from __future__ import annotations

import sqlite3
import threading
from datetime import datetime
from pathlib import Path


class Store:
    def __init__(self, path: Path):
        path.parent.mkdir(parents=True, exist_ok=True)
        self.path = path
        self._lock = threading.Lock()
        self._db = sqlite3.connect(path, check_same_thread=False)
        self._db.row_factory = sqlite3.Row
        self._db.execute("PRAGMA journal_mode=WAL")
        self._db.execute("""
            CREATE TABLE IF NOT EXISTS messages (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              direction TEXT NOT NULL,
              account_email TEXT NOT NULL,
              message_id TEXT NOT NULL,
              thread_key TEXT,
              sender TEXT,
              recipient TEXT,
              subject TEXT,
              body TEXT,
              reply_to_message_id TEXT,
              provider_message_id TEXT,
              status TEXT NOT NULL,
              error TEXT,
              created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
              UNIQUE(direction, account_email, message_id)
            )
        """)
        self._ensure_column("messages", "mail_date", "TEXT")
        self._ensure_column("messages", "imap_uid", "TEXT")
        self._ensure_column("messages", "imap_folder", "TEXT")
        self._ensure_column("messages", "deleted_at", "TEXT")
        self._ensure_column("messages", "delete_mode", "TEXT")
        self._db.execute("""
            CREATE TABLE IF NOT EXISTS events (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              category TEXT NOT NULL,
              level TEXT NOT NULL,
              text TEXT NOT NULL,
              created_at TEXT NOT NULL
            )
        """)
        self._db.execute("""
            CREATE TABLE IF NOT EXISTS api_runs (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              kind TEXT NOT NULL,
              status TEXT NOT NULL,
              model TEXT NOT NULL,
              reasoning_effort TEXT,
              input_path TEXT,
              output_path TEXT,
              response_id TEXT,
              request_summary TEXT,
              response_summary TEXT,
              error TEXT,
              elapsed_ms INTEGER,
              started_at TEXT NOT NULL,
              finished_at TEXT
            )
        """)
        self._db.execute("CREATE INDEX IF NOT EXISTS idx_messages_direction_id ON messages(direction, id DESC)")
        self._db.execute("CREATE INDEX IF NOT EXISTS idx_events_id ON events(id DESC)")
        self._db.execute("CREATE INDEX IF NOT EXISTS idx_api_runs_id ON api_runs(id DESC)")
        self._db.commit()

    def _ensure_column(self, table: str, column: str, declaration: str) -> None:
        columns = {str(row[1]) for row in self._db.execute(f"PRAGMA table_info({table})").fetchall()}
        if column not in columns:
            self._db.execute(f"ALTER TABLE {table} ADD COLUMN {column} {declaration}")

    @staticmethod
    def _now() -> str:
        return datetime.now().strftime("%Y-%m-%d %H:%M:%S")

    def seen(self, account: str, message_id: str) -> bool:
        with self._lock:
            row = self._db.execute(
                "SELECT 1 FROM messages WHERE direction='in' AND account_email=? AND message_id=?",
                (account, message_id),
            ).fetchone()
        return bool(row)

    def add_inbound(self, *, account: str, message_id: str, thread_key: str, sender: str,
                    recipient: str, subject: str, body: str, status: str,
                    mail_date: str = "", imap_uid: str = "", imap_folder: str = "") -> None:
        with self._lock:
            self._db.execute(
                """INSERT OR IGNORE INTO messages
                (direction,account_email,message_id,thread_key,sender,recipient,subject,body,status,
                 mail_date,imap_uid,imap_folder,created_at)
                VALUES('in',?,?,?,?,?,?,?,?,?,?,?,?)""",
                (account, message_id, thread_key, sender, recipient, subject, body, status,
                 mail_date, imap_uid, imap_folder, self._now()),
            )
            self._db.commit()

    def add_outbound(self, *, account: str, message_id: str, thread_key: str, sender: str,
                     recipient: str, subject: str, body: str, reply_to: str,
                     provider_message_id: str, status: str, error: str = "",
                     mail_date: str = "") -> None:
        with self._lock:
            self._db.execute(
                """INSERT OR IGNORE INTO messages
                (direction,account_email,message_id,thread_key,sender,recipient,subject,body,
                 reply_to_message_id,provider_message_id,status,error,mail_date,created_at)
                VALUES('out',?,?,?,?,?,?,?,?,?,?,?,?,?)""",
                (account, message_id, thread_key, sender, recipient, subject, body,
                 reply_to, provider_message_id, status, error, mail_date or self._now(), self._now()),
            )
            self._db.commit()

    def set_inbound_status(self, account: str, message_id: str, status: str) -> None:
        with self._lock:
            self._db.execute(
                "UPDATE messages SET status=? WHERE direction='in' AND account_email=? AND message_id=?",
                (status, account, message_id),
            )
            self._db.commit()

    def mark_deleted(self, message_row_id: int, delete_mode: str) -> None:
        with self._lock:
            cur = self._db.execute(
                "UPDATE messages SET deleted_at=?, delete_mode=? WHERE id=? AND direction='in' AND deleted_at IS NULL",
                (self._now(), delete_mode, message_row_id),
            )
            if cur.rowcount != 1:
                raise RuntimeError("mensagem não encontrada ou já removida")
            self._db.commit()

    def add_event(self, category: str, level: str, text: str) -> None:
        with self._lock:
            self._db.execute(
                "INSERT INTO events(category,level,text,created_at) VALUES(?,?,?,?)",
                (category, level, text, self._now()),
            )
            self._db.execute(
                "DELETE FROM events WHERE id NOT IN (SELECT id FROM events ORDER BY id DESC LIMIT 5000)"
            )
            self._db.commit()

    def list_messages(self, direction: str, limit: int = 500) -> list[dict]:
        if direction not in {"in", "out"}:
            raise ValueError("direction inválida")
        with self._lock:
            rows = self._db.execute(
                """SELECT id,direction,account_email,message_id,thread_key,sender,recipient,subject,body,
                          reply_to_message_id,provider_message_id,status,error,created_at,mail_date,
                          imap_uid,imap_folder,deleted_at,delete_mode
                   FROM messages WHERE direction=? AND deleted_at IS NULL ORDER BY id DESC LIMIT ?""",
                (direction, limit),
            ).fetchall()
        return [dict(row) for row in rows]

    def get_message(self, message_id: int) -> dict | None:
        with self._lock:
            row = self._db.execute(
                """SELECT id,direction,account_email,message_id,thread_key,sender,recipient,subject,body,
                          reply_to_message_id,provider_message_id,status,error,created_at,mail_date,
                          imap_uid,imap_folder,deleted_at,delete_mode
                   FROM messages WHERE id=?""",
                (message_id,),
            ).fetchone()
        return dict(row) if row else None

    def recent_events(self, limit: int = 500) -> list[dict]:
        with self._lock:
            rows = self._db.execute(
                "SELECT id,category,level,text,created_at FROM events ORDER BY id DESC LIMIT ?",
                (limit,),
            ).fetchall()
        return [dict(row) for row in rows]

    def recent(self, limit: int = 12) -> list[tuple]:
        with self._lock:
            rows = self._db.execute(
                """SELECT created_at,direction,account_email,sender,recipient,subject,status
                   FROM messages ORDER BY id DESC LIMIT ?""", (limit,)
            ).fetchall()
        return [tuple(row) for row in rows]
    def add_api_run(self, *, kind: str, status: str, model: str, reasoning_effort: str, input_path: str,
                    output_path: str, request_summary: str) -> int:
        with self._lock:
            cur = self._db.execute(
                """INSERT INTO api_runs(kind,status,model,reasoning_effort,input_path,output_path,request_summary,started_at)
                   VALUES(?,?,?,?,?,?,?,?)""",
                (kind, status, model, reasoning_effort, input_path, output_path, request_summary, self._now()),
            )
            self._db.commit()
            return int(cur.lastrowid)

    def update_api_run(self, run_id: int, *, status: str | None = None, output_path: str | None = None,
                       response_id: str | None = None, response_summary: str | None = None,
                       error: str | None = None, elapsed_ms: int | None = None, finished: bool = False) -> None:
        values = []
        params = []
        for column, value in (("status", status), ("output_path", output_path), ("response_id", response_id),
                              ("response_summary", response_summary), ("error", error), ("elapsed_ms", elapsed_ms)):
            if value is not None:
                values.append(f"{column}=?")
                params.append(value)
        if finished:
            values.append("finished_at=?")
            params.append(self._now())
        if not values:
            return
        params.append(run_id)
        with self._lock:
            self._db.execute(f"UPDATE api_runs SET {', '.join(values)} WHERE id=?", params)
            self._db.commit()

    def list_api_runs(self, limit: int = 200) -> list[dict]:
        with self._lock:
            rows = self._db.execute(
                """SELECT id,kind,status,model,reasoning_effort,input_path,output_path,response_id,
                          request_summary,response_summary,error,elapsed_ms,started_at,finished_at
                   FROM api_runs ORDER BY id DESC LIMIT ?""",
                (limit,),
            ).fetchall()
        return [dict(row) for row in rows]

    def get_api_run(self, run_id: int) -> dict | None:
        with self._lock:
            row = self._db.execute(
                """SELECT id,kind,status,model,reasoning_effort,input_path,output_path,response_id,
                          request_summary,response_summary,error,elapsed_ms,started_at,finished_at
                   FROM api_runs WHERE id=?""", (run_id,)
            ).fetchone()
        return dict(row) if row else None

