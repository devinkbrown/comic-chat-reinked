//! Safe in-memory `.ccc` conversation and `.ccr` locator workflows.

const std = @import("std");
const record = @import("../proto/record.zig");
const udi = @import("../proto/udi.zig");
const session = @import("../comic/session.zig");

pub const max_document_bytes: usize = 16 * 1024 * 1024;

pub fn loadConversation(io: std.Io, gpa: std.mem.Allocator, path: []const u8) !session.Transcript {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(max_document_bytes));
    defer gpa.free(bytes);
    return decodeConversation(gpa, bytes);
}

pub fn saveConversation(io: std.Io, gpa: std.mem.Allocator, path: []const u8, transcript: *const session.Transcript) !void {
    const bytes = try encodeConversation(gpa, transcript);
    defer gpa.free(bytes);
    try saveBytesAtomic(io, gpa, path, bytes);
}

pub fn saveBytesAtomic(io: std.Io, gpa: std.mem.Allocator, path: []const u8, bytes: []const u8) !void {
    if (bytes.len > max_document_bytes) return error.DocumentTooLarge;
    if (path.len == 0 or std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidPath;
    const temporary = try std.fmt.allocPrint(gpa, "{s}.tmp", .{path});
    defer gpa.free(temporary);
    const cwd = std.Io.Dir.cwd();
    try cwd.writeFile(io, .{ .sub_path = temporary, .data = bytes });
    try cwd.rename(temporary, cwd, path, io);
}

/// Save a newly received file without ever replacing an existing path. The
/// exclusive create closes the check/write race and failed writes remove only
/// the file this call created, so no partial transfer is left behind.
pub fn saveBytesNew(io: std.Io, path: []const u8, bytes: []const u8) !void {
    if (bytes.len > max_document_bytes) return error.DocumentTooLarge;
    if (path.len == 0 or std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidPath;
    const cwd = std.Io.Dir.cwd();
    var file = try cwd.createFile(io, path, .{ .exclusive = true });
    var keep = false;
    defer {
        file.close(io);
        if (!keep) cwd.deleteFile(io, path) catch {};
    }
    try file.writeStreamingAll(io, bytes);
    keep = true;
}

pub fn encodeConversation(gpa: std.mem.Allocator, transcript: *const session.Transcript) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, "#CHATCONVERSATION\r\n");
    for (transcript.roster.items) |member| {
        try record.writeRecord(&out, gpa, "join", &.{member.nick});
        try record.writeRecord(&out, gpa, "changeavatar", &.{ member.nick, member.avatar, "" });
    }
    for (transcript.lines.items) |line| {
        var metadata_buf: [96]u8 = undefined;
        const pose: udi.PoseState = line.pose_state orelse .{
            .gesture = .{ .index = 0, .emotion = 0, .intensity = 0 },
            .expression = .{ .index = 0, .emotion = 0, .intensity = 0 },
            .requested = false,
        };
        const metadata = try std.fmt.bufPrint(&metadata_buf, "(G:{d} {d} {d} E:{d} {d} {d} R:{d} M:{d})", .{
            pose.gesture.index,
            pose.gesture.emotion,
            pose.gesture.intensity,
            pose.expression.index,
            pose.expression.emotion,
            pose.expression.intensity,
            @intFromBool(pose.requested),
            @intFromEnum(udi.balloonToSerial(line.modes)),
        });
        try record.writeSay(&out, gpa, line.nick, metadata, line.text);
    }
    return out.toOwnedSlice(gpa);
}

