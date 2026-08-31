from __future__ import annotations

import json
import re
import unicodedata
from dataclasses import dataclass
from pathlib import Path


REASONING_LEVELS: dict[int, str] = {
    0: "none",
    1: "low",
    2: "medium",
    3: "high",
    4: "xhigh",
    5: "max",
}


@dataclass(frozen=True)
class FunctionRequest:
    name: str
    sender: str
    reasoning_level: int
    reasoning_effort: str
    request_text: str


class FunctionMap:
    """Carrega autorizações locais e reconhece comandos de funções em e-mails."""

    def __init__(self, path: Path):
        self.path = Path(path)
        self.payload = self._load()

    def _load(self) -> dict:
        if not self.path.is_file():
            return {"version": 1, "senders": {}, "functions": {}}
        try:
            payload = json.loads(self.path.read_text(encoding="utf-8"))
        except json.JSONDecodeError as exc:
            raise RuntimeError(f"JSON inválido em {self.path}") from exc
        if not isinstance(payload, dict):
            raise RuntimeError(f"configuração de funções inválida em {self.path}")
        return payload

    @staticmethod
    def _normalize(text: str) -> str:
        value = unicodedata.normalize("NFKD", str(text or ""))
        value = "".join(ch for ch in value if not unicodedata.combining(ch))
        return " ".join(value.lower().split())

    def sender_functions(self, sender: str) -> set[str]:
        senders = self.payload.get("senders") or {}
        if not isinstance(senders, dict):
            return set()
        entry = senders.get(str(sender or "").strip().lower())
        if not isinstance(entry, dict) or not bool(entry.get("enabled", True)):
            return set()
        functions = entry.get("functions") or []
        if not isinstance(functions, list):
            return set()
        return {str(name).strip() for name in functions if str(name).strip()}

    def function_enabled(self, name: str) -> bool:
        functions = self.payload.get("functions") or {}
        entry = functions.get(name) if isinstance(functions, dict) else None
        return isinstance(entry, dict) and bool(entry.get("enabled", True))

    def _aliases(self, name: str) -> list[str]:
        functions = self.payload.get("functions") or {}
        entry = functions.get(name) if isinstance(functions, dict) else None
        if not isinstance(entry, dict):
            return []
        aliases = entry.get("aliases") or []
        if not isinstance(aliases, list):
            return []
        return [self._normalize(str(alias)) for alias in aliases if str(alias).strip()]

    def _default_level(self, name: str) -> int:
        functions = self.payload.get("functions") or {}
        entry = functions.get(name) if isinstance(functions, dict) else None
        value = entry.get("default_reasoning_level", 2) if isinstance(entry, dict) else 2
        try:
            level = int(value)
        except (TypeError, ValueError):
            level = 2
        return level if level in REASONING_LEVELS else 2

    def _allowed_levels(self, name: str) -> set[int]:
        functions = self.payload.get("functions") or {}
        entry = functions.get(name) if isinstance(functions, dict) else None
        raw = entry.get("allowed_reasoning_levels", list(REASONING_LEVELS)) if isinstance(entry, dict) else list(REASONING_LEVELS)
        if not isinstance(raw, list):
            return set(REASONING_LEVELS)
        allowed = set()
        for value in raw:
            try:
                level = int(value)
            except (TypeError, ValueError):
                continue
            if level in REASONING_LEVELS:
                allowed.add(level)
        return allowed or set(REASONING_LEVELS)

    @staticmethod
    def _reasoning_level(text: str, default: int) -> int:
        normalized = FunctionMap._normalize(text)
        match = re.search(r"\b(?:nivel|level)\s*[:=#-]?\s*(\d+)\b", normalized)
        if match:
            level = int(match.group(1))
            if level not in REASONING_LEVELS:
                raise ValueError("nível da API deve estar entre 0 e 5")
            return level
        return default

    @staticmethod
    def _request_text(text: str) -> str:
        """Extrai a instrução depois de 'peça como retorno' ou 'retorno'."""
        raw = str(text or "").strip()
        patterns = (
            r"(?is)\bpe[cç]a\s+como\s+retorno\s*[:\-]?\s*(.+)$",
            r"(?is)\bcomo\s+retorno\s*[:\-]?\s*(.+)$",
            r"(?is)\bretorno\s*[:\-]\s*(.+)$",
        )
        for pattern in patterns:
            match = re.search(pattern, raw)
            if match:
                result = match.group(1).strip()
                if result:
                    return result[:8000]
        return "Confirme que o arquivo ZIP de teste foi processado com sucesso."

    def detect_name(self, subject: str, body: str) -> str | None:
        text = self._normalize(f"{subject}\n{body}")
        functions = self.payload.get("functions") or {}
        if not isinstance(functions, dict):
            return None
        for name in functions:
            if not self.function_enabled(str(name)):
                continue
            aliases = self._aliases(str(name))
            if any(alias and alias in text for alias in aliases):
                return str(name)
        return None

    def resolve(self, sender: str, subject: str, body: str) -> FunctionRequest | None:
        name = self.detect_name(subject, body)
        if not name:
            return None
        if name not in self.sender_functions(sender):
            return None
        text = f"{subject}\n{body}".strip()
        level = self._reasoning_level(text, self._default_level(name))
        if level not in self._allowed_levels(name):
            raise ValueError(f"nível {level} não permitido para a função {name}")
        return FunctionRequest(
            name=name,
            sender=str(sender or "").strip().lower(),
            reasoning_level=level,
            reasoning_effort=REASONING_LEVELS[level],
            request_text=self._request_text(text),
        )

    def is_command_but_unauthorized(self, sender: str, subject: str, body: str) -> str | None:
        name = self.detect_name(subject, body)
        if not name:
            return None
        if name in self.sender_functions(sender):
            return None
        return name
