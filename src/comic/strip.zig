//! Source-faithful Microsoft Comic Chat 2.5 page renderer.
//!
//! The shipped path is deliberately assembled from the literal ports in this
//! directory: `CUnitPanelPage::AddLine`, `LayoutAvatars`, Woodring balloon
//! geometry, the body mask/ROP compositor, and the y-up panel raster bridge.
//! Coordinates remain in the original 2300-unit panel space until the final
//! 315-pixel device transform.  The title panel, two-column page, 144-unit
//! interstice, persistent MSVCRT random stream, backdrop zoom crop, reverse
//! balloon draw order, and clipped 120-unit panel border all follow the source.

const std = @import("std");
const bgb = @import("../assets/bgb.zig");
const figure = @import("figure.zig");
const formatting = @import("formatting.zig");
const original_balloon = @import("original_balloon.zig");
const original_figure = @import("original_figure.zig");
const original_layout = @import("original_layout.zig");
const original_page = @import("original_page.zig");
const original_raster = @import("original_raster.zig");
const original_title = @import("original_title.zig");
const canvas_mod = @import("../render/canvas.zig");
const udi = @import("../proto/udi.zig");

const Canvas = canvas_mod.Canvas;
const black = canvas_mod.black;
const white = canvas_mod.white;

pub const Image = bgb.Image;

/// An addressed participant which may be pulled into a panel by the source
/// `AddTalkTos` pass even when they do not have a balloon of their own.
pub const Participant = struct {
    /// Stable user identity. This, not the selected avatar, controls panel
    /// membership, repeated-speaker handling, and placement hysteresis.
    identity: []const u8,
    display_name: ?[]const u8 = null,
    /// Built-in avatar asset name (for example `anna` or `kevin`).
    avatar: []const u8,
};

/// Current live channel-member state for the source title-panel star list.
/// Unlike `Line` inference, this includes members who have not spoken yet.
pub const TitleParticipant = struct {
    identity: []const u8,
    display_name: ?[]const u8 = null,
    avatar: []const u8,
    is_self: bool = false,
    sends: u32 = 0,
    departed: bool = false,
};

pub const Line = struct {
    /// Compatibility shorthand used as identity, display name, and avatar
    /// when the corresponding explicit field below is absent.
    speaker: []const u8 = "",
    text: []const u8,
    /// Source format-state changes indexed into `text` after control removal.
    formatting: []const formatting.Change = &.{},
    modes: u16 = original_page.bm_say,
    identity: ?[]const u8 = null,
    display_name: ?[]const u8 = null,
    avatar: ?[]const u8 = null,
    /// Semantic avatar-pose text supplied by the caller. An uncooked `<Chr>`
    /// reaction analyzes its own text before AddReaction, just like
    /// `CChatDoc::ProcessLine`; cooked reactions use `pose_state` below.
    pose_text: ?[]const u8 = null,
    /// Cooked Microsoft UDI pose. When present this takes precedence over
    /// semantic text posing and selects exact authored record ordinals.
    pose_state: ?udi.PoseState = null,
    talk_targets: []const Participant = &.{},
};

pub const RenderOptions = struct {
    /// `CChatDoc` initializes `m_comicsTitle` to null. Null therefore selects
    /// one of the localized title resources with exactly one `randfloat()`;
    /// an explicit title is used verbatim and consumes no random value.
    title: ?[]const u8 = null,
    /// Seed installed by `CChatDoc::InitMyDocument` before either title or
    /// panel construction consumes the shared MSVCRT stream.
    document_seed: u32 = 1,
    starring: []const u8 = "Starring",
    /// Stable identity corresponding to `MyAvatarID`; null retains the
    /// first-participant convention. Legacy avatar-name callers still work.
    self_speaker: ?[]const u8 = null,
    /// Live member-map snapshot for `AddStarsAux`. Null preserves the static
    /// API's historic line-inference fallback.
    title_roster: ?[]const TitleParticipant = null,
    backdrop: []const u8 = field_background,
    /// `BF_NOZOOM` keeps the whole authored backdrop visible.
    backdrop_no_zoom: bool = false,
    /// Number of panels placed across the rendered page. The source default
    /// remains two for compatibility; desktop clients may choose a denser,
    /// responsive presentation without changing panel internals.
    page_columns: u8 = columns,
    /// Keep the requested number of desktop grid columns even when the last
    /// row is only partly populated. The source/export API leaves this false;
    /// the interactive desktop enables it so a sparse page cannot magnify one
    /// panel to the size of the entire conversation buffer.
    reserve_page_columns: bool = false,
};

pub const Error = bgb.Error || original_layout.Error || original_balloon.Error ||
    original_page.Error || original_raster.Error || original_title.Error ||
    original_figure.Error || error{
    MissingNeckAnchors,
    UnknownAvatar,
    InvalidPlannerResult,
};

pub const panel_width: u32 = 315;
pub const panel_height: u32 = 315;
pub const columns: u32 = original_title.panels_per_row;
pub const logical_interstice: i32 = original_title.horizontal_interstice;
pub const device_interstice: u32 = sourceRoundU32(
    @as(f64, @floatFromInt(logical_interstice)) *
        @as(f64, @floatFromInt(panel_width)) /
        @as(f64, @floatFromInt(original_layout.default_unit_width)),
);

/// Source rectangle inside a composed strip page. Desktop views width-fit this
/// crop so a tall transcript shows the latest panels instead of shrinking the
/// entire page.
pub const PageCrop = struct {
    x: u32 = 0,
    y: u32 = 0,
    w: u32,
    h: u32,
};

/// Choose the latest complete panel rows that fill `dest_w`×`dest_h` after a
/// width-fit scale. Short pages return the whole image. Tall pages crop from
/// the bottom on a panel-row boundary so a width-fit cannot slice Anna into
/// legs on one row and hair on the next. Callers must still pass the full
/// transcript prefix into `renderWithOptions` so AddLine / hysteresis / the
/// shared CRT stream stay source-faithful.
pub fn latestPageCrop(page_w: u32, page_h: u32, dest_w: u32, dest_h: u32) PageCrop {
    if (page_w == 0 or page_h == 0) return .{ .w = page_w, .h = page_h };
    if (dest_w == 0 or dest_h == 0) return .{ .w = page_w, .h = @min(page_h, panel_height) };
    const visible_h: u32 = @intCast(@min(
        @as(u64, page_h),
        @divTrunc(@as(u64, dest_h) * page_w, dest_w),
    ));
    const stride = panel_height + device_interstice;
    const rows: u32 = if (stride == 0)
        1
    else
        @max(@as(u32, 1), (visible_h + device_interstice) / stride);
    const crop_h = @min(page_h, rows * panel_height + (rows - 1) * device_interstice);
    var y: u32 = if (page_h > crop_h) page_h - crop_h else 0;
    if (stride > 0 and y >= stride) y = (y / stride) * stride;
    return .{
        .x = 0,
        .y = y,
        .w = page_w,
        .h = page_h - y,
    };
}

const panel_rect = original_balloon.Rect{
    .left = 0,
    .top = 0,
    .right = original_layout.default_unit_width,
    .bottom = -original_layout.default_unit_height,
};

const balloon_rect = original_balloon.Rect{
    .left = original_title.border_width,
    .top = -original_title.border_width,
    .right = original_layout.default_unit_width - original_title.border_width,
    .bottom = -@divTrunc(original_layout.default_unit_height, 2),
};

fn drawPanelBodies(
    gpa: std.mem.Allocator,
    canvas: *Canvas,
    placements: []const original_layout.Placement,
    avatars: []const []const u8,
    poses: []const []const u8,
    pose_states: []const ?udi.PoseState,
    transform: original_raster.Transform,
) !void {
    for (placements) |placement| {
        const source = placement.rect;
        const draw_options = original_figure.LogicalOptions{
            .client = .{
                .left = source.x,
                .top = -source.y,
                .right = source.x + source.w,
                .bottom = -(source.y + source.h),
            },
            .transform = transform,
            .flipped = placement.flipped,
        };
        _ = if (pose_states[placement.body_index]) |pose_state|
            try original_figure.drawSourcePoseLogical(
                gpa,
                canvas,
                avatars[placement.body_index],
                pose_state,
                draw_options,
            )
        else
            try original_figure.drawForTextLogical(
                gpa,
                canvas,
                avatars[placement.body_index],
                poses[placement.body_index],
                draw_options,
            );
    }
}

fn nudgeColorDestsBelowBalloons(
    placements: []original_layout.Placement,
    bodies: []const original_layout.Body,
    balloons: []const original_balloon.BalloonGeometry,
) void {
    var clear_above: i32 = 0;
    for (balloons) |balloon| {
        const cloud_bottom_down = -balloon.cloud_bbox.bottom;
        if (cloud_bottom_down > 0) clear_above = @max(clear_above, cloud_bottom_down + 40);
    }
    if (clear_above <= 0) return;
    for (placements) |*placement| {
        if (!bodies[placement.body_index].keep_recognizable) continue;
        original_layout.nudgeRecognizableDestBelow(
            &placement.rect,
            clear_above,
            original_layout.default_unit_height,
        );
    }
}

const HistoryEntry = struct {
    id: u32,
    history: original_layout.History,
};

const OwnedLine = struct {
    identity: []u8,
    display_name: []u8,
    avatar: []u8,
    text: []u8,
    formatting: []formatting.Change,
    pose_text: []u8,
    pose_state: ?udi.PoseState,
    talk_targets: []OwnedParticipant,
    modes: u16,
    has_balloon: bool,

    fn init(
        gpa: std.mem.Allocator,
        identity: []const u8,
        display_name: []const u8,
        avatar: []const u8,
        text: []const u8,
        format_changes: []const formatting.Change,
        pose_text: []const u8,
        pose_state: ?udi.PoseState,
        talk_targets: []const Participant,
        modes: u16,
        has_balloon: bool,
    ) !OwnedLine {
        const owned_identity = try gpa.dupe(u8, identity);
        errdefer gpa.free(owned_identity);
        const owned_display_name = try gpa.dupe(u8, display_name);
        errdefer gpa.free(owned_display_name);
        const owned_avatar = try gpa.dupe(u8, avatar);
        errdefer gpa.free(owned_avatar);
        const owned_text = try gpa.dupe(u8, text);
        errdefer gpa.free(owned_text);
        const owned_formatting = try gpa.dupe(formatting.Change, format_changes);
        errdefer gpa.free(owned_formatting);
        const owned_pose_text = try gpa.dupe(u8, pose_text);
        errdefer gpa.free(owned_pose_text);
        const owned_targets = try cloneParticipants(gpa, talk_targets);
        return .{
            .identity = owned_identity,
            .display_name = owned_display_name,
            .avatar = owned_avatar,
            .text = owned_text,
            .formatting = owned_formatting,
            .pose_text = owned_pose_text,
            .pose_state = pose_state,
            .talk_targets = owned_targets,
            .modes = modes,
            .has_balloon = has_balloon,
        };
    }

    fn clone(self: OwnedLine, gpa: std.mem.Allocator) !OwnedLine {
        const targets = try participantsView(gpa, self.talk_targets);
        defer gpa.free(targets);
        return init(
            gpa,
            self.identity,
            self.display_name,
            self.avatar,
            self.text,
            self.formatting,
            self.pose_text,
            self.pose_state,
            targets,
            self.modes,
            self.has_balloon,
        );
    }

    fn deinit(self: *OwnedLine, gpa: std.mem.Allocator) void {
        gpa.free(self.identity);
        gpa.free(self.display_name);
        gpa.free(self.avatar);
        gpa.free(self.text);
        gpa.free(self.formatting);
        gpa.free(self.pose_text);
        deinitParticipants(gpa, self.talk_targets);
        self.* = undefined;
    }
};

