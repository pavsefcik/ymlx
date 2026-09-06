/**
 * ymlx-sync — keeps pi's list of local MLX models in sync with what's actually
 * downloaded in the Hugging Face hub cache, and starts/switches ymlx to the
 * selected local model on :11500.
 *
 * Distributed as part of the ymlx repo (a pi package):
 *
 *   pi install git:github.com/pavsefcik/ymlx
 *
 * or copied into ~/.pi/agent/extensions/ymlx-sync.ts — `zsh install.zsh` from a
 * clone does the copy and generates the ~/.pi/agent/bin/ymlx wrapper for you.
 * Hot-reload with /reload. The factory runs on every pi start and /reload.
 *
 * Commands:
 *   /ymlx-sync   re-scan the HF hub cache and re-register the "local" provider
 *   /ymlx-setup  install/repair ymlx + deps (uv, gum, mlx-vlm via brew) and wire
 *                pi → ymlx: copy ymlx.zsh to ~/.local/share/ymlx (a stable dir,
 *                because pi resets git-package checkouts on update) and write the
 *                ~/.pi/agent/bin/ymlx wrapper. Also offered automatically on
 *                session start when ymlx isn't wired in yet.
 *
 * Discovery: scans ~/.cache/huggingface/hub for `models--*` directories and
 * re-registers the local provider via `pi.registerProvider(..., { models })`,
 * exactly like ymlx's own enumerator (`models--ORG--NAME` -> `ORG/NAME`). So
 * /model, Ctrl+P cycling and `pi --list-models` always show what's on disk.
 *
 * Selection: on `model_select`, if the newly selected model belongs to the local
 * MLX provider, runs `ymlx run <model-id>` headless (blocking until the server
 * is ready) so pi's next request hits the right model. Each registered model
 * carries pi-ai `compat` (system role, no reasoning_effort, qwen-chat-template
 * thinking) so requests match what mlx_vlm.server expects.
 *
 * Environment (all optional):
 *   YMLX_PI_PROVIDER  provider name in pi's catalog (default "local")
 *   YMLX_HUB_DIR      HF hub cache dir        (default ~/.cache/huggingface/hub)
 *   YMLX_BIN          wrapper path            (default ~/.pi/agent/bin/ymlx)
 *   YMLX_REPO         ymlx repo root          (default: pi's git-package clone)
 *   YMLX_ZSH          explicit path to ymlx.zsh
 *   YMLX_STABLE_DIR   dir ymlx.zsh is copied to (default ~/.local/share/ymlx)
 */

import { execFile } from "node:child_process";
import { constants as FS_CONST } from "node:fs";
import {
  access,
  copyFile,
  mkdir,
  readFile,
  readdir,
  writeFile,
} from "node:fs/promises";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import { promisify } from "node:util";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

const execFileP = promisify(execFile);

// Provider name for ymlx in pi's model catalog (defaults to "local", matching models.json).
const YMLX_PROVIDER = process.env.YMLX_PI_PROVIDER ?? "local";
// Wrapper that executes the real ymlx.zsh headlessly. install.zsh writes this;
// /ymlx-setup can too.
const WRAPPER =
  process.env.YMLX_BIN ?? join(homedir(), ".pi", "agent", "bin", "ymlx");
// Where ymlx keeps its downloaded MLX models (Hugging Face hub cache).
const HUB_DIR =
  process.env.YMLX_HUB_DIR ?? join(homedir(), ".cache", "huggingface", "hub");
// Stable copy target for ymlx.zsh + lib/: pi git-packages get reset on
// `pi update --extensions`, so the wrapper must never point into the package
// clone. install.zsh points the wrapper at the repo directly (fine — it's the
// user's own clone); /ymlx-setup copies into this dir instead.
const YMLX_STABLE =
  process.env.YMLX_STABLE_DIR ?? join(homedir(), ".local", "share", "ymlx");
// Where the pi git-package clone lands when installed via
// `pi install git:github.com/pavsefcik/ymlx` (docs/packages.md).
const YMLX_CLONE = join(
  homedir(),
  ".pi",
  "agent",
  "git",
  "github.com",
  "pavsefcik",
  "ymlx"
);
const LOAD_TIMEOUT_MS = 25 * 60 * 1000; // matches ymlx's readiness loop

