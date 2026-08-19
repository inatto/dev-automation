#!/usr/bin/env bash
# Sincroniza workspaces/desktops com os projetos ativos e reserva lrdp1/lrdp2 no final.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
PROJECTS_FILE="${PROJECTS_FILE:-$PROJECT_ROOT/config/auto-code-manager.projects}"
DESKTOPS_PLATFORM="${DESKTOPS_PLATFORM:-auto}"
GNOME_EXTENSION_UUID='workspace-name-osd@dev-automation'
GNOME_EXTENSION_SOURCE="$PROJECT_ROOT/apps/desktops-gnome-extension"
GNOME_EXTENSION_TARGET="$HOME/.local/share/gnome-shell/extensions/$GNOME_EXTENSION_UUID"
STATE_ROOT="${AUTO_CODE_STATE_DIR:-$HOME/.local/state/dev-automation}"
DESKTOPS_STATE_DIR="$STATE_ROOT/desktops"
DESKTOPS_CLOSE_REQUEST="$DESKTOPS_STATE_DIR/close.request"
DESKTOPS_CLOSE_READY="$DESKTOPS_STATE_DIR/close.ready"
DESKTOPS_CLOSE_RESULT="$DESKTOPS_STATE_DIR/close.result"
DESKTOPS_EXTENSION_READY="$DESKTOPS_STATE_DIR/extension.ready"

log() { printf '[desktops] %s\n' "$*"; }
warn() { printf '[desktops] AVISO: %s\n' "$*" >&2; }
fail() { printf '[desktops] ERRO: %s\n' "$*" >&2; exit 1; }

[[ -f "$PROJECTS_FILE" ]] || fail "arquivo de projetos não encontrado: $PROJECTS_FILE"

projects=()
while IFS= read -r raw_line || [[ -n "$raw_line" ]]; do
  line="${raw_line%%#*}"
  line="${line#"${line%%[![:space:]]*}"}"
  line="${line%"${line##*[![:space:]]}"}"
  line="${line#./}"
  line="${line%/}"
  [[ -n "$line" ]] || continue
  projects+=("$(basename -- "$line")")
done < "$PROJECTS_FILE"

((${#projects[@]} > 0)) || fail "nenhum projeto ativo configurado"

desktop_names=("LAZER" "${projects[@]}" "lrdp1" "lrdp2")

show_list() {
  local index=1 name
  for name in "${desktop_names[@]}"; do
    if ((index == 1)); then
      printf '%d\t%s (preservado)\n' "$index" "$name"
    else
      printf '%d\t%s\n' "$index" "$name"
    fi
    ((index += 1))
  done
}

request_gnome_close() {
  command -v gnome-extensions >/dev/null 2>&1 || fail 'gnome-extensions não encontrado'
  install_gnome_extension
  gnome-extensions info "$GNOME_EXTENSION_UUID" >/dev/null 2>&1 || \
    fail 'extensão GNOME de workspaces ainda não registrada; faça logout/login uma vez e rode desktops --close novamente.'

  mkdir -p "$DESKTOPS_STATE_DIR"
  local token tmp attempt ready result
  token="$(date +%s%N)-$$-$RANDOM"
  tmp="$DESKTOPS_CLOSE_REQUEST.tmp.$$"
  rm -f -- "$DESKTOPS_CLOSE_READY" "$DESKTOPS_CLOSE_RESULT"
  printf '%s\n' "$token" > "$tmp"
  mv -f "$tmp" "$DESKTOPS_CLOSE_REQUEST"

  for ((attempt=0; attempt<60; attempt++)); do
    if [[ -f "$DESKTOPS_CLOSE_READY" ]]; then
      ready="$(cat "$DESKTOPS_CLOSE_READY" 2>/dev/null || true)"
      if [[ "$ready" == "$token" ]]; then
        result="$(cat "$DESKTOPS_CLOSE_RESULT" 2>/dev/null || true)"
        log "fechamento solicitado para janelas dos workspaces gerenciados (LAZER preservado). ${result:-}"
        return 0
      fi
    fi
    sleep 0.1
  done
  fail 'GNOME não confirmou desktops --close; nenhuma tentativa de kill forçado foi feita.'
}

requested_action=sync
case "${1:-}" in
  --list|list)
    show_list
    exit 0
    ;;
  --close|close)
    requested_action=close
    ;;
  --help|-h|help)
    cat <<'HELP'
Uso:
  desktops --list   Mostra LAZER + projetos + lrdp1 + lrdp2, sem alterar o sistema
  desktops --close  Solicita fechamento de todas as janelas dos workspaces 2..N; preserva LAZER
  desktops          Sincroniza os workspaces e seus nomes

Ubuntu/GNOME:
  usa quantidade fixa de workspaces, nomeia todos e mantém uma extensão de controle
  sem UI própria. O nome do workspace fica somente na taskbar/painel já configurado.
  lrdp1 e lrdp2 ficam sempre por último.

WSL/Windows:
  preserva Desktop 1 e cria/nomeia os demais na mesma ordem.
HELP
    exit 0
    ;;
  "")
    ;;
  *)
    fail "argumento inválido: $1 (use --help)"
    ;;
