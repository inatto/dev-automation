#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
ARCHIVER="$ROOT/apps/worker-sync/scripts/delete-from-watch.sh"
DOWNLOADER="$ROOT/apps/worker-sync/scripts/download-from.sh"
IMPORTS="$ROOT/scripts/dev-manager/70-imports.sh"
README="$ROOT/apps/worker-sync/README.md"

bash -n "$ARCHIVER"
bash -n "$DOWNLOADER"
bash -n "$IMPORTS"
grep -Fq 'archive_worker_from_zip()' "$IMPORTS"
grep -Fq 'mv -- "$zip_file" "$archive_path"' "$IMPORTS"
grep -Fq 'ZIP ARQUIVADO LOCALMENTE:' "$IMPORTS"
grep -Fq 'copy "$REMOTE_BACKUP" "$BACKUP_DIR"' "$ARCHIVER"
grep -Fq 'copy "$BACKUP_DIR" "$REMOTE_BACKUP"' "$ARCHIVER"
grep -Fq 'copyto "$archive_path" "$remote_target"' "$ARCHIVER"
grep -Fq 'deletefile "$remote_source"' "$ARCHIVER"
grep -Fq -- "--exclude '/backup/**'" "$DOWNLOADER"
grep -Fq '<projeto>--<finalidade>.zip' "$README"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/from/backup" "$TMP/bin"
printf 'payload\n' > "$TMP/from/dev-automation--worker-from-backup-esteira.zip"

# Exercita a regra principal: o manager move localmente para backup, não apaga.
log() { :; }
worker_from_dir() { printf '%s\n' "$TMP/from"; }
# shellcheck source=/dev/null
source "$IMPORTS"
WORKER_ARCHIVE_STAMP='20260816-195500' \
archive_worker_from_zip "$TMP/from/dev-automation--worker-from-backup-esteira.zip" PROCESSED
LOCAL_ARCHIVE="$TMP/from/backup/dev-automation--worker-from-backup-esteira--20260816-195500--PROCESSED.zip"
[ -f "$LOCAL_ARCHIVE" ]
[ ! -e "$TMP/from/dev-automation--worker-from-backup-esteira.zip" ]
grep -Fxq 'payload' "$LOCAL_ARCHIVE"

cat > "$TMP/bin/inotifywait" <<EOF_INOTIFY
#!/usr/bin/env bash
printf 'MOVED_TO|%s/from/backup/dev-automation--worker-from-backup-esteira--20260816-195500--PROCESSED.zip\n' '$TMP'
EOF_INOTIFY
cat > "$TMP/bin/rclone" <<'EOF_RCLONE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$RCLONE_LOG"
exit 0
EOF_RCLONE
chmod +x "$TMP/bin/inotifywait" "$TMP/bin/rclone"

RCLONE_LOG="$TMP/rclone.log" \
WORKER_LOCAL_FROM="$TMP/from" \
WORKER_REMOTE_FROM='fake:worker/from' \
RCLONE_BIN="$TMP/bin/rclone" \
INOTIFYWAIT_BIN="$TMP/bin/inotifywait" \
bash "$ARCHIVER" >/dev/null

grep -Fq "copy fake:worker/from/backup $TMP/from/backup" "$TMP/rclone.log"
grep -Fq "copy $TMP/from/backup fake:worker/from/backup" "$TMP/rclone.log"
grep -Fq "copyto $LOCAL_ARCHIVE fake:worker/from/backup/dev-automation--worker-from-backup-esteira--20260816-195500--PROCESSED.zip" "$TMP/rclone.log"
grep -Fq 'deletefile fake:worker/from/dev-automation--worker-from-backup-esteira.zip' "$TMP/rclone.log"

echo 'OK: worker/from move local -> backup local -> backup Drive; raízes ficam limpas e histórico é reconciliado'
