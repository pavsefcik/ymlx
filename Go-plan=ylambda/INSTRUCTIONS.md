# ymlx — Go Rewrite: Claude Code Instructions

## Project Overview

Rewrite `ymlx` from Zsh to Go. `ymlx` is an interactive terminal launcher for
local MLX language models on Apple Silicon. The Go version replaces the `gum`
dependency with a native Bubble Tea TUI, adds a model manager with RAM-aware
swapping, and lays groundwork for a Python sidecar (future).

Reference projects for TUI style and structure:
- https://github.com/charmbracelet/bubbletea (framework)
- https://github.com/charmbracelet/crush (architecture inspiration — note its `internal/` layout)

---

## Target File Structure

```
ymlx/
├── main.go                        # entry point, program bootstrap
├── models.go                      # local model discovery from HF hub cache
├── run.go                         # subprocess wrappers (chat, server, download, open)
├── internal/
│   ├── catalog/
│   │   ├── catalog.go             # curated_LLMs.md parser → []Section
│   │   └── catalog_test.go
│   ├── manager/
│   │   ├── manager.go             # model lifecycle: start, stop, swap
│   │   ├── registry.go            # loaded model state + RAM tracking
│   │   └── manager_test.go
│   ├── setup/
│   │   └── setup.go               # dependency bootstrap: uv, mlx-lm, mlx-vlm
│   └── sidecar/
│       └── sidecar.go             # stub: future Python FastAPI sidecar lifecycle
│   └── ui/
│       ├── app.go                 # root Bubble Tea model, view switcher
│       ├── menu.go                # main menu model (Model/Init/Update/View)
│       ├── action.go              # action menu for a selected model
│       ├── download.go            # download flow (curated list + custom input)
│       └── styles.go              # lipgloss styles, colour palette
├── curated_LLMs.md                # embedded at compile time
├── README.md
├── go.mod
└── go.sum
```

**Delete:** `ymlx.zsh`, `ymlx-launcher.zsh`

---

## Dependencies

```
github.com/charmbracelet/bubbletea v1.3.10
github.com/charmbracelet/bubbles   (transitively pulled — use for list, textinput, spinner)
github.com/charmbracelet/lipgloss  (transitively pulled — use for all styling)
```

Module name: `github.com/pavsefcik/ymlx`

Bootstrap:
```bash
go mod init github.com/pavsefcik/ymlx
go get github.com/charmbracelet/bubbletea@v1.3.10
go mod tidy
```

---

## Startup Flow (before TUI launches)

Before the Bubble Tea TUI starts, `main.go` calls `setup.EnsureDeps()` which
runs in plain terminal output (not inside the TUI). This gives the user visible
feedback during potentially slow installs.

### internal/setup/setup.go

```
Checking dependencies...
  ✓ uv found
  ✗ mlx-lm not installed → installing via uv tool...
  [streaming uv output]
  ✓ mlx-lm ready
  ✓ mlx-vlm ready
Launching ymlx...
[TUI starts]
```

**Dependency resolution order:**

1. **Check for `uv`** (`exec.LookPath("uv")`):
   - If missing → check for Homebrew (`exec.LookPath("brew")`):
     - If brew present → `brew install uv` (streamed to stdout)
     - If brew absent → `curl -LsSf https://astral.sh/uv/install.sh | sh` (streamed to stdout)
2. **Check for `mlx-lm`** (`uv tool list` output contains `mlx-lm`):
   - If missing → `uv tool install mlx-lm` (streamed to stdout)
3. **Check for `mlx-vlm`** (`uv tool list` output contains `mlx-vlm`):
   - If missing → `uv tool install mlx-vlm` (streamed to stdout)

```go
package setup

// EnsureDeps checks and installs uv, mlx-lm, mlx-vlm as needed.
// All output is streamed directly to os.Stdout/os.Stderr (plain terminal, not TUI).
// Returns an error only if a required dep cannot be installed.
func EnsureDeps() error
```

**Notes:**
- Use `stream()` from `run.go` (or an equivalent local helper) for all installs
  so the user sees live output.
- Print a ✓ / ✗ status line before each check using `fmt.Println`.
- If any step fails, return a descriptive error; `main.go` prints it and exits
  with code 1 before launching the TUI.
- MLX tooling (`mlx-lm`, `mlx-vlm`) lives in the global `uv tool` environment —
  no per-project venv needed for them. Future Python sidecar tools go in `.venv/`.

