const std = @import("std");
const builtin = std.builtin;
const io = std.io;
const fs = std.fs;
const process = std.process;
const ChildProcess = std.ChildProcess;
const print = std.debug.print;
const mem = std.mem;
const testing = std.testing;

const exe_ext = (std.zig.CrossTarget{}).exeFileExt();
const obj_ext = (std.zig.CrossTarget{}).oFileExt();

fn assertToken(tokenizer: *Tokenizer, token: Token, id: Token.Id) !void {
    if (token.id != id) {
        return parseError(tokenizer, token, "expected {}, found {}", .{ @tagName(id), @tagName(token.id) });
    }
}

fn eatToken(tokenizer: *Tokenizer, id: Token.Id) !Token {
    const token = tokenizer.next();
    try assertToken(tokenizer, token, id);
    return token;
}

const HeaderOpen = struct {
    name: []const u8,
    url: []const u8,
    n: usize,
};

const SeeAlsoItem = struct {
    name: []const u8,
    token: Token,
};

const ExpectedOutcome = enum {
    Succeed,
    Fail,
    BuildFail,
};

const Code = struct {
    id: Id,
    name: []const u8,
    source_token: Token,
    is_inline: bool,
    mode: builtin.Mode,
    link_objects: []const []const u8,
    target_str: ?[]const u8,
    link_libc: bool,
    disable_cache: bool,

    const Id = union(enum) {
        Test,
        TestError: []const u8,
        TestSafety: []const u8,
        Exe: ExpectedOutcome,
        Obj: ?[]const u8,
        Lib,
    };
};

const Link = struct {
    url: []const u8,
    name: []const u8,
    token: Token,
};

const Node = union(enum) {
    Content: []const u8,
    Nav,
    Builtin: Token,
    HeaderOpen: HeaderOpen,
    SeeAlso: []const SeeAlsoItem,
    Code: Code,
    Link: Link,
    Syntax: Token,
};

const Toc = struct {
    nodes: []Node,
    toc: []u8,
    urls: std.StringHashMap(Token),
};

const Action = enum {
    Open,
    Close,
};

fn urlize(allocator: *mem.Allocator, input: []const u8) ![]u8 {
    var buf = std.ArrayList(u8).init(allocator);
    defer buf.deinit();

    const out = buf.outStream();
    for (input) |c| {
        switch (c) {
            'a'...'z', 'A'...'Z', '_', '-', '0'...'9' => {
                try out.writeByte(c);
            },
            ' ' => {
                try out.writeByte('-');
            },
            else => {},
        }
    }
    return buf.toOwnedSlice();
}

fn escapeHtml(allocator: *mem.Allocator, input: []const u8) ![]u8 {
    var buf = std.ArrayList(u8).init(allocator);
    defer buf.deinit();

    const out = buf.outStream();
    try writeEscaped(out, input);
    return buf.toOwnedSlice();
}

fn writeEscaped(out: anytype, input: []const u8) !void {
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
    testing.expectEqualSlices(u8, "A<span class=\"t32\">green</span>B", result);
}

