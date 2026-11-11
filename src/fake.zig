const std = @import("std");

const Twingate = @import("twingate.zig").Twingate;

const assert = std.debug.assert;

const Environ = std.process.Environ;

pub const Fake = struct {
    environment: Environ.Map,
    journalctl: Path,
    notifier: Path,
    pkexec: Path,
    root: Path,
    temporary: std.testing.TmpDir,
    twingate: Path,

    pub const File = enum {
        accounts,
        calls,
        deny,
        fail,
        hang,
        inventory,
        journal,
        journal_repeat,
        journalctl,
        levels,
        notifier,
        pkexec,
        prompt,
        resources,
        status,
        status_queue,
        twingate,

        pub fn name(file: File) []const u8 {
            return switch (file) {
                .accounts => "accounts.txt",
                .calls => "calls.log",
                .deny => "deny",
                .fail => "fail",
                .hang => "hang",
                .inventory => "inventory.json",
                .journal => "journal.txt",
                .journal_repeat => "journal.repeat",
                .journalctl => "journalctl",
                .levels => "levels.log",
                .notifier => "twingate-notifier",
                .pkexec => "pkexec",
                .prompt => "prompt.txt",
                .resources => "resources.txt",
                .status => "status.txt",
                .status_queue => "status.queue",
                .twingate => "twingate",
            };
        }
    };

    pub const InitError = Environ.CreateMapError ||
        std.Io.Dir.RealPathError ||
        std.Io.Dir.WriteFileError ||
        std.Io.Writer.Error;

    pub const ReadError = std.Io.Dir.ReadFileError;
    pub const WriteError = std.Io.Dir.WriteFileError;

    const Path = struct {
        bytes: [path_bytes_max]u8,
        length: u32,

        fn slice(path: *const Path) []const u8 {
            assert(path.length > 0);
            assert(path.length <= path_bytes_max);

            return path.bytes[0..path.length];
        }
    };

    pub fn init(fake: *Fake, io: std.Io) InitError!void {
        fake.environment = try std.testing.environ.createMap(std.testing.allocator);
        errdefer fake.environment.deinit();

        fake.temporary = std.testing.tmpDir(.{
            .access_sub_paths = true,
            .follow_symlinks = true,
            .iterate = false,
        });

        errdefer fake.temporary.cleanup();

        const root_length = try fake.temporary.dir.realPath(io, &fake.root.bytes);

        fake.root.length = @intCast(root_length);
        fake.journalctl = try fake.join(.journalctl);
        fake.notifier = try fake.join(.notifier);
        fake.pkexec = try fake.join(.pkexec);
        fake.twingate = try fake.join(.twingate);

        try fake.write(io, .journalctl, journalctl_script);
        try fake.write(io, .notifier, notifier_script);
        try fake.write(io, .pkexec, pkexec_script);
        try fake.write(io, .twingate, twingate_script);
        try fake.write(io, .accounts, "");
        try fake.write(io, .inventory, "{\"resources\":[]}\n");
        try fake.write(io, .journal, "");
        try fake.write(io, .resources, "");
        try fake.write(io, .status, "offline\n");

        assert(fake.root.length > 0);
        assert(fake.root.length < fake.journalctl.length);
        assert(fake.root.length < fake.notifier.length);
        assert(fake.root.length < fake.pkexec.length);
        assert(fake.root.length < fake.twingate.length);
    }

    pub fn deinit(fake: *Fake) void {
        assert(fake.root.length > 0);

        fake.temporary.cleanup();
        fake.environment.deinit();
    }

    pub fn paths(fake: *const Fake) Twingate.Paths {
        assert(fake.root.length > 0);

        return .{
            .journalctl = fake.journalctl.slice(),
            .notifier = fake.notifier.slice(),
            .pkexec = fake.pkexec.slice(),
            .twingate = fake.twingate.slice(),
        };
    }

    pub fn read(fake: *Fake, io: std.Io, file: File, buffer: []u8) ReadError![]const u8 {
        assert(buffer.len > 0);
        assert(fake.root.length > 0);

        return fake.temporary.dir.readFile(io, file.name(), buffer) catch |err| switch (err) {
            error.FileNotFound => return "",
            else => return err,
        };
    }

    pub fn write(fake: *Fake, io: std.Io, file: File, data: []const u8) WriteError!void {
        assert(data.len <= Twingate.output_bytes_max);
        assert(fake.root.length > 0);

        const permissions: std.Io.File.Permissions = switch (file) {
            .journalctl, .notifier, .pkexec, .twingate => .executable_file,
            .accounts, .calls, .deny, .fail, .hang, .inventory, .journal => .default_file,
            .journal_repeat, .levels, .prompt, .resources, .status, .status_queue => .default_file,
        };

        try fake.temporary.dir.writeFile(io, .{
            .data = data,
            .flags = .{ .permissions = permissions },
            .sub_path = file.name(),
        });
    }

    fn join(fake: *const Fake, file: File) std.Io.Writer.Error!Path {
        assert(fake.root.length > 0);

        var path: Path = .{ .bytes = undefined, .length = 0 };
        var writer: std.Io.Writer = .fixed(&path.bytes);

        try writer.print("{s}/{s}", .{ fake.root.slice(), file.name() });

        path.length = @intCast(writer.buffered().len);

        assert(path.length > fake.root.length);

        return path;
    }
};

