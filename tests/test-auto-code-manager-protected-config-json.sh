#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
T="$(mktemp -d /tmp/devauto-protected-json-XXXXXX)"
trap 'rm -rf -- "$T"' EXIT

PROJECT="$T/project"
SOURCE="$T/source"
FILTERED="$T/filtered"
BACKUP="$T/backup"
mkdir -p "$PROJECT/.config/amazon-imap-bot" "$SOURCE/.config/amazon-imap-bot" "$FILTERED" "$BACKUP/.config/amazon-imap-bot"

cat > "$BACKUP/.config/amazon-imap-bot/functions.json" <<'JSON'
{
  "version": 1,
  "functions": {"project_zip_edit": {"enabled": true}},
  "api_token": "backup-secret"
}
JSON

source "$ROOT/scripts/dev-manager/100-protected-config.sh"
sanitize_backup_config_passwords "$BACKUP" >/dev/null
python3 - "$BACKUP/.config/amazon-imap-bot/functions.json" <<'PY'
import json, sys
p = sys.argv[1]
data = json.load(open(p, encoding="utf-8"))
assert data["version"] == 1
assert data["functions"]["project_zip_edit"]["enabled"] is True
assert data["api_token"] == "********"
PY

cat > "$PROJECT/.config/amazon-imap-bot/functions.json" <<'JSON'
{
  "version": 1,
  "functions": {"old": {"enabled": true}},
  "api_token": "local-secret"
}
JSON
cat > "$SOURCE/.config/amazon-imap-bot/functions.json" <<'JSON'
{
  "version": 2,
  "functions": {"project_zip_edit": {"enabled": true}},
  "api_token": "********"
}
JSON

source "$ROOT/scripts/dev-manager/120-protected-config-merge.sh"
PROTECTED_CONFIG_BASELINES_DIR="$T/baselines"
project_path(){ printf '%s\n' "$PROJECT"; }
protected_config_baseline_dir(){ printf '%s\n' "$T/baseline"; }
project_relpath_belongs_to_registered_subproject(){ return 1; }
log(){ :; }

materialize_changed_protected_configs demo "$SOURCE" "$FILTERED"
python3 - "$FILTERED/.config/amazon-imap-bot/functions.json" <<'PY'
import json, sys
p = sys.argv[1]
data = json.load(open(p, encoding="utf-8"))
assert data["version"] == 2
assert "project_zip_edit" in data["functions"]
assert "old" not in data["functions"]
assert data["api_token"] == "local-secret"
PY

echo 'OK: JSON em .config é importável e preserva segredo local'
