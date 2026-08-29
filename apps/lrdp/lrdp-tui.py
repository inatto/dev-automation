#!/usr/bin/env python3
"""LRDP Control Center: TUI fullscreen para conexões FreeRDP do dev-automation."""

from __future__ import annotations

import argparse
import curses
import ipaddress
import json
import locale
import os
import re
import shlex
import shutil
import socket
import subprocess
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import asdict, dataclass, replace
from pathlib import Path
from typing import Dict, Iterable, List, Optional, Tuple

locale.setlocale(locale.LC_ALL, "")

APP_DIR = Path(os.environ.get("LRDP_APPS_DIR", Path(__file__).resolve().parent))
STATE_ROOT = Path(
    os.environ.get(
        "LRDP_STATE_ROOT",
        Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config"))
        / "dev-automation"
        / "lrdp",
    )
)
LOG_ROOT = Path(
    os.environ.get(
        "LRDP_LOG_ROOT",
        Path(os.environ.get("XDG_STATE_HOME", Path.home() / ".local" / "state"))
        / "dev-automation"
        / "lrdp",
    )
)

AUDIO_MODES = ("redirect", "server", "none")
AUDIO_LABELS = {
    "redirect": "Neste Ubuntu",
    "server": "No computador remoto",
    "none": "Sem áudio",
}
REFRESH_SECONDS = 0.20
STATIC_REFRESH_SECONDS = 6.0
PROBE_SECONDS = 3.0


@dataclass
class LoginProfile:
    label: str
    username: str
    password_set: bool = False


@dataclass
class RdpProfile:
    name: str
    label: str
    target: str
    port: int
    script: str
    logins: List[LoginProfile]


@dataclass
class RdpState:
    login_index: int = 1
    audio_mode: str = "server"
    microphone: str = "no"
    primary_monitor: str = ""


@dataclass
class Monitor:
    id: int
    width: int
    height: int
    x: int
    y: int
    local_primary: bool = False


@dataclass
class DrmOutput:
    name: str
    connected: bool
    mode: str = ""


@dataclass
class ProbeResult:
    online: Optional[bool] = None
    latency_ms: Optional[float] = None
    interface: str = ""
    local_ip: str = ""
    gateway: str = ""
    route_raw: str = ""
    local_session: bool = False
    checked_at: float = 0.0
    error: str = ""


def run_command(args: List[str], timeout: float = 1.0) -> Tuple[int, str]:
    try:
        proc = subprocess.run(
            args,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=timeout,
            check=False,
        )
        return proc.returncode, proc.stdout.strip()
    except (OSError, subprocess.TimeoutExpired) as exc:
        return 127, str(exc)


def natural_rdp_key(name: str) -> Tuple[int, str]:
    match = re.fullmatch(r"lrdp(\d+)", name)
    return (int(match.group(1)) if match else 10**9, name)


def parse_metadata(text: str, script: Path) -> Optional[RdpProfile]:
    scalars: Dict[str, str] = {}
    logins: List[LoginProfile] = []
    for raw in text.splitlines():
        parts = raw.rstrip("\n").split("\t")
        if not parts:
            continue
        if parts[0] == "login" and len(parts) >= 3:
            logins.append(
                LoginProfile(
                    label=parts[1],
                    username=parts[2],
                    password_set=len(parts) >= 4 and parts[3] == "yes",
                )
            )
        elif len(parts) >= 2:
            scalars[parts[0]] = parts[1]
    name = scalars.get("name", script.name)
    target = scalars.get("target", "")
    if not re.fullmatch(r"lrdp\d+", name) or not target:
        return None
    try:
        port = int(scalars.get("port", "3389"))
    except ValueError:
        port = 3389
    return RdpProfile(
        name=name,
        label=scalars.get("label", name.upper()),
        target=target,
        port=port,
        script=str(script),
        logins=logins,
    )


def discover_rdps() -> List[RdpProfile]:
    profiles: List[RdpProfile] = []
    try:
        candidates = sorted(
            (p for p in APP_DIR.iterdir() if p.is_file() and re.fullmatch(r"lrdp\d+", p.name)),
            key=lambda p: natural_rdp_key(p.name),
        )
    except OSError:
        return []
    for script in candidates:
        code, output = run_command(["bash", str(script), "--metadata"], timeout=1.2)
        if code != 0:
            continue
        profile = parse_metadata(output, script)
        if profile:
            profiles.append(profile)
    return profiles


def state_path(profile: RdpProfile) -> Path:
    return STATE_ROOT / f"{profile.name}.conf"


def load_state(profile: RdpProfile) -> RdpState:
    state = RdpState()
    path = state_path(profile)
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError:
        lines = []
    values: Dict[str, str] = {}
    for line in lines:
        if "=" in line:
            key, value = line.split("=", 1)
            values[key.strip()] = value.strip()
    try:
        login_index = int(values.get("login_index", "1"))
    except ValueError:
        login_index = 1
    max_login = max(1, len(profile.logins))
    state.login_index = max(1, min(login_index, max_login))
    audio = values.get("audio_mode", "server")
    state.audio_mode = audio if audio in AUDIO_MODES else "server"
    mic = values.get("microphone", "no")
    state.microphone = mic if mic in ("yes", "no") else "no"
    primary = values.get("primary_monitor", "")
    state.primary_monitor = primary if (not primary or primary.isdigit()) else ""
    return state


def save_state(profile: RdpProfile, state: RdpState) -> None:
    STATE_ROOT.mkdir(parents=True, exist_ok=True)
    path = state_path(profile)
    tmp = path.with_suffix(path.suffix + ".tmp")
    content = (
        f"login_index={state.login_index}\n"
        f"audio_mode={state.audio_mode}\n"
        f"microphone={state.microphone}\n"
        f"primary_monitor={state.primary_monitor}\n"
    )
    old_umask = os.umask(0o077)
    try:
        tmp.write_text(content, encoding="utf-8")
        os.chmod(tmp, 0o600)
        os.replace(tmp, path)
    finally:
        os.umask(old_umask)
        try:
            tmp.unlink()
        except OSError:
            pass


def validate_target_ip(value: str) -> str:
    value = value.strip()
    try:
        address = ipaddress.ip_address(value)
    except ValueError as exc:
        raise ValueError("IP IPv4 inválido") from exc
    if address.version != 4:
        raise ValueError("use um endereço IPv4")
    return str(address)


def update_profile_target_file(profile: RdpProfile, target: str) -> None:
    target = validate_target_ip(target)
    path = Path(profile.script)
    try:
        original = path.read_text(encoding="utf-8")
    except OSError as exc:
        raise OSError(f"não foi possível ler {path}: {exc}") from exc

    pattern = re.compile(r'(?m)^(?P<prefix>[ \t]*LRDP_TARGET=)(?P<value>[^\r\n]*)(?P<ending>\r?)$')
    matches = list(pattern.finditer(original))
    if len(matches) != 1:
        raise ValueError(f"esperado exatamente um LRDP_TARGET em {path}")

    replacement = rf'\g<prefix>"{target}"\g<ending>'
    updated = pattern.sub(replacement, original, count=1)
    if updated == original:
        return

    try:
        with path.open("w", encoding="utf-8", newline="") as handle:
            handle.write(updated)
            handle.flush()
            os.fsync(handle.fileno())
    except OSError as exc:
        raise OSError(f"não foi possível gravar {path}: {exc}") from exc


