from __future__ import annotations

import argparse
import curses
import json
import math
import os
import re
import shutil
import subprocess
import sys
import time
import tomllib
import unicodedata
import wave
from collections import deque
from dataclasses import dataclass
from datetime import datetime
from difflib import SequenceMatcher
from pathlib import Path

APP_DIR = Path(__file__).resolve().parent
DEFAULT_CONFIG = APP_DIR / "config.toml"


def normalize(text: str) -> str:
    text = unicodedata.normalize("NFKD", text.lower())
    text = "".join(ch for ch in text if not unicodedata.combining(ch))
    text = re.sub(r"[^a-z0-9\s]", " ", text)
    return " ".join(text.split())


@dataclass(frozen=True)
class Match:
    command: str
    phrase: str
    score: float


@dataclass(frozen=True)
class LogEvent:
    when: str
    kind: str
    heard: str
    detail: str = ""


class DailyVoiceLogger:
    """Persist every non-empty transcription with the exact captured utterance."""

    def __init__(self, cfg: dict):
        log_cfg = cfg.get("logging", {})
        self.enabled = bool(log_cfg.get("enabled", True))
        configured = Path(str(log_cfg.get("directory", "logs"))).expanduser()
        self.root = configured if configured.is_absolute() else APP_DIR / configured

    @staticmethod
    def _write_wav(path: Path, samples, sample_rate: int) -> None:
        import numpy as np

        pcm = np.asarray(samples, dtype=np.float32)
        pcm = np.clip(pcm, -1.0, 1.0)
        pcm16 = (pcm * 32767.0).astype(np.int16)
        with wave.open(str(path), "wb") as wav:
            wav.setnchannels(1)
            wav.setsampwidth(2)
            wav.setframerate(sample_rate)
            wav.writeframes(pcm16.tobytes())

    def log(
        self,
        samples,
        sample_rate: int,
        text: str,
        kind: str,
        detail: str = "",
        match: Match | None = None,
    ) -> Path | None:
        if not self.enabled or not text.strip():
            return None
        now = datetime.now()
        day_dir = self.root / now.strftime("%Y-%m-%d")
        day_dir.mkdir(parents=True, exist_ok=True)
        stem = now.strftime("%H-%M-%S-%f")
        wav_path = day_dir / f"{stem}.wav"
        self._write_wav(wav_path, samples, sample_rate)

        payload = {
            "timestamp": now.isoformat(timespec="milliseconds"),
            "audio": wav_path.name,
            "text": text,
            "kind": kind,
            "detail": detail,
            "command": match.command if match else None,
            "matched_phrase": match.phrase if match else None,
            "similarity": round(match.score, 6) if match else None,
        }
        with (day_dir / "events.jsonl").open("a", encoding="utf-8") as fh:
            fh.write(json.dumps(payload, ensure_ascii=False) + "\n")
        safe_text = text.replace("\t", " ").replace("\r", " ").replace("\n", " ")
        safe_detail = detail.replace("\t", " ").replace("\r", " ").replace("\n", " ")
        with (day_dir / "transcriptions.tsv").open("a", encoding="utf-8") as fh:
            fh.write(f"{payload['timestamp']}\t{wav_path.name}\t{kind}\t{safe_text}\t{safe_detail}\n")
        return wav_path


class CommandMatcher:
    def __init__(self, commands: dict[str, list[str]], minimum_similarity: float = 0.82):
        self.minimum_similarity = minimum_similarity
        self.commands = {
            command: sorted({normalize(p) for p in phrases if normalize(p)})
            for command, phrases in commands.items()
        }

    @staticmethod
    def _score(spoken: str, phrase: str) -> float:
        if spoken == phrase:
            return 1.0
        # Curto demais exige proximidade muito alta; evita "vai" disparar dentro de conversa longa.
        if len(phrase.split()) == 1 and len(spoken.split()) > 2:
            return 0.0
        return SequenceMatcher(None, spoken, phrase).ratio()

    def match(self, text: str) -> Match | None:
        spoken = normalize(text)
        if not spoken:
            return None
        best: Match | None = None
        for command, phrases in self.commands.items():
            for phrase in phrases:
                score = self._score(spoken, phrase)
                if best is None or score > best.score:
                    best = Match(command, phrase, score)
        if best is None or best.score < self.minimum_similarity:
            return None
        return best


