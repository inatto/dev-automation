from __future__ import annotations

import hmac
import json
import threading
import uuid
from dataclasses import asdict
from datetime import datetime
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

from api_runner import ApiTestRunner
from monitor import Monitor
from store import Store


PROCESSING_STATUSES = {"analyzing", "understood", "sending", "executing"}


class ApiError(RuntimeError):
    def __init__(self, status: int, message: str):
        super().__init__(message)
        self.status = int(status)


class MobileApiService:
    """Camada de aplicação usada pela API mobile, sem acesso ou emulação do terminal."""

    def __init__(self, settings, store: Store, monitor: Monitor, api_runner: ApiTestRunner | None = None):
        self.settings = settings
        self.store = store
        self.monitor = monitor
        self.api_runner = api_runner or ApiTestRunner(settings, store, monitor.on_event)
        self._actions: dict[str, dict] = {}
        self._actions_lock = threading.Lock()

    @staticmethod
    def _limit(query: dict, default: int, maximum: int) -> int:
        try:
            return max(1, min(maximum, int((query.get("limit") or [default])[0])))
        except (TypeError, ValueError):
            raise ApiError(HTTPStatus.BAD_REQUEST, "limit inválido")

    def _new_action(self, kind: str, detail: str = "") -> dict:
        action = {
            "id": uuid.uuid4().hex,
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
            if len(self._actions) > 200:
                oldest = sorted(self._actions.values(), key=lambda item: item["created_at"])[:-200]
                for item in oldest:
                    self._actions.pop(item["id"], None)
        return dict(action)

    def _update_action(self, action_id: str, **values) -> None:
        with self._actions_lock:
            if action_id in self._actions:
                self._actions[action_id].update(values)

    def _run_action(self, action: dict, callback) -> None:
        def target():
            self._update_action(action["id"], status="running")
            try:
                result = callback()
                self._update_action(
                    action["id"], status="completed", result=str(result or ""),
                    finished_at=datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
                )
            except Exception as exc:
                self._update_action(
                    action["id"], status="error", error=str(exc),
                    finished_at=datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
                )
        threading.Thread(target=target, daemon=True).start()

    def _safe_config(self) -> dict:
        return {
            "imap_host": self.settings.imap_host,
            "imap_port": self.settings.imap_port,
            "imap_folder": self.settings.imap_folder,
            "poll_seconds": self.settings.poll_seconds,
            "aws_profile": self.settings.aws_profile,
            "aws_region": self.settings.aws_region,
            "openai_model": self.settings.openai_model,
            "openai_base_url": self.settings.openai_base_url,
            "openai_reasoning_effort": self.settings.openai_reasoning_effort,
            "openai_timeout_seconds": self.settings.openai_timeout_seconds,
            "openai_key_configured": bool(self.settings.openai_api_key),
            "openai_output_dir": str(self.settings.openai_output_dir),
            "openai_test_zip": str(self.settings.openai_test_zip),
            "functions_config": str(self.settings.functions_config),
            "project_zip_search_root": str(self.settings.project_zip_search_root),
            "auto_reply_enabled": self.settings.auto_reply_enabled,
            "sound_enabled": self.settings.sound_enabled,
        }

    def overview(self) -> dict:
        accounts = self.accounts()
        return {
            "service": "amazon-imap-bot",
            "server_time": datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
            "running": not self.monitor.stop_event.is_set(),
            "checking": self.monitor.run_lock.locked(),
            "online_accounts": sum(1 for item in accounts if item["connected"]),
            "account_count": len(accounts),
            "account_errors": sum(1 for item in accounts if item["last_error"]),
            "received": sum(item["received"] for item in accounts),
            "replied": sum(item["replied"] for item in accounts),
            "queues": {
                "processing_messages": sum(
                    1 for row in self.store.list_messages("in", 500)
                    if str(row.get("status") or "").lower() in PROCESSING_STATUSES
                ),
                "active_actions": sum(
                    1 for item in self.actions()
                    if item["status"] in {"queued", "running"}
                ),
            },
            "config": self._safe_config(),
        }

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

    def functions(self) -> dict:
        path = Path(self.settings.functions_config)
        if not path.is_file():
            return {"version": 1, "senders": {}, "functions": {}, "available": False}
        try:
            payload = json.loads(path.read_text(encoding="utf-8"))
        except json.JSONDecodeError as exc:
            raise ApiError(HTTPStatus.INTERNAL_SERVER_ERROR, f"functions.json inválido: {exc}")
        if not isinstance(payload, dict):
            raise ApiError(HTTPStatus.INTERNAL_SERVER_ERROR, "functions.json inválido")
        return {**payload, "available": True}

    def actions(self) -> list[dict]:
        with self._actions_lock:
            return [dict(item) for item in reversed(list(self._actions.values()))]

    def refresh(self) -> dict:
        action = self._new_action("refresh", "Verificação IMAP solicitada pelo aplicativo")
        self._run_action(action, lambda: self.monitor.run_once() or "verificação concluída")
        return action

    def run_zip_test(self, body: dict) -> dict:
        effort = str(body.get("reasoning_effort") or self.settings.openai_reasoning_effort)
        request_text = str(body.get("request_text") or "").strip()
        action = self._new_action("api-zip-test", request_text[:300])
        self._run_action(
            action,
            lambda: f"api_run_id={self.api_runner.run_zip_test(reasoning_effort=effort, request_text=request_text, source='mobile')}",
        )
        return action

    def delete_message(self, message_id: int) -> dict:
        row = self.store.get_message(message_id)
        if row is None:
            raise ApiError(HTTPStatus.NOT_FOUND, "mensagem não encontrada")
        action = self._new_action("delete-message", f"message_id={message_id}")
        self._update_action(action["id"], status="running")
        try:
            mode = self.monitor.delete_inbound(row)
            self._update_action(
                action["id"], status="completed", result=mode,
                finished_at=datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
            )
        except Exception as exc:
            self._update_action(
                action["id"], status="error", error=str(exc),
                finished_at=datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
            )
            raise ApiError(HTTPStatus.CONFLICT, str(exc))
        return next(item for item in self.actions() if item["id"] == action["id"])


class MobileApiHandler(BaseHTTPRequestHandler):
    server_version = "AmazonImapBotMobileAPI/1.0"

    def _json(self, status: int, payload) -> None:
        data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(int(status))
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def _authorized(self) -> bool:
        expected = self.server.api_token
        supplied = self.headers.get("Authorization", "")
        if not supplied.startswith("Bearer "):
            return False
        return hmac.compare_digest(supplied[7:], expected)

    def _body(self) -> dict:
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            raise ApiError(HTTPStatus.BAD_REQUEST, "Content-Length inválido")
        if length > 65536:
            raise ApiError(HTTPStatus.REQUEST_ENTITY_TOO_LARGE, "corpo excede 64 KiB")
        if not length:
            return {}
        try:
            payload = json.loads(self.rfile.read(length).decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            raise ApiError(HTTPStatus.BAD_REQUEST, "JSON inválido")
        if not isinstance(payload, dict):
            raise ApiError(HTTPStatus.BAD_REQUEST, "o corpo deve ser um objeto JSON")
        return payload

    def _route(self, method: str) -> tuple[int, object]:
        parsed = urlparse(self.path)
        path = parsed.path.rstrip("/") or "/"
        query = parse_qs(parsed.query)

        if path == "/health" and method == "GET":
            return HTTPStatus.OK, {"status": "ok"}
        if not self._authorized():
            raise ApiError(HTTPStatus.UNAUTHORIZED, "token Bearer inválido ou ausente")

        service = self.server.service
        if method == "GET" and path == "/api/v1/overview":
            return HTTPStatus.OK, service.overview()
        if method == "GET" and path == "/api/v1/accounts":
            return HTTPStatus.OK, service.accounts()
        if method == "GET" and path == "/api/v1/events":
            return HTTPStatus.OK, service.store.recent_events(service._limit(query, 500, 5000))
        if method == "GET" and path == "/api/v1/api-runs":
            return HTTPStatus.OK, service.store.list_api_runs(service._limit(query, 200, 1000))
        if method == "GET" and path == "/api/v1/functions":
            return HTTPStatus.OK, service.functions()
        if method == "GET" and path == "/api/v1/actions":
            return HTTPStatus.OK, service.actions()
        if method == "GET" and path == "/api/v1/messages":
            direction = str((query.get("direction") or ["in"])[0]).lower()
            if direction not in {"in", "out"}:
                raise ApiError(HTTPStatus.BAD_REQUEST, "direction deve ser in ou out")
            return HTTPStatus.OK, service.store.list_messages(direction, service._limit(query, 500, 2000))

        match = __import__("re").fullmatch(r"/api/v1/messages/(\d+)", path)
        if match and method == "GET":
            row = service.store.get_message(int(match.group(1)))
            if row is None:
                raise ApiError(HTTPStatus.NOT_FOUND, "mensagem não encontrada")
            return HTTPStatus.OK, row
        if match and method == "DELETE":
            return HTTPStatus.OK, service.delete_message(int(match.group(1)))

        run_match = __import__("re").fullmatch(r"/api/v1/api-runs/(\d+)", path)
        if run_match and method == "GET":
            row = service.store.get_api_run(int(run_match.group(1)))
            if row is None:
                raise ApiError(HTTPStatus.NOT_FOUND, "execução de API não encontrada")
            return HTTPStatus.OK, row

        if method == "POST" and path == "/api/v1/actions/refresh":
            return HTTPStatus.ACCEPTED, service.refresh()
        if method == "POST" and path == "/api/v1/actions/api-zip-test":
            return HTTPStatus.ACCEPTED, service.run_zip_test(self._body())
        raise ApiError(HTTPStatus.NOT_FOUND, "rota não encontrada")

    def do_GET(self) -> None:
        self._dispatch("GET")

    def do_POST(self) -> None:
        self._dispatch("POST")

    def do_DELETE(self) -> None:
        self._dispatch("DELETE")

    def _dispatch(self, method: str) -> None:
        try:
            status, payload = self._route(method)
            self._json(status, payload)
        except ApiError as exc:
            self._json(exc.status, {"error": str(exc)})
        except Exception:
            self._json(HTTPStatus.INTERNAL_SERVER_ERROR, {"error": "erro interno"})

    def log_message(self, format: str, *args) -> None:
        self.server.service.store.add_event("MOBILE_API", "INFO", format % args)


def serve_mobile_api(settings, store: Store | None = None, monitor: Monitor | None = None) -> int:
    if not settings.mobile_api_token:
        raise RuntimeError("MOBILE_API_TOKEN ausente; a API mobile não inicia sem autenticação")
    store = store or Store(settings.database_path)
    monitor = monitor or Monitor(settings, store)
    service = MobileApiService(settings, store, monitor)
    monitor_thread = threading.Thread(target=monitor.run_forever, daemon=True)
    monitor_thread.start()
    server = ThreadingHTTPServer((settings.mobile_api_host, settings.mobile_api_port), MobileApiHandler)
    server.service = service
    server.api_token = settings.mobile_api_token
    store.add_event(
        "MOBILE_API", "INFO",
        f"API mobile iniciada em {settings.mobile_api_host}:{settings.mobile_api_port}",
    )
    try:
        server.serve_forever(poll_interval=0.5)
    except KeyboardInterrupt:
        return 130
    finally:
        monitor.stop()
        server.server_close()
    return 0
