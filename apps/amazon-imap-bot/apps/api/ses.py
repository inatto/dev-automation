from __future__ import annotations

import re
from email.message import EmailMessage
from email.utils import formataddr, formatdate, make_msgid, parseaddr

import boto3
from botocore.config import Config

from config import Account
from message import Incoming


def _safe_header(value: object) -> str:
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

    @staticmethod
    def new_message_id(account: Account) -> str:
        from_email = _safe_address(account.email)
        return str(make_msgid(domain=from_email.split("@")[-1]))

    def send_stored_reply(self, account: Account, row: dict) -> tuple[str, str]:
        from_email = _safe_address(account.email)
        to_email = _safe_address(row.get("recipient"))
        display_name = _safe_header(account.display_name)
        original_subject = _safe_header(row.get("subject")) or "(sem assunto)"
        subject = original_subject if original_subject.lower().startswith("re:") else f"Re: {original_subject}"
        in_reply_to = _safe_header(row.get("reply_to_message_id"))
        references = _safe_header(row.get("references"))
        if in_reply_to and in_reply_to not in references:
            references = _safe_header(f"{references} {in_reply_to}")
        message_id = _safe_header(row.get("message_id")) or self.new_message_id(account)

        msg = EmailMessage()
        msg["From"] = formataddr((display_name, from_email))
        msg["To"] = to_email
        msg["Subject"] = subject
        msg["Date"] = formatdate(localtime=False)
        msg["Message-ID"] = message_id
        if in_reply_to:
            msg["In-Reply-To"] = in_reply_to
        if references:
            msg["References"] = references
        msg.set_content(str(row.get("body") or ""))

        result = self.client.send_raw_email(
            Source=from_email,
            Destinations=[to_email],
            RawMessage={"Data": msg.as_bytes()},
        )
        return message_id, str(result.get("MessageId", ""))

    def send_reply(self, account: Account, incoming: Incoming, body: str) -> tuple[str, str]:
        message_id = self.new_message_id(account)
        row = {
            "recipient": incoming.sender_email,
            "subject": incoming.subject,
            "reply_to_message_id": incoming.message_id,
            "references": incoming.references,
            "message_id": message_id,
            "body": body,
        }
        return self.send_stored_reply(account, row)
