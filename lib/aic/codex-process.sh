# shellcheck shell=bash
# aic module: codex-process
# Codex session discovery, display, and force-close on account switch.
# Sourced by lib/aic/_load.sh; not executed directly.

running_codex_processes() {
  if command -v pgrep >/dev/null 2>&1; then
    pgrep -fl '(^|[ /])codex([[:space:]]|$)' 2>/dev/null |
      awk '!/ai-account-center/ && !/codex-rate-limits[.]mjs/ && !/pgrep -fl/'
  else
    ps -axo pid=,command= 2>/dev/null |
      awk '/(^|[ /])codex([[:space:]]|$)/ && !/ai-account-center/ && !/codex-rate-limits[.]mjs/ && !/awk /'
  fi
}

# Keep fixed metadata columns before command. tty/state/cpu/age make the warning
# useful; pid/ppid still drive the safe process-tree close.
process_table() {
  ps -axo pid=,ppid=,tty=,state=,%cpu=,etime=,command= 2>/dev/null |
    awk '{$1=$1; print}'
}

process_field_for_pid() {
  local pid="$1" field="$2" table_file="$3"
  awk -v target="$pid" -v column="$field" '$1 == target { print $column; exit }' "$table_file"
}

parent_for_pid() {
  process_field_for_pid "$1" 2 "$2"
}

command_for_pid() {
  local pid="$1" table_file="$2"
  awk -v target="$pid" '
    $1 == target {
      for (i=1; i<=6; i++) $i=""
      sub(/^ +/, "")
      print
      exit
    }
  ' "$table_file"
}

pid_in_list() {
  local needle="$1" haystack="$2" pid
  while IFS= read -r pid; do
    [[ "$pid" == "$needle" ]] && return 0
  done <<<"$haystack"
  return 1
}

append_unique_pid() {
  local pid="$1" list="$2"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 0
  pid_in_list "$pid" "$list" && {
    printf '%s' "$list"
    return 0
  }
  if [[ -n "$list" ]]; then
    printf '%s\n%s' "$list" "$pid"
  else
    printf '%s' "$pid"
  fi
}

root_pids_from_processes() {
  awk '$1 ~ /^[0-9]+$/ { print $1 }' <<<"$1"
}

pid_has_listed_ancestor() {
  local pid="$1" roots="$2" table_file="$3" parent depth=0
  parent="$(parent_for_pid "$pid" "$table_file")"
  while [[ "$parent" =~ ^[0-9]+$ && "$parent" -gt 1 && "$depth" -lt 64 ]]; do
    pid_in_list "$parent" "$roots" && return 0
    parent="$(parent_for_pid "$parent" "$table_file")"
    depth=$((depth + 1))
  done
  return 1
}

# pgrep normally finds both `node .../codex` and its native codex child. Treat
# that pair as one user-visible session while retaining both in the kill tree.
codex_session_root_pids() {
  local processes="$1" table_file="$2" roots pid
  roots="$(root_pids_from_processes "$processes")"
  while IFS= read -r pid; do
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    pid_has_listed_ancestor "$pid" "$roots" "$table_file" || printf '%s\n' "$pid"
  done <<<"$roots"
}

expand_process_tree_pids() {
  local roots="$1" table_file="$2"
  local all="" queue="" line pid children child remaining

  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    pid="${line%% *}"
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    [[ "$pid" == "$$" || "$pid" == "${PPID:-}" ]] && continue
    all="$(append_unique_pid "$pid" "$all")"
    queue="$(append_unique_pid "$pid" "$queue")"
  done <<<"$roots"

  while [[ -n "$queue" ]]; do
    pid="${queue%%$'\n'*}"
    if [[ "$queue" == *$'\n'* ]]; then
      remaining="${queue#*$'\n'}"
    else
      remaining=""
    fi
    queue="$remaining"

    children="$(awk -v parent="$pid" '$2 == parent { print $1 }' "$table_file")"
    while IFS= read -r child; do
      [[ "$child" =~ ^[0-9]+$ ]] || continue
      [[ "$child" == "$$" || "$child" == "${PPID:-}" ]] && continue
      if ! pid_in_list "$child" "$all"; then
        all="$(append_unique_pid "$child" "$all")"
        queue="$(append_unique_pid "$child" "$queue")"
      fi
    done <<<"$children"
  done

  printf '%s\n' "$all" | awk 'NF'
}

