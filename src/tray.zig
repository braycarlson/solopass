const std = @import("std");

const umbra = @import("umbra");

const Action = @import("action.zig").Action;
const Elapsed = @import("elapsed.zig").Elapsed;
const Session = @import("session.zig").Session;
const Snapshot = @import("snapshot.zig").Snapshot;
const Status = @import("status.zig").Status;
const Table = @import("table.zig").Table;
const TextType = @import("text.zig").TextType;
const Twingate = @import("twingate.zig").Twingate;

const assert = std.debug.assert;
const log = std.log.scoped(.tray);

const Kind = umbra.Notifier.Notification.Kind;
const Menu = umbra.Menu;
const Notification = umbra.Notifier.Notification;
const Pixmap = umbra.Icon.Pixmap;

const Item = enum(u32) {
    open = 4,
    quit = 5,
    sign_in = 6,
    status = 1,
    stop = 3,
    toggle = 2,
    _,
};

const ItemOptions = struct {
    enabled: bool,
};

const Body = TextType(umbra.limits.notification_body_bytes_max);
const Label = TextType(label_bytes_max);

const account_count_max: u32 = 8;
const account_item_base: u32 = 100;
const account_label_bytes_max: u32 = 288;
const absent_ticks_max: u32 = 20;
const connected_prefix = "Connected for ";
const icon_busy = "busy";
const icon_connected = "connected";
const icon_idle = "disconnected";
const label_bytes_max: u32 = 64;
const pixmap_dimension: u32 = 32;
const switch_prefix = "Switch to ";
const synchronize_interval_ms: u32 = 500;
const synchronize_timer_id: u32 = 1;
const tooltip_prefix = "Solopass: ";
const busy = Pixmap.from_rgba(@embedFile("busy.rgba"), pixmap_dimension);
const connected = Pixmap.from_rgba(@embedFile("connected.rgba"), pixmap_dimension);
const disconnected = Pixmap.from_rgba(@embedFile("disconnected.rgba"), pixmap_dimension);

const host_functions = [_][]const u8{
    "fail",
    "is_stopping",
    "is_visible",
    "quit",
    "show",
    "sign_in",
};

const notification_connected: Notification = .{
    .body = "Twingate is connected.",
    .kind = .info,
    .silent = false,
    .title = "Connected",
};

const notification_disconnected: Notification = .{
    .body = "Twingate is no longer connected.",
    .kind = .warning,
    .silent = false,
    .title = "Disconnected",
};

const notification_sign_in: Notification = .{
    .body = "Choose Sign in from the Solopass menu to finish connecting.",
    .kind = .info,
    .silent = false,
    .title = "Sign in to Twingate",
};

comptime {
    assert(busy.height == pixmap_dimension);
    assert(connected.height == pixmap_dimension);
    assert(disconnected.height == pixmap_dimension);
    assert(account_item_base > @backingInt(Item.sign_in));
    assert(account_item_base + account_count_max <= umbra.limits.menu_item_id_max);
    assert(connected_prefix.len + Elapsed.bytes_max <= label_bytes_max);
    assert(label_bytes_max <= umbra.limits.menu_label_bytes_max);
    assert(tooltip_prefix.len + label_bytes_max <= umbra.limits.tooltip_bytes_max);
    assert(switch_prefix.len + Twingate.account_bytes_max <= account_label_bytes_max);
    assert(synchronize_interval_ms * absent_ticks_max == 10 * std.time.ms_per_s);
}

