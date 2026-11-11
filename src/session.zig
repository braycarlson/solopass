const std = @import("std");

const Action = @import("action.zig").Action;
const Snapshot = @import("snapshot.zig").Snapshot;
const Status = @import("status.zig").Status;
const TextType = @import("text.zig").TextType;
const Twingate = @import("twingate.zig").Twingate;

const assert = std.debug.assert;

pub const Session = struct {
    command: ?Command,
    mutex: std.Io.Mutex,
    snapshot: Snapshot,

    pub const Command = struct {
        account: Account,
        action: Action,

        pub const Account = TextType(Twingate.account_bytes_max);
    };

    pub fn init(session: *Session) void {
        session.* = .{ .command = null, .mutex = .init, .snapshot = .initial };

        assert(session.command == null);
        assert(session.snapshot.generation == 0);
    }

    pub fn accept(session: *Session, io: std.Io) void {
        session.mutex.lockUncancelable(io);
        defer session.mutex.unlock(io);

        assert(session.snapshot.pending != null);
        assert(!session.snapshot.accepted);

        session.snapshot.accepted = true;
        session.bump();
    }

    pub fn clear_message(session: *Session, io: std.Io) void {
        session.mutex.lockUncancelable(io);
        defer session.mutex.unlock(io);

        if (session.snapshot.message.text.length == 0) return;

        session.snapshot.message.text = .empty;
        session.bump();
    }

    pub fn copy(session: *Session, io: std.Io, target: *Snapshot) bool {
        session.mutex.lockUncancelable(io);
        defer session.mutex.unlock(io);

        if (target.generation == session.snapshot.generation) return false;

        target.* = session.snapshot;

        assert(target.generation == session.snapshot.generation);

        return true;
    }

    pub fn finish(session: *Session, io: std.Io) void {
        session.mutex.lockUncancelable(io);
        defer session.mutex.unlock(io);

        assert(session.snapshot.pending != null);
        assert(session.command == null);

        session.snapshot.accepted = false;
        session.snapshot.pending = null;
        session.bump();
    }

    pub fn log_request(session: *Session, io: std.Io) ?u64 {
        session.mutex.lockUncancelable(io);
        defer session.mutex.unlock(io);

        const log = &session.snapshot.log;
        if (!log.reading()) return null;

        assert(log.requested > log.served);

        return log.requested;
    }

    pub fn request_log(session: *Session, io: std.Io) void {
        session.mutex.lockUncancelable(io);
        defer session.mutex.unlock(io);

        const log = &session.snapshot.log;

        log.requested += 1;
        session.bump();

        assert(log.reading());
    }

    pub fn set_accounts(session: *Session, io: std.Io, text: []const u8) void {
        assert(text.len <= Twingate.output_bytes_max);

        session.mutex.lockUncancelable(io);
        defer session.mutex.unlock(io);

        const snapshot = &session.snapshot;

        if (snapshot.accounts_observed) {
            if (std.mem.eql(u8, snapshot.accounts.slice(), text)) return;
        }

        snapshot.accounts.set(text);
        snapshot.accounts_observed = true;
        session.bump();

        assert(std.mem.eql(u8, snapshot.accounts.slice(), text));
    }

    pub fn set_locked(session: *Session, io: std.Io, locked: bool) void {
        session.mutex.lockUncancelable(io);
        defer session.mutex.unlock(io);

        if (session.snapshot.locked == locked) return;

        session.snapshot.locked = locked;
        session.bump();

        assert(session.snapshot.locked == locked);
    }

    pub fn set_log(session: *Session, io: std.Io, served: u64, text: []const u8) void {
        assert(served > 0);
        assert(text.len <= Twingate.output_bytes_max);

        session.mutex.lockUncancelable(io);
        defer session.mutex.unlock(io);

        const log = &session.snapshot.log;

        assert(served > log.served);
        assert(served <= log.requested);

        log.served = served;
        log.text.set(text);
        session.bump();
    }

    pub fn set_message(
        session: *Session,
        io: std.Io,
        kind: Snapshot.Message.Kind,
        text: []const u8,
    ) void {
        assert(text.len > 0);
        assert(text.len <= Twingate.output_bytes_max);

        session.mutex.lockUncancelable(io);
        defer session.mutex.unlock(io);

        const message = &session.snapshot.message;

        message.text.set(text);
        message.kind = kind;
        message.generation += 1;
        session.bump();
    }

    pub fn set_resources(session: *Session, io: std.Io, text: []const u8) void {
        assert(text.len <= Twingate.output_bytes_max);

        session.mutex.lockUncancelable(io);
        defer session.mutex.unlock(io);

        const snapshot = &session.snapshot;

        assert(snapshot.status == .online);

        if (snapshot.resources_observed) {
            if (std.mem.eql(u8, snapshot.resources.slice(), text)) return;
        }

        snapshot.resources.set(text);
        snapshot.resources_observed = true;
        session.bump();

        assert(std.mem.eql(u8, snapshot.resources.slice(), text));
    }

    pub fn set_status(
        session: *Session,
        io: std.Io,
        status: Status,
        detail: []const u8,
        now_seconds: i64,
    ) void {
        assert(detail.len <= Twingate.output_bytes_max);
        assert(now_seconds >= 0);

        session.mutex.lockUncancelable(io);
        defer session.mutex.unlock(io);

        const snapshot = &session.snapshot;
        if (snapshot.reports(status, detail)) return;

        if (status == .online) {
            if (snapshot.status == .online) {
                assert(snapshot.observed);
            } else {
                snapshot.online_since_seconds = if (snapshot.observed) now_seconds else null;
            }
        } else {
            snapshot.locked = false;
            snapshot.online_since_seconds = null;
            snapshot.resources = .empty;
            snapshot.resources_observed = false;
        }

        snapshot.status = status;
        snapshot.observed = true;
        snapshot.detail.set(detail);
        session.bump();

        if (status != .online) assert(snapshot.resources.length == 0);
        if (status != .online) assert(!snapshot.locked);
    }

    pub fn settled(session: *Session, io: std.Io) bool {
        session.mutex.lockUncancelable(io);
        defer session.mutex.unlock(io);

        assert(session.snapshot.pending != null);
        assert(session.command == null);

        return session.snapshot.settled();
    }

    pub fn submit(session: *Session, io: std.Io, action: Action, account: []const u8) bool {
        if (account.len > Twingate.account_bytes_max) return false;

        session.mutex.lockUncancelable(io);
        defer session.mutex.unlock(io);

        if (session.command != null) return false;
        if (session.snapshot.pending != null) return false;

        assert(!session.snapshot.accepted);

        var command: Command = .{ .account = .empty, .action = action };

        command.account.set(account);

        session.command = command;
        session.snapshot.pending = action;
        session.bump();

        assert(std.mem.eql(u8, session.command.?.account.slice(), account));

        return true;
    }

    pub fn take(session: *Session, io: std.Io) ?Command {
        session.mutex.lockUncancelable(io);
        defer session.mutex.unlock(io);

        const command = session.command orelse return null;

        assert(session.snapshot.pending == command.action);

        session.command = null;

        return command;
    }

    fn bump(session: *Session) void {
        const generation = session.snapshot.generation;

        session.snapshot.generation = generation + 1;

        assert(session.snapshot.generation > generation);
    }
};

