const std = @import("std");

const Scheme = @import("theme.zig").Scheme;

const assert = std.debug.assert;

const Dir = std.Io.Dir;

pub const Appearance = struct {
    path: [path_bytes_max]u8,
    path_length: u32,

    pub const InitError = error{NameTooLong};
    pub const LoadError = error{ContentInvalid} || Dir.ReadFileError;
    pub const SaveError = Dir.CreateDirPathError || Dir.WriteFileError;

    pub const path_bytes_max: u32 = 1024;

    pub fn init(directory: []const u8) InitError!Appearance {
        assert(directory.len > 0);
        assert(directory[0] == '/');

        if (directory.len > path_bytes_max - file_suffix.len) return error.NameTooLong;

        const length: u32 = @intCast(directory.len + file_suffix.len);

        var appearance: Appearance = .{ .path = undefined, .path_length = length };

        @memcpy(appearance.path[0..directory.len], directory);
        @memcpy(appearance.path[directory.len..length], file_suffix);

        assert(std.mem.eql(u8, appearance.file_directory(), directory));
        assert(std.mem.endsWith(u8, appearance.file_path(), file_suffix));

        return appearance;
    }

    pub fn load(appearance: *const Appearance, io: std.Io) LoadError!Scheme {
        var buffer: [content_bytes_max]u8 = undefined;

        const content = try Dir.cwd().readFile(io, appearance.file_path(), &buffer);
        if (content.len == buffer.len) return error.ContentInvalid;

        const name = std.mem.trim(u8, content, " \t\r\n");
        const scheme = std.meta.stringToEnum(Scheme, name) orelse return error.ContentInvalid;
        const saved = render(scheme);

        assert(std.mem.eql(u8, saved[0 .. saved.len - 1], name));

        return scheme;
    }

    pub fn save(appearance: *const Appearance, io: std.Io, scheme: Scheme) SaveError!void {
        const content = render(scheme);

        assert(content.len < content_bytes_max);

        try Dir.cwd().createDirPath(io, appearance.file_directory());
        try Dir.cwd().writeFile(io, .{ .sub_path = appearance.file_path(), .data = content });
    }

    fn file_directory(appearance: *const Appearance) []const u8 {
        assert(appearance.path_length > file_suffix.len);
        assert(appearance.path_length <= path_bytes_max);

        return appearance.path[0 .. appearance.path_length - file_suffix.len];
    }

    fn file_path(appearance: *const Appearance) []const u8 {
        assert(appearance.path_length > file_suffix.len);
        assert(appearance.path_length <= path_bytes_max);

        return appearance.path[0..appearance.path_length];
    }
};

const content_bytes_max: u32 = 16;
const file_name = "appearance";
const file_suffix = "/" ++ file_name;

comptime {
    assert(file_suffix.len < Appearance.path_bytes_max);
    assert("light\n".len < content_bytes_max);
    assert("dark\n".len < content_bytes_max);
}

fn render(scheme: Scheme) []const u8 {
    const result = switch (scheme) {
        .dark => "dark\n",
        .light => "light\n",
    };

    assert(std.mem.endsWith(u8, result, "\n"));
    assert(std.meta.stringToEnum(Scheme, result[0 .. result.len - 1]).? == scheme);

    return result;
}

const testing = std.testing;

const temporary_options: Dir.OpenOptions = .{
    .access_sub_paths = true,
    .follow_symlinks = true,
    .iterate = false,
};

fn test_directory(temporary: *testing.TmpDir, buffer: *[Appearance.path_bytes_max]u8) ![]const u8 {
    const length = try temporary.dir.realPath(testing.io, buffer);

    assert(length > 0);

    return std.mem.print(buffer[length..], "{s}/solopass", .{buffer[0..length]});
}

test Appearance {
    const io = testing.io;

    var temporary = testing.tmpDir(temporary_options);
    defer temporary.cleanup();

    var buffer: [Appearance.path_bytes_max]u8 = undefined;

    const appearance: Appearance = try .init(try test_directory(&temporary, &buffer));

    try appearance.save(io, .light);

    try testing.expectEqual(Scheme.light, try appearance.load(io));
}

test "each scheme loads as it was saved, over a missing file and over the other scheme" {
    const io = testing.io;

    var temporary = testing.tmpDir(temporary_options);
    defer temporary.cleanup();

    var buffer: [Appearance.path_bytes_max]u8 = undefined;

    const appearance: Appearance = try .init(try test_directory(&temporary, &buffer));

    try testing.expectError(error.FileNotFound, appearance.load(io));

    for ([_]Scheme{ .dark, .light, .dark }) |scheme| {
        try appearance.save(io, scheme);
        try testing.expectEqual(scheme, try appearance.load(io));
    }
}

test "a file edited by hand loads through stray whitespace and refuses anything else" {
    const io = testing.io;

    var temporary = testing.tmpDir(temporary_options);
    defer temporary.cleanup();

    var buffer: [Appearance.path_bytes_max]u8 = undefined;

    const appearance: Appearance = try .init(try test_directory(&temporary, &buffer));

    try appearance.save(io, .dark);

    const padding: [content_bytes_max - "light".len]u8 = @splat(' ');

    const cases = [_]struct { content: []const u8, scheme: ?Scheme }{
        .{ .content = "light", .scheme = .light },
        .{ .content = "  dark \r\n", .scheme = .dark },
        .{ .content = "\tlight\t\n", .scheme = .light },
        .{ .content = "", .scheme = null },
        .{ .content = "\n", .scheme = null },
        .{ .content = "Dark\n", .scheme = null },
        .{ .content = "blue\n", .scheme = null },
        .{ .content = "light dark\n", .scheme = null },
        .{ .content = "lightish\n", .scheme = null },
        .{ .content = "light" ++ padding, .scheme = null },
    };

    for (cases) |case| {
        try Dir.cwd().writeFile(io, .{ .sub_path = appearance.file_path(), .data = case.content });

        if (case.scheme) |scheme| {
            try testing.expectEqual(scheme, try appearance.load(io));
        } else {
            try testing.expectError(error.ContentInvalid, appearance.load(io));
        }
    }
}

test "a directory fits only while the file path stays within its bound" {
    var directory: [Appearance.path_bytes_max]u8 = @splat('a');

    directory[0] = '/';

    const fitting = directory[0 .. Appearance.path_bytes_max - file_suffix.len];
    const appearance: Appearance = try .init(fitting);

    try testing.expectEqual(Appearance.path_bytes_max, appearance.path_length);
    try testing.expectEqualStrings(fitting, appearance.file_directory());
    try testing.expectError(error.NameTooLong, Appearance.init(directory[0 .. fitting.len + 1]));
    try testing.expectError(error.NameTooLong, Appearance.init(&directory));
}
