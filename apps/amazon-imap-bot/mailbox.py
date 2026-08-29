from __future__ import annotations

import imaplib
import ssl
from config import Account, Settings


class MailboxClient:
    def __init__(self, settings: Settings):
        self.settings = settings

    @staticmethod
    def _quoted_mailbox(folder: str) -> str:
        escaped = folder.replace("\\", "\\\\").replace('"', '\\"')
        return f'"{escaped}"'

    @staticmethod
    def _capabilities(conn) -> set[str]:
        values: set[str] = set()
        for raw in getattr(conn, "capabilities", ()) or ():
            text = raw.decode("ascii", errors="ignore") if isinstance(raw, bytes) else str(raw)
            values.update(token.upper() for token in text.split())
        return values

    def connect(self, account: Account, folder: str | None = None, readonly: bool = False):
        conn = imaplib.IMAP4_SSL(
            self.settings.imap_host,
            self.settings.imap_port,
            ssl_context=ssl.create_default_context(),
        )
        try:
            conn.login(account.email, account.password)
            selected = folder or self.settings.imap_folder
            status, _ = conn.select(self._quoted_mailbox(selected), readonly=readonly)
            if status != "OK":
                raise RuntimeError(f"não foi possível abrir a pasta {selected}")
            return conn
        except Exception:
            try:
                conn.logout()
            except Exception:
                pass
            raise

    @staticmethod
    def logout(conn) -> None:
        if conn is None:
            return
        try:
            conn.logout()
        except Exception:
            pass

    @staticmethod
    def uid_validity(conn) -> str:
        try:
            _, data = conn.response("UIDVALIDITY")
        except Exception:
            data = None
        if data:
            value = data[-1]
            if isinstance(value, bytes):
                return value.decode("ascii", errors="ignore") or "unknown"
            return str(value) or "unknown"
        return "unknown"

    @staticmethod
    def search_uids(conn, criterion: str) -> list[str]:
        status, data = conn.uid("search", None, criterion)
        if status != "OK":
            raise RuntimeError(f"falha ao consultar mensagens: {criterion}")
        if not data or not data[0]:
            return []
        raw_values = data[0].split()
        result: list[str] = []
        for raw in raw_values:
            text = raw.decode("ascii", errors="ignore") if isinstance(raw, bytes) else str(raw)
            if text.isdigit():
                result.append(text)
        return sorted(set(result), key=int)

    @classmethod
    def max_uid(cls, conn) -> int:
        values = cls.search_uids(conn, "ALL")
        return max((int(value) for value in values), default=0)

    @staticmethod
    def fetch_raw(conn, uid: str) -> bytes:
        status, parts = conn.uid("fetch", uid, "(BODY.PEEK[])")
        if status != "OK" or not parts:
            raise RuntimeError(f"falha ao baixar UID {uid}")
        raw = next(
            (part[1] for part in parts if isinstance(part, tuple) and len(part) > 1 and isinstance(part[1], bytes)),
            b"",
        )
        if not raw:
            raise RuntimeError(f"mensagem UID {uid} veio sem conteúdo")
        return raw

    def move_selected_to_trash(self, conn, uid: str) -> str:
        if not uid.isdigit():
            raise RuntimeError("UID IMAP inválido para remoção")
        conn.uid("store", uid, "+FLAGS.SILENT", "(\\Seen)")
        target = self._quoted_mailbox(self.settings.imap_trash_folder)
        capabilities = self._capabilities(conn)

        if "MOVE" in capabilities:
            status, _ = conn.uid("move", uid, target)
            if status != "OK":
                raise RuntimeError(f"não foi possível mover UID {uid} para {self.settings.imap_trash_folder}")
            return "move"

        status, _ = conn.uid("copy", uid, target)
        if status != "OK":
            raise RuntimeError(f"não foi possível copiar UID {uid} para {self.settings.imap_trash_folder}")
        status, _ = conn.uid("store", uid, "+FLAGS.SILENT", "(\\Deleted \\Seen)")
        if status != "OK":
            raise RuntimeError(f"não foi possível marcar UID {uid} como removido")

        if "UIDPLUS" in capabilities:
            status, _ = conn.uid("expunge", uid)
            if status != "OK":
                raise RuntimeError(f"não foi possível concluir a remoção do UID {uid}")
            return "copy-delete"

        # Sem UID EXPUNGE, um EXPUNGE global poderia apagar mensagens de terceiros
        # já marcadas como \Deleted. A cópia foi criada e a origem fica marcada
        # como removida, sem expurgar outras mensagens da pasta.
        return "copy-mark-deleted"

    def move_to_trash(self, account: Account, uid: str, folder: str) -> str:
        conn = self.connect(account, folder=folder, readonly=False)
        try:
            return self.move_selected_to_trash(conn, uid)
        finally:
            self.logout(conn)

    def mark_seen(self, account: Account, uid: str, folder: str) -> None:
        if not uid.isdigit():
            return
        conn = self.connect(account, folder=folder, readonly=False)
        try:
            status, _ = conn.uid("store", uid, "+FLAGS.SILENT", "(\\Seen)")
            if status != "OK":
                raise RuntimeError(f"não foi possível marcar UID {uid} como lido")
        finally:
            self.logout(conn)
