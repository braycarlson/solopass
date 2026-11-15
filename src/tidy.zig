const std = @import("std");

const Allocator = std.mem.Allocator;
const Ast = std.zig.Ast;
const assert = std.debug.assert;

const source_directories = [_][]const u8{"src"};

const extra_files = [_][]const u8{
    "build.zig",
    "build.zig.zon",
    "contrib/50-solopass.rules",
    "contrib/install.sh",
    "contrib/solopass.desktop",
};

const generated_paths = [_][]const u8{};
const test_registries = [_][]const u8{"src/unit_tests.zig"};
const entry_points = [_][]const u8{ "main.zig", "unit_tests.zig" };
const boundary_exempt = [_][]const u8{ "main.zig", "unit_tests.zig" };
const neutral_markers = [_][]const u8{"capa" ++ "bilities."};

const Ban = struct {
    needle: []const u8,
    replacement: []const u8,
};

const Location = struct {
    line: u32,
    path: []const u8,
};

const Lookup = struct {
    name: []const u8,
    text: []const u8,
};

const Mention = struct {
    count: u32,
    offset: u32,
};

const Span = struct {
    exempt: bool,
    first: u32,
    last: u32,
};

const SourceFile = struct {
    basename: []const u8,
    path: []const u8,
    text: []const u8,

    fn location_line(file: *const SourceFile, line: u32) Location {
        assert(line > 0);
        assert(file.path.len > 0);

        return .{ .line = line, .path = file.path };
    }

    fn location_offset(file: *const SourceFile, offset: usize) Location {
        assert(offset <= file.text.len);
        assert(file.path.len > 0);

        return .{ .line = line_of(file.text, offset), .path = file.path };
    }
};

const Step = struct {
    declaration: []const u8,
    line: []const u8,
};

const line_columns_max: u32 = 100;
const line_count_max: u32 = 8192;
const file_bytes_max: u32 = 16 * 1024 * 1024;
const file_count_max: u32 = 1024;
const functions_per_file_max: u32 = 1024;
const imports_per_file_max: u32 = 1024;
const function_lines_max: u32 = 70;
const function_marker = "fn ";
const import_marker = "@import(\"";
const type_suffix = "Type";
const assert_alias = "const assert = std.debug." ++ "assert;";
const assert_call = "assert(";
const catch_opener = "catch " ++ "{";

const banned = [_]Ban{
    .{ .needle = "== " ++ "error.", .replacement = "a switch, to avoid a silent anyerror upcast" },
    .{ .needle = "!= " ++ "error.", .replacement = "a switch, to avoid a silent anyerror upcast" },
    .{ .needle = "debug." ++ "assert(", .replacement = "an unqualified assert" },
    .{ .needle = "Self = " ++ "@This()", .replacement = "the type's own name" },
    .{ .needle = "!comp" ++ "time", .replacement = "! inside comptime" },
    .{ .needle = "using" ++ "namespace", .replacement = "an explicit declaration" },
    .{ .needle = "@c" ++ "Import", .replacement = "an explicit extern declaration" },
    .{ .needle = "catch " ++ "unreachable", .replacement = "an explicit error handler" },
    .{ .needle = "catch " ++ "{}", .replacement = "an explicit error handler" },
};

const leftover_markers = [_][]const u8{ "FIX" ++ "ME", "db" ++ "g(" };
const builtin_marker = "@import(\"buil" ++ "tin\")";
const linux_markers = [_][]const u8{ "std.po" ++ "six", "std.os." ++ "linux" };
const windows_markers = [_][]const u8{"std.os." ++ "windows"};
const guard_keywords = [_][]const u8{ "defer ", "errdefer " };
const breathing_keywords = [_][]const u8{ "return", "if ", "while ", "for ", "switch ", "try " };
const statement_openers = "({[";
const statement_closers = ")}]";
const prong_marker = "=>";

const block_keywords = [_][]const u8{
    ".",
    "comptime",
    "defer",
    "else",
    "errdefer",
    "export",
    "extern",
    "fn ",
    "for ",
    "if ",
    "inline",
    "pub ",
    "switch ",
    "test ",
    "while ",
};

const container_openers = [_][]const u8{ "enum {", "error {", "opaque {", "struct {", "union {" };

comptime {
    assert(line_columns_max == 100);
    assert(line_count_max > line_columns_max);
    assert(file_bytes_max > 0);
    assert(file_count_max > 0);
    assert(functions_per_file_max > 0);
    assert(imports_per_file_max > 0);
    assert(function_lines_max > 0);
    assert(source_directories.len > 0);
    assert(test_registries.len > 0);
    assert(entry_points.len > 0);
    assert(banned.len > 0);
    assert(leftover_markers.len > 0);
    assert(guard_keywords.len > 0);
    assert(breathing_keywords.len > 0);
    assert(block_keywords.len > 0);
    assert(container_openers.len > 0);
    assert(linux_markers.len > 0);
    assert(windows_markers.len > 0);
    assert(assert_alias.len > 0);
    assert(builtin_marker.len > 0);
    assert(function_marker.len == 3);
    assert(import_marker.len > 0);
    assert(type_suffix.len > 0);
    assert(prong_marker.len == 2);
    assert(statement_openers.len == statement_closers.len);
}

