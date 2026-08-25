//! Direct, renderer-independent port of Microsoft Comic Chat 2.5's balloon
//! layout and Woodring outline construction.
//!
//! Coordinates deliberately retain the original logical/TWIP convention:
//! `top >= bottom`, the panel top is near zero, and positions below it are
//! negative.  A Windows or Wayland renderer should scale only at its final
//! device boundary.  Text extents remain a host concern because the original
//! asks GDI for formatted extents; every other decision is made here.
//!
//! Source: Microsoft Comic Chat 2.5 beta 1 (MIT), chiefly
//! `balloon.cpp:153-565,584-848,1180-1239,1358-1907`,
//! `panel.cpp:153-256,855-945`, `spline.cpp:65-295`, and
//! `splinutl.cpp:18-293`.

const std = @import("std");
const formatting = @import("formatting.zig");

// `balloon.cpp:51-74` and `panel.cpp:40-41`.
pub const xbox_delta: i32 = 90;
pub const ybox_delta: i32 = 50;
pub const min_route_width: i32 = 300;
pub const bubble_height: i32 = 150;
pub const inter_bubble: i32 = 100;
pub const end_bubble_width: i32 = 400;
pub const v_wave_height: i32 = 70;
pub const v_wave_interval: i32 = 300;
pub const h_wave_height: i32 = 70;
pub const h_wave_interval: i32 = 300;
pub const max_points: usize = 150;
pub const threshold_1: i32 = -70;
pub const threshold_2: i32 = 70;
pub const x_border: i32 = 100;
pub const y_border: i32 = 40;
pub const top_border: i32 = -20;
pub const large_delta: i32 = 350;
pub const small_delta: i32 = 150;
pub const min_tail_height: i32 = 100;
pub const border_fudge: i32 = 400;
pub const one_line_threshold: i32 = 500;
pub const min_hook_height: i32 = 100;
pub const max_lines: usize = 10;
pub const max_balloons: usize = 10;
pub const large_integer: i32 = 100_000_000;
pub const continuation = "...";

pub const Point = struct {
    x: i32,
    y: i32,
};

/// Win32 `RECT` field order with the original y-up logical coordinates.
pub const Rect = struct {
    left: i32,
    top: i32,
    right: i32,
    bottom: i32,

    pub fn width(self: Rect) i32 {
        return self.right - self.left;
    }

    pub fn height(self: Rect) i32 {
        return self.top - self.bottom;
    }

    pub fn translated(self: Rect, by: Point) Rect {
        return .{
            .left = self.left + by.x,
            .top = self.top + by.y,
            .right = self.right + by.x,
            .bottom = self.bottom + by.y,
        };
    }
};

pub const Size = struct { width: i32, height: i32 };

/// Adapter for the original `GetFormattedTextExtent` call. `nextChar` is the
/// equivalent of Win32 `CharNext`; omit it for the original single-byte path.
pub const TextMeasurer = struct {
    context: *const anyopaque,
    measure_fn: *const fn (*const anyopaque, []const u8) Size,
    measure_formatted_fn: ?*const fn (*const anyopaque, []const u8, []const formatting.Change, usize) Size = null,
    next_char_fn: ?*const fn (*const anyopaque, []const u8, usize) usize = null,

    pub fn measure(self: TextMeasurer, text: []const u8) Size {
        return self.measure_fn(self.context, text);
    }

    pub fn measureFormatted(
        self: TextMeasurer,
        text: []const u8,
        changes: []const formatting.Change,
        source_offset: usize,
    ) Size {
        if (self.measure_formatted_fn) |measure_fn|
            return measure_fn(self.context, text, changes, source_offset);
        return self.measure(text);
    }

    fn next(self: TextMeasurer, text: []const u8, at: usize) usize {
        if (at >= text.len) return text.len;
        if (self.next_char_fn) |next_fn| {
            const candidate = next_fn(self.context, text, at);
            if (candidate > at and candidate <= text.len) return candidate;
        }
        return at + 1;
    }
};

/// Values computed by `CFontInfo` in `balloon.cpp:584-628`.
pub const FontInfo = struct {
    line_height: i32,
    base_add: i32 = 0,
    top_offset: i32 = 0,
};

pub const BalloonMetrics = struct {
    font: FontInfo,
    measurer: TextMeasurer,
};

/// Source `CBWoodringWhisper` selects a distinct italic `CFontInfo`, while all
/// other balloon classes—including the dashed `BM_ACTION|BM_WHISPER` box—use
/// the normal face (`fonts.cpp:72-92`, `balloon.cpp:1813-1817`).
pub const MetricSet = struct {
    normal: BalloonMetrics,
    whisper: ?BalloonMetrics = null,

    pub fn forKind(self: MetricSet, kind: BalloonKind) BalloonMetrics {
        if (kind == .whisper) return self.whisper orelse self.normal;
        return self.normal;
    }
};

pub const BalloonKind = enum {
    say,
    whisper,
    think,
    action,

    pub fn isBox(self: BalloonKind) bool {
        return self == .action;
    }

    pub fn dashed(self: BalloonKind) bool {
        return self == .whisper;
    }
};

pub const BalloonInput = struct {
    /// The 2.5 constructor applies locale-aware `Capitalize`. This module
    /// performs the byte-for-byte ASCII portion; legacy code-page adapters may
    /// capitalize non-ASCII bytes before calling.
    text: []const u8,
    formatting: []const formatting.Change = &.{},
    kind: BalloonKind = .say,
    /// `BM_ACTION|BM_WHISPER` is a dashed box: box shape and dash style are
    /// independent in `MakeBalloon`, even though ordinary whispers use the
    /// Woodring cloud. Null selects the kind's normal dash behavior.
    dashed_override: ?bool = null,
    arrow_x: i32,
    speaker_box: Rect,
};

pub const TextLine = struct {
    start: usize,
    len: usize,
    width: i32,
    /// Panel-coordinate baseline/top passed to GDI `TextOut`.
    x: i32,
    y: i32,

    pub fn bytes(self: TextLine, text: []const u8) []const u8 {
        return text[self.start .. self.start + self.len];
    }
};

pub const CubicBezier = struct { p0: Point, p1: Point, p2: Point, p3: Point };
pub const Arc = struct { start: Point, end: Point, altitude: i32 };

pub const Tail = struct {
    tip: Point,
    opening_left: Point,
    opening_right: Point,
    first_arc: Arc,
    second_arc: Arc,
};

pub const ThoughtBubble = Rect;

/// Complete source-derived geometry. For ordinary/whisper/thought balloons,
/// draw `outline_beziers`, then the two tail arcs, and close/fill the path.
/// For action boxes, connect `outline_points` with straight segments.
pub const BalloonGeometry = struct {
    input_index: usize,
    kind: BalloonKind,
    dashed: bool,
    text: []u8,
    formatting: []formatting.Change,
    lines: []TextLine,
    cloud_bbox: Rect,
    route_region: Rect,
    /// Translation from the local Woodring path coordinates to panel space.
    origin: Point,
    /// Local path coordinates, exactly as passed after MFC offsets its DC.
    outline_points: []Point,
    outline_beziers: []CubicBezier,
    tail: ?Tail,
    thought_bubbles: []ThoughtBubble,

    pub fn deinit(self: *BalloonGeometry, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        allocator.free(self.formatting);
        allocator.free(self.lines);
        allocator.free(self.outline_points);
        allocator.free(self.outline_beziers);
        allocator.free(self.thought_bubbles);
        self.* = undefined;
    }

    /// Color-only: slide the cloud up so it stays above `max_bottom` (y-up)
    /// without crossing `panel_top`. The tail tip stays on the speaker dest.
    /// Testdata goldens never call this.
    pub fn liftAbove(self: *BalloonGeometry, max_bottom: i32, panel_top: i32) void {
        if (self.cloud_bbox.bottom >= max_bottom) return;
        var dy = max_bottom - self.cloud_bbox.bottom;
        if (self.cloud_bbox.top + dy > panel_top) {
            dy = panel_top - self.cloud_bbox.top;
        }
        if (dy <= 0) return;
        self.origin.y += dy;
        self.cloud_bbox.top += dy;
        self.cloud_bbox.bottom += dy;
        self.route_region.top += dy;
        self.route_region.bottom += dy;
        for (self.lines) |*line| line.y += dy;
        for (self.thought_bubbles) |*bubble| {
            bubble.top += dy;
            bubble.bottom += dy;
        }
        if (self.tail) |*tail| {
            tail.tip.y -= dy;
            tail.first_arc.end.y -= dy;
            tail.second_arc.start.y -= dy;
        }
    }

    /// Color-only: move the tail tip to a new world y (y-up) after dest nudge.
    /// Testdata goldens never call this.
    pub fn retargetTip(self: *BalloonGeometry, world_tip_y: i32) void {
        const tail = if (self.tail) |*value| value else return;
        const dy = world_tip_y - (self.origin.y + tail.tip.y);
        if (dy == 0) return;
        tail.tip.y += dy;
        tail.first_arc.end.y += dy;
        tail.second_arc.start.y += dy;
    }
};

pub const PanelLayout = struct {
    balloons: []BalloonGeometry,
    /// Owned `"..." ++ remainder` from the single-balloon `ForceFitBalloon`
    /// path. The current balloon likewise ends in `"..."`.
    continuation_text: ?[]u8 = null,
    continuation_formatting: ?[]formatting.Change = null,

    pub fn deinit(self: *PanelLayout, allocator: std.mem.Allocator) void {
        for (self.balloons) |*balloon| balloon.deinit(allocator);
        allocator.free(self.balloons);
        if (self.continuation_text) |rest| allocator.free(rest);
        if (self.continuation_formatting) |rest| allocator.free(rest);
        self.* = undefined;
    }
};

pub const Error = error{
    InvalidFont,
    InvalidRectangle,
    EmptyText,
    NoCharacterFits,
    TooManyBalloons,
    BalloonsDoNotFit,
    TooManyOutlinePoints,
    DegenerateSpline,
} || std.mem.Allocator.Error;

/// Microsoft's Win32 builds use the MSVCRT `rand` recurrence and a 15-bit
/// `RAND_MAX`. `panel.cpp:556,867` stores a seed and re-seeds before layout;
/// `balloon.cpp:428-431` divides each value by `RAND_MAX`.
pub const MsvcrtRand = struct {
    state: u32,

    pub fn init(seed: u32) MsvcrtRand {
        return .{ .state = seed };
    }

    pub fn next(self: *MsvcrtRand) u15 {
        self.state = self.state *% 214013 +% 2531011;
        return @truncate((self.state >> 16) & 0x7fff);
    }

    pub fn float(self: *MsvcrtRand) f64 {
        return @as(f64, @floatFromInt(self.next())) / 32767.0;
    }
};

