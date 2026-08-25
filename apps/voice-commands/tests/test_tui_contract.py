import unittest
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from voice_commands import command_label, load_config, WhisperRecognizer


class TUIContractTests(unittest.TestCase):
    def test_labels(self):
        self.assertEqual(command_label("next_desktop"), "AVANÇAR TELA")
        self.assertEqual(command_label("previous_desktop"), "RECUAR TELA")
        self.assertEqual(command_label("workspace::orbital-legal"), "DESKTOP · orbital-legal")

    def test_ui_config(self):
        root = Path(__file__).resolve().parents[1]
        cfg = load_config(root / "config.toml")
        self.assertGreaterEqual(cfg["ui"]["max_history"], 50)
        self.assertEqual(cfg["recognition"]["device"], "cuda")
        self.assertEqual(cfg["recognition"]["model"], "medium")
        self.assertEqual(cfg["recognition"]["compute_type"], "float16")
        self.assertEqual(cfg["recognition"]["gpu_fallback_compute_type"], "int8_float16")
        self.assertFalse(cfg["recognition"]["allow_cpu_fallback"])
        self.assertTrue((root / "commands.defaults.json").is_file())

    def test_cuda_runtime_detection(self):
        self.assertTrue(WhisperRecognizer._is_cuda_runtime_error(RuntimeError("Library libcublas.so.12 is not found or cannot be loaded")))
        self.assertTrue(WhisperRecognizer._is_cuda_runtime_error(RuntimeError("cuDNN failed to initialize")))
        self.assertFalse(WhisperRecognizer._is_cuda_runtime_error(RuntimeError("model file is corrupt")))


if __name__ == "__main__":
    unittest.main()
