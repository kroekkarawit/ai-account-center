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

cat >"$TMP/bin/claude" <<'SH'
#!/usr/bin/env bash
exit 1
SH
chmod +x "$TMP/bin/claude"

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

# ---------------------------------------------------------------------------
# The one-line verbs (codex/claude/model/schedule/...) were removed from the
# CLI; the interactive TUI is now the only human interface. Tests therefore
# exercise the library functions directly by sourcing the modules, and keep a
# thin integration layer for the surviving commands (refresh/status/--help/
# version/uninstall + the no-arg TUI + install.sh).
# ---------------------------------------------------------------------------
export AIC_SELF="$ROOT/bin/aic"   # so resolve_self() locates the repo, not a lib file
# shellcheck source=/dev/null
source "$ROOT/lib/aic/_load.sh"
ensure_dirs

assert_contains() {
  local output="$1" expected="$2"
  case "$output" in
    *"$expected"*) ;;
    *) printf 'Expected output to contain: %s\nActual: %s\n' "$expected" "$output" >&2; exit 1 ;;
  esac
}

jwt_payload() {
  jq -cn --arg email "$1" --arg sub "$2" '{email: $email, sub: $sub}' |
    base64 |
    tr -d '\n=' |
    tr '+/' '-_'
}

save_live_codex_as personal >/dev/null
test -f "$AIC_DATA_DIR/accounts/codex/personal.json"
test "$(jq -r '.active_codex_account' "$AIC_DATA_DIR/state.json")" = "personal"

jq '.tokens.account_id = "account-company" |
    .tokens.access_token = "access-company" |
    .tokens.refresh_token = "refresh-company"' \
  "$AIC_CODEX_HOME/auth.json" >"$AIC_CODEX_HOME/auth.json.tmp"
mv "$AIC_CODEX_HOME/auth.json.tmp" "$AIC_CODEX_HOME/auth.json"
save_live_codex_as company >/dev/null

jq --arg id_token "header.$(jwt_payload other@example.com google-oauth2-other).signature" \
  '.tokens.account_id = "account-company" |
   .tokens.id_token = $id_token |
   .tokens.access_token = "access-same-account-other-user" |
   .tokens.refresh_token = "refresh-same-account-other-user"' \
  "$AIC_CODEX_HOME/auth.json" >"$TMP/same-account-other-user.json"
import_codex_auth_json sameaccountother "$TMP/same-account-other-user.json" >/dev/null
test "$(jq -r '.tokens.account_id' "$AIC_DATA_DIR/accounts/codex/sameaccountother.json")" = "account-company"
test "$(jq -r '.tokens.id_token' "$AIC_DATA_DIR/accounts/codex/sameaccountother.json")" = "header.$(jwt_payload other@example.com google-oauth2-other).signature"

if output="$(import_codex_auth_json sameaccountduplicate "$TMP/same-account-other-user.json" 2>&1)"; then
  printf 'Expected same Codex login duplicate to fail\n' >&2
  exit 1
fi
assert_contains "$output" "This Codex login is already stored as 'sameaccountother'."
test ! -f "$AIC_DATA_DIR/accounts/codex/sameaccountduplicate.json"

jq '.tokens.account_id = "account-imported" |
    .tokens.access_token = "access-imported" |
    .tokens.refresh_token = "refresh-imported"' \
  "$AIC_CODEX_HOME/auth.json" >"$TMP/imported-auth.json"
import_codex_auth_json imported "$TMP/imported-auth.json" >/dev/null
test "$(jq -r '.tokens.account_id' "$AIC_DATA_DIR/accounts/codex/imported.json")" = "account-imported"

jq '.tokens.account_id = "account-path-input" |
    .tokens.access_token = "access-path-input" |
    .tokens.refresh_token = "refresh-path-input"' \
  "$AIC_CODEX_HOME/auth.json" >"$TMP/path-auth.json"
printf '%s\n' "$TMP/path-auth.json" | import_codex_auth_json pathinput >/dev/null
test "$(jq -r '.tokens.account_id' "$AIC_DATA_DIR/accounts/codex/pathinput.json")" = "account-path-input"

mkdir -p "$HOME/Desktop"
jq '.tokens.account_id = "account-tilde-path" |
    .tokens.access_token = "access-tilde-path" |
    .tokens.refresh_token = "refresh-tilde-path"' \
  "$AIC_CODEX_HOME/auth.json" >"$HOME/Desktop/tilde-auth.json"
printf '%s\n' '~/Desktop/tilde-auth.json' | import_codex_auth_json tildepath >/dev/null
test "$(jq -r '.tokens.account_id' "$AIC_DATA_DIR/accounts/codex/tildepath.json")" = "account-tilde-path"

