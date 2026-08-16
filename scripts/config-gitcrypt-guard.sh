#!/usr/bin/env bash
# Protege qualquer pasta "config" dos projetos ativos com git-crypt.
# Engine independente: não inicia TUI, não faz commit/push e nunca adiciona
# arquivo não rastreado. O dev-manager apenas consome os resultados deste script.

set -uo pipefail

CODE_ROOT="${CODE_ROOT:-/home/daniel/Code}"
PROJECTS_FILE="${DEV_MANAGER_PROJECTS_FILE:-}"
KEY_FILE="${DEV_MANAGER_GIT_CRYPT_KEY:-/home/daniel/static/git-reverse-crypt-2.key}"
MODE="fix"
ONLY_PROJECT=""
PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
PROJECTS_FILE="${PROJECTS_FILE:-$PROJECT_ROOT/config/auto-code-manager.projects}"

BEGIN_MARKER='# BEGIN dev-manager: config folders git-crypt'
END_MARKER='# END dev-manager: config folders git-crypt'
CRITICALS=0
FIXES=0
WARNINGS=0

usage() {
  cat <<'EOF_HELP'
Uso:
  config-gitcrypt-guard.sh [--fix|--check] [--project REL] [--code-root DIR]
                           [--projects-file FILE] [--key FILE]

Padrão: --fix usando /home/daniel/static/git-reverse-crypt-2.key.
--fix não faz commit/push e não adiciona arquivos não rastreados.
EOF_HELP
}

out() {
  printf '%s: %s\n' "$1" "$2"
}

critical() {
  CRITICALS=$((CRITICALS + 1))
  out CRITICAL "$*"
}

fixed() {
  FIXES=$((FIXES + 1))
  out FIX "$*"
}

warn() {
  WARNINGS=$((WARNINGS + 1))
  out AVISO "$*"
}

ok() {
  out OK "$*"
}

