# shellcheck shell=bash
# aic module: model
# Model profiles: launch Codex/Claude with an alternate provider/model
# Sourced by lib/aic/_load.sh; not executed directly.

model_profile_file() { printf '%s/%s.json\n' "$MODEL_PROFILES_DIR" "$1"; }

model_profile_names() {
  local file
  for file in "$MODEL_PROFILES_DIR"/*.json; do
    [[ -e "$file" ]] || continue
    basename "$file" .json
  done
}

_model_preset() {
  local preset="$1"
  case "$preset" in
    deepseek-v4-pro)
      printf '%s\n' \
        'display_name=DeepSeek V4 Pro' \
        'base_url=https://api.deepseek.com/anthropic' \
        'default_model=deepseek-v4-pro' \
        'opus_model=deepseek-v4-pro' \
        'sonnet_model=deepseek-v4-pro' \
        'haiku_model=deepseek-v4-flash' \
        'subagent_model=deepseek-v4-flash'
      ;;
    deepseek-v3)
      printf '%s\n' \
        'display_name=DeepSeek V3' \
        'base_url=https://api.deepseek.com/anthropic' \
        'default_model=deepseek-v3' \
        'opus_model=deepseek-v3' \
        'sonnet_model=deepseek-v3' \
        'haiku_model=deepseek-v3' \
        'subagent_model=deepseek-v3'
      ;;
  esac
}

add_model_profile() {
  local name="${1:-}"
  local preset
  preset="$(choose_from "Select provider" \
    "DeepSeek V4 Pro  (verified with Claude Code)::deepseek-v4-pro" \
    "DeepSeek V3::deepseek-v3" \
    "Custom (enter URL and models manually)::custom" \
  )" || return 1
  preset="${preset##*::}"

  if [[ -z "$name" ]]; then
    printf 'Profile name (e.g. deepseek, my-deepseek): '
    IFS= read -r name
    [[ -n "$name" ]] || return 1
  fi
  validate_name "$name"
  local dest
  dest="$(model_profile_file "$name")"
  [[ ! -f "$dest" ]] || die "Model profile already exists: $name"

  local display_name base_url default_model opus_model sonnet_model haiku_model subagent_model
  if [[ "$preset" != "custom" ]]; then
    local line key val
    while IFS= read -r line; do
      key="${line%%=*}"; val="${line#*=}"
      case "$key" in
        display_name)  display_name="$val"  ;;
        base_url)      base_url="$val"      ;;
        default_model) default_model="$val" ;;
        opus_model)    opus_model="$val"    ;;
        sonnet_model)  sonnet_model="$val"  ;;
        haiku_model)   haiku_model="$val"   ;;
        subagent_model) subagent_model="$val" ;;
      esac
    done < <(_model_preset "$preset")
  else
    display_name="$name"
    printf 'API base URL (e.g. https://api.deepseek.com/anthropic): '
    IFS= read -r base_url; [[ -n "$base_url" ]] || die "Base URL required."
    printf 'Default model name: '
    IFS= read -r default_model; [[ -n "$default_model" ]] || die "Model name required."
    printf 'Opus model    [%s]: ' "$default_model"; IFS= read -r opus_model
    printf 'Sonnet model  [%s]: ' "$default_model"; IFS= read -r sonnet_model
    printf 'Haiku model   [%s]: ' "$default_model"; IFS= read -r haiku_model
    printf 'Subagent model[%s]: ' "${haiku_model:-$default_model}"; IFS= read -r subagent_model
    [[ -n "$opus_model" ]]    || opus_model="$default_model"
    [[ -n "$sonnet_model" ]]  || sonnet_model="$default_model"
    [[ -n "$haiku_model" ]]   || haiku_model="$default_model"
    [[ -n "$subagent_model" ]] || subagent_model="$haiku_model"
  fi

  printf 'API key for %s (hidden): ' "$display_name" >&2
  local api_key=""
  IFS= read -r -s api_key; printf '\n' >&2
  [[ -n "$api_key" ]] || die "API key cannot be empty."

  jq -n \
    --arg name "$name" \
    --arg display_name "$display_name" \
    --arg base_url "$base_url" \
    --arg api_key "$api_key" \
    --arg default_model "$default_model" \
    --arg opus_model "$opus_model" \
    --arg sonnet_model "$sonnet_model" \
    --arg haiku_model "$haiku_model" \
    --arg subagent_model "$subagent_model" \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{name:$name,display_name:$display_name,base_url:$base_url,api_key:$api_key,
      default_model:$default_model,opus_model:$opus_model,sonnet_model:$sonnet_model,
      haiku_model:$haiku_model,subagent_model:$subagent_model,created_at:$ts}' \
    >"$dest.tmp" || die "Could not save model profile."
  chmod 600 "$dest.tmp"
  mv -f "$dest.tmp" "$dest"
  printf 'Saved model profile: %s (%s)\n' "$name" "$display_name"
}

remove_model_profile() {
  local name="$1"
  validate_name "$name"
  local file
  file="$(model_profile_file "$name")"
  [[ -f "$file" ]] || die "Unknown model profile: $name"
  rm -f "$file"
  printf 'Removed model profile: %s\n' "$name"
}

launch_with_profile() {
  local name="$1"; shift
  local file
  file="$(model_profile_file "$name")"
  [[ -f "$file" ]] || die "Unknown model profile: $name"
  require_command claude

  local base_url api_key default_model opus_model sonnet_model haiku_model subagent_model display_name
  base_url="$(jq -r      '.base_url      // empty' "$file")"
  api_key="$(jq -r       '.api_key       // empty' "$file")"
  default_model="$(jq -r '.default_model // empty' "$file")"
  opus_model="$(jq -r    '.opus_model    // empty' "$file")"
  sonnet_model="$(jq -r  '.sonnet_model  // empty' "$file")"
  haiku_model="$(jq -r   '.haiku_model   // empty' "$file")"
  subagent_model="$(jq -r '.subagent_model // empty' "$file")"
  display_name="$(jq -r  '.display_name // .name' "$file")"

  local envs=()
  [[ -n "$base_url"      ]] && envs+=("ANTHROPIC_BASE_URL=$base_url")
  [[ -n "$api_key"       ]] && envs+=("ANTHROPIC_AUTH_TOKEN=$api_key")
  [[ -n "$default_model" ]] && envs+=("ANTHROPIC_MODEL=$default_model")
  [[ -n "$opus_model"    ]] && envs+=("ANTHROPIC_DEFAULT_OPUS_MODEL=$opus_model")
  [[ -n "$sonnet_model"  ]] && envs+=("ANTHROPIC_DEFAULT_SONNET_MODEL=$sonnet_model")
  [[ -n "$haiku_model"   ]] && envs+=("ANTHROPIC_DEFAULT_HAIKU_MODEL=$haiku_model")
  [[ -n "$subagent_model" ]] && envs+=("CLAUDE_CODE_SUBAGENT_MODEL=$subagent_model")

  printf '%sLaunching Claude  ·  profile: %s  ·  %s%s\n' \
    "$CYAN" "$display_name" "${base_url#https://}" "$RESET"
  exec env "${envs[@]}" claude "$@"
}

codex_profile_base_url() {
  local file="$1" base_url
  base_url="$(jq -r '.codex_base_url // .openai_base_url // .base_url // empty' "$file")"
  case "$base_url" in
    */anthropic) base_url="${base_url%/anthropic}" ;;
  esac
  printf '%s' "$base_url"
}

