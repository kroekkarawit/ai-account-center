#!/usr/bin/env bash

set -eu

REPO_OWNER="${AIC_REPO_OWNER:-kroekkarawit}"
REPO_NAME="${AIC_REPO_NAME:-ai-account-center}"
REPO_URL="${AIC_REPO_URL:-https://github.com/$REPO_OWNER/$REPO_NAME}"
APP_DIR="${AIC_APP_DIR:-$HOME/.local/share/ai-account-center}"
BIN_DIR="${AIC_INSTALL_DIR:-$HOME/.local/bin}"
REF="${AIC_INSTALL_REF:-main}"
MODE="copy"
REMOTE_INSTALL=0

usage() {
  cat <<HELP
AI Account Center installer

Usage:
  install.sh [--ref REF] [--dev] [--remote]

Options:
  --ref REF   Install from a Git branch/tag when running the remote installer.
              Default: main
  --dev       Symlink the current checkout instead of copying files.
  --remote    Download from GitHub even when this installer has local source.

Environment:
  AIC_APP_DIR       App install directory. Default: ~/.local/share/ai-account-center
  AIC_INSTALL_DIR   Binary directory. Default: ~/.local/bin
  AIC_REPO_URL      GitHub repository URL. Default: $REPO_URL
  GITHUB_TOKEN      Optional token for installing from a private repository.
HELP
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --ref)
      [[ -n "${2:-}" ]] || { printf 'Missing value for --ref\n' >&2; exit 1; }
      REF="$2"
      shift 2
      ;;
    --dev)
      MODE="dev"
      shift
      ;;
    --remote)
      REMOTE_INSTALL=1
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      printf 'Unknown option: %s\n' "$1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

need_command() {
  command -v "$1" >/dev/null 2>&1 || {
    printf 'Required command not found: %s\n' "$1" >&2
    exit 1
  }
}

build_curl_args() {
  CURL_ARGS=(-fsSL)
  if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    CURL_ARGS+=(-H "Authorization: Bearer $GITHUB_TOKEN")
  fi
}

download_source_if_needed() {
  [[ "$REMOTE_INSTALL" -eq 0 && -f "$SCRIPT_DIR/bin/aic" ]] && return 0

  need_command curl
  need_command tar
  need_command mktemp

  local tmp archive_url extracted
  tmp="$(mktemp -d)"
  archive_url="$REPO_URL/archive/refs/heads/$REF.tar.gz"
  if [[ "$REF" == v* ]]; then
    archive_url="$REPO_URL/archive/refs/tags/$REF.tar.gz"
  fi
  if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    archive_url="https://api.github.com/repos/$REPO_OWNER/$REPO_NAME/tarball/$REF"
  fi

  printf 'Downloading %s (%s)...\n' "$REPO_URL" "$REF"
  build_curl_args
  curl "${CURL_ARGS[@]}" "$archive_url" | tar -xz -C "$tmp"
  extracted="$(find "$tmp" -mindepth 1 -maxdepth 1 -type d -exec test -f '{}/install.sh' ';' -print | head -n 1)"
  [[ -n "$extracted" && -f "$extracted/install.sh" ]] || {
    printf 'Downloaded archive does not look like AI Account Center.\n' >&2
    exit 1
  }
  exec bash "$extracted/install.sh" --ref "$REF"
}

copy_source() {
  local source_dir="$1"
  mkdir -p "$APP_DIR"
  (
    cd "$source_dir"
    tar -cf - bin lib install.sh README.md spec-upgrade.md 2>/dev/null
  ) | (
    cd "$APP_DIR"
    tar -xf -
  )
  chmod +x "$APP_DIR/bin/aic" "$APP_DIR/install.sh"
}

install_link() {
  mkdir -p "$BIN_DIR"
  ln -sfn "$1" "$BIN_DIR/aic"
}

download_source_if_needed

if [[ "$MODE" == "dev" ]]; then
  install_link "$SCRIPT_DIR/bin/aic"
  printf 'Installed dev symlink: %s/aic -> %s/bin/aic\n' "$BIN_DIR" "$SCRIPT_DIR"
else
  copy_source "$SCRIPT_DIR"
  install_link "$APP_DIR/bin/aic"
  printf 'Installed: %s/aic\n' "$BIN_DIR"
  printf 'App files: %s\n' "$APP_DIR"
fi

case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) printf 'Add this to your shell config: export PATH="%s:$PATH"\n' "$BIN_DIR" ;;
esac

printf 'Update later with: aic update\n'
