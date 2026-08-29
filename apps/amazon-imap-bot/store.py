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
        self._db.execute("""
            CREATE TABLE IF NOT EXISTS events (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              category TEXT NOT NULL,
              level TEXT NOT NULL,
              text TEXT NOT NULL,
              created_at TEXT NOT NULL
            )
        """)
        self._db.execute("CREATE INDEX IF NOT EXISTS idx_messages_direction_id ON messages(direction, id DESC)")
        self._db.execute("CREATE INDEX IF NOT EXISTS idx_events_id ON events(id DESC)")
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
                          imap_uid,imap_folder
                   FROM messages WHERE direction=? ORDER BY id DESC LIMIT ?""",
                (direction, limit),
            ).fetchall()
        return [dict(row) for row in rows]

    def get_message(self, message_id: int) -> dict | None:
        with self._lock:
            row = self._db.execute(
                """SELECT id,direction,account_email,message_id,thread_key,sender,recipient,subject,body,
                          reply_to_message_id,provider_message_id,status,error,created_at,mail_date,
                          imap_uid,imap_folder
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
