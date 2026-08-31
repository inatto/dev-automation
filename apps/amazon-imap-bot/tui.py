from __future__ import annotations

import curses
import json
import queue
import textwrap
import threading
import time

from config import Settings
from api_runner import ApiTestRunner
from monitor import Monitor
from store import Store


TAB_INBOX = 0
TAB_REPLIES = 1
TAB_CONSOLE = 2
TAB_ACCOUNTS = 3
TAB_API = 4
TAB_FUNCTIONS = 5
TAB_NAMES = ("ENTRADA", "RESPOSTAS", "CONSOLE", "CONTAS", "API", "FUNÇÕES")

STATUS_LABELS = {
    "received": "RECEBIDO",
    "analyzing": "ANALISANDO",
    "understood": "ENTENDIDO",
    "awaiting-confirmation": "AGUARDANDO CONF.",
    "confirmed": "CONFIRMADO",
    "sending": "ENVIANDO",
    "executing": "EXECUTANDO",
    "completed": "CONCLUÍDO",
    "replied": "RESPONDIDO",
    "reply-error": "ERRO RESPOSTA",
    "function-error": "ERRO FUNÇÃO",
    "sent": "ENVIADO",
    "error": "ERRO",
}
PROCESSING_STATUSES = {"analyzing", "understood", "sending", "executing"}


def _status_label(status: str) -> str:
    value = (status or "").strip().lower()
    if value.startswith("ignored:") or value == "ignored":
        return "IGNORADO"
    return STATUS_LABELS.get(value, (status or "-").upper())


class Palette:
    NORMAL = 0
    HEADER = 0
    BORDER = 0
    SELECTED = 0
    OK = 0
    WARN = 0
    ERROR = 0
    DIM = 0
    TAB = 0
    TAB_ACTIVE = 0


def _init_colors() -> Palette:
    p = Palette()
    if not curses.has_colors():
        return p
    curses.start_color()
    background = curses.COLOR_BLACK
    try:
        curses.use_default_colors()
        background = -1
    except curses.error:
        pass
    curses.init_pair(1, curses.COLOR_WHITE, curses.COLOR_BLUE)
    curses.init_pair(2, curses.COLOR_CYAN, background)
    curses.init_pair(3, curses.COLOR_BLACK, curses.COLOR_CYAN)
    curses.init_pair(4, curses.COLOR_GREEN, background)
    curses.init_pair(5, curses.COLOR_YELLOW, background)
    curses.init_pair(6, curses.COLOR_RED, background)
    curses.init_pair(7, curses.COLOR_BLUE, background)
    curses.init_pair(8, curses.COLOR_BLACK, curses.COLOR_WHITE)
    curses.init_pair(9, curses.COLOR_WHITE, curses.COLOR_BLUE)
    p.HEADER = curses.color_pair(1) | curses.A_BOLD
    p.BORDER = curses.color_pair(2)
    p.SELECTED = curses.color_pair(3) | curses.A_BOLD
    p.OK = curses.color_pair(4) | curses.A_BOLD
    p.WARN = curses.color_pair(5) | curses.A_BOLD
    p.ERROR = curses.color_pair(6) | curses.A_BOLD
    p.DIM = curses.color_pair(7)
    p.TAB = curses.color_pair(8)
    p.TAB_ACTIVE = curses.color_pair(9) | curses.A_BOLD
    return p


def _safe_add(win, y: int, x: int, text: object, width: int | None = None, attr: int = 0) -> None:
    try:
        value = str(text or "")
        if width is None:
            win.addstr(y, x, value, attr)
        else:
            win.addnstr(y, x, value, max(0, width), attr)
    except curses.error:
        pass


def _status_attr(status: str, p: Palette) -> int:
    value = (status or "").lower()
    if "error" in value or "erro" in value:
        return p.ERROR
    if value in {"awaiting-confirmation", "received"} or "ignored" in value or "warn" in value or "ignorado" in value:
        return p.WARN
    if value in {"sent", "replied", "completed", "confirmed", "online"} or "ok" in value:
        return p.OK
    if value in PROCESSING_STATUSES:
        return p.BORDER | curses.A_BOLD
    return 0


def _format_date(value: str) -> str:
    value = str(value or "")
    if len(value) >= 16 and value[4:5] == "-" and value[7:8] == "-":
        return f"{value[8:10]}/{value[5:7]} {value[11:16]}"
    return value[:16]


def _draw_box(stdscr, top: int, left: int, height: int, width: int, title: str, p: Palette):
    height = max(3, height)
    width = max(4, width)
    win = stdscr.derwin(height, width, top, left)
    try:
        win.attron(p.BORDER)
        win.border()
        win.attroff(p.BORDER)
    except curses.error:
        pass
    if title:
        _safe_add(win, 0, 2, f" {title} ", max(0, width - 4), p.BORDER | curses.A_BOLD)
    return win