const testing = std.testing;

test Session {
    const io = testing.io;

    var session: Session = undefined;

    session.init();
    session.set_status(io, .offline, "", 10);

    try testing.expect(session.submit(io, .connect, ""));

    const command = session.take(io) orelse return error.CommandMissing;

    try testing.expectEqual(Action.connect, command.action);

    session.finish(io);

    var snapshot: Snapshot = .initial;

    try testing.expect(session.copy(io, &snapshot));
    try testing.expectEqual(Status.offline, snapshot.status);
}

test "a reader copies only when the generation moved" {
    const io = testing.io;

    var session: Session = undefined;
    var snapshot: Snapshot = .initial;

    session.init();

    try testing.expect(!session.copy(io, &snapshot));

    session.set_status(io, .offline, "", 100);

    try testing.expect(session.copy(io, &snapshot));
    try testing.expect(!session.copy(io, &snapshot));
    try testing.expectEqual(Status.offline, snapshot.status);
    try testing.expect(snapshot.observed);

    session.set_status(io, .offline, "", 200);

    try testing.expect(!session.copy(io, &snapshot));
}

test "there is one command in flight at a time" {
    const io = testing.io;

    var session: Session = undefined;

    session.init();

    try testing.expect(session.submit(io, .connect, ""));
    try testing.expect(!session.submit(io, .stop, ""));
    try testing.expectEqual(Action.connect, session.take(io).?.action);
    try testing.expectEqual(@as(?Session.Command, null), session.take(io));
    try testing.expect(!session.submit(io, .stop, ""));

    session.finish(io);

    try testing.expect(session.submit(io, .switch_account, "a@b.c"));

    const command = session.take(io).?;

    try testing.expectEqual(Action.switch_account, command.action);
    try testing.expectEqualStrings("a@b.c", command.account.slice());

    session.finish(io);

    const long: [Twingate.account_bytes_max + 1]u8 = @splat('a');

    try testing.expect(!session.submit(io, .switch_account, &long));
    try testing.expectEqual(@as(?Action, null), session.snapshot.pending);
}

