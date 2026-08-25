//! Assemble a complete Comic Chat character figure from a decoded .avb.
//!
//! Humanoid avatars store the figure as two layers — a head/expression pose and
//! a (taller) body/gesture pose — composited at the neck using the pose-metadata
//! anchors. Creature/totem avatars (Jordan, Tiki) store a complete figure per
//! pose and are rendered directly. Returns an RGBA image with a TRANSPARENT
//! background (so it can be composited over a panel scene); the figure itself is
//! an opaque white "sticker" silhouette with black ink, matching the original.

const std = @import("std");
const avb_asset = @import("../assets/avb.zig");
const bgb = @import("../assets/bgb.zig");
const emotion_mod = @import("emotion.zig");
const udi = @import("../proto/udi.zig");
const Canvas = @import("../render/canvas.zig").Canvas;

pub const Image = bgb.Image;

pub const Rendered = struct {
    image: Image,
    /// Original `GetDimInfo` values in authored bitmap pixels.
    face_x: i32,
    /// `CBodySingle::GetDimInfo` (`avatar.cpp:63`) uses `ydim/2` for simple
    /// avatars. Complex bodies use the neck-assembled head band from
    /// `CBodyDouble::GetDimInfo`.
    head_height: i32,
    /// `CBody::m_requested` is not visual, but it is part of the exact state
    /// installed by `SetIndices` and must survive the portable assembly path.
    requested: bool = false,
    /// Cropped generated Color/HD standing card. Comic layout must not
    /// zoom these around the ground line (legs-only).
    generated_standing: bool = false,

    pub fn deinit(self: *Rendered, gpa: std.mem.Allocator) void {
        self.image.deinit(gpa);
        self.* = undefined;
    }
};

/// Exact AVB records selected by `SayEntry::Execute`.  Normal avatars use the
/// transmitted record ordinals directly; OTHERMAPPED avatars select from the
/// serialized emotion/intensity pair instead (`histent.cpp:94-105`).
pub const SourcePoseSelection = struct {
    face: ?*const avb_asset.PoseRecord = null,
    torso: ?*const avb_asset.PoseRecord = null,
    body: ?*const avb_asset.PoseRecord = null,
    requested: bool,
};

/// Port of `CAvatarComplex/CAvatarSimple::SetIndices`, plus the OTHERMAPPED
/// `BytesToEmotion`/`SetEmotions` branch.  `SetIndices` leaves an invalid layer
/// unchanged; the portable page renderer has no long-lived `CAvatarX` body to
/// consult, so an out-of-range wire ordinal uses a deterministic neutral
/// fallback. Valid annotations, including every emitted by the old client,
/// take the exact source path.
pub fn selectSourcePose(
    records: []const avb_asset.PoseRecord,
    kind: avb_asset.Kind,
    other_mapped: bool,
    pose: udi.PoseState,
) SourcePoseSelection {
    if (kind == .simple_avatar) return .{
        .body = if (other_mapped)
            mappedRecord(records, .body, pose.expression)
        else
            recordByOrdinal(records, .body, pose.gesture.index) orelse neutralRecord(records, .body),
        .requested = pose.requested,
    };
    return .{
        .face = if (other_mapped)
            mappedRecord(records, .face, pose.expression)
        else
            recordByOrdinal(records, .face, pose.expression.index) orelse neutralRecord(records, .face),
        .torso = if (other_mapped)
            mappedRecord(records, .torso, pose.gesture)
        else
            recordByOrdinal(records, .torso, pose.gesture.index) orelse neutralRecord(records, .torso),
        .requested = pose.requested,
    };
}

fn recordByOrdinal(records: []const avb_asset.PoseRecord, layer: avb_asset.PoseLayer, ordinal: u8) ?*const avb_asset.PoseRecord {
    var found: usize = 0;
    for (records) |*record| {
        if (record.layer != layer) continue;
        if (found == @as(usize, ordinal)) return record;
        found += 1;
    }
    return null;
}

fn neutralRecord(records: []const avb_asset.PoseRecord, layer: avb_asset.PoseLayer) ?*const avb_asset.PoseRecord {
    for (records) |*record|
        if (record.layer == layer and record.emotion_index == 9 and record.intensity == 0) return record;
    for (records) |*record| if (record.layer == layer) return record;
    return null;
}

/// `BytesToEmotion` indexes float values, not AVB codes. `emFloats[0]`, HAPPY,
/// and NEUTRAL all equal 0.0, so records 1 and 9 (plus invalid record indices,
/// which `EmotionToFloat` also maps to zero) compete by intensity for wire
/// indices 0, 1, 9, and the out-of-range neutral fallback.
fn mappedEmotionMatches(record_index: u16, wire_index: u8) bool {
    if (wire_index == 0 or wire_index == 1 or wire_index == 9 or wire_index >= 18)
        return record_index == 0 or record_index == 1 or record_index == 9 or record_index >= 18;
    return record_index == wire_index;
}

fn mappedRecord(
    records: []const avb_asset.PoseRecord,
    layer: avb_asset.PoseLayer,
    components: udi.Components,
) ?*const avb_asset.PoseRecord {
    var best: ?*const avb_asset.PoseRecord = null;
    var best_delta: u32 = std.math.maxInt(u32);
    for (records) |*record| {
        if (record.layer != layer or !mappedEmotionMatches(record.emotion_index, components.emotion)) continue;
        // AVB intensity is byte/255.0; BytesToEmotion is wire/10.0. Compare
        // without floating-point rounding: |record*10 - wire*255|.
        const authored = @as(i32, record.intensity) * 10;
        const requested = @as(i32, components.intensity) * 255;
        const delta: u32 = @intCast(@abs(authored - requested));
        if (delta < best_delta) {
            best = record;
            best_delta = delta;
        }
    }
    return best orelse neutralRecord(records, layer);
}

/// Assemble the figure for `avb` using head pose `emotion` and body pose `gesture`
/// (both 0-based; clamped to what's available — index 0 = neutral).
pub fn assemble(gpa: std.mem.Allocator, avb: []const u8, emotion: usize, gesture: usize) !Image {
    var body = bgb.decodePoseAuto(gpa, avb, gesture, true) catch
        try bgb.decodePoseAuto(gpa, avb, 0, true);
    defer body.deinit(gpa);

    var head_opt: ?Image = bgb.decodePoseAuto(gpa, avb, emotion, false) catch
        (bgb.decodePoseAuto(gpa, avb, 0, false) catch null);
    defer if (head_opt) |*h| h.deinit(gpa);

    // Composite whenever the avatar has a head pose. Only true "creature"
    // avatars with NO head layer at all (e.g. Jordan) render a single pose.
    if (head_opt == null) return try solo(gpa, body);

    return joinExact(gpa, bgb.neckAnchors(avb) orelse return error.MissingNeckAnchors, head_opt.?, body);
}

/// Reproduce `GetBodyFromEmotion(CEmotionOpts&)`: priority-ranked text rules
/// choose one face and one gesture independently for complex avatars, while a
/// simple avatar chooses its single whole-body pose from the same option set.
pub fn assembleForText(gpa: std.mem.Allocator, avb_data: []const u8, text: []const u8) !Image {
    const analysis = emotion_mod.analyzeText(text);
    return assembleAnalysis(gpa, avb_data, &analysis);
}

pub fn assembleAnalysis(gpa: std.mem.Allocator, avb_data: []const u8, analysis: *const emotion_mod.TextAnalysis) !Image {
    const rendered = try assembleDetailedAnalysis(gpa, avb_data, analysis);
    return rendered.image;
}

pub fn assembleDetailedForText(gpa: std.mem.Allocator, avb_data: []const u8, text: []const u8) !Rendered {
    const analysis = emotion_mod.analyzeText(text);
    return assembleDetailedAnalysis(gpa, avb_data, &analysis);
}

