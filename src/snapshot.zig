const std = @import("std");

const Action = @import("action.zig").Action;
const Elapsed = @import("elapsed.zig").Elapsed;
const Status = @import("status.zig").Status;
const TextType = @import("text.zig").TextType;
const Twingate = @import("twingate.zig").Twingate;

const assert = std.debug.assert;

pub const Snapshot = struct {
    accepted: bool,
    accounts: Accounts,
    accounts_observed: bool,
    detail: Detail,
    generation: u64,
    locked: bool,
    log: Log,
    message: Message,
    observed: bool,
    online_since_seconds: ?i64,
    pending: ?Action,
    resources: Resources,
    resources_observed: bool,
    status: Status,

    pub const Accounts = TextType(accounts_bytes_max);
    pub const Detail = TextType(Status.detail_bytes_max);
    pub const Resources = TextType(resources_bytes_max);

    pub const Log = struct {
        requested: u64,
        served: u64,
        text: Text,

        pub const Text = TextType(Twingate.journal_bytes_max);

        pub const empty: Log = .{ .requested = 0, .served = 0, .text = .empty };

        pub fn reading(log: *const Log) bool {
            assert(log.served <= log.requested);
            assert(log.text.length <= Twingate.journal_bytes_max);

            return log.served < log.requested;
        }
    };

    pub const Message = struct {
        generation: u64,
        kind: Kind,
        text: Text,

        pub const Kind = enum {
            failure,
            information,
        };

        pub const Text = TextType(message_bytes_max);

        pub const empty: Message = .{ .generation = 0, .kind = .information, .text = .empty };
    };

    pub const accounts_bytes_max: u32 = 8 * 1024;
    pub const message_bytes_max: u32 = 1024;
    pub const resources_bytes_max: u32 = 64 * 1024;

    pub const initial: Snapshot = .{
        .accepted = false,
        .accounts = .empty,
        .accounts_observed = false,
        .detail = .empty,
        .generation = 0,
        .locked = false,
        .log = .empty,
        .message = .empty,
        .observed = false,
        .online_since_seconds = null,
        .pending = null,
        .resources = .empty,
        .resources_observed = false,
        .status = .unknown,
    };

    pub fn activity(snapshot: *const Snapshot) ?Action {
        const action = snapshot.pending orelse return null;
        if (action == .refresh) return null;

        return action;
    }

    pub fn connected_seconds(snapshot: *const Snapshot, now_seconds: i64) ?u64 {
        assert(now_seconds >= 0);

        if (!snapshot.is_connected()) return null;

        const since = snapshot.online_since_seconds orelse return null;
        if (now_seconds <= since) return 0;

        assert(since >= 0);

        const result: u64 = @intCast(now_seconds - since);

        assert(result > 0);
        assert(result <= Elapsed.seconds_max);

        return result;
    }

    pub fn is_connected(snapshot: *const Snapshot) bool {
        if (snapshot.status != .online) return false;

        return !snapshot.needs_sign_in();
    }

    pub fn label(snapshot: *const Snapshot) []const u8 {
        if (snapshot.sign_in_url() != null) return Status.authenticating.label();
        if (snapshot.needs_sign_in()) return label_locked;

        return snapshot.status.label();
    }

    pub fn needs_sign_in(snapshot: *const Snapshot) bool {
        if (snapshot.sign_in_url() != null) return true;
        if (snapshot.status != .online) return false;

        return snapshot.locked;
    }

    pub fn progress(snapshot: *const Snapshot) ?[]const u8 {
        if (snapshot.activity()) |action| return action.progress();
        if (snapshot.status.is_transitional()) return snapshot.status.label();

        return null;
    }

    pub fn settled(snapshot: *const Snapshot) bool {
        const action = snapshot.pending orelse return true;

        return switch (action) {
            .connect => snapshot.status == .online or snapshot.sign_in_url() != null,
            .disconnect => snapshot.status == .offline or snapshot.status == .stopped,
            .refresh, .sign_in, .switch_account => true,
            .stop => snapshot.status == .stopped,
        };
    }

    pub fn sign_in_url(snapshot: *const Snapshot) ?[]const u8 {
        switch (snapshot.status) {
            .authenticating, .online => {},
            .connecting, .offline, .starting, .stopped, .stopping, .unknown => return null,
        }

        const url = snapshot.detail.slice();
        if (url.len == 0) return null;

        return url;
    }

    pub fn tone(snapshot: *const Snapshot) Status.Tone {
        if (!snapshot.observed) return .busy;
        if (snapshot.activity() != null) return .busy;
        if (snapshot.needs_sign_in()) return .busy;

        return snapshot.status.tone();
    }

    pub fn reports(snapshot: *const Snapshot, status: Status, detail: []const u8) bool {
        assert(detail.len <= Twingate.output_bytes_max);

        if (!snapshot.observed) return false;
        if (snapshot.status != status) return false;

        return std.mem.eql(u8, snapshot.detail.slice(), detail);
    }
};

