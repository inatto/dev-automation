from __future__ import annotations

import json
import re
import subprocess
import unicodedata
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable

APP_DIR = Path(__file__).resolve().parent
PROJECT_ROOT = APP_DIR.parents[1]
DEFAULT_COMMANDS_PATH = APP_DIR / "commands.defaults.json"
USER_COMMANDS_PATH = APP_DIR / "commands.json"
DESKTOPS_SCRIPT = PROJECT_ROOT / "scripts" / "desktops.sh"


def normalize(text: str) -> str:
    text = unicodedata.normalize("NFKD", text.lower())
    text = "".join(ch for ch in text if not unicodedata.combining(ch))
    text = re.sub(r"[^a-z0-9\s]", " ", text)
    return " ".join(text.split())


@dataclass(frozen=True)
class ActionDefinition:
    id: str
    label: str
    category: str
    description: str
    dangerous: bool = False


@dataclass(frozen=True)
class DesktopEntry:
    index: int
    name: str
    preserved: bool = False


FIXED_ACTIONS: tuple[ActionDefinition, ...] = (
    ActionDefinition("next_desktop", "Avançar tela", "Navegação", "Vai para o próximo desktop/workspace."),
    ActionDefinition("previous_desktop", "Recuar tela", "Navegação", "Volta para o desktop/workspace anterior."),
    ActionDefinition("next_two_desktops", "Avançar duas telas", "Navegação", "Avança dois desktops/workspaces."),
    ActionDefinition("previous_two_desktops", "Recuar duas telas", "Navegação", "Volta dois desktops/workspaces."),
    ActionDefinition("first_desktop", "Primeira tela", "Navegação", "Vai para o primeiro desktop (LAZER)."),
    ActionDefinition("last_desktop", "Última tela", "Navegação", "Vai para o último desktop configurado."),
    ActionDefinition("mute_audio", "Desligar som", "Áudio", "Silencia a saída de áudio padrão."),
    ActionDefinition("unmute_audio", "Ligar som", "Áudio", "Reativa a saída de áudio padrão."),
    ActionDefinition("toggle_mute", "Alternar mudo", "Áudio", "Alterna entre som ligado e mudo."),
    ActionDefinition("volume_up", "Aumentar volume", "Áudio", "Aumenta o volume padrão em 5%."),
    ActionDefinition("volume_down", "Diminuir volume", "Áudio", "Diminui o volume padrão em 5%."),
    ActionDefinition("lock_screen", "Bloquear tela", "Sistema", "Bloqueia a sessão sem desligar o computador."),
    ActionDefinition("suspend_system", "Suspender computador", "Sistema", "Suspende o computador. Sem palavra padrão para evitar disparo acidental.", True),
    ActionDefinition("open_calculator", "Abrir calculadora", "Aplicativos", "Abre a calculadora do Ubuntu."),
    ActionDefinition("open_text_editor", "Abrir bloco de notas", "Aplicativos", "Abre o editor de texto disponível."),
    ActionDefinition("open_email", "Abrir e-mail", "Aplicativos", "Abre o aplicativo/handler padrão de e-mail."),
    ActionDefinition("open_terminal", "Abrir terminal", "Aplicativos", "Abre um novo terminal."),
    ActionDefinition("open_files", "Abrir arquivos", "Aplicativos", "Abre a pasta pessoal no gerenciador de arquivos."),
    ActionDefinition("open_browser", "Abrir navegador", "Aplicativos", "Abre o navegador padrão."),
    ActionDefinition("open_settings", "Abrir configurações", "Aplicativos", "Abre as configurações do GNOME."),
)
FIXED_ACTION_MAP = {action.id: action for action in FIXED_ACTIONS}