pub fn TrayType(comptime Host: type) type {
    comptime {
        for (host_functions) |name| {
            if (!@hasDecl(Host, name)) {
                @compileError(@typeName(Host) ++ " has no pub fn " ++ name ++ " for the tray");
            }
        }
    }

    return struct {
        absent_ticks: u32,
        app: umbra.App,
        host: *Host,
        io: std.Io,
        label: Label,
        session: *Session,
        snapshot: Snapshot,

        const Tray = @This();

        const Previous = struct {
            message_generation: u64,
            observed: bool,
            signing: bool,
            status: Status,
        };

        pub fn main(tray: *Tray, io: std.Io, session: *Session, host: *Host) void {
            tray.init(io, session, host) catch |err| {
                log.err("the tray could not start: {t}", .{err});
                host.fail();

                return;
            };

            defer tray.deinit();

            tray.app.run() catch |err| {
                log.err("the tray stopped: {t}", .{err});
            };

            if (!host.is_stopping()) host.fail();
        }

        pub fn init(tray: *Tray, io: std.Io, session: *Session, host: *Host) umbra.Error!void {
            tray.absent_ticks = 0;
            tray.host = host;
            tray.io = io;
            tray.label = .empty;
            tray.session = session;
            tray.snapshot = .initial;

            try tray.app.init(.{ .name = "Solopass", .tooltip = "Solopass" });
            errdefer tray.app.deinit();

            _ = try umbra.IconBuilder.init(&tray.app.icons)
                .pixels(icon_busy, busy)
                .pixels(icon_connected, connected)
                .pixels(icon_idle, disconnected)
                .done();

            try tray.app.icons.set_current(icon_busy);
            try fill(&tray.app.menu, &tray.snapshot, "Checking Twingate");
            try tray.app.bus.attach(Tray, tray);

            assert(!tray.app.is_running());
            assert(tray.snapshot.generation == 0);
        }

        pub fn deinit(tray: *Tray) void {
            tray.app.deinit();

            assert(!tray.app.is_running());
        }

        pub fn on_app_init(tray: *Tray) void {
            assert(tray.snapshot.generation == 0);

            const timer: umbra.TimerSet.Timer = .{
                .id = synchronize_timer_id,
                .interval_ms = synchronize_interval_ms,
            };

            tray.app.timers.start(timer) catch |err| {
                log.err("the tray cannot follow the session: {t}", .{err});
                tray.app.quit();

                return;
            };

            assert(tray.app.timers.is_running(synchronize_timer_id));

            tray.synchronize();
        }

        pub fn on_menu_select(tray: *Tray, selection: umbra.Event.Selection) void {
            assert(selection.id > 0);

            if (selection.id >= account_item_base) {
                const index = selection.id - account_item_base;

                if (index < account_count_max) {
                    tray.switch_account(index);
                } else {
                    log.warn("the menu sent an unknown account item {d}", .{selection.id});
                }

                return;
            }

            switch (@as(Item, @fromBackingInt(selection.id))) {
                .open => tray.host.show(tray.io, tray.app.tray.get_activation_token()),
                .quit => tray.host.quit(),
                .sign_in => tray.host.sign_in(),
                .status => {},
                .stop => tray.submit(.stop, ""),
                .toggle => tray.submit(Action.toggle(tray.snapshot.status), ""),
                _ => log.warn("the menu sent an unknown item {d}", .{selection.id}),
            }
        }

        pub fn on_timer_tick(tray: *Tray, tick: umbra.Event.Tick) void {
            assert(tick.id == synchronize_timer_id);
            assert(tick.tick_count > 0);

            if (tray.host.is_stopping()) {
                tray.app.quit();

                return;
            }

            tray.watch_presence();
            tray.synchronize();
        }

        pub fn on_tray_left_click(tray: *Tray) void {
            assert(tray.absent_ticks <= absent_ticks_max);

            tray.host.show(tray.io, tray.app.tray.get_activation_token());
        }

        fn announce(tray: *Tray, previous: *const Previous) void {
            assert(tray.snapshot.generation > 0);

            if (tray.host.is_visible()) return;

            const snapshot = &tray.snapshot;
            const connected_before = previous.status == .online and !previous.signing;
            const connected_started = snapshot.is_connected() and !connected_before;
            const dropped = previous.status == .online and snapshot.status != .online;
            const spoke = snapshot.message.generation != previous.message_generation;
            const sign_in_started = snapshot.needs_sign_in() and !previous.signing;

            if (spoke) assert(snapshot.message.generation > previous.message_generation);
            if (dropped) assert(previous.observed);

            if (connected_started) {
                if (previous.observed) tray.notify(&notification_connected);
            }

            if (dropped) tray.notify(&notification_disconnected);
            if (sign_in_started) tray.notify(&notification_sign_in);
            if (spoke) tray.announce_message();
        }

        fn announce_message(tray: *Tray) void {
            assert(tray.snapshot.message.generation > 0);

            const message = tray.snapshot.message.text.slice();
            if (message.len == 0) return;

            assert(message.len <= Snapshot.message_bytes_max);

            const kind: Kind = switch (tray.snapshot.message.kind) {
                .failure => .err,
                .information => .info,
            };

            const notification: Notification = .{
                .body = message,
                .kind = kind,
                .silent = false,
                .title = "Solopass",
            };

            tray.notify(&notification);
        }

        fn notify(tray: *Tray, notification: *const Notification) void {
            assert(notification.title.len > 0);
            assert(notification.title.len <= umbra.limits.notification_title_bytes_max);
            assert(notification.body.len > 0);

            var body: Body = .empty;

            body.set(notification.body);

            var shortened = notification.*;

            shortened.body = body.slice();

            tray.app.notifier.send(shortened) catch |err| {
                log.warn("the notification was not shown: {t}", .{err});
            };
        }

        fn present(tray: *Tray) void {
            const label = tray.label.slice();

            assert(label.len > 0);

            var buffer: [umbra.limits.tooltip_bytes_max]u8 = undefined;

            const tooltip = print(&buffer, tooltip_prefix ++ "{s}", .{label});

            assert(tooltip.len <= umbra.limits.tooltip_bytes_max);

            tray.app.icons.set_current(icon_name(&tray.snapshot)) catch |err| {
                log.warn("the tray icon did not change: {t}", .{err});
            };

            tray.app.tray.set_tooltip(tooltip) catch |err| {
                log.warn("the tooltip did not change: {t}", .{err});
            };

            fill(&tray.app.menu, &tray.snapshot, label) catch |err| {
                log.warn("the menu could not be filled: {t}", .{err});
            };

            tray.app.menu.build() catch |err| {
                log.warn("the menu could not be built: {t}", .{err});
            };
        }

        fn submit(tray: *Tray, action: Action, account: []const u8) void {
            assert(account.len <= Snapshot.accounts_bytes_max);
            if (action != .switch_account) assert(account.len == 0);

            if (tray.session.submit(tray.io, action, account)) return;

            log.info("{t} was refused while another command runs", .{action});
        }

        fn switch_account(tray: *Tray, index: u32) void {
            assert(index < account_count_max);

            const accounts: Table = .init(tray.snapshot.accounts.slice());
            const line = accounts.row(index) orelse return;

            assert(line.kind == .row);

            if (line.is_current()) return;

            tray.submit(.switch_account, line.cell(0));
        }

        fn synchronize(tray: *Tray) void {
            const previous: Previous = .{
                .message_generation = tray.snapshot.message.generation,
                .observed = tray.snapshot.observed,
                .signing = tray.snapshot.needs_sign_in(),
                .status = tray.snapshot.status,
            };

            const changed = tray.session.copy(tray.io, &tray.snapshot);
            const now_seconds = std.Io.Clock.boot.now(tray.io).toSeconds();

            var buffer: [label_bytes_max]u8 = undefined;

            const label = status_line(&buffer, &tray.snapshot, now_seconds);
            const stale = changed or !std.mem.eql(u8, label, tray.label.slice());

            assert(label.len > 0);
            assert(label.len <= label_bytes_max);

            if (changed) tray.announce(&previous);
            if (!stale) return;

            tray.label.set(label);

            assert(std.mem.eql(u8, tray.label.slice(), label));

            tray.present();
        }

        fn watch_presence(tray: *Tray) void {
            assert(tray.absent_ticks <= absent_ticks_max);
            defer assert(tray.absent_ticks <= absent_ticks_max);

            if (tray.app.tray.is_created()) {
                tray.absent_ticks = 0;

                return;
            }

            if (tray.absent_ticks == absent_ticks_max) return;

            tray.absent_ticks += 1;
            if (tray.absent_ticks == absent_ticks_max) tray.host.fail();
        }
    };
}

