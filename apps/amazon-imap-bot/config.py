from __future__ import annotations

import json
import os
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class Account:
    email: str
    password: str
    display_name: str
    enabled: bool = True


@dataclass(frozen=True)
class Settings:
    config_root: Path
    accounts: tuple[Account, ...]
    imap_host: str
    imap_port: int
    imap_folder: str
    poll_seconds: int
    aws_profile: str
    aws_region: str
    openai_api_key: str
    openai_model: str
    openai_base_url: str
    openai_reasoning_effort: str
    openai_timeout_seconds: int
    openai_output_dir: Path
    openai_test_zip: Path
    functions_config: Path
    auto_reply_enabled: bool
    sound_enabled: bool
    database_path: Path
    sound_file: Path
    imap_trash_folder: str = ""


def _env_file(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    if not path.is_file():
        return values
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in raw:
            continue
        key, value = raw.split("=", 1)
        value = value.strip()
        if value[:1] in {'"', "'"} and value[-1:] == value[:1]:
            value = value[1:-1]
        values[key.strip()] = value
    return values


def _bool(value: str, default: bool) -> bool:
    if not value:
        return default
    return value.strip().lower() in {"1", "true", "yes", "on", "sim"}


def _project_root() -> Path:
    return Path(__file__).resolve().parents[2]


def load_settings() -> Settings:
    project_root = _project_root()
    config_root = Path(os.environ.get(
        "AMAZON_IMAP_BOT_CONFIG_ROOT",
        project_root / ".config" / "amazon-imap-bot",
    )).expanduser()
    env = _env_file(config_root / "settings.env")

    accounts_raw = env.get("IMAP_ACCOUNTS_JSON", "[]")
    try:
        payload = json.loads(accounts_raw)
    except json.JSONDecodeError as exc:
        raise RuntimeError("IMAP_ACCOUNTS_JSON inválido em settings.env") from exc
    accounts: list[Account] = []
    for item in payload:
        if not isinstance(item, dict):
            continue
        email = str(item.get("email", "")).strip()
        password = str(item.get("password", ""))
        if not email:
            continue
        accounts.append(Account(
            email=email,
            password=password,
            display_name=str(item.get("display_name") or email),
            enabled=bool(item.get("enabled", True)),
        ))

    api_key = env.get("OPENAI_API_KEY", "").strip()
    if not api_key:
        fallback = Path(env.get(
            "OPENAI_SETTINGS_FALLBACK",
            project_root / ".config" / "gpt-console" / "settings.env",
        )).expanduser()
        api_key = _env_file(fallback).get("OPENAI_API_KEY", "").strip()

    return Settings(
        config_root=config_root,
        accounts=tuple(accounts),
        imap_host=env.get("IMAP_HOST", "imap.mail.us-east-1.awsapps.com"),
        imap_port=int(env.get("IMAP_PORT", "993")),
        imap_folder=env.get("IMAP_FOLDER", "INBOX"),
        imap_trash_folder=env.get("IMAP_TRASH_FOLDER", "").strip(),
        poll_seconds=max(10, int(env.get("POLL_SECONDS", "30"))),
        aws_profile=env.get("AWS_PROFILE", "default"),
        aws_region=env.get("AWS_REGION", "us-east-1"),
        openai_api_key=api_key,
        openai_model=env.get("OPENAI_MODEL", "gpt-5.6"),
        openai_base_url=env.get("OPENAI_BASE_URL", "https://api.openai.com/v1"),
        openai_reasoning_effort=env.get("OPENAI_REASONING_EFFORT", "medium").strip().lower() or "medium",
        openai_timeout_seconds=max(30, int(env.get("OPENAI_TIMEOUT_SECONDS", "300"))),
        openai_output_dir=Path(env.get("OPENAI_OUTPUT_DIR", Path.home() / "Downloads")).expanduser(),
        openai_test_zip=Path(env.get("OPENAI_TEST_ZIP", config_root / "api-test-input.zip")).expanduser(),
        functions_config=Path(env.get("FUNCTIONS_CONFIG", config_root / "functions.json")).expanduser(),
        auto_reply_enabled=_bool(env.get("AUTO_REPLY_ENABLED", "true"), True),
        sound_enabled=_bool(env.get("SOUND_ENABLED", "true"), True),
        database_path=Path(env.get("DATABASE_PATH", config_root / "mailbot.sqlite3")).expanduser(),
        sound_file=Path(env.get(
            "SOUND_FILE",
            project_root / "assets" / "sounds" / "soft-notification.wav",
        )).expanduser(),
    )
