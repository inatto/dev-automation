from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path

from dotenv import load_dotenv


ROOT = Path(__file__).resolve().parents[1]
load_dotenv(ROOT / ".env")


def _bool(name: str, default: bool = False) -> bool:
    raw = os.getenv(name)
    if raw is None:
        return default
    return raw.strip().lower() in {"1", "true", "yes", "on"}


@dataclass(frozen=True)
class Settings:
    contaja_base_url: str = os.getenv("CONTAJA_BASE_URL", "https://app.contaja.com.br/")
    contaja_email: str = os.getenv("CONTAJA_EMAIL", "").strip()
    contaja_password: str = os.getenv("CONTAJA_PASSWORD", "")
    contaja_headless: bool = _bool("CONTAJA_HEADLESS", False)
    contaja_otp_gmail_query: str = os.getenv("CONTAJA_OTP_GMAIL_QUERY", "contaja newer_than:15m").strip()
    contaja_otp_timeout_seconds: int = int(os.getenv("CONTAJA_OTP_TIMEOUT_SECONDS", "180"))
    gmail_client_secret_file: str = os.getenv("GMAIL_CLIENT_SECRET_FILE", "").strip()
    gmail_token_file: str = os.getenv("GMAIL_TOKEN_FILE", "var/gmail-token.json").strip()

    @property
    def gmail_token_path(self) -> Path:
        path = Path(self.gmail_token_file).expanduser()
        return path if path.is_absolute() else ROOT / path

    @property
    def gmail_client_secret_path(self) -> Path | None:
        if not self.gmail_client_secret_file:
            return None
        path = Path(self.gmail_client_secret_file).expanduser()
        return path if path.is_absolute() else ROOT / path
