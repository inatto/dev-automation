#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
SCRIPT="$ROOT/scripts/chromes/ubuntu.sh"
TMP="$(mktemp -d /tmp/chromes-profile-test-XXXXXX)"
trap 'rm -rf -- "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/home/.config/google-chrome/Default" "$TMP/home/.config/google-chrome/Profile 3"
cat > "$TMP/home/.config/google-chrome/Local State" <<'JSON'
{
  "profile": {
    "last_used": "Profile 3",
    "info_cache": {
      "Default": {"name": "Daniel", "gaia_name": "Daniel Maia", "user_name": "daniel@example.test", "active_time": 10},
      "Profile 3": {"name": "Sindicatto", "gaia_name": "Sindicatto", "user_name": "admin@sindicatto.test", "active_time": 20}
    }
  }
}
JSON
cat > "$TMP/bin/google-chrome-stable" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CHROMES_TEST_LOG"
FAKE
chmod +x "$TMP/bin/google-chrome-stable"

OUT="$(HOME="$TMP/home" PATH="$TMP/bin:$PATH" "$SCRIPT" --diagnose 2>&1)"
grep -Fq 'Profile 3' <<<"$OUT"
grep -Fq 'nome=Sindicatto' <<<"$OUT"
grep -Fq 'Sindicatto resolvido: Profile 3 (detectado pelo nome/metadados)' <<<"$OUT"

: > "$TMP/chrome.log"
HOME="$TMP/home" PATH="$TMP/bin:$PATH" CHROMES_TEST_LOG="$TMP/chrome.log" CHROMES_LOCAL_URLS="https://admin.localhost/" "$SCRIPT" >/dev/null
# Os dois lançamentos são assíncronos; espere só o necessário para o fake gravar.
for _ in {1..20}; do
  [[ "$(wc -l < "$TMP/chrome.log")" -ge 2 ]] && break
  sleep 0.05
done
grep -Fq -- '--profile-directory=Default' "$TMP/chrome.log"
grep -Fq -- '--profile-directory=Profile 3' "$TMP/chrome.log"

echo 'OK: chromes Ubuntu diagnostica e resolve Sindicatto pelo Local State real.'
