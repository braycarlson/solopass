const std = @import("std");

const assert = std.debug.assert;
const log = std.log.scoped(.x11);

pub const Display = opaque {};
const Atom = c_ulong;
const Bool = c_int;
const Time = c_ulong;
const Window = c_ulong;

const ChangeProperty = fn (
    *Display,
    Window,
    Atom,
    Atom,
    c_int,
    c_int,
    [*]const u8,
    c_int,
) callconv(.c) c_int;

const CheckIfEvent = fn (*Display, *Event, *const Predicate, ?*anyopaque) callconv(.c) Bool;
const Flush = fn (*Display) callconv(.c) c_int;
const InternAtom = fn (*Display, [*:0]const u8, Bool) callconv(.c) Atom;
const Predicate = fn (*Display, *Event, ?*anyopaque) callconv(.c) Bool;
const RootWindow = fn (*Display) callconv(.c) Window;
const SendEvent = fn (*Display, Window, Bool, c_long, *Event) callconv(.c) c_int;
const Sync = fn (*Display, Bool) callconv(.c) c_int;

const ClientMessageEvent = extern struct {
    type: c_int,
    serial: c_ulong,
    send_event: Bool,
    display: ?*Display,
    window: Window,
    message_type: Atom,
    format: c_int,
    data: [5]c_long,
};

const Event = extern union {
    client: ClientMessageEvent,
    pad: [24]c_long,
    property: PropertyEvent,
    type: c_int,
};

const Library = struct {
    change_property: *const ChangeProperty,
    check_if_event: *const CheckIfEvent,
    flush: *const Flush,
    intern_atom: *const InternAtom,
    root_window: *const RootWindow,
    send_event: *const SendEvent,
    synchronize: *const Sync,
};

const PropertyEvent = extern struct {
    type: c_int,
    serial: c_ulong,
    send_event: Bool,
    display: ?*Display,
    window: Window,
    atom: Atom,
    time: Time,
    state: c_int,
};

const Target = struct {
    atom: Atom,
    window: Window,
};

const active_window_name = "_NET_ACTIVE_WINDOW";
const client_message: c_int = 33;
const library_name = "libX11.so.6";
const mode_replace: c_int = 0;
const motif_decorations_border: c_long = 1;
const motif_function_all: c_long = 1 << 0;
const motif_function_close: c_long = 1 << 5;
const motif_function_maximize: c_long = 1 << 4;
const motif_function_minimize: c_long = 1 << 3;
const motif_function_move: c_long = 1 << 2;
const motif_function_resize: c_long = 1 << 1;
const motif_hint_decorations: c_long = 1 << 1;
const motif_hint_functions: c_long = 1 << 0;
const motif_hints_name = "_MOTIF_WM_HINTS";

const motif_hints = [5]c_long{
    motif_hint_functions | motif_hint_decorations,
    motif_function_all | motif_function_maximize,
    motif_decorations_border,
    0,
    0,
};

const property_notify: c_int = 28;
const source_application: c_long = 1;
const substructure_notify_mask: c_long = 1 << 19;
const substructure_redirect_mask: c_long = 1 << 20;
const timestamp_name = "_SOLOPASS_TIMESTAMP";

comptime {
    assert(@sizeOf(Event) == 24 * @sizeOf(c_long));
    assert(@sizeOf(PropertyEvent) == 8 * @sizeOf(c_long));
    assert(@sizeOf(ClientMessageEvent) == 12 * @sizeOf(c_long));
    assert(@offsetOf(PropertyEvent, "time") == 6 * @sizeOf(c_long));
    assert(@offsetOf(ClientMessageEvent, "data") == 7 * @sizeOf(c_long));
    assert(motif_hints[1] & motif_function_all != 0);
    assert(motif_hints[1] & motif_function_maximize != 0);
    assert(motif_hints[1] & motif_function_resize == 0);
}

pub fn activate(display: *Display, window: Window) void {
    assert(window != 0);

    var handle = std.DynLib.open(library_name) catch |err| {
        log.warn("{s} did not load: {t}", .{ library_name, err });

        return;
    };

    defer handle.close();

    const library = library_load(&handle) orelse {
        log.warn("{s} lacks a function that window activation needs", .{library_name});

        return;
    };

    const time = server_time(&library, display, window) orelse {
        log.warn("the X server did not report its time", .{});

        return;
    };

    activation_send(&library, display, window, time);
}

pub fn maximize_disable(display: *Display, window: Window) void {
    assert(window != 0);

    var handle = std.DynLib.open(library_name) catch |err| {
        log.warn("{s} did not load: {t}", .{ library_name, err });

        return;
    };

    defer handle.close();

    const library = library_load(&handle) orelse {
        log.warn("{s} lacks a function that the window hints need", .{library_name});

        return;
    };

    const atom = library.intern_atom(display, motif_hints_name, 0);
    if (atom == 0) return;

    const data = std.mem.asBytes(&motif_hints);

    assert(data.len == motif_hints.len * @sizeOf(c_long));

    _ = library.change_property(
        display,
        window,
        atom,
        atom,
        32,
        mode_replace,
        data,
        motif_hints.len,
    );

    _ = library.flush(display);
}