class DesktopRegistry:
    def __init__(self, script: Path = DESKTOPS_SCRIPT):
        self.script = Path(script)
        self.entries: list[DesktopEntry] = []
        self.error = ""
        self.refresh()

    def refresh(self) -> list[DesktopEntry]:
        try:
            proc = subprocess.run(
                ["bash", str(self.script), "--list"],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                encoding="utf-8",
                errors="replace",
                timeout=4,
                check=False,
            )
        except (OSError, subprocess.TimeoutExpired) as exc:
            self.entries = []
            self.error = str(exc)
            return self.entries
        if proc.returncode != 0:
            self.entries = []
            self.error = (proc.stderr or proc.stdout or f"exit {proc.returncode}").strip()
            return self.entries

        entries: list[DesktopEntry] = []
        for raw in proc.stdout.splitlines():
            match = re.match(r"^\s*(\d+)\t(.+?)\s*$", raw)
            if not match:
                continue
            index = int(match.group(1))
            label = match.group(2).strip()
            preserved = label.endswith(" (preservado)")
            if preserved:
                label = label[: -len(" (preservado)")].rstrip()
            entries.append(DesktopEntry(index=index, name=label, preserved=preserved))
        self.entries = entries
        self.error = "" if entries else "nenhum desktop encontrado"
        return entries

    def by_name(self, name: str) -> DesktopEntry | None:
        needle = name.casefold()
        return next((entry for entry in self.entries if entry.name.casefold() == needle), None)

    def by_index(self, index: int) -> DesktopEntry | None:
        return next((entry for entry in self.entries if entry.index == index), None)


