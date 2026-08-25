//! Direct Zig port of Microsoft Comic Chat 2.5's panel avatar layout.
//!
//! The algorithm and constants in this file come from the MIT-licensed
//! `v2.5-beta-1-modern/panel.cpp`, principally `EvalPair`, `EvalPlacement`,
//! `DoGreedyOrdering`, `OrderAvatars`, and `CUnitPanel::LayoutAvatars`.
//! Coordinates use the original panel's logical units (TWIPs in the MFC app),
//! with a conventional top-down rectangle returned to the renderer.

const std = @import("std");

pub const max_bodies_per_panel: usize = 5;
pub const default_unit_width: i32 = 2300;
pub const default_unit_height: i32 = 2300;

pub const Rect = struct {
    x: i32,
    y: i32,
    w: i32,
    h: i32,
};

/// Persistent per-avatar placement state. The original stores these fields on
/// CAvatarX and updates them after each panel to avoid visual jumping.
pub const History = struct {
    last_dir: bool = false,
    last_right: u32 = 0,
    last_left: u32 = 0,
};

/// Source dimensions and conversational relationships for one panel body.
pub const Body = struct {
    id: u32,
    width: i32,
    height: i32,
    norm_height: i32 = 100,
    head_height: i32,
    face_x: i32,
    talk_to_ids: []const u32 = &.{},
    history: History = .{},
    /// Generated Color/HD standing cards. Source zoom-in keeps the pre-zoom
    /// top and crops around the ground line, which turns a full woman into
    /// legs-only. Skip that branch so she stays a recognizable whole person.
    /// Testdata bodies leave this false so goldens stay on `panel.cpp`.
    keep_recognizable: bool = false,
};

pub const Placement = struct {
    body_index: usize,
    rect: Rect,
    flipped: bool,
    arrow_x: i32,
    history: History,
};

/// `CBackDrop::m_bbox`, in the source's y-up panel coordinates.  The backdrop
/// renderer uses this rectangle as the source crop after avatar zooming.
pub const ArtRect = struct {
    left: i32,
    bottom: i32,
    right: i32,
    top: i32,
};

pub const SceneLayout = struct {
    placements: []Placement,
    art_bbox: ArtRect,
    zoom_factor: f64,

    pub fn deinit(self: *SceneLayout, gpa: std.mem.Allocator) void {
        gpa.free(self.placements);
        self.* = undefined;
    }
};

const Working = struct {
    body_index: usize,
    flipped: bool,
};

pub const Error = error{ InvalidPanelSize, InvalidBody, TooManyBodies } || std.mem.Allocator.Error;

/// Port of `CUnitPanel::LayoutAvatars`. `establishing` suppresses the original
/// zoom-in branch while a connection is still being established.
pub fn layoutAvatars(
    gpa: std.mem.Allocator,
    bodies: []const Body,
    unit_width: i32,
    unit_height: i32,
    establishing: bool,
) Error![]Placement {
    const scene = try layoutScene(gpa, bodies, unit_width, unit_height, establishing);
    return scene.placements;
}

