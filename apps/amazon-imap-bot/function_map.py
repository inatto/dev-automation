from __future__ import annotations

import json
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
    arguments: dict


class FunctionMap:
    """Autorizações locais e definições das funções que podem ser expostas ao GPT."""

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

    def function_entry(self, name: str) -> dict:
        functions = self.payload.get("functions") or {}
        entry = functions.get(name) if isinstance(functions, dict) else None
        return dict(entry) if isinstance(entry, dict) else {}

    def function_enabled(self, name: str) -> bool:
        entry = self.function_entry(name)
        return bool(entry) and bool(entry.get("enabled", True))

    def authorized_function_names(self, sender: str) -> list[str]:
        return sorted(
            name for name in self.sender_functions(sender)
            if self.function_enabled(name)
        )

    @staticmethod
    def _default_parameters(name: str) -> dict:
        if name in {"api_zip_test", "project_zip_edit"}:
            request_description = (
                "Pedido original de alteração do projeto. Preserve o sentido e os detalhes do remetente."
                if name == "project_zip_edit"
                else "Pergunta ou instrução que deve ser respondida dentro do teste ZIP. "
                     "Se não houver uma pergunta separada, use uma confirmação objetiva de processamento do ZIP."
            )
            return {
                "type": "object",
                "properties": {
                    "reasoning_level": {
                        "type": "integer",
                        "enum": [0, 1, 2, 3, 4, 5],
                        "description": (
                            "Nível solicitado pelo usuário: 0=none, 1=low, 2=medium, "
                            "3=high, 4=xhigh, 5=max."
                        ),
                    },
                    "request_text": {
                        "type": "string",
                        "description": request_description,
                    },
                },
                "required": ["reasoning_level", "request_text"],
                "additionalProperties": False,
            }
        return {
            "type": "object",
            "properties": {},
            "required": [],
            "additionalProperties": False,
        }

    def openai_tools_for_sender(self, sender: str) -> list[dict]:
        """Expõe ao modelo somente funções que este remetente pode executar."""
        tools: list[dict] = []
        for name in self.authorized_function_names(sender):
            entry = self.function_entry(name)
            parameters = entry.get("parameters")
            if not isinstance(parameters, dict):
                parameters = self._default_parameters(name)
            tools.append({
                "type": "function",
                "name": name,
                "description": str(entry.get("description") or f"Executa a função {name}."),
                "parameters": parameters,
                "strict": True,
            })
        return tools

    def _allowed_levels(self, name: str) -> set[int]:
        entry = self.function_entry(name)
        raw = entry.get("allowed_reasoning_levels", list(REASONING_LEVELS))
        if not isinstance(raw, list):
            return set(REASONING_LEVELS)
        allowed: set[int] = set()
        for value in raw:
            try:
                level = int(value)
            except (TypeError, ValueError):
                continue
            if level in REASONING_LEVELS:
                allowed.add(level)
        return allowed or set(REASONING_LEVELS)

    def request_from_tool_call(self, sender: str, name: str, arguments: str | dict) -> FunctionRequest:
        """Valida novamente no Python a decisão/argumentos retornados pelo GPT."""
        sender_key = str(sender or "").strip().lower()
        if name not in self.authorized_function_names(sender_key):
            raise PermissionError(f"função {name} não autorizada para {sender_key}")

        if isinstance(arguments, str):
            try:
                args = json.loads(arguments or "{}")
            except json.JSONDecodeError as exc:
                raise ValueError(f"argumentos JSON inválidos para {name}") from exc
        elif isinstance(arguments, dict):
            args = dict(arguments)
        else:
            raise ValueError(f"argumentos inválidos para {name}")

        if name not in {"api_zip_test", "project_zip_edit"}:
            raise RuntimeError(f"função não implementada: {name}")

        try:
            level = int(args.get("reasoning_level"))
        except (TypeError, ValueError) as exc:
            raise ValueError("nível da API deve ser um número entre 0 e 5") from exc
        if level not in REASONING_LEVELS:
            raise ValueError("nível da API deve estar entre 0 e 5")
        if level not in self._allowed_levels(name):
            raise ValueError(f"nível {level} não permitido para a função {name}")

        request_text = str(args.get("request_text") or "").strip()
        if not request_text:
            request_text = (
                "Confirme que o arquivo ZIP de teste foi processado com sucesso."
                if name == "api_zip_test"
                else "Execute a alteração de projeto solicitada no e-mail."
            )
        request_text = request_text[:8000]

        return FunctionRequest(
            name=name,
            sender=sender_key,
            reasoning_level=level,
            reasoning_effort=REASONING_LEVELS[level],
            request_text=request_text,
            arguments=args,
        )
