#!/usr/bin/env bash
# Sincroniza workspaces/desktops com os projetos ativos e reserva lrdp1/lrdp2 no final.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
PROJECTS_FILE="${PROJECTS_FILE:-$PROJECT_ROOT/config/auto-code-manager.projects}"
DESKTOPS_PLATFORM="${DESKTOPS_PLATFORM:-auto}"
GNOME_OSD_UUID='workspace-name-osd@dev-automation'
GNOME_OSD_SOURCE="$PROJECT_ROOT/apps/desktops-gnome-extension"
GNOME_OSD_TARGET="$HOME/.local/share/gnome-shell/extensions/$GNOME_OSD_UUID"

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

case "${1:-}" in
  --list|list)
    show_list
    exit 0
    ;;
  --help|-h|help)
    cat <<'HELP'
Uso:
  desktops --list   Mostra LAZER + projetos + lrdp1 + lrdp2, sem alterar o sistema
  desktops          Sincroniza os workspaces e seus nomes

Ubuntu/GNOME:
  usa quantidade fixa de workspaces, nomeia todos e instala OSD que mostra
  "numero  nome" ao alternar. lrdp1 e lrdp2 ficam sempre por último.

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

install_gnome_osd() {
  command -v gnome-extensions >/dev/null 2>&1 || { warn 'gnome-extensions não encontrado; nomes serão aplicados, mas o OSD não será instalado.'; return 0; }
  [[ -f "$GNOME_OSD_SOURCE/extension.js" ]] || { warn "extensão OSD ausente: $GNOME_OSD_SOURCE"; return 0; }

  mkdir -p "$GNOME_OSD_TARGET"
  cp -f "$GNOME_OSD_SOURCE/extension.js" "$GNOME_OSD_TARGET/extension.js"
  cp -f "$GNOME_OSD_SOURCE/stylesheet.css" "$GNOME_OSD_TARGET/stylesheet.css"

  local major
  major="$(shell_major)"
  cat > "$GNOME_OSD_TARGET/metadata.json" <<JSON
{
  "uuid": "$GNOME_OSD_UUID",
  "name": "Dev Automation Workspace Name OSD",
  "description": "Mostra numero e nome do workspace ao alternar no GNOME.",
  "shell-version": ["$major"],
  "version": 1
}
JSON

  if gnome-extensions info "$GNOME_OSD_UUID" >/dev/null 2>&1; then
    gnome-extensions enable "$GNOME_OSD_UUID" >/dev/null 2>&1 || true
    log 'OSD de nome do workspace instalado/habilitado.'
  else
    warn 'OSD instalado, mas o GNOME Shell ainda não registrou a nova extensão; faça logout/login uma vez e rode desktops novamente.'
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
  install_gnome_osd

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

case "$(detect_platform)" in
  gnome) sync_gnome ;;
  windows) sync_windows ;;
esac
