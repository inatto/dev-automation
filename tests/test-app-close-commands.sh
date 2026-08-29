#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
INSTALLER="$ROOT/deploy/local/install-commands.sh"

for script in session-app-close files-close chromes-close pycharms-close; do
  bash -n "$ROOT/scripts/$script.sh"
done
bash -n "$INSTALLER"

grep -Fq 'CHROMES_CLOSE_SOURCE="$PROJECT_ROOT/scripts/chromes-close.sh"' "$INSTALLER"
grep -Fq 'FILES_CLOSE_SOURCE="$PROJECT_ROOT/scripts/files-close.sh"' "$INSTALLER"
grep -Fq 'PYCHARMS_CLOSE_SOURCE="$PROJECT_ROOT/scripts/pycharms-close.sh"' "$INSTALLER"
grep -Fq 'chromes chromes-all chromes-close files files-all files-close terminals terminals-close' "$INSTALLER"
grep -Fq 'pycharms pycharms-close phpstorm-dev' "$INSTALLER"

grep -Fq -- '--type=*' "$ROOT/scripts/session-app-close.sh"
grep -Fq 'WAYLAND_DISPLAY' "$ROOT/scripts/session-app-close.sh"
grep -Fq 'XDG_SESSION_ID' "$ROOT/scripts/session-app-close.sh"
grep -Fq 'exec bash "$SCRIPT_DIR/pycharms.sh" --close' "$ROOT/scripts/pycharms-close.sh"

[[ "$(bash "$ROOT/scripts/files-close.sh" --help | head -n1)" == 'Uso: files-close' ]]
[[ "$(bash "$ROOT/scripts/chromes-close.sh" --help | head -n1)" == 'Uso: chromes-close' ]]
[[ "$(bash "$ROOT/scripts/pycharms-close.sh" --help | head -n1)" == 'Uso: pycharms-close' ]]

printf 'ok: comandos files-close, chromes-close e pycharms-close instaláveis e seguros\n'

TMP="$(mktemp -d /tmp/app-close-commands-XXXXXX)"
main_pid=''
renderer_pid=''
files_pid=''
cleanup() {
  for pid in "$main_pid" "$renderer_pid" "$files_pid"; do
    if [[ -n "$pid" ]]; then
      kill -KILL "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
    fi
  done
  rm -rf -- "$TMP"
}
trap cleanup EXIT
mkdir -p "$TMP/bin" "$TMP/proc"
cp /bin/sleep "$TMP/bin/chrome"
cp /bin/sleep "$TMP/bin/nautilus"

WAYLAND_DISPLAY=wayland-test "$TMP/bin/chrome" 30 & main_pid=$!
WAYLAND_DISPLAY=wayland-test "$TMP/bin/chrome" 30 & renderer_pid=$!
WAYLAND_DISPLAY=wayland-test "$TMP/bin/nautilus" 30 & files_pid=$!

fake_proc_entry() {
  local pid="$1" exe="$2" cmdline="$3"
  mkdir -p "$TMP/proc/$pid"
  printf 'Name:\ttest\nUid:\t%s\t%s\t%s\t%s\n' "$UID" "$UID" "$UID" "$UID" > "$TMP/proc/$pid/status"
  printf 'WAYLAND_DISPLAY=wayland-test\0XDG_SESSION_ID=test-session\0' > "$TMP/proc/$pid/environ"
  printf '%b' "$cmdline" > "$TMP/proc/$pid/cmdline"
  ln -s "$exe" "$TMP/proc/$pid/exe"
}

fake_proc_entry "$main_pid" "$TMP/bin/chrome" "$TMP/bin/chrome\00030\000"
fake_proc_entry "$renderer_pid" "$TMP/bin/chrome" "$TMP/bin/chrome\000--type=renderer\000"
fake_proc_entry "$files_pid" "$TMP/bin/nautilus" "$TMP/bin/nautilus\00030\000"

wait_dead() {
  local pid="$1" attempt stat
  for ((attempt=0; attempt<40; attempt++)); do
    if ! kill -0 "$pid" 2>/dev/null; then
      return 0
    fi
    stat="$(ps -o stat= -p "$pid" 2>/dev/null | tr -d '[:space:]' || true)"
    if [[ "$stat" == Z* ]]; then
      wait "$pid" 2>/dev/null || true
      return 0
    fi
    sleep 0.05
  done
  return 1
}

WAYLAND_DISPLAY=wayland-test XDG_SESSION_ID=test-session \
APP_CLOSE_PROC_ROOT="$TMP/proc" APP_CLOSE_WAIT_ATTEMPTS=0 \
  bash "$ROOT/scripts/chromes-close.sh" >/dev/null 2>&1
wait_dead "$main_pid"
kill -0 "$renderer_pid" 2>/dev/null

WAYLAND_DISPLAY=wayland-test XDG_SESSION_ID=test-session \
APP_CLOSE_PROC_ROOT="$TMP/proc" APP_CLOSE_WAIT_ATTEMPTS=0 \
  bash "$ROOT/scripts/files-close.sh" >/dev/null 2>&1
wait_dead "$files_pid"
kill -0 "$renderer_pid" 2>/dev/null

printf 'ok: seleção funcional fecha processos principais e preserva renderer Chrome\n'
