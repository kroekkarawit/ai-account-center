# shellcheck shell=bash
# aic module: lifecycle
# Self update/uninstall and diagnostics
# Sourced by lib/aic/_load.sh; not executed directly.

update_self() {
  local ref="${1:-main}" script_path app_dir installer curl_args
  script_path="$(resolve_self)"
  app_dir="$(cd "$(dirname "$script_path")/.." && pwd)"
  installer="$app_dir/install.sh"

  if [[ -f "$installer" ]]; then
    AIC_INSTALL_REF="$ref" bash "$installer" --remote --ref "$ref"
    return
  fi

  require_command curl
  curl_args=(-fsSL)
  if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    curl_args+=(-H "Authorization: Bearer $GITHUB_TOKEN")
  fi
  printf 'Installer not found next to this aic install. Downloading installer from %s (%s)...\n' "$APP_REPO_URL" "$ref"
  curl "${curl_args[@]}" "$APP_REPO_URL/raw/$ref/install.sh" | AIC_INSTALL_REF="$ref" bash
}

uninstall_self() {
  local purge_data=0 assume_yes=0 arg script_path app_bin app_dir
  for arg in "$@"; do
    case "$arg" in
      --purge-data) purge_data=1 ;;
      --yes|-y) assume_yes=1 ;;
      --help|-h)
        cat <<HELP
Usage:
  aic uninstall [--yes] [--purge-data]

Default removes the installed app, command link, and scheduler only.
Account data is kept at: $DATA_DIR

Options:
  --yes         Do not ask for confirmation.
  --purge-data  Also delete $DATA_DIR, including stored account tokens.
HELP
        return 0
        ;;
      *) die "Unknown uninstall option: $arg" ;;
    esac
  done

  if [[ "$assume_yes" -ne 1 ]]; then
    printf 'Uninstall AI Account Center?\n'
    printf 'Remove app files: %s\n' "$APP_DIR"
    printf 'Remove command: %s/aic\n' "$APP_BIN_DIR"
    if [[ "$purge_data" -eq 1 ]]; then
      printf '%sWARNING:%s This will also delete stored account data: %s\n' "$RED" "$RESET" "$DATA_DIR"
    else
      printf 'Keep account data: %s\n' "$DATA_DIR"
    fi
    printf 'Continue? [y/N] '
    local answer
    IFS= read -r answer
    case "$answer" in
      y|Y|yes|YES) ;;
      *) printf 'Uninstall cancelled.\n'; return 1 ;;
    esac
  fi

  uninstall_scheduler 2>/dev/null || true

  script_path="$(resolve_self)"
  app_bin="$APP_BIN_DIR/aic"
  app_dir="$APP_DIR"

  if [[ -e "$app_bin" || -L "$app_bin" ]]; then
    rm -f "$app_bin"
    printf 'Removed command: %s\n' "$app_bin"
  fi

  if [[ -d "$app_dir" ]]; then
    rm -rf "$app_dir"
    printf 'Removed app files: %s\n' "$app_dir"
  elif [[ "$script_path" == "$app_bin" && -f "$script_path" ]]; then
    rm -f "$script_path"
    printf 'Removed legacy command file: %s\n' "$script_path"
  fi

  if [[ "$purge_data" -eq 1 ]]; then
    rm -rf "$DATA_DIR"
    printf 'Removed account data: %s\n' "$DATA_DIR"
  else
    printf 'Kept account data: %s\n' "$DATA_DIR"
  fi

  printf 'Uninstalled AI Account Center.\n'
}

config_set() {
  local key="$1" value="$2"
  [[ -n "$key" && -n "$value" ]] || die "config_set requires a key and a value."
  local tmp
  tmp="$(jq --arg k "$key" --arg v "$value" 'getpath($k|split(".")) as $cur |
    if $cur == null or ($cur|type) == "string" then setpath($k|split("."); $v)
    elif ($cur|type) == "number" then setpath($k|split("."); ($v|tonumber))
    elif ($cur|type) == "boolean" then setpath($k|split("."); ($v == "true"))
    else setpath($k|split("."); $v) end' "$CONFIG_FILE")" || die "Could not update config."
  chmod 600 <(printf '%s' "$tmp") 2>/dev/null || true
  printf '%s' "$tmp" >"$CONFIG_FILE.tmp"
  chmod 600 "$CONFIG_FILE.tmp"
  mv -f "$CONFIG_FILE.tmp" "$CONFIG_FILE"
  printf 'Set %s = %s\n' "$key" "$value"
}

