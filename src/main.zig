const std = @import("std");

const dvui = @import("dvui");
const umbra = @import("umbra");

const Action = @import("action.zig").Action;
const Appearance = @import("appearance.zig").Appearance;
const Autostart = @import("autostart.zig").Autostart;
const Journal = @import("journal.zig").Journal;
const Session = @import("session.zig").Session;
const Snapshot = @import("snapshot.zig").Snapshot;
const Table = @import("table.zig").Table;
const theme = @import("theme.zig");
const TrayType = @import("tray.zig").TrayType;
const Twingate = @import("twingate.zig").Twingate;
const View = @import("view.zig").View;
const wayland = @import("wayland.zig");
const Worker = @import("worker.zig").Worker;
const x11 = @import("x11.zig");

const assert = std.debug.assert;
const c = dvui.backend.c;
const log = std.log.scoped(.solopass);

const Allocator = std.mem.Allocator;
const Backend = dvui.backend;
const Environ = std.process.Environ;
const Scheme = theme.Scheme;
const Tray = TrayType(Host);

const Activation = struct {
    bytes: [activation_token_bytes_max]u8,
    length: u32,
    mutex: std.Io.Mutex,

    const empty: Activation = .{ .bytes = undefined, .length = 0, .mutex = .init };

    fn store(activation: *Activation, io: std.Io, token: []const u8) void {
        assert(token.len <= activation_token_bytes_max);

        activation.mutex.lockUncancelable(io);
        defer activation.mutex.unlock(io);

        @memcpy(activation.bytes[0..token.len], token);

        activation.length = @intCast(token.len);

        assert(std.mem.eql(u8, activation.bytes[0..activation.length], token));
    }

    fn take(
        activation: *Activation,
        io: std.Io,
        buffer: *[activation_token_bytes_max + 1]u8,
    ) [:0]const u8 {
        activation.mutex.lockUncancelable(io);
        defer activation.mutex.unlock(io);

        const length = activation.length;

        assert(length <= activation_token_bytes_max);

        @memcpy(buffer[0..length], activation.bytes[0..length]);

        buffer[length] = 0;
        activation.length = 0;

        assert(activation.length == 0);

        return buffer[0..length :0];
    }
};

