# ymlx

A small zsh launcher for browsing, running, and downloading local MLX LLMs on Apple Silicon.
Exposes an OpenAI-compatible REST API at `localhost:11500`.

## What it does

- Lists installed models from `~/.cache/huggingface/hub`
- Runs the selected model on `:11500` via `mlx-lm` — one model at a time; Enter starts it and drops straight into chat
- Three-phase loading spinner (initialize → load weights → warm up); cancellable mid-load
- Built-in chat REPL; `tab` toggles thinking per-request (sent as `enable_thinking`, so it actually turns reasoning on/off), thinking renders dim/gray and the answer white, `esc` stops generation
- Chat history viewer in the main menu
- Copy-paste **Use from another app** screen showing base URL / model id / API key (shown after launch)
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

Once a model is running, ymlx prints a **Use from another app** summary after launch. Three values are all most apps need:

- **Base URL:** `http://localhost:11500/v1`
- **Model:** the HuggingFace id of whatever is running (e.g. `mlx-community/Qwen3.5-4B-MLX-4bit`)
- **API key:** not required — use any non-empty string if a client demands one

ymlx is a drop-in OpenAI-compatible endpoint, so anything that talks to OpenAI works against ymlx after changing those three values. To point the same URL at a different model, stop the running one (^s) and start the new model — the URL stays the same.

### Use from Pi (coding agent)

Point [pi](https://pi-coding.org) at the same endpoint by adding a provider to `~/.pi/agent/models.json` (create the file if missing):

```json
{
  "providers": {
    "ymlx": {
      "baseUrl": "http://localhost:11500/v1",
      "api": "openai-completions",
      "apiKey": "local",
      "compat": {
        "supportsDeveloperRole": false,
        "supportsReasoningEffort": false,
        "thinkingFormat": "qwen-chat-template"
      },
      "models": [
        {
          "id": "<hf-id-of-the-running-model>",
          "name": "Local MLX (ymlx)",
          "reasoning": true,
          "input": ["text"],
          "contextWindow": 131072,
          "maxTokens": 8192,
          "cost": { "input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0 },
          "thinkingLevelMap": { "off": "off", "low": "on", "high": "on" }
        }
      ]
    }
  }
}
```

The `reasoning: true` + `thinkingFormat: "qwen-chat-template"` pair is what makes the thinking toggle work: Pi then sends `chat_template_kwargs.enable_thinking` (and `preserve_thinking`) per request — the exact knob `mlx_lm.server` reads — so `Shift+Tab` in Pi turns thinking on/off per request. Note that per-request `chat_template_kwargs` override ymlx's server-side `--chat-template-args`, so Pi's toggle wins over the Basic-settings Thinking value; set the menu value to `default` if you want Pi to fully own thinking.

## Configuration

Pick **Basic settings** from the main menu for the four quick toggles you'll actually flip between sessions:

- **Thinking** — `default` / `on` / `off` (sets `--chat-template-args '{"enable_thinking": …}'` for chat and server)
- **Temperature** — preset (0.0 / 0.3 / 0.7 / 1.0) or custom
- **Max tokens** — preset (512 / 2048 / 8192 / 32768) or custom
- **System prompt** — multi-line `gum write` editor; chat only

These persist in a managed block at the top of `~/.cache/ymlx/config.zsh` (auto-created on first run; Thinking starts at `off` since it's the value most users want). Basic settings is in the main menu, so it's always one keystroke away. In the main menu, navigate with ↑/↓, press Enter to start or chat, Tab to toggle thinking, `^s` to stop the running server, `^d` to delete the selected model, and `^q` (or Esc) to quit.

Selecting **Advanced settings** opens the config file in your editor — `micro` if installed, otherwise `nano`, then `$VISUAL` / `$EDITOR`, finally `vi`. Below the managed block live two arrays, `YMLX_CHAT_FLAGS` and `YMLX_SERVER_FLAGS`, with every flag from `mlx_lm.chat --help` / `mlx_lm.server --help` listed (commented out by default): `--draft-model`, `--seed`, `--top-k` / `--min-p`, `--xtc-*`, concurrency knobs, adapter paths, etc. `--model`, `--port`, and `--host` stay managed by ymlx. Changes take effect immediately on save — no ymlx restart needed. Use **Restart and refresh** to apply flag changes to a running model, or **Open models folder** to browse `~/.cache/huggingface/hub` in Finder.

## Curated model list

The "Download new model" submenu is populated from [ymlx-curator](https://github.com/pavsefcik/ymlx-curator), a standalone repo that keeps the list up to date even when ymlx itself isn't. ymlx pulls the latest [`ymlx-curator.md`](https://github.com/pavsefcik/ymlx-curator/blob/main/ymlx-curator.md) from GitHub at every startup and caches it in `~/.cache/ymlx/curated-llms.md` (the last good copy is used if you're offline). To add or remove entries, edit the file in the ymlx-curator repo.

Format: blank-line-separated 2-line blocks under a tier header. The first line is the HuggingFace id used for downloading, and the second is the tag list shown in the menu.

```
8 GB RAM Tier Models

mlx-community/Qwen3.5-4B-MLX-4bit
vision, reasoning

mlx-community/gemma-4-e4b-it-4bit
vision, audio


16 GB RAM Tier Models

...
```

Tier headers are any line matching `GB RAM` (e.g. `if 16 GB RAM:`). The menu adapts to the machine's RAM (read via `sysctl hw.memsize`):

- ≤ 8 GB: only the 8 GB tier is shown
- 16 / 18 GB: 16 GB tier shown, 8 GB tier dimmed
- ≥ 24 GB: 24 GB tier shown, 16 GB tier dimmed, 8 GB hidden

Models already present in `~/.cache/huggingface/hub` are filtered out of the list. The last entry is always a "Custom (paste HuggingFace ID)…" option for anything off-list.
