const std = @import("std");

const dvui = @import("dvui");

const Action = @import("action.zig").Action;
const Elapsed = @import("elapsed.zig").Elapsed;
const Snapshot = @import("snapshot.zig").Snapshot;
const Status = @import("status.zig").Status;
const Table = @import("table.zig").Table;
const theme = @import("theme.zig");
const Twingate = @import("twingate.zig").Twingate;

const assert = std.debug.assert;

const Color = dvui.Color;
const Options = dvui.Options;
const Palette = theme.Palette;
const Scheme = theme.Scheme;
const SourceLocation = std.lang.SourceLocation;

pub const View = struct {
    autostart: bool,
    connected_seconds: ?u64,
    log_open: bool,
    snapshot: *const Snapshot,

    pub const Choice = union(enum) {
        act: Action,
        autostart: bool,
        dismiss,
        log: bool,
        scheme: Scheme,
        sign_in,
        switch_account: u32,
    };

    pub const account_count_max: u32 = 8;

    pub fn frame(view: *const View) ?Choice {
        if (view.connected_seconds != null) assert(view.snapshot.status == .online);
        if (view.connected_seconds) |seconds| assert(seconds <= Elapsed.seconds_max);
        if (view.snapshot.resources_observed) assert(view.snapshot.status == .online);

        focus_track();

        const choice = page(view);
        if (!view.log_open) return choice;

        return log_modal(&view.snapshot.log);
    }
};

const Arc = struct {
    radius: f32,
    start: f32,
    sweep: f32,
};

const ButtonState = enum {
    busy,
    disabled,
    enabled,
};

const Measure = struct {
    height_laid: ?f32,
    height_natural: ?f32,
    resized: bool,
};

const Preference = struct {
    caption: []const u8,
    on: bool,
    tag: []const u8,
    title: []const u8,
};

const Reveal = struct {
    clip_previous: dvui.Rect.Physical,
    content: *dvui.BoxWidget,
    frame: *dvui.BoxWidget,
    height_shown: ?f32,
    id: dvui.Id,

    fn init(source: SourceLocation, style: Options) Reveal {
        assert(source.line > 0);
        assert(style.min_size_content == null);
        assert(style.max_size_content == null);

        const content_source = @src();
        const id = dvui.parentGet().extendId(source, style.idExtra());
        const content_id = id.extendId(content_source, 0);
        const content_size = dvui.minSizeGet(content_id);
        const height_natural: ?f32 = if (content_size) |size| size.h else null;
        const height_laid = dvui.dataGet(null, id, reveal_shown_key, f32);

        const measure: Measure = .{
            .height_laid = height_laid,
            .height_natural = height_natural,
            .resized = reveal_resized(id),
        };

        const height_shown = reveal_height(id, &measure);

        const bounds: Options = if (height_shown) |height| .{
            .min_size_content = .{ .h = height_laid orelse height },
            .max_size_content = .height(height),
        } else .{};

        const frame = dvui.box(source, box_vertical, style.override(bounds));

        assert(frame.data().id == id);

        const clip_previous = dvui.clip(frame.data().backgroundRectScale().r);

        const content = dvui.box(content_source, box_vertical, .{
            .expand = .horizontal,
            .rect = .{},
        });

        assert(content.data().id == content_id);

        return .{
            .clip_previous = clip_previous,
            .content = content,
            .frame = frame,
            .height_shown = height_shown,
            .id = id,
        };
    }

    fn deinit(reveal: *Reveal) void {
        const frame_data = reveal.frame.data();

        assert(reveal.id == frame_data.id);

        reveal.content.deinit();
        dvui.clipSet(reveal.clip_previous);

        if (reveal.height_shown) |height| {
            frame_data.minSizeMax(frame_data.options.padSize(.{ .h = height }));
            dvui.dataSet(null, reveal.id, reveal_shown_key, height);
        }

        dvui.dataSet(null, reveal.id, reveal_width_natural_key, frame_data.rect.w);
        reveal.frame.deinit();
    }
};

const Ripple = struct {
    alpha: f32,
    scale: f32,
};

const Variant = enum {
    danger,
    link,
    primary,
    secondary,
};

const box_horizontal: dvui.BoxWidget.InitOptions = .{ .dir = .horizontal };
const box_vertical: dvui.BoxWidget.InitOptions = .{ .dir = .vertical };
const connected_prefix = "Connected for ";
const describe_bytes_max: u32 = 160;
const detail_bytes_max: u32 = 512;
const focus_visible_key = "focus_visible";
const modal_margin: f32 = 16;
const page_padding_x: f32 = 24;
const ping_alpha_max: f32 = 0.75;
const ping_period_ms: u32 = 1000;
const ping_spread_fraction: f32 = 0.75;
const resource_count_max: u32 = 256;
const reveal_duration_us: i32 = 180 * std.time.us_per_ms;
const reveal_epsilon: f32 = 0.5;
const reveal_motion_key = "reveal_motion";
const reveal_shown_key = "reveal_shown";
const reveal_width_natural_key = "reveal_width_natural";
const reveal_width_shown_key = "reveal_width_shown";
const scrollbar_margin_x: f32 = 4;
const spin_period_ms: u32 = 1000;
const spinner_size: f32 = 14;
const spinner_thickness: f32 = 2;

const account_tags = [View.account_count_max][]const u8{
    "account-0",
    "account-1",
    "account-2",
    "account-3",
    "account-4",
    "account-5",
    "account-6",
    "account-7",
};

const button_base: Options = .{
    .font = theme.text_sm_medium,
    .corners = .round(8),
    .border = .all(1),
    .padding = .{ .x = 14, .y = 9, .w = 14, .h = 9 },
    .margin = .all(0),
};

const compact: Options = .{
    .font = theme.text_xs_medium,
    .padding = .{ .x = 10, .y = 5, .w = 10, .h = 5 },
};

comptime {
    assert(account_tags.len == View.account_count_max);
    assert(resource_count_max > View.account_count_max);
    assert(page_padding_x > scrollbar_margin_x);
    assert(modal_margin < page_padding_x);
    assert(ping_spread_fraction > 0);
    assert(ping_spread_fraction <= 1);
    assert(spinner_thickness < spinner_size);
    assert(connected_prefix.len + Elapsed.bytes_max + ".".len <= describe_bytes_max);
    assert(reveal_duration_us > 0);
    assert(reveal_epsilon > 0);
}

fn focus_track() void {
    const id = dvui.currentWindow().data().id;

    var visible = dvui.dataGet(null, id, focus_visible_key, bool) orelse false;

    for (dvui.events()) |event| {
        switch (event.evt) {
            .app, .text, .window => {},
            .key => |key| {
                if (key.code != .tab) continue;
                if (key.action == .up) continue;

                visible = true;
            },
            .mouse => |mouse| {
                if (mouse.action == .press) visible = false;
            },
        }
    }

    dvui.dataSet(null, id, focus_visible_key, visible);

    assert(focus_shown() == visible);
}

fn page(view: *const View) ?View.Choice {
    var root = dvui.box(@src(), box_vertical, .{
        .expand = .both,
        .background = true,
        .color_fill = .{ .color = colors_active().page },
        .padding = .{ .x = page_padding_x, .y = 22, .w = scrollbar_margin_x, .h = 0 },
    });

    defer root.deinit();

    header(view.snapshot);

    var scroll = dvui.scrollArea(@src(), .{ .vertical_bar = .auto_overlay }, .{
        .expand = .both,
        .background = false,
    });

    defer scroll.deinit();

    var column = dvui.box(@src(), box_vertical, .{
        .expand = .horizontal,
        .padding = .{ .w = page_padding_x - scrollbar_margin_x },
    });

    defer column.deinit();

    var choice: ?View.Choice = null;

    if (connection_card(view)) |picked| choice = picked;
    if (message_banner(view.snapshot)) |picked| choice = picked;
    if (accounts_section(view.snapshot)) |picked| choice = picked;
    if (resources_section(view.snapshot)) |picked| choice = picked;
    if (preferences_section(view.autostart)) |picked| choice = picked;
    if (choice) |picked| if (picked == .log) assert(picked.log);

    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .h = 24 } });

    return choice;
}

fn header(snapshot: *const Snapshot) void {
    if (!snapshot.observed) assert(snapshot.status == .unknown);

    var row = dvui.box(@src(), box_horizontal, .{
        .expand = .horizontal,
        .margin = .{ .w = page_padding_x - scrollbar_margin_x, .h = 18 },
    });

    defer row.deinit();

    label(@src(), "Solopass", brand().override(.{ .gravity_y = 0.5 }));
    badge(snapshot);
}

fn badge(snapshot: *const Snapshot) void {
    if (!snapshot.observed) assert(snapshot.tone() == .busy);

    const palette = palette_of(snapshot.tone());

    var pill = dvui.box(@src(), box_horizontal, .{
        .gravity_x = 1,
        .gravity_y = 0.5,
        .background = true,
        .color_fill = .{ .color = palette.fill },
        .border = .all(1),
        .color_border = .{ .color = palette.ring },
        .corners = .round(12),
        .padding = .{ .x = 9, .y = 4, .w = 11, .h = 4 },
    });

    defer pill.deinit();

    dot(palette.text, snapshot.progress() != null);

    label(@src(), headline(snapshot), .{
        .font = theme.text_xs_medium,
        .color_text = .{ .color = palette.text },
        .gravity_y = 0.5,
    });
}

