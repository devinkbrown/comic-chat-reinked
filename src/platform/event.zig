//! Window-system-independent native input contract.

const std = @import("std");

pub const Key = union(enum) {
    char: u21,
    backspace,
    enter,
    escape,
    tab,
    left,
    right,
    up,
    down,
    home,
    end,
    page_up,
    page_down,
    delete,
    other,
};

pub const PointerButton = enum { none, primary, middle, secondary };
pub const PointerKind = enum { move, down, up, wheel };

pub const Modifiers = packed struct(u8) {
    shift: bool = false,
    control: bool = false,
    alt: bool = false,
    super: bool = false,
    _reserved: u4 = 0,
};

pub const KeyInput = struct {
    key: Key,
    modifiers: Modifiers = .{},
};

pub const Pointer = struct {
    kind: PointerKind,
    x: i32,
    y: i32,
    button: PointerButton = .none,
    /// Positive is up/away and negative is down/toward, in logical ticks.
    wheel_y: i16 = 0,
    /// 1 for an ordinary activation, 2 for a native double-click.
    clicks: u8 = 1,
};

pub const Event = union(enum) {
    key: KeyInput,
    pointer: Pointer,
    resize: struct { w: u32, h: u32 },
    expose,
    close,
    other,
};

test "shared pointer event retains coordinates, button, and wheel direction" {
    const event: Event = .{ .pointer = .{
        .kind = .wheel,
        .x = 12,
        .y = 34,
        .wheel_y = -1,
    } };
    try std.testing.expectEqual(@as(i32, 12), event.pointer.x);
    try std.testing.expectEqual(@as(i16, -1), event.pointer.wheel_y);
}

/// First button still held, preferring primary so composer/emotion drag unsticks.
pub fn firstHeldPointerButton(primary: bool, middle: bool, secondary: bool) PointerButton {
    if (primary) return .primary;
    if (middle) return .middle;
    if (secondary) return .secondary;
    return .none;
}

/// LeaveNotify / `wl_pointer.leave`: release a held button, then clear hover.
pub fn pointerLeaveSequence(held: PointerButton) struct { first: Event, queued: ?Event } {
    const clear: Event = .{ .pointer = .{ .kind = .move, .x = -1, .y = -1 } };
    if (held == .none) return .{ .first = clear, .queued = null };
    return .{
        .first = .{ .pointer = .{ .kind = .up, .x = -1, .y = -1, .button = held } },
        .queued = clear,
    };
}

test "key input preserves the logical modifier contract" {
    const event: Event = .{ .key = .{ .key = .{ .char = 'c' }, .modifiers = .{ .control = true } } };
    try std.testing.expect(event.key.modifiers.control);
}

test "pointer leave releases a held button before clearing hover" {
    try std.testing.expectEqual(PointerButton.primary, firstHeldPointerButton(true, true, true));
    try std.testing.expectEqual(PointerButton.middle, firstHeldPointerButton(false, true, true));
    try std.testing.expectEqual(PointerButton.none, firstHeldPointerButton(false, false, false));
    const held = pointerLeaveSequence(.primary);
    try std.testing.expectEqual(PointerKind.up, held.first.pointer.kind);
    try std.testing.expectEqual(PointerButton.primary, held.first.pointer.button);
    try std.testing.expectEqual(@as(i32, -1), held.first.pointer.x);
    try std.testing.expectEqual(PointerKind.move, held.queued.?.pointer.kind);
    try std.testing.expectEqual(@as(i32, -1), held.queued.?.pointer.x);
    const idle = pointerLeaveSequence(.none);
    try std.testing.expectEqual(PointerKind.move, idle.first.pointer.kind);
    try std.testing.expectEqual(@as(?Event, null), idle.queued);
}
