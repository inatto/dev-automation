#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
[[ -x "$ROOT/scripts/pycharms.sh" ]]
[[ -x "$ROOT/scripts/pycharms/windows.sh" ]]
[[ -x "$ROOT/scripts/pycharms/ubuntu.sh" ]]
[[ -x "$ROOT/scripts/chromes.sh" ]]
[[ -x "$ROOT/scripts/chromes/windows.sh" ]]
[[ -x "$ROOT/scripts/chromes/ubuntu.sh" ]]
[[ -x "$ROOT/scripts/files.sh" ]]
[[ -x "$ROOT/scripts/files/windows.sh" ]]
[[ -x "$ROOT/scripts/files/ubuntu.sh" ]]
grep -q 'PowerShell do Windows' "$ROOT/scripts/pycharms/windows.sh"
grep -q 'PowerShell do Windows' "$ROOT/scripts/chromes/windows.sh"
! grep -q '/mnt/c/' "$ROOT/scripts/pycharms/ubuntu.sh"
! grep -q '/mnt/c/' "$ROOT/scripts/chromes/ubuntu.sh"
! grep -q '/mnt/c/' "$ROOT/scripts/files/ubuntu.sh"
printf 'OK: pycharms/chromes/files têm entrada única e backends Windows/Ubuntu separados.\n'