const ZERO_COST = { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 };

interface LocalModel {
  id: string;
  name: string;
  reasoning: boolean;
  input: ("image" | "text")[];
  contextWindow: number;
  maxTokens: number;
  cost: typeof ZERO_COST;
  thinkingLevelMap: { off: string; low: string; high: string };
  compat: {
    supportsDeveloperRole: false;
    supportsReasoningEffort: false;
    thinkingFormat: "qwen-chat-template";
  };
}

interface SetupUI {
  setStatus(key: string, value: string): void;
  notify(message: string, type?: "error" | "info" | "warning"): void;
}

/* ------------------------------------------------------------------ */
/* Small helpers                                                      */
/* ------------------------------------------------------------------ */

async function pathOk(p: string | undefined, mode = FS_CONST.R_OK): Promise<boolean> {
  if (!p) return false;
  try {
    await access(p, mode);
    return true;
  } catch {
    return false;
  }
}

/** Whether a command is available on PATH. */
async function onPath(cmd: string): Promise<boolean> {
  try {
    await execFileP("sh", ["-c", `command -v ${cmd}`]);
    return true;
  } catch {
    return false;
  }
}

function errMsg(err: unknown): string {
  const e = err as { stderr?: string; stdout?: string; message?: string };
  return e.stderr?.trim() || e.message || String(err);
}

/** First ymlx.zsh we can find: explicit env, then known repo locations. */
async function findYmlxZsh(): Promise<string | undefined> {
  const env = process.env.YMLX_ZSH;
  if (await pathOk(env)) return env;
  const roots = [
    process.env.YMLX_REPO,
    YMLX_CLONE,
    join(homedir(), "Dev", "projects", "ymlx"), // local clone (dev fallback)
  ];
  for (const root of roots) {
    if (!root) continue;
    const zsh = join(root, "ymlx.zsh");
    if (await pathOk(zsh)) return zsh;
  }
  return undefined;
}

async function ensureLocalBinOnPath(ui: SetupUI): Promise<void> {
  if (!(await pathOk(join(homedir(), ".local", "bin", "mlx_vlm.server")))) return;
  const zshrc = join(homedir(), ".zshrc");
  try {
    const cur = await readFile(zshrc, "utf8").catch(() => "");
    if (!cur.includes("local/bin")) {
      await writeFile(zshrc, `${cur}\nexport PATH="$HOME/.local/bin:$PATH"\n`);
      ui.notify("ymlx-setup: appended ~/.local/bin to ~/.zshrc", "info");
    }
  } catch {
    // best effort
  }
}

/**
 * /ymlx-setup — idempotent install/repair:
 *   1. Xcode CLT 2. brew 3. uv+gum 4. mlx-vlm+jinja2 (uv tool)
 *   5. PATH fix 6. stable ymlx.zsh copy + generated wrapper
 */
let setupRunning = false;

async function runSetup(ui: SetupUI): Promise<void> {
  if (setupRunning) {
    ui.notify("ymlx-setup: already running", "info");
    return;
  }
  setupRunning = true;
  const key = "ymlx-setup";
  try {
    ui.setStatus(key, "⟳ ymlx setup…");

    // 1. Xcode CLT — cannot be automated (GUI prompt); fail fast with instructions.
    try {
      await execFileP("xcode-select", ["-p"]);
    } catch {
      ui.notify(
        "ymlx-setup: install Xcode Command Line Tools first — run 'xcode-select --install'",
        "error"
      );
      return;
    }

    // 2. Homebrew (also needs manual install the first time).
    if (!(await onPath("brew"))) {
      ui.notify(
        "ymlx-setup: Homebrew missing — install it first:\n  /bin/bash -c \"$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\"\nthen re-run /ymlx-setup",
        "error"
      );
      return;
    }

    // 3. uv + gum via brew (skipped when already present).
    for (const tool of ["uv", "gum"]) {
      if (await onPath(tool)) continue;
      ui.setStatus(key, `⟳ installing ${tool} (brew)…`);
      try {
        await execFileP("brew", ["install", tool], { timeout: 15 * 60 * 1000 });
      } catch (err) {
        ui.notify(`ymlx-setup: brew install ${tool} failed — ${errMsg(err)}`, "error");
        return;
      }
    }

    // 4. mlx-vlm as a uv tool. Always re-run so jinja2 is guaranteed (mlx-vlm's
    //    apply_chat_template needs it for every request and its own requirements
    //    don't declare it).
    ui.setStatus(key, "⟳ installing mlx-vlm (uv tool)…");
    try {
      await execFileP("uv", ["tool", "install", "mlx-vlm", "--with", "jinja2"], {
        timeout: 15 * 60 * 1000,
      });
    } catch (err) {
      ui.notify(`ymlx-setup: mlx-vlm install failed — ${errMsg(err)}`, "error");
      return;
    }

    // 5. ~/.local/bin on PATH for future shells.
    await ensureLocalBinOnPath(ui);

    // 6. Wire the wrapper (stable copy if we can find a ymlx.zsh source).
    const wired = await wireYmlx(ui);
    if (!wired) return;

    const depsOk = !!(await onPath("gum")) && !!(await onPath("uv")) && !!(await onPath("mlx_vlm.server"));
    ui.notify(
      depsOk
        ? "ymlx-setup: deps + wrapper ready — pick a local model via /model"
        : "ymlx-setup: deps installed — open a new terminal so ~/.local/bin is on PATH, then /model",
      "info"
    );
  } finally {
    ui.setStatus(key, "");
    setupRunning = false;
  }
}