pub fn decodeConversation(gpa: std.mem.Allocator, document: []const u8) !session.Transcript {
    if (document.len > max_document_bytes) return error.DocumentTooLarge;
    var iterator = record.DocumentIterator.init(document);
    const header = iterator.next() orelse return error.MissingConversationHeader;
    if (header.type != .chat_conversation) return error.MissingConversationHeader;
    var transcript = session.Transcript.init(gpa);
    errdefer transcript.deinit();
    while (iterator.next()) |item| switch (item.type) {
        .join, .existing_join => if (item.field(0)) |nick| try transcript.setAvatar(nick, null),
        .changeavatar => if (item.field(0)) |nick| if (item.field(1)) |avatar| {
            transcript.setAvatar(nick, avatar) catch try transcript.setAvatar(nick, null);
        },
        .say => {
            const nick = item.field(0) orelse continue;
            const metadata = item.field(1) orelse "";
            const escaped = item.field(2) orelse continue;
            const text = try record.unescapeMessageAlloc(gpa, escaped);
            defer gpa.free(text);
            try transcript.addWithOptions(nick, text, .{ .modes = parseModes(metadata) });
        },
        else => {},
    };
    return transcript;
}

fn parseModes(metadata: []const u8) u16 {
    const marker = std.mem.indexOf(u8, metadata, "M:") orelse return udi.bm_say;
    const start = marker + 2;
    var end = start;
    while (end < metadata.len and std.ascii.isDigit(metadata[end])) : (end += 1) {}
    const serial = std.fmt.parseInt(u8, metadata[start..end], 10) catch return udi.bm_say;
    return udi.serialToBalloon(serial);
}

pub const Locator = struct {
    server: ?[]const u8 = null,
    channel: ?[]const u8 = null,
    character: ?[]const u8 = null,
    backdrop: ?[]const u8 = null,
    title: ?[]const u8 = null,
    view: ?[]const u8 = null,
};

pub fn parseLocator(document: []const u8) !Locator {
    if (document.len > max_document_bytes) return error.DocumentTooLarge;
    var iterator = record.LocatorIterator.init(document) orelse return error.MissingLocatorHeader;
    var locator: Locator = .{};
    while (iterator.next()) |item| {
        const value = item.field(0) orelse continue;
        switch (item.type) {
            .irc_server => locator.server = value,
            .irc_channel => locator.channel = value,
            .character => locator.character = value,
            .locator_backdrop => locator.backdrop = value,
            .title => locator.title = value,
            .view => locator.view = value,
            else => {},
        }
    }
    return locator;
}

pub fn encodeLocator(gpa: std.mem.Allocator, locator: Locator) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, "#CHATLOCATOR\r\n");
    if (locator.server) |value| try record.writeRecord(&out, gpa, "IRCSERVER:", &.{value});
    if (locator.channel) |value| try record.writeRecord(&out, gpa, "IRCCHANNEL:", &.{value});
    if (locator.character) |value| try record.writeRecord(&out, gpa, "CHARACTER:", &.{value});
    if (locator.backdrop) |value| try record.writeRecord(&out, gpa, "BACKDROP:", &.{value});
    if (locator.title) |value| try record.writeRecord(&out, gpa, "TITLE:", &.{value});
    if (locator.view) |value| try record.writeRecord(&out, gpa, "VIEW:", &.{value});
    return out.toOwnedSlice(gpa);
}

test "conversation archive round trips visible text, avatar, and balloon mode" {
    var source = session.Transcript.init(std.testing.allocator);
    defer source.deinit();
    try source.setAvatar("anna", "anna");
    try source.addWithOptions("anna", "hello\nworld", .{ .modes = udi.bm_think });
    const encoded = try encodeConversation(std.testing.allocator, &source);
    defer std.testing.allocator.free(encoded);
    var decoded = try decodeConversation(std.testing.allocator, encoded);
    defer decoded.deinit();
    try std.testing.expectEqualStrings("hello\nworld", decoded.lines.items[0].text);
    try std.testing.expectEqual(udi.bm_think, decoded.lines.items[0].modes);
    try std.testing.expectEqualStrings("anna color", decoded.roster.items[0].avatar);
}

test "locator codec keeps source document separation" {
    const encoded = try encodeLocator(std.testing.allocator, .{ .server = "eshmaki.me", .channel = "#root", .character = "anna" });
    defer std.testing.allocator.free(encoded);
    const decoded = try parseLocator(encoded);
    try std.testing.expectEqualStrings("eshmaki.me", decoded.server.?);
    try std.testing.expectEqualStrings("#root", decoded.channel.?);
}
