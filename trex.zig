/// zig-trex - Single-file Zig regex library. ASCII only, no Unicode.
///
/// This is a zig port of Tiny-Rex, a tiny regular expression library written in
/// C. See github.com/omtinez/tiny-rex by Alberto Demichelis and Oscar Martinez,
/// using the zlib/libpng license.
///
/// ── Supported syntax ────────────────────────────────────────────────────────
///   .          any character
///   ^  $       start / end of string anchors
///   |          alternation
///   (...)      capturing group
///   (?:...)    non-capturing group
///   [...]      character class          [abc]  [a-z]
///   [^...]     negated character class
///   *  +  ?    greedy: 0+, 1+, 0-or-1
///   {n}        exactly n times
///   {n,}       at least n times
///   {n,m}      between n and m times
///
///   \w \W   word / non-word  ([0-9A-Za-z_])
///   \s \S   whitespace / non-whitespace
///   \d \D   digit / non-digit
///   \b \B   word boundary / non-word-boundary
///
/// ── Differences from PCRE ───────────────────────────────────────────────────
///   - No lazy quantifiers (*? +? ??)   — greedy only
///   - No backreferences                — \1 \2 etc.
///   - No named groups                  — (?<name>...)
///   - No flags in pattern              — (?i) (?m) etc.
///   - No Unicode                       — byte-level ASCII matching only
///   - \A start-of-string anchor        — use ^ instead
///   - \z / \Z end-of-string anchors    — use $ instead
///   - No lookahead/lookbehind          — (?=) (?!) (?<=) (?<!)
///
/// ── Differences from C original ─────────────────────────────────────────────
///   - \l, \u, \x/\X, \c/\C, and \p/\P removed
///   - \b uses \w/\W boundary transition (not isspace)
///

//
// constructor
//

/// Compile a pattern string into a Trex. Call deinit() on the result when done.
pub fn re(alloc: std.mem.Allocator, pattern: []const u8, opts: TrexOptions) TrexError!Trex {
    var trex = Trex.init(alloc, opts);
    errdefer trex.deinit();

    // Node 0 is always the root OP_EXPR; subexpr 0 is the whole match.
    var c = Compiler{ .trex = &trex, .pat = pattern };
    const root = try c.newNode(OP_EXPR);
    const inner = try c.parseList();
    trex.nodes.items[@intCast(root)].left = inner;
    if (c.pos != pattern.len) return error.UnexpectedChar;

    return trex;
}

/// A compiled regular expression. Create with `re()`, free with `deinit()`.
pub const Trex = struct {
    alloc: std.mem.Allocator,
    nodes: std.ArrayList(Node) = .empty, // compiled regex
    nsubexpr: usize = 0, // total capture slots
    opts: TrexOptions = .{}, // compile-time matcher options

    /// Allocate an empty Trex; used only by `re()`.
    fn init(alloc: std.mem.Allocator, options: TrexOptions) Trex {
        return .{ .alloc = alloc, .opts = options };
    }

    /// Free all memory owned by this Trex.
    pub fn deinit(self: *Trex) void {
        self.nodes.deinit(self.alloc);
    }

    /// Returns true if matches anywhere in string.
    pub fn isMatch(self: *const Trex, text: []const u8) TrexError!bool {
        var md = try self.match(text);
        defer if (md) |*m| m.deinit();
        return md != null;
    }

    /// Find the first occurrence of the pattern anywhere in text (like re.search).
    /// The caller owns the returned result and must call `deinit()`.
    pub fn match(self: *const Trex, text: []const u8) TrexError!?TrexMatchData {
        var it = self.scan(text);
        return it.next();
    }

    /// Returns true if full-string match.
    pub fn isFullmatch(self: *const Trex, text: []const u8) TrexError!bool {
        var md = try self.fullmatch(text);
        defer if (md) |*m| m.deinit();
        return md != null;
    }

    /// Full-string match with owned capture data for the successful match.
    /// The caller owns the returned result and must call `deinit()`.
    pub fn fullmatch(self: *const Trex, text: []const u8) TrexError!?TrexMatchData {
        var md = try TrexMatchData.init(self.alloc, text, self.nsubexpr);
        errdefer md.deinit();

        const result = try matchNode(self, &md, 0, 0, MATCH_END_SENTINEL);
        const end = result orelse {
            md.deinit();
            return null;
        };
        if (end != md.text.len) {
            md.deinit();
            return null;
        }
        return md;
    }

    /// Return an iterator that yields successive non-overlapping matches of the
    /// pattern within text. The caller must keep both self and text alive for
    /// the lifetime of the returned iterator. Each yielded result is owned by
    /// the caller and must be deinitialized. Each result borrows `text`.
    pub fn scan(self: *const Trex, text: []const u8) TrexSearchIterator {
        return .{ .trex = self, .text = text };
    }
};

