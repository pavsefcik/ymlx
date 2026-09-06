# ymlx

A small zsh launcher for browsing, running and downloading local MLX LLMs on
Apple Silicon, with a drop-in OpenAI-compatible REST endpoint at
`localhost:11500`.

## Install

The repo ships as a [pi package](https://pi.dev/packages) — install [pi](https://pi.dev) once, then everything else comes from in-pi commands:

```sh
pi install git:github.com/pavsefcik/ymlx
```

Inside pi, run **`/ymlx-setup`** (auto-offered on first launch): it installs
`uv`, `gum` and `mlx-vlm` (Xcode CLT and Homebrew are the only manual steps),
copies `ymlx.zsh` to a stable directory, and wires a headless wrapper. Then
**`/ymlx-sync`** and pick a model via `/model` — it starts and switches ymlx to
the selected model automatically, all offline.

Prefer ymlx standalone (no pi)? `git clone` the repo and run `sh install.sh`
— same deps, plus the pi extension and wrapper. It adds the
`ymlx-launcher.zsh` source line to `~/.zshrc`, so `ymlx` is available in any
new shell.

### Standalone — one line (curl)

Installs to `~/.ymlx` (`YMLX_DIR` to override) and wires the launcher into `~/.zshrc`:

```sh
curl -fsSL https://raw.githubusercontent.com/pavsefcik/ymlx/main/install.sh | sh
```

### Standalone — Homebrew (tap)

```sh
brew tap pavsefcik/ymlx
brew install ymlx
```

The formula brings `gum` + `uv`; run
`sh "$(brew --prefix)/opt/ymlx/libexec/install.sh"` once — it installs the
`mlx-vlm` tool and adds the launcher to `~/.zshrc`. Then open a new terminal
and run `ymlx`.

## Use

- One model at a time on `:11500` — Enter starts it and drops straight into chat
- `tab` toggles thinking per request · `esc` stops generation · `^s` stops server
- Download from a curated list ([ymlx-curator](https://github.com/pavsefcik/ymlx-curator),
  filtered to your RAM tier) or paste any HuggingFace id
- Drop-in OpenAI endpoint for other apps — from the **Use from another app**
  screen: base URL `http://localhost:11500/v1`, model = HF id of the running
  model, API key not required

## Configuration

**Basic settings** — thinking (default/on/off), temperature, max tokens, system
prompt. **Advanced settings** — every `mlx_vlm` flag (`--kv-bits`,
`--draft-model`, adapters, extra model slots, …). Everything persists in
`~/.cache/ymlx/config.zsh`.

## Updates

ymlx checks GitHub for a newer version at every launch; when one exists a
`▲ Update available: X.Y.Z → A.B.C` banner appears and the menu gains an
**Update to latest version** entry that pulls and reinstalls in place (a
pi-managed install instead guides you to `pi update`). Installed version lives
in the repo-root `VERSION` file (semver, currently 0.1.0).