const App = struct {
    appearance: ?Appearance,
    autostart: ?Autostart,
    autostart_enabled: bool,
    group: std.Io.Group,
    host: Host,
    io: std.Io,
    journal: Journal,
    log_open: bool,
    session: Session,
    snapshot: Snapshot,
    tray: Tray,
    tray_thread: ?std.Thread,
    worker: Worker,

    const InitError = Allocator.Error || std.Io.ConcurrentError;

    fn init(
        app: *App,
        gpa: Allocator,
        io: std.Io,
        window: *dvui.Window,
        environment: *const Environ.Map,
        appearance: *const ?Appearance,
    ) InitError!void {
        const paths: Twingate.Paths = .system;

        app.* = .{
            .appearance = appearance.*,
            .autostart = autostart_find(),
            .autostart_enabled = false,
            .group = .init,
            .host = .init(window),
            .io = io,
            .journal = undefined,
            .log_open = false,
            .session = undefined,
            .snapshot = .initial,
            .tray = undefined,
            .tray_thread = null,
            .worker = undefined,
        };

        app.session.init();

        try app.worker.init(gpa, io, &app.session, &paths, environment);
        errdefer app.worker.deinit();

        try app.journal.init(gpa, io, &app.session, &paths, environment);
        errdefer app.journal.deinit();

        try app.group.concurrent(io, Worker.run, .{&app.worker});
        errdefer app.group.cancel(io);

        try app.group.concurrent(io, Journal.run, .{&app.journal});

        const arguments = .{ &app.tray, io, &app.session, &app.host };
        const options: std.Thread.SpawnConfig = .{ .stack_size = tray_stack_bytes };

        app.tray_thread = std.Thread.spawn(options, Tray.main, arguments) catch |err| {
            log.err("the tray thread did not start: {t}", .{err});
            app.host.fail();

            return;
        };

        assert(app.tray_thread != null);
    }

    fn deinit(app: *App) void {
        assert(!app.host.is_stopping());

        app.host.stopping.store(true, .release);
        app.group.cancel(app.io);

        if (app.tray_thread) |thread| thread.join();

        app.tray_thread = null;
        app.journal.deinit();
        app.worker.deinit();

        assert(app.host.is_stopping());
    }

    fn apply(app: *App, choice: View.Choice) void {
        if (choice == .dismiss) assert(app.snapshot.message.text.length > 0);
        if (choice == .sign_in) assert(app.snapshot.needs_sign_in());

        switch (choice) {
            .act => |action| app.submit(action, ""),
            .autostart => |enabled| app.set_autostart(enabled),
            .dismiss => app.session.clear_message(app.io),
            .log => |open| app.show_log(open),
            .scheme => |scheme| app.set_scheme(scheme),
            .sign_in => app.sign_in(),
            .switch_account => |index| app.switch_account(index),
        }

        dvui.refresh(null, @src(), null);
    }

    fn conceal(app: *App) void {
        assert(dvui.currentWindow() == app.host.window);

        const window = dvui.currentWindow().backend.impl.window;

        if (!c.SDL_HideWindow(window)) {
            log.warn("the window did not hide: {s}", .{c.SDL_GetError()});

            return;
        }

        app.host.visible.store(false, .release);

        assert(!app.host.is_visible());
    }

    fn enable_autostart(app: *App, autostart: *const Autostart) void {
        assert(!app.autostart_enabled);

        var buffer: [Autostart.path_bytes_max]u8 = undefined;

        const length = std.process.executablePath(app.io, &buffer) catch |err| {
            app.report("Solopass could not find its own executable", err);

            return;
        };

        assert(length > 0);

        autostart.enable(app.io, buffer[0..length]) catch |err| switch (err) {
            error.ExecutableUnsafe => app.session.set_message(
                app.io,
                .failure,
                "Start at login needs Solopass at a path without spaces or symbols.",
            ),
            else => app.report("Start at login could not be turned on", err),
        };
    }

    fn frame(app: *App) Frame {
        assert(!app.host.is_stopping());
        assert(dvui.currentWindow() == app.host.window);

        if (app.host.quitting.load(.acquire)) return .quit;

        if (app.host.failed.load(.acquire)) {
            if (!app.host.is_visible()) app.reveal();
        } else {
            app.intercept_close();
        }

        if (app.host.showing.swap(false, .acq_rel)) app.reveal();

        const generation = app.snapshot.generation;
        const copied = app.session.copy(app.io, &app.snapshot);

        if (copied) assert(app.snapshot.generation > generation);
        if (!copied) assert(app.snapshot.generation == generation);

        if (app.host.signing_in.swap(false, .acq_rel)) app.sign_in();

        const now_seconds = std.Io.Clock.boot.now(app.io).toSeconds();

        assert(now_seconds >= 0);

        if (app.autostart) |*autostart| app.autostart_enabled = autostart.is_enabled(app.io);

        const view: View = .{
            .autostart = app.autostart_enabled,
            .connected_seconds = app.snapshot.connected_seconds(now_seconds),
            .log_open = app.log_open,
            .snapshot = &app.snapshot,
        };

        if (view.frame()) |choice| app.apply(choice);
        if (app.host.is_visible()) schedule_refresh(&app.snapshot);

        return if (copied) .layout else .present;
    }

    fn intercept_close(app: *App) void {
        const window = dvui.currentWindow();

        assert(window == app.host.window);

        for (dvui.events()) |*event| {
            if (event.handled) continue;
            if (event.evt != .window) continue;
            if (event.evt.window.action != .close) continue;

            event.handle(@src(), window.data());
            app.conceal();

            assert(event.handled);
        }
    }

    fn report(app: *App, comptime prefix: []const u8, err: anyerror) void {
        comptime assert(prefix.len > 0);
        comptime assert(prefix.len + ".".len <= message_bytes_max);

        var buffer: [message_bytes_max]u8 = undefined;

        const text = std.mem.print(&buffer, prefix ++ ": {t}.", .{err}) catch prefix ++ ".";

        assert(std.mem.startsWith(u8, text, prefix));
        assert(std.mem.endsWith(u8, text, "."));

        log.warn("{s}", .{text});
        app.session.set_message(app.io, .failure, text);
    }

    fn reveal(app: *App) void {
        assert(dvui.currentWindow() == app.host.window);

        const window = dvui.currentWindow().backend.impl.window;

        var buffer: [activation_token_bytes_max + 1]u8 = undefined;

        const token = app.host.activation.take(app.io, &buffer);

        assert(token.len <= activation_token_bytes_max);

        const raise = Raise.choose(.{
            .hidden = (c.SDL_GetWindowFlags(window) & c.SDL_WINDOW_HIDDEN) != 0,
            .token = token.len > 0,
            .wayland = video_wayland(),
        });

        if (raise == .token_with_show) activation_hand(token);

        if (!c.SDL_ShowWindow(window)) {
            log.warn("the window did not show: {s}", .{c.SDL_GetError()});

            return;
        }

        switch (raise) {
            .request => {
                _ = c.SDL_RaiseWindow(window);
                activate_x11(window);
            },
            .token_now => activate_wayland(window, token),
            .token_with_show => {},
        }

        app.host.visible.store(true, .release);
        dvui.refresh(null, @src(), null);

        assert(app.host.is_visible());
    }

    fn save_scheme(app: *App, scheme: Scheme) void {
        const appearance = if (app.appearance) |*found| found else {
            app.session.set_message(
                app.io,
                .failure,
                "Solopass has no configuration directory to save the theme in.",
            );

            return;
        };

        appearance.save(app.io, scheme) catch |err| {
            app.report("The theme could not be saved", err);
        };
    }

    fn set_autostart(app: *App, enabled: bool) void {
        assert(enabled != app.autostart_enabled);

        const autostart = if (app.autostart) |*found| found else {
            app.session.set_message(
                app.io,
                .failure,
                "Start at login is unavailable on this desktop.",
            );

            return;
        };

        if (enabled) {
            app.enable_autostart(autostart);
        } else {
            autostart.disable(app.io) catch |err| {
                app.report("Start at login could not be turned off", err);
            };
        }

        app.autostart_enabled = autostart.is_enabled(app.io);
    }

    fn set_scheme(app: *App, scheme: Scheme) void {
        assert(theme.scheme_of(&dvui.currentWindow().theme) != scheme);

        dvui.themeSet(theme.theme_of(scheme));
        app.save_scheme(scheme);

        assert(theme.scheme_of(&dvui.currentWindow().theme) == scheme);
    }

    fn show_log(app: *App, open: bool) void {
        if (!open) assert(app.log_open);

        app.log_open = open;

        if (open) app.session.request_log(app.io);

        assert(app.log_open == open);
    }

    fn sign_in(app: *App) void {
        if (!app.snapshot.needs_sign_in()) return;

        const url = app.snapshot.sign_in_url() orelse {
            if (app.snapshot.pending == null) app.submit(.sign_in, "");

            return;
        };

        const status = app.snapshot.status;

        assert(url.len > 0);
        assert(status == .authenticating or status == .online);

        if (dvui.openURL(.{ .url = url })) return;

        app.session.set_message(app.io, .failure, "The sign-in page did not open in a browser.");
    }

    fn submit(app: *App, action: Action, account: []const u8) void {
        assert(account.len <= Snapshot.accounts_bytes_max);
        assert(app.snapshot.pending == null);

        if (action != .switch_account) assert(account.len == 0);
        if (app.session.submit(app.io, action, account)) return;

        log.info("{t} was refused while another command runs", .{action});
    }

    fn switch_account(app: *App, index: u32) void {
        assert(index < View.account_count_max);

        const accounts: Table = .init(app.snapshot.accounts.slice());
        const line = accounts.row(index) orelse return;

        assert(line.kind == .row);
        assert(!line.is_current());

        app.submit(.switch_account, line.cell(0));
    }
};

