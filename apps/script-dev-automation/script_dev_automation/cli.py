from __future__ import annotations

import argparse
import json
from pathlib import Path

from .core import DEFAULT_CODE_ROOT, DEFAULT_KEY_FILE, correct_key, protect, scan
from .tui import run_tui


def parser() -> argparse.ArgumentParser:
    value = argparse.ArgumentParser(description="TUI de auditoria GitCrypt das pastas .config.")
    value.add_argument("--scan-json", action="store_true", help="imprime a auditoria em JSON")
    value.add_argument("--check", action="store_true", help="audita sem TUI e falha se houver pendências")
    value.add_argument("--protect-all", action="store_true", help="protege todas as pastas pendentes")
    value.add_argument("--correct-project", help="troca a chave antiga do projeto pela chave padrão")
    value.add_argument("--yes", action="store_true", help="confirma --protect-all não interativo")
    value.add_argument("--code-root", type=Path, default=DEFAULT_CODE_ROOT)
    value.add_argument("--projects-file", type=Path)
    value.add_argument("--key", type=Path, default=DEFAULT_KEY_FILE)
    return value


def main(argv: list[str] | None = None) -> int:
    args = parser().parse_args(argv)
    if not (args.scan_json or args.check or args.protect_all or args.correct_project):
        run_tui()
        return 0
    report = scan(args.code_root, args.projects_file, args.key)
    if args.protect_all:
        if not args.yes:
            raise SystemExit("--protect-all exige --yes; na TUI a confirmação é interativa")
        for message in protect(report):
            print(message)
        report = scan(args.code_root, args.projects_file, args.key)
    if args.correct_project:
        if not args.yes:
            raise SystemExit("--correct-project exige --yes; na TUI a confirmação é interativa")
        selected = next(
            (item for item in report.configs if item.project == args.correct_project and item.status == "wrong_key"),
            None,
        )
        if selected is None:
            raise SystemExit(f"projeto não encontrado com status CHAVE ANTIGA: {args.correct_project}")
        print(correct_key(report, selected))
        report = scan(args.code_root, args.projects_file, args.key)
    if args.scan_json:
        print(json.dumps(report.as_dict(), ensure_ascii=False, indent=2))
    else:
        print(json.dumps(report.counts(), ensure_ascii=False))
    if args.check:
        counts = report.counts()
        problems = counts["pending"] + counts["locked"] + counts["wrong_key"] + counts["no_git"] + counts["error"]
        return 3 if problems else 0
    return 0
