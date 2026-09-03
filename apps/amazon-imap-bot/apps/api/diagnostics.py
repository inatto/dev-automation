from __future__ import annotations

import faulthandler
import logging
import signal
import threading
from logging.handlers import RotatingFileHandler
from pathlib import Path

_logger = logging.getLogger("amazon-imap-bot")
_logger.setLevel(logging.INFO)
_logger.propagate = False
_crash_handle = None
_configured = False


def configure(config_root: Path) -> tuple[Path, Path]:
    global _configured, _crash_handle
    root = Path(config_root)
    root.mkdir(parents=True, exist_ok=True)
    runtime_path = root / "runtime.log"
    crash_path = root / "crash.log"
    if not _configured:
        handler = RotatingFileHandler(runtime_path, maxBytes=5 * 1024 * 1024, backupCount=3, encoding="utf-8")
        handler.setFormatter(logging.Formatter("%(asctime)s.%(msecs)03d [%(threadName)s] %(message)s", "%Y-%m-%d %H:%M:%S"))
        _logger.handlers.clear()
        _logger.addHandler(handler)
        _crash_handle = crash_path.open("a", encoding="utf-8", buffering=1)
        faulthandler.enable(file=_crash_handle, all_threads=True)
        if hasattr(signal, "SIGUSR1"):
            try:
                faulthandler.register(signal.SIGUSR1, file=_crash_handle, all_threads=True, chain=False)
            except Exception:
                pass
        previous = threading.excepthook
        def hook(args):
            _logger.exception("THREAD CRASH name=%s", getattr(args.thread, "name", "?"), exc_info=(args.exc_type, args.exc_value, args.exc_traceback))
            previous(args)
        threading.excepthook = hook
        _configured = True
    trace(f"DIAGNOSTICS runtime={runtime_path} crash={crash_path}")
    return runtime_path, crash_path


def trace(text: str) -> None:
    try:
        _logger.info(str(text))
    except Exception:
        pass
