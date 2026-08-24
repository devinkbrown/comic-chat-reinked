//! Live Microsoft Comic Chat UDI annotation codec.
//!
//! This is the compact, byte-oriented format used beside live IRC messages;
//! it is not the tab-delimited conversation archive format in `record.zig`.
//! The port follows the MIT-licensed Microsoft source at commit
//! `c7df00f60bc8e9fdef413f139e61f7c37e024684`:
//! - `defines.h:57-77`: serial modes, balloon modes, and field prefixes.
//! - `protsupp.cpp:1023-1063`: `IndexToByte`, `ByteToIndex`, `SM2BM`, `BM2SM`.
//! - `protsupp.cpp:1485-1539`: `ProcessUDIData` field order.
//! - `protsupp.cpp:1545-1623`: `ProcessSay` embedded annotations and stripping.
//! - `protsupp.cpp:3057-3099`: `bInsertAnnotations` encoding.
//!
//! The source grammar is `#GgggEeee[R]Mm[Tnick,nick]`, where each lower-case
//! placeholder is one byte, not an ASCII decimal number. Gesture/expression
//! component values are represented by `value + '0'` exactly as in the
//! original. `ProcessUDIData` itself accepted missing/truncated optional fields
//! and then marked the UDI valid. `parseAnnotation` intentionally accepts only
//! a complete canonical annotation: it bounds and validates the formerly
//! NUL-terminated C input while preserving source semantics for valid fields.

const std = @import("std");

/// `MAX_ANNOTATIONS` is a 256-byte C buffer in `defines.h`; one byte was the
/// terminating NUL, leaving at most 255 wire bytes.
pub const max_annotation_bytes: usize = 255;

pub const bm_say: u16 = 0x0001;
pub const bm_whisper: u16 = 0x0002;
pub const bm_think: u16 = 0x0004;
pub const bm_action: u16 = 0x0008;
pub const bm_sound: u16 = 0x0010;

pub const SerialMode = enum(u8) {
    say = 1,
    whisper = 2,
    think = 3,
    /// Defined by the source but deliberately falls through to SAY in SM2BM.
    shout = 4,
    action = 5,
};

/// Direct `SM2BM` port. The source maps only 2, 3, and 5 specially; every
/// other decoded serial value, including the defined-but-unused SHOUT value 4,
/// becomes SAY.
pub fn serialToBalloon(mode: u8) u16 {
    return switch (mode) {
        2 => bm_whisper,
        3 => bm_think,
        5 => bm_action,
        else => bm_say,
    };
}

/// Direct `BM2SM` port, including its source precedence and `BM_SOUND` rule.
pub fn balloonToSerial(modes: u16) SerialMode {
    if (modes & (bm_action | bm_sound) != 0) return .action;
    if (modes & bm_whisper != 0) return .whisper;
    if (modes & bm_think != 0) return .think;
    return .say;
}

pub const Components = struct {
    index: u8,
    emotion: u8,
    intensity: u8,
};

/// The avatar state carried by one cooked UDI annotation.  `SayEntry` copies
/// these seven fields before rendering (`histent.cpp:48-56`), so keep them as
/// one value instead of dropping the pose after parsing its balloon mode.
pub const PoseState = struct {
    gesture: Components,
    expression: Components,
    requested: bool,
};

/// A decoded annotation. `talk_to` borrows from the annotation input and is
/// the comma-separated suffix without the leading `T`.
pub const Annotation = struct {
    gesture: Components,
    expression: Components,
    requested: bool,
    /// Raw `ByteToIndex` value from the wire. Unknown serial values are kept
    /// even though `modes` follows `SM2BM` and treats them as SAY.
    serial_value: u8,
    modes: u16,
    talk_to: ?[]const u8,

    pub fn talkTos(self: Annotation) TalkToIterator {
        return .{ .rest = self.talk_to orelse "" };
    }

    pub fn poseState(self: Annotation) PoseState {
        return .{
            .gesture = self.gesture,
            .expression = self.expression,
            .requested = self.requested,
        };
    }
};

/// Allocation-free iterator over decoded talk-to nickname slices.
pub const TalkToIterator = struct {
    rest: []const u8,

    pub fn next(self: *TalkToIterator) ?[]const u8 {
        if (self.rest.len == 0) return null;
        const comma = std.mem.indexOfScalar(u8, self.rest, ',') orelse self.rest.len;
        const nick = self.rest[0..comma];
        self.rest = if (comma == self.rest.len) "" else self.rest[comma + 1 ..];
        return nick;
    }
};

