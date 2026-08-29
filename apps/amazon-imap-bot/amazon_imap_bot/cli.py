from __future__ import annotations

import argparse
import json
import sys

from .config import load_settings
from .monitor import Monitor
from .store import Store
from .tui import run as run_tui


def doctor(settings) -> int:
    errors = 0
    print("Amazon IMAP Bot")
    print(f"Config: {settings.config_root}")
    print(f"Contas ativas: {sum(1 for a in settings.accounts if a.enabled)}")
    for account in settings.accounts:
        pwd = "configurada" if account.password else "AUSENTE"
        print(f"  - {account.email}: {'ativa' if account.enabled else 'desativada'} · senha {pwd}")
        if account.enabled and not account.password:
            errors += 1
    print(f"OpenAI: {'configurada' if settings.openai_api_key else 'AUSENTE'} · {settings.openai_model}")
    if not settings.openai_api_key:
        errors += 1
    try:
        import boto3
        session = boto3.Session(profile_name=settings.aws_profile, region_name=settings.aws_region)
        sts = session.client("sts")
        identity = sts.get_caller_identity()
        print(f"AWS: OK · {identity.get('Arn','')}")
    except Exception as exc:
        print(f"AWS: ERRO · {exc}")
        errors += 1
    print(f"Banco: {settings.database_path}")
    print(f"Som: {settings.sound_file} ({'OK' if settings.sound_file.is_file() else 'fallback terminal'})")
    return 1 if errors else 0


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(prog="amazon-imap-bot")
    parser.add_argument("--doctor", action="store_true")
    parser.add_argument("--once", action="store_true", help="faz uma verificação e encerra")
    args = parser.parse_args(argv)
    try:
        settings = load_settings()
        if args.doctor:
            return doctor(settings)
        if not any(a.enabled for a in settings.accounts):
            print("Nenhuma conta ativa em .config/amazon-imap-bot/settings.env", file=sys.stderr)
            return 2
        if args.once:
            monitor = Monitor(settings, Store(settings.database_path), print)
            monitor.run_once()
            return 0
        return run_tui(settings)
    except KeyboardInterrupt:
        return 130
    except Exception as exc:
        print(f"ERRO: {exc}", file=sys.stderr)
        return 1
