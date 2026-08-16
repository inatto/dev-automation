#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
ARCHIVER="$ROOT/apps/worker-sync/scripts/delete-from-watch.sh"
DOWNLOADER="$ROOT/apps/worker-sync/scripts/download-from.sh"
RUNTIME="$ROOT/scripts/dev-manager/60-project-runtime.sh"
README="$ROOT/apps/worker-sync/README.md"

bash -n "$ARCHIVER"
bash -n "$DOWNLOADER"
grep -Fq 'remote_backup="$REMOTE_DIR/backup/$archive_name"' "$ARCHIVER"
grep -Fq 'archive_name="${stem}--${stamp}--PROCESSED.zip"' "$ARCHIVER"
grep -Fq 'moveto "$remote_source" "$remote_backup"' "$ARCHIVER"
grep -Fq -- "--exclude '/backup/**'" "$DOWNLOADER"
grep -Fq 'worker_from_zip_has_purpose' "$RUNTIME"
grep -Fq '<projeto>--<o-que-faz>.zip' "$README"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/from" "$TMP/bin"
touch "$TMP/from/dev-automation--worker-from-backup-esteira.zip"
cat > "$TMP/bin/inotifywait" <<EOF_INOTIFY
#!/usr/bin/env bash
printf 'DELETE|%s/from/dev-automation--worker-from-backup-esteira.zip\n' '$TMP'
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
WORKER_ARCHIVE_STAMP='20260816-195500' \
RCLONE_BIN="$TMP/bin/rclone" \
INOTIFYWAIT_BIN="$TMP/bin/inotifywait" \
bash "$ARCHIVER" >/dev/null

grep -Fq 'mkdir fake:worker/from/backup' "$TMP/rclone.log"
grep -Fq 'moveto fake:worker/from/dev-automation--worker-from-backup-esteira.zip fake:worker/from/backup/dev-automation--worker-from-backup-esteira--20260816-195500--PROCESSED.zip' "$TMP/rclone.log"

echo 'OK: worker/from vira fila; processados vão para backup remoto com projeto+finalidade+timestamp'
