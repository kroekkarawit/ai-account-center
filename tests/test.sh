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

mock_no_codex_processes() {
  cat >"$TMP/bin/pgrep" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$TMP/bin/pgrep"
}

mock_no_codex_processes

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

jq '.tokens.account_id = "account-imported" |
    .tokens.access_token = "access-imported" |
    .tokens.refresh_token = "refresh-imported"' \
  "$AIC_CODEX_HOME/auth.json" >"$TMP/imported-auth.json"
"$ROOT/bin/aic" codex import imported "$TMP/imported-auth.json" >/dev/null
test "$(jq -r '.tokens.account_id' "$AIC_DATA_DIR/accounts/codex/imported.json")" = "account-imported"

jq '.tokens.account_id = "account-pasted" |
    .tokens.access_token = "access-pasted" |
    .tokens.refresh_token = "refresh-pasted"' \
  "$AIC_CODEX_HOME/auth.json" | "$ROOT/bin/aic" codex import pasted >/dev/null
test "$(jq -r '.tokens.account_id' "$AIC_DATA_DIR/accounts/codex/pasted.json")" = "account-pasted"

long_token="$(printf 'x%.0s' $(seq 1 20000))"
jq -c --arg token "$long_token" \
  '.tokens.account_id = "account-long-paste" |
   .tokens.access_token = $token |
   .tokens.refresh_token = $token' \
  "$AIC_CODEX_HOME/auth.json" | "$ROOT/bin/aic" codex import longpaste >/dev/null
test "$(jq -r '.tokens.access_token | length' "$AIC_DATA_DIR/accounts/codex/longpaste.json")" = "20000"

if printf 'q\n' | "$ROOT/bin/aic" codex import cancelled >/dev/null 2>&1; then
  printf 'Expected paste import cancellation to return non-zero\n' >&2
  exit 1
fi
test ! -f "$AIC_DATA_DIR/accounts/codex/cancelled.json"

if printf '{\n' | "$ROOT/bin/aic" codex import incomplete >/dev/null 2>&1; then
  printf 'Expected incomplete paste import to return non-zero\n' >&2
  exit 1
fi
test ! -f "$AIC_DATA_DIR/accounts/codex/incomplete.json"

"$ROOT/bin/aic" codex use personal >/dev/null
test "$(jq -r '.tokens.account_id' "$AIC_CODEX_HOME/auth.json")" = "account-personal"

cat >"$TMP/bin/pgrep" <<'SH'
#!/usr/bin/env bash
if [[ "$*" == *codex* ]]; then
  printf '100 node /opt/homebrew/bin/codex\n'
  exit 0
fi
exit 1
SH
chmod +x "$TMP/bin/pgrep"
cat >"$TMP/bin/ps" <<'SH'
#!/usr/bin/env bash
cat <<'OUT'
100 1 node /opt/homebrew/bin/codex
101 100 /opt/homebrew/lib/node_modules/@openai/codex/vendor/bin/codex
102 101 /opt/homebrew/lib/node_modules/@openai/codex/vendor/bin/codex child-worker
OUT
SH
chmod +x "$TMP/bin/ps"
kill_log="$TMP/kill.log"
output="$(AIC_TEST_KILL_LOG="$kill_log" AIC_TEST_STILL_ALIVE_PIDS="101" AIC_KILL_GRACE_SECONDS=0 "$ROOT/bin/aic" codex use company 2>&1)"
assert_contains "$output" "Codex CLI is currently running"
test "$(jq -r '.tokens.account_id' "$AIC_CODEX_HOME/auth.json")" = "account-company"
grep -q '^TERM 102$' "$kill_log"
grep -q '^TERM 101$' "$kill_log"
grep -q '^TERM 100$' "$kill_log"
grep -q '^KILL 101$' "$kill_log"
mock_no_codex_processes
"$ROOT/bin/aic" codex use personal >/dev/null

