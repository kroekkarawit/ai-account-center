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
# `tee /dev/tty` echoes the credential to the screen (and the trailing `echo`
# adds a newline) so the person running it sees output and knows it worked,
# rather than a silent clipboard copy that looks like nothing happened.
claude_cred_capture_cmd() {
  printf '%s' 'security find-generic-password -s "Claude Code-credentials" -w | base64 | tr -d "\n" | tee /dev/tty | pbcopy; echo'
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
  printf '  %s3%s  It prints the credential (so they see it worked) and copies it.\n' "$B" "$R" >&2
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
#   "token" — a setup-token (`claude setup-token`). It is subscription/OAuth
#             credential material, but lacks a refresh token, so it runs only in
#             a per-launch credential profile and never switches globally.
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
# only this process uses the account; the global keychain / other clients are
# untouched.
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
  [[ "$args" == *"/claude"* || "$args" == claude\ * || "$args" == *" claude "* ]]
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

# Accounts eligible to run in parallel: everything except the global-active
# account (running it in parallel would just split its one quota). An account
# already running is still listed — the launcher marks it "running" — so it never
# disappears.
claude_parallel_candidates() {
  local active name; active="$(active_claude_name)"
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
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
  local name="$1" file token oauth org
  file="$(claude_account_file "$name")"
  case "$(claude_account_kind "$name")" in
    token)
      token="$(sanitize_claude_token "$(jq -r '.token // .claudeAiOauth.accessToken // empty' "$file")")"
      [[ -n "$token" ]] || die "Account '$name' has no usable setup-token."
      jq -n --arg token "$token" \
        '{claudeAiOauth:{accessToken:$token,refreshToken:"",expiresAt:0,scopes:["user:inference"]}}'
      ;;
    oauth)
      oauth="$(jq -c '.claudeAiOauth // empty' "$file")"
      [[ -n "$oauth" ]] || die "Account '$name' has no OAuth credentials."
      org="$(jq -r '.organizationUuid // empty' "$file")"
      jq -n --argjson oauth "$oauth" --arg org "$org" \
        '{claudeAiOauth:$oauth} + (if $org != "" then {organizationUuid:$org} else {} end)'
      ;;
    *)
      die "Unknown Claude account: $name"
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

launch_claude_with_token() {
  local name="$1"; shift
  validate_name "$name"
  local file dir
  file="$(claude_account_file "$name")"
  [[ -f "$file" ]] || die "Unknown Claude account: $name"
  require_command claude
  dir="$(claude_session_config_dir "$name")"
  _seed_claude_session_config "$dir" "$name"
  _seed_claude_session_dir "$name" "$dir"
  validate_claude_session_profile "$name" "$dir"
  register_claude_session "$name"
  printf '%sLaunching Claude  ·  parallel (setup-token): %s  ·  this terminal, subscription quota%s\n' \
    "$CYAN" "$name" "$RESET"
  _exec_claude_isolated "$dir" claude "$@"
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
    token) launch_claude_with_token "$name" "$@" ;;
    oauth) launch_claude_oauth_session "$name" "$@" ;;
    *) die "Unknown Claude account: $name" ;;
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
# Setup-token sessions also have .credentials.json, but no refresh token; syncing
# them back is mostly a shape repair and keeps the stored `.token` authoritative.
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
      if [[ -z "$(jq -r '.refreshToken // empty' <<<"$oauth" 2>/dev/null)" ]]; then
        jq --argjson o "$oauth" '.token = ($o.accessToken // .token) | .claudeAiOauth = $o' "$dest" >"$dest.tmp" 2>/dev/null &&
          chmod 600 "$dest.tmp" && mv -f "$dest.tmp" "$dest"
      else
        jq --argjson o "$oauth" '.claudeAiOauth = $o' "$dest" >"$dest.tmp" 2>/dev/null &&
          chmod 600 "$dest.tmp" && mv -f "$dest.tmp" "$dest"
      fi
    fi
    rm -rf "$sessdir" 2>/dev/null || true
  fi
  return 0
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
_switch_claude_write() {
  local source="$1" live_blob new_blob
  live_blob="$(current_claude_oauth_blob || printf '{}')"
  new_blob="$(jq -n \
    --argjson l "$live_blob" \
    --argjson oauth "$(jq '.claudeAiOauth' "$source")" \
    --arg org "$(jq -r '.organizationUuid // empty' "$source")" \
    '$l | .claudeAiOauth = $oauth | .organizationUuid = $org')"
  write_claude_keychain "$new_blob"
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

  # Land the swap under Claude Code's credential lock so a concurrent refresh in
  # a running claude can't clobber it (and strand a pre-rotation refresh token).
  with_claude_credentials_lock _switch_claude_write "$source"
  set_active_claude_name "$name"
  printf 'Active Claude account: %s\n' "$name"
}

interactive_claude_use() {
  # Global switch targets are OAuth logins only — they alone carry the refresh
  # token the keychain requires. Setup-token accounts are launched per-session
  # from Open with model → Claude, so they are excluded here (ranked by score,
  # so the first OAuth entry is the best switchable account).
  local options=() best_name="" name score rest item label
  while IFS=$'\t' read -r name score rest; do
    [[ -n "$name" ]] || continue
    [[ "$(claude_account_kind "$name")" == "oauth" ]] || continue
    [[ -z "$best_name" ]] && best_name="$name"
    label="$(claude_choice_label "$name" "$best_name" "$score")"
    # Flag an account currently checked out to a parallel session — switching to
    # it will offer to terminate that session and take it global.
    claude_account_in_session "$name" && label="$label  ⏵ in parallel session"
    options+=("$label::$name")
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