reverse_pids() {
  awk 'NF { lines[++count]=$1 } END { for (i=count; i>=1; i--) print lines[i] }'
}

commands_for_pids() {
  local pids="$1" table_file="$2" pid command
  while IFS= read -r pid; do
    command="$(command_for_pid "$pid" "$table_file")"
    [[ -n "$command" ]] && printf '%s\n' "$command"
  done <<<"$pids"
}

ancestor_commands_for_pid() {
  local pid="$1" table_file="$2" parent command depth=0
  parent="$pid"
  while [[ "$parent" =~ ^[0-9]+$ && "$parent" -gt 1 && "$depth" -lt 64 ]]; do
    command="$(command_for_pid "$parent" "$table_file")"
    [[ -n "$command" ]] && printf '%s\n' "$command"
    parent="$(parent_for_pid "$parent" "$table_file")"
    depth=$((depth + 1))
  done
}

codex_session_client() {
  local root_pid="$1" table_file="$2" source_text ancestors tty
  source_text="$(command_for_pid "$root_pid" "$table_file")"
  ancestors="$(ancestor_commands_for_pid "$root_pid" "$table_file")"

  # Only the root host identifies the owning client. Child commands may include
  # paths inside ChatGPT.app (browser control), Playwright, or an editor even
  # though the actual Codex session was launched from a terminal.
  case "$source_text" in
    *"/.vscode-insiders/extensions/openai.chatgpt"*) printf 'VS Code Insiders extension' ;;
    *"/.vscode/extensions/openai.chatgpt"*|*"openai.chatgpt-"*) printf 'VS Code extension' ;;
    *"Application Support/Zed"*|*"/Zed.app/"*|*"/.local/share/zed"*) printf 'Zed extension' ;;
    *"/Applications/ChatGPT.app/"*|*"/ChatGPT.app/"*) printf 'ChatGPT desktop' ;;
    *)
      case "$ancestors" in
        *"Visual Studio Code.app"*|*"Code Helper"*) printf 'VS Code terminal' ;;
        *"/Zed.app/"*) printf 'Zed terminal' ;;
        *"/Alacritty.app/"*|*"/alacritty"*) printf 'Alacritty terminal' ;;
        *"/iTerm.app/"*|*"iTerm2"*) printf 'iTerm terminal' ;;
        *"/Warp.app/"*) printf 'Warp terminal' ;;
        *"/Terminal.app/"*) printf 'Terminal.app' ;;
        *)
          tty="$(process_field_for_pid "$root_pid" 3 "$table_file")"
          if [[ -n "$tty" && "$tty" != "??" && "$tty" != "?" ]]; then
            printf 'Terminal / CLI'
          elif [[ "$source_text" == *"codex app-server"* ]]; then
            printf 'Editor extension / app-server'
          else
            printf 'Codex CLI'
          fi
          ;;
      esac
      ;;
  esac
}

session_rollout_files() {
  local pids="$1" pid
  command -v lsof >/dev/null 2>&1 || return 0
  while IFS= read -r pid; do
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    lsof -a -p "$pid" -Fn 2>/dev/null |
      awk 'substr($0,1,1)=="n" && $0 ~ /\/sessions\/.*[.]jsonl$/ { print substr($0,2) }'
  done <<<"$pids" | awk '!seen[$0]++'
}

