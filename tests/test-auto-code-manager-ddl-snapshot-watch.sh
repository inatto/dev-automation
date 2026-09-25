#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TEMP="$(mktemp -d /tmp/auto-code-ddl-watch-XXXXXX)"
MANAGER="$TEMP/manager"
CODE_ROOT="$TEMP/Code"
HOME_DIR="$TEMP/home"
STATE_DIR="$TEMP/state"
DDL="$CODE_ROOT/infra/oracle-infra/exports/ddl"
LOG="$TEMP/manager.log"
trap 'rm -rf -- "$TEMP"' EXIT

cp -a -- "$ROOT" "$MANAGER"
mkdir -p "$DDL" "$HOME_DIR" "$STATE_DIR"
: > "$MANAGER/config/auto-code-manager.folder-sql-zip"
printf '%s\n' "$DDL" > "$MANAGER/config/auto-code-manager.folder-sql-watch"
cat > "$MANAGER/config/auto-code-manager.env" <<'ENV'
STABLE_WAIT=1
BEEP_REPEATS=1
BEEP_GAP_MS=1
BEEP_MODE=none
BEEP_VOLUME=0
BACKUP_BEEP_ENABLED=false
TASKBAR_STATUS_ENABLED=false
ENV

run_snapshot_once() {
  HOME="$HOME_DIR" CODE_ROOT="$CODE_ROOT" AUTO_CODE_STATE_DIR="$STATE_DIR" AUTO_CODE_TUI=off \
    "$MANAGER/scripts/dev-manager/auto-code-manager.sh" --sql-snapshot-once >>"$LOG" 2>&1
}

snapshot_count_local() {
  find "$DDL" -maxdepth 1 -type f -name '*.zip' | sed -nE '/\/[0-9]{8}-[0-9]{4}\.zip$/p' | wc -l | tr -d ' '
}

snapshot_count_root() {
  find "$CODE_ROOT" -maxdepth 1 -type f -name '*.zip' | sed -nE '/\/[0-9]{8}-[0-9]{4}\.zip$/p' | wc -l | tr -d ' '
}

latest_local_zip() {
  find "$DDL" -maxdepth 1 -type f -name '*.zip' -printf '%T@\t%p\n' | sort -nr | cut -f2- | grep -E '/[0-9]{8}-[0-9]{4}\.zip$' | head -n1
}

assert_one_sql_zip() {
  local zip_file="$1"
  local expected_entry="$2"
  local entries

  unzip -tq "$zip_file" >/dev/null
  entries="$(unzip -Z1 "$zip_file" | sed '/\/$/d')"
  [ "$(printf '%s\n' "$entries" | sed '/^$/d' | wc -l | tr -d ' ')" -eq 1 ]
  printf '%s\n' "$entries" | grep -Fx "$expected_entry" >/dev/null
}

# 1) SQL novo e preenchido: compacta imediatamente.
printf 'create table a (id number);\n' > "$DDL/a.sql"
run_snapshot_once
[ "$(snapshot_count_local)" -eq 1 ]
[ "$(snapshot_count_root)" -eq 1 ]
zip_a="$(latest_local_zip)"
root_a="$CODE_ROOT/$(basename -- "$zip_a")"
[[ "$(basename -- "$zip_a")" =~ ^[0-9]{8}-[0-9]{4}\.zip$ ]]
assert_one_sql_zip "$zip_a" 'a.sql'
cmp -s -- "$zip_a" "$root_a"
grep -Fq "$DDL/a.sql" "$STATE_DIR/sql-snapshot-signatures.tsv"

# 2) Alteração posterior também compacta. Se ocorrer no mesmo minuto, atualiza
# exatamente o mesmo YYYYMMDD-HHMM.zip em vez de inventar sufixo.
printf 'create table a (id number, name varchar2(30));\n' > "$DDL/a.sql"
run_snapshot_once
[ "$(snapshot_count_local)" -eq 1 ]
[ "$(snapshot_count_root)" -eq 1 ]
zip_a2="$(latest_local_zip)"
[[ "$(basename -- "$zip_a2")" =~ ^[0-9]{8}-[0-9]{4}\.zip$ ]]
assert_one_sql_zip "$zip_a2" 'a.sql'
unzip -p "$zip_a2" a.sql | grep -Fq 'name varchar2(30)'
cmp -s -- "$zip_a2" "$CODE_ROOT/$(basename -- "$zip_a2")"

# 3) Arquivo vazio não gera snapshot nem assinatura.
printf '   \n\t\n' > "$DDL/b.sql"
run_snapshot_once
[ "$(snapshot_count_local)" -eq 1 ]
! grep -Fq "$DDL/b.sql" "$STATE_DIR/sql-snapshot-signatures.tsv"

# 4) Assim que b.sql recebe conteúdo real, ele é compactado imediatamente.
printf 'create table b (id number);\n' > "$DDL/b.sql"
run_snapshot_once
[ "$(snapshot_count_local)" -eq 1 ]
[ "$(snapshot_count_root)" -eq 1 ]
zip_b="$(latest_local_zip)"
assert_one_sql_zip "$zip_b" 'b.sql'
unzip -p "$zip_b" b.sql | grep -Fq 'create table b'

# 5) Repetir sem alteração é idempotente.
checksum_before="$(sha256sum "$zip_b" | awk '{print $1}')"
run_snapshot_once
checksum_after="$(sha256sum "$(latest_local_zip)" | awk '{print $1}')"
[ "$checksum_before" = "$checksum_after" ]
[ "$(snapshot_count_local)" -eq 1 ]
[ "$(snapshot_count_root)" -eq 1 ]

grep -Fq 'ZIP DDL:' "$LOG"
printf 'OK: Oracle DDL = novo/alterado compacta imediatamente em YYYYMMDD-HHMM.zip; vazio ignora; repetição é idempotente\n'
