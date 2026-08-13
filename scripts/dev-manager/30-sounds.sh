#!/usr/bin/env bash
# Contexto: sons de notificação, erro e backup

soft_beep() {
  [ ! -f "$SOUND_DISABLED_FILE" ] || return 0

  local repeats="${BEEP_REPEATS:-2}"
  local gap_ms="${BEEP_GAP_MS:-220}"
  local mode="${BEEP_MODE:-wave}"
  local volume="${BEEP_VOLUME:-22}"
  local wave_file="${BEEP_WAVE_FILE:-$PROJECT_ROOT/assets/sounds/soft-notification.wav}"
  local windows_wave="${BEEP_WINDOWS_WAVE_FILE:-C:\\Windows\\Media\\notify.wav}"
  local bundled_windows=""
  local powershell_cmd=""
  local powershell_probe=""
  local powershell_script=""
  local audio_result=""
  local i

  line
  log "AVISO SONORO: iniciando ($repeats toque(s), modo=$mode, volume=$volume%)"

  # No WSLg, PulseAudio/PipeWire normalmente é a rota mais direta e não depende
  # da interoperabilidade com executáveis do Windows.
  if [ "$mode" = "wave" ] && [ -r "$wave_file" ]; then
    if command -v paplay >/dev/null 2>&1; then
      log "AVISO SONORO: tentando WAV pelo paplay do WSL..."
      for ((i = 0; i < repeats; i++)); do
        if ! paplay --volume="$((volume * 65536 / 100))" "$wave_file" >/dev/null 2>&1; then
          break
        fi
        [ "$i" -ge $((repeats - 1)) ] || sleep "$(awk "BEGIN { print $gap_ms / 1000 }")"
      done
      if [ "$i" -eq "$repeats" ]; then
        log "AVISO SONORO: WAV tocado pelo áudio nativo do WSL (paplay)."
        line
        return 0
      fi
      log "AVISO SONORO: paplay existe, mas não conseguiu tocar o WAV."
    fi

    if command -v pw-play >/dev/null 2>&1; then
      log "AVISO SONORO: tentando WAV pelo PipeWire do WSL..."
      for ((i = 0; i < repeats; i++)); do
        if ! pw-play --volume="$(awk "BEGIN { print $volume / 100 }")" "$wave_file" >/dev/null 2>&1; then
          break
        fi
        [ "$i" -ge $((repeats - 1)) ] || sleep "$(awk "BEGIN { print $gap_ms / 1000 }")"
      done
      if [ "$i" -eq "$repeats" ]; then
        log "AVISO SONORO: WAV tocado pelo áudio nativo do WSL (pw-play)."
        line
        return 0
      fi
      log "AVISO SONORO: pw-play existe, mas não conseguiu tocar o WAV."
    fi

    if command -v aplay >/dev/null 2>&1; then
      log "AVISO SONORO: tentando WAV pelo ALSA do WSL..."
      for ((i = 0; i < repeats; i++)); do
        if ! aplay -q "$wave_file" >/dev/null 2>&1; then
          break
        fi
        [ "$i" -ge $((repeats - 1)) ] || sleep "$(awk "BEGIN { print $gap_ms / 1000 }")"
      done
      if [ "$i" -eq "$repeats" ]; then
        log "AVISO SONORO: WAV tocado pelo áudio nativo do WSL (aplay)."
        line
        return 0
      fi
      log "AVISO SONORO: aplay existe, mas não conseguiu tocar o WAV."
    fi
  fi

  powershell_cmd="$(command -v powershell.exe 2>/dev/null || true)"
  if [ -n "$powershell_cmd" ]; then
    powershell_probe="$($powershell_cmd -NoLogo -NoProfile -NonInteractive -Command "exit 0" 2>&1 || true)"
    if [ -z "$powershell_probe" ]; then
      log "AVISO SONORO: interoperabilidade WSL/Windows operacional."

      if [ "$mode" = "wave" ]; then
        if [ -r "$wave_file" ] && command -v wslpath >/dev/null 2>&1; then
          bundled_windows="$(wslpath -w "$wave_file" 2>/dev/null || true)"
        fi

        powershell_script="\$ErrorActionPreference = 'Stop';
          \$candidates = @('$windows_wave', '$bundled_windows') | Where-Object { \$_ -and (Test-Path -LiteralPath \$_) };
          if (\$candidates.Count -eq 0) { throw 'Nenhum arquivo WAV foi encontrado.' }
          foreach (\$wav in \$candidates) {
            try {
              \$player = New-Object System.Media.SoundPlayer;
              \$player.SoundLocation = \$wav;
              \$player.Load();
              for (\$i = 0; \$i -lt $repeats; \$i++) {
                \$player.PlaySync();
                if (\$i -lt ($repeats - 1)) { Start-Sleep -Milliseconds $gap_ms }
              }
              Write-Output ('OK|' + \$wav);
              exit 0;
            } catch {
              Write-Output ('FALHOU|' + \$wav + '|' + \$_.Exception.Message);
            }
          }
          exit 2"

        audio_result="$($powershell_cmd -NoLogo -NoProfile -NonInteractive -STA -Command "$powershell_script" 2>&1 | tr -d '\r')"
        if grep -q '^OK|' <<< "$audio_result"; then
          log "AVISO SONORO: WAV tocado pelo Windows: $(grep '^OK|' <<< "$audio_result" | tail -n1 | cut -d'|' -f2-)"
          line
          return 0
        fi
        log "AVISO SONORO: Windows não conseguiu tocar o WAV. Retorno: ${audio_result:-<sem retorno>}"
      fi

      log "AVISO SONORO: tentando beep eletrônico pelo Windows..."
      if "$powershell_cmd" -NoLogo -NoProfile -NonInteractive -Command \
        "for (\$i = 0; \$i -lt $repeats; \$i++) { [console]::beep(880,220); if (\$i -lt ($repeats - 1)) { Start-Sleep -Milliseconds $gap_ms } }" \
        >/dev/null 2>&1; then
        log "AVISO SONORO: beep eletrônico enviado ao Windows."
        line
        return 0
      fi
      log "AVISO SONORO: beep eletrônico do Windows também falhou."
    else
      log "AVISO SONORO: powershell.exe existe, mas o WSL não consegue executá-lo."
      log "AVISO SONORO: retorno da interoperabilidade: $powershell_probe"
    fi
  else
    log "AVISO SONORO: powershell.exe não está disponível no PATH do WSL."
  fi

  log "AVISO SONORO: tentando campainha do terminal/TTY..."
  local tty_ok=false
  for ((i = 0; i < repeats; i++)); do
    if printf '\a' > /dev/tty 2>/dev/null; then
      tty_ok=true
    else
      printf '\a'
    fi
    [ "$i" -ge $((repeats - 1)) ] || sleep "$(awk "BEGIN { print $gap_ms / 1000 }")"
  done

  if [ "$tty_ok" = true ]; then
    log "AVISO SONORO: campainha enviada ao TTY, mas o terminal pode estar silenciando-a."
  else
    log "AVISO SONORO: nenhuma saída de áudio disponível."
  fi
  line
  return 1
}