/** Copy ymlx.zsh + lib into the stable dir and (re)generate the wrapper. */
async function wireYmlx(ui: SetupUI): Promise<boolean> {
  const zsh = await findYmlxZsh();
  if (zsh) {
    try {
      await mkdir(join(YMLX_STABLE, "lib"), { recursive: true });
      await copyFile(zsh, join(YMLX_STABLE, "ymlx.zsh"));
      await copyFile(
        join(dirname(zsh), "lib", "ymlx-helpers.zsh"),
        join(YMLX_STABLE, "lib", "ymlx-helpers.zsh")
      );
      // Version lives next to ymlx.zsh (self-update notice reads it); best-effort.
      await copyFile(
        join(dirname(zsh), "VERSION"),
        join(YMLX_STABLE, "VERSION")
      ).catch(() => {});
    } catch (err) {
      ui.notify(`ymlx-setup: failed copying ymlx.zsh → ${YMLX_STABLE} — ${errMsg(err)}`, "error");
      return false;
    }
  } else if (!(await pathOk(WRAPPER))) {
    // No ymlx.zsh anywhere and no existing wrapper (e.g. install.zsh never ran).
    ui.notify(
      "ymlx-setup: can't find ymlx.zsh. Clone it and set YMLX_REPO (or run its install.zsh), or set YMLX_ZSH=/path/to/ymlx.zsh, then /reload and re-run /ymlx-setup.",
      "error"
    );
    return false;
  } else {
    // Existing wrapper (install.zsh generated it, pointing at the user's clone).
    return true;
  }

  const target = join(YMLX_STABLE, "ymlx.zsh");
  const script = [
    "#!/usr/bin/env bash",
    "# Generated by ymlx-sync (/ymlx-setup) — points at the stable copy of ymlx.zsh.",
    "set -euo pipefail",
    `YMLX_ZSH="${target}" exec zsh "${target}" "$@"`,
    "",
  ].join("\n");
  try {
    await mkdir(dirname(WRAPPER), { recursive: true });
    await writeFile(WRAPPER, script, { mode: 0o755 });
  } catch (err) {
    ui.notify(`ymlx-setup: failed writing ${WRAPPER} — ${errMsg(err)}`, "error");
    return false;
  }
  ui.setStatus("ymlx-setup", `✓ wrote ${WRAPPER}`);
  return true;
}

/* ------------------------------------------------------------------ */
/* Model discovery + provider registration                            */
/* ------------------------------------------------------------------ */

/**
 * Discover local MLX models from the HF hub cache. `models--ORG--NAME`
 * directories become `ORG/NAME` model ids, exactly like ymlx's enumerator.
 */
