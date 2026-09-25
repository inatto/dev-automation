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

assert_one_sql_zip() {
  local zip_file="$1"
  local expected_entry="$2"
  local entries

  unzip -tq "$zip_file" >/dev/null
  entries="$(unzip -Z1 "$zip_file" | sed '/\/$/d')"
  [ "$(printf '%s\n' "$entries" | sed '/^$/d' | wc -l | tr -d ' ')" -eq 1 ]
  printf '%s\n' "$entries" | grep -Fx "$expected_entry" >/dev/null
}

# 1) O nome do SQL define o nome do ZIP; só aquele SQL entra no arquivo.
printf 'create table a (id number);\n' > "$DDL/a.sql"
run_snapshot_once
[ -f "$DDL/a.sql" ]
[ -f "$DDL/a.zip" ]
assert_one_sql_zip "$DDL/a.zip" 'a.sql'
unzip -p "$DDL/a.zip" a.sql | grep -Fq 'create table a (id number);'
[ -f "$CODE_ROOT/a.zip" ]
cmp -s -- "$DDL/a.zip" "$CODE_ROOT/a.zip"

# 2) Se a.zip já existe, alterar a.sql não recria nem sobrescreve o ZIP.
checksum_before="$(sha256sum "$DDL/a.zip" | awk '{print $1}')"
printf 'create table a (id number, name varchar2(30));\n' > "$DDL/a.sql"
run_snapshot_once
checksum_after="$(sha256sum "$DDL/a.zip" | awk '{print $1}')"
[ "$checksum_before" = "$checksum_after" ]
unzip -p "$DDL/a.zip" a.sql | grep -Fq 'create table a (id number);'
! unzip -p "$DDL/a.zip" a.sql | grep -Fq 'name varchar2(30)'

# 3) Arquivo vazio e arquivo não-SQL não geram ZIP.
printf '   \n\t\n' > "$DDL/b.sql"
printf 'nao compactar\n' > "$DDL/nao-sql.txt"
run_snapshot_once
[ ! -e "$DDL/b.zip" ]
[ ! -e "$DDL/nao-sql.zip" ]

# 4) Assim que b.sql recebe conteúdo real, gera exatamente b.zip.
printf 'create table b (id number);\n' > "$DDL/b.sql"
run_snapshot_once
[ -f "$DDL/b.zip" ]
assert_one_sql_zip "$DDL/b.zip" 'b.sql'
unzip -p "$DDL/b.zip" b.sql | grep -Fq 'create table b'

# 5) Nome escolhido pelo usuário é preservado literalmente no ZIP.
printf 'create table backup_escolhido (id number);\n' > "$DDL/meu-backup-2026.sql"
run_snapshot_once
[ -f "$DDL/meu-backup-2026.zip" ]
assert_one_sql_zip "$DDL/meu-backup-2026.zip" 'meu-backup-2026.sql'

# 6) Se o ZIP correspondente já existir, ele é ignorado sem ser validado/alterado.
printf 'create table existente (id number);\n' > "$DDL/existente.sql"
printf 'zip-preexistente-nao-tocar\n' > "$DDL/existente.zip"
existing_before="$(sha256sum "$DDL/existente.zip" | awk '{print $1}')"
run_snapshot_once
existing_after="$(sha256sum "$DDL/existente.zip" | awk '{print $1}')"
[ "$existing_before" = "$existing_after" ]

grep -Fq 'ZIP DDL: a.zip' "$LOG"
grep -Fq 'ZIP DDL: b.zip' "$LOG"
grep -Fq 'ZIP DDL: meu-backup-2026.zip' "$LOG"

# 7) now.sql vazio não gera ZIP; com conteúdo gera YYYYMMDD-HHMM.zip.
printf '   \n\t\n' > "$DDL/now.sql"
run_snapshot_once
now_count_before="$(find "$DDL" -maxdepth 1 -type f -regextype posix-extended -regex '.*/[0-9]{8}-[0-9]{4}\.zip' | wc -l | tr -d ' ')"
[ "$now_count_before" -eq 0 ]
printf 'create table now_backup (id number);\n' > "$DDL/now.sql"
run_snapshot_once
now_zip="$(find "$DDL" -maxdepth 1 -type f -regextype posix-extended -regex '.*/[0-9]{8}-[0-9]{4}\.zip' -print -quit)"
[ -n "$now_zip" ]
assert_one_sql_zip "$now_zip" 'now.sql'
unzip -p "$now_zip" now.sql | grep -Fq 'create table now_backup'

# Mesmo conteúdo de now.sql não cria outro backup em nova reconciliação.
now_count_before="$(find "$DDL" -maxdepth 1 -type f -regextype posix-extended -regex '.*/[0-9]{8}-[0-9]{4}\.zip' | wc -l | tr -d ' ')"
run_snapshot_once
now_count_after="$(find "$DDL" -maxdepth 1 -type f -regextype posix-extended -regex '.*/[0-9]{8}-[0-9]{4}\.zip' | wc -l | tr -d ' ')"
[ "$now_count_before" -eq "$now_count_after" ]

printf 'OK: Oracle DDL = <nome>.sql -> <nome>.zip; now.sql -> YYYYMMDD-HHMM.zip; vazios ignorados\n'
