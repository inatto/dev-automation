#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"
cat > "$TMP/bin/xfreerdp3" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@"
EOF
chmod +x "$TMP/bin/xfreerdp3"

for name in lrdp1 lrdp2; do
  script="$ROOT/apps/lrdp/$name"
  grep -Fq "Quer alterar a configuração? [s/N]:" "$script"
  grep -Fq "'/audio-mode:redirect'" "$script"
  grep -Fq "'/audio-mode:server'" "$script"
  grep -Fq "'/audio-mode:none'" "$script"

  # N: abre direto usando áudio remoto, sem entrar no menu.
  output="$(printf 'n\n' | script -qfec "PATH='$TMP/bin':\$PATH '$script'" /dev/null | tr -d '\r')"
  grep -Fq '/audio-mode:server' <<<"$output"
  ! grep -Fq 'Áudio RDP:' <<<"$output"

  # S: exibe opções; 1 escolhe áudio local.
  output="$(printf 's\n1\n' | script -qfec "PATH='$TMP/bin':\$PATH '$script'" /dev/null | tr -d '\r')"
  grep -Fq 'Áudio RDP:' <<<"$output"
  grep -Fq '/audio-mode:redirect' <<<"$output"
done

printf 'OK: lrdp1/lrdp2 perguntam antes; N conecta direto e S abre opções de áudio\n'