jq '.tokens.account_id = "account-pasted" |
    .tokens.access_token = "access-pasted" |
    .tokens.refresh_token = "refresh-pasted"' \
  "$AIC_CODEX_HOME/auth.json" | import_codex_auth_json pasted >/dev/null
test "$(jq -r '.tokens.account_id' "$AIC_DATA_DIR/accounts/codex/pasted.json")" = "account-pasted"

jq '.tokens.account_id = "account-clipboard" |
    .tokens.access_token = "access-clipboard" |
    .tokens.refresh_token = "refresh-clipboard"' \
  "$AIC_CODEX_HOME/auth.json" >"$TMP/clipboard-auth.json"
cat >"$TMP/bin/pbpaste" <<SH
#!/usr/bin/env bash
cat "$TMP/clipboard-auth.json"
SH
chmod +x "$TMP/bin/pbpaste"
printf 'p' | import_codex_auth_json clipboard >/dev/null
test "$(jq -r '.tokens.account_id' "$AIC_DATA_DIR/accounts/codex/clipboard.json")" = "account-clipboard"

cat >"$TMP/clipboard-auth.json" <<'JSON'
{
  "auth_mode": "chatgpt",
  "OPENAI_API_KEY": null,
  "tokens": {
    "id_token": "header.eyJlbWFpbCI6ImNsaXBib2FyZC1yZXBhaXJAZXhhbXBsZS5jb20ifQ.signature",
    "access_token": "access-
clipboard-
repair",
    "refresh_token": "refresh-
clipboard-
repair",
    "account_id": "account-clipboard-repair"
  },
  "last_refresh": "2026-06-15T00:00:00Z"
}
JSON
repair_output="$(printf 'p' | import_codex_auth_json clipboardrepair 2>&1 >/dev/null)"
assert_contains "$repair_output" "Repaired clipboard JSON by removing raw control characters inside quoted strings."
test "$(jq -r '.tokens.access_token' "$AIC_DATA_DIR/accounts/codex/clipboardrepair.json")" = "access-clipboard-repair"
test "$(jq -r '.tokens.refresh_token' "$AIC_DATA_DIR/accounts/codex/clipboardrepair.json")" = "refresh-clipboard-repair"