/// Reproduce the pose fields emitted by `bInsertAnnotations` after
/// `ChatPreSendText` has selected an avatar body from the message text.
/// Indices are raw face/torso/body record ordinals; emotion/intensity bytes
/// follow `EmotionToBytes`, including its first-match HAPPY encoding for the
/// shared HAPPY/NEUTRAL 0.0 float value.
pub fn poseStateForText(
    gpa: std.mem.Allocator,
    avb_data: []const u8,
    text: []const u8,
) !udi.PoseState {
    const analysis = emotion_mod.analyzeText(text);
    return poseStateForAnalysis(gpa, avb_data, &analysis);
}

/// Resolve an explicit body-camera face selection through the same authored
/// AVB availability and ordinal rules used by text-derived poses.
pub fn poseStateForEmotion(
    gpa: std.mem.Allocator,
    avb_data: []const u8,
    selected: emotion_mod.Emotion,
    intensity: u8,
) !udi.PoseState {
    var analysis: emotion_mod.TextAnalysis = .{};
    analysis.add(selected, intensity, 255);
    var pose = try poseStateForAnalysis(gpa, avb_data, &analysis);
    pose.requested = true;
    return pose;
}

fn poseStateForAnalysis(
    gpa: std.mem.Allocator,
    avb_data: []const u8,
    analysis: *const emotion_mod.TextAnalysis,
) !udi.PoseState {
    const asset = try avb_asset.parse(avb_data);
    var table = try avb_asset.parsePoseTable(gpa, avb_data);
    defer table.deinit(gpa);

    if (asset.kind == .simple_avatar) {
        const choice = selectAvailable(table.records, analysis, .body, null) orelse neutralChoice();
        const body = bgb.selectPose(table.records, .body, choice.emotion.assetIndex(), choice.intensity) orelse
            return error.PoseNotFound;
        return .{
            // CAvatarSimple::GetEmotions reports torso as (0,0), while
            // GetIndices reports the selected whole body as the torso index.
            .gesture = .{
                .index = try recordOrdinal(table.records, .body, body),
                .emotion = 1,
                .intensity = 0,
            },
            .expression = sourceComponents(
                0,
                body.emotion_index,
                body.intensity,
            ),
            .requested = false,
        };
    }

    const face_choice = selectAvailable(table.records, analysis, .face, false) orelse neutralChoice();
    const torso_choice = selectAvailable(table.records, analysis, .torso, true) orelse neutralChoice();
    const face = bgb.selectPose(table.records, .face, face_choice.emotion.assetIndex(), face_choice.intensity) orelse
        return error.PoseNotFound;
    const torso = bgb.selectPose(table.records, .torso, torso_choice.emotion.assetIndex(), torso_choice.intensity) orelse
        return error.PoseNotFound;
    return .{
        .gesture = sourceComponents(
            try recordOrdinal(table.records, .torso, torso),
            torso.emotion_index,
            torso.intensity,
        ),
        .expression = sourceComponents(
            try recordOrdinal(table.records, .face, face),
            face.emotion_index,
            face.intensity,
        ),
        .requested = false,
    };
}

fn recordOrdinal(
    records: []const avb_asset.PoseRecord,
    layer: avb_asset.PoseLayer,
    wanted: *const avb_asset.PoseRecord,
) !u8 {
    var ordinal: usize = 0;
    for (records) |*record| {
        if (record.layer != layer) continue;
        if (record == wanted) return std.math.cast(u8, ordinal) orelse error.PoseOrdinalOverflow;
        ordinal += 1;
    }
    return error.PoseNotFound;
}

fn sourceComponents(index: u8, emotion_index: u16, intensity: u8) udi.Components {
    return .{
        .index = index,
        // EmotionToBytes scans emFloats from index one. HAPPY, NEUTRAL, zero,
        // and invalid EmotionToFloat values all share the first HAPPY value.
        .emotion = switch (emotion_index) {
            2...8, 10...17 => @intCast(emotion_index),
            else => 1,
        },
        .intensity = @intCast(@divTrunc(@as(u16, intensity) * 10, 255)),
    };
}

/// Assemble the exact cooked UDI pose.  Unlike the semantic text path, record
/// indices remain raw AVB table ordinals for ordinary avatars, matching
/// `CAvatarComplex::SetIndices` and `CAvatarSimple::SetIndices`.
pub fn assembleDetailedForSourcePose(
    gpa: std.mem.Allocator,
    avb_data: []const u8,
    pose: udi.PoseState,
) !Rendered {
    return assembleDetailedForSourcePoseInner(gpa, avb_data, pose, false);
}

fn assembleDetailedForSourcePoseInner(
    gpa: std.mem.Allocator,
    avb_data: []const u8,
    pose: udi.PoseState,
    srcand: bool,
) !Rendered {
    const asset = try avb_asset.parse(avb_data);
    var table = try avb_asset.parsePoseTable(gpa, avb_data);
    defer table.deinit(gpa);
    const selected = selectSourcePose(table.records, asset.kind, asset.flags.other_mapped, pose);

    if (asset.kind == .simple_avatar) {
        const record = selected.body orelse return error.PoseNotFound;
        var image = try bgb.decodeImageRef(gpa, avb_data, record.images[0]);
        const crop = try takePaddedSimpleCard(gpa, &image);
        if (srcand) keySrcAndMatte(image);
        return .{
            .image = image,
            .face_x = remappedSimpleFaceX(image, record.face.x, crop),
            .head_height = simpleHeadHeight(image.height),
            .requested = selected.requested,
            .generated_standing = isGeneratedStanding(crop.applied, image),
        };
    }

    const face_record = selected.face orelse return error.PoseNotFound;
    const torso_record = selected.torso orelse return error.PoseNotFound;
    var head = try bgb.decodeImageRef(gpa, avb_data, face_record.images[0]);
    defer head.deinit(gpa);
    var body = try bgb.decodeImageRef(gpa, avb_data, torso_record.images[0]);
    defer body.deinit(gpa);
    if (srcand) {
        keySrcAndMatte(head);
        keySrcAndMatte(body);
    }
    const anchors = bgb.NeckAnchors{
        .head = .{
            .x = @as(i32, face_record.center.x) - face_record.delta.x,
            .y = @as(i32, face_record.center.y) - face_record.delta.y,
        },
        .body = .{ .x = torso_record.center.x, .y = torso_record.center.y },
    };
    const image = try joinExact(gpa, anchors, head, body);
    const dx = anchors.body.x - anchors.head.x;
    const dy = anchors.body.y - anchors.head.y;
    const bit_left = @min(@as(i32, 0), dx);
    const bit_top = @min(@as(i32, 0), dy);
    return .{
        .image = image,
        .face_x = @as(i32, face_record.face.x) + dx - bit_left,
        .head_height = dy + @as(i32, @intCast(head.height)) - bit_top,
        .requested = selected.requested,
    };
}

pub fn assembleDetailedAnalysis(gpa: std.mem.Allocator, avb_data: []const u8, analysis: *const emotion_mod.TextAnalysis) !Rendered {
    return assembleDetailedAnalysisInner(gpa, avb_data, analysis, false);
}