cmd_debug() {
  local target_account="${1:-}"

  printf '%s=== Environment ===%s\n' "$BOLD" "$RESET"
  printf '  OS:       %s\n' "$(uname -srm)"
  printf '  Shell:    %s\n' "${SHELL:-unknown}"
  printf '  PATH entries:\n'
  printf '%s' "$PATH" | tr ':' '\n' | sed 's/^/    /'
  printf '\n\n'

  printf '%s=== Commands ===%s\n' "$BOLD" "$RESET"
  local codex_path node_path jq_path
  codex_path="$(command -v codex 2>/dev/null || true)"
  node_path="$(command -v node 2>/dev/null || true)"
  jq_path="$(command -v jq 2>/dev/null || true)"

  if [[ -n "$codex_path" ]]; then
    local codex_ver
    codex_ver="$(codex --version 2>/dev/null || printf 'unknown')"
    printf '  %scodex%s  %s  (v%s)\n' "$GREEN" "$RESET" "$codex_path" "$codex_ver"
  else
    printf '  %scodex%s  NOT FOUND in PATH\n' "$RED" "$RESET"
  fi

  if [[ -n "$node_path" ]]; then
    local node_ver
    node_ver="$(node --version 2>/dev/null || printf 'unknown')"
    printf '  %snode%s   %s  (%s)\n' "$GREEN" "$RESET" "$node_path" "$node_ver"
  else
    printf '  %snode%s   NOT FOUND in PATH\n' "$RED" "$RESET"
  fi

  printf '  %sjq%s     %s\n\n' "${jq_path:+$GREEN}" "$RESET" "${jq_path:-NOT FOUND in PATH}"

  printf '%s=== Rate-limit Helper ===%s\n' "$BOLD" "$RESET"
  local helper
  helper="$(find_codex_rate_limit_helper 2>/dev/null || true)"
  if [[ -f "${helper:-}" ]]; then
    printf '  %sFound%s: %s\n\n' "$GREEN" "$RESET" "$helper"
  else
    printf '  %sNOT FOUND%s: %s\n' "$RED" "$RESET" "${helper:-(empty)}"
    printf '  Reinstall: curl -fsSL %s/raw/main/install.sh | bash\n\n' "$APP_REPO_URL"
  fi

  printf '%s=== Live ~/.codex/auth.json ===%s\n' "$BOLD" "$RESET"
  local live_auth="$CODEX_HOME_DIR/auth.json"
  if [[ -f "$live_auth" ]]; then
    local live_auth_mode live_token_keys live_account_id live_exp live_now
    live_auth_mode="$(jq -r '.auth_mode // "(missing)"' "$live_auth" 2>/dev/null)"
    live_token_keys="$(jq -r '.tokens | keys | join(", ")' "$live_auth" 2>/dev/null || printf '(parse error)')"
    live_account_id="$(jq -r '.tokens.account_id // "(missing)"' "$live_auth" 2>/dev/null)"
    live_exp="$(access_token_exp "$live_auth")"
    live_now="$(date +%s)"
    printf '  File:         %s\n' "$live_auth"
    printf '  auth_mode:    %s\n' "$live_auth_mode"
    printf '  token keys:   %s\n' "$live_token_keys"
    printf '  account_id:   %s\n' "$live_account_id"
    if [[ -n "$live_exp" && "$live_exp" =~ ^[0-9]+$ ]]; then
      if ((live_now >= live_exp)); then
        printf '  access_token: %sEXPIRED%s (expired %ds ago)\n' "$RED" "$RESET" "$((live_now - live_exp))"
      else
        printf '  access_token: %svalid%s (expires in %ds)\n' "$GREEN" "$RESET" "$((live_exp - live_now))"
      fi
    else
      printf '  access_token: %s(expiry unknown / not a JWT)%s\n' "$YELLOW" "$RESET"
    fi
    if validate_codex_auth "$live_auth"; then
      printf '  validate:     %sok%s\n' "$GREEN" "$RESET"
    else
      printf '  validate:     %sFAILED%s (missing required fields)\n' "$RED" "$RESET"
    fi
  else
    printf '  %sFile not found%s: %s\n' "$RED" "$RESET" "$live_auth"
  fi
  printf '\n'

  local files=()
  if [[ -n "$target_account" ]]; then
    files=("$(codex_account_file "$target_account")")
  else
    for f in "$CODEX_ACCOUNTS_DIR"/*.json; do
      [[ -e "$f" ]] && files+=("$f")
    done
  fi

  if [[ "${#files[@]}" -eq 0 ]]; then
    printf '%s=== Stored Codex Accounts ===%s\n' "$BOLD" "$RESET"
    printf '  No stored Codex accounts found.\n\n'
    return 0
  fi

  for file in "${files[@]}"; do
    local name
    name="$(basename "$file" .json)"
    printf '%s=== Stored Account: %s ===%s\n' "$BOLD" "$name" "$RESET"

    if [[ ! -f "$file" ]]; then
      printf '  %sFile not found%s: %s\n\n' "$RED" "$RESET" "$file"
      continue
    fi

    local auth_mode token_keys account_id exp now
    auth_mode="$(jq -r '.auth_mode // "(missing)"' "$file" 2>/dev/null)"
    token_keys="$(jq -r '.tokens | keys | join(", ")' "$file" 2>/dev/null || printf '(parse error)')"
    account_id="$(jq -r '.tokens.account_id // "(missing)"' "$file" 2>/dev/null)"
    exp="$(access_token_exp "$file")"
    now="$(date +%s)"
    printf '  auth_mode:    %s\n' "$auth_mode"
    printf '  token keys:   %s\n' "$token_keys"
    printf '  account_id:   %s\n' "$account_id"
    if [[ -n "$exp" && "$exp" =~ ^[0-9]+$ ]]; then
      if ((now >= exp)); then
        printf '  access_token: %sEXPIRED%s (expired %ds ago)\n' "$RED" "$RESET" "$((now - exp))"
      else
        printf '  access_token: %svalid%s (expires in %ds)\n' "$GREEN" "$RESET" "$((exp - now))"
      fi
    else
      printf '  access_token: %s(expiry unknown / not a JWT)%s\n' "$YELLOW" "$RESET"
    fi
    if validate_codex_auth "$file"; then
      printf '  validate:     %sok%s\n' "$GREEN" "$RESET"
    else
      printf '  validate:     %sFAILED%s (missing required fields)\n' "$RED" "$RESET"
    fi

    if [[ -n "$codex_path" && -n "$node_path" && -f "${helper:-}" ]]; then
      printf '  Running rate-limit check (timeout 20s)...\n'
      local runtime out_file err_file chk_status
      runtime="$RUNTIME_DIR/debug-$name-$$"
      out_file="$RUNTIME_DIR/debug-$name-$$-out.json"
      err_file="$RUNTIME_DIR/debug-$name-$$-err.txt"
      mkdir -p "$runtime"
      chmod 700 "$runtime"
      cp "$file" "$runtime/auth.json"
      chmod 600 "$runtime/auth.json"

      chk_status=0
      CODEX_HOME="$runtime" node "$helper" 20 >"$out_file" 2>"$err_file" || chk_status=$?

      printf '  Exit status:  %s\n' "$chk_status"

      if [[ -s "$err_file" ]]; then
        printf '  %sStderr:%s\n' "$YELLOW" "$RESET"
        while IFS= read -r line; do printf '    %s\n' "$line"; done <"$err_file"
      else
        printf '  Stderr:       (empty)\n'
      fi

      if [[ -s "$out_file" ]]; then
        printf '  Stdout:\n'
        while IFS= read -r line; do printf '    %s\n' "$line"; done <"$out_file"
        local limits err_msg
        limits="$(jq -c '.rateLimitsByLimitId.codex // .rateLimits // empty' "$out_file" 2>/dev/null)"
        if [[ -n "$limits" && "$limits" != "null" ]]; then
          printf '  %sRate limits: received ok%s\n' "$GREEN" "$RESET"
        else
          err_msg="$(jq -r '.error.message // empty' "$out_file" 2>/dev/null)"
          printf '  %sRate limits: NOT received%s%s\n' "$RED" "${err_msg:+ — $err_msg}" "$RESET"
        fi
      else
        printf '  %sStdout: (empty — codex app-server produced no JSON)%s\n' "$RED" "$RESET"
      fi

      if [[ -f "$runtime/auth.json" ]]; then
        local new_exp
        new_exp="$(access_token_exp "$runtime/auth.json")"
        if [[ -n "$new_exp" && "$new_exp" != "${exp:-}" && "$new_exp" =~ ^[0-9]+$ ]]; then
          local new_exp_iso
          new_exp_iso="$(iso_from_epoch "$new_exp" 2>/dev/null || printf '%s' "$new_exp")"
          printf '  %sToken refreshed during check (new expiry: %s)%s\n' "$GREEN" "$new_exp_iso" "$RESET"
        fi
      fi

      rm -rf "$runtime" "$out_file" "$err_file"
    else
      printf '  %sSkipping rate-limit check: codex or node not found, or helper missing%s\n' \
        "$YELLOW" "$RESET"
    fi

    printf '\n'
  done
}

