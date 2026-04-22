# Chunk 5 — internal/manager + internal/sidecar

## Scope

The model-lifecycle manager:

- `Registry` — thread-safe map of currently-loaded models.
- `Manager` — orchestrates start / stop / swap, with RAM-aware LRU eviction.
- `MonitorRAM` — ticker goroutine that refreshes available RAM from `vm_stat`.

Plus the `sidecar` stub — bodies left as `// TODO: Phase 2`.

See `INSTRUCTIONS.md` → "internal/manager/registry.go",
"internal/manager/manager.go", and "internal/sidecar/sidecar.go".

## Preconditions

- Chunk 4 complete (not strictly required for compilation, but keeps the
  natural review order — manager is conceptually after the subprocess
  helpers).

## Files touched

- `internal/manager/registry.go`
- `internal/manager/manager.go`
- `internal/manager/manager_test.go`
- `internal/sidecar/sidecar.go`

## Registry

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

Methods (pick names as needed): `Add`, `Remove`, `Get`, `Touch` (updates
`LastUsed`), `LRU()` (returns the oldest-used entry), `All()` (slice copy
under the lock), `Len()`.

All methods must take the mutex.

## Manager

```go
type Manager struct {
    registry    *Registry
    availableGB float64
    mu          sync.Mutex  // guards availableGB
}

func New(availableGB float64) *Manager
func (m *Manager) Swap(ctx context.Context, modelID string) error
func (m *Manager) MonitorRAM(ctx context.Context, interval time.Duration)
func (m *Manager) StopAll() error
```

### `Swap` algorithm

1. If `modelID` is already in the registry → `registry.Touch(modelID)`, return nil.
2. Determine model size (for now: assume 4 GB default — a future chunk can
   refine this by parsing `config.json` from the cache dir).
3. If `size <= availableGB` → start alongside existing.
4. Else → kill LRU model(s) until size fits, then start.
5. After starting: poll `http://127.0.0.1:<port>/health` with 500 ms interval
   until 200 OK or 30 s timeout.
6. On timeout: kill the new process, remove from registry, return error.

Port allocation: start at 8080, increment per concurrent model. Track the
next free port in the Manager struct, or pick a random ephemeral port with
`net.Listen("tcp", ":0")` then close — either is fine.

### `MonitorRAM`

```go
func (m *Manager) MonitorRAM(ctx context.Context, interval time.Duration) {
    t := time.NewTicker(interval)
    defer t.Stop()
    for {
        select {
        case <-ctx.Done(): return
        case <-t.C:
            gb, err := readAvailableRAM()  // parses `vm_stat` output
            if err != nil { /* log, continue */ continue }
            m.mu.Lock(); m.availableGB = gb; m.mu.Unlock()
            // (optional) trigger LRU eviction if memory pressure high
        }
    }
}
```

`readAvailableRAM` runs `exec.Command("vm_stat")`, finds the page size and
"Pages free" / "Pages inactive" / "Pages speculative" counts, multiplies,
divides by 1024^3, returns GB.

### `StopAll`

Iterate the registry and `SIGTERM` each process; wait up to 5 s, then
`SIGKILL` stragglers. Clear the registry.

## Sidecar stub

```go
package sidecar

type Sidecar struct {
    cmd  *exec.Cmd
    port int
}

func Start(uvPath string) (*Sidecar, error) {
    return nil, nil  // TODO: Phase 2
}
func (s *Sidecar) Health() bool { return false } // TODO: Phase 2
func (s *Sidecar) Stop() error  { return nil }   // TODO: Phase 2
```

## Tests

`internal/manager/manager_test.go` — keep scope minimal since most of this
touches real subprocesses and macOS-specific tools:

- `TestRegistryAddRemove` — pure in-memory check.
- `TestRegistryLRU` — add three entries with different `LastUsed` times,
  assert `LRU()` returns the oldest.
- `TestParseVMStat` — feed canned `vm_stat` output, assert GB value is
  reasonable. Requires refactoring `readAvailableRAM` to take `io.Reader`
  or a raw byte slice; do this refactor.

Do not test `Swap` end-to-end here — that's an integration concern covered
by chunk 8's manual verification.

## Verification

```bash
go build ./...
go test ./internal/manager/...
go vet ./internal/manager/... ./internal/sidecar/...
```

## Handoff to next chunk

UI chunks (6–7) will receive a `*manager.Manager` from `main` and call
`Swap` from inside Bubble Tea commands.
