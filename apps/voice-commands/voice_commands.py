from __future__ import annotations

import argparse
import curses
import json
import locale
import math
import os
import shutil
import subprocess
import sys
import time
import tomllib
import wave
from collections import deque
from dataclasses import dataclass
from datetime import datetime
from difflib import SequenceMatcher
from pathlib import Path

from command_catalog import (
    APP_DIR,
    DEFAULT_COMMANDS_PATH,
    USER_COMMANDS_PATH,
    CommandCatalog,
    DesktopEntry,
    DesktopRegistry,
    FIXED_ACTIONS,
    FIXED_ACTION_MAP,
    normalize,
)

locale.setlocale(locale.LC_ALL, "")
DEFAULT_CONFIG = APP_DIR / "config.toml"


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
    def __init__(
        self,
        backend: str = "auto",
        dry_run: bool = False,
        verbose: bool = True,
        step_delay: float = 0.07,
    ):
        self.backend = backend
        self.dry_run = dry_run
        self.verbose = verbose
        self.step_delay = max(0.0, float(step_delay))

    def _run(self, command: list[str], *, check: bool = True) -> subprocess.CompletedProcess | None:
        if self.dry_run:
            if self.verbose:
                print("DRY-RUN:", " ".join(command), flush=True)
            return None
        return subprocess.run(
            command,
            check=check,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            text=True,
        )

    def _xdotool(self, direction: str) -> str:
        key = "Right" if direction == "next" else "Left"
        self._run(["xdotool", "key", "--clearmodifiers", f"ctrl+alt+{key}"])
        return f"xdotool · Ctrl+Alt+{key}"

    def _ydotool(self, direction: str) -> str:
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
        session = os.environ.get("XDG_SESSION_TYPE", "").lower()
        if (session == "wayland" or os.environ.get("WAYLAND_DISPLAY")) and shutil.which("ydotool"):
            return "ydotool"
        if (session == "wayland" or os.environ.get("WAYLAND_DISPLAY")) and shutil.which("wtype"):
            return "wtype"
        if os.environ.get("DISPLAY") and shutil.which("xdotool"):
            return "xdotool"
        if shutil.which("ydotool"):
            return "ydotool"
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

    def move_steps(self, direction: str, count: int) -> str:
        count = max(1, int(count))
        last = ""
        for step in range(count):
            last = self.move(direction)
            if step + 1 < count and not self.dry_run and self.step_delay:
                time.sleep(self.step_delay)
        return f"{count} passo(s) · {last}"

    def go_to(self, index: int, total: int, label: str = "") -> str:
        index = max(1, int(index))
        total = max(index, int(total))
        target = label or f"desktop {index}"
        if self.dry_run:
            if self.verbose:
                print(f"DRY-RUN: ir diretamente para {target} (índice {index}/{total})", flush=True)
            return f"dry-run · {target} · índice {index}/{total}"

        # X11 possui seleção absoluta barata. Em Wayland usamos um caminho que não
        # depende de introspecção privada do GNOME: recua até a borda e então avança
        # até o índice alvo. Como workspaces são fixos, o resultado é determinístico.
        if os.environ.get("XDG_SESSION_TYPE", "").lower() == "x11" and shutil.which("xdotool"):
            self._run(["xdotool", "set_desktop", str(index - 1)])
            return f"xdotool · {target} · índice {index}/{total}"

        self.move_steps("previous", total + 1)
        if index > 1:
            self.move_steps("next", index - 1)
        return f"workspace direto · {target} · índice {index}/{total}"


class ActionExecutor:
    def __init__(self, cfg: dict, catalog: CommandCatalog, dry_run: bool = False, verbose: bool = True):
        action_cfg = cfg.get("action", {})
        self.catalog = catalog
        self.dry_run = dry_run
        self.verbose = verbose
        self.controller = DesktopController(
            str(action_cfg.get("backend", "auto")),
            dry_run=dry_run,
            verbose=verbose,
            step_delay=float(action_cfg.get("workspace_step_delay", 0.07)),
        )

    def _run_first(self, candidates: list[list[str]], label: str) -> str:
        if self.dry_run:
            command = candidates[0]
            if self.verbose:
                print("DRY-RUN:", " ".join(command), flush=True)
            return f"dry-run · {label}"
        errors: list[str] = []
        for command in candidates:
            executable = command[0]
            if "/" not in executable and shutil.which(executable) is None:
                continue
            try:
                subprocess.Popen(
                    command,
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    start_new_session=True,
                )
                return f"{label} · {' '.join(command)}"
            except OSError as exc:
                errors.append(str(exc))
        raise RuntimeError(f"não foi possível executar {label}" + (f": {'; '.join(errors)}" if errors else ""))

    def _run_sync_first(self, candidates: list[list[str]], label: str) -> str:
        if self.dry_run:
            if self.verbose:
                print("DRY-RUN:", " ".join(candidates[0]), flush=True)
            return f"dry-run · {label}"
        errors: list[str] = []
        for command in candidates:
            if "/" not in command[0] and shutil.which(command[0]) is None:
                continue
            proc = subprocess.run(command, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True, check=False)
            if proc.returncode == 0:
                return f"{label} · {' '.join(command)}"
            errors.append((proc.stderr or f"exit {proc.returncode}").strip())
        raise RuntimeError(f"{label} falhou" + (f": {'; '.join(filter(None, errors))}" if errors else ""))

    def _audio(self, mode: str) -> str:
        wpctl_mode = {"mute": "1", "unmute": "0", "toggle": "toggle"}[mode]
        pactl_mode = {"mute": "1", "unmute": "0", "toggle": "toggle"}[mode]
        return self._run_sync_first(
            [
                ["wpctl", "set-mute", "@DEFAULT_AUDIO_SINK@", wpctl_mode],
                ["pactl", "set-sink-mute", "@DEFAULT_SINK@", pactl_mode],
            ],
            {"mute": "som desligado", "unmute": "som ligado", "toggle": "mudo alternado"}[mode],
        )

    def _volume(self, direction: str) -> str:
        wpctl_delta = "5%+" if direction == "up" else "5%-"
        pactl_delta = "+5%" if direction == "up" else "-5%"
        return self._run_sync_first(
            [
                ["wpctl", "set-volume", "-l", "1.5", "@DEFAULT_AUDIO_SINK@", wpctl_delta],
                ["pactl", "set-sink-volume", "@DEFAULT_SINK@", pactl_delta],
            ],
            "volume alterado",
        )

    def execute(self, command_id: str) -> str:
        workspace = self.catalog.workspace_name(command_id)
        if workspace is not None:
            self.catalog.refresh_desktops()
            entry = self.catalog.registry.by_name(workspace)
            if not entry:
                raise RuntimeError(f"desktop não encontrado: {workspace}")
            return self.controller.go_to(entry.index, len(self.catalog.registry.entries), entry.name)

        if command_id == "next_desktop":
            return self.controller.move("next")
        if command_id == "previous_desktop":
            return self.controller.move("previous")
        if command_id == "next_two_desktops":
            return self.controller.move_steps("next", 2)
        if command_id == "previous_two_desktops":
            return self.controller.move_steps("previous", 2)
        if command_id in {"first_desktop", "last_desktop"}:
            self.catalog.refresh_desktops()
            entries = self.catalog.registry.entries
            if not entries:
                raise RuntimeError(self.catalog.registry.error or "nenhum desktop configurado")
            entry = entries[0] if command_id == "first_desktop" else entries[-1]
            return self.controller.go_to(entry.index, len(entries), entry.name)
        if command_id == "mute_audio":
            return self._audio("mute")
        if command_id == "unmute_audio":
            return self._audio("unmute")
        if command_id == "toggle_mute":
            return self._audio("toggle")
        if command_id == "volume_up":
            return self._volume("up")
        if command_id == "volume_down":
            return self._volume("down")
        if command_id == "lock_screen":
            return self._run_sync_first(
                [["loginctl", "lock-session"], ["xdg-screensaver", "lock"]],
                "tela bloqueada",
            )
        if command_id == "suspend_system":
            return self._run_sync_first([["systemctl", "suspend"]], "computador suspenso")
        if command_id == "open_calculator":
            return self._run_first([["gnome-calculator"], ["kcalc"]], "calculadora")
        if command_id == "open_text_editor":
            return self._run_first([["gnome-text-editor"], ["gedit"], ["kate"]], "editor de texto")
        if command_id == "open_email":
            return self._run_first([["xdg-open", "mailto:"]], "e-mail")
        if command_id == "open_terminal":
            return self._run_first([["ptyxis"], ["kgx"], ["gnome-terminal"], ["xterm"]], "terminal")
        if command_id == "open_files":
            return self._run_first([["xdg-open", str(Path.home())]], "arquivos")
        if command_id == "open_browser":
            return self._run_first([["xdg-open", "https://www.google.com/"]], "navegador")
        if command_id == "open_settings":
            return self._run_first([["gnome-control-center"]], "configurações")
        raise RuntimeError(f"Comando sem ação: {command_id}")


