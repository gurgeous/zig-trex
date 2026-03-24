/// trex tester
/// Usage:
///   trex [-i] [-m] <pattern> <text>          search for pattern in text, print match
///   trex [-i] [-m] --match <pattern> <text>  full-string match (exits 0=match, 1=no match)
///   -i   case-insensitive matching
///   -m   multiline anchors (^ and $ also match around newlines)
const usage =
    \\Usage:
    \\  trex [-i] [-m] <pattern> <text>
    \\  trex [-i] [-m] --match <pattern> <text>
    \\
;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var stdout_buffer: [4096]u8 = undefined;
    var stderr_buffer: [4096]u8 = undefined;
    var stdout = std.fs.File.stdout().writer(&stdout_buffer);
    var stderr = std.fs.File.stderr().writer(&stderr_buffer);

    var full_match = false;
    var ci = false;
    var multiline = false;
    var arg_idx: usize = 1;

    // Parse flags until the first positional argument.
    while (arg_idx < args.len) : (arg_idx += 1) {
        if (std.mem.eql(u8, args[arg_idx], "-i")) {
            ci = true;
        } else if (std.mem.eql(u8, args[arg_idx], "-m")) {
            multiline = true;
        } else if (std.mem.eql(u8, args[arg_idx], "--match")) {
            full_match = true;
        } else {
            break;
        }
    }

    if (args.len < arg_idx + 2) {
        try stderr.interface.print(usage, .{});
        try stderr.interface.flush();
        std.process.exit(2);
    }

    const pattern = args[arg_idx];
    const text = args[arg_idx + 1];
    const opts = trex.TrexOptions{
        .case_insensitive = ci,
        .multiline = multiline,
    };

    var re = trex.re(allocator, pattern, opts) catch |err| {
        try stderr.interface.print("compile error: {}\n", .{err});
        try stderr.interface.flush();
        std.process.exit(2);
    };
    defer re.deinit();

    if (full_match) {
        var result = re.fullmatch(text) catch |err| {
            try stderr.interface.print("match error: {}\n", .{err});
            try stderr.interface.flush();
            std.process.exit(2);
        };
        if (result) |*md| md.deinit();
        try stdout.interface.print("{s}\n", .{if (result != null) "match" else "no match"});
        try stdout.interface.flush();
        std.process.exit(if (result != null) 0 else 1);
    }

    var result = re.match(text) catch |err| {
        try stderr.interface.print("search error: {}\n", .{err});
        try stderr.interface.flush();
        std.process.exit(2);
    } orelse {
        try stdout.interface.print("no match\n", .{});
        try stdout.interface.flush();
        std.process.exit(1);
    };
    defer result.deinit();

    const whole = result.subexp(0).?;
    const matched = result.text[whole.begin .. whole.begin + whole.len];
    try stdout.interface.print("match [{d},{d}): \"{s}\"\n", .{ whole.begin, whole.begin + whole.len, matched });

    const nsub = result.subexpCount();
    if (nsub > 1) {
        var i: usize = 0;
        while (i < nsub) : (i += 1) {
            const m = result.subexp(i) orelse continue;
            if (!m.matched) continue;
            const sub = result.text[m.begin .. m.begin + m.len];
            try stdout.interface.print("  [{d}] \"{s}\"\n", .{ i, sub });
        }
    }
    try stdout.interface.flush();
}

const std = @import("std");
const trex = @import("trex");
