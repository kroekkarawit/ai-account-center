# shellcheck shell=bash
# aic module: claude
# Claude accounts: keychain, OAuth import, subscription login, switch
# Sourced by lib/aic/_load.sh; not executed directly.

# Strip whitespace and control bytes from a Claude OAuth access token.
sanitize_claude_token() {
  printf '%s' "$1" | tr -d '[:space:][:cntrl:]'
}

# Supported Claude accounts are full OAuth browser logins with a refresh token.
# Older refresh-token-less records are classified as unsupported and are kept
# only so users can remove or replace them.
claude_account_kind() {
  local file
  file="$(claude_account_file "$1")"
  [[ -f "$file" ]] || { printf ''; return; }
  if [[ -n "$(jq -r '.claudeAiOauth.refreshToken // empty' "$file" 2>/dev/null)" ]]; then
    printf 'oauth'
  else
    printf 'unsupported'
  fi
}

claude_oauth_names() {
  local n
  while IFS= read -r n; do
    [[ -n "$n" ]] || continue
    [[ "$(claude_account_kind "$n")" == "oauth" ]] && printf '%s\n' "$n"
  done < <(claude_names)
}

# Short "[5h x%  7d y%]" badge from cached usage, for the launcher list.
claude_token_usage_badge() {
  local uf
  uf="$(usage_file claude "$1")"
  [[ -f "$uf" ]] || return 0
  if [[ "$(jq -r '.status // ""' "$uf" 2>/dev/null)" != "ok" ]]; then
    printf '[usage ?]'
    return 0
  fi
  local five week
  five="$(jq -r '(.limits.five_hour.used_percent // null) | if type=="number" then (round|tostring)+"%" else "?" end' "$uf")"
  week="$(jq -r '(.limits.weekly.used_percent // null) | if type=="number" then (round|tostring)+"%" else "?" end' "$uf")"
  printf '[5h %s  7d %s]' "$five" "$week"
}

# ---- Parallel account sessions ---------------------------------------------
# Run another Claude account in THIS terminal (its own quota), alongside your
# global account — e.g. to burn down two accounts at once near a weekly reset.
# A PID registry (the pid survives exec, so it becomes the launched claude's pid)
# lets the launcher FLAG an account that's already running — but never hides it,
# so an account can't mysteriously vanish from the list.
claude_session_pid_file() { printf '%s/sessions/%s.pid' "$RUNTIME_DIR" "$1"; }
claude_session_config_dir() { printf '%s/sessions/claude-%s' "$DATA_DIR" "$1"; }

register_claude_session() {
  local f; f="$(claude_session_pid_file "$1")"
  mkdir -p "$(dirname "$f")" && chmod 700 "$(dirname "$f")" 2>/dev/null || true
  printf '%s' "$$" >"$f"   # $$ survives exec → becomes the claude process's pid
}

claude_pid_is_claude() {
  local pid="$1" args
  args="$(ps -p "$pid" -o args= 2>/dev/null || true)"
  [[ "$args" == claude || "$args" == *"/claude" || "$args" == *"/claude"\ * ||
     "$args" == claude\ * || "$args" == *" claude "* ]]
}

# 0 if the account has a live parallel session; prunes a dead registration. The
# pid must still be a claude process — guards against pid reuse falsely flagging
# (or, for reclaim, killing) an unrelated process. Use args, not comm: macOS can
# truncate comm before the final "/claude".
claude_account_in_session() {
  local f pid; f="$(claude_session_pid_file "$1")"
  [[ -f "$f" ]] || return 1
  pid="$(cat "$f" 2>/dev/null)"
  if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null \
     && claude_pid_is_claude "$pid"; then
    return 0
  fi
  rm -f "$f" 2>/dev/null || true
  return 1
}

# OAuth accounts eligible to run in parallel: everything except the
# global-active account (running it in parallel would just split its one quota).
# An account already running is still listed — the launcher marks it "running".
claude_parallel_candidates() {
  local active name; active="$(active_claude_name)"
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    [[ "$(claude_account_kind "$name")" == "oauth" ]] || continue
    [[ "$name" == "$active" ]] && continue
    printf '%s\n' "$name"
  done < <(claude_names)
}

# A fresh CLAUDE_CONFIG_DIR is a blank first-run, so Claude Code shows its theme
# and login wizard. Mirror the user's global config into the session dir, but
# remove identity/project history and force onboarding complete. This is repaired
# on every launch so older broken session dirs recover automatically.
_seed_claude_session_config() {
  local dir="$1" name="${2:-}" kind="" cj="$HOME/.claude.json" out="$dir/.claude.json"
  mkdir -p "$dir"
  chmod 700 "$dir" 2>/dev/null || true
  [[ -n "$name" ]] && kind="$(claude_account_kind "$name")"

  if [[ -f "$out" ]]; then
    jq 'del(.projects) | .hasCompletedOnboarding = true' "$out" \
      >"$out.tmp" 2>/dev/null ||
      printf '{"hasCompletedOnboarding":true,"theme":"dark","numStartups":1}' >"$out.tmp"
    mv -f "$out.tmp" "$out"
  elif [[ -f "$cj" ]] && jq 'del(.oauthAccount, .projects) | .hasCompletedOnboarding = true' "$cj" >"$out.tmp" 2>/dev/null; then
    mv -f "$out.tmp" "$out"
  else
    rm -f "$out.tmp" 2>/dev/null || true
    printf '{"hasCompletedOnboarding":true,"theme":"dark","numStartups":1}' >"$out"
  fi

  if [[ "$kind" == "oauth" ]]; then
    local oauth_account
    oauth_account="$(jq -c '.oauthAccount // empty' "$(claude_account_file "$name")" 2>/dev/null)"
    if [[ -n "$oauth_account" ]]; then
      jq --argjson acct "$oauth_account" '.oauthAccount = $acct' "$out" >"$out.tmp" 2>/dev/null &&
        mv -f "$out.tmp" "$out"
    fi
  else
    jq 'del(.oauthAccount)' "$out" >"$out.tmp" 2>/dev/null && mv -f "$out.tmp" "$out"
  fi
  chmod 600 "$out" 2>/dev/null || true

  if [[ -f "$HOME/.claude/settings.json" && ! -f "$dir/settings.json" ]]; then
    cp "$HOME/.claude/settings.json" "$dir/settings.json" 2>/dev/null &&
      chmod 600 "$dir/settings.json" 2>/dev/null || true
  fi
}

claude_session_keychain_account() {
  if [[ -n "${USER:-}" ]]; then
    printf '%s' "$USER"
  else
    id -un 2>/dev/null || printf 'claude-code-user'
  fi
}