def _nvidia_pip_library_dir(module_name: str) -> str:
    try:
        from importlib import import_module

        module = import_module(module_name)
        module_paths = list(getattr(module, "__path__", []) or [])
        if module_paths:
            return str(Path(module_paths[0]).resolve())
        filename = getattr(module, "__file__", None)
        if filename:
            return str(Path(filename).resolve().parent)
    except Exception:
        pass
    return "-"


def gpu_diagnostics() -> dict[str, str]:
    info = {
        "GPU NVIDIA": "não detectada",
        "Driver NVIDIA": "-",
        "VRAM": "-",
        "CUDA driver": "-",
        "CTranslate2 CUDA": "indisponível",
        "Compute CUDA": "-",
        "cuBLAS 12": _nvidia_pip_library_dir("nvidia.cublas.lib"),
        "cuDNN 9": _nvidia_pip_library_dir("nvidia.cudnn.lib"),
    }
    smi = shutil.which("nvidia-smi")
    if smi:
        try:
            result = subprocess.run(
                [
                    smi,
                    "--query-gpu=name,driver_version,memory.total,memory.free",
                    "--format=csv,noheader,nounits",
                ],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                timeout=2,
                check=False,
            )
            first = (result.stdout or "").strip().splitlines()
            if result.returncode == 0 and first:
                parts = [part.strip() for part in first[0].split(",")]
                if len(parts) >= 4:
                    info["GPU NVIDIA"] = parts[0]
                    info["Driver NVIDIA"] = parts[1]
                    info["VRAM"] = f"{parts[3]} MiB livre / {parts[2]} MiB total"
            version = subprocess.run(
                [smi],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                timeout=2,
                check=False,
            ).stdout
            marker = "CUDA Version:"
            if marker in version:
                info["CUDA driver"] = version.split(marker, 1)[1].split()[0]
        except Exception:
            pass
    try:
        import ctranslate2

        count = int(ctranslate2.get_cuda_device_count())
        info["CTranslate2 CUDA"] = f"{count} dispositivo(s)"
        if count > 0:
            try:
                supported = sorted(ctranslate2.get_supported_compute_types("cuda"))
                info["Compute CUDA"] = ", ".join(supported) or "-"
            except Exception as exc:
                info["Compute CUDA"] = f"ERRO: {exc}"
    except Exception as exc:
        info["CTranslate2 CUDA"] = f"ERRO: {exc}"
    return info