async function discoverModels(): Promise<LocalModel[]> {
  let entries;
  try {
    entries = await readdir(HUB_DIR, { withFileTypes: true });
  } catch {
    return [];
  }

  const models: LocalModel[] = [];
  for (const entry of entries) {
    if (!entry.isDirectory() || !entry.name.startsWith("models--")) continue;
    const id = entry.name.slice("models--".length).replace(/--/g, "/");
    models.push({
      id,
      name: id, // id is the exact string `ymlx run <id>` expects
      reasoning: true,
      input: ["text"],
      contextWindow: 131072,
      maxTokens: 8192,
      cost: ZERO_COST,
      thinkingLevelMap: { off: "off", low: "on", high: "on" },
      // Per-model compat (pi reads model.compat at request time): keep the
      // system prompt as "system" (mlx_vlm.server is OpenAI-shaped), never send
      // reasoning_effort, and route the thinking toggle through
      // chat_template_kwargs.enable_thinking — the field mlx_vlm.server reads.
      compat: {
        supportsDeveloperRole: false,
        supportsReasoningEffort: false,
        thinkingFormat: "qwen-chat-template",
      },
    });
  }
  return models;
}

/** Re-scan the hub cache and re-register the ymlx provider with the models found. */
async function refresh(pi: ExtensionAPI): Promise<LocalModel[]> {
  const models = await discoverModels();
  pi.registerProvider(YMLX_PROVIDER, {
    name: "Local MLX (ymlx)",
    baseUrl: "http://localhost:11500/v1",
    api: "openai-completions",
    apiKey: "local",
    models,
  });
  return models;
}

/* ------------------------------------------------------------------ */
/* Extension entry point                                              */
/* ------------------------------------------------------------------ */

export default async function (pi: ExtensionAPI) {
  // Refresh the available-model list on every pi start and /reload.
  await refresh(pi);

  // Serialize switches so rapid consecutive selections don't stomp each other.
  let chain: Promise<void> = Promise.resolve();

  pi.on("model_select", async (event, ctx) => {
    const { model, source } = event;
    if (model.provider !== YMLX_PROVIDER) return;

    // Session restore just rings the model up; don't force a switch on clean restores.
    if (source === "restore") return;

    const modelId = model.id;
    const ui = ctx.ui;
    const statusKey = "ymlx";

    if (!(await pathOk(WRAPPER))) {
      ui.notify(`ymlx: wrapper ${WRAPPER} missing — run /ymlx-setup first`, "error");
      return;
    }

    const sync = async (): Promise<void> => {
      ui.setStatus(statusKey, `⟳ loading ${modelId}…`);
      try {
        await execFileP(WRAPPER, ["run", modelId], { timeout: LOAD_TIMEOUT_MS });
        ui.notify(`ymlx: ${modelId} ready on :11500`, "info");
      } catch (err) {
        ui.notify(
          `ymlx: failed to start ${modelId} — ${errMsg(err)}`,
          "error"
        );
      } finally {
        ui.setStatus(statusKey, "");
      }
    };

    chain = chain.then(sync, sync);
    await chain; // surface errors so pi doesn't treat the handler as crashed
  });

  // Manual re-sync: re-scan the hub cache and re-register the provider.
  pi.registerCommand("ymlx-sync", {
    description: "Re-scan the HF hub cache and register available local MLX models",
    handler: async (_args, ctx) => {
      const models = await refresh(pi);
      const ids = models.map((m) => m.id).join(", ") || "(none)";
      ctx.ui.notify(`ymlx-sync: registered ${models.length} model(s): ${ids}`, "info");
    },
  });

  // One-shot install/repair of ymlx + deps and the pi→ymlx wiring.
  pi.registerCommand("ymlx-setup", {
    description: "Install/repair ymlx + deps (uv, gum, mlx-vlm via brew) and wire pi → ymlx",
    handler: async (_args, ctx) => {
      await runSetup(ctx.ui);
    },
  });

  // Offer setup once per process when ymlx isn't wired in yet.
  let offered = false;
  pi.on("session_start", async (_event, ctx) => {
    if (offered || !ctx.hasUI) return;
    offered = true;
    if ((await pathOk(WRAPPER)) || (await onPath("ymlx"))) return;
    const yes = await ctx.ui.confirm(
      "ymlx",
      "ymlx isn't wired into pi yet. Run setup now (brew: uv, gum; uv tool: mlx-vlm; writes ~/.pi/agent/bin/ymlx wrapper)?"
    );
    if (yes) await runSetup(ctx.ui);
  });
}