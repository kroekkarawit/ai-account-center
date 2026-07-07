# shellcheck shell=bash
# aic module: core
# core globals, colors, foundation helpers, state + path/time helpers
# Sourced by lib/aic/_load.sh; not executed directly.

export PATH="${PATH:-/usr/bin:/bin}:$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

APP_NAME="AI Account Center"
APP_VERSION="0.16.0"
APP_REPO_URL="${AIC_REPO_URL:-https://github.com/kroekkarawit/ai-account-center}"
APP_DIR="${AIC_APP_DIR:-$HOME/.local/share/ai-account-center}"
APP_BIN_DIR="${AIC_INSTALL_DIR:-$HOME/.local/bin}"
DATA_DIR="${AIC_DATA_DIR:-$HOME/.ai-account-center}"
CODEX_HOME_DIR="${AIC_CODEX_HOME:-$HOME/.codex}"
CONFIG_FILE="$DATA_DIR/config.json"
STATE_FILE="$DATA_DIR/state.json"
CODEX_ACCOUNTS_DIR="$DATA_DIR/accounts/codex"
CLAUDE_ACCOUNTS_DIR="$DATA_DIR/accounts/claude"
MODEL_PROFILES_DIR="$DATA_DIR/model-profiles"
USAGE_DIR="$DATA_DIR/usage"
BACKUP_DIR="$DATA_DIR/backups"
RUNTIME_DIR="$DATA_DIR/runtime"
LOCK_DIR="$DATA_DIR/lock"
REFRESH_STATUS_FILE="$RUNTIME_DIR/refresh-status.json"
REFRESH_REDRAW_FILE="$RUNTIME_DIR/refresh-redraw.flag"

if [[ -t 1 ]]; then
  BOLD=$'\033[1m'
  DIM=$'\033[2m'
  RED=$'\033[31m'
  GREEN=$'\033[32m'
  YELLOW=$'\033[33m'
  BLUE=$'\033[34m'
  MAGENTA=$'\033[35m'
  CYAN=$'\033[36m'
  WHITE=$'\033[37m'
  REVERSE=$'\033[7m'
  RESET=$'\033[0m'
else
  BOLD=""
  DIM=""
  RED=""
  GREEN=""
  YELLOW=""
  BLUE=""
  MAGENTA=""
  CYAN=""
  WHITE=""
  REVERSE=""
  RESET=""
fi

die() {
  printf '%sError:%s %s\n' "$RED" "$RESET" "$*" >&2
  exit 1
}

warn() {
  printf '%sWarning:%s %s\n' "$YELLOW" "$RESET" "$*" >&2
}

info() {
  printf '%s%s%s\n' "$CYAN" "$*" "$RESET"
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

ensure_dirs() {
  mkdir -p \
    "$CODEX_ACCOUNTS_DIR" \
    "$CLAUDE_ACCOUNTS_DIR" \
    "$MODEL_PROFILES_DIR" \
    "$USAGE_DIR" \
    "$BACKUP_DIR" \
    "$RUNTIME_DIR"
  chmod 700 "$DATA_DIR" "$DATA_DIR/accounts" "$CODEX_ACCOUNTS_DIR" \
    "$CLAUDE_ACCOUNTS_DIR" "$MODEL_PROFILES_DIR" "$USAGE_DIR" "$BACKUP_DIR" \
    "$RUNTIME_DIR" 2>/dev/null || true

  if [[ ! -f "$CONFIG_FILE" ]]; then
    cat >"$CONFIG_FILE.tmp" <<'JSON'
{
  "display": {
    "timezone": "Asia/Bangkok"
  },
  "schedule": {
    "enabled": false,
    "interval_minutes": 60
  },
  "monitor": {
    "codex": {
      "enabled": true,
      "prompt": "Reply only with: 1",
      "timeout_seconds": 120
    },
    "claude": {
      "enabled": true,
      "timeout_seconds": 15,
      "probe_model": "claude-haiku-4-5-20251001"
    }
  }
}
JSON
    chmod 600 "$CONFIG_FILE.tmp"
    mv -f "$CONFIG_FILE.tmp" "$CONFIG_FILE"
  fi

  if [[ ! -f "$STATE_FILE" ]]; then
    printf '{"active_codex_account":null,"active_claude_account":null}\n' >"$STATE_FILE.tmp"
    chmod 600 "$STATE_FILE.tmp"
    mv -f "$STATE_FILE.tmp" "$STATE_FILE"
  fi
}

validate_name() {
  local name="${1:-}"
  [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]] ||
    die "Account name must use letters, numbers, dot, underscore, or dash."
}