def _message_lines(row: dict, width: int) -> list[str]:
    direction = row.get("direction", "")
    lines = [
        f"Direção: {'ENTRADA' if direction == 'in' else 'RESPOSTA'}",
        f"Data: {row.get('mail_date') or row.get('created_at') or '-'}",
        f"Conta: {row.get('account_email') or '-'}",
        f"De: {row.get('sender') or '-'}",
        f"Para: {row.get('recipient') or '-'}",
        f"Assunto: {row.get('subject') or '(sem assunto)'}",
        f"Status: {_status_label(row.get('status') or '-')}",
        f"Message-ID: {row.get('message_id') or '-'}",
    ]
    if row.get("imap_uid"):
        lines.append(f"IMAP: {row.get('imap_folder') or 'INBOX'} / UID {row.get('imap_uid')}")
    if row.get("reply_to_message_id"):
        lines.append(f"In-Reply-To: {row.get('reply_to_message_id')}")
    if row.get("provider_message_id"):
        lines.append(f"SES MessageId: {row.get('provider_message_id')}")
    if row.get("error"):
        lines.extend(["", f"ERRO: {row.get('error')}"])
    lines.extend(["", "CONTEÚDO", "--------"])
    body = row.get("body") or "(sem corpo textual)"
    wrap_width = max(20, width - 4)
    for paragraph in str(body).splitlines() or [""]:
        if not paragraph:
            lines.append("")
        else:
            lines.extend(textwrap.wrap(paragraph, width=wrap_width, replace_whitespace=False) or [""])
    return lines