esac

shell_major() {
  local version
  version="$(gnome-shell --version 2>/dev/null | grep -oE '[0-9]+' | head -n1 || true)"
  [[ -n "$version" ]] || version=50
  printf '%s\n' "$version"
}

install_gnome_extension() {
  command -v gnome-extensions >/dev/null 2>&1 || fail 'gnome-extensions não encontrado; não é possível ativar o controlador de workspaces.'
  [[ -f "$GNOME_EXTENSION_SOURCE/extension.js" ]] || fail "extensão GNOME ausente: $GNOME_EXTENSION_SOURCE"

  mkdir -p "$GNOME_EXTENSION_TARGET"
  cp -f "$GNOME_EXTENSION_SOURCE/extension.js" "$GNOME_EXTENSION_TARGET/extension.js"
  cp -f "$GNOME_EXTENSION_SOURCE/stylesheet.css" "$GNOME_EXTENSION_TARGET/stylesheet.css"

  local major
  major="$(shell_major)"
  cat > "$GNOME_EXTENSION_TARGET/metadata.json" <<JSON
{
  "uuid": "$GNOME_EXTENSION_UUID",
  "name": "Dev Automation Workspace Controller",
  "description": "Mantém o suporte ao desktops --close sem criar indicador visual duplicado; o nome do workspace fica somente na taskbar.",
  "shell-version": ["$major"],
  "version": 5
}
JSON

  if gnome-extensions info "$GNOME_EXTENSION_UUID" >/dev/null 2>&1; then
    mkdir -p "$DESKTOPS_STATE_DIR"
    rm -f -- "$DESKTOPS_EXTENSION_READY" "$DESKTOPS_STATE_DIR/ui.ready"
    gnome-extensions disable "$GNOME_EXTENSION_UUID" >/dev/null 2>&1 || true
    gnome-extensions enable "$GNOME_EXTENSION_UUID" >/dev/null 2>&1 || \
      fail 'GNOME recusou habilitar a extensão de controle dos workspaces.'

    local attempt ready=""
    for ((attempt=0; attempt<50; attempt++)); do
      if [[ -s "$DESKTOPS_EXTENSION_READY" ]]; then
        ready="$(cat "$DESKTOPS_EXTENSION_READY" 2>/dev/null || true)"
        if grep -Fqx 'version=5' <<<"$ready" && \
           grep -Fqx 'controller=1' <<<"$ready" && \
           grep -Fqx 'floating-label=0' <<<"$ready"; then
          log 'Extensão GNOME confirmada: sem indicador flutuante; nome do workspace permanece somente na taskbar.'
          return 0
        fi
      fi
      sleep 0.1
    done
    fail 'a extensão foi habilitada, mas não confirmou o modo sem indicador flutuante; veja journalctl --user -b | grep workspace-name-osd.'
  else
    fail 'extensão GNOME instalada, mas o Shell ainda não a registrou; faça logout/login uma vez e rode desktops novamente.'
  fi
}

