import tempfile
from pathlib import Path
from email.message import EmailMessage

from message import parse, should_reply
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


def test_store_dedup():
    with tempfile.TemporaryDirectory() as tmp:
        store = Store(Path(tmp) / "db.sqlite3")
        store.add_inbound(account="a@b.com", message_id="<1>", thread_key="<1>",
                          sender="x@y.com", recipient="a@b.com", subject="s", body="b", status="received")
        assert store.seen("a@b.com", "<1>")