class DesktopController:
    def __init__(self, backend: str = "auto", dry_run: bool = False, verbose: bool = True):
        self.backend = backend
        self.dry_run = dry_run
        self.verbose = verbose

    def _run(self, command: list[str]) -> None:
        if self.dry_run:
            if self.verbose:
                print("DRY-RUN:", " ".join(command), flush=True)
            return
        subprocess.run(command, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)

    def _xdotool(self, direction: str) -> str:
        key = "Right" if direction == "next" else "Left"
        self._run(["xdotool", "key", "--clearmodifiers", f"ctrl+alt+{key}"])
        return f"xdotool · Ctrl+Alt+{key}"

    def _ydotool(self, direction: str) -> str:
        # Linux input-event codes: LeftCtrl=29, LeftAlt=56, Left=105, Right=106.
        key_code = "106" if direction == "next" else "105"
        key_name = "Right" if direction == "next" else "Left"
        self._run(["ydotool", "key", "29:1", "56:1", f"{key_code}:1", f"{key_code}:0", "56:0", "29:0"])
        return f"ydotool · Ctrl+Alt+{key_name}"

    def _wtype(self, direction: str) -> str:
        key = "Right" if direction == "next" else "Left"
        self._run(["wtype", "-M", "ctrl", "-M", "alt", "-k", key, "-m", "alt", "-m", "ctrl"])
        return f"wtype · Ctrl+Alt+{key}"

    def _pyautogui(self, direction: str) -> str:
        try:
            import pyautogui
        except ImportError as exc:
            raise RuntimeError("backend pyautogui indisponível") from exc
        key = "right" if direction == "next" else "left"
        if self.dry_run:
            if self.verbose:
                print(f"DRY-RUN: pyautogui.hotkey('ctrl','alt','{key}')", flush=True)
        else:
            pyautogui.hotkey("ctrl", "alt", key)
        return f"pyautogui · Ctrl+Alt+{key.title()}"

    def _select_backend(self) -> str:
        if self.backend != "auto":
            return self.backend
        if os.environ.get("DISPLAY") and shutil.which("xdotool"):
            return "xdotool"
        if shutil.which("ydotool"):
            return "ydotool"
        if os.environ.get("WAYLAND_DISPLAY") and shutil.which("wtype"):
            return "wtype"
        try:
            import pyautogui  # noqa: F401
            return "pyautogui"
        except Exception:
            pass
        raise RuntimeError(
            "Nenhum backend para trocar desktop. Instale xdotool (X11) ou ydotool (Wayland); "
            "wtype também é aceito quando suportado pelo compositor."
        )

    def move(self, direction: str) -> str:
        if self.dry_run and self.backend == "auto":
            key = "Right" if direction == "next" else "Left"
            if self.verbose:
                print(f"DRY-RUN: desktop {direction} (Ctrl+Alt+{key})", flush=True)
            return f"dry-run · Ctrl+Alt+{key}"
        backend = self._select_backend()
        if backend == "xdotool":
            return self._xdotool(direction)
        if backend == "ydotool":
            return self._ydotool(direction)
        if backend == "wtype":
            return self._wtype(direction)
        if backend == "pyautogui":
            return self._pyautogui(direction)
        raise RuntimeError(f"Backend desconhecido: {backend}")


