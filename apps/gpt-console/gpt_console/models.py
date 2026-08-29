from __future__ import annotations

import re
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Any

from .errors import CatalogError


ACTION_NAME = re.compile(r"^[a-z][a-z0-9_]{1,63}$")
GROUP_ID = re.compile(r"^[a-z0-9][a-z0-9_-]{1,63}$")
PARAMETER_TYPES = {"string", "integer", "number", "boolean"}


@dataclass(frozen=True)
class ParameterDefinition:
    name: str
    type: str = "string"
    description: str = ""
    required: bool = False
    enum: tuple[Any, ...] = ()

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> "ParameterDefinition":
        item = cls(
            name=str(data.get("name", "")).strip(),
            type=str(data.get("type", "string")).strip(),
            description=str(data.get("description", "")).strip(),
            required=bool(data.get("required", False)),
            enum=tuple(data.get("enum") or ()),
        )
        item.validate()
        return item

    def validate(self) -> None:
        if not ACTION_NAME.fullmatch(self.name):
            raise CatalogError(f"parâmetro inválido: {self.name!r}; use snake_case em inglês")
        if self.type not in PARAMETER_TYPES:
            raise CatalogError(f"tipo inválido em {self.name}: {self.type}")
        if self.enum and self.type not in {"string", "integer", "number"}:
            raise CatalogError(f"enum não suportado para {self.name}:{self.type}")

    def json_schema(self) -> dict[str, Any]:
        schema_type: Any = self.type if self.required else [self.type, "null"]
        schema: dict[str, Any] = {"type": schema_type}
        if self.description:
            schema["description"] = self.description
        if self.enum:
            schema["enum"] = list(self.enum) if self.required else [*self.enum, None]
        return schema


@dataclass(frozen=True)
class ActionDefinition:
    name: str
    description: str
    parameters: tuple[ParameterDefinition, ...] = ()

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> "ActionDefinition":
        item = cls(
            name=str(data.get("name", "")).strip(),
            description=str(data.get("description", "")).strip(),
            parameters=tuple(ParameterDefinition.from_dict(value) for value in data.get("parameters") or ()),
        )
        item.validate()
        return item

    def validate(self) -> None:
        if not ACTION_NAME.fullmatch(self.name):
            raise CatalogError(f"ação inválida: {self.name!r}; use snake_case em inglês")
        if not self.description:
            raise CatalogError(f"ação {self.name} está sem descrição")
        names = [item.name for item in self.parameters]
        if len(names) != len(set(names)):
            raise CatalogError(f"ação {self.name} possui parâmetros duplicados")

    def function_tool(self) -> dict[str, Any]:
        properties = {item.name: item.json_schema() for item in self.parameters}
        # Strict function calling exige todos os campos em required. Campos
        # semanticamente opcionais usam type=[tipo, "null"].
        required = [item.name for item in self.parameters]
        return {
            "type": "function",
            "name": self.name,
            "description": self.description,
            "parameters": {
                "type": "object",
                "properties": properties,
                "required": required,
                "additionalProperties": False,
            },
            "strict": True,
        }

    def as_dict(self) -> dict[str, Any]:
        return {
            "name": self.name,
            "description": self.description,
            "parameters": [asdict(item) | {"enum": list(item.enum)} for item in self.parameters],
        }


@dataclass(frozen=True)
class ActionGroup:
    project_id: str
    label: str
    zip_name: str
    instructions: str = ""
    actions: tuple[ActionDefinition, ...] = ()
    schema_version: int = 1

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> "ActionGroup":
        project = data.get("project") or {}
        item = cls(
            project_id=str(project.get("id", "")).strip(),
            label=str(project.get("label", "")).strip(),
            zip_name=str(project.get("zip_name", "")).strip(),
            instructions=str(data.get("instructions", "")).strip(),
            actions=tuple(ActionDefinition.from_dict(value) for value in data.get("actions") or ()),
            schema_version=int(data.get("schema_version", 1)),
        )
        item.validate()
        return item

    def validate(self) -> None:
        if self.schema_version != 1:
            raise CatalogError(f"schema_version não suportado em {self.project_id or '?'}: {self.schema_version}")
        if not GROUP_ID.fullmatch(self.project_id):
            raise CatalogError(f"id de projeto inválido: {self.project_id!r}")
        if not self.label:
            raise CatalogError(f"projeto {self.project_id} está sem label")
        zip_path = Path(self.zip_name)
        if not self.zip_name.lower().endswith(".zip") or zip_path.name != self.zip_name:
            raise CatalogError(f"zip_name inválido em {self.project_id}: {self.zip_name!r}")
        names = [item.name for item in self.actions]
        if len(names) != len(set(names)):
            raise CatalogError(f"projeto {self.project_id} possui ações duplicadas")

    def function_tools(self) -> list[dict[str, Any]]:
        return [action.function_tool() for action in self.actions]

    def action(self, name: str) -> ActionDefinition | None:
        return next((item for item in self.actions if item.name == name), None)

    def as_dict(self) -> dict[str, Any]:
        return {
            "schema_version": self.schema_version,
            "project": {"id": self.project_id, "label": self.label, "zip_name": self.zip_name},
            "instructions": self.instructions,
            "actions": [action.as_dict() for action in self.actions],
        }


@dataclass(frozen=True)
class ActionMatch:
    matched: bool
    action: str = ""
    parameters: dict[str, Any] = field(default_factory=dict)
    message: str = ""
    response_id: str = ""
    input_tokens: int = 0
    output_tokens: int = 0

    def as_dict(self) -> dict[str, Any]:
        return asdict(self)


@dataclass(frozen=True)
class ZipJobResult:
    project_id: str
    source: str
    destination: str
    response_id: str
    summary: str
    input_tokens: int = 0
    output_tokens: int = 0

    def as_dict(self) -> dict[str, Any]:
        return asdict(self)
