#!/usr/bin/env bash
# Contexto: configs protegidas enviados ao chat com segredos mascarados.
# NUNCA altera o projeto original durante o backup: trabalha somente na cópia temporária.

protected_config_relpath() {
  case "$1" in
    config/local/*|config/remote/*|config/production/*|*/config/local/*|*/config/remote/*|*/config/production/*|.config/*|*/.config/*) return 0 ;;
    *) return 1 ;;
  esac
}

mergeable_protected_config_relpath() {
  local rel="$1" name suffix
  protected_config_relpath "$rel" || return 1
  name="${rel##*/}"
  name="${name,,}"
  case "$name" in
    env|.env|config|settings|.env.*|*.env|*.ini|*.conf|*.cfg|*.properties|*.json) return 0 ;;
    *) return 1 ;;
  esac
}

sanitize_backup_config_passwords() {
  local backup_dir="$1"

  python3 - "$backup_dir" <<'PY_SANITIZE'
import re
import sys
from pathlib import Path

root = Path(sys.argv[1])
placeholder = "********"
secret_key = re.compile(
    r"(?:^|_)(?:PASSWORD|PASSWD|PWD|SECRET|TOKEN|API_KEY|ADMIN_KEY|ACCESS_KEY|PRIVATE_KEY)(?:$|_)",
    re.IGNORECASE,
)
assignment = re.compile(
    r"^(?P<prefix>\s*(?:export\s+)?(?P<key>[A-Za-z_][A-Za-z0-9_.-]*)\s*=\s*)(?P<value>.*?)(?P<ending>\r?\n?)$"
)
url_credentials = re.compile(
    r"(?P<prefix>\b[A-Za-z][A-Za-z0-9+.-]*://[^\s:/@]+:)(?P<password>[^\s@]*)(?P<suffix>@)"
)
pem_private = re.compile(
    r"-----BEGIN [^-\r\n]*PRIVATE KEY-----.*?-----END [^-\r\n]*PRIVATE KEY-----",
    re.IGNORECASE | re.DOTALL,
)
changed_files = 0
changed_values = 0
fully_redacted = 0


def rel_parts(path: Path):
    return path.relative_to(root).parts


def protected(path: Path) -> bool:
    parts = rel_parts(path)
    if any(part.lower() == ".config" for part in parts[:-1]):
        return True
    for i in range(len(parts) - 2):
        if parts[i].lower() == "config" and parts[i + 1].lower() in {"local", "remote", "production"}:
            return True
    return False


def mergeable(path: Path) -> bool:
    name = path.name.lower()
    return (
        name in {"env", ".env", "config", "settings"}
        or name.startswith(".env.")
        or name.endswith(".env")
        or path.suffix.lower() in {".ini", ".conf", ".cfg", ".properties", ".json"}
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
    if not path.is_file() or not protected(path):
        continue

    # Formato que não sabemos reconciliar com segurança: mantém o caminho no
    # ZIP, mas nunca envia o conteúdo. Na volta ele também nunca sobrescreve o local.
    if not mergeable(path):
        path.write_text(placeholder + "\n", encoding="utf-8")
        changed_files += 1
        fully_redacted += 1
        continue

    try:
        raw = path.read_bytes()
    except OSError:
        continue

    if path.suffix.lower() == ".json":
        try:
            import json
            data = json.loads(raw.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            path.write_text(placeholder + "\n", encoding="utf-8")
            changed_files += 1
            fully_redacted += 1
            continue

        json_changed = False

        def sanitize_json(value, key=None):
            global json_changed, changed_values
            if key is not None and secret_key.search(str(key)):
                if value not in (None, "", placeholder):
                    json_changed = True
                    changed_values += 1
                return placeholder
            if isinstance(value, dict):
                return {k: sanitize_json(v, k) for k, v in value.items()}
            if isinstance(value, list):
                return [sanitize_json(v) for v in value]
            if isinstance(value, str):
                masked, count = url_credentials.subn(
                    lambda item: f"{item.group('prefix')}{placeholder}{item.group('suffix')}",
                    value,
                )
                if count:
                    json_changed = True
                    changed_values += count
                return masked
            return value

        sanitized = sanitize_json(data)
        if json_changed:
            path.write_text(
                json.dumps(sanitized, ensure_ascii=False, indent=2) + "\n",
                encoding="utf-8",
            )
            changed_files += 1
        continue

    if b"\x00" in raw:
        path.write_text(placeholder + "\n", encoding="utf-8")
        changed_files += 1
        fully_redacted += 1
        continue

    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError:
        path.write_text(placeholder + "\n", encoding="utf-8")
        changed_files += 1
        fully_redacted += 1
        continue

    # Chaves privadas PEM não podem vazar mesmo se estiverem em valor multilinha.
    text, pem_count = pem_private.subn(placeholder, text)
    if pem_count:
        changed_values += pem_count

    output = []
    file_changed = pem_count > 0
    lines = text.splitlines(keepends=True)
    i = 0
    while i < len(lines):
        line = lines[i]
        match = assignment.match(line)
        if not match:
            output.append(line)
            i += 1
            continue

        key = match.group("key")
        value = match.group("value")

        # Valor secreto multilinha entre aspas: é mais seguro redigir o arquivo
        # inteiro do que tentar adivinhar onde termina o segredo.
        stripped = value.strip()
        if secret_key.search(key) and stripped[:1] in {"'", '"'}:
            quote = stripped[0]
            if not (len(stripped) >= 2 and stripped.endswith(quote)):
                path.write_text(placeholder + "\n", encoding="utf-8")
                changed_files += 1
                fully_redacted += 1
                output = None
                break

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
        i += 1

    if output is None:
        continue
    if file_changed:
        path.write_text("".join(output), encoding="utf-8", newline="")
        changed_files += 1

print(f"{changed_files}:{changed_values}:{fully_redacted}")
PY_SANITIZE
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

valid_import_relative_path() {
  local rel="$1"
  case "$rel" in
    ""|/*|..|../*|*/../*|*/..) return 1 ;;
    *) return 0 ;;
  esac
}
