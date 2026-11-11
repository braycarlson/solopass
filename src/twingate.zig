const std = @import("std");

const Fake = @import("fake.zig").Fake;

const assert = std.debug.assert;

const Allocator = std.mem.Allocator;
const Environ = std.process.Environ;

pub const Twingate = struct {
    io: std.Io,
    output: [output_bytes_max]u8,
    paths: Paths,
    quiet: Environ.Map,
    scratch: [scratch_bytes_max]u8,

    pub const Paths = struct {
        journalctl: []const u8,
        notifier: []const u8,
        pkexec: []const u8,
        twingate: []const u8,

        pub const system: Paths = .{
            .journalctl = "/usr/bin/journalctl",
            .notifier = "/usr/bin/twingate-notifier",
            .pkexec = "/usr/bin/pkexec",
            .twingate = "/usr/bin/twingate",
        };

        pub fn arguments(
            paths: *const Paths,
            request: Request,
            buffer: *[argument_count_max][]const u8,
        ) []const []const u8 {
            assert(paths.journalctl.len > 0);
            assert(paths.notifier.len > 0);
            assert(paths.pkexec.len > 0);
            assert(paths.twingate.len > 0);
            if (request == .authenticate) assert(is_resource(request.authenticate));
            if (request == .switch_account) assert(is_account(request.switch_account));

            var count: u32 = 0;

            if (request.is_privileged()) {
                buffer[count] = paths.pkexec;
                count += 1;
            }

            switch (request.binary()) {
                .journalctl => {
                    buffer[count] = paths.journalctl;
                    count += 1;
                },
                .notifier => {
                    buffer[count] = paths.notifier;
                    count += 1;
                },
                .twingate => {
                    buffer[count] = paths.twingate;
                    buffer[count + 1] = "-d";
                    count += 2;
                },
            }

            for (request.words()) |word| {
                buffer[count] = word;
                count += 1;
            }

            switch (request) {
                .authenticate, .switch_account => |value| {
                    buffer[count] = value;
                    count += 1;
                },
                .accounts, .connect, .desktop_start, .desktop_stop, .disconnect => {},
                .inventory, .journal, .resources, .service_stop, .status => {},
            }

            assert(count <= argument_count_max);
            assert(count >= 2);

            return buffer[0..count];
        }
    };

    pub const Request = union(enum) {
        accounts,
        authenticate: []const u8,
        connect,
        desktop_start,
        desktop_stop,
        disconnect,
        inventory,
        journal,
        resources,
        service_stop,
        status,
        switch_account: []const u8,

        const Binary = enum {
            journalctl,
            notifier,
            twingate,
        };

        pub fn is_confirmed(request: Request) bool {
            if (request == .switch_account) assert(is_account(request.switch_account));

            return switch (request) {
                .switch_account => true,
                .accounts, .authenticate, .connect, .desktop_start, .desktop_stop => false,
                .disconnect, .inventory, .journal, .resources, .service_stop, .status => false,
            };
        }

        pub fn is_privileged(request: Request) bool {
            if (request == .switch_account) assert(is_account(request.switch_account));

            return switch (request) {
                .connect, .service_stop, .switch_account => true,
                .accounts, .authenticate, .desktop_start, .desktop_stop, .disconnect => false,
                .inventory, .journal, .resources, .status => false,
            };
        }

        pub fn is_query(request: Request) bool {
            if (request == .switch_account) assert(is_account(request.switch_account));

            return switch (request) {
                .accounts, .inventory, .journal, .resources, .status => true,
                .authenticate, .connect, .desktop_start, .desktop_stop => false,
                .disconnect, .service_stop, .switch_account => false,
            };
        }

        fn binary(request: Request) Binary {
            if (request == .switch_account) assert(is_account(request.switch_account));

            return switch (request) {
                .journal => .journalctl,
                .authenticate, .inventory => .notifier,
                .accounts, .connect, .desktop_start, .desktop_stop, .disconnect => .twingate,
                .resources, .service_stop, .status, .switch_account => .twingate,
            };
        }

        fn program(request: Request) []const u8 {
            if (request == .switch_account) assert(is_account(request.switch_account));

            return switch (request.binary()) {
                .journalctl => "journalctl",
                .notifier, .twingate => "Twingate",
            };
        }

        fn timeout_seconds(request: Request) i64 {
            if (request == .switch_account) assert(is_account(request.switch_account));

            if (request == .authenticate) return timeout_authenticate_seconds;
            if (request.is_privileged()) return timeout_privileged_seconds;

            return timeout_unprivileged_seconds;
        }

        fn words(request: Request) []const []const u8 {
            if (request == .switch_account) assert(is_account(request.switch_account));

            return switch (request) {
                .accounts => &.{ "account", "list" },
                .authenticate => &.{"auth"},
                .connect => &.{"connect"},
                .desktop_start => &.{"desktop-start"},
                .desktop_stop => &.{"desktop-stop"},
                .disconnect => &.{"disconnect"},
                .inventory => &.{"resources"},
                .journal => &journal_flags,
                .resources => &.{"resources"},
                .service_stop => &.{"service-stop"},
                .status => &.{"status"},
                .switch_account => &.{ "account", "switch" },
            };
        }
    };

    pub const Result = struct {
        outcome: Outcome,
        text: []const u8,

        pub const Outcome = enum {
            denied,
            failed,
            missing,
            succeeded,
            timed_out,
        };
    };

    pub const account_bytes_max: u32 = 254;
    pub const argument_count_max: u32 = 7;
    pub const journal_bytes_max: u32 = 32 * 1024;
    pub const output_bytes_max: u32 = 64 * 1024;
    pub const resource_bytes_max: u32 = 255;
    pub const scratch_bytes_max: u32 = 4 * output_bytes_max;

    pub fn init(
        twingate: *Twingate,
        gpa: Allocator,
        io: std.Io,
        paths: *const Paths,
        parent: *const Environ.Map,
    ) Allocator.Error!void {
        assert(paths.journalctl.len > 0);
        assert(paths.notifier.len > 0);
        assert(paths.pkexec.len > 0);
        assert(paths.twingate.len > 0);

        var quiet = try parent.clone(gpa);
        errdefer quiet.deinit();

        try quiet.put(log_level_key, log_level_off);

        assert(quiet.count() >= parent.count());
        assert(quiet.count() <= parent.count() + 1);

        twingate.* = .{
            .io = io,
            .output = undefined,
            .paths = paths.*,
            .quiet = quiet,
            .scratch = undefined,
        };

        assert(twingate.paths.journalctl.len == paths.journalctl.len);
        assert(twingate.paths.notifier.len == paths.notifier.len);
        assert(twingate.paths.pkexec.len == paths.pkexec.len);
        assert(twingate.paths.twingate.len == paths.twingate.len);
    }

    pub fn deinit(twingate: *Twingate) void {
        assert(std.mem.eql(u8, twingate.quiet.get(log_level_key) orelse "", log_level_off));
        assert(twingate.paths.twingate.len > 0);

        twingate.quiet.deinit();
    }

    pub fn is_account(text: []const u8) bool {
        if (text.len == 0) return false;
        if (text.len > account_bytes_max) return false;

        for (text) |byte| {
            if (std.ascii.isAlphanumeric(byte)) continue;
            if (std.mem.findScalar(u8, account_punctuation, byte) != null) continue;

            return false;
        }

        return true;
    }

    pub fn is_resource(text: []const u8) bool {
        if (text.len == 0) return false;
        if (text.len > resource_bytes_max) return false;
        if (text[0] == '-') return false;
        if (!std.unicode.utf8ValidateSlice(text)) return false;

        for (text) |byte| {
            if (std.ascii.isControl(byte)) return false;
        }

        return true;
    }

    pub fn run(twingate: *Twingate, request: Request) std.Io.Cancelable!Result {
        assert(std.mem.eql(u8, twingate.quiet.get(log_level_key) orelse "", log_level_off));
        if (request == .authenticate) assert(is_resource(request.authenticate));
        if (request == .switch_account) assert(is_account(request.switch_account));

        var allocator = std.heap.FixedBufferAllocator.init(&twingate.scratch);

        const program = request.program();
        const spawned = if (request.is_privileged()) "pkexec" else program;

        const ran = twingate.run_child(allocator.allocator(), request) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            error.FileNotFound => {
                return twingate.report(.missing, "{s} is not installed.", .{spawned});
            },
            error.Timeout => return twingate.report(.timed_out, "{s} did not answer.", .{program}),
            else => return twingate.report(.failed, "{s} could not run: {t}.", .{ program, err }),
        };

        return twingate.classify(request, &ran);
    }

    fn classify(twingate: *Twingate, request: Request, ran: *const std.process.RunResult) Result {
        if (request == .switch_account) assert(is_account(request.switch_account));
        assert(ran.stdout.len <= output_bytes_max);
        assert(ran.stderr.len <= output_bytes_max);

        const program = request.program();

        if (request == .journal) {
            const entries = std.mem.trim(u8, ran.stdout, " \t\r\n");
            if (entries.len > 0) return twingate.report(.succeeded, "{s}", .{entries});
        }

        const code = switch (ran.term) {
            .exited => |value| value,
            .signal, .stopped, .unknown => {
                return twingate.report(.failed, "{s} stopped unexpectedly.", .{program});
            },
        };

        const text = summary(ran);

        if (code == 0) return twingate.report(.succeeded, "{s}", .{answered(request, text)});

        if (request.is_privileged()) {
            if (code == exit_dismissed) {
                return twingate.report(.denied, "The password prompt was dismissed.", .{});
            }

            if (code == exit_unauthorized) {
                return twingate.report(.denied, "This account may not control Twingate.", .{});
            }
        }

        if (text.len == 0) {
            return twingate.report(.failed, "{s} exited with code {d}.", .{ program, code });
        }

        return twingate.report(.failed, "{s}", .{text});
    }

    fn report(
        twingate: *Twingate,
        outcome: Result.Outcome,
        comptime format: []const u8,
        values: anytype,
    ) Result {
        comptime assert(format.len > 0);
        comptime assert(@typeInfo(@TypeOf(values)) == .@"struct");

        const text = std.mem.print(&twingate.output, format, values) catch &twingate.output;
        const trimmed = std.mem.trim(u8, text, " \t\r\n");

        assert(trimmed.len <= output_bytes_max);

        return .{ .outcome = outcome, .text = trimmed };
    }

    fn run_child(
        twingate: *Twingate,
        gpa: Allocator,
        request: Request,
    ) !std.process.RunResult {
        if (request == .switch_account) assert(is_account(request.switch_account));

        var buffer: [argument_count_max][]const u8 = undefined;
        const io = twingate.io;
        const seconds = request.timeout_seconds();

        const limit: Limit = if (request == .journal)
            .{ .bytes = journal_bytes_max, .overflow = .cut }
        else
            .{ .bytes = output_bytes_max, .overflow = .fail };

        var child = try std.process.spawn(io, .{
            .argv = twingate.paths.arguments(request, &buffer),
            .environ_map = if (request.is_query()) &twingate.quiet else null,
            .stderr = .pipe,
            .stdin = if (request.is_confirmed()) .pipe else .ignore,
            .stdout = .pipe,
        });

        defer child.kill(io);

        if (child.stdin) |stdin| {
            defer stdin.close(io);

            child.stdin = null;

            stdin.writeStreamingAll(io, confirmation_answer) catch |err| switch (err) {
                error.BrokenPipe => {},
                else => |other| return other,
            };
        }

        assert(child.stdin == null);

        const timeout: std.Io.Timeout = .{
            .duration = .{ .clock = .awake, .raw = .fromSeconds(seconds) },
        };

        return collect(gpa, io, &child, timeout, limit);
    }
};

