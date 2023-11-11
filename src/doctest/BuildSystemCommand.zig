const std = @import("std");
const mem = std.mem;
const print = std.debug.print;
const fs = std.fs;
const ChildProcess = std.ChildProcess;
const process = std.process;
const BuildSystemCommand = @This();
const render_utils = @import("render_utils.zig");

name: []const u8,
expected_outcome: union(enum) { SilentSuccess, Success, Failure: []const u8 } = .Success,
max_doc_file_size: usize = 1024 * 1024 * 1,
dirname: []const u8,
tmp_dir_name: []const u8,

pub fn run(
    allocator: mem.Allocator,
    out: anytype,
    env_map: *std.process.EnvMap,
    zig_exe: []const u8,
    args_it: *std.process.ArgIteratorGeneral(.{}),
    cmd: BuildSystemCommand,
) !void {
    const zig_cache_path = try fs.path.join(allocator, &.{ cmd.tmp_dir_name, "zig-cache" });
    const zig_out_path = try fs.path.join(allocator, &.{ cmd.tmp_dir_name, "zig-out" });

    // Save the code as a temp .zig file and start preparing
    // the argument list for the Zig compiler.
    var build_args = std.ArrayList([]const u8).init(allocator);
    defer build_args.deinit();

    try build_args.appendSlice(&[_][]const u8{
        zig_exe,       "build",
        "--color",     "on",
        "--cache-dir", try fs.path.relative(allocator, cmd.dirname, zig_cache_path),
        "--prefix",    try fs.path.relative(allocator, cmd.dirname, zig_out_path),
    });

    // Invocation line (continues into the following blocks)
    try out.print("<pre><code class=\"shell\">$ zig build", .{});

    while (args_it.next()) |arg| {
        try build_args.append(arg);
        try out.print(" {s}", .{arg});
    }

    // Build the script
    const result = try ChildProcess.run(.{
        .allocator = allocator,
        .argv = build_args.items,
        .env_map = env_map,
        .max_output_bytes = cmd.max_doc_file_size,
        .cwd = cmd.dirname,
    });

    // We check the output and confront it with the expected result.
    switch (result.term) {
        .Exited => |exit_code| {
            if (exit_code == 0) { // build succeded
                switch (cmd.expected_outcome) {
                    .SilentSuccess => {
                        return;
                    },
                    .Success => {
                        if (result.stdout.len > 0) {
                            const escaped_stdout = try render_utils.escapeHtml(allocator, result.stdout);
                            try out.print("\n{s}</code></pre>\n", .{escaped_stdout});
                        } else {
                            const escaped_stderr = try render_utils.escapeHtml(allocator, result.stderr);
                            const colored_stderr = try render_utils.termColor(allocator, escaped_stderr);
                            try out.print("\n{s}</code></pre>\n", .{colored_stderr});
                        }

                        return;
                    },
                    .Failure => {
                        print("{s}\nThe following command incorrectly succeeded:\n", .{result.stderr});
                        render_utils.dumpArgs(build_args.items);
                        return error.BuildSuccededWhenExpectingFailure;
                    },
                }
            } else { // build failed
                switch (cmd.expected_outcome) {
                    .Success, .SilentSuccess => {
                        print("{s}\nBuild failed unexpectedly\n", .{result.stderr});
                        render_utils.dumpArgs(build_args.items);
                        return error.BuildFailed;
                    },
                    .Failure => {
                        const escaped_stderr = try render_utils.escapeHtml(allocator, result.stderr);
                        const colored_stderr = try render_utils.termColor(allocator, escaped_stderr);
                        try out.print("\n{s}</code></pre>\n", .{colored_stderr});
                        return;
                    },
                }
            }
        },
        else => {
            print("{s}\nThe following command crashed:\n", .{result.stderr});
            render_utils.dumpArgs(build_args.items);
            // return parseError(tokenizer, code.source_token, "example compile crashed", .{});
            return error.BuildError;
        },
    }
}