pub const LineBreak = struct { start: usize, len: usize, width: i32 };
const RawLine = LineBreak;

pub const BrokenLines = struct {
    lines: []LineBreak,

    pub fn deinit(self: *BrokenLines, allocator: std.mem.Allocator) void {
        allocator.free(self.lines);
        self.* = undefined;
    }
};

fn cSpace(byte: u8) bool {
    return switch (byte) {
        ' ', '\t', '\n', '\r', 0x0b, 0x0c => true,
        else => false,
    };
}

fn cPrint(byte: u8) bool {
    return byte >= 0x20 and byte <= 0x7e;
}

fn nextStart(text: []const u8, start: usize, measurer: TextMeasurer) usize {
    var at = start;
    while (at < text.len and cSpace(text[at])) at = measurer.next(text, at);
    return at;
}

fn nextEnd(text: []const u8, start: usize, measurer: TextMeasurer) usize {
    var at = start;
    while (at < text.len and cSpace(text[at])) at = measurer.next(text, at);
    while (at < text.len and !cSpace(text[at])) at = measurer.next(text, at);
    return at;
}

fn upcomingReturn(text: []const u8, start: usize, measurer: TextMeasurer) bool {
    var at = start;
    while (at < text.len and cSpace(text[at])) {
        if (text[at] == '\n') return true;
        at = measurer.next(text, at);
    }
    return false;
}

const ForcedBreak = struct { len: usize, width: i32 };

/// `ForceLineBreak`, `balloon.cpp:185-212`. The source checks one character
/// beyond the candidate, so the final character is never selected by this
/// emergency path; normal fitting consumes it on the following line.
fn forceLineBreak(
    text: []const u8,
    format_changes: []const formatting.Change,
    source_offset: usize,
    max_width: i32,
    measurer: TextMeasurer,
) Error!ForcedBreak {
    var len: usize = 0;
    var width: i32 = 0;
    while (len < text.len) {
        const previous = len;
        len = measurer.next(text, len);
        const extent = measurer.measureFormatted(text[0..len], format_changes, source_offset);
        if (len < text.len and extent.width <= max_width) {
            width = extent.width;
        } else {
            len = previous;
            if (len == 0) return error.NoCharacterFits;
            return .{ .len = len, .width = width };
        }
    }
    return if (len > 0)
        .{ .len = len, .width = measurer.measureFormatted(text[0..len], format_changes, source_offset).width }
    else
        error.NoCharacterFits;
}

const Furthest = struct { end: usize, width: i32 };

/// `FindFurthestLineBreak`, `balloon.cpp:287-323`.
fn findFurthestLineBreak(
    text: []const u8,
    format_changes: []const formatting.Change,
    source_offset: usize,
    max_width: i32,
    measurer: TextMeasurer,
) Error!Furthest {
    var last_end: usize = 0;
    var line_end: usize = 0;
    var last_width: i32 = 0;
    while (true) {
        last_end = line_end;
        line_end = nextEnd(text, line_end, measurer);
        const extent = measurer.measureFormatted(text[0..line_end], format_changes, source_offset);
        if (extent.width <= max_width) {
            last_width = extent.width;
            if (line_end == text.len) return .{ .end = line_end, .width = extent.width };
        } else {
            if (last_end == 0) {
                const forced = try forceLineBreak(text, format_changes, source_offset, max_width, measurer);
                return .{ .end = forced.len, .width = forced.width };
            }
            return .{ .end = last_end, .width = last_width };
        }
    }
}

/// Exact US `BreakIntoLines` control flow from `balloon.cpp:347-425`, with
/// byte offsets in place of its pointer arrays. Hard returns and forced
/// long-word breaks are intentionally retained.
pub fn breakIntoLines(
    allocator: std.mem.Allocator,
    text: []const u8,
    max_width: i32,
    measurer: TextMeasurer,
) Error!BrokenLines {
    return breakIntoLinesFormatted(allocator, text, &.{}, max_width, measurer);
}

pub fn breakIntoLinesFormatted(
    allocator: std.mem.Allocator,
    text: []const u8,
    format_changes: []const formatting.Change,
    max_width: i32,
    measurer: TextMeasurer,
) Error!BrokenLines {
    if (text.len == 0) return error.EmptyText;
    if (max_width <= 0) return error.NoCharacterFits;

    var result: std.ArrayList(RawLine) = .empty;
    errdefer result.deinit(allocator);
    var string_start: usize = 0;
    var line_end: usize = 0;
    var this_length: usize = 0;
    var last_length: usize = 0;
    var last_width: i32 = 0;

    while (true) {
        line_end = nextEnd(text, line_end, measurer);
        last_length = this_length;
        this_length = line_end - string_start;
        const extent = measurer.measureFormatted(text[string_start..line_end], format_changes, string_start);
        const found_return = upcomingReturn(text, line_end, measurer);

        if (extent.width <= max_width and !found_return) {
            if (line_end == text.len) {
                try result.append(allocator, .{
                    .start = string_start,
                    .len = this_length,
                    .width = extent.width,
                });
                break;
            }
            last_width = extent.width;
        } else {
            if (last_length == 0 and extent.width > max_width) {
                const forced = try forceLineBreak(text[string_start..], format_changes, string_start, max_width, measurer);
                last_length = forced.len;
                last_width = forced.width;
            } else if (found_return and extent.width <= max_width) {
                last_length = this_length;
                last_width = extent.width;
            }

            try result.append(allocator, .{
                .start = string_start,
                .len = last_length,
                .width = last_width,
            });
            string_start = nextStart(text, string_start + last_length, measurer);
            line_end = string_start;
            if (string_start == text.len or result.items.len >= max_lines) break;
            this_length = 0;
        }
    }

    return .{ .lines = try result.toOwnedSlice(allocator) };
}

/// `CLabel::AreaEstimate`, `balloon.cpp:705-716`.
pub fn areaEstimate(text: []const u8, font: FontInfo, measurer: TextMeasurer) i32 {
    return areaEstimateFormatted(text, &.{}, font, measurer);
}

pub fn areaEstimateFormatted(
    text: []const u8,
    format_changes: []const formatting.Change,
    font: FontInfo,
    measurer: TextMeasurer,
) i32 {
    const extent = measurer.measureFormatted(text, format_changes, 0);
    const value = 1.3 * @as(f64, @floatFromInt(extent.width)) *
        @as(f64, @floatFromInt(extent.height + font.line_height));
    return @intFromFloat(value);
}

/// Literal port of `CLabel::WidestWord`, `balloon.cpp:719-748`. Note that the
/// 2.5 source uses C `isprint`, so spaces remain part of a printable run; the
/// function effectively measures the widest control-delimited run.
pub fn widestWord(text: []const u8, measurer: TextMeasurer) i32 {
    return widestWordFormatted(text, &.{}, measurer);
}

pub fn widestWordFormatted(
    text: []const u8,
    format_changes: []const formatting.Change,
    measurer: TextMeasurer,
) i32 {
    var max_width_seen: i32 = 0;
    var start: usize = 0;
    while (true) {
        while (start < text.len and !cPrint(text[start])) start = measurer.next(text, start);
        if (start == text.len) break;
        var end = start;
        while (end < text.len and cPrint(text[end])) end = measurer.next(text, end);
        // The source requests `end-start+1`; an included control byte normally
        // has zero extent. At NUL, the C-string sentinel likewise contributes 0.
        const measured_end = if (end < text.len) measurer.next(text, end) else end;
        max_width_seen = @max(
            max_width_seen,
            measurer.measureFormatted(text[start..measured_end], format_changes, start).width,
        );
        if (end == text.len) break;
        start = measurer.next(text, end);
    }
    return max_width_seen;
}

pub const SplitText = struct {
    first: []u8,
    first_formatting: []formatting.Change,
    rest: ?[]u8,
    rest_formatting: ?[]formatting.Change,

    pub fn deinit(self: *SplitText, allocator: std.mem.Allocator) void {
        allocator.free(self.first);
        allocator.free(self.first_formatting);
        if (self.rest) |rest| allocator.free(rest);
        if (self.rest_formatting) |rest| allocator.free(rest);
        self.* = undefined;
    }
};

/// Geometry-free form of `CBWoodringNormal::SplitHeight`, preserving the 400
/// TWIP border allowance and `...` on both the old and continuation panels
/// (`balloon.cpp:1533-1585`).
pub fn splitHeight(
    allocator: std.mem.Allocator,
    text: []const u8,
    width: i32,
    height: i32,
    font: FontInfo,
    measurer: TextMeasurer,
) Error!SplitText {
    return splitHeightFormatted(allocator, text, &.{}, width, height, font, measurer);
}

pub fn splitHeightFormatted(
    allocator: std.mem.Allocator,
    text: []const u8,
    format_changes: []const formatting.Change,
    width: i32,
    height: i32,
    font: FontInfo,
    measurer: TextMeasurer,
) Error!SplitText {
    if (font.line_height <= 0) return error.InvalidFont;
    var broken = try breakIntoLinesFormatted(allocator, text, format_changes, width, measurer);
    defer broken.deinit(allocator);
    const max_fit_i32 = @divTrunc(height - border_fudge, font.line_height);
    if (max_fit_i32 <= 0) return error.BalloonsDoNotFit;
    const max_fit: usize = @intCast(max_fit_i32);
    if (max_fit >= broken.lines.len) {
        const first = try allocator.dupe(u8, text);
        errdefer allocator.free(first);
        return .{
            .first = first,
            .first_formatting = try allocator.dupe(formatting.Change, format_changes),
            .rest = null,
            .rest_formatting = null,
        };
    }

    const last = broken.lines[max_fit - 1];
    // SplitHeight uses m_fInfo->m_bbox width, which BreakIntoLines shrinks to
    // the widest actual line (`balloon.cpp:677-692,1566-1567`), not the
    // caller's original width constraint.
    var actual_width: i32 = 0;
    for (broken.lines) |line| actual_width = @max(actual_width, line.width);
    const cont_width = measurer.measure(continuation).width;
    const furthest = try findFurthestLineBreak(
        text[last.start..],
        format_changes,
        last.start,
        actual_width - cont_width,
        measurer,
    );
    var cut = last.start + furthest.end;
    if (cut <= continuation.len and std.mem.startsWith(u8, text, continuation) and text.len > continuation.len) {
        cut = continuation.len + 1;
    }
    const rest_start = nextStart(text, cut, measurer);

    const first = try allocator.alloc(u8, cut + continuation.len);
    errdefer allocator.free(first);
    @memcpy(first[0..cut], text[0..cut]);
    @memcpy(first[cut..], continuation);

    const rest = try allocator.alloc(u8, continuation.len + text.len - rest_start);
    errdefer allocator.free(rest);
    @memcpy(rest[0..continuation.len], continuation);
    @memcpy(rest[continuation.len..], text[rest_start..]);
    const first_formatting = try formatting.beforeContinuation(allocator, format_changes, cut);
    errdefer allocator.free(first_formatting);
    return .{
        .first = first,
        .first_formatting = first_formatting,
        .rest = rest,
        .rest_formatting = try formatting.afterContinuation(
            allocator,
            format_changes,
            rest_start,
            continuation.len,
        ),
    };
}

