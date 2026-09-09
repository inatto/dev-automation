#!/usr/bin/env bash
# Shared helpers for local process/port lifecycle.

runtime_listener_pids() {
  local port="$1"
  fuser -n tcp "$port" 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9]+$' || true
}


runtime_process_running() {
  local pid="$1"
  local state
  state="$(ps -o stat= -p "$pid" 2>/dev/null | awk '{print $1}' || true)"
  [[ -n "$state" && "$state" != Z* ]]
}

runtime_pgid() {
  local pid="$1"
  ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ' || true
}

runtime_cmd() {
  local pid="$1"
  ps -o args= -p "$pid" 2>/dev/null || true
}

runtime_cwd() {
  local pid="$1"
  readlink -f "/proc/$pid/cwd" 2>/dev/null || true
}

runtime_is_under_root() {
  local pid="$1"
  local root="$2"
  local cwd
  cwd="$(runtime_cwd "$pid")"
  [[ -n "$cwd" && ( "$cwd" == "$root" || "$cwd" == "$root/"* ) ]]
}

runtime_group_is_safe_for_root() {
  local pgid="$1"
  local root="$2"
  [[ "$pgid" =~ ^[0-9]+$ ]] || return 1
  runtime_is_under_root "$pgid" "$root"
}

runtime_stop_port_owner() {
  local port="$1"
  local root="$2"
  local label="$3"
  local pids=() foreign=() groups=() direct=()
  local pid pgid seen

  mapfile -t pids < <(runtime_listener_pids "$port")
  ((${#pids[@]})) || return 0

  for pid in "${pids[@]}"; do
    if ! runtime_is_under_root "$pid" "$root"; then
      foreign+=("$pid")
    fi
  done

  if ((${#foreign[@]})); then
    echo "$label não pode iniciar: porta $port ocupada por processo externo." >&2
    for pid in "${foreign[@]}"; do
      echo "  PID $pid | cwd=$(runtime_cwd "$pid") | $(runtime_cmd "$pid")" >&2
    done
    return 1
  fi

  echo "$label: instância local anterior detectada na porta $port; encerrando de forma controlada..."
  for pid in "${pids[@]}"; do
    pgid="$(runtime_pgid "$pid")"
    if [[ -n "$pgid" ]] && runtime_group_is_safe_for_root "$pgid" "$root"; then
      seen=0
      for existing in "${groups[@]}"; do [[ "$existing" == "$pgid" ]] && seen=1; done
      [[ "$seen" -eq 1 ]] || groups+=("$pgid")
    else
      direct+=("$pid")
    fi
  done

  for pgid in "${groups[@]}"; do kill -TERM -- "-$pgid" 2>/dev/null || true; done
  for pid in "${direct[@]}"; do kill -TERM "$pid" 2>/dev/null || true; done

  for _ in {1..40}; do
    mapfile -t pids < <(runtime_listener_pids "$port")
    ((${#pids[@]} == 0)) && return 0
    sleep 0.1
  done

  echo "$label: processo anterior não encerrou em 4s; forçando apenas processos desta aplicação." >&2
  mapfile -t pids < <(runtime_listener_pids "$port")
  for pid in "${pids[@]}"; do
    runtime_is_under_root "$pid" "$root" || continue
    pgid="$(runtime_pgid "$pid")"
    if [[ -n "$pgid" ]] && runtime_group_is_safe_for_root "$pgid" "$root"; then
      kill -KILL -- "-$pgid" 2>/dev/null || true
    else
      kill -KILL "$pid" 2>/dev/null || true
    fi
  done

  for _ in {1..20}; do
    mapfile -t pids < <(runtime_listener_pids "$port")
    ((${#pids[@]} == 0)) && return 0
    sleep 0.1
  done

  echo "$label: porta $port continuou ocupada após tentativa de limpeza." >&2
  return 1
}

runtime_port_owned_by_group() {
  local port="$1"
  local expected_pgid="$2"
  local pid pgid
  while read -r pid; do
    [[ -n "$pid" ]] || continue
    pgid="$(runtime_pgid "$pid")"
    [[ "$pgid" == "$expected_pgid" ]] && return 0
  done < <(runtime_listener_pids "$port")
  return 1
}

runtime_wait_http_owned() {
  local pid="$1"
  local port="$2"
  local url="$3"
  local label="$4"
  local attempts="${5:-40}"
  local pgid

  pgid="$(runtime_pgid "$pid")"
  [[ -n "$pgid" ]] || pgid="$pid"

  for ((i=1; i<=attempts; i++)); do
    runtime_process_running "$pid" || {
      echo "$label encerrou durante a inicialização." >&2
      return 1
    }
    if curl -fsS --max-time 2 "$url" >/dev/null 2>&1 && runtime_port_owned_by_group "$port" "$pgid"; then
      return 0
    fi
    sleep 1
  done

  echo "$label não ficou pronta na porta $port." >&2
  return 1
}

runtime_stop_session() {
  local pid="$1"
  local label="$2"
  local tenths="${3:-35}"

  kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
  for ((i=1; i<=tenths; i++)); do
    runtime_process_running "$pid" || { wait "$pid" 2>/dev/null || true; return 0; }
    sleep 0.1
  done

  echo "$label não encerrou; forçando sessão local PID $pid." >&2
  kill -KILL -- "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
}
