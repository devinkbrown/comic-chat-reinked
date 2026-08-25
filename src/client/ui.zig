//! Reusable visual primitives for the Comic Chat desktop shell.
//!
//! Geometry stays in `geometry.zig`. This module owns the Ink Sunday
//! presentation: warm newsprint, vermillion speech accents, and ink chrome
//! around a source-faithful comic page. Comic Neue is never used here.

const std = @import("std");
const canvas_mod = @import("../render/canvas.zig");
const geometry = @import("geometry.zig");

const Canvas = canvas_mod.Canvas;
const Rect = geometry.Rect;

pub const Theme = struct {
    pub const ink: u32 = 0xff1b1410;
    pub const secondary: u32 = 0xff6d5c50;
    pub const chrome: u32 = 0xfff3ead8;
    pub const layer: u32 = 0xfffff8ee;
    pub const subtle: u32 = 0xffeadfcb;
    pub const divider: u32 = 0xffcbbba4;
    pub const accent: u32 = 0xffd4482a;
    pub const accent_soft: u32 = 0xffffe8df;
    pub const accent_hover: u32 = 0xffffd4c4;
    pub const focus: u32 = 0xff9c2d18;
    pub const success: u32 = 0xff2a7a4d;
    pub const warning: u32 = 0xffc47a12;
    pub const comic_paper: u32 = 0xffe8dcc6;
    pub const workspace: u32 = 0xffefe4cf;
    pub const rail: u32 = 0xfff7efe0;
    pub const navigation: u32 = 0xff1b1410;
    pub const navigation_hover: u32 = 0xff3a2d26;
    pub const navigation_muted: u32 = 0xffd4c4ae;
    pub const shadow: u32 = 0xffc4b49a;
    pub const paper_ink: u32 = 0xff1b1410;
    pub const paper: u32 = 0xfffffdf8;
};

pub const ThemeMode = enum { light, dark };
pub const Accent = enum { cobalt, violet, forest };
pub const Appearance = struct {
    mode: ThemeMode = .light,
    accent: Accent = .cobalt,
    high_contrast: bool = false,
};

pub const Palette = struct {
    ink: u32,
    secondary: u32,
    chrome: u32,
    layer: u32,
    subtle: u32,
    divider: u32,
    accent: u32,
    accent_soft: u32,
    accent_hover: u32,
    focus: u32,
    success: u32,
    success_soft: u32,
    warning: u32,
    comic_paper: u32,
    workspace: u32,
    rail: u32,
    navigation: u32,
    navigation_hover: u32,
    navigation_muted: u32,
    navigation_ink: u32,
    shadow: u32,
    paper_ink: u32,
    paper: u32,
    artwork_paper: u32,
    notice_warning: u32,
    notice_failure: u32,
    notice_success: u32,
    failure: u32,
    hover_border: u32,
};

pub fn paletteFor(appearance: Appearance) Palette {
    const accent_color: u32 = switch (appearance.accent) {
        .cobalt => if (appearance.mode == .dark) 0xffff7048 else Theme.accent,
        .violet => if (appearance.mode == .dark) 0xffc9a0ff else 0xff7a4aa8,
        .forest => if (appearance.mode == .dark) 0xff65d6ae else 0xff2d6b4a,
    };
    const accent_soft: u32 = switch (appearance.accent) {
        .cobalt => if (appearance.mode == .dark) 0xff4a261c else Theme.accent_soft,
        .violet => if (appearance.mode == .dark) 0xff3a2a4d else 0xfff0e6ff,
        .forest => if (appearance.mode == .dark) 0xff1d3d32 else 0xffd7efe4,
    };
    const accent_hover: u32 = switch (appearance.accent) {
        .cobalt => if (appearance.mode == .dark) 0xff5c3024 else Theme.accent_hover,
        .violet => if (appearance.mode == .dark) 0xff4d3864 else 0xffe2d2ff,
        .forest => if (appearance.mode == .dark) 0xff275246 else 0xffc4e6d6,
    };
    if (appearance.mode == .light) return .{
        .ink = if (appearance.high_contrast) 0xff110c09 else Theme.ink,
        .secondary = if (appearance.high_contrast) 0xff4a3b32 else Theme.secondary,
        .chrome = Theme.chrome,
        .layer = Theme.layer,
        .subtle = Theme.subtle,
        .divider = if (appearance.high_contrast) 0xff8d7a66 else Theme.divider,
        .accent = accent_color,
        .accent_soft = accent_soft,
        .accent_hover = accent_hover,
        .focus = if (appearance.accent == .cobalt) Theme.focus else accent_color,
        .success = Theme.success,
        .success_soft = 0xffdcefe3,
        .warning = Theme.warning,
        .comic_paper = Theme.comic_paper,
        .workspace = Theme.workspace,
        .rail = Theme.rail,
        .navigation = Theme.navigation,
        .navigation_hover = Theme.navigation_hover,
        .navigation_muted = Theme.navigation_muted,
        .navigation_ink = Theme.paper,
        .shadow = Theme.shadow,
        .paper_ink = Theme.paper_ink,
        .paper = Theme.paper,
        .artwork_paper = Theme.paper,
        .notice_warning = 0xfffff0cc,
        .notice_failure = 0xffffe4dc,
        .notice_success = 0xffdcefe3,
        .failure = 0xffb42318,
        .hover_border = 0xffb59f86,
    };
    return .{
        .ink = if (appearance.high_contrast) 0xffffffff else 0xfff6eee4,
        .secondary = if (appearance.high_contrast) 0xffe6d8c8 else 0xffc4b3a2,
        .chrome = 0xff1c1814,
        .layer = 0xff241e18,
        .subtle = 0xff2d261f,
        .divider = if (appearance.high_contrast) 0xff8a7a68 else 0xff4a4036,
        .accent = accent_color,
        .accent_soft = accent_soft,
        .accent_hover = accent_hover,
        .focus = accent_color,
        .success = 0xff6ee0a6,
        .success_soft = 0xff1d4438,
        .warning = 0xffffc56a,
        .comic_paper = 0xff16120f,
        .workspace = 0xff12100d,
        .rail = 0xff1a1612,
        .navigation = 0xff0e0b09,
        .navigation_hover = 0xff2a231c,
        .navigation_muted = 0xffcbbba6,
        .navigation_ink = 0xfff6eee4,
        .shadow = 0xff080705,
        .paper_ink = 0xfff6eee4,
        .paper = 0xff2a241e,
        .artwork_paper = Theme.paper,
        .notice_warning = 0xff4a3517,
        .notice_failure = 0xff4a2428,
        .notice_success = 0xff1d4438,
        .failure = 0xffff8a72,
        .hover_border = 0xff6b5c4c,
    };
}

pub var current: Palette = paletteFor(.{});

/// Structural chrome strokes stay at least two device pixels. Wayland and X11
/// present this framebuffer with nearest-neighbour integer scale, so 1px
/// hairlines vanish or shimmer at 2x/3x.
pub const stroke: i32 = 2;

pub fn activateAppearance(appearance: Appearance) void {
    current = paletteFor(appearance);
}

pub const ButtonKind = enum { primary, secondary, quiet };
pub const DialogButton = enum { primary, cancel };
pub const NoticeTone = enum { info, warning, failure, success };
pub const SurfaceKind = enum { canvas, panel, raised, accent };
pub const InputKind = enum { text, password, choice, list, preview, readonly, composer };

pub const InputState = struct {
    focused: bool = false,
    hovered: bool = false,
    populated: bool = false,
    invalid: bool = false,
};

pub const ControlState = struct {
    hovered: bool = false,
    selected: bool = false,
    focused: bool = false,
    pressed: bool = false,
    disabled: bool = false,
};

pub const ControlColors = struct { fill: u32, border: u32, content: u32 };

pub fn resolveControlColors(state: ControlState) ControlColors {
    if (state.disabled) return .{ .fill = current.chrome, .border = current.divider, .content = current.divider };
    if (state.pressed) return .{ .fill = current.accent, .border = current.focus, .content = current.layer };
    if (state.selected) return .{ .fill = current.accent_soft, .border = current.accent_soft, .content = current.accent };
    if (state.focused) return .{ .fill = current.layer, .border = current.accent, .content = current.focus };
    if (state.hovered) return .{ .fill = current.layer, .border = current.divider, .content = current.focus };
    return .{ .fill = current.chrome, .border = current.chrome, .content = current.ink };
}

/// Shared dialog geometry, centralized so draw, accessibility, and pointer
/// handling cannot silently drift apart as dialogs grow.
pub const DialogLayout = struct {
    rect: Rect,
    body_y: i32,
    row_h: i32,
    field_count: usize,
    primary: Rect,
    cancel: Rect,

    pub fn init(canvas_width: u32, canvas_height: u32, source_width: u16, source_height: u16, field_count: usize, primary_width: i32, show_cancel: bool) DialogLayout {
        const canvas_w: i32 = @intCast(canvas_width);
        const canvas_h: i32 = @intCast(canvas_height);
        const desired_w = @divTrunc(@as(i32, source_width) * 3, 2);
        const source_h = @divTrunc(@as(i32, source_height) * 3, 2);
        // Reserve a dedicated notice row above the button rail. Validation,
        // transfer progress, and consent copy must never paint over the last
        // field or the primary action.
        const controls_h = 80 + @as(i32, @intCast(field_count)) * 52 + 78;
        const desired_h = @max(source_h, controls_h);
        const rect = Rect{
            .x = @divTrunc(canvas_w - @min(@max(300, desired_w), @max(240, canvas_w - 32)), 2),
            .y = @divTrunc(canvas_h - @min(@max(170, desired_h), @max(140, canvas_h - 32)), 2),
            .w = @min(@max(300, desired_w), @max(240, canvas_w - 32)),
            .h = @min(@max(170, desired_h), @max(140, canvas_h - 32)),
        };
        const body_y = rect.y + 80;
        const available_h = @max(43, rect.bottom() - 72 - body_y);
        const row_h = @min(54, @max(48, @divTrunc(available_h, @max(1, @as(i32, @intCast(field_count))))));
        return .{
            .rect = rect,
            .body_y = body_y,
            .row_h = row_h,
            .field_count = field_count,
            .primary = .{ .x = rect.right() - (if (show_cancel) @as(i32, 100) else @as(i32, 10)) - primary_width, .y = rect.bottom() - 42, .w = primary_width, .h = 32 },
            .cancel = if (show_cancel)
                .{ .x = rect.right() - 88, .y = rect.bottom() - 42, .w = 78, .h = 32 }
            else
                .{ .x = rect.right() - 10, .y = rect.bottom() - 42, .w = 0, .h = 0 },
        };
    }

    pub fn fieldLabelY(self: DialogLayout, index: usize) i32 {
        return self.fieldLabelYScrolled(index, 0);
    }

    pub fn fieldLabelYScrolled(self: DialogLayout, index: usize, first: usize) i32 {
        const relative: i32 = @intCast(index -| first);
        return self.body_y + relative * self.row_h;
    }

    pub fn fieldRect(self: DialogLayout, index: usize) Rect {
        return self.fieldRectScrolled(index, 0);
    }

    pub fn fieldRectScrolled(self: DialogLayout, index: usize, first: usize) Rect {
        return .{ .x = self.rect.x + 24, .y = self.fieldLabelYScrolled(index, first) + 18, .w = self.rect.w - 48, .h = 30 };
    }

    pub fn fieldIndexAt(self: DialogLayout, x: i32, y: i32) ?usize {
        return self.fieldIndexAtScrolled(x, y, 0);
    }

    pub fn fieldIndexAtScrolled(self: DialogLayout, x: i32, y: i32, first: usize) ?usize {
        if (y < self.body_y or y >= self.rect.bottom() - 67) return null;
        const raw = @divTrunc(y - self.body_y, self.row_h);
        if (raw < 0) return null;
        const index = first + @as(usize, @intCast(raw));
        if (index >= self.field_count) return null;
        if (!contains(self.fieldRectScrolled(index, first), x, y)) return null;
        return index;
    }

    pub fn visibleRows(self: DialogLayout) usize {
        const body_h = @max(1, self.rect.bottom() - 72 - self.body_y);
        return @intCast(@max(1, @divTrunc(body_h, self.row_h)));
    }
};

/// Responsive geometry for the status activity surface.  The layout owns the
/// compact fallback decision so status information never collides with actions
/// on a short desktop window.
pub const StatusPanelLayout = struct {
    rect: Rect,
    connection: Rect,
    settings: Rect,
    show_actions: bool,
    show_metrics: bool,
    show_details: bool,

    pub fn init(canvas_width: u32, canvas_height: u32, requested_details: bool) StatusPanelLayout {
        const canvas_w: i32 = @intCast(canvas_width);
        const canvas_h: i32 = @intCast(canvas_height);
        const preferred_y = geometry.menu_height + geometry.toolbar_height + geometry.tab_bar_height + 10;
        const desired_h: i32 = if (requested_details) 200 else 150;
        // A native window normally enforces 640x480, but the component must
        // still remain self-contained for compact previews and test harnesses.
        const status_top = canvas_h - geometry.status_height;
        const y = preferred_y;
        const available_h = @max(0, status_top - y - 12);
        const rect = Rect{
            .x = 12,
            .y = y,
            .w = @min(430, @max(300, canvas_w - 24)),
            .h = @min(desired_h, available_h),
        };
        const show_actions = rect.h >= 120;
        return .{
            .rect = rect,
            .connection = if (show_actions) .{ .x = rect.x + 18, .y = rect.bottom() - 44, .w = 152, .h = 30 } else .{ .x = rect.x, .y = rect.y, .w = 0, .h = 0 },
            .settings = if (show_actions) .{ .x = rect.x + 180, .y = rect.bottom() - 44, .w = 118, .h = 30 } else .{ .x = rect.x, .y = rect.y, .w = 0, .h = 0 },
            .show_actions = show_actions,
            .show_metrics = rect.h >= 156,
            .show_details = requested_details and rect.h >= 190,
        };
    }
};

pub fn contains(rect: Rect, x: i32, y: i32) bool {
    return x >= rect.x and y >= rect.y and x < rect.right() and y < rect.bottom();
}

pub fn dialogButtonAt(layout: DialogLayout, x: i32, y: i32) ?DialogButton {
    if (contains(layout.primary, x, y)) return .primary;
    if (contains(layout.cancel, x, y)) return .cancel;
    return null;
}

