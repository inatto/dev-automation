from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
import zipfile


TEXT_EXTENSIONS = {
    ".txt", ".md", ".rst", ".py", ".js", ".jsx", ".ts", ".tsx", ".mjs", ".cjs",
    ".json", ".jsonl", ".yaml", ".yml", ".toml", ".ini", ".cfg", ".conf", ".env",
    ".sh", ".bash", ".zsh", ".fish", ".sql", ".xml", ".html", ".htm", ".css", ".scss",
    ".java", ".kt", ".kts", ".go", ".rs", ".rb", ".php", ".cs", ".c", ".h", ".cpp",
    ".hpp", ".properties", ".gradle", ".csv", ".tsv", ".graphql", ".gql", ".dockerfile",
}
SKIP_DIRS = {".git", ".idea", ".venv", "venv", "node_modules", "__pycache__", ".pytest_cache", ".mypy_cache"}


@dataclass(frozen=True)
class LoadedContext:
    text: str
    files: tuple[str, ...]
    total_bytes: int
    truncated: bool


class ReplyContextFiles:
    """Navegação e leitura controlada de arquivos abaixo da pasta Code.

    Caminhos expostos para TUI/API são relativos ao root. O serviço nunca segue
    um caminho que resolva para fora do root.
    """

    def __init__(self, root: Path, *, max_files: int = 8, max_file_bytes: int = 120_000, max_total_bytes: int = 600_000):
        self.root = Path(root).expanduser().resolve()
        self.max_files = max(1, int(max_files))
        self.max_file_bytes = max(4_096, int(max_file_bytes))
        self.max_total_bytes = max(self.max_file_bytes, int(max_total_bytes))

    def _resolve(self, relative: str | Path = "") -> Path:
        raw = str(relative or "").strip()
        candidate = (self.root / raw).resolve() if raw not in {"", "."} else self.root
        try:
            candidate.relative_to(self.root)
        except ValueError as exc:
            raise ValueError("caminho fora da pasta Code não é permitido") from exc
        return candidate

    def relative(self, path: Path) -> str:
        return path.resolve().relative_to(self.root).as_posix()

    def browse(self, relative: str = "") -> dict:
        current = self._resolve(relative)
        if not current.exists() or not current.is_dir():
            raise FileNotFoundError(f"pasta não encontrada: {relative or '.'}")
        entries: list[dict] = []
        for child in current.iterdir():
            if child.name in SKIP_DIRS:
                continue
            try:
                resolved = child.resolve()
                resolved.relative_to(self.root)
            except (OSError, ValueError):
                continue
            try:
                is_dir = resolved.is_dir()
                is_file = resolved.is_file()
            except OSError:
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
                "path": self.relative(resolved),
                "type": "dir" if is_dir else "file",
                "size": size,
            })
        entries.sort(key=lambda item: (item["type"] != "dir", item["name"].lower()))
        parent = ""
        if current != self.root:
            parent = self.relative(current.parent)
        return {
            "root": str(self.root),
            "path": self.relative(current) if current != self.root else "",
            "parent": parent,
            "entries": entries,
            "max_files": self.max_files,
            "max_file_bytes": self.max_file_bytes,
            "max_total_bytes": self.max_total_bytes,
        }

    @staticmethod
    def _looks_text(path: Path, data: bytes) -> bool:
        if path.name.lower() == "dockerfile" or path.suffix.lower() in TEXT_EXTENSIONS:
            return True
        if b"\x00" in data[:4096]:
            return False
        if not data:
            return True
        sample = data[:4096]
        bad = sum(1 for byte in sample if byte < 9 or (13 < byte < 32))
        return bad / max(1, len(sample)) < 0.04

    def _read_regular(self, path: Path, budget: int) -> tuple[str, int, bool]:
        limit = min(self.max_file_bytes, max(0, budget))
        if limit <= 0:
            return "", 0, True
        with path.open("rb") as handle:
            data = handle.read(limit + 1)
        truncated = len(data) > limit
        data = data[:limit]
        if not self._looks_text(path, data):
            return f"[arquivo binário não incluído: {self.relative(path)}]", len(data), truncated
        return data.decode("utf-8", errors="replace"), len(data), truncated

    def _read_zip(self, path: Path, budget: int) -> tuple[str, int, bool]:
        used = 0
        truncated = False
        lines = [f"[ZIP {self.relative(path)}]"]
        with zipfile.ZipFile(path, "r") as archive:
            members = [item for item in archive.infolist() if not item.is_dir()]
            lines.append(f"Arquivos no ZIP: {len(members)}")
            for member in members[:300]:
                lines.append(f"- {member.filename} ({member.file_size} bytes)")
            if len(members) > 300:
                lines.append(f"- ... mais {len(members) - 300} arquivo(s)")
            lines.append("\nCONTEÚDO TEXTUAL DO ZIP")
            for member in members:
                if used >= min(self.max_file_bytes, budget):
                    truncated = True
                    break
                virtual = Path(member.filename)
                if virtual.name in SKIP_DIRS or any(part in SKIP_DIRS for part in virtual.parts):
                    continue
                if virtual.suffix.lower() not in TEXT_EXTENSIONS and virtual.name.lower() != "dockerfile":
                    continue
                take = min(60_000, self.max_file_bytes - used, budget - used)
                if take <= 0:
                    truncated = True
                    break
                with archive.open(member, "r") as handle:
                    data = handle.read(take + 1)
                member_truncated = len(data) > take
                data = data[:take]
                used += len(data)
                lines.append(f"\n--- {member.filename} ---")
                lines.append(data.decode("utf-8", errors="replace"))
                if member_truncated:
                    lines.append("[conteúdo truncado]")
                    truncated = True
        return "\n".join(lines), used, truncated

    def load(self, relative_paths: list[str] | tuple[str, ...] | None) -> LoadedContext:
        unique: list[str] = []
        for raw in relative_paths or []:
            value = str(raw or "").strip().replace("\\", "/")
            if value and value not in unique:
                unique.append(value)
        if len(unique) > self.max_files:
            raise ValueError(f"selecione no máximo {self.max_files} arquivos de contexto")

        parts: list[str] = []
        accepted: list[str] = []
        total = 0
        truncated = False
        for relative in unique:
            path = self._resolve(relative)
            if not path.exists() or not path.is_file():
                raise FileNotFoundError(f"arquivo de contexto não encontrado: {relative}")
            budget = self.max_total_bytes - total
            if budget <= 0:
                truncated = True
                break
            if path.suffix.lower() == ".zip":
                content, used, item_truncated = self._read_zip(path, budget)
            else:
                content, used, item_truncated = self._read_regular(path, budget)
            accepted.append(self.relative(path))
            parts.append(f"\n===== ARQUIVO: {self.relative(path)} =====\n{content}")
            total += used
            truncated = truncated or item_truncated
        if len(accepted) < len(unique):
            truncated = True
        return LoadedContext(
            text="\n".join(parts).strip(),
            files=tuple(accepted),
            total_bytes=total,
            truncated=truncated,
        )
