//! Bounded parser for the XKB text keymap a Wayland compositor sends over
//! `wl_keyboard.keymap` (format 1, XKB_V1_TEXT). No libxkbcommon, no C
//! interop: this reads the same brace-delimited text format compositors
//! already emit and extracts just enough to translate a physical key press
//! into the character or named key the user's configured layout produces.
//!
//! Scope, and why: a real XKB keymap also carries `xkb_types` (multi-level
//! group/shift-state rules, e.g. AltGr as a third level) and `xkb_compat`
//! (modifier-mapping semantics). Implementing those is a much larger,
//! separate undertaking — this parser covers `xkb_keycodes` (physical key
//! name <-> numeric code) and `xkb_symbols` (key name -> the keysym list for
//! levels 1–3: unshifted, Shift, and AltGr/ISO Level3 when the keymap lists
//! a third keysym). That is what makes the base, shifted, and AltGr
//! character of a non-US layout actually correct. A bounded dead-key /
//! Multi_key composer plus optional XCompose locale tables (`~/.XCompose`,
//! `XCOMPOSEFILE`, `%L`) cover European accents (see `Compose`). A
//! level-4+ keysym, if present, is ignored. IME input method integration
//! is a separate protocol (text-input-unstable-v3) and out of scope for this
//! parser.
//!
//! Wayland's wl_keyboard.key event reports the physical key as a raw evdev
//! scancode. XKB numeric keycodes are that scancode plus 8 (a fixed offset
//! inherited from X11, where keycodes below 8 were reserved) — see
//! `xkbKeycodeFromEvdev`.

const std = @import("std");
const compose_file = @import("compose_file.zig");

pub const ComposeTable = compose_file.Table;

pub fn loadComposeTable(gpa: std.mem.Allocator, env: []const u8) !?ComposeTable {
    return compose_file.loadFromEnvironment(gpa, env);
}

pub const ParseError = error{
    UnsupportedKeymapFormat,
    KeycodesSectionMissing,
    SymbolsSectionMissing,
    MalformedKeymap,
} || std.mem.Allocator.Error;

/// A physical key's Shift-level-1 (unshifted), Shift-level-2 (shifted), and
/// optional ISO Level3 (AltGr) keysym names, e.g. .{ "a", "A", "ae" } or
/// .{ "1", "exclam" }. A key with only one level (rare; some symbol keys)
/// repeats it in both Shift slots. Level3 is null when the keymap lists
/// fewer than three symbols.
const Levels = struct {
    base: []const u8,
    shifted: []const u8,
    level3: ?[]const u8 = null,
};

/// Which of the three bounded XKB levels to read.
pub const Level = enum { base, shift, level3 };

/// A parsed keymap: enough of `xkb_keycodes` and `xkb_symbols` to translate
/// an evdev scancode plus a shift state into the keysym name the
/// compositor's configured layout assigns it.
pub const Keymap = struct {
    gpa: std.mem.Allocator,
    /// xkb numeric keycode (evdev + 8) -> the bracket name that names it in
    /// both xkb_keycodes and xkb_symbols, e.g. 38 -> "AC01".
    code_to_name: std.AutoHashMapUnmanaged(u32, []const u8) = .empty,
    /// Bracket name -> its level-1/2/3 keysym names, e.g. "AC01" ->
    /// .{"a", "A", "ae"}.
    name_to_levels: std.StringHashMapUnmanaged(Levels) = .empty,
    /// Backing storage for every name/keysym slice held above, freed once as
    /// a whole on deinit rather than tracked per entry.
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *Keymap) void {
        self.code_to_name.deinit(self.gpa);
        self.name_to_levels.deinit(self.gpa);
        self.arena.deinit();
        self.* = undefined;
    }

    /// The XKB numeric keycode for a raw evdev scancode (see module doc).
    pub fn xkbKeycodeFromEvdev(evdev_code: u32) u32 {
        return evdev_code + 8;
    }

    /// The keysym name a physical key (evdev scancode) produces at the given
    /// Shift level, or null if this keymap has no entry for that key.
    pub fn keysymFor(self: *const Keymap, evdev_code: u32, shifted: bool) ?[]const u8 {
        return self.keysymForLevel(evdev_code, if (shifted) .shift else .base);
    }

    /// The keysym name a physical key produces at base, Shift, or AltGr/ISO
    /// Level3. Level3 returns null when the keymap listed fewer than three
    /// symbols for that key so the caller can fall back to Shift/base.
    pub fn keysymForLevel(self: *const Keymap, evdev_code: u32, level: Level) ?[]const u8 {
        const name = self.code_to_name.get(xkbKeycodeFromEvdev(evdev_code)) orelse return null;
        const levels = self.name_to_levels.get(name) orelse return null;
        return switch (level) {
            .base => levels.base,
            .shift => levels.shifted,
            .level3 => levels.level3,
        };
    }
};

/// Parses a compositor-supplied XKB text keymap (the bytes mmap'd from the
/// wl_keyboard.keymap fd). `format` is the event's format field; only 1
/// (XKB_V1_TEXT) is understood.
pub fn parse(gpa: std.mem.Allocator, format: u32, text: []const u8) ParseError!Keymap {
    if (format != 1) return error.UnsupportedKeymapFormat;

    var keymap = Keymap{ .gpa = gpa, .arena = std.heap.ArenaAllocator.init(gpa) };
    errdefer keymap.deinit();
    const arena = keymap.arena.allocator();

    const keycodes_body = try extractSection(text, "xkb_keycodes") orelse return error.KeycodesSectionMissing;
    try parseKeycodes(arena, gpa, keycodes_body, &keymap.code_to_name);

    const symbols_body = try extractSection(text, "xkb_symbols") orelse return error.SymbolsSectionMissing;
    try parseSymbols(arena, gpa, symbols_body, &keymap.name_to_levels);

    return keymap;
}

