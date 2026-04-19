# ymlx

A small zsh launcher for browsing, running, and downloading local MLX LLMs on Apple Silicon.

## What it does

- Lists models already cached under `~/.cache/huggingface/hub`
- Runs chat or an OpenAI-compatible server against the selected model via `mlx-lm`
- Downloads new models — either from a curated list or a pasted HuggingFace ID
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

## Curated model list

The "Download new model" submenu is populated from [`curated_LLMs.md`](curated_LLMs.md). Edit that file to add or remove entries.

Format: blank-line-separated 4-line blocks.

```
Title
mlx-community/Some-Model-ID
tag1, tag2
Short description (currently unused by the menu).
```

Tier headers are any line ending with `GB RAM:` (e.g. `If 16 GB RAM:`) and render as separators in the menu. The last menu item is always a manual "Custom (paste HuggingFace ID)…" entry, so you can still grab anything off HuggingFace directly.
