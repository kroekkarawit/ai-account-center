# shellcheck shell=bash
# aic module: resume
# After an account switch, restart CLI sessions in their own terminal tab and
# resume the same chat: `cd <dir> && claude --resume <id>` / `codex resume <id>`.
# Tabs are found by tty through iTerm2 or Terminal.app AppleScript; anything
# else gets the command printed to run by hand.
# Sourced by lib/aic/_load.sh; not executed directly.

pid_tty() {
  local tty
  tty="$(ps -o tty= -p "$1" 2>/dev/null | tr -d ' ')"
  [[ -n "$tty" && "$tty" != "??" && "$tty" != "?" ]] || return 1
  [[ "$tty" == /dev/* ]] || tty="/dev/$tty"
  printf '%s' "$tty"
}

# The session must sit directly on an interactive shell, so that when it exits
# the tab drops back to a prompt we can type into (not e.g. `exec claude`).
pid_parent_is_shell() {
  local ppid comm
  ppid="$(ps -o ppid= -p "$1" 2>/dev/null | tr -d ' ')"
  [[ "$ppid" =~ ^[0-9]+$ ]] || return 1
  comm="$(ps -o comm= -p "$ppid" 2>/dev/null)"
  comm="${comm##*/}"
  comm="${comm#-}"
  case "$comm" in
    zsh|bash|fish|sh|ksh|tcsh|nu) return 0 ;;
  esac
  return 1
}

# Never restart the process that is running aic (e.g. aic called from a
# Claude Code Bash tool).
pid_is_own_ancestor() {
  local target="$1" pid="$$" guard=0
  while [[ "$pid" =~ ^[0-9]+$ ]] && (( pid > 1 && guard < 64 )); do
    [[ "$pid" == "$target" ]] && return 0
    pid="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')"
    guard=$((guard + 1))
  done
  return 1
}

# osascript with a time limit: a first-time macOS Automation permission prompt
# (or a busy app) must not hang the account switch.
_osascript_limited() {
  local limit="$1" out pid waited=0; shift
  out="$RUNTIME_DIR/osascript-$$.out"
  osascript "$@" <&0 >"$out" 2>/dev/null &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    if (( waited >= limit * 5 )); then
      kill "$pid" 2>/dev/null || true
      rm -f "$out"
      return 1
    fi
    sleep 0.2
    waited=$((waited + 1))
  done
  wait "$pid" 2>/dev/null || true
  cat "$out" 2>/dev/null
  rm -f "$out"
}

terminal_app_running() {
  [[ "$(_osascript_limited 5 -e "application id \"$1\" is running")" == "true" ]]
}

# Type a command into the terminal tab that owns TTY. Prints the app used.
terminal_write_to_tty() {
  local tty="$1" text="$2" result
  [[ "$(uname -s 2>/dev/null)" == "Darwin" ]] || return 1
  command -v osascript >/dev/null 2>&1 || return 1
  if terminal_app_running com.googlecode.iterm2; then
    result="$(_osascript_limited 15 - "$tty" "$text" <<'OSA'
on run argv
  set targetTty to item 1 of argv
  set cmd to item 2 of argv
  tell application "iTerm2"
    repeat with w in windows
      repeat with t in tabs of w
        repeat with s in sessions of t
          if tty of s is targetTty then
            tell s to write text cmd
            return "ok"
          end if
        end repeat
      end repeat
    end repeat
  end tell
  return "missing"
end run
OSA
)"
    [[ "$result" == "ok" ]] && { printf 'iTerm2'; return 0; }
  fi
  if terminal_app_running com.apple.Terminal; then
    result="$(_osascript_limited 15 - "$tty" "$text" <<'OSA'
on run argv
  set targetTty to item 1 of argv
  set cmd to item 2 of argv
  tell application "Terminal"
    repeat with w in windows
      repeat with t in tabs of w
        if tty of t is targetTty then
          do script cmd in t
          return "ok"
        end if
      end repeat
    end repeat
  end tell
  return "missing"
end run
OSA
)"
    [[ "$result" == "ok" ]] && { printf 'Terminal'; return 0; }
  fi
  return 1
}

# Quote for a POSIX shell, keeping UTF-8 paths readable (printf %q would turn
# Thai/emoji into byte escapes).
shell_quote() {
  local v="$1"
  if [[ "$v" =~ ^[A-Za-z0-9_./:=@%+-]+$ ]]; then
    printf '%s' "$v"
  else
    printf "'%s'" "$(printf '%s' "$v" | sed "s/'/'\\\\''/g")"
  fi
}

