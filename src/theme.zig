const std = @import("std");

const dvui = @import("dvui");

const assert = std.debug.assert;

const Color = dvui.Color;
const Font = dvui.Font;
const Theme = dvui.Theme;

pub const Colors = struct {
    accent: Color,
    border: Color,
    control: Color,
    control_border: Color,
    control_hover: Color,
    control_press: Color,
    danger: Color,
    danger_fill_hover: Color,
    danger_fill_press: Color,
    danger_strong: Color,
    ink: Color,
    page: Color,
    palette_busy: Palette,
    palette_connected: Palette,
    palette_failure: Palette,
    palette_idle: Palette,
    palette_information: Palette,
    palette_unknown: Palette,
    primary: Color,
    primary_hover: Color,
    primary_press: Color,
    scrim: Color,
    surface: Color,
    text: Color,
    text_disabled: Color,
    text_muted: Color,
    text_soft: Color,
    text_strong: Color,
    track: Color,
    track_hover: Color,
    track_press: Color,
};

pub const Palette = struct {
    fill: Color,
    ring: Color,
    text: Color,
};

pub const Scheme = enum {
    dark,
    light,
};

const Tint = struct {
    base: Color,
    text: Color,
};

pub const amber_400 = Color.fromHex("#fbbf24");
pub const amber_500 = Color.fromHex("#f59e0b");
pub const amber_800 = Color.fromHex("#92400e");
pub const emerald_400 = Color.fromHex("#34d399");
pub const emerald_500 = Color.fromHex("#10b981");
pub const emerald_700 = Color.fromHex("#047857");
pub const indigo_300 = Color.fromHex("#8f9cff");
pub const indigo_400 = Color.fromHex("#5262ea");
pub const indigo_500 = Color.fromHex("#4353e6");
pub const indigo_600 = Color.fromHex("#3646d4");
pub const red_1 = Color.fromHex("#f66151");
pub const red_3 = Color.fromHex("#e01b24");
pub const red_4 = Color.fromHex("#c01c28");
pub const red_5 = Color.fromHex("#a51d2d");
pub const steel_10 = Color.fromHex("#16171c");
pub const steel_12 = Color.fromHex("#1c1d23");
pub const steel_14 = Color.fromHex("#1e2027");
pub const steel_15 = Color.fromHex("#22242b");
pub const steel_18 = Color.fromHex("#292b33");
pub const steel_19 = Color.fromHex("#2c2e36");
pub const steel_23 = Color.fromHex("#363841");
pub const steel_28 = Color.fromHex("#41434d");
pub const steel_32 = Color.fromHex("#4a4d57");
pub const steel_38 = Color.fromHex("#5b5e69");
pub const steel_39 = Color.fromHex("#5e606b");
pub const steel_4 = Color.fromHex("#08090c");
pub const steel_5 = Color.fromHex("#0a0b0e");
pub const steel_57 = Color.fromHex("#8a8d98");
pub const steel_60 = Color.fromHex("#91939f");
pub const steel_68 = Color.fromHex("#a4a9b6");
pub const steel_7 = Color.fromHex("#0f1014");
pub const steel_75 = Color.fromHex("#b9bdc8");
pub const steel_8 = Color.fromHex("#121318");
pub const steel_82 = Color.fromHex("#cccdd6");
pub const steel_83 = Color.fromHex("#cfd2da");
pub const steel_85 = Color.fromHex("#d4d7de");
pub const steel_89 = Color.fromHex("#dde0e7");
pub const steel_91 = Color.fromHex("#e4e6eb");
pub const steel_92 = Color.fromHex("#e8eaef");
pub const steel_94 = Color.fromHex("#edeef2");
pub const steel_96 = Color.fromHex("#f2f3f6");
pub const steel_97 = Color.fromHex("#f5f6f8");
pub const white = Color.white;
pub const snap_to_pixels = true;
pub const text_2xl = style(family_semibold, 17);
pub const text_sm = style(family_regular, 10);
pub const text_sm_medium = style(family_medium, 10);
pub const text_xl = style(family_semibold, 14);
pub const text_xs = style(family_regular, 9);
pub const text_xs_medium = style(family_medium, 9);