test "the connected clock starts only on an observed transition" {
    const io = testing.io;

    var session: Session = undefined;

    session.init();
    session.set_status(io, .online, "", 1_000);

    try testing.expectEqual(@as(?i64, null), session.snapshot.online_since_seconds);

    session.set_status(io, .offline, "", 1_100);
    session.set_status(io, .online, "", 1_200);
    session.set_status(io, .online, "", 1_300);

    try testing.expectEqual(@as(?i64, 1_200), session.snapshot.online_since_seconds);

    session.set_status(io, .stopped, "", 1_400);

    try testing.expectEqual(@as(?i64, null), session.snapshot.online_since_seconds);
}

test "a tunnel that drops clears its resources in the same update a reader copies" {
    const io = testing.io;

    var session: Session = undefined;
    var snapshot: Snapshot = .initial;

    session.init();
    session.set_status(io, .online, "", 10);
    session.set_resources(io, "NAME\tADDRESS\nWiki\twiki.internal");

    try testing.expect(session.copy(io, &snapshot));
    try testing.expect(snapshot.resources_observed);

    const generation = snapshot.generation;

    session.set_status(io, .offline, "", 20);

    try testing.expect(session.copy(io, &snapshot));
    try testing.expectEqual(generation + 1, snapshot.generation);
    try testing.expectEqual(Status.offline, snapshot.status);
    try testing.expectEqual(@as(usize, 0), snapshot.resources.slice().len);
    try testing.expect(!snapshot.resources_observed);

    session.set_status(io, .online, "", 30);

    try testing.expect(session.copy(io, &snapshot));
    try testing.expect(!snapshot.resources_observed);
}

test "an empty list read still counts as read and an unchanged one moves nothing" {
    const io = testing.io;

    var session: Session = undefined;

    session.init();
    session.set_status(io, .online, "", 10);

    try testing.expect(!session.snapshot.accounts_observed);
    try testing.expect(!session.snapshot.resources_observed);

    const generation = session.snapshot.generation;

    session.set_accounts(io, "");
    session.set_resources(io, "");

    try testing.expect(session.snapshot.accounts_observed);
    try testing.expect(session.snapshot.resources_observed);
    try testing.expectEqual(generation + 2, session.snapshot.generation);

    session.set_accounts(io, "");
    session.set_resources(io, "");

    try testing.expectEqual(generation + 2, session.snapshot.generation);
}