# Keep only flags that are safe to carry over: never a positional prompt
# (it would be sent again) and never an old --resume/--continue.
_keep_flags() {
  local bools="$1" values="$2"; shift 2
  local out=() arg
  while [[ "$#" -gt 0 ]]; do
    arg="$1"; shift
    if [[ " $bools " == *" $arg "* ]]; then
      out+=("$arg")
    elif [[ " $values " == *" $arg "* && "$#" -gt 0 ]]; then
      out+=("$arg" "$1"); shift
    elif [[ "$arg" == --*=* && " $values " == *" ${arg%%=*} "* ]]; then
      out+=("$arg")
    fi
  done
  for arg in ${out[@]+"${out[@]}"}; do
    printf ' %s' "$(shell_quote "$arg")"
  done
  return 0
}

claude_resume_command() {
  local cwd="$1" sid="$2" args="$3" flags
  # shellcheck disable=SC2086
  flags="$(_keep_flags \
    "--dangerously-skip-permissions --verbose --chrome --no-chrome --ide" \
    "--model --permission-mode --add-dir --agent --fallback-model" \
    $args)"
  printf 'cd %s && claude%s --resume %s' "$(shell_quote "$cwd")" "$flags" "$(shell_quote "$sid")"
}

codex_resume_command() {
  local cwd="$1" sid="$2" args="$3" flags
  # shellcheck disable=SC2086
  flags="$(_keep_flags \
    "--dangerously-bypass-approvals-and-sandbox --search --no-alt-screen --oss" \
    "-m --model -s --sandbox -a --ask-for-approval -p --profile --add-dir" \
    $args)"
  printf 'cd %s && codex resume%s' "$(shell_quote "$cwd")" "$flags"
  [[ -z "$sid" ]] || printf ' %s' "$(shell_quote "$sid")"
}