pub fn drawOutline(c: *Canvas, x: i32, y: i32, w: i32, h: i32, color: u32) void {
    drawInkRule(c, x, y, w, 1, color);
    drawInkRule(c, x, y + h - 1, w, 1, color);
    drawInkRule(c, x, y, 1, h, color);
    drawInkRule(c, x + w - 1, y, 1, h, color);
}

pub fn drawInkRule(c: *Canvas, x: i32, y: i32, w: i32, h: i32, color: u32) void {
    if (w <= 0 or h <= 0) return;
    const rw = if (w <= 1) stroke else w;
    const rh = if (h <= 1) stroke else h;
    c.fillRect(x, y, rw, rh, color);
}

/// Printed plate: a 2px ink frame around a paper fill so nearest-neighbour
/// integer scale keeps the Sunday outline readable at 2x and 3x.
pub fn drawInkPlate(c: *Canvas, x: i32, y: i32, w: i32, h: i32, radius: i32, fill: u32) void {
    if (w <= 0 or h <= 0) return;
    fillRoundedRect(c, x, y, w, h, radius, current.ink);
    const inset = stroke;
    if (w > inset * 2 and h > inset * 2)
        fillRoundedRect(c, x + inset, y + inset, w - inset * 2, h - inset * 2, @max(0, radius - 1), fill);
}

pub fn fillRoundedRect(c: *Canvas, x: i32, y: i32, w: i32, h: i32, radius: i32, color: u32) void {
    if (w <= 0 or h <= 0) return;
    const r = @min(@max(0, radius), @divTrunc(@min(w, h), 2));
    c.fillRect(x + r, y, @max(0, w - 2 * r), h, color);
    c.fillRect(x, y + r, w, @max(0, h - 2 * r), color);
    var oy: i32 = 0;
    while (oy < r) : (oy += 1) {
        var ox: i32 = 0;
        while (ox < r) : (ox += 1) {
            const dx = r - ox;
            const dy = r - oy;
            if (dx * dx + dy * dy <= r * r) {
                c.set(x + ox, y + oy, color);
                c.set(x + w - 1 - ox, y + oy, color);
                c.set(x + ox, y + h - 1 - oy, color);
                c.set(x + w - 1 - ox, y + h - 1 - oy, color);
            }
        }
    }
}

pub fn drawRoundedBorder(c: *Canvas, x: i32, y: i32, w: i32, h: i32, radius: i32, fill: u32, border: u32) void {
    fillRoundedRect(c, x, y, w, h, radius, border);
    fillRoundedRect(c, x + 1, y + 1, w - 2, h - 2, @max(0, radius - 1), fill);
}

/// Four-by-four supersampling for compact vector-like icon artwork. These
/// primitives stay deterministic across every native framebuffer backend.
pub fn drawAaDisc(c: *Canvas, cx: i32, cy: i32, radius: f64, color: u32) void {
    const extent: i32 = @intFromFloat(@ceil(radius + 1.0));
    var py = cy - extent;
    while (py <= cy + extent) : (py += 1) {
        var px = cx - extent;
        while (px <= cx + extent) : (px += 1) {
            var covered: u32 = 0;
            for (0..4) |sample_y| for (0..4) |sample_x| {
                const sx = @as(f64, @floatFromInt(px)) + (@as(f64, @floatFromInt(sample_x)) + 0.5) / 4.0;
                const sy = @as(f64, @floatFromInt(py)) + (@as(f64, @floatFromInt(sample_y)) + 0.5) / 4.0;
                const dx = sx - (@as(f64, @floatFromInt(cx)) + 0.5);
                const dy = sy - (@as(f64, @floatFromInt(cy)) + 0.5);
                if (dx * dx + dy * dy <= radius * radius) covered += 1;
            };
            if (covered != 0) c.blendPixel(px, py, color, @divTrunc(covered * 255, 16));
        }
    }
}

pub fn drawAaRing(c: *Canvas, cx: i32, cy: i32, radius: f64, thickness: f64, fill: u32, ring: u32) void {
    drawAaDisc(c, cx, cy, radius, ring);
    drawAaDisc(c, cx, cy, @max(0.0, radius - thickness), fill);
}

pub fn drawAaCircleOutline(c: *Canvas, cx: i32, cy: i32, radius: f64, thickness: f64, color: u32) void {
    const extent: i32 = @intFromFloat(@ceil(radius + 1.0));
    const inner = @max(0.0, radius - thickness);
    var py = cy - extent;
    while (py <= cy + extent) : (py += 1) {
        var px = cx - extent;
        while (px <= cx + extent) : (px += 1) {
            var covered: u32 = 0;
            for (0..4) |sample_y| for (0..4) |sample_x| {
                const sx = @as(f64, @floatFromInt(px)) + (@as(f64, @floatFromInt(sample_x)) + 0.5) / 4.0;
                const sy = @as(f64, @floatFromInt(py)) + (@as(f64, @floatFromInt(sample_y)) + 0.5) / 4.0;
                const dx = sx - (@as(f64, @floatFromInt(cx)) + 0.5);
                const dy = sy - (@as(f64, @floatFromInt(cy)) + 0.5);
                const distance_sq = dx * dx + dy * dy;
                if (distance_sq <= radius * radius and distance_sq >= inner * inner) covered += 1;
            };
            if (covered != 0) c.blendPixel(px, py, color, @divTrunc(covered * 255, 16));
        }
    }
}

pub fn drawAaLine(c: *Canvas, x1: i32, y1: i32, x2: i32, y2: i32, width: f64, color: u32) void {
    const extent: i32 = @intFromFloat(@ceil(width));
    var py = @min(y1, y2) - extent;
    while (py <= @max(y1, y2) + extent) : (py += 1) {
        var px = @min(x1, x2) - extent;
        while (px <= @max(x1, x2) + extent) : (px += 1) {
            var covered: u32 = 0;
            for (0..4) |sample_y| for (0..4) |sample_x| {
                const sx = @as(f64, @floatFromInt(px)) + (@as(f64, @floatFromInt(sample_x)) + 0.5) / 4.0;
                const sy = @as(f64, @floatFromInt(py)) + (@as(f64, @floatFromInt(sample_y)) + 0.5) / 4.0;
                if (pointSegmentDistanceSquared(sx, sy, @floatFromInt(x1), @floatFromInt(y1), @floatFromInt(x2), @floatFromInt(y2)) <= width * width / 4.0) covered += 1;
            };
            if (covered != 0) c.blendPixel(px, py, color, @divTrunc(covered * 255, 16));
        }
    }
}

fn pointSegmentDistanceSquared(px: f64, py: f64, x1: f64, y1: f64, x2: f64, y2: f64) f64 {
    const dx = x2 - x1;
    const dy = y2 - y1;
    if (dx == 0 and dy == 0) return (px - x1) * (px - x1) + (py - y1) * (py - y1);
    const t = std.math.clamp(((px - x1) * dx + (py - y1) * dy) / (dx * dx + dy * dy), 0.0, 1.0);
    const nearest_x = x1 + t * dx;
    const nearest_y = y1 + t * dy;
    return (px - nearest_x) * (px - nearest_x) + (py - nearest_y) * (py - nearest_y);
}

pub fn drawSurface(c: *Canvas, rect: Rect, kind: SurfaceKind) void {
    const fill = switch (kind) {
        .canvas => current.workspace,
        .panel => current.paper,
        .raised => current.layer,
        .accent => current.accent_soft,
    };
    if (kind == .raised) {
        fillRoundedRect(c, rect.x + 4, rect.y + 6, rect.w, rect.h, 4, current.shadow);
    }
    drawRoundedBorder(c, rect.x, rect.y, rect.w, rect.h, 4, fill, current.ink);
}

pub fn drawPill(c: *Canvas, rect: Rect, label: []const u8, active: bool) void {
    const fill = if (active) current.accent_soft else current.chrome;
    const color = if (active) current.accent else current.secondary;
    drawInkPlate(c, rect.x, rect.y, rect.w, rect.h, @divTrunc(rect.h, 2), fill);
    drawEllipsized(c, label, rect.x + 8, rect.y + @max(1, @divTrunc(rect.h - 17, 2)), rect.w - 16, color);
}

pub fn drawTooltip(c: *Canvas, rect: Rect, label: []const u8) void {
    drawTooltipWithHint(c, rect, label, "");
}

/// Tooltip with a compact contextual badge. The badge is optional so existing
/// one-line tooltips keep their stable geometry.
pub fn drawTooltipWithHint(c: *Canvas, rect: Rect, label: []const u8, hint: []const u8) void {
    fillRoundedRect(c, rect.x + 3, rect.y + 5, rect.w, rect.h, 3, current.shadow);
    drawInkPlate(c, rect.x, rect.y, rect.w, rect.h, 3, current.navigation);
    const hint_w = if (hint.len == 0) 0 else Canvas.uiTextWidth(hint) + 14;
    if (hint_w > 0) drawRoundedBorder(c, rect.right() - hint_w - 7, rect.y + 5, hint_w, rect.h - 10, 3, current.navigation_hover, current.navigation_hover);
    drawEllipsized(c, label, rect.x + 9, rect.y + 5, rect.w - 18 - hint_w, current.layer);
    if (hint_w > 0) drawEllipsized(c, hint, rect.right() - hint_w + 1, rect.y + 6, hint_w - 8, current.navigation_ink);
}

pub fn drawButton(c: *Canvas, x: i32, y: i32, width: i32, label: []const u8, kind: ButtonKind, hovered: bool) void {
    const fill = switch (kind) {
        .primary => if (hovered) current.focus else current.accent,
        .secondary => if (hovered) current.accent_soft else current.layer,
        .quiet => if (hovered) current.subtle else current.layer,
    };
    if (kind == .primary) fillRoundedRect(c, x + 2, y + 3, width, 32, 3, current.shadow);
    drawInkPlate(c, x, y, width, 32, 3, fill);
    if (kind != .primary) c.fillRect(x + stroke, y + stroke, @max(0, width - stroke * 2), 2, if (hovered) current.accent else current.ink);
    const text_color = if (kind == .primary) current.layer else current.ink;
    const available = @max(0, width - 16);
    const text_w = Canvas.uiTextWidth(label);
    if (text_w <= available)
        _ = c.drawUiText(label, x + @divTrunc(width - text_w, 2), y + 3, text_color)
    else
        drawEllipsized(c, label, x + 8, y + 3, available, text_color);
}

pub fn drawModalBackdrop(c: *Canvas) void {
    var y: i32 = 0;
    while (y < @as(i32, @intCast(c.height))) : (y += 1) {
        var x: i32 = 0;
        while (x < @as(i32, @intCast(c.width))) : (x += 1) c.blendPixel(x, y, 0xff000000, 0x88);
    }
}

pub fn drawDialogSurface(c: *Canvas, rect: Rect, title: []const u8, subtitle: []const u8) void {
    fillRoundedRect(c, rect.x + 7, rect.y + 9, rect.w, rect.h, 2, current.shadow);
    drawInkPlate(c, rect.x, rect.y, rect.w, rect.h, 2, current.paper);
    c.fillRect(rect.x + stroke, rect.y + stroke, rect.w - stroke * 2, 60, current.navigation);
    c.fillRect(rect.x, rect.y, rect.w, 4, current.accent);
    drawBrandMark(c, .{ .x = rect.x + 16, .y = rect.y + 16, .w = 28, .h = 28 });
    const edition = if (rect.w >= 340) mastheadEdition(rect.w) else "";
    const edition_w = if (edition.len == 0) 0 else Canvas.uiTextWidth(edition) + 28;
    drawEllipsized(c, title, rect.x + 54, rect.y + 18, rect.w - 72 - edition_w, current.navigation_ink);
    drawEllipsized(c, subtitle, rect.x + 54, rect.y + 36, rect.w - 72 - edition_w, current.navigation_muted);
    if (edition_w > 0) drawInkChip(c, .{ .x = rect.right() - edition_w - 12, .y = rect.y + 20, .w = edition_w, .h = 22 }, edition, true);
    c.fillRect(rect.x, rect.y + 62, rect.w, 3, current.accent);
}

pub fn drawNotice(c: *Canvas, x: i32, y: i32, width: i32, label: []const u8, tone: NoticeTone) void {
    const colors = switch (tone) {
        .info => .{ current.accent_soft, current.accent },
        .warning => .{ current.notice_warning, current.warning },
        .failure => .{ current.notice_failure, current.failure },
        .success => .{ current.notice_success, current.success },
    };
    c.fillRect(x, y, width, 20, colors[0]);
    c.fillRect(x, y, 3, 20, colors[1]);
    drawInkRule(c, x + 3, y, 1, 20, current.ink);
    drawEllipsized(c, label, x + 10, y + 2, width - 16, colors[1]);
}

/// Gives modal actions a quiet shared footer so warnings, primary actions, and
/// cancellation controls remain distinct when a dialog becomes dense.
pub fn drawDialogActionBar(c: *Canvas, rect: Rect, y: i32) void {
    const top = @max(rect.y + 68, y);
    if (top >= rect.bottom() - 10) return;
    c.fillRect(rect.x + 1, top, rect.w - 2, rect.bottom() - top - 1, current.chrome);
    c.fillRect(rect.x + 1, top, rect.w - 2, 3, current.ink);
    c.fillRect(rect.x + 1, top + 3, rect.w - 2, 2, current.accent);
}

/// Shared label treatment for typed dialog rows. The small active marker keeps
/// keyboard focus readable without relying on color alone.
pub fn drawDialogFieldLabel(c: *Canvas, rect: Rect, label: []const u8, active: bool) void {
    const color = if (active) current.accent else current.secondary;
    if (active) fillRoundedRect(c, rect.x, rect.y + 6, 3, 8, 2, current.accent);
    drawEllipsized(c, label, rect.x + if (active) @as(i32, 8) else @as(i32, 0), rect.y, rect.w - if (active) @as(i32, 8) else @as(i32, 0), color);
}

/// A popup separator that always respects the menu's visual inset.
pub fn drawMenuGroupDivider(c: *Canvas, rect: Rect, y: i32) void {
    drawInkRule(c, rect.x + 14, y, @max(0, rect.w - 28), 1, current.divider);
    c.fillRect(rect.x + 14, y, 12, stroke, current.accent);
}