// ── public types ──────────────────────────────────────────────────────────────

/// All errors that `re()` can return.
pub const TrexError = error{
    EmptyClass, // [] has no members
    ExpectedBracket, // missing closing ]
    ExpectedColon, // missing : in (?:
    ExpectedCommaOrBrace, // bad {n,m} separator or terminator
    ExpectedLetter, // expected printable character
    ExpectedNumber, // expected decimal digit sequence
    ExpectedParenthesis, // missing closing )
    InvalidRangeChar, // range endpoint used a character class
    InvalidRangeNum, // range bounds are reversed
    NumericOverflow, // parsed number exceeds u16
    OutOfMemory, // alloc failed
    UnexpectedChar, // trailing or unsupported syntax
    UnfinishedRange, // class range ends before upper bound
};

/// Compile-time options passed to `re()`.
pub const TrexOptions = struct {
    case_insensitive: bool = false, // ASCII case-fold literal/class matching
    multiline: bool = false, // ^ and $ also match around newlines
};

/// A matched region: byte offset and length within the input text.
/// `matched = false` means the capture group did not participate.
pub const TrexMatch = struct {
    matched: bool = false,
    begin: usize = 0,
    len: usize = 0,

    fn clear(self: *TrexMatch) void {
        self.* = .{};
    }
};

/// An owned match result, including all captures for a single match attempt.
/// `text` is borrowed: the caller must keep the input text alive while using this result.
/// This is an owning type: shallow copies alias the same allocation.
/// The caller must call `deinit()` exactly once for each live result.
pub const TrexMatchData = struct {
    alloc: std.mem.Allocator,
    text: []const u8,
    matches: []TrexMatch,

    fn init(alloc: std.mem.Allocator, text: []const u8, nsubexpr: usize) std.mem.Allocator.Error!TrexMatchData {
        const matches = try alloc.alloc(TrexMatch, nsubexpr);
        var md: TrexMatchData = .{ .alloc = alloc, .text = text, .matches = matches };
        md.clear();
        return md;
    }

    /// Free the capture buffer owned by this result.
    pub fn deinit(self: *TrexMatchData) void {
        self.alloc.free(self.matches);
        self.* = undefined;
    }

    fn clear(self: *TrexMatchData) void {
        for (self.matches) |*m| m.clear();
    }

    /// Return the total number of subexpressions in this result.
    pub fn subexpCount(self: TrexMatchData) usize {
        return self.matches.len;
    }

    /// Return the nth subexpression, or null if n is out of range.
    /// In-range groups that did not participate return `matched = false`.
    pub fn subexp(self: TrexMatchData, n: usize) ?TrexMatch {
        return if (n < self.matches.len) self.matches[n] else null;
    }
};

/// Stateful iterator returned by scan(); holds borrowed references to the
/// Trex and input text.
pub const TrexSearchIterator = struct {
    trex: *const Trex,
    text: []const u8,
    pos: usize = 0,

    /// Return the next non-overlapping match, or null when the text is exhausted.
    /// The caller owns each returned result and must call `deinit()`.
    pub fn next(self: *TrexSearchIterator) TrexError!?TrexMatchData {
        if (self.pos > self.text.len) return null;

        var md = try TrexMatchData.init(self.trex.alloc, self.text, self.trex.nsubexpr);
        errdefer md.deinit();

        var idx = self.pos;
        while (idx <= self.text.len) {
            md.clear();
            if (try matchNode(self.trex, &md, 0, idx, -1)) |end| {
                // Advance past this match. For zero-width matches step by 1 so
                // the same position is never returned twice.
                self.pos = if (end > idx) end else end + 1;
                return md;
            }
            idx += 1;
        }

        // done, mark exhausted
        self.pos = self.text.len + 1;
        md.deinit();
        return null;
    }
};

// ── internal node representation ──────────────────────────────────────────────

