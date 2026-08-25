//! Source-faithful Comic Chat 2.5 figure drawing.
//!
//! The released client did not alpha-composite a preassembled character.  It
//! stretched each aura, mask, and drawing directly onto the panel DC with
//! `MERGEPAINT` and `SRCAND` (`bodycam.cpp:524-573`).  That distinction matters:
//! the white sticker is made from the backdrop itself, and `TORSOFIRST`,
//! `HEADMASK`, and `TORSOMASK` change the result in overlapping regions.
//!
//! This module keeps those operations platform-neutral.  Its public low-level
//! entry points accept the existing `bgb.Image` type, while `drawSelection` and
//! `drawForText` decode the authored AVB image plans.  Packed two-bit mask
//! resources are separated here because `CPose::ConvertMasksCommon` needs their
//! individual low/high/any-bit planes; a flattened RGBA decode has already lost
//! that information.

const std = @import("std");
const flate = std.compress.flate;
const avb = @import("../assets/avb.zig");
const bgb = @import("../assets/bgb.zig");
const emotion = @import("emotion.zig");
const source_figure = @import("figure.zig");
const udi = @import("../proto/udi.zig");
const balloon = @import("original_balloon.zig");
const raster = @import("original_raster.zig");
const Canvas = @import("../render/canvas.zig").Canvas;

pub const Image = bgb.Image;

pub const Rect = struct {
    x: i32,
    y: i32,
    w: i32,
    h: i32,
};

/// Borrowed pose layers.  The caller retains ownership of every image.
pub const PoseLayers = struct {
    drawing: Image,
    mask: ?Image = null,
    aura: ?Image = null,
};

pub const Options = struct {
    client: Rect,
    flipped: bool = false,
    draw_aura: bool = true,
};

/// Original y-up panel rectangle.  Keeping this as the balloon/layout type
/// prevents an intermediate device-space body box from changing bodycam's
/// ROUND and component `+1` decisions.
pub const LogicalRect = balloon.Rect;

pub const LogicalOptions = struct {
    client: LogicalRect,
    transform: raster.Transform,
    flipped: bool = false,
    draw_aura: bool = true,
};

/// Rectangles corresponding to `fullRect`, `headRect`, and `torsoRect` in
/// bodycam.cpp.  `head` is null for a simple/whole-body avatar.
pub const Geometry = struct {
    full: Rect,
    head: ?Rect,
    torso: Rect,
};

/// The exact RECT values produced by bodycam.cpp before the panel DC maps them
/// to pixels.  Flipped component rectangles intentionally have left > right,
/// just like the negative StretchDIBits widths in the released client.
pub const LogicalGeometry = struct {
    full: LogicalRect,
    head: ?LogicalRect,
    torso: LogicalRect,
};

pub const TransformedGeometry = struct {
    logical: LogicalGeometry,
    device: Geometry,
};

/// Explicit AVB selectors.  Nine is the source neutral emotion record.
pub const Selection = struct {
    face_emotion: u16 = 9,
    face_intensity: u8 = 0,
    torso_emotion: u16 = 9,
    torso_intensity: u8 = 0,
    body_emotion: u16 = 9,
    body_intensity: u8 = 0,
};

pub const Error = bgb.Error || error{
    InvalidDestination,
    InvalidImage,
    MissingImage,
};

pub const RasterOp = enum { merge_paint, merge_paint_sticker, src_and, src_copy_keyed };

/// Cross-platform equivalent of the source's `StretchDIBits` calls.  Sampling
/// uses an area filter, preserving the coverage/color averaging expected from
/// `STRETCH_HALFTONE` instead of the nearest-neighbour artifacts of the sketch
/// renderer.  ROPs are then applied to the actual destination RGB value.
pub fn stretchRop(canvas: *Canvas, source: Image, destination: Rect, flipped: bool, op: RasterOp) Error!void {
    if (source.width == 0 or source.height == 0 or
        source.pixels.len != @as(usize, source.width) * source.height)
        return error.InvalidImage;
    if (destination.w <= 0 or destination.h <= 0) return error.InvalidDestination;

    var y: i32 = 0;
    while (y < destination.h) : (y += 1) {
        const out_y = destination.y + y;
        if (out_y < 0 or out_y >= @as(i32, @intCast(canvas.height))) continue;
        var x: i32 = 0;
        while (x < destination.w) : (x += 1) {
            const out_x = destination.x + x;
            if (out_x < 0 or out_x >= @as(i32, @intCast(canvas.width))) continue;
            const sampled = areaSample(source, x, y, destination.w, destination.h, flipped);
            const index = @as(usize, @intCast(out_y)) * canvas.width + @as(usize, @intCast(out_x));
            const old = canvas.px[index];
            // Windows GDI's bitmap ROPs do not have an alpha channel.  Retain
            // the Canvas destination alpha and apply the exact RGB truth table.
            canvas.px[index] = (old & 0xff000000) | switch (op) {
                .src_and => (old & sampled) & 0x00ffffff,
                .src_copy_keyed => if (stickerInk(sampled)) sampled & 0x00ffffff else old & 0x00ffffff,
                .merge_paint => (old | ~sampled) & 0x00ffffff,
                .merge_paint_sticker => blk: {
                    const sticker: u32 = if (stickerInk(sampled)) 0x00000000 else 0x00ffffff;
                    break :blk (old | ~sticker) & 0x00ffffff;
                },
            };
        }
    }
}

