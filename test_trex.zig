const alloc = std.testing.allocator;
const default_opts = tr.TrexOptions{};
const ci_opts = tr.TrexOptions{ .case_insensitive = true };
const multiline_opts = tr.TrexOptions{ .multiline = true };

// ── literal / basic ───────────────────────────────────────────────────────────

test "literal full match" {
    try expectMatch("hello", "hello", true);
    try expectMatch("hello", "hell", false);
    try expectMatch("hello", "helloo", false);
}

test "dot any char" {
    try expectMatch("h.llo", "hello", true);
    try expectMatch("h.llo", "hXllo", true);
    try expectMatch("...", "abc", true);
    try expectMatch("...", "ab", false);
}

test "anchors bol eol" {
    try expectSearch("^foo", "foobar", 0, 3);
    try expectNoSearch("^foo", "barfoo");
    try expectSearch("bar$", "foobar", 3, 6);
    try expectNoSearch("bar$", "barfoo");
    try expectMatch("^hello$", "hello", true);
    try expectMatch("^hello$", "hello!", false);
}

test "caret is an anchor outside character classes even mid-sequence" {
    try expectMatch("a^b", "a^b", false);
    try expectMatch("a^b", "ab", false);
    try expectMatch("\\^", "^", true);
    try expectMatch("a\\^b", "a^b", true);
}

test "multiline anchors match line boundaries in search" {
    var trex_bol = try tr.re(alloc, "^foo", multiline_opts);
    defer trex_bol.deinit();
    var r1 = (try trex_bol.match("bar\nfoo\nbaz")).?;
    defer r1.deinit();
    try expectWholeMatch(r1, 4, 3);

    var trex_eol = try tr.re(alloc, "bar$", multiline_opts);
    defer trex_eol.deinit();
    var r2 = (try trex_eol.match("foo\nbar\nbaz")).?;
    defer r2.deinit();
    try expectWholeMatch(r2, 4, 3);
}

test "multiline disabled keeps anchors at string boundaries only" {
    var trex_bol = try tr.re(alloc, "^foo", default_opts);
    defer trex_bol.deinit();
    try std.testing.expect(try trex_bol.match("bar\nfoo\nbaz") == null);

    var trex_eol = try tr.re(alloc, "bar$", default_opts);
    defer trex_eol.deinit();
    try std.testing.expect(try trex_eol.match("foo\nbar\nbaz") == null);
}

test "multiline full match can target an interior line" {
    var trex = try tr.re(alloc, "^foo$", multiline_opts);
    defer trex.deinit();
    try std.testing.expect(try didFullmatch(&trex, "foo"));
    try std.testing.expect(!try didFullmatch(&trex, "bar\nfoo\nbaz"));
    var r = (try trex.match("bar\nfoo\nbaz")).?;
    defer r.deinit();
    try expectWholeMatch(r, 4, 3);
}

test "multiline zero-width anchors on empty lines" {
    var trex = try tr.re(alloc, "^$", multiline_opts);
    defer trex.deinit();
    var r = (try trex.match("a\n\nb")).?;
    defer r.deinit();
    try expectWholeMatch(r, 2, 0);
}

// ── quantifiers ───────────────────────────────────────────────────────────────

test "star" {
    try expectMatch("ab*c", "ac", true);
    try expectMatch("ab*c", "abc", true);
    try expectMatch("ab*c", "abbbbc", true);
}

test "plus" {
    try expectMatch("ab+c", "ac", false);
    try expectMatch("ab+c", "abc", true);
    try expectMatch("ab+c", "abbbbc", true);
}

test "question" {
    try expectMatch("ab?c", "ac", true);
    try expectMatch("ab?c", "abc", true);
    try expectMatch("ab?c", "abbc", false);
}

test "braces exact" {
    try expectMatch("x{2}yy", "xxyy", true);
    try expectMatch("x{2}yy", "xxxyy", false);
    try expectMatch("x{2}yy", "xyy", false);
}

test "braces min" {
    try expectMatch("x{2,}y", "xxy", true);
    try expectMatch("x{2,}y", "xxxxy", true);
    try expectMatch("x{2,}y", "xy", false);
}

test "braces range" {
    try expectMatch("x{2,4}", "xx", true);
    try expectMatch("x{2,4}", "xxx", true);
    try expectMatch("x{2,4}", "xxxx", true);
    try expectMatch("x{2,4}", "x", false);
    try expectMatch("x{2,4}", "xxxxx", false);
}

