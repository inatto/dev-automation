#!/usr/bin/env bash
# cd /home/daniel/Code/bots/dev-automation

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
CLEAR_TERMINAL="$SCRIPT_DIR/clear-terminal.sh"
LOCAL_WORKER="$SCRIPT_DIR/local-all-worker.sh"

COMMAND_NAME="${1:-}"
DEPLOY_MODE="${2:-}"
PROJECTS_FILE="${3:-}"
CODE_ROOT="${4:-/home/daniel/Code}"
COMMAND_DIR="${5:-$HOME/.local/bin}"
shift 5 || true

fail() {
  printf '[%s] ERRO: %s\n' "${COMMAND_NAME:-project-all}" "$*" >&2
  exit 1
}

[[ -n "$COMMAND_NAME" ]] || fail "nome do comando não informado"
[[ "$DEPLOY_MODE" == "local" || "$DEPLOY_MODE" == "remote" ]] || fail "modo de deploy inválido: $DEPLOY_MODE"
[[ -f "$PROJECTS_FILE" ]] || fail "arquivo de projetos não encontrado: $PROJECTS_FILE"
[[ -d "$CODE_ROOT" ]] || fail "raiz de código não encontrada: $CODE_ROOT"
[[ -d "$COMMAND_DIR" ]] || fail "diretório de comandos não encontrado: $COMMAND_DIR"

[[ -f "$CLEAR_TERMINAL" ]] && bash "$CLEAR_TERMINAL"

project_commands=()
project_names=()
project_dirs=()

while IFS= read -r raw_line || [[ -n "$raw_line" ]]; do
  line="${raw_line%%#*}"
  line="$(printf '%s' "$line" | xargs)"
  [[ -n "$line" ]] || continue

  project_dir="$CODE_ROOT/$line"
  project_name="$(basename "$line")"

  if [[ ! -d "$project_dir" ]]; then
    printf '[%s] ignorado; pasta não existe: %s\n' "$COMMAND_NAME" "$project_dir"
    continue
  fi

  if [[ ! -f "$project_dir/deploy/$DEPLOY_MODE/setup.sh" ]]; then
    printf '[%s] ignorado; sem deploy/%s/setup.sh: %s\n' "$COMMAND_NAME" "$DEPLOY_MODE" "$line"
    continue
  fi

  if [[ "$DEPLOY_MODE" == "remote" ]]; then
    project_command="remote-$project_name"
  else
    project_command="$project_name"
  fi
  command_path="$COMMAND_DIR/$project_command"
  [[ -x "$command_path" ]] || fail "comando global ausente: $project_command (execute 'dev-manager commands')"

  project_commands+=("$command_path")
  project_names+=("$project_command")
  project_dirs+=("$project_dir")
done < "$PROJECTS_FILE"

total="${#project_commands[@]}"
if ((total == 0)); then
  printf '[%s] nenhum projeto ativo possui deploy %s.\n' "$COMMAND_NAME" "$DEPLOY_MODE"
  exit 0
fi

action="${1:-setup}"

local_state_base() {
  printf '%s/dev-automation/local-all' "${XDG_STATE_HOME:-$HOME/.local/state}"
}

local_latest_dir() {
  local base latest
  base="$(local_state_base)"
  latest="$base/latest"
  [[ -f "$latest" ]] || return 1
  local run_id
  run_id="$(cat "$latest" 2>/dev/null || true)"
  [[ -n "$run_id" && -d "$base/$run_id" ]] || return 1
  printf '%s/%s\n' "$base" "$run_id"
}

status_for_project() {
  local run_dir="$1" name="$2" raw pid status_file pid_file
  status_file="$run_dir/$name.status"
  pid_file="$run_dir/$name.pid"
  raw="$(cat "$status_file" 2>/dev/null || true)"
  pid="$(cat "$pid_file" 2>/dev/null || true)"

  case "$raw" in
    OK) printf 'OK' ;;
    STOPPED) printf 'PARADO' ;;
    ERRO:*) printf 'ERRO(%s)' "${raw#ERRO:}" ;;
    STARTING|'')
      if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
        printf 'RODANDO'
      elif [[ "$raw" == "STARTING" ]]; then
        printf 'ERRO(?)'
      else
        printf 'DESCONHECIDO'
      fi
      ;;
    *) printf '%s' "$raw" ;;
  esac
}