fn assembleDetailedAnalysisInner(
    gpa: std.mem.Allocator,
    avb_data: []const u8,
    analysis: *const emotion_mod.TextAnalysis,
    srcand: bool,
) !Rendered {
    const asset = try avb_asset.parse(avb_data);
    var table = try avb_asset.parsePoseTable(gpa, avb_data);
    defer table.deinit(gpa);
    if (asset.kind == .simple_avatar) {
        const choice = selectAvailable(table.records, analysis, .body, null) orelse neutralChoice();
        const record = bgb.selectPose(table.records, .body, choice.emotion.assetIndex(), choice.intensity) orelse
            return error.PoseNotFound;
        var image = try bgb.decodePoseForEmotion(gpa, avb_data, .body, choice.emotion.assetIndex(), choice.intensity);
        const crop = try takePaddedSimpleCard(gpa, &image);
        if (srcand) keySrcAndMatte(image);
        return .{
            .image = image,
            .face_x = remappedSimpleFaceX(image, record.face.x, crop),
            .head_height = simpleHeadHeight(image.height),
            .generated_standing = isGeneratedStanding(crop.applied, image),
        };
    }

    const face_choice = selectAvailable(table.records, analysis, .face, false) orelse neutralChoice();
    const torso_choice = selectAvailable(table.records, analysis, .torso, true) orelse neutralChoice();
    const face_record = bgb.selectPose(table.records, .face, face_choice.emotion.assetIndex(), face_choice.intensity) orelse
        return error.PoseNotFound;
    const torso_record = bgb.selectPose(table.records, .torso, torso_choice.emotion.assetIndex(), torso_choice.intensity) orelse
        return error.PoseNotFound;
    var head = try bgb.decodePoseForEmotion(
        gpa,
        avb_data,
        .face,
        face_choice.emotion.assetIndex(),
        face_choice.intensity,
    );
    defer head.deinit(gpa);
    var body = try bgb.decodePoseForEmotion(
        gpa,
        avb_data,
        .torso,
        torso_choice.emotion.assetIndex(),
        torso_choice.intensity,
    );
    defer body.deinit(gpa);
    if (srcand) {
        keySrcAndMatte(head);
        keySrcAndMatte(body);
    }
    const anchors = bgb.NeckAnchors{
        .head = .{
            .x = @as(i32, face_record.center.x) - face_record.delta.x,
            .y = @as(i32, face_record.center.y) - face_record.delta.y,
        },
        .body = .{ .x = torso_record.center.x, .y = torso_record.center.y },
    };
    const image = try joinExact(gpa, anchors, head, body);
    const dx = anchors.body.x - anchors.head.x;
    const dy = anchors.body.y - anchors.head.y;
    const bit_left = @min(@as(i32, 0), dx);
    const bit_top = @min(@as(i32, 0), dy);
    return .{
        .image = image,
        .face_x = @as(i32, face_record.face.x) + dx - bit_left,
        .head_height = dy + @as(i32, @intCast(head.height)) - bit_top,
    };
}

fn neutralChoice() emotion_mod.EmotionOption {
    return .{ .emotion = .neutral, .intensity = 0, .priority = 0 };
}

fn selectAvailable(
    records: []const avb_asset.PoseRecord,
    analysis: *const emotion_mod.TextAnalysis,
    layer: avb_asset.PoseLayer,
    gesture: ?bool,
) ?emotion_mod.EmotionOption {
    var best: ?emotion_mod.EmotionOption = null;
    for (analysis.slice()) |option| {
        if (gesture) |want_gesture| {
            if (option.emotion.isGesture() != want_gesture) continue;
        }
        if (bgb.selectPose(records, layer, option.emotion.assetIndex(), option.intensity) == null) continue;
        if (best == null or option.priority > best.?.priority) best = option;
    }
    return best;
}

/// `CBodySingle::GetDimInfo` at `avatar.cpp:63`:
/// `headHeight = ydim/2; // for now, be conservative -- head = half body!`
/// Authored `face.y` is unused for simple-avatar layout. Generated Color/HD
/// cards are cropped to the opaque silhouette first so `ydim` is the figure,
/// not the 240×280 pad. Do not replace this with `face.y`.
fn simpleHeadHeight(image_height: u32) i32 {
    return @intCast(image_height / 2);
}

fn isGeneratedStanding(cropped_card: bool, image: Image) bool {
    return cropped_card and image.height >= 80;
}

fn clampedFaceX(face_x: i32, width: u32) i32 {
    if (width == 0) return 0;
    if (face_x < 0 or face_x > @as(i32, @intCast(width))) return @intCast(width / 2);
    return face_x;
}

/// Packager dummy `face` is `(120, 60)` on the 240-wide card (`package_generated_avb.py`).
/// After the ink-run crop that point often sits in the right-hand paper, so balloon
/// tails would aim at the pad instead of the head.
fn remappedSimpleFaceX(image: Image, face_x: i32, crop: SimpleCardCrop) i32 {
    const local = face_x - crop.origin_x;
    if (!crop.applied) return clampedFaceX(face_x, image.width);
    const ink = paperInkBounds(image) orelse return clampedFaceX(local, image.width);
    if (local >= @as(i32, @intCast(ink.x)) and local <= @as(i32, @intCast(ink.x + ink.w)))
        return local;
    const head_h = @max(@as(u32, 1), ink.h / 2);
    if (paperInkCenterX(image, ink.x, ink.y, ink.w, head_h)) |cx| return @intCast(cx);
    return @intCast(ink.x + ink.w / 2);
}

/// Packager canvas from `tools/package_generated_avb.py`. Authored simple
/// poses stay well below this; they keep their decoded DIB dimensions.
fn isPaddedSimpleCard(image: Image, bbox: Bounds) bool {
    if (image.width < 200 or image.height < 240) return false;
    return bbox.w + 8 < image.width or bbox.h + 8 < image.height;
}

fn paperInkPixel(image: Image, x: u32, y: u32) bool {
    if (x >= image.width or y >= image.height) return false;
    const pixel = image.pixels[y * image.width + x];
    return (pixel >> 24) != 0 and (pixel & 0x00ffffff) != 0x00ffffff;
}

fn paperInkBounds(image: Image) ?Bounds {
    var min_x: u32 = image.width;
    var min_y: u32 = image.height;
    var max_x: u32 = 0;
    var max_y: u32 = 0;
    var y: u32 = 0;
    while (y < image.height) : (y += 1) {
        var x: u32 = 0;
        while (x < image.width) : (x += 1) {
            if (!paperInkPixel(image, x, y)) continue;
            min_x = @min(min_x, x);
            min_y = @min(min_y, y);
            max_x = @max(max_x, x + 1);
            max_y = @max(max_y, y + 1);
        }
    }
    if (min_x >= max_x or min_y >= max_y) return null;
    return .{ .x = min_x, .y = min_y, .w = max_x - min_x, .h = max_y - min_y };
}

fn columnHasPaperInk(image: Image, x: u32) bool {
    var y: u32 = 0;
    while (y < image.height) : (y += 1) {
        if (paperInkPixel(image, x, y)) return true;
    }
    return false;
}

fn paperInkCenterX(image: Image, x: u32, y: u32, w: u32, h: u32) ?u32 {
    var weighted: u64 = 0;
    var mass: u64 = 0;
    var row: u32 = 0;
    while (row < h) : (row += 1) {
        var col: u32 = 0;
        while (col < w) : (col += 1) {
            if (!paperInkPixel(image, x + col, y + row)) continue;
            weighted += x + col;
            mass += 1;
        }
    }
    if (mass == 0) return null;
    return @intCast(weighted / mass);
}

/// Generated HD/Color cards sometimes store a wrap sliver to the right of the
/// real figure. Layout must use the widest ink column-run, not the bbox of
/// every non-white pixel.
fn largestPaperInkRun(image: Image) ?Bounds {
    var best_x0: u32 = 0;
    var best_x1: u32 = 0;
    var x: u32 = 0;
    while (x < image.width) {
        if (!columnHasPaperInk(image, x)) {
            x += 1;
            continue;
        }
        var x1 = x + 1;
        while (x1 < image.width and columnHasPaperInk(image, x1)) : (x1 += 1) {}
        if (x1 - x > best_x1 - best_x0) {
            best_x0 = x;
            best_x1 = x1;
        }
        x = x1;
    }
    if (best_x1 <= best_x0) return paperInkBounds(image);

    var min_y: u32 = image.height;
    var max_y: u32 = 0;
    var y: u32 = 0;
    while (y < image.height) : (y += 1) {
        var col = best_x0;
        while (col < best_x1) : (col += 1) {
            if (!paperInkPixel(image, col, y)) continue;
            min_y = @min(min_y, y);
            max_y = @max(max_y, y + 1);
        }
    }
    if (min_y >= max_y) return paperInkBounds(image);
    return .{ .x = best_x0, .y = min_y, .w = best_x1 - best_x0, .h = max_y - min_y };
}

