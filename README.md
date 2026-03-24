[![test](https://github.com/gurgeous/zig-trex/actions/workflows/ci.yml/badge.svg)](https://github.com/gurgeous/zig-trex/actions/workflows/ci.yml)

# zig-trex

`zig-trex` is a small single-file ASCII regex library for Zig. It is a direct
port of [tiny-rex](https://github.com/omtinez/tiny-rex) with some mild
improvements. Same zlib/libpng license as the original.

```
── Supported syntax ────────────────────────────────────────────────────────
  .          any character
  ^  $       start / end of string anchors
  |          alternation
  (...)      capturing group
  (?:...)    non-capturing group
  [...]      character class          [abc]  [a-z]
  [^...]     negated character class
  *  +  ?    greedy: 0+, 1+, 0-or-1
  {n}        exactly n times
  {n,}       at least n times
  {n,m}      between n and m times

  \w \W   word / non-word  ([0-9A-Za-z_])
  \s \S   whitespace / non-whitespace
  \d \D   digit / non-digit
  \b \B   word boundary / non-word-boundary

── Differences from PCRE ───────────────────────────────────────────────────
  - No lazy quantifiers (*? +? ??)   — greedy only
  - No backreferences                — \1 \2 etc.
  - No named groups                  — (?<name>...)
  - No flags in pattern              — (?i) (?m) etc.
  - No Unicode                       — byte-level ASCII matching only
  - \A start-of-string anchor        — use ^ instead
  - \z / \Z end-of-string anchors    — use $ instead
  - No lookahead/lookbehind          — (?=) (?!) (?<=) (?<!)

── Differences from C original ─────────────────────────────────────────────
  - \l, \u, \x/\X, \c/\C, and \p/\P removed
  - \b uses \w/\W boundary transition (not isspace)
```

## Library Example

```zig
const std = @import("std");
const trex = @import("trex");

pub fn main() !void {
    const alloc = std.heap.page_allocator;

    // compile re
    var re = try trex.re(alloc, "(\\d+)", .{});
    defer re.deinit();

    // match and report
    if (try re.match("id=42")) |res| {
        var md = res;
        defer md.deinit();
        const whole = md.subexp(0).?;
        const str = md.text[whole.begin .. whole.begin + whole.len];
        std.debug.print("match at {d} len {d}: \"{s}\"\n", .{ whole.begin, whole.len, str });
    }
}
```

See more examples in [`examples.zig`](examples.zig), which you can run directly:

```sh
$ mise trust && mise install
$ zig run examples.zig
```
