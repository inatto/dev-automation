from __future__ import annotations

import curses
import queue
import threading
import time

from config import Settings
from monitor import Monitor
from store import Store


def run(settings: Settings) -> int:
    store = Store(settings.database_path)
    events: queue.Queue[str] = queue.Queue()
    monitor = Monitor(settings, store, events.put)
    thread = threading.Thread(target=monitor.run_forever, daemon=True)
    thread.start()

    def draw(stdscr):
        curses.curs_set(0)
        stdscr.nodelay(True)
        log: list[str] = []
        while not monitor.stop_event.is_set():
            while True:
                try:
                    log.append(events.get_nowait())
                except queue.Empty:
                    break
            log = log[-12:]
            stdscr.erase()
            h, w = stdscr.getmaxyx()
            def put(y, text):
                if 0 <= y < h:
                    try:
                        stdscr.addnstr(y, 0, text, max(0, w - 1))
                    except curses.error:
                        pass
            put(0, "Amazon IMAP Bot · monitor 24h")
            put(1, f"IMAP {settings.imap_host}:{settings.imap_port} · SES {settings.aws_region}/{settings.aws_profile} · OpenAI {settings.openai_model}")
            put(2, f"Auto-resposta: {'ON' if settings.auto_reply_enabled else 'OFF'} · Som: {'ON' if settings.sound_enabled else 'OFF'} · intervalo {settings.poll_seconds}s")
            put(4, "CAIXAS MONITORADAS")
            y = 5
            for email, state in monitor.states.items():
                status = "ONLINE" if state.connected else ("ERRO" if state.last_error else "INICIANDO")
                put(y, f"{status:<9} {email:<38} recebidos={state.received:<4} respondidos={state.replied:<4} última={state.last_check}")
                y += 1
            y += 1
            put(y, "ATIVIDADE"); y += 1
            for entry in log:
                put(y, entry); y += 1
            put(h - 1, "Q sair · R verificar agora")
            stdscr.refresh()
            try:
                ch = stdscr.getch()
            except curses.error:
                ch = -1
            if ch in (ord("q"), ord("Q")):
                monitor.stop()
                break
            if ch in (ord("r"), ord("R")):
                threading.Thread(target=monitor.run_once, daemon=True).start()
            time.sleep(0.2)

    try:
        curses.wrapper(draw)
    finally:
        monitor.stop()
        thread.join(timeout=2)
    return 0
