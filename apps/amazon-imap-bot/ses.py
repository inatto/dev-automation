from __future__ import annotations

import re
from email.message import EmailMessage
from email.utils import formataddr, formatdate, make_msgid, parseaddr

import boto3
from botocore.config import Config

from config import Account
from message import Incoming


def _safe_header(value: object) -> str:
    """Transforma dados externos em um único valor seguro de cabeçalho RFC 5322."""
    text = str(value or "")
    text = text.replace("\x00", "")
    return re.sub(r"[\r\n]+", " ", text).strip()


def _safe_address(value: object) -> str:
    cleaned = _safe_header(value)
    _, address = parseaddr(cleaned)
    if not address or not re.fullmatch(r"[^@\s<>]+@[^@\s<>]+", address):
        raise ValueError("endereço de e-mail inválido")
    return address


class SesSender:
    def __init__(self, profile: str, region: str):
        session = boto3.Session(profile_name=profile, region_name=region)
        self.client = session.client("ses", config=Config(retries={"max_attempts": 5, "mode": "standard"}))

    def send_reply(self, account: Account, incoming: Incoming, body: str) -> tuple[str, str]:
        from_email = _safe_address(account.email)
        to_email = _safe_address(incoming.sender_email)
        display_name = _safe_header(account.display_name)
        original_subject = _safe_header(incoming.subject) or "(sem assunto)"
        subject = original_subject if original_subject.lower().startswith("re:") else f"Re: {original_subject}"
        in_reply_to = _safe_header(incoming.message_id)
        references = _safe_header(f"{incoming.references} {incoming.message_id}")

        msg = EmailMessage()
        msg["From"] = formataddr((display_name, from_email))
        msg["To"] = to_email
        msg["Subject"] = subject
        msg["Date"] = formatdate(localtime=False)
        msg["Message-ID"] = make_msgid(domain=from_email.split("@")[-1])
        if in_reply_to:
            msg["In-Reply-To"] = in_reply_to
        if references:
            msg["References"] = references
        msg.set_content(body)

        result = self.client.send_raw_email(
            Source=from_email,
            Destinations=[to_email],
            RawMessage={"Data": msg.as_bytes()},
        )
        return str(msg["Message-ID"]), str(result.get("MessageId", ""))