gvariant_strv() {
  local result='[' name escaped separator=''
  for name in "$@"; do
    escaped="${name//\\/\\\\}"
    escaped="${escaped//\'/\\\'}"
    result+="$separator'$escaped'"
    separator=', '
  done
  result+=']'
  printf '%s\n' "$result"
}

sync_gnome() {
  command -v gsettings >/dev/null 2>&1 || fail 'gsettings não encontrado'
  local required_count names_variant
  required_count="${#desktop_names[@]}"
  names_variant="$(gvariant_strv "${desktop_names[@]}")"

  gsettings set org.gnome.mutter dynamic-workspaces false
  gsettings set org.gnome.desktop.wm.preferences num-workspaces "$required_count"
  gsettings set org.gnome.desktop.wm.preferences workspace-names "$names_variant"
  install_gnome_extension

  log "GNOME sincronizado: $required_count workspaces fixos; lrdp1 e lrdp2 são os dois últimos."
  show_list
}

sync_windows() {
  command -v powershell.exe >/dev/null 2>&1 || fail "powershell.exe não encontrado"
  command -v iconv >/dev/null 2>&1 || fail "iconv não encontrado"
  command -v base64 >/dev/null 2>&1 || fail "base64 não encontrado"

  local sync_script encoded_command name escaped
  sync_script="$({
    printf '$desktopNames = @(\n'
    for name in "${desktop_names[@]:1}"; do
      escaped="${name//\'/\'\'}"
      printf "    '%s'\n" "$escaped"
    done
    cat <<'POWERSHELL_SYNC'
)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$OutputEncoding = [Console]::OutputEncoding
Import-Module VirtualDesktop -DisableNameChecking

$requiredCount = 1 + $desktopNames.Count
while ((Get-DesktopCount) -lt $requiredCount) {
    New-Desktop | Out-Null
}
for ($i = 0; $i -lt $desktopNames.Count; $i++) {
    $desktop = Get-Desktop ($i + 1)
    Set-DesktopName -Desktop $desktop -Name ([string]$desktopNames[$i])
}
Write-Host ("[desktops] Desktop 1 preservado; {0} desktop(s) sincronizado(s)." -f $desktopNames.Count)
POWERSHELL_SYNC
  })"

  encoded_command="$(printf '%s' "$sync_script" | iconv -f UTF-8 -t UTF-16LE | base64 -w0)"
  powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -EncodedCommand "$encoded_command"
}

detect_platform() {
  case "$DESKTOPS_PLATFORM" in
    gnome|ubuntu|linux) printf 'gnome\n'; return ;;
    windows|wsl) printf 'windows\n'; return ;;
    auto) ;;
    *) fail "DESKTOPS_PLATFORM inválido: $DESKTOPS_PLATFORM" ;;
  esac

  if command -v gsettings >/dev/null 2>&1 && command -v gnome-shell >/dev/null 2>&1; then
    printf 'gnome\n'
  elif command -v powershell.exe >/dev/null 2>&1; then
    printf 'windows\n'
  else
    fail 'ambiente não suportado: GNOME e powershell.exe não encontrados'
  fi
}

platform="$(detect_platform)"
case "$requested_action:$platform" in
  sync:gnome) sync_gnome ;;
  sync:windows) sync_windows ;;
  close:gnome) request_gnome_close ;;
  close:windows) fail 'desktops --close está disponível no Ubuntu/GNOME.' ;;
  *) fail "ação/plataforma inválida: $requested_action/$platform" ;;
esac