const label_locked = "Sign-in needed";

comptime {
    assert(Snapshot.accounts_bytes_max <= Twingate.output_bytes_max);
    assert(Snapshot.message_bytes_max <= Twingate.output_bytes_max);
    assert(Snapshot.resources_bytes_max <= Twingate.output_bytes_max);
}

const testing = std.testing;

test Snapshot {
    var snapshot: Snapshot = .initial;

    snapshot.observed = true;
    snapshot.status = .online;
    snapshot.online_since_seconds = 100;

    try testing.expectEqual(Status.Tone.connected, snapshot.tone());
    try testing.expectEqual(@as(?u64, 60), snapshot.connected_seconds(160));
    try testing.expect(snapshot.progress() == null);
    try testing.expect(snapshot.settled());
}

test "the connected time counts from the observed transition" {
    var snapshot: Snapshot = .initial;

    snapshot.observed = true;
    snapshot.status = .online;

    try testing.expectEqual(@as(?u64, null), snapshot.connected_seconds(500));

    snapshot.online_since_seconds = 400;

    try testing.expectEqual(@as(?u64, 100), snapshot.connected_seconds(500));
    try testing.expectEqual(@as(?u64, 0), snapshot.connected_seconds(300));

    snapshot.status = .offline;

    try testing.expectEqual(@as(?u64, null), snapshot.connected_seconds(500));
}

test "a snapshot reads as busy until observed and while a command runs" {
    var snapshot: Snapshot = .initial;

    try testing.expectEqual(Status.Tone.busy, snapshot.tone());

    snapshot.observed = true;
    snapshot.status = .online;

    try testing.expectEqual(Status.Tone.connected, snapshot.tone());

    snapshot.pending = .disconnect;

    try testing.expectEqual(Status.Tone.busy, snapshot.tone());
}

test "a connect reads as one unbroken progress until the tunnel settles" {
    var snapshot: Snapshot = .initial;

    snapshot.observed = true;
    snapshot.status = .offline;

    try testing.expect(snapshot.progress() == null);

    snapshot.pending = .connect;

    const requested = snapshot.progress().?;

    snapshot.pending = null;
    snapshot.status = .connecting;

    const transitional = snapshot.progress().?;

    try testing.expectEqualStrings(requested, transitional);

    snapshot.status = .online;

    try testing.expect(snapshot.progress() == null);

    snapshot.pending = .refresh;

    try testing.expect(snapshot.activity() == null);
    try testing.expect(snapshot.progress() == null);
    try testing.expectEqual(Status.Tone.connected, snapshot.tone());

    snapshot.pending = .disconnect;

    try testing.expectEqual(@as(?Action, .disconnect), snapshot.activity());
    try testing.expectEqualStrings("Disconnecting\u{2026}", snapshot.progress().?);
    try testing.expectEqual(Status.Tone.busy, snapshot.tone());
}

