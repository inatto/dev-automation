#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

HOME_DIR="$TMP/home"
CODE_ROOT="$TMP/Code"
TARGET_DIR="$HOME_DIR/.local/bin"
PROJECTS_FILE="$TMP/projects"
RUN_LOG="$TMP/run.log"
mkdir -p "$HOME_DIR"
: > "$HOME_DIR/.bashrc"

cat > "$PROJECTS_FILE" <<'PROJECTS'
orgs/alpha
#orgs/ignored
orgs/beta
orgs/local-only
orgs/gamma
PROJECTS

make_script() {
  local project="$1"
  local mode="$2"
  local action="$3"
  local status="${4:-0}"
  local path="$CODE_ROOT/orgs/$project/deploy/$mode/$action.sh"
  mkdir -p "$(dirname "$path")"
  cat > "$path" <<SCRIPT
#!/usr/bin/env bash
printf '%s:%s:%s:%s\n' '$project' '$mode' '$action' "\${*:-}" >> "\${RUN_LOG:?}"
if [[ '$mode' == 'local' && '$action' == 'setup' && -n "\${LOCAL_SETUP_SLEEP:-}" ]]; then
  sleep "\$LOCAL_SETUP_SLEEP"
fi
if [[ '$mode' == 'remote' && -n "\${REMOTE_SLEEP:-}" ]]; then
  sleep "\$REMOTE_SLEEP"
fi
if [[ "\${FAIL_PROJECT:-}" == '$project' ]]; then
  exit $status
fi
SCRIPT
  chmod +x "$path"
}

for project in alpha beta gamma; do
  for mode in local remote; do
    make_script "$project" "$mode" setup 9
    make_script "$project" "$mode" test 9
  done
done
make_script local-only local setup 9
make_script local-only local test 9

HOME="$HOME_DIR" TARGET_DIR="$TARGET_DIR" CODE_ROOT="$CODE_ROOT" PROJECTS_FILE="$PROJECTS_FILE" \
  "$ROOT/deploy/local/install-project-commands.sh" >/dev/null

[[ -x "$TARGET_DIR/local-all" ]]
[[ -x "$TARGET_DIR/remote-all" ]]
[[ ! -e "$TARGET_DIR/ignored" ]]

# setup local: dispara todos em paralelo/desacoplados e devolve o terminal sem esperar os setups terminarem.
: > "$RUN_LOG"
start_ns="$(date +%s%N)"
RUN_LOG="$RUN_LOG" LOCAL_SETUP_SLEEP=2 XDG_STATE_HOME="$TMP/state" "$TARGET_DIR/local-all" >/dev/null
end_ns="$(date +%s%N)"
elapsed_ms=$(((end_ns - start_ns) / 1000000))
((elapsed_ms < 1000))

for _ in $(seq 1 100); do
  [[ "$(wc -l < "$RUN_LOG")" -ge 4 ]] && break
  sleep 0.02
done
[[ "$(wc -l < "$RUN_LOG")" -eq 4 ]]
grep -Fxq 'alpha:local:setup:' "$RUN_LOG"
grep -Fxq 'beta:local:setup:' "$RUN_LOG"
grep -Fxq 'local-only:local:setup:' "$RUN_LOG"
grep -Fxq 'gamma:local:setup:' "$RUN_LOG"

# Ações locais que terminam (test/stop/etc.) também rodam em paralelo, mas aguardam e agregam o resultado.
: > "$RUN_LOG"
RUN_LOG="$RUN_LOG" XDG_STATE_HOME="$TMP/state" "$TARGET_DIR/local-all" test abc >/dev/null
for expected in \
  'alpha:local:test:abc' \
  'beta:local:test:abc' \
  'local-only:local:test:abc' \
  'gamma:local:test:abc'; do
  grep -Fxq "$expected" "$RUN_LOG"
done
[[ "$(wc -l < "$RUN_LOG")" -eq 4 ]]

# Falha local não impede os demais jobs paralelos de executar; o comando retorna código de falha ao final.
: > "$RUN_LOG"
set +e
RUN_LOG="$RUN_LOG" FAIL_PROJECT=beta XDG_STATE_HOME="$TMP/state" "$TARGET_DIR/local-all" test >/dev/null 2>&1
status=$?
set -e
[[ "$status" -eq 9 ]]
[[ "$(wc -l < "$RUN_LOG")" -eq 4 ]]
grep -Fxq 'alpha:local:test:' "$RUN_LOG"
grep -Fxq 'beta:local:test:' "$RUN_LOG"
grep -Fxq 'local-only:local:test:' "$RUN_LOG"
grep -Fxq 'gamma:local:test:' "$RUN_LOG"

# Remoto roda todos os projetos em paralelo, mostra prefixos ao vivo e espera todos terminarem.
: > "$RUN_LOG"
start_ns="$(date +%s%N)"
RUN_LOG="$RUN_LOG" REMOTE_SLEEP=1 XDG_STATE_HOME="$TMP/state" "$TARGET_DIR/remote-all" >"$TMP/remote.out" 2>"$TMP/remote.err"
end_ns="$(date +%s%N)"
elapsed_ms=$(((end_ns - start_ns) / 1000000))
((elapsed_ms < 2200))
for expected in \
  'alpha:remote:setup:' \
  'beta:remote:setup:' \
  'gamma:remote:setup:'; do
  grep -Fxq "$expected" "$RUN_LOG"
done
[[ "$(wc -l < "$RUN_LOG")" -eq 3 ]]
grep -Fq '[remote-all] [1/3] INICIANDO: remote-alpha' "$TMP/remote.out"
grep -Fq '[remote-all] [2/3] INICIANDO: remote-beta' "$TMP/remote.out"
grep -Fq '[remote-all] [3/3] INICIANDO: remote-gamma' "$TMP/remote.out"
grep -Fq '[remote-alpha] [remote-alpha] executando: ./deploy/remote/setup.sh' "$TMP/remote.out"
grep -Fq 'OK    remote-alpha' "$TMP/remote.out"
grep -Fq 'OK    remote-beta' "$TMP/remote.out"
grep -Fq 'OK    remote-gamma' "$TMP/remote.out"
grep -Fq '[remote-all] 3 OK | 0 ERRO' "$TMP/remote.out"

# Falha remota é agregada: não cancela nem impede nenhum dos outros jobs.
: > "$RUN_LOG"
set +e
RUN_LOG="$RUN_LOG" FAIL_PROJECT=beta REMOTE_SLEEP=0.1 XDG_STATE_HOME="$TMP/state" "$TARGET_DIR/remote-all" test >"$TMP/remote-fail.out" 2>"$TMP/remote-fail.err"
status=$?
set -e
[[ "$status" -eq 9 ]]
for expected in \
  'alpha:remote:test:' \
  'beta:remote:test:' \
  'gamma:remote:test:'; do
  grep -Fxq "$expected" "$RUN_LOG"
done
[[ "$(wc -l < "$RUN_LOG")" -eq 3 ]]
grep -Fq 'OK    remote-alpha' "$TMP/remote-fail.out"
grep -Fq 'ERRO  remote-beta (código 9)' "$TMP/remote-fail.out"
grep -Fq 'OK    remote-gamma' "$TMP/remote-fail.out"
grep -Fq '[remote-all] 2 OK | 1 ERRO' "$TMP/remote-fail.out"

printf 'OK: local-all paralelo; remote-all paralelo, independente, com logs prefixados e resumo agregado\n'