class WhisperRecognizer:
    CUDA_RUNTIME_MARKERS = (
        "libcublas",
        "libcudnn",
        "cuda",
        "cublas",
        "cudnn",
    )

    def __init__(self, model_name: str, language: str, compute_type: str, device: str = "auto"):
        try:
            from faster_whisper import WhisperModel
        except ImportError as exc:
            raise RuntimeError("Dependências ausentes. Rode ./install.sh") from exc
        self._WhisperModel = WhisperModel
        self.language = language
        self.model_name = model_name
        self.requested_device = device
        self.device = device
        self.compute_type = compute_type
        self.model = self._load_model(device)

    @classmethod
    def _is_cuda_runtime_error(cls, exc: BaseException) -> bool:
        message = str(exc).lower()
        return any(marker in message for marker in cls.CUDA_RUNTIME_MARKERS)

    def _load_model(self, device: str):
        try:
            return self._WhisperModel(self.model_name, device=device, compute_type=self.compute_type)
        except Exception as exc:
            if device != "auto" or not self._is_cuda_runtime_error(exc):
                raise
            self.device = "cpu"
            return self._WhisperModel(self.model_name, device="cpu", compute_type=self.compute_type)

    def _transcribe(self, samples):
        return self.model.transcribe(
            samples,
            language=self.language,
            initial_prompt="Comandos curtos: vai, avança, pra frente, continua, volta, recua, pra trás, desktop anterior.",
            beam_size=5,
            best_of=5,
            temperature=0.0,
            vad_filter=False,
            condition_on_previous_text=False,
            repetition_penalty=1.05,
            no_repeat_ngram_size=3,
        )

    def transcribe(self, samples, sample_rate: int) -> str:
        try:
            segments, _ = self._transcribe(samples)
            # faster-whisper may defer CUDA library loading until segments are consumed.
            segments = list(segments)
        except Exception as exc:
            if self.requested_device != "auto" or self.device == "cpu" or not self._is_cuda_runtime_error(exc):
                raise
            self.device = "cpu"
            self.model = self._WhisperModel(self.model_name, device="cpu", compute_type=self.compute_type)
            segments, _ = self._transcribe(samples)
            segments = list(segments)
        return " ".join(seg.text.strip() for seg in segments).strip()


def load_config(path: Path) -> dict:
    with path.open("rb") as fh:
        return tomllib.load(fh)


def build_matcher(cfg: dict) -> CommandMatcher:
    commands = {name: data.get("phrases", []) for name, data in cfg.get("commands", {}).items()}
    return CommandMatcher(commands, float(cfg["recognition"].get("minimum_similarity", 0.82)))


def execute_match(match: Match, controller: DesktopController) -> str:
    if match.command == "next_desktop":
        return controller.move("next")
    if match.command == "previous_desktop":
        return controller.move("previous")
    raise RuntimeError(f"Comando sem ação: {match.command}")


def command_label(command: str) -> str:
    return {
        "next_desktop": "PRÓXIMO DESKTOP",
        "previous_desktop": "DESKTOP ANTERIOR",
    }.get(command, command.upper())


