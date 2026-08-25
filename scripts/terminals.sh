#!/usr/bin/env bash
# Mantém exatamente um terminal por projeto no workspace correspondente.
# Idempotente: reaproveita terminais existentes pela pasta do projeto, abre
# somente os faltantes e reconcilia workspace/monitor/maximização na mesma chamada.
# Workspace 1 = LAZER; projetos começam no workspace 2; lrdp1/lrdp2 ficam no final.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
# shellcheck source=lib/project-config.sh
source "$PROJECT_ROOT/scripts/lib/project-config.sh"
PLACEMENT_LIB="$PROJECT_ROOT/scripts/gnome-window-placement.sh"
PROJECTS_FILE="${PROJECTS_FILE:-$(dev_projects_file "$PROJECT_ROOT")}"
CODE_ROOT="${CODE_ROOT:-/home/daniel/Code}"
STATE_ROOT="${AUTO_CODE_STATE_DIR:-$HOME/.local/state/dev-automation}"
STATE_DIR="$STATE_ROOT/desktops"
CAPTURE_TIMEOUT_TENTHS="${TERMINALS_CAPTURE_TIMEOUT_TENTHS:-200}"
PROJECTS_SIGNATURE_FILE="$STATE_DIR/terminals.projects.sha256"
PROJECTS_MANIFEST_FILE="$STATE_DIR/terminals.projects.tsv"
TERMINALS_BATCH_FILE="$STATE_DIR/terminals.batch"

log(){ printf '[terminals] %s\n' "$*"; }
warn(){ printf '[terminals] AVISO: %s\n' "$*" >&2; }
fail(){ printf '[terminals] ERRO: %s\n' "$*" >&2; exit 1; }

[[ -f "$PLACEMENT_LIB" ]] || fail "biblioteca GNOME ausente: $PLACEMENT_LIB"
[[ -f "$PROJECTS_FILE" ]] || fail "arquivo de projetos não encontrado: $PROJECTS_FILE"
# shellcheck source=gnome-window-placement.sh
source "$PLACEMENT_LIB"

project_entries=()
project_dirs=()
project_match_dirs=()

load_projects() {
  local raw line path canonical
  project_entries=()
  project_dirs=()
  project_match_dirs=()
  while IFS= read -r raw || [[ -n "$raw" ]]; do
    raw="${raw%$'\r'}"
    line="${raw%%#*}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    line="${line#./}"
    line="${line%/}"
    [[ -n "$line" && "${line,,}" != *.zip ]] || continue

    path="$CODE_ROOT/$line"
    project_entries+=("$line")
    if [[ -d "$path" ]]; then
      canonical="$(cd -- "$path" && pwd -P)"
      project_dirs+=("$canonical")
      project_match_dirs+=("$canonical")
    else
      # Mantém a identidade prevista para diagnóstico, mas não inventa outro cwd.
      project_dirs+=("$path")
      project_match_dirs+=("$path")
    fi
  done < "$PROJECTS_FILE"

  # lrdp1/lrdp2 não possuem uma pasta de projeto própria. Continuam recebendo
  # terminais no HOME e são identificados pelo vínculo persistido do controlador.
  project_entries+=("lrdp1" "lrdp2")
  project_dirs+=("$HOME" "$HOME")
  project_match_dirs+=("" "")
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
  [[ -d "$working_dir" ]] || return 2
  case "$backend" in
    ptyxis) nohup "$terminal" --new-window --working-directory="$working_dir" >/dev/null 2>&1 & ;;
    gnome-terminal) nohup "$terminal" --window --working-directory="$working_dir" >/dev/null 2>&1 & ;;
    kgx) (cd -- "$working_dir" && nohup "$terminal" >/dev/null 2>&1 &) ;;
    xdg-terminal-exec) nohup "$terminal" --dir="$working_dir" >/dev/null 2>&1 & ;;
    x-terminal-emulator) (cd -- "$working_dir" && nohup "$terminal" >/dev/null 2>&1 &) ;;
    *) return 1 ;;
  esac
}

