const std = @import("std");

const Twingate = @import("twingate.zig").Twingate;

const assert = std.debug.assert;

pub const Table = struct {
    text: []const u8,

    pub const Line = struct {
        kind: Kind,
        text: []const u8,

        pub const Kind = enum {
            header,
            note,
            row,
        };

        pub fn cell(line: *const Line, index: u32) []const u8 {
            assert(line.kind != .note);
            assert(line.text.len > 0);

            var cells = std.mem.splitScalar(u8, line.text, '\t');
            var position: u32 = 0;

            while (cells.next()) |value| : (position += 1) {
                assert(position <= line.text.len);

                if (position == index) return std.mem.trim(u8, value, " ");
            }

            return "";
        }

        pub fn is_current(line: *const Line) bool {
            assert(line.kind == .row);
            assert(line.text.len > 0);

            return std.mem.endsWith(u8, line.text, suffix_current);
        }
    };

    pub const Lines = struct {
        in_table: bool,
        remaining: u32,
        split: std.mem.SplitIterator(u8, .scalar),

        pub fn next(iterator: *Lines) ?Line {
            while (iterator.split.next()) |raw| {
                assert(iterator.remaining > 0);

                iterator.remaining -= 1;

                const line = std.mem.trimEnd(u8, raw, " \r");
                const trimmed = std.mem.trim(u8, line, " \t");
                if (trimmed.len == 0) continue;

                if (std.mem.findScalar(u8, line, '\t') == null) {
                    iterator.in_table = false;

                    return .{ .kind = .note, .text = trimmed };
                }

                const kind: Line.Kind = if (iterator.in_table) .row else .header;

                iterator.in_table = true;

                return .{ .kind = kind, .text = line };
            }

            assert(iterator.remaining == 0);

            return null;
        }
    };

    pub fn init(text: []const u8) Table {
        assert(text.len <= Twingate.output_bytes_max);

        return .{ .text = text };
    }

    pub fn lines(table: *const Table) Lines {
        assert(table.text.len <= Twingate.output_bytes_max);

        const count = std.mem.countScalar(u8, table.text, '\n') + 1;

        assert(count <= table.text.len + 1);

        return .{
            .in_table = false,
            .remaining = @intCast(count),
            .split = std.mem.splitScalar(u8, table.text, '\n'),
        };
    }

    pub fn row(table: *const Table, index: u32) ?Line {
        assert(table.text.len <= Twingate.output_bytes_max);

        var iterator = table.lines();
        var position: u32 = 0;

        for (0..iterator.remaining) |_| {
            const line = iterator.next() orelse break;
            if (line.kind != .row) continue;
            if (position == index) return line;

            position += 1;
        }

        return null;
    }

    pub fn row_count(table: *const Table) u32 {
        assert(table.text.len <= Twingate.output_bytes_max);

        var iterator = table.lines();
        var count: u32 = 0;

        for (0..iterator.remaining) |_| {
            const line = iterator.next() orelse break;

            if (line.kind == .row) count += 1;
        }

        assert(count <= table.text.len);

        return count;
    }
};

const suffix_current = "\t*";

const testing = std.testing;

const account_list =
    "EMAIL                  \tNETWORK   \tNETWORK URL\n" ++
    "avery.quinn@example.com\tExampleNet\texamplenet.twingate.com\n" ++
    "\n";

const account_marked =
    "EMAIL                  \tNETWORK      \tNETWORK URL               \t\n" ++
    "avery.quinn@example.com\tExampleNet   \texamplenet.twingate.com   \t\n" ++
    "tester@example.com     \tSolopass Test\tsolopass-test.twingate.com\t*\n" ++
    "\n";

const account_missing =
    "Account not found. Available formats: email, email:tenant_slug, or account ID\n" ++
    "\n" ++
    "Available profiles:\n" ++
    "EMAIL\tNETWORK\tNETWORK URL\n";

test Table {
    const table: Table = .init(account_list);
    const row = table.row(0) orelse return error.RowMissing;

    try testing.expectEqual(@as(u32, 1), table.row_count());
    try testing.expectEqualStrings("avery.quinn@example.com", row.cell(0));
    try testing.expectEqualStrings("ExampleNet", row.cell(1));
}

