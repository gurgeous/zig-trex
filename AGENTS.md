## Toolchain

- See mise.toml - zig `0.15.2`
- Prefer `just` recipes:
  - `just check` after each change
  - `just run -- ...`

## Files

- `trex.zig`: single-file regex library
- `test_trex.zig`: tests

## Behavior

- ASCII-only, byte matching
- Greedy quantifiers do backtrack
- `Trex` is read-only after compile; captures live in `TrexMatchData`
- Use `Trex` methods for matching: `fullmatch`, `match`, `scan`, `isFullmatch`, `isMatch`
- See header comment in `trex.zig` for syntax and PCRE differences
