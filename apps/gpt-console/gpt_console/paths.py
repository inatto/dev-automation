from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path


def _expanded(value: str) -> Path:
    return Path(os.path.expandvars(os.path.expanduser(value))).resolve()


@dataclass(frozen=True)
class AppPaths:
    app_dir: Path
    project_root: Path
    config_root: Path
    catalogs_root: Path
    defaults_root: Path

    @classmethod
    def discover(cls) -> "AppPaths":
        app_dir = Path(__file__).resolve().parents[1]
        project_root = app_dir.parents[1]
        configured = os.environ.get("GPT_CONSOLE_CONFIG_ROOT", "").strip()
        config_root = _expanded(configured) if configured else project_root / ".config" / "gpt-console"
        return cls(
            app_dir=app_dir,
            project_root=project_root,
            config_root=config_root,
            catalogs_root=config_root / "actions",
            defaults_root=app_dir / "defaults" / "actions",
        )
