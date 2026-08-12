from __future__ import annotations

import base64
import re
import time
from email import message_from_bytes
from pathlib import Path

from google.auth.transport.requests import Request
from google.oauth2.credentials import Credentials
from google_auth_oauthlib.flow import InstalledAppFlow
from googleapiclient.discovery import build


SCOPES = ["https://www.googleapis.com/auth/gmail.readonly"]
OTP_RE = re.compile(r"(?<!\d)(\d{6})(?!\d)")


class GmailOtpReader:
    def __init__(self, client_secret_file: Path, token_file: Path) -> None:
        self.client_secret_file = client_secret_file
        self.token_file = token_file

    def _credentials(self) -> Credentials:
        credentials: Credentials | None = None
        if self.token_file.exists():
            credentials = Credentials.from_authorized_user_file(str(self.token_file), SCOPES)
        if credentials and credentials.expired and credentials.refresh_token:
            credentials.refresh(Request())
        if not credentials or not credentials.valid:
            if not self.client_secret_file.exists():
                raise RuntimeError(f"Credencial OAuth Gmail não encontrada: {self.client_secret_file}")
            flow = InstalledAppFlow.from_client_secrets_file(str(self.client_secret_file), SCOPES)
            credentials = flow.run_local_server(port=0)
            self.token_file.parent.mkdir(parents=True, exist_ok=True)
            self.token_file.write_text(credentials.to_json(), encoding="utf-8")
        return credentials

    @staticmethod
    def _extract_text(payload: dict) -> str:
        chunks: list[str] = []

        def visit(part: dict) -> None:
            body = part.get("body") or {}
            data = body.get("data")
            mime = str(part.get("mimeType") or "")
            if data and (mime.startswith("text/") or not mime):
                decoded = base64.urlsafe_b64decode(data + "=" * (-len(data) % 4))
                chunks.append(decoded.decode("utf-8", errors="ignore"))
            for child in part.get("parts") or []:
                visit(child)

        visit(payload)
        return "\n".join(chunks)

    def wait_for_code(self, query: str, timeout_seconds: int = 180, poll_seconds: int = 3) -> str:
        service = build("gmail", "v1", credentials=self._credentials(), cache_discovery=False)
        deadline = time.monotonic() + timeout_seconds
        seen: set[str] = set()
        while time.monotonic() < deadline:
            response = service.users().messages().list(userId="me", q=query, maxResults=10).execute()
            for item in response.get("messages", []):
                message_id = item["id"]
                if message_id in seen:
                    continue
                seen.add(message_id)
                message = service.users().messages().get(userId="me", id=message_id, format="full").execute()
                text = self._extract_text(message.get("payload") or {})
                match = OTP_RE.search(text)
                if match:
                    return match.group(1)
            time.sleep(poll_seconds)
        raise TimeoutError(f"Nenhum código de 6 dígitos encontrado no Gmail em {timeout_seconds}s.")
