#!/usr/bin/env python3
from datetime import datetime
from pathlib import Path
from zoneinfo import ZoneInfo
import re

path = Path(__file__).resolve().parents[1] / "VERSION"
current = path.read_text(encoding="utf-8").strip() if path.exists() else ""
match = re.fullmatch(r"\d{4}\.\d{2}\.\d{2}-V(\d+)", current)
number = int(match.group(1)) + 1 if match else 1
today = datetime.now(ZoneInfo("America/Sao_Paulo"))
value = f"{today:%Y.%m.%d}-V{number}"
path.write_text(value + "\n", encoding="utf-8")
print(value)