trim_line() {
  local line="$1"
  line="${line%$'\r'}"
  line="${line%%#*}"
  line="${line#"${line%%[![:space:]]*}"}"
  line="${line%"${line##*[![:space:]]}"}"
  printf '%s\n' "$line"
}

is_aggregate_project() {
  [[ "${1,,}" == *.zip ]]
}

project_selected() {
  local project="$1"
  [ -z "$ONLY_PROJECT" ] || [ "$project" = "$ONLY_PROJECT" ]
}

find_config_dirs() {
  local root="$1"
  find "$root" \
    \( -type d \( \
      -name .git -o -name node_modules -o -name .venv -o -name venv -o \
      -name __pycache__ -o -name .pytest_cache -o -name .cache -o \
      -name dist -o -name build -o -name target -o -name vendor -o \
      -name .idea -o -name .astro \
    \) -prune \) -o \
    \( -type d -iname config -print \) 2>/dev/null
}

repo_relative_path() {
  local repo="$1"
  local path="$2"
  python3 - "$repo" "$path" <<'PY'
import os, sys
repo, path = map(os.path.realpath, sys.argv[1:3])
rel = os.path.relpath(path, repo).replace(os.sep, '/')
if rel == '..' or rel.startswith('../'):
    raise SystemExit(2)
print(rel)
PY
}

pattern_for_rel() {
  local rel="$1"
  # Projetos reais do catálogo não usam whitespace nos caminhos. Se alguém
  # inventar isso depois, falhamos fechado em vez de gerar .gitattributes ambíguo.
  if [[ "$rel" =~ [[:space:]] ]]; then
    return 1
  fi
  printf '%s/** filter=git-crypt diff=git-crypt\n' "$rel"
}

build_managed_block() {
  local rel
  printf '%s\n' "$BEGIN_MARKER"
  while IFS= read -r rel || [ -n "$rel" ]; do
    [ -n "$rel" ] || continue
    pattern_for_rel "$rel" || return 1
  done
  # Arquivos que controlam o próprio Git não podem ser criptografados. O
  # upstream do git-crypt alerta explicitamente para .gitattributes/.gitignore.
  cat <<'EOF_BLOCK'
.gitattributes !filter !diff
.gitignore !filter !diff
.gitmodules !filter !diff
**/.gitattributes !filter !diff
**/.gitignore !filter !diff
**/.gitmodules !filter !diff
EOF_BLOCK
  printf '%s\n' "$END_MARKER"
}

render_gitattributes() {
  local attrs="$1"
  local block_file="$2"
  local output="$3"
  python3 - "$attrs" "$block_file" "$output" "$BEGIN_MARKER" "$END_MARKER" <<'PY'
from pathlib import Path
import sys
attrs, block, output, begin, end = sys.argv[1:]
p = Path(attrs)
text = p.read_text(encoding='utf-8', errors='surrogateescape') if p.exists() else ''
lines = text.splitlines()
result = []
in_block = False
for line in lines:
    if line == begin:
        in_block = True
        continue
    if in_block:
        if line == end:
            in_block = False
        continue
    result.append(line)
while result and not result[-1].strip():
    result.pop()
if result:
    result.append('')
result.extend(Path(block).read_text(encoding='utf-8').splitlines())
Path(output).write_text('\n'.join(result) + '\n', encoding='utf-8')
PY
}

repo_internal_key_matches() {
  local repo="$1"
  local tmp
  tmp="$(mktemp)" || return 2
  if git -C "$repo" crypt export-key "$tmp" >/dev/null 2>&1; then
    if cmp -s -- "$tmp" "$KEY_FILE"; then
      rm -f -- "$tmp"
      return 0
    fi
    rm -f -- "$tmp"
    return 1
  fi
  rm -f -- "$tmp"
  return 2
}

ensure_repo_key() {
  local repo="$1"
  local key_state
  repo_internal_key_matches "$repo"
  key_state=$?
  case "$key_state" in
    0)
      return 0
      ;;
    1)
      critical "repo usa chave git-crypt diferente da chave padrão; não alterado: $repo"
      return 1
      ;;
    2)
      if [ "$MODE" = check ]; then
        critical "repo não está desbloqueado/configurado com a chave padrão: $repo"
        return 1
      fi
      local unlock_err
      unlock_err="$(git -C "$repo" crypt unlock "$KEY_FILE" 2>&1 >/dev/null || true)"
      if repo_internal_key_matches "$repo"; then
        fixed "git-crypt configurado/desbloqueado com a chave padrão: $repo"
        return 0
      fi
      unlock_err="${unlock_err//$'\n'/; }"
      [ -n "$unlock_err" ] || unlock_err="git-crypt recusou a chave sem detalhar o motivo"
      critical "não foi possível aplicar a chave git-crypt padrão; repo preservado: $repo | motivo: $unlock_err"
      return 1
      ;;
  esac
}

tracked_config_dirty() {
  local repo="$1"
  shift
  local rel
  for rel in "$@"; do
    if [ -n "$(git -C "$repo" status --porcelain=v1 --untracked-files=no -- "$rel" 2>/dev/null)" ]; then
      return 0
    fi
  done
  return 1
}

attrs_dirty() {
  local repo="$1"
  [ -n "$(git -C "$repo" status --porcelain=v1 --untracked-files=no -- .gitattributes 2>/dev/null)" ]
}

is_git_control_path() {
  case "$(basename -- "$1")" in
    .gitattributes|.gitignore|.gitmodules) return 0 ;;
    *) return 1 ;;
  esac
}

index_blob_is_encrypted() {
  local repo="$1"
  local path="$2"
  local hex
  hex="$(git -C "$repo" show ":$path" 2>/dev/null | head -c 10 | od -An -tx1 | tr -d ' \n')"
  [ "$hex" = "00474954435259505400" ]
}

head_blob_is_encrypted() {
  local repo="$1"
  local path="$2"
  local hex
  git -C "$repo" cat-file -e "HEAD:$path" 2>/dev/null || return 0
  hex="$(git -C "$repo" show "HEAD:$path" 2>/dev/null | head -c 10 | od -An -tx1 | tr -d ' \n')"
  [ "$hex" = "00474954435259505400" ]
}