const Limit = struct {
    bytes: u32,
    overflow: Overflow,

    const Overflow = enum {
        cut,
        fail,
    };
};

const account_punctuation = "@._:+-";
const confirmation_answer = "y\n";
const confirmation_prompt = "[y/N]:";
const exit_dismissed: u8 = 126;
const exit_unauthorized: u8 = 127;
const fill_count_max: u32 = 2 * Twingate.output_bytes_max + 4;
const journal_line_count_max: u32 = 300;
const log_level_key = "LOG_LEVEL";
const log_level_off = "off";
const reserve_bytes: u32 = 64;
const timeout_authenticate_seconds: i64 = 3;
const timeout_privileged_seconds: i64 = 180;
const timeout_unprivileged_seconds: i64 = 20;

const journal_flags = [_][]const u8{
    "--unit=twingate.service",
    std.fmt.comptimePrint("--lines={d}", .{journal_line_count_max}),
    "--reverse",
    "--output=cat",
    "--no-pager",
};

comptime {
    assert(Twingate.scratch_bytes_max > 2 * Twingate.output_bytes_max);
    assert(Twingate.journal_bytes_max < Twingate.output_bytes_max);
    assert(journal_flags.len < Twingate.argument_count_max);
    assert(timeout_privileged_seconds > timeout_unprivileged_seconds);
    assert(timeout_unprivileged_seconds > timeout_authenticate_seconds);
    assert(std.mem.endsWith(u8, confirmation_answer, "\n"));
    assert(reserve_bytes < Twingate.output_bytes_max);
}