/// Two-level compact heading for popovers and information panes.
pub fn drawContentHeading(c: *Canvas, rect: Rect, title: []const u8, detail: []const u8) void {
    drawEllipsized(c, title, rect.x, rect.y, rect.w, current.ink);
    drawEllipsized(c, detail, rect.x, rect.y + 19, rect.w, current.secondary);
}

pub fn drawField(c: *Canvas, x: i32, y: i32, width: i32, active: bool) void {
    drawInputControl(c, .{ .x = x, .y = y, .w = width, .h = 30 }, .text, .{ .focused = active });
}

pub fn drawChoiceField(c: *Canvas, x: i32, y: i32, width: i32, active: bool) void {
    drawInputControl(c, .{ .x = x, .y = y, .w = width, .h = 30 }, .choice, .{ .focused = active });
}

pub fn drawListField(c: *Canvas, x: i32, y: i32, width: i32, active: bool) void {
    drawInputControl(c, .{ .x = x, .y = y, .w = width, .h = 30 }, .list, .{ .focused = active });
}

pub fn drawPreviewField(c: *Canvas, x: i32, y: i32, width: i32) void {
    drawInputControl(c, .{ .x = x, .y = y, .w = width, .h = 30 }, .preview, .{});
}

pub fn drawReadonlyField(c: *Canvas, x: i32, y: i32, width: i32) void {
    drawInputControl(c, .{ .x = x, .y = y, .w = width, .h = 30 }, .readonly, .{});
}

/// Unified modern input surface. Text fields, selectors, previews, and the
/// composer share the same fill, focus halo, border weight, and affordance
/// language so dialogs no longer feel assembled from unrelated widgets.
pub fn drawInputControl(c: *Canvas, rect: Rect, kind: InputKind, state: InputState) void {
    if (rect.w <= 0 or rect.h <= 0) return;
    const readonly = kind == .readonly or kind == .preview;
    const fill = if (readonly) current.subtle else if (state.focused) current.layer else if (state.hovered) current.paper else current.chrome;
    const border = if (state.invalid) current.failure else if (state.focused) current.accent else if (state.hovered) current.hover_border else current.divider;
    const radius: i32 = if (kind == .composer) 4 else 3;

    if (state.focused) {
        fillRoundedRect(c, rect.x - 3, rect.y - 3, rect.w + 6, rect.h + 6, radius + 2, current.accent_soft);
        fillRoundedRect(c, rect.x + 2, rect.y + 4, rect.w, rect.h, radius, current.shadow);
    }
    drawRoundedBorder(c, rect.x, rect.y, rect.w, rect.h, radius, fill, border);
    if (state.focused or state.invalid) {
        c.fillRect(rect.x + 1, rect.y + 1, 3, @max(0, rect.h - 2), if (state.invalid) current.failure else current.accent);
        fillRoundedRect(c, rect.x + 8, rect.bottom() - 3, @max(0, rect.w - 16), stroke, 1, if (state.invalid) current.failure else current.accent);
    } else if (state.hovered) {
        c.fillRect(rect.x + 1, rect.y + 1, 3, @max(0, rect.h - 2), current.accent);
    } else {
        c.fillRect(rect.x + 8, rect.y + 1, @max(0, rect.w - 16), stroke, current.layer);
    }

    switch (kind) {
        .password => {
            const cx = rect.right() - 17;
            drawAaCircleOutline(c, cx, rect.y + 12, 4, 1.25, if (state.focused) current.accent else current.secondary);
            fillRoundedRect(c, cx - 6, rect.y + 12, 12, 10, 3, if (state.focused) current.accent_soft else current.subtle);
            c.fillRect(cx, rect.y + 15, 1, 4, if (state.focused) current.accent else current.secondary);
        },
        .choice => {
            fillRoundedRect(c, rect.right() - 31, rect.y + 4, 27, rect.h - 8, 3, if (state.focused or state.hovered) current.accent_soft else current.subtle);
            const cx = rect.right() - 17;
            c.drawLine(cx - 4, rect.y + 12, cx, rect.y + 16, if (state.focused) current.accent else current.secondary);
            c.drawLine(cx, rect.y + 16, cx + 4, rect.y + 12, if (state.focused) current.accent else current.secondary);
        },
        .list => {
            fillRoundedRect(c, rect.x + 7, rect.y + 7, 17, 16, 5, if (state.focused) current.accent_soft else current.subtle);
            c.fillRect(rect.x + 11, rect.y + 11, 9, 2, if (state.focused) current.accent else current.secondary);
            c.fillRect(rect.x + 11, rect.y + 16, 9, 2, if (state.focused) current.accent else current.secondary);
        },
        .preview => drawInkRule(c, rect.x + 48, rect.y + 5, 1, rect.h - 10, current.divider),
        .readonly => {
            fillRoundedRect(c, rect.x + 9, rect.y + 11, 8, 8, 4, current.success);
            drawInkRule(c, rect.x + 27, rect.y + 8, 1, rect.h - 16, current.divider);
        },
        .text, .composer => {},
    }
}

/// A compact command tile for icon-only tools.  The top ink mark is the
/// Comic Chat signature: selected modes read at a glance without a bulky
/// native-toolbar bevel.
pub fn drawCommandTile(c: *Canvas, x: i32, y: i32, selected: bool, hovered: bool) u32 {
    return drawCommandTileState(c, x, y, selected, hovered, false);
}

pub fn drawCommandTileState(c: *Canvas, x: i32, y: i32, selected: bool, hovered: bool, disabled: bool) u32 {
    if (disabled) {
        drawInkPlate(c, x, y, 32, 32, 2, current.chrome);
        c.fillRect(x + stroke, y + stroke, 32 - stroke * 2, 2, current.divider);
        return current.divider;
    }
    if (selected) {
        drawInkPlate(c, x, y, 32, 32, 2, current.accent);
        return current.layer;
    }
    if (hovered) {
        drawInkPlate(c, x, y, 32, 32, 2, current.accent_soft);
        c.fillRect(x + stroke, y + stroke, 32 - stroke * 2, 3, current.accent);
        return current.accent;
    }
    drawInkPlate(c, x, y, 32, 32, 2, current.paper);
    return current.ink;
}

pub const ToolGlyph = enum {
    connect,
    disconnect,
    enter_room,
    leave_room,
    create_room,
    comic,
    text,
    rooms,
    members,
    favorite,
    away,
    identity,
    ignore,
    whisper,
    email,
    home_page,
    meeting,
    font,
    color,
    bold,
    italic,
    underline,
    fixed,
    symbol,
};

pub const SayGlyph = enum { say, think, whisper, action, sound };

/// The nine expressions used by Comic Chat's radial mood dial.  Keeping their
/// silhouettes here makes the dial a reusable themed control rather than a
/// collection of client-local pixels.
pub const MoodGlyph = enum { angry, loud, laughing, sad, neutral, happy, uneasy, bored, coy };

pub fn drawMoodGlyph(c: *Canvas, cx: i32, cy: i32, mood: MoodGlyph, selected: bool) void {
    const face_fill = if (selected) current.accent else current.layer;
    const face_border = if (selected) current.accent else current.divider;
    const feature = if (selected) current.layer else current.ink;
    drawAaDisc(c, cx, cy, 13.0, face_border);
    drawAaDisc(c, cx, cy, 11.4, face_fill);

    switch (mood) {
        .angry => {
            drawMoodFeatureLine(c, cx - 6, cy - 5, cx - 2, cy - 3, feature);
            drawMoodFeatureLine(c, cx + 2, cy - 3, cx + 6, cy - 5, feature);
            drawMoodEye(c, cx - 4, cy, feature);
            drawMoodEye(c, cx + 4, cy, feature);
            drawMoodFeatureLine(c, cx - 4, cy + 6, cx, cy + 3, feature);
            drawMoodFeatureLine(c, cx, cy + 3, cx + 4, cy + 6, feature);
        },
        .loud => {
            drawMoodEye(c, cx - 4, cy - 2, feature);
            drawMoodEye(c, cx + 4, cy - 2, feature);
            drawAaDisc(c, cx, cy + 4, 4.2, feature);
            drawAaDisc(c, cx, cy + 3, 2.0, face_fill);
        },
        .laughing => {
            drawMoodFeatureLine(c, cx - 6, cy - 2, cx - 4, cy - 4, feature);
            drawMoodFeatureLine(c, cx - 4, cy - 4, cx - 2, cy - 2, feature);
            drawMoodFeatureLine(c, cx + 2, cy - 2, cx + 4, cy - 4, feature);
            drawMoodFeatureLine(c, cx + 4, cy - 4, cx + 6, cy - 2, feature);
            drawMoodFeatureLine(c, cx - 5, cy + 2, cx, cy + 6, feature);
            drawMoodFeatureLine(c, cx, cy + 6, cx + 5, cy + 2, feature);
        },
        .sad => {
            drawMoodEye(c, cx - 4, cy - 2, feature);
            drawMoodEye(c, cx + 4, cy - 2, feature);
            drawMoodFeatureLine(c, cx - 5, cy + 6, cx, cy + 3, feature);
            drawMoodFeatureLine(c, cx, cy + 3, cx + 5, cy + 6, feature);
        },
        .neutral => {
            drawMoodEye(c, cx - 4, cy - 2, feature);
            drawMoodEye(c, cx + 4, cy - 2, feature);
            drawMoodFeatureLine(c, cx - 4, cy + 4, cx + 4, cy + 4, feature);
        },
        .happy => {
            drawMoodEye(c, cx - 4, cy - 2, feature);
            drawMoodEye(c, cx + 4, cy - 2, feature);
            drawMoodFeatureLine(c, cx - 5, cy + 2, cx, cy + 6, feature);
            drawMoodFeatureLine(c, cx, cy + 6, cx + 5, cy + 2, feature);
        },
        .uneasy => {
            drawMoodEye(c, cx - 4, cy - 2, feature);
            drawMoodEye(c, cx + 4, cy - 1, feature);
            drawMoodFeatureLine(c, cx - 5, cy + 5, cx - 1, cy + 3, feature);
            drawMoodFeatureLine(c, cx - 1, cy + 3, cx + 4, cy + 5, feature);
        },
        .bored => {
            drawMoodFeatureLine(c, cx - 6, cy - 3, cx - 2, cy - 3, feature);
            drawMoodFeatureLine(c, cx + 2, cy - 3, cx + 6, cy - 3, feature);
            drawAaLine(c, cx - 5, cy - 1, cx - 3, cy - 1, 1.4, feature);
            drawAaLine(c, cx + 3, cy - 1, cx + 5, cy - 1, 1.4, feature);
            drawMoodFeatureLine(c, cx - 4, cy + 5, cx + 4, cy + 5, feature);
        },
        .coy => {
            drawMoodEye(c, cx - 4, cy - 2, feature);
            drawMoodFeatureLine(c, cx + 2, cy - 3, cx + 6, cy - 3, feature);
            drawMoodFeatureLine(c, cx - 3, cy + 3, cx + 1, cy + 5, feature);
            drawMoodFeatureLine(c, cx + 1, cy + 5, cx + 5, cy + 2, feature);
        },
    }
}

fn drawMoodFeatureLine(c: *Canvas, x1: i32, y1: i32, x2: i32, y2: i32, color: u32) void {
    drawAaLine(c, x1, y1, x2, y2, 1.8, color);
}

fn drawMoodEye(c: *Canvas, x: i32, y: i32, color: u32) void {
    drawAaDisc(c, x, y, 1.45, color);
}

pub fn drawToolGlyph(c: *Canvas, glyph: ToolGlyph, x: i32, y: i32, color: u32) void {
    switch (glyph) {
        .connect, .disconnect => {
            drawGlyphLine(c, x + 3, y + 3, x + 12, y + 12, color);
            drawGlyphLine(c, x + 2, y + 6, x + 6, y + 2, color);
            drawGlyphLine(c, x + 9, y + 14, x + 14, y + 9, color);
            if (glyph == .disconnect) drawGlyphLine(c, x + 2, y + 14, x + 14, y + 2, current.accent);
        },
        .enter_room, .leave_room => {
            drawGlyphRectOutline(c, x + 8, y + 2, 6, 13, color);
            const rightward = glyph == .enter_room;
            const from_x = if (rightward) x + 1 else x + 13;
            const to_x = if (rightward) x + 10 else x + 4;
            drawGlyphLine(c, from_x, y + 8, to_x, y + 8, color);
            drawGlyphLine(c, to_x, y + 8, if (rightward) to_x - 3 else to_x + 3, y + 5, color);
            drawGlyphLine(c, to_x, y + 8, if (rightward) to_x - 3 else to_x + 3, y + 11, color);
        },
        .create_room => {
            drawGlyphRectOutline(c, x + 2, y + 2, 12, 12, color);
            drawGlyphLine(c, x + 5, y + 8, x + 11, y + 8, color);
            drawGlyphLine(c, x + 8, y + 5, x + 8, y + 11, color);
        },
        .comic, .whisper => drawBubbleGlyph(c, x, y, color, glyph == .whisper),
        .text => {
            drawGlyphLine(c, x + 2, y + 3, x + 14, y + 3, color);
            drawGlyphLine(c, x + 2, y + 7, x + 12, y + 7, color);
            drawGlyphLine(c, x + 2, y + 11, x + 14, y + 11, color);
            drawGlyphLine(c, x + 2, y + 15, x + 9, y + 15, color);
        },
        .rooms => {
            drawGlyphRectOutline(c, x + 1, y + 2, 14, 12, color);
            drawGlyphLine(c, x + 6, y + 3, x + 6, y + 13, color);
            drawGlyphLine(c, x + 2, y + 7, x + 14, y + 7, color);
        },
        .members, .identity, .ignore => {
            drawGlyphCircleOutline(c, x + 8, y + 5, 3, color);
            drawGlyphLine(c, x + 3, y + 14, x + 5, y + 10, color);
            drawGlyphLine(c, x + 5, y + 10, x + 11, y + 10, color);
            drawGlyphLine(c, x + 11, y + 10, x + 13, y + 14, color);
            if (glyph == .ignore) drawGlyphLine(c, x + 2, y + 14, x + 14, y + 2, current.accent);
            if (glyph == .identity) drawGlyphRectOutline(c, x + 1, y + 1, 14, 14, color);
        },
        .favorite => drawStarGlyph(c, x + 8, y + 8, color),
        .away => {
            drawGlyphCircleOutline(c, x + 8, y + 8, 6, color);
            c.fillRect(x + 7, y + 1, 7, 9, current.chrome);
            drawGlyphLine(c, x + 8, y + 14, x + 13, y + 11, color);
        },
        .email => {
            drawGlyphRectOutline(c, x + 1, y + 3, 14, 11, color);
            drawGlyphLine(c, x + 2, y + 4, x + 8, y + 9, color);
            drawGlyphLine(c, x + 14, y + 4, x + 8, y + 9, color);
        },
        .home_page => {
            drawGlyphCircleOutline(c, x + 8, y + 8, 7, color);
            drawGlyphLine(c, x + 1, y + 8, x + 15, y + 8, color);
            drawGlyphLine(c, x + 8, y + 1, x + 8, y + 15, color);
            drawGlyphRectOutline(c, x + 4, y + 1, 8, 14, color);
        },
        .meeting => {
            drawGlyphRectOutline(c, x + 1, y + 4, 10, 9, color);
            c.fillTriangle(x + 11, y + 7, x + 15, y + 4, x + 15, y + 13, color);
        },
        .font => _ = c.drawUiText("A", x + 2, y - 3, color),
        .color => {
            drawGlyphCircleOutline(c, x + 8, y + 8, 7, color);
            c.fillRect(x + 3, y + 4, 3, 3, current.accent);
            c.fillRect(x + 8, y + 2, 3, 3, current.success);
            c.fillRect(x + 11, y + 7, 3, 3, current.failure);
        },
        .bold => _ = c.drawUiText("B", x + 2, y - 3, color),
        .italic => _ = c.drawUiText("I", x + 4, y - 3, color),
        .underline => {
            _ = c.drawUiText("U", x + 2, y - 3, color);
            drawGlyphLine(c, x + 2, y + 15, x + 13, y + 15, color);
        },
        .fixed => {
            drawGlyphLine(c, x + 4, y + 3, x + 1, y + 8, color);
            drawGlyphLine(c, x + 1, y + 8, x + 4, y + 13, color);
            drawGlyphLine(c, x + 12, y + 3, x + 15, y + 8, color);
            drawGlyphLine(c, x + 15, y + 8, x + 12, y + 13, color);
        },
        .symbol => _ = c.drawUiText("#", x + 1, y - 3, color),
    }
}