const Errors = struct {
    count: u32 = 0,
    echo: bool,

    fn add(errors: *Errors, location: Location, message: []const u8) void {
        assert(location.path.len > 0);
        assert(location.line > 0);
        assert(message.len > 0);

        errors.count += 1;

        if (errors.echo) {
            const values = .{ location.path, location.line, message };

            std.debug.print("{s}:{d}: error: {s}\n", values);
        }
    }

    fn add_format(
        errors: *Errors,
        location: Location,
        comptime format: []const u8,
        arguments: anytype,
    ) void {
        comptime assert(format.len > 0);
        comptime assert(@typeInfo(@TypeOf(arguments)) == .@"struct");

        assert(location.path.len > 0);
        assert(location.line > 0);

        errors.count += 1;

        if (errors.echo) {
            const values = .{ location.path, location.line } ++ arguments;

            std.debug.print("{s}:{d}: error: " ++ format ++ "\n", values);
        }
    }
};

const Lines = struct {
    items: [line_count_max][]const u8,
    count: u32,

    fn fill(self: *Lines, text: []const u8) void {
        assert(text.len <= file_bytes_max);

        self.count = 0;

        var iterator = std.mem.splitScalar(u8, text, '\n');

        for (&self.items) |*item| {
            item.* = iterator.next() orelse break;
            self.count += 1;
        }

        assert(self.count <= line_count_max);
    }

    fn get(self: *const Lines, index: u32) []const u8 {
        assert(self.count <= line_count_max);
        assert(index < self.count);

        return self.items[index];
    }
};

fn line_of(text: []const u8, offset: usize) u32 {
    assert(text.len <= file_bytes_max);
    assert(offset <= text.len);

    const line: u32 = @intCast(std.mem.count(u8, text[0..offset], "\n") + 1);

    assert(line <= offset + 1);

    return line;
}

fn line_columns(line: []const u8) u32 {
    assert(std.mem.findScalar(u8, line, '\n') == null);
    assert(line.len <= file_bytes_max);

    const columns: u32 = @intCast(std.unicode.utf8CountCodepoints(line) catch line.len);

    assert(columns <= line.len);

    return columns;
}

fn indent_of(line: []const u8) []const u8 {
    assert(std.mem.findScalar(u8, line, '\n') == null);
    assert(line.len <= file_bytes_max);

    const end = std.mem.findNone(u8, line, " \t") orelse line.len;
    return line[0..end];
}

fn trimmed_of(line: []const u8) []const u8 {
    assert(std.mem.findScalar(u8, line, '\n') == null);
    assert(line.len <= file_bytes_max);

    return std.mem.trim(u8, line, " \t\r");
}

fn is_blank(line: []const u8) bool {
    assert(std.mem.findScalar(u8, line, '\n') == null);
    assert(line.len <= file_bytes_max);

    return trimmed_of(line).len == 0;
}

fn is_guard(line: []const u8) bool {
    assert(std.mem.findScalar(u8, line, '\n') == null);
    assert(line.len <= file_bytes_max);

    const trimmed = trimmed_of(line);

    for (guard_keywords) |keyword| {
        if (std.mem.startsWith(u8, trimmed, keyword)) return true;
    }

    return false;
}

fn is_declaration(line: []const u8) bool {
    assert(std.mem.findScalar(u8, line, '\n') == null);
    assert(line.len <= file_bytes_max);

    const trimmed = trimmed_of(line);

    const opens = std.mem.startsWith(u8, trimmed, "const ") or
        std.mem.startsWith(u8, trimmed, "var ");

    if (!opens) {
        return false;
    }

    return std.mem.endsWith(u8, trimmed, ";");
}

fn is_control_flow(line: []const u8) bool {
    assert(std.mem.findScalar(u8, line, '\n') == null);
    assert(line.len <= file_bytes_max);

    const trimmed = trimmed_of(line);

    for (breathing_keywords) |keyword| {
        if (std.mem.startsWith(u8, trimmed, keyword)) return true;
    }

    return false;
}

fn opens_scope(line: []const u8) bool {
    assert(std.mem.findScalar(u8, line, '\n') == null);
    assert(line.len <= file_bytes_max);

    const trimmed = trimmed_of(line);

    if (trimmed.len == 0) {
        return false;
    }

    return std.mem.findScalar(u8, statement_openers, trimmed[trimmed.len - 1]) != null;
}

