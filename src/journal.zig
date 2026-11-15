const std = @import("std");

const Fake = @import("fake.zig").Fake;
const Session = @import("session.zig").Session;
const Twingate = @import("twingate.zig").Twingate;

const assert = std.debug.assert;

const Allocator = std.mem.Allocator;
const Environ = std.process.Environ;

pub const Journal = struct {
    io: std.Io,
    session: *Session,
    twingate: Twingate,

    pub fn init(
        journal: *Journal,
        gpa: Allocator,
        io: std.Io,
        session: *Session,
        paths: *const Twingate.Paths,
        environment: *const Environ.Map,
    ) Allocator.Error!void {
        assert(paths.journalctl.len > 0);

        try journal.twingate.init(gpa, io, paths, environment);

        journal.io = io;
        journal.session = session;

        assert(journal.twingate.paths.journalctl.len == paths.journalctl.len);
    }

    pub fn deinit(journal: *Journal) void {
        assert(journal.twingate.paths.journalctl.len > 0);
        assert(journal.twingate.paths.twingate.len > 0);

        journal.twingate.deinit();
    }

    pub fn run(journal: *Journal) std.Io.Cancelable!void {
        var iteration: u64 = 0;

        while (iteration < iteration_max) : (iteration += 1) {
            try journal.step();
            try journal.io.sleep(.fromMilliseconds(tick_ms), .awake);
        }

        assert(iteration == iteration_max);
    }

    pub fn step(journal: *Journal) std.Io.Cancelable!void {
        const request = journal.session.log_request(journal.io) orelse return;
        const result = try journal.twingate.run(.journal);

        assert(request > 0);
        assert(result.text.len <= Twingate.output_bytes_max);

        journal.session.set_log(journal.io, request, result.text);
    }
};

const iteration_max: u64 = 1 << 48;
const tick_ms: i64 = 100;

comptime {
    assert(tick_ms > 0);
    assert(tick_ms < std.time.ms_per_s);
}

const testing = std.testing;

const entries =
    "[2026-11-08T13:25:56.214696-0600] [INFO] [client] Connected to the network\n" ++
    "[2026-11-08T13:25:51.104112-0600] [INFO] [client] Connecting\n";

const Fixture = struct {
    calls_buffer: [512]u8,
    fake: Fake,
    journal: Journal,
    session: Session,

    fn init(fixture: *Fixture, io: std.Io) !void {
        try fixture.fake.init(io);
        errdefer fixture.fake.deinit();

        const paths = fixture.fake.paths();
        const environment = &fixture.fake.environment;

        fixture.session.init();
        try fixture.journal.init(testing.allocator, io, &fixture.session, &paths, environment);

        assert(fixture.journal.session == &fixture.session);
        assert(std.mem.eql(u8, fixture.journal.twingate.paths.journalctl, paths.journalctl));
    }

    fn deinit(fixture: *Fixture) void {
        fixture.journal.deinit();
        fixture.fake.deinit();
    }

    fn calls(fixture: *Fixture, io: std.Io) ![]const u8 {
        const text = try fixture.fake.read(io, .calls, &fixture.calls_buffer);

        assert(text.len <= fixture.calls_buffer.len);

        return text;
    }
};

test Journal {
    const io = testing.io;

    var fixture: Fixture = undefined;

    try fixture.init(io);
    defer fixture.deinit();

    try fixture.fake.write(io, .journal, entries);

    fixture.session.request_log(io);

    try fixture.journal.step();

    const log = &fixture.session.snapshot.log;

    try testing.expect(!log.reading());
    try testing.expectEqualStrings(std.mem.trimEnd(u8, entries, "\n"), log.text.slice());
}

test "a step without a request reads nothing" {
    const io = testing.io;

    var fixture: Fixture = undefined;

    try fixture.init(io);
    defer fixture.deinit();

    try fixture.fake.write(io, .journal, entries);
    try fixture.journal.step();

    const log = &fixture.session.snapshot.log;

    try testing.expectEqualStrings("", try fixture.calls(io));
    try testing.expectEqual(@as(u64, 0), log.served);
    try testing.expectEqual(@as(usize, 0), log.text.slice().len);
}

test "a failed read leaves its reason where the entries would be" {
    const io = testing.io;

    var fixture: Fixture = undefined;

    try fixture.init(io);
    defer fixture.deinit();

    try fixture.fake.write(io, .fail, "");

    fixture.session.request_log(io);

    try fixture.journal.step();

    const log = &fixture.session.snapshot.log;

    try testing.expect(!log.reading());
    try testing.expectEqualStrings("journalctl refused", log.text.slice());
}

test "a step serves the newest request and leaves a later one to the next step" {
    const io = testing.io;

    var fixture: Fixture = undefined;

    try fixture.init(io);
    defer fixture.deinit();

    fixture.session.request_log(io);
    fixture.session.request_log(io);

    try fixture.journal.step();

    const log = &fixture.session.snapshot.log;

    try testing.expect(!log.reading());
    try testing.expectEqual(@as(u64, 2), log.served);

    fixture.session.request_log(io);

    try testing.expect(log.reading());

    try fixture.fake.write(io, .journal, entries);
    try fixture.journal.step();

    try testing.expect(!log.reading());
    try testing.expectEqualStrings(std.mem.trimEnd(u8, entries, "\n"), log.text.slice());
}
