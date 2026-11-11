const std = @import("std");

const assert = std.debug.assert;
const log = std.log.scoped(.wayland);

pub const Display = opaque {};
pub const Surface = opaque {};
const Proxy = opaque {};
const Queue = opaque {};

const AddListener = fn (*Proxy, *const Listener, ?*anyopaque) callconv(.c) c_int;
const CreateQueue = fn (*Display) callconv(.c) ?*Queue;
const CreateWrapper = fn (*Display) callconv(.c) ?*Proxy;
const DestroyProxy = fn (*Proxy) callconv(.c) void;
const DestroyQueue = fn (*Queue) callconv(.c) void;
const DestroyWrapper = fn (*Proxy) callconv(.c) void;
const Flush = fn (*Display) callconv(.c) c_int;
const Global = fn (?*anyopaque, *Proxy, u32, [*:0]const u8, u32) callconv(.c) void;
const GlobalRemove = fn (?*anyopaque, *Proxy, u32) callconv(.c) void;
const Marshal = fn (*Proxy, u32, ?*const Interface, u32, u32, [*]Argument) callconv(.c) ?*Proxy;
const Roundtrip = fn (*Display, *Queue) callconv(.c) c_int;
const SetQueue = fn (*Proxy, ?*Queue) callconv(.c) void;
const Version = fn (*Proxy) callconv(.c) u32;

const Argument = extern union {
    object: ?*anyopaque,
    signed: i32,
    string: ?[*:0]const u8,
    unsigned: u32,
};

const Interface = extern struct {
    name: [*:0]const u8,
    version: c_int,
    method_count: c_int,
    methods: ?[*]const Message,
    event_count: c_int,
    events: ?[*]const Message,
};

const Library = struct {
    add_listener: *const AddListener,
    create_queue: *const CreateQueue,
    create_wrapper: *const CreateWrapper,
    destroy_proxy: *const DestroyProxy,
    destroy_queue: *const DestroyQueue,
    destroy_wrapper: *const DestroyWrapper,
    flush: *const Flush,
    marshal: *const Marshal,
    registry_interface: *const Interface,
    roundtrip: *const Roundtrip,
    set_queue: *const SetQueue,
    surface_interface: *const Interface,
    version: *const Version,
};

const Listener = extern struct {
    global: *const Global,
    global_remove: *const GlobalRemove,
};

const Message = extern struct {
    name: [*:0]const u8,
    signature: [*:0]const u8,
    types: [*]const ?*const Interface,
};

const Offer = struct {
    name: ?u32,
};

const activation_name = "xdg_activation_v1";
const activation_opcode_activate: u32 = 2;
const activation_opcode_destroy: u32 = 0;
const activation_version: u32 = 1;
const display_opcode_get_registry: u32 = 1;
const library_name = "libwayland-client.so.0";
const listener: Listener = .{ .global = &offer_record, .global_remove = &offer_ignore };
const marshal_flag_destroy: u32 = 1 << 0;
const message_bytes_max: u32 = std.math.maxInt(u16);
const pointer_bytes = @sizeOf(*const Interface);
const registry_opcode_bind: u32 = 0;

comptime {
    assert(@sizeOf(Argument) == pointer_bytes);
    assert(@sizeOf(Message) == 3 * pointer_bytes);
    assert(@sizeOf(Interface) == 5 * pointer_bytes);
    assert(@offsetOf(Interface, "methods") == 2 * pointer_bytes);
    assert(@offsetOf(Interface, "events") == 4 * pointer_bytes);
}

pub fn activate(display: *Display, surface: *Surface, token: [:0]const u8) void {
    assert(token.len > 0);

    var handle = std.DynLib.open(library_name) catch |err| {
        log.warn("{s} did not load: {t}", .{ library_name, err });

        return;
    };

    defer handle.close();

    const library = library_load(&handle) orelse {
        log.warn("{s} lacks a function that window activation needs", .{library_name});

        return;
    };

    const queue = library.create_queue(display) orelse return;
    defer library.destroy_queue(queue);

    const wrapper = library.create_wrapper(display) orelse return;
    defer library.destroy_wrapper(wrapper);

    library.set_queue(wrapper, queue);

    var none = [_]Argument{.{ .object = null }};

    const registry = library.marshal(
        wrapper,
        display_opcode_get_registry,
        library.registry_interface,
        library.version(wrapper),
        0,
        &none,
    ) orelse return;

    defer library.destroy_proxy(registry);

    var offer: Offer = .{ .name = null };

    if (library.add_listener(registry, &listener, &offer) != 0) return;
    if (library.roundtrip(display, queue) < 0) return;

    const name = offer.name orelse {
        log.info("the compositor offers no {s}", .{activation_name});

        return;
    };

    activation_send(&library, registry, name, surface, token);

    if (library.flush(display) < 0) log.warn("the activation request was not sent", .{});
}

