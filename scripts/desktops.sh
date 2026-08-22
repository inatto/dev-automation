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
GNOME_EXTENSION_VERSION=10

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
  --ensure-controller|ensure-controller)
    requested_action=ensure-controller
    ;;
  --help|-h|help)
    cat <<'HELP'
Uso:
  desktops --list   Mostra LAZER + projetos + lrdp1 + lrdp2, sem alterar o sistema
  desktops --close              Solicita fechamento de todas as janelas dos workspaces 2..N; preserva LAZER
  desktops --ensure-controller  Instala/recarrega apenas o controlador GNOME, sem renomear workspaces
  desktops                      Sincroniza os workspaces e seus nomes

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

  mkdir -p "$GNOME_EXTENSION_TARGET" "$DESKTOPS_STATE_DIR"

  local major metadata_tmp changed=0 info state runtime_ready attempt
  major="$(shell_major)"
  metadata_tmp="$(mktemp "$DESKTOPS_STATE_DIR/metadata.XXXXXX")"
  cat > "$metadata_tmp" <<JSON
{
  "uuid": "$GNOME_EXTENSION_UUID",
  "name": "Dev Automation Workspace Controller",
  "description": "Controla workspaces e posicionamento explícito de janelas sem criar indicador visual duplicado.",
  "shell-version": ["$major"],
  "version": $GNOME_EXTENSION_VERSION
}
JSON

  for pair in \
    "$GNOME_EXTENSION_SOURCE/extension.js:$GNOME_EXTENSION_TARGET/extension.js" \
    "$GNOME_EXTENSION_SOURCE/stylesheet.css:$GNOME_EXTENSION_TARGET/stylesheet.css" \
    "$metadata_tmp:$GNOME_EXTENSION_TARGET/metadata.json"
  do
    local src="${pair%%:*}" dst="${pair#*:}"
    if [[ ! -f "$dst" ]] || ! cmp -s -- "$src" "$dst"; then
      cp -f -- "$src" "$dst"
      changed=1
    fi
  done
  rm -f -- "$metadata_tmp"

  runtime_ready=0
  if [[ -s "$DESKTOPS_EXTENSION_READY" ]]; then
    runtime_ready=1
    grep -Fqx "version=$GNOME_EXTENSION_VERSION" "$DESKTOPS_EXTENSION_READY" || runtime_ready=0
    grep -Fqx 'controller=1' "$DESKTOPS_EXTENSION_READY" || runtime_ready=0
    grep -Fqx 'floating-label=0' "$DESKTOPS_EXTENSION_READY" || runtime_ready=0
    grep -Fqx 'window-placement=1' "$DESKTOPS_EXTENSION_READY" || runtime_ready=0
  fi

  info="$(gnome-extensions info "$GNOME_EXTENSION_UUID" 2>/dev/null || true)"
  state="$(sed -n 's/^[[:space:]]*State:[[:space:]]*//p' <<<"$info" | head -n1 | tr '[:lower:]' '[:upper:]')"

  # Caminho normal e idempotente: se o controlador já está ativo e confirmou a
  # versão carregada nesta sessão, NÃO desabilita, NÃO reabilita e NÃO apaga o
  # marker. Repetir desktops/chromes/terminals não muda o estado da extensão.
  if [[ "$state" == ACTIVE && "$runtime_ready" == 1 ]]; then
    (( changed == 0 )) || warn 'arquivos da extensão foram atualizados no disco; a sessão atual continua usando o controlador já carregado.'
    return 0
  fi

  # Extensão ainda não registrada pelo Shell atual. Em Wayland, código novo só
  # entra de verdade em um novo processo gnome-shell (logout/login).
  if [[ -z "$info" ]]; then
    gnome-extensions enable "$GNOME_EXTENSION_UUID" >/dev/null 2>&1 || true
    warn 'controlador GNOME instalado no disco, mas esta sessão ainda não o registrou. Faça logout/login UMA vez; depois os comandos ficam idempotentes.'
    return 75
  fi

  # Se está registrada porém inativa, habilitar é válido. Aguarda confirmação
  # sem apagar markers nem ficar alternando enable/disable em corrida.
  if [[ "$state" != ACTIVE ]]; then
    gnome-extensions enable "$GNOME_EXTENSION_UUID" >/dev/null 2>&1 || \
      fail 'GNOME recusou habilitar a extensão de controle dos workspaces.'
    for ((attempt=0; attempt<30; attempt++)); do
      if [[ -s "$DESKTOPS_EXTENSION_READY" ]] && \
         grep -Fqx "version=$GNOME_EXTENSION_VERSION" "$DESKTOPS_EXTENSION_READY" && \
         grep -Fqx 'controller=1' "$DESKTOPS_EXTENSION_READY" && \
         grep -Fqx 'floating-label=0' "$DESKTOPS_EXTENSION_READY" && \
         grep -Fqx 'window-placement=1' "$DESKTOPS_EXTENSION_READY"; then
        return 0
      fi
      sleep 0.1
    done
  fi

  # ACTIVE com marker antigo = exatamente o caso que estava aparecendo de forma
  # aleatória: o script copiava v6 e tentava "recarregar" com disable/enable,
  # mas GJS mantém o módulo em cache na mesma sessão Wayland. Não insistimos.
  if [[ "${XDG_SESSION_TYPE:-}" == wayland ]]; then
    warn "controlador GNOME v$GNOME_EXTENSION_VERSION já foi preparado no disco, mas a sessão Wayland ainda usa a versão anterior. Faça logout/login UMA vez; não é necessário reiniciar o Ubuntu."
    return 75
  fi

  fail 'controlador GNOME não confirmou a versão carregada; veja journalctl --user -b | grep workspace-name-osd.'
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

  local controller_rc=0
  install_gnome_extension || controller_rc=$?
  if (( controller_rc == 75 )); then
    warn 'workspaces sincronizados e controlador atualizado no disco; falta apenas UM logout/login para o GNOME carregar o código novo.'
  elif (( controller_rc != 0 )); then
    return "$controller_rc"
  fi

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
  ensure-controller:gnome) install_gnome_extension ;;
  ensure-controller:windows) fail 'desktops --ensure-controller está disponível no Ubuntu/GNOME.' ;;
  *) fail "ação/plataforma inválida: $requested_action/$platform" ;;
esac