/// Packager `normalize_pose` keeps 12px of paper around the silhouette. Grow
/// the widest ink run by that much so hair/arm anti-alias is not flush with
/// the dest rect. Stop before the next ink column-run so a wrap sliver stays out.
const generated_card_pad: u32 = 12;

fn expandPaperInkRun(image: Image, run: Bounds) Bounds {
    var x0 = run.x;
    var x1 = run.x + run.w;
    var left: u32 = 0;
    while (left < generated_card_pad and x0 > 0) {
        if (columnHasPaperInk(image, x0 - 1)) break;
        x0 -= 1;
        left += 1;
    }
    var right: u32 = 0;
    while (right < generated_card_pad and x1 < image.width) {
        if (columnHasPaperInk(image, x1)) break;
        x1 += 1;
        right += 1;
    }
    const top_pad = @min(generated_card_pad, run.y);
    const bot_room = image.height - (run.y + run.h);
    const bot_pad = @min(generated_card_pad, bot_room);
    return .{
        .x = x0,
        .y = run.y - top_pad,
        .w = x1 - x0,
        .h = run.h + top_pad + bot_pad,
    };
}

pub const SimpleCardCrop = struct {
    origin_x: i32 = 0,
    applied: bool = false,
};

/// Crop a generated 240×280 white card to the ink silhouette plus paper pad.
/// `origin_x` is the discarded left so `face.x` can be remapped.
pub fn takePaddedSimpleCard(gpa: std.mem.Allocator, image: *Image) !SimpleCardCrop {
    const full = paperInkBounds(image.*) orelse return .{};
    if (!isPaddedSimpleCard(image.*, full)) return .{};
    const run = largestPaperInkRun(image.*) orelse full;
    const bbox = expandPaperInkRun(image.*, run);
    const cropped = try copyRect(gpa, image.*, bbox.x, bbox.y, bbox.w, bbox.h);
    image.deinit(gpa);
    image.* = cropped;
    return .{ .origin_x = @intCast(bbox.x), .applied = true };
}

/// `CBodyCam::DrawBody` calls `DrawBody(..., FALSE)` and `CBodySingle` uses
/// `SRCAND`. Exact white is the paper matte: it leaves the destination
/// unchanged. Chrome RGBA blits must key that matte or the figure becomes a
/// white rectangle on the roster / body camera.
pub fn keySrcAndMatte(image: Image) void {
    for (image.pixels) |*pixel| {
        if (pixel.* & 0x00ffffff == 0x00ffffff) pixel.* = 0x00000000;
    }
}

/// Member-list / CAST portrait. Microsoft uses `CAvatarX::GetIconPose`
/// (`avatar.h:251`) — the authored `AK_ICON` mugshot — for roster and title
/// stars. Generated HD packages smash the whole simple-avatar body into 64×64
/// without preserving aspect; those fail `GetIconPose` and fall back to the
/// silhouette mugshot. Authored simple icons keep other sizes.
pub fn chromePortrait(gpa: std.mem.Allocator, avb_data: []const u8) !Image {
    const asset = try avb_asset.parse(avb_data);
    var icon = try bgb.decodeIcon(gpa, avb_data);
    errdefer icon.deinit(gpa);
    keySrcAndMatte(icon);

    if (asset.kind == .simple_avatar) {
        const analysis = emotion_mod.analyzeText("");
        var rendered = try assembleDetailedAnalysisInner(gpa, avb_data, &analysis, true);
        defer rendered.deinit(gpa);
        // Generated Color/HD packages always store a 64×64 AK_ICON. HD smashes
        // the whole body; Color portraits can still be a hair pancake. Both
        // read better as a silhouette mugshot. Authored simple icons keep
        // other sizes and stay on GetIconPose.
        if (icon.width == 64 and icon.height == 64) {
            const portrait = try cropHeadPortrait(gpa, rendered.image, rendered.head_height);
            icon.deinit(gpa);
            return portrait;
        }
    }

    const trimmed = trimTransparent(gpa, icon) catch return icon;
    icon.deinit(gpa);
    return trimmed;
}

/// Title-panel starring icon. `CBodyUnary` draws `m_icon` (`panel.cpp:1437`)
/// through `CBodySingle::DrawBody`. Generated Color/HD packages store a
/// smashed or pancake 64×64 `AK_ICON` on a much larger pose card; those
/// stars reuse the chrome silhouette mugshot. Authored icons — including
/// 64×64 simple-avatar mugshots whose pose stays near the icon — stay the
/// decoded `AK_ICON` so legacy title goldens do not move.
pub fn titleStarIcon(gpa: std.mem.Allocator, avb_data: []const u8) !Image {
    var icon = try bgb.decodeIcon(gpa, avb_data);
    const asset = try avb_asset.parse(avb_data);
    if (asset.kind != .simple_avatar or icon.width != 64 or icon.height != 64)
        return icon;

    var pose = try assemble(gpa, avb_data, 0, 0);
    defer pose.deinit(gpa);
    if (!generatedCardIcon(icon, pose)) return icon;

    icon.deinit(gpa);
    return chromePortrait(gpa, avb_data);
}

/// Generated Color/HD cards are 240×280-class. Authored simple poses stay
/// near their 64×64 `AK_ICON`, so `GetIconPose` remains a usable mugshot.
fn generatedCardIcon(icon: Image, body: Image) bool {
    if (icon.width != 64 or icon.height != 64) return false;
    return body.width > icon.width * 2 or body.height > icon.height * 2;
}

/// Body-camera figure. `CBodyCam::DrawBody(..., FALSE)` (`bodycam.cpp:499`):
/// full body, no aura/nimbus, `SRCAND` paper (white leaves dest). Layers are
/// keyed before the neck join so a head DIB's white sticker cannot cut the
/// torso — the same ROP as `CBodyDouble::DrawBody`.
pub fn chromeBody(gpa: std.mem.Allocator, avb_data: []const u8, text: []const u8) !Image {
    const analysis = emotion_mod.analyzeText(text);
    var rendered = try assembleDetailedAnalysisInner(gpa, avb_data, &analysis, true);
    return takeTrimmed(gpa, &rendered.image);
}

/// Body-camera figure for an explicit cooked UDI / mood-dial pose.
pub fn chromeBodyForSourcePose(gpa: std.mem.Allocator, avb_data: []const u8, pose: udi.PoseState) !Image {
    var rendered = try assembleDetailedForSourcePoseInner(gpa, avb_data, pose, true);
    return takeTrimmed(gpa, &rendered.image);
}

fn takeTrimmed(gpa: std.mem.Allocator, image: *Image) !Image {
    const trimmed = trimTransparent(gpa, image.*) catch return image.*;
    image.deinit(gpa);
    return trimmed;
}

/// Generated HD icons are `resize((64, 64))` of the neutral pose. Authored
/// mugshots and Color `--portrait-icon` crops do not track that stretch.
fn iconLooksLikeStretchedBody(icon: Image, body: Image) bool {
    if (icon.width == 0 or icon.height == 0 or body.width == 0 or body.height == 0) return false;
    if (icon.width != 64 or icon.height != 64) return false;
    if (body.height <= icon.height * 2 and body.width <= icon.width * 2) return false;

    var opaque_icon: usize = 0;
    var matches: usize = 0;
    var samples: usize = 0;
    var y: u32 = 0;
    while (y < icon.height) : (y += 1) {
        var x: u32 = 0;
        while (x < icon.width) : (x += 1) {
            const icon_opaque = icon.pixels[y * icon.width + x] >> 24 != 0;
            if (icon_opaque) opaque_icon += 1;
            const bx = @min(body.width - 1, @as(u32, @intCast(@divTrunc(@as(u64, x) * body.width, icon.width))));
            const by = @min(body.height - 1, @as(u32, @intCast(@divTrunc(@as(u64, y) * body.height, icon.height))));
            const body_opaque = body.pixels[by * body.width + bx] >> 24 != 0;
            samples += 1;
            if (icon_opaque == body_opaque) matches += 1;
        }
    }
    const coverage = opaque_icon * 100 / (@as(usize, icon.width) * icon.height);
    const agreement = matches * 100 / samples;
    return coverage >= 25 and agreement >= 80;
}