/// Finds `name "<anything>" { ... };` (the section's own name string is
/// whatever the compositor labeled its component with, e.g.
/// "xkb_keycodes \"evdev+aliases(qwerty)\" { ... };") and returns the slice
/// between the outermost matched braces. XKB nests braces (indicator groups,
/// key symbol lists), so this counts depth rather than finding the first `}`.
fn extractSection(text: []const u8, name: []const u8) ParseError!?[]const u8 {
    var search_from: usize = 0;
    while (std.mem.indexOfPos(u8, text, search_from, name)) |name_at| {
        search_from = name_at + name.len;
        // Reject a match that is a substring of a longer identifier, e.g.
        // "xkb_keycodes" must not match inside some future "xkb_keycodes_v2".
        if (name_at > 0 and isIdentChar(text[name_at - 1])) continue;
        if (name_at + name.len < text.len and isIdentChar(text[name_at + name.len])) continue;

        const open = std.mem.indexOfScalarPos(u8, text, search_from, '{') orelse return null;
        // Everything between the name and the open brace must be whitespace
        // and/or a quoted label; reject a same-named identifier used for
        // something else (defensive, real keymaps never do this).
        var i = search_from;
        var saw_quote = false;
        while (i < open) : (i += 1) {
            const c = text[i];
            if (c == '"') {
                saw_quote = !saw_quote;
            } else if (!saw_quote and !std.ascii.isWhitespace(c)) {
                break;
            }
        }
        if (i != open) continue;

        var depth: usize = 1;
        var j = open + 1;
        while (j < text.len and depth > 0) : (j += 1) {
            switch (text[j]) {
                '{' => depth += 1,
                '}' => depth -= 1,
                else => {},
            }
        }
        if (depth != 0) return error.MalformedKeymap;
        return text[open + 1 .. j - 1];
    }
    return null;
}

fn isIdentChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// Parses `<NAME> = NUMBER;` lines (ignores everything else in the section:
/// `minimum`/`maximum` bounds, `indicator` declarations, and `alias`
/// declarations, none of which affect the base+shift translation this
/// parser targets).
fn parseKeycodes(
    arena: std.mem.Allocator,
    gpa: std.mem.Allocator,
    body: []const u8,
    out: *std.AutoHashMapUnmanaged(u32, []const u8),
) ParseError!void {
    var i: usize = 0;
    while (i < body.len) {
        skipToNextToken(body, &i);
        if (i >= body.len) break;
        if (body[i] != '<') {
            skipStatement(body, &i);
            continue;
        }
        const name_start = i + 1;
        const name_end = std.mem.indexOfScalarPos(u8, body, name_start, '>') orelse return error.MalformedKeymap;
        const name = body[name_start..name_end];
        i = name_end + 1;

        skipToNextToken(body, &i);
        if (i >= body.len or body[i] != '=') {
            skipStatement(body, &i);
            continue;
        }
        i += 1;
        skipToNextToken(body, &i);

        const number_start = i;
        while (i < body.len and std.ascii.isDigit(body[i])) : (i += 1) {}
        if (i == number_start) return error.MalformedKeymap;
        const code = std.fmt.parseUnsigned(u32, body[number_start..i], 10) catch return error.MalformedKeymap;

        try out.put(gpa, code, try arena.dupe(u8, name));
        skipStatement(body, &i);
    }
}

/// Parses `key <NAME> { [ sym1, sym2, ... ] };` lines within `xkb_symbols`
/// (ignores `modifier_map`, virtual-modifier, and group declarations, none
/// of which this parser's level-1/level-2 scope needs).
fn parseSymbols(
    arena: std.mem.Allocator,
    gpa: std.mem.Allocator,
    body: []const u8,
    out: *std.StringHashMapUnmanaged(Levels),
) ParseError!void {
    var i: usize = 0;
    while (i < body.len) {
        skipToNextToken(body, &i);
        if (i >= body.len) break;

        if (!std.mem.startsWith(u8, body[i..], "key") or (i + 3 < body.len and isIdentChar(body[i + 3]))) {
            skipStatement(body, &i);
            continue;
        }
        i += 3;
        skipToNextToken(body, &i);
        if (i >= body.len or body[i] != '<') {
            skipStatement(body, &i);
            continue;
        }
        const name_start = i + 1;
        const name_end = std.mem.indexOfScalarPos(u8, body, name_start, '>') orelse return error.MalformedKeymap;
        const name = body[name_start..name_end];
        i = name_end + 1;

        skipToNextToken(body, &i);
        if (i >= body.len or body[i] != '{') {
            skipStatement(body, &i);
            continue;
        }
        // key <NAME> { ... } bodies can themselves contain nested
        // `symbols[Group1] = [ ... ]` or a bare `[ ... ]`; only the keysym
        // list is needed, wherever the first one appears.
        const brace_open = i;
        var depth: usize = 1;
        var j = brace_open + 1;
        while (j < body.len and depth > 0) : (j += 1) {
            switch (body[j]) {
                '{' => depth += 1,
                '}' => depth -= 1,
                else => {},
            }
        }
        if (depth != 0) return error.MalformedKeymap;
        const key_body = body[brace_open + 1 .. j - 1];
        i = j;

        if (try firstKeysymList(key_body)) |syms| {
            var it = std.mem.splitScalar(u8, syms, ',');
            var base: ?[]const u8 = null;
            var shifted: ?[]const u8 = null;
            var level3: ?[]const u8 = null;
            while (it.next()) |raw| {
                const trimmed = std.mem.trim(u8, raw, " \t\r\n");
                if (trimmed.len == 0) continue;
                if (base == null) {
                    base = trimmed;
                } else if (shifted == null) {
                    shifted = trimmed;
                } else if (level3 == null) {
                    level3 = trimmed;
                } else {
                    break; // level 4+ ignored, see module doc.
                }
            }
            if (base) |b| {
                try out.put(gpa, try arena.dupe(u8, name), .{
                    .base = try arena.dupe(u8, b),
                    .shifted = try arena.dupe(u8, shifted orelse b),
                    .level3 = if (level3) |third| try arena.dupe(u8, third) else null,
                });
            }
        }
        skipStatement(body, &i);
    }
}

