const std = @import("std");

const Action = @import("action.zig").Action;
const Fake = @import("fake.zig").Fake;
const Inventory = @import("inventory.zig").Inventory;
const Session = @import("session.zig").Session;
const Snapshot = @import("snapshot.zig").Snapshot;
const Status = @import("status.zig").Status;
const Twingate = @import("twingate.zig").Twingate;

const assert = std.debug.assert;
const log = std.log.scoped(.worker);

const Allocator = std.mem.Allocator;
const Environ = std.process.Environ;

pub const Worker = struct {
    accounts_due_ms: i64,
    authentication_due: bool,
    inventory_due_ms: ?i64,
    io: std.Io,
    online: bool,
    resources_due_ms: ?i64,
    scratch: [Inventory.scratch_bytes_max]u8,
    session: *Session,
    signing: bool,
    status_due_ms: i64,
    twingate: Twingate,

    const Pair = struct {
        notifier: Twingate.Request,
        privileged: Twingate.Request,
    };

    pub fn init(
        worker: *Worker,
        gpa: Allocator,
        io: std.Io,
        session: *Session,
        paths: *const Twingate.Paths,
        environment: *const Environ.Map,
    ) Allocator.Error!void {
        try worker.twingate.init(gpa, io, paths, environment);

        worker.accounts_due_ms = 0;
        worker.authentication_due = false;
        worker.inventory_due_ms = null;
        worker.io = io;
        worker.online = false;
        worker.resources_due_ms = null;
        worker.session = session;
        worker.signing = false;
        worker.status_due_ms = 0;

        assert(worker.accounts_due_ms == 0);
        assert(!worker.authentication_due);
        assert(worker.inventory_due_ms == null);
        assert(!worker.online);
        assert(worker.resources_due_ms == null);
    }

    pub fn deinit(worker: *Worker) void {
        assert(worker.status_due_ms >= 0);

        worker.twingate.deinit();
    }

    pub fn run(worker: *Worker) std.Io.Cancelable!void {
        var iteration: u64 = 0;

        while (iteration < iteration_max) : (iteration += 1) {
            try worker.step();
            try worker.io.sleep(.fromMilliseconds(tick_ms), .awake);
        }

        assert(iteration == iteration_max);
    }

    pub fn step(worker: *Worker) std.Io.Cancelable!void {
        if (worker.authentication_due) assert(worker.online);
        if (worker.inventory_due_ms != null) assert(worker.online);
        if (worker.resources_due_ms != null) assert(worker.online);

        if (worker.session.take(worker.io)) |command| {
            try worker.execute(&command);
        }

        const now = worker.now_ms();

        if (now >= worker.status_due_ms) {
            try worker.poll_status();
        }

        if (now >= worker.accounts_due_ms) {
            try worker.refresh_accounts();
        }

        if (worker.resources_due_ms) |due| {
            if (now >= due) try worker.refresh_resources();
        }

        if (worker.inventory_due_ms) |due| {
            if (now >= due) try worker.check_sign_in(worker.authentication_due);
        }
    }

    fn execute(worker: *Worker, command: *const Session.Command) std.Io.Cancelable!void {
        defer worker.session.finish(worker.io);

        worker.session.clear_message(worker.io);
        worker.status_due_ms = 0;

        switch (command.action) {
            .connect => {
                const pair: Pair = .{ .notifier = .desktop_start, .privileged = .connect };

                if (try worker.perform_pair(pair)) try worker.settle(.connect);
            },
            .disconnect => {
                if (try worker.perform(.disconnect)) try worker.settle(.disconnect);
            },
            .refresh => {
                worker.accounts_due_ms = 0;

                if (worker.online) worker.resources_due_ms = 0;
            },
            .sign_in => try worker.sign_in(),
            .stop => {
                const pair: Pair = .{ .notifier = .desktop_stop, .privileged = .service_stop };

                if (try worker.perform_pair(pair)) try worker.settle(.stop);
            },
            .switch_account => try worker.switch_account(command.account.slice()),
        }
    }

    fn now_ms(worker: *const Worker) i64 {
        const result = std.Io.Clock.awake.now(worker.io).toMilliseconds();

        assert(result >= 0);

        return result;
    }

    fn perform(worker: *Worker, request: Twingate.Request) std.Io.Cancelable!bool {
        if (request == .switch_account) assert(Twingate.is_account(request.switch_account));

        const result = try worker.run_request(request);
        if (result.outcome == .succeeded) return true;

        assert(result.text.len > 0);

        worker.session.set_message(worker.io, .failure, result.text);

        return false;
    }

    fn perform_pair(worker: *Worker, pair: Pair) std.Io.Cancelable!bool {
        assert(pair.privileged.is_privileged());
        assert(!pair.notifier.is_privileged());

        if (!try worker.perform(pair.privileged)) return false;

        _ = try worker.perform(pair.notifier);

        return true;
    }

    fn poll_status(worker: *Worker) std.Io.Cancelable!void {
        const now = worker.now_ms();
        var result = try worker.run_request(.status);
        const reading = status_of(&result);
        const page = reading.detail(result.text);
        const arrived = !worker.online and reading == .online;
        const ended = worker.signing and reading == .online and page.len == 0;
        const recheck = arrived or ended;

        if (arrived) worker.authentication_due = true;

        if (recheck) {
            try worker.check_sign_in(worker.authentication_due);

            result = try worker.run_request(.status);
        }

        const status = status_of(&result);
        const detail = status.detail(result.text);
        const online = status == .online;
        const boot_seconds = std.Io.Clock.boot.now(worker.io).toSeconds();
        const page_pending = status == .authenticating and detail.len == 0;
        const transitional = status.is_transitional() or page_pending;

        const interval_ms = if (transitional)
            transition_interval_ms
        else
            status_interval_ms;

        if (online) {
            if (!worker.online) {
                worker.accounts_due_ms = 0;
                worker.resources_due_ms = 0;
            }
        } else {
            worker.authentication_due = false;
            worker.inventory_due_ms = null;
            worker.resources_due_ms = null;
        }

        worker.online = online;
        worker.signing = online and detail.len > 0;
        worker.status_due_ms = now + interval_ms;
        worker.session.set_status(worker.io, status, detail, boot_seconds);

        assert(worker.status_due_ms > now);
        if (!worker.online) assert(!worker.authentication_due);
        if (!worker.online) assert(worker.inventory_due_ms == null);
        if (!worker.online) assert(worker.resources_due_ms == null);
    }

    fn refresh_accounts(worker: *Worker) std.Io.Cancelable!void {
        assert(worker.now_ms() >= worker.accounts_due_ms);

        const result = try worker.run_request(.accounts);

        worker.accounts_due_ms = worker.now_ms() + accounts_interval_ms;
        worker.session.set_accounts(worker.io, result.text);
    }

    fn refresh_resources(worker: *Worker) std.Io.Cancelable!void {
        assert(worker.resources_due_ms != null);
        assert(worker.online);

        const result = try worker.run_request(.resources);

        worker.resources_due_ms = worker.now_ms() + resources_interval_ms;
        worker.session.set_resources(worker.io, result.text);
    }

    fn check_sign_in(worker: *Worker, start: bool) std.Io.Cancelable!void {
        if (start) assert(worker.authentication_due or worker.online);

        const listed = try worker.run_request(.inventory);

        worker.inventory_due_ms = worker.now_ms() + inventory_interval_ms;

        if (listed.outcome != .succeeded) return;

        var allocator: std.heap.FixedBufferAllocator = .init(&worker.scratch);

        const inventory = Inventory.parse(allocator.allocator(), listed.text) catch |err| {
            log.warn("the resource list could not be read: {t}", .{err});
            worker.authentication_due = false;
            worker.session.set_locked(worker.io, false);

            return;
        };

        const now_seconds = std.Io.Clock.real.now(worker.io).toSeconds();
        const verdict = inventory.verdict(now_seconds);

        worker.session.set_locked(worker.io, verdict == .locked);

        const locked = switch (verdict) {
            .empty => return,
            .locked => |name| name,
            .settled => {
                worker.authentication_due = false;

                return;
            },
        };

        if (!start) return;

        worker.authentication_due = false;

        try worker.start_sign_in(locked);
    }

    fn start_sign_in(worker: *Worker, name: []const u8) std.Io.Cancelable!void {
        assert(Twingate.is_resource(name));
        assert(!worker.authentication_due);

        var buffer: [Twingate.resource_bytes_max]u8 = undefined;

        @memcpy(buffer[0..name.len], name);

        const resource = buffer[0..name.len];
        const started = try worker.run_request(.{ .authenticate = resource });

        switch (started.outcome) {
            .succeeded, .timed_out => {},
            .denied, .failed, .missing => {
                log.warn("the sign-in for {s} did not start: {s}", .{ resource, started.text });
            },
        }
    }

    fn sign_in(worker: *Worker) std.Io.Cancelable!void {
        assert(worker.status_due_ms == 0);

        if (!worker.online) return;

        try worker.check_sign_in(true);
        try worker.poll_status();

        assert(worker.status_due_ms > 0);
    }

    fn run_request(worker: *Worker, request: Twingate.Request) std.Io.Cancelable!Twingate.Result {
        if (request == .switch_account) assert(Twingate.is_account(request.switch_account));

        const result = try worker.twingate.run(request);

        assert(result.text.len <= Twingate.output_bytes_max);

        return result;
    }

    fn settle(worker: *Worker, action: Action) std.Io.Cancelable!void {
        assert(action != .refresh);
        assert(action != .sign_in);
        assert(action != .switch_account);

        worker.session.accept(worker.io);

        var poll: u32 = 0;

        while (poll < settle_polls_max) : (poll += 1) {
            try worker.poll_status();
            if (worker.session.settled(worker.io)) return;

            try worker.io.sleep(.fromMilliseconds(transition_interval_ms), .awake);
        }

        assert(poll == settle_polls_max);

        const text = switch (action) {
            .connect => settle_overdue("come online"),
            .disconnect => settle_overdue("disconnect"),
            .refresh, .sign_in, .switch_account => unreachable,
            .stop => settle_overdue("stop"),
        };

        worker.session.set_message(worker.io, .failure, text);
    }

    fn switch_account(worker: *Worker, account: []const u8) std.Io.Cancelable!void {
        assert(account.len <= Twingate.account_bytes_max);

        worker.accounts_due_ms = 0;

        if (!Twingate.is_account(account)) {
            worker.session.set_message(worker.io, .failure, "That account name is not valid.");

            return;
        }

        const result = try worker.run_request(.{ .switch_account = account });

        if (result.outcome != .succeeded) {
            assert(result.text.len > 0);

            worker.session.set_message(worker.io, .failure, result.text);

            return;
        }

        if (result.text.len > 0) {
            worker.session.set_message(worker.io, .information, result.text);
        }
    }
};

