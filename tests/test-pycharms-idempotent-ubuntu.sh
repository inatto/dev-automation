#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TMP="$(mktemp -d /tmp/pycharms-idempotent-ubuntu-XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

CODE="$TMP/Code"
CFG="$TMP/projects"
STATE="$TMP/state"
OPEN="$TMP/open-projects.tsv"
BIN="$TMP/bin"
LOG="$TMP/open.log"
mkdir -p "$CODE/orgs/a/proj-a" "$CODE/orgs/b/proj-b" "$BIN" "$STATE"
cat > "$CFG" <<'EOF'
orgs/a/proj-a
orgs/b/proj-b
EOF

# proj-a já está aberto antes da primeira execução.
printf '%s\n' "$CODE/orgs/a/proj-a" > "$OPEN"

cat > "$BIN/pycharm" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$1" >> "$OPEN_LOG"
printf '%s\n' "$1" >> "$OPEN_STATE_PATH"
EOF
chmod +x "$BIN/pycharm"

run_pycharms() {
  PATH="$BIN:$PATH" \
  OPEN_LOG="$LOG" \
  OPEN_STATE_PATH="$OPEN" \
  CODE_ROOT="$CODE" \
  AUTO_CODE_STATE_DIR="$STATE" \
  PYCHARMS_PROJECTS_FILE="$CFG" \
  PYCHARMS_PLATFORM=ubuntu \
  PYCHARMS_OPEN_PROJECTS_FILE="$OPEN" \
  PYCHARMS_OPEN_DELAY_SECONDS=0 \
  XDG_SESSION_TYPE=x11 \
  "$ROOT/scripts/pycharms.sh"
}

out1="$(run_pycharms)"
sleep 0.3
[[ -f "$LOG" ]] || { echo 'FALHOU: primeira execução não abriu o projeto faltante' >&2; exit 1; }
mapfile -t opened < "$LOG"
[[ ${#opened[@]} -eq 1 && "${opened[0]}" == "$CODE/orgs/b/proj-b" ]] || {
  printf 'FALHOU: primeira execução deveria abrir somente proj-b. Log:\n%s\n' "$(cat "$LOG")" >&2
  exit 1
}
grep -Fq 'já aberto; ignorando workspace 2' <<<"$out1" || { echo 'FALHOU: não informou que proj-a já estava aberto' >&2; exit 1; }

out2="$(run_pycharms)"
sleep 0.3
mapfile -t opened2 < "$LOG"
[[ ${#opened2[@]} -eq 1 ]] || {
  printf 'FALHOU: segunda execução abriu projeto duplicado. Log:\n%s\n' "$(cat "$LOG")" >&2
  exit 1
}
grep -Fq 'todos os projetos já estão abertos; nenhuma nova janela criada' <<<"$out2" || {
  echo 'FALHOU: segunda execução não reconheceu estado idempotente' >&2
  exit 1
}

EXT="$ROOT/apps/pycharms-gnome-extension/extension.js"
grep -q 'open-projects.request' "$EXT" || { echo 'FALHOU: extensão não recebe pedido de snapshot' >&2; exit 1; }
grep -q '_writeOpenProjectsSnapshot' "$EXT" || { echo 'FALHOU: extensão não grava snapshot de janelas abertas' >&2; exit 1; }
grep -q 'OPEN_PROJECTS_READY_PATH' "$EXT" || { echo 'FALHOU: extensão não confirma snapshot ao backend' >&2; exit 1; }

echo 'OK: pycharms Ubuntu é idempotente: ignora abertos, abre só faltantes e segunda execução não duplica janelas.'