class WhisperRecognizer:
    CUDA_RUNTIME_MARKERS = (
        "libcublas",
        "libcudnn",
        "cuda",
        "cublas",
        "cudnn",
        "out of memory",
        "compute type",
    )

    def __init__(
        self,
        model_name: str,
        language: str,
        compute_type: str,
        device: str = "auto",
        initial_prompt: str = "",
        gpu_fallback_compute_type: str = "int8_float16",
        cpu_compute_type: str = "int8",
        allow_cpu_fallback: bool = True,
    ):
        try:
            from faster_whisper import WhisperModel
        except ImportError as exc:
            raise RuntimeError("Dependências ausentes. Rode ./install.sh --gpu") from exc
        self._WhisperModel = WhisperModel
        self.language = language
        self.model_name = model_name
        self.requested_device = device
        self.requested_compute_type = compute_type
        self.gpu_fallback_compute_type = gpu_fallback_compute_type
        self.cpu_compute_type = cpu_compute_type
        self.allow_cpu_fallback = allow_cpu_fallback
        self.device = device
        self.compute_type = compute_type
        self.initial_prompt = initial_prompt
        self.model = self._load_model(device)

    def set_initial_prompt(self, prompt: str) -> None:
        self.initial_prompt = prompt

    @classmethod
    def _is_cuda_runtime_error(cls, exc: BaseException) -> bool:
        message = str(exc).lower()
        return any(marker in message for marker in cls.CUDA_RUNTIME_MARKERS)

    @staticmethod
    def _cuda_available() -> bool:
        try:
            import ctranslate2

            return int(ctranslate2.get_cuda_device_count()) > 0
        except Exception:
            return False

    def _cuda_compute_candidates(self) -> list[str]:
        values: list[str] = []
        for value in (self.requested_compute_type, self.gpu_fallback_compute_type):
            value = str(value or "").strip()
            if value and value not in values:
                values.append(value)
        return values or ["float16", "int8_float16"]

    @staticmethod
    def _cuda_help(exc: BaseException) -> RuntimeError:
        return RuntimeError(
            "CUDA do Voice Commands não iniciou. "
            "Rode 'cd apps/voice-commands && ./install.sh --gpu' e depois './run.sh --doctor'. "
            f"Erro original: {exc}"
        )

    def _load_cpu(self):
        self.device = "cpu"
        self.compute_type = self.cpu_compute_type
        return self._WhisperModel(self.model_name, device="cpu", compute_type=self.compute_type)

    def _load_cuda(self, candidates: list[str] | None = None):
        last_exc: BaseException | None = None
        for compute in candidates or self._cuda_compute_candidates():
            try:
                model = self._WhisperModel(self.model_name, device="cuda", compute_type=compute)
                self.device = "cuda"
                self.compute_type = compute
                return model
            except Exception as exc:
                last_exc = exc
        if self.allow_cpu_fallback:
            return self._load_cpu()
        if last_exc is not None and self._is_cuda_runtime_error(last_exc):
            raise self._cuda_help(last_exc) from last_exc
        if last_exc is not None:
            raise last_exc
        raise RuntimeError("CUDA indisponível")

    def _load_model(self, device: str):
        requested = str(device or "auto").lower()
        if requested == "cpu":
            return self._load_cpu()
        if requested == "cuda":
            return self._load_cuda()
        if requested == "auto":
            if self._cuda_available():
                return self._load_cuda()
            return self._load_cpu()
        self.device = requested
        try:
            return self._WhisperModel(self.model_name, device=requested, compute_type=self.compute_type)
        except Exception:
            if self.allow_cpu_fallback:
                return self._load_cpu()
            raise

    def _transcribe(self, samples):
        return self.model.transcribe(
            samples,
            language=self.language,
            initial_prompt=self.initial_prompt or None,
            beam_size=5,
            best_of=5,
            temperature=0.0,
            vad_filter=False,
            condition_on_previous_text=False,
            repetition_penalty=1.05,
            no_repeat_ngram_size=3,
        )

    def _retry_after_cuda_failure(self, samples):
        remaining = [value for value in self._cuda_compute_candidates() if value != self.compute_type]
        last_exc: BaseException | None = None
        for compute in remaining:
            try:
                self.model = self._WhisperModel(self.model_name, device="cuda", compute_type=compute)
                self.device = "cuda"
                self.compute_type = compute
                segments, info = self._transcribe(samples)
                return list(segments), info
            except Exception as exc:
                last_exc = exc
        if self.allow_cpu_fallback:
            self.model = self._load_cpu()
            segments, info = self._transcribe(samples)
            return list(segments), info
        if last_exc is not None:
            raise self._cuda_help(last_exc) from last_exc
        raise RuntimeError("CUDA falhou durante a transcrição")

    def transcribe(self, samples, sample_rate: int) -> str:
        del sample_rate
        try:
            segments, _ = self._transcribe(samples)
            segments = list(segments)
        except Exception as exc:
            if self.device != "cuda" or not self._is_cuda_runtime_error(exc):
                raise
            segments, _ = self._retry_after_cuda_failure(samples)
        return " ".join(seg.text.strip() for seg in segments).strip()


def load_config(path: Path) -> dict:
    with path.open("rb") as fh:
        return tomllib.load(fh)


def build_catalog() -> CommandCatalog:
    return CommandCatalog()


def build_matcher(cfg: dict, catalog: CommandCatalog | None = None) -> CommandMatcher:
    catalog = catalog or build_catalog()
    return CommandMatcher(catalog.matcher_commands(), float(cfg["recognition"].get("minimum_similarity", 0.82)))


def execute_match(match: Match, executor: ActionExecutor) -> str:
    return executor.execute(match.command)


def command_label(command: str, catalog: CommandCatalog | None = None) -> str:
    if catalog is not None:
        return catalog.label_for(command)
    workspace = CommandCatalog.workspace_name(command)
    if workspace is not None:
        return f"DESKTOP · {workspace}"
    definition = FIXED_ACTION_MAP.get(command)
    return definition.label.upper() if definition else command.upper()


