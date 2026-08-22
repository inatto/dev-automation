#!/usr/bin/env bash
# Terminais em duas fases, no mesmo padrão operacional do pycharms:
# 1ª chamada abre somente o que falta, UM POR VEZ e com confirmação do GNOME;
# 2ª e seguintes apenas reconciliam workspace/monitor/maximização.
# Workspace 1 = LAZER; lrdp1/lrdp2 ficam fora. Um terminal por projeto.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
PLACEMENT_LIB="$PROJECT_ROOT/scripts/gnome-window-placement.sh"
PROJECTS_FILE="${PROJECTS_FILE:-$PROJECT_ROOT/config/auto-code-manager.projects}"
CODE_ROOT="${CODE_ROOT:-/home/daniel/Code}"
STATE_ROOT="${AUTO_CODE_STATE_DIR:-$HOME/.local/state/dev-automation}"
STATE_DIR="$STATE_ROOT/desktops"
OPEN_SETTLE_SECONDS="${TERMINALS_OPEN_SETTLE_SECONDS:-2}"
CAPTURE_TIMEOUT_TENTHS="${TERMINALS_CAPTURE_TIMEOUT_TENTHS:-200}"

log(){ printf '[terminals] %s\n' "$*"; }
warn(){ printf '[terminals] AVISO: %s\n' "$*" >&2; }
fail(){ printf '[terminals] ERRO: %s\n' "$*" >&2; exit 1; }

[[ -f "$PLACEMENT_LIB" ]] || fail "biblioteca GNOME ausente: $PLACEMENT_LIB"
[[ -f "$PROJECTS_FILE" ]] || fail "arquivo de projetos não encontrado: $PROJECTS_FILE"
source "$PLACEMENT_LIB"

project_entries=()
project_dirs=()
load_projects() {
  local raw line path
  project_entries=()
  project_dirs=()
  while IFS= read -r raw || [[ -n "$raw" ]]; do
    raw="${raw%$'\r'}"
    line="${raw%%#*}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    line="${line#./}"
    line="${line%/}"
    [[ -n "$line" && "${line,,}" != *.zip ]] || continue

    project_entries+=("$line")
    path="$CODE_ROOT/$line"
    if [[ -d "$path" ]]; then
      project_dirs+=("$(cd -- "$path" && pwd -P)")
    else
      project_dirs+=("$CODE_ROOT")
    fi
  done < "$PROJECTS_FILE"
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

acquire_lock() {
  mkdir -p "$STATE_DIR"
  if command -v flock >/dev/null 2>&1; then
    exec 9>"$STATE_DIR/terminals.lock"
    flock -w 5 9 || fail 'já existe outra execução de terminals em andamento; aguarde terminar.'
    return 0
  fi

  local lock_dir="$STATE_DIR/terminals.lock.d"
  mkdir "$lock_dir" 2>/dev/null || fail 'já existe outra execução de terminals em andamento; aguarde terminar.'
  trap 'rmdir "$lock_dir" 2>/dev/null || true' EXIT
}

# O reset usa apenas o protocolo estável action=reset. Assim ele continua
# conseguindo limpar a bagunça produzida pela v47 mesmo antes do novo
# controlador ser carregado pela sessão GNOME.
legacy_compatible_reset() {
  gnome_placement_supported || fail 'terminals --reset requer GNOME/Wayland.'
  local info request ready result token tmp attempt line controller_rc=0

  # Copia primeiro o controlador novo para o disco. Se a sessão ainda estiver
  # usando a versão anterior, o reset abaixo continua falando o protocolo v9 e
  # funciona; no próximo login o GNOME já carrega a v10.
  "$PROJECT_ROOT/scripts/desktops.sh" --ensure-controller >/dev/null || controller_rc=$?
  if (( controller_rc != 0 && controller_rc != 75 )); then
    warn 'não foi possível preparar o controlador novo no disco; tentando ao menos limpar o lote atual.'
  fi
  info="$(gnome-extensions info workspace-name-osd@dev-automation 2>/dev/null || true)"
  grep -qiE '^[[:space:]]*State:[[:space:]]*ACTIVE[[:space:]]*$' <<<"$info" || \
    fail 'controlador GNOME não está ACTIVE; não vou fingir que fechei as janelas.'

  mkdir -p "$STATE_DIR"
  request="$STATE_DIR/terminals.request"
  ready="$STATE_DIR/terminals.ready"
  result="$STATE_DIR/terminals.result"
  token="$(date +%s%N)-$$-$RANDOM"
  tmp="$request.tmp.$$"
  rm -f -- "$ready" "$result"
  printf '%s\taction=reset\tcount=%s\n' "$token" "${#project_entries[@]}" > "$tmp"
  mv -f -- "$tmp" "$request"

  for ((attempt=0; attempt<100; attempt++)); do
    if [[ -s "$ready" ]]; then
      line="$(cat "$ready" 2>/dev/null || true)"
      if [[ "${line%%$'\t'*}" == "$token" ]]; then
        log 'RESET confirmado: fechando o lote gerenciado e todos os terminais extras nos workspaces de projeto.'
        return 0
      fi
    fi
    sleep 0.1
  done
  fail 'o controlador GNOME não confirmou o reset.'
}

show_diagnose() {
  local count="${#project_entries[@]}"
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
  if [[ -s "$STATE_DIR/extension.ready" ]]; then
    printf 'Runtime:\n'
    sed 's/^/  /' "$STATE_DIR/extension.ready"
  fi
}

load_projects
count="${#project_entries[@]}"
(( count > 0 )) || fail 'nenhum projeto configurado para receber terminal.'

case "${1:-}" in
  --diagnose|diagnose) show_diagnose; exit 0 ;;
  --reset|reset)
    acquire_lock
    legacy_compatible_reset
    exit 0
    ;;
  --help|-h|help)
    printf 'Uso: terminals | terminals --reset | terminals --diagnose\n'
    printf 'Fluxo: 1ª chamada abre exatamente os terminais faltantes, um por vez; 2ª chamada distribui e maximiza um por projeto no monitor direito.\n'
    printf 'LAZER (workspace 1) e lrdp1/lrdp2 não recebem terminal automático.\n'
    exit 0
    ;;
  '') ;;
  *) fail "opção inválida: $1" ;;
