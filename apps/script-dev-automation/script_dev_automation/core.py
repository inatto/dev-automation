from __future__ import annotations

import hashlib
import json
import os
import re
import shutil
import subprocess
import tempfile
from datetime import datetime
from dataclasses import dataclass, field
from pathlib import Path
from typing import Iterable


DEFAULT_CODE_ROOT = Path("/home/daniel/Code")
DEFAULT_KEY_FILE = Path("/home/daniel/static/reverse-crypt.key")
IGNORED_DIRS = {
    ".git", ".idea", ".astro", ".cache", ".pytest_cache", ".venv",
    "__pycache__", "build", "dist", "node_modules", "target", "vendor", "venv",
}


@dataclass
class ConfigAudit:
    project: str
    path: Path
    repo: Path | None
    status: str
    detail: str
    files: int = 0
    tracked: int = 0
    uncovered: int = 0

    def as_dict(self) -> dict[str, object]:
        return {
            "project": self.project, "path": str(self.path),
            "repo": str(self.repo) if self.repo else None, "status": self.status,
            "detail": self.detail, "files": self.files, "tracked": self.tracked,
            "uncovered": self.uncovered,
        }


@dataclass
class ProjectAudit:
    name: str
    path: Path
    status: str
    detail: str
    configs: list[ConfigAudit] = field(default_factory=list)

    def as_dict(self) -> dict[str, object]:
        return {
            "name": self.name, "path": str(self.path), "status": self.status,
            "detail": self.detail, "configs": [item.as_dict() for item in self.configs],
        }


@dataclass
class AuditReport:
    projects_file: Path
    code_root: Path
    key_file: Path
    projects: list[ProjectAudit]

    @property
    def configs(self) -> list[ConfigAudit]:
        return [config for project in self.projects for config in project.configs]

    def counts(self) -> dict[str, int]:
        result = {"projects": len(self.projects), "configs": len(self.configs)}
        for status in ("protected", "pending", "locked", "wrong_key", "no_git", "error"):
            result[status] = sum(item.status == status for item in self.configs)
        result["missing_projects"] = sum(item.status == "missing" for item in self.projects)
        return result

    def as_dict(self) -> dict[str, object]:
        return {
            "projects_file": str(self.projects_file), "code_root": str(self.code_root),
            "key_file": str(self.key_file), "counts": self.counts(),
            "projects": [item.as_dict() for item in self.projects],
        }


def project_root() -> Path:
    return Path(__file__).resolve().parents[3]


def resolve_projects_file(root: Path) -> Path:
    explicit = os.environ.get("PROJECTS_FILE") or os.environ.get("DEV_MANAGER_PROJECTS_FILE")
    if explicit:
        return Path(explicit).expanduser()
    machine_id = os.environ.get("DEV_MACHINE_ID", "").strip().lower()
    if not machine_id:
        try:
            machine_id = Path("/etc/machine-id").read_text(encoding="utf-8").strip().lower()
        except OSError:
            machine_id = ""
    if len(machine_id) == 32 and all(char in "0123456789abcdef" for char in machine_id):
        machine_file = root / "config" / "projects" / f"{machine_id}.projects"
        if machine_file.is_file():
            return machine_file
    default = root / "config" / "projects" / "default.projects"
    return default if default.is_file() else root / "config" / "auto-code-manager.projects"


def load_projects(path: Path) -> list[str]:
    if not path.is_file():
        raise FileNotFoundError(f"arquivo de projetos não encontrado: {path}")
    projects: list[str] = []
    seen: set[str] = set()
    for raw in path.read_text(encoding="utf-8").splitlines():
        value = raw.split("#", 1)[0].strip().strip("/")
        if not value or value in seen:
            continue
        if value.startswith("../") or value == ".." or Path(value).is_absolute():
            continue
        seen.add(value)
        projects.append(value)
    return projects