const OwnedParticipant = struct {
    identity: []u8,
    display_name: []u8,
    avatar: []u8,
};

const Scene = struct {
    seed: u32,
    lines: []OwnedLine,
    history_before: []HistoryEntry,
    history_after: []HistoryEntry,
    image: Image,

    fn deinit(self: *Scene, gpa: std.mem.Allocator) void {
        for (self.lines) |*line| line.deinit(gpa);
        gpa.free(self.lines);
        gpa.free(self.history_before);
        gpa.free(self.history_after);
        self.image.deinit(gpa);
        self.* = undefined;
    }
};

const Candidate = struct {
    scene: ?Scene,
    continuation: ?[]u8,
    continuation_formatting: ?[]formatting.Change,

    fn deinit(self: *Candidate, gpa: std.mem.Allocator) void {
        if (self.scene) |*scene| scene.deinit(gpa);
        if (self.continuation) |rest| gpa.free(rest);
        if (self.continuation_formatting) |changes| gpa.free(changes);
        self.* = undefined;
    }
};

/// Render a complete old-client page.  As in `AddTitle`, even an empty page
/// contains the borderless title panel; conversation panels start at index 1.
pub fn render(gpa: std.mem.Allocator, lines: []const Line) Error!Image {
    return renderWithOptions(gpa, lines, .{});
}

pub fn renderWithOptions(
    gpa: std.mem.Allocator,
    lines: []const Line,
    options: RenderOptions,
) Error!Image {
    var page_random = original_page.MsvcrtRand.init(options.document_seed);
    const resolved_options = resolveDocumentTitle(options, &page_random);
    var planner = try original_page.Planner.init(gpa, &page_random);
    defer planner.deinit(gpa);

    var scenes: std.ArrayList(Scene) = .empty;
    defer {
        for (scenes.items) |*scene| scene.deinit(gpa);
        scenes.deinit(gpa);
    }
    var histories: std.ArrayList(HistoryEntry) = .empty;
    defer histories.deinit(gpa);
    // `g_bNewedPanel` is a page-global in pageview.cpp. AddLine updates it,
    // while AddReaction deliberately leaves the previous value untouched.
    var newed_panel = false;

    for (lines) |input_line| {
        const identity = lineIdentity(input_line);
        var pending_owned: ?[]u8 = null;
        defer if (pending_owned) |text| gpa.free(text);
        var pending_formatting_owned: ?[]formatting.Change = null;
        defer if (pending_formatting_owned) |changes| gpa.free(changes);
        var request_formatting = input_line.formatting;
        var request = original_page.Line{
            .speaker_id = speakerId(identity),
            .words = input_line.text,
            .modes = input_line.modes,
        };

        request_loop: while (true) {
            const begun = try planner.begin(&page_random, request);
            var attempt = switch (begun) {
                .forced_break => break :request_loop,
                .attempt => |value| value,
            };
            updateNewedPanel(&newed_panel, attempt.kind, attempt.replace_last);
            const base: ?*const Scene = if (attempt.replace_last)
                (if (scenes.items.len == 0) return error.InvalidPlannerResult else &scenes.items[scenes.items.len - 1])
            else
                null;

            // `LayoutBalloons` calls srand(panel.seed) and leaves the global
            // CRT generator advanced.  Keep the nominal page and balloon RNG
            // types synchronized on success and on failed clone attempts.
            var balloon_random = original_balloon.MsvcrtRand.init(page_random.state);
            var trial_histories: std.ArrayList(HistoryEntry) = .empty;
            defer trial_histories.deinit(gpa);
            const establishing = isEstablishing(planner.panelCount(), newed_panel) or
                generatedFamilyAvatar(lineAvatar(input_line));
            var candidate = buildCandidate(
                gpa,
                base,
                request,
                request_formatting,
                input_line,
                attempt.kind,
                attempt.panel.seed,
                histories.items,
                establishing,
                &trial_histories,
                &balloon_random,
                options,
            ) catch |err| switch (err) {
                error.BalloonsDoNotFit => {
                    page_random.state = balloon_random.state;
                    try applyHistories(gpa, &histories, trial_histories.items);
                    const next = try planner.finish(gpa, attempt, .{ .fit = false });
                    request = switch (next) {
                        .retry => |retry| retry,
                        else => return error.InvalidPlannerResult,
                    };
                    continue :request_loop;
                },
                else => return err,
            };
            defer candidate.deinit(gpa);
            page_random.state = balloon_random.state;

            var body_ids: [original_page.max_bodies_per_panel]u32 = undefined;
            const history_after = candidate.scene.?.history_after;
            if (history_after.len > body_ids.len) return error.InvalidPlannerResult;
            for (history_after, 0..) |entry, index| body_ids[index] = entry.id;
            try attempt.panel.setBodies(body_ids[0..history_after.len]);

            const continuation_view: ?original_page.Continuation = if (candidate.continuation) |rest|
                .{ .words = rest }
            else
                null;
            const next = try planner.finish(gpa, attempt, .{
                .fit = true,
                .continuation = continuation_view,
            });

            try applyHistories(gpa, &histories, candidate.scene.?.history_after);
            if (attempt.replace_last) {
                if (scenes.items.len == 0) return error.InvalidPlannerResult;
                scenes.items[scenes.items.len - 1].deinit(gpa);
                scenes.items[scenes.items.len - 1] = candidate.scene.?;
            } else {
                try scenes.append(gpa, candidate.scene.?);
            }
            candidate.scene = null;

            switch (next) {
                .done => break :request_loop,
                .continuation => |rest| {
                    if (pending_owned) |old| gpa.free(old);
                    if (pending_formatting_owned) |old| gpa.free(old);
                    pending_owned = candidate.continuation orelse return error.InvalidPlannerResult;
                    candidate.continuation = null;
                    pending_formatting_owned = candidate.continuation_formatting orelse
                        return error.InvalidPlannerResult;
                    candidate.continuation_formatting = null;
                    request = rest;
                    request.words = pending_owned.?;
                    request_formatting = pending_formatting_owned.?;
                },
                .retry => return error.InvalidPlannerResult,
            }
        }
    }

    return composePage(gpa, lines, scenes.items, resolved_options);
}

fn resolveDocumentTitle(options: RenderOptions, rng: *original_page.MsvcrtRand) RenderOptions {
    var resolved = options;
    if (options.title == null)
        resolved.title = original_title.englishRandomTitle(rng.randFloat());
    return resolved;
}

fn buildCandidate(
    gpa: std.mem.Allocator,
    base: ?*const Scene,
    request: original_page.Line,
    request_formatting: []const formatting.Change,
    input_line: Line,
    attempt_kind: original_page.AttemptKind,
    seed: u32,
    current_histories: []const HistoryEntry,
    establishing: bool,
    trial_histories: *std.ArrayList(HistoryEntry),
    random: *original_balloon.MsvcrtRand,
    options: RenderOptions,
) Error!Candidate {
    var owned_lines: std.ArrayList(OwnedLine) = .empty;
    errdefer {
        for (owned_lines.items) |*line| line.deinit(gpa);
        owned_lines.deinit(gpa);
    }
    if (base) |old| {
        try owned_lines.ensureTotalCapacity(gpa, old.lines.len + 1);
        for (old.lines) |line| {
            var copy = try line.clone(gpa);
            owned_lines.append(gpa, copy) catch |err| {
                copy.deinit(gpa);
                return err;
            };
        }
    }
    if (attempt_kind == .reaction) {
        var replaced = false;
        for (owned_lines.items) |*line| {
            if (!identityEql(line.identity, lineIdentity(input_line))) continue;
            try updateReactionBody(gpa, line, input_line);
            replaced = true;
            break;
        }
        if (!replaced) {
            var reaction = try OwnedLine.init(
                gpa,
                lineIdentity(input_line),
                lineDisplayName(input_line),
                lineAvatar(input_line),
                "",
                &.{},
                input_line.pose_text orelse input_line.text,
                input_line.pose_state,
                input_line.talk_targets,
                request.modes,
                false,
            );
            owned_lines.append(gpa, reaction) catch |err| {
                reaction.deinit(gpa);
                return err;
            };
        }
    } else {
        // Balloon layout uppercases before it splits. A continuation leftover
        // like "...CLEARER NOW." is all-caps and would select a shouting /
        // kick pose. Generated standing cards then dest-overflow into
        // legs-only. Keep the original line's pose so Color/HD Anna stays a
        // whole person. Testdata goldens still use the leftover fragment.
        const pose_source = input_line.pose_text orelse
            if (generatedFamilyAvatar(lineAvatar(input_line))) input_line.text else request.words;
        var spoken = try OwnedLine.init(
            gpa,
            lineIdentity(input_line),
            lineDisplayName(input_line),
            lineAvatar(input_line),
            request.words,
            request_formatting,
            pose_source,
            input_line.pose_state,
            input_line.talk_targets,
            request.modes,
            true,
        );
        owned_lines.append(gpa, spoken) catch |err| {
            spoken.deinit(gpa);
            return err;
        };
    }
    const lines = try owned_lines.toOwnedSlice(gpa);
    errdefer {
        for (lines) |*line| line.deinit(gpa);
        gpa.free(lines);
    }

    const history_before = try gpa.dupe(HistoryEntry, current_histories);
    errdefer gpa.free(history_before);
    return renderScene(gpa, seed, lines, history_before, establishing, trial_histories, random, options);
}

