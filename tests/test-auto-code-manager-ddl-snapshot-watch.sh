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
    "$MANAGER/scripts/auto-code-manager.sh" --sql-snapshot-once >>"$LOG" 2>&1
}

snapshot_count_local() {
  find "$DDL" -maxdepth 1 -type f -name 'oracle-infra-ddl-*.zip' | wc -l | tr -d ' '
}

snapshot_count_root() {
  find "$CODE_ROOT" -maxdepth 1 -type f -name 'oracle-infra-ddl-*.zip' | wc -l | tr -d ' '
}

latest_local_zip() {
  find "$DDL" -maxdepth 1 -type f -name 'oracle-infra-ddl-*.zip' -printf '%T@\t%p\n' | sort -nr | head -n1 | cut -f2-
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

# 1) SQL novo e preenchido: apenas baseline, sem ZIP.
printf 'create table a (id number);\n' > "$DDL/a.sql"
run_snapshot_once
[ "$(snapshot_count_local)" -eq 0 ]
[ "$(snapshot_count_root)" -eq 0 ]
grep -Fq "$DDL/a.sql" "$STATE_DIR/sql-snapshot-signatures.tsv"

# 2) Alteração posterior: 1 ZIP, contendo somente a.sql.
printf 'create table a (id number, name varchar2(30));\n' > "$DDL/a.sql"
run_snapshot_once
[ "$(snapshot_count_local)" -eq 1 ]
[ "$(snapshot_count_root)" -eq 1 ]
zip_a="$(latest_local_zip)"
root_a="$CODE_ROOT/$(basename -- "$zip_a")"
assert_one_sql_zip "$zip_a" 'a.sql'
cmp -s -- "$zip_a" "$root_a"

# 3) Outro SQL novo não gera ZIP na primeira aparição.
printf 'create table b (id number);\n' > "$DDL/b.sql"
run_snapshot_once
[ "$(snapshot_count_local)" -eq 1 ]
[ "$(snapshot_count_root)" -eq 1 ]

# 4) Depois de alterado, b.sql ganha seu próprio ZIP; Code continua com apenas o mais recente.
printf 'create table b (id number, note varchar2(20));\n' > "$DDL/b.sql"
run_snapshot_once
[ "$(snapshot_count_local)" -eq 2 ]
[ "$(snapshot_count_root)" -eq 1 ]
zip_b="$(latest_local_zip)"
root_b="$CODE_ROOT/$(basename -- "$zip_b")"
assert_one_sql_zip "$zip_b" 'b.sql'
cmp -s -- "$zip_b" "$root_b"
[ ! -e "$root_a" ]

# 5) Vazio/whitespace nunca gera ZIP nem baseline novo.
printf '   \n\t\n' > "$DDL/c.sql"
run_snapshot_once
[ "$(snapshot_count_local)" -eq 2 ]
! grep -Fq "$DDL/c.sql" "$STATE_DIR/sql-snapshot-signatures.tsv"

# Primeiro conteúdo real de c.sql ainda é baseline de arquivo novo.
printf 'create table c (id number);\n' > "$DDL/c.sql"
run_snapshot_once
[ "$(snapshot_count_local)" -eq 2 ]
grep -Fq "$DDL/c.sql" "$STATE_DIR/sql-snapshot-signatures.tsv"

# Segunda gravação de c.sql gera ZIP individual.
printf 'create table c (id number, enabled number(1));\n' > "$DDL/c.sql"
run_snapshot_once
[ "$(snapshot_count_local)" -eq 3 ]
[ "$(snapshot_count_root)" -eq 1 ]
zip_c="$(latest_local_zip)"
root_c="$CODE_ROOT/$(basename -- "$zip_c")"
assert_one_sql_zip "$zip_c" 'c.sql'
cmp -s -- "$zip_c" "$root_c"
[ ! -e "$root_b" ]

# 6) Apagado + reconciliado + recriado = arquivo novo de novo, sem ZIP.
rm -f -- "$DDL/b.sql"
run_snapshot_once
! grep -Fq "$DDL/b.sql" "$STATE_DIR/sql-snapshot-signatures.tsv"
printf 'create table b (id number, recreated number(1));\n' > "$DDL/b.sql"
run_snapshot_once
[ "$(snapshot_count_local)" -eq 3 ]
grep -Fq "$DDL/b.sql" "$STATE_DIR/sql-snapshot-signatures.tsv"

# 7) Mesmo se houver lixo antigo na raiz Code, uma reconciliação deixa só o ZIP válido mais recente.
cp -f -- "$root_c" "$CODE_ROOT/oracle-infra-ddl-lixo-antigo.zip"
[ "$(snapshot_count_root)" -eq 2 ]
run_snapshot_once
[ "$(snapshot_count_root)" -eq 1 ]
cmp -s -- "$zip_c" "$root_c"

# 8) Repetir sem alteração é idempotente: não cria novos ZIPs.
count_before="$(snapshot_count_local)"
run_snapshot_once
[ "$(snapshot_count_local)" = "$count_before" ]
[ "$(snapshot_count_root)" -eq 1 ]

printf 'OK: Oracle DDL = baseline por arquivo; novo/vazio sem ZIP; alteração = 1 ZIP/1 SQL; Code = somente o ZIP mais recente\n'
