import tempfile
from pathlib import Path
from email import policy
from email.message import EmailMessage
from email.parser import BytesParser

from config import Account
from message import Incoming, parse, should_reply
from ses import SesSender
from store import Store


def test_parse_and_reply_rule():
    msg = EmailMessage()
    msg["From"] = "Cliente <cliente@example.com>"
    msg["To"] = "suporte@sindicatto.com"
    msg["Subject"] = "Ajuda"
    msg["Message-ID"] = "<abc@example.com>"
    msg.set_content("Preciso de ajuda com meu acesso.")
    item = parse(msg.as_bytes())
    assert item.sender_email == "cliente@example.com"
    assert item.subject == "Ajuda"
    assert should_reply(item, {"suporte@sindicatto.com"}) == (True, "ok")


def test_no_reply_is_ignored():
    msg = EmailMessage()
    msg["From"] = "no-reply@example.com"
    msg["To"] = "suporte@sindicatto.com"
    msg["Subject"] = "Automático"
    msg["Message-ID"] = "<auto@example.com>"
    msg.set_content("Mensagem automática")
    item = parse(msg.as_bytes())
    assert should_reply(item, {"suporte@sindicatto.com"})[0] is False


def test_empty_body_is_still_replyable():
    item = Incoming(
        message_id="<empty@example.com>", thread_key="<empty@example.com>",
        sender_name="Cliente", sender_email="cliente@example.com",
        recipient="suporte@example.com", subject="Teste", body="", references="",
        auto_submitted="", precedence="", list_id="",
    )
    assert should_reply(item, {"suporte@example.com"}) == (True, "ok")


def test_store_dedup_and_details():
    with tempfile.TemporaryDirectory() as tmp:
        store = Store(Path(tmp) / "db.sqlite3")
        store.add_inbound(
            account="a@b.com", message_id="<1>", thread_key="<1>",
            sender="x@y.com", recipient="a@b.com", subject="s", body="b", status="received",
            mail_date="2026-08-29 12:00:00", imap_uid="42", imap_folder="INBOX",
        )
        assert store.seen("a@b.com", "<1>")
        rows = store.list_messages("in")
        assert rows[0]["imap_uid"] == "42"
        assert store.get_message(rows[0]["id"])["body"] == "b"


def test_ses_sanitizes_untrusted_header_linebreaks():
    class FakeClient:
        def __init__(self):
            self.raw = b""

        def send_raw_email(self, **kwargs):
            self.raw = kwargs["RawMessage"]["Data"]
            return {"MessageId": "ses-123"}

    sender = SesSender.__new__(SesSender)
    sender.client = FakeClient()
    account = Account(
        email="suporte@example.com",
        password="x",
        display_name="Suporte\r\nInjetado: não",
    )
    incoming = Incoming(
        message_id="<abc@example.com>\r\nX-Bad: 1",
        thread_key="<abc@example.com>",
        sender_name="Cliente",
        sender_email="cliente@example.com",
        recipient="suporte@example.com",
        subject="Teste\r\nX-Bad: assunto",
        body="Oi",
        references="<root@example.com>\r\n <prev@example.com>",
        auto_submitted="",
        precedence="",
        list_id="",
    )
    sender.send_reply(account, incoming, "Recebido.")
    parsed = BytesParser(policy=policy.default).parsebytes(sender.client.raw)
    assert "\r" not in str(parsed["Subject"])
    assert "\n" not in str(parsed["Subject"])
    assert parsed["Bcc"] is None
    assert "X-Bad" not in parsed.keys()


def test_store_migrates_existing_database_and_records_outbound():
    import sqlite3
    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp) / "old.sqlite3"
        db = sqlite3.connect(path)
        db.execute("""
            CREATE TABLE messages (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              direction TEXT NOT NULL,
              account_email TEXT NOT NULL,
              message_id TEXT NOT NULL,
              thread_key TEXT,
              sender TEXT,
              recipient TEXT,
              subject TEXT,
              body TEXT,
              reply_to_message_id TEXT,
              provider_message_id TEXT,
              status TEXT NOT NULL,
              error TEXT,
              created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
              UNIQUE(direction, account_email, message_id)
            )
        """)
        db.commit()
        db.close()
        store = Store(path)
        store.add_outbound(
            account="suporte@example.com", message_id="<out@example.com>", thread_key="<in@example.com>",
            sender="suporte@example.com", recipient="cliente@example.com", subject="Teste", body="Recebido",
            reply_to="<in@example.com>", provider_message_id="ses-1", status="sent",
        )
        row = store.list_messages("out")[0]
        assert row["provider_message_id"] == "ses-1"
        assert "mail_date" in row
        assert "imap_uid" in row


def test_event_log_is_persistent():
    with tempfile.TemporaryDirectory() as tmp:
        store = Store(Path(tmp) / "db.sqlite3")
        store.add_event("GPT", "INFO", "REQUEST model=test")
        event = store.recent_events(1)[0]
        assert event["category"] == "GPT"
        assert "REQUEST" in event["text"]


def test_soft_delete_hides_message_but_preserves_dedup():
    with tempfile.TemporaryDirectory() as tmp:
        store = Store(Path(tmp) / "db.sqlite3")
        store.add_inbound(
            account="suporte@example.com", message_id="<delete-me>", thread_key="<delete-me>",
            sender="cliente@example.com", recipient="suporte@example.com", subject="Remover", body="Oi",
            status="replied", mail_date="2026-08-29 12:00:00", imap_uid="77", imap_folder="INBOX",
        )
        row = store.list_messages("in")[0]
        store.mark_deleted(row["id"], "move:Deleted Items")
        assert store.list_messages("in") == []
        assert store.seen("suporte@example.com", "<delete-me>") is True
        full = store.get_message(row["id"])
        assert full["deleted_at"]
        assert full["delete_mode"] == "move:Deleted Items"