fn fill(menu: *Menu, snapshot: *const Snapshot, label: []const u8) umbra.CapacityError!void {
    assert(label.len > 0);
    assert(label.len <= label_bytes_max);

    const idle = snapshot.pending == null;

    menu.clear();

    try menu.add(item(@backingInt(Item.status), label, .{ .enabled = false }));
    try menu.add(.separator());

    if (snapshot.needs_sign_in()) {
        try menu.add(item(@backingInt(Item.sign_in), "Sign in\u{2026}", .{ .enabled = idle }));
    }

    const stoppable = idle and snapshot.observed and snapshot.status.is_running();
    const toggle = Action.toggle(snapshot.status);

    try menu.add(item(@backingInt(Item.toggle), toggle.label(), .{ .enabled = idle }));
    try menu.add(item(@backingInt(Item.stop), Action.stop.label(), .{ .enabled = stoppable }));
    try fill_accounts(menu, snapshot);
    try menu.add(.separator());
    try menu.add(item(@backingInt(Item.open), "Open Solopass", .{ .enabled = true }));
    try menu.add(item(@backingInt(Item.quit), "Quit", .{ .enabled = true }));

    assert(!menu.is_empty());
}

fn fill_accounts(menu: *Menu, snapshot: *const Snapshot) umbra.CapacityError!void {
    assert(!menu.is_empty());

    const accounts: Table = .init(snapshot.accounts.slice());
    if (accounts.row_count() < 2) return;

    const options: ItemOptions = .{ .enabled = snapshot.pending == null };

    try menu.add(.separator());

    var lines = accounts.lines();
    var index: u32 = 0;

    for (0..lines.remaining) |_| {
        const line = lines.next() orelse break;
        if (line.kind != .row) continue;
        if (index == account_count_max) break;

        defer index += 1;

        if (line.is_current()) continue;

        const email = line.cell(0);
        if (!Twingate.is_account(email)) continue;

        var buffer: [account_label_bytes_max]u8 = undefined;

        const full = print(&buffer, switch_prefix ++ "{s}", .{email});
        const shown = full[0..@min(full.len, umbra.limits.menu_label_bytes_max)];

        try menu.add(item(account_item_base + index, shown, options));
    }

    assert(index <= account_count_max);
}