/// Port of `CBodyDouble::GetBodyBox`, `FlipBodyBox`, and `DrawBody`.
pub fn drawComplex(
    canvas: *Canvas,
    head: PoseLayers,
    torso: PoseLayers,
    anchors: bgb.NeckAnchors,
    flags: avb.AvatarFlags,
    options: Options,
) Error!Geometry {
    try validateOptions(options);
    try validateImage(head.drawing);
    try validateImage(torso.drawing);

    const x_offset = anchors.body.x - anchors.head.x;
    const y_offset = anchors.body.y - anchors.head.y;
    const head_w: i32 = @intCast(head.drawing.width);
    const head_h: i32 = @intCast(head.drawing.height);
    const torso_w: i32 = @intCast(torso.drawing.width);
    const torso_h: i32 = @intCast(torso.drawing.height);
    const bit_left = @min(@as(i32, 0), x_offset);
    const bit_top = @min(@as(i32, 0), y_offset);
    const bit_right = @max(torso_w, x_offset + head_w);
    const bit_bottom = @max(torso_h, y_offset + head_h);
    const bit_width = bit_right - bit_left;
    const bit_height = bit_bottom - bit_top;
    if (bit_width <= 0 or bit_height <= 0) return error.InvalidImage;

    const width_scale = @as(f64, @floatFromInt(options.client.w)) / @as(f64, @floatFromInt(bit_width));
    const height_scale = @as(f64, @floatFromInt(options.client.h)) / @as(f64, @floatFromInt(bit_height));
    const scale = @min(width_scale, height_scale);
    const full_w = roundSource(scale * @as(f64, @floatFromInt(bit_width)));
    const full_h = roundSource(scale * @as(f64, @floatFromInt(bit_height)));
    const full = Rect{
        .x = options.client.x + @divTrunc(options.client.w - full_w, 2),
        .y = options.client.y + options.client.h - full_h,
        .w = full_w,
        .h = full_h,
    };

    var head_rect = Rect{
        .x = full.x + roundSource(@as(f64, @floatFromInt(x_offset - bit_left)) * scale),
        .y = full.y + roundSource(@as(f64, @floatFromInt(y_offset - bit_top)) * scale),
        // The source deliberately adds one after scaling each component.
        .w = roundSource(@as(f64, @floatFromInt(head_w)) * scale) + 1,
        .h = roundSource(@as(f64, @floatFromInt(head_h)) * scale) + 1,
    };
    var torso_rect = Rect{
        .x = full.x + roundSource(@as(f64, @floatFromInt(-bit_left)) * scale),
        .y = full.y + roundSource(@as(f64, @floatFromInt(-bit_top)) * scale),
        .w = roundSource(@as(f64, @floatFromInt(torso_w)) * scale) + 1,
        .h = roundSource(@as(f64, @floatFromInt(torso_h)) * scale) + 1,
    };
    if (options.flipped) {
        head_rect.x = full.x + full.w - (head_rect.x - full.x) - head_rect.w;
        torso_rect.x = full.x + full.w - (torso_rect.x - full.x) - torso_rect.w;
    }

    // bodycam.cpp draws both nimbuses before either body component.
    if (options.draw_aura) {
        if (torso.aura) |layer| try stretchRop(canvas, layer, torso_rect, options.flipped, .merge_paint);
        if (head.aura) |layer| try stretchRop(canvas, layer, head_rect, options.flipped, .merge_paint);
    }

    if (flags.torso_first)
        try drawTorso(canvas, torso, torso_rect, flags.torso_mask, options.flipped);

    if (flags.head_mask) {
        if (head.mask) |layer| try stretchRop(canvas, layer, head_rect, options.flipped, .merge_paint);
    }
    try stretchRop(canvas, head.drawing, head_rect, options.flipped, .src_and);

    if (!flags.torso_first)
        try drawTorso(canvas, torso, torso_rect, flags.torso_mask, options.flipped);

    return .{ .full = full, .head = head_rect, .torso = torso_rect };
}

/// Port of `CBodySingle::GetBodyBox`, `FlipBodyBox`, and `DrawBody`.
pub fn drawSingle(canvas: *Canvas, pose: PoseLayers, options: Options) Error!Geometry {
    try validateOptions(options);
    try validateImage(pose.drawing);
    const source_w: i32 = @intCast(pose.drawing.width);
    const source_h: i32 = @intCast(pose.drawing.height);
    const width_scale = @as(f64, @floatFromInt(options.client.w)) / @as(f64, @floatFromInt(source_w));
    const height_scale = @as(f64, @floatFromInt(options.client.h)) / @as(f64, @floatFromInt(source_h));

    var full_w: i32 = undefined;
    var full_h: i32 = undefined;
    if (width_scale <= height_scale) {
        full_w = options.client.w;
        // CBodySingle uses a cast, not ROUND.
        full_h = @intFromFloat(width_scale * @as(f64, @floatFromInt(source_h)));
    } else {
        full_h = options.client.h;
        full_w = @intFromFloat(height_scale * @as(f64, @floatFromInt(source_w)));
    }
    const full = Rect{
        .x = options.client.x + @divTrunc(options.client.w - full_w, 2),
        .y = options.client.y + options.client.h - full_h,
        .w = full_w,
        .h = full_h,
    };
    try paintKeyedBody(canvas, pose, full, options.flipped, options.draw_aura);
    return .{ .full = full, .head = null, .torso = full };
}

/// Logical-coordinate counterpart to `drawComplex`.  This follows
/// `CBodyDouble::GetBodyBox` and `FlipBodyBox` while the rectangles are still
/// panel units, then maps each completed rectangle once at the raster boundary.
pub fn drawComplexLogical(
    canvas: *Canvas,
    head: PoseLayers,
    torso: PoseLayers,
    anchors: bgb.NeckAnchors,
    flags: avb.AvatarFlags,
    options: LogicalOptions,
) Error!TransformedGeometry {
    try validateLogicalOptions(options);
    try validateImage(head.drawing);
    try validateImage(torso.drawing);

    const logical = try complexLogicalGeometry(head.drawing, torso.drawing, anchors, options);
    const device = try mapLogicalGeometry(logical, options.transform);
    const head_rect = device.head.?;

    // bodycam.cpp draws both nimbuses before either body component.
    if (options.draw_aura) {
        if (torso.aura) |layer| try stretchRop(canvas, layer, device.torso, options.flipped, .merge_paint);
        if (head.aura) |layer| try stretchRop(canvas, layer, head_rect, options.flipped, .merge_paint);
    }

    if (flags.torso_first)
        try drawTorso(canvas, torso, device.torso, flags.torso_mask, options.flipped);

    if (flags.head_mask) {
        if (head.mask) |layer| try stretchRop(canvas, layer, head_rect, options.flipped, .merge_paint);
    }
    try stretchRop(canvas, head.drawing, head_rect, options.flipped, .src_and);

    if (!flags.torso_first)
        try drawTorso(canvas, torso, device.torso, flags.torso_mask, options.flipped);

    return .{ .logical = logical, .device = device };
}

/// Logical-coordinate counterpart to `drawSingle`.  A source flip swaps the
/// logical left/right edges before their one device mapping, reproducing the
/// negative destination width passed to StretchDIBits.
pub fn drawSingleLogical(canvas: *Canvas, pose: PoseLayers, options: LogicalOptions) Error!TransformedGeometry {
    try validateLogicalOptions(options);
    try validateImage(pose.drawing);

    const logical = try singleLogicalGeometry(pose.drawing, options);
    const device = try mapLogicalGeometry(logical, options.transform);
    try paintKeyedBody(canvas, pose, device.full, options.flipped, options.draw_aura);
    return .{ .logical = logical, .device = device };
}

/// Decode and draw explicit source emotion records into an existing panel.
pub fn drawSelection(
    gpa: std.mem.Allocator,
    canvas: *Canvas,
    avb_data: []const u8,
    selection: Selection,
    options: Options,
) !Geometry {
    const asset = try avb.parse(avb_data);
    var table = try avb.parsePoseTable(gpa, avb_data);
    defer table.deinit(gpa);

    if (asset.kind == .simple_avatar) {
        const record = bgb.selectPose(table.records, .body, selection.body_emotion, selection.body_intensity) orelse
            return error.MissingImage;
        var pose = try loadPose(gpa, avb_data, record.*, false, options.draw_aura);
        defer pose.deinit(gpa);
        return drawSingle(canvas, pose.borrow(), options);
    }

    const face = bgb.selectPose(table.records, .face, selection.face_emotion, selection.face_intensity) orelse
        return error.MissingImage;
    const torso = bgb.selectPose(table.records, .torso, selection.torso_emotion, selection.torso_intensity) orelse
        return error.MissingImage;
    var head_pose = try loadPose(gpa, avb_data, face.*, asset.flags.head_mask, options.draw_aura);
    defer head_pose.deinit(gpa);
    var torso_pose = try loadPose(gpa, avb_data, torso.*, asset.flags.torso_mask, options.draw_aura);
    defer torso_pose.deinit(gpa);
    return drawComplex(canvas, head_pose.borrow(), torso_pose.borrow(), .{
        .head = .{
            .x = @as(i32, face.center.x) - face.delta.x,
            .y = @as(i32, face.center.y) - face.delta.y,
        },
        .body = .{ .x = torso.center.x, .y = torso.center.y },
    }, asset.flags, options);
}