fn dot(color: Color, pinging: bool) void {
    assert(color.a > 0);

    var circle = dvui.box(@src(), box_vertical, .{
        .min_size_content = .{ .w = 6, .h = 6 },
        .background = true,
        .color_fill = .{ .color = color },
        .corners = .round(3),
        .gravity_y = 0.5,
        .margin = .{ .w = 7 },
    });

    defer circle.deinit();

    if (!pinging) return;

    const ripple = ripple_at(dvui.frameTimeNS());
    const tinted = color.opacity(ripple.alpha);
    if (tinted.a == 0) return;

    assert(tinted.a <= color.a);

    const scaled = circle.data().contentRectScale();
    const radius = scaled.r.w / 2.0 * ripple.scale;
    if (radius <= 0) return;

    fill_circle(scaled.r.center(), radius, tinted);
}

fn ripple_at(nanoseconds: i128) Ripple {
    assert(nanoseconds >= 0);

    const phase: f32 = cycle_phase(nanoseconds, ping_period_ms);
    const spread = dvui.easing.outCubic(@min(phase / ping_spread_fraction, 1));
    const ripple: Ripple = .{ .alpha = ping_alpha_max * (1 - spread), .scale = 1 + spread };

    assert(ripple.alpha >= 0);
    assert(ripple.scale >= 1);

    return ripple;
}

fn connection_card(view: *const View) ?View.Choice {
    const status = view.snapshot.status;

    if (view.snapshot.sign_in_url() != null) assert(status == .authenticating or status == .online);

    var reveal: Reveal = .init(@src(), card());
    defer reveal.deinit();

    var buffer: [describe_bytes_max]u8 = undefined;
    var choice: ?View.Choice = null;

    if (connection_title()) choice = .{ .log = true };

    label(@src(), headline(view.snapshot), display());
    paragraph(@src(), describe(&buffer, view), caption().override(.{ .font = theme.text_sm }));

    if (sign_in(view.snapshot)) |picked| choice = picked;
    if (actions(view.snapshot)) |picked| choice = picked;

    return choice;
}

fn connection_title() bool {
    var row = dvui.box(@src(), box_horizontal, .{ .expand = .horizontal });
    defer row.deinit();

    label(@src(), "Connection", overline().override(.{ .gravity_y = 0.5 }));

    const options: Options = .{ .tag = "log", .gravity_x = 1, .gravity_y = 0.5 };

    return button(@src(), "Service log", .link, .enabled, options);
}

fn sign_in(snapshot: *const Snapshot) ?View.Choice {
    if (!snapshot.needs_sign_in()) return null;

    const options: Options = .{ .tag = "sign-in", .expand = .horizontal, .margin = .{ .y = 20 } };
    const state: ButtonState = if (snapshot.pending == null) .enabled else .disabled;
    const clicked = button(@src(), "Sign in to Twingate", .primary, state, options);

    if (clicked) assert(snapshot.pending == null);

    return if (clicked) .sign_in else null;
}

fn actions(snapshot: *const Snapshot) ?View.Choice {
    const gap: f32 = if (snapshot.needs_sign_in()) 12 else 20;

    var row = dvui.box(@src(), .{ .dir = .horizontal, .equal_space = true }, .{
        .expand = .horizontal,
        .margin = .{ .y = gap },
    });

    defer row.deinit();

    const idle = snapshot.pending == null;
    const progress = snapshot.progress();
    const stoppable = idle and snapshot.status.is_running();
    const toggle = Action.toggle(snapshot.status);
    const text = progress orelse toggle.label();
    const variant: Variant = if (progress != null or toggle == .connect) .primary else .secondary;
    const stop_state: ButtonState = if (stoppable) .enabled else .disabled;

    const toggle_state: ButtonState = if (progress != null)
        .busy
    else if (idle)
        .enabled
    else
        .disabled;

    var choice: ?View.Choice = null;

    const toggle_options: Options = .{
        .tag = "toggle",
        .expand = .horizontal,
        .margin = .{ .w = 5 },
    };

    const stop_options: Options = .{ .tag = "stop", .expand = .horizontal, .margin = .{ .x = 5 } };

    if (button(@src(), text, variant, toggle_state, toggle_options)) choice = .{ .act = toggle };
    if (button(@src(), "Stop service", .danger, stop_state, stop_options)) {
        choice = .{ .act = .stop };
    }

    if (choice != null) assert(idle);

    return choice;
}

fn message_banner(snapshot: *const Snapshot) ?View.Choice {
    var reveal: Reveal = .init(@src(), .{ .expand = .horizontal });
    defer reveal.deinit();

    const message = snapshot.message.text.slice();
    if (message.len == 0) return null;

    assert(message.len <= Snapshot.message_bytes_max);

    const colors = colors_active();

    const palette: Palette = switch (snapshot.message.kind) {
        .failure => colors.palette_failure,
        .information => colors.palette_information,
    };

    var banner = dvui.box(@src(), box_horizontal, .{
        .expand = .horizontal,
        .margin = .{ .y = 14 },
        .background = true,
        .color_fill = .{ .color = palette.fill },
        .border = .all(1),
        .color_border = .{ .color = palette.ring },
        .corners = .round(10),
        .padding = .{ .x = 14, .y = 8, .w = 6, .h = 8 },
    });

    defer banner.deinit();

    paragraph(@src(), message, .{
        .font = theme.text_sm,
        .color_text = .{ .color = palette.text },
        .gravity_y = 0.5,
    });

    const dismiss: Options = .{
        .tag = "dismiss",
        .gravity_y = 0.5,
        .color_text = .{ .color = palette.text },
        .color_text_hover = .{ .color = colors.ink },
        .color_text_press = .{ .color = colors.ink },
    };

    if (button(@src(), "Dismiss", .link, .enabled, dismiss)) return .dismiss;

    return null;
}

fn accounts_section(snapshot: *const Snapshot) ?View.Choice {
    section_title(@src(), "Accounts");

    var reveal: Reveal = .init(@src(), list());
    defer reveal.deinit();

    const accounts: Table = .init(snapshot.accounts.slice());
    const switchable = snapshot.pending == null and accounts.row_count() >= 2;

    var lines = accounts.lines();
    var choice: ?View.Choice = null;
    var drawn: u32 = 0;
    var rows: u32 = 0;

    for (0..lines.remaining) |_| {
        const line = lines.next() orelse break;
        if (line.kind == .header) continue;
        if (drawn == View.account_count_max) break;
        if (drawn > 0) divider(drawn);

        switch (line.kind) {
            .header => unreachable,
            .note => note_row(&line, drawn),
            .row => {
                if (account_row(&line, rows, switchable)) choice = .{ .switch_account = rows };

                rows += 1;
            },
        }

        drawn += 1;
    }

    assert(rows <= drawn);
    assert(drawn <= View.account_count_max);

    if (drawn == 0) empty_row(@src(), accounts_placeholder(snapshot));

    return choice;
}

fn accounts_placeholder(snapshot: *const Snapshot) []const u8 {
    if (snapshot.accounts_observed) return "No accounts yet. Connect to sign in.";

    assert(snapshot.accounts.length == 0);

    return "Reading the accounts\u{2026}";
}

fn account_row(line: *const Table.Line, index: u32, switchable: bool) bool {
    assert(line.kind == .row);
    assert(index < View.account_count_max);

    var row = dvui.box(@src(), box_horizontal, .{
        .expand = .horizontal,
        .padding = .{ .x = 16, .y = 12, .w = 14, .h = 12 },
        .id_extra = index,
    });

    defer row.deinit();

    var labels = dvui.box(@src(), box_vertical, .{ .expand = .horizontal, .gravity_y = 0.5 });

    label(@src(), line.cell(0), body());
    label(@src(), line.cell(1), caption());
    labels.deinit();

    if (line.is_current()) {
        label(@src(), "Current", caption().override(.{ .tag = "current", .gravity_y = 0.5 }));

        return false;
    }

    if (!switchable) return false;

    const options = compact.override(.{ .tag = account_tags[index], .gravity_y = 0.5 });

    return button(@src(), "Switch", .secondary, .enabled, options);
}

fn resources_section(snapshot: *const Snapshot) ?View.Choice {
    const online = snapshot.observed and snapshot.status == .online;
    const refreshable = online and snapshot.pending == null;

    var choice: ?View.Choice = null;

    if (section_title_action(@src(), "Resources", refreshable)) choice = .{ .act = .refresh };
    if (choice != null) assert(refreshable);

    var reveal: Reveal = .init(@src(), list());
    defer reveal.deinit();

    if (resources_placeholder(snapshot)) |placeholder| {
        empty_row(@src(), placeholder);

        return choice;
    }

    const resources: Table = .init(snapshot.resources.slice());

    var lines = resources.lines();
    var drawn: u32 = 0;

    for (0..lines.remaining) |_| {
        const line = lines.next() orelse break;
        if (line.kind == .header) continue;
        if (drawn == resource_count_max) break;
        if (drawn > 0) divider(drawn);

        resource_row(&line, drawn);
        drawn += 1;
    }

    assert(drawn <= resource_count_max);

    if (drawn == 0) empty_row(@src(), "No resources are shared with this account.");

    return choice;
}

