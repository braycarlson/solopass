const std = @import("std");

const Twingate = @import("twingate.zig").Twingate;

const assert = std.debug.assert;

const Allocator = std.mem.Allocator;

pub const Inventory = struct {
    resources: []const Resource = &.{},

    pub const Resource = struct {
        auth_expires_at: i64 = 0,
        auth_flow_id: []const u8 = "",
        auth_state: []const u8 = "",
        name: []const u8 = "",
    };

    pub const Verdict = union(enum) {
        empty,
        locked: []const u8,
        settled,
    };

    pub const ParseError = std.json.ParseError(std.json.Scanner);

    pub const scratch_bytes_max: u32 = 64 * 1024;

    pub fn parse(allocator: Allocator, text: []const u8) ParseError!Inventory {
        assert(text.len <= Twingate.output_bytes_max);

        const options: std.json.ParseOptions = .{ .ignore_unknown_fields = true };
        const inventory = try std.json.parseFromSliceLeaky(Inventory, allocator, text, options);

        assert(inventory.resources.len <= text.len);

        return inventory;
    }

    pub fn verdict(inventory: *const Inventory, now_seconds: i64) Verdict {
        assert(inventory.resources.len <= Twingate.output_bytes_max);

        if (inventory.resources.len == 0) return .empty;

        for (inventory.resources) |resource| {
            if (resource.auth_flow_id.len == 0) continue;
            if (!Twingate.is_resource(resource.name)) continue;
            if (inventory.settles(resource.auth_flow_id, now_seconds)) continue;

            return .{ .locked = resource.name };
        }

        return .settled;
    }

    fn settles(inventory: *const Inventory, flow: []const u8, now_seconds: i64) bool {
        assert(flow.len > 0);
        assert(inventory.resources.len > 0);

        for (inventory.resources) |resource| {
            if (!std.mem.eql(u8, resource.auth_flow_id, flow)) continue;
            if (std.mem.eql(u8, resource.auth_state, state_pending)) return true;
            if (resource.auth_expires_at > now_seconds) return true;
        }

        return false;
    }
};

const state_pending = "pending";

const testing = std.testing;

const flow_compute = "104620";
const flow_wiki = "104618";
const instant_seconds: i64 = 1_794_404_654;
const resource_count_max: u32 = 8;
const signed_seconds: i64 = 1_794_966_722;
const text_bytes_max: u32 = 4 * 1024;

const stringify_options: std.json.Stringify.Options = .{
    .emit_null_optional_fields = true,
    .emit_strings_as_arrays = false,
    .escape_unicode = false,
    .whitespace = .minified,
};

const listed =
    \\{"admin_url":"https://example.twingate.com","cas":[],"full_tunnel_time_limit":43200,
    \\"gateways":[],"internet_security":{"mode":1,"status":0},"network_name":"ExampleNet",
    \\"resources":[{"address":"10.10.0.0/16","admin_url":"https://example.twingate.com/r/1",
    \\"auth_expires_at":0,"auth_flow_id":"104620","auth_state":"none",
    \\"can_open_in_browser":true,"client_visibility":1,"global_id":"UmVzb3VyY2U6MQ==",
    \\"id":"1","metadata":{"gateway_id":"","resource_type":1},
    \\"name":"Lethbridge Compute Network","open_url":"","type":"ip"},
    \\{"address":"10.10.5.221","admin_url":"https://example.twingate.com/r/2",
    \\"auth_expires_at":0,"auth_flow_id":"104620","auth_state":"none",
    \\"can_open_in_browser":true,"client_visibility":1,"global_id":"UmVzb3VyY2U6Mg==",
    \\"id":"2","metadata":{"gateway_id":"","resource_type":1},
    \\"name":"Gpu Development LXC 1","open_url":"","type":"ip"}],
    \\"user":{"avatar_url":"","email":"avery.quinn@example.com","first_name":"Avery",
    \\"id":"7","is_admin":false,"last_name":"Quinn"}}
;

fn verdict_from(text: []const u8, now: i64) !Inventory.Verdict {
    assert(text.len > 0);
    assert(text.len <= Twingate.output_bytes_max);
    assert(now > 0);

    var scratch: [Inventory.scratch_bytes_max]u8 = undefined;
    var allocator: std.heap.FixedBufferAllocator = .init(&scratch);

    const inventory = try Inventory.parse(allocator.allocator(), text);

    return inventory.verdict(now);
}

fn verdict_of(resources: []const Inventory.Resource, now: i64) !Inventory.Verdict {
    assert(resources.len <= resource_count_max);
    assert(now > 0);

    var text: [text_bytes_max]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&text);

    const inventory: Inventory = .{ .resources = resources };

    try std.json.Stringify.value(inventory, stringify_options, &writer);

    return verdict_from(writer.buffered(), now);
}

fn expect_locked(expected: []const u8, verdict: Inventory.Verdict) !void {
    assert(expected.len > 0);

    try testing.expect(verdict == .locked);
    try testing.expectEqualStrings(expected, verdict.locked);
}

test Inventory {
    try expect_locked("Lethbridge Compute Network", try verdict_from(listed, instant_seconds));
}

