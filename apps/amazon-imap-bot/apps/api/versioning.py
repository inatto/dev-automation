from pathlib import Path


def get_version() -> str:
    path = Path(__file__).resolve().parents[2] / "VERSION"
    return path.read_text(encoding="utf-8").strip() if path.is_file() else "unknown"