fn resources_placeholder(snapshot: *const Snapshot) ?[]const u8 {
    if (!snapshot.resources_observed) assert(snapshot.resources.length == 0);

    if (snapshot.status != .online) return "Connect to see the resources you can reach.";
    if (!snapshot.resources_observed) return "Reading the resources you can reach\u{2026}";

    return null;
}

fn resource_row(line: *const Table.Line, index: u32) void {
    assert(line.kind != .header);
    assert(index < resource_count_max);

    if (line.kind == .note) {
        note_row(line, index);

        return;
    }

    var row = dvui.box(@src(), box_vertical, .{
        .expand = .horizontal,
        .padding = .{ .x = 16, .y = 11, .w = 16, .h = 11 },
        .id_extra = index,
    });

    defer row.deinit();

    var buffer: [detail_bytes_max]u8 = undefined;

    label(@src(), line.cell(0), body());
    label(@src(), join_details(&buffer, line), caption());
}

fn preferences_section(autostart: bool) ?View.Choice {
    section_title(@src(), "Preferences");

    var box = dvui.box(@src(), box_vertical, list());
    defer box.deinit();

    const dark = scheme_active() == .dark;

    const login: Preference = .{
        .caption = "Keep Solopass in the tray after you sign in.",
        .on = autostart,
        .tag = "autostart",
        .title = "Start at login",
    };

    const appearance: Preference = .{
        .caption = "Show this window in dark colours.",
        .on = dark,
        .tag = "dark",
        .title = "Dark mode",
    };

    var choice: ?View.Choice = null;

    if (preference_row(@src(), &login)) choice = .{ .autostart = !autostart };

    divider(1);

    if (preference_row(@src(), &appearance)) choice = .{ .scheme = if (dark) .light else .dark };

    return choice;
}

fn preference_row(source: SourceLocation, preference: *const Preference) bool {
    assert(source.line > 0);
    assert(preference.caption.len > 0);
    assert(preference.tag.len > 0);
    assert(preference.title.len > 0);

    var row = dvui.box(source, box_horizontal, .{
        .expand = .horizontal,
        .padding = .{ .x = 16, .y = 14, .w = 16, .h = 14 },
    });

    defer row.deinit();

    var labels = dvui.box(@src(), box_vertical, .{ .expand = .horizontal, .gravity_y = 0.5 });

    label(@src(), preference.title, body());
    label(@src(), preference.caption, caption());
    labels.deinit();

    return toggle_switch(preference.tag, preference.on);
}

fn toggle_switch(tag: []const u8, on: bool) bool {
    assert(tag.len > 0);

    const colors = colors_active();
    var track: dvui.ButtonWidget = undefined;

    track.init(@src(), .{ .draw_focus = focus_shown() }, .{
        .tag = tag,
        .gravity_y = 0.5,
        .min_size_content = .{ .w = 40, .h = 20 },
        .padding = .all(2),
        .margin = .{ .x = 12 },
        .border = .all(0),
        .corners = .round(12),
        .color_fill = .{ .color = if (on) colors.primary else colors.track },
        .color_fill_hover = .{ .color = if (on) colors.primary_hover else colors.track_hover },
        .color_fill_press = .{ .color = if (on) colors.primary_press else colors.track_press },
    });

    track.processEvents();
    track.drawBackground();

    var knob = dvui.box(@src(), box_vertical, .{
        .min_size_content = .{ .w = 20, .h = 20 },
        .gravity_x = if (on) 1 else 0,
        .gravity_y = 0.5,
        .background = true,
        .color_fill = .{ .color = theme.white },
        .corners = .round(10),
    });

    knob.deinit();
    track.drawFocus();

    const clicked = track.clicked();

    track.deinit();

    return clicked;
}

fn log_modal(log: *const Snapshot.Log) ?View.Choice {
    const reading = log.reading();
    const scrim = colors_active().scrim;
    const options = card().override(.{ .color_text = .{ .color = scrim } });

    var rect: dvui.Rect = .cast(dvui.windowRect().insetAll(modal_margin));

    var modal = dvui.floatingWindow(
        @src(),
        .{
            .modal = true,
            .modal_alpha = scrim.a,
            .rect = &rect,
            .resize = .none,
        },
        options,
    );

    defer modal.deinit();

    modal.dragAreaSet(.{ .x = 0, .y = 0, .w = 0, .h = 0 });

    var choice = log_header(reading);

    log_entries(log.text.slice(), reading);

    if (escape_pressed(modal)) choice = .{ .log = false };
    if (choice) |picked| assert(picked == .log);

    return choice;
}

fn log_header(reading: bool) ?View.Choice {
    var row = dvui.box(@src(), box_horizontal, .{ .expand = .horizontal, .margin = .{ .h = 16 } });
    defer row.deinit();

    var titles = dvui.box(@src(), box_vertical, .{ .expand = .horizontal, .gravity_y = 0.5 });

    label(@src(), "Service log", brand());
    label(@src(), "Newest first, from the twingate.service journal.", caption());
    titles.deinit();

    const refresh: Options = .{ .tag = "log-refresh", .gravity_y = 0.5 };
    const close: Options = .{ .tag = "log-close", .gravity_y = 0.5 };
    const state: ButtonState = if (reading) .busy else .enabled;

    var choice: ?View.Choice = null;

    if (button(@src(), "Refresh", .link, state, refresh)) choice = .{ .log = true };
    if (button(@src(), "Close", .link, .enabled, close)) choice = .{ .log = false };
    if (reading) assert(choice == null or !choice.?.log);

    return choice;
}

fn log_entries(text: []const u8, reading: bool) void {
    assert(text.len <= Twingate.journal_bytes_max);

    const colors = colors_active();

    var panel = dvui.box(@src(), box_vertical, .{
        .expand = .both,
        .background = true,
        .color_fill = .{ .color = colors.page },
        .border = .all(1),
        .color_border = .{ .color = colors.border },
        .corners = .round(8),
    });

    defer panel.deinit();

    var scroll = dvui.scrollArea(@src(), .{ .vertical_bar = .auto_overlay }, .{
        .expand = .both,
        .background = false,
    });

    defer scroll.deinit();

    const padding: dvui.Rect = .all(12);

    if (text.len > 0) {
        paragraph(@src(), text, entry().override(.{ .padding = padding }));

        return;
    }

    const placeholder = if (reading)
        "Reading the log\u{2026}"
    else
        "The Twingate service has not logged anything.";

    paragraph(@src(), placeholder, caption().override(.{ .padding = padding }));
}

fn escape_pressed(modal: *dvui.FloatingWindowWidget) bool {
    assert(modal.init_options.modal);

    for (dvui.events()) |*event| {
        if (event.handled) continue;

        switch (event.evt) {
            .key => |key| {
                if (key.code != .escape) continue;
                if (key.action != .down) continue;

                event.handle(@src(), modal.data());

                return true;
            },
            .app, .mouse, .text, .window => {},
        }
    }

    return false;
}

fn button(
    source: SourceLocation,
    text: []const u8,
    variant: Variant,
    state: ButtonState,
    extra: Options,
) bool {
    assert(source.line > 0);
    assert(text.len > 0);
    assert(extra.tag != null);

    const enabled = state == .enabled;

    const muted: ?Color = switch (state) {
        .busy, .enabled => null,
        .disabled => switch (variant) {
            .danger, .link => colors_active().text_disabled,
            .primary, .secondary => null,
        },
    };

    const reachable: Options = if (enabled) .{} else .{ .tab_index = 0 };
    const quiet: Options = if (muted) |color| .{ .color_text = .{ .color = color } } else .{};
    const options = variant_options(variant).override(extra).override(reachable).override(quiet);
    const grayed = state == .disabled and muted == null;

    var widget: dvui.ButtonWidget = undefined;

    widget.init(source, .{ .draw_focus = focus_shown(), .grayed = grayed }, options);

    if (enabled) widget.processEvents();

    widget.drawBackground();

    const content = options.strip().override(widget.style());

    var row = dvui.box(@src(), box_horizontal, .{ .gravity_x = 0.5, .gravity_y = 0.5 });

    if (state == .busy) spinner(content.color(.text).toColor());

    dvui.labelNoFmt(@src(), text, .{ .ellipsize = true }, content.override(.{ .gravity_y = 0.5 }));
    row.deinit();

    if (enabled) widget.drawFocus();

    const clicked = widget.clicked();

    widget.deinit();

    if (clicked) assert(enabled);

    return clicked;
}

fn focus_shown() bool {
    const id = dvui.currentWindow().data().id;
    return dvui.dataGet(null, id, focus_visible_key, bool) orelse false;
}

