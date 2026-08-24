//! IRC client protocol engine (transport-agnostic, pure Zig).
//!
//! This layer knows how to *frame* the byte stream into lines and how to
//! *build* the commands Comic Chat uses. The actual socket pump (std.Io.net)
//! is a thin wrapper added on top — everything here is testable without a
//! network, which is how the original CIrcProto logic is exercised.

const std = @import("std");
pub const message = @import("message.zig");
pub const Message = message.Message;

// --- Line framing ---------------------------------------------------------

/// Accumulates raw bytes from a socket and yields complete lines (CRLF or LF
/// terminated). The slice returned by `next` is valid until the following
/// call to `next` or `push`.
pub const LineFramer = struct {
    gpa: std.mem.Allocator,
    buf: std.ArrayList(u8) = .empty,
    scratch: std.ArrayList(u8) = .empty,
    cursor: usize = 0,

    pub fn init(gpa: std.mem.Allocator) LineFramer {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *LineFramer) void {
        self.buf.deinit(self.gpa);
        self.scratch.deinit(self.gpa);
    }

    /// Feed bytes received from the transport.
    pub fn push(self: *LineFramer, data: []const u8) !void {
        try self.buf.appendSlice(self.gpa, data);
    }

    /// Return the next complete line (CR/LF stripped), or null if none is
    /// buffered yet. Empty lines are returned as zero-length slices.
    pub fn next(self: *LineFramer) !?[]const u8 {
        const data = self.buf.items[self.cursor..];
        const nl = std.mem.indexOfScalar(u8, data, '\n') orelse {
            // Maximum content is 8191 bytes of tag section plus 510 bytes of
            // ordinary IRC payload. An untagged line can never exceed 510
            // content bytes (both limits include the eventual CRLF).
            const maximum_pending: usize = if (data.len > 0 and data[0] == '@') 8701 else 510;
            if (data.len > maximum_pending) {
                self.buf.clearRetainingCapacity();
                self.cursor = 0;
                return error.IrcLineTooLong;
            }
            return null;
        };
        const line = std.mem.trimEnd(u8, data[0..nl], "\r");

        const valid_length = if (line.len > 0 and line[0] == '@') tagged: {
            const separator = std.mem.indexOfScalar(u8, line, ' ') orelse break :tagged false;
            // `separator + 1` includes both `@` and the tag separator space.
            break :tagged separator + 1 <= 8191 and line.len - separator - 1 + 2 <= 512;
        } else line.len + 2 <= 512;

        if (valid_length) {
            // Copy before clearing the source ArrayList; debug allocators are
            // allowed to poison elements outside its new logical length.
            self.scratch.clearRetainingCapacity();
            try self.scratch.appendSlice(self.gpa, line);
        }
        self.cursor += nl + 1;
        if (self.cursor >= self.buf.items.len) {
            self.buf.clearRetainingCapacity();
            self.cursor = 0;
        }
        if (!valid_length) return error.IrcLineTooLong;
        return self.scratch.items;
    }
};

// --- Command builders ------------------------------------------------------
// Each appends a single CRLF-terminated command to `out`.

pub fn writeNick(out: *std.ArrayList(u8), gpa: std.mem.Allocator, nick: []const u8) !void {
    var m = Message{ .command = "NICK" };
    m.params[0] = nick;
    m.param_count = 1;
    try message.write(out, gpa, m);
}

pub fn writeUser(
    out: *std.ArrayList(u8),
    gpa: std.mem.Allocator,
    user: []const u8,
    realname: []const u8,
) !void {
    // USER <user> <mode> * :<realname>   (mode 0, unused host field '*')
    var m = Message{ .command = "USER" };
    m.params[0] = user;
    m.params[1] = "0";
    m.params[2] = "*";
    m.params[3] = realname;
    m.param_count = 4;
    try message.write(out, gpa, m);
}

