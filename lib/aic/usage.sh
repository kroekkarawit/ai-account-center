# shellcheck shell=bash
# aic module: usage
# Usage refresh (Codex + Claude), rate-limit parsing, scoring, recommendations
# Sourced by lib/aic/_load.sh; not executed directly.

find_codex_rate_limit_helper() {
  local script_path script_root candidate
  if [[ -n "${AIC_CODEX_RATE_LIMIT_HELPER:-}" ]]; then
    [[ -f "$AIC_CODEX_RATE_LIMIT_HELPER" ]] && {
      printf '%s' "$AIC_CODEX_RATE_LIMIT_HELPER"
      return 0
    }
  fi

  script_path="$(resolve_self)"
  script_root="$(cd "$(dirname "$script_path")/.." && pwd)"
  for candidate in \
    "$script_root/lib/codex-rate-limits.mjs" \
    "$APP_DIR/lib/codex-rate-limits.mjs" \
    "$HOME/.local/share/ai-account-center/lib/codex-rate-limits.mjs"
  do
    if [[ -f "$candidate" ]]; then
      printf '%s' "$candidate"
      return 0
    fi
  done

  printf '%s' "$script_root/lib/codex-rate-limits.mjs"
  return 1
}

write_error_usage() {
  local provider="$1" name="$2" message="$3"
  local destination
  destination="$(usage_file "$provider" "$name")"
  jq -n \
    --arg provider "$provider" \
    --arg account "$name" \
    --arg checked "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg error "$message" \
    '{provider:$provider, account:$account, checked_at:$checked, status:"error", error:$error}' \
    >"$destination.tmp"
  chmod 600 "$destination.tmp"
  mv -f "$destination.tmp" "$destination"
}

