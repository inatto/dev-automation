#!/usr/bin/env bash
sleep 0.20
export YDOTOOL_SOCKET="/run/ydotool-dm.sock"
exec /usr/bin/ydotool type --key-delay 2 "$(date '+%Y%m%d-%H%M')"