test "an accepted command stays pending until it finishes" {
    const io = testing.io;

    var session: Session = undefined;

    session.init();

    try testing.expect(session.submit(io, .connect, ""));
    try testing.expectEqual(Action.connect, session.take(io).?.action);

    session.accept(io);

    try testing.expect(session.snapshot.accepted);
    try testing.expectEqual(@as(?Action, .connect), session.snapshot.pending);
    try testing.expect(!session.settled(io));

    session.set_status(io, .online, "", 10);

    try testing.expect(session.settled(io));

    session.finish(io);

    try testing.expect(!session.snapshot.accepted);
    try testing.expectEqual(@as(?Action, null), session.snapshot.pending);
    try testing.expect(session.submit(io, .disconnect, ""));
}

test "a sign-in offers a page only when it carries one" {
    const io = testing.io;
    const page = "https://login.example.com/authorize?state=abc";

    var session: Session = undefined;

    session.init();
    session.set_status(io, .authenticating, page, 0);

    try testing.expectEqualStrings(page, session.snapshot.sign_in_url() orelse "");

    session.set_status(io, .authenticating, "", 1);

    try testing.expect(session.snapshot.sign_in_url() == null);

    session.set_status(io, .unknown, page, 2);

    try testing.expect(session.snapshot.sign_in_url() == null);

    session.set_status(io, .online, page, 3);

    try testing.expectEqualStrings(page, session.snapshot.sign_in_url() orelse "");

    session.set_status(io, .online, "", 4);

    try testing.expect(session.snapshot.sign_in_url() == null);
}

test "a lock moves the generation once and goes with the tunnel" {
    const io = testing.io;

    var session: Session = undefined;

    session.init();
    session.set_status(io, .online, "", 10);

    const generation = session.snapshot.generation;

    session.set_locked(io, true);
    session.set_locked(io, true);

    try testing.expect(session.snapshot.locked);
    try testing.expect(session.snapshot.needs_sign_in());
    try testing.expectEqual(generation + 1, session.snapshot.generation);

    session.set_status(io, .offline, "", 20);

    try testing.expect(!session.snapshot.locked);
    try testing.expect(!session.snapshot.needs_sign_in());

    session.set_status(io, .online, "", 30);

    try testing.expect(session.snapshot.is_connected());
}

test "a message replaces the last one and counts each time it is set" {
    const io = testing.io;

    var session: Session = undefined;

    session.init();
    session.set_message(io, .failure, "The password prompt was dismissed.");
    session.set_message(io, .information, "Switched account.");

    const message = &session.snapshot.message;

    try testing.expectEqual(@as(u64, 2), message.generation);
    try testing.expectEqual(Snapshot.Message.Kind.information, message.kind);
    try testing.expectEqualStrings("Switched account.", message.text.slice());

    session.clear_message(io);

    try testing.expectEqual(@as(usize, 0), message.text.slice().len);
    try testing.expectEqual(@as(u64, 2), message.generation);
}

test "a log request stays outstanding until a read serves the newest one" {
    const io = testing.io;

    var session: Session = undefined;
    var snapshot: Snapshot = .initial;

    session.init();

    try testing.expectEqual(@as(?u64, null), session.log_request(io));

    session.request_log(io);

    try testing.expect(session.copy(io, &snapshot));
    try testing.expect(snapshot.log.reading());

    const first = session.log_request(io) orelse return error.RequestMissing;

    session.request_log(io);
    session.set_log(io, first, "older");

    const log = &session.snapshot.log;

    try testing.expect(log.reading());
    try testing.expectEqualStrings("older", log.text.slice());

    const second = session.log_request(io) orelse return error.RequestMissing;

    try testing.expect(second > first);

    session.set_log(io, second, "newer");

    try testing.expect(!log.reading());
    try testing.expectEqual(@as(?u64, null), session.log_request(io));
    try testing.expectEqualStrings("newer", log.text.slice());
    try testing.expect(session.copy(io, &snapshot));
    try testing.expectEqualStrings("newer", snapshot.log.text.slice());
}