/// Decode explicit source emotion records and retain logical bodycam geometry
/// until the final panel transform.
pub fn drawSelectionLogical(
    gpa: std.mem.Allocator,
    canvas: *Canvas,
    avb_data: []const u8,
    selection: Selection,
    options: LogicalOptions,
) !TransformedGeometry {
    const asset = try avb.parse(avb_data);
    var table = try avb.parsePoseTable(gpa, avb_data);
    defer table.deinit(gpa);

    if (asset.kind == .simple_avatar) {
        const record = bgb.selectPose(table.records, .body, selection.body_emotion, selection.body_intensity) orelse
            return error.MissingImage;
        var pose = try loadPose(gpa, avb_data, record.*, false, options.draw_aura);
        defer pose.deinit(gpa);
        return drawSingleLogical(canvas, pose.borrow(), options);
    }

    const face = bgb.selectPose(table.records, .face, selection.face_emotion, selection.face_intensity) orelse
        return error.MissingImage;
    const torso = bgb.selectPose(table.records, .torso, selection.torso_emotion, selection.torso_intensity) orelse
        return error.MissingImage;
    var head_pose = try loadPose(gpa, avb_data, face.*, asset.flags.head_mask, options.draw_aura);
    defer head_pose.deinit(gpa);
    var torso_pose = try loadPose(gpa, avb_data, torso.*, asset.flags.torso_mask, options.draw_aura);
    defer torso_pose.deinit(gpa);
    return drawComplexLogical(canvas, head_pose.borrow(), torso_pose.borrow(), .{
        .head = .{
            .x = @as(i32, face.center.x) - face.delta.x,
            .y = @as(i32, face.center.y) - face.delta.y,
        },
        .body = .{ .x = torso.center.x, .y = torso.center.y },
    }, asset.flags, options);
}

/// Draw the exact cooked UDI pose selected by the released `SayEntry` path.
/// This is intentionally separate from `drawForText`: ordinary AVBs use raw
/// face/torso/body record ordinals, while OTHERMAPPED assets use the serialized
/// emotion and intensity fields.
pub fn drawSourcePose(
    gpa: std.mem.Allocator,
    canvas: *Canvas,
    avb_data: []const u8,
    pose: udi.PoseState,
    options: Options,
) !Geometry {
    const asset = try avb.parse(avb_data);
    var table = try avb.parsePoseTable(gpa, avb_data);
    defer table.deinit(gpa);
    const selected = source_figure.selectSourcePose(table.records, asset.kind, asset.flags.other_mapped, pose);

    if (asset.kind == .simple_avatar) {
        const record = selected.body orelse return error.MissingImage;
        var loaded = try loadPose(gpa, avb_data, record.*, false, options.draw_aura);
        defer loaded.deinit(gpa);
        return drawSingle(canvas, loaded.borrow(), options);
    }
    const face = selected.face orelse return error.MissingImage;
    const torso = selected.torso orelse return error.MissingImage;
    var head_pose = try loadPose(gpa, avb_data, face.*, asset.flags.head_mask, options.draw_aura);
    defer head_pose.deinit(gpa);
    var torso_pose = try loadPose(gpa, avb_data, torso.*, asset.flags.torso_mask, options.draw_aura);
    defer torso_pose.deinit(gpa);
    return drawComplex(canvas, head_pose.borrow(), torso_pose.borrow(), .{
        .head = .{
            .x = @as(i32, face.center.x) - face.delta.x,
            .y = @as(i32, face.center.y) - face.delta.y,
        },
        .body = .{ .x = torso.center.x, .y = torso.center.y },
    }, asset.flags, options);
}

/// Logical-coordinate counterpart used by the page renderer so the selected
/// UDI pose still crosses the source's ROUND/+1 boundary exactly once.
pub fn drawSourcePoseLogical(
    gpa: std.mem.Allocator,
    canvas: *Canvas,
    avb_data: []const u8,
    pose: udi.PoseState,
    options: LogicalOptions,
) !TransformedGeometry {
    const asset = try avb.parse(avb_data);
    var table = try avb.parsePoseTable(gpa, avb_data);
    defer table.deinit(gpa);
    const selected = source_figure.selectSourcePose(table.records, asset.kind, asset.flags.other_mapped, pose);

    if (asset.kind == .simple_avatar) {
        const record = selected.body orelse return error.MissingImage;
        var loaded = try loadPose(gpa, avb_data, record.*, false, options.draw_aura);
        defer loaded.deinit(gpa);
        return drawSingleLogical(canvas, loaded.borrow(), options);
    }
    const face = selected.face orelse return error.MissingImage;
    const torso = selected.torso orelse return error.MissingImage;
    var head_pose = try loadPose(gpa, avb_data, face.*, asset.flags.head_mask, options.draw_aura);
    defer head_pose.deinit(gpa);
    var torso_pose = try loadPose(gpa, avb_data, torso.*, asset.flags.torso_mask, options.draw_aura);
    defer torso_pose.deinit(gpa);
    return drawComplexLogical(canvas, head_pose.borrow(), torso_pose.borrow(), .{
        .head = .{
            .x = @as(i32, face.center.x) - face.delta.x,
            .y = @as(i32, face.center.y) - face.delta.y,
        },
        .body = .{ .x = torso.center.x, .y = torso.center.y },
    }, asset.flags, options);
}

/// Use the same authored emotion analysis/selection policy as `figure.zig`, but
/// retain the separate pose layers until after the source drawing order.
pub fn drawForText(
    gpa: std.mem.Allocator,
    canvas: *Canvas,
    avb_data: []const u8,
    text: []const u8,
    options: Options,
) !Geometry {
    const analysis = emotion.analyzeText(text);
    var table = try avb.parsePoseTable(gpa, avb_data);
    defer table.deinit(gpa);
    const asset = try avb.parse(avb_data);

    if (asset.kind == .simple_avatar) {
        const choice = selectAvailable(table.records, &analysis, .body, null);
        return drawSelection(gpa, canvas, avb_data, .{
            .body_emotion = choice.emotion.assetIndex(),
            .body_intensity = choice.intensity,
        }, options);
    }
    const face = selectAvailable(table.records, &analysis, .face, false);
    const torso = selectAvailable(table.records, &analysis, .torso, true);
    return drawSelection(gpa, canvas, avb_data, .{
        .face_emotion = face.emotion.assetIndex(),
        .face_intensity = face.intensity,
        .torso_emotion = torso.emotion.assetIndex(),
        .torso_intensity = torso.intensity,
    }, options);
}

