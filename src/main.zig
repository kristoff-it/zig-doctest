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
const Command = enum {
    syntax,
    @"test",
    exe,
};

// doctest syntax zig_path in_file out_file
// doctest test-succeed zig_path in_file out_file
// doctest test-fail err_msg zig_path in_file out_file

// doctest test zig_path in_file out_file
// doctest test --fail-safety="Overflow"

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const allocator = &arena.allocator;

    var args_it = try clap.args.OsIterator.init(allocator);
    defer args_it.deinit();

    const command_name = (try args_it.next()) orelse @panic("expected command arg");

    @setEvalBranchQuota(5000);
    const command = std.meta.stringToEnum(Command, command_name) orelse @panic("unknown command");
    switch (command) {
        else => unreachable,
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