test "the account list splits into a header and trimmed cells" {
    const table: Table = .init(account_list);

    var lines = table.lines();

    const header = lines.next().?;

    try testing.expectEqual(Table.Line.Kind.header, header.kind);
    try testing.expectEqualStrings("EMAIL", header.cell(0));
    try testing.expectEqualStrings("NETWORK URL", header.cell(2));

    const row = lines.next().?;

    try testing.expectEqual(Table.Line.Kind.row, row.kind);
    try testing.expectEqualStrings("avery.quinn@example.com", row.cell(0));
    try testing.expectEqualStrings("ExampleNet", row.cell(1));
    try testing.expectEqualStrings("examplenet.twingate.com", row.cell(2));
    try testing.expectEqualStrings("", row.cell(3));

    const end = lines.next();

    try testing.expectEqual(@as(?Table.Line, null), end);
}

test "the prose before a table stays prose and starts a new header" {
    const table: Table = .init(account_missing);

    var lines = table.lines();

    const notice = lines.next().?;
    const profiles = lines.next().?;
    const header = lines.next().?;
    const end = lines.next();

    try testing.expectEqual(Table.Line.Kind.note, notice.kind);
    try testing.expectEqual(Table.Line.Kind.note, profiles.kind);
    try testing.expectEqualStrings("Available profiles:", profiles.text);
    try testing.expectEqual(Table.Line.Kind.header, header.kind);
    try testing.expectEqual(@as(?Table.Line, null), end);
    try testing.expectEqual(@as(u32, 0), table.row_count());
}

test "a row is addressed by its position among the rows" {
    const two: Table = .init(account_list ++ "other@example.com\tExample\texample.twingate.com\n");
    const empty: Table = .init("");

    try testing.expectEqual(@as(u32, 2), two.row_count());
    try testing.expectEqualStrings("other@example.com", two.row(1).?.cell(0));
    try testing.expectEqual(@as(?Table.Line, null), two.row(2));
    try testing.expectEqual(@as(?Table.Line, null), empty.row(0));
}

test "the account in use is the row the cli ends with an asterisk" {
    const marked: Table = .init(account_marked);
    const trimmed: Table = .init(std.mem.trim(u8, account_marked, " \t\r\n"));
    const plain: Table = .init(account_list);
    const other = marked.row(0) orelse return error.RowMissing;
    const current = marked.row(1) orelse return error.RowMissing;
    const last = trimmed.row(1) orelse return error.RowMissing;
    const unmarked = plain.row(0) orelse return error.RowMissing;

    try testing.expectEqual(@as(u32, 2), marked.row_count());
    try testing.expect(!other.is_current());
    try testing.expect(current.is_current());
    try testing.expect(last.is_current());
    try testing.expect(!unmarked.is_current());
    try testing.expectEqualStrings("tester@example.com", current.cell(0));
    try testing.expectEqualStrings("Solopass Test", current.cell(1));
    try testing.expectEqualStrings("*", current.cell(3));
}

test "each line of arbitrary bytes is a slice of the input" {
    var prng = std.Random.DefaultPrng.init(0x5eed);
    var bytes: [512]u8 = undefined;

    const alphabet = "ab \t\r\n";

    for (0..64) |_| {
        for (&bytes) |*byte| byte.* = alphabet[prng.random().uintLessThan(u32, alphabet.len)];

        const text = bytes[0..prng.random().uintAtMost(u32, bytes.len)];
        const table: Table = .init(text);

        var lines = table.lines();
        var count: u32 = 0;

        for (0..lines.remaining) |_| {
            const line = lines.next() orelse break;
            const start = @intFromPtr(line.text.ptr) - @intFromPtr(text.ptr);

            try testing.expect(line.text.len > 0);
            try testing.expect(start + line.text.len <= text.len);
            try testing.expect(std.mem.findScalar(u8, line.text, '\n') == null);

            count += 1;
        }

        const end = lines.next();

        try testing.expect(end == null);
        try testing.expectEqual(@as(u32, 0), lines.remaining);
        try testing.expect(count <= std.mem.count(u8, text, "\n") + 1);
    }
}