const Frame = enum {
    layout,
    present,
    quit,
};

const Hint = struct {
    name: [:0]const u8,
    value: [:0]const u8,
};

const Host = struct {
    activation: Activation,
    failed: std.atomic.Value(bool),
    quitting: std.atomic.Value(bool),
    showing: std.atomic.Value(bool),
    signing_in: std.atomic.Value(bool),
    stopping: std.atomic.Value(bool),
    visible: std.atomic.Value(bool),
    window: *dvui.Window,

    fn init(window: *dvui.Window) Host {
        return .{
            .activation = .empty,
            .failed = .init(false),
            .quitting = .init(false),
            .showing = .init(false),
            .signing_in = .init(false),
            .stopping = .init(false),
            .visible = .init(false),
            .window = window,
        };
    }

    pub fn fail(host: *Host) void {
        host.failed.store(true, .release);
        host.wake();

        assert(host.failed.load(.acquire));
    }

    pub fn is_stopping(host: *const Host) bool {
        return host.stopping.load(.acquire);
    }

    pub fn is_visible(host: *const Host) bool {
        return host.visible.load(.acquire);
    }

    pub fn quit(host: *Host) void {
        host.quitting.store(true, .release);
        host.wake();

        assert(host.quitting.load(.acquire));
    }

    pub fn show(host: *Host, io: std.Io, token: []const u8) void {
        assert(token.len <= activation_token_bytes_max);

        host.activation.store(io, token);
        host.showing.store(true, .release);
        host.wake();
    }

    pub fn sign_in(host: *Host) void {
        host.signing_in.store(true, .release);
        host.wake();
    }

    fn wake(host: *Host) void {
        dvui.refresh(host.window, @src(), null);
    }
};