/// Full `LayoutAvatars` result, including the exact `AdjustArtToCoord` crop
/// applied to the panel backdrop.  `layoutAvatars` remains as the compatibility
/// ownership-transfer wrapper for callers interested only in bodies.
pub fn layoutScene(
    gpa: std.mem.Allocator,
    bodies: []const Body,
    unit_width: i32,
    unit_height: i32,
    establishing: bool,
) Error!SceneLayout {
    if (unit_width <= 0 or unit_height <= 0) return error.InvalidPanelSize;
    if (bodies.len == 0) return .{
        .placements = try gpa.alloc(Placement, 0),
        .art_bbox = .{ .left = 0, .bottom = -unit_height, .right = unit_width, .top = 0 },
        .zoom_factor = 1.0,
    };
    if (bodies.len > max_bodies_per_panel) return error.TooManyBodies;
    for (bodies) |body| {
        if (body.width <= 0 or body.height <= 0 or body.norm_height <= 0 or
            body.head_height <= 0 or body.face_x < 0 or body.face_x > body.width)
            return error.InvalidBody;
    }

    const ordered = try greedyOrder(gpa, bodies);
    defer gpa.free(ordered);

    var widths: [max_bodies_per_panel]i32 = undefined;
    var heights: [max_bodies_per_panel]i32 = undefined;
    var tops: [max_bodies_per_panel]i32 = undefined;
    var head_heights: [max_bodies_per_panel]i32 = undefined;
    var arrow_fractions: [max_bodies_per_panel]f64 = undefined;

    const max_body_height: i32 = @intFromFloat(@as(f64, @floatFromInt(unit_height)) / 1.9);
    var max_norm: i32 = 0;
    for (ordered) |entry| max_norm = @max(max_norm, bodies[entry.body_index].norm_height);

    var body_width: i32 = 0;
    for (ordered, 0..) |entry, i| {
        const body = bodies[entry.body_index];
        const source_face_x = if (entry.flipped) body.width - body.face_x else body.face_x;
        arrow_fractions[i] = @as(f64, @floatFromInt(source_face_x)) / @as(f64, @floatFromInt(body.width));

        const height_cap = if (body.keep_recognizable)
            recognizableStandingHeight(unit_height)
        else
            max_body_height;
        const new_height: i32 = roundF32ToI32(
            @as(f32, @floatFromInt(height_cap)) *
                (@as(f32, @floatFromInt(body.norm_height)) / @as(f32, @floatFromInt(max_norm))),
        );
        const scale_ratio = @as(f32, @floatFromInt(new_height)) / @as(f32, @floatFromInt(body.height));
        heights[i] = new_height;
        widths[i] = roundF32ToI32(scale_ratio * @as(f32, @floatFromInt(body.width)));
        tops[i] = -unit_height + heights[i];
        head_heights[i] = roundF32ToI32(scale_ratio * @as(f32, @floatFromInt(body.head_height)));
        body_width += widths[i];
    }

    var zoom_factor: f64 = 1.0;
    if (body_width > unit_width) {
        const reduction = @as(f32, @floatFromInt(unit_width)) / @as(f32, @floatFromInt(body_width));
        body_width = 0;
        for (ordered, 0..) |_, i| {
            heights[i] = roundF32ToI32(@as(f32, @floatFromInt(heights[i])) * reduction);
            widths[i] = roundF32ToI32(@as(f32, @floatFromInt(widths[i])) * reduction);
            tops[i] = -unit_height + heights[i];
            body_width += widths[i];
        }
    } else if (!establishing and !anyKeepRecognizable(bodies)) {
        zoom_factor = @as(f64, @floatFromInt(unit_width)) / @as(f64, @floatFromInt(body_width));
        var max_head_height: i32 = 0;
        for (ordered, 0..) |_, i| max_head_height = @max(max_head_height, head_heights[i]);
        const head_factor = @as(f64, @floatFromInt(max_body_height)) /
            (@as(f64, @floatFromInt(max_head_height)) * 1.2);
        zoom_factor = @min(zoom_factor, head_factor);
        if (zoom_factor < 1.1) zoom_factor = 1.0;

        body_width = 0;
        for (ordered, 0..) |_, i| {
            heights[i] = roundToI32(@as(f64, @floatFromInt(heights[i])) * zoom_factor);
            widths[i] = roundToI32(@as(f64, @floatFromInt(widths[i])) * zoom_factor);
            body_width += widths[i];
        }
    }

    const placements = try gpa.alloc(Placement, ordered.len);
    const margin = @divTrunc(unit_width - body_width, @as(i32, @intCast(ordered.len + 1)));
    var x_offset = margin;
    for (ordered, 0..) |entry, i| {
        const original_top = tops[i];
        const rect = Rect{
            .x = x_offset,
            .y = -original_top,
            .w = widths[i],
            .h = heights[i],
        };
        const arrow_x = rect.x + roundToI32(arrow_fractions[i] * @as(f64, @floatFromInt(rect.w)));
        placements[i] = .{
            .body_index = entry.body_index,
            .rect = rect,
            .flipped = entry.flipped,
            .arrow_x = arrow_x,
            .history = .{
                .last_dir = entry.flipped,
                // These names preserve the original CAvatarX field semantics,
                // including its historical left/right naming inversion.
                .last_right = if (i > 0)
                    bodies[ordered[i - 1].body_index].id
                else
                    bodies[entry.body_index].history.last_right,
                .last_left = if (i + 1 < ordered.len)
                    bodies[ordered[i + 1].body_index].id
                else
                    bodies[entry.body_index].history.last_left,
            },
        };
        x_offset += widths[i] + margin;
    }
    if (anyKeepRecognizable(bodies)) {
        for (placements) |*placement| {
            if (bodies[placement.body_index].keep_recognizable)
                containRecognizableDest(&placement.rect, unit_height);
        }
    }
    // Direct port of `AdjustArtToCoord(-unitHeight + maxBodyHeight,
    // zoomFactor)`, panel.cpp:946-956. `SetBBox` takes left,bottom,right,top.
    const fixed_y = -unit_height + max_body_height;
    const log_height = roundToI32(@as(f64, @floatFromInt(unit_height)) / zoom_factor);
    const log_width = roundToI32(@as(f64, @floatFromInt(unit_width)) / zoom_factor);
    const new_fixed_y = roundToI32(@as(f64, @floatFromInt(fixed_y)) / zoom_factor);
    const delta = fixed_y - new_fixed_y;
    return .{
        .placements = placements,
        .art_bbox = .{ .left = 0, .bottom = -log_height + delta, .right = log_width, .top = delta },
        .zoom_factor = zoom_factor,
    };
}