pub const CodecError = error{
    AnnotationTooLong,
    InvalidPrefix,
    Truncated,
    InvalidIndexByte,
    UnexpectedField,
    InvalidTalkTo,
    InvalidEmbeddedAnnotation,
};

fn decodeIndex(byte: u8) CodecError!u8 {
    if (byte < '0') return error.InvalidIndexByte;
    return byte - '0';
}

fn parseComponents(bytes: []const u8) CodecError!Components {
    if (bytes.len != 3) return error.Truncated;
    return .{
        .index = try decodeIndex(bytes[0]),
        .emotion = try decodeIndex(bytes[1]),
        .intensity = try decodeIndex(bytes[2]),
    };
}

fn validNick(nick: []const u8) bool {
    if (nick.len == 0) return false;
    for (nick) |byte| {
        // Source output contains IRC nicknames. Reject delimiters, whitespace,
        // C controls, and non-ASCII bytes rather than admitting ambiguous data.
        if (byte <= ' ' or byte >= 0x7f or byte == ',' or byte == ')') return false;
    }
    return true;
}

fn validateTalkTo(list: []const u8) CodecError!void {
    if (list.len == 0) return error.InvalidTalkTo;
    var rest = list;
    while (true) {
        const comma = std.mem.indexOfScalar(u8, rest, ',') orelse rest.len;
        if (!validNick(rest[0..comma])) return error.InvalidTalkTo;
        if (comma == rest.len) return;
        rest = rest[comma + 1 ..];
    }
}

/// Strictly decode the canonical standalone form associated with the source's
/// `ProcessUDIData`. Unlike that C function, this rejects missing fields and
/// malformed/trailing data. The returned nickname slices borrow from `wire`.
pub fn parseAnnotation(wire: []const u8) CodecError!Annotation {
    if (wire.len > max_annotation_bytes) return error.AnnotationTooLong;
    if (wire.len == 0 or wire[0] != '#') return error.InvalidPrefix;

    var at: usize = 1;
    if (at >= wire.len or wire[at] != 'G') return error.UnexpectedField;
    at += 1;
    if (wire.len - at < 3) return error.Truncated;
    const gesture = try parseComponents(wire[at .. at + 3]);
    at += 3;

    if (at >= wire.len or wire[at] != 'E') return error.UnexpectedField;
    at += 1;
    if (wire.len - at < 3) return error.Truncated;
    const expression = try parseComponents(wire[at .. at + 3]);
    at += 3;

    var requested = false;
    if (at < wire.len and wire[at] == 'R') {
        requested = true;
        at += 1;
    }

    if (at >= wire.len or wire[at] != 'M') return error.UnexpectedField;
    at += 1;
    if (at >= wire.len) return error.Truncated;
    const serial_value = try decodeIndex(wire[at]);
    at += 1;

    var talk_to: ?[]const u8 = null;
    if (at < wire.len) {
        if (wire[at] != 'T') return error.UnexpectedField;
        at += 1;
        const list = wire[at..];
        try validateTalkTo(list);
        talk_to = list;
        at = wire.len;
    }
    std.debug.assert(at == wire.len);

    return .{
        .gesture = gesture,
        .expression = expression,
        .requested = requested,
        .serial_value = serial_value,
        .modes = serialToBalloon(serial_value),
        .talk_to = talk_to,
    };
}

pub const Message = struct {
    annotation: ?Annotation,
    /// Message text after removing a valid non-IRCX `(<annotation>) ` prefix.
    text: []const u8,
    /// Effective `ProcessSay` modes, including its private-message override.
    modes: u16,
};

/// `ProcessSay` forces whisper balloon semantics on a private message
/// regardless of the decoded serial mode (`M1`/`M5`).
pub fn privateModes(modes: u16) u16 {
    return (modes & ~(bm_say | bm_think)) | bm_whisper;
}

/// Decode the source's non-IRCX `(#...) <text>` form from `ProcessSay`.
/// Unannotated text is returned unchanged with SAY (or WHISPER for a private
/// message). A string beginning `(#` is treated as an annotation attempt and
/// rejected when it is malformed instead of being partially consumed.
pub fn parseMessage(message: []const u8, is_private: bool) CodecError!Message {
    if (!std.mem.startsWith(u8, message, "(#")) {
        return .{
            .annotation = null,
            .text = message,
            .modes = if (is_private) bm_whisper else bm_say,
        };
    }

    const close = std.mem.indexOf(u8, message[2..], ") ") orelse
        return error.InvalidEmbeddedAnnotation;
    const close_at = 2 + close;
    // Skip only the opening parenthesis; the standalone parser expects `#`.
    const annotation = parseAnnotation(message[1..close_at]) catch
        return error.InvalidEmbeddedAnnotation;
    const modes = if (is_private) privateModes(annotation.modes) else annotation.modes;
    return .{
        .annotation = annotation,
        .text = message[close_at + 2 ..],
        .modes = modes,
    };
}