fn spinner(color: Color) void {
    assert(color.a > 0);

    var box = dvui.box(@src(), box_vertical, .{
        .min_size_content = .{ .w = spinner_size, .h = spinner_size },
        .gravity_y = 0.5,
        .margin = .{ .w = 8 },
    });

    defer box.deinit();

    const scaled = box.data().contentRectScale();
    const thickness = spinner_thickness * scaled.s;
    const radius = (@min(scaled.r.w, scaled.r.h) - thickness) / 2.0;
    if (radius <= 0) return;

    const center = scaled.r.center();
    const head = spin_angle(dvui.frameTimeNS());
    const ring: Arc = .{ .radius = radius, .start = 0, .sweep = std.math.tau };
    const sweep: Arc = .{ .radius = radius, .start = head, .sweep = std.math.pi / 2.0 };

    stroke_arc(center, ring, .{
        .thickness = thickness,
        .color = .{ .color = color.opacity(0.25) },
        .closed = true,
    });

    stroke_arc(center, sweep, .{
        .thickness = thickness,
        .color = .{ .color = color },
        .closed = false,
    });
}

fn variant_options(variant: Variant) Options {
    const colors = colors_active();

    const options: Options = switch (variant) {
        .danger => .{
            .color_fill = .{ .color = colors.surface },
            .color_fill_hover = .{ .color = colors.danger_fill_hover },
            .color_fill_press = .{ .color = colors.danger_fill_press },
            .color_text = .{ .color = colors.danger },
            .color_text_hover = .{ .color = colors.danger_strong },
            .color_text_press = .{ .color = colors.danger_strong },
            .color_border = .{ .color = colors.control_border },
        },
        .link => .{
            .font = theme.text_xs_medium,
            .padding = .{ .x = 8, .y = 4, .w = 8, .h = 4 },
            .border = .all(0),
            .color_fill = .{ .color = Color.transparent },
            .color_fill_hover = .{ .color = colors.ink.opacity(0.06) },
            .color_fill_press = .{ .color = colors.ink.opacity(0.1) },
            .color_text = .{ .color = colors.accent },
            .color_text_hover = .{ .color = colors.accent },
            .color_text_press = .{ .color = colors.accent },
        },
        .primary => .{
            .color_fill = .{ .color = colors.primary },
            .color_fill_hover = .{ .color = colors.primary_hover },
            .color_fill_press = .{ .color = colors.primary_press },
            .color_text = .{ .color = theme.white },
            .color_text_hover = .{ .color = theme.white },
            .color_text_press = .{ .color = theme.white },
            .color_border = .{ .color = colors.primary },
        },
        .secondary => .{
            .color_fill = .{ .color = colors.control },
            .color_fill_hover = .{ .color = colors.control_hover },
            .color_fill_press = .{ .color = colors.control_press },
            .color_text = .{ .color = colors.text },
            .color_text_hover = .{ .color = colors.text_strong },
            .color_text_press = .{ .color = colors.text_strong },
            .color_border = .{ .color = colors.control_border },
        },
    };

    const result = button_base.override(options);

    assert(result.font != null);
    assert(result.color_text != null);

    return result;
}

fn section_title(source: SourceLocation, title: []const u8) void {
    assert(source.line > 0);
    assert(title.len > 0);

    label(source, title, section().override(.{ .margin = .{ .x = 2, .y = 28, .h = 10 } }));
}

fn section_title_action(source: SourceLocation, title: []const u8, enabled: bool) bool {
    assert(source.line > 0);
    assert(title.len > 0);

    var row = dvui.box(source, box_horizontal, .{
        .expand = .horizontal,
        .margin = .{ .x = 2, .y = 24, .h = 6 },
    });

    defer row.deinit();

    label(@src(), title, section().override(.{ .gravity_y = 0.5 }));

    const options: Options = .{ .tag = "refresh", .gravity_x = 1, .gravity_y = 0.5 };
    const state: ButtonState = if (enabled) .enabled else .disabled;

    return button(@src(), "Refresh", .link, state, options);
}

fn divider(index: u32) void {
    assert(index > 0);
    assert(index < resource_count_max);

    _ = dvui.separator(@src(), .{
        .expand = .horizontal,
        .color_fill = .{ .color = colors_active().border },
        .id_extra = index,
    });
}

fn empty_row(source: SourceLocation, text: []const u8) void {
    assert(source.line > 0);
    assert(text.len > 0);

    const padding: dvui.Rect = .{ .x = 16, .y = 14, .w = 16, .h = 14 };

    paragraph(source, text, caption().override(.{ .padding = padding }));
}

fn note_row(line: *const Table.Line, index: u32) void {
    assert(line.kind == .note);
    assert(index < resource_count_max);

    const options = caption().override(.{
        .padding = .{ .x = 16, .y = 12, .w = 16, .h = 12 },
        .id_extra = index,
    });

    paragraph(@src(), line.text, options);
}

fn label(source: SourceLocation, text: []const u8, options: Options) void {
    assert(source.line > 0);
    assert(text.len <= Twingate.output_bytes_max);
    assert(options.font != null);

    const plain: Options = .{ .padding = .all(0) };

    dvui.labelNoFmt(source, text, .{ .ellipsize = true }, plain.override(options));
}

fn paragraph(source: SourceLocation, text: []const u8, options: Options) void {
    assert(source.line > 0);
    assert(text.len <= Twingate.output_bytes_max);
    assert(options.font != null);

    const plain: Options = .{
        .expand = .horizontal,
        .background = false,
        .padding = .all(0),
        .margin = .all(0),
    };

    var layout = dvui.textLayout(source, .{ .break_lines = true }, plain.override(options));

    layout.addText(text, options);
    layout.deinit();
}

fn describe(buffer: *[describe_bytes_max]u8, view: *const View) []const u8 {
    const snapshot = view.snapshot;

    if (snapshot.activity()) |action| return pending_detail(action, snapshot.accepted);
    if (!snapshot.observed) return "Reading the state of the Twingate service.";

    const result = switch (snapshot.status) {
        .authenticating => sign_in_detail(snapshot),
        .connecting, .starting => "Twingate is bringing the tunnel up.",
        .offline => "The service is running, but the tunnel is down.",
        .online => online_detail(buffer, view),
        .stopped => "The Twingate service is not running.",
        .stopping => "Twingate is shutting the service down.",
        .unknown => unknown_detail(snapshot),
    };

    assert(result.len > 0);

    return result;
}

fn online_detail(buffer: *[describe_bytes_max]u8, view: *const View) []const u8 {
    assert(view.snapshot.status == .online);

    if (view.snapshot.needs_sign_in()) return "Sign in to Twingate to unlock its resources.";

    const seconds = view.connected_seconds orelse return "Private resources are reachable.";

    return connected_detail(buffer, seconds);
}

fn connected_detail(buffer: *[describe_bytes_max]u8, seconds: u64) []const u8 {
    assert(seconds <= Elapsed.seconds_max);

    const elapsed: Elapsed = .{ .seconds = seconds };

    var writer: std.Io.Writer = .fixed(buffer);

    writer.print(connected_prefix ++ "{f}.", .{elapsed}) catch |err| switch (err) {
        error.WriteFailed => unreachable,
    };

    const result = writer.buffered();

    assert(std.mem.startsWith(u8, result, connected_prefix));
    assert(std.mem.endsWith(u8, result, "."));

    return result;
}

fn headline(snapshot: *const Snapshot) []const u8 {
    if (!snapshot.observed) assert(snapshot.status == .unknown);

    if (snapshot.progress()) |progress| return progress;
    if (!snapshot.observed) return "Checking";

    return snapshot.label();
}

fn cycle_phase(nanoseconds: i128, period_ms: u32) f32 {
    assert(nanoseconds >= 0);
    assert(period_ms > 0);

    const milliseconds = @divFloor(nanoseconds, std.time.ns_per_ms);
    const offset = @mod(milliseconds, period_ms);
    const phase = @as(f32, @floatFromInt(offset)) / @as(f32, @floatFromInt(period_ms));

    assert(phase >= 0);
    assert(phase < 1);

    return phase;
}

fn fill_circle(center: dvui.Point.Physical, radius: f32, color: Color) void {
    assert(std.math.isFinite(center.x));
    assert(std.math.isFinite(center.y));
    assert(radius > 0);
    assert(color.a > 0);

    var path: dvui.Path.Builder = .init(dvui.currentWindow().lifo());
    defer path.deinit();

    path.addArc(center, radius, std.math.tau, 0, true);
    path.build().fillConvex(.{ .color = .{ .color = color }, .fade = 1.0 });
}

fn join_details(buffer: *[detail_bytes_max]u8, line: *const Table.Line) []const u8 {
    assert(line.kind == .row);

    var writer: std.Io.Writer = .fixed(buffer);
    var cells = std.mem.splitScalar(u8, line.text, '\t');
    var position: u32 = 0;

    _ = cells.next();

    while (cells.next()) |raw| : (position += 1) {
        assert(position < line.text.len);

        const value = std.mem.trim(u8, raw, " ");
        if (value.len == 0) continue;

        if (writer.end > 0) writer.writeAll(" \u{00b7} ") catch break;

        writer.writeAll(value) catch break;
    }

    return writer.buffered();
}

