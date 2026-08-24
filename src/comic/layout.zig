//! Prototype heuristic panel layout. This is not the shipped Comic Chat path.
//!
//! All product strip and panel rendering must go through `original_layout.zig`
//! via `strip.zig`. This module stays compiled only so its unit tests remain a
//! fence against accidentally reintroducing a second layout algorithm. Do not
//! call it from `view`, `strip`, or any `original_*` renderer.

const std = @import("std");

pub const Message = struct {
    speaker_id: u32,
    text_len: u32,
};

pub const Point = struct {
    x: i32,
    y: i32,
};

pub const Rect = struct {
    x: i32,
    y: i32,
    w: i32,
    h: i32,

    pub fn right(self: Rect) i32 {
        return self.x + self.w;
    }

    pub fn bottom(self: Rect) i32 {
        return self.y + self.h;
    }

    pub fn containsRect(self: Rect, other: Rect) bool {
        return other.x >= self.x and other.y >= self.y and
            other.right() <= self.right() and other.bottom() <= self.bottom();
    }

    pub fn containsPoint(self: Rect, p: Point) bool {
        return p.x >= self.x and p.y >= self.y and p.x < self.right() and p.y < self.bottom();
    }
};

pub const Config = struct {
    panel_width: u32 = 315,
    panel_height: u32 = 315,
    columns: u32 = 3,
    gutter: u32 = 12,

    /// Inner inset for balloons and tail targets.
    margin: u32 = 12,

    /// Start a new panel before adding a message that would exceed this total.
    /// Set to 0 to disable text-based breaking.
    large_text_threshold: u32 = 180,

    /// Reserved lower band where character figures are expected to stand.
    character_band: u32 = 74,
};

pub const MessageLayout = struct {
    message_index: usize,
    balloon: Rect,
    tail_anchor: Point,
    character_x: i32,
};

pub const Panel = struct {
    row: u32,
    col: u32,
    rect: Rect,
    messages: []const Message,
    message_layouts: []const MessageLayout,
};

pub const Layout = struct {
    panels: []Panel,
    message_layouts: []MessageLayout,

    pub fn deinit(self: *Layout, gpa: std.mem.Allocator) void {
        gpa.free(self.message_layouts);
        gpa.free(self.panels);
        self.* = undefined;
    }
};

pub const LayoutError = error{InvalidConfig};

pub fn arrange(gpa: std.mem.Allocator, messages: []const Message, cfg: Config) !Layout {
    try validate(cfg);

    const panel_count = countPanels(messages, cfg);
    const panels = try gpa.alloc(Panel, panel_count);
    errdefer gpa.free(panels);
    const message_layouts = try gpa.alloc(MessageLayout, messages.len);
    errdefer gpa.free(message_layouts);

    var start: usize = 0;
    var panel_i: usize = 0;
    var layout_i: usize = 0;
    while (start < messages.len) {
        const end = panelEnd(messages, start, cfg);
        const count = end - start;
        const cell = cellFor(panel_i, cfg);
        const rect = try rectFor(panel_i, cfg);
        const layouts = message_layouts[layout_i .. layout_i + count];

        fillMessageLayouts(cfg, rect, start, messages[start..end], layouts);
        panels[panel_i] = .{
            .row = cell.row,
            .col = cell.col,
            .rect = rect,
            .messages = messages[start..end],
            .message_layouts = layouts,
        };

        start = end;
        panel_i += 1;
        layout_i += count;
    }

    return .{ .panels = panels, .message_layouts = message_layouts };
}

fn validate(cfg: Config) LayoutError!void {
    if (cfg.panel_width == 0 or cfg.panel_height == 0 or cfg.columns == 0) {
        return error.InvalidConfig;
    }
    _ = try i32FromU64(cfg.panel_width);
    _ = try i32FromU64(cfg.panel_height);
}

fn countPanels(messages: []const Message, cfg: Config) usize {
    var count: usize = 0;
    var start: usize = 0;
    while (start < messages.len) {
        start = panelEnd(messages, start, cfg);
        count += 1;
    }
    return count;
}

fn panelEnd(messages: []const Message, start: usize, cfg: Config) usize {
    var speakers: [3]u32 = undefined;
    var speaker_count: usize = 0;
    var text_total: u32 = 0;
    var count: usize = 0;
    var i = start;
    while (i < messages.len) : (i += 1) {
        const msg = messages[i];
        if (count == 3) break;
        const seen = containsSpeaker(speakers[0..speaker_count], msg.speaker_id);
        if (seen) break;
        if (!seen and speaker_count == speakers.len) break;
        if (cfg.large_text_threshold != 0 and count > 0 and
            text_total +| msg.text_len > cfg.large_text_threshold) break;

        speakers[speaker_count] = msg.speaker_id;
        speaker_count += 1;
        text_total +|= msg.text_len;
        count += 1;
    }
    return i;
}

