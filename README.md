# ymlx

A small zsh launcher for browsing, running, and downloading local MLX LLMs on Apple Silicon.
Exposes an OpenAI-compatible REST API at `localhost:11500`.

## What it does

- Lists installed models from `~/.cache/huggingface/hub` with per-model disk size and a running total
- Runs the selected model on `:11500` via `mlx-lm` — one model at a time
- **Swap** replaces the active model without touching the URL — your other apps stay configured
- Three-phase loading spinner (initialize → load weights → warm up); cancellable mid-load
- Built-in chat REPL with optional `<think>` tag hiding
- Copy-paste **Use from another app** screen showing base URL / model id / API key
- Downloads new models — curated list filtered to your machine's RAM tier, or a pasted HuggingFace ID
- Cleans up automatically — closing the terminal tab stops the running server

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

## Use from another app

Once a model is running, pick **Use from another app** in the running-model submenu for a copy-pasteable summary. Three values are all most apps need:

- **Base URL:** `http://localhost:11500/v1`
- **Model:** the HuggingFace id of whatever is running (e.g. `mlx-community/Qwen3.5-4B-MLX-4bit`)
- **API key:** not required — use any non-empty string if a client demands one

ymlx is a drop-in OpenAI-compatible endpoint, so anything that talks to OpenAI works against ymlx after changing those three values. To point the same URL at a different model, pick the new model in ymlx and choose **Swap** — the URL stays the same.

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

---

## Expert mode

Turn on **Settings → Turn on expert mode** to unlock multi-server workflows and raw mlx-lm commands. ymlx stops pinning to `:11500` — each launch picks the next free port in `11500–11519`.

The installed-model submenu grows:

- `Start mlx_lm.server on port 11500` / `Swap mlx_lm.server on port 11500` — same intent as standard mode, with the underlying command exposed.
- `Run mlx_lm.server on port 115xx` — when `:11500` is taken, spawn an *additional* concurrent server on the next free port.
- `Run mlx_lm.chat` / `Run mlx_lm.generate` — invoke the raw mlx-lm CLIs directly.
- `Copy name`, `Delete`.

The running-server submenu adds **Restart**, **Tail logs**, **Server details**, and **Copy name**. The main menu gains a **Stop All** entry.

### Connect agentic CLI (crush etc.)

Settings gains a **Connect agentic CLI** entry that prints connection snippets and offers to sync `~/.config/crush/crush.json` with your installed models. crush requires `models[]` declared explicitly — it does not auto-discover from `/v1/models` — so the sync rewrites the `ymlx` provider's model list:

```jsonc
// ~/.config/crush/crush.json — after sync
{
  "providers": {
    "ymlx": {
      "name": "ymlx (local MLX)",
      "base_url": "http://localhost:11500/v1/",
      "type": "openai-compat",
      "api_key": "dummy",
      "models": [ /* populated by ymlx */ ]
    }
  }
}
```

Re-run the sync after downloading new models. Other agentic CLIs (aider, Continue, OpenAI SDK clients) just need the three values from **Use from another app** — no list to maintain.
