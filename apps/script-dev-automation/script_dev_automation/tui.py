from __future__ import annotations

import curses
from dataclasses import dataclass

from .core import ConfigAudit, ProjectAudit, correct_key, protect, scan


STATUS = {
    "protected": ("PROTEGIDA", "ok"), "pending": ("PENDENTE", "warn"),
    "locked": ("BLOQUEADA", "warn"), "wrong_key": ("CHAVE ANTIGA", "error"),
    "no_git": ("SEM GIT", "error"), "error": ("ERRO", "error"),
    "missing": ("AUSENTE", "muted"), "no_config": ("SEM .CONFIG", "muted"),
    "aggregate": ("AGREGADOR", "muted"), "warning": ("ATENÇÃO", "error"),
}


def safe_add(win, y: int, x: int, value: object, attr: int = 0, width: int | None = None) -> None:
    try:
        height, total = win.getmaxyx()
        if 0 <= y < height and 0 <= x < total:
            win.addnstr(y, x, str(value), max(0, min(width or total - x, total - x)), attr)
    except curses.error:
        pass


@dataclass
class Row:
    project: ProjectAudit
    config: ConfigAudit | None


class Tui:
    def __init__(self, stdscr):
        self.stdscr = stdscr
        self.report = scan()
        self.rows: list[Row] = []
        self.index = 0
        self.offset = 0
        self.message = "A protege pendentes · P protege a selecionada · C corrige a chave da selecionada."
        self.running = True
        self.attrs: dict[str, int] = {}
        self._init_curses()
        self._rows()

    def _init_curses(self) -> None:
        self.stdscr.keypad(True)
        try:
            curses.curs_set(0)
        except curses.error:
            pass
        if curses.has_colors():
            curses.start_color()
            try:
                curses.use_default_colors()
            except curses.error:
                pass
            for number, colors in {
                1: (curses.COLOR_WHITE, curses.COLOR_BLUE), 2: (curses.COLOR_BLACK, curses.COLOR_CYAN),
                3: (curses.COLOR_CYAN, -1), 4: (curses.COLOR_GREEN, -1),
                5: (curses.COLOR_YELLOW, -1), 6: (curses.COLOR_RED, -1), 7: (curses.COLOR_WHITE, -1),
            }.items():
                try:
                    curses.init_pair(number, *colors)
                except curses.error:
                    pass
        self.attrs = {
            "header": curses.color_pair(1) | curses.A_BOLD,
            "selected": curses.color_pair(2) | curses.A_BOLD,
            "accent": curses.color_pair(3) | curses.A_BOLD,
            "ok": curses.color_pair(4) | curses.A_BOLD,
            "warn": curses.color_pair(5) | curses.A_BOLD,
            "error": curses.color_pair(6) | curses.A_BOLD,
            "normal": curses.color_pair(7), "muted": curses.A_DIM, "bold": curses.A_BOLD,
        }

    def _rows(self) -> None:
        self.rows = []
        for project in self.report.projects:
            self.rows.extend(Row(project, config) for config in project.configs) if project.configs else self.rows.append(Row(project, None))
        self.index = min(self.index, max(0, len(self.rows) - 1))

    def _refresh(self) -> None:
        self.report = scan()
        self._rows()
        self.message = "Status atualizado."

    @staticmethod
    def _status(row: Row) -> str:
        return row.config.status if row.config else row.project.status

    def draw(self) -> None:
        win = self.stdscr
        win.erase()
        height, width = win.getmaxyx()
        if height < 24 or width < 105:
            safe_add(win, 2, 2, "SCRIPT DEV AUTOMATION", self.attrs["accent"])
            safe_add(win, 4, 2, f"Terminal {width}x{height}; mínimo recomendado 105x24.", self.attrs["warn"])
            safe_add(win, 6, 2, "Amplie o terminal. Q sai.")
            win.refresh()
            return
        try:
            win.attrset(self.attrs["header"])
            win.hline(0, 0, " ", width)
            win.hline(1, 0, " ", width)
            win.attrset(0)
        except curses.error:
            pass
        safe_add(win, 0, 2, "SCRIPT DEV AUTOMATION · AUDITORIA GITCRYPT · .CONFIG", self.attrs["header"], width - 4)
        counts = self.report.counts()
        pending = counts["pending"] + counts["locked"]
        alerts = counts["wrong_key"] + counts["no_git"] + counts["error"]
        safe_add(win, 1, 2, f"Projetos com .config: {counts['projects']}   pastas: {counts['configs']}   protegidas: {counts['protected']}   pendentes: {pending}   alertas: {alerts}", self.attrs["header"], width - 4)
        safe_add(win, 3, 2, "STATUS", self.attrs["accent"])
        safe_add(win, 3, 18, "PROJETO", self.attrs["accent"])
        safe_add(win, 3, 50, "PASTA .CONFIG", self.attrs["accent"])
        visible = height - 11
        if self.index < self.offset:
            self.offset = self.index
        if self.index >= self.offset + visible:
            self.offset = self.index - visible + 1
        for screen_row, row_index in enumerate(range(self.offset, min(len(self.rows), self.offset + visible)), start=4):
            row = self.rows[row_index]
            label, attr_name = STATUS.get(self._status(row), (self._status(row).upper(), "normal"))
            selected = row_index == self.index
            safe_add(win, screen_row, 2, f"{label:<14}", self.attrs["selected"] if selected else self.attrs[attr_name], 14)
            safe_add(win, screen_row, 18, row.project.name, self.attrs["selected"] if selected else self.attrs["normal"], 30)
            config_path = str(row.config.path) if row.config else row.project.detail
            safe_add(win, screen_row, 50, config_path, self.attrs["selected"] if selected else self.attrs["normal"], width - 52)
        selected = self.rows[self.index] if self.rows else None
        detail_y = height - 6
        try:
            win.hline(detail_y - 1, 0, curses.ACS_HLINE, width)
        except curses.error:
            pass
        if selected:
            detail = selected.config.detail if selected.config else selected.project.detail
            if selected.config:
                detail += f" · arquivos={selected.config.files} · rastreados={selected.config.tracked} · repo={selected.config.repo or '-'}"
            safe_add(win, detail_y, 2, detail, self.attrs["muted"], width - 4)
        safe_add(win, detail_y + 1, 2, f"Chave fixa: {self.report.key_file}", self.attrs["accent"], width - 4)
        safe_add(win, detail_y + 2, 2, self.message, self.attrs["warn"], width - 4)
        safe_add(win, height - 2, 2, "↑↓ navega · R/F2 reaudita · P protege · A/F5 protege todas · C usa a chave correta · Q sai", self.attrs["bold"], width - 4)
        safe_add(win, height - 1, 2, "GitCrypt protege o conteúdo no Git; a cópia local continua legível enquanto desbloqueada. Nenhum commit é criado.", self.attrs["muted"], width - 4)
        win.refresh()

    def _confirm(self, prompt: str, expected: str = "PROTEGER") -> bool:
        height, width = self.stdscr.getmaxyx()
        popup_width = min(78, width - 6)
        popup = self.stdscr.derwin(7, popup_width, max(1, (height - 7) // 2), max(1, (width - popup_width) // 2))
        popup.erase()
        popup.box()
        safe_add(popup, 1, 2, prompt, self.attrs["warn"], popup_width - 4)
        safe_add(popup, 3, 2, f"Digite {expected} e pressione Enter; Esc cancela:", self.attrs["normal"], popup_width - 4)
        value = ""
        try:
            curses.curs_set(1)
        except curses.error:
            pass
        while True:
            safe_add(popup, 4, 2, " " * (popup_width - 4), 0, popup_width - 4)
            safe_add(popup, 4, 2, value, self.attrs["accent"], popup_width - 4)
            popup.refresh()
            key = popup.get_wch()
            if key == "\x1b":
                result = False
                break
            if key in ("\n", "\r"):
                result = value == expected
                break
            if key in (curses.KEY_BACKSPACE, "\b", "\x7f"):
                value = value[:-1]
            elif isinstance(key, str) and key.isprintable() and len(value) < 20:
                value += key
        try:
            curses.curs_set(0)
        except curses.error:
            pass
        self.stdscr.touchwin()
        return result

    def _protect(self, selected_only: bool) -> None:
        row = self.rows[self.index] if self.rows else None
        selected = row.config if selected_only and row else None
        target = str(selected.path) if selected else "todas as pastas .config pendentes"
        if selected_only and (not selected or selected.status not in {"pending", "locked"}):
            self.message = "A linha selecionada não está pendente."
            return
        if not self._confirm(f"Proteger {target}?"):
            self.message = "Operação cancelada; nada foi alterado."
            return
        try:
            messages = protect(self.report, selected)
            self._refresh()
            self.message = " | ".join(messages)
        except Exception as exc:
            self.message = f"ERRO: {exc}"

    def _correct_key(self) -> None:
        row = self.rows[self.index] if self.rows else None
        selected = row.config if row else None
        if not selected or selected.status != "wrong_key":
            self.message = "Selecione uma pasta marcada como CHAVE ANTIGA."
            return
        prompt = f"Substituir a chave antiga de {selected.repo} pela chave correta?"
        if not self._confirm(prompt, "USAR CHAVE CORRETA"):
            self.message = "Troca de chave cancelada; nada foi alterado."
            return
        try:
            message = correct_key(self.report, selected)
            self._refresh()
            self.message = message
        except Exception as exc:
            self.message = f"ERRO AO CORRIGIR CHAVE: {exc}"

    def handle(self, key: int) -> None:
        if key in (ord("q"), ord("Q"), 3):
            self.running = False
        elif key in (curses.KEY_UP, ord("k")) and self.rows:
            self.index = (self.index - 1) % len(self.rows)
        elif key in (curses.KEY_DOWN, ord("j")) and self.rows:
            self.index = (self.index + 1) % len(self.rows)
        elif key == curses.KEY_NPAGE and self.rows:
            self.index = min(len(self.rows) - 1, self.index + 10)
        elif key == curses.KEY_PPAGE and self.rows:
            self.index = max(0, self.index - 10)
        elif key in (ord("r"), ord("R"), getattr(curses, "KEY_F2", -1002)):
            self._refresh()
        elif key in (ord("p"), ord("P")):
            self._protect(True)
        elif key in (ord("a"), ord("A"), getattr(curses, "KEY_F5", -1005)):
            self._protect(False)
        elif key in (ord("c"), ord("C")):
            self._correct_key()

    def run(self) -> None:
        while self.running:
            self.draw()
            key = self.stdscr.getch()
            if key != -1:
                self.handle(key)


def run_tui() -> None:
    curses.wrapper(lambda stdscr: Tui(stdscr).run())
