# ymlx

A small zsh launcher for browsing, running, and downloading local MLX LLMs on Apple Silicon.
Exposes an OpenAI-compatible REST API at `localhost:11500`.

## What it does

- Lists installed models from `~/.cache/huggingface/hub`
- Runs the selected model on `:11500` via `mlx-vlm` — one model at a time; Enter starts it and drops straight into chat
- Three-phase loading spinner (initialize → load weights → warm up); cancellable mid-load
- Built-in chat REPL; `tab` toggles thinking per-request (sent as `enable_thinking`, so it actually turns reasoning on/off), thinking renders dim/gray and the answer white, `esc` stops generation
- Chat history viewer in the main menu
- Copy-paste **Use from another app** screen showing base URL / model id / API key (shown after launch)
- Downloads new models — curated list filtered to your machine's RAM tier, or a pasted HuggingFace ID
- Cleans up automatically — closing the terminal tab stops the running server

## Requirements

- Apple Silicon Mac (MLX is Apple Silicon only)
- [`uv`](https://github.com/astral-sh/uv) — provides `uvx`, used to fetch `mlx-vlm` on demand
- [`gum`](https://github.com/charmbracelet/gum) — interactive menus
- [`mlx-vlm`](https://github.com/Blaizzy/mlx-vlm) — running chat/server uses `mlx_vlm.chat` and `mlx_vlm.server` directly. Unlike `mlx-lm`, it also serves multimodal models: curated models tagged `vision`/`audio` accept image/audio content over the same endpoint.

Install the CLI tools — either run the bundled bootstrap (handles everything below, including a PATH fix for `~/.local/bin`):

```sh
zsh install.zsh
```

…or install by hand (same result):

```sh
brew install uv gum && uv tool install mlx-vlm --with jinja2
```

(`--with jinja2` is required: mlx-vlm's `apply_chat_template` needs it for every chat request, and mlx-vlm's own requirements don't declare it.)

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

## Use from Pi (coding agent)

The repo ships as a [pi package](https://pi.dev/packages): the `ymlx-sync` extension keeps pi's model list in sync with what's actually in the HF hub cache, and starts/switches ymlx to the selected model headlessly. No hand-maintained `models.json` needed — the extension registers everything.

Install pi, then:

```sh
npm i -g @earendil-works/pi-coding-agent
pi install git:github.com/pavsefcik/ymlx
```

Then inside pi:

1. **`/ymlx-setup`** — one-time install/repair: uv + gum via brew, `mlx-vlm` (+jinja2) via uv tool, copies `ymlx.zsh` to `~/.local/share/ymlx`, writes the `~/.pi/agent/bin/ymlx` wrapper. Auto-offered on first launch if ymlx isn't wired in yet. (Xcode CLT is the only manual step.)
2. **`/ymlx-sync`** — scans `~/.cache/huggingface/hub` and re-registers the `local` provider with what's downloaded.
3. **`/model`** → pick a model under **Local MLX (ymlx)** — pi runs `ymlx run <model-id>` headless and talks to `http://localhost:11500/v1`.

`/reload` after any change to the extension file. No ymlx in the hub cache yet? Run `ymlx` and use **Download new model**.

Alternative install: `git clone` + `zsh install.zsh` — it also copies the extension and generates the wrapper (with your clone's path baked in), so you only need `/reload` inside pi.

Environment knobs (all optional): `YMLX_PI_PROVIDER` (provider name, default `local`), `YMLX_HUB_DIR`, `YMLX_BIN`, `YMLX_REPO`, `YMLX_ZSH`, `YMLX_STABLE_DIR`.

Why thinking works: the extension registers models with `reasoning: true` and `thinkingFormat` so pi sends a top-level `enable_thinking` per request — the exact field `mlx_vlm.server` reads — so Shift+Tab in pi turns thinking on/off per request. Note that per-request `enable_thinking` overrides ymlx's server-side `--enable-thinking`, so pi's toggle wins over the Basic-settings Thinking value; set the menu value to `default` if you want pi to fully own thinking.

## Configuration

Pick **Basic settings** from the main menu for the four quick toggles you'll actually flip between sessions:

- **Thinking** — `default` / `on` / `off` (adds/removes server-side `--enable-thinking`; the chat REPL and Pi still force it per request)
- **Temperature** — preset (0.0 / 0.3 / 0.7 / 1.0) or custom
- **Max tokens** — preset (512 / 2048 / 8192 / 32768) or custom
- **System prompt** — multi-line `gum write` editor; chat only

These persist in a managed block at the top of `~/.cache/ymlx/config.zsh` (auto-created on first run; Thinking starts at `off` since it's the value most users want). Basic settings is in the main menu, so it's always one keystroke away. In the main menu, navigate with ↑/↓, press Enter to start or chat, Tab to toggle thinking, `^s` to stop the running server, `^d` to delete the selected model, and `^q` (or Esc) to quit.

Selecting **Advanced settings** opens the config file in your editor — `micro` if installed, otherwise `nano`, then `$VISUAL` / `$EDITOR`, finally `vi`. Below the managed block live two arrays, `YMLX_CHAT_FLAGS` and `YMLX_SERVER_FLAGS`, with every flag from `mlx_vlm.chat --help` / `mlx_vlm.server --help` listed (commented out by default): `--draft-model`, `--kv-bits` / `--kv-quant-scheme`, thinking budget & start/end token flags, adapter paths, and extra model slots (`--image-model`, `--tts-model`, `--stt-model`, `--embedding-model`, `--reranker-model`), etc. `--model`, `--port`, and `--host` stay managed by ymlx. Changes take effect immediately on save — no ymlx restart needed. Use **Restart and refresh** to apply flag changes to a running model, or **Open models folder** to browse `~/.cache/huggingface/hub` in Finder.

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