fn anyKeepRecognizable(bodies: []const Body) bool {
    for (bodies) |body| if (body.keep_recognizable) return true;
    return false;
}

/// Paper between heels and the panel bezel. Source dests sit on the 2300-unit
/// ground line; a generated standing card then reads as mid-thigh / feet-kiss.
fn recognizableGroundInset(unit_height: i32) i32 {
    return @max(120, @divTrunc(unit_height, 16));
}

/// Keep `speaker_box.top + 200` balloon tails inside the panel and leave
/// empty panel above a generated standing dest so a 2-line balloon sits
/// above the face. Taller balloons call `nudgeRecognizableDestBelow`.
/// Testdata dests do not use this.
fn recognizableHeadroom(unit_height: i32) i32 {
    return @max(900, @divTrunc(unit_height * 2, 5));
}

/// Slide a generated standing dest down so its head starts below `clear_above`
/// (top-down). Used after balloon layout so a 3-line cloud does not cover the
/// face. Testdata dests are never passed here.
pub fn nudgeRecognizableDestBelow(rect: *Rect, clear_above: i32, unit_height: i32) void {
    if (unit_height <= 0) return;
    const inset = recognizableGroundInset(unit_height);
    const max_bottom = unit_height - inset;
    if (max_bottom <= 0) return;
    if (clear_above <= rect.y) return;

    // Prefer dest.y >= clear_above even when that shrinks the card below
    // dest min-height. Snapping back to min_h puts the face under the cloud.
    if (clear_above < max_bottom) {
        rect.y = clear_above;
        rect.h = @max(1, max_bottom - rect.y);
        return;
    }

    // Balloon reaches the ground line. Keep a standing sliver so a later
    // Color balloon lift can recover the face.
    const min_h = @max(@divTrunc(unit_height, 3), 1);
    rect.h = @min(min_h, max_bottom);
    rect.y = max_bottom - rect.h;
}