cat >"$TMP/bin/pgrep" <<'SH'
#!/usr/bin/env bash
if [[ "$*" == *codex* ]]; then
  printf '23456 /Users/test/.vscode/extensions/openai.chatgpt-test/bin/macos-aarch64/codex app-server --analytics-default-enabled\n'
  exit 0
fi
exit 1
SH
chmod +x "$TMP/bin/pgrep"
output="$("$ROOT/bin/aic" codex use company 2>&1)"
assert_contains "$output" "VS Code Codex app-server is running"
test "$(jq -r '.tokens.account_id' "$AIC_CODEX_HOME/auth.json")" = "account-company"
mock_no_codex_processes
"$ROOT/bin/aic" codex use personal >/dev/null

touch "$TMP/not-a-codex-home"
if AIC_CODEX_HOME="$TMP/not-a-codex-home" "$ROOT/bin/aic" codex use company >/dev/null 2>&1; then
  printf 'Expected account switch to fail when Codex home is not writable\n' >&2
  exit 1
fi
test "$(jq -r '.active_codex_account' "$AIC_DATA_DIR/state.json")" = "personal"

output="$("$ROOT/bin/aic" list)"
assert_contains "$output" "personal"
assert_contains "$output" "company"

printf 'claude-test-token\n' | "$ROOT/bin/aic" claude add personal >/dev/null
test "$(jq -r '.token' "$AIC_DATA_DIR/accounts/claude/personal.json")" = "claude-test-token"

output="$("$ROOT/bin/aic" status)"
assert_contains "$output" "CODEX"
assert_contains "$output" "CLAUDE"

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

jq '.account = "company" |
    .limits.five_hour.used_percent = 2 |
    .limits.weekly.used_percent = 4 |
    .limits.five_hour.resets_at_epoch = 1781506075 |
    .limits.weekly.resets_at_epoch = 1781603429' \
  "$AIC_DATA_DIR/usage/codex-personal.json" >"$AIC_DATA_DIR/usage/codex-company.json"
output="$("$ROOT/bin/aic" recommend)"
assert_contains "$output" "Best now: company"
assert_contains "$output" "★ best"
assert_contains "$output" "5h usage is low"

"$ROOT/bin/aic" codex use company >/dev/null
"$ROOT/bin/aic" refresh codex personal
test "$(jq -r '.tokens.account_id' "$AIC_CODEX_HOME/auth.json")" = "account-company"
test "$(jq -r '.active_codex_account' "$AIC_DATA_DIR/state.json")" = "company"

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

output="$("$ROOT/bin/aic" status)"
assert_contains "$output" "[5h"
assert_contains "$output" "13:47]"
assert_contains "$output" "Jun 20, 15:00]"
assert_contains "$output" "12% → 13:47"
assert_contains "$output" "12% → Jun 20, 15:00"

output="$("$ROOT/bin/aic" --help)"
assert_contains "$output" "AI Account Center"
assert_contains "$output" "aic update"

install_app="$TMP/install-app"
install_bin="$TMP/install-bin"
AIC_APP_DIR="$install_app" AIC_INSTALL_DIR="$install_bin" "$ROOT/install.sh" >/dev/null
test -x "$install_app/bin/aic"
test -x "$install_app/install.sh"
test -L "$install_bin/aic"
test "$("$install_bin/aic" version)" = "0.9.0"

output="$(printf 'q' | "$ROOT/bin/aic")"
assert_contains "$output" "Background refresh:"

"$ROOT/bin/aic" codex remove company >/dev/null
test ! -f "$AIC_DATA_DIR/accounts/codex/company.json"
test "$(jq -r '.active_codex_account // empty' "$AIC_DATA_DIR/state.json")" = ""
test "$(jq -r '.tokens.account_id' "$AIC_CODEX_HOME/auth.json")" = "account-company"

"$ROOT/bin/aic" claude remove personal >/dev/null
test ! -f "$AIC_DATA_DIR/accounts/claude/personal.json"

"$ROOT/bin/aic" schedule off >/dev/null
test "$(jq -r '.schedule.enabled' "$AIC_DATA_DIR/config.json")" = "false"

printf 'All tests passed.\n'
