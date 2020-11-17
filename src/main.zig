const std = @import("std");
const clap = @import("clap");
const io = std.io;
const fs = std.fs;
const mem = std.mem;
const process = std.process;

const doctest = @import("./doctest.zig");

// TODO: make the temp directory unique so that we
//       can have multiple instances running at the same time!
const tmp_dir_name = "docgen_tmp";
const test_out_path = tmp_dir_name ++ fs.path.sep_str ++ "test" ++ exe_ext;
const max_doc_file_size = 10 * 1024 * 1024;
const CLICommand = enum {
    syntax,
    @"build-exe",
    run,
    @"test",
};

// TODO: run should accept arguments for the executable
// TODO: test (and maybe run?) should differentiate between panics and other error conditions.
// TODO: manage temp paths
// TODO: build obj and lib ??? C stuff???
// TODO: cleanup pass to ensure everything works
// TODO: refactor duplicated code
// TODO: json output mode?

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const allocator = &arena.allocator;

    var args_it = try clap.args.OsIterator.init(allocator);
    defer args_it.deinit();

    const command_name = (try args_it.next()) orelse @panic("expected command arg");

    @setEvalBranchQuota(10000);
    const command = std.meta.stringToEnum(CLICommand, command_name) orelse @panic("unknown command");
    switch (command) {
        .syntax => {
            const summary = "Tests that the syntax is valid, without running the code.";
            const params = comptime [_]clap.Param(clap.Help){
                clap.parseParam("-h, --help             Display this help message") catch unreachable,
                clap.parseParam("-i, --in_file <PATH>   path to the input file, defaults to stdin") catch unreachable,
                clap.parseParam("-o, --out_file <PATH>  path to the output file, defaults to stdout") catch unreachable,
            };

            var diag: clap.Diagnostic = undefined;
            var args = clap.ComptimeClap(
                clap.Help,
                clap.args.OsIterator,
                &params,
            ).parse(allocator, &args_it, &diag) catch |err| {
                // Report any useful error and exit
                diag.report(std.io.getStdErr().outStream(), err) catch {};
                return err;
            };
            check_help(summary, &params, args);

            const input_file_bytes = blk: {
                const in_file = if (args.option("--in_file")) |in_file_name|
                    try fs.cwd().openFile(in_file_name, .{ .read = true })
                else
                    io.getStdIn();

                break :blk try in_file.reader().readAllAlloc(allocator, max_doc_file_size);
            };

            var buffered_out_stream = blk: {
                const out_file = if (args.option("--out_file")) |out_file_name|
                    try fs.cwd().createFile(out_file_name, .{})
                else
                    io.getStdOut();

                break :blk io.bufferedWriter(out_file.writer());
            };

            try doctest.highlightZigCode(input_file_bytes, buffered_out_stream.writer());
            try buffered_out_stream.flush();
        },
        .@"build-exe" => {
            // TODO: it seems a good idea to have a "check output" flag, rather than
            // tying output checking just to failure cases.
            const summary = "Builds a code snippet, checking for the build to succeed or fail as expected.";
            const params = comptime [_]clap.Param(clap.Help){
                clap.parseParam("-h, --help                     Display this help message") catch unreachable,
                clap.parseParam("-e, --error                    expect the build command to encounter a compile error") catch unreachable,
                clap.parseParam("-i, --in_file <PATH>           path to the input file, defaults to stdin") catch unreachable,
                clap.parseParam("-o, --out_file <PATH>          path to the output file, defaults to stdout") catch unreachable,
                clap.parseParam("-z, --zig_exe <PATH>           path to the zig compiler, defaults to `zig` (i.e. assumes zig present in PATH)") catch unreachable,
                clap.parseParam("-t, --target <TARGET>          compilation target, expected as a arch-os-abi tripled (e.g. `x86_64-linux-gnu`) defaults to `native`") catch unreachable,
            };

            var diag: clap.Diagnostic = undefined;
            var args = clap.ComptimeClap(
                clap.Help,
                clap.args.OsIterator,
                &params,
            ).parse(allocator, &args_it, &diag) catch |err| {
                // Report any useful error and exit
                diag.report(std.io.getStdErr().outStream(), err) catch {};
                return err;
            };
            check_help(summary, &params, args);

            const input_file_bytes = blk: {
                const in_file = if (args.option("--in_file")) |in_file_name|
                    try fs.cwd().openFile(in_file_name, .{ .read = true })
                else
                    io.getStdIn();

                break :blk try in_file.reader().readAllAlloc(allocator, max_doc_file_size);
            };

            var buffered_out_stream = blk: {
                const out_file = if (args.option("--out_file")) |out_file_name|
                    try fs.cwd().createFile(out_file_name, .{})
                else
                    io.getStdOut();

                break :blk io.bufferedWriter(out_file.writer());
            };

            // Produce the syntax highlighting
            try doctest.highlightZigCode(input_file_bytes, buffered_out_stream.writer());

            // Grab env map and set max output size
            var env_map = try process.getEnvMap(allocator);
            try env_map.set("ZIG_DEBUG_COLOR", "1");

            // Build the code and write the resulting output
            _ = try doctest.buildExe(
                allocator,
                input_file_bytes,
                buffered_out_stream.writer(),
                &env_map,
                if (args.option("--zig_exe")) |z| z else "zig",
                doctest.BuildCommand{
                    .id = .Exe,
                    .tmp_dir_name = "blah",
                    .expected_outcome = if (args.flag("--error")) .Failure else .Success,
                    .target_str = args.option("--target"),
                },
            );

            try buffered_out_stream.flush();
        },

        .run => {
            // TODO: it seems a good idea to have a "check output" flag, rather than
            // tying output checking just to failure cases.
            const summary = "Builds a code snippet, checking for the build to succeed or fail as expected.";
            const params = comptime [_]clap.Param(clap.Help){
                clap.parseParam("-h, --help                     Display this help message") catch unreachable,
                clap.parseParam("-e, --error                    expect the build command to encounter a compile error") catch unreachable,
                clap.parseParam("-i, --in_file <PATH>           path to the input file, defaults to stdin") catch unreachable,
                clap.parseParam("-o, --out_file <PATH>          path to the output file, defaults to stdout") catch unreachable,
                clap.parseParam("-z, --zig_exe <PATH>           path to the zig compiler, defaults to `zig` (i.e. assumes zig present in PATH)") catch unreachable,
            };

            var diag: clap.Diagnostic = undefined;
            var args = clap.ComptimeClap(
                clap.Help,
                clap.args.OsIterator,
                &params,
            ).parse(allocator, &args_it, &diag) catch |err| {
                // Report any useful error and exit
                diag.report(std.io.getStdErr().outStream(), err) catch {};
                return err;
            };
            check_help(summary, &params, args);

            const input_file_bytes = blk: {
                const in_file = if (args.option("--in_file")) |in_file_name|
                    try fs.cwd().openFile(in_file_name, .{ .read = true })
                else
                    io.getStdIn();

                break :blk try in_file.reader().readAllAlloc(allocator, max_doc_file_size);
            };

            var buffered_out_stream = blk: {
                const out_file = if (args.option("--out_file")) |out_file_name|
                    try fs.cwd().createFile(out_file_name, .{})
                else
                    io.getStdOut();

                break :blk io.bufferedWriter(out_file.writer());
            };

            // Produce the syntax highlighting
            try doctest.highlightZigCode(input_file_bytes, buffered_out_stream.writer());

            // Grab env map and set max output size
            var env_map = try process.getEnvMap(allocator);
            try env_map.set("ZIG_DEBUG_COLOR", "1");

            // Build the code and write the resulting output
            const executable_path = try doctest.buildExe(
                allocator,
                input_file_bytes,
                buffered_out_stream.writer(),
                &env_map,
                if (args.option("--zig_exe")) |z| z else "zig",
                doctest.BuildCommand{
                    .id = .Exe,
                    .tmp_dir_name = "blah",
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
                        .expected_outcome = .Success,
                        .check_output = null,
                    },
                );
            }

            try buffered_out_stream.flush();
        },

        .@"test" => {
            const summary = "Runs a code snippet containing a test and checks if it succeeds or fails as expected.";
            const params = comptime [_]clap.Param(clap.Help){
                clap.parseParam("-h, --help                     Display this help message") catch unreachable,
                clap.parseParam("-e, --compile_error <ERR_MSG>  expect the test to encounter a compile error that matches the provided message") catch unreachable,
                clap.parseParam("-p, --panic <PANIC_MSG>        expect the test to compile successfully but fail while running with a error that matches the provided message") catch unreachable,
                clap.parseParam("-i, --in_file <PATH>           path to the input file, defaults to stdin") catch unreachable,
                clap.parseParam("-o, --out_file <PATH>          path to the output file, defaults to stdout") catch unreachable,
                clap.parseParam("-z, --zig_exe <PATH>           path to the zig compiler, defaults to `zig` (i.e. assumes zig present in PATH)") catch unreachable,
            };

            var diag: clap.Diagnostic = undefined;
            var args = clap.ComptimeClap(
                clap.Help,
                clap.args.OsIterator,
                &params,
            ).parse(allocator, &args_it, &diag) catch |err| {
                // Report any useful error and exit
                diag.report(std.io.getStdErr().outStream(), err) catch {};
                return err;
            };
            check_help(summary, &params, args);
        },
    }

    // try fs.cwd().makePath(tmp_dir_name);
    // defer fs.cwd().deleteTree(tmp_dir_name) catch {
    //     // TODO: warn the user on stderr
    // };

    // switch (command) {
    //     .Syntax => {
    //         try doctest.highlightZigCode(input_file_bytes, buffered_out_stream.outStream());
    //     },
    // }

    // try genHtml(allocator, &tokenizer, &toc, buffered_out_stream.outStream(), zig_exe);
}

fn check_help(comptime summary: []const u8, comptime params: anytype, args: anytype) void {
    if (args.flag("--help")) {
        std.debug.print("{}\n\n", .{summary});
        clap.help(io.getStdErr().writer(), params) catch {};
        std.debug.print("\n", .{});
        std.os.exit(0);
    }
}