fn closes_scope(line: []const u8) bool {
    assert(std.mem.findScalar(u8, line, '\n') == null);
    assert(line.len <= file_bytes_max);

    const trimmed = trimmed_of(line);

    if (trimmed.len == 0) {
        return false;
    }

    return std.mem.findScalar(u8, statement_closers, trimmed[0]) != null;
}

fn opens_statement(line: []const u8) bool {
    assert(std.mem.findScalar(u8, line, '\n') == null);
    assert(line.len <= file_bytes_max);

    const trimmed = trimmed_of(line);
    if (trimmed.len == 0) return false;
    if (indent_of(line).len == 0) return false;
    if (!opens_scope(line)) return false;
    if (closes_scope(line)) return false;
    if (std.mem.find(u8, trimmed, prong_marker) != null) return false;

    for (block_keywords) |keyword| {
        if (std.mem.startsWith(u8, trimmed, keyword)) return false;
    }

    for (container_openers) |opener| {
        if (std.mem.endsWith(u8, trimmed, opener)) return false;
    }

    return true;
}

fn statement_end(lines: *const Lines, start: u32) ?u32 {
    assert(lines.count <= line_count_max);
    assert(start < lines.count);

    const indent = indent_of(lines.get(start));

    var index = start + 1;

    while (index < lines.count) : (index += 1) {
        assert(index > start);

        const line = lines.get(index);
        if (is_blank(line)) continue;

        const current = indent_of(line);
        if (current.len > indent.len) continue;
        if (current.len < indent.len) return null;
        if (!closes_scope(line)) return null;
        if (std.mem.endsWith(u8, trimmed_of(line), ";")) return index;
    }

    return null;
}

fn guard_is_crowded(lines: *const Lines, index: u32) bool {
    assert(index < lines.count);
    assert(is_guard(lines.get(index)));

    const line = lines.get(index);
    if (!std.mem.endsWith(u8, trimmed_of(line), ";")) return false;
    if (index + 1 >= lines.count) return false;

    const next = lines.get(index + 1);
    if (is_blank(next)) return false;
    if (is_guard(next)) return false;
    if (closes_scope(next)) return false;
    return std.mem.eql(u8, indent_of(next), indent_of(line));
}

fn statement_is_crowded_above(lines: *const Lines, start: u32) bool {
    assert(start < lines.count);
    assert(opens_statement(lines.get(start)));

    if (start == 0) return false;

    const above = lines.get(start - 1);
    return !(is_blank(above) or opens_scope(above) or is_guard(above));
}

fn statement_is_crowded_below(lines: *const Lines, end: u32) bool {
    assert(end < lines.count);
    assert(closes_scope(lines.get(end)));

    if (end + 1 >= lines.count) return false;

    const below = lines.get(end + 1);
    return !(is_blank(below) or closes_scope(below));
}

fn tidy_guards(errors: *Errors, path: []const u8, lines: *const Lines) void {
    assert(path.len > 0);
    assert(std.mem.endsWith(u8, path, ".zig"));

    var index: u32 = 0;

    while (index < lines.count) : (index += 1) {
        if (!is_guard(lines.get(index))) continue;

        if (guard_is_crowded(lines, index)) {
            const location: Location = .{ .line = index + 1, .path = path };

            errors.add(location, "guard needs a blank line before the next step");
        }
    }
}

fn tidy_isolation(errors: *Errors, path: []const u8, lines: *const Lines) void {
    assert(path.len > 0);
    assert(std.mem.endsWith(u8, path, ".zig"));

    var index: u32 = 0;

    while (index < lines.count) {
        if (!opens_statement(lines.get(index))) {
            index += 1;

            continue;
        }

        const end = statement_end(lines, index) orelse {
            index += 1;

            continue;
        };

        if (statement_is_crowded_above(lines, index)) {
            const above: Location = .{ .line = index + 1, .path = path };

            errors.add(above, "multi-line expression needs a blank line above");
        }

        if (statement_is_crowded_below(lines, end)) {
            const below: Location = .{ .line = end + 2, .path = path };

            errors.add(below, "multi-line expression needs a blank line below");
        }

        index = end + 1;
    }
}

fn tidy_breathing(errors: *Errors, path: []const u8, lines: *const Lines) void {
    assert(path.len > 0);
    assert(std.mem.endsWith(u8, path, ".zig"));

    var index: u32 = 1;

    while (index < lines.count) : (index += 1) {
        const previous = lines.get(index - 1);
        const line = lines.get(index);

        if (!is_declaration(previous)) continue;
        if (!is_control_flow(line)) continue;
        if (!std.mem.eql(u8, indent_of(previous), indent_of(line))) continue;
        if (guard_validates(.{ .declaration = previous, .line = line })) continue;
        if (return_is_fed(lines, index)) continue;

        const location: Location = .{ .line = index + 1, .path = path };

        errors.add(location, "declaration needs a blank line before the next step");
    }
}

