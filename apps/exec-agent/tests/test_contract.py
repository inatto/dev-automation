from __future__ import annotations

import ast
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


class ExecAgentContractTests(unittest.TestCase):
    def test_python_files_compile(self) -> None:
        for path in (ROOT / "agent").rglob("*.py"):
            ast.parse(path.read_text(encoding="utf-8"), filename=str(path))

    def test_required_deploy_scripts_exist(self) -> None:
        for name in ("setup.sh", "start.sh", "test.sh", "contaja-login.sh"):
            self.assertTrue((ROOT / "deploy" / "local" / name).is_file(), name)

    def test_first_flow_stops_after_opening_invoice(self) -> None:
        text = (ROOT / "agent" / "contaja.py").read_text(encoding="utf-8")
        self.assertIn("nenhuma nota é emitida", text)
        self.assertIn("Emitir NFS-e", text)


if __name__ == "__main__":
    unittest.main()