const DPoint = struct { x: f64, y: f64 };

fn roundOriginal(value: f64) i32 {
    // `vector2d.h:46-52`, half away from zero.
    return @intFromFloat(if (value > 0) value + 0.5 else value - 0.5);
}

fn pointAdd(a: Point, b: Point) Point {
    return .{ .x = a.x + b.x, .y = a.y + b.y };
}

fn pointSub(a: Point, b: Point) Point {
    return .{ .x = a.x - b.x, .y = a.y - b.y };
}

fn dAdd(a: DPoint, b: DPoint) DPoint {
    return .{ .x = a.x + b.x, .y = a.y + b.y };
}

fn dSub(a: DPoint, b: DPoint) DPoint {
    return .{ .x = a.x - b.x, .y = a.y - b.y };
}

fn dScale(value: f64, point: DPoint) DPoint {
    return .{ .x = value * point.x, .y = value * point.y };
}

fn toD(point: Point) DPoint {
    return .{ .x = @floatFromInt(point.x), .y = @floatFromInt(point.y) };
}

fn toPoint(point: DPoint) Point {
    return .{ .x = roundOriginal(point.x), .y = roundOriginal(point.y) };
}

fn distance(a: Point, b: Point) f64 {
    const dx: f64 = @floatFromInt(a.x - b.x);
    const dy: f64 = @floatFromInt(a.y - b.y);
    return @sqrt(dx * dx + dy * dy);
}

const Range = struct { start: usize = 0, end: usize = 0, x: i32 = 0, y: i32 = 0 };

const FormatInfo = struct {
    lines: [max_lines]RawLine = undefined,
    left_x: [max_lines]i32 = undefined,
    count: usize = 0,
    max_width: i32 = 0,
    bbox: Rect = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },
};

/// `GetFilters`, `balloon.cpp:466-512`.
fn getFilters(
    format: *const FormatInfo,
    left: *[20]Range,
    right: *[20]Range,
) struct { left_count: usize, right_count: usize } {
    var li: usize = 0;
    var ri: usize = 0;
    left[0] = .{ .x = format.left_x[0], .start = 0 };
    right[0] = .{ .x = format.left_x[0] + format.lines[0].width, .start = 0 };

    var i: usize = 1;
    while (i < format.count) : (i += 1) {
        const this_left = format.left_x[i];
        const this_right = this_left + format.lines[i].width;
        const left_delta = this_left - left[li].x;
        const right_delta = this_right - right[ri].x;
        if (left_delta <= threshold_1) {
            left[li].end = i - 1;
            li += 1;
            left[li] = .{ .start = i, .x = this_left };
        } else if (left_delta <= 0) {
            left[li].x = this_left;
        } else if (left_delta >= threshold_2) {
            const next_left = if (i + 1 < format.count) format.left_x[i + 1] else this_left;
            if (next_left - left[li].x >= threshold_2) {
                left[li].end = i - 1;
                li += 1;
                left[li] = .{ .start = i, .x = @min(this_left, next_left) };
            }
        }

        if (right_delta >= -threshold_1) {
            right[ri].end = i - 1;
            ri += 1;
            right[ri] = .{ .start = i, .x = this_right };
        } else if (right_delta >= 0) {
            right[ri].x = this_right;
        } else if (right_delta <= -threshold_2) {
            const next_right = if (i + 1 < format.count)
                format.left_x[i + 1] + format.lines[i + 1].width
            else
                this_right;
            if (next_right - right[ri].x <= -threshold_2) {
                right[ri].end = i - 1;
                ri += 1;
                right[ri] = .{ .start = i, .x = @max(this_right, next_right) };
            }
        }
    }
    left[li].end = format.count - 1;
    right[ri].end = format.count - 1;
    return .{ .left_count = li + 1, .right_count = ri + 1 };
}

/// `PermuteFilters`, `balloon.cpp:515-543`. The historical name is retained;
/// its active code contains no random permutation.
fn permuteFilters(
    font: FontInfo,
    left: []Range,
    right: []Range,
) i32 {
    var base_y: i32 = 0;
    var last_x: i32 = large_integer;
    for (left, 0..) |*filter, i| {
        filter.x -= x_border;
        if (i == 0)
            filter.y = base_y + top_border + y_border + font.top_offset
        else if (filter.x < last_x)
            filter.y = base_y + y_border
        else
            filter.y = base_y - y_border - font.base_add;
        base_y -= @as(i32, @intCast(filter.end - filter.start + 1)) * font.line_height;
        last_x = filter.x;
    }

    base_y = 0;
    last_x = -large_integer;
    for (right, 0..) |*filter, i| {
        filter.x += x_border;
        if (i == 0)
            filter.y = base_y + top_border + y_border + font.top_offset
        else if (filter.x > last_x)
            filter.y = base_y + y_border
        else
            filter.y = base_y - y_border - font.base_add;
        base_y -= @as(i32, @intCast(filter.end - filter.start + 1)) * font.line_height;
        last_x = filter.x;
    }
    return base_y - top_border - y_border - font.base_add;
}

/// `AddWavies`, `balloon.cpp:546-565`.
fn addWavies(points: *std.ArrayList(Point), allocator: std.mem.Allocator, a: Point, b: Point, diameter: i32, interval: i32) Error!void {
    const dist = distance(a, b);
    const wave_count_f = dist / @as(f64, @floatFromInt(interval));
    if (wave_count_f < 2.0) return;
    const wave_count: i32 = @intFromFloat(wave_count_f);
    const wave_len = dist / @as(f64, @floatFromInt(wave_count));
    const unit = dScale(1.0 / dist, dSub(toD(b), toD(a)));
    const increment = toPoint(dScale(wave_len, unit));
    const normal = DPoint{ .x = unit.y, .y = -unit.x };
    const extra = toPoint(dScale(@floatFromInt(diameter), normal));
    var base = a;
    var i: i32 = 0;
    while (i < wave_count - 1) : (i += 1) {
        base = pointAdd(base, increment);
        try points.append(allocator, if ((i & 1) == 0) pointAdd(base, extra) else base);
        if (points.items.len > max_points) return error.TooManyOutlinePoints;
    }
}

const Matrix = [4][4]f64;

/// `CBeta::SetMatrix(5.0, 1.0)`, `spline.cpp:65-73,112-145`.
fn betaMatrix() Matrix {
    const tension = 5.0;
    const bias = 1.0;
    const b2 = bias * bias;
    const b3 = bias * b2;
    const d = 1.0 / (tension + 2.0 * b3 + 4.0 * (b2 + bias) + 2.0);
    var matrix: Matrix = .{
        .{ -2.0 * b3, 2.0 * (tension + b3 + b2 + bias), -2.0 * (tension + b2 + bias + 1.0), 2.0 },
        .{ 6.0 * b3, -3.0 * (tension + 2.0 * (b3 + b2)), 3.0 * (tension + 2.0 * b2), 0.0 },
        .{ -6.0 * b3, 6.0 * (b3 - bias), 6.0 * bias, 0.0 },
        .{ 2.0 * b3, tension + 4.0 * (b2 + bias), 2.0, 0.0 },
    };
    for (&matrix) |*row| {
        for (row) |*value| value.* *= d;
    }
    return matrix;
}

fn betaKnot(points: []const Point, closed: bool, index: usize) Point {
    if (closed) {
        if (index == 0) return points[points.len - 1];
        if (index == points.len + 1) return points[0];
        if (index == points.len + 2) return points[1];
        return points[index - 1];
    }
    // CBeta::GetDups() == 3.
    if (index < 3) return points[0];
    if (index >= points.len + 1) return points[points.len - 1];
    return points[index - 2];
}

fn matrixPoint(matrix: *const Matrix, row: usize, knots: [4]Point) Point {
    return .{
        .x = roundOriginal(matrix[row][0] * @as(f64, @floatFromInt(knots[0].x)) +
            matrix[row][1] * @as(f64, @floatFromInt(knots[1].x)) +
            matrix[row][2] * @as(f64, @floatFromInt(knots[2].x)) +
            matrix[row][3] * @as(f64, @floatFromInt(knots[3].x))),
        .y = roundOriginal(matrix[row][0] * @as(f64, @floatFromInt(knots[0].y)) +
            matrix[row][1] * @as(f64, @floatFromInt(knots[1].y)) +
            matrix[row][2] * @as(f64, @floatFromInt(knots[2].y)) +
            matrix[row][3] * @as(f64, @floatFromInt(knots[3].y))),
    };
}

/// `CSpline::ComputeBezpts`, `CvertsToCubic`, and `CubicToBezier`,
/// `spline.cpp:169-230`.
fn betaBeziers(allocator: std.mem.Allocator, points: []const Point, closed: bool) Error![]CubicBezier {
    if (points.len < 2) return error.DegenerateSpline;
    const knot_count = if (closed) points.len + 3 else points.len + 4;
    const segment_count = knot_count - 3;
    const result = try allocator.alloc(CubicBezier, segment_count);
    errdefer allocator.free(result);
    const matrix = betaMatrix();
    for (result, 0..) |*segment, i| {
        const knots = [4]Point{
            betaKnot(points, closed, i),
            betaKnot(points, closed, i + 1),
            betaKnot(points, closed, i + 2),
            betaKnot(points, closed, i + 3),
        };
        const c3 = matrixPoint(&matrix, 0, knots);
        const c2 = matrixPoint(&matrix, 1, knots);
        const c1 = matrixPoint(&matrix, 2, knots);
        const c0 = matrixPoint(&matrix, 3, knots);
        const b0 = c0;
        const b1 = Point{
            .x = c0.x + roundOriginal(@as(f64, @floatFromInt(c1.x)) / 3.0),
            .y = c0.y + roundOriginal(@as(f64, @floatFromInt(c1.y)) / 3.0),
        };
        const b2 = Point{
            .x = b1.x + roundOriginal(@as(f64, @floatFromInt(c1.x + c2.x)) / 3.0),
            .y = b1.y + roundOriginal(@as(f64, @floatFromInt(c1.y + c2.y)) / 3.0),
        };
        const b3 = Point{
            .x = c0.x + c1.x + c2.x + c3.x,
            .y = c0.y + c1.y + c2.y + c3.y,
        };
        segment.* = .{ .p0 = b0, .p1 = b1, .p2 = b2, .p3 = b3 };
    }
    return result;
}