fn containsSpeaker(speakers: []const u32, speaker_id: u32) bool {
    for (speakers) |s| {
        if (s == speaker_id) return true;
    }
    return false;
}

const Cell = struct {
    row: u32,
    col: u32,
};

fn cellFor(panel_index: usize, cfg: Config) Cell {
    const i: u32 = @intCast(panel_index);
    return .{ .row = i / cfg.columns, .col = i % cfg.columns };
}

fn rectFor(panel_index: usize, cfg: Config) LayoutError!Rect {
    const cell = cellFor(panel_index, cfg);
    const stride_x = @as(u64, cfg.panel_width) + cfg.gutter;
    const stride_y = @as(u64, cfg.panel_height) + cfg.gutter;
    return .{
        .x = try i32FromU64(@as(u64, cell.col) * stride_x),
        .y = try i32FromU64(@as(u64, cell.row) * stride_y),
        .w = try i32FromU64(cfg.panel_width),
        .h = try i32FromU64(cfg.panel_height),
    };
}

fn fillMessageLayouts(
    cfg: Config,
    panel_rect: Rect,
    first_message_index: usize,
    messages: []const Message,
    out: []MessageLayout,
) void {
    const count_i: i32 = @intCast(messages.len);
    const margin = effectiveInset(cfg.margin, panel_rect.w, panel_rect.h);
    const char_band = @min(@as(i32, @intCast(cfg.character_band)), @max(@divTrunc(panel_rect.h, 3), 1));
    const inner_x = panel_rect.x + margin;
    const inner_y = panel_rect.y + margin;
    const inner_w = @max(panel_rect.w - margin * 2, 1);
    const usable_h = @max(panel_rect.h - margin * 2 - char_band, 1);
    const gap = if (messages.len > 1) @min(@divTrunc(usable_h, count_i * 4), 8) else 0;
    const total_gap = gap * @as(i32, @intCast(messages.len - 1));
    const slot_h = @max(@divTrunc(@max(usable_h - total_gap, 1), count_i), 1);

    for (messages, 0..) |msg, i| {
        const pos_i: i32 = @intCast(i + 1);
        const cx = panel_rect.x + @divTrunc(panel_rect.w * pos_i, count_i + 1);
        const desired_w = desiredBalloonWidth(msg.text_len);
        const bw = @min(@max(desired_w, @min(inner_w, 72)), inner_w);
        const bx = clampI32(cx - @divTrunc(bw, 2), inner_x, inner_x + inner_w - bw);

        const ideal_h = desiredBalloonHeight(msg.text_len, bw);
        const bh = @min(@max(ideal_h, @min(slot_h, 24)), slot_h);
        const by = inner_y + @as(i32, @intCast(i)) * (slot_h + gap);
        const anchor_y = panel_rect.bottom() - margin - 1;

        out[i] = .{
            .message_index = first_message_index + i,
            .balloon = .{ .x = bx, .y = by, .w = bw, .h = bh },
            .tail_anchor = .{ .x = clampI32(cx, panel_rect.x, panel_rect.right() - 1), .y = anchor_y },
            .character_x = clampI32(cx, panel_rect.x, panel_rect.right() - 1),
        };
    }
}

fn effectiveInset(requested: u32, w: i32, h: i32) i32 {
    const limit = @max(@min(@divTrunc(w, 4), @divTrunc(h, 4)), 0);
    return @min(@as(i32, @intCast(requested)), limit);
}

fn desiredBalloonWidth(text_len: u32) i32 {
    const text: i32 = @intCast(@min(text_len, 120));
    return 72 + text * 3;
}

fn desiredBalloonHeight(text_len: u32, width: i32) i32 {
    const body_w = @max(width - 20, 1);
    const chars_per_line: u32 = @intCast(@max(@divTrunc(body_w, 6), 1));
    const lines = @max(ceilDiv(text_len, chars_per_line), 1);
    return 18 + @as(i32, @intCast(lines)) * 14;
}

fn ceilDiv(a: u32, b: u32) u32 {
    return (a + b - 1) / b;
}

fn clampI32(v: i32, lo: i32, hi: i32) i32 {
    if (hi <= lo) return lo;
    if (v < lo) return lo;
    if (v > hi) return hi;
    return v;
}

fn i32FromU64(v: u64) LayoutError!i32 {
    if (v > @as(u64, @intCast(std.math.maxInt(i32)))) return error.InvalidConfig;
    return @intCast(v);
}