// One node in the compiled regex NFA;
const Node = struct {
    kind: i32, // kind encodes the node op or a literal byte
    left: i32 = -1, // child / class-head / repeat-target
    right: i32 = -1, // OR right-branch / repeat-bounds / subexpr index
    next: i32 = -1, // sibling in sequence
};

// ── pattern compiler ──────────────────────────────────────────────────────────
// Recursive-descent parser that builds the node array from a pattern string.

// ── node type constants ───────────────────────────────────────────────────────
// Values > 255 so they can't collide with literal byte values stored as i32.
const OP_GREEDY: i32 = 256; // * + ? {n,m}
const OP_OR: i32 = 257; // |
const OP_EXPR: i32 = 258; // capturing group (...)
const OP_NOCAPEXPR: i32 = 259; // non-capturing group (?:...)
const OP_DOT: i32 = 260; // . — any character
const OP_CLASS: i32 = 261; // [...] — character class
const OP_CCLASS: i32 = 262; // \w \d etc. — named character class
const OP_NCLASS: i32 = 263; // [^...] — negated character class
const OP_RANGE: i32 = 264; // a-z inside [...]
const OP_EOL: i32 = 265; // $ — end of string
const OP_BOL: i32 = 266; // ^ — beginning of string
const OP_WB: i32 = 267; // \b \B — word boundary
const MATCH_END_SENTINEL: i32 = -2; // internal full-match continuation

