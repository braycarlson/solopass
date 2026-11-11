const std = @import("std");

const assert = std.debug.assert;

pub const Elapsed = struct {
    seconds: u64,

    pub const bytes_max: u32 = 48;
    pub const seconds_max: u64 = std.math.maxInt(i64);

    pub fn format(elapsed: Elapsed, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        assert(elapsed.seconds <= seconds_max);

        if (elapsed.seconds < seconds_per_minute) return writer.writeAll("under a minute");

        const days = @divFloor(elapsed.seconds, seconds_per_day);
        const hours = @divFloor(elapsed.seconds % seconds_per_day, seconds_per_hour);
        const minutes = @divFloor(elapsed.seconds % seconds_per_hour, seconds_per_minute);

        assert(hours < 24);
        assert(minutes < 60);

        if (days > 0) return writer.print("{d}d {d}h", .{ days, hours });
        if (hours > 0) return writer.print("{d}h {d}m", .{ hours, minutes });

        return writer.print("{d}m", .{minutes});
    }
};

const seconds_per_day: u64 = 24 * seconds_per_hour;
const seconds_per_hour: u64 = 60 * seconds_per_minute;
const seconds_per_minute: u64 = 60;

comptime {
    assert(seconds_per_day == 86_400);
    assert(Elapsed.bytes_max >= "18446744073709551615d 23h".len);
}

const testing = std.testing;

fn expect_elapsed(expected: []const u8, seconds: u64) !void {
    try testing.expect(seconds <= Elapsed.seconds_max);

    var buffer: [Elapsed.bytes_max]u8 = undefined;

    const text = try std.mem.print(&buffer, "{f}", .{Elapsed{ .seconds = seconds }});

    try testing.expectEqualStrings(expected, text);
}

test Elapsed {
    var buffer: [64]u8 = undefined;

    const elapsed: Elapsed = .{ .seconds = 2 * 3600 + 14 * 60 };
    const text = try std.mem.print(&buffer, "Connected for {f}", .{elapsed});

    try testing.expectEqualStrings("Connected for 2h 14m", text);
}

test "an elapsed time keeps its two largest units" {
    try expect_elapsed("under a minute", 0);
    try expect_elapsed("under a minute", 59);
    try expect_elapsed("1m", 60);
    try expect_elapsed("59m", 3599);
    try expect_elapsed("1h 0m", 3600);
    try expect_elapsed("2h 14m", 2 * 3600 + 14 * 60 + 59);
    try expect_elapsed("23h 59m", 86_399);
    try expect_elapsed("1d 0h", 86_400);
    try expect_elapsed("3d 7h", 3 * 86_400 + 7 * 3600 + 1);
}

test "the widest elapsed time still fits its buffer" {
    var buffer: [Elapsed.bytes_max]u8 = undefined;

    const widest: Elapsed = .{ .seconds = Elapsed.seconds_max };
    const text = try std.mem.print(&buffer, "{f}", .{widest});

    try testing.expect(std.mem.endsWith(u8, text, "h"));
    try testing.expect(text.len <= Elapsed.bytes_max);
}

test "the rendered units add back up to the time they came from" {
    var prng = std.Random.DefaultPrng.init(0xe1a9);

    for (0..512) |_| {
        const seconds = prng.random().uintAtMost(u64, 400 * 86_400);

        var buffer: [Elapsed.bytes_max]u8 = undefined;

        const text = try std.mem.print(&buffer, "{f}", .{Elapsed{ .seconds = seconds }});

        if (seconds < 60) {
            try testing.expectEqualStrings("under a minute", text);

            continue;
        }

        var total: u64 = 0;
        var units: u32 = 0;
        var words = std.mem.splitScalar(u8, text, ' ');

        while (words.next()) |word| : (units += 1) {
            try testing.expect(units < 2);

            const value = try std.fmt.parseInt(u64, word[0 .. word.len - 1], 10);

            const scale: u64 = switch (word[word.len - 1]) {
                'd' => 86_400,
                'h' => 3600,
                'm' => 60,
                else => return error.UnitUnknown,
            };

            total += value * scale;
        }

        const granularity: u64 = if (seconds >= 86_400) 3600 else 60;

        try testing.expect(units >= 1);
        try testing.expect(total <= seconds);
        try testing.expect(seconds - total < granularity);
    }
}