fn cropHeadPortrait(gpa: std.mem.Allocator, image: Image, head_height: i32) !Image {
    // Generated cards are cropped to the opaque silhouette first. A half-body
    // band that is wider than it is tall contain-fits into a pancake and reads
    // as a waist cut; keep the full silhouette instead of 5:4-clipping arms.
    const bbox = opaqueBounds(image) orelse return copyRect(gpa, image, 0, 0, image.width, image.height);
    const half: u32 = if (head_height > 0) @intCast(head_height) else bbox.h / 2;
    const crop_h = @min(bbox.h, @max(@as(u32, 64), half));
    // Generated standing figures are taller than a mugshot slot. Returning the
    // full silhouette lets CAST/gallery contain-fit the whole woman instead of
    // a waist-cut head band or a 5:4 side clip.
    if (bbox.h >= 160 and bbox.w >= 80) {
        return copyRect(gpa, image, bbox.x, bbox.y, bbox.w, bbox.h);
    }
    const band = opaqueBoundsIn(image, bbox.x, bbox.y, bbox.w, crop_h) orelse bbox;
    var head = try copyRect(gpa, image, band.x, band.y, band.w, band.h);
    const trimmed = trimTransparent(gpa, head) catch return head;
    head.deinit(gpa);
    return trimmed;
}

const Bounds = struct { x: u32, y: u32, w: u32, h: u32 };

fn opaqueBounds(image: Image) ?Bounds {
    return opaqueBoundsIn(image, 0, 0, image.width, image.height);
}

fn opaquePixel(image: Image, x: u32, y: u32) bool {
    if (x >= image.width or y >= image.height) return false;
    return image.pixels[y * image.width + x] >> 24 != 0;
}

fn hasOpaqueNeighbor(image: Image, x: u32, y: u32) bool {
    const x0 = if (x == 0) 0 else x - 1;
    const y0 = if (y == 0) 0 else y - 1;
    const x1 = @min(image.width - 1, x + 1);
    const y1 = @min(image.height - 1, y + 1);
    var row = y0;
    while (row <= y1) : (row += 1) {
        var col = x0;
        while (col <= x1) : (col += 1) {
            if (col == x and row == y) continue;
            if (opaquePixel(image, col, row)) return true;
        }
    }
    return false;
}

fn opaqueBoundsIn(image: Image, x: u32, y: u32, w: u32, h: u32) ?Bounds {
    var min_x: u32 = image.width;
    var min_y: u32 = image.height;
    var max_x: u32 = 0;
    var max_y: u32 = 0;
    var row: u32 = 0;
    while (row < h) : (row += 1) {
        var col: u32 = 0;
        while (col < w) : (col += 1) {
            const px = x + col;
            const py = y + row;
            if (!opaquePixel(image, px, py) or !hasOpaqueNeighbor(image, px, py)) continue;
            min_x = @min(min_x, px);
            min_y = @min(min_y, py);
            max_x = @max(max_x, px + 1);
            max_y = @max(max_y, py + 1);
        }
    }
    if (min_x >= max_x or min_y >= max_y) return null;
    return .{ .x = min_x, .y = min_y, .w = max_x - min_x, .h = max_y - min_y };
}

fn opaqueCenterX(image: Image, x: u32, y: u32, w: u32, h: u32) ?u32 {
    var weighted: u64 = 0;
    var mass: u64 = 0;
    var row: u32 = 0;
    while (row < h) : (row += 1) {
        var col: u32 = 0;
        while (col < w) : (col += 1) {
            if (image.pixels[(y + row) * image.width + (x + col)] >> 24 == 0) continue;
            weighted += x + col;
            mass += 1;
        }
    }
    if (mass == 0) return null;
    return @intCast(weighted / mass);
}

fn copyRect(gpa: std.mem.Allocator, image: Image, x: u32, y: u32, w: u32, h: u32) !Image {
    const pixels = try gpa.alloc(u32, @as(usize, w) * h);
    var row: u32 = 0;
    while (row < h) : (row += 1) {
        const src = (y + row) * image.width + x;
        const dst = row * w;
        @memcpy(pixels[dst .. dst + w], image.pixels[src .. src + w]);
    }
    return .{ .width = w, .height = h, .pixels = pixels };
}

fn trimTransparent(gpa: std.mem.Allocator, image: Image) !Image {
    const bbox = opaqueBounds(image) orelse return error.PoseNotFound;
    return copyRect(gpa, image, bbox.x, bbox.y, bbox.w, bbox.h);
}

fn joinExact(gpa: std.mem.Allocator, anchors: bgb.NeckAnchors, head: Image, body: Image) !Image {
    const dx = anchors.body.x - anchors.head.x;
    const dy = anchors.body.y - anchors.head.y;

    const bw: i32 = @intCast(body.width);
    const bh: i32 = @intCast(body.height);
    const hw: i32 = @intCast(head.width);
    const hh: i32 = @intCast(head.height);
    const body_x = @max(@as(i32, 0), -dx);
    const body_y = @max(@as(i32, 0), -dy);
    const head_x = body_x + dx;
    const head_y = body_y + dy;
    const W: u32 = @intCast(@max(body_x + bw, head_x + hw));
    const H: u32 = @intCast(@max(body_y + bh, head_y + hh));

    var c = try Canvas.init(gpa, W, H);
    defer c.deinit(gpa);
    c.clear(0x00000000);
    composite(&c, body.pixels, body.width, body.height, body_x, body_y);
    composite(&c, head.pixels, head.width, head.height, head_x, head_y);
    return dupe(gpa, &c);
}

fn solo(gpa: std.mem.Allocator, img: Image) !Image {
    var c = try Canvas.init(gpa, img.width, img.height);
    defer c.deinit(gpa);
    c.clear(0x00000000);
    composite(&c, img.pixels, img.width, img.height, 0, 0);
    return dupe(gpa, &c);
}

fn dupe(gpa: std.mem.Allocator, c: *const Canvas) !Image {
    const px = try gpa.dupe(u32, c.px);
    return .{ .width = c.width, .height = c.height, .pixels = px };
}

/// Composite a transparent-keyed authored image onto `c`.
pub fn composite(c: *Canvas, src: []const u32, sw: u32, sh: u32, dx: i32, dy: i32) void {
    var y: u32 = 0;
    while (y < sh) : (y += 1) {
        var x: u32 = 0;
        while (x < sw) : (x += 1) {
            const p = src[y * sw + x];
            if (p >> 24 == 0) continue;
            const ox = dx + @as(i32, @intCast(x));
            const oy = dy + @as(i32, @intCast(y));
            if (ox < 0 or oy < 0 or ox >= c.width or oy >= c.height) continue;
            c.px[@as(usize, @intCast(oy)) * c.width + @as(usize, @intCast(ox))] = p;
        }
    }
}

test "assemble produces a figure with transparent margins and opaque ink" {
    const gpa = std.testing.allocator;
    const anna = @embedFile("../assets/testdata/anna.avb");
    var fig = try assemble(gpa, anna, 0, 0);
    defer fig.deinit(gpa);
    try std.testing.expect(fig.width > 0 and fig.height > 0);
    var opaque_px: usize = 0;
    for (fig.pixels) |p| {
        if (p >> 24 != 0) opaque_px += 1;
    }
    try std.testing.expect(opaque_px > 1000);
}

