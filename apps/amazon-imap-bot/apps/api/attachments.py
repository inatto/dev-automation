from __future__ import annotations

import hashlib
import json
import os
import shutil
import tempfile
from pathlib import Path


class AttachmentFiles:
    """Navegação HTML controlada em Downloads e staging persistente de anexos.

    O navegador nunca recebe acesso direto ao filesystem. A API expõe somente
    caminhos relativos abaixo de ``browse_root`` e copia os arquivos escolhidos
    para ``staging_root`` antes de criar/liberar o e-mail.
    """

    def __init__(
        self,
        browse_root: Path,
        staging_root: Path,
        *,
        max_files: int = 8,
        max_file_bytes: int = 7_000_000,
        max_total_bytes: int = 7_000_000,
    ):
        self.browse_root = Path(browse_root).expanduser().resolve()
        self.staging_root = Path(staging_root).expanduser().resolve()
        self.max_files = max(1, int(max_files))
        self.max_file_bytes = max(1, int(max_file_bytes))
        self.max_total_bytes = max(self.max_file_bytes, int(max_total_bytes))
        self.staging_root.mkdir(parents=True, exist_ok=True)

    def _resolve_source(self, relative: str | Path = "") -> Path:
        raw = str(relative or "").strip().replace("\\", "/")
        candidate = (self.browse_root / raw).resolve() if raw not in {"", "."} else self.browse_root
        try:
            candidate.relative_to(self.browse_root)
        except ValueError as exc:
            raise ValueError("caminho fora da pasta Downloads não é permitido") from exc
        return candidate

    def _relative(self, path: Path) -> str:
        return path.resolve().relative_to(self.browse_root).as_posix()

    def browse(self, relative: str = "") -> dict:
        current = self._resolve_source(relative)
        if not current.exists() or not current.is_dir():
            raise FileNotFoundError(f"pasta não encontrada: {relative or '.'}")
        entries: list[dict] = []
        try:
            children = list(current.iterdir())
        except PermissionError as exc:
            raise PermissionError(f"sem permissão para abrir: {relative or '.'}") from exc
        for child in children:
            try:
                resolved = child.resolve()
                resolved.relative_to(self.browse_root)
                is_dir = resolved.is_dir()
                is_file = resolved.is_file()
            except (OSError, ValueError):
                continue
            if not (is_dir or is_file):
                continue
            size = 0
            if is_file:
                try:
                    size = int(resolved.stat().st_size)
                except OSError:
                    size = 0
            entries.append({
                "name": child.name,
                "path": self._relative(resolved),
                "type": "dir" if is_dir else "file",
                "size": size,
            })
        entries.sort(key=lambda item: (item["type"] != "dir", item["name"].lower()))
        parent = ""
        if current != self.browse_root:
            parent = self._relative(current.parent)
        return {
            "root_label": "Downloads",
            "path": self._relative(current) if current != self.browse_root else "",
            "parent": parent,
            "entries": entries,
            "max_files": self.max_files,
            "max_file_bytes": self.max_file_bytes,
            "max_total_bytes": self.max_total_bytes,
        }

    def validate(self, relative_paths: list[str] | tuple[str, ...] | None) -> list[dict]:
        unique: list[str] = []
        for raw in relative_paths or []:
            value = str(raw or "").strip().replace("\\", "/")
            if value and value not in unique:
                unique.append(value)
        if len(unique) > self.max_files:
            raise ValueError(f"selecione no máximo {self.max_files} anexos")

        files: list[dict] = []
        total = 0
        for relative in unique:
            path = self._resolve_source(relative)
            if not path.exists() or not path.is_file():
                raise FileNotFoundError(f"anexo não encontrado: {relative}")
            size = int(path.stat().st_size)
            if size > self.max_file_bytes:
                raise ValueError(f"anexo excede o limite permitido: {path.name}")
            total += size
            if total > self.max_total_bytes:
                raise ValueError("o total dos anexos excede o limite permitido")
            files.append({"source": path, "relative": self._relative(path), "name": path.name, "size": size})
        return files

    @staticmethod
    def _key(message_id: str) -> str:
        return hashlib.sha256(str(message_id or "").encode("utf-8")).hexdigest()

    def _message_dir(self, message_id: str) -> Path:
        return self.staging_root / self._key(message_id)

    def stage(self, message_id: str, relative_paths: list[str] | tuple[str, ...] | None) -> list[dict]:
        sources = self.validate(relative_paths)
        target = self._message_dir(message_id)
        if not sources:
            self.remove(message_id)
            return []

        self.staging_root.mkdir(parents=True, exist_ok=True)
        temp = Path(tempfile.mkdtemp(prefix="mail-attachments-", dir=str(self.staging_root)))
        manifest: list[dict] = []
        try:
            for index, item in enumerate(sources, start=1):
                safe_name = Path(str(item["name"])).name.replace("\x00", "") or f"anexo-{index}"
                stored_name = f"{index:02d}-{safe_name}"
                destination = temp / stored_name
                shutil.copy2(item["source"], destination)
                manifest.append({
                    "name": safe_name,
                    "stored_name": stored_name,
                    "size": int(destination.stat().st_size),
                    "source_relative": item["relative"],
                })
            (temp / "manifest.json").write_text(
                json.dumps(manifest, ensure_ascii=False, indent=2), encoding="utf-8"
            )
            if target.exists():
                shutil.rmtree(target)
            os.replace(temp, target)
            return self.list(message_id)
        except Exception:
            shutil.rmtree(temp, ignore_errors=True)
            raise

    def list(self, message_id: str) -> list[dict]:
        target = self._message_dir(message_id)
        manifest_path = target / "manifest.json"
        if not manifest_path.is_file():
            return []
        try:
            raw = json.loads(manifest_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            return []
        result: list[dict] = []
        for item in raw if isinstance(raw, list) else []:
            stored_name = Path(str(item.get("stored_name") or "")).name
            path = target / stored_name
            if not stored_name or not path.is_file():
                continue
            result.append({
                "name": str(item.get("name") or stored_name),
                "size": int(item.get("size") or path.stat().st_size),
            })
        return result

    def preview(self, message_id: str, attachment_index: int) -> dict:
        items = self.paths(message_id)
        index = int(attachment_index)
        if index < 0 or index >= len(items):
            raise FileNotFoundError("anexo não encontrado")
        return items[index]

    def paths(self, message_id: str) -> list[dict]:
        target = self._message_dir(message_id)
        manifest_path = target / "manifest.json"
        if not manifest_path.is_file():
            return []
        try:
            raw = json.loads(manifest_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            return []
        result: list[dict] = []
        for item in raw if isinstance(raw, list) else []:
            stored_name = Path(str(item.get("stored_name") or "")).name
            path = (target / stored_name).resolve()
            try:
                path.relative_to(target.resolve())
            except ValueError:
                continue
            if not path.is_file():
                continue
            result.append({"path": path, "name": str(item.get("name") or stored_name)})
        return result

    def remove(self, message_id: str) -> None:
        shutil.rmtree(self._message_dir(message_id), ignore_errors=True)