fn palette_of(tone: Status.Tone) Palette {
    const colors = colors_active();

    const result = switch (tone) {
        .busy => colors.palette_busy,
        .connected => colors.palette_connected,
        .idle => colors.palette_idle,
        .unknown => colors.palette_unknown,
    };

    assert(result.text.a > 0);

    return result;
}

fn pending_detail(action: Action, accepted: bool) []const u8 {
    const detail = switch (action) {
        .connect => if (accepted)
            "Twingate is bringing the tunnel up."
        else
            "Approve the system prompt to connect.",
        .disconnect => "Closing the tunnel.",
        .refresh => "Reading the accounts and resources again.",
        .sign_in => "Opening the sign-in page in the browser.",
        .stop => if (accepted)
            "Twingate is shutting the service down."
        else
            "Approve the system prompt to stop the service.",
        .switch_account => "Approve the system prompt to switch accounts.",
    };

    assert(detail.len > 0);
    assert(std.mem.endsWith(u8, detail, "."));

    return detail;
}

fn sign_in_detail(snapshot: *const Snapshot) []const u8 {
    assert(snapshot.observed);
    assert(snapshot.status == .authenticating);

    if (snapshot.sign_in_url() != null) return "Sign in to Twingate to finish connecting.";

    return "Twingate is signing in. Run twingate status if it stalls.";
}

fn spin_angle(nanoseconds: i128) f32 {
    assert(nanoseconds >= 0);

    const angle = std.math.tau * cycle_phase(nanoseconds, spin_period_ms);

    assert(angle >= 0);
    assert(angle < std.math.tau);

    return angle;
}

fn stroke_arc(center: dvui.Point.Physical, arc: Arc, options: dvui.Path.StrokeOptions) void {
    assert(std.math.isFinite(center.x));
    assert(std.math.isFinite(center.y));
    assert(arc.radius > 0);
    assert(arc.start >= 0);
    assert(arc.start < std.math.tau);
    assert(arc.sweep > 0);
    assert(arc.sweep <= std.math.tau);
    assert(options.thickness > 0);

    var path: dvui.Path.Builder = .init(dvui.currentWindow().lifo());
    defer path.deinit();

    path.addArc(center, arc.radius, arc.start + arc.sweep, arc.start, options.closed);
    path.build().stroke(options);
}

fn reveal_height(id: dvui.Id, measure: *const Measure) ?f32 {
    assert(id != .undef);
    if (measure.height_natural) |height| assert(height >= 0);
    if (measure.height_laid) |height| assert(height >= 0);

    const natural = measure.height_natural orelse return null;
    const motion = dvui.animationGet(id, reveal_motion_key);

    if (measure.resized) {
        if (motion != null) {
            dvui.animation(id, reveal_motion_key, .{
                .start_val = natural,
                .end_val = natural,
                .end_time = 0,
            });
        }

        return natural;
    }

    const stored = measure.height_laid orelse natural;
    const shown = if (motion) |current| current.value() else stored;
    const target = if (motion) |current| current.end_val else shown;

    assert(natural >= 0);
    assert(shown >= 0);

    if (@abs(natural - target) < reveal_epsilon) return shown;

    dvui.animation(id, reveal_motion_key, .{
        .easing = dvui.easing.outCubic,
        .start_val = shown,
        .end_val = natural,
        .end_time = reveal_duration_us,
    });

    return shown;
}

fn reveal_resized(id: dvui.Id) bool {
    assert(id != .undef);

    const natural = dvui.dataGet(null, id, reveal_width_natural_key, f32) orelse return false;
    const shown = dvui.dataGet(null, id, reveal_width_shown_key, f32) orelse natural;

    assert(natural >= 0);
    assert(shown >= 0);

    dvui.dataSet(null, id, reveal_width_shown_key, natural);

    return @abs(natural - shown) > reveal_epsilon;
}

fn unknown_detail(snapshot: *const Snapshot) []const u8 {
    assert(snapshot.observed);
    assert(snapshot.status == .unknown);

    const detail = snapshot.detail.slice();
    if (detail.len == 0) return "Twingate reported a state Solopass does not recognise.";

    return detail;
}

fn body() Options {
    return .{ .font = theme.text_sm, .color_text = .{ .color = colors_active().text } };
}

fn brand() Options {
    return .{ .font = theme.text_xl, .color_text = .{ .color = colors_active().text_strong } };
}

fn caption() Options {
    return .{ .font = theme.text_xs, .color_text = .{ .color = colors_active().text_muted } };
}

fn card() Options {
    const colors = colors_active();

    assert(colors.surface.a == 255);
    assert(colors.border.a > 0);

    return .{
        .expand = .horizontal,
        .background = true,
        .color_fill = .{ .color = colors.surface },
        .border = .all(1),
        .color_border = .{ .color = colors.border },
        .corners = .round(12),
        .padding = .all(20),
    };
}

fn colors_active() *const theme.Colors {
    return theme.colors_of(scheme_active());
}

fn display() Options {
    return .{
        .font = theme.text_2xl,
        .color_text = .{ .color = colors_active().text_strong },
        .margin = .{ .y = 6, .h = 4 },
    };
}

fn entry() Options {
    return .{ .font = theme.text_xs, .color_text = .{ .color = colors_active().text_soft } };
}

fn list() Options {
    return card().override(.{ .padding = .all(0) });
}

fn overline() Options {
    return caption().override(.{ .font = theme.text_xs_medium });
}

fn scheme_active() Scheme {
    return theme.scheme_of(&dvui.currentWindow().theme);
}

fn section() Options {
    return .{ .font = theme.text_sm_medium, .color_text = .{ .color = colors_active().text_soft } };
}

const testing = std.testing;

const slide_frame_count: u32 = 8;
const wrapping_text = "Twingate is signing in. Run twingate status if it stalls.";

const Pair = struct {
    lower: []const u8,
    upper: []const u8,
};

const Track = struct {
    gaps: [slide_frame_count]f32,
    tops: [slide_frame_count]f32,
};

const account_one =
    "EMAIL                  \tNETWORK   \tNETWORK URL\n" ++
    "avery.quinn@example.com\tExampleNet\texamplenet.twingate.com\n";

const account_two = account_one ++ "brayden@example.com\tExample\texample.twingate.com\n";

const account_marked =
    "EMAIL                  \tNETWORK      \tNETWORK URL               \t\n" ++
    "avery.quinn@example.com\tExampleNet   \texamplenet.twingate.com   \t\n" ++
    "tester@example.com     \tSolopass Test\tsolopass-test.twingate.com\t*\n";

const journal_entries =
    "[2026-11-08T13:55:56.218519-0600] [INFO] [client] [382705] Connected to the network\n" ++
    "[2026-11-08T13:55:51.104112-0600] [INFO] [client] [382705] Resources updated\n" ++
    "[2026-11-08T13:55:50.913020-0600] [WARNING] [client] [382705] cryptsetup: Device " ++
    "nvme2n1p2 not found\n" ++
    "[2026-11-08T13:55:48.002318-0600] [INFO] [client] [382705] Authenticating\n" ++
    "[2026-11-08T13:55:47.551906-0600] [INFO] [client] [382705] Starting the client\n";

const resource_list =
    "NAME\tADDRESS\tALIAS\n" ++
    "Wiki\twiki.internal\twiki.corp\n" ++
    "Grafana\t10.0.4.12\t\n" ++
    "Build cache\t*.cache.internal\t\n";

const Scene = struct {
    choice: ?View.Choice,
    focus_visible: bool,
    snapshot: Snapshot,
    view: View,

    fn draw(scene: *Scene) dvui.App.Result {
        assert(scene.view.snapshot == &scene.snapshot);

        if (scene.view.frame()) |choice| scene.choice = choice;

        scene.focus_visible = focus_shown();

        return .ok;
    }

    fn prepare(scene: *Scene, status: Status, accounts: []const u8) void {
        assert(accounts.len <= Snapshot.accounts_bytes_max);

        scene.choice = null;
        scene.focus_visible = false;
        scene.snapshot = .initial;
        scene.snapshot.observed = true;
        scene.snapshot.status = status;
        scene.snapshot.accounts.set(accounts);
        scene.snapshot.accounts_observed = true;
        scene.snapshot.resources_observed = status == .online;

        scene.view = .{
            .autostart = false,
            .connected_seconds = null,
            .log_open = false,
            .snapshot = &scene.snapshot,
        };
    }
};

fn StageType(comptime source: SourceLocation) type {
    comptime assert(source.line > 0);

    return struct {
        var scene: Scene = undefined;

        fn draw() anyerror!dvui.App.Result {
            return scene.draw();
        }
    };
}

fn test_harness() !dvui.testing {
    var harness = try dvui.testing.init(.{ .window_size = .{ .w = 560, .h = 760 } });

    harness.window.themeSet(theme.theme_of(.dark));
    harness.window.snap_to_pixels = theme.snap_to_pixels;

    return harness;
}