def test_mailbox_detects_special_use_trash_folder():
    from types import SimpleNamespace
    from mailbox import MailboxClient

    class FakeConn:
        def list(self):
            return "OK", [
                b'(\\HasNoChildren) "/" "INBOX"',
                b'(\\HasNoChildren \\Trash) "/" "Deleted Items"',
            ]

    client = MailboxClient(SimpleNamespace(imap_trash_folder=""))
    assert client.trash_folder(FakeConn()) == "Deleted Items"


def test_api_run_stack_persists_status_and_timing():
    with tempfile.TemporaryDirectory() as tmp:
        store = Store(Path(tmp) / "db.sqlite3")
        run_id = store.add_api_run(
            kind="zip-test", status="aguardando-resposta", model="gpt-5.6",
            reasoning_effort="medium", input_path="/tmp/in.zip", output_path="",
            request_summary="teste",
        )
        store.update_api_run(
            run_id, status="concluido", output_path="/tmp/out.zip",
            response_id="resp_123", response_summary="ok", elapsed_ms=1234, finished=True,
        )
        row = store.get_api_run(run_id)
        assert row["status"] == "concluido"
        assert row["elapsed_ms"] == 1234
        assert row["response_id"] == "resp_123"
        assert row["finished_at"]


def test_api_runner_extracts_container_zip_citation():
    from api_runner import ApiTestRunner

    response = {
        "output": [{
            "type": "message",
            "content": [{
                "type": "output_text",
                "annotations": [{
                    "type": "container_file_citation",
                    "container_id": "cntr_1",
                    "file_id": "cfile_1",
                    "filename": "return.zip",
                }],
            }],
        }],
    }
    assert ApiTestRunner._container_files(response) == [{
        "container_id": "cntr_1", "file_id": "cfile_1", "filename": "return.zip"
    }]


def test_function_map_authorizes_sender_and_maps_reasoning_level():
    import json
    from function_map import FunctionMap

    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp) / "functions.json"
        path.write_text(json.dumps({
            "version": 1,
            "senders": {
                "danielmaiax@gmail.com": {
                    "enabled": True,
                    "functions": ["api_zip_test"],
                }
            },
            "functions": {
                "api_zip_test": {
                    "enabled": True,
                    "aliases": ["mande o arquivo teste"],
                    "default_reasoning_level": 2,
                    "allowed_reasoning_levels": [0, 1, 2, 3, 4, 5],
                }
            },
        }), encoding="utf-8")
        mapping = FunctionMap(path)
        request = mapping.resolve(
            "DanielMaiaX@gmail.com",
            "Teste API",
            "Mande o arquivo teste usando o nível 1 e peça como retorno qual é a capital da África do Sul",
        )
        assert request is not None
        assert request.name == "api_zip_test"
        assert request.reasoning_level == 1
        assert request.reasoning_effort == "low"
        assert request.request_text == "qual é a capital da África do Sul"


def test_function_map_rejects_unauthorized_sender():
    import json
    from function_map import FunctionMap

    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp) / "functions.json"
        path.write_text(json.dumps({
            "senders": {"danielmaiax@gmail.com": {"functions": ["api_zip_test"]}},
            "functions": {
                "api_zip_test": {
                    "aliases": ["mande o arquivo teste"],
                    "allowed_reasoning_levels": [0, 1, 2, 3, 4, 5],
                }
            },
        }), encoding="utf-8")
        mapping = FunctionMap(path)
        assert mapping.resolve(
            "outra-pessoa@example.com", "", "mande o arquivo teste usando nível 1"
        ) is None
        assert mapping.is_command_but_unauthorized(
            "outra-pessoa@example.com", "", "mande o arquivo teste usando nível 1"
        ) == "api_zip_test"


def test_function_map_all_reasoning_levels_and_invalid_level():
    import json
    import pytest
    from function_map import FunctionMap, REASONING_LEVELS

    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp) / "functions.json"
        path.write_text(json.dumps({
            "senders": {"a@example.com": {"functions": ["api_zip_test"]}},
            "functions": {
                "api_zip_test": {
                    "aliases": ["mande o arquivo teste"],
                    "allowed_reasoning_levels": [0, 1, 2, 3, 4, 5],
                }
            },
        }), encoding="utf-8")
        mapping = FunctionMap(path)
        for level, effort in REASONING_LEVELS.items():
            request = mapping.resolve("a@example.com", "", f"mande o arquivo teste nível {level}")
            assert request is not None
            assert request.reasoning_effort == effort
        with pytest.raises(ValueError, match="entre 0 e 5"):
            mapping.resolve("a@example.com", "", "mande o arquivo teste nível 9")


def test_api_runner_validates_reasoning_effort():
    import pytest
    from api_runner import ApiTestRunner

    assert ApiTestRunner.normalize_reasoning_effort("LOW") == "low"
    assert ApiTestRunner.normalize_reasoning_effort("xhigh") == "xhigh"
    with pytest.raises(ValueError):
        ApiTestRunner.normalize_reasoning_effort("impossivel")