test "chrome portraits crop simple-avatar heads and key the SRCAND paper matte" {
    const gpa = std.testing.allocator;
    const jordan = @embedFile("../assets/testdata/jordan.avb");
    var body = try assembleDetailedForText(gpa, jordan, "");
    defer body.deinit(gpa);
    var portrait = try chromePortrait(gpa, jordan);
    defer portrait.deinit(gpa);
    try std.testing.expect(portrait.height <= @as(u32, @intCast(body.head_height)));
    try std.testing.expect(portrait.height < body.image.height);
    try std.testing.expect(portrait.width > 0);
    for (portrait.pixels) |pixel| try std.testing.expect(pixel & 0x00ffffff != 0x00ffffff);

    const hd = @embedFile("../assets/generated/anna-reimagined-hd-v1.avb");
    var smashed = try bgb.decodeIcon(gpa, hd);
    defer smashed.deinit(gpa);
    var hd_portrait = try chromePortrait(gpa, hd);
    defer hd_portrait.deinit(gpa);
    try std.testing.expect(hd_portrait.height > smashed.height or hd_portrait.width != smashed.width);
    for (hd_portrait.pixels) |pixel| try std.testing.expect(pixel & 0x00ffffff != 0x00ffffff);

    const color = @embedFile("../assets/generated/anna-color-hd-v1.avb");
    var color_portrait = try chromePortrait(gpa, color);
    defer color_portrait.deinit(gpa);
    var colorful = false;
    for (color_portrait.pixels) |pixel| {
        if (pixel >> 24 == 0) continue;
        const red: u8 = @truncate(pixel >> 16);
        const green: u8 = @truncate(pixel >> 8);
        const blue: u8 = @truncate(pixel);
        if (red != green or green != blue) colorful = true;
    }
    try std.testing.expect(colorful);

    const anna = @embedFile("../assets/testdata/anna.avb");
    var icon = try bgb.decodeIcon(gpa, anna);
    defer icon.deinit(gpa);
    var mugshot = try chromePortrait(gpa, anna);
    defer mugshot.deinit(gpa);
    try std.testing.expect(mugshot.width > 0 and mugshot.height > 0);
    try std.testing.expect(mugshot.width <= icon.width);
    try std.testing.expect(mugshot.height <= icon.height);
}

test "title stars keep authored icons and replace smashed generated HD" {
    const gpa = std.testing.allocator;
    const anna = @embedFile("../assets/testdata/anna.avb");
    var authored = try bgb.decodeIcon(gpa, anna);
    defer authored.deinit(gpa);
    var star = try titleStarIcon(gpa, anna);
    defer star.deinit(gpa);
    try std.testing.expectEqual(authored.width, star.width);
    try std.testing.expectEqual(authored.height, star.height);
    try std.testing.expectEqualSlices(u32, authored.pixels, star.pixels);

    const hd = @embedFile("../assets/generated/anna-reimagined-hd-v1.avb");
    var smashed = try bgb.decodeIcon(gpa, hd);
    defer smashed.deinit(gpa);
    var hd_star = try titleStarIcon(gpa, hd);
    defer hd_star.deinit(gpa);
    var portrait = try chromePortrait(gpa, hd);
    defer portrait.deinit(gpa);
    try std.testing.expectEqual(portrait.width, hd_star.width);
    try std.testing.expectEqual(portrait.height, hd_star.height);
    try std.testing.expect(hd_star.width != smashed.width or hd_star.height != smashed.height);

    const jordan = @embedFile("../assets/testdata/jordan.avb");
    var jordan_icon = try bgb.decodeIcon(gpa, jordan);
    defer jordan_icon.deinit(gpa);
    var jordan_star = try titleStarIcon(gpa, jordan);
    defer jordan_star.deinit(gpa);
    try std.testing.expectEqual(jordan_icon.width, jordan_star.width);
    try std.testing.expectEqual(jordan_icon.height, jordan_star.height);
    try std.testing.expectEqualSlices(u32, jordan_icon.pixels, jordan_star.pixels);

    const color = @embedFile("../assets/generated/anna-color-hd-v1.avb");
    var color_star = try titleStarIcon(gpa, color);
    defer color_star.deinit(gpa);
    var color_portrait = try chromePortrait(gpa, color);
    defer color_portrait.deinit(gpa);
    try std.testing.expectEqual(color_portrait.width, color_star.width);
    try std.testing.expectEqual(color_portrait.height, color_star.height);
    try std.testing.expect(color_star.height >= 80);
}

fn countOpaque(image: Image) usize {
    var count: usize = 0;
    for (image.pixels) |pixel| {
        if (pixel >> 24 != 0) count += 1;
    }
    return count;
}

test "chrome body SRCAND keeps torso ink under the head paper" {
    const gpa = std.testing.allocator;
    const anna = @embedFile("../assets/testdata/anna.avb");
    var punched = try assembleForText(gpa, anna, "");
    defer punched.deinit(gpa);
    keySrcAndMatte(punched);
    var chrome = try chromeBody(gpa, anna, "");
    defer chrome.deinit(gpa);
    try std.testing.expect(countOpaque(chrome) > countOpaque(punched));
}

test "HD chrome portraits reject smashed 64x64 bodies and Color keeps the mugshot" {
    const gpa = std.testing.allocator;
    const hd = @embedFile("../assets/generated/anna-reimagined-hd-v1.avb");
    var smashed = try bgb.decodeIcon(gpa, hd);
    defer smashed.deinit(gpa);
    keySrcAndMatte(smashed);
    var hd_card = try bgb.decodePoseForEmotion(gpa, hd, .body, 9, 0);
    defer hd_card.deinit(gpa);
    keySrcAndMatte(hd_card);
    try std.testing.expect(iconLooksLikeStretchedBody(smashed, hd_card));
    var hd_body = try chromeBody(gpa, hd, "");
    defer hd_body.deinit(gpa);
    var hd_portrait = try chromePortrait(gpa, hd);
    defer hd_portrait.deinit(gpa);
    try std.testing.expect(hd_portrait.height != smashed.height or hd_portrait.width != smashed.width);
    try std.testing.expect(hd_portrait.height >= 80);
    try std.testing.expect(countOpaque(hd_portrait) * 4 >= @as(usize, hd_portrait.width) * hd_portrait.height);

    const color = @embedFile("../assets/generated/anna-color-hd-v1.avb");
    var color_icon = try bgb.decodeIcon(gpa, color);
    defer color_icon.deinit(gpa);
    keySrcAndMatte(color_icon);
    var color_body = try chromeBody(gpa, color, "");
    defer color_body.deinit(gpa);
    try std.testing.expect(!iconLooksLikeStretchedBody(color_icon, color_body));
    var color_portrait = try chromePortrait(gpa, color);
    defer color_portrait.deinit(gpa);
    try std.testing.expect(color_portrait.height <= color_body.height);
}

test "Anna HD and Color female chrome is a full silhouette not a half-width or feet crop" {
    const gpa = std.testing.allocator;
    const blobs = [_][]const u8{
        @embedFile("../assets/generated/anna-reimagined-hd-v1.avb"),
        @embedFile("../assets/generated/anna-color-hd-v1.avb"),
    };
    for (blobs) |avb_data| {
        var assembled = try assembleDetailedForText(gpa, avb_data, "");
        defer assembled.deinit(gpa);
        try std.testing.expect(assembled.image.width < 200);
        try std.testing.expect(assembled.image.height < 240);
        try std.testing.expectEqual(simpleHeadHeight(assembled.image.height), assembled.head_height);
        try std.testing.expect(assembled.head_height * 5 >= @as(i32, @intCast(assembled.image.height)) * 2);

        var body = try chromeBody(gpa, avb_data, "");
        defer body.deinit(gpa);
        var portrait = try chromePortrait(gpa, avb_data);
        defer portrait.deinit(gpa);

        try std.testing.expect(body.width >= 80);
        try std.testing.expect(body.width < 160);
        try std.testing.expect(body.height >= 160);
        try std.testing.expect(body.height > body.width);
        try std.testing.expect(portrait.width * 4 >= body.width * 3);
        try std.testing.expect(portrait.height >= 80);
        try std.testing.expect(portrait.height <= body.height);
        try std.testing.expect(portrait.width > body.width / 2);

        const bbox = opaqueBounds(body).?;
        try std.testing.expectEqual(@as(u32, 0), bbox.x);
        try std.testing.expect(bbox.w * 8 >= body.width * 7);
        var empty_run: u32 = 0;
        var col: u32 = 0;
        while (col < body.width) : (col += 1) {
            var ink = false;
            var row: u32 = 0;
            while (row < body.height) : (row += 1) {
                if (body.pixels[row * body.width + col] >> 24 != 0) {
                    ink = true;
                    break;
                }
            }
            if (ink) {
                empty_run = 0;
            } else {
                empty_run += 1;
                try std.testing.expect(empty_run < 12);
            }
        }
    }
}