def parse_monitor_output(text: str) -> List[Monitor]:
    monitors: List[Monitor] = []
    seen = set()
    pattern = re.compile(
        r"(?P<star>\*)?\s*\[(?P<id>\d+)\].*?"
        r"(?P<w>\d+)x(?P<h>\d+).*?"
        r"(?P<x>[+-]\d+)(?P<y>[+-]\d+)\s*$"
    )
    for line in text.splitlines():
        match = pattern.search(line)
        if not match:
            continue
        mid = int(match.group("id"))
        if mid in seen:
            continue
        seen.add(mid)
        monitors.append(
            Monitor(
                id=mid,
                width=int(match.group("w")),
                height=int(match.group("h")),
                x=int(match.group("x")),
                y=int(match.group("y")),
                local_primary=bool(match.group("star")),
            )
        )
    return monitors


def load_monitors() -> Tuple[List[Monitor], str]:
    executable = shutil.which("xfreerdp3")
    if not executable:
        return [], "xfreerdp3 não encontrado no PATH"
    _, output = run_command([executable, "/list:monitor"], timeout=1.5)
    return parse_monitor_output(output), output


def physical_monitor_order(monitors: Iterable[Monitor]) -> List[Monitor]:
    return sorted(monitors, key=lambda m: (m.x, m.y, m.id))


def effective_primary(state: RdpState, monitors: List[Monitor]) -> str:
    valid = {str(m.id) for m in monitors}
    if state.primary_monitor in valid:
        return state.primary_monitor
    for monitor in monitors:
        if monitor.local_primary:
            return str(monitor.id)
    return str(monitors[0].id) if monitors else ""


def monitor_order_for_command(state: RdpState, monitors: List[Monitor]) -> str:
    primary = effective_primary(state, monitors)
    if not primary:
        return ""
    ids = [str(m.id) for m in monitors]
    return ",".join([primary] + [mid for mid in ids if mid != primary])


def selected_login(profile: RdpProfile, state: RdpState) -> LoginProfile:
    if not profile.logins:
        return LoginProfile("Sem perfil", "?")
    idx = max(1, min(state.login_index, len(profile.logins))) - 1
    return profile.logins[idx]


def effective_command(profile: RdpProfile, state: RdpState, monitors: List[Monitor]) -> str:
    login = selected_login(profile, state)
    args = [
        "xfreerdp3",
        f"/v:{profile.target}",
        f"/u:{login.username}",
        "/multimon",
        f"/audio-mode:{state.audio_mode}",
        "/cert:ignore",
    ]
    order = monitor_order_for_command(state, monitors)
    if order:
        args.append(f"/monitors:{order}")
    if state.microphone == "yes":
        args.append("/microphone")
    if login.password_set:
        args.append("/p:<senha-oculta>")
    return " ".join(args)


def load_drm_outputs() -> List[DrmOutput]:
    outputs: List[DrmOutput] = []
    seen = set()
    for status_path in sorted(Path("/sys/class/drm").glob("card*-*/status")):
        parent = status_path.parent.name
        if "-" not in parent:
            continue
        name = parent.split("-", 1)[1]
        if name in seen:
            continue
        seen.add(name)
        try:
            status = status_path.read_text(encoding="ascii", errors="ignore").strip()
        except OSError:
            continue
        mode = ""
        modes_path = status_path.parent / "modes"
        try:
            mode = next((line.strip() for line in modes_path.read_text(encoding="ascii", errors="ignore").splitlines() if line.strip()), "")
        except OSError:
            pass
        outputs.append(DrmOutput(name=name, connected=status == "connected", mode=mode))
    return outputs


def local_ipv4_addresses() -> List[Tuple[str, str]]:
    executable = shutil.which("ip")
    if not executable:
        return []
    _, output = run_command([executable, "-br", "-4", "addr", "show"], timeout=0.8)
    result = []
    for line in output.splitlines():
        parts = line.split()
        if len(parts) < 3 or parts[1].upper() == "DOWN":
            continue
        iface = parts[0]
        for value in parts[2:]:
            if re.fullmatch(r"\d+\.\d+\.\d+\.\d+/\d+", value):
                result.append((iface, value))
    return result


def route_for_target(target: str) -> Tuple[str, str, str, str]:
    executable = shutil.which("ip")
    if not executable:
        return "", "", "", "ip não encontrado"
    _, output = run_command([executable, "-4", "route", "get", target], timeout=0.8)
    line = output.splitlines()[0] if output else ""
    tokens = line.split()
    iface = local_ip = gateway = ""
    for i, token in enumerate(tokens[:-1]):
        if token == "dev":
            iface = tokens[i + 1]
        elif token == "src":
            local_ip = tokens[i + 1]
        elif token == "via":
            gateway = tokens[i + 1]
    return iface, local_ip, gateway, line


def active_rdp_targets() -> set:
    targets = set()
    proc = Path("/proc")
    try:
        entries = list(proc.iterdir())
    except OSError:
        return targets
    for entry in entries:
        if not entry.name.isdigit():
            continue
        try:
            raw = (entry / "cmdline").read_bytes().replace(b"\x00", b" ").decode("utf-8", errors="ignore")
        except OSError:
            continue
        if "xfreerdp" not in raw:
            continue
        for match in re.finditer(r"/v:([^\s]+)", raw):
            targets.add(match.group(1))
    return targets


def probe_target(profile: RdpProfile, active_targets: set) -> ProbeResult:
    result = ProbeResult(checked_at=time.time(), local_session=profile.target in active_targets)
    iface, local_ip, gateway, raw = route_for_target(profile.target)
    result.interface = iface
    result.local_ip = local_ip
    result.gateway = gateway
    result.route_raw = raw
    start = time.monotonic()
    try:
        with socket.create_connection((profile.target, profile.port), timeout=0.45):
            pass
        result.online = True
        result.latency_ms = (time.monotonic() - start) * 1000.0
    except OSError as exc:
        result.online = False
        result.error = str(exc)
    return result


class ProbeWorker:
    def __init__(self, profiles: List[RdpProfile]):
        self._profiles = profiles
        self._lock = threading.Lock()
        self._results: Dict[str, ProbeResult] = {}
        self._stop = threading.Event()
        self._wake = threading.Event()
        self._thread = threading.Thread(target=self._run, name="lrdp-probe", daemon=True)

    def start(self) -> None:
        self._thread.start()

    def stop(self) -> None:
        self._stop.set()
        self._wake.set()
        self._thread.join(timeout=1.0)

    def update_profiles(self, profiles: List[RdpProfile]) -> None:
        with self._lock:
            self._profiles = list(profiles)
        self._wake.set()

    def refresh_now(self) -> None:
        self._wake.set()

    def snapshot(self) -> Dict[str, ProbeResult]:
        with self._lock:
            return {name: replace(value) for name, value in self._results.items()}

    def _run(self) -> None:
        while not self._stop.is_set():
            with self._lock:
                profiles = list(self._profiles)
            active = active_rdp_targets()
            results: Dict[str, ProbeResult] = {}
            if profiles:
                with ThreadPoolExecutor(max_workers=min(8, len(profiles))) as pool:
                    futures = {pool.submit(probe_target, profile, active): profile.name for profile in profiles}
                    for future in as_completed(futures):
                        name = futures[future]
                        try:
                            results[name] = future.result()
                        except Exception as exc:  # defensive: worker must never kill the TUI
                            results[name] = ProbeResult(online=None, error=str(exc), checked_at=time.time())
            with self._lock:
                self._results.update(results)
            self._wake.wait(PROBE_SECONDS)
            self._wake.clear()


