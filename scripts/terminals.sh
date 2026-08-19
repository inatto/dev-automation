#!/usr/bin/env bash
# Terminais em duas fases, no mesmo padrão do pycharms:
# 1ª chamada abre somente o que falta; 2ª e seguintes apenas reconciliam.
# Workspace 1 = LAZER; lrdp1/lrdp2 também ficam fora. Um terminal por projeto.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
PLACEMENT_LIB="$PROJECT_ROOT/scripts/gnome-window-placement.sh"
PROJECTS_FILE="${PROJECTS_FILE:-$PROJECT_ROOT/config/auto-code-manager.projects}"

log(){ printf '[terminals] %s\n' "$*"; }
warn(){ printf '[terminals] AVISO: %s\n' "$*" >&2; }
fail(){ printf '[terminals] ERRO: %s\n' "$*" >&2; exit 1; }

[[ -f "$PLACEMENT_LIB" ]] || fail "biblioteca GNOME ausente: $PLACEMENT_LIB"
[[ -f "$PROJECTS_FILE" ]] || fail "arquivo de projetos não encontrado: $PROJECTS_FILE"
source "$PLACEMENT_LIB"

project_count() {
  local raw line count=0
  while IFS= read -r raw || [[ -n "$raw" ]]; do
    raw="${raw%$'\r'}"
    line="${raw%%#*}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    line="${line#./}"; line="${line%/}"
    [[ -n "$line" ]] || continue
    ((count += 1))
  done < "$PROJECTS_FILE"
  printf '%d\n' "$count"
}

terminal_backend() {
  local path
  if path="$(command -v ptyxis 2>/dev/null)"; then printf 'ptyxis\t%s\n' "$path"; return 0; fi
  if path="$(command -v gnome-terminal 2>/dev/null)"; then printf 'gnome-terminal\t%s\n' "$path"; return 0; fi
  if path="$(command -v kgx 2>/dev/null)"; then printf 'kgx\t%s\n' "$path"; return 0; fi
  if path="$(command -v xdg-terminal-exec 2>/dev/null)"; then printf 'xdg-terminal-exec\t%s\n' "$path"; return 0; fi
  if path="$(command -v x-terminal-emulator 2>/dev/null)"; then printf 'x-terminal-emulator\t%s\n' "$path"; return 0; fi
  return 1
}

launch_terminal_window() {
  local backend="$1" terminal="$2" working_dir="$3"
  case "$backend" in
    ptyxis) nohup "$terminal" --new-window --working-directory="$working_dir" >/dev/null 2>&1 & ;;
    gnome-terminal) nohup "$terminal" --window --working-directory="$working_dir" >/dev/null 2>&1 & ;;
    kgx) (cd -- "$working_dir" && nohup "$terminal" >/dev/null 2>&1 &) ;;
    xdg-terminal-exec) nohup "$terminal" --dir="$working_dir" >/dev/null 2>&1 & ;;
    x-terminal-emulator) (cd -- "$working_dir" && nohup "$terminal" >/dev/null 2>&1 &) ;;
    *) return 1 ;;
  esac
}

show_diagnose() {
  local count
  count="$(project_count)"
  printf '=== TERMINALS / GNOME ===\n'
  printf 'Sessão: %s / %s\n' "${XDG_CURRENT_DESKTOP:-?}" "${XDG_SESSION_TYPE:-?}"
  printf 'Projetos: %s (workspaces 2..%s; LAZER e lrdp1/lrdp2 excluídos)\n' "$count" "$((count + 1))"
  printf 'Terminal: '; terminal_backend || printf 'nenhum terminal compatível encontrado\n'
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

count="$(project_count)"
(( count > 0 )) || fail 'nenhum projeto configurado para receber terminal.'
request_fields="count=$count"

case "${1:-}" in
  --diagnose|diagnose) show_diagnose; exit 0 ;;
  --reset|reset)
    gnome_placement_prepare terminals reset "$request_fields" || fail 'não foi possível preparar a limpeza dos terminais de projeto.'
    closed="$(gnome_placement_ready_field managed 2>/dev/null || printf '0')"
    log "RESET solicitado. Lote gerenciado limpo; terminais dos workspaces de projeto serão fechados."
    exit 0
    ;;
  --help|-h|help)
    printf 'Uso: terminals | terminals --reset | terminals --diagnose\n'
    printf 'Fluxo: 1ª chamada abre somente terminais faltantes; 2ª chamada distribui um por projeto no monitor direito. Chamadas seguintes só reconciliam.\n'
    printf 'LAZER (workspace 1) e lrdp1/lrdp2 não recebem terminal automático.\n'
    exit 0
    ;;
  '') ;;
  *) fail "opção inválida: $1" ;;
