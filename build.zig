const std = @import("std");

const assert = std.debug.assert;

const Backend = enum {
    native,
    mock,
};

const format_paths = [_][]const u8{ "build.zig", "src" };

const Steps = struct {
    check: *std.Build.Step,
    continuous_integration: *std.Build.Step,
    run: *std.Build.Step,
    snapshot: *std.Build.Step,
    test_all: *std.Build.Step,
    test_format: *std.Build.Step,
    test_unit: *std.Build.Step,
};

const Context = struct {
    builder: *std.Build,
    filters: []const []const u8,
    optimize: std.lang.Optimize,
    snapshot_directory: []const u8,
    steps: Steps,
    target: std.Build.ResolvedTarget,
};

const Asset = struct {
    name: []const u8,
    path: []const u8,
};

const assets = [_]Asset{
    .{ .name = "busy.rgba", .path = "assets/busy.rgba" },
    .{ .name = "connected.rgba", .path = "assets/connected.rgba" },
    .{ .name = "disconnected.rgba", .path = "assets/disconnected.rgba" },
    .{ .name = "font_medium", .path = "assets/geist-medium.ttf" },
    .{ .name = "font_regular", .path = "assets/geist-regular.ttf" },
    .{ .name = "font_semibold", .path = "assets/geist-semibold.ttf" },
    .{ .name = "icon", .path = "assets/solopass-icon-256.png" },
};

const dvui_licenses = [_]Asset{
    .{ .name = "bitstream-vera-license.txt", .path = "src/fonts/bitstream-vera/COPYRIGHT.TXT" },
    .{ .name = "dvui-license.txt", .path = "LICENSE" },
};

const icon_sizes = [_]u32{ 16, 24, 32, 48, 64, 128, 256, 512 };
const snapshot_filters = [_][]const u8{"view.test."};

pub fn build(builder: *std.Build) void {
    const target = builder.standardTargetOptions(.{ .whitelist = null, .default_target = .{} });
    const optimize = builder.standardOptimizeOption(.{ .preferred_optimize_mode = null });

    const filters = builder.option(
        []const []const u8,
        "test-filter",
        "Skip tests that do not match any filter",
    ) orelse &.{};

    const snapshot_directory = builder.option(
        []const u8,
        "snapshot-dir",
        "Directory the snapshot step writes the window images to",
    ) orelse "zig-out/snapshots";

    assert(snapshot_directory.len > 0);

    const context = Context{
        .builder = builder,
        .filters = filters,
        .optimize = optimize,
        .snapshot_directory = snapshot_directory,
        .steps = .{
            .check = builder.step("check", "Compile every artifact without running it"),
            .continuous_integration = builder.step("ci", "Run every check and test"),
            .run = builder.step("run", "Build and run the application"),
            .snapshot = builder.step("snapshot", "Render the window states to PNG images"),
            .test_all = builder.step("test", "Run every test suite and the format check"),
            .test_format = builder.step("test:fmt", "Check that every source file is formatted"),
            .test_unit = builder.step("test:unit", "Run the unit tests and the tidy check"),
        },
        .target = target,
    };

    add_executable(context);
    add_unit_tests(context);
    add_snapshots(context);
    add_cross_check(context);
    add_format(context);

    builder.getInstallStep().dependOn(context.steps.check);
}

fn add_executable(context: Context) void {
    assert(context.steps.run != context.steps.check);
    assert(context.target.result.os.tag == .linux);

    const builder = context.builder;
    const dvui = window_dependency(context);
    const module = create_module(context, .native, "src/main.zig", dvui.module("dvui_sdl3"));
    const exe = builder.addExecutable(.{ .name = "solopass", .root_module = module });

    builder.installArtifact(exe);
    builder.installFile("contrib/50-solopass.rules", "share/polkit-1/rules.d/50-solopass.rules");
    builder.installFile("contrib/solopass.desktop", "share/applications/solopass.desktop");

    builder.installFile(
        "assets/solopass-icon.svg",
        "share/icons/hicolor/scalable/apps/solopass.svg",
    );

    for (icon_sizes) |size| {
        const source = builder.fmt("assets/solopass-icon-{d}.png", .{size});

        const target = builder.fmt(
            "share/icons/hicolor/{d}x{d}/apps/solopass.png",
            .{ size, size },
        );

        builder.installFile(source, target);
    }

    builder.installFile("assets/geist-license.txt", "share/licenses/solopass/geist-license.txt");

    for (dvui_licenses) |license| {
        const target = builder.fmt("share/licenses/solopass/{s}", .{license.name});
        const install = builder.addInstallFileWithDir(dvui.path(license.path), .prefix, target);

        builder.getInstallStep().dependOn(&install.step);
    }

    const run = builder.addRunArtifact(exe);

    run.step.dependOn(builder.getInstallStep());

    context.steps.run.dependOn(&run.step);
    context.steps.check.dependOn(&exe.step);
}

