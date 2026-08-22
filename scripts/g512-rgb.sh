#!/usr/bin/env bash
# Integra o auxiliar RGB do Logitech G512 ao dev-automation.
# Migra uma instalação legada na primeira execução e mantém o helper isolado
# do dev-manager depois disso.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
SYSTEMCTL="${G512_SYSTEMCTL:-systemctl}"
LEGACY_UNIT="${G512_LEGACY_UNIT:-g512-rgb.service}"
UNIT_NAME="${G512_UNIT_NAME:-dev-automation-g512-rgb.service}"
USER_UNIT_DIR="${G512_USER_UNIT_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user}"
STATE_DIR="${G512_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/dev-automation/g512}"
APP_DIR="${G512_APP_DIR:-$PROJECT_ROOT/scripts/g512}"
MAIN_POINTER="$APP_DIR/.main-script"
UNIT_PATH="$USER_UNIT_DIR/$UNIT_NAME"
MIGRATION_META="$APP_DIR/.migrated-from"
VENV_DIR="$STATE_DIR/venv"
REQ_STAMP="$STATE_DIR/requirements.sha256"
OPENRGB_UNIT_NAME="${G512_OPENRGB_UNIT_NAME:-dev-automation-openrgb.service}"
OPENRGB_UNIT_PATH="$USER_UNIT_DIR/$OPENRGB_UNIT_NAME"
OPENRGB_HOST="${G512_OPENRGB_HOST:-127.0.0.1}"
OPENRGB_PORT="${G512_OPENRGB_PORT:-6742}"

log() { printf '[g512-rgb] %s\n' "$*"; }
warn() { printf '[g512-rgb] AVISO: %s\n' "$*" >&2; }
fail() { printf '[g512-rgb] ERRO: %s\n' "$*" >&2; exit 1; }

is_native_linux() {
  [[ "$(uname -s 2>/dev/null || true)" == "Linux" ]] || return 1
  command -v "$SYSTEMCTL" >/dev/null 2>&1 || return 1
  return 0
}

systemctl_user() {
  "$SYSTEMCTL" --user "$@"
}

legacy_fragment() {
  local fragment=""
  fragment="$(systemctl_user show -p FragmentPath --value "$LEGACY_UNIT" 2>/dev/null || true)"
  if [[ -n "$fragment" && -f "$fragment" ]]; then
    printf '%s\n' "$fragment"
    return 0
  fi

  if [[ -f "$USER_UNIT_DIR/$LEGACY_UNIT" ]]; then
    printf '%s\n' "$USER_UNIT_DIR/$LEGACY_UNIT"
    return 0
  fi

  return 1
}

stop_legacy_service() {
  # A unit antiga ficou presa em restart-loop quando o venv sumiu. Sempre a
  # interrompemos antes de qualquer migração para não martelar o user systemd.
  systemctl_user disable --now "$LEGACY_UNIT" >/dev/null 2>&1 || \
    systemctl_user stop "$LEGACY_UNIT" >/dev/null 2>&1 || true
  systemctl_user reset-failed "$LEGACY_UNIT" >/dev/null 2>&1 || true
}