/// Finds the contents of the first `[ ... ]` in a `key <NAME> { ... }` body
/// (the keysym list; may be preceded by `symbols[Group1] =` or nothing).
fn firstKeysymList(key_body: []const u8) ParseError!?[]const u8 {
    const open = std.mem.indexOfScalar(u8, key_body, '[') orelse return null;
    const close = std.mem.indexOfScalarPos(u8, key_body, open, ']') orelse return error.MalformedKeymap;
    return key_body[open + 1 .. close];
}

fn skipToNextToken(body: []const u8, i: *usize) void {
    while (i.* < body.len) {
        if (std.ascii.isWhitespace(body[i.*])) {
            i.* += 1;
        } else if (body[i.*] == '/' and i.* + 1 < body.len and body[i.* + 1] == '/') {
            while (i.* < body.len and body[i.*] != '\n') i.* += 1;
        } else {
            break;
        }
    }
}

/// Advances past the current statement's terminating `;` (or to the end of
/// the section if none remains), skipping any string literal's own `;`-free
/// content and respecting nested `{ }` so a `key <NAME> { ... };` this
/// parser did not recognize does not get truncated mid-body.
fn skipStatement(body: []const u8, i: *usize) void {
    var depth: usize = 0;
    var in_string = false;
    while (i.* < body.len) : (i.* += 1) {
        const c = body[i.*];
        if (in_string) {
            if (c == '"') in_string = false;
            continue;
        }
        switch (c) {
            '"' => in_string = true,
            '{' => depth += 1,
            '}' => {
                if (depth == 0) return;
                depth -= 1;
            },
            ';' => if (depth == 0) {
                i.* += 1;
                return;
            },
            else => {},
        }
    }
}

/// Named (non-printable-character) keys this parser recognizes by their XKB
/// keysym name. Mirrors the non-`char` variants of the platform `Key` union;
/// callers map these to their own Key type.
pub const NamedKey = enum {
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
};

const named_keysyms = std.StaticStringMap(NamedKey).initComptime(.{
    .{ "BackSpace", .backspace },
    .{ "Return", .enter },
    .{ "KP_Enter", .enter },
    .{ "Escape", .escape },
    .{ "Tab", .tab },
    .{ "ISO_Left_Tab", .tab },
    .{ "Left", .left },
    .{ "Right", .right },
    .{ "Up", .up },
    .{ "Down", .down },
    .{ "Home", .home },
    .{ "End", .end },
    .{ "Prior", .page_up },
    .{ "Next", .page_down },
    .{ "Delete", .delete },
});