const Pacing = struct {
    hidden: bool,

    const initial: Pacing = .{ .hidden = false };

    fn present(pacing: *Pacing, outcome: Frame, drifted: bool) bool {
        const hidden_last = pacing.hidden;
        const stale = if (drifted) true else outcome == .layout;
        const shown = if (hidden_last) true else !stale;

        pacing.hidden = !shown;

        if (hidden_last) assert(shown);
        if (!shown) assert(stale);

        return shown;
    }
};

const Raise = enum {
    request,
    token_now,
    token_with_show,

    const Situation = struct {
        hidden: bool,
        token: bool,
        wayland: bool,
    };

    fn choose(situation: Situation) Raise {
        if (!situation.wayland) return .request;
        if (!situation.token) return .request;
        if (situation.hidden) return .token_with_show;

        return .token_now;
    }
};

const X11Window = struct {
    display: *x11.Display,
    window: u32,
};

const activation_token_bytes_max = umbra.limits.activation_token_bytes_max;
const activation_variable = "XDG_ACTIVATION_TOKEN";
const autostart_name = "autostart";
const config_name = "solopass";
const desktop_key = "XDG_CURRENT_DESKTOP";
const desktop_name_count_max: u32 = 16;
const desktop_name_gnome = "GNOME";
const frame_count_max: u64 = 1 << 48;
const message_bytes_max: u32 = 160;
const refresh_micros: i32 = 500 * std.time.us_per_ms;
const scheme_fallback: Scheme = .dark;
const tray_stack_bytes: u32 = std.Thread.SpawnConfig.default_stack_size;

comptime {
    assert(message_bytes_max <= Snapshot.message_bytes_max);
    assert(refresh_micros > 0);
}

pub fn main(init: std.process.Init) u8 {
    assert(init.minimal.args.vector.len > 0);

    start(&init) catch |err| {
        log.err("solopass stopped: {t}", .{err});

        return 1;
    };

    return 0;
}

fn start(init: *const std.process.Init) !void {
    set_hint(.{ .name = "SDL_QUIT_ON_LAST_WINDOW_CLOSE", .value = "0" });
    set_hint(.{ .name = "SDL_VIDEO_ALLOW_SCREENSAVER", .value = "1" });

    const gnome = desktop_gnome(init.environ_map);

    if (gnome) set_hint(.{ .name = "SDL_VIDEO_DRIVER", .value = "x11,wayland" });

    var backend = try Backend.initWindow(.{
        .io = init.io,
        .environ_map = init.environ_map,
        .size = .{ .w = 560, .h = 680 },
        .min_size = .{ .w = 380, .h = 520 },
        .vsync = true,
        .org = "braycarlson",
        .app = "solopass",
        .title = "Solopass",
        .hidden = true,
        .persist_window_geometry = false,
    });

    defer backend.deinit();

    icon_set(backend.window);

    if (gnome) maximize_disable_x11(backend.window);

    const appearance = appearance_find();
    const saved = if (appearance) |*found| scheme_load(init.io, found) else null;
    const scheme = saved orelse scheme_preferred(&backend) orelse scheme_fallback;
    var open = true;

    var window = try dvui.Window.init(@src(), init.gpa, backend.backend(), .{
        .open_flag = &open,
        .theme = theme.theme_of(scheme),
    });

    defer window.deinit();

    assert(theme.scheme_of(&window.theme) == scheme);

    window.snap_to_pixels = theme.snap_to_pixels;

    var app: App = undefined;

    try app.init(init.gpa, init.io, &window, init.environ_map, &appearance);
    defer app.deinit();

    assert(app.host.window == &window);

    try run(&app, &backend, &window, &open);
}

