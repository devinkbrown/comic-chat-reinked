//! Platform-independent state for the portable Microsoft-style application
//! shell. Rendering lives in `view.zig`; native backends only translate input
//! and present pixels.

const std = @import("std");
const emotion_mod = @import("../comic/emotion.zig");

pub const ContentMode = enum { comic, text };
pub const SayMode = enum { say, think, whisper, action, sound };
pub const MemberView = enum { icons, list };
pub const TranscriptSelection = struct { start: usize, end: usize };

pub const Focus = enum {
    navigation,
    toolbar,
    transcript,
    composer,
    say_actions,
    members,
    emotion,
    status,
};

pub const State = struct {
    content_mode: ContentMode = .comic,
    focus: Focus = .composer,
    history_offset: usize = 0,
    transcript_cursor: ?usize = null,
    transcript_anchor: ?usize = null,
    show_navigation: bool = true,
    show_members: bool = true,
    comic_columns: u8 = 4,
    say_mode: SayMode = .say,
    selected_member: ?usize = null,
    member_view: MemberView = .icons,
    member_offset: usize = 0,
    emotion_x: i16 = 0,
    emotion_y: i16 = 0,
    emotion_radius: i16 = 1,
    emotion_frozen: bool = false,

    pub fn cycleFocus(self: *State) void {
        self.focus = switch (self.focus) {
            .navigation => .toolbar,
            .toolbar => .transcript,
            .transcript => .composer,
            .composer => .say_actions,
            .say_actions => if (self.show_members) .members else .status,
            .members => if (self.content_mode == .comic) .emotion else .status,
            .emotion => .status,
            .status => if (self.show_navigation) .navigation else .toolbar,
        };
    }

    pub fn cycleFocusBackward(self: *State) void {
        self.focus = switch (self.focus) {
            .navigation => .status,
            .toolbar => if (self.show_navigation) .navigation else .status,
            .transcript => .toolbar,
            .composer => .transcript,
            .say_actions => .composer,
            .members => .say_actions,
            .emotion => .members,
            .status => if (self.show_members and self.content_mode == .comic) .emotion else if (self.show_members) .members else .say_actions,
        };
    }

    pub fn focusComposer(self: *State) void {
        self.focus = .composer;
    }

    pub fn toggleContentMode(self: *State) void {
        self.content_mode = switch (self.content_mode) {
            .comic => .text,
            .text => .comic,
        };
    }

    pub fn setContentMode(self: *State, mode: ContentMode) void {
        self.content_mode = mode;
    }

    pub fn toggleNavigation(self: *State) void {
        self.show_navigation = !self.show_navigation;
        if (!self.show_navigation and self.focus == .navigation) self.focus = .transcript;
    }

    pub fn toggleMembers(self: *State) void {
        self.setMembersVisible(!self.show_members);
    }

    pub fn setMembersVisible(self: *State, visible: bool) void {
        self.show_members = visible;
        if (!self.show_members and (self.focus == .members or self.focus == .emotion)) self.focus = .composer;
    }

    pub fn decreaseComicColumns(self: *State) void {
        self.comic_columns = @max(1, self.comic_columns -| 1);
    }

    pub fn increaseComicColumns(self: *State) void {
        self.comic_columns = @min(6, self.comic_columns + 1);
    }

    pub fn setComicColumns(self: *State, columns: u8) void {
        self.comic_columns = std.math.clamp(columns, 1, 6);
    }

    pub fn selectMember(self: *State, index: usize) void {
        self.selected_member = index;
        self.focus = .members;
    }

    pub fn moveMemberSelection(self: *State, count: usize, delta: i32) void {
        if (count == 0) return;
        const current: i32 = @intCast(@min(self.selected_member orelse 0, count - 1));
        self.selected_member = @intCast(std.math.clamp(current + delta, 0, @as(i32, @intCast(count - 1))));
        self.focus = .members;
    }

    pub fn setMemberView(self: *State, view: MemberView) void {
        self.member_view = view;
        self.member_offset = 0;
        self.show_members = true;
    }

    pub fn scrollMembers(self: *State, count: usize, visible: usize, step: usize, forward: bool) void {
        if (count <= visible) {
            self.member_offset = 0;
            return;
        }
        const max_offset = count - visible;
        if (forward) {
            self.member_offset = @min(max_offset, self.member_offset +| @max(step, 1));
        } else {
            self.member_offset -|= @max(step, 1);
        }
    }

    pub fn revealMember(self: *State, count: usize, visible: usize, index: usize) void {
        if (count <= visible) {
            self.member_offset = 0;
        } else if (index < self.member_offset) {
            self.member_offset = index;
        } else if (index >= self.member_offset + visible) {
            self.member_offset = @min(count - visible, index - visible + 1);
        }
    }

    pub fn setSayMode(self: *State, mode: SayMode) void {
        self.say_mode = mode;
        self.focus = .composer;
    }

    pub fn setEmotionPoint(self: *State, x: i32, y: i32, radius: i32) void {
        if (self.emotion_frozen) return;
        if (radius <= 0) return;
        const distance_sq = @as(i64, x) * x + @as(i64, y) * y;
        const radius_sq = @as(i64, radius) * radius;
        if (distance_sq <= radius_sq) {
            self.emotion_x = @intCast(std.math.clamp(x, std.math.minInt(i16), std.math.maxInt(i16)));
            self.emotion_y = @intCast(std.math.clamp(y, std.math.minInt(i16), std.math.maxInt(i16)));
            self.emotion_radius = @intCast(@min(radius, std.math.maxInt(i16)));
        }
        self.focus = .emotion;
    }

    pub fn moveEmotion(self: *State, dx: i32, dy: i32) void {
        if (self.emotion_frozen) return;
        const radius: i32 = @max(1, @as(i32, self.emotion_radius));
        const step = @max(4, @divTrunc(radius, 4));
        var next_x = @as(i32, self.emotion_x) + dx * step;
        var next_y = @as(i32, self.emotion_y) + dy * step;
        const distance_sq = @as(i64, next_x) * next_x + @as(i64, next_y) * next_y;
        const radius_sq = @as(i64, radius) * radius;
        if (distance_sq > radius_sq) {
            next_x = std.math.clamp(next_x, -radius, radius);
            next_y = std.math.clamp(next_y, -radius, radius);
            if (@as(i64, next_x) * next_x + @as(i64, next_y) * next_y > radius_sq) {
                if (@abs(next_x) >= @abs(next_y)) next_y = 0 else next_x = 0;
            }
        }
        self.setEmotionPoint(next_x, next_y, radius);
    }

    pub fn neutralEmotion(self: *State) void {
        if (self.emotion_frozen) return;
        self.emotion_x = 0;
        self.emotion_y = 0;
        self.focus = .emotion;
    }

    pub fn outerEmotion(self: *State) void {
        if (self.emotion_frozen) return;
        const radius: i32 = @max(1, @as(i32, self.emotion_radius));
        var x: i32 = self.emotion_x;
        var y: i32 = self.emotion_y;
        if (x == 0 and y == 0) {
            x = radius;
        } else {
            const scale_den: i32 = @intCast(@max(@abs(x), @abs(y)));
            x = @divTrunc(x * radius, scale_den);
            y = @divTrunc(y * radius, scale_den);
            if (@as(i64, x) * x + @as(i64, y) * y > @as(i64, radius) * radius) {
                if (@abs(x) >= @abs(y)) y = 0 else x = 0;
            }
        }
        self.setEmotionPoint(x, y, radius);
    }

    pub fn toggleEmotionFreeze(self: *State) void {
        self.emotion_frozen = !self.emotion_frozen;
        self.focus = .emotion;
    }

    pub fn selectedEmotion(self: *const State) emotion_mod.Emotion {
        const x: i32 = self.emotion_x;
        const y: i32 = self.emotion_y;
        if (x * x + y * y < 36) return .neutral;
        const ax = @abs(x);
        const ay = @abs(y);
        if (ay * 1000 < ax * 414) return if (x >= 0) .happy else .sad;
        if (ax * 1000 < ay * 414) return if (y >= 0) .bored else .shouting;
        if (x >= 0 and y >= 0) return .coy;
        if (x < 0 and y >= 0) return .scared;
        if (x < 0) return .angry;
        return .laughing;
    }

    pub fn selectedEmotionIntensity(self: *const State) u8 {
        const distance = @max(@abs(@as(i32, self.emotion_x)), @abs(@as(i32, self.emotion_y)));
        return @intCast(@min(255, @divTrunc(distance * 255, @max(1, @as(i32, self.emotion_radius)))));
    }

    pub fn pageEarlier(self: *State, total_lines: usize, page_size: usize) void {
        if (total_lines <= page_size) {
            self.history_offset = 0;
            return;
        }
        const max_offset = total_lines - page_size;
        self.history_offset = @min(max_offset, self.history_offset + page_size);
    }

    pub fn pageLater(self: *State, page_size: usize) void {
        self.history_offset -|= page_size;
    }

    pub fn jumpLatest(self: *State) void {
        self.history_offset = 0;
    }

    pub fn selectTranscriptLine(self: *State, total: usize, index: usize, extend: bool) void {
        if (total == 0) {
            self.transcript_cursor = null;
            self.transcript_anchor = null;
            return;
        }
        const bounded = @min(index, total - 1);
        if (extend) {
            if (self.transcript_anchor == null) self.transcript_anchor = self.transcript_cursor orelse bounded;
        } else {
            self.transcript_anchor = null;
        }
        self.transcript_cursor = bounded;
        self.focus = .transcript;
    }

    pub fn moveTranscriptSelection(self: *State, total: usize, delta: i32, extend: bool) void {
        if (total == 0) return self.selectTranscriptLine(0, 0, false);
        const current: i32 = @intCast(@min(self.transcript_cursor orelse total - 1, total - 1));
        self.selectTranscriptLine(total, @intCast(std.math.clamp(current + delta, 0, @as(i32, @intCast(total - 1)))), extend);
    }

    pub fn transcriptSelection(self: *const State) ?TranscriptSelection {
        const cursor = self.transcript_cursor orelse return null;
        const anchor = self.transcript_anchor orelse return .{ .start = cursor, .end = cursor + 1 };
        return .{ .start = @min(anchor, cursor), .end = @max(anchor, cursor) + 1 };
    }

    pub fn visibleRange(self: *const State, total_lines: usize, page_size: usize) struct { start: usize, end: usize } {
        if (total_lines == 0 or page_size == 0) return .{ .start = 0, .end = 0 };
        const end = total_lines -| @min(self.history_offset, total_lines);
        return .{ .start = end -| @min(page_size, end), .end = end };
    }
};

