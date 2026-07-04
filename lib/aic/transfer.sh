# shellcheck shell=bash
# aic module: transfer
# Encrypted account export/import between machines (spec-upgrade.md §7).
# Sourced by lib/aic/_load.sh; not executed directly.
#
# Envelope (text):  AIC<fmtver>.<keyver>.<base64>
#   base64 = openssl-base64( AES-256-CBC( gzip( payload-json ) ) )
# This is OBFUSCATION, not confidentiality: aic is open source and holds the
# key, so anyone running aic can decode a blob. It stops casual/accidental
# leakage and secret-scanners, and the fixed 3-day TTL limits the exposure
# window. See the Threat Model in spec-upgrade.md §7.

TRANSFER_FMT="AIC1"                 # magic + format version
TRANSFER_KEY_VERSION=1             # bump (and add a case below) to rotate the key
TRANSFER_TTL_SECONDS=259200       # fixed 3 days (policy)
TRANSFER_ITER=100000

# Embedded per-version obfuscation key. Not a secret in the crypto sense.
transfer_app_key() {
  case "$1" in
    1) printf '%s' 'aic-xfer-k1:6b8d1f2a94c7e05b3d8a71f0c2e94d6b8a15f3c7e29d04b6a8c1e5f7092b3d4a6' ;;
    *) return 1 ;;
  esac
}

# Encode: payload JSON on stdin -> "AIC1.<keyver>.<base64>" on stdout.
transfer_encode() {
  local keyver="$TRANSFER_KEY_VERSION" key ct
  key="$(transfer_app_key "$keyver")" || return 1
  ct="$(gzip -c |
    openssl enc -aes-256-cbc -pbkdf2 -iter "$TRANSFER_ITER" -md sha256 -salt \
      -pass pass:"$key" 2>/dev/null |
    openssl base64 -A 2>/dev/null)"
  [[ -n "$ct" ]] || return 1
  printf '%s.%s.%s' "$TRANSFER_FMT" "$keyver" "$ct"
}

# Decode: arg1 = blob -> payload JSON on stdout.
# Return codes: 0 ok | 2 not-an-aic-blob/malformed | 3 newer format/unknown key
# | 4 decrypt/decompress failed (corrupt or foreign key).
transfer_decode() {
  local blob magic rest keyver b64 key payload
  blob="$(printf '%s' "$1" | tr -d '[:space:]')"
  [[ -n "$blob" && "$blob" == *.*.* ]] || return 2
  magic="${blob%%.*}"
  rest="${blob#*.}"
  keyver="${rest%%.*}"
  b64="${rest#*.}"
  case "$magic" in
    "$TRANSFER_FMT") ;;
    AIC*) return 3 ;;          # e.g. AIC2 from a newer aic
    *) return 2 ;;
  esac
  [[ -n "$keyver" && -n "$b64" && "$keyver" =~ ^[0-9]+$ ]] || return 2
  key="$(transfer_app_key "$keyver")" || return 3
  payload="$(printf '%s' "$b64" |
    openssl base64 -d -A 2>/dev/null |
    openssl enc -d -aes-256-cbc -pbkdf2 -iter "$TRANSFER_ITER" -md sha256 \
      -pass pass:"$key" 2>/dev/null |
    gunzip 2>/dev/null)"
  [[ -n "$payload" ]] || return 4
  jq -e . <<<"$payload" >/dev/null 2>&1 || return 4
  printf '%s' "$payload"
}

# 0 if the decoded payload is past its TTL (or malformed timing).
transfer_payload_expired() {
  local payload="$1" created ttl now
  created="$(jq -r '.created_at // empty' <<<"$payload" 2>/dev/null)"
  ttl="$(jq -r '.ttl // empty' <<<"$payload" 2>/dev/null)"
  [[ "$created" =~ ^[0-9]+$ && "$ttl" =~ ^[0-9]+$ ]] || return 0
  now="$(date +%s)"
  ((now > created + ttl))
}