fn termColor(allocator: *mem.Allocator, input: []const u8) ![]u8 {
    var buf = std.ArrayList(u8).init(allocator);
    defer buf.deinit();

    var out = buf.outStream();
    var number_start_index: usize = undefined;
    var first_number: usize = undefined;
    var second_number: usize = undefined;
    var i: usize = 0;
    var state = TermState.Start;
    var open_span_count: usize = 0;
    while (i < input.len) : (i += 1) {
        const c = input[i];
        switch (state) {
            TermState.Start => switch (c) {
                '\x1b' => state = TermState.Escape,
                else => try out.writeByte(c),
            },
            TermState.Escape => switch (c) {
                '[' => state = TermState.LBracket,
                else => return error.UnsupportedEscape,
            },
            TermState.LBracket => switch (c) {
                '0'...'9' => {
                    number_start_index = i;
                    state = TermState.Number;
                },
                else => return error.UnsupportedEscape,
            },
            TermState.Number => switch (c) {
                '0'...'9' => {},
                else => {
                    first_number = std.fmt.parseInt(usize, input[number_start_index..i], 10) catch unreachable;
                    second_number = 0;
                    state = TermState.AfterNumber;
                    i -= 1;
                },
            },

            TermState.AfterNumber => switch (c) {
                ';' => state = TermState.Arg,
                else => {
                    state = TermState.ExpectEnd;
                    i -= 1;
                },
            },
            TermState.Arg => switch (c) {
                '0'...'9' => {
                    number_start_index = i;
                    state = TermState.ArgNumber;
                },
                else => return error.UnsupportedEscape,
            },
            TermState.ArgNumber => switch (c) {
                '0'...'9' => {},
                else => {
                    second_number = std.fmt.parseInt(usize, input[number_start_index..i], 10) catch unreachable;
                    state = TermState.ExpectEnd;
                    i -= 1;
                },
            },
            TermState.ExpectEnd => switch (c) {
                'm' => {
                    state = TermState.Start;
                    while (open_span_count != 0) : (open_span_count -= 1) {
                        try out.writeAll("</span>");
                    }
                    if (first_number != 0 or second_number != 0) {
                        try out.print("<span class=\"t{}_{}\">", .{ first_number, second_number });
                        open_span_count += 1;
                    }
                },
                else => return error.UnsupportedEscape,
            },
        }
    }
    return buf.toOwnedSlice();
}

const builtin_types = [_][]const u8{
    "f16",         "f32",      "f64",    "f128",     "c_longdouble", "c_short",
    "c_ushort",    "c_int",    "c_uint", "c_long",   "c_ulong",      "c_longlong",
    "c_ulonglong", "c_char",   "c_void", "void",     "bool",         "isize",
    "usize",       "noreturn", "type",   "anyerror", "comptime_int", "comptime_float",
};

fn isType(name: []const u8) bool {
    for (builtin_types) |t| {
        if (mem.eql(u8, t, name))
            return true;
    }
    return false;
}

const Location = struct {
    line: usize,
    column: usize,
    line_start: usize,
    line_end: usize,
};
fn getTokenLocation(src: []const u8, token: std.zig.Token) Location {
    var loc = Location{
        .line = 0,
        .column = 0,
        .line_start = 0,
        .line_end = 0,
    };
    for (src) |c, i| {
        if (i == token.loc.start) {
            loc.line_end = i;
            while (loc.line_end < src.len and src[loc.line_end] != '\n') : (loc.line_end += 1) {}
            return loc;
        }
        if (c == '\n') {
            loc.line += 1;
            loc.column = 0;
            loc.line_start = i + 1;
        } else {
            loc.column += 1;
        }
    }
    return loc;
}

