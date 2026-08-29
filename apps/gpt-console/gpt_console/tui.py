from __future__ import annotations

import curses
import importlib.util
import json
import locale
import os
import textwrap
import time
from concurrent.futures import Future, ThreadPoolExecutor
from dataclasses import replace
from pathlib import Path
from typing import Any, Callable

from .audio_service import record_microphone, validate_audio, wav_duration
from .catalog_store import CatalogStore
from .config_store import ConfigStore, Settings
from .errors import GptConsoleError
from .models import ActionDefinition, ActionGroup, ParameterDefinition
from .openai_gateway import OpenAIGateway
from .paths import AppPaths
from .usage_store import UsageStore, fetch_organization_costs
from .zip_workflow import ZipWorkflow

locale.setlocale(locale.LC_ALL, "")

SCREENS = (
    ("dashboard", "INÍCIO", "F8"),
    ("actions", "AÇÕES JSON", "F3"),
    ("text", "TESTE TEXTO", "F4"),
    ("voice", "VOZ / ÁUDIO", "F5"),
    ("zip", "PROJETO ZIP", "F6"),
    ("usage", "USO DA API", "F7"),
    ("config", "CONFIGURAÇÃO", "F2"),
    ("doctor", "DIAGNÓSTICO", "F9"),
    ("help", "AJUDA", "F1"),
)

CONFIG_FIELDS = (
    ("api_key", "OpenAI API key", True),
    ("admin_api_key", "OpenAI Admin key (uso/custos)", True),
    ("organization_id", "Organization ID", False),
    ("project_id", "Project ID", False),
    ("base_url", "Base URL", False),
    ("text_model", "Modelo texto/ações", False),
    ("transcription_model", "Modelo transcrição", False),
    ("zip_model", "Modelo edição ZIP", False),
    ("request_timeout_seconds", "Timeout (segundos)", False),
    ("recording_seconds", "Gravação (segundos)", False),
    ("code_root", "Pasta Code", False),
    ("downloads_root", "Pasta Downloads", False),
    ("max_zip_mb", "Limite ZIP (MiB)", False),
    ("container_memory", "Memória Code Interpreter", False),
)


def safe_add(win, y: int, x: int, value: Any, attr: int = 0, max_width: int | None = None) -> None:
    try:
        height, width = win.getmaxyx()
        if y < 0 or y >= height or x < 0 or x >= width:
            return
        limit = max(0, min(max_width if max_width is not None else width - x, width - x))
        if limit:
            win.addnstr(y, x, str(value), limit, attr)
    except curses.error:
        pass


def wrapped(value: str, width: int) -> list[str]:
    if width <= 4:
        return [value[: max(0, width)]]
    output: list[str] = []
    for paragraph in value.splitlines() or [""]:
        output.extend(textwrap.wrap(paragraph, width=width, replace_whitespace=False) or [""])
    return output