// Parser state while compiling a pattern string into nodes.
const Compiler = struct {
    trex: *Trex,
    pat: []const u8,
    pos: usize = 0,

    /// Allocate a new node of the given kind, returning its index.
    fn newNode(c: *Compiler, kind: i32) TrexError!i32 {
        var n = Node{ .kind = kind };
        if (kind == OP_EXPR) {
            n.right = @intCast(c.trex.nsubexpr);
            c.trex.nsubexpr += 1;
        }
        try c.trex.nodes.append(c.trex.alloc, n);
        return @intCast(c.trex.nodes.items.len - 1);
    }

    /// Return the current character without advancing, or 0 at end of pattern.
    fn peek(c: *Compiler) u8 {
        return if (c.pos < c.pat.len) c.pat[c.pos] else 0;
    }

    /// Return and consume the current character.
    fn advance(c: *Compiler) u8 {
        const ch = c.peek();
        c.pos += 1;
        return ch;
    }

    /// Consume the expected character or return err.
    fn expectChar(c: *Compiler, ch: u8, err: TrexError) TrexError!void {
        if (c.peek() != ch) return err;
        c.pos += 1;
    }

    /// Decode a single escape sequence to its raw byte value (used inside [...]).
    fn escapeChar(c: *Compiler) TrexError!u8 {
        if (c.peek() == '\\') {
            c.pos += 1;
            if (c.pos >= c.pat.len) return error.UnexpectedChar;
            return switch (c.advance()) {
                'a' => '\x07',
                'f' => '\x0C',
                'n' => '\n',
                'r' => '\r',
                't' => '\t',
                'v' => '\x0B',
                else => |ch| ch,
            };
        }
        const ch = c.peek();
        if (!std.ascii.isPrint(ch)) return error.ExpectedLetter;
        c.pos += 1;
        return ch;
    }

    /// Parse one character or escape sequence into a node; in_class=true disables \b as anchor.
    fn charNode(c: *Compiler, in_class: bool) TrexError!i32 {
        if (c.peek() == '\\') {
            c.pos += 1;
            if (c.pos >= c.pat.len) return error.UnexpectedChar;
            const ch = c.advance();
            return switch (ch) {
                'a' => c.newNode('\x07'),
                'f' => c.newNode('\x0C'),
                'n' => c.newNode('\n'),
                'r' => c.newNode('\r'),
                't' => c.newNode('\t'),
                'v' => c.newNode('\x0B'),
                'w', 'W', 's', 'S', 'd', 'D' => blk: {
                    const n = try c.newNode(OP_CCLASS);
                    c.trex.nodes.items[@intCast(n)].left = ch;
                    break :blk n;
                },
                'b', 'B' => if (!in_class) blk: {
                    const nd = try c.newNode(OP_WB);
                    c.trex.nodes.items[@intCast(nd)].left = ch;
                    break :blk nd;
                } else c.newNode(ch), // inside [...], \b/\B are literal b/B
                else => c.newNode(ch),
            };
        }

        const ch = c.peek();
        if (!std.ascii.isPrint(ch)) return error.ExpectedLetter;
        c.pos += 1;
        return c.newNode(ch);
    }

    /// Parse a [...] or [^...] character class into a linked chain of nodes.
    fn parseClass(c: *Compiler) TrexError!i32 {
        const ret: i32 = if (c.peek() == '^') blk: {
            c.pos += 1;
            break :blk try c.newNode(OP_NCLASS);
        } else try c.newNode(OP_CLASS);

        if (c.peek() == ']') return error.EmptyClass;

        var chain = ret;
        var first: i32 = -1;
        while (c.peek() != ']' and c.pos < c.pat.len) {
            if (c.peek() == '-' and first != -1) {
                // Range: e.g. a-z. Validate that lo <= hi and that lo is not a class.
                c.pos += 1;
                if (c.peek() == ']') return error.UnfinishedRange;
                const r = try c.newNode(OP_RANGE);
                const first_kind = c.trex.nodes.items[@intCast(first)].kind;
                if (first_kind == OP_CCLASS) return error.InvalidRangeChar;
                const lo: u8 = @intCast(first_kind);
                const hi = try c.escapeChar();
                if (lo > hi) return error.InvalidRangeNum;
                c.trex.nodes.items[@intCast(r)].left = lo;
                c.trex.nodes.items[@intCast(r)].right = hi;
                c.trex.nodes.items[@intCast(chain)].next = r;
                chain = r;
                first = -1;
            } else {
                if (first != -1) {
                    c.trex.nodes.items[@intCast(chain)].next = first;
                    chain = first;
                }
                first = try c.charNode(true);
            }
        }
        if (first != -1) {
            c.trex.nodes.items[@intCast(chain)].next = first;
        }
        // The class/nclass node's left points to the first member of the chain.
        c.trex.nodes.items[@intCast(ret)].left = c.trex.nodes.items[@intCast(ret)].next;
        c.trex.nodes.items[@intCast(ret)].next = -1;
        return ret;
    }

    /// Parse a decimal integer for {n} / {n,m} quantifiers.
    fn parseNumber(c: *Compiler) TrexError!u16 {
        if (!std.ascii.isDigit(c.peek())) return error.ExpectedNumber;
        var val: u32 = 0;
        while (std.ascii.isDigit(c.peek())) {
            val = val * 10 + (c.advance() - '0');
            if (val > 0xFFFF) return error.NumericOverflow;
        }
        return @intCast(val);
    }

    /// Parse one atomic element (literal, group, class, anchor) plus any quantifier, then chain the next element.
    fn parseElement(c: *Compiler) TrexError!i32 {
        var ret: i32 = switch (c.peek()) {
            '(' => blk: {
                c.pos += 1;
                const expr: i32 = if (c.peek() == '?') inner: {
                    c.pos += 1;
                    try c.expectChar(':', error.ExpectedColon);
                    break :inner try c.newNode(OP_NOCAPEXPR);
                } else try c.newNode(OP_EXPR);
                const inner = try c.parseList();
                c.trex.nodes.items[@intCast(expr)].left = inner;
                try c.expectChar(')', error.ExpectedParenthesis);
                break :blk expr;
            },
            '[' => blk: {
                c.pos += 1;
                const cls = try c.parseClass();
                try c.expectChar(']', error.ExpectedBracket);
                break :blk cls;
            },
            '$' => blk: {
                c.pos += 1;
                break :blk try c.newNode(OP_EOL);
            },
            '^' => blk: {
                c.pos += 1;
                break :blk try c.newNode(OP_BOL);
            },
            '.' => blk: {
                c.pos += 1;
                break :blk try c.newNode(OP_DOT);
            },
            else => try c.charNode(false),
        };

        // Attach a greedy quantifier wrapper if one follows.
        var bounds = RepeatBounds{};
        var is_greedy = false;
        switch (c.peek()) {
            '*' => {
                c.pos += 1;
                bounds = .{ .max = 0xFFFF };
                is_greedy = true;
            },
            '+' => {
                c.pos += 1;
                bounds = .{ .min = 1, .max = 0xFFFF };
                is_greedy = true;
            },
            '?' => {
                c.pos += 1;
                bounds = .{ .max = 1 };
                is_greedy = true;
            },
            '{' => {
                c.pos += 1;
                bounds.min = try c.parseNumber();
                switch (c.peek()) {
                    '}' => {
                        c.pos += 1;
                        bounds.max = bounds.min;
                    },
                    ',' => {
                        c.pos += 1;
                        bounds.max = if (std.ascii.isDigit(c.peek())) try c.parseNumber() else 0xFFFF;
                        try c.expectChar('}', error.ExpectedCommaOrBrace);
                    },
                    else => return error.ExpectedCommaOrBrace,
                }
                if (!bounds.isUnbounded() and bounds.min > bounds.max) return error.InvalidRangeNum;
                is_greedy = true;
            },
            else => {},
        }
        if (is_greedy) {
            // Reject lazy-quantifier spellings (*? +? ??) — not supported.
            if (c.peek() == '?') return error.UnexpectedChar;
            const gn = try c.newNode(OP_GREEDY);
            c.trex.nodes.items[@intCast(gn)].left = ret;
            c.trex.nodes.items[@intCast(gn)].right = bounds.encode();
            ret = gn;
        }

        // Chain the next element unless we are at a boundary character.
        const ch = c.peek();
        if (ch != '|' and ch != ')' and ch != '*' and ch != '+' and ch != 0) {
            const nxt = try c.parseElement();
            c.trex.nodes.items[@intCast(ret)].next = nxt;
        }
        return ret;
    }

    /// Parse an alternation expression (a sequence optionally followed by | and another list).
    fn parseList(c: *Compiler) TrexError!i32 {
        var ret: i32 = -1;
        // Only parse an element if we are not at a boundary (end, '|', ')').
        const ch0 = c.peek();
        if (ch0 != 0 and ch0 != '|' and ch0 != ')') {
            const e = try c.parseElement();
            if (ret != -1) {
                c.trex.nodes.items[@intCast(ret)].next = e;
            } else {
                ret = e;
            }
        }
        if (c.peek() == '|') {
            c.pos += 1;
            const or_node = try c.newNode(OP_OR);
            c.trex.nodes.items[@intCast(or_node)].left = ret;
            // Evaluate parseList first: it may grow nodes and reallocate the backing
            // array, which would invalidate any pointer into items computed beforehand.
            const right = try c.parseList();
            c.trex.nodes.items[@intCast(or_node)].right = right;
            ret = or_node;
        }
        return ret;
    }
};