def _run(args: list[str], cwd: Path | None = None) -> subprocess.CompletedProcess[bytes]:
    try:
        return subprocess.run(args, cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
    except FileNotFoundError:
        return subprocess.CompletedProcess(args, 127, b"", f"comando ausente: {args[0]}".encode())


def _real(path: Path) -> Path:
    try:
        return path.resolve()
    except OSError:
        return path.absolute()


def find_config_dirs(root: Path, nested_projects: Iterable[Path] = ()) -> list[Path]:
    root_real = _real(root)
    nested = {_real(item) for item in nested_projects if _real(item) != root_real}
    found: list[Path] = []
    for current, dirs, _files in os.walk(root, followlinks=False):
        current_path = _real(Path(current))
        if current_path in nested:
            dirs[:] = []
            continue
        dirs[:] = [name for name in dirs if name not in IGNORED_DIRS]
        if ".config" in dirs:
            found.append(Path(current) / ".config")
            dirs.remove(".config")
    return sorted(found)


def _repo_for(path: Path) -> Path | None:
    result = _run(["git", "-C", str(path), "rev-parse", "--show-toplevel"])
    if result.returncode:
        return None
    value = result.stdout.decode("utf-8", "replace").strip()
    return _real(Path(value)) if value else None


def _key_state(repo: Path, key_file: Path) -> str:
    handle = tempfile.NamedTemporaryFile(prefix="script-dev-automation-key-", delete=False)
    handle.close()
    output = Path(handle.name)
    try:
        result = _run(["git", "-C", str(repo), "crypt", "export-key", str(output)])
        if result.returncode:
            return "unavailable"
        expected = hashlib.sha256(key_file.read_bytes()).digest()
        actual = hashlib.sha256(output.read_bytes()).digest()
        return "match" if expected == actual else "different"
    except OSError:
        return "unavailable"
    finally:
        output.unlink(missing_ok=True)


def _config_files(path: Path) -> list[Path]:
    files: list[Path] = []
    for current, dirs, names in os.walk(path, followlinks=False):
        dirs[:] = [name for name in dirs if name not in IGNORED_DIRS]
        for name in names:
            item = Path(current) / name
            if item.is_file() or item.is_symlink():
                files.append(item)
    return sorted(files)


def _relative(repo: Path, path: Path) -> str:
    return path.relative_to(repo).as_posix()


def _covered_paths(repo: Path, paths: list[str]) -> set[str]:
    covered: set[str] = set()
    for start in range(0, len(paths), 200):
        batch = paths[start : start + 200]
        result = _run(["git", "-C", str(repo), "check-attr", "-z", "filter", "diff", "--", *batch])
        if result.returncode:
            continue
        values = result.stdout.split(b"\0")
        attrs: dict[str, dict[str, str]] = {}
        for index in range(0, len(values) - 2, 3):
            name = values[index].decode("utf-8", "surrogateescape")
            attr = values[index + 1].decode("utf-8", "replace")
            value = values[index + 2].decode("utf-8", "replace")
            attrs.setdefault(name, {})[attr] = value
        for name in batch:
            values_for_path = attrs.get(name, {})
            if values_for_path.get("filter") == "git-crypt" and values_for_path.get("diff") == "git-crypt":
                covered.add(name)
    return covered


def _gitcrypt_tracked_paths(repo: Path) -> list[str]:
    listed = _run(["git", "-C", str(repo), "ls-files", "-z"])
    if listed.returncode:
        raise RuntimeError(f"não foi possível listar arquivos rastreados em {repo}")
    paths = [item.decode("utf-8", "surrogateescape") for item in listed.stdout.split(b"\0") if item]
    encrypted: list[str] = []
    for start in range(0, len(paths), 200):
        batch = paths[start : start + 200]
        result = _run(["git", "-C", str(repo), "check-attr", "-z", "filter", "--", *batch])
        if result.returncode:
            continue
        values = result.stdout.split(b"\0")
        for index in range(0, len(values) - 2, 3):
            path = values[index].decode("utf-8", "surrogateescape")
            value = values[index + 2].decode("utf-8", "replace")
            if value == "git-crypt":
                encrypted.append(path)
    return sorted(set(encrypted))


def _attribute_files(repo: Path, git_dir: Path) -> list[Path]:
    found: list[Path] = []
    for current, dirs, names in os.walk(repo, followlinks=False):
        current_path = _real(Path(current))
        if current_path == git_dir:
            dirs[:] = []
            continue
        dirs[:] = [name for name in dirs if name not in IGNORED_DIRS]
        if ".gitattributes" in names:
            found.append(Path(current) / ".gitattributes")
    info_attributes = git_dir / "info" / "attributes"
    if info_attributes.is_file():
        found.append(info_attributes)
    return sorted(set(found))


def _without_default_gitcrypt_rules(content: bytes) -> bytes:
    lines = content.splitlines(keepends=True)
    return b"".join(
        line for line in lines
        if not re.search(rb"(?:^|\s)(?:filter|diff)=git-crypt(?:\s|$)", line)
    )


def _git_dir(repo: Path) -> Path:
    result = _run(["git", "-C", str(repo), "rev-parse", "--absolute-git-dir"])
    if result.returncode:
        raise RuntimeError(f"não foi possível localizar a pasta interna Git de {repo}")
    return _real(Path(result.stdout.decode("utf-8", "replace").strip()))


def audit_config(project: str, path: Path, key_file: Path, gitcrypt_available: bool) -> ConfigAudit:
    repo = _repo_for(path)
    if repo is None:
        return ConfigAudit(project, path, None, "no_git", "a pasta não pertence a um repositório Git")
    files = _config_files(path)
    rel_dir = _relative(repo, path)
    probes = [_relative(repo, item) for item in files]
    # O probe profundo garante que a regra também protege arquivos futuros em
    # subpastas; uma regra rasa como .config/* não é considerada suficiente.
    probes.append(f"{rel_dir}/.gitcrypt-probe/deep")
    covered = _covered_paths(repo, probes)
    uncovered = len(probes) - len(covered)
    tracked_result = _run(["git", "-C", str(repo), "ls-files", "-z", "--", rel_dir])
    tracked = len([item for item in tracked_result.stdout.split(b"\0") if item]) if not tracked_result.returncode else 0
    if not gitcrypt_available:
        return ConfigAudit(project, path, repo, "error", "git-crypt não está instalado", len(files), tracked, uncovered)
    if not key_file.is_file():
        return ConfigAudit(project, path, repo, "error", f"chave ausente: {key_file}", len(files), tracked, uncovered)
    key_state = _key_state(repo, key_file)
    if key_state == "different":
        return ConfigAudit(project, path, repo, "wrong_key", "chave antiga diferente da chave correta fixa; pressione C para corrigir", len(files), tracked, uncovered)
    if uncovered:
        return ConfigAudit(project, path, repo, "pending", f"{uncovered} caminho(s) sem filter/diff git-crypt", len(files), tracked, uncovered)
    if key_state == "unavailable":
        return ConfigAudit(project, path, repo, "locked", "regra correta, mas o repositório ainda não está aberto com a chave padrão", len(files), tracked, 0)
    return ConfigAudit(project, path, repo, "protected", "regra git-crypt e chave padrão confirmadas", len(files), tracked, 0)


def scan(code_root: Path | None = None, projects_file: Path | None = None, key_file: Path | None = None) -> AuditReport:
    root = project_root()
    code = Path(os.environ.get("CODE_ROOT", str(code_root or DEFAULT_CODE_ROOT))).expanduser()
    projects_path = Path(os.environ.get("PROJECTS_FILE", str(projects_file or resolve_projects_file(root)))).expanduser()
    key = Path(os.environ.get("GIT_CRYPT_KEY", str(key_file or DEFAULT_KEY_FILE))).expanduser()
    names = load_projects(projects_path)
    project_paths = {name: _real(code / name) for name in names if not name.lower().endswith(".zip")}
    gitcrypt_available = shutil.which("git-crypt") is not None
    projects: list[ProjectAudit] = []
    for name in names:
        path = code / name
        if name.lower().endswith(".zip"):
            continue
        if not path.is_dir():
            continue
        path_real = _real(path)
        nested = [other for other_name, other in project_paths.items() if other_name != name and other != path_real and other.is_relative_to(path_real)]
        configs = [audit_config(name, item, key, gitcrypt_available) for item in find_config_dirs(path, nested)]
        if not configs:
            continue
        states = {item.status for item in configs}
        if states == {"protected"}:
            status, detail = "protected", "todas as pastas .config estão protegidas"
        elif states & {"wrong_key", "no_git", "error"}:
            status, detail = "warning", "há bloqueios que exigem revisão"
        else:
            status, detail = "pending", "há pastas .config pendentes"
        projects.append(ProjectAudit(name, path, status, detail, configs))
    return AuditReport(projects_path, code, key, projects)


def _quote_pattern(pattern: str) -> str:
    if any(char.isspace() or char in {'"', '\\'} for char in pattern):
        return json.dumps(pattern, ensure_ascii=False)
    return pattern


def _ensure_attribute_rules(repo: Path, configs: list[ConfigAudit]) -> list[str]:
    attributes = repo / ".gitattributes"
    existing = attributes.read_bytes() if attributes.exists() else b""
    additions: list[str] = []
    for config in configs:
        rel_dir = _relative(repo, config.path)
        probe = f"{rel_dir}/.gitcrypt-probe/deep"
        if probe not in _covered_paths(repo, [probe]):
            additions.append(f"{_quote_pattern(rel_dir + '/**')} filter=git-crypt diff=git-crypt")
    if additions:
        with attributes.open("ab") as handle:
            if existing and not existing.endswith(b"\n"):
                handle.write(b"\n")
            handle.write(("\n".join(additions) + "\n").encode("utf-8"))
    return additions


def protect(report: AuditReport, selected: ConfigAudit | None = None) -> list[str]:
    if not report.key_file.is_file():
        raise RuntimeError(f"chave ausente: {report.key_file}")
    if shutil.which("git-crypt") is None:
        raise RuntimeError("git-crypt não instalado; execute: sudo apt install git-crypt")
    candidates = [selected] if selected else report.configs
    targets = [item for item in candidates if item and item.repo and item.status in {"pending", "locked"}]
    by_repo: dict[Path, list[ConfigAudit]] = {}
    for item in targets:
        by_repo.setdefault(item.repo, []).append(item)  # type: ignore[arg-type]
    messages: list[str] = []
    for repo, configs in by_repo.items():
        state = _key_state(repo, report.key_file)
        if state == "different":
            messages.append(f"BLOQUEADO {repo}: outra chave já está ativa")
            continue
        if state != "match":
            unlocked = _run(["git", "-C", str(repo), "crypt", "unlock", str(report.key_file)])
            if unlocked.returncode or _key_state(repo, report.key_file) != "match":
                reason = unlocked.stderr.decode("utf-8", "replace").strip() or "git-crypt recusou a chave"
                messages.append(f"ERRO {repo}: {reason}")
                continue
        additions = _ensure_attribute_rules(repo, configs)
        paths = sorted({_relative(repo, item.path) for item in configs if item.files})
        if additions:
            add = _run(["git", "-C", str(repo), "add", "--", ".gitattributes"])
            if add.returncode:
                messages.append(f"ERRO {repo}: não foi possível adicionar .gitattributes")
                continue
        if paths:
            stage = _run(["git", "-C", str(repo), "add", "-f", "--", *paths])
            if stage.returncode:
                reason = stage.stderr.decode("utf-8", "replace").strip() or "git add falhou"
                messages.append(f"ERRO {repo}: {reason}")
                continue
        messages.append(f"OK {repo}: {len(configs)} pasta(s), {len(additions)} regra(s); alterações preparadas no índice Git")
    if not messages:
        messages.append("Nenhuma pasta pendente selecionada.")
    return messages


def correct_key(report: AuditReport, selected: ConfigAudit) -> str:
    """Troca somente a chave ativa do repositório e recriptografa os blobs atuais.

    A operação mantém a chave/estado anterior dentro da pasta interna do Git,
    preserva o índice para rollback e nunca cria commit.
    """
    if selected.status != "wrong_key" or selected.repo is None:
        raise RuntimeError("selecione uma pasta marcada como CHAVE ANTIGA")
    if not report.key_file.is_file():
        raise RuntimeError(f"chave correta ausente: {report.key_file}")
    if shutil.which("git-crypt") is None:
        raise RuntimeError("git-crypt não instalado; execute: sudo apt install git-crypt")
    repo = selected.repo
    git_dir = _git_dir(repo)
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    migration = git_dir / "script-dev-automation" / "key-migrations" / stamp
    migration.mkdir(parents=True, exist_ok=False)
    old_key = migration / "previous.key"
    exported = _run(["git", "-C", str(repo), "crypt", "export-key", str(old_key)])
    if exported.returncode or not old_key.is_file():
        raise RuntimeError("não foi possível criar o backup recuperável da chave anterior")
    old_key.chmod(0o600)

    attributes = _attribute_files(repo, git_dir)
    attribute_bytes = {path: path.read_bytes() for path in attributes}
    tracked_crypt = _gitcrypt_tracked_paths(repo)
    repo_configs = [item for item in report.configs if item.repo == repo]
    plaintext_paths = sorted({
        _relative(repo, path)
        for config in repo_configs
        for path in _config_files(config.path)
    } | set(tracked_crypt))
    plaintext_backup = migration / "plaintext"
    plaintext_backup.mkdir(mode=0o700)
    for relative in plaintext_paths:
        source = repo / relative
        if not source.is_file() or source.is_symlink():
            continue
        content = source.read_bytes()
        if content.startswith(b"\x00GITCRYPT"):
            raise RuntimeError(f"arquivo ainda está fechado com a chave antiga: {source}")
        destination = plaintext_backup / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(content)
        destination.chmod(0o600)

    index = git_dir / "index"
    config = git_dir / "config"
    if index.is_file():
        shutil.copy2(index, migration / "index.before")
    if config.is_file():
        shutil.copy2(config, migration / "config.before")
    old_state = git_dir / "git-crypt" / "keys" / "default"
    saved_state = migration / "default-key-state.before"
    state_moved = False
    try:
        for path, content in attribute_bytes.items():
            path.write_bytes(_without_default_gitcrypt_rules(content))
        if old_state.exists():
            saved_state.parent.mkdir(parents=True, exist_ok=True)
            shutil.move(str(old_state), str(saved_state))
            state_moved = True
        unlocked = _run(["git", "-C", str(repo), "crypt", "unlock", str(report.key_file)])
        if unlocked.returncode or _key_state(repo, report.key_file) != "match":
            reason = unlocked.stderr.decode("utf-8", "replace").strip() or "git-crypt recusou a chave correta"
            raise RuntimeError(reason)
        for path, content in attribute_bytes.items():
            path.write_bytes(content)
        additions = _ensure_attribute_rules(repo, repo_configs)
        for relative in plaintext_paths:
            backup = plaintext_backup / relative
            if backup.is_file():
                destination = repo / relative
                destination.parent.mkdir(parents=True, exist_ok=True)
                destination.write_bytes(backup.read_bytes())
        attribute_relatives = [
            _relative(repo, path) for path in _attribute_files(repo, git_dir)
            if path.is_relative_to(repo)
        ]
        stage_paths = sorted(set(attribute_relatives + plaintext_paths))
        if stage_paths:
            staged = _run(["git", "-C", str(repo), "add", "-f", "--", *stage_paths])
            if staged.returncode:
                raise RuntimeError(staged.stderr.decode("utf-8", "replace").strip() or "git add falhou")
        status = _run(["git", "-C", str(repo), "crypt", "status"])
        output = (status.stdout + status.stderr).decode("utf-8", "replace")
        if status.returncode or "WARNING: staged/committed version is NOT ENCRYPTED" in output:
            raise RuntimeError("a verificação final encontrou conteúdo não criptografado")
        shutil.rmtree(plaintext_backup)
        return f"CHAVE CORRIGIDA {repo}: usando {report.key_file}; backup anterior em {migration}"
    except Exception:
        original_attribute_paths = set(attribute_bytes)
        for path in _attribute_files(repo, git_dir):
            if path not in original_attribute_paths and path.is_file():
                path.unlink()
        for path, content in attribute_bytes.items():
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(content)
        for relative in plaintext_paths:
            backup = plaintext_backup / relative
            if backup.is_file():
                destination = repo / relative
                destination.parent.mkdir(parents=True, exist_ok=True)
                destination.write_bytes(backup.read_bytes())
        if (migration / "index.before").is_file():
            shutil.copy2(migration / "index.before", index)
        if (migration / "config.before").is_file():
            shutil.copy2(migration / "config.before", config)
        if state_moved and saved_state.exists():
            if old_state.exists():
                old_state.unlink()
            old_state.parent.mkdir(parents=True, exist_ok=True)
            shutil.move(str(saved_state), str(old_state))
        raise