fn renderScene(
    gpa: std.mem.Allocator,
    seed: u32,
    lines: []OwnedLine,
    history_before: []HistoryEntry,
    establishing: bool,
    trial_histories: *std.ArrayList(HistoryEntry),
    random: *original_balloon.MsvcrtRand,
    options: RenderOptions,
) Error!Candidate {
    if (lines.len == 0 or lines.len > original_page.max_bodies_per_panel)
        return error.InvalidPlannerResult;

    var body_meta: std.ArrayList(BodyMeta) = .empty;
    defer {
        for (body_meta.items) |meta| gpa.free(meta.talk_to_ids);
        body_meta.deinit(gpa);
    }
    // Requested speakers are inserted first, matching the `initialCount`
    // snapshot in AddTalkTos. Addressed-only participants follow as the
    // available roster and are pulled in, without duplicates, up to five.
    for (lines) |line| {
        if (findBodyMeta(body_meta.items, speakerId(line.identity)) != null) continue;
        const talk_to_ids = try gpa.alloc(u32, line.talk_targets.len);
        errdefer gpa.free(talk_to_ids);
        for (line.talk_targets, 0..) |target, index|
            talk_to_ids[index] = speakerId(target.identity);
        try body_meta.append(gpa, .{
            .id = speakerId(line.identity),
            .avatar = line.avatar,
            .pose_text = line.pose_text,
            .pose_state = line.pose_state,
            .talk_to_ids = talk_to_ids,
        });
    }
    const speaker_count = body_meta.items.len;
    for (lines) |line| {
        for (line.talk_targets) |target| {
            const target_id = speakerId(target.identity);
            if (findBodyMeta(body_meta.items, target_id) != null) continue;
            const no_targets = try gpa.alloc(u32, 0);
            errdefer gpa.free(no_targets);
            try body_meta.append(gpa, .{
                .id = target_id,
                .avatar = target.avatar,
                .pose_text = "",
                .pose_state = null,
                .talk_to_ids = no_targets,
            });
        }
    }

    const available = try gpa.alloc(original_layout.Body, body_meta.items.len);
    defer gpa.free(available);
    for (body_meta.items, 0..) |meta, index| available[index] = .{
        .id = meta.id,
        .width = 1,
        .height = 1,
        .head_height = 1,
        .face_x = 0,
        .talk_to_ids = meta.talk_to_ids,
        .history = historyFor(history_before, meta.id),
    };
    const bodies = try original_layout.addTalkTos(gpa, available[0..speaker_count], available);
    defer gpa.free(bodies);
    if (bodies.len == 0 or bodies.len > original_page.max_bodies_per_panel)
        return error.InvalidPlannerResult;

    const rendered = try gpa.alloc(figure.Rendered, bodies.len);
    var rendered_count: usize = 0;
    defer {
        for (rendered[0..rendered_count]) |*item| item.deinit(gpa);
        gpa.free(rendered);
    }
    const avatars = try gpa.alloc([]const u8, bodies.len);
    defer gpa.free(avatars);
    const poses = try gpa.alloc([]const u8, bodies.len);
    defer gpa.free(poses);
    const pose_states = try gpa.alloc(?udi.PoseState, bodies.len);
    defer gpa.free(pose_states);
    for (bodies, 0..) |*body, index| {
        const meta = findBodyMeta(body_meta.items, body.id) orelse return error.InvalidPlannerResult;
        const avatar = avatarByName(meta.avatar) orelse return error.UnknownAvatar;
        avatars[index] = avatar;
        poses[index] = meta.pose_text;
        pose_states[index] = meta.pose_state;
        rendered[index] = if (meta.pose_state) |pose_state|
            try figure.assembleDetailedForSourcePose(gpa, avatar, pose_state)
        else
            try figure.assembleDetailedForText(gpa, avatar, meta.pose_text);
        rendered_count += 1;
        body.width = @intCast(rendered[index].image.width);
        body.height = @intCast(rendered[index].image.height);
        body.norm_height = 100;
        body.head_height = rendered[index].head_height;
        body.face_x = rendered[index].face_x;
        body.keep_recognizable = rendered[index].generated_standing;
        body.history = historyFor(history_before, body.id);
    }

    var layout = try original_layout.layoutScene(
        gpa,
        bodies,
        original_layout.default_unit_width,
        original_layout.default_unit_height,
        establishing,
    );
    defer layout.deinit(gpa);

    try trial_histories.ensureTotalCapacity(gpa, layout.placements.len);
    for (layout.placements) |placement| trial_histories.appendAssumeCapacity(.{
        .id = bodies[placement.body_index].id,
        .history = placement.history,
    });

    var balloon_count: usize = 0;
    for (lines) |line| if (line.has_balloon) {
        balloon_count += 1;
    };
    const inputs = try gpa.alloc(original_balloon.BalloonInput, balloon_count);
    defer gpa.free(inputs);
    var balloon_index: usize = 0;
    for (layout.placements) |placement| {
        const line = findOwnedLine(lines, bodies[placement.body_index].id) orelse continue;
        if (!line.has_balloon) continue;
        const rect = placement.rect;
        const style = balloonStyle(line.modes);
        inputs[balloon_index] = .{
            .text = line.text,
            .formatting = line.formatting,
            .kind = style.kind,
            .dashed_override = style.dashed,
            .arrow_x = placement.arrow_x,
            .speaker_box = .{
                .left = rect.x,
                .top = -rect.y,
                .right = rect.x + rect.w,
                .bottom = -(rect.y + rect.h),
            },
        };
        balloon_index += 1;
    }

    const metrics = original_raster.AtlasMetrics{};
    const whisper_metrics = original_raster.AtlasMetrics{ .style = .whisper };
    var balloon_layout = try original_balloon.layoutPanelWithMetricSetRandom(
        gpa,
        inputs,
        balloon_rect,
        .{
            .normal = .{ .font = metrics.fontInfo(), .measurer = metrics.textMeasurer() },
            .whisper = .{ .font = whisper_metrics.fontInfo(), .measurer = whisper_metrics.textMeasurer() },
        },
        random,
    );
    defer balloon_layout.deinit(gpa);

    var any_recognizable = false;
    for (bodies) |body| {
        if (!body.keep_recognizable) continue;
        any_recognizable = true;
        break;
    }
    nudgeColorDestsBelowBalloons(layout.placements, bodies, balloon_layout.balloons);
    if (any_recognizable) {
        var head_line: i32 = std.math.maxInt(i32);
        for (layout.placements) |placement| {
            if (!bodies[placement.body_index].keep_recognizable) continue;
            head_line = @min(head_line, placement.rect.y);
        }
        if (head_line != std.math.maxInt(i32)) {
            const max_bottom_y_up = -(head_line - 40);
            for (balloon_layout.balloons) |*balloon| {
                balloon.liftAbove(max_bottom_y_up, balloon_rect.top);
            }
            nudgeColorDestsBelowBalloons(layout.placements, bodies, balloon_layout.balloons);
        }
        var balloon_i: usize = 0;
        for (layout.placements) |placement| {
            const line = findOwnedLine(lines, bodies[placement.body_index].id) orelse continue;
            if (!line.has_balloon) continue;
            if (balloon_i >= balloon_layout.balloons.len) break;
            if (bodies[placement.body_index].keep_recognizable) {
                balloon_layout.balloons[balloon_i].retargetTip(-placement.rect.y + 200);
            }
            balloon_i += 1;
        }
    }

    var canvas = try Canvas.init(gpa, panel_width, panel_height);
    defer canvas.deinit(gpa);
    canvas.clear(white);
    const transform = original_raster.Transform.panel315();

    var backdrop = try bgb.decodeBackground(gpa, options.backdrop);
    defer backdrop.deinit(gpa);
    const art_bbox = if (options.backdrop_no_zoom)
        panel_rect
    else
        original_balloon.Rect{
            .left = layout.art_bbox.left,
            .top = layout.art_bbox.top,
            .right = layout.art_bbox.right,
            .bottom = layout.art_bbox.bottom,
        };
    const crop = original_raster.ImageRegion.fromBackdropBBox(
        art_bbox,
        panel_rect,
        backdrop.width,
        backdrop.height,
    );
    original_raster.blitImageRegion(
        &canvas,
        backdrop.pixels,
        backdrop.width,
        backdrop.height,
        crop,
        panel_rect,
        transform,
        false,
    );

    // Microsoft `CUnitPanel::Draw` paints bodies, then balloons. Testdata
    // dests keep that order so goldens do not move. Generated standing dests
    // paint after balloons so a cloud that is still taller than the dest gap
    // after docking at the top cannot cover the face.
    if (any_recognizable) {
        try original_raster.drawPanelBalloons(gpa, &canvas, balloon_layout.balloons, transform);
        try drawPanelBodies(gpa, &canvas, layout.placements, avatars, poses, pose_states, transform);
    } else {
        try drawPanelBodies(gpa, &canvas, layout.placements, avatars, poses, pose_states, transform);
        try original_raster.drawPanelBalloons(gpa, &canvas, balloon_layout.balloons, transform);
    }
    drawPanelBorder(&canvas);

    const pixels = try gpa.dupe(u32, canvas.px);
    errdefer gpa.free(pixels);
    const history_after = try gpa.dupe(HistoryEntry, trial_histories.items);
    errdefer gpa.free(history_after);
    const continuation = if (balloon_layout.continuation_text) |rest|
        try gpa.dupe(u8, rest)
    else
        null;
    errdefer if (continuation) |rest| gpa.free(rest);
    const continuation_formatting = if (balloon_layout.continuation_formatting) |changes|
        try gpa.dupe(formatting.Change, changes)
    else
        null;
    errdefer if (continuation_formatting) |changes| gpa.free(changes);

    return .{
        .scene = .{
            .seed = seed,
            .lines = lines,
            .history_before = history_before,
            .history_after = history_after,
            .image = .{ .width = panel_width, .height = panel_height, .pixels = pixels },
        },
        .continuation = continuation,
        .continuation_formatting = continuation_formatting,
    };
}

fn composePage(
    gpa: std.mem.Allocator,
    lines: []const Line,
    scenes: []const Scene,
    options: RenderOptions,
) Error!Image {
    const panel_count = scenes.len + 1;
    const configured_columns: usize = std.math.clamp(@as(usize, options.page_columns), 1, 8);
    const page_columns: u32 = @intCast(if (options.reserve_page_columns)
        configured_columns
    else
        @min(panel_count, configured_columns));
    const rows: u32 = @intCast((panel_count - 1) / configured_columns + 1);
    const width = page_columns * panel_width + (page_columns - 1) * device_interstice;
    const height = rows * panel_height + (rows - 1) * device_interstice;
    var page = try Canvas.init(gpa, width, height);
    defer page.deinit(gpa);
    page.clear(white);

    var title = try renderTitlePanel(gpa, lines, options);
    defer title.deinit(gpa);
    page.blit(title.pixels, title.width, title.height, 0, 0);
    for (scenes, 1..) |scene, panel_index| {
        const column: u32 = @intCast(panel_index % configured_columns);
        const row: u32 = @intCast(panel_index / configured_columns);
        const x: i32 = @intCast(column * (panel_width + device_interstice));
        const y: i32 = @intCast(row * (panel_height + device_interstice));
        page.blit(scene.image.pixels, scene.image.width, scene.image.height, x, y);
    }
    return .{ .width = width, .height = height, .pixels = try gpa.dupe(u32, page.px) };
}

