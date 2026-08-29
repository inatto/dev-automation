from __future__ import annotations

import sqlite3
import threading
from pathlib import Path
from typing import Iterable


class Store:
    def __init__(self, path: Path):
        path.parent.mkdir(parents=True, exist_ok=True)
        self.path = path
        self._lock = threading.Lock()
        self._db = sqlite3.connect(path, check_same_thread=False)
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
        self._db.commit()

    def seen(self, account: str, message_id: str) -> bool:
        with self._lock:
            row = self._db.execute(
                "SELECT 1 FROM messages WHERE direction='in' AND account_email=? AND message_id=?",
                (account, message_id),
            ).fetchone()
        return bool(row)

    def add_inbound(self, *, account: str, message_id: str, thread_key: str, sender: str,
                    recipient: str, subject: str, body: str, status: str) -> None:
        with self._lock:
            self._db.execute(
                """INSERT OR IGNORE INTO messages
                (direction,account_email,message_id,thread_key,sender,recipient,subject,body,status)
                VALUES('in',?,?,?,?,?,?,?,?)""",
                (account, message_id, thread_key, sender, recipient, subject, body, status),
            )
            self._db.commit()

    def add_outbound(self, *, account: str, message_id: str, thread_key: str, sender: str,
                     recipient: str, subject: str, body: str, reply_to: str,
                     provider_message_id: str, status: str, error: str = "") -> None:
        with self._lock:
            self._db.execute(
                """INSERT OR IGNORE INTO messages
                (direction,account_email,message_id,thread_key,sender,recipient,subject,body,
                 reply_to_message_id,provider_message_id,status,error)
                VALUES('out',?,?,?,?,?,?,?,?,?,?,?)""",
                (account, message_id, thread_key, sender, recipient, subject, body,
                 reply_to, provider_message_id, status, error),
            )
            self._db.commit()

    def recent(self, limit: int = 12) -> list[tuple]:
        with self._lock:
            return self._db.execute(
                """SELECT created_at,direction,account_email,sender,recipient,subject,status
                   FROM messages ORDER BY id DESC LIMIT ?""", (limit,)
            ).fetchall()
