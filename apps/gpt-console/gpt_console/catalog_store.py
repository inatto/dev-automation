from __future__ import annotations

import json
import os
import shutil
from dataclasses import replace
from pathlib import Path

from .errors import CatalogError
from .models import ActionDefinition, ActionGroup
from .paths import AppPaths


class CatalogStore:
    def __init__(self, paths: AppPaths | None = None):
        self.paths = paths or AppPaths.discover()

    def bootstrap_defaults(self) -> int:
        self.paths.catalogs_root.mkdir(parents=True, exist_ok=True)
        marker = self.paths.config_root / ".defaults-initialized"
        if marker.exists():
            return 0
        created = 0
        if not any(self.paths.catalogs_root.glob("*.json")):
            for source in sorted(self.paths.defaults_root.glob("*.json")):
                destination = self.paths.catalogs_root / source.name
                try:
                    shutil.copyfile(source, destination)
                except OSError as exc:
                    raise CatalogError(f"não foi possível inicializar {destination}: {exc}") from exc
                created += 1
        try:
            marker.write_text("1\n", encoding="ascii")
        except OSError as exc:
            raise CatalogError(f"não foi possível marcar a inicialização dos catálogos: {exc}") from exc
        return created

    def list_groups(self, bootstrap: bool = True) -> list[ActionGroup]:
        if bootstrap:
            self.bootstrap_defaults()
        if not self.paths.catalogs_root.exists():
            return []
        groups = [self.load_path(path) for path in sorted(self.paths.catalogs_root.glob("*.json"))]
        ids = [group.project_id for group in groups]
        if len(ids) != len(set(ids)):
            raise CatalogError("há ids de projeto duplicados nos catálogos")
        return groups

    def load(self, project_id: str) -> ActionGroup:
        self._safe_id(project_id)
        path = self.paths.catalogs_root / f"{project_id}.json"
        if not path.exists():
            raise CatalogError(f"grupo de ações não encontrado: {project_id}")
        return self.load_path(path)

    @staticmethod
    def load_path(path: Path) -> ActionGroup:
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except OSError as exc:
            raise CatalogError(f"não foi possível ler {path}: {exc}") from exc
        except json.JSONDecodeError as exc:
            raise CatalogError(f"JSON inválido em {path}:{exc.lineno}: {exc.msg}") from exc
        if not isinstance(data, dict):
            raise CatalogError(f"catálogo deve ser um objeto JSON: {path}")
        group = ActionGroup.from_dict(data)
        if path.stem != group.project_id:
            raise CatalogError(f"arquivo {path.name} deve ter project.id={path.stem!r}")
        return group

    def save(self, group: ActionGroup) -> Path:
        group.validate()
        self.paths.catalogs_root.mkdir(parents=True, exist_ok=True)
        path = self.paths.catalogs_root / f"{group.project_id}.json"
        content = json.dumps(group.as_dict(), ensure_ascii=False, indent=2) + "\n"
        self._atomic_write(path, content)
        return path

    def delete(self, project_id: str) -> None:
        self._safe_id(project_id)
        path = self.paths.catalogs_root / f"{project_id}.json"
        try:
            path.unlink()
        except FileNotFoundError:
            return
        except OSError as exc:
            raise CatalogError(f"não foi possível remover {path}: {exc}") from exc

    def upsert_action(self, project_id: str, action: ActionDefinition, original_name: str = "") -> ActionGroup:
        group = self.load(project_id)
        actions = list(group.actions)
        target = original_name or action.name
        index = next((i for i, item in enumerate(actions) if item.name == target), None)
        if index is None:
            if any(item.name == action.name for item in actions):
                raise CatalogError(f"ação já existe: {action.name}")
            actions.append(action)
        else:
            if action.name != target and any(item.name == action.name for item in actions):
                raise CatalogError(f"ação já existe: {action.name}")
            actions[index] = action
        updated = replace(group, actions=tuple(actions))
        self.save(updated)
        return updated

    def remove_action(self, project_id: str, name: str) -> ActionGroup:
        group = self.load(project_id)
        actions = tuple(item for item in group.actions if item.name != name)
        if len(actions) == len(group.actions):
            raise CatalogError(f"ação não encontrada: {name}")
        updated = replace(group, actions=actions)
        self.save(updated)
        return updated

    @staticmethod
    def _safe_id(project_id: str) -> None:
        if not project_id or Path(project_id).name != project_id or any(value in project_id for value in ("/", "\\", "..")):
            raise CatalogError(f"id de projeto inseguro: {project_id!r}")

    @staticmethod
    def _atomic_write(path: Path, content: str) -> None:
        temp = path.with_suffix(path.suffix + ".tmp")
        old_umask = os.umask(0o077)
        try:
            temp.write_text(content, encoding="utf-8", newline="\n")
            os.replace(temp, path)
        except OSError as exc:
            raise CatalogError(f"não foi possível salvar {path}: {exc}") from exc
        finally:
            os.umask(old_umask)
            try:
                temp.unlink()
            except OSError:
                pass