fn renderTitlePanel(gpa: std.mem.Allocator, lines: []const Line, options: RenderOptions) Error!Image {
    var canvas = try Canvas.init(gpa, panel_width, panel_height);
    defer canvas.deinit(gpa);
    canvas.clear(white);

    var people: std.ArrayList(TitlePerson) = .empty;
    defer people.deinit(gpa);
    if (options.title_roster) |roster| {
        for (roster) |member| {
            try people.append(gpa, .{
                .identity = member.identity,
                .display_name = member.display_name orelse member.identity,
                .avatar = member.avatar,
                .is_self = member.is_self,
                .departed = member.departed,
                .sends = member.sends,
            });
        }
    } else {
        for (lines) |line| {
            const identity = lineIdentity(line);
            if (findTitlePerson(people.items, identity)) |index| {
                people.items[index].sends += 1;
                people.items[index].display_name = lineDisplayName(line);
                people.items[index].avatar = lineAvatar(line);
            } else {
                try people.append(gpa, .{
                    .identity = identity,
                    .display_name = lineDisplayName(line),
                    .avatar = lineAvatar(line),
                    .sends = 1,
                });
            }
            for (line.talk_targets) |target| {
                if (findTitlePerson(people.items, target.identity) != null) continue;
                try people.append(gpa, .{
                    .identity = target.identity,
                    .display_name = target.display_name orelse target.identity,
                    .avatar = target.avatar,
                    .sends = 0,
                });
            }
        }
    }
    const participants = try gpa.alloc(original_title.Participant, people.items.len);
    defer gpa.free(participants);
    for (people.items, 0..) |person, index| participants[index] = .{
        .name = person.display_name,
        .is_self = if (options.title_roster != null)
            person.is_self
        else if (options.self_speaker) |self|
            identityEql(person.identity, self) or std.ascii.eqlIgnoreCase(person.avatar, self)
        else
            index == 0,
        .departed = person.departed,
        .sends = person.sends,
        .has_icon = avatarByName(person.avatar) != null,
    };

    var context = TitleMetrics{};
    var plan = try original_title.build(gpa, options.title.?, participants, .{
        .context = &context,
        .measure_text = TitleMetrics.measure,
        .fonts = .{
            .title_line_height = TitleMetrics.title_line_height,
            .title_base_add = TitleMetrics.construction.title_base_add,
            .shout_line_height = TitleMetrics.shout_line_height,
            .shout_base_add = 0,
        },
    }, .{ .starring_text = options.starring });
    defer plan.deinit(gpa);
    const transform = original_raster.Transform.panel315();
    // CUnitPanel::Draw walks m_elements tail-to-head. AddTitle appended title,
    // Starring, then each icon/label pair, so the visual order is the exact
    // reverse of construction.
    var star_index = plan.stars.len;
    while (star_index > 0) {
        star_index -= 1;
        const star = plan.stars[star_index];
        drawTitleLabel(&canvas, star.label);
        if (avatarByName(people.items[star.participant_index].avatar)) |avatar| {
            var icon = try figure.titleStarIcon(gpa, avatar);
            defer icon.deinit(gpa);
            original_raster.blitImage(
                &canvas,
                icon.pixels,
                icon.width,
                icon.height,
                .{
                    .left = star.icon_bbox.left,
                    .top = star.icon_bbox.top,
                    .right = star.icon_bbox.right,
                    .bottom = star.icon_bbox.bottom,
                },
                transform,
                false,
            );
        }
    }
    drawTitleLabel(&canvas, plan.starring);
    drawTitleLabel(&canvas, plan.title);

    return .{ .width = panel_width, .height = panel_height, .pixels = try gpa.dupe(u32, canvas.px) };
}

const TitleMetrics = struct {
    const construction = original_title.fontConstruction(-240);
    const title_request_height: i32 = -construction.title_request_height;
    const shout_request_height: i32 = -construction.shout_request_height;
    // The checked-in Comic Neue atlas has a 23px tmHeight at its default
    // -240 logical request. Scaling that actual metric keeps portable glyph
    // extents, wrapping, and CFontInfo line advances internally consistent.
    const title_tm_height: i32 = sourceRoundI32(23.0 * @as(f64, @floatFromInt(title_request_height)) / 23.0);
    const shout_tm_height: i32 = sourceRoundI32(23.0 * @as(f64, @floatFromInt(shout_request_height)) / 23.0);
    const title_line_height: i32 = title_tm_height + construction.title_leading;
    const shout_line_height: i32 = shout_tm_height;

    fn measure(
        _: ?*const anyopaque,
        role: original_title.FontRole,
        text: []const u8,
        maximum_width: i32,
    ) original_title.Measurement {
        _ = maximum_width;
        const height = requestHeight(role);
        const width: i32 = sourceRoundI32(
            @as(f64, @floatFromInt(Canvas.textWidth(text))) *
                @as(f64, @floatFromInt(height)) / 23.0,
        );
        return .{ .width = width };
    }

    fn requestHeight(role: original_title.FontRole) i32 {
        return if (role == .title) title_request_height else shout_request_height;
    }

    fn lineHeight(role: original_title.FontRole) i32 {
        return if (role == .title) title_line_height else shout_line_height;
    }
};

fn drawTitleLabel(canvas: *Canvas, label: original_title.Label) void {
    const transform = original_raster.Transform.panel315();
    const metrics = original_raster.AtlasMetrics.fromLogicalLineHeight(TitleMetrics.requestHeight(label.role));
    if (label.end_ellipsis) {
        drawTitleEllipsized(canvas, label.text, label.bbox.left, label.bbox.top, label.bbox.width(), transform, metrics);
        return;
    }
    var y = label.bbox.top;
    for (label.lines) |line| {
        // GetFormatInfoCommon's centered branch uses the page unit width
        // literally (its own source comment calls this a kludge).
        const x = if (label.left_justified)
            label.bbox.left
        else
            label.bbox.left + @divTrunc(original_title.unit_width - line.width, 2);
        original_raster.drawAtlasText(canvas, line.bytes(label.text), x, y, transform, metrics);
        y -= TitleMetrics.lineHeight(label.role);
    }
}

fn drawTitleEllipsized(
    canvas: *Canvas,
    text: []const u8,
    x: i32,
    y: i32,
    maximum_width: i32,
    transform: original_raster.Transform,
    metrics: original_raster.AtlasMetrics,
) void {
    const full_width = titleTextWidth(text, metrics.logical_height);
    if (full_width <= maximum_width) {
        original_raster.drawAtlasText(canvas, text, x, y, transform, metrics);
        return;
    }
    const dots = "...";
    const dots_width = titleTextWidth(dots, metrics.logical_height);
    if (dots_width > maximum_width) return;
    var prefix_len: usize = 0;
    while (prefix_len < text.len) {
        const candidate = prefix_len + 1;
        if (titleTextWidth(text[0..candidate], metrics.logical_height) + dots_width > maximum_width) break;
        prefix_len = candidate;
    }
    original_raster.drawAtlasText(canvas, text[0..prefix_len], x, y, transform, metrics);
    const prefix_width = titleTextWidth(text[0..prefix_len], metrics.logical_height);
    original_raster.drawAtlasText(canvas, dots, x + prefix_width, y, transform, metrics);
}

fn titleTextWidth(text: []const u8, request_height: i32) i32 {
    return sourceRoundI32(
        @as(f64, @floatFromInt(Canvas.textWidth(text))) *
            @as(f64, @floatFromInt(request_height)) / 23.0,
    );
}

fn drawPanelBorder(canvas: *Canvas) void {
    // The 120-unit pen is centered on the panel edge; clipping retains its
    // inner 60 units, exactly the same inset used by GetBalloonRect.
    const thickness: i32 = @intCast(sourceRoundU32(
        @as(f64, @floatFromInt(original_title.border_width)) *
            @as(f64, @floatFromInt(panel_width)) /
            @as(f64, @floatFromInt(original_layout.default_unit_width)),
    ));
    const width: i32 = @intCast(canvas.width);
    const height: i32 = @intCast(canvas.height);
    canvas.fillRect(0, 0, width, thickness, black);
    canvas.fillRect(0, height - thickness, width, thickness, black);
    canvas.fillRect(0, 0, thickness, height, black);
    canvas.fillRect(width - thickness, 0, thickness, height, black);
}

const BalloonStyle = struct {
    kind: original_balloon.BalloonKind,
    dashed: ?bool = null,
};

fn balloonStyle(modes: u16) BalloonStyle {
    return switch (modes) {
        original_page.bm_say => .{ .kind = .say },
        original_page.bm_whisper => .{ .kind = .whisper },
        original_page.bm_think => .{ .kind = .think },
        original_page.bm_action,
        original_page.bm_action | original_page.bm_say,
        original_page.bm_action | original_page.bm_think,
        => .{ .kind = .action, .dashed = false },
        original_page.bm_action | original_page.bm_whisper => .{ .kind = .action, .dashed = true },
        else => .{ .kind = .say },
    };
}

fn historyFor(entries: []const HistoryEntry, id: u32) original_layout.History {
    for (entries) |entry| if (entry.id == id) return entry.history;
    return .{};
}

fn applyHistories(
    gpa: std.mem.Allocator,
    entries: *std.ArrayList(HistoryEntry),
    updates: []const HistoryEntry,
) std.mem.Allocator.Error!void {
    for (updates) |update| {
        var found = false;
        for (entries.items) |*entry| {
            if (entry.id != update.id) continue;
            entry.history = update.history;
            found = true;
            break;
        }
        if (!found) try entries.append(gpa, update);
    }
}

const BodyMeta = struct {
    id: u32,
    avatar: []const u8,
    pose_text: []const u8,
    pose_state: ?udi.PoseState,
    talk_to_ids: []const u32,
};

const TitlePerson = struct {
    identity: []const u8,
    display_name: []const u8,
    avatar: []const u8,
    is_self: bool = false,
    departed: bool = false,
    sends: u32,
};

fn lineIdentity(line: Line) []const u8 {
    return line.identity orelse line.speaker;
}

fn lineDisplayName(line: Line) []const u8 {
    return line.display_name orelse line.identity orelse line.speaker;
}

fn lineAvatar(line: Line) []const u8 {
    return line.avatar orelse line.speaker;
}

fn identityEql(first: []const u8, second: []const u8) bool {
    // IRC nick identity is case-insensitive in the current transport model.
    return std.ascii.eqlIgnoreCase(first, second);
}

fn findBodyMeta(items: []const BodyMeta, id: u32) ?*const BodyMeta {
    for (items) |*item| if (item.id == id) return item;
    return null;
}

fn findOwnedLine(lines: []OwnedLine, id: u32) ?*OwnedLine {
    for (lines) |*line| if (speakerId(line.identity) == id) return line;
    return null;
}

fn findTitlePerson(people: []const TitlePerson, identity: []const u8) ?usize {
    for (people, 0..) |person, index|
        if (identityEql(person.identity, identity)) return index;
    return null;
}

fn isEstablishing(panel_count: usize, newed_panel: bool) bool {
    return panel_count <= 1 or (!newed_panel and panel_count <= 2);
}

fn generatedFamilyAvatar(name: []const u8) bool {
    return std.ascii.endsWithIgnoreCase(name, " color") or std.ascii.endsWithIgnoreCase(name, " hd");
}

fn updateNewedPanel(newed_panel: *bool, kind: original_page.AttemptKind, replace_last: bool) void {
    if (kind == .line) newed_panel.* = !replace_last;
}

fn updateReactionBody(gpa: std.mem.Allocator, line: *OwnedLine, input: Line) !void {
    const display = try gpa.dupe(u8, lineDisplayName(input));
    errdefer gpa.free(display);
    const avatar = try gpa.dupe(u8, lineAvatar(input));
    errdefer gpa.free(avatar);
    const targets = try cloneParticipants(gpa, input.talk_targets);
    errdefer deinitParticipants(gpa, targets);
    // ProcessLine runs ChatPreSendText for every uncooked line before it
    // recognizes `<Chr>` as a reaction. A cooked UDI replaces that semantic
    // pose; an uncooked reaction therefore analyzes its own text (normally
    // neutral), rather than retaining the body cloned from the old panel.
    const pose = try gpa.dupe(u8, input.pose_text orelse input.text);
    errdefer gpa.free(pose);

    gpa.free(line.display_name);
    line.display_name = display;
    gpa.free(line.avatar);
    line.avatar = avatar;
    deinitParticipants(gpa, line.talk_targets);
    line.talk_targets = targets;
    gpa.free(line.pose_text);
    line.pose_text = pose;
    line.pose_state = input.pose_state;
}