class VoiceTUI:
    def __init__(self, cfg: dict, dry_run: bool = False):
        self.cfg = cfg
        self.dry_run = dry_run
        ui_cfg = cfg.get("ui", {})
        self.max_history = int(ui_cfg.get("max_history", 200))
        self.events: deque[LogEvent] = deque(maxlen=self.max_history)
        self.screen = None
        self.scroll = 0
        self.status = "INICIANDO"
        self.mic_name = "detectando..."
        self.level = 0.0
        self.recognizing = False
        self.model_name = str(cfg.get("recognition", {}).get("model", "tiny"))
        self.device = str(cfg.get("recognition", {}).get("device", "auto"))
        self.compute_type = str(cfg.get("recognition", {}).get("compute_type", "int8"))
        self.backend = str(cfg.get("action", {}).get("backend", "auto"))

    def __enter__(self):
        self.screen = curses.initscr()
        curses.noecho()
        curses.cbreak()
        self.screen.keypad(True)
        self.screen.nodelay(True)
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
            curses.init_pair(1, curses.COLOR_GREEN, -1)
            curses.init_pair(2, curses.COLOR_YELLOW, -1)
            curses.init_pair(3, curses.COLOR_RED, -1)
            curses.init_pair(4, curses.COLOR_CYAN, -1)
            curses.init_pair(5, curses.COLOR_WHITE, -1)
            curses.init_pair(6, curses.COLOR_BLUE, -1)
        self.render()
        return self

    def __exit__(self, exc_type, exc, tb):
        if self.screen is not None:
            try:
                self.screen.keypad(False)
            except curses.error:
                pass
        curses.nocbreak()
        curses.echo()
        curses.endwin()

    def _color(self, pair: int, bold: bool = False) -> int:
        attr = curses.color_pair(pair) if curses.has_colors() else 0
        return attr | (curses.A_BOLD if bold else 0)

    def _add(self, y: int, x: int, text: str, attr: int = 0, width: int | None = None) -> None:
        if self.screen is None:
            return
        h, w = self.screen.getmaxyx()
        if y < 0 or y >= h or x >= w:
            return
        max_width = max(0, w - x - 1) if width is None else min(width, max(0, w - x - 1))
        if max_width <= 0:
            return
        try:
            self.screen.addnstr(y, x, text, max_width, attr)
        except curses.error:
            pass

    def set_mic(self, name: str) -> None:
        self.mic_name = name
        self.render()

    def set_status(self, status: str) -> None:
        self.status = status
        self.render()

    def set_level(self, level: float, threshold: float) -> None:
        self.level = 0.0 if threshold <= 0 else min(1.0, level / max(threshold * 2.5, 0.0001))

    def log(self, kind: str, heard: str, detail: str = "") -> None:
        self.events.append(LogEvent(datetime.now().strftime("%H:%M:%S"), kind, heard, detail))
        self.scroll = 0
        self.render()

    def handle_input(self) -> bool:
        if self.screen is None:
            return True
        try:
            key = self.screen.getch()
        except curses.error:
            return True
        if key == -1:
            return True
        if key in (ord("q"), ord("Q"), 27):
            return False
        if key in (curses.KEY_UP, ord("k")):
            self.scroll = min(self.scroll + 1, max(0, len(self.events) - 1))
            self.render()
        elif key in (curses.KEY_DOWN, ord("j")):
            self.scroll = max(0, self.scroll - 1)
            self.render()
        elif key in (curses.KEY_END, ord("G")):
            self.scroll = 0
            self.render()
        elif key in (curses.KEY_RESIZE,):
            self.render()
        return True

    def render(self) -> None:
        if self.screen is None:
            return
        self.screen.erase()
        h, w = self.screen.getmaxyx()
        if h < 12 or w < 56:
            self._add(0, 0, "VOICE COMMANDS", self._color(4, True))
            self._add(2, 0, "Terminal pequeno demais para a TUI.", self._color(2))
            self._add(4, 0, "Aumente a janela. Q/Esc encerra.")
            self.screen.refresh()
            return

        title = " VOICE COMMANDS "
        mode = "DRY-RUN" if self.dry_run else "ATIVO"
        self._add(0, 0, "─" * (w - 1), self._color(6))
        self._add(0, 2, title, self._color(4, True))
        self._add(0, max(2, w - len(mode) - 3), f" {mode} ", self._color(1 if not self.dry_run else 2, True))

        status_color = 1 if self.status == "ESCUTANDO" else 2 if self.status in {"RECONHECENDO", "FALA DETECTADA"} else 3
        self._add(2, 2, "●", self._color(status_color, True))
        self._add(2, 4, self.status, self._color(status_color, True))
        self._add(2, 24, "Mic:", self._color(5, True))
        self._add(2, 29, self.mic_name)

        bar_width = min(32, max(12, w - 24))
        filled = int(bar_width * self.level)
        meter = "█" * filled + "░" * (bar_width - filled)
        self._add(3, 2, "Nível:", self._color(5, True))
        self._add(3, 9, meter, self._color(1 if self.level >= 0.4 else 4))

        self._add(5, 0, "─" * (w - 1), self._color(6))
        self._add(5, 2, " EVENTOS ", self._color(4, True))

        log_top = 6
        footer_top = h - 4
        visible_rows = max(1, footer_top - log_top)
        events = list(self.events)
        end = len(events) - self.scroll
        start = max(0, end - visible_rows // 2)
        visible = events[start:end]

        row = log_top
        for event in visible:
            if row >= footer_top:
                break
            kind_color = {"ok": 1, "ignored": 5, "cooldown": 2, "error": 3, "info": 4}.get(event.kind, 5)
            icon = {"ok": "✓", "ignored": "·", "cooldown": "~", "error": "!", "info": "i"}.get(event.kind, "·")
            self._add(row, 2, event.when, self._color(6))
            self._add(row, 11, "🎙" if w >= 72 else ">", self._color(4))
            self._add(row, 14, f'"{event.heard}"', self._color(5, True), width=max(10, w - 18))
            row += 1
            if row >= footer_top:
                break
            self._add(row, 11, icon, self._color(kind_color, True))
            self._add(row, 14, event.detail, self._color(kind_color), width=max(10, w - 18))
            row += 1

        if not events:
            self._add(log_top + 1, 2, "Fale um comando. O que for reconhecido aparece aqui.", self._color(5))

        self._add(footer_top, 0, "─" * (w - 1), self._color(6))
        model_line = f"Modelo: {self.model_name}   Device: {self.device}   Compute: {self.compute_type}   Backend: {self.backend}"
        self._add(footer_top + 1, 2, model_line, self._color(5))
        help_line = "↑/↓ histórico   End: mais recente   Q/Esc: sair"
        self._add(footer_top + 2, 2, help_line, self._color(6))
        try:
            self.screen.refresh()
        except curses.error:
            pass


def run_stdin(cfg: dict, dry_run: bool) -> int:
    matcher = build_matcher(cfg)
    controller = DesktopController(cfg["action"].get("backend", "auto"), dry_run=dry_run)
    print("Modo texto. Digite uma frase; Ctrl+D encerra.")
    for line in sys.stdin:
        text = line.strip()
        match = matcher.match(text)
        if match:
            print(f"{text!r} -> {match.command} ({match.score:.0%}, frase={match.phrase!r})")
            action = execute_match(match, controller)
            print(f"  ação: {action}")
        else:
            print(f"{text!r} -> ignorado")
    return 0


def rms(block) -> float:
    import numpy as np
    if len(block) == 0:
        return 0.0
    return float(math.sqrt(float(np.mean(np.square(block, dtype=np.float64)))))


def _input_device_name(sd) -> str:
    try:
        return str(sd.query_devices(kind="input")["name"])
    except Exception:
        return "dispositivo padrão"


def _plain_log(kind: str, text: str, detail: str = "") -> None:
    prefix = {
        "ok": "OK",
        "ignored": "IGNORADO",
        "cooldown": "COOLDOWN",
        "error": "ERRO",
        "info": "INFO",
    }.get(kind, kind.upper())
    suffix = f" -> {detail}" if detail else ""
    print(f"[{datetime.now().strftime('%H:%M:%S')}] {prefix}: {text!r}{suffix}", flush=True)


def _microphone_loop(cfg: dict, dry_run: bool, tui: VoiceTUI | None) -> int:
    try:
        import numpy as np
        import sounddevice as sd
    except ImportError as exc:
        raise RuntimeError("Dependências ausentes. Rode ./install.sh") from exc

    audio_cfg = cfg["audio"]
    rec_cfg = cfg["recognition"]
    rate = int(audio_cfg.get("sample_rate", 16000))
    block_seconds = float(audio_cfg.get("block_seconds", 0.25))
    threshold = float(audio_cfg.get("speech_rms_threshold", 0.012))
    finish_silence = float(audio_cfg.get("silence_to_finish_seconds", 0.65))
    max_utterance = float(audio_cfg.get("utterance_max_seconds", 3.5))
    blocksize = max(1, int(rate * block_seconds))
    silence_blocks = max(1, round(finish_silence / block_seconds))
    max_blocks = max(1, round(max_utterance / block_seconds))

    device = str(rec_cfg.get("device", "auto"))
    if tui:
        tui.set_status("CARREGANDO MODELO")
        tui.set_mic(_input_device_name(sd))

    recognizer = WhisperRecognizer(
        rec_cfg.get("model", "tiny"),
        rec_cfg.get("language", "pt"),
        rec_cfg.get("compute_type", "int8"),
        device,
    )
    matcher = build_matcher(cfg)
    controller = DesktopController(cfg["action"].get("backend", "auto"), dry_run=dry_run, verbose=tui is None)
    voice_logger = DailyVoiceLogger(cfg)
    cooldown = float(rec_cfg.get("cooldown_seconds", 0.9))
    last_action_at = 0.0

    frames: list = []
    pre_roll = deque(maxlen=2)
    in_speech = False
    silent_count = 0

    if tui:
        tui.set_status("ESCUTANDO")
    else:
        print("Escutando. Ctrl+C encerra.", flush=True)

    with sd.InputStream(samplerate=rate, channels=1, dtype="float32", blocksize=blocksize) as stream:
        while True:
            if tui and not tui.handle_input():
                return 0

            data, overflowed = stream.read(blocksize)
            if overflowed:
                if tui:
                    tui.log("error", "microfone", "overflow de captura")
                else:
                    print("Aviso: overflow do microfone", file=sys.stderr, flush=True)
            mono = np.asarray(data[:, 0], dtype=np.float32)
            level = rms(mono)
            if tui:
                tui.set_level(level, threshold)

            if level >= threshold:
                if not in_speech:
                    frames = list(pre_roll)
                    in_speech = True
                    if tui:
                        tui.set_status("FALA DETECTADA")
                frames.append(mono.copy())
                silent_count = 0
            elif in_speech:
                frames.append(mono.copy())
                silent_count += 1
            else:
                pre_roll.append(mono.copy())

            finished = in_speech and (silent_count >= silence_blocks or len(frames) >= max_blocks)
            if not finished:
                if tui:
                    tui.render()
                continue

            samples = np.concatenate(frames) if frames else np.empty(0, dtype=np.float32)
            frames = []
            pre_roll.clear()
            in_speech = False
            silent_count = 0
            if samples.size < int(rate * 0.18):
                if tui:
                    tui.set_status("ESCUTANDO")
                continue

            if tui:
                tui.set_status("RECONHECENDO")
            text = recognizer.transcribe(samples, rate)
            if not text:
                if tui:
                    tui.set_status("ESCUTANDO")
                continue

            match = matcher.match(text)
            if not match:
                detail = "nenhum comando compatível"
                voice_logger.log(samples, rate, text, "ignored", detail)
                if tui:
                    tui.log("ignored", text, detail)
                    tui.set_status("ESCUTANDO")
                else:
                    _plain_log("ignored", text, detail)
                continue

            now = time.monotonic()
            if now - last_action_at < cooldown:
                detail = f"{command_label(match.command)} · {match.score:.0%} · ignorado por cooldown"
                voice_logger.log(samples, rate, text, "cooldown", detail, match)
                if tui:
                    tui.log("cooldown", text, detail)
                    tui.set_status("ESCUTANDO")
                else:
                    _plain_log("cooldown", text, detail)
                continue

            try:
                action = execute_match(match, controller)
                detail = f"{command_label(match.command)} · {match.score:.0%} · {action}"
                voice_logger.log(samples, rate, text, "ok", detail, match)
                if tui:
                    tui.log("ok", text, detail)
                else:
                    _plain_log("ok", text, detail)
                last_action_at = now
            except Exception as exc:
                detail = f"{command_label(match.command)} · falhou: {exc}"
                voice_logger.log(samples, rate, text, "error", detail, match)
                if tui:
                    tui.log("error", text, detail)
                else:
                    _plain_log("error", text, detail)
            finally:
                if tui:
                    tui.set_status("ESCUTANDO")


def run_microphone(cfg: dict, dry_run: bool, use_tui: bool) -> int:
    if use_tui:
        with VoiceTUI(cfg, dry_run=dry_run) as tui:
            return _microphone_loop(cfg, dry_run, tui)
    return _microphone_loop(cfg, dry_run, None)


def doctor(cfg: dict) -> int:
    print(f"Python: {sys.version.split()[0]}")
    print(f"Config: {DEFAULT_CONFIG}")
    print(f"DISPLAY: {os.environ.get('DISPLAY') or '-'}")
    print(f"WAYLAND_DISPLAY: {os.environ.get('WAYLAND_DISPLAY') or '-'}")
    print(f"xdotool: {shutil.which('xdotool') or '-'}")
    print(f"ydotool: {shutil.which('ydotool') or '-'}")
    print(f"wtype: {shutil.which('wtype') or '-'}")
    print(f"TUI: {'disponível' if sys.stdout.isatty() else 'desativada (stdout não é TTY)'}")
    rec_cfg = cfg.get("recognition", {})
    print(f"Whisper model: {rec_cfg.get('model', 'tiny')}")
    print(f"Whisper device: {rec_cfg.get('device', 'auto')}")
    print(f"Whisper compute: {rec_cfg.get('compute_type', 'int8')}")
    logger = DailyVoiceLogger(cfg)
    print(f"Voice logs: {logger.root} ({'ativo' if logger.enabled else 'desativado'})")
    try:
        import sounddevice as sd
        print("sounddevice: OK")
        try:
            print(f"input device: {sd.query_devices(kind='input')['name']}")
        except Exception as exc:
            print(f"input device: ERRO ({exc})")
    except Exception as exc:
        print(f"sounddevice: ERRO ({exc})")
    try:
        import faster_whisper  # noqa: F401
        print("faster-whisper: OK")
    except Exception as exc:
        print(f"faster-whisper: ERRO ({exc})")
    matcher = build_matcher(cfg)
    print(f"comandos: {sum(len(v) for v in matcher.commands.values())} frases cadastradas")
    return 0


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Comandos de voz locais para troca de desktop/workspace")
    parser.add_argument("--config", type=Path, default=DEFAULT_CONFIG)
    parser.add_argument("--stdin", action="store_true", help="testa reconhecimento digitando frases")
    parser.add_argument("--dry-run", action="store_true", help="reconhece, mas não envia teclas")
    parser.add_argument("--doctor", action="store_true", help="diagnóstico de dependências e ambiente")
    ui = parser.add_mutually_exclusive_group()
    ui.add_argument("--tui", action="store_true", help="força interface TUI no terminal")
    ui.add_argument("--no-tui", action="store_true", help="usa log textual simples")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    cfg = load_config(args.config)
    try:
        if args.doctor:
            return doctor(cfg)
        if args.stdin:
            return run_stdin(cfg, args.dry_run)
        use_tui = args.tui or (not args.no_tui and sys.stdin.isatty() and sys.stdout.isatty())
        return run_microphone(cfg, args.dry_run, use_tui)
    except KeyboardInterrupt:
        if not (args.tui or (not args.no_tui and sys.stdin.isatty() and sys.stdout.isatty())):
            print("\nEncerrado.")
        return 130
    except Exception as exc:
        print(f"ERRO: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