/// Transform-aware text entry point for panel rendering.  Unlike
/// `drawForText`, `options.client` is the original y-up body bbox.  Component
/// ROUND/+1/flip decisions happen there, and only the final rectangles cross
/// `options.transform` into device pixels.
pub fn drawForTextLogical(
    gpa: std.mem.Allocator,
    canvas: *Canvas,
    avb_data: []const u8,
    text: []const u8,
    options: LogicalOptions,
) !TransformedGeometry {
    const analysis = emotion.analyzeText(text);
    var table = try avb.parsePoseTable(gpa, avb_data);
    defer table.deinit(gpa);
    const asset = try avb.parse(avb_data);

    if (asset.kind == .simple_avatar) {
        const choice = selectAvailable(table.records, &analysis, .body, null);
        return drawSelectionLogical(gpa, canvas, avb_data, .{
            .body_emotion = choice.emotion.assetIndex(),
            .body_intensity = choice.intensity,
        }, options);
    }
    const face = selectAvailable(table.records, &analysis, .face, false);
    const torso = selectAvailable(table.records, &analysis, .torso, true);
    return drawSelectionLogical(gpa, canvas, avb_data, .{
        .face_emotion = face.emotion.assetIndex(),
        .face_intensity = face.intensity,
        .torso_emotion = torso.emotion.assetIndex(),
        .torso_intensity = torso.intensity,
    }, options);
}

fn selectAvailable(
    records: []const avb.PoseRecord,
    analysis: *const emotion.TextAnalysis,
    layer: avb.PoseLayer,
    gesture: ?bool,
) emotion.EmotionOption {
    var best: ?emotion.EmotionOption = null;
    for (analysis.slice()) |option| {
        if (gesture) |want_gesture| {
            if (option.emotion.isGesture() != want_gesture) continue;
        }
        if (bgb.selectPose(records, layer, option.emotion.assetIndex(), option.intensity) == null) continue;
        if (best == null or option.priority > best.?.priority) best = option;
    }
    return best orelse .{ .emotion = .neutral, .intensity = 0, .priority = 0 };
}

fn complexLogicalGeometry(
    head: Image,
    torso: Image,
    anchors: bgb.NeckAnchors,
    options: LogicalOptions,
) Error!LogicalGeometry {
    const x_offset = anchors.body.x - anchors.head.x;
    const y_offset = anchors.body.y - anchors.head.y;
    const head_w: i32 = @intCast(head.width);
    const head_h: i32 = @intCast(head.height);
    const torso_w: i32 = @intCast(torso.width);
    const torso_h: i32 = @intCast(torso.height);
    const bit_left = @min(@as(i32, 0), x_offset);
    const bit_top = @min(@as(i32, 0), y_offset);
    const bit_right = @max(torso_w, x_offset + head_w);
    const bit_bottom = @max(torso_h, y_offset + head_h);
    const bit_width = bit_right - bit_left;
    const bit_height = bit_bottom - bit_top;
    if (bit_width <= 0 or bit_height <= 0) return error.InvalidImage;

    const client = options.client;
    const height_sign: i32 = if (client.bottom > client.top) 1 else -1;
    const client_width = client.right - client.left;
    const client_height = height_sign * (client.bottom - client.top);
    const width_scale = @as(f64, @floatFromInt(client_width)) / @as(f64, @floatFromInt(bit_width));
    const height_scale = @as(f64, @floatFromInt(client_height)) / @as(f64, @floatFromInt(bit_height));
    const scale = @min(width_scale, height_scale);
    const full_width = roundSource(scale * @as(f64, @floatFromInt(bit_width)));
    const full_height = roundSource(scale * @as(f64, @floatFromInt(bit_height)));
    const full_left = client.left + @divTrunc(client_width - full_width, 2);
    const full_top = client.top + (client_height - full_height);
    const full = LogicalRect{
        .left = full_left,
        .top = full_top,
        .right = full_left + full_width,
        .bottom = full_top + height_sign * full_height,
    };

    var head_rect = LogicalRect{
        .left = full.left + roundSource(@as(f64, @floatFromInt(x_offset - bit_left)) * scale),
        .top = full.top + roundSource(@as(f64, @floatFromInt(y_offset - bit_top)) * scale),
        .right = undefined,
        .bottom = undefined,
    };
    // bodycam.cpp:649-657 adds one in logical coordinates after each ROUND.
    head_rect.right = head_rect.left + roundSource(@as(f64, @floatFromInt(head_w)) * scale) + 1;
    head_rect.bottom = head_rect.top + height_sign *
        (roundSource(@as(f64, @floatFromInt(head_h)) * scale) + 1);

    var torso_rect = LogicalRect{
        .left = full.left + roundSource(@as(f64, @floatFromInt(-bit_left)) * scale),
        .top = full.top + height_sign * roundSource(@as(f64, @floatFromInt(-bit_top)) * scale),
        .right = undefined,
        .bottom = undefined,
    };
    torso_rect.right = torso_rect.left + roundSource(@as(f64, @floatFromInt(torso_w)) * scale) + 1;
    torso_rect.bottom = torso_rect.top + height_sign *
        (roundSource(@as(f64, @floatFromInt(torso_h)) * scale) + 1);

    if (options.flipped) {
        const head_width = head_rect.right - head_rect.left;
        head_rect.left = full.right - (head_rect.left - full.left);
        head_rect.right = head_rect.left - head_width;
        const torso_width = torso_rect.right - torso_rect.left;
        torso_rect.left = full.right - (torso_rect.left - full.left);
        torso_rect.right = torso_rect.left - torso_width;
    }

    return .{ .full = full, .head = head_rect, .torso = torso_rect };
}

fn singleLogicalGeometry(pose: Image, options: LogicalOptions) Error!LogicalGeometry {
    const source_width: i32 = @intCast(pose.width);
    const source_height: i32 = @intCast(pose.height);
    const client = options.client;
    const height_sign: i32 = if (client.bottom > client.top) 1 else -1;
    const client_width = client.right - client.left;
    const client_height = height_sign * (client.bottom - client.top);
    const width_scale = @as(f64, @floatFromInt(client_width)) / @as(f64, @floatFromInt(source_width));
    const height_scale = @as(f64, @floatFromInt(client_height)) / @as(f64, @floatFromInt(source_height));

    var full_width: i32 = undefined;
    var full_height: i32 = undefined;
    if (width_scale <= height_scale) {
        full_width = client_width;
        // CBodySingle::GetBodyBox casts rather than ROUNDing.
        full_height = @intFromFloat(width_scale * @as(f64, @floatFromInt(source_height)));
    } else {
        full_height = client_height;
        full_width = @intFromFloat(height_scale * @as(f64, @floatFromInt(source_width)));
    }

    const full_left = client.left + @divTrunc(client_width - full_width, 2);
    const full_top = client.top + (client_height - full_height);
    var full = LogicalRect{
        .left = full_left,
        .top = full_top,
        .right = full_left + full_width,
        .bottom = full_top + height_sign * full_height,
    };
    if (options.flipped) std.mem.swap(i32, &full.left, &full.right);
    return .{ .full = full, .head = null, .torso = full };
}

fn mapLogicalGeometry(logical: LogicalGeometry, transform: raster.Transform) Error!Geometry {
    return .{
        .full = try mapLogicalRect(logical.full, transform),
        .head = if (logical.head) |head| try mapLogicalRect(head, transform) else null,
        .torso = try mapLogicalRect(logical.torso, transform),
    };
}