claude_session_keychain_service() {
  local dir="$1" normalized digest
  if command -v perl >/dev/null 2>&1; then
    normalized="$(printf '%s' "$dir" | perl -MUnicode::Normalize=NFC -CS -0pe '$_=NFC($_)' 2>/dev/null || printf '%s' "$dir")"
  else
    normalized="$dir"
  fi
  if command -v shasum >/dev/null 2>&1; then
    digest="$(printf '%s' "$normalized" | shasum -a 256 | awk '{print substr($1,1,8)}')"
  elif command -v sha256sum >/dev/null 2>&1; then
    digest="$(printf '%s' "$normalized" | sha256sum | awk '{print substr($1,1,8)}')"
  else
    digest=""
  fi
  [[ -n "$digest" ]] || return 1
  printf 'Claude Code-credentials-%s' "$digest"
}

delete_claude_session_keychain_entry() {
  local dir="$1" service account
  [[ "$(uname -s 2>/dev/null)" == "Darwin" ]] || return 0
  [[ -x /usr/bin/security ]] || return 0
  service="$(claude_session_keychain_service "$dir" 2>/dev/null || true)"
  [[ -n "$service" ]] || return 0
  account="$(claude_session_keychain_account)"
  /usr/bin/security delete-generic-password -a "$account" -s "$service" >/dev/null 2>&1 || true
}

read_claude_session_credentials() {
  local dir="$1" service account
  if [[ "$(uname -s 2>/dev/null)" == "Darwin" && -x /usr/bin/security ]]; then
    service="$(claude_session_keychain_service "$dir" 2>/dev/null || true)"
    if [[ -n "$service" ]]; then
      account="$(claude_session_keychain_account)"
      /usr/bin/security find-generic-password -a "$account" -s "$service" -w 2>/dev/null && return 0
    fi
  fi
  [[ -f "$dir/.credentials.json" ]] && cat "$dir/.credentials.json"
}

_claude_account_session_credentials() {
  local name="$1" file oauth org
  file="$(claude_account_file "$name")"
  case "$(claude_account_kind "$name")" in
    oauth)
      oauth="$(jq -c '.claudeAiOauth // empty' "$file")"
      [[ -n "$oauth" ]] || die "Account '$name' has no OAuth credentials."
      org="$(jq -r '.organizationUuid // empty' "$file")"
      jq -n --argjson oauth "$oauth" --arg org "$org" \
        '{claudeAiOauth:$oauth} + (if $org != "" then {organizationUuid:$org} else {} end)'
      ;;
    *)
      die "Claude account '$name' is not a full OAuth login. Re-add it with: Add account → Claude → Login with OAuth."
      ;;
  esac
}

_seed_claude_session_dir() {
  local name="$1" dir="$2" creds source_hash existing_hash marker
  mkdir -p "$dir"
  chmod 700 "$dir" 2>/dev/null || true
  marker="$dir/.aic-credential-source.sha256"
  creds="$(_claude_account_session_credentials "$name")"
  if command -v shasum >/dev/null 2>&1; then
    source_hash="$(printf '%s' "$creds" | shasum -a 256 | awk '{print $1}')"
  elif command -v sha256sum >/dev/null 2>&1; then
    source_hash="$(printf '%s' "$creds" | sha256sum | awk '{print $1}')"
  else
    source_hash=""
  fi
  existing_hash="$(cat "$marker" 2>/dev/null || true)"
  if [[ ! -f "$dir/.credentials.json" || -z "$source_hash" || "$existing_hash" != "$source_hash" ]]; then
    delete_claude_session_keychain_entry "$dir"
    printf '%s\n' "$creds" >"$dir/.credentials.json"
    chmod 600 "$dir/.credentials.json"
    if [[ -n "$source_hash" ]]; then
      printf '%s' "$source_hash" >"$marker"
      chmod 600 "$marker" 2>/dev/null || true
    fi
  fi
}

_run_claude_isolated() {
  local dir="$1"; shift
  env \
    -u CLAUDE_CODE_OAUTH_TOKEN \
    -u CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR \
    -u CLAUDE_CODE_API_KEY_FILE_DESCRIPTOR \
    -u ANTHROPIC_API_KEY \
    -u ANTHROPIC_AUTH_TOKEN \
    -u ANTHROPIC_BASE_URL \
    -u ANTHROPIC_MODEL \
    -u ANTHROPIC_DEFAULT_OPUS_MODEL \
    -u ANTHROPIC_DEFAULT_SONNET_MODEL \
    -u ANTHROPIC_DEFAULT_HAIKU_MODEL \
    -u ANTHROPIC_SMALL_FAST_MODEL \
    -u CLAUDE_CODE_SUBAGENT_MODEL \
    -u CLAUDE_CODE_USE_BEDROCK \
    -u CLAUDE_CODE_USE_VERTEX \
    -u ANTHROPIC_VERTEX_PROJECT_ID \
    -u CLOUD_ML_REGION \
    CLAUDE_CONFIG_DIR="$dir" \
    "$@"
}

_exec_claude_isolated() {
  local dir="$1"; shift
  exec env \
    -u CLAUDE_CODE_OAUTH_TOKEN \
    -u CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR \
    -u CLAUDE_CODE_API_KEY_FILE_DESCRIPTOR \
    -u ANTHROPIC_API_KEY \
    -u ANTHROPIC_AUTH_TOKEN \
    -u ANTHROPIC_BASE_URL \
    -u ANTHROPIC_MODEL \
    -u ANTHROPIC_DEFAULT_OPUS_MODEL \
    -u ANTHROPIC_DEFAULT_SONNET_MODEL \
    -u ANTHROPIC_DEFAULT_HAIKU_MODEL \
    -u ANTHROPIC_SMALL_FAST_MODEL \
    -u CLAUDE_CODE_SUBAGENT_MODEL \
    -u CLAUDE_CODE_USE_BEDROCK \
    -u CLAUDE_CODE_USE_VERTEX \
    -u ANTHROPIC_VERTEX_PROJECT_ID \
    -u CLOUD_ML_REGION \
    CLAUDE_CONFIG_DIR="$dir" \
    "$@"
}

