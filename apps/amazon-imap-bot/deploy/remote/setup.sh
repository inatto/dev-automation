#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"; TARGET_FILE="${DEPLOY_TARGET_FILE:-$SCRIPT_DIR/target.conf}"; source "$TARGET_FILE"
SSH=(-i "$DEPLOY_SSH_KEY" -o BatchMode=yes -o ConnectTimeout=15 -o ServerAliveInterval=30 -o ServerAliveCountMax=120)
[[ -f "$DEPLOY_SSH_KEY" ]] || { echo "Chave SSH não encontrada: $DEPLOY_SSH_KEY" >&2; exit 1; }
echo "Enviando Amazon IMAP Bot para $DEPLOY_REMOTE_HOST:$DEPLOY_REMOTE_ROOT..."
ssh "${SSH[@]}" "$DEPLOY_REMOTE_HOST" "mkdir -p $(printf '%q' "$DEPLOY_REMOTE_ROOT") $(printf '%q' "$DEPLOY_REMOTE_CONFIG_DIR")"
rsync -az --delete --itemize-changes -e "ssh ${SSH[*]}" --exclude='.git/' --exclude='apps/api/.venv/' --exclude='apps/web/node_modules/' --exclude='apps/web/.astro/' --exclude='apps/web/dist/' --exclude='__pycache__/' --exclude='*.pyc' "$ROOT_DIR/" "$DEPLOY_REMOTE_HOST:$DEPLOY_REMOTE_ROOT/"
rsync -az --itemize-changes -e "ssh ${SSH[*]}" "$DEPLOY_LOCAL_CONFIG_DIR/" "$DEPLOY_REMOTE_HOST:$DEPLOY_REMOTE_CONFIG_DIR/"
"$SCRIPT_DIR/setup-api.sh"
"$SCRIPT_DIR/setup-web.sh"
echo "Deploy remoto concluído."