// ── character-class helpers ───────────────────────────────────────────────────

/// True if ch is a "word" character: alphanumeric or underscore.
fn isWordChar(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_';
}

/// Test ch against a named character class (the letter after \).
fn matchCClass(classid: u8, ch: u8) bool {
    return switch (classid) {
        'd' => std.ascii.isDigit(ch),
        's' => std.ascii.isWhitespace(ch),
        'w' => isWordChar(ch),
        'D' => !std.ascii.isDigit(ch),
        'S' => !std.ascii.isWhitespace(ch),
        'W' => !isWordChar(ch),
        else => false,
    };
}

// Inclusive repetition bounds for a greedy quantifier.
const RepeatBounds = struct {
    min: u16 = 0,
    max: u16 = 0,

    fn encode(self: RepeatBounds) i32 {
        return (@as(i32, self.min) << 16) | self.max;
    }

    fn decode(encoded: i32) RepeatBounds {
        return .{
            .min = @intCast((encoded >> 16) & 0xFFFF),
            .max = @intCast(encoded & 0xFFFF),
        };
    }

    fn isUnbounded(self: RepeatBounds) bool {
        return self.max == 0xFFFF;
    }
};

// Saved capture slots used to restore state during backtracking.
const MatchState = struct {
    matches: []TrexMatch,

    fn deinit(self: *MatchState, alloc: std.mem.Allocator) void {
        alloc.free(self.matches);
    }

    fn capture(alloc: std.mem.Allocator, md: *const TrexMatchData) std.mem.Allocator.Error!MatchState {
        const matches = try alloc.dupe(TrexMatch, md.matches);
        return .{ .matches = matches };
    }

    fn restore(self: *const MatchState, md: *TrexMatchData) void {
        std.mem.copyForwards(TrexMatch, md.matches, self.matches);
    }
};

/// True if pos is a valid start-of-line anchor position within the current text.
fn isBolMatch(trex: *const Trex, md: *const TrexMatchData, pos: usize) bool {
    if (pos == 0) return true;
    if (!trex.opts.multiline or pos > md.text.len) return false;
    return md.text[pos - 1] == '\n';
}

