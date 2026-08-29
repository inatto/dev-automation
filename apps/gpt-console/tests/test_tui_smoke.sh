#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
TMP="$(mktemp -d /tmp/gpt-console-tui-XXXXXX)"
trap 'rm -rf -- "$TMP"' EXIT

GPT_CONSOLE_CONFIG_ROOT="$TMP/config" \
  bash "$ROOT/apps/gpt-console/run.sh" --validate > "$TMP/validate.json"
grep -Fq '"status": "ok"' "$TMP/validate.json"

printf 'q' | timeout 8 script -qfec \
  "TERM=xterm-256color GPT_CONSOLE_CONFIG_ROOT='$TMP/config' bash '$ROOT/apps/gpt-console/run.sh'" \
  /dev/null >/dev/null

GPT_CONSOLE_CONFIG_ROOT="$TMP/config" \
  bash "$ROOT/apps/gpt-console/run.sh" --dump-json > "$TMP/dump.json"
python3 - "$TMP/dump.json" <<'PY'
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
assert data["app"] == "gpt-console"
assert data["groups"][0]["project_id"] == "orbital-app"
assert data["settings"]["api_key"] == "não configurada"
assert data["config_root"].endswith("/config")
PY

printf 'OK: GPT Console valida configuração, abre a TUI e não expõe chave\n'
