# Chunk 6 — internal/ui foundation: styles, app root, main menu

## Scope

The Bubble Tea skeleton: styles palette, root App model with state machine,
and the main menu. After this chunk, the TUI runs and navigates — but
"Download" and the action menu are placeholders until chunk 7.

See `INSTRUCTIONS.md` → "Step 8 — internal/ui/".

## Preconditions

- Chunk 3 (`catalog`) done — App consumes `[]catalog.Section`.
- Chunk 4 (`models.go`) done — App consumes `[]LocalModel`.
- Chunk 5 (`manager`) done — App holds `*manager.Manager`.

## Files touched

- `internal/ui/styles.go` — fill in.
- `internal/ui/app.go` — fill in.
- `internal/ui/menu.go` — fill in.
- `internal/ui/action.go` — placeholder that renders "action menu (chunk 7)".
- `internal/ui/download.go` — placeholder that renders "download (chunk 7)".

## styles.go

Define a small named palette using `lipgloss`. Names below are the ones
referenced elsewhere in the plan — keep them stable.

```go
package ui

import "github.com/charmbracelet/lipgloss"

var (
    Primary   = lipgloss.Color("#7D56F4")
    Muted     = lipgloss.Color("240")
    Accent    = lipgloss.Color("#04B575")
    ErrColor  = lipgloss.Color("#E06C75")

    Title    = lipgloss.NewStyle().Bold(true).Foreground(Primary)
    Header   = lipgloss.NewStyle().Bold(true).Underline(true)
    Selected = lipgloss.NewStyle().Foreground(Accent).Bold(true)
    Dimmed   = lipgloss.NewStyle().Foreground(Muted)
    Error    = lipgloss.NewStyle().Foreground(ErrColor)
    Panel    = lipgloss.NewStyle().
                 BorderStyle(lipgloss.RoundedBorder()).
                 BorderForeground(Muted).
                 Padding(0, 1)
)
```

Exact colours can be tuned — but keep the *names* exactly as above so
other chunks can import them without refactor.

## app.go

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
    menu     menu.Model      // if menu is its own sub-package, adjust
    action   action.Model
    download download.Model
    manager  *manager.Manager
    sections []catalog.Section
    local    []LocalModel     // from root main package — see note below
    ramGB    int              // from sysctl, passed in
    selected LocalModel
    err      error
}

func New(
    mgr *manager.Manager,
    sections []catalog.Section,
    local []LocalModel,
    ramGB int,
) App

func (a App) Init() tea.Cmd
func (a App) Update(msg tea.Msg) (tea.Model, tea.Cmd)
func (a App) View() string
```

### Import cycle note

`LocalModel` lives in package `main`, so `internal/ui` cannot import it.
**Resolution:** move `LocalModel` and `ListLocalModels` from `models.go`
into a new `internal/models` package in this chunk. Update `models.go` to
just re-export or delete it — prefer to delete and have `main.go` import
from `internal/models` directly.

Update `INSTRUCTIONS.md` handoff accordingly in the chunk-8 notes (the spec
put these in root `main` — we're moving them). Document this choice in
a `// NOTE:` comment on the package declaration.

### Update() routing

- `state == stateMenu` → delegate to `menu.Update`, inspect returned
  `tea.Msg` for sentinel messages (e.g. `menuSelectedMsg`, `menuDownloadMsg`,
  `menuOpenFolderMsg`, `menuExitMsg`).
- `state == stateAction` / `stateDownload` / `stateLoading` → delegate to
  the matching sub-model.
- Global `ctrl+c` / `q` → `manager.StopAll()` then `tea.Quit`.

## menu.go

Uses `bubbles/list`. Items:

1. Each `LocalModel` — selecting one triggers swap → action state.
2. `"Open local folder"` — runs `OpenFolder(hubDir)` (`tea.ExecProcess`? no —
   `open` returns immediately, so a plain Cmd wrapper is fine).
3. `"Download"` → switch to download state.
4. `"Exit"` → emit `menuExitMsg`.

Model / Init / Update / View standard pattern. `View()` renders the list
plus the `Title` style at the top.

Use the `bubbles/list` default key bindings (arrows + j/k, enter, ctrl+c).

## action.go / download.go (placeholders)

Empty `Model`, `Update` that returns a "go back" message on any key, `View()`
returns `"action menu — implemented in chunk 7"`. Enough to wire the state
machine without implementing the real flows.

## Verification

```bash
go build ./...
go vet ./...
```

Run `go run .` manually (this works because `main.go` is still empty —
add a temporary 10-line bootstrap in `main.go` for this chunk's
verification; chunk 8 replaces it). Confirm:

- TUI launches (alt screen).
- Main menu shows local models (empty list is OK on a dev machine).
- `q` / `ctrl+c` exits cleanly.

Remove the temporary bootstrap at the end of the chunk — or leave it for
chunk 8 to replace.

## Handoff to next chunk

Chunk 7 replaces the two placeholders with real action and download flows.
Styles and state routing are stable.