# ---- Claude -----------------------------------------------------------------
# Global-login Claude Code CLI sessions in a terminal, from Claude Code's own
# registry (~/.claude/sessions/<pid>.json). Parallel-account sessions use their
# own config dir and are not listed — the switch doesn't affect them.
# Row: pid tty status session_id cwd args
claude_terminal_sessions() {
  local f pid tty sid cwd status args
  for f in "$HOME/.claude/sessions"/*.json; do
    [[ -e "$f" ]] || continue
    pid="$(jq -r '.pid // empty' "$f" 2>/dev/null)"
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    [[ "$(jq -r '.kind // "interactive"' "$f" 2>/dev/null)" == "interactive" ]] || continue
    kill -0 "$pid" 2>/dev/null && claude_pid_is_claude "$pid" || continue
    tty="$(pid_tty "$pid")" || continue
    sid="$(jq -r '.sessionId // empty' "$f")"
    cwd="$(jq -r '.cwd // empty' "$f")"
    [[ -n "$sid" && -n "$cwd" ]] || continue
    status="$(jq -r '.status // "unknown"' "$f")"
    pid_is_own_ancestor "$pid" && status="self"
    args="$(ps -o args= -p "$pid" 2>/dev/null | cut -d' ' -f2-)"
    [[ "$args" == "$(ps -o args= -p "$pid" 2>/dev/null)" ]] && args=""
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$pid" "$tty" "$status" "$sid" "$cwd" "$args"
  done
}

describe_claude_terminal_sessions() {
  local rows="$1" pid tty status sid cwd args
  while IFS=$'\t' read -r pid tty status sid cwd args; do
    [[ -n "$pid" ]] || continue
    case "$status" in
      idle) printf '  %s●%s idle   %s  %s\n' "$GREEN" "$RESET" "$(compact_path "$cwd")" "$DIM${tty#/dev/}$RESET" >&2 ;;
      *)    printf '  %s●%s %-6s %s  %s\n' "$YELLOW" "$RESET" "$status" "$(compact_path "$cwd")" "$DIM${tty#/dev/}$RESET" >&2 ;;
    esac
  done <<<"$rows"
}

# Stop one idle session and resume it in the same tab. Prints the terminal app
# on success; returns 1 (session untouched or closed) otherwise.
restart_claude_session() {
  local pid="$1" tty="$2" cmd="$3" i
  pid_parent_is_shell "$pid" || return 1
  kill -TERM "$pid" 2>/dev/null || return 1
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.2
  done
  if kill -0 "$pid" 2>/dev/null; then
    warn "Claude session PID $pid did not exit; leaving it running."
    return 1
  fi
  sleep 0.4   # let the shell redraw its prompt
  terminal_write_to_tty "$tty" "$cmd"
}

# Restart every idle session; busy ones are left alone (their command is
# printed instead), so no running task is cut off.
restart_claude_sessions_after_switch() {
  local rows pid tty status sid cwd args cmd app manual=()
  rows="$(claude_terminal_sessions)"
  [[ -n "$rows" ]] || return 0
  while IFS=$'\t' read -r pid tty status sid cwd args; do
    [[ -n "$pid" ]] || continue
    cmd="$(claude_resume_command "$cwd" "$sid" "$args")"
    if [[ "$status" == "idle" ]] && app="$(restart_claude_session "$pid" "$tty" "$cmd")"; then
      printf '  %s↻%s resumed in %s (%s): %s\n' "$GREEN" "$RESET" "$app" "${tty#/dev/}" "$(compact_path "$cwd")"
    else
      manual+=("$status|$cmd")
    fi
  done <<<"$rows"

  if [[ "${#manual[@]}" -gt 0 ]]; then
    printf '%sThese sessions still use the previous account until restarted. Run in their tab:%s\n' "$YELLOW" "$RESET"
    local item
    for item in "${manual[@]}"; do
      printf '  %s[%s]%s %s\n' "$DIM" "${item%%|*}" "$RESET" "${item#*|}"
    done
  fi
}

# ---- Codex ------------------------------------------------------------------
# Before Codex sessions are force-closed: one row per terminal session root.
# Row: tty cwd session_id args   (session_id "" = open the resume picker)
# Newer Codex TUIs talk to a shared app-server daemon that holds the rollout
# files, so a tab is matched to the newest open rollout recorded for its cwd;
# when several tabs share a cwd the match is ambiguous and the picker is used.
codex_resume_snapshot() {
  local roots="$1" table_file="$2" root tty tree rollout sid cwd args
  local all_open rows="" tab_cwds="" f
  all_open="$(session_rollout_files "$(awk '{print $1}' "$table_file")" 2>/dev/null |
    while IFS= read -r f; do
      [[ -r "$f" ]] || continue
      printf '%s\t%s\t%s\n' "$(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f" 2>/dev/null || printf 0)" \
        "$(rollout_project_dir "$f")" "$f"
    done | sort -rn)"

  while IFS= read -r root; do
    [[ "$root" =~ ^[0-9]+$ ]] || continue
    pid_parent_is_shell "$root" || continue
    tty="$(pid_tty "$root")" || continue
    tree="$(expand_process_tree_pids "$root" "$table_file")"
    cwd="$(cwd_for_pid "$root")"
    rollout="$(session_rollout_files "$tree" | head -n 1)"
    if [[ -n "$rollout" ]]; then
      cwd="$(rollout_project_dir "$rollout" | grep . || printf '%s' "$cwd")"
    elif [[ -n "$cwd" ]]; then
      rollout="$(awk -F'\t' -v c="$cwd" '$2 == c { print $3; exit }' <<<"$all_open")"
    fi
    if [[ -z "$cwd" || ! -d "$cwd" ]]; then
      printf '  %sCodex in %s: its folder is gone, so it will not be reopened.%s\n' "$YELLOW" "${tty#/dev/}" "$RESET" >&2
      continue
    fi
    sid="$(basename "${rollout:-x}" .jsonl | grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' || true)"
    args="$(command_for_pid "$root" "$table_file")"
    args="${args#*codex}"
    rows+="$tty"$'\t'"$cwd"$'\t'"$sid"$'\t'"$args"$'\n'
    tab_cwds+="$cwd"$'\n'
  done <<<"$roots"

  # Same cwd in several tabs: the cwd match can't tell them apart.
  while IFS=$'\t' read -r tty cwd sid args; do
    [[ -n "$tty" ]] || continue
    if (( $(grep -cxF -- "$cwd" <<<"$tab_cwds") > 1 )); then
      sid=""
    fi
    printf '%s\t%s\t%s\t%s\n' "$tty" "$cwd" "$sid" "$args"
  done <<<"$rows"
}

reopen_codex_sessions() {
  local rows="$1" tty cwd sid args cmd app
  [[ -n "$rows" ]] || return 0
  sleep 0.4
  while IFS=$'\t' read -r tty cwd sid args; do
    [[ -n "$tty" ]] || continue
    # `codex resume` subcommand args come first in the old command; drop them.
    args="${args# resume}"
    cmd="$(codex_resume_command "$cwd" "$sid" "$args")"
    if app="$(terminal_write_to_tty "$tty" "$cmd")"; then
      printf '  %s↻%s Codex resumed in %s (%s): %s\n' "$GREEN" "$RESET" "$app" "${tty#/dev/}" "$(compact_path "$cwd")" >&2
    else
      printf '  Resume Codex by hand: %s\n' "$cmd" >&2
    fi
  done <<<"$rows"
}
