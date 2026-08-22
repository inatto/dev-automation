#!/usr/bin/env python3
"""Bootstrap/synchronize the projects declared by dev-automation.

Project list source of truth: config/auto-code-manager.projects.
Repository location source of truth: GitHub API for the active gh account.
config/environment.repositories is refreshed from GitHub after successful resolution.
"""

from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import sys
from pathlib import Path, PurePosixPath
from typing import Iterable

PROJECT_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_CODE_ROOT = Path(os.environ.get("CODE_ROOT", "/home/daniel/Code"))
DEFAULT_PROJECTS_FILE = PROJECT_ROOT / "config" / "auto-code-manager.projects"
DEFAULT_REPOSITORIES_FILE = PROJECT_ROOT / "config" / "environment.repositories"


def out(message: str = "") -> None:
    print(message, flush=True)


def fail(message: str, code: int = 1) -> "NoReturn":
    print(f"[dev-gitsetup] ERRO: {message}", file=sys.stderr, flush=True)
    raise SystemExit(code)


def run(cmd: list[str], *, check: bool = True, capture: bool = False) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        cmd,
        check=check,
        text=True,
        stdout=subprocess.PIPE if capture else None,
        stderr=subprocess.PIPE if capture else None,
    )


def active_projects(path: Path) -> list[str]:
    if not path.is_file():
        fail(f"arquivo de projetos não encontrado: {path}")

    result: list[str] = []
    seen: set[str] = set()
    for raw in path.read_text(encoding="utf-8-sig").splitlines():
        line = raw.split("#", 1)[0].strip().replace("\\", "/")
        if not line or line.lower().endswith(".zip"):
            continue
        normalized = str(PurePosixPath(line))
        if normalized.startswith("../") or normalized == ".." or normalized.startswith("/"):
            fail(f"caminho de projeto inválido: {line}")
        if normalized not in seen:
            seen.add(normalized)
            result.append(normalized)
    return result


def repository_map(path: Path) -> dict[str, str]:
    result: dict[str, str] = {}
    if not path.is_file():
        return result
    for raw in path.read_text(encoding="utf-8-sig").splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "|" not in line:
            continue
        rel, url = (part.strip() for part in line.split("|", 1))
        rel = rel.replace("\\", "/")
        if rel and url:
            result[str(PurePosixPath(rel))] = url
    return result


def parent_project(project: str, project_set: set[str]) -> str | None:
    p = PurePosixPath(project)
    for parent in p.parents:
        text = str(parent)
        if text == ".":
            break
        if text in project_set:
            return text
    return None


def ensure_command(name: str) -> None:
    if shutil.which(name) is None:
        if name == "gh":
            fail("GitHub CLI (gh) não instalado. No Ubuntu: sudo apt update && sudo apt install -y gh")
        fail(f"comando obrigatório não encontrado: {name}")


def ensure_github_auth(non_interactive: bool = False) -> str:
    ensure_command("gh")

    status = run(["gh", "auth", "status", "--hostname", "github.com"], check=False, capture=True)
    if status.returncode != 0:
        if non_interactive:
            fail("nenhum usuário GitHub autenticado no gh")
        out("[dev-gitsetup] Nenhum usuário GitHub autenticado.")
        out("[dev-gitsetup] Abrindo login oficial do GitHub CLI...")
        login = run(
            ["gh", "auth", "login", "--hostname", "github.com", "--git-protocol", "https", "--web"],
            check=False,
        )
        if login.returncode != 0:
            fail("autenticação do GitHub CLI não foi concluída")
        status = run(["gh", "auth", "status", "--hostname", "github.com"], check=False, capture=True)
        if status.returncode != 0:
            fail("gh continua sem uma conta GitHub autenticada")

    user = run(["gh", "api", "user", "--jq", ".login"], capture=True).stdout.strip()
    if not user:
        fail("não foi possível identificar o usuário autenticado no GitHub")

    # Keep git and gh on the same transport. No surprise SSH prompts on a fresh machine.
    run(["gh", "config", "set", "git_protocol", "https", "--host", "github.com"])
    run(["gh", "auth", "setup-git"])
    return user


def accessible_repositories() -> dict[str, list[tuple[str, str]]]:
    proc = run(
        [
            "gh",
            "api",
            "--paginate",
            "/user/repos?per_page=100&affiliation=owner,collaborator,organization_member",
            "--jq",
            ".[] | [.name, .full_name, .clone_url] | @tsv",
        ],
        capture=True,
    )
    by_name: dict[str, list[tuple[str, str]]] = {}
    for line in proc.stdout.splitlines():
        parts = line.split("\t")
        if len(parts) != 3:
            continue
        name, full_name, clone_url = parts
        by_name.setdefault(name, []).append((full_name, clone_url))
    return by_name


def _mapped_full_name(url: str) -> str | None:
    cleaned = url.strip().removesuffix(".git")
    marker = "github.com/"
    if marker not in cleaned.lower():
        return None
    # Preserve original path while finding the marker case-insensitively.
    idx = cleaned.lower().index(marker) + len(marker)
    value = cleaned[idx:].strip("/")
    return value or None


