# shellcheck shell=bash
# aic module: codex-process
# Codex process detection and force-close on account switch
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

process_table() {
  ps -axo pid=,ppid=,command= 2>/dev/null | awk '{$1=$1; print}'
}

vscode_codex_app_server_processes() {
  awk '/\/\.vscode\/extensions\/openai[.]chatgpt-.*\/codex app-server/ || /openai[.]chatgpt-.*codex app-server/'
}

non_vscode_codex_processes() {
  awk '!(/\/\.vscode\/extensions\/openai[.]chatgpt-.*\/codex app-server/ || /openai[.]chatgpt-.*codex app-server/)'
}

warn_running_codex_for_switch() {
  local mode="${1:-warn}" processes vscode_processes other_processes
  processes="$(running_codex_processes || true)"
  [[ -z "$processes" ]] && return 0

  vscode_processes="$(printf '%s\n' "$processes" | vscode_codex_app_server_processes || true)"
  other_processes="$(printf '%s\n' "$processes" | non_vscode_codex_processes || true)"

  if [[ "$mode" == "confirm" ]]; then
    if [[ -n "$vscode_processes" ]]; then
      warn "VS Code Codex app-server is running. If you continue, VS Code Codex will be force-restarted after the account switch."
      printf '%s\n' "$vscode_processes" >&2
    fi
    if [[ -n "$other_processes" ]]; then
      warn "Codex CLI is currently running. If you continue, these Codex sessions will be force-closed after the account switch."
      printf '%s\n' "$other_processes" >&2
    fi
    confirm_switch_with_running_codex || return 1
  else
    if [[ -n "$vscode_processes" ]]; then
      warn "VS Code Codex app-server is running. It will be force-restarted after the account switch."
      printf '%s\n' "$vscode_processes" >&2
    fi
    if [[ -n "$other_processes" ]]; then
      warn "Codex CLI is currently running. It will be force-closed after the account switch."
      printf '%s\n' "$other_processes" >&2
    fi
  fi
  return 0
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

reverse_pids() {
  awk 'NF { lines[++count]=$1 } END { for (i=count; i>=1; i--) print lines[i] }'
}

command_for_pid() {
  local pid="$1" table_file="$2"
  awk -v target="$pid" '$1 == target { $1=""; $2=""; sub(/^  */, ""); print; exit }' "$table_file"
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
  local roots table_file pids pid command grace
  roots="$(running_codex_processes || true)"
  [[ -n "$roots" ]] || return 0

  table_file="$RUNTIME_DIR/process-table-$$.txt"
  process_table >"$table_file"
  pids="$(expand_process_tree_pids "$roots" "$table_file" | reverse_pids)"
  [[ -n "$pids" ]] || {
    rm -f "$table_file"
    return 0
  }

  printf '%sForce-closing Codex processes so new sessions reload the switched account.%s\n' "$YELLOW" "$RESET" >&2
  while IFS= read -r pid; do
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    command="$(command_for_pid "$pid" "$table_file")"
    send_signal_to_pid TERM "$pid" &&
      printf 'TERM: %s%s\n' "$pid" "${command:+ $command}" >&2 ||
      warn "Could not send TERM to Codex process PID $pid. It may have already exited."
  done <<<"$pids"

  grace="${AIC_KILL_GRACE_SECONDS:-1}"
  sleep "$grace" 2>/dev/null || true

  while IFS= read -r pid; do
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    if pid_alive "$pid"; then
      command="$(command_for_pid "$pid" "$table_file")"
      send_signal_to_pid KILL "$pid" &&
        printf 'KILL: %s%s\n' "$pid" "${command:+ $command}" >&2 ||
        warn "Could not send KILL to Codex process PID $pid. It may have already exited."
    fi
  done <<<"$pids"

  rm -f "$table_file"
}

confirm_switch_with_running_codex() {
  local answer
  answer="$(choose_from "Continue and force-close all Codex sessions?" "No, cancel" "Yes, switch and close")" || return 1
  [[ "$answer" == "Yes, switch and close" ]]
}

