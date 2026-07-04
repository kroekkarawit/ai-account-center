# shellcheck shell=bash
# aic module: claude
# Claude accounts: keychain, OAuth import, subscription login, switch
# Sourced by lib/aic/_load.sh; not executed directly.

print_claude_token_instructions() {
  cat >&2 <<'EOF'
Claude token setup:
  1. Open another terminal.
  2. Run: claude setup-token
  3. Authenticate in the browser when Claude opens it.
  4. Return to the terminal and copy the token that starts with sk-ant-oat01-.
  5. Paste that token here. Input is hidden.

EOF
}

add_claude_token() {
  local name="$1"
  local token="${2:-}"
  validate_name "$name"

  if [[ -z "$token" ]]; then
    if [[ ! -t 0 ]]; then
      IFS= read -r token
    else
      print_claude_token_instructions
      printf 'Claude subscription token: ' >&2
      IFS= read -r -s token
      printf '\n' >&2
    fi
  fi
  [[ -n "$token" ]] || die "Claude token cannot be empty."

  local destination
  destination="$(claude_account_file "$name")"
  jq -n --arg token "$token" --arg created "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{token:$token, created_at:$created}' >"$destination.tmp" ||
    die "Could not store Claude token."
  chmod 600 "$destination.tmp"
  mv -f "$destination.tmp" "$destination"
  printf 'Saved Claude account: %s\n' "$name"
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
  printf 'Saved Claude account: %s\n' "$name"
}

save_current_claude_oauth() {
  local name="$1"
  validate_name "$name"
  local blob oauth_obj refresh_token org_uuid destination
  blob="$(current_claude_oauth_blob)"
  [[ -n "$blob" ]] || die "No Claude OAuth login found. Add it from the menu: Add Claude account → Login with OAuth."
  oauth_obj="$(jq -c '.claudeAiOauth // empty' <<<"$blob" 2>/dev/null)"
  refresh_token="$(jq -r '.claudeAiOauth.refreshToken // empty' <<<"$blob" 2>/dev/null)"
  [[ -n "$oauth_obj" && -n "$refresh_token" ]] ||
    die "Claude login found but missing OAuth tokens. Re-add from the menu: Add Claude account → Login with OAuth."
  org_uuid="$(jq -r '.organizationUuid // empty' <<<"$blob" 2>/dev/null)"
  destination="$(claude_account_file "$name")"
  jq -n \
    --argjson oauth "$oauth_obj" \
    --arg org "$org_uuid" \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{"claudeAiOauth":$oauth,"organizationUuid":$org,"created_at":$ts}' \
    >"$destination.tmp" || die "Could not store Claude account."
  chmod 600 "$destination.tmp"
  mv -f "$destination.tmp" "$destination"
}

login_claude() {
  local name="$1"
  validate_name "$name"
  require_command claude
  printf 'Starting Claude subscription login for account: %s\n' "$name"
  claude auth login --claudeai || die "Claude login failed."
  import_current_claude "$name"
}

relogin_claude_oauth() {
  local name="$1"
  validate_name "$name"
  require_command claude
  local existing_file backup
  existing_file="$(claude_account_file "$name")"
  [[ -f "$existing_file" ]] || die "Unknown Claude account: $name"
  backup="$existing_file.relogin-$$"
  cp "$existing_file" "$backup"
  chmod 600 "$backup"

  printf 'Starting Claude subscription re-login for account: %s\n' "$name"
  if claude auth login --claudeai && ( save_current_claude_oauth "$name" ); then
    rm -f "$backup"
    printf 'Re-login complete for account: %s\n' "$name"
  else
    mv "$backup" "$existing_file"
    warn "Re-login failed. Original credentials restored for: $name"
    return 1
  fi
}

