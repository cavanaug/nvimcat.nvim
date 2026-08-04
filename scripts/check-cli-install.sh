#!/usr/bin/env bash
# Self-check: setup() symlinks ~/.local/bin/nvimcat (using temp HOME).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOME_TMP="$(mktemp -d)"
trap 'rm -rf "$HOME_TMP"' EXIT
export HOME="$HOME_TMP"

nvim --headless \
  --cmd "set rtp^=${ROOT}" \
  -c "lua require('nvimcat').setup({})" \
  -c "qa!"

link="$HOME_TMP/.local/bin/nvimcat"
target="$ROOT/bin/nvimcat"

if [[ ! -L "$link" ]]; then
  echo "FAIL: expected symlink at $link" >&2
  exit 1
fi
got="$(readlink "$link")"
if [[ "$got" != "$target" ]]; then
  echo "FAIL: symlink points to $got, want $target" >&2
  exit 1
fi

# Second setup is no-op / still correct.
nvim --headless \
  --cmd "set rtp^=${ROOT}" \
  -c "lua require('nvimcat').setup({})" \
  -c "qa!"
got2="$(readlink "$link")"
[[ "$got2" == "$target" ]] || { echo "FAIL: rerun changed link" >&2; exit 1; }

# Opt-out does not remove existing link; with empty bin and install_cli=false, no link created.
HOME_TMP2="$(mktemp -d)"
export HOME="$HOME_TMP2"
nvim --headless \
  --cmd "set rtp^=${ROOT}" \
  -c "lua require('nvimcat').setup({ install_cli = false })" \
  -c "qa!"
if [[ -e "$HOME_TMP2/.local/bin/nvimcat" ]]; then
  echo "FAIL: install_cli=false created a link" >&2
  exit 1
fi

echo "OK cli_install"