show_local_status_once() {
  local label="${1:-local-status-all}" run_dir state pid log_file last_line
  local ok=0 running=0 errors=0 stopped=0 unknown=0

  if ! run_dir="$(local_latest_dir)"; then
    printf '[%s] nenhuma execução local-all registrada ainda.\n' "$label"
    return 0
  fi

  printf '[%s] execução: %s\n' "$label" "$run_dir"
  for ((i = 0; i < total; i += 1)); do
    state="$(status_for_project "$run_dir" "${project_names[$i]}")"
    pid="$(cat "$run_dir/${project_names[$i]}.pid" 2>/dev/null || true)"
    log_file="$run_dir/${project_names[$i]}.log"
    last_line="$(tail -n 1 "$log_file" 2>/dev/null | tr '\r\n' ' ' | cut -c1-160 || true)"

    case "$state" in
      OK) ok=$((ok + 1)) ;;
      RODANDO) running=$((running + 1)) ;;
      PARADO) stopped=$((stopped + 1)) ;;
      ERRO*) errors=$((errors + 1)) ;;
      *) unknown=$((unknown + 1)) ;;
    esac

    if [[ -n "$pid" ]]; then
      printf '[%s] %-11s %-24s PID %-7s' "$label" "$state" "${project_names[$i]}" "$pid"
    else
      printf '[%s] %-11s %-24s' "$label" "$state" "${project_names[$i]}"
    fi
    [[ -n "$last_line" ]] && printf ' | %s' "$last_line"
    printf '\n'
  done
  printf '[%s] resumo: %d RODANDO | %d OK | %d ERRO | %d PARADO | %d OUTRO\n' \
    "$label" "$running" "$ok" "$errors" "$stopped" "$unknown"
  printf '[%s] logs: %s\n' "$label" "$run_dir"
}

run_local_status() {
  local mode="${2:-${1:-}}"
  if [[ "$mode" == "watch" || "$mode" == "--watch" || "$mode" == "-w" ]]; then
    while true; do
      if [[ -t 1 && -n "${TERM:-}" && "${TERM:-dumb}" != "dumb" ]]; then
        printf '\033[H\033[2J'
      fi
      show_local_status_once "$COMMAND_NAME"
      printf '[%s] atualizando a cada 1s; Ctrl+C para sair.\n' "$COMMAND_NAME"
      sleep 1
    done
  fi
  show_local_status_once "$COMMAND_NAME"
}

run_remote_parallel() {
  local state_base run_id log_dir log_file status_file pid current final_status status ok_count fail_count
  local -a pids=() status_files=()

  state_base="${XDG_STATE_HOME:-$HOME/.local/state}/dev-automation/remote-all"
  run_id="$(date '+%Y%m%d-%H%M%S')-$$"
  log_dir="$state_base/$run_id"
  mkdir -p "$log_dir"

  printf '[%s] %d projeto(s) ativo(s) com deploy remote; execução paralela.\n' "$COMMAND_NAME" "$total"
  printf '[%s] logs: %s\n' "$COMMAND_NAME" "$log_dir"

  for ((i = 0; i < total; i += 1)); do
    current=$((i + 1))
    log_file="$log_dir/${project_names[$i]}.log"
    status_file="$log_dir/${project_names[$i]}.status"
    status_files+=("$status_file")

    printf '[%s] [%d/%d] INICIANDO: %s\n' \
      "$COMMAND_NAME" "$current" "$total" "${project_names[$i]}"

    (
      set +e
      DEV_AUTOMATION_SKIP_CLEAR=1 "${project_commands[$i]}" "$@" 2>&1 | \
        while IFS= read -r line || [[ -n "$line" ]]; do
          printf '[%s] %s\n' "${project_names[$i]}" "$line"
          printf '%s\n' "$line" >> "$log_file"
        done
      status=${PIPESTATUS[0]}
      printf '%d\n' "$status" > "$status_file"
      if ((status == 0)); then
        printf '[%s] OK\n' "${project_names[$i]}"
      else
        printf '[%s] ERRO (%d)\n' "${project_names[$i]}" "$status" >&2
      fi
      exit "$status"
    ) &
    pid=$!
    pids+=("$pid")
  done

  final_status=0
  for ((i = 0; i < total; i += 1)); do
    if wait "${pids[$i]}"; then
      :
    else
      status=$?
      ((final_status == 0)) && final_status=$status
    fi
  done

  ok_count=0
  fail_count=0
  printf '\n========== %s RESUMO ==========\n' "$COMMAND_NAME"
  for ((i = 0; i < total; i += 1)); do
    if [[ -f "${status_files[$i]}" ]]; then
      status="$(cat "${status_files[$i]}")"
    else
      status=125
      ((final_status == 0)) && final_status=$status
    fi

    if [[ "$status" == "0" ]]; then
      printf 'OK    %s\n' "${project_names[$i]}"
      ok_count=$((ok_count + 1))
    else
      printf 'ERRO  %s (código %s)\n' "${project_names[$i]}" "$status"
      fail_count=$((fail_count + 1))
    fi
  done
  printf '=================================\n'
  printf '[%s] %d OK | %d ERRO | logs: %s\n' "$COMMAND_NAME" "$ok_count" "$fail_count" "$log_dir"

  if ((final_status != 0)); then
    exit "$final_status"
  fi
}

