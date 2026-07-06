# shellcheck shell=bash
# aic module: ui
# TUI primitives (choose_from, menus), dashboard/status rendering, help, settings
# Sourced by lib/aic/_load.sh; not executed directly.

supports_utf8() {
  case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
    *UTF-8*|*utf8*|*UTF8*) return 0 ;;
    *) return 1 ;;
  esac
}

menu_icon() {
  local name="$1"
  if supports_utf8; then
    case "$name" in
      codex-switch) printf '◆' ;;
      codex-open) printf '▶' ;;
      codex-login) printf '◎' ;;
      codex-add) printf '＋' ;;
      codex-import) printf '⇢' ;;
      add-codex) printf '＋' ;;
      add-claude) printf '◈' ;;
      claude-switch) printf '◆' ;;
      model-launch) printf '◉' ;;
      claude-login) printf '◇' ;;
      claude-import) printf '⇠' ;;
      claude-token) printf '◈' ;;
      manage) printf '✎' ;;
      transfer) printf '⇄' ;;
      export) printf '⇪' ;;
      import) printf '⇩' ;;
      refresh) printf '↻' ;;
      schedule) printf '⏱' ;;
      remove) printf '×' ;;
      list) printf '☷' ;;
      help) printf '?' ;;
      exit) printf '⌫' ;;
      *) printf '•' ;;
    esac
  else
    case "$name" in
      codex-switch) printf 'C>' ;;
      codex-open) printf 'C$' ;;
      codex-login) printf 'C@' ;;
      codex-add) printf 'C+' ;;
      codex-import) printf 'C<' ;;
      add-codex) printf 'C+' ;;
      add-claude) printf 'A+' ;;
      claude-switch) printf 'A>' ;;
      model-launch) printf 'M>' ;;
      claude-login) printf 'A@' ;;
      claude-import) printf 'A<' ;;
      claude-token) printf 'A#' ;;
      manage) printf 'M~' ;;
      transfer) printf 'IO' ;;
      export) printf 'E>' ;;
      import) printf 'I<' ;;
      refresh) printf 'R*' ;;
      schedule) printf 'T~' ;;
      remove) printf 'X-' ;;
      list) printf 'L=' ;;
      help) printf '??' ;;
      exit) printf 'Q!' ;;
      *) printf '--' ;;
    esac
  fi
}

menu_item() {
  local icon="$1" text="$2" action="$3"
  printf '%s  %s::%s' "$(menu_icon "$icon")" "$text" "$action"
}

manage_account_menu() {
  local options=() item provider name
  while IFS= read -r name; do
    [[ -n "$name" ]] && options+=("Codex  | $name")
  done < <(codex_names)
  while IFS= read -r name; do
    [[ -n "$name" ]] && options+=("Claude | $name")
  done < <(claude_names)

  [[ "${#options[@]}" -gt 0 ]] || { warn "No accounts found."; return 1; }

  item="$(choose_from "Select account to manage" "${options[@]}")" || return 1
  provider="${item%%|*}"
  provider="${provider// /}"
  name="${item#*| }"
  name="${name## }"

  local sub_options=()
  if [[ "$provider" == "Codex" ]]; then
    sub_options=(
      "◆  Switch to this account::switch"
      "↻  Refresh this account::refresh"
      "✎  Rename::rename"
      "◎  Re-login with browser::relogin"
      "⇢  Re-import auth.json::reimport"
      "×  Remove::remove"
    )
  elif [[ "$(claude_account_kind "$name")" == "oauth" ]]; then
    sub_options=(
      "◆  Switch to this account (global)::switch"
      "↻  Refresh this account::refresh"
      "✎  Rename::rename"
      "◇  Re-login OAuth::relogin"
      "×  Remove::remove"
    )
  else
    sub_options=(
      "▶  Open with model (launch this session)::launch-token"
      "↻  Refresh this account::refresh"
      "✎  Rename::rename"
      "◈  Update setup-token::update-token"
      "×  Remove::remove"
    )
  fi

  local sub_action new_name
  sub_action="$(choose_from "Manage $provider: $name" "${sub_options[@]}")" || return 1
  sub_action="${sub_action##*::}"

  case "$sub_action" in
    switch)
      if [[ "$provider" == "Codex" ]]; then
        with_lock switch_codex_impl "$name" confirm
      else
        switch_claude_impl "$name" confirm
      fi
      ;;
    refresh)
      if [[ "$provider" == "Codex" ]]; then
        refresh_codex_account "$name"
      else
        refresh_claude_account "$name"
      fi
      ;;
    rename)
      printf 'New name: '
      IFS= read -r new_name
      [[ -n "$new_name" ]] || return 0
      if [[ "$provider" == "Codex" ]]; then
        with_lock rename_codex_account "$name" "$new_name"
      else
        rename_claude_account "$name" "$new_name"
      fi
      ;;
    relogin)
      if [[ "$provider" == "Codex" ]]; then
        with_lock relogin_codex_browser "$name"
      else
        with_lock relogin_claude_oauth "$name"
      fi
      ;;
    reimport)
      with_lock reimport_codex_auth_json "$name"
      ;;
    update-token)
      add_claude_token "$name"
      ;;
    launch-token)
      launch_claude_with_token "$name"
      ;;
    remove)
      local answer
      answer="$(choose_from "Remove $provider account '$name'?" "No, cancel" "Yes, remove it")" || return 1
      if [[ "$answer" == "Yes, remove it" ]]; then
        if [[ "$provider" == "Codex" ]]; then
          with_lock remove_codex_impl "$name"
        else
          remove_claude "$name"
        fi
      fi
      ;;
  esac
}