test "empty input produces no panels" {
    const gpa = std.testing.allocator;
    var layout = try arrange(gpa, &.{}, .{});
    defer layout.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), layout.panels.len);
    try std.testing.expectEqual(@as(usize, 0), layout.message_layouts.len);
}

test "N messages are grouped at most three per panel" {
    const gpa = std.testing.allocator;
    const messages = [_]Message{
        .{ .speaker_id = 1, .text_len = 10 },
        .{ .speaker_id = 2, .text_len = 10 },
        .{ .speaker_id = 3, .text_len = 10 },
        .{ .speaker_id = 4, .text_len = 10 },
        .{ .speaker_id = 5, .text_len = 10 },
        .{ .speaker_id = 6, .text_len = 10 },
        .{ .speaker_id = 7, .text_len = 10 },
    };
    var layout = try arrange(gpa, &messages, .{ .large_text_threshold = 0 });
    defer layout.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 3), layout.panels.len);
    try std.testing.expectEqual(@as(usize, 3), layout.panels[0].messages.len);
    try std.testing.expectEqual(@as(usize, 3), layout.panels[1].messages.len);
    try std.testing.expectEqual(@as(usize, 1), layout.panels[2].messages.len);
}

test "same speaker repeating starts a new panel" {
    const gpa = std.testing.allocator;
    const messages = [_]Message{
        .{ .speaker_id = 10, .text_len = 12 },
        .{ .speaker_id = 20, .text_len = 12 },
        .{ .speaker_id = 10, .text_len = 12 },
    };
    var layout = try arrange(gpa, &messages, .{});
    defer layout.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 2), layout.panels.len);
    try std.testing.expectEqual(@as(usize, 2), layout.panels[0].messages.len);
    try std.testing.expectEqual(@as(usize, 1), layout.panels[1].messages.len);
}

test "large accumulated text starts a new panel" {
    const gpa = std.testing.allocator;
    const messages = [_]Message{
        .{ .speaker_id = 1, .text_len = 45 },
        .{ .speaker_id = 2, .text_len = 20 },
        .{ .speaker_id = 3, .text_len = 10 },
    };
    var layout = try arrange(gpa, &messages, .{ .large_text_threshold = 50 });
    defer layout.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 2), layout.panels.len);
    try std.testing.expectEqual(@as(usize, 1), layout.panels[0].messages.len);
    try std.testing.expectEqual(@as(usize, 2), layout.panels[1].messages.len);
}

test "balloons tails and character placements stay within panel bounds" {
    const gpa = std.testing.allocator;
    const messages = [_]Message{
        .{ .speaker_id = 1, .text_len = 4 },
        .{ .speaker_id = 2, .text_len = 70 },
        .{ .speaker_id = 3, .text_len = 160 },
        .{ .speaker_id = 4, .text_len = 20 },
    };
    var layout = try arrange(gpa, &messages, .{ .columns = 2 });
    defer layout.deinit(gpa);
    for (layout.panels) |panel| {
        for (panel.message_layouts) |ml| {
            try std.testing.expect(panel.rect.containsRect(ml.balloon));
            try std.testing.expect(panel.rect.containsPoint(ml.tail_anchor));
            try std.testing.expect(ml.character_x >= panel.rect.x and ml.character_x < panel.rect.right());
        }
    }
}

test "layout is deterministic" {
    const gpa = std.testing.allocator;
    const messages = [_]Message{
        .{ .speaker_id = 1, .text_len = 13 },
        .{ .speaker_id = 2, .text_len = 42 },
        .{ .speaker_id = 3, .text_len = 75 },
        .{ .speaker_id = 2, .text_len = 8 },
        .{ .speaker_id = 5, .text_len = 99 },
    };
    var a = try arrange(gpa, &messages, .{ .columns = 2, .gutter = 9 });
    defer a.deinit(gpa);
    var b = try arrange(gpa, &messages, .{ .columns = 2, .gutter = 9 });
    defer b.deinit(gpa);

    try std.testing.expectEqual(a.panels.len, b.panels.len);
    try std.testing.expectEqual(a.message_layouts.len, b.message_layouts.len);
    for (a.panels, b.panels) |pa, pb| {
        try std.testing.expectEqual(pa.row, pb.row);
        try std.testing.expectEqual(pa.col, pb.col);
        try std.testing.expectEqual(pa.rect, pb.rect);
        try std.testing.expectEqual(pa.messages.len, pb.messages.len);
    }
    for (a.message_layouts, b.message_layouts) |ma, mb| {
        try std.testing.expectEqual(ma, mb);
    }
}
