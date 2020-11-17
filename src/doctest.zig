const build = @import("doctest/build_exe.zig");
const run = @import("doctest/run.zig");

pub const highlightZigCode = @import("doctest/syntax.zig").highlightZigCode;

pub const buildExe = build.buildExe;
pub const BuildCommand = build.BuildCommand;

pub const runExe = run.runExe;
pub const RunCommand = run.RunCommand;