pub fn drawSayGlyph(c: *Canvas, glyph: SayGlyph, x: i32, y: i32, color: u32) void {
    switch (glyph) {
        .say => drawBubbleGlyph(c, x, y, color, false),
        .whisper => drawBubbleGlyph(c, x, y, color, true),
        .think => {
            drawGlyphCircleOutline(c, x + 5, y + 7, 4, color);
            drawGlyphCircleOutline(c, x + 10, y + 6, 4, color);
            drawGlyphCircleOutline(c, x + 8, y + 10, 4, color);
            drawAaDisc(c, x + 4, y + 15, 1.1, color);
        },
        .action => {
            drawGlyphLine(c, x + 9, y + 1, x + 4, y + 9, color);
            drawGlyphLine(c, x + 4, y + 9, x + 8, y + 9, color);
            drawGlyphLine(c, x + 8, y + 9, x + 5, y + 16, color);
            drawGlyphLine(c, x + 5, y + 16, x + 14, y + 6, color);
            drawGlyphLine(c, x + 14, y + 6, x + 10, y + 6, color);
        },
        .sound => {
            c.fillRect(x + 2, y + 6, 4, 6, color);
            c.fillTriangle(x + 6, y + 6, x + 11, y + 2, x + 11, y + 16, color);
            drawGlyphLine(c, x + 13, y + 5, x + 15, y + 8, color);
            drawGlyphLine(c, x + 15, y + 8, x + 13, y + 12, color);
        },
    }
}

/// Icon geometry is drawn with one weight so 16px controls stay crisp across
/// the application rather than inheriting a mixture of legacy one-pixel marks.
fn drawGlyphLine(c: *Canvas, x1: i32, y1: i32, x2: i32, y2: i32, color: u32) void {
    drawAaLine(c, x1, y1, x2, y2, 1.55, color);
}

fn drawGlyphRectOutline(c: *Canvas, x: i32, y: i32, w: i32, h: i32, color: u32) void {
    if (w <= 0 or h <= 0) return;
    drawGlyphLine(c, x, y, x + w - 1, y, color);
    drawGlyphLine(c, x, y + h - 1, x + w - 1, y + h - 1, color);
    drawGlyphLine(c, x, y, x, y + h - 1, color);
    drawGlyphLine(c, x + w - 1, y, x + w - 1, y + h - 1, color);
}
fn drawGlyphCircleOutline(c: *Canvas, cx: i32, cy: i32, radius: i32, color: u32) void {
    drawAaCircleOutline(c, cx, cy, @floatFromInt(radius), 1.55, color);
}
fn drawBubbleGlyph(c: *Canvas, x: i32, y: i32, color: u32, dotted: bool) void {
    drawGlyphRectOutline(c, x + 1, y + 2, 14, 10, color);
    drawGlyphLine(c, x + 5, y + 11, x + 3, y + 15, color);
    drawGlyphLine(c, x + 5, y + 11, x + 8, y + 11, color);
    if (dotted) {
        drawAaDisc(c, x + 5, y + 7, 1.2, color);
        drawAaDisc(c, x + 8, y + 7, 1.2, color);
        drawAaDisc(c, x + 11, y + 7, 1.2, color);
    }
}
fn drawStarGlyph(c: *Canvas, cx: i32, cy: i32, color: u32) void {
    const points = [_][2]i32{ .{ 0, -7 }, .{ 2, -2 }, .{ 7, -2 }, .{ 3, 1 }, .{ 5, 6 }, .{ 0, 3 }, .{ -5, 6 }, .{ -3, 1 }, .{ -7, -2 }, .{ -2, -2 } };
    for (points, 0..) |point, index| {
        const next = points[(index + 1) % points.len];
        drawGlyphLine(c, cx + point[0], cy + point[1], cx + next[0], cy + next[1], color);
    }
}

pub fn drawMenuItem(c: *Canvas, x: i32, y: i32, width: i32, label: []const u8, hint: []const u8, hovered: bool, checked: bool, enabled: bool) void {
    if (hovered and enabled) {
        c.fillRect(x, y, width, 27, current.accent_soft);
        c.fillRect(x, y, 4, 27, current.accent);
        drawInkRule(c, x + 4, y, 1, 27, current.ink);
        c.fillRect(x + width - 3, y + 4, 3, 19, current.accent);
    } else if (!enabled) {
        c.fillRect(x, y, width, 27, current.subtle);
        c.fillRect(x, y, 2, 27, current.divider);
    } else {
        c.fillRect(x, y, 2, 27, current.subtle);
    }
    if (checked) {
        drawAaDisc(c, x + 15, y + 14, 4.0, current.accent);
        drawGlyphLine(c, x + 13, y + 14, x + 15, y + 16, current.paper);
        drawGlyphLine(c, x + 15, y + 16, x + 19, y + 11, current.paper);
    }
    const hint_w: i32 = if (hint.len == 0) 0 else Canvas.uiTextWidth(hint) + 8;
    drawEllipsized(c, label, x + 27, y + 5, width - 40 - hint_w, if (enabled) current.ink else current.secondary);
    if (hint_w > 0) drawEllipsized(c, hint, x + width - hint_w - 12, y + 5, hint_w, if (hovered and enabled) current.accent else current.secondary);
}

pub fn drawMenuLabel(c: *Canvas, x: i32, y: i32, width: i32, label: []const u8, selected: bool) void {
    if (selected) {
        c.fillRect(x - 6, y + 5, width + 6, 24, current.navigation_hover);
        c.fillRect(x - 4, y + 26, @max(10, width), 3, current.accent);
    }
    _ = c.drawUiText(label, x, y + 6, if (selected) current.accent else current.navigation_ink);
}

pub fn drawMenuBarSurface(c: *Canvas, rect: Rect) void {
    c.fillRect(rect.x, rect.y, rect.w, rect.h, current.navigation);
    c.fillRect(rect.x, rect.bottom() - 4, rect.w, 4, current.accent);
    c.fillRect(rect.x, rect.bottom() - 6, rect.w, 2, current.navigation_hover);
    if (rect.w >= 760) {
        const edition = mastheadEdition(rect.w);
        const mark_w = Canvas.uiTextWidth(edition) + 24;
        drawInkChip(c, .{ .x = rect.right() - mark_w - 10, .y = rect.y + 5, .w = mark_w, .h = 20 }, edition, true);
    }
}

pub fn mastheadEdition(width: i32) []const u8 {
    return if (width >= 860) "Sunday / Ink" else "Sunday";
}

pub fn drawBrandMark(c: *Canvas, rect: Rect) void {
    if (rect.w < 16 or rect.h < 16) return;
    const body_h = @max(10, rect.h - 6);
    fillRoundedRect(c, rect.x, rect.y, rect.w, body_h, 5, current.accent);
    fillRoundedRect(c, rect.x + 3, rect.y + 3, @max(0, rect.w - 6), @max(0, body_h - 6), 4, current.paper);
    fillRoundedRect(c, rect.x + 5, rect.y + 5, 4, 4, 2, current.accent);
    c.fillTriangle(
        rect.x + 5,
        rect.y + body_h - 1,
        rect.x + 2,
        rect.bottom() - 1,
        rect.x + 12,
        rect.y + body_h - 1,
        current.accent,
    );
}

/// Shared application identity for the desktop menu bar.
pub fn drawAppBrand(c: *Canvas, rect: Rect, name: []const u8) void {
    drawBrandMark(c, .{ .x = rect.x + 10, .y = rect.y + 4, .w = 26, .h = 26 });
    drawEllipsized(c, name, rect.x + 44, rect.y + 7, rect.w - 52, current.navigation_ink);
    const rule_w = @min(Canvas.uiTextWidth(name), @max(0, rect.w - 52));
    c.fillRect(rect.x + 44, rect.y + 24, rule_w, 2, current.accent);
}

pub fn drawToolbarSurface(c: *Canvas, rect: Rect) void {
    c.fillRect(rect.x, rect.y, rect.w, rect.h, current.paper);
    c.fillRect(rect.x, rect.y, rect.w, 2, current.accent);
    c.fillRect(rect.x, rect.bottom() - 2, rect.w, 2, current.ink);
    if (rect.w >= 760) {
        const mark_w = Canvas.uiTextWidth("INK") + 20;
        drawInkPlate(c, rect.right() - mark_w - 10, rect.y + 12, mark_w, 22, 2, current.accent);
        drawEllipsized(c, "INK", rect.right() - mark_w - 2, rect.y + 14, mark_w - 16, current.layer);
    }
}

pub fn drawToolbarGroup(c: *Canvas, rect: Rect) void {
    drawInkPlate(c, rect.x, rect.y, rect.w, rect.h, 3, current.layer);
    c.fillRect(rect.x + stroke, rect.y + stroke, @max(0, rect.w - stroke * 2), 2, current.accent);
}

/// Shared geometry for the compact primary toolbar.  Button rectangles, group
/// frames, and tooltip anchors all come from this one source so a responsive
/// shell cannot draw a tool in a different place than it describes it.
pub const ToolbarLayout = struct {
    rect: Rect,

    pub const group_counts = [_]i32{ 3, 2, 2, 3, 2 };
    pub const button_count: usize = 12;
    /// The compact toolbar deliberately shows the most useful commands from
    /// the larger historical command set.  Rendering, hit testing, keyboard
    /// navigation, and accessibility all use this single order.
    pub const command_ids = [_]u8{ 0, 2, 4, 5, 6, 7, 8, 10, 11, 13, 17, 18 };
    const group_gap: i32 = 8;
    const group_inset: i32 = 4;
    const button_pitch: i32 = 38;
    const button_size: i32 = 32;

    pub fn init(rect: Rect) ToolbarLayout {
        return .{ .rect = rect };
    }

    pub fn groupRect(self: ToolbarLayout, group: usize) ?Rect {
        if (group >= group_counts.len) return null;
        var x = self.rect.x + 8;
        for (group_counts[0..group]) |count| x += count * button_pitch + group_inset + group_gap;
        const width = group_counts[group] * button_pitch + group_inset;
        const result = Rect{ .x = x, .y = self.rect.y + 5, .w = width, .h = 36 };
        return if (result.x >= self.rect.right()) null else result;
    }

    pub fn buttonRect(self: ToolbarLayout, index: usize) ?Rect {
        if (index >= button_count) return null;
        var remaining: i32 = @intCast(index);
        var group: usize = 0;
        while (group < group_counts.len) : (group += 1) {
            const count = group_counts[group];
            if (remaining < count) {
                const frame = self.groupRect(group) orelse return null;
                const result = Rect{ .x = frame.x + group_inset + remaining * button_pitch, .y = self.rect.y + @divTrunc(self.rect.h - button_size, 2), .w = button_size, .h = button_size };
                return if (result.right() <= self.rect.right()) result else null;
            }
            remaining -= count;
        }
        return null;
    }
};

