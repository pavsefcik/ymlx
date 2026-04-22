# Chunk 8 — main.go + end-to-end verification

## Scope

Wire everything together in `main.go` and run the full verification
checklist from `INSTRUCTIONS.md`.

## Preconditions

- Chunks 1–7 complete. `go build ./...` and `go vet ./...` clean.
- `go test ./...` passes (catalog + manager tests).

## Files touched

- `main.go` — full implementation.
- `README.md` — update with Go build/run instructions (keep short).

## main.go structure

```go
package main

import (
    _ "embed"
    "context"
    "fmt"
    "os"
    "os/exec"
    "path/filepath"
    "strconv"
    "strings"
    "time"

    tea "github.com/charmbracelet/bubbletea"

    "github.com/pavsefcik/ymlx/internal/catalog"
    "github.com/pavsefcik/ymlx/internal/manager"
    "github.com/pavsefcik/ymlx/internal/models"  // see chunk 6 note
    "github.com/pavsefcik/ymlx/internal/setup"
    "github.com/pavsefcik/ymlx/internal/ui"
)

//go:embed curated_LLMs.md
var curatedData []byte

func main() {
    // 1. Pre-TUI deps bootstrap
    if err := setup.EnsureDeps(); err != nil {
        fmt.Fprintln(os.Stderr, "setup failed:", err)
        os.Exit(1)
    }

    // 2. Parse catalog
    sections, err := catalog.Parse(curatedData)
    if err != nil {
        fmt.Fprintln(os.Stderr, "catalog parse failed:", err)
        os.Exit(1)
    }

    // 3. RAM via sysctl hw.memsize (bytes → GB int, rounded)
    ramGB := readSysctlRAMGB()

    // 4. Discover local models
    home, _ := os.UserHomeDir()
    hubDir := filepath.Join(home, ".cache", "huggingface", "hub")
    local, _ := models.ListLocalModels(hubDir)

    // 5. Manager + RAM monitor
    ctx, cancel := context.WithCancel(context.Background())
    defer cancel()
    mgr := manager.New(float64(ramGB))
    go mgr.MonitorRAM(ctx, 5*time.Second)

    // 6. Debug log
    if os.Getenv("DEBUG") != "" {
        if f, err := tea.LogToFile("debug.log", "debug"); err == nil {
            defer f.Close()
        }
    }

    // 7. Run TUI
    app := ui.New(mgr, sections, local, ramGB)
    if _, err := tea.NewProgram(app, tea.WithAltScreen()).Run(); err != nil {
        fmt.Fprintln(os.Stderr, "tui error:", err)
    }

    // 8. Graceful teardown
    cancel()
    _ = mgr.StopAll()
}

func readSysctlRAMGB() int {
    out, err := exec.Command("sysctl", "-n", "hw.memsize").Output()
    if err != nil { return 16 } // sensible fallback
    bytes, err := strconv.ParseInt(strings.TrimSpace(string(out)), 10, 64)
    if err != nil { return 16 }
    return int(bytes / (1024 * 1024 * 1024))
}
```

## Verification — end-to-end

Run through the 14-item checklist in `INSTRUCTIONS.md` → "Verification
Checklist". Shortened here:

```bash
go build ./...        # must compile clean
go test ./...         # all tests pass
go vet ./...          # no findings
./ymlx                # full TUI run
```

Checklist walk (abbreviated — see INSTRUCTIONS for full):

1. First run with missing deps: install output streams, then TUI launches.
2. Subsequent runs: instant launch.
3. Main menu shows local models.
4. Select model → swap spinner → action menu.
5. Run chat: terminal handoff works, returns to TUI.
6. Step back returns to main menu.
7. Download → RAM-aware list, installed models filtered out.
8. Active tier normal, dimmed tier muted.
9. Detail panel updates on cursor move (Desc + dim HFID).
10. Blank detail panel on separators / Custom.
11. Custom input accepts HF ID.
12. Copy name → confirmation flash.
13. `DEBUG=1 ./ymlx` writes debug.log with RAM monitor entries.
14. Ctrl+C → clean exit, no orphan processes (`pgrep mlx_lm` returns nothing).

## Handoff

Done. Project is in v1 state. Possible follow-ups (do not do here):
- Phase-2 sidecar (Python FastAPI tool layer).
- Size-aware LRU (parse model `config.json` for actual param count → GB).
- Integration tests using a fake mlx binary on PATH.
