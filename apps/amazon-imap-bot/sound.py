from __future__ import annotations

import shutil
import subprocess
from pathlib import Path


def notify(sound_file: Path) -> None:
    if sound_file.is_file():
        for command in ("paplay", "pw-play", "aplay"):
            binary = shutil.which(command)
            if not binary:
                continue
            args = [binary, str(sound_file)]
            if command == "aplay":
                args.insert(1, "-q")
            try:
                subprocess.Popen(args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                return
            except OSError:
                pass
    try:
        print("\a", end="", flush=True)
    except Exception:
        pass
