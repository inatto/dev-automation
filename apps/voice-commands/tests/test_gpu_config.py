import sys
import types
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from voice_commands import WhisperRecognizer


class FakeWhisperModel:
    attempts = []

    def __init__(self, model_name, device, compute_type):
        self.__class__.attempts.append((device, compute_type))
        if device == "cuda" and compute_type == "float16":
            raise RuntimeError("Requested float16 compute type is not supported efficiently")
        self.device = device
        self.compute_type = compute_type

    def transcribe(self, samples, **kwargs):
        return iter(()), object()


class GpuConfigTests(unittest.TestCase):
    def setUp(self):
        FakeWhisperModel.attempts = []
        self.module = types.SimpleNamespace(WhisperModel=FakeWhisperModel)

    def test_gpu_compute_falls_back_on_gpu_before_cpu(self):
        with patch.dict(sys.modules, {"faster_whisper": self.module}):
            recognizer = WhisperRecognizer(
                "medium",
                "pt",
                "float16",
                "cuda",
                gpu_fallback_compute_type="int8_float16",
                cpu_compute_type="int8",
                allow_cpu_fallback=False,
            )
        self.assertEqual(recognizer.device, "cuda")
        self.assertEqual(recognizer.compute_type, "int8_float16")
        self.assertEqual(
            FakeWhisperModel.attempts,
            [("cuda", "float16"), ("cuda", "int8_float16")],
        )

    def test_gpu_error_does_not_silently_drop_to_cpu(self):
        class BrokenCuda(FakeWhisperModel):
            def __init__(self, model_name, device, compute_type):
                self.__class__.attempts.append((device, compute_type))
                if device == "cuda":
                    raise RuntimeError("Library libcublas.so.12 is not found or cannot be loaded")
                super().__init__(model_name, device, compute_type)

        BrokenCuda.attempts = []
        module = types.SimpleNamespace(WhisperModel=BrokenCuda)
        with patch.dict(sys.modules, {"faster_whisper": module}):
            with self.assertRaisesRegex(RuntimeError, "install.sh --gpu"):
                WhisperRecognizer(
                    "medium",
                    "pt",
                    "float16",
                    "cuda",
                    allow_cpu_fallback=False,
                )
        self.assertTrue(BrokenCuda.attempts)
        self.assertFalse(any(device == "cpu" for device, _ in BrokenCuda.attempts))


if __name__ == "__main__":
    unittest.main()