/// keysym name -> the Latin-1/ASCII printable character it names, for the
/// named punctuation/space keysyms XKB uses instead of the literal
/// character. A single-character keysym name (letters, digits, and the
/// handful of ASCII symbols that are also valid identifier characters, like
/// bare "a" or "1") is its own translation and does not need a table entry
/// — see `charForKeysym`.
const named_char_keysyms = std.StaticStringMap(u8).initComptime(.{
    .{ "space", ' ' },
    .{ "exclam", '!' },
    .{ "quotedbl", '"' },
    .{ "numbersign", '#' },
    .{ "dollar", '$' },
    .{ "percent", '%' },
    .{ "ampersand", '&' },
    .{ "apostrophe", '\'' },
    .{ "quoteright", '\'' },
    .{ "parenleft", '(' },
    .{ "parenright", ')' },
    .{ "asterisk", '*' },
    .{ "plus", '+' },
    .{ "comma", ',' },
    .{ "minus", '-' },
    .{ "period", '.' },
    .{ "slash", '/' },
    .{ "colon", ':' },
    .{ "semicolon", ';' },
    .{ "less", '<' },
    .{ "equal", '=' },
    .{ "greater", '>' },
    .{ "question", '?' },
    .{ "at", '@' },
    .{ "bracketleft", '[' },
    .{ "backslash", '\\' },
    .{ "bracketright", ']' },
    .{ "asciicircum", '^' },
    .{ "underscore", '_' },
    .{ "grave", '`' },
    .{ "quoteleft", '`' },
    .{ "braceleft", '{' },
    .{ "bar", '|' },
    .{ "braceright", '}' },
    .{ "asciitilde", '~' },
    .{ "exclamdown", 0xa1 },
    .{ "cent", 0xa2 },
    .{ "sterling", 0xa3 },
    .{ "currency", 0xa4 },
    .{ "yen", 0xa5 },
    .{ "section", 0xa7 },
    .{ "copyright", 0xa9 },
    .{ "guillemotleft", 0xab },
    .{ "notsign", 0xac },
    .{ "registered", 0xae },
    .{ "degree", 0xb0 },
    .{ "plusminus", 0xb1 },
    .{ "twosuperior", 0xb2 },
    .{ "threesuperior", 0xb3 },
    .{ "mu", 0xb5 },
    .{ "paragraph", 0xb6 },
    .{ "periodcentered", 0xb7 },
    .{ "onesuperior", 0xb9 },
    .{ "guillemotright", 0xbb },
    .{ "onequarter", 0xbc },
    .{ "onehalf", 0xbd },
    .{ "threequarters", 0xbe },
    .{ "questiondown", 0xbf },
    .{ "Agrave", 0xc0 },
    .{ "Aacute", 0xc1 },
    .{ "Adiaeresis", 0xc4 },
    .{ "Aring", 0xc5 },
    .{ "AE", 0xc6 },
    .{ "Ccedilla", 0xc7 },
    .{ "Egrave", 0xc8 },
    .{ "Eacute", 0xc9 },
    .{ "Ntilde", 0xd1 },
    .{ "Odiaeresis", 0xd6 },
    .{ "Oslash", 0xd8 },
    .{ "Udiaeresis", 0xdc },
    .{ "ssharp", 0xdf },
    .{ "agrave", 0xe0 },
    .{ "aacute", 0xe1 },
    .{ "adiaeresis", 0xe4 },
    .{ "aring", 0xe5 },
    .{ "ae", 0xe6 },
    .{ "ccedilla", 0xe7 },
    .{ "egrave", 0xe8 },
    .{ "eacute", 0xe9 },
    .{ "ntilde", 0xf1 },
    .{ "odiaeresis", 0xf6 },
    .{ "oslash", 0xf8 },
    .{ "udiaeresis", 0xfc },
});

/// Resolves a keysym name to a plain character, if it is one. Covers the
/// bare-letter/digit case ("a", "A", "5") and the named-punctuation table
/// above; returns null for anything else (a named key, or an unrecognized
/// keysym this bounded parser does not translate).
pub fn charForKeysym(name: []const u8) ?u21 {
    if (name.len == 1 and std.ascii.isPrint(name[0])) return name[0];
    if (std.mem.eql(u8, name, "EuroSign") or std.mem.eql(u8, name, "euro")) return 0x20ac;
    if (named_char_keysyms.get(name)) |character| return character;
    if (name.len >= 5 and name.len <= 7 and name[0] == 'U') {
        const value = std.fmt.parseInt(u21, name[1..], 16) catch return null;
        if (value > 0x10ffff or (value >= 0xd800 and value <= 0xdfff)) return null;
        return value;
    }
    return null;
}

/// Resolves a keysym name to a named (non-character) key, if it is one.
pub fn namedKeyForKeysym(name: []const u8) ?NamedKey {
    return named_keysyms.get(name);
}

/// Dead-key accents this bounded composer understands. The names match the
/// XKB `dead_*` keysyms and the X11 `XK_dead_*` range 0xfe50–0xfe5c.
pub const Dead = enum {
    grave,
    acute,
    circumflex,
    tilde,
    macron,
    breve,
    abovedot,
    diaeresis,
    abovering,
    doubleacute,
    caron,
    cedilla,
    ogonek,
};

pub const x11_multi_key: u32 = 0xff20;

/// Result of feeding one key into `Compose`. `pending` means the key was
/// consumed and the caller should not emit a character yet. `pass` means
/// compose did not handle the key; the caller should translate it normally.
pub const Outcome = union(enum) {
    pending,
    char: u21,
    pass,
};

