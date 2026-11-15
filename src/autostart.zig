const std = @import("std");

const assert = std.debug.assert;

const Dir = std.Io.Dir;

pub const Autostart = struct {
    directory_length: u32,
    path: [path_bytes_max]u8,
    path_length: u32,

    pub const DisableError = Dir.DeleteFileError;

    pub const EnableError = error{ExecutableUnsafe} ||
        Dir.CreateDirPathError ||
        Dir.WriteFileError;

    pub const InitError = error{NameTooLong};

    pub const path_bytes_max: u32 = 1024;

    pub fn init(directory: []const u8) InitError!Autostart {
        assert(directory.len > 0);
        assert(directory[0] == '/');

        if (directory.len > path_bytes_max - entry_suffix.len) return error.NameTooLong;

        const length: u32 = @intCast(directory.len + entry_suffix.len);

        var autostart: Autostart = .{
            .directory_length = @intCast(directory.len),
            .path = undefined,
            .path_length = length,
        };

        @memcpy(autostart.path[0..directory.len], directory);
        @memcpy(autostart.path[directory.len..length], entry_suffix);

        assert(std.mem.eql(u8, autostart.entry_directory(), directory));
        assert(std.mem.endsWith(u8, autostart.entry_path(), entry_suffix));

        return autostart;
    }

    pub fn disable(autostart: *const Autostart, io: std.Io) DisableError!void {
        const path = autostart.entry_path();

        assert(std.mem.endsWith(u8, path, entry_suffix));

        Dir.deleteFileAbsolute(io, path) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
    }

    pub fn enable(
        autostart: *const Autostart,
        io: std.Io,
        executable: []const u8,
    ) EnableError!void {
        if (!is_safe(executable)) return error.ExecutableUnsafe;

        var buffer: [entry_bytes_max]u8 = undefined;

        const entry = render(&buffer, executable);

        assert(entry.len > template.len);

        try Dir.cwd().createDirPath(io, autostart.entry_directory());
        try Dir.cwd().writeFile(io, .{ .sub_path = autostart.entry_path(), .data = entry });
    }

    pub fn is_enabled(autostart: *const Autostart, io: std.Io) bool {
        const path = autostart.entry_path();

        assert(std.mem.endsWith(u8, path, entry_suffix));

        Dir.accessAbsolute(io, path, .{ .follow_symlinks = true }) catch return false;

        return true;
    }

    fn entry_directory(autostart: *const Autostart) []const u8 {
        assert(autostart.directory_length > 0);
        assert(autostart.directory_length < autostart.path_length);

        return autostart.path[0..autostart.directory_length];
    }

    fn entry_path(autostart: *const Autostart) []const u8 {
        assert(autostart.path_length > autostart.directory_length);
        assert(autostart.path_length <= path_bytes_max);

        return autostart.path[0..autostart.path_length];
    }
};

const entry_bytes_max: u32 = 2048;
const entry_name = "solopass.desktop";
const entry_suffix = "/" ++ entry_name;
const safe_punctuation = "/._+-";

const template =
    \\[Desktop Entry]
    \\Type=Application
    \\Name=Solopass
    \\Comment=Twingate in the system tray
    \\Exec={s}
    \\Terminal=false
    \\X-GNOME-Autostart-enabled=true
    \\
;

comptime {
    assert(template.len + Autostart.path_bytes_max <= entry_bytes_max);
    assert(entry_suffix.len < Autostart.path_bytes_max);
}

fn is_safe(executable: []const u8) bool {
    if (executable.len < 2) return false;
    if (executable.len > Autostart.path_bytes_max) return false;
    if (executable[0] != '/') return false;

    for (executable) |byte| {
        if (std.ascii.isAlphanumeric(byte)) continue;
        if (std.mem.findScalar(u8, safe_punctuation, byte) != null) continue;

        return false;
    }

    return true;
}