test "braces zero" {
    try expectMatch("a{0}b", "b", true); // exactly 0 repetitions
    try expectMatch("a{0}b", "ab", false);
    try expectMatch("a{0,}b", "b", true); // {0,} same as *
    try expectMatch("a{0,}b", "aaab", true);
    try expectMatch("a{0,2}b", "b", true); // 0 to 2
    try expectMatch("a{0,2}b", "ab", true);
    try expectMatch("a{0,2}b", "aab", true);
    try expectMatch("a{0,2}b", "aaab", false);
}

test "braces search" {
    try expectSearch("x{2}yy", "AxxyyxxA", 1, 5);
}

// ── alternation ───────────────────────────────────────────────────────────────

test "alternation" {
    try expectMatch("cat|dog", "cat", true);
    try expectMatch("cat|dog", "dog", true);
    try expectMatch("cat|dog", "bird", false);
    try expectSearch("cat|dog", "I have a dog.", 9, 12);
}

test "triple alternation" {
    try expectMatch("a|b|c", "a", true);
    try expectMatch("a|b|c", "b", true);
    try expectMatch("a|b|c", "c", true);
    try expectMatch("a|b|c", "d", false);
}

test "alternation inside group" {
    try expectMatch("(cat|dog)s?", "cats", true);
    try expectMatch("(cat|dog)s?", "dogs", true);
    try expectMatch("(cat|dog)s?", "cat", true);
    try expectMatch("(cat|dog)s?", "bird", false);
}

test "alternation backtracks against later context" {
    try expectMatch("a|ab", "ab", true);
    try expectMatch("(a|ab)c", "abc", true);
    try expectSearch("(a|ab)c", "zabc", 1, 4);
}

test "empty alternation branches" {
    try expectMatch("a|", "", true);
    try expectMatch("|a", "", true);
    try expectMatch("|a", "a", true);
    // a| matches empty string; search finds the first (zero-width) match at pos 0.
    try expectSearch("a|", "za", 0, 0);
}

// ── character classes ─────────────────────────────────────────────────────────

test "class basic" {
    try expectMatch("[abc]", "a", true);
    try expectMatch("[abc]", "b", true);
    try expectMatch("[abc]", "d", false);
}

test "class range" {
    try expectMatch("[a-z]+", "hello", true);
    try expectMatch("[a-z]+", "HELLO", false);
    try expectMatch("[0-9]+", "123", true);
    try expectMatch("[0-9]+", "abc", false);
}

test "uppercase range [A-Z] without CI" {
    // Bug that was present: range bounds were always folded to lowercase, so [A-Z]
    // matched lowercase letters instead of uppercase ones in non-CI mode.
    try expectMatch("[A-Z]+", "HELLO", true);
    try expectMatch("[A-Z]+", "hello", false);
    try expectMatch("[A-Z]", "A", true);
    try expectMatch("[A-Z]", "Z", true);
    try expectMatch("[A-Z]", "a", false);
}

test "multi-range class [a-zA-Z0-9]" {
    try expectMatch("[a-zA-Z0-9]+", "Hello123", true);
    try expectMatch("[a-zA-Z0-9]+", "!@#", false);
    try expectMatch("[a-zA-Z]+", "Hello", true);
    try expectMatch("[a-zA-Z]+", "123", false);
}

test "negated class" {
    try expectMatch("[^abc]", "d", true);
    try expectMatch("[^abc]", "a", false);
    try expectMatch("[^0-9]+", "abc", true);
    try expectMatch("[^0-9]+", "123", false);
}

test "negated range [^a-z]" {
    try expectMatch("[^a-z]+", "ABC123", true);
    try expectMatch("[^a-z]+", "hello", false);
    try expectMatch("[^a-z]+", "HELLO", true);
}

test "predefined class inside brackets" {
    try expectMatch("[\\d]+", "123", true); // [\d] same as \d
    try expectMatch("[\\d]+", "abc", false);
    try expectMatch("[\\w]+", "hi_123", true);
    try expectMatch("[\\s\\d]+", "1 2 3", true); // whitespace or digit
    try expectMatch("[\\s\\d]+", "abc", false);
}

// ── predefined classes ────────────────────────────────────────────────────────

test "\\w and \\W" {
    try expectMatch("\\w+", "hello123", true);
    try expectMatch("\\w+", "hello_", true);
    try expectMatch("\\W+", "!@#", true);
    try expectMatch("\\W+", "abc", false);
}

test "\\d and \\D" {
    try expectMatch("\\d+", "123", true);
    try expectMatch("\\d+", "abc", false);
    try expectMatch("\\D+", "abc", true);
    try expectMatch("\\D+", "123", false);
}

test "\\s and \\S" {
    try expectMatch("\\s+", "   ", true);
    try expectMatch("\\s+", "abc", false);
    try expectMatch("\\S+", "abc", true);
    try expectMatch("\\S+", "   ", false);
}

// ── escape sequences ──────────────────────────────────────────────────────────