fn mapLogicalRect(logical: LogicalRect, transform: raster.Transform) Error!Rect {
    const first = transform.map(.{ .x = logical.left, .y = logical.top });
    const second = transform.map(.{ .x = logical.right, .y = logical.bottom });
    const left = @min(first.x, second.x);
    const top = @min(first.y, second.y);
    const width = @max(first.x, second.x) - left;
    const height = @max(first.y, second.y) - top;
    if (width <= 0 or height <= 0) return error.InvalidDestination;
    return .{ .x = left, .y = top, .w = width, .h = height };
}

fn drawTorso(canvas: *Canvas, pose: PoseLayers, rect: Rect, use_mask: bool, flipped: bool) Error!void {
    if (use_mask) {
        if (pose.mask) |layer| try stretchRop(canvas, layer, rect, flipped, .merge_paint);
    }
    try stretchRop(canvas, pose.drawing, rect, flipped, .src_and);
}

fn validateOptions(options: Options) Error!void {
    if (options.client.w <= 0 or options.client.h <= 0) return error.InvalidDestination;
}

fn validateLogicalOptions(options: LogicalOptions) Error!void {
    if (options.client.right <= options.client.left or options.client.top == options.client.bottom)
        return error.InvalidDestination;
}

fn validateImage(image: Image) Error!void {
    if (image.width == 0 or image.height == 0 or
        image.pixels.len != @as(usize, image.width) * image.height)
        return error.InvalidImage;
}

fn roundSource(value: f64) i32 {
    // vector2d.h:46-52.  All body-box values passed here are non-negative,
    // while retaining the negative branch documents the exact helper.
    return if (value > 0)
        @intFromFloat(value + 0.5)
    else
        @intFromFloat(value - 0.5);
}

fn areaSample(source: Image, dx: i32, dy: i32, dw: i32, dh: i32, flipped: bool) u32 {
    const sw = @as(f64, @floatFromInt(source.width));
    const sh = @as(f64, @floatFromInt(source.height));
    var sx0 = @as(f64, @floatFromInt(dx)) * sw / @as(f64, @floatFromInt(dw));
    var sx1 = @as(f64, @floatFromInt(dx + 1)) * sw / @as(f64, @floatFromInt(dw));
    if (flipped) {
        const old0 = sx0;
        sx0 = sw - sx1;
        sx1 = sw - old0;
    }
    const sy0 = @as(f64, @floatFromInt(dy)) * sh / @as(f64, @floatFromInt(dh));
    const sy1 = @as(f64, @floatFromInt(dy + 1)) * sh / @as(f64, @floatFromInt(dh));
    const first_x: i32 = @intFromFloat(@floor(sx0));
    const last_x: i32 = @intFromFloat(@ceil(sx1));
    const first_y: i32 = @intFromFloat(@floor(sy0));
    const last_y: i32 = @intFromFloat(@ceil(sy1));

    var accum_a: f64 = 0;
    var accum_r: f64 = 0;
    var accum_g: f64 = 0;
    var accum_b: f64 = 0;
    var total: f64 = 0;
    var sy = first_y;
    while (sy < last_y) : (sy += 1) {
        if (sy < 0 or sy >= @as(i32, @intCast(source.height))) continue;
        const wy = @min(sy1, @as(f64, @floatFromInt(sy + 1))) - @max(sy0, @as(f64, @floatFromInt(sy)));
        if (wy <= 0) continue;
        var sx = first_x;
        while (sx < last_x) : (sx += 1) {
            if (sx < 0 or sx >= @as(i32, @intCast(source.width))) continue;
            const wx = @min(sx1, @as(f64, @floatFromInt(sx + 1))) - @max(sx0, @as(f64, @floatFromInt(sx)));
            if (wx <= 0) continue;
            const weight = wx * wy;
            const pixel = source.pixels[@as(usize, @intCast(sy)) * source.width + @as(usize, @intCast(sx))];
            accum_a += @as(f64, @floatFromInt((pixel >> 24) & 0xff)) * weight;
            accum_r += @as(f64, @floatFromInt((pixel >> 16) & 0xff)) * weight;
            accum_g += @as(f64, @floatFromInt((pixel >> 8) & 0xff)) * weight;
            accum_b += @as(f64, @floatFromInt(pixel & 0xff)) * weight;
            total += weight;
        }
    }
    if (total == 0) return 0xffffffff;
    const a: u32 = @intFromFloat(@floor(accum_a / total + 0.5));
    const r: u32 = @intFromFloat(@floor(accum_r / total + 0.5));
    const g: u32 = @intFromFloat(@floor(accum_g / total + 0.5));
    const b: u32 = @intFromFloat(@floor(accum_b / total + 0.5));
    return (a << 24) | (r << 16) | (g << 8) | b;
}

const LoadedPose = struct {
    drawing: Image,
    mask: ?Image = null,
    aura: ?Image = null,

    fn borrow(self: LoadedPose) PoseLayers {
        return .{ .drawing = self.drawing, .mask = self.mask, .aura = self.aura };
    }

    fn deinit(self: *LoadedPose, gpa: std.mem.Allocator) void {
        self.drawing.deinit(gpa);
        if (self.mask) |*image| image.deinit(gpa);
        if (self.aura) |*image| image.deinit(gpa);
        self.* = undefined;
    }
};

fn loadPose(
    gpa: std.mem.Allocator,
    data: []const u8,
    record: avb.PoseRecord,
    want_mask: bool,
    want_aura: bool,
) !LoadedPose {
    const drawing_plan = record.imagePlan(.drawing) orelse return error.MissingImage;
    var result = LoadedPose{ .drawing = try decodePlan(gpa, data, drawing_plan) };
    errdefer result.deinit(gpa);
    _ = try source_figure.takePaddedSimpleCard(gpa, &result.drawing);
    if (want_mask) {
        if (record.imagePlan(.mask)) |plan| result.mask = try decodePlan(gpa, data, plan);
    }
    if (want_aura) {
        if (record.imagePlan(.aura)) |plan| result.aura = try decodePlan(gpa, data, plan);
    }
    return result;
}

fn drawingHasChromaticInk(image: Image) bool {
    for (image.pixels) |pixel| {
        if (pixel >> 24 == 0) continue;
        const rgb = pixel & 0x00ffffff;
        if (rgb == 0 or rgb == 0x00ffffff) continue;
        const red: u8 = @truncate(pixel >> 16);
        const green: u8 = @truncate(pixel >> 8);
        const blue: u8 = @truncate(pixel);
        if (red != green or green != blue) return true;
    }
    return false;
}

/// Near-white / near-gray anti-alias on Color/HD cards is paper, not
/// silhouette. Treating mid-gray fringe (230–241) as ink MERGEPAINTs a pale
/// halo around the woman on colored rooms. Chromatic clothes stay ink.
fn stickerInk(sampled: u32) bool {
    if (sampled >> 24 == 0) return false;
    const rgb = sampled & 0x00ffffff;
    if (rgb == 0x00ffffff) return false;
    const red: u8 = @truncate(sampled >> 16);
    const green: u8 = @truncate(sampled >> 8);
    const blue: u8 = @truncate(sampled);
    const max_c = @max(red, @max(green, blue));
    const min_c = @min(red, @min(green, blue));
    if (min_c >= 228 and max_c - min_c < 18) return false;
    return red < 242 or green < 242 or blue < 242;
}

