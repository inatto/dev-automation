from __future__ import annotations

import json
import os
import curses
import stat
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

APP = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(APP))

from gpt_console.catalog_store import CatalogStore
from gpt_console.config_store import ConfigStore, Settings
from gpt_console.errors import ZipWorkflowError
from gpt_console.models import ActionDefinition, ActionGroup, ParameterDefinition
from gpt_console.openai_gateway import OpenAIGateway
from gpt_console.paths import AppPaths
from gpt_console.usage_store import UsageStore
from gpt_console.zip_workflow import ZipWorkflow
from gpt_console.tui import GptConsoleTui, SCREENS


class Object:
    def __init__(self, **values):
        self.__dict__.update(values)


class TuiNavigationTests(unittest.TestCase):
    def tui(self):
        instance = GptConsoleTui.__new__(GptConsoleTui)
        instance.future = None
        instance.running = True
        instance.screen = "dashboard"
        instance.menu_index = 0
        instance.menu_focused = True
        instance.groups = []
        return instance

    def test_arrows_select_module_without_opening_it(self):
        tui = self.tui()
        tui.handle_key(curses.KEY_DOWN)
        self.assertEqual(tui.menu_index, 1)
        self.assertEqual(SCREENS[tui.menu_index][0], "actions")
        self.assertEqual(tui.screen, "dashboard")
        self.assertTrue(tui.menu_focused)

    def test_enter_opens_selected_module_and_escape_returns_to_menu(self):
        tui = self.tui()
        tui.handle_key(curses.KEY_DOWN)
        tui.handle_key(10)
        self.assertEqual(tui.screen, "actions")
        self.assertFalse(tui.menu_focused)
        tui.handle_key(27)
        self.assertEqual(tui.screen, "actions")
        self.assertEqual(tui.menu_index, 1)
        self.assertTrue(tui.menu_focused)


class ResponseObject(Object):
    def __init__(self, dump: dict, **values):
        super().__init__(**values)
        self.dump = dump

    def model_dump(self, mode="json"):
        return self.dump


def paths_for(root: Path) -> AppPaths:
    app = root / "apps" / "gpt-console"
    defaults = app / "defaults" / "actions"
    defaults.mkdir(parents=True, exist_ok=True)
    config = root / ".config" / "gpt-console"
    return AppPaths(app, root, config, config / "actions", defaults)


def sample_group() -> ActionGroup:
    return ActionGroup(
        project_id="orbital-app",
        label="Orbital App",
        zip_name="orbital-app.zip",
        actions=(
            ActionDefinition(
                name="find_member",
                description="Find one member.",
                parameters=(ParameterDefinition(name="query", type="string", required=True),),
            ),
        ),
    )


class ConfigStoreTests(unittest.TestCase):
    def test_settings_are_saved_under_project_dot_config_and_masked(self):
        with tempfile.TemporaryDirectory() as temp:
            paths = paths_for(Path(temp))
            store = ConfigStore(paths)
            settings = Settings(api_key="test-api-key-123456789", admin_api_key="test-admin-key-987654321")
            store.save(settings)
            self.assertEqual(store.path, Path(temp) / ".config" / "gpt-console" / "settings.env")
            self.assertEqual(stat.S_IMODE(store.path.stat().st_mode), 0o600)
            loaded = store.load()
            self.assertEqual(loaded.api_key, settings.api_key)
            public = loaded.public_dict()
            self.assertNotIn(settings.api_key, json.dumps(public))
            self.assertNotIn(settings.admin_api_key, json.dumps(public))


