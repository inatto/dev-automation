#!/usr/bin/env bash
# Abre exatamente um terminal NOVO em cada workspace de PROJETO do GNOME
# (workspace 2 em diante), sempre no monitor horizontalmente mais à direita.
# Workspace 1 = LAZER e é preservado. O workspace atual permanece ativo.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
PLACEMENT_LIB="$PROJECT_ROOT/scripts/gnome-window-placement.sh"

log(){ printf '[terminals] %s\n' "$*"; }
fail(){ printf '[terminals] ERRO: %s\n' "$*" >&2; exit 1; }

[[ -f "$PLACEMENT_LIB" ]] || fail "biblioteca GNOME ausente: $PLACEMENT_LIB"
source "$PLACEMENT_LIB"

terminal_backend() {
  local path
  # Ubuntu 26.04 normalmente usa Ptyxis; não exigir gnome-terminal foi a
  # correção essencial aqui. Preferimos launchers que garantem NOVA janela.
  if path="$(command -v ptyxis 2>/dev/null)"; then
    printf 'ptyxis\t%s\n' "$path"
    return 0
  fi
  if path="$(command -v gnome-terminal 2>/dev/null)"; then
    printf 'gnome-terminal\t%s\n' "$path"
    return 0
  fi
  if path="$(command -v kgx 2>/dev/null)"; then
    printf 'kgx\t%s\n' "$path"
    return 0
  fi
  if path="$(command -v xdg-terminal-exec 2>/dev/null)"; then
    printf 'xdg-terminal-exec\t%s\n' "$path"
    return 0
  fi
  if path="$(command -v x-terminal-emulator 2>/dev/null)"; then
    printf 'x-terminal-emulator\t%s\n' "$path"
    return 0
  fi
  return 1
}

launch_terminal_window() {
  local backend="$1" terminal="$2" working_dir="$3"
  case "$backend" in
    ptyxis)
      nohup "$terminal" --new-window --working-directory="$working_dir" >/dev/null 2>&1 &
      ;;
    gnome-terminal)
      nohup "$terminal" --window --working-directory="$working_dir" >/dev/null 2>&1 &
      ;;
    kgx)
      # GNOME Console abre uma nova janela por processo/invocação. Herdar cwd é
      # suficiente; versões que aceitam --working-directory podem variar.
      (cd -- "$working_dir" && nohup "$terminal" >/dev/null 2>&1 &)
      ;;
    xdg-terminal-exec)
      # Interface padrão presente no Ubuntu 26.04; --dir é parte do utilitário.
      nohup "$terminal" --dir="$working_dir" >/dev/null 2>&1 &
      ;;
    x-terminal-emulator)
      (cd -- "$working_dir" && nohup "$terminal" >/dev/null 2>&1 &)
      ;;
    *) return 1 ;;
  esac
}

show_diagnose() {
  printf '=== TERMINALS / GNOME ===\n'
  printf 'Sessão: %s / %s\n' "${XDG_CURRENT_DESKTOP:-?}" "${XDG_SESSION_TYPE:-?}"
  printf 'Terminal: '
  terminal_backend || printf 'nenhum terminal compatível encontrado\n'
  if command -v xdg-terminal-exec >/dev/null 2>&1; then
    printf 'Terminal XDG preferido: ' ; xdg-terminal-exec --print-id 2>/dev/null || true
  fi
  printf 'Monitores:\n'
  command -v xrandr >/dev/null 2>&1 && xrandr --listmonitors 2>/dev/null || true
  printf 'Controlador: '
  if command -v gnome-extensions >/dev/null 2>&1; then
    gnome-extensions info workspace-name-osd@dev-automation 2>/dev/null | grep -E 'State:|Version:' | tr '\n' ' ' || true
    printf '\n'
  else
    printf 'gnome-extensions ausente\n'
  fi
}

case "${1:-}" in
  --diagnose|diagnose) show_diagnose; exit 0 ;;
  --help|-h|help)
    printf 'Uso: terminals | terminals --diagnose\n'
    printf 'Ação: abre um terminal NOVO em cada workspace de projeto (2+), no monitor mais à direita, sem maximizar.\n'
    exit 0
    ;;
  '') ;;
  *) fail "opção inválida: $1" ;;
esac

IFS=$'\t' read -r terminal_kind terminal < <(terminal_backend) || fail 'nenhum terminal compatível encontrado. Rode: terminals --diagnose'
gnome_placement_prepare terminals || fail 'não foi possível preparar a distribuição dos terminais no GNOME/Wayland.'
count="$(gnome_placement_ready_field count 2>/dev/null || true)"
[[ "$count" =~ ^[0-9]+$ ]] || fail "quantidade de workspaces de projeto inválida retornada pelo GNOME: ${count:-vazio}"
if (( count == 0 )); then
  log "Nenhum workspace de projeto encontrado; workspace 1 (LAZER) preservado."
  exit 0
fi

log "Terminal: $terminal_kind -> $terminal"
log "Abrindo $count terminal(is) novo(s): um por workspace de projeto (2+), todos no monitor mais à direita (HDMI-3 no layout diagnosticado), sem maximizar."
working_dir="$(pwd -P)"
for ((i=1; i<=count; i++)); do
  launch_terminal_window "$terminal_kind" "$terminal" "$working_dir" || fail "falha ao abrir terminal via $terminal_kind"
  sleep 0.08
done

timeout_tenths=$(( count * 15 ))
(( timeout_tenths < 200 )) && timeout_tenths=200
if ! gnome_placement_wait_complete terminals "$timeout_tenths"; then
  fail "o GNOME não confirmou a distribuição completa dos $count terminais. Rode: terminals --diagnose"
fi

log "Concluído: $count/$count terminais distribuídos nos workspaces de projeto, no monitor direito, sem maximizar e sem trocar seu workspace atual."