fn cloneParticipants(gpa: std.mem.Allocator, participants: []const Participant) ![]OwnedParticipant {
    const owned = try gpa.alloc(OwnedParticipant, participants.len);
    var initialized: usize = 0;
    errdefer {
        for (owned[0..initialized]) |participant| {
            gpa.free(participant.identity);
            gpa.free(participant.display_name);
            gpa.free(participant.avatar);
        }
        gpa.free(owned);
    }
    for (participants, 0..) |participant, index| {
        const identity = try gpa.dupe(u8, participant.identity);
        errdefer gpa.free(identity);
        const display = try gpa.dupe(u8, participant.display_name orelse participant.identity);
        errdefer gpa.free(display);
        const avatar = try gpa.dupe(u8, participant.avatar);
        owned[index] = .{ .identity = identity, .display_name = display, .avatar = avatar };
        initialized += 1;
    }
    return owned;
}

fn participantsView(gpa: std.mem.Allocator, owned: []const OwnedParticipant) ![]Participant {
    const result = try gpa.alloc(Participant, owned.len);
    for (owned, 0..) |participant, index| result[index] = .{
        .identity = participant.identity,
        .display_name = participant.display_name,
        .avatar = participant.avatar,
    };
    return result;
}

fn deinitParticipants(gpa: std.mem.Allocator, participants: []OwnedParticipant) void {
    for (participants) |participant| {
        gpa.free(participant.identity);
        gpa.free(participant.display_name);
        gpa.free(participant.avatar);
    }
    gpa.free(participants);
}

fn sourceRoundI32(value: f64) i32 {
    return @intFromFloat(if (value >= 0) value + 0.5 else value - 0.5);
}

fn sourceRoundU32(value: f64) u32 {
    return @intCast(@max(0, sourceRoundI32(value)));
}

pub fn speakerId(speaker: []const u8) u32 {
    var hash: u32 = 0x811c9dc5;
    for (speaker) |character| hash = (hash ^ std.ascii.toLower(character)) *% 0x01000193;
    return hash;
}

const field_background = @embedFile("../assets/testdata/field.bgb");

pub fn avatarByName(name: []const u8) ?[]const u8 {
    const eql = std.ascii.eqlIgnoreCase;
    if (eql(name, "anna")) return @embedFile("../assets/testdata/anna.avb");
    if (eql(name, "armando")) return @embedFile("../assets/testdata/armando.avb");
    if (eql(name, "bolo")) return @embedFile("../assets/testdata/bolo.avb");
    if (eql(name, "cro")) return @embedFile("../assets/testdata/cro.avb");
    if (eql(name, "dan")) return @embedFile("../assets/testdata/dan.avb");
    if (eql(name, "denise")) return @embedFile("../assets/testdata/denise.avb");
    if (eql(name, "hugh")) return @embedFile("../assets/testdata/hugh.avb");
    if (eql(name, "jordan")) return @embedFile("../assets/testdata/jordan.avb");
    if (eql(name, "kevin")) return @embedFile("../assets/testdata/kevin.avb");
    if (eql(name, "kwensa")) return @embedFile("../assets/testdata/kwensa.avb");
    if (eql(name, "lance")) return @embedFile("../assets/testdata/lance.avb");
    if (eql(name, "lynnea")) return @embedFile("../assets/testdata/lynnea.avb");
    if (eql(name, "margaret")) return @embedFile("../assets/testdata/margaret.avb");
    if (eql(name, "maynard")) return @embedFile("../assets/testdata/maynard.avb");
    if (eql(name, "mike")) return @embedFile("../assets/testdata/mike.avb");
    if (eql(name, "rebecca")) return @embedFile("../assets/testdata/rebecca.avb");
    if (eql(name, "sage")) return @embedFile("../assets/testdata/sage.avb");
    if (eql(name, "scotty")) return @embedFile("../assets/testdata/scotty.avb");
    if (eql(name, "susan")) return @embedFile("../assets/testdata/susan.avb");
    if (eql(name, "tiki")) return @embedFile("../assets/testdata/tiki.avb");
    if (eql(name, "tiki hd")) return @embedFile("../assets/generated/tiki-reimagined-hd-v1.avb");
    if (eql(name, "tongtyed")) return @embedFile("../assets/testdata/tongtyed.avb");
    if (eql(name, "xeno")) return @embedFile("../assets/testdata/xeno.avb");
    if (eql(name, "anna hd")) return @embedFile("../assets/generated/anna-reimagined-hd-v1.avb");
    if (eql(name, "armando hd")) return @embedFile("../assets/generated/armando-reimagined-hd-v1.avb");
    if (eql(name, "bolo hd")) return @embedFile("../assets/generated/bolo-reimagined-hd-v1.avb");
    if (eql(name, "cro hd")) return @embedFile("../assets/generated/cro-reimagined-hd-v1.avb");
    if (eql(name, "dan hd")) return @embedFile("../assets/generated/dan-reimagined-hd-v1.avb");
    if (eql(name, "denise hd")) return @embedFile("../assets/generated/denise-reimagined-hd-v1.avb");
    if (eql(name, "hugh hd")) return @embedFile("../assets/generated/hugh-reimagined-hd-v1.avb");
    if (eql(name, "jordan hd")) return @embedFile("../assets/generated/jordan-reimagined-hd-v1.avb");
    if (eql(name, "kevin hd")) return @embedFile("../assets/generated/kevin-reimagined-hd-v1.avb");
    if (eql(name, "kwensa hd")) return @embedFile("../assets/generated/kwensa-reimagined-hd-v1.avb");
    if (eql(name, "lance hd")) return @embedFile("../assets/generated/lance-reimagined-hd-v1.avb");
    if (eql(name, "lynnea hd")) return @embedFile("../assets/generated/lynnea-reimagined-hd-v1.avb");
    if (eql(name, "margaret hd")) return @embedFile("../assets/generated/margaret-reimagined-hd-v1.avb");
    if (eql(name, "maynard hd")) return @embedFile("../assets/generated/maynard-reimagined-hd-v1.avb");
    if (eql(name, "mike hd")) return @embedFile("../assets/generated/mike-reimagined-hd-v1.avb");
    if (eql(name, "rebecca hd")) return @embedFile("../assets/generated/rebecca-reimagined-hd-v1.avb");
    if (eql(name, "sage hd")) return @embedFile("../assets/generated/sage-reimagined-hd-v1.avb");
    if (eql(name, "scotty hd")) return @embedFile("../assets/generated/scotty-reimagined-hd-v1.avb");
    if (eql(name, "susan hd")) return @embedFile("../assets/generated/susan-reimagined-hd-v1.avb");
    if (eql(name, "tongtyed hd")) return @embedFile("../assets/generated/tongtyed-reimagined-hd-v1.avb");
    if (eql(name, "xeno hd")) return @embedFile("../assets/generated/xeno-reimagined-hd-v1.avb");
    if (eql(name, "anna color")) return @embedFile("../assets/generated/anna-color-hd-v1.avb");
    if (eql(name, "armando color")) return @embedFile("../assets/generated/armando-color-hd-v1.avb");
    if (eql(name, "bolo color")) return @embedFile("../assets/generated/bolo-color-hd-v1.avb");
    if (eql(name, "cro color")) return @embedFile("../assets/generated/cro-color-hd-v1.avb");
    if (eql(name, "dan color")) return @embedFile("../assets/generated/dan-color-hd-v1.avb");
    if (eql(name, "denise color")) return @embedFile("../assets/generated/denise-color-hd-v1.avb");
    if (eql(name, "hugh color")) return @embedFile("../assets/generated/hugh-color-hd-v1.avb");
    if (eql(name, "jordan color")) return @embedFile("../assets/generated/jordan-color-hd-v1.avb");
    if (eql(name, "kevin color")) return @embedFile("../assets/generated/kevin-color-hd-v1.avb");
    if (eql(name, "kwensa color")) return @embedFile("../assets/generated/kwensa-color-hd-v1.avb");
    if (eql(name, "lance color")) return @embedFile("../assets/generated/lance-color-hd-v1.avb");
    if (eql(name, "lynnea color")) return @embedFile("../assets/generated/lynnea-color-hd-v1.avb");
    if (eql(name, "margaret color")) return @embedFile("../assets/generated/margaret-color-hd-v1.avb");
    if (eql(name, "maynard color")) return @embedFile("../assets/generated/maynard-color-hd-v1.avb");
    if (eql(name, "mike color")) return @embedFile("../assets/generated/mike-color-hd-v1.avb");
    if (eql(name, "rebecca color")) return @embedFile("../assets/generated/rebecca-color-hd-v1.avb");
    if (eql(name, "sage color")) return @embedFile("../assets/generated/sage-color-hd-v1.avb");
    if (eql(name, "scotty color")) return @embedFile("../assets/generated/scotty-color-hd-v1.avb");
    if (eql(name, "susan color")) return @embedFile("../assets/generated/susan-color-hd-v1.avb");
    if (eql(name, "tiki color")) return @embedFile("../assets/generated/tiki-color-hd-v2.avb");
    if (eql(name, "tongtyed color")) return @embedFile("../assets/generated/tongtyed-color-hd-v1.avb");
    if (eql(name, "xeno color")) return @embedFile("../assets/generated/xeno-color-hd-v1.avb");
    if (eql(name, "anna original")) return @embedFile("../assets/testdata/anna.avb");
    if (eql(name, "armando original")) return @embedFile("../assets/testdata/armando.avb");
    if (eql(name, "bolo original")) return @embedFile("../assets/testdata/bolo.avb");
    if (eql(name, "cro original")) return @embedFile("../assets/testdata/cro.avb");
    if (eql(name, "dan original")) return @embedFile("../assets/testdata/dan.avb");
    if (eql(name, "denise original")) return @embedFile("../assets/testdata/denise.avb");
    if (eql(name, "hugh original")) return @embedFile("../assets/testdata/hugh.avb");
    if (eql(name, "jordan original")) return @embedFile("../assets/testdata/jordan.avb");
    if (eql(name, "kevin original")) return @embedFile("../assets/testdata/kevin.avb");
    if (eql(name, "kwensa original")) return @embedFile("../assets/testdata/kwensa.avb");
    if (eql(name, "lance original")) return @embedFile("../assets/testdata/lance.avb");
    if (eql(name, "lynnea original")) return @embedFile("../assets/testdata/lynnea.avb");
    if (eql(name, "margaret original")) return @embedFile("../assets/testdata/margaret.avb");
    if (eql(name, "maynard original")) return @embedFile("../assets/testdata/maynard.avb");
    if (eql(name, "mike original")) return @embedFile("../assets/testdata/mike.avb");
    if (eql(name, "rebecca original")) return @embedFile("../assets/testdata/rebecca.avb");
    if (eql(name, "sage original")) return @embedFile("../assets/testdata/sage.avb");
    if (eql(name, "scotty original")) return @embedFile("../assets/testdata/scotty.avb");
    if (eql(name, "susan original")) return @embedFile("../assets/testdata/susan.avb");
    if (eql(name, "tiki original")) return @embedFile("../assets/testdata/tiki.avb");
    if (eql(name, "tongtyed original")) return @embedFile("../assets/testdata/tongtyed.avb");
    if (eql(name, "xeno original")) return @embedFile("../assets/testdata/xeno.avb");
    return null;
}

