//! Advertised ISUPPORT identity rules used on the live path.
//!
//! `005` tokens are stored in feature state; this module turns `PREFIX`,
//! `CASEMAPPING`, `CHANTYPES`, `CHANMODES`, `STATUSMSG`, and the length
//! limits into the comparisons, MODE parameter rules, and send/join checks
//! the session actually applies. Defaults match traditional IRC (`rfc1459`,
//! `(qaohv)~&@%+`, `#&`, `beI,k,l,imnpst`) until a server advertisement
//! replaces them.

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

/// RFC 1459/2811 channel-mode classes. Type A/B always take a parameter;
/// type C takes one only when adding; type D never does. Prefix modes are
/// handled separately by `PrefixMap`.
pub const ChanModes = struct {
    bytes: [96]u8 = undefined,
    len: u8 = 0,
    custom: bool = false,

    pub const default: ChanModes = .{};
    pub const traditional = "beI,k,l,imnpst";

    pub fn parse(value: []const u8) ChanModes {
        var modes = ChanModes{ .bytes = @splat(0), .len = 0, .custom = true };
        const n = @min(value.len, modes.bytes.len);
        @memcpy(modes.bytes[0..n], value[0..n]);
        modes.len = @intCast(n);
        return modes;
    }

    pub fn raw(self: ChanModes) []const u8 {
        return if (self.custom) self.bytes[0..self.len] else traditional;
    }

    pub fn classOf(self: ChanModes, mode: u8) ?u8 {
        var class: u8 = 'A';
        for (self.raw()) |ch| {
            if (ch == ',') {
                class += 1;
                continue;
            }
            if (ch == mode) return class;
        }
        return null;
    }

    pub fn takesParam(self: ChanModes, mode: u8, adding: bool) bool {
        return switch (self.classOf(mode) orelse return false) {
            'A', 'B' => true,
            'C' => adding,
            else => false,
        };
    }
};

