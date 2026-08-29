from __future__ import annotations

import json
import os
from dataclasses import asdict, dataclass, fields
from pathlib import Path
from typing import Any

from .errors import ConfigurationError
from .paths import AppPaths


@dataclass(frozen=True)
class Settings:
    api_key: str = ""
    admin_api_key: str = ""
    organization_id: str = ""
    project_id: str = ""
    base_url: str = "https://api.openai.com/v1"
    text_model: str = "gpt-5.6"
    transcription_model: str = "gpt-transcribe"
    zip_model: str = "gpt-5.6"
    request_timeout_seconds: int = 300
    recording_seconds: int = 8
    code_root: str = "/home/daniel/Code"
    downloads_root: str = "/home/daniel/Downloads"
    max_zip_mb: int = 500
    container_memory: str = "4g"

    @property
    def configured(self) -> bool:
        return bool(self.api_key.strip())

    @property
    def masked_api_key(self) -> str:
        return mask_secret(self.api_key)

    @property
    def masked_admin_api_key(self) -> str:
        return mask_secret(self.admin_api_key)

    def public_dict(self) -> dict[str, Any]:
        data = asdict(self)
        data["api_key"] = self.masked_api_key
        data["admin_api_key"] = self.masked_admin_api_key
        data["configured"] = self.configured
        return data


ENV_KEYS = {
    "OPENAI_API_KEY": "api_key",
    "OPENAI_ADMIN_KEY": "admin_api_key",
    "OPENAI_ORGANIZATION_ID": "organization_id",
    "OPENAI_PROJECT_ID": "project_id",
    "OPENAI_BASE_URL": "base_url",
    "OPENAI_TEXT_MODEL": "text_model",
    "OPENAI_TRANSCRIPTION_MODEL": "transcription_model",
    "OPENAI_ZIP_MODEL": "zip_model",
    "REQUEST_TIMEOUT_SECONDS": "request_timeout_seconds",
    "RECORDING_SECONDS": "recording_seconds",
    "CODE_ROOT": "code_root",
    "DOWNLOADS_ROOT": "downloads_root",
    "MAX_ZIP_MB": "max_zip_mb",
    "CONTAINER_MEMORY": "container_memory",
}
INTEGER_FIELDS = {
    "request_timeout_seconds": (10, 3600),
    "recording_seconds": (1, 120),
    "max_zip_mb": (1, 512),
}
MEMORY_VALUES = {"1g", "4g", "16g", "64g"}


def mask_secret(value: str) -> str:
    value = value.strip()
    if not value:
        return "não configurada"
    if len(value) <= 8:
        return "********"
    return f"{value[:3]}…{value[-4:]}"


def _decode_value(raw: str) -> str:
    raw = raw.strip()
    if not raw:
        return ""
    if raw[0:1] in {'"', "'"}:
        try:
            if raw[0] == '"':
                return str(json.loads(raw))
            return raw[1:-1] if raw.endswith("'") else raw[1:]
        except (ValueError, TypeError):
            return raw.strip('"\'')
    return raw


def _encode_value(value: Any) -> str:
    return json.dumps(str(value), ensure_ascii=False)


class ConfigStore:
    def __init__(self, paths: AppPaths | None = None):
        self.paths = paths or AppPaths.discover()
        self.path = self.paths.config_root / "settings.env"

    def load(self) -> Settings:
        values: dict[str, str] = {}
        if self.path.exists():
            try:
                lines = self.path.read_text(encoding="utf-8").splitlines()
            except OSError as exc:
                raise ConfigurationError(f"não foi possível ler {self.path}: {exc}") from exc
            for number, raw in enumerate(lines, 1):
                line = raw.strip()
                if not line or line.startswith("#"):
                    continue
                if "=" not in raw:
                    raise ConfigurationError(f"linha inválida em {self.path}:{number}")
                key, value = raw.split("=", 1)
                field_name = ENV_KEYS.get(key.strip())
                if field_name:
                    values[field_name] = _decode_value(value)

        # Variáveis do processo funcionam como fallback, mas nunca são gravadas
        # automaticamente no projeto.
        for env_key, field_name in ENV_KEYS.items():
            if not values.get(field_name) and os.environ.get(env_key):
                values[field_name] = os.environ[env_key]

        for name, (minimum, maximum) in INTEGER_FIELDS.items():
            if name not in values:
                continue
            try:
                parsed = int(values[name])
            except ValueError as exc:
                raise ConfigurationError(f"{name} deve ser inteiro") from exc
            if not minimum <= parsed <= maximum:
                raise ConfigurationError(f"{name} deve ficar entre {minimum} e {maximum}")
            values[name] = parsed  # type: ignore[assignment]

        settings = Settings(**values)
        self.validate(settings)
        return settings

    def validate(self, settings: Settings) -> None:
        if not settings.base_url.startswith(("https://", "http://")):
            raise ConfigurationError("OPENAI_BASE_URL deve começar com https:// ou http://")
        if not settings.text_model or not settings.transcription_model or not settings.zip_model:
            raise ConfigurationError("os três modelos precisam estar preenchidos")
        if settings.container_memory not in MEMORY_VALUES:
            raise ConfigurationError("CONTAINER_MEMORY deve ser 1g, 4g, 16g ou 64g")
        for name, (minimum, maximum) in INTEGER_FIELDS.items():
            value = int(getattr(settings, name))
            if not minimum <= value <= maximum:
                raise ConfigurationError(f"{name} deve ficar entre {minimum} e {maximum}")

    def save(self, settings: Settings) -> Path:
        self.validate(settings)
        self.paths.config_root.mkdir(parents=True, exist_ok=True)
        ordered: list[tuple[str, Any]] = []
        by_field = {value: key for key, value in ENV_KEYS.items()}
        for item in fields(settings):
            ordered.append((by_field[item.name], getattr(settings, item.name)))
        content = [
            "# GPT Console - configuração local protegida pelo Dev Automation.",
            "# Não copie estas chaves para código, logs ou catálogos de ações.",
        ]
        content.extend(f"{key}={_encode_value(value)}" for key, value in ordered)
        self._atomic_write("\n".join(content) + "\n")
        return self.path

    def update(self, current: Settings, **changes: Any) -> Settings:
        data = asdict(current)
        data.update(changes)
        for name in INTEGER_FIELDS:
            if name in data:
                data[name] = int(data[name])
        updated = Settings(**data)
        self.save(updated)
        return updated

    def _atomic_write(self, content: str) -> None:
        temp = self.path.with_suffix(self.path.suffix + ".tmp")
        old_umask = os.umask(0o077)
        try:
            temp.write_text(content, encoding="utf-8", newline="\n")
            os.chmod(temp, 0o600)
            os.replace(temp, self.path)
        except OSError as exc:
            raise ConfigurationError(f"não foi possível salvar {self.path}: {exc}") from exc
        finally:
            os.umask(old_umask)
            try:
                temp.unlink()
            except OSError:
                pass