toml_string() {
  jq -Rn -r --arg value "$1" '$value | @json'
}

launch_codex_with_profile() {
  local name="$1"; shift
  local file
  file="$(model_profile_file "$name")"
  [[ -f "$file" ]] || die "Unknown model profile: $name"
  require_command codex

  local base_url api_key model display_name
  base_url="$(codex_profile_base_url "$file")"
  api_key="$(jq -r '.codex_api_key // .openai_api_key // .api_key // empty' "$file")"
  model="$(jq -r '.codex_model // .openai_model // .default_model // empty' "$file")"
  display_name="$(jq -r '.display_name // .name' "$file")"
  [[ -n "$model" ]] || die "Model profile '$name' has no default model."

  local envs=()
  [[ -n "$api_key" ]] && envs+=("OPENAI_API_KEY=$api_key")
  local args=()
  if [[ -n "$base_url" ]]; then
    envs+=("OPENAI_BASE_URL=$base_url")
    args+=("-c" "openai_base_url=$(toml_string "$base_url")")
  fi
  args+=("--model" "$model")

  printf '%sLaunching Codex  ·  profile: %s  ·  model: %s%s\n' \
    "$CYAN" "$display_name" "$model" "$RESET"
  exec env "${envs[@]}" codex "${args[@]}" "$@"
}