cat >"$TMP/clipboard-auth.json" <<'JSON'
{
  "tokens": {
    "access_token": "secret-access-token
JSON
if output="$(printf 'p' | import_codex_auth_json badclipboard 2>&1)"; then
  printf 'Expected bad clipboard JSON to fail\n' >&2
  exit 1
fi
assert_contains "$output" "JSON parse failed (clipboard)."
assert_contains "$output" "jq error:"
assert_contains "$output" "Raw clipboard saved for local inspection:"
assert_contains "$output" "Diagnosis: token lines are missing closing quotes."
assert_contains "$output" "\"access_token\": \"[redacted]"
test -f "$AIC_DATA_DIR/runtime/last-invalid-codex-clipboard.txt"
assert_contains "$(cat "$AIC_DATA_DIR/runtime/last-invalid-codex-clipboard.txt")" "secret-access-token"
test ! -f "$AIC_DATA_DIR/accounts/codex/badclipboard.json"

{
  printf '\033[200~'
  jq '.tokens.account_id = "account-bracketed-paste" |
      .tokens.access_token = "access-bracketed-paste" |
      .tokens.refresh_token = "refresh-bracketed-paste"' \
    "$AIC_CODEX_HOME/auth.json"
  printf '\033[201~'
} | import_codex_auth_json bracketedpaste >/dev/null
test "$(jq -r '.tokens.account_id' "$AIC_DATA_DIR/accounts/codex/bracketedpaste.json")" = "account-bracketed-paste"

long_token="$(printf 'x%.0s' $(seq 1 20000))"
jq -c --arg token "$long_token" \
  '.tokens.account_id = "account-long-paste" |
   .tokens.access_token = $token |
   .tokens.refresh_token = $token' \
  "$AIC_CODEX_HOME/auth.json" | import_codex_auth_json longpaste >/dev/null
test "$(jq -r '.tokens.access_token | length' "$AIC_DATA_DIR/accounts/codex/longpaste.json")" = "20000"

if printf 'q\n' | import_codex_auth_json cancelled >/dev/null 2>&1; then
  printf 'Expected paste import cancellation to return non-zero\n' >&2
  exit 1
fi
test ! -f "$AIC_DATA_DIR/accounts/codex/cancelled.json"

if printf '{\n' | import_codex_auth_json incomplete >/dev/null 2>&1; then
  printf 'Expected incomplete paste import to return non-zero\n' >&2
  exit 1
fi
test ! -f "$AIC_DATA_DIR/accounts/codex/incomplete.json"

cat >"$TMP/bin/codex" <<'SH'
#!/usr/bin/env bash
if [[ "${1:-}" == "login" ]]; then
  mkdir -p "$CODEX_HOME"
  printf '%s\n' "$*" >"$CODEX_HOME/login-args.txt"
  cat >"$CODEX_HOME/auth.json" <<'JSON'
{
  "auth_mode": "chatgpt",
  "OPENAI_API_KEY": null,
  "tokens": {
    "id_token": "header.eyJlbWFpbCI6ImJyb3dzZXJAZXhhbXBsZS5jb20ifQ.signature",
    "access_token": "access-browser",
    "refresh_token": "refresh-browser",
    "account_id": "account-browser"
  },
  "last_refresh": "2026-06-15T00:00:00Z"
}
JSON
  exit 0
fi
printf 'unexpected codex command: %s\n' "$*" >&2
exit 1
SH
chmod +x "$TMP/bin/codex"

login_codex_browser browser --device-auth >/dev/null
test -f "$AIC_DATA_DIR/accounts/codex/browser.json"
test "$(jq -r '.tokens.account_id' "$AIC_DATA_DIR/accounts/codex/browser.json")" = "account-browser"
test "$(jq -r '.active_codex_account' "$AIC_DATA_DIR/state.json")" = "company"
test "$(jq -r '.tokens.account_id' "$AIC_CODEX_HOME/auth.json")" = "account-company"

switch_codex_impl personal >/dev/null
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
output="$(AIC_TEST_KILL_LOG="$kill_log" AIC_TEST_STILL_ALIVE_PIDS="101" AIC_KILL_GRACE_SECONDS=0 \
  switch_codex_impl company 2>&1)"
assert_contains "$output" "Codex CLI is currently running"
test "$(jq -r '.tokens.account_id' "$AIC_CODEX_HOME/auth.json")" = "account-company"
grep -q '^TERM 102$' "$kill_log"
grep -q '^TERM 101$' "$kill_log"
grep -q '^TERM 100$' "$kill_log"
grep -q '^KILL 101$' "$kill_log"
mock_no_codex_processes
switch_codex_impl personal >/dev/null

cat >"$TMP/bin/pgrep" <<'SH'
#!/usr/bin/env bash
if [[ "$*" == *codex* ]]; then
  printf '23456 /Users/test/.vscode/extensions/openai.chatgpt-test/bin/macos-aarch64/codex app-server --analytics-default-enabled\n'
  exit 0
fi
exit 1
SH
chmod +x "$TMP/bin/pgrep"
output="$(switch_codex_impl company 2>&1)"
assert_contains "$output" "VS Code Codex app-server is running"
test "$(jq -r '.tokens.account_id' "$AIC_CODEX_HOME/auth.json")" = "account-company"
mock_no_codex_processes
switch_codex_impl personal >/dev/null

touch "$TMP/not-a-codex-home"
if ( CODEX_HOME_DIR="$TMP/not-a-codex-home" switch_codex_impl company ) >/dev/null 2>&1; then
  printf 'Expected account switch to fail when Codex home is not writable\n' >&2
  exit 1
fi
test "$(jq -r '.active_codex_account' "$AIC_DATA_DIR/state.json")" = "personal"

output="$(codex_names)"
assert_contains "$output" "personal"
assert_contains "$output" "company"

printf 'claude-test-token\n' | add_claude_token personal >/dev/null
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
output="$(print_codex_recommendations)"
assert_contains "$output" "Best now: company"
assert_contains "$output" "★ best"
assert_contains "$output" "5h usage is low"

switch_codex_impl company >/dev/null
"$ROOT/bin/aic" refresh codex personal
test "$(jq -r '.tokens.account_id' "$AIC_CODEX_HOME/auth.json")" = "account-company"
test "$(jq -r '.active_codex_account' "$AIC_DATA_DIR/state.json")" = "company"

legacy_bin="$TMP/legacy-bin"
legacy_app="$TMP/legacy-app"
mkdir -p "$legacy_bin"
AIC_APP_DIR="$legacy_app" AIC_INSTALL_DIR="$legacy_bin" "$ROOT/install.sh" >/dev/null
rm -f "$legacy_bin/aic"
cp "$legacy_app/bin/aic" "$legacy_bin/aic"
chmod +x "$legacy_bin/aic"
AIC_APP_DIR="$legacy_app" "$legacy_bin/aic" refresh codex personal
test "$(jq -r '.limits.five_hour.remaining_percent' "$AIC_DATA_DIR/usage/codex-personal.json")" = "88"

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

# Claude recommendation/scoring — parity with Codex. Add a heavily-used second
# account; the lightly-used one must win and be marked best.
printf 'claude-work-token\n' | add_claude_token work >/dev/null
jq '.account = "work" |
    .limits.five_hour.used_percent = 82 |
    .limits.weekly.used_percent = 91 |
    .limits.five_hour.remaining_percent = 18 |
    .limits.weekly.remaining_percent = 9' \
  "$AIC_DATA_DIR/usage/claude-personal.json" >"$AIC_DATA_DIR/usage/claude-work.json"
output="$(print_claude_recommendations)"
assert_contains "$output" "Best now: personal"
assert_contains "$output" "★ best"
test "$(best_claude_recommendation | cut -f1)" = "personal"
rm -f "$AIC_DATA_DIR/accounts/claude/work.json" "$AIC_DATA_DIR/usage/claude-work.json"

# Account-kind classification: setup-token vs OAuth login.
test "$(claude_account_kind personal)" = "token"
jq -n '{claudeAiOauth:{accessToken:"sk-ant-oat01-a",refreshToken:"sk-ant-ort01-r",expiresAt:0,scopes:["user:inference"]},organizationUuid:"o",created_at:"t"}' \
  > "$AIC_DATA_DIR/accounts/claude/oauthy.json"
test "$(claude_account_kind oauthy)" = "oauth"
test "$(claude_oauth_names | grep -c '^oauthy$')" = "1"
test "$(claude_token_names | grep -c '^personal$')" = "1"
test "$(claude_oauth_names | grep -c '^personal$')" = "0"

# Clobber guard: add_claude_token must REFUSE to overwrite an OAuth account
# (a bare setup-token would strip its refresh token and break global switching).
if printf 'sk-ant-oat01-new\n' | add_claude_token oauthy >/dev/null 2>&1; then
  echo "FAIL: add_claude_token overwrote an OAuth account"; exit 1
fi
test "$(claude_account_kind oauthy)" = "oauth"
rm -f "$AIC_DATA_DIR/accounts/claude/oauthy.json"

# Import a full OAuth login from a base64 keychain blob (another machine).
blob_json='{"claudeAiOauth":{"accessToken":"sk-ant-oat01-imp","refreshToken":"sk-ant-ort01-imp","expiresAt":1783342808084,"scopes":["user:inference","user:profile"],"subscriptionType":"pro"},"mcpOAuth":{}}'
blob_b64="$(printf '%s' "$blob_json" | base64 | tr -d '\n')"
printf '%s\n' "$blob_b64" | import_claude_oauth_blob imported >/dev/null
test "$(claude_account_kind imported)" = "oauth"
test "$(jq -r '.claudeAiOauth.refreshToken' "$AIC_DATA_DIR/accounts/claude/imported.json")" = "sk-ant-ort01-imp"
# A blob without a refresh token (setup-token shape) must be rejected.
notoken_b64="$(printf '{"claudeAiOauth":{"accessToken":"sk-ant-oat01-x"}}' | base64 | tr -d '\n')"
if printf '%s\n' "$notoken_b64" | import_claude_oauth_blob rejectme >/dev/null 2>&1; then
  echo "FAIL: imported a credential with no refresh token"; exit 1
fi
test ! -f "$AIC_DATA_DIR/accounts/claude/rejectme.json"
rm -f "$AIC_DATA_DIR/accounts/claude/imported.json"

# At 100% usage the probe is rejected with HTTP 429, but Anthropic still returns
# the rate-limit headers. Those must be trusted (100% used + reset), not shown
# as an error.
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
HTTP/2 429
anthropic-ratelimit-unified-5h-status: rejected
anthropic-ratelimit-unified-5h-reset: 1781506200
anthropic-ratelimit-unified-5h-utilization: 1.0
anthropic-ratelimit-unified-7d-status: allowed
anthropic-ratelimit-unified-7d-reset: 1781942400
anthropic-ratelimit-unified-7d-utilization: 0.5
HEADERS
printf '%s\n' '{"type":"error","error":{"type":"rate_limit_error","message":"This request would exceed your account rate limit."}}' >"$body"
printf '429'
SH
chmod +x "$TMP/bin/curl"

"$ROOT/bin/aic" refresh claude personal
test "$(jq -r '.status' "$AIC_DATA_DIR/usage/claude-personal.json")" = "ok"
test "$(jq -r '.source' "$AIC_DATA_DIR/usage/claude-personal.json")" = "inference_headers"
test "$(jq -r '.limits.five_hour.used_percent' "$AIC_DATA_DIR/usage/claude-personal.json")" = "100"
test "$(jq -r '.limits.five_hour.remaining_percent' "$AIC_DATA_DIR/usage/claude-personal.json")" = "0"
test "$(jq -r '.limits.weekly.used_percent' "$AIC_DATA_DIR/usage/claude-personal.json")" = "50"

# Restore the 94/88 usage record so later status assertions are unaffected.
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
test "$(jq -r '.limits.five_hour.remaining_percent' "$AIC_DATA_DIR/usage/claude-personal.json")" = "94"

output="$("$ROOT/bin/aic" status)"
assert_contains "$output" "[5h"
assert_contains "$output" "13:47]"
assert_contains "$output" "Jun 20, 15:00]"
assert_contains "$output" "12% → 13:47"
assert_contains "$output" "12% → Jun 20, 15:00"

output="$("$ROOT/bin/aic" --help)"
assert_contains "$output" "AI Account Center"
assert_contains "$output" "aic update"
assert_contains "$output" "aic uninstall"

install_app="$TMP/install-app"
install_bin="$TMP/install-bin"
AIC_APP_DIR="$install_app" AIC_INSTALL_DIR="$install_bin" "$ROOT/install.sh" >/dev/null
test -x "$install_app/bin/aic"
test -x "$install_app/install.sh"
test -f "$install_app/lib/aic/_load.sh"
test -L "$install_bin/aic"
expected_version="$("$ROOT/bin/aic" version)"
test "$("$install_bin/aic" version)" = "$expected_version"

uninstall_data="$TMP/uninstall-data"
mkdir -p "$uninstall_data"
touch "$uninstall_data/keep.json"
AIC_DATA_DIR="$uninstall_data" AIC_APP_DIR="$install_app" AIC_INSTALL_DIR="$install_bin" "$install_bin/aic" uninstall --yes >/dev/null
test ! -e "$install_bin/aic"
test ! -d "$install_app"
test -f "$uninstall_data/keep.json"

output="$(printf 'q' | "$ROOT/bin/aic")"
assert_contains "$output" "refresh:"

rename_codex_account company company-renamed >/dev/null
test ! -f "$AIC_DATA_DIR/accounts/codex/company.json"
test -f "$AIC_DATA_DIR/accounts/codex/company-renamed.json"
test "$(jq -r '.tokens.account_id' "$AIC_DATA_DIR/accounts/codex/company-renamed.json")" = "account-company"

printf 'claude-rename-test\n' | add_claude_token rename-src >/dev/null
rename_claude_account rename-src rename-dst >/dev/null
test ! -f "$AIC_DATA_DIR/accounts/claude/rename-src.json"
test -f "$AIC_DATA_DIR/accounts/claude/rename-dst.json"
test "$(jq -r '.token' "$AIC_DATA_DIR/accounts/claude/rename-dst.json")" = "claude-rename-test"
remove_claude rename-dst >/dev/null

remove_codex_impl company-renamed >/dev/null
test ! -f "$AIC_DATA_DIR/accounts/codex/company-renamed.json"
test "$(jq -r '.active_codex_account // empty' "$AIC_DATA_DIR/state.json")" = ""
test "$(jq -r '.tokens.account_id' "$AIC_CODEX_HOME/auth.json")" = "account-company"

# Claude account switch tests
# Create a full OAuth account (future expiresAt = not expired)
future_ms=$(( ($(date +%s) + 3600) * 1000 ))
oauth_blob="$(jq -n \
  --argjson exp "$future_ms" \
  '{claudeAiOauth:{accessToken:"sk-ant-oat01-test",refreshToken:"sk-ant-ort01-test",expiresAt:$exp,scopes:["user:inference"],subscriptionType:"pro",rateLimitTier:"default"},organizationUuid:"test-org-uuid",created_at:"2026-01-01T00:00:00Z"}')"
printf '%s\n' "$oauth_blob" >"$AIC_DATA_DIR/accounts/claude/switch-test.json"
chmod 600 "$AIC_DATA_DIR/accounts/claude/switch-test.json"

# Set up a fake live keychain file
CLAUDE_CRED_FILE="$TMP/claude-creds.json"
export CLAUDE_CRED_FILE
printf '{"claudeAiOauth":{"accessToken":"old-token","refreshToken":"old-rt","expiresAt":1000},"organizationUuid":"old-org","mcpOAuth":{"plugin:test":{"accessToken":"mcp-token"}}}\n' >"$CLAUDE_CRED_FILE"

# Switch to the new account
switch_claude_impl switch-test >/dev/null

# Verify: accessToken and orgUuid updated, mcpOAuth preserved
test "$(jq -r '.claudeAiOauth.accessToken' "$CLAUDE_CRED_FILE")" = "sk-ant-oat01-test"
test "$(jq -r '.organizationUuid' "$CLAUDE_CRED_FILE")" = "test-org-uuid"
test "$(jq -r '.mcpOAuth["plugin:test"].accessToken' "$CLAUDE_CRED_FILE")" = "mcp-token"
test "$(jq -r '.active_claude_account' "$AIC_DATA_DIR/state.json")" = "switch-test"

# The dashboard marks the active Claude account with ">" (same as Codex).
output="$("$ROOT/bin/aic" status)"
assert_contains "$output" ">switch-test"

# Claude credential lock: cooperates with Claude Code's ~/.claude.lock so a swap
# never interleaves with a running claude's token refresh.
test "$(claude_credentials_lock_dir)" = "$HOME/.claude.lock"
rm -rf "$(claude_credentials_lock_dir)"
with_claude_credentials_lock true
test ! -d "$(claude_credentials_lock_dir)"                 # released after use
# A stale lock (mtime > 10s old) is stolen, so a switch never blocks forever.
mkdir -p "$(claude_credentials_lock_dir)"
touch -t 200001010000 "$(claude_credentials_lock_dir)"
with_claude_credentials_lock bash -c "printf ran > '$TMP/lock-ran'"
test "$(cat "$TMP/lock-ran")" = "ran"                     # ran despite stale lock
test ! -d "$(claude_credentials_lock_dir)"                # released

# Verify expired token detection: create account with past expiresAt
past_ms=$(( ($(date +%s) - 3600) * 1000 ))
expired_blob="$(jq -n \
  --argjson exp "$past_ms" \
  '{claudeAiOauth:{accessToken:"sk-ant-oat01-expired",refreshToken:"sk-ant-ort01-expired",expiresAt:$exp,scopes:["user:inference"],subscriptionType:"pro",rateLimitTier:"default"},organizationUuid:"expired-org","created_at":"2026-01-01T00:00:00Z"}')"
printf '%s\n' "$expired_blob" >"$AIC_DATA_DIR/accounts/claude/expired-test.json"
chmod 600 "$AIC_DATA_DIR/accounts/claude/expired-test.json"

# Switching with expired token writes it to keychain and calls claude auth status;
# since there's no real claude, the refresh fails gracefully but switch still happens
switch_claude_impl expired-test >/dev/null 2>&1 || true
test "$(jq -r '.active_claude_account' "$AIC_DATA_DIR/state.json")" = "expired-test"

# Verify token-only accounts (from add_claude_token) cannot switch
if ( switch_claude_impl personal ) >/dev/null 2>&1; then
  printf 'ERROR: token-only account should have failed switch\n' >&2
  exit 1
fi

cat >"$TMP/bin/claude" <<'SH'
#!/usr/bin/env bash
if [[ "$1" == "auth" && "$2" == "login" && "$3" == "--claudeai" ]]; then
  cat >"$CLAUDE_CRED_FILE" <<'JSON'
{"claudeAiOauth":{"accessToken":"sk-ant-oat01-relogin","refreshToken":"sk-ant-ort01-relogin","expiresAt":4102444800000,"scopes":["user:inference"],"subscriptionType":"pro","rateLimitTier":"default"},"organizationUuid":"relogin-org"}
JSON
  exit 0
fi
exit 1
SH
chmod +x "$TMP/bin/claude"
hash -r

relogin_claude_oauth personal >/dev/null
test "$(jq -r '.claudeAiOauth.refreshToken' "$AIC_DATA_DIR/accounts/claude/personal.json")" = "sk-ant-ort01-relogin"
switch_claude_impl personal >/dev/null
test "$(jq -r '.active_claude_account' "$AIC_DATA_DIR/state.json")" = "personal"

# Parallel-account session: "Run a profile session" candidate filter.
printf 'sk-ant-oat01-parA\n' | add_claude_token par-a >/dev/null   # setup-token kind
jq -n '{claudeAiOauth:{accessToken:"a",refreshToken:"r",expiresAt:0,scopes:[]},created_at:"t"}' \
  >"$AIC_DATA_DIR/accounts/claude/par-b.json"                       # oauth kind
clear_active_claude_name
test "$(claude_account_kind par-a)" = "token"
test "$(claude_account_kind par-b)" = "oauth"
# both are candidates when not the global-active account
test "$(claude_parallel_candidates | grep -c '^par-a$')" = "1"
test "$(claude_parallel_candidates | grep -c '^par-b$')" = "1"
# a running account is NOT hidden (it stays a candidate, just flagged elsewhere)
register_claude_session par-a
test "$(claude_parallel_candidates | grep -c '^par-a$')" = "1"
# claude_account_in_session: a dead pid reports not-running and is pruned
printf '99999999' >"$(claude_session_pid_file par-b)"
claude_account_in_session par-b && { echo "FAIL: dead pid reported running"; exit 1; }
test ! -f "$(claude_session_pid_file par-b)"
# claude_account_in_session: a live NON-claude pid ($$ = bash) is not a claude session
test "$(cat "$(claude_session_pid_file par-a)")" = "$$"
claude_account_in_session par-a && { echo "FAIL: bash pid flagged as claude session"; exit 1; }
# the global-active account is never a parallel candidate
rm -f "$(claude_session_pid_file par-a)"
set_active_claude_name par-a
test "$(claude_parallel_candidates | grep -c '^par-a$')" = "0"
clear_active_claude_name
remove_claude par-a >/dev/null; remove_claude par-b >/dev/null
rm -f "$(claude_session_pid_file par-a)"

# reclaim_claude_session: a stale (dead-pid) session registration is pruned.
jq -n '{claudeAiOauth:{accessToken:"a",refreshToken:"r",expiresAt:0,scopes:[]},organizationUuid:"o",created_at:"t"}' \
  >"$AIC_DATA_DIR/accounts/claude/rec-a.json"
printf '99999998' >"$(claude_session_pid_file rec-a)"   # dead pid → pruned, no kill
reclaim_claude_session rec-a warn >/dev/null
test ! -f "$(claude_session_pid_file rec-a)"   # pid pruned
remove_claude rec-a >/dev/null

# Clean up
remove_claude switch-test >/dev/null
remove_claude expired-test >/dev/null
unset CLAUDE_CRED_FILE

remove_claude personal >/dev/null
test ! -f "$AIC_DATA_DIR/accounts/claude/personal.json"

# Model profile tests — create profile directly (bypass interactive wizard)
profile_file="$AIC_DATA_DIR/model-profiles/test-deepseek.json"
jq -n '{
  name:"test-deepseek",
  display_name:"DeepSeek V4 Pro",
  base_url:"https://api.deepseek.com/anthropic",
  api_key:"sk-test-deepseek-key",
  default_model:"deepseek-v4-pro",
  opus_model:"deepseek-v4-pro",
  sonnet_model:"deepseek-v4-pro",
  haiku_model:"deepseek-v4-flash",
  subagent_model:"deepseek-v4-flash",
  created_at:"2026-01-01T00:00:00Z"
}' >"$profile_file"
chmod 600 "$profile_file"

# list (model_profile_names + display name)
output="$(model_profile_names)"
assert_contains "$output" "test-deepseek"
assert_contains "$(jq -r '.display_name' "$profile_file")" "DeepSeek V4 Pro"

# launch_with_profile: mock claude binary prints the env it receives
cat >"$TMP/bin/claude" <<'SH'
#!/usr/bin/env bash
printf 'ANTHROPIC_BASE_URL=%s\n' "${ANTHROPIC_BASE_URL:-}"
printf 'ANTHROPIC_AUTH_TOKEN=%s\n' "${ANTHROPIC_AUTH_TOKEN:-}"
printf 'ANTHROPIC_MODEL=%s\n' "${ANTHROPIC_MODEL:-}"
printf 'ANTHROPIC_DEFAULT_OPUS_MODEL=%s\n' "${ANTHROPIC_DEFAULT_OPUS_MODEL:-}"
printf 'ANTHROPIC_DEFAULT_HAIKU_MODEL=%s\n' "${ANTHROPIC_DEFAULT_HAIKU_MODEL:-}"
printf 'CLAUDE_CODE_SUBAGENT_MODEL=%s\n' "${CLAUDE_CODE_SUBAGENT_MODEL:-}"
SH
chmod +x "$TMP/bin/claude"

output="$(launch_with_profile test-deepseek 2>/dev/null)"
assert_contains "$output" "ANTHROPIC_BASE_URL=https://api.deepseek.com/anthropic"
assert_contains "$output" "ANTHROPIC_AUTH_TOKEN=sk-test-deepseek-key"
assert_contains "$output" "ANTHROPIC_MODEL=deepseek-v4-pro"
assert_contains "$output" "ANTHROPIC_DEFAULT_OPUS_MODEL=deepseek-v4-pro"
assert_contains "$output" "ANTHROPIC_DEFAULT_HAIKU_MODEL=deepseek-v4-flash"
assert_contains "$output" "CLAUDE_CODE_SUBAGENT_MODEL=deepseek-v4-flash"

# launch_codex_with_profile: mock codex binary prints the env and args it receives
cat >"$TMP/bin/codex" <<'SH'
#!/usr/bin/env bash
printf 'OPENAI_API_KEY=%s\n' "${OPENAI_API_KEY:-}"
printf 'OPENAI_BASE_URL=%s\n' "${OPENAI_BASE_URL:-}"
printf 'ARGS=%s\n' "$*"
SH
chmod +x "$TMP/bin/codex"

output="$(launch_codex_with_profile test-deepseek --no-alt-screen 2>/dev/null)"
assert_contains "$output" "OPENAI_API_KEY=sk-test-deepseek-key"
assert_contains "$output" "OPENAI_BASE_URL=https://api.deepseek.com"
assert_contains "$output" 'ARGS=-c openai_base_url="https://api.deepseek.com" --model deepseek-v4-pro --no-alt-screen'

# remove
remove_model_profile test-deepseek >/dev/null
test ! -f "$profile_file"

disable_schedule >/dev/null
test "$(jq -r '.schedule.enabled' "$AIC_DATA_DIR/config.json")" = "false"

# ---------------------------------------------------------------------------
# Account transfer (encrypted export/import) — spec §7
# ---------------------------------------------------------------------------
cat >"$AIC_CODEX_HOME/auth.json" <<'JSON'
{"auth_mode":"chatgpt","OPENAI_API_KEY":null,"tokens":{"id_token":"h.eyJlbWFpbCI6InhAeC5jb20ifQ.s","access_token":"ax-a","refresh_token":"rtx-a","account_id":"acct-XA"}}
JSON
save_live_codex_as xfera >/dev/null
jq '.tokens.account_id="acct-XB"|.tokens.access_token="ax-b"|.tokens.refresh_token="rtx-b"' \
  "$AIC_CODEX_HOME/auth.json" >"$AIC_CODEX_HOME/auth.json.tmp"
mv "$AIC_CODEX_HOME/auth.json.tmp" "$AIC_CODEX_HOME/auth.json"
save_live_codex_as xferb >/dev/null
xfer_future=$(( ($(date +%s) + 3600) * 1000 ))
jq -n --argjson e "$xfer_future" \
  '{claudeAiOauth:{accessToken:"cx",refreshToken:"rtx-c",expiresAt:$e},organizationUuid:"org-X"}' \
  >"$AIC_DATA_DIR/accounts/claude/xferc.json"
chmod 600 "$AIC_DATA_DIR/accounts/claude/xferc.json"

# build + encode + decode round-trip is lossless
xfer_payload="$(build_transfer_payload codex:xfera codex:xferb claude:xferc)"
test "$(jq -r '.accounts | length' <<<"$xfer_payload")" = "3"
xfer_blob="$(printf '%s' "$xfer_payload" | transfer_encode)"
case "$xfer_blob" in AIC1.*) ;; *) printf 'blob prefix wrong: %s\n' "$xfer_blob" >&2; exit 1 ;; esac
xfer_dec="$(transfer_decode "$xfer_blob")"
test "$(jq -rS . <<<"$xfer_dec")" = "$(jq -rS . <<<"$xfer_payload")"

