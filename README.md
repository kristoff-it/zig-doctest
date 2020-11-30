# Doctest
A tool for testing snippets of code, useful for websites and books that talk about Zig.


## Abstract
Doctest is a code rendering tool that on top of providing syntax highlighting it also can run your code snippets to ensure that they behave as expected.

Other than the syntax highlighting, this tool gives you the option of testing scripts that are exptected to fail. This is something that the built-in testing framework of Zig doesn't allow to do in the same way. This is particularly useful when demoing things like runtime checks in safe release modes, which will cause the executable to crash.


## Usage
```
Available commands: syntax, build, test, run, inline, help.

Put the `--help` flag after the command to get command-specific
help.

Examples:

 ./doctest syntax --in_file=foo.zig
 ./doctest build --obj --fail "not handled in switch"
 ./doctest test --out_file bar.zig --zig_exe="/Downloads/zig/bin/zig"
```

