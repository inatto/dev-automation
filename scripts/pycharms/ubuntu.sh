#!/usr/bin/env bash
# Backend Ubuntu/Linux do comando `pycharms`.
# Uma única chamada reconcilia os projetos já abertos, abre apenas os faltantes
# e reconcilia novamente quando as novas janelas estiverem disponíveis.
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd -P)"
# shellcheck source=../lib/project-config.sh
source "$PROJECT_ROOT/scripts/lib/project-config.sh"
CONFIG_FILE="${PYCHARMS_PROJECTS_FILE:-$(dev_projects_file "$PROJECT_ROOT")}"
CODE_ROOT="${CODE_ROOT:-/home/daniel/Code}"
OPEN_DELAY_SECONDS="${PYCHARMS_OPEN_DELAY_SECONDS:-1}"
GNOME_WAYLAND_HELPER="$SCRIPT_DIR/gnome-wayland.sh"
DESKTOPS_SCRIPT="$PROJECT_ROOT/scripts/desktops.sh"
STATE_DIR="${AUTO_CODE_STATE_DIR:-$HOME/.local/state/dev-automation}/pycharms"
WORKSPACE_MAP="$STATE_DIR/workspaces.tsv"
BATCH_MARKER="$STATE_DIR/batch-opening"
RECONCILE_REQUEST="$STATE_DIR/reconcile.request"
RECONCILE_READY="$STATE_DIR/reconcile.ready"
RECONCILE_RESULT="$STATE_DIR/reconcile.result"
CLOSE_REQUEST="$STATE_DIR/close.request"
CLOSE_READY="$STATE_DIR/close.ready"
CLOSE_RESULT="$STATE_DIR/close.result"
OPEN_PROJECTS_SNAPSHOT="${PYCHARMS_OPEN_PROJECTS_FILE:-$STATE_DIR/open-projects.tsv}"
OPEN_PROJECTS_REQUEST="$STATE_DIR/open-projects.request"
OPEN_PROJECTS_READY="$STATE_DIR/open-projects.ready"
VERSION_FILE="$PROJECT_ROOT/VERSION"
BUILD_VERSION="$(cat "$VERSION_FILE" 2>/dev/null || printf 'versão-desconhecida')"
log(){ printf '[pycharms] %s\n' "$*"; }
warn(){ printf '[pycharms] AVISO: %s\n' "$*" >&2; }
fail(){ printf '[pycharms] ERRO: %s\n' "$*" >&2; exit 1; }

find_pycharm_native() {
  local cmd candidate
  for cmd in pycharm pycharm-professional pycharm-community pycharm.sh; do
    if command -v "$cmd" >/dev/null 2>&1; then command -v "$cmd"; return 0; fi
  done
  while IFS= read -r candidate; do
    [[ -x "$candidate" ]] && { printf '%s\n' "$candidate"; return 0; }
  done < <(find /opt "$HOME/.local/share/JetBrains/Toolbox/apps" -maxdepth 8 -type f \( -name pycharm -o -name pycharm.sh \) 2>/dev/null | sort -r)
  return 1
}

pycharm_mode() {
  local native
  if native="$(find_pycharm_native 2>/dev/null)"; then printf 'native\t%s\n' "$native"; return 0; fi
  if command -v snap >/dev/null 2>&1; then
    if snap list pycharm-professional >/dev/null 2>&1; then printf 'snap\tpycharm-professional\n'; return 0; fi
    if snap list pycharm-community >/dev/null 2>&1; then printf 'snap\tpycharm-community\n'; return 0; fi
  fi
  if command -v flatpak >/dev/null 2>&1; then
    if flatpak info com.jetbrains.PyCharm-Professional >/dev/null 2>&1; then printf 'flatpak\tcom.jetbrains.PyCharm-Professional\n'; return 0; fi
    if flatpak info com.jetbrains.PyCharm-Community >/dev/null 2>&1; then printf 'flatpak\tcom.jetbrains.PyCharm-Community\n'; return 0; fi
  fi
  return 1
}

