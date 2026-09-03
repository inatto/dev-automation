from __future__ import annotations

import json
import shutil
import threading
import time
import urllib.request
import zipfile
from datetime import datetime
from pathlib import Path

from config import Settings
from function_map import REASONING_LEVELS
from store import Store


class ProjectZipRunner:
    """Seleciona semanticamente um ZIP de ~/Code e executa uma demanda sobre o projeto em uma segunda chamada independente."""

    def __init__(self, settings: Settings, store: Store, on_event=lambda _: None, client=None):
        self.settings = settings
        self.store = store
        self.on_event = on_event
        self._lock = threading.Lock()
        self._client_override = client

    def _event(self, text: str, level: str = "INFO") -> None:
        try:
            self.store.add_event("API", level, text)
        except Exception:
            pass
        self.on_event(text)

    def _client(self):
        if self._client_override is not None:
            return self._client_override
        if not self.settings.openai_api_key:
            raise RuntimeError("OPENAI_API_KEY ausente")
        from openai import OpenAI
        return OpenAI(
            api_key=self.settings.openai_api_key,
            base_url=self.settings.openai_base_url,
            timeout=self.settings.openai_timeout_seconds,
        )

    @staticmethod
    def normalize_reasoning_effort(value: str) -> str:
        effort = str(value or "").strip().lower()
        if effort not in set(REASONING_LEVELS.values()):
            raise ValueError(f"nível de raciocínio inválido: {value}")
        return effort

    def discover_zip_candidates(self) -> list[Path]:
        root = self.settings.project_zip_search_root.expanduser().resolve()
        if not root.is_dir():
            raise RuntimeError(f"diretório de projetos não encontrado: {root}")
        candidates: list[Path] = []
        for path in root.glob("*.zip"):
            try:
                resolved = path.resolve()
            except OSError:
                continue
            if not resolved.is_file():
                continue
            try:
                resolved.relative_to(root)
            except ValueError:
                continue
            candidates.append(resolved)
        candidates.sort(key=lambda p: str(p).lower())
        return candidates

    @staticmethod
    def _output_items(response) -> list:
        output = getattr(response, "output", None)
        if isinstance(output, list):
            return output
        if output is None:
            return []
        try:
            return list(output)
        except TypeError:
            return []

    @staticmethod
    def _plain(value):
        if value is None or isinstance(value, (str, int, float, bool)):
            return value
        if isinstance(value, dict):
            return {str(k): ProjectZipRunner._plain(v) for k, v in value.items()}
        if isinstance(value, (list, tuple)):
            return [ProjectZipRunner._plain(v) for v in value]
        if hasattr(value, "model_dump"):
            try:
                return ProjectZipRunner._plain(value.model_dump())
            except Exception:
                pass
        if hasattr(value, "__dict__"):
            return ProjectZipRunner._plain(vars(value))
        return str(value)

    @classmethod
    def _container_files(cls, response) -> list[dict]:
        payload = cls._plain(response)
        found: list[dict] = []

        def walk(node):
            if isinstance(node, dict):
                if node.get("type") == "container_file_citation" and node.get("container_id") and node.get("file_id"):
                    found.append({
                        "container_id": str(node.get("container_id")),
                        "file_id": str(node.get("file_id")),
                        "filename": str(node.get("filename") or node.get("file_id")),
                    })
                for value in node.values():
                    walk(value)
            elif isinstance(node, list):
                for value in node:
                    walk(value)

        walk(payload)
        unique: list[dict] = []
        seen = set()
        for item in found:
            key = (item["container_id"], item["file_id"])
            if key not in seen:
                seen.add(key)
                unique.append(item)
        return unique

    def _download_container_file(self, container_id: str, file_id: str, target: Path) -> None:
        base = self.settings.openai_base_url.rstrip("/")
        url = f"{base}/containers/{container_id}/files/{file_id}/content"
        req = urllib.request.Request(url, headers={"Authorization": f"Bearer {self.settings.openai_api_key}"})
        with urllib.request.urlopen(req, timeout=self.settings.openai_timeout_seconds) as response:
            data = response.read()
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)

    @staticmethod
    def _candidate_listing(root: Path, candidates: list[Path]) -> str:
        # Esta chamada envia SOMENTE nomes/caminhos relativos dos ZIPs. Nenhum ZIP é anexado aqui.
        return "\n".join(
            f"{idx}. {path.relative_to(root).as_posix()}"
            for idx, path in enumerate(candidates, 1)
        )

    @staticmethod
    def _zip_file_count(path: Path) -> int:
        """Conta somente arquivos reais dentro do ZIP; diretórios não entram na métrica."""
        with zipfile.ZipFile(path, "r") as zf:
            return sum(1 for info in zf.infolist() if not info.is_dir())

    def select_project_zip(self, request_text: str) -> tuple[Path, int]:
        root = self.settings.project_zip_search_root.expanduser().resolve()
        candidates = self.discover_zip_candidates()
        if not candidates:
            raise RuntimeError(f"nenhum arquivo .zip encontrado em {root}")

        listing = self._candidate_listing(root, candidates)
        prompt = (
                "Você deve apenas identificar qual arquivo ZIP corresponde ao projeto pedido pelo usuário. "
                "Não execute a alteração e não invente caminhos. Escolha EXATAMENTE um caminho relativo da lista fornecida. "
                "Se nomes forem parecidos, use o contexto do pedido para selecionar o mais provável. "
                "IMPORTANTE: esta chamada recebeu somente uma lista textual de nomes/caminhos de ZIP; nenhum arquivo ZIP foi anexado.\n\n"
                "PEDIDO ORIGINAL:\n---\n"
                f"{request_text.strip()}\n"
                "---\n\n"
                f"RAIZ LOCAL: {root}\n"
                "ZIPS DISPONÍVEIS (somente nomes/caminhos; nenhum arquivo anexado):\n"
                f"{listing}"
            )
        prompt_bytes = len(prompt.encode("utf-8"))
        run_id = self.store.add_api_run(
            kind="project-zip-select",
            status="aguardando-resposta",
            model=self.settings.openai_model,
            reasoning_effort="low",
            input_path=str(root),
            output_path="",
            request_summary=(request_text or "")[:1800],
            request_payload=prompt,
            request_bytes=prompt_bytes,
            input_file_bytes=0,
            input_file_count=0,
            listed_item_count=len(candidates),
        )
        started = time.monotonic()
        self._event(
            f"PROJECT ZIP SELECT #{run_id}: enviando somente {len(candidates)} nome(s) de ZIP "
            f"({prompt_bytes} bytes de texto), sem anexos"
        )
        try:
            # Não há client.files.create nesta etapa: é apenas texto + function calling.
            client = self._client()
            response = client.responses.create(
                model=self.settings.openai_model,
                reasoning={"effort": "low"},
                input=prompt,
                tools=[{
                    "type": "function",
                    "name": "select_project_zip",
                    "description": "Seleciona exatamente um ZIP da lista fornecida para atender ao pedido original.",
                    "parameters": {
                        "type": "object",
                        "properties": {
                            "selected_zip": {
                                "type": "string",
                                "description": "Caminho relativo exato de um dos ZIPs fornecidos na lista.",
                            },
                            "reason": {
                                "type": "string",
                                "description": "Justificativa curta para a escolha.",
                            },
                        },
                        "required": ["selected_zip", "reason"],
                        "additionalProperties": False,
                    },
                    "strict": True,
                }],
                tool_choice="required",
                parallel_tool_calls=False,
            )
            calls = [item for item in self._output_items(response) if getattr(item, "type", "") == "function_call"]
            if len(calls) != 1 or str(getattr(calls[0], "name", "")) != "select_project_zip":
                raise RuntimeError("a API não retornou uma única seleção de ZIP válida")
            try:
                args = json.loads(str(getattr(calls[0], "arguments", "{}") or "{}"))
            except json.JSONDecodeError as exc:
                raise RuntimeError("a API retornou argumentos inválidos ao selecionar o ZIP") from exc
            selected_rel = str(args.get("selected_zip") or "").strip().replace("\\", "/")
            reason = str(args.get("reason") or "").strip()
            by_rel = {path.relative_to(root).as_posix(): path for path in candidates}
            selected = by_rel.get(selected_rel)
            if selected is None:
                raise RuntimeError(f"a API selecionou um ZIP que não existe na lista: {selected_rel or '(vazio)'}")
            if not zipfile.is_zipfile(selected):
                raise RuntimeError(f"o arquivo selecionado não é um ZIP válido: {selected}")
            elapsed_ms = int((time.monotonic() - started) * 1000)
            response_id = str(getattr(response, "id", "") or "")
            response_summary = f"ZIP={selected_rel} | {reason}"[:1800]
            self.store.update_api_run(
                run_id,
                status="concluido",
                output_path=str(selected),
                response_id=response_id,
                response_summary=response_summary,
                response_bytes=len(response_summary.encode("utf-8")),
                elapsed_ms=elapsed_ms,
                finished=True,
            )
            self._event(f"PROJECT ZIP SELECT #{run_id}: escolhido {selected_rel} em {elapsed_ms/1000:.2f}s")
            return selected, run_id
        except Exception as exc:
            elapsed_ms = int((time.monotonic() - started) * 1000)
            self.store.update_api_run(run_id, status="erro", error=str(exc), elapsed_ms=elapsed_ms, finished=True)
            self._event(f"PROJECT ZIP SELECT #{run_id}: ERRO {exc}", "ERROR")
            raise

    @staticmethod
    def _preserve_existing_zip_metadata(original: Path, returned_zip: Path, target: Path) -> None:
        """Mantém metadados ZIP dos caminhos que já existiam no arquivo original."""
        target.parent.mkdir(parents=True, exist_ok=True)
        temp = target.with_suffix(target.suffix + ".tmp")
        if temp.exists():
            temp.unlink()
        with zipfile.ZipFile(original, "r") as src, zipfile.ZipFile(returned_zip, "r") as ret:
            original_info = {info.filename: info for info in src.infolist()}
            with zipfile.ZipFile(temp, "w") as out:
                out.comment = ret.comment
                for info in ret.infolist():
                    data = ret.read(info.filename)
                    base = original_info.get(info.filename)
                    if base is None:
                        out.writestr(info, data)
                        continue
                    preserved = zipfile.ZipInfo(filename=info.filename, date_time=base.date_time)
                    preserved.compress_type = info.compress_type
                    preserved.comment = base.comment
                    preserved.extra = base.extra
                    preserved.create_system = base.create_system
                    preserved.create_version = base.create_version
                    preserved.extract_version = base.extract_version
                    preserved.flag_bits = info.flag_bits
                    preserved.internal_attr = base.internal_attr
                    preserved.external_attr = base.external_attr
                    preserved.volume = base.volume
                    out.writestr(preserved, data)
        temp.replace(target)

    def process_project_zip(self, selected: Path, request_text: str, reasoning_effort: str, operation: str, source: str) -> int:
        effort = self.normalize_reasoning_effort(reasoning_effort)
        operation = str(operation or "modify").strip().lower()
        if operation not in {"query", "modify"}:
            raise ValueError(f"operação de projeto inválida: {operation}")
        requires_zip_output = operation == "modify"
        selected = selected.expanduser().resolve()
        root = self.settings.project_zip_search_root.expanduser().resolve()
        try:
            selected.relative_to(root)
        except ValueError as exc:
            raise RuntimeError(f"ZIP fora da raiz autorizada: {selected}") from exc
        if not selected.is_file() or not zipfile.is_zipfile(selected):
            raise RuntimeError(f"ZIP selecionado inválido: {selected}")

        input_zip_bytes = selected.stat().st_size
        input_zip_files = self._zip_file_count(selected)
        task_rule = (
            "A demanda é de MODIFICAÇÃO. Inspecione o projeto antes de alterar e implemente somente o pedido original, "
            "sem melhorias paralelas nem mudanças não solicitadas. Ao final é OBRIGATÓRIO devolver um único ZIP completo alterado."
            if requires_zip_output
            else
            "A demanda é de CONSULTA/ANÁLISE. Use o ZIP inteiro como contexto para responder com precisão. NÃO altere o projeto "
            "e NÃO gere ZIP de retorno, a menos que o próprio pedido peça explicitamente a criação de um arquivo."
        )
        prompt = (
            "Trabalhe exclusivamente no arquivo ZIP anexado usando Code Interpreter. "
            "Esta é uma chamada independente: todo o contexto necessário está nesta mensagem. "
            f"{task_rule} "
            "Preserve a hierarquia do ZIP quando houver modificação. "
            "\n\nREGRA DE EFICIÊNCIA OBRIGATÓRIA PARA O ZIP:\n"
            "- Há exatamente UM ZIP de entrada anexado.\n"
            "- NÃO extraia/descompacte o projeto inteiro para uma árvore de arquivos no container.\n"
            "- NÃO copie, clone ou duplique a árvore do projeto.\n"
            "- Use Python zipfile para listar TODAS as entradas do ZIP e ler diretamente do arquivo compactado apenas os conteúdos necessários.\n"
            "- Pesquise nomes/caminhos e, quando necessário, leia arquivos candidatos diretamente via zipfile sem extração global.\n"
            "- Se a demanda for de modificação, produza diretamente UM NOVO ZIP: copie cada entrada do ZIP original para o ZIP de saída e substitua "
            "somente as entradas realmente alteradas. Não crie uma segunda árvore completa em disco.\n"
            "- Se a demanda for de consulta/análise, apenas leia o necessário diretamente do ZIP e responda em texto; não reconstrua o ZIP.\n"
            "- Quando houver ZIP de saída, ele deve conter o projeto COMPLETO, inclusive tudo que não foi alterado.\n"
            "- Preserve nomes, hierarquia e metadados na medida do possível.\n"
            "Ao terminar, valide o que for possível sem deploy. Se for modificação, explique brevemente o que mudou e cite/anexe "
            "explicitamente o ÚNICO ZIP final para download. Se for consulta, responda de forma objetiva e fundamentada no conteúdo do projeto.\n\n"
            f"OPERAÇÃO: {operation.upper()}\n"
            f"ZIP SELECIONADO LOCALMENTE: {selected.name}\n"
            f"ZIP DE ENTRADA: {input_zip_bytes} bytes; {input_zip_files} arquivos internos (diretórios não contam).\n"
            "PEDIDO ORIGINAL DO E-MAIL:\n---\n"
            f"{request_text.strip()}\n"
            "---"
        )
        prompt_bytes = len(prompt.encode("utf-8"))
        run_id = self.store.add_api_run(
            kind="project-zip-query" if not requires_zip_output else "project-zip-edit",
            status="preparando",
            model=self.settings.openai_model,
            reasoning_effort=effort,
            input_path=str(selected),
            output_path="",
            request_summary=f"origem={source} | {request_text[:1700]}",
            request_payload=prompt,
            request_bytes=prompt_bytes,
            input_file_bytes=input_zip_bytes,
            input_file_count=input_zip_files,
            listed_item_count=1,
        )
        started = time.monotonic()
        downloaded_temp: Path | None = None
        self._event(
            f"PROJECT ZIP {'EDIT' if requires_zip_output else 'QUERY'} #{run_id}: preparando {selected.name} effort={effort} | "
            f"1 ZIP, {input_zip_bytes} bytes, {input_zip_files} arquivos internos"
        )
        try:
            client = self._client()
            self.store.update_api_run(run_id, status="enviando")
            with selected.open("rb") as fh:
                uploaded = client.files.create(file=fh, purpose="user_data")
            self._event(f"PROJECT ZIP {'EDIT' if requires_zip_output else 'QUERY'} #{run_id}: upload concluído file_id={uploaded.id}")
            self.store.update_api_run(run_id, status="aguardando-resposta")

            response = client.responses.create(
                model=self.settings.openai_model,
                reasoning={"effort": effort},
                tools=[{
                    "type": "code_interpreter",
                    "container": {"type": "auto", "file_ids": [uploaded.id]},
                }],
                tool_choice="required",
                input=prompt,
            )
            response_id = str(getattr(response, "id", "") or "")
            text = str(getattr(response, "output_text", "") or "").strip()
            self.store.update_api_run(
                run_id,
                status="baixando",
                response_id=response_id,
                response_summary=text[:1800],
                response_bytes=len(text.encode("utf-8")),
            )
            self._event(f"PROJECT ZIP {'EDIT' if requires_zip_output else 'QUERY'} #{run_id}: resposta recebida response_id={response_id or '-'}")

            files = self._container_files(response)
            zip_files = [item for item in files if item["filename"].lower().endswith(".zip")]
            if not requires_zip_output:
                elapsed_ms = int((time.monotonic() - started) * 1000)
                self.store.update_api_run(
                    run_id, status="concluido", output_path="", output_file_bytes=0, output_file_count=0,
                    elapsed_ms=elapsed_ms, finished=True,
                )
                self._event(f"PROJECT ZIP QUERY #{run_id}: CONCLUÍDO em {elapsed_ms/1000:.2f}s | resposta textual")
                return run_id
            if not zip_files:
                raise RuntimeError("a API respondeu a uma solicitação de modificação, mas não retornou um arquivo ZIP de container")
            chosen = zip_files[-1]
            output_dir = self.settings.openai_output_dir.expanduser()
            output_dir.mkdir(parents=True, exist_ok=True)
            target = output_dir / selected.name
            if target.exists():
                stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
                target = output_dir / f"{selected.stem}-{stamp}{selected.suffix}"
            downloaded_temp = output_dir / f".{target.name}.download-{run_id}.tmp.zip"
            self._download_container_file(chosen["container_id"], chosen["file_id"], downloaded_temp)
            if not zipfile.is_zipfile(downloaded_temp):
                raise RuntimeError("o arquivo retornado pela API não é um ZIP válido")
            self._preserve_existing_zip_metadata(selected, downloaded_temp, target)
            if not zipfile.is_zipfile(target):
                raise RuntimeError(f"falha ao produzir ZIP final válido: {target}")
            if downloaded_temp.exists():
                downloaded_temp.unlink()
                downloaded_temp = None

            output_zip_bytes = target.stat().st_size
            output_zip_files = self._zip_file_count(target)
            elapsed_ms = int((time.monotonic() - started) * 1000)
            self.store.update_api_run(
                run_id,
                status="concluido",
                output_path=str(target),
                output_file_bytes=output_zip_bytes,
                output_file_count=output_zip_files,
                elapsed_ms=elapsed_ms,
                finished=True,
            )
            self._event(
                f"PROJECT ZIP EDIT #{run_id}: CONCLUÍDO em {elapsed_ms/1000:.2f}s -> {target} | "
                f"{output_zip_bytes} bytes, {output_zip_files} arquivos internos"
            )
            return run_id
        except Exception as exc:
            if downloaded_temp is not None and downloaded_temp.exists():
                try:
                    downloaded_temp.unlink()
                except OSError:
                    pass
            elapsed_ms = int((time.monotonic() - started) * 1000)
            self.store.update_api_run(run_id, status="erro", error=str(exc), elapsed_ms=elapsed_ms, finished=True)
            self._event(f"PROJECT ZIP {'EDIT' if requires_zip_output else 'QUERY'} #{run_id}: ERRO {exc}", "ERROR")
            raise

    def run_project_request(self, *, request_text: str, reasoning_effort: str, operation: str = "modify", source: str = "email") -> int:
        if not self._lock.acquire(blocking=False):
            raise RuntimeError("já existe uma demanda de projeto ZIP em andamento")
        try:
            request = str(request_text or "").strip()
            if not request:
                raise ValueError("pedido sobre o projeto vazio")
            selected, _selection_run_id = self.select_project_zip(request)
            return self.process_project_zip(selected, request, reasoning_effort, operation, source)
        finally:
            self._lock.release()

    def run_project_edit(self, *, request_text: str, reasoning_effort: str, source: str = "email") -> int:
        """Compatibilidade com chamadas antigas: equivale a operation=modify."""
        return self.run_project_request(
            request_text=request_text, reasoning_effort=reasoning_effort, operation="modify", source=source
        )