error_beep() {
  [ ! -f "$SOUND_DISABLED_FILE" ] || return 0

  # Erro usa um som diferente do aviso de importação. No Windows tentamos o
  # Critical Stop; sem interoperabilidade, caímos no beep eletrônico/TTY.
  (
    BEEP_REPEATS=2
    BEEP_GAP_MS=140
    BEEP_MODE="wave"
    BEEP_VOLUME=28
    BEEP_WAVE_FILE="__dev_automation_error_wave_missing__"
    BEEP_WINDOWS_WAVE_FILE="${ERROR_WINDOWS_WAVE_FILE:-C:\\Windows\\Media\\Windows Critical Stop.wav}"
    soft_beep
  ) >/dev/null 2>&1 || true
  return 0
}

backup_beep() {
  [ ! -f "$SOUND_DISABLED_FILE" ] || return 0
  [ "${BACKUP_BEEP_ENABLED:-true}" = "true" ] || return 0

  local windows_wave="${BACKUP_WINDOWS_WAVE_FILE:-C:\\Windows\\Media\\ding.wav}"
  local powershell_cmd=""
  local escaped_windows_wave=""

  # O backup usa prioritariamente o som nativo solicitado do Windows. O
  # SoundPlayer respeita o volume geral do sistema e bloqueia até o fim do WAV,
  # evitando sobreposição quando vários backups terminam em sequência.
  powershell_cmd="$(command -v powershell.exe 2>/dev/null || true)"
  if [ -n "$powershell_cmd" ]; then
    escaped_windows_wave="${windows_wave//\'/\'\'}"
    if "$powershell_cmd" -NoLogo -NoProfile -NonInteractive -STA -Command \
      "\$ErrorActionPreference = 'Stop'; \
       \$wav = '$escaped_windows_wave'; \
       if (-not (Test-Path -LiteralPath \$wav)) { throw 'Arquivo WAV de backup não encontrado.' }; \
       \$player = New-Object System.Media.SoundPlayer; \
       \$player.SoundLocation = \$wav; \
       \$player.Load(); \
       \$player.PlaySync()" \
      >/dev/null 2>&1; then
      return 0
    fi
  fi

  # Fallback discreto para ambientes sem interoperabilidade WSL/Windows ou sem
  # o ding.wav. Não altera o aviso sonoro usado após downloads/importações.
  (
    BEEP_REPEATS=1
    BEEP_GAP_MS=1
    BEEP_MODE="wave"
    BEEP_VOLUME="${BACKUP_BEEP_VOLUME:-18}"
    BEEP_WAVE_FILE="${BACKUP_BEEP_WAVE_FILE:-$PROJECT_ROOT/assets/sounds/backup-complete.wav}"
    BEEP_WINDOWS_WAVE_FILE="__backup_native_wave_disabled__"
    soft_beep
  ) >/dev/null 2>&1 || true

  return 0
}

