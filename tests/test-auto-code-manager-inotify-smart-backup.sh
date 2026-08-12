#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TEMP="$(mktemp -d /tmp/auto-code-inotify-smart-XXXXXX)"
TEST_PROJECT="$TEMP/manager"
CODE_ROOT="$TEMP/Code"
DOWNLOADS="$TEMP/Downloads"
LOG="$TEMP/manager.log"
PID=""

cleanup() {
  if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
    kill -TERM "$PID" 2>/dev/null || true
    wait "$PID" 2>/dev/null || true
  fi
  rm -rf -- "$TEMP"
}
trap cleanup EXIT

command -v inotifywait >/dev/null 2>&1 || {
  printf 'SKIP: inotifywait não instalado\n'
  exit 0
}

cp -a -- "$ROOT" "$TEST_PROJECT"
mkdir -p \
  "$DOWNLOADS" \
  "$CODE_ROOT/bots/dev-automation/apps/exec-agent/node_modules/pkg" \
  "$CODE_ROOT/orgs/other"

printf 'parent-v1\n' > "$CODE_ROOT/bots/dev-automation/root.txt"
printf 'child-v1\n' > "$CODE_ROOT/bots/dev-automation/apps/exec-agent/app.txt"
printf 'ignored-v1\n' > "$CODE_ROOT/bots/dev-automation/apps/exec-agent/node_modules/pkg/cache.txt"
printf 'other-v1\n' > "$CODE_ROOT/orgs/other/app.txt"

cat > "$TEST_PROJECT/config/auto-code-manager.projects" <<'PROJECTS'
bots/dev-automation
bots/dev-automation/apps/exec-agent
bots/dev-automation/apps.zip
Code.zip
orgs/other
PROJECTS
cat > "$TEST_PROJECT/config/auto-code-manager.ignore-zip" <<'IGNORE'
.git/
.venv/
venv/
node_modules/
*.log
*:Zone.Identifier
IGNORE
: > "$TEST_PROJECT/config/auto-code-manager.ignore-unzip"
: > "$TEST_PROJECT/config/auto-code-manager.folder-sql-zip"
cat > "$TEST_PROJECT/config/auto-code-manager.env" <<'ENV'
INTERVAL=1
ZONE_EVERY=60
BACKUP_EVERY=2
STABLE_WAIT=1
BEEP_REPEATS=1
BEEP_GAP_MS=1
BEEP_MODE="beep"
BEEP_VOLUME=0
BACKUP_BEEP_ENABLED=false
BACKUP_BEEP_VOLUME=0
TASKBAR_STATUS_ENABLED=false
ENV

DOWNLOADS_DIR="$DOWNLOADS" CODE_ROOT="$CODE_ROOT" AUTO_CODE_STATE_DIR="$TEMP/state" \
  "$TEST_PROJECT/scripts/auto-code-manager.sh" >"$LOG" 2>&1 &
PID=$!

wait_for_file() {
  local file="$1"
  local i
  for i in $(seq 1 80); do
    [ -s "$file" ] && return 0
    sleep 0.1
  done
  printf 'FALHOU: arquivo não apareceu: %s\n' "$file" >&2
  cat "$LOG" >&2
  exit 1
}

wait_for_hash_change() {
  local file="$1" old="$2"
  local i new
  for i in $(seq 1 120); do
    new="$(sha256sum "$file" | awk '{print $1}')"
    [ "$new" != "$old" ] && return 0
    sleep 0.1
  done
  printf 'FALHOU: ZIP não mudou após alteração real: %s\n' "$file" >&2
  cat "$LOG" >&2
  exit 1
}

for zip in dev-automation.zip dev-automation--exec-agent.zip apps.zip Code.zip other.zip; do
  wait_for_file "$CODE_ROOT/$zip"
done

# Aguarda a baseline e o watcher estabilizarem.
sleep 1
grep -Fxq "@$CODE_ROOT/bots/dev-automation/apps/exec-agent/node_modules" "$TEMP/state/inotify-paths.txt" || {
  printf 'FALHOU: node_modules não foi podado da árvore de watches inotify\n' >&2
  cat "$TEMP/state/inotify-paths.txt" >&2
  exit 1
}
parent_before="$(sha256sum "$CODE_ROOT/dev-automation.zip" | awk '{print $1}')"
child_before="$(sha256sum "$CODE_ROOT/dev-automation--exec-agent.zip" | awk '{print $1}')"
apps_before="$(sha256sum "$CODE_ROOT/apps.zip" | awk '{print $1}')"
code_before="$(sha256sum "$CODE_ROOT/Code.zip" | awk '{print $1}')"
other_before="$(sha256sum "$CODE_ROOT/other.zip" | awk '{print $1}')"