def resolve_repo(project: str, mapping: dict[str, str], accessible: dict[str, list[tuple[str, str]]]) -> tuple[str, str]:
    """Resolve exclusively from the current GitHub API result.

    A previous environment.repositories entry may only disambiguate two currently
    accessible repositories with the same basename. Its URL is never trusted as
    the clone source.
    """
    name = PurePosixPath(project).name
    matches = accessible.get(name, [])
    if not matches:
        fail(f"repositório não encontrado no GitHub para '{project}' (nome esperado: {name})")
    if len(matches) == 1:
        return matches[0]

    previous = mapping.get(project)
    previous_full = _mapped_full_name(previous) if previous else None
    if previous_full:
        selected = [item for item in matches if item[0].lower() == previous_full.lower()]
        if len(selected) == 1:
            return selected[0]

    names = ", ".join(full for full, _ in matches)
    fail(
        f"mais de um repositório GitHub acessível chamado '{name}': {names}. "
        "O environment.repositories antigo só desempata se apontar para um deles."
    )


def write_repository_map(path: Path, entries: list[tuple[str, str]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    content = [
        "# Gerado automaticamente por dev-gitsetup a partir do GitHub API.",
        "# Não use este arquivo como fonte da verdade; execute dev-gitsetup para atualizá-lo.",
    ]
    content.extend(f"{project}|{clone_url}" for project, clone_url in entries)
    content.append("")
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text("\n".join(content), encoding="utf-8")
    os.replace(tmp, path)


def git_root(path: Path) -> Path | None:
    proc = run(["git", "-C", str(path), "rev-parse", "--show-toplevel"], check=False, capture=True)
    if proc.returncode != 0:
        return None
    value = proc.stdout.strip()
    return Path(value) if value else None


def sync(args: argparse.Namespace) -> int:
    ensure_command("git")
    user = ensure_github_auth(args.non_interactive)
    out(f"[dev-gitsetup] GitHub autenticado: {user}")

    projects = active_projects(args.projects_file)
    mapping = repository_map(args.repositories_file)
    project_set = set(projects)
    roots = [project for project in projects if parent_project(project, project_set) is None]
    children = [project for project in projects if project not in roots]

    out(f"[dev-gitsetup] Projetos ativos: {len(projects)} ({len(roots)} repositórios + {len(children)} subprojetos)")
    accessible = accessible_repositories()

    cloned = fetched = skipped = errors = 0
    resolved: dict[str, tuple[str, str]] = {}
    for project in roots:
        try:
            resolved[project] = resolve_repo(project, mapping, accessible)
        except SystemExit:
            errors += 1
            if not args.keep_going:
                raise

    if errors == 0:
        repo_entries = [(project, resolved[project][1]) for project in roots]
        if args.dry_run:
            out(f"[dev-gitsetup] DRY-RUN: atualizaria {args.repositories_file} com {len(repo_entries)} repositórios")
        else:
            write_repository_map(args.repositories_file, repo_entries)
            out(f"[dev-gitsetup] Atualizado: {args.repositories_file} ({len(repo_entries)} repositórios)")

    for project in roots:
        if project not in resolved:
            continue
        target = args.code_root / Path(project)
        full_name, clone_url = resolved[project]

        out("")
        out(f"[{project}]")
        out(f"  GitHub : {full_name}")
        out(f"  Local  : {target}")

        if (target / ".git").is_dir():
            out("  Ação   : fetch --all --prune (já existe)")
            if not args.dry_run:
                run(["git", "-C", str(target), "remote", "set-url", "origin", clone_url], check=False)
                result = run(["git", "-C", str(target), "fetch", "--all", "--prune"], check=False)
                if result.returncode != 0:
                    errors += 1
                    if not args.keep_going:
                        fail(f"falha ao atualizar {project}")
                    continue
            fetched += 1
            continue

        if target.exists():
            root = git_root(target)
            if root is not None:
                out(f"  Ação   : ignorado; já pertence ao Git {root}")
                skipped += 1
                continue
            out("  Ação   : ERRO; caminho existe e não é repositório Git")
            errors += 1
            if not args.keep_going:
                fail(f"não vou sobrescrever: {target}")
            continue

        out("  Ação   : clone")
        if not args.dry_run:
            target.parent.mkdir(parents=True, exist_ok=True)
            result = run(["git", "clone", clone_url, str(target)], check=False)
            if result.returncode != 0:
                errors += 1
                if not args.keep_going:
                    fail(f"falha ao clonar {full_name}")
                continue
        cloned += 1

    for project in children:
        parent = parent_project(project, project_set)
        out(f"[subprojeto] {project} -> incluído em {parent}")
        skipped += 1

    out("")
    out("[dev-gitsetup] Resultado")
    out(f"  clonados    : {cloned}")
    out(f"  atualizados : {fetched}")
    out(f"  ignorados   : {skipped}")
    out(f"  erros       : {errors}")

    if errors:
        return 1
    return 0


def parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="dev-gitsetup",
        description="Prepara /home/daniel/Code a partir de config/auto-code-manager.projects.",
    )
    p.add_argument("--code-root", type=Path, default=DEFAULT_CODE_ROOT)
    p.add_argument("--projects-file", type=Path, default=DEFAULT_PROJECTS_FILE)
    p.add_argument("--repositories-file", type=Path, default=DEFAULT_REPOSITORIES_FILE)
    p.add_argument("--dry-run", action="store_true", help="mostra o que faria sem clonar/atualizar")
    p.add_argument("--non-interactive", action="store_true", help="falha em vez de abrir gh auth login")
    p.add_argument("--keep-going", action="store_true", help="continua os demais projetos após uma falha")
    return p


def main() -> int:
    args = parser().parse_args()
    return sync(args)


if __name__ == "__main__":
    raise SystemExit(main())