# expiry: fresh ok, 3-day-old refused
if transfer_payload_expired "$xfer_dec"; then printf 'fresh transfer flagged expired\n' >&2; exit 1; fi
if ! transfer_payload_expired "$(jq '.created_at -= 999999' <<<"$xfer_payload")"; then
  printf 'old transfer not flagged expired\n' >&2; exit 1
fi

# decode error codes: corrupt=4, newer version=3, not-an-aic-blob=2
xfer_rc=0; transfer_decode "AIC1.1.@@notbase64@@" >/dev/null 2>&1 || xfer_rc=$?; test "$xfer_rc" = "4"
xfer_rc=0; transfer_decode "AIC2.1.abcd"         >/dev/null 2>&1 || xfer_rc=$?; test "$xfer_rc" = "3"
xfer_rc=0; transfer_decode "just some text"      >/dev/null 2>&1 || xfer_rc=$?; test "$xfer_rc" = "2"

# duplicate detection + name helpers
xfer_adata="$(jq -c '.accounts[0].data' <<<"$xfer_dec")"
test "$(transfer_identity_conflict codex "$xfer_adata")" = "xfera"
if ! transfer_name_exists codex xfera; then printf 'xfera should exist\n' >&2; exit 1; fi
if transfer_name_exists codex nope-nope; then printf 'nope-nope should not exist\n' >&2; exit 1; fi
test "$(transfer_unique_name codex xfera)" = "xfera-2"

