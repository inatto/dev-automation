from __future__ import annotations

import imaplib
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
from function_map import FunctionMap, FunctionRequest
from mailbox import MailboxClient
from message import parse, should_reply
from ses import SesSender
from sound import notify
from store import Store


@dataclass
class AccountState:
    email: str
    connected: bool = False
    last_check: str = "-"
    last_error: str = ""
    received: int = 0
    replied: int = 0


class Monitor:
    def __init__(self, settings: Settings, store: Store, on_event: Callable[[str], None] | None = None):
        self.settings = settings
        self.store = store
        self.on_event = on_event or (lambda text: None)
        self.states = {a.email: AccountState(a.email) for a in settings.accounts if a.enabled}
        self.stop_event = threading.Event()
        self.run_lock = threading.Lock()
        self.ai = ReplyGenerator(
            settings.openai_api_key, settings.openai_model, settings.openai_base_url,
            settings.openai_reasoning_effort, settings.openai_timeout_seconds,
        )
        self.ses = SesSender(settings.aws_profile, settings.aws_region)
        self.mailbox = MailboxClient(settings)
        self.function_map = FunctionMap(settings.functions_config)
        self.api_runner = ApiTestRunner(
            settings, store,
            lambda text: self.on_event(f"{datetime.now().strftime('%H:%M:%S')} [API] {text}"),
        )
        self.accounts_by_email = {a.email.lower(): a for a in settings.accounts}
        self.own = set(self.accounts_by_email)

    def stop(self) -> None:
        self.stop_event.set()

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

    def _execute_function_request(self, account: Account, item, request: FunctionRequest, state: AccountState) -> None:
        """Executa uma função explicitamente autorizada pelo functions.json."""
        self.store.set_inbound_status(account.email, item.message_id, "executing")
        self._event(
            f"EXECUTANDO função={request.name} remetente={request.sender} "
            f"nível={request.reasoning_level}/{request.reasoning_effort}",
            "FUNCTION",
        )
        if request.name != "api_zip_test":
            raise RuntimeError(f"função não implementada: {request.name}")

        run_id = self.api_runner.run_zip_test(
            reasoning_effort=request.reasoning_effort,
            request_text=request.request_text,
            source=f"email:{request.sender}",
        )
        api_run = self.store.get_api_run(run_id) or {}
        output_path = str(api_run.get("output_path") or "")
        result = str(api_run.get("response_summary") or "").strip()
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

        self.store.set_inbound_status(account.email, item.message_id, "sending")
        local_id, ses_id = self.ses.send_reply(account, item, reply_body)
        self.store.add_outbound(
            account=account.email,
            message_id=local_id,
            thread_key=item.thread_key,
            sender=account.email,
            recipient=item.sender_email,
            subject=item.subject,
            body=reply_body,
            reply_to=item.message_id,
            provider_message_id=ses_id,
            status="sent",
        )
        self.store.set_inbound_status(account.email, item.message_id, "replied")
        state.replied += 1
        self._event(f"OK função={request.name} resposta enviada para={item.sender_email} MessageId={ses_id}", "SES")

    def run_account_once(self, account: Account) -> None:
        state = self.states[account.email]
        conn = None
        try:
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
            status, data = conn.uid("search", None, "UNSEEN")
            if status != "OK":
                raise RuntimeError("falha ao consultar mensagens não lidas")
            uids = data[0].split() if data and data[0] else []
            self._event(f"{account.email}: {len(uids)} mensagem(ns) UNSEEN", "IMAP")

            for uid in uids:
                uid_text = uid.decode("ascii", errors="ignore") if isinstance(uid, bytes) else str(uid)
                status, parts = conn.uid("fetch", uid, "(RFC822)")
                if status != "OK" or not parts:
                    self._event(f"Falha ao baixar UID {uid_text}", "IMAP", "WARN")
                    continue
                raw = next((part[1] for part in parts if isinstance(part, tuple) and isinstance(part[1], bytes)), b"")
                if not raw:
                    self._event(f"UID {uid_text} retornou sem conteúdo", "IMAP", "WARN")
                    continue
                item = parse(raw)
                if self.store.seen(account.email, item.message_id):
                    continue

                allowed, reason = should_reply(item, self.own)
                self.store.add_inbound(
                    account=account.email,
                    message_id=item.message_id,
                    thread_key=item.thread_key,
                    sender=item.sender_email,
                    recipient=item.recipient,
                    subject=item.subject,
                    body=item.body,
                    status="received" if allowed else f"ignored:{reason}",
                    mail_date=item.mail_date,
                    imap_uid=uid_text,
                    imap_folder=self.settings.imap_folder,
                )
                state.received += 1
                self._event(
                    f"RECEBIDO {account.email} <- {item.sender_email} | {item.subject or '(sem assunto)'}",
                    "EMAIL",
                )
                if self.settings.sound_enabled:
                    notify(self.settings.sound_file)
                if not allowed:
                    self._event(f"IGNORADO {item.sender_email} | {reason}", "EMAIL", "WARN")
                    continue

                try:
                    function_request = self.function_map.resolve(item.sender_email, item.subject, item.body)
                except ValueError as command_exc:
                    self.store.set_inbound_status(account.email, item.message_id, "function-error")
                    self._event(
                        f"COMANDO INVÁLIDO remetente={item.sender_email}: {command_exc}",
                        "FUNCTION",
                        "WARN",
                    )
                    invalid_body = f"O comando de função foi reconhecido, mas é inválido: {command_exc}."
                    try:
                        local_id, ses_id = self.ses.send_reply(account, item, invalid_body)
                        self.store.add_outbound(
                            account=account.email, message_id=local_id, thread_key=item.thread_key,
                            sender=account.email, recipient=item.sender_email, subject=item.subject,
                            body=invalid_body, reply_to=item.message_id, provider_message_id=ses_id, status="sent",
                        )
                    except Exception as reply_exc:
                        self._event(f"Falha ao responder comando inválido para {item.sender_email}: {reply_exc}", "SES", "ERROR")
                    continue

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
                            local_id, ses_id = self.ses.send_reply(account, item, failure_body)
                            self.store.add_outbound(
                                account=account.email, message_id=local_id, thread_key=item.thread_key,
                                sender=account.email, recipient=item.sender_email, subject=item.subject,
                                body=failure_body, reply_to=item.message_id, provider_message_id=ses_id, status="sent",
                            )
                        except Exception as reply_exc:
                            self._event(f"Falha ao avisar erro da função para {item.sender_email}: {reply_exc}", "SES", "ERROR")
                    continue

                denied_function = self.function_map.is_command_but_unauthorized(
                    item.sender_email, item.subject, item.body
                )
                if denied_function:
                    self._event(
                        f"NEGADO função={denied_function} remetente={item.sender_email} não autorizado",
                        "AUTH",
                        "WARN",
                    )

                if not self.settings.auto_reply_enabled:
                    self.store.set_inbound_status(account.email, item.message_id, "awaiting-confirmation")
                    self._event(f"AGUARDANDO CONFIRMAÇÃO {item.sender_email} | auto-resposta desativada", "EMAIL", "WARN")
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
                    api_run_id = self.store.add_api_run(
                        kind="email-reply", status="aguardando-resposta",
                        model=self.settings.openai_model,
                        reasoning_effort=self.settings.openai_reasoning_effort,
                        input_path="", output_path="",
                        request_summary=f"Responder e-mail de {item.sender_email}: {self._preview(item.subject or '(sem assunto)', 120)}",
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
                            elapsed_ms=int((time.monotonic() - api_started) * 1000), finished=True,
                        )
                    self.store.set_inbound_status(account.email, item.message_id, "understood")
                    self._event(
                        f"RESPONSE {len(generated_body)} chars | {self._preview(generated_body)}",
                        "GPT",
                    )
                    self.store.set_inbound_status(account.email, item.message_id, "sending")
                    self._event(
                        f"SEND para={item.sender_email} assunto={self._preview(item.subject or '(sem assunto)', 90)}",
                        "SES",
                    )
                    local_id, ses_id = self.ses.send_reply(account, item, generated_body)
                    self.store.add_outbound(
                        account=account.email,
                        message_id=local_id,
                        thread_key=item.thread_key,
                        sender=account.email,
                        recipient=item.sender_email,
                        subject=item.subject,
                        body=generated_body,
                        reply_to=item.message_id,
                        provider_message_id=ses_id,
                        status="sent",
                    )
                    self.store.set_inbound_status(account.email, item.message_id, "replied")
                    state.replied += 1
                    self._event(f"OK para={item.sender_email} MessageId={ses_id}", "SES")
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
        except (imaplib.IMAP4.error, OSError, socket.error, RuntimeError) as exc:
            state.connected = False
            state.last_error = str(exc)
            state.last_check = datetime.now().strftime("%d/%m/%Y %H:%M:%S")
            self._event(f"{account.email}: {exc}", "IMAP", "ERROR")
        finally:
            if conn is not None:
                try:
                    conn.logout()
                except Exception:
                    pass


    def delete_inbound(self, row: dict) -> str:
        if row.get("direction") != "in":
            raise RuntimeError("somente mensagens de entrada podem ser removidas")
        if (row.get("status") or "").lower() in {"analyzing", "understood", "sending", "executing"}:
            raise RuntimeError("a mensagem está em processamento; aguarde terminar antes de remover")
        uid = str(row.get("imap_uid") or "").strip()
        folder = str(row.get("imap_folder") or self.settings.imap_folder).strip()
        if not uid.isdigit():
            raise RuntimeError("esta mensagem não possui UID IMAP; não é possível removê-la do servidor")
        account_email = str(row.get("account_email") or "").lower()
        account = self.accounts_by_email.get(account_email)
        if account is None or not account.enabled:
            raise RuntimeError(f"conta IMAP não disponível para remoção: {account_email}")
        if not self.run_lock.acquire(timeout=15):
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
            self.run_once()
            self.stop_event.wait(self.settings.poll_seconds)
