#!/usr/bin/env python3
import curses
import locale
import os
import queue
import re
import resource
import signal
import subprocess
import sys
import threading
import time
from collections import deque
from pathlib import Path

locale.setlocale(locale.LC_ALL, "")

REFRESH_SECONDS = 0.15
CLOCK_SECONDS = 1.0
METRIC_SECONDS = 5.0
SYSTEM_METRIC_SECONDS = 1.0
MAX_LOG_LINES = 4000
THEMES = ("classic", "matrix")

PROJECT_ROOT = Path(__file__).resolve().parent.parent
BUILD_VERSION_FILE = PROJECT_ROOT / "VERSION"


def read_build_version():
    try:
        value = BUILD_VERSION_FILE.read_text(encoding="utf-8").strip()
        if value:
            return value
    except OSError:
        pass
    return "versão-desconhecida"


def clamp(value, low, high):
    return max(low, min(high, value))


def safe_add(win, y, x, text, attr=0, max_width=None):
    try:
        h, w = win.getmaxyx()
        if y < 0 or y >= h or x < 0 or x >= w:
            return
        room = max(0, w - x - 1)
        if max_width is not None:
            room = min(room, max_width)
        if room <= 0:
            return
        win.addnstr(y, x, str(text), room, attr)
    except curses.error:
        pass


def fit(text, width):
    text = str(text).replace("\r", " ").replace("\n", " ")
    if width <= 0:
        return ""
    if len(text) <= width:
        return text
    if width == 1:
        return text[:1]
    return text[: width - 1] + "~"


def read_int(path, default=0):
    try:
        return int(Path(path).read_text(encoding="ascii").strip())
    except (OSError, ValueError):
        return default


def same_uid(pid, uid):
    try:
        with open(f"/proc/{pid}/status", "r", encoding="ascii", errors="ignore") as fh:
            for line in fh:
                if line.startswith("Uid:"):
                    return int(line.split()[1]) == uid
    except (OSError, ValueError, IndexError):
        return False
    return False


def collect_inotify_metrics():
    uid = os.getuid()
    instances = 0
    watches = 0
    try:
        proc_entries = os.scandir("/proc")
    except OSError:
        return 0, 0

    with proc_entries:
        for entry in proc_entries:
            if not entry.name.isdigit() or not same_uid(entry.name, uid):
                continue
            fd_dir = f"/proc/{entry.name}/fd"
            try:
                fds = os.scandir(fd_dir)
            except OSError:
                continue
            with fds:
                for fd in fds:
                    try:
                        target = os.readlink(fd.path)
                    except OSError:
                        continue
                    if "inotify" not in target:
                        continue
                    instances += 1
                    try:
                        with open(
                            f"/proc/{entry.name}/fdinfo/{fd.name}",
                            "r",
                            encoding="ascii",
                            errors="ignore",
                        ) as info:
                            watches += sum(1 for line in info if line.startswith("inotify "))
                    except OSError:
                        pass
    return instances, watches


def process_fd_metrics(pid):
    if not pid:
        return 0, 0
    try:
        used = sum(1 for _ in os.scandir(f"/proc/{pid}/fd"))
    except OSError:
        used = 0
    limit = 0
    try:
        with open(f"/proc/{pid}/limits", "r", encoding="ascii", errors="ignore") as fh:
            for line in fh:
                if line.startswith("Max open files"):
                    parts = line.split()
                    limit = int(parts[3])
                    break
    except (OSError, ValueError, IndexError):
        try:
            limit = resource.getrlimit(resource.RLIMIT_NOFILE)[0]
        except Exception:
            limit = 0
    return used, limit


def systemd_user_active(unit):
    try:
        return subprocess.run(
            ["systemctl", "--user", "is-active", "--quiet", unit],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=0.2,
            check=False,
        ).returncode == 0
    except (OSError, subprocess.TimeoutExpired):
        return False


def count_zip_files(directory):
    if not directory:
        return 0
    try:
        return sum(
            1
            for p in Path(directory).iterdir()
            if p.is_file() and p.suffix.lower() == ".zip"
        )
    except OSError:
        return 0