fn answered(request: Twingate.Request, text: []const u8) []const u8 {
    if (request == .switch_account) assert(Twingate.is_account(request.switch_account));
    assert(text.len <= Twingate.output_bytes_max);

    if (!request.is_confirmed()) return text;

    const start = std.mem.find(u8, text, confirmation_prompt) orelse return text;
    const rest = std.mem.trim(u8, text[start + confirmation_prompt.len ..], " \t\r\n");

    assert(rest.len < text.len);

    return rest;
}

fn collect(
    gpa: Allocator,
    io: std.Io,
    child: *std.process.Child,
    timeout: std.Io.Timeout,
    limit: Limit,
) !std.process.RunResult {
    assert(child.id != null);
    assert(child.stdin == null);
    assert(timeout != .none);
    assert(limit.bytes > 0);
    assert(limit.bytes <= Twingate.output_bytes_max);

    var streams: std.Io.File.MultiReader.Buffer(2) = undefined;
    var output: std.Io.File.MultiReader = undefined;

    output.init(gpa, io, streams.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer output.deinit();

    const deadline = timeout.toDeadline(io);
    const stdout_reader = output.reader(0);
    const stderr_reader = output.reader(1);

    var fill_count: u32 = 0;

    const cut = while (fill_count < fill_count_max) : (fill_count += 1) {
        output.fill(reserve_bytes, deadline) catch |err| switch (err) {
            error.EndOfStream => break false,
            else => |other| return other,
        };

        if (stderr_reader.bufferedLen() > Twingate.output_bytes_max) return error.StreamTooLong;
        if (stdout_reader.bufferedLen() <= limit.bytes) continue;
        if (limit.overflow == .fail) return error.StreamTooLong;

        break true;
    } else {
        return error.StreamTooLong;
    };

    if (cut) {
        output.batch.cancel(io);
        child.stdout.?.close(io);
        child.stderr.?.close(io);
        child.stdout = null;
        child.stderr = null;
    }

    try output.checkAnyError();

    const term = try child.wait(io);
    const stdout = try output.toOwnedSlice(0);
    const stderr = try output.toOwnedSlice(1);
    const kept = if (cut) whole_lines(stdout[0..limit.bytes]) else stdout;

    assert(kept.len <= limit.bytes);
    assert(stderr.len <= Twingate.output_bytes_max);

    return .{ .stderr = stderr, .stdout = stdout[0..kept.len], .term = term };
}

fn summary(ran: *const std.process.RunResult) []const u8 {
    assert(ran.stdout.len <= Twingate.output_bytes_max);
    assert(ran.stderr.len <= Twingate.output_bytes_max);

    const primary = std.mem.trim(u8, ran.stdout, " \t\r\n");
    if (primary.len > 0) return primary;

    return std.mem.trim(u8, ran.stderr, " \t\r\n");
}

fn whole_lines(bytes: []const u8) []const u8 {
    assert(bytes.len <= Twingate.output_bytes_max);

    const last = std.mem.findScalarLast(u8, bytes, '\n') orelse return bytes;
    const result = bytes[0 .. last + 1];

    assert(std.mem.endsWith(u8, result, "\n"));

    return result;
}

const testing = std.testing;

const switch_question =
    "This will switch to the account tester@example.com - Solopass Test (twingate.com). " ++
    "Are you sure? [y/N]: ";

const switch_unresolved =
    "Starting Twingate service\n" ++
    "Unable to resolve solopass-test.twingate.com: Please verify that your DNS and network " ++
    "configuration allows access to solopass-test.twingate.com. Do you want to try to " ++
    "connect anyway? [N/y]twingate service-start failed\n";

const journal_entries =
    "[2026-11-08T13:25:56.214696-0600] [INFO] [client] Connected to the network\n" ++
    "[2026-11-08T13:25:51.104112-0600] [INFO] [client] Connecting\n" ++
    "Started twingate.service - Twingate Client.\n";

const Fixture = struct {
    fake: Fake,
    twingate: Twingate,

    fn init(fixture: *Fixture, io: std.Io) !void {
        try fixture.fake.init(io);
        errdefer fixture.fake.deinit();

        const paths = fixture.fake.paths();

        try fixture.twingate.init(testing.allocator, io, &paths, &fixture.fake.environment);
    }

    fn deinit(fixture: *Fixture) void {
        fixture.twingate.deinit();
        fixture.fake.deinit();
    }
};

test Twingate {
    const io = testing.io;

    var fixture: Fixture = undefined;

    try fixture.init(io);
    defer fixture.deinit();

    try fixture.fake.write(io, .status, "online\n");

    const result = try fixture.twingate.run(.status);

    try testing.expectEqual(Twingate.Result.Outcome.succeeded, result.outcome);
    try testing.expectEqualStrings("online", result.text);
}

test "each request becomes the command line the cli expects" {
    var buffer: [Twingate.argument_count_max][]const u8 = undefined;

    const paths: Twingate.Paths = .system;

    const expected = [_]struct { request: Twingate.Request, line: []const u8 }{
        .{ .request = .accounts, .line = "/usr/bin/twingate -d account list" },
        .{
            .request = .{ .authenticate = "Lethbridge Compute Network" },
            .line = "/usr/bin/twingate-notifier auth Lethbridge Compute Network",
        },
        .{ .request = .connect, .line = "/usr/bin/pkexec /usr/bin/twingate -d connect" },
        .{ .request = .desktop_start, .line = "/usr/bin/twingate -d desktop-start" },
        .{ .request = .desktop_stop, .line = "/usr/bin/twingate -d desktop-stop" },
        .{ .request = .disconnect, .line = "/usr/bin/twingate -d disconnect" },
        .{ .request = .inventory, .line = "/usr/bin/twingate-notifier resources" },
        .{ .request = .resources, .line = "/usr/bin/twingate -d resources" },
        .{ .request = .service_stop, .line = "/usr/bin/pkexec /usr/bin/twingate -d service-stop" },
        .{ .request = .status, .line = "/usr/bin/twingate -d status" },
        .{
            .request = .{ .switch_account = "a@b.c" },
            .line = "/usr/bin/pkexec /usr/bin/twingate -d account switch a@b.c",
        },
        .{
            .request = .journal,
            .line = "/usr/bin/journalctl --unit=twingate.service --lines=300 --reverse " ++
                "--output=cat --no-pager",
        },
    };

    for (expected) |entry| {
        var joined: [256]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&joined);

        for (paths.arguments(entry.request, &buffer), 0..) |argument, index| {
            if (index > 0) try writer.writeByte(' ');

            try writer.writeAll(argument);
        }

        try testing.expectEqualStrings(entry.line, writer.buffered());
    }
}