show_diagnose() {
  printf '=== PYCHARM / UBUNTU ===\n'
  printf 'VERSÃO=%s\n' "$BUILD_VERSION"
  printf 'PATH command: '; command -v pycharm || true
  printf 'pycharm-professional: '; command -v pycharm-professional || true
  printf 'pycharm-community: '; command -v pycharm-community || true
  printf '\nCandidatos locais:\n'
  find /opt "$HOME/.local/share/JetBrains/Toolbox/apps" -maxdepth 8 -type f \( -name pycharm -o -name pycharm.sh \) -print 2>/dev/null | sort || true
  printf '\nDetectado pelo comando:\n'; pycharm_mode || printf 'NÃO ENCONTRADO\n'
  printf '\n=== GNOME / MONITOR ===\n'
  [[ -x "$GNOME_WAYLAND_HELPER" ]] && "$GNOME_WAYLAND_HELPER" diagnose || true
  printf '\n=== MAPA PROJETO -> WORKSPACE ===\n'
  load_projects
  write_workspace_map
  cat "$WORKSPACE_MAP"
}

load_projects() {
  [[ -f "$CONFIG_FILE" ]] || fail "configuração não encontrada: $CONFIG_FILE"
  resolved_projects=(); resolved_workspace_indexes=(); resolved_project_names=()
  configured_projects=(); configured_workspace_indexes=()
  declare -gA seen_projects=()
  local line path real workspace_index=2

  # Exatamente a mesma grade usada por `desktops` e `terminals`: agregadores
  # *.zip e subprojetos dentro de <pai>/apps/... não consomem workspace.
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -n "$line" ]] || continue
    configured_projects+=("$line")
    configured_workspace_indexes+=("$workspace_index")
    ((workspace_index += 1))
  done < <(dev_desktop_projects "$CONFIG_FILE")

  local idx
  for ((idx=0; idx<${#configured_projects[@]}; idx++)); do
    line="${configured_projects[$idx]}"
    path="$CODE_ROOT/$line"
    if [[ ! -d "$path" ]]; then
      warn "fora do grid da IDE; projeto ainda ausente: $path"
      continue
    fi

    real="$(cd -- "$path" && pwd -P)"
    [[ -z "${seen_projects[$real]:-}" ]] || continue
    seen_projects[$real]=1
    resolved_projects+=("$real")
    resolved_workspace_indexes+=("${configured_workspace_indexes[$idx]}")
    resolved_project_names+=("$(basename -- "$line")")
  done
}
write_workspace_map() {
  mkdir -p "$STATE_DIR"
  local tmp="$WORKSPACE_MAP.tmp.$$" i
  : > "$tmp"
  for ((i=0; i<${#resolved_projects[@]}; i++)); do
    printf '%s\t%s\t%s\n' \
      "${resolved_workspace_indexes[$i]}" \
      "${resolved_project_names[$i]}" \
      "${resolved_projects[$i]}" >> "$tmp"
  done
  mv -f "$tmp" "$WORKSPACE_MAP"
}

show_workspace_map() {
  load_projects
  write_workspace_map
  cat "$WORKSPACE_MAP"
}

request_reconcile() {
  mkdir -p "$STATE_DIR"
  local token tmp attempt ready result
  token="$(date +%s%N)-$$-$RANDOM"
  tmp="$RECONCILE_REQUEST.tmp.$$"
  rm -f -- "$RECONCILE_READY" "$RECONCILE_RESULT"
  printf '%s\n' "$token" > "$tmp"
  mv -f "$tmp" "$RECONCILE_REQUEST"

  log "MOVIMENTAÇÃO: pedido enviado ao GNOME; tentando posicionar as janelas nos workspaces configurados."
  if [[ "${XDG_SESSION_TYPE:-}" != wayland ]]; then
    log "MOVIMENTAÇÃO: sessão não-Wayland; pedido gravado, sem confirmação do GNOME."
    return 0
  fi

  for ((attempt=0; attempt<100; attempt++)); do
    if [[ -f "$RECONCILE_READY" ]]; then
      ready="$(cat "$RECONCILE_READY" 2>/dev/null || true)"
      if [[ "$ready" == "$token" ]]; then
        result="$(cat "$RECONCILE_RESULT" 2>/dev/null || true)"
        log "MOVIMENTAÇÃO CONFIRMADA PELO GNOME: ${result:-sem detalhes}"
        return 0
      fi
    fi
    sleep 0.1
  done

  warn 'MOVIMENTAÇÃO SOLICITADA, mas o GNOME não confirmou em 10s. Rode: pycharms --diagnose'
  return 1
}

request_close_all() {
  [[ "${XDG_SESSION_TYPE:-}" == wayland ]] || fail 'pycharms --close requer sessão GNOME/Wayland.'
  [[ -x "$GNOME_WAYLAND_HELPER" ]] || fail "helper GNOME ausente: $GNOME_WAYLAND_HELPER"
  "$GNOME_WAYLAND_HELPER" ensure >/dev/null || true

  mkdir -p "$STATE_DIR"
  local token tmp attempt ready result
  token="$(date +%s%N)-$$-$RANDOM"
  tmp="$CLOSE_REQUEST.tmp.$$"
  rm -f -- "$BATCH_MARKER" "$CLOSE_READY" "$CLOSE_RESULT"
  printf '%s\n' "$token" > "$tmp"
  mv -f "$tmp" "$CLOSE_REQUEST"

  for ((attempt=0; attempt<60; attempt++)); do
    if [[ -f "$CLOSE_READY" ]]; then
      ready="$(cat "$CLOSE_READY" 2>/dev/null || true)"
      if [[ "$ready" == "$token" ]]; then
        result="$(cat "$CLOSE_RESULT" 2>/dev/null || true)"
        log "fechamento solicitado para todas as janelas PyCharm. ${result:-}"
        return 0
      fi
    fi
    sleep 0.1
  done
  fail 'GNOME não confirmou pycharms --close; nenhum kill forçado foi executado.'
}

pycharm_process_running() {
  pgrep -af 'pycharm64|pycharm\.sh|/pycharm([[:space:]]|$)|jetbrains.*pycharm|PyCharm' >/dev/null 2>&1
}

request_open_projects_snapshot() {
  mkdir -p "$STATE_DIR"

  # Testes/integrações podem fornecer um snapshot explícito. No uso normal em
  # GNOME/Wayland, a extensão produz este arquivo a partir das janelas reais.
  if [[ -n "${PYCHARMS_OPEN_PROJECTS_FILE:-}" ]]; then
    [[ -f "$OPEN_PROJECTS_SNAPSHOT" ]] || : > "$OPEN_PROJECTS_SNAPSHOT"
    return 0
  fi

  if [[ "${XDG_SESSION_TYPE:-}" != wayland ]]; then
    # Fora do Wayland não prometemos introspecção de janelas. Mantém o
    # comportamento anterior sem inventar estado que não conseguimos provar.
    : > "$OPEN_PROJECTS_SNAPSHOT"
    return 0
  fi

  local token tmp attempt ready
  token="$(date +%s%N)-$$-$RANDOM"
  tmp="$OPEN_PROJECTS_REQUEST.tmp.$$"
  rm -f -- "$OPEN_PROJECTS_READY"
  printf '%s\n' "$token" > "$tmp"
  mv -f "$tmp" "$OPEN_PROJECTS_REQUEST"

  for ((attempt=0; attempt<50; attempt++)); do
    if [[ -f "$OPEN_PROJECTS_READY" ]]; then
      ready="$(cat "$OPEN_PROJECTS_READY" 2>/dev/null || true)"
      if [[ "$ready" == "$token" ]]; then
        [[ -f "$OPEN_PROJECTS_SNAPSHOT" ]] || : > "$OPEN_PROJECTS_SNAPSHOT"
        return 0
      fi
    fi
    sleep 0.1
  done

  # Idempotência é mais importante que "tentar mesmo assim". Se já existe
  # PyCharm rodando e não conseguimos enumerar as janelas, não abrimos nada.
  if pycharm_process_running; then
    fail 'não foi possível obter a lista de projetos PyCharm já abertos pelo GNOME; abortando para não duplicar janelas. Rode: pycharms --diagnose'
  fi

  warn 'snapshot de janelas GNOME indisponível, mas nenhum PyCharm está rodando; seguindo com lista vazia.'
  : > "$OPEN_PROJECTS_SNAPSHOT"
}

load_open_project_set() {
  declare -gA open_project_set=()
  local a b c path
  [[ -f "$OPEN_PROJECTS_SNAPSHOT" ]] || return 0
  while IFS=$'\t' read -r a b c || [[ -n "${a:-}${b:-}${c:-}" ]]; do
    path=''
    if [[ -n "${c:-}" ]]; then
      path="$c"
    elif [[ -n "${b:-}" ]]; then
      path="$b"
    else
      path="${a:-}"
    fi
    [[ -n "$path" ]] || continue
    open_project_set["$path"]=1
  done < "$OPEN_PROJECTS_SNAPSHOT"
}

refresh_open_projects() {
  request_open_projects_snapshot
  load_open_project_set
}

ensure_gnome_workspaces() {
  [[ "${XDG_SESSION_TYPE:-}" == wayland ]] || return 0
  if [[ -x "$DESKTOPS_SCRIPT" ]]; then
    PROJECTS_FILE="$CONFIG_FILE" DESKTOPS_PLATFORM=gnome "$DESKTOPS_SCRIPT" >/dev/null || \
      warn 'não foi possível sincronizar os workspaces antes de abrir o PyCharm'
  fi
  if [[ -x "$GNOME_WAYLAND_HELPER" ]]; then
    "$GNOME_WAYLAND_HELPER" ensure || warn 'extensão GNOME não está ACTIVE; abertura pode prosseguir, mas MOVIMENTAÇÃO não será confirmada.'
  fi
}

begin_batch() {
  mkdir -p "$STATE_DIR"
  # Expiração de segurança caso o comando seja interrompido durante a abertura.
  printf '%s\n' "$(( $(date +%s) + 180 ))" > "$BATCH_MARKER"
}

wait_for_all_projects_open() {
  local timeout="${PYCHARMS_OPEN_WAIT_SECONDS:-75}" attempt max_attempts missing project
  [[ "$timeout" =~ ^[0-9]+$ ]] || timeout=75
  max_attempts=$((timeout * 2))

  for ((attempt=0; attempt<max_attempts; attempt++)); do
    refresh_open_projects
    missing=0
    for project in "${resolved_projects[@]}"; do
      if [[ -z "${open_project_set[$project]:-}" ]]; then
        ((missing += 1))
      fi
    done
    ((missing == 0)) && return 0
    sleep 0.5
  done
  return 1
}
open_project() {
  local mode="$1" target="$2" project="$3"
  case "$mode" in
    native) nohup "$target" "$project" >/dev/null 2>&1 & ;;
    snap) nohup snap run "$target" "$project" >/dev/null 2>&1 & ;;
    flatpak) nohup flatpak run "$target" "$project" >/dev/null 2>&1 & ;;
  esac
}

case "${1:-}" in
  --diagnose|diagnose) show_diagnose; exit 0 ;;
  --workspace-map|workspace-map) show_workspace_map; exit 0 ;;
  --close|close)
    log "VERSÃO: $BUILD_VERSION"
    request_close_all
    exit 0
    ;;
  --reconcile|reconcile)
    log "VERSÃO: $BUILD_VERSION"
    log 'FASE: MOVIMENTAÇÃO FORÇADA'
    load_projects
    write_workspace_map
    ensure_gnome_workspaces
    rm -f -- "$BATCH_MARKER"
    request_reconcile
    log 'reconciliação final solicitada.'
    exit 0
    ;;
  --help|-h|help) printf 'Uso: pycharms | pycharms --list | pycharms --workspace-map | pycharms --reconcile | pycharms --close | pycharms --diagnose\n'; exit 0 ;;
  --list|list) list_only=1 ;;
  "") list_only=0 ;;
  *) fail "opção inválida: $1" ;;
