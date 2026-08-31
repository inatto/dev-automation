from __future__ import annotations

import email
import hashlib
import re
from dataclasses import dataclass
from pathlib import Path
from email.header import decode_header, make_header
from email.message import Message
from email.utils import parseaddr, parsedate_to_datetime


@dataclass(frozen=True)
class IncomingAttachment:
    filename: str
    content_type: str
    data: bytes

    @property
    def size(self) -> int:
        return len(self.data)


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
    mail_date: str = ""
    attachments: tuple[IncomingAttachment, ...] = ()


def _single_line(value: str) -> str:
    return re.sub(r"[\r\n]+", " ", value.replace("\x00", "")).strip()


def _header(msg: Message, name: str) -> str:
    raw = str(msg.get(name, "") or "")
    try:
        return _single_line(str(make_header(decode_header(raw))))
    except Exception:
        return _single_line(raw)


def _mail_date(msg: Message) -> str:
    raw = str(msg.get("Date", "") or "").strip()
    if not raw:
        return ""
    try:
        parsed = parsedate_to_datetime(raw)
        if parsed is None:
            return ""
        if parsed.tzinfo is not None:
            parsed = parsed.astimezone()
        return parsed.strftime("%Y-%m-%d %H:%M:%S")
    except Exception:
        return ""


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
    # Remove trechos citados para não enviar threads enormes à IA.
    body = re.split(r"\nOn .+wrote:\s*\n|\nEm .+escreveu:\s*\n", body, maxsplit=1)[0]
    return body.strip()[:12000]



def _safe_attachment_filename(value: str, index: int, content_type: str) -> str:
    raw = _single_line(value or "")
    try:
        decoded = str(make_header(decode_header(raw))) if raw else ""
    except Exception:
        decoded = raw
    name = Path(decoded.replace("\\", "/")).name.strip().replace("\x00", "")
    if name in {"", ".", ".."}:
        import mimetypes
        ext = mimetypes.guess_extension(content_type or "") or ".bin"
        name = f"anexo-{index:02d}{ext}"
    # Evita caracteres de controle e nomes absurdamente longos; preserva Unicode legível.
    name = re.sub(r"[\r\n\t]+", " ", name).strip()[:180]
    return name or f"anexo-{index:02d}.bin"


def _attachments(msg: Message) -> tuple[IncomingAttachment, ...]:
    if not msg.is_multipart():
        return ()
    result: list[IncomingAttachment] = []
    used: set[str] = set()
    index = 0
    for part in msg.walk():
        if part.is_multipart():
            continue
        disposition = str(part.get("Content-Disposition", "") or "").lower()
        filename = part.get_filename() or ""
        # Considera anexo explícito ou qualquer parte com filename (inclui imagens inline anexadas).
        if "attachment" not in disposition and not filename:
            continue
        payload = part.get_payload(decode=True)
        if payload is None:
            try:
                content = part.get_content()
                payload = content.encode(part.get_content_charset() or "utf-8") if isinstance(content, str) else bytes(content)
            except Exception:
                payload = b""
        index += 1
        content_type = str(part.get_content_type() or "application/octet-stream")
        safe = _safe_attachment_filename(filename, index, content_type)
        base = safe
        suffix = 2
        while safe.lower() in used:
            path = Path(base)
            safe = f"{path.stem}-{suffix}{path.suffix}"
            suffix += 1
        used.add(safe.lower())
        result.append(IncomingAttachment(filename=safe, content_type=content_type, data=payload or b""))
    return tuple(result)

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
        sender_name=_single_line(sender_name),
        sender_email=_single_line(sender_email).lower(),
        recipient=_single_line(recipient),
        subject=subject,
        body=_plain_body(msg),
        references=refs,
        auto_submitted=_header(msg, "Auto-Submitted").lower(),
        precedence=_header(msg, "Precedence").lower(),
        list_id=_header(msg, "List-Id"),
        mail_date=_mail_date(msg),
        attachments=_attachments(msg),
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
    # Mensagem vazia continua válida: a IA gera uma confirmação genérica.
    return True, "ok"
