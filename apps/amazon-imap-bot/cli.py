from __future__ import annotations

import argparse
import sys
import time

from config import load_settings
from function_catalog import OracleFunctionCatalog
from monitor import Monitor
from store import Store
from tui import run as run_tui
from mobile_api import serve_mobile_api


def doctor(settings, startup_log=None) -> int:
    startup_log = startup_log or (lambda text: None)
    errors = 0
    print("Amazon IMAP Bot")
    print(f"Config: {settings.config_root}")
    print(f"Contas ativas: {sum(1 for a in settings.accounts if a.enabled)}")
    for account in settings.accounts:
        pwd = "configurada" if account.password else "AUSENTE"
        print(f"  - {account.email}: {'ativa' if account.enabled else 'desativada'} · senha {pwd}")
        if account.enabled and not account.password:
            errors += 1
    print(f"OpenAI: {'configurada' if settings.openai_api_key else 'AUSENTE'} · {settings.openai_model} · reasoning={settings.openai_reasoning_effort}")
    print(f"OpenAI timeout: {settings.openai_timeout_seconds}s")
    print(f"OpenAI saída: {settings.openai_output_dir}")
    db = settings.function_database
    print(f"Catálogo de funções: Oracle · schema={db.schema or 'AUSENTE'} · config={db.env_path}")
    print(f"Senha Oracle: {'configurada' if db.password else 'AUSENTE'}")
    try:
        payload = OracleFunctionCatalog(db, log=startup_log).load()
        print(f"Oracle: OK · versão={payload.get('version', '-')} · funções={len(payload.get('functions') or {})}")
    except Exception as exc:
        print(f"Oracle: ERRO · {exc}")
        errors += 1
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
    parser.add_argument("--api", action="store_true", help="inicia a API segura para o aplicativo Flutter")
    args = parser.parse_args(argv)
    started = time.monotonic()

    def startup_log(text: str) -> None:
        elapsed = time.monotonic() - started
        print(f"[amazon-imap-bot] +{elapsed:7.2f}s {text}", file=sys.stderr, flush=True)

    try:
        startup_log("Inicialização iniciada.")
        startup_log("Carregando settings.env e database.env...")
        settings = load_settings()
        startup_log(
            f"Configuração carregada: root={settings.config_root} "
            f"contas_ativas={sum(1 for account in settings.accounts if account.enabled)}."
        )
        if args.doctor:
            startup_log("Executando diagnóstico --doctor...")
            return doctor(settings, startup_log=startup_log)
        if args.api:
            startup_log("Iniciando API mobile...")
            return serve_mobile_api(settings)
        if not any(a.enabled for a in settings.accounts):
            print("Nenhuma conta ativa em .config/amazon-imap-bot/settings.env", file=sys.stderr)
            return 2
        if args.once:
            startup_log(f"Abrindo SQLite local em {settings.database_path}...")
            store = Store(settings.database_path)
            startup_log("SQLite local OK; inicializando monitor --once...")
            monitor = Monitor(settings, store, print, on_startup=startup_log)
            startup_log("Monitor --once pronto; executando verificação IMAP.")
            monitor.run_once()
            return 0
        return run_tui(settings, startup_log=startup_log)
    except KeyboardInterrupt:
        return 130
    except Exception as exc:
        startup_log(f"Inicialização interrompida por erro: {exc}")
        print(f"ERRO: {exc}", file=sys.stderr)
        return 1