const accounts_interval_ms: i64 = 10 * std.time.ms_per_s;
const inventory_interval_ms: i64 = 60 * std.time.ms_per_s;
const iteration_max: u64 = 1 << 48;
const resources_interval_ms: i64 = 60 * std.time.ms_per_s;
const settle_polls_max: u32 = 60;
const settle_seconds_max: u32 = 30;
const status_interval_ms: i64 = 2 * std.time.ms_per_s;
const tick_ms: i64 = 200;
const transition_interval_ms: i64 = 500;

comptime {
    assert(tick_ms < transition_interval_ms);
    assert(transition_interval_ms < status_interval_ms);
    assert(status_interval_ms < accounts_interval_ms);
    assert(accounts_interval_ms < resources_interval_ms);
    assert(accounts_interval_ms < inventory_interval_ms);
    assert(settle_polls_max * transition_interval_ms == settle_seconds_max * std.time.ms_per_s);
}

fn status_of(result: *const Twingate.Result) Status {
    assert(result.text.len <= Twingate.output_bytes_max);

    const status: Status = switch (result.outcome) {
        .succeeded => Status.parse(result.text),
        .denied, .failed, .missing, .timed_out => .unknown,
    };

    if (result.outcome != .succeeded) assert(status == .unknown);

    return status;
}