test "chrome body keeps the full simple-avatar figure after keying white" {
    const gpa = std.testing.allocator;
    const color = @embedFile("../assets/generated/kevin-color-hd-v1.avb");
    var portrait = try chromePortrait(gpa, color);
    defer portrait.deinit(gpa);
    var body = try chromeBody(gpa, color, "");
    defer body.deinit(gpa);
    try std.testing.expect(body.height >= portrait.height);
    var transparent = false;
    for (body.pixels) |pixel| if (pixel >> 24 == 0) {
        transparent = true;
        break;
    };
    try std.testing.expect(transparent);
}

test "simple-avatar GetDimInfo keeps the source half-body head height" {
    const gpa = std.testing.allocator;
    const jordan = @embedFile("../assets/testdata/jordan.avb");
    var simple = try assembleDetailedForText(gpa, jordan, "ordinary text");
    defer simple.deinit(gpa);
    try std.testing.expectEqual(simpleHeadHeight(simple.image.height), simple.head_height);

    const color = @embedFile("../assets/generated/anna-color-hd-v1.avb");
    var generated = try assembleDetailedForText(gpa, color, "ordinary text");
    defer generated.deinit(gpa);
    try std.testing.expectEqual(avb_asset.Kind.simple_avatar, (try avb_asset.parse(color)).kind);
    try std.testing.expectEqual(simpleHeadHeight(generated.image.height), generated.head_height);
    // face.y is authored metadata, not the layout head band.
    try std.testing.expect(generated.head_height != generated.image.height);
    try std.testing.expect(generated.image.height < 240);
    try std.testing.expect(generated.image.width < 240);
}

test "authored simple face.x is unchanged and generated cards keep paper pad" {
    const gpa = std.testing.allocator;
    const jordan = @embedFile("../assets/testdata/jordan.avb");
    var table = try avb_asset.parsePoseTable(gpa, jordan);
    defer table.deinit(gpa);
    const analysis = emotion_mod.analyzeText("ordinary text");
    const choice = selectAvailable(table.records, &analysis, .body, null) orelse neutralChoice();
    const record = bgb.selectPose(table.records, .body, choice.emotion.assetIndex(), choice.intensity).?;
    var simple = try assembleDetailedForText(gpa, jordan, "ordinary text");
    defer simple.deinit(gpa);
    try std.testing.expectEqual(@as(i32, record.face.x), simple.face_x);

    const blobs = [_][]const u8{
        @embedFile("../assets/generated/anna-reimagined-hd-v1.avb"),
        @embedFile("../assets/generated/anna-color-hd-v1.avb"),
    };
    for (blobs) |avb_data| {
        var generated = try assembleDetailedForText(gpa, avb_data, "ordinary text");
        defer generated.deinit(gpa);
        const ink = paperInkBounds(generated.image).?;
        try std.testing.expect(ink.x >= 4);
        try std.testing.expect(ink.x + ink.w + 4 <= generated.image.width);
        try std.testing.expect(ink.y >= 4);
        try std.testing.expect(generated.face_x >= @as(i32, @intCast(ink.x)));
        try std.testing.expect(generated.face_x <= @as(i32, @intCast(ink.x + ink.w)));
        try std.testing.expect(generated.face_x * 4 > @as(i32, @intCast(generated.image.width)));
        try std.testing.expect(generated.face_x * 4 < @as(i32, @intCast(generated.image.width)) * 3);
        try std.testing.expect(generated.image.width < 140);
        try std.testing.expect(generated.image.height < 230);
    }
}

test "text rules select simple-avatar whole-body expressions" {
    const gpa = std.testing.allocator;
    const jordan = @embedFile("../assets/testdata/jordan.avb");
    var neutral = try assembleForText(gpa, jordan, "ordinary text");
    defer neutral.deinit(gpa);
    var laughing = try assembleForText(gpa, jordan, "LOL!!!");
    defer laughing.deinit(gpa);
    try std.testing.expect(!std.mem.eql(u32, neutral.pixels, laughing.pixels));
}

test "generated color avatars produce distinct requested mood poses" {
    const gpa = std.testing.allocator;
    const avatars = [_][]const u8{
        @embedFile("../assets/generated/anna-color-hd-v1.avb"),     @embedFile("../assets/generated/armando-color-hd-v1.avb"),
        @embedFile("../assets/generated/bolo-color-hd-v1.avb"),     @embedFile("../assets/generated/cro-color-hd-v1.avb"),
        @embedFile("../assets/generated/dan-color-hd-v1.avb"),      @embedFile("../assets/generated/denise-color-hd-v1.avb"),
        @embedFile("../assets/generated/hugh-color-hd-v1.avb"),     @embedFile("../assets/generated/jordan-color-hd-v1.avb"),
        @embedFile("../assets/generated/kevin-color-hd-v1.avb"),    @embedFile("../assets/generated/kwensa-color-hd-v1.avb"),
        @embedFile("../assets/generated/lance-color-hd-v1.avb"),    @embedFile("../assets/generated/lynnea-color-hd-v1.avb"),
        @embedFile("../assets/generated/margaret-color-hd-v1.avb"), @embedFile("../assets/generated/maynard-color-hd-v1.avb"),
        @embedFile("../assets/generated/mike-color-hd-v1.avb"),     @embedFile("../assets/generated/rebecca-color-hd-v1.avb"),
        @embedFile("../assets/generated/sage-color-hd-v1.avb"),     @embedFile("../assets/generated/scotty-color-hd-v1.avb"),
        @embedFile("../assets/generated/susan-color-hd-v1.avb"),    @embedFile("../assets/generated/tiki-color-hd-v2.avb"),
        @embedFile("../assets/generated/tongtyed-color-hd-v1.avb"), @embedFile("../assets/generated/xeno-color-hd-v1.avb"),
    };
    inline for (avatars) |avatar| {
        const happy = try poseStateForEmotion(gpa, avatar, .happy, 255);
        const angry = try poseStateForEmotion(gpa, avatar, .angry, 255);
        try std.testing.expect(happy.requested and angry.requested);
        try std.testing.expect(happy.gesture.index != angry.gesture.index or happy.expression.index != angry.expression.index);
        var happy_image = try assembleDetailedForSourcePose(gpa, avatar, happy);
        defer happy_image.deinit(gpa);
        var angry_image = try assembleDetailedForSourcePose(gpa, avatar, angry);
        defer angry_image.deinit(gpa);
        try std.testing.expect(!std.mem.eql(u32, happy_image.image.pixels, angry_image.image.pixels));
    }
}

test "cooked UDI selects raw face and torso record ordinals" {
    const gpa = std.testing.allocator;
    const anna = @embedFile("../assets/testdata/anna.avb");
    var table = try avb_asset.parsePoseTable(gpa, anna);
    defer table.deinit(gpa);
    const pose = udi.PoseState{
        .gesture = .{ .index = 2, .emotion = 10, .intensity = 7 },
        .expression = .{ .index = 1, .emotion = 8, .intensity = 9 },
        .requested = true,
    };
    const selected = selectSourcePose(table.records, .avatar, false, pose);
    try std.testing.expect(selected.face.? == recordByOrdinal(table.records, .face, 1).?);
    try std.testing.expect(selected.torso.? == recordByOrdinal(table.records, .torso, 2).?);
    try std.testing.expect(selected.requested);

    var rendered = try assembleDetailedForSourcePose(gpa, anna, pose);
    defer rendered.deinit(gpa);
    try std.testing.expect(rendered.requested);
    try std.testing.expect(rendered.image.width > 0 and rendered.image.height > 0);
}

