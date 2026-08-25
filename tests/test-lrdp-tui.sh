#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/state"

cat > "$TMP/bin/xfreerdp3" <<'EOT'
#!/usr/bin/env bash
if [[ "${1:-}" == "/list:monitor" ]]; then
  cat <<'MON'
  [0] 1920x1080 +1920+0
* [1] 1920x1080 +0+0
  [2] 3840x2160 +3840+0
MON
  exit 0
fi
printf '%s\n' "$@"
EOT
chmod +x "$TMP/bin/xfreerdp3"

cat > "$TMP/state/lrdp1.conf" <<'STATE'
login_index=2
audio_mode=redirect
microphone=yes
primary_monitor=1
STATE

PATH="$TMP/bin:$PATH" LRDP_STATE_ROOT="$TMP/state" \
  python3 "$ROOT/apps/lrdp/lrdp-tui.py" --dump-json > "$TMP/dump.json"

python3 - "$TMP/dump.json" <<'PY'
import json, sys
p=sys.argv[1]
data=json.load(open(p, encoding='utf-8'))
assert [x['name'] for x in data['profiles']] == ['lrdp1', 'lrdp2'], data['profiles']
assert [m['id'] for m in data['monitors']] == [0, 1, 2], data['monitors']
assert data['physical_order'] == [1, 0, 2], data['physical_order']
assert [m['id'] for m in data['monitors'] if m['local_primary']] == [1]
p1=data['profiles'][0]
assert p1['target'] == '192.168.1.143'
assert p1['state']['login_index'] == 2
assert p1['effective_primary'] == '1'
cmd=p1['command']
for expected in ['/u:govbr', '/audio-mode:redirect', '/microphone', '/monitors:1,0,2', '/p:<senha-oculta>']:
    assert expected in cmd, cmd
# O JSON contém apenas password_set=true e o placeholder; não existe campo de senha.
for profile in data['profiles']:
    for login in profile['logins']:
        assert set(login) == {'label', 'username', 'password_set'}, login
PY

# O modo usado pela TUI deve conectar sem imprimir perguntas de configuração.
output="$(PATH="$TMP/bin:$PATH" LRDP_STATE_ROOT="$TMP/state" "$ROOT/apps/lrdp/lrdp1" --saved)"
grep -Fq '/u:govbr' <<<"$output"
grep -Fq '/monitors:1,0,2' <<<"$output"
grep -Fq '/microphone' <<<"$output"
! grep -Fq 'Usar essa configuração?' <<<"$output"
! grep -Fq 'Monitores detectados' <<<"$output"

# Smoke test da TUI em pseudo-TTY: inicia curses e sai por Q sem crash.
printf 'q' | timeout 8 script -qfec \
  "TERM=xterm-256color PATH='$TMP/bin':\$PATH LRDP_STATE_ROOT='$TMP/state' '$ROOT/apps/lrdp/lrdp'" \
  /dev/null >/dev/null

# dev-manager também expõe a mesma TUI sem duplicar implementação.
cat > "$TMP/lrdp-mock" <<'EOT'
#!/usr/bin/env bash
printf 'LRDP-MOCK %s\n' "$*"
EOT
chmod +x "$TMP/lrdp-mock"
dm_output="$(DEV_MANAGER_LRDP_SCRIPT="$TMP/lrdp-mock" bash "$ROOT/scripts/dev-manager.sh" lrdp --probe)"
[[ "$dm_output" == 'LRDP-MOCK --probe' ]]

printf 'OK: LRDP TUI descobre perfis, protege senhas, desenha topologia e conecta com estado salvo\n'