validate_claude_session_profile() {
  local name="$1" dir="$2" status logged auth method
  status="$(_run_claude_isolated "$dir" claude auth status --json 2>/dev/null || true)"
  [[ -n "$status" ]] || { warn "Could not validate Claude session profile for '$name' before launch."; return 0; }
  jq -e . >/dev/null 2>&1 <<<"$status" || { warn "Claude auth status did not return JSON for '$name'; launching with seeded profile anyway."; return 0; }
  logged="$(jq -r '.loggedIn // .logged_in // false' <<<"$status")"
  method="$(jq -r '.authMethod // .auth_method // .authenticationMethod // ""' <<<"$status")"
  auth="$(jq -r '.authToken // .auth_token // ""' <<<"$status")"
  if [[ "$logged" != "true" ]]; then
    warn "Claude session profile for '$name' is not logged in yet. If Claude opens login/onboarding, close it and refresh this account."
    return 0
  fi
  if [[ "$method" == *api* || "$auth" == "ANTHROPIC_API_KEY" || "$auth" == "ANTHROPIC_AUTH_TOKEN" ]]; then
    warn "Claude session profile for '$name' appears to be API/custom-token billing, not subscription OAuth."
  fi
}

launch_claude_oauth_session() {
  local name="$1"; shift
  validate_name "$name"
  [[ -f "$(claude_account_file "$name")" ]] || die "Unknown Claude account: $name"
  require_command claude
  local dir
  dir="$(claude_session_config_dir "$name")"
  _seed_claude_session_config "$dir" "$name"
  _seed_claude_session_dir "$name" "$dir"
  validate_claude_session_profile "$name" "$dir"
  register_claude_session "$name"
  printf '%sLaunching Claude  ·  parallel (OAuth): %s  ·  this terminal, subscription quota%s\n' \
    "$CYAN" "$name" "$RESET"
  _exec_claude_isolated "$dir" claude "$@"
}

launch_claude_parallel() {
  local name="$1"; shift
  case "$(claude_account_kind "$name")" in
    oauth) launch_claude_oauth_session "$name" "$@" ;;
    *) die "Claude account '$name' is not a full OAuth login. Re-add it with: Add account → Claude → Login with OAuth." ;;
  esac
}

# Reclaim an account from a parallel session so its refresh chain lives in one
# place again: terminate a live session (with confirmation), sync the session's
# latest refreshed credential back into the account store, then drop the session
# copy. This is what removes the "re-import to switch later" caveat — the token
# the session rotated forward is written back before we hand the account to the
# global keychain. Returns 1 only if the user declines to terminate a live session.
# If an account is running in a parallel session, offer to terminate it (so
# global-switching to it takes over cleanly). OAuth session dirs may contain a
# rotated credential chain, so sync that back before dropping the isolated copy.
reclaim_claude_session() {
  local name="$1" mode="${2:-warn}"
  local pidf pid sessdir sesscreds
  pidf="$(claude_session_pid_file "$name")"
  sessdir="$(claude_session_config_dir "$name")"
  sesscreds="$sessdir/.credentials.json"

  if [[ -f "$pidf" ]]; then
    pid="$(cat "$pidf" 2>/dev/null)"
    # Only act if the pid is still a live claude process (never kill a reused pid).
    if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null \
       && claude_pid_is_claude "$pid"; then
      warn "Account '$name' is running in a parallel session (PID $pid)."
      if [[ "$mode" == "confirm" && -t 0 ]]; then
        local ans
        ans="$(choose_from "Terminate that session and take '$name' global?" \
          "No, cancel" "Yes, terminate it")" || return 1
        [[ "$ans" == Yes* ]] || return 1
      fi
      kill "$pid" 2>/dev/null || true
      local i
      for i in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$pid" 2>/dev/null || break; sleep 0.2; done
      kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null || true
      printf 'Terminated parallel session for %s.\n' "$name"
    fi
    rm -f "$pidf" 2>/dev/null || true
  fi

  if [[ -f "$sesscreds" || -d "$sessdir" ]]; then
    local oauth dest
    oauth="$(read_claude_session_credentials "$sessdir" 2>/dev/null | jq -c '.claudeAiOauth // empty' 2>/dev/null || true)"
    dest="$(claude_account_file "$name")"
    if [[ -n "$oauth" && -f "$dest" ]]; then
      if [[ -n "$(jq -r '.refreshToken // empty' <<<"$oauth" 2>/dev/null)" ]]; then
        jq --argjson o "$oauth" '.claudeAiOauth = $o' "$dest" >"$dest.tmp" 2>/dev/null &&
          chmod 600 "$dest.tmp" && mv -f "$dest.tmp" "$dest"
      fi
    fi
    rm -rf "$sessdir" 2>/dev/null || true
  fi
  return 0
}

# ---- Live login identity + token sync ---------------------------------------
# Claude Code rotates the refresh token on every refresh and stores the result
# only in the global keychain. The copy in our account store goes stale the
# moment that account is live, so before anything replaces the live login we
# copy its tokens back (sync_live_claude_to_store). Accounts are matched by
# account UUID (~/.claude.json oauthAccount), never by our own state file.
claude_global_config_file() { printf '%s/.claude.json' "$HOME"; }

live_claude_oauth_account() {
  jq -c '.oauthAccount // empty' "$(claude_global_config_file)" 2>/dev/null || true
}

live_claude_account_uuid() {
  jq -r '.oauthAccount.accountUuid // empty' "$(claude_global_config_file)" 2>/dev/null || true
}

claude_account_uuid() {
  jq -r '.oauthAccount.accountUuid // empty' "$(claude_account_file "$1")" 2>/dev/null || true
}

claude_account_email() {
  jq -r '.oauthAccount.emailAddress // empty' "$(claude_account_file "$1")" 2>/dev/null || true
}

claude_name_for_uuid() {
  local uuid="$1" name
  [[ -n "$uuid" ]] || return 1
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    if [[ "$(claude_account_uuid "$name")" == "$uuid" ]]; then
      printf '%s' "$name"
      return 0
    fi
  done < <(claude_names)
  return 1
}

# oauthAccount-shaped identity (same keys Claude Code keeps in ~/.claude.json)
# for an access token, from the OAuth profile endpoint.
fetch_claude_oauth_account() {
  local token body
  token="$(sanitize_claude_token "$1")"
  [[ -n "$token" ]] || return 1
  command -v curl >/dev/null 2>&1 || return 1
  body="$(
    curl -sS --max-time 15 \
      -H "Accept: application/json" \
      -H "Authorization: Bearer $token" \
      -H "anthropic-beta: oauth-2025-04-20" \
      -H "User-Agent: ai-account-center/$APP_VERSION" \
      "https://api.anthropic.com/api/oauth/profile" 2>/dev/null
  )" || return 1
  jq -ce 'select(.account.uuid) | {
    accountUuid: .account.uuid,
    emailAddress: .account.email,
    displayName: .account.display_name,
    fullName: .account.full_name,
    accountCreatedAt: .account.created_at,
    organizationUuid: .organization.uuid,
    organizationName: .organization.name,
    organizationType: .organization.organization_type,
    organizationRateLimitTier: .organization.rate_limit_tier,
    billingType: .organization.billing_type,
    hasExtraUsageEnabled: .organization.has_extra_usage_enabled,
    subscriptionCreatedAt: .organization.subscription_created_at
  } | with_entries(select(.value != null))' <<<"$body" 2>/dev/null
}

