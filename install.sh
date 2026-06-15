#!/usr/bin/env bash

set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="${AIC_INSTALL_DIR:-$HOME/.local/bin}"

mkdir -p "$INSTALL_DIR"
ln -sfn "$SCRIPT_DIR/bin/aic" "$INSTALL_DIR/aic"

printf 'Installed: %s/aic\n' "$INSTALL_DIR"
case ":$PATH:" in
  *":$INSTALL_DIR:"*) ;;
  *) printf 'Add this to your shell config: export PATH="%s:$PATH"\n' "$INSTALL_DIR" ;;
esac