esac

load_projects
write_workspace_map
if ((list_only)); then printf '%s\n' "${resolved_projects[@]}"; exit 0; fi
log "VERSÃO: $BUILD_VERSION"
((${#resolved_projects[@]})) || fail 'nenhum projeto existente para abrir.'
ensure_gnome_workspaces
rm -f -- "$BATCH_MARKER"
refresh_open_projects

projects_to_open=()
workspaces_to_open=()
for ((i=0; i<${#resolved_projects[@]}; i++)); do
  project="${resolved_projects[$i]}"
  workspace="${resolved_workspace_indexes[$i]}"
  if [[ -n "${open_project_set[$project]:-}" ]]; then
    log "já aberto; realinhando para workspace $workspace: $project"
    continue
  fi
  projects_to_open+=("$project")
  workspaces_to_open+=("$workspace")
done

if [[ "${XDG_SESSION_TYPE:-}" == wayland ]]; then
  log 'FASE: REALINHAMENTO INICIAL'
  request_reconcile || fail 'GNOME não confirmou o realinhamento das janelas PyCharm já abertas.'
fi

if ((${#projects_to_open[@]} == 0)); then
  log "ABERTURA: 0 projeto(s). Todos os ${#resolved_projects[@]} projeto(s) já estão abertos e foram reconciliados com a grade atual."
  log 'CONCLUÍDO: nenhuma janela duplicada foi criada.'
  exit 0
fi

IFS=$'\t' read -r mode target < <(pycharm_mode) || fail 'PyCharm não encontrado. Rode: pycharms --diagnose'
if [[ "${XDG_SESSION_TYPE:-}" == wayland ]]; then
  begin_batch
fi
log 'FASE: ABERTURA DOS FALTANTES'
log "Ubuntu backend: $mode -> $target"
log "ABERTURA: ${#projects_to_open[@]} projeto(s) faltando de ${#resolved_projects[@]} configurado(s)."
for ((i=0; i<${#projects_to_open[@]}; i++)); do
  project="${projects_to_open[$i]}"
  workspace="${workspaces_to_open[$i]}"
  log "ABRINDO AGORA workspace $workspace: $project"
  open_project "$mode" "$target" "$project"
  sleep "$OPEN_DELAY_SECONDS"
done

if [[ "${XDG_SESSION_TYPE:-}" == wayland ]]; then
  log 'FASE: CONFIRMAÇÃO E REALINHAMENTO FINAL'
  if ! wait_for_all_projects_open; then
    rm -f -- "$BATCH_MARKER"
    request_reconcile >/dev/null 2>&1 || true
    fail 'nem todas as janelas PyCharm apareceram dentro do limite; as detectadas foram realinhadas, mas o lote ficou incompleto.'
  fi
  rm -f -- "$BATCH_MARKER"
  request_reconcile || fail 'as janelas abriram, mas o GNOME não confirmou o realinhamento final.'
  log 'CONCLUÍDO: projetos existentes realinhados e faltantes abertos na mesma chamada.'
else
  log 'CONCLUÍDO: projetos faltantes abertos; realinhamento de workspace exige GNOME/Wayland.'
fi
