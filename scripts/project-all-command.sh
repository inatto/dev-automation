#!/usr/bin/env bash
# cd /home/daniel/Code/bots/dev-automation

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
CLEAR_TERMINAL="$SCRIPT_DIR/clear-terminal.sh"

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
done < "$PROJECTS_FILE"

total="${#project_commands[@]}"
if ((total == 0)); then
  printf '[%s] nenhum projeto ativo possui deploy %s.\n' "$COMMAND_NAME" "$DEPLOY_MODE"
  exit 0
fi

action="${1:-setup}"

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
  local state_base run_id log_dir log_file pid current
  state_base="${XDG_STATE_HOME:-$HOME/.local/state}/dev-automation/local-all"
  run_id="$(date '+%Y%m%d-%H%M%S')-$$"
  log_dir="$state_base/$run_id"
  mkdir -p "$log_dir"

  printf '[%s] %d projeto(s) ativo(s); iniciando setup local em paralelo.\n' "$COMMAND_NAME" "$total"
  printf '[%s] logs: %s\n' "$COMMAND_NAME" "$log_dir"

  for ((i = 0; i < total; i += 1)); do
    current=$((i + 1))
    log_file="$log_dir/${project_names[$i]}.log"

    nohup env DEV_AUTOMATION_SKIP_CLEAR=1 "${project_commands[$i]}" "$@" \
      >"$log_file" 2>&1 </dev/null &
    pid=$!
    disown "$pid" 2>/dev/null || true

    printf '[%s] [%d/%d] disparado: %s (PID %d)\n' \
      "$COMMAND_NAME" "$current" "$total" "${project_names[$i]}" "$pid"
  done

  printf '\n[%s] %d inicialização(ões) disparadas em paralelo; terminal liberado.\n' "$COMMAND_NAME" "$total"
}

run_local_parallel_wait() {
  local state_base run_id log_dir log_file pid current status final_status
  local -a pids=() logs=()

  state_base="${XDG_STATE_HOME:-$HOME/.local/state}/dev-automation/local-all"
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
elif [[ "$action" == "setup" ]]; then
  run_local_setup_detached "$@"
else
  run_local_parallel_wait "$@"
fi