def safe_add(win, y: int, x: int, text: str, attr: int = 0, max_width: Optional[int] = None) -> None:
    try:
        h, w = win.getmaxyx()
        if y < 0 or y >= h or x < 0 or x >= w:
            return
        room = max(0, w - x - 1)
        if max_width is not None:
            room = min(room, max_width)
        if room <= 0:
            return
        win.addnstr(y, x, str(text).replace("\n", " "), room, attr)
    except curses.error:
        pass


def fit(text: str, width: int) -> str:
    text = str(text).replace("\n", " ").replace("\r", " ")
    if width <= 0:
        return ""
    if len(text) <= width:
        return text
    return text[: max(0, width - 1)] + ("~" if width > 1 else "")


def wrap_text(text: str, width: int) -> List[str]:
    if width <= 4:
        return [fit(text, width)]
    words = text.split()
    lines: List[str] = []
    current = ""
    for word in words:
        candidate = word if not current else f"{current} {word}"
        if len(candidate) <= width:
            current = candidate
        else:
            if current:
                lines.append(current)
            current = word
    if current:
        lines.append(current)
    return lines or [""]


class LrdpTui:
    def __init__(self, stdscr):
        self.stdscr = stdscr
        self.profiles = discover_rdps()
        self.states: Dict[str, RdpState] = {p.name: load_state(p) for p in self.profiles}
        self.monitors, self.monitor_raw = load_monitors()
        self.drm_outputs = load_drm_outputs()
        self.addresses = local_ipv4_addresses()
        self.selected = 0
        self.list_scroll = 0
        self.mode = "main"
        self.previous_mode = "main"
        self.config_field = 0
        self.edit_state: Optional[RdpState] = None
        self.edit_target = ""
        self.monitor_candidate = ""
        self.message = "Pronto. Enter conecta usando a configuração salva."
        self.message_until = 0.0
        self.last_static_refresh = time.monotonic()
        self.click_rows: List[Tuple[int, int, int]] = []
        self.worker = ProbeWorker(self.profiles)
        self.attrs: Dict[str, int] = {}
        self._init_curses()

    def _init_curses(self) -> None:
        try:
            curses.curs_set(0)
        except curses.error:
            pass
        self.stdscr.keypad(True)
        self.stdscr.timeout(int(REFRESH_SECONDS * 1000))
        try:
            curses.mousemask(curses.ALL_MOUSE_EVENTS | getattr(curses, "REPORT_MOUSE_POSITION", 0))
        except curses.error:
            pass
        if curses.has_colors():
            curses.start_color()
            try:
                curses.use_default_colors()
            except curses.error:
                pass
            pairs = [
                (1, curses.COLOR_CYAN, -1),
                (2, curses.COLOR_WHITE, curses.COLOR_BLUE),
                (3, curses.COLOR_BLACK, curses.COLOR_CYAN),
                (4, curses.COLOR_GREEN, -1),
                (5, curses.COLOR_RED, -1),
                (6, curses.COLOR_YELLOW, -1),
                (7, curses.COLOR_MAGENTA, -1),
                (8, curses.COLOR_BLUE, -1),
            ]
            for number, fg, bg in pairs:
                try:
                    curses.init_pair(number, fg, bg)
                except curses.error:
                    pass
        self.attrs = {
            "border": curses.color_pair(1) | curses.A_BOLD,
            "header": curses.color_pair(2) | curses.A_BOLD,
            "selected": curses.color_pair(3) | curses.A_BOLD,
            "ok": curses.color_pair(4) | curses.A_BOLD,
            "error": curses.color_pair(5) | curses.A_BOLD,
            "warn": curses.color_pair(6) | curses.A_BOLD,
            "accent": curses.color_pair(7) | curses.A_BOLD,
            "muted": curses.A_DIM,
            "bold": curses.A_BOLD,
        }

    @property
    def profile(self) -> Optional[RdpProfile]:
        if not self.profiles:
            return None
        self.selected = max(0, min(self.selected, len(self.profiles) - 1))
        return self.profiles[self.selected]

    def state(self, profile: Optional[RdpProfile] = None) -> RdpState:
        profile = profile or self.profile
        if not profile:
            return RdpState()
        return self.states.setdefault(profile.name, load_state(profile))

    def set_message(self, message: str, seconds: float = 4.0) -> None:
        self.message = message
        self.message_until = time.monotonic() + seconds

    def refresh_static(self, force: bool = False) -> None:
        now = time.monotonic()
        if not force and now - self.last_static_refresh < STATIC_REFRESH_SECONDS:
            return
        selected_name = self.profile.name if self.profile else ""
        profiles = discover_rdps()
        if profiles:
            self.profiles = profiles
            self.states = {p.name: load_state(p) for p in self.profiles}
            if selected_name:
                for i, profile in enumerate(self.profiles):
                    if profile.name == selected_name:
                        self.selected = i
                        break
            self.worker.update_profiles(self.profiles)
        self.monitors, self.monitor_raw = load_monitors()
        self.drm_outputs = load_drm_outputs()
        self.addresses = local_ipv4_addresses()
        self.last_static_refresh = now

    def prep_box(self, win, label: str) -> None:
        try:
            win.erase()
            win.attron(self.attrs["border"])
            win.box()
            win.attroff(self.attrs["border"])
            _, width = win.getmaxyx()
            title = f" {label} "
            x = max(2, (width - len(title)) // 2)
            safe_add(win, 0, x, title, self.attrs["border"], width - x - 2)
        except curses.error:
            pass

    def draw_header_footer(self) -> None:
        h, w = self.stdscr.getmaxyx()
        profile = self.profile
        host = socket.gethostname()
        session = os.environ.get("XDG_SESSION_TYPE", "?").upper()
        desktop = os.environ.get("XDG_CURRENT_DESKTOP", "Ubuntu")
        title = " LRDP CONTROL CENTER :: FREE RDP / MONITOR BIOS "
        try:
            self.stdscr.attron(self.attrs["header"])
            self.stdscr.hline(0, 0, " ", max(1, w - 1))
            safe_add(self.stdscr, 0, max(0, (w - len(title)) // 2), title, self.attrs["header"])
            self.stdscr.attroff(self.attrs["header"])
        except curses.error:
            pass
        summary = (
            f" {host}  |  {desktop} / {session}  |  monitores ativos: {len(self.monitors)}"
            f"  |  RDPs: {len(self.profiles)}"
        )
        if profile:
            summary += f"  |  selecionado: {profile.label} -> {profile.target}:{profile.port}"
        safe_add(self.stdscr, 1, 0, fit(summary, w - 1), self.attrs["muted"])

        footer = " ENTER Conectar   F2 Configurar   F3 Monitores   F4 Rede   F5 Atualizar   F1 Ajuda   Q Sair "
        if self.mode == "config":
            footer = " ↑↓ Campo   ENTER Editar IP/alterar   ←→ Alterar opções   F10/S Salvar   ESC Cancelar "
        elif self.mode == "monitors":
            footer = " ←→/↑↓ Escolher monitor   ENTER Definir principal   F5 Atualizar   ESC/F3 Voltar "
        elif self.mode == "network":
            footer = " ↑↓ Selecionar RDP   F5 Atualizar diagnóstico   ENTER Conectar   ESC/F4 Voltar "
        elif self.mode == "help":
            footer = " F1 / ESC / ENTER Voltar "
        try:
            self.stdscr.attron(self.attrs["header"])
            self.stdscr.hline(h - 2, 0, " ", max(1, w - 1))
            safe_add(self.stdscr, h - 2, 0, fit(footer, w - 1), self.attrs["header"])
            self.stdscr.attroff(self.attrs["header"])
        except curses.error:
            pass
        message = self.message
        if self.message_until and time.monotonic() > self.message_until:
            message = "Setas escolhem o RDP. Enter conecta sem perguntar de novo."
        safe_add(self.stdscr, h - 1, 0, fit(f" {message}", w - 1), self.attrs["muted"])

    def draw_small_terminal(self) -> None:
        h, w = self.stdscr.getmaxyx()
        self.stdscr.erase()
        msg = "Aumente/maximize o terminal: LRDP precisa de pelo menos 100x28."
        safe_add(self.stdscr, max(0, h // 2), max(0, (w - len(msg)) // 2), msg, self.attrs["warn"])
        self.stdscr.refresh()

    def draw(self) -> None:
        h, w = self.stdscr.getmaxyx()
        if h < 28 or w < 100:
            self.draw_small_terminal()
            return
        self.stdscr.erase()
        self.draw_header_footer()
        if self.mode == "main":
            self.draw_main()
        elif self.mode == "config":
            self.draw_config()
        elif self.mode == "monitors":
            self.draw_monitors_screen()
        elif self.mode == "network":
            self.draw_network_screen()
        elif self.mode == "help":
            self.draw_main()
            self.draw_help_overlay()
        self.stdscr.refresh()

    def draw_main(self) -> None:
        h, w = self.stdscr.getmaxyx()
        top = 2
        content_h = h - 4
        left_w = max(36, min(50, int(w * 0.34)))
        right_w = w - left_w
        mon_h = max(13, int(content_h * 0.58))
        detail_h = content_h - mon_h
        left = self.stdscr.derwin(content_h, left_w, top, 0)
        mon = self.stdscr.derwin(mon_h, right_w, top, left_w)
        detail = self.stdscr.derwin(detail_h, right_w, top + mon_h, left_w)
        self.draw_rdp_list(left, top)
        profile = self.profile
        state = self.state(profile)
        self.draw_monitor_box(mon, state, "TOPOLOGIA DOS MONITORES")
        self.draw_selected_details(detail, profile, state)

    def draw_rdp_list(self, win, absolute_top: int) -> None:
        self.prep_box(win, "RDPs DISPONÍVEIS")
        h, w = win.getmaxyx()
        self.click_rows = []
        if not self.profiles:
            safe_add(win, 2, 2, "Nenhum apps/lrdp/lrdpN encontrado.", self.attrs["error"])
            return
        probes = self.worker.snapshot()
        item_h = 4
        visible = max(1, (h - 3) // item_h)
        if self.selected < self.list_scroll:
            self.list_scroll = self.selected
        if self.selected >= self.list_scroll + visible:
            self.list_scroll = self.selected - visible + 1
        self.list_scroll = max(0, min(self.list_scroll, max(0, len(self.profiles) - visible)))
        for slot, index in enumerate(range(self.list_scroll, min(len(self.profiles), self.list_scroll + visible))):
            profile = self.profiles[index]
            state = self.state(profile)
            login = selected_login(profile, state)
            probe = probes.get(profile.name, ProbeResult())
            row = 1 + slot * item_h
            selected = index == self.selected
            base = self.attrs["selected"] if selected else 0
            if selected:
                for dy in range(3):
                    try:
                        win.hline(row + dy, 1, " ", max(1, w - 2), base)
                    except curses.error:
                        pass
            marker = "▶" if selected else " "
            if probe.online is True:
                status = "ONLINE"
                status_attr = self.attrs["selected"] if selected else self.attrs["ok"]
            elif probe.online is False:
                status = "OFFLINE"
                status_attr = self.attrs["selected"] if selected else self.attrs["error"]
            else:
                status = "..."
                status_attr = self.attrs["selected"] if selected else self.attrs["warn"]
            safe_add(win, row, 2, f"{marker} {index + 1:>2}. {profile.label}", base | curses.A_BOLD, w - 4)
            safe_add(win, row, max(2, w - len(status) - 3), status, status_attr)
            safe_add(win, row + 1, 4, f"{profile.target}:{profile.port}  •  {login.label} ({login.username})", base, w - 6)
            primary = effective_primary(state, self.monitors) or "auto"
            mic = "ON" if state.microphone == "yes" else "OFF"
            sess = " • SESSÃO ATIVA" if probe.local_session else ""
            summary = f"Áudio: {AUDIO_LABELS.get(state.audio_mode, state.audio_mode)}  •  Mic: {mic}  •  Principal: {primary}{sess}"
            safe_add(win, row + 2, 4, summary, base | (curses.A_BOLD if probe.local_session else 0), w - 6)
            self.click_rows.append((absolute_top + row, absolute_top + row + 2, index))
        if len(self.profiles) > visible:
            safe_add(win, h - 2, 2, f"{self.selected + 1}/{len(self.profiles)}  ↑↓ para navegar", self.attrs["muted"])

    def draw_monitor_box(self, win, state: RdpState, title: str, candidate: str = "") -> None:
        self.prep_box(win, title)
        h, w = win.getmaxyx()
        if not self.monitors:
            safe_add(win, 2, 2, "FreeRDP não retornou monitores.", self.attrs["error"])
            safe_add(win, 3, 2, fit(self.monitor_raw or "Use F5 para tentar novamente.", w - 4), self.attrs["muted"])
            return
        self.draw_monitor_topology(win, 2, 2, h - 5, w - 4, state, candidate)
        ordered = "  ".join(f"[{m.id}] {m.width}x{m.height}" for m in physical_monitor_order(self.monitors))
        safe_add(win, h - 2, 2, fit(f"Esquerda → direita: {ordered}", w - 4), self.attrs["muted"])

    def draw_monitor_topology(self, win, top: int, left: int, height: int, width: int, state: RdpState, candidate: str = "") -> None:
        if not self.monitors or height < 5 or width < 12:
            return
        min_x = min(m.x for m in self.monitors)
        max_x = max(m.x + m.width for m in self.monitors)
        min_y = min(m.y for m in self.monitors)
        max_y = max(m.y + m.height for m in self.monitors)
        total_x = max(1.0, float(max_x - min_x))
        # Terminal cells are roughly twice as tall as wide; halve Y so the
        # drawn monitor keeps a useful visual aspect ratio.
        total_y = max(1.0, float(max_y - min_y) / 2.0)
        scale = min(max(0.0001, (width - 1) / total_x), max(0.0001, (height - 1) / total_y))
        used_w = max(1, int(round(total_x * scale)))
        used_h = max(1, int(round(total_y * scale)))
        x_pad = max(0, (width - used_w) // 2)
        y_pad = max(0, (height - used_h) // 2)
        rdp_primary = effective_primary(state, self.monitors)
        for monitor in self.monitors:
            x = left + x_pad + int(round((monitor.x - min_x) * scale))
            y = top + y_pad + int(round(((monitor.y - min_y) / 2.0) * scale))
            box_w = max(8, int(round(monitor.width * scale)))
            box_h = max(4, int(round((monitor.height / 2.0) * scale)))
            box_w = min(box_w, left + width - x)
            box_h = min(box_h, top + height - y)
            if box_w < 4 or box_h < 3:
                continue
            is_candidate = candidate and str(monitor.id) == candidate
            is_rdp_primary = str(monitor.id) == rdp_primary
            attr = self.attrs["selected"] if is_candidate else (self.attrs["accent"] if is_rdp_primary else self.attrs["border"])
            self.draw_rect(win, y, x, box_h, box_w, attr)
            flags = []
            if monitor.local_primary:
                flags.append("LOCAL★")
            if is_rdp_primary:
                flags.append("RDP★")
            if is_candidate:
                flags.append("ESCOLHA")
            safe_add(win, y + 1, x + 2, fit(f"MON {monitor.id}", max(1, box_w - 4)), attr | curses.A_BOLD, max(1, box_w - 4))
            if box_h >= 5:
                safe_add(win, y + 2, x + 2, fit(f"{monitor.width}x{monitor.height}", max(1, box_w - 4)), attr, max(1, box_w - 4))
            if box_h >= 6:
                safe_add(win, y + 3, x + 2, fit(f"x={monitor.x} y={monitor.y}", max(1, box_w - 4)), attr, max(1, box_w - 4))
            if box_h >= 7 and flags:
                safe_add(win, y + 4, x + 2, fit(" ".join(flags), max(1, box_w - 4)), attr | curses.A_BOLD, max(1, box_w - 4))

    def draw_rect(self, win, y: int, x: int, height: int, width: int, attr: int) -> None:
        try:
            win.attron(attr)
            win.hline(y, x + 1, curses.ACS_HLINE, max(0, width - 2))
            win.hline(y + height - 1, x + 1, curses.ACS_HLINE, max(0, width - 2))
            win.vline(y + 1, x, curses.ACS_VLINE, max(0, height - 2))
            win.vline(y + 1, x + width - 1, curses.ACS_VLINE, max(0, height - 2))
            win.addch(y, x, curses.ACS_ULCORNER)
            win.addch(y, x + width - 1, curses.ACS_URCORNER)
            win.addch(y + height - 1, x, curses.ACS_LLCORNER)
            win.addch(y + height - 1, x + width - 1, curses.ACS_LRCORNER)
            win.attroff(attr)
        except curses.error:
            pass

    def draw_selected_details(self, win, profile: Optional[RdpProfile], state: RdpState) -> None:
        self.prep_box(win, "RDP SELECIONADO / ROTA / COMANDO")
        h, w = win.getmaxyx()
        if not profile:
            safe_add(win, 2, 2, "Nenhum RDP disponível.", self.attrs["error"])
            return
        probe = self.worker.snapshot().get(profile.name, ProbeResult())
        login = selected_login(profile, state)
        primary = effective_primary(state, self.monitors) or "automático"
        status_text = "AGUARDANDO"
        status_attr = self.attrs["warn"]
        if probe.online is True:
            status_text = f"ONLINE / TCP {profile.port} aberto"
            if probe.latency_ms is not None:
                status_text += f" / {probe.latency_ms:.0f} ms"
            status_attr = self.attrs["ok"]
        elif probe.online is False:
            status_text = f"OFFLINE / TCP {profile.port} sem resposta"
            status_attr = self.attrs["error"]
        rows = [
            ("Destino", f"{profile.target}:{profile.port}", self.attrs["bold"]),
            ("Remoto", status_text, status_attr),
            ("Sessão", "xfreerdp3 ATIVO" if probe.local_session else "não detectada", self.attrs["ok"] if probe.local_session else self.attrs["muted"]),
            ("Login", f"{login.label} ({login.username})", 0),
            ("Áudio", AUDIO_LABELS.get(state.audio_mode, state.audio_mode), 0),
            ("Microfone", "REDIRECIONADO" if state.microphone == "yes" else "desligado", self.attrs["ok"] if state.microphone == "yes" else 0),
            ("Principal", f"monitor {primary}", self.attrs["accent"]),
            ("Rota", self.route_text(probe, profile), 0),
        ]
        y = 1
        for key, value, attr in rows:
            if y >= h - 2:
                break
            safe_add(win, y, 2, f"{key:>10}: ", self.attrs["muted"] | curses.A_BOLD, 12)
            safe_add(win, y, 14, fit(value, w - 16), attr, w - 16)
            y += 1
        if y < h - 2:
            safe_add(win, y, 2, "   Comando: ", self.attrs["muted"] | curses.A_BOLD, 12)
            cmd_lines = wrap_text(effective_command(profile, state, self.monitors), max(10, w - 16))
            for line_no, line in enumerate(cmd_lines[: max(1, h - y - 2)]):
                safe_add(win, y + line_no, 14 if line_no == 0 else 4, line, self.attrs["bold"] if line_no == 0 else 0, w - (16 if line_no == 0 else 6))

    def route_text(self, probe: ProbeResult, profile: RdpProfile) -> str:
        if not probe.interface and not probe.local_ip:
            return f"origem ? → {profile.target}"
        text = f"{probe.local_ip or '?'} → {probe.interface or '?'}"
        if probe.gateway:
            text += f" → gateway {probe.gateway}"
        text += f" → {profile.target}"
        return text

    def draw_config(self) -> None:
        h, w = self.stdscr.getmaxyx()
        profile = self.profile
        if not profile or self.edit_state is None:
            self.mode = "main"
            return
        content_h = h - 4
        left_w = max(46, min(62, int(w * 0.42)))
        fields_win = self.stdscr.derwin(content_h, left_w, 2, 0)
        monitor_win = self.stdscr.derwin(content_h, w - left_w, 2, left_w)
        self.prep_box(fields_win, f"F2 CONFIGURAÇÃO :: {profile.label}")
        fh, fw = fields_win.getmaxyx()
        safe_add(fields_win, 2, 2, f"Arquivo: {Path(profile.script).name}  |  porta: {profile.port}", self.attrs["bold"])
        safe_add(fields_win, 3, 2, "F10/S salva opções e grava o IP no arquivo LRDP_TARGET.", self.attrs["muted"])
        values = self.config_values(profile, self.edit_state)
        explanations = [
            "ENTER edita. Ao salvar, altera LRDP_TARGET no arquivo deste RDP.",
            "Credencial usada na autenticação. A senha fica oculta.",
            "Onde o som do Windows remoto será reproduzido.",
            "Liga/desliga o redirecionamento do microfone do Ubuntu.",
            "Primeiro ID em /monitors; vira o principal da sessão RDP.",
        ]
        labels = ["IP de destino", "Login", "Áudio", "Microfone", "Monitor principal"]
        start = 5
        for idx, (label, value) in enumerate(zip(labels, values)):
            y = start + idx * 3
            selected = idx == self.config_field
            attr = self.attrs["selected"] if selected else self.attrs["border"]
            if selected:
                try:
                    fields_win.hline(y, 1, " ", fw - 2, self.attrs["selected"])
                    fields_win.hline(y + 1, 1, " ", fw - 2, self.attrs["selected"])
                except curses.error:
                    pass
            safe_add(fields_win, y, 3, f"{label}:", attr | curses.A_BOLD, fw - 6)
            display_value = f"[ ENTER editar ]  {value}" if idx == 0 else f"<  {value}  >"
            safe_add(fields_win, y + 1, 5, fit(display_value, fw - 10), attr, fw - 10)
            safe_add(fields_win, y + 2, 5, fit(explanations[idx], fw - 10), self.attrs["muted"], fw - 10)
        fixed_y = start + len(labels) * 3 + 1
        if fixed_y + 4 < fh:
            safe_add(fields_win, fixed_y, 2, "PARÂMETROS FIXOS", self.attrs["accent"])
            fixed = ["/multimon = ativo", "/cert:ignore = ativo", f"porta RDP = {profile.port}"]
            for i, line in enumerate(fixed):
                safe_add(fields_win, fixed_y + 1 + i, 4, line, self.attrs["muted"])
        self.draw_monitor_box(monitor_win, self.edit_state, "PRÉVIA / TOPOLOGIA")

    def config_values(self, profile: RdpProfile, state: RdpState) -> List[str]:
        login = selected_login(profile, state)
        primary = effective_primary(state, self.monitors) or "automático"
        return [
            self.edit_target or profile.target,
            f"{login.label} ({login.username})",
            AUDIO_LABELS.get(state.audio_mode, state.audio_mode),
            "REDIRECIONADO" if state.microphone == "yes" else "desligado",
            f"[{primary}] {self.monitor_description(primary)}" if primary else "automático",
        ]

    def monitor_description(self, monitor_id: str) -> str:
        for monitor in self.monitors:
            if str(monitor.id) == str(monitor_id):
                return f"{monitor.width}x{monitor.height} @ {monitor.x},{monitor.y}"
        return "não detectado"

    def draw_monitors_screen(self) -> None:
        h, w = self.stdscr.getmaxyx()
        profile = self.profile
        state = self.state(profile)
        content_h = h - 4
        left_w = max(34, min(48, int(w * 0.31)))
        list_win = self.stdscr.derwin(content_h, left_w, 2, 0)
        wall_win = self.stdscr.derwin(content_h, w - left_w, 2, left_w)
        self.prep_box(list_win, "F3 MONITORES / PRINCIPAL")
        lh, lw = list_win.getmaxyx()
        if not profile:
            safe_add(list_win, 2, 2, "Nenhum RDP selecionado.", self.attrs["error"])
            return
        current = effective_primary(state, self.monitors)
        safe_add(list_win, 2, 2, f"RDP: {profile.label}", self.attrs["bold"])
        safe_add(list_win, 3, 2, f"Principal salvo/efetivo: [{current or 'auto'}]", self.attrs["accent"])
        safe_add(list_win, 4, 2, "Escolha abaixo e pressione ENTER.", self.attrs["muted"])
        y = 6
        for monitor in physical_monitor_order(self.monitors):
            candidate = str(monitor.id) == self.monitor_candidate
            attr = self.attrs["selected"] if candidate else 0
            if candidate:
                try:
                    list_win.hline(y, 1, " ", lw - 2, attr)
                    list_win.hline(y + 1, 1, " ", lw - 2, attr)
                except curses.error:
                    pass
            flags = []
            if monitor.local_primary:
                flags.append("LOCAL★")
            if str(monitor.id) == current:
                flags.append("RDP★")
            safe_add(list_win, y, 3, f"[{monitor.id}] {monitor.width}x{monitor.height}", attr | curses.A_BOLD, lw - 6)
            safe_add(list_win, y + 1, 5, f"x={monitor.x} y={monitor.y} {' '.join(flags)}", attr, lw - 8)
            y += 3
        y = min(lh - 6, y + 1)
        safe_add(list_win, y, 2, "SAÍDAS FÍSICAS (DRM)", self.attrs["accent"])
        y += 1
        if not self.drm_outputs:
            safe_add(list_win, y, 4, "Sem dados DRM disponíveis.", self.attrs["muted"])
        else:
            for output in self.drm_outputs[: max(0, lh - y - 2)]:
                status = "ON" if output.connected else "OFF"
                attr = self.attrs["ok"] if output.connected else self.attrs["error"]
                text = f"{output.name}: {status}"
                if output.mode:
                    text += f" {output.mode}"
                safe_add(list_win, y, 4, fit(text, lw - 8), attr, lw - 8)
                y += 1
        self.draw_monitor_box(wall_win, state, "MAPA FÍSICO / POSIÇÃO / TAMANHO", self.monitor_candidate)

    def draw_network_screen(self) -> None:
        h, w = self.stdscr.getmaxyx()
        content_h = h - 4
        left_w = max(42, min(58, int(w * 0.38)))
        local_win = self.stdscr.derwin(content_h, left_w, 2, 0)
        remote_win = self.stdscr.derwin(content_h, w - left_w, 2, left_w)
        self.prep_box(local_win, "F4 UBUNTU / REDE LOCAL")
        self.prep_box(remote_win, "ROTAS / DESTINOS RDP")
        lh, lw = local_win.getmaxyx()
        safe_add(local_win, 2, 2, f"Host: {socket.gethostname()}", self.attrs["bold"])
        safe_add(local_win, 3, 2, f"Desktop: {os.environ.get('XDG_CURRENT_DESKTOP', '?')}", 0)
        safe_add(local_win, 4, 2, f"Sessão: {os.environ.get('XDG_SESSION_TYPE', '?')}  Display: {os.environ.get('WAYLAND_DISPLAY') or os.environ.get('DISPLAY') or '?'}", 0)
        safe_add(local_win, 6, 2, "IPv4 locais", self.attrs["accent"])
        y = 7
        if not self.addresses:
            safe_add(local_win, y, 4, "Não foi possível ler 'ip -br -4 addr'.", self.attrs["muted"])
            y += 1
        else:
            for iface, address in self.addresses:
                safe_add(local_win, y, 4, f"{iface:<14} {address}", 0, lw - 8)
                y += 1
        y += 1
        safe_add(local_win, y, 2, "Monitores físicos / DRM", self.attrs["accent"])
        y += 1
        for output in self.drm_outputs[: max(0, lh - y - 2)]:
            attr = self.attrs["ok"] if output.connected else self.attrs["error"]
            safe_add(local_win, y, 4, f"{output.name:<14} {'ON' if output.connected else 'OFF'} {output.mode}", attr, lw - 8)
            y += 1

        probes = self.worker.snapshot()
        rh, rw = remote_win.getmaxyx()
        y = 2
        for idx, profile in enumerate(self.profiles):
            if y >= rh - 4:
                break
            probe = probes.get(profile.name, ProbeResult())
            selected = idx == self.selected
            attr = self.attrs["selected"] if selected else 0
            if selected:
                try:
                    remote_win.hline(y, 1, " ", rw - 2, attr)
                    remote_win.hline(y + 1, 1, " ", rw - 2, attr)
                    remote_win.hline(y + 2, 1, " ", rw - 2, attr)
                except curses.error:
                    pass
            status = "ONLINE" if probe.online is True else ("OFFLINE" if probe.online is False else "AGUARDANDO")
            safe_add(remote_win, y, 3, f"{idx + 1}. {profile.label}  {profile.target}:{profile.port}  [{status}]", attr | curses.A_BOLD, rw - 6)
            route = self.route_text(probe, profile)
            safe_add(remote_win, y + 1, 5, fit(route, rw - 10), attr, rw - 10)
            session = "SESSÃO xfreerdp3 ATIVA" if probe.local_session else "sem processo local detectado"
            safe_add(remote_win, y + 2, 5, fit(session, rw - 10), attr | (curses.A_BOLD if probe.local_session else 0), rw - 10)
            y += 4
        if self.profile and y < rh - 2:
            safe_add(remote_win, y, 2, "Comando efetivo selecionado:", self.attrs["accent"])
            cmd = effective_command(self.profile, self.state(), self.monitors)
            for line in wrap_text(cmd, max(10, rw - 8))[: max(1, rh - y - 2)]:
                y += 1
                safe_add(remote_win, y, 4, line, 0, rw - 8)

    def draw_help_overlay(self) -> None:
        h, w = self.stdscr.getmaxyx()
        oh = min(22, h - 6)
        ow = min(84, w - 8)
        top = max(2, (h - oh) // 2)
        left = max(0, (w - ow) // 2)
        win = curses.newwin(oh, ow, top, left)
        self.prep_box(win, "AJUDA / CONTROLES")
        lines = [
            ("Enter", "abre o RDP selecionado usando a última configuração; não pergunta tudo de novo"),
            ("↑ / ↓", "navega entre RDP 1, 2, 3... descobertos automaticamente em apps/lrdp"),
            ("1..9", "seleciona rapidamente um RDP pelo número"),
            ("F2", "configura IP de destino, login, áudio, microfone e monitor principal"),
            ("F3", "mapa de monitores com posição/tamanho; Enter define o principal do RDP"),
            ("F4", "diagnóstico Ubuntu/rede: IP local, interface, gateway, destino e sessão ativa"),
            ("F5", "recarrega monitores/RDPs e força novo teste de rede"),
            ("F10/S", "salva F2; se o IP mudou, grava LRDP_TARGET no arquivo lrdpN"),
            ("Mouse", "clique seleciona um RDP; duplo clique conecta quando o terminal suporta"),
            ("Q", "sai somente da TUI; sessões RDP já abertas continuam rodando"),
        ]
        y = 2
        for key, desc in lines:
            safe_add(win, y, 3, f"{key:<10}", self.attrs["accent"])
            safe_add(win, y, 15, fit(desc, ow - 18), 0, ow - 18)
            y += 1
        y += 1
        safe_add(win, y, 3, "Segurança:", self.attrs["warn"])
        safe_add(win, y, 15, "senhas nunca são exibidas na TUI nem no comando de diagnóstico.", 0, ow - 18)
        win.refresh()

    def begin_config(self) -> None:
        profile = self.profile
        if not profile:
            self.set_message("Nenhum RDP para configurar.")
            return
        self.edit_state = replace(self.state(profile))
        self.edit_target = profile.target
        if not self.edit_state.primary_monitor:
            self.edit_state.primary_monitor = effective_primary(self.edit_state, self.monitors)
        self.config_field = 0
        self.mode = "config"

    def cycle_config(self, delta: int) -> None:
        profile = self.profile
        if not profile or self.edit_state is None:
            return
        if self.config_field == 1 and profile.logins:
            count = len(profile.logins)
            self.edit_state.login_index = ((self.edit_state.login_index - 1 + delta) % count) + 1
        elif self.config_field == 2:
            index = AUDIO_MODES.index(self.edit_state.audio_mode) if self.edit_state.audio_mode in AUDIO_MODES else 1
            self.edit_state.audio_mode = AUDIO_MODES[(index + delta) % len(AUDIO_MODES)]
        elif self.config_field == 3:
            self.edit_state.microphone = "no" if self.edit_state.microphone == "yes" else "yes"
        elif self.config_field == 4 and self.monitors:
            ordered = physical_monitor_order(self.monitors)
            ids = [str(m.id) for m in ordered]
            current = effective_primary(self.edit_state, self.monitors)
            index = ids.index(current) if current in ids else 0
            self.edit_state.primary_monitor = ids[(index + delta) % len(ids)]

    def edit_target_ip(self) -> None:
        profile = self.profile
        if not profile or self.edit_state is None:
            return
        h, w = self.stdscr.getmaxyx()
        box_w = min(66, max(44, w - 12))
        box_h = 9
        y = max(1, (h - box_h) // 2)
        x = max(1, (w - box_w) // 2)
        win = self.stdscr.derwin(box_h, box_w, y, x)
        value = self.edit_target or profile.target
        cursor = len(value)
        try:
            curses.curs_set(1)
        except curses.error:
            pass
        try:
            while True:
                self.prep_box(win, f"EDITAR IP :: {profile.label}")
                safe_add(win, 2, 3, "IPv4 do computador remoto:", self.attrs["bold"], box_w - 6)
                field_w = max(8, box_w - 8)
                shown = fit(value, field_w)
                safe_add(win, 4, 4, " " * field_w, self.attrs["selected"], field_w)
                safe_add(win, 4, 4, shown, self.attrs["selected"], field_w)
                safe_add(win, 6, 3, "ENTER confirma apenas na edição; F10/S grava no arquivo. ESC cancela.", self.attrs["muted"], box_w - 6)
                try:
                    win.move(4, min(4 + cursor, 4 + field_w - 1))
                except curses.error:
                    pass
                win.refresh()
                key = win.getch()
                if key in (27,):
                    return
                if key in (10, 13, curses.KEY_ENTER):
                    try:
                        self.edit_target = validate_target_ip(value)
                    except ValueError as exc:
                        self.set_message(f"IP não alterado: {exc}.", 6)
                        return
                    self.set_message(f"IP preparado: {self.edit_target}. Pressione F10/S para gravar.")
                    return
                if key in (curses.KEY_LEFT,):
                    cursor = max(0, cursor - 1)
                elif key in (curses.KEY_RIGHT,):
                    cursor = min(len(value), cursor + 1)
                elif key == curses.KEY_HOME:
                    cursor = 0
                elif key == curses.KEY_END:
                    cursor = len(value)
                elif key in (curses.KEY_BACKSPACE, 127, 8):
                    if cursor > 0:
                        value = value[: cursor - 1] + value[cursor:]
                        cursor -= 1
                elif key == curses.KEY_DC:
                    if cursor < len(value):
                        value = value[:cursor] + value[cursor + 1 :]
                elif ord("0") <= key <= ord("9") or key == ord("."):
                    if len(value) < 15:
                        value = value[:cursor] + chr(key) + value[cursor:]
                        cursor += 1
        finally:
            try:
                curses.curs_set(0)
            except curses.error:
                pass

    def save_config(self) -> None:
        profile = self.profile
        if not profile or self.edit_state is None:
            return
        try:
            target = validate_target_ip(self.edit_target or profile.target)
            if target != profile.target:
                update_profile_target_file(profile, target)
                profile.target = target
        except (OSError, ValueError) as exc:
            self.set_message(f"ERRO ao salvar IP de {profile.label}: {exc}", 8)
            return
        save_state(profile, self.edit_state)
        self.states[profile.name] = replace(self.edit_state)
        self.worker.update_profiles(self.profiles)
        self.worker.refresh_now()
        self.mode = "main"
        self.edit_state = None
        self.edit_target = ""
        self.set_message(f"Configuração de {profile.label} salva; IP no arquivo: {profile.target}.")

    def begin_monitors(self) -> None:
        profile = self.profile
        if not profile:
            self.set_message("Nenhum RDP selecionado.")
            return
        if not self.monitors:
            self.set_message("Nenhum monitor detectado pelo FreeRDP.")
        self.monitor_candidate = effective_primary(self.state(profile), self.monitors)
        self.mode = "monitors"

    def cycle_monitor_candidate(self, delta: int) -> None:
        if not self.monitors:
            return
        ordered = physical_monitor_order(self.monitors)
        ids = [str(m.id) for m in ordered]
        index = ids.index(self.monitor_candidate) if self.monitor_candidate in ids else 0
        self.monitor_candidate = ids[(index + delta) % len(ids)]

    def apply_monitor_candidate(self) -> None:
        profile = self.profile
        if not profile or not self.monitor_candidate:
            return
        state = replace(self.state(profile))
        state.primary_monitor = self.monitor_candidate
        save_state(profile, state)
        self.states[profile.name] = state
        self.mode = "main"
        self.set_message(f"Monitor [{self.monitor_candidate}] definido como principal de {profile.label}.")

    def move_selection(self, delta: int) -> None:
        if not self.profiles:
            return
        self.selected = (self.selected + delta) % len(self.profiles)
        if self.mode == "monitors":
            self.monitor_candidate = effective_primary(self.state(), self.monitors)

    def launch_selected(self) -> None:
        profile = self.profile
        if not profile:
            self.set_message("Nenhum RDP disponível.")
            return
        if not shutil.which("xfreerdp3"):
            self.set_message("ERRO: xfreerdp3 não encontrado no PATH.", 6)
            return
        LOG_ROOT.mkdir(parents=True, exist_ok=True)
        log_path = LOG_ROOT / f"{profile.name}.log"
        env = os.environ.copy()
        env["LRDP_STATE_ROOT"] = str(STATE_ROOT)
        try:
            with open(log_path, "ab", buffering=0) as log_file:
                proc = subprocess.Popen(
                    ["bash", profile.script, "--saved"],
                    stdin=subprocess.DEVNULL,
                    stdout=log_file,
                    stderr=subprocess.STDOUT,
                    cwd=str(APP_DIR),
                    env=env,
                    start_new_session=True,
                    close_fds=True,
                )
            self.set_message(f"{profile.label} iniciado em segundo plano (PID {proc.pid}). Log: {log_path}", 7)
            self.worker.refresh_now()
        except OSError as exc:
            self.set_message(f"Falha ao iniciar {profile.label}: {exc}", 7)

    def force_refresh(self) -> None:
        self.refresh_static(force=True)
        self.worker.refresh_now()
        self.set_message("RDPs, monitores e diagnóstico de rede atualizados.")

    def handle_mouse(self) -> None:
        try:
            _, mx, my, _, bstate = curses.getmouse()
        except curses.error:
            return
        if self.mode != "main":
            return
        for y0, y1, index in self.click_rows:
            if y0 <= my <= y1:
                self.selected = index
                if bstate & getattr(curses, "BUTTON1_DOUBLE_CLICKED", 0):
                    self.launch_selected()
                break

    def handle_key(self, key: int) -> bool:
        esc = 27
        if key in (ord("q"), ord("Q"), 3) and self.mode == "main":
            return False
        if key == curses.KEY_RESIZE:
            return True
        if key == curses.KEY_MOUSE:
            self.handle_mouse()
            return True
        if key in (getattr(curses, "KEY_F1", -1001),):
            if self.mode == "help":
                self.mode = self.previous_mode
            else:
                self.previous_mode = self.mode
                self.mode = "help"
            return True
        if self.mode == "help":
            if key in (esc, 10, 13, ord(" ")):
                self.mode = self.previous_mode
            return True
        if self.mode == "main":
            if key in (curses.KEY_UP, ord("k")):
                self.move_selection(-1)
            elif key in (curses.KEY_DOWN, ord("j")):
                self.move_selection(1)
            elif key == curses.KEY_HOME:
                self.selected = 0
            elif key == curses.KEY_END and self.profiles:
                self.selected = len(self.profiles) - 1
            elif key in (10, 13, curses.KEY_ENTER):
                self.launch_selected()
            elif key == getattr(curses, "KEY_F2", -1002):
                self.begin_config()
            elif key == getattr(curses, "KEY_F3", -1003):
                self.begin_monitors()
            elif key == getattr(curses, "KEY_F4", -1004):
                self.mode = "network"
            elif key in (getattr(curses, "KEY_F5", -1005), ord("r"), ord("R")):
                self.force_refresh()
            elif ord("1") <= key <= ord("9"):
                index = key - ord("1")
                if index < len(self.profiles):
                    self.selected = index
            return True
        if self.mode == "config":
            if key == esc:
                self.mode = "main"
                self.edit_state = None
                self.edit_target = ""
                self.set_message("Alterações descartadas.")
            elif key in (curses.KEY_UP, ord("k")):
                self.config_field = (self.config_field - 1) % 5
            elif key in (curses.KEY_DOWN, ord("j"), 9):
                self.config_field = (self.config_field + 1) % 5
            elif self.config_field == 0 and key in (10, 13, curses.KEY_ENTER, ord(" ")):
                self.edit_target_ip()
            elif key in (curses.KEY_LEFT, ord("h")):
                self.cycle_config(-1)
            elif key in (curses.KEY_RIGHT, ord("l"), 10, 13, curses.KEY_ENTER, ord(" ")):
                self.cycle_config(1)
            elif key in (getattr(curses, "KEY_F10", -1010), ord("s"), ord("S")):
                self.save_config()
            elif key == getattr(curses, "KEY_F5", -1005):
                self.refresh_static(force=True)
                self.set_message("Monitores atualizados; edição mantida.")
            return True
        if self.mode == "monitors":
            if key in (esc, getattr(curses, "KEY_F3", -1003)):
                self.mode = "main"
            elif key in (curses.KEY_LEFT, curses.KEY_UP, ord("h"), ord("k")):
                self.cycle_monitor_candidate(-1)
            elif key in (curses.KEY_RIGHT, curses.KEY_DOWN, ord("l"), ord("j")):
                self.cycle_monitor_candidate(1)
            elif key in (10, 13, curses.KEY_ENTER):
                self.apply_monitor_candidate()
            elif key == getattr(curses, "KEY_F5", -1005):
                self.refresh_static(force=True)
                self.monitor_candidate = effective_primary(self.state(), self.monitors)
                self.set_message("Mapa de monitores atualizado.")
            return True
        if self.mode == "network":
            if key in (esc, getattr(curses, "KEY_F4", -1004)):
                self.mode = "main"
            elif key in (curses.KEY_UP, ord("k")):
                self.move_selection(-1)
            elif key in (curses.KEY_DOWN, ord("j")):
                self.move_selection(1)
            elif key in (10, 13, curses.KEY_ENTER):
                self.launch_selected()
            elif key == getattr(curses, "KEY_F5", -1005):
                self.force_refresh()
            return True
        return True

    def run(self) -> None:
        self.worker.start()
        try:
            running = True
            while running:
                self.refresh_static(force=False)
                self.draw()
                key = self.stdscr.getch()
                if key != -1:
                    running = self.handle_key(key)
        finally:
            self.worker.stop()


def dump_json() -> int:
    profiles = discover_rdps()
    monitors, raw = load_monitors()
    states = {p.name: load_state(p) for p in profiles}
    payload = {
        "app_dir": str(APP_DIR),
        "state_root": str(STATE_ROOT),
        "profiles": [
            {
                **asdict(profile),
                "state": asdict(states[profile.name]),
                "effective_primary": effective_primary(states[profile.name], monitors),
                "command": effective_command(profile, states[profile.name], monitors),
            }
            for profile in profiles
        ],
        "monitors": [asdict(monitor) for monitor in monitors],
        "physical_order": [monitor.id for monitor in physical_monitor_order(monitors)],
        "drm_outputs": [asdict(output) for output in load_drm_outputs()],
        "addresses": local_ipv4_addresses(),
        "monitor_raw": raw,
    }
    print(json.dumps(payload, ensure_ascii=False, indent=2))
    return 0


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(description="LRDP Control Center fullscreen")
    parser.add_argument("--dump-json", action="store_true", help=argparse.SUPPRESS)
    args = parser.parse_args(argv)
    if args.dump_json:
        return dump_json()
    if not sys.stdin.isatty() or not sys.stdout.isatty():
        print("ERRO: a TUI LRDP precisa de um terminal interativo (TTY).", file=sys.stderr)
        return 2
    curses.wrapper(lambda stdscr: LrdpTui(stdscr).run())
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