const colors_dark: Colors = .{
    .accent = indigo_300,
    .border = steel_14,
    .control = steel_10,
    .control_border = steel_18,
    .control_hover = steel_12,
    .control_press = steel_15,
    .danger = red_1,
    .danger_fill_hover = steel_7.lerp(red_3, 0.12),
    .danger_fill_press = steel_7.lerp(red_3, 0.2),
    .danger_strong = red_1,
    .ink = white,
    .page = steel_4,
    .palette_busy = tint(.{ .base = amber_500, .text = amber_400 }),
    .palette_connected = tint(.{ .base = emerald_500, .text = emerald_400 }),
    .palette_failure = tint(.{ .base = red_3, .text = red_1 }),
    .palette_idle = tint(.{ .base = steel_60, .text = steel_60 }),
    .palette_information = tint(.{ .base = emerald_500, .text = emerald_400 }),
    .palette_unknown = tint(.{ .base = red_3, .text = red_1 }),
    .primary = indigo_500,
    .primary_hover = indigo_400,
    .primary_press = indigo_600,
    .scrim = .{ .r = steel_4.r, .g = steel_4.g, .b = steel_4.b, .a = 160 },
    .surface = steel_7,
    .text = steel_94,
    .text_disabled = steel_39,
    .text_muted = steel_60,
    .text_soft = steel_82,
    .text_strong = white,
    .track = steel_19,
    .track_hover = steel_23,
    .track_press = steel_28,
};

const colors_light: Colors = .{
    .accent = indigo_600,
    .border = steel_91,
    .control = steel_96,
    .control_border = steel_85,
    .control_hover = steel_92,
    .control_press = steel_89,
    .danger = red_4,
    .danger_fill_hover = white.lerp(red_3, 0.12),
    .danger_fill_press = white.lerp(red_3, 0.2),
    .danger_strong = red_5,
    .ink = steel_5,
    .page = steel_97,
    .palette_busy = tint(.{ .base = amber_500, .text = amber_800 }),
    .palette_connected = tint(.{ .base = emerald_500, .text = emerald_700 }),
    .palette_failure = tint(.{ .base = red_3, .text = red_5 }),
    .palette_idle = tint(.{ .base = steel_60, .text = steel_32 }),
    .palette_information = tint(.{ .base = emerald_500, .text = emerald_700 }),
    .palette_unknown = tint(.{ .base = red_3, .text = red_4 }),
    .primary = indigo_500,
    .primary_hover = indigo_400,
    .primary_press = indigo_600,
    .scrim = .{ .r = steel_5.r, .g = steel_5.g, .b = steel_5.b, .a = 102 },
    .surface = white,
    .text = steel_8,
    .text_disabled = steel_57,
    .text_muted = steel_38,
    .text_soft = steel_18,
    .text_strong = steel_5,
    .track = steel_83,
    .track_hover = steel_75,
    .track_press = steel_68,
};

const family_medium = "Geist Medium";
const family_regular = "Geist";
const family_semibold = "Geist SemiBold";
const theme_name_prefix = "Solopass";

const fonts: []const Font.Source = &.{
    .{ .family = Font.array(family_medium), .bytes = @embedFile("font_medium") },
    .{ .family = Font.array(family_regular), .bytes = @embedFile("font_regular") },
    .{ .family = Font.array(family_semibold), .bytes = @embedFile("font_semibold") },
};

comptime {
    assert(fonts.len == 3);
    assert(text_xs.size < text_sm.size);
    assert(text_sm.size < text_xl.size);
    assert(text_xl.size < text_2xl.size);
    assert(colors_light.scrim.a < colors_dark.scrim.a);
}

