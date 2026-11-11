const std = @import("std");

const Twingate = @import("twingate.zig").Twingate;

const assert = std.debug.assert;

pub fn TextType(comptime capacity: u32) type {
    comptime assert(capacity > 0);
    comptime assert(capacity <= Twingate.output_bytes_max);

    return struct {
        bytes: [capacity]u8,
        length: u32,

        const Text = @This();

        pub const empty: Text = .{ .bytes = undefined, .length = 0 };

        pub fn set(text: *Text, value: []const u8) void {
            assert(value.len <= Twingate.output_bytes_max);

            const length = prefix_length(value);

            @memcpy(text.bytes[0..length], value[0..length]);

            text.length = length;

            assert(text.length <= capacity);
            assert(text.length == value.len or text.length + character_bytes_max > capacity);
        }

        pub fn slice(text: *const Text) []const u8 {
            assert(text.length <= capacity);

            return text.bytes[0..text.length];
        }

        fn prefix_length(value: []const u8) u32 {
            assert(value.len <= Twingate.output_bytes_max);

            var length: u32 = @intCast(@min(value.len, capacity));
            var steps: u32 = 0;

            while (steps < character_bytes_max - 1) : (steps += 1) {
                if (length == value.len) break;
                if (length == 0) break;
                if ((value[length] & 0xc0) != 0x80) break;

                length -= 1;
            }

            assert(length <= capacity);
            assert(length == value.len or length + character_bytes_max > capacity);

            return length;
        }
    };
}

const character_bytes_max: u32 = 4;

const testing = std.testing;

test TextType {
    var text: TextType(16) = .empty;

    text.set("Connected");

    try testing.expectEqualStrings("Connected", text.slice());
}

test "a value past the capacity is cut on a character boundary" {
    var text: TextType(8) = .empty;

    text.set("abcdefgh");

    try testing.expectEqualStrings("abcdefgh", text.slice());

    text.set("abcdefg\u{e9}");

    try testing.expectEqualStrings("abcdefg", text.slice());

    text.set("ab\u{1f600}\u{1f600}");

    try testing.expectEqualStrings("ab\u{1f600}", text.slice());
    try testing.expect(std.unicode.utf8ValidateSlice(text.slice()));
}

test "a run of continuation bytes is cut within one character of the capacity" {
    var text: TextType(8) = .empty;

    const continuation: [12]u8 = @splat(0x80);

    text.set(&continuation);

    try testing.expectEqual(@as(usize, 5), text.slice().len);
    try testing.expectEqualSlices(u8, continuation[0..5], text.slice());
}

test "a cut keeps a prefix of the value and never splits a character" {
    const pieces = [_][]const u8{ "a", "\u{e9}", "\u{2026}", "\u{1f600}", "\x80", "\xc3" };
    const valid_count: usize = 4;

    var prng = std.Random.DefaultPrng.init(0x7e47);
    var source: [64]u8 = undefined;

    for (0..256) |round| {
        const choices = if (round % 2 == 0) pieces[0..valid_count] else pieces[0..];

        var length: usize = 0;

        while (length + character_bytes_max <= source.len) {
            const piece = choices[prng.random().uintLessThan(u32, @intCast(choices.len))];

            @memcpy(source[length..][0..piece.len], piece);

            length += piece.len;
        }

        const value = source[0..length];

        var text: TextType(16) = .empty;

        text.set(value);

        const kept = text.slice();

        try testing.expect(std.mem.startsWith(u8, value, kept));
        try testing.expect(kept.len <= 16);
        try testing.expect(kept.len + character_bytes_max > 16);

        if (std.unicode.utf8ValidateSlice(value)) {
            try testing.expect(std.unicode.utf8ValidateSlice(kept));
        }
    }
}