test "a successful query returns its trimmed output" {
    const io = testing.io;

    var fixture: Fixture = undefined;

    try fixture.init(io);
    defer fixture.deinit();

    try fixture.fake.write(io, .status, "  online\n\n");

    const result = try fixture.twingate.run(.status);

    try testing.expectEqual(Twingate.Result.Outcome.succeeded, result.outcome);
    try testing.expectEqualStrings("online", result.text);
}

test "a failing command reports what it printed to stderr" {
    const io = testing.io;

    var fixture: Fixture = undefined;

    try fixture.init(io);
    defer fixture.deinit();

    try fixture.fake.write(io, .fail, "");

    const result = try fixture.twingate.run(.disconnect);

    try testing.expectEqual(Twingate.Result.Outcome.failed, result.outcome);
    try testing.expectEqualStrings("Twingate refused", result.text);
}

test "a dismissed password prompt is a denial rather than a failure" {
    const io = testing.io;

    var fixture: Fixture = undefined;

    try fixture.init(io);
    defer fixture.deinit();

    try fixture.fake.write(io, .deny, "");

    const result = try fixture.twingate.run(.connect);

    try testing.expectEqual(Twingate.Result.Outcome.denied, result.outcome);
    try testing.expectEqualStrings("The password prompt was dismissed.", result.text);
}

