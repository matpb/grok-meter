#!/usr/bin/env bash
# grok-meter — SuperGrok weekly pool + Grok Build share, one JSON line.
# Token is used in memory only, sent only to cli-chat-proxy.grok.com over HTTPS.

set -f
export PATH="/usr/local/bin:/usr/bin:/bin:$PATH:/home/linuxbrew/.linuxbrew/bin"

grok_home="${GROK_HOME:-$HOME/.grok}"
auth="$grok_home/auth.json"
cache="${GROK_METER_CACHE:-${XDG_CONFIG_HOME:-$HOME/.config}/grok-meter/last.json}"
now=$(date +%s)
BILLING_URL="https://cli-chat-proxy.grok.com/v1/billing?format=credits"
SETTINGS_URL="https://cli-chat-proxy.grok.com/v1/settings"

log() { [ -n "${GROK_METER_DEBUG:-}" ] && printf 'grok-meter: %s\n' "$*" >&2; }

# JWT exp check. Unknown exp → try the request rather than skip it.
token_alive() {
    local payload pad exp
    payload=$(printf '%s' "$1" | cut -d. -f2)
    pad=$(( (4 - ${#payload} % 4) % 4 ))
    [ "$pad" -gt 0 ] && payload="$payload$(printf '=%.0s' $(seq 1 $pad))"
    exp=$(printf '%s' "$payload" | tr '_-' '/+' | base64 -d 2>/dev/null | jq -r '.exp // empty' 2>/dev/null)
    [ -n "$exp" ] || return 0
    [ "$exp" -gt "$now" ]
}

normalize() {
    local plan="$1"
    jq -e -c --argjson now "$now" --arg plan "$plan" '
      def toepoch: (sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z") | fromdateiso8601);
      def rint: if . == null then 0 else ((. + 0.5) | floor) end;
      (.config // .) as $c
      | if ($c.creditUsagePercent == null) then error("no usage") else . end
      | ($c.currentPeriod.end // $c.billingPeriodEnd) as $end
      | (if $end == null then 0
         else (($end | toepoch) - $now) end) as $ri0
      | (if $ri0 < 0 then 0 else $ri0 end) as $ri
      | ($c.creditUsagePercent | rint) as $seven
      | (($c.productUsage // []) | map(select(.product == "GrokBuild")) | first) as $gb
      | (if $gb == null then 0 else (($gb.usagePercent // 0) | rint) end) as $five
      | { ok: true, source: "live", age: 0,
          plan: (if $plan == "" then "SuperGrok" else $plan end),
          five:  { pct: $five,  reset_in: $ri,
                   fresh: (if $gb == null then true else (($five == 0) and ($seven == 0)) end) },
          seven: { pct: $seven, reset_in: $ri, fresh: ($seven == 0) } }
    '
}

emit_cache() {
    [ -s "$cache" ] || { printf '{"ok":false,"reason":"no-data"}\n'; return; }
    jq -e -c --argjson now "$now" '
      ($now - (.ts // $now)) as $age
      | if (.ok != true) then error("bad cache") else . end
      | .five.reset_in  as $f | .seven.reset_in as $s
      | { ok: true, source: "cache", age: $age, plan: (.plan // "SuperGrok"),
          five:  (.five  + { reset_in: (if $f == null then null elif ($f - $age) < 0 then 0 else ($f - $age) end) }),
          seven: (.seven + { reset_in: (if $s == null then null elif ($s - $age) < 0 then 0 else ($s - $age) end) }) }
    ' "$cache" 2>/dev/null || printf '{"ok":false,"reason":"parse-error"}\n'
}

write_cache() {
    local dir tmp
    dir=$(dirname "$cache")
    mkdir -p "$dir" 2>/dev/null || return 0
    tmp="$cache.tmp.$$"
    printf '%s' "$1" | jq -c --argjson now "$now" '. + {ts: $now}' > "$tmp" 2>/dev/null || { rm -f "$tmp"; return 0; }
    chmod 600 "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$cache" 2>/dev/null || rm -f "$tmp"
}

plan_from_settings_file() {
    jq -r '.subscription_tier_display // empty' "$1" 2>/dev/null
}

plan_from_live() {
    local tok="$1" resp p
    [ -n "$tok" ] || return 0
    command -v curl >/dev/null 2>&1 || return 0
    set +x
    resp=$(printf 'header = "Authorization: Bearer %s"\n' "$tok" | timeout 10 curl -sS --fail --max-time 10 \
        -K - \
        -H "Accept: application/json" \
        -H "User-Agent: grok-meter/1.0" \
        -H "X-XAI-Token-Auth: xai-grok-cli" \
        "$SETTINGS_URL" 2>/dev/null) || return 0
    p=$(printf '%s' "$resp" | jq -r '.subscription_tier_display // empty' 2>/dev/null)
    [ -n "$p" ] && printf '%s' "$p"
}

try_live() {
    command -v jq >/dev/null 2>&1 || { log "missing jq"; return 1; }

    local tok="" billing="" plan="" resp

    if [ -n "${GROK_METER_BILLING_JSON:-}" ]; then
        [ -s "$GROK_METER_BILLING_JSON" ] || { log "billing fixture missing"; return 1; }
        billing=$(cat "$GROK_METER_BILLING_JSON")
        [ -n "$billing" ] || { log "billing fixture empty"; return 1; }
    else
        command -v curl >/dev/null 2>&1 || { log "missing curl"; return 1; }
        [ -s "$auth" ] || { log "no $auth — run: grok login"; return 1; }
        tok=$(jq -r 'to_entries[0].value.key // empty' "$auth" 2>/dev/null)
        [ -n "$tok" ] || { log "no token in auth.json"; return 1; }
        token_alive "$tok" || { log "access token expired — run grok once to refresh it"; return 1; }
        set +x
        resp=$(printf 'header = "Authorization: Bearer %s"\n' "$tok" | timeout 10 curl -sS --fail --max-time 10 \
            -K - \
            -H "Accept: application/json" \
            -H "User-Agent: grok-meter/1.0" \
            -H "X-XAI-Token-Auth: xai-grok-cli" \
            "$BILLING_URL" 2>/dev/null) || { log "billing endpoint failed"; return 1; }
        billing=$resp
        [ -n "$billing" ] || { log "billing endpoint returned nothing"; return 1; }
    fi

    if [ -n "${GROK_METER_SETTINGS_JSON:-}" ] && [ -s "$GROK_METER_SETTINGS_JSON" ]; then
        plan=$(plan_from_settings_file "$GROK_METER_SETTINGS_JSON")
    elif [ -z "${GROK_METER_BILLING_JSON:-}" ]; then
        plan=$(plan_from_live "$tok")
    fi
    plan="${plan:-SuperGrok}"

    printf '%s' "$billing" | normalize "$plan" 2>/dev/null || { log "could not parse billing response"; return 1; }
}

if out=$(try_live) && [ -n "$out" ]; then
    write_cache "$out"
    printf '%s\n' "$out"
else
    emit_cache
fi
