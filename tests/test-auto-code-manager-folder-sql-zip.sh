#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cp -a "$ROOT/." "$TMP/dev-automation/"
mkdir -p "$TMP/code/one" "$TMP/code/two"
printf '%s\n' "$TMP/code/one" "$TMP/code/two" > "$TMP/dev-automation/config/auto-code-manager.folder-sql-zip"
printf 'select 1 from dual;\n' > "$TMP/code/one/qualquer-nome.sql"
printf 'create table x (id number);\n' > "$TMP/code/one/outro.SQL"
printf 'select 2 from dual;\n' > "$TMP/code/two/ddl-solto.sql"

CODE_ROOT="$TMP/code" STABLE_WAIT=1 "$TMP/dev-automation/scripts/auto-code-manager.sh" --sql-zip-once

for folder in one two; do
  test "$(find "$TMP/code/$folder" -maxdepth 1 -type f -iname '*.sql' | wc -l)" -eq 0
  test "$(find "$TMP/code/$folder" -maxdepth 1 -type f -name '????????-????.zip' | wc -l)" -eq 1
  zip_file="$(find "$TMP/code/$folder" -maxdepth 1 -type f -name '????????-????.zip' -print -quit)"
  unzip -tq "$zip_file" >/dev/null
 done

zip_one="$(find "$TMP/code/one" -maxdepth 1 -type f -name '????????-????.zip' -print -quit)"
unzip -Z1 "$zip_one" | grep -Fx 'qualquer-nome.sql' >/dev/null
unzip -Z1 "$zip_one" | grep -Fx 'outro.SQL' >/dev/null

printf 'alter table x add name varchar2(10);\n' > "$TMP/code/one/mais-um.sql"
CODE_ROOT="$TMP/code" STABLE_WAIT=1 "$TMP/dev-automation/scripts/auto-code-manager.sh" --sql-zip-once

test ! -e "$TMP/code/one/mais-um.sql"
test "$(find "$TMP/code/one" -maxdepth 1 -type f -name '????????-????.zip' | wc -l)" -eq 1
unzip -Z1 "$zip_one" | grep -Fx 'mais-um.sql' >/dev/null

echo 'OK: folder SQL ZIP'
