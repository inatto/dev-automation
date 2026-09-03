#!/usr/bin/env bash
set -euo pipefail
ROOT="$1"; CONFIG_ROOT="$2"; SERVICE="$3"; COMPONENT="$4"
case "$COMPONENT" in
  api)
    cat <<EOF | sudo tee "/etc/systemd/system/$SERVICE" >/dev/null
[Unit]
Description=Amazon IMAP Bot API
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
User=ubuntu
WorkingDirectory=$ROOT/apps/api
Environment=AMAZON_IMAP_BOT_CONFIG_ENV=production
Environment=AMAZON_IMAP_BOT_CONFIG_ROOT=$CONFIG_ROOT
ExecStart=$ROOT/apps/api/.venv/bin/python $ROOT/apps/api/main.py
Restart=always
RestartSec=3
[Install]
WantedBy=multi-user.target
EOF
    ;;
  web)
    cat <<EOF | sudo tee "/etc/systemd/system/$SERVICE" >/dev/null
[Unit]
Description=Amazon IMAP Bot Web
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
User=ubuntu
WorkingDirectory=$ROOT/apps/web
Environment=AMAZON_IMAP_BOT_WEB_ENV=production
Environment=NODE_ENV=production
ExecStart=/usr/bin/node $ROOT/apps/web/dist/server/entry.mjs
Restart=always
RestartSec=3
[Install]
WantedBy=multi-user.target
EOF
    ;;
  *) echo "Componente inválido: $COMPONENT" >&2; exit 1;;
esac
sudo systemctl daemon-reload
sudo systemctl enable "$SERVICE" >/dev/null
