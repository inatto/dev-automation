#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
MANAGER="$PROJECT_ROOT/scripts/auto-code-manager.sh"

assert_match() {
  local filename="$1"
  local expected="$2"
  local actual

  actual="$($MANAGER --identify-zip "$filename")"
  if [ "$actual" != "$expected" ]; then
    printf 'FALHOU: %s -> esperado=%s atual=%s\n' "$filename" "$expected" "$actual" >&2
    exit 1
  fi

  printf 'OK: %s -> %s\n' "$filename" "$actual"
}

assert_rejected() {
  local filename="$1"

  if "$MANAGER" --identify-zip "$filename" >/dev/null 2>&1; then
    printf 'FALHOU: deveria rejeitar %s\n' "$filename" >&2
    exit 1
  fi

  printf 'OK rejeitado: %s\n' "$filename"
}

assert_match 'dev-automation.zip' 'bots/dev-automation'
assert_match 'dev-automation(15).zip' 'bots/dev-automation'
assert_match 'dev-automation%23232-3434.zip' 'bots/dev-automation'
assert_match 'dev-automation#23232-3434.zip' 'bots/dev-automation'
assert_match 'DEV-AUTOMATION%20copy.ZIP' 'bots/dev-automation'
assert_match 'orbital-reports[11].zip' 'orgs/orbital/orbital-reports'

assert_rejected 'dev-automation2.zip'
assert_rejected 'dev-automationXYZ.zip'
assert_rejected 'unknown%23232.zip'