const path_bytes_max: u32 = 1024;

const journalctl_script =
    \\#!/bin/sh
    \\here=$(dirname "$0")
    \\echo "journalctl $*" >> "$here/calls.log"
    \\if [ -f "$here/fail" ]; then echo "journalctl refused" >&2; exit 1; fi
    \\repeat=$(cat "$here/journal.repeat" 2>/dev/null || echo 1)
    \\while [ "$repeat" -gt 0 ]; do
    \\    cat "$here/journal.txt"
    \\    repeat=$((repeat - 1))
    \\done
    \\
;

const notifier_script =
    \\#!/bin/sh
    \\here=$(dirname "$0")
    \\echo "twingate-notifier $*" >> "$here/calls.log"
    \\echo "$* ${LOG_LEVEL-unset}" >> "$here/levels.log"
    \\if [ -f "$here/fail" ]; then echo "Twingate refused" >&2; exit 1; fi
    \\case "$1" in
    \\resources) cat "$here/inventory.json" ;;
    \\auth)
    \\    echo "Starting authentication for $2"
    \\    if [ -f "$here/prompt.txt" ]; then cp "$here/prompt.txt" "$here/status.txt"; fi
    \\    if [ -f "$here/hang" ]; then exec sleep 60; fi ;;
    \\*) echo "Done" ;;
    \\esac
    \\
;

const pkexec_script =
    \\#!/bin/sh
    \\here=$(dirname "$0")
    \\program=$(basename "$1")
    \\shift
    \\echo "pkexec $program $*" >> "$here/calls.log"
    \\if [ -f "$here/deny" ]; then exit 126; fi
    \\exec "$here/$program" "$@"
    \\
;

const twingate_script =
    \\#!/bin/sh
    \\here=$(dirname "$0")
    \\echo "twingate $*" >> "$here/calls.log"
    \\echo "$* ${LOG_LEVEL-unset}" >> "$here/levels.log"
    \\if [ -f "$here/fail" ]; then echo "Twingate refused" >&2; exit 3; fi
    \\case "$*" in
    \\"-d status")
    \\    if [ -s "$here/status.queue" ]; then
    \\        head -n 1 "$here/status.queue"
    \\        sed -i 1d "$here/status.queue"
    \\    else
    \\        cat "$here/status.txt"
    \\    fi ;;
    \\"-d account list") cat "$here/accounts.txt" ;;
    \\"-d account switch "*)
    \\    printf 'This will switch to the account %s. Are you sure? [y/N]: ' "$4"
    \\    if ! read -r answer || [ "$answer" != y ]; then echo EOF; exit 1; fi
    \\    echo "Starting Twingate service" ;;
    \\"-d resources") cat "$here/resources.txt" ;;
    \\*) echo "Done" ;;
    \\esac
    \\
;

const testing = std.testing;

test Fake {
    const io = testing.io;

    var fake: Fake = undefined;
    var buffer: [64]u8 = undefined;

    try fake.init(io);
    defer fake.deinit();

    try fake.write(io, .status, "online\n");

    const paths = fake.paths();

    try testing.expectEqualStrings("online\n", try fake.read(io, .status, &buffer));
    try testing.expectEqualStrings("", try fake.read(io, .calls, &buffer));
    try testing.expect(std.mem.endsWith(u8, paths.journalctl, "/journalctl"));
    try testing.expect(std.mem.endsWith(u8, paths.notifier, "/twingate-notifier"));
    try testing.expect(std.mem.endsWith(u8, paths.pkexec, "/pkexec"));
    try testing.expect(std.mem.endsWith(u8, paths.twingate, "/twingate"));
}

test "each file has a name of its own that the scripts spell" {
    for (std.enums.values(Fake.File), 0..) |file, index| {
        try testing.expect(file.name().len > 0);

        for (std.enums.values(Fake.File)[index + 1 ..]) |other| {
            try testing.expect(!std.mem.eql(u8, file.name(), other.name()));
        }

        const script = journalctl_script ++ notifier_script ++ pkexec_script ++ twingate_script;
        const spelled = std.mem.find(u8, script, file.name()) != null;

        try testing.expect(spelled);
    }
}