test "implicit title and first conversation panel use the source two-column page" {
    const gpa = std.testing.allocator;
    const lines = [_]Line{.{ .speaker = "anna", .text = "Hi." }};
    var image = try render(gpa, &lines);
    defer image.deinit(gpa);
    try std.testing.expectEqual(@as(u32, 2 * panel_width + device_interstice), image.width);
    try std.testing.expectEqual(panel_height, image.height);
    try std.testing.expectEqual(white, image.pixels[0]);
    try std.testing.expectEqual(black, image.pixels[panel_width + device_interstice]);
}

test "repeated speaker starts a fresh panel and wraps after two columns" {
    const gpa = std.testing.allocator;
    const lines = [_]Line{
        .{ .speaker = "anna", .text = "One." },
        .{ .speaker = "anna", .text = "Two." },
    };
    var image = try render(gpa, &lines);
    defer image.deinit(gpa);
    try std.testing.expectEqual(@as(u32, 2 * panel_width + device_interstice), image.width);
    try std.testing.expectEqual(@as(u32, 2 * panel_height + device_interstice), image.height);
}

test "desktop page density can place four panels across without changing panel geometry" {
    const gpa = std.testing.allocator;
    const lines = [_]Line{
        .{ .speaker = "anna", .text = "One." },
        .{ .speaker = "anna", .text = "Two." },
        .{ .speaker = "anna", .text = "Three." },
    };
    var image = try renderWithOptions(gpa, &lines, .{ .page_columns = 4 });
    defer image.deinit(gpa);
    try std.testing.expectEqual(@as(u32, 4 * panel_width + 3 * device_interstice), image.width);
    try std.testing.expectEqual(panel_height, image.height);
}

test "desktop reserved grid keeps sparse and break-only pages at selected density" {
    const gpa = std.testing.allocator;
    var sparse = try renderWithOptions(gpa, &.{.{ .speaker = "anna", .text = "One." }}, .{
        .page_columns = 4,
        .reserve_page_columns = true,
    });
    defer sparse.deinit(gpa);
    try std.testing.expectEqual(@as(u32, 4 * panel_width + 3 * device_interstice), sparse.width);
    try std.testing.expectEqual(panel_height, sparse.height);

    var break_only = try renderWithOptions(gpa, &.{.{ .speaker = "anna", .text = "<Brk>" }}, .{
        .page_columns = 4,
        .reserve_page_columns = true,
    });
    defer break_only.deinit(gpa);
    try std.testing.expectEqual(sparse.width, break_only.width);
    try std.testing.expectEqual(sparse.height, break_only.height);
}

test "render is deterministic and rejects an unknown avatar" {
    const gpa = std.testing.allocator;
    const lines = [_]Line{
        .{ .speaker = "anna", .text = "The same seed." },
        .{ .speaker = "kevin", .text = "The same page." },
    };
    var first = try render(gpa, &lines);
    defer first.deinit(gpa);
    var second = try render(gpa, &lines);
    defer second.deinit(gpa);
    try std.testing.expectEqualSlices(u32, first.pixels, second.pixels);
    try std.testing.expectError(
        error.UnknownAvatar,
        render(gpa, &.{.{ .speaker = "not-an-avatar", .text = "No avatar." }}),
    );
}

test "stable identities sharing one avatar remain distinct panel speakers" {
    const gpa = std.testing.allocator;
    const lines = [_]Line{
        .{ .identity = "Alice", .display_name = "Alice", .avatar = "anna", .text = "One." },
        .{ .identity = "Bob", .display_name = "Bob", .avatar = "anna", .text = "Two." },
    };
    var image = try render(gpa, &lines);
    defer image.deinit(gpa);

    // AddLine checks stable avatar/user identity. Selecting the same AVB asset
    // must not turn Bob into a repeated utterance by Alice.
    try std.testing.expectEqual(panel_height, image.height);
}

test "cooked UDI pose traverses exact ordinal assembly and logical drawing" {
    const gpa = std.testing.allocator;
    const lines = [_]Line{.{
        .identity = "Alice",
        .display_name = "Alice",
        .avatar = "anna",
        .text = "A cooked source pose.",
        .pose_state = .{
            .gesture = .{ .index = 2, .emotion = 10, .intensity = 10 },
            .expression = .{ .index = 1, .emotion = 8, .intensity = 10 },
            .requested = true,
        },
    }};
    var image = try render(gpa, &lines);
    defer image.deinit(gpa);
    try std.testing.expectEqual(2 * panel_width + device_interstice, image.width);
    try std.testing.expectEqual(panel_height, image.height);
}

test "source AddTalkTos publishes addressed bodies to later AddLine checks" {
    const gpa = std.testing.allocator;
    const bob = [_]Participant{.{ .identity = "Bob", .display_name = "Bob", .avatar = "kevin" }};
    const lines = [_]Line{
        .{
            .identity = "Alice",
            .display_name = "Alice",
            .avatar = "anna",
            .text = "Bob, look over here.",
            .talk_targets = &bob,
        },
        .{ .identity = "Bob", .display_name = "Bob", .avatar = "kevin", .text = "I am here." },
    };
    var image = try render(gpa, &lines);
    defer image.deinit(gpa);

    // AddTalkTos put Bob's body in the first conversation panel, so the
    // source AvatarInPanel preflight starts a fresh panel for Bob's speech.
    try std.testing.expectEqual(2 * panel_height + device_interstice, image.height);
}

test "Chr derives uncooked pose or installs cooked UDI and preserves global establishing state" {
    const gpa = std.testing.allocator;
    var body = try OwnedLine.init(gpa, "Alice", "Alice", "anna", "Hello.", &.{}, "I feel happy.", null, &.{}, original_page.bm_say, true);
    defer body.deinit(gpa);
    try updateReactionBody(gpa, &body, .{ .identity = "Alice", .avatar = "anna", .text = "<Chr>" });
    try std.testing.expectEqualStrings("<Chr>", body.pose_text);
    try std.testing.expect(body.pose_state == null);

    const cooked = udi.PoseState{
        .gesture = .{ .index = 2, .emotion = 10, .intensity = 10 },
        .expression = .{ .index = 1, .emotion = 8, .intensity = 10 },
        .requested = true,
    };
    try updateReactionBody(gpa, &body, .{
        .identity = "Alice",
        .avatar = "anna",
        .text = "<Chr>",
        .pose_state = cooked,
    });
    try std.testing.expectEqual(cooked, body.pose_state.?);

    var newed_panel = false;
    updateNewedPanel(&newed_panel, .line, false);
    try std.testing.expect(newed_panel);
    try std.testing.expect(isEstablishing(1, newed_panel));
    // AddReaction never writes g_bNewedPanel. The clone of the first
    // conversation panel is therefore no longer an establishing shot.
    updateNewedPanel(&newed_panel, .reaction, true);
    try std.testing.expect(newed_panel);
    try std.testing.expect(!isEstablishing(2, newed_panel));
    // A subsequent normal cloned AddLine explicitly clears the global.
    updateNewedPanel(&newed_panel, .line, true);
    try std.testing.expect(!newed_panel);
    try std.testing.expect(isEstablishing(2, newed_panel));
}

test "title labels use display names rather than avatar asset names" {
    const gpa = std.testing.allocator;
    var legacy = try render(gpa, &.{.{ .speaker = "anna", .text = "Hello." }});
    defer legacy.deinit(gpa);
    var named = try render(gpa, &.{.{
        .identity = "user-42",
        .display_name = "Alice",
        .avatar = "anna",
        .text = "Hello.",
    }});
    defer named.deinit(gpa);
    try std.testing.expect(!std.mem.eql(
        u32,
        legacy.pixels[0 .. panel_width * panel_height],
        named.pixels[0 .. panel_width * panel_height],
    ));
}

test "explicit title roster renders silent users in AddStarsAux order" {
    const gpa = std.testing.allocator;
    const lines = [_]Line{.{
        .identity = "Self",
        .display_name = "Self",
        .avatar = "anna",
        .text = "Only the local user has spoken.",
    }};
    const unsorted = [_]TitleParticipant{
        .{ .identity = "Self", .avatar = "anna", .is_self = true, .sends = 1 },
        .{ .identity = "Gone", .avatar = "xeno", .departed = true, .sends = 99 },
        .{ .identity = "Silent", .avatar = "mike", .sends = 1 },
    };
    const source_order = [_]TitleParticipant{
        .{ .identity = "Self", .avatar = "anna", .is_self = true, .sends = 1 },
        .{ .identity = "Silent", .avatar = "mike", .sends = 1 },
        .{ .identity = "Gone", .avatar = "xeno", .departed = true, .sends = 99 },
    };

    var inferred = try renderTitlePanel(gpa, &lines, .{ .title = "ROSTER" });
    defer inferred.deinit(gpa);
    var live = try renderTitlePanel(gpa, &lines, .{
        .title = "ROSTER",
        .title_roster = &unsorted,
    });
    defer live.deinit(gpa);
    var sorted = try renderTitlePanel(gpa, &lines, .{
        .title = "ROSTER",
        .title_roster = &source_order,
    });
    defer sorted.deinit(gpa);

    try std.testing.expect(!std.mem.eql(u32, inferred.pixels, live.pixels));
    try std.testing.expectEqualSlices(u32, live.pixels, sorted.pixels);
}

test "random title consumes one document RNG value while explicit title consumes none" {
    var default_rng = original_page.MsvcrtRand.init(1);
    const source_default = resolveDocumentTitle(.{}, &default_rng);
    try std.testing.expectEqualStrings("EVERYONE'S A COMIC", source_default.title.?);
    try std.testing.expectEqual(@as(u15, 18467), default_rng.rand());

    var explicit_rng = original_page.MsvcrtRand.init(0x12345678);
    const explicit = resolveDocumentTitle(.{ .document_seed = 0x12345678, .title = "COMIC CHAT" }, &explicit_rng);
    try std.testing.expectEqualStrings("COMIC CHAT", explicit.title.?);
    try std.testing.expectEqual(@as(u32, 0x12345678), explicit_rng.state);

    var expected_rng = original_page.MsvcrtRand.init(0x12345678);
    const expected_title = original_title.englishRandomTitle(expected_rng.randFloat());
    const expected_panel_seed = expected_rng.rand();
    var random_rng = original_page.MsvcrtRand.init(0x12345678);
    const random = resolveDocumentTitle(.{ .document_seed = 0x12345678 }, &random_rng);
    try std.testing.expectEqualStrings(expected_title, random.title.?);
    // Planner::init is the next consumer, matching AddNewPage/AddTitle after
    // GetComicsTitle in InitMyDocument.
    try std.testing.expectEqual(expected_panel_seed, random_rng.rand());
}