/// Shared menu/context popup item geometry.  Labels and commands remain owned
/// by the client, while every popup agrees on padding, row stride, and bounds.
pub const PopupLayout = struct {
    rect: Rect,
    item_count: u8,
    pub const row_height: i32 = 29;
    pub const outer_padding: i32 = 5;

    pub fn menu(canvas_width: u32, anchor_x: i32, top_y: i32, width: i32, item_count: u8) PopupLayout {
        const bounded_w = @min(width, @max(210, @as(i32, @intCast(canvas_width)) - 12));
        const right_limit = @max(6, @as(i32, @intCast(canvas_width)) - bounded_w - 6);
        return .{ .rect = .{ .x = std.math.clamp(anchor_x, 6, right_limit), .y = top_y, .w = bounded_w, .h = @as(i32, item_count) * row_height + 10 }, .item_count = item_count };
    }

    pub fn anchored(canvas_width: u32, canvas_height: u32, anchor_x: i32, anchor_y: i32, width: i32, item_count: u8) PopupLayout {
        const height = @as(i32, item_count) * row_height + 10;
        const canvas_w: i32 = @intCast(canvas_width);
        const canvas_h: i32 = @intCast(canvas_height);
        return .{ .rect = .{ .x = std.math.clamp(anchor_x, 6, @max(6, canvas_w - width - 6)), .y = std.math.clamp(anchor_y, 6, @max(6, canvas_h - height - 6)), .w = width, .h = height }, .item_count = item_count };
    }

    pub fn itemRect(self: PopupLayout, index: u8) ?Rect {
        if (index >= self.item_count) return null;
        return .{ .x = self.rect.x + outer_padding, .y = self.rect.y + outer_padding + @as(i32, index) * row_height, .w = self.rect.w - outer_padding * 2, .h = 27 };
    }

    pub fn itemAt(self: PopupLayout, x: i32, y: i32) ?u8 {
        if (x < self.rect.x or x >= self.rect.right() or y < self.rect.y + 4 or y >= self.rect.bottom() - 4) return null;
        const index = @divTrunc(y - self.rect.y - outer_padding, row_height);
        if (index < 0 or index >= self.item_count) return null;
        const item: u8 = @intCast(index);
        return if (contains(self.itemRect(item).?, x, y)) item else null;
    }
};

pub fn drawPopupSurface(c: *Canvas, rect: Rect) void {
    fillRoundedRect(c, rect.x + 6, rect.y + 8, rect.w, rect.h, 2, current.shadow);
    drawInkPlate(c, rect.x, rect.y, rect.w, rect.h, 2, current.paper);
    c.fillRect(rect.x + stroke, rect.y + stroke, @max(0, rect.w - stroke * 2), stroke, current.layer);
    c.fillRect(rect.x + 8, rect.y + stroke, 12, stroke, current.accent);
    c.fillRect(rect.x, rect.y, 5, rect.h, current.accent);
    drawInkRule(c, rect.x + 5, rect.y, 1, rect.h, current.ink);
    c.fillRect(rect.x, rect.bottom() - 3, rect.w, 3, current.ink);
}

pub fn drawPopupListSurface(c: *Canvas, layout: PopupLayout) void {
    drawPopupSurface(c, layout.rect);
}

/// A popover with a visible origin.  Use this for temporary surfaces opened
/// from a fixed shell control so users can tell what remains underneath.
pub fn drawAnchoredPopoverSurface(c: *Canvas, rect: Rect, anchor_x: i32) void {
    const tip_x = std.math.clamp(anchor_x, rect.x + 14, rect.right() - 14);
    c.fillTriangle(tip_x - 7, rect.y, tip_x, rect.y - 7, tip_x + 7, rect.y, current.divider);
    c.fillTriangle(tip_x - 5, rect.y, tip_x, rect.y - 5, tip_x + 5, rect.y, current.layer);
    drawPopupSurface(c, rect);
}

pub fn drawToolbarSeparator(c: *Canvas, x: i32, rect: Rect) i32 {
    drawInkRule(c, x + 5, rect.y + 9, 1, rect.h - 18, current.divider);
    return x + 12;
}

pub fn drawSplitter(c: *Canvas, rect: Rect) void {
    c.fillRect(rect.x, rect.y, rect.w, rect.h, current.workspace);
    if (rect.w > rect.h) c.fillRect(rect.x + @divTrunc(rect.w - 48, 2), rect.y + @divTrunc(rect.h - 3, 2), @min(48, rect.w), 3, current.ink);
    if (rect.h > rect.w) c.fillRect(rect.x + @divTrunc(rect.w - 3, 2), rect.y + @divTrunc(rect.h - 48, 2), 3, @min(48, rect.h), current.ink);
}

pub fn drawVerticalScrollbar(c: *Canvas, rect: Rect, total: usize, visible: usize, first: usize) void {
    if (rect.h < 36 or visible == 0 or total <= visible) return;
    const track = Rect{ .x = rect.right() - 10, .y = rect.y + 7, .w = 5, .h = rect.h - 14 };
    fillRoundedRect(c, track.x, track.y, track.w, track.h, 3, current.subtle);
    const thumb_h = @max(28, @divTrunc(track.h * @as(i32, @intCast(visible)), @as(i32, @intCast(total))));
    const max_first = total - visible;
    const bounded_first = @min(first, max_first);
    const thumb_y = track.y + @divTrunc((track.h - thumb_h) * @as(i32, @intCast(bounded_first)), @as(i32, @intCast(max_first)));
    fillRoundedRect(c, track.x, thumb_y, track.w, thumb_h, 3, current.secondary);
}

pub fn drawContentSurface(c: *Canvas, rect: Rect, comic: bool) void {
    if (comic) {
        drawPageWell(c, rect);
    } else {
        c.fillRect(rect.x, rect.y, rect.w, rect.h, current.workspace);
    }
}

/// Newsprint matte and ink frame around the 1:1 source page. The inner
/// paper starts at the same +8 inset the view uses for `blitSourcePage`.
pub fn drawPageWell(c: *Canvas, rect: Rect) void {
    c.fillRect(rect.x, rect.y, rect.w, rect.h, current.comic_paper);
    if (rect.w < 28 or rect.h < 28) return;
    const page = Rect{ .x = rect.x + 6, .y = rect.y + 6, .w = rect.w - 12, .h = rect.h - 12 };
    fillRoundedRect(c, page.x + 4, page.y + 5, page.w, page.h, 2, current.shadow);
    drawInkPlate(c, page.x, page.y, page.w, page.h, 2, current.artwork_paper);
    drawOutline(c, page.x + 4, page.y + 4, page.w - 8, page.h - 8, current.divider);
    drawPageCorner(c, page.x, page.y, 1, 1);
    drawPageCorner(c, page.right() - 1, page.y, -1, 1);
    drawPageCorner(c, page.x, page.bottom() - 1, 1, -1);
    drawPageCorner(c, page.right() - 1, page.bottom() - 1, -1, -1);
}

fn drawPageCorner(c: *Canvas, x: i32, y: i32, dx: i32, dy: i32) void {
    const tick: i32 = 10;
    const hx = if (dx < 0) x - tick + 1 else x;
    const vy = if (dy < 0) y - tick + 1 else y;
    c.fillRect(hx, y, tick, stroke, current.accent);
    c.fillRect(x, vy, stroke, tick, current.accent);
}

pub fn drawTabStrip(c: *Canvas, rect: Rect) void {
    c.fillRect(rect.x, rect.y, rect.w, rect.h, current.comic_paper);
    c.fillRect(rect.x, rect.y, rect.w, 2, current.layer);
    c.fillRect(rect.x, rect.bottom() - 2, rect.w, 2, current.ink);
}

pub fn drawStatusTab(c: *Canvas, rect: Rect, selected: bool, hovered: bool) void {
    const fill = if (selected) current.accent else if (hovered) current.accent_soft else current.paper;
    drawInkPlate(c, rect.x + 8, rect.y + 6, 96, rect.h - 12, 2, fill);
    if (!selected) c.fillRect(rect.x + 10, rect.y + 8, 92, 2, current.accent);
}

pub fn drawStatusTabContent(c: *Canvas, rect: Rect, selected: bool, tone: NoticeTone, label: []const u8) void {
    const mark = switch (tone) {
        .success => current.success,
        .warning => current.warning,
        .failure => current.failure,
        .info => if (selected) current.layer else current.accent,
    };
    const text = if (selected) current.layer else current.ink;
    fillRoundedRect(c, rect.x + 16, rect.y + 12, 12, 9, 2, mark);
    _ = c.drawUiText(label, rect.x + 36, rect.y + 9, text);
}

pub fn drawMemberCard(c: *Canvas, rect: Rect, selected: bool, departed: bool, away: bool, hovered: bool) void {
    const card = Rect{ .x = rect.x + 4, .y = rect.y + 4, .w = rect.w - 8, .h = rect.h - 8 };
    const fill = if (selected) current.accent_soft else if (hovered) current.paper else current.layer;
    drawInkPlate(c, card.x, card.y, card.w, card.h, 2, fill);
    c.fillRect(card.x, card.y, 4, card.h, if (selected) current.accent else current.ink);
    fillRoundedRect(c, rect.x + 12, rect.y + 9, 8, 8, 4, if (departed) current.divider else if (away) current.warning else current.success);
    const plate_h: i32 = 20;
    if (card.h > plate_h + 8) {
        c.fillRect(card.x + 4, card.bottom() - plate_h, card.w - 4, plate_h, current.paper);
        drawInkRule(c, card.x + 4, card.bottom() - plate_h, card.w - 4, 1, current.ink);
    }
}

pub fn drawInspectorRail(c: *Canvas, rect: Rect) void {
    if (rect.w <= 0 or rect.h <= 0) return;
    c.fillRect(rect.x, rect.y, rect.w, rect.h, current.rail);
    c.fillRect(rect.x, rect.y, 3, rect.h, current.ink);
    c.fillRect(rect.x + 3, rect.y, 2, rect.h, current.accent);
}

pub fn drawMemberRailSurface(c: *Canvas, rect: Rect) void {
    drawInspectorRail(c, rect);
}

pub fn drawCharacterPane(c: *Canvas, rect: Rect) void {
    c.fillRect(rect.x, rect.y, rect.w, rect.h, current.rail);
    const frame = Rect{ .x = rect.x + 10, .y = rect.y + 30, .w = @max(0, rect.w - 20), .h = @max(0, rect.h - 38) };
    if (frame.w > 0 and frame.h > 0) {
        fillRoundedRect(c, frame.x + 3, frame.y + 4, frame.w, frame.h, 2, current.shadow);
        drawInkPlate(c, frame.x, frame.y, frame.w, frame.h, 2, current.artwork_paper);
    }
}

/// The expression picker is an intentional control surface, rather than a
/// leftover slab beneath the character preview.  The caller draws the dial
/// and authored expression marks inside the returned interior.
pub fn drawExpressionPanel(c: *Canvas, rect: Rect, selection: []const u8) void {
    c.fillRect(rect.x, rect.y, rect.w, rect.h, current.rail);
    const plate = Rect{ .x = rect.x + 8, .y = rect.y + 2, .w = @max(0, rect.w - 16), .h = @max(0, rect.h - 8) };
    if (plate.w > 0 and plate.h > 0) drawInkPlate(c, plate.x, plate.y, plate.w, plate.h, 2, current.paper);
    fillRoundedRect(c, rect.x + 18, rect.y + 11, 5, 5, 3, current.accent);
    const label_w = @min(@max(40, rect.w - 44), Canvas.uiTextWidth(selection) + 20);
    const label_x = rect.right() - label_w - 12;
    const mood_w = label_x - (rect.x + 31) - 6;
    if (mood_w >= Canvas.uiTextWidth("Mood")) _ = c.drawUiText("Mood", rect.x + 31, rect.y + 6, current.ink);
    drawPill(c, .{ .x = label_x, .y = rect.y + 5, .w = label_w, .h = 20 }, selection, true);
    c.fillRect(rect.x + 18, rect.y + 31, rect.w - 36, 2, current.ink);
}

/// The interactive portion of a radial mood dial.  Input code uses this same
/// rectangle, so the visible dial and its pointer target cannot drift apart.
pub fn moodDialInterior(rect: Rect) Rect {
    return .{ .x = rect.x + 8, .y = rect.y + 30, .w = @max(0, rect.w - 16), .h = @max(0, rect.h - 38) };
}

/// Shared radial expression control.  The view owns emotion input/state while
/// this component owns every themed visual: panel, dial rings, mood grid, and
/// selection puck.
pub fn drawMoodDial(c: *Canvas, rect: Rect, label: []const u8, selector_x: i16, selector_y: i16, selector_radius: i16) void {
    drawExpressionPanel(c, rect, label);
    const dial = moodDialInterior(rect);
    const cx = dial.x + @divTrunc(dial.w, 2);
    const cy = dial.y + @divTrunc(dial.h, 2);
    const radius = @max(1, @min(@divTrunc(dial.w, 2), @divTrunc(dial.h, 2)) - 9);
    drawAaDisc(c, cx + 2, cy + 3, @floatFromInt(radius), current.shadow);
    drawAaRing(c, cx, cy, @floatFromInt(radius), 2.0, current.paper, current.ink);
    drawAaRing(c, cx, cy, @floatFromInt(@max(1, radius - 7)), 1.2, current.paper, current.accent);

    const directions = [_][2]i32{
        .{ -707, -707 }, .{ 0, -1000 }, .{ 707, -707 },
        .{ -1000, 0 },   .{ 1000, 0 },  .{ -707, 707 },
        .{ 0, 1000 },    .{ 707, 707 },
    };
    const glyph_positions = [_][2]i32{ .{ 0, 0 }, .{ 0, 1 }, .{ 0, 2 }, .{ 1, 0 }, .{ 1, 2 }, .{ 2, 0 }, .{ 2, 1 }, .{ 2, 2 } };
    const selected_col = moodGridCoordinate(selector_x);
    const selected_row = moodGridCoordinate(selector_y);
    const icon_radius = @max(14, radius - 10);
    for (directions, glyph_positions) |direction, glyph_position| {
        const gx = cx + @divTrunc(direction[0] * icon_radius, 1000);
        const gy = cy + @divTrunc(direction[1] * icon_radius, 1000);
        const selected = glyph_position[1] == selected_col and glyph_position[0] == selected_row;
        drawMoodGlyph(c, gx, gy, @enumFromInt(glyph_position[0] * 3 + glyph_position[1]), selected);
    }
    drawMoodGlyph(c, cx, cy, .neutral, selected_col == 1 and selected_row == 1);

    const source_radius = @max(1, @as(i32, selector_radius));
    const travel = @max(1, radius - 18);
    const puck_x = cx + @divTrunc(@as(i32, selector_x) * travel, source_radius);
    const puck_y = cy + @divTrunc(@as(i32, selector_y) * travel, source_radius);
    drawAaDisc(c, puck_x + 1, puck_y + 2, 5.5, current.shadow);
    drawAaDisc(c, puck_x, puck_y, 5.5, current.layer);
    drawAaDisc(c, puck_x, puck_y, 3.5, current.accent);
}

fn moodGridCoordinate(value: i16) i32 {
    if (value < -5) return 0;
    if (value > 5) return 2;
    return 1;
}