set_claude_account_identity() {
  local name="$1" acct="$2" file
  file="$(claude_account_file "$name")"
  [[ -f "$file" && -n "$acct" ]] || return 1
  jq --argjson a "$acct" '.oauthAccount = $a' "$file" >"$file.tmp" 2>/dev/null &&
    chmod 600 "$file.tmp" && mv -f "$file.tmp" "$file"
}

# Records saved before identities were tracked: look the identity up with the
# stored token (only when it is still valid; never refreshes).
backfill_claude_account_identity() {
  local name="$1" file token acct
  file="$(claude_account_file "$name")"
  [[ -f "$file" ]] || return 1
  [[ -z "$(claude_account_uuid "$name")" ]] || return 0
  is_claude_token_expired "$file" && return 1
  token="$(jq -r '.claudeAiOauth.accessToken // empty' "$file" 2>/dev/null)"
  acct="$(fetch_claude_oauth_account "$token")" || return 1
  set_claude_account_identity "$name" "$acct"
}

# Work out which stored account owns the live global login. Sets:
#   LIVE_OWNER     stored account name ("" = a login that isn't stored)
#   LIVE_VERIFIED  1 when proven from the tokens themselves, 0 when only
#                  ~/.claude.json says so (a running Claude Code can rewrite that
#                  file with its old identity, so it never justifies a write)
#   LIVE_ACCT      oauthAccount identity, when known
# With "refresh", an expired live token is refreshed (and written back to the
# keychain) so its identity can be checked. Returns 1 when there is no login.
LIVE_OWNER="" LIVE_VERIFIED=0 LIVE_ACCT=""
_resolve_live_claude() {
  local allow_refresh="${1:-}" blob live_rt name tmp
  LIVE_OWNER="" LIVE_VERIFIED=0 LIVE_ACCT=""
  blob="$(current_claude_oauth_blob)"
  live_rt="$(jq -r '.claudeAiOauth.refreshToken // empty' <<<"$blob" 2>/dev/null)"
  [[ -n "$live_rt" ]] || return 1

  # Same refresh-token chain as a stored account: definitely that account.
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    if [[ "$(jq -r '.claudeAiOauth.refreshToken // empty' "$(claude_account_file "$name")" 2>/dev/null)" == "$live_rt" ]]; then
      LIVE_OWNER="$name" LIVE_VERIFIED=1
      return 0
    fi
  done < <(claude_names)

  # Otherwise ask the API whose token it is.
  tmp="$RUNTIME_DIR/claude-live-$$.json"
  printf '%s' "$blob" >"$tmp" && chmod 600 "$tmp"
  if is_claude_token_expired "$tmp" && [[ "$allow_refresh" == "refresh" ]] &&
     _refresh_claude_oauth_file "$tmp"; then
    with_claude_credentials_lock _switch_claude_write "$tmp" keep-identity
  fi
  if ! is_claude_token_expired "$tmp" &&
     LIVE_ACCT="$(fetch_claude_oauth_account "$(jq -r '.claudeAiOauth.accessToken // empty' "$tmp")")"; then
    LIVE_VERIFIED=1
    LIVE_OWNER="$(claude_name_for_uuid "$(jq -r '.accountUuid // empty' <<<"$LIVE_ACCT")" || true)"
  else
    LIVE_ACCT="$(live_claude_oauth_account)"
    LIVE_OWNER="$(claude_name_for_uuid "$(live_claude_account_uuid)" || true)"
  fi
  rm -f "$tmp"
  return 0
}

# Copy an OAuth object into an account if it is at least as new as the stored
# one (expiresAt), so a dead pre-rotation token never replaces a live one.
_adopt_claude_oauth() {
  local name="$1" oauth="$2" file live_exp stored_exp
  file="$(claude_account_file "$name")"
  [[ -f "$file" ]] || return 1
  [[ -n "$(jq -r '.refreshToken // empty' <<<"$oauth" 2>/dev/null)" ]] || return 1
  [[ "$(jq -c '.claudeAiOauth' "$file")" == "$(jq -c . <<<"$oauth")" ]] && return 0
  live_exp="$(jq -r '.expiresAt // 0' <<<"$oauth" 2>/dev/null)"
  stored_exp="$(jq -r '.claudeAiOauth.expiresAt // 0' "$file" 2>/dev/null)"
  [[ "$live_exp" =~ ^[0-9]+$ ]] || live_exp=0
  [[ "$stored_exp" =~ ^[0-9]+$ ]] || stored_exp=0
  (( live_exp >= stored_exp )) || return 0
  jq --argjson o "$oauth" '.claudeAiOauth = $o' "$file" >"$file.tmp" 2>/dev/null &&
    chmod 600 "$file.tmp" && mv -f "$file.tmp" "$file"
}

claude_autosave_name() {
  local email="$1" base candidate i=2
  base="${email%%@*}"
  base="$(printf '%s' "$base" | tr -c 'A-Za-z0-9._-' '-' | sed 's/^[^A-Za-z0-9]*//' | cut -c1-48)"
  [[ -n "$base" ]] || base="claude-login"
  candidate="$base"
  while [[ -f "$(claude_account_file "$candidate")" ]]; do
    candidate="$base-$i"
    i=$((i + 1))
  done
  printf '%s' "$candidate"
}

# Write the live login's current tokens back into the account that owns it.
# A live login that isn't stored anywhere is saved under its email name so a
# switch or login can never overwrite the only copy. Prints the owner name.
# Returns 1 if there is no live login, 2 if its owner couldn't be verified.
sync_live_claude_to_store() {
  local oauth
  _resolve_live_claude "${1:-}" || return 1
  [[ "$LIVE_VERIFIED" == "1" ]] || return 2
  if [[ -z "$LIVE_OWNER" ]]; then
    LIVE_OWNER="$(claude_autosave_name "$(jq -r '.emailAddress // empty' <<<"$LIVE_ACCT")")"
    store_claude_oauth_blob "$LIVE_OWNER" "$(current_claude_oauth_blob)" "$LIVE_ACCT" || return 1
    printf '%sSaved the current Claude login as account: %s%s\n' "$CYAN" "$LIVE_OWNER" "$RESET" >&2
  else
    oauth="$(current_claude_oauth_blob | jq -c '.claudeAiOauth // empty' 2>/dev/null)"
    _adopt_claude_oauth "$LIVE_OWNER" "$oauth" || true
    [[ -n "$LIVE_ACCT" && -z "$(claude_account_uuid "$LIVE_OWNER")" ]] &&
      set_claude_account_identity "$LIVE_OWNER" "$LIVE_ACCT"
  fi
  printf '%s' "$LIVE_OWNER"
}