fn guard_validates(step: Step) bool {
    assert(is_declaration(step.declaration));
    assert(is_control_flow(step.line));

    const trimmed = trimmed_of(step.line);
    if (!std.mem.startsWith(u8, trimmed, "if ")) return false;
    if (!std.mem.endsWith(u8, trimmed, ";")) return false;
    return mentions(.{ .name = declared_name(step.declaration), .text = trimmed });
}

fn return_is_fed(lines: *const Lines, index: u32) bool {
    assert(index > 0);
    assert(index < lines.count);

    const trimmed = trimmed_of(lines.get(index));
    if (!std.mem.startsWith(u8, trimmed, "return")) return false;

    if (index >= 2) {
        const above = lines.get(index - 2);

        if (!is_blank(above)) {
            if (!opens_scope(above)) return false;
        }
    }

    return mentions(.{ .name = declared_name(lines.get(index - 1)), .text = trimmed });
}

fn declared_name(declaration: []const u8) []const u8 {
    assert(is_declaration(declaration));

    const trimmed = trimmed_of(declaration);
    const prefix_length: u32 = if (std.mem.startsWith(u8, trimmed, "const ")) 6 else 4;
    const rest = trimmed[prefix_length..];

    var length: u32 = 0;

    for (rest) |byte| {
        if (!is_identifier_byte(byte)) break;

        length += 1;
    }

    assert(length <= rest.len);

    return rest[0..length];
}

fn mentions(lookup: Lookup) bool {
    assert(lookup.text.len <= file_bytes_max);

    for (lookup.name) |byte| {
        assert(is_identifier_byte(byte));
    }

    const text = lookup.text;
    const name = lookup.name;
    if (name.len == 0) return false;

    var start: u32 = 0;

    for (0..text.len) |_| {
        const found = std.mem.findPos(u8, text, start, name) orelse return false;
        const end = found + name.len;

        assert(end <= text.len);

        start = @intCast(found + 1);

        if (found > 0) {
            if (is_identifier_byte(text[found - 1])) continue;
        }

        if (end < text.len) {
            if (is_identifier_byte(text[end])) continue;
        }

        return true;
    }

    return false;
}

fn is_identifier_byte(byte: u8) bool {
    if (byte == '_') return true;
    return std.ascii.isAlphanumeric(byte);
}

fn tidy_control_characters(errors: *Errors, file: *const SourceFile) void {
    assert(file.text.len <= file_bytes_max);

    const offset = std.mem.findAny(u8, file.text, "\r\t") orelse return;

    assert(offset < file.text.len);

    const name = if (file.text[offset] == '\r') "carriage return" else "tab";

    errors.add_format(file.location_offset(offset), "control character: {s}", .{name});
}

fn tidy_banned(errors: *Errors, file: *const SourceFile) void {
    assert(file.text.len <= file_bytes_max);
    assert(file.path.len > 0);

    for (banned) |ban| {
        const offset = std.mem.find(u8, file.text, ban.needle) orelse continue;

        errors.add_format(file.location_offset(offset), "'{s}' is banned, use {s}", .{
            ban.needle,
            ban.replacement,
        });
    }

    for (leftover_markers) |marker| {
        const offset = std.mem.find(u8, file.text, marker) orelse continue;

        errors.add_format(file.location_offset(offset), "leftover '{s}', remove it", .{marker});
    }

    if (std.mem.find(u8, file.text, assert_call) == null) return;
    if (std.mem.find(u8, file.text, assert_alias) != null) return;

    const location = file.location_line(1);

    errors.add_format(location, "uses assert without declaring '{s}'", .{assert_alias});
}

fn tidy_catch_blocks(errors: *Errors, file: *const SourceFile) void {
    const catch_count_max = @divFloor(file.text.len, catch_opener.len);

    var catch_count: u32 = 0;
    var index: u32 = 0;

    while (std.mem.findPos(u8, file.text, index, catch_opener)) |found| {
        catch_count += 1;

        assert(catch_count <= catch_count_max);

        const opened = found + catch_opener.len;

        assert(opened <= file.text.len);

        index = @intCast(opened);

        const closed = std.mem.findScalarPos(u8, file.text, opened, '}') orelse continue;
        const body = std.mem.trim(u8, file.text[opened..closed], " \t\r\n");
        if (body.len > 0) continue;

        errors.add(file.location_offset(found), "empty catch block swallows the error");
    }
}

