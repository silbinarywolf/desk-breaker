const std = @import("std");
const ascii = std.ascii;
const unicode = std.unicode;
const testing = std.testing;
const assert = std.debug.assert;

const Tag = enum {
    ident,
    equal,
    newline,
    string,
    // decimal, // number with decimal places
    digit, // number with no decimal places

    // Error tokens
    error_unexpected,
    error_invalid_control_code,
    error_incomplete_control_code,
    error_incomplete_string,
};

const Token = struct {
    tag: Tag,
    start: u32,
    end: u32,

    fn init(tag: Tag, start: u32, end: u32) Token {
        return .{
            .tag = tag,
            .start = start,
            .end = end,
        };
    }

    fn data(self: *const Token, source: []const u8) []const u8 {
        const r = source[self.start..self.end];
        // assert(r.len != 0);
        return r;
    }
};

data: []const u8,

/// i is the position in the byte data
i: u32,

pub fn init(data: []const u8) error{InvalidUtf8}!Lexer {
    if (!unicode.utf8ValidateSlice(data)) {
        return error.InvalidUtf8;
    }
    return .{
        .data = data,
        .i = 0,
    };
}

/// slice gets the token data
pub fn slice(self: *const Lexer, tok: Token) []const u8 {
    return tok.data(self.data);
}

pub fn next(self: *Lexer) ?Token {
    var top_i = self.i;
    var top_c = self.nextChar() catch |err| switch (err) {
        error.EOF => return null,
    };
    // Ignore whitespace (excludes newline)
    if (ascii.isWhitespace(top_c) and top_c != '\n') {
        while (ascii.isWhitespace(top_c) and top_c != '\n') {
            top_c = self.nextChar() catch |err| switch (err) {
                error.EOF => return null,
            };
            top_i = self.i;
        }
        top_i = self.i - 1;
    }

    // Read equal
    if (top_c == '=') {
        const tok = Token.init(.equal, top_i, top_i);
        return tok;
    }
    if (top_c == '\n') {
        const tok = Token.init(.newline, top_i, top_i);
        return tok;
    }
    // Read string
    if (top_c == '"') {
        while (true) {
            // TODO: Consider UTF-8 at this point and use UTF-8 iterator
            var c = self.nextChar() catch |err| switch (err) {
                error.EOF => return Token.init(.ErrorIncompleteString, top_i, self.i),
            };
            // std.debug.print("c: {c}\n", .{c});
            if (c == '\\') {
                // If escaping string, skip over it
                // const prev_i = self.i;
                const ec = self.nextChar() catch |err| switch (err) {
                    error.EOF => return Token.init(.ErrorIncompleteControlCode, self.i - 1, self.i),
                };
                switch (ec) {
                    '"' => {},
                    '\\' => {},
                    else => return Token.init(.ErrorInvalidControlCode, self.i - 1, self.i),
                }
                c = ec;
            }
            if (c == '"') {
                break;
            }
        }
        const tok = Token.init(.string, top_i + 1, self.i - 1);
        return tok;
    }
    if (ascii.isDigit(top_c)) {
        while (true) {
            const c = self.nextChar() catch |err| switch (err) {
                error.EOF => break,
            };
            if (!ascii.isDigit(c)) {
                self.i -= 1; // ignore last ignored digit
                break;
            }
        }
        const tok = Token.init(.digit, top_i, self.i);
        return tok;
    }
    // Read ident
    if (ascii.isAlphabetic(top_c)) {
        while (true) {
            const c = self.nextChar() catch |err| switch (err) {
                error.EOF => break,
            };
            // NOTE(jae): 2024-07-21
            // Idents are only alphabetic and not alphanumeric so we can do: "1h30m40s"
            if (!ascii.isAlphabetic(c) and c != '_') {
                self.i -= 1; // ignore last ignored ident character
                break;
            }
        }
        const tok = Token.init(.ident, top_i, self.i);
        return tok;
    }
    const tok = Token.init(.ErrorUnexpected, top_i, top_i);
    return tok;
}

fn nextChar(self: *Lexer) error{EOF}!u8 {
    if (self.i >= self.data.len) {
        return error.EOF;
    }
    const v = self.data[self.i];
    self.i += 1;
    return v;
}

// fn peekCharIs(self: *Lexer, c: u8) bool {
//     if (self.i >= self.data.len) {
//         return false;
//     }
//     const v = self.data[self.i];
//     return v == c;
// }

const Lexer = @This();

test "incomplete string" {
    var l = try Lexer.init("\"my string");
    const tok = l.next() orelse return error.ExpectedToken;
    try testing.expectEqual(Tag.error_incomplete_string, tok.tag);
    // TODO: Improve this to not include the quote
    try testing.expectEqualSlices(u8, "\"my string", l.slice(tok));
}

test "working config" {
    var l = try Lexer.init("my_test_ident=\"my string\"\nalso_this=2");
    // First key value
    {
        const tok = l.next() orelse return error.MissingToken;
        try testing.expectEqual(Tag.ident, tok.tag);
    }
    {
        const tok = l.next() orelse return error.MissingToken;
        try testing.expectEqual(Tag.equal, tok.tag);
    }
    {
        const tok = l.next() orelse return error.MissingToken;
        try testing.expectEqual(Tag.string, tok.tag);
    }
    {
        const tok = l.next() orelse return error.MissingToken;
        try testing.expectEqual(Tag.newline, tok.tag);
    }
    // Next key value
    {
        const tok = l.next() orelse return error.MissingToken;
        try testing.expectEqual(Tag.ident, tok.tag);
    }
    {
        const tok = l.next() orelse return error.MissingToken;
        try testing.expectEqual(Tag.equal, tok.tag);
    }
    {
        const tok = l.next() orelse return error.MissingToken;
        try testing.expectEqual(Tag.digit, tok.tag);
    }
}
