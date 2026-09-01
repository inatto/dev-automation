from __future__ import annotations

import hashlib
import threading
import time
from copy import deepcopy
from datetime import datetime
from pathlib import Path
from typing import Any, Callable

from diagnostics import trace


def _now_text() -> str:
    return datetime.now().strftime("%Y-%m-%d %H:%M:%S")


def _parse_dt(value: str | datetime | None) -> datetime | None:
    if value in (None, ""):
        return None
    if isinstance(value, datetime):
        return value
    text = str(value).strip()
    if not text:
        return None
    try:
        return datetime.fromisoformat(text.replace("Z", "+00:00")).replace(tzinfo=None)
    except ValueError:
        try:
            return datetime.strptime(text[:19], "%Y-%m-%d %H:%M:%S")
        except ValueError:
            return None


def _message_key(message_id: str) -> str:
    return hashlib.sha256(str(message_id or "").encode("utf-8")).hexdigest()


def _as_text(value: Any) -> Any:
    if value is None:
        return None
    if isinstance(value, datetime):
        return value.strftime("%Y-%m-%d %H:%M:%S")
    reader = getattr(value, "read", None)
    if callable(reader):
        return str(reader())
    return value


class _MemoryStore:
    """Backend sem SQLite usado apenas por testes/unitários locais."""

    def __init__(self):
        self._lock = threading.RLock()
        self.messages: list[dict] = []
        self.events: list[dict] = []
        self.api_runs: list[dict] = []
        self.mailbox_states: dict[tuple[str, str], dict] = {}
        self.control = {
            "external_send_enabled": False,
            "external_require_approval": True,
            "updated_at": _now_text(),
            "updated_by": "memory",
        }
        self.allowed_recipients = {"danielmaiax@gmail.com"}
        self._next_message_id = 1
        self._next_event_id = 1
        self._next_api_id = 1

    def close(self) -> None:
        return None

    def seen(self, account: str, message_id: str) -> bool:
        key = _message_key(message_id)
        with self._lock:
            return any(
                row["direction"] == "in"
                and row["account_email"].lower() == account.lower()
                and row["message_key"] == key
                for row in self.messages
            )

    def get_inbound_by_uid(self, account: str, folder: str, uid_validity: str, uid: str) -> dict | None:
        with self._lock:
            for row in self.messages:
                if (
                    row["direction"] == "in"
                    and row["account_email"].lower() == account.lower()
                    and str(row.get("imap_folder") or "") == str(folder)
                    and str(row.get("imap_uid_validity") or "") == str(uid_validity)
                    and str(row.get("imap_uid") or "") == str(uid)
                ):
                    return deepcopy(row)
        return None

    def touch_inbound_uid(self, message_row_id: int) -> None:
        with self._lock:
            row = self._message(message_row_id)
            row["imap_present"] = 1
            row["imap_last_seen_at"] = _now_text()
            if row.get("delete_mode") == "imap-sync-missing":
                row["deleted_at"] = None
                row["delete_mode"] = None

    def list_inbound_uid_index(self, account: str, folder: str, uid_validity: str) -> dict[str, dict]:
        with self._lock:
            return {
                str(row.get("imap_uid") or ""): deepcopy(row)
                for row in self.messages
                if row["direction"] == "in"
                and row["account_email"].lower() == account.lower()
                and str(row.get("imap_folder") or "") == str(folder)
                and str(row.get("imap_uid_validity") or "") == str(uid_validity)
                and row.get("imap_uid") not in (None, "")
            }

    def add_inbound(
        self, *, account: str, message_id: str, thread_key: str, sender: str,
        recipient: str, subject: str, body: str, status: str, mail_date: str = "",
        imap_uid: str = "", imap_folder: str = "", imap_uid_validity: str = "",
        references: str = "",
    ) -> int:
        key = _message_key(message_id)
        with self._lock:
            existing = next((
                row for row in self.messages
                if row["direction"] == "in" and row["account_email"].lower() == account.lower()
                and row["message_key"] == key
            ), None)
            if existing:
                existing.update({
                    "thread_key": thread_key, "sender": sender, "recipient": recipient,
                    "subject": subject, "body": body, "mail_date": mail_date,
                    "imap_uid": str(imap_uid), "imap_folder": imap_folder,
                    "imap_uid_validity": str(imap_uid_validity), "imap_present": 1,
                    "imap_last_seen_at": _now_text(), "b_references": references,
                    "deleted_at": None, "delete_mode": None,
                })
                return int(existing["id"])
            row = {
                "id": self._next_message_id, "direction": "in", "account_email": account,
                "message_id": message_id, "message_key": key, "thread_key": thread_key,
                "sender": sender, "recipient": recipient, "subject": subject, "body": body,
                "reply_to_message_id": None, "provider_message_id": None, "status": status,
                "error": "", "created_at": _now_text(), "mail_date": mail_date,
                "imap_uid": str(imap_uid), "imap_folder": imap_folder,
                "imap_uid_validity": str(imap_uid_validity), "imap_present": 1,
                "imap_last_seen_at": _now_text(), "deleted_at": None, "delete_mode": None,
                "recipient_class": None, "approval_required": 0, "approved_at": None,
                "approved_by": None, "send_queued_at": None, "sent_at": None,
                "b_references": references,
                "reply_suppressed": 0, "reply_suppressed_at": None, "reply_suppressed_by": None,
            }
            self._next_message_id += 1
            self.messages.append(row)
            return int(row["id"])

    def add_outbound(
        self, *, account: str, message_id: str, thread_key: str, sender: str,
        recipient: str, subject: str, body: str, reply_to: str,
        provider_message_id: str, status: str, error: str = "", mail_date: str = "",
        references: str = "", recipient_class: str = "external",
        approval_required: bool = False, approved_at: str | None = None,
        approved_by: str = "",
    ) -> int:
        key = _message_key(message_id)
        with self._lock:
            existing = next((
                row for row in self.messages
                if row["direction"] == "out" and row["account_email"].lower() == account.lower()
                and row["message_key"] == key
            ), None)
            if existing:
                return int(existing["id"])
            row = {
                "id": self._next_message_id, "direction": "out", "account_email": account,
                "message_id": message_id, "message_key": key, "thread_key": thread_key,
                "sender": sender, "recipient": recipient, "subject": subject, "body": body,
                "reply_to_message_id": reply_to, "provider_message_id": provider_message_id,
                "status": status, "error": error, "created_at": _now_text(),
                "mail_date": mail_date or _now_text(), "imap_uid": None, "imap_folder": None,
                "imap_uid_validity": None, "imap_present": 1, "imap_last_seen_at": None,
                "deleted_at": None, "delete_mode": None, "recipient_class": recipient_class,
                "approval_required": 1 if approval_required else 0,
                "approved_at": approved_at, "approved_by": approved_by or None,
                "send_queued_at": _now_text() if status == "send-queued" else None,
                "sent_at": _now_text() if status == "sent" else None,
                "b_references": references,
                "reply_suppressed": 0, "reply_suppressed_at": None, "reply_suppressed_by": None,
            }
            self._next_message_id += 1
            self.messages.append(row)
            return int(row["id"])

    def set_inbound_status(self, account: str, message_id: str, status: str) -> None:
        key = _message_key(message_id)
        with self._lock:
            for row in self.messages:
                if row["direction"] == "in" and row["account_email"].lower() == account.lower() and row["message_key"] == key:
                    if int(row.get("reply_suppressed") or 0) == 1:
                        row["status"] = "no-reply"
                        row["error"] = ""
                        return
                    row["status"] = status
                    row["error"] = ""
                    return

    def set_message_status(self, message_row_id: int, status: str, error: str = "") -> None:
        with self._lock:
            row = self._message(message_row_id)
            if row["direction"] != "in" or row.get("deleted_at"):
                raise RuntimeError("mensagem não encontrada ou já removida")
            row["status"] = status
            row["error"] = error

    def set_outbound_status(self, message_row_id: int, status: str, error: str = "", provider_message_id: str | None = None) -> None:
        with self._lock:
            row = self._message(message_row_id)
            if row["direction"] != "out":
                raise RuntimeError("resposta não encontrada")
            row["status"] = status
            row["error"] = error
            if provider_message_id is not None:
                row["provider_message_id"] = provider_message_id
            if status == "send-queued":
                row["send_queued_at"] = _now_text()
            if status == "sent":
                row["sent_at"] = _now_text()

    def is_inbound_reply_suppressed(self, account: str, message_id: str) -> bool:
        key = _message_key(message_id)
        with self._lock:
            row = next((
                r for r in self.messages
                if r["direction"] == "in" and r["account_email"].lower() == account.lower()
                and r["message_key"] == key and not r.get("deleted_at")
            ), None)
            return bool(row and int(row.get("reply_suppressed") or 0) == 1)

    def suppress_inbound_reply(self, message_row_id: int, suppressed_by: str = "tui") -> dict:
        with self._lock:
            row = self._message(message_row_id)
            if row["direction"] != "in" or row.get("deleted_at"):
                raise RuntimeError("mensagem de entrada não encontrada")
            linked = [
                r for r in self.messages
                if r["direction"] == "out" and not r.get("deleted_at")
                and str(r.get("reply_to_message_id") or "") == str(row.get("message_id") or "")
            ]
            if any(str(r.get("status") or "") in {"sending", "sent"} for r in linked):
                raise RuntimeError("a resposta já está sendo enviada ou já foi enviada; não é mais possível marcar como não responder")
            cancelled = 0
            for reply in linked:
                if str(reply.get("status") or "") in {"pending-approval", "approved-waiting-global", "send-queued", "send-error"}:
                    reply["status"] = "cancelled-no-reply"
                    reply["error"] = ""
                    cancelled += 1
            row["reply_suppressed"] = 1
            row["reply_suppressed_at"] = _now_text()
            row["reply_suppressed_by"] = suppressed_by
            row["status"] = "no-reply"
            row["error"] = ""
            result = deepcopy(row)
            result["cancelled_replies"] = cancelled
            return result

    def count_pending_deletes(self) -> int:
        with self._lock:
            return sum(1 for row in self.messages if row["direction"] == "in" and not row.get("deleted_at") and row["status"] in {"delete-queued", "deleting"})

    def list_pending_deletes(self) -> list[dict]:
        with self._lock:
            return [deepcopy(row) for row in sorted(self.messages, key=lambda r: r["id"]) if row["direction"] == "in" and not row.get("deleted_at") and row["status"] in {"delete-queued", "deleting"}]

    def mark_deleted(self, message_row_id: int, delete_mode: str) -> None:
        with self._lock:
            row = self._message(message_row_id)
            if row["direction"] != "in" or row.get("deleted_at"):
                raise RuntimeError("mensagem não encontrada ou já removida")
            row["deleted_at"] = _now_text()
            row["delete_mode"] = delete_mode
            row["imap_present"] = 0
            row["error"] = ""

    def reconcile_inbox(self, account: str, folder: str, uid_validity: str, present_uids: set[str]) -> int:
        removed = 0
        with self._lock:
            for row in self.messages:
                if row["direction"] != "in" or row["account_email"].lower() != account.lower() or str(row.get("imap_folder") or "") != str(folder):
                    continue
                if row.get("deleted_at") and row.get("delete_mode") != "imap-sync-missing":
                    continue
                same_validity = str(row.get("imap_uid_validity") or "") == str(uid_validity)
                present = same_validity and str(row.get("imap_uid") or "") in present_uids
                if present:
                    row["imap_present"] = 1
                    row["imap_last_seen_at"] = _now_text()
                    if row.get("delete_mode") == "imap-sync-missing":
                        row["deleted_at"] = None
                        row["delete_mode"] = None
                elif row.get("imap_present", 1):
                    row["imap_present"] = 0
                    row["deleted_at"] = _now_text()
                    row["delete_mode"] = "imap-sync-missing"
                    removed += 1
        return removed

    def get_mailbox_state(self, account: str, folder: str) -> dict | None:
        with self._lock:
            row = self.mailbox_states.get((account.lower(), folder))
            return deepcopy(row) if row else None

    def set_mailbox_state(self, account: str, folder: str, uid_validity: str, last_max_uid: int, initialized: bool = True) -> None:
        with self._lock:
            key = (account.lower(), folder)
            old = self.mailbox_states.get(key)
            self.mailbox_states[key] = {
                "account_email": account, "imap_folder": folder, "uid_validity": str(uid_validity),
                "last_max_uid": int(last_max_uid), "initialized": 1 if initialized else 0,
                "initial_sync_at": old.get("initial_sync_at") if old else _now_text(),
                "last_sync_at": _now_text(),
            }

    def add_event(self, category: str, level: str, text: str) -> None:
        with self._lock:
            self.events.append({"id": self._next_event_id, "category": category, "level": level, "text": text, "created_at": _now_text()})
            self._next_event_id += 1
            self.events = self.events[-5000:]

    def list_messages(self, direction: str, limit: int = 500) -> list[dict]:
        if direction not in {"in", "out"}:
            raise ValueError("direction inválida")
        with self._lock:
            rows = [row for row in self.messages if row["direction"] == direction and not row.get("deleted_at")]
            if direction == "in":
                rows = [row for row in rows if row.get("imap_present", 1)]
            return [deepcopy(row) for row in sorted(rows, key=lambda r: r["id"], reverse=True)[:limit]]

    def get_message(self, message_id: int) -> dict | None:
        with self._lock:
            try:
                return deepcopy(self._message(message_id))
            except RuntimeError:
                return None

    def recent_events(self, limit: int = 500) -> list[dict]:
        with self._lock:
            return [deepcopy(row) for row in sorted(self.events, key=lambda r: r["id"], reverse=True)[:limit]]

    def recent(self, limit: int = 12) -> list[tuple]:
        return [(row["id"], row["direction"], row["account_email"], row["sender"], row["recipient"], row["subject"], row["status"], row["created_at"]) for row in self.list_messages("in", limit)]

    def add_api_run(self, *, kind: str, status: str, model: str, reasoning_effort: str, input_path: str,
                    output_path: str, request_summary: str, request_payload: str = "", request_bytes: int = 0,
                    input_file_bytes: int = 0, input_file_count: int = 0, listed_item_count: int = 0) -> int:
        with self._lock:
            row = {
                "id": self._next_api_id, "kind": kind, "status": status, "model": model,
                "reasoning_effort": reasoning_effort, "input_path": input_path, "output_path": output_path,
                "response_id": "", "request_summary": request_summary, "response_summary": "", "error": "",
                "elapsed_ms": None, "started_at": _now_text(), "finished_at": None,
                "request_payload": request_payload, "request_bytes": request_bytes,
                "input_file_bytes": input_file_bytes, "input_file_count": input_file_count,
                "listed_item_count": listed_item_count, "response_bytes": 0, "output_file_bytes": 0,
                "output_file_count": 0,
            }
            self._next_api_id += 1
            self.api_runs.append(row)
            return int(row["id"])

    def update_api_run(self, run_id: int, *, status: str | None = None, output_path: str | None = None,
                       response_id: str | None = None, request_summary: str | None = None,
                       response_summary: str | None = None, error: str | None = None,
                       elapsed_ms: int | None = None, finished: bool = False,
                       request_payload: str | None = None, request_bytes: int | None = None,
                       input_file_bytes: int | None = None, input_file_count: int | None = None,
                       listed_item_count: int | None = None, response_bytes: int | None = None,
                       output_file_bytes: int | None = None, output_file_count: int | None = None) -> None:
        with self._lock:
            row = next((r for r in self.api_runs if r["id"] == run_id), None)
            if not row:
                raise RuntimeError("execução de API não encontrada")
            values = locals()
            for key in ("status", "output_path", "response_id", "request_summary", "response_summary", "error", "elapsed_ms", "request_payload", "request_bytes", "input_file_bytes", "input_file_count", "listed_item_count", "response_bytes", "output_file_bytes", "output_file_count"):
                if values[key] is not None:
                    row[key] = values[key]
            if finished:
                row["finished_at"] = _now_text()

    def list_api_runs(self, limit: int = 200) -> list[dict]:
        with self._lock:
            return [deepcopy(row) for row in sorted(self.api_runs, key=lambda r: r["id"], reverse=True)[:limit]]

    def get_api_run(self, run_id: int) -> dict | None:
        with self._lock:
            row = next((r for r in self.api_runs if r["id"] == run_id), None)
            return deepcopy(row) if row else None

    def get_tui_header(self) -> dict:
        with self._lock:
            return {
                "external_send_enabled": bool(self.control.get("external_send_enabled")),
                "pending_deletes": sum(1 for r in self.messages if r["direction"] == "in" and not r.get("deleted_at") and r.get("status") in {"delete-queued", "deleting"}),
                "pending_approvals": sum(1 for r in self.messages if r["direction"] == "out" and not r.get("deleted_at") and r.get("status") == "pending-approval"),
                "approved_waiting_global": sum(1 for r in self.messages if r["direction"] == "out" and not r.get("deleted_at") and r.get("status") == "approved-waiting-global"),
            }

    def get_control(self) -> dict:
        with self._lock:
            return deepcopy(self.control)

    def set_external_send_enabled(self, enabled: bool, updated_by: str = "tui") -> None:
        with self._lock:
            self.control["external_send_enabled"] = bool(enabled)
            self.control["updated_at"] = _now_text()
            self.control["updated_by"] = updated_by

    def is_always_allowed_recipient(self, email: str) -> bool:
        with self._lock:
            return str(email or "").strip().lower() in self.allowed_recipients

    def count_pending_approvals(self) -> int:
        with self._lock:
            return sum(1 for row in self.messages if row["direction"] == "out" and not row.get("deleted_at") and row["status"] == "pending-approval")

    def count_approved_waiting_global(self) -> int:
        with self._lock:
            return sum(1 for row in self.messages if row["direction"] == "out" and not row.get("deleted_at") and row["status"] == "approved-waiting-global")

    def approve_outbound(self, message_row_id: int, approved_by: str = "tui") -> dict:
        with self._lock:
            row = self._message(message_row_id)
            if row["direction"] != "out":
                raise RuntimeError("somente respostas podem ser liberadas")
            if not row.get("approval_required"):
                raise RuntimeError("esta resposta não exige liberação manual")
            if row["status"] not in {"pending-approval", "approved-waiting-global"}:
                raise RuntimeError(f"resposta não está pendente de liberação: {row['status']}")
            row["approved_at"] = row.get("approved_at") or _now_text()
            row["approved_by"] = approved_by
            if self.control["external_send_enabled"]:
                row["status"] = "send-queued"
                row["send_queued_at"] = _now_text()
            else:
                row["status"] = "approved-waiting-global"
            return deepcopy(row)

    def list_send_queue(self) -> list[dict]:
        with self._lock:
            return [deepcopy(row) for row in sorted(self.messages, key=lambda r: r["id"]) if row["direction"] == "out" and not row.get("deleted_at") and row["status"] in {"send-queued", "sending"}]

    def activate_approved_waiting(self) -> list[int]:
        with self._lock:
            if not self.control["external_send_enabled"]:
                return []
            ids = []
            for row in self.messages:
                if row["direction"] == "out" and row["status"] == "approved-waiting-global" and row.get("approved_at"):
                    row["status"] = "send-queued"
                    row["send_queued_at"] = _now_text()
                    ids.append(int(row["id"]))
            return ids

    def _message(self, message_row_id: int) -> dict:
        row = next((r for r in self.messages if int(r["id"]) == int(message_row_id)), None)
        if row is None:
            raise RuntimeError("mensagem não encontrada")
        return row