class CatalogStoreTests(unittest.TestCase):
    def test_catalog_round_trip_and_function_schema(self):
        with tempfile.TemporaryDirectory() as temp:
            store = CatalogStore(paths_for(Path(temp)))
            path = store.save(sample_group())
            self.assertEqual(path.name, "orbital-app.json")
            loaded = store.load("orbital-app")
            tool = loaded.function_tools()[0]
            self.assertEqual(tool["name"], "find_member")
            self.assertTrue(tool["strict"])
            self.assertEqual(tool["parameters"]["required"], ["query"])
            self.assertFalse(tool["parameters"]["additionalProperties"])

    def test_optional_parameters_are_nullable_but_required_by_strict_schema(self):
        action = ActionDefinition(
            name="view_member",
            description="View a member.",
            parameters=(ParameterDefinition(name="member_id", required=False),),
        )
        tool = action.function_tool()
        self.assertEqual(tool["parameters"]["required"], ["member_id"])
        self.assertEqual(tool["parameters"]["properties"]["member_id"]["type"], ["string", "null"])

    def test_upsert_and_remove_action(self):
        with tempfile.TemporaryDirectory() as temp:
            store = CatalogStore(paths_for(Path(temp)))
            store.save(sample_group())
            action = ActionDefinition(name="view_member", description="View a member.")
            self.assertEqual(len(store.upsert_action("orbital-app", action).actions), 2)
            self.assertEqual(len(store.remove_action("orbital-app", "find_member").actions), 1)

    def test_deleted_default_is_not_recreated_after_initial_bootstrap(self):
        with tempfile.TemporaryDirectory() as temp:
            paths = paths_for(Path(temp))
            (paths.defaults_root / "orbital-app.json").write_text(
                json.dumps(sample_group().as_dict()), encoding="utf-8"
            )
            store = CatalogStore(paths)
            self.assertEqual(store.bootstrap_defaults(), 1)
            store.delete("orbital-app")
            self.assertEqual(store.bootstrap_defaults(), 0)
            self.assertEqual(store.list_groups(), [])


