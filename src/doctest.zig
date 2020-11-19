const build = @import("doctest/build.zig");
const run = @import("doctest/run.zig");
const _test = @import("doctest/test.zig");

pub const highlightZigCode = @import("doctest/syntax.zig").highlightZigCode;

pub const runBuild = build.runBuild;
pub const BuildCommand = build.BuildCommand;

pub const runExe = run.runExe;
pub const RunCommand = run.RunCommand;

pub const runTest = _test.runTest;
pub const TestCommand = _test.TestCommand;