pub const EncodeInput = struct {
    gesture: Components,
    expression: Components,
    requested: bool = false,
    modes: u16 = bm_say,
    talk_tos: []const []const u8 = &.{},
};

fn checkedIndex(value: u8) CodecError!u8 {
    // `IndexToByte` adds '0' to a BYTE. Values beyond this range would wrap.
    if (value > std.math.maxInt(u8) - '0') return error.InvalidIndexByte;
    return value + '0';
}

fn validateInput(input: EncodeInput, embedded: bool) CodecError!usize {
    _ = try checkedIndex(input.gesture.index);
    _ = try checkedIndex(input.gesture.emotion);
    _ = try checkedIndex(input.gesture.intensity);
    _ = try checkedIndex(input.expression.index);
    _ = try checkedIndex(input.expression.emotion);
    _ = try checkedIndex(input.expression.intensity);

    var len: usize = 11 + @as(usize, @intFromBool(input.requested));
    if (input.talk_tos.len != 0) {
        len += 1; // T
        for (input.talk_tos, 0..) |nick, i| {
            if (!validNick(nick)) return error.InvalidTalkTo;
            len += nick.len + @intFromBool(i != 0);
        }
    }
    if (len > max_annotation_bytes) return error.AnnotationTooLong;
    return len + if (embedded) @as(usize, 3) else 0; // '(' + ") "
}

/// Append the source `bInsertAnnotations` representation. With `embedded`
/// true, append the non-IRCX parenthesized form, ready for message text.
pub fn encode(
    out: *std.ArrayList(u8),
    gpa: std.mem.Allocator,
    input: EncodeInput,
    embedded: bool,
) (CodecError || std.mem.Allocator.Error)!void {
    const len = try validateInput(input, embedded);
    try out.ensureUnusedCapacity(gpa, len);

    if (embedded) out.appendAssumeCapacity('(');
    out.appendSliceAssumeCapacity("#G");
    out.appendAssumeCapacity(try checkedIndex(input.gesture.index));
    out.appendAssumeCapacity(try checkedIndex(input.gesture.emotion));
    out.appendAssumeCapacity(try checkedIndex(input.gesture.intensity));
    out.appendAssumeCapacity('E');
    out.appendAssumeCapacity(try checkedIndex(input.expression.index));
    out.appendAssumeCapacity(try checkedIndex(input.expression.emotion));
    out.appendAssumeCapacity(try checkedIndex(input.expression.intensity));
    if (input.requested) out.appendAssumeCapacity('R');
    out.appendAssumeCapacity('M');
    out.appendAssumeCapacity(@intFromEnum(balloonToSerial(input.modes)) + '0');
    if (input.talk_tos.len != 0) {
        out.appendAssumeCapacity('T');
        for (input.talk_tos, 0..) |nick, i| {
            if (i != 0) out.appendAssumeCapacity(',');
            out.appendSliceAssumeCapacity(nick);
        }
    }
    if (embedded) out.appendSliceAssumeCapacity(") ");
}

test "source UDI grammar decodes fixed fields and talk-to slices" {
    const decoded = try parseAnnotation("#G123E456RM3Talice,bob");
    try std.testing.expectEqual(Components{ .index = 1, .emotion = 2, .intensity = 3 }, decoded.gesture);
    try std.testing.expectEqual(Components{ .index = 4, .emotion = 5, .intensity = 6 }, decoded.expression);
    try std.testing.expect(decoded.requested);
    try std.testing.expectEqual(@as(u8, 3), decoded.serial_value);
    try std.testing.expectEqual(@as(u16, bm_think), decoded.modes);
    try std.testing.expectEqual(PoseState{
        .gesture = .{ .index = 1, .emotion = 2, .intensity = 3 },
        .expression = .{ .index = 4, .emotion = 5, .intensity = 6 },
        .requested = true,
    }, decoded.poseState());

    var names = decoded.talkTos();
    try std.testing.expectEqualStrings("alice", names.next().?);
    try std.testing.expectEqualStrings("bob", names.next().?);
    try std.testing.expect(names.next() == null);
}

