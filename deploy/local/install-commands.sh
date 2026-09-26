#!/usr/bin/env bash
# cd /home/daniel/Code/bots/dev-automation

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd -P)"
TARGET_DIR="${TARGET_DIR:-$HOME/.local/bin}"
AUTO_SOURCE="$PROJECT_ROOT/scripts/dev-manager/auto-code-manager.sh"
AUTO_TARGET="$TARGET_DIR/auto-code-manager"
PROJECT_INSTALLER="$PROJECT_ROOT/deploy/local/install-project-commands.sh"
PROJECT_RUNNER="$PROJECT_ROOT/scripts/project/project-command.sh"
PROJECT_SSH_RUNNER="$PROJECT_ROOT/scripts/project/project-ssh.sh"
PROJECT_ALL_RUNNER="$PROJECT_ROOT/scripts/project/project-all-command.sh"
ORACLE_MONITOR_DIR="$PROJECT_ROOT/apps/oracle-monitor"
VOICE_COMMANDS_SOURCE="$PROJECT_ROOT/apps/voice-commands/run.sh"
GPT_CONSOLE_SOURCE="$PROJECT_ROOT/apps/gpt-console/run.sh"
AMAZON_IMAP_BOT_DIR="$PROJECT_ROOT/apps/amazon-imap-bot"
AMAZON_IMAP_BOT_SOURCE="$AMAZON_IMAP_BOT_DIR/deploy/local/start.sh"
AMAZON_IMAP_BOT_AUTO_STATUS_SOURCE="$PROJECT_ROOT/scripts/amazon-imap-bot/amazon-imap-bot-auto-status.sh"
SCRIPT_DEV_AUTOMATION_SOURCE="$PROJECT_ROOT/apps/script-dev-automation/run.sh"
CHROMES_SOURCE="$PROJECT_ROOT/scripts/chromes/chromes.sh"
CHROMES_ALL_SOURCE="$PROJECT_ROOT/scripts/chromes/chromes-all.sh"
CHROMES_CLOSE_SOURCE="$PROJECT_ROOT/scripts/chromes/chromes-close.sh"
FILES_SOURCE="$PROJECT_ROOT/scripts/files/files.sh"
FILES_ALL_SOURCE="$PROJECT_ROOT/scripts/files/files-all.sh"
FILES_CLOSE_SOURCE="$PROJECT_ROOT/scripts/files/files-close.sh"
TERMINALS_SOURCE="$PROJECT_ROOT/scripts/terminals/terminals.sh"
TERMINALS_CLOSE_SOURCE="$PROJECT_ROOT/scripts/terminals/terminals-close.sh"
CHATGPTS_SOURCE="$PROJECT_ROOT/scripts/chatgpts/chatgpts.sh"
PHPSTORMS_SOURCE="$PROJECT_ROOT/scripts/phpstorms/phpstorms.sh"
PYCHARMS_SOURCE="$PROJECT_ROOT/scripts/pycharms/pycharms.sh"
PYCHARMS_CLOSE_SOURCE="$PROJECT_ROOT/scripts/pycharms/pycharms-close.sh"
PHPSTORM_DEV_SOURCE="$PROJECT_ROOT/scripts/phpstorms/phpstorm-dev.sh"
DEV_MANAGER_SOURCE="$PROJECT_ROOT/scripts/dev-manager/dev-manager.sh"
DESKTOPS_SOURCE="$PROJECT_ROOT/scripts/desktops/desktops.sh"
LOCAL_NGINX_SOURCE="$PROJECT_ROOT/scripts/nginx/local-nginx.sh"
DEV_STATUS_SOURCE="$PROJECT_ROOT/scripts/dev-status/dev-status.sh"
CLEAR_TERMINAL_SOURCE="$PROJECT_ROOT/scripts/core/clear-terminal.sh"
DEV_GITSETUP_SOURCE="$PROJECT_ROOT/scripts/project-sync/dev-gitsetup.py"
G512_RGB_SOURCE="$PROJECT_ROOT/scripts/g512/g512-rgb.sh"
GLOBAL_SHORTCUTS_SOURCE="$PROJECT_ROOT/scripts/Global Shortcuts/Global-Shortcuts.sh"
GLOBAL_SHORTCUTS_TARGET="$TARGET_DIR/Global-Shortcuts"
GLOBAL_AUTO_RUNNER="$PROJECT_ROOT/scripts/core/global-command-auto.sh"
CODE_ROOT="${CODE_ROOT:-/home/daniel/Code}"
LRDP_DIR="${LRDP_DIR:-$PROJECT_ROOT/apps/lrdp}"
LRDP_TUI_SOURCE="${LRDP_TUI_SOURCE:-$LRDP_DIR/lrdp}"
LRDP1_SOURCE="${LRDP1_SOURCE:-$LRDP_DIR/lrdp1}"
LRDP2_SOURCE="${LRDP2_SOURCE:-$LRDP_DIR/lrdp2}"

