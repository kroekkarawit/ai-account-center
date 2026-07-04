# shellcheck shell=bash
# aic module: codex-import
# Codex auth import: paste/file/clipboard JSON reading, validation, repair
# Sourced by lib/aic/_load.sh; not executed directly.

import_codex_auth_json() {
  local name="$1" source="${2:-}" temp=""
  validate_name "$name"

  if [[ -n "$source" ]]; then
    save_codex_auth_file_as "$name" "$source"
    return
  fi

  temp="$RUNTIME_DIR/import-codex-$name-$$.json"
  print_codex_import_prompt "$name"
  local import_status
  if read_json_object "$temp"; then
    :
  else
    import_status=$?
    rm -f "$temp"
    if [[ "$import_status" -eq 2 ]]; then
      printf 'Import failed.\n' >&2
    else
      printf 'Import cancelled.\n' >&2
    fi
    return "$import_status"
  fi
  chmod 600 "$temp"
  save_codex_auth_file_as "$name" "$temp"
  rm -f "$temp"
}

print_codex_import_prompt() {
  local name="$1"
  printf '+----------------------------------------------------------------+\n' >&2
  printf '| CODEX AUTH IMPORT                                              |\n' >&2
  printf '| Account: %-53.53s |\n' "$name" >&2
  printf '|                                                                |\n' >&2
  if command -v pbpaste >/dev/null 2>&1; then
    printf '|   >>>  PRESS  [ P ]  TO IMPORT FROM CLIPBOARD  <<<             |\n' >&2
    printf '|                                                                |\n' >&2
    printf '|   Or type/paste a file path: ~/Desktop/auth.json                |\n' >&2
    printf '|   Advanced fallback: paste raw JSON starting with {             |\n' >&2
  else
    printf '|   Type/paste a file path: ~/Desktop/auth.json                   |\n' >&2
    printf '|   Or paste raw JSON starting with {                              |\n' >&2
  fi
  printf '+----------------------------------------------------------------+\n' >&2
  printf 'Cancel: q / Ctrl-C / Ctrl-D    Clear: Ctrl-U\n' >&2
}

repair_json_control_chars() {
  local source="$1" destination="$2"
  command -v perl >/dev/null 2>&1 || return 1
  perl -0ne '
    my $out = "";
    my $in_string = 0;
    my $escaped = 0;
    for my $char (split //) {
      if ($in_string) {
        if ($escaped) {
          $out .= $char;
          $escaped = 0;
        } elsif ($char eq "\\") {
          $out .= $char;
          $escaped = 1;
        } elsif ($char eq "\"") {
          $out .= $char;
          $in_string = 0;
        } elsif ($char =~ /[\x00-\x1f]/) {
          next;
        } else {
          $out .= $char;
        }
      } else {
        $out .= $char;
        $in_string = 1 if $char eq "\"";
      }
    }
    print $out;
  ' "$source" >"$destination"
}

looks_like_truncated_token_copy() {
  local file="$1"
  grep -Eq '"(id_token|access_token|refresh_token)"[[:space:]]*:[[:space:]]*"[^"]*$' "$file" 2>/dev/null
}

validate_json_or_report() {
  local file="$1" source_label="$2" raw_debug="$3"
  local err_file repaired_file bytes lines preview_lines
  err_file="$RUNTIME_DIR/json-parse-$$.err"
  repaired_file="$RUNTIME_DIR/json-repair-$$.json"

  if jq -e . "$file" >/dev/null 2>"$err_file"; then
    rm -f "$err_file"
    return 0
  fi

  chmod 600 "$file" 2>/dev/null || true
  cp "$file" "$raw_debug" 2>/dev/null || true
  chmod 600 "$raw_debug" 2>/dev/null || true

  if repair_json_control_chars "$file" "$repaired_file" &&
    jq -e . "$repaired_file" >/dev/null 2>/dev/null; then
    cp "$repaired_file" "$file"
    chmod 600 "$file" 2>/dev/null || true
    rm -f "$err_file" "$repaired_file"
    printf 'Repaired %s JSON by removing raw control characters inside quoted strings.\n' "$source_label" >&2
    printf 'Original %s saved for local inspection: %s\n' "$source_label" "$raw_debug" >&2
    return 0
  fi
  rm -f "$repaired_file"

  bytes="$(wc -c <"$file" 2>/dev/null | tr -d ' ')"
  lines="$(wc -l <"$file" 2>/dev/null | tr -d ' ')"
  preview_lines=12

  printf 'JSON parse failed (%s).\n' "$source_label" >&2
  printf 'Size: %s bytes, %s lines\n' "${bytes:-0}" "${lines:-0}" >&2
  if [[ -s "$err_file" ]]; then
    printf 'jq error:\n' >&2
    while IFS= read -r line; do
      printf '  %s\n' "$line" >&2
    done <"$err_file"
  fi
  if [[ -f "$raw_debug" ]]; then
    printf 'Raw %s saved for local inspection: %s\n' "$source_label" "$raw_debug" >&2
  fi
  if looks_like_truncated_token_copy "$file"; then
    printf 'Diagnosis: token lines are missing closing quotes. This usually means the clipboard contains wrapped/truncated terminal text, not raw auth.json.\n' >&2
    printf 'Use file import, or copy from the file directly: pbcopy < /path/to/auth.json\n' >&2
  fi
  printf 'Redacted preview, first %d lines:\n' "$preview_lines" >&2
  sed -E \
    -e 's/("(id_token|access_token|refresh_token|OPENAI_API_KEY)"[[:space:]]*:[[:space:]]*")[^"]*/\1[redacted]/g' \
    "$file" 2>/dev/null |
    head -n "$preview_lines" |
    cut -c 1-240 |
    while IFS= read -r line; do
      printf '  %s\n' "$line" >&2
    done
  rm -f "$err_file"
  return 1
}