rollout_lifecycle() {
  local file="$1"
  [[ -r "$file" ]] || return 0
  tail -n 2000 "$file" 2>/dev/null |
    jq -r 'select(.type == "event_msg" and
      (.payload.type == "task_started" or
       .payload.type == "task_complete" or
       .payload.type == "turn_aborted")) | .payload.type' 2>/dev/null |
    tail -n 1
}

codex_session_activity() {
  local tree_pids="$1" table_file="$2" rollouts file lifecycle
  local saw_complete=0 saw_lifecycle=0 tree_text max_cpu padded_pids
  rollouts="$(session_rollout_files "$tree_pids")"
  while IFS= read -r file; do
    [[ -n "$file" ]] || continue
    lifecycle="$(rollout_lifecycle "$file")"
    case "$lifecycle" in
      task_started)
        printf 'WORKING\tunfinished agent turn; switching now will interrupt it'
        return 0
        ;;
      task_complete|turn_aborted)
        saw_complete=1
        saw_lifecycle=1
        ;;
      '') ;;
      *) saw_lifecycle=1 ;;
    esac
  done <<<"$rollouts"

  if [[ "$saw_complete" -eq 1 && "$saw_lifecycle" -eq 1 ]]; then
    printf 'IDLE\twaiting for a prompt; no active task'
    return 0
  fi

  # Older clients may not expose an open rollout. A transient code-mode host or
  # measurable activity is useful evidence, but keep the status visibly
  # best-effort rather than claiming certainty.
  tree_text="$(commands_for_pids "$tree_pids" "$table_file")"
  if [[ "$tree_text" == *"codex-code-mode-host"* ]]; then
    printf 'WORKING\tactive tool host (best effort)'
    return 0
  fi
  padded_pids=" $(printf '%s\n' "$tree_pids" | tr '\n' ' ') "
  max_cpu="$(awk -v pids="$padded_pids" '
    index(pids, " " $1 " ") && ($5+0) > max { max=$5+0 }
    END { printf "%.1f", max+0 }
  ' "$table_file")"
  if awk -v cpu="$max_cpu" 'BEGIN { exit !(cpu >= 1.0) }'; then
    printf 'WORKING\tprocess activity observed (best effort)'
  else
    printf 'IDLE?\tno active turn observed'
  fi
}

rollout_project_dir() {
  local file="$1"
  [[ -r "$file" ]] || return 0
  head -n 20 "$file" 2>/dev/null |
    jq -r 'select(.type == "session_meta" and (.payload.cwd // "") != "") | .payload.cwd' 2>/dev/null |
    head -n 1
}

cwd_for_pid() {
  local pid="$1"
  command -v lsof >/dev/null 2>&1 || return 0
  lsof -a -p "$pid" -d cwd -Fn 2>/dev/null |
    awk 'substr($0,1,1)=="n" { print substr($0,2); exit }'
}

codex_session_project() {
  local tree_pids="$1" rollouts file project pid
  rollouts="$(session_rollout_files "$tree_pids")"
  while IFS= read -r file; do
    [[ -n "$file" ]] || continue
    project="$(rollout_project_dir "$file")"
    [[ -n "$project" ]] && {
      printf '%s' "$project"
      return 0
    }
  done <<<"$rollouts"
  while IFS= read -r pid; do
    project="$(cwd_for_pid "$pid")"
    [[ -n "$project" ]] && {
      printf '%s' "$project"
      return 0
    }
  done <<<"$tree_pids"
}