fn settle_overdue(comptime change: []const u8) []const u8 {
    comptime assert(change.len > 0);

    return std.fmt.comptimePrint(
        "Twingate did not {s} within {d} seconds.",
        .{ change, settle_seconds_max },
    );
}

const testing = std.testing;

const account_list =
    "EMAIL                  \tNETWORK   \tNETWORK URL\n" ++
    "avery.quinn@example.com\tExampleNet\texamplenet.twingate.com\n";

const account_marked =
    "EMAIL                  \tNETWORK      \tNETWORK URL               \t\n" ++
    "avery.quinn@example.com\tExampleNet   \texamplenet.twingate.com   \t\n" ++
    "tester@example.com     \tSolopass Test\tsolopass-test.twingate.com\t*\n";

const calls_bytes_max: u32 = 4096;
const sign_in_state: [900]u8 = @splat('s');
const sign_in_page = "https://login.example.com/authorize?state=" ++ sign_in_state;

const sign_in_output =
    "authenticating\n" ++
    "Visit the following URL to authenticate to your Twingate network:\n" ++
    "\n" ++
    sign_in_page ++ "\n";

const Fixture = struct {
    calls_buffer: [calls_bytes_max]u8,
    fake: Fake,
    session: Session,
    worker: Worker,

    fn init(fixture: *Fixture, io: std.Io) !void {
        try fixture.fake.init(io);
        errdefer fixture.fake.deinit();

        try fixture.fake.write(io, .accounts, account_list);

        const paths = fixture.fake.paths();
        const environment = &fixture.fake.environment;

        fixture.session.init();
        try fixture.worker.init(testing.allocator, io, &fixture.session, &paths, environment);
    }

    fn deinit(fixture: *Fixture) void {
        fixture.worker.deinit();
        fixture.fake.deinit();
    }

    fn calls(fixture: *Fixture, io: std.Io) ![]const u8 {
        return fixture.fake.read(io, .calls, &fixture.calls_buffer);
    }

    fn submit(fixture: *Fixture, io: std.Io, action: Action, account: []const u8) !void {
        try testing.expect(fixture.session.submit(io, action, account));
    }
};