refresh_codex_account() {
  local name="$1"
  local mode="${2:-manual}"
  local source
  source="$(codex_account_file "$name")"
  [[ -f "$source" ]] || return 1

  local enabled
  enabled="$(jq -r '.monitor.codex.enabled // true' "$CONFIG_FILE")"
  [[ "$enabled" == "true" ]] || return 0
  require_command node
  require_command codex

  local runtime output timeout_seconds helper
  runtime="$RUNTIME_DIR/codex-$name"
  output="$RUNTIME_DIR/codex-$name-rate-limits.json"
  timeout_seconds="$(jq -r '.monitor.codex.timeout_seconds // 120' "$CONFIG_FILE")"
  helper="$(find_codex_rate_limit_helper)" ||
    die "Missing Codex rate-limit helper. Reinstall with: curl -fsSL $APP_REPO_URL/raw/main/install.sh | bash"
  [[ -f "$helper" ]] || die "Missing Codex rate-limit helper: $helper"

  rm -rf "$runtime"
  mkdir -p "$runtime"
  chmod 700 "$runtime"
  cp "$source" "$runtime/auth.json"
  chmod 600 "$runtime/auth.json"

  local status=0
  CODEX_HOME="$runtime" node "$helper" "$timeout_seconds" \
    >"$output" 2>"$output.stderr" || status=$?

  if [[ "$status" -eq 0 && -f "$runtime/auth.json" ]] && validate_codex_auth "$runtime/auth.json"; then
    cp "$runtime/auth.json" "$source.tmp"
    chmod 600 "$source.tmp"
    mv -f "$source.tmp" "$source"

    if [[ "$mode" != "background" && "$(active_codex_name)" == "$name" ]]; then
      cp "$source" "$CODEX_HOME_DIR/auth.json.tmp"
      chmod 600 "$CODEX_HOME_DIR/auth.json.tmp"
      mv -f "$CODEX_HOME_DIR/auth.json.tmp" "$CODEX_HOME_DIR/auth.json"
    fi
  fi

  local limits
  limits="$(jq -c '.rateLimitsByLimitId.codex // .rateLimits // empty' "$output" 2>/dev/null)"
  if [[ -z "$limits" || "$limits" == "null" ]]; then
    local error_message
    error_message="$(tail -1 "$output.stderr" 2>/dev/null)"
    [[ -n "$error_message" ]] ||
      error_message="$(jq -r '.error.message // empty' "$output" 2>/dev/null)"
    [[ -n "$error_message" ]] ||
      error_message="Codex app-server returned no rate-limit metadata (exit $status)."
    write_error_usage codex "$name" "$error_message"
    rm -rf "$runtime"
    return 1
  fi

  local destination
  destination="$(usage_file codex "$name")"
  jq -n \
    --arg account "$name" \
    --arg checked "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson limits "$limits" \
    '{
      provider:"codex",
      account:$account,
      checked_at:$checked,
      status:"ok",
      plan_type:($limits.planType // null),
      limits:{
        five_hour:{
          used_percent:($limits.primary.usedPercent // null),
          remaining_percent:(100 - ($limits.primary.usedPercent // 0)),
          resets_at_epoch:($limits.primary.resetsAt // null)
        },
        weekly:{
          used_percent:($limits.secondary.usedPercent // null),
          remaining_percent:(100 - ($limits.secondary.usedPercent // 0)),
          resets_at_epoch:($limits.secondary.resetsAt // null)
        }
      }
    }' >"$destination.tmp"
  chmod 600 "$destination.tmp"
  mv -f "$destination.tmp" "$destination"
  rm -rf "$runtime"
  return 0
}

refresh_claude_account() {
  local name="$1"
  local source token timeout_seconds enabled
  source="$(claude_account_file "$name")"
  [[ -f "$source" ]] || return 1
  enabled="$(jq -r '.monitor.claude.enabled // true' "$CONFIG_FILE")"
  [[ "$enabled" == "true" ]] || return 0
  require_command curl

  if [[ "$(claude_account_kind "$name")" != "oauth" ]]; then
    write_error_usage claude "$name" "Claude account is not a full OAuth login. Re-add it from Add account -> Claude -> Login with OAuth."
    return 1
  fi

  token="$(jq -r '.claudeAiOauth.accessToken // empty' "$source")"
  token="$(sanitize_claude_token "$token")"
  [[ -n "$token" ]] || {
    write_error_usage claude "$name" "Stored Claude OAuth token is empty."
    return 1
  }
  timeout_seconds="$(jq -r '.monitor.claude.timeout_seconds // 15' "$CONFIG_FILE")"

  if is_claude_token_expired "$source"; then
    if refresh_claude_oauth_account "$name" "$source"; then
      token="$(jq -r '.claudeAiOauth.accessToken // empty' "$source")"
      token="$(sanitize_claude_token "$token")"
    else
      write_error_usage claude "$name" "Stored Claude OAuth token is expired and could not be refreshed. Re-login from Add account -> Claude -> Login with OAuth."
      return 1
    fi
  fi

  local response
  response="$(
    curl -sS --max-time "$timeout_seconds" \
      -H "Accept: application/json" \
      -H "Content-Type: application/json" \
      -H "Authorization: Bearer $token" \
      -H "anthropic-beta: oauth-2025-04-20" \
      -H "User-Agent: ai-account-center/$APP_VERSION" \
      "https://api.anthropic.com/api/oauth/usage" 2>/dev/null
  )"

  local usage="$response" source_type="usage_endpoint"
  if ! jq -e '.five_hour and .seven_day' >/dev/null 2>&1 <<<"$response"; then
    local message
    message="$(jq -r '.error.message // .message // "Claude usage request failed."' <<<"$response" 2>/dev/null)"
    if [[ "$message" == "Invalid authentication credentials" ]] && refresh_claude_oauth_account "$name" "$source"; then
      token="$(jq -r '.claudeAiOauth.accessToken // empty' "$source")"
      token="$(sanitize_claude_token "$token")"
      response="$(
        curl -sS --max-time "$timeout_seconds" \
          -H "Accept: application/json" \
          -H "Content-Type: application/json" \
          -H "Authorization: Bearer $token" \
          -H "anthropic-beta: oauth-2025-04-20" \
          -H "User-Agent: ai-account-center/$APP_VERSION" \
          "https://api.anthropic.com/api/oauth/usage" 2>/dev/null
      )"
      usage="$response"
      if jq -e '.five_hour and .seven_day' >/dev/null 2>&1 <<<"$response"; then
        message=""
      else
        message="$(jq -r '.error.message // .message // "Claude usage request failed."' <<<"$response" 2>/dev/null)"
      fi
    fi
    [[ -z "$message" ]] || {
      write_error_usage claude "$name" "$message"
      return 1
    }
  fi

  local destination
  destination="$(usage_file claude "$name")"
  jq -n \
    --arg account "$name" \
    --arg checked "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg source "$source_type" \
    --argjson usage "$usage" \
    '{
      provider:"claude",
      account:$account,
      checked_at:$checked,
      status:"ok",
      source:$source,
      limits:{
        five_hour:{
          used_percent:($usage.five_hour.utilization // null),
          remaining_percent:(100 - ($usage.five_hour.utilization // 0)),
          resets_at:($usage.five_hour.resets_at // null),
          resets_at_epoch:($usage.five_hour.resets_at_epoch // null)
        },
        weekly:{
          used_percent:($usage.seven_day.utilization // null),
          remaining_percent:(100 - ($usage.seven_day.utilization // 0)),
          resets_at:($usage.seven_day.resets_at // null),
          resets_at_epoch:($usage.seven_day.resets_at_epoch // null)
        }
      }
    }' >"$destination.tmp"
  chmod 600 "$destination.tmp"
  mv -f "$destination.tmp" "$destination"
  return 0
}

refresh_all() {
  local mode="${1:-manual}" failures=0 successes=0 found=0 total=0
  local result_dir pids=() job_keys=() file name

  for file in "$CODEX_ACCOUNTS_DIR"/*.json "$CLAUDE_ACCOUNTS_DIR"/*.json; do
    [[ -e "$file" ]] || continue
    total=$((total + 1))
    found=1
  done

  if [[ "$found" -eq 0 ]]; then
    warn "No accounts have been added."
    return 1
  fi

  [[ "$mode" == "background" ]] && write_refresh_status running 0 "$total" "" 0 0

  result_dir="$RUNTIME_DIR/refresh-$$"
  mkdir -p "$result_dir"

  for file in "$CODEX_ACCOUNTS_DIR"/*.json; do
    [[ -e "$file" ]] || continue
    name="$(basename "$file" .json)"
    job_keys+=("codex:$name")
    printf 'Refreshing Codex/%s...\n' "$name"
    (
      local r='fail'
      trap 'printf "%s" "$r" >"$result_dir/codex-$name"' EXIT
      refresh_codex_account "$name" "$mode" && r='ok' || true
    ) &
    pids+=("$!")
  done

  for file in "$CLAUDE_ACCOUNTS_DIR"/*.json; do
    [[ -e "$file" ]] || continue
    name="$(basename "$file" .json)"
    job_keys+=("claude:$name")
    printf 'Refreshing Claude/%s...\n' "$name"
    (
      local r='fail'
      trap 'printf "%s" "$r" >"$result_dir/claude-$name"' EXIT
      refresh_claude_account "$name" && r='ok' || true
    ) &
    pids+=("$!")
  done

  local pid
  for pid in "${pids[@]}"; do
    wait "$pid" 2>/dev/null || true
  done

  local job provider acct result
  for job in "${job_keys[@]}"; do
    provider="${job%%:*}"
    acct="${job##*:}"
    result="$(cat "$result_dir/$provider-$acct" 2>/dev/null)"
    if [[ "$result" == "ok" ]]; then
      printf '%s/%s: ok\n' "$(uppercase "$provider")" "$acct"
      successes=$((successes + 1))
    else
      printf '%s/%s: failed\n' "$(uppercase "$provider")" "$acct"
      failures=$((failures + 1))
    fi
  done
  rm -rf "$result_dir"

  local done_count=$((successes + failures))
  if [[ "$mode" == "background" ]]; then
    if [[ "$failures" -eq 0 ]]; then
      write_refresh_status done "$done_count" "$total" "" "$successes" "$failures"
    else
      write_refresh_status failed "$done_count" "$total" "" "$successes" "$failures"
    fi
  fi
  [[ "$failures" -eq 0 ]]
}

write_refresh_status() {
  local state="$1" done="$2" total="$3" current="$4" ok="$5" failures="$6"
  jq -n \
    --arg state "$state" \
    --arg checked "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg current "$current" \
    --argjson done "$done" \
    --argjson total "$total" \
    --argjson ok "$ok" \
    --argjson failures "$failures" \
    '{
      state:$state,
      updated_at:$checked,
      current:$current,
      done:$done,
      total:$total,
      ok:$ok,
      failures:$failures
    }' >"$REFRESH_STATUS_FILE.tmp" 2>/dev/null || return 0
  chmod 600 "$REFRESH_STATUS_FILE.tmp" 2>/dev/null || true
  mv -f "$REFRESH_STATUS_FILE.tmp" "$REFRESH_STATUS_FILE" 2>/dev/null || true
}

refresh_status_line() {
  [[ -f "$REFRESH_STATUS_FILE" ]] || return 0
  local state current done total ok failures updated timezone updated_epoch updated_text
  state="$(jq -r '.state // empty' "$REFRESH_STATUS_FILE" 2>/dev/null)"
  [[ -n "$state" ]] || return 0
  current="$(jq -r '.current // empty' "$REFRESH_STATUS_FILE" 2>/dev/null)"
  done="$(jq -r '.done // 0' "$REFRESH_STATUS_FILE" 2>/dev/null)"
  total="$(jq -r '.total // 0' "$REFRESH_STATUS_FILE" 2>/dev/null)"
  ok="$(jq -r '.ok // 0' "$REFRESH_STATUS_FILE" 2>/dev/null)"
  failures="$(jq -r '.failures // 0' "$REFRESH_STATUS_FILE" 2>/dev/null)"
  updated="$(jq -r '.updated_at // empty' "$REFRESH_STATUS_FILE" 2>/dev/null)"
  timezone="$(jq -r '.display.timezone // "Asia/Bangkok"' "$CONFIG_FILE")"

  if [[ "$state" == "running" ]]; then
    printf '%sBackground refresh:%s %s [%s/%s]\n' "$YELLOW" "$RESET" "${current:-starting}" "$done" "$total"
  elif [[ "$state" == "done" || "$state" == "failed" ]]; then
    updated_epoch="$(epoch_from_iso "$updated")"
    updated_text="-"
    if [[ -n "$updated_epoch" ]]; then
      updated_text="$(TZ="$timezone" date -r "$updated_epoch" '+%H:%M' 2>/dev/null ||
        TZ="$timezone" date -d "@$updated_epoch" '+%H:%M' 2>/dev/null)"
    fi
    if [[ "$state" == "done" ]]; then
      printf '%sLast background refresh:%s %s, %s ok, 0 failed\n' "$DIM" "$RESET" "$updated_text" "$ok"
    else
      printf '%sLast background refresh:%s %s, %s/%s done, %s failed\n' "$YELLOW" "$RESET" "$updated_text" "$done" "$total" "$failures"
    fi
  fi
}

background_refresh_running() {
  [[ -f "$REFRESH_STATUS_FILE" ]] || return 1
  [[ "$(jq -r '.state // empty' "$REFRESH_STATUS_FILE" 2>/dev/null)" == "running" ]] || return 1
  local updated updated_epoch now
  updated="$(jq -r '.updated_at // empty' "$REFRESH_STATUS_FILE" 2>/dev/null)"
  updated_epoch="$(epoch_from_iso "$updated")"
  now="$(date +%s)"
  [[ -n "$updated_epoch" ]] && ((now - updated_epoch < 1800))
}

background_refresh_recent() {
  [[ -f "$REFRESH_STATUS_FILE" ]] || return 1
  local state updated updated_epoch now interval cooldown
  state="$(jq -r '.state // empty' "$REFRESH_STATUS_FILE" 2>/dev/null)"
  [[ "$state" == "done" || "$state" == "failed" ]] || return 1
  updated="$(jq -r '.updated_at // empty' "$REFRESH_STATUS_FILE" 2>/dev/null)"
  updated_epoch="$(epoch_from_iso "$updated")"
  [[ -n "$updated_epoch" ]] || return 1
  now="$(date +%s)"
  interval="$(jq -r '.schedule.interval_minutes // 15' "$CONFIG_FILE" 2>/dev/null)"
  [[ "$interval" =~ ^[0-9]+$ ]] || interval=15
  cooldown=$((interval * 60))
  ((cooldown < 300)) && cooldown=300
  ((now - updated_epoch < cooldown))
}

start_background_refresh_for_tui() {
  background_refresh_running && return 0
  background_refresh_recent && return 0
  rm -f "$REFRESH_REDRAW_FILE"
  write_refresh_status running 0 0 "" 0 0
  (
    refresh_all background >"$RUNTIME_DIR/background-refresh.log" 2>"$RUNTIME_DIR/background-refresh-error.log" || true
    : >"$REFRESH_REDRAW_FILE"
  ) &
}

reset_epoch() {
  local file="$1" window="$2"
  local value epoch timezone
  value="$(jq -r --arg window "$window" '.limits[$window].resets_at // empty' "$file" 2>/dev/null)"
  epoch="$(jq -r --arg window "$window" '.limits[$window].resets_at_epoch // empty' "$file" 2>/dev/null)"
  if [[ -n "$value" ]]; then
    epoch="$(epoch_from_iso "$value")"
  fi
  printf '%s' "$epoch"
}

format_reset() {
  local file="$1" window="$2" style="$3"
  local epoch timezone format
  timezone="$(jq -r '.display.timezone // "Asia/Bangkok"' "$CONFIG_FILE")"
  epoch="$(reset_epoch "$file" "$window")"
  [[ -n "$epoch" ]] || {
    printf '-'
    return
  }

  if [[ "$style" == "time" ]]; then
    format='+%H:%M'
  else
    format='+%b %d, %H:%M'
  fi
  TZ="$timezone" date -r "$epoch" "$format" 2>/dev/null ||
    TZ="$timezone" date -d "@$epoch" "$format" 2>/dev/null
}

quota_color() {
  local used="$1"
  if [[ ! "$used" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    printf '%s' "$DIM"
  elif awk "BEGIN { exit !($used >= 90) }"; then
    printf '%s' "$RED"
  elif awk "BEGIN { exit !($used >= 70) }"; then
    printf '%s' "$YELLOW"
  else
    printf '%s' "$GREEN"
  fi
}

quota_bar() {
  local used="$1" width=10 filled=0
  if [[ "$used" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    filled="$(awk -v value="$used" -v width="$width" \
      'BEGIN { n=int((value * width / 100) + 0.5); if(n<0)n=0; if(n>width)n=width; print n }')"
  fi
  local empty=$((width - filled))
  local i
  for ((i = 0; i < filled; i++)); do printf '█'; done
  for ((i = 0; i < empty; i++)); do printf '░'; done
}

format_quota_badge() {
  local label="$1" used="$2" reset="$3"
  if [[ ! "$used" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    printf '%s[%s ░░░░░░░░░░  -- → %s]%s' "$DIM" "$label" "$reset" "$RESET"
    return
  fi
  local color bar
  color="$(quota_color "$used")"
  bar="$(quota_bar "$used")"
  printf '%s[%s %s %3.0f%% → %s]%s' "$color" "$label" "$bar" "$used" "$reset" "$RESET"
}

recommendation_label() {
  local score="$1"
  if awk "BEGIN { exit !($score >= 75) }"; then
    printf 'good'
  elif awk "BEGIN { exit !($score >= 50) }"; then
    printf 'ok'
  elif awk "BEGIN { exit !($score <= -50) }"; then
    printf 'blocked'
  else
    printf 'avoid'
  fi
}

recommendation_reason() {
  local five="$1" week="$2" reset5_hours="$3" resetw_hours="$4" stale="$5"
  local reasons=()
  if awk "BEGIN { exit !($five <= 20) }"; then
    reasons+=("5h usage is low")
  elif awk "BEGIN { exit !($five >= 90) }"; then
    reasons+=("5h usage is near limit")
  fi
  if awk "BEGIN { exit !($week <= 35) }"; then
    reasons+=("weekly usage is low")
  elif awk "BEGIN { exit !($week >= 95) }"; then
    reasons+=("weekly usage is almost full")
  fi
  if [[ "$resetw_hours" != "-" ]] && awk "BEGIN { exit !($resetw_hours <= 24) }"; then
    reasons+=("weekly reset is near")
  fi
  if [[ "$reset5_hours" != "-" ]] && awk "BEGIN { exit !($reset5_hours <= 1) }"; then
    reasons+=("5h reset is soon")
  fi
  [[ "$stale" == "1" ]] && reasons+=("usage data is stale")

  if [[ "${#reasons[@]}" -eq 0 ]]; then
    printf 'balanced usage and reset timing'
    return
  fi

  local reason_text="" reason
  for reason in "${reasons[@]}"; do
    if [[ -n "$reason_text" ]]; then
      reason_text+=", $reason"
    else
      reason_text="$reason"
    fi
  done
  printf '%s' "$reason_text"
}

# Account scoring / recommendations. The math is provider-agnostic — every
# account has a 5-hour window and a weekly window in the same usage-file shape —
# so score_account works for both Codex and Claude. The per-provider wrappers
# below only bind the provider namespace (usage files + <provider>_names).
score_account() {
  local provider="$1" name="$2" usage now status five week reset5 resetw checked checked_epoch stale=0
  usage="$(usage_file "$provider" "$name")"
  now="$(date +%s)"

  if [[ ! -f "$usage" ]]; then
    printf '%s\t%s\t%s\t%s\t%s\n' "$name" "-40" "no usage data; refresh first" "blocked" ""
    return
  fi

  status="$(jq -r '.status // "error"' "$usage")"
  if [[ "$status" != "ok" ]]; then
    printf '%s\t%s\t%s\t%s\t%s\n' "$name" "-100" "usage check failed" "blocked" ""
    return
  fi

  five="$(jq -r '.limits.five_hour.used_percent // empty' "$usage")"
  week="$(jq -r '.limits.weekly.used_percent // empty' "$usage")"
  if [[ ! "$five" =~ ^[0-9]+([.][0-9]+)?$ || ! "$week" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    printf '%s\t%s\t%s\t%s\t%s\n' "$name" "-80" "usage data is incomplete" "blocked" ""
    return
  fi

  reset5="$(reset_epoch "$usage" five_hour)"
  resetw="$(reset_epoch "$usage" weekly)"
  checked="$(jq -r '.checked_at // empty' "$usage")"
  checked_epoch="$(epoch_from_iso "$checked")"
  if [[ -n "$checked_epoch" ]] && awk "BEGIN { exit !(($now - $checked_epoch) > 1800) }"; then
    stale=1
  fi

  awk -v name="$name" \
    -v five="$five" \
    -v week="$week" \
    -v reset5="${reset5:-0}" \
    -v resetw="${resetw:-0}" \
    -v now="$now" \
    -v stale="$stale" '
    function reset_bonus(hours, short, medium, long) {
      if (hours <= 0) return 0
      if (hours <= short) return 1
      if (hours <= medium) return 0.7
      if (hours <= long) return 0.35
      return 0
    }
    BEGIN {
      reset5_hours = reset5 > 0 ? (reset5 - now) / 3600 : -1
      resetw_hours = resetw > 0 ? (resetw - now) / 3600 : -1
      score = (45 * (1 - five / 100)) + (25 * (1 - week / 100))
      score += 10 * reset_bonus(reset5_hours, 0.5, 1, 2)
      score += 15 * reset_bonus(resetw_hours, 6, 24, 72)
      score += stale ? 0 : 5
      if (five >= 95) score -= 50
      else if (five >= 90) score -= 30
      if (week >= 100) score -= 100
      else if (week >= 95) score -= 50
      else if (week >= 90) score -= 25
      if (stale) score -= 20
      if (score > 100) score = 100
      if (score < -100) score = -100
      printf "%s\t%.0f\t%.2f\t%.2f\t%d\n", name, score, reset5_hours, resetw_hours, stale
    }'
}

score_codex_account() { score_account codex "$1"; }
score_claude_account() { score_account claude "$1"; }

provider_recommendations() {
  local provider="$1" name
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    score_account "$provider" "$name"
  done < <("${provider}_names") | sort -t $'\t' -k2,2nr
}

codex_recommendations() { provider_recommendations codex; }
claude_recommendations() { provider_recommendations claude; }

best_codex_recommendation() { codex_recommendations | head -1; }
best_claude_recommendation() { claude_recommendations | head -1; }

print_recommendation_bar() {
  local provider="$1" label="$2"
  local best best_fn name score reset5_hours resetw_hours stale usage five week reason rec_label
  best_fn="best_${provider}_recommendation"
  best="$("$best_fn")"
  [[ -n "$best" ]] || {
    printf '%sRecommendation%s\n  No %s accounts found.\n\n' "$BOLD" "$RESET" "$label"
    return 0
  }

  IFS=$'\t' read -r name score reset5_hours resetw_hours stale <<<"$best"
  usage="$(usage_file "$provider" "$name")"
  if [[ -f "$usage" ]]; then
    five="$(jq -r '.limits.five_hour.used_percent // "-"' "$usage")"
    week="$(jq -r '.limits.weekly.used_percent // "-"' "$usage")"
  else
    five="-"
    week="-"
  fi
  if [[ "$five" =~ ^[0-9]+([.][0-9]+)?$ && "$week" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    reason="$(recommendation_reason "$five" "$week" "$reset5_hours" "$resetw_hours" "$stale")"
  else
    reason="refresh usage first"
  fi
  rec_label="$(recommendation_label "$score")"

  printf '%sRecommendation%s\n' "$BOLD" "$RESET"
  printf '  Best now: %s%s%s  (%s, score %s/100)\n' "$CYAN" "$name" "$RESET" "$rec_label" "$score"
  printf '  Reason: %s\n\n' "$reason"
}

print_codex_recommendation_bar() { print_recommendation_bar codex Codex; }
print_claude_recommendation_bar() { print_recommendation_bar claude Claude; }

account_choice_label() {
  local provider="$1" name="$2" best_name="$3" score="$4" usage five week reset5 resetw label suffix
  usage="$(usage_file "$provider" "$name")"
  suffix=""
  [[ "$name" == "$best_name" ]] && suffix="  ★ best"
  label="$(recommendation_label "$score")"

  if [[ ! -f "$usage" ]]; then
    printf '%-18s [5h -- → -] [7d -- → -]  %s%s' "$name" "$label" "$suffix"
    return
  fi

  if [[ "$(jq -r '.status // "error"' "$usage")" != "ok" ]]; then
    printf '%-18s [usage error]  blocked%s' "$name" "$suffix"
    return
  fi

  five="$(jq -r '.limits.five_hour.used_percent // "-"' "$usage")"
  week="$(jq -r '.limits.weekly.used_percent // "-"' "$usage")"
  reset5="$(format_reset "$usage" five_hour time)"
  resetw="$(format_reset "$usage" weekly datetime)"
  printf '%-18s [5h %3s%% → %s] [7d %3s%% → %s]  %s%s' \
    "$name" "$five" "$reset5" "$week" "$resetw" "$label" "$suffix"
}

codex_choice_label() { account_choice_label codex "$1" "$2" "$3"; }
claude_choice_label() { account_choice_label claude "$1" "$2" "$3"; }

print_recommendations() {
  local provider="$1" label="$2" best best_fn best_name name score reset5_hours resetw_hours stale
  print_recommendation_bar "$provider" "$label"
  best_fn="best_${provider}_recommendation"
  best="$("$best_fn")"
  best_name="${best%%$'\t'*}"
  printf '%sAccounts%s\n' "$BOLD" "$RESET"
  while IFS=$'\t' read -r name score reset5_hours resetw_hours stale; do
    [[ -n "$name" ]] || continue
    printf '  '
    account_choice_label "$provider" "$name" "$best_name" "$score"
    printf '\n'
  done < <("${provider}_recommendations")
}

print_codex_recommendations() { print_recommendations codex Codex; }
print_claude_recommendations() { print_recommendations claude Claude; }

uppercase() {
  printf '%s' "$1" | tr '[:lower:]' '[:upper:]'
}

next_refresh_countdown() {
  local enabled interval_minutes
  enabled="$(jq -r '.schedule.enabled // false' "$CONFIG_FILE")"
  [[ "$enabled" == "true" ]] || { printf 'off'; return 0; }
  interval_minutes="$(jq -r '.schedule.interval_minutes // 60' "$CONFIG_FILE")"
  [[ "$interval_minutes" =~ ^[0-9]+$ ]] || interval_minutes=60

  local updated updated_epoch now remaining
  updated="$(jq -r '.updated_at // empty' "$REFRESH_STATUS_FILE" 2>/dev/null)"
  [[ -n "$updated" ]] || { printf 'every %sm' "$interval_minutes"; return 0; }
  updated_epoch="$(epoch_from_iso "$updated")"
  [[ -n "$updated_epoch" ]] || { printf 'every %sm' "$interval_minutes"; return 0; }

  now="$(date +%s)"
  remaining=$(( updated_epoch + interval_minutes * 60 - now ))
  if ((remaining <= 0)); then
    printf 'due now'
  elif ((remaining < 60)); then
    printf 'in %ds' "$remaining"
  else
    printf 'in %dm' "$((remaining / 60))"
  fi
}
