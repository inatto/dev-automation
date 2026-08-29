from __future__ import annotations

import uuid
from email.message import EmailMessage
from email.utils import formataddr, formatdate, make_msgid

import boto3
from botocore.config import Config

from config import Account
from message import Incoming


class SesSender:
    def __init__(self, profile: str, region: str):
        session = boto3.Session(profile_name=profile, region_name=region)
        self.client = session.client("ses", config=Config(retries={"max_attempts": 5, "mode": "standard"}))

    def send_reply(self, account: Account, incoming: Incoming, body: str) -> tuple[str, str]:
        msg = EmailMessage()
        msg["From"] = formataddr((account.display_name, account.email))
        msg["To"] = incoming.sender_email
        subject = incoming.subject.strip()
        msg["Subject"] = subject if subject.lower().startswith("re:") else f"Re: {subject}"
        msg["Date"] = formatdate(localtime=False)
        msg["Message-ID"] = make_msgid(domain=account.email.split("@")[-1])
        msg["In-Reply-To"] = incoming.message_id
        refs = (incoming.references + " " + incoming.message_id).strip()
        if refs:
            msg["References"] = refs
        msg.set_content(body)
        result = self.client.send_raw_email(
            Source=account.email,
            Destinations=[incoming.sender_email],
            RawMessage={"Data": msg.as_bytes()},
        )
        return str(msg["Message-ID"]), str(result.get("MessageId", ""))