fn icon_name(snapshot: *const Snapshot) []const u8 {
    if (!snapshot.observed) assert(snapshot.status == .unknown);

    const result = switch (snapshot.tone()) {
        .busy => icon_busy,
        .connected => icon_connected,
        .idle, .unknown => icon_idle,
    };

    assert(result.len > 0);

    return result;
}

fn item(id: u32, label: []const u8, options: ItemOptions) Menu.Item {
    assert(id > 0);
    assert(id <= umbra.limits.menu_item_id_max);
    assert(label.len > 0);
    assert(label.len <= umbra.limits.menu_label_bytes_max);

    var result: Menu.Item = .action(id, label);

    result.enabled = options.enabled;

    return result;
}

fn print(buffer: []u8, comptime format: []const u8, arguments: anytype) []const u8 {
    comptime assert(format.len > 0);
    comptime assert(@typeInfo(@TypeOf(arguments)) == .@"struct");
    assert(buffer.len > 0);

    const result = std.mem.print(buffer, format, arguments) catch |err| switch (err) {
        error.NoSpaceLeft => unreachable,
    };

    assert(result.len <= buffer.len);

    return result;
}

fn status_line(
    buffer: *[label_bytes_max]u8,
    snapshot: *const Snapshot,
    now_seconds: i64,
) []const u8 {
    assert(now_seconds >= 0);

    if (snapshot.progress()) |progress| return progress;
    if (!snapshot.observed) return "Checking Twingate";

    const seconds = snapshot.connected_seconds(now_seconds) orelse return snapshot.label();
    const elapsed: Elapsed = .{ .seconds = seconds };

    return print(buffer, connected_prefix ++ "{f}", .{elapsed});
}

const testing = std.testing;

