#!/usr/bin/env python3
from __future__ import annotations

import os
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "dev-automation.py"


class DevAutomationSyncTest(unittest.TestCase):
    def make_fake_tools(self, root: Path, initially_authenticated: bool = True) -> tuple[Path, Path, Path]:
        bindir = root / "bin"
        bindir.mkdir(exist_ok=True)
        state = root / "auth-state"
        log = root / "calls.log"
        if initially_authenticated:
            state.write_text("yes")

        gh = bindir / "gh"
        gh.write_text(textwrap.dedent(f'''\
            #!/usr/bin/env bash
            set -euo pipefail
            echo "gh $*" >> {str(log)!r}
            STATE={str(state)!r}
            if [[ "$1 $2" == "auth status" ]]; then
              [[ -f "$STATE" ]] && exit 0 || exit 1
            fi
            if [[ "$1 $2" == "auth login" ]]; then
              touch "$STATE"
              exit 0
            fi
            if [[ "$1 $2" == "auth setup-git" ]]; then exit 0; fi
            if [[ "$1 $2" == "config set" ]]; then exit 0; fi
            if [[ "$1 $2" == "api user" ]]; then echo "danielmaiax"; exit 0; fi
            if [[ "$1" == "api" && "$2" == "--paginate" ]]; then
              printf 'alpha\\towner/alpha\\thttps://github.com/owner/alpha.git\\n'
              printf 'beta\\towner/beta\\thttps://github.com/owner/beta.git\\n'
              printf 'fallback\\tother/fallback\\thttps://github.com/other/fallback.git\\n'
              exit 0
            fi
            echo "unexpected gh args: $*" >&2
            exit 9
        '''))
        gh.chmod(0o755)

        git = bindir / "git"
        git.write_text(textwrap.dedent(f'''\
            #!/usr/bin/env bash
            set -euo pipefail
            echo "git $*" >> {str(log)!r}
            if [[ "$1" == "clone" ]]; then
              mkdir -p "$3/.git"
              exit 0
            fi
            if [[ "$1" == "-C" && "$3" == "remote" ]]; then exit 0; fi
            if [[ "$1" == "-C" && "$3" == "fetch" ]]; then exit 0; fi
            if [[ "$1" == "-C" && "$3" == "rev-parse" ]]; then exit 1; fi
            exit 0
        '''))
        git.chmod(0o755)
        return bindir, state, log

    def run_sync(self, temp: Path, *, initially_authenticated: bool = True):
        code = temp / "Code"
        config = temp / "config"
        config.mkdir(exist_ok=True)
        projects = config / "projects"
        projects.write_text("""\
#ignored
bots/alpha
bots/alpha/apps/child
orgs/beta
orgs/fallback
""")
        repos = config / "repos"
        repos.write_text("""\
bots/alpha|https://github.com/owner/alpha.git
orgs/beta|https://github.com/owner/beta.git
""")
        bindir, state, log = self.make_fake_tools(temp, initially_authenticated)
        env = os.environ.copy()
        env["PATH"] = f"{bindir}:{env['PATH']}"
        cmd = [
            "python3", str(SCRIPT),
            "--code-root", str(code),
            "--projects-file", str(projects),
            "--repositories-file", str(repos),
        ]
        result = subprocess.run(cmd, env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        return result, code, state, log

    def test_clones_roots_skips_children_and_uses_fallback(self):
        with tempfile.TemporaryDirectory() as td:
            result, code, _state, log = self.run_sync(Path(td))
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertTrue((code / "bots/alpha/.git").is_dir())
            self.assertFalse((code / "bots/alpha/apps/child/.git").exists())
            self.assertTrue((code / "orgs/beta/.git").is_dir())
            self.assertTrue((code / "orgs/fallback/.git").is_dir())
            calls = log.read_text()
            self.assertIn("https://github.com/other/fallback.git", calls)
            self.assertIn("[subprojeto] bots/alpha/apps/child -> incluído em bots/alpha", result.stdout)

    def test_is_idempotent_existing_repositories_are_fetched(self):
        with tempfile.TemporaryDirectory() as td:
            temp = Path(td)
            result, code, _state, first_log = self.run_sync(temp)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            first_log.write_text("")
            # Run again with freshly generated fake tools but same Code tree.
            result2, _code2, _state2, log2 = self.run_sync(temp)
            self.assertEqual(result2.returncode, 0, result2.stdout + result2.stderr)
            calls = log2.read_text()
            self.assertIn("fetch --all --prune", calls)
            self.assertNotIn("git clone", calls)

    def test_requests_login_when_no_account_is_authenticated(self):
        with tempfile.TemporaryDirectory() as td:
            result, _code, state, log = self.run_sync(Path(td), initially_authenticated=False)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertTrue(state.exists())
            self.assertIn("gh auth login --hostname github.com --git-protocol https --web", log.read_text())
            self.assertIn("Nenhum usuário GitHub autenticado", result.stdout)


if __name__ == "__main__":
    unittest.main()