pub fn colors_of(scheme: Scheme) *const Colors {
    const result = switch (scheme) {
        .dark => &colors_dark,
        .light => &colors_light,
    };

    assert(result.page.a == 255);
    assert(result.surface.a == 255);

    return result;
}

pub fn scheme_of(theme: *const Theme) Scheme {
    assert(std.mem.startsWith(u8, theme.name, theme_name_prefix));

    return if (theme.dark) .dark else .light;
}

pub fn theme_of(scheme: Scheme) Theme {
    const colors = colors_of(scheme);

    const result: Theme = .{
        .name = switch (scheme) {
            .dark => theme_name_prefix ++ " Dark",
            .light => theme_name_prefix ++ " Light",
        },
        .dark = scheme == .dark,
        .embedded_fonts = fonts,
        .font_body = text_sm,
        .font_heading = text_sm_medium,
        .font_title = text_xl,
        .font_mono = text_sm,
        .focus = colors.accent,
        .text_select = colors.primary.opacity(0.4),
        .fill = colors.surface,
        .fill_hover = colors.control,
        .fill_press = colors.control_hover,
        .text = colors.text,
        .border = colors.border,
        .corner = .round(8),
        .control = .{
            .fill = colors.control,
            .fill_hover = colors.control_hover,
            .fill_press = colors.control_press,
            .text = colors.text,
            .border = colors.control_border,
        },
        .window = .{ .fill = colors.page, .text = colors.text, .border = colors.border },
        .highlight = .{
            .fill = colors.primary,
            .fill_hover = colors.primary_hover,
            .fill_press = colors.primary_press,
            .text = white,
            .border = colors.primary,
        },
        .err = .{
            .fill = red_4,
            .fill_hover = red_3,
            .fill_press = red_5,
            .text = white,
            .border = red_4,
        },
    };

    assert(scheme_of(&result) == scheme);

    return result;
}

fn style(family: []const u8, size: f32) Font {
    assert(family.len > 0);
    assert(size > 0);
    assert(@floor(size) == size);

    return .find(.{ .family = family, .size = size });
}

fn tint(colors: Tint) Palette {
    assert(colors.base.a > 0);
    assert(colors.text.a > 0);

    const result: Palette = .{
        .fill = colors.base.opacity(0.1),
        .ring = colors.base.opacity(0.25),
        .text = colors.text,
    };

    assert(result.fill.a < result.ring.a);

    return result;
}

const testing = std.testing;

const Pair = struct {
    background: Color,
    foreground: Color,
};

const contrast_max: f64 = 21;
const fade_step_count: u32 = 64;
const luminance_weights = [3]f64{ 0.2126, 0.7152, 0.0722 };

fn contrast(pair: Pair) f64 {
    assert(pair.background.a == 255);
    assert(pair.foreground.a > 0);

    const top = luminance(blend(pair));
    const bottom = luminance(pair.background);
    const light = @max(top, bottom);
    const dark = @min(top, bottom);
    const result = (light + 0.05) / (dark + 0.05);

    assert(result >= 1);
    assert(result <= contrast_max);

    return result;
}

fn blend(pair: Pair) Color {
    assert(pair.background.a == 255);
    assert(pair.foreground.a > 0);

    const alpha = @as(f64, @floatFromInt(pair.foreground.a)) / 255.0;
    const above = [3]u8{ pair.foreground.r, pair.foreground.g, pair.foreground.b };
    const below = [3]u8{ pair.background.r, pair.background.g, pair.background.b };

    var channels: [3]u8 = undefined;

    for (above, below, &channels) |top, bottom, *blended| {
        const value = (@as(f64, @floatFromInt(top)) * alpha) +
            (@as(f64, @floatFromInt(bottom)) * (1.0 - alpha));

        blended.* = @intFromFloat(@round(value));

        assert(blended.* >= @min(top, bottom));
        assert(blended.* <= @max(top, bottom));
    }

    const result: Color = .{ .r = channels[0], .g = channels[1], .b = channels[2], .a = 255 };

    if (pair.foreground.a == 255) assert(std.meta.eql(result, pair.foreground));

    return result;
}