parse_unit_source() {
  local unit_file="$1"
  python3 - "$unit_file" <<'PY'
import os
import shlex
import sys

path = sys.argv[1]
working_dir = ""
exec_lines = []

# Systemd aceita continuação com barra invertida. Para esse helper simples,
# juntar as linhas preserva o suficiente sem executar conteúdo algum.
raw = open(path, "r", encoding="utf-8", errors="replace").read().splitlines()
logical = []
buf = ""
for line in raw:
    if buf:
        line = buf + line.lstrip()
        buf = ""
    if line.rstrip().endswith("\\"):
        buf = line.rstrip()[:-1]
        continue
    logical.append(line)
if buf:
    logical.append(buf)

for line in logical:
    stripped = line.strip()
    if stripped.startswith("WorkingDirectory=") and not working_dir:
        working_dir = stripped.split("=", 1)[1].strip()
        if working_dir.startswith("-"):
            working_dir = working_dir[1:].lstrip()
    elif stripped.startswith("ExecStart="):
        exec_lines.append(stripped.split("=", 1)[1].strip())

working_dir = os.path.expandvars(os.path.expanduser(working_dir))
for cmd in exec_lines:
    if cmd.startswith("-"):
        cmd = cmd[1:].lstrip()
    try:
        argv = shlex.split(cmd, posix=True)
    except ValueError:
        continue
    for arg in argv[1:]:
        expanded = os.path.expandvars(os.path.expanduser(arg))
        if expanded.lower().endswith(".py"):
            if not os.path.isabs(expanded) and working_dir:
                expanded = os.path.join(working_dir, expanded)
            print(os.path.abspath(expanded))
            print(os.path.abspath(working_dir) if working_dir else "")
            raise SystemExit(0)

print("")
print(os.path.abspath(working_dir) if working_dir else "")
PY
}

