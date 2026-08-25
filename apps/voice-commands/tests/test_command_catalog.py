import json
import tempfile
import unittest
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from command_catalog import CommandCatalog, DesktopRegistry, DEFAULT_COMMANDS_PATH
from voice_commands import CommandMatcher


class CommandCatalogTests(unittest.TestCase):
    def make_catalog(self, tmp: Path):
        desktop_script = tmp / "desktops.sh"
        desktop_script.write_text(
            "#!/usr/bin/env bash\nprintf '1\\tLAZER (preservado)\\n2\\torbital-legal\\n3\\torbital-content\\n4\\tlrdp1\\n5\\tlrdp2\\n'\n",
            encoding="utf-8",
        )
        registry = DesktopRegistry(desktop_script)
        user_path = tmp / "commands.json"
        return CommandCatalog(registry=registry, defaults_path=DEFAULT_COMMANDS_PATH, user_path=user_path), user_path

    def test_requested_desktop_aliases_are_present(self):
        with tempfile.TemporaryDirectory() as raw:
            catalog, _ = self.make_catalog(Path(raw))
            matcher = CommandMatcher(catalog.matcher_commands(), 0.82)
            self.assertEqual(matcher.match("jurídico").command, "workspace::orbital-legal")
            self.assertEqual(matcher.match("conteúdo").command, "workspace::orbital-content")
            self.assertEqual(matcher.match("rdp1").command, "workspace::lrdp1")
            self.assertEqual(matcher.match("rdp dois").command, "workspace::lrdp2")

    def test_add_remove_save_and_reload(self):
        with tempfile.TemporaryDirectory() as raw:
            tmp = Path(raw)
            catalog, user_path = self.make_catalog(tmp)
            catalog.add_phrase("workspace::orbital-legal", "processos")
            catalog.save()
            self.assertTrue(user_path.is_file())
            payload = json.loads(user_path.read_text(encoding="utf-8"))
            self.assertIn("processos", payload["desktops"]["orbital-legal"]["phrases"])

            catalog2, _ = self.make_catalog(tmp)
            self.assertIn("processos", catalog2.desktop_phrases("orbital-legal"))
            while catalog2.fixed_phrases("suspend_system"):
                catalog2.remove_phrase("suspend_system", 0)
            catalog2.save()
            catalog3, _ = self.make_catalog(tmp)
            self.assertEqual(catalog3.fixed_phrases("suspend_system"), [])

    def test_duplicate_phrase_across_actions_is_rejected(self):
        with tempfile.TemporaryDirectory() as raw:
            catalog, _ = self.make_catalog(Path(raw))
            with self.assertRaisesRegex(ValueError, "já leva para"):
                catalog.add_phrase("previous_desktop", "vai")

    def test_edit_preserves_position_and_rejects_same_command_duplicate(self):
        with tempfile.TemporaryDirectory() as raw:
            catalog, _ = self.make_catalog(Path(raw))
            original = catalog.fixed_phrases("next_desktop")
            catalog.replace_phrase("next_desktop", 0, "anda")
            edited = catalog.fixed_phrases("next_desktop")
            self.assertEqual(edited[0], "anda")
            self.assertEqual(edited[1:], original[1:])
            with self.assertRaisesRegex(ValueError, "já está cadastrada"):
                catalog.replace_phrase("next_desktop", 0, edited[1])

    def test_whisper_prompt_contains_custom_vocabulary(self):
        with tempfile.TemporaryDirectory() as raw:
            catalog, _ = self.make_catalog(Path(raw))
            prompt = catalog.whisper_prompt()
            self.assertIn("jurídico", prompt)
            self.assertIn("conteúdo", prompt)


if __name__ == "__main__":
    unittest.main()