test "focus follows visible Microsoft shell regions" {
    var state: State = .{};
    try std.testing.expectEqual(Focus.composer, state.focus);
    state.cycleFocus();
    try std.testing.expectEqual(Focus.say_actions, state.focus);
    state.cycleFocus();
    try std.testing.expectEqual(Focus.members, state.focus);
    state.cycleFocus();
    try std.testing.expectEqual(Focus.emotion, state.focus);
    state.cycleFocus();
    try std.testing.expectEqual(Focus.status, state.focus);
    state.cycleFocus();
    try std.testing.expectEqual(Focus.navigation, state.focus);
    state.cycleFocus();
    try std.testing.expectEqual(Focus.toolbar, state.focus);
    state.cycleFocus();
    try std.testing.expectEqual(Focus.transcript, state.focus);
    state.cycleFocus();
    try std.testing.expectEqual(Focus.composer, state.focus);
    state.cycleFocus();
    try std.testing.expectEqual(Focus.say_actions, state.focus);
    state.toggleMembers();
    state.cycleFocus();
    try std.testing.expectEqual(Focus.status, state.focus);
    state.cycleFocus();
    try std.testing.expectEqual(Focus.navigation, state.focus);
    state.toggleNavigation();
    try std.testing.expectEqual(Focus.transcript, state.focus);
    state.cycleFocus();
    try std.testing.expectEqual(Focus.composer, state.focus);
}