test "escape tab newline" {
    try expectMatch("a\\tb", "a\tb", true);
    try expectMatch("a\\nb", "a\nb", true);
}

test "escape chars r f v a" {
    try expectMatch("a\\rb", "a\rb", true);
    try expectMatch("a\\fb", "a\x0Cb", true);
    try expectMatch("a\\vb", "a\x0Bb", true);
    try expectMatch("a\\ab", "a\x07b", true);
}

test "escaped literal metacharacters" {
    try expectMatch("\\(", "(", true);
    try expectMatch("\\)", ")", true);
    try expectMatch("\\[", "[", true);
    try expectMatch("\\]", "]", true);
    try expectMatch("\\|", "|", true);
    try expectMatch("\\*", "*", true);
    try expectMatch("\\+", "+", true);
    try expectMatch("\\?", "?", true);
    try expectMatch("\\.", ".", true);
    try expectMatch("\\\\", "\\", true);
    try expectMatch("\\$", "$", true);
    try expectMatch("\\^", "^", true);
}

// ── dot and greedy ────────────────────────────────────────────────────────────

test "a* matches empty string" {
    try expectMatch("a*", "", true);
    try expectMatch("a*", "aaa", true);
    try expectMatch("^$", "", true);
    try expectMatch("^$", "a", false);
}

test ".* matches anything" {
    try expectMatch(".*", "", true);
    try expectMatch(".*", "hello", true);
    try expectMatch("a.*b", "aXb", true);
    try expectMatch("a.*b", "aXXXb", true);
    try expectMatch("a.*b", "b", false);
    try expectMatch("a.*b", "ab", true); // backtracking: .* yields to let 'b' match
}

test "greedy backtracking" {
    // Zero-width case: .* must yield to allow adjacent literal to match.
    try expectMatch("a.*b", "ab", true);
    try expectMatch("foo.*bar", "foobar", true);
    // Multiple adjacent greedy quantifiers.
    try expectMatch("a.*b.*c", "abc", true);
    try expectMatch("a.*b.*c", "aXbYc", true);
    // Multi-node continuation after the greedy.
    try expectMatch("a.*bc", "abc", true);
    try expectMatch("a.*bc", "abbc", true);
    try expectMatch("a.*bbc", "abbbc", true);
    // Plus keeps its minimum-one guarantee.
    try expectMatch("a.+b", "aXb", true);
    try expectMatch("a.+b", "ab", false); // .+ needs >=1, leaves nothing for 'b'
    // Backtracking works inside search too.
    try expectSearch("a.*b", "xaby", 1, 3);
    // Group with greedy sub-pattern.
    try expectMatch("(a.*b)c", "abc", true);
    try expectMatch("(a.*b)c", "aXbc", true);
    // Alternation inside a repeated node must not see the outer continuation
    // during greedy collection, or valid matches like "aac" are lost.
    try expectMatch("(a|ab)*c", "aac", true);
    try expectMatch("(a|ab)*c", "abc", true);
}

// ── grouping / captures ───────────────────────────────────────────────────────

test "capture group" {
    var trex = try tr.re(alloc, "(hello)", default_opts);
    defer trex.deinit();
    const text = "hello";
    var md = (try trex.fullmatch(text)).?;
    defer md.deinit();
    try std.testing.expectEqual(@as(usize, 2), md.subexpCount()); // 0=whole, 1=group
    const m0 = md.subexp(0).?;
    const m1 = md.subexp(1).?;
    try std.testing.expect(m0.matched);
    try std.testing.expect(m1.matched);
    try std.testing.expectEqual(@as(usize, 0), m0.begin);
    try std.testing.expectEqual(@as(usize, 5), m0.len);
    try std.testing.expectEqual(@as(usize, 0), m1.begin);
    try std.testing.expectEqual(@as(usize, 5), m1.len);
}

test "non-capturing group" {
    var trex = try tr.re(alloc, "(?:hello)", default_opts);
    defer trex.deinit();
    var md = (try trex.fullmatch("hello")).?;
    defer md.deinit();
    try std.testing.expectEqual(@as(usize, 1), md.subexpCount()); // only subexpr 0=whole
}

test "multiple captures" {
    var trex = try tr.re(alloc, "(\\d+)-(\\d+)", default_opts);
    defer trex.deinit();
    const text = "123-456";
    var md = (try trex.fullmatch(text)).?;
    defer md.deinit();
    const m1 = md.subexp(1).?;
    const m2 = md.subexp(2).?;
    try std.testing.expectEqualStrings("123", text[m1.begin .. m1.begin + m1.len]);
    try std.testing.expectEqualStrings("456", text[m2.begin .. m2.begin + m2.len]);
}

