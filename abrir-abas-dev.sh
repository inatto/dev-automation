#!/usr/bin/env bash
# cd /home/daniel/Code/sind-infra/deploy
set -euo pipefail

# Abre, na MESMA janela do Windows Terminal, uma aba WSL para cada projeto
# e inicia o comando local correspondente.
#
# COMO RODAR
# 1. Entre na raiz do projeto:
#      cd ~/Code/sind-infra
# 2. Na primeira vez, dê permissão de execução:
#      chmod +x deploy/abrir-abas-dev.sh
# 3. Execute:
#      ./deploy/abrir-abas-dev.sh
#
# ORDEM E COMANDOS INICIADOS
# 1. Sind Infra:  ./deploy/auto-code-manager.sh
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

open_tab "Sind Infra" \
  "$CODE_ROOT/sind-infra" \
  "./deploy/auto-code-manager.sh"

open_tab "SINPROPREV" \
  "$CODE_ROOT/site-sinproprev-v2" \
  "./deploy/local.dev.sh"

open_tab "Murm App" \
  "$CODE_ROOT/murm-app" \
  "flutter run -d linux"

open_tab "ASAClub" \
  "$CODE_ROOT/site-asaclub-2026" \
  "./deploy/local.dev.sh"

open_tab "Site Inst" \
  "$CODE_ROOT/site-inst" \
  "./deploy/local.dev.sh anpprev"
