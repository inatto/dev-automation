#!/usr/bin/env bash
# Contexto: sanitização e baseline de configurações protegidas

sanitize_backup_config_passwords() {
  local backup_dir="$1"

  python3 - "$backup_dir" <<'PY_SANITIZE'
import re
import sys
from pathlib import Path

root = Path(sys.argv[1])
placeholder = "********"
config_extensions = {".env", ".ini", ".conf", ".cfg", ".properties"}
config_names = {"env", ".env", "config", "settings"}
secret_key = re.compile(
    r"(?:^|_)(?:PASSWORD|PASSWD|PWD|SECRET|TOKEN|API_KEY|ACCESS_KEY|PRIVATE_KEY)(?:$|_)",
    re.IGNORECASE,
)
assignment = re.compile(
    r"^(?P<prefix>\s*(?:export\s+)?(?P<key>[A-Za-z_][A-Za-z0-9_.-]*)\s*=\s*)(?P<value>.*?)(?P<ending>\r?\n?)$"
)
url_credentials = re.compile(
    r"(?P<prefix>\b[A-Za-z][A-Za-z0-9+.-]*://[^\s:/@]+:)(?P<password>[^\s@]*)(?P<suffix>@)"
)
changed_files = 0
changed_values = 0


def is_config_file(path: Path) -> bool:
    parts = path.relative_to(root).parts
    if not any(part.lower() == "config" for part in parts[:-1]):
        return False

    name = path.name.lower()
    suffix = path.suffix.lower()
    return (
        suffix in config_extensions
        or name in config_names
        or name.startswith(".env.")
        or name.endswith(".env")
    )


def mask_value(value: str) -> str:
    stripped = value.strip()
    if not stripped:
        return value

    leading = value[: len(value) - len(value.lstrip())]
    trailing = value[len(value.rstrip()) :]
    core = stripped

    comment = ""
    comment_match = re.match(r"^(.*?)(\s+[;#][^\r\n]*)$", core)
    if comment_match:
        core, comment = comment_match.groups()
        core = core.rstrip()

    if len(core) >= 2 and core[0] == core[-1] and core[0] in {"'", '"'}:
        masked = f"{core[0]}{placeholder}{core[-1]}"
    else:
        masked = placeholder

    return f"{leading}{masked}{comment}{trailing}"


for path in root.rglob("*"):
    if not path.is_file() or not is_config_file(path):
        continue

    try:
        raw = path.read_bytes()
    except OSError:
        continue

    if b"\x00" in raw:
        continue

    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError:
        continue

    output = []
    file_changed = False

    for line in text.splitlines(keepends=True):
        match = assignment.match(line)
        if not match:
            output.append(line)
            continue

        key = match.group("key")
        value = match.group("value")

        if secret_key.search(key):
            new_value = mask_value(value)
        else:
            new_value = url_credentials.sub(
                lambda item: f"{item.group('prefix')}{placeholder}{item.group('suffix')}",
                value,
            )

        if new_value != value:
            file_changed = True
            changed_values += 1

        output.append(f"{match.group('prefix')}{new_value}{match.group('ending')}")

    if file_changed:
        path.write_text("".join(output), encoding="utf-8", newline="")
        changed_files += 1

print(f"{changed_files}:{changed_values}")
PY_SANITIZE
}

protected_config_relpath() {
  case "$1" in
    */config/local/*|*/config/remote/*|*/config/production/*) return 0 ;;
    *) return 1 ;;
  esac
}

protected_config_baseline_dir() {
  local project="$1"
  printf '%s/%s\n' "$PROTECTED_CONFIG_BASELINES_DIR" "$(project_archive_name "$project")"
}

save_protected_config_baseline() {
  local project="$1"
  local sanitized_root="$2"
  local baseline_dir rel destination

  baseline_dir="$(protected_config_baseline_dir "$project")"
  rm -rf -- "$baseline_dir"
  mkdir -p -- "$baseline_dir"

  while IFS= read -r -d '' rel; do
    protected_config_relpath "$rel" || continue
    destination="$baseline_dir/$rel"
    mkdir -p -- "$(dirname -- "$destination")"
    cp -p -- "$sanitized_root/$rel" "$destination"
  done < <(find "$sanitized_root" -type f -printf '%P\0')
}

canonical_external_relpath() {
  local rel="$1"

  while [[ "$rel" == *.external ]]; do
    rel="${rel%.external}"
  done

  printf '%s.external\n' "$rel"
}

valid_import_relative_path() {
  local rel="$1"
  case "$rel" in
    ""|/*|..|../*|*/../*|*/..) return 1 ;;
    *) return 0 ;;
  esac
}

