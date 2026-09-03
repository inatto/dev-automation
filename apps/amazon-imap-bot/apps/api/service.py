from __future__ import annotations

import threading
from datetime import datetime

from api_runner import ApiTestRunner
from monitor import Monitor
from store import Store
from versioning import get_version

PROCESSING_STATUSES = {"analyzing", "understood", "sending", "executing"}


class ServiceError(RuntimeError):
    def __init__(self, status_code: int, message: str):
        super().__init__(message)
        self.status_code = int(status_code)


class BotService:
    def __init__(self, settings, store: Store, monitor: Monitor):
        self.settings = settings
        self.store = store
        self.monitor = monitor
        self.api_runner = ApiTestRunner(settings, store, monitor.on_event)
        self._actions: dict[str, dict] = {}
        self._actions_lock = threading.Lock()

    @staticmethod
    def _action_run_id(action_id: str) -> int | None:
        value = str(action_id or "").strip()
        if not value.startswith("db-"):
            return None
        try:
            return int(value[3:])
        except ValueError:
            return None

    @staticmethod
    def _encode_action_result(value) -> str:
        # Auditoria textual deliberadamente não usa JSON no Oracle.
        if isinstance(value, dict):
            ordered = ("inbound_id", "outbound_id", "api_run_id", "status")
            parts = []
            for key in ordered:
                item = value.get(key)
                if item not in (None, ""):
                    parts.append(f"{key}={item}")
            return "; ".join(parts) or str(value)
        return "" if value is None else str(value)

    @staticmethod
    def _decode_action_result(value: str):
        text = str(value or "").strip()
        if not text:
            return ""
        parsed = {}
        for part in text.split(";"):
            if "=" not in part:
                return text
            key, raw = part.split("=", 1)
            key, raw = key.strip(), raw.strip()
            if not key:
                return text
            parsed[key] = int(raw) if raw.isdigit() else raw
        return parsed or text

    def _action_from_api_run(self, row: dict) -> dict:
        kind = str(row.get("kind") or "")
        if not kind.startswith("action:"):
            raise ServiceError(404, "ação não encontrada")
        return {
            "id": f"db-{int(row['id'])}",
            "kind": kind.split(":", 1)[1],
            "status": str(row.get("status") or "queued"),
            "detail": str(row.get("request_summary") or ""),
            "result": self._decode_action_result(row.get("response_summary") or ""),
            "error": str(row.get("error") or row.get("error_message") or ""),
            "created_at": row.get("started_at") or "",
            "finished_at": row.get("finished_at") or "",
        }

    def _new_action(self, kind: str, detail: str = "") -> dict:
        # A ação precisa existir no Oracle ANTES de devolver HTTP 202.
        # Assim polling, múltiplos workers e reinícios não perdem o job.
        try:
            run_id = self.store.add_api_run(
                kind=f"action:{kind}",
                status="queued",
                model=self.settings.openai_model,
                reasoning_effort=self.settings.openai_reasoning_effort,
                input_path="",
                output_path="",
                request_summary=detail,
                request_payload="",
            )
        except Exception as exc:
            raise ServiceError(503, f"não foi possível registrar a ação no Oracle: {exc}") from exc
        action = {
            "id": f"db-{run_id}",
            "kind": kind,
            "status": "queued",
            "detail": detail,
            "result": "",
            "error": "",
            "created_at": datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
            "finished_at": "",
        }
        with self._actions_lock:
            self._actions[action["id"]] = action
        return dict(action)

    def _update_action(self, action_id: str, **values) -> None:
        with self._actions_lock:
            if action_id in self._actions:
                self._actions[action_id].update(values)
        run_id = self._action_run_id(action_id)
        if run_id is None:
            return
        kwargs = {}
        if "status" in values:
            kwargs["status"] = values["status"]
        if "result" in values:
            kwargs["response_summary"] = self._encode_action_result(values["result"])
        if "error" in values:
            kwargs["error"] = str(values["error"] or "")
        if values.get("finished_at") or values.get("status") in {"completed", "error"}:
            kwargs["finished"] = True
        if kwargs:
            self.store.update_api_run(run_id, **kwargs)

    def _run_action(self, action: dict, callback) -> None:
        def target():
            self._update_action(action["id"], status="running")
            try:
                result = callback()
                self._update_action(
                    action["id"], status="completed", result=result if result is not None else "",
                    finished_at=datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
                )
            except Exception as exc:
                self._update_action(
                    action["id"], status="error", error=str(exc),
                    finished_at=datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
                )
        threading.Thread(target=target, name=f"amazon-imap-action-{action['kind']}", daemon=True).start()

    def actions(self) -> list[dict]:
        # Oracle é a fonte de verdade da fila. O cache em memória é apenas otimização.
        rows = self.store.list_api_runs(1000)
        result = []
        for row in rows:
            if str(row.get("kind") or "").startswith("action:"):
                result.append(self._action_from_api_run(row))
                if len(result) >= 300:
                    break
        return result

    def action(self, action_id: str) -> dict:
        with self._actions_lock:
            item = self._actions.get(str(action_id))
            if item is not None:
                return dict(item)
        run_id = self._action_run_id(action_id)
        if run_id is None:
            raise ServiceError(404, "ação não encontrada")
        row = self.store.get_api_run(run_id)
        if row is None:
            raise ServiceError(404, "ação não encontrada")
        return self._action_from_api_run(row)

    def accounts(self) -> list[dict]:
        return [
            {
                "email": email,
                "connected": state.connected,
                "last_check": state.last_check,
                "last_error": state.last_error,
                "received": state.received,
                "replied": state.replied,
            }
            for email, state in self.monitor.states.items()
        ]

    def overview(self) -> dict:
        accounts = self.accounts()
        inbound = self.store.list_messages("in", 500)
        outbound = self.store.list_messages("out", 500)
        control = self.store.get_control()
        return {
            "service": "amazon-imap-bot",
            "version": get_version(),
            "server_time": datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
            "running": not self.monitor.stop_event.is_set(),
            "checking": self.monitor.run_lock.locked(),
            "online_accounts": sum(1 for item in accounts if item["connected"]),
            "account_count": len(accounts),
            "account_errors": sum(1 for item in accounts if item["last_error"]),
            "received": len(inbound),
            "replied": sum(1 for row in outbound if str(row.get("status") or "").lower() == "sent"),
            "pending_approvals": self.store.count_pending_approvals(),
            "approved_waiting_global": self.store.count_approved_waiting_global(),
            "pending_deletes": self.store.count_pending_deletes(),
            "processing_messages": sum(1 for row in inbound if str(row.get("status") or "").lower() in PROCESSING_STATUSES),
            "active_actions": sum(1 for item in self.actions() if item["status"] in {"queued", "running"}),
            "external_send_enabled": bool(control.get("external_send_enabled")),
            "poll_seconds": self.settings.poll_seconds,
            "model": self.settings.openai_model,
            "reasoning": self.settings.openai_reasoning_effort,
            "imap_host": self.settings.imap_host,
            "imap_folder": self.settings.imap_folder,
        }

    def message(self, message_id: int) -> dict:
        row = self.store.get_message(int(message_id))
        if row is None:
            raise ServiceError(404, "mensagem não encontrada")
        return row

    def messages(self, direction: str, limit: int) -> list[dict]:
        direction = str(direction or "in").lower()
        if direction not in {"in", "out"}:
            raise ServiceError(400, "direction deve ser in ou out")
        return self.store.list_messages(direction, max(1, min(2000, int(limit))))

    def events(self, limit: int) -> list[dict]:
        return self.store.recent_events(max(1, min(5000, int(limit))))

    def api_runs(self, limit: int) -> list[dict]:
        # Jobs internos action:* sustentam o polling, mas não poluem o histórico OpenAI.
        wanted = max(1, min(1000, int(limit)))
        rows = self.store.list_api_runs(min(1000, max(wanted * 4, wanted)))
        return [row for row in rows if not str(row.get("kind") or "").startswith("action:")][:wanted]

    def api_run(self, run_id: int) -> dict:
        row = self.store.get_api_run(int(run_id))
        if row is None:
            raise ServiceError(404, "execução de API não encontrada")
        return row

    def functions(self) -> dict:
        try:
            payload = self.monitor.function_map.catalog_payload(refresh=True)
        except Exception as exc:
            raise ServiceError(503, f"catálogo Oracle indisponível: {exc}") from exc
        return {**payload, "available": True}

    def sync_functions(self) -> dict:
        action = self._new_action("functions-sync", "Recarga do catálogo de funções Oracle")
        self._run_action(action, lambda: self.monitor.function_map.catalog_summary_text(refresh=True))
        return action

    def refresh(self) -> dict:
        action = self._new_action("refresh", "Verificação IMAP solicitada pela Web")
        self._run_action(action, lambda: self.monitor.run_once() or "verificação concluída")
        return action

    def context_files(self, relative_path: str = "") -> dict:
        try:
            return self.monitor.reply_context.browse(relative_path)
        except (ValueError, FileNotFoundError) as exc:
            raise ServiceError(400, str(exc)) from exc

    @staticmethod
    def _files(body: dict) -> list[str]:
        raw = body.get("files") or []
        if not isinstance(raw, list):
            raise ServiceError(400, "files deve ser uma lista")
        values: list[str] = []
        for item in raw:
            value = str(item or "").strip()
            if value and value not in values:
                values.append(value)
        return values

    def generate_reply(self, message_id: int, body: dict) -> dict:
        row = self.message(message_id)
        instruction = str(body.get("instruction") or "").strip()
        files = self._files(body)

        # Falhas determinísticas são devolvidas antes do 202. Assim a Web nunca
        # afirma que enfileirou uma resposta que já sabemos que não pode rodar.
        try:
            self.monitor.validate_reply_generation(row, manual_force=True)
        except RuntimeError as exc:
            raise ServiceError(409, str(exc)) from exc

        action = self._new_action(
            "reply-compose",
            f"message_id={message_id} arquivos={len(files)} instrução={instruction[:180] or '[padrão]'}",
        )
        def callback():
            return self.monitor.generate_or_regenerate_reply(
                row, instruction=instruction, context_files=files, requested_by="web", manual_force=True
            )
        self._run_action(action, callback)
        return action

    def approve(self, message_id: int) -> dict:
        try:
            return self.monitor.approve_outbound(self.message(message_id), approved_by="web")
        except RuntimeError as exc:
            raise ServiceError(409, str(exc)) from exc

    def no_reply(self, message_id: int) -> dict:
        try:
            return self.monitor.suppress_inbound_reply(self.message(message_id), suppressed_by="web")
        except RuntimeError as exc:
            raise ServiceError(409, str(exc)) from exc

    def delete(self, message_id: int) -> dict:
        row = self.message(message_id)
        try:
            pending = self.monitor.queue_delete_inbound(row)
        except RuntimeError as exc:
            raise ServiceError(409, str(exc)) from exc
        return {"queued": True, "message_id": int(message_id), "pending_deletes": pending}

    def external_delivery(self) -> dict:
        return self.store.get_control()

    def set_external_delivery(self, enabled: bool) -> dict:
        activated = self.monitor.set_external_send_enabled(bool(enabled), updated_by="web")
        return {**self.store.get_control(), "activated": activated}

    def run_zip_test(self, body: dict) -> dict:
        effort = str(body.get("reasoning_effort") or self.settings.openai_reasoning_effort)
        request_text = str(body.get("request_text") or "").strip()
        action = self._new_action("api-zip-test", request_text[:300])
        self._run_action(
            action,
            lambda: f"api_run_id={self.api_runner.run_zip_test(reasoning_effort=effort, request_text=request_text, source='web')}",
        )
        return action
