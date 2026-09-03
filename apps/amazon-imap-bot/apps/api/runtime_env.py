from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path
from urllib.parse import urlsplit


@dataclass(frozen=True)
class AppRuntime:
    env_name: str
    app_host: str
    app_port: int
    cors_origins: tuple[str, ...]
    app_name: str


def _parse_env(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    if not path.is_file():
        raise RuntimeError(f"configuração da API não encontrada: {path}")
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in raw:
            raise RuntimeError(f"linha inválida em {path}: {raw}")
        key, value = raw.split("=", 1)
        value = value.strip()
        if value[:1] in {'"', "'"} and value[-1:] == value[:1]:
            value = value[1:-1]
        values[key.strip()] = value
    return values


def load_runtime() -> AppRuntime:
    api_root = Path(__file__).resolve().parent
    name = str(os.environ.get("AMAZON_IMAP_BOT_CONFIG_ENV", "")).strip().lower()
    if not name:
        name = "production" if os.environ.get("APP_ENV") == "production" else "local"
    if name not in {"local", "production"}:
        raise RuntimeError("AMAZON_IMAP_BOT_CONFIG_ENV deve ser local ou production")
    values = _parse_env(api_root / "config" / name / "app.env")
    for key, value in values.items():
        os.environ.setdefault(key, value)
    config_root = str(values.get("BOT_CONFIG_ROOT", "")).strip()
    if config_root:
        os.environ.setdefault("AMAZON_IMAP_BOT_CONFIG_ROOT", config_root)
    host = str(values.get("APP_HOST") or "127.0.0.1")
    port = int(values.get("APP_PORT") or 8115)
    if not 1 <= port <= 65535:
        raise RuntimeError("APP_PORT inválido")
    origins = tuple(x.strip().rstrip("/") for x in str(values.get("APP_CORS_ORIGINS") or "").split(",") if x.strip())
    for origin in origins:
        parsed = urlsplit(origin)
        if parsed.scheme not in {"http", "https"} or not parsed.hostname or parsed.path not in {"", "/"}:
            raise RuntimeError(f"origem CORS inválida: {origin}")
    return AppRuntime(
        env_name=name,
        app_host=host,
        app_port=port,
        cors_origins=origins,
        app_name=str(values.get("APP_NAME") or "Amazon IMAP Bot API"),
    )