test "long title wraps and participant names use source single-line ellipsis" {
    const gpa = std.testing.allocator;
    var wrapped = try renderWithOptions(gpa, &.{.{
        .identity = "member-1",
        .display_name = "THIS PARTICIPANT DISPLAY NAME IS DELIBERATELY MUCH TOO LONG FOR THE STAR ROW",
        .avatar = "anna",
        .text = "Hello.",
    }}, .{
        .title = "A VERY LONG COMIC CHAT TITLE WHICH WRAPS AT SOURCE WORD BOUNDARIES ACROSS MULTIPLE LINES",
    });
    defer wrapped.deinit(gpa);

    // The title page remains bounded and deterministic even when CLabel uses
    // multiple lines and CStarLabel's DrawTextEx path clips with an ellipsis.
    try std.testing.expectEqual(2 * panel_width + device_interstice, wrapped.width);
    var repeated = try renderWithOptions(gpa, &.{.{
        .identity = "member-1",
        .display_name = "THIS PARTICIPANT DISPLAY NAME IS DELIBERATELY MUCH TOO LONG FOR THE STAR ROW",
        .avatar = "anna",
        .text = "Hello.",
    }}, .{
        .title = "A VERY LONG COMIC CHAT TITLE WHICH WRAPS AT SOURCE WORD BOUNDARIES ACROSS MULTIPLE LINES",
    });
    defer repeated.deinit(gpa);
    try std.testing.expectEqualSlices(u32, wrapped.pixels, repeated.pixels);
}

test "latest page crop keeps a short page and crops a tall page from the bottom" {
    const short = latestPageCrop(650, 315, 400, 400);
    try std.testing.expectEqual(@as(u32, 0), short.y);
    try std.testing.expectEqual(@as(u32, 650), short.w);
    try std.testing.expectEqual(@as(u32, 315), short.h);

    const three_rows = 3 * panel_height + 2 * device_interstice;
    const tall = latestPageCrop(650, three_rows, 325, 315);
    try std.testing.expectEqual(@as(u32, 650), tall.w);
    try std.testing.expectEqual(panel_height, tall.h);
    try std.testing.expectEqual(2 * (panel_height + device_interstice), tall.y);

    const two_rows = 2 * panel_height + device_interstice;
    const mid_row = latestPageCrop(4 * panel_width + 3 * device_interstice, two_rows, 700, 250);
    try std.testing.expectEqual(panel_height, mid_row.h);
    try std.testing.expectEqual(panel_height + device_interstice, mid_row.y);
}

test "Anna Color continuation keeps her head in the panel" {
    const gpa = std.testing.allocator;
    const lines = [_]Line{
        .{ .speaker = "anna color", .text = "Great. The comic view feels much clearer now." },
        .{ .speaker = "anna color", .text = "A repeated speaker starts a fresh panel that must still show her face." },
    };
    var image = try renderWithOptions(gpa, &lines, .{
        .page_columns = 4,
        .reserve_page_columns = true,
        .backdrop = @embedFile("../assets/generated/color-cafe.bgb"),
    });
    defer image.deinit(gpa);
    try std.testing.expect(image.height >= panel_height);

    const stride = panel_width + device_interstice;
    const row_stride = panel_height + device_interstice;
    const cols = if (stride == 0) 1 else image.width / stride + 1;
    const rows = if (image.height == panel_height) 1 else image.height / row_stride + 1;
    var checked: usize = 0;
    var row: u32 = 0;
    while (row < rows) : (row += 1) {
        var col: u32 = 0;
        while (col < cols) : (col += 1) {
            if (row == 0 and col == 0) continue;
            const x0 = col * stride;
            const y0 = row * row_stride;
            if (x0 + panel_width > image.width or y0 + panel_height > image.height) continue;
            var high_red: usize = 0;
            var high_peach: usize = 0;
            var ink_min_y: u32 = panel_height;
            var ink_max_y: u32 = 0;
            var y: u32 = 0;
            while (y < panel_height) : (y += 1) {
                var x: u32 = 0;
                while (x < panel_width) : (x += 1) {
                    const pixel = image.pixels[(y0 + y) * image.width + x0 + x];
                    const red: i32 = @as(u8, @truncate(pixel >> 16));
                    const green: i32 = @as(u8, @truncate(pixel >> 8));
                    const blue: i32 = @as(u8, @truncate(pixel));
                    if (red == green and green == blue) continue;
                    if (red >= 245 and green >= 245 and blue >= 245) continue;
                    const peach = red > green + 15 and red > blue + 15 and green + 25 > blue and
                        red > 90 and red < 230 and green > 60 and blue > 40;
                    const tube = red > 120 and red > green + 40 and red > blue + 40 and green < 90;
                    if (peach or tube) {
                        ink_min_y = @min(ink_min_y, y);
                        ink_max_y = @max(ink_max_y, y + 1);
                    }
                    if (y >= (panel_height * 6) / 10) continue;
                    if (tube) high_red += 1;
                    if (peach) high_peach += 1;
                }
            }
            if (high_red + high_peach < 20) continue;
            // A legs-only dest has the red top and face below the midline.
            try std.testing.expect(high_peach > 10);
            try std.testing.expect(high_red > 8);
            // Full standing dest occupies most of the panel, not a mid-thigh crop.
            try std.testing.expect(ink_max_y > ink_min_y);
            try std.testing.expect(ink_max_y - ink_min_y >= (panel_height * 45) / 100);
            try std.testing.expect(ink_min_y < panel_height / 3);
            try std.testing.expect(ink_max_y > (panel_height * 7) / 10);
            // Face sits below a 3-line balloon, not under it.
            var face_peach: usize = 0;
            var y_face: u32 = panel_height / 4;
            while (y_face < (panel_height * 6) / 10) : (y_face += 1) {
                var x: u32 = 0;
                while (x < panel_width) : (x += 1) {
                    const pixel = image.pixels[(y0 + y_face) * image.width + x0 + x];
                    const red: i32 = @as(u8, @truncate(pixel >> 16));
                    const green: i32 = @as(u8, @truncate(pixel >> 8));
                    const blue: i32 = @as(u8, @truncate(pixel));
                    if (red > green + 15 and red > blue + 15 and green + 25 > blue and
                        red > 90 and red < 230 and green > 60 and blue > 40)
                        face_peach += 1;
                }
            }
            try std.testing.expect(face_peach > 8);
            checked += 1;
        }
    }
    try std.testing.expect(checked >= 2);

    var sticker_edge: usize = 0;
    row = 0;
    while (row < rows) : (row += 1) {
        var col: u32 = 0;
        while (col < cols) : (col += 1) {
            if (row == 0 and col == 0) continue;
            const x0 = col * stride;
            const y0 = row * row_stride;
            if (x0 + panel_width > image.width or y0 + panel_height > image.height) continue;
            var y: u32 = 4;
            while (y + 4 < panel_height) : (y += 1) {
                var x: u32 = 4;
                while (x + 4 < panel_width) : (x += 1) {
                    const pixel = image.pixels[(y0 + y) * image.width + x0 + x];
                    const red: i32 = @as(u8, @truncate(pixel >> 16));
                    const green: i32 = @as(u8, @truncate(pixel >> 8));
                    const blue: i32 = @as(u8, @truncate(pixel));
                    if (red < 245 or green < 245 or blue < 245) continue;
                    var body_ink = false;
                    var room = false;
                    var dy: i32 = -1;
                    while (dy <= 1) : (dy += 1) {
                        var dx: i32 = -1;
                        while (dx <= 1) : (dx += 1) {
                            if (dx == 0 and dy == 0) continue;
                            const ny: u32 = @intCast(@as(i64, y0) + @as(i64, y) + dy);
                            const nx: u32 = @intCast(@as(i64, x0) + @as(i64, x) + dx);
                            const n = image.pixels[ny * image.width + nx];
                            const nr: i32 = @as(u8, @truncate(n >> 16));
                            const ng: i32 = @as(u8, @truncate(n >> 8));
                            const nb: i32 = @as(u8, @truncate(n));
                            const peach = nr > ng + 15 and nr > nb + 15 and ng + 25 > nb and
                                nr > 90 and nr < 230 and ng > 60 and nb > 40;
                            const tube = nr > 120 and nr > ng + 40 and nr > nb + 40 and ng < 90;
                            const hair = nr > 40 and nr > ng + 20 and nr > nb + 20 and ng < 80 and nb < 50;
                            const outline = @max(@max(nr, ng), nb) < 45;
                            if (peach or tube or hair or outline) body_ink = true;
                            const sky = nb > nr + 15 and nb > ng + 5 and nb > 80;
                            const plant = ng > nr + 12 and ng > nb + 8 and ng > 70;
                            const wood = nr > 70 and nr >= ng and ng + 10 >= nb and nr - nb > 20 and
                                nr < 210 and ng < 160 and !peach and !tube;
                            if (sky or plant or wood) room = true;
                        }
                    }
                    if (body_ink and room) sticker_edge += 1;
                }
            }
        }
    }
    try std.testing.expect(sticker_edge < 20);
}

test "Anna Color tall balloon keeps her face clear" {
    const gpa = std.testing.allocator;
    const lines = [_]Line{
        .{
            .speaker = "anna color",
            .text = "Great. The comic view feels much clearer now and the standing Color figures keep their faces visible even when the balloon needs several more lines of text than a short dest would allow without sliding.",
        },
    };
    var image = try renderWithOptions(gpa, &lines, .{
        .page_columns = 4,
        .reserve_page_columns = true,
        .backdrop = @embedFile("../assets/generated/color-cafe.bgb"),
    });
    defer image.deinit(gpa);
    try std.testing.expect(image.height >= panel_height);

    const stride = panel_width + device_interstice;
    const cols = if (stride == 0) 1 else image.width / stride + 1;
    var checked: usize = 0;
    var col: u32 = 1;
    while (col < cols) : (col += 1) {
        const x0 = col * stride;
        if (x0 + panel_width > image.width) continue;
        var face_peach: usize = 0;
        var high_red: usize = 0;
        var y: u32 = panel_height / 4;
        while (y < (panel_height * 6) / 10) : (y += 1) {
            var x: u32 = 0;
            while (x < panel_width) : (x += 1) {
                const pixel = image.pixels[y * image.width + x0 + x];
                const red: i32 = @as(u8, @truncate(pixel >> 16));
                const green: i32 = @as(u8, @truncate(pixel >> 8));
                const blue: i32 = @as(u8, @truncate(pixel));
                if (red > green + 15 and red > blue + 15 and green + 25 > blue and
                    red > 90 and red < 230 and green > 60 and blue > 40)
                    face_peach += 1;
                if (red > 120 and red > green + 40 and red > blue + 40 and green < 90)
                    high_red += 1;
            }
        }
        if (face_peach + high_red < 20) continue;
        // Dest paints after balloons on Color, so peach stays visible even
        // when a docked cloud is taller than the dest gap.
        try std.testing.expect(face_peach > 8);
        checked += 1;
    }
    try std.testing.expect(checked >= 1);
}