log() { printf '[install-commands] %s\n' "$*"; }
fail() { printf '[install-commands] ERRO: %s\n' "$*" >&2; exit 1; }

normalize_ubuntu_terminal() {
  # O Dev Automation usa deliberadamente um único emulador gráfico:
  # GNOME Terminal. Ele é necessário para manter as abas Local/Remote visíveis.
  command -v apt-get >/dev/null 2>&1 || return 0
  command -v dpkg-query >/dev/null 2>&1 || return 0
  command -v sudo >/dev/null 2>&1 || return 0

  local can_sudo=0
  if [[ -t 0 && -t 1 ]]; then
    can_sudo=1
  elif sudo -n true >/dev/null 2>&1; then
    can_sudo=1
  fi
  [[ "$can_sudo" == 1 ]] || {
    log 'AVISO: sem sudo interativo; normalização do terminal foi adiada.'
    return 0
  }

  if ! dpkg-query -W -f='${Status}' gnome-terminal 2>/dev/null | grep -Fq 'install ok installed'; then
    log 'instalando terminal padrão do Dev Automation: GNOME Terminal...'
    sudo apt-get install -y gnome-terminal
  fi

  # Ptyxis é o terminal concorrente que vinha ficando instalado em paralelo no
  # Ubuntu. A remoção é idempotente e só ocorre quando o pacote realmente existe.
  if dpkg-query -W -f='${Status}' ptyxis 2>/dev/null | grep -Fq 'install ok installed'; then
    log 'removendo terminal duplicado: Ptyxis...'
    sudo apt-get purge -y ptyxis
  fi
}