pub fn drawComposerSurface(c: *Canvas, rect: Rect) void {
    c.fillRect(rect.x, rect.y, rect.w, rect.h, current.paper);
    c.fillRect(rect.x, rect.y, rect.w, 3, current.ink);
    c.fillRect(rect.x, rect.bottom() - 2, rect.w, 2, current.ink);
    c.fillRect(rect.x, rect.y + 3, 5, @max(0, rect.h - 5), current.accent);
    drawInkRule(c, rect.x + 5, rect.y + 3, 1, @max(0, rect.h - 5), current.ink);
    if (rect.w > 16 and rect.h > 14)
        c.fillRect(rect.x + 8, rect.y + 6, @max(0, rect.w - 10), @max(0, rect.h - 10), current.layer);
}

pub fn drawHistoryBanner(c: *Canvas, rect: Rect, label: []const u8) void {
    const width = @min(rect.w - 12, Canvas.uiTextWidth(label) + 22);
    drawInkPlate(c, rect.x + 6, rect.y + 6, width, 25, 3, current.paper);
    c.fillRect(rect.x + 8, rect.y + 8, 3, 21, current.accent);
    _ = c.drawUiText(label, rect.x + 16, rect.y + 8, current.ink);
}

pub fn drawTab(c: *Canvas, x: i32, y: i32, width: i32, height: i32, selected: bool, hovered: bool) void {
    if (selected) {
        drawInkPlate(c, x, y + 4, width, height - 4, 2, current.paper);
        c.fillRect(x + stroke, y + 6, width - stroke * 2, 3, current.accent);
        c.fillRect(x + stroke, y + height - 2, width - stroke * 2, 2, current.paper);
    } else if (hovered) {
        drawInkPlate(c, x + 1, y + 6, width - 2, height - 10, 2, current.paper);
        c.fillRect(x + 3, y + 8, width - 6, 2, current.accent);
    } else {
        drawInkPlate(c, x + 2, y + 8, width - 4, height - 12, 2, current.layer);
    }
}

const ConversationTabLayout = struct {
    badge_w: i32,
    label_right: i32,
};

fn conversationTabLayout(rect: Rect, unread: usize) ConversationTabLayout {
    var unread_buf: [24]u8 = undefined;
    const unread_label = if (unread > 0) std.fmt.bufPrint(&unread_buf, "{d}", .{unread}) catch "!" else "";
    const badge_w: i32 = if (unread == 0) 0 else Canvas.uiTextWidth(unread_label) + 16;
    return .{
        .badge_w = badge_w,
        .label_right = if (unread == 0) rect.right() - 14 else rect.right() - badge_w - 14,
    };
}

pub fn drawConversationTab(c: *Canvas, rect: Rect, label: []const u8, unread: usize, selected: bool, focused: bool, hovered: bool) void {
    drawTab(c, rect.x, rect.y, rect.w, rect.h, selected, hovered);
    const text_color = if (selected) current.ink else if (unread > 0) current.accent else current.secondary;
    const tab_layout = conversationTabLayout(rect, unread);
    var unread_buf: [24]u8 = undefined;
    const unread_label = if (unread > 0) std.fmt.bufPrint(&unread_buf, "{d}", .{unread}) catch "!" else "";
    drawEllipsized(c, label, rect.x + 14, rect.y + 4, tab_layout.label_right - rect.x - 14, text_color);
    if (unread > 0) {
        const badge = Rect{ .x = rect.right() - tab_layout.badge_w - 8, .y = rect.y + 7, .w = tab_layout.badge_w, .h = 16 };
        drawInkPlate(c, badge.x, badge.y, badge.w, badge.h, 6, current.accent);
        const unread_x = badge.x + @divTrunc(badge.w - Canvas.uiTextWidth(unread_label), 2);
        _ = c.drawUiText(unread_label, unread_x, rect.y + 8, current.layer);
    }
    if (focused) drawFocusRing(c, .{ .x = rect.x, .y = rect.y - 3, .w = rect.w, .h = rect.h + 3 });
}

pub fn drawActionTile(c: *Canvas, x: i32, y: i32, width: i32, height: i32, selected: bool, hovered: bool) u32 {
    return drawActionTileState(c, x, y, width, height, selected, hovered, false);
}

pub fn drawActionTileState(c: *Canvas, x: i32, y: i32, width: i32, height: i32, selected: bool, hovered: bool, disabled: bool) u32 {
    const inset = Rect{ .x = x + 5, .y = y + 7, .w = width - 10, .h = height - 14 };
    if (disabled) {
        drawInkPlate(c, inset.x, inset.y, inset.w, inset.h, 2, current.chrome);
        c.fillRect(inset.x + stroke, inset.y + stroke, @max(0, inset.w - stroke * 2), 2, current.divider);
        return current.divider;
    }
    if (selected) {
        drawInkPlate(c, inset.x, inset.y, inset.w, inset.h, 2, current.accent);
        return current.layer;
    }
    drawInkPlate(c, inset.x, inset.y, inset.w, inset.h, 2, if (hovered) current.accent_soft else current.paper);
    if (hovered) c.fillRect(inset.x + stroke, inset.y + stroke, @max(0, inset.w - stroke * 2), 3, current.accent);
    return if (hovered) current.accent else current.ink;
}

pub fn drawFocusRing(c: *Canvas, rect: Rect) void {
    if (rect.w < 4 or rect.h < 4) return;
    c.fillRect(rect.x, rect.y, rect.w, 2, current.focus);
    c.fillRect(rect.x, rect.bottom() - 2, rect.w, 2, current.focus);
    c.fillRect(rect.x, rect.y, 2, rect.h, current.focus);
    c.fillRect(rect.right() - 2, rect.y, 2, rect.h, current.focus);
}

pub fn drawComposerField(c: *Canvas, rect: Rect, focused: bool, hovered: bool, populated: bool) void {
    const field = Rect{ .x = rect.x + 9, .y = rect.y + 7, .w = @max(0, rect.w - 18), .h = @max(0, rect.h - 14) };
    drawInputControl(c, field, .composer, .{ .focused = focused, .hovered = hovered, .populated = populated });
}

/// Geometry and base drawing for the editable composer. Text splitting and
/// cursor ownership remain client concerns, but every adornment derives from
/// these same bounds.
pub const ComposerEditorLayout = struct {
    edit: Rect,
    content: Rect,

    pub fn init(edit: Rect) ComposerEditorLayout {
        return .{ .edit = edit, .content = .{ .x = edit.x + 18, .y = edit.y + 10, .w = @max(0, edit.w - 36), .h = @max(0, edit.h - 20) } };
    }

    pub fn rowY(self: ComposerEditorLayout, row_index: usize, row_count: usize) i32 {
        return if (row_count <= 1) self.edit.y + 13 else self.edit.y + 7 + @as(i32, @intCast(row_index)) * 18;
    }

    pub fn selectionRect(_: ComposerEditorLayout, x: i32, y: i32, width: i32) Rect {
        return .{ .x = x, .y = y + 1, .w = width, .h = 17 };
    }

    pub fn caretX(self: ComposerEditorLayout, requested_x: i32) i32 {
        return @min(self.edit.right() - 12, requested_x);
    }

    pub fn rowAtY(self: ComposerEditorLayout, pointer_y: i32, row_count: usize) usize {
        return if (row_count > 1 and pointer_y >= self.rowY(1, row_count) + 1) 1 else 0;
    }
};

pub fn drawComposerEditor(c: *Canvas, layout: ComposerEditorLayout, focused: bool, hovered: bool, populated: bool) void {
    drawComposerField(c, layout.edit, focused, hovered, populated);
}

pub fn drawComposerModeChip(c: *Canvas, rect: Rect, label: []const u8, hot: bool) void {
    drawInkPlate(c, rect.x, rect.y, rect.w, rect.h, 2, if (hot) current.accent else current.subtle);
    drawEllipsized(c, label, rect.x + 6, rect.y + @max(0, @divTrunc(rect.h - 17, 2)), rect.w - 12, if (hot) current.layer else current.ink);
}

pub fn drawComposerOverflowMarks(c: *Canvas, layout: ComposerEditorLayout, left_hidden: bool, right_hidden: bool) void {
    drawInputOverflowMarks(c, layout.edit, left_hidden, right_hidden);
}

/// Overflow affordances shared by dialog editors and the composer.
pub fn drawInputOverflowMarks(c: *Canvas, rect: Rect, left_hidden: bool, right_hidden: bool) void {
    if (left_hidden) drawTextOverflowMark(c, rect.x + 9, rect.y + 9, rect.h - 18);
    if (right_hidden) drawTextOverflowMark(c, rect.right() - 12, rect.y + 9, rect.h - 18);
}

pub fn drawBrowseButton(c: *Canvas, rect: Rect, hovered: bool) void {
    drawInkPlate(c, rect.x, rect.y, rect.w, rect.h, 3, if (hovered) current.accent_soft else current.chrome);
    if (hovered) c.fillRect(rect.x + stroke, rect.y + stroke, @max(0, rect.w - stroke * 2), 2, current.accent);
    _ = c.drawUiText("Choose", rect.x + @max(7, @divTrunc(rect.w - Canvas.uiTextWidth("Choose"), 2)), rect.y + @divTrunc(rect.h - 14, 2), current.accent);
}

pub fn drawPreviewChoiceCard(c: *Canvas, rect: Rect, active: bool) void {
    drawInkPlate(c, rect.x, rect.y, rect.w, rect.h, 3, if (active) current.accent_soft else current.chrome);
    if (active) c.fillRect(rect.x + stroke, rect.y + stroke, @max(0, rect.w - stroke * 2), 2, current.accent);
}

/// Stable frame and content bounds for a decoded character or backdrop asset.
/// The view owns decoding/scaling; the UI library owns the chrome around it.
pub const AssetPreviewLayout = struct {
    frame: Rect,
    artwork: Rect,
    label: Rect,

    pub fn card(rect: Rect) AssetPreviewLayout {
        const label_h: i32 = if (rect.h >= 42) 20 else 0;
        return .{
            .frame = rect,
            .artwork = .{ .x = rect.x + 8, .y = rect.y + 7, .w = @max(0, rect.w - 16), .h = @max(0, rect.h - label_h - 12) },
            .label = .{ .x = rect.x + 6, .y = rect.bottom() - label_h - 2, .w = @max(0, rect.w - 12), .h = label_h },
        };
    }

    pub fn inlinePreview(rect: Rect, artwork_width: i32) AssetPreviewLayout {
        const image_w = @min(@max(0, artwork_width), @max(0, rect.w - 18));
        return .{
            .frame = .{ .x = rect.x + 6, .y = rect.y + 3, .w = image_w, .h = @max(0, rect.h - 6) },
            .artwork = .{ .x = rect.x + 8, .y = rect.y + 5, .w = @max(0, image_w - 4), .h = @max(0, rect.h - 10) },
            .label = .{ .x = rect.x + image_w + 14, .y = rect.y + @divTrunc(rect.h - 17, 2), .w = @max(0, rect.w - image_w - 22), .h = 17 },
        };
    }
};

pub fn drawAssetPreviewFrame(c: *Canvas, layout: AssetPreviewLayout, active: bool) void {
    drawPreviewChoiceCard(c, layout.frame, active);
    if (layout.artwork.w > 0 and layout.artwork.h > 0)
        fillRoundedRect(c, layout.artwork.x, layout.artwork.y, layout.artwork.w, layout.artwork.h, 3, current.artwork_paper);
}

/// Compact family selector used where a gallery has multiple complete visual
/// treatments. Every segment is a real target, not a decorative label.
pub fn drawSegmentedChoice(c: *Canvas, rect: Rect, labels: []const []const u8, selected: usize) void {
    if (labels.len == 0 or rect.w <= 0 or rect.h <= 0) return;
    fillRoundedRect(c, rect.x, rect.y, rect.w, rect.h, 3, current.subtle);
    const segment_w = @divTrunc(rect.w, @as(i32, @intCast(labels.len)));
    for (labels, 0..) |label, index| {
        const x = rect.x + @as(i32, @intCast(index)) * segment_w;
        const w = if (index + 1 == labels.len) rect.right() - x else segment_w;
        const active = index == selected;
        if (active) fillRoundedRect(c, x + 2, rect.y + 2, w - 4, rect.h - 4, 3, current.layer);
        const color = if (active) current.accent else current.secondary;
        const available = @max(0, w - 10);
        const text_w = Canvas.uiTextWidth(label);
        if (text_w <= available)
            _ = c.drawUiText(label, x + @divTrunc(w - text_w, 2), rect.y + @divTrunc(rect.h - 17, 2), color)
        else
            drawEllipsized(c, label, x + 5, rect.y + @divTrunc(rect.h - 17, 2), available, color);
    }
}

pub fn drawTextSelection(c: *Canvas, rect: Rect) void {
    fillRoundedRect(c, rect.x, rect.y, @max(1, rect.w), @max(1, rect.h), 3, current.accent_soft);
}

pub fn drawTextCaret(c: *Canvas, x: i32, y: i32, height: i32) void {
    c.fillRect(x, y, 2, @max(1, height), current.accent);
}

pub fn drawTextOverflowMark(c: *Canvas, x: i32, y: i32, height: i32) void {
    fillRoundedRect(c, x, y, 3, @max(4, height), 2, current.accent_soft);
    c.fillRect(x + 1, y + 3, 1, @max(2, height - 6), current.accent);
}

pub fn drawStatusIdentity(c: *Canvas, rect: Rect, tone: NoticeTone) void {
    const color: u32 = switch (tone) {
        .success => current.success,
        .warning => current.warning,
        .failure => current.failure,
        .info => current.accent,
    };
    fillRoundedRect(c, rect.x, rect.y, rect.w, rect.h, 3, current.accent_soft);
    const disc = @max(6, @divTrunc(@min(rect.w, rect.h), 3));
    fillRoundedRect(c, rect.x + @divTrunc(rect.w - disc, 2), rect.y + @divTrunc(rect.h - disc, 2), disc, disc, @divTrunc(disc, 2), color);
}

pub fn drawSectionRule(c: *Canvas, x: i32, y: i32, width: i32) void {
    drawInkRule(c, x, y, @max(0, width), 1, current.divider);
    c.fillRect(x, y, @min(12, @max(0, width)), stroke, current.accent);
}