interactive_model_launch_for() {
  local target="$1"
  local options=() name display base file item
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    file="$(model_profile_file "$name")"
    display="$(jq -r '.display_name // .name' "$file" 2>/dev/null)"
    if [[ "$target" == "codex" ]]; then
      base="$(codex_profile_base_url "$file")"
    else
      base="$(jq -r '.base_url // ""' "$file" 2>/dev/null)"
    fi
    base="${base#https://}"; base="${base%%/*}"
    options+=("$name  —  $display  ($base)::$name")
  done < <(model_profile_names)

  if [[ "${#options[@]}" -eq 0 ]]; then
    warn "No model profiles saved."
    local ans
    ans="$(choose_from "Add a profile now?" \
      "Yes, add a profile" "No, cancel")" || return 0
    [[ "$ans" == "Yes"* ]] && add_model_profile
    return 0
  fi

  options+=("+ Add new profile::__add__")
  options+=("⚙ Manage profiles (remove)::__manage__")
  item="$(choose_from "Select $target model profile" "${options[@]}")" || return 1
  local key="${item##*::}"
  [[ "$key" == "__add__" ]] && { add_model_profile; return; }
  [[ "$key" == "__manage__" ]] && { manage_model_profiles; return; }
  case "$target" in
    codex) launch_codex_with_profile "$key" ;;
    claude) launch_with_profile "$key" ;;
  esac
}

# Manage saved model profiles from the TUI (the old `aic model remove` verb).
manage_model_profiles() {
  local options=() name display file item key action confirm
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    file="$(model_profile_file "$name")"
    display="$(jq -r '.display_name // .name' "$file" 2>/dev/null)"
    options+=("$name  —  $display::$name")
  done < <(model_profile_names)
  [[ "${#options[@]}" -gt 0 ]] || { warn "No model profiles saved."; return 0; }

  item="$(choose_from "Select a profile to manage" "${options[@]}")" || return 0
  key="${item##*::}"
  action="$(choose_from "Manage profile: $key" \
    "×  Remove profile::remove" \
    "←  Back::back")" || return 0
  action="${action##*::}"
  case "$action" in
    remove)
      confirm="$(choose_from "Remove model profile '$key'?" "No, cancel" "Yes, remove it")" || return 0
      [[ "$confirm" == "Yes, remove it" ]] && remove_model_profile "$key"
      ;;
  esac
}

# Run a profile session → Claude. Runs a per-session Claude in THIS terminal:
# a parallel Claude account (its own quota; setup-token via CLAUDE_CODE_OAUTH_TOKEN
# or OAuth via CLAUDE_CONFIG_DIR) or a third-party model profile (DeepSeek/custom).
# Parallel accounts exclude the global-active one and any already running.
interactive_claude_launch() {
  local options=() name display base file item key badge kind

  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    kind="$(claude_account_kind "$name")"
    badge="$(claude_token_usage_badge "$name")"
    options+=("$name  —  parallel account ($kind)${badge:+  $badge}::acct:$name")
  done < <(claude_parallel_candidates)

  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    file="$(model_profile_file "$name")"
    display="$(jq -r '.display_name // .name' "$file" 2>/dev/null)"
    base="$(jq -r '.base_url // ""' "$file" 2>/dev/null)"; base="${base#https://}"; base="${base%%/*}"
    options+=("$name  —  $display ($base)::prof:$name")
  done < <(model_profile_names)

  options+=("＋ Add Claude setup-token::__addtok__")
  options+=("＋ Add model / API provider::__addprof__")
  options+=("⚙ Manage model profiles::__manage__")

  item="$(choose_from "Run a profile session" "${options[@]}")" || return 1
  key="${item##*::}"
  case "$key" in
    __addtok__)  printf 'Name for this setup-token: '; IFS= read -r name; add_claude_token "$name" ;;
    __addprof__) add_model_profile ;;
    __manage__)  manage_model_profiles ;;
    acct:*) launch_claude_parallel "${key#acct:}" ;;
    prof:*) launch_with_profile "${key#prof:}" ;;
  esac
}

interactive_codex_model_launch() {
  interactive_model_launch_for codex
}