const TestHost = struct {
    failed: u32 = 0,
    quits: u32 = 0,
    shows: u32 = 0,
    sign_ins: u32 = 0,
    stopping: bool = false,
    token: [umbra.limits.activation_token_bytes_max]u8 = undefined,
    token_length: u32 = 0,
    visible: bool = false,

    pub fn fail(host: *TestHost) void {
        host.failed += 1;
    }

    pub fn is_stopping(host: *const TestHost) bool {
        return host.stopping;
    }

    pub fn is_visible(host: *const TestHost) bool {
        return host.visible;
    }

    pub fn quit(host: *TestHost) void {
        host.quits += 1;
    }

    pub fn show(host: *TestHost, _: std.Io, token: []const u8) void {
        assert(token.len <= umbra.limits.activation_token_bytes_max);

        @memcpy(host.token[0..token.len], token);

        host.shows += 1;
        host.token_length = @intCast(token.len);
    }

    fn token_seen(host: *const TestHost) []const u8 {
        return host.token[0..host.token_length];
    }

    pub fn sign_in(host: *TestHost) void {
        host.sign_ins += 1;
    }
};

const two_accounts =
    "EMAIL                  \tNETWORK   \tNETWORK URL\n" ++
    "avery.quinn@example.com\tExampleNet\texamplenet.twingate.com\n" ++
    "brayden@example.com\tExample\texample.twingate.com\n";

const account_marked =
    "EMAIL                  \tNETWORK      \tNETWORK URL               \t\n" ++
    "avery.quinn@example.com\tExampleNet   \texamplenet.twingate.com   \t\n" ++
    "tester@example.com     \tSolopass Test\tsolopass-test.twingate.com\t*\n";

const Fixture = struct {
    host: TestHost,
    session: Session,
    tray: TrayType(TestHost),

    fn init(fixture: *Fixture, io: std.Io) !void {
        umbra.mock.reset();
        fixture.host = .{};
        fixture.session.init();

        try umbra.mock.runtime.open(.{ .name = "solopass" });
        try fixture.tray.init(io, &fixture.session, &fixture.host);
    }

    fn deinit(fixture: *Fixture) void {
        fixture.tray.deinit();
    }

    fn enabled(fixture: *const Fixture, id: u32) bool {
        assert(id > 0);

        return fixture.tray.app.menu.get_item(id).?.enabled;
    }

    fn label(fixture: *const Fixture, id: u32) []const u8 {
        assert(id > 0);

        return fixture.tray.app.menu.get_item(id).?.get_label();
    }

    fn tick(fixture: *Fixture, count: u64) void {
        assert(count > 0);

        fixture.tray.on_timer_tick(.{ .id = synchronize_timer_id, .tick_count = count });
    }
};

test TrayType {
    const io = testing.io;

    var fixture: Fixture = undefined;

    try fixture.init(io);
    defer fixture.deinit();

    fixture.session.set_status(io, .online, "", 0);
    fixture.tray.on_app_init();

    try testing.expectEqualStrings("Connected", fixture.label(@backingInt(Item.status)));
    try testing.expectEqualStrings("Disconnect", fixture.label(@backingInt(Item.toggle)));
}

test "the menu offers to connect while the service is stopped" {
    const io = testing.io;

    var fixture: Fixture = undefined;

    try fixture.init(io);
    defer fixture.deinit();

    fixture.session.set_status(io, .stopped, "", 0);
    fixture.tray.on_app_init();

    try testing.expectEqualStrings("Not running", fixture.label(@backingInt(Item.status)));
    try testing.expectEqualStrings("Connect", fixture.label(@backingInt(Item.toggle)));
    try testing.expect(!fixture.enabled(@backingInt(Item.status)));
    try testing.expect(fixture.enabled(@backingInt(Item.toggle)));
    try testing.expect(!fixture.enabled(@backingInt(Item.stop)));
    try testing.expectEqualStrings("Solopass: Not running", fixture.tray.app.tray.get_tooltip());
    try testing.expectEqualStrings(icon_idle, fixture.tray.app.icons.get_current_name().?);
    try testing.expect(fixture.tray.app.menu.get_item(account_item_base) == null);
}