repair_plain_index_blobs() {
  local repo="$1"
  shift
  local -a rels=("$@")
  local rel path mode blob attr_out filter diff
  local repaired=0 failed=0

  for rel in "${rels[@]}"; do
    while IFS= read -r -d '' path; do
      mode="$(git -C "$repo" ls-files -s -- "$path" 2>/dev/null | awk '$3==0{print $1; exit}')"
      [ "$mode" = 100644 ] || [ "$mode" = 100755 ] || continue
      is_git_control_path "$path" && continue
      index_blob_is_encrypted "$repo" "$path" && continue

      if [ -n "$(git -C "$repo" ls-files -u -- "$path" 2>/dev/null)" ]; then
        critical "$repo: arquivo config com merge não resolvido; não alterei o índice: $path"
        failed=$((failed + 1))
        continue
      fi

      attr_out="$(git -C "$repo" check-attr filter diff -- "$path" 2>/dev/null || true)"
      filter="$(printf '%s\n' "$attr_out" | awk -F': ' '$2=="filter"{print $3; exit}')"
      diff="$(printf '%s\n' "$attr_out" | awk -F': ' '$2=="diff"{print $3; exit}')"
      if [ "$filter" != git-crypt ] || [ "$diff" != git-crypt ]; then
        critical "$repo: atributos git-crypt ainda não ativos para $path"
        failed=$((failed + 1))
        continue
      fi

      # Usa EXATAMENTE o conteúdo que já está no índice, não o working tree.
      # --path faz o Git aplicar o clean filter (git-crypt) ao gerar o novo blob.
      blob="$(git -C "$repo" show ":$path" 2>/dev/null | git -C "$repo" hash-object -w --path="$path" --stdin 2>/dev/null || true)"
      if [ -z "$blob" ] || ! git -C "$repo" cat-file -e "$blob^{blob}" 2>/dev/null; then
        critical "$repo: não consegui gerar blob git-crypt para o índice: $path"
        failed=$((failed + 1))
        continue
      fi
      if ! git -C "$repo" update-index --cacheinfo "$mode" "$blob" "$path" >/dev/null 2>&1; then
        critical "$repo: não consegui substituir blob plaintext no índice: $path"
        failed=$((failed + 1))
        continue
      fi
      if ! index_blob_is_encrypted "$repo" "$path"; then
        critical "$repo: filtro executou mas o blob continuou plaintext: $path"
        failed=$((failed + 1))
        continue
      fi
      repaired=$((repaired + 1))
    done < <(git -C "$repo" ls-files -z -- "$rel" 2>/dev/null)
  done

  if [ "$repaired" -gt 0 ]; then
    fixed "$repo: $repaired blob(s) config migrado(s) para git-crypt no índice sem tocar no working tree"
  fi
  [ "$failed" -eq 0 ]
}

verify_repo_configs() {
  local repo="$1"
  shift
  local -a rels=("$@")
  local rel path attr_out filter diff mode
  local plain_index=0 plain_head=0 attr_bad=0 tracked=0

  for rel in "${rels[@]}"; do
    while IFS= read -r -d '' path; do
      mode="$(git -C "$repo" ls-files -s -- "$path" 2>/dev/null | awk 'NR==1{print $1}')"
      [ "$mode" = 100644 ] || [ "$mode" = 100755 ] || continue
      is_git_control_path "$path" && continue
      tracked=$((tracked + 1))

      attr_out="$(git -C "$repo" check-attr filter diff -- "$path" 2>/dev/null || true)"
      filter="$(printf '%s\n' "$attr_out" | awk -F': ' '$2=="filter"{print $3; exit}')"
      diff="$(printf '%s\n' "$attr_out" | awk -F': ' '$2=="diff"{print $3; exit}')"
      if [ "$filter" != git-crypt ] || [ "$diff" != git-crypt ]; then
        attr_bad=$((attr_bad + 1))
        continue
      fi
      index_blob_is_encrypted "$repo" "$path" || plain_index=$((plain_index + 1))
      head_blob_is_encrypted "$repo" "$path" || plain_head=$((plain_head + 1))
    done < <(git -C "$repo" ls-files -z -- "$rel" 2>/dev/null)
  done

  [ "$attr_bad" -eq 0 ] || critical "$repo: $attr_bad arquivo(s) rastreado(s) em config sem atributos git-crypt corretos"
  [ "$plain_index" -eq 0 ] || critical "$repo: $plain_index arquivo(s) de config ainda estão plaintext no índice Git"
  if [ "$plain_head" -gt 0 ]; then
    if [ "$plain_index" -eq 0 ] && [ "$attr_bad" -eq 0 ]; then
      warn "$repo: $plain_head arquivo(s) ainda estão plaintext no HEAD antigo; índice já está criptografado. Um próximo commit grava a proteção; histórico anterior só some com rewrite explícito"
    else
      critical "$repo: $plain_head arquivo(s) de config estão plaintext no HEAD e a migração atual ainda não ficou comprovada"
    fi
  fi
  if [ "$attr_bad" -eq 0 ] && [ "$plain_index" -eq 0 ]; then
    ok "$repo: ${#rels[@]} pasta(s) config protegida(s); $tracked arquivo(s) rastreado(s) verificados"
  fi
}

