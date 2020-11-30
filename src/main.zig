const std = @import("std");
const clap = @import("clap");
const io = std.io;
const fs = std.fs;
const mem = std.mem;
const process = std.process;

const doctest = @import("./doctest.zig");

const max_doc_file_size = 10 * 1024 * 1024; // TODO: this should be overridable by the user
const CommandLineCommand = enum {
    @"inline",
    syntax,
    build,
    run,
    @"test",
    help,
    @"--help",
};

// TODO: test (and maybe run?) should differentiate between panics and other error conditions.
// TODO: integrate with hugo & check that output is correct

// TODO: tests?
// TODO: run should accept arguments for the executable
// TODO: I believe the original code had also a syntax + semantic analisys mode.
// TODO: refactor duplicated code
// TODO: json output mode?
// TODO: caching, of course!
// TODO: code_begin + syntax used to mean --obj, why? now we're changing those to just syntax. Bad idea?
// TODO: cd into the temp directory to produce cleaner outputs
// TODO: make sure to match --fail errors in all commands

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const allocator = &arena.allocator;

    var args_it = try clap.args.OsIterator.init(allocator);
    defer args_it.deinit();

    const command_name = (try args_it.next()) orelse @panic("expected command arg");

    @setEvalBranchQuota(10000);
    const command = std.meta.stringToEnum(CommandLineCommand, command_name) orelse @panic("unknown command");
    switch (command) {
        .@"inline" => {
            const summary = "Allows you to place the actual command to run and its options as a comment inside the file.";
            const params = comptime [_]clap.Param(clap.Help){
                clap.parseParam("-h, --help             Display this help message") catch unreachable,
                clap.parseParam("-i, --in_file <PATH>   path to the input file, defaults to stdin") catch unreachable,
                clap.parseParam("-o, --out_file <PATH>  path to the output file, defaults to stdout") catch unreachable,
            };

            var diag: clap.Diagnostic = undefined;
            var args = clap.ComptimeClap(
                clap.Help,
                &params,
            ).parse(allocator, &args_it, &diag) catch |err| {
                // Report any useful error and exit
                diag.report(std.io.getStdErr().outStream(), err) catch {};
                return err;
            };
            check_help(summary, &params, args);

            const input_file_bytes = try read_input(allocator, args.option("--in_file"));
            var buffered_out_stream = try open_output(args.option("--out_file"));

            // TODO: make this a bit flexible
            const prefix = "// zig-doctest: ";
            if (!mem.startsWith(u8, input_file_bytes, prefix)) {
                @panic("the input file doesn't begin with `// zig-doctest: `");
            }

            const first_newline = for (input_file_bytes) |c, idx| {
                if (c == '\n') break idx;
            } else {
                @panic("the script is empty!");
            };

            var iterator = clap.args.ShellIterator.init(
                std.heap.page_allocator,
                input_file_bytes[prefix.len..first_newline],
            );

            const code_without_args_comment = input_file_bytes[first_newline + 1 ..];
            // Read the real command string from the file
            const real_command_name = (try iterator.next()) orelse @panic("expected command arg in zig-doctest comment line");
            const real_command = std.meta.stringToEnum(CommandLineCommand, real_command_name) orelse @panic("unknown command in comment line");
            switch (real_command) {
                .@"inline" => @panic("`inline` can only be used as an actual command line argument"),
                .syntax => try do_syntax(allocator, &iterator, true, code_without_args_comment, buffered_out_stream),
                .run => try do_run(allocator, &iterator, true, code_without_args_comment, buffered_out_stream),
                .build => try do_build(allocator, &iterator, true, code_without_args_comment, buffered_out_stream),
                .@"test" => try do_test(allocator, &iterator, true, code_without_args_comment, buffered_out_stream),
                .help, .@"--help" => @panic("`help` cannot be used inside the zig-doctest comment"),
            }
        },
        .syntax => try do_syntax(allocator, &args_it, false, {}, {}),
        .build => try do_build(allocator, &args_it, false, {}, {}),
        .run => try do_run(allocator, &args_it, false, {}, {}),
        .@"test" => try do_test(allocator, &args_it, false, {}, {}),
        .help, .@"--help" => show_main_help(),
    }
}

