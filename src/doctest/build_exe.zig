const builtin = @import("builtin");
const std = @import("std");
const mem = std.mem;
const print = std.debug.print;
const fs = std.fs;
const ChildProcess = std.ChildProcess;
const process = std.process;

const render_utils = @import("render_utils.zig");

const workaround = [1][]const u8{"bug"};

/// This struct bundles all the options necessary to run a snippet of code.
/// `id` is used to differentiate between the different commands (e.g. build-exe, test).
pub const BuildCommand = struct {
    id: Id,
    name: []const u8 = "code",
    is_inline: bool = false,
    mode: builtin.Mode = .Debug,
    link_objects: []const []const u8 = workaround[0..0],
    target_str: ?[]const u8 = null,
    link_libc: bool = false,
    disable_cache: bool = false, // TODO make sure it's used somewhere
    tmp_dir_name: []const u8, // TODO, maybe this should be automated at a different level?
    expected_outcome: enum { SilentSuccess, Success, Failure } = .Success,
    check_output: ?[]const u8 = null, // TODO: should we differentiate between out and err?
    max_doc_file_size: usize = 1024 * 1024 * 1, // 1MB TODO: change?

    pub const obj_ext = (std.zig.CrossTarget{}).oFileExt();
    pub const Id = enum {
        Exe,
        Obj,
        Lib,
    };
};

fn dumpArgs(args: []const []const u8) void {
    for (args) |arg|
        print("{} ", .{arg})
    else
        print("\n", .{});
}

pub fn buildExe(
    allocator: *mem.Allocator,
    input_bytes: []const u8,
    out: anytype,
    env_map: *std.BufMap,
    zig_exe: []const u8,
    cmd: BuildCommand,
) !?[]const u8 {

    // Save the code as a temp .zig file and start preparing
    // the argument list for the Zig compiler.
    var build_args = std.ArrayList([]const u8).init(allocator);
    defer build_args.deinit();
    {
        const name_plus_ext = try std.fmt.allocPrint(allocator, "{}.zig", .{cmd.name});
        const tmp_source_file_name = try fs.path.join(
            allocator,
            &[_][]const u8{ cmd.tmp_dir_name, name_plus_ext },
        );

        try fs.cwd().writeFile(tmp_source_file_name, input_bytes);

        try build_args.appendSlice(&[_][]const u8{
            zig_exe,          "build-exe",
            "--name",         cmd.name,
            "--color",        "on",
            "--enable-cache", tmp_source_file_name,
        });
    }

    // Invocation line (continues into the following blocks)
    try out.print("<pre><code class=\"shell\">$ zig build-exe {}.zig", .{cmd.name});

    // Add release switches
    switch (cmd.mode) {
        .Debug => {},
        else => {
            try build_args.appendSlice(&[_][]const u8{ "-O", @tagName(cmd.mode) });
            try out.print(" -O {s}", .{@tagName(cmd.mode)});
        },
    }

    // Add link options
    for (cmd.link_objects) |link_object| {
        // TODO: we're setting the obj file extension before parsing
        //       the provided crosstarget string. Prob not ok.
        const name_with_ext = try std.fmt.allocPrint(allocator, "{}{}", .{ link_object, BuildCommand.obj_ext });
        const full_path_object = try fs.path.join(
            allocator,
            &[_][]const u8{ cmd.tmp_dir_name, name_with_ext },
        );
        try build_args.append(full_path_object);
        try out.print(" {s}", .{name_with_ext});
    }
    if (cmd.link_libc) {
        try build_args.append("-lc");
        try out.print(" -lc", .{});
    }

    // Add target options
    // TODO: solve the target mistery and win one less symbol in the lexical scope!
    const target = try std.zig.CrossTarget.parse(.{
        .arch_os_abi = cmd.target_str orelse "native",
    });
    // TODO: is_inline is a switch that prevents the target option from being
    // shown in the output. It seems a stylistical thing, do we keep it?
    if (cmd.target_str) |triple| {
        try build_args.appendSlice(&[_][]const u8{ "-target", triple });
        if (!cmd.is_inline) {
            try out.print(" -target {}", .{triple});
        }
    }

    // Build the script
    const result = try ChildProcess.exec(.{
        .allocator = allocator,
        .argv = build_args.items,
        .env_map = env_map,
        .max_output_bytes = cmd.max_doc_file_size,
    });

    // We check the output and confront it with the expected result.
    switch (result.term) {
        .Exited => |exit_code| {
            if (exit_code == 0) { // build succeded
                switch (cmd.expected_outcome) {
                    .SilentSuccess => {
                        const path_to_exe_dir = mem.trim(u8, result.stdout, " \r\n");
                        const path_to_exe_basename = try std.fmt.allocPrint(allocator, "{}{}", .{
                            cmd.name,
                            target.exeFileExt(),
                        });
                        const path_to_exe = try fs.path.join(allocator, &[_][]const u8{
                            path_to_exe_dir,
                            path_to_exe_basename,
                        });

                        return path_to_exe;
                    },
                    .Success => {
                        const escaped_stderr = try render_utils.escapeHtml(allocator, result.stderr);
                        const colored_stderr = try render_utils.termColor(allocator, escaped_stderr);
                        try out.print("\n{}</code></pre>\n", .{colored_stderr});

                        return null; // TODO: return values are confusing the way they are now.
                    },
                    .Failure => {
                        print("{}\nThe following command incorrectly succeeded:\n", .{result.stderr});
                        render_utils.dumpArgs(build_args.items);
                        return null;
                    },
                }
            } else { // build failed
                switch (cmd.expected_outcome) {
                    .Success, .SilentSuccess => {
                        print("{}\nBuild failed unexpectedly\n", .{result.stderr});
                        render_utils.dumpArgs(build_args.items);
                        return null;
                        // return parseError(tokenizer, code.source_token, "example failed to compile", .{});
                    },
                    .Failure => {
                        const escaped_stderr = try render_utils.escapeHtml(allocator, result.stderr);
                        const colored_stderr = try render_utils.termColor(allocator, escaped_stderr);
                        try out.print("\n{}</code></pre>\n", .{colored_stderr});
                        return null;
                    },
                }
            }
        },
        else => {
            print("{}\nThe following command crashed:\n", .{result.stderr});
            render_utils.dumpArgs(build_args.items);
            // return parseError(tokenizer, code.source_token, "example compile crashed", .{});
            return error.BuildError;
        },
    }
}
