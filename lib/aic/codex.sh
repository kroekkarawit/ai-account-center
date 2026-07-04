# shellcheck shell=bash
# aic module: codex
# Codex accounts: JWT/auth parsing, switch, remove, rename, browser login
# Sourced by lib/aic/_load.sh; not executed directly.

codex_name_for_identity_key() {
  local identity_key="$1" file
  [[ -n "$identity_key" ]] || return 1
  for file in "$CODEX_ACCOUNTS_DIR"/*.json; do
    [[ -e "$file" ]] || continue
    if [[ "$(codex_identity_key "$file")" == "$identity_key" ]]; then
      basename "$file" .json
      return 0
    fi
  done
  return 1
}

reconcile_active_codex() {
  local auth="$CODEX_HOME_DIR/auth.json"
  [[ -f "$auth" ]] || return 0
  validate_codex_auth "$auth" || return 0

  local live_identity active active_file matched
  live_identity="$(codex_identity_key "$auth")"
  active="$(active_codex_name)"
  if [[ -n "$active" ]]; then
    active_file="$(codex_account_file "$active")"
    if [[ -f "$active_file" && "$(codex_identity_key "$active_file")" == "$live_identity" ]]; then
      return 0
    fi
  fi

  matched="$(codex_name_for_identity_key "$live_identity" || true)"
  if [[ -n "$matched" ]]; then
    set_active_codex_name "$matched"
  else
    clear_active_codex_name
  fi
}

backup_live_auth() {
  local auth="$CODEX_HOME_DIR/auth.json"
  [[ -f "$auth" ]] || return 0
  local stamp
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  cp "$auth" "$BACKUP_DIR/codex-auth-$stamp.json"
  chmod 600 "$BACKUP_DIR/codex-auth-$stamp.json"
}

validate_codex_auth() {
  local file="$1"
  jq -e '
    .auth_mode and
    (.tokens | type == "object") and
    (.tokens.account_id | type == "string" and length > 0) and
    (.tokens.access_token | type == "string" and length > 0)
  ' "$file" >/dev/null 2>&1
}

codex_account_id() {
  jq -r '.tokens.account_id // empty' "$1"
}

jwt_payload_json() {
  local file="$1" token_name="$2"
  local payload decoded
  payload="$(
    jq -r --arg token_name "$token_name" '.tokens[$token_name] // empty' "$file" |
      awk -F. 'NF >= 2 { print $2 }' |
      tr '_-' '/+' |
      awk '{
        rem = length($0) % 4
        if (rem == 2) print $0 "=="
        else if (rem == 3) print $0 "="
        else print $0
      }'
  )"
  [[ -n "$payload" ]] || return 0

  decoded="$(printf '%s' "$payload" | base64 --decode 2>/dev/null)" ||
    decoded="$(printf '%s' "$payload" | base64 -D 2>/dev/null)" ||
    return 0
  printf '%s\n' "$decoded"
}

jwt_claim() {
  local file="$1" token_name="$2" filter="$3"
  local decoded
  decoded="$(jwt_payload_json "$file" "$token_name")"
  [[ -n "$decoded" ]] || return 0
  jq -r "$filter" <<<"$decoded" 2>/dev/null
}

codex_email() {
  local file="$1" email
  email="$(jwt_claim "$file" id_token '.email // .["https://api.openai.com/profile"].email // empty')"
  if [[ -z "$email" || "$email" == "null" ]]; then
    email="$(jwt_claim "$file" access_token '.email // .["https://api.openai.com/profile"].email // empty')"
  fi
  printf '%s' "$email"
}

codex_user_identity() {
  local file="$1" identity
  identity="$(jwt_claim "$file" access_token '.["https://api.openai.com/auth"].chatgpt_account_user_id // .["https://api.openai.com/auth"].chatgpt_user_id // .["https://api.openai.com/auth"].user_id // .sub // empty')"
  if [[ -z "$identity" || "$identity" == "null" ]]; then
    identity="$(jwt_claim "$file" id_token '.["https://api.openai.com/auth"].chatgpt_user_id // .["https://api.openai.com/auth"].user_id // .sub // .email // empty')"
  fi
  printf '%s' "$identity"
}

codex_identity_key() {
  local file="$1" account_id user_identity email
  account_id="$(codex_account_id "$file")"
  user_identity="$(codex_user_identity "$file")"
  if [[ -z "$user_identity" || "$user_identity" == "null" ]]; then
    email="$(codex_email "$file")"
    user_identity="$email"
  fi
  if [[ -n "$user_identity" && "$user_identity" != "null" ]]; then
    printf '%s|%s' "$account_id" "$user_identity"
  else
    printf '%s' "$account_id"
  fi
}

access_token_exp() {
  local file="$1" payload decoded
  payload="$(
    jq -r '.tokens.access_token // empty' "$file" |
      awk -F. 'NF >= 2 { print $2 }' |
      tr '_-' '/+' |
      awk '{
        rem = length($0) % 4
        if (rem == 2) print $0 "=="
        else if (rem == 3) print $0 "="
        else print $0
      }'
  )"
  [[ -n "$payload" ]] || return 0
  decoded="$(printf '%s' "$payload" | base64 --decode 2>/dev/null)" ||
    decoded="$(printf '%s' "$payload" | base64 -D 2>/dev/null)" ||
    return 0
  jq -r '.exp // empty' <<<"$decoded" 2>/dev/null
}

is_access_token_expired() {
  local file="$1" exp now
  exp="$(access_token_exp "$file")"
  [[ -n "$exp" && "$exp" =~ ^[0-9]+$ ]] || return 1
  now="$(date +%s)"
  ((now >= exp))
}

codex_duplicate_name_for_file() {
  local source="$1" destination="$2" source_identity file
  source_identity="$(codex_identity_key "$source")"
  [[ -n "$source_identity" ]] || return 0
  for file in "$CODEX_ACCOUNTS_DIR"/*.json; do
    [[ -e "$file" ]] || continue
    if [[ "$(codex_identity_key "$file")" == "$source_identity" && "$file" != "$destination" ]]; then
      basename "$file" .json
      return 0
    fi
  done
  return 0
}

save_live_codex_as() {
  local name="$1"
  validate_name "$name"
  local auth="$CODEX_HOME_DIR/auth.json"
  [[ -f "$auth" ]] || die "No Codex auth file found at $auth. Run codex login first."
  validate_codex_auth "$auth" || die "The current Codex auth file has an unsupported format."

  local destination
  destination="$(codex_account_file "$name")"
  local duplicate
  duplicate="$(codex_duplicate_name_for_file "$auth" "$destination")"
  [[ -z "$duplicate" ]] || die "This Codex login is already stored as '$duplicate'."

  cp "$auth" "$destination.tmp"
  chmod 600 "$destination.tmp"
  mv -f "$destination.tmp" "$destination"
  set_active_codex_name "$name"

  local email
  email="$(codex_email "$destination")"
  printf 'Saved Codex account: %s%s\n' "$name" "${email:+ ($email)}"
}

save_codex_auth_file_as() {
  local name="$1" source="$2"
  validate_name "$name"
  [[ -f "$source" ]] || die "Auth JSON file not found: $source"
  validate_codex_auth "$source" || die "The provided Codex auth JSON has an unsupported format."

  local destination duplicate
  destination="$(codex_account_file "$name")"
  duplicate="$(codex_duplicate_name_for_file "$source" "$destination")"
  [[ -z "$duplicate" ]] || die "This Codex login is already stored as '$duplicate'."

  cp "$source" "$destination.tmp"
  chmod 600 "$destination.tmp"
  mv -f "$destination.tmp" "$destination"

  local email
  email="$(codex_email "$destination")"
  printf 'Imported Codex account: %s%s\n' "$name" "${email:+ ($email)}"
}

login_codex_browser() {
  local name="$1"
  shift || true
  validate_name "$name"
  require_command codex
  require_command mktemp

  local login_home auth_file status
  login_home="$(mktemp -d "$RUNTIME_DIR/codex-login-$name-XXXXXX")" ||
    die "Could not create temporary Codex login directory."
  chmod 700 "$login_home"
  auth_file="$login_home/auth.json"

  printf 'Starting Codex browser login for account: %s\n' "$name"
  printf 'This uses a temporary CODEX_HOME, so your active ~/.codex/auth.json is not changed.\n'
  printf 'If browser login will not open on a remote/headless machine, import auth.json instead (menu: Add Codex account → Import).\n'
  CODEX_HOME="$login_home" codex login "$@"
  status=$?
  if [[ "$status" -ne 0 ]]; then
    rm -rf "$login_home"
    return "$status"
  fi

  [[ -f "$auth_file" ]] || {
    rm -rf "$login_home"
    die "Codex login finished but no auth.json was created in the temporary login directory."
  }
  save_codex_auth_file_as "$name" "$auth_file"
  rm -rf "$login_home"
  printf 'Switch to "%s" anytime from the menu: Switch account → Codex.\n' "$name"
}

sync_active_codex() {
  local active auth destination
  active="$(active_codex_name)"
  auth="$CODEX_HOME_DIR/auth.json"
  [[ -n "$active" && -f "$auth" ]] || return 0
  validate_codex_auth "$auth" || return 0

  destination="$(codex_account_file "$active")"
  [[ -f "$destination" ]] || return 0

  if [[ "$(codex_identity_key "$auth")" == "$(codex_identity_key "$destination")" ]]; then
    cp "$auth" "$destination.tmp"
    chmod 600 "$destination.tmp"
    mv -f "$destination.tmp" "$destination"
  else
    local matched
    matched="$(codex_name_for_identity_key "$(codex_identity_key "$auth")" || true)"
    if [[ -n "$matched" ]]; then
      set_active_codex_name "$matched"
    else
      clear_active_codex_name
    fi
  fi
}

switch_codex_impl() {
  local name="$1" process_mode="${2:-warn}"
  validate_name "$name"
  local source auth
  source="$(codex_account_file "$name")"
  auth="$CODEX_HOME_DIR/auth.json"
  [[ -f "$source" ]] || die "Unknown Codex account: $name"
  validate_codex_auth "$source" || die "Stored auth for '$name' is invalid."
  warn_running_codex_for_switch "$process_mode" || return 1

  if is_access_token_expired "$source"; then
    printf '%sAccess token for %s is expired — refreshing before switch...%s\n' "$YELLOW" "$name" "$RESET"
    if refresh_codex_account "$name" 2>/dev/null; then
      source="$(codex_account_file "$name")"
    else
      warn "Token refresh failed. Switching with expired token — Codex may require re-login."
    fi
  fi

  sync_active_codex
  backup_live_auth
  mkdir -p "$CODEX_HOME_DIR" || die "Unable to create Codex home directory: $CODEX_HOME_DIR"
  cp "$source" "$auth.tmp" || die "Unable to write Codex auth temp file: $auth.tmp"
  chmod 600 "$auth.tmp" || die "Unable to chmod Codex auth temp file: $auth.tmp"
  mv -f "$auth.tmp" "$auth" || die "Unable to replace Codex auth file: $auth"
  set_active_codex_name "$name"
  force_close_codex_processes_after_switch

  printf 'Active Codex account: %s\n' "$name"
}

remove_codex_impl() {
  local name="$1"
  validate_name "$name"
  local file active
  file="$(codex_account_file "$name")"
  [[ -f "$file" ]] || die "Unknown Codex account: $name"
  active="$(active_codex_name)"
  if [[ "$active" == "$name" ]]; then
    clear_active_codex_name
  fi
  rm -f "$file" "$(usage_file codex "$name")"
  printf 'Removed Codex account: %s\n' "$name"
  if [[ "$active" == "$name" ]]; then
    printf 'The live %s/auth.json was left unchanged.\n' "$CODEX_HOME_DIR"
  fi
}

rename_codex_account() {
  local old_name="$1" new_name="$2"
  validate_name "$old_name"
  validate_name "$new_name"
  local old_file new_file
  old_file="$(codex_account_file "$old_name")"
  new_file="$(codex_account_file "$new_name")"
  [[ -f "$old_file" ]] || die "Unknown Codex account: $old_name"
  [[ ! -f "$new_file" ]] || die "Account name already exists: $new_name"
  mv "$old_file" "$new_file"
  local old_usage new_usage
  old_usage="$(usage_file codex "$old_name")"
  new_usage="$(usage_file codex "$new_name")"
  [[ -f "$old_usage" ]] && mv "$old_usage" "$new_usage" || true
  local active
  active="$(active_codex_name)"
  [[ "$active" == "$old_name" ]] && set_active_codex_name "$new_name"
  printf 'Renamed Codex account: %s → %s\n' "$old_name" "$new_name"
}

relogin_codex_browser() {
  local name="$1"
  shift || true
  validate_name "$name"
  local existing_file backup
  existing_file="$(codex_account_file "$name")"
  [[ -f "$existing_file" ]] || die "Unknown Codex account: $name"
  backup="$existing_file.relogin-$$"
  cp "$existing_file" "$backup"
  chmod 600 "$backup"
  rm -f "$existing_file"
  if login_codex_browser "$name" "$@"; then
    rm -f "$backup"
    printf 'Re-login complete for account: %s\n' "$name"
  else
    mv "$backup" "$existing_file"
    warn "Re-login failed. Original credentials restored for: $name"
    return 1
  fi
}

interactive_use() {
  local options=() best best_name line name score reset5_hours resetw_hours stale item
  print_codex_recommendation_bar
  best="$(best_codex_recommendation)"
  best_name="${best%%$'\t'*}"
  while IFS=$'\t' read -r name score reset5_hours resetw_hours stale; do
    [[ -n "$name" ]] || continue
    options+=("$(codex_choice_label "$name" "$best_name" "$score")::$name")
  done < <(codex_recommendations)
  [[ "${#options[@]}" -gt 0 ]] || {
    warn "No Codex accounts have been added."
    return 1
  }
  item="$(choose_from "Select Codex account" "${options[@]}")" || return 1
  name="${item##*::}"
  with_lock switch_codex_impl "$name" confirm
}