current_projects_signature() {
  local i
  for i in "${!project_entries[@]}"; do
    printf '%s\t%s\0' "${project_entries[$i]}" "${project_match_dirs[$i]}"
  done | sha256sum | awk '{print $1}'
}

persist_projects_signature() {
  local signature="$1" tmp
  mkdir -p "$STATE_DIR"
  tmp="$PROJECTS_SIGNATURE_FILE.tmp.$$"
  printf '%s\n' "$signature" > "$tmp"
  mv -f -- "$tmp" "$PROJECTS_SIGNATURE_FILE"
}

write_projects_manifest() {
  local tmp i path
  mkdir -p "$STATE_DIR"
  tmp="$PROJECTS_MANIFEST_FILE.tmp.$$"
  : > "$tmp"
  for i in "${!project_entries[@]}"; do
    path="${project_match_dirs[$i]}"
    [[ -n "$path" ]] || path='-'
    printf '%s\t%s\t%s\n' "$i" "${project_entries[$i]}" "$path" >> "$tmp"
  done
  mv -f -- "$tmp" "$PROJECTS_MANIFEST_FILE"
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

legacy_compatible_reset() {
  gnome_placement_supported || fail 'terminals --reset requer GNOME/Wayland.'
  gnome_placement_prepare terminals reset "count=$count" || \
    fail 'não foi possível solicitar o reset dos terminais.'
  gnome_placement_wait_complete terminals 120 || \
    fail 'o GNOME não confirmou o reset dos terminais.'
  rm -f -- "$PROJECTS_SIGNATURE_FILE" "$PROJECTS_MANIFEST_FILE"
}

show_diagnose() {
  local count_local="${#project_entries[@]}" i
  printf '=== TERMINALS / GNOME ===\n'
  printf 'Sessão: %s / %s\n' "${XDG_CURRENT_DESKTOP:-?}" "${XDG_SESSION_TYPE:-?}"
  printf 'Destinos: %s (workspaces 2..%s; LAZER excluído)\n' "$count_local" "$((count_local + 1))"
  printf 'Terminal: '; terminal_backend || printf 'nenhum terminal compatível encontrado\n'
  printf 'Projetos / pastas:\n'
  for i in "${!project_entries[@]}"; do
    printf '  %2d -> %-28s  %s\n' "$((i + 2))" "${project_entries[$i]}" "${project_dirs[$i]}"
  done
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
  if [[ -s "$PROJECTS_MANIFEST_FILE" ]]; then
    printf 'Manifesto de identidade:\n'
    sed 's/^/  /' "$PROJECTS_MANIFEST_FILE"
  fi
}

parse_missing_indices() {
  local raw="$1" item
  missing_indices=()
  [[ -n "$raw" ]] || return 0
  IFS=',' read -ra _parts <<< "$raw"
  for item in "${_parts[@]}"; do
    [[ "$item" =~ ^[0-9]+$ ]] || continue
    (( item < count )) || continue
    missing_indices+=("$item")
  done
}

load_projects
count="${#project_entries[@]}"
(( count > 2 )) || fail 'nenhum projeto configurado para receber terminal.'

case "${1:-}" in
  --diagnose|diagnose)
    write_projects_manifest
    show_diagnose
    exit 0
    ;;
  --reset|reset)
    acquire_lock
    write_projects_manifest
    legacy_compatible_reset
    exit 0
    ;;
  --help|-h|help)
    printf 'Uso: terminals | terminals --reset | terminals --diagnose\n'
    printf 'Idempotente: reaproveita terminais pela pasta atual, abre somente os faltantes e move todos para o workspace correto na mesma chamada.\n'
    printf 'LAZER (workspace 1) não recebe terminal automático; lrdp1/lrdp2 recebem os dois últimos.\n'
    exit 0
    ;;
  '') ;;
  *) fail "opção inválida: $1" ;;
esac

acquire_lock
write_projects_manifest
projects_signature="$(current_projects_signature)"
request_fields="count=$count"

