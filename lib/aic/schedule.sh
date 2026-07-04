# shellcheck shell=bash
# aic module: schedule
# Scheduled refresh config + launchd/systemd installation
# Sourced by lib/aic/_load.sh; not executed directly.

set_schedule_interval() {
  local raw="$1" minutes
  case "$raw" in
    *m)
      minutes="${raw%m}"
      [[ "$minutes" =~ ^[0-9]+$ ]] ||
        die "Use an interval such as 15m, 30m, 1h, or 2h."
      ;;
    *h)
      local hours="${raw%h}"
      [[ "$hours" =~ ^[0-9]+$ ]] ||
        die "Use an interval such as 15m, 30m, 1h, or 2h."
      minutes=$((hours * 60))
      ;;
    *)
      minutes="$raw"
      ;;
  esac
  [[ "$minutes" =~ ^[0-9]+$ ]] || die "Use an interval such as 15m, 30m, 1h, or 2h."
  ((minutes >= 5 && minutes <= 10080)) || die "Interval must be between 5 minutes and 7 days."

  jq --argjson minutes "$minutes" \
    '.schedule.enabled = true | .schedule.interval_minutes = $minutes' \
    "$CONFIG_FILE" >"$CONFIG_FILE.tmp" || die "Could not update config."
  chmod 600 "$CONFIG_FILE.tmp"
  mv -f "$CONFIG_FILE.tmp" "$CONFIG_FILE"
  printf 'Monitor interval: %s minutes\n' "$minutes"
  install_scheduler
}

disable_schedule() {
  jq '.schedule.enabled = false' "$CONFIG_FILE" >"$CONFIG_FILE.tmp" ||
    die "Could not update config."
  chmod 600 "$CONFIG_FILE.tmp"
  mv -f "$CONFIG_FILE.tmp" "$CONFIG_FILE"
  uninstall_scheduler
  printf 'Background monitor disabled.\n'
}

install_launchd() {
  local interval_seconds plist script_path log_dir
  interval_seconds=$(( $(jq -r '.schedule.interval_minutes' "$CONFIG_FILE") * 60 ))
  plist="$HOME/Library/LaunchAgents/com.local.ai-account-center.plist"
  script_path="$(resolve_self)"
  log_dir="$DATA_DIR/logs"
  mkdir -p "$HOME/Library/LaunchAgents" "$log_dir"

  cat >"$plist.tmp" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.local.ai-account-center</string>
  <key>ProgramArguments</key>
  <array>
    <string>$script_path</string>
    <string>refresh</string>
    <string>--scheduled</string>
  </array>
  <key>StartInterval</key>
  <integer>$interval_seconds</integer>
  <key>RunAtLoad</key>
  <true/>
  <key>StandardOutPath</key>
  <string>$log_dir/scheduler.log</string>
  <key>StandardErrorPath</key>
  <string>$log_dir/scheduler-error.log</string>
</dict>
</plist>
PLIST
  mv -f "$plist.tmp" "$plist"
  launchctl bootout "gui/$(id -u)" "$plist" >/dev/null 2>&1 || true
  launchctl bootstrap "gui/$(id -u)" "$plist" >/dev/null 2>&1 ||
    warn "launchd could not load the scheduler. Try: launchctl bootstrap gui/$(id -u) '$plist'"
  printf 'Installed launchd scheduler: %s\n' "$plist"
}

uninstall_launchd() {
  local plist="$HOME/Library/LaunchAgents/com.local.ai-account-center.plist"
  if [[ -f "$plist" ]]; then
    launchctl bootout "gui/$(id -u)" "$plist" >/dev/null 2>&1 || true
    rm -f "$plist"
  fi
}

install_systemd() {
  local minutes script_path unit_dir
  minutes="$(jq -r '.schedule.interval_minutes' "$CONFIG_FILE")"
  script_path="$(resolve_self)"
  unit_dir="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
  mkdir -p "$unit_dir"

  cat >"$unit_dir/ai-account-center.service" <<UNIT
[Unit]
Description=Refresh AI account usage

[Service]
Type=oneshot
ExecStart=$script_path refresh --scheduled
UNIT

  cat >"$unit_dir/ai-account-center.timer" <<UNIT
[Unit]
Description=Refresh AI account usage every $minutes minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=${minutes}min
Persistent=true

[Install]
WantedBy=timers.target
UNIT
  systemctl --user daemon-reload
  systemctl --user enable --now ai-account-center.timer
  printf 'Installed systemd user timer.\n'
}

uninstall_systemd() {
  local unit_dir="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
  systemctl --user disable --now ai-account-center.timer >/dev/null 2>&1 || true
  rm -f "$unit_dir/ai-account-center.service" "$unit_dir/ai-account-center.timer"
  systemctl --user daemon-reload >/dev/null 2>&1 || true
}

install_scheduler() {
  case "$(uname -s)" in
    Darwin) install_launchd ;;
    Linux)
      command -v systemctl >/dev/null 2>&1 ||
        die "systemd is not available. Use cron to run: $(resolve_self) refresh --scheduled"
      install_systemd
      ;;
    *) die "Automatic scheduler installation supports macOS and systemd Linux." ;;
  esac
}

uninstall_scheduler() {
  case "$(uname -s)" in
    Darwin) uninstall_launchd ;;
    Linux) uninstall_systemd ;;
  esac
}

