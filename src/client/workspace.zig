//! Owning multi-room application state shared by every native backend.

const std = @import("std");
const session = @import("../comic/session.zig");
const input = @import("input.zig");

pub const max_rooms: usize = 64;

pub const Room = struct {
    name: []u8,
    transcript: session.Transcript,
    editor: input.Editor,
    joined: bool = false,
    unread: u32 = 0,
    /// Optional channel key for reconnect (`JOIN <room> <password>`).
    join_key: ?[]u8 = null,

    fn deinit(self: *Room, gpa: std.mem.Allocator) void {
        self.transcript.deinit();
        self.editor.deinit();
        gpa.free(self.name);
        if (self.join_key) |key| gpa.free(key);
        self.* = undefined;
    }

    pub fn setJoinKey(self: *Room, gpa: std.mem.Allocator, key: []const u8) !void {
        if (self.join_key) |old| {
            gpa.free(old);
            self.join_key = null;
        }
        if (key.len == 0) return;
        self.join_key = try gpa.dupe(u8, key);
    }
};

pub const Workspace = struct {
    gpa: std.mem.Allocator,
    self_nick: []u8,
    rooms: std.ArrayList(Room) = .empty,
    active: ?usize = null,
    clipboard: std.ArrayList(u8) = .empty,

    pub fn init(gpa: std.mem.Allocator, self_nick: []const u8) !Workspace {
        return .{ .gpa = gpa, .self_nick = try gpa.dupe(u8, self_nick) };
    }

    pub fn deinit(self: *Workspace) void {
        for (self.rooms.items) |*room| room.deinit(self.gpa);
        self.rooms.deinit(self.gpa);
        self.clipboard.deinit(self.gpa);
        self.gpa.free(self.self_nick);
        self.* = undefined;
    }

    pub fn find(self: *const Workspace, name: []const u8) ?usize {
        for (self.rooms.items, 0..) |room, index| if (ircCaseEqual(room.name, name)) return index;
        return null;
    }

    pub fn ensure(self: *Workspace, name: []const u8) !usize {
        if (!validRoomName(name)) return error.InvalidRoomName;
        if (self.find(name)) |index| return index;
        if (self.rooms.items.len >= max_rooms) return error.TooManyRooms;
        const owned_name = try self.gpa.dupe(u8, name);
        errdefer self.gpa.free(owned_name);
        var transcript = session.Transcript.init(self.gpa);
        errdefer transcript.deinit();
        try transcript.setSelf(self.self_nick);
        try self.rooms.append(self.gpa, .{ .name = owned_name, .transcript = transcript, .editor = input.Editor.init(self.gpa) });
        if (self.active == null) self.active = self.rooms.items.len - 1;
        return self.rooms.items.len - 1;
    }

    pub fn activate(self: *Workspace, index: usize) bool {
        if (index >= self.rooms.items.len) return false;
        self.active = index;
        self.rooms.items[index].unread = 0;
        return true;
    }

    pub fn remove(self: *Workspace, index: usize) bool {
        if (index >= self.rooms.items.len) return false;
        var removed = self.rooms.orderedRemove(index);
        removed.deinit(self.gpa);
        if (self.rooms.items.len == 0) {
            self.active = null;
        } else if (self.active) |active| {
            self.active = if (active > index) active - 1 else @min(active, self.rooms.items.len - 1);
        }
        return true;
    }

    pub fn activeRoom(self: *Workspace) ?*Room {
        const index = self.active orelse return null;
        return &self.rooms.items[index];
    }

    pub fn observeMessage(self: *Workspace, room_name: []const u8, nick: []const u8, text: []const u8) !void {
        const index = try self.ensure(room_name);
        try self.rooms.items[index].transcript.add(nick, text);
        if (self.active != index) self.rooms.items[index].unread +|= 1;
    }

    pub fn setClipboard(self: *Workspace, text: []const u8) !void {
        self.clipboard.clearRetainingCapacity();
        try self.clipboard.appendSlice(self.gpa, text);
    }
};

fn validRoomName(name: []const u8) bool {
    return name.len >= 2 and name.len <= 200 and (name[0] == '#' or name[0] == '&') and
        std.mem.indexOfAny(u8, name, " ,\r\n\x00") == null;
}

/// RFC 1459 casemapping used by traditional IRC channel identifiers.
fn ircCaseEqual(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| if (ircFold(left) != ircFold(right)) return false;
    return true;
}

fn ircFold(value: u8) u8 {
    return switch (value) {
        'A'...'Z' => value + ('a' - 'A'),
        '[' => '{',
        ']' => '}',
        '\\' => '|',
        '^' => '~',
        else => value,
    };
}

test "workspace owns, activates, counts, and removes multiple rooms" {
    var workspace = try Workspace.init(std.testing.allocator, "alex");
    defer workspace.deinit();
    const root = try workspace.ensure("#root");
    const onyx = try workspace.ensure("#onyx");
    try std.testing.expectEqual(onyx, try workspace.ensure("#ONYX"));
    try std.testing.expectEqual(@as(usize, 0), root);
    try std.testing.expectEqual(@as(usize, 1), onyx);
    try workspace.observeMessage("#onyx", "anna", "hello");
    try workspace.rooms.items[root].editor.insert('a');
    try std.testing.expectEqual(@as(u32, 1), workspace.rooms.items[onyx].unread);
    try std.testing.expect(workspace.activate(onyx));
    try std.testing.expectEqualStrings("", workspace.activeRoom().?.editor.text());
    try std.testing.expectEqual(@as(u32, 0), workspace.rooms.items[onyx].unread);
    try std.testing.expect(workspace.remove(root));
    try std.testing.expectEqualStrings("#onyx", workspace.activeRoom().?.name);
}

test "workspace retains a room join key for reconnect" {
    var workspace = try Workspace.init(std.testing.allocator, "alex");
    defer workspace.deinit();
    const index = try workspace.ensure("#locked");
    try workspace.rooms.items[index].setJoinKey(workspace.gpa, "swordfish");
    try std.testing.expectEqualStrings("swordfish", workspace.rooms.items[index].join_key.?);
    try workspace.rooms.items[index].setJoinKey(workspace.gpa, "");
    try std.testing.expect(workspace.rooms.items[index].join_key == null);
}

test "workspace uses RFC 1459 channel casemapping" {
    var workspace = try Workspace.init(std.testing.allocator, "alex");
    defer workspace.deinit();
    const index = try workspace.ensure("#[room]\\^x");
    try std.testing.expectEqual(index, try workspace.ensure("#{ROOM}|~X"));
}