test "nested groups capture" {
    var trex = try tr.re(alloc, "((\\d+)-(\\d+))", default_opts);
    defer trex.deinit();
    const text = "123-456";
    var md = (try trex.fullmatch(text)).?;
    defer md.deinit();
    // subexpr 0=whole, 1=outer group, 2=first \d+, 3=second \d+
    try std.testing.expectEqual(@as(usize, 4), md.subexpCount());
    const m1 = md.subexp(1).?;
    const m2 = md.subexp(2).?;
    const m3 = md.subexp(3).?;
    try std.testing.expectEqualStrings("123-456", text[m1.begin .. m1.begin + m1.len]);
    try std.testing.expectEqualStrings("123", text[m2.begin .. m2.begin + m2.len]);
    try std.testing.expectEqualStrings("456", text[m3.begin .. m3.begin + m3.len]);
}

test "alternation backtracking clears captures from failed branch" {
    var trex = try tr.re(alloc, "((a)|(ab))c", default_opts);
    defer trex.deinit();
    const text = "abc";
    var md = (try trex.fullmatch(text)).?;
    defer md.deinit();

    const whole = md.subexp(0).?;
    const outer = md.subexp(1).?;
    const left = md.subexp(2).?;
    const right = md.subexp(3).?;

    try std.testing.expectEqualStrings("abc", text[whole.begin .. whole.begin + whole.len]);
    try std.testing.expectEqualStrings("ab", text[outer.begin .. outer.begin + outer.len]);
    try std.testing.expect(!left.matched);
    try std.testing.expectEqual(@as(usize, 0), left.len);
    try std.testing.expect(right.matched);
    try std.testing.expectEqualStrings("ab", text[right.begin .. right.begin + right.len]);
}

test "greedy backtracking restores captures from accepted repetition count" {
    var trex = try tr.re(alloc, "((a)|(ab))+c", default_opts);
    defer trex.deinit();
    const text = "abc";
    var md = (try trex.fullmatch(text)).?;
    defer md.deinit();

    const outer = md.subexp(1).?;
    const left = md.subexp(2).?;
    const right = md.subexp(3).?;

    try std.testing.expectEqualStrings("ab", text[outer.begin .. outer.begin + outer.len]);
    try std.testing.expect(!left.matched);
    try std.testing.expectEqual(@as(usize, 0), left.len);
    try std.testing.expect(right.matched);
    try std.testing.expectEqualStrings("ab", text[right.begin .. right.begin + right.len]);
}

test "group with quantifier" {
    try expectMatch("(ab)+", "ab", true);
    try expectMatch("(ab)+", "ababab", true);
    try expectMatch("(ab)+", "a", false);
    try expectMatch("(ab)*", "", true);
    try expectMatch("(ab)*", "ab", true);
    try expectMatch("(ab)?c", "c", true);
    try expectMatch("(ab)?c", "abc", true);
    try expectMatch("(ab)?c", "ababc", false);
}

// ── word boundaries ───────────────────────────────────────────────────────────

test "word boundary basic" {
    try expectSearch("\\bfoo\\b", "the foo bar", 4, 7);
    try expectNoSearch("\\bfoo\\b", "foobar");
    try expectNoSearch("\\bfoo\\b", "barfoo");
}

test "\\b at start and end of string" {
    try expectSearch("\\bfoo", "foo bar", 0, 3); // word at string start
    try expectSearch("foo\\b", "bar foo", 4, 7); // word at string end
    try expectSearch("\\bfoo", "!foo", 1, 4); // boundary after punctuation
    try expectNoSearch("\\bfoo", "xfoo"); // no boundary mid-word
}

test "\\b between word and punctuation (C bug fix)" {
    // The C original used isspace() so '!' was not seen as a non-word char.
    // Our version uses isWordChar() so punctuation correctly triggers boundaries.
    try expectSearch("\\bfoo\\b", "!foo!", 1, 4);
    try expectSearch("\\bfoo\\b", ".foo.", 1, 4);
    try expectNoSearch("\\bfoo\\b", "xfooy");
}

test "\\B non-word-boundary" {
    try expectSearch("\\Boo\\B", "foobar", 1, 3); // mid-word
    try expectNoSearch("\\Bfoo\\B", "foo"); // at boundaries
    try expectNoSearch("\\Bfoo\\B", "!foo!"); // boundaries around foo
}

test "\\b and \\B inside character class are literal b/B" {
    try expectMatch("[\\b]", "b", true);
    try expectMatch("[\\b]", "a", false);
    try expectMatch("[\\B]", "B", true);
    try expectMatch("[\\B]", "b", false);
}

// ── search ────────────────────────────────────────────────────────────────────

test "search finds first match" {
    try expectSearch("\\d+", "abc123def456", 3, 6);
}