fn test_click(comptime draw: fn () anyerror!dvui.App.Result, tag: []const u8) !void {
    assert(tag.len > 0);

    try dvui.testing.settle(draw);
    try dvui.testing.moveTo(tag);
    try dvui.testing.click(.left);
    try dvui.testing.settle(draw);
}

fn test_top(tag: []const u8) !f32 {
    assert(tag.len > 0);

    const found = dvui.tagGet(tag) orelse return error.TagMissing;

    return found.rect.y;
}

fn test_track(comptime draw: fn () anyerror!dvui.App.Result, pair: *const Pair) !Track {
    assert(pair.upper.len > 0);
    assert(pair.lower.len > 0);

    var track: Track = undefined;

    for (&track.tops, &track.gaps) |*top, *gap| {
        _ = try dvui.testing.step(draw);

        top.* = try test_top(pair.upper);
        gap.* = try test_top(pair.lower) - top.*;
    }

    return track;
}

fn expect_rigid(gap: f32, track: *const Track) !void {
    assert(std.math.isFinite(gap));
    assert(gap > 0);

    for (track.gaps) |frame_gap| {
        try testing.expectApproxEqAbs(gap, frame_gap, reveal_epsilon);
    }
}

fn expect_slide(start: f32, tops: []const f32) !void {
    assert(std.math.isFinite(start));
    assert(tops.len == slide_frame_count);

    const end = tops[tops.len - 1];
    const direction: f32 = if (end > start) 1 else -1;

    var between: u32 = 0;
    var previous = start;

    try testing.expect(@abs(end - start) > reveal_epsilon);
    try testing.expectApproxEqAbs(start, tops[0], reveal_epsilon);
    try testing.expectApproxEqAbs(end, tops[tops.len - 2], reveal_epsilon);

    for (tops) |top| {
        try testing.expect((top - previous) * direction >= -reveal_epsilon);
        try testing.expect((end - top) * direction >= -reveal_epsilon);

        if ((top - start) * direction > reveal_epsilon) {
            if ((end - top) * direction > reveal_epsilon) between += 1;
        }

        previous = top;
    }

    try testing.expect(between > 0);
}

test View {
    const Stage = StageType(@src());

    var harness = try test_harness();
    defer harness.deinit();

    Stage.scene.prepare(.offline, account_one);

    try test_click(Stage.draw, "toggle");

    try testing.expectEqual(@as(?View.Choice, .{ .act = .connect }), Stage.scene.choice);
}

test "the primary button connects while the service is stopped" {
    const Stage = StageType(@src());

    var harness = try test_harness();
    defer harness.deinit();

    Stage.scene.prepare(.stopped, account_one);

    try dvui.testing.settle(Stage.draw);
    try harness.saveImage(Stage.draw, null, "stopped.png");
    try test_click(Stage.draw, "toggle");

    try testing.expectEqual(View.Choice{ .act = .connect }, Stage.scene.choice.?);
    try testing.expect(dvui.tagGet("sign-in") == null);
    try testing.expect(dvui.tagGet("stop") != null);
}

test "the primary button connects while the tunnel is down" {
    const Stage = StageType(@src());

    var harness = try test_harness();
    defer harness.deinit();

    Stage.scene.prepare(.offline, account_one);

    try dvui.testing.settle(Stage.draw);
    try harness.saveImage(Stage.draw, null, "disconnected.png");
    try test_click(Stage.draw, "toggle");

    try testing.expectEqual(View.Choice{ .act = .connect }, Stage.scene.choice.?);
    try testing.expect(dvui.tagGet("sign-in") == null);
    try testing.expect(dvui.tagGet("stop") != null);
}

test "a connected session disconnects and lists its resources" {
    const Stage = StageType(@src());

    var harness = try test_harness();
    defer harness.deinit();

    Stage.scene.prepare(.online, account_one);

    Stage.scene.snapshot.resources.set(resource_list);
    Stage.scene.view.connected_seconds = 2 * 3600 + 14 * 60;
    Stage.scene.view.autostart = true;

    try dvui.testing.settle(Stage.draw);
    try harness.saveImage(Stage.draw, null, "connected.png");
    try test_click(Stage.draw, "toggle");

    try testing.expectEqual(View.Choice{ .act = .disconnect }, Stage.scene.choice.?);

    Stage.scene.choice = null;

    try test_click(Stage.draw, "refresh");

    try testing.expectEqual(View.Choice{ .act = .refresh }, Stage.scene.choice.?);
}

test "each of two accounts offers a switch" {
    const Stage = StageType(@src());

    var harness = try test_harness();
    defer harness.deinit();

    Stage.scene.prepare(.offline, account_two);

    try dvui.testing.settle(Stage.draw);
    try harness.saveImage(Stage.draw, null, "accounts.png");
    try test_click(Stage.draw, "account-1");

    try testing.expectEqual(View.Choice{ .switch_account = 1 }, Stage.scene.choice.?);
    try testing.expect(dvui.tagGet("account-0") != null);
    try testing.expect(dvui.tagGet("account-2") == null);
    try testing.expect(dvui.tagGet("current") == null);
}

test "the account in use reads as current and offers no switch" {
    const Stage = StageType(@src());

    var harness = try test_harness();
    defer harness.deinit();

    Stage.scene.prepare(.offline, account_marked);

    try dvui.testing.settle(Stage.draw);
    try harness.saveImage(Stage.draw, null, "current.png");
    try test_click(Stage.draw, "account-0");

    try testing.expectEqual(View.Choice{ .switch_account = 0 }, Stage.scene.choice.?);
    try testing.expect(dvui.tagGet("current") != null);
    try testing.expect(dvui.tagGet("account-1") == null);
}

test "a failure banner can be dismissed" {
    const Stage = StageType(@src());

    var harness = try test_harness();
    defer harness.deinit();

    Stage.scene.prepare(.offline, account_one);

    Stage.scene.snapshot.message.text.set("The password prompt was dismissed.");
    Stage.scene.snapshot.message.kind = .failure;

    try dvui.testing.settle(Stage.draw);
    try harness.saveImage(Stage.draw, null, "failure.png");

    try testing.expect(dvui.tagGet("dismiss") != null);

    try test_click(Stage.draw, "dismiss");

    try testing.expectEqual(View.Choice.dismiss, Stage.scene.choice.?);
}

test "the login switch asks for the opposite value" {
    const Stage = StageType(@src());

    var harness = try test_harness();
    defer harness.deinit();

    Stage.scene.prepare(.offline, account_one);

    try test_click(Stage.draw, "autostart");

    try testing.expectEqual(View.Choice{ .autostart = true }, Stage.scene.choice.?);

    Stage.scene.choice = null;
    Stage.scene.view.autostart = true;

    try test_click(Stage.draw, "autostart");

    try testing.expectEqual(View.Choice{ .autostart = false }, Stage.scene.choice.?);
}

test "the dark mode switch asks for the scheme the window is not in" {
    const Stage = StageType(@src());

    var harness = try test_harness();
    defer harness.deinit();

    Stage.scene.prepare(.offline, account_one);

    try test_click(Stage.draw, "dark");

    try testing.expectEqual(View.Choice{ .scheme = .light }, Stage.scene.choice.?);

    Stage.scene.choice = null;
    harness.window.themeSet(theme.theme_of(.light));

    try test_click(Stage.draw, "dark");

    try testing.expectEqual(View.Choice{ .scheme = .dark }, Stage.scene.choice.?);

    Stage.scene.choice = null;

    try test_click(Stage.draw, "autostart");

    try testing.expectEqual(View.Choice{ .autostart = true }, Stage.scene.choice.?);
}

test "each action is inert while a command runs" {
    const Stage = StageType(@src());

    var harness = try test_harness();
    defer harness.deinit();

    Stage.scene.prepare(.offline, account_two);

    Stage.scene.snapshot.pending = .connect;

    try dvui.testing.settle(Stage.draw);
    try harness.saveImage(Stage.draw, null, "pending.png");
    try test_click(Stage.draw, "toggle");
    try test_click(Stage.draw, "stop");

    try testing.expectEqual(@as(?View.Choice, null), Stage.scene.choice);
    try testing.expect(dvui.tagGet("account-0") == null);
    try testing.expect(dvui.tagGet("account-1") == null);
}

test "a clicked button takes focus without a ring until the tab key moves focus" {
    const Stage = StageType(@src());

    var harness = try test_harness();
    defer harness.deinit();

    Stage.scene.prepare(.offline, account_one);

    try dvui.testing.settle(Stage.draw);
    try test_click(Stage.draw, "toggle");
    try dvui.testing.expectFocused("toggle");
    try testing.expect(!Stage.scene.focus_visible);

    try dvui.testing.pressKey(.tab, .none);
    try dvui.testing.settle(Stage.draw);
    try dvui.testing.expectNotFocused("toggle");
    try testing.expect(Stage.scene.focus_visible);

    try test_click(Stage.draw, "toggle");
    try dvui.testing.expectFocused("toggle");
    try testing.expect(!Stage.scene.focus_visible);
}