---

## Key Structs

### internal/catalog/catalog.go

**curated_LLMs.md format** — 4-line blocks separated by blank lines, under RAM tier headers.
The file begins with a header block (`Title / Source / Tags / Description`) that must be
silently skipped (treat any block whose first line does not start with a known prefix as a
header and discard it, or simply skip until the first `"GB RAM"` line is encountered).

```
Title
Source
Tags
Description


8 GB RAM Tier Models

Qwen 3.5 4B
mlx-community/Qwen3.5-4B-MLX-4bit
vision, reasoning
The benchmark king at small scale. Leads small-model benchmarks…

Ministral 3 3B
mlx-community/Ministral-3-3B-Reasoning-2512-4bit
vision, reasoning
Surprisingly sharp for its size…
```

Parsing rules:
- Lines containing `"GB RAM"` → new Section header; parse the leading integer as `RAMReq`
- Blank lines reset the 4-line block counter
- Lines before the first `"GB RAM"` line are silently skipped (file header block)
- Line 1 of each block → Title (human-readable short name, e.g. "Qwen 3.5 4B")
- Line 2 of each block → HFID (e.g. "mlx-community/Qwen3.5-4B-MLX-4bit")
- Line 3 of each block → Tags (e.g. "vision, reasoning")
- Line 4 of each block → Desc (one-sentence description)

```go
type Section struct {
    Header  string   // e.g. "8 GB RAM Tier Models"
    RAMReq  int      // parsed GB value, e.g. 8, 16, 24
    Models  []Model
}

type Model struct {
    Title string   // "Qwen 3.5 4B"
    HFID  string   // "mlx-community/Qwen3.5-4B-MLX-4bit"
    Tags  string   // "vision, reasoning"
    Desc  string   // "The benchmark king at small scale…"
}

func Parse(data []byte) ([]Section, error)
```

### internal/catalog/catalog_test.go

Tests must cover:
- Correct section count (3 sections for the bundled file)
- Correct model counts per section
- Correct Title, HFID, Tags, and Desc values for at least one model per section
- File header block (`Title / Source / Tags / Description`) is silently dropped
- Empty input returns empty slice, nil error

### models.go

```go
type LocalModel struct {
    DisplayName string  // "mlx-community/Qwen3.5-9B-MLX-4bit"
    DirPath     string  // full path to the models-- directory
}

func ListLocalModels(hubDir string) ([]LocalModel, error)
func dirToDisplayName(s string) string  // strip "models--" prefix, replace "--" with "/"
```

- `os.ReadDir(hubDir)`, filter `strings.HasPrefix(name, "models--")`
- `dirToDisplayName`: `strings.TrimPrefix` + `strings.ReplaceAll("--", "/")`

### internal/manager/registry.go

```go
type LoadedModel struct {
    ModelID   string
    Process   *os.Process
    Port      int
    StartedAt time.Time
    LastUsed  time.Time
    SizeGB    float64
}

type Registry struct {
    mu     sync.Mutex
    models map[string]*LoadedModel
}
```

### internal/manager/manager.go

```go
type Manager struct {
    registry    *Registry
    availableGB float64
    mu          sync.Mutex
}

// Swap ensures modelID is running:
// 1. already running → update LastUsed, return nil
// 2. enough RAM → start alongside existing
// 3. not enough RAM → kill LRU model, then start
// 4. poll /health on the new process port until ready or timeout
func (m *Manager) Swap(ctx context.Context, modelID string) error

// MonitorRAM runs as a goroutine on a ticker.
// Parses `vm_stat` output, updates m.availableGB.
// Triggers LRU eviction if memory pressure crosses threshold.
func (m *Manager) MonitorRAM(ctx context.Context, interval time.Duration)

func (m *Manager) StopAll() error
```

### internal/sidecar/sidecar.go

```go
// Stub — implement in a future phase when the Python tool layer is added.
type Sidecar struct {
    cmd  *exec.Cmd
    port int
}

func Start(uvPath string) (*Sidecar, error)
func (s *Sidecar) Health() bool
func (s *Sidecar) Stop() error
```

---

## Implementation Steps

### Step 1 — Scaffold

```bash
go mod init github.com/pavsefcik/ymlx
go get github.com/charmbracelet/bubbletea@v1.3.10
go mod tidy
```

Create all files as empty stubs so the module compiles from the start.

### Step 2 — internal/setup/setup.go