test "empty pattern" {
    var trex = try tr.re(alloc, "", default_opts);
    defer trex.deinit();

    try std.testing.expect(try didFullmatch(&trex, ""));
    try std.testing.expect(!try didFullmatch(&trex, "a"));

    var m = (try trex.match("abc")).?;
    defer m.deinit();
    try expectWholeMatch(m, 0, 0);

    var it = trex.scan("ab");
    var r1 = (try it.next()).?;
    defer r1.deinit();
    try expectWholeMatch(r1, 0, 0);
    var r2 = (try it.next()).?;
    defer r2.deinit();
    try expectWholeMatch(r2, 1, 0);
    var r3 = (try it.next()).?;
    defer r3.deinit();
    try expectWholeMatch(r3, 2, 0);
    try std.testing.expect(try it.next() == null);
}

test "search no match" {
    try expectNoSearch("\\d+", "abcdef");
}

test "search zero-width match on empty string" {
    // Zero-width patterns must be findable via search(), not only match().
    var trex = try tr.re(alloc, "^$", default_opts);
    defer trex.deinit();
    var r = (try trex.match("")).?;
    defer r.deinit();
    try expectWholeMatch(r, 0, 0);
    // Non-empty string: ^$ anchors fail everywhere except an empty string.
    try std.testing.expect(try trex.match("a") == null);
}

test "search zero-width anchor at boundaries" {
    // ^ anchor matches at position 0 (zero-width)
    var trex_bol = try tr.re(alloc, "^", default_opts);
    defer trex_bol.deinit();
    var r1 = (try trex_bol.match("hello")).?;
    defer r1.deinit();
    try expectWholeMatch(r1, 0, 0);
    // $ anchor matches at end (zero-width)
    var trex_eol = try tr.re(alloc, "$", default_opts);
    defer trex_eol.deinit();
    var r2 = (try trex_eol.match("hello")).?;
    defer r2.deinit();
    try expectWholeMatch(r2, 5, 0);
}

// ── scan iterator ─────────────────────────────────────────────────────────────

test "scan multiple non-overlapping matches" {
    var trex = try tr.re(alloc, "\\d+", default_opts);
    defer trex.deinit();
    var it = trex.scan("a1b22c333");
    var r1 = (try it.next()).?;
    defer r1.deinit();
    try expectWholeMatch(r1, 1, 1);
    var r2 = (try it.next()).?;
    defer r2.deinit();
    try expectWholeMatch(r2, 3, 2);
    var r3 = (try it.next()).?;
    defer r3.deinit();
    try expectWholeMatch(r3, 6, 3);
    try std.testing.expect(try it.next() == null);
    try std.testing.expect(try it.next() == null); // idempotent after exhaustion
}

test "scan word tokens" {
    var trex = try tr.re(alloc, "\\w+", default_opts);
    defer trex.deinit();
    var it = trex.scan("hello world");
    var r1 = (try it.next()).?;
    defer r1.deinit();
    try expectWholeText("hello world", r1, "hello");
    var r2 = (try it.next()).?;
    defer r2.deinit();
    try expectWholeText("hello world", r2, "world");
    try std.testing.expect(try it.next() == null);
}

test "scan no matches" {
    var trex = try tr.re(alloc, "\\d+", default_opts);
    defer trex.deinit();
    var it = trex.scan("abcdef");
    try std.testing.expect(try it.next() == null);
}

test "scan single character" {
    var trex = try tr.re(alloc, "a", default_opts);
    defer trex.deinit();
    var it = trex.scan("banana");
    var r1 = (try it.next()).?;
    defer r1.deinit();
    try expectWholeMatch(r1, 1, 1);
    var r2 = (try it.next()).?;
    defer r2.deinit();
    try expectWholeMatch(r2, 3, 1);
    var r3 = (try it.next()).?;
    defer r3.deinit();
    try expectWholeMatch(r3, 5, 1);
    try std.testing.expect(try it.next() == null);
}

test "scan zero-width matches advance and terminate" {
    // a* can match zero 'a's; iterator must not loop forever.
    // On "bab": "" at 0, "a" at 1-2, "" at 2, "" at 3 (eol), then done.
    var trex = try tr.re(alloc, "a*", default_opts);
    defer trex.deinit();
    var it = trex.scan("bab");
    var r1 = (try it.next()).?; // "" at 0
    defer r1.deinit();
    try expectWholeMatch(r1, 0, 0);
    var r2 = (try it.next()).?; // "a" at 1
    defer r2.deinit();
    try expectWholeMatch(r2, 1, 1);
    var r3 = (try it.next()).?; // "" at 2
    defer r3.deinit();
    try expectWholeMatch(r3, 2, 0);
    var r4 = (try it.next()).?; // "" at 3 (eol)
    defer r4.deinit();
    try expectWholeMatch(r4, 3, 0);
    try std.testing.expect(try it.next() == null);
}

test "scan anchor ^ matches only at start" {
    // ^foo can only match at position 0; subsequent scan positions skip it.
    var trex = try tr.re(alloc, "^foo", default_opts);
    defer trex.deinit();
    var it = trex.scan("foo foo");
    var r1 = (try it.next()).?;
    defer r1.deinit();
    try expectWholeMatch(r1, 0, 3);
    try std.testing.expect(try it.next() == null); // second "foo" not at ^
}

test "scan with backtracking pattern" {
    var trex = try tr.re(alloc, "a.*b", default_opts);
    defer trex.deinit();
    var it = trex.scan("xabxab");
    var r1 = (try it.next()).?; // "ab" at [1,3)? or greedy "abxab" at [1,6)?
    defer r1.deinit();
    // greedy: .* consumes "bxab" → tries to leave "b"; backtracks to "bxa" → "b"
    // at pos 5 → match "abxab" [1,6)
    try expectWholeMatch(r1, 1, 5);
    try std.testing.expect(try it.next() == null);
}

// ── match data ────────────────────────────────────────────────────────────────

test "fullmatch subexpCount for plain pattern is 1" {
    var trex = try tr.re(alloc, "hello", default_opts);
    defer trex.deinit();
    var md = (try trex.fullmatch("hello")).?;
    defer md.deinit();
    try std.testing.expectEqual(@as(usize, 1), md.subexpCount());
}

test "subexp(0) after search gives matched region" {
    var trex = try tr.re(alloc, "\\d+", default_opts);
    defer trex.deinit();
    const text = "abc123def";
    var md = (try trex.match(text)).?;
    defer md.deinit();
    const m = md.subexp(0).?;
    try std.testing.expect(m.matched);
    try std.testing.expectEqual(@as(usize, 3), m.begin);
    try std.testing.expectEqual(@as(usize, 3), m.len);
}

test "empty capture is distinguishable from unmatched capture" {
    var trex_empty = try tr.re(alloc, "()a", default_opts);
    defer trex_empty.deinit();
    var empty_md = (try trex_empty.fullmatch("a")).?;
    defer empty_md.deinit();
    const empty_cap = empty_md.subexp(1).?;
    try std.testing.expect(empty_cap.matched);
    try std.testing.expectEqual(@as(usize, 0), empty_cap.begin);
    try std.testing.expectEqual(@as(usize, 0), empty_cap.len);

    var trex_optional = try tr.re(alloc, "(a)?b", default_opts);
    defer trex_optional.deinit();
    var optional_md = (try trex_optional.fullmatch("b")).?;
    defer optional_md.deinit();
    const optional_cap = optional_md.subexp(1).?;
    try std.testing.expect(!optional_cap.matched);
    try std.testing.expectEqual(@as(usize, 0), optional_cap.begin);
    try std.testing.expectEqual(@as(usize, 0), optional_cap.len);
}

test "search exposes capture participation" {
    var trex = try tr.re(alloc, "(a)?b", default_opts);
    defer trex.deinit();
    var md = (try trex.match("zb")).?;
    defer md.deinit();
    const whole = md.subexp(0).?;
    const cap = md.subexp(1).?;
    try std.testing.expect(whole.matched);
    try std.testing.expect(!cap.matched);
    try std.testing.expectEqual(@as(usize, 1), whole.begin);
    try std.testing.expectEqual(@as(usize, 1), whole.len);
}

test "search clears captures between failed start positions" {
    var trex = try tr.re(alloc, "(a)?b", default_opts);
    defer trex.deinit();
    var md = (try trex.match("acb")).?;
    defer md.deinit();

    const whole = md.subexp(0).?;
    const cap = md.subexp(1).?;
    try std.testing.expectEqual(@as(usize, 2), whole.begin);
    try std.testing.expectEqual(@as(usize, 1), whole.len);
    try std.testing.expect(!cap.matched);
    try std.testing.expectEqual(@as(usize, 0), cap.begin);
    try std.testing.expectEqual(@as(usize, 0), cap.len);
}

test "scan preserves capture participation per result" {
    var trex = try tr.re(alloc, "(a)?", default_opts);
    defer trex.deinit();
    var it = trex.scan("a");

    var first = (try it.next()).?;
    defer first.deinit();
    try std.testing.expect(first.subexp(1).?.matched);

    var second = (try it.next()).?;
    defer second.deinit();
    const cap = second.subexp(1).?;
    try std.testing.expect(!cap.matched);
    try std.testing.expectEqual(@as(usize, 1), second.subexp(0).?.begin);
    try std.testing.expectEqual(@as(usize, 0), second.subexp(0).?.len);
}

test "scan clears captures between failed start positions" {
    var trex = try tr.re(alloc, "(a)?b", default_opts);
    defer trex.deinit();
    var it = trex.scan("acb");

    var first = (try it.next()).?;
    defer first.deinit();
    const whole = first.subexp(0).?;
    const cap = first.subexp(1).?;
    try std.testing.expectEqual(@as(usize, 2), whole.begin);
    try std.testing.expectEqual(@as(usize, 1), whole.len);
    try std.testing.expect(!cap.matched);
    try std.testing.expectEqual(@as(usize, 0), cap.begin);
    try std.testing.expectEqual(@as(usize, 0), cap.len);
}

test "subexp out of bounds returns null" {
    var trex = try tr.re(alloc, "hello", default_opts);
    defer trex.deinit();
    var md = (try trex.fullmatch("hello")).?;
    defer md.deinit();
    try std.testing.expect(md.subexp(99) == null);
}

test "fullmatch does not leave match state in Trex" {
    var trex = try tr.re(alloc, "(\\d+)", default_opts);
    defer trex.deinit();
    var m1_data = (try trex.fullmatch("123")).?;
    defer m1_data.deinit();
    const m1 = m1_data.subexp(1).?;
    try std.testing.expectEqualStrings("123", "123"[m1.begin .. m1.begin + m1.len]);
    var m2_data = (try trex.fullmatch("456")).?;
    defer m2_data.deinit();
    const m2 = m2_data.subexp(1).?;
    try std.testing.expectEqual(@as(usize, 0), m2.begin);
    try std.testing.expectEqual(@as(usize, 3), m2.len);
    try std.testing.expect(try trex.fullmatch("abc") == null);
}

// ── compile errors ────────────────────────────────────────────────────────────

test "error empty class" {
    try std.testing.expectError(error.EmptyClass, tr.re(alloc, "[]", default_opts));
}

test "error unexpected char" {
    try std.testing.expectError(error.UnexpectedChar, tr.re(alloc, "abc)", default_opts));
}

test "error unclosed paren" {
    try std.testing.expectError(error.ExpectedParenthesis, tr.re(alloc, "(foo", default_opts));
}

test "error invalid range [z-a]" {
    try std.testing.expectError(error.InvalidRangeNum, tr.re(alloc, "[z-a]", default_opts));
}

test "error range with cclass [\\d-z]" {
    try std.testing.expectError(error.InvalidRangeChar, tr.re(alloc, "[\\d-z]", default_opts));
}

test "error bad brace {3x}" {
    try std.testing.expectError(error.ExpectedCommaOrBrace, tr.re(alloc, "a{3x}", default_opts));
}

test "error brace without number" {
    try std.testing.expectError(error.ExpectedNumber, tr.re(alloc, "a{x}", default_opts));
}

test "error unfinished range [a-]" {
    try std.testing.expectError(error.UnfinishedRange, tr.re(alloc, "[a-]", default_opts));
}

test "error lazy quantifiers rejected" {
    // *? +? ?? are not supported; the trailing ? must be flagged as UnexpectedChar.
    try std.testing.expectError(error.UnexpectedChar, tr.re(alloc, "a*?", default_opts));
    try std.testing.expectError(error.UnexpectedChar, tr.re(alloc, "a+?", default_opts));
    try std.testing.expectError(error.UnexpectedChar, tr.re(alloc, "a??", default_opts));
}

test "error malformed non-capturing group (?foo)" {
    // (?foo) — missing colon after ? → ExpectedColon.
    try std.testing.expectError(error.ExpectedColon, tr.re(alloc, "(?foo)", default_opts));
}

test "error unclosed character class [abc" {
    // [abc without ] → ExpectedBracket.
    try std.testing.expectError(error.ExpectedBracket, tr.re(alloc, "[abc", default_opts));
}

test "error missing closing brace {3," {
    // {3, without } → ExpectedCommaOrBrace.
    try std.testing.expectError(error.ExpectedCommaOrBrace, tr.re(alloc, "a{3,", default_opts));
}

test "error descending brace range {3,2}" {
    try std.testing.expectError(error.InvalidRangeNum, tr.re(alloc, "a{3,2}", default_opts));
}

test "error trailing backslash" {
    try std.testing.expectError(error.UnexpectedChar, tr.re(alloc, "\\", default_opts));
    try std.testing.expectError(error.UnexpectedChar, tr.re(alloc, "[\\", default_opts));
}

// ── case-insensitive ──────────────────────────────────────────────────────────

test "CI literal" {
    var trex = try tr.re(alloc, "hello", ci_opts);
    defer trex.deinit();
    try std.testing.expect(try didFullmatch(&trex, "hello"));
    try std.testing.expect(try didFullmatch(&trex, "HELLO"));
    try std.testing.expect(try didFullmatch(&trex, "HeLLo"));
    try std.testing.expect(!try didFullmatch(&trex, "world"));
}

test "CI character class" {
    var trex = try tr.re(alloc, "[a-z]+", ci_opts);
    defer trex.deinit();
    try std.testing.expect(try didFullmatch(&trex, "hello"));
    try std.testing.expect(try didFullmatch(&trex, "HELLO"));
    try std.testing.expect(try didFullmatch(&trex, "HeLLo"));
}

test "CI explicit upper range" {
    var trex = try tr.re(alloc, "[A-Z]+", ci_opts);
    defer trex.deinit();
    try std.testing.expect(try didFullmatch(&trex, "hello"));
    try std.testing.expect(try didFullmatch(&trex, "HELLO"));
}

test "CI mixed ASCII range preserves punctuation gap" {
    var trex = try tr.re(alloc, "[A-z]", ci_opts);
    defer trex.deinit();
    try std.testing.expect(try didFullmatch(&trex, "_"));
    try std.testing.expect(try didFullmatch(&trex, "["));
    try std.testing.expect(try didFullmatch(&trex, "`"));
}

test "CI alternation" {
    var trex = try tr.re(alloc, "cat|dog", ci_opts);
    defer trex.deinit();
    try std.testing.expect(try didFullmatch(&trex, "CAT"));
    try std.testing.expect(try didFullmatch(&trex, "Dog"));
    try std.testing.expect(!try didFullmatch(&trex, "bird"));
}

test "CI search" {
    var trex = try tr.re(alloc, "foo", ci_opts);
    defer trex.deinit();
    var r = (try trex.match("find FOO here")).?;
    defer r.deinit();
    try expectWholeMatch(r, 5, 3);
}

test "CI class literal inside brackets" {
    var trex = try tr.re(alloc, "[aeiou]+", ci_opts);
    defer trex.deinit();
    try std.testing.expect(try didFullmatch(&trex, "aeiou"));
    try std.testing.expect(try didFullmatch(&trex, "AEIOU"));
    try std.testing.expect(try didFullmatch(&trex, "AeIoU"));
}

// ── test helpers (co-located at bottom) ──────────────────────────────────────

/// Compile pattern with default options and assert fullmatch() returns expected.
fn expectMatch(pattern: []const u8, text: []const u8, expected: bool) !void {
    var trex = try tr.re(alloc, pattern, default_opts);
    defer trex.deinit();
    const got = try didFullmatch(&trex, text);
    if (got != expected) {
        std.debug.print("fullmatch(\"{s}\", \"{s}\") = {}, want {}\n", .{ pattern, text, got, expected });
        return error.TestExpectedEqual;
    }
}

/// Compile pattern with default options and assert match() finds [exp_begin, exp_end).
fn expectSearch(pattern: []const u8, text: []const u8, exp_begin: usize, exp_end: usize) !void {
    var trex = try tr.re(alloc, pattern, default_opts);
    defer trex.deinit();
    var r = try trex.match(text) orelse {
        std.debug.print("match(\"{s}\", \"{s}\") = null, want [{d},{d})\n", .{ pattern, text, exp_begin, exp_end });
        return error.TestExpectedEqual;
    };
    defer r.deinit();
    try expectWholeMatch(r, exp_begin, exp_end - exp_begin);
}

/// Compile pattern with default options and assert match() returns null.
fn expectNoSearch(pattern: []const u8, text: []const u8) !void {
    var trex = try tr.re(alloc, pattern, default_opts);
    defer trex.deinit();
    if (try trex.match(text) != null) {
        std.debug.print("match(\"{s}\", \"{s}\") expected null\n", .{ pattern, text });
        return error.TestExpectedEqual;
    }
}

fn expectWholeMatch(md: tr.TrexMatchData, begin: usize, len: usize) !void {
    const m = md.subexp(0).?;
    try std.testing.expect(m.matched);
    try std.testing.expectEqual(begin, m.begin);
    try std.testing.expectEqual(len, m.len);
}

fn expectWholeText(text: []const u8, md: tr.TrexMatchData, expected: []const u8) !void {
    const m = md.subexp(0).?;
    try std.testing.expectEqualStrings(expected, text[m.begin .. m.begin + m.len]);
}

fn didFullmatch(trex: *const tr.Trex, text: []const u8) !bool {
    var md = try trex.fullmatch(text) orelse return false;
    md.deinit();
    return true;
}

const std = @import("std");
const tr = @import("trex.zig");