/// Dead-key plus Multi_key composer, optionally backed by a parsed XCompose
/// table. The built-in pair table covers the common Western-European set
/// when no locale file is present. Escape/control cancel; space or a doubled
/// dead key emits the standalone accent.
pub const Compose = struct {
    table: ?*const ComposeTable = null,
    seq: [compose_file.max_seq_len]u16 = @splat(0),
    seq_len: u8 = 0,
    dead: ?Dead = null,
    multi: bool = false,
    first: ?u21 = null,

    pub fn reset(self: *Compose) void {
        const table = self.table;
        self.* = .{ .table = table };
    }

    pub fn active(self: *const Compose) bool {
        return self.seq_len != 0 or self.dead != null or self.multi;
    }

    /// Locale table first, then the built-in dead/Multi_key rules.
    pub fn feedName(self: *Compose, name: []const u8) Outcome {
        if (self.feedLocale(name)) |out| return out;
        return self.feedBuiltin(name);
    }

    fn feedLocale(self: *Compose, name: []const u8) ?Outcome {
        const table = self.table orelse return null;
        const id = table.idOf(name) orelse {
            if (self.seq_len != 0) {
                self.reset();
                return self.feedBuiltin(name);
            }
            return null;
        };
        if (self.seq_len >= self.seq.len) self.reset();
        self.seq[self.seq_len] = id;
        self.seq_len += 1;
        switch (table.match(self.seq[0..self.seq_len])) {
            .exact => |ch| {
                self.reset();
                return .{ .char = ch };
            },
            .prefix => return .pending,
            .none => {
                self.reset();
                if (self.seq_len == 0) return self.feedBuiltin(name);
                return .pass;
            },
        }
    }

    fn feedBuiltin(self: *Compose, name: []const u8) Outcome {
        if (deadForKeysym(name)) |dead| return self.feedDead(dead);
        if (isMultiKeyName(name)) return self.feedMulti();
        if (charForKeysym(name)) |ch| return self.feedChar(ch);
        if (std.mem.eql(u8, name, "space")) return self.feedChar(' ');
        if (self.active()) self.reset();
        return .pass;
    }

    pub fn feedDead(self: *Compose, dead: Dead) Outcome {
        if (self.dead == dead and self.first == null and !self.multi) {
            self.reset();
            return .{ .char = standalone(dead) };
        }
        self.dead = dead;
        self.multi = false;
        self.first = null;
        return .pending;
    }

    pub fn feedMulti(self: *Compose) Outcome {
        self.dead = null;
        self.multi = true;
        self.first = null;
        return .pending;
    }

    pub fn feedChar(self: *Compose, ch: u21) Outcome {
        if (self.dead) |dead| {
            self.reset();
            if (ch == ' ') return .{ .char = standalone(dead) };
            if (ch <= 0xff) {
                if (composePair(dead, @intCast(ch))) |out| return .{ .char = out };
            }
            return .{ .char = ch };
        }
        if (self.multi) {
            if (self.first) |a| {
                self.reset();
                if (a <= 0xff and ch <= 0xff) {
                    if (multiPair(@intCast(a), @intCast(ch))) |out| return .{ .char = out };
                }
                return .{ .char = ch };
            }
            self.first = ch;
            return .pending;
        }
        return .{ .char = ch };
    }
};

pub fn deadForKeysym(name: []const u8) ?Dead {
    const dead_names = std.StaticStringMap(Dead).initComptime(.{
        .{ "dead_grave", .grave },
        .{ "dead_acute", .acute },
        .{ "dead_circumflex", .circumflex },
        .{ "dead_tilde", .tilde },
        .{ "dead_macron", .macron },
        .{ "dead_breve", .breve },
        .{ "dead_abovedot", .abovedot },
        .{ "dead_diaeresis", .diaeresis },
        .{ "dead_abovering", .abovering },
        .{ "dead_doubleacute", .doubleacute },
        .{ "dead_caron", .caron },
        .{ "dead_cedilla", .cedilla },
        .{ "dead_ogonek", .ogonek },
    });
    return dead_names.get(name);
}

const ascii_letter_lo = [_][]const u8{ "a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l", "m", "n", "o", "p", "q", "r", "s", "t", "u", "v", "w", "x", "y", "z" };
const ascii_letter_hi = [_][]const u8{ "A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K", "L", "M", "N", "O", "P", "Q", "R", "S", "T", "U", "V", "W", "X", "Y", "Z" };
const ascii_digit = [_][]const u8{ "0", "1", "2", "3", "4", "5", "6", "7", "8", "9" };

pub fn keysymNameForX11(sym: u32) ?[]const u8 {
    if (sym == x11_multi_key) return "Multi_key";
    if (deadForX11(sym)) |dead| return switch (dead) {
        .grave => "dead_grave",
        .acute => "dead_acute",
        .circumflex => "dead_circumflex",
        .tilde => "dead_tilde",
        .macron => "dead_macron",
        .breve => "dead_breve",
        .abovedot => "dead_abovedot",
        .diaeresis => "dead_diaeresis",
        .abovering => "dead_abovering",
        .doubleacute => "dead_doubleacute",
        .caron => "dead_caron",
        .cedilla => "dead_cedilla",
        .ogonek => "dead_ogonek",
    };
    if (sym == ' ') return "space";
    if (sym >= '0' and sym <= '9') return ascii_digit[sym - '0'];
    if (sym >= 'a' and sym <= 'z') return ascii_letter_lo[sym - 'a'];
    if (sym >= 'A' and sym <= 'Z') return ascii_letter_hi[sym - 'A'];
    return switch (sym) {
        '!' => "exclam",
        '"' => "quotedbl",
        '#' => "numbersign",
        '$' => "dollar",
        '%' => "percent",
        '&' => "ampersand",
        '\'' => "apostrophe",
        '(' => "parenleft",
        ')' => "parenright",
        '*' => "asterisk",
        '+' => "plus",
        ',' => "comma",
        '-' => "minus",
        '.' => "period",
        '/' => "slash",
        ':' => "colon",
        ';' => "semicolon",
        '<' => "less",
        '=' => "equal",
        '>' => "greater",
        '?' => "question",
        '@' => "at",
        '[' => "bracketleft",
        '\\' => "backslash",
        ']' => "bracketright",
        '^' => "asciicircum",
        '_' => "underscore",
        '`' => "grave",
        '{' => "braceleft",
        '|' => "bar",
        '}' => "braceright",
        '~' => "asciitilde",
        else => null,
    };
}

