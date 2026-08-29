from __future__ import annotations

import json
import os
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Any

from .config_store import Settings
from .errors import ApiError
from .paths import AppPaths


@dataclass(frozen=True)
class LocalUsage:
    requests: int = 0
    input_tokens: int = 0
    output_tokens: int = 0
    transcribed_seconds: float = 0.0
    zip_jobs: int = 0
    updated_at: str = ""

    def as_dict(self) -> dict[str, Any]:
        return {
            "requests": self.requests,
            "input_tokens": self.input_tokens,
            "output_tokens": self.output_tokens,
            "total_tokens": self.input_tokens + self.output_tokens,
            "transcribed_seconds": round(self.transcribed_seconds, 2),
            "zip_jobs": self.zip_jobs,
            "updated_at": self.updated_at,
        }


class UsageStore:
    def __init__(self, paths: AppPaths | None = None):
        self.paths = paths or AppPaths.discover()
        self.path = self.paths.config_root / "usage.json"

    def load(self) -> LocalUsage:
        if not self.path.exists():
            return LocalUsage()
        try:
            data = json.loads(self.path.read_text(encoding="utf-8"))
            return LocalUsage(
                requests=int(data.get("requests", 0)),
                input_tokens=int(data.get("input_tokens", 0)),
                output_tokens=int(data.get("output_tokens", 0)),
                transcribed_seconds=float(data.get("transcribed_seconds", 0.0)),
                zip_jobs=int(data.get("zip_jobs", 0)),
                updated_at=str(data.get("updated_at", "")),
            )
        except (OSError, ValueError, TypeError, json.JSONDecodeError):
            return LocalUsage()

    def record(self, input_tokens: int = 0, output_tokens: int = 0, seconds: float = 0.0, zip_job: bool = False) -> LocalUsage:
        current = self.load()
        updated = LocalUsage(
            requests=current.requests + 1,
            input_tokens=current.input_tokens + max(0, int(input_tokens)),
            output_tokens=current.output_tokens + max(0, int(output_tokens)),
            transcribed_seconds=current.transcribed_seconds + max(0.0, float(seconds)),
            zip_jobs=current.zip_jobs + int(zip_job),
            updated_at=datetime.now(timezone.utc).isoformat(timespec="seconds"),
        )
        self.paths.config_root.mkdir(parents=True, exist_ok=True)
        temp = self.path.with_suffix(".tmp")
        old_umask = os.umask(0o077)
        try:
            temp.write_text(json.dumps(updated.as_dict(), ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
            os.replace(temp, self.path)
        finally:
            os.umask(old_umask)
            try:
                temp.unlink()
            except OSError:
                pass
        return updated


def fetch_organization_costs(settings: Settings, days: int = 30) -> dict[str, Any]:
    if not settings.admin_api_key:
        raise ApiError("OPENAI_ADMIN_KEY não configurada; o painel remoto de custos exige uma Admin API key")
    end = int(time.time())
    start = end - max(1, min(days, 180)) * 86400
    query = urllib.parse.urlencode({"start_time": start, "end_time": end, "bucket_width": "1d", "limit": min(days, 180)})
    url = f"{settings.base_url.rstrip('/')}/organization/costs?{query}"
    request = urllib.request.Request(
        url,
        headers={"Authorization": f"Bearer {settings.admin_api_key}", "Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(request, timeout=settings.request_timeout_seconds) as response:
            payload = json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", errors="replace")[:500]
        raise ApiError(f"consulta de custos falhou (HTTP {exc.code}): {detail}") from exc
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as exc:
        raise ApiError(f"consulta de custos falhou: {exc}") from exc

    total = 0.0
    currency = "usd"
    buckets = payload.get("data") if isinstance(payload, dict) else []
    for bucket in buckets or []:
        for result in bucket.get("results") or []:
            amount = result.get("amount") or {}
            total += float(amount.get("value") or 0.0)
            currency = str(amount.get("currency") or currency)
    return {"days": days, "total": round(total, 6), "currency": currency, "buckets": len(buckets or [])}
