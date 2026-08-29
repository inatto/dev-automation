from __future__ import annotations

import email
import hashlib
import re
from dataclasses import dataclass
from email.header import decode_header, make_header
from email.message import Message
from email.utils import parseaddr


@dataclass(frozen=True)
class Incoming:
    message_id: str
    thread_key: str
    sender_name: str
    sender_email: str
    recipient: str
    subject: str
    body: str
    references: str
    auto_submitted: str
    precedence: str
    list_id: str


def _header(msg: Message, name: str) -> str:
    raw = str(msg.get(name, "") or "")
    try:
        return str(make_header(decode_header(raw))).strip()
    except Exception:
        return raw.strip()


def _plain_body(msg: Message) -> str:
    candidates: list[str] = []
    if msg.is_multipart():
        for part in msg.walk():
            content_type = part.get_content_type()
            disposition = str(part.get("Content-Disposition", "")).lower()
            if content_type != "text/plain" or "attachment" in disposition:
                continue
            try:
                candidates.append(part.get_content())
            except Exception:
                payload = part.get_payload(decode=True) or b""
                candidates.append(payload.decode(part.get_content_charset() or "utf-8", errors="replace"))
    else:
        try:
            candidates.append(msg.get_content())
        except Exception:
            payload = msg.get_payload(decode=True) or b""
            candidates.append(payload.decode(msg.get_content_charset() or "utf-8", errors="replace"))
    body = "\n".join(x.strip() for x in candidates if x.strip())
    # Remove quoted reply sections enough to avoid feeding huge threads to the first version.
    body = re.split(r"\nOn .+wrote:\s*\n|\nEm .+escreveu:\s*\n", body, maxsplit=1)[0]
    return body.strip()[:12000]


def parse(raw: bytes) -> Incoming:
    msg = email.message_from_bytes(raw)
    sender_name, sender_email = parseaddr(_header(msg, "From"))
    recipient = parseaddr(_header(msg, "To"))[1] or _header(msg, "To")
    subject = _header(msg, "Subject")
    message_id = _header(msg, "Message-ID")
    if not message_id:
        message_id = "<sha256-" + hashlib.sha256(raw).hexdigest() + ">"
    refs = _header(msg, "References")
    thread_seed = refs.split()[0] if refs else message_id
    return Incoming(
        message_id=message_id,
        thread_key=thread_seed,
        sender_name=sender_name,
        sender_email=sender_email.strip().lower(),
        recipient=recipient,
        subject=subject,
        body=_plain_body(msg),
        references=refs,
        auto_submitted=_header(msg, "Auto-Submitted").lower(),
        precedence=_header(msg, "Precedence").lower(),
        list_id=_header(msg, "List-Id"),
    )


def should_reply(item: Incoming, own_addresses: set[str]) -> tuple[bool, str]:
    sender = item.sender_email.lower()
    if not sender or sender in own_addresses:
        return False, "remetente próprio/vazio"
    if item.auto_submitted and item.auto_submitted != "no":
        return False, "mensagem automática"
    if item.precedence in {"bulk", "list", "junk"} or item.list_id:
        return False, "lista/bulk"
    local = sender.split("@", 1)[0] if "@" in sender else sender
    blocked = ("no-reply", "noreply", "mailer-daemon", "postmaster")
    if any(token in local for token in blocked):
        return False, "no-reply/bounce"
    if not item.body.strip():
        return False, "sem corpo textual"
    return True, "ok"
