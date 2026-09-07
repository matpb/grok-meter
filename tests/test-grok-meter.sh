#!/usr/bin/env bash
# Fixture-only tests for grok-meter.sh. Does not hit the network. Does not run install.sh.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SCRIPT="$ROOT/plasmoid/org.mat.grokmeter/contents/scripts/grok-meter.sh"
FIX="$HERE/fixtures"
pass=0
fail=0

die() { printf 'FAIL: %s\n' "$*" >&2; fail=$((fail + 1)); }
ok()  { printf 'ok   %s\n' "$*"; pass=$((pass + 1)); }

make_jwt() {
    local exp="$1" hdr pl
    hdr=$(printf '{"alg":"none","typ":"JWT"}' | openssl base64 -A 2>/dev/null | tr '+/' '-_' | tr -d '=')
    pl=$(printf '{"exp":%s}' "$exp" | openssl base64 -A 2>/dev/null | tr '+/' '-_' | tr -d '=')
    printf '%s.%s.x' "$hdr" "$pl"
}

run_meter() {
    env -u GROK_METER_DEBUG "$@" bash "$SCRIPT"
}

assert_jq() {
    local json="$1" expr="$2" label="$3"
    if printf '%s' "$json" | jq -e "$expr" >/dev/null 2>&1; then
        ok "$label"
    else
        die "$label (got: $json)"
    fi
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# --- 1. live fixture: weekly 22%, GrokBuild 1% ---
got=$(GROK_METER_BILLING_JSON="$FIX/billing-live.json" \
      GROK_METER_SETTINGS_JSON="$FIX/settings.json" \
      GROK_METER_CACHE="$TMP/cache-live.json" \
      GROK_HOME="$TMP/no-auth" \
      run_meter)
assert_jq "$got" '.ok == true and .source == "live"' "live fixture ok/source"
assert_jq "$got" '.seven.pct == 22 and (.seven.pct | type) == "number"' "live fixture seven.pct=22"
assert_jq "$got" '.five.pct == 1 and (.five.pct | type) == "number"' "live fixture five.pct=1"
assert_jq "$got" '.plan == "SuperGrok"' "live fixture plan"
assert_jq "$got" '.seven.fresh == false and .five.fresh == false' "live fixture not fresh"

# --- 2. no GrokBuild product ---
got=$(GROK_METER_BILLING_JSON="$FIX/billing-no-build.json" \
      GROK_METER_SETTINGS_JSON="$FIX/settings.json" \
      GROK_METER_CACHE="$TMP/cache-nobuild.json" \
      GROK_HOME="$TMP/no-auth" \
      run_meter)
assert_jq "$got" '.ok == true and .five.pct == 0 and .five.fresh == true' "no GrokBuild → five 0 fresh"
assert_jq "$got" '.seven.pct == 22 and .seven.fresh == false' "no GrokBuild weekly still 22"

# --- 3. creditUsagePercent=0 → seven.fresh ---
got=$(GROK_METER_BILLING_JSON="$FIX/billing-fresh.json" \
      GROK_METER_SETTINGS_JSON="$FIX/settings.json" \
      GROK_METER_CACHE="$TMP/cache-fresh.json" \
      GROK_HOME="$TMP/no-auth" \
      run_meter)
assert_jq "$got" '.ok == true and .seven.pct == 0 and .seven.fresh == true' "zero weekly → seven.fresh"

# --- 4. missing auth.json, no fixture, no cache ---
mkdir -p "$TMP/empty-home"
got=$(GROK_HOME="$TMP/empty-home" \
      GROK_METER_CACHE="$TMP/missing-cache.json" \
      run_meter)
assert_jq "$got" '.ok == false and (.reason | type) == "string" and (.reason | length) > 0' \
    "missing auth → ok=false with reason"
assert_jq "$got" '.reason == "no-data"' "missing auth reason=no-data"

# --- 5. expired JWT + cache present ---
mkdir -p "$TMP/expired-home"
exp_jwt=$(make_jwt $(( $(date +%s) - 3600 )))
printf '{"https://auth.x.ai::test":{"key":"%s"}}\n' "$exp_jwt" > "$TMP/expired-home/auth.json"
now=$(date +%s)
jq -n --argjson ts $((now - 120)) '{
  ok: true, source: "live", age: 0, plan: "SuperGrok", ts: $ts,
  five:  {pct: 1,  reset_in: 100000, fresh: false},
  seven: {pct: 22, reset_in: 100000, fresh: false}
}' > "$TMP/cache-expired.json"
got=$(GROK_HOME="$TMP/expired-home" \
      GROK_METER_CACHE="$TMP/cache-expired.json" \
      run_meter)
assert_jq "$got" '.ok == true and .source == "cache" and .age > 0' "expired JWT → cache age>0"
assert_jq "$got" '.seven.pct == 22 and .five.pct == 1' "expired JWT cache percents"

# --- 6. malformed billing JSON does not crash ---
printf '{not json\n' > "$TMP/bad.json"
set +e
got=$(GROK_METER_BILLING_JSON="$TMP/bad.json" \
      GROK_METER_CACHE="$TMP/missing-malformed.json" \
      GROK_HOME="$TMP/empty-home" \
      run_meter)
rc=$?
set -e
[ "$rc" -eq 0 ] || die "malformed billing crashed (exit $rc)"
assert_jq "$got" '.ok == false' "malformed billing → ok=false"

# malformed with cache → fallback
got=$(GROK_METER_BILLING_JSON="$TMP/bad.json" \
      GROK_METER_CACHE="$TMP/cache-expired.json" \
      GROK_HOME="$TMP/empty-home" \
      run_meter)
assert_jq "$got" '.ok == true and .source == "cache"' "malformed billing falls back to cache"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