protect_repo() {
  local repo="$1"
  shift
  local -a rels=("$@")
  local attrs="$repo/.gitattributes"
  local block rendered rel
  local need_write=false

  block="$(mktemp)" || return 1
  rendered="$(mktemp)" || { rm -f -- "$block"; return 1; }
  if ! printf '%s\n' "${rels[@]}" | sort -u | build_managed_block > "$block"; then
    critical "caminho de config com whitespace não suportado automaticamente; repo preservado: $repo"
    rm -f -- "$block" "$rendered"
    return 1
  fi
  render_gitattributes "$attrs" "$block" "$rendered" || {
    critical "falha ao preparar .gitattributes sem tocar no repo: $repo"
    rm -f -- "$block" "$rendered"
    return 1
  }

  if [ ! -f "$attrs" ] || ! cmp -s -- "$attrs" "$rendered"; then
    need_write=true
  fi

  if [ "$MODE" = check ]; then
    [ "$need_write" = false ] || critical "pasta config sem regra gerenciada git-crypt em .gitattributes: $repo"
    rm -f -- "$block" "$rendered"
    verify_repo_configs "$repo" "${rels[@]}"
    return 0
  fi

  if ! ensure_repo_key "$repo"; then
    rm -f -- "$block" "$rendered"
    return 1
  fi

  if [ "$need_write" = true ]; then
    if attrs_dirty "$repo"; then
      critical ".gitattributes tem alteração local; não sobrescrevi para evitar estrago: $repo"
      rm -f -- "$block" "$rendered"
      return 1
    fi
    cat -- "$rendered" > "$attrs" || {
      critical "não consegui gravar .gitattributes: $repo"
      rm -f -- "$block" "$rendered"
      return 1
    }
    git -C "$repo" add -- .gitattributes >/dev/null 2>&1 || {
      critical "regra foi gravada mas não consegui stagear .gitattributes: $repo"
      rm -f -- "$block" "$rendered"
      return 1
    }
    fixed "regras git-crypt adicionadas/normalizadas em .gitattributes: $repo"
  fi

  # Migra somente o conteúdo JÁ presente no índice. Isso funciona mesmo com
  # arquivo modificado/staged e não puxa mudanças do working tree para o stage.
  repair_plain_index_blobs "$repo" "${rels[@]}" || true

  rm -f -- "$block" "$rendered"
  verify_repo_configs "$repo" "${rels[@]}"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --fix) MODE=fix; shift ;;
    --check) MODE=check; shift ;;
    --project)
      [ "$#" -ge 2 ] || { usage >&2; exit 2; }
      ONLY_PROJECT="${2#./}"; ONLY_PROJECT="${ONLY_PROJECT%/}"; shift 2 ;;
    --code-root)
      [ "$#" -ge 2 ] || { usage >&2; exit 2; }
      CODE_ROOT="$2"; shift 2 ;;
    --projects-file)
      [ "$#" -ge 2 ] || { usage >&2; exit 2; }
      PROJECTS_FILE="$2"; shift 2 ;;
    --key)
      [ "$#" -ge 2 ] || { usage >&2; exit 2; }
      KEY_FILE="$2"; shift 2 ;;
    -h|--help|help) usage; exit 0 ;;
    *) printf 'ERRO: argumento inválido: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

[ -d "$CODE_ROOT" ] || { critical "CODE_ROOT não existe: $CODE_ROOT"; exit 3; }
[ -f "$PROJECTS_FILE" ] || { critical "arquivo de projetos não existe: $PROJECTS_FILE"; exit 3; }
command -v git >/dev/null 2>&1 || { critical "git não instalado"; exit 3; }

