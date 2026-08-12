from __future__ import annotations

import argparse

from .config import Settings
from .contaja import ContajaAgent


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="exec-agent", description="Agente pessoal multitarefa")
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("contaja-login", help="Loga na ContaJá, resolve OTP pelo Gmail e abre Emitir NFS-e")
    return parser


def main() -> int:
    args = build_parser().parse_args()
    if args.command == "contaja-login":
        ContajaAgent(Settings()).login_and_find_invoice()
        return 0
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