test "a policy with one resource signed in or signing in settles every resource it covers" {
    const pending = [_]Inventory.Resource{
        .{ .auth_flow_id = flow_wiki, .auth_state = "pending", .name = "Wiki" },
        .{ .auth_flow_id = flow_wiki, .auth_state = "none", .name = "Grafana" },
    };

    const signed = [_]Inventory.Resource{
        .{ .auth_flow_id = flow_wiki, .auth_state = "none", .name = "Grafana" },
        .{
            .auth_expires_at = signed_seconds,
            .auth_flow_id = flow_wiki,
            .auth_state = "none",
            .name = "Wiki",
        },
    };

    try testing.expectEqual(Inventory.Verdict.settled, try verdict_of(&pending, instant_seconds));
    try testing.expectEqual(Inventory.Verdict.settled, try verdict_of(&signed, instant_seconds));
}

test "a sign-in that has expired locks its resources again" {
    const expired = [_]Inventory.Resource{
        .{
            .auth_expires_at = instant_seconds - 60,
            .auth_flow_id = flow_wiki,
            .auth_state = "none",
            .name = "Wiki",
        },
    };

    try expect_locked("Wiki", try verdict_of(&expired, instant_seconds));
}

test "a resource no policy protects never asks for a sign-in" {
    const unprotected = [_]Inventory.Resource{
        .{ .auth_state = "none", .name = "Wiki" },
        .{ .auth_state = "none", .name = "Grafana" },
    };

    const verdict = try verdict_of(&unprotected, instant_seconds);

    try testing.expectEqual(Inventory.Verdict.settled, verdict);
}

test "the first unsettled policy names its first resource the cli can pass as an argument" {
    const mixed = [_]Inventory.Resource{
        .{
            .auth_expires_at = signed_seconds,
            .auth_flow_id = flow_wiki,
            .auth_state = "none",
            .name = "Wiki",
        },
        .{ .auth_flow_id = flow_compute, .auth_state = "none", .name = "-h" },
        .{ .auth_flow_id = flow_compute, .auth_state = "none", .name = "Build cache" },
        .{ .auth_flow_id = flow_wiki, .auth_state = "none", .name = "Grafana" },
    };

    try expect_locked("Build cache", try verdict_of(&mixed, instant_seconds));
}

test "a list without resources is empty and output that is not the list is an error" {
    const none = [_]Inventory.Resource{};

    try testing.expectEqual(Inventory.Verdict.empty, try verdict_of(&none, instant_seconds));
    try testing.expectEqual(Inventory.Verdict.empty, try verdict_from("{}", instant_seconds));
    try testing.expectError(error.SyntaxError, verdict_from("not connected\n", instant_seconds));
    try testing.expectError(error.UnexpectedToken, verdict_from("[]", instant_seconds));
}

test "a written list reads back unchanged and its verdict holds for every policy" {
    const flows = [_][]const u8{ "", flow_wiki, flow_compute };
    const names = [_][]const u8{ "Wiki", "Grafana", "-h", "Lethbridge Compute Network" };
    const states = [_][]const u8{ "none", "pending" };
    const expiries = [_]i64{ 0, instant_seconds - 60, instant_seconds, instant_seconds + 60 };

    var prng = std.Random.DefaultPrng.init(0x5eed);
    var resources: [resource_count_max]Inventory.Resource = undefined;
    var text: [text_bytes_max]u8 = undefined;

    for (0..512) |_| {
        const random = prng.random();
        const count = random.uintAtMost(u32, resource_count_max);

        for (resources[0..count]) |*resource| {
            resource.* = .{
                .auth_expires_at = expiries[random.uintLessThan(u32, expiries.len)],
                .auth_flow_id = flows[random.uintLessThan(u32, flows.len)],
                .auth_state = states[random.uintLessThan(u32, states.len)],
                .name = names[random.uintLessThan(u32, names.len)],
            };
        }

        const written: Inventory = .{ .resources = resources[0..count] };

        var writer: std.Io.Writer = .fixed(&text);

        try std.json.Stringify.value(written, stringify_options, &writer);

        var scratch: [Inventory.scratch_bytes_max]u8 = undefined;
        var allocator: std.heap.FixedBufferAllocator = .init(&scratch);

        const read = try Inventory.parse(allocator.allocator(), writer.buffered());

        try testing.expectEqual(written.resources.len, read.resources.len);

        for (written.resources, read.resources) |expected, actual| {
            try testing.expectEqual(expected.auth_expires_at, actual.auth_expires_at);
            try testing.expectEqualStrings(expected.auth_flow_id, actual.auth_flow_id);
            try testing.expectEqualStrings(expected.auth_state, actual.auth_state);
            try testing.expectEqualStrings(expected.name, actual.name);
        }

        try expect_verdict_holds(&read, read.verdict(instant_seconds));
    }
}

fn expect_verdict_holds(inventory: *const Inventory, verdict: Inventory.Verdict) !void {
    assert(inventory.resources.len <= resource_count_max);

    try testing.expectEqual(inventory.resources.len == 0, verdict == .empty);

    for (inventory.resources, 0..) |resource, index| {
        if (resource.auth_flow_id.len == 0) continue;
        if (!Twingate.is_resource(resource.name)) continue;

        var covered = false;

        for (inventory.resources) |other| {
            if (!std.mem.eql(u8, other.auth_flow_id, resource.auth_flow_id)) continue;
            if (std.mem.eql(u8, other.auth_state, "pending")) covered = true;
            if (other.auth_expires_at > instant_seconds) covered = true;
        }

        if (covered) continue;

        try testing.expect(verdict == .locked);
        try testing.expectEqualStrings(resource.name, verdict.locked);
        try testing.expect(verdict.locked.ptr == inventory.resources[index].name.ptr);

        return;
    }

    if (inventory.resources.len > 0) try testing.expectEqual(Inventory.Verdict.settled, verdict);
}
