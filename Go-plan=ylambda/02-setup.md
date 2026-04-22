# Chunk 2 — internal/setup

## Scope

Implement `setup.EnsureDeps()` — the pre-TUI dependency bootstrap that ensures
`uv`, `mlx-lm`, and `mlx-vlm` are installed. Output streams directly to the
terminal (no TUI yet at this stage of startup).

See `INSTRUCTIONS.md` → "Startup Flow" for the authoritative spec.

## Preconditions

- Chunk 1 complete (module compiles with stubs).

## Files touched

- `internal/setup/setup.go` — fill in the body.

## Public API

```go
func EnsureDeps() error
```

## Behaviour

1. Print `"Checking dependencies..."`.
2. `uv` — `exec.LookPath("uv")`:
   - missing + `brew` present → `brew install uv` (streamed)
   - missing + no `brew`     → `sh -c "curl -LsSf https://astral.sh/uv/install.sh | sh"` (streamed)
   - present                 → `✓ uv found`
3. `mlx-lm` — run `uv tool list`, look for `mlx-lm` in output:
   - missing → `uv tool install mlx-lm` (streamed)
   - present → `✓ mlx-lm ready`
4. `mlx-vlm` — same pattern as mlx-lm.
5. Print `"Launching ymlx..."` at the end.

Each check prints a ✓ / ✗ line before running the install. Installs stream
stdout+stderr live.

## Implementation notes

- Define a local `stream(name string, args ...string) error` helper here,
  *or* wait for chunk 4 where `run.go` defines the canonical version and
  import it. Prefer the latter to avoid duplication — but `run.go` hasn't
  been filled in yet at this point in the plan. **Resolution:** define a
  private `streamCmd` helper inside `setup.go` for now; chunk 4 can extract
  it later if needed. Keep it small (3 lines).
- The curl-piped-to-sh install for uv runs through `sh -c` — do *not*
  try to pipe in Go with `io.Pipe`.
- Return a descriptive error if any required dep ultimately cannot be
  installed. `main.go` (chunk 8) will print it to stderr and `os.Exit(1)`.
- `uv tool list` may have mlx-lm in its output on a separate line — use
  `strings.Contains(output, "mlx-lm")` rather than exact-line matching.

## Verification

```bash
go build ./...
go vet ./...
```

Runtime verification is deferred to chunk 8 (first end-to-end run); at this
point we only confirm the package compiles and has no obvious issues.

A tiny smoke test is optional but useful — a scratch `cmd/setupcheck/main.go`
that calls `EnsureDeps()` — but don't commit it. Just verify by eye.

## Handoff to next chunk

Next chunk (catalog) is independent of this one. Both 2 and 3 only need
chunk 1 as prerequisite and could be executed in either order.
