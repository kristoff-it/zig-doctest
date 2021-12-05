const std = @import("std");
const mem = std.mem;
const print = std.debug.print;
const fs = std.fs;
const ChildProcess = std.ChildProcess;
const process = std.process;

const render_utils = @import("render_utils.zig");

/// This struct bundles all the options necessary to run a snippet of code.
/// `id` is used to differentiate between the different commands (e.g. build-exe, test).
pub const BuildCommand = struct {
    format: Format,
    name: ?[]const u8 = null,
    is_inline: bool = false,
    mode: std.builtin.Mode = .Debug,
    link_objects: []const []const u8 = &[0][]u8{},
    target_str: ?[]const u8 = null,
    link_libc: bool = false,
    disable_cache: bool = false, // TODO make sure it's used somewhere
    tmp_dir_name: []const u8, // TODO, maybe this should be automated at a different level?
    expected_outcome: union(enum) { SilentSuccess, Success, Failure: []const u8 } = .Success,
    max_doc_file_size: usize = 1024 * 1024 * 1, // 1MB TODO: change?

    pub const obj_ext = (std.zig.CrossTarget{}).dynamicLibSuffix();
    pub const Format = enum { exe, obj, lib };
};

fn dumpArgs(args: []const []const u8) void {
    for (args) |arg|
        print("{s} ", .{arg})
    else
        print("\n", .{});
}

pub fn runBuild(
    allocator: mem.Allocator,
    input_bytes: []const u8,
    out: anytype,
    env_map: *std.BufMap,
    zig_exe: []const u8,
    cmd: BuildCommand,
) !?[]const u8 {
    const name = cmd.name orelse "test";
    const zig_command = switch (cmd.format) {
        .exe => "build-exe",
        .obj => "build-obj",
        .lib => "build-lib",
    };

    // Save the code as a temp .zig file and start preparing
    // the argument list for the Zig compiler.
    var build_args = std.ArrayList([]const u8).init(allocator);
    defer build_args.deinit();
    {
        const name_plus_ext = try std.fmt.allocPrint(allocator, "{s}.zig", .{name});
        const tmp_source_file_name = try fs.path.join(
            allocator,
            &[_][]const u8{ cmd.tmp_dir_name, name_plus_ext },
        );

        try fs.cwd().writeFile(tmp_source_file_name, input_bytes);

        try build_args.appendSlice(&[_][]const u8{
            zig_exe,          zig_command,
            "--name",         name,
            "--color",        "on",
            "--enable-cache", tmp_source_file_name,
        });
    }

    // Invocation line (continues into the following blocks)
    try out.print("<pre><code class=\"shell\">$ zig {s} {s}.zig", .{ zig_command, name });

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
        const name_with_ext = try std.fmt.allocPrint(allocator, "{s}{s}", .{ link_object, BuildCommand.obj_ext });
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
            try out.print(" -target {s}", .{triple});
        }
    }

    // Create a path for the resulting executable
    const ext = switch (cmd.format) {
        .exe => target.exeFileExt(),
        .obj => target.dynamicLibSuffix(),
        .lib => target.staticLibSuffix(), // TODO: I don't even know how this stupid naming scheme works, please somebody make this correct for me.
    };
    const name_with_ext = try std.fmt.allocPrint(allocator, "{s}{s}", .{ name, ext });
    const path_to_exe = try fs.path.join(allocator, &[_][]const u8{
        cmd.tmp_dir_name,
        name_with_ext,
    });

    try build_args.appendSlice(&[_][]const u8{
        try std.fmt.allocPrint(allocator, "-femit-bin={s}", .{path_to_exe}),
    });

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
                        return path_to_exe;
                    },
                    .Success => {
                        const escaped_stderr = try render_utils.escapeHtml(allocator, result.stderr);
                        const colored_stderr = try render_utils.termColor(allocator, escaped_stderr);
                        try out.print("\n{s}</code></pre>\n", .{colored_stderr});

                        return null;
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
                        return null;
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