# write a brand-new account from transfer data + validate
xfer_newdata="$(jq -c '.tokens.account_id="acct-XN"|.tokens.access_token="ax-n"|.tokens.refresh_token="rtx-n"' \
  "$(codex_account_file xfera)")"
transfer_write_account codex xferimported "$xfer_newdata"
test "$(jq -r '.tokens.account_id' "$AIC_DATA_DIR/accounts/codex/xferimported.json")" = "acct-XN"

# overwrite backs up the previous file
transfer_write_account codex xferimported "$xfer_newdata"
ls "$AIC_DATA_DIR/backups/"xferimported-xfer-*.json >/dev/null 2>&1 ||
  { printf 'no backup created on overwrite\n' >&2; exit 1; }

# invalid data is rejected, nothing written
if transfer_write_account codex xferbad '{"garbage":true}' 2>/dev/null; then
  printf 'invalid transfer data was accepted\n' >&2; exit 1
fi
test ! -f "$AIC_DATA_DIR/accounts/codex/xferbad.json"

# claude account writes from transfer data
xfer_cdata="$(jq -c '.accounts[2].data' <<<"$xfer_dec")"
transfer_write_account claude xferc2 "$xfer_cdata"
test "$(jq -r '.claudeAiOauth.refreshToken' "$AIC_DATA_DIR/accounts/claude/xferc2.json")" = "rtx-c"

printf 'All tests passed.\n'