[[ -f "$AUTO_SOURCE" ]] || fail "script não encontrado: $AUTO_SOURCE"
[[ -f "$PROJECT_INSTALLER" ]] || fail "instalador não encontrado: $PROJECT_INSTALLER"
[[ -f "$PROJECT_RUNNER" ]] || fail "executor de projetos não encontrado: $PROJECT_RUNNER"
[[ -f "$PROJECT_SSH_RUNNER" ]] || fail "executor SSH de projetos não encontrado: $PROJECT_SSH_RUNNER"
[[ -f "$PROJECT_ALL_RUNNER" ]] || fail "executor geral de projetos não encontrado: $PROJECT_ALL_RUNNER"
[[ -d "$ORACLE_MONITOR_DIR" ]] || fail "aplicação não encontrada: $ORACLE_MONITOR_DIR"
[[ -f "$VOICE_COMMANDS_SOURCE" ]] || fail "aplicação não encontrada: $VOICE_COMMANDS_SOURCE"
[[ -f "$GPT_CONSOLE_SOURCE" ]] || fail "aplicação não encontrada: $GPT_CONSOLE_SOURCE"
[[ -f "$AMAZON_IMAP_BOT_SOURCE" ]] || fail "aplicação não encontrada: $AMAZON_IMAP_BOT_SOURCE"
[[ -f "$AMAZON_IMAP_BOT_AUTO_STATUS_SOURCE" ]] || fail "integração AUTO status não encontrada: $AMAZON_IMAP_BOT_AUTO_STATUS_SOURCE"
[[ -f "$SCRIPT_DEV_AUTOMATION_SOURCE" ]] || fail "aplicação não encontrada: $SCRIPT_DEV_AUTOMATION_SOURCE"
[[ -f "$CHROMES_SOURCE" ]] || fail "script não encontrado: $CHROMES_SOURCE"
[[ -f "$CHROMES_ALL_SOURCE" ]] || fail "script não encontrado: $CHROMES_ALL_SOURCE"
[[ -f "$CHROMES_CLOSE_SOURCE" ]] || fail "script não encontrado: $CHROMES_CLOSE_SOURCE"
[[ -f "$FILES_SOURCE" ]] || fail "script não encontrado: $FILES_SOURCE"
[[ -f "$FILES_ALL_SOURCE" ]] || fail "script não encontrado: $FILES_ALL_SOURCE"
[[ -f "$FILES_CLOSE_SOURCE" ]] || fail "script não encontrado: $FILES_CLOSE_SOURCE"
[[ -f "$TERMINALS_SOURCE" ]] || fail "script não encontrado: $TERMINALS_SOURCE"
[[ -f "$TERMINALS_CLOSE_SOURCE" ]] || fail "script não encontrado: $TERMINALS_CLOSE_SOURCE"
[[ -f "$CHATGPTS_SOURCE" ]] || fail "script não encontrado: $CHATGPTS_SOURCE"
[[ -f "$PHPSTORMS_SOURCE" ]] || fail "script não encontrado: $PHPSTORMS_SOURCE"
[[ -f "$PYCHARMS_SOURCE" ]] || fail "script não encontrado: $PYCHARMS_SOURCE"
[[ -f "$PYCHARMS_CLOSE_SOURCE" ]] || fail "script não encontrado: $PYCHARMS_CLOSE_SOURCE"
[[ -f "$PHPSTORM_DEV_SOURCE" ]] || fail "script não encontrado: $PHPSTORM_DEV_SOURCE"
[[ -f "$DEV_MANAGER_SOURCE" ]] || fail "script não encontrado: $DEV_MANAGER_SOURCE"
[[ -f "$DESKTOPS_SOURCE" ]] || fail "script não encontrado: $DESKTOPS_SOURCE"
[[ -f "$LOCAL_NGINX_SOURCE" ]] || fail "script não encontrado: $LOCAL_NGINX_SOURCE"
[[ -f "$DEV_STATUS_SOURCE" ]] || fail "script não encontrado: $DEV_STATUS_SOURCE"
[[ -f "$CLEAR_TERMINAL_SOURCE" ]] || fail "script não encontrado: $CLEAR_TERMINAL_SOURCE"
[[ -f "$DEV_GITSETUP_SOURCE" ]] || fail "script não encontrado: $DEV_GITSETUP_SOURCE"
[[ -f "$G512_RGB_SOURCE" ]] || fail "script não encontrado: $G512_RGB_SOURCE"
[[ -f "$GLOBAL_SHORTCUTS_SOURCE" ]] || fail "gerenciador de atalhos não encontrado: $GLOBAL_SHORTCUTS_SOURCE"
[[ -f "$GLOBAL_AUTO_RUNNER" ]] || fail "supervisor AUTO não encontrado: $GLOBAL_AUTO_RUNNER"
[[ -f "$LRDP_TUI_SOURCE" ]] || fail "script não encontrado: $LRDP_TUI_SOURCE"
[[ -f "$LRDP1_SOURCE" ]] || fail "script não encontrado: $LRDP1_SOURCE"
[[ -f "$LRDP2_SOURCE" ]] || fail "script não encontrado: $LRDP2_SOURCE"

