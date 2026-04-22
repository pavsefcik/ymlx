# ymlx Go Rewrite — Execution Plan

The work from `INSTRUCTIONS.md` broken into 8 self-contained chunks. Each chunk
is sized to fit comfortably inside one Claude Code session without context
pressure: a chunk should be executable start-to-finish by re-reading
`INSTRUCTIONS.md` + the chunk file, without needing prior conversation history.

## Chunk order (respects dependencies)

| # | File | Scope | Depends on |
|---|------|-------|------------|
| 1 | [01-scaffold.md](01-scaffold.md)       | Module init, file cleanup, empty stubs that compile | — |
| 2 | [02-setup.md](02-setup.md)             | `internal/setup` — uv / mlx-lm / mlx-vlm bootstrap  | 1 |
| 3 | [03-catalog.md](03-catalog.md)         | `internal/catalog` parser + tests                   | 1 |
| 4 | [04-models-run.md](04-models-run.md)   | `models.go` + `run.go` subprocess helpers           | 1 |
| 5 | [05-manager.md](05-manager.md)         | `internal/manager` + `internal/sidecar` stub        | 4 |
| 6 | [06-ui-foundation.md](06-ui-foundation.md) | `internal/ui`: styles, app root, main menu     | 3, 4 |
| 7 | [07-ui-flows.md](07-ui-flows.md)       | `internal/ui`: action menu + download flow          | 6 |
| 8 | [08-main-verify.md](08-main-verify.md) | `main.go` bootstrap + end-to-end verification       | 2, 5, 7 |

## How to execute each chunk

At the start of a new session, the user runs something like:

> Follow `plan/0N-xxx.md`. Reference `INSTRUCTIONS.md` for any spec detail not
> repeated in the chunk file.

Each chunk file contains:
- **Scope** — exactly what to build in this chunk
- **Preconditions** — state that must already exist
- **Files touched** — new / modified / deleted
- **Implementation notes** — anything not obvious from INSTRUCTIONS.md
- **Verification** — commands that must pass before marking the chunk done
- **Handoff** — what the next chunk can assume

## Guiding rules (apply to every chunk)

- Do not put lipgloss styles inline in `View()` — always reference `styles.go`.
- `main.go` stays thin. Business logic lives under `internal/`.
- `manager.MonitorRAM` must accept a `context.Context` and exit cleanly on cancel.
- Use `tea.ExecProcess` for subprocess handoff inside `Update()`; never block.
- Back action is labelled **"Step back"** (not "Back") — matches the zsh original.
- `sidecar` package stays a stub with `// TODO: Phase 2` bodies.
- Every chunk must leave the tree in a `go build ./...`-clean state.