fn raw_literal_fits(line: []const u8) bool {
    assert(std.mem.findScalar(u8, line, '\n') == null);
    assert(line.len <= file_bytes_max);

    const marker = std.mem.find(u8, line, "\\\\") orelse return false;

    for (line[0..marker]) |byte| {
        if (byte != ' ') return false;
    }

    return line_columns(line[marker + 2 ..]) <= line_columns_max;
}

fn tidy_lines(errors: *Errors, file: *const SourceFile) void {
    assert(file.text.len <= file_bytes_max);

    const generated = is_generated(file.path);

    var lines = std.mem.splitScalar(u8, file.text, '\n');

    for (0..line_count_max + 1) |index| {
        const raw = lines.next() orelse break;

        assert(index <= file.text.len);

        const line = if (std.mem.endsWith(u8, raw, "\r")) raw[0 .. raw.len - 1] else raw;

        const location = file.location_line(@intCast(index + 1));

        if (std.mem.endsWith(u8, line, " ")) {
            errors.add(location, "trailing whitespace");
        }

        if (generated) continue;

        if (index == line_count_max) {
            errors.add_format(location, "file exceeds {d} lines", .{line_count_max});
        }

        if (line_columns(line) <= line_columns_max) continue;
        if (std.mem.find(u8, line, "https://") != null) continue;
        if (raw_literal_fits(line)) continue;

        errors.add_format(location, "line exceeds {d} columns", .{line_columns_max});
    }
}

fn tidy_type_functions(errors: *Errors, file: *const SourceFile) void {
    assert(file.text.len <= file_bytes_max);

    var lines = std.mem.splitScalar(u8, file.text, '\n');

    for (0..line_count_max + 1) |index| {
        const line = lines.next() orelse break;

        assert(index <= file.text.len);

        const found = std.mem.find(u8, line, function_marker) orelse continue;

        if (found > 0) {
            if (line[found - 1] != ' ') continue;
        }

        if (std.mem.find(u8, line, "extern \"") != null) continue;

        const rest = line[found + function_marker.len ..];
        const open = std.mem.findScalar(u8, rest, '(') orelse continue;
        const name = rest[0..open];
        if (name.len == 0) continue;
        if (!std.ascii.isUpper(name[0])) continue;
        if (std.mem.endsWith(u8, name, type_suffix)) continue;

        const location = file.location_line(@intCast(index + 1));

        errors.add_format(location, "type function '{s}' must end in '{s}'", .{
            name,
            type_suffix,
        });
    }
}

fn tidy_file_name(errors: *Errors, file: *const SourceFile) void {
    assert(file.basename.len > 0);
    assert(std.mem.endsWith(u8, file.path, file.basename));

    if (!std.mem.endsWith(u8, file.basename, ".zig")) {
        errors.add(file.location_line(1), "source file must end in .zig");

        return;
    }

    const stem = file.basename[0 .. file.basename.len - ".zig".len];

    if (stem.len == 0) {
        errors.add(file.location_line(1), "empty file name stem");

        return;
    }

    for (stem) |byte| {
        const lower = std.ascii.isLower(byte);
        const digit = std.ascii.isDigit(byte);

        if (lower) continue;
        if (digit) continue;
        if (byte == '_') continue;

        errors.add(file.location_line(1), "file name must be snake_case");

        return;
    }
}

fn is_boundary_exempt(basename: []const u8) bool {
    assert(std.mem.endsWith(u8, basename, ".zig"));
    assert(std.mem.findScalar(u8, basename, '/') == null);

    for (boundary_exempt) |name| {
        if (std.mem.eql(u8, basename, name)) return true;
    }

    return false;
}

fn is_entry_point(basename: []const u8) bool {
    assert(std.mem.endsWith(u8, basename, ".zig"));
    assert(std.mem.findScalar(u8, basename, '/') == null);

    for (entry_points) |name| {
        if (std.mem.eql(u8, basename, name)) return true;
    }

    return false;
}

fn is_generated(path: []const u8) bool {
    assert(path.len > 0);
    assert(path[0] != '/');

    for (generated_paths) |prefix| {
        if (std.mem.startsWith(u8, path, prefix)) return true;
    }

    return false;
}

fn report_marker(errors: *Errors, file: *const SourceFile, marker: []const u8) void {
    assert(marker.len > 0);
    assert(file.text.len <= file_bytes_max);

    const offset = std.mem.find(u8, file.text, marker) orelse return;

    errors.add_format(file.location_offset(offset), "'{s}' does not belong here", .{marker});
}

fn tidy_boundary(errors: *Errors, file: *const SourceFile) void {
    assert(file.basename.len > 0);
    assert(std.mem.endsWith(u8, file.path, file.basename));

    if (is_boundary_exempt(file.basename)) return;

    for (neutral_markers) |marker| {
        report_marker(errors, file, marker);
    }

    for (linux_markers) |marker| report_marker(errors, file, marker);
    for (windows_markers) |marker| report_marker(errors, file, marker);

    report_marker(errors, file, builtin_marker);
}