mkdir -p "$TARGET_DIR"
normalize_ubuntu_terminal
chmod +x "$GLOBAL_AUTO_RUNNER" "$VOICE_COMMANDS_SOURCE" "$GPT_CONSOLE_SOURCE" "$AMAZON_IMAP_BOT_SOURCE" "$AMAZON_IMAP_BOT_AUTO_STATUS_SOURCE" "$SCRIPT_DEV_AUTOMATION_SOURCE" "$G512_RGB_SOURCE" "$GLOBAL_SHORTCUTS_SOURCE" "$DEV_GITSETUP_SOURCE" "$AUTO_SOURCE" "$PROJECT_INSTALLER" "$PROJECT_RUNNER" "$PROJECT_SSH_RUNNER" "$PROJECT_ALL_RUNNER" "$CHROMES_SOURCE" "$CHROMES_ALL_SOURCE" "$FILES_SOURCE" "$FILES_ALL_SOURCE" "$TERMINALS_SOURCE" "$CHATGPTS_SOURCE" "$PHPSTORMS_SOURCE" "$PYCHARMS_SOURCE" "$PHPSTORM_DEV_SOURCE" "$DEV_MANAGER_SOURCE" "$DESKTOPS_SOURCE" "$LOCAL_NGINX_SOURCE" "$DEV_STATUS_SOURCE" "$CLEAR_TERMINAL_SOURCE" "$LRDP_TUI_SOURCE" "$LRDP1_SOURCE" "$LRDP2_SOURCE"

rm -f "$AUTO_TARGET"
cat > "$AUTO_TARGET" <<EOF_WRAPPER
#!/usr/bin/env bash
# generated-by: dev-automation-global-command
bash "$CLEAR_TERMINAL_SOURCE"
exec bash "$AUTO_SOURCE" "\$@"
EOF_WRAPPER
chmod +x "$AUTO_TARGET"
log "criado: auto-code-manager -> $AUTO_SOURCE"

LEGACY_DEV_AUTOMATION_TARGET="$TARGET_DIR/dev-automation"
if [[ -f "$LEGACY_DEV_AUTOMATION_TARGET" ]] && grep -qF 'generated-by: dev-automation-global-command' "$LEGACY_DEV_AUTOMATION_TARGET"; then
  rm -f "$LEGACY_DEV_AUTOMATION_TARGET"
  log "removido comando legado: dev-automation"
fi

DEV_GITSETUP_TARGET="$TARGET_DIR/dev-gitsetup"
rm -f "$DEV_GITSETUP_TARGET"
cat > "$DEV_GITSETUP_TARGET" <<EOF_WRAPPER
#!/usr/bin/env bash
# generated-by: dev-automation-global-command
exec python3 "$DEV_GITSETUP_SOURCE" "\$@"
EOF_WRAPPER
chmod +x "$DEV_GITSETUP_TARGET"
log "criado: dev-gitsetup -> $DEV_GITSETUP_SOURCE"

AMAZON_IMAP_BOT_AUTO_STATUS_TARGET="$TARGET_DIR/amazon-imap-bot-auto-status"
rm -f "$AMAZON_IMAP_BOT_AUTO_STATUS_TARGET"
cat > "$AMAZON_IMAP_BOT_AUTO_STATUS_TARGET" <<EOF_WRAPPER
#!/usr/bin/env bash
# generated-by: dev-automation-global-command
exec bash "$AMAZON_IMAP_BOT_AUTO_STATUS_SOURCE" "\$@"
EOF_WRAPPER
chmod +x "$AMAZON_IMAP_BOT_AUTO_STATUS_TARGET"
log "criado: amazon-imap-bot-auto-status -> $AMAZON_IMAP_BOT_AUTO_STATUS_SOURCE"

