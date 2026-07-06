# shellcheck shell=bash
# aic module: claude
# Claude accounts: keychain, OAuth import, subscription login, switch
# Sourced by lib/aic/_load.sh; not executed directly.

claude_token_box_plain() {
  local text="$1" style="${2:-}" pad
  pad=$((60 - ${#text}))
  (( pad < 0 )) && pad=0
  printf '%s|%s%s%s%*s%s|%s\n' \
    "$CYAN" "$RESET" "$style" "$text" "$pad" "" "$CYAN" "$RESET" >&2
}

claude_token_box_highlight() {
  local left="$1" highlight="$2" right="$3" pad
  pad=$((60 - ${#left} - ${#highlight} - ${#right}))
  (( pad < 0 )) && pad=0
  printf '%s|%s%s%s%s%s%s%*s%s|%s\n' \
    "$CYAN" "$RESET" "$left" "$YELLOW" "$highlight" "$RESET" "$right" \
    "$pad" "" "$CYAN" "$RESET" >&2
}

print_claude_token_instructions() {
  printf '%s+------------------------------------------------------------+%s\n' "$CYAN" "$RESET" >&2
  claude_token_box_plain "  CLAUDE SETUP TOKEN" "$BOLD"
  claude_token_box_plain ""
  claude_token_box_highlight "  1  Run " "claude setup-token" " in another terminal."
  claude_token_box_plain "  2  Approve the browser login."
  claude_token_box_highlight "  3  Paste the " "sk-ant-oat01-..." " token here."
  claude_token_box_plain ""
  claude_token_box_plain "  Claude shows this token once. Input is visible so you" "$DIM"
  claude_token_box_plain "  can confirm it pasted cleanly (no stray characters)." "$DIM"
  printf '%s+------------------------------------------------------------+%s\n' "$CYAN" "$RESET" >&2
  printf '\n' >&2
}

# Single source of truth for the "capture credential on the other Mac" command,
# used by both the on-screen instructions and the [c] copy-to-clipboard hotkey.
claude_cred_capture_cmd() {
  printf '%s' 'security find-generic-password -s "Claude Code-credentials" -w | base64 | tr -d "\n" | pbcopy'
}

# A framed, colored walkthrough for importing a Claude credential from another
# machine: a source→destination diagram, numbered steps, and the command shown
# on its own highlighted line so it is easy to select or copy with [c].
print_claude_credential_import_box() {
  local h v tl tr bl br conn rule box gap
  if supports_utf8; then
    h='─'; v='│'; tl='┌'; tr='┐'; bl='└'; br='┘'; conn=' ──> '
  else
    h='-'; v='|'; tl='+'; tr='+'; bl='+'; br='+'; conn=' --> '
  fi
  rule="$(printf "${h}%.0s" $(seq 1 64))"
  box="$(printf "${h}%.0s" $(seq 1 12))"   # 12 inner cols → 14-wide box incl borders
  gap='     '                              # 5 spaces == visual width of conn

  local C="$CYAN" R="$RESET" B="$BOLD" D="$DIM" Y="$YELLOW" G="$GREEN" W="$WHITE"

  # Build each row as one string so widths line up exactly across rows.
  local cell_top="${C}${tl}${box}${tr}${R}"
  local cell_bot="${C}${bl}${box}${br}${R}"
  local arrow="${B}${Y}${conn}${R}"
  local cellL="${C}${v}${R} OTHER Mac  ${C}${v}${R}"
  local cellM="${C}${v}${R} clipboard  ${C}${v}${R}"
  local cellR="${C}${v}${R}  THIS Mac  ${C}${v}${R}"

  printf '\n%s%s%s\n' "$C" "$rule" "$R" >&2
  printf '  %s%sIMPORT CLAUDE CREDENTIAL%s  %s· bring a switchable account onto this Mac%s\n' \
    "$B" "$W" "$R" "$D" "$R" >&2
  printf '%s%s%s\n\n' "$C" "$rule" "$R" >&2

  printf '%s\n' "  ${cell_top}${gap}${cell_top}${gap}${cell_top}" >&2
  printf '%s\n' "  ${cellL}${arrow}${cellM}${arrow}${cellR}" >&2
  printf '%s\n' "  ${cell_bot}${gap}${cell_bot}${gap}${cell_bot}" >&2
  printf '%s\n\n' "  ${D} run command  ${R}${gap}${D} or via chat  ${R}${gap}${D} paste result ${R}" >&2

  printf '  %s1%s  Press %s[c]%s to copy the command  %s(or select the line below)%s\n' \
    "$B" "$R" "$B$G" "$R" "$D" "$R" >&2
  printf '  %s2%s  Run it on the OTHER Mac, or paste it to that person in chat.\n' "$B" "$R" >&2
  printf '  %s3%s  That copies their Claude credential to the clipboard.\n' "$B" "$R" >&2
  printf '  %s4%s  Paste the copied credential back here.\n\n' "$B" "$R" >&2

  printf '  %scommand to run on the other machine:%s\n' "$D" "$R" >&2
  printf '    %s%s%s%s\n' "$B" "$Y" "$(claude_cred_capture_cmd)" "$R" >&2
  printf '%s%s%s\n' "$C" "$rule" "$R" >&2
}

# Strip whitespace and control bytes (e.g. a stray ESC captured during a paste)
# from a Claude token. A setup token / OAuth access token is a single run of
# printable, whitespace-free characters, so this only ever removes corruption.
# One such byte silently breaks the Authorization header and makes every usage
# refresh fail with a blank error, so sanitize on both input and read.
sanitize_claude_token() {
  printf '%s' "$1" | tr -d '[:space:][:cntrl:]'
}

# Two kinds of Claude account share CLAUDE_ACCOUNTS_DIR:
#   "oauth" — a full browser login with a refreshToken. Only these can be
#             switched globally (written to the keychain so every client picks
#             them up), because the keychain rejects refresh-token-less creds.
#   "token" — a setup-token (`claude setup-token`). A session credential like an
#             API key: full Claude, but only per-launch via CLAUDE_CODE_OAUTH_TOKEN.
claude_account_kind() {
  local file
  file="$(claude_account_file "$1")"
  [[ -f "$file" ]] || { printf ''; return; }
  if [[ -n "$(jq -r '.claudeAiOauth.refreshToken // empty' "$file" 2>/dev/null)" ]]; then
    printf 'oauth'
  else
    printf 'token'
  fi
}

claude_oauth_names() {
  local n
  while IFS= read -r n; do
    [[ -n "$n" ]] || continue
    [[ "$(claude_account_kind "$n")" == "oauth" ]] && printf '%s\n' "$n"
  done < <(claude_names)
}

claude_token_names() {
  local n
  while IFS= read -r n; do
    [[ -n "$n" ]] || continue
    [[ "$(claude_account_kind "$n")" == "token" ]] && printf '%s\n' "$n"
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

# Launch a full Claude session authenticated by a setup-token. Session-scoped:
# only this process uses the account; the keychain / other clients are untouched.
launch_claude_with_token() {
  local name="$1"; shift
  validate_name "$name"
  local file token
  file="$(claude_account_file "$name")"
  [[ -f "$file" ]] || die "Unknown Claude account: $name"
  token="$(sanitize_claude_token "$(jq -r '.token // .claudeAiOauth.accessToken // empty' "$file")")"
  [[ -n "$token" ]] || die "Account '$name' has no usable token."
  require_command claude
  printf '%sLaunching Claude  ·  setup-token: %s  ·  this session only (keychain untouched)%s\n' \
    "$CYAN" "$name" "$RESET"
  exec env CLAUDE_CODE_OAUTH_TOKEN="$token" claude "$@"
}

add_claude_token() {
  local name="$1"
  local token="${2:-}"
  validate_name "$name"

  # Never silently clobber an existing account. Overwriting an OAuth login with
  # a bare setup-token would strip its refresh token and downgrade it from a
  # global-switchable account to a session-only credential — refuse outright.
  if [[ -f "$(claude_account_file "$name")" ]]; then
    if [[ "$(claude_account_kind "$name")" == "oauth" ]]; then
      die "Account '$name' is a full OAuth login (globally switchable). Adding a setup-token would remove that. Choose another name, or remove '$name' first."
    fi
    warn "Setup-token account '$name' already exists; it will be replaced."
    if [[ -t 0 ]]; then
      local ans
      ans="$(choose_from "Overwrite existing setup-token '$name'?" "No, cancel" "Yes, overwrite")" || return 1
      [[ "$ans" == Yes* ]] || return 1
    fi
  fi

  if [[ -z "$token" ]]; then
    if [[ ! -t 0 ]]; then
      IFS= read -r token
    else
      print_claude_token_instructions
      printf '%sPaste setup token:%s ' "$BOLD" "$RESET" >&2
      # Visible input (not -s): the paste is echoed so you can eyeball it before
      # it is stored. sanitize_claude_token still strips anything unexpected.
      IFS= read -r token
    fi
  fi
  token="$(sanitize_claude_token "$token")"
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

# Persist a keychain-shaped blob ({"claudeAiOauth":{…}}) as a switchable account.
# Returns non-zero (stores nothing) if the blob has no OAuth refresh token.
store_claude_oauth_blob() {
  local name="$1" blob="$2"
  local oauth_obj refresh_token org_uuid destination
  oauth_obj="$(jq -c '.claudeAiOauth // empty' <<<"$blob" 2>/dev/null)"
  refresh_token="$(jq -r '.claudeAiOauth.refreshToken // empty' <<<"$blob" 2>/dev/null)"
  [[ -n "$oauth_obj" && -n "$refresh_token" ]] || return 1
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

save_current_claude_oauth() {
  local name="$1"
  validate_name "$name"
  local blob
  blob="$(current_claude_oauth_blob)"
  [[ -n "$blob" ]] || die "No Claude OAuth login found. Add it from the menu: Add Claude account → Login with OAuth."
  store_claude_oauth_blob "$name" "$blob" ||
    die "Claude login found but missing OAuth tokens. Re-add from the menu: Add Claude account → Login with OAuth."
}

# Import a full Claude OAuth login from a base64 blob captured on another machine:
#   security find-generic-password -s "Claude Code-credentials" -w | base64 | tr -d '\n'
# Unlike a setup-token this carries the refresh token, so the imported account is
# globally switchable. (A bare setup-token belongs under Open with model.)
import_claude_oauth_blob() {
  local name="$1"
  local input="${2:-}"
  validate_name "$name"

  if [[ -z "$input" ]]; then
    if [[ ! -t 0 ]]; then
      IFS= read -r input
    else
      print_claude_credential_import_box
      while true; do
        printf '\n%sPaste credential%s  %s(or press %sc%s%s then Enter to copy the command)%s: ' \
          "$BOLD" "$RESET" "$DIM" "$BOLD$GREEN" "$RESET" "$DIM" "$RESET" >&2
        IFS= read -r input
        case "$input" in
          c|C)
            if printf '%s' "$(claude_cred_capture_cmd)" | transfer_clipboard_copy; then
              printf '  %s✓ Command copied — run it on the other Mac, or paste it to that person in chat.%s\n' "$GREEN" "$RESET" >&2
            else
              printf '  %s! No clipboard tool found (pbcopy/xclip). Select the command above to copy it.%s\n' "$YELLOW" "$RESET" >&2
            fi
            ;;
          *) break ;;
        esac
      done
    fi
  fi
  input="$(printf '%s' "$input" | tr -d '[:space:]')"
  [[ -n "$input" ]] || die "No credential provided."

  # Accept raw JSON (starts with '{') or base64 of it.
  local blob=""
  if [[ "$input" == \{* ]]; then
    blob="$input"
  else
    blob="$(printf '%s' "$input" | base64 -d 2>/dev/null)"
    [[ -n "$blob" ]] || blob="$(printf '%s' "$input" | base64 -D 2>/dev/null)"
  fi
  jq -e . >/dev/null 2>&1 <<<"$blob" ||
    die "Could not decode the credential (expected base64 of the keychain JSON)."

  if [[ -f "$(claude_account_file "$name")" ]]; then
    local existing_kind
    existing_kind="$(claude_account_kind "$name")"
    if [[ -t 0 ]]; then
      local ans
      ans="$(choose_from "Claude account '$name' exists ($existing_kind). Overwrite with imported OAuth login?" "No, cancel" "Yes, overwrite")" || return 1
      [[ "$ans" == Yes* ]] || return 1
    else
      warn "Overwriting existing Claude account '$name' ($existing_kind) with imported OAuth login."
    fi
  fi

  store_claude_oauth_blob "$name" "$blob" ||
    die "Not a full Claude OAuth credential (no refresh token). For an inference-only setup-token use: Open with model → Claude → Add Claude setup-token."

  printf 'Imported Claude OAuth account: %s  (globally switchable)\n' "$name"
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
  # Global switch targets are OAuth logins only — they alone carry the refresh
  # token the keychain requires. Setup-token accounts are launched per-session
  # from Open with model → Claude, so they are excluded here (ranked by score,
  # so the first OAuth entry is the best switchable account).
  local options=() best_name="" name score rest item
  while IFS=$'\t' read -r name score rest; do
    [[ -n "$name" ]] || continue
    [[ "$(claude_account_kind "$name")" == "oauth" ]] || continue
    [[ -z "$best_name" ]] && best_name="$name"
    options+=("$(claude_choice_label "$name" "$best_name" "$score")::$name")
  done < <(claude_recommendations)

  if [[ "${#options[@]}" -eq 0 ]]; then
    warn "No switchable Claude accounts yet. Add one from: Add account → Claude → Login with OAuth."
    local toks
    toks="$(claude_token_names | paste -sd', ' -)"
    [[ -n "$toks" ]] && printf '  Setup-token accounts (%s) run per-session via Open with model → Claude.\n' "$toks" >&2
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
