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


def _write_function_config(path: Path):
    import json
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
                "description": "Executa semanticamente o teste ZIP da API.",
                "allowed_reasoning_levels": [0, 1, 2, 3, 4, 5],
                "parameters": {
                    "type": "object",
                    "properties": {
                        "reasoning_level": {"type": "integer", "enum": [0, 1, 2, 3, 4, 5]},
                        "request_text": {"type": "string"},
                    },
                    "required": ["reasoning_level", "request_text"],
                    "additionalProperties": False,
                },
            }
        },
    }), encoding="utf-8")


def test_function_map_exposes_only_sender_authorized_tools():
    from function_map import FunctionMap

    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp) / "functions.json"
        _write_function_config(path)
        mapping = FunctionMap(path)
        tools = mapping.openai_tools_for_sender("DanielMaiaX@gmail.com")
        assert len(tools) == 1
        assert tools[0]["name"] == "api_zip_test"
        assert tools[0]["strict"] is True
        assert tools[0]["parameters"]["additionalProperties"] is False
        assert mapping.openai_tools_for_sender("outra-pessoa@example.com") == []


def test_function_router_uses_gpt_tool_call_not_phrase_matching():
    from types import SimpleNamespace
    from function_map import FunctionMap
    from function_router import FunctionRouter

    class FakeResponses:
        def __init__(self):
            self.kwargs = None

        def create(self, **kwargs):
            self.kwargs = kwargs
            return SimpleNamespace(
                id="resp_router_1",
                output=[SimpleNamespace(
                    type="function_call",
                    name="api_zip_test",
                    arguments='{"reasoning_level":1,"request_text":"qual é a capital da África do Sul"}',
                )],
            )

    class FakeClient:
        def __init__(self):
            self.responses = FakeResponses()

    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp) / "functions.json"
        _write_function_config(path)
        mapping = FunctionMap(path)
        client = FakeClient()
        router = FunctionRouter("", "gpt-5.6", "https://api.openai.com/v1", 30, mapping, client=client)
        result = router.route(
            "danielmaiax@gmail.com",
            "Uma solicitação qualquer",
            "Faça aquele processamento do arquivo de teste no primeiro nível e descubra a capital da África do Sul.",
        )
        assert result.request is not None
        assert result.request.name == "api_zip_test"
        assert result.request.reasoning_level == 1
        assert result.request.reasoning_effort == "low"
        assert result.request.request_text == "qual é a capital da África do Sul"
        assert result.response_id == "resp_router_1"
        assert client.responses.kwargs["tool_choice"] == "auto"
        assert client.responses.kwargs["parallel_tool_calls"] is False
        assert client.responses.kwargs["tools"][0]["name"] == "api_zip_test"


def test_function_router_does_not_call_api_when_sender_has_no_functions():
    from function_map import FunctionMap
    from function_router import FunctionRouter

    class NeverResponses:
        def create(self, **kwargs):
            raise AssertionError("API não deveria ser chamada para remetente sem funções")

    class FakeClient:
        responses = NeverResponses()

    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp) / "functions.json"
        _write_function_config(path)
        mapping = FunctionMap(path)
        router = FunctionRouter("", "gpt-5.6", "https://api.openai.com/v1", 30, mapping, client=FakeClient())
        result = router.route("outra-pessoa@example.com", "teste", "faça o ZIP")
        assert result.request is None
        assert result.response_id == ""


def test_function_map_validates_all_reasoning_levels_and_rejects_invalid():
    import pytest
    from function_map import FunctionMap, REASONING_LEVELS

    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp) / "functions.json"
        _write_function_config(path)
        mapping = FunctionMap(path)
        for level, effort in REASONING_LEVELS.items():
            request = mapping.request_from_tool_call(
                "danielmaiax@gmail.com",
                "api_zip_test",
                {"reasoning_level": level, "request_text": "teste"},
            )
            assert request.reasoning_effort == effort
        with pytest.raises(ValueError, match="entre 0 e 5"):
            mapping.request_from_tool_call(
                "danielmaiax@gmail.com",
                "api_zip_test",
                {"reasoning_level": 9, "request_text": "teste"},
            )
        with pytest.raises(PermissionError):
            mapping.request_from_tool_call(
                "outra-pessoa@example.com",
                "api_zip_test",
                {"reasoning_level": 1, "request_text": "teste"},
            )


def test_api_runner_validates_reasoning_effort():
    import pytest
    from api_runner import ApiTestRunner

    assert ApiTestRunner.normalize_reasoning_effort("LOW") == "low"
    assert ApiTestRunner.normalize_reasoning_effort("xhigh") == "xhigh"
    with pytest.raises(ValueError):
        ApiTestRunner.normalize_reasoning_effort("impossivel")


def test_tui_menu_reserves_function_keys_and_has_functions_area():
    from tui import TAB_NAMES

    assert TAB_NAMES == ("ENTRADA", "RESPOSTAS", "CONSOLE", "CONTAS", "API", "FUNÇÕES")
    assert all(not (len(name) > 1 and name[0] == "F" and name[1].isdigit()) for name in TAB_NAMES)


def test_functions_view_reads_real_json_as_human_interface():
    import json
    from tui import _function_view_lines

    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp) / "functions.json"
        path.write_text(json.dumps({
            "version": 7,
            "reasoning_levels": {"0": "none", "1": "low", "2": "medium"},
            "senders": {
                "danielmaiax@gmail.com": {
                    "enabled": True,
                    "functions": ["api_zip_test"],
                }
            },
            "functions": {
                "api_zip_test": {
                    "enabled": True,
                    "description": "Executa o teste ZIP.",
                    "default_reasoning_level": 2,
                    "allowed_reasoning_levels": [0, 1, 2],
                    "parameters": {
                        "type": "object",
                        "properties": {
                            "reasoning_level": {"type": "integer", "enum": [0, 1, 2]},
                            "request_text": {"type": "string", "description": "Pedido do remetente."},
                        },
                        "required": ["reasoning_level", "request_text"],
                        "additionalProperties": False,
                    },
                }
            },
        }), encoding="utf-8")

        lines = _function_view_lines(path, 100)
        text = "\n".join(lines)
        assert "Versão: 7" in text
        assert "FUNÇÃO: api_zip_test" in text
        assert "[ATIVA]" in text
        assert "Nível padrão: 2 (medium)" in text
        assert "reasoning_level" in text
        assert "OBRIGATÓRIO" in text
        assert "REMETENTE: danielmaiax@gmail.com" in text
        assert "[PERMITIDA]" in text
        assert '"functions"' not in text