pub fn deadForX11(sym: u32) ?Dead {
    return switch (sym) {
        0xfe50 => .grave,
        0xfe51 => .acute,
        0xfe52 => .circumflex,
        0xfe53 => .tilde,
        0xfe54 => .macron,
        0xfe55 => .breve,
        0xfe56 => .abovedot,
        0xfe57 => .diaeresis,
        0xfe58 => .abovering,
        0xfe59 => .doubleacute,
        0xfe5a => .caron,
        0xfe5b => .cedilla,
        0xfe5c => .ogonek,
        else => null,
    };
}

pub fn isMultiKeyName(name: []const u8) bool {
    return std.mem.eql(u8, name, "Multi_key");
}

fn standalone(dead: Dead) u21 {
    return switch (dead) {
        .grave => '`',
        .acute => 0xb4,
        .circumflex => '^',
        .tilde => '~',
        .macron => 0xaf,
        .breve => 0x02d8,
        .abovedot => 0x02d9,
        .diaeresis => 0xa8,
        .abovering => 0x02da,
        .doubleacute => 0x02dd,
        .caron => 0x02c7,
        .cedilla => 0xb8,
        .ogonek => 0x02db,
    };
}

fn composePair(dead: Dead, base: u8) ?u21 {
    return switch (dead) {
        .acute => switch (base) {
            'a' => 0xe1,
            'A' => 0xc1,
            'c' => 0x107,
            'C' => 0x106,
            'e' => 0xe9,
            'E' => 0xc9,
            'i' => 0xed,
            'I' => 0xcd,
            'n' => 0x144,
            'N' => 0x143,
            'o' => 0xf3,
            'O' => 0xd3,
            's' => 0x15b,
            'S' => 0x15a,
            'u' => 0xfa,
            'U' => 0xda,
            'y' => 0xfd,
            'Y' => 0xdd,
            'z' => 0x17a,
            'Z' => 0x179,
            else => null,
        },
        .grave => switch (base) {
            'a' => 0xe0,
            'A' => 0xc0,
            'e' => 0xe8,
            'E' => 0xc8,
            'i' => 0xec,
            'I' => 0xcc,
            'o' => 0xf2,
            'O' => 0xd2,
            'u' => 0xf9,
            'U' => 0xd9,
            else => null,
        },
        .circumflex => switch (base) {
            'a' => 0xe2,
            'A' => 0xc2,
            'e' => 0xea,
            'E' => 0xca,
            'i' => 0xee,
            'I' => 0xce,
            'o' => 0xf4,
            'O' => 0xd4,
            'u' => 0xfb,
            'U' => 0xdb,
            else => null,
        },
        .tilde => switch (base) {
            'a' => 0xe3,
            'A' => 0xc3,
            'n' => 0xf1,
            'N' => 0xd1,
            'o' => 0xf5,
            'O' => 0xd5,
            else => null,
        },
        .diaeresis => switch (base) {
            'a' => 0xe4,
            'A' => 0xc4,
            'e' => 0xeb,
            'E' => 0xcb,
            'i' => 0xef,
            'I' => 0xcf,
            'o' => 0xf6,
            'O' => 0xd6,
            'u' => 0xfc,
            'U' => 0xdc,
            'y' => 0xff,
            'Y' => 0x178,
            else => null,
        },
        .cedilla => switch (base) {
            'c' => 0xe7,
            'C' => 0xc7,
            's' => 0x15f,
            'S' => 0x15e,
            else => null,
        },
        .caron => switch (base) {
            'c' => 0x10d,
            'C' => 0x10c,
            'd' => 0x10f,
            'D' => 0x10e,
            'e' => 0x11b,
            'E' => 0x11a,
            'n' => 0x148,
            'N' => 0x147,
            'r' => 0x159,
            'R' => 0x158,
            's' => 0x161,
            'S' => 0x160,
            't' => 0x165,
            'T' => 0x164,
            'z' => 0x17e,
            'Z' => 0x17d,
            else => null,
        },
        .macron => switch (base) {
            'a' => 0x101,
            'A' => 0x100,
            'e' => 0x113,
            'E' => 0x112,
            'i' => 0x12b,
            'I' => 0x12a,
            'o' => 0x14d,
            'O' => 0x14c,
            'u' => 0x16b,
            'U' => 0x16a,
            else => null,
        },
        .breve => switch (base) {
            'a' => 0x103,
            'A' => 0x102,
            else => null,
        },
        .abovering => switch (base) {
            'a' => 0xe5,
            'A' => 0xc5,
            else => null,
        },
        .ogonek => switch (base) {
            'a' => 0x105,
            'A' => 0x104,
            'e' => 0x119,
            'E' => 0x118,
            else => null,
        },
        .doubleacute => switch (base) {
            'o' => 0x151,
            'O' => 0x150,
            'u' => 0x171,
            'U' => 0x170,
            else => null,
        },
        .abovedot => switch (base) {
            'z' => 0x17c,
            'Z' => 0x17b,
            else => null,
        },
    };
}

fn deadFromPunct(c: u8) ?Dead {
    return switch (c) {
        '\'' => .acute,
        '`' => .grave,
        '^' => .circumflex,
        '~' => .tilde,
        '"' => .diaeresis,
        ',' => .cedilla,
        else => null,
    };
}

