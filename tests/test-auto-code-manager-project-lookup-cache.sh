#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
T="$(mktemp -d /tmp/devauto-lookup-cache-XXXXXX)"
trap 'rm -rf -- "$T"' EXIT
PROJECT_ROOT="$ROOT"
CODE_ROOT="$T/Code"
DEV_MANAGER_PROJECTS_FILE="$T/projects"
mkdir -p "$CODE_ROOT/orgs/main/apps/child/apps/deep" "$CODE_ROOT/orgs/main-extra" "$CODE_ROOT/orgs/other"
printf '%s\n' orgs/main orgs/main/apps/child orgs/main/apps/child/apps/deep orgs/main-extra orgs/other > "$DEV_MANAGER_PROJECTS_FILE"
source "$ROOT/scripts/dev-manager/00-runtime.sh"
source "$ROOT/scripts/dev-manager/40-files-safety.sh"
source "$ROOT/scripts/dev-manager/50-project-registry.sh"
source "$ROOT/scripts/dev-manager/60-project-runtime.sh"
source "$ROOT/scripts/dev-manager/160-dirty-backups.sh"
log() { printf '%s\n' "$*" >> "$T/log"; }
refresh_verified_project_lookup
[ "$(project_for_zip 'MAIN(2).ZIP')" = orgs/main ]
[ "$(project_for_zip 'main-child--nova.zip')" = orgs/main/apps/child ]
[ "$(project_for_zip 'main--child.zip')" = orgs/main/apps/child ]
[ "$(project_for_zip 'child(3).zip')" = orgs/main/apps/child ]
[ "$(project_for_zip 'child-deep.zip')" = orgs/main/apps/child/apps/deep ]
[ "$(project_for_zip 'main-extra--nova.zip')" = orgs/main-extra ]
[ -z "$(project_for_zip 'main2.zip')" ]
[ "$(event_owner_project "$CODE_ROOT/orgs/main/.config/child/db.env")" = orgs/main/apps/child ]
[ "$(event_owner_project "$CODE_ROOT/orgs/main/apps/child/.config/deep/db.env")" = orgs/main/apps/child/apps/deep ]
[ "$(event_owner_project "$CODE_ROOT/orgs/main/apps/child/apps/deep/src/app.ts")" = orgs/main/apps/child/apps/deep ]
[ -z "$(event_owner_project "$CODE_ROOT/orgs/main-other/app.ts")" ]
[ "$(project_archive_content_prefix orgs/main/apps/child/apps/deep)" = apps/deep ]

# Nenhuma reabertura do catálogo em 50 identificações, inclusive em $(...).
configured_projects() { printf 'read\n' >> "$T/catalog-reads"; clean_file "$PROJECTS_FILE"; }
for ((i=0; i<25; i++)); do
  [ "$(project_for_zip 'main-child.zip')" = orgs/main/apps/child ]
  [ "$(event_owner_project "$CODE_ROOT/orgs/main/apps/child/app.ts")" = orgs/main/apps/child ]
done
[ ! -e "$T/catalog-reads" ]

# A existência dos projetos não é memorizada: pasta removida não autoriza unzip.
rmdir "$CODE_ROOT/orgs/other"
[ -z "$(project_for_zip 'other.zip')" ]
mkdir -p "$CODE_ROOT/orgs/other"
[ "$(project_for_zip 'other.zip')" = orgs/other ]

# Rename atômico com tamanho e mtime preservados invalida pelo inode/ctime.
sed 's,orgs/other,orgs/newer,' "$PROJECTS_FILE" > "$T/replacement"
touch -r "$PROJECTS_FILE" "$T/replacement"
mv "$T/replacement" "$PROJECTS_FILE"
mkdir -p "$CODE_ROOT/orgs/newer"
refresh_verified_project_lookup
[ "$(project_for_zip 'newer.zip')" = orgs/newer ]
[ -z "$(project_for_zip 'other.zip')" ]
[ -s "$T/catalog-reads" ]

# Configuração ambígua nova não fica validada pelo cache.
printf '%s\n' orgs/main another/main > "$PROJECTS_FILE"
if refresh_verified_project_lookup; then
  echo 'FALHOU: chave lógica duplicada aceita após reload' >&2
  exit 1
fi
if refresh_verified_project_lookup; then
  echo 'FALHOU: configuração inválida foi aceita na segunda consulta' >&2
  exit 1
fi
printf 'OK: cache preserva aliases, subprojetos e .config; reusa catálogo e invalida por edição/rename\n'