class CommandCatalog:
    """Editable phrase catalog backed by JSON inside apps/voice-commands."""

    def __init__(
        self,
        registry: DesktopRegistry | None = None,
        defaults_path: Path = DEFAULT_COMMANDS_PATH,
        user_path: Path = USER_COMMANDS_PATH,
    ):
        self.registry = registry or DesktopRegistry()
        self.defaults_path = Path(defaults_path)
        self.user_path = Path(user_path)
        self._defaults = self._read_json(self.defaults_path, required=True)
        self._data = self._load_user_data()
        self._ensure_shape()

    @staticmethod
    def _read_json(path: Path, required: bool = False) -> dict:
        try:
            raw = path.read_text(encoding="utf-8")
        except FileNotFoundError:
            if required:
                raise RuntimeError(f"catálogo padrão não encontrado: {path}")
            return {}
        except OSError as exc:
            raise RuntimeError(f"não foi possível ler {path}: {exc}") from exc
        try:
            data = json.loads(raw)
        except json.JSONDecodeError as exc:
            raise RuntimeError(f"JSON inválido em {path}: linha {exc.lineno}, coluna {exc.colno}") from exc
        if not isinstance(data, dict):
            raise RuntimeError(f"JSON inválido em {path}: raiz deve ser objeto")
        return data

    def _load_user_data(self) -> dict:
        user = self._read_json(self.user_path, required=False)
        defaults = self._defaults
        result = {"version": 1, "commands": {}, "desktops": {}}
        default_commands = defaults.get("commands", {}) if isinstance(defaults.get("commands", {}), dict) else {}
        user_commands = user.get("commands", {}) if isinstance(user.get("commands", {}), dict) else {}
        for action in FIXED_ACTIONS:
            source = user_commands[action.id] if action.id in user_commands else default_commands.get(action.id, {})
            result["commands"][action.id] = {"phrases": self._phrase_list(source)}

        default_desktops = defaults.get("desktops", {}) if isinstance(defaults.get("desktops", {}), dict) else {}
        user_desktops = user.get("desktops", {}) if isinstance(user.get("desktops", {}), dict) else {}
        for entry in self.registry.entries:
            if entry.name in user_desktops:
                source = user_desktops[entry.name]
            elif entry.name in default_desktops:
                source = default_desktops[entry.name]
            else:
                source = {"phrases": self._suggest_desktop_phrases(entry.name)}
            result["desktops"][entry.name] = {"phrases": self._phrase_list(source)}

        # Mantém mapeamentos de desktops não presentes nesta máquina/configuração.
        # Eles reaparecem automaticamente se o desktop voltar no futuro.
        for name, source in user_desktops.items():
            if isinstance(name, str) and name not in result["desktops"]:
                result["desktops"][name] = {"phrases": self._phrase_list(source)}
        return result

    @staticmethod
    def _phrase_list(source) -> list[str]:
        if isinstance(source, dict):
            source = source.get("phrases", [])
        if not isinstance(source, list):
            return []
        output: list[str] = []
        seen: set[str] = set()
        for value in source:
            if not isinstance(value, str):
                continue
            phrase = " ".join(value.strip().split())
            key = normalize(phrase)
            if not phrase or not key or key in seen:
                continue
            seen.add(key)
            output.append(phrase)
        return output

    @staticmethod
    def _suggest_desktop_phrases(name: str) -> list[str]:
        normalized_name = " ".join(name.replace("-", " ").replace("_", " ").split())
        known = {
            "orbital-legal": ["jurídico", "juridico", "orbital legal"],
            "orbital-content": ["conteúdo", "conteudo", "orbital content"],
            "lrdp1": ["rdp1", "rdp um", "remoto um"],
            "lrdp2": ["rdp2", "rdp dois", "remoto dois"],
        }
        return known.get(name.casefold(), [normalized_name])

    def _ensure_shape(self) -> None:
        self._data.setdefault("version", 1)
        self._data.setdefault("commands", {})
        self._data.setdefault("desktops", {})
        for action in FIXED_ACTIONS:
            self._data["commands"].setdefault(action.id, {"phrases": []})
        for entry in self.registry.entries:
            self._data["desktops"].setdefault(
                entry.name,
                {"phrases": self._suggest_desktop_phrases(entry.name)},
            )

    def refresh_desktops(self) -> None:
        self.registry.refresh()
        self._ensure_shape()

    @staticmethod
    def workspace_command_id(name: str) -> str:
        return f"workspace::{name}"

    @staticmethod
    def workspace_name(command_id: str) -> str | None:
        prefix = "workspace::"
        return command_id[len(prefix):] if command_id.startswith(prefix) else None

    def command_phrases(self, command_id: str) -> list[str]:
        workspace = self.workspace_name(command_id)
        if workspace is not None:
            item = self._data.get("desktops", {}).get(workspace, {})
        else:
            item = self._data.get("commands", {}).get(command_id, {})
        return list(self._phrase_list(item))

    def fixed_phrases(self, action_id: str) -> list[str]:
        return self.command_phrases(action_id)

    def desktop_phrases(self, name: str) -> list[str]:
        return self.command_phrases(self.workspace_command_id(name))

    def label_for(self, command_id: str) -> str:
        workspace = self.workspace_name(command_id)
        if workspace is not None:
            entry = self.registry.by_name(workspace)
            if entry:
                return f"DESKTOP {entry.index} · {entry.name}"
            return f"DESKTOP · {workspace}"
        definition = FIXED_ACTION_MAP.get(command_id)
        return definition.label.upper() if definition else command_id.upper()

    def definition_for(self, command_id: str) -> ActionDefinition | None:
        return FIXED_ACTION_MAP.get(command_id)

    def matcher_commands(self) -> dict[str, list[str]]:
        commands: dict[str, list[str]] = {}
        for action in FIXED_ACTIONS:
            phrases = self.fixed_phrases(action.id)
            if phrases:
                commands[action.id] = phrases
        for entry in self.registry.entries:
            phrases = self.desktop_phrases(entry.name)
            if phrases:
                commands[self.workspace_command_id(entry.name)] = phrases
        return commands

    def all_phrase_owners(self, exclude_command: str | None = None) -> dict[str, str]:
        owners: dict[str, str] = {}
        for command_id, phrases in self.matcher_commands().items():
            if command_id == exclude_command:
                continue
            for phrase in phrases:
                key = normalize(phrase)
                if key:
                    owners.setdefault(key, command_id)
        return owners

    def _container_for(self, command_id: str) -> tuple[dict, str]:
        workspace = self.workspace_name(command_id)
        if workspace is not None:
            self._data.setdefault("desktops", {}).setdefault(workspace, {"phrases": []})
            return self._data["desktops"], workspace
        if command_id not in FIXED_ACTION_MAP:
            raise KeyError(command_id)
        self._data.setdefault("commands", {}).setdefault(command_id, {"phrases": []})
        return self._data["commands"], command_id

    def add_phrase(self, command_id: str, phrase: str) -> None:
        phrase = " ".join(phrase.strip().split())
        key = normalize(phrase)
        if not key:
            raise ValueError("a palavra/frase está vazia")
        owner = self.all_phrase_owners(exclude_command=command_id).get(key)
        if owner:
            raise ValueError(f"'{phrase}' já leva para {self.label_for(owner)}")
        container, key_name = self._container_for(command_id)
        phrases = self._phrase_list(container[key_name])
        if key not in {normalize(item) for item in phrases}:
            phrases.append(phrase)
        container[key_name] = {"phrases": phrases}

    def replace_phrase(self, command_id: str, index: int, phrase: str) -> None:
        phrases = self.command_phrases(command_id)
        if index < 0 or index >= len(phrases):
            raise IndexError(index)
        phrase = " ".join(phrase.strip().split())
        normalized = normalize(phrase)
        if not normalized:
            raise ValueError("a palavra/frase está vazia")
        owner = self.all_phrase_owners(exclude_command=command_id).get(normalized)
        if owner:
            raise ValueError(f"'{phrase}' já leva para {self.label_for(owner)}")
        for other_index, other in enumerate(phrases):
            if other_index != index and normalize(other) == normalized:
                raise ValueError(f"'{phrase}' já está cadastrada neste comando")
        phrases[index] = phrase
        container, key_name = self._container_for(command_id)
        container[key_name] = {"phrases": phrases}

    def remove_phrase(self, command_id: str, index: int) -> str:
        phrases = self.command_phrases(command_id)
        if index < 0 or index >= len(phrases):
            raise IndexError(index)
        removed = phrases.pop(index)
        container, key_name = self._container_for(command_id)
        container[key_name] = {"phrases": phrases}
        return removed

    def reset_command(self, command_id: str) -> None:
        workspace = self.workspace_name(command_id)
        if workspace is not None:
            defaults = self._defaults.get("desktops", {}) if isinstance(self._defaults.get("desktops", {}), dict) else {}
            source = defaults.get(workspace, {"phrases": self._suggest_desktop_phrases(workspace)})
            phrases = self._phrase_list(source)
        else:
            defaults = self._defaults.get("commands", {}) if isinstance(self._defaults.get("commands", {}), dict) else {}
            phrases = self._phrase_list(defaults.get(command_id, {}))
        container, key_name = self._container_for(command_id)
        container[key_name] = {"phrases": phrases}

    def save(self) -> None:
        # Materializa somente dados válidos e estáveis. Escrita atômica evita JSON pela metade.
        output = {
            "version": 1,
            "commands": {
                action.id: {"phrases": self.fixed_phrases(action.id)}
                for action in FIXED_ACTIONS
            },
            "desktops": {
                name: {"phrases": self.desktop_phrases(name)}
                for name in sorted(self._data.get("desktops", {}), key=str.casefold)
            },
        }
        self.user_path.parent.mkdir(parents=True, exist_ok=True)
        tmp = self.user_path.with_suffix(self.user_path.suffix + ".tmp")
        tmp.write_text(json.dumps(output, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        tmp.replace(self.user_path)
        self._data = output

    def whisper_prompt(self, limit: int = 52) -> str:
        phrases: list[str] = []
        seen: set[str] = set()
        # Prioriza frases curtas: são justamente as mais fáceis de o Whisper confundir.
        candidates: list[str] = []
        for values in self.matcher_commands().values():
            candidates.extend(values)
        candidates.sort(key=lambda value: (len(value.split()), len(value), value.casefold()))
        for phrase in candidates:
            key = normalize(phrase)
            if not key or key in seen:
                continue
            seen.add(key)
            phrases.append(phrase)
            if len(phrases) >= limit:
                break
        return "Comandos curtos em português. Vocabulário esperado: " + ", ".join(phrases) + "."

    def active_phrase_count(self) -> int:
        return sum(len(values) for values in self.matcher_commands().values())

    def fixed_actions(self) -> Iterable[ActionDefinition]:
        return FIXED_ACTIONS
