from __future__ import annotations

import queue
import sys
import tempfile
from email import policy
from email.parser import BytesParser
from pathlib import Path
from types import SimpleNamespace

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from attachments import AttachmentFiles
from config import Account
from monitor import Monitor
from ses import SesSender
from store import Store


class FakeSes:
    @staticmethod
    def new_message_id(account):
        return f"<manual-{account.email.replace('@', '-')}-1>"


def test_new_manual_email_is_always_pending_and_stages_attachments():
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        downloads = tmp / "Downloads"
        downloads.mkdir()
        (downloads / "documento.txt").write_text("conteudo", encoding="utf-8")

        account = Account(email="suporte@example.com", password="x", display_name="Suporte")
        monitor = Monitor.__new__(Monitor)
        monitor.settings = SimpleNamespace(accounts=(account,))
        monitor.store = Store(tmp / "memory.store")
        monitor.store.set_external_send_enabled(True, updated_by="test")
        monitor.accounts_by_email = {account.email: account}
        monitor.ses = FakeSes()
        monitor.attachment_files = AttachmentFiles(downloads, tmp / "staging")
        monitor.send_queue = queue.Queue()
        monitor._event = lambda *args, **kwargs: None

        result = monitor.create_manual_email(
            account_email=account.email,
            recipient="cliente@example.com",
            subject="Novo assunto",
            body="Mensagem nova",
            attachment_files=["documento.txt"],
            requested_by="web",
        )

        row = monitor.store.get_message(result["outbound_id"])
        assert row["status"] == "pending-approval"
        assert int(row["approval_required"]) == 1
        assert row["reply_to_message_id"] == ""
        assert monitor.send_queue.empty()
        assert monitor.attachment_files.list(row["message_id"])[0]["name"] == "documento.txt"


def test_ses_new_mail_keeps_subject_and_adds_staged_attachment():
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        file_path = tmp / "relatorio.txt"
        file_path.write_text("anexo", encoding="utf-8")

        class FakeClient:
            def __init__(self):
                self.raw = b""

            def send_raw_email(self, **kwargs):
                self.raw = kwargs["RawMessage"]["Data"]
                return {"MessageId": "ses-123"}

        sender = SesSender.__new__(SesSender)
        sender.client = FakeClient()
        account = Account(email="suporte@example.com", password="x", display_name="Suporte")
        sender.send_stored_reply(
            account,
            {
                "recipient": "cliente@example.com",
                "subject": "Assunto novo",
                "reply_to_message_id": "",
                "references": "",
                "message_id": "<novo@example.com>",
                "body": "Corpo",
            },
            attachments=[{"path": file_path, "name": "relatorio.txt"}],
        )
        parsed = BytesParser(policy=policy.default).parsebytes(sender.client.raw)
        assert str(parsed["Subject"]) == "Assunto novo"
        assert [part.get_filename() for part in parsed.iter_attachments()] == ["relatorio.txt"]


def test_attachment_browser_rejects_path_escape():
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        downloads = tmp / "Downloads"
        downloads.mkdir()
        outside = tmp / "secret.txt"
        outside.write_text("secret", encoding="utf-8")
        files = AttachmentFiles(downloads, tmp / "staging")
        try:
            files.browse("../")
        except ValueError as exc:
            assert "fora da pasta Downloads" in str(exc)
        else:
            raise AssertionError("path traversal deveria ser bloqueado")


def test_staged_attachment_can_be_resolved_for_inline_preview():
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        downloads = tmp / "Downloads"
        downloads.mkdir()
        (downloads / "foto.png").write_bytes(b"png-data")
        files = AttachmentFiles(downloads, tmp / "staging")
        files.stage("<msg@example.com>", ["foto.png"])

        preview = files.preview("<msg@example.com>", 0)
        assert preview["name"] == "foto.png"
        assert preview["path"].is_file()

        try:
            files.preview("<msg@example.com>", 1)
        except FileNotFoundError:
            pass
        else:
            raise AssertionError("índice inexistente deveria retornar anexo não encontrado")
