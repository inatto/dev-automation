from __future__ import annotations

import json
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any, Callable

from .config_store import Settings
from .errors import ApiError, ConfigurationError
from .models import ActionGroup, ActionMatch
from .usage_store import UsageStore


def _object_dump(value: Any) -> Any:
    if hasattr(value, "model_dump"):
        return value.model_dump(mode="json")
    if isinstance(value, dict):
        return {key: _object_dump(item) for key, item in value.items()}
    if isinstance(value, (list, tuple)):
        return [_object_dump(item) for item in value]
    return value


def _walk(value: Any):
    if isinstance(value, dict):
        yield value
        for item in value.values():
            yield from _walk(item)
    elif isinstance(value, list):
        for item in value:
            yield from _walk(item)


def _usage(response: Any) -> tuple[int, int]:
    usage = getattr(response, "usage", None)
    if usage is None:
        return 0, 0
    if isinstance(usage, dict):
        return int(usage.get("input_tokens", 0) or 0), int(usage.get("output_tokens", 0) or 0)
    return int(getattr(usage, "input_tokens", 0) or 0), int(getattr(usage, "output_tokens", 0) or 0)


class OpenAIGateway:
    def __init__(
        self,
        settings: Settings,
        usage_store: UsageStore | None = None,
        client_factory: Callable[..., Any] | None = None,
    ):
        self.settings = settings
        self.usage_store = usage_store or UsageStore()
        self.client_factory = client_factory
        self._client_instance: Any = None

    def _client(self):
        if not self.settings.configured:
            raise ConfigurationError("API não configurada; abra F2 e informe OPENAI_API_KEY")
        if self._client_instance is not None:
            return self._client_instance
        factory = self.client_factory
        if factory is None:
            try:
                from openai import OpenAI
            except ImportError as exc:
                raise ConfigurationError("SDK openai ausente; execute apps/gpt-console/install.sh") from exc
            factory = OpenAI
        kwargs: dict[str, Any] = {
            "api_key": self.settings.api_key,
            "base_url": self.settings.base_url,
            "timeout": self.settings.request_timeout_seconds,
        }
        if self.settings.organization_id:
            kwargs["organization"] = self.settings.organization_id
        if self.settings.project_id:
            kwargs["project"] = self.settings.project_id
        self._client_instance = factory(**kwargs)
        return self._client_instance

    def test_connection(self) -> dict[str, str]:
        try:
            model = self._client().models.retrieve(self.settings.text_model)
        except Exception as exc:  # normalizado para não vazar detalhes internos da SDK
            raise self._api_error("teste da API", exc) from exc
        return {"status": "ok", "model": str(getattr(model, "id", self.settings.text_model))}

    def classify(self, group: ActionGroup, text: str) -> ActionMatch:
        text = text.strip()
        if not text:
            raise ApiError("texto vazio")
        if not group.actions:
            return ActionMatch(matched=False, message=f"O grupo {group.label} ainda não possui ações cadastradas.")
        names = ", ".join(action.name for action in group.actions)
        instructions = (
            "Você é o roteador determinístico de comandos do projeto informado. "
            "Use exclusivamente as funções fornecidas. Chame exatamente uma função somente quando o pedido do usuário "
            "corresponder claramente a uma ação cadastrada e preencha apenas parâmetros sustentados pelo texto. "
            "Nunca invente identificadores ou valores. Se nenhuma ação servir, não chame função alguma e responda em "
            f"português com uma orientação curta citando opções válidas. Ações: {names}."
        )
        if group.instructions:
            instructions += f" Contexto específico: {group.instructions}"
        try:
            response = self._client().responses.create(
                model=self.settings.text_model,
                instructions=instructions,
                input=text,
                tools=group.function_tools(),
                parallel_tool_calls=False,
            )
        except Exception as exc:
            raise self._api_error("identificação da ação", exc) from exc

        input_tokens, output_tokens = _usage(response)
        self.usage_store.record(input_tokens=input_tokens, output_tokens=output_tokens)
        response_id = str(getattr(response, "id", ""))
        payload = _object_dump(getattr(response, "output", []))
        calls = [item for item in _walk(payload) if item.get("type") == "function_call"]
        if len(calls) > 1:
            raise ApiError("a API retornou mais de uma ação; a resposta foi descartada")
        if calls:
            call = calls[0]
            name = str(call.get("name", ""))
            action = group.action(name)
            if action is None:
                raise ApiError(f"a API retornou ação fora do catálogo: {name}")
            raw_arguments = call.get("arguments") or "{}"
            try:
                arguments = json.loads(raw_arguments) if isinstance(raw_arguments, str) else dict(raw_arguments)
            except (json.JSONDecodeError, TypeError, ValueError) as exc:
                raise ApiError(f"parâmetros JSON inválidos para {name}") from exc
            self._validate_arguments(action, arguments)
            arguments = {key: value for key, value in arguments.items() if value is not None}
            return ActionMatch(
                matched=True,
                action=name,
                parameters=arguments,
                response_id=response_id,
                input_tokens=input_tokens,
                output_tokens=output_tokens,
            )
        message = str(getattr(response, "output_text", "") or "Nenhuma ação compatível foi identificada.").strip()
        return ActionMatch(
            matched=False,
            message=message,
            response_id=response_id,
            input_tokens=input_tokens,
            output_tokens=output_tokens,
        )

    @staticmethod
    def _validate_arguments(action, arguments: dict[str, Any]) -> None:
        if not isinstance(arguments, dict):
            raise ApiError(f"parâmetros de {action.name} não são um objeto")
        definitions = {item.name: item for item in action.parameters}
        unknown = sorted(set(arguments) - set(definitions))
        if unknown:
            raise ApiError(f"parâmetros desconhecidos em {action.name}: {', '.join(unknown)}")
        missing = sorted(item.name for item in action.parameters if item.required and item.name not in arguments)
        if missing:
            raise ApiError(f"parâmetros obrigatórios ausentes em {action.name}: {', '.join(missing)}")
        expected = {"string": str, "integer": int, "number": (int, float), "boolean": bool}
        for name, value in arguments.items():
            definition = definitions[name]
            if value is None:
                if definition.required:
                    raise ApiError(f"parâmetro obrigatório nulo em {action.name}.{name}")
                continue
            valid = isinstance(value, expected[definition.type])
            if definition.type in {"integer", "number"} and isinstance(value, bool):
                valid = False
            if not valid:
                raise ApiError(f"tipo inválido para {action.name}.{name}: esperado {definition.type}")
            if definition.enum and value not in definition.enum:
                raise ApiError(f"valor inválido para {action.name}.{name}")

    def transcribe(self, audio_path: Path, duration_seconds: float = 0.0) -> str:
        if not audio_path.is_file():
            raise ApiError(f"arquivo de áudio não encontrado: {audio_path}")
        try:
            with audio_path.open("rb") as audio_file:
                response = self._client().audio.transcriptions.create(
                    model=self.settings.transcription_model,
                    file=audio_file,
                )
        except Exception as exc:
            raise self._api_error("transcrição", exc) from exc
        text = str(getattr(response, "text", "") or "").strip()
        if not text:
            raise ApiError("a transcrição voltou vazia")
        self.usage_store.record(seconds=duration_seconds)
        return text

    def edit_zip(self, source: Path, request_text: str) -> tuple[bytes, str, str, int, int]:
        client = self._client()
        uploaded_id = ""
        try:
            with source.open("rb") as stream:
                uploaded = client.files.create(file=stream, purpose="user_data")
            uploaded_id = str(uploaded.id)
            instructions = (
                "Você edita projetos de software enviados como ZIP. Use obrigatoriamente a ferramenta python. "
                "Extraia o arquivo com proteção contra path traversal, inspecione o projeto antes de alterar, implemente "
                "somente a demanda, preserve LF e os modos POSIX registrados no ZIP, rode validações relevantes e gere "
                "um único ZIP completo na raiz de /mnt/data. O ZIP final deve manter a mesma estrutura de raiz do original, "
                "não pode conter o ZIP de entrada, .git, .venv, node_modules ou segredos novos. Cite o ZIP final na resposta "
                "e resuma objetivamente as alterações e testes. Não devolva patches soltos."
            )
            response = client.responses.create(
                model=self.settings.zip_model,
                instructions=instructions,
                input=(
                    f"Arquivo de entrada disponível no container: {source.name}\n\n"
                    f"Demanda do usuário:\n{request_text.strip()}"
                ),
                tools=[
                    {
                        "type": "code_interpreter",
                        "container": {
                            "type": "auto",
                            "memory_limit": self.settings.container_memory,
                            "file_ids": [uploaded_id],
                        },
                    }
                ],
                tool_choice="required",
            )
            data = _object_dump(response)
            annotations = [
                item
                for item in _walk(data)
                if item.get("type") == "container_file_citation"
                and str(item.get("filename", "")).lower().endswith(".zip")
            ]
            container_id = ""
            file_id = ""
            if annotations:
                selected = annotations[-1]
                container_id = str(selected.get("container_id", ""))
                file_id = str(selected.get("file_id", ""))
            if not container_id:
                calls = [item for item in _walk(data) if item.get("type") == "code_interpreter_call"]
                if calls:
                    container_id = str(calls[-1].get("container_id", ""))
            if container_id and not file_id:
                try:
                    files = list(client.containers.files.list(container_id))
                    candidates = [
                        item
                        for item in files
                        if str(getattr(item, "path", "")).lower().endswith(".zip")
                        and str(getattr(item, "source", "")) == "assistant"
                    ]
                    if candidates:
                        file_id = str(getattr(candidates[-1], "id", ""))
                except Exception:
                    pass
            if not container_id or not file_id:
                raise ApiError("a API concluiu, mas não entregou um ZIP citável para download")
            content = self._download_container_file(container_id, file_id)
            input_tokens, output_tokens = _usage(response)
            self.usage_store.record(input_tokens=input_tokens, output_tokens=output_tokens, zip_job=True)
            return (
                content,
                str(getattr(response, "output_text", "") or "ZIP processado pela API."),
                str(getattr(response, "id", "")),
                input_tokens,
                output_tokens,
            )
        except (ApiError, ConfigurationError):
            raise
        except Exception as exc:
            raise self._api_error("edição do ZIP", exc) from exc
        finally:
            if uploaded_id:
                try:
                    client.files.delete(uploaded_id)
                except Exception:
                    pass

    def _download_container_file(self, container_id: str, file_id: str) -> bytes:
        safe_container = urllib.parse.quote(container_id, safe="")
        safe_file = urllib.parse.quote(file_id, safe="")
        url = f"{self.settings.base_url.rstrip('/')}/containers/{safe_container}/files/{safe_file}/content"
        headers = {"Authorization": f"Bearer {self.settings.api_key}"}
        if self.settings.organization_id:
            headers["OpenAI-Organization"] = self.settings.organization_id
        if self.settings.project_id:
            headers["OpenAI-Project"] = self.settings.project_id
        request = urllib.request.Request(url, headers=headers)
        try:
            with urllib.request.urlopen(request, timeout=self.settings.request_timeout_seconds) as response:
                return response.read()
        except urllib.error.HTTPError as exc:
            detail = exc.read().decode("utf-8", errors="replace")[:300]
            raise ApiError(f"download do ZIP falhou (HTTP {exc.code}): {detail}") from exc
        except (urllib.error.URLError, TimeoutError) as exc:
            raise ApiError(f"download do ZIP falhou: {exc}") from exc

    @staticmethod
    def _api_error(operation: str, exc: Exception) -> ApiError:
        message = str(exc).strip().replace("\n", " ")
        if len(message) > 500:
            message = message[:497] + "..."
        return ApiError(f"{operation} falhou: {message or exc.__class__.__name__}")