fn bboxOf(points: []const Point) Rect {
    var result = Rect{
        .left = large_integer,
        .top = -large_integer,
        .right = -large_integer,
        .bottom = large_integer,
    };
    for (points) |point| {
        result.left = @min(result.left, point.x);
        result.right = @max(result.right, point.x);
        result.top = @max(result.top, point.y);
        result.bottom = @min(result.bottom, point.y);
    }
    return result;
}

/// `CBWoodringNormal::CreateBalloonSpline`, `balloon.cpp:1700-1735`.
fn createBalloonControlPoints(allocator: std.mem.Allocator, format: *const FormatInfo, font: FontInfo) Error![]Point {
    var left: [20]Range = undefined;
    var right: [20]Range = undefined;
    const counts = getFilters(format, &left, &right);
    const final_y = permuteFilters(font, left[0..counts.left_count], right[0..counts.right_count]);
    var last_y = final_y;
    var points: std.ArrayList(Point) = .empty;
    errdefer points.deinit(allocator);

    for (left[0..counts.left_count], 0..) |filter, i| {
        const this_point = Point{ .x = filter.x, .y = filter.y };
        if (i > 0) try addWavies(&points, allocator, points.items[points.items.len - 1], this_point, h_wave_height, h_wave_interval);
        try points.append(allocator, this_point);
        const next_point = Point{
            .x = filter.x,
            .y = if (i + 1 == counts.left_count) final_y else left[i + 1].y,
        };
        try addWavies(&points, allocator, points.items[points.items.len - 1], next_point, v_wave_height, v_wave_interval);
        try points.append(allocator, next_point);
    }

    var i = counts.right_count;
    while (i > 0) {
        i -= 1;
        const this_point = Point{ .x = right[i].x, .y = last_y };
        try addWavies(&points, allocator, points.items[points.items.len - 1], this_point, h_wave_height, h_wave_interval);
        try points.append(allocator, this_point);
        const next_point = Point{ .x = this_point.x, .y = right[i].y };
        last_y = next_point.y;
        try addWavies(&points, allocator, points.items[points.items.len - 1], next_point, v_wave_height, v_wave_interval);
        try points.append(allocator, next_point);
    }
    try addWavies(&points, allocator, points.items[points.items.len - 1], points.items[0], h_wave_height, h_wave_interval);
    if (points.items.len > max_points) return error.TooManyOutlinePoints;
    return points.toOwnedSlice(allocator);
}

const DBezier = struct { p0: DPoint, p1: DPoint, p2: DPoint, p3: DPoint };

fn toDBezier(bezier: CubicBezier) DBezier {
    return .{ .p0 = toD(bezier.p0), .p1 = toD(bezier.p1), .p2 = toD(bezier.p2), .p3 = toD(bezier.p3) };
}

fn splitBezier(bezier: DBezier) struct { left: DBezier, right: DBezier } {
    var left: DBezier = undefined;
    var right: DBezier = undefined;
    left.p0 = bezier.p0;
    left.p1 = dScale(0.5, dAdd(bezier.p0, bezier.p1));
    const middle = dScale(0.5, dAdd(bezier.p1, bezier.p2));
    left.p2 = dScale(0.5, dAdd(left.p1, middle));
    right.p3 = bezier.p3;
    right.p2 = dScale(0.5, dAdd(bezier.p2, bezier.p3));
    right.p1 = dScale(0.5, dAdd(middle, right.p2));
    left.p3 = dScale(0.5, dAdd(left.p2, right.p1));
    right.p0 = left.p3;
    return .{ .left = left, .right = right };
}

/// `flat_bezier`, `splinutl.cpp:54-86`, epsilon 1.0.
fn flatBezier(bezier: DBezier) bool {
    const xmin = @min(bezier.p0.x, bezier.p3.x);
    const xmax = @max(bezier.p0.x, bezier.p3.x);
    const ymin = @min(bezier.p0.y, bezier.p3.y);
    const ymax = @max(bezier.p0.y, bezier.p3.y);
    for ([_]DPoint{ bezier.p1, bezier.p2 }) |point| {
        if (point.x + 0.5 < xmin or point.x - 0.5 > xmax or
            point.y + 0.5 < ymin or point.y - 0.5 > ymax) return false;
    }
    const d1 = dSub(bezier.p1, bezier.p0);
    const d2 = dSub(bezier.p2, bezier.p0);
    const d = dSub(bezier.p3, bezier.p0);
    const dx = @abs(d.x);
    const dy = @abs(d.y);
    if (dx + dy < 1.0) return true;
    if (dy < dx) {
        const slope = d.y / d.x;
        return @abs(d2.y - d2.x * slope) < 1.0 and @abs(d1.y - d1.x * slope) < 1.0;
    }
    const slope = d.x / d.y;
    return @abs(d2.x - d2.y * slope) < 1.0 and @abs(d1.x - d1.y * slope) < 1.0;
}

const SampleFn = *const fn (DPoint, *anyopaque) bool;

/// `subdivide`, `splinutl.cpp:89-117`. Returning true stops traversal.
fn subdivide(bezier: DBezier, callback: SampleFn, context: *anyopaque) bool {
    if (flatBezier(bezier)) {
        const delta = dSub(bezier.p3, bezier.p0);
        const length = @sqrt(delta.x * delta.x + delta.y * delta.y);
        if (length > 1.0e-24) {
            const step = 1.0 / length;
            var alpha: f64 = 0;
            while (alpha <= 1.0) : (alpha += step) {
                const point = dAdd(dScale(alpha, bezier.p3), dScale(1.0 - alpha, bezier.p0));
                if (callback(point, context)) return true;
            }
        }
        return callback(bezier.p3, context);
    }
    const halves = splitBezier(bezier);
    return subdivide(halves.left, callback, context) or subdivide(halves.right, callback, context);
}

const NearContext = struct {
    given: DPoint,
    found: DPoint = undefined,
    distance: f64 = 1.0e24,
};

fn nearestSample(point: DPoint, raw_context: *anyopaque) bool {
    const context: *NearContext = @ptrCast(@alignCast(raw_context));
    const candidate = @abs(point.x - context.given.x) + @abs(point.y - context.given.y);
    if (candidate < context.distance) {
        context.distance = candidate;
        context.found = point;
    }
    return false;
}

const Closest = struct { point: Point, knot_index: usize };

/// `CSpline::ClosestPoint`, `spline.cpp:251-267`, and its exact Manhattan,
/// epsilon-subdivision sampler in `splinutl.cpp:147-220`.
fn closestPoint(beziers: []const CubicBezier, target: Point) Closest {
    var minimum: i32 = 10_000_000;
    var result = Closest{ .point = beziers[0].p0, .knot_index = 2 };
    for (beziers, 0..) |bezier, i| {
        var context = NearContext{ .given = toD(target) };
        _ = subdivide(toDBezier(bezier), nearestSample, &context);
        const integer_distance: i32 = @intFromFloat(context.distance);
        if (integer_distance < minimum) {
            minimum = integer_distance;
            // `int_bezier_nearest_point` truncates, not ROUNDs.
            result.point = .{ .x = @intFromFloat(context.found.x), .y = @intFromFloat(context.found.y) };
            result.knot_index = i + 2;
        }
    }
    return result;
}

const BeyondContext = struct {
    goal_x: f64,
    found: DPoint = .{ .x = -1_000_000, .y = 0 },
};

fn beyondSample(point: DPoint, raw_context: *anyopaque) bool {
    const context: *BeyondContext = @ptrCast(@alignCast(raw_context));
    if (point.x > context.found.x) context.found = point;
    return point.x >= context.goal_x;
}

const HorizontalWalk = struct { point: Point, knot_index: usize };

/// `CSpline::WalkHorizontalDistance`, `spline.cpp:269-296`, plus
/// `walk_horizontal_dist`, `splinutl.cpp:259-293`.
fn walkHorizontal(beziers: []const CubicBezier, from_knot: usize, goal_x: i32) HorizontalWalk {
    var segment_index = from_knot - 2;
    var found_index: usize = 0;
    var last = Point{ .x = -100_000, .y = -100_000 };
    var count: usize = 0;
    while (count < beziers.len) : (count += 1) {
        if (segment_index >= beziers.len) segment_index = 0;
        var context = BeyondContext{ .goal_x = @floatFromInt(goal_x) };
        const found = subdivide(toDBezier(beziers[segment_index]), beyondSample, &context);
        const furthest = toPoint(context.found);
        if (found) return .{ .point = furthest, .knot_index = segment_index + 2 };
        if (furthest.x > last.x) {
            found_index = segment_index + 2;
            last = furthest;
        }
        segment_index += 1;
    }
    return .{ .point = last, .knot_index = found_index };
}

const OpenSpline = struct { points: []Point, beziers: []CubicBezier };

/// `BreakSpline`, `balloon.cpp:434-463`: removes a 160 TWIP opening from the
/// closed cloud by walking its computed beta Beziers, then recomputes an open
/// beta spline with the two sampled opening endpoints.
fn breakSpline(
    allocator: std.mem.Allocator,
    closed_points: []const Point,
    x: i32,
    y: i32,
) Error!OpenSpline {
    const closed_beziers = try betaBeziers(allocator, closed_points, true);
    defer allocator.free(closed_beziers);
    const gap_width: i32 = 80;
    const nearest = closestPoint(closed_beziers, .{ .x = x - gap_width, .y = y });
    const walked = walkHorizontal(closed_beziers, nearest.knot_index, nearest.point.x + 2 * gap_width);
    if (walked.knot_index == 0) return error.DegenerateSpline;

    const cyclic_delta = (walked.knot_index + closed_points.len - nearest.knot_index) % closed_points.len;
    const new_count = closed_points.len + 2 - cyclic_delta;
    if (new_count < 2) return error.DegenerateSpline;
    const points = try allocator.alloc(Point, new_count);
    errdefer allocator.free(points);
    points[0] = walked.point;
    var i: usize = 1;
    while (i + 1 < new_count) : (i += 1) {
        points[i] = closed_points[(walked.knot_index + i - 2) % closed_points.len];
    }
    points[new_count - 1] = nearest.point;
    const beziers = try betaBeziers(allocator, points, false);
    return .{ .points = points, .beziers = beziers };
}