/// Taller than `unit_height/1.9` so a standing Color card fills most of the
/// 315px panel instead of a waist-cut sliver on the ground line.
fn recognizableStandingHeight(unit_height: i32) i32 {
    const standing = unit_height - recognizableGroundInset(unit_height) - recognizableHeadroom(unit_height);
    const source_cap: i32 = @intFromFloat(@as(f64, @floatFromInt(unit_height)) / 1.9);
    return @max(source_cap, standing);
}

/// Keep a generated standing dest inside the visible panel with margin so the
/// full silhouette (head through heels) is not cropped to the ground line.
fn containRecognizableDest(rect: *Rect, unit_height: i32) void {
    if (unit_height <= 0) return;
    const inset = recognizableGroundInset(unit_height);
    const headroom = recognizableHeadroom(unit_height);
    const max_h = @max(1, unit_height - inset - headroom);
    if (rect.h > max_h) rect.h = max_h;
    if (rect.y < headroom) rect.y = headroom;
    if (rect.y + rect.h > unit_height - inset) {
        rect.y = unit_height - inset - rect.h;
        if (rect.y < headroom) {
            rect.y = headroom;
            rect.h = max_h;
        }
    }
    if (rect.h < 1) rect.h = 1;
}

/// Port of `AddTalkTos`: starting with requested speakers, append addressed
/// avatars from the available roster, without duplicates, up to the original
/// five-body cap. The returned Body values borrow their relationship slices.
pub fn addTalkTos(
    gpa: std.mem.Allocator,
    speakers: []const Body,
    available: []const Body,
) std.mem.Allocator.Error![]Body {
    const capacity = @min(max_bodies_per_panel, speakers.len + available.len);
    const expanded = try gpa.alloc(Body, capacity);
    var count = @min(speakers.len, max_bodies_per_panel);
    @memcpy(expanded[0..count], speakers[0..count]);
    const initial_count = count;
    for (expanded[0..initial_count]) |speaker| {
        for (speaker.talk_to_ids) |target_id| {
            if (count >= max_bodies_per_panel) return gpa.realloc(expanded, count);
            var duplicate = false;
            for (expanded[0..count]) |present| {
                if (present.id == target_id) {
                    duplicate = true;
                    break;
                }
            }
            if (duplicate) continue;
            for (available) |candidate| {
                if (candidate.id != target_id) continue;
                expanded[count] = candidate;
                count += 1;
                break;
            }
        }
    }
    return gpa.realloc(expanded, count);
}

fn greedyOrder(gpa: std.mem.Allocator, bodies: []const Body) ![]Working {
    const placed = try gpa.alloc(Working, bodies.len);
    var placed_len: usize = 0;
    for (bodies, 0..) |_, body_index| {
        var best_rating: i32 = std.math.maxInt(i32);
        var best_position: usize = 0;
        var best_dir = bodies[body_index].history.last_dir;
        var position: usize = 0;
        while (position <= placed_len) : (position += 1) {
            const result = evaluatePlacement(bodies, placed[0..placed_len], body_index, position);
            if (result.rating < best_rating) {
                best_rating = result.rating;
                best_position = position;
                best_dir = result.flipped;
            }
        }
        std.mem.copyBackwards(Working, placed[best_position + 1 .. placed_len + 1], placed[best_position..placed_len]);
        placed[best_position] = .{ .body_index = body_index, .flipped = best_dir };
        placed_len += 1;
    }
    return placed;
}

const Evaluation = struct { rating: i32, flipped: bool };