fn activate_wayland(window: *c.SDL_Window, token: [:0]const u8) void {
    assert(token.len > 0);
    assert(token.len <= activation_token_bytes_max);

    const properties = c.SDL_GetWindowProperties(window);

    const display_pointer = c.SDL_GetPointerProperty(
        properties,
        c.SDL_PROP_WINDOW_WAYLAND_DISPLAY_POINTER,
        null,
    );

    const surface_pointer = c.SDL_GetPointerProperty(
        properties,
        c.SDL_PROP_WINDOW_WAYLAND_SURFACE_POINTER,
        null,
    );

    const display: *wayland.Display = @ptrCast(display_pointer orelse return);
    const surface: *wayland.Surface = @ptrCast(surface_pointer orelse return);

    wayland.activate(display, surface, token);
}

fn activate_x11(window: *c.SDL_Window) void {
    const target = x11_window(window) orelse return;

    assert(target.window > 0);

    x11.activate(target.display, target.window);
}

fn activation_hand(token: [:0]const u8) void {
    assert(token.len > 0);
    assert(token.len <= activation_token_bytes_max);

    const environment = c.SDL_GetEnvironment() orelse return;

    if (c.SDL_SetEnvironmentVariable(environment, activation_variable, token.ptr, true)) return;

    log.warn("the activation token did not reach SDL: {s}", .{c.SDL_GetError()});
}

fn appearance_find() ?Appearance {
    var buffer: [umbra.limits.path_bytes_max]u8 = undefined;

    const directory = umbra.paths.config_dir(&buffer, config_name) catch |err| {
        log.warn("the configuration directory is unknown: {t}", .{err});

        return null;
    };

    assert(std.mem.endsWith(u8, directory, config_name));

    return Appearance.init(directory) catch |err| {
        log.warn("the configuration directory is too long for the appearance: {t}", .{err});

        return null;
    };
}

fn autostart_find() ?Autostart {
    var buffer: [umbra.limits.path_bytes_max]u8 = undefined;

    const directory = umbra.paths.config_dir(&buffer, autostart_name) catch |err| {
        log.warn("the autostart directory is unknown: {t}", .{err});

        return null;
    };

    assert(std.mem.endsWith(u8, directory, autostart_name));

    return Autostart.init(directory) catch |err| {
        log.warn("the autostart directory is too long for its entry: {t}", .{err});

        return null;
    };
}

fn desktop_gnome(environ: *const Environ.Map) bool {
    const desktops = environ.get(desktop_key) orelse return false;
    var names = std.mem.splitScalar(u8, desktops, ':');
    var count: u32 = 0;

    while (names.next()) |name| : (count += 1) {
        assert(count <= desktop_name_count_max);

        if (count == desktop_name_count_max) return false;
        if (std.mem.eql(u8, name, desktop_name_gnome)) return true;
    }

    assert(count > 0);

    return false;
}

fn icon_set(window: *c.SDL_Window) void {
    const bytes = @embedFile("icon");

    var width: c_int = 0;
    var height: c_int = 0;
    var channels: c_int = 0;

    const pixels = dvui.c.stbi_load_from_memory(bytes, bytes.len, &width, &height, &channels, 4);

    if (pixels == null) {
        log.warn("the window icon did not decode: {s}", .{dvui.c.stbi_failure_reason()});

        return;
    }

    defer dvui.c.stbi_image_free(pixels);

    assert(width > 0);
    assert(width == height);

    const surface = c.SDL_CreateSurfaceFrom(
        width,
        height,
        c.SDL_PIXELFORMAT_ABGR8888,
        @ptrCast(pixels),
        4 * width,
    ) orelse {
        log.warn("the window icon surface was not made: {s}", .{c.SDL_GetError()});

        return;
    };

    defer c.SDL_DestroySurface(surface);

    if (c.SDL_SetWindowIcon(window, surface)) return;

    log.debug("the compositor takes the icon from the desktop entry: {s}", .{c.SDL_GetError()});
}

fn maximize_disable_x11(window: *c.SDL_Window) void {
    const target = x11_window(window) orelse return;

    assert(target.window > 0);

    x11.maximize_disable(target.display, target.window);
}

