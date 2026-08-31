import tempfile
from pathlib import Path
from email import policy
from email.message import EmailMessage
from email.parser import BytesParser

from config import Account
from message import Incoming, IncomingAttachment, parse, should_reply
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



def test_parse_collects_email_attachments():
    msg = EmailMessage()
    msg["From"] = "Cliente <cliente@example.com>"
    msg["To"] = "suporte@sindicatto.com"
    msg["Subject"] = "Planilha"
    msg["Message-ID"] = "<attach@example.com>"
    msg.set_content("Verifique a planilha anexa no projeto.")
    msg.add_attachment(
        b"fake-xlsx",
        maintype="application",
        subtype="vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        filename="dados.xlsx",
    )
    item = parse(msg.as_bytes())
    assert len(item.attachments) == 1
    assert item.attachments[0].filename == "dados.xlsx"
    assert item.attachments[0].data == b"fake-xlsx"
    assert item.attachments[0].size == 9


def test_ses_reply_can_attach_generated_file():
    class FakeClient:
        def __init__(self):
            self.raw = b""

        def send_raw_email(self, **kwargs):
            self.raw = kwargs["RawMessage"]["Data"]
            return {"MessageId": "ses-attachment"}

    sender = SesSender.__new__(SesSender)
    sender.client = FakeClient()
    account = Account(email="suporte@example.com", password="x", display_name="Suporte")
    incoming = Incoming(
        message_id="<in@example.com>", thread_key="<in@example.com>", sender_name="Cliente",
        sender_email="cliente@example.com", recipient="suporte@example.com", subject="Imagem", body="",
        references="", auto_submitted="", precedence="", list_id="",
    )
    with tempfile.TemporaryDirectory() as tmp:
        image = Path(tmp) / "resultado.png"
        image.write_bytes(b"PNGDATA")
        sender.send_reply(account, incoming, "Segue o arquivo.", attachment_paths=[image])
    parsed = BytesParser(policy=policy.default).parsebytes(sender.client.raw)
    attachments = list(parsed.iter_attachments())
    assert len(attachments) == 1
    assert attachments[0].get_filename() == "resultado.png"
    assert attachments[0].get_payload(decode=True) == b"PNGDATA"

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


def test_project_zip_function_is_configured_for_daniel():
    import json
    from pathlib import Path

    config_path = Path(__file__).resolve().parents[3] / ".config" / "amazon-imap-bot" / "functions.json"
    payload = json.loads(config_path.read_text(encoding="utf-8"))
    assert "project_zip_edit" in payload["functions"]
    assert "project_zip_edit" in payload["senders"]["danielmaiax@gmail.com"]["functions"]
    entry = payload["functions"]["project_zip_edit"]
    assert entry["default_reasoning_level"] == 2
    assert entry["allowed_reasoning_levels"] == [0, 1, 2, 3, 4, 5]