LEGACY_DIGITAR_DATA_HORA_TARGET="$TARGET_DIR/digitar-data-hora"
if [[ -f "$LEGACY_DIGITAR_DATA_HORA_TARGET" ]] && grep -qF 'generated-by: dev-automation-global-command' "$LEGACY_DIGITAR_DATA_HORA_TARGET"; then
  rm -f "$LEGACY_DIGITAR_DATA_HORA_TARGET"
  log "removido comando legado: digitar-data-hora"
fi

rm -f "$GLOBAL_SHORTCUTS_TARGET"
cat > "$GLOBAL_SHORTCUTS_TARGET" <<EOF_WRAPPER
#!/usr/bin/env bash
# generated-by: dev-automation-global-command
exec bash "$GLOBAL_SHORTCUTS_SOURCE" "\$@"
EOF_WRAPPER
chmod +x "$GLOBAL_SHORTCUTS_TARGET"
log "criado: Global-Shortcuts -> $GLOBAL_SHORTCUTS_SOURCE"
GLOBAL_SHORTCUTS_COMMAND="$GLOBAL_SHORTCUTS_TARGET" "$GLOBAL_SHORTCUTS_TARGET" ensure

for command_name in chromes chromes-all chromes-close files files-all files-close terminals terminals-close chatgpts phpstorms pycharms pycharms-close phpstorm-dev dev-manager desktops local-nginx dev-status g512-rgb voice-commands gpt-console amazon-imap-bot script-dev-automation; do
  case "$command_name" in
    chromes) source_file="$CHROMES_SOURCE" ;;
    chromes-all) source_file="$CHROMES_ALL_SOURCE" ;;
    chromes-close) source_file="$CHROMES_CLOSE_SOURCE" ;;
    files) source_file="$FILES_SOURCE" ;;
    files-all) source_file="$FILES_ALL_SOURCE" ;;
    files-close) source_file="$FILES_CLOSE_SOURCE" ;;
    terminals) source_file="$TERMINALS_SOURCE" ;;
    terminals-close) source_file="$TERMINALS_CLOSE_SOURCE" ;;
    chatgpts) source_file="$CHATGPTS_SOURCE" ;;
    phpstorms) source_file="$PHPSTORMS_SOURCE" ;;
    pycharms) source_file="$PYCHARMS_SOURCE" ;;
    pycharms-close) source_file="$PYCHARMS_CLOSE_SOURCE" ;;
    phpstorm-dev) source_file="$PHPSTORM_DEV_SOURCE" ;;
    dev-manager) source_file="$DEV_MANAGER_SOURCE" ;;
    desktops) source_file="$DESKTOPS_SOURCE" ;;
    local-nginx) source_file="$LOCAL_NGINX_SOURCE" ;;
    dev-status) source_file="$DEV_STATUS_SOURCE" ;;
    g512-rgb) source_file="$G512_RGB_SOURCE" ;;
    voice-commands) source_file="$VOICE_COMMANDS_SOURCE" ;;
    gpt-console) source_file="$GPT_CONSOLE_SOURCE" ;;
    amazon-imap-bot) source_file="$AMAZON_IMAP_BOT_SOURCE" ;;
    script-dev-automation) source_file="$SCRIPT_DEV_AUTOMATION_SOURCE" ;;
  esac
  target_file="$TARGET_DIR/$command_name"

  rm -f "$target_file"
  cat > "$target_file" <<EOF_WRAPPER