test Worker {
    const io = testing.io;

    var fixture: Fixture = undefined;

    try fixture.init(io);
    defer fixture.deinit();

    try fixture.worker.step();
    try fixture.submit(io, .disconnect, "");
    try fixture.worker.step();

    const snapshot = &fixture.session.snapshot;

    try testing.expectEqual(Status.offline, snapshot.status);
    try testing.expectEqual(@as(?Action, null), snapshot.pending);
    try testing.expectEqual(@as(usize, 0), snapshot.message.text.slice().len);
}

test "the first step reads the status and the accounts" {
    const io = testing.io;

    var fixture: Fixture = undefined;

    try fixture.init(io);
    defer fixture.deinit();

    try fixture.worker.step();

    const snapshot = &fixture.session.snapshot;
    const accounts = snapshot.accounts.slice();
    const calls = try fixture.calls(io);

    try testing.expectEqual(Status.offline, snapshot.status);
    try testing.expectEqualStrings(std.mem.trimEnd(u8, account_list, "\n"), accounts);
    try testing.expectEqualStrings("twingate -d status\ntwingate -d account list\n", calls);
}

test "an elevated connect starts the notifier and then lists the resources" {
    const io = testing.io;

    var fixture: Fixture = undefined;

    try fixture.init(io);
    defer fixture.deinit();

    try fixture.worker.step();
    try fixture.fake.write(io, .status, "online\n");
    try fixture.fake.write(io, .resources, "NAME\tADDRESS\nWiki\twiki.internal\n");
    try fixture.fake.write(io, .inventory, unlocked_inventory);
    try fixture.submit(io, .connect, "");
    try fixture.worker.step();

    const expected =
        "twingate -d status\n" ++
        "twingate -d account list\n" ++
        "pkexec twingate -d connect\n" ++
        "twingate -d connect\n" ++
        "twingate -d desktop-start\n" ++
        "twingate -d status\n" ++
        "twingate-notifier resources\n" ++
        "twingate -d status\n" ++
        "twingate -d account list\n" ++
        "twingate -d resources\n";

    const snapshot = &fixture.session.snapshot;
    const resources = snapshot.resources.slice();
    const calls = try fixture.calls(io);

    try testing.expectEqualStrings(expected, calls);
    try testing.expectEqual(Status.online, snapshot.status);
    try testing.expectEqual(@as(?Action, null), snapshot.pending);
    try testing.expectEqualStrings("NAME\tADDRESS\nWiki\twiki.internal", resources);
}

const locked_inventory =
    "{\"resources\":[" ++
    "{\"name\":\"Wiki\",\"auth_flow_id\":\"104618\"," ++
    "\"auth_state\":\"none\",\"auth_expires_at\":4102444800}," ++
    "{\"name\":\"Lethbridge Compute Network\",\"auth_flow_id\":\"104620\"," ++
    "\"auth_state\":\"none\",\"auth_expires_at\":0}" ++
    "]}\n";