fallback_discover_source() {
  local working_dir="${1:-}"
  local roots=()
  local candidate=""

  [[ -n "$working_dir" && -d "$working_dir" ]] && roots+=("$working_dir")
  [[ -d "$HOME/Code/playground" ]] && roots+=("$HOME/Code/playground")
  [[ -d "$HOME/Code" ]] && roots+=("$HOME/Code")

  local root
  for root in "${roots[@]}"; do
    candidate="$(find "$root" \
      -maxdepth 5 \
      -type d \( -name .git -o -name .venv -o -name venv -o -name node_modules -o -name __pycache__ \) -prune -o \
      -type f \( -iname '*g512*.py' -o -iname '*rgb*.py' \) -print \
      2>/dev/null | head -n 1 || true)"
    if [[ -n "$candidate" && -f "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

copy_source_bundle() {
  local main_source="$1"
  local source_dir source_base lower_dir
  source_dir="$(cd -- "$(dirname -- "$main_source")" && pwd -P)"
  source_base="$(basename -- "$main_source")"
  lower_dir="$(basename -- "$source_dir" | tr '[:upper:]' '[:lower:]')"

  rm -rf -- "$APP_DIR"
  mkdir -p -- "$APP_DIR"

  if [[ "$lower_dir" == *g512* || "$lower_dir" == *rgb* || "$lower_dir" == *keyboard* ]]; then
    # Diretório claramente dedicado: leva o auxiliar inteiro, sem lixo de IDE,
    # git ou ambientes virtuais.
    tar -C "$source_dir" \
      --exclude='.git' --exclude='.venv' --exclude='venv' \
      --exclude='__pycache__' --exclude='.idea' --exclude='.pytest_cache' \
      --exclude='*.pyc' -cf - . | tar -C "$APP_DIR" -xf -
  else
    # Se o script está solto numa pasta grande (ex.: Code/playground), não
    # sequestramos o playground inteiro. Copiamos o main e arquivos auxiliares
    # típicos do mesmo diretório.
    cp -a -- "$main_source" "$APP_DIR/$source_base"

    # Copia módulos Python locais realmente importados pelo main, em vez de
    # despejar todos os .py de uma pasta grande como Code/playground.
    python3 - "$main_source" "$source_dir" "$APP_DIR" <<'PY_COPY'
import ast
import os
import shutil
import sys
from pathlib import Path

main = Path(sys.argv[1]).resolve()
root = Path(sys.argv[2]).resolve()
dest = Path(sys.argv[3]).resolve()
seen = set()
queue = [main]

def copy_module(name: str):
    if not name:
        return
    top = name.split('.', 1)[0]
    file_candidate = root / f"{top}.py"
    package_candidate = root / top
    if file_candidate.is_file():
        target = dest / file_candidate.name
        if not target.exists():
            shutil.copy2(file_candidate, target)
        queue.append(file_candidate)
    elif (package_candidate / "__init__.py").is_file():
        target = dest / top
        if not target.exists():
            shutil.copytree(
                package_candidate,
                target,
                ignore=shutil.ignore_patterns('__pycache__', '*.pyc', '.pytest_cache'),
            )

while queue:
    path = queue.pop(0)
    if path in seen or not path.is_file():
        continue
    seen.add(path)
    try:
        tree = ast.parse(path.read_text(encoding='utf-8', errors='replace'))
    except (SyntaxError, OSError):
        continue
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            for alias in node.names:
                copy_module(alias.name)
        elif isinstance(node, ast.ImportFrom) and node.level == 0:
            copy_module(node.module or '')
PY_COPY

    find "$source_dir" -maxdepth 1 -type f \
      \( -name 'requirements*.txt' -o -name 'pyproject.toml' \
         -o -name '*.json' -o -name '*.toml' -o -name '*.yaml' -o -name '*.yml' \
         -o -name '*.ini' -o -name '*.conf' \) \
      -exec cp -a -t "$APP_DIR" -- {} + 2>/dev/null || true
  fi

  [[ -f "$APP_DIR/$source_base" ]] || fail "falha ao copiar script legado: $main_source"
  # O serviço deve usar o daemon não-interativo. g512_rgb.py é a UI/loop
  # interativo antigo e exige TTY, portanto não pode ser ExecStart do systemd.
  if [[ -f "$APP_DIR/g512_daemon.py" ]]; then
    printf '%s\n' "g512_daemon.py" > "$MAIN_POINTER"
  else
    printf '%s\n' "$source_base" > "$MAIN_POINTER"
  fi
  {
    printf 'source=%s\n' "$main_source"
    printf 'migrated_at=%s\n' "$(date -Iseconds 2>/dev/null || date)"
  } > "$MIGRATION_META"

  log "auxiliar legado incorporado em $APP_DIR"
}

migrate_legacy_source() {
  [[ -s "$MAIN_POINTER" ]] && return 0

  local fragment source working_dir fallback
  fragment="$(legacy_fragment 2>/dev/null || true)"
  source=""
  working_dir=""

  if [[ -n "$fragment" ]]; then
    mapfile -t parsed < <(parse_unit_source "$fragment")
    source="${parsed[0]:-}"
    working_dir="${parsed[1]:-}"
  fi

  if [[ -z "$source" || ! -f "$source" ]]; then
    fallback="$(fallback_discover_source "$working_dir" 2>/dev/null || true)"
    [[ -n "$fallback" ]] && source="$fallback"
  fi

  if [[ -z "$source" || ! -f "$source" ]]; then
    warn "não encontrei o script legado para migrar; a unit quebrada ficou parada."
    warn "quando o código do G512 estiver acessível, rode: g512-rgb migrate"
    return 1
  fi

  copy_source_bundle "$source"
  return 0
}

main_script_path() {
  [[ -s "$MAIN_POINTER" ]] || return 1
  local relative
  relative="$(head -n 1 "$MAIN_POINTER")"
  [[ -n "$relative" && -f "$APP_DIR/$relative" ]] || return 1
  printf '%s\n' "$APP_DIR/$relative"
}

requirements_file() {
  local candidate
  candidate="$(find "$APP_DIR" -maxdepth 1 -type f -name 'requirements*.txt' -print 2>/dev/null | sort | head -n 1 || true)"
  [[ -n "$candidate" ]] || return 1
  printf '%s\n' "$candidate"
}

ensure_python_runtime() {
  local requirements hash current_hash=""
  requirements="$(requirements_file 2>/dev/null || true)"

  if [[ -z "$requirements" ]]; then
    command -v python3
    return 0
  fi

  mkdir -p -- "$STATE_DIR"
  hash="$(sha256sum "$requirements" | awk '{print $1}')"
  [[ -f "$REQ_STAMP" ]] && current_hash="$(cat "$REQ_STAMP" 2>/dev/null || true)"

  if [[ ! -x "$VENV_DIR/bin/python" || "$hash" != "$current_hash" ]]; then
    rm -rf -- "$VENV_DIR"
    python3 -m venv "$VENV_DIR"
    "$VENV_DIR/bin/python" -m pip install --disable-pip-version-check -r "$requirements" >&2
    printf '%s\n' "$hash" > "$REQ_STAMP"
  fi

  printf '%s\n' "$VENV_DIR/bin/python"
}

sdk_port_ready() {
  timeout 1 bash -c "</dev/tcp/$OPENRGB_HOST/$OPENRGB_PORT" >/dev/null 2>&1
}

openrgb_binary() {
  command -v openrgb 2>/dev/null || command -v OpenRGB 2>/dev/null || true
}

ensure_openrgb_server() {
  if [[ "${G512_SKIP_HARDWARE_CHECK:-0}" == "1" ]]; then
    return 0
  fi
  if sdk_port_ready; then
    return 0
  fi

  local bin
  bin="$(openrgb_binary)"
  [[ -n "$bin" ]] || fail "OpenRGB não está rodando e o executável openrgb/OpenRGB não foi encontrado"

  mkdir -p -- "$USER_UNIT_DIR"
  cat > "$OPENRGB_UNIT_PATH" <<EOF_OPENRGB
[Unit]
Description=Dev Automation - OpenRGB SDK server for Logitech G512
After=graphical-session.target
StartLimitIntervalSec=60
StartLimitBurst=5

[Service]
Type=simple
ExecStart=$bin --server
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
EOF_OPENRGB

  systemctl_user daemon-reload
  systemctl_user enable "$OPENRGB_UNIT_NAME" >/dev/null 2>&1 || true
  systemctl_user restart "$OPENRGB_UNIT_NAME" || fail "não foi possível iniciar o servidor OpenRGB"

  local i
  for i in {1..20}; do
    sdk_port_ready && return 0
    sleep 0.5
  done

  systemctl_user --no-pager --full status "$OPENRGB_UNIT_NAME" >&2 2>/dev/null || true
  fail "OpenRGB não abriu $OPENRGB_HOST:$OPENRGB_PORT"
}

probe_g512() {
  if [[ "${G512_SKIP_HARDWARE_CHECK:-0}" == "1" ]]; then
    return 0
  fi
  local python_bin
  python_bin="$(ensure_python_runtime)" || return 1
  timeout 5 "$python_bin" - <<'PY_G512_PROBE'
from openrgb import OpenRGBClient
c = OpenRGBClient()
if not any("G512" in d.name for d in c.devices):
    raise SystemExit(2)
PY_G512_PROBE
}

run_helper() {
  local main_file python_bin
  main_file="$(main_script_path)" || fail "auxiliar G512 ainda não foi migrado"
  python_bin="$(ensure_python_runtime)" || fail "não foi possível preparar o Python do G512"
  cd -- "$APP_DIR"
  exec "$python_bin" "$main_file"
}

write_unit() {
  mkdir -p -- "$USER_UNIT_DIR"
  cat > "$UNIT_PATH" <<EOF_UNIT
[Unit]
Description=Dev Automation - Logitech G512 RGB helper
After=graphical-session.target
StartLimitIntervalSec=60
StartLimitBurst=5

[Service]
Type=simple
ExecStart=$SCRIPT_DIR/g512-rgb.sh run
Restart=on-failure
RestartSec=5
Environment=PYTHONUNBUFFERED=1

[Install]
WantedBy=default.target
EOF_UNIT
}

archive_and_remove_legacy_unit() {
  local fragment
  fragment="$(legacy_fragment 2>/dev/null || true)"
  [[ -n "$fragment" ]] || return 0

  mkdir -p -- "$STATE_DIR/legacy-unit"
  cp -a -- "$fragment" "$STATE_DIR/legacy-unit/$LEGACY_UNIT" 2>/dev/null || true

  # Só removemos arquivo sob o diretório de units do usuário. Unit de pacote do
  # sistema nunca é apagada por este helper.
  case "$fragment" in
    "$USER_UNIT_DIR"/*)
      rm -f -- "$fragment"
      ;;
  esac
}

install_and_start_unit() {
  ensure_openrgb_server
  if ! probe_g512; then
    fail "OpenRGB está ativo, mas o Logitech G512 não apareceu no SDK"
  fi

  write_unit
  systemctl_user daemon-reload
  systemctl_user enable "$UNIT_NAME" >/dev/null 2>&1 || true
  if ! systemctl_user restart "$UNIT_NAME"; then
    systemctl_user --no-pager --full status "$UNIT_NAME" >&2 2>/dev/null || true
    return 1
  fi

  sleep 0.7
  if ! systemctl_user is-active --quiet "$UNIT_NAME"; then
    warn "$UNIT_NAME caiu logo após iniciar"
    systemctl_user --no-pager --full status "$UNIT_NAME" >&2 2>/dev/null || true
    return 1
  fi
  return 0
}

ensure_all() {
  if ! is_native_linux; then
    log "fora de Linux/systemd; nada a fazer."
    return 0
  fi

  stop_legacy_service

  if [[ -f "$APP_DIR/g512_daemon.py" ]]; then
    printf '%s\n' "g512_daemon.py" > "$MAIN_POINTER"
  elif ! main_script_path >/dev/null 2>&1; then
    migrate_legacy_source || return 1
  fi

  install_and_start_unit || return 1
  archive_and_remove_legacy_unit
  systemctl_user daemon-reload >/dev/null 2>&1 || true
  systemctl_user reset-failed "$LEGACY_UNIT" >/dev/null 2>&1 || true
  log "G512 integrado e independente: $UNIT_NAME"
}

status_all() {
  if ! is_native_linux; then
    log "fora de Linux/systemd."
    return 0
  fi

  local main_file=""
  main_file="$(main_script_path 2>/dev/null || true)"
  if [[ -n "$main_file" ]]; then
    log "código incorporado: $main_file"
  else
    warn "código ainda não incorporado."
  fi
  if sdk_port_ready; then
    log "OpenRGB SDK: $OPENRGB_HOST:$OPENRGB_PORT ativo"
  else
    warn "OpenRGB SDK: $OPENRGB_HOST:$OPENRGB_PORT indisponível"
  fi
  systemctl_user --no-pager --full status "$UNIT_NAME" 2>/dev/null || true
}

remove_legacy_only() {
  if ! is_native_linux; then
    return 0
  fi
  stop_legacy_service
  archive_and_remove_legacy_unit
  systemctl_user daemon-reload >/dev/null 2>&1 || true
  log "unit legada $LEGACY_UNIT removida/desativada."
}

action="${1:-ensure}"
case "$action" in
  ensure|start)
    ensure_all
    ;;
  migrate)
    if ! is_native_linux; then
      log "fora de Linux/systemd; nada a fazer."
      exit 0
    fi
    stop_legacy_service
    migrate_legacy_source
    install_and_start_unit
    archive_and_remove_legacy_unit
    systemctl_user daemon-reload >/dev/null 2>&1 || true
    ;;
  run)
    run_helper
    ;;
  status)
    status_all
    ;;
  stop)
    is_native_linux && systemctl_user stop "$UNIT_NAME" || true
    ;;
  restart)
    ensure_all
    ;;
  cleanup-legacy)
    remove_legacy_only
    ;;
  help|-h|--help)
    cat <<'EOF_HELP'
Uso:
  g512-rgb ensure          migra o helper legado e garante o serviço próprio
  g512-rgb migrate         força a tentativa de migração do código legado
  g512-rgb status          mostra código incorporado e status do serviço
  g512-rgb restart         garante/migra e reinicia
  g512-rgb stop            para apenas o helper RGB
  g512-rgb cleanup-legacy  para e remove apenas a unit g512-rgb.service antiga
EOF_HELP
    ;;
  *)
    fail "ação inválida: $action"
    ;;
esac
