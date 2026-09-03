from __future__ import annotations

import threading
from contextlib import asynccontextmanager
from fastapi import FastAPI, HTTPException, Query, Request
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel, Field
import uvicorn

from config import load_settings
from diagnostics import configure as configure_diagnostics
from monitor import Monitor
from runtime_env import load_runtime
from service import BotService, ServiceError
from store import Store
from versioning import get_version

runtime = load_runtime()


class ReplyRequest(BaseModel):
    instruction: str = Field(default="", max_length=12000)
    files: list[str] = Field(default_factory=list, max_length=8)


class DeliveryRequest(BaseModel):
    enabled: bool


class ZipTestRequest(BaseModel):
    reasoning_effort: str = ""
    request_text: str = Field(default="", max_length=12000)


@asynccontextmanager
async def lifespan(app: FastAPI):
    print(f"[amazon-imap-bot-api] versão {get_version()} iniciando")
    settings = load_settings()
    configure_diagnostics(settings.config_root)
    store = Store(settings.function_database, log=lambda text: print(f"[amazon-imap-bot-api] {text}"))
    monitor = Monitor(
        settings,
        store,
        on_event=lambda text: print(f"[amazon-imap-bot-api] {text}"),
        on_startup=lambda text: print(f"[amazon-imap-bot-api] {text}"),
    )
    service = BotService(settings, store, monitor)
    thread = threading.Thread(target=monitor.run_forever, name="amazon-imap-monitor", daemon=True)
    thread.start()
    app.state.settings = settings
    app.state.store = store
    app.state.monitor = monitor
    app.state.service = service
    app.state.monitor_thread = thread
    try:
        yield
    finally:
        print("[amazon-imap-bot-api] encerramento solicitado; cancelando IMAP e workers...")
        monitor.stop()
        thread.join(timeout=2.0)
        monitor.wait_workers(timeout=2.0)
        if thread.is_alive():
            print("[amazon-imap-bot-api] aviso: thread IMAP ainda viva; pool Oracle será fechado à força")
        store.close()
        print("[amazon-imap-bot-api] encerrado")


app = FastAPI(title=runtime.app_name, version=get_version(), lifespan=lifespan)
if runtime.cors_origins:
    app.add_middleware(
        CORSMiddleware,
        allow_origins=list(runtime.cors_origins),
        allow_methods=["GET", "POST", "PUT", "DELETE", "OPTIONS"],
        allow_headers=["*"],
        allow_credentials=False,
    )


@app.exception_handler(ServiceError)
async def service_error_handler(_request: Request, exc: ServiceError):
    from fastapi.responses import JSONResponse
    return JSONResponse(status_code=exc.status_code, content={"detail": str(exc)})


def service(request: Request) -> BotService:
    return request.app.state.service


@app.get("/api/health")
def health():
    return {"status": "ok", "version": get_version()}


@app.get("/api/version")
def version():
    return {"version": get_version()}


@app.get("/api/v1/overview")
def overview(request: Request):
    return service(request).overview()


@app.get("/api/v1/accounts")
def accounts(request: Request):
    return service(request).accounts()


@app.get("/api/v1/messages")
def messages(request: Request, direction: str = "in", limit: int = Query(500, ge=1, le=2000)):
    return service(request).messages(direction, limit)


@app.get("/api/v1/messages/{message_id}")
def message(request: Request, message_id: int):
    return service(request).message(message_id)


@app.post("/api/v1/messages/{message_id}/reply", status_code=202)
def generate_reply(request: Request, message_id: int, payload: ReplyRequest):
    return service(request).generate_reply(message_id, payload.model_dump())


@app.post("/api/v1/messages/{message_id}/approve")
def approve(request: Request, message_id: int):
    return service(request).approve(message_id)


@app.post("/api/v1/messages/{message_id}/no-reply")
def no_reply(request: Request, message_id: int):
    return service(request).no_reply(message_id)


@app.delete("/api/v1/messages/{message_id}", status_code=202)
def delete(request: Request, message_id: int):
    return service(request).delete(message_id)


@app.get("/api/v1/events")
def events(request: Request, limit: int = Query(500, ge=1, le=5000)):
    return service(request).events(limit)


@app.get("/api/v1/api-runs")
def api_runs(request: Request, limit: int = Query(200, ge=1, le=1000)):
    return service(request).api_runs(limit)


@app.get("/api/v1/api-runs/{run_id}")
def api_run(request: Request, run_id: int):
    return service(request).api_run(run_id)


@app.get("/api/v1/functions")
def functions(request: Request):
    return service(request).functions()


@app.post("/api/v1/actions/functions-sync", status_code=202)
def functions_sync(request: Request):
    return service(request).sync_functions()


@app.get("/api/v1/actions")
def actions(request: Request):
    return service(request).actions()


@app.get("/api/v1/actions/{action_id}")
def action(request: Request, action_id: str):
    return service(request).action(action_id)


@app.post("/api/v1/actions/refresh", status_code=202)
def refresh(request: Request):
    return service(request).refresh()


@app.post("/api/v1/actions/api-zip-test", status_code=202)
def api_zip_test(request: Request, payload: ZipTestRequest):
    return service(request).run_zip_test(payload.model_dump())


@app.get("/api/v1/context-files")
def context_files(request: Request, path: str = ""):
    return service(request).context_files(path)


@app.get("/api/v1/external-delivery")
def external_delivery(request: Request):
    return service(request).external_delivery()


@app.put("/api/v1/external-delivery")
def set_external_delivery(request: Request, payload: DeliveryRequest):
    return service(request).set_external_delivery(payload.enabled)


if __name__ == "__main__":
    uvicorn.run(
        "main:app",
        host=runtime.app_host,
        port=runtime.app_port,
        reload=False,
        access_log=True,
        timeout_graceful_shutdown=3,
    )