test "a privileged action asks for its prompt only until Twingate accepts it" {
    const prompt = "system prompt";

    for ([_]Action{ .connect, .stop }) |action| {
        try testing.expect(std.mem.find(u8, pending_detail(action, false), prompt) != null);
        try testing.expect(std.mem.find(u8, pending_detail(action, true), prompt) == null);
    }

    try testing.expect(std.mem.find(u8, pending_detail(.disconnect, false), prompt) == null);
    try testing.expect(std.mem.find(u8, pending_detail(.disconnect, true), prompt) == null);
}

test "a tunnel on its way up keeps the toggle busy and the service stoppable" {
    const Stage = StageType(@src());

    var harness = try test_harness();
    defer harness.deinit();

    Stage.scene.prepare(.connecting, account_two);

    try dvui.testing.settle(Stage.draw);
    try harness.saveImage(Stage.draw, null, "connecting.png");
    try test_click(Stage.draw, "toggle");

    try testing.expectEqual(@as(?View.Choice, null), Stage.scene.choice);

    try test_click(Stage.draw, "stop");

    try testing.expectEqual(@as(?View.Choice, .{ .act = .stop }), Stage.scene.choice);
}

test "a sign-in offers its page above the connection actions" {
    const Stage = StageType(@src());

    var harness = try test_harness();
    defer harness.deinit();

    Stage.scene.prepare(.authenticating, account_one);

    Stage.scene.snapshot.detail.set("https://login.example.com/authorize?state=abc");

    try dvui.testing.settle(Stage.draw);
    try harness.saveImage(Stage.draw, null, "signing-in.png");
    try test_click(Stage.draw, "sign-in");

    try testing.expectEqual(@as(?View.Choice, .sign_in), Stage.scene.choice);

    Stage.scene.choice = null;
    Stage.scene.snapshot.detail.set("");

    try dvui.testing.settle(Stage.draw);

    try testing.expect(dvui.tagGet("sign-in") == null);

    try test_click(Stage.draw, "toggle");

    try testing.expectEqual(@as(?View.Choice, .{ .act = .disconnect }), Stage.scene.choice);
}

test "a resource sign-in offers its page while the tunnel stays up" {
    const Stage = StageType(@src());

    var harness = try test_harness();
    defer harness.deinit();

    Stage.scene.prepare(.online, account_one);

    Stage.scene.snapshot.detail.set("https://login.example.com/authorize?state=abc");

    var buffer: [describe_bytes_max]u8 = undefined;

    const detail = describe(&buffer, &Stage.scene.view);

    try testing.expectEqualStrings("Sign in to Twingate to unlock its resources.", detail);
    try testing.expectEqualStrings("Signing in", headline(&Stage.scene.snapshot));
    try testing.expectEqual(Status.Tone.busy, Stage.scene.snapshot.tone());

    try dvui.testing.settle(Stage.draw);
    try harness.saveImage(Stage.draw, null, "resource-sign-in.png");
    try test_click(Stage.draw, "sign-in");

    try testing.expectEqual(@as(?View.Choice, .sign_in), Stage.scene.choice);

    Stage.scene.choice = null;

    try test_click(Stage.draw, "toggle");

    try testing.expectEqual(@as(?View.Choice, .{ .act = .disconnect }), Stage.scene.choice);
}

test "a tunnel whose resources still owe a sign-in offers one without a page" {
    const Stage = StageType(@src());

    var harness = try test_harness();
    defer harness.deinit();

    Stage.scene.prepare(.online, account_one);

    Stage.scene.snapshot.locked = true;

    try testing.expectEqualStrings("Sign-in needed", headline(&Stage.scene.snapshot));

    try dvui.testing.settle(Stage.draw);
    try test_click(Stage.draw, "sign-in");

    try testing.expectEqual(@as(?View.Choice, .sign_in), Stage.scene.choice);
}

test "the service log opens from the connection card and closes on its link or escape" {
    const Stage = StageType(@src());

    var harness = try test_harness();
    defer harness.deinit();

    Stage.scene.prepare(.online, account_one);

    try test_click(Stage.draw, "log");

    try testing.expectEqual(@as(?View.Choice, .{ .log = true }), Stage.scene.choice);

    Stage.scene.choice = null;
    Stage.scene.snapshot.log.requested = 1;
    Stage.scene.snapshot.log.served = 1;
    Stage.scene.snapshot.log.text.set(journal_entries);
    Stage.scene.view.log_open = true;

    try dvui.testing.settle(Stage.draw);
    try harness.saveImage(Stage.draw, null, "log.png");
    try test_click(Stage.draw, "log-refresh");

    try testing.expectEqual(@as(?View.Choice, .{ .log = true }), Stage.scene.choice);

    Stage.scene.choice = null;

    try test_click(Stage.draw, "log-close");

    try testing.expectEqual(@as(?View.Choice, .{ .log = false }), Stage.scene.choice);

    Stage.scene.choice = null;

    try dvui.testing.pressKey(.escape, .none);
    try dvui.testing.settle(Stage.draw);

    try testing.expectEqual(@as(?View.Choice, .{ .log = false }), Stage.scene.choice);
}

test "the page under the service log takes no clicks" {
    const Stage = StageType(@src());

    var harness = try test_harness();
    defer harness.deinit();

    Stage.scene.prepare(.offline, account_two);

    Stage.scene.view.log_open = true;

    try test_click(Stage.draw, "toggle");
    try test_click(Stage.draw, "account-1");
    try test_click(Stage.draw, "autostart");

    try testing.expectEqual(@as(?View.Choice, null), Stage.scene.choice);
    try testing.expect(dvui.tagGet("log-close") != null);
}

test "a log read in flight keeps refresh busy until it is served" {
    const Stage = StageType(@src());

    var harness = try test_harness();
    defer harness.deinit();

    Stage.scene.prepare(.offline, account_one);

    Stage.scene.snapshot.log.requested = 1;
    Stage.scene.view.log_open = true;

    try dvui.testing.settle(Stage.draw);
    try harness.saveImage(Stage.draw, null, "log-reading.png");
    try test_click(Stage.draw, "log-refresh");

    try testing.expectEqual(@as(?View.Choice, null), Stage.scene.choice);

    Stage.scene.snapshot.log.served = 1;

    try test_click(Stage.draw, "log-refresh");

    try testing.expectEqual(@as(?View.Choice, .{ .log = true }), Stage.scene.choice);
}

test "a connected session in light mode disconnects from its card" {
    const Stage = StageType(@src());

    var harness = try test_harness();
    defer harness.deinit();

    harness.window.themeSet(theme.theme_of(.light));

    Stage.scene.prepare(.online, account_two);

    Stage.scene.snapshot.resources.set(resource_list);
    Stage.scene.view.connected_seconds = 2 * 3600 + 14 * 60;
    Stage.scene.view.autostart = true;

    try dvui.testing.settle(Stage.draw);
    try harness.saveImage(Stage.draw, null, "connected-light.png");
    try test_click(Stage.draw, "toggle");

    try testing.expectEqual(View.Choice{ .act = .disconnect }, Stage.scene.choice.?);
}

test "a failure banner and the service log in light mode answer their links" {
    const Stage = StageType(@src());

    var harness = try test_harness();
    defer harness.deinit();

    harness.window.themeSet(theme.theme_of(.light));

    Stage.scene.prepare(.offline, account_marked);

    Stage.scene.snapshot.message.text.set("The password prompt was dismissed.");
    Stage.scene.snapshot.message.kind = .failure;

    try dvui.testing.settle(Stage.draw);
    try harness.saveImage(Stage.draw, null, "failure-light.png");
    try test_click(Stage.draw, "dismiss");

    try testing.expectEqual(View.Choice.dismiss, Stage.scene.choice.?);

    Stage.scene.choice = null;
    Stage.scene.snapshot.log.requested = 1;
    Stage.scene.snapshot.log.served = 1;
    Stage.scene.snapshot.log.text.set(journal_entries);
    Stage.scene.view.log_open = true;

    try dvui.testing.settle(Stage.draw);
    try harness.saveImage(Stage.draw, null, "log-light.png");
    try test_click(Stage.draw, "log-close");

    try testing.expectEqual(@as(?View.Choice, .{ .log = false }), Stage.scene.choice);
}

test "a tunnel on its way up in light mode keeps the toggle busy" {
    const Stage = StageType(@src());

    var harness = try test_harness();
    defer harness.deinit();

    harness.window.themeSet(theme.theme_of(.light));

    Stage.scene.prepare(.connecting, account_two);

    try dvui.testing.settle(Stage.draw);
    try harness.saveImage(Stage.draw, null, "connecting-light.png");
    try test_click(Stage.draw, "toggle");

    try testing.expectEqual(@as(?View.Choice, null), Stage.scene.choice);

    try test_click(Stage.draw, "stop");

    try testing.expectEqual(@as(?View.Choice, .{ .act = .stop }), Stage.scene.choice);
}

