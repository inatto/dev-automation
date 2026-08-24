import unittest
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from voice_commands import CommandMatcher, load_config, build_matcher


class MatcherTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cfg = load_config(Path(__file__).resolve().parents[1] / "config.toml")
        cls.matcher = build_matcher(cfg)

    def assertCommand(self, text, expected):
        match = self.matcher.match(text)
        self.assertIsNotNone(match, text)
        self.assertEqual(match.command, expected, text)

    def test_next_aliases(self):
        for text in ["vai", "avança", "avanca", "pra frente", "continua", "pode ir", "próximo desktop"]:
            self.assertCommand(text, "next_desktop")

    def test_previous_aliases(self):
        for text in ["volta", "recua", "recuar", "pra trás", "desktop anterior", "pode voltar"]:
            self.assertCommand(text, "previous_desktop")

    def test_accents_are_ignored(self):
        self.assertCommand("AVANÇA", "next_desktop")
        self.assertCommand("pra tras", "previous_desktop")

    def test_long_conversation_does_not_trigger_short_word(self):
        self.assertIsNone(self.matcher.match("vai buscar aquilo na outra janela depois"))

    def test_noise_is_ignored(self):
        self.assertIsNone(self.matcher.match("hoje está calor demais"))


if __name__ == "__main__":
    unittest.main()
