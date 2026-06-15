#!/usr/bin/env bash

set -eu

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export HOME="$TMP/home"
export AIC_DATA_DIR="$TMP/data"
export AIC_CODEX_HOME="$TMP/codex"
mkdir -p "$HOME" "$AIC_CODEX_HOME" "$TMP/bin"
export PATH="$TMP/bin:$PATH"

cat >"$AIC_CODEX_HOME/auth.json" <<'JSON'
{
  "auth_mode": "chatgpt",
  "OPENAI_API_KEY": null,
  "tokens": {
    "id_token": "header.eyJlbWFpbCI6InBlcnNvbmFsQGV4YW1wbGUuY29tIn0.signature",
    "access_token": "access-personal",
    "refresh_token": "refresh-personal",
    "account_id": "account-personal"
  },
  "last_refresh": "2026-06-15T00:00:00Z"
}
JSON

chmod +x "$ROOT/bin/aic"

assert_contains() {
  local output="$1" expected="$2"
  case "$output" in
    *"$expected"*) ;;
    *) printf 'Expected output to contain: %s\nActual: %s\n' "$expected" "$output" >&2; exit 1 ;;
  esac
}

"$ROOT/bin/aic" codex add personal >/dev/null
test -f "$AIC_DATA_DIR/accounts/codex/personal.json"
test "$(jq -r '.active_codex_account' "$AIC_DATA_DIR/state.json")" = "personal"

jq '.tokens.account_id = "account-company" |
    .tokens.access_token = "access-company" |
    .tokens.refresh_token = "refresh-company"' \
  "$AIC_CODEX_HOME/auth.json" >"$AIC_CODEX_HOME/auth.json.tmp"
mv "$AIC_CODEX_HOME/auth.json.tmp" "$AIC_CODEX_HOME/auth.json"
"$ROOT/bin/aic" codex add company >/dev/null

"$ROOT/bin/aic" codex use personal >/dev/null
test "$(jq -r '.tokens.account_id' "$AIC_CODEX_HOME/auth.json")" = "account-personal"

output="$("$ROOT/bin/aic" list)"
assert_contains "$output" "personal"
assert_contains "$output" "company"

printf 'claude-test-token\n' | "$ROOT/bin/aic" claude add personal >/dev/null
test "$(jq -r '.token' "$AIC_DATA_DIR/accounts/claude/personal.json")" = "claude-test-token"

output="$("$ROOT/bin/aic" status)"
assert_contains "$output" "codex"
assert_contains "$output" "claude"

cat >"$TMP/bin/codex" <<'SH'
#!/usr/bin/env bash
while IFS= read -r line; do
  id="$(jq -r '.id // empty' <<<"$line")"
  if [[ "$id" == "1" ]]; then
    printf '%s\n' '{"id":1,"result":{"userAgent":"mock","codexHome":"/tmp","platformFamily":"unix","platformOs":"macos"}}'
  elif [[ "$id" == "2" ]]; then
    printf '%s\n' '{"id":2,"result":{"rateLimits":{"limitId":"codex","planType":"plus","primary":{"usedPercent":12,"windowDurationMins":300,"resetsAt":1781506075},"secondary":{"usedPercent":34,"windowDurationMins":10080,"resetsAt":1781603429}}}}'
  fi
done
SH
chmod +x "$TMP/bin/codex"

"$ROOT/bin/aic" refresh codex personal
test "$(jq -r '.limits.five_hour.remaining_percent' "$AIC_DATA_DIR/usage/codex-personal.json")" = "88"
test "$(jq -r '.limits.weekly.remaining_percent' "$AIC_DATA_DIR/usage/codex-personal.json")" = "66"

cat >"$TMP/bin/curl" <<'SH'
#!/usr/bin/env bash
if [[ "$*" == *"/api/oauth/usage"* ]]; then
  printf '%s\n' '{"five_hour":{"utilization":4,"resets_at":"2026-06-15T06:49:59Z"},"seven_day":{"utilization":13,"resets_at":"2026-06-20T07:59:59Z"}}'
fi
SH
chmod +x "$TMP/bin/curl"

"$ROOT/bin/aic" refresh claude personal
test "$(jq -r '.limits.five_hour.remaining_percent' "$AIC_DATA_DIR/usage/claude-personal.json")" = "96"
test "$(jq -r '.limits.weekly.remaining_percent' "$AIC_DATA_DIR/usage/claude-personal.json")" = "87"

cat >"$TMP/bin/curl" <<'SH'
#!/usr/bin/env bash
if [[ "$*" == *"/api/oauth/usage"* ]]; then
  printf '%s\n' '{"error":{"message":"OAuth token does not meet scope requirement user:profile"}}'
  exit 0
fi

headers=""
body=""
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    -D) headers="$2"; shift 2 ;;
    -o) body="$2"; shift 2 ;;
    *) shift ;;
  esac
done
cat >"$headers" <<'HEADERS'
HTTP/2 200
anthropic-ratelimit-unified-5h-reset: 1781506200
anthropic-ratelimit-unified-5h-utilization: 0.06
anthropic-ratelimit-unified-7d-reset: 1781942400
anthropic-ratelimit-unified-7d-utilization: 0.12
HEADERS
printf '%s\n' '{"content":[{"type":"text","text":"1"}]}' >"$body"
printf '200'
SH
chmod +x "$TMP/bin/curl"

"$ROOT/bin/aic" refresh claude personal
test "$(jq -r '.source' "$AIC_DATA_DIR/usage/claude-personal.json")" = "inference_headers"
test "$(jq -r '.limits.five_hour.remaining_percent' "$AIC_DATA_DIR/usage/claude-personal.json")" = "94"
test "$(jq -r '.limits.weekly.remaining_percent' "$AIC_DATA_DIR/usage/claude-personal.json")" = "88"

"$ROOT/bin/aic" schedule off >/dev/null
test "$(jq -r '.schedule.enabled' "$AIC_DATA_DIR/config.json")" = "false"

printf 'All tests passed.\n'
