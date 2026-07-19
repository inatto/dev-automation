#!/usr/bin/env bash
# cd /home/daniel/Code/dev-automation
set -euo pipefail

# Abre, na MESMA janela do Windows Terminal, uma aba WSL para cada projeto
# e inicia o comando local correspondente.
#
# COMO RODAR
# 1. Entre na raiz do projeto:
#      cd ~/Code/dev-automation
# 2. Na primeira vez, dê permissão de execução:
#      chmod +x abrir-abas-dev.sh
# 3. Execute:
#      ./abrir-abas-dev.sh
#
# ORDEM E COMANDOS INICIADOS
# 1. Dev Automation: ./auto-code-manager.sh
# 2. SINPROPREV:  ./deploy/local.dev.sh
# 3. Murm App:    flutter run -d linux
# 4. ASAClub:     ./deploy/local.dev.sh
# 5. Site Inst:   ./deploy/local.dev.sh anpprev
#
# Cada chamada é separada para evitar problemas de aspas entre Bash,
# Windows Terminal e wsl.exe.

DISTRO="${WSL_DISTRO_NAME:-Ubuntu-22.04-D}"
PROFILE="Ubuntu-22.04-D"
CODE_ROOT="/home/daniel/Code"

open_tab() {
  local title="$1"
  local directory="$2"
  local command="$3"

  wt.exe -w 0 new-tab \
    --profile "$PROFILE" \
    --title "$title" \
    --suppressApplicationTitle \
    wsl.exe -d "$DISTRO" --cd "$directory" -- \
    bash -lc "$command; exec bash"
}

open_tab "Dev Automation" \
  "$CODE_ROOT/dev-automation" \
  "./auto-code-manager.sh"

open_tab "SINPROPREV" \
  "$CODE_ROOT/sindicatto/site-sinproprev-v2" \
  "./deploy/local.dev.sh"

open_tab "Murm App" \
  "$CODE_ROOT/siteverso/murm-app" \
  "flutter run -d linux"

open_tab "ASAClub" \
  "$CODE_ROOT/sindicatto/asaclub-app" \
  "./deploy/local.dev.sh"

open_tab "Site Inst" \
  "$CODE_ROOT/sindicatto/inst-app" \
  "./deploy/local.dev.sh anpprev"