is_claude_token_expired() {
  local file="$1" expires_at now_ms
  expires_at="$(jq -r '.claudeAiOauth.expiresAt // empty' "$file" 2>/dev/null)"
  [[ -n "$expires_at" && "$expires_at" =~ ^[0-9]+$ ]] || return 1
  now_ms=$(( $(date +%s) * 1000 ))
  (( now_ms >= expires_at ))
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

warn_running_claude_for_switch() {
  local mode="${1:-warn}" procs
  procs="$(running_claude_processes || true)"
  [[ -n "$procs" ]] || return 0
  warn "Claude is currently running. The new account takes effect on next launch."
  printf '%s\n' "$procs" >&2
  [[ "$mode" == "confirm" ]] || return 0
  local answer
  answer="$(choose_from "Continue with switch?" "No, cancel" "Yes, switch anyway")" || return 1
  [[ "$answer" == *"Yes"* ]] || return 1
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

  warn_running_claude_for_switch "$process_mode" || return 1

  if is_claude_token_expired "$source"; then
    printf '%sAccess token for %s is expired — refreshing before switch...%s\n' \
      "$YELLOW" "$name" "$RESET"
    local live_blob merged
    live_blob="$(current_claude_oauth_blob || printf '{}')"
    merged="$(jq -n \
      --argjson l "$live_blob" \
      --argjson oauth "$(jq '.claudeAiOauth' "$source")" \
      --arg org "$(jq -r '.organizationUuid // empty' "$source")" \
      '$l | .claudeAiOauth = $oauth | .organizationUuid = $org')"
    write_claude_keychain "$merged"
    if claude auth status --json >/dev/null 2>&1; then
      local refreshed_blob
      refreshed_blob="$(current_claude_oauth_blob)"
      jq -n \
        --argjson oauth "$(jq '.claudeAiOauth' <<<"$refreshed_blob")" \
        --arg org "$(jq -r '.organizationUuid // empty' <<<"$refreshed_blob")" \
        --arg ts "$(jq -r '.created_at' "$source")" \
        '{"claudeAiOauth":$oauth,"organizationUuid":$org,"created_at":$ts}' \
        >"$source.tmp"
      chmod 600 "$source.tmp"
      mv -f "$source.tmp" "$source"
      printf 'Token refreshed.\n'
    else
      warn "Token refresh failed. Switching with stored token — Claude may require re-login."
    fi
  fi

  local new_blob live_blob
  live_blob="$(current_claude_oauth_blob || printf '{}')"
  new_blob="$(jq -n \
    --argjson l "$live_blob" \
    --argjson oauth "$(jq '.claudeAiOauth' "$source")" \
    --arg org "$(jq -r '.organizationUuid // empty' "$source")" \
    '$l | .claudeAiOauth = $oauth | .organizationUuid = $org')"
  write_claude_keychain "$new_blob"
  set_active_claude_name "$name"
  printf 'Active Claude account: %s\n' "$name"
}

interactive_claude_use() {
  local options=() name item has_oauth suffix
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    has_oauth="$(jq -r '.claudeAiOauth.refreshToken // empty' "$(claude_account_file "$name")" 2>/dev/null)"
    suffix=""
    [[ -z "$has_oauth" ]] && suffix="  (token-only, re-import to enable switch)"
    options+=("$name$suffix::$name")
  done < <(claude_names)
  [[ "${#options[@]}" -gt 0 ]] || { warn "No Claude accounts have been added."; return 1; }
  item="$(choose_from "Select Claude account" "${options[@]}")" || return 1
  name="${item##*::}"
  has_oauth="$(jq -r '.claudeAiOauth.refreshToken // empty' "$(claude_account_file "$name")" 2>/dev/null)"
  [[ -n "$has_oauth" ]] || {
    warn "Account '$name' has no OAuth credentials. Re-import from the menu: Add Claude account → Import current login."
    return 1
  }
  switch_claude_impl "$name" confirm
}

remove_claude() {
  local name="$1"
  validate_name "$name"
  local file
  file="$(claude_account_file "$name")"
  [[ -f "$file" ]] || die "Unknown Claude account: $name"
  rm -f "$file" "$(usage_file claude "$name")"
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
