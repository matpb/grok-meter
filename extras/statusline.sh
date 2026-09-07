#!/usr/bin/env bash
# Grok Meter status line: prints `Grok 7d N% · CLI N%` from grok-meter.sh.
set -f
export PATH="/usr/local/bin:/usr/bin:/bin:$PATH:/home/linuxbrew/.linuxbrew/bin"
cat >/dev/null || true

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../plasmoid/org.mat.grokmeter/contents/scripts/grok-meter.sh"
if [ ! -x "$SCRIPT" ]; then
    SCRIPT="${HOME}/.local/share/plasma/plasmoids/org.mat.grokmeter/contents/scripts/grok-meter.sh"
fi
[ -x "$SCRIPT" ] || { printf 'Grok no data\n'; exit 0; }

out=$("$SCRIPT" 2>/dev/null | tail -n 1)
[ -n "$out" ] || { printf 'Grok no data\n'; exit 0; }

line=$(printf '%s' "$out" | jq -r '
  if .ok == true then
    "Grok 7d \(.seven.pct)% · CLI \(.five.pct)%"
  else
    "Grok no data"
  end
' 2>/dev/null) || line="Grok no data"

printf '%s\n' "$line"
