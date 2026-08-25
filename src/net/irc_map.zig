//! Advertised ISUPPORT identity rules used on the live path.
//!
//! `005` tokens are stored in feature state; this module turns `PREFIX`,
//! `CASEMAPPING`, and `CHANTYPES` into the comparisons and NAMES/MODE
//! decorations the session actually applies. Defaults match traditional IRC
//! (`rfc1459`, `(qaohv)~&@%+`, `#&`) until a server advertisement replaces them.

const std = @import("std");

pub const CaseMapping = enum { ascii, rfc1459, strict_rfc1459 };

pub fn parseCaseMapping(value: []const u8) CaseMapping {
    if (std.ascii.eqlIgnoreCase(value, "ascii")) return .ascii;
    if (std.ascii.eqlIgnoreCase(value, "strict-rfc1459") or std.ascii.eqlIgnoreCase(value, "rfc2366"))
        return .strict_rfc1459;
    return .rfc1459;
}

pub fn fold(mapping: CaseMapping, value: u8) u8 {
    return switch (mapping) {
        .ascii => if (value >= 'A' and value <= 'Z') value + ('a' - 'A') else value,
        .rfc1459 => switch (value) {
            'A'...'Z' => value + ('a' - 'A'),
            '[' => '{',
            ']' => '}',
            '\\' => '|',
            '^' => '~',
            else => value,
        },
        .strict_rfc1459 => switch (value) {
            'A'...'Z' => value + ('a' - 'A'),
            '[' => '{',
            ']' => '}',
            '\\' => '|',
            else => value,
        },
    };
}

pub fn eql(mapping: CaseMapping, a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| if (fold(mapping, left) != fold(mapping, right)) return false;
    return true;
}

pub const PrefixMap = struct {
    modes: [16]u8 = undefined,
    symbols: [16]u8 = undefined,
    len: u8 = 0,

    pub const default = parse("(qaohv)~&@%+").?;

    pub fn parse(value: []const u8) ?PrefixMap {
        if (value.len < 3 or value[0] != '(') return null;
        const close = std.mem.indexOfScalar(u8, value, ')') orelse return null;
        const modes = value[1..close];
        const symbols = value[close + 1 ..];
        if (modes.len == 0 or modes.len != symbols.len or modes.len > 16) return null;
        var map = PrefixMap{ .len = @intCast(modes.len) };
        @memcpy(map.modes[0..modes.len], modes);
        @memcpy(map.symbols[0..symbols.len], symbols);
        return map;
    }

    pub fn modeSlice(self: *const PrefixMap) []const u8 {
        return self.modes[0..self.len];
    }

    pub fn symbolSlice(self: *const PrefixMap) []const u8 {
        return self.symbols[0..self.len];
    }

    pub fn isSymbol(self: *const PrefixMap, ch: u8) bool {
        return std.mem.indexOfScalar(u8, self.symbolSlice(), ch) != null;
    }

    pub fn isMode(self: *const PrefixMap, ch: u8) bool {
        return std.mem.indexOfScalar(u8, self.modeSlice(), ch) != null;
    }

    pub fn modeForSymbol(self: *const PrefixMap, symbol: u8) ?u8 {
        const index = std.mem.indexOfScalar(u8, self.symbolSlice(), symbol) orelse return null;
        return self.modes[index];
    }

    pub fn bitForIndex(self: *const PrefixMap, index: usize) u8 {
        if (index >= self.len) return 0;
        return @as(u8, 1) << @intCast(self.len - 1 - index);
    }

    pub fn bitForMode(self: *const PrefixMap, mode: u8) u8 {
        const index = std.mem.indexOfScalar(u8, self.modeSlice(), mode) orelse return 0;
        return self.bitForIndex(index);
    }

    pub fn bitForSymbol(self: *const PrefixMap, symbol: u8) u8 {
        const index = std.mem.indexOfScalar(u8, self.symbolSlice(), symbol) orelse return 0;
        return self.bitForIndex(index);
    }
};

pub const ChanTypes = struct {
    bytes: [16]u8 = .{ '#', '&', 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
    len: u8 = 2,

    pub const default: ChanTypes = .{};

    pub fn parse(value: []const u8) ChanTypes {
        var types = ChanTypes{ .bytes = @splat(0), .len = 0 };
        for (value) |ch| {
            if (types.len == types.bytes.len) break;
            if (ch <= ' ' or std.mem.indexOfScalar(u8, types.bytes[0..types.len], ch) != null) continue;
            types.bytes[types.len] = ch;
            types.len += 1;
        }
        return if (types.len == 0) .default else types;
    }

    pub fn slice(self: *const ChanTypes) []const u8 {
        return self.bytes[0..self.len];
    }

    pub fn contains(self: *const ChanTypes, ch: u8) bool {
        return std.mem.indexOfScalar(u8, self.slice(), ch) != null;
    }
};

pub fn isChannelName(types: ChanTypes, name: []const u8) bool {
    return name.len >= 2 and types.contains(name[0]) and std.mem.indexOfAny(u8, name, " ,\r\n\x00") == null;
}

test "casemapping distinguishes ascii from rfc1459 punctuation" {
    try std.testing.expect(eql(.rfc1459, "#[Room]\\^x", "#{ROOM}|~X"));
    try std.testing.expect(!eql(.ascii, "#[Room]\\^x", "#{ROOM}|~X"));
    try std.testing.expect(eql(.ascii, "Alice", "alice"));
    try std.testing.expect(eql(.strict_rfc1459, "[nick]", "{nick}"));
    try std.testing.expect(!eql(.strict_rfc1459, "nick^", "nick~"));
    try std.testing.expectEqual(CaseMapping.ascii, parseCaseMapping("ASCII"));
    try std.testing.expectEqual(CaseMapping.strict_rfc1459, parseCaseMapping("rfc2366"));
}

test "PREFIX parse drives NAMES symbols and MODE letters" {
    const traditional = PrefixMap.default;
    try std.testing.expect(traditional.isSymbol('~'));
    try std.testing.expect(traditional.isSymbol('%'));
    try std.testing.expect(traditional.isMode('q'));
    try std.testing.expectEqual(@as(u8, 'q'), traditional.modeForSymbol('~').?);
    try std.testing.expectEqual(@as(u8, 1 << 4), traditional.bitForSymbol('~'));

    const onyx = PrefixMap.parse("(YQqov)*!.@+").?;
    try std.testing.expect(onyx.isSymbol('*'));
    try std.testing.expect(onyx.isSymbol('!'));
    try std.testing.expect(onyx.isSymbol('.'));
    try std.testing.expect(!onyx.isSymbol('~'));
    try std.testing.expect(!onyx.isSymbol('%'));
    try std.testing.expect(onyx.isMode('Y'));
    try std.testing.expect(onyx.isMode('Q'));
    try std.testing.expectEqual(@as(u8, 'q'), onyx.modeForSymbol('.').?);
    try std.testing.expectEqual(@as(u8, 1 << 4), onyx.bitForSymbol('*'));
    try std.testing.expect(PrefixMap.parse("(ov)@+") != null);
    try std.testing.expect(PrefixMap.parse("(ov)@") == null);
}

test "CHANTYPES parse keeps a usable default" {
    try std.testing.expect(ChanTypes.default.contains('#'));
    try std.testing.expect(ChanTypes.default.contains('&'));
    const only_hash = ChanTypes.parse("#");
    try std.testing.expect(only_hash.contains('#'));
    try std.testing.expect(!only_hash.contains('&'));
    try std.testing.expect(isChannelName(.default, "#root"));
    try std.testing.expect(!isChannelName(only_hash, "&local"));
}