# Point state.json at whichever stored account is actually live (cheap: reads
# ~/.claude.json only). Like reconcile_active_codex.
reconcile_active_claude() {
  local matched active
  matched="$(claude_name_for_uuid "$(live_claude_account_uuid)" || true)"
  active="$(active_claude_name)"
  if [[ -n "$matched" ]]; then
    [[ "$matched" == "$active" ]] || set_active_claude_name "$matched"
  elif [[ -n "$active" && ! -f "$(claude_account_file "$active")" ]]; then
    clear_active_claude_name
  fi
}

# Make Claude Code's cached identity match the swapped-in credentials. Without
# a known identity, drop it so Claude Code refetches instead of mislabelling.
write_claude_global_identity() {
  local source="$1" cfg acct mode
  cfg="$(claude_global_config_file)"
  [[ -f "$cfg" ]] || return 0
  mode="$(stat -f %Lp "$cfg" 2>/dev/null || stat -c %a "$cfg" 2>/dev/null || printf '600')"
  acct="$(jq -c '.oauthAccount // empty' "$source" 2>/dev/null)"
  if [[ -n "$acct" ]]; then
    jq --argjson a "$acct" '.oauthAccount = ((.oauthAccount // {}) as $old |
      if ($old.accountUuid // "") == $a.accountUuid then $old + $a else $a end)' \
      "$cfg" >"$cfg.aic-tmp" 2>/dev/null || return 0
  else
    jq 'del(.oauthAccount)' "$cfg" >"$cfg.aic-tmp" 2>/dev/null || return 0
  fi
  chmod "$mode" "$cfg.aic-tmp" 2>/dev/null || true
  mv -f "$cfg.aic-tmp" "$cfg"
}

current_claude_oauth_blob() {
  # CLAUDE_CRED_FILE can be set in tests to redirect away from the real keychain
  if [[ -n "${CLAUDE_CRED_FILE:-}" ]]; then
    [[ -f "$CLAUDE_CRED_FILE" ]] && cat "$CLAUDE_CRED_FILE" || true
    return
  fi
  local blob=""
  if command -v security >/dev/null 2>&1; then
    blob="$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null || true)"
  fi
  if [[ -z "$blob" && -f "$HOME/.claude/.credentials.json" ]]; then
    blob="$(cat "$HOME/.claude/.credentials.json" 2>/dev/null || true)"
  fi
  printf '%s' "$blob"
}

write_claude_keychain() {
  local blob="$1"
  if [[ -n "${CLAUDE_CRED_FILE:-}" ]]; then
    printf '%s' "$blob" >"$CLAUDE_CRED_FILE"
    chmod 600 "$CLAUDE_CRED_FILE"
    return
  fi
  if command -v security >/dev/null 2>&1; then
    security add-generic-password -U \
      -s "Claude Code-credentials" -a "$(id -un)" \
      -w "$blob" 2>/dev/null || die "Could not write to keychain."
  else
    mkdir -p "$HOME/.claude"
    printf '%s' "$blob" >"$HOME/.claude/.credentials.json"
    chmod 600 "$HOME/.claude/.credentials.json"
  fi
}

import_current_claude() {
  local name="$1"
  validate_name "$name"
  local destination
  destination="$(claude_account_file "$name")"
  [[ ! -f "$destination" ]] || die "Claude account already exists: $name"
  save_current_claude_oauth "$name"
  set_active_claude_name "$name"
  printf 'Saved Claude account: %s\n' "$name"
}

# Persist a keychain-shaped blob ({"claudeAiOauth":{…}}) as a switchable account,
# with its oauthAccount identity when known. Returns non-zero (stores nothing)
# if the blob has no OAuth refresh token.
store_claude_oauth_blob() {
  local name="$1" blob="$2" acct="${3:-}"
  local oauth_obj refresh_token org_uuid destination
  oauth_obj="$(jq -c '.claudeAiOauth // empty' <<<"$blob" 2>/dev/null)"
  refresh_token="$(jq -r '.claudeAiOauth.refreshToken // empty' <<<"$blob" 2>/dev/null)"
  [[ -n "$oauth_obj" && -n "$refresh_token" ]] || return 1
  [[ -n "$acct" ]] || acct='null'
  org_uuid="$(jq -r '.organizationUuid // empty' <<<"$blob" 2>/dev/null)"
  [[ -n "$org_uuid" ]] || org_uuid="$(jq -r '.organizationUuid // empty' <<<"$acct" 2>/dev/null)"
  destination="$(claude_account_file "$name")"
  jq -n \
    --argjson oauth "$oauth_obj" \
    --argjson acct "$acct" \
    --arg org "$org_uuid" \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{"claudeAiOauth":$oauth,"organizationUuid":$org,"created_at":$ts}
      + (if $acct != null then {"oauthAccount":$acct} else {} end)' \
    >"$destination.tmp" || die "Could not store Claude account."
  chmod 600 "$destination.tmp"
  mv -f "$destination.tmp" "$destination"
}

# Save the live login as NAME. Refuses if that login is already stored under a
# different name (two records for one account would fork its refresh chain).
save_current_claude_oauth() {
  local name="$1"
  validate_name "$name"
  local blob acct uuid existing
  blob="$(current_claude_oauth_blob)"
  [[ -n "$blob" ]] || die "No Claude OAuth login found. Add it from the menu: Add Claude account → Login with OAuth."
  acct="$(live_claude_oauth_account)"
  [[ -n "$acct" ]] || acct="$(fetch_claude_oauth_account "$(jq -r '.claudeAiOauth.accessToken // empty' <<<"$blob" 2>/dev/null)" || true)"
  uuid="$(jq -r '.accountUuid // empty' <<<"${acct:-null}" 2>/dev/null)"
  existing="$(claude_name_for_uuid "$uuid" || true)"
  if [[ -n "$existing" && "$existing" != "$name" ]]; then
    _adopt_claude_oauth "$existing" "$(jq -c '.claudeAiOauth' <<<"$blob")" || true
    die "This Claude login ($(jq -r '.emailAddress // "?"' <<<"$acct")) is already saved as '$existing'."
  fi
  store_claude_oauth_blob "$name" "$blob" "$acct" ||
    die "Claude login found but missing OAuth tokens. Re-add from the menu: Add Claude account → Login with OAuth."
}

login_claude() {
  local name="$1"
  validate_name "$name"
  require_command claude
  [[ ! -f "$(claude_account_file "$name")" ]] || die "Claude account already exists: $name"
  # `claude auth login` replaces the live login — save its rotated tokens first.
  sync_live_claude_to_store >/dev/null || true
  printf 'Starting Claude subscription login for account: %s\n' "$name"
  claude auth login --claudeai || die "Claude login failed."
  import_current_claude "$name"
}

relogin_claude_oauth() {
  local name="$1"
  validate_name "$name"
  require_command claude
  local existing_file backup previous expected_uuid new_uuid
  existing_file="$(claude_account_file "$name")"
  [[ -f "$existing_file" ]] || die "Unknown Claude account: $name"
  previous="$(sync_live_claude_to_store || true)"
  expected_uuid="$(claude_account_uuid "$name")"
  backup="$existing_file.relogin-$$"
  cp "$existing_file" "$backup"
  chmod 600 "$backup"

  printf 'Starting Claude subscription re-login for account: %s\n' "$name"
  printf '%sSign in as %s in the browser.%s\n' "$DIM" "$(claude_account_email "$name" | grep . || printf 'this account')" "$RESET"
  if claude auth login --claudeai; then
    new_uuid="$(live_claude_account_uuid)"
    if [[ -n "$expected_uuid" && -n "$new_uuid" && "$new_uuid" != "$expected_uuid" ]]; then
      mv "$backup" "$existing_file"
      warn "That login is $(jq -r '.oauthAccount.emailAddress // "a different account"' "$(claude_global_config_file)" 2>/dev/null), not '$name'. Original credentials restored."
      if [[ -n "$previous" && "$previous" != "$name" && -f "$(claude_account_file "$previous")" ]]; then
        with_claude_credentials_lock _switch_claude_write "$(claude_account_file "$previous")"
        set_active_claude_name "$previous"
      fi
      return 1
    fi
    rm -f "$existing_file"
    if ( save_current_claude_oauth "$name" ); then
      rm -f "$backup"
      set_active_claude_name "$name"
      printf 'Re-login complete for account: %s\n' "$name"
      # Re-login is a repair, not a switch: put the previous global login back.
      if [[ -n "$previous" && "$previous" != "$name" && -f "$(claude_account_file "$previous")" ]]; then
        switch_claude_impl "$previous" && printf 'Global Claude account restored to: %s\n' "$previous"
      fi
      return 0
    fi
  fi
  mv "$backup" "$existing_file"
  warn "Re-login failed. Original credentials restored for: $name"
  return 1
}

is_claude_token_expired() {
  local file="$1" expires_at now_ms
  expires_at="$(jq -r '.claudeAiOauth.expiresAt // empty' "$file" 2>/dev/null)"
  [[ -n "$expires_at" && "$expires_at" =~ ^[0-9]+$ ]] || return 1
  now_ms=$(( $(date +%s) * 1000 ))
  (( now_ms >= expires_at ))
}

refresh_claude_oauth_account() {
  local name="$1" source="$2"
  CLAUDE_REFRESH_ERROR="" CLAUDE_REFRESH_HTTP=""
  [[ "$(claude_account_kind "$name")" == "oauth" ]] || return 1
  _refresh_claude_oauth_file "$source"
}

# Refresh the OAuth tokens in a keychain-shaped JSON file in place. On failure,
# CLAUDE_REFRESH_ERROR holds a short reason and CLAUDE_REFRESH_HTTP the status
# (400/401 = the refresh token is dead; anything else may be transient).
CLAUDE_REFRESH_ERROR="" CLAUDE_REFRESH_HTTP=""
_refresh_claude_oauth_file() {
  local source="$1" refresh_token scopes payload response body http_code org
  CLAUDE_REFRESH_ERROR="" CLAUDE_REFRESH_HTTP=""
  local client_id="${CLAUDE_CODE_OAUTH_CLIENT_ID:-9d1c250a-e61b-44d9-88ed-5944d1962f5e}"
  require_command curl
  [[ -f "$source" ]] || return 1

  refresh_token="$(jq -r '.claudeAiOauth.refreshToken // empty' "$source" 2>/dev/null)"
  [[ -n "$refresh_token" ]] || return 1
  scopes="$(jq -r '(.claudeAiOauth.scopes // ["user:profile","user:inference","user:sessions:claude_code","user:mcp_servers","user:file_upload"]) | join(" ")' "$source" 2>/dev/null)"
  [[ -n "$scopes" ]] || scopes="user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload"
  payload="$(jq -nc \
    --arg rt "$refresh_token" \
    --arg client "$client_id" \
    --arg scope "$scopes" \
    '{grant_type:"refresh_token", refresh_token:$rt, client_id:$client, scope:$scope}')"

  response="$(
    curl -sS -w '\n%{http_code}' --max-time 30 \
      -H "Accept: application/json" \
      -H "Content-Type: application/json" \
      -H "anthropic-beta: oauth-2025-04-20" \
      -H "User-Agent: ai-account-center/$APP_VERSION" \
      -d "$payload" \
      "https://platform.claude.com/v1/oauth/token" 2>/dev/null
  )"
  body="${response%$'\n'*}"
  http_code="${response##*$'\n'}"
  CLAUDE_REFRESH_HTTP="$http_code"
  if [[ "$http_code" != "200" ]]; then
    CLAUDE_REFRESH_ERROR="HTTP ${http_code:-?}: $(jq -r '.error_description // .error.message // .error // "no response"' <<<"$body" 2>/dev/null | head -1)"
    [[ "$http_code" == "429" ]] && CLAUDE_REFRESH_ERROR="$CLAUDE_REFRESH_ERROR (rate limited — try again later)"
    return 1
  fi
  jq -e '.access_token and .expires_in' >/dev/null 2>&1 <<<"$body" || {
    CLAUDE_REFRESH_ERROR="unexpected token response"
    return 1
  }

  org="$(jq -r '.account.organization.uuid // empty' <<<"$body" 2>/dev/null || true)"
  [[ -n "$org" ]] || org="$(jq -r '.organizationUuid // empty' "$source" 2>/dev/null || true)"
  jq --argjson tok "$body" --arg org "$org" '
    .claudeAiOauth.accessToken = $tok.access_token |
    .claudeAiOauth.refreshToken = ($tok.refresh_token // .claudeAiOauth.refreshToken) |
    .claudeAiOauth.expiresAt = ((now * 1000) + (($tok.expires_in // 0) * 1000) | floor) |
    .claudeAiOauth.refreshTokenExpiresAt =
      (if ($tok.refresh_token_expires_in // null) then
        ((now * 1000) + ($tok.refresh_token_expires_in * 1000) | floor)
      else .claudeAiOauth.refreshTokenExpiresAt end) |
    .claudeAiOauth.scopes =
      (if ($tok.scope // "") != "" then ($tok.scope | split(" ") | map(select(length > 0))) else .claudeAiOauth.scopes end) |
    .organizationUuid = $org
  ' "$source" >"$source.tmp" 2>/dev/null &&
    chmod 600 "$source.tmp" && mv -f "$source.tmp" "$source"
}

running_claude_processes() {
  local claude_bin="" pid cmd
  claude_bin="$(command -v claude 2>/dev/null || true)"
  [[ -n "$claude_bin" ]] || claude_bin="claude"
  while IFS= read -r pid; do
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    [[ "$pid" == "$$" || "$pid" == "${PPID:-}" ]] && continue
    cmd="$(ps -p "$pid" -o args= 2>/dev/null || true)"
    [[ "$cmd" == *"aic"* ]] && continue
    [[ -n "$cmd" ]] && printf '  PID %s: %s\n' "$pid" "$cmd"
  done < <(pgrep -f "$claude_bin" 2>/dev/null || true)
}

# Running Claude Code sessions keep the old account's token in memory. In the
# interactive switch, offer to restart idle terminal sessions afterwards and
# resume each chat in its own tab (see resume.sh). Sets CLAUDE_RESTART_AFTER_SWITCH.
CLAUDE_RESTART_AFTER_SWITCH=0
warn_running_claude_for_switch() {
  local mode="${1:-warn}" procs rows answer
  CLAUDE_RESTART_AFTER_SWITCH=0
  rows="$(claude_terminal_sessions)"
  if [[ -n "$rows" ]]; then
    printf '%sOpen Claude Code sessions (they keep the old account until restarted):%s\n' "$YELLOW" "$RESET" >&2
    describe_claude_terminal_sessions "$rows"
    [[ "$mode" == "confirm" ]] || return 0
    answer="$(choose_from "Switch account and…" \
      "Restart idle sessions and resume their chats (busy ones are left alone)::restart" \
      "Just switch (restart sessions myself later)::switch" \
      "Cancel::cancel")" || return 1
    case "${answer##*::}" in
      restart) CLAUDE_RESTART_AFTER_SWITCH=1 ;;
      switch) ;;
      *) return 1 ;;
    esac
    return 0
  fi
  procs="$(running_claude_processes || true)"
  [[ -n "$procs" ]] || return 0
  warn "Claude is currently running. The new account takes effect on next launch."
  printf '%s\n' "$procs" >&2
  [[ "$mode" == "confirm" ]] || return 0
  answer="$(choose_from "Continue with switch?" "No, cancel" "Yes, switch anyway")" || return 1
  [[ "$answer" == *"Yes"* ]] || return 1
}

# ---- Cooperate with Claude Code's own credential lock ----------------------
# Claude Code guards its OAuth token refresh with a proper-lockfile directory
# lock at "<config-home>.lock" (e.g. ~/.claude.lock): mkdir is the mutex, and a
# lock whose mtime is older than 10s is stale and may be taken over. If we swap
# the keychain while a running claude is mid-refresh, its save would overwrite
# our swap with the refreshed OLD-account token and strand a pre-rotation refresh
# token (the very collision behind the "already used" errors). Holding this lock
# during our write makes claude's own double-checked re-read see the swapped
# (non-expired) credential and abort its refresh. The write is sub-second, so no
# mtime toucher is needed. (Ported from claude-swap's claude_locks.py.)
claude_credentials_lock_dir() {
  printf '%s.lock' "${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
}

with_claude_credentials_lock() {
  local lock now mtime age rc=0 deadline
  lock="$(claude_credentials_lock_dir)"
  mkdir -p "$(dirname "$lock")" 2>/dev/null || true
  deadline=$(( $(date +%s) + 9 ))
  while ! mkdir "$lock" 2>/dev/null; do
    now="$(date +%s)"
    mtime="$(stat -f %m "$lock" 2>/dev/null || stat -c %Y "$lock" 2>/dev/null || printf '%s' "$now")"
    age=$(( now - mtime ))
    if (( age > 10 )); then
      rmdir "$lock" 2>/dev/null || true
      continue
    fi
    if (( now >= deadline )); then
      warn "Claude credential lock is busy; switching without it."
      "$@"
      return $?
    fi
    sleep 0.3
  done
  "$@" || rc=$?
  rmdir "$lock" 2>/dev/null || true
  return "$rc"
}

# Re-read the live keychain, merge our account's OAuth over it (preserving
# mcpOAuth etc.), and write it back — the read-merge-write is one critical
# section, run under with_claude_credentials_lock.
# With "keep-identity" only the tokens change (same account, refreshed).
_switch_claude_write() {
  local source="$1" mode="${2:-}" live_blob new_blob oauth
  live_blob="$(current_claude_oauth_blob)"
  jq -e 'type == "object"' >/dev/null 2>&1 <<<"$live_blob" || live_blob='{}'
  oauth="$(jq -c '.claudeAiOauth // empty' "$source" 2>/dev/null)"
  [[ -n "$(jq -r '.refreshToken // empty' <<<"$oauth" 2>/dev/null)" ]] || {
    warn "Refusing to write Claude credentials without a refresh token."
    return 1
  }
  new_blob="$(jq -cn \
    --argjson l "$live_blob" \
    --argjson oauth "$oauth" \
    --arg org "$(jq -r '.organizationUuid // empty' "$source")" \
    '$l | .claudeAiOauth = $oauth | if $org != "" then .organizationUuid = $org else del(.organizationUuid) end')"
  [[ -n "$new_blob" ]] || { warn "Could not build Claude credentials."; return 1; }
  write_claude_keychain "$new_blob"
  [[ "$mode" == "keep-identity" ]] || write_claude_global_identity "$source"
}

backup_live_claude_login() {
  local blob stamp dest
  blob="$(current_claude_oauth_blob)"
  [[ -n "$blob" ]] || return 0
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  dest="$BACKUP_DIR/claude-live-$stamp.json"
  ( umask 077; jq -n --argjson creds "$blob" --argjson acct "$(live_claude_oauth_account | grep . || printf 'null')" \
      '{credentials:$creds, oauthAccount:$acct}' >"$dest" 2>/dev/null ) || rm -f "$dest"
  # Keep the 10 most recent.
  ls -1t "$BACKUP_DIR"/claude-live-*.json 2>/dev/null | tail -n +11 | while IFS= read -r old; do rm -f "$old"; done
}

# Before switching, make sure the target's login still works, so a dead login
# never replaces a working one. Refreshes it when expired (safe: it isn't live).
preflight_claude_target() {
  local name="$1" source="$2" mode="${3:-warn}" token code answer
  if ! is_claude_token_expired "$source"; then
    token="$(sanitize_claude_token "$(jq -r '.claudeAiOauth.accessToken // empty' "$source")")"
    code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 15 \
      -H "Authorization: Bearer $token" -H "anthropic-beta: oauth-2025-04-20" \
      -H "User-Agent: ai-account-center/$APP_VERSION" \
      "https://api.anthropic.com/api/oauth/profile" 2>/dev/null || true)"
    [[ "$code" == "401" || "$code" == "403" ]] || return 0
  fi

  printf '%sRefreshing the login for %s before switching...%s\n' "$YELLOW" "$name" "$RESET"
  refresh_claude_oauth_account "$name" "$source" && return 0

  case "$CLAUDE_REFRESH_HTTP" in
    400|401|403)
      warn "The saved login for '$name' is no longer valid (${CLAUDE_REFRESH_ERROR}). Your current login was left untouched."
      printf 'Fix it with: Manage accounts → %s → Re-login OAuth\n' "$name" >&2
      return 1
      ;;
  esac
  warn "Could not verify the login for '$name' (${CLAUDE_REFRESH_ERROR:-no response})."
  [[ "$mode" == "confirm" && -t 0 ]] || return 1
  answer="$(choose_from "Switch to '$name' anyway?" "No, cancel" "Yes, switch anyway")" || return 1
  [[ "$answer" == Yes* ]]
}

switch_claude_impl() {
  local name="$1" process_mode="${2:-warn}"
  validate_name "$name"
  local source
  source="$(claude_account_file "$name")"
  [[ -f "$source" ]] || die "Unknown Claude account: $name"
  local refresh_token
  refresh_token="$(jq -r '.claudeAiOauth.refreshToken // empty' "$source" 2>/dev/null)"
  [[ -n "$refresh_token" ]] ||
    die "Account '$name' has no OAuth credentials. Re-import from the menu: Add Claude account → Import current login."

  # If this account is checked out to a parallel session, terminate it and sync
  # its rotated-forward token back into the store first, so the global switch
  # lands the live credential (no stale-token / re-import problem).
  reclaim_claude_session "$name" "$process_mode" || return 1

  # Save the outgoing login's rotated tokens (or the whole login, if it was never
  # stored) before it is overwritten — otherwise switching back later fails.
  local live_owner sync_rc=0
  live_owner="$(sync_live_claude_to_store refresh)" || sync_rc=$?
  if [[ "$sync_rc" == "0" && "$live_owner" == "$name" ]]; then
    set_active_claude_name "$name"
    printf 'Claude account %s is already the active login.\n' "$name"
    return 0
  fi
  [[ "$sync_rc" == "2" ]] &&
    warn "Could not confirm which account the current Claude login belongs to; it will be backed up in $BACKUP_DIR."

  preflight_claude_target "$name" "$source" "$process_mode" || return 1
  warn_running_claude_for_switch "$process_mode" || return 1
  backfill_claude_account_identity "$name" || true
  backup_live_claude_login

  # Land the swap under Claude Code's credential lock so a concurrent refresh in
  # a running claude can't clobber it (and strand a pre-rotation refresh token).
  with_claude_credentials_lock _switch_claude_write "$source" || return 1
  set_active_claude_name "$name"
  printf 'Active Claude account: %s%s\n' "$name" \
    "$(claude_account_email "$name" | sed 's/^/ (/; s/$/)/')"
  if [[ "$CLAUDE_RESTART_AFTER_SWITCH" == "1" ]]; then
    CLAUDE_RESTART_AFTER_SWITCH=0
    restart_claude_sessions_after_switch
  fi
}

interactive_claude_use() {
  # Global switch targets are OAuth logins only; they carry the refresh token
  # the keychain requires.
  local options=() best_name="" name score rest item label
  # Make sure the current login is saved (and listed) before choosing.
  sync_live_claude_to_store >/dev/null || true
  while IFS=$'\t' read -r name score rest; do
    [[ -n "$name" ]] || continue
    [[ "$(claude_account_kind "$name")" == "oauth" ]] || continue
    [[ -z "$best_name" ]] && best_name="$name"
    label="$(claude_choice_label "$name" "$best_name" "$score")"
    # Flag an account currently checked out to a parallel session — switching to
    # it will offer to terminate that session and take it global.
    claude_account_in_session "$name" && label="$label  ⏵ in parallel session"
    jq -e '.status == "error" and ((.error // "") | test("Re-login"))' \
      "$(usage_file claude "$name")" >/dev/null 2>&1 && label="$label  ⚠ needs Re-login OAuth"
    options+=("$label::$name")
  done < <(claude_recommendations)

  if [[ "${#options[@]}" -eq 0 ]]; then
    warn "No switchable Claude accounts yet. Add one from: Add account → Claude → Login with OAuth."
    return 1
  fi

  item="$(choose_from "Switch to Claude account (global — all clients)" "${options[@]}")" || return 1
  name="${item##*::}"
  switch_claude_impl "$name" confirm
}

remove_claude() {
  local name="$1"
  validate_name "$name"
  local file
  file="$(claude_account_file "$name")"
  [[ -f "$file" ]] || die "Unknown Claude account: $name"
  rm -f "$file" "$(usage_file claude "$name")" "$(claude_session_pid_file "$name")"
  printf 'Removed Claude account: %s\n' "$name"
}


rename_claude_account() {
  local old_name="$1" new_name="$2"
  validate_name "$old_name"
  validate_name "$new_name"
  local old_file new_file
  old_file="$(claude_account_file "$old_name")"
  new_file="$(claude_account_file "$new_name")"
  [[ -f "$old_file" ]] || die "Unknown Claude account: $old_name"
  [[ ! -f "$new_file" ]] || die "Account name already exists: $new_name"
  mv "$old_file" "$new_file"
  local old_usage new_usage
  old_usage="$(usage_file claude "$old_name")"
  new_usage="$(usage_file claude "$new_name")"
  [[ -f "$old_usage" ]] && mv "$old_usage" "$new_usage" || true
  printf 'Renamed Claude account: %s → %s\n' "$old_name" "$new_name"
}