/// STATUSMSG delivery prefixes. When the token is absent, callers fall back
/// to the advertised PREFIX symbols. Onyx advertises `!.@+` — `*` is the
/// local-oper PREFIX symbol and must not strip a channel target.
pub const StatusMsg = struct {
    bytes: [16]u8 = .{ '~', '&', '@', '%', '+', 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
    len: u8 = 5,

    pub const default: StatusMsg = .{};

    pub fn parse(value: []const u8) StatusMsg {
        var symbols = StatusMsg{ .bytes = @splat(0), .len = 0 };
        for (value) |ch| {
            if (symbols.len == symbols.bytes.len) break;
            if (ch <= ' ' or std.mem.indexOfScalar(u8, symbols.bytes[0..symbols.len], ch) != null) continue;
            symbols.bytes[symbols.len] = ch;
            symbols.len += 1;
        }
        return if (symbols.len == 0) .default else symbols;
    }

    pub fn fromPrefix(prefixes: PrefixMap) StatusMsg {
        return parse(prefixes.symbolSlice());
    }

    pub fn contains(self: StatusMsg, ch: u8) bool {
        return std.mem.indexOfScalar(u8, self.bytes[0..self.len], ch) != null;
    }

    pub fn slice(self: *const StatusMsg) []const u8 {
        return self.bytes[0..self.len];
    }
};

/// `0` means the server did not advertise a bound; the live path must not
/// invent a tighter default before `005`.
pub const SessionLimits = struct {
    nicklen: usize = 0,
    channellen: usize = 0,
    topiclen: usize = 0,
    awaylen: usize = 0,
    kicklen: usize = 0,
    keylen: usize = 0,
    chanlimit: usize = 0,
    maxtargets: usize = 0,
    monitor: usize = 0,
    silence: usize = 0,
    modes: usize = 0,
    maxlist: usize = 0,
    bot: u8 = 0,
    whox: bool = false,
    utf8only: bool = false,

    pub fn parseCount(value: []const u8) usize {
        return std.fmt.parseUnsigned(usize, value, 10) catch 0;
    }

    /// `MAXLIST=beIZ:100` / `b:50,e:20` — take the largest per-list cap.
    pub fn parseMaxlist(value: []const u8) usize {
        return parseChanlimit(value);
    }

    /// `CHANLIMIT=#&:50` / `#:20,&:10` — take the largest per-prefix cap.
    pub fn parseChanlimit(value: []const u8) usize {
        var max: usize = 0;
        var it = std.mem.splitScalar(u8, value, ',');
        while (it.next()) |part| {
            const colon = std.mem.lastIndexOfScalar(u8, part, ':') orelse continue;
            const n = parseCount(part[colon + 1 ..]);
            if (n > max) max = n;
        }
        return max;
    }

    pub fn clip(limit: usize, text: []const u8) []const u8 {
        if (limit == 0 or text.len <= limit) return text;
        return text[0..limit];
    }

    pub fn exceeds(limit: usize, value: []const u8) bool {
        return limit != 0 and value.len > limit;
    }

    pub fn exceedsCount(limit: usize, count: usize) bool {
        return limit != 0 and count > limit;
    }

    pub fn targetCount(list: []const u8) usize {
        if (list.len == 0) return 0;
        var count: usize = 1;
        for (list) |ch| {
            if (ch == ',') count += 1;
        }
        return count;
    }
};

pub const Extban = struct {
    prefix: u8 = '$',
    types: [16]u8 = @splat(0),
    types_len: u8 = 0,
    present: bool = false,

    pub const Parsed = struct { negated: bool, kind: u8, value: []const u8 };

    /// `$,acgmrz` — prefix plus the advertised type letters.
    pub fn parse(value: []const u8) Extban {
        var parsed = Extban{ .present = true };
        const comma = std.mem.indexOfScalar(u8, value, ',');
        const prefix_part = if (comma) |index| value[0..index] else value;
        const types_part = if (comma) |index| value[index + 1 ..] else "";
        if (prefix_part.len != 0) parsed.prefix = prefix_part[0];
        for (types_part) |ch| {
            if (parsed.types_len == parsed.types.len) break;
            if (ch <= ' ' or std.mem.indexOfScalar(u8, parsed.types[0..parsed.types_len], ch) != null) continue;
            parsed.types[parsed.types_len] = ch;
            parsed.types_len += 1;
        }
        return parsed;
    }

    pub fn allows(self: Extban, kind: u8) bool {
        if (!self.present) return true;
        const folded = if (kind >= 'A' and kind <= 'Z') kind + ('a' - 'A') else kind;
        for (self.types[0..self.types_len]) |advertised| {
            const want = if (advertised >= 'A' and advertised <= 'Z') advertised + ('a' - 'A') else advertised;
            if (want == folded) return true;
        }
        return false;
    }

    /// `$a:alice`, `$~a:alice`, `$c:#chan`.
    pub fn parseMask(self: Extban, mask: []const u8) ?Parsed {
        if (mask.len < 3 or mask[0] != self.prefix) return null;
        var index: usize = 1;
        var negated = false;
        if (mask[index] == '~') {
            negated = true;
            index += 1;
        }
        if (index + 1 >= mask.len or mask[index + 1] != ':') return null;
        return .{ .negated = negated, .kind = mask[index], .value = mask[index + 2 ..] };
    }
};

pub const Advertised = struct {
    casemapping: CaseMapping = .rfc1459,
    prefixes: PrefixMap = .default,
    chantypes: ChanTypes = .default,
    chanmodes: ChanModes = .default,
    statusmsg: StatusMsg = .default,
    session_limits: SessionLimits = .{},
    extban: Extban = .{},
};

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

test "CHANMODES classes consume list, key, and add-only parameters" {
    const traditional = ChanModes.default;
    try std.testing.expect(traditional.takesParam('b', true));
    try std.testing.expect(traditional.takesParam('k', false));
    try std.testing.expect(traditional.takesParam('l', true));
    try std.testing.expect(!traditional.takesParam('l', false));
    try std.testing.expect(!traditional.takesParam('n', true));
    try std.testing.expect(!traditional.takesParam('Z', true));
    try std.testing.expect(!traditional.takesParam('f', true));

    const onyx = ChanModes.parse("beIZ,k,lfj,imnstCTNMSgWOAVUFD");
    try std.testing.expect(onyx.takesParam('Z', false));
    try std.testing.expect(onyx.takesParam('f', true));
    try std.testing.expect(!onyx.takesParam('f', false));
    try std.testing.expect(onyx.takesParam('j', true));
    try std.testing.expect(!onyx.takesParam('m', true));
}

test "STATUSMSG parse keeps PREFIX fallback distinct from Onyx" {
    const traditional = StatusMsg.default;
    try std.testing.expect(traditional.contains('@'));
    try std.testing.expect(traditional.contains('~'));
    const onyx = StatusMsg.parse("!.@+");
    try std.testing.expect(onyx.contains('!'));
    try std.testing.expect(onyx.contains('.'));
    try std.testing.expect(onyx.contains('@'));
    try std.testing.expect(onyx.contains('+'));
    try std.testing.expect(!onyx.contains('*'));
    try std.testing.expect(!onyx.contains('~'));
    const from_onyx_prefix = StatusMsg.fromPrefix(PrefixMap.parse("(YQqov)*!.@+").?);
    try std.testing.expect(from_onyx_prefix.contains('*'));
}

test "session limits parse CHANLIMIT and clip outgoing text" {
    try std.testing.expectEqual(@as(usize, 50), SessionLimits.parseChanlimit("#&:50"));
    try std.testing.expectEqual(@as(usize, 20), SessionLimits.parseChanlimit("#:20,&:10"));
    try std.testing.expectEqual(@as(usize, 0), SessionLimits.parseChanlimit("#&"));
    try std.testing.expectEqual(@as(usize, 64), SessionLimits.parseCount("64"));
    try std.testing.expectEqualStrings("hello", SessionLimits.clip(10, "hello"));
    try std.testing.expectEqualStrings("hel", SessionLimits.clip(3, "hello"));
    try std.testing.expectEqualStrings("hello", SessionLimits.clip(0, "hello"));
    try std.testing.expect(SessionLimits.exceeds(4, "alice"));
    try std.testing.expect(!SessionLimits.exceeds(0, "alice"));
    try std.testing.expectEqual(@as(usize, 3), SessionLimits.targetCount("anna,bob,carol"));
    try std.testing.expectEqual(@as(usize, 1), SessionLimits.targetCount("anna"));
    try std.testing.expect(SessionLimits.exceedsCount(4, 5));
    try std.testing.expect(!SessionLimits.exceedsCount(0, 20));
    try std.testing.expectEqual(@as(usize, 100), SessionLimits.parseMaxlist("beIZ:100"));
    const extban = Extban.parse("$,acgmrz");
    try std.testing.expect(extban.present);
    try std.testing.expectEqual(@as(u8, '$'), extban.prefix);
    try std.testing.expect(extban.allows('a'));
    try std.testing.expect(extban.allows('Z'));
    try std.testing.expect(!extban.allows('x'));
    const account = extban.parseMask("$a:alice").?;
    try std.testing.expect(!account.negated);
    try std.testing.expectEqual(@as(u8, 'a'), account.kind);
    try std.testing.expectEqualStrings("alice", account.value);
    const muted = extban.parseMask("$~m:*!*@*").?;
    try std.testing.expect(muted.negated);
    try std.testing.expectEqual(@as(u8, 'm'), muted.kind);
    try std.testing.expect(extban.parseMask("alice!*@*") == null);
}