print_dashboard_header() {
  local active schedule_text title_line state_line timezone
  active="$(active_codex_name)"
  timezone="$(jq -r '.display.timezone // "Asia/Bangkok"' "$CONFIG_FILE")"
  schedule_text="$(next_refresh_countdown)"

  title_line="AI ACCOUNT CENTER  v$APP_VERSION"
  state_line="Active Codex: ${active:-none}  |  Next refresh: $schedule_text  |  TZ: $timezone"
  printf '%s+------------------------------------------------------------------------------+%s\n' "$CYAN" "$RESET"
  printf '%s|%s %s%-76s%s %s|%s\n' \
    "$CYAN" "$RESET" "$BOLD" "$title_line" "$RESET" "$CYAN" "$RESET"
  printf '%s|%s %-76s %s|%s\n' \
    "$CYAN" "$RESET" "$state_line" "$CYAN" "$RESET"
  printf '%s+------------------------------------------------------------------------------+%s\n' "$CYAN" "$RESET"
}

print_status() {
  local active_codex active_claude active_name
  active_codex="$(active_codex_name)"
  active_claude="$(active_claude_name)"
  local errors=()
  printf '%s%-9s %-19s %-29s %-38s%s\n' \
    "$BOLD" "PROVIDER" "ACCOUNT" "5-HOUR LIMIT" "7-DAY LIMIT" "$RESET"
  printf '%s%-9s %-19s %-29s %-38s%s\n' \
    "$DIM" "--------" "------------------" "----------------------------" "-------------------------------------" "$RESET"

  local provider provider_label provider_color dir file name usage marker status five week reset5 resetw
  for provider in codex claude; do
    provider_label="$(uppercase "$provider")"
    if [[ "$provider" == "codex" ]]; then
      dir="$CODEX_ACCOUNTS_DIR"
      provider_color="$CYAN"
      active_name="$active_codex"
    else
      dir="$CLAUDE_ACCOUNTS_DIR"
      provider_color="$MAGENTA"
      active_name="$active_claude"
    fi

    for file in "$dir"/*.json; do
      [[ -e "$file" ]] || continue
      name="$(basename "$file" .json)"
      usage="$(usage_file "$provider" "$name")"
      marker=" "
      [[ -n "$active_name" && "$active_name" == "$name" ]] && marker=">"

      if [[ ! -f "$usage" ]]; then
        printf '%s%-9s%s %s%-18s ' "$provider_color" "$provider_label" "$RESET" "$marker" "$name"
        printf '%s%-29s %-38s%s\n' \
          "$DIM" "[5h ░░░░░░░░░░  -- → -]" "[7d ░░░░░░░░░░  -- → -]" "$RESET"
        continue
      fi

      status="$(jq -r '.status // "error"' "$usage")"
      if [[ "$status" != "ok" ]]; then
        local full_error
        full_error="$(jq -r '.error // "unknown"' "$usage")"
        errors+=("$provider/$name: $full_error")
        printf '%s%-9s%s %s%-18s %s%-29s %-38s%s\n' \
          "$provider_color" "$provider_label" "$RESET" "$marker" "$name" \
          "$RED" "[5h !!!!!!!!!! ERR → -]" "[7d !!!!!!!!!! ERR → see errors]" "$RESET"
        continue
      fi

      five="$(jq -r '.limits.five_hour.used_percent // "-"' "$usage")"
      week="$(jq -r '.limits.weekly.used_percent // "-"' "$usage")"
      reset5="$(format_reset "$usage" five_hour time)"
      resetw="$(format_reset "$usage" weekly datetime)"
      printf '%s%-9s%s %s%-18s ' "$provider_color" "$provider_label" "$RESET" "$marker" "$name"
      format_quota_badge "5h" "$five" "$reset5"
      printf ' '
      format_quota_badge "7d" "$week" "$resetw"
      printf '\n'
    done
  done

  if [[ "${#errors[@]}" -gt 0 ]]; then
    printf '\n%s%s[!] ERRORS%s\n' "$BOLD" "$RED" "$RESET"
    local error
    for error in "${errors[@]}"; do
      printf '  %s!%s %s\n' "$RED" "$RESET" "$error"
    done
  fi
}

choose_from() {
  local prompt="$1"
  shift
  local options=("$@")
  [[ "${#options[@]}" -gt 0 ]] || return 1

  local selected=0 key rest i lines
  lines=$((${#options[@]} + 3))
  if [[ -t 0 ]]; then
    exec 3<&0
  elif [[ -r /dev/tty ]]; then
    { exec 3</dev/tty; } 2>/dev/null || return 1
  else
    return 1
  fi

  option_label() {
    local value="$1"
    printf '%s' "${value%%::*}"
  }

  local show_numbers=0
  ((${#options[@]} >= 2)) && show_numbers=1
  local max_shortcut=9
  ((${#options[@]} < max_shortcut)) && max_shortcut="${#options[@]}"

  local rendered=0
  while true; do
    if ((rendered == 0)); then
      printf '%s%s%s\n' "$BOLD" "$prompt" "$RESET" >&2
      if ((show_numbers)); then
        printf '%s  Up/Down or j/k, Enter to confirm, 1-%d to jump+confirm, Esc/q cancel%s\n' \
          "$DIM" "$max_shortcut" "$RESET" >&2
      else
        printf '%s  Use Up/Down or j/k, Enter to select, Esc/q to cancel%s\n' "$DIM" "$RESET" >&2
      fi
      for ((i = 0; i < ${#options[@]}; i++)); do
        local label
        label="$(option_label "${options[$i]}")"
        local num_prefix
        ((show_numbers && i < 9)) && num_prefix="$((i+1)) " || num_prefix="   "
        if ((i == selected)); then
          printf ' %s%s%s> %-44s%s\n' "$DIM" "$num_prefix" "$RESET$CYAN$REVERSE" "$label" "$RESET" >&2
        else
          printf ' %s%s%s  %-44s%s\n' "$DIM" "$num_prefix" "$RESET" "$label" "$RESET" >&2
        fi
      done
      printf '\n' >&2
      rendered=1
    fi

    if [[ "${AIC_REDRAW_ON_REFRESH_DONE:-}" == "1" ]]; then
      IFS= read -r -s -n 1 -t 1 key <&3 || {
        if [[ -f "$REFRESH_REDRAW_FILE" ]]; then
          rm -f "$REFRESH_REDRAW_FILE"
          printf '\033[%dA\033[J' "$lines" >&2
          exec 3<&-
          printf '%s\n' "__AIC_REDRAW__"
          return 0
        fi
        continue
      }
    else
      IFS= read -r -s -n 1 key <&3 || {
        exec 3<&-
        return 1
      }
    fi
    if [[ "$key" == $'\033' ]]; then
      rest=""
      IFS= read -r -s -n 2 -t 1 rest <&3 || true
      key+="$rest"
    fi

    printf '\033[%dA\033[J' "$lines" >&2
    rendered=0
    case "$key" in
      $'\033[A'|k|K)
        selected=$(((selected - 1 + ${#options[@]}) % ${#options[@]}))
        ;;
      $'\033[B'|j|J)
        selected=$(((selected + 1) % ${#options[@]}))
        ;;
      ""|$'\n'|$'\r')
        exec 3<&-
        printf '%s\n' "${options[$selected]}"
        return 0
        ;;
      q|Q|$'\033')
        exec 3<&-
        return 1
        ;;
      [1-9])
        if ((show_numbers && key <= ${#options[@]} && key <= 9)); then
          exec 3<&-
          printf '%s\n' "${options[$((key - 1))]}"
          return 0
        fi
        ;;
    esac
  done
}

# Multi-select checkbox picker. Prints the ::value of each checked option, one
# per line. Space toggles, 'a' toggles all, Enter confirms, Esc/q cancels.
choose_multi() {
  local prompt="$1"
  shift
  local options=("$@")
  [[ "${#options[@]}" -gt 0 ]] || return 1

  local selected=() i cursor=0 key rest lines box label anyoff
  for ((i = 0; i < ${#options[@]}; i++)); do selected[i]=0; done
  lines=$((${#options[@]} + 3))

  if [[ -t 0 ]]; then
    exec 3<&0
  elif [[ -r /dev/tty ]]; then
    { exec 3</dev/tty; } 2>/dev/null || return 1
  else
    return 1
  fi

  local rendered=0
  while true; do
    if ((rendered == 0)); then
      printf '%s%s%s\n' "$BOLD" "$prompt" "$RESET" >&2
      printf '%s  Up/Down or j/k · Space toggle · a all · Enter confirm · Esc/q cancel%s\n' \
        "$DIM" "$RESET" >&2
      for ((i = 0; i < ${#options[@]}; i++)); do
        label="${options[$i]%%::*}"
        ((selected[i])) && box="[x]" || box="[ ]"
        if ((i == cursor)); then
          printf ' %s%s %-42s%s\n' "$REVERSE$CYAN" "$box" "$label" "$RESET" >&2
        else
          printf ' %s %-42s\n' "$box" "$label" >&2
        fi
      done
      printf '\n' >&2
      rendered=1
    fi

    IFS= read -r -s -n 1 key <&3 || {
      exec 3<&-
      return 1
    }
    if [[ "$key" == $'\033' ]]; then
      rest=""
      IFS= read -r -s -n 2 -t 1 rest <&3 || true
      key+="$rest"
    fi

    printf '\033[%dA\033[J' "$lines" >&2
    rendered=0
    case "$key" in
      $'\033[A'|k|K) cursor=$(((cursor - 1 + ${#options[@]}) % ${#options[@]})) ;;
      $'\033[B'|j|J) cursor=$(((cursor + 1) % ${#options[@]})) ;;
      ' ') ((selected[cursor] = !selected[cursor])) ;;
      a|A)
        anyoff=0
        for ((i = 0; i < ${#options[@]}; i++)); do ((selected[i])) || anyoff=1; done
        for ((i = 0; i < ${#options[@]}; i++)); do selected[i]=$anyoff; done
        ;;
      ""|$'\n'|$'\r')
        exec 3<&-
        for ((i = 0; i < ${#options[@]}; i++)); do
          ((selected[i])) && printf '%s\n' "${options[$i]##*::}"
        done
        return 0
        ;;
      q|Q|$'\033')
        exec 3<&-
        return 1
        ;;
    esac
  done
}

confirm_action() {
  local prompt="$1" answer
  answer="$(choose_from "$prompt" "No, cancel" "Yes, remove it")" || return 1
  [[ "$answer" == "Yes, remove it" ]]
}

interactive_remove() {
  local options=() item provider name
  while IFS= read -r name; do
    [[ -n "$name" ]] && options+=("Codex  | $name")
  done < <(codex_names)
  while IFS= read -r name; do
    [[ -n "$name" ]] && options+=("Claude | $name")
  done < <(claude_names)

  [[ "${#options[@]}" -gt 0 ]] || {
    warn "No accounts to remove."
    return 1
  }

  item="$(choose_from "Select account to remove" "${options[@]}")" || return 1
  provider="${item%%|*}"
  provider="${provider// /}"
  name="${item#*| }"

  confirm_action "Remove $provider account '$name'?" || return 1
  if [[ "$provider" == "Codex" ]]; then
    with_lock remove_codex_impl "$name"
  else
    remove_claude "$name"
  fi
}

help_content_en() {
  cat <<HELP
AI ACCOUNT CENTER - USER GUIDE

OVERVIEW
AI Account Center stores multiple Codex account credentials, switches the
active Codex CLI account, and monitors Codex and Claude subscription limits.
All account data is stored locally under ~/.ai-account-center.

KEYBOARD CONTROLS
Up / Down       Move through menus or scroll this guide
j / k           Alternative navigation keys
PageUp/PageDown Scroll one page
Home / End      Jump to the beginning or end
Enter           Select the highlighted menu item
Esc / q         Cancel or close the current screen

DASHBOARD
The > marker identifies the active Codex account stored by Account Center.
The percentage in each badge is usage consumed, not quota remaining.

  [5h ██░░░░░░░░  22% -> 18:49]
  [7d █████████░  94% -> Jun 16, 16:50]

Green means low usage, yellow means at least 70% used, and red means at least
90% used. Reset times use Asia/Bangkok unless changed in config.json.

ADD A CODEX ACCOUNT
Choose "Add account -> Codex", then one of:
  Login with browser    - opens Codex OAuth in a temporary CODEX_HOME
  Save current session  - saves the current ~/.codex/auth.json
  Import from file or paste - paste the JSON, a file path, or the clipboard
Enter a short name such as personal or company. To bring an account from
another computer, copy its auth.json over and use "Import from file or paste".

SWITCH CODEX
Choose "Switch account -> Codex account", pick one, and press Enter; Account
Center atomically replaces ~/.codex/auth.json. To run Codex with the active
account afterward, just run `codex` in your terminal.

Do not switch accounts while another Codex CLI process is still running.

ACCOUNTS vs SETUP-TOKENS  (Claude)
  Account (OAuth login)  - has a refresh token; switches GLOBALLY (written to
                           the keychain, so every terminal + VS Code + extension
                           uses it). Add under "Add account -> Claude".
  Setup-token            - a session credential like an API key. Full Claude
                           (Opus/Sonnet, subagents, all tools) but only for the
                           session you launch with it; other clients are
                           untouched. Add/run under "Open with model -> Claude".

ADD A CLAUDE ACCOUNT (global switch)
Choose "Add account -> Claude":
  Login with OAuth      - normal Claude subscription OAuth
  Import current login  - import an existing Claude Code login
Both capture the refresh token, so the account switches across all clients.

OPEN WITH MODEL  (per-session)
"Open with model -> Codex / Claude" launches the CLI for one session against a
chosen credential. For Claude this lists your setup-tokens (launched via
CLAUDE_CODE_OAUTH_TOKEN) and any alternate-provider model profiles (DeepSeek /
custom). Add a setup-token with "+ Add Claude setup-token"; get one by running
`claude setup-token` in another terminal (shown once as `sk-ant-oat01-...`).

MONITORING
"Refresh all usage" updates every stored account, including setup-tokens.
Codex usage is read from account/rateLimits/read without an inference prompt.
Claude full OAuth uses its usage endpoint. An inference-only setup-token uses a
one-output-token Haiku request and reads utilization from response headers.

BACKGROUND SCHEDULE
Open "Settings" and set a schedule interval (15m, 30m, 1h, 2h, 4h, 6h) or turn
it off. macOS uses launchd, so the terminal does not need to stay open. The
computer must be awake and connected to the internet when the refresh runs.

MANAGE OR REMOVE AN ACCOUNT
"Manage accounts" lets you switch, refresh, rename, re-login, re-import, or
remove a single account. Removing an active Codex profile does not delete the
live ~/.codex/auth.json and does not log the account out; it only removes
Account Center's saved copy.

DIAGNOSTICS
Help -> Diagnostics prints environment, command paths, token expiry, and a
live rate-limit check for troubleshooting.

COMMAND LINE (for scripts and the background scheduler)
aic                 open this menu
aic status          print cached usage for all accounts
aic refresh         refresh all accounts (or: aic refresh codex NAME)
aic update          update from GitHub
aic uninstall       remove the install (keeps account data)
Everything else - switching, adding, model launch, schedule, remove - is here
in the menu.

FILES
Source code: $APP_DIR
Private data: ~/.ai-account-center
Live Codex credential: ~/.codex/auth.json
HELP
}

help_content_th() {
  cat <<HELP
AI ACCOUNT CENTER - คู่มือการใช้งาน

ภาพรวม
AI Account Center ใช้เก็บบัญชี Codex หลายบัญชี สลับบัญชีที่ Codex CLI ใช้งาน
และตรวจสอบ limit ของ Codex กับ Claude ในที่เดียว ข้อมูลบัญชีทั้งหมดเก็บไว้ใน
เครื่องที่ ~/.ai-account-center

ปุ่มควบคุม
ขึ้น / ลง         เลื่อนเมนูหรือเลื่อนอ่านคู่มือ
j / k             ปุ่มสำรองสำหรับเลื่อน
PageUp/PageDown   เลื่อนครั้งละหนึ่งหน้า
Home / End        ไปต้นเอกสารหรือท้ายเอกสาร
Enter             เลือกรายการที่ highlight
Esc / q           ยกเลิกหรือปิดหน้าปัจจุบัน

หน้า DASHBOARD
เครื่องหมาย > แสดงบัญชี Codex ที่ active อยู่ใน Account Center
เปอร์เซ็นต์ใน badge คือจำนวนที่ใช้ไปแล้ว ไม่ใช่จำนวนที่เหลือ

  [5h ██░░░░░░░░  22% -> 18:49]
  [7d █████████░  94% -> Jun 16, 16:50]

สีเขียวหมายถึงใช้ไม่มาก สีเหลืองหมายถึงใช้ตั้งแต่ 70% และสีแดงหมายถึงใช้
ตั้งแต่ 90% เวลา reset แสดงเป็น Asia/Bangkok เว้นแต่แก้ใน config.json

เพิ่มบัญชี CODEX
เลือก "Add account -> Codex" แล้วเลือกอย่างใดอย่างหนึ่ง:
  Login with browser        - เปิด Codex OAuth ใน CODEX_HOME ชั่วคราว
  Save current session      - บันทึก ~/.codex/auth.json ปัจจุบัน
  Import from file or paste - แปะ JSON, ใส่ path ไฟล์ หรือใช้ clipboard
ตั้งชื่อสั้น ๆ เช่น personal หรือ company ถ้าจะย้ายบัญชีจากอีกเครื่อง ให้ copy
ไฟล์ auth.json มา แล้วใช้ "Import from file or paste"

สลับ CODEX
เลือก "Switch account -> Codex account" เลือกบัญชีแล้วกด Enter ระบบจะเปลี่ยน
~/.codex/auth.json แบบ atomic จะเปิด Codex ด้วยบัญชีที่ active ก็รันคำสั่ง `codex`
ได้เลย

อย่าสลับบัญชีขณะที่ยังมี Codex CLI process อื่นกำลังทำงานอยู่

บัญชี vs SETUP-TOKEN  (Claude)
  บัญชี (OAuth login) - มี refresh token สลับได้ระดับ GLOBAL (เขียนลง keychain
                        ทุก terminal + VS Code + extension จะใช้บัญชีนี้)
                        เพิ่มที่ "Add account -> Claude"
  Setup-token         - เป็น session credential เหมือน API key ใช้ Claude ได้เต็ม
                        (Opus/Sonnet, subagent, ทุก tool) แต่เฉพาะ session ที่เปิด
                        เท่านั้น client อื่นไม่กระทบ เพิ่ม/เปิดที่
                        "Open with model -> Claude"

เพิ่มบัญชี CLAUDE (สลับระดับ global)
เลือก "Add account -> Claude":
  Login with OAuth      - Claude subscription OAuth ตามปกติ
  Import current login  - ใช้ login ที่ Claude Code มีอยู่แล้ว
ทั้งสองเก็บ refresh token บัญชีจึงสลับได้ทุก client

เปิดด้วย MODEL / SETUP-TOKEN  (เฉพาะ session)
"Open with model -> Codex / Claude" เปิด CLI หนึ่ง session ด้วย credential ที่เลือก
ฝั่ง Claude จะลิสต์ setup-token (เปิดผ่าน CLAUDE_CODE_OAUTH_TOKEN) และ model profile
ของ provider อื่น (DeepSeek/custom) เพิ่ม setup-token ด้วย "+ Add Claude setup-token"
ขอ token โดยรัน `claude setup-token` (แสดงครั้งเดียวเป็น `sk-ant-oat01-...`)

การ MONITOR
"Refresh all usage" อัปเดตข้อมูลทุกบัญชี รวมถึง setup-token
Codex อ่าน account/rateLimits/read โดยไม่ยิง inference prompt
Claude full OAuth ใช้ usage endpoint ส่วน setup-token จะยิง Haiku ที่ output
หนึ่ง token แล้วอ่าน utilization จาก response headers

ตั้งเวลา BACKGROUND
เปิด "Settings" แล้วตั้งช่วงเวลา (15m, 30m, 1h, 2h, 4h, 6h) หรือปิด
บน macOS ระบบใช้ launchd จึงไม่ต้องเปิด Terminal ค้างไว้ แต่เครื่องต้องตื่น
และเชื่อมต่ออินเทอร์เน็ตตอนถึงเวลาที่กำหนด

จัดการหรือลบบัญชี
"Manage accounts" ให้สลับ, refresh, เปลี่ยนชื่อ, re-login, re-import หรือลบ
บัญชีทีละบัญชี ถ้าลบ Codex account ที่ active ระบบจะไม่ลบ ~/.codex/auth.json
และไม่ logout แต่จะลบเฉพาะสำเนาที่ Account Center เก็บไว้

DIAGNOSTICS
Help -> Diagnostics แสดงข้อมูล environment, path ของคำสั่ง, วันหมดอายุ token
และตรวจ rate-limit สด ๆ สำหรับแก้ปัญหา

คำสั่ง CLI (สำหรับสคริปต์และตัวตั้งเวลาเบื้องหลัง)
aic                 เปิดเมนูนี้
aic status          แสดง usage ที่ cache ไว้ของทุกบัญชี
aic refresh         refresh ทุกบัญชี (หรือ: aic refresh codex NAME)
aic update          อัปเดตจาก GitHub
aic uninstall       ถอนการติดตั้ง (ยังเก็บข้อมูลบัญชีไว้)
ส่วนอื่น ๆ ทั้งหมด - สลับ, เพิ่ม, เปิดด้วย model, ตั้งเวลา, ลบ - อยู่ในเมนูนี้

ตำแหน่งไฟล์
Source code: $APP_DIR
ข้อมูลส่วนตัว: ~/.ai-account-center
Credential ที่ Codex ใช้อยู่: ~/.codex/auth.json
HELP
}

terminal_height() {
  local height
  height="$(tput lines 2>/dev/null || true)"
  [[ "$height" =~ ^[0-9]+$ && "$height" -ge 12 ]] || height=24
  printf '%s' "$height"
}

show_help_pager() {
  local language="$1" content_file="$RUNTIME_DIR/help-$$.txt"
  if [[ "$language" == "th" ]]; then
    help_content_th >"$content_file"
  else
    help_content_en >"$content_file"
  fi

  local total height page_size offset=0 key rest max_offset
  total="$(wc -l <"$content_file" | tr -d ' ')"
  height="$(terminal_height)"
  page_size=$((height - 5))
  ((page_size < 5)) && page_size=5
  max_offset=$((total - page_size))
  ((max_offset < 0)) && max_offset=0

  if [[ -t 0 ]]; then
    exec 3<&0
  elif [[ -r /dev/tty ]]; then
    exec 3</dev/tty
  else
    cat "$content_file"
    rm -f "$content_file"
    return 0
  fi

  while true; do
    clear 2>/dev/null || printf '\033[2J\033[H'
    printf '%s%sHELP / คู่มือ%s  %sLine %d-%d of %d%s\n' \
      "$BOLD" "$CYAN" "$RESET" "$DIM" "$((offset + 1))" \
      "$((offset + page_size > total ? total : offset + page_size))" "$total" "$RESET"
    printf '%sUp/Down scroll  PgUp/PgDn page  Home/End jump  Esc/q close%s\n\n' "$DIM" "$RESET"
    sed -n "$((offset + 1)),$((offset + page_size))p" "$content_file"

    IFS= read -r -s -n 1 key <&3 || break
    if [[ "$key" == $'\033' ]]; then
      rest=""
      IFS= read -r -s -n 2 -t 1 rest <&3 || true
      if [[ "$rest" == $'[1' || "$rest" == $'[4' || "$rest" == $'[5' || "$rest" == $'[6' ]]; then
        local suffix=""
        IFS= read -r -s -n 1 -t 1 suffix <&3 || true
        rest+="$suffix"
      fi
      key+="$rest"
    fi

    case "$key" in
      $'\033[A'|k|K) ((offset > 0)) && offset=$((offset - 1)) ;;
      $'\033[B'|j|J) ((offset < max_offset)) && offset=$((offset + 1)) ;;
      $'\033[5~') offset=$((offset - page_size)); ((offset < 0)) && offset=0 ;;
      $'\033[6~') offset=$((offset + page_size)); ((offset > max_offset)) && offset=$max_offset ;;
      $'\033[H'|$'\033[1~'|g) offset=0 ;;
      $'\033[F'|$'\033[4~'|G) offset=$max_offset ;;
      q|Q|$'\033') break ;;
    esac
  done

  exec 3<&-
  rm -f "$content_file"
}

interactive_help() {
  local choice
  choice="$(choose_from "Help / คู่มือ" \
    "English guide::en" \
    "ไทย::th" \
    "Diagnostics (environment, tokens, rate-limit check)::diagnostics")" || return 0
  choice="${choice##*::}"
  case "$choice" in
    en) show_help_pager en ;;
    th) show_help_pager th ;;
    diagnostics)
      printf '\n'
      cmd_debug
      printf '\n%sPress Enter to return...%s' "$DIM" "$RESET"
      IFS= read -r _ </dev/tty
      ;;
  esac
}

interactive_config_editor() {
  local tz codex_on codex_timeout claude_on claude_timeout probe_model sched_on sched_interval
  local field new_val

  while true; do
    tz="$(jq -r '.display.timezone // "Asia/Bangkok"' "$CONFIG_FILE")"
    codex_on="$(jq -r '.monitor.codex.enabled // true' "$CONFIG_FILE")"
    codex_timeout="$(jq -r '.monitor.codex.timeout_seconds // 120' "$CONFIG_FILE")"
    claude_on="$(jq -r '.monitor.claude.enabled // true' "$CONFIG_FILE")"
    claude_timeout="$(jq -r '.monitor.claude.timeout_seconds // 15' "$CONFIG_FILE")"
    probe_model="$(jq -r '.monitor.claude.probe_model // "claude-haiku-4-5-20251001"' "$CONFIG_FILE")"
    sched_on="$(jq -r '.schedule.enabled // false' "$CONFIG_FILE")"
    sched_interval="$(jq -r '.schedule.interval_minutes // 60' "$CONFIG_FILE")"

    local sched_label
    [[ "$sched_on" == "true" ]] && sched_label="every ${sched_interval}m" || sched_label="off"

    field="$(choose_from "Settings  (Enter to edit, q to close)" \
      "Timezone              $tz::timezone" \
      "Codex monitor         $codex_on::codex-enabled" \
      "Codex timeout         ${codex_timeout}s::codex-timeout" \
      "Claude monitor        $claude_on::claude-enabled" \
      "Claude timeout        ${claude_timeout}s::claude-timeout" \
      "Claude probe model    $probe_model::claude-model" \
      "Schedule              $sched_label::schedule" \
    )" || return 0
    field="${field##*::}"

    case "$field" in
      timezone)
        printf 'Timezone (e.g. Asia/Bangkok, America/New_York) [%s]: ' "$tz"
        IFS= read -r new_val
        [[ -n "$new_val" ]] || continue
        config_set display.timezone "$new_val"
        ;;
      codex-enabled)
        [[ "$codex_on" == "true" ]] && new_val="false" || new_val="true"
        config_set monitor.codex.enabled "$new_val"
        ;;
      codex-timeout)
        printf 'Codex timeout seconds [%s]: ' "$codex_timeout"
        IFS= read -r new_val
        [[ "$new_val" =~ ^[0-9]+$ ]] || { warn "Must be a number."; continue; }
        config_set monitor.codex.timeout_seconds "$new_val"
        ;;
      claude-enabled)
        [[ "$claude_on" == "true" ]] && new_val="false" || new_val="true"
        config_set monitor.claude.enabled "$new_val"
        ;;
      claude-timeout)
        printf 'Claude timeout seconds [%s]: ' "$claude_timeout"
        IFS= read -r new_val
        [[ "$new_val" =~ ^[0-9]+$ ]] || { warn "Must be a number."; continue; }
        config_set monitor.claude.timeout_seconds "$new_val"
        ;;
      claude-model)
        printf 'Claude probe model [%s]: ' "$probe_model"
        IFS= read -r new_val
        [[ -n "$new_val" ]] || continue
        config_set monitor.claude.probe_model "$new_val"
        ;;
      schedule)
        local interval
        interval="$(choose_from "Schedule interval" \
          "Every 15 minutes::15" "Every 30 minutes::30" "Every hour::60" \
          "Every 2 hours::120" "Every 4 hours::240" "Every 6 hours::360" \
          "Disable schedule::off"
        )" || continue
        interval="${interval##*::}"
        if [[ "$interval" == "off" ]]; then
          disable_schedule
        else
          set_schedule_interval "${interval}m"
        fi
        ;;
    esac
  done
}

interactive_menu() {
  local name sched_label action sub prov
  start_background_refresh_for_tui
  while true; do
    reconcile_active_codex
    clear 2>/dev/null || true
    print_dashboard_header
    printf '\n'
    print_status
    refresh_status_line
    printf '\n'

    sched_label="Settings  ($(next_refresh_countdown))"

    action="$(
      AIC_REDRAW_ON_REFRESH_DONE=1 choose_from "Action" \
        "$(menu_item codex-switch "Switch account →" switch-account)" \
        "$(menu_item model-launch "Open with model →" model-launch)" \
        "$(menu_item add-codex "Add account →" add-account)" \
        "$(menu_item refresh "Refresh all usage" refresh-all)" \
        "$(menu_item manage "Manage accounts" manage)" \
        "$(menu_item transfer "Export / Import accounts →" transfer)" \
        "$(menu_item schedule "$sched_label" settings)" \
        "$(menu_item help "Help / คู่มือ" help)"
    )" || return 0
    [[ "$action" == "__AIC_REDRAW__" ]] && continue
    action="${action##*::}"

    case "$action" in
      switch-account)
        sub="$(choose_from "Switch account" \
          "$(menu_item codex-switch "Codex account" switch-codex)" \
          "$(menu_item claude-switch "Claude account" switch-claude)" \
        )" || continue
        sub="${sub##*::}"
        case "$sub" in
          switch-codex) interactive_use ;;
          switch-claude) interactive_claude_use ;;
        esac
        ;;
      model-launch)
        prov="$(choose_from "Open with model" \
          "$(menu_item codex-switch "Codex" codex)" \
          "$(menu_item claude-switch "Claude" claude)" \
        )" || continue
        prov="${prov##*::}"
        case "$prov" in
          codex) interactive_codex_model_launch ;;
          claude) interactive_claude_launch ;;
        esac
        ;;
      add-account)
        prov="$(choose_from "Add account" \
          "$(menu_item add-codex "Codex" codex)" \
          "$(menu_item add-claude "Claude" claude)" \
        )" || continue
        prov="${prov##*::}"
        if [[ "$prov" == "codex" ]]; then
          sub="$(choose_from "Add Codex account" \
            "$(menu_item codex-login "Login with browser" codex-login)" \
            "$(menu_item codex-add  "Save current session" codex-add-current)" \
            "$(menu_item codex-import "Import from file or paste" codex-import)" \
          )" || continue
          sub="${sub##*::}"
          case "$sub" in
            codex-login) printf 'Account name: '; IFS= read -r name; with_lock login_codex_browser "$name" ;;
            codex-add-current) printf 'Account name: '; IFS= read -r name; with_lock save_live_codex_as "$name" ;;
            codex-import) printf 'Account name: '; IFS= read -r name; with_lock import_codex_auth_json "$name" ;;
          esac
        else
          # Accounts here are OAuth logins only — they switch globally (keychain).
          # Setup-tokens are session credentials: add them under Open with model.
          sub="$(choose_from "Add Claude account (global switch)" \
            "$(menu_item claude-login "Login with OAuth" claude-login)" \
            "$(menu_item claude-import "Import current login" claude-import)" \
          )" || continue
          sub="${sub##*::}"
          case "$sub" in
            claude-login) printf 'Account name: '; IFS= read -r name; login_claude "$name" ;;
            claude-import) printf 'Account name: '; IFS= read -r name; import_current_claude "$name" ;;
          esac
        fi
        ;;
      manage) manage_account_menu ;;
      transfer)
        sub="$(choose_from "Export / Import accounts" \
          "$(menu_item export "Export accounts (to file or string)" export)" \
          "$(menu_item import "Import accounts (from file or string)" import)" \
        )" || continue
        sub="${sub##*::}"
        case "$sub" in
          export) interactive_export_accounts ;;
          import) interactive_import_accounts ;;
        esac
        ;;
      refresh-all) refresh_all || true ;;
      settings) interactive_config_editor ;;
      help) interactive_help ;;
    esac
    printf '\n%sPress Enter to return to the dashboard...%s' "$DIM" "$RESET"
    IFS= read -r _ </dev/tty
  done
}
