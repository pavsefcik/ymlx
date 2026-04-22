# Chunk 4 — models.go + run.go

## Scope

Two small top-level files:

- `models.go` — discover locally-cached HuggingFace models.
- `run.go` — subprocess wrappers for chat / server / download / open /
  clipboard operations.

Both are pure helpers with no TUI coupling.

See `INSTRUCTIONS.md` → "models.go" and "Step 6 — run.go" for the spec.

## Preconditions

- Chunk 1 complete.

## Files touched

- `models.go`
- `run.go`

## models.go

```go
package main

type LocalModel struct {
    DisplayName string  // "mlx-community/Qwen3.5-9B-MLX-4bit"
    DirPath     string  // full path to the models-- directory
}

func ListLocalModels(hubDir string) ([]LocalModel, error)
func dirToDisplayName(s string) string
```

Behaviour:
- `os.ReadDir(hubDir)`, filter entries that are directories and whose name
  starts with `"models--"`.
- Sort by `DisplayName` for deterministic output.
- `dirToDisplayName`: `strings.TrimPrefix(name, "models--")` then
  `strings.ReplaceAll("--", "/")`.
- If `hubDir` does not exist, return an empty slice and nil error (user
  simply has no models yet).

Caller passes the hub dir (typically `~/.cache/huggingface/hub`) — don't
hardcode the path here; `main.go` will resolve `$HOME`.

## run.go

```go
package main

func stream(name string, args ...string) error
func RunChat(modelID string) error
func RunServer(modelID string) error
func Download(hfID string) error
func OpenFolder(path string) error
func CopyToClipboard(text string) error
```

### `stream` (the canonical helper)

```go
func stream(name string, args ...string) error {
    cmd := exec.Command(name, args...)
    cmd.Stdin, cmd.Stdout, cmd.Stderr = os.Stdin, os.Stdout, os.Stderr
    return cmd.Run()
}
```

### Subprocess commands

- `RunChat(id)`: `mlx_lm.chat --model <id> --max-tokens 2048 --temp 0.7 --top-p 0.9`
- `RunServer(id)`: `mlx_lm.server --model <id>`
- `Download(id)`: `uvx --from mlx-lm python3 -c "from mlx_lm import load; load('<id>')"`
  — the hfID is interpolated into Python source. **Guard against injection:**
  reject hfIDs containing `'`, `\`, or newlines; the catalog only uses
  `/`, `-`, `.`, and alphanumerics, so a simple allowlist regex is fine.
- `OpenFolder(path)`: `open <path>` (macOS-only — the project is Apple Silicon only).
- `CopyToClipboard(text)`: pipe `text` into `pbcopy`. Use `cmd.StdinPipe()`,
  start, write, close, wait.

### Notes

- These helpers are called from two places:
  1. `internal/setup` (chunk 2) — already defined its own local `streamCmd`.
     Leave it duplicated for now; don't couple `setup` to the root `main`
     package.
  2. `internal/ui` (chunks 6–7) — will call these via `tea.ExecProcess`,
     which itself handles terminal handoff. `tea.ExecProcess` takes an
     `*exec.Cmd`, so the UI chunks may want an additional
     `ChatCmd(id) *exec.Cmd` constructor that returns the command rather
     than running it. **Add this variant now** to save a round trip:

```go
func ChatCmd(id string) *exec.Cmd
func ServerCmd(id string) *exec.Cmd
func DownloadCmd(id string) *exec.Cmd
```

Have `RunChat` call `ChatCmd(id)` then `stream`-equivalent wiring — keep DRY.

## Verification

```bash
go build ./...
go vet ./...
```

Unit tests are not required for this chunk — these wrappers are thin enough
that testing them provides little value and would require mocking `exec`.
An optional `TestDirToDisplayName` is nice to have.

## Handoff to next chunk

Chunk 5 (manager) uses `os/exec` directly for process control — it doesn't
call these helpers. Chunks 6–7 (UI) will call `ChatCmd`, `ServerCmd`,
`DownloadCmd`, `OpenFolder`, and `CopyToClipboard`.
