#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
PY="$ROOT/scripts/dev-manager-tui.py"
TMP="$(mktemp -d /tmp/dev-manager-ncurses-XXXXXX)"
trap 'rm -rf -- "$TMP"' EXIT

python3 -m py_compile "$PY"
command -v script >/dev/null 2>&1 || {
  echo "SKIP: util-linux script não instalado"
  exit 0
}

cat > "$TMP/fake-manager.sh" <<'FAKE'
#!/usr/bin/env bash
echo 'Auto Code Manager - ncurses-smoke'
echo 'Downloads: /tmp'
echo 'Modo: light'
echo 'IDLE leve: aguardando alterações'
sleep 1.5
FAKE
chmod +x "$TMP/fake-manager.sh"

# Smoke em PTTY real + alternância de tema em runtime pelo atalho T.
(
  sleep 0.35
  printf 't'
  sleep 0.35
  printf 'q'
) | TERM=xterm-256color DEV_MANAGER_TUI_THEME_FILE="$TMP/theme" timeout 8 \
  script -qfec "python3 '$PY' '$TMP/fake-manager.sh'" "$TMP/typescript" \
  >/dev/null 2>"$TMP/stderr" || true

[ ! -s "$TMP/stderr" ] || {
  cat "$TMP/stderr" >&2
  exit 1
}

python3 - "$TMP/typescript" "$TMP/theme" "$PY" <<'PY'
from pathlib import Path
import sys

b = Path(sys.argv[1]).read_bytes()
theme = Path(sys.argv[2]).read_text(encoding="ascii").strip()
source = Path(sys.argv[3]).read_text(encoding="utf-8")

assert b"Traceback" not in b, "ncurses gerou traceback"
assert b"\x1b(0" in b, "ACS/line-drawing nativo não foi ativado"
assert b"DEV AUTOMATION :: CLIPPER / NCURSES" in b, "painel principal não foi desenhado"
assert b"DAY / BASIC" in b, "tema BASIC não foi desenhado"
assert b"DARK / MATRIX" in b, "atalho T não alternou para MATRIX"
assert theme == "matrix", "tema selecionado não foi persistido"
assert "F2/T: tema" in source, "atalho de tema não está documentado no rodapé"
assert "if self.full_redraw:" in source, "redesenho completo não está protegido por dirty/full redraw"
PY

# Reinício deve recuperar o tema salvo.
TERM=xterm-256color DEV_MANAGER_TUI_THEME_FILE="$TMP/theme" timeout 8 \
  script -qfec "python3 '$PY' '$TMP/fake-manager.sh'" "$TMP/typescript-restart" \
  </dev/null >/dev/null 2>"$TMP/stderr-restart" || true

[ ! -s "$TMP/stderr-restart" ] || {
  cat "$TMP/stderr-restart" >&2
  exit 1
}
grep -a -q 'DARK / MATRIX' "$TMP/typescript-restart"

echo "OK: ncurses ACS + BASIC/MATRIX + atalho T/F2 + persistência + refresh sem clear global contínuo"