fn run(app: *App, backend: *Backend, window: *dvui.Window, open: *const bool) !void {
    assert(app.host.window == window);

    var interrupted = false;
    var pacing: Pacing = .initial;
    var frame_index: u64 = 0;

    while (frame_index < frame_count_max) : (frame_index += 1) {
        assert(open.*);

        const nanoseconds = window.beginWait(interrupted);

        try window.begin(nanoseconds);
        try backend.addAllEvents(window);

        const outcome = app.frame();
        const drifted = !std.meta.eql(window.rect_pixels.size(), backend.pixelSize());
        const presented = pacing.present(outcome, drifted);
        if (!presented) dvui.refresh(null, @src(), null);

        const end_micros = try window.end(.{ .manage_backend = presented, .show_toasts = true });

        if (outcome == .quit) return;
        if (!open.*) return;

        interrupted = try backend.waitEventTimeout(window.waitTime(end_micros));
    }
}

fn schedule_refresh(snapshot: *const Snapshot) void {
    const id = dvui.currentWindow().data().id;
    const busy = snapshot.pending != null or snapshot.progress() != null;
    const animated = busy or snapshot.log.reading();

    if (animated) {
        dvui.refresh(null, @src(), id);
    } else {
        if (dvui.timerDoneOrNone(id)) dvui.timer(id, refresh_micros);
    }
}

fn scheme_load(io: std.Io, appearance: *const Appearance) ?Scheme {
    assert(appearance.path_length > 0);

    return appearance.load(io) catch |err| switch (err) {
        error.FileNotFound => null,
        else => {
            log.warn("the saved appearance was not read: {t}", .{err});

            return null;
        },
    };
}

fn scheme_preferred(backend: *Backend) ?Scheme {
    const preferred = backend.backend().preferredColorScheme() orelse return null;

    return switch (preferred) {
        .dark => .dark,
        .light => .light,
    };
}

fn set_hint(comptime hint: Hint) void {
    comptime assert(std.mem.startsWith(u8, hint.name, "SDL_"));
    comptime assert(hint.value.len > 0);

    if (c.SDL_SetHint(hint.name, hint.value)) return;

    log.warn("the SDL hint {s} was not set: {s}", .{ hint.name, c.SDL_GetError() });
}

fn x11_window(window: *c.SDL_Window) ?X11Window {
    const properties = c.SDL_GetWindowProperties(window);

    const pointer = c.SDL_GetPointerProperty(
        properties,
        c.SDL_PROP_WINDOW_X11_DISPLAY_POINTER,
        null,
    );

    const display: *x11.Display = @ptrCast(pointer orelse return null);
    const number = c.SDL_GetNumberProperty(properties, c.SDL_PROP_WINDOW_X11_WINDOW_NUMBER, 0);
    if (number <= 0) return null;

    assert(number <= std.math.maxInt(u32));

    return .{ .display = display, .window = @intCast(number) };
}

fn video_wayland() bool {
    const name = c.SDL_GetCurrentVideoDriver() orelse return false;

    return std.mem.eql(u8, std.mem.span(name), "wayland");
}

const testing = std.testing;

const temporary_options: std.Io.Dir.OpenOptions = .{
    .access_sub_paths = true,
    .follow_symlinks = true,
    .iterate = false,
};

const two_accounts =
    "EMAIL                  \tNETWORK   \tNETWORK URL\n" ++
    "avery.quinn@example.com\tExampleNet\texamplenet.twingate.com\n" ++
    "brayden@example.com\tExample\texample.twingate.com\n";

test main {
    const Main = fn (std.process.Init) u8;

    try testing.expect(@TypeOf(main) == Main);
}

test "new data and a size that moved mid-frame are laid out unseen once, a plain resize never" {
    var pacing: Pacing = .initial;

    try testing.expect(pacing.present(.present, false));
    try testing.expect(!pacing.present(.layout, false));
    try testing.expect(pacing.present(.present, false));
    try testing.expect(!pacing.present(.present, true));
    try testing.expect(pacing.present(.present, false));
    try testing.expect(pacing.present(.quit, false));
}

test "a frame that is stale every time is still shown every other frame" {
    var pacing: Pacing = .initial;
    var shown: u32 = 0;

    for (0..64) |index| {
        if (pacing.present(.layout, index % 3 == 0)) shown += 1;
    }

    try testing.expectEqual(@as(u32, 32), shown);
}

