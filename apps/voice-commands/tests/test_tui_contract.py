import unittest
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from voice_commands import command_label, load_config


class TUIContractTests(unittest.TestCase):
    def test_labels(self):
        self.assertEqual(command_label("next_desktop"), "PRÓXIMO DESKTOP")
        self.assertEqual(command_label("previous_desktop"), "DESKTOP ANTERIOR")

    def test_ui_config(self):
        cfg = load_config(Path(__file__).resolve().parents[1] / "config.toml")
        self.assertGreaterEqual(cfg["ui"]["max_history"], 50)
        self.assertIn("device", cfg["recognition"])


if __name__ == "__main__":
    unittest.main()