class VoiceTUI:
    PAGE_LIVE = "live"
    PAGE_COMMANDS = "commands"
    PAGE_DESKTOPS = "desktops"
    PAGE_DIAGNOSTICS = "diagnostics"

    def __init__(self, cfg: dict, catalog: CommandCatalog, dry_run: bool = False, config_only: bool = False):
        self.cfg = cfg
        self.catalog = catalog
        self.dry_run = dry_run
        self.config_only = config_only
        ui_cfg = cfg.get("ui", {})
        self.max_history = int(ui_cfg.get("max_history", 200))
        self.events: deque[LogEvent] = deque(maxlen=self.max_history)
        self.screen = None
        self.status = "CONFIGURAÇÃO" if config_only else "INICIANDO"
        self.mic_name = "desativado" if config_only else "detectando..."
        self.level = 0.0
        self.model_name = str(cfg.get("recognition", {}).get("model", "medium"))
        self.requested_device = str(cfg.get("recognition", {}).get("device", "cuda"))
        self.device = self.requested_device
        self.compute_type = str(cfg.get("recognition", {}).get("compute_type", "float16"))
        self._gpu_diag_cache: dict[str, str] = {}
        self._gpu_diag_at = 0.0
        self.backend = str(cfg.get("action", {}).get("backend", "auto"))
        self.page = self.PAGE_COMMANDS if config_only else self.PAGE_LIVE
        self.item_index = {self.PAGE_COMMANDS: 0, self.PAGE_DESKTOPS: 0}
        self.phrase_index = {self.PAGE_COMMANDS: 0, self.PAGE_DESKTOPS: 0}
        self.focus = "items"
        self.pending = False
        self.saved_revision = 0
        self.flash = ""
        self.flash_until = 0.0
        self.editor: dict | None = None
        self.exit_armed_until = 0.0

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
            curses.init_pair(7, curses.COLOR_BLACK, curses.COLOR_CYAN)
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

    def _color(self, pair: int, bold: bool = False, reverse: bool = False) -> int:
        attr = curses.color_pair(pair) if curses.has_colors() else 0
        if bold:
            attr |= curses.A_BOLD
        if reverse:
            attr |= curses.A_REVERSE
        return attr

    def _add(self, y: int, x: int, text: str, attr: int = 0, width: int | None = None) -> None:
        if self.screen is None:
            return
        h, w = self.screen.getmaxyx()
        if y < 0 or y >= h or x < 0 or x >= w:
            return
        max_width = max(0, w - x - 1) if width is None else min(width, max(0, w - x - 1))
        if max_width <= 0:
            return
        try:
            self.screen.addnstr(y, x, text, max_width, attr)
        except curses.error:
            pass

    def _line(self, y: int, x: int, width: int, char: str = "─", attr: int = 0) -> None:
        self._add(y, x, char * max(0, width), attr, width=width)

    def _vline(self, x: int, y1: int, y2: int, attr: int = 0) -> None:
        for y in range(y1, y2):
            self._add(y, x, "│", attr, width=1)

    def _flash(self, text: str, seconds: float = 2.4) -> None:
        self.flash = text
        self.flash_until = time.monotonic() + seconds
        self.render()

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
        self.render()

    def listening_enabled(self) -> bool:
        return not self.config_only and self.page == self.PAGE_LIVE and self.editor is None

    def consume_saved_revision(self, previous: int) -> int:
        return self.saved_revision if self.saved_revision != previous else previous

    def _current_items(self):
        if self.page == self.PAGE_COMMANDS:
            return list(FIXED_ACTIONS)
        if self.page == self.PAGE_DESKTOPS:
            return list(self.catalog.registry.entries)
        return []

    def _selected_command_id(self) -> str | None:
        items = self._current_items()
        if not items:
            return None
        idx = max(0, min(self.item_index.get(self.page, 0), len(items) - 1))
        self.item_index[self.page] = idx
        item = items[idx]
        if self.page == self.PAGE_COMMANDS:
            return item.id
        return self.catalog.workspace_command_id(item.name)

    def _selected_phrases(self) -> list[str]:
        command_id = self._selected_command_id()
        return self.catalog.command_phrases(command_id) if command_id else []

    def _mark_pending(self) -> None:
        self.pending = True
        self.exit_armed_until = 0.0

    def _save(self) -> None:
        self.catalog.save()
        self.pending = False
        self.saved_revision += 1
        self._flash(f"Salvo em {self.catalog.user_path.name}")

    def _reset_selected(self) -> None:
        command_id = self._selected_command_id()
        if not command_id:
            return
        self.catalog.reset_command(command_id)
        self.phrase_index[self.page] = 0
        self._mark_pending()
        self._flash("Palavras restauradas para o padrão; F10 salva.")

    def _start_editor(self, mode: str) -> None:
        command_id = self._selected_command_id()
        if not command_id:
            self._flash("Nenhum comando selecionado.")
            return
        phrases = self.catalog.command_phrases(command_id)
        phrase_idx = self.phrase_index.get(self.page, 0)
        if mode == "edit" and not phrases:
            self._flash("Não existe palavra para editar. Use A para adicionar.")
            return
        initial = phrases[max(0, min(phrase_idx, len(phrases) - 1))] if mode == "edit" else ""
        self.editor = {
            "mode": mode,
            "command": command_id,
            "index": max(0, min(phrase_idx, len(phrases) - 1)) if phrases else 0,
            "buffer": initial,
        }
        try:
            curses.curs_set(1)
        except curses.error:
            pass
        self.render()

    def _commit_editor(self) -> None:
        if not self.editor:
            return
        command_id = self.editor["command"]
        text = self.editor["buffer"]
        try:
            if self.editor["mode"] == "edit":
                self.catalog.replace_phrase(command_id, int(self.editor["index"]), text)
            else:
                self.catalog.add_phrase(command_id, text)
            self._mark_pending()
            self._flash("Palavra alterada; F10 salva.")
            self.editor = None
            try:
                curses.curs_set(0)
            except curses.error:
                pass
        except (ValueError, IndexError) as exc:
            self._flash(str(exc), 3.5)

    def _remove_selected_phrase(self) -> None:
        command_id = self._selected_command_id()
        if not command_id:
            return
        phrases = self.catalog.command_phrases(command_id)
        if not phrases:
            self._flash("Esse comando não tem palavras cadastradas.")
            return
        idx = max(0, min(self.phrase_index.get(self.page, 0), len(phrases) - 1))
        removed = self.catalog.remove_phrase(command_id, idx)
        self.phrase_index[self.page] = max(0, min(idx, len(phrases) - 2))
        self._mark_pending()
        self._flash(f"Removido: {removed} · F10 salva.")

    def _handle_editor_key(self, key) -> bool:
        if not self.editor:
            return False
        if key in (27, "\x1b"):
            self.editor = None
            try:
                curses.curs_set(0)
            except curses.error:
                pass
            self.render()
            return True
        if key in (curses.KEY_ENTER, 10, 13, "\n", "\r"):
            self._commit_editor()
            return True
        if key in (curses.KEY_BACKSPACE, 127, 8, "\x7f", "\b"):
            self.editor["buffer"] = self.editor["buffer"][:-1]
            self.render()
            return True
        if isinstance(key, str) and key.isprintable() and len(self.editor["buffer"]) < 100:
            self.editor["buffer"] += key
            self.render()
            return True
        return True

    @staticmethod
    def _key_code(key):
        if isinstance(key, int):
            return key
        if key == "\n":
            return 10
        if key == "\r":
            return 13
        if key == "\x1b":
            return 27
        if key == "\t":
            return 9
        if key == "\x7f":
            return 127
        return ord(key) if len(key) == 1 else -1

    def handle_input(self) -> bool:
        if self.screen is None:
            return True
        try:
            key = self.screen.get_wch()
        except curses.error:
            return True
        if self.editor:
            return self._handle_editor_key(key)
        key = self._key_code(key)
        if key == -1:
            return True

        if key in (curses.KEY_F1,):
            self.page = self.PAGE_LIVE if not self.config_only else self.PAGE_COMMANDS
            self.focus = "items"
        elif key == curses.KEY_F2:
            self.page = self.PAGE_COMMANDS
            self.focus = "items"
        elif key == curses.KEY_F3:
            self.catalog.refresh_desktops()
            self.page = self.PAGE_DESKTOPS
            self.focus = "items"
        elif key == curses.KEY_F4:
            self.page = self.PAGE_DIAGNOSTICS
            self.focus = "items"
        elif key in (ord("q"), ord("Q")):
            if self.pending and time.monotonic() > self.exit_armed_until:
                self.exit_armed_until = time.monotonic() + 3.0
                self._flash("Há alterações sem salvar. F10 salva; Q novamente descarta.", 3.0)
                return True
            return False
        elif key == 27:
            if self.page != self.PAGE_LIVE and not self.config_only:
                self.page = self.PAGE_LIVE
                self.focus = "items"
            elif self.config_only:
                if self.pending and time.monotonic() > self.exit_armed_until:
                    self.exit_armed_until = time.monotonic() + 3.0
                    self._flash("Há alterações sem salvar. F10 salva; Esc novamente descarta.", 3.0)
                    return True
                return False
            else:
                return False
        elif key == curses.KEY_F10:
            if self.pending:
                try:
                    self._save()
                except Exception as exc:
                    self._flash(f"Falha ao salvar: {exc}", 4.0)
            else:
                self._flash("Nenhuma alteração pendente.")
        elif self.page in {self.PAGE_COMMANDS, self.PAGE_DESKTOPS}:
            items = self._current_items()
            phrases = self._selected_phrases()
            if key in (9, curses.KEY_RIGHT, curses.KEY_LEFT):
                self.focus = "phrases" if self.focus == "items" else "items"
            elif key in (curses.KEY_UP, ord("k")):
                if self.focus == "items":
                    self.item_index[self.page] = max(0, self.item_index.get(self.page, 0) - 1)
                    self.phrase_index[self.page] = 0
                else:
                    self.phrase_index[self.page] = max(0, self.phrase_index.get(self.page, 0) - 1)
            elif key in (curses.KEY_DOWN, ord("j")):
                if self.focus == "items":
                    self.item_index[self.page] = min(max(0, len(items) - 1), self.item_index.get(self.page, 0) + 1)
                    self.phrase_index[self.page] = 0
                else:
                    self.phrase_index[self.page] = min(max(0, len(phrases) - 1), self.phrase_index.get(self.page, 0) + 1)
            elif key in (curses.KEY_ENTER, 10, 13):
                if self.focus == "items":
                    self.focus = "phrases"
                elif phrases:
                    self._start_editor("edit")
                else:
                    self._start_editor("add")
            elif key in (ord("a"), ord("A")):
                self._start_editor("add")
            elif key in (ord("e"), ord("E")):
                self._start_editor("edit")
            elif key in (curses.KEY_DC, 330, ord("x"), ord("X")):
                self._remove_selected_phrase()
            elif key in (ord("r"), ord("R")):
                self._reset_selected()
        self.render()
        return True

    def _render_header(self, h: int, w: int) -> int:
        mode = "CONFIG" if self.config_only else ("DRY-RUN" if self.dry_run else "ATIVO")
        dirty = " · ALTERADO" if self.pending else ""
        self._line(0, 0, w - 1, attr=self._color(6))
        self._add(0, 2, " VOICE COMMANDS CONTROL CENTER ", self._color(4, True))
        right = f" {mode}{dirty} "
        self._add(0, max(2, w - len(right) - 2), right, self._color(2 if self.pending else 1, True))

        effective_status = self.status
        if not self.config_only and self.page != self.PAGE_LIVE:
            effective_status = "PAUSADO · CONFIGURAÇÃO"
        status_color = 1 if effective_status == "ESCUTANDO" else 2 if "RECONHECENDO" in effective_status or "FALA" in effective_status or "PAUSADO" in effective_status else 4
        self._add(2, 2, "●", self._color(status_color, True))
        self._add(2, 4, effective_status, self._color(status_color, True), width=28)
        self._add(2, 35, "Mic:", self._color(5, True))
        self._add(2, 40, self.mic_name, width=max(10, w - 42))

        bar_width = min(32, max(12, w - 28))
        filled = int(bar_width * self.level)
        meter = "█" * filled + "░" * (bar_width - filled)
        self._add(3, 2, "Nível:", self._color(5, True))
        self._add(3, 9, meter, self._color(1 if self.level >= 0.4 else 4))

        tabs = [
            ("F1", "AO VIVO", self.PAGE_LIVE),
            ("F2", "COMANDOS", self.PAGE_COMMANDS),
            ("F3", "DESKTOPS", self.PAGE_DESKTOPS),
            ("F4", "DIAGNÓSTICO", self.PAGE_DIAGNOSTICS),
        ]
        x = 2
        for key, label, page in tabs:
            if self.config_only and page == self.PAGE_LIVE:
                continue
            text = f" {key} {label} "
            attr = self._color(7, True) if self.page == page and curses.has_colors() else self._color(4, self.page == page, self.page == page)
            self._add(5, x, text, attr)
            x += len(text) + 1
        self._line(6, 0, w - 1, attr=self._color(6))
        return 7

    def _render_live(self, top: int, bottom: int, w: int) -> None:
        left_w = max(38, min(58, w // 2))
        self._vline(left_w, top, bottom, self._color(6))
        self._add(top, 2, "COMANDOS ATIVOS", self._color(4, True))
        self._add(top, left_w + 2, "ÚLTIMOS RECONHECIMENTOS", self._color(4, True))
        row = top + 2
        max_rows = max(1, bottom - row)
        summary = []
        for action in FIXED_ACTIONS:
            phrases = self.catalog.fixed_phrases(action.id)
            if phrases:
                summary.append((action.label, phrases))
        for entry in self.catalog.registry.entries:
            phrases = self.catalog.desktop_phrases(entry.name)
            if phrases:
                summary.append((f"Desktop {entry.index} · {entry.name}", phrases))
        for label, phrases in summary[:max_rows]:
            alias = ", ".join(phrases[:3])
            more = f" +{len(phrases) - 3}" if len(phrases) > 3 else ""
            self._add(row, 2, label, self._color(5, True), width=left_w - 4)
            row += 1
            if row >= bottom:
                break
            self._add(row, 4, f"{alias}{more}", self._color(6), width=left_w - 6)
            row += 1
            if row >= bottom:
                break
        if not summary:
            self._add(row, 2, "Nenhuma palavra ativa. F2/F3 para configurar.", self._color(2), width=left_w - 4)

        events = list(self.events)
        event_rows = max(1, bottom - top - 2)
        shown = events[-max(1, event_rows // 2):]
        row = top + 2
        for event in shown:
            if row >= bottom:
                break
            kind_color = {"ok": 1, "ignored": 5, "cooldown": 2, "error": 3, "info": 4}.get(event.kind, 5)
            self._add(row, left_w + 2, f"{event.when}  {event.heard}", self._color(5, True), width=w - left_w - 4)
            row += 1
            if row >= bottom:
                break
            self._add(row, left_w + 4, event.detail, self._color(kind_color), width=w - left_w - 6)
            row += 1
        if not events:
            self._add(top + 2, left_w + 2, "Fale um comando; a transcrição aparece aqui.", self._color(5), width=w - left_w - 4)

    def _render_catalog_page(self, top: int, bottom: int, w: int) -> None:
        items = self._current_items()
        left_w = max(38, min(58, w // 2))
        self._vline(left_w, top, bottom, self._color(6))
        title = "AÇÕES DISPONÍVEIS" if self.page == self.PAGE_COMMANDS else "DESKTOPS / PROJETOS"
        self._add(top, 2, title, self._color(4, True))
        self._add(top, left_w + 2, "PALAVRAS VINCULADAS", self._color(4, True))

        list_top = top + 2
        visible = max(1, bottom - list_top)
        selected = max(0, min(self.item_index.get(self.page, 0), max(0, len(items) - 1)))
        start = max(0, selected - visible // 2)
        if start + visible > len(items):
            start = max(0, len(items) - visible)

        for row_offset, item in enumerate(items[start:start + visible]):
            idx = start + row_offset
            if self.page == self.PAGE_COMMANDS:
                command_id = item.id
                label = item.label
                category = item.category
                warning = " !" if item.dangerous else ""
            else:
                command_id = self.catalog.workspace_command_id(item.name)
                label = f"{item.index:>2}  {item.name}"
                category = "preservado" if item.preserved else "workspace"
                warning = ""
            phrases = self.catalog.command_phrases(command_id)
            marker = "▶" if idx == selected and self.focus == "items" else " "
            state = "●" if phrases else "○"
            attr = self._color(7, True) if idx == selected and self.focus == "items" and curses.has_colors() else self._color(5, idx == selected, idx == selected and self.focus == "items")
            self._add(list_top + row_offset, 2, f"{marker} {state} {label}{warning}", attr, width=left_w - 4)
            if w > 115:
                self._add(list_top + row_offset, max(24, left_w - 18), f"{len(phrases):>2} · {category}", self._color(6), width=16)

        if not items:
            message = self.catalog.registry.error if self.page == self.PAGE_DESKTOPS else "Nenhuma ação cadastrada."
            self._add(list_top, 2, message, self._color(3), width=left_w - 4)
            return

        command_id = self._selected_command_id()
        phrases = self.catalog.command_phrases(command_id) if command_id else []
        if self.page == self.PAGE_COMMANDS:
            definition = FIXED_ACTION_MAP.get(command_id or "")
            detail_title = definition.label if definition else command_id or ""
            detail = definition.description if definition else ""
            if definition and definition.dangerous:
                detail += "  ATENÇÃO: ação de energia; só será reconhecida se você cadastrar uma palavra."
        else:
            workspace = self.catalog.workspace_name(command_id or "") or ""
            entry = self.catalog.registry.by_name(workspace)
            detail_title = f"Desktop {entry.index} · {entry.name}" if entry else workspace
            detail = "Dizer qualquer palavra abaixo leva diretamente para este workspace/projeto."

        self._add(top + 2, left_w + 2, detail_title, self._color(5, True), width=w - left_w - 4)
        self._add(top + 3, left_w + 2, detail, self._color(6), width=w - left_w - 4)
        phrase_top = top + 5
        phrase_visible = max(1, bottom - phrase_top)
        selected_phrase = max(0, min(self.phrase_index.get(self.page, 0), max(0, len(phrases) - 1)))
        self.phrase_index[self.page] = selected_phrase
        pstart = max(0, selected_phrase - phrase_visible // 2)
        if pstart + phrase_visible > len(phrases):
            pstart = max(0, len(phrases) - phrase_visible)
        for row_offset, phrase in enumerate(phrases[pstart:pstart + phrase_visible]):
            idx = pstart + row_offset
            active = idx == selected_phrase and self.focus == "phrases"
            marker = "▶" if active else " "
            attr = self._color(7, True) if active and curses.has_colors() else self._color(5, active, active)
            self._add(phrase_top + row_offset, left_w + 2, f"{marker} {idx + 1:>2}. {phrase}", attr, width=w - left_w - 4)
        if not phrases:
            self._add(phrase_top, left_w + 2, "Nenhuma palavra. Pressione A para adicionar.", self._color(2), width=w - left_w - 4)

    def _render_diagnostics(self, top: int, bottom: int, w: int) -> None:
        logger = DailyVoiceLogger(self.cfg)
        self.catalog.refresh_desktops()
        now = time.monotonic()
        if not self._gpu_diag_cache or now - self._gpu_diag_at >= 3.0:
            self._gpu_diag_cache = gpu_diagnostics()
            self._gpu_diag_at = now
        rows = [
            ("Modelo Whisper", self.model_name),
            ("Idioma", str(self.cfg.get("recognition", {}).get("language", "pt"))),
            ("GPU solicitada", f"{self.requested_device} / {self.cfg.get('recognition', {}).get('compute_type', 'float16')}"),
            ("Device ativo", f"{self.device} / {self.compute_type}"),
            ("Backend desktop", self.backend),
            ("Frases ativas", str(self.catalog.active_phrase_count())),
            ("Desktops detectados", str(len(self.catalog.registry.entries))),
            ("Config editável", str(self.catalog.user_path)),
            ("Padrões", str(self.catalog.defaults_path)),
            ("Logs diários", str(logger.root)),
            ("DISPLAY", os.environ.get("DISPLAY") or "-"),
            ("WAYLAND_DISPLAY", os.environ.get("WAYLAND_DISPLAY") or "-"),
            ("Sessão", os.environ.get("XDG_SESSION_TYPE") or "-"),
            ("xdotool", shutil.which("xdotool") or "-"),
            ("ydotool", shutil.which("ydotool") or "-"),
            ("wtype", shutil.which("wtype") or "-"),
            ("wpctl", shutil.which("wpctl") or "-"),
            ("pactl", shutil.which("pactl") or "-"),
        ]
        rows.extend(self._gpu_diag_cache.items())
        self._add(top, 2, "DIAGNÓSTICO", self._color(4, True))
        row = top + 2
        label_w = min(24, max(16, w // 5))
        for label, value in rows:
            if row >= bottom:
                break
            self._add(row, 2, f"{label}:", self._color(5, True), width=label_w)
            self._add(row, 2 + label_w, value, self._color(6), width=w - label_w - 4)
            row += 1
        if self.catalog.registry.error:
            self._add(min(bottom - 1, row + 1), 2, f"Desktop registry: {self.catalog.registry.error}", self._color(3), width=w - 4)

    def _render_editor(self, h: int, w: int) -> None:
        if not self.editor:
            return
        command_id = self.editor["command"]
        label = self.catalog.label_for(command_id)
        title = "EDITAR PALAVRA" if self.editor["mode"] == "edit" else "ADICIONAR PALAVRA"
        box_w = min(max(54, len(label) + 10), max(20, w - 8))
        x = max(2, (w - box_w) // 2)
        y = max(7, h // 2 - 3)
        self._add(y, x, "┌" + "─" * (box_w - 2) + "┐", self._color(4, True), width=box_w)
        for row in range(y + 1, min(h - 2, y + 6)):
            self._add(row, x, "│" + " " * (box_w - 2) + "│", self._color(5), width=box_w)
        self._add(y + 6, x, "└" + "─" * (box_w - 2) + "┘", self._color(4, True), width=box_w)
        self._add(y + 1, x + 2, title, self._color(4, True), width=box_w - 4)
        self._add(y + 2, x + 2, label, self._color(6), width=box_w - 4)
        buffer = self.editor["buffer"]
        field_w = box_w - 6
        shown = buffer[-field_w:]
        self._add(y + 4, x + 2, "> " + shown, self._color(5, True), width=box_w - 4)
        self._add(y + 5, x + 2, "Enter confirma · Esc cancela", self._color(6), width=box_w - 4)
        if self.screen is not None:
            try:
                self.screen.move(y + 4, min(x + box_w - 3, x + 4 + len(shown)))
            except curses.error:
                pass

    def render(self) -> None:
        if self.screen is None:
            return
        self.screen.erase()
        h, w = self.screen.getmaxyx()
        if h < 20 or w < 82:
            self._add(0, 0, "VOICE COMMANDS CONTROL CENTER", self._color(4, True))
            self._add(2, 0, "Terminal pequeno. Use pelo menos 82x20.", self._color(2))
            self._add(4, 0, "Q/Esc encerra.")
            self.screen.refresh()
            return

        top = self._render_header(h, w)
        footer_top = h - 4
        if self.page == self.PAGE_LIVE:
            self._render_live(top, footer_top, w)
        elif self.page in {self.PAGE_COMMANDS, self.PAGE_DESKTOPS}:
            self._render_catalog_page(top, footer_top, w)
        else:
            self._render_diagnostics(top, footer_top, w)

        self._line(footer_top, 0, w - 1, attr=self._color(6))
        if self.page in {self.PAGE_COMMANDS, self.PAGE_DESKTOPS}:
            help_line = "↑/↓ escolher  Tab/←/→ painel  Enter editar  A adicionar  Del/X remover  R padrão  F10 salvar"
        else:
            help_line = "F1 ao vivo  F2 comandos  F3 desktops  F4 diagnóstico  Q sair"
        self._add(footer_top + 1, 2, help_line, self._color(6), width=w - 4)
        model_line = f"Whisper {self.model_name} · {self.device}/{self.compute_type} · {self.catalog.active_phrase_count()} palavras ativas · JSON: {self.catalog.user_path.name}"
        self._add(footer_top + 2, 2, model_line, self._color(5), width=w - 4)
        if self.flash and time.monotonic() <= self.flash_until:
            self._add(footer_top + 3, 2, self.flash, self._color(2, True), width=w - 4)
        elif self.page != self.PAGE_LIVE and not self.config_only:
            self._add(footer_top + 3, 2, "Reconhecimento pausado enquanto você configura; F1 volta a escutar.", self._color(4), width=w - 4)

        self._render_editor(h, w)
        try:
            self.screen.refresh()
        except curses.error:
            pass


def run_stdin(cfg: dict, dry_run: bool) -> int:
    catalog = build_catalog()
    matcher = build_matcher(cfg, catalog)
    executor = ActionExecutor(cfg, catalog, dry_run=dry_run)
    print("Modo texto. Digite uma frase; Ctrl+D encerra.")
    for line in sys.stdin:
        text = line.strip()
        match = matcher.match(text)
        if match:
            print(f"{text!r} -> {match.command} ({match.score:.0%}, frase={match.phrase!r})")
            action = execute_match(match, executor)
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
    prefix = {"ok": "OK", "ignored": "IGNORADO", "cooldown": "COOLDOWN", "error": "ERRO", "info": "INFO"}.get(kind, kind.upper())
    suffix = f" -> {detail}" if detail else ""
    print(f"[{datetime.now().strftime('%H:%M:%S')}] {prefix}: {text!r}{suffix}", flush=True)


def _microphone_loop(cfg: dict, dry_run: bool, tui: VoiceTUI | None, catalog: CommandCatalog) -> int:
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
        str(rec_cfg.get("model", "medium")),
        str(rec_cfg.get("language", "pt")),
        str(rec_cfg.get("compute_type", "float16")),
        device,
        initial_prompt=catalog.whisper_prompt(),
        gpu_fallback_compute_type=str(rec_cfg.get("gpu_fallback_compute_type", "int8_float16")),
        cpu_compute_type=str(rec_cfg.get("cpu_compute_type", "int8")),
        allow_cpu_fallback=bool(rec_cfg.get("allow_cpu_fallback", False)),
    )
    if tui:
        tui.device = recognizer.device
        tui.compute_type = recognizer.compute_type
    matcher = build_matcher(cfg, catalog)
    executor = ActionExecutor(cfg, catalog, dry_run=dry_run, verbose=tui is None)
    voice_logger = DailyVoiceLogger(cfg)
    cooldown = float(rec_cfg.get("cooldown_seconds", 0.9))
    last_action_at = 0.0
    catalog_revision = tui.saved_revision if tui else 0

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
            if tui:
                if not tui.handle_input():
                    return 0
                if tui.saved_revision != catalog_revision:
                    catalog_revision = tui.saved_revision
                    matcher = build_matcher(cfg, catalog)
                    recognizer.set_initial_prompt(catalog.whisper_prompt())
                    executor.catalog = catalog
                    tui.log("info", "configuração", f"{catalog.active_phrase_count()} palavras recarregadas")

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

            if tui and not tui.listening_enabled():
                frames = []
                pre_roll.clear()
                in_speech = False
                silent_count = 0
                tui.render()
                continue

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
                detail = f"{command_label(match.command, catalog)} · {match.score:.0%} · ignorado por cooldown"
                voice_logger.log(samples, rate, text, "cooldown", detail, match)
                if tui:
                    tui.log("cooldown", text, detail)
                    tui.set_status("ESCUTANDO")
                else:
                    _plain_log("cooldown", text, detail)
                continue

            try:
                action = execute_match(match, executor)
                detail = f"{command_label(match.command, catalog)} · {match.score:.0%} · {action}"
                voice_logger.log(samples, rate, text, "ok", detail, match)
                if tui:
                    tui.log("ok", text, detail)
                else:
                    _plain_log("ok", text, detail)
                last_action_at = now
            except Exception as exc:
                detail = f"{command_label(match.command, catalog)} · falhou: {exc}"
                voice_logger.log(samples, rate, text, "error", detail, match)
                if tui:
                    tui.log("error", text, detail)
                else:
                    _plain_log("error", text, detail)
            finally:
                if tui:
                    tui.set_status("ESCUTANDO")


def run_microphone(cfg: dict, dry_run: bool, use_tui: bool) -> int:
    catalog = build_catalog()
    if use_tui:
        with VoiceTUI(cfg, catalog, dry_run=dry_run) as tui:
            return _microphone_loop(cfg, dry_run, tui, catalog)
    return _microphone_loop(cfg, dry_run, None, catalog)


def run_config_tui(cfg: dict) -> int:
    catalog = build_catalog()
    if not (sys.stdin.isatty() and sys.stdout.isatty()):
        raise RuntimeError("--configure precisa de um terminal interativo")
    with VoiceTUI(cfg, catalog, dry_run=True, config_only=True) as tui:
        while tui.handle_input():
            tui.render()
            time.sleep(0.04)
    return 0


def list_commands(cfg: dict) -> int:
    del cfg
    catalog = build_catalog()
    print("AÇÕES")
    for action in FIXED_ACTIONS:
        phrases = catalog.fixed_phrases(action.id)
        print(f"{action.id}\t{action.label}\t{len(phrases)}\t{', '.join(phrases)}")
    print("DESKTOPS")
    for entry in catalog.registry.entries:
        phrases = catalog.desktop_phrases(entry.name)
        print(f"workspace::{entry.name}\tDesktop {entry.index} · {entry.name}\t{len(phrases)}\t{', '.join(phrases)}")
    return 0


def doctor(cfg: dict) -> int:
    catalog = build_catalog()
    print(f"Python: {sys.version.split()[0]}")
    print(f"Config: {DEFAULT_CONFIG}")
    print(f"Commands JSON: {catalog.user_path}")
    print(f"Commands defaults: {catalog.defaults_path}")
    print(f"DISPLAY: {os.environ.get('DISPLAY') or '-'}")
    print(f"WAYLAND_DISPLAY: {os.environ.get('WAYLAND_DISPLAY') or '-'}")
    print(f"xdotool: {shutil.which('xdotool') or '-'}")
    print(f"ydotool: {shutil.which('ydotool') or '-'}")
    print(f"wtype: {shutil.which('wtype') or '-'}")
    print(f"wpctl: {shutil.which('wpctl') or '-'}")
    print(f"pactl: {shutil.which('pactl') or '-'}")
    print(f"TUI: {'disponível' if sys.stdout.isatty() else 'desativada (stdout não é TTY)'}")
    rec_cfg = cfg.get("recognition", {})
    print(f"Whisper model: {rec_cfg.get('model', 'medium')}")
    print(f"Whisper device solicitado: {rec_cfg.get('device', 'cuda')}")
    print(f"Whisper compute principal: {rec_cfg.get('compute_type', 'float16')}")
    print(f"Whisper compute fallback GPU: {rec_cfg.get('gpu_fallback_compute_type', 'int8_float16')}")
    print(f"Fallback CPU: {'SIM' if rec_cfg.get('allow_cpu_fallback', False) else 'NÃO'}")
    for label, value in gpu_diagnostics().items():
        print(f"{label}: {value}")
    logger = DailyVoiceLogger(cfg)
    print(f"Voice logs: {logger.root} ({'ativo' if logger.enabled else 'desativado'})")
    print(f"Desktops: {len(catalog.registry.entries)}" + (f" ({catalog.registry.error})" if catalog.registry.error else ""))
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
    print(f"comandos: {catalog.active_phrase_count()} frases cadastradas")
    return 0


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Comandos de voz locais com TUI e atalhos editáveis")
    parser.add_argument("--config", type=Path, default=DEFAULT_CONFIG)
    parser.add_argument("--stdin", action="store_true", help="testa reconhecimento digitando frases")
    parser.add_argument("--dry-run", action="store_true", help="reconhece, mas não executa ações")
    parser.add_argument("--doctor", action="store_true", help="diagnóstico de dependências e ambiente")
    parser.add_argument("--configure", action="store_true", help="abre somente a TUI de configuração, sem carregar Whisper")
    parser.add_argument("--list-commands", action="store_true", help="lista ações, desktops e palavras cadastradas")
    ui = parser.add_mutually_exclusive_group()
    ui.add_argument("--tui", action="store_true", help="força interface TUI no terminal")
    ui.add_argument("--no-tui", action="store_true", help="usa log textual simples")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    cfg = load_config(args.config)
    use_tui = args.tui or (not args.no_tui and sys.stdin.isatty() and sys.stdout.isatty())
    try:
        if args.doctor:
            return doctor(cfg)
        if args.list_commands:
            return list_commands(cfg)
        if args.configure:
            return run_config_tui(cfg)
        if args.stdin:
            return run_stdin(cfg, args.dry_run)
        return run_microphone(cfg, args.dry_run, use_tui)
    except KeyboardInterrupt:
        if not use_tui:
            print("\nEncerrado.")
        return 130
    except Exception as exc:
        print(f"ERRO: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
