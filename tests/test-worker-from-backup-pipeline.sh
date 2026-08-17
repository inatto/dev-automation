#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
DOWNLOADER="$ROOT/apps/worker-sync/scripts/download-from.sh"
ARCHIVER="$ROOT/apps/worker-sync/scripts/delete-from-watch.sh"
STATE_LIB="$ROOT/apps/worker-sync/scripts/from-state.sh"

bash -n "$DOWNLOADER"
bash -n "$ARCHIVER"
bash -n "$STATE_LIB"
grep -Fq 'moveto "$REMOTE_DIR/$original" "$processing"' "$DOWNLOADER"
grep -Fq 'copyto "$processing" "$staged"' "$DOWNLOADER"
grep -Fq 'deletefile "$processing"' "$ARCHIVER"
grep -Fq 'worker_from_claim_attach_archive' "$ROOT/scripts/dev-manager/70-imports.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/remote" "$TMP/local" "$TMP/state"

cat > "$TMP/bin/rclone" <<'RCLONE'
#!/usr/bin/env bash
set -euo pipefail
cmd="$1"; shift
args=(); recursive=false
while [ "$#" -gt 0 ]; do
  case "$1" in
    --log-level|--contimeout|--timeout|--retries|--low-level-retries|--max-depth) shift 2 ;;
    --files-only|--create-empty-src-dirs) shift ;;
    --recursive) recursive=true; shift ;;
    --*) shift ;;
    *) args+=("$1"); shift ;;
  esac
done
case "$cmd" in
  mkdir) mkdir -p -- "${args[0]}" ;;
  lsf)
    p="${args[0]}"; [ -d "$p" ] || exit 1
    if [ "$recursive" = true ]; then find "$p" -type f -printf '%P\n' | sort
    else find "$p" -maxdepth 1 -type f -printf '%f\n' | sort; fi ;;
  moveto) mkdir -p -- "$(dirname -- "${args[1]}")"; mv -- "${args[0]}" "${args[1]}" ;;
  copyto) mkdir -p -- "$(dirname -- "${args[1]}")"; cp -- "${args[0]}" "${args[1]}" ;;
  copy) mkdir -p -- "${args[1]}"; [ ! -d "${args[0]}" ] || cp -a "${args[0]}"/. "${args[1]}"/ 2>/dev/null || true ;;
  md5sum) [ -f "${args[0]}" ] && md5sum -- "${args[0]}" || find "${args[0]}" -type f -print0 | xargs -0 -r md5sum ;;
  deletefile) rm -f -- "${args[0]}" ;;
  rmdir) rmdir -- "${args[0]}" ;;
  *) exit 2 ;;
esac
RCLONE
chmod +x "$TMP/bin/rclone"
cat > "$TMP/bin/inotifywait" <<'INOTIFY'
#!/usr/bin/env bash
sleep 1
[ -z "${TEST_EVENT_PATH:-}" ] || printf 'MOVED_TO|%s\n' "$TEST_EVENT_PATH"
INOTIFY
chmod +x "$TMP/bin/inotifywait"

ENVV=(
  "WORKER_REMOTE_FROM=$TMP/remote"
  "WORKER_LOCAL_FROM=$TMP/local"
  "WORKER_SYNC_STATE_DIR=$TMP/state"
  "RCLONE_BIN=$TMP/bin/rclone"
  "TIMEOUT_BIN=/usr/bin/timeout"
  "WORKER_FROM_LIST_TIMEOUT=5"
  "WORKER_FROM_MOVE_TIMEOUT=5"
  "WORKER_FROM_DOWNLOAD_TIMEOUT=5"
)

printf 'A\n' > "$TMP/remote/dev-automation.zip"
env "${ENVV[@]}" "$DOWNLOADER" >/dev/null
[ -f "$TMP/local/dev-automation.zip" ]
[ ! -f "$TMP/remote/dev-automation.zip" ]

# Nova versão de mesmo nome chega antes da versão A terminar o backup.
printf 'B\n' > "$TMP/remote/dev-automation.zip"
env "${ENVV[@]}" "$DOWNLOADER" >/dev/null
grep -qx A "$TMP/local/dev-automation.zip"
grep -qx B "$TMP/remote/dev-automation.zip"

export WORKER_SYNC_STATE_DIR="$TMP/state"
# shellcheck source=/dev/null
source "$STATE_LIB"
archive='dev-automation--20260817-021500--PROCESSED.zip'
worker_from_claim_attach_archive dev-automation.zip "$archive" "$TMP/local/dev-automation.zip" >/dev/null
mkdir -p "$TMP/local/backup"
mv "$TMP/local/dev-automation.zip" "$TMP/local/backup/$archive"

env "${ENVV[@]}" INOTIFYWAIT_BIN="$TMP/bin/inotifywait" TEST_EVENT_PATH="$TMP/local/backup/$archive" WORKER_FROM_BACKUP_NETWORK_TIMEOUT=5 \
  /usr/bin/timeout 8s "$ARCHIVER" >/dev/null || true

# Finalizar A remove apenas .processing de A. A versão B da raiz sobrevive.
grep -qx B "$TMP/remote/dev-automation.zip"
[ ! -f "$(worker_from_claim_path dev-automation.zip)" ]
[ -f "$TMP/remote/backup/$archive" ]
if find "$TMP/remote/.processing" -type f -name dev-automation.zip 2>/dev/null | grep -q .; then
  echo 'processing antigo não foi removido' >&2
  exit 1
fi

# Próxima rodada adquire B uma única vez.
env "${ENVV[@]}" "$DOWNLOADER" >/dev/null
grep -qx B "$TMP/local/dev-automation.zip"
[ ! -f "$TMP/remote/dev-automation.zip" ]

echo 'OK: claim remoto + .processing eliminam redownload e preservam nova versão de mesmo nome'