printf 'child-v2\n' > "$CODE_ROOT/bots/dev-automation/apps/exec-agent/app.txt"
wait_for_hash_change "$CODE_ROOT/dev-automation--exec-agent.zip" "$child_before"
wait_for_hash_change "$CODE_ROOT/apps.zip" "$apps_before"
wait_for_hash_change "$CODE_ROOT/Code.zip" "$code_before"

parent_after="$(sha256sum "$CODE_ROOT/dev-automation.zip" | awk '{print $1}')"
other_after="$(sha256sum "$CODE_ROOT/other.zip" | awk '{print $1}')"
[ "$parent_after" = "$parent_before" ] || {
  printf 'FALHOU: alteração do filho refez indevidamente o ZIP do pai\n' >&2
  exit 1
}
[ "$other_after" = "$other_before" ] || {
  printf 'FALHOU: alteração do filho refez projeto não relacionado\n' >&2
  exit 1
}

# Uma alteração exclusivamente ignorada não pode sujar o backup do filho.
child_after="$(sha256sum "$CODE_ROOT/dev-automation--exec-agent.zip" | awk '{print $1}')"
printf 'ignored-v2\n' > "$CODE_ROOT/bots/dev-automation/apps/exec-agent/node_modules/pkg/cache.txt"
sleep 4
child_ignored="$(sha256sum "$CODE_ROOT/dev-automation--exec-agent.zip" | awk '{print $1}')"
[ "$child_ignored" = "$child_after" ] || {
  printf 'FALHOU: node_modules disparou backup mesmo estando ignorado\n' >&2
  cat "$LOG" >&2
  exit 1
}

# Diretório ignorado criado depois do watcher subir deve provocar apenas
# repruning do inotify, nunca backup do projeto.
other_before_dynamic="$(sha256sum "$CODE_ROOT/other.zip" | awk '{print $1}')"
mkdir -p "$CODE_ROOT/orgs/other/node_modules/pkg"
printf 'dynamic-cache\n' > "$CODE_ROOT/orgs/other/node_modules/pkg/cache.txt"
sleep 4
other_after_dynamic="$(sha256sum "$CODE_ROOT/other.zip" | awk '{print $1}')"
[ "$other_after_dynamic" = "$other_before_dynamic" ] || {
  printf 'FALHOU: node_modules criado em runtime disparou backup\n' >&2
  cat "$LOG" >&2
  exit 1
}
pruned=false
for _i in $(seq 1 60); do
  if grep -Fxq "@$CODE_ROOT/orgs/other/node_modules" "$TEMP/state/inotify-paths.txt" 2>/dev/null; then
    pruned=true
    break
  fi
  sleep 0.1
done
[ "$pruned" = true ] || {
  printf 'FALHOU: node_modules criado em runtime não foi podado após reload\n' >&2
  cat "$TEMP/state/inotify-paths.txt" >&2
  cat "$LOG" >&2
  exit 1
}

# Sem qualquer mudança, também não existe backup periódico por relógio.
sleep 3
child_idle="$(sha256sum "$CODE_ROOT/dev-automation--exec-agent.zip" | awk '{print $1}')"
[ "$child_idle" = "$child_after" ] || {
  printf 'FALHOU: ZIP foi refeito sem alteração de fonte\n' >&2
  cat "$LOG" >&2
  exit 1
}

grep -Fq 'Backup inteligente ativo via inotify' "$LOG"
grep -Fq 'backup pendente: bots/dev-automation/apps/exec-agent' "$LOG" || grep -Fq 'Alteração detectada; backup pendente: bots/dev-automation/apps/exec-agent' "$LOG"
grep -Fq 'Backup inteligente concluído: 1 projeto(s) alterado(s)' "$LOG"

printf 'OK: inotify refaz somente o subprojeto alterado e agregadores dependentes; pai, projetos alheios e ignorados ficam intactos\n'