const unlocked_inventory =
    "{\"resources\":[" ++
    "{\"name\":\"Lethbridge Compute Network\",\"auth_flow_id\":\"104620\"," ++
    "\"auth_state\":\"none\",\"auth_expires_at\":4102444800}" ++
    "]}\n";

fn authentication_calls(calls: []const u8) u32 {
    assert(calls.len <= calls_bytes_max);

    const call = "twingate-notifier auth Lethbridge Compute Network\n";
    const count = std.mem.count(u8, calls, call);

    assert(count <= calls.len);

    return @intCast(count);
}

test "a connect starts the sign-in for a locked resource once, before anything is visited" {
    const io = testing.io;

    var fixture: Fixture = undefined;

    try fixture.init(io);
    defer fixture.deinit();

    try fixture.worker.step();
    try fixture.fake.write(io, .status, "online\n");
    try fixture.fake.write(io, .inventory, locked_inventory);
    try fixture.submit(io, .connect, "");
    try fixture.worker.step();

    const connected = try fixture.calls(io);

    const tail =
        "twingate -d status\n" ++
        "twingate-notifier resources\n" ++
        "twingate-notifier auth Lethbridge Compute Network\n" ++
        "twingate -d status\n" ++
        "twingate -d account list\n" ++
        "twingate -d resources\n";

    try testing.expect(std.mem.endsWith(u8, connected, tail));
    try testing.expectEqual(@as(u32, 1), authentication_calls(connected));
    try testing.expect(!fixture.worker.authentication_due);

    fixture.worker.resources_due_ms = 0;
    try fixture.worker.step();

    try testing.expectEqual(@as(u32, 1), authentication_calls(try fixture.calls(io)));
}

test "each return of the tunnel owes one sign-in, and an unlocked list settles it" {
    const io = testing.io;

    var fixture: Fixture = undefined;

    try fixture.init(io);
    defer fixture.deinit();

    try fixture.fake.write(io, .status, "online\n");
    try fixture.fake.write(io, .inventory, unlocked_inventory);
    try fixture.worker.step();

    try testing.expect(!fixture.worker.authentication_due);
    try testing.expectEqual(@as(u32, 0), authentication_calls(try fixture.calls(io)));

    try fixture.fake.write(io, .status, "offline\n");
    fixture.worker.status_due_ms = 0;
    try fixture.worker.step();

    try testing.expect(!fixture.worker.authentication_due);

    try fixture.fake.write(io, .status, "online\n");
    try fixture.fake.write(io, .inventory, locked_inventory);
    fixture.worker.status_due_ms = 0;
    try fixture.worker.step();

    try testing.expectEqual(@as(u32, 1), authentication_calls(try fixture.calls(io)));
}

test "a resource list that has not arrived yet keeps the sign-in owed" {
    const io = testing.io;

    var fixture: Fixture = undefined;

    try fixture.init(io);
    defer fixture.deinit();

    try fixture.fake.write(io, .status, "online\n");
    try fixture.fake.write(io, .resources, "No resources currently available\n");
    try fixture.worker.step();

    try testing.expect(fixture.worker.authentication_due);
    try testing.expectEqual(@as(u32, 0), authentication_calls(try fixture.calls(io)));

    try fixture.fake.write(io, .inventory, locked_inventory);
    fixture.worker.inventory_due_ms = 0;
    try fixture.worker.step();

    try testing.expect(!fixture.worker.authentication_due);
    try testing.expectEqual(@as(u32, 1), authentication_calls(try fixture.calls(io)));
}

test "a list that does not parse settles the sign-in without starting one" {
    testing.log_level = .err;

    const io = testing.io;

    var fixture: Fixture = undefined;

    try fixture.init(io);
    defer fixture.deinit();

    try fixture.fake.write(io, .status, "online\n");
    try fixture.fake.write(io, .inventory, "not connected\n");
    try fixture.worker.step();

    try testing.expect(!fixture.worker.authentication_due);
    try testing.expectEqual(@as(u32, 0), authentication_calls(try fixture.calls(io)));
}