fn luminance(color: Color) f64 {
    assert(color.a == 255);

    const values = [3]u8{ color.r, color.g, color.b };

    var result: f64 = 0;

    for (luminance_weights, values) |weight, value| {
        result += weight * channel(@as(f64, @floatFromInt(value)) / 255.0);
    }

    assert(result >= 0);
    assert(result <= 1);

    return result;
}

fn channel(ratio: f64) f64 {
    assert(ratio >= 0);
    assert(ratio <= 1);

    const result = if (ratio <= 0.03928)
        ratio / 12.92
    else
        std.math.pow(f64, (ratio + 0.055) / 1.055, 2.4);

    assert(result >= 0);
    assert(result <= ratio);

    return result;
}

fn fade_stays_within(fade: Pair) bool {
    assert(fade.background.a == 255);
    assert(fade.foreground.a > 0);

    const settled = blend(fade);

    for (0..fade_step_count + 1) |step| {
        const amount = @as(f32, @floatFromInt(step)) / @as(f32, @floatFromInt(fade_step_count));
        const frame = fade.background.lerp(fade.foreground, amount);
        const shown = blend(.{ .background = fade.background, .foreground = frame });

        for (rgb(shown), rgb(fade.background), rgb(settled)) |value, start, end| {
            if (value < @min(start, end)) return false;
            if (value > @max(start, end)) return false;
        }
    }

    return true;
}

fn rgb(color: Color) [3]u8 {
    assert(color.a == 255);

    return .{ color.r, color.g, color.b };
}

test Colors {
    try testing.expect(colors_of(.dark).ink.r > colors_of(.light).ink.r);
}

test Palette {
    const palette = colors_of(.light).palette_failure;

    try testing.expect(palette.fill.a < palette.ring.a);
    try testing.expect(palette.ring.a < palette.text.a);
}

test Scheme {
    try testing.expect(colors_of(.dark) != colors_of(.light));
}

test colors_of {
    try testing.expect(colors_of(.dark).page.r < colors_of(.light).page.r);
}

test scheme_of {
    try testing.expectEqual(Scheme.light, scheme_of(&theme_of(.light)));
}

test theme_of {
    try testing.expect(theme_of(.dark).dark);
}

test "each scheme maps to a theme as dark as its page and back to itself" {
    for (std.enums.values(Scheme)) |scheme| {
        const colors = colors_of(scheme);
        const built = theme_of(scheme);
        const darker = luminance(colors.page) < luminance(colors.text);

        try testing.expectEqual(scheme, scheme_of(&built));
        try testing.expectEqual(darker, built.dark);
        try testing.expect(std.meta.eql(colors.page, built.window.fill.?));
        try testing.expect(std.meta.eql(colors.surface, built.fill));
    }
}

test "the reference contrast of black on white is 21" {
    const reference: Pair = .{ .background = Color.white, .foreground = Color.black };
    const flat: Pair = .{ .background = steel_7, .foreground = steel_7 };

    try testing.expectApproxEqAbs(@as(f64, 21.0), contrast(reference), 0.01);
    try testing.expectApproxEqAbs(@as(f64, 1.0), contrast(flat), 0.0001);
}

test "the contrast helpers agree with the sRGB reference values" {
    const veil: Color = .{ .r = 255, .g = 255, .b = 255, .a = 51 };
    const veiled = blend(.{ .background = Color.black, .foreground = veil });

    try testing.expectApproxEqAbs(@as(f64, 0.2140), channel(0.5), 0.0001);
    try testing.expectEqual(@as(f64, 1), luminance(Color.white));
    try testing.expectEqual(@as(f64, 0), luminance(Color.black));
    try testing.expect(std.meta.eql(Color{ .r = 51, .g = 51, .b = 51, .a = 255 }, veiled));
}

