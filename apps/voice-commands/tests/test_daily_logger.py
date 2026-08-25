import json
import tempfile
import unittest
import wave
from pathlib import Path
import sys

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from voice_commands import DailyVoiceLogger, Match


class DailyVoiceLoggerTests(unittest.TestCase):
    def test_persists_wav_and_transcription(self):
        with tempfile.TemporaryDirectory() as tmp:
            logger = DailyVoiceLogger({"logging": {"enabled": True, "directory": tmp}})
            samples = np.zeros(1600, dtype=np.float32)
            match = Match("next_desktop", "avança", 0.95)
            wav_path = logger.log(samples, 16000, "Avança.", "ok", "PRÓXIMO DESKTOP", match)

            self.assertIsNotNone(wav_path)
            self.assertTrue(wav_path.exists())
            with wave.open(str(wav_path), "rb") as fh:
                self.assertEqual(fh.getframerate(), 16000)
                self.assertEqual(fh.getnchannels(), 1)
                self.assertEqual(fh.getsampwidth(), 2)

            day_dir = wav_path.parent
            payload = json.loads((day_dir / "events.jsonl").read_text(encoding="utf-8").strip())
            self.assertEqual(payload["text"], "Avança.")
            self.assertEqual(payload["command"], "next_desktop")
            self.assertEqual(payload["audio"], wav_path.name)
            self.assertIn("Avança.", (day_dir / "transcriptions.tsv").read_text(encoding="utf-8"))

    def test_empty_transcription_is_not_saved(self):
        with tempfile.TemporaryDirectory() as tmp:
            logger = DailyVoiceLogger({"logging": {"enabled": True, "directory": tmp}})
            result = logger.log(np.zeros(100, dtype=np.float32), 16000, "", "ignored")
            self.assertIsNone(result)
            self.assertEqual(list(Path(tmp).iterdir()), [])


if __name__ == "__main__":
    unittest.main()
