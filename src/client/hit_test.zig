//! Stable hit targets for the modern desktop shell.

const std = @import("std");
const geometry = @import("geometry.zig");
const ui = @import("ui.zig");
const Canvas = @import("../render/canvas.zig").Canvas;

const Rect = geometry.Rect;

pub const Target = union(enum) {
    none,
    menu: u8,
    toolbar: u8,
    room_tab,
    comic_columns_decrease,
    comic_columns_increase,
    transcript,
    composer,
    say_action: u8,
    member: usize,
    emotion,
    status_window,
    connection_status,
};

pub fn contains(rect: Rect, x: i32, y: i32) bool {
    return x >= rect.x and y >= rect.y and x < rect.right() and y < rect.bottom();
}

pub fn shell(layout: geometry.Layout, comic_mode: bool, member_icons: bool, x: i32, y: i32, member_count: usize) Target {
    if (contains(layout.status, x, y)) return .connection_status;
    if (contains(layout.menu, x, y)) return .{ .menu = menuIndex(x) orelse return .none };
    if (contains(layout.toolbar, x, y)) return .{ .toolbar = toolbarIndex(layout.toolbar, x) orelse return .none };
    if (comic_mode and layout.transcript.w >= 430 and contains(geometry.comicColumnDecrease(layout), x, y)) return .comic_columns_decrease;
    if (comic_mode and layout.transcript.w >= 430 and contains(geometry.comicColumnIncrease(layout), x, y)) return .comic_columns_increase;
    if (contains(layout.tabs, x, y)) return if (x < layout.tabs.x + 108) .status_window else .room_tab;
    if (contains(layout.say_editor, x, y)) return .composer;
    if (contains(layout.say_actions, x, y)) {
        const index = @divTrunc(x - layout.say_actions.x, layout.say_action_size);
        if (index >= 0 and index < geometry.say_button_count) return .{ .say_action = @intCast(index) };
    }
    if (contains(layout.transcript, x, y)) return .transcript;
    if (contains(layout.members, x, y)) {
        const index: usize = if (member_icons) iconIndex(layout.members, x, y) else @intCast(@max(0, @divTrunc(y - layout.members.y - 37, 24)));
        if (index < member_count) return .{ .member = index };
        return .none;
    }
    if (comic_mode and contains(layout.body_camera, x, y)) return .emotion;
    return .none;
}

fn menuIndex(pointer_x: i32) ?u8 {
    const items = [_][]const u8{ "Page", "Ink", "Show", "Look", "Room", "CAST", "Tools" };
    var x: i32 = 170;
    for (items, 0..) |item, index| {
        const right = x + Canvas.uiTextWidth(item) + 28;
        if (pointer_x >= x and pointer_x < right) return @intCast(index);
        x = right;
    }
    return null;
}

fn toolbarIndex(rect: Rect, x: i32) ?u8 {
    const ids = [_]u8{ 0, 2, 4, 5, 6, 7, 8, 10, 11, 13, 17, 18 };
    const toolbar_layout = ui.ToolbarLayout.init(rect);
    for (ids, 0..) |id, index| if (toolbar_layout.buttonRect(index)) |button| {
        if (x >= button.x and x < button.right()) return id;
    };
    return null;
}

fn iconIndex(rect: Rect, x: i32, y: i32) usize {
    const columns: i32 = @max(1, @divTrunc(rect.w, 88));
    const cell_w = @max(1, @divTrunc(rect.w, columns));
    const column = std.math.clamp(@divTrunc(x - rect.x, cell_w), 0, columns - 1);
    const row = @max(0, @divTrunc(y - rect.y - 30, 82));
    return @intCast(row * columns + column);
}

test "source shell hit targets distinguish controls and content" {
    const layout = geometry.Layout.compute(960, 720, true, true);
    try std.testing.expectEqual(Target{ .toolbar = 5 }, shell(layout, true, true, 140, geometry.menu_height + 10, 3));
    const ink_x = 170 + Canvas.uiTextWidth("Page") + 28 + @divTrunc(Canvas.uiTextWidth("Ink") + 28, 2);
    try std.testing.expectEqual(Target{ .menu = 1 }, shell(layout, true, true, ink_x, 10, 3));
    try std.testing.expectEqual(Target{ .say_action = 0 }, shell(layout, true, true, layout.say_actions.x + 2, layout.say.y + 2, 3));
    try std.testing.expectEqual(Target{ .member = 0 }, shell(layout, true, true, layout.members.x + 3, layout.members.y + 3, 3));
    try std.testing.expectEqual(Target.emotion, shell(layout, true, true, layout.body_camera.x + 3, layout.body_camera.y + 3, 3));
    try std.testing.expectEqual(Target.connection_status, shell(layout, true, true, layout.status.x + 20, layout.status.y + 10, 3));
    try std.testing.expectEqual(Target.status_window, shell(layout, true, true, layout.tabs.x + 20, layout.tabs.y + 10, 3));
    const decrease = geometry.comicColumnDecrease(layout);
    const increase = geometry.comicColumnIncrease(layout);
    try std.testing.expectEqual(Target.comic_columns_decrease, shell(layout, true, true, decrease.x + 2, decrease.y + 2, 3));
    try std.testing.expectEqual(Target.comic_columns_increase, shell(layout, true, true, increase.x + 2, increase.y + 2, 3));
}
