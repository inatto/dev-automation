from __future__ import annotations

import os
import time
from contextlib import asynccontextmanager
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import oracledb
from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", env_file_encoding="utf-8", extra="ignore")

    app_name: str = "Oracle Local Monitor API"
    app_env: str = "development"
    app_host: str = "127.0.0.1"
    app_port: int = 8010
    cors_origins: str = "http://localhost:4010,http://127.0.0.1:4010"

    oracle_user: str = ""
    oracle_password: str = ""
    oracle_connect_string: str = ""
    oracle_wallet_local_dir: str = "/home/daniel/.oracle/Wallet_sindicatto"
    oracle_wallet_password: str = ""
    oracle_local_machine_filter: str = "desktop-ioq529o"
    oracle_connect_timeout_seconds: int = 8
    monitor_refresh_seconds: int = 3

    @property
    def origins(self) -> list[str]:
        return [item.strip() for item in self.cors_origins.split(",") if item.strip()]

    def validate_oracle(self) -> None:
        missing = [
            name
            for name, value in {
                "ORACLE_USER": self.oracle_user,
                "ORACLE_PASSWORD": self.oracle_password,
                "ORACLE_CONNECT_STRING": self.oracle_connect_string,
            }.items()
            if not value
        ]
        if missing:
            raise RuntimeError("Variáveis Oracle ausentes: " + ", ".join(missing))
        wallet = Path(self.oracle_wallet_local_dir).expanduser()
        if not wallet.is_dir():
            raise RuntimeError(f"Wallet Oracle não encontrada: {wallet}")


settings = Settings()


def connect() -> oracledb.Connection:
    settings.validate_oracle()
    connection = oracledb.connect(
        user=settings.oracle_user,
        password=settings.oracle_password,
        dsn=settings.oracle_connect_string,
        config_dir=str(Path(settings.oracle_wallet_local_dir).expanduser()),
        wallet_location=str(Path(settings.oracle_wallet_local_dir).expanduser()),
        wallet_password=settings.oracle_wallet_password or None,
        tcp_connect_timeout=settings.oracle_connect_timeout_seconds,
    )
    connection.module = "oracle-monitor-local"
    connection.action = "read-v-session"
    connection.client_identifier = "dev-automation"
    return connection


def rows_as_dicts(cursor: oracledb.Cursor) -> list[dict[str, Any]]:
    columns = [description[0].lower() for description in cursor.description]
    return [dict(zip(columns, row, strict=True)) for row in cursor]


def query_sessions(connection: oracledb.Connection) -> list[dict[str, Any]]:
    machine_filter = settings.oracle_local_machine_filter.strip().lower()
    sql = """
        SELECT
            s.sid,
            s.serial# AS serial_number,
            s.username,
            s.status,
            s.machine,
            s.osuser,
            s.process,
            s.program,
            NVL(s.module, 'SEM MODULE') AS module,
            s.action,
            s.client_identifier,
            s.event,
            s.wait_class,
            s.seconds_in_wait,
            s.blocking_session,
            s.sql_id,
            s.logon_time,
            s.last_call_et
        FROM v$session s
        WHERE s.username IS NOT NULL
          AND (:machine_filter IS NULL OR LOWER(s.machine) LIKE '%' || :machine_filter || '%')
        ORDER BY
            CASE WHEN s.blocking_session IS NOT NULL THEN 0 ELSE 1 END,
            CASE WHEN s.status = 'ACTIVE' THEN 0 ELSE 1 END,
            s.seconds_in_wait DESC,
            s.module,
            s.sid
    """
    with connection.cursor() as cursor:
        cursor.execute(sql, machine_filter=machine_filter or None)
        return rows_as_dicts(cursor)


def query_transactions(connection: oracledb.Connection) -> list[dict[str, Any]]:
    machine_filter = settings.oracle_local_machine_filter.strip().lower()
    sql = """
        SELECT
            s.sid,
            s.serial# AS serial_number,
            s.status,
            s.machine,
            NVL(s.module, 'SEM MODULE') AS module,
            s.action,
            t.start_time,
            t.used_ublk,
            t.used_urec,
            s.sql_id,
            s.prev_sql_id,
            s.last_call_et
        FROM v$transaction t
        JOIN v$session s ON s.saddr = t.ses_addr
        WHERE (:machine_filter IS NULL OR LOWER(s.machine) LIKE '%' || :machine_filter || '%')
        ORDER BY t.start_time
    """
    with connection.cursor() as cursor:
        cursor.execute(sql, machine_filter=machine_filter or None)
        return rows_as_dicts(cursor)


def summarize(sessions: list[dict[str, Any]], transactions: list[dict[str, Any]]) -> dict[str, Any]:
    by_module: dict[str, dict[str, Any]] = {}
    for session in sessions:
        module = str(session.get("module") or "SEM MODULE")
        item = by_module.setdefault(
            module,
            {"module": module, "total": 0, "active": 0, "inactive": 0, "blocked": 0, "transactions": 0},
        )
        item["total"] += 1
        status = str(session.get("status") or "").upper()
        if status == "ACTIVE":
            item["active"] += 1
        else:
            item["inactive"] += 1
        if session.get("blocking_session") is not None:
            item["blocked"] += 1

    for transaction in transactions:
        module = str(transaction.get("module") or "SEM MODULE")
        item = by_module.setdefault(
            module,
            {"module": module, "total": 0, "active": 0, "inactive": 0, "blocked": 0, "transactions": 0},
        )
        item["transactions"] += 1

    return {
        "total": len(sessions),
        "active": sum(1 for item in sessions if str(item.get("status") or "").upper() == "ACTIVE"),
        "inactive": sum(1 for item in sessions if str(item.get("status") or "").upper() != "ACTIVE"),
        "blocked": sum(1 for item in sessions if item.get("blocking_session") is not None),
        "transactions": len(transactions),
        "applications": sorted(by_module.values(), key=lambda item: (-item["blocked"], -item["active"], item["module"])),
    }


@asynccontextmanager
async def lifespan(_: FastAPI):
    yield


app = FastAPI(title=settings.app_name, lifespan=lifespan)
app.add_middleware(
    CORSMiddleware,
    allow_origins=settings.origins,
    allow_credentials=False,
    allow_methods=["GET"],
    allow_headers=["*"],
)


@app.get("/api/health")
def health() -> dict[str, Any]:
    started = time.monotonic()
    try:
        with connect() as connection:
            with connection.cursor() as cursor:
                cursor.execute("SELECT SYSTIMESTAMP FROM dual")
                database_time = cursor.fetchone()[0]
        return {
            "status": "ok",
            "database_time": database_time,
            "latency_ms": round((time.monotonic() - started) * 1000, 1),
        }
    except Exception as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc


@app.get("/api/monitor")
def monitor() -> dict[str, Any]:
    started = time.monotonic()
    try:
        with connect() as connection:
            sessions = query_sessions(connection)
            transactions = query_transactions(connection)
        return {
            "generated_at": datetime.now(timezone.utc),
            "latency_ms": round((time.monotonic() - started) * 1000, 1),
            "machine_filter": settings.oracle_local_machine_filter or None,
            "refresh_seconds": settings.monitor_refresh_seconds,
            "summary": summarize(sessions, transactions),
            "sessions": sessions,
            "transactions": transactions,
        }
    except oracledb.DatabaseError as exc:
        error, = exc.args
        detail = f"Oracle {getattr(error, 'code', '')}: {getattr(error, 'message', str(exc))}".strip()
        raise HTTPException(status_code=503, detail=detail) from exc
    except Exception as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc
