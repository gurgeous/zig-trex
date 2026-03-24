pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    // get ready
    var stdout_buffer: [4096]u8 = undefined;
    var stdout = std.fs.File.stdout().writer(&stdout_buffer);
    const out = &stdout.interface;
    var num: usize = 1;

    // Compile once and reuse the regex for simple full matches.
    var re1 = try trex.re(alloc, "hello", .{});
    defer re1.deinit();
    try out.print("{d}. fullmatch(\"hello\", \"hello\") => {}\n", .{ num, try re1.isFullmatch("hello") });
    num += 1;
    try out.print("{d}. fullmatch(\"hello\", \"HELLO\") => {}\n\n", .{ num, try re1.isFullmatch("HELLO") });
    num += 1;

    // Character classes and quantifiers cover many small validation tasks.
    var re2 = try trex.re(alloc, "[A-Za-z_][A-Za-z0-9_]*", .{});
    defer re2.deinit();
    try out.print("{d}. fullmatch(\"[A-Za-z_][A-Za-z0-9_]*\", \"name_42\") => {}\n", .{ num, try re1.isFullmatch("name_42") });
    num += 1;
    try out.print("{d}. fullmatch(\"[A-Za-z_][A-Za-z0-9_]*\", \"42name\")  => {}\n\n", .{ num, try re1.isFullmatch("42name") });
    num += 1;

    // Use fullmatch() when you want the overall match plus capture groups.
    var re3 = try trex.re(alloc, "(\\d+)-(\\d+)", .{});
    defer re3.deinit();
    if (try re3.fullmatch("123-456")) |res| {
        var md = res;
        defer md.deinit();
        try out.print("{d}. ", .{num});
        try printMatchData(out, "fullmatch(\"(\\d+)-(\\d+)\", \"123-456\")", &md);
    }
    try out.print("\n", .{});
    num += 1;

    // Optional groups keep their slot and report whether they participated.
    var re4 = try trex.re(alloc, "(a)?b", .{});
    defer re4.deinit();
    if (try re4.fullmatch("b")) |res| {
        var md = res;
        defer md.deinit();
        try out.print("{d}. ", .{num});
        try printMatchData(out, "fullmatch(\"(a)?b\", \"b\")", &md);
    }
    try out.print("\n", .{});
    num += 1;

    // Empty captures are distinct from unmatched optional captures.
    var re5 = try trex.re(alloc, "()a", .{});
    defer re5.deinit();
    if (try re5.fullmatch("a")) |res| {
        var md = res;
        defer md.deinit();
        try out.print("{d}. ", .{num});
        try printMatchData(out, "fullmatch(\"()a\", \"a\")", &md);
    }
    try out.print("\n", .{});
    num += 1;

    // match() finds the first occurrence and returns owned match data.
    const search_text = "ids: 42 and 99";
    var re6 = try trex.re(alloc, "(\\d+)", .{});
    defer re6.deinit();
    if (try re6.match(search_text)) |res| {
        var md = res;
        defer md.deinit();
        try out.print("{d}. ", .{num});
        try printMatchData(out, "match(\"(\\d+)\", \"ids: 42 and 99\")", &md);
    }
    try out.print("\n", .{});
    num += 1;

    // scan() iterates over non-overlapping matches.
    var iter = re6.scan(search_text);
    try out.print("{d}. scan(\"(\\d+)\", \"ids: 42 and 99\") yields non-overlapping matches\n", .{num});
    while (try iter.next()) |res| {
        var md = res;
        defer md.deinit();
        const whole = md.subexp(0).?;
        const slice = md.text[whole.begin .. whole.begin + whole.len];
        try out.print("  -> pos {d}, len {d}: \"{s}\"\n", .{ whole.begin, whole.len, slice });
    }
    try out.print("\n", .{});
    num += 1;

    // Alternation and word boundaries are useful for token-style searches.
    const pet_text = "a dog, a cat, and a catalog";
    var re7 = try trex.re(alloc, "\\b(cat|dog)\\b", .{});
    defer re7.deinit();
    var pet_iter = re7.scan(pet_text);
    try out.print("{d}. scan(\"\\b(cat|dog)\\b\", \"a dog, a cat, and a catalog\") finds both whole-word pets\n", .{num});
    while (try pet_iter.next()) |res| {
        var md = res;
        defer md.deinit();
        const whole = md.subexp(0).?;
        const choice = md.subexp(1).?;
        try out.print("  -> pos {d}, len {d}: whole \"{s}\", capture \"{s}\"\n", .{
            whole.begin,
            whole.len,
            md.text[whole.begin .. whole.begin + whole.len],
            md.text[choice.begin .. choice.begin + choice.len],
        });
    }
    try out.print("\n", .{});
    num += 1;

    // Case-insensitive mode is configured at compile time.
    var re8 = try trex.re(alloc, "status: ok", .{ .case_insensitive = true });
    defer re8.deinit();
    try out.print("{d}. fullmatch(\"status: ok\", \"STATUS: OK\") with case_insensitive = true => {}\n\n", .{ num, try re1.isFullmatch("STATUS: OK") });
    num += 1;

    // Multiline mode lets ^ and $ match around newlines.
    const multiline_text = "alpha\nbeta\ngamma";
    var re9 = try trex.re(alloc, "^beta$", .{ .multiline = true });
    defer re9.deinit();
    var re10 = try trex.re(alloc, "^beta$", .{});
    defer re10.deinit();
    try out.print("{d}. match(\"^beta$\", \"alpha\\nbeta\\ngamma\") with multiline = false => {s}\n", .{
        num,
        if (try re10.match(multiline_text) == null) "null" else "match",
    });
    num += 1;
    if (try re9.match(multiline_text)) |res| {
        var md = res;
        defer md.deinit();
        try out.print("{d}. ", .{num});
        try printMatchData(out, "match(\"^beta$\", \"alpha\\nbeta\\ngamma\") with multiline = true", &md);
    }

    try out.flush();
}

fn printMatchData(writer: anytype, label: []const u8, md: *const trex.TrexMatchData) !void {
    try writer.print("{s}\n", .{label});

    var ii: usize = 0;
    while (ii < md.subexpCount()) : (ii += 1) {
        const m = md.subexp(ii).?;
        if (!m.matched) {
            try writer.print("  [{d}] <unmatched>\n", .{ii});
            continue;
        }
        const slice = md.text[m.begin .. m.begin + m.len];
        try writer.print("  [{d}] pos {d}, len {d}: \"{s}\"\n", .{ ii, m.begin, m.len, slice });
    }
}

const std = @import("std");
const trex = @import("trex.zig");