test "the toggle submits the action the menu showed" {
    const io = testing.io;

    var fixture: Fixture = undefined;

    try fixture.init(io);
    defer fixture.deinit();

    fixture.session.set_status(io, .online, "", 0);
    fixture.tray.on_app_init();

    try testing.expectEqualStrings("Disconnect", fixture.label(@backingInt(Item.toggle)));

    fixture.tray.on_menu_select(.{ .checked = false, .id = @backingInt(Item.toggle) });

    try testing.expectEqual(Action.disconnect, fixture.session.take(io).?.action);

    fixture.tick(1);

    const progress = fixture.label(@backingInt(Item.status));

    try testing.expectEqualStrings("Disconnecting\u{2026}", progress);
    try testing.expect(!fixture.enabled(@backingInt(Item.toggle)));
    try testing.expectEqualStrings(icon_busy, fixture.tray.app.icons.get_current_name().?);
}

test "each of two accounts becomes a switch item that names the account" {
    const io = testing.io;

    var fixture: Fixture = undefined;

    try fixture.init(io);
    defer fixture.deinit();

    fixture.session.set_status(io, .offline, "", 0);
    fixture.session.set_accounts(io, two_accounts);
    fixture.tray.on_app_init();

    const second = account_item_base + 1;

    try testing.expectEqualStrings("Switch to brayden@example.com", fixture.label(second));

    fixture.tray.on_menu_select(.{ .checked = false, .id = second });

    const command = fixture.session.take(io).?;

    try testing.expectEqual(Action.switch_account, command.action);
    try testing.expectEqualStrings("brayden@example.com", command.account.slice());
}

test "the menu offers no switch to the account in use" {
    const io = testing.io;

    var fixture: Fixture = undefined;

    try fixture.init(io);
    defer fixture.deinit();

    fixture.session.set_status(io, .offline, "", 0);
    fixture.session.set_accounts(io, account_marked);
    fixture.tray.on_app_init();

    const other = fixture.label(account_item_base);

    try testing.expectEqualStrings("Switch to avery.quinn@example.com", other);
    try testing.expect(fixture.tray.app.menu.get_item(account_item_base + 1) == null);

    fixture.tray.on_menu_select(.{ .checked = false, .id = account_item_base + 1 });

    try testing.expectEqual(@as(?Session.Command, null), fixture.session.take(io));

    fixture.tray.on_menu_select(.{ .checked = false, .id = account_item_base });

    const command = fixture.session.take(io).?;

    try testing.expectEqualStrings("avery.quinn@example.com", command.account.slice());
}

test "an account item past the menu's accounts submits nothing" {
    testing.log_level = .err;

    const io = testing.io;

    var fixture: Fixture = undefined;

    try fixture.init(io);
    defer fixture.deinit();

    fixture.session.set_accounts(io, two_accounts);
    fixture.tray.on_app_init();
    fixture.tray.on_menu_select(.{ .checked = false, .id = account_item_base + 2 });
    fixture.tray.on_menu_select(.{ .checked = false, .id = account_item_base + account_count_max });
    fixture.tray.on_menu_select(.{ .checked = false, .id = std.math.maxInt(i32) });

    try testing.expect(fixture.tray.app.menu.get_item(account_item_base + 1) != null);
    try testing.expect(fixture.tray.app.menu.get_item(account_item_base + 2) == null);
    try testing.expectEqual(@as(?Session.Command, null), fixture.session.take(io));
}

test "a hidden window learns of failures and transitions by notification" {
    const io = testing.io;

    var fixture: Fixture = undefined;

    try fixture.init(io);
    defer fixture.deinit();

    fixture.session.set_status(io, .offline, "", 0);
    fixture.tray.on_app_init();
    fixture.session.set_status(io, .online, "", 10);
    fixture.tick(1);
    fixture.session.set_message(io, .failure, "The password prompt was dismissed.");
    fixture.tick(2);

    const notes = umbra.mock.notification;

    try testing.expectEqual(@as(u32, 2), notes.recorded_count());
    try testing.expectEqualStrings("Connected", notes.title_at(0));
    try testing.expectEqualStrings("The password prompt was dismissed.", notes.body_at(1));
    try testing.expectEqual(@as(?Kind, .err), notes.kind_at(1));

    fixture.host.visible = true;
    fixture.session.set_status(io, .offline, "", 20);
    fixture.tick(3);

    try testing.expectEqual(@as(u32, 2), notes.recorded_count());
}