esac

acquire_lock
request_fields="count=$count"

# Consulta sempre o estado real. Repetir o comando não cria lote novo quando
# os terminais gerenciados ainda existem.
gnome_placement_prepare terminals status "$request_fields" || \
  fail 'não foi possível consultar o estado dos terminais no GNOME/Wayland.'
managed="$(gnome_placement_ready_field managed 2>/dev/null || true)"
missing="$(gnome_placement_ready_field missing 2>/dev/null || true)"
untracked="$(gnome_placement_ready_field untracked 2>/dev/null || printf '0')"
overflow="$(gnome_placement_ready_field overflow 2>/dev/null || printf '0')"
[[ "$managed" =~ ^[0-9]+$ && "$missing" =~ ^[0-9]+$ && "$untracked" =~ ^[0-9]+$ && "$overflow" =~ ^[0-9]+$ ]] || \
  fail "estado inválido retornado pelo GNOME: managed=${managed:-?} missing=${missing:-?} untracked=${untracked:-?} overflow=${overflow:-?}"

if (( untracked > 0 )); then
  warn "$untracked terminal(is) não gerenciado(s) já existe(m) nos workspaces de projeto; serão preservados. Para limpar tudo e recomeçar: terminals --reset"
fi
if (( overflow > 0 )); then
  warn "$overflow janela(s) excedente(s) do lote anterior será(ão) fechada(s) na fase de movimentação."
fi

if (( missing > 0 )); then
  IFS=$'\t' read -r terminal_kind terminal < <(terminal_backend) || \
    fail 'nenhum terminal compatível encontrado. Rode: terminals --diagnose'

  gnome_placement_prepare terminals open "$request_fields" || fail 'não foi possível preparar a fase de abertura.'
  missing="$(gnome_placement_ready_field missing 2>/dev/null || true)"
  managed="$(gnome_placement_ready_field managed 2>/dev/null || true)"
  [[ "$missing" =~ ^[0-9]+$ && "$managed" =~ ^[0-9]+$ ]] || \
    fail "quantidades inválidas para abertura: managed=${managed:-?} missing=${missing:-?}"

  log 'FASE: ABERTURA'
  log "Terminal: $terminal_kind -> $terminal"
  log "ABERTURA: $missing terminal(is) faltando para $count projeto(s). Abrindo UM POR VEZ e esperando confirmação antes do próximo."
  log 'Nesta chamada NÃO haverá movimentação entre workspaces.'

  captured=0
  while (( captured < missing )); do
    project_index=$((managed + captured))
    (( project_index < count )) || project_index=$((count - 1))
    project_name="${project_entries[$project_index]}"
    working_dir="${project_dirs[$project_index]}"

    previous="$captured"
    log "ABRINDO $((managed + previous + 1))/$count: $project_name"
    launch_terminal_window "$terminal_kind" "$terminal" "$working_dir" || \
      fail "falha ao abrir terminal via $terminal_kind"

    if ! gnome_placement_wait_min terminals placed "$((previous + 1))" "$CAPTURE_TIMEOUT_TENTHS"; then
      fail "o GNOME não confirmou a nova janela de terminal para '$project_name'; parei imediatamente para não disparar duplicatas."
    fi

    captured="$(gnome_placement_result_field terminals placed 2>/dev/null || true)"
    [[ "$captured" =~ ^[0-9]+$ ]] || fail "captura inválida retornada pelo GNOME: ${captured:-vazio}"
    (( captured > missing )) && captured="$missing"
    sleep 0.15
  done

  if ! gnome_placement_wait_complete terminals "$CAPTURE_TIMEOUT_TENTHS"; then
    fail "o GNOME não confirmou a captura dos $missing terminais novos. Rode: terminals --diagnose"
  fi

  [[ "$OPEN_SETTLE_SECONDS" =~ ^[0-9]+([.][0-9]+)?$ ]] || OPEN_SETTLE_SECONDS=2
  sleep "$OPEN_SETTLE_SECONDS"
  log "FASE ABERTURA CONCLUÍDA: $missing terminal(is) novo(s) capturado(s), sem distribuição."
  log 'PRÓXIMA CHAMADA: terminals fará somente a MOVIMENTAÇÃO e MAXIMIZAÇÃO, um terminal por projeto no monitor direito.'
  exit 0
fi

log 'FASE: MOVIMENTAÇÃO'
log "ABERTURA: 0. Os $managed/$count terminais necessários já existem; nenhuma nova janela será criada."
gnome_placement_prepare terminals reconcile "$request_fields" || fail 'não foi possível preparar a reconciliação dos terminais.'
if ! gnome_placement_wait_complete terminals 200; then
  fail 'o GNOME não confirmou a movimentação completa. Rode: terminals --diagnose'
fi
log "MOVIMENTAÇÃO CONCLUÍDA: 1 terminal por projeto, workspaces 2..$((count + 1)), monitor direito e MAXIMIZADO."
log 'Idempotência: próximas chamadas apenas reconciliam; não abrem outro lote enquanto os terminais gerenciados existirem.'