test "text mode skips the comic-only emotion control" {
    var state: State = .{ .content_mode = .text, .focus = .members };
    state.cycleFocus();
    try std.testing.expectEqual(Focus.status, state.focus);
}

test "reverse focus follows the same shell order" {
    var state: State = .{ .focus = .navigation };
    state.cycleFocusBackward();
    try std.testing.expectEqual(Focus.status, state.focus);
    state.cycleFocusBackward();
    try std.testing.expectEqual(Focus.emotion, state.focus);
    state.cycleFocusBackward();
    try std.testing.expectEqual(Focus.members, state.focus);
    state.cycleFocusBackward();
    try std.testing.expectEqual(Focus.say_actions, state.focus);
    state.cycleFocusBackward();
    try std.testing.expectEqual(Focus.composer, state.focus);
}

test "history paging is bounded and returns to latest" {
    var state: State = .{};
    state.pageEarlier(30, 9);
    try std.testing.expectEqual(@as(usize, 9), state.history_offset);
    state.pageEarlier(30, 9);
    state.pageEarlier(30, 9);
    try std.testing.expectEqual(@as(usize, 21), state.history_offset);
    const range = state.visibleRange(30, 9);
    try std.testing.expectEqual(@as(usize, 0), range.start);
    try std.testing.expectEqual(@as(usize, 9), range.end);
    state.pageLater(9);
    try std.testing.expectEqual(@as(usize, 12), state.history_offset);
    state.jumpLatest();
    try std.testing.expectEqual(@as(usize, 0), state.history_offset);
}