test "a sign-in adds a menu item for the host and tells a hidden window once" {
    const io = testing.io;
    const page = "https://login.example.com/authorize?state=abc";

    var fixture: Fixture = undefined;

    try fixture.init(io);
    defer fixture.deinit();

    fixture.session.set_status(io, .starting, "", 0);
    fixture.tray.on_app_init();

    try testing.expect(fixture.tray.app.menu.get_item(@backingInt(Item.sign_in)) == null);

    fixture.session.set_status(io, .authenticating, page, 1);
    fixture.tick(1);
    fixture.session.set_status(io, .authenticating, page ++ "&retry=1", 2);
    fixture.tick(2);

    const notes = umbra.mock.notification;

    try testing.expectEqualStrings("Sign in\u{2026}", fixture.label(@backingInt(Item.sign_in)));
    try testing.expect(fixture.enabled(@backingInt(Item.sign_in)));
    try testing.expectEqual(@as(u32, 1), notes.recorded_count());
    try testing.expectEqualStrings("Sign in to Twingate", notes.title_at(0));

    fixture.tray.on_menu_select(.{ .checked = false, .id = @backingInt(Item.sign_in) });

    try testing.expectEqual(@as(u32, 1), fixture.host.sign_ins);
    try testing.expectEqual(@as(?Session.Command, null), fixture.session.take(io));
}

test "a sign-in on a tunnel that is up shows signing in and announces connected only after it" {
    const io = testing.io;
    const page = "https://login.example.com/authorize?state=abc";

    var fixture: Fixture = undefined;

    try fixture.init(io);
    defer fixture.deinit();

    fixture.session.set_status(io, .offline, "", 0);
    fixture.tray.on_app_init();
    fixture.session.set_status(io, .online, page, 10);
    fixture.tick(1);

    const notes = umbra.mock.notification;

    try testing.expectEqualStrings("Signing in", fixture.label(@backingInt(Item.status)));
    try testing.expectEqualStrings("Sign in\u{2026}", fixture.label(@backingInt(Item.sign_in)));
    try testing.expectEqualStrings(icon_busy, fixture.tray.app.icons.get_current_name().?);
    try testing.expectEqual(@as(u32, 1), notes.recorded_count());
    try testing.expectEqualStrings("Sign in to Twingate", notes.title_at(0));

    fixture.session.set_status(io, .online, "", 20);
    fixture.tick(2);

    try testing.expectEqualStrings(icon_connected, fixture.tray.app.icons.get_current_name().?);
    try testing.expect(fixture.tray.app.menu.get_item(@backingInt(Item.sign_in)) == null);
    try testing.expectEqual(@as(u32, 2), notes.recorded_count());
    try testing.expectEqualStrings("Connected", notes.title_at(1));

    fixture.session.set_status(io, .online, page, 30);
    fixture.tick(3);

    try testing.expectEqual(@as(u32, 3), notes.recorded_count());
    try testing.expectEqualStrings("Sign in to Twingate", notes.title_at(2));

    fixture.session.set_status(io, .offline, "", 40);
    fixture.tick(4);

    try testing.expectEqual(@as(u32, 4), notes.recorded_count());
    try testing.expectEqualStrings("Disconnected", notes.title_at(3));
}

