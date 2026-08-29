from __future__ import annotations

import argparse
import importlib.util
import json
import os
import sys
from pathlib import Path
from typing import Any

from .audio_service import validate_audio, wav_duration
from .catalog_store import CatalogStore
from .config_store import ConfigStore
from .errors import GptConsoleError
from .openai_gateway import OpenAIGateway
from .paths import AppPaths
from .tui import run_tui
from .usage_store import UsageStore, fetch_organization_costs
from .zip_workflow import ZipWorkflow


def parser() -> argparse.ArgumentParser:
    value = argparse.ArgumentParser(prog="gpt-console", description="Playground TUI da OpenAI API no Dev Automation")
    value.add_argument("--dump-json", action="store_true", help="mostra estado seguro sem chamar a API")
    value.add_argument("--validate", action="store_true", help="valida configuração e catálogos")
    value.add_argument("--doctor", action="store_true", help="diagnóstico local sem chamar a API")
    value.add_argument("--test-connection", action="store_true", help="valida a chave e o modelo na API")
    value.add_argument("--group", help="id do grupo de ações")
    value.add_argument("--classify", metavar="TEXT", help="identifica uma ação por texto")
    value.add_argument("--transcribe", metavar="AUDIO", help="transcreve áudio e identifica a ação")
    value.add_argument("--zip-request", metavar="TEXT", help="edita o ZIP do grupo e salva em Downloads")
    value.add_argument("--usage", action="store_true", help="mostra uso local")
    value.add_argument("--remote-costs", action="store_true", help="inclui custos remotos dos últimos 30 dias")
    return value


def context() -> tuple[AppPaths, ConfigStore, CatalogStore, UsageStore, Any, list[Any]]:
    paths = AppPaths.discover()
    config = ConfigStore(paths)
    catalogs = CatalogStore(paths)
    usage = UsageStore(paths)
    catalogs.bootstrap_defaults()
    settings = config.load()
    groups = catalogs.list_groups()
    return paths, config, catalogs, usage, settings, groups


def selected_group(groups, project_id: str | None):
    if not groups:
        raise GptConsoleError("nenhum grupo de ações cadastrado")
    if not project_id:
        return groups[0]
    group = next((item for item in groups if item.project_id == project_id), None)
    if group is None:
        raise GptConsoleError(f"grupo não encontrado: {project_id}")
    return group


def safe_state(paths, settings, groups, usage) -> dict[str, Any]:
    workflow = ZipWorkflow(settings, OpenAIGateway(settings, usage))
    return {
        "app": "gpt-console",
        "project_root": str(paths.project_root),
        "config_root": str(paths.config_root),
        "settings": settings.public_dict(),
        "groups": [
            {
                "project_id": group.project_id,
                "label": group.label,
                "zip_name": group.zip_name,
                "actions": [action.name for action in group.actions],
                "zip": workflow.inspect(group),
            }
            for group in groups
        ],
        "usage": usage.load().as_dict(),
    }


def doctor_state(paths, settings, groups) -> dict[str, Any]:
    return {
        "python": sys.version.split()[0],
        "openai_sdk": bool(importlib.util.find_spec("openai")),
        "sounddevice": bool(importlib.util.find_spec("sounddevice")),
        "numpy": bool(importlib.util.find_spec("numpy")),
        "api_configured": settings.configured,
        "config_root": str(paths.config_root),
        "groups": len(groups),
        "code_root_exists": Path(os.path.expandvars(os.path.expanduser(settings.code_root))).is_dir(),
        "downloads_root_exists": Path(os.path.expandvars(os.path.expanduser(settings.downloads_root))).is_dir(),
    }


def main(argv: list[str] | None = None) -> int:
    args = parser().parse_args(argv)
    if not any(
        (
            args.dump_json,
            args.validate,
            args.doctor,
            args.test_connection,
            args.classify is not None,
            args.transcribe is not None,
            args.zip_request is not None,
            args.usage,
            args.remote_costs,
        )
    ):
        run_tui()
        return 0
    try:
        paths, config, catalogs, usage, settings, groups = context()
        if args.validate:
            config.validate(settings)
            print(json.dumps({"status": "ok", "groups": len(groups)}, ensure_ascii=False))
            return 0
        if args.dump_json:
            print(json.dumps(safe_state(paths, settings, groups, usage), ensure_ascii=False, indent=2))
            return 0
        if args.doctor:
            print(json.dumps(doctor_state(paths, settings, groups), ensure_ascii=False, indent=2))
            return 0
        gateway = OpenAIGateway(settings, usage)
        if args.test_connection:
            print(json.dumps(gateway.test_connection(), ensure_ascii=False, indent=2))
            return 0
        if args.usage or args.remote_costs:
            payload: dict[str, Any] = {"local": usage.load().as_dict()}
            if args.remote_costs:
                payload["organization_costs"] = fetch_organization_costs(settings)
            print(json.dumps(payload, ensure_ascii=False, indent=2))
            return 0
        group = selected_group(groups, args.group)
        if args.classify is not None:
            print(json.dumps(gateway.classify(group, args.classify).as_dict(), ensure_ascii=False, indent=2))
            return 0
        if args.transcribe is not None:
            audio = validate_audio(Path(args.transcribe))
            transcript = gateway.transcribe(audio, wav_duration(audio))
            match = gateway.classify(group, transcript)
            print(json.dumps({"transcript": transcript, "match": match.as_dict()}, ensure_ascii=False, indent=2))
            return 0
        if args.zip_request is not None:
            result = ZipWorkflow(settings, gateway).run(group, args.zip_request)
            print(json.dumps(result.as_dict(), ensure_ascii=False, indent=2))
            return 0
        return 0
    except GptConsoleError as exc:
        print(f"[gpt-console] ERRO: {exc}", file=sys.stderr)
        return 2
    except KeyboardInterrupt:
        print("\n[gpt-console] interrompido.", file=sys.stderr)
        return 130


if __name__ == "__main__":
    raise SystemExit(main())