fn evaluatePlacement(bodies: []const Body, placed: []const Working, body_index: usize, position: usize) Evaluation {
    var candidate: [max_bodies_per_panel]Working = undefined;
    @memcpy(candidate[0..position], placed[0..position]);
    @memcpy(candidate[position + 1 .. placed.len + 1], placed[position..]);

    candidate[position] = .{ .body_index = body_index, .flipped = false };
    const rating_right = evaluateOrder(bodies, candidate[0 .. placed.len + 1]);
    candidate[position].flipped = true;
    const rating_left = evaluateOrder(bodies, candidate[0 .. placed.len + 1]);

    if (rating_right < rating_left) return .{ .rating = rating_right, .flipped = false };
    if (rating_right > rating_left) return .{ .rating = rating_left, .flipped = true };
    return .{ .rating = rating_right, .flipped = bodies[body_index].history.last_dir };
}

fn evaluateOrder(bodies: []const Body, ordered: []const Working) i32 {
    var rating = displacementPenalty(bodies, ordered);
    for (ordered, 0..) |first, i| {
        for (ordered[i + 1 ..], i + 1..) |second, j| {
            rating += evalPair(bodies, first, second, @intCast(j - i));
            rating += evalPair(bodies, second, first, -@as(i32, @intCast(j - i)));
        }
    }
    return rating;
}

fn displacementPenalty(bodies: []const Body, ordered: []const Working) i32 {
    var penalty: i32 = 0;
    for (ordered, 0..) |entry, i| {
        const body = bodies[entry.body_index];
        if (i > 0 and body.history.last_right != bodies[ordered[i - 1].body_index].id) penalty += 1;
        if (i + 1 < ordered.len and body.history.last_left != bodies[ordered[i + 1].body_index].id) penalty += 1;
    }
    return penalty;
}

fn evalPair(bodies: []const Body, first: Working, second: Working, delta_placement_in: i32) i32 {
    var delta_placement = delta_placement_in;
    const desired_dir = if (delta_placement > 0) false else direction: {
        delta_placement = -delta_placement;
        break :direction true;
    };

    var rating: i32 = 0;
    const first_body = bodies[first.body_index];
    if (first_body.talk_to_ids.len == 0) {
        if (first.flipped != desired_dir) rating += 4;
        if (second.flipped == desired_dir) rating += 2;
    } else if (containsId(first_body.talk_to_ids, bodies[second.body_index].id)) {
        if (first.flipped == desired_dir)
            rating += 4 * (delta_placement - 1)
        else
            rating += 40;
        if (second.flipped == desired_dir) rating += 4;
    }
    return rating;
}

fn containsId(ids: []const u32, id: u32) bool {
    for (ids) |candidate| if (candidate == id) return true;
    return false;
}

fn roundToI32(value: f64) i32 {
    return @intFromFloat(@round(value));
}

fn roundF32ToI32(value: f32) i32 {
    return @intFromFloat(@round(value));
}

/// Exact `CUnitPanelPage::AddLine` preflight condition. The actual source then
/// clones the prior panel and accepts it only when balloon layout succeeds.
pub fn mustStartNewPanel(
    forced: bool,
    existing_panel_count_including_title: usize,
    current_element_count: usize,
    speaker_already_present: bool,
) bool {
    return forced or current_element_count >= 5 or
        existing_panel_count_including_title < 2 or speaker_already_present;
}

test "Anna Color continuation layout keeps zoom at 1" {
    const gpa = std.testing.allocator;
    const color = @embedFile("../assets/generated/anna-color-hd-v1.avb");
    var assembled = try @import("figure.zig").assembleDetailedForText(gpa, color, "much clearer now.");
    defer assembled.deinit(gpa);
    try std.testing.expect(assembled.generated_standing);
    const bodies = [_]Body{.{
        .id = 1,
        .width = @intCast(assembled.image.width),
        .height = @intCast(assembled.image.height),
        .head_height = assembled.head_height,
        .face_x = assembled.face_x,
        .keep_recognizable = assembled.generated_standing,
    }};
    var scene = try layoutScene(gpa, &bodies, default_unit_width, default_unit_height, false);
    defer scene.deinit(gpa);
    try std.testing.expectEqual(@as(f64, 1.0), scene.zoom_factor);
    const dest = scene.placements[0].rect;
    try std.testing.expect(dest.y >= recognizableHeadroom(default_unit_height));
    try std.testing.expect(dest.y + dest.h <= default_unit_height - recognizableGroundInset(default_unit_height));
    try std.testing.expect(dest.h >= recognizableStandingHeight(default_unit_height) - 8);
}

