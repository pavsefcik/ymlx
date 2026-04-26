# ymlx

A small zsh launcher for browsing, running, and downloading local MLX LLMs on Apple Silicon.

## What it does

- Lists installed models from `~/.cache/huggingface/hub` with per-model disk size and a running total
- Runs chat or an OpenAI-compatible server against the selected model via `mlx-lm`
- Manages multiple concurrent servers — each gets a fresh port in 11500–11519
- Shows running servers with their port, live RAM usage, and pid
- Per-server actions: **Restart**, **Stop**, **Tail logs** (`q` to return), **Copy name**
- Three-phase loading spinner (initialize → load weights → warm up); cancellable mid-load
- Cleans up automatically — closing the terminal tab stops every server it started
- Downloads new models — curated list filtered to your machine's RAM tier, or a pasted HuggingFace ID
- Opens the local hub folder in Finder

## Requirements

- Apple Silicon Mac (MLX is Apple Silicon only)
- [`uv`](https://github.com/astral-sh/uv) — provides `uvx`, used to fetch `mlx-lm` on demand
- [`gum`](https://github.com/charmbracelet/gum) — interactive menus
- [`mlx-lm`](https://github.com/ml-explore/mlx-lm) — running chat/server uses `mlx_lm.chat` and `mlx_lm.server` directly.

Install the CLI tools:

```sh
brew install uv gum && uv tool install mlx-lm
```

## Install

Source the launcher from your `~/.zshrc`:

```sh
source /path/to/ymlx/ymlx-launcher.zsh
```

Then run `ymlx` in any shell.

## Configuration

Pick **Settings** from the main menu for the four quick toggles you'll actually flip between sessions:

- **Thinking** — `default` / `on` / `off` (sets `--chat-template-args '{"enable_thinking": …}'` for chat and server)
- **Temperature** — preset (0.0 / 0.3 / 0.7 / 1.0) or custom
- **Max tokens** — preset (512 / 2048 / 8192 / 32768) or custom
- **System prompt** — multi-line `gum write` editor; chat only

These persist in a managed block at the top of `~/.cache/ymlx/config.zsh` (auto-created on first run; Thinking starts at `off` since it's the value most users want). Settings is the first item in the main menu and in every per-model action menu, so it's always one keystroke away.

Selecting **Advanced settings** inside Settings opens the config file in your editor — `micro` if installed, otherwise `nano`, then `$VISUAL` / `$EDITOR`, finally `vi`. Below the managed block live two arrays, `YMLX_CHAT_FLAGS` and `YMLX_SERVER_FLAGS`, with every flag from `mlx_lm.chat --help` / `mlx_lm.server --help` listed (commented out by default): `--draft-model`, `--seed`, `--top-k` / `--min-p`, `--xtc-*`, concurrency knobs, adapter paths, etc. `--model`, `--port`, and `--host` stay managed by ymlx. Changes take effect immediately on save — no ymlx restart needed.

## Curated model list

The "Download new model" submenu is populated from [`curated-llms.md`](curated-llms.md). Edit that file to add or remove entries.

Format: blank-line-separated 2-line blocks under a tier header.

```
if 8 GB RAM:

mlx-community/Some-Model-ID
tag1, tag2

mlx-community/Another-Model-ID
tag1, tag2


if 16 GB RAM:

...
```

Tier headers are any line matching `GB RAM` (e.g. `if 16 GB RAM:`). The menu adapts to the machine's RAM (read via `sysctl hw.memsize`):

- ≤ 8 GB: only the 8 GB tier is shown
- 16 / 18 GB: 16 GB tier shown, 8 GB tier dimmed
- ≥ 24 GB: 24 GB tier shown, 16 GB tier dimmed, 8 GB hidden

Models already present in `~/.cache/huggingface/hub` are filtered out of the list. The last entry is always a "Custom (paste HuggingFace ID)…" option for anything off-list.
