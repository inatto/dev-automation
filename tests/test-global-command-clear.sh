#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FAKE_BIN="$TMP/bin"
MARKER="$TMP/clear.called"
mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/clear" <<EOF_CLEAR
#!/usr/bin/env bash
printf 'clear\n' >> "$MARKER"
EOF_CLEAR
chmod +x "$FAKE_BIN/clear"

# Em execução não interativa, não deve limpar nem depender de TERM.
PATH="$FAKE_BIN:$PATH" TERM= bash "$ROOT/scripts/clear-terminal.sh"
[[ ! -e "$MARKER" ]]

# Em terminal real, limpa uma vez.
PATH="$FAKE_BIN:$PATH" TERM=xterm script -q -e -c "bash '$ROOT/scripts/clear-terminal.sh'" /dev/null >/dev/null
[[ "$(wc -l < "$MARKER")" -eq 1 ]]

# Todo comando de projeto local/remoto passa pelo runner comum e limpa antes de executar.
APP="$TMP/sample-app"
mkdir -p "$APP/deploy/remote"
cat > "$APP/deploy/remote/setup.sh" <<'EOF_SETUP'
#!/usr/bin/env bash
printf 'setup-ok\n'
EOF_SETUP
chmod +x "$APP/deploy/remote/setup.sh"
: > "$MARKER"
PATH="$FAKE_BIN:$PATH" TERM=xterm script -q -e -c "bash '$ROOT/scripts/project-command.sh' remote-sample-app '$APP' remote" /dev/null >/dev/null
[[ "$(wc -l < "$MARKER")" -eq 1 ]]

# O instalador geral injeta o mesmo helper nos comandos globais fixos.
HOME_DIR="$TMP/home"
TARGET_DIR="$HOME_DIR/.local/bin"
CODE_ROOT="$TMP/Code"
PROJECTS_FILE="$TMP/projects"
mkdir -p "$HOME_DIR" "$CODE_ROOT/orgs/sample-app/deploy/local"
: > "$HOME_DIR/.bashrc"
cat > "$CODE_ROOT/orgs/sample-app/deploy/local/setup.sh" <<'EOF_LOCAL'
#!/usr/bin/env bash
exit 0
EOF_LOCAL
chmod +x "$CODE_ROOT/orgs/sample-app/deploy/local/setup.sh"
printf 'orgs/sample-app\n' > "$PROJECTS_FILE"
HOME="$HOME_DIR" TARGET_DIR="$TARGET_DIR" CODE_ROOT="$CODE_ROOT" PROJECTS_FILE="$PROJECTS_FILE" \
  "$ROOT/deploy/local/install-commands.sh" >/dev/null

grep -Fq "bash \"$ROOT/scripts/clear-terminal.sh\"" "$TARGET_DIR/auto-code-manager"
grep -Fq "bash \"$ROOT/scripts/clear-terminal.sh\"" "$TARGET_DIR/dev-manager"
grep -Fq "bash \"$ROOT/scripts/clear-terminal.sh\"" "$TARGET_DIR/local-nginx"
# Projetos e oracle-monitor limpam via project-command, sem duplicar clear no wrapper.
grep -Fq "exec \"$ROOT/scripts/project-command.sh\"" "$TARGET_DIR/sample-app"
grep -Fq "exec \"$ROOT/scripts/project-command.sh\"" "$TARGET_DIR/oracle-monitor"

# local-all limpa uma vez; os comandos individuais internos preservam o log completo.
: > "$MARKER"
PATH="$FAKE_BIN:$PATH" TERM=xterm script -q -e -c "'$TARGET_DIR/local-all'" /dev/null >/dev/null
[[ "$(wc -l < "$MARKER")" -eq 1 ]]

printf 'OK: comandos globais limpam terminal interativo sem afetar automacao nao interativa\n'