# Reúne configs por repositório Git para aplicar uma única transação de regras.
declare -A REPO_CONFIGS=()
declare -A SEEN_CONFIGS=()
FOUND_CONFIGS=0

while IFS= read -r raw || [ -n "$raw" ]; do
  project="$(trim_line "$raw")"
  [ -n "$project" ] || continue
  project="${project#./}"; project="${project%/}"
  is_aggregate_project "$project" && continue
  project_selected "$project" || continue
  project_dir="$CODE_ROOT/$project"
  if [ ! -d "$project_dir" ]; then
    warn "projeto ativo ainda não existe nesta máquina: $project_dir"
    continue
  fi

  while IFS= read -r config_dir || [ -n "$config_dir" ]; do
    [ -n "$config_dir" ] || continue
    config_real="$(readlink -f -- "$config_dir" 2>/dev/null || true)"
    [ -n "$config_real" ] || continue
    [ -z "${SEEN_CONFIGS[$config_real]+x}" ] || continue
    SEEN_CONFIGS["$config_real"]=1
    FOUND_CONFIGS=$((FOUND_CONFIGS + 1))

    repo="$(git -C "$config_real" rev-parse --show-toplevel 2>/dev/null || true)"
    if [ -z "$repo" ] || [ ! -d "$repo/.git" ] && [ ! -f "$repo/.git" ]; then
      critical "pasta config não pertence a repositório Git: $config_real"
      continue
    fi
    repo="$(readlink -f -- "$repo")"
    rel="$(repo_relative_path "$repo" "$config_real" 2>/dev/null || true)"
    if [ -z "$rel" ] || [ "$rel" = . ]; then
      critical "não consegui resolver caminho relativo da pasta config: $config_real"
      continue
    fi
    if [[ "$rel" =~ [[:space:]] ]]; then
      critical "pasta config com whitespace não pode ser protegida automaticamente sem revisão: $config_real"
      continue
    fi
    if [ -n "${REPO_CONFIGS[$repo]-}" ]; then
      REPO_CONFIGS["$repo"]+=$'\n'"$rel"
    else
      REPO_CONFIGS["$repo"]="$rel"
    fi
  done < <(find_config_dirs "$project_dir")
done < "$PROJECTS_FILE"

if [ "$FOUND_CONFIGS" -eq 0 ]; then
  [ -z "$ONLY_PROJECT" ] || ok "nenhuma pasta config encontrada no projeto ativo: $ONLY_PROJECT"
  out RESUMO "0 críticos, 0 correções, $WARNINGS aviso(s), 0 pastas config examinadas"
  exit 0
fi

if [ "${#REPO_CONFIGS[@]}" -gt 0 ]; then
  command -v git-crypt >/dev/null 2>&1 || {
    critical "git-crypt não instalado; proteção de config não pode ser garantida"
    out INSTALAR "sudo apt update && sudo apt install -y git-crypt"
    out RESUMO "$CRITICALS crítico(s), 0 correções, $WARNINGS aviso(s), $FOUND_CONFIGS pasta(s) config examinada(s)"
    exit 3
  }
  [ -r "$KEY_FILE" ] || { critical "chave git-crypt ausente ou ilegível: $KEY_FILE"; out RESUMO "$CRITICALS crítico(s), 0 correções, $WARNINGS aviso(s), $FOUND_CONFIGS pasta(s) config examinada(s)"; exit 3; }
fi

for repo in "${!REPO_CONFIGS[@]}"; do
  mapfile -t rels < <(printf '%s\n' "${REPO_CONFIGS[$repo]}" | sed '/^$/d' | sort -u)
  protect_repo "$repo" "${rels[@]}"
done

if [ "$CRITICALS" -gt 0 ]; then
  out RESUMO "$CRITICALS crítico(s), $FIXES correção(ões), $WARNINGS aviso(s), $FOUND_CONFIGS pasta(s) config examinada(s)"
  exit 3
fi
out RESUMO "0 críticos, $FIXES correção(ões), $WARNINGS aviso(s), $FOUND_CONFIGS pasta(s) config examinada(s)"
exit 0
