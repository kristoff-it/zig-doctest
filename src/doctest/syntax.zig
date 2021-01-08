const std = @import("std");
const mem = std.mem;
const print = std.debug.print;
const render_utils = @import("render_utils.zig");

pub fn highlightZigCode(raw_src: []const u8, out: anytype) !void {
    // TODO: who should be doing this cleanup?
    const src = mem.trim(u8, raw_src, " \n");
    try out.writeAll("<pre><code class=\"zig\">");
    var tokenizer = std.zig.Tokenizer.init(src);
    var index: usize = 0;
    var next_tok_is_fn = false;
    while (true) {
        const prev_tok_was_fn = next_tok_is_fn;
        next_tok_is_fn = false;

        const token = tokenizer.next();
        try render_utils.writeEscaped(out, src[index..token.loc.start]);
        switch (token.id) {
            .Eof => break,

            .Keyword_align,
            .Keyword_and,
            .Keyword_asm,
            .Keyword_async,
            .Keyword_await,
            .Keyword_break,
            .Keyword_catch,
            .Keyword_comptime,
            .Keyword_const,
            .Keyword_continue,
            .Keyword_defer,
            .Keyword_else,
            .Keyword_enum,
            .Keyword_errdefer,
            .Keyword_error,
            .Keyword_export,
            .Keyword_extern,
            .Keyword_for,
            .Keyword_if,
            .Keyword_inline,
            .Keyword_noalias,
            .Keyword_noinline,
            .Keyword_nosuspend,
            .Keyword_opaque,
            .Keyword_or,
            .Keyword_orelse,
            .Keyword_packed,
            .Keyword_anyframe,
            .Keyword_pub,
            .Keyword_resume,
            .Keyword_return,
            .Keyword_linksection,
            .Keyword_callconv,
            .Keyword_struct,
            .Keyword_suspend,
            .Keyword_switch,
            .Keyword_test,
            .Keyword_threadlocal,
            .Keyword_try,
            .Keyword_union,
            .Keyword_unreachable,
            .Keyword_usingnamespace,
            .Keyword_var,
            .Keyword_volatile,
            .Keyword_allowzero,
            .Keyword_while,
            .Keyword_anytype,
            => {
                try out.writeAll("<span class=\"tok-kw\">");
                try render_utils.writeEscaped(out, src[token.loc.start..token.loc.end]);
                try out.writeAll("</span>");
            },

            .Keyword_fn => {
                try out.writeAll("<span class=\"tok-kw\">");
                try render_utils.writeEscaped(out, src[token.loc.start..token.loc.end]);
                try out.writeAll("</span>");
                next_tok_is_fn = true;
            },

            .Keyword_undefined,
            .Keyword_null,
            .Keyword_true,
            .Keyword_false,
            => {
                try out.writeAll("<span class=\"tok-null\">");
                try render_utils.writeEscaped(out, src[token.loc.start..token.loc.end]);
                try out.writeAll("</span>");
            },

            .StringLiteral,
            .MultilineStringLiteralLine,
            .CharLiteral,
            => {
                try out.writeAll("<span class=\"tok-str\">");
                try render_utils.writeEscaped(out, src[token.loc.start..token.loc.end]);
                try out.writeAll("</span>");
            },

            .Builtin => {
                try out.writeAll("<span class=\"tok-builtin\">");
                try render_utils.writeEscaped(out, src[token.loc.start..token.loc.end]);
                try out.writeAll("</span>");
            },

            .LineComment,
            .DocComment,
            .ContainerDocComment,
            .ShebangLine,
            => {
                try out.writeAll("<span class=\"tok-comment\">");
                try render_utils.writeEscaped(out, src[token.loc.start..token.loc.end]);
                try out.writeAll("</span>");
            },

            .Identifier => {
                if (prev_tok_was_fn) {
                    try out.writeAll("<span class=\"tok-fn\">");
                    try render_utils.writeEscaped(out, src[token.loc.start..token.loc.end]);
                    try out.writeAll("</span>");
                } else {
                    const is_int = blk: {
                        if (src[token.loc.start] != 'i' and src[token.loc.start] != 'u')
                            break :blk false;
                        var i = token.loc.start + 1;
                        if (i == token.loc.end)
                            break :blk false;
                        while (i != token.loc.end) : (i += 1) {
                            if (src[i] < '0' or src[i] > '9')
                                break :blk false;
                        }
                        break :blk true;
                    };
                    if (is_int or isType(src[token.loc.start..token.loc.end])) {
                        try out.writeAll("<span class=\"tok-type\">");
                        try render_utils.writeEscaped(out, src[token.loc.start..token.loc.end]);
                        try out.writeAll("</span>");
                    } else {
                        try render_utils.writeEscaped(out, src[token.loc.start..token.loc.end]);
                    }
                }
            },

            .IntegerLiteral,
            .FloatLiteral,
            => {
                try out.writeAll("<span class=\"tok-number\">");
                try render_utils.writeEscaped(out, src[token.loc.start..token.loc.end]);
                try out.writeAll("</span>");
            },

            .Bang,
            .Pipe,
            .PipePipe,
            .PipeEqual,
            .Equal,
            .EqualEqual,
            .EqualAngleBracketRight,
            .BangEqual,
            .LParen,
            .RParen,
            .Semicolon,
            .Percent,
            .PercentEqual,
            .LBrace,
            .RBrace,
            .LBracket,
            .RBracket,
            .Period,
            .PeriodAsterisk,
            .Ellipsis2,
            .Ellipsis3,
            .Caret,
            .CaretEqual,
            .Plus,
            .PlusPlus,
            .PlusEqual,
            .PlusPercent,
            .PlusPercentEqual,
            .Minus,
            .MinusEqual,
            .MinusPercent,
            .MinusPercentEqual,
            .Asterisk,
            .AsteriskEqual,
            .AsteriskAsterisk,
            .AsteriskPercent,
            .AsteriskPercentEqual,
            .Arrow,
            .Colon,
            .Slash,
            .SlashEqual,
            .Comma,
            .Ampersand,
            .AmpersandEqual,
            .QuestionMark,
            .AngleBracketLeft,
            .AngleBracketLeftEqual,
            .AngleBracketAngleBracketLeft,
            .AngleBracketAngleBracketLeftEqual,
            .AngleBracketRight,
            .AngleBracketRightEqual,
            .AngleBracketAngleBracketRight,
            .AngleBracketAngleBracketRightEqual,
            .Tilde,
            => try render_utils.writeEscaped(out, src[token.loc.start..token.loc.end]),

            .Invalid, .Invalid_ampersands, .Invalid_periodasterisks => return parseError(
                src,
                token,
                "syntax error",
                .{},
            ),
        }
        index = token.loc.end;
    }
    try out.writeAll("</code></pre>");
}