fn do_syntax(
    allocator: *mem.Allocator,
    args_it: anytype,
    comptime is_inline: bool,
    cl_input_file_bytes: anytype,
    cl_buffered_out_stream: anytype,
) !void {
    const summary = "Tests that the syntax is valid, without running the code.";
    const params = comptime [_]clap.Param(clap.Help){
        clap.parseParam("-h, --help             Display this help message") catch unreachable,
        clap.parseParam("-i, --in_file <PATH>   path to the input file, defaults to stdin") catch unreachable,
        clap.parseParam("-o, --out_file <PATH>  path to the output file, defaults to stdout") catch unreachable,
    };

    var diag: clap.Diagnostic = undefined;
    var args = clap.ComptimeClap(
        clap.Help,
        &params,
    ).parse(allocator, args_it, &diag) catch |err| {
        // Report any useful error and exit
        diag.report(std.io.getStdErr().outStream(), err) catch {};
        return err;
    };
    check_help(summary, &params, args);

    const input_file_bytes = blk: {
        if (is_inline) {
            if (args.option("--in_file")) |_| {
                @panic("`--in_file` is not allowed in comment arguments!");
            }
            break :blk cl_input_file_bytes;
        }
        break :blk try read_input(allocator, args.option("--in_file"));
    };

    var buffered_out_stream = blk: {
        if (is_inline) {
            if (args.option("--out_file")) |_| {
                @panic("`--out_file` is not allowed in comment arguments!");
            }
            break :blk cl_buffered_out_stream;
        }
        break :blk try open_output(args.option("--out_file"));
    };

    try doctest.highlightZigCode(input_file_bytes, buffered_out_stream.writer());
    try buffered_out_stream.flush();
}

fn do_build(
    allocator: *mem.Allocator,
    args_it: anytype,
    comptime is_inline: bool,
    cl_input_file_bytes: anytype,
    cl_buffered_out_stream: anytype,
) !void {
    // TODO: it seems a good idea to have a "check output" flag, rather than
    // tying output checking just to failure cases.
    const summary = "Builds a code snippet, checking for the build to succeed or fail as expected.";
    const params = comptime [_]clap.Param(clap.Help){
        clap.parseParam("-h, --help                     Display this help message") catch unreachable,
        clap.parseParam("-n, --name <NAME>              Name of the script, defaults to the input filename or `code` when using stdin.") catch unreachable,
        clap.parseParam("-r, --format  <OUTPUT_FORMAT>  Output format, possible values: `exe`, `obj`, `lib`, defaults to `exe`") catch unreachable,
        clap.parseParam("-f, --fail <MATCH>             Expect the build command to encounter a compile error containing some text that is expected to be present in stderr") catch unreachable,
        clap.parseParam("-i, --in_file <PATH>           Path to the input file, defaults to stdin") catch unreachable,
        clap.parseParam("-o, --out_file <PATH>          Path to the output file, defaults to stdout") catch unreachable,
        clap.parseParam("-z, --zig_exe <PATH>           Path to the zig compiler, defaults to `zig` (i.e. assumes zig present in PATH)") catch unreachable,
        clap.parseParam("-t, --target <TARGET>          Compilation target, expected as a arch-os-abi tripled (e.g. `x86_64-linux-gnu`) defaults to `native`") catch unreachable,
        clap.parseParam("-k, --keep                     Don't delete the temp folder, useful for debugging the resulting executable.") catch unreachable,
    };

    var diag: clap.Diagnostic = undefined;
    var args = clap.ComptimeClap(
        clap.Help,
        &params,
    ).parse(allocator, args_it, &diag) catch |err| {
        // Report any useful error and exit
        diag.report(std.io.getStdErr().outStream(), err) catch {};
        return err;
    };
    check_help(summary, &params, args);

    const input_file_bytes = blk: {
        if (is_inline) {
            if (args.option("--in_file")) |_| {
                @panic("`--in_file` is not allowed in comment arguments!");
            }
            break :blk cl_input_file_bytes;
        }
        break :blk try read_input(allocator, args.option("--in_file"));
    };

    var buffered_out_stream = blk: {
        if (is_inline) {
            if (args.option("--out_file")) |_| {
                @panic("`--out_file` is not allowed in comment arguments!");
            }
            break :blk cl_buffered_out_stream;
        }
        break :blk try open_output(args.option("--out_file"));
    };

    // Choose the right name for this example
    const name = args.option("--name") orelse choose_test_name(args.option("--in_file"));

    // Print the filename element
    try buffered_out_stream.writer().print("<p class=\"file\">{}.zig</p>", .{name});

    // Produce the syntax highlighting
    try doctest.highlightZigCode(input_file_bytes, buffered_out_stream.writer());

    // Grab env map and set max output size
    var env_map = try process.getEnvMap(allocator);
    try env_map.set("ZIG_DEBUG_COLOR", "1");

    // Create a temp folder
    const tmp_dir_name: []const u8 = while (true) {
        const tmp_dir_name = try randomized_path_name(allocator, "doctest-");
        fs.cwd().makePath(tmp_dir_name) catch |err| switch (err) {
            error.PathAlreadyExists => continue,
            else => |e| return e,
        };

        break tmp_dir_name;
    } else unreachable;
    defer if (!args.flag("--keep")) {
        fs.cwd().deleteTree(tmp_dir_name) catch {
            @panic("Error while deleting the temp directory!");
        };
    };

    // Build the code and write the resulting output
    const output_format = if (args.option("--format")) |format|
        std.meta.stringToEnum(doctest.BuildCommand.Format, format) orelse {
            std.debug.print("Invalid value for --format!\n", .{});
            return error.InvalidFormat;
        }
    else
        .exe;

    _ = try doctest.runBuild(
        allocator,
        input_file_bytes,
        buffered_out_stream.writer(),
        &env_map,
        args.option("--zig_exe") orelse "zig",
        doctest.BuildCommand{
            .name = name,
            .format = output_format,
            .tmp_dir_name = tmp_dir_name,
            .expected_outcome = if (args.option("--fail")) |f| .{ .Failure = f } else .Success,
            .target_str = args.option("--target"),
        },
    );

    try buffered_out_stream.flush();
}