const InternalBalloon = struct {
    input_index: usize,
    kind: BalloonKind,
    dashed_override: ?bool,
    arrow_x: i32,
    speaker_box: Rect,
    text: []u8,
    formatting: []formatting.Change,
    format: FormatInfo,
    origin: Point,
    cloud_bbox: Rect,
    route: Rect,
    base_points: []Point,

    fn deinit(self: *InternalBalloon, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        allocator.free(self.formatting);
        allocator.free(self.base_points);
        self.* = undefined;
    }
};

fn uppercaseAsciiAlloc(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    const copy = try allocator.dupe(u8, text);
    for (copy) |*byte| {
        if (byte.* >= 'a' and byte.* <= 'z') byte.* -= 'a' - 'A';
    }
    return copy;
}

fn buildFormat(
    allocator: std.mem.Allocator,
    text: []const u8,
    format_changes: []const formatting.Change,
    desired_width: i32,
    font: FontInfo,
    measurer: TextMeasurer,
    left_justify: bool,
    random: *MsvcrtRand,
) Error!FormatInfo {
    var broken = try breakIntoLinesFormatted(allocator, text, format_changes, desired_width, measurer);
    defer broken.deinit(allocator);
    if (broken.lines.len == 0) return error.EmptyText;
    var result = FormatInfo{};
    result.count = broken.lines.len;
    for (broken.lines, 0..) |line, i| {
        result.lines[i] = line;
        result.max_width = @max(result.max_width, line.width);
    }
    result.bbox.top = 0;
    if (left_justify) {
        result.bbox.left = 0;
        result.bbox.right = result.max_width;
    } else {
        result.bbox.left = @divTrunc(desired_width - result.max_width, 2);
        result.bbox.right = result.bbox.left + result.max_width;
    }
    result.bbox.bottom = result.bbox.top - @as(i32, @intCast(result.count)) * font.line_height - font.base_add;

    // `ShiftLines`, `balloon.cpp:751-774`; both random shift maxima are zero.
    for (0..result.count) |i| {
        _ = random.float();
        result.left_x[i] = if (left_justify)
            0
        else
            @divTrunc(result.bbox.width() - result.lines[i].width, 2);
    }
    return result;
}

fn computeBalloon(
    allocator: std.mem.Allocator,
    input: BalloonInput,
    input_index: usize,
    requested_left: i32,
    requested_right: i32,
    requested_top: i32,
    font: FontInfo,
    measurer: TextMeasurer,
    random: *MsvcrtRand,
) Error!InternalBalloon {
    if (requested_right <= requested_left) return error.InvalidRectangle;
    const text = try uppercaseAsciiAlloc(allocator, input.text);
    errdefer allocator.free(text);
    const format_changes = try allocator.dupe(formatting.Change, input.formatting);
    errdefer allocator.free(format_changes);
    const desired_width = requested_right - requested_left - 2 * x_border;
    const format = try buildFormat(
        allocator,
        text,
        format_changes,
        desired_width,
        font,
        measurer,
        input.kind.isBox(),
        random,
    );
    const base_points = if (input.kind.isBox())
        try allocator.alloc(Point, 0)
    else
        try createBalloonControlPoints(allocator, &format, font);
    errdefer allocator.free(base_points);
    const true_box = if (input.kind.isBox()) Rect{
        .left = format.bbox.left - xbox_delta,
        .top = format.bbox.top + ybox_delta,
        .right = format.bbox.right + xbox_delta,
        .bottom = format.bbox.bottom - ybox_delta,
    } else bboxOf(base_points);
    const origin = Point{ .x = requested_left - true_box.left, .y = requested_top - true_box.top };
    const cloud = true_box.translated(origin);
    return .{
        .input_index = input_index,
        .kind = input.kind,
        .dashed_override = input.dashed_override,
        .arrow_x = input.arrow_x,
        .speaker_box = input.speaker_box,
        .text = text,
        .formatting = format_changes,
        .format = format,
        .origin = origin,
        .cloud_bbox = cloud,
        .route = cloud,
        .base_points = base_points,
    };
}

fn dockAtTop(balloon: *InternalBalloon, height: i32) void {
    // `CBalloon::DockAtTop`, `balloon.cpp:1234-1240` sets m_bbox.Top rather
    // than cloud top, retaining its height.
    const old_origin_y = balloon.origin.y;
    balloon.origin.y = height + top_border;
    const delta = balloon.origin.y - old_origin_y;
    balloon.cloud_bbox.top += delta;
    balloon.cloud_bbox.bottom += delta;
}

fn queryRoute(balloon: *const InternalBalloon, other_x: i32) struct { left: i32, right: i32 } {
    // Boxes override this as a no-op (`balloon.cpp:1911-1915`).
    if (balloon.kind.isBox()) return .{ .left = -large_integer, .right = large_integer };
    if (other_x > balloon.arrow_x) {
        return .{
            .left = @max(balloon.arrow_x, balloon.route.left + min_route_width),
            .right = large_integer,
        };
    }
    return .{
        .left = -large_integer,
        .right = @min(balloon.arrow_x, balloon.route.right - min_route_width),
    };
}

fn setRoute(balloon: *InternalBalloon, other_x: i32, left: i32, right: i32) void {
    if (balloon.kind.isBox()) return;
    if (other_x > balloon.arrow_x)
        balloon.route.right = @min(balloon.route.right, left)
    else
        balloon.route.left = @max(balloon.route.left, right);
}

/// `GetInterveningBBox`, `panel.cpp:167-210`. The source's misleading
/// left/right comment is intentionally not used to reinterpret its branch.
fn getInterveningBBox(balloons: []const InternalBalloon, free: Rect, estimate: *Rect, to_x: i32) void {
    var most_left = free.left;
    var most_right = free.right;
    for (balloons) |*previous| {
        const allowance = queryRoute(previous, to_x);
        most_left = @max(most_left, allowance.left);
        most_right = @min(most_right, allowance.right);
    }
    if (most_left > estimate.left or most_right < estimate.right) {
        const clearance = most_right - most_left;
        if (clearance >= estimate.width()) {
            const delta = if (most_left > estimate.left)
                most_left - estimate.left
            else
                most_right - estimate.right;
            estimate.left += delta;
            estimate.right += delta;
        } else {
            estimate.left = most_left;
            estimate.right = most_right;
        }
    }

    estimate.top = free.top;
    for (balloons) |previous| {
        var cloud = previous.cloud_bbox;
        if (cloud.right < estimate.left) {
            estimate.top = @min(estimate.top, cloud.top);
        } else {
            // `Dock(RECT&)`, `balloon.cpp:568-573`: -20 + 40 + 70 = 90.
            cloud.top += top_border + y_border + h_wave_height;
            cloud.bottom += top_border + y_border + h_wave_height;
            estimate.top = @min(estimate.top, cloud.bottom);
        }
    }
}

fn lowestPreviousBottom(balloons: []const InternalBalloon, initial: i32) i32 {
    var low = initial;
    for (balloons) |balloon| {
        // `LowestPreviousBottom` reads CBalloon::m_bbox.Bottom, which is
        // offset relative to m_trueBox rather than the translated cloud box.
        const bbox_bottom = balloon.origin.y - balloon.cloud_bbox.height();
        low = @min(low, bbox_bottom);
    }
    return low;
}

/// `CUnitPanel::GetCloudEstimate`, `panel.cpp:885-922`.
fn getCloudEstimate(
    text: []const u8,
    format_changes: []const formatting.Change,
    kind: BalloonKind,
    arrow_x: i32,
    prior: []const InternalBalloon,
    free: Rect,
    font: FontInfo,
    measurer: TextMeasurer,
    random: *MsvcrtRand,
) Rect {
    const extent = measurer.measureFormatted(text, format_changes, 0);
    const length = extent.width;
    const area = areaEstimateFormatted(text, format_changes, font, measurer);
    const max_width = free.width();
    var goal_width: i32 = undefined;
    if (length <= one_line_threshold) {
        goal_width = length;
    } else {
        // `canBeTall` is hard-coded TRUE in the released 2.5 source.
        const potential_height = lowestPreviousBottom(prior, free.top) - free.bottom + min_hook_height;
        var minimum_width = @divTrunc(area, potential_height);
        minimum_width = @max(minimum_width, widestWordFormatted(text, format_changes, measurer));
        goal_width = minimum_width + @as(i32, @intFromFloat(random.float() *
            @as(f64, @floatFromInt(max_width - minimum_width))));
    }
    goal_width = @min(goal_width + 200, max_width);
    goal_width = @min(goal_width, length + 200);

    var left: i32 = undefined;
    if (kind.isBox()) {
        left = free.left;
    } else {
        const left_limit = arrow_x - goal_width;
        const right_limit = arrow_x;
        left = left_limit + @as(i32, @intFromFloat(random.float() *
            @as(f64, @floatFromInt(right_limit - left_limit))));
        if (left < free.left) left = free.left;
        if (left + goal_width > free.right) left = free.right - goal_width;
    }
    return .{ .left = left, .right = left + goal_width, .top = free.top, .bottom = free.bottom };
}

fn makePanelLines(allocator: std.mem.Allocator, balloon: *const InternalBalloon, font: FontInfo) ![]TextLine {
    const lines = try allocator.alloc(TextLine, balloon.format.count);
    for (lines, 0..) |*line, i| {
        const raw = balloon.format.lines[i];
        line.* = .{
            .start = raw.start,
            .len = raw.len,
            .width = raw.width,
            .x = balloon.origin.x + balloon.format.left_x[i],
            .y = balloon.origin.y - @as(i32, @intCast(i)) * font.line_height,
        };
    }
    return lines;
}