# Build the payload JSON from a list of "provider:name" specs (stdout).
build_transfer_payload() {
  local now spec provider name file data idfield idval accounts_json="[]"
  now="$(date +%s)"
  for spec in "$@"; do
    provider="${spec%%:*}"
    name="${spec#*:}"
    if [[ "$provider" == "codex" ]]; then
      file="$(codex_account_file "$name")"
      idfield="account_id"
      idval="$(codex_account_id "$file" 2>/dev/null)"
    else
      file="$(claude_account_file "$name")"
      idfield="org"
      idval="$(jq -r '.organizationUuid // empty' "$file" 2>/dev/null)"
    fi
    [[ -f "$file" ]] || continue
    data="$(cat "$file")"
    accounts_json="$(jq \
      --arg p "$provider" --arg n "$name" --arg idf "$idfield" --arg idv "$idval" \
      --argjson d "$data" \
      '. + [ {provider:$p, name:$n, ($idf):$idv, data:$d} ]' <<<"$accounts_json")" || return 1
  done
  jq -n \
    --argjson now "$now" --argjson ttl "$TRANSFER_TTL_SECONDS" \
    --argjson accounts "$accounts_json" \
    '{v:1, created_at:$now, ttl:$ttl, accounts:$accounts}'
}

# Existing account name that shares this incoming account's identity, if any
# (Codex: same account_id/user identity; Claude: same org under a different name).
transfer_identity_conflict() {
  local provider="$1" data="$2" tmp result="" f
  tmp="$RUNTIME_DIR/xfer-id-$$.json"
  printf '%s' "$data" >"$tmp"
  chmod 600 "$tmp" 2>/dev/null || true
  if [[ "$provider" == "codex" ]]; then
    result="$(codex_duplicate_name_for_file "$tmp" "$tmp" 2>/dev/null || true)"
  else
    local org
    org="$(jq -r '.organizationUuid // empty' "$tmp" 2>/dev/null)"
    if [[ -n "$org" ]]; then
      for f in "$CLAUDE_ACCOUNTS_DIR"/*.json; do
        [[ -e "$f" ]] || continue
        if [[ "$(jq -r '.organizationUuid // empty' "$f" 2>/dev/null)" == "$org" ]]; then
          result="$(basename "$f" .json)"
          break
        fi
      done
    fi
  fi
  rm -f "$tmp"
  printf '%s' "$result"
}

transfer_name_exists() {
  local provider="$1" name="$2" file
  if [[ "$provider" == "codex" ]]; then file="$(codex_account_file "$name")"; else file="$(claude_account_file "$name")"; fi
  [[ -f "$file" ]]
}

# Validate + write one account's data under a name (0600, backs up any existing).
transfer_write_account() {
  local provider="$1" name="$2" data="$3" dest tmp
  validate_name "$name" || return 1
  if [[ "$provider" == "codex" ]]; then dest="$(codex_account_file "$name")"; else dest="$(claude_account_file "$name")"; fi
  tmp="$dest.xfer-$$"
  printf '%s' "$data" >"$tmp"
  chmod 600 "$tmp" 2>/dev/null || true

  if [[ "$provider" == "codex" ]]; then
    validate_codex_auth "$tmp" || { rm -f "$tmp"; return 2; }
  else
    jq -e '.claudeAiOauth.refreshToken or .token' "$tmp" >/dev/null 2>&1 || { rm -f "$tmp"; return 2; }
  fi

  if [[ -f "$dest" ]]; then
    cp "$dest" "$BACKUP_DIR/$(basename "$dest" .json)-xfer-$(date -u +%Y%m%dT%H%M%SZ).json" 2>/dev/null || true
  fi
  mv -f "$tmp" "$dest" || return 1
  chmod 600 "$dest" 2>/dev/null || true
}

transfer_unique_name() {
  local provider="$1" base="$2" n=2 candidate
  candidate="$base-$n"
  while transfer_name_exists "$provider" "$candidate"; do
    n=$((n + 1))
    candidate="$base-$n"
  done
  printf '%s' "$candidate"
}

# ---------------------------------------------------------------------------
# Interactive export / import (menu-driven)
# ---------------------------------------------------------------------------

transfer_clipboard_copy() {
  if command -v pbcopy >/dev/null 2>&1; then pbcopy
  elif command -v wl-copy >/dev/null 2>&1; then wl-copy
  elif command -v xclip >/dev/null 2>&1; then xclip -selection clipboard
  else return 1; fi
}

# Choose an output folder: native picker on macOS, prompt elsewhere. Prints path.
transfer_pick_folder() {
  local dir=""
  if [[ "$(uname -s)" == "Darwin" ]] && command -v osascript >/dev/null 2>&1; then
    dir="$(osascript -e 'try
  POSIX path of (choose folder with prompt "Choose a folder to save the aic transfer file")
on error
  return ""
end try' 2>/dev/null)"
    dir="${dir%/}"
  else
    printf 'Folder to save into [%s]: ' "$HOME" >&2
    IFS= read -r dir
    [[ -z "$dir" ]] && dir="$HOME"
    dir="$(normalize_import_path "$dir")"
  fi
  [[ -n "$dir" && -d "$dir" ]] || return 1
  printf '%s' "$dir"
}

interactive_export_accounts() {
  local options=() name chosen=() spec blob transport
  while IFS= read -r name; do [[ -n "$name" ]] && options+=("Codex  | $name::codex:$name"); done < <(codex_names)
  while IFS= read -r name; do [[ -n "$name" ]] && options+=("Claude | $name::claude:$name"); done < <(claude_names)
  [[ "${#options[@]}" -gt 0 ]] || { warn "No accounts to export."; return 1; }

  while IFS= read -r spec; do [[ -n "$spec" ]] && chosen+=("$spec"); done \
    < <(choose_multi "Select accounts to export" "${options[@]}")
  [[ "${#chosen[@]}" -gt 0 ]] || { info "Nothing selected."; return 0; }

  blob="$(build_transfer_payload "${chosen[@]}" | transfer_encode)" ||
    { warn "Export failed while encoding."; return 1; }

  transport="$(choose_from "Export ${#chosen[@]} account(s) as" \
    "Save to a file::file" \
    "Show a copy-paste string::string")" || return 0
  transport="${transport##*::}"

  if [[ "$transport" == "file" ]]; then
    local dir out
    dir="$(transfer_pick_folder)" || { info "Export cancelled."; return 0; }
    out="$dir/aic-transfer-$(date -u +%Y%m%dT%H%M%SZ).aicx"
    printf '%s' "$blob" >"$out"
    chmod 600 "$out" 2>/dev/null || true
    printf '%sExported %d account(s) to:%s %s\n' "$GREEN" "${#chosen[@]}" "$RESET" "$out"
  else
    printf '\n%s----- BEGIN AIC TRANSFER (expires in 3 days) -----%s\n' "$DIM" "$RESET"
    printf '%s\n' "$blob"
    printf '%s----- END AIC TRANSFER -----%s\n' "$DIM" "$RESET"
    if printf '%s' "$blob" | transfer_clipboard_copy 2>/dev/null; then
      printf '%sCopied to clipboard.%s\n' "$GREEN" "$RESET"
    fi
  fi
  printf 'Expires in 3 days. Send it to yourself, import on the other machine, then delete it.\n'
}

interactive_import_accounts() {
  local src blob path
  src="$(choose_from "Import accounts from" \
    "Paste a transfer string::paste" \
    "Read a file (path or drag)::file")" || return 0
  src="${src##*::}"

  if [[ "$src" == "paste" ]]; then
    printf 'Paste the AIC transfer string, then press Enter:\n' >&2
    IFS= read -r blob
  else
    printf 'File path (you can drag the file into the terminal): ' >&2
    IFS= read -r path
    path="$(normalize_import_path "$path")"
    [[ -f "$path" ]] || { warn "File not found: $path"; return 1; }
    blob="$(cat "$path")"
  fi
  [[ -n "$blob" ]] || { info "Nothing to import."; return 0; }
  import_transfer_blob "$blob"
}

# Decode a transfer blob, let the user pick which accounts to import, and resolve
# duplicates. Interactive (uses choose_multi / choose_from).
import_transfer_blob() {
  local blob="$1" payload rc count i provider name data idconf target ans
  local options=() chosen=() idx imported=0 skipped=0

  payload="$(transfer_decode "$blob")"
  rc=$?
  case "$rc" in
    0) ;;
    3) warn "This transfer was made by a newer aic. Update first: aic update"; return 1 ;;
    *) warn "This does not look like a valid aic transfer (corrupt or wrong format)."; return 1 ;;
  esac
  if transfer_payload_expired "$payload"; then
    warn "This transfer has expired (valid for 3 days). Ask for a fresh export."
    return 1
  fi

  count="$(jq -r '.accounts | length' <<<"$payload" 2>/dev/null || printf 0)"
  [[ "$count" =~ ^[0-9]+$ && "$count" -gt 0 ]] || { warn "The transfer contains no accounts."; return 1; }

  for ((i = 0; i < count; i++)); do
    provider="$(jq -r ".accounts[$i].provider" <<<"$payload")"
    name="$(jq -r ".accounts[$i].name" <<<"$payload")"
    if [[ "$provider" == "codex" ]]; then options+=("Codex  | $name::$i"); else options+=("Claude | $name::$i"); fi
  done

  while IFS= read -r idx; do [[ -n "$idx" ]] && chosen+=("$idx"); done \
    < <(choose_multi "Select accounts to import ($count found)" "${options[@]}")
  [[ "${#chosen[@]}" -gt 0 ]] || { info "Nothing selected."; return 0; }

  for idx in "${chosen[@]}"; do
    provider="$(jq -r ".accounts[$idx].provider" <<<"$payload")"
    name="$(jq -r ".accounts[$idx].name" <<<"$payload")"
    data="$(jq -c ".accounts[$idx].data" <<<"$payload")"
    target="$name"

    idconf="$(transfer_identity_conflict "$provider" "$data")"
    if [[ -n "$idconf" ]]; then
      ans="$(choose_from "'$name' is already stored as '$idconf'." \
        "Replace '$idconf' (keeps that name)::replace" "Skip::skip")" || { skipped=$((skipped + 1)); continue; }
      ans="${ans##*::}"
      [[ "$ans" == "skip" ]] && { skipped=$((skipped + 1)); continue; }
      target="$idconf"
    elif transfer_name_exists "$provider" "$name"; then
      ans="$(choose_from "The name '$name' is used by a different account." \
        "Overwrite '$name'::overwrite" "Import as '$(transfer_unique_name "$provider" "$name")'::rename" "Skip::skip")" ||
        { skipped=$((skipped + 1)); continue; }
      ans="${ans##*::}"
      case "$ans" in
        skip) skipped=$((skipped + 1)); continue ;;
        rename) target="$(transfer_unique_name "$provider" "$name")" ;;
      esac
    fi

    if transfer_write_account "$provider" "$target" "$data"; then
      printf '%sImported%s %s/%s\n' "$GREEN" "$RESET" "$provider" "$target"
      imported=$((imported + 1))
    else
      warn "Skipped $provider/$name — invalid account data."
      skipped=$((skipped + 1))
    fi
  done

  reconcile_active_codex 2>/dev/null || true
  printf '\nDone: %d imported, %d skipped.\n' "$imported" "$skipped"
}