fn multiPair(a: u8, b: u8) ?u21 {
    if (deadFromPunct(a)) |dead| {
        if (composePair(dead, b)) |out| return out;
    }
    if (deadFromPunct(b)) |dead| {
        if (composePair(dead, a)) |out| return out;
    }
    if ((a == 'o' or a == 'O') and (b == 'a' or b == 'A')) {
        return if (std.ascii.isUpper(a) or std.ascii.isUpper(b)) 0xc5 else 0xe5;
    }
    if (a == '/' and (b == 'o' or b == 'O')) return if (b == 'O') 0xd8 else 0xf8;
    if (b == '/' and (a == 'o' or a == 'O')) return if (a == 'O') 0xd8 else 0xf8;
    if (a == '=' and (b == 'e' or b == 'E' or b == 'c' or b == 'C')) return 0x20ac;
    if (b == '=' and (a == 'e' or a == 'E' or a == 'c' or a == 'C')) return 0x20ac;
    if (a == 's' and b == 's') return 0xdf;
    return null;
}

test "extractSection finds a brace-balanced body and ignores an unrelated prefix match" {
    const text =
        \\xkb_keymap {
        \\  xkb_keycodes "evdev" {
        \\      minimum = 8;
        \\      <AE01> = 10;
        \\  };
        \\  xkb_symbols "pc" {
        \\      key <AE01> { [ 1, exclam ] };
        \\  };
        \\};
    ;
    const keycodes = (try extractSection(text, "xkb_keycodes")).?;
    try std.testing.expect(std.mem.indexOf(u8, keycodes, "<AE01> = 10;") != null);
    const symbols = (try extractSection(text, "xkb_symbols")).?;
    try std.testing.expect(std.mem.indexOf(u8, symbols, "key <AE01>") != null);
    try std.testing.expectEqual(@as(?[]const u8, null), try extractSection(text, "xkb_geometry"));
}

test "parse translates a realistic US-shaped fragment for base and shifted levels" {
    const text =
        \\xkb_keymap {
        \\  xkb_keycodes "evdev+aliases(qwerty)" {
        \\      minimum = 8;
        \\      maximum = 255;
        \\      <AE02> = 11;
        \\      <AC01> = 38;
        \\      <RTRN> = 36;
        \\      indicator 1 = "Caps Lock";
        \\  };
        \\  xkb_types "complete" {
        \\      // deliberately unparsed by this bounded parser
        \\  };
        \\  xkb_compat "complete" {
        \\  };
        \\  xkb_symbols "pc+us+inet(evdev)" {
        \\      key <AE02> {  [ 2, at ] };
        \\      key <AC01> {        [       a,      A       ]       };
        \\      key <RTRN> { [ Return ] };
        \\      modifier_map Shift { <LFSH> };
        \\  };
        \\};
    ;
    var keymap = try parse(std.testing.allocator, 1, text);
    defer keymap.deinit();

    // evdev code 3 = XKB keycode 11 = <AE02> = "2"/"at".
    try std.testing.expectEqualStrings("2", keymap.keysymFor(3, false).?);
    try std.testing.expectEqualStrings("at", keymap.keysymFor(3, true).?);
    try std.testing.expectEqual(@as(u8, '@'), charForKeysym(keymap.keysymFor(3, true).?).?);

    // evdev code 30 = XKB keycode 38 = <AC01> = "a"/"A".
    try std.testing.expectEqualStrings("a", keymap.keysymFor(30, false).?);
    try std.testing.expectEqualStrings("A", keymap.keysymFor(30, true).?);
    try std.testing.expectEqual(@as(u8, 'a'), charForKeysym("a").?);
    try std.testing.expectEqual(@as(u8, 'A'), charForKeysym("A").?);

    // A single-level key (<RTRN>) repeats its only keysym at both levels,
    // and resolves through the named-key table, not charForKeysym.
    try std.testing.expectEqualStrings("Return", keymap.keysymFor(28, false).?);
    try std.testing.expectEqualStrings("Return", keymap.keysymFor(28, true).?);
    try std.testing.expectEqual(NamedKey.enter, namedKeyForKeysym("Return").?);
    try std.testing.expectEqual(@as(?u21, null), charForKeysym("Return"));

    // A key with no entry at all (never declared).
    try std.testing.expectEqual(@as(?[]const u8, null), keymap.keysymFor(999, false));
}

test "parse keeps the third keysym as ISO Level3 / AltGr" {
    const text =
        \\xkb_keymap {
        \\  xkb_keycodes "evdev" {
        \\      minimum = 8;
        \\      maximum = 255;
        \\      <AC01> = 38;
        \\      <AE03> = 12;
        \\  };
        \\  xkb_symbols "pc+de" {
        \\      key <AC01> { [ a, A, ae ] };
        \\      key <AE03> { [ 3, section, threesuperior, sterling ] };
        \\  };
        \\};
    ;
    var keymap = try parse(std.testing.allocator, 1, text);
    defer keymap.deinit();

    try std.testing.expectEqualStrings("a", keymap.keysymForLevel(30, .base).?);
    try std.testing.expectEqualStrings("A", keymap.keysymForLevel(30, .shift).?);
    try std.testing.expectEqualStrings("ae", keymap.keysymForLevel(30, .level3).?);
    try std.testing.expectEqual(@as(u21, 0xe6), charForKeysym(keymap.keysymForLevel(30, .level3).?).?);
    try std.testing.expectEqualStrings("threesuperior", keymap.keysymForLevel(4, .level3).?);
    try std.testing.expectEqual(@as(u21, 0xb3), charForKeysym("threesuperior").?);
    try std.testing.expectEqual(@as(u21, 0x20ac), charForKeysym("EuroSign").?);
    try std.testing.expectEqual(@as(?[]const u8, null), keymap.keysymForLevel(28, .level3));
}