fn nested(spans: []const Span, index: usize) bool {
    assert(spans.len <= functions_per_file_max);
    assert(index < spans.len);

    const target = spans[index];

    for (spans, 0..) |span, other| {
        if (other == index) continue;
        if (span.first > target.first) continue;
        if (span.last >= target.last) return true;
    }

    return false;
}

fn returns_type(tree: *const Ast, node: Ast.Node.Index) bool {
    assert(tree.errors.len == 0);
    assert(tree.nodeTag(node) == .fn_decl);

    var buffer: [1]Ast.Node.Index = undefined;

    const proto = tree.fullFnProto(&buffer, node) orelse return false;
    const returned = proto.ast.return_type.unwrap() orelse return false;
    if (tree.nodeTag(returned) != .identifier) return false;
    return std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(returned)), "type");
}

fn tidy_function_lengths(errors: *Errors, tree: *const Ast, file: *const SourceFile) void {
    assert(tree.errors.len == 0);

    var spans: [functions_per_file_max]Span = undefined;
    var count: u32 = 0;

    for (tree.nodes.items(.tag), 0..) |tag, index| {
        if (tag != .fn_decl) continue;
        if (count == spans.len) break;

        const node: Ast.Node.Index = @fromBackingInt(@intCast(index));
        const body = tree.nodeData(node).node_and_node[1];

        spans[count] = .{
            .exempt = returns_type(tree, node),
            .first = @intCast(tree.tokenLocation(0, tree.firstToken(node)).line),
            .last = @intCast(tree.tokenLocation(0, tree.lastToken(body)).line),
        };

        count += 1;
    }

    for (spans[0..count], 0..) |span, index| {
        if (span.exempt) continue;
        if (nested(spans[0..count], index)) continue;

        assert(span.last >= span.first);

        const length = span.last - span.first + 1;
        if (length <= function_lines_max) continue;

        const location = file.location_line(span.first + 1);

        errors.add_format(location, "function spans {d} lines (max {d})", .{
            length,
            function_lines_max,
        });
    }
}

fn is_bin_op_bitwise(tree: *const Ast, node: Ast.Node.Index) bool {
    assert(tree.errors.len == 0);
    assert(@backingInt(node) < tree.nodes.len);

    return switch (tree.nodeTag(node)) {
        .shl, .shl_sat, .shr => true,
        .bit_and, .bit_or, .bit_xor => true,
        else => false,
    };
}

fn is_bin_op_arithmetic(tree: *const Ast, node: Ast.Node.Index) bool {
    assert(tree.errors.len == 0);
    assert(@backingInt(node) < tree.nodes.len);

    return switch (tree.nodeTag(node)) {
        .add, .add_sat, .add_wrap => true,
        .sub, .sub_sat, .sub_wrap => true,
        .mul, .mul_sat, .mul_wrap => true,
        .div, .mod => true,
        else => false,
    };
}

fn tidy_precedence(errors: *Errors, tree: *const Ast, file: *const SourceFile) void {
    assert(tree.errors.len == 0);
    assert(file.path.len > 0);

    for (0..tree.nodes.len) |index| {
        const node: Ast.Node.Index = @fromBackingInt(@intCast(index));
        const bitwise = is_bin_op_bitwise(tree, node);
        const arithmetic = is_bin_op_arithmetic(tree, node);

        if (!bitwise) {
            if (!arithmetic) continue;
        }

        const left, const right = tree.nodeData(node).node_and_node;

        for ([_]Ast.Node.Index{ left, right }) |child| {
            const mixed = (bitwise and is_bin_op_arithmetic(tree, child)) or
                (arithmetic and is_bin_op_bitwise(tree, child));

            if (!mixed) continue;

            const line: u32 = @intCast(tree.tokenLocation(0, tree.firstToken(node)).line);
            const location = file.location_line(line + 1);

            errors.add(location, "ambiguous operator precedence, add parentheses");
        }
    }
}

fn is_private_declaration(tree: *const Ast, token: Ast.TokenIndex) bool {
    assert(tree.errors.len == 0);
    assert(token < tree.tokens.len);

    if (token == 0) return false;

    const tags = tree.tokens.items(.tag);
    const keyword = tags[token - 1];

    switch (keyword) {
        .keyword_const, .keyword_fn => {},
        else => return false,
    }

    var offset: Ast.TokenIndex = 2;

    while (offset <= 4) : (offset += 1) {
        if (token < offset) return true;

        switch (tags[token - offset]) {
            .keyword_inline, .keyword_extern, .string_literal => {},
            .keyword_pub, .keyword_export => return false,
            .r_bracket, .r_paren, .asterisk => return false,
            else => return true,
        }
    }

    return false;
}