fn thoughtBubbles(allocator: std.mem.Allocator, balloon: *const InternalBalloon) ![]ThoughtBubble {
    if (balloon.kind != .think) return allocator.alloc(ThoughtBubble, 0);
    // `CBWoodringThink::Draw`, `balloon.cpp:1830-1864`.
    const entry = Point{
        .x = @divTrunc(balloon.route.left + balloon.route.right, 2),
        .y = balloon.format.bbox.bottom + balloon.origin.y,
    };
    const tail = Point{ .x = balloon.arrow_x, .y = balloon.speaker_box.top + 200 };
    const delta_y = entry.y - tail.y;
    if (delta_y < 0) return allocator.alloc(ThoughtBubble, 0);
    const count_i32 = @divTrunc(delta_y + inter_bubble, bubble_height + inter_bubble);
    if (count_i32 <= 0) return allocator.alloc(ThoughtBubble, 0);
    const count: usize = @intCast(count_i32);
    const result = try allocator.alloc(ThoughtBubble, count);
    const spacing = if (count > 1)
        @divTrunc(delta_y - bubble_height * count_i32, count_i32 - 1)
    else
        0;
    const dx: f64 = @floatFromInt(entry.x - tail.x);
    const dy: f64 = @floatFromInt(entry.y - tail.y);
    const magnitude = @sqrt(dx * dx + dy * dy);
    const norm = if (magnitude < 1.0e-24) DPoint{ .x = 0, .y = 0 } else DPoint{ .x = dx / magnitude, .y = dy / magnitude };
    var start = pointAdd(tail, toPoint(dScale(@as(f64, @floatFromInt(bubble_height)) / 2.0, norm)));
    const increment = toPoint(dScale(@floatFromInt(bubble_height + spacing), norm));
    const width_delta = if (count > 1)
        @divTrunc(end_bubble_width - bubble_height, 2 * (count_i32 - 1))
    else
        0;
    var width_adjustment: i32 = 0;
    for (result) |*bubble| {
        bubble.* = .{
            .left = start.x - bubble_height / 2 - width_adjustment,
            .right = start.x + bubble_height / 2 + width_adjustment,
            .top = start.y + bubble_height / 2,
            .bottom = start.y - bubble_height / 2,
        };
        start = pointAdd(start, increment);
        width_adjustment += width_delta;
    }
    return result;
}

/// `CBWoodringNormal::AddArrow`, `balloon.cpp:1466-1530`.
fn addArrow(
    allocator: std.mem.Allocator,
    balloon: *const InternalBalloon,
) Error!struct { points: []Point, beziers: []CubicBezier, tail: Tail } {
    var bottom_panel = Point{ .x = balloon.arrow_x, .y = balloon.speaker_box.top + 200 };
    var bottom_local = pointSub(bottom_panel, balloon.origin);
    var x_break = @divTrunc(balloon.route.left + balloon.route.right, 2) - balloon.origin.x;
    const last_index = balloon.format.count - 1;
    const bottom_start = balloon.format.left_x[last_index];
    const bottom_end = bottom_start + balloon.format.lines[last_index].width;
    if (x_break < bottom_start and bottom_start + balloon.origin.x < balloon.route.right - large_delta)
        x_break = bottom_start + small_delta
    else if (x_break > bottom_end and bottom_end + balloon.origin.x > balloon.route.left + large_delta)
        x_break = bottom_end - small_delta;

    var top_panel = Point{ .x = x_break + balloon.origin.x, .y = balloon.cloud_bbox.bottom };
    if (top_panel.y - bottom_panel.y < min_tail_height) {
        bottom_panel.y = top_panel.y - min_tail_height;
        bottom_local.y = bottom_panel.y - balloon.origin.y;
    }
    x_break = clampTailBreak(x_break, balloon.origin.x, top_panel.y, bottom_panel);

    const opened = try breakSpline(allocator, balloon.base_points, x_break, balloon.format.bbox.bottom);
    errdefer allocator.free(opened.points);
    errdefer allocator.free(opened.beziers);
    const left = opened.points[opened.points.len - 1];
    const right = opened.points[0];
    top_panel = .{
        .x = @divTrunc(left.x + right.x, 2) + balloon.origin.x,
        .y = @divTrunc(left.y + right.y, 2) + balloon.origin.y,
    };
    const tail_length: i32 = @intFromFloat(distance(top_panel, bottom_panel));
    const altitude: i32 = @intFromFloat(0.05 * @as(f64, @floatFromInt(tail_length)));
    const sign: i32 = if (bottom_local.x > left.x) 1 else -1;
    return .{
        .points = opened.points,
        .beziers = opened.beziers,
        .tail = .{
            .tip = bottom_local,
            .opening_left = left,
            .opening_right = right,
            .first_arc = .{ .start = left, .end = bottom_local, .altitude = sign * altitude },
            .second_arc = .{ .start = bottom_local, .end = right, .altitude = -sign * altitude },
        },
    };
}

/// The released source's literal "45 degree" clamp, including its asymmetric
/// `fabs(angle) - PI/2` condition (`balloon.cpp:1497-1509`).
fn clampTailBreak(x_break: i32, origin_x: i32, top_y: i32, bottom_panel: Point) i32 {
    var angle = std.math.atan2(
        @as(f64, @floatFromInt(top_y - bottom_panel.y)),
        @as(f64, @floatFromInt(x_break + origin_x - bottom_panel.x)),
    );
    if (@abs(angle) - std.math.pi / 2.0 > std.math.pi / 4.0) {
        angle = if (angle > 3.0 * std.math.pi / 4.0) 3.0 * std.math.pi / 4.0 else std.math.pi / 4.0;
        const height_delta = top_y - bottom_panel.y;
        return @intFromFloat(@cos(angle) * @as(f64, @floatFromInt(height_delta)) +
            @as(f64, @floatFromInt(bottom_panel.x - origin_x)));
    }
    return x_break;
}

fn finalizeGeometry(allocator: std.mem.Allocator, balloon: *InternalBalloon, font: FontInfo) Error!BalloonGeometry {
    const text = balloon.text;
    balloon.text = &.{};
    errdefer allocator.free(text);
    const format_changes = balloon.formatting;
    balloon.formatting = &.{};
    errdefer allocator.free(format_changes);
    const lines = try makePanelLines(allocator, balloon, font);
    errdefer allocator.free(lines);
    const bubbles = try thoughtBubbles(allocator, balloon);
    errdefer allocator.free(bubbles);

    var points: []Point = undefined;
    var beziers: []CubicBezier = undefined;
    var tail: ?Tail = null;
    if (balloon.kind.isBox()) {
        allocator.free(balloon.base_points);
        balloon.base_points = &.{};
        points = try allocator.alloc(Point, 4);
        points[0] = .{ .x = balloon.format.bbox.left - xbox_delta, .y = balloon.format.bbox.bottom - ybox_delta };
        points[1] = .{ .x = points[0].x, .y = balloon.format.bbox.top + ybox_delta };
        points[2] = .{ .x = balloon.format.bbox.right + xbox_delta, .y = points[1].y };
        points[3] = .{ .x = points[2].x, .y = points[0].y };
        errdefer allocator.free(points);
        beziers = try allocator.alloc(CubicBezier, 0);
    } else {
        // CBWoodringThink overrides only Draw, not SetBalloonTraj
        // (balloon.cpp:1820-1868): CBWoodringThink::Draw calls
        // CBWoodringNormal::Draw first ("will draw the cloud properly", i.e.
        // the same open-cloud + pointed-tail path any say/whisper balloon
        // gets from AddArrow) and only then overlays the bubble chain. A
        // think balloon is not tailless — the bubbles are additive, not a
        // replacement. See thoughtBubbles below for the think-only overlay.
        const arrow = try addArrow(allocator, balloon);
        allocator.free(balloon.base_points);
        balloon.base_points = &.{};
        points = arrow.points;
        beziers = arrow.beziers;
        tail = arrow.tail;
    }
    return .{
        .input_index = balloon.input_index,
        .kind = balloon.kind,
        .dashed = balloon.dashed_override orelse balloon.kind.dashed(),
        .text = text,
        .formatting = format_changes,
        .lines = lines,
        .cloud_bbox = balloon.cloud_bbox,
        .route_region = balloon.route,
        .origin = balloon.origin,
        .outline_points = points,
        .outline_beziers = beziers,
        .tail = tail,
        .thought_bubbles = bubbles,
    };
}

fn replaceContinuation(allocator: std.mem.Allocator, slot: *?[]u8, rest: []const u8) !void {
    const replacement = try allocator.dupe(u8, rest);
    if (slot.*) |old| allocator.free(old);
    slot.* = replacement;
}

fn replaceContinuationFormatting(
    allocator: std.mem.Allocator,
    slot: *?[]formatting.Change,
    rest: []const formatting.Change,
) !void {
    const replacement = try allocator.dupe(formatting.Change, rest);
    if (slot.*) |old| allocator.free(old);
    slot.* = replacement;
}

/// Full `CUnitPanel::LayoutBalloons` / `LayoutBalloon` port. Layout is seeded
/// with the original MSVCRT recurrence, uses exact route-region subtraction,
/// and emits device-independent Woodring render geometry.
pub fn layoutPanel(
    allocator: std.mem.Allocator,
    inputs: []const BalloonInput,
    free_rect: Rect,
    seed: u32,
    font: FontInfo,
    measurer: TextMeasurer,
) Error!PanelLayout {
    var random = MsvcrtRand.init(seed);
    return layoutPanelWithRandom(allocator, inputs, free_rect, font, measurer, &random);
}

/// The source application uses the process-wide MSVCRT generator both to seed
/// newly constructed panels and to lay out their balloons.  This entry point
/// exposes that shared state so page sequencing can preserve the exact random
/// stream, including random values consumed by a failed clone attempt.
pub fn layoutPanelWithRandom(
    allocator: std.mem.Allocator,
    inputs: []const BalloonInput,
    free_rect: Rect,
    font: FontInfo,
    measurer: TextMeasurer,
    random: *MsvcrtRand,
) Error!PanelLayout {
    return layoutPanelWithMetricSetRandom(
        allocator,
        inputs,
        free_rect,
        .{ .normal = .{ .font = font, .measurer = measurer } },
        random,
    );
}

pub fn layoutPanelWithMetricSet(
    allocator: std.mem.Allocator,
    inputs: []const BalloonInput,
    free_rect: Rect,
    seed: u32,
    metrics: MetricSet,
) Error!PanelLayout {
    var random = MsvcrtRand.init(seed);
    return layoutPanelWithMetricSetRandom(allocator, inputs, free_rect, metrics, &random);
}

