#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
DOWNLOADER="$ROOT/apps/worker-sync/scripts/download-from.sh"
ARCHIVER="$ROOT/apps/worker-sync/scripts/delete-from-watch.sh"

bash -n "$DOWNLOADER"
bash -n "$ARCHIVER"
grep -Fq 'copyto "$remote_source" "$staged"' "$DOWNLOADER"
! grep -Eq 'REMOTE_PROCESSING|moveto .*REMOTE_DIR' "$DOWNLOADER"
grep -Fq 'copyto "$archive_path" "$remote_backup_target"' "$ARCHIVER"
grep -Fq 'deletefile "$remote_source"' "$ARCHIVER"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/remote/backup" "$TMP/local/backup"

cat > "$TMP/bin/rclone" <<'RCLONE'
#!/usr/bin/env bash
set -euo pipefail
cmd="$1"; shift
args=(); recursive=false
while [ "$#" -gt 0 ]; do
  case "$1" in
    --log-level|--contimeout|--timeout|--retries|--low-level-retries|--max-depth) shift 2 ;;
    --files-only|--create-empty-src-dirs|--no-traverse) shift ;;
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
  copyto) mkdir -p -- "$(dirname -- "${args[1]}")"; cp -- "${args[0]}" "${args[1]}" ;;
  copy) mkdir -p -- "${args[1]}"; [ ! -d "${args[0]}" ] || cp -a "${args[0]}"/. "${args[1]}"/ 2>/dev/null || true ;;
  md5sum) [ -f "${args[0]}" ] && md5sum -- "${args[0]}" || find "${args[0]}" -type f -print0 | xargs -0 -r md5sum ;;
  deletefile) rm -f -- "${args[0]}" ;;
  *) exit 2 ;;
esac
RCLONE
chmod +x "$TMP/bin/rclone"
cat > "$TMP/bin/inotifywait" <<'INOTIFY'
#!/usr/bin/env bash
sleep 1
[ -z "${TEST_EVENT_PATH:-}" ] || printf '%s\n' "$TEST_EVENT_PATH"
INOTIFY
chmod +x "$TMP/bin/inotifywait"

ENVV=(
  "WORKER_REMOTE_FROM=$TMP/remote"
  "WORKER_LOCAL_FROM=$TMP/local"
  "RCLONE_BIN=$TMP/bin/rclone"
  "TIMEOUT_BIN=/usr/bin/timeout"
  "WORKER_FROM_LIST_TIMEOUT=5"
  "WORKER_FROM_DOWNLOAD_TIMEOUT=5"
)

name='dev-automation-worker-nome-unico.zip'
printf 'VERSAO-A\n' > "$TMP/remote/$name"
env "${ENVV[@]}" "$DOWNLOADER" >/dev/null
[ -f "$TMP/local/$name" ]
grep -qx 'VERSAO-A' "$TMP/local/$name"
[ -f "$TMP/remote/$name" ]

# O dev-manager move o MESMO nome para backup.
mv "$TMP/local/$name" "$TMP/local/backup/$name"

# Mesmo antes da limpeza remota, o downloader não baixa de novo porque o nome
# já existe no backup local.
env "${ENVV[@]}" "$DOWNLOADER" >/dev/null
[ ! -f "$TMP/local/$name" ]
[ -f "$TMP/local/backup/$name" ]

# Backup watcher sobe o mesmo nome e só então limpa a raiz remota.
env "${ENVV[@]}" INOTIFYWAIT_BIN="$TMP/bin/inotifywait" TEST_EVENT_PATH="$TMP/local/backup/$name" WORKER_FROM_BACKUP_NETWORK_TIMEOUT=5 \
  /usr/bin/timeout 8s "$ARCHIVER" >/dev/null || true

[ -f "$TMP/remote/backup/$name" ]
grep -qx 'VERSAO-A' "$TMP/remote/backup/$name"
[ ! -f "$TMP/remote/$name" ]
[ -f "$TMP/local/backup/$name" ]

# Nenhum estágio inventa outro nome.
[ "$(find "$TMP/local/backup" -maxdepth 1 -type f -printf '%f\n')" = "$name" ]
[ "$(find "$TMP/remote/backup" -maxdepth 1 -type f -printf '%f\n')" = "$name" ]

echo 'OK: baixou -> usou -> moveu local -> subiu, sempre com o mesmo nome'