fn record_mention(
    arena: Allocator,
    counts: *std.StringHashMapUnmanaged(Mention),
    tree: *const Ast,
    token: Ast.TokenIndex,
) !void {
    assert(token < tree.tokens.len);
    assert(tree.tokens.items(.tag)[token] == .identifier);

    const name = tree.tokenSlice(token);
    const offset = tree.tokenStart(token);
    const entry = try counts.getOrPut(arena, name);

    if (!entry.found_existing) {
        entry.value_ptr.* = .{ .count = 1, .offset = offset };

        return;
    }

    const between = tree.source[entry.value_ptr.offset..offset];
    if (std.mem.findScalar(u8, between, '\n') == null) return;

    entry.value_ptr.count += 1;
    entry.value_ptr.offset = offset;
}

fn tidy_dead_declarations(
    arena: Allocator,
    errors: *Errors,
    tree: *const Ast,
    file: *const SourceFile,
) !void {
    assert(tree.errors.len == 0);

    var counts: std.StringHashMapUnmanaged(Mention) = .empty;
    defer counts.deinit(arena);

    const tags = tree.tokens.items(.tag);

    for (tags, 0..) |tag, index| {
        if (tag != .identifier) continue;

        try record_mention(arena, &counts, tree, @intCast(index));
    }

    for (tags, 0..) |tag, index| {
        if (tag != .identifier) continue;

        const token: Ast.TokenIndex = @intCast(index);
        const name = tree.tokenSlice(token);
        const mention = counts.get(name) orelse continue;

        assert(mention.count >= 1);

        if (mention.count != 1) continue;
        if (!is_private_declaration(tree, token)) continue;

        const line: u32 = @intCast(tree.tokenLocation(0, token).line);
        const location = file.location_line(line + 1);

        errors.add_format(location, "unused private declaration '{s}'", .{name});
    }
}

fn tidy_ast(arena: Allocator, errors: *Errors, file: *const SourceFile) !void {
    assert(file.text.len <= file_bytes_max);

    const source = try arena.dupeSentinel(u8, file.text, 0);

    var tree = try Ast.parse(arena, source, .{ .mode = .zig, .recover = true });
    defer tree.deinit(arena);

    assert(tree.source.len == file.text.len);

    if (tree.errors.len > 0) {
        errors.add(file.location_line(1), "file does not parse");

        return;
    }

    tidy_function_lengths(errors, &tree, file);
    tidy_precedence(errors, &tree, file);

    try tidy_dead_declarations(arena, errors, &tree, file);
}

fn tidy_text(arena: Allocator, errors: *Errors, file: *const SourceFile) !void {
    assert(file.path.len > 0);
    assert(file.text.len <= file_bytes_max);

    tidy_control_characters(errors, file);
    tidy_banned(errors, file);
    tidy_catch_blocks(errors, file);
    tidy_lines(errors, file);
    tidy_type_functions(errors, file);

    if (is_generated(file.path)) return;

    var buffer: Lines = undefined;

    buffer.fill(file.text);

    tidy_guards(errors, file.path, &buffer);
    tidy_isolation(errors, file.path, &buffer);
    tidy_breathing(errors, file.path, &buffer);

    try tidy_ast(arena, errors, file);
}

fn declares_tests(text: []const u8) bool {
    assert(text.len <= file_bytes_max);

    if (std.mem.startsWith(u8, text, "test ")) return true;
    return std.mem.find(u8, text, "\ntest ") != null;
}

fn find_source(sources: []const SourceFile, path: []const u8) ?*const SourceFile {
    assert(sources.len <= file_count_max);
    assert(path.len > 0);
    assert(std.mem.endsWith(u8, path, ".zig"));

    for (sources) |*source| {
        if (std.mem.eql(u8, source.path, path)) return source;
    }

    return null;
}

fn is_registered(sources: []const SourceFile, basename: []const u8) bool {
    assert(sources.len <= file_count_max);
    assert(std.mem.endsWith(u8, basename, ".zig"));

    for (test_registries) |path| {
        const registry = find_source(sources, path) orelse continue;
        if (imports_basename(.{ .name = basename, .text = registry.text })) return true;
    }

    return false;
}

fn imports_basename(lookup: Lookup) bool {
    assert(lookup.text.len <= file_bytes_max);
    assert(lookup.name.len > 0);

    const basename = lookup.name;
    const text = lookup.text;

    var index: u32 = 0;
    var guard: u32 = 0;

    while (std.mem.findPos(u8, text, index, import_marker)) |found| {
        guard += 1;

        assert(guard <= imports_per_file_max);

        const start = found + import_marker.len;
        const end = std.mem.findScalarPos(u8, text, start, '"') orelse return false;
        const path = text[start..end];

        index = @intCast(end);

        const tail = if (std.mem.findScalarLast(u8, path, '/')) |slash|
            path[slash + 1 ..]
        else
            path;

        if (std.mem.eql(u8, tail, basename)) return true;
    }

    return false;
}