test "a command settles only once the status shows what it asked for" {
    const page = "https://login.example.com/authorize?state=abc";

    const cases = [_]struct { action: Action, page: []const u8, settled: bool, status: Status }{
        .{ .action = .connect, .page = "", .settled = true, .status = .online },
        .{ .action = .connect, .page = page, .settled = true, .status = .authenticating },
        .{ .action = .connect, .page = "", .settled = false, .status = .authenticating },
        .{ .action = .connect, .page = "", .settled = false, .status = .offline },
        .{ .action = .connect, .page = "", .settled = false, .status = .connecting },
        .{ .action = .connect, .page = "", .settled = false, .status = .starting },
        .{ .action = .connect, .page = "", .settled = false, .status = .stopped },
        .{ .action = .connect, .page = "", .settled = false, .status = .unknown },
        .{ .action = .disconnect, .page = "", .settled = true, .status = .offline },
        .{ .action = .disconnect, .page = "", .settled = true, .status = .stopped },
        .{ .action = .disconnect, .page = "", .settled = false, .status = .online },
        .{ .action = .disconnect, .page = page, .settled = false, .status = .authenticating },
        .{ .action = .stop, .page = "", .settled = true, .status = .stopped },
        .{ .action = .stop, .page = "", .settled = false, .status = .stopping },
        .{ .action = .stop, .page = "", .settled = false, .status = .offline },
        .{ .action = .stop, .page = "", .settled = false, .status = .online },
        .{ .action = .refresh, .page = "", .settled = true, .status = .online },
        .{ .action = .switch_account, .page = "", .settled = true, .status = .authenticating },
    };

    for (cases) |case| {
        var snapshot: Snapshot = .initial;

        snapshot.observed = true;
        snapshot.pending = case.action;
        snapshot.status = case.status;
        snapshot.detail.set(case.page);

        try testing.expectEqual(case.settled, snapshot.settled());

        snapshot.pending = null;

        try testing.expect(snapshot.settled());
    }
}

test "a sign-in waiting on a tunnel that is up reads exactly like the network sign-in" {
    const page = "https://login.example.com/authorize?state=abc";

    var snapshot: Snapshot = .initial;

    snapshot.observed = true;
    snapshot.status = .online;
    snapshot.online_since_seconds = 100;

    try testing.expect(snapshot.is_connected());
    try testing.expectEqualStrings("Connected", snapshot.label());
    try testing.expectEqual(Status.Tone.connected, snapshot.tone());
    try testing.expectEqual(@as(?u64, 60), snapshot.connected_seconds(160));

    snapshot.detail.set(page);

    for ([_]Status{ .authenticating, .online }) |status| {
        snapshot.status = status;

        try testing.expect(!snapshot.is_connected());
        try testing.expectEqualStrings(Status.authenticating.label(), snapshot.label());
        try testing.expectEqual(Status.authenticating.tone(), snapshot.tone());
        try testing.expectEqual(@as(?u64, null), snapshot.connected_seconds(160));
        try testing.expectEqual(Action.disconnect, Action.toggle(status));
    }
}

test "a tunnel whose resources still owe a sign-in reads as needing one, only while it is up" {
    var snapshot: Snapshot = .initial;

    snapshot.observed = true;
    snapshot.status = .online;
    snapshot.locked = true;

    try testing.expect(snapshot.sign_in_url() == null);
    try testing.expect(snapshot.needs_sign_in());
    try testing.expect(!snapshot.is_connected());
    try testing.expectEqualStrings("Sign-in needed", snapshot.label());
    try testing.expectEqual(Status.Tone.busy, snapshot.tone());
    try testing.expectEqual(@as(?u64, null), snapshot.connected_seconds(160));

    snapshot.detail.set("https://login.example.com/authorize?state=abc");

    try testing.expectEqualStrings("Signing in", snapshot.label());

    snapshot.detail.set("");
    snapshot.status = .offline;

    try testing.expect(!snapshot.needs_sign_in());
    try testing.expectEqualStrings("Disconnected", snapshot.label());
    try testing.expectEqual(Status.Tone.idle, snapshot.tone());
}

test "a snapshot reports only the status and detail it already holds" {
    var snapshot: Snapshot = .initial;

    try testing.expect(!snapshot.reports(.unknown, ""));

    snapshot.observed = true;
    snapshot.status = .authenticating;
    snapshot.detail.set("https://login.example.com");

    try testing.expect(snapshot.reports(.authenticating, "https://login.example.com"));
    try testing.expect(!snapshot.reports(.authenticating, ""));
    try testing.expect(!snapshot.reports(.online, "https://login.example.com"));
}

test "a log read stays in flight until the newest request is served" {
    var log: Snapshot.Log = .empty;

    try testing.expect(!log.reading());

    log.requested = 2;
    log.served = 1;

    try testing.expect(log.reading());

    log.served = 2;

    try testing.expect(!log.reading());
    try testing.expect(!Snapshot.initial.log.reading());
}
