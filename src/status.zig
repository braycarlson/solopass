const std = @import("std");

const Twingate = @import("twingate.zig").Twingate;

const assert = std.debug.assert;

pub const Status = enum {
    authenticating,
    connecting,
    offline,
    online,
    starting,
    stopped,
    stopping,
    unknown,

    pub const Tone = enum {
        busy,
        connected,
        idle,
        unknown,
    };

    pub const detail_bytes_max: u32 = 8 * 1024;

    pub fn detail(status: Status, text: []const u8) []const u8 {
        assert(text.len <= Twingate.output_bytes_max);

        const result = switch (status) {
            .authenticating, .online => sign_in_url(text),
            .unknown => text,
            .connecting, .offline, .starting, .stopped, .stopping => "",
        };

        assert(result.len <= text.len);

        return result;
    }

    pub fn is_running(status: Status) bool {
        return status != .stopped;
    }

    pub fn is_transitional(status: Status) bool {
        return switch (status) {
            .connecting, .starting, .stopping => true,
            .authenticating, .offline, .online, .stopped, .unknown => false,
        };
    }

    pub fn label(status: Status) []const u8 {
        return switch (status) {
            .authenticating => "Signing in",
            .connecting => "Connecting\u{2026}",
            .offline => "Disconnected",
            .online => "Connected",
            .starting => "Starting\u{2026}",
            .stopped => "Not running",
            .stopping => "Stopping\u{2026}",
            .unknown => "Unavailable",
        };
    }

    pub fn parse(text: []const u8) Status {
        assert(text.len <= Twingate.output_bytes_max);

        const trimmed = std.mem.trim(u8, text, " \t\r\n");
        var lines = std.mem.splitScalar(u8, trimmed, '\n');
        const line = std.mem.trimEnd(u8, lines.first(), " \t\r");

        for (names) |name| {
            if (!std.mem.startsWith(u8, line, name.text)) continue;
            if (is_word_end(line[name.text.len..])) return name.status;
        }

        return .unknown;
    }

    pub fn tone(status: Status) Tone {
        return switch (status) {
            .authenticating, .connecting, .starting, .stopping => .busy,
            .offline, .stopped => .idle,
            .online => .connected,
            .unknown => .unknown,
        };
    }
};

const Name = struct {
    status: Status,
    text: []const u8,
};

const names = [_]Name{
    .{ .status = .authenticating, .text = "authenticating" },
    .{ .status = .connecting, .text = "connecting" },
    .{ .status = .offline, .text = "disconnected" },
    .{ .status = .offline, .text = "offline" },
    .{ .status = .online, .text = "online" },
    .{ .status = .starting, .text = "starting" },
    .{ .status = .stopped, .text = "not-running" },
    .{ .status = .stopping, .text = "stopping" },
};

comptime {
    assert(Status.detail_bytes_max <= Twingate.output_bytes_max);

    for (std.enums.values(Status)) |status| {
        var named = false;

        for (names) |name| {
            if (name.status == status) named = true;
        }

        assert(named == (status != .unknown));
    }
}

fn is_word_end(rest: []const u8) bool {
    assert(rest.len <= Twingate.output_bytes_max);

    if (rest.len == 0) return true;

    return std.ascii.isUpper(rest[0]);
}

fn sign_in_url(text: []const u8) []const u8 {
    assert(text.len <= Twingate.output_bytes_max);

    var lines = std.mem.splitScalar(u8, text, '\n');
    var count: u32 = 0;

    while (lines.next()) |raw| : (count += 1) {
        assert(count <= text.len);

        const line = std.mem.trim(u8, raw, " \t\r");
        if (!std.mem.startsWith(u8, line, "https://")) continue;
        if (line.len > Status.detail_bytes_max) return "";

        return line;
    }

    return "";
}

const testing = std.testing;

const sign_in_state: [900]u8 = @splat('s');
const sign_in_page = "https://login.example.com/authorize?state=" ++ sign_in_state;

const sign_in_output =
    "authenticating\n" ++
    "Visit the following URL to authenticate to your Twingate network:\n" ++
    "\n" ++
    sign_in_page ++ "\n";

const resource_output =
    "onlineA resource you attempted to access requires additional authentication.\n" ++
    "Open the following URL to authorize access to the resource:\n" ++
    "\n" ++
    sign_in_page ++ "\n";

test Status {
    const status = Status.parse("online\n");

    try testing.expectEqual(Status.online, status);
    try testing.expectEqualStrings("Connected", status.label());
    try testing.expectEqual(Status.Tone.connected, status.tone());
    try testing.expect(status.is_running());
    try testing.expect(!status.is_transitional());
    try testing.expectEqualStrings("", status.detail("online\n"));
}