fn imported_anywhere(sources: []const SourceFile, target: *const SourceFile) bool {
    assert(sources.len <= file_count_max);
    assert(find_source(sources, target.path) != null);

    for (sources) |*source| {
        if (std.mem.eql(u8, source.path, target.path)) continue;
        if (imports_basename(.{ .name = target.basename, .text = source.text })) return true;
    }

    return false;
}

fn tidy_imports(errors: *Errors, sources: []const SourceFile, file: *const SourceFile) void {
    assert(sources.len > 0);
    assert(sources.len <= file_count_max);

    if (is_entry_point(file.basename)) return;

    if (!imported_anywhere(sources, file)) {
        errors.add(file.location_line(1), "never imported by another file, dead file?");
    }

    if (declares_tests(file.text)) {
        if (!is_registered(sources, file.basename)) {
            errors.add(file.location_line(1), "declares tests but is missing from a test registry");
        }
    }
}

fn normalize(path: []u8) []u8 {
    assert(path.len > 0);

    for (path) |*byte| {
        if (byte.* == '\\') byte.* = '/';
    }

    assert(std.mem.findScalar(u8, path, '\\') == null);

    return path;
}

fn collect(
    arena: Allocator,
    io: std.Io,
    storage: []SourceFile,
    directories: []const []const u8,
) !u32 {
    assert(storage.len > 0);
    assert(directories.len > 0);

    var count: u32 = 0;

    for (directories) |directory| {
        var handle = try std.Io.Dir.cwd().openDir(io, directory, .{ .iterate = true });
        defer handle.close(io);

        var walker = try handle.walk(arena);
        defer walker.deinit();

        while (try walker.next(io)) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.basename, ".zig")) continue;

            try std.testing.expect(count < storage.len);

            const relative = normalize(try arena.dupe(u8, entry.path));

            const text = try entry.dir.readFileAlloc(
                io,
                entry.basename,
                arena,
                .limited(file_bytes_max),
            );

            storage[count] = .{
                .basename = try arena.dupe(u8, entry.basename),
                .path = try arena.print("{s}/{s}", .{ directory, relative }),
                .text = text,
            };

            count += 1;
        }
    }

    assert(count <= storage.len);

    return count;
}

fn tidy_extra_files(arena: Allocator, io: std.Io, errors: *Errors) !void {
    for (extra_files) |path| {
        const text = try std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(file_bytes_max));

        const file: SourceFile = .{
            .basename = std.Io.Dir.path.basename(path),
            .path = path,
            .text = text,
        };

        assert(file.text.len <= file_bytes_max);
        assert(file.basename.len > 0);

        if (std.mem.endsWith(u8, path, ".zig")) {
            try tidy_text(arena, errors, &file);

            continue;
        }

        tidy_control_characters(errors, &file);
        tidy_lines(errors, &file);
    }
}

test "tidy: sources obey the mechanical law" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    const arena = arena_state.allocator();
    const storage = try arena.alloc(SourceFile, file_count_max);
    const count = try collect(arena, io, storage, &source_directories);

    try std.testing.expect(count > 0);

    const sources = storage[0..count];

    var errors: Errors = .{ .echo = true };

    for (test_registries) |path| {
        if (find_source(sources, path) != null) continue;

        const location: Location = .{ .line = 1, .path = path };

        errors.add(location, "test registry is missing");
    }

    for (sources) |*source| {
        tidy_file_name(&errors, source);
        tidy_boundary(&errors, source);
        tidy_imports(&errors, sources, source);

        try tidy_text(arena, &errors, source);
    }

    try tidy_extra_files(arena, io, &errors);
    try std.testing.expectEqual(@as(u32, 0), errors.count);
}

test "tidy: a declaration breathes unless a guard validates it or a return it feeds follows" {
    const source =
        \\fn spaced() u32 {
        \\    const value = load();
        \\    if (value == 0) return 0;
        \\
        \\    const scaled = load();
        \\    if (ready()) return .{ .real = scaled };
        \\
        \\    const other = load();
        \\    if (ready()) return 0;
        \\
        \\    const first = load();
        \\    const second = load();
        \\    return first + second;
        \\}
        \\
        \\fn fed() u32 {
        \\    const raw = load();
        \\    return raw;
        \\}
        \\
        \\fn unfed() u32 {
        \\    const raw = load();
        \\    return other();
        \\}
    ;

    var lines: Lines = undefined;
    var errors: Errors = .{ .echo = false };

    lines.fill(source);
    tidy_breathing(&errors, "sample.zig", &lines);

    try std.testing.expectEqual(@as(u32, 3), errors.count);
}