/// `CBodySingle::DrawBody` MERGEPAINTs an aura before SRCAND (`bodycam.cpp:602-609`).
/// Color/HD packages have no authored aura. A synthesized 1-bit sticker then
/// bleaches a paper ring on colored rooms; copy keyed chromatic ink instead.
/// Testdata keeps the authored aura + SRCAND path.
fn paintKeyedBody(
    canvas: *Canvas,
    pose: PoseLayers,
    destination: Rect,
    flipped: bool,
    draw_aura: bool,
) Error!void {
    if (draw_aura) {
        if (pose.aura) |layer| {
            try stretchRop(canvas, layer, destination, flipped, .merge_paint);
            try stretchRop(canvas, pose.drawing, destination, flipped, .src_and);
            return;
        }
        if (drawingHasChromaticInk(pose.drawing)) {
            try stretchRop(canvas, pose.drawing, destination, flipped, .src_copy_keyed);
            return;
        }
    }
    try stretchRop(canvas, pose.drawing, destination, flipped, .src_and);
}

fn decodePlan(gpa: std.mem.Allocator, data: []const u8, plan: avb.PoseImagePlan) !Image {
    return switch (plan.component) {
        .whole => bgb.decodeImageRef(gpa, data, plan.image),
        .masked_mono_drawing, .low_bit, .high_bit, .any_bit => decodePackedPlane(gpa, data, plan.image, plan.component),
    };
}

fn rdU16(bytes: []const u8, offset: usize) Error!u16 {
    if (offset + 2 > bytes.len) return error.Truncated;
    return @as(u16, bytes[offset]) | (@as(u16, bytes[offset + 1]) << 8);
}

fn rdU32(bytes: []const u8, offset: usize) Error!u32 {
    if (offset + 4 > bytes.len) return error.Truncated;
    return @as(u32, bytes[offset]) | (@as(u32, bytes[offset + 1]) << 8) |
        (@as(u32, bytes[offset + 2]) << 16) | (@as(u32, bytes[offset + 3]) << 24);
}

fn rdI32(bytes: []const u8, offset: usize) Error!i32 {
    return @bitCast(try rdU32(bytes, offset));
}

/// Decode the exact bit planes emitted by `CPose::ConvertMasksCommon`.
fn decodePackedPlane(
    gpa: std.mem.Allocator,
    data: []const u8,
    image_ref: avb.ImageRef,
    component: avb.ImageComponent,
) !Image {
    if (image_ref.format != .zlib) return error.UnsupportedFormat;
    if (image_ref.palette != .masked_mono and image_ref.palette != .dual_mask)
        return error.UnsupportedPalette;
    var pos: usize = image_ref.offset;
    const header_size = try rdU32(data, pos);
    if (header_size < 40 or header_size > 240 or pos + header_size > data.len)
        return error.InvalidBitmap;
    const signed_width = try rdI32(data, pos + 4);
    const signed_height = try rdI32(data, pos + 8);
    if (signed_width <= 0 or signed_height == 0 or signed_height == std.math.minInt(i32))
        return error.InvalidBitmap;
    if (try rdU16(data, pos + 12) != 1 or try rdU16(data, pos + 14) != 2)
        return error.UnsupportedDepth;
    const width: u32 = @intCast(signed_width);
    const height: u32 = @intCast(@abs(signed_height));
    if (width > 8192 or height > 8192) return error.InvalidBitmap;
    pos += header_size;
    const raw_len = try rdU32(data, pos);
    const compressed_len = try rdU32(data, pos + 4);
    pos += 8;
    const compressed_end = std.math.add(usize, pos, compressed_len) catch return error.Truncated;
    if (compressed_end > data.len) return error.Truncated;
    const stride: usize = ((@as(usize, width) * 2 + 31) / 32) * 4;
    const expected_len = std.math.mul(usize, stride, height) catch return error.InvalidBitmap;
    if (raw_len != expected_len) return error.InvalidBitmap;

    const raw = try gpa.alloc(u8, expected_len);
    defer gpa.free(raw);
    var input: std.Io.Reader = .fixed(data[pos..compressed_end]);
    var window: [flate.max_window_len]u8 = undefined;
    var decoder = flate.Decompress.init(&input, .zlib, &window);
    try decoder.reader.readSliceAll(raw);

    const pixels = try gpa.alloc(u32, @as(usize, width) * height);
    errdefer gpa.free(pixels);
    var y: u32 = 0;
    while (y < height) : (y += 1) {
        const source_y = if (signed_height > 0) height - 1 - y else y;
        const row = @as(usize, source_y) * stride;
        var x: u32 = 0;
        while (x < width) : (x += 1) {
            const value = (raw[row + x / 4] >> @intCast(6 - 2 * (x % 4))) & 3;
            // ConvertMasksCommon emits low bit, high bit, and any bit.  For a
            // masked-mono drawing it then ANDs image with mask, so drawing ink
            // survives only when both packed bits are set.
            const black = switch (component) {
                .masked_mono_drawing => value == 3,
                .low_bit => value & 1 != 0,
                .high_bit => value & 2 != 0,
                .any_bit => value != 0,
                .whole => unreachable,
            };
            pixels[@as(usize, y) * width + x] = if (black) 0xff000000 else 0xffffffff;
        }
    }
    return .{ .width = width, .height = height, .pixels = pixels };
}

test "bodycam component order obeys TORSOFIRST and HEADMASK" {
    const gpa = std.testing.allocator;
    var torso_pixels = [_]u32{0xff000000};
    var head_pixels = [_]u32{0xffff0000};
    var mask_pixels = [_]u32{0xff000000};
    const torso = PoseLayers{ .drawing = .{ .width = 1, .height = 1, .pixels = &torso_pixels } };
    const head = PoseLayers{
        .drawing = .{ .width = 1, .height = 1, .pixels = &head_pixels },
        .mask = .{ .width = 1, .height = 1, .pixels = &mask_pixels },
    };
    const options = Options{ .client = .{ .x = 0, .y = 0, .w = 1, .h = 1 }, .draw_aura = false };
    const anchors = bgb.NeckAnchors{ .head = .{ .x = 0, .y = 0 }, .body = .{ .x = 0, .y = 0 } };

    var torso_first = try Canvas.init(gpa, 1, 1);
    defer torso_first.deinit(gpa);
    torso_first.clear(0xff0000ff);
    _ = try drawComplex(&torso_first, head, torso, anchors, .{
        .head_mask = true,
        .torso_first = true,
    }, options);
    try std.testing.expectEqual(@as(u32, 0xffff0000), torso_first.px[0]);

    var torso_last = try Canvas.init(gpa, 1, 1);
    defer torso_last.deinit(gpa);
    torso_last.clear(0xff0000ff);
    _ = try drawComplex(&torso_last, head, torso, anchors, .{ .head_mask = true }, options);
    try std.testing.expectEqual(@as(u32, 0xff000000), torso_last.px[0]);

    var mask_disabled = try Canvas.init(gpa, 1, 1);
    defer mask_disabled.deinit(gpa);
    mask_disabled.clear(0xff0000ff);
    _ = try drawComplex(&mask_disabled, head, torso, anchors, .{ .torso_first = true }, options);
    try std.testing.expectEqual(@as(u32, 0xff000000), mask_disabled.px[0]);

    // The late torso mask erases the already drawn head before its white
    // drawing, exactly like bodycam.cpp's non-TORSOFIRST branch.
    var white_torso_pixels = [_]u32{0xffffffff};
    const white_torso = PoseLayers{
        .drawing = .{ .width = 1, .height = 1, .pixels = &white_torso_pixels },
        .mask = .{ .width = 1, .height = 1, .pixels = &mask_pixels },
    };
    var torso_masked = try Canvas.init(gpa, 1, 1);
    defer torso_masked.deinit(gpa);
    torso_masked.clear(0xff0000ff);
    _ = try drawComplex(&torso_masked, head, white_torso, anchors, .{ .torso_mask = true }, options);
    try std.testing.expectEqual(@as(u32, 0xffffffff), torso_masked.px[0]);
}

