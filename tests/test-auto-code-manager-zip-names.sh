#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
MANAGER="$PROJECT_ROOT/scripts/auto-code-manager.sh"
TEMP="$(mktemp -d /tmp/auto-code-zip-names-XXXXXX)"
CODE_ROOT="$TEMP/Code"
PROJECTS_FILE="$TEMP/projects"
HOME_DIR="$TEMP/home"
trap 'rm -rf -- "$TEMP"' EXIT

mkdir -p \
  "$HOME_DIR" \
  "$CODE_ROOT/bots/dev-automation/apps/amazon-imap-bot" \
  "$CODE_ROOT/orgs/orbital/orbital-reports"
cat > "$PROJECTS_FILE" <<'PROJECTS'
bots/dev-automation
bots/dev-automation/apps/amazon-imap-bot
orgs/orbital.zip
orgs/orbital/orbital-reports
PROJECTS

identify_zip() {
  HOME="$HOME_DIR" CODE_ROOT="$CODE_ROOT" DEV_MANAGER_PROJECTS_FILE="$PROJECTS_FILE" \
    "$MANAGER" --identify-zip "$1"
}

assert_match() {
  local filename="$1"
  local expected="$2"
  local actual

  actual="$(identify_zip "$filename")"
  if [ "$actual" != "$expected" ]; then
    printf 'FALHOU: %s -> esperado=%s atual=%s\n' "$filename" "$expected" "$actual" >&2
    exit 1
  fi

  printf 'OK: %s -> %s\n' "$filename" "$actual"
}

assert_rejected() {
  local filename="$1"

  if identify_zip "$filename" >/dev/null 2>&1; then
    printf 'FALHOU: deveria rejeitar %s\n' "$filename" >&2
    exit 1
  fi

  printf 'OK rejeitado: %s\n' "$filename"
}

assert_match 'dev-automation.zip' 'bots/dev-automation'
assert_match 'dev-automation--worker-from-backup-esteira.zip' 'bots/dev-automation'
assert_match 'dev-automation(15).zip' 'bots/dev-automation'
assert_match 'dev-automation%23232-3434.zip' 'bots/dev-automation'
assert_match 'dev-automation#23232-3434.zip' 'bots/dev-automation'
assert_match 'DEV-AUTOMATION%20copy.ZIP' 'bots/dev-automation'
assert_match 'dev-automation-amazon-imap-bot.zip' 'bots/dev-automation/apps/amazon-imap-bot'
assert_match 'dev-automation-amazon-imap-bot--resposta-gpt.zip' 'bots/dev-automation/apps/amazon-imap-bot'
assert_match 'dev-automation--amazon-imap-bot.zip' 'bots/dev-automation/apps/amazon-imap-bot'
assert_match 'amazon-imap-bot.zip' 'bots/dev-automation/apps/amazon-imap-bot'
assert_match 'orbital-reports[11].zip' 'orgs/orbital/orbital-reports'

assert_rejected 'dev-automation2.zip'
assert_rejected 'dev-automationXYZ.zip'
assert_rejected 'unknown%23232.zip'
assert_match 'orbital.zip' 'orgs/orbital.zip'
assert_match 'orbital(2).zip' 'orgs/orbital.zip'
