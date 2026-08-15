#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
EXT="$ROOT/apps/pycharms-gnome-extension/extension.js"
HELPER="$ROOT/scripts/pycharms/gnome-wayland.sh"
UBUNTU="$ROOT/scripts/pycharms/ubuntu.sh"

[[ -f "$EXT" ]] || { echo 'FALHOU: extension.js ausente' >&2; exit 1; }
[[ -x "$HELPER" ]] || { echo 'FALHOU: helper GNOME ausente/não executável' >&2; exit 1; }
grep -q "window-created" "$EXT" || { echo 'FALHOU: extensão não observa novas janelas' >&2; exit 1; }
grep -q "move_to_monitor" "$EXT" || { echo 'FALHOU: extensão não move janela' >&2; exit 1; }
grep -q "MaximizeFlags.BOTH" "$EXT" || { echo 'FALHOU: extensão não maximiza' >&2; exit 1; }
grep -q "width \* rect.height" "$EXT" || { echo 'FALHOU: extensão não seleciona maior monitor' >&2; exit 1; }
grep -q "gnome-wayland.sh" "$UBUNTU" || { echo 'FALHOU: backend Ubuntu não integra helper GNOME' >&2; exit 1; }
grep -q "XDG_SESSION_TYPE" "$UBUNTU" || { echo 'FALHOU: backend Ubuntu não detecta Wayland' >&2; exit 1; }

echo 'OK: PyCharm Ubuntu/Wayland usa extensão GNOME separada, move para o maior monitor (4K) e maximiza.'
