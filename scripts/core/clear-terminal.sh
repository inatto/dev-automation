#!/usr/bin/env bash

set -u

# Limpa somente um terminal interativo real. Em pipes, testes, cron/systemd ou
# TERM ausente/dumb, não emite sequências ANSI nem falha a automação.
if [[ -t 1 && -n "${TERM:-}" && "${TERM:-}" != "dumb" ]] && command -v clear >/dev/null 2>&1; then
  clear || true
fi