pub fn writeJoin(out: *std.ArrayList(u8), gpa: std.mem.Allocator, channel: []const u8) !void {
    return writeJoinWithKey(out, gpa, channel, "");
}

pub fn writeJoinWithKey(
    out: *std.ArrayList(u8),
    gpa: std.mem.Allocator,
    channel: []const u8,
    key: []const u8,
) !void {
    var m = Message{ .command = "JOIN" };
    m.params[0] = channel;
    if (key.len == 0) {
        m.param_count = 1;
    } else {
        m.params[1] = key;
        m.param_count = 2;
    }
    try message.write(out, gpa, m);
}

pub fn writePrivmsg(
    out: *std.ArrayList(u8),
    gpa: std.mem.Allocator,
    target: []const u8,
    text: []const u8,
) !void {
    var m = Message{ .command = "PRIVMSG", .force_trailing = true };
    m.params[0] = target;
    m.params[1] = text;
    m.param_count = 2;
    try message.write(out, gpa, m);
}

/// The source Comic Chat avatar control (`ChatAnnounceNewAvatar`):
/// `PRIVMSG <target> :# Appears as <bundled-name>.`.
pub fn writeAvatarAnnouncement(
    out: *std.ArrayList(u8),
    gpa: std.mem.Allocator,
    target: []const u8,
    avatar: []const u8,
) !void {
    if (target.len == 0 or avatar.len == 0 or
        std.mem.indexOfAny(u8, target, " \r\n") != null or
        std.mem.indexOfAny(u8, avatar, ".\r\n") != null)
        return error.InvalidIrcParameter;

    const start = out.items.len;
    errdefer out.shrinkRetainingCapacity(start);
    try out.appendSlice(gpa, "PRIVMSG ");
    try out.appendSlice(gpa, target);
    try out.appendSlice(gpa, " :# Appears as ");
    var capitalize = true;
    for (avatar) |ch| {
        if (ch == ' ') {
            capitalize = true;
            continue;
        }
        if (!std.ascii.isAlphanumeric(ch) and ch != '_' and ch != '-') return error.InvalidIrcParameter;
        try out.append(gpa, if (capitalize) std.ascii.toUpper(ch) else ch);
        capitalize = false;
    }
    try out.appendSlice(gpa, ".\r\n");
}

/// Source IRCX UDI sideband: `DATA <target> CCUDI1 :<annotation>`.
pub fn writeComicData(
    out: *std.ArrayList(u8),
    gpa: std.mem.Allocator,
    target: []const u8,
    annotation: []const u8,
) !void {
    if (target.len == 0 or annotation.len == 0 or
        std.mem.indexOfAny(u8, target, " \r\n") != null or
        std.mem.indexOfAny(u8, annotation, "\r\n") != null)
        return error.InvalidIrcParameter;
    try out.appendSlice(gpa, "DATA ");
    try out.appendSlice(gpa, target);
    try out.appendSlice(gpa, " CCUDI1 :");
    try out.appendSlice(gpa, annotation);
    try out.appendSlice(gpa, "\r\n");
}

pub fn writePong(out: *std.ArrayList(u8), gpa: std.mem.Allocator, token: []const u8) !void {
    var m = Message{ .command = "PONG" };
    m.params[0] = token;
    m.param_count = 1;
    try message.write(out, gpa, m);
}

/// Probe for Microsoft IRCX exactly as Comic Chat does before opting in.
pub fn writeIrcxProbe(out: *std.ArrayList(u8), gpa: std.mem.Allocator) !void {
    var msg = Message{ .command = "MODE" };
    msg.params[0] = "ISIRCX";
    msg.param_count = 1;
    try message.write(out, gpa, msg);
}

/// Enable Microsoft IRCX after `MODE ISIRCX` returns numeric state zero.
pub fn writeIrcx(out: *std.ArrayList(u8), gpa: std.mem.Allocator) !void {
    try message.write(out, gpa, .{ .command = "IRCX" });
}