test "a tunnel whose resources still owe a sign-in offers one without a page and tells once" {
    const io = testing.io;

    var fixture: Fixture = undefined;

    try fixture.init(io);
    defer fixture.deinit();

    fixture.session.set_status(io, .offline, "", 0);
    fixture.tray.on_app_init();
    fixture.session.set_status(io, .online, "", 10);
    fixture.session.set_locked(io, true);
    fixture.tick(1);
    fixture.tick(2);

    const notes = umbra.mock.notification;

    try testing.expectEqualStrings("Sign-in needed", fixture.label(@backingInt(Item.status)));
    try testing.expectEqualStrings(icon_busy, fixture.tray.app.icons.get_current_name().?);
    try testing.expect(fixture.enabled(@backingInt(Item.sign_in)));
    try testing.expectEqual(@as(u32, 1), notes.recorded_count());
    try testing.expectEqualStrings("Sign in to Twingate", notes.title_at(0));

    fixture.tray.on_menu_select(.{ .checked = false, .id = @backingInt(Item.sign_in) });

    try testing.expectEqual(@as(u32, 1), fixture.host.sign_ins);
}

test "a tray that never appears hands the session to the window" {
    const io = testing.io;

    var fixture: Fixture = undefined;

    try fixture.init(io);
    defer fixture.deinit();

    fixture.tray.on_app_init();

    var tick: u64 = 0;

    while (tick < absent_ticks_max * 2) : (tick += 1) {
        fixture.tick(tick + 1);

        const expected: u32 = if (tick + 1 >= absent_ticks_max) 1 else 0;

        try testing.expectEqual(expected, fixture.host.failed);
    }

    try testing.expectEqual(absent_ticks_max, fixture.tray.absent_ticks);
}

test "the menu and a left click reach the host" {
    const io = testing.io;

    var fixture: Fixture = undefined;

    try fixture.init(io);
    defer fixture.deinit();

    fixture.tray.on_app_init();
    fixture.tray.on_menu_select(.{ .checked = false, .id = @backingInt(Item.open) });
    fixture.tray.on_tray_left_click();
    fixture.tray.on_menu_select(.{ .checked = false, .id = @backingInt(Item.quit) });

    try testing.expectEqual(@as(u32, 2), fixture.host.shows);
    try testing.expectEqual(@as(u32, 1), fixture.host.quits);
    try testing.expectEqual(@as(?Session.Command, null), fixture.session.take(io));
}

test "a token from the tray host travels with each request to show the window" {
    const io = testing.io;
    const token = "gnome-shell/Solopass/2541-0-fedora_TIME51234";

    var fixture: Fixture = undefined;

    try fixture.init(io);
    defer fixture.deinit();

    umbra.mock.tray.activation_provide(token);
    fixture.tray.on_tray_left_click();

    try testing.expectEqualStrings(token, fixture.host.token_seen());

    umbra.mock.tray.activation_clear();
    fixture.tray.on_menu_select(.{ .checked = false, .id = @backingInt(Item.open) });

    try testing.expectEqualStrings("", fixture.host.token_seen());

    umbra.mock.tray.activation_provide("kwin-17");
    fixture.tray.on_menu_select(.{ .checked = false, .id = @backingInt(Item.open) });

    try testing.expectEqualStrings("kwin-17", fixture.host.token_seen());
    try testing.expectEqual(@as(u32, 3), fixture.host.shows);
}

test "a stopping host ends the loop before the next event" {
    var fixture: Fixture = undefined;

    umbra.mock.reset();
    fixture.host = .{ .stopping = true };
    fixture.session.init();

    const tick: umbra.Event.Tick = .{ .id = synchronize_timer_id, .tick_count = 1 };

    try umbra.mock.loop.push(.create(.{ .timer_tick = tick }));
    try umbra.mock.loop.push(.create(.{ .tray_left_click = {} }));

    TrayType(TestHost).main(&fixture.tray, testing.io, &fixture.session, &fixture.host);

    try testing.expectEqual(@as(u32, 1), umbra.mock.loop.dispatch_count());
    try testing.expectEqual(@as(u32, 0), fixture.host.shows);
    try testing.expectEqual(@as(u32, 0), fixture.host.failed);
}

test "a loop that ends on its own hands the session to the window" {
    var fixture: Fixture = undefined;

    umbra.mock.reset();
    fixture.host = .{};
    fixture.session.init();

    TrayType(TestHost).main(&fixture.tray, testing.io, &fixture.session, &fixture.host);

    try testing.expectEqual(@as(u32, 1), fixture.host.failed);
    try testing.expectEqual(@as(u32, 1), umbra.mock.loop.runs());
}