test "Color cafe and apartment keep wood plants and sky" {
    const gpa = std.testing.allocator;
    const rooms = [_][]const u8{
        @embedFile("../assets/generated/color-cafe.bgb"),
        @embedFile("../assets/generated/color-apartment.bgb"),
    };
    for (rooms) |data| {
        var image = try bgb.decodeBackground(gpa, data);
        defer image.deinit(gpa);
        var brown: usize = 0;
        var green: usize = 0;
        var blue: usize = 0;
        var purple: usize = 0;
        for (image.pixels) |pixel| {
            const red: i32 = @as(u8, @truncate(pixel >> 16));
            const green_ch: i32 = @as(u8, @truncate(pixel >> 8));
            const blue_ch: i32 = @as(u8, @truncate(pixel));
            if (red == green_ch and green_ch == blue_ch) continue;
            if (red > green_ch + 15 and red > blue_ch + 10 and green_ch > 40 and green_ch + 40 > blue_ch)
                brown += 1;
            if (green_ch > red + 15 and green_ch > blue_ch + 10)
                green += 1;
            if (blue_ch > red + 15 and blue_ch + 10 > green_ch)
                blue += 1;
            if (blue_ch + 10 > red and (blue_ch > green_ch + 20 or red > green_ch + 20) and
                @abs(red - blue_ch) < 60)
                purple += 1;
        }
        try std.testing.expect(brown > 80);
        try std.testing.expect(green > 40);
        try std.testing.expect(blue > 40);
        try std.testing.expect(brown + green + blue > purple);
    }
}

test "Color and whacky rooms do not package a paper sheet gutter" {
    const gpa = std.testing.allocator;
    const rooms = [_][]const u8{
        @embedFile("../assets/generated/color-apartment.bgb"),
        @embedFile("../assets/generated/color-boardwalk.bgb"),
        @embedFile("../assets/generated/color-cafe.bgb"),
        @embedFile("../assets/generated/color-campsite.bgb"),
        @embedFile("../assets/generated/color-library.bgb"),
        @embedFile("../assets/generated/color-park.bgb"),
        @embedFile("../assets/generated/color-rainy-street.bgb"),
        @embedFile("../assets/generated/color-rooftop.bgb"),
        @embedFile("../assets/generated/color-school-hall.bgb"),
        @embedFile("../assets/generated/color-space-corridor.bgb"),
        @embedFile("../assets/generated/whacky-arcade-planetarium.bgb"),
        @embedFile("../assets/generated/whacky-asteroid-diner.bgb"),
        @embedFile("../assets/generated/whacky-cloud-train-station.bgb"),
        @embedFile("../assets/generated/whacky-cosmic-laundromat.bgb"),
        @embedFile("../assets/generated/whacky-friendly-castle.bgb"),
        @embedFile("../assets/generated/whacky-mushroom-village.bgb"),
        @embedFile("../assets/generated/whacky-pinball-interior.bgb"),
        @embedFile("../assets/generated/whacky-sky-island-market.bgb"),
        @embedFile("../assets/generated/whacky-spaceship-bridge.bgb"),
        @embedFile("../assets/generated/whacky-underwater-dome.bgb"),
    };
    for (rooms) |data| {
        var image = try bgb.decodeBackground(gpa, data);
        defer image.deinit(gpa);
        try std.testing.expectEqual(@as(u32, 315), image.width);
        try std.testing.expectEqual(@as(u32, 315), image.height);
        var top: usize = 0;
        var bot: usize = 0;
        var left: usize = 0;
        var right: usize = 0;
        var x: u32 = 0;
        while (x < image.width) : (x += 1) {
            const t = image.pixels[x];
            const b = image.pixels[(image.height - 1) * image.width + x];
            const tr: u8 = @truncate(t >> 16);
            const tg: u8 = @truncate(t >> 8);
            const tb: u8 = @truncate(t);
            const br: u8 = @truncate(b >> 16);
            const bg_ch: u8 = @truncate(b >> 8);
            const bb: u8 = @truncate(b);
            if (tr >= 245 and tg >= 245 and tb >= 245) top += 1;
            if (br >= 245 and bg_ch >= 245 and bb >= 245) bot += 1;
        }
        var y: u32 = 0;
        while (y < image.height) : (y += 1) {
            const l = image.pixels[y * image.width];
            const r = image.pixels[y * image.width + image.width - 1];
            const lr: u8 = @truncate(l >> 16);
            const lg: u8 = @truncate(l >> 8);
            const lb: u8 = @truncate(l);
            const rr: u8 = @truncate(r >> 16);
            const rg: u8 = @truncate(r >> 8);
            const rb: u8 = @truncate(r);
            if (lr >= 245 and lg >= 245 and lb >= 245) left += 1;
            if (rr >= 245 and rg >= 245 and rb >= 245) right += 1;
        }
        try std.testing.expect(top * 10 < image.width * 9);
        try std.testing.expect(bot * 10 < image.width * 9);
        try std.testing.expect(left * 10 < image.height * 9);
        try std.testing.expect(right * 10 < image.height * 9);
    }
}

test "every Color default chrome portrait stays a standing silhouette" {
    const gpa = std.testing.allocator;
    const names = [_][]const u8{
        "anna color",     "armando color", "bolo color",     "cro color",     "dan color",   "denise color",
        "hugh color",     "jordan color",  "kevin color",    "kwensa color",  "lance color", "lynnea color",
        "margaret color", "maynard color", "mike color",     "rebecca color", "sage color",  "scotty color",
        "susan color",    "tiki color",    "tongtyed color", "xeno color",    "anna hd",     "armando hd",
        "bolo hd",        "cro hd",        "dan hd",         "denise hd",     "hugh hd",     "jordan hd",
        "kevin hd",       "kwensa hd",     "lance hd",       "lynnea hd",     "margaret hd", "maynard hd",
        "mike hd",        "rebecca hd",    "sage hd",        "scotty hd",     "susan hd",    "tiki hd",
        "tongtyed hd",    "xeno hd",
    };
    for (names) |name| {
        const data = avatarByName(name) orelse return error.TestUnexpectedResult;
        var portrait = try figure.chromePortrait(gpa, data);
        defer portrait.deinit(gpa);
        try std.testing.expect(portrait.height >= 120);
        try std.testing.expect(portrait.height + 16 > portrait.width);
        var colorful = false;
        for (portrait.pixels) |pixel| {
            if (pixel >> 24 == 0) continue;
            const red: u8 = @truncate(pixel >> 16);
            const green: u8 = @truncate(pixel >> 8);
            const blue: u8 = @truncate(pixel);
            if (red != green or green != blue) {
                colorful = true;
                break;
            }
        }
        try std.testing.expect(colorful);
    }
}

test "testdata anna mapping is unchanged for Microsoft goldens" {
    const testdata = avatarByName("anna") orelse return error.TestUnexpectedResult;
    const color = avatarByName("anna color") orelse return error.TestUnexpectedResult;
    try std.testing.expect(testdata.ptr != color.ptr);
}

test "Color wrap story panels fill the bezel without paper bleed" {
    const gpa = std.testing.allocator;
    const lines = [_]Line{
        .{ .speaker = "anna color", .text = "Great. The comic view feels much clearer now." },
        .{ .speaker = "anna color", .text = "A repeated speaker starts a fresh panel that must still show her face." },
    };
    var image = try renderWithOptions(gpa, &lines, .{
        .page_columns = 4,
        .reserve_page_columns = true,
        .backdrop = @embedFile("../assets/generated/color-cafe.bgb"),
    });
    defer image.deinit(gpa);

    const stride = panel_width + device_interstice;
    const row_stride = panel_height + device_interstice;
    const cols = if (stride == 0) 1 else image.width / stride + 1;
    const rows = if (image.height == panel_height) 1 else image.height / row_stride + 1;
    var checked: usize = 0;
    var row: u32 = 0;
    while (row < rows) : (row += 1) {
        var col: u32 = 0;
        while (col < cols) : (col += 1) {
            if (row == 0 and col == 0) continue;
            const x0 = col * stride;
            const y0 = row * row_stride;
            if (x0 + panel_width > image.width or y0 + panel_height > image.height) continue;
            var wood: usize = 0;
            var y_scan: u32 = 8;
            while (y_scan + 8 < panel_height) : (y_scan += 1) {
                var x_scan: u32 = 8;
                while (x_scan + 8 < panel_width) : (x_scan += 1) {
                    const pixel = image.pixels[(y0 + y_scan) * image.width + x0 + x_scan];
                    const red: i32 = @as(u8, @truncate(pixel >> 16));
                    const green: i32 = @as(u8, @truncate(pixel >> 8));
                    const blue: i32 = @as(u8, @truncate(pixel));
                    if (red > 70 and red >= green and green + 10 >= blue and red - blue > 20 and
                        red < 210 and green < 160)
                        wood += 1;
                }
            }
            if (wood < 40) continue;
            var paper: usize = 0;
            var inset: u32 = 1;
            while (inset <= 3) : (inset += 1) {
                var x: u32 = 8;
                while (x + 8 < panel_width) : (x += 1) {
                    const bottom = image.pixels[(y0 + panel_height - 1 - inset) * image.width + x0 + x];
                    const red: u8 = @truncate(bottom >> 16);
                    const green: u8 = @truncate(bottom >> 8);
                    const blue: u8 = @truncate(bottom);
                    if (red >= 248 and green >= 248 and blue >= 248) paper += 1;
                }
                var y: u32 = 40;
                while (y + 40 < panel_height) : (y += 1) {
                    const left = image.pixels[(y0 + y) * image.width + x0 + inset];
                    const right = image.pixels[(y0 + y) * image.width + x0 + panel_width - 1 - inset];
                    inline for (.{ left, right }) |edge| {
                        const red: u8 = @truncate(edge >> 16);
                        const green: u8 = @truncate(edge >> 8);
                        const blue: u8 = @truncate(edge);
                        if (red >= 248 and green >= 248 and blue >= 248) paper += 1;
                    }
                }
            }
            try std.testing.expectEqual(@as(usize, 0), paper);
            checked += 1;
        }
    }
    try std.testing.expect(checked >= 2);
}

test "Color apartment and cafe drop the next-panel sheet sliver" {
    const gpa = std.testing.allocator;
    const rooms = [_][]const u8{
        @embedFile("../assets/generated/color-apartment.bgb"),
        @embedFile("../assets/generated/color-cafe.bgb"),
    };
    for (rooms) |encoded| {
        var image = try bgb.decodeBackground(gpa, encoded);
        defer image.deinit(gpa);
        try std.testing.expectEqual(@as(u32, 315), image.width);
        try std.testing.expectEqual(@as(u32, 315), image.height);

        var wood_count: usize = 0;
        var sky_count: usize = 0;
        var y: u32 = image.height - 16;
        while (y < image.height) : (y += 1) {
            var x: u32 = 0;
            while (x < image.width) : (x += 1) {
                const pixel = image.pixels[y * image.width + x];
                const red: u8 = @truncate(pixel >> 16);
                const green: u8 = @truncate(pixel >> 8);
                const blue: u8 = @truncate(pixel);
                if (red < 95 and green > 115 and blue > 155)
                    sky_count += 1
                else if (red > 105 and green > 70 and blue < 90)
                    wood_count += 1;
            }
        }
        try std.testing.expect(wood_count > 80);
        try std.testing.expect(wood_count > sky_count * 4);
        try std.testing.expect(sky_count < 80);
    }
}