test "a token waits for the window once, and the latest request's token wins" {
    const io = testing.io;

    var activation: Activation = .empty;
    var buffer: [activation_token_bytes_max + 1]u8 = undefined;

    try testing.expectEqualStrings("", activation.take(io, &buffer));

    activation.store(io, "kwin-17");
    activation.store(io, "gnome-shell/Solopass/2541-0-fedora_TIME51234");

    const token = activation.take(io, &buffer);

    try testing.expectEqualStrings("gnome-shell/Solopass/2541-0-fedora_TIME51234", token);
    try testing.expectEqual(@as(u8, 0), token.ptr[token.len]);
    try testing.expectEqualStrings("", activation.take(io, &buffer));

    const longest: [activation_token_bytes_max]u8 = @splat('t');

    activation.store(io, &longest);

    try testing.expectEqualStrings(&longest, activation.take(io, &buffer));

    activation.store(io, "kwin-17");
    activation.store(io, "");

    try testing.expectEqualStrings("", activation.take(io, &buffer));
}

test "only Wayland with a token raises by the token, through SDL while still hidden" {
    for ([_]bool{ false, true }) |hidden| {
        for ([_]bool{ false, true }) |token| {
            const server = Raise.choose(.{ .hidden = hidden, .token = token, .wayland = false });

            try testing.expectEqual(Raise.request, server);
        }

        const bare = Raise.choose(.{ .hidden = hidden, .token = false, .wayland = true });

        try testing.expectEqual(Raise.request, bare);
    }

    const opening = Raise.choose(.{ .hidden = true, .token = true, .wayland = true });
    const raising = Raise.choose(.{ .hidden = false, .token = true, .wayland = true });

    try testing.expectEqual(Raise.token_with_show, opening);
    try testing.expectEqual(Raise.token_now, raising);
}

test "a desktop list is GNOME only when one of its entries is exactly GNOME" {
    var environ: Environ.Map = .init(testing.allocator);
    defer environ.deinit();

    try testing.expect(!desktop_gnome(&environ));

    const cases = [_]struct { desktops: []const u8, gnome: bool }{
        .{ .desktops = "GNOME", .gnome = true },
        .{ .desktops = "ubuntu:GNOME", .gnome = true },
        .{ .desktops = "GNOME-Flashback:GNOME", .gnome = true },
        .{ .desktops = "1:2:3:4:5:6:7:8:9:10:11:12:13:14:15:GNOME", .gnome = true },
        .{ .desktops = "1:2:3:4:5:6:7:8:9:10:11:12:13:14:15:16:GNOME", .gnome = false },
        .{ .desktops = "", .gnome = false },
        .{ .desktops = "KDE", .gnome = false },
        .{ .desktops = "X-Cinnamon", .gnome = false },
        .{ .desktops = "gnome", .gnome = false },
        .{ .desktops = "GNOME-Classic", .gnome = false },
    };

    for (cases) |case| {
        try environ.put(desktop_key, case.desktops);
        try testing.expectEqual(case.gnome, desktop_gnome(&environ));
    }
}

test "a report names its prefix and error, or the prefix alone once both overflow" {
    testing.log_level = .err;

    const io = testing.io;

    var app: App = undefined;

    app.io = io;
    app.session.init();
    app.report("Start at login could not be turned off", error.AccessDenied);

    const message = &app.session.snapshot.message;

    try testing.expectEqualStrings(
        "Start at login could not be turned off: AccessDenied.",
        message.text.slice(),
    );

    try testing.expectEqual(Snapshot.Message.Kind.failure, message.kind);
    try testing.expectEqual(@as(u64, 1), message.generation);

    const prefix_long: [message_bytes_max - 1]u8 = @splat('x');

    app.report(&prefix_long, error.AccessDenied);

    try testing.expectEqualStrings(prefix_long ++ ".", message.text.slice());
    try testing.expectEqual(@as(u64, 2), message.generation);
}

test "the start at login switch reports a desktop without autostart and removes an entry" {
    const io = testing.io;

    var app: App = undefined;

    app.io = io;
    app.autostart = null;
    app.autostart_enabled = false;
    app.session.init();
    app.set_autostart(true);

    const message = &app.session.snapshot.message;

    try testing.expectEqualStrings(
        "Start at login is unavailable on this desktop.",
        message.text.slice(),
    );

    try testing.expect(!app.autostart_enabled);

    var temporary = testing.tmpDir(temporary_options);
    defer temporary.cleanup();

    var buffer: [Autostart.path_bytes_max]u8 = undefined;

    const length = try temporary.dir.realPath(io, &buffer);
    const directory = try std.mem.print(buffer[length..], "{s}/autostart", .{buffer[0..length]});
    const autostart = try Autostart.init(directory);

    try autostart.enable(io, "/usr/bin/solopass");

    app.autostart = autostart;
    app.autostart_enabled = true;
    app.set_autostart(false);

    try testing.expect(!app.autostart_enabled);
    try testing.expect(!autostart.is_enabled(io));
    try testing.expectEqual(@as(u64, 1), message.generation);

    app.set_autostart(true);

    try testing.expect(app.autostart_enabled != (message.generation > 1));
}