esac

# Sempre consulta primeiro o estado real das janelas; não decide por arquivo de
# marker do shell. Assim repetir o comando não cria novo lote por acidente.
gnome_placement_prepare terminals status "$request_fields" || fail 'não foi possível consultar o estado dos terminais no GNOME/Wayland.'
managed="$(gnome_placement_ready_field managed 2>/dev/null || true)"
missing="$(gnome_placement_ready_field missing 2>/dev/null || true)"
untracked="$(gnome_placement_ready_field untracked 2>/dev/null || true)"
[[ "$managed" =~ ^[0-9]+$ && "$missing" =~ ^[0-9]+$ && "$untracked" =~ ^[0-9]+$ ]] || \
  fail "estado inválido retornado pelo GNOME: managed=${managed:-?} missing=${missing:-?} untracked=${untracked:-?}"

if (( untracked > 0 )); then
  warn "$untracked terminal(is) extra(s) já existente(s) nos workspaces de projeto não pertencem ao lote gerenciado e serão preservados. Use 'terminals --reset' somente se quiser limpar esses terminais."
fi

if (( missing > 0 )); then
  IFS=$'\t' read -r terminal_kind terminal < <(terminal_backend) || fail 'nenhum terminal compatível encontrado. Rode: terminals --diagnose'
  gnome_placement_prepare terminals open "$request_fields" || fail 'não foi possível preparar a fase de abertura.'
  missing="$(gnome_placement_ready_field missing 2>/dev/null || true)"
  [[ "$missing" =~ ^[0-9]+$ ]] || fail "quantidade de terminais faltantes inválida: ${missing:-vazio}"

  log 'FASE: ABERTURA'
  log "Terminal: $terminal_kind -> $terminal"
  log "ABERTURA: $missing terminal(is) faltando para $count projeto(s). Nesta chamada NÃO haverá movimentação entre workspaces."
  working_dir="$(pwd -P)"
  for ((i=1; i<=missing; i++)); do
    launch_terminal_window "$terminal_kind" "$terminal" "$working_dir" || fail "falha ao abrir terminal via $terminal_kind"
    sleep 0.10
  done

  timeout_tenths=$(( missing * 20 ))
  (( timeout_tenths < 200 )) && timeout_tenths=200
  if ! gnome_placement_wait_complete terminals "$timeout_tenths"; then
    fail "o GNOME não confirmou a captura dos $missing terminais novos. Rode: terminals --diagnose"
  fi

  log "FASE ABERTURA CONCLUÍDA: $missing terminal(is) novo(s) capturado(s), sem maximizar e sem distribuição."
  log 'PRÓXIMA CHAMADA: terminals fará somente a MOVIMENTAÇÃO, um terminal por projeto no monitor direito.'
  exit 0
fi

log 'FASE: MOVIMENTAÇÃO'
log "ABERTURA: 0. Os $managed/$count terminais necessários já existem; nenhuma nova janela será criada."
gnome_placement_prepare terminals reconcile "$request_fields" || fail 'não foi possível preparar a reconciliação dos terminais.'
if ! gnome_placement_wait_complete terminals 200; then
  fail 'o GNOME não confirmou a movimentação completa. Rode: terminals --diagnose'
fi
log "MOVIMENTAÇÃO CONCLUÍDA: 1 terminal por projeto, workspaces 2..$((count + 1)), monitor direito, sem maximizar."
log 'Idempotência: próximas chamadas apenas reconciliam; não abrem outro lote enquanto os terminais gerenciados existirem.'