test "a missing binary is reported as missing" {
    const io = testing.io;

    var twingate: Twingate = undefined;
    var parent: Environ.Map = .init(testing.allocator);
    defer parent.deinit();

    const paths: Twingate.Paths = .{
        .journalctl = "/nonexistent/journalctl",
        .notifier = "/nonexistent/twingate-notifier",
        .pkexec = "/nonexistent/pkexec",
        .twingate = "/nonexistent/twingate",
    };

    try twingate.init(testing.allocator, io, &paths, &parent);
    defer twingate.deinit();

    const result = try twingate.run(.status);

    try testing.expectEqual(Twingate.Result.Outcome.missing, result.outcome);
    try testing.expectEqualStrings("Twingate is not installed.", result.text);

    const inventory = try twingate.run(.inventory);

    try testing.expectEqual(Twingate.Result.Outcome.missing, inventory.outcome);
    try testing.expectEqualStrings("Twingate is not installed.", inventory.text);

    const privileged = try twingate.run(.connect);

    try testing.expectEqual(Twingate.Result.Outcome.missing, privileged.outcome);
    try testing.expectEqualStrings("pkexec is not installed.", privileged.text);

    const journal = try twingate.run(.journal);

    try testing.expectEqual(Twingate.Result.Outcome.missing, journal.outcome);
    try testing.expectEqualStrings("journalctl is not installed.", journal.text);
}

