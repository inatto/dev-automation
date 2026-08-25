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

for name in lrdp1 lrdp2; do
  rm -rf "$TMP/state/$name"
  mkdir -p "$TMP/state/$name"
  script_path="$ROOT/apps/lrdp/$name"

  # Configuração inicial: login Gov, áudio local, microfone, monitor 1 como principal.
  output="$(printf '2\n1\ns\n1\n' | script -qfec "PATH='$TMP/bin':\$PATH LRDP_STATE_ROOT='$TMP/state/$name' '$script_path'" /dev/null | tr -d '\r')"
  grep -Fq 'Monitores detectados pelo FreeRDP:' <<<"$output"
  grep -Fq '[1] 1920x1080 +0+0' <<<"$output"
  grep -Fq 'IDs detectados: 0 1 2' <<<"$output"
  grep -Fq 'Esquerda -> direita: [1] [0] [2]' <<<"$output"
  grep -Fq '/u:govbr' <<<"$output"
  grep -Fq '/audio-mode:redirect' <<<"$output"
  grep -Fq '/microphone' <<<"$output"
  grep -Fq '/monitors:1,0,2' <<<"$output"

  state="$TMP/state/$name/$name.conf"
  [[ -f "$state" ]]
  grep -Fxq 'login_index=2' "$state"
  grep -Fxq 'audio_mode=redirect' "$state"
  grep -Fxq 'microphone=yes' "$state"
  grep -Fxq 'primary_monitor=1' "$state"

  # Segunda execução: Enter aceita toda a última configuração, sem reconfigurar.
  output="$(printf '\n' | script -qfec "PATH='$TMP/bin':\$PATH LRDP_STATE_ROOT='$TMP/state/$name' '$script_path'" /dev/null | tr -d '\r')"
  grep -Fq "Última configuração de $name:" <<<"$output"
  grep -Fq 'Usar essa configuração? [S/n]:' <<<"$output"
  grep -Fq '/u:govbr' <<<"$output"
  grep -Fq '/audio-mode:redirect' <<<"$output"
  grep -Fq '/microphone' <<<"$output"
  grep -Fq '/monitors:1,0,2' <<<"$output"
done

printf 'OK: lrdp1/lrdp2 persistem login, áudio, microfone e monitor principal\n'