# 1) Descobre o estado REAL. O controlador prioriza a pasta exibida no título /
# cwd do terminal, e usa o lote persistido apenas como fallback para lrdp1/lrdp2
# ou terminais cujo backend não exponha a pasta.
gnome_placement_prepare terminals status "$request_fields" || \
  fail 'não foi possível consultar os terminais no GNOME/Wayland.'
controller_count="$(gnome_placement_ready_field count 2>/dev/null || true)"
managed="$(gnome_placement_ready_field managed 2>/dev/null || true)"
missing="$(gnome_placement_ready_field missing 2>/dev/null || true)"
missing_raw="$(gnome_placement_ready_field missing_indices 2>/dev/null || true)"
untracked="$(gnome_placement_ready_field untracked 2>/dev/null || printf '0')"
[[ "$controller_count" =~ ^[0-9]+$ && "$managed" =~ ^[0-9]+$ && "$missing" =~ ^[0-9]+$ && "$untracked" =~ ^[0-9]+$ ]] || \
  fail "estado inválido retornado pelo GNOME: count=${controller_count:-?} managed=${managed:-?} missing=${missing:-?} untracked=${untracked:-?}"
(( controller_count == count )) || \
  fail "GNOME tem espaço para $controller_count/$count destinos. Rode 'desktops' para sincronizar os workspaces antes de 'terminals'."
parse_missing_indices "$missing_raw"

if (( ${#missing_indices[@]} != missing )); then
  fail "controlador retornou lista inconsistente de ausentes: missing=$missing indices='${missing_raw:-}'"
fi

log "ENCONTRADOS: $managed/$count terminal(is) já associados pela pasta/projeto."
if (( untracked > 0 )); then
  log "PRESERVADOS: $untracked terminal(is) sem pasta de projeto reconhecida; não serão movidos nem fechados."
fi

# 2) Abre SOMENTE os projetos realmente ausentes. Cada abertura declara ao
# controlador qual projeto está sendo criado; assim o vínculo não depende mais
# da ordem/velocidade em que janelas aparecem.
if (( missing > 0 )); then
  IFS=$'\t' read -r terminal_kind terminal < <(terminal_backend) || \
    fail 'nenhum terminal compatível encontrado. Rode: terminals --diagnose'
  log "FALTANDO: $missing. Abrindo somente os ausentes via $terminal_kind."

  for project_index in "${missing_indices[@]}"; do
    project_name="${project_entries[$project_index]}"
    working_dir="${project_dirs[$project_index]}"
    [[ -d "$working_dir" ]] || \
      fail "pasta do projeto '$project_name' não existe: $working_dir"

    log "ABRINDO: $project_name -> $working_dir"
    gnome_placement_prepare terminals open "$request_fields"$'\t'"project=$project_index" || \
      fail "não foi possível preparar a captura do terminal de '$project_name'."
    launch_terminal_window "$terminal_kind" "$terminal" "$working_dir" || \
      fail "falha ao abrir terminal de '$project_name' via $terminal_kind"
    gnome_placement_wait_complete terminals "$CAPTURE_TIMEOUT_TENTHS" || \
      fail "o GNOME não confirmou o terminal de '$project_name'; parei para não criar duplicatas."
  done
fi

# 3) Na MESMA chamada move todos os identificados para o workspace correto e
# maximiza no monitor direito. Repetir `terminals` só repete esta reconciliação.
gnome_placement_prepare terminals reconcile "$request_fields" || \
  fail 'não foi possível preparar a reconciliação dos terminais.'
if ! gnome_placement_wait_complete terminals 200; then
  fail 'o GNOME não confirmou a reconciliação completa. Rode: terminals --diagnose'
fi

persist_projects_signature "$projects_signature"
log "OK: $count terminal(is), um por destino, workspaces 2..$((count + 1)), monitor direito e MAXIMIZADO."
log 'Idempotente: se um terminal sair do workspace correto, rode terminals novamente; ele será movido pelo projeto/pasta sem abrir duplicata.'