fn library_load(handle: *std.DynLib) ?Library {
    const library: Library = .{
        .add_listener = handle.lookup(
            *const AddListener,
            "wl_proxy_add_listener",
        ) orelse return null,
        .create_queue = handle.lookup(
            *const CreateQueue,
            "wl_display_create_queue",
        ) orelse return null,
        .create_wrapper = handle.lookup(
            *const CreateWrapper,
            "wl_proxy_create_wrapper",
        ) orelse return null,
        .destroy_proxy = handle.lookup(*const DestroyProxy, "wl_proxy_destroy") orelse return null,
        .destroy_queue = handle.lookup(
            *const DestroyQueue,
            "wl_event_queue_destroy",
        ) orelse return null,
        .destroy_wrapper = handle.lookup(
            *const DestroyWrapper,
            "wl_proxy_wrapper_destroy",
        ) orelse return null,
        .flush = handle.lookup(*const Flush, "wl_display_flush") orelse return null,
        .marshal = handle.lookup(
            *const Marshal,
            "wl_proxy_marshal_array_flags",
        ) orelse return null,
        .registry_interface = handle.lookup(
            *const Interface,
            "wl_registry_interface",
        ) orelse return null,
        .roundtrip = handle.lookup(
            *const Roundtrip,
            "wl_display_roundtrip_queue",
        ) orelse return null,
        .set_queue = handle.lookup(*const SetQueue, "wl_proxy_set_queue") orelse return null,
        .surface_interface = handle.lookup(
            *const Interface,
            "wl_surface_interface",
        ) orelse return null,
        .version = handle.lookup(*const Version, "wl_proxy_get_version") orelse return null,
    };

    assert(std.mem.orderZ(u8, library.registry_interface.name, "wl_registry") == .eq);
    assert(std.mem.orderZ(u8, library.surface_interface.name, "wl_surface") == .eq);

    return library;
}

fn offer_record(
    data: ?*anyopaque,
    _: *Proxy,
    name: u32,
    interface: [*:0]const u8,
    version: u32,
) callconv(.c) void {
    assert(data != null);
    assert(std.mem.len(interface) <= message_bytes_max);

    if (name == 0) return;
    if (version < activation_version) return;
    if (std.mem.orderZ(u8, interface, activation_name) != .eq) return;

    const offer: *Offer = @ptrCast(@alignCast(data.?));

    offer.name = name;

    assert(offer.name != null);
}

fn offer_ignore(_: ?*anyopaque, _: *Proxy, _: u32) callconv(.c) void {}

fn activation_send(
    library: *const Library,
    registry: *Proxy,
    name: u32,
    surface: *Surface,
    token: [:0]const u8,
) void {
    assert(name > 0);
    assert(token.len > 0);
    assert(library.surface_interface.version > 0);

    const activate_types = [_]?*const Interface{ null, library.surface_interface };
    const token_types = [_]?*const Interface{null};

    const methods = [_]Message{
        .{ .name = "destroy", .signature = "", .types = &token_types },
        .{ .name = "get_activation_token", .signature = "n", .types = &token_types },
        .{ .name = "activate", .signature = "so", .types = &activate_types },
    };

    const interface: Interface = .{
        .name = activation_name,
        .version = activation_version,
        .method_count = methods.len,
        .methods = &methods,
        .event_count = 0,
        .events = null,
    };

    var bind = [_]Argument{
        .{ .unsigned = name },
        .{ .string = activation_name },
        .{ .unsigned = activation_version },
        .{ .object = null },
    };

    const activation = library.marshal(
        registry,
        registry_opcode_bind,
        &interface,
        activation_version,
        0,
        &bind,
    ) orelse return;

    var request = [_]Argument{ .{ .string = token.ptr }, .{ .object = surface } };
    var none = [_]Argument{.{ .object = null }};

    _ = library.marshal(
        activation,
        activation_opcode_activate,
        null,
        activation_version,
        0,
        &request,
    );

    _ = library.marshal(
        activation,
        activation_opcode_destroy,
        null,
        activation_version,
        marshal_flag_destroy,
        &none,
    );
}

const testing = std.testing;

test activate {
    const Activate = fn (*Display, *Surface, [:0]const u8) void;

    try testing.expect(@TypeOf(activate) == Activate);
}

test "the registry records only an activation offer the request can bind" {
    var offer: Offer = .{ .name = null };
    var byte: u8 = 0;

    const registry: *Proxy = @ptrCast(&byte);

    offer_record(&offer, registry, 7, "wl_compositor", 6);
    offer_record(&offer, registry, 9, "xdg_activation", 1);
    offer_record(&offer, registry, 11, activation_name, 0);
    offer_record(&offer, registry, 0, activation_name, 1);

    try testing.expectEqual(@as(?u32, null), offer.name);

    offer_record(&offer, registry, 12, activation_name, 1);

    try testing.expectEqual(@as(?u32, 12), offer.name);
}
