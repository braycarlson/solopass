const std = @import("std");

const Status = @import("status.zig").Status;

pub const Action = enum {
    connect,
    disconnect,
    refresh,
    sign_in,
    stop,
    switch_account,

    pub fn label(action: Action) []const u8 {
        return switch (action) {
            .connect => "Connect",
            .disconnect => "Disconnect",
            .refresh => "Refresh",
            .sign_in => "Sign in",
            .stop => "Stop Twingate",
            .switch_account => "Switch account",
        };
    }

    pub fn progress(action: Action) []const u8 {
        return switch (action) {
            .connect => "Connecting\u{2026}",
            .disconnect => "Disconnecting\u{2026}",
            .refresh => "Refreshing\u{2026}",
            .sign_in => "Signing in\u{2026}",
            .stop => "Stopping\u{2026}",
            .switch_account => "Switching\u{2026}",
        };
    }

    pub fn toggle(status: Status) Action {
        return switch (status.tone()) {
            .busy, .connected => .disconnect,
            .idle, .unknown => .connect,
        };
    }
};

const testing = std.testing;

test Action {
    const action = Action.toggle(.offline);

    try testing.expectEqual(Action.connect, action);
    try testing.expectEqualStrings("Connect", action.label());
    try testing.expectEqualStrings("Connecting\u{2026}", action.progress());
}

test "each action names itself and trails off while it runs" {
    for (std.enums.values(Action)) |action| {
        const label = action.label();
        const progress = action.progress();

        try testing.expect(label.len > 0);
        try testing.expect(!std.mem.eql(u8, label, progress));
        try testing.expect(std.mem.endsWith(u8, progress, "\u{2026}"));
        try testing.expect(!std.mem.endsWith(u8, label, "\u{2026}"));
    }
}

test "the toggle disconnects whatever is connected or on its way" {
    try testing.expectEqual(Action.disconnect, Action.toggle(.online));
    try testing.expectEqual(Action.disconnect, Action.toggle(.authenticating));
    try testing.expectEqual(Action.connect, Action.toggle(.offline));
    try testing.expectEqual(Action.connect, Action.toggle(.stopped));
    try testing.expectEqual(Action.connect, Action.toggle(.unknown));
}