class _OracleStore:
    def __init__(self, database, log: Callable[[str], None] | None = None):
        self.database = database
        self.log = log or (lambda text: None)
        self.schema = str(database.schema or "").strip().upper()
        if not self.schema:
            raise RuntimeError("DB_SCHEMA ausente em database.env")
        try:
            import oracledb
        except ImportError as exc:
            raise RuntimeError("dependência oracledb não instalada") from exc
        self.oracledb = oracledb
        self._cache_lock = threading.RLock()
        self._cache: dict[tuple, tuple[float, Any]] = {}
        dsn = str(database.jdbc_url or "").strip()
        prefix = "jdbc:oracle:thin:@"
        if dsn.lower().startswith(prefix):
            dsn = dsn[len(prefix):]
        if not dsn:
            raise RuntimeError("DB_JDBC_URL ausente em database.env")
        kwargs: dict[str, Any] = {
            "user": database.user,
            "password": database.password,
            "dsn": dsn,
            "min": 1,
            "max": 4,
            "increment": 1,
            "tcp_connect_timeout": float(database.connect_timeout_seconds),
            "retry_count": int(database.retry_count),
            "retry_delay": int(database.retry_delay_seconds),
        }
        if database.tns_admin:
            wallet = str(database.tns_admin)
            kwargs["config_dir"] = wallet
            kwargs["wallet_location"] = wallet
        if str(database.wallet_password or "").strip():
            kwargs["wallet_password"] = database.wallet_password
        self.log(f"Oracle Store: abrindo pool schema={self.schema} dsn={dsn}...")
        self.pool = oracledb.create_pool(**kwargs)
        required_tables = (
            "IMAP_BOT_MESSAGES",
            "IMAP_BOT_EVENTS",
            "IMAP_BOT_API_RUNS",
            "IMAP_BOT_CONTROL",
            "IMAP_BOT_ALWAYS_ALLOWED_RECIPIENTS",
            "IMAP_BOT_MAILBOX_STATE",
        )
        with self.pool.acquire() as conn:
            cur = conn.cursor()
            try:
                for table in required_tables:
                    self.log(f"Oracle Store: verificando {self.schema}.{table}...")
                    cur.execute(f"SELECT 1 FROM {self.schema}.{table} WHERE 1=0")
                self.log(f"Oracle Store: verificando colunas de controle de resposta em {self.schema}.IMAP_BOT_MESSAGES...")
                try:
                    cur.execute(
                        f"SELECT reply_suppressed,reply_suppressed_at,reply_suppressed_by "
                        f"FROM {self.schema}.IMAP_BOT_MESSAGES WHERE 1=0"
                    )
                except Exception as exc:
                    raise RuntimeError(
                        "IMAP_BOT_MESSAGES ainda não possui as colunas REPLY_SUPPRESSED/REPLY_SUPPRESSED_AT/"
                        "REPLY_SUPPRESSED_BY; execute o patch SQL de não-resposta fornecido"
                    ) from exc
                cur.execute(f"SELECT COUNT(*) FROM {self.schema}.IMAP_BOT_CONTROL WHERE control_key='DEFAULT'")
                if int(cur.fetchone()[0]) != 1:
                    raise RuntimeError("IMAP_BOT_CONTROL/DEFAULT ausente; execute o patch SQL fornecido")
            finally:
                cur.close()
        self.log("Oracle Store: pool OK; armazenamento operacional no Oracle.")

    def close(self) -> None:
        try:
            self.pool.close(force=False)
        except Exception as exc:
            trace(f"Oracle Store: fechamento normal falhou: {exc}; usando force após workers encerrados")
            try:
                self.pool.close(force=True)
            except Exception:
                pass

    def _invalidate_cache(self, *prefixes: str) -> None:
        with self._cache_lock:
            if not prefixes:
                self._cache.clear()
                return
            doomed = [key for key in self._cache if key and str(key[0]) in prefixes]
            for key in doomed:
                self._cache.pop(key, None)

    def _cached(self, key: tuple, loader, ttl: float = 1.50):
        now = time.monotonic()
        with self._cache_lock:
            cached = self._cache.get(key)
            if cached and now - cached[0] <= ttl:
                return deepcopy(cached[1])
        value = loader()
        loaded_at = time.monotonic()
        with self._cache_lock:
            self._cache[key] = (loaded_at, deepcopy(value))
        return value

    def _fetchall(self, sql: str, binds: dict | None = None) -> list[dict]:
        started = time.monotonic()
        compact_sql = " ".join(str(sql).split())
        with self.pool.acquire() as conn:
            cur = conn.cursor()
            try:
                try:
                    cur.execute(sql, binds or {})
                except Exception as exc:
                    trace(
                        f"ORACLE READ ERROR {type(exc).__name__}: {exc} | "
                        f"SQL={compact_sql[:1800]} | binds={','.join(sorted((binds or {}).keys())) or '-'}"
                    )
                    raise
                names = [str(col[0]).lower() for col in cur.description or []]
                rows = [{names[i]: _as_text(value) for i, value in enumerate(row)} for row in cur.fetchall()]
                elapsed = time.monotonic() - started
                trace(f"ORACLE READ {elapsed:.3f}s rows={len(rows)} sql={compact_sql[:320]}")
                return rows
            finally:
                cur.close()

    def _fetchone(self, sql: str, binds: dict | None = None) -> dict | None:
        rows = self._fetchall(sql, binds)
        return rows[0] if rows else None

    def _execute(self, sql: str, binds: dict | None = None) -> int:
        started = time.monotonic()
        compact_sql = " ".join(str(sql).split())
        with self.pool.acquire() as conn:
            cur = conn.cursor()
            try:
                try:
                    cur.execute(sql, binds or {})
                except Exception as exc:
                    trace(
                        f"ORACLE WRITE ERROR {type(exc).__name__}: {exc} | "
                        f"SQL={compact_sql[:1800]} | binds={','.join(sorted((binds or {}).keys())) or '-'}"
                    )
                    raise
                count = int(cur.rowcount or 0)
                conn.commit()
                self._invalidate_cache()
                trace(f"ORACLE WRITE {time.monotonic()-started:.3f}s rows={count} sql={compact_sql[:320]}")
                return count
            finally:
                cur.close()

    @staticmethod
    def _message_select() -> str:
        return (
            "id,direction,account_email,message_id,message_key,thread_key,"
            "sender_email AS \"sender\",recipient_email AS \"recipient\",subject,body,"
            "reply_to_message_id,provider_message_id,status,error_message AS \"error\","
            "created_at,mail_date,imap_uid,imap_folder,imap_uid_validity,imap_present,"
            "imap_last_seen_at,deleted_at,delete_mode,recipient_class,approval_required,"
            "approved_at,approved_by,send_queued_at,sent_at,references_header AS \"references\","
            "reply_suppressed,reply_suppressed_at,reply_suppressed_by"
        )

    def seen(self, account: str, message_id: str) -> bool:
        row = self._fetchone(
            f"SELECT 1 AS \"found\" FROM {self.schema}.IMAP_BOT_MESSAGES "
            "WHERE direction='in' AND LOWER(account_email)=LOWER(:account) AND message_key=:message_key FETCH FIRST 1 ROW ONLY",
            {"account": account, "message_key": _message_key(message_id)},
        )
        return row is not None

    def get_inbound_by_uid(self, account: str, folder: str, uid_validity: str, uid: str) -> dict | None:
        return self._fetchone(
            f"SELECT {self._message_select()} FROM {self.schema}.IMAP_BOT_MESSAGES "
            "WHERE direction='in' AND LOWER(account_email)=LOWER(:account) AND imap_folder=:folder "
            "AND imap_uid_validity=:b_uid_validity AND imap_uid=:b_imap_uid FETCH FIRST 1 ROW ONLY",
            {"account": account, "folder": folder, "b_uid_validity": int(uid_validity or 0), "b_imap_uid": int(uid)},
        )

    def list_inbound_uid_index(self, account: str, folder: str, uid_validity: str) -> dict[str, dict]:
        rows = self._fetchall(
            f"SELECT id,imap_uid,imap_present,delete_mode,deleted_at,status FROM {self.schema}.IMAP_BOT_MESSAGES "
            "WHERE direction='in' AND LOWER(account_email)=LOWER(:b_account) AND imap_folder=:b_folder "
            "AND imap_uid_validity=:b_uid_validity",
            {"b_account": account, "b_folder": folder, "b_uid_validity": int(uid_validity or 0)},
        )
        return {str(row.get("imap_uid") or ""): row for row in rows if row.get("imap_uid") not in (None, "")}

    def touch_inbound_uid(self, message_row_id: int) -> None:
        self._execute(
            f"UPDATE {self.schema}.IMAP_BOT_MESSAGES SET imap_present=1, imap_last_seen_at=SYSTIMESTAMP, "
            "deleted_at=CASE WHEN delete_mode='imap-sync-missing' THEN NULL ELSE deleted_at END, "
            "delete_mode=CASE WHEN delete_mode='imap-sync-missing' THEN NULL ELSE delete_mode END, updated_at=SYSTIMESTAMP "
            "WHERE id=:id AND direction='in'",
            {"id": int(message_row_id)},
        )

    def add_inbound(
        self, *, account: str, message_id: str, thread_key: str, sender: str,
        recipient: str, subject: str, body: str, status: str, mail_date: str = "",
        imap_uid: str = "", imap_folder: str = "", imap_uid_validity: str = "",
        references: str = "",
    ) -> int:
        binds = {
            "account": account, "message_id": message_id, "message_key": _message_key(message_id),
            "thread_key": thread_key, "sender": sender, "recipient": recipient, "subject": subject,
            "body": body, "status": status, "mail_date": _parse_dt(mail_date),
            "imap_uid": int(imap_uid) if str(imap_uid).isdigit() else None,
            "imap_folder": imap_folder, "uid_validity": int(imap_uid_validity) if str(imap_uid_validity).isdigit() else 0,
            "b_references": references,
        }
        self._execute(
            f"MERGE INTO {self.schema}.IMAP_BOT_MESSAGES t USING (SELECT :account account_email,:message_key message_key FROM dual) s "
            "ON (t.direction='in' AND LOWER(t.account_email)=LOWER(s.account_email) AND t.message_key=s.message_key) "
            "WHEN MATCHED THEN UPDATE SET thread_key=:thread_key,sender_email=:sender,recipient_email=:recipient,"
            "subject=:subject,body=:body,mail_date=:mail_date,imap_uid=:imap_uid,imap_folder=:imap_folder,"
            "imap_uid_validity=:uid_validity,imap_present=1,imap_last_seen_at=SYSTIMESTAMP,references_header=:b_references,"
            "deleted_at=NULL,delete_mode=NULL,updated_at=SYSTIMESTAMP "
            "WHEN NOT MATCHED THEN INSERT (direction,account_email,message_id,message_key,thread_key,sender_email,recipient_email,"
            "subject,body,status,mail_date,imap_uid,imap_folder,imap_uid_validity,imap_present,imap_last_seen_at,references_header) "
            "VALUES ('in',:account,:message_id,:message_key,:thread_key,:sender,:recipient,:subject,:body,:status,:mail_date,"
            ":imap_uid,:imap_folder,:uid_validity,1,SYSTIMESTAMP,:b_references)",
            binds,
        )
        row = self._fetchone(
            f"SELECT id FROM {self.schema}.IMAP_BOT_MESSAGES WHERE direction='in' AND LOWER(account_email)=LOWER(:account) AND message_key=:message_key",
            {"account": account, "message_key": binds["message_key"]},
        )
        return int(row["id"])

    def add_outbound(
        self, *, account: str, message_id: str, thread_key: str, sender: str,
        recipient: str, subject: str, body: str, reply_to: str,
        provider_message_id: str, status: str, error: str = "", mail_date: str = "",
        references: str = "", recipient_class: str = "external",
        approval_required: bool = False, approved_at: str | None = None,
        approved_by: str = "",
    ) -> int:
        out_id = None
        with self.pool.acquire() as conn:
            cur = conn.cursor()
            try:
                out_var = cur.var(self.oracledb.NUMBER)
                cur.execute(
                    f"INSERT INTO {self.schema}.IMAP_BOT_MESSAGES (direction,account_email,message_id,message_key,thread_key,"
                    "sender_email,recipient_email,subject,body,reply_to_message_id,provider_message_id,status,error_message,"
                    "mail_date,recipient_class,approval_required,approved_at,approved_by,send_queued_at,sent_at,references_header) "
                    "VALUES ('out',:account,:message_id,:message_key,:thread_key,:sender,:recipient,:subject,:body,:reply_to,"
                    ":provider_message_id,:status,:error_message,:mail_date,:recipient_class,:approval_required,:approved_at,"
                    ":approved_by,CASE WHEN :status_for_queue='send-queued' THEN SYSTIMESTAMP END,"
                    "CASE WHEN :status_for_sent='sent' THEN SYSTIMESTAMP END,:b_references) RETURNING id INTO :out_id",
                    {
                        "account": account, "message_id": message_id, "message_key": _message_key(message_id),
                        "thread_key": thread_key, "sender": sender, "recipient": recipient, "subject": subject,
                        "body": body, "reply_to": reply_to, "provider_message_id": provider_message_id or None,
                        "status": status, "error_message": error or None, "mail_date": _parse_dt(mail_date) or datetime.now(),
                        "recipient_class": recipient_class, "approval_required": 1 if approval_required else 0,
                        "approved_at": _parse_dt(approved_at), "approved_by": approved_by or None,
                        "status_for_queue": status, "status_for_sent": status, "b_references": references,
                        "out_id": out_var,
                    },
                )
                conn.commit()
                self._invalidate_cache()
                value = out_var.getvalue()
                out_id = value[0] if isinstance(value, list) else value
            finally:
                cur.close()
        return int(out_id)

    def set_inbound_status(self, account: str, message_id: str, status: str) -> None:
        self._execute(
            f"UPDATE {self.schema}.IMAP_BOT_MESSAGES SET status=:status,error_message=NULL,updated_at=SYSTIMESTAMP "
            "WHERE direction='in' AND LOWER(account_email)=LOWER(:account) AND message_key=:message_key "
            "AND NVL(reply_suppressed,0)=0",
            {"status": status, "account": account, "message_key": _message_key(message_id)},
        )

    def set_message_status(self, message_row_id: int, status: str, error: str = "") -> None:
        count = self._execute(
            f"UPDATE {self.schema}.IMAP_BOT_MESSAGES SET status=:status,error_message=:error_message,updated_at=SYSTIMESTAMP "
            "WHERE id=:id AND direction='in' AND deleted_at IS NULL",
            {"status": status, "error_message": error or None, "id": int(message_row_id)},
        )
        if count != 1:
            raise RuntimeError("mensagem não encontrada ou já removida")

    def set_outbound_status(self, message_row_id: int, status: str, error: str = "", provider_message_id: str | None = None) -> None:
        count = self._execute(
            f"UPDATE {self.schema}.IMAP_BOT_MESSAGES SET status=:status,error_message=:error_message,"
            "provider_message_id=COALESCE(:provider_message_id,provider_message_id),"
            "send_queued_at=CASE WHEN :status_queue='send-queued' THEN SYSTIMESTAMP ELSE send_queued_at END,"
            "sent_at=CASE WHEN :status_sent='sent' THEN SYSTIMESTAMP ELSE sent_at END,updated_at=SYSTIMESTAMP "
            "WHERE id=:id AND direction='out' AND deleted_at IS NULL",
            {"status": status, "error_message": error or None, "provider_message_id": provider_message_id,
             "status_queue": status, "status_sent": status, "id": int(message_row_id)},
        )
        if count != 1:
            raise RuntimeError("resposta não encontrada")

    def is_inbound_reply_suppressed(self, account: str, message_id: str) -> bool:
        row = self._fetchone(
            f"SELECT reply_suppressed FROM {self.schema}.IMAP_BOT_MESSAGES "
            "WHERE direction='in' AND LOWER(account_email)=LOWER(:b_account) "
            "AND message_key=:b_message_key AND deleted_at IS NULL FETCH FIRST 1 ROW ONLY",
            {"b_account": account, "b_message_key": _message_key(message_id)},
        )
        return bool(row and int(row.get("reply_suppressed") or 0) == 1)

    def suppress_inbound_reply(self, message_row_id: int, suppressed_by: str = "tui") -> dict:
        cancelled = 0
        with self.pool.acquire() as conn:
            cur = conn.cursor()
            try:
                cur.execute(
                    f"SELECT message_id,status,reply_suppressed FROM {self.schema}.IMAP_BOT_MESSAGES "
                    "WHERE id=:b_id AND direction='in' AND deleted_at IS NULL FOR UPDATE",
                    {"b_id": int(message_row_id)},
                )
                found = cur.fetchone()
                if found is None:
                    raise RuntimeError("mensagem de entrada não encontrada")
                inbound_message_id = str(found[0] or "")
                cur.execute(
                    f"SELECT COUNT(*) FROM {self.schema}.IMAP_BOT_MESSAGES "
                    "WHERE direction='out' AND deleted_at IS NULL AND reply_to_message_id=:b_reply_to "
                    "AND status IN ('sending','sent')",
                    {"b_reply_to": inbound_message_id},
                )
                if int(cur.fetchone()[0] or 0) > 0:
                    raise RuntimeError(
                        "a resposta já está sendo enviada ou já foi enviada; não é mais possível marcar como não responder"
                    )
                cur.execute(
                    f"UPDATE {self.schema}.IMAP_BOT_MESSAGES "
                    "SET status='cancelled-no-reply',error_message=NULL,updated_at=SYSTIMESTAMP "
                    "WHERE direction='out' AND deleted_at IS NULL AND reply_to_message_id=:b_reply_to "
                    "AND status IN ('pending-approval','approved-waiting-global','send-queued','send-error')",
                    {"b_reply_to": inbound_message_id},
                )
                cancelled = int(cur.rowcount or 0)
                cur.execute(
                    f"UPDATE {self.schema}.IMAP_BOT_MESSAGES "
                    "SET reply_suppressed=1,reply_suppressed_at=SYSTIMESTAMP,reply_suppressed_by=:b_by,"
                    "status='no-reply',error_message=NULL,updated_at=SYSTIMESTAMP "
                    "WHERE id=:b_id AND direction='in'",
                    {"b_by": suppressed_by, "b_id": int(message_row_id)},
                )
                conn.commit()
                self._invalidate_cache()
            finally:
                cur.close()
        result = self.get_message(int(message_row_id))
        if result is None:
            raise RuntimeError("mensagem não encontrada após atualização")
        result["cancelled_replies"] = cancelled
        return result

    def count_pending_deletes(self) -> int:
        row = self._cached(
            ("count_pending_deletes",),
            lambda: self._fetchone(
                f"SELECT COUNT(*) AS \"total\" FROM {self.schema}.IMAP_BOT_MESSAGES WHERE direction='in' AND deleted_at IS NULL "
                "AND status IN ('delete-queued','deleting')"
            ),
        )
        return int(row["total"] if row else 0)

    def list_pending_deletes(self) -> list[dict]:
        return self._fetchall(
            f"SELECT {self._message_select()} FROM {self.schema}.IMAP_BOT_MESSAGES WHERE direction='in' AND deleted_at IS NULL "
            "AND status IN ('delete-queued','deleting') ORDER BY id"
        )

    def mark_deleted(self, message_row_id: int, delete_mode: str) -> None:
        count = self._execute(
            f"UPDATE {self.schema}.IMAP_BOT_MESSAGES SET deleted_at=SYSTIMESTAMP,delete_mode=:delete_mode,imap_present=0,"
            "error_message=NULL,updated_at=SYSTIMESTAMP WHERE id=:id AND direction='in' AND deleted_at IS NULL",
            {"delete_mode": delete_mode, "id": int(message_row_id)},
        )
        if count != 1:
            raise RuntimeError("mensagem não encontrada ou já removida")

    def reconcile_inbox(self, account: str, folder: str, uid_validity: str, present_uids: set[str]) -> int:
        rows = self._fetchall(
            f"SELECT id,imap_uid,imap_uid_validity,delete_mode,deleted_at,imap_present FROM {self.schema}.IMAP_BOT_MESSAGES "
            "WHERE direction='in' AND LOWER(account_email)=LOWER(:account) AND imap_folder=:folder",
            {"account": account, "folder": folder},
        )
        missing_ids: list[int] = []
        present_ids: list[int] = []
        for row in rows:
            if row.get("deleted_at") and row.get("delete_mode") != "imap-sync-missing":
                continue
            same_validity = str(row.get("imap_uid_validity") or "") == str(uid_validity)
            present = same_validity and str(row.get("imap_uid") or "") in present_uids
            if present:
                if int(row.get("imap_present") or 0) != 1 or row.get("delete_mode") == "imap-sync-missing":
                    present_ids.append(int(row["id"]))
            elif int(row.get("imap_present") or 0) == 1:
                missing_ids.append(int(row["id"]))
        if present_ids:
            with self.pool.acquire() as conn:
                cur = conn.cursor()
                try:
                    cur.executemany(
                        f"UPDATE {self.schema}.IMAP_BOT_MESSAGES SET imap_present=1,imap_last_seen_at=SYSTIMESTAMP,"
                        "deleted_at=CASE WHEN delete_mode='imap-sync-missing' THEN NULL ELSE deleted_at END,"
                        "delete_mode=CASE WHEN delete_mode='imap-sync-missing' THEN NULL ELSE delete_mode END,updated_at=SYSTIMESTAMP WHERE id=:1",
                        [(row_id,) for row_id in present_ids],
                    )
                    conn.commit()
                    self._invalidate_cache()
                finally:
                    cur.close()
        if missing_ids:
            with self.pool.acquire() as conn:
                cur = conn.cursor()
                try:
                    cur.executemany(
                        f"UPDATE {self.schema}.IMAP_BOT_MESSAGES SET imap_present=0,deleted_at=SYSTIMESTAMP,"
                        "delete_mode='imap-sync-missing',updated_at=SYSTIMESTAMP WHERE id=:1",
                        [(row_id,) for row_id in missing_ids],
                    )
                    conn.commit()
                    self._invalidate_cache()
                finally:
                    cur.close()
        return len(missing_ids)

    def get_mailbox_state(self, account: str, folder: str) -> dict | None:
        return self._fetchone(
            f"SELECT account_email,imap_folder,uid_validity,last_max_uid,initialized,initial_sync_at,last_sync_at "
            f"FROM {self.schema}.IMAP_BOT_MAILBOX_STATE WHERE LOWER(account_email)=LOWER(:account) AND imap_folder=:folder",
            {"account": account, "folder": folder},
        )

    def set_mailbox_state(self, account: str, folder: str, uid_validity: str, last_max_uid: int, initialized: bool = True) -> None:
        self._execute(
            f"MERGE INTO {self.schema}.IMAP_BOT_MAILBOX_STATE t USING (SELECT :account account_email,:folder imap_folder FROM dual) s "
            "ON (LOWER(t.account_email)=LOWER(s.account_email) AND t.imap_folder=s.imap_folder) "
            "WHEN MATCHED THEN UPDATE SET uid_validity=:uid_validity,last_max_uid=:last_max_uid,initialized=:initialized,"
            "last_sync_at=SYSTIMESTAMP "
            "WHEN NOT MATCHED THEN INSERT (account_email,imap_folder,uid_validity,last_max_uid,initialized,initial_sync_at,last_sync_at) "
            "VALUES (:account,:folder,:uid_validity,:last_max_uid,:initialized,SYSTIMESTAMP,SYSTIMESTAMP)",
            {"account": account, "folder": folder, "uid_validity": int(uid_validity or 0),
             "last_max_uid": int(last_max_uid), "initialized": 1 if initialized else 0},
        )

    def add_event(self, category: str, level: str, text: str) -> None:
        started = time.monotonic()
        with self.pool.acquire() as conn:
            cur = conn.cursor()
            try:
                cur.execute(
                    f"INSERT INTO {self.schema}.IMAP_BOT_EVENTS(category,level_name,event_text) VALUES(:category,:level_name,:event_text)",
                    {"category": category, "level_name": level, "event_text": text},
                )
                conn.commit()
                self._invalidate_cache("events")
                trace(f"ORACLE EVENT {time.monotonic()-started:.3f}s category={category} level={level}")
            finally:
                cur.close()

    def list_messages(self, direction: str, limit: int = 500) -> list[dict]:
        if direction not in {"in", "out"}:
            raise ValueError("direction inválida")
        extra = " AND imap_present=1" if direction == "in" else ""
        key = ("messages", direction, int(limit))
        return self._cached(
            key,
            lambda: self._fetchall(
                f"SELECT {self._message_select()} FROM {self.schema}.IMAP_BOT_MESSAGES WHERE direction=:direction "
                f"AND deleted_at IS NULL{extra} ORDER BY id DESC FETCH FIRST {max(1, int(limit))} ROWS ONLY",
                {"direction": direction},
            ),
        )

    def get_message(self, message_id: int) -> dict | None:
        return self._fetchone(
            f"SELECT {self._message_select()} FROM {self.schema}.IMAP_BOT_MESSAGES WHERE id=:id",
            {"id": int(message_id)},
        )

    def recent_events(self, limit: int = 500) -> list[dict]:
        return self._cached(
            ("events", int(limit)),
            lambda: self._fetchall(
                f"SELECT id,category,level_name AS \"level\",event_text AS \"text\",created_at FROM {self.schema}.IMAP_BOT_EVENTS "
                f"ORDER BY id DESC FETCH FIRST {max(1, int(limit))} ROWS ONLY"
            ),
        )

    def recent(self, limit: int = 12) -> list[tuple]:
        return [tuple(row.get(key) for key in ("id", "direction", "account_email", "sender", "recipient", "subject", "status", "created_at")) for row in self.list_messages("in", limit)]

    def add_api_run(self, *, kind: str, status: str, model: str, reasoning_effort: str, input_path: str,
                    output_path: str, request_summary: str, request_payload: str = "", request_bytes: int = 0,
                    input_file_bytes: int = 0, input_file_count: int = 0, listed_item_count: int = 0) -> int:
        with self.pool.acquire() as conn:
            cur = conn.cursor()
            try:
                out_var = cur.var(self.oracledb.NUMBER)
                cur.execute(
                    f"INSERT INTO {self.schema}.IMAP_BOT_API_RUNS(kind,status,model,reasoning_effort,input_path,output_path,"
                    "request_summary,request_payload,request_bytes,input_file_bytes,input_file_count,listed_item_count) "
                    "VALUES(:kind,:status,:model,:reasoning_effort,:input_path,:output_path,:request_summary,:request_payload,"
                    ":request_bytes,:input_file_bytes,:input_file_count,:listed_item_count) RETURNING id INTO :out_id",
                    {"kind": kind, "status": status, "model": model, "reasoning_effort": reasoning_effort or None,
                     "input_path": input_path or None, "output_path": output_path or None,
                     "request_summary": request_summary or None, "request_payload": request_payload or None,
                     "request_bytes": int(request_bytes or 0), "input_file_bytes": int(input_file_bytes or 0),
                     "input_file_count": int(input_file_count or 0), "listed_item_count": int(listed_item_count or 0),
                     "out_id": out_var},
                )
                conn.commit()
                self._invalidate_cache()
                value = out_var.getvalue()
                return int(value[0] if isinstance(value, list) else value)
            finally:
                cur.close()

    def update_api_run(self, run_id: int, *, status: str | None = None, output_path: str | None = None,
                       response_id: str | None = None, request_summary: str | None = None,
                       response_summary: str | None = None, error: str | None = None,
                       elapsed_ms: int | None = None, finished: bool = False,
                       request_payload: str | None = None, request_bytes: int | None = None,
                       input_file_bytes: int | None = None, input_file_count: int | None = None,
                       listed_item_count: int | None = None, response_bytes: int | None = None,
                       output_file_bytes: int | None = None, output_file_count: int | None = None) -> None:
        mapping = {
            "status": status, "output_path": output_path, "response_id": response_id,
            "request_summary": request_summary, "response_summary": response_summary,
            "error_message": error, "elapsed_ms": elapsed_ms, "request_payload": request_payload,
            "request_bytes": request_bytes, "input_file_bytes": input_file_bytes,
            "input_file_count": input_file_count, "listed_item_count": listed_item_count,
            "response_bytes": response_bytes, "output_file_bytes": output_file_bytes,
            "output_file_count": output_file_count,
        }
        sets: list[str] = []
        binds: dict[str, Any] = {"id": int(run_id)}
        for col, value in mapping.items():
            if value is not None:
                sets.append(f"{col}=:{col}")
                binds[col] = value
        if finished:
            sets.append("finished_at=SYSTIMESTAMP")
        if not sets:
            return
        count = self._execute(
            f"UPDATE {self.schema}.IMAP_BOT_API_RUNS SET {','.join(sets)} WHERE id=:id",
            binds,
        )
        if count != 1:
            raise RuntimeError("execução de API não encontrada")

    def list_api_runs(self, limit: int = 200) -> list[dict]:
        return self._cached(
            ("api_runs", int(limit)),
            lambda: self._fetchall(
                f"SELECT id,kind,status,model,reasoning_effort,input_path,output_path,response_id,request_summary,response_summary,"
                "error_message AS \"error\",elapsed_ms,started_at,finished_at,request_payload,request_bytes,input_file_bytes,"
                f"input_file_count,listed_item_count,response_bytes,output_file_bytes,output_file_count FROM {self.schema}.IMAP_BOT_API_RUNS "
                f"ORDER BY id DESC FETCH FIRST {max(1, int(limit))} ROWS ONLY"
            ),
        )

    def get_api_run(self, run_id: int) -> dict | None:
        return self._fetchone(
            f"SELECT id,kind,status,model,reasoning_effort,input_path,output_path,response_id,request_summary,response_summary,"
            "error_message AS \"error\",elapsed_ms,started_at,finished_at,request_payload,request_bytes,input_file_bytes,"
            f"input_file_count,listed_item_count,response_bytes,output_file_bytes,output_file_count FROM {self.schema}.IMAP_BOT_API_RUNS WHERE id=:id",
            {"id": int(run_id)},
        )

    def get_tui_header(self) -> dict:
        row = self._fetchone(
            f"SELECT c.external_send_enabled, "
            f"(SELECT COUNT(*) FROM {self.schema}.IMAP_BOT_MESSAGES m WHERE m.direction='in' AND m.deleted_at IS NULL AND m.status IN ('delete-queued','deleting')) AS pending_deletes, "
            f"(SELECT COUNT(*) FROM {self.schema}.IMAP_BOT_MESSAGES m WHERE m.direction='out' AND m.deleted_at IS NULL AND m.status='pending-approval') AS pending_approvals, "
            f"(SELECT COUNT(*) FROM {self.schema}.IMAP_BOT_MESSAGES m WHERE m.direction='out' AND m.deleted_at IS NULL AND m.status='approved-waiting-global') AS approved_waiting_global "
            f"FROM {self.schema}.IMAP_BOT_CONTROL c WHERE c.control_key='DEFAULT'"
        )
        if not row:
            raise RuntimeError("IMAP_BOT_CONTROL/DEFAULT ausente")
        return {
            "external_send_enabled": int(row.get("external_send_enabled") or 0) == 1,
            "pending_deletes": int(row.get("pending_deletes") or 0),
            "pending_approvals": int(row.get("pending_approvals") or 0),
            "approved_waiting_global": int(row.get("approved_waiting_global") or 0),
        }

    def get_control(self) -> dict:
        row = self._cached(
            ("control",),
            lambda: self._fetchone(
                f"SELECT external_send_enabled,updated_at,updated_by FROM {self.schema}.IMAP_BOT_CONTROL WHERE control_key='DEFAULT'"
            ),
        )
        if not row:
            raise RuntimeError("IMAP_BOT_CONTROL/DEFAULT ausente")
        return {
            "external_send_enabled": int(row["external_send_enabled"] or 0) == 1,
            # Regra fixa: cliente/terceiro sempre exige liberação individual.
            "external_require_approval": True,
            "updated_at": row.get("updated_at"), "updated_by": row.get("updated_by"),
        }

    def set_external_send_enabled(self, enabled: bool, updated_by: str = "tui") -> None:
        count = self._execute(
            f"UPDATE {self.schema}.IMAP_BOT_CONTROL SET external_send_enabled=:enabled,updated_at=SYSTIMESTAMP,updated_by=:updated_by "
            "WHERE control_key='DEFAULT'",
            {"enabled": 1 if enabled else 0, "updated_by": updated_by},
        )
        if count != 1:
            raise RuntimeError("IMAP_BOT_CONTROL/DEFAULT ausente")

    def is_always_allowed_recipient(self, email: str) -> bool:
        row = self._fetchone(
            f"SELECT 1 AS \"found\" FROM {self.schema}.IMAP_BOT_ALWAYS_ALLOWED_RECIPIENTS WHERE LOWER(recipient_email)=LOWER(:email) "
            "AND enabled=1 FETCH FIRST 1 ROW ONLY",
            {"email": str(email or "").strip()},
        )
        return row is not None

    def count_pending_approvals(self) -> int:
        row = self._cached(
            ("count_pending_approvals",),
            lambda: self._fetchone(
                f"SELECT COUNT(*) AS \"total\" FROM {self.schema}.IMAP_BOT_MESSAGES WHERE direction='out' AND deleted_at IS NULL AND status='pending-approval'"
            ),
        )
        return int(row["total"] if row else 0)

    def count_approved_waiting_global(self) -> int:
        row = self._cached(
            ("count_waiting_global",),
            lambda: self._fetchone(
                f"SELECT COUNT(*) AS \"total\" FROM {self.schema}.IMAP_BOT_MESSAGES WHERE direction='out' AND deleted_at IS NULL AND status='approved-waiting-global'"
            ),
        )
        return int(row["total"] if row else 0)

    def approve_outbound(self, message_row_id: int, approved_by: str = "tui") -> dict:
        row = self.get_message(message_row_id)
        if not row or row.get("direction") != "out":
            raise RuntimeError("somente respostas podem ser liberadas")
        if int(row.get("approval_required") or 0) != 1:
            raise RuntimeError("esta resposta não exige liberação manual")
        if str(row.get("status") or "") not in {"pending-approval", "approved-waiting-global"}:
            raise RuntimeError(f"resposta não está pendente de liberação: {row.get('status')}")
        control = self.get_control()
        target_status = "send-queued" if control["external_send_enabled"] else "approved-waiting-global"
        self._execute(
            f"UPDATE {self.schema}.IMAP_BOT_MESSAGES SET approved_at=COALESCE(approved_at,SYSTIMESTAMP),approved_by=:approved_by,"
            "status=:status,send_queued_at=CASE WHEN :status_queue='send-queued' THEN SYSTIMESTAMP ELSE send_queued_at END,updated_at=SYSTIMESTAMP "
            "WHERE id=:id AND direction='out'",
            {"approved_by": approved_by, "status": target_status, "status_queue": target_status, "id": int(message_row_id)},
        )
        return self.get_message(message_row_id) or row

    def list_send_queue(self) -> list[dict]:
        return self._fetchall(
            f"SELECT {self._message_select()} FROM {self.schema}.IMAP_BOT_MESSAGES WHERE direction='out' AND deleted_at IS NULL "
            "AND status IN ('send-queued','sending') ORDER BY id"
        )

    def activate_approved_waiting(self) -> list[int]:
        control = self.get_control()
        if not control["external_send_enabled"]:
            return []
        rows = self._fetchall(
            f"SELECT id FROM {self.schema}.IMAP_BOT_MESSAGES WHERE direction='out' AND deleted_at IS NULL "
            "AND status='approved-waiting-global' AND approved_at IS NOT NULL ORDER BY id"
        )
        if not rows:
            return []
        ids = [int(row["id"]) for row in rows]
        with self.pool.acquire() as conn:
            cur = conn.cursor()
            try:
                cur.executemany(
                    f"UPDATE {self.schema}.IMAP_BOT_MESSAGES SET status='send-queued',send_queued_at=SYSTIMESTAMP,updated_at=SYSTIMESTAMP WHERE id=:1",
                    [(row_id,) for row_id in ids],
                )
                conn.commit()
                self._invalidate_cache()
            finally:
                cur.close()
        return ids


class Store:
    """Facade. Runtime usa Oracle; Path é backend em memória para testes, nunca SQLite."""

    def __init__(self, database, log: Callable[[str], None] | None = None):
        if hasattr(database, "db_type"):
            self._backend = _OracleStore(database, log=log)
        else:
            self._backend = _MemoryStore()

    def __getattr__(self, name: str):
        return getattr(self._backend, name)