test "generated standing figures skip the source zoom-in branch" {
    const gpa = std.testing.allocator;
    const zoomed = [_]Body{.{
        .id = 11,
        .width = 100,
        .height = 200,
        .norm_height = 100,
        .head_height = 90,
        .face_x = 25,
    }};
    const kept = [_]Body{.{
        .id = 11,
        .width = 100,
        .height = 200,
        .norm_height = 100,
        .head_height = 90,
        .face_x = 25,
        .keep_recognizable = true,
    }};
    var scene_zoom = try layoutScene(gpa, &zoomed, default_unit_width, default_unit_height, false);
    defer scene_zoom.deinit(gpa);
    var scene_keep = try layoutScene(gpa, &kept, default_unit_width, default_unit_height, false);
    defer scene_keep.deinit(gpa);
    try std.testing.expect(scene_zoom.zoom_factor > 1.1);
    try std.testing.expectEqual(@as(f64, 1.0), scene_keep.zoom_factor);
    try std.testing.expect(scene_keep.placements[0].rect.h < scene_zoom.placements[0].rect.h);
    const keep = scene_keep.placements[0].rect;
    try std.testing.expect(keep.y >= recognizableHeadroom(default_unit_height));
    try std.testing.expect(keep.y + keep.h <= default_unit_height - recognizableGroundInset(default_unit_height));
    try std.testing.expect(keep.h >= recognizableStandingHeight(default_unit_height) - 8);
}

test "containRecognizableDest pulls an oversized feet crop back into the panel" {
    var feet = Rect{ .x = 100, .y = -800, .w = 400, .h = 4000 };
    containRecognizableDest(&feet, default_unit_height);
    try std.testing.expectEqual(recognizableHeadroom(default_unit_height), feet.y);
    try std.testing.expectEqual(recognizableStandingHeight(default_unit_height), feet.h);
    try std.testing.expect(feet.y + feet.h < default_unit_height);
}

test "nudgeRecognizableDestBelow slides a standing dest under a tall balloon" {
    var dest = Rect{ .x = 100, .y = 400, .w = 500, .h = 1600 };
    nudgeRecognizableDestBelow(&dest, 1100, default_unit_height);
    try std.testing.expectEqual(@as(i32, 1100), dest.y);
    try std.testing.expect(dest.y + dest.h <= default_unit_height - recognizableGroundInset(default_unit_height));
    try std.testing.expect(dest.h >= @divTrunc(default_unit_height, 3));
}

test "nudgeRecognizableDestBelow does not snap dest back under a panel-height balloon" {
    var dest = Rect{ .x = 100, .y = 400, .w = 500, .h = 1600 };
    nudgeRecognizableDestBelow(&dest, 2200, default_unit_height);
    try std.testing.expect(dest.y > 1200);
    try std.testing.expect(dest.y + dest.h <= default_unit_height - recognizableGroundInset(default_unit_height));
    try std.testing.expect(dest.h >= @divTrunc(default_unit_height, 3));
}

test "source AddLine preflight preserves title-panel and repeat-speaker rules" {
    try std.testing.expect(mustStartNewPanel(false, 1, 0, false));
    try std.testing.expect(!mustStartNewPanel(false, 2, 1, false));
    try std.testing.expect(mustStartNewPanel(false, 2, 5, false));
    try std.testing.expect(mustStartNewPanel(false, 2, 1, true));
    try std.testing.expect(mustStartNewPanel(true, 8, 1, false));
}

