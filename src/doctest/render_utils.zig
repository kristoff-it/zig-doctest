const std = @import("std");
const mem = std.mem;
const print = std.debug.print;
const ChildProcess = std.ChildProcess;
const Allocator = std.mem.Allocator;

pub fn dumpArgs(args: []const []const u8) void {
    for (args) |arg|
        print("{s} ", .{arg})
    else
        print("\n", .{});
}

pub fn escapeHtml(allocator: Allocator, input: []const u8) ![]u8 {
    var buf = std.ArrayList(u8).init(allocator);
    defer buf.deinit();

    const out = buf.writer();
    try writeEscaped(out, input);
    return buf.toOwnedSlice();
}

pub fn writeEscaped(out: anytype, input: []const u8) !void {
    for (input) |c| {
        try switch (c) {
            '&' => out.writeAll("&amp;"),
            '<' => out.writeAll("&lt;"),
            '>' => out.writeAll("&gt;"),
            '"' => out.writeAll("&quot;"),
            else => out.writeByte(c),
        };
    }
}

//#define VT_RED "\x1b[31;1m"
//#define VT_GREEN "\x1b[32;1m"
//#define VT_CYAN "\x1b[36;1m"
//#define VT_WHITE "\x1b[37;1m"
//#define VT_BOLD "\x1b[0;1m"
//#define VT_RESET "\x1b[0m"

const TermState = enum {
    Start,
    Escape,
    LBracket,
    Number,
    AfterNumber,
    Arg,
    ArgNumber,
    ExpectEnd,
};

test "term color" {
    const input_bytes = "A\x1b[32;1mgreen\x1b[0mB";
    const result = try termColor(std.testing.allocator, input_bytes);
    defer std.testing.allocator.free(result);
    std.testing.expectEqualSlices(u8, "A<span class=\"t32\">green</span>B", result);
}

pub fn termColor(allocator: Allocator, input: []const u8) ![]u8 {
    // The SRG sequences generates by the Zig compiler are in the format:
    //   ESC [ <foreground-color> ; <n> m
    // or
    //   ESC [ <n> m
    //
    // where
    //   foreground-color is 31 (red), 32 (green), 36 (cyan)
    //   n is 0 (reset), 1 (bold), 2 (dim)
    //
    //   Note that 37 (white) is currently not used by the compiler.
    //
    // See std.debug.TTY.Color.
    const supported_sgr_colors = [_]u8{ 31, 32, 36 };
    const supported_sgr_numbers = [_]u8{ 0, 1, 2 };

    var buf = std.ArrayList(u8).init(allocator);
    defer buf.deinit();

    var out = buf.writer();
    var sgr_param_start_index: usize = undefined;
    var sgr_num: u8 = undefined;
    var sgr_color: u8 = undefined;
    var i: usize = 0;
    var state: enum {
        start,
        escape,
        lbracket,
        number,
        after_number,
        arg,
        arg_number,
        expect_end,
    } = .start;
    var last_new_line: usize = 0;
    var open_span_count: usize = 0;
    while (i < input.len) : (i += 1) {
        const c = input[i];
        switch (state) {
            .start => switch (c) {
                '\x1b' => {
                    if (mem.startsWith(u8, input[i..], "\x1B\x28\x30\x6d\x71")) {
                        try buf.appendSlice("└");
                        i += 5 - 1;
                    } else if (mem.startsWith(u8, input[i..], "\x1B\x28\x42")) {
                        try buf.appendSlice("─");
                        i += 3 - 1;
                    } else if (mem.startsWith(u8, input[i..], "\x1B\x28\x30\x74\x71")) {
                        try buf.appendSlice("├");
                        i += 5 - 1;
                    } else if (mem.startsWith(u8, input[i..], "\x1B\x28\x30\x78")) {
                        try buf.appendSlice("│");
                        i += 4 - 1;
                    } else {
                        state = .escape;
                    }
                },
                '\n' => {
                    try out.writeByte(c);
                    last_new_line = buf.items.len;
                },
                else => try out.writeByte(c),
            },
            .escape => switch (c) {
                '[' => state = .lbracket,
                else => return error.UnsupportedEscape,
            },
            .lbracket => switch (c) {
                '0'...'9' => {
                    sgr_param_start_index = i;
                    state = .number;
                },
                else => return error.UnsupportedEscape,
            },
            .number => switch (c) {
                '0'...'9' => {},
                else => {
                    sgr_num = try std.fmt.parseInt(u8, input[sgr_param_start_index..i], 10);
                    sgr_color = 0;
                    state = .after_number;
                    i -= 1;
                },
            },
            .after_number => switch (c) {
                ';' => state = .arg,
                'D' => state = .start,
                'K' => {
                    buf.items.len = last_new_line;
                    state = .start;
                },
                else => {
                    state = .expect_end;
                    i -= 1;
                },
            },
            .arg => switch (c) {
                '0'...'9' => {
                    sgr_param_start_index = i;
                    state = .arg_number;
                },
                else => return error.UnsupportedEscape,
            },
            .arg_number => switch (c) {
                '0'...'9' => {},
                else => {
                    // Keep the sequence consistent, foreground color first.
                    // 32;1m is equivalent to 1;32m, but the latter will
                    // generate an incorrect HTML class without notice.
                    sgr_color = sgr_num;
                    if (!in(&supported_sgr_colors, sgr_color)) return error.UnsupportedForegroundColor;

                    sgr_num = try std.fmt.parseInt(u8, input[sgr_param_start_index..i], 10);
                    if (!in(&supported_sgr_numbers, sgr_num)) return error.UnsupportedNumber;

                    state = .expect_end;
                    i -= 1;
                },
            },
            .expect_end => switch (c) {
                'm' => {
                    state = .start;
                    while (open_span_count != 0) : (open_span_count -= 1) {
                        try out.writeAll("</span>");
                    }
                    if (sgr_num == 0) {
                        if (sgr_color != 0) return error.UnsupportedColor;
                        continue;
                    }
                    if (sgr_color != 0) {
                        try out.print("<span class=\"sgr-{d}_{d}m\">", .{ sgr_color, sgr_num });
                    } else {
                        try out.print("<span class=\"sgr-{d}m\">", .{sgr_num});
                    }
                    open_span_count += 1;
                },
                else => return error.UnsupportedEscape,
            },
        }
    }
    return try buf.toOwnedSlice();
}

// Returns true if number is in slice.
fn in(slice: []const u8, number: u8) bool {
    for (slice) |n| {
        if (number == n) return true;
    }
    return false;
}

pub fn exec(
    allocator: Allocator,
    env_map: *std.process.EnvMap,
    max_size: usize,
    args: []const []const u8,
) !ChildProcess.RunResult {
    const result = try ChildProcess.run(.{
        .allocator = allocator,
        .argv = args,
        .env_map = env_map,
        .max_output_bytes = max_size,
    });
    switch (result.term) {
        .Exited => |exit_code| {
            if (exit_code != 0) {
                print("{s}\nThe following command exited with code {d}:\n", .{ result.stderr, exit_code });
                dumpArgs(args);
                return error.ChildExitError;
            }
        },
        else => {
            print("{s}\nThe following command crashed:\n", .{result.stderr});
            dumpArgs(args);
            return error.ChildCrashed;
        },
    }
    return result;
}
