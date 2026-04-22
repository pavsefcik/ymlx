# Chunk 7 — UI flows: action menu + download

## Scope

Replace the chunk-6 placeholders with the real action and download models.
After this chunk, the TUI is feature-complete — only `main.go` wire-up
remains.

See `INSTRUCTIONS.md` → "Step 8 — internal/ui/", especially the "UX flow",
"Download menu — RAM-aware tier display", "Download list item layout", and
"Detail panel" sections.

## Preconditions

- Chunk 6 complete (styles, App shell, main menu).

## Files touched

- `internal/ui/action.go` — full implementation.
- `internal/ui/download.go` — full implementation.
- `internal/ui/app.go` — extend state transitions; most of it already exists.

## action.go

Action menu for a single selected model. Items:

| Label           | Behaviour                                                          |
|-----------------|--------------------------------------------------------------------|
| `Run chat`      | `tea.ExecProcess(ChatCmd(id))` — hands terminal over; on exit, return to `stateMenu` |
| `Run server`    | `tea.ExecProcess(ServerCmd(id))` — same                            |
| `Copy name`     | `CopyToClipboard(id)` then show a transient confirmation in the action view |
| `Step back`     | emit `stepBackMsg` → App returns to `stateMenu`                    |

Key points:
- Label is **"Step back"**, never "Back".
- Confirmation on "Copy name" is a short-lived state — e.g. set a
  `copiedAt time.Time` and render `Style.Accent` text "Copied!" for 2 s.
  Use a `tea.Tick` to clear the confirmation flag.
- Use `bubbles/list` for the menu to stay consistent with main menu.

## download.go

### Data prep (done when download state is entered)

From the App, the download model gets:
- `sections []catalog.Section`
- `ramGB int` (from sysctl)
- `local []LocalModel` (to filter already-installed)

Compute active & dimmed tiers:

```
ramGB <= 8   → active=8,  dimmed=none
ramGB 16 or 18 → active=16, dimmed=8
ramGB >= 24  → active=24, dimmed=16
```

Build list items in this order, one pass per section (8 → 16 → 24):

1. Separator line item (non-selectable): `── 16 GB RAM Tier Models ──`
2. For each `Model` in the section:
   - Skip if `HFID` is already in `local` (by display name match).
   - Otherwise add a `modelItem` carrying `Title`, `HFID`, `Tags`, `Desc`,
     and `dim bool` (true if this is a dimmed tier).

Then append a final `customItem`: `"Custom (paste HuggingFace ID)…"`.

### Rendering

**List row:**
- Modern tier: normal style. Layout: `Title` left-aligned, `Tags`
  right-aligned, padded to the list width.
- Dimmed tier: render the whole row with `styles.Dimmed`.
- Separator items: bold header style, not selectable.
- Custom item: normal style, always selectable.

**Detail panel** (fixed 2 lines below the list, rendered via `styles.Panel`):
- Line 1: `Desc` of the currently selected model (normal style).
- Line 2: `HFID` (styles.Dimmed).
- When the cursor is on a separator or the Custom entry: both lines blank
  (but the panel still renders so the layout doesn't shift).

The detail panel reads `list.SelectedItem()` each `View()` call — no
manual update wiring needed.

### Custom input

Selecting the Custom entry switches to a `textinput` sub-state inside the
download model:

- Prompt: `"HuggingFace ID:"`
- Placeholder: `"org/repo-name"`
- Enter → `Download(id)` via `tea.ExecProcess(DownloadCmd(id))`, then back to menu.
- Esc → back to the list.

### "Step back"

Pressing `esc` (or a selectable "Step back" item at the top of the list —
pick one; `esc` is simpler) returns to `stateMenu`.

## app.go updates

- Wire `menuDownloadMsg` → create fresh `download.Model` with the tier
  calculation, switch to `stateDownload`.
- Wire `menuSelectedMsg(LocalModel)` → spinner state (`stateLoading`) while
  `manager.Swap(ctx, id)` runs in a goroutine, then transition to
  `stateAction`.
  - Use `bubbles/spinner` during the wait.
  - On swap error: surface via `styles.Error` in the menu view and return
    to `stateMenu`.
- Wire `stepBackMsg` → `stateMenu`.
- Wire `downloadCompleteMsg` → `stateMenu`.

## Verification

```bash
go build ./...
go vet ./...
go run .   # manual — add a temporary bootstrap if main.go is still empty
```

Walk through the UX flow manually:

1. Main menu → Download → list renders with separators, active + dimmed tiers.
2. Cursor movement updates detail panel live.
3. Separator row → detail panel blank.
4. Custom entry → text input appears → typing works → Enter triggers
   (you can stub the actual `Download` call with a `log.Println` for
    the duration of this chunk).
5. Esc returns to main menu.
6. Pick a local model → swap spinner → action menu.
7. "Run chat" hands off terminal (use `echo` as a stub command during dev).
8. "Copy name" → clipboard contains the model ID, confirmation flashes.
9. "Step back" returns to main menu.

## Handoff to next chunk

Only `main.go` remains. All user-facing flows are implemented and tested
by hand.
