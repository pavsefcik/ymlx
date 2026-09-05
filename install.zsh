#!/usr/bin/env zsh
# ymlx bootstrap — installs everything ymlx needs on a fresh Apple Silicon Mac:
#   Xcode CLT (python3 for the chat REPL), Homebrew, uv, gum, and mlx-vlm.
# Usage:
#   git clone <this repo> && zsh ymlx/install.zsh
# Safe to re-run — each step skips what's already present, and the mlx-vlm step
# is self-healing (it re-runs the tool install with jinja2, so a previous
# install that lacked jinja2 gets repaired).

die() { print -u2 "install.zsh: $*"; exit 1; }

step() { print "\n==> $*"; }
says() { print "    $*"; }

# 1. Xcode Command Line Tools — python3 + compilers, needed by brew and the
#    chat REPL. No brew on a fresh box until this exists.
step "Checking Xcode Command Line Tools…"
if ! xcode-select -p >/dev/null 2>&1; then
  die "Xcode CLT not installed. Run 'xcode-select --install' (GUI prompt), then re-run this script."
else
  says "present ($(xcode-select -p))"
fi

# 2. Homebrew.
step "Checking Homebrew…"
if ! command -v brew >/dev/null 2>&1; then
  die "Homebrew missing — install it first:
    /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\"
  then re-run this script."
else
  says "present ($(brew --version | head -n1))"
fi

# 3. uv + gum via brew (no-op if already installed).
step "Installing uv and gum…"
brew list uv >/dev/null 2>&1 || brew install uv
brew list gum >/dev/null 2>&1 || brew install gum
command -v uv >/dev/null 2>&1 || die "uv not on PATH after install — re-run this script in a new terminal."
command -v gum >/dev/null 2>&1 || die "gum not on PATH after install — re-run this script in a new terminal."
says "uv $(uv --version | awk '{print $2}'), gum $(gum --version 2>/dev/null || echo installed)"

# 4. mlx-vlm as a uv tool. Always re-run so jinja2 is guaranteed: mlx-vlm's
#    apply_chat_template needs jinja2 for every chat request and mlx-vlm's own
#    requirements don't declare it — a plain 'uv tool install mlx-vlm' works
#    until the first chat request, then 500s.
step "Installing mlx-vlm (with jinja2)…"
uv tool install mlx-vlm --with jinja2 || die "uv tool install mlx-vlm failed."

# 5. Make sure uv's bin dir (~/.local/bin) is on PATH for future shells.
step "Checking PATH…"
if ! command -v mlx_vlm.server >/dev/null 2>&1; then
  if [[ -f ~/.local/bin/mlx_vlm.server ]]; then
    if ! grep -q 'local/bin' ~/.zshrc 2>/dev/null; then
      print 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc
      says "appended ~/.local/bin to ~/.zshrc"
    fi
    says "mlx_vlm.server found at ~/.local/bin — open a new terminal before running ymlx."
  else
    die "mlx_vlm.server is not on PATH and not at ~/.local/bin — something went wrong."
  fi
else
  says "mlx_vlm.server on PATH ✓"
fi

# 6. Final verification.
step "Verifying…"
local ok=1
for c in gum uv mlx_vlm.server; do
  command -v "$c" >/dev/null 2>&1 || { says "MISSING: $c"; ok=0; }
done
(( ok )) && says "all tools present ✓"
if command -v mlx_vlm.server >/dev/null 2>&1 && \
   uvx --from mlx-vlm --with jinja2 python3 -c "import jinja2" >/dev/null 2>&1; then
  says "mlx-vlm + jinja2 importable ✓"
fi

print "\nDone. Add to ~/.zshrc and run:"
print "  source /path/to/ymlx/ymlx-launcher.zsh"
print "  ymlx"