pub fn drawStatusMetric(c: *Canvas, x: i32, y: i32, label: []const u8, value: []const u8, max_width: i32) void {
    _ = c.drawUiText(label, x, y, current.secondary);
    drawEllipsized(c, value, x, y + 17, max_width, current.ink);
}

pub fn drawStatusMetricCard(c: *Canvas, rect: Rect, label: []const u8, value: []const u8) void {
    drawInkPlate(c, rect.x, rect.y, rect.w, rect.h, 3, current.paper);
    _ = c.drawUiText(label, rect.x + 9, rect.y + 5, current.secondary);
    drawEllipsized(c, value, rect.x + 9, rect.y + 20, rect.w - 18, current.ink);
}

pub fn drawStepper(c: *Canvas, rect: Rect, decrease_hovered: bool, increase_hovered: bool) void {
    drawInkPlate(c, rect.x, rect.y, rect.w, rect.h, 3, current.paper);
    if (decrease_hovered) c.fillRect(rect.x + stroke, rect.y + stroke, 29, rect.h - stroke * 2, current.accent_soft);
    if (increase_hovered) c.fillRect(rect.right() - 30, rect.y + stroke, 29, rect.h - stroke * 2, current.accent_soft);
    drawInkRule(c, rect.x + 30, rect.y + 5, 1, rect.h - 10, current.ink);
    drawInkRule(c, rect.right() - 31, rect.y + 5, 1, rect.h - 10, current.ink);
}

pub fn drawLabeledStepper(c: *Canvas, rect: Rect, label: []const u8, decrease_hovered: bool, increase_hovered: bool) void {
    drawStepper(c, rect, decrease_hovered, increase_hovered);
    c.drawLine(rect.x + 10, rect.y + 13, rect.x + 19, rect.y + 13, current.secondary);
    c.drawLine(rect.right() - 20, rect.y + 13, rect.right() - 11, rect.y + 13, current.secondary);
    c.drawLine(rect.right() - 16, rect.y + 9, rect.right() - 16, rect.y + 18, current.secondary);
    _ = c.drawUiText(label, rect.x + @divTrunc(rect.w - Canvas.uiTextWidth(label), 2), rect.y + 3, current.ink);
}

const MessageRowLayout = struct {
    speaker_w: i32,
    left: i32,
    text_x: i32,
    text_w: i32,
};

fn messageRowLayout(rect: Rect, continued: bool) MessageRowLayout {
    // A stable speaker rail keeps every message column aligned while giving
    // everyday IRC nicknames enough room to remain whole.
    const speaker_w = std.math.clamp(@divTrunc(rect.w, 5), 72, 104);
    const left = if (continued) rect.x + 24 else rect.x + 7;
    const text_x = if (continued) rect.x + 32 else rect.x + speaker_w + 14;
    return .{
        .speaker_w = speaker_w,
        .left = left,
        .text_x = text_x,
        .text_w = if (continued) rect.right() - text_x - 16 else rect.right() - text_x - 16,
    };
}

pub fn drawMessageRow(c: *Canvas, rect: Rect, nick: []const u8, text: []const u8, alternate: bool, selected: bool, continued: bool, own: bool) void {
    const layout = messageRowLayout(rect, continued);
    const speaker_color = if (own) current.success else current.accent;
    const speaker_soft = if (own) current.success_soft else current.accent_soft;
    const background = if (selected) current.accent_soft else if (own) speaker_soft else if (alternate) current.chrome else current.paper;
    drawInkPlate(c, layout.left, rect.y - 1, rect.right() - layout.left - 7, rect.h - 4, 3, background);
    if (continued) {
        c.fillRect(rect.x + 16, rect.y + 9, 3, rect.h - 23, speaker_color);
        c.fillRect(rect.x + 14, rect.y + 5, 7, 7, speaker_color);
    } else {
        c.fillRect(rect.x + 7, rect.y + 5, 3, rect.h - 15, speaker_color);
        c.fillRect(rect.x + 16, rect.y + 2, layout.speaker_w - 8, 18, speaker_soft);
        drawEllipsized(c, nick, rect.x + 20, rect.y + 3, layout.speaker_w - 16, speaker_color);
    }
    const split = messageWrapPoint(text, layout.text_w);
    drawEllipsized(c, text[0..split], layout.text_x, rect.y + 3, layout.text_w, current.ink);
    if (split < text.len) {
        const rest = if (text[split] == ' ') text[split + 1 ..] else text[split..];
        drawEllipsized(c, rest, layout.text_x, rect.y + 21, layout.text_w, current.secondary);
    }
}

pub fn drawConversationPresenceDot(c: *Canvas, x: i32, y: i32, live: bool) void {
    fillRoundedRect(c, x, y, 6, 6, 3, if (live) current.success else current.warning);
}

pub fn drawConversationTitle(c: *Canvas, x: i32, y: i32) void {
    _ = c.drawUiText("Conversation", x, y, current.ink);
}

pub fn drawConversationSummary(c: *Canvas, x: i32, y: i32, width: i32, count: usize, members: usize) void {
    var summary_buf: [32]u8 = undefined;
    const summary = std.fmt.bufPrint(&summary_buf, "{d} lines / {d} here", .{ count, members }) catch "";
    drawEllipsized(c, summary, x, y, width, current.navigation_muted);
}

pub fn drawConversationStateBadge(c: *Canvas, x: i32, y: i32, live: bool) void {
    const mode = if (live) "Live" else "Earlier";
    const width = Canvas.uiTextWidth(mode) + 18;
    drawInkPlate(c, x - width, y, width, 16, 2, if (live) current.accent else current.notice_warning);
    _ = c.drawUiText(mode, x - width + 9, y + 1, if (live) current.layer else current.ink);
}

pub fn drawConversationRule(c: *Canvas, rect: Rect) void {
    c.fillRect(rect.x + 12, rect.bottom() - 2, @max(0, rect.w - 24), 2, current.ink);
}

pub fn drawConversationHeader(c: *Canvas, rect: Rect, count: usize, members: usize, live: bool) void {
    c.fillRect(rect.x, rect.y, rect.w, 30, current.navigation);
    c.fillRect(rect.x, rect.y + 25, rect.w, 2, current.ink);
    c.fillRect(rect.x, rect.y + 27, rect.w, 3, current.accent);
    drawConversationPresenceDot(c, rect.x + 12, rect.y + 10, live);
    _ = c.drawUiText("Conversation", rect.x + 28, rect.y + 7, current.navigation_ink);
    drawConversationSummary(c, rect.x + 136, rect.y + 7, @max(0, rect.w - 242), count, members);
    drawConversationStateBadge(c, rect.right() - 12, rect.y + 7, live);
}

fn messageWrapPoint(text: []const u8, width: i32) usize {
    if (Canvas.uiTextWidth(text) <= width) return text.len;
    var point: usize = 0;
    var last_space: ?usize = null;
    while (point < text.len) : (point += 1) {
        if (text[point] == ' ') last_space = point;
        if (Canvas.uiTextWidth(text[0 .. point + 1]) > width) return last_space orelse point;
    }
    return text.len;
}

pub fn drawMemberRow(c: *Canvas, rect: Rect, label: []const u8, role_badge: []const u8, selected: bool, departed: bool, away: bool, hovered: bool) void {
    if (selected or hovered) {
        drawInkPlate(c, rect.x + 3, rect.y - 1, rect.w - 6, 23, 2, if (selected) current.accent_soft else current.paper);
        c.fillRect(rect.x + 3, rect.y - 1, 4, 23, current.accent);
    } else {
        c.fillRect(rect.x + 3, rect.y + 2, 2, 18, current.subtle);
    }
    fillRoundedRect(c, rect.x + 8, rect.y + 5, 8, 8, 4, if (departed) current.divider else if (away) current.warning else current.success);
    const badge_w: i32 = if (role_badge.len == 0) 0 else Canvas.uiTextWidth(role_badge) + 10;
    drawEllipsized(c, label, rect.x + 24, rect.y, rect.w - 30 - badge_w, if (departed) current.secondary else current.ink);
    if (role_badge.len != 0) {
        fillRoundedRect(c, rect.right() - badge_w - 6, rect.y + 2, badge_w, 18, 6, current.accent_soft);
        _ = c.drawUiText(role_badge, rect.right() - badge_w - 2, rect.y + 2, current.accent);
    }
}

pub fn drawInkChip(c: *Canvas, rect: Rect, label: []const u8, hot: bool) void {
    const fill = if (hot) current.accent else current.navigation_hover;
    const color = if (hot) current.layer else current.navigation_ink;
    drawInkPlate(c, rect.x, rect.y, rect.w, rect.h, 2, fill);
    drawEllipsized(c, label, rect.x + 8, rect.y + @max(1, @divTrunc(rect.h - 17, 2)), rect.w - 16, color);
}

pub fn drawPaneHeader(c: *Canvas, rect: Rect, title: []const u8) void {
    drawPaneHeaderReserved(c, rect, title, 0);
}

pub fn drawPaneHeaderReserved(c: *Canvas, rect: Rect, title: []const u8, trailing_width: i32) void {
    c.fillRect(rect.x, rect.y, rect.w, 30, current.navigation);
    c.fillRect(rect.x + 10, rect.y + 8, 4, 14, current.accent);
    drawEllipsized(c, title, rect.x + 28, rect.y + 7, rect.w - 40 - @max(0, trailing_width), current.navigation_ink);
    c.fillRect(rect.x, rect.y + 25, rect.w, 2, current.ink);
    c.fillRect(rect.x, rect.y + 27, rect.w, 3, current.accent);
}

/// Inspector header with a right-aligned live count that cannot collide with
/// the title label.
pub fn drawPaneCountHeader(c: *Canvas, rect: Rect, title: []const u8, count: []const u8) void {
    const count_w = @max(32, Canvas.uiTextWidth(count) + 20);
    drawPaneHeaderReserved(c, rect, title, count_w + 8);
    drawInkChip(c, .{ .x = rect.right() - count_w - 12, .y = rect.y + 5, .w = count_w, .h = 20 }, count, !std.mem.eql(u8, count, "0"));
}

/// Quiet, right-aligned keyboard-dismissal affordance for temporary popovers.
pub fn drawDismissHint(c: *Canvas, rect: Rect, label: []const u8) void {
    const width = Canvas.uiTextWidth(label);
    if (rect.w < width + 28) return;
    drawEllipsized(c, label, rect.right() - width - 16, rect.bottom() - 35, width, current.secondary);
}

pub fn drawIdentityPaneHeader(c: *Canvas, rect: Rect, title: []const u8, identity: []const u8) void {
    const title_w = Canvas.uiTextWidth(title);
    const available_identity = rect.w - 37 - title_w - 10;
    const identity_w = Canvas.uiTextWidth(identity) + 16;
    if (identity_w < 44 or identity_w > available_identity) {
        drawPaneHeader(c, rect, title);
        return;
    }
    drawPaneHeaderReserved(c, rect, title, identity_w + 10);
    drawInkChip(c, .{ .x = rect.right() - identity_w - 12, .y = rect.y + 5, .w = identity_w, .h = 20 }, identity, true);
}

pub fn drawStatusBar(c: *Canvas, x: i32, y: i32, width: i32, height: i32, status: []const u8, member_count: usize, hovered: bool) void {
    c.fillRect(x, y, width, height, current.navigation);
    c.fillRect(x, y, width, 3, current.accent);
    c.fillRect(x, y + height - 2, width, 2, current.ink);
    const status_color = switch (statusTone(status)) {
        .success => current.success,
        .warning => current.warning,
        .failure => current.failure,
        .info => current.accent,
    };
    c.fillRect(x + 10, y + 9, 8, 8, status_color);
    var buf: [32]u8 = undefined;
    const members = if (member_count == 1)
        "CAST 1"
    else
        std.fmt.bufPrint(&buf, "CAST {d}", .{member_count}) catch "CAST";
    const badge_w = Canvas.uiTextWidth(members) + 24;
    const badge_x = x + @max(108, width - badge_w - 8);
    if (hovered) c.fillRect(x + 4, y + 4, @max(1, badge_x - x - 10), @max(1, height - 8), current.navigation_hover);
    drawInkChip(c, .{ .x = badge_x, .y = y + 3, .w = badge_w, .h = @max(1, height - 6) }, members, false);
    const needs_connect = statusTone(status) != .success;
    const action = if (needs_connect) "Wire" else "Live";
    const action_w = if (needs_connect or hovered or badge_x - x >= 220) Canvas.uiTextWidth(action) + 28 else 0;
    drawEllipsized(c, status, x + 24, y + 5, badge_x - x - 34 - action_w, current.navigation_ink);
    if (action_w > 0) drawInkChip(c, .{ .x = badge_x - action_w - 6, .y = y + 3, .w = action_w, .h = @max(1, height - 6) }, action, needs_connect or hovered);
}

pub fn statusTone(status: []const u8) NoticeTone {
    if (std.mem.eql(u8, status, "On the wire")) return .success;
    if (std.mem.indexOf(u8, status, "error") != null or std.mem.indexOf(u8, status, "failed") != null) return .failure;
    if (std.mem.indexOf(u8, status, "nickname in use") != null) return .warning;
    if (std.mem.indexOf(u8, status, "reconnect") != null or std.mem.indexOf(u8, status, "offline") != null or std.mem.indexOf(u8, status, "Disconnected") != null or std.mem.indexOf(u8, status, "disconnected") != null) return .warning;
    if (std.mem.indexOf(u8, status, "connected") != null) return .success;
    return .info;
}

pub fn drawEmptyState(c: *Canvas, x: i32, y: i32, width: i32, height: i32, title: []const u8, detail: []const u8, requested_columns: u8) void {
    c.fillRect(x, y, width, height, current.comic_paper);
    if (width < 360 or height < 140) {
        drawEllipsized(c, detail, x + 16, y + @max(8, @divTrunc(height - 17, 2)), width - 32, current.secondary);
        return;
    }
    const card_w = @min(420, @max(260, width - 72));
    const card_h: i32 = 108;
    const card_x = x + @divTrunc(width - card_w, 2);
    const card_y = y + @max(16, height - card_h - 20);
    _ = requested_columns;
    drawEmptyCaption(c, .{ .x = card_x, .y = card_y, .w = card_w, .h = card_h }, title, detail);
}

