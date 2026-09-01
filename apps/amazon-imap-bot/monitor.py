from __future__ import annotations

import imaplib
import queue
import socket
import ssl
import threading
import time
import uuid
from dataclasses import dataclass
from datetime import datetime
from typing import Callable

from ai import ReplyGenerator
from api_runner import ApiTestRunner
from config import Account, Settings
from function_catalog import OracleFunctionCatalog
from function_map import FunctionMap, FunctionRequest
from function_router import FunctionRouter
from mailbox import MailboxClient
from project_zip_runner import ProjectZipRunner
from message import parse, should_reply
from ses import SesSender
from sound import notify
from store import Store
from diagnostics import trace


@dataclass
class AccountState:
    email: str
    connected: bool = False
    last_check: str = "-"
    last_error: str = ""
    received: int = 0
    replied: int = 0


class Monitor:
    def __init__(
        self,
        settings: Settings,
        store: Store,
        on_event: Callable[[str], None] | None = None,
        function_map: FunctionMap | None = None,
        on_startup: Callable[[str], None] | None = None,
    ):
        self.settings = settings
        self.store = store
        self.on_event = on_event or (lambda text: None)
        self.on_startup = on_startup or (lambda text: None)
        self.states = {a.email: AccountState(a.email) for a in settings.accounts if a.enabled}
        self.stop_event = threading.Event()
        self.run_lock = threading.Lock()
        self.on_startup("Monitor: inicializando cliente OpenAI...")
        self.ai = ReplyGenerator(
            settings.openai_api_key, settings.openai_model, settings.openai_base_url,
            settings.openai_reasoning_effort, settings.openai_timeout_seconds,
        )
        self.on_startup("Monitor: cliente OpenAI OK.")
        self.on_startup("Monitor: inicializando Amazon SES...")
        self.ses = SesSender(settings.aws_profile, settings.aws_region)
        self.on_startup("Monitor: Amazon SES OK.")
        self.on_startup("Monitor: inicializando cliente IMAP...")
        self.mailbox = MailboxClient(settings)
        self.on_startup("Monitor: cliente IMAP OK.")
        if function_map is None:
            self.on_startup("Monitor: carregando catálogo de funções do Oracle...")
            self.function_map = FunctionMap(
                OracleFunctionCatalog(settings.function_database, log=self.on_startup)
            )
            self.on_startup("Monitor: catálogo de funções Oracle OK.")
        else:
            self.function_map = function_map
            self.on_startup(f"Monitor: catálogo fornecido externamente ({self.function_map.source_name}).")
        self.on_startup("Monitor: inicializando roteador de funções...")
        self.function_router = FunctionRouter(
            settings.openai_api_key, settings.openai_model, settings.openai_base_url,
            settings.openai_timeout_seconds, self.function_map,
        )
        self.on_startup("Monitor: roteador de funções OK.")
        self.on_startup("Monitor: inicializando executores de API/ZIP...")
        self.api_runner = ApiTestRunner(
            settings, store,
            lambda text: self.on_event(f"{datetime.now().strftime('%H:%M:%S')} [API] {text}"),
        )
        self.project_zip_runner = ProjectZipRunner(
            settings, store,
            lambda text: self.on_event(f"{datetime.now().strftime('%H:%M:%S')} [API] {text}"),
        )
        self.on_startup("Monitor: executores de API/ZIP OK.")
        self.accounts_by_email = {a.email.lower(): a for a in settings.accounts}
        self.own = set(self.accounts_by_email)
        self.delete_queue: queue.Queue[int] = queue.Queue()
        pending_deletes = self.store.list_pending_deletes()
        for pending in pending_deletes:
            self.store.set_message_status(int(pending["id"]), "delete-queued")
            self.delete_queue.put(int(pending["id"]))
        self.delete_thread = threading.Thread(
            target=self._delete_worker_loop,
            name="amazon-imap-delete-worker",
            daemon=True,
        )
        self.delete_thread.start()
        if pending_deletes:
            self.on_startup(
                f"Monitor: retomando {len(pending_deletes)} remoção(ões) pendente(s) na fila assíncrona."
            )

        self.send_queue: queue.Queue[int] = queue.Queue()
        pending_sends = self.store.list_send_queue()
        for pending in pending_sends:
            self.store.set_outbound_status(int(pending["id"]), "send-queued")
            self.send_queue.put(int(pending["id"]))
        if self.store.get_control().get("external_send_enabled"):
            for outbound_id in self.store.activate_approved_waiting():
                self.send_queue.put(int(outbound_id))
        self.send_thread = threading.Thread(
            target=self._send_worker_loop,
            name="amazon-imap-send-worker",
            daemon=True,
        )
        self.send_thread.start()
        if pending_sends:
            self.on_startup(
                f"Monitor: retomando {len(pending_sends)} envio(s) pendente(s) na fila assíncrona."
            )
        self.on_startup(f"Monitor: pronto; {len(self.states)} conta(s) ativa(s).")

    def stop(self) -> None:
        self.stop_event.set()

    def wait_workers(self, timeout: float = 10.0) -> None:
        deadline = time.monotonic() + max(0.0, float(timeout))
        for worker in (self.delete_thread, self.send_thread):
            remaining = max(0.0, deadline - time.monotonic())
            if worker.is_alive() and remaining > 0:
                worker.join(timeout=remaining)

    @staticmethod
    def _preview(text: str, limit: int = 180) -> str:
        value = " ".join(str(text or "").split())
        return value if len(value) <= limit else value[:limit - 1] + "…"

    def _event(self, text: str, category: str = "SYSTEM", level: str = "INFO") -> None:
        stamp = datetime.now().strftime("%H:%M:%S")
        try:
            self.store.add_event(category, level, text)
        except Exception:
            pass
        self.on_event(f"{stamp} [{category}] {text}")

    def _queue_generated_reply(self, account: Account, item, body: str) -> int:
        if self.store.is_inbound_reply_suppressed(account.email, item.message_id):
            self.store.set_inbound_status(account.email, item.message_id, "no-reply")
            self._event(
                f"NÃO RESPONDER ativo para {item.sender_email} | {item.subject or '(sem assunto)'}; resposta não foi criada",
                "EMAIL",
                "WARN",
            )
            return 0
        recipient = str(item.sender_email or "").strip().lower()
        if not recipient:
            raise RuntimeError("destinatário da resposta está vazio")
        control = self.store.get_control()
        owner_recipient = self.store.is_always_allowed_recipient(recipient)
        # Segundo bloqueio é mandatório: todo destinatário externo exige liberação individual.
        approval_required = not owner_recipient

        if owner_recipient:
            recipient_class = "owner"
            status = "send-queued"
            approved_at = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
            approved_by = "always-allowed"
        elif approval_required:
            recipient_class = "external"
            status = "pending-approval"
            approved_at = None
            approved_by = ""
        elif bool(control.get("external_send_enabled")):
            recipient_class = "external"
            status = "send-queued"
            approved_at = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
            approved_by = "policy"
        else:
            recipient_class = "external"
            status = "approved-waiting-global"
            approved_at = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
            approved_by = "policy"

        local_id = self.ses.new_message_id(account)
        outbound_id = self.store.add_outbound(
            account=account.email,
            message_id=local_id,
            thread_key=item.thread_key,
            sender=account.email,
            recipient=recipient,
            subject=item.subject,
            body=body,
            reply_to=item.message_id,
            provider_message_id="",
            status=status,
            references=item.references,
            recipient_class=recipient_class,
            approval_required=approval_required,
            approved_at=approved_at,
            approved_by=approved_by,
        )

        if status == "pending-approval":
            self.store.set_inbound_status(account.email, item.message_id, "reply-pending-approval")
            self._event(
                f"RESPOSTA GERADA e pendente de liberação manual para={recipient} resposta_id={outbound_id}",
                "EMAIL",
                "WARN",
            )
        elif status == "approved-waiting-global":
            self.store.set_inbound_status(account.email, item.message_id, "reply-approved-waiting-global")
            self._event(
                f"RESPOSTA GERADA para={recipient}; liberação individual OK, mas envio externo global está bloqueado",
                "EMAIL",
                "WARN",
            )
        else:
            self.store.set_inbound_status(account.email, item.message_id, "reply-queued")
            self.send_queue.put(int(outbound_id))
            self._event(
                f"ENVIO ENFILEIRADO para={recipient} resposta_id={outbound_id} classe={recipient_class}",
                "SES",
            )
        return int(outbound_id)

    def approve_outbound(self, row: dict, approved_by: str = "tui") -> dict:
        fresh = self.store.get_message(int(row.get("id") or 0))
        if fresh is None:
            raise RuntimeError("resposta não encontrada")
        approved = self.store.approve_outbound(int(fresh["id"]), approved_by=approved_by)
        inbound_message_id = str(approved.get("reply_to_message_id") or "")
        account_email = str(approved.get("account_email") or "")
        if approved.get("status") == "send-queued":
            if inbound_message_id:
                self.store.set_inbound_status(account_email, inbound_message_id, "reply-queued")
            self.send_queue.put(int(approved["id"]))
            self._event(
                f"RESPOSTA LIBERADA resposta_id={approved['id']} para={approved.get('recipient') or '-'}; envio enfileirado",
                "EMAIL",
                "WARN",
            )
        else:
            if inbound_message_id:
                self.store.set_inbound_status(account_email, inbound_message_id, "reply-approved-waiting-global")
            self._event(
                f"RESPOSTA LIBERADA resposta_id={approved['id']} para={approved.get('recipient') or '-'}; "
                "aguardando liberação global de clientes",
                "EMAIL",
                "WARN",
            )
        return approved

    def suppress_inbound_reply(self, row: dict, suppressed_by: str = "tui") -> dict:
        fresh = self.store.get_message(int(row.get("id") or 0))
        if fresh is None or fresh.get("deleted_at"):
            raise RuntimeError("mensagem de entrada não encontrada")
        result = self.store.suppress_inbound_reply(int(fresh["id"]), suppressed_by=suppressed_by)
        self._event(
            f"NÃO RESPONDER marcado para mensagem_id={fresh['id']} de={fresh.get('sender') or '-'}; "
            f"respostas pendentes canceladas={int(result.get('cancelled_replies') or 0)}",
            "EMAIL",
            "WARN",
        )
        return result

    def set_external_send_enabled(self, enabled: bool, updated_by: str = "tui") -> int:
        self.store.set_external_send_enabled(bool(enabled), updated_by=updated_by)
        activated = 0
        if enabled:
            ids = self.store.activate_approved_waiting()
            for outbound_id in ids:
                row = self.store.get_message(int(outbound_id))
                if row and row.get("reply_to_message_id"):
                    self.store.set_inbound_status(
                        str(row.get("account_email") or ""),
                        str(row.get("reply_to_message_id") or ""),
                        "reply-queued",
                    )
                self.send_queue.put(int(outbound_id))
            activated = len(ids)
        self._event(
            f"ENVIO EXTERNO GLOBAL {'LIBERADO' if enabled else 'BLOQUEADO'} por {updated_by}; "
            f"{activated} resposta(s) previamente aprovadas enfileirada(s)",
            "EMAIL",
            "WARN" if not enabled else "INFO",
        )
        return activated

    def _send_outbound_now(self, row: dict) -> None:
        if row.get("direction") != "out":
            raise RuntimeError("fila de envio recebeu registro que não é resposta")
        account_email = str(row.get("account_email") or "").strip().lower()
        account = self.accounts_by_email.get(account_email)
        if account is None or not account.enabled:
            raise RuntimeError(f"conta remetente não disponível: {account_email}")

        inbound_message_id = str(row.get("reply_to_message_id") or "")
        if inbound_message_id and self.store.is_inbound_reply_suppressed(account_email, inbound_message_id):
            self.store.set_outbound_status(int(row["id"]), "cancelled-no-reply")
            self.store.set_inbound_status(account_email, inbound_message_id, "no-reply")
            self._event(
                f"ENVIO CANCELADO resposta_id={row['id']}: mensagem marcada como NÃO RESPONDER",
                "SES",
                "WARN",
            )
            return

        recipient_class = str(row.get("recipient_class") or "external").strip().lower()
        if recipient_class != "owner":
            control = self.store.get_control()
            if not bool(control.get("external_send_enabled")):
                self.store.set_outbound_status(int(row["id"]), "approved-waiting-global")
                if row.get("reply_to_message_id"):
                    self.store.set_inbound_status(account_email, str(row["reply_to_message_id"]), "reply-approved-waiting-global")
                return
            if int(row.get("approval_required") or 0) == 1 and not row.get("approved_at"):
                self.store.set_outbound_status(int(row["id"]), "pending-approval")
                if row.get("reply_to_message_id"):
                    self.store.set_inbound_status(account_email, str(row["reply_to_message_id"]), "reply-pending-approval")
                return

        self.store.set_outbound_status(int(row["id"]), "sending")
        if row.get("reply_to_message_id"):
            self.store.set_inbound_status(account_email, str(row["reply_to_message_id"]), "sending")
        self._event(
            f"SEND para={row.get('recipient') or '-'} assunto={self._preview(row.get('subject') or '(sem assunto)', 90)}",
            "SES",
        )
        _message_id, ses_id = self.ses.send_stored_reply(account, row)
        self.store.set_outbound_status(int(row["id"]), "sent", provider_message_id=ses_id)
        if row.get("reply_to_message_id"):
            self.store.set_inbound_status(account_email, str(row["reply_to_message_id"]), "replied")
        state = self.states.get(account.email)
        if state is not None:
            state.replied += 1
        self._event(f"OK para={row.get('recipient') or '-'} MessageId={ses_id}", "SES")

    def _send_worker_loop(self) -> None:
        while not self.stop_event.is_set():
            try:
                message_row_id = self.send_queue.get(timeout=0.5)
            except queue.Empty:
                continue
            try:
                row = self.store.get_message(int(message_row_id))
                if row is None or row.get("deleted_at") or row.get("status") not in {"send-queued", "sending"}:
                    continue
                self._send_outbound_now(row)
            except Exception as exc:
                try:
                    current = self.store.get_message(int(message_row_id))
                    if current is not None:
                        self.store.set_outbound_status(int(message_row_id), "send-error", str(exc))
                        if current.get("reply_to_message_id"):
                            self.store.set_inbound_status(
                                str(current.get("account_email") or ""),
                                str(current.get("reply_to_message_id") or ""),
                                "reply-error",
                            )
                except Exception:
                    pass
                self._event(f"ERRO AO ENVIAR resposta_id={message_row_id}: {exc}", "SES", "ERROR")
            finally:
                self.send_queue.task_done()

    def _execute_function_request(self, account: Account, item, request: FunctionRequest, state: AccountState) -> None:
        """Executa uma função explicitamente autorizada pelo catálogo Oracle."""
        self.store.set_inbound_status(account.email, item.message_id, "executing")
        self._event(
            f"EXECUTANDO função={request.name} remetente={request.sender} "
            f"nível={request.reasoning_level}/{request.reasoning_effort}",
            "FUNCTION",
        )
        original_request = "\n\n".join(
            part for part in [
                f"Assunto: {item.subject}" if item.subject else "",
                item.body or "",
            ] if part
        ).strip()
        output_path = ""
        result = ""
        run_id = None
        if request.name == "api_zip_test":
            run_id = self.api_runner.run_zip_test(
                reasoning_effort=request.reasoning_effort,
                request_text=request.request_text,
                source=f"email:{request.sender}",
            )
        elif request.name == "project_zip_edit":
            operation = str(request.arguments.get("operation") or "modify").strip().lower()
            run_id = self.project_zip_runner.run_project_request(
                request_text=original_request or request.request_text,
                reasoning_effort=request.reasoning_effort,
                operation=operation,
                source=f"email:{request.sender}",
            )
        elif request.name == "function_catalog_admin":
            operation = str(request.arguments.get("operation") or "list").strip().lower()
            started = time.monotonic()
            run_id = self.store.add_api_run(
                kind="function-catalog",
                status="executando",
                model="oracle",
                reasoning_effort=request.reasoning_effort,
                input_path="",
                output_path="",
                request_summary=f"{operation} do catálogo de funções Oracle",
                request_payload="\n".join(f"{key}={value}" for key, value in sorted(request.arguments.items())), 
                listed_item_count=0,
            )
            try:
                result = self.function_map.catalog_summary_text(refresh=operation == "sync")
                self.store.update_api_run(
                    run_id,
                    status="concluido",
                    response_summary=result,
                    response_bytes=len(result.encode("utf-8")),
                    elapsed_ms=int((time.monotonic() - started) * 1000),
                    finished=True,
                )
            except Exception as exc:
                self.store.update_api_run(
                    run_id,
                    status="erro",
                    error=str(exc),
                    elapsed_ms=int((time.monotonic() - started) * 1000),
                    finished=True,
                )
                raise
        else:
            raise RuntimeError(f"função não implementada: {request.name}")
        api_run = self.store.get_api_run(run_id) or {} if run_id is not None else {}
        output_path = output_path or str(api_run.get("output_path") or "")
        result = result or str(api_run.get("response_summary") or "").strip()
        self.store.set_inbound_status(account.email, item.message_id, "completed")
        self._event(
            f"CONCLUÍDO função={request.name} run=#{run_id} arquivo={output_path or '-'}",
            "FUNCTION",
        )

        reply_lines = [
            f"Função {request.name} executada com sucesso.",
            f"Nível: {request.reasoning_level} ({request.reasoning_effort}).",
        ]
        if output_path:
            reply_lines.append(f"Arquivo de retorno salvo em: {output_path}")
        if result:
            reply_lines.extend(["", "Resultado da API:", result[:2500]])
        reply_body = "\n".join(reply_lines)

        self._queue_generated_reply(account, item, reply_body)

    def run_account_once(self, account: Account) -> None:
        state = self.states[account.email]
        conn = None
        cycle_started = time.monotonic()
        try:
            trace(f"IMAP CYCLE START account={account.email} folder={self.settings.imap_folder}")
            self._event(f"Consultando {account.email} em {self.settings.imap_folder}", "IMAP")
            conn = imaplib.IMAP4_SSL(
                self.settings.imap_host,
                self.settings.imap_port,
                ssl_context=ssl.create_default_context(),
            )
            conn.login(account.email, account.password)
            status, _ = conn.select(self.settings.imap_folder, readonly=True)
            if status != "OK":
                raise RuntimeError(f"não foi possível abrir {self.settings.imap_folder}")
            state.connected = True
            state.last_error = ""
            state.last_check = datetime.now().strftime("%d/%m/%Y %H:%M:%S")
            uid_validity = self.mailbox.uid_validity(conn)
            mailbox_state = self.store.get_mailbox_state(account.email, self.settings.imap_folder)
            previous_uid_validity = str((mailbox_state or {}).get("uid_validity") or "")
            previous_max_uid = int((mailbox_state or {}).get("last_max_uid") or 0)
            initial_sync = mailbox_state is None or previous_uid_validity != str(uid_validity)

            status, data = conn.uid("search", None, "ALL")
            if status != "OK":
                raise RuntimeError("falha ao consultar todas as mensagens da pasta IMAP")
            uids = data[0].split() if data and data[0] else []
            present_uids = {
                (uid.decode("ascii", errors="ignore") if isinstance(uid, bytes) else str(uid))
                for uid in uids
            }
            current_max_uid = max((int(uid) for uid in present_uids if str(uid).isdigit()), default=0)
            self._event(
                f"{account.email}: sincronizando {len(uids)} mensagem(ns) da pasta {self.settings.imap_folder} "
                f"UIDVALIDITY={uid_validity}",
                "IMAP",
            )

            uid_index_started = time.monotonic()
            existing_by_uid = self.store.list_inbound_uid_index(
                account.email, self.settings.imap_folder, str(uid_validity)
            )
            trace(
                f"IMAP UID INDEX account={account.email} oracle_rows={len(existing_by_uid)} "
                f"elapsed={time.monotonic()-uid_index_started:.3f}s"
            )
            new_uid_count = 0
            for uid in uids:
                uid_text = uid.decode("ascii", errors="ignore") if isinstance(uid, bytes) else str(uid)
                if uid_text in existing_by_uid:
                    continue
                new_uid_count += 1
                status, parts = conn.uid("fetch", uid, "(RFC822)")
                if status != "OK" or not parts:
                    self._event(f"Falha ao baixar UID {uid_text}", "IMAP", "WARN")
                    continue
                raw = next((part[1] for part in parts if isinstance(part, tuple) and isinstance(part[1], bytes)), b"")
                if not raw:
                    self._event(f"UID {uid_text} retornou sem conteúdo", "IMAP", "WARN")
                    continue

                item = parse(raw)
                allowed, reason = should_reply(item, self.own)
                should_process = (
                    not initial_sync
                    and uid_text.isdigit()
                    and int(uid_text) > previous_max_uid
                )
                initial_status = (
                    ("received" if allowed else f"ignored:{reason}")
                    if should_process
                    else "synced"
                )
                self.store.add_inbound(
                    account=account.email,
                    message_id=item.message_id,
                    thread_key=item.thread_key,
                    sender=item.sender_email,
                    recipient=item.recipient,
                    subject=item.subject,
                    body=item.body,
                    status=initial_status,
                    mail_date=item.mail_date,
                    imap_uid=uid_text,
                    imap_folder=self.settings.imap_folder,
                    imap_uid_validity=str(uid_validity),
                    references=item.references,
                )
                state.received += 1
                if not should_process:
                    self._event(
                        f"SINCRONIZADO {account.email} <- {item.sender_email} UID={uid_text} | "
                        f"{item.subject or '(sem assunto)'}",
                        "IMAP",
                    )
                    continue
                self._event(
                    f"RECEBIDO {account.email} <- {item.sender_email} | {item.subject or '(sem assunto)'}",
                    "EMAIL",
                )
                if self.settings.sound_enabled:
                    notify(self.settings.sound_file)
                if not allowed:
                    self._event(f"IGNORADO {item.sender_email} | {reason}", "EMAIL", "WARN")
                    continue

                function_request = None
                authorized_functions = self.function_map.authorized_function_names(item.sender_email)
                if authorized_functions:
                    router_payload = self.function_router.audit_payload(item.sender_email, item.subject, item.body)
                    router_run_id = self.store.add_api_run(
                        kind="function-router",
                        status="aguardando-resposta",
                        model=self.settings.openai_model,
                        reasoning_effort=self.function_router.reasoning_effort,
                        input_path="",
                        output_path="",
                        request_summary=(
                            f"Roteamento de {item.sender_email} | funções={','.join(authorized_functions)} | "
                            f"{self._preview(item.subject or '(sem assunto)', 160)}"
                        ),
                        request_payload=router_payload,
                        request_bytes=len(router_payload.encode("utf-8")),
                        input_file_bytes=0,
                        input_file_count=0,
                        listed_item_count=len(authorized_functions),
                    )
                    router_started = time.monotonic()
                    self.store.set_inbound_status(account.email, item.message_id, "analyzing")
                    self._event(
                        f"ROUTER REQUEST remetente={item.sender_email} funções={','.join(authorized_functions)}",
                        "GPT",
                    )
                    try:
                        route = self.function_router.route(item.sender_email, item.subject, item.body)
                        function_request = route.request
                        if function_request is None:
                            route_summary = "nenhuma função selecionada"
                        else:
                            route_summary = (
                                f"função={function_request.name} "
                                f"nível={function_request.reasoning_level}/{function_request.reasoning_effort} "
                                f"pedido={self._preview(function_request.request_text, 500)}"
                            )
                        self.store.update_api_run(
                            router_run_id,
                            status="concluido",
                            response_id=route.response_id,
                            response_summary=route_summary,
                            response_bytes=len(route_summary.encode("utf-8")),
                            elapsed_ms=int((time.monotonic() - router_started) * 1000),
                            finished=True,
                        )
                        self._event(f"ROUTER RESPONSE {route_summary}", "GPT")
                    except Exception as router_exc:
                        self.store.update_api_run(
                            router_run_id,
                            status="erro",
                            error=str(router_exc),
                            elapsed_ms=int((time.monotonic() - router_started) * 1000),
                            finished=True,
                        )
                        self._event(
                            f"ROUTER ERRO remetente={item.sender_email}: {router_exc}",
                            "GPT",
                            "ERROR",
                        )
                        # Falha no roteador nunca autoriza execução. O e-mail segue para o fluxo normal de suporte.
                        function_request = None

                if function_request is not None:
                    try:
                        self._execute_function_request(account, item, function_request, state)
                    except Exception as exc:
                        self.store.set_inbound_status(account.email, item.message_id, "function-error")
                        self._event(
                            f"ERRO função={function_request.name} remetente={item.sender_email}: {exc}",
                            "FUNCTION",
                            "ERROR",
                        )
                        failure_body = (
                            f"A função {function_request.name} foi reconhecida, mas não foi concluída. "
                            "O erro foi registrado no console do bot para análise."
                        )
                        try:
                            self._queue_generated_reply(account, item, failure_body)
                        except Exception as reply_exc:
                            self._event(f"Falha ao preparar aviso de erro da função para {item.sender_email}: {reply_exc}", "SES", "ERROR")
                    continue

                generated_body = ""
                try:
                    self.store.set_inbound_status(account.email, item.message_id, "analyzing")
                    body_chars = len(item.body or "")
                    self._event(
                        f"REQUEST model={self.settings.openai_model} effort={self.settings.openai_reasoning_effort} para={item.sender_email} "
                        f"assunto={self._preview(item.subject or '(sem assunto)', 80)} input={body_chars} chars",
                        "GPT",
                    )
                    email_payload = self.ai.audit_payload(item)
                    api_run_id = self.store.add_api_run(
                        kind="email-reply", status="aguardando-resposta",
                        model=self.settings.openai_model,
                        reasoning_effort=self.settings.openai_reasoning_effort,
                        input_path="", output_path="",
                        request_summary=f"Responder e-mail de {item.sender_email}: {self._preview(item.subject or '(sem assunto)', 120)}",
                        request_payload=email_payload,
                        request_bytes=len(email_payload.encode("utf-8")),
                        input_file_bytes=0, input_file_count=0, listed_item_count=0,
                    )
                    api_started = time.monotonic()
                    try:
                        generated_body = self.ai.generate(item)
                    except Exception as api_exc:
                        self.store.update_api_run(
                            api_run_id, status="erro", error=str(api_exc),
                            elapsed_ms=int((time.monotonic() - api_started) * 1000), finished=True,
                        )
                        raise
                    else:
                        self.store.update_api_run(
                            api_run_id, status="concluido", response_id=self.ai.last_response_id,
                            response_summary=generated_body[:1000],
                            response_bytes=len(generated_body.encode("utf-8")),
                            elapsed_ms=int((time.monotonic() - api_started) * 1000), finished=True,
                        )
                    self.store.set_inbound_status(account.email, item.message_id, "understood")
                    self._event(
                        f"RESPONSE {len(generated_body)} chars | {self._preview(generated_body)}",
                        "GPT",
                    )
                    self._queue_generated_reply(account, item, generated_body)
                except Exception as exc:
                    self.store.set_inbound_status(account.email, item.message_id, "reply-error")
                    try:
                        self.store.add_outbound(
                            account=account.email,
                            message_id=f"<error-{uuid.uuid4()}@local>",
                            thread_key=item.thread_key,
                            sender=account.email,
                            recipient=item.sender_email,
                            subject=item.subject,
                            body=generated_body,
                            reply_to=item.message_id,
                            provider_message_id="",
                            status="error",
                            error=str(exc),
                        )
                    except Exception:
                        pass
                    self._event(f"Resposta para {item.sender_email}: {exc}", "ERROR", "ERROR")

            reconcile_started = time.monotonic()
            removed_by_sync = self.store.reconcile_inbox(
                account.email, self.settings.imap_folder, str(uid_validity), present_uids
            )
            trace(
                f"IMAP RECONCILE account={account.email} present={len(present_uids)} new={new_uid_count} "
                f"removed={removed_by_sync} elapsed={time.monotonic()-reconcile_started:.3f}s"
            )
            self.store.set_mailbox_state(
                account.email, self.settings.imap_folder, str(uid_validity), current_max_uid, initialized=True
            )
            if initial_sync:
                self._event(
                    f"SINCRONIZAÇÃO INICIAL concluída: {len(present_uids)} mensagem(ns) espelhadas; "
                    "mensagens já existentes não foram respondidas automaticamente.",
                    "IMAP",
                )
            if removed_by_sync:
                self._event(
                    f"SINCRONIZAÇÃO IMAP removeu {removed_by_sync} registro(s) da ENTRADA local porque "
                    "não existem mais na pasta do servidor.",
                    "IMAP",
                    "WARN",
                )
        except (imaplib.IMAP4.error, OSError, socket.error, RuntimeError) as exc:
            state.connected = False
            state.last_error = str(exc)
            state.last_check = datetime.now().strftime("%d/%m/%Y %H:%M:%S")
            self._event(f"{account.email}: {exc}", "IMAP", "ERROR")
        finally:
            trace(f"IMAP CYCLE END account={account.email} elapsed={time.monotonic()-cycle_started:.3f}s")
            if conn is not None:
                try:
                    conn.logout()
                except Exception:
                    pass


    @staticmethod
    def _delete_status(row: dict) -> str:
        return str(row.get("status") or "").strip().lower()

    def _validate_delete_row(self, row: dict, *, allow_queued: bool = False):
        if row.get("direction") != "in":
            raise RuntimeError("somente mensagens de entrada podem ser removidas")
        status = self._delete_status(row)
        if status in {"analyzing", "understood", "sending", "executing"}:
            raise RuntimeError("a mensagem está em processamento; aguarde terminar antes de remover")
        if not allow_queued and status in {"delete-queued", "deleting"}:
            raise RuntimeError("a mensagem já está na fila de remoção")
        uid = str(row.get("imap_uid") or "").strip()
        folder = str(row.get("imap_folder") or self.settings.imap_folder).strip()
        if not uid.isdigit():
            raise RuntimeError("esta mensagem não possui UID IMAP; não é possível removê-la do servidor")
        account_email = str(row.get("account_email") or "").lower()
        account = self.accounts_by_email.get(account_email)
        if account is None or not account.enabled:
            raise RuntimeError(f"conta IMAP não disponível para remoção: {account_email}")
        return account, uid, folder

    def queue_delete_inbound(self, row: dict) -> int:
        fresh = self.store.get_message(int(row.get("id") or 0))
        if fresh is None or fresh.get("deleted_at"):
            raise RuntimeError("mensagem não encontrada ou já removida")
        account, uid, _folder = self._validate_delete_row(fresh)
        self.store.set_message_status(int(fresh["id"]), "delete-queued")
        self.delete_queue.put(int(fresh["id"]))
        pending = self.store.count_pending_deletes()
        self._event(
            f"REMOÇÃO ENFILEIRADA {account.email} UID={uid} pendentes={pending}",
            "EMAIL",
            "WARN",
        )
        return pending

    def _acquire_run_lock_for_delete(self, *, wait: bool) -> bool:
        if not wait:
            return self.run_lock.acquire(timeout=15)
        while not self.stop_event.is_set():
            if self.run_lock.acquire(timeout=0.5):
                return True
        return False

    def _delete_inbound_now(self, row: dict, *, wait_for_monitor: bool = False, allow_queued: bool = False) -> str:
        account, uid, folder = self._validate_delete_row(row, allow_queued=allow_queued)
        if not self._acquire_run_lock_for_delete(wait=wait_for_monitor):
            if self.stop_event.is_set():
                raise RuntimeError("remoção interrompida durante o encerramento")
            raise RuntimeError("há uma verificação em andamento; tente remover novamente em alguns segundos")
        try:
            mode = self.mailbox.move_to_trash(account, uid, folder)
            self.store.mark_deleted(int(row["id"]), mode)
            status = str(row.get("status") or "")
            self._event(
                f"REMOVIDO {account.email} UID={uid} status={status} modo={mode}",
                "EMAIL",
                "WARN",
            )
            return mode
        finally:
            self.run_lock.release()

    def _delete_worker_loop(self) -> None:
        while not self.stop_event.is_set():
            try:
                message_row_id = self.delete_queue.get(timeout=0.5)
            except queue.Empty:
                continue
            try:
                row = self.store.get_message(int(message_row_id))
                if row is None or row.get("deleted_at"):
                    continue
                self.store.set_message_status(int(message_row_id), "deleting")
                row = self.store.get_message(int(message_row_id)) or row
                self._event(
                    f"REMOVENDO {row.get('account_email') or '-'} UID={row.get('imap_uid') or '-'} "
                    f"fila_restante={self.delete_queue.qsize()}",
                    "EMAIL",
                    "WARN",
                )
                self._delete_inbound_now(row, wait_for_monitor=True, allow_queued=True)
            except Exception as exc:
                try:
                    current = self.store.get_message(int(message_row_id))
                    if current is not None and not current.get("deleted_at"):
                        self.store.set_message_status(int(message_row_id), "delete-error", str(exc))
                except Exception:
                    pass
                self._event(f"ERRO AO REMOVER message_row_id={message_row_id}: {exc}", "EMAIL", "ERROR")
            finally:
                self.delete_queue.task_done()

    def delete_inbound(self, row: dict) -> str:
        # Mantido síncrono para chamadas legadas/API. A TUI usa queue_delete_inbound().
        return self._delete_inbound_now(row)

    def run_once(self) -> None:
        if not self.run_lock.acquire(blocking=False):
            self._event("Verificação já está em andamento; nova solicitação ignorada", "SYSTEM", "WARN")
            return
        try:
            for account in self.settings.accounts:
                if account.enabled and not self.stop_event.is_set():
                    self.run_account_once(account)
        finally:
            self.run_lock.release()

    def run_forever(self) -> None:
        while not self.stop_event.is_set():
            try:
                self.run_once()
            except Exception as exc:
                self._event(
                    f"ERRO NO CICLO IMAP: {type(exc).__name__}: {exc}",
                    "SYSTEM",
                    "ERROR",
                )
            self.stop_event.wait(self.settings.poll_seconds)