test "a theme saves to the appearance, or reports a desktop without a configuration directory" {
    const io = testing.io;

    var app: App = undefined;

    app.io = io;
    app.appearance = null;
    app.session.init();
    app.save_scheme(.light);

    const message = &app.session.snapshot.message;

    try testing.expectEqualStrings(
        "Solopass has no configuration directory to save the theme in.",
        message.text.slice(),
    );

    var temporary = testing.tmpDir(temporary_options);
    defer temporary.cleanup();

    var buffer: [Appearance.path_bytes_max]u8 = undefined;

    const length = try temporary.dir.realPath(io, &buffer);
    const directory = try std.mem.print(buffer[length..], "{s}/solopass", .{buffer[0..length]});
    const appearance = try Appearance.init(directory);

    app.appearance = appearance;

    for ([_]Scheme{ .light, .dark }) |scheme| {
        app.save_scheme(scheme);

        try testing.expectEqual(@as(?Scheme, scheme), scheme_load(io, &appearance));
    }

    try testing.expectEqual(@as(u64, 1), message.generation);
}

test "a missing or unreadable appearance reads as no saved scheme" {
    testing.log_level = .err;

    const io = testing.io;

    var temporary = testing.tmpDir(temporary_options);
    defer temporary.cleanup();

    var buffer: [Appearance.path_bytes_max]u8 = undefined;

    const length = try temporary.dir.realPath(io, &buffer);
    const directory = try std.mem.print(buffer[length..], "{s}/solopass", .{buffer[0..length]});
    const appearance = try Appearance.init(directory);

    try testing.expectEqual(@as(?Scheme, null), scheme_load(io, &appearance));

    try appearance.save(io, .light);
    try testing.expectEqual(@as(?Scheme, .light), scheme_load(io, &appearance));

    try temporary.dir.writeFile(io, .{ .sub_path = "solopass/appearance", .data = "blue\n" });
    try testing.expectEqual(@as(?Scheme, null), scheme_load(io, &appearance));
}

test "an account switch submits the email of its row and ignores a row past the list" {
    const io = testing.io;

    var app: App = undefined;

    app.io = io;
    app.session.init();
    app.snapshot = .initial;
    app.snapshot.accounts.set(two_accounts);
    app.switch_account(1);

    const second = app.session.take(io) orelse return error.CommandMissing;

    try testing.expectEqual(Action.switch_account, second.action);
    try testing.expectEqualStrings("brayden@example.com", second.account.slice());

    app.session.finish(io);
    app.switch_account(2);

    try testing.expect(app.session.take(io) == null);

    app.switch_account(0);

    const first = app.session.take(io) orelse return error.CommandMissing;

    try testing.expectEqualStrings("avery.quinn@example.com", first.account.slice());
}

test "a sign-in with no page to open asks the worker to start one, once and only while idle" {
    const io = testing.io;

    var app: App = undefined;

    app.io = io;
    app.session.init();
    app.snapshot = .initial;
    app.snapshot.observed = true;
    app.snapshot.status = .offline;
    app.sign_in();

    try testing.expect(app.session.take(io) == null);

    app.snapshot.status = .online;
    app.snapshot.locked = true;
    app.sign_in();

    const command = app.session.take(io) orelse return error.CommandMissing;

    try testing.expectEqual(Action.sign_in, command.action);

    app.snapshot.pending = .sign_in;
    app.sign_in();

    try testing.expect(app.session.take(io) == null);
}

test "the service log opens with a read, reads again on refresh, and closes without one" {
    const io = testing.io;

    var app: App = undefined;

    app.io = io;
    app.log_open = false;
    app.session.init();
    app.show_log(true);

    const service_log = &app.session.snapshot.log;

    try testing.expect(app.log_open);
    try testing.expect(service_log.reading());
    try testing.expectEqual(@as(u64, 1), service_log.requested);

    app.show_log(true);

    try testing.expectEqual(@as(u64, 2), service_log.requested);

    app.show_log(false);

    try testing.expect(!app.log_open);
    try testing.expectEqual(@as(u64, 2), service_log.requested);
    try testing.expectEqual(@as(?u64, 2), app.session.log_request(io));
}
