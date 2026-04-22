# Chunk 3 — internal/catalog

## Scope

Parse `curated_LLMs.md` into `[]Section`, with full unit test coverage.

See `INSTRUCTIONS.md` → "Key Structs → internal/catalog/catalog.go" for the
format spec, and the same file for test-coverage requirements.

## Preconditions

- Chunk 1 complete (stubs exist, `curated_LLMs.md` at repo root).

## Files touched

- `internal/catalog/catalog.go` — fill in `Parse`.
- `internal/catalog/catalog_test.go` — full test suite.

## Parser rules (recap)

- Lines containing `"GB RAM"` → new Section. Parse the leading integer as
  `RAMReq` (e.g. `"8 GB RAM Tier Models"` → `RAMReq = 8`).
- Blank line resets the block line counter.
- Lines *before* the first `"GB RAM"` line are silently skipped. This is how
  the header block (Title / Source / Tags / Description) is discarded.
- Inside a section, every 4 consecutive non-blank lines form a Model:
  - Line 1 → `Title`
  - Line 2 → `HFID`
  - Line 3 → `Tags`
  - Line 4 → `Desc`
- Trim whitespace on each field.

## Test coverage (required)

Create at least these cases in `catalog_test.go`:

1. `TestParseBundledFile` — reads `../../curated_LLMs.md` from disk,
   asserts:
   - Exactly 3 sections
   - Section headers equal `"8 GB RAM Tier Models"`, `"16 GB RAM Tier Models"`,
     `"24 GB RAM Tier Models"` in order
   - `RAMReq` values are 8, 16, 24
   - Each section has the expected model count
   - For at least one model per section: exact Title, HFID, Tags, Desc match
2. `TestParseHeaderBlockDropped` — input is `"Title\nSource\nTags\nDescription\n\n\n8 GB RAM Tier Models\n\nT\nH\nTg\nD\n"`, assert one section with one model named `T`.
3. `TestParseEmpty` — empty `[]byte` input returns `([]Section{}, nil)` or
   `(nil, nil)`. Pick one and document the choice in a comment.
4. `TestParseNoBlankBetweenBlocks` — defensive case: two blocks separated by
   only one newline should still parse as two models.

Use `testdata/` for any fixture files beyond the bundled `curated_LLMs.md`.

## Implementation notes

- Use `bufio.Scanner` over bytes, not string splitting — handles trailing
  newline variance better.
- The regex-free approach: for the `"GB RAM"` header, `strconv.Atoi` the
  substring from line start up to the first space.
- Do not use `//go:embed` here — catalog takes raw bytes so callers decide
  where the data comes from. `main.go` (chunk 8) is what embeds the file.

## Verification

```bash
go test ./internal/catalog/...
go vet ./internal/catalog/...
```

All tests must pass. Target >80% line coverage on `catalog.go`
(`go test -cover ./internal/catalog/...`).

## Handoff to next chunk

`catalog.Parse` is callable and tested. Chunk 6 (UI) will consume `[]Section`
via the App model.