/// True if pos is a valid end-of-line anchor position within the current text.
fn isEolMatch(trex: *const Trex, md: *const TrexMatchData, pos: usize) bool {
    if (pos == md.text.len) return true;
    if (!trex.opts.multiline or pos >= md.text.len) return false;
    return md.text[pos] == '\n';
}

/// Test ch against the member-chain of an OP_CLASS or OP_NCLASS node.
fn matchClass(trex: *const Trex, node_idx: i32, ch: u8) bool {
    var idx = node_idx;
    while (idx != -1) {
        const node = &trex.nodes.items[@intCast(idx)];
        switch (node.kind) {
            OP_RANGE => {
                const lo: u8 = @intCast(node.left);
                const hi: u8 = @intCast(node.right);
                if (trex.opts.case_insensitive) {
                    // Check both the raw byte value (preserves non-letter chars
                    // that lie within the range, e.g. '_' inside [A-z]) and the
                    // case-folded value (so [A-Z] matches lowercase letters).
                    const raw_match = ch >= lo and ch <= hi;
                    const c2 = std.ascii.toLower(ch);
                    const folded_match = c2 >= std.ascii.toLower(lo) and c2 <= std.ascii.toLower(hi);
                    if (raw_match or folded_match) return true;
                } else {
                    if (ch >= lo and ch <= hi) return true;
                }
            },
            OP_CCLASS => if (matchCClass(@intCast(node.left), ch)) return true,
            else => {
                const pat: u8 = @intCast(node.kind);
                if (trex.opts.case_insensitive) {
                    if (std.ascii.toLower(ch) == std.ascii.toLower(pat)) return true;
                } else {
                    if (ch == pat) return true;
                }
            },
        }
        idx = node.next;
    }
    return false;
}

// ── recursive matcher ─────────────────────────────────────────────────────────

/// Walk a next-chained sequence starting at start_idx, returning the end position or null.
fn matchSequence(trex: *const Trex, md: *TrexMatchData, start_idx: i32, pos: usize) TrexError!?usize {
    if (start_idx == MATCH_END_SENTINEL) {
        return if (isEolMatch(trex, md, pos)) pos else null;
    }
    var temp = start_idx;
    var cur = pos;
    while (true) {
        const next_idx = trex.nodes.items[@intCast(temp)].next;
        cur = try matchNode(trex, md, temp, cur, -1) orelse return null;
        if (next_idx != -1) temp = next_idx else return cur;
    }
}

