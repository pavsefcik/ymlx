# Chunk 1 — Scaffold

## Scope

Bring the repo from "zsh project with a spec" to "Go module that compiles".
No logic yet — only the directory layout, module bootstrap, and empty stubs
for every file named in `INSTRUCTIONS.md`.

## Preconditions

- Fresh checkout at `/Users/pavel/Dev/projects/ymlx`
- Existing files: `ymlx.zsh`, `ymlx-launcher.zsh`, `curated-llms.md`,
  `curated-llms-long.md`, `README.md`, `INSTRUCTIONS.md`

## Files touched

### Rename
- `curated-llms-long.md` → `curated_LLMs.md` (matches spec; this is the 4-line
  block format that the parser expects)

### Delete
- `ymlx.zsh`
- `ymlx-launcher.zsh`
- `curated-llms.md` (older 2-line format, superseded)

### Create (empty-body stubs — just enough that `go build ./...` passes)

```
main.go
models.go
run.go
internal/catalog/catalog.go
internal/catalog/catalog_test.go
internal/manager/manager.go
internal/manager/registry.go
internal/manager/manager_test.go
internal/setup/setup.go
internal/sidecar/sidecar.go
internal/ui/app.go
internal/ui/menu.go
internal/ui/action.go
internal/ui/download.go
internal/ui/styles.go
go.mod   (via go mod init)
go.sum   (via go mod tidy)
```

Each Go file gets its package declaration and exported identifiers from the
spec, returning zero values. Example:

```go
// internal/catalog/catalog.go
package catalog

type Section struct {
    Header string
    RAMReq int
    Models []Model
}

type Model struct {
    Title, HFID, Tags, Desc string
}

func Parse(data []byte) ([]Section, error) { return nil, nil }
```

`main.go` minimally:

```go
package main

func main() {}
```

## Implementation notes

- Module path: `github.com/pavsefcik/ymlx`
- Go toolchain: verify `go version` prints ≥ 1.22 before starting. If go is
  absent, stop and surface to the user.
- Bootstrap commands:
  ```bash
  go mod init github.com/pavsefcik/ymlx
  go get github.com/charmbracelet/bubbletea@v1.3.10
  go mod tidy
  ```
- The `bubbles` and `lipgloss` deps will be added when a chunk first imports
  them — not here.
- Do **not** embed `curated_LLMs.md` yet (that lands in chunk 8 with `main.go`).

## Verification

```bash
go build ./...
go vet ./...
ls ymlx.zsh ymlx-launcher.zsh curated-llms.md 2>&1 | grep -q "No such file"
test -f curated_LLMs.md
```

All four must succeed.

## Handoff to next chunk

After this chunk:
- Module compiles with empty function bodies.
- Every file path the spec names exists.
- `curated_LLMs.md` is present at repo root, ready to be parsed (chunk 3) and
  embedded (chunk 8).