fn render(buffer: *[entry_bytes_max]u8, executable: []const u8) []const u8 {
    assert(is_safe(executable));

    const entry = std.mem.print(buffer, template, .{executable}) catch |err| switch (err) {
        error.NoSpaceLeft => unreachable,
    };

    assert(std.mem.endsWith(u8, entry, "\n"));

    return entry;
}

const testing = std.testing;

const temporary_options: Dir.OpenOptions = .{
    .access_sub_paths = true,
    .follow_symlinks = true,
    .iterate = false,
};

fn test_directory(temporary: *testing.TmpDir, buffer: *[Autostart.path_bytes_max]u8) ![]const u8 {
    const length = try temporary.dir.realPath(testing.io, buffer);

    assert(length > 0);

    return std.mem.print(buffer[length..], "{s}/autostart", .{buffer[0..length]});
}

test Autostart {
    const io = testing.io;

    var temporary = testing.tmpDir(temporary_options);
    defer temporary.cleanup();

    var buffer: [Autostart.path_bytes_max]u8 = undefined;

    const autostart: Autostart = try .init(try test_directory(&temporary, &buffer));

    try autostart.enable(io, "/usr/bin/solopass");

    try testing.expect(autostart.is_enabled(io));
}

test "the entry runs the executable it was given" {
    var buffer: [entry_bytes_max]u8 = undefined;

    const entry = render(&buffer, "/opt/solopass/bin/solopass");
    const start = std.mem.find(u8, entry, "\nExec=").? + "\nExec=".len;
    const end = std.mem.findScalarPos(u8, entry, start, '\n').?;

    try testing.expectEqualStrings("/opt/solopass/bin/solopass", entry[start..end]);
    try testing.expect(std.mem.startsWith(u8, entry, "[Desktop Entry]\nType=Application\n"));
}

test "an enable writes the entry and a disable removes it twice over" {
    const io = testing.io;

    var temporary = testing.tmpDir(temporary_options);
    defer temporary.cleanup();

    var directory_buffer: [Autostart.path_bytes_max]u8 = undefined;
    var entry_buffer: [entry_bytes_max]u8 = undefined;
    var read_buffer: [entry_bytes_max]u8 = undefined;

    const directory = try test_directory(&temporary, &directory_buffer);
    const autostart: Autostart = try .init(directory);

    try testing.expect(!autostart.is_enabled(io));
    try autostart.enable(io, "/usr/local/bin/solopass");
    try testing.expect(autostart.is_enabled(io));

    const written = try Dir.cwd().readFile(io, autostart.entry_path(), &read_buffer);
    const expected = render(&entry_buffer, "/usr/local/bin/solopass");

    try testing.expectEqualStrings(expected, written);
    try autostart.disable(io);
    try testing.expect(!autostart.is_enabled(io));
    try autostart.disable(io);
}

test "an executable path that a desktop entry would misread is refused" {
    const io = testing.io;

    const unsafe = [_][]const u8{
        "",
        "/",
        "solopass",
        "./solopass",
        "/opt/my apps/solopass",
        "/opt/solopass %u",
        "/opt/solopass\nExec=/bin/sh",
        "/opt/solopass;reboot",
        "/opt/\"solopass\"",
    };

    const autostart: Autostart = try .init("/nonexistent");

    for (unsafe) |executable| {
        try testing.expect(!is_safe(executable));
        try testing.expectError(error.ExecutableUnsafe, autostart.enable(io, executable));
    }

    try testing.expect(is_safe("/home/user/.local/bin/solopass-0.1_x86+64"));
}

test "a directory fits only while the entry path stays within its bound" {
    var directory: [Autostart.path_bytes_max]u8 = @splat('a');

    directory[0] = '/';

    const fitting = directory[0 .. Autostart.path_bytes_max - entry_suffix.len];
    const autostart: Autostart = try .init(fitting);

    try testing.expectEqual(Autostart.path_bytes_max, autostart.path_length);
    try testing.expectError(error.NameTooLong, Autostart.init(directory[0 .. fitting.len + 1]));
    try testing.expectError(error.NameTooLong, Autostart.init(&directory));
}