run_local_setup_detached() {
  local state_base run_id log_dir log_file status_file pid_file pid current
  state_base="$(local_state_base)"
  run_id="$(date '+%Y%m%d-%H%M%S')-$$"
  log_dir="$state_base/$run_id"
  mkdir -p "$log_dir"
  printf '%s\n' "$run_id" > "$state_base/latest"

  [[ -x "$LOCAL_WORKER" ]] || fail "worker local não encontrado: $LOCAL_WORKER"

  printf '[%s] %d projeto(s) ativo(s); iniciando setup local em paralelo.\n' "$COMMAND_NAME" "$total"
  printf '[%s] logs: %s\n' "$COMMAND_NAME" "$log_dir"

  for ((i = 0; i < total; i += 1)); do
    current=$((i + 1))
    log_file="$log_dir/${project_names[$i]}.log"
    status_file="$log_dir/${project_names[$i]}.status"
    pid_file="$log_dir/${project_names[$i]}.pid"
    : > "$log_file"
    printf 'STARTING\n' > "$status_file"

    setsid nohup "$LOCAL_WORKER" "$status_file" "$log_file" "${project_names[$i]}" \
      env DEV_AUTOMATION_SKIP_CLEAR=1 "${project_commands[$i]}" "$@" \
      </dev/null >/dev/null 2>&1 &
    pid=$!
    printf '%d\n' "$pid" > "$pid_file"
    disown "$pid" 2>/dev/null || true

    printf '[%s] [%d/%d] INICIANDO: %s (PID %d)\n' \
      "$COMMAND_NAME" "$current" "$total" "${project_names[$i]}" "$pid"
  done

  sleep "${LOCAL_ALL_FEEDBACK_DELAY:-1}"
  printf '\n'
  show_local_status_once "$COMMAND_NAME"
  printf '\n[%s] terminal liberado. Acompanhe ao vivo: local-status-all watch\n' "$COMMAND_NAME"
  printf '[%s] para tudo: local-stop-all\n' "$COMMAND_NAME"
}