/// Source-ordered registration handshake: optional IRCX probe, then NICK + USER.
pub fn writeRegister(
    out: *std.ArrayList(u8),
    gpa: std.mem.Allocator,
    nick: []const u8,
    user: []const u8,
    realname: []const u8,
    want_ircx: bool,
) !void {
    if (want_ircx) try writeIrcxProbe(out, gpa);
    try writeNick(out, gpa, nick);
    try writeUser(out, gpa, user, realname);
}

// --- Tests ----------------------------------------------------------------

test "LineFramer reassembles split and batched lines" {
    const gpa = std.testing.allocator;
    var fr = LineFramer.init(gpa);
    defer fr.deinit();

    // A line arriving in two chunks.
    try fr.push("PING :ser");
    try std.testing.expect((try fr.next()) == null);
    try fr.push("ver1\r\n");
    try std.testing.expectEqualStrings("PING :server1", (try fr.next()).?);
    try std.testing.expect((try fr.next()) == null);

    // Two lines in one chunk, LF-only and CRLF mixed.
    try fr.push("NICK bob\nJOIN #comics\r\n");
    try std.testing.expectEqualStrings("NICK bob", (try fr.next()).?);
    try std.testing.expectEqualStrings("JOIN #comics", (try fr.next()).?);
    try std.testing.expect((try fr.next()) == null);
}

test "register handshake emits the Microsoft IRCX discovery probe" {
    const gpa = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);

    try writeRegister(&out, gpa, "anna", "anna", "Anna Example", true);
    try std.testing.expectEqualStrings(
        "MODE ISIRCX\r\n" ++
            "NICK anna\r\n" ++
            "USER anna 0 * :Anna Example\r\n",
        out.items,
    );
}

test "privmsg builds trailing form" {
    const gpa = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);

    try writePrivmsg(&out, gpa, "#comics", "hi there");
    try std.testing.expectEqualStrings("PRIVMSG #comics :hi there\r\n", out.items);
}

test "avatar announcement uses the source control PRIVMSG" {
    const gpa = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);

    try writeAvatarAnnouncement(&out, gpa, "#comics", "anna");
    try std.testing.expectEqualStrings(
        "PRIVMSG #comics :# Appears as Anna.\r\n",
        out.items,
    );
    const before = out.items.len;
    try std.testing.expectError(
        error.InvalidIrcParameter,
        writeAvatarAnnouncement(&out, gpa, "bad target", "anna"),
    );
    try std.testing.expectEqual(before, out.items.len);
    try std.testing.expectError(
        error.InvalidIrcParameter,
        writeAvatarAnnouncement(&out, gpa, "#comics", "anna.url"),
    );
}

test "IRCX comic DATA keeps the source CCUDI1 trailing form" {
    const gpa = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try writeComicData(&out, gpa, "#comics", "#G000E000RM1");
    try std.testing.expectEqualStrings("DATA #comics CCUDI1 :#G000E000RM1\r\n", out.items);
    try std.testing.expectError(error.InvalidIrcParameter, writeComicData(&out, gpa, "bad target", "#G000E000M1"));
}

test "pong echoes the ping token" {
    const gpa = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);

    const ping = message.parse("PING :server1");
    try writePong(&out, gpa, ping.param(0).?);
    try std.testing.expectEqualStrings("PONG server1\r\n", out.items);
}

test "LineFramer: empty lines are returned as zero-length slices" {
    const gpa = std.testing.allocator;
    var fr = LineFramer.init(gpa);
    defer fr.deinit();
    try fr.push("\r\n\r\nPING x\r\n");
    try std.testing.expectEqualStrings("", (try fr.next()).?);
    try std.testing.expectEqualStrings("", (try fr.next()).?);
    try std.testing.expectEqualStrings("PING x", (try fr.next()).?);
    try std.testing.expect((try fr.next()) == null);
}