/// Multi-face form of `layoutPanelWithRandom`; the normal and whisper
/// measurers remain paired with the face ultimately used to rasterize each
/// balloon, preserving GDI's per-class font selection through line breaking.
pub fn layoutPanelWithMetricSetRandom(
    allocator: std.mem.Allocator,
    inputs: []const BalloonInput,
    free_rect: Rect,
    metrics: MetricSet,
    random: *MsvcrtRand,
) Error!PanelLayout {
    if (metrics.normal.font.line_height <= 0) return error.InvalidFont;
    if (metrics.whisper) |whisper| if (whisper.font.line_height <= 0) return error.InvalidFont;
    if (free_rect.width() <= 0 or free_rect.height() <= 0) return error.InvalidRectangle;
    if (inputs.len > max_balloons) return error.TooManyBalloons;
    if (inputs.len == 0) return .{ .balloons = try allocator.alloc(BalloonGeometry, 0) };

    const internals = try allocator.alloc(InternalBalloon, inputs.len);
    var internal_count: usize = 0;
    defer {
        for (internals[0..internal_count]) |*balloon| balloon.deinit(allocator);
        allocator.free(internals);
    }
    var continuation_text: ?[]u8 = null;
    errdefer if (continuation_text) |rest| allocator.free(rest);
    var continuation_formatting: ?[]formatting.Change = null;
    errdefer if (continuation_formatting) |rest| allocator.free(rest);

    for (inputs, 0..) |input, index| {
        if (input.text.len == 0) return error.EmptyText;
        const selected = metrics.forKind(input.kind);
        const font = selected.font;
        const measurer = selected.measurer;
        const capitalized = try uppercaseAsciiAlloc(allocator, input.text);
        defer allocator.free(capitalized);
        var estimate = getCloudEstimate(
            capitalized,
            input.formatting,
            input.kind,
            input.arrow_x,
            internals[0..internal_count],
            free_rect,
            font,
            measurer,
            random,
        );
        getInterveningBBox(internals[0..internal_count], free_rect, &estimate, input.arrow_x);

        var built = computeBalloon(allocator, input, index, estimate.left, estimate.right, estimate.top, font, measurer, random) catch |err| blk: {
            if (inputs.len != 1 or index != 0 or err == error.OutOfMemory) return if (err == error.OutOfMemory) err else error.BalloonsDoNotFit;
            // `ForceFitBalloon`, `panel.cpp:153-164`.
            var split = try splitHeightFormatted(
                allocator,
                capitalized,
                input.formatting,
                free_rect.width() - 2 * x_border,
                free_rect.height(),
                font,
                measurer,
            );
            defer split.deinit(allocator);
            const forced_input = BalloonInput{
                .text = split.first,
                .formatting = split.first_formatting,
                .kind = input.kind,
                .dashed_override = input.dashed_override,
                .arrow_x = input.arrow_x,
                .speaker_box = input.speaker_box,
            };
            if (split.rest) |rest| {
                try replaceContinuation(allocator, &continuation_text, rest);
                try replaceContinuationFormatting(
                    allocator,
                    &continuation_formatting,
                    split.rest_formatting orelse &.{},
                );
            }
            break :blk try computeBalloon(allocator, forced_input, index, free_rect.left, free_rect.right, free_rect.top, font, measurer, random);
        };
        if (built.origin.y > -250) dockAtTop(&built, free_rect.top);
        built.route = built.cloud_bbox;
        if (built.route.bottom < free_rect.bottom + min_hook_height) {
            built.deinit(allocator);
            if (inputs.len == 1 and index == 0) {
                // Force fit after geometric failure, matching the source.
                var split = try splitHeightFormatted(
                    allocator,
                    capitalized,
                    input.formatting,
                    free_rect.width() - 2 * x_border,
                    free_rect.height(),
                    font,
                    measurer,
                );
                defer split.deinit(allocator);
                const forced_input = BalloonInput{ .text = split.first, .formatting = split.first_formatting, .kind = input.kind, .dashed_override = input.dashed_override, .arrow_x = input.arrow_x, .speaker_box = input.speaker_box };
                built = try computeBalloon(allocator, forced_input, index, free_rect.left, free_rect.right, free_rect.top, font, measurer, random);
                if (split.rest) |rest| {
                    try replaceContinuation(allocator, &continuation_text, rest);
                    try replaceContinuationFormatting(
                        allocator,
                        &continuation_formatting,
                        split.rest_formatting orelse &.{},
                    );
                }
                if (built.origin.y > -250) dockAtTop(&built, free_rect.top);
                built.route = built.cloud_bbox;
            } else return error.BalloonsDoNotFit;
        }
        const left = built.route.left;
        const right = built.route.right;
        for (internals[0..internal_count]) |*previous| setRoute(previous, built.arrow_x, left, right);
        internals[internal_count] = built;
        internal_count += 1;
    }

    const output = try allocator.alloc(BalloonGeometry, internal_count);
    var output_count: usize = 0;
    errdefer {
        for (output[0..output_count]) |*balloon| balloon.deinit(allocator);
        allocator.free(output);
    }
    for (internals[0..internal_count], 0..) |*balloon, index| {
        output[index] = try finalizeGeometry(allocator, balloon, metrics.forKind(balloon.kind).font);
        output_count += 1;
    }
    return .{
        .balloons = output,
        .continuation_text = continuation_text,
        .continuation_formatting = continuation_formatting,
    };
}

const TestMetrics = struct {
    char_width: i32 = 10,
    line_height: i32 = 100,

    fn measure(raw: *const anyopaque, text: []const u8) Size {
        const self: *const TestMetrics = @ptrCast(@alignCast(raw));
        var width: i32 = 0;
        var max_width_seen: i32 = 0;
        var lines: i32 = 1;
        for (text) |byte| {
            if (byte == '\n' or byte == '\r') {
                max_width_seen = @max(max_width_seen, width);
                width = 0;
                if (byte == '\n') lines += 1;
            } else if (byte != 0 and byte != '\t' and byte != 0x0b and byte != 0x0c) {
                width += self.char_width;
            }
        }
        return .{ .width = @max(max_width_seen, width), .height = lines * self.line_height };
    }

    fn adapter(self: *const TestMetrics) TextMeasurer {
        return .{ .context = self, .measure_fn = measure };
    }
};

test "MSVCRT seeded sequence matches the Win32 runtime" {
    var random = MsvcrtRand.init(1);
    try std.testing.expectEqual(@as(u15, 41), random.next());
    try std.testing.expectEqual(@as(u15, 18467), random.next());
    try std.testing.expectEqual(@as(u15, 6334), random.next());
}

test "metric set selects italic measurements only for Woodring whisper" {
    const normal = TestMetrics{ .char_width = 10, .line_height = 100 };
    const whisper = TestMetrics{ .char_width = 12, .line_height = 100 };
    const metrics = MetricSet{
        .normal = .{ .font = .{ .line_height = 100 }, .measurer = normal.adapter() },
        .whisper = .{ .font = .{ .line_height = 100 }, .measurer = whisper.adapter() },
    };

    try std.testing.expectEqual(@as(i32, 24), metrics.forKind(.whisper).measurer.measure("AB").width);
    try std.testing.expectEqual(@as(i32, 20), metrics.forKind(.say).measurer.measure("AB").width);
    // `BM_ACTION|BM_WHISPER` is represented by an action kind plus a dashed
    // override, matching the source's CBWoodringBox construction.
    try std.testing.expectEqual(@as(i32, 20), metrics.forKind(.action).measurer.measure("AB").width);
}

test "source line breaker honors hard returns and forcibly breaks long words" {
    const metrics = TestMetrics{};
    var returned = try breakIntoLines(std.testing.allocator, "AB\nCD", 100, metrics.adapter());
    defer returned.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), returned.lines.len);
    try std.testing.expectEqualStrings("AB", "AB\nCD"[returned.lines[0].start..][0..returned.lines[0].len]);
    try std.testing.expectEqualStrings("CD", "AB\nCD"[returned.lines[1].start..][0..returned.lines[1].len]);

    var forced = try breakIntoLines(std.testing.allocator, "ABCDEFGHIJ", 35, metrics.adapter());
    defer forced.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 4), forced.lines.len);
    try std.testing.expectEqualStrings("ABC", "ABCDEFGHIJ"[forced.lines[0].start..][0..forced.lines[0].len]);
    try std.testing.expectEqualStrings("J", "ABCDEFGHIJ"[forced.lines[3].start..][0..forced.lines[3].len]);
}

test "AreaEstimate and source isprint WidestWord behavior are literal" {
    const metrics = TestMetrics{};
    const font = FontInfo{ .line_height = 100 };
    // width 50, GDI height 200 because the test adapter sees one hard return.
    try std.testing.expectEqual(@as(i32, 19_500), areaEstimate("AB CD\nXYZ", font, metrics.adapter()));
    // C isprint includes the space, so the first run is "AB CD" (50 TWIPs).
    try std.testing.expectEqual(@as(i32, 50), widestWord("AB CD\nXYZ", metrics.adapter()));
}

test "continuation split places ellipses on both panels at a source line break" {
    const metrics = TestMetrics{};
    const font = FontInfo{ .line_height = 100 };
    var split = try splitHeight(
        std.testing.allocator,
        "ONE TWO THREE FOUR FIVE",
        60,
        600,
        font,
        metrics.adapter(),
    );
    defer split.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("ONE TW...", split.first);
    try std.testing.expect(split.rest != null);
    try std.testing.expectEqualStrings("...O THREE FOUR FIVE", split.rest.?);

    const changes = [_]formatting.Change{
        .{ .offset = 2, .format = formatting.effect.italic },
        .{ .offset = 12, .format = 0 },
    };
    var styled = try splitHeightFormatted(
        std.testing.allocator,
        "ONE TWO THREE FOUR FIVE",
        &changes,
        60,
        600,
        font,
        metrics.adapter(),
    );
    defer styled.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(formatting.Change, &.{
        .{ .offset = 2, .format = formatting.effect.italic },
        .{ .offset = 6, .format = 0 },
    }, styled.first_formatting);
    try std.testing.expectEqualSlices(formatting.Change, &.{
        .{ .offset = 3, .format = formatting.effect.italic },
        .{ .offset = 9, .format = 0 },
    }, styled.rest_formatting.?);
}