test "the quiet environment turns the notifier log off and keeps the rest" {
    const paths: Twingate.Paths = .system;

    var twingate: Twingate = undefined;
    var parent: Environ.Map = .init(testing.allocator);
    defer parent.deinit();

    try parent.put("LOG_LEVEL", "info");
    try parent.put("XDG_RUNTIME_DIR", "/run/user/1000");

    try twingate.init(testing.allocator, testing.io, &paths, &parent);
    defer twingate.deinit();

    const quiet = &twingate.quiet;

    try testing.expectEqual(parent.count(), quiet.count());
    try testing.expectEqualStrings("off", quiet.get("LOG_LEVEL") orelse "");
    try testing.expectEqualStrings("/run/user/1000", quiet.get("XDG_RUNTIME_DIR") orelse "");
    try testing.expectEqualStrings("info", parent.get("LOG_LEVEL") orelse "");
}

test "a query runs with the notifier log off and a command inherits solopass's" {
    const io = testing.io;

    var fixture: Fixture = undefined;

    try fixture.init(io);
    defer fixture.deinit();

    const query = try fixture.twingate.run(.status);
    const command = try fixture.twingate.run(.disconnect);
    const inventory = try fixture.twingate.run(.inventory);

    var expected_buffer: [128]u8 = undefined;
    var levels_buffer: [128]u8 = undefined;

    const inherited = testing.environ.getPosix("LOG_LEVEL") orelse "unset";
    const format = "-d status off\n-d disconnect {s}\nresources off\n";
    const expected = try std.mem.print(&expected_buffer, format, .{inherited});
    const levels = try fixture.fake.read(io, .levels, &levels_buffer);

    try testing.expectEqual(Twingate.Result.Outcome.succeeded, query.outcome);
    try testing.expectEqual(Twingate.Result.Outcome.succeeded, command.outcome);
    try testing.expectEqual(Twingate.Result.Outcome.succeeded, inventory.outcome);
    try testing.expectEqualStrings(expected, levels);
}

test "a sign-in left waiting on the browser is ended at its cap, not after the full timeout" {
    const io = testing.io;

    var fixture: Fixture = undefined;

    try fixture.init(io);
    defer fixture.deinit();

    try fixture.fake.write(io, .hang, "");

    const request: Twingate.Request = .{ .authenticate = "Lethbridge Compute Network" };
    const cap_ms = timeout_authenticate_seconds * std.time.ms_per_s;
    const truncation_ms: i64 = 2;
    const before_ms = std.Io.Clock.awake.now(io).toMilliseconds();
    const result = try fixture.twingate.run(request);
    const after_ms = std.Io.Clock.awake.now(io).toMilliseconds();
    const elapsed_ms = after_ms - before_ms;

    try testing.expectEqual(Twingate.Result.Outcome.timed_out, result.outcome);
    try testing.expect(elapsed_ms >= cap_ms - truncation_ms);
    try testing.expect(elapsed_ms < timeout_unprivileged_seconds * std.time.ms_per_s);
}

test "a sign-in for a resource the service does not know fails with what the notifier said" {
    const io = testing.io;

    var fixture: Fixture = undefined;

    try fixture.init(io);
    defer fixture.deinit();

    try fixture.fake.write(io, .fail, "");

    const result = try fixture.twingate.run(.{ .authenticate = "Gone" });

    try testing.expectEqual(Twingate.Result.Outcome.failed, result.outcome);
    try testing.expectEqualStrings("Twingate refused", result.text);
}