test "the preferences slide down as resources arrive and back up as the tunnel drops" {
    const Stage = StageType(@src());

    var harness = try test_harness();
    defer harness.deinit();

    Stage.scene.prepare(.online, account_one);

    Stage.scene.snapshot.resources_observed = false;

    try dvui.testing.settle(Stage.draw);

    const switches: Pair = .{ .lower = "dark", .upper = "autostart" };
    const reading = try test_top(switches.upper);
    const gap = try test_top(switches.lower) - reading;

    Stage.scene.snapshot.resources.set(resource_list);
    Stage.scene.snapshot.resources_observed = true;

    const arriving = try test_track(Stage.draw, &switches);
    const arrived = arriving.tops[slide_frame_count - 1];

    try expect_slide(reading, &arriving.tops);
    try expect_rigid(gap, &arriving);
    try testing.expect(arrived > reading);

    Stage.scene.snapshot.status = .offline;
    Stage.scene.snapshot.resources = .empty;
    Stage.scene.snapshot.resources_observed = false;

    const leaving = try test_track(Stage.draw, &switches);

    try expect_slide(arrived, &leaving.tops);
    try expect_rigid(gap, &leaving);
    try testing.expectApproxEqAbs(reading, leaving.tops[slide_frame_count - 1], reveal_epsilon);
}

test "the sections under a message slide down as it appears and close up once it clears" {
    const Stage = StageType(@src());

    var harness = try test_harness();
    defer harness.deinit();

    Stage.scene.prepare(.offline, account_one);

    try dvui.testing.settle(Stage.draw);

    const sections: Pair = .{ .lower = "autostart", .upper = "refresh" };
    const closed = try test_top(sections.upper);
    const gap = try test_top(sections.lower) - closed;

    Stage.scene.snapshot.message.text.set("The password prompt was dismissed.");
    Stage.scene.snapshot.message.kind = .failure;

    const opening = try test_track(Stage.draw, &sections);
    const opened = opening.tops[slide_frame_count - 1];

    try expect_slide(closed, &opening.tops);
    try expect_rigid(gap, &opening);

    Stage.scene.snapshot.message.text = .empty;

    const closing = try test_track(Stage.draw, &sections);

    try expect_slide(opened, &closing.tops);
    try expect_rigid(gap, &closing);
    try testing.expectApproxEqAbs(closed, closing.tops[slide_frame_count - 1], reveal_epsilon);
}

test "a section takes the height a new width needs at once instead of sliding to it" {
    const Stage = struct {
        var width: f32 = 0;

        fn draw() anyerror!dvui.App.Result {
            var column = dvui.box(@src(), box_vertical, .{
                .min_size_content = .{ .w = width },
                .max_size_content = .width(width),
            });

            defer column.deinit();

            var reveal: Reveal = .init(@src(), .{ .expand = .horizontal });

            paragraph(@src(), wrapping_text, body());
            reveal.deinit();

            _ = dvui.spacer(@src(), .{ .tag = "below", .min_size_content = .{ .w = 4, .h = 4 } });

            return .ok;
        }
    };

    var harness = try test_harness();
    defer harness.deinit();

    Stage.width = 360;

    try dvui.testing.settle(Stage.draw);

    const wide = try test_top("below");

    Stage.width = 120;

    var tops: [slide_frame_count]f32 = undefined;

    for (&tops) |*top| {
        _ = try dvui.testing.step(Stage.draw);

        top.* = try test_top("below");
    }

    const narrow = tops[slide_frame_count - 1];

    try testing.expect(narrow > wide + reveal_epsilon);

    for (tops) |top| {
        const arrived = @abs(top - narrow) <= reveal_epsilon;

        if (!arrived) try testing.expectApproxEqAbs(wide, top, reveal_epsilon);
    }
}

test "the resources read as unreachable offline and as reading until the first list arrives" {
    var snapshot: Snapshot = .initial;

    snapshot.observed = true;
    snapshot.status = .offline;

    const offline = resources_placeholder(&snapshot) orelse return error.PlaceholderMissing;

    snapshot.status = .online;

    const reading = resources_placeholder(&snapshot) orelse return error.PlaceholderMissing;

    snapshot.resources_observed = true;

    try testing.expect(resources_placeholder(&snapshot) == null);
    try testing.expect(std.mem.startsWith(u8, offline, "Connect "));
    try testing.expect(std.mem.startsWith(u8, reading, "Reading "));
}

test "the accounts read as reading until the first list arrives and as none after it" {
    var snapshot: Snapshot = .initial;

    try testing.expect(std.mem.startsWith(u8, accounts_placeholder(&snapshot), "Reading "));

    snapshot.accounts_observed = true;

    try testing.expect(std.mem.startsWith(u8, accounts_placeholder(&snapshot), "No accounts "));
}

test "a resource row joins its details and skips the empty ones" {
    var buffer: [detail_bytes_max]u8 = undefined;

    const resources: Table = .init(resource_list);
    const wiki = resources.row(0) orelse return error.RowMissing;
    const grafana = resources.row(1) orelse return error.RowMissing;
    const wiki_details = join_details(&buffer, &wiki);

    try testing.expectEqualStrings("Wiki", wiki.cell(0));
    try testing.expectEqualStrings("wiki.internal \u{00b7} wiki.corp", wiki_details);
    try testing.expectEqualStrings("10.0.4.12", join_details(&buffer, &grafana));
}

test "the connected detail names the time connected and fits its buffer" {
    var buffer: [describe_bytes_max]u8 = undefined;

    const widest = connected_detail(&buffer, Elapsed.seconds_max);

    try testing.expect(widest.len <= describe_bytes_max);
    try testing.expectEqualStrings("Connected for 2h 14m.", connected_detail(&buffer, 8040));
    try testing.expectEqualStrings("Connected for under a minute.", connected_detail(&buffer, 0));
}

test "each text style tightens a pair Geist kerns and leaves an unkerned pair alone" {
    const styles = [_]dvui.Font{
        theme.text_2xl,
        theme.text_sm,
        theme.text_sm_medium,
        theme.text_xl,
        theme.text_xs,
        theme.text_xs_medium,
    };

    const Width = struct {
        kerned: f32,
        plain: f32,
    };

    const Stage = struct {
        var kerned_pairs: [styles.len]Width = undefined;
        var plain_pairs: [styles.len]Width = undefined;

        fn draw() anyerror!dvui.App.Result {
            for (styles, &kerned_pairs, &plain_pairs) |style, *kerned, *plain| {
                kerned.* = measure(style, "To");
                plain.* = measure(style, "42");
            }

            return .ok;
        }

        fn measure(style: dvui.Font, text: []const u8) Width {
            assert(style.size > 0);
            assert(text.len == 2);

            return .{
                .kerned = style.textSizeEx(text, .{ .kerning = null }).w,
                .plain = style.textSizeEx(text, .{ .kerning = false }).w,
            };
        }
    };

    var harness = try test_harness();
    defer harness.deinit();

    try dvui.testing.settle(Stage.draw);

    for (Stage.kerned_pairs, Stage.plain_pairs) |kerned, plain| {
        try testing.expect(kerned.kerned < kerned.plain);
        try testing.expect(plain.plain > 0);
        try testing.expectEqual(plain.plain, plain.kerned);
    }
}

test "the spinner turns once a second at a steady rate" {
    const second: i128 = std.time.ns_per_s;
    const quarter = @divExact(second, 4);
    const starts = [_]i128{ 0, 7 * second + 123 * std.time.ns_per_ms, 90 * second - 1 };

    for (starts) |start| {
        const angle = spin_angle(start);

        try testing.expect(angle >= 0);
        try testing.expect(angle < std.math.tau);
        try testing.expectApproxEqAbs(angle, spin_angle(start + second), 1e-5);
    }

    try testing.expectApproxEqAbs(@as(f32, 0), spin_angle(0), 1e-6);
    try testing.expectApproxEqAbs(@as(f32, std.math.pi / 2.0), spin_angle(quarter), 1e-5);
    try testing.expectApproxEqAbs(@as(f32, std.math.pi), spin_angle(2 * quarter), 1e-5);
}

test "the status ping spreads to twice the dot as it fades, then rests until the next beat" {
    const first = ripple_at(0);

    try testing.expectApproxEqAbs(@as(f32, 1), first.scale, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.75), first.alpha, 1e-6);

    var previous = first;
    var millisecond: i128 = 1;

    while (millisecond < std.time.ms_per_s) : (millisecond += 1) {
        const ripple = ripple_at(millisecond * std.time.ns_per_ms);

        try testing.expect(ripple.scale >= previous.scale);
        try testing.expect(ripple.alpha <= previous.alpha);
        try testing.expectApproxEqAbs(@as(f32, 2), ripple.scale + ripple.alpha / 0.75, 1e-5);

        if (millisecond >= 750) {
            try testing.expectApproxEqAbs(@as(f32, 2), ripple.scale, 1e-6);
            try testing.expectApproxEqAbs(@as(f32, 0), ripple.alpha, 1e-6);
        }

        previous = ripple;
    }

    const next = ripple_at(std.time.ns_per_s);

    try testing.expectEqual(first, next);
}
