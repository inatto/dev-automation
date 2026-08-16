#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
EXT="$ROOT/apps/pycharms-gnome-extension/extension.js"
HELPER="$ROOT/scripts/pycharms/gnome-wayland.sh"
UBUNTU="$ROOT/scripts/pycharms/ubuntu.sh"

[[ -f "$EXT" ]] || { echo 'FALHOU: extension.js ausente' >&2; exit 1; }
[[ -x "$HELPER" ]] || { echo 'FALHOU: helper GNOME ausente/não executável' >&2; exit 1; }
grep -q "window-created" "$EXT" || { echo 'FALHOU: extensão não observa novas janelas' >&2; exit 1; }
grep -q "change_workspace_by_index" "$EXT" || { echo 'FALHOU: extensão não move para workspace' >&2; exit 1; }
grep -q "move_to_monitor" "$EXT" || { echo 'FALHOU: extensão não move janela entre monitores' >&2; exit 1; }
grep -q 'window.maximize()' "$EXT" || { echo 'FALHOU: extensão não maximiza com API Mutter atual' >&2; exit 1; }
grep -q "width \* rect.height" "$EXT" || { echo 'FALHOU: extensão não seleciona maior monitor' >&2; exit 1; }
grep -q "workspaces.tsv" "$EXT" || { echo 'FALHOU: extensão não usa mapa projeto/workspace' >&2; exit 1; }
grep -q "batch-opening" "$EXT" || { echo 'FALHOU: extensão não bloqueia movimentação durante lote' >&2; exit 1; }
grep -q "reconcile.request" "$EXT" || { echo 'FALHOU: extensão não observa reconciliação final' >&2; exit 1; }
grep -q "PYCHARMS_STARTUP_SETTLE_SECONDS" "$UBUNTU" || { echo 'FALHOU: backend não possui janela de estabilização configurável' >&2; exit 1; }
grep -q "DESKTOPS_SCRIPT" "$UBUNTU" || { echo 'FALHOU: backend não garante workspaces antes de abrir' >&2; exit 1; }
grep -q "finish_batch_later" "$UBUNTU" || { echo 'FALHOU: backend não dispara reconciliação final após o lote' >&2; exit 1; }
grep -q 'gnome-extensions disable "$UUID"' "$HELPER" || { echo 'FALHOU: helper não recarrega extensão atualizada' >&2; exit 1; }
grep -q "gnome-wayland.sh" "$UBUNTU" || { echo 'FALHOU: backend Ubuntu não integra helper GNOME' >&2; exit 1; }
grep -q "XDG_SESSION_TYPE" "$UBUNTU" || { echo 'FALHOU: backend Ubuntu não detecta Wayland' >&2; exit 1; }
! grep -q "window.activate(global.get_current_time())" "$EXT" || { echo 'FALHOU: extensão ainda ativa janela e muda contexto do usuário' >&2; exit 1; }

echo 'OK: PyCharm Ubuntu/Wayland usa extensão GNOME separada, workspace por projeto, maior monitor 4K e maximização sem ativar a janela.'