test "each text colour meets WCAG AA on the surface it sits on" {
    const ratio_min: f64 = 4.5;

    for (std.enums.values(Scheme)) |scheme| {
        const colors = colors_of(scheme);

        const pairs = [_]Pair{
            .{ .background = colors.page, .foreground = colors.text_strong },
            .{ .background = colors.surface, .foreground = colors.text_strong },
            .{ .background = colors.surface, .foreground = colors.text },
            .{ .background = colors.page, .foreground = colors.text_soft },
            .{ .background = colors.surface, .foreground = colors.text_muted },
            .{ .background = colors.page, .foreground = colors.text_muted },
            .{ .background = colors.primary, .foreground = white },
            .{ .background = colors.primary_hover, .foreground = white },
            .{ .background = colors.primary_press, .foreground = white },
            .{ .background = colors.control, .foreground = colors.text },
            .{ .background = colors.surface, .foreground = colors.danger },
            .{ .background = colors.page, .foreground = colors.danger_strong },
            .{ .background = colors.page, .foreground = colors.palette_connected.text },
            .{ .background = colors.page, .foreground = colors.palette_busy.text },
            .{ .background = colors.page, .foreground = colors.accent },
            .{ .background = colors.surface, .foreground = colors.accent },
        };

        for (pairs) |pair| {
            try testing.expect(contrast(pair) >= ratio_min);
        }
    }
}

test "each palette keeps its text legible on its own tint over the page" {
    const ratio_min: f64 = 4.5;

    for (std.enums.values(Scheme)) |scheme| {
        const colors = colors_of(scheme);

        const palettes = [_]Palette{
            colors.palette_busy,
            colors.palette_connected,
            colors.palette_failure,
            colors.palette_idle,
            colors.palette_information,
            colors.palette_unknown,
        };

        for (palettes) |palette| {
            const fill = blend(.{ .background = colors.page, .foreground = palette.fill });
            const pair: Pair = .{ .background = fill, .foreground = palette.text };

            try testing.expect(contrast(pair) >= ratio_min);
        }
    }
}

test "each hover and press fill fades without passing the colour it settles on" {
    for (std.enums.values(Scheme)) |scheme| {
        const colors = colors_of(scheme);

        const fades = [_]Pair{
            .{ .background = colors.control, .foreground = colors.control_hover },
            .{ .background = colors.control, .foreground = colors.control_press },
            .{ .background = colors.surface, .foreground = colors.danger_fill_hover },
            .{ .background = colors.surface, .foreground = colors.danger_fill_press },
            .{ .background = colors.primary, .foreground = colors.primary_hover },
            .{ .background = colors.primary, .foreground = colors.primary_press },
            .{ .background = colors.track, .foreground = colors.track_hover },
            .{ .background = colors.track, .foreground = colors.track_press },
        };

        for (fades) |fade| {
            try testing.expect(fade_stays_within(fade));
        }

        const translucent = red_3.opacity(0.12);
        const flashing: Pair = .{ .background = colors.surface, .foreground = translucent };

        try testing.expect(!fade_stays_within(flashing));
    }
}

test "the muted label of a disabled button stays legible on each surface it sits on" {
    const legible: f64 = 3.0;

    for (std.enums.values(Scheme)) |scheme| {
        const colors = colors_of(scheme);

        const pairs = [_]Pair{
            .{ .background = colors.page, .foreground = colors.text_disabled },
            .{ .background = colors.surface, .foreground = colors.text_disabled },
        };

        for (pairs) |pair| {
            try testing.expect(contrast(pair) >= legible);
        }
    }
}

test "each embedded font is a TrueType file" {
    for (fonts) |source| {
        try testing.expect(source.bytes.len > 1024);
        try testing.expectEqualSlices(u8, &.{ 0, 1, 0, 0 }, source.bytes[0..4]);
    }
}