def _popup_message(stdscr, row: dict, p: Palette) -> None:
    h, w = stdscr.getmaxyx()
    ph = max(8, min(h - 2, 32))
    pw = max(30, min(w - 4, 120))
    top = max(0, (h - ph) // 2)
    left = max(0, (w - pw) // 2)
    win = curses.newwin(ph, pw, top, left)
    win.keypad(True)
    try:
        win.attron(p.BORDER)
        win.border()
        win.attroff(p.BORDER)
    except curses.error:
        pass
    _safe_add(win, 0, 2, " DETALHE DO E-MAIL ", pw - 4, p.HEADER)
    _safe_add(win, ph - 1, 2, " ↑↓ rolar · PgUp/PgDn · Esc/Enter fechar ", pw - 4, p.DIM)
    lines = _message_lines(row, pw - 2)
    offset = 0
    page = max(1, ph - 4)
    while True:
        for y in range(1, ph - 1):
            try:
                win.move(y, 1)
                win.clrtoeol()
            except curses.error:
                pass
        for i, line in enumerate(lines[offset:offset + page]):
            _safe_add(win, 1 + i, 2, line, pw - 4)
        win.refresh()
        ch = win.getch()
        if ch in (27, 10, 13, curses.KEY_ENTER, ord("q"), ord("Q")):
            break
        if ch == curses.KEY_UP:
            offset = max(0, offset - 1)
        elif ch == curses.KEY_DOWN:
            offset = min(max(0, len(lines) - page), offset + 1)
        elif ch == curses.KEY_PPAGE:
            offset = max(0, offset - page)
        elif ch == curses.KEY_NPAGE:
            offset = min(max(0, len(lines) - page), offset + page)
    stdscr.touchwin()
    stdscr.refresh()


def _popup_notice(stdscr, title: str, lines: list[str], p: Palette, attr: int = 0) -> None:
    h, w = stdscr.getmaxyx()
    content_width = max([len(title)] + [len(line) for line in lines] + [30])
    pw = min(max(52, content_width + 8), max(30, w - 4))
    ph = min(max(8, len(lines) + 5), max(8, h - 2))
    top = max(0, (h - ph) // 2)
    left = max(0, (w - pw) // 2)
    win = curses.newwin(ph, pw, top, left)
    win.keypad(True)
    try:
        win.attron(p.BORDER)
        win.border()
        win.attroff(p.BORDER)
    except curses.error:
        pass
    _safe_add(win, 0, 2, f" {title} ", pw - 4, attr or p.HEADER)
    for idx, line in enumerate(lines[: ph - 4]):
        _safe_add(win, 2 + idx, 3, line, pw - 6, attr if idx == 0 else 0)
    _safe_add(win, ph - 2, 3, "Enter/Esc fechar", pw - 6, p.DIM)
    win.refresh()
    while True:
        ch = win.getch()
        if ch in (27, 10, 13, curses.KEY_ENTER, ord("q"), ord("Q")):
            break
    stdscr.touchwin()
    stdscr.refresh()


def _delete_confirmation_text(row: dict) -> tuple[str, list[str], str]:
    status = (row.get("status") or "").lower()
    subject = str(row.get("subject") or "(sem assunto)")
    sender = str(row.get("sender") or "-")
    if status == "replied":
        return (
            "REMOVER E-MAIL RESPONDIDO",
            [
                "E-MAIL RESPONDIDO.",
                "A resposta já foi enviada ao remetente.",
                f"De: {sender}",
                f"Assunto: {subject}",
                "A mensagem será movida para a lixeira do IMAP.",
                "Confirma a remoção?",
            ],
            "ok",
        )
    if status == "reply-error":
        headline = "ATENÇÃO: A RESPOSTA FALHOU."
        detail = "Este e-mail NÃO foi respondido com sucesso."
        level = "error"
    elif status.startswith("ignored:") or status == "ignored":
        headline = "ATENÇÃO: E-MAIL IGNORADO."
        detail = "Este e-mail não recebeu resposta automática."
        level = "warn"
    elif status == "awaiting-confirmation":
        headline = "ATENÇÃO: AGUARDANDO CONFIRMAÇÃO."
        detail = "Este e-mail ainda NÃO foi respondido."
        level = "warn"
    else:
        headline = "ATENÇÃO: E-MAIL NÃO RESPONDIDO."
        detail = "Remover agora elimina a mensagem da caixa de entrada sem resposta."
        level = "error"
    return (
        "CONFIRMAR REMOÇÃO",
        [
            headline,
            detail,
            f"De: {sender}",
            f"Assunto: {subject}",
            f"Estado atual: {_status_label(status)}",
            "A mensagem será movida para a lixeira do IMAP.",
            "Confirma mesmo assim?",
        ],
        level,
    )


def _popup_confirm_delete(stdscr, row: dict, p: Palette) -> bool:
    title, lines, level = _delete_confirmation_text(row)
    attr = p.OK if level == "ok" else (p.ERROR if level == "error" else p.WARN)
    h, w = stdscr.getmaxyx()
    content_width = max([len(title)] + [len(line) for line in lines] + [42])
    pw = min(max(62, content_width + 8), max(34, w - 4))
    ph = min(max(12, len(lines) + 6), max(10, h - 2))
    top = max(0, (h - ph) // 2)
    left = max(0, (w - pw) // 2)
    win = curses.newwin(ph, pw, top, left)
    win.keypad(True)
    try:
        win.attron(attr)
        win.border()
        win.attroff(attr)
    except curses.error:
        pass
    _safe_add(win, 0, 2, f" {title} ", pw - 4, attr | curses.A_BOLD)
    for idx, line in enumerate(lines[: ph - 5]):
        line_attr = attr if idx == 0 else 0
        _safe_add(win, 2 + idx, 3, line, pw - 6, line_attr)
    _safe_add(win, ph - 2, 3, "S ou Enter = REMOVER   N ou Esc = CANCELAR", pw - 6, p.DIM)
    win.refresh()
    while True:
        ch = win.getch()
        if ch in (ord("s"), ord("S"), ord("y"), ord("Y"), 10, 13, curses.KEY_ENTER):
            return True
        if ch in (ord("n"), ord("N"), 27, ord("q"), ord("Q")):
            return False




def _wrap_labeled(lines: list[str], prefix: str, value: object, width: int) -> None:
    text = str(value if value not in (None, "") else "-")
    usable = max(20, width - len(prefix))
    chunks = textwrap.wrap(text, width=usable, replace_whitespace=False) or [""]
    lines.append(prefix + chunks[0])
    continuation = ("│ " + " " * max(0, len(prefix) - 2)) if prefix.startswith("│") else (" " * len(prefix))
    lines.extend(continuation + chunk for chunk in chunks[1:])


def _function_view_lines(path, width: int) -> list[str]:
    """Representa functions.json como uma visão humana; lê o arquivo atual a cada renderização."""
    width = max(48, width)
    try:
        raw = path.read_text(encoding="utf-8")
    except FileNotFoundError:
        return [
            "CONFIGURAÇÃO DE FUNÇÕES",
            f"Arquivo: {path}",
            "ERRO: functions.json não encontrado.",
        ]
    except OSError as exc:
        return ["CONFIGURAÇÃO DE FUNÇÕES", f"Arquivo: {path}", f"ERRO: {exc}"]
    try:
        payload = json.loads(raw)
    except json.JSONDecodeError as exc:
        return [
            "CONFIGURAÇÃO DE FUNÇÕES",
            f"Arquivo: {path}",
            f"ERRO: JSON inválido na linha {exc.lineno}, coluna {exc.colno}: {exc.msg}",
        ]
    if not isinstance(payload, dict):
        return ["CONFIGURAÇÃO DE FUNÇÕES", f"Arquivo: {path}", "ERRO: raiz do JSON precisa ser um objeto."]

    functions = payload.get("functions") if isinstance(payload.get("functions"), dict) else {}
    senders = payload.get("senders") if isinstance(payload.get("senders"), dict) else {}
    levels = payload.get("reasoning_levels") if isinstance(payload.get("reasoning_levels"), dict) else {}
    lines: list[str] = [
        "CONFIGURAÇÃO DE FUNÇÕES",
        f"Arquivo: {path}",
        f"Versão: {payload.get('version', '-')}   Funções: {len(functions)}   Remetentes configurados: {len(senders)}",
        "",
        "NÍVEIS DE RACIOCÍNIO",
    ]
    if levels:
        ordered = []
        for key, value in sorted(levels.items(), key=lambda item: int(item[0]) if str(item[0]).isdigit() else 999):
            ordered.append(f"{key}={value}")
        _wrap_labeled(lines, "  ", "   ".join(ordered), width)
    else:
        lines.append("  Nenhum nível declarado no arquivo.")

    lines.extend(["", "FUNÇÕES DISPONÍVEIS"])
    if not functions:
        lines.append("  Nenhuma função configurada.")
    for name, raw_entry in functions.items():
        entry = raw_entry if isinstance(raw_entry, dict) else {}
        enabled = bool(entry.get("enabled", True))
        state = "ATIVA" if enabled else "DESATIVADA"
        border = max(20, min(width - 2, 100))
        lines.append("┌" + "─" * (border - 2) + "┐")
        lines.append(f"│ FUNÇÃO: {name}   [{state}]")
        _wrap_labeled(lines, "│ Descrição: ", entry.get("description") or "-", width - 2)
        default_level = entry.get("default_reasoning_level", "-")
        default_name = str(levels.get(str(default_level), "")) if default_level != "-" else ""
        default_text = f"{default_level}" + (f" ({default_name})" if default_name else "")
        lines.append(f"│ Nível padrão: {default_text}")
        allowed = entry.get("allowed_reasoning_levels")
        if isinstance(allowed, list):
            allowed_text = ", ".join(
                f"{item}={levels.get(str(item), '?')}" for item in allowed
            ) or "-"
        else:
            allowed_text = "todos os níveis válidos"
        _wrap_labeled(lines, "│ Níveis permitidos: ", allowed_text, width - 2)
        params = entry.get("parameters") if isinstance(entry.get("parameters"), dict) else {}
        props = params.get("properties") if isinstance(params.get("properties"), dict) else {}
        required = set(params.get("required") if isinstance(params.get("required"), list) else [])
        lines.append("│ Parâmetros:")
        if not props:
            lines.append("│   (nenhum)")
        for param_name, raw_param in props.items():
            param = raw_param if isinstance(raw_param, dict) else {}
            req = "OBRIGATÓRIO" if param_name in required else "opcional"
            type_name = param.get("type") or "-"
            enum = param.get("enum")
            head = f"│   • {param_name}  [{type_name} | {req}]"
            lines.append(head)
            if isinstance(enum, list):
                _wrap_labeled(lines, "│     Valores: ", ", ".join(map(str, enum)), width - 2)
            if param.get("description"):
                _wrap_labeled(lines, "│     Descrição: ", param.get("description"), width - 2)
        lines.append("└" + "─" * (border - 2) + "┘")
        lines.append("")

    lines.append("AUTORIZAÇÕES POR REMETENTE")
    if not senders:
        lines.append("  Nenhum remetente configurado.")
    for sender, raw_entry in senders.items():
        entry = raw_entry if isinstance(raw_entry, dict) else {}
        enabled = bool(entry.get("enabled", True))
        state = "ATIVO" if enabled else "DESATIVADO"
        lines.append(f"┌ REMETENTE: {sender}   [{state}]")
        fn_names = entry.get("functions") if isinstance(entry.get("functions"), list) else []
        if fn_names:
            for fn_name in fn_names:
                fn = functions.get(str(fn_name), {}) if isinstance(functions, dict) else {}
                fn_enabled = bool(fn.get("enabled", True)) if isinstance(fn, dict) else False
                lines.append(f"│   • {fn_name}   [{'PERMITIDA' if fn_enabled else 'FUNÇÃO DESATIVADA'}]")
        else:
            lines.append("│   (nenhuma função permitida)")
        lines.append("└")
        lines.append("")
    return lines


def _function_line_attr(line: str, p: Palette) -> int:
    upper = line.upper()
    if "ERRO:" in upper or "DESATIVAD" in upper or "FUNÇÃO DESATIVADA" in upper:
        return p.ERROR
    if "[ATIVA]" in upper or "[ATIVO]" in upper or "[PERMITIDA]" in upper:
        return p.OK
    if line.startswith("CONFIGURAÇÃO") or line in {"FUNÇÕES DISPONÍVEIS", "AUTORIZAÇÕES POR REMETENTE", "NÍVEIS DE RACIOCÍNIO"}:
        return p.BORDER | curses.A_BOLD
    if line.startswith("┌") or line.startswith("└"):
        return p.BORDER
    return 0


def _api_kind_label(kind: str) -> str:
    labels = {
        "zip-test": "ZIP TESTE",
        "function-router": "ROUTER",
        "email-reply": "E-MAIL",
        "project-zip-select": "ESCOLHE ZIP",
        "project-zip-edit": "PROJETO",
    }
    return labels.get(str(kind or ""), str(kind or "API").upper())


def _byte_detail(value) -> str:
    if value is None:
        return "-"
    try:
        n = int(value)
    except (TypeError, ValueError):
        return str(value)
    if n < 1024:
        return f"{n} bytes"
    if n < 1024 * 1024:
        return f"{n} bytes ({n / 1024:.2f} KiB)"
    return f"{n} bytes ({n / (1024 * 1024):.2f} MiB)"

def _api_status_label(status: str) -> str:
    labels = {
        "preparando": "PREPARANDO",
        "enviando": "ENVIANDO ZIP",
        "aguardando-resposta": "AGUARDANDO",
        "baixando": "BAIXANDO",
        "concluido": "CONCLUÍDO",
        "erro": "ERRO",
    }
    return labels.get((status or "").lower(), (status or "-").upper())


def _popup_api_run(stdscr, row: dict, p: Palette) -> None:
    h, w = stdscr.getmaxyx()
    ph = max(12, min(h - 2, 28))
    pw = max(60, min(w - 4, 124))
    top = max(0, (h - ph) // 2)
    left = max(0, (w - pw) // 2)
    win = curses.newwin(ph, pw, top, left)
    win.keypad(True)
    try:
        win.attron(p.BORDER)
        win.border()
        win.attroff(p.BORDER)
    except curses.error:
        pass

    kind = str(row.get("kind") or "")
    elapsed = row.get("elapsed_ms")
    elapsed_text = f"{int(elapsed)/1000:.2f}s" if elapsed is not None else "em andamento"
    input_path = str(row.get("input_path") or "")
    output_path = str(row.get("output_path") or "")
    request_payload = str(row.get("request_payload") or "")
    response_summary = str(row.get("response_summary") or "")

    if kind == "project-zip-select":
        input_path_label = "Raiz consultada"
        attachment_line = "Anexos enviados: 0 — somente lista textual de nomes/caminhos de ZIP"
        listed_label = "ZIPs listados"
    elif kind in {"project-zip-edit", "zip-test"}:
        input_path_label = "ZIP de entrada"
        attachment_line = "Anexos enviados: 1 ZIP"
        listed_label = "Anexos"
    elif kind == "function-router":
        input_path_label = "Arquivo de entrada"
        attachment_line = "Anexos enviados: 0"
        listed_label = "Funções listadas"
    else:
        input_path_label = "Arquivo de entrada"
        attachment_line = "Anexos enviados: 0"
        listed_label = "Itens listados"

    lines: list[str] = [
        f"ID: #{row.get('id')}",
        f"Tipo: {_api_kind_label(kind)}",
        f"Estado: {_api_status_label(row.get('status') or '')}",
        f"Modelo: {row.get('model') or '-'}",
        f"Raciocínio: {row.get('reasoning_effort') or '-'}",
        f"Início: {row.get('started_at') or '-'}",
        f"Fim: {row.get('finished_at') or '-'}",
        f"Tempo: {elapsed_text}",
        f"Response ID: {row.get('response_id') or '-'}",
        "",
        "=== ENVIO PARA API ===",
        f"Texto/contexto enviado: {_byte_detail(row.get('request_bytes'))}",
        attachment_line,
        f"{listed_label}: {row.get('listed_item_count') if row.get('listed_item_count') is not None else '-'}",
        f"{input_path_label}: {input_path or '-'}",
        f"Bytes do ZIP/arquivo de entrada: {_byte_detail(row.get('input_file_bytes'))}",
        f"Arquivos internos no ZIP de entrada: {row.get('input_file_count') if row.get('input_file_count') is not None else '-'}",
        "",
        "=== RETORNO DA API ===",
        f"Texto recebido: {_byte_detail(row.get('response_bytes'))}",
        f"ZIP/arquivo de retorno: {output_path or '-'}",
        f"Bytes do ZIP/arquivo de retorno: {_byte_detail(row.get('output_file_bytes'))}",
        f"Arquivos internos no ZIP de retorno: {row.get('output_file_count') if row.get('output_file_count') is not None else '-'}",
        "",
        f"Pedido resumido: {row.get('request_summary') or '-'}",
        f"Resposta resumida: {response_summary or '-'}",
    ]
    if row.get("error"):
        lines.extend(["", f"ERRO: {row.get('error')}"])

    lines.extend(["", "=== CONTEÚDO ENVIADO À API ==="] )
    if request_payload:
        lines.extend(request_payload.splitlines() or [request_payload])
    else:
        lines.append("(registro antigo: conteúdo detalhado não foi gravado)")

    wrapped: list[str] = []
    width = max(20, pw - 8)
    for line in lines:
        if line == "":
            wrapped.append("")
            continue
        wrapped.extend(textwrap.wrap(str(line), width, replace_whitespace=False, drop_whitespace=False) or [""])

    _safe_add(win, 0, 2, " CHAMADA API — DETALHES ", pw - 4, p.HEADER)
    offset = 0
    page = max(1, ph - 4)
    while True:
        for y in range(1, ph - 2):
            _safe_add(win, y, 2, " " * max(0, pw - 4), pw - 4)
        for i, line in enumerate(wrapped[offset:offset + page]):
            upper = line.upper()
            if line.startswith("ERRO:"):
                attr = p.ERROR
            elif upper.startswith("=== ENVIO") or upper.startswith("=== RETORNO") or upper.startswith("=== CONTEÚDO"):
                attr = p.BORDER | curses.A_BOLD
            elif "ANEXOS ENVIADOS: 0" in upper and kind == "project-zip-select":
                attr = p.OK
            else:
                attr = 0
            _safe_add(win, 1 + i, 3, line, pw - 6, attr)
        _safe_add(win, ph - 2, 3, "↑↓/PgUp/PgDn rolar   Enter/Esc fechar", pw - 6, p.DIM)
        win.refresh()
        ch = win.getch()
        if ch in (27, 10, 13, curses.KEY_ENTER, ord('q'), ord('Q')):
            break
        if ch == curses.KEY_UP:
            offset = max(0, offset - 1)
        elif ch == curses.KEY_DOWN:
            offset = min(max(0, len(wrapped) - page), offset + 1)
        elif ch == curses.KEY_PPAGE:
            offset = max(0, offset - page)
        elif ch == curses.KEY_NPAGE:
            offset = min(max(0, len(wrapped) - page), offset + page)
    stdscr.touchwin()
    stdscr.refresh()

def run(settings: Settings) -> int:
    store = Store(settings.database_path)
    events: queue.Queue[str] = queue.Queue()
    monitor = Monitor(settings, store, events.put)
    api_runner = ApiTestRunner(settings, store, events.put)
    thread = threading.Thread(target=monitor.run_forever, daemon=True)
    thread.start()

    def draw(stdscr):
        try:
            curses.curs_set(0)
        except curses.error:
            pass
        stdscr.nodelay(True)
        stdscr.keypad(True)
        p = _init_colors()
        active_tab = TAB_INBOX
        menu_focus = True
        selected = {idx: 0 for idx in range(len(TAB_NAMES))}
        offsets = {idx: 0 for idx in range(len(TAB_NAMES))}
        checking = False
        api_testing = False
        notice = ""
        notice_attr = 0
        notice_until = 0.0

        while not monitor.stop_event.is_set():
            while True:
                try:
                    events.get_nowait()
                except queue.Empty:
                    break

            stdscr.erase()
            h, w = stdscr.getmaxyx()
            if h < 16 or w < 78:
                _safe_add(stdscr, 0, 0, "Amazon IMAP Bot", w - 1, p.HEADER)
                _safe_add(stdscr, 2, 0, "Terminal pequeno demais. Mínimo recomendado: 78x16.", w - 1, p.ERROR)
                _safe_add(stdscr, h - 1, 0, "Q sair", w - 1, p.DIM)
                stdscr.refresh()
                ch = stdscr.getch()
                if ch in (ord("q"), ord("Q")):
                    monitor.stop()
                    break
                time.sleep(0.15)
                continue

            online = sum(1 for state in monitor.states.values() if state.connected)
            errors = sum(1 for state in monitor.states.values() if state.last_error)
            received = sum(state.received for state in monitor.states.values())
            replied = sum(state.replied for state in monitor.states.values())

            try:
                stdscr.attron(p.HEADER)
                stdscr.addnstr(0, 0, " " * (w - 1), w - 1)
                stdscr.addnstr(0, 1, "AMAZON IMAP BOT :: CENTRAL DE MONITORAMENTO", w - 3)
                stdscr.attroff(p.HEADER)
            except curses.error:
                pass
            _safe_add(
                stdscr, 1, 1,
                f"IMAP {settings.imap_host}:{settings.imap_port}  |  SES {settings.aws_region}/{settings.aws_profile}  |  GPT {settings.openai_model}",
                w - 2, p.DIM,
            )
            _safe_add(
                stdscr, 2, 1,
                f"Caixas online {online}/{len(monitor.states)}  Erros {errors}  Recebidos {received}  Respondidos {replied}  "
                f"Auto-resposta {'ON' if settings.auto_reply_enabled else 'OFF'}  Poll {settings.poll_seconds}s",
                w - 2,
                p.OK if errors == 0 else p.WARN,
            )

            x = 1
            for idx, name in enumerate(TAB_NAMES):
                label = f" {name} "
                attr = p.TAB_ACTIVE if idx == active_tab else p.TAB
                _safe_add(stdscr, 4, x, label, len(label), attr)
                x += len(label) + 1
            if menu_focus:
                _safe_add(stdscr, 4, min(w - 18, x + 1), "←/→  ↓ entrar", 16, p.DIM)

            box_top = 5
            box_height = h - 8
            box = _draw_box(stdscr, box_top, 0, box_height, w, TAB_NAMES[active_tab], p)
            usable = max(1, box_height - 3)

            rows: list[dict] = []
            function_lines: list[str] = []
            if active_tab == TAB_INBOX:
                rows = store.list_messages("in", 500)
                _safe_add(box, 1, 2, "DATA        REMETENTE                         ASSUNTO                                  STATUS", w - 4, p.DIM)
            elif active_tab == TAB_REPLIES:
                rows = store.list_messages("out", 500)
                _safe_add(box, 1, 2, "DATA        DESTINATÁRIO                      ASSUNTO                                  STATUS", w - 4, p.DIM)
            elif active_tab == TAB_CONSOLE:
                rows = store.recent_events(500)
                _safe_add(box, 1, 2, "DATA        TIPO     NÍVEL   EVENTO", w - 4, p.DIM)
            elif active_tab == TAB_ACCOUNTS:
                rows = [
                    {
                        "email": email,
                        "connected": state.connected,
                        "last_error": state.last_error,
                        "received": state.received,
                        "replied": state.replied,
                        "last_check": state.last_check,
                    }
                    for email, state in monitor.states.items()
                ]
                _safe_add(box, 1, 2, "STATUS     CONTA                                      REC   RESP   ÚLTIMA VERIFICAÇÃO", w - 4, p.DIM)
            elif active_tab == TAB_API:
                rows = store.list_api_runs(200)
                cfg1 = f"Modelo={settings.openai_model}  Raciocínio={settings.openai_reasoning_effort}  Timeout={settings.openai_timeout_seconds}s  Chave={'CONFIGURADA' if settings.openai_api_key else 'AUSENTE'}"
                cfg2 = f"Base URL={settings.openai_base_url}"
                cfg3 = f"Saída={settings.openai_output_dir}  ZIP teste={settings.openai_test_zip}  Projetos ZIP={settings.project_zip_search_root}  Funções={settings.functions_config}"
                _safe_add(box, 1, 2, cfg1, w - 4, p.BORDER | curses.A_BOLD)
                _safe_add(box, 2, 2, cfg2, w - 4, p.DIM)
                _safe_add(box, 3, 2, cfg3, w - 4, p.DIM)
                _safe_add(box, 4, 2, "ID    TIPO    INÍCIO      ESTADO         MODELO             NÍVEL   TEMPO     RESULTADO", w - 4, p.DIM)
            else:
                function_lines = _function_view_lines(settings.functions_config, w - 6)

            if active_tab == TAB_FUNCTIONS:
                page = max(1, usable - 1)
                off = offsets[TAB_FUNCTIONS]
                off = max(0, min(off, max(0, len(function_lines) - page)))
                offsets[TAB_FUNCTIONS] = off
                for pos, line in enumerate(function_lines[off:off + page]):
                    _safe_add(box, 1 + pos, 2, line, w - 4, _function_line_attr(line, p))
                if len(function_lines) > page:
                    _safe_add(box, box_height - 2, max(2, w - 28), f"linhas {off + 1}-{min(len(function_lines), off + page)}/{len(function_lines)}", 24, p.DIM)
            else:
                page = max(1, usable - (4 if active_tab == TAB_API else 1))
                if rows:
                    selected[active_tab] = min(selected[active_tab], len(rows) - 1)
                else:
                    selected[active_tab] = 0
                sel = selected[active_tab]
                off = offsets[active_tab]
                if sel < off:
                    off = sel
                if sel >= off + page:
                    off = sel - page + 1
                off = max(0, min(off, max(0, len(rows) - page)))
                offsets[active_tab] = off

                for pos, row in enumerate(rows[off:off + page]):
                    absolute = off + pos
                    y = (5 if active_tab == TAB_API else 2) + pos
                    attr = p.SELECTED if absolute == sel and not menu_focus else 0
                    if active_tab in (TAB_INBOX, TAB_REPLIES):
                        date = _format_date(row.get("mail_date") or row.get("created_at") or "-")
                        peer = row.get("sender") if active_tab == TAB_INBOX else row.get("recipient")
                        subject = row.get("subject") or "(sem assunto)"
                        status = row.get("status") or "-"
                        status_label = _status_label(status)
                        line = f"{date:<11} {str(peer or '-')[:34]:<34} {str(subject)[:40]:<40} {status_label[:18]}"
                        if absolute != sel or menu_focus:
                            attr = _status_attr(status, p)
                        _safe_add(box, y, 2, line, w - 4, attr)
                    elif active_tab == TAB_CONSOLE:
                        date = _format_date(row.get("created_at") or "-")
                        category = str(row.get("category") or "-")[:8]
                        level = str(row.get("level") or "-")[:6]
                        text = str(row.get("text") or "")
                        line = f"{date:<11} {category:<8} {level:<6} {text}"
                        if absolute != sel or menu_focus:
                            attr = _status_attr(level, p)
                        _safe_add(box, y, 2, line, w - 4, attr)
                    elif active_tab == TAB_ACCOUNTS:
                        status = "ONLINE" if row["connected"] else ("ERRO" if row["last_error"] else "INICIANDO")
                        line = f"{status:<10} {row['email'][:42]:<42} {row['received']:<5} {row['replied']:<6} {row['last_check']}"
                        if absolute != sel or menu_focus:
                            attr = _status_attr(status, p)
                        _safe_add(box, y, 2, line, w - 4, attr)
                    else:
                        status = row.get("status") or "-"
                        elapsed = row.get("elapsed_ms")
                        elapsed_text = f"{int(elapsed)/1000:.1f}s" if elapsed is not None else "..."
                        result = row.get("output_path") or row.get("response_summary") or row.get("input_path") or "-"
                        kind = _api_kind_label(str(row.get("kind") or ""))
                        if kind == "ZIP TESTE":
                            kind = "ZIP"
                        elif kind == "ESCOLHE ZIP":
                            kind = "ESCOLHE"
                        kind = kind[:7]
                        line = f"#{int(row.get('id') or 0):<4} {kind:<7} {_format_date(row.get('started_at') or '-'):<11} {_api_status_label(status):<14} {str(row.get('model') or '-')[:17]:<17} {str(row.get('reasoning_effort') or '-')[:6]:<6} {elapsed_text:<9} {result}"
                        if absolute != sel or menu_focus:
                            attr = _status_attr("error" if status == "erro" else ("completed" if status == "concluido" else "analyzing"), p)
                        _safe_add(box, y, 2, line, w - 4, attr)

                if not rows:
                    _safe_add(box, 3, 3, "Nenhum registro ainda.", w - 6, p.DIM)

            if menu_focus:
                footer = "←/→ selecionar menu  ↓ ou Enter entrar  F5 atualizar agora  Q sair"
            elif active_tab == TAB_INBOX:
                footer = "↑/↓ navegar  Enter abrir  D remover  PgUp/PgDn  Esc voltar ao menu  F5 atualizar  Q sair"
            elif active_tab == TAB_API:
                footer = "↑/↓ navegar  Enter abrir  T teste ZIP  PgUp/PgDn  Esc voltar ao menu  F5 atualizar  Q sair"
            elif active_tab == TAB_FUNCTIONS:
                footer = "↑/↓ rolar  PgUp/PgDn  Esc voltar ao menu  F5 atualizar  Q sair"
            else:
                footer = "↑/↓ navegar  Enter abrir quando disponível  PgUp/PgDn  Esc voltar ao menu  F5 atualizar  Q sair"
            _safe_add(stdscr, h - 2, 1, footer, w - 2, p.DIM)
            if notice and time.time() < notice_until:
                _safe_add(stdscr, h - 1, 1, notice, w - 2, notice_attr)
            else:
                notice = ""
                hint = (
                    "FUNÇÕES mostra o conteúdo atual de functions.json em formato humano." if active_tab == TAB_FUNCTIONS else
                    "T na área API envia um ZIP de teste e salva o retorno na pasta configurada." if active_tab == TAB_API else
                    "D remove da ENTRADA com confirmação e move o e-mail para a lixeira do servidor." if active_tab == TAB_INBOX else
                    "Use ↑/Esc para voltar ao menu superior."
                )
                _safe_add(stdscr, h - 1, 1, hint, w - 2, p.DIM)
            stdscr.refresh()

            try:
                ch = stdscr.getch()
            except curses.error:
                ch = -1

            if ch in (ord("q"), ord("Q")):
                monitor.stop()
                break

            if ch in (curses.KEY_F5, ord("r"), ord("R")) and not checking:
                checking = True
                notice = "Atualizando agora: executando a mesma verificação IMAP do poll automático..."
                notice_attr = p.WARN
                notice_until = time.time() + 3

                def do_check():
                    nonlocal checking
                    try:
                        monitor.run_once()
                    finally:
                        checking = False
                threading.Thread(target=do_check, daemon=True).start()
                time.sleep(0.12)
                continue

            if menu_focus:
                if ch in (9, curses.KEY_RIGHT):
                    active_tab = (active_tab + 1) % len(TAB_NAMES)
                elif ch == curses.KEY_LEFT:
                    active_tab = (active_tab - 1) % len(TAB_NAMES)
                elif ch in (curses.KEY_DOWN, 10, 13, curses.KEY_ENTER):
                    menu_focus = False
                time.sleep(0.12)
                continue

            if ch == 27:
                menu_focus = True
                time.sleep(0.12)
                continue

            if active_tab == TAB_FUNCTIONS:
                max_off = max(0, len(function_lines) - page)
                if ch == curses.KEY_UP:
                    if offsets[TAB_FUNCTIONS] <= 0:
                        menu_focus = True
                    else:
                        offsets[TAB_FUNCTIONS] = max(0, offsets[TAB_FUNCTIONS] - 1)
                elif ch == curses.KEY_DOWN:
                    offsets[TAB_FUNCTIONS] = min(max_off, offsets[TAB_FUNCTIONS] + 1)
                elif ch == curses.KEY_PPAGE:
                    offsets[TAB_FUNCTIONS] = max(0, offsets[TAB_FUNCTIONS] - page)
                elif ch == curses.KEY_NPAGE:
                    offsets[TAB_FUNCTIONS] = min(max_off, offsets[TAB_FUNCTIONS] + page)
                time.sleep(0.12)
                continue

            if ch == curses.KEY_UP and rows:
                if selected[active_tab] == 0:
                    menu_focus = True
                else:
                    selected[active_tab] = max(0, selected[active_tab] - 1)
            elif ch == curses.KEY_UP and not rows:
                menu_focus = True
            elif ch == curses.KEY_DOWN and rows:
                selected[active_tab] = min(len(rows) - 1, selected[active_tab] + 1)
            elif ch == curses.KEY_PPAGE and rows:
                selected[active_tab] = max(0, selected[active_tab] - page)
            elif ch == curses.KEY_NPAGE and rows:
                selected[active_tab] = min(len(rows) - 1, selected[active_tab] + page)
            elif ch in (10, 13, curses.KEY_ENTER) and rows and active_tab in (TAB_INBOX, TAB_REPLIES):
                row = rows[selected[active_tab]]
                full = store.get_message(int(row["id"]))
                if full:
                    stdscr.nodelay(False)
                    _popup_message(stdscr, full, p)
                    stdscr.nodelay(True)
            elif ch in (10, 13, curses.KEY_ENTER) and rows and active_tab == TAB_API:
                full = store.get_api_run(int(rows[selected[active_tab]]["id"]))
                if full:
                    stdscr.nodelay(False)
                    _popup_api_run(stdscr, full, p)
                    stdscr.nodelay(True)
            elif ch in (ord("d"), ord("D")):
                if active_tab != TAB_INBOX:
                    notice = "D: remoção disponível somente em ENTRADA; respostas permanecem como histórico de envio."
                    notice_attr = p.WARN
                    notice_until = time.time() + 4
                elif not rows:
                    notice = "Nenhuma mensagem selecionada para remover."
                    notice_attr = p.WARN
                    notice_until = time.time() + 3
                else:
                    row = rows[selected[active_tab]]
                    full = store.get_message(int(row["id"]))
                    if full:
                        status = (full.get("status") or "").lower()
                        stdscr.nodelay(False)
                        if status in PROCESSING_STATUSES:
                            _popup_notice(
                                stdscr,
                                "REMOÇÃO BLOQUEADA",
                                [
                                    "E-MAIL EM PROCESSAMENTO.",
                                    f"Estado atual: {_status_label(status)}",
                                    "Aguarde o processamento terminar antes de remover.",
                                ],
                                p,
                                p.WARN,
                            )
                            confirmed = False
                        else:
                            confirmed = _popup_confirm_delete(stdscr, full, p)
                        stdscr.nodelay(True)
                        if confirmed:
                            try:
                                _safe_add(stdscr, h - 1, 1, "Removendo do IMAP e registrando a remoção...", w - 2, p.WARN)
                                stdscr.refresh()
                                mode = monitor.delete_inbound(full)
                                notice = f"E-mail removido com sucesso. IMAP: {mode}."
                                notice_attr = p.OK
                                notice_until = time.time() + 5
                                selected[TAB_INBOX] = max(0, selected[TAB_INBOX] - 1)
                            except Exception as exc:
                                notice = f"ERRO AO REMOVER: {exc}"
                                notice_attr = p.ERROR
                                notice_until = time.time() + 8
            elif ch in (ord("t"), ord("T")) and active_tab == TAB_API:
                if api_testing:
                    notice = "Já existe um teste ZIP da API em andamento."
                    notice_attr = p.WARN
                    notice_until = time.time() + 4
                else:
                    api_testing = True
                    notice = f"Teste ZIP iniciado. O retorno será salvo em {settings.openai_output_dir}."
                    notice_attr = p.WARN
                    notice_until = time.time() + 5

                    def do_api_test():
                        nonlocal api_testing
                        try:
                            api_runner.run_zip_test()
                        except Exception:
                            pass
                        finally:
                            api_testing = False
                    threading.Thread(target=do_api_test, daemon=True).start()
            time.sleep(0.12)

    try:
        curses.wrapper(draw)
    finally:
        monitor.stop()
        thread.join(timeout=2)
    return 0