Implement `EnsureDeps()` as described in the Startup Flow section above.
This runs before the TUI and streams all output directly to the terminal.

### Step 3 — internal/catalog/catalog.go

Parse `curated_LLMs.md` into `[]Section`:
- Skip all lines before the first `"GB RAM"` line (file header block)
- Lines containing `"GB RAM"` → new Section; parse the leading integer as `RAMReq`
- Blank lines reset a 4-line block counter
- Line 1 of each block → Title
- Line 2 of each block → HFID
- Line 3 of each block → Tags
- Line 4 of each block → Desc

### Step 4 — internal/catalog/catalog_test.go

See test coverage requirements in the Key Structs section above.

### Step 5 — models.go

Implement `ListLocalModels` and `dirToDisplayName` as described above.

### Step 6 — run.go

All subprocess calls use a single `stream()` helper:

```go
func stream(name string, args ...string) error {
    cmd := exec.Command(name, args...)
    cmd.Stdin, cmd.Stdout, cmd.Stderr = os.Stdin, os.Stdout, os.Stderr
    return cmd.Run()
}

func RunChat(modelID string) error
    // mlx_lm.chat --model <modelID> --max-tokens 2048 --temp 0.7 --top-p 0.9

func RunServer(modelID string) error
    // mlx_lm.server --model <modelID>

func Download(hfID string) error
    // uvx --from mlx-lm python3 -c "from mlx_lm import load; load('<hfID>')"

func OpenFolder(path string) error
    // exec.Command("open", path).Run()

func CopyToClipboard(text string) error
    // pipes text into pbcopy
```

### Step 7 — internal/manager/registry.go + manager.go

Implement Registry and Manager as specified above.
`MonitorRAM` must parse `vm_stat` via `exec.Command("vm_stat")` — no external
dependencies. Run it as a goroutine started in main, cancelled via context on
exit.

### Step 8 — internal/ui/

Build the Bubble Tea TUI using the Elm Architecture (Model/Init/Update/View).
Use `bubbles/list` for model selection menus and `bubbles/textinput` for the
custom HF ID input. Use `bubbles/spinner` during model swap/load.

**App model** (`ui/app.go`) owns a `state` enum and delegates rendering:

```go
type state int
const (
    stateMenu state = iota
    stateAction
    stateDownload
    stateLoading
)

type App struct {
    state    state
    menu     menu.Model
    action   action.Model
    download download.Model
    manager  *manager.Manager
    selected LocalModel
}
```

**UX flow:**

```
App (stateMenu)
  ├── model selected → manager.Swap() → stateAction
  │     ├── Run chat    → tea.ExecProcess(RunChat) → back to stateMenu
  │     ├── Run server  → tea.ExecProcess(RunServer) → back to stateMenu
  │     ├── Copy name   → CopyToClipboard → stateAction (show confirmation)
  │     └── Step back   → stateMenu
  ├── Open local folder → OpenFolder → stateMenu
  ├── Download          → stateDownload
  │     ├── curated pick → Download(hfID) → stateMenu
  │     ├── Custom input → textinput → Download(hfID) → stateMenu
  │     └── Step back    → stateMenu
  └── Exit → manager.StopAll() → tea.Quit
```

Use `tea.ExecProcess` (not `stream()` directly) for handing control of the
terminal to a subprocess and returning to the TUI afterward.

**Download menu — RAM-aware tier display:**

Read available RAM via `sysctl hw.memsize` at startup. Determine the active
and dimmed tiers using the same logic as the zsh original:

```
≤ 8 GB  → active=8,  dim=none
16/18GB → active=16, dim=8
≥ 24 GB → active=24, dim=16
```

In the download list:
- Active tier models are shown normally
- Dimmed tier models are rendered with a muted lipgloss style (do not hide them)
- Models already present in `~/.cache/huggingface/hub` are filtered out of the list entirely
- A separator line renders before each tier header (e.g. `── 16 GB RAM Tier Models ──`)
- The last item in the list is always `Custom (paste HuggingFace ID)…`

**Download list item layout** — each row shows only the Title and Tags on one line.
Keep the list uncluttered; all detail lives in the detail panel below.

```
Qwen 3.5 4B                    vision, reasoning
```

**Detail panel** — rendered below the list, updates on cursor move (no keypress needed).
Shows the Desc of the currently highlighted model on one line, then the HFID dimmed
on the next line. When the cursor is on a separator or the Custom entry, the panel
is blank.

