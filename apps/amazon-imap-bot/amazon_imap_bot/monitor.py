from __future__ import annotations

import imaplib
import socket
import ssl
import threading
import time
from dataclasses import dataclass
from datetime import datetime
from typing import Callable

from .ai import ReplyGenerator
from .config import Account, Settings
from .message import parse, should_reply
from .ses import SesSender
from .sound import notify
from .store import Store


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
        self.ai = ReplyGenerator(settings.openai_api_key, settings.openai_model, settings.openai_base_url)
        self.ses = SesSender(settings.aws_profile, settings.aws_region)
        self.own = {a.email.lower() for a in settings.accounts}

    def stop(self) -> None:
        self.stop_event.set()

    def _event(self, text: str) -> None:
        self.on_event(f"{datetime.now().strftime('%H:%M:%S')} {text}")

    def run_account_once(self, account: Account) -> None:
        state = self.states[account.email]
        conn = None
        try:
            conn = imaplib.IMAP4_SSL(self.settings.imap_host, self.settings.imap_port, ssl_context=ssl.create_default_context())
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
            for uid in (data[0].split() if data and data[0] else []):
                status, parts = conn.uid("fetch", uid, "(RFC822)")
                if status != "OK" or not parts:
                    continue
                raw = next((part[1] for part in parts if isinstance(part, tuple) and isinstance(part[1], bytes)), b"")
                if not raw:
                    continue
                item = parse(raw)
                if self.store.seen(account.email, item.message_id):
                    continue
                allowed, reason = should_reply(item, self.own)
                self.store.add_inbound(
                    account=account.email, message_id=item.message_id, thread_key=item.thread_key,
                    sender=item.sender_email, recipient=item.recipient, subject=item.subject,
                    body=item.body, status="received" if allowed else f"ignored:{reason}",
                )
                state.received += 1
                self._event(f"RECEBIDO {account.email} <- {item.sender_email} | {item.subject}")
                if self.settings.sound_enabled:
                    notify(self.settings.sound_file)
                if not allowed or not self.settings.auto_reply_enabled:
                    self._event(f"IGNORADO {item.sender_email} | {reason if not allowed else 'auto-resposta desativada'}")
                    continue
                try:
                    body = self.ai.generate(item)
                    local_id, ses_id = self.ses.send_reply(account, item, body)
                    self.store.add_outbound(
                        account=account.email, message_id=local_id, thread_key=item.thread_key,
                        sender=account.email, recipient=item.sender_email,
                        subject=item.subject, body=body, reply_to=item.message_id,
                        provider_message_id=ses_id, status="sent",
                    )
                    state.replied += 1
                    self._event(f"RESPONDIDO {account.email} -> {item.sender_email} | SES {ses_id[-12:]}")
                except Exception as exc:
                    self._event(f"ERRO resposta para {item.sender_email}: {exc}")
        except (imaplib.IMAP4.error, OSError, socket.error, RuntimeError) as exc:
            state.connected = False
            state.last_error = str(exc)
            state.last_check = datetime.now().strftime("%d/%m/%Y %H:%M:%S")
            self._event(f"ERRO {account.email}: {exc}")
        finally:
            if conn is not None:
                try:
                    conn.logout()
                except Exception:
                    pass

    def run_once(self) -> None:
        for account in self.settings.accounts:
            if account.enabled and not self.stop_event.is_set():
                self.run_account_once(account)

    def run_forever(self) -> None:
        while not self.stop_event.is_set():
            self.run_once()
            self.stop_event.wait(self.settings.poll_seconds)
