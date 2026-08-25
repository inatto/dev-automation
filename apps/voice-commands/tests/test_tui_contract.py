import unittest
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from voice_commands import command_label, load_config, WhisperRecognizer


class TUIContractTests(unittest.TestCase):
    def test_labels(self):
        self.assertEqual(command_label("next_desktop"), "PRÓXIMO DESKTOP")
        self.assertEqual(command_label("previous_desktop"), "DESKTOP ANTERIOR")

    def test_ui_config(self):
        cfg = load_config(Path(__file__).resolve().parents[1] / "config.toml")
        self.assertGreaterEqual(cfg["ui"]["max_history"], 50)
        self.assertEqual(cfg["recognition"]["device"], "cpu")

    def test_cuda_runtime_detection(self):
        self.assertTrue(WhisperRecognizer._is_cuda_runtime_error(RuntimeError("Library libcublas.so.12 is not found or cannot be loaded")))
        self.assertTrue(WhisperRecognizer._is_cuda_runtime_error(RuntimeError("cuDNN failed to initialize")))
        self.assertFalse(WhisperRecognizer._is_cuda_runtime_error(RuntimeError("model file is corrupt")))


if __name__ == "__main__":
    unittest.main()