class GatewayTests(unittest.TestCase):
    def client_factory(self, response):
        class Responses:
            def create(self, **kwargs):
                self.kwargs = kwargs
                return response

        client = Object(
            responses=Responses(),
            models=Object(retrieve=lambda name: Object(id=name)),
        )
        return lambda **kwargs: client

    def test_function_call_becomes_validated_action_json(self):
        with tempfile.TemporaryDirectory() as temp:
            response = Object(
                id="resp_1",
                output=[{"type": "function_call", "name": "find_member", "arguments": '{"query":"Pedro"}'}],
                output_text="",
                usage=Object(input_tokens=11, output_tokens=4),
            )
            usage = UsageStore(paths_for(Path(temp)))
            gateway = OpenAIGateway(
                Settings(api_key="test"),
                usage,
                client_factory=self.client_factory(response),
            )
            match = gateway.classify(sample_group(), "procure o Pedro")
            self.assertTrue(match.matched)
            self.assertEqual(match.action, "find_member")
            self.assertEqual(match.parameters, {"query": "Pedro"})
            self.assertEqual(usage.load().input_tokens, 11)

    def test_no_function_call_is_a_safe_no_match(self):
        with tempfile.TemporaryDirectory() as temp:
            response = Object(
                id="resp_2",
                output=[{"type": "message"}],
                output_text="Posso localizar, visualizar ou editar um associado.",
                usage=Object(input_tokens=8, output_tokens=8),
            )
            gateway = OpenAIGateway(
                Settings(api_key="test"),
                UsageStore(paths_for(Path(temp))),
                client_factory=self.client_factory(response),
            )
            match = gateway.classify(sample_group(), "qual é a previsão do tempo?")
            self.assertFalse(match.matched)
            self.assertIn("localizar", match.message)

    def test_optional_null_parameters_are_removed_from_public_result(self):
        with tempfile.TemporaryDirectory() as temp:
            group = ActionGroup(
                project_id="orbital-app",
                label="Orbital App",
                zip_name="orbital-app.zip",
                actions=(
                    ActionDefinition(
                        name="view_member",
                        description="View a member.",
                        parameters=(
                            ParameterDefinition(name="member_id", required=False),
                            ParameterDefinition(name="query", required=False),
                        ),
                    ),
                ),
            )
            response = Object(
                id="resp_3",
                output=[{"type": "function_call", "name": "view_member", "arguments": '{"member_id":null,"query":"Pedro"}'}],
                output_text="",
                usage=Object(input_tokens=4, output_tokens=2),
            )
            gateway = OpenAIGateway(
                Settings(api_key="test"),
                UsageStore(paths_for(Path(temp))),
                client_factory=self.client_factory(response),
            )
            self.assertEqual(gateway.classify(group, "abra o Pedro").parameters, {"query": "Pedro"})

    def test_zip_is_attached_to_code_interpreter_container_and_cleaned_up(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            source = root / "project.zip"
            with zipfile.ZipFile(source, "w") as archive:
                archive.writestr("app.py", "print('ok')\n")

            class Files:
                deleted = []

                def create(self, **kwargs):
                    return Object(id="file_input")

                def delete(self, file_id):
                    self.deleted.append(file_id)

            response = ResponseObject(
                {
                    "output": [
                        {
                            "type": "message",
                            "content": [
                                {
                                    "type": "output_text",
                                    "annotations": [
                                        {
                                            "type": "container_file_citation",
                                            "container_id": "cntr_1",
                                            "file_id": "cfile_1",
                                            "filename": "project.zip",
                                        }
                                    ],
                                }
                            ],
                        }
                    ]
                },
                id="resp_zip",
                output_text="feito",
                usage=Object(input_tokens=20, output_tokens=5),
            )

            class Responses:
                kwargs = None

                def create(self, **kwargs):
                    self.kwargs = kwargs
                    return response

            client = Object(files=Files(), responses=Responses())
            usage = UsageStore(paths_for(root))
            gateway = OpenAIGateway(Settings(api_key="test"), usage, client_factory=lambda **kwargs: client)
            gateway._download_container_file = lambda container_id, file_id: b"PK-test"  # type: ignore[method-assign]
            content, _, response_id, _, _ = gateway.edit_zip(source, "revise")
            self.assertEqual(content, b"PK-test")
            self.assertEqual(response_id, "resp_zip")
            container = client.responses.kwargs["tools"][0]["container"]
            self.assertEqual(container["file_ids"], ["file_input"])
            self.assertNotIn("input_file", json.dumps(client.responses.kwargs["input"]))
            self.assertEqual(client.files.deleted, ["file_input"])
            self.assertEqual(usage.load().zip_jobs, 1)


class FakeZipGateway:
    def __init__(self, payload: bytes):
        self.payload = payload

    def edit_zip(self, source: Path, request_text: str):
        return self.payload, "feito", "resp_zip", 20, 5


class ZipWorkflowTests(unittest.TestCase):
    @staticmethod
    def archive_bytes(path: Path, name: str = "app.py") -> bytes:
        with zipfile.ZipFile(path, "w") as archive:
            archive.writestr(name, "print('ok')\n")
        return path.read_bytes()

    def test_result_is_validated_and_saved_with_dev_manager_compatible_suffix(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            code = root / "Code"
            downloads = root / "Downloads"
            code.mkdir()
            output_seed = root / "result.zip"
            payload = self.archive_bytes(output_seed)
            self.archive_bytes(code / "orbital-app.zip", "old.py")
            settings = Settings(api_key="test", code_root=str(code), downloads_root=str(downloads))
            workflow = ZipWorkflow(settings, FakeZipGateway(payload))  # type: ignore[arg-type]
            result = workflow.run(sample_group(), "adicione um teste")
            destination = Path(result.destination)
            self.assertTrue(destination.is_file())
            self.assertRegex(destination.name, r"^orbital-app\(gpt-\d{8}-\d{6}\)\.zip$")
            self.assertEqual(ZipWorkflow.validate_archive(destination)[0], 1)

    def test_path_traversal_is_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            bad = Path(temp) / "bad.zip"
            with zipfile.ZipFile(bad, "w") as archive:
                archive.writestr("../escape.txt", "no")
            with self.assertRaises(ZipWorkflowError):
                ZipWorkflow.validate_archive(bad)

    def test_extra_root_folder_is_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            source = root / "source.zip"
            output = root / "output.zip"
            with zipfile.ZipFile(source, "w") as archive:
                archive.writestr("app.py", "ok")
                archive.writestr("README.md", "ok")
            with zipfile.ZipFile(output, "w") as archive:
                archive.writestr("project/app.py", "ok")
                archive.writestr("project/README.md", "ok")
            with self.assertRaises(ZipWorkflowError):
                ZipWorkflow._validate_root_shape(source, output)


if __name__ == "__main__":
    unittest.main()
