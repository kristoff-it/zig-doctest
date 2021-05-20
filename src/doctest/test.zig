const std = @import("std");
const mem = std.mem;
const print = std.debug.print;
const fs = std.fs;
const ChildProcess = std.ChildProcess;
const process = std.process;

const render_utils = @import("render_utils.zig");

pub const TestCommand = struct {
    name: ?[]const u8 = null,
    is_inline: bool = false,
    mode: std.builtin.Mode = .Debug,
    link_objects: []const []const u8 = &[0][]u8{},
    // target_str: ?[]const u8 = null,
    link_libc: bool = false,
    disable_cache: bool = false, // TODO make sure it's used somewhere
    tmp_dir_name: []const u8, // TODO, maybe this should be automated at a different level?
    expected_outcome: union(enum) { Success, Failure: []const u8 } = .Success,
    max_doc_file_size: usize = 1024 * 1024 * 1, // 1MB TODO: change?

    pub const obj_ext = (std.zig.CrossTarget{}).oFileExt();
};

pub fn runTest(
    allocator: *mem.Allocator,
    input_bytes: []const u8,
    out: anytype,
    env_map: *std.BufMap,
    zig_exe: []const u8,
    cmd: TestCommand,
) !void {
    const name = cmd.name orelse "test";
    const name_plus_ext = try std.fmt.allocPrint(allocator, "{s}.zig", .{name});
    const tmp_source_file_name = try fs.path.join(
        allocator,
        &[_][]const u8{ cmd.tmp_dir_name, name_plus_ext },
    );

    try fs.cwd().writeFile(tmp_source_file_name, input_bytes);

    var test_args = std.ArrayList([]const u8).init(allocator);
    defer test_args.deinit();
    try test_args.appendSlice(&[_][]const u8{
        zig_exe,
        "test",
        "--color",
        "on",
        tmp_source_file_name,
    });

    try out.print("<pre><code class=\"shell\">$ zig test {s}.zig", .{name});
    switch (cmd.mode) {
        .Debug => {},
        else => {
            try test_args.appendSlice(&[_][]const u8{ "-O", @tagName(cmd.mode) });
            try out.print(" -O {s}", .{@tagName(cmd.mode)});
        },
    }
    if (cmd.link_libc) {
        try test_args.append("-lc");
        try out.print(" -lc", .{});
    }
    // if (cmd.target_str) |triple| {
    //     try test_args.appendSlice(&[_][]const u8{ "-target", triple });
    //     try out.print(" -target {}", .{triple});
    // }

    // TODO: signal stuff
    var exited_with_signal = false;

    const result = if (cmd.expected_outcome == .Failure) ko: {
        const result = try ChildProcess.exec(.{
            .allocator = allocator,
            .argv = test_args.items,
            .env_map = env_map,
            .max_output_bytes = cmd.max_doc_file_size,
        });

        switch (result.term) {
            .Exited => |exit_code| {
                if (exit_code == 0) {
                    print("{s}\nThe following command incorrectly succeeded:\n", .{result.stderr});
                    render_utils.dumpArgs(test_args.items);
                    // return parseError(tokenizer, code.source_token, "example incorrectly compiled", .{});
                    return;
                }
            },
            .Signal => exited_with_signal = true,
            else => {},
        }
        break :ko result;
    } else ok: {
        break :ok try render_utils.exec(allocator, env_map, cmd.max_doc_file_size, test_args.items);
    };

    if (cmd.expected_outcome == .Failure) {
        const error_match = cmd.expected_outcome.Failure;
        if (mem.indexOf(u8, result.stderr, error_match) == null) {
            print("Expected to find '{s}' in stderr\n{s}\n", .{ error_match, result.stderr });
            return error.ErrorMismatch;
        }
    }

    const escaped_stderr = try render_utils.escapeHtml(allocator, result.stderr);
    const escaped_stdout = try render_utils.escapeHtml(allocator, result.stdout);
    const colored_stderr = try render_utils.termColor(allocator, escaped_stderr);
    const colored_stdout = try render_utils.termColor(allocator, escaped_stdout);

    try out.print("\n{s}{s}</code></pre>\n", .{ colored_stderr, colored_stdout });
}