read_clipboard_json() {
  local destination="$1"
  command -v pbpaste >/dev/null 2>&1 || die "Clipboard import requires pbpaste. Paste a file path to the auth.json instead."
  pbpaste >"$destination"
  chmod 600 "$destination" 2>/dev/null || true
  if ! validate_json_or_report "$destination" "clipboard" "$RUNTIME_DIR/last-invalid-codex-clipboard.txt"; then
    return 1
  fi
}

normalize_import_path() {
  local input="$1" path
  path="$(printf '%s' "$input" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  if [[ "$path" == \"*\" && "$path" == *\" ]]; then
    path="${path#\"}"
    path="${path%\"}"
  elif [[ "$path" == \'*\' && "$path" == *\' ]]; then
    path="${path#\'}"
    path="${path%\'}"
  fi
  case "$path" in
    file://localhost/*) path="/${path#file://localhost/}" ;;
    file:///*) path="/${path#file:///}" ;;
  esac
  path="${path//%20/ }"
  path="${path//\\ / }"
  path="${path//\\(/(}"
  path="${path//\\)/)}"
  path="${path//\\[/[}"
  path="${path//\\]/]}"
  if [[ "$path" == "~" ]]; then
    path="$HOME"
  elif [[ "$path" == "~/"* ]]; then
    path="$HOME/${path#\~/}"
  fi
  printf '%s' "$path"
}

read_path_json() {
  local destination="$1" raw_path="$2" source
  source="$(normalize_import_path "$raw_path")"
  if [[ -z "$source" ]]; then
    return 1
  fi
  if [[ ! -f "$source" ]]; then
    printf 'File not found: %s\n' "$source" >&2
    printf 'Tip: drag the auth.json file into this terminal, or paste its full path.\n' >&2
    return 1
  fi
  cp "$source" "$destination"
  chmod 600 "$destination" 2>/dev/null || true
  if ! validate_json_or_report "$destination" "file" "$RUNTIME_DIR/last-invalid-codex-file.txt"; then
    return 1
  fi
}

read_json_object() {
  local destination="$1"
  : >"$destination"

  local started=0 depth=0 in_string=0 escaped=0 char command_line="" buffer=""
  local old_stty="" raw_enabled=0 cancelled=0 read_status=0
  local bracketed_paste=0 bracketed_paste_done=0 last_escape_sequence=""

  if [[ -t 0 ]]; then
    old_stty="$(stty -g 2>/dev/null || true)"
    if [[ -n "$old_stty" ]] && stty -icanon -echo -isig min 1 time 0 2>/dev/null; then
      raw_enabled=1
      printf 'Reading paste... chars: 0\r' >&2
    fi
  fi

  restore_terminal() {
    if ((raw_enabled)) && [[ -n "$old_stty" ]]; then
      stty "$old_stty" 2>/dev/null || true
    fi
  }

  reset_paste_state() {
    : >"$destination"
    buffer=""
    started=0
    depth=0
    in_string=0
    escaped=0
    command_line=""
    bracketed_paste=0
    bracketed_paste_done=0
    last_escape_sequence=""
  }

  replay_paste_state() {
    local i replay_char length
    started=0
    depth=0
    in_string=0
    escaped=0
    command_line=""
    length=${#buffer}
    for ((i = 0; i < length; i++)); do
      replay_char="${buffer:i:1}"
      update_json_state "$replay_char"
    done
    if ((started == 0)); then
      command_line="${buffer##*$'\n'}"
    else
      command_line=""
    fi
  }

  update_json_state() {
    local update_char="$1"
    if ((escaped)); then
      escaped=0
      return 0
    fi
    if [[ "$update_char" == "\\" && "$in_string" -eq 1 ]]; then
      escaped=1
      return 0
    fi
    if [[ "$update_char" == '"' ]]; then
      if ((in_string)); then in_string=0; else in_string=1; fi
      return 0
    fi
    ((in_string)) && return 0
    case "$update_char" in
      "{") started=1; depth=$((depth + 1)) ;;
      "}") depth=$((depth - 1)) ;;
    esac
  }

  print_paste_status() {
    ((raw_enabled)) || return 0
    printf 'Reading paste... chars: %-8d\r' "${#buffer}" >&2
  }

  read_escape_sequence() {
    local introducer="" seq_char="" sequence=""
    last_escape_sequence=""
    IFS= read -r -s -n 1 -t 1 introducer || return 0
    case "$introducer" in
      "[")
        sequence="["
        while IFS= read -r -s -n 1 -t 1 seq_char; do
          sequence+="$seq_char"
          case "$seq_char" in
            [A-Za-z~]) break ;;
          esac
        done
        last_escape_sequence="$sequence"
        case "$sequence" in
          "[200~") bracketed_paste=1 ;;
          "[201~") bracketed_paste_done=1 ;;
        esac
        ;;
      "]")
        sequence="]"
        while IFS= read -r -s -n 1 -t 1 seq_char; do
          sequence+="$seq_char"
          [[ "$seq_char" == $'\a' ]] && break
        done
        last_escape_sequence="$sequence"
        ;;
    esac
  }

  while IFS= read -r -n 1 char; do
    case "$char" in
      $'\003')
        cancelled=1
        read_status=130
        break
        ;;
      $'\004')
        read_status=1
        break
        ;;
      $'\025')
        reset_paste_state
        printf '\nPaste buffer cleared. Paste Codex auth.json again, or press Ctrl-C to cancel.\n' >&2
        print_paste_status
        continue
        ;;
      $'\177'|$'\010')
        if [[ -n "$buffer" ]]; then
          buffer="${buffer%?}"
          replay_paste_state
          print_paste_status
        fi
        continue
        ;;
      $'\033')
        read_escape_sequence
        if ((started && depth <= 0 && in_string == 0)); then
          if ((bracketed_paste == 0 || bracketed_paste_done)); then
            break
          fi
        fi
        continue
        ;;
      $'\r')
        char=$'\n'
        ;;
    esac
    if [[ -z "$char" ]]; then
      char=$'\n'
    fi

    if ((started == 0)); then
      if [[ "$char" == "p" || "$char" == "P" ]] && [[ -z "$command_line" ]]; then
        restore_terminal
        trap - INT
        printf '\nImporting Codex auth.json from clipboard...\n' >&2
        if read_clipboard_json "$destination"; then
          return 0
        fi
        return 2
      fi
      if [[ "$char" == $'\n' ]]; then
        case "$command_line" in
          q|:q|quit|exit)
            read_status=1
            break
            ;;
        esac
        if [[ -n "$command_line" ]]; then
          restore_terminal
          trap - INT
          printf '\nImporting Codex auth.json from file path...\n' >&2
          if read_path_json "$destination" "$command_line"; then
            return 0
          fi
          return 2
        fi
        command_line=""
      else
        command_line+="$char"
      fi
    fi

    buffer+="$char"
    update_json_state "$char"
    print_paste_status

    if ((started && depth <= 0 && in_string == 0)); then
      if ((bracketed_paste && bracketed_paste_done == 0)); then
        continue
      fi
      break
    fi
  done
  if ((cancelled)); then
    read_status=130
  elif ((started == 0 && depth == 0)); then
    read_status=1
  fi
  restore_terminal
  trap - INT

  if ((read_status != 0)); then
    return 1
  fi

  if ((started == 0)); then
    die "No JSON object was pasted."
  fi
  if ((depth > 0 || in_string == 1)); then
    die "Pasted JSON is incomplete. Paste the full auth.json, or provide a file path instead."
  fi
  printf '%s' "$buffer" >"$destination"
  chmod 600 "$destination" 2>/dev/null || true
  if ! validate_json_or_report "$destination" "paste" "$RUNTIME_DIR/last-invalid-codex-paste.txt"; then
    return 2
  fi
}

reimport_codex_auth_json() {
  local name="$1" source="${2:-}"
  validate_name "$name"
  local existing_file backup
  existing_file="$(codex_account_file "$name")"
  [[ -f "$existing_file" ]] || die "Unknown Codex account: $name"
  backup="$existing_file.reimport-$$"
  cp "$existing_file" "$backup"
  chmod 600 "$backup"
  rm -f "$existing_file"
  if import_codex_auth_json "$name" "$source"; then
    rm -f "$backup"
  else
    mv "$backup" "$existing_file"
    warn "Re-import failed. Original credentials restored for: $name"
    return 1
  fi
}