#!/usr/bin/env bash
# generated-by: dev-automation-global-command
bash "$CLEAR_TERMINAL_SOURCE"
exec bash "$source_file" "\$@"
EOF_WRAPPER
  chmod +x "$target_file"
  log "criado: $command_name -> $source_file"

  auto_target_file="$TARGET_DIR/$command_name-auto"
  case "$command_name" in
    amazon-imap-bot)
      # O AUTO acompanha o subaplicativo completo e relança o launcher local.
      watch_dir="$AMAZON_IMAP_BOT_DIR"
      ;;
    *)
      case "$source_file" in
        "$PROJECT_ROOT"/apps/*)
          watch_dir="$(dirname -- "$source_file")"
          ;;
        *)
          watch_dir="$PROJECT_ROOT"
          ;;
      esac
      ;;
  esac
  # Comandos globais AUTO são isolados pelo diretório exato. Em especial,
  # dev-manager-auto não reinicia quando o ZIP pertence a subprojeto cadastrado.
  restart_descendants=0
  auto_exec_file="$source_file"
  if [[ "$command_name" == "dev-manager" ]]; then
    # O AUTO do Dev Manager supervisiona o próprio comando global dev-manager.
    # Assim cada reinício usa exatamente o wrapper dev-manager recém-instalado/atualizado.
    auto_exec_file="dev-manager"
  fi
  rm -f "$auto_target_file"
  cat > "$auto_target_file" <<EOF_AUTO_WRAPPER
#!/usr/bin/env bash
# generated-by: dev-automation-global-command
bash "$CLEAR_TERMINAL_SOURCE"
exec bash "$GLOBAL_AUTO_RUNNER" "$command_name" "$auto_exec_file" "$watch_dir" "$restart_descendants" "\$@"
EOF_AUTO_WRAPPER
  chmod +x "$auto_target_file"
  log "criado: $command_name-auto -> monitora $watch_dir"
done

ORACLE_MONITOR_TARGET="$TARGET_DIR/oracle-monitor"
rm -f "$ORACLE_MONITOR_TARGET"
cat > "$ORACLE_MONITOR_TARGET" <<EOF_WRAPPER
#!/usr/bin/env bash
# generated-by: dev-automation-global-command
exec bash "$PROJECT_RUNNER" "oracle-monitor" "$ORACLE_MONITOR_DIR" "local" "\$@"
EOF_WRAPPER
chmod +x "$ORACLE_MONITOR_TARGET"
log "criado: oracle-monitor -> $ORACLE_MONITOR_DIR"
ORACLE_MONITOR_AUTO_TARGET="$TARGET_DIR/oracle-monitor-auto"
rm -f "$ORACLE_MONITOR_AUTO_TARGET"
cat > "$ORACLE_MONITOR_AUTO_TARGET" <<EOF_WRAPPER
#!/usr/bin/env bash
# generated-by: dev-automation-global-command
exec bash "$PROJECT_RUNNER" "oracle-monitor-auto" "$ORACLE_MONITOR_DIR" "local" "\$@"
EOF_WRAPPER
chmod +x "$ORACLE_MONITOR_AUTO_TARGET"
log "criado: oracle-monitor-auto -> $ORACLE_MONITOR_DIR"

LRDP_TUI_TARGET="$TARGET_DIR/lrdp"
rm -f "$LRDP_TUI_TARGET"
cat > "$LRDP_TUI_TARGET" <<EOF_WRAPPER
#!/usr/bin/env bash
# generated-by: dev-automation-global-command
if [[ ! -f "$LRDP_TUI_SOURCE" ]]; then
  printf '[lrdp] ERRO: TUI do projeto não encontrada: %s\n' "$LRDP_TUI_SOURCE" >&2
  exit 1
fi
exec bash "$LRDP_TUI_SOURCE" "\$@"
EOF_WRAPPER
chmod +x "$LRDP_TUI_TARGET"
log "criado: lrdp -> $LRDP_TUI_SOURCE"
LRDP_TUI_AUTO_TARGET="$TARGET_DIR/lrdp-auto"
rm -f "$LRDP_TUI_AUTO_TARGET"
cat > "$LRDP_TUI_AUTO_TARGET" <<EOF_WRAPPER
#!/usr/bin/env bash
# generated-by: dev-automation-global-command
exec bash "$GLOBAL_AUTO_RUNNER" "lrdp" "$LRDP_TUI_SOURCE" "$LRDP_DIR" "0" "\$@"
EOF_WRAPPER
chmod +x "$LRDP_TUI_AUTO_TARGET"
log "criado: lrdp-auto -> monitora $LRDP_DIR"

# lrdp1/lrdp2 continuam atalhos diretos. Qualquer futuro lrdp3/lrdp4...
# em apps/lrdp também ganha comando global automaticamente.
declare -a lrdp_sources=("$LRDP1_SOURCE" "$LRDP2_SOURCE")
while IFS= read -r lrdp_extra; do
  [[ -n "$lrdp_extra" ]] || continue
  case "$(basename "$lrdp_extra")" in
    lrdp1|lrdp2) continue ;;
  esac
  lrdp_sources+=("$lrdp_extra")
done < <(find "$LRDP_DIR" -maxdepth 1 -type f -regextype posix-extended -regex '.*/lrdp[0-9]+' -print 2>/dev/null | sort -V)