test "a sign-in left waiting on the browser starts once and reports no failure" {
    const io = testing.io;

    var fixture: Fixture = undefined;

    try fixture.init(io);
    defer fixture.deinit();

    try fixture.fake.write(io, .hang, "");
    try fixture.fake.write(io, .inventory, locked_inventory);
    try fixture.fake.write(io, .status, "online\n");
    try fixture.worker.step();

    const snapshot = &fixture.session.snapshot;

    try testing.expectEqual(@as(u32, 1), authentication_calls(try fixture.calls(io)));
    try testing.expect(!fixture.worker.authentication_due);
    try testing.expectEqual(Status.online, snapshot.status);
    try testing.expectEqual(@as(usize, 0), snapshot.message.text.slice().len);
}

const resource_prompt =
    "onlineA resource you attempted to access requires additional authentication.\n" ++
    "Open the following URL to authorize access to the resource:\n" ++
    "\n" ++
    sign_in_page ++ "\n";

test "a tunnel that comes up needing a sign-in is reported signing in, never connected first" {
    const io = testing.io;

    var fixture: Fixture = undefined;

    try fixture.init(io);
    defer fixture.deinit();

    try fixture.fake.write(io, .inventory, locked_inventory);
    try fixture.fake.write(io, .prompt, resource_prompt);
    try fixture.fake.write(io, .status, "online\n");
    try fixture.worker.step();

    const snapshot = &fixture.session.snapshot;

    const order =
        "twingate -d status\n" ++
        "twingate-notifier resources\n" ++
        "twingate-notifier auth Lethbridge Compute Network\n" ++
        "twingate -d status\n";

    try testing.expect(std.mem.startsWith(u8, try fixture.calls(io), order));
    try testing.expectEqual(@as(u64, 4), snapshot.generation);
    try testing.expectEqualStrings(sign_in_page, snapshot.sign_in_url() orelse "");
    try testing.expect(!snapshot.is_connected());

    try fixture.fake.write(io, .inventory, unlocked_inventory);
    try fixture.fake.write(io, .status, "online\n");
    fixture.worker.status_due_ms = 0;
    try fixture.worker.step();

    try testing.expect(snapshot.is_connected());
    try testing.expectEqual(@as(u32, 1), authentication_calls(try fixture.calls(io)));
}

test "a sign-in left unfinished stays owed, and the sign-in action starts a fresh one" {
    const io = testing.io;

    var fixture: Fixture = undefined;

    try fixture.init(io);
    defer fixture.deinit();

    try fixture.fake.write(io, .inventory, locked_inventory);
    try fixture.fake.write(io, .prompt, resource_prompt);
    try fixture.fake.write(io, .status, "online\n");
    try fixture.worker.step();

    const snapshot = &fixture.session.snapshot;

    try testing.expect(snapshot.sign_in_url() != null);

    try fixture.fake.write(io, .status, "online\n");
    fixture.worker.status_due_ms = 0;
    try fixture.worker.step();

    try testing.expect(snapshot.sign_in_url() == null);
    try testing.expect(snapshot.locked);
    try testing.expectEqualStrings("Sign-in needed", snapshot.label());
    try testing.expectEqual(@as(u32, 1), authentication_calls(try fixture.calls(io)));

    fixture.worker.inventory_due_ms = 0;
    try fixture.worker.step();

    try testing.expectEqual(@as(u32, 1), authentication_calls(try fixture.calls(io)));

    try fixture.submit(io, .sign_in, "");
    try fixture.worker.step();

    try testing.expectEqual(@as(u32, 2), authentication_calls(try fixture.calls(io)));
    try testing.expectEqualStrings(sign_in_page, snapshot.sign_in_url() orelse "");
    try testing.expectEqual(@as(?Action, null), snapshot.pending);

    try fixture.fake.write(io, .inventory, unlocked_inventory);
    try fixture.fake.write(io, .status, "online\n");
    fixture.worker.status_due_ms = 0;
    try fixture.worker.step();

    try testing.expect(!snapshot.locked);
    try testing.expect(snapshot.is_connected());
}