```
┌─────────────────────────────────────────────────┐
│ Qwen 3.5 4B           vision, reasoning         │  ← highlighted row
│ Ministral 3 3B        vision, reasoning         │
│ ...                                             │
├─────────────────────────────────────────────────┤
│ The benchmark king at small scale. Leads        │  ← Desc (normal style)
│ mlx-community/Qwen3.5-4B-MLX-4bit              │  ← HFID (Dimmed style)
└─────────────────────────────────────────────────┘
```

The detail panel is part of the `download.Model` View() — it reads
`list.Model.SelectedItem()` and renders the two lines using styles from
`styles.go`. The panel height is fixed at 2 lines so the layout does not shift.

**Styles** (`ui/styles.go`): define all colours and styles using lipgloss here.
Keep crush's approach: a small palette of named variables, no inline styling
scattered through view functions. Define a `Dimmed` style for out-of-tier models
and for HFID lines in the detail panel.

### Step 9 — main.go

```go
//go:embed curated_LLMs.md
var curatedData []byte

func main() {
    // 1. setup.EnsureDeps() — plain terminal output, exits on error
    // 2. Parse catalog
    // 3. Read RAM via sysctl hw.memsize
    // 4. Discover local models
    // 5. Create manager, start MonitorRAM goroutine
    // 6. Build App model
    // 7. tea.NewProgram(app, tea.WithAltScreen()).Run()
    // 8. On exit: manager.StopAll()
}
```

Enable debug logging to file when `DEBUG=1` is set:

```go
if os.Getenv("DEBUG") != "" {
    f, _ := tea.LogToFile("debug.log", "debug")
    defer f.Close()
}
```

---

## Error Handling

- All `tea.KeyMsg` `ctrl+c` / `q` → `tea.Quit` + `manager.StopAll()`
- Subprocess errors → print to stderr, return to menu (do not crash)
- Manager swap timeout (>30s) → surface error message in TUI, remain in menu
- `vm_stat` parse failure → log, skip tick, do not crash
- `setup.EnsureDeps()` failure → print error to stderr, `os.Exit(1)` before TUI launches

---

## Verification Checklist

```
go build ./...           # must compile clean
go test ./...            # all tests pass
./ymlx                   # dependency check runs, then TUI renders
```

1. First run: missing deps detected, installed with visible output, then TUI launches
2. Subsequent runs: all deps present, dependency check is instant, TUI launches immediately
3. Main menu shows local models listed cleanly
4. Selecting a model → swap starts → spinner shown → action menu appears
5. "Run chat" hands terminal to `mlx_lm.chat`, returns to TUI on exit
6. "Step back" in action menu returns to main menu
7. "Download" → RAM-aware curated list → already-installed models absent from list
8. Active tier renders normally; dimmed tier renders muted
9. Hovering a model updates the detail panel: Desc on line 1, HFID dimmed on line 2
10. Detail panel is blank when cursor is on a separator or Custom entry
11. "Custom" input accepts a HF model ID string
12. "Copy name" copies model ID → confirmation message shown in TUI
13. RAM monitor goroutine visible in debug log
14. Ctrl+C at any point exits cleanly, all subprocesses terminated

---

## Notes for Claude Code

- Follow crush's `internal/` package structure closely — keep UI, business
  logic, and data layers strictly separated
- Do not put lipgloss styles inline in View() functions — always reference
  `styles.go` variables
- The `sidecar` package is a stub — implement the interface but leave the body
  as `// TODO: Phase 2`
- `manager.MonitorRAM` must be cancellable via `context.Context` — the context
  is cancelled in main's defer before `StopAll()`
- Use `tea.ExecProcess` for all subprocess handoff, not raw `os/exec` blocking
  calls inside Update()
- Keep `main.go` thin — it wires things together, it does not contain logic
- `curated_LLMs.md` has 4-line blocks (Title, HFID, Tags, Desc); the file opens
  with a header block (`Title / Source / Tags / Description`) that must be silently skipped
- The download list shows **Title + Tags** per row only — Desc and HFID appear in the
  fixed 2-line detail panel below the list, updated on cursor move
- The HFID in the detail panel uses the `Dimmed` lipgloss style — visible but subordinate
- The back action is labelled **"Step back"** (matching the zsh original), not "Back"
- MLX tools (`mlx-lm`, `mlx-vlm`) are global `uv tool` installs; `.venv/` is
  reserved for future per-project sidecar tooling only