fn genHtml(allocator: *mem.Allocator, tokenizer: *Tokenizer, toc: *Toc, out: anytype, zig_exe: []const u8) !void {
    var code_progress_index: usize = 0;

    var env_map = try process.getEnvMap(allocator);
    try env_map.set("ZIG_DEBUG_COLOR", "1");

    for (toc.nodes) |node| {
        switch (node) {
            .Syntax => |content_tok| {
                try tokenizeAndPrint(tokenizer, out, content_tok);
            },
            .Code => |code| {
                code_progress_index += 1;
                print("docgen example code {}/{}...", .{ code_progress_index, tokenizer.code_node_count });

                const raw_source = tokenizer.buffer[code.source_token.start..code.source_token.end];
                const trimmed_raw_source = mem.trim(u8, raw_source, " \n");
                if (!code.is_inline) {
                    try out.print("<p class=\"file\">{}.zig</p>", .{code.name});
                }
                try out.writeAll("<pre>");
                try tokenizeAndPrint(tokenizer, out, code.source_token);
                try out.writeAll("</pre>");
                const name_plus_ext = try std.fmt.allocPrint(allocator, "{}.zig", .{code.name});
                const tmp_source_file_name = try fs.path.join(
                    allocator,
                    &[_][]const u8{ tmp_dir_name, name_plus_ext },
                );
                try fs.cwd().writeFile(tmp_source_file_name, trimmed_raw_source);

                switch (code.id) {
                    Code.Id.Exe => |expected_outcome| code_block: {
                        const name_plus_bin_ext = try std.fmt.allocPrint(allocator, "{}{}", .{ code.name, exe_ext });
                        var build_args = std.ArrayList([]const u8).init(allocator);
                        defer build_args.deinit();
                        try build_args.appendSlice(&[_][]const u8{
                            zig_exe,          "build-exe",
                            "--name",         code.name,
                            "--color",        "on",
                            "--enable-cache", tmp_source_file_name,
                        });
                        try out.print("<pre><code class=\"shell\">$ zig build-exe {}.zig", .{code.name});
                        switch (code.mode) {
                            .Debug => {},
                            else => {
                                try build_args.appendSlice(&[_][]const u8{ "-O", @tagName(code.mode) });
                                try out.print(" -O {s}", .{@tagName(code.mode)});
                            },
                        }
                        for (code.link_objects) |link_object| {
                            const name_with_ext = try std.fmt.allocPrint(allocator, "{}{}", .{ link_object, obj_ext });
                            const full_path_object = try fs.path.join(
                                allocator,
                                &[_][]const u8{ tmp_dir_name, name_with_ext },
                            );
                            try build_args.append(full_path_object);
                            try out.print(" {s}", .{name_with_ext});
                        }
                        if (code.link_libc) {
                            try build_args.append("-lc");
                            try out.print(" -lc", .{});
                        }
                        const target = try std.zig.CrossTarget.parse(.{
                            .arch_os_abi = code.target_str orelse "native",
                        });
                        if (code.target_str) |triple| {
                            try build_args.appendSlice(&[_][]const u8{ "-target", triple });
                            if (!code.is_inline) {
                                try out.print(" -target {}", .{triple});
                            }
                        }
                        if (expected_outcome == .BuildFail) {
                            const result = try ChildProcess.exec(.{
                                .allocator = allocator,
                                .argv = build_args.items,
                                .env_map = &env_map,
                                .max_output_bytes = max_doc_file_size,
                            });
                            switch (result.term) {
                                .Exited => |exit_code| {
                                    if (exit_code == 0) {
                                        print("{}\nThe following command incorrectly succeeded:\n", .{result.stderr});
                                        dumpArgs(build_args.items);
                                        return parseError(tokenizer, code.source_token, "example incorrectly compiled", .{});
                                    }
                                },
                                else => {
                                    print("{}\nThe following command crashed:\n", .{result.stderr});
                                    dumpArgs(build_args.items);
                                    return parseError(tokenizer, code.source_token, "example compile crashed", .{});
                                },
                            }
                            const escaped_stderr = try escapeHtml(allocator, result.stderr);
                            const colored_stderr = try termColor(allocator, escaped_stderr);
                            try out.print("\n{}</code></pre>\n", .{colored_stderr});
                            break :code_block;
                        }
                        const exec_result = exec(allocator, &env_map, build_args.items) catch
                            return parseError(tokenizer, code.source_token, "example failed to compile", .{});

                        if (code.target_str) |triple| {
                            if (mem.startsWith(u8, triple, "wasm32") or
                                mem.startsWith(u8, triple, "riscv64-linux") or
                                (mem.startsWith(u8, triple, "x86_64-linux") and
                                std.Target.current.os.tag != .linux or std.Target.current.cpu.arch != .x86_64))
                            {
                                // skip execution
                                try out.print("</code></pre>\n", .{});
                                break :code_block;
                            }
                        }

                        const path_to_exe_dir = mem.trim(u8, exec_result.stdout, " \r\n");
                        const path_to_exe_basename = try std.fmt.allocPrint(allocator, "{}{}", .{
                            code.name,
                            target.exeFileExt(),
                        });
                        const path_to_exe = try fs.path.join(allocator, &[_][]const u8{
                            path_to_exe_dir,
                            path_to_exe_basename,
                        });
                        const run_ags = &[_][]const u8{path_to_exe};

                        var exited_with_signal = false;

                        const result = if (expected_outcome == ExpectedOutcome.Fail) blk: {
                            const result = try ChildProcess.exec(.{
                                .allocator = allocator,
                                .argv = run_args,
                                .env_map = &env_map,
                                .max_output_bytes = max_doc_file_size,
                            });
                            switch (result.term) {
                                .Exited => |exit_code| {
                                    if (exit_code == 0) {
                                        print("{}\nThe following command incorrectly succeeded:\n", .{result.stderr});
                                        dumpArgs(run_args);
                                        return parseError(tokenizer, code.source_token, "example incorrectly compiled", .{});
                                    }
                                },
                                .Signal => exited_with_signal = true,
                                else => {},
                            }
                            break :blk result;
                        } else blk: {
                            break :blk exec(allocator, &env_map, run_args) catch return parseError(tokenizer, code.source_token, "example crashed", .{});
                        };

                        const escaped_stderr = try escapeHtml(allocator, result.stderr);
                        const escaped_stdout = try escapeHtml(allocator, result.stdout);

                        const colored_stderr = try termColor(allocator, escaped_stderr);
                        const colored_stdout = try termColor(allocator, escaped_stdout);

                        try out.print("\n$ ./{}\n{}{}", .{ code.name, colored_stdout, colored_stderr });
                        if (exited_with_signal) {
                            try out.print("(process terminated by signal)", .{});
                        }
                        try out.print("</code></pre>\n", .{});
                    },
                    Code.Id.Test => {
                        var test_args = std.ArrayList([]const u8).init(allocator);
                        defer test_args.deinit();

                        try test_args.appendSlice(&[_][]const u8{ zig_exe, "test", tmp_source_file_name });
                        try out.print("<pre><code class=\"shell\">$ zig test {}.zig", .{code.name});
                        switch (code.mode) {
                            .Debug => {},
                            else => {
                                try test_args.appendSlice(&[_][]const u8{ "-O", @tagName(code.mode) });
                                try out.print(" -O {s}", .{@tagName(code.mode)});
                            },
                        }
                        if (code.link_libc) {
                            try test_args.append("-lc");
                            try out.print(" -lc", .{});
                        }
                        if (code.target_str) |triple| {
                            try test_args.appendSlice(&[_][]const u8{ "-target", triple });
                            try out.print(" -target {}", .{triple});
                        }
                        const result = exec(allocator, &env_map, test_args.items) catch return parseError(tokenizer, code.source_token, "test failed", .{});
                        const escaped_stderr = try escapeHtml(allocator, result.stderr);
                        const escaped_stdout = try escapeHtml(allocator, result.stdout);
                        try out.print("\n{}{}</code></pre>\n", .{ escaped_stderr, escaped_stdout });
                    },
                    Code.Id.TestError => |error_match| {
                        var test_args = std.ArrayList([]const u8).init(allocator);
                        defer test_args.deinit();

                        try test_args.appendSlice(&[_][]const u8{
                            zig_exe,
                            "test",
                            "--color",
                            "on",
                            tmp_source_file_name,
                        });
                        try out.print("<pre><code class=\"shell\">$ zig test {}.zig", .{code.name});
                        switch (code.mode) {
                            .Debug => {},
                            else => {
                                try test_args.appendSlice(&[_][]const u8{ "-O", @tagName(code.mode) });
                                try out.print(" -O {s}", .{@tagName(code.mode)});
                            },
                        }
                        const result = try ChildProcess.exec(.{
                            .allocator = allocator,
                            .argv = test_args.items,
                            .env_map = &env_map,
                            .max_output_bytes = max_doc_file_size,
                        });
                        switch (result.term) {
                            .Exited => |exit_code| {
                                if (exit_code == 0) {
                                    print("{}\nThe following command incorrectly succeeded:\n", .{result.stderr});
                                    dumpArgs(test_args.items);
                                    return parseError(tokenizer, code.source_token, "example incorrectly compiled", .{});
                                }
                            },
                            else => {
                                print("{}\nThe following command crashed:\n", .{result.stderr});
                                dumpArgs(test_args.items);
                                return parseError(tokenizer, code.source_token, "example compile crashed", .{});
                            },
                        }
                        if (mem.indexOf(u8, result.stderr, error_match) == null) {
                            print("{}\nExpected to find '{}' in stderr\n", .{ result.stderr, error_match });
                            return parseError(tokenizer, code.source_token, "example did not have expected compile error", .{});
                        }
                        const escaped_stderr = try escapeHtml(allocator, result.stderr);
                        const colored_stderr = try termColor(allocator, escaped_stderr);
                        try out.print("\n{}</code></pre>\n", .{colored_stderr});
                    },

                    Code.Id.TestSafety => |error_match| {
                        var test_args = std.ArrayList([]const u8).init(allocator);
                        defer test_args.deinit();

                        try test_args.appendSlice(&[_][]const u8{
                            zig_exe,
                            "test",
                            tmp_source_file_name,
                        });
                        var mode_arg: []const u8 = "";
                        switch (code.mode) {
                            .Debug => {},
                            .ReleaseSafe => {
                                try test_args.append("-OReleaseSafe");
                                mode_arg = "-OReleaseSafe";
                            },
                            .ReleaseFast => {
                                try test_args.append("-OReleaseFast");
                                mode_arg = "-OReleaseFast";
                            },
                            .ReleaseSmall => {
                                try test_args.append("-OReleaseSmall");
                                mode_arg = "-OReleaseSmall";
                            },
                        }

                        const result = try ChildProcess.exec(.{
                            .allocator = allocator,
                            .argv = test_args.items,
                            .env_map = &env_map,
                            .max_output_bytes = max_doc_file_size,
                        });
                        switch (result.term) {
                            .Exited => |exit_code| {
                                if (exit_code == 0) {
                                    print("{}\nThe following command incorrectly succeeded:\n", .{result.stderr});
                                    dumpArgs(test_args.items);
                                    return parseError(tokenizer, code.source_token, "example test incorrectly succeeded", .{});
                                }
                            },
                            else => {
                                print("{}\nThe following command crashed:\n", .{result.stderr});
                                dumpArgs(test_args.items);
                                return parseError(tokenizer, code.source_token, "example compile crashed", .{});
                            },
                        }
                        if (mem.indexOf(u8, result.stderr, error_match) == null) {
                            print("{}\nExpected to find '{}' in stderr\n", .{ result.stderr, error_match });
                            return parseError(tokenizer, code.source_token, "example did not have expected runtime safety error message", .{});
                        }
                        const escaped_stderr = try escapeHtml(allocator, result.stderr);
                        const colored_stderr = try termColor(allocator, escaped_stderr);
                        try out.print("<pre><code class=\"shell\">$ zig test {}.zig{}\n{}</code></pre>\n", .{
                            code.name,
                            mode_arg,
                            colored_stderr,
                        });
                    },
                    Code.Id.Obj => |maybe_error_match| {
                        const name_plus_obj_ext = try std.fmt.allocPrint(allocator, "{}{}", .{ code.name, obj_ext });
                        const tmp_obj_file_name = try fs.path.join(
                            allocator,
                            &[_][]const u8{ tmp_dir_name, name_plus_obj_ext },
                        );
                        var build_args = std.ArrayList([]const u8).init(allocator);
                        defer build_args.deinit();

                        const x = try std.fmt.allocPrint(allocator, "{}.h", .{code.name});
                        const output_h_file_name = try fs.path.join(
                            allocator,
                            &[_][]const u8{ tmp_dir_name, name_plus_h_ext },
                        );

                        try build_args.appendSlice(&[_][]const u8{
                            zig_exe,
                            "build-obj",
                            tmp_source_file_name,
                            "--color",
                            "on",
                            "--name",
                            code.name,
                            try std.fmt.allocPrint(allocator, "-femit-bin={s}{c}{s}", .{
                                tmp_dir_name, fs.path.sep, name_plus_obj_ext,
                            }),
                        });
                        if (!code.is_inline) {
                            try out.print("<pre><code class=\"shell\">$ zig build-obj {}.zig", .{code.name});
                        }

                        switch (code.mode) {
                            .Debug => {},
                            else => {
                                try build_args.appendSlice(&[_][]const u8{ "-O", @tagName(code.mode) });
                                if (!code.is_inline) {
                                    try out.print(" -O {s}", .{@tagName(code.mode)});
                                }
                            },
                        }

                        if (code.target_str) |triple| {
                            try build_args.appendSlice(&[_][]const u8{ "-target", triple });
                            try out.print(" -target {}", .{triple});
                        }

                        if (maybe_error_match) |error_match| {
                            const result = try ChildProcess.exec(.{
                                .allocator = allocator,
                                .argv = build_args.items,
                                .env_map = &env_map,
                                .max_output_bytes = max_doc_file_size,
                            });
                            switch (result.term) {
                                .Exited => |exit_code| {
                                    if (exit_code == 0) {
                                        print("{}\nThe following command incorrectly succeeded:\n", .{result.stderr});
                                        dumpArgs(build_args.items);
                                        return parseError(tokenizer, code.source_token, "example build incorrectly succeeded", .{});
                                    }
                                },
                                else => {
                                    print("{}\nThe following command crashed:\n", .{result.stderr});
                                    dumpArgs(build_args.items);
                                    return parseError(tokenizer, code.source_token, "example compile crashed", .{});
                                },
                            }
                            if (mem.indexOf(u8, result.stderr, error_match) == null) {
                                print("{}\nExpected to find '{}' in stderr\n", .{ result.stderr, error_match });
                                return parseError(tokenizer, code.source_token, "example did not have expected compile error message", .{});
                            }
                            const escaped_stderr = try escapeHtml(allocator, result.stderr);
                            const colored_stderr = try termColor(allocator, escaped_stderr);
                            try out.print("\n{}", .{colored_stderr});
                        } else {
                            _ = exec(allocator, &env_map, build_args.items) catch return parseError(tokenizer, code.source_token, "example failed to compile", .{});
                        }
                        if (!code.is_inline) {
                            try out.print("</code></pre>\n", .{});
                        }
                    },
                    Code.Id.Lib => {
                        const bin_basename = try std.zig.binNameAlloc(allocator, .{
                            .root_name = code.name,
                            .target = std.Target.current,
                            .output_mode = .Lib,
                        });

                        var test_args = std.ArrayList([]const u8).init(allocator);
                        defer test_args.deinit();

                        try test_args.appendSlice(&[_][]const u8{
                            zig_exe,
                            "build-lib",
                            tmp_source_file_name,
                            try std.fmt.allocPrint(allocator, "-femit-bin={s}{s}{s}", .{
                                tmp_dir_name, fs.path.sep_str, bin_basename,
                            }),
                        });
                        try out.print("<pre><code class=\"shell\">$ zig build-lib {}.zig", .{code.name});
                        switch (code.mode) {
                            .Debug => {},
                            else => {
                                try test_args.appendSlice(&[_][]const u8{ "-O", @tagName(code.mode) });
                                try out.print(" -O {s}", .{@tagName(code.mode)});
                            },
                        }
                        if (code.target_str) |triple| {
                            try test_args.appendSlice(&[_][]const u8{ "-target", triple });
                            try out.print(" -target {}", .{triple});
                        }
                        const result = exec(allocator, &env_map, test_args.items) catch return parseError(tokenizer, code.source_token, "test failed", .{});
                        const escaped_stderr = try escapeHtml(allocator, result.stderr);
                        const escaped_stdout = try escapeHtml(allocator, result.stdout);
                        try out.print("\n{}{}</code></pre>\n", .{ escaped_stderr, escaped_stdout });
                    },
                }
                print("OK\n", .{});
            },
        }
    }
}

fn exec(allocator: *mem.Allocator, env_map: *std.BufMap, args: []const []const u8) !ChildProcess.ExecResult {
    const result = try ChildProcess.exec(.{
        .allocator = allocator,
        .argv = args,
        .env_map = env_map,
        .max_output_bytes = max_doc_file_size,
    });
    switch (result.term) {
        .Exited => |exit_code| {
            if (exit_code != 0) {
                print("{}\nThe following command exited with code {}:\n", .{ result.stderr, exit_code });
                dumpArgs(args);
                return error.ChildExitError;
            }
        },
        else => {
            print("{}\nThe following command crashed:\n", .{result.stderr});
            dumpArgs(args);
            return error.ChildCrashed;
        },
    }
    return result;
}

fn getBuiltinCode(allocator: *mem.Allocator, env_map: *std.BufMap, zig_exe: []const u8) ![]const u8 {
    const result = try exec(allocator, env_map, &[_][]const u8{ zig_exe, "build-obj", "--show-builtin" });
    return result.stdout;
}

fn dumpArgs(args: []const []const u8) void {
    for (args) |arg|
        print("{} ", .{arg})
    else
        print("\n", .{});
}