codex_account_file() {
  printf '%s/%s.json\n' "$CODEX_ACCOUNTS_DIR" "$1"
}

claude_account_file() {
  printf '%s/%s.json\n' "$CLAUDE_ACCOUNTS_DIR" "$1"
}

usage_file() {
  printf '%s/%s-%s.json\n' "$USAGE_DIR" "$1" "$2"
}

active_codex_name() {
  jq -r '.active_codex_account // empty' "$STATE_FILE" 2>/dev/null
}

set_active_codex_name() {
  local name="$1"
  jq --arg name "$name" '.active_codex_account = $name' "$STATE_FILE" >"$STATE_FILE.tmp" ||
    die "Could not update state."
  chmod 600 "$STATE_FILE.tmp"
  mv -f "$STATE_FILE.tmp" "$STATE_FILE"
}

clear_active_codex_name() {
  jq '.active_codex_account = null' "$STATE_FILE" >"$STATE_FILE.tmp" ||
    die "Could not update state."
  chmod 600 "$STATE_FILE.tmp"
  mv -f "$STATE_FILE.tmp" "$STATE_FILE"
}

active_claude_name() {
  jq -r '.active_claude_account // empty' "$STATE_FILE" 2>/dev/null
}

set_active_claude_name() {
  local name="$1"
  jq --arg name "$name" '.active_claude_account = $name' "$STATE_FILE" >"$STATE_FILE.tmp" ||
    die "Could not update state."
  chmod 600 "$STATE_FILE.tmp"
  mv -f "$STATE_FILE.tmp" "$STATE_FILE"
}

clear_active_claude_name() {
  jq '.active_claude_account = null' "$STATE_FILE" >"$STATE_FILE.tmp" ||
    die "Could not update state."
  chmod 600 "$STATE_FILE.tmp"
  mv -f "$STATE_FILE.tmp" "$STATE_FILE"
}

with_lock() {
  local command_name="$1"
  shift

  if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    die "Another account operation is running. Remove $LOCK_DIR only if no aic process exists."
  fi
  trap 'rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT INT TERM
  "$command_name" "$@"
  local status=$?
  rmdir "$LOCK_DIR" 2>/dev/null || true
  trap - EXIT INT TERM
  return "$status"
}

iso_from_epoch() {
  local epoch="$1"
  if date -u -r "$epoch" +%Y-%m-%dT%H:%M:%SZ >/dev/null 2>&1; then
    date -u -r "$epoch" +%Y-%m-%dT%H:%M:%SZ
  else
    date -u -d "@$epoch" +%Y-%m-%dT%H:%M:%SZ
  fi
}

epoch_from_iso() {
  local iso="$1" normalized epoch
  normalized="${iso%%.*}"
  normalized="${normalized%Z}"
  normalized="${normalized%%+*}"
  if epoch="$(TZ=UTC date -j -f '%Y-%m-%dT%H:%M:%S' "$normalized" +%s 2>/dev/null)"; then
    printf '%s' "$epoch"
  else
    date -u -d "$iso" +%s 2>/dev/null
  fi
}

codex_names() {
  local file
  for file in "$CODEX_ACCOUNTS_DIR"/*.json; do
    [[ -e "$file" ]] || continue
    basename "$file" .json
  done
}

claude_names() {
  local file
  for file in "$CLAUDE_ACCOUNTS_DIR"/*.json; do
    [[ -e "$file" ]] || continue
    basename "$file" .json
  done
}

resolve_self() {
  # AIC_SELF is set by the bin/aic entrypoint to its own ${BASH_SOURCE[0]} so
  # that self-location works even though this function lives in a sourced lib.
  local source="${AIC_SELF:-${BASH_SOURCE[0]}}"
  while [[ -L "$source" ]]; do
    local dir
    dir="$(cd -P "$(dirname "$source")" && pwd)"
    source="$(readlink "$source")"
    [[ "$source" != /* ]] && source="$dir/$source"
  done
  cd -P "$(dirname "$source")" && printf '%s/%s\n' "$PWD" "$(basename "$source")"
}