for lrdp_source in "${lrdp_sources[@]}"; do
  [[ -f "$lrdp_source" ]] || continue
  lrdp_name="$(basename "$lrdp_source")"
  lrdp_target="$TARGET_DIR/$lrdp_name"
  rm -f "$lrdp_target"
  cat > "$lrdp_target" <<EOF_WRAPPER
#!/usr/bin/env bash
# generated-by: dev-automation-global-command
if [[ ! -f "$lrdp_source" ]]; then
  printf '[$lrdp_name] ERRO: comando do projeto não encontrado: %s\n' "$lrdp_source" >&2
  exit 1
fi
exec bash "$lrdp_source" "\$@"
EOF_WRAPPER
  chmod +x "$lrdp_target"
  log "criado: $lrdp_name -> $lrdp_source"

  lrdp_auto_target="$TARGET_DIR/$lrdp_name-auto"
  rm -f "$lrdp_auto_target"
  cat > "$lrdp_auto_target" <<EOF_WRAPPER
#!/usr/bin/env bash
# generated-by: dev-automation-global-command
exec bash "$GLOBAL_AUTO_RUNNER" "$lrdp_name" "$lrdp_source" "$LRDP_DIR" "0" "\$@"
EOF_WRAPPER
  chmod +x "$lrdp_auto_target"
  log "criado: $lrdp_name-auto -> monitora $LRDP_DIR"
done

TARGET_DIR="$TARGET_DIR" CODE_ROOT="$CODE_ROOT" "$PROJECT_INSTALLER"

PATH_LINE='export PATH="$HOME/.local/bin:$PATH"'
if ! grep -qxF "$PATH_LINE" "$HOME/.bashrc" 2>/dev/null; then
  printf '\n%s\n' "$PATH_LINE" >> "$HOME/.bashrc"
  log 'PATH adicionado ao ~/.bashrc'
fi

export PATH="$TARGET_DIR:$PATH"
hash -r 2>/dev/null || true

printf '\nInstalação concluída com execução direta em primeiro plano.\n'
printf 'No terminal atual, execute:\n  source ~/.bashrc\n\n'
printf 'Testes:\n  command -v dev-gitsetup\n  command -v auto-code-manager\n  command -v dev-manager\n  command -v chromes\n  command -v chromes-all\n  command -v chromes-close\n  command -v files\n  command -v files-all\n  command -v files-close\n  command -v terminals\n  command -v terminals-close\n  command -v chatgpts\n  command -v phpstorms\n  command -v pycharms\n  command -v pycharms-close\n  command -v phpstorm-dev\n  command -v local-nginx\n  command -v dev-status\n  command -v g512-rgb\n  command -v voice-commands\n  command -v gpt-console\n  command -v script-dev-automation\n  command -v Global-Shortcuts\n  command -v oracle-monitor\n  command -v lrdp\n  command -v lrdp1\n  command -v lrdp2\n  command -v local-all\n  command -v remote-all\n  phpstorms --list\n  pycharms --list\n  orbital-app help\n  station-app dir\n'