fn do_run(
    allocator: *mem.Allocator,
    args_it: anytype,
    comptime is_inline: bool,
    cl_input_file_bytes: anytype,
    cl_buffered_out_stream: anytype,
) !void {

    // TODO: it seems a good idea to have a "check output" flag, rather than
    // tying output checking just to failure cases.
    const summary = "Compiles and runs a code snippet, checking for the execution to succeed or fail as expected.";
    const params = comptime [_]clap.Param(clap.Help){
        clap.parseParam("-h, --help                     Display this help message") catch unreachable,
        clap.parseParam("-n, --name <NAME>              Name of the script, defaults to the input filename or `code` when using stdin.") catch unreachable,
        clap.parseParam("-f, --fail <MATCH>             Expect the execution to encounter a runtime error, optionally provide some text that is expected to be present in stderr") catch unreachable,
        clap.parseParam("-i, --in_file <PATH>           Path to the input file, defaults to stdin") catch unreachable,
        clap.parseParam("-o, --out_file <PATH>          Path to the output file, defaults to stdout") catch unreachable,
        clap.parseParam("-z, --zig_exe <PATH>           Path to the zig compiler, defaults to `zig` (i.e. assumes zig present in PATH)") catch unreachable,
    };

    var diag: clap.Diagnostic = undefined;
    var args = clap.ComptimeClap(
        clap.Help,
        &params,
    ).parse(allocator, args_it, &diag) catch |err| {
        // Report any useful error and exit
        diag.report(std.io.getStdErr().outStream(), err) catch {};
        return err;
    };
    check_help(summary, &params, args);

    const input_file_bytes = blk: {
        if (is_inline) {
            if (args.option("--in_file")) |_| {
                @panic("`--in_file` is not allowed in comment arguments!");
            }
            break :blk cl_input_file_bytes;
        }
        break :blk try read_input(allocator, args.option("--in_file"));
    };

    var buffered_out_stream = blk: {
        if (is_inline) {
            if (args.option("--out_file")) |_| {
                @panic("`--out_file` is not allowed in comment arguments!");
            }
            break :blk cl_buffered_out_stream;
        }
        break :blk try open_output(args.option("--out_file"));
    };

    // Choose the right name for this example
    const name = args.option("--name") orelse choose_test_name(args.option("--in_file"));

    // Print the filename element
    try buffered_out_stream.writer().print("<p class=\"file\">{}.zig</p>", .{name});

    // Produce the syntax highlighting
    try doctest.highlightZigCode(input_file_bytes, buffered_out_stream.writer());

    // Grab env map and set max output size
    var env_map = try process.getEnvMap(allocator);
    try env_map.set("ZIG_DEBUG_COLOR", "1");

    // Create a temp folder
    const tmp_dir_name = while (true) {
        const tmp_dir_name = try randomized_path_name(allocator, "doctest-");
        fs.cwd().makePath(tmp_dir_name) catch |err| switch (err) {
            error.PathAlreadyExists => continue,
            else => |e| return e,
        };

        break tmp_dir_name;
    } else unreachable;
    defer fs.cwd().deleteTree(tmp_dir_name) catch {
        @panic("Error while deleting the temp directory!");
    };

    // Build the code and write the resulting output
    const executable_path = try doctest.runBuild(
        allocator,
        input_file_bytes,
        buffered_out_stream.writer(),
        &env_map,
        args.option("--zig_exe") orelse "zig",
        doctest.BuildCommand{
            .format = .exe,
            .name = name,
            .tmp_dir_name = tmp_dir_name,
            .expected_outcome = .SilentSuccess,
            .target_str = null,
        },
    );

    // Missing executable path means that the build failed.
    if (executable_path) |exe_path| {
        const run_outcome = try doctest.runExe(
            allocator,
            exe_path,
            buffered_out_stream.writer(),
            &env_map,
            doctest.RunCommand{
                .expected_outcome = if (args.option("--fail")) |f| .{ .Failure = f } else .Success,
            },
        );
    }

    try buffered_out_stream.flush();
}

