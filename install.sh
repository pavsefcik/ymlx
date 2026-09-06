#!/bin/sh
# ymlx — one-line installer ("curl | sh").
#
# Downloads ymlx into a stable directory ($HOME/.ymlx by default), runs the
# real installer (install.zsh) from there, and sources the launcher from
# ~/.zshrc so the `ymlx` command is available in any shell.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/pavsefcik/ymlx/main/install.sh | sh
#
# Notes
#   - This is a thin bootstrap: install.zsh must run from inside a complete
#     checkout (it resolves its own dir and bakes it into the pi wrapper), so
#     this script materializes the repo first. Piping install.zsh directly
#     through `curl | sh` would break that.
#   - Xcode CLT and Homebrew must be present first; install.zsh fails with a
#     clear message if either is missing.
#
# Environment:
#   YMLX_DIR   install directory           (default: $HOME/.ymlx)
#   YMLX_REF   git ref to fetch            (default: latest release tag, else main)

set -e

repo="pavsefcik/ymlx"
: "${YMLX_DIR:=$HOME/.ymlx}"

step() { printf '\n==> %s\n' "$1"; }
says() { printf '    %s\n' "$1"; }

# Resolve the ref to fetch: prefer the latest GitHub release tag, else main.
ref="${YMLX_REF:-}"
if [ -z "$ref" ]; then
  ref="$(curl -fsSL "https://api.github.com/repos/$repo/releases/latest" 2>/dev/null \
    | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -n 1)"
  [ -n "$ref" ] || ref="main"
fi

# 1. Download ymlx into the install dir unless it is already present.
mkdir -p "$YMLX_DIR"
if [ -f "$YMLX_DIR/ymlx.zsh" ]; then
  step "ymlx already installed in $YMLX_DIR — skipping download (run install.zsh there to update deps)"
else
  step "Downloading ymlx @ $ref into $YMLX_DIR …"
  if [ "$ref" = "main" ]; then
    url="https://github.com/$repo/archive/refs/heads/main.tar.gz"
  else
    url="https://github.com/$repo/archive/refs/tags/$ref.tar.gz"
  fi
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/ymlx.XXXXXX")"
  curl -fsSL "$url" -o "$tmp/src.tar.gz"
  tar -xzf "$tmp/src.tar.gz" -C "$tmp"
  sub="$(find "$tmp" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
  cp -R "$sub/." "$YMLX_DIR/"
  rm -rf "$tmp"
  says "done."
fi

# 2. Run the real installer from the install dir. Its repo dir is resolved from
#    its own location, so it must actually live there (not be piped in).
step "Running install.zsh …"
zsh "$YMLX_DIR/install.zsh"

# 3. Wire the launcher into ~/.zshrc (idempotent) and print next steps.
step "Wiring ymlx into ~/.zshrc …"
if ! grep -q 'ymlx-launcher.zsh' "$HOME/.zshrc" 2>/dev/null; then
  {
    printf '\n# ymlx (installed by install.sh)\n'
    printf 'test -f "%s/ymlx-launcher.zsh" && source "%s/ymlx-launcher.zsh"\n' "$YMLX_DIR" "$YMLX_DIR"
  } >> "$HOME/.zshrc"
  says "appended launcher source to ~/.zshrc"
else
  says "launcher already wired"
fi

step "Done. ymlx is installed in $YMLX_DIR"
says "Open a NEW terminal (or run: source ~/.zshrc), then type: ymlx"