/// Attempt to match node_idx at pos; return the new position on success or null on failure.
fn matchNode(trex: *const Trex, md: *TrexMatchData, node_idx: i32, pos: usize, next_idx: i32) TrexError!?usize {
    const node = &trex.nodes.items[@intCast(node_idx)];
    switch (node.kind) {
        OP_GREEDY => {
            // Greedy with backtracking: collect positions for each repetition of the
            // sub-node (most reps first), then try the continuation from the longest
            // match downward until one succeeds.
            const bounds = RepeatBounds.decode(node.right);
            const p0: usize = bounds.min;
            const p1: usize = bounds.max;
            const continuation: i32 = if (node.next != -1) node.next else next_idx;

            // positions[k] = text offset after k repetitions of the sub-node.
            var positions: std.ArrayList(usize) = .{};
            defer positions.deinit(trex.alloc);
            try positions.append(trex.alloc, pos);

            // states[k] = capture state after k repetitions of the sub-node.
            var states: std.ArrayList(MatchState) = .{};
            defer {
                for (states.items) |*state| state.deinit(trex.alloc);
                states.deinit(trex.alloc);
            }
            try states.append(trex.alloc, try MatchState.capture(trex.alloc, md));

            var s = pos;
            while (bounds.isUnbounded() or positions.items.len - 1 < p1) {
                // Collect one repetition with the greedy node itself as the
                // continuation. This lets alternation inside the repeated
                // subpattern choose a branch that can continue through another
                // repetition or the eventual post-greedy continuation.
                const ns = try matchNode(trex, md, node.left, s, node_idx) orelse break;
                if (ns == s) break; // zero-width match: prevent infinite loop
                try positions.append(trex.alloc, ns);
                try states.append(trex.alloc, try MatchState.capture(trex.alloc, md));
                s = ns;
                if (s >= md.text.len) break;
            }

            const nmatches = positions.items.len - 1;

            // Try from most-greedy to least-greedy.
            var i: usize = nmatches;
            while (true) {
                if (i >= p0 and (bounds.isUnbounded() or i <= p1)) {
                    const cur_pos = positions.items[i];
                    states.items[i].restore(md);
                    if (continuation == -1) return cur_pos;
                    if (try matchSequence(trex, md, continuation, cur_pos) != null) {
                        return cur_pos;
                    }
                }
                if (i == 0) break;
                i -= 1;
            }
            states.items[0].restore(md);
            return null;
        },
        OP_OR => {
            // Either branch may be -1 when a pattern ends with | or starts with |.
            // An empty branch matches here without consuming any input.
            var initial_state = try MatchState.capture(trex.alloc, md);
            defer initial_state.deinit(trex.alloc);

            const left_pos: ?usize = if (node.left != -1)
                try matchSequence(trex, md, node.left, pos)
            else
                pos;

            if (left_pos) |lp| {
                // If a continuation is known, verify it can succeed before
                // committing to the left branch. This enables alternation
                // backtracking: /a|ab/ can match "ab" by yielding 'a' when the
                // continuation (here, an implicit OP_EOL sentinel) fails after
                // consuming only one character.
                if (next_idx == -1 or try matchSequence(trex, md, next_idx, lp) != null) {
                    return lp;
                }
                // Left matched but the continuation can't proceed; try right.
            }

            initial_state.restore(md);
            if (node.right == -1) return pos; // empty right branch
            return try matchSequence(trex, md, node.right, pos);
        },
        OP_EXPR, OP_NOCAPEXPR => {
            // Match all child nodes in sequence; record begin/len for capturing groups.
            var n_idx = node.left;
            var cur = pos;
            var capture: i32 = -1;
            if (node.kind == OP_EXPR) {
                capture = node.right;
                md.matches[@intCast(capture)].begin = cur;
                md.matches[@intCast(capture)].matched = false;
            }
            while (n_idx != -1) {
                const n = &trex.nodes.items[@intCast(n_idx)];
                const subnext: i32 = if (n.next != -1) n.next else next_idx;
                cur = try matchNode(trex, md, n_idx, cur, subnext) orelse {
                    if (capture != -1)
                        md.matches[@intCast(capture)].clear();
                    return null;
                };
                n_idx = n.next;
            }
            if (capture != -1) {
                md.matches[@intCast(capture)].matched = true;
                md.matches[@intCast(capture)].len =
                    cur - md.matches[@intCast(capture)].begin;
            }
            return cur;
        },
        OP_WB => {
            // Word boundary: \w/\W transition; consistent with PCRE (not isspace).
            const cur_w = if (pos < md.text.len) isWordChar(md.text[pos]) else false;
            const prev_w = if (pos > 0) isWordChar(md.text[pos - 1]) else false;
            const is_wb = if (pos == 0) cur_w else if (pos == md.text.len) prev_w else cur_w != prev_w;
            return if ((node.left == 'b') == is_wb) pos else null;
        },
        OP_BOL => return if (isBolMatch(trex, md, pos)) pos else null,
        OP_EOL => return if (isEolMatch(trex, md, pos)) pos else null,
        OP_DOT => {
            // Match any single character; fail at end of string.
            if (pos >= md.text.len) return null;
            return pos + 1;
        },
        OP_CLASS, OP_NCLASS => {
            // Match (or reject) the current character against the class member chain.
            if (pos >= md.text.len) return null;
            const ch = md.text[pos];
            const hit = matchClass(trex, node.left, ch);
            return if (hit == (node.kind == OP_CLASS)) pos + 1 else null;
        },
        OP_CCLASS => {
            // Match a standalone named class outside [...].
            if (pos >= md.text.len) return null;
            return if (matchCClass(@intCast(node.left), md.text[pos])) pos + 1 else null;
        },
        else => {
            // Literal byte comparison, with optional case folding.
            if (pos >= md.text.len) return null;
            const pat: u8 = @intCast(node.kind);
            const ch = md.text[pos];
            const eq = if (trex.opts.case_insensitive) std.ascii.toLower(ch) == std.ascii.toLower(pat) else ch == pat;
            return if (eq) pos + 1 else null;
        },
    }
}

const std = @import("std");