class GptConsoleTui:
    def __init__(self, stdscr):
        self.stdscr = stdscr
        self.paths = AppPaths.discover()
        self.config_store = ConfigStore(self.paths)
        self.catalog_store = CatalogStore(self.paths)
        self.usage_store = UsageStore(self.paths)
        self.catalog_store.bootstrap_defaults()
        self.settings = self.config_store.load()
        self.groups = self.catalog_store.list_groups()
        self.group_index = 0
        self.action_index = 0
        self.actions_focus = "actions"
        self.menu_index = 0
        self.menu_focused = True
        self.config_index = 0
        self.screen = "dashboard"
        self.message = ""
        self.message_until = 0.0
        self.last_result = ""
        self.last_transcript = ""
        self.remote_usage: dict[str, Any] | None = None
        self.executor = ThreadPoolExecutor(max_workers=1, thread_name_prefix="gpt-console")
        self.future: Future | None = None
        self.job_label = ""
        self.spinner = 0
        self.running = True
        self.attrs: dict[str, int] = {}
        self._init_curses()

    @property
    def group(self) -> ActionGroup | None:
        if not self.groups:
            return None
        self.group_index %= len(self.groups)
        return self.groups[self.group_index]

    def _init_curses(self) -> None:
        self.stdscr.keypad(True)
        self.stdscr.timeout(100)
        try:
            curses.curs_set(0)
        except curses.error:
            pass
        try:
            curses.mousemask(curses.ALL_MOUSE_EVENTS)
        except curses.error:
            pass
        if curses.has_colors():
            curses.start_color()
            try:
                curses.use_default_colors()
            except curses.error:
                pass
            pairs = {
                1: (curses.COLOR_WHITE, curses.COLOR_BLUE),
                2: (curses.COLOR_CYAN, -1),
                3: (curses.COLOR_BLACK, curses.COLOR_CYAN),
                4: (curses.COLOR_GREEN, -1),
                5: (curses.COLOR_YELLOW, -1),
                6: (curses.COLOR_RED, -1),
                7: (curses.COLOR_WHITE, -1),
                8: (curses.COLOR_BLACK, curses.COLOR_WHITE),
            }
            for pair, colors in pairs.items():
                try:
                    curses.init_pair(pair, *colors)
                except curses.error:
                    pass
        self.attrs = {
            "header": curses.color_pair(1) | curses.A_BOLD,
            "accent": curses.color_pair(2) | curses.A_BOLD,
            "selected": curses.color_pair(3) | curses.A_BOLD,
            "ok": curses.color_pair(4) | curses.A_BOLD,
            "warn": curses.color_pair(5) | curses.A_BOLD,
            "error": curses.color_pair(6) | curses.A_BOLD,
            "normal": curses.color_pair(7),
            "field": curses.color_pair(8),
            "muted": curses.A_DIM,
            "bold": curses.A_BOLD,
        }

    def set_message(self, message: str, seconds: float = 6.0) -> None:
        self.message = message.replace("\n", " ")
        self.message_until = time.monotonic() + seconds

    def refresh_groups(self) -> None:
        selected = self.group.project_id if self.group else ""
        self.groups = self.catalog_store.list_groups()
        if selected:
            self.group_index = next((i for i, item in enumerate(self.groups) if item.project_id == selected), 0)
        self.action_index = 0

    def gateway(self) -> OpenAIGateway:
        return OpenAIGateway(self.settings, self.usage_store)

    def prep_box(self, win, label: str) -> None:
        try:
            win.erase()
            win.box()
        except curses.error:
            pass
        safe_add(win, 0, 2, f" {label} ", self.attrs["accent"])

    def draw(self) -> None:
        self.stdscr.erase()
        height, width = self.stdscr.getmaxyx()
        if height < 24 or width < 96:
            self.draw_small_terminal()
            self.stdscr.refresh()
            return
        title = " GPT CONSOLE · DEV AUTOMATION · OPENAI API PLAYGROUND "
        try:
            self.stdscr.attrset(self.attrs["header"])
            self.stdscr.hline(0, 0, " ", width)
            self.stdscr.hline(1, 0, " ", width)
            safe_add(self.stdscr, 0, 2, title, self.attrs["header"], width - 4)
            state = "CONFIGURADA" if self.settings.configured else "CONFIGURE F2"
            group = self.group.label if self.group else "sem projeto"
            safe_add(self.stdscr, 1, 2, f"API: {state}   Projeto: {group}", self.attrs["header"], width - 4)
            self.stdscr.attrset(0)
        except curses.error:
            pass
        content_height = height - 5
        menu_width = 24
        menu = self.stdscr.derwin(content_height, menu_width, 2, 0)
        body = self.stdscr.derwin(content_height, width - menu_width, 2, menu_width)
        self.draw_menu(menu)
        drawer = getattr(self, f"draw_{self.screen}", self.draw_dashboard)
        drawer(body)
        footer = self.footer_text()
        try:
            self.stdscr.hline(height - 3, 0, curses.ACS_HLINE, width)
        except curses.error:
            pass
        if self.future:
            frames = "◐◓◑◒"
            self.spinner = (self.spinner + 1) % len(frames)
            safe_add(self.stdscr, height - 2, 2, f"{frames[self.spinner]} {self.job_label}", self.attrs["warn"], width - 4)
        elif self.message and time.monotonic() < self.message_until:
            safe_add(self.stdscr, height - 2, 2, self.message, self.attrs["accent"], width - 4)
        else:
            safe_add(self.stdscr, height - 2, 2, footer, self.attrs["muted"], width - 4)
        safe_add(self.stdscr, height - 1, 2, "F1 Ajuda  F2 Config  F3 Ações  F4 Texto  F5 Voz  F6 ZIP  F7 Uso  F9 Diagnóstico  Q Sair", self.attrs["bold"], width - 4)
        self.stdscr.refresh()

    def draw_small_terminal(self) -> None:
        h, w = self.stdscr.getmaxyx()
        safe_add(self.stdscr, 1, 2, "GPT CONSOLE", self.attrs["accent"])
        safe_add(self.stdscr, 3, 2, f"Terminal atual: {w}x{h}")
        safe_add(self.stdscr, 4, 2, "Mínimo recomendado: 96x24.", self.attrs["warn"])
        safe_add(self.stdscr, 6, 2, "Amplie o terminal. Q sai.")

    def draw_menu(self, win) -> None:
        self.prep_box(win, "MÓDULOS")
        _, width = win.getmaxyx()
        for index, (key, label, shortcut) in enumerate(SCREENS):
            if self.menu_focused and index == self.menu_index:
                attr = self.attrs["selected"]
            elif key == self.screen:
                attr = self.attrs["accent"]
            else:
                attr = self.attrs["normal"]
            safe_add(win, 2 + index * 2, 2, f"{label:<15}{shortcut:>3}", attr, width - 4)
        safe_add(win, 21, 2, "[ / ] troca projeto", self.attrs["muted"], width - 4)

    def footer_text(self) -> str:
        if self.menu_focused:
            return "↑↓ seleciona módulo · Enter abre · [ ] troca projeto"
        if self.screen == "actions":
            return "Tab grupo/ação · N novo grupo · G editar grupo · A nova ação · E editar · D remover · Esc módulos"
        if self.screen == "config":
            return "↑↓ campo · Enter editar · Del limpar · T testar conexão · S salvar · Esc módulos"
        if self.screen == "voice":
            return "A arquivo de áudio · R gravar microfone · [ ] troca projeto · Esc módulos"
        if self.screen == "zip":
            return "Enter descreve e envia ZIP · resposta vai para Downloads · Esc módulos"
        if self.screen == "usage":
            return "U consulta custos remotos com Admin API key · F7 atualiza tela · Esc módulos"
        return "Esc volta aos módulos · [ ] troca projeto"

    def body_title(self, win, title: str, subtitle: str = "") -> tuple[int, int]:
        self.prep_box(win, title)
        _, width = win.getmaxyx()
        if subtitle:
            safe_add(win, 2, 3, subtitle, self.attrs["muted"], width - 6)
        return win.getmaxyx()

    def draw_dashboard(self, win) -> None:
        h, w = self.body_title(win, "CENTRAL / VISÃO GERAL", "Protótipo desacoplado para ações, voz e manutenção de projetos ZIP.")
        status_attr = self.attrs["ok"] if self.settings.configured else self.attrs["error"]
        safe_add(win, 4, 3, "OPENAI API", self.attrs["accent"])
        safe_add(win, 5, 5, "Status:")
        safe_add(win, 5, 20, "PRONTA" if self.settings.configured else "NÃO CONFIGURADA", status_attr)
        safe_add(win, 6, 5, "Chave:")
        safe_add(win, 6, 20, self.settings.masked_api_key)
        safe_add(win, 7, 5, "Modelos:")
        safe_add(win, 7, 20, f"ações={self.settings.text_model}  voz={self.settings.transcription_model}  ZIP={self.settings.zip_model}", 0, w - 24)
        safe_add(win, 9, 3, "PROJETO SELECIONADO", self.attrs["accent"])
        if self.group:
            safe_add(win, 10, 5, f"{self.group.label} ({self.group.project_id})", self.attrs["bold"])
            safe_add(win, 11, 5, f"Ações: {len(self.group.actions)}   ZIP: {self.group.zip_name}")
            source = ZipWorkflow(self.settings, self.gateway()).source_for(self.group)
            safe_add(win, 12, 5, f"Origem: {source}", self.attrs["ok"] if source.is_file() else self.attrs["warn"], w - 10)
        else:
            safe_add(win, 10, 5, "Nenhum grupo. Pressione F3 e N para cadastrar.", self.attrs["warn"])
        safe_add(win, 14, 3, "FLUXOS", self.attrs["accent"])
        flows = [
            ("F4", "texto → catálogo de funções → ação + parâmetros JSON"),
            ("F5", "arquivo/microfone → transcrição → mesmo roteador de ações"),
            ("F6", "ZIP da pasta Code → Code Interpreter → ZIP validado em Downloads"),
            ("F7", "uso local desta aplicação e custos remotos opcionais"),
        ]
        for index, (key, description) in enumerate(flows):
            safe_add(win, 15 + index, 5, key, self.attrs["accent"])
            safe_add(win, 15 + index, 11, description, 0, w - 15)
        if self.last_result:
            safe_add(win, 20, 3, "ÚLTIMO RESULTADO", self.attrs["accent"])
            for offset, line in enumerate(wrapped(self.last_result, w - 10)[: max(0, h - 23)]):
                safe_add(win, 21 + offset, 5, line, 0, w - 10)

    def draw_actions(self, win) -> None:
        h, w = self.body_title(win, "CATÁLOGOS / AÇÕES POR PROJETO", "Arquivos JSON em dev-automation/.config/gpt-console/actions/.")
        split = max(30, min(42, w // 3))
        safe_add(win, 4, 3, "PROJETOS", self.attrs["accent"])
        for index, group in enumerate(self.groups[: max(1, h - 8)]):
            if index == self.group_index:
                attr = self.attrs["selected"] if self.actions_focus == "groups" else self.attrs["accent"]
            else:
                attr = 0
            safe_add(win, 5 + index, 3, f"{group.label}  [{len(group.actions)}]", attr, split - 5)
        safe_add(win, 4, split, "AÇÕES / JSON GERADO", self.attrs["accent"])
        group = self.group
        if not group:
            safe_add(win, 6, split, "N cria o primeiro grupo.", self.attrs["warn"])
            return
        for index, action in enumerate(group.actions[: max(1, min(9, h - 10))]):
            if index == self.action_index:
                attr = self.attrs["selected"] if self.actions_focus == "actions" else self.attrs["accent"]
            else:
                attr = 0
            safe_add(win, 5 + index, split, action.name, attr, w - split - 3)
        selected = group.actions[self.action_index % len(group.actions)] if group.actions else None
        if selected:
            y = min(16, 6 + len(group.actions))
            preview = json.dumps(selected.function_tool(), ensure_ascii=False, indent=2)
            for line in preview.splitlines()[: max(0, h - y - 2)]:
                safe_add(win, y, split, line, self.attrs["muted"], w - split - 3)
                y += 1

    def draw_text(self, win) -> None:
        h, w = self.body_title(win, "TESTE DE TEXTO / FUNCTION CALLING", "Enter escreve um comando como cliente; a resposta nunca executa a ação.")
        safe_add(win, 4, 3, f"Grupo: {self.group.label if self.group else 'nenhum'}", self.attrs["accent"])
        safe_add(win, 6, 3, "Exemplo: procure o Pedro", self.attrs["muted"])
        safe_add(win, 8, 3, "RESULTADO JSON", self.attrs["accent"])
        value = self.last_result or "Nenhum teste executado."
        for offset, line in enumerate(wrapped(value, w - 8)[: max(0, h - 11)]):
            safe_add(win, 9 + offset, 5, line, 0, w - 8)

    def draw_voice(self, win) -> None:
        h, w = self.body_title(win, "VOZ / TRANSCRIÇÃO + AÇÃO", "A usa arquivo existente; R grava o microfone pelo tempo configurado.")
        safe_add(win, 4, 3, f"Modelo: {self.settings.transcription_model}")
        safe_add(win, 5, 3, f"Gravação: {self.settings.recording_seconds}s")
        safe_add(win, 7, 3, "ÚLTIMA TRANSCRIÇÃO", self.attrs["accent"])
        for offset, line in enumerate(wrapped(self.last_transcript or "Nenhuma.", w - 8)[:5]):
            safe_add(win, 8 + offset, 5, line, 0, w - 8)
        safe_add(win, 14, 3, "AÇÃO IDENTIFICADA", self.attrs["accent"])
        for offset, line in enumerate(wrapped(self.last_result or "Nenhuma.", w - 8)[: max(0, h - 17)]):
            safe_add(win, 15 + offset, 5, line, 0, w - 8)

    def draw_zip(self, win) -> None:
        h, w = self.body_title(win, "PROJETO ZIP / CODE INTERPRETER", "Lê o ZIP em Code e grava um novo pacote em Downloads; nada é aplicado diretamente.")
        group = self.group
        if not group:
            safe_add(win, 4, 3, "Cadastre um projeto em F3.", self.attrs["warn"])
            return
        workflow = ZipWorkflow(self.settings, self.gateway())
        source = workflow.source_for(group)
        exists = source.is_file()
        safe_add(win, 4, 3, f"Projeto: {group.label}", self.attrs["accent"])
        safe_add(win, 5, 3, f"Origem: {source}", 0, w - 6)
        if exists:
            safe_add(win, 6, 3, f"ZIP encontrado · {source.stat().st_size / 1024 / 1024:.1f} MiB · integridade será validada antes do envio", self.attrs["ok"])
        else:
            safe_add(win, 6, 3, "ZIP não encontrado", self.attrs["error"], w - 6)
        safe_add(win, 8, 3, f"Destino: {workflow.downloads_root}/{Path(group.zip_name).stem}(gpt-data-hora).zip", 0, w - 6)
        safe_add(win, 10, 3, "SEGURANÇA DO FLUXO", self.attrs["accent"])
        items = [
            "• confirmação obrigatória antes do upload",
            "• arquivo remoto de entrada apagado após a resposta",
            "• download imediato antes de o container expirar",
            "• CRC e caminhos internos validados antes do Downloads",
            "• Dev Manager continua responsável por importar e preservar configs locais",
        ]
        for offset, item in enumerate(items):
            safe_add(win, 11 + offset, 5, item, 0, w - 10)
        if self.last_result:
            safe_add(win, 18, 3, "ÚLTIMO JOB", self.attrs["accent"])
            for offset, line in enumerate(wrapped(self.last_result, w - 8)[: max(0, h - 21)]):
                safe_add(win, 19 + offset, 5, line, 0, w - 8)

    def draw_usage(self, win) -> None:
        h, w = self.body_title(win, "USO DA API", "Totais locais são deste app; custos remotos exigem OPENAI_ADMIN_KEY.")
        usage = self.usage_store.load().as_dict()
        rows = [
            ("Requisições", usage["requests"]),
            ("Tokens de entrada", usage["input_tokens"]),
            ("Tokens de saída", usage["output_tokens"]),
            ("Tokens totais", usage["total_tokens"]),
            ("Áudio transcrito", f"{usage['transcribed_seconds']}s"),
            ("Jobs de ZIP", usage["zip_jobs"]),
            ("Atualizado", usage["updated_at"] or "nunca"),
        ]
        for index, (label, value) in enumerate(rows):
            safe_add(win, 4 + index, 4, f"{label:<22}", self.attrs["accent"])
            safe_add(win, 4 + index, 28, value, self.attrs["bold"])
        safe_add(win, 13, 3, "CUSTOS DA ORGANIZAÇÃO / 30 DIAS", self.attrs["accent"])
        if self.remote_usage:
            safe_add(win, 14, 5, f"{self.remote_usage['currency'].upper()} {self.remote_usage['total']:.6f} em {self.remote_usage['buckets']} dia(s)", self.attrs["ok"])
        elif self.settings.admin_api_key:
            safe_add(win, 14, 5, "Pressione U para consultar.", self.attrs["warn"])
        else:
            safe_add(win, 14, 5, "Admin API key não configurada; o app não finge que a project key enxerga custos.", self.attrs["muted"], w - 10)

    def draw_config(self, win) -> None:
        h, w = self.body_title(win, "BIOS / CONFIGURAÇÃO", f"Arquivo: {self.config_store.path}")
        public = self.settings.public_dict()
        for index, (name, label, _) in enumerate(CONFIG_FIELDS):
            if 4 + index >= h - 2:
                break
            attr = self.attrs["selected"] if index == self.config_index else 0
            safe_add(win, 4 + index, 3, f"{label:<34}", attr, 35)
            safe_add(win, 4 + index, 39, public[name], attr, w - 42)

    def draw_doctor(self, win) -> None:
        h, w = self.body_title(win, "DIAGNÓSTICO", "Checagens locais; não faz chamada de API.")
        checks = [
            ("Python", os.sys.version.split()[0], True),
            ("SDK openai", "instalado" if importlib.util.find_spec("openai") else "ausente: execute install.sh", bool(importlib.util.find_spec("openai"))),
            ("sounddevice", "instalado" if importlib.util.find_spec("sounddevice") else "ausente: gravação indisponível", bool(importlib.util.find_spec("sounddevice"))),
            ("Config root", str(self.paths.config_root), self.paths.config_root.exists()),
            ("Catálogos", f"{len(self.groups)} grupo(s)", bool(self.groups)),
            ("Code", self.settings.code_root, Path(os.path.expanduser(self.settings.code_root)).is_dir()),
            ("Downloads", self.settings.downloads_root, Path(os.path.expanduser(self.settings.downloads_root)).is_dir()),
        ]
        for index, (label, detail, ok) in enumerate(checks):
            safe_add(win, 4 + index * 2, 3, "OK" if ok else "ATENÇÃO", self.attrs["ok"] if ok else self.attrs["warn"])
            safe_add(win, 4 + index * 2, 14, f"{label}: {detail}", 0, w - 17)
        safe_add(win, 20, 3, "T em F2 testa a chave e o modelo configurado com a API.", self.attrs["muted"])

    def draw_help(self, win) -> None:
        h, w = self.body_title(win, "AJUDA / CONTROLES")
        lines = [
            ("F2", "configura chaves, modelos, pastas, timeout, áudio e container"),
            ("F3", "gerencia projetos e funções JSON sem editar arquivo à mão"),
            ("F4", "testa texto e devolve {matched, action, parameters, message}"),
            ("F5", "transcreve arquivo ou microfone e reaproveita o mesmo roteador"),
            ("F6", "envia o ZIP escolhido, aguarda, baixa, valida e põe em Downloads"),
            ("F7", "mostra uso local; U consulta custo organizacional com Admin key"),
            ("F9", "diagnóstico local sem consumir API"),
            ("[ ]", "troca o projeto ativo em qualquer tela"),
            ("Q", "sai; nunca encerra ou altera o Dev Manager"),
        ]
        for index, (key, description) in enumerate(lines):
            safe_add(win, 3 + index * 2, 4, f"{key:<8}", self.attrs["accent"])
            safe_add(win, 3 + index * 2, 14, description, 0, w - 18)
        safe_add(win, 22, 4, "Enter envia somente nas telas de teste/ZIP e sempre há confirmação no ZIP.", self.attrs["warn"], w - 8)

    def _prompt_line(self, title: str, initial: str = "", secret: bool = False) -> str | None:
        h, w = self.stdscr.getmaxyx()
        width = min(max(60, len(title) + 8), w - 6)
        win = curses.newwin(7, width, max(1, (h - 7) // 2), max(1, (w - width) // 2))
        self.prep_box(win, title)
        value = list(initial)
        position = len(value)
        win.keypad(True)
        win.timeout(-1)
        try:
            curses.curs_set(1)
        except curses.error:
            pass
        while True:
            display = "•" * len(value) if secret else "".join(value)
            safe_add(win, 2, 2, " " * (width - 4), self.attrs["field"], width - 4)
            start = max(0, position - (width - 6))
            safe_add(win, 2, 2, display[start:], self.attrs["field"], width - 4)
            safe_add(win, 4, 2, "Enter confirma · Esc cancela", self.attrs["muted"], width - 4)
            try:
                win.move(2, min(width - 3, 2 + position - start))
            except curses.error:
                pass
            win.refresh()
            key = win.get_wch()
            if key in ("\n", "\r"):
                result = "".join(value)
                break
            if key == "\x1b":
                result = None
                break
            if key in (curses.KEY_BACKSPACE, "\b", "\x7f") and position:
                position -= 1
                value.pop(position)
            elif key == curses.KEY_DC and position < len(value):
                value.pop(position)
            elif key == curses.KEY_LEFT:
                position = max(0, position - 1)
            elif key == curses.KEY_RIGHT:
                position = min(len(value), position + 1)
            elif isinstance(key, str) and key.isprintable() and len(value) < 4096:
                value.insert(position, key)
                position += 1
        try:
            curses.curs_set(0)
        except curses.error:
            pass
        self.stdscr.touchwin()
        return result

    def _prompt_text(self, title: str, initial: str = "") -> str | None:
        h, w = self.stdscr.getmaxyx()
        oh, ow = max(12, h - 8), max(70, w - 12)
        win = curses.newwin(oh, ow, max(1, (h - oh) // 2), max(1, (w - ow) // 2))
        self.prep_box(win, title)
        lines = initial.splitlines() or [""]
        row, col = len(lines) - 1, len(lines[-1])
        win.keypad(True)
        win.timeout(-1)
        try:
            curses.curs_set(1)
        except curses.error:
            pass
        while True:
            for y in range(2, oh - 3):
                safe_add(win, y, 2, " " * (ow - 4), self.attrs["field"], ow - 4)
                source = y - 2
                if source < len(lines):
                    safe_add(win, y, 2, lines[source], self.attrs["field"], ow - 4)
            safe_add(win, oh - 2, 2, "F10 envia · Enter nova linha · Esc cancela", self.attrs["muted"], ow - 4)
            try:
                win.move(min(oh - 4, row + 2), min(ow - 3, col + 2))
            except curses.error:
                pass
            win.refresh()
            key = win.get_wch()
            if key == getattr(curses, "KEY_F10", -1010):
                result = "\n".join(lines).strip()
                break
            if key == "\x1b":
                result = None
                break
            if key in ("\n", "\r") and len(lines) < oh - 5:
                tail = lines[row][col:]
                lines[row] = lines[row][:col]
                lines.insert(row + 1, tail)
                row, col = row + 1, 0
            elif key in (curses.KEY_BACKSPACE, "\b", "\x7f"):
                if col:
                    lines[row] = lines[row][: col - 1] + lines[row][col:]
                    col -= 1
                elif row:
                    previous = len(lines[row - 1])
                    lines[row - 1] += lines.pop(row)
                    row, col = row - 1, previous
            elif key == curses.KEY_LEFT:
                col = max(0, col - 1)
            elif key == curses.KEY_RIGHT:
                col = min(len(lines[row]), col + 1)
            elif key == curses.KEY_UP:
                row = max(0, row - 1)
                col = min(col, len(lines[row]))
            elif key == curses.KEY_DOWN:
                row = min(len(lines) - 1, row + 1)
                col = min(col, len(lines[row]))
            elif isinstance(key, str) and key.isprintable() and sum(map(len, lines)) < 20000:
                lines[row] = lines[row][:col] + key + lines[row][col:]
                col += 1
        try:
            curses.curs_set(0)
        except curses.error:
            pass
        self.stdscr.touchwin()
        return result

    def _confirm(self, question: str) -> bool:
        answer = self._prompt_line(f"CONFIRMAR · {question} · digite SIM")
        return bool(answer and answer.strip().upper() == "SIM")

    def start_job(self, label: str, function: Callable[[], dict[str, Any]]) -> None:
        if self.future:
            self.set_message("Já existe uma chamada em andamento.")
            return
        self.job_label = label
        self.future = self.executor.submit(function)

    def poll_job(self) -> None:
        if not self.future or not self.future.done():
            return
        future = self.future
        self.future = None
        try:
            result = future.result()
            kind = result.get("kind")
            if kind == "action":
                self.last_result = json.dumps(result["match"], ensure_ascii=False, indent=2)
            elif kind == "voice":
                self.last_transcript = result["transcript"]
                self.last_result = json.dumps(result["match"], ensure_ascii=False, indent=2)
            elif kind == "zip":
                self.last_result = json.dumps(result["result"], ensure_ascii=False, indent=2)
            elif kind == "usage":
                self.remote_usage = result["usage"]
            elif kind == "connection":
                self.last_result = json.dumps(result["result"], ensure_ascii=False)
            self.set_message(result.get("message", "Concluído."), 8)
        except Exception as exc:
            self.set_message(f"ERRO: {exc}", 10)

    def classify_job(self, text: str) -> dict[str, Any]:
        if not self.group:
            raise GptConsoleError("nenhum projeto selecionado")
        match = self.gateway().classify(self.group, text)
        return {"kind": "action", "match": match.as_dict(), "message": "Ação analisada; nenhuma função foi executada."}

    def voice_file_job(self, path: Path, remove_after: bool = False) -> dict[str, Any]:
        try:
            duration = wav_duration(path)
            gateway = self.gateway()
            transcript = gateway.transcribe(path, duration)
            if not self.group:
                raise GptConsoleError("nenhum projeto selecionado")
            match = gateway.classify(self.group, transcript)
            return {"kind": "voice", "transcript": transcript, "match": match.as_dict(), "message": "Áudio transcrito e ação analisada."}
        finally:
            if remove_after:
                path.unlink(missing_ok=True)

    def zip_job(self, request_text: str) -> dict[str, Any]:
        if not self.group:
            raise GptConsoleError("nenhum projeto selecionado")
        result = ZipWorkflow(self.settings, self.gateway()).run(self.group, request_text)
        return {"kind": "zip", "result": result.as_dict(), "message": f"ZIP validado e salvo: {result.destination}"}

    def change_group(self, delta: int) -> None:
        if self.groups:
            self.group_index = (self.group_index + delta) % len(self.groups)
            self.action_index = 0

    def handle_actions_key(self, key: int) -> None:
        if key == 9:
            self.actions_focus = "groups" if self.actions_focus == "actions" else "actions"
        elif key in (curses.KEY_UP, ord("k")):
            if self.actions_focus == "groups":
                self.change_group(-1)
            elif self.group and self.group.actions:
                self.action_index = (self.action_index - 1) % len(self.group.actions)
        elif key in (curses.KEY_DOWN, ord("j")):
            if self.actions_focus == "groups":
                self.change_group(1)
            elif self.group and self.group.actions:
                self.action_index = (self.action_index + 1) % len(self.group.actions)
        elif key in (ord("n"), ord("N")):
            project_id = self._prompt_line("ID do projeto (kebab-case)")
            if not project_id:
                return
            label = self._prompt_line("Nome exibido", project_id) or project_id
            zip_name = self._prompt_line("Nome do ZIP na pasta Code", f"{project_id}.zip") or f"{project_id}.zip"
            group = ActionGroup(project_id=project_id, label=label, zip_name=zip_name)
            self.catalog_store.save(group)
            self.refresh_groups()
            self.group_index = next((i for i, item in enumerate(self.groups) if item.project_id == project_id), 0)
            self.set_message(f"Grupo {label} criado.")
        elif key in (ord("g"), ord("G")) and self.group:
            label = self._prompt_line("Nome exibido", self.group.label)
            if label is None:
                return
            zip_name = self._prompt_line("Nome do ZIP na pasta Code", self.group.zip_name)
            if zip_name is None:
                return
            instructions = self._prompt_text("Contexto adicional do roteador", self.group.instructions)
            if instructions is None:
                return
            self.catalog_store.save(replace(self.group, label=label, zip_name=zip_name, instructions=instructions))
            self.refresh_groups()
            self.set_message("Grupo atualizado.")
        elif key in (ord("x"), ord("X")) and self.group:
            project_id = self.group.project_id
            if self._confirm(f"remover o grupo {project_id}"):
                self.catalog_store.delete(project_id)
                self.refresh_groups()
                self.set_message("Grupo removido.")
        elif key in (ord("a"), ord("A")) and self.group:
            self.edit_action(None)
        elif key in (ord("e"), ord("E")) and self.group and self.group.actions:
            self.edit_action(self.group.actions[self.action_index % len(self.group.actions)])
        elif key in (ord("d"), ord("D")) and self.group and self.group.actions:
            action = self.group.actions[self.action_index % len(self.group.actions)]
            if self._confirm(f"remover a ação {action.name}"):
                self.catalog_store.remove_action(self.group.project_id, action.name)
                self.refresh_groups()
                self.set_message("Ação removida.")

    def edit_action(self, current: ActionDefinition | None) -> None:
        name = self._prompt_line("Nome da ação em inglês / snake_case", current.name if current else "")
        if not name:
            return
        description = self._prompt_text("Descrição objetiva da ação", current.description if current else "")
        if not description:
            return
        initial = ""
        if current:
            initial = ", ".join(f"{item.name}:{item.type}{'*' if item.required else ''}" for item in current.parameters)
        spec = self._prompt_line("Parâmetros: nome:tipo* obrigatórios, separados por vírgula", initial)
        if spec is None:
            return
        parameters: list[ParameterDefinition] = []
        for raw in (item.strip() for item in spec.split(",")):
            if not raw:
                continue
            required = raw.endswith("*")
            raw = raw[:-1] if required else raw
            parts = [item.strip() for item in raw.split(":", 1)]
            param_name = parts[0]
            param_type = parts[1] if len(parts) > 1 else "string"
            parameters.append(ParameterDefinition(name=param_name, type=param_type, required=required))
        action = ActionDefinition(name=name, description=description, parameters=tuple(parameters))
        action.validate()
        self.catalog_store.upsert_action(self.group.project_id, action, current.name if current else "")  # type: ignore[union-attr]
        self.refresh_groups()
        self.set_message(f"Ação {name} salva.")

    def handle_config_key(self, key: int) -> None:
        if key in (curses.KEY_UP, ord("k")):
            self.config_index = (self.config_index - 1) % len(CONFIG_FIELDS)
        elif key in (curses.KEY_DOWN, ord("j")):
            self.config_index = (self.config_index + 1) % len(CONFIG_FIELDS)
        elif key in (10, 13, curses.KEY_ENTER):
            name, label, secret = CONFIG_FIELDS[self.config_index]
            current = "" if secret else str(getattr(self.settings, name))
            value = self._prompt_line(label, current, secret=secret)
            if value is None or (secret and not value):
                return
            try:
                self.settings = self.config_store.update(self.settings, **{name: value})
                self.set_message(f"{label} salvo.")
            except Exception as exc:
                self.set_message(f"ERRO: {exc}", 8)
        elif key == curses.KEY_DC:
            name, label, secret = CONFIG_FIELDS[self.config_index]
            if secret and self._confirm(f"limpar {label}"):
                self.settings = self.config_store.update(self.settings, **{name: ""})
                self.set_message(f"{label} removido.")
        elif key in (ord("s"), ord("S")):
            self.config_store.save(self.settings)
            self.set_message(f"Configuração salva em {self.config_store.path}.")
        elif key in (ord("t"), ord("T")):
            self.start_job("Testando chave e modelo...", lambda: {"kind": "connection", "result": self.gateway().test_connection(), "message": "Conexão com a API confirmada."})

    def handle_key(self, key: int) -> None:
        if self.future:
            if key in (ord("q"), ord("Q"), 3):
                self.set_message("Há uma chamada em andamento; aguarde a conclusão ou o timeout configurado.", 8)
            return
        shortcuts = {
            getattr(curses, "KEY_F1", -1001): "help",
            getattr(curses, "KEY_F2", -1002): "config",
            getattr(curses, "KEY_F3", -1003): "actions",
            getattr(curses, "KEY_F4", -1004): "text",
            getattr(curses, "KEY_F5", -1005): "voice",
            getattr(curses, "KEY_F6", -1006): "zip",
            getattr(curses, "KEY_F7", -1007): "usage",
            getattr(curses, "KEY_F8", -1008): "dashboard",
            getattr(curses, "KEY_F9", -1009): "doctor",
        }
        if key in shortcuts:
            self.screen = shortcuts[key]
            self.menu_index = next(i for i, item in enumerate(SCREENS) if item[0] == self.screen)
            self.menu_focused = False
            return
        if key in (ord("q"), ord("Q"), 3):
            self.running = False
        elif key == ord("["):
            self.change_group(-1)
        elif key == ord("]"):
            self.change_group(1)
        elif key == 27:
            self.menu_focused = True
            self.menu_index = next(i for i, item in enumerate(SCREENS) if item[0] == self.screen)
        elif self.menu_focused and key in (curses.KEY_UP, ord("k")):
            self.menu_index = (self.menu_index - 1) % len(SCREENS)
        elif self.menu_focused and key in (curses.KEY_DOWN, ord("j")):
            self.menu_index = (self.menu_index + 1) % len(SCREENS)
        elif self.menu_focused and key in (10, 13, curses.KEY_ENTER):
            self.screen = SCREENS[self.menu_index][0]
            self.menu_focused = False
        elif self.menu_focused:
            return
        elif self.screen == "actions":
            self.handle_actions_key(key)
        elif self.screen == "config":
            self.handle_config_key(key)
        elif self.screen == "text" and key in (10, 13, curses.KEY_ENTER):
            value = self._prompt_text("COMANDO DO CLIENTE · F10 envia")
            if value:
                self.start_job("Identificando ação pela API...", lambda value=value: self.classify_job(value))
        elif self.screen == "voice" and key in (ord("a"), ord("A")):
            value = self._prompt_line("Caminho do arquivo de áudio")
            if value:
                path = validate_audio(Path(value))
                self.start_job("Transcrevendo áudio e identificando ação...", lambda path=path: self.voice_file_job(path))
        elif self.screen == "voice" and key in (ord("r"), ord("R")):
            seconds = self.settings.recording_seconds

            def record_job():
                path = record_microphone(seconds)
                return self.voice_file_job(path, remove_after=True)

            self.start_job(f"Gravando {seconds}s, transcrevendo e identificando ação...", record_job)
        elif self.screen == "zip" and key in (10, 13, curses.KEY_ENTER):
            demand = self._prompt_text("DEMANDA DO PROJETO · F10 continua")
            if demand and self._confirm("enviar o ZIP e consumir a API"):
                self.start_job("Enviando, editando e validando ZIP; isso pode demorar...", lambda demand=demand: self.zip_job(demand))
        elif self.screen == "usage" and key in (ord("u"), ord("U")):
            self.start_job("Consultando custos da organização...", lambda: {"kind": "usage", "usage": fetch_organization_costs(self.settings), "message": "Custos remotos atualizados."})

    def run(self) -> None:
        try:
            while self.running:
                self.poll_job()
                self.draw()
                key = self.stdscr.getch()
                if key != -1:
                    try:
                        self.handle_key(key)
                    except GptConsoleError as exc:
                        self.set_message(f"ERRO: {exc}", 8)
                    except Exception as exc:
                        self.set_message(f"ERRO INESPERADO: {exc}", 10)
        finally:
            self.executor.shutdown(wait=False, cancel_futures=True)


def run_tui() -> None:
    curses.wrapper(lambda stdscr: GptConsoleTui(stdscr).run())
