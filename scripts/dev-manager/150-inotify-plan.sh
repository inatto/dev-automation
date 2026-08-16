#!/usr/bin/env bash
# Contexto: regras, exclusões e árvore de diretórios do inotify

build_inotify_exclude_regex() {
  local wsl_mode=0
  # Apenas regras de ARQUIVO são enviadas ao --exclude. Diretórios ignorados
  # são removidos da própria árvore de watches com @path, reduzindo drasticamente
  # o número de watches em .venv/node_modules/.git etc.
  is_wsl_runtime && wsl_mode=1
  python3 - "$IGNORE_ZIP_FILE" "$wsl_mode" <<'PY_INOTIFY_REGEX'
import re
import sys

path = sys.argv[1]
wsl_mode = sys.argv[2] == '1'
patterns = []


def glob_to_ere(value: str) -> str:
    out = []
    for ch in value:
        if ch == '*':
            out.append('[^/]*')
        elif ch == '?':
            out.append('[^/]')
        else:
            out.append(re.escape(ch))
    return ''.join(out)

with open(path, 'r', encoding='utf-8', errors='replace') as fh:
    for raw in fh:
        line = raw.rstrip('\r\n')
        line = line.split('#', 1)[0].strip()
        if not line or line.startswith('!'):
            continue
        if line.endswith('/'):
            continue
        if 'Zone.Identifier' in line and wsl_mode:
            # No WSL o evento precisa chegar para apagar o sidecar sem scan.
            # No Linux nativo a própria regra de ignore o remove do watcher.
            continue
        if line.startswith('/'):
            line = line[1:]
        if not line:
            continue
        patterns.append('(^|/)' + glob_to_ere(line) + '$')

print('|'.join(patterns))
PY_INOTIFY_REGEX
}

build_inotify_directory_regex() {
  python3 - "$IGNORE_ZIP_FILE" <<'PY_INOTIFY_DIR_REGEX'
import re
import sys

path = sys.argv[1]
patterns = []


def glob_to_ere(value: str) -> str:
    out = []
    for ch in value:
        if ch == '*':
            out.append('[^/]*')
        elif ch == '?':
            out.append('[^/]')
        else:
            out.append(re.escape(ch))
    return ''.join(out)

with open(path, 'r', encoding='utf-8', errors='replace') as fh:
    for raw in fh:
        line = raw.rstrip('\r\n')
        line = line.split('#', 1)[0].strip()
        if not line or line.startswith('!') or not line.endswith('/'):
            continue
        line = line[:-1]
        if line.startswith('/'):
            line = line[1:]
        if not line:
            continue
        patterns.append('(^|/)' + glob_to_ere(line) + '(/|$)')

print('|'.join(patterns))
PY_INOTIFY_DIR_REGEX
}

watch_excluded_directories() {
  local root="$1"
  python3 - "$root" "$IGNORE_ZIP_FILE" <<'PY_WATCH_EXCLUDES'
import fnmatch
import os
import subprocess
import sys

root = os.path.abspath(sys.argv[1])
ignore_file = sys.argv[2]
basename_rules = []
path_rules = []
git_ignored_dirs = set()

with open(ignore_file, 'r', encoding='utf-8', errors='replace') as fh:
    for raw in fh:
        line = raw.rstrip('\r\n')
        line = line.split('#', 1)[0].strip()
        if not line or line.startswith('!') or not line.endswith('/'):
            continue
        line = line[:-1].lstrip('/')
        if not line:
            continue
        if '/' in line:
            path_rules.append(line)
        else:
            basename_rules.append(line)

# O Git resolve .gitignore aninhado, excludes globais e regras com !. Com
# --directory ele devolve a raiz das subárvores ignoradas, permitindo podá-las
# antes do os.walk entrar nelas.
try:
    inside = subprocess.run(
        ['git', '-C', root, 'rev-parse', '--is-inside-work-tree'],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    if inside.returncode == 0:
        ignored = subprocess.run(
            ['git', '-C', root, 'ls-files', '-z', '--others', '--ignored',
             '--exclude-standard', '--directory', '--', '.'],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            check=False,
        )
        if ignored.returncode == 0:
            for raw in ignored.stdout.split(b'\0'):
                if not raw.endswith(b'/'):
                    continue
                rel = raw[:-1].decode('utf-8', errors='surrogateescape')
                if rel:
                    git_ignored_dirs.add(rel)
except OSError:
    pass

for current, dirs, _files in os.walk(root, topdown=True, followlinks=False):
    kept = []
    for name in dirs:
        full = os.path.join(current, name)
        rel = os.path.relpath(full, root).replace(os.sep, '/')
        ignored = rel in git_ignored_dirs
        if not ignored:
            ignored = any(fnmatch.fnmatchcase(name, pat) for pat in basename_rules)
        if not ignored:
            ignored = any(fnmatch.fnmatchcase(rel, pat) for pat in path_rules)
        if ignored:
            print(full)
        else:
            kept.append(name)
    dirs[:] = kept
PY_WATCH_EXCLUDES
}

path_is_git_ignored() {
  local project_dir="$1" event_path="$2"

  command -v git >/dev/null 2>&1 || return 1
  git -C "$project_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 1
  git -C "$project_dir" check-ignore -q -- "$event_path" 2>/dev/null
}