compact_path() {
  local path="$1"
  case "$path" in
    "$HOME") printf '~' ;;
    "$HOME"/*) printf '~/%s' "${path#"$HOME"/}" ;;
    *) printf '%s' "$path" ;;
  esac
}

append_summary_item() {
  local current="$1" item="$2"
  case ",$current," in
    *",$item,"*) printf '%s' "$current" ;;
    ",,") printf '%s' "$item" ;;
    *) printf '%s, %s' "$current" "$item" ;;
  esac
}

codex_session_tools() {
  local tree_pids="$1" table_file="$2" text tools=""
  text="$(commands_for_pids "$tree_pids" "$table_file")"
  [[ "$text" == *"playwright-mcp"* || "$text" == *"@playwright/mcp"* ]] &&
    tools="$(append_summary_item "$tools" 'Playwright MCP')"
  [[ "$text" == *"cua_node/bin/node_repl"* ]] &&
    tools="$(append_summary_item "$tools" 'browser control')"
  [[ "$text" == *"codex-code-mode-host"* ]] &&
    tools="$(append_summary_item "$tools" 'code-mode host')"
  [[ "$text" == *"/vite"* || "$text" == *"vite.js"* ]] &&
    tools="$(append_summary_item "$tools" 'Vite dev server')"
  [[ "$text" == *"/esbuild"* && "$text" == *"--service="* ]] &&
    tools="$(append_summary_item "$tools" 'esbuild')"
  printf '%s' "$tools"
}

codex_session_mode() {
  local tree_pids="$1" table_file="$2" text
  text="$(commands_for_pids "$tree_pids" "$table_file")"
  if [[ "$text" == *"codex app-server"* ]]; then
    printf 'app-server'
  else
    printf 'CLI'
  fi
}

describe_codex_sessions() {
  local processes="$1" table_file="$2" roots root_pid tree_pids
  local client activity status reason project tty age mode tools child_count
  local session_count=0 working_count=0 idle_count=0 uncertain_count=0 total_related=0
  roots="$(codex_session_root_pids "$processes" "$table_file")"

  printf 'Codex sessions that will be closed:\n' >&2
  while IFS= read -r root_pid; do
    [[ "$root_pid" =~ ^[0-9]+$ ]] || continue
    tree_pids="$(expand_process_tree_pids "$root_pid" "$table_file")"
    client="$(codex_session_client "$root_pid" "$table_file")"
    activity="$(codex_session_activity "$tree_pids" "$table_file")"
    status="${activity%%$'\t'*}"
    reason="${activity#*$'\t'}"
    project="$(codex_session_project "$tree_pids")"
    tty="$(process_field_for_pid "$root_pid" 3 "$table_file")"
    age="$(process_field_for_pid "$root_pid" 6 "$table_file")"
    mode="$(codex_session_mode "$tree_pids" "$table_file")"
    tools="$(codex_session_tools "$tree_pids" "$table_file")"
    child_count="$(printf '%s\n' "$tree_pids" | awk 'NF { count++ } END { print (count > 0 ? count-1 : 0) }')"

    printf '  %-7s %s\n' "$status" "$client" >&2
    printf '          PID %s · %s' "$root_pid" "$mode" >&2
    [[ -n "$tty" && "$tty" != "??" && "$tty" != "?" ]] && printf ' · %s' "$tty" >&2
    [[ -n "$age" ]] && printf ' · age %s' "$age" >&2
    [[ "$child_count" -gt 0 ]] && printf ' · %s related process(es)' "$child_count" >&2
    printf '\n' >&2
    [[ -n "$project" ]] && printf '          Project: %s\n' "$(compact_path "$project")" >&2
    printf '          State: %s\n' "$reason" >&2
    [[ -n "$tools" ]] && printf '          Tools: %s\n' "$tools" >&2

    session_count=$((session_count + 1))
    total_related=$((total_related + child_count))
    case "$status" in
      WORKING) working_count=$((working_count + 1)) ;;
      IDLE) idle_count=$((idle_count + 1)) ;;
      *) uncertain_count=$((uncertain_count + 1)) ;;
    esac
  done <<<"$roots"

  printf '%s session(s): %s working, %s idle' "$session_count" "$working_count" "$idle_count" >&2
  [[ "$uncertain_count" -gt 0 ]] && printf ', %s best-effort' "$uncertain_count" >&2
  printf '. %s related process(es) will close with them.\n' "$total_related" >&2
  printf 'State comes from Codex turn events when available; IDLE? is a best-effort fallback.\n' >&2
}

warn_running_codex_for_switch() {
  local mode="${1:-warn}" processes table_file
  processes="$(running_codex_processes || true)"
  [[ -z "$processes" ]] && return 0

  table_file="$RUNTIME_DIR/process-table-warning-$$.txt"
  process_table >"$table_file"
  if [[ "$mode" == "confirm" ]]; then
    warn "Codex sessions are currently open. Continuing will close every session below after the account switch."
  else
    warn "Codex sessions are currently open. They will be closed after the account switch."
  fi
  describe_codex_sessions "$processes" "$table_file"
  rm -f "$table_file"

  if [[ "$mode" == "confirm" ]]; then
    confirm_switch_with_running_codex || return 1
  fi
  return 0
}

pid_alive() {
  local pid="$1"
  if [[ -n "${AIC_TEST_STILL_ALIVE_PIDS:-}" ]]; then
    case " $AIC_TEST_STILL_ALIVE_PIDS " in
      *" $pid "*) return 0 ;;
    esac
  fi
  kill -0 "$pid" 2>/dev/null
}

send_signal_to_pid() {
  local signal="$1" pid="$2"
  if [[ -n "${AIC_TEST_KILL_LOG:-}" ]]; then
    printf '%s %s\n' "$signal" "$pid" >>"$AIC_TEST_KILL_LOG"
    return 0
  fi
  kill "-$signal" "$pid" 2>/dev/null
}

force_close_codex_processes_after_switch() {
  local processes table_file roots pids pid grace command
  local session_count process_count term_count=0 kill_count=0
  processes="$(running_codex_processes || true)"
  [[ -n "$processes" ]] || return 0

  table_file="$RUNTIME_DIR/process-table-$$.txt"
  process_table >"$table_file"
  roots="$(codex_session_root_pids "$processes" "$table_file")"
  pids="$(expand_process_tree_pids "$roots" "$table_file" | reverse_pids)"
  [[ -n "$pids" ]] || {
    rm -f "$table_file"
    return 0
  }
  session_count="$(printf '%s\n' "$roots" | awk 'NF { count++ } END { print count+0 }')"
  process_count="$(printf '%s\n' "$pids" | awk 'NF { count++ } END { print count+0 }')"

  printf '%sClosing %s Codex session(s) and %s process(es) so they reload the switched account.%s\n' \
    "$YELLOW" "$session_count" "$process_count" "$RESET" >&2
  while IFS= read -r pid; do
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    if send_signal_to_pid TERM "$pid"; then
      term_count=$((term_count + 1))
    else
      warn "Could not send TERM to Codex process PID $pid. It may have already exited."
    fi
  done <<<"$pids"
  printf '  TERM sent to %s/%s process(es).\n' "$term_count" "$process_count" >&2

  grace="${AIC_KILL_GRACE_SECONDS:-1}"
  sleep "$grace" 2>/dev/null || true

  while IFS= read -r pid; do
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    if pid_alive "$pid"; then
      command="$(command_for_pid "$pid" "$table_file")"
      if send_signal_to_pid KILL "$pid"; then
        kill_count=$((kill_count + 1))
        printf '  KILL required for PID %s%s\n' "$pid" "${command:+ ($command)}" >&2
      else
        warn "Could not send KILL to Codex process PID $pid. It may have already exited."
      fi
    fi
  done <<<"$pids"
  [[ "$kill_count" -eq 0 ]] && printf '  All targeted processes accepted TERM.\n' >&2

  rm -f "$table_file"
}

confirm_switch_with_running_codex() {
  local answer
  answer="$(choose_from "Continue and force-close all Codex sessions?" "No, cancel" "Yes, switch and close")" || return 1
  [[ "$answer" == "Yes, switch and close" ]]
}
