from __future__ import annotations

import tempfile
import wave
from pathlib import Path

from .errors import GptConsoleError


SUPPORTED_AUDIO = {".flac", ".m4a", ".mp3", ".mp4", ".mpeg", ".mpga", ".ogg", ".wav", ".webm"}


def validate_audio(path: Path) -> Path:
    path = path.expanduser().resolve()
    if not path.is_file():
        raise GptConsoleError(f"arquivo de áudio não encontrado: {path}")
    if path.suffix.lower() not in SUPPORTED_AUDIO:
        raise GptConsoleError(f"formato de áudio não suportado: {path.suffix or 'sem extensão'}")
    if path.stat().st_size > 25 * 1024 * 1024:
        raise GptConsoleError("o arquivo de áudio excede 25 MiB")
    return path


def wav_duration(path: Path) -> float:
    if path.suffix.lower() != ".wav":
        return 0.0
    try:
        with wave.open(str(path), "rb") as wav:
            return wav.getnframes() / float(wav.getframerate())
    except (OSError, wave.Error, ZeroDivisionError):
        return 0.0


def record_microphone(seconds: int, sample_rate: int = 16000) -> Path:
    try:
        import numpy as np
        import sounddevice as sd
    except ImportError as exc:
        raise GptConsoleError("gravação exige numpy e sounddevice; execute apps/gpt-console/install.sh") from exc
    try:
        samples = sd.rec(int(seconds * sample_rate), samplerate=sample_rate, channels=1, dtype="float32")
        sd.wait()
    except Exception as exc:
        raise GptConsoleError(f"falha ao gravar microfone: {exc}") from exc
    pcm = np.clip(samples.reshape(-1), -1.0, 1.0)
    pcm16 = (pcm * 32767.0).astype(np.int16)
    handle = tempfile.NamedTemporaryFile(prefix="gpt-console-", suffix=".wav", delete=False)
    handle.close()
    path = Path(handle.name)
    try:
        with wave.open(str(path), "wb") as wav:
            wav.setnchannels(1)
            wav.setsampwidth(2)
            wav.setframerate(sample_rate)
            wav.writeframes(pcm16.tobytes())
    except Exception:
        path.unlink(missing_ok=True)
        raise
    return path