test "a connect stays pending until the tunnel is up" {
    const io = testing.io;

    var fixture: Fixture = undefined;

    try fixture.init(io);
    defer fixture.deinit();

    try fixture.worker.step();
    try fixture.fake.write(io, .status_queue, "offline\nauthenticating\nonline\nonline\n");
    try fixture.submit(io, .connect, "");
    try fixture.worker.step();

    const expected =
        "twingate -d status\n" ++
        "twingate -d account list\n" ++
        "pkexec twingate -d connect\n" ++
        "twingate -d connect\n" ++
        "twingate -d desktop-start\n" ++
        "twingate -d status\n" ++
        "twingate -d status\n" ++
        "twingate -d status\n" ++
        "twingate-notifier resources\n" ++
        "twingate -d status\n" ++
        "twingate -d account list\n" ++
        "twingate -d resources\n";

    const snapshot = &fixture.session.snapshot;
    const calls = try fixture.calls(io);

    try testing.expectEqualStrings(expected, calls);
    try testing.expectEqual(Status.online, snapshot.status);
    try testing.expectEqual(@as(?Action, null), snapshot.pending);
    try testing.expect(!snapshot.accepted);
    try testing.expectEqual(@as(usize, 0), snapshot.message.text.slice().len);
}

test "a connect that needs a sign-in stops waiting when the page appears" {
    const io = testing.io;

    var fixture: Fixture = undefined;

    try fixture.init(io);
    defer fixture.deinit();

    try fixture.worker.step();
    try fixture.fake.write(io, .status, sign_in_output);
    try fixture.submit(io, .connect, "");
    try fixture.worker.step();

    const snapshot = &fixture.session.snapshot;
    const calls = try fixture.calls(io);
    const settled = "twingate -d desktop-start\ntwingate -d status\n";

    try testing.expect(std.mem.endsWith(u8, calls, settled));
    try testing.expectEqual(@as(?Action, null), snapshot.pending);
    try testing.expectEqualStrings(sign_in_page, snapshot.sign_in_url() orelse "");
}

test "a disconnect stays pending until the tunnel is down" {
    const io = testing.io;

    var fixture: Fixture = undefined;

    try fixture.init(io);
    defer fixture.deinit();

    try fixture.fake.write(io, .status, "online\n");
    try fixture.worker.step();
    try fixture.fake.write(io, .status_queue, "online\noffline\n");
    try fixture.submit(io, .disconnect, "");
    try fixture.worker.step();

    const snapshot = &fixture.session.snapshot;
    const calls = try fixture.calls(io);
    const settled = "twingate -d disconnect\ntwingate -d status\ntwingate -d status\n";

    try testing.expect(std.mem.endsWith(u8, calls, settled));
    try testing.expectEqual(Status.offline, snapshot.status);
    try testing.expectEqual(@as(?Action, null), snapshot.pending);
    try testing.expectEqual(@as(usize, 0), snapshot.resources.slice().len);
}

test "a tunnel in transition is read again within half a second and a settled one in two" {
    const io = testing.io;

    var fixture: Fixture = undefined;

    try fixture.init(io);
    defer fixture.deinit();

    const cases = [_]struct { output: []const u8, interval_ms: i64 }{
        .{ .output = "connecting\n", .interval_ms = 500 },
        .{ .output = "online\n", .interval_ms = 2000 },
        .{ .output = "authenticating\n", .interval_ms = 500 },
        .{ .output = sign_in_output, .interval_ms = 2000 },
        .{ .output = "stopping\n", .interval_ms = 500 },
        .{ .output = "offline\n", .interval_ms = 2000 },
    };

    for (cases) |case| {
        try fixture.fake.write(io, .status, case.output);

        fixture.worker.status_due_ms = 0;

        const before_ms = fixture.worker.now_ms();

        try fixture.worker.step();

        const after_ms = fixture.worker.now_ms();
        const due_ms = fixture.worker.status_due_ms;

        try testing.expect(due_ms >= before_ms + case.interval_ms);
        try testing.expect(due_ms <= after_ms + case.interval_ms);
    }
}

test "an account list changed outside solopass is read again once the tunnel comes up" {
    const io = testing.io;

    var fixture: Fixture = undefined;

    try fixture.init(io);
    defer fixture.deinit();

    try fixture.worker.step();
    try fixture.fake.write(io, .accounts, account_marked);
    try fixture.fake.write(io, .status, "online\n");

    fixture.worker.status_due_ms = 0;

    try fixture.worker.step();

    const accounts = fixture.session.snapshot.accounts.slice();

    try testing.expectEqualStrings(std.mem.trim(u8, account_marked, " \t\r\n"), accounts);
}