fn do_test(
    allocator: *mem.Allocator,
    args_it: anytype,
    comptime is_inline: bool,
    cl_input_file_bytes: anytype,
    cl_buffered_out_stream: anytype,
) !void {
    const summary = "Tests a code snippet, checking for the test to succeed or fail as expected.";
    const params = comptime [_]clap.Param(clap.Help){
        clap.parseParam("-h, --help                     Display this help message") catch unreachable,
        clap.parseParam("-n, --name <NAME>              Name of the script, defaults to the input filename or `code` when using stdin.") catch unreachable,
        clap.parseParam("-f, --fail <MATCH>             Expect the test to fail, optionally provide some text that is expected to be present in stderr") catch unreachable,
        clap.parseParam("-i, --in_file <PATH>           Path to the input file, defaults to stdin") catch unreachable,
        clap.parseParam("-o, --out_file <PATH>          Path to the output file, defaults to stdout") catch unreachable,
        clap.parseParam("-z, --zig_exe <PATH>           Path to the zig compiler, defaults to `zig` (i.e. assumes zig present in PATH)") catch unreachable,
    };

    var diag: clap.Diagnostic = undefined;
    var args = clap.ComptimeClap(
        clap.Help,
        &params,
    ).parse(allocator, args_it, &diag) catch |err| {
        // Report any useful error and exit
        diag.report(std.io.getStdErr().outStream(), err) catch {};
        return err;
    };
    check_help(summary, &params, args);

    const input_file_bytes = blk: {
        if (is_inline) {
            if (args.option("--in_file")) |_| {
                @panic("`--in_file` is not allowed in comment arguments!");
            }
            break :blk cl_input_file_bytes;
        }
        break :blk try read_input(allocator, args.option("--in_file"));
    };

    var buffered_out_stream = blk: {
        if (is_inline) {
            if (args.option("--out_file")) |_| {
                @panic("`--out_file` is not allowed in comment arguments!");
            }
            break :blk cl_buffered_out_stream;
        }
        break :blk try open_output(args.option("--out_file"));
    };

    // Choose the right name for this example
    const name = args.option("--name") orelse choose_test_name(args.option("--in_file"));

    // Print the filename element
    try buffered_out_stream.writer().print("<p class=\"file\">{}.zig</p>", .{name});

    // Produce the syntax highlighting
    try doctest.highlightZigCode(input_file_bytes, buffered_out_stream.writer());

    // Grab env map and set max output size
    var env_map = try process.getEnvMap(allocator);
    try env_map.set("ZIG_DEBUG_COLOR", "1");

    // Create a temp folder
    const tmp_dir_name = while (true) {
        const tmp_dir_name = try randomized_path_name(allocator, "doctest-");
        fs.cwd().makePath(tmp_dir_name) catch |err| switch (err) {
            error.PathAlreadyExists => continue,
            else => |e| return e,
        };

        break tmp_dir_name;
    } else unreachable;
    defer fs.cwd().deleteTree(tmp_dir_name) catch {
        @panic("Error while deleting the temp directory!");
    };

    const test_outcome = try doctest.runTest(
        allocator,
        input_file_bytes,
        buffered_out_stream.writer(),
        &env_map,
        args.option("--zig_exe") orelse "zig",
        doctest.TestCommand{
            .name = name,
            .expected_outcome = if (args.option("--fail")) |f| .{ .Failure = f } else .Success,
            .tmp_dir_name = tmp_dir_name,
        },
    );

    try buffered_out_stream.flush();
}

