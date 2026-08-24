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
    const asset = try avb_asset.parse(avb_data);
    var table = try avb_asset.parsePoseTable(gpa, avb_data);
    defer table.deinit(gpa);
    const selected = selectSourcePose(table.records, asset.kind, asset.flags.other_mapped, pose);

    if (asset.kind == .simple_avatar) {
        const record = selected.body orelse return error.PoseNotFound;
        const image = try bgb.decodeImageRef(gpa, avb_data, record.images[0]);
        return .{
            .image = image,
            .face_x = record.face.x,
            .head_height = simpleHeadHeight(image.height),
            .requested = selected.requested,
        };
    }

    const face_record = selected.face orelse return error.PoseNotFound;
    const torso_record = selected.torso orelse return error.PoseNotFound;
    var head = try bgb.decodeImageRef(gpa, avb_data, face_record.images[0]);
    defer head.deinit(gpa);
    var body = try bgb.decodeImageRef(gpa, avb_data, torso_record.images[0]);
    defer body.deinit(gpa);
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
    const asset = try avb_asset.parse(avb_data);
    var table = try avb_asset.parsePoseTable(gpa, avb_data);
    defer table.deinit(gpa);
    if (asset.kind == .simple_avatar) {
        const choice = selectAvailable(table.records, analysis, .body, null) orelse neutralChoice();
        const record = bgb.selectPose(table.records, .body, choice.emotion.assetIndex(), choice.intensity) orelse
            return error.PoseNotFound;
        const image = try bgb.decodePoseForEmotion(gpa, avb_data, .body, choice.emotion.assetIndex(), choice.intensity);
        return .{
            .image = image,
            .face_x = record.face.x,
            .head_height = simpleHeadHeight(image.height),
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
/// Authored `face.y` is unused for simple-avatar layout. Do not "improve" this.
fn simpleHeadHeight(image_height: u32) i32 {
    return @intCast(image_height / 2);
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