test "parse rejects an unsupported keymap format" {
    try std.testing.expectError(error.UnsupportedKeymapFormat, parse(std.testing.allocator, 0, ""));
}

test "parse fails closed on a missing section rather than returning a partial keymap" {
    try std.testing.expectError(
        error.KeycodesSectionMissing,
        parse(std.testing.allocator, 1, "xkb_keymap { xkb_symbols \"x\" { }; };"),
    );
    try std.testing.expectError(
        error.SymbolsSectionMissing,
        parse(std.testing.allocator, 1, "xkb_keymap { xkb_keycodes \"x\" { }; };"),
    );
}

test "charForKeysym and namedKeyForKeysym cover the documented tables" {
    try std.testing.expectEqual(@as(u8, ' '), charForKeysym("space").?);
    try std.testing.expectEqual(@as(u8, '!'), charForKeysym("exclam").?);
    try std.testing.expectEqual(@as(u8, '5'), charForKeysym("5").?);
    try std.testing.expectEqual(@as(?u21, null), charForKeysym("nonexistent_keysym_name"));
    try std.testing.expectEqual(@as(?u21, 0x20ac), charForKeysym("U20AC"));
    try std.testing.expectEqual(NamedKey.backspace, namedKeyForKeysym("BackSpace").?);
    try std.testing.expectEqual(NamedKey.page_up, namedKeyForKeysym("Prior").?);
    try std.testing.expectEqual(@as(?NamedKey, null), namedKeyForKeysym("nonexistent_keysym_name"));
}

test "dead-key compose arms, combines, and emits a standalone accent" {
    var compose: Compose = .{};
    try std.testing.expectEqual(Dead.acute, deadForKeysym("dead_acute").?);
    try std.testing.expectEqual(Dead.acute, deadForX11(0xfe51).?);
    try std.testing.expect(deadForKeysym("a") == null);
    try std.testing.expectEqual(Outcome.pending, compose.feedDead(.acute));
    try std.testing.expect(compose.active());
    try std.testing.expectEqual(Outcome{ .char = 0xe9 }, compose.feedChar('e'));
    try std.testing.expect(!compose.active());

    try std.testing.expectEqual(Outcome.pending, compose.feedDead(.tilde));
    try std.testing.expectEqual(Outcome{ .char = 0xf1 }, compose.feedChar('n'));

    try std.testing.expectEqual(Outcome.pending, compose.feedDead(.diaeresis));
    try std.testing.expectEqual(Outcome{ .char = 0xa8 }, compose.feedChar(' '));

    try std.testing.expectEqual(Outcome.pending, compose.feedDead(.grave));
    try std.testing.expectEqual(Outcome{ .char = '`' }, compose.feedDead(.grave));
}

test "Multi_key compose accepts punctuation+letter in either order" {
    var compose: Compose = .{};
    try std.testing.expect(isMultiKeyName("Multi_key"));
    try std.testing.expectEqual(Outcome.pending, compose.feedMulti());
    try std.testing.expectEqual(Outcome.pending, compose.feedChar('\''));
    try std.testing.expectEqual(Outcome{ .char = 0xe1 }, compose.feedChar('a'));

    try std.testing.expectEqual(Outcome.pending, compose.feedMulti());
    try std.testing.expectEqual(Outcome.pending, compose.feedChar('n'));
    try std.testing.expectEqual(Outcome{ .char = 0xf1 }, compose.feedChar('~'));

    try std.testing.expectEqual(Outcome.pending, compose.feedMulti());
    try std.testing.expectEqual(Outcome.pending, compose.feedChar('='));
    try std.testing.expectEqual(Outcome{ .char = 0x20ac }, compose.feedChar('e'));

    try std.testing.expectEqual(Outcome.pending, compose.feedMulti());
    try std.testing.expectEqual(Outcome.pending, compose.feedChar('s'));
    try std.testing.expectEqual(Outcome{ .char = 0xdf }, compose.feedChar('s'));
}

test "feedName prefers a parsed XCompose table over the built-in pairs" {
    const text =
        \\<Multi_key> <minus> <greater> : "→"
        \\<dead_acute> <e> : "é"
        \\
    ;
    var table = try compose_file.parse(std.testing.allocator, text);
    defer table.deinit();
    var compose: Compose = .{ .table = &table };
    try std.testing.expectEqual(Outcome.pending, compose.feedName("Multi_key"));
    try std.testing.expectEqual(Outcome.pending, compose.feedName("minus"));
    try std.testing.expectEqual(Outcome{ .char = 0x2192 }, compose.feedName("greater"));
    try std.testing.expectEqual(Outcome.pending, compose.feedName("dead_acute"));
    try std.testing.expectEqual(Outcome{ .char = 0xe9 }, compose.feedName("e"));
    try std.testing.expectEqualStrings("dead_acute", keysymNameForX11(0xfe51).?);
    try std.testing.expectEqualStrings("apostrophe", keysymNameForX11('\'').?);
}

test "loadComposeTable honors a missing XCOMPOSEFILE instead of falling through" {
    const table = try loadComposeTable(
        std.testing.allocator,
        "XCOMPOSEFILE=/tmp/comicchat-missing-xcompose\x00LANG=en_US.UTF-8\x00",
    );
    try std.testing.expect(table == null);
}