run_local_stop_all() {
  local run_dir="" log_file pid status_file current stop_status final_status killed
  local -a pids=() names=() result_files=()

  run_dir="$(local_latest_dir 2>/dev/null || true)"
  printf '[%s] %d projeto(s); parando em paralelo.\n' "$COMMAND_NAME" "$total"

  final_status=0
  for ((i = 0; i < total; i += 1)); do
    current=$((i + 1))
    printf '[%s] [%d/%d] PARANDO: %s\n' "$COMMAND_NAME" "$current" "$total" "${project_names[$i]}"
    result_file="$(mktemp)"
    result_files+=("$result_file")
    names+=("${project_names[$i]}")

    (
      set +e
      stop_status=0
      killed=0

      if [[ -f "${project_dirs[$i]}/deploy/local/stop.sh" ]]; then
        DEV_AUTOMATION_SKIP_CLEAR=1 "${project_commands[$i]}" stop >"${result_file}.log" 2>&1
        stop_status=$?
      fi

      if [[ -n "$run_dir" ]]; then
        pid="$(cat "$run_dir/${project_names[$i]}.pid" 2>/dev/null || true)"
        status_file="$run_dir/${project_names[$i]}.status"
        if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
          kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
          killed=1
          for _ in 1 2 3 4 5; do
            kill -0 "$pid" 2>/dev/null || break
            sleep 0.1
          done
          if kill -0 "$pid" 2>/dev/null; then
            kill -KILL -- "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
          fi
        fi
        printf 'STOPPED\n' > "$status_file"
      fi

      if [[ -f "${project_dirs[$i]}/deploy/local/stop.sh" && "$stop_status" -ne 0 && "$killed" -eq 0 ]]; then
        printf 'ERRO:%d\n' "$stop_status" > "$result_file"
        exit "$stop_status"
      fi
      printf 'OK\n' > "$result_file"
      exit 0
    ) &
    pids+=("$!")
  done

  for ((i = 0; i < total; i += 1)); do
    if wait "${pids[$i]}"; then
      printf '[%s] OK: %s\n' "$COMMAND_NAME" "${names[$i]}"
    else
      stop_status=$?
      ((final_status == 0)) && final_status=$stop_status
      printf '[%s] ERRO (%d): %s\n' "$COMMAND_NAME" "$stop_status" "${names[$i]}" >&2
      [[ -f "${result_files[$i]}.log" ]] && tail -n 20 "${result_files[$i]}.log" >&2 || true
    fi
    rm -f "${result_files[$i]}" "${result_files[$i]}.log"
  done

  printf '[%s] parada concluída.\n' "$COMMAND_NAME"
  [[ -n "$run_dir" ]] && show_local_status_once "$COMMAND_NAME"
  ((final_status == 0)) || exit "$final_status"
}

run_local_parallel_wait() {
  local state_base run_id log_dir log_file pid current status final_status
  local -a pids=() logs=()

  state_base="$(local_state_base)"
  run_id="$(date '+%Y%m%d-%H%M%S')-$$"
  log_dir="$state_base/$run_id"
  mkdir -p "$log_dir"

  printf '[%s] %d projeto(s) ativo(s); executando "%s" em paralelo.\n' "$COMMAND_NAME" "$total" "$action"

  for ((i = 0; i < total; i += 1)); do
    current=$((i + 1))
    log_file="$log_dir/${project_names[$i]}.log"
    logs+=("$log_file")

    DEV_AUTOMATION_SKIP_CLEAR=1 "${project_commands[$i]}" "$@" >"$log_file" 2>&1 &
    pid=$!
    pids+=("$pid")
    printf '[%s] [%d/%d] iniciado: %s (PID %d)\n' \
      "$COMMAND_NAME" "$current" "$total" "${project_names[$i]}" "$pid"
  done

  final_status=0
  for ((i = 0; i < total; i += 1)); do
    current=$((i + 1))
    if wait "${pids[$i]}"; then
      status=0
    else
      status=$?
      ((final_status == 0)) && final_status=$status
    fi

    printf '\n[%s] [%d/%d] log: %s\n' "$COMMAND_NAME" "$current" "$total" "${project_names[$i]}"
    cat "${logs[$i]}"

    if ((status == 0)); then
      printf '[%s] [%d/%d] OK: %s\n' "$COMMAND_NAME" "$current" "$total" "${project_names[$i]}"
    else
      printf '[%s] [%d/%d] FALHOU (%d): %s\n' \
        "$COMMAND_NAME" "$current" "$total" "$status" "${project_names[$i]}" >&2
    fi
  done

  if ((final_status != 0)); then
    printf '\n[%s] concluído com falha; logs: %s\n' "$COMMAND_NAME" "$log_dir" >&2
    exit "$final_status"
  fi

  printf '\n[%s] concluído: %d/%d projeto(s).\n' "$COMMAND_NAME" "$total" "$total"
}

if [[ "$DEPLOY_MODE" == "remote" ]]; then
  run_remote_parallel "$@"
elif [[ "$action" == "__status" ]]; then
  run_local_status "$@"
elif [[ "$action" == "__stop" ]]; then
  run_local_stop_all
elif [[ "$action" == "setup" ]]; then
  run_local_setup_detached "$@"
else
  run_local_parallel_wait "$@"
fi