test "serial modes map with source SM2BM default and BM2SM precedence" {
    try std.testing.expectEqual(@as(u16, bm_say), serialToBalloon(1));
    try std.testing.expectEqual(@as(u16, bm_whisper), serialToBalloon(2));
    try std.testing.expectEqual(@as(u16, bm_think), serialToBalloon(3));
    try std.testing.expectEqual(@as(u16, bm_action), serialToBalloon(5));
    try std.testing.expectEqual(SerialMode.action, balloonToSerial(bm_action | bm_whisper));
    try std.testing.expectEqual(SerialMode.action, balloonToSerial(bm_sound));
    try std.testing.expectEqual(SerialMode.whisper, balloonToSerial(bm_whisper | bm_think));
    try std.testing.expectEqual(SerialMode.think, balloonToSerial(bm_think));
    try std.testing.expectEqual(SerialMode.say, balloonToSerial(0));
    try std.testing.expectEqual(@as(u16, bm_whisper), privateModes(bm_say));
    try std.testing.expectEqual(@as(u16, bm_action | bm_whisper), privateModes(bm_action));
}

test "strict parser rejects malformed and overlong annotations" {
    const malformed = [_]struct { wire: []const u8, expected: anyerror }{
        .{ .wire = "G123E456M1", .expected = error.InvalidPrefix },
        .{ .wire = "#G12", .expected = error.Truncated },
        .{ .wire = "#G123X456M1", .expected = error.UnexpectedField },
        .{ .wire = "#G/23E456M1", .expected = error.InvalidIndexByte },
        .{ .wire = "#G123E456", .expected = error.UnexpectedField },
        .{ .wire = "#G123E456M1X", .expected = error.UnexpectedField },
        .{ .wire = "#G123E456M1T", .expected = error.InvalidTalkTo },
        .{ .wire = "#G123E456M1Talice,,bob", .expected = error.InvalidTalkTo },
    };
    for (malformed) |case| try std.testing.expectError(case.expected, parseAnnotation(case.wire));

    var overlong: [max_annotation_bytes + 1]u8 = @splat('x');
    overlong[0] = '#';
    try std.testing.expectError(error.AnnotationTooLong, parseAnnotation(&overlong));
}

test "SM2BM preserves raw M0 M4 M9 values and defaults each to SAY" {
    const cases = [_]struct { wire: []const u8, value: u8 }{
        .{ .wire = "#G123E456M0", .value = 0 },
        .{ .wire = "#G123E456M4", .value = 4 },
        .{ .wire = "#G123E456M9", .value = 9 },
    };
    for (cases) |case| {
        const decoded = try parseAnnotation(case.wire);
        try std.testing.expectEqual(case.value, decoded.serial_value);
        try std.testing.expectEqual(@as(u16, bm_say), decoded.modes);
    }
}

test "ProcessSay embedded form strips annotation and applies private override" {
    const parsed = try parseMessage("(#G123E456M3Talice,bob) this is private", true);
    try std.testing.expectEqualStrings("this is private", parsed.text);
    try std.testing.expect(parsed.annotation != null);
    try std.testing.expectEqual(@as(u16, bm_whisper), parsed.modes);

    const action = try parseMessage("(#G123E456M5) waves", true);
    try std.testing.expectEqual(@as(u16, bm_action | bm_whisper), action.modes);
    try std.testing.expectEqualStrings("waves", action.text);

    const plain = try parseMessage("ordinary (#text) remains", false);
    try std.testing.expect(plain.annotation == null);
    try std.testing.expectEqualStrings("ordinary (#text) remains", plain.text);
    try std.testing.expectEqual(@as(u16, bm_say), plain.modes);
}

test "malformed embedded prefix is never partially stripped" {
    try std.testing.expectError(error.InvalidEmbeddedAnnotation, parseMessage("(#G123E456M1 no close", false));
    try std.testing.expectError(error.InvalidEmbeddedAnnotation, parseMessage("(#G123E456M/) text", false));
}

test "bInsertAnnotations encoding matches fixed standalone and embedded bytes" {
    const gpa = std.testing.allocator;
    const input: EncodeInput = .{
        .gesture = .{ .index = 1, .emotion = 2, .intensity = 3 },
        .expression = .{ .index = 4, .emotion = 5, .intensity = 6 },
        .requested = true,
        .modes = bm_whisper,
        .talk_tos = &.{ "alice", "bob" },
    };

    var standalone: std.ArrayList(u8) = .empty;
    defer standalone.deinit(gpa);
    try encode(&standalone, gpa, input, false);
    try std.testing.expectEqualStrings("#G123E456RM2Talice,bob", standalone.items);

    var embedded: std.ArrayList(u8) = .empty;
    defer embedded.deinit(gpa);
    try encode(&embedded, gpa, input, true);
    try embedded.appendSlice(gpa, "hello");
    try std.testing.expectEqualStrings("(#G123E456RM2Talice,bob) hello", embedded.items);
}