test "comic column density defaults to four and remains adjustable within bounds" {
    var state: State = .{};
    try std.testing.expectEqual(@as(u8, 4), state.comic_columns);
    state.increaseComicColumns();
    state.increaseComicColumns();
    state.increaseComicColumns();
    try std.testing.expectEqual(@as(u8, 6), state.comic_columns);
    state.decreaseComicColumns();
    try std.testing.expectEqual(@as(u8, 5), state.comic_columns);
}

test "member roving and body camera keyboard controls stay bounded" {
    var state: State = .{ .focus = .members };
    state.moveMemberSelection(3, 1);
    try std.testing.expectEqual(@as(?usize, 1), state.selected_member);
    state.moveMemberSelection(3, 20);
    try std.testing.expectEqual(@as(?usize, 2), state.selected_member);
    state.setMemberView(.list);
    try std.testing.expectEqual(MemberView.list, state.member_view);

    state.focus = .emotion;
    state.emotion_radius = 48;
    state.moveEmotion(1, 0);
    try std.testing.expect(state.emotion_x > 0);
    state.neutralEmotion();
    try std.testing.expectEqual(@as(i16, 0), state.emotion_x);
    try std.testing.expectEqual(@as(i16, 0), state.emotion_y);
    state.outerEmotion();
    try std.testing.expectEqual(@as(i16, 48), state.emotion_x);
    try std.testing.expectEqual(@as(i16, 0), state.emotion_y);
    state.emotion_frozen = true;
    state.outerEmotion();
    try std.testing.expectEqual(@as(i16, 48), state.emotion_x);
}

test "explicit member visibility keeps focus on a visible region" {
    var state: State = .{ .focus = .members };
    state.setMembersVisible(false);
    try std.testing.expect(!state.show_members);
    try std.testing.expectEqual(Focus.composer, state.focus);
    state.setMembersVisible(true);
    try std.testing.expect(state.show_members);
}

test "member viewport scrolling and selection reveal stay bounded" {
    var state: State = .{};
    state.scrollMembers(7, 2, 2, true);
    try std.testing.expectEqual(@as(usize, 2), state.member_offset);
    state.scrollMembers(7, 2, 2, true);
    state.scrollMembers(7, 2, 2, true);
    try std.testing.expectEqual(@as(usize, 5), state.member_offset);
    state.scrollMembers(7, 2, 2, false);
    try std.testing.expectEqual(@as(usize, 3), state.member_offset);
    state.revealMember(7, 2, 0);
    try std.testing.expectEqual(@as(usize, 0), state.member_offset);
    state.revealMember(7, 2, 6);
    try std.testing.expectEqual(@as(usize, 5), state.member_offset);
}
