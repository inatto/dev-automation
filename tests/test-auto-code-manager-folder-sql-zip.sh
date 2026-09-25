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
printf 'nao compactar\n' > "$TMP/code/one/ignorar.txt"
printf 'select 2 from dual;\n' > "$TMP/code/two/ddl-solto.sql"

CODE_ROOT="$TMP/code" STABLE_WAIT=1 "$TMP/dev-automation/scripts/dev-manager/auto-code-manager.sh" --sql-zip-once

for spec in \
  "$TMP/code/one/qualquer-nome.zip:qualquer-nome.sql" \
  "$TMP/code/one/outro.zip:outro.SQL" \
  "$TMP/code/two/ddl-solto.zip:ddl-solto.sql"
do
  zip_file="${spec%%:*}"
  sql_name="${spec#*:}"
  test -f "$zip_file"
  unzip -tq "$zip_file" >/dev/null
  test "$(unzip -Z1 "$zip_file" | sed '/\/$/d' | wc -l | tr -d ' ')" -eq 1
  unzip -Z1 "$zip_file" | grep -Fx "$sql_name" >/dev/null
done

# SQLs são preservados e arquivos não-SQL são ignorados.
test -f "$TMP/code/one/qualquer-nome.sql"
test -f "$TMP/code/one/outro.SQL"
test -f "$TMP/code/two/ddl-solto.sql"
test ! -e "$TMP/code/one/ignorar.zip"

# ZIP já existente bloqueia qualquer sobrescrita, mesmo se o SQL mudar.
zip_one="$TMP/code/one/qualquer-nome.zip"
checksum_before="$(sha256sum "$zip_one" | awk '{print $1}')"
printf 'select 999 from dual;\n' > "$TMP/code/one/qualquer-nome.sql"
CODE_ROOT="$TMP/code" STABLE_WAIT=1 "$TMP/dev-automation/scripts/dev-manager/auto-code-manager.sh" --sql-zip-once
checksum_after="$(sha256sum "$zip_one" | awk '{print $1}')"
test "$checksum_before" = "$checksum_after"
unzip -p "$zip_one" qualquer-nome.sql | grep -Fq 'select 1 from dual;'

# Novo nome de SQL gera novo ZIP com o mesmo nome-base.
printf 'alter table x add name varchar2(10);\n' > "$TMP/code/one/mais-um.sql"
CODE_ROOT="$TMP/code" STABLE_WAIT=1 "$TMP/dev-automation/scripts/dev-manager/auto-code-manager.sh" --sql-zip-once
test -f "$TMP/code/one/mais-um.sql"
test -f "$TMP/code/one/mais-um.zip"
unzip -Z1 "$TMP/code/one/mais-um.zip" | grep -Fx 'mais-um.sql' >/dev/null

# Um ZIP pré-existente não é tocado.
printf 'create table bloqueado (id number);\n' > "$TMP/code/one/bloqueado.sql"
printf 'nao-tocar\n' > "$TMP/code/one/bloqueado.zip"
blocked_before="$(sha256sum "$TMP/code/one/bloqueado.zip" | awk '{print $1}')"
CODE_ROOT="$TMP/code" STABLE_WAIT=1 "$TMP/dev-automation/scripts/dev-manager/auto-code-manager.sh" --sql-zip-once
blocked_after="$(sha256sum "$TMP/code/one/bloqueado.zip" | awk '{print $1}')"
test "$blocked_before" = "$blocked_after"

# now.sql vazio é ignorado; com conteúdo gera YYYYMMDD-HHMM.zip.
printf '   \n\t\n' > "$TMP/code/two/now.sql"
CODE_ROOT="$TMP/code" STABLE_WAIT=1 "$TMP/dev-automation/scripts/dev-manager/auto-code-manager.sh" --sql-zip-once
test "$(find "$TMP/code/two" -maxdepth 1 -type f -regextype posix-extended -regex '.*/[0-9]{8}-[0-9]{4}\.zip' | wc -l | tr -d ' ')" -eq 0
printf 'create table now_shortcut (id number);\n' > "$TMP/code/two/now.sql"
CODE_ROOT="$TMP/code" STABLE_WAIT=1 "$TMP/dev-automation/scripts/dev-manager/auto-code-manager.sh" --sql-zip-once
now_zip="$(find "$TMP/code/two" -maxdepth 1 -type f -regextype posix-extended -regex '.*/[0-9]{8}-[0-9]{4}\.zip' -print -quit)"
test -n "$now_zip"
unzip -Z1 "$now_zip" | grep -Fx 'now.sql' >/dev/null
unzip -p "$now_zip" now.sql | grep -Fq 'create table now_shortcut'

echo 'OK: folder SQL ZIP = <nome>.sql -> <nome>.zip; now.sql -> YYYYMMDD-HHMM.zip; vazios ignorados'