fn check_help(comptime summary: []const u8, comptime params: anytype, args: anytype) void {
    if (args.flag("--help")) {
        std.debug.print("{}\n\n", .{summary});
        clap.help(io.getStdErr().writer(), params) catch {};
        std.debug.print("\n", .{});
        std.os.exit(0);
    }
}

// Nothing to see here, just a normal elegant generic type.
const BufferedFileType = @TypeOf(io.bufferedWriter((std.fs.File{ .handle = 0 }).writer()));
fn open_output(output: ?[]const u8) !BufferedFileType {
    const out_file = if (output) |out_file_name|
        try fs.cwd().createFile(out_file_name, .{})
    else
        io.getStdOut();

    return io.bufferedWriter(out_file.writer());
}

fn read_input(allocator: *mem.Allocator, input: ?[]const u8) ![]const u8 {
    const in_file = if (input) |in_file_name|
        try fs.cwd().openFile(in_file_name, .{ .read = true })
    else
        io.getStdIn();
    defer in_file.close();

    return try in_file.reader().readAllAlloc(allocator, max_doc_file_size);
}

// TODO: this way of chopping of the file extension seems kinda dumb.
// What should we do if somebody is passing in a .md file, for example?
fn choose_test_name(in_file: ?[]const u8) ?[]const u8 {
    return if (in_file) |in_file_name| blk: {
        const name_with_ext = fs.path.basename(in_file_name);
        if (mem.endsWith(u8, name_with_ext, ".zig")) {
            break :blk name_with_ext[0 .. name_with_ext.len - 3];
        }
        break :blk name_with_ext;
    } else null;
}

fn randomized_path_name(allocator: *mem.Allocator, prefix: []const u8) ![]const u8 {
    const seed = @bitCast(u64, @truncate(i64, std.time.nanoTimestamp()));
    var xoro = std.rand.Xoroshiro128.init(seed);

    var buf: [4]u8 = undefined;
    xoro.random.bytes(&buf);

    var name = try allocator.alloc(u8, prefix.len + 8);
    errdefer allocator.free(name);

    return try std.fmt.bufPrint(name, "{}{x}", .{ prefix, buf });
}

fn show_main_help() void {
    std.debug.print("{}", .{
        \\Doctest runs a Zig code snippet and provides both syntax 
        \\highlighting and colored output in HTML format.
        \\
        \\Available commands: syntax, build, test, run, inline, help.
        \\
        \\Put the `--help` flag after the command to get command-specific
        \\help.
        \\
        \\Examples:
        \\
        \\ ./doctest syntax --in_file=foo.zig 
        \\ ./doctest build --obj --fail "not handled in switch"
        \\ ./doctest test --out_file bar.zig --zig_exe="/Downloads/zig/bin/zig"
        \\
        \\
    });
}