test "LineFramer: a line spanning three pushes reassembles correctly" {
    const gpa = std.testing.allocator;
    var fr = LineFramer.init(gpa);
    defer fr.deinit();
    try fr.push(":nick!u@h PRIV");
    try std.testing.expect((try fr.next()) == null);
    try fr.push("MSG #c :hel");
    try std.testing.expect((try fr.next()) == null);
    try fr.push("lo\n");
    try std.testing.expectEqualStrings(":nick!u@h PRIVMSG #c :hello", (try fr.next()).?);
}

test "LineFramer: trailing partial line stays buffered until terminated" {
    const gpa = std.testing.allocator;
    var fr = LineFramer.init(gpa);
    defer fr.deinit();
    try fr.push("DONE\nPART");
    try std.testing.expectEqualStrings("DONE", (try fr.next()).?);
    try std.testing.expect((try fr.next()) == null); // "PART" has no newline yet
    try fr.push("IAL\n");
    try std.testing.expectEqualStrings("PARTIAL", (try fr.next()).?);
}

test "LineFramer enforces ordinary and separate IRCv3 tag budgets and recovers" {
    const gpa = std.testing.allocator;
    var fr = LineFramer.init(gpa);
    defer fr.deinit();

    var ordinary: [511]u8 = undefined;
    @memset(&ordinary, 'x');
    try fr.push(&ordinary);
    try std.testing.expectError(error.IrcLineTooLong, fr.next());

    var oversized_tag: [8191]u8 = undefined;
    @memset(&oversized_tag, 'a');
    oversized_tag[0] = '@';
    try fr.push(&oversized_tag);
    try fr.push(" PING x\r\nPING :recovered\r\n");
    try std.testing.expectError(error.IrcLineTooLong, fr.next());
    try std.testing.expectEqualStrings("PING :recovered", (try fr.next()).?);

    // 8189 tag-data bytes plus '@' and space is the exact 8191-byte tag
    // section limit; `PING x` plus CRLF remains under the payload limit.
    var exact_tag: [8190]u8 = undefined;
    @memset(&exact_tag, 'a');
    exact_tag[0] = '@';
    try fr.push(&exact_tag);
    try fr.push(" PING x\r\n");
    const exact = (try fr.next()).?;
    try std.testing.expectEqual(@as(usize, 8197), exact.len);
}

test "writeRegister without IRCX omits the IRCX probe" {
    const gpa = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try writeRegister(&out, gpa, "bob", "bob", "Bob B", false);
    try std.testing.expectEqualStrings(
        "NICK bob\r\n" ++ "USER bob 0 * :Bob B\r\n",
        out.items,
    );
}

test "command builders emit individual CRLF-terminated commands" {
    const gpa = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try writeNick(&out, gpa, "anna");
    try writeJoin(&out, gpa, "#comics");
    try writeJoinWithKey(&out, gpa, "#locked", "swordfish");
    try writePong(&out, gpa, "tok123");
    try std.testing.expectEqualStrings(
        "NICK anna\r\n" ++ "JOIN #comics\r\n" ++ "JOIN #locked swordfish\r\n" ++ "PONG tok123\r\n",
        out.items,
    );
}

test "writePrivmsg preserves Microsoft's trailing form for one-word text" {
    const gpa = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try writePrivmsg(&out, gpa, "#c", "hi");
    // Source always uses the explicit trailing parameter form.
    try std.testing.expectEqualStrings("PRIVMSG #c :hi\r\n", out.items);
}

test "round-trip: framed line parses back into a Message" {
    const gpa = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try writePrivmsg(&out, gpa, "#comics", "hello there");

    var fr = LineFramer.init(gpa);
    defer fr.deinit();
    try fr.push(out.items);
    const line = (try fr.next()).?;
    const m = message.parse(line);
    try std.testing.expectEqualStrings("PRIVMSG", m.command);
    try std.testing.expectEqualStrings("#comics", m.param(0).?);
    try std.testing.expectEqualStrings("hello there", m.param(1).?);
}