test "source greedy ordering faces two world speakers toward one another" {
    const gpa = std.testing.allocator;
    const bodies = [_]Body{
        .{ .id = 1, .width = 100, .height = 200, .head_height = 90, .face_x = 50 },
        .{ .id = 2, .width = 100, .height = 200, .head_height = 90, .face_x = 50 },
    };
    const placed = try layoutAvatars(gpa, &bodies, default_unit_width, default_unit_height, false);
    defer gpa.free(placed);
    try std.testing.expectEqual(@as(usize, 2), placed.len);
    try std.testing.expect(!placed[0].flipped);
    try std.testing.expect(placed[1].flipped);
    try std.testing.expect(placed[0].rect.x < placed[1].rect.x);
}

test "source avatar scaling preserves equal margins and max height formula" {
    const gpa = std.testing.allocator;
    const bodies = [_]Body{
        .{ .id = 1, .width = 80, .height = 200, .head_height = 90, .face_x = 30 },
        .{ .id = 2, .width = 120, .height = 240, .head_height = 100, .face_x = 70 },
        .{ .id = 3, .width = 90, .height = 210, .head_height = 95, .face_x = 45 },
    };
    const placed = try layoutAvatars(gpa, &bodies, default_unit_width, default_unit_height, true);
    defer gpa.free(placed);
    try std.testing.expectEqual(@as(usize, 3), placed.len);
    const margin = placed[0].rect.x;
    try std.testing.expect(margin >= 0);
    try std.testing.expectEqual(
        margin,
        placed[1].rect.x - (placed[0].rect.x + placed[0].rect.w),
    );
    try std.testing.expectEqual(
        margin,
        placed[2].rect.x - (placed[1].rect.x + placed[1].rect.w),
    );
}

test "source layout rejects invalid bodies and original five-body cap" {
    const gpa = std.testing.allocator;
    const bad = [_]Body{.{ .id = 1, .width = 0, .height = 2, .head_height = 1, .face_x = 0 }};
    try std.testing.expectError(error.InvalidBody, layoutAvatars(gpa, &bad, 2300, 2300, false));
    const too_many = [_]Body{
        .{ .id = 1, .width = 1, .height = 2, .head_height = 1, .face_x = 0 },
        .{ .id = 2, .width = 1, .height = 2, .head_height = 1, .face_x = 0 },
        .{ .id = 3, .width = 1, .height = 2, .head_height = 1, .face_x = 0 },
        .{ .id = 4, .width = 1, .height = 2, .head_height = 1, .face_x = 0 },
        .{ .id = 5, .width = 1, .height = 2, .head_height = 1, .face_x = 0 },
        .{ .id = 6, .width = 1, .height = 2, .head_height = 1, .face_x = 0 },
    };
    try std.testing.expectError(error.TooManyBodies, layoutAvatars(gpa, &too_many, 2300, 2300, false));
}

test "source AddTalkTos appends addressed bodies once and preserves edge history" {
    const gpa = std.testing.allocator;
    const targets = [_]u32{ 2, 3, 2 };
    const speakers = [_]Body{.{
        .id = 1,
        .width = 100,
        .height = 200,
        .head_height = 90,
        .face_x = 50,
        .talk_to_ids = &targets,
        .history = .{ .last_right = 77, .last_left = 88 },
    }};
    const available = [_]Body{
        .{ .id = 2, .width = 100, .height = 200, .head_height = 90, .face_x = 50 },
        .{ .id = 3, .width = 100, .height = 200, .head_height = 90, .face_x = 50 },
    };
    const expanded = try addTalkTos(gpa, &speakers, &available);
    defer gpa.free(expanded);
    try std.testing.expectEqual(@as(usize, 3), expanded.len);

    const single = try layoutAvatars(gpa, &speakers, default_unit_width, default_unit_height, true);
    defer gpa.free(single);
    try std.testing.expectEqual(@as(u32, 77), single[0].history.last_right);
    try std.testing.expectEqual(@as(u32, 88), single[0].history.last_left);
}
