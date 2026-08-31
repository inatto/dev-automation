from __future__ import annotations

import curses
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
TAB_NAMES = ("F1 ENTRADA", "F2 RESPOSTAS", "F3 CONSOLE", "F4 CONTAS", "F6 API")

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
    ph = max(12, min(h - 2, 24))
    pw = max(60, min(w - 4, 110))
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
    elapsed = row.get("elapsed_ms")
    elapsed_text = f"{int(elapsed)/1000:.2f}s" if elapsed is not None else "em andamento"
    lines = [
        f"ID: #{row.get('id')}",
        f"Estado: {_api_status_label(row.get('status') or '')}",
        f"Modelo: {row.get('model') or '-'}",
        f"Raciocínio: {row.get('reasoning_effort') or '-'}",
        f"Início: {row.get('started_at') or '-'}",
        f"Fim: {row.get('finished_at') or '-'}",
        f"Tempo: {elapsed_text}",
        f"Response ID: {row.get('response_id') or '-'}",
        f"ZIP entrada: {row.get('input_path') or '-'}",
        f"ZIP retorno: {row.get('output_path') or '-'}",
        "",
        f"Pedido: {row.get('request_summary') or '-'}",
        f"Resposta: {row.get('response_summary') or '-'}",
    ]
    if row.get("error"):
        lines.extend(["", f"ERRO: {row.get('error')}"])
    wrapped=[]
    for line in lines:
        wrapped.extend(textwrap.wrap(str(line), max(20, pw - 8), replace_whitespace=False) or [""])
    _safe_add(win, 0, 2, " CHAMADA API ", pw - 4, p.HEADER)
    offset=0
    page=max(1, ph-4)
    while True:
        for y in range(1, ph-2):
            _safe_add(win, y, 2, " " * max(0, pw-4), pw-4)
        for i, line in enumerate(wrapped[offset:offset+page]):
            attr = p.ERROR if line.startswith("ERRO:") else 0
            _safe_add(win, 1+i, 3, line, pw-6, attr)
        _safe_add(win, ph-2, 3, "↑↓/PgUp/PgDn rolar   Enter/Esc fechar", pw-6, p.DIM)
        win.refresh()
        ch=win.getch()
        if ch in (27,10,13,curses.KEY_ENTER,ord('q'),ord('Q')):
            break
        if ch == curses.KEY_UP:
            offset=max(0,offset-1)
        elif ch == curses.KEY_DOWN:
            offset=min(max(0,len(wrapped)-page),offset+1)
        elif ch == curses.KEY_PPAGE:
            offset=max(0,offset-page)
        elif ch == curses.KEY_NPAGE:
            offset=min(max(0,len(wrapped)-page),offset+page)
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

            box_top = 5
            box_height = h - 8
            box = _draw_box(stdscr, box_top, 0, box_height, w, TAB_NAMES[active_tab].split(" ", 1)[1], p)
            usable = max(1, box_height - 3)

            rows: list[dict] = []
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
            else:
                rows = store.list_api_runs(200)
                cfg1 = f"Modelo={settings.openai_model}  Raciocínio={settings.openai_reasoning_effort}  Timeout={settings.openai_timeout_seconds}s  Chave={'CONFIGURADA' if settings.openai_api_key else 'AUSENTE'}"
                cfg2 = f"Base URL={settings.openai_base_url}"
                cfg3 = f"Saída={settings.openai_output_dir}  ZIP teste={settings.openai_test_zip}  Funções={settings.functions_config}"
                _safe_add(box, 1, 2, cfg1, w - 4, p.BORDER | curses.A_BOLD)
                _safe_add(box, 2, 2, cfg2, w - 4, p.DIM)
                _safe_add(box, 3, 2, cfg3, w - 4, p.DIM)
                _safe_add(box, 4, 2, "ID    TIPO    INÍCIO      ESTADO         MODELO             NÍVEL   TEMPO     RESULTADO", w - 4, p.DIM)

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
                attr = p.SELECTED if absolute == sel else 0
                if active_tab in (TAB_INBOX, TAB_REPLIES):
                    date = _format_date(row.get("mail_date") or row.get("created_at") or "-")
                    peer = row.get("sender") if active_tab == TAB_INBOX else row.get("recipient")
                    subject = row.get("subject") or "(sem assunto)"
                    status = row.get("status") or "-"
                    status_label = _status_label(status)
                    line = f"{date:<11} {str(peer or '-')[:34]:<34} {str(subject)[:40]:<40} {status_label[:18]}"
                    if absolute != sel:
                        attr = _status_attr(status, p)
                    _safe_add(box, y, 2, line, w - 4, attr)
                elif active_tab == TAB_CONSOLE:
                    date = _format_date(row.get("created_at") or "-")
                    category = str(row.get("category") or "-")[:8]
                    level = str(row.get("level") or "-")[:6]
                    text = str(row.get("text") or "")
                    line = f"{date:<11} {category:<8} {level:<6} {text}"
                    if absolute != sel:
                        attr = _status_attr(level, p)
                    _safe_add(box, y, 2, line, w - 4, attr)
                elif active_tab == TAB_ACCOUNTS:
                    status = "ONLINE" if row["connected"] else ("ERRO" if row["last_error"] else "INICIANDO")
                    line = f"{status:<10} {row['email'][:42]:<42} {row['received']:<5} {row['replied']:<6} {row['last_check']}"
                    if absolute != sel:
                        attr = _status_attr(status, p)
                    _safe_add(box, y, 2, line, w - 4, attr)
                else:
                    status = row.get("status") or "-"
                    elapsed = row.get("elapsed_ms")
                    elapsed_text = f"{int(elapsed)/1000:.1f}s" if elapsed is not None else "..."
                    result = row.get("output_path") or row.get("response_summary") or row.get("input_path") or "-"
                    kind_map = {"zip-test": "ZIP", "function-router": "ROUTER", "email-reply": "EMAIL"}
                    kind = kind_map.get(str(row.get("kind") or ""), str(row.get("kind") or "API").upper()[:7])
                    line = f"#{int(row.get('id') or 0):<4} {kind:<7} {_format_date(row.get('started_at') or '-'):<11} {_api_status_label(status):<14} {str(row.get('model') or '-')[:17]:<17} {str(row.get('reasoning_effort') or '-')[:6]:<6} {elapsed_text:<9} {result}"
                    if absolute != sel:
                        attr = _status_attr("error" if status == "erro" else ("completed" if status == "concluido" else "analyzing"), p)
                    _safe_add(box, y, 2, line, w - 4, attr)

            if not rows:
                empty = "Nenhum registro ainda."
                _safe_add(box, 3, 3, empty, w - 6, p.DIM)

            footer = "F1 Entrada  F2 Respostas  F3 Console  F4 Contas  F5 Atualizar  F6 API  T teste ZIP  Enter abrir  Q sair"
            _safe_add(stdscr, h - 2, 1, footer, w - 2, p.DIM)
            if notice and time.time() < notice_until:
                _safe_add(stdscr, h - 1, 1, notice, w - 2, notice_attr)
            else:
                notice = ""
                _safe_add(
                    stdscr, h - 1, 1,
                    ("T na aba API envia um ZIP de teste e salva o retorno na pasta configurada." if active_tab == TAB_API else
                     "D remove da ENTRADA com confirmação e move o e-mail para a lixeira do servidor."),
                    w - 2, p.DIM,
                )
            stdscr.refresh()

            try:
                ch = stdscr.getch()
            except curses.error:
                ch = -1
            if ch in (ord("q"), ord("Q")):
                monitor.stop()
                break
            if ch == curses.KEY_F1:
                active_tab = TAB_INBOX
            elif ch == curses.KEY_F2:
                active_tab = TAB_REPLIES
            elif ch == curses.KEY_F3:
                active_tab = TAB_CONSOLE
            elif ch == curses.KEY_F4:
                active_tab = TAB_ACCOUNTS
            elif ch == curses.KEY_F6:
                active_tab = TAB_API
            elif ch in (9, curses.KEY_RIGHT):
                active_tab = (active_tab + 1) % len(TAB_NAMES)
            elif ch == curses.KEY_LEFT:
                active_tab = (active_tab - 1) % len(TAB_NAMES)
            elif ch == curses.KEY_UP and rows:
                selected[active_tab] = max(0, selected[active_tab] - 1)
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
            elif ch in (curses.KEY_F5, ord("r"), ord("R")) and not checking:
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

    try:
        curses.wrapper(draw)
    finally:
        monitor.stop()
        thread.join(timeout=2)
    return 0
