import tempfile
import unittest
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from command_catalog import CommandCatalog, DesktopRegistry, DEFAULT_COMMANDS_PATH
from voice_commands import ActionExecutor, load_config


class ActionExecutorTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        script = root / "desktops.sh"
        script.write_text(
            "#!/usr/bin/env bash\nprintf '1\\tLAZER (preservado)\\n2\\torbital-legal\\n3\\tlrdp1\\n'\n",
            encoding="utf-8",
        )
        registry = DesktopRegistry(script)
        self.catalog = CommandCatalog(registry=registry, defaults_path=DEFAULT_COMMANDS_PATH, user_path=root / "commands.json")
        self.cfg = load_config(Path(__file__).resolve().parents[1] / "config.toml")
        self.executor = ActionExecutor(self.cfg, self.catalog, dry_run=True, verbose=False)

    def tearDown(self):
        self.tmp.cleanup()

    def test_specific_workspace_is_absolute_target(self):
        result = self.executor.execute("workspace::orbital-legal")
        self.assertIn("orbital-legal", result)
        self.assertIn("índice 2/3", result)

    def test_relative_and_system_actions_exist(self):
        self.assertIn("2 passo", self.executor.execute("next_two_desktops"))
        self.assertIn("som desligado", self.executor.execute("mute_audio"))
        self.assertIn("calculadora", self.executor.execute("open_calculator"))


if __name__ == "__main__":
    unittest.main()