def test_function_map_accepts_project_zip_edit_and_level():
    import json
    from function_map import FunctionMap

    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp) / "functions.json"
        path.write_text(json.dumps({
            "senders": {
                "danielmaiax@gmail.com": {
                    "enabled": True,
                    "functions": ["project_zip_edit"],
                }
            },
            "functions": {
                "project_zip_edit": {
                    "enabled": True,
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
        mapping = FunctionMap(path)
        req = mapping.request_from_tool_call(
            "danielmaiax@gmail.com",
            "project_zip_edit",
            {"reasoning_level": 3, "request_text": "Altere o título do Orbital App."},
        )
        assert req.name == "project_zip_edit"
        assert req.reasoning_level == 3
        assert req.reasoning_effort == "high"
        assert "Orbital App" in req.request_text


def test_project_zip_runner_two_independent_calls_select_edit_and_download():
    import json
    import zipfile
    from types import SimpleNamespace
    from project_zip_runner import ProjectZipRunner

    class FakeFiles:
        def __init__(self):
            self.uploaded_name = None
            self.create_calls = 0

        def create(self, *, file, purpose):
            self.create_calls += 1
            self.uploaded_name = Path(file.name).name
            assert purpose == "user_data"
            return SimpleNamespace(id="file_project_zip")

    class FakeResponses:
        def __init__(self):
            self.calls = []

        def create(self, **kwargs):
            self.calls.append(kwargs)
            if kwargs["tools"][0]["type"] == "function":
                return SimpleNamespace(
                    id="resp_select",
                    output=[SimpleNamespace(
                        type="function_call",
                        name="select_project_zip",
                        arguments=json.dumps({
                            "selected_zip": "orbital-app.zip",
                            "reason": "O pedido menciona explicitamente Orbital App.",
                        }),
                    )],
                )
            return SimpleNamespace(
                id="resp_edit",
                output_text="Título alterado conforme solicitado.",
                output=[SimpleNamespace(
                    type="message",
                    content=[SimpleNamespace(
                        type="output_text",
                        annotations=[SimpleNamespace(
                            type="container_file_citation",
                            container_id="cntr_project",
                            file_id="cfile_project",
                            filename="orbital-app-return.zip",
                        )],
                    )],
                )],
            )

    class FakeClient:
        def __init__(self):
            self.files = FakeFiles()
            self.responses = FakeResponses()

    class TestRunner(ProjectZipRunner):
        def _download_container_file(self, container_id, file_id, target):
            assert container_id == "cntr_project"
            assert file_id == "cfile_project"
            target.parent.mkdir(parents=True, exist_ok=True)
            with zipfile.ZipFile(target, "w", compression=zipfile.ZIP_DEFLATED) as zf:
                info = zipfile.ZipInfo("apps/orbital-app/index.html", (2026, 8, 31, 1, 2, 2))
                info.external_attr = 0o600 << 16
                zf.writestr(info, "<title>Orbital App - mágica aconteceu</title>")

    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp) / "Code"
        output = Path(tmp) / "Downloads"
        project_zip = root / "orbital-app.zip"
        root.mkdir(parents=True)
        with zipfile.ZipFile(project_zip, "w", compression=zipfile.ZIP_DEFLATED) as zf:
            info = zipfile.ZipInfo("apps/orbital-app/index.html", (2025, 1, 2, 3, 4, 4))
            info.external_attr = 0o755 << 16
            zf.writestr(info, "<title>Orbital App</title>")

        nested = root / "orgs" / "ignored.zip"
        nested.parent.mkdir(parents=True)
        with zipfile.ZipFile(nested, "w", compression=zipfile.ZIP_DEFLATED) as zf:
            zf.writestr("ignored.txt", "ignored")

        settings = SimpleNamespace(
            project_zip_search_root=root,
            openai_model="gpt-5.6",
            openai_api_key="test",
            openai_base_url="https://api.openai.com/v1",
            openai_timeout_seconds=30,
            openai_output_dir=output,
        )
        store = Store(Path(tmp) / "db.sqlite3")
        client = FakeClient()
        runner = TestRunner(settings, store, client=client)
        request = "Assunto: teste\n\nAltere apenas o título da página inicial do Orbital App para - mágica aconteceu."
        final_run_id = runner.run_project_edit(
            request_text=request,
            reasoning_effort="high",
            source="email:danielmaiax@gmail.com",
        )

        assert len(client.responses.calls) == 2
        select_call, edit_call = client.responses.calls
        assert "previous_response_id" not in select_call
        assert "previous_response_id" not in edit_call
        assert select_call["reasoning"]["effort"] == "low"
        assert edit_call["reasoning"]["effort"] == "high"
        assert "orbital-app.zip" in select_call["input"]
        assert "orgs/ignored.zip" not in select_call["input"]
        assert "bytes=" not in select_call["input"]
        assert "nenhum arquivo ZIP foi anexado" in select_call["input"]
        assert request in select_call["input"]
        assert request in edit_call["input"]
        assert "NÃO extraia/descompacte o projeto inteiro" in edit_call["input"]
        assert "Use Python zipfile" in edit_call["input"]
        assert edit_call["tools"][0]["type"] == "code_interpreter"
        assert edit_call["tools"][0]["container"]["file_ids"] == ["file_project_zip"]
        assert client.files.uploaded_name == "orbital-app.zip"
        assert client.files.create_calls == 1  # somente a chamada PROJETO faz upload; ESCOLHE é texto puro

        final_row = store.get_api_run(final_run_id)
        assert final_row["kind"] == "project-zip-edit"
        assert final_row["status"] == "concluido"
        final_zip = Path(final_row["output_path"])
        assert final_zip.parent == output
        assert zipfile.is_zipfile(final_zip)
        with zipfile.ZipFile(final_zip) as zf:
            assert zf.read("apps/orbital-app/index.html").decode() == "<title>Orbital App - mágica aconteceu</title>"
            info = zf.getinfo("apps/orbital-app/index.html")
            assert info.date_time == (2025, 1, 2, 3, 4, 4)
            assert (info.external_attr >> 16) & 0o777 == 0o755

        runs = store.list_api_runs(10)
        kinds = [row["kind"] for row in runs]
        assert "project-zip-select" in kinds
        assert "project-zip-edit" in kinds
        select_row = next(row for row in runs if row["kind"] == "project-zip-select")
        assert select_row["status"] == "concluido"
        assert select_row["output_path"] == str(project_zip.resolve())
        assert select_row["input_file_count"] == 0
        assert select_row["input_file_bytes"] == 0
        assert select_row["listed_item_count"] == 1
        assert select_row["request_bytes"] == len(select_row["request_payload"].encode("utf-8"))
        assert "1. orbital-app.zip" in select_row["request_payload"]
        assert "orgs/ignored.zip" not in select_row["request_payload"]

        edit_row = next(row for row in runs if row["kind"] == "project-zip-edit")
        assert edit_row["input_file_count"] == 1
        assert edit_row["input_file_bytes"] == project_zip.stat().st_size
        assert edit_row["output_file_count"] == 1
        assert edit_row["output_file_bytes"] == Path(edit_row["output_path"]).stat().st_size
        assert edit_row["request_bytes"] == len(edit_row["request_payload"].encode("utf-8"))


def test_project_zip_function_accepts_query_operation():
    import json
    from function_map import FunctionMap

    config_path = Path(__file__).resolve().parents[3] / ".config" / "amazon-imap-bot" / "functions.json"
    mapping = FunctionMap(config_path)
    request = mapping.request_from_tool_call(
        "danielmaiax@gmail.com",
        "project_zip_edit",
        json.dumps({
            "reasoning_level": 2,
            "request_text": "Resuma as funções do módulo Orbital Legal.",
            "operation": "query",
        }),
    )
    assert request.name == "project_zip_edit"
    assert request.arguments["operation"] == "query"
    tool = next(t for t in mapping.openai_tools_for_sender("danielmaiax@gmail.com") if t["name"] == "project_zip_edit")
    assert "explicar" in tool["description"].lower()
    assert "operation" in tool["parameters"]["required"]


def test_project_zip_query_completes_without_return_zip():
    from types import SimpleNamespace
    import zipfile
    from project_zip_runner import ProjectZipRunner

    class FakeFiles:
        def create(self, **kwargs):
            return SimpleNamespace(id="file_project_1")

    class FakeResponses:
        def create(self, **kwargs):
            return SimpleNamespace(
                id="resp_query_1",
                output_text="O módulo possui telas de processos, partes e andamentos.",
                output=[],
            )

    class FakeClient:
        def __init__(self):
            self.files = FakeFiles()
            self.responses = FakeResponses()

    with tempfile.TemporaryDirectory() as tmp:
        tmp_path = Path(tmp)
        source = tmp_path / "orbital-legal.zip"
        with zipfile.ZipFile(source, "w") as zf:
            zf.writestr("README.md", "Módulo jurídico")
        settings = SimpleNamespace(
            project_zip_search_root=tmp_path,
            openai_model="gpt-5.6",
            openai_api_key="test",
            openai_base_url="https://api.openai.com/v1",
            openai_timeout_seconds=300,
            openai_output_dir=tmp_path / "downloads",
        )
        store = Store(tmp_path / "db.sqlite3")
        runner = ProjectZipRunner(settings, store, client=FakeClient())
        run_id = runner.process_project_zip(
            source,
            "Resuma as funções do módulo.",
            "medium",
            "query",
            "email:danielmaiax@gmail.com",
        )
        row = store.get_api_run(run_id)
        assert row["status"] == "concluido"
        assert row["output_path"] == ""
        assert "processos" in row["response_summary"]


def test_project_zip_query_uploads_email_attachments_and_downloads_generated_nonzip():
    import json
    import zipfile
    from types import SimpleNamespace
    from project_zip_runner import ProjectZipRunner

    class FakeFiles:
        def __init__(self):
            self.names = []

        def create(self, *, file, purpose):
            assert purpose == "user_data"
            self.names.append(Path(file.name).name)
            return SimpleNamespace(id=f"file_{len(self.names)}")

    class FakeResponses:
        def __init__(self):
            self.calls = []

        def create(self, **kwargs):
            self.calls.append(kwargs)
            if kwargs["tools"][0]["type"] == "function":
                return SimpleNamespace(
                    id="resp_select_attach",
                    output=[SimpleNamespace(
                        type="function_call", name="select_project_zip",
                        arguments=json.dumps({"selected_zip": "orbital-app.zip", "reason": "pedido menciona projeto"}),
                    )],
                )
            return SimpleNamespace(
                id="resp_query_attach",
                output_text="A planilha é compatível com o importador. Segue imagem de validação.",
                output=[SimpleNamespace(
                    type="message",
                    content=[SimpleNamespace(
                        type="output_text",
                        annotations=[SimpleNamespace(
                            type="container_file_citation",
                            container_id="cntr_attach",
                            file_id="cfile_png",
                            filename="validacao.png",
                        )],
                    )],
                )],
            )

    class FakeClient:
        def __init__(self):
            self.files = FakeFiles()
            self.responses = FakeResponses()

    class TestRunner(ProjectZipRunner):
        def _download_container_file(self, container_id, file_id, target):
            assert container_id == "cntr_attach"
            assert file_id == "cfile_png"
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(b"PNGRESULT")

    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp) / "Code"
        out = Path(tmp) / "Downloads"
        root.mkdir()
        source = root / "orbital-app.zip"
        with zipfile.ZipFile(source, "w") as zf:
            zf.writestr("README.md", "Orbital App")
        settings = SimpleNamespace(
            project_zip_search_root=root, openai_model="gpt-5.6", openai_api_key="test",
            openai_base_url="https://api.openai.com/v1", openai_timeout_seconds=300, openai_output_dir=out,
        )
        store = Store(Path(tmp) / "db.sqlite3")
        client = FakeClient()
        runner = TestRunner(settings, store, client=client)
        attachment = IncomingAttachment(
            filename="dados.xlsx",
            content_type="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
            data=b"EXCELDATA",
        )
        run_id = runner.run_project_request(
            request_text="Verifique se a planilha está sendo importada corretamente no Orbital App e gere uma imagem de validação.",
            reasoning_effort="medium", operation="query", source="email:danielmaiax@gmail.com",
            attachments=(attachment,),
        )
        assert len(client.responses.calls) == 2
        select_call, project_call = client.responses.calls
        assert "dados.xlsx" in select_call["input"]
        assert "nenhum binário nesta chamada" in select_call["input"]
        assert client.files.names[0] == "orbital-app.zip"
        assert client.files.names[1].endswith("dados.xlsx")
        assert project_call["tools"][0]["container"]["file_ids"] == ["file_1", "file_2"]
        assert "ANEXOS RECEBIDOS NO E-MAIL: 1 arquivo(s), 9 bytes" in project_call["input"]
        outputs = runner.output_files_for_run(run_id)
        assert len(outputs) == 1
        assert outputs[0].name == "validacao.png"
        assert outputs[0].read_bytes() == b"PNGRESULT"
        row = store.get_api_run(run_id)
        assert row["kind"] == "project-zip-query"
        assert row["status"] == "concluido"
        assert row["output_path"] == str(outputs[0])
        assert row["output_file_count"] == 1
        assert "validacao.png" in row["response_summary"]


def test_api_run_records_final_email_notification_state():
    with tempfile.TemporaryDirectory() as tmp:
        store = Store(Path(tmp) / "db.sqlite3")
        run_id = store.add_api_run(
            kind="project-zip-edit", status="concluido", model="gpt-5.6",
            reasoning_effort="medium", input_path="/tmp/in.zip", output_path="/tmp/out.zip",
            request_summary="teste",
        )
        store.update_api_run(run_id, notification_status="enviado", notification_error="")
        row = store.get_api_run(run_id)
        assert row["notification_status"] == "enviado"
        assert row["notification_error"] == ""


def test_function_receipt_is_sent_before_processing_without_function_details():
    from monitor import Monitor

    class FakeStore:
        def __init__(self):
            self.outbound = []
        def add_event(self, *args, **kwargs):
            pass
        def add_outbound(self, **kwargs):
            self.outbound.append(kwargs)

    class FakeSes:
        def __init__(self):
            self.bodies = []
        def send_reply(self, account, item, body, attachment_paths=()):
            self.bodies.append(body)
            return "<ack@example.com>", "ses-ack"

    monitor = Monitor.__new__(Monitor)
    monitor.store = FakeStore()
    monitor.ses = FakeSes()
    monitor.on_event = lambda text: None
    account = Account(email="suporte@sindicatto.com", password="x", display_name="Suporte")
    item = Incoming(
        message_id="<in@example.com>", thread_key="<in@example.com>", sender_name="Daniel",
        sender_email="danielmaiax@gmail.com", recipient="suporte@sindicatto.com",
        subject="Alterar projeto", body="Faça a alteração", references="",
        auto_submitted="", precedence="", list_id="",
    )
    assert monitor._send_function_receipt(account, item) is True
    assert len(monitor.ses.bodies) == 1
    body = monitor.ses.bodies[0]
    assert "solicitação está sendo processada" in body
    assert "project_zip_edit" not in body
    assert len(monitor.store.outbound) == 1
    assert monitor.store.outbound[0]["status"] == "sent"


def test_completed_function_sends_final_email_and_marks_api_notification():
    from monitor import Monitor, AccountState
    from function_map import FunctionRequest

    class FakeStore:
        def __init__(self):
            self.statuses = []
            self.outbound = []
            self.api_updates = []
        def add_event(self, *args, **kwargs):
            pass
        def set_inbound_status(self, account, message_id, status):
            self.statuses.append(status)
        def get_api_run(self, run_id):
            return {"output_path": "/home/daniel/Downloads/orbital-app.zip", "response_summary": "Alteração concluída."}
        def update_api_run(self, run_id, **kwargs):
            self.api_updates.append((run_id, kwargs))
        def add_outbound(self, **kwargs):
            self.outbound.append(kwargs)

    class FakeProjectRunner:
        def run_project_request(self, **kwargs):
            return 42
        def output_files_for_run(self, run_id):
            return []

    class FakeSes:
        def __init__(self):
            self.bodies = []
        def send_reply(self, account, item, body, attachment_paths=()):
            self.bodies.append(body)
            return "<final@example.com>", "ses-final"

    monitor = Monitor.__new__(Monitor)
    monitor.store = FakeStore()
    monitor.ses = FakeSes()
    monitor.project_zip_runner = FakeProjectRunner()
    monitor.api_runner = None
    monitor.on_event = lambda text: None
    account = Account(email="suporte@sindicatto.com", password="x", display_name="Suporte")
    item = Incoming(
        message_id="<in2@example.com>", thread_key="<in2@example.com>", sender_name="Daniel",
        sender_email="danielmaiax@gmail.com", recipient="suporte@sindicatto.com",
        subject="Alterar Orbital", body="Troque o título", references="",
        auto_submitted="", precedence="", list_id="",
    )
    request = FunctionRequest(
        name="project_zip_edit", sender="danielmaiax@gmail.com", reasoning_level=2,
        reasoning_effort="medium", request_text="Troque o título",
        arguments={"operation": "modify", "reasoning_level": 2, "request_text": "Troque o título"},
    )
    state = AccountState(account.email)
    monitor._execute_function_request(account, item, request, state)
    assert monitor.store.statuses[-1] == "replied"
    assert state.replied == 1
    assert len(monitor.ses.bodies) == 1
    assert "Solicitação concluída com sucesso" in monitor.ses.bodies[0]
    assert any(update.get("notification_status") == "enviado" for _, update in monitor.store.api_updates)
    assert monitor.store.outbound[-1]["provider_message_id"] == "ses-final"