fn add_unit_tests(context: Context) void {
    assert(context.steps.test_unit != context.steps.test_all);
    assert(context.steps.continuous_integration != context.steps.test_unit);

    const builder = context.builder;

    const dvui = builder.dependency("dvui", .{
        .target = context.target,
        .optimize = context.optimize,
        .backend = .testing,
        .freetype = false,
    });

    const module = create_module(context, .mock, "src/unit_tests.zig", dvui.module("dvui_testing"));
    const unit = builder.addTest(.{ .root_module = module, .filters = context.filters });
    const run = builder.addRunArtifact(unit);

    run.has_side_effects = true;
    run.setCwd(builder.path("."));

    context.steps.test_unit.dependOn(&run.step);
    context.steps.test_all.dependOn(&run.step);
    context.steps.check.dependOn(&unit.step);
    context.steps.continuous_integration.dependOn(context.steps.test_unit);
}

fn add_snapshots(context: Context) void {
    assert(context.steps.snapshot != context.steps.check);
    assert(context.snapshot_directory.len > 0);

    const builder = context.builder;
    const dvui = window_dependency(context);
    const module = create_module(context, .mock, "src/view.zig", dvui.module("dvui_sdl3"));

    const snapshot = builder.addTest(.{
        .name = "snapshot",
        .root_module = module,
        .filters = &snapshot_filters,
    });

    const run = builder.addRunArtifact(snapshot);

    run.has_side_effects = true;
    run.setCwd(builder.path("."));

    context.steps.snapshot.dependOn(&run.step);
    context.steps.check.dependOn(&snapshot.step);
}

fn add_cross_check(context: Context) void {
    assert(context.steps.continuous_integration != context.steps.check);

    const builder = context.builder;
    const queries = [_]std.Target.Query{.{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .gnu }};

    for (queries) |query| {
        const resolved = builder.resolveTargetQuery(query);

        assert(resolved.result.os.tag == .linux);

        var scoped = context;

        scoped.target = resolved;

        const dvui = window_dependency(scoped);
        const module = create_module(scoped, .native, "src/main.zig", dvui.module("dvui_sdl3"));

        const exe = builder.addExecutable(.{
            .name = builder.fmt("solopass-{s}", .{@tagName(query.os_tag.?)}),
            .root_module = module,
        });

        context.steps.continuous_integration.dependOn(&exe.step);
    }
}

fn add_format(context: Context) void {
    assert(context.steps.test_format != context.steps.test_all);
    assert(context.steps.continuous_integration != context.steps.test_format);

    const builder = context.builder;
    const format = builder.addFmt(.{ .paths = builder.pathList(&format_paths), .check = true });

    context.steps.test_format.dependOn(&format.step);
    context.steps.test_all.dependOn(&format.step);
    context.steps.continuous_integration.dependOn(context.steps.test_format);
    context.steps.continuous_integration.dependOn(context.steps.check);
}

fn create_module(
    context: Context,
    backend: Backend,
    root: []const u8,
    dvui: *std.Build.Module,
) *std.Build.Module {
    assert(context.target.result.ptrBitWidth() >= 32);
    assert(std.mem.startsWith(u8, root, "src/"));
    assert(std.mem.endsWith(u8, root, ".zig"));

    const builder = context.builder;

    const umbra = builder.dependency("umbra", .{
        .target = context.target,
        .optimize = context.optimize,
        .backend = backend,
    });

    const module = builder.createModule(.{
        .root_source_file = builder.path(root),
        .target = context.target,
        .optimize = context.optimize,
    });

    module.addImport("dvui", dvui);
    module.addImport("umbra", umbra.module("umbra"));

    for (assets) |asset| {
        module.addAnonymousImport(asset.name, .{ .root_source_file = builder.path(asset.path) });
    }

    return module;
}

fn window_dependency(context: Context) *std.Build.Dependency {
    assert(context.snapshot_directory.len > 0);
    assert(context.target.result.ptrBitWidth() >= 32);

    return context.builder.dependency("dvui", .{
        .target = context.target,
        .optimize = context.optimize,
        .backend = .sdl3,
        .freetype = false,
        .@"image-dir" = context.snapshot_directory,
    });
}
