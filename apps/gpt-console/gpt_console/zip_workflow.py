from __future__ import annotations

import os
import re
import zipfile
from datetime import datetime
from pathlib import Path, PurePosixPath

from .config_store import Settings
from .errors import ZipWorkflowError
from .models import ActionGroup, ZipJobResult
from .openai_gateway import OpenAIGateway


class ZipWorkflow:
    def __init__(self, settings: Settings, gateway: OpenAIGateway):
        self.settings = settings
        self.gateway = gateway

    @property
    def code_root(self) -> Path:
        return Path(os.path.expandvars(os.path.expanduser(self.settings.code_root))).resolve()

    @property
    def downloads_root(self) -> Path:
        return Path(os.path.expandvars(os.path.expanduser(self.settings.downloads_root))).resolve()

    def source_for(self, group: ActionGroup) -> Path:
        return self.code_root / group.zip_name

    def inspect(self, group: ActionGroup) -> dict[str, object]:
        source = self.source_for(group)
        data: dict[str, object] = {"source": str(source), "exists": source.is_file(), "valid": False, "size": 0}
        if source.is_file():
            data["size"] = source.stat().st_size
            try:
                files, unpacked = self.validate_archive(source)
                data.update({"valid": True, "files": files, "unpacked_bytes": unpacked})
            except ZipWorkflowError as exc:
                data["error"] = str(exc)
        return data

    def run(self, group: ActionGroup, request_text: str) -> ZipJobResult:
        request_text = request_text.strip()
        if not request_text:
            raise ZipWorkflowError("a demanda do ZIP está vazia")
        source = self.source_for(group)
        if not source.is_file():
            raise ZipWorkflowError(f"ZIP de origem não encontrado: {source}")
        if source.stat().st_size > self.settings.max_zip_mb * 1024 * 1024:
            raise ZipWorkflowError(f"ZIP excede o limite configurado de {self.settings.max_zip_mb} MiB")
        self.validate_archive(source)
        content, summary, response_id, input_tokens, output_tokens = self.gateway.edit_zip(source, request_text)
        if len(content) > self.settings.max_zip_mb * 1024 * 1024:
            raise ZipWorkflowError(f"ZIP retornado excede o limite configurado de {self.settings.max_zip_mb} MiB")
        self.downloads_root.mkdir(parents=True, exist_ok=True)
        stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
        destination = self.downloads_root / f"{source.stem}(gpt-{stamp}).zip"
        sequence = 2
        while destination.exists():
            destination = self.downloads_root / f"{source.stem}(gpt-{stamp}-{sequence:02d}).zip"
            sequence += 1
        temp = destination.with_suffix(destination.suffix + ".part")
        try:
            temp.write_bytes(content)
            output_files, _ = self.validate_archive(temp)
            input_files, _ = self.validate_archive(source)
            if output_files < max(1, input_files // 2):
                raise ZipWorkflowError(
                    f"ZIP retornado parece incompleto: {output_files} entradas contra {input_files} no original"
                )
            self._validate_root_shape(source, temp)
            os.replace(temp, destination)
        except OSError as exc:
            raise ZipWorkflowError(f"não foi possível salvar {destination}: {exc}") from exc
        finally:
            try:
                temp.unlink()
            except OSError:
                pass
        return ZipJobResult(
            project_id=group.project_id,
            source=str(source),
            destination=str(destination),
            response_id=response_id,
            summary=summary.strip(),
            input_tokens=input_tokens,
            output_tokens=output_tokens,
        )

    @staticmethod
    def validate_archive(path: Path) -> tuple[int, int]:
        try:
            with zipfile.ZipFile(path) as archive:
                infos = archive.infolist()
                if not infos:
                    raise ZipWorkflowError(f"ZIP vazio: {path}")
                unpacked = 0
                for info in infos:
                    name = info.filename.replace("\\", "/")
                    pure = PurePosixPath(name)
                    if not name or pure.is_absolute() or ".." in pure.parts or re.match(r"^[A-Za-z]:", name):
                        raise ZipWorkflowError(f"caminho inseguro no ZIP: {info.filename!r}")
                    unpacked += max(0, info.file_size)
                if unpacked > 4 * 1024 * 1024 * 1024:
                    raise ZipWorkflowError("conteúdo descompactado excede 4 GiB")
                bad = archive.testzip()
                if bad:
                    raise ZipWorkflowError(f"CRC inválido no ZIP: {bad}")
                return len(infos), unpacked
        except zipfile.BadZipFile as exc:
            raise ZipWorkflowError(f"arquivo não é um ZIP íntegro: {path}") from exc
        except OSError as exc:
            raise ZipWorkflowError(f"não foi possível validar {path}: {exc}") from exc

    @staticmethod
    def _validate_root_shape(source: Path, output: Path) -> None:
        def shape(path: Path) -> tuple[set[str], str]:
            with zipfile.ZipFile(path) as archive:
                members = [
                    (info, PurePosixPath(info.filename.replace("\\", "/")).parts)
                    for info in archive.infolist()
                    if info.filename and PurePosixPath(info.filename.replace("\\", "/")).parts
                ]
                top = {parts[0] for _, parts in members}
                wrapper = ""
                if len(top) == 1 and all(len(parts) > 1 or info.is_dir() for info, parts in members):
                    wrapper = next(iter(top))
                return top, wrapper

        _, original_wrapper = shape(source)
        _, returned_wrapper = shape(output)
        if not original_wrapper and returned_wrapper:
            raise ZipWorkflowError("ZIP retornado adicionou uma pasta-raiz que não existia no original")
        if original_wrapper and returned_wrapper and original_wrapper != returned_wrapper:
            raise ZipWorkflowError("ZIP retornado trocou a pasta-raiz do projeto")
