from __future__ import annotations

import curses
import queue
import textwrap
import threading
import time

from config import Settings
from monitor import Monitor
from store import Store


TAB_INBOX = 0
TAB_REPLIES = 1
TAB_CONSOLE = 2
TAB_ACCOUNTS = 3
TAB_NAMES = ("F1 ENTRADA", "F2 RESPOSTAS", "F3 CONSOLE", "F4 CONTAS")


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
    if "ignored" in value or "warn" in value or "ignorado" in value:
        return p.WARN
    if value in {"sent", "replied", "online"} or "ok" in value:
        return p.OK
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
        f"Status: {row.get('status') or '-'}",
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


def run(settings: Settings) -> int:
    store = Store(settings.database_path)
    events: queue.Queue[str] = queue.Queue()
    monitor = Monitor(settings, store, events.put)
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
        selected = {TAB_INBOX: 0, TAB_REPLIES: 0, TAB_CONSOLE: 0, TAB_ACCOUNTS: 0}
        offsets = {TAB_INBOX: 0, TAB_REPLIES: 0, TAB_CONSOLE: 0, TAB_ACCOUNTS: 0}
        checking = False

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
            else:
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

            page = max(1, usable - 1)
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
                y = 2 + pos
                attr = p.SELECTED if absolute == sel else 0
                if active_tab in (TAB_INBOX, TAB_REPLIES):
                    date = _format_date(row.get("mail_date") or row.get("created_at") or "-")
                    peer = row.get("sender") if active_tab == TAB_INBOX else row.get("recipient")
                    subject = row.get("subject") or "(sem assunto)"
                    status = row.get("status") or "-"
                    line = f"{date:<11} {str(peer or '-')[:34]:<34} {str(subject)[:40]:<40} {status[:18]}"
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
                else:
                    status = "ONLINE" if row["connected"] else ("ERRO" if row["last_error"] else "INICIANDO")
                    line = f"{status:<10} {row['email'][:42]:<42} {row['received']:<5} {row['replied']:<6} {row['last_check']}"
                    if absolute != sel:
                        attr = _status_attr(status, p)
                    _safe_add(box, y, 2, line, w - 4, attr)

            if not rows:
                empty = "Nenhum registro ainda."
                _safe_add(box, 3, 3, empty, w - 6, p.DIM)

            footer = "F1 Entrada  F2 Respostas  F3 Console  F4 Contas  ↑↓ navegar  Enter abrir  R verificar agora  Q sair"
            _safe_add(stdscr, h - 2, 1, footer, w - 2, p.DIM)
            _safe_add(
                stdscr, h - 1, 1,
                "Segredos não são exibidos no console. O histórico operacional fica salvo no SQLite.",
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
            elif ch in (ord("r"), ord("R")) and not checking:
                checking = True
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