test "outgoing text pose serializes selected source ordinals and EmotionToBytes" {
    const gpa = std.testing.allocator;
    const anna = @embedFile("../assets/testdata/anna.avb");
    const neutral = try poseStateForText(gpa, anna, "ordinary words");
    try std.testing.expectEqual(@as(u8, 1), neutral.expression.emotion);
    try std.testing.expectEqual(@as(u8, 1), neutral.gesture.emotion);
    try std.testing.expectEqual(@as(u8, 0), neutral.expression.intensity);
    try std.testing.expectEqual(@as(u8, 0), neutral.gesture.intensity);
    try std.testing.expect(!neutral.requested);

    const expressive = try poseStateForText(gpa, anna, "Hello! LOL");
    var table = try avb_asset.parsePoseTable(gpa, anna);
    defer table.deinit(gpa);
    try std.testing.expect(
        recordByOrdinal(table.records, .face, expressive.expression.index).?.emotion_index == 8,
    );
    try std.testing.expect(
        recordByOrdinal(table.records, .torso, expressive.gesture.index).?.emotion_index == 10,
    );
    try std.testing.expectEqual(@as(u8, 8), expressive.expression.emotion);
    try std.testing.expectEqual(@as(u8, 10), expressive.gesture.emotion);
}

test "simple outgoing UDI stores body ordinal in gesture and pose in expression" {
    const gpa = std.testing.allocator;
    const jordan = @embedFile("../assets/testdata/jordan.avb");
    const state = try poseStateForText(gpa, jordan, "LOL");
    var table = try avb_asset.parsePoseTable(gpa, jordan);
    defer table.deinit(gpa);
    const body = recordByOrdinal(table.records, .body, state.gesture.index).?;
    try std.testing.expectEqual(@as(u8, 0), state.expression.index);
    try std.testing.expectEqual(sourceComponents(0, body.emotion_index, body.intensity).emotion, state.expression.emotion);
    try std.testing.expectEqual(@as(u8, 1), state.gesture.emotion);
    try std.testing.expectEqual(@as(u8, 0), state.gesture.intensity);
}

test "malformed direct UDI ordinal uses documented portable neutral fallback" {
    const gpa = std.testing.allocator;
    var table = try avb_asset.parsePoseTable(gpa, @embedFile("../assets/testdata/anna.avb"));
    defer table.deinit(gpa);
    const selected = selectSourcePose(table.records, .avatar, false, .{
        .gesture = .{ .index = 255, .emotion = 0, .intensity = 0 },
        .expression = .{ .index = 255, .emotion = 0, .intensity = 0 },
        .requested = false,
    });
    try std.testing.expect(selected.face.? == neutralRecord(table.records, .face).?);
    try std.testing.expect(selected.torso.? == neutralRecord(table.records, .torso).?);
}

test "OTHERMAPPED follows BytesToEmotion exact emotion and scaled intensity" {
    const gpa = std.testing.allocator;
    var table = try avb_asset.parsePoseTable(gpa, @embedFile("../assets/testdata/anna.avb"));
    defer table.deinit(gpa);
    const selected = selectSourcePose(table.records, .avatar, true, .{
        .gesture = .{ .index = 99, .emotion = 10, .intensity = 10 },
        .expression = .{ .index = 99, .emotion = 8, .intensity = 10 },
        .requested = false,
    });
    try std.testing.expectEqual(@as(u16, 8), selected.face.?.emotion_index);
    try std.testing.expectEqual(@as(u16, 10), selected.torso.?.emotion_index);

    // BytesToEmotion maps an out-of-range emotion to neutral, and index zero
    // has the same float value as EM_HAPPY in the source table.
    const fallback = selectSourcePose(table.records, .avatar, true, .{
        .gesture = .{ .index = 0, .emotion = 250, .intensity = 0 },
        .expression = .{ .index = 0, .emotion = 0, .intensity = 10 },
        .requested = false,
    });
    try std.testing.expectEqual(@as(u16, 1), fallback.face.?.emotion_index);
    try std.testing.expectEqual(@as(u16, 9), fallback.torso.?.emotion_index);
}

test "Anna Color uses peach skin and a red top instead of a purple wash" {
    const gpa = std.testing.allocator;
    const color = @embedFile("../assets/generated/anna-color-hd-v1.avb");
    var assembled = try assembleDetailedForText(gpa, color, "");
    defer assembled.deinit(gpa);
    try std.testing.expect(assembled.generated_standing);
    try std.testing.expect(assembled.image.height > assembled.image.width);
    try std.testing.expect(assembled.image.height >= 160);
    var top_edge: usize = 0;
    var bot_edge: usize = 0;
    const edge_h = @max(@as(u32, 1), assembled.image.height / 16);
    for (assembled.image.pixels, 0..) |pixel, index| {
        if (pixel >> 24 == 0) continue;
        if (pixel & 0x00ffffff == 0x00ffffff) continue;
        const y = index / assembled.image.width;
        if (y < edge_h) top_edge += 1;
        if (y + edge_h >= assembled.image.height) bot_edge += 1;
    }
    try std.testing.expect(top_edge > 4);
    try std.testing.expect(bot_edge > 4);

    var peach: usize = 0;
    var red: usize = 0;
    var purple: usize = 0;
    for (assembled.image.pixels) |pixel| {
        if (pixel >> 24 == 0) continue;
        if (pixel & 0x00ffffff == 0x00ffffff) continue;
        const red_ch: i32 = @as(u8, @truncate(pixel >> 16));
        const green_ch: i32 = @as(u8, @truncate(pixel >> 8));
        const blue_ch: i32 = @as(u8, @truncate(pixel));
        if (red_ch == green_ch and green_ch == blue_ch) continue;
        const max_c = @max(red_ch, @max(green_ch, blue_ch));
        const min_c = @min(red_ch, @min(green_ch, blue_ch));
        if (max_c < 40) continue;
        if (max_c - min_c < 20) continue;
        if (red_ch > green_ch + 15 and red_ch > blue_ch + 15 and green_ch + 25 > blue_ch)
            peach += 1;
        if (red_ch > 120 and red_ch > green_ch + 40 and red_ch > blue_ch + 40 and green_ch < 90)
            red += 1;
        if (blue_ch + 10 > red_ch and (blue_ch > green_ch + 20 or red_ch > green_ch + 20) and
            @abs(red_ch - blue_ch) < 60)
            purple += 1;
    }
    try std.testing.expect(peach > 80);
    try std.testing.expect(red > 40);
    try std.testing.expect(peach > purple);
    try std.testing.expect(red > purple);
}

test "simple SetIndices uses gesture ordinal while OTHERMAPPED uses expression" {
    const gpa = std.testing.allocator;
    var table = try avb_asset.parsePoseTable(gpa, @embedFile("../assets/testdata/jordan.avb"));
    defer table.deinit(gpa);
    const pose = udi.PoseState{
        .gesture = .{ .index = 1, .emotion = 9, .intensity = 0 },
        .expression = .{ .index = 0, .emotion = 8, .intensity = 10 },
        .requested = true,
    };
    const direct = selectSourcePose(table.records, .simple_avatar, false, pose);
    try std.testing.expect(direct.body.? == recordByOrdinal(table.records, .body, 1).?);
    const mapped = selectSourcePose(table.records, .simple_avatar, true, pose);
    try std.testing.expectEqual(@as(u16, 8), mapped.body.?.emotion_index);
}
