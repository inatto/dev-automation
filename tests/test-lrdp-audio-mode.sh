#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"
cat > "$TMP/bin/xfreerdp3" <<'EOT'
#!/usr/bin/env bash
if [[ "${1:-}" == "/list:monitor" ]]; then
  printf '%s\n' '* [0] 1920x1080 +0+0' '  [1] 1920x1080 +1920+0'
  exit 0
fi
printf '%s\n' "$@"
EOT
chmod +x "$TMP/bin/xfreerdp3"

for name in lrdp1 lrdp2; do
  state="$TMP/state-$name"
  mkdir -p "$state"
  script_path="$ROOT/apps/lrdp/$name"

  # Escolhe áudio remoto, sem microfone e monitor 0.
  output="$(printf '1\n2\nn\n0\n' | script -qfec "PATH='$TMP/bin':\$PATH LRDP_STATE_ROOT='$state' '$script_path'" /dev/null | tr -d '\r')"
  grep -Fq '/audio-mode:server' <<<"$output"
  ! grep -Fxq '/microphone' <<<"$output"
  grep -Fq '/monitors:0,1' <<<"$output"

  # Reconfigura a partir do salvo: N, mantém login, escolhe sem áudio, mic sim, principal 1.
  output="$(printf 'n\n\n3\ns\n1\n' | script -qfec "PATH='$TMP/bin':\$PATH LRDP_STATE_ROOT='$state' '$script_path'" /dev/null | tr -d '\r')"
  grep -Fq '/audio-mode:none' <<<"$output"
  grep -Fq '/microphone' <<<"$output"
  grep -Fq '/monitors:1,0' <<<"$output"
done

printf 'OK: lrdp1/lrdp2 reconfiguram áudio/microfone e ordenam monitor principal\n'