test "an account switch answers the cli's question and reports what followed it" {
    const io = testing.io;

    var fixture: Fixture = undefined;

    try fixture.init(io);
    defer fixture.deinit();

    const switched = try fixture.twingate.run(.{ .switch_account = "avery.quinn@example.com" });

    try testing.expectEqual(Twingate.Result.Outcome.succeeded, switched.outcome);
    try testing.expectEqualStrings("Starting Twingate service", switched.text);

    const queried = try fixture.twingate.run(.status);

    try testing.expectEqual(Twingate.Result.Outcome.succeeded, queried.outcome);
    try testing.expectEqualStrings("offline", queried.text);
}

test "the answered question leaves a switch only when the cli succeeded" {
    var twingate: Twingate = undefined;

    const switch_request: Twingate.Request = .{ .switch_account = "tester@example.com" };
    const started = switch_question ++ "Starting Twingate service\n";
    const unresolved = switch_question ++ switch_unresolved;

    const cases = [_]struct {
        code: u8,
        expected: []const u8,
        output: []const u8,
        request: Twingate.Request,
    }{
        .{
            .code = 0,
            .expected = "Starting Twingate service",
            .output = started,
            .request = switch_request,
        },
        .{
            .code = 1,
            .expected = std.mem.trimEnd(u8, unresolved, "\n"),
            .output = unresolved,
            .request = switch_request,
        },
        .{
            .code = 0,
            .expected = std.mem.trimEnd(u8, started, "\n"),
            .output = started,
            .request = .disconnect,
        },
        .{
            .code = 0,
            .expected = "Done",
            .output = "Done\n",
            .request = switch_request,
        },
    };

    for (cases) |case| {
        var stdout: [512]u8 = undefined;

        @memcpy(stdout[0..case.output.len], case.output);

        const ran: std.process.RunResult = .{
            .stderr = stdout[0..0],
            .stdout = stdout[0..case.output.len],
            .term = .{ .exited = case.code },
        };

        const result = twingate.classify(case.request, &ran);

        try testing.expectEqualStrings(case.expected, result.text);
    }
}

test "an account name admits only the polkit rule charset" {
    try testing.expect(Twingate.is_account("avery.quinn@example.com"));
    try testing.expect(Twingate.is_account("user+tag@example.com:tenant-1"));
    try testing.expect(!Twingate.is_account(""));
    try testing.expect(!Twingate.is_account("a b"));
    try testing.expect(!Twingate.is_account("a;rm"));
    try testing.expect(!Twingate.is_account("--help\n"));

    const long: [Twingate.account_bytes_max + 1]u8 = @splat('a');

    try testing.expect(!Twingate.is_account(&long));
}

test "a resource name admits printable text the cli cannot mistake for an option" {
    try testing.expect(Twingate.is_resource("Lethbridge Compute Network"));
    try testing.expect(Twingate.is_resource("build-cache"));
    try testing.expect(!Twingate.is_resource("--help"));
    try testing.expect(!Twingate.is_resource("-h"));
    try testing.expect(Twingate.is_resource("caf\xC3\xA9"));
    try testing.expect(!Twingate.is_resource(""));
    try testing.expect(!Twingate.is_resource("a\nb"));
    try testing.expect(!Twingate.is_resource("a\x00b"));
    try testing.expect(!Twingate.is_resource("\xC3\x28"));

    const longest: [Twingate.resource_bytes_max]u8 = @splat('a');
    const long: [Twingate.resource_bytes_max + 1]u8 = @splat('a');

    try testing.expect(Twingate.is_resource(&longest));
    try testing.expect(!Twingate.is_resource(&long));
}

test "a journal read returns what journalctl printed for the twingate service" {
    const io = testing.io;

    var fixture: Fixture = undefined;
    var calls_buffer: [256]u8 = undefined;

    try fixture.init(io);
    defer fixture.deinit();

    try fixture.fake.write(io, .journal, journal_entries);

    const result = try fixture.twingate.run(.journal);
    const calls = try fixture.fake.read(io, .calls, &calls_buffer);

    const call =
        "journalctl --unit=twingate.service --lines=300 --reverse --output=cat --no-pager\n";

    try testing.expectEqual(Twingate.Result.Outcome.succeeded, result.outcome);
    try testing.expectEqualStrings(std.mem.trimEnd(u8, journal_entries, "\n"), result.text);
    try testing.expectEqualStrings(call, calls);
}