// TODO: this function returns anyerror, interesting
fn parseError(src: []const u8, token: std.zig.Token, comptime fmt: []const u8, args: anytype) anyerror {
    const loc = getTokenLocation(src, token);
    // const args_prefix = .{ tokenizer.source_file_name, loc.line + 1, loc.column + 1 };
    // print("{}:{}:{}: error: " ++ fmt ++ "\n", args_prefix ++ args);

    const args_prefix = .{ loc.line + 1, loc.column + 1 };
    print("{d}:{d}: error: " ++ fmt ++ "\n", args_prefix ++ args);
    if (loc.line_start <= loc.line_end) {
        print("{s}\n", .{src[loc.line_start..loc.line_end]});
        {
            var i: usize = 0;
            while (i < loc.column) : (i += 1) {
                print(" ", .{});
            }
        }
        {
            const caret_count = token.loc.end - token.loc.start;
            var i: usize = 0;
            while (i < caret_count) : (i += 1) {
                print("~", .{});
            }
        }
        print("\n", .{});
    }
    return error.ParseError;
}

const builtin_types = [_][]const u8{
    "f16",         "f32",      "f64",    "f128",     "c_longdouble", "c_short",
    "c_ushort",    "c_int",    "c_uint", "c_long",   "c_ulong",      "c_longlong",
    "c_ulonglong", "c_char",   "c_void", "void",     "bool",         "isize",
    "usize",       "noreturn", "type",   "anyerror", "comptime_int", "comptime_float",
};

fn isType(name: []const u8) bool {
    for (builtin_types) |t| {
        if (mem.eql(u8, t, name))
            return true;
    }
    return false;
}

const Location = struct {
    line: usize,
    column: usize,
    line_start: usize,
    line_end: usize,
};
fn getTokenLocation(src: []const u8, token: std.zig.Token) Location {
    var loc = Location{
        .line = 0,
        .column = 0,
        .line_start = 0,
        .line_end = 0,
    };
    for (src) |c, i| {
        if (i == token.loc.start) {
            loc.line_end = i;
            while (loc.line_end < src.len and src[loc.line_end] != '\n') : (loc.line_end += 1) {}
            return loc;
        }
        if (c == '\n') {
            loc.line += 1;
            loc.column = 0;
            loc.line_start = i + 1;
        } else {
            loc.column += 1;
        }
    }
    return loc;
}