test "aura MERGEPAINT makes the source white sticker" {
    const gpa = std.testing.allocator;
    var white_pixels = [_]u32{0xffffffff};
    var black_pixels = [_]u32{0xff000000};
    const pose = PoseLayers{
        .drawing = .{ .width = 1, .height = 1, .pixels = &white_pixels },
        .aura = .{ .width = 1, .height = 1, .pixels = &black_pixels },
    };
    var canvas = try Canvas.init(gpa, 1, 1);
    defer canvas.deinit(gpa);
    canvas.clear(0xff2468ac);
    _ = try drawSingle(&canvas, pose, .{ .client = .{ .x = 0, .y = 0, .w = 1, .h = 1 } });
    try std.testing.expectEqual(@as(u32, 0xffffffff), canvas.px[0]);
}

test "color DIB MERGEPAINT sticker keeps chromatic ink off a colored dest" {
    const gpa = std.testing.allocator;
    var red = [_]u32{0xffff0000};
    const pose = PoseLayers{ .drawing = .{ .width = 1, .height = 1, .pixels = &red } };
    var canvas = try Canvas.init(gpa, 1, 1);
    defer canvas.deinit(gpa);
    canvas.clear(0xff00ff00);
    _ = try drawSingle(&canvas, pose, .{ .client = .{ .x = 0, .y = 0, .w = 1, .h = 1 } });
    // Keyed copy keeps red. SRCAND without a sticker would be red & green = black.
    try std.testing.expectEqual(@as(u32, 0xffff0000), canvas.px[0]);

    const color = @embedFile("../assets/generated/anna-color-hd-v1.avb");
    var panel = try Canvas.init(gpa, 80, 120);
    defer panel.deinit(gpa);
    panel.clear(0xff00aa33);
    _ = try drawForText(gpa, &panel, color, "", .{ .client = .{ .x = 0, .y = 0, .w = 80, .h = 120 } });
    var colorful: usize = 0;
    var and_black: usize = 0;
    for (panel.px) |pixel| {
        const rgb = pixel & 0x00ffffff;
        if (rgb == 0) and_black += 1;
        const red_ch: u8 = @truncate(pixel >> 16);
        const green_ch: u8 = @truncate(pixel >> 8);
        const blue_ch: u8 = @truncate(pixel);
        if (red_ch != green_ch or green_ch != blue_ch) colorful += 1;
    }
    try std.testing.expect(colorful > 100);
    try std.testing.expect(and_black < colorful);
}

test "Color sticker ignores near-white AA so dest is not bleached" {
    try std.testing.expect(!stickerInk(0xfff8f4f2));
    try std.testing.expect(!stickerInk(0xffffffff));
    try std.testing.expect(!stickerInk(0xfff0f0f0));
    try std.testing.expect(!stickerInk(0xffe6e6e4));
    try std.testing.expect(stickerInk(0xffff2040));
    try std.testing.expect(stickerInk(0xffe0b090));
    try std.testing.expect(stickerInk(0xfff5ead0));

    var fringe = [_]u32{0xfff8f4f2};
    const pose = PoseLayers{ .drawing = .{ .width = 1, .height = 1, .pixels = &fringe } };
    var canvas = try Canvas.init(std.testing.allocator, 1, 1);
    defer canvas.deinit(std.testing.allocator);
    canvas.clear(0xff00aa33);
    _ = try drawSingle(&canvas, pose, .{ .client = .{ .x = 0, .y = 0, .w = 1, .h = 1 } });
    const rgb = canvas.px[0] & 0x00ffffff;
    try std.testing.expect(rgb != 0x00ffffff);
    const green: u8 = @truncate(rgb >> 8);
    try std.testing.expect(green > 80);
}

test "negative StretchDIBits width is reproduced by horizontal flip" {
    const gpa = std.testing.allocator;
    var pixels = [_]u32{ 0xff000000, 0xffffffff };
    const pose = PoseLayers{ .drawing = .{ .width = 2, .height = 1, .pixels = &pixels } };
    var canvas = try Canvas.init(gpa, 2, 1);
    defer canvas.deinit(gpa);
    canvas.clear(0xffff0000);
    _ = try drawSingle(&canvas, pose, .{
        .client = .{ .x = 0, .y = 0, .w = 2, .h = 1 },
        .flipped = true,
        .draw_aura = false,
    });
    try std.testing.expectEqualSlices(u32, &.{ 0xffff0000, 0xff000000 }, canvas.px);
}

test "halftone-compatible shrink averages authored pixels" {
    const gpa = std.testing.allocator;
    var pixels = [_]u32{ 0xff000000, 0xffffffff };
    var canvas = try Canvas.init(gpa, 1, 1);
    defer canvas.deinit(gpa);
    canvas.clear(0xffffffff);
    try stretchRop(&canvas, .{ .width = 2, .height = 1, .pixels = &pixels }, .{
        .x = 0,
        .y = 0,
        .w = 1,
        .h = 1,
    }, false, .src_and);
    try std.testing.expectEqual(@as(u32, 0xff808080), canvas.px[0]);
}

test "complex body geometry retains source rounding and component plus one" {
    const gpa = std.testing.allocator;
    var head_pixels: [100]u32 = @splat(0xffffffff);
    var torso_pixels: [600]u32 = @splat(0xffffffff);
    const head = PoseLayers{ .drawing = .{ .width = 10, .height = 10, .pixels = &head_pixels } };
    const torso = PoseLayers{ .drawing = .{ .width = 20, .height = 30, .pixels = &torso_pixels } };
    var canvas = try Canvas.init(gpa, 100, 100);
    defer canvas.deinit(gpa);
    canvas.clear(0xffffffff);
    const geometry = try drawComplex(&canvas, head, torso, .{
        .head = .{ .x = 0, .y = 0 },
        .body = .{ .x = 5, .y = -2 },
    }, .{}, .{
        .client = .{ .x = 0, .y = 0, .w = 100, .h = 100 },
        .draw_aura = false,
    });
    try std.testing.expectEqual(Rect{ .x = 18, .y = 0, .w = 63, .h = 100 }, geometry.full);
    try std.testing.expectEqual(Rect{ .x = 34, .y = 0, .w = 32, .h = 32 }, geometry.head.?);
    try std.testing.expectEqual(Rect{ .x = 18, .y = 6, .w = 64, .h = 95 }, geometry.torso);
}