def centered_label(win, label, attr):
    try:
        _, width = win.getmaxyx()
        label = f" {label} "
        x = max(2, (width - len(label)) // 2)
        safe_add(win, 0, x, label, attr, width - x - 2)
    except curses.error:
        pass


def human_bytes(value, per_second=False):
    value = max(0.0, float(value or 0.0))
    units = ("B", "K", "M", "G", "T")
    unit = units[0]
    for unit in units:
        if value < 1024.0 or unit == units[-1]:
            break
        value /= 1024.0
    if unit == "B":
        text = f"{value:.0f}{unit}"
    elif value >= 100:
        text = f"{value:.0f}{unit}"
    elif value >= 10:
        text = f"{value:.1f}{unit}"
    else:
        text = f"{value:.2f}{unit}"
    return text + ("/s" if per_second else "")


def cpu_times():
    try:
        fields = Path("/proc/stat").read_text(encoding="ascii").splitlines()[0].split()[1:]
        values = [int(value) for value in fields]
    except (OSError, ValueError, IndexError):
        return 0, 0
    total = sum(values)
    idle = (values[3] if len(values) > 3 else 0) + (values[4] if len(values) > 4 else 0)
    return total, idle


def memory_usage():
    values = {}
    try:
        for line in Path("/proc/meminfo").read_text(encoding="ascii").splitlines():
            key, rest = line.split(":", 1)
            values[key] = int(rest.strip().split()[0]) * 1024
    except (OSError, ValueError, IndexError):
        return 0, 0
    total = values.get("MemTotal", 0)
    available = values.get("MemAvailable", values.get("MemFree", 0))
    return max(0, total - available), total


def disk_usage(path="/"):
    try:
        stat = os.statvfs(path)
    except OSError:
        return 0, 0
    total = stat.f_blocks * stat.f_frsize
    available = stat.f_bavail * stat.f_frsize
    return max(0, total - available), total


def default_network_interface():
    try:
        lines = Path("/proc/net/route").read_text(encoding="ascii").splitlines()[1:]
    except OSError:
        lines = []
    for line in lines:
        fields = line.split()
        if len(fields) >= 4 and fields[1] == "00000000":
            try:
                flags = int(fields[3], 16)
            except ValueError:
                flags = 0
            if flags & 0x2:
                return fields[0]
    try:
        for entry in Path("/sys/class/net").iterdir():
            if entry.name != "lo" and (entry / "operstate").read_text(encoding="ascii").strip() == "up":
                return entry.name
    except OSError:
        pass
    return ""


def network_bytes(interface):
    if not interface:
        return 0, 0
    base = Path("/sys/class/net") / interface / "statistics"
    return read_int(base / "rx_bytes"), read_int(base / "tx_bytes")


def network_speed_bps(interface):
    if not interface:
        return 0
    speed_mbps = read_int(Path("/sys/class/net") / interface / "speed", 0)
    if speed_mbps <= 0 or speed_mbps > 1_000_000:
        return 0
    return speed_mbps * 1_000_000


class Dashboard:
    def __init__(self, stdscr, script, child_args):
        self.stdscr = stdscr
        self.script = script
        self.child_args = child_args
        self.proc = None
        self.output = queue.Queue()
        self.logs = deque(maxlen=MAX_LOG_LINES)
        self.scroll = 0
        self.follow = True
        self.running = True
        self.status = "INICIANDO"
        self.status_detail = "Preparando monitor"
        self.last_action = "Inicialização"
        self.version = read_build_version()
        self.mode = "INOTIFY"
        self.output_dir = os.environ.get("CODE_ROOT", "/home/daniel/Code")
        self.downloads = str(Path.home() / "Downloads")
        self.inotify_instances = 0
        self.inotify_watches = 0
        self.max_instances = 0
        self.max_watches = 0
        self.manager_fds = 0
        self.manager_fd_limit = 0
        self.zip_count = 0
        self.download_zip_count = 0
        self.last_metric_at = 0.0
        self.last_system_metric_at = 0.0
        self.cpu_percent = 0.0
        self.cpu_prev_total = 0
        self.cpu_prev_idle = 0
        self.memory_used = 0
        self.memory_total = 0
        self.disk_used = 0
        self.disk_total = 0
        self.net_interface = default_network_interface()
        self.net_rx_rate = 0.0
        self.net_tx_rate = 0.0
        self.net_bar_percent = 0.0
        self.net_capacity_bps = network_speed_bps(self.net_interface)
        self.net_prev_at = 0.0
        self.net_prev_rx = 0
        self.net_prev_tx = 0
        self.last_draw_at = 0.0
        self.exit_code = None
        self.child_exited = False
        self.colors = {}
        self.windows = {}
        self.layout_size = None
        self.dirty = True
        self.full_redraw = True
        self.theme_file = Path(
            os.environ.get(
                "DEV_MANAGER_TUI_THEME_FILE",
                str(Path.home() / ".local/state/dev-automation/tui-theme"),
            )
        )
        self.theme = self.load_theme()

    def load_theme(self):
        env_theme = os.environ.get("DEV_MANAGER_TUI_THEME", "").strip().lower()
        if env_theme in THEMES:
            return env_theme
        try:
            saved = self.theme_file.read_text(encoding="ascii").strip().lower()
            if saved in THEMES:
                return saved
        except OSError:
            pass
        return "classic"

    def save_theme(self):
        try:
            self.theme_file.parent.mkdir(parents=True, exist_ok=True)
            self.theme_file.write_text(self.theme + "\n", encoding="ascii")
        except OSError:
            pass

    def init_screen(self):
        try:
            curses.curs_set(0)
        except curses.error:
            pass
        self.stdscr.keypad(True)
        self.stdscr.timeout(int(REFRESH_SECONDS * 1000))
        try:
            self.stdscr.leaveok(True)
        except curses.error:
            pass
        if curses.has_colors():
            curses.start_color()
            try:
                curses.use_default_colors()
            except curses.error:
                pass
        self.apply_theme(persist=False)

    def color_number(self, preferred, fallback):
        if curses.has_colors() and getattr(curses, "COLORS", 0) > preferred:
            return preferred
        return fallback

    def apply_theme(self, persist=True):
        if curses.has_colors():
            if self.theme == "matrix":
                # XTerm-256: preto + verdes profundos/brilhantes.
                bg = self.color_number(0, curses.COLOR_BLACK)
                base = self.color_number(40, curses.COLOR_GREEN)
                border = self.color_number(46, curses.COLOR_GREEN)
                highlight = self.color_number(82, curses.COLOR_GREEN)
                ok = self.color_number(118, curses.COLOR_GREEN)
                error = self.color_number(196, curses.COLOR_RED)
                sql = self.color_number(48, curses.COLOR_CYAN)
                muted = self.color_number(22, curses.COLOR_GREEN)
                download = self.color_number(51, curses.COLOR_CYAN)
                warning = self.color_number(226, curses.COLOR_YELLOW)
                metric_cpu = self.color_number(51, curses.COLOR_CYAN)
                metric_memory = self.color_number(201, curses.COLOR_MAGENTA)
                metric_disk = self.color_number(226, curses.COLOR_YELLOW)
                metric_network = self.color_number(118, curses.COLOR_GREEN)
            else:
                # BASIC/Clipper escurecido: navy profundo sem o azul estourado.
                bg = self.color_number(17, curses.COLOR_BLUE)
                base = self.color_number(253, curses.COLOR_WHITE)
                border = self.color_number(45, curses.COLOR_CYAN)
                highlight = self.color_number(228, curses.COLOR_YELLOW)
                ok = self.color_number(84, curses.COLOR_GREEN)
                error = self.color_number(203, curses.COLOR_RED)
                sql = self.color_number(213, curses.COLOR_MAGENTA)
                muted = self.color_number(110, curses.COLOR_CYAN)
                download = self.color_number(117, curses.COLOR_CYAN)
                warning = self.color_number(220, curses.COLOR_YELLOW)
                metric_cpu = self.color_number(51, curses.COLOR_CYAN)
                metric_memory = self.color_number(213, curses.COLOR_MAGENTA)
                metric_disk = self.color_number(220, curses.COLOR_YELLOW)
                metric_network = self.color_number(84, curses.COLOR_GREEN)

            pairs = (
                (1, base, bg),
                (2, border, bg),
                (3, highlight, bg),
                (4, ok, bg),
                (5, error, bg),
                (6, sql, bg),
                (7, muted, bg),
                (8, download, bg),
                (9, warning, bg),
                (10, metric_cpu, bg),
                (11, metric_memory, bg),
                (12, metric_disk, bg),
                (13, metric_network, bg),
            )
            for pair, fg, bg_color in pairs:
                try:
                    curses.init_pair(pair, fg, bg_color)
                except curses.error:
                    pass

        self.colors = {
            "base": curses.color_pair(1),
            "border": curses.color_pair(2) | curses.A_BOLD,
            "highlight": curses.color_pair(3) | curses.A_BOLD,
            "ok": curses.color_pair(4) | curses.A_BOLD,
            "error": curses.color_pair(5) | curses.A_BOLD,
            "sql": curses.color_pair(6) | curses.A_BOLD,
            "muted": curses.color_pair(7),
            "download": curses.color_pair(8) | curses.A_BOLD,
            "warning": curses.color_pair(9) | curses.A_BOLD,
            "metric_cpu": curses.color_pair(10) | curses.A_BOLD,
            "metric_memory": curses.color_pair(11) | curses.A_BOLD,
            "metric_disk": curses.color_pair(12) | curses.A_BOLD,
            "metric_network": curses.color_pair(13) | curses.A_BOLD,
        }
        self.stdscr.bkgd(" ", self.colors["base"])
        for win in self.windows.values():
            try:
                win.bkgd(" ", self.colors["base"])
            except curses.error:
                pass
        self.full_redraw = True
        self.dirty = True
        if persist:
            self.save_theme()

    def toggle_theme(self):
        self.theme = "matrix" if self.theme == "classic" else "classic"
        self.apply_theme(persist=True)

    def start_child(self):
        env = os.environ.copy()
        env["DEV_MANAGER_TUI_CHILD"] = "1"
        env["AUTO_CODE_TUI"] = "off"
        cmd = [self.script] + self.child_args
        self.proc = subprocess.Popen(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            stdin=subprocess.DEVNULL,
            text=True,
            bufsize=1,
            env=env,
            start_new_session=True,
        )

        def reader():
            assert self.proc.stdout is not None
            try:
                for raw in self.proc.stdout:
                    self.output.put(raw.rstrip("\n"))
            finally:
                self.output.put(None)

        threading.Thread(target=reader, name="dev-manager-output", daemon=True).start()

    def stop_child(self):
        if not self.proc or self.proc.poll() is not None:
            return
        try:
            os.killpg(self.proc.pid, signal.SIGINT)
        except (ProcessLookupError, PermissionError):
            try:
                self.proc.terminate()
            except OSError:
                pass
        try:
            self.proc.wait(timeout=4)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(self.proc.pid, signal.SIGTERM)
            except (ProcessLookupError, PermissionError):
                pass
            try:
                self.proc.wait(timeout=2)
            except subprocess.TimeoutExpired:
                try:
                    os.killpg(self.proc.pid, signal.SIGKILL)
                except (ProcessLookupError, PermissionError):
                    pass

    @staticmethod
    def split_log_context(line):
        match = re.match(r"^@@DEVCTX:([a-z_]+)@@", line)
        if not match:
            return "", line
        return match.group(1), line[match.end():]

    def infer_state(self, line):
        _, line = self.split_log_context(line)
        clean = re.sub(r"\x1b\[[0-9;?]*[ -/]*[@-~]", "", line).strip()
        if not clean:
            return
        self.last_action = fit(clean, 180)
        upper = clean.upper()

        if clean.startswith("Auto Code Manager - "):
            self.status_detail = clean
        elif clean.startswith("Downloads:"):
            self.downloads = clean.split(":", 1)[1].strip()
        elif clean.startswith("ZIP_DIR:"):
            self.output_dir = clean.split(":", 1)[1].strip()
        elif clean.startswith("Modo:"):
            self.mode = clean.split(":", 1)[1].strip().split()[0].upper()

        # Vermelho é reservado a erro real. Nunca inferir erro só porque uma
        # linha de resumo contém texto como "0 falha(s)".
        if "ERRO:" in upper:
            self.status = "ERRO"
            self.status_detail = clean
        elif "PAUSADO" in upper:
            self.status = "PAUSADO"
            self.status_detail = clean
        elif "BACKUP" in upper and ("INÍCIO" in upper or "INICIO" in upper):
            self.status = "BACKUP"
            self.status_detail = clean
        elif "DOWNLOADS" in upper or "IMPORT" in upper or "UNZIP" in upper:
            self.status = "IMPORTANDO"
            self.status_detail = clean
        elif "SQL" in upper and ("ZIP" in upper or "COMPACT" in upper):
            self.status = "SQL -> ZIP"
            self.status_detail = clean
        elif "IDLE" in upper or "AGUARDANDO" in upper:
            self.status = "ATIVO"
            self.status_detail = clean
        elif "CONCLUÍDO" in upper or "CONCLUIDO" in upper:
            self.status = "OK"
            self.status_detail = clean

    def drain_output(self):
        changed = False
        while True:
            try:
                item = self.output.get_nowait()
            except queue.Empty:
                break
            if item is None:
                continue
            changed = True
            self.logs.append(item)
            self.infer_state(item)
            if self.follow:
                self.scroll = 0
        if changed:
            self.dirty = True
        return changed

    def collect_metrics(self):
        now = time.monotonic()
        if now - self.last_metric_at < METRIC_SECONDS:
            return False
        self.last_metric_at = now
        before = (
            self.max_instances,
            self.max_watches,
            self.inotify_instances,
            self.inotify_watches,
            self.manager_fds,
            self.manager_fd_limit,
            self.zip_count,
            self.download_zip_count,
        )
        self.max_instances = read_int("/proc/sys/fs/inotify/max_user_instances")
        self.max_watches = read_int("/proc/sys/fs/inotify/max_user_watches")
        self.inotify_instances, self.inotify_watches = collect_inotify_metrics()
        pid = self.proc.pid if self.proc else None
        self.manager_fds, self.manager_fd_limit = process_fd_metrics(pid)
        self.zip_count = count_zip_files(self.output_dir)
        self.download_zip_count = count_zip_files(self.downloads)
        after = (
            self.max_instances,
            self.max_watches,
            self.inotify_instances,
            self.inotify_watches,
            self.manager_fds,
            self.manager_fd_limit,
            self.zip_count,
            self.download_zip_count,
        )
        if after != before:
            self.dirty = True
            return True
        return False

    def collect_system_metrics(self):
        now = time.monotonic()
        if now - self.last_system_metric_at < SYSTEM_METRIC_SECONDS:
            return False
        self.last_system_metric_at = now

        before = (
            round(self.cpu_percent, 1),
            self.memory_used,
            self.memory_total,
            self.disk_used,
            self.disk_total,
            self.net_interface,
            int(self.net_rx_rate),
            int(self.net_tx_rate),
            round(self.net_bar_percent, 1),
        )

        total, idle = cpu_times()
        if self.cpu_prev_total and total > self.cpu_prev_total:
            delta_total = total - self.cpu_prev_total
            delta_idle = max(0, idle - self.cpu_prev_idle)
            if delta_total > 0:
                self.cpu_percent = clamp(100.0 * (delta_total - delta_idle) / delta_total, 0.0, 100.0)
        self.cpu_prev_total, self.cpu_prev_idle = total, idle

        self.memory_used, self.memory_total = memory_usage()
        self.disk_used, self.disk_total = disk_usage("/")

        interface = default_network_interface()
        if interface != self.net_interface:
            self.net_interface = interface
            self.net_capacity_bps = network_speed_bps(interface)
            self.net_prev_at = 0.0
            self.net_prev_rx = 0
            self.net_prev_tx = 0

        rx, tx = network_bytes(self.net_interface)
        if self.net_prev_at and now > self.net_prev_at:
            elapsed = now - self.net_prev_at
            self.net_rx_rate = max(0.0, (rx - self.net_prev_rx) / elapsed)
            self.net_tx_rate = max(0.0, (tx - self.net_prev_tx) / elapsed)
        self.net_prev_at = now
        self.net_prev_rx = rx
        self.net_prev_tx = tx

        capacity = self.net_capacity_bps or 100_000_000
        traffic_bps = (self.net_rx_rate + self.net_tx_rate) * 8.0
        self.net_bar_percent = clamp((traffic_bps / capacity) * 100.0, 0.0, 100.0) if capacity else 0.0

        after = (
            round(self.cpu_percent, 1),
            self.memory_used,
            self.memory_total,
            self.disk_used,
            self.disk_total,
            self.net_interface,
            int(self.net_rx_rate),
            int(self.net_tx_rate),
            round(self.net_bar_percent, 1),
        )
        if after != before:
            self.dirty = True
            return True
        return False

    @staticmethod
    def metric_text(label, detail, percent, width):
        """Renderiza a telemetria como duas subcolunas alinhadas.

        O rótulo fica à direita em uma largura fixa e a barra começa sempre
        na mesma coluna, com o mesmo tamanho para CPU/RAM/DISK/NET. O detalhe
        vem depois da barra e pode ser truncado sem deslocar o gráfico.
        """
        width = max(0, width)
        label_width = 4
        label_cell = str(label)[:label_width].rjust(label_width)

        # A largura da barra depende apenas da largura da coluna, nunca do
        # tamanho variável do detalhe. Assim todos os gráficos ficam alinhados.
        if width >= 34:
            bar_width = 14
        elif width >= 28:
            bar_width = 10
        else:
            bar_width = max(4, min(8, width - label_width - 4))

        filled = clamp(int(round(bar_width * clamp(percent, 0.0, 100.0) / 100.0)), 0, bar_width)
        bar = "█" * filled + "·" * (bar_width - filled)
        graph = f"[{bar}]"
        base = f"{label_cell}  {graph}"
        if width <= len(base):
            return fit(base, width)
        return fit(f"{base}  {detail}", width)

    def make_box(self, top, left, height, width):
        if height < 3 or width < 4:
            return None
        try:
            win = curses.newwin(height, width, top, left)
            win.bkgd(" ", self.colors["base"])
            try:
                win.leaveok(True)
            except curses.error:
                pass
            return win
        except curses.error:
            return None

    def ensure_layout(self):
        rows, cols = self.stdscr.getmaxyx()
        size = (rows, cols)
        if self.layout_size == size and self.windows:
            return rows, cols

        self.layout_size = size
        self.windows = {}
        self.full_redraw = True
        if rows < 18 or cols < 80:
            return rows, cols

        margin = 1
        width = cols - 2
        header_h = 7
        action_h = 4
        footer_h = 1
        action_top = margin + header_h
        log_top = action_top + action_h
        log_h = rows - log_top - footer_h - 1

        self.windows["header"] = self.make_box(margin, margin, header_h, width)
        self.windows["action"] = self.make_box(action_top, margin, action_h, width)
        self.windows["log"] = self.make_box(log_top, margin, max(3, log_h), width)
        return rows, cols

    def prep_box(self, win, label):
        if not win:
            return
        win.erase()
        win.bkgd(" ", self.colors["base"])
        win.attrset(self.colors["border"])
        # ACS/terminfo real: sem borda Unicode desenhada manualmente.
        win.border(
            curses.ACS_VLINE,
            curses.ACS_VLINE,
            curses.ACS_HLINE,
            curses.ACS_HLINE,
            curses.ACS_ULCORNER,
            curses.ACS_URCORNER,
            curses.ACS_LLCORNER,
            curses.ACS_LRCORNER,
        )
        centered_label(win, label, self.colors["highlight"])

    def status_attr(self):
        if self.status == "ERRO":
            return self.colors["error"]
        if self.status in {"OK", "ATIVO"}:
            return self.colors["ok"]
        return self.colors["highlight"]

    def draw(self, force=False):
        now_mono = time.monotonic()
        if not force and not self.dirty and now_mono - self.last_draw_at < CLOCK_SECONDS:
            return

        rows, cols = self.ensure_layout()
        if self.full_redraw:
            self.stdscr.erase()
            self.stdscr.bkgd(" ", self.colors["base"])

        if rows < 18 or cols < 80:
            if self.full_redraw:
                self.stdscr.erase()
            msg = "Terminal mínimo: 80x18. Aumente a janela para o modo Clipper."
            safe_add(
                self.stdscr,
                max(0, rows // 2),
                max(0, (cols - len(msg)) // 2),
                msg,
                self.colors["highlight"],
            )
            self.stdscr.noutrefresh()
            curses.doupdate()
            self.dirty = False
            self.full_redraw = False
            self.last_draw_at = now_mono
            return

        footer = "F2/T: tema   Setas/PgUp/PgDn: log   End: seguir   Ctrl+C/Q: sair" if not self.child_exited else "PROCESSO PAROU - veja o LOG acima   Setas/PgUp/PgDn: log   Q: sair"
        # Só atualiza a linha de rodapé; não limpa/redesenha a tela inteira.
        try:
            self.stdscr.move(rows - 1, 0)
            self.stdscr.clrtoeol()
        except curses.error:
            pass
        safe_add(self.stdscr, rows - 1, 2, fit(footer, cols - 4), self.colors["highlight"], cols - 4)
        self.stdscr.noutrefresh()

        header = self.windows.get("header")
        action = self.windows.get("action")
        logwin = self.windows.get("log")

        if header:
            self.prep_box(header, f"DEV AUTOMATION :: {self.version} :: CLIPPER / NCURSES")
            _, width = header.getmaxyx()
            inner = width - 4
            col = max(18, inner // 3)
            col1_x = 2
            col2_x = 2 + col
            col3_x = 2 + (2 * col)
            col1_w = max(1, col - 2)
            col2_w = max(1, col - 2)
            col3_w = max(1, width - col3_x - 2)
            now = time.strftime("%H:%M:%S")
            theme_label = "DARK / MATRIX" if self.theme == "matrix" else "DAY / BASIC"

            # Três colunas no mesmo header. As duas primeiras preservam o painel
            # operacional existente; a terceira é telemetria do host em tempo real.
            for sep_x in (col2_x - 1, col3_x - 1):
                if 1 < sep_x < width - 1:
                    for y in range(1, 6):
                        try:
                            header.addch(y, sep_x, curses.ACS_VLINE, self.colors["muted"])
                        except curses.error:
                            pass

            safe_add(header, 1, col1_x, f"STATUS: {self.status}", self.status_attr(), col1_w)
            safe_add(header, 1, col2_x, f"HORA: {now}", self.colors["highlight"], col2_w)
            safe_add(header, 2, col1_x, f"MODO: {self.mode}", self.colors["base"], col1_w)
            safe_add(header, 2, col2_x, f"TEMA: {theme_label}", self.colors["muted"], col2_w)
            safe_add(
                header,
                3,
                col1_x,
                f"INOTIFY: {self.inotify_instances}/{self.max_instances} instâncias",
                self.colors["border"],
                col1_w,
            )
            safe_add(
                header,
                3,
                col2_x,
                f"WATCHES: {self.inotify_watches}/{self.max_watches}",
                self.colors["border"],
                col2_w,
            )
            safe_add(
                header,
                4,
                col1_x,
                f"FD DEV-MANAGER: {self.manager_fds}/{self.manager_fd_limit}",
                self.colors["base"],
                col1_w,
            )
            safe_add(header, 4, col2_x, f"DOWNLOADS ZIPs: {self.download_zip_count}", self.colors["base"], col2_w)
            safe_add(header, 5, col1_x, f"DOWNLOADS: {self.downloads} · ZIPs CODE: {self.zip_count}", self.colors["ok"], col1_w + col2_w)

            mem_percent = (100.0 * self.memory_used / self.memory_total) if self.memory_total else 0.0
            disk_percent = (100.0 * self.disk_used / self.disk_total) if self.disk_total else 0.0
            cpu_detail = f"{self.cpu_percent:4.1f}%"
            mem_detail = f"{human_bytes(self.memory_used)}/{human_bytes(self.memory_total)} {mem_percent:3.0f}%"
            disk_detail = f"{human_bytes(self.disk_used)}/{human_bytes(self.disk_total)} {disk_percent:3.0f}%"
            net_detail = f"↓{human_bytes(self.net_rx_rate, True)} ↑{human_bytes(self.net_tx_rate, True)}"

            safe_add(
                header, 1, col3_x,
                self.metric_text("CPU", cpu_detail, self.cpu_percent, col3_w),
                self.colors["metric_cpu"], col3_w,
            )
            safe_add(
                header, 2, col3_x,
                self.metric_text("RAM", mem_detail, mem_percent, col3_w),
                self.colors["metric_memory"], col3_w,
            )
            safe_add(
                header, 3, col3_x,
                self.metric_text("DISK", disk_detail, disk_percent, col3_w),
                self.colors["metric_disk"], col3_w,
            )
            safe_add(
                header, 4, col3_x,
                self.metric_text("NET", net_detail, self.net_bar_percent, col3_w),
                self.colors["metric_network"], col3_w,
            )
            speed_label = f"IFACE: {self.net_interface or '-'}"
            if self.net_capacity_bps:
                speed_label += f"  LINK {self.net_capacity_bps / 1_000_000:.0f}M"
            else:
                speed_label += "  escala 100M"
            safe_add(header, 5, col3_x, fit(speed_label, col3_w), self.colors["muted"], col3_w)
            header.noutrefresh()

        if action:
            self.prep_box(action, "ÚLTIMA AÇÃO")
            _, width = action.getmaxyx()
            safe_add(action, 1, 2, fit(self.last_action, width - 5), self.colors["highlight"], width - 5)
            safe_add(action, 2, 2, fit(self.status_detail, width - 5), self.colors["base"], width - 5)
            action.noutrefresh()

        if logwin:
            self.prep_box(logwin, "LOG")
            lh, lw = logwin.getmaxyx()
            visible = max(1, lh - 2)
            total = len(self.logs)
            max_scroll = max(0, total - visible)
            self.scroll = clamp(self.scroll, 0, max_scroll)
            end = total - self.scroll
            start = max(0, end - visible)
            selected = list(self.logs)[start:end]
            context_colors = {
                "error": self.colors["error"],
                "warning": self.colors["warning"],
                "backup": self.colors["ok"],
                "downloads": self.colors["download"],
                "download_done": self.colors["download"],
                "cycle": self.colors["highlight"],
                "sql": self.colors["sql"],
                "zone": self.colors["warning"],
                "wait": self.colors["muted"],
                "ok": self.colors["ok"],
                "base": self.colors["base"],
            }
            for i, raw_line in enumerate(selected, start=1):
                context, line = self.split_log_context(raw_line)
                attr = context_colors.get(context, self.colors["base"])

                # Fallback somente para saídas externas não estruturadas. Logs
                # internos chegam com @@DEVCTX e não dependem do texto/caminho.
                if not context:
                    upper = line.upper()
                    message = re.sub(r"^\[[^]]+\]\s*", "", upper).lstrip()
                    if message.startswith("ERRO:"):
                        attr = self.colors["error"]
                    elif message.startswith(("AVISO:", "ATENÇÃO:", "ATENCAO:")):
                        attr = self.colors["warning"]
                    elif message.startswith(("OK ", "CONFIRMADO ", "CONCLUÍDO", "CONCLUIDO", "SUCESSO")):
                        attr = self.colors["ok"]

                display_line = fit(line, lw - 5)
                match = re.match(r"^(\[[^]]+\]\s*)(.*)$", display_line)
                if match:
                    stamp, message = match.groups()
                    # Data/hora mantém exatamente a cor semântica da linha, mas
                    # com brilho discretamente menor para separar visualmente o
                    # timestamp sem criar uma nova cor aleatória no meio do log.
                    stamp_attr = (attr & ~curses.A_BOLD) | curses.A_DIM
                    safe_add(logwin, i, 2, stamp, stamp_attr, lw - 5)
                    safe_add(logwin, i, 2 + len(stamp), message, attr, lw - 5 - len(stamp))
                else:
                    safe_add(logwin, i, 2, display_line, attr, lw - 5)
            indicator = "SEGUINDO" if self.follow else f"ROLAGEM +{self.scroll}"
            safe_add(
                logwin,
                0,
                max(2, lw - len(indicator) - 4),
                f" {indicator} ",
                self.colors["highlight"],
                len(indicator) + 2,
            )
            logwin.noutrefresh()

        curses.doupdate()
        self.dirty = False
        self.full_redraw = False
        self.last_draw_at = now_mono

    def handle_key(self, key):
        if key in (3, ord("q"), ord("Q")):
            self.running = False
        elif key in (getattr(curses, "KEY_F2", -9999), ord("t"), ord("T")):
            self.toggle_theme()
        elif key == curses.KEY_RESIZE:
            self.layout_size = None
            self.windows = {}
            self.full_redraw = True
            self.dirty = True
        elif key in (curses.KEY_UP, ord("k")):
            self.follow = False
            self.scroll += 1
            self.dirty = True
        elif key in (curses.KEY_DOWN, ord("j")):
            self.scroll = max(0, self.scroll - 1)
            if self.scroll == 0:
                self.follow = True
            self.dirty = True
        elif key == curses.KEY_PPAGE:
            self.follow = False
            rows, _ = self.stdscr.getmaxyx()
            self.scroll += max(5, rows - 16)
            self.dirty = True
        elif key == curses.KEY_NPAGE:
            rows, _ = self.stdscr.getmaxyx()
            self.scroll = max(0, self.scroll - max(5, rows - 16))
            if self.scroll == 0:
                self.follow = True
            self.dirty = True
        elif key == curses.KEY_END:
            self.scroll = 0
            self.follow = True
            self.dirty = True

    def run(self):
        self.init_screen()
        self.start_child()
        try:
            while self.running:
                self.drain_output()
                self.collect_metrics()
                self.collect_system_metrics()
                if self.proc and self.proc.poll() is not None and not self.child_exited:
                    self.exit_code = self.proc.returncode
                    self.child_exited = True
                    self.drain_output()
                    if self.exit_code == 0:
                        self.status = "ENCERRADO"
                        self.status_detail = "Processo finalizou inesperadamente. Q para sair."
                    else:
                        self.status = "ERRO"
                        self.status_detail = f"Processo encerrou com código {self.exit_code}. Q para sair."
                    self.last_action = "DEV-MANAGER PAROU; a interface permanecerá aberta para preservar o diagnóstico."
                    self.dirty = True
                    self.draw(force=True)
                    # Não fecha a TUI. Antes ela desaparecia imediatamente e escondia
                    # justamente as últimas linhas que explicavam a falha.
                self.draw()
                try:
                    key = self.stdscr.getch()
                except curses.error:
                    key = -1
                if key != -1:
                    self.handle_key(key)
        finally:
            self.stop_child()
            self.drain_output()
        return 0 if self.exit_code in (None, 0, 130, -signal.SIGINT) else int(self.exit_code)


def curses_main(stdscr, script, child_args):
    dashboard = Dashboard(stdscr, script, child_args)
    return dashboard.run()


def main():
    if len(sys.argv) < 2:
        print("Uso: dev-manager-tui.py <auto-code-manager.sh> [args...]", file=sys.stderr)
        return 2
    script = os.path.realpath(sys.argv[1])
    child_args = sys.argv[2:]
    if not os.path.isfile(script):
        print(f"ERRO: script não encontrado: {script}", file=sys.stderr)
        return 2
    try:
        result = [0]

        def wrapped(stdscr):
            result[0] = curses_main(stdscr, script, child_args)

        curses.wrapper(wrapped)
        return result[0]
    except KeyboardInterrupt:
        return 130


if __name__ == "__main__":
    raise SystemExit(main())