test "Woodring outline follows text filters and original beta spline matrix" {
    const allocator = std.testing.allocator;
    const metrics = TestMetrics{ .char_width = 50, .line_height = 100 };
    const font = FontInfo{ .line_height = 100 };
    var random = MsvcrtRand.init(1);
    const format = try buildFormat(allocator, "AAAA BBBB C", &.{}, 260, font, metrics.adapter(), false, &random);
    const points = try createBalloonControlPoints(allocator, &format, font);
    defer allocator.free(points);
    try std.testing.expect(points.len >= 4);
    try std.testing.expect(points.len <= max_points);
    try std.testing.expectEqual(format.left_x[0] - x_border, points[0].x);
    const beziers = try betaBeziers(allocator, points, true);
    defer allocator.free(beziers);
    try std.testing.expectEqual(points.len, beziers.len);
    try std.testing.expectEqual(beziers[beziers.len - 1].p3, beziers[0].p0);

    const matrix = betaMatrix();
    try std.testing.expectApproxEqAbs(-2.0 / 17.0, matrix[0][0], 0.000_001);
    try std.testing.expectApproxEqAbs(16.0 / 17.0, matrix[0][1], 0.000_001);
    try std.testing.expectApproxEqAbs(13.0 / 17.0, matrix[3][1], 0.000_001);
}

test "panel layout subtracts route regions and emits tail Beziers and arcs" {
    const allocator = std.testing.allocator;
    const metrics = TestMetrics{ .char_width = 40, .line_height = 100 };
    const font = FontInfo{ .line_height = 100 };
    const inputs = [_]BalloonInput{
        .{
            .text = "first balloon from source",
            .arrow_x = 500,
            .speaker_box = .{ .left = 250, .top = -700, .right = 750, .bottom = -1500 },
        },
        .{
            .text = "second balloon from source",
            .arrow_x = 1800,
            .speaker_box = .{ .left = 1550, .top = -700, .right = 2050, .bottom = -1500 },
        },
    };
    var panel = try layoutPanel(
        allocator,
        &inputs,
        .{ .left = 60, .top = -60, .right = 2240, .bottom = -1150 },
        1234,
        font,
        metrics.adapter(),
    );
    defer panel.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), panel.balloons.len);
    try std.testing.expect(panel.balloons[0].route_region.right <= panel.balloons[1].route_region.left);
    for (panel.balloons) |balloon| {
        try std.testing.expect(balloon.outline_beziers.len > 0);
        try std.testing.expect(balloon.tail != null);
        const tail = balloon.tail.?;
        try std.testing.expectEqual(tail.opening_left, tail.first_arc.start);
        try std.testing.expectEqual(tail.tip, tail.first_arc.end);
        try std.testing.expectEqual(tail.tip, tail.second_arc.start);
        try std.testing.expectEqual(tail.opening_right, tail.second_arc.end);
    }
}

test "thought balloon keeps the pointed tail and adds source ellipses" {
    const allocator = std.testing.allocator;
    const metrics = TestMetrics{ .char_width = 30, .line_height = 100 };
    const input = [_]BalloonInput{.{
        .text = "thinking",
        .kind = .think,
        .arrow_x = 1100,
        .speaker_box = .{ .left = 850, .top = -600, .right = 1350, .bottom = -1100 },
    }};
    var panel = try layoutPanel(
        allocator,
        &input,
        .{ .left = 60, .top = -60, .right = 2240, .bottom = -1150 },
        77,
        .{ .line_height = 100 },
        metrics.adapter(),
    );
    defer panel.deinit(allocator);
    const balloon = panel.balloons[0];
    // CBWoodringThink overrides only Draw, not SetBalloonTraj
    // (balloon.cpp:1820-1868): it inherits CBWoodringNormal's AddArrow tail
    // unchanged and additively overlays the bubble chain on top ("will draw
    // the cloud properly", balloon.cpp:1828) -- a think balloon keeps its
    // pointed tail, it is not a replacement for one.
    try std.testing.expect(balloon.tail != null);
    try std.testing.expect(balloon.thought_bubbles.len > 0);
    try std.testing.expectEqual(@as(i32, bubble_height), balloon.thought_bubbles[0].height());
}

test "tail break preserves the source asymmetric 45-degree clamp" {
    // A far-left opening produces an angle just below PI and is clamped to
    // 3*PI/4: trunc(cos(3*PI/4) * 100) == -70.
    try std.testing.expectEqual(
        @as(i32, -70),
        clampTailBreak(-1000, 0, 100, .{ .x = 0, .y = 0 }),
    );
    // The released fabs(angle)-PI/2 condition does not clamp the symmetric
    // far-right case; retaining that asymmetry is source parity.
    try std.testing.expectEqual(
        @as(i32, 1000),
        clampTailBreak(1000, 0, 100, .{ .x = 0, .y = 0 }),
    );
}

test "action balloon emits the exact four-sided Woodring box with no tail" {
    const allocator = std.testing.allocator;
    const metrics = TestMetrics{ .char_width = 30, .line_height = 100 };
    const input = [_]BalloonInput{.{
        .text = "waves hello",
        .kind = .action,
        .arrow_x = 1000,
        .speaker_box = .{ .left = 750, .top = -700, .right = 1250, .bottom = -1500 },
    }};
    var panel = try layoutPanel(
        allocator,
        &input,
        .{ .left = 60, .top = -60, .right = 2240, .bottom = -1150 },
        9,
        .{ .line_height = 100 },
        metrics.adapter(),
    );
    defer panel.deinit(allocator);
    const box = panel.balloons[0];
    try std.testing.expectEqual(@as(usize, 4), box.outline_points.len);
    try std.testing.expectEqual(@as(usize, 0), box.outline_beziers.len);
    try std.testing.expect(box.tail == null);
    try std.testing.expectEqual(box.outline_points[0].x, box.outline_points[1].x);
    try std.testing.expectEqual(box.outline_points[1].y, box.outline_points[2].y);
}

fn exerciseLayoutAllocationFailures(allocator: std.mem.Allocator) !void {
    const metrics = TestMetrics{ .char_width = 35, .line_height = 100 };
    const inputs = [_]BalloonInput{
        .{
            .text = "allocation-safe source balloon one",
            .arrow_x = 500,
            .speaker_box = .{ .left = 250, .top = -700, .right = 750, .bottom = -1500 },
        },
        .{
            .text = "allocation-safe source balloon two",
            .kind = .think,
            .arrow_x = 1800,
            .speaker_box = .{ .left = 1550, .top = -700, .right = 2050, .bottom = -1500 },
        },
    };
    var panel = try layoutPanel(
        allocator,
        &inputs,
        .{ .left = 60, .top = -60, .right = 2240, .bottom = -1150 },
        0x1234,
        .{ .line_height = 100 },
        metrics.adapter(),
    );
    defer panel.deinit(allocator);
}

test "layout ownership is safe at every allocation failure point" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseLayoutAllocationFailures,
        .{},
    );
}

test "liftAbove docks a Color balloon above a standing dest" {
    const gpa = std.testing.allocator;
    var lines = [_]TextLine{.{ .start = 0, .len = 0, .width = 0, .x = 200, .y = -400 }};
    var geo = BalloonGeometry{
        .input_index = 0,
        .kind = .say,
        .dashed = false,
        .text = try gpa.dupe(u8, "HI"),
        .formatting = &.{},
        .lines = &lines,
        .cloud_bbox = .{ .left = 100, .top = -400, .right = 800, .bottom = -1200 },
        .route_region = .{ .left = 100, .top = -400, .right = 800, .bottom = -1200 },
        .origin = .{ .x = 100, .y = -400 },
        .outline_points = &.{},
        .outline_beziers = &.{},
        .tail = .{
            .tip = .{ .x = 50, .y = -1400 },
            .opening_left = .{ .x = 0, .y = 0 },
            .opening_right = .{ .x = 10, .y = 0 },
            .first_arc = .{ .start = .{ .x = 0, .y = 0 }, .end = .{ .x = 50, .y = -1400 }, .altitude = 0 },
            .second_arc = .{ .start = .{ .x = 50, .y = -1400 }, .end = .{ .x = 10, .y = 0 }, .altitude = 0 },
        },
        .thought_bubbles = &.{},
    };
    defer gpa.free(geo.text);
    const world_tip_before = geo.origin.y + geo.tail.?.tip.y;
    geo.liftAbove(-900, -20);
    try std.testing.expectEqual(@as(i32, -900), geo.cloud_bbox.bottom);
    try std.testing.expectEqual(@as(i32, -400 + 300), geo.origin.y);
    try std.testing.expectEqual(world_tip_before, geo.origin.y + geo.tail.?.tip.y);
    try std.testing.expectEqual(geo.tail.?.tip.y, geo.tail.?.first_arc.end.y);
    try std.testing.expectEqual(geo.tail.?.tip.y, geo.tail.?.second_arc.start.y);
}

test "retargetTip aims a Color tail at the post-nudge dest" {
    var lines = [_]TextLine{.{ .start = 0, .len = 0, .width = 0, .x = 200, .y = -400 }};
    var geo = BalloonGeometry{
        .input_index = 0,
        .kind = .say,
        .dashed = false,
        .text = try std.testing.allocator.dupe(u8, "HI"),
        .formatting = &.{},
        .lines = &lines,
        .cloud_bbox = .{ .left = 100, .top = -400, .right = 800, .bottom = -900 },
        .route_region = .{ .left = 100, .top = -400, .right = 800, .bottom = -900 },
        .origin = .{ .x = 100, .y = -400 },
        .outline_points = &.{},
        .outline_beziers = &.{},
        .tail = .{
            .tip = .{ .x = 50, .y = -320 },
            .opening_left = .{ .x = 0, .y = 0 },
            .opening_right = .{ .x = 10, .y = 0 },
            .first_arc = .{ .start = .{ .x = 0, .y = 0 }, .end = .{ .x = 50, .y = -320 }, .altitude = 0 },
            .second_arc = .{ .start = .{ .x = 50, .y = -320 }, .end = .{ .x = 10, .y = 0 }, .altitude = 0 },
        },
        .thought_bubbles = &.{},
    };
    defer std.testing.allocator.free(geo.text);
    geo.retargetTip(-1100 + 200);
    try std.testing.expectEqual(@as(i32, -900), geo.origin.y + geo.tail.?.tip.y);
    try std.testing.expectEqual(geo.tail.?.tip.y, geo.tail.?.first_arc.end.y);
    try std.testing.expectEqual(geo.tail.?.tip.y, geo.tail.?.second_arc.start.y);
}