test "logical bodycam component plus one is scaled instead of added as a device pixel" {
    const gpa = std.testing.allocator;
    var head_pixels: [100]u32 = @splat(0xffffffff);
    var torso_pixels: [600]u32 = @splat(0xffffffff);
    const head = PoseLayers{ .drawing = .{ .width = 10, .height = 10, .pixels = &head_pixels } };
    const torso = PoseLayers{ .drawing = .{ .width = 20, .height = 30, .pixels = &torso_pixels } };
    var canvas = try Canvas.init(gpa, 10, 10);
    defer canvas.deinit(gpa);
    canvas.clear(0xffffffff);
    const transform = try raster.Transform.init(
        .{ .left = 0, .top = 100, .right = 100, .bottom = 0 },
        .{ .x = 0, .y = 0, .width = 10, .height = 10 },
    );
    const result = try drawComplexLogical(&canvas, head, torso, .{
        .head = .{ .x = 0, .y = 0 },
        .body = .{ .x = 5, .y = -2 },
    }, .{}, .{
        .client = .{ .left = 0, .top = 100, .right = 100, .bottom = 0 },
        .transform = transform,
        .draw_aura = false,
    });

    try std.testing.expectEqual(
        LogicalRect{ .left = 18, .top = 100, .right = 81, .bottom = 0 },
        result.logical.full,
    );
    try std.testing.expectEqual(
        LogicalRect{ .left = 34, .top = 100, .right = 66, .bottom = 68 },
        result.logical.head.?,
    );
    try std.testing.expectEqual(
        LogicalRect{ .left = 18, .top = 94, .right = 82, .bottom = -1 },
        result.logical.torso,
    );
    try std.testing.expectEqual(Rect{ .x = 2, .y = 0, .w = 6, .h = 10 }, result.device.full);
    try std.testing.expectEqual(Rect{ .x = 3, .y = 0, .w = 4, .h = 3 }, result.device.head.?);
    // Computing the component box after mapping the 100-unit client to 10px
    // would incorrectly make this 7x10: the source's +1 belongs to TWIPs.
    try std.testing.expectEqual(Rect{ .x = 2, .y = 1, .w = 6, .h = 9 }, result.device.torso);
}

test "logical bodycam flip preserves negative source widths before mapping" {
    const gpa = std.testing.allocator;
    var head_pixels: [100]u32 = @splat(0xffffffff);
    var torso_pixels: [600]u32 = @splat(0xffffffff);
    const head = PoseLayers{ .drawing = .{ .width = 10, .height = 10, .pixels = &head_pixels } };
    const torso = PoseLayers{ .drawing = .{ .width = 20, .height = 30, .pixels = &torso_pixels } };
    var canvas = try Canvas.init(gpa, 10, 10);
    defer canvas.deinit(gpa);
    canvas.clear(0xffffffff);
    const transform = try raster.Transform.init(
        .{ .left = 0, .top = 100, .right = 100, .bottom = 0 },
        .{ .x = 0, .y = 0, .width = 10, .height = 10 },
    );
    const result = try drawComplexLogical(&canvas, head, torso, .{
        .head = .{ .x = 0, .y = 0 },
        .body = .{ .x = 5, .y = -2 },
    }, .{}, .{
        .client = .{ .left = 0, .top = 100, .right = 100, .bottom = 0 },
        .transform = transform,
        .flipped = true,
        .draw_aura = false,
    });

    try std.testing.expectEqual(
        LogicalRect{ .left = 65, .top = 100, .right = 33, .bottom = 68 },
        result.logical.head.?,
    );
    try std.testing.expectEqual(
        LogicalRect{ .left = 81, .top = 94, .right = 17, .bottom = -1 },
        result.logical.torso,
    );
    try std.testing.expectEqual(Rect{ .x = 3, .y = 0, .w = 4, .h = 3 }, result.device.head.?);
    try std.testing.expectEqual(Rect{ .x = 2, .y = 1, .w = 6, .h = 9 }, result.device.torso);
}

test "real masked-mono pose preserves separate drawing mask and aura planes" {
    const gpa = std.testing.allocator;
    const anna = @embedFile("../assets/testdata/anna.avb");
    var table = try avb.parsePoseTable(gpa, anna);
    defer table.deinit(gpa);
    const record = table.records[0];
    var pose = try loadPose(gpa, anna, record, true, true);
    defer pose.deinit(gpa);
    try std.testing.expectEqual(pose.drawing.width, pose.mask.?.width);
    try std.testing.expectEqual(pose.drawing.height, pose.aura.?.height);
    var drawing_black: usize = 0;
    var mask_black: usize = 0;
    var aura_black: usize = 0;
    for (pose.drawing.pixels) |pixel| if ((pixel & 0x00ffffff) == 0) {
        drawing_black += 1;
    };
    for (pose.mask.?.pixels) |pixel| if ((pixel & 0x00ffffff) == 0) {
        mask_black += 1;
    };
    for (pose.aura.?.pixels) |pixel| if ((pixel & 0x00ffffff) == 0) {
        aura_black += 1;
    };
    try std.testing.expect(drawing_black > 0);
    try std.testing.expect(mask_black > drawing_black);
    try std.testing.expect(aura_black >= mask_black);
}

test "drawForText composites a bundled avatar directly onto a panel" {
    const gpa = std.testing.allocator;
    var canvas = try Canvas.init(gpa, 315, 315);
    defer canvas.deinit(gpa);
    canvas.clear(0xff6a8cb0);
    const geometry = try drawForText(gpa, &canvas, @embedFile("../assets/testdata/anna.avb"), "Hello!", .{
        .client = .{ .x = 30, .y = 95, .w = 255, .h = 220 },
    });
    try std.testing.expect(geometry.full.w > 0 and geometry.full.h > 0);
    try std.testing.expect(std.mem.indexOfScalar(u32, canvas.px, 0xffffffff) != null);
    try std.testing.expect(std.mem.indexOfScalar(u32, canvas.px, 0xff000000) != null);
}

test "drawForTextLogical keeps bundled avatar geometry in panel units until raster" {
    const gpa = std.testing.allocator;
    var canvas = try Canvas.init(gpa, 315, 315);
    defer canvas.deinit(gpa);
    canvas.clear(0xff6a8cb0);
    const geometry = try drawForTextLogical(gpa, &canvas, @embedFile("../assets/testdata/anna.avb"), "Hello!", .{
        .client = .{ .left = 200, .top = -600, .right = 2100, .bottom = -2300 },
        .transform = raster.Transform.panel315(),
    });
    try std.testing.expect(geometry.logical.full.right > geometry.logical.full.left);
    try std.testing.expect(geometry.device.full.w > 0 and geometry.device.full.h > 0);
    try std.testing.expect(std.mem.indexOfScalar(u32, canvas.px, 0xffffffff) != null);
    try std.testing.expect(std.mem.indexOfScalar(u32, canvas.px, 0xff000000) != null);
}