/// Caption overlay used when the source title panel already occupies the well.
pub fn drawEmptyCaption(c: *Canvas, rect: Rect, title: []const u8, detail: []const u8) void {
    fillRoundedRect(c, rect.x + 3, rect.y + 4, rect.w, rect.h, 2, current.shadow);
    drawInkPlate(c, rect.x, rect.y, rect.w, rect.h, 2, current.paper);
    c.fillRect(rect.x, rect.y, 6, rect.h, current.accent);
    drawInkRule(c, rect.x + 6, rect.y, 1, rect.h, current.ink);
    const tip_x = rect.x + @divTrunc(rect.w, 2);
    c.fillTriangle(tip_x - 8, rect.y, tip_x, rect.y - 8, tip_x + 8, rect.y, current.ink);
    c.fillTriangle(tip_x - 6, rect.y, tip_x, rect.y - 6, tip_x + 6, rect.y, current.paper);
    drawBrandMark(c, .{ .x = rect.x + 16, .y = rect.y + 12, .w = 20, .h = 20 });
    drawEllipsized(c, "SUNDAY EDITION", rect.x + 44, rect.y + 8, rect.w - 60, current.accent);
    drawEllipsized(c, title, rect.x + 44, rect.y + 26, rect.w - 60, current.ink);
    drawEllipsized(c, detail, rect.x + 44, rect.y + 46, rect.w - 60, current.secondary);
    c.fillRect(rect.x + 7, rect.bottom() - 3, @max(0, rect.w - 7), 3, current.ink);
}

/// Shared call-to-action for an otherwise empty workspace or list.
pub fn drawEmptyStateCallout(c: *Canvas, rect: Rect, title: []const u8, detail: []const u8) void {
    drawInkPlate(c, rect.x, rect.y, rect.w, rect.h, 3, current.accent_soft);
    c.fillRect(rect.x, rect.y, 4, rect.h, current.accent);
    c.fillRect(rect.x + 4, rect.y, @max(0, rect.w - 4), 2, current.ink);
    fillRoundedRect(c, rect.x + 10, rect.y + @divTrunc(rect.h - 18, 2), 18, 18, 3, current.accent);
    _ = c.drawUiText("+", rect.x + 15, rect.y + @divTrunc(rect.h - 18, 2), current.layer);
    const content_w = rect.w - 52;
    if (rect.h < 38) {
        drawEllipsized(c, if (detail.len != 0) detail else title, rect.x + 40, rect.y + @divTrunc(rect.h - 17, 2), content_w, current.ink);
        return;
    }
    drawEllipsized(c, title, rect.x + 40, rect.y + 4, content_w, current.ink);
    drawEllipsized(c, detail, rect.x + 40, rect.y + 21, content_w, current.secondary);
}

pub fn drawEllipsized(c: *Canvas, text: []const u8, x: i32, y: i32, max_width: i32, color: u32) void {
    if (max_width <= 0) return;
    if (Canvas.uiTextWidth(text) <= max_width) {
        _ = c.drawUiText(text, x, y, color);
        return;
    }
    const dots = "...";
    const dots_width = Canvas.uiTextWidth(dots);
    var end = text.len;
    while (end > 0 and Canvas.uiTextWidth(text[0..end]) + dots_width > max_width) end -= 1;
    // Application labels should not end in a clipped word.  Keep the last
    // complete word when one fits; an unbroken token still falls back to a
    // character ellipsis so long IRC names and paths remain distinguishable.
    if (end < text.len and end > 0 and !std.ascii.isWhitespace(text[end - 1]) and !std.ascii.isWhitespace(text[end])) {
        var word_end = end;
        while (word_end > 0 and !std.ascii.isWhitespace(text[word_end - 1])) word_end -= 1;
        if (word_end > 0) end = word_end;
    }
    while (end > 0 and std.ascii.isWhitespace(text[end - 1])) end -= 1;
    _ = c.drawUiText(text[0..end], x, y, color);
    _ = c.drawUiText(dots, x + Canvas.uiTextWidth(text[0..end]), y, color);
}

test "page well frames the comic paper with ink" {
    const testing = std.testing;
    var canvas = try Canvas.init(testing.allocator, 120, 80);
    defer canvas.deinit(testing.allocator);
    canvas.clear(current.workspace);
    drawPageWell(&canvas, .{ .x = 4, .y = 4, .w = 112, .h = 72 });
    try testing.expectEqual(current.comic_paper, canvas.px[6 + 6 * 120]);
    try testing.expectEqual(current.ink, canvas.px[30 + 10 * 120]);
    try testing.expectEqual(current.artwork_paper, canvas.px[16 + 16 * 120]);
}

test "structural ink rules stay two framebuffer pixels" {
    const testing = std.testing;
    try testing.expectEqual(@as(i32, 2), stroke);
    var canvas = try Canvas.init(testing.allocator, 32, 16);
    defer canvas.deinit(testing.allocator);
    canvas.clear(current.paper);
    drawInkRule(&canvas, 4, 6, 12, 1, current.ink);
    try testing.expectEqual(current.ink, canvas.px[4 + 6 * 32]);
    try testing.expectEqual(current.ink, canvas.px[4 + 7 * 32]);
    try testing.expectEqual(current.paper, canvas.px[4 + 8 * 32]);
}

test "primary buttons and focused fields use the shared accent" {
    const testing = std.testing;
    var canvas = try Canvas.init(testing.allocator, 160, 80);
    defer canvas.deinit(testing.allocator);
    drawButton(&canvas, 4, 4, 90, "Save", .primary, false);
    drawField(&canvas, 4, 38, 120, true);
    try testing.expectEqual(current.accent, canvas.px[10 + 10 * 160]);
    try testing.expectEqual(current.accent, canvas.px[13 + 65 * 160]);
}

test "dialog layout keeps fields and actions inside the modal" {
    const layout = DialogLayout.init(640, 430, 252, 226, 3, 108, true);
    try std.testing.expect(layout.rect.w >= 300);
    try std.testing.expect(contains(layout.primary, layout.primary.x + 1, layout.primary.y + 1));
    try std.testing.expect(contains(layout.cancel, layout.cancel.x + 1, layout.cancel.y + 1));
    const last_field = layout.fieldRect(2);
    try std.testing.expect(last_field.y > layout.fieldRect(0).y);
    try std.testing.expect(last_field.y + last_field.h < layout.primary.y);
    try std.testing.expectEqual(@as(?usize, 2), layout.fieldIndexAt(last_field.x + 2, last_field.y + 2));
    try std.testing.expectEqual(@as(?usize, null), layout.fieldIndexAt(layout.rect.x + 2, last_field.y + 2));
}

test "semantic feedback primitives classify status and button targets" {
    const layout = DialogLayout.init(640, 430, 252, 218, 2, 96, true);
    try std.testing.expectEqual(NoticeTone.success, statusTone("connected"));
    try std.testing.expectEqual(NoticeTone.success, statusTone("On the wire"));
    try std.testing.expectEqual(NoticeTone.warning, statusTone("reconnecting"));
    try std.testing.expectEqual(NoticeTone.warning, statusTone("nickname in use"));
    try std.testing.expectEqual(NoticeTone.warning, statusTone("Disconnected"));
    try std.testing.expectEqual(NoticeTone.failure, statusTone("connection failed"));
    try std.testing.expectEqual(DialogButton.primary, dialogButtonAt(layout, layout.primary.x + 1, layout.primary.y + 1).?);
    try std.testing.expectEqual(DialogButton.cancel, dialogButtonAt(layout, layout.cancel.x + 1, layout.cancel.y + 1).?);
}

test "conversation tab keeps large unread badges clear of labels" {
    const rect = Rect{ .x = 20, .y = 5, .w = 164, .h = 28 };
    const layout = conversationTabLayout(rect, 1000);
    const label_x = rect.x + 14;
    const badge_x = rect.right() - layout.badge_w - 8;
    try std.testing.expect(layout.badge_w > 20);
    try std.testing.expect(layout.label_right <= badge_x - 6);
    try std.testing.expect(layout.label_right > label_x);
}

test "ellipsized labels preserve complete words when possible" {
    var canvas = try Canvas.init(std.testing.allocator, 160, 32);
    defer canvas.deinit(std.testing.allocator);
    canvas.clear(current.layer);
    drawEllipsized(&canvas, "Wire setup options", 2, 4, Canvas.uiTextWidth("Wire setup..."), current.ink);
    var marked = false;
    for (canvas.px) |pixel| {
        if (pixel != current.layer) {
            marked = true;
            break;
        }
    }
    try std.testing.expect(marked);
}

test "status panel layout falls back to compact metrics when height is constrained" {
    const detailed = StatusPanelLayout.init(640, 720, true);
    try std.testing.expect(detailed.show_details);
    const compact = StatusPanelLayout.init(640, 260, true);
    try std.testing.expect(!compact.show_details);
    try std.testing.expect(!compact.show_metrics);
    try std.testing.expect(!compact.show_actions);
    try std.testing.expectEqual(@as(i32, geometry.menu_height + geometry.toolbar_height + geometry.tab_bar_height + 10), compact.rect.y);
    try std.testing.expect(compact.rect.bottom() <= 260 - geometry.status_height - 12);
}

test "shared toolbar and composer glyphs render through the palette" {
    var canvas = try Canvas.init(std.testing.allocator, 48, 24);
    defer canvas.deinit(std.testing.allocator);
    canvas.clear(current.layer);
    drawToolGlyph(&canvas, .color, 2, 3, current.ink);
    drawSayGlyph(&canvas, .whisper, 26, 3, current.accent);
    var marked: usize = 0;
    for (canvas.px) |pixel| {
        if (pixel != current.layer) marked += 1;
    }
    try std.testing.expect(marked > 20);
}

test "shared popup and toolbar layouts preserve bounded interaction geometry" {
    const popup = PopupLayout.menu(640, 540, 33, 210, 4);
    try std.testing.expect(popup.rect.right() <= 634);
    try std.testing.expect(popup.itemAt(popup.rect.x + 1, popup.rect.y + 5) == null);
    try std.testing.expect(popup.itemAt(popup.rect.x + 8, popup.rect.y + 4) == null);
    try std.testing.expectEqual(@as(?u8, 0), popup.itemAt(popup.rect.x + 8, popup.rect.y + 8));
    try std.testing.expectEqual(@as(?u8, 3), popup.itemAt(popup.rect.x + 8, popup.rect.y + 8 + PopupLayout.row_height * 3));
    const toolbar = ToolbarLayout.init(.{ .x = 0, .y = 33, .w = 640, .h = 46 });
    try std.testing.expectEqual(@as(i32, 12), toolbar.buttonRect(0).?.x);
    try std.testing.expectEqual(@as(i32, 138), toolbar.buttonRect(3).?.x);
    try std.testing.expectEqual(@as(i32, 478), toolbar.buttonRect(11).?.x);
    try std.testing.expect(toolbar.buttonRect(11).?.right() <= 640);
}

test "asset preview and composer layouts reserve non-overlapping content" {
    const card = AssetPreviewLayout.card(.{ .x = 10, .y = 10, .w = 82, .h = 62 });
    try std.testing.expect(card.artwork.bottom() <= card.label.y);
    const inline_preview = AssetPreviewLayout.inlinePreview(.{ .x = 10, .y = 10, .w = 260, .h = 30 }, 60);
    try std.testing.expect(inline_preview.frame.right() <= inline_preview.label.x);
    const editor = ComposerEditorLayout.init(.{ .x = 10, .y = 20, .w = 320, .h = 44 });
    try std.testing.expect(editor.content.right() < editor.edit.right());
    try std.testing.expectEqual(@as(i32, 33), editor.rowY(0, 1));
    try std.testing.expectEqual(@as(usize, 1), editor.rowAtY(46, 2));
    try std.testing.expect(editor.caretX(999) < editor.edit.right());
}

test "every shared mood glyph renders a selected and resting expression" {
    const moods = [_]MoodGlyph{ .angry, .loud, .laughing, .sad, .neutral, .happy, .uneasy, .bored, .coy };
    var canvas = try Canvas.init(std.testing.allocator, 160, 64);
    defer canvas.deinit(std.testing.allocator);
    canvas.clear(current.chrome);
    for (moods, 0..) |mood, index| {
        const x: i32 = 12 + @as(i32, @intCast(index)) * 17;
        drawMoodGlyph(&canvas, x, 18, mood, false);
        drawMoodGlyph(&canvas, x, 46, mood, true);
    }
    var marked: usize = 0;
    for (canvas.px) |pixel| {
        if (pixel != current.chrome) marked += 1;
    }
    try std.testing.expect(marked > 900);
}

test "control states resolve selected pressed and disabled colors consistently" {
    try std.testing.expectEqual(current.accent, resolveControlColors(.{ .selected = true }).content);
    try std.testing.expectEqual(current.layer, resolveControlColors(.{ .pressed = true }).content);
    try std.testing.expectEqual(current.accent, resolveControlColors(.{ .focused = true }).border);
    try std.testing.expectEqual(current.divider, resolveControlColors(.{ .disabled = true }).content);
}

test "dark and accent appearances resolve complete draw-time palettes" {
    const dark_violet = Appearance{ .mode = .dark, .accent = .violet, .high_contrast = true };
    const palette = paletteFor(dark_violet);
    try std.testing.expectEqual(@as(u32, 0xff1c1814), palette.chrome);
    try std.testing.expectEqual(@as(u32, 0xffc9a0ff), palette.accent);
    try std.testing.expectEqual(@as(u32, 0xffffffff), palette.ink);
    try std.testing.expectEqual(@as(u32, 0xff4a2428), palette.notice_failure);
}

test "supersampled icon primitives produce smooth partial edge coverage" {
    var canvas = try Canvas.init(std.testing.allocator, 32, 32);
    defer canvas.deinit(std.testing.allocator);
    canvas.clear(current.layer);
    drawAaDisc(&canvas, 16, 16, 8.4, current.accent);
    drawAaLine(&canvas, 9, 16, 23, 16, 1.8, current.ink);
    const center = canvas.px[16 * 32 + 16];
    try std.testing.expect(center != current.layer and center != current.accent);
    var has_partial_coverage = false;
    for (canvas.px) |pixel| {
        if (pixel != current.layer and pixel != current.accent and pixel != current.ink) {
            has_partial_coverage = true;
            break;
        }
    }
    try std.testing.expect(has_partial_coverage);
}