test "a settled session reads the account list again after ten seconds and not before" {
    const io = testing.io;

    var fixture: Fixture = undefined;

    try fixture.init(io);
    defer fixture.deinit();

    const before_ms = fixture.worker.now_ms();

    try fixture.worker.step();

    const after_ms = fixture.worker.now_ms();
    const due_ms = fixture.worker.accounts_due_ms;
    const interval_ms = 10 * std.time.ms_per_s;

    try testing.expect(due_ms >= before_ms + interval_ms);
    try testing.expect(due_ms <= after_ms + interval_ms);

    try fixture.fake.write(io, .accounts, account_marked);

    fixture.worker.status_due_ms = 0;

    try fixture.worker.step();

    const snapshot = &fixture.session.snapshot;
    const stale = std.mem.trimEnd(u8, account_list, "\n");
    const fresh = std.mem.trim(u8, account_marked, " \t\r\n");

    try testing.expectEqualStrings(stale, snapshot.accounts.slice());

    fixture.worker.accounts_due_ms = 0;

    try fixture.worker.step();

    try testing.expectEqualStrings(fresh, snapshot.accounts.slice());
}

test "a sign-in keeps the whole page the cli printed" {
    const io = testing.io;

    var fixture: Fixture = undefined;

    try fixture.init(io);
    defer fixture.deinit();

    try fixture.fake.write(io, .status, sign_in_output);
    try fixture.worker.step();

    const snapshot = &fixture.session.snapshot;

    try testing.expectEqual(Status.authenticating, snapshot.status);
    try testing.expectEqualStrings(sign_in_page, snapshot.sign_in_url() orelse "");
}

test "a dismissed prompt stops the pair and leaves a failure message" {
    const io = testing.io;

    var fixture: Fixture = undefined;

    try fixture.init(io);
    defer fixture.deinit();

    try fixture.worker.step();
    try fixture.fake.write(io, .deny, "");
    try fixture.submit(io, .stop, "");
    try fixture.worker.step();

    const snapshot = &fixture.session.snapshot;
    const message = snapshot.message.text.slice();
    const calls = try fixture.calls(io);

    try testing.expect(std.mem.find(u8, calls, "pkexec twingate -d service-stop\n") != null);
    try testing.expect(std.mem.find(u8, calls, "desktop-stop") == null);
    try testing.expectEqual(Snapshot.Message.Kind.failure, snapshot.message.kind);
    try testing.expectEqualStrings("The password prompt was dismissed.", message);
}

test "an account outside the polkit charset never reaches pkexec" {
    const io = testing.io;

    var fixture: Fixture = undefined;

    try fixture.init(io);
    defer fixture.deinit();

    try fixture.worker.step();
    try fixture.submit(io, .switch_account, "evil;reboot");
    try fixture.worker.step();

    const message = fixture.session.snapshot.message.text.slice();
    const calls = try fixture.calls(io);

    try testing.expect(std.mem.find(u8, calls, "pkexec") == null);
    try testing.expectEqualStrings("That account name is not valid.", message);
}

test "a valid account switch is elevated and the accounts are read again" {
    const io = testing.io;

    var fixture: Fixture = undefined;

    try fixture.init(io);
    defer fixture.deinit();

    try fixture.worker.step();
    try fixture.submit(io, .switch_account, "avery.quinn@example.com");
    try fixture.worker.step();

    const calls = try fixture.calls(io);
    const switched = "pkexec twingate -d account switch avery.quinn@example.com\n";
    const reread = "twingate -d status\ntwingate -d account list\n";

    try testing.expect(std.mem.find(u8, calls, switched) != null);
    try testing.expect(std.mem.endsWith(u8, calls, reread));
}

test "a missing cli leaves the status unknown with the reason" {
    const io = testing.io;

    var session: Session = undefined;
    var worker: Worker = undefined;
    var parent: Environ.Map = .init(testing.allocator);
    defer parent.deinit();

    const paths: Twingate.Paths = .{
        .journalctl = "/nonexistent/journalctl",
        .notifier = "/nonexistent/twingate-notifier",
        .pkexec = "/nonexistent/pkexec",
        .twingate = "/nonexistent/twingate",
    };

    session.init();

    try worker.init(testing.allocator, io, &session, &paths, &parent);
    defer worker.deinit();

    try worker.step();

    const detail = session.snapshot.detail.slice();

    try testing.expectEqual(Status.unknown, session.snapshot.status);
    try testing.expect(session.snapshot.observed);
    try testing.expectEqualStrings("Twingate is not installed.", detail);
}