test "each word the cli prints maps to its state" {
    try testing.expectEqual(Status.authenticating, Status.parse("authenticating"));
    try testing.expectEqual(Status.connecting, Status.parse("connecting"));
    try testing.expectEqual(Status.offline, Status.parse("disconnected"));
    try testing.expectEqual(Status.offline, Status.parse("offline"));
    try testing.expectEqual(Status.online, Status.parse("online\n"));
    try testing.expectEqual(Status.starting, Status.parse("starting"));
    try testing.expectEqual(Status.stopped, Status.parse("not-running\n"));
    try testing.expectEqual(Status.stopping, Status.parse("  stopping\r\n"));
}

test "an unexpected word is unknown rather than guessed" {
    try testing.expectEqual(Status.unknown, Status.parse(""));
    try testing.expectEqual(Status.unknown, Status.parse("Online"));
    try testing.expectEqual(Status.unknown, Status.parse("online now"));
    try testing.expectEqual(Status.unknown, Status.parse("error: connection refused"));
    try testing.expectEqual(Status.unknown, Status.parse("Visit the page\nauthenticating\n"));
}

test "the first line names the state and the lines after it are detail" {
    try testing.expectEqual(Status.authenticating, Status.parse(sign_in_output));
    try testing.expectEqual(Status.online, Status.parse("online\nResources are reachable.\n"));
    try testing.expectEqual(Status.stopped, Status.parse("\n not-running \r\n\n"));
}

test "a sign-in carries its whole page as the detail" {
    try testing.expect(sign_in_page.len > 512);
    try testing.expectEqualStrings(sign_in_page, Status.authenticating.detail(sign_in_output));
    try testing.expectEqualStrings("", Status.offline.detail(sign_in_output));
    try testing.expectEqualStrings("", Status.authenticating.detail("authenticating\n"));
    try testing.expectEqualStrings("", Status.authenticating.detail("x\nhttp://a.example\n"));
    try testing.expectEqualStrings("error: refused", Status.unknown.detail("error: refused"));
}

test "a resource sign-in the cli glues onto the online word keeps the word and its page" {
    try testing.expectEqual(Status.online, Status.parse(resource_output));
    try testing.expectEqualStrings(sign_in_page, Status.online.detail(resource_output));
    try testing.expectEqualStrings("", Status.online.detail("online\n"));
}

test "each state word parses with a sentence glued on and never as part of a longer word" {
    var buffer: [64]u8 = undefined;

    for (names) |name| {
        const glued = try std.mem.print(&buffer, "{s}A resource needs a sign-in.", .{name.text});

        try testing.expectEqual(name.status, Status.parse(glued));

        const longer = try std.mem.print(&buffer, "{s}x", .{name.text});

        try testing.expectEqual(Status.unknown, Status.parse(longer));
    }
}

test "a page longer than the detail holds is dropped rather than cut" {
    const head = "authenticating\n";

    var text: [head.len + Status.detail_bytes_max + 1]u8 = @splat('a');

    @memcpy(text[0..head.len], head);
    @memcpy(text[head.len..][0.."https://".len], "https://");

    const fits = Status.authenticating.detail(text[0 .. text.len - 1]);
    const long = Status.authenticating.detail(&text);

    try testing.expectEqual(@as(usize, Status.detail_bytes_max), fits.len);
    try testing.expectEqual(@as(usize, 0), long.len);
}

test "the stopped service alone reports itself as not running" {
    for (std.enums.values(Status)) |status| {
        try testing.expectEqual(status != .stopped, status.is_running());
        try testing.expect(status.label().len > 0);
    }

    try testing.expectEqual(Status.Tone.connected, Status.online.tone());
    try testing.expectEqual(Status.Tone.busy, Status.authenticating.tone());
    try testing.expectEqual(Status.Tone.idle, Status.stopped.tone());
    try testing.expectEqual(Status.Tone.unknown, Status.unknown.tone());
}

test "a status is transitional and trails off exactly when the service is on its way up or down" {
    const transitional = [_]Status{ .connecting, .starting, .stopping };

    for (std.enums.values(Status)) |status| {
        const expected = std.mem.findScalar(Status, &transitional, status) != null;
        const label = status.label();

        try testing.expectEqual(expected, status.is_transitional());
        try testing.expectEqual(expected, std.mem.endsWith(u8, label, "\u{2026}"));

        if (expected) try testing.expectEqual(Status.Tone.busy, status.tone());
    }
}
