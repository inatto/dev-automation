#!/usr/bin/env bash
# Espelha SOMENTE remoções locais de ~/worker/from para o remoto worker/from.
# Arquivos locais novos/alterados NUNCA são enviados ao Drive.

LOCAL_DIR="${WORKER_LOCAL_FROM:-/home/daniel/worker/from}"
REMOTE_DIR="${WORKER_REMOTE_FROM:-danielmaiax:worker/from}"
RCLONE_BIN="${RCLONE_BIN:-/usr/bin/rclone}"
INOTIFYWAIT_BIN="${INOTIFYWAIT_BIN:-/usr/bin/inotifywait}"
LOCK_FILE="${WORKER_FROM_LOCK_FILE:-${XDG_RUNTIME_DIR:-/tmp}/dev-automation-worker-from.lock}"

log() { printf '[worker-sync][from-delete] [%s] %s\n' "$(date '+%F %T')" "$*"; }

mkdir -p "$LOCAL_DIR"
log "MONITORANDO REMOÇÕES: $LOCAL_DIR"

"$INOTIFYWAIT_BIN" \
  --monitor \
  --recursive \
  --quiet \
  --event delete,moved_from \
  --format '%e|%w%f' \
  "$LOCAL_DIR" |
while IFS='|' read -r events removed; do
  case ",$events," in
    *,ISDIR,*) continue ;;
  esac

  rel="${removed#"$LOCAL_DIR"/}"
  [ -n "$rel" ] || continue
  remote="$REMOTE_DIR/$rel"

  log "DELETE LOCAL DETECTADO: $removed"
  log "APAGANDO REMOTO: $remote"

  # O mesmo lock é usado pelo downloader para impedir corrida entre download
  # e remoção remota do item que acabou de ser processado localmente.
  if command -v flock >/dev/null 2>&1; then
    if flock "$LOCK_FILE" "$RCLONE_BIN" deletefile "$remote" --log-level ERROR; then
      log "OK - REMOTO APAGADO: $remote"
    else
      log "AVISO - não foi possível apagar remoto (pode já ter sido removido): $remote"
    fi
  else
    if "$RCLONE_BIN" deletefile "$remote" --log-level ERROR; then
      log "OK - REMOTO APAGADO: $remote"
    else
      log "AVISO - não foi possível apagar remoto (pode já ter sido removido): $remote"
    fi
  fi
done
