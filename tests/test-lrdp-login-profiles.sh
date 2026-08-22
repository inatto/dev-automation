#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"
cat > "$TMP/bin/xfreerdp3" <<'EOT'
#!/usr/bin/env bash
printf '%s\n' "$@"
EOT
chmod +x "$TMP/bin/xfreerdp3"

for name in lrdp1 lrdp2; do
  src="$ROOT/apps/lrdp/$name"
  testscript="$TMP/$name"
  cp "$src" "$testscript"
  python3 - "$testscript" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1])
s=p.read_text()
needle='LOGIN_PROFILES=(\n'
s=s.replace(needle, needle+'  "Secundário|segundo.usuario|senha_teste"\n', 1)
p.write_text(s)
PY
  chmod +x "$testscript"

  output="$(printf '1\nn\n' | script -qfec "PATH='$TMP/bin':\$PATH '$testscript'" /dev/null | tr -d '\r')"
  grep -Fq 'Login RDP:' <<<"$output"
  grep -Fq 'Secundário (segundo.usuario)' <<<"$output"
  grep -Fq '/u:segundo.usuario' <<<"$output"
  grep -Fq '/p:senha_teste' <<<"$output"
  grep -Fq '/audio-mode:server' <<<"$output"
done

printf 'OK: lrdp1/lrdp2 permitem múltiplos logins e seleção ao iniciar\n'