test "a journal read longer than its bound keeps the newest whole entries and ends journalctl" {
    const io = testing.io;
    const format = "[2026-11-08T13:25:56.000000-0600] [INFO] [client] entry {d:0>6}\n";

    var fixture: Fixture = undefined;
    var content_buffer: [Twingate.output_bytes_max]u8 = undefined;
    var content_writer: std.Io.Writer = .fixed(&content_buffer);
    var entry: u32 = 700;

    try fixture.init(io);
    defer fixture.deinit();

    while (entry > 0) : (entry -= 1) {
        try content_writer.print(format, .{entry});
    }

    const content = content_writer.buffered();

    try testing.expect(content.len > Twingate.journal_bytes_max);

    try fixture.fake.write(io, .journal, content);
    try fixture.fake.write(io, .journal_repeat, "8\n");

    const before_ms = std.Io.Clock.awake.now(io).toMilliseconds();
    const result = try fixture.twingate.run(.journal);
    const after_ms = std.Io.Clock.awake.now(io).toMilliseconds();
    const text = result.text;

    try testing.expect(after_ms - before_ms < 5 * std.time.ms_per_s);
    try testing.expectEqual(Twingate.Result.Outcome.succeeded, result.outcome);
    try testing.expect(text.len > 0);
    try testing.expect(text.len < Twingate.journal_bytes_max);
    try testing.expect(std.mem.startsWith(u8, content, text));
    try testing.expectEqual(@as(u8, '\n'), content[text.len]);

    const end_next = std.mem.findScalarPos(u8, content, text.len + 1, '\n') orelse content.len;

    try testing.expect(end_next + 1 > Twingate.journal_bytes_max);
}

test "a journal read that fails reports what journalctl printed to stderr" {
    const io = testing.io;

    var fixture: Fixture = undefined;

    try fixture.init(io);
    defer fixture.deinit();

    try fixture.fake.write(io, .journal, journal_entries);
    try fixture.fake.write(io, .fail, "");

    const result = try fixture.twingate.run(.journal);

    try testing.expectEqual(Twingate.Result.Outcome.failed, result.outcome);
    try testing.expectEqualStrings("journalctl refused", result.text);
}

test "a child that keeps writing is stopped at the deadline rather than after each read" {
    const io = testing.io;

    var scratch: [Twingate.scratch_bytes_max]u8 = undefined;
    var allocator = std.heap.FixedBufferAllocator.init(&scratch);

    var child = try std.process.spawn(io, .{
        .argv = &.{ "/bin/sh", "-c", "while :; do echo tick; sleep 0.05; done" },
        .stderr = .pipe,
        .stdin = .ignore,
        .stdout = .pipe,
    });

    defer child.kill(io);

    const timeout_ms: i64 = 400;
    const truncation_ms: i64 = 2;

    const timeout: std.Io.Timeout = .{
        .duration = .{ .clock = .awake, .raw = .fromMilliseconds(timeout_ms) },
    };

    const limit: Limit = .{ .bytes = Twingate.output_bytes_max, .overflow = .fail };
    const before_ms = std.Io.Clock.awake.now(io).toMilliseconds();
    const result = collect(allocator.allocator(), io, &child, timeout, limit);
    const after_ms = std.Io.Clock.awake.now(io).toMilliseconds();
    const elapsed_ms = after_ms - before_ms;

    try testing.expectError(error.Timeout, result);
    try testing.expect(elapsed_ms >= timeout_ms - truncation_ms);
    try testing.expect(elapsed_ms < 2 * std.time.ms_per_s);
}

test "whole lines end at the last newline and keep everything before it" {
    const text = "first entry\nsecond\n\nfourth entry";

    for (0..text.len + 1) |length| {
        const bytes = text[0..length];
        const kept = whole_lines(bytes);
        const rest = bytes[kept.len..];

        try testing.expect(std.mem.startsWith(u8, bytes, kept));
        try testing.expect(std.mem.findScalar(u8, rest, '\n') == null);

        if (std.mem.findScalar(u8, bytes, '\n') == null) {
            try testing.expectEqualStrings(bytes, kept);
        } else {
            try testing.expect(std.mem.endsWith(u8, kept, "\n"));
        }
    }
}