fn library_load(handle: *std.DynLib) ?Library {
    const library: Library = .{
        .change_property = handle.lookup(
            *const ChangeProperty,
            "XChangeProperty",
        ) orelse return null,
        .check_if_event = handle.lookup(*const CheckIfEvent, "XCheckIfEvent") orelse return null,
        .flush = handle.lookup(*const Flush, "XFlush") orelse return null,
        .intern_atom = handle.lookup(*const InternAtom, "XInternAtom") orelse return null,
        .root_window = handle.lookup(*const RootWindow, "XDefaultRootWindow") orelse return null,
        .send_event = handle.lookup(*const SendEvent, "XSendEvent") orelse return null,
        .synchronize = handle.lookup(*const Sync, "XSync") orelse return null,
    };

    return library;
}

fn server_time(library: *const Library, display: *Display, window: Window) ?Time {
    assert(window != 0);

    const atom = library.intern_atom(display, timestamp_name, 0);
    if (atom == 0) return null;

    var target: Target = .{ .atom = atom, .window = window };
    var event: Event = .{ .pad = @splat(0) };

    _ = library.change_property(display, window, atom, atom, 8, mode_replace, "a", 1);
    _ = library.synchronize(display, 0);

    if (library.check_if_event(display, &event, property_matches, &target) == 0) return null;

    assert(event.property.window == window);
    assert(event.property.atom == atom);
    assert(event.property.time <= std.math.maxInt(u32));

    return event.property.time;
}

fn property_matches(_: *Display, event: *Event, argument: ?*anyopaque) callconv(.c) Bool {
    assert(argument != null);

    const target: *const Target = @ptrCast(@alignCast(argument.?));

    assert(target.window != 0);
    assert(target.atom != 0);

    if (event.type != property_notify) return 0;
    if (event.property.window != target.window) return 0;
    if (event.property.atom != target.atom) return 0;

    return 1;
}

fn activation_send(library: *const Library, display: *Display, window: Window, time: Time) void {
    assert(window != 0);
    assert(time <= std.math.maxInt(u32));

    const atom = library.intern_atom(display, active_window_name, 0);
    if (atom == 0) return;

    var event: Event = .{ .pad = @splat(0) };

    event.client = .{
        .type = client_message,
        .serial = 0,
        .send_event = 1,
        .display = display,
        .window = window,
        .message_type = atom,
        .format = 32,
        .data = .{ source_application, @intCast(time), 0, 0, 0 },
    };

    const root = library.root_window(display);
    const mask = substructure_notify_mask | substructure_redirect_mask;

    assert(root != 0);

    _ = library.send_event(display, root, 0, mask, &event);
    _ = library.flush(display);
}

const testing = std.testing;

const Functions = struct {
    close: bool,
    maximize: bool,
    minimize: bool,
    move: bool,
    resize: bool,
};

fn mutter_functions(hints: *const [5]c_long) Functions {
    assert(hints[0] & motif_hint_functions != 0);

    const listed = hints[1];
    const keep = listed & motif_function_all != 0;

    return .{
        .close = if (listed & motif_function_close != 0) !keep else keep,
        .maximize = if (listed & motif_function_maximize != 0) !keep else keep,
        .minimize = if (listed & motif_function_minimize != 0) !keep else keep,
        .move = if (listed & motif_function_move != 0) !keep else keep,
        .resize = if (listed & motif_function_resize != 0) !keep else keep,
    };
}

test maximize_disable {
    const MaximizeDisable = fn (*Display, Window) void;

    try testing.expect(@TypeOf(maximize_disable) == MaximizeDisable);
}

test "mutter reads the hints as every window function but maximize, on a bordered window" {
    const functions = mutter_functions(&motif_hints);

    try testing.expect(!functions.maximize);
    try testing.expect(functions.close);
    try testing.expect(functions.minimize);
    try testing.expect(functions.move);
    try testing.expect(functions.resize);
    try testing.expect(motif_hints[0] & motif_hint_decorations != 0);
    try testing.expectEqual(motif_decorations_border, motif_hints[2]);
}

test activate {
    const Activate = fn (*Display, Window) void;

    try testing.expect(@TypeOf(activate) == Activate);
}

test "the round trip answers only to the timestamp property on this window" {
    var target: Target = .{ .atom = 401, .window = 0x2600007 };
    var event: Event = .{ .pad = @splat(0) };
    var display: u8 = 0;

    const handle: *Display = @ptrCast(&display);

    event.property = .{
        .type = property_notify,
        .serial = 1,
        .send_event = 0,
        .display = handle,
        .window = target.window,
        .atom = target.atom,
        .time = 123_456,
        .state = 0,
    };

    try testing.expectEqual(@as(Bool, 1), property_matches(handle, &event, &target));

    event.property.atom = target.atom + 1;

    try testing.expectEqual(@as(Bool, 0), property_matches(handle, &event, &target));

    event.property.atom = target.atom;
    event.property.window = target.window + 1;

    try testing.expectEqual(@as(Bool, 0), property_matches(handle, &event, &target));

    event.property.window = target.window;
    event.type = client_message;

    try testing.expectEqual(@as(Bool, 0), property_matches(handle, &event, &target));
}
