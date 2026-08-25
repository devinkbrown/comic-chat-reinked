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
//! a third keysym, plus a second group when the keymap publishes two
//! `[ ... ]` lists). That is what makes the base, shifted, AltGr, and
//! group-2 character of a non-US or dual-layout keymap actually correct.
//! Named Central European letters, X11 Latin-2 keysyms (`0x01a0`–`0x01ff`),
//! Latin-9 OE/Ydiaeresis, Greek, Hebrew, Arabic, Armenian, Georgian, and Thai
//! letters resolve to
//! characters without an IME. A
//! bounded dead-key / Multi_key composer plus optional XCompose locale
//! tables (`~/.XCompose`,
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
    group2_base: ?[]const u8 = null,
    group2_shifted: ?[]const u8 = null,
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
        return self.keysymForGroupLevel(evdev_code, 0, level);
    }

    /// Group 0 is the first keysym list; group 1 is the second list when the
    /// keymap published two groups (`[ a, A ], [ Cyrillic_ef, ... ]`).
    pub fn keysymForGroupLevel(self: *const Keymap, evdev_code: u32, group: u32, level: Level) ?[]const u8 {
        const name = self.code_to_name.get(xkbKeycodeFromEvdev(evdev_code)) orelse return null;
        const levels = self.name_to_levels.get(name) orelse return null;
        if (group != 0) {
            const base = levels.group2_base orelse return switch (level) {
                .base => levels.base,
                .shift => levels.shifted,
                .level3 => levels.level3,
            };
            return switch (level) {
                .base => base,
                .shift => levels.group2_shifted orelse base,
                .level3 => null,
            };
        }
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
            var group2_base: ?[]const u8 = null;
            var group2_shifted: ?[]const u8 = null;
            if (try secondKeysymList(key_body)) |group2| {
                var group_it = std.mem.splitScalar(u8, group2, ',');
                while (group_it.next()) |raw| {
                    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
                    if (trimmed.len == 0) continue;
                    if (group2_base == null) {
                        group2_base = trimmed;
                    } else {
                        group2_shifted = trimmed;
                        break;
                    }
                }
            }
            if (base) |b| {
                try out.put(gpa, try arena.dupe(u8, name), .{
                    .base = try arena.dupe(u8, b),
                    .shifted = try arena.dupe(u8, shifted orelse b),
                    .level3 = if (level3) |third| try arena.dupe(u8, third) else null,
                    .group2_base = if (group2_base) |g2| try arena.dupe(u8, g2) else null,
                    .group2_shifted = if (group2_shifted) |g2s| try arena.dupe(u8, g2s) else null,
                });
            }
        }
        skipStatement(body, &i);
    }
}

/// Finds the contents of the first `[ ... ]` in a `key <NAME> { ... }` body
/// (the keysym list; may be preceded by `symbols[Group1] =` or nothing).
fn firstKeysymList(key_body: []const u8) ParseError!?[]const u8 {
    return keysymListAt(key_body, 0);
}

fn secondKeysymList(key_body: []const u8) ParseError!?[]const u8 {
    return keysymListAt(key_body, 1);
}

fn keysymListAt(key_body: []const u8, want: usize) ParseError!?[]const u8 {
    var found: usize = 0;
    var search: usize = 0;
    while (search < key_body.len) {
        const open = std.mem.indexOfScalarPos(u8, key_body, search, '[') orelse return null;
        const close = std.mem.indexOfScalarPos(u8, key_body, open, ']') orelse return error.MalformedKeymap;
        const inner = std.mem.trim(u8, key_body[open + 1 .. close], " \t\r\n");
        search = close + 1;
        if (std.mem.startsWith(u8, inner, "Group")) continue;
        if (found == want) return key_body[open + 1 .. close];
        found += 1;
    }
    return null;
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

/// Legacy X11 Cyrillic keysyms `0x06c0`–`0x06ff` (lowercase then uppercase),
/// plus `XK_Cyrillic_io` / `XK_Cyrillic_IO`. Used by a US+ru group-2 layout.
const cyrillic_06c0 = [_]u21{
    0x044e, 0x0430, 0x0431, 0x0446, 0x0434, 0x0435, 0x0444, 0x0433,
    0x0445, 0x0438, 0x0439, 0x043a, 0x043b, 0x043c, 0x043d, 0x043e,
    0x043f, 0x044f, 0x0440, 0x0441, 0x0442, 0x0443, 0x0436, 0x0432,
    0x044c, 0x044b, 0x0437, 0x0448, 0x044d, 0x0449, 0x0447, 0x044a,
};

const named_cyrillic_keysyms = std.StaticStringMap(u21).initComptime(.{
    .{ "Cyrillic_yu", 0x044e },
    .{ "Cyrillic_a", 0x0430 },
    .{ "Cyrillic_be", 0x0431 },
    .{ "Cyrillic_tse", 0x0446 },
    .{ "Cyrillic_de", 0x0434 },
    .{ "Cyrillic_ie", 0x0435 },
    .{ "Cyrillic_ef", 0x0444 },
    .{ "Cyrillic_ghe", 0x0433 },
    .{ "Cyrillic_ha", 0x0445 },
    .{ "Cyrillic_i", 0x0438 },
    .{ "Cyrillic_shorti", 0x0439 },
    .{ "Cyrillic_ka", 0x043a },
    .{ "Cyrillic_el", 0x043b },
    .{ "Cyrillic_em", 0x043c },
    .{ "Cyrillic_en", 0x043d },
    .{ "Cyrillic_o", 0x043e },
    .{ "Cyrillic_pe", 0x043f },
    .{ "Cyrillic_ya", 0x044f },
    .{ "Cyrillic_er", 0x0440 },
    .{ "Cyrillic_es", 0x0441 },
    .{ "Cyrillic_te", 0x0442 },
    .{ "Cyrillic_u", 0x0443 },
    .{ "Cyrillic_zhe", 0x0436 },
    .{ "Cyrillic_ve", 0x0432 },
    .{ "Cyrillic_softsign", 0x044c },
    .{ "Cyrillic_yeru", 0x044b },
    .{ "Cyrillic_ze", 0x0437 },
    .{ "Cyrillic_sha", 0x0448 },
    .{ "Cyrillic_e", 0x044d },
    .{ "Cyrillic_shcha", 0x0449 },
    .{ "Cyrillic_che", 0x0447 },
    .{ "Cyrillic_hardsign", 0x044a },
    .{ "Cyrillic_YU", 0x042e },
    .{ "Cyrillic_A", 0x0410 },
    .{ "Cyrillic_BE", 0x0411 },
    .{ "Cyrillic_TSE", 0x0426 },
    .{ "Cyrillic_DE", 0x0414 },
    .{ "Cyrillic_IE", 0x0415 },
    .{ "Cyrillic_EF", 0x0424 },
    .{ "Cyrillic_GHE", 0x0413 },
    .{ "Cyrillic_HA", 0x0425 },
    .{ "Cyrillic_I", 0x0418 },
    .{ "Cyrillic_SHORTI", 0x0419 },
    .{ "Cyrillic_KA", 0x041a },
    .{ "Cyrillic_EL", 0x041b },
    .{ "Cyrillic_EM", 0x041c },
    .{ "Cyrillic_EN", 0x041d },
    .{ "Cyrillic_O", 0x041e },
    .{ "Cyrillic_PE", 0x041f },
    .{ "Cyrillic_YA", 0x042f },
    .{ "Cyrillic_ER", 0x0420 },
    .{ "Cyrillic_ES", 0x0421 },
    .{ "Cyrillic_TE", 0x0422 },
    .{ "Cyrillic_U", 0x0423 },
    .{ "Cyrillic_ZHE", 0x0416 },
    .{ "Cyrillic_VE", 0x0412 },
    .{ "Cyrillic_SOFTSIGN", 0x042c },
    .{ "Cyrillic_YERU", 0x042b },
    .{ "Cyrillic_ZE", 0x0417 },
    .{ "Cyrillic_SHA", 0x0428 },
    .{ "Cyrillic_E", 0x042d },
    .{ "Cyrillic_SHCHA", 0x0429 },
    .{ "Cyrillic_CHE", 0x0427 },
    .{ "Cyrillic_HARDSIGN", 0x042a },
    .{ "Cyrillic_io", 0x0451 },
    .{ "Cyrillic_IO", 0x0401 },
});

/// Central European XKB names (Polish, Hungarian, Czech, Slovak, Romanian).
const named_latin_ext_keysyms = std.StaticStringMap(u21).initComptime(.{
    .{ "lstroke", 0x0142 },
    .{ "Lstroke", 0x0141 },
    .{ "aogonek", 0x0105 },
    .{ "Aogonek", 0x0104 },
    .{ "eogonek", 0x0119 },
    .{ "Eogonek", 0x0118 },
    .{ "sacute", 0x015b },
    .{ "Sacute", 0x015a },
    .{ "cacute", 0x0107 },
    .{ "Cacute", 0x0106 },
    .{ "nacute", 0x0144 },
    .{ "Nacute", 0x0143 },
    .{ "zacute", 0x017a },
    .{ "Zacute", 0x0179 },
    .{ "zabovedot", 0x017c },
    .{ "Zabovedot", 0x017b },
    .{ "zcaron", 0x017e },
    .{ "Zcaron", 0x017d },
    .{ "scaron", 0x0161 },
    .{ "Scaron", 0x0160 },
    .{ "ccaron", 0x010d },
    .{ "Ccaron", 0x010c },
    .{ "rcaron", 0x0159 },
    .{ "Rcaron", 0x0158 },
    .{ "ecaron", 0x011b },
    .{ "Ecaron", 0x011a },
    .{ "ncaron", 0x0148 },
    .{ "Ncaron", 0x0147 },
    .{ "dcaron", 0x010f },
    .{ "Dcaron", 0x010e },
    .{ "tcaron", 0x0165 },
    .{ "Tcaron", 0x0164 },
    .{ "lcaron", 0x013e },
    .{ "Lcaron", 0x013d },
    .{ "uring", 0x016f },
    .{ "Uring", 0x016e },
    .{ "odoubleacute", 0x0151 },
    .{ "Odoubleacute", 0x0150 },
    .{ "udoubleacute", 0x0171 },
    .{ "Udoubleacute", 0x0170 },
    .{ "abreve", 0x0103 },
    .{ "Abreve", 0x0102 },
    .{ "gbreve", 0x011f },
    .{ "Gbreve", 0x011e },
    .{ "scommaaccent", 0x0219 },
    .{ "Scommaaccent", 0x0218 },
    .{ "tcommaaccent", 0x021b },
    .{ "Tcommaaccent", 0x021a },
    .{ "OE", 0x0152 },
    .{ "oe", 0x0153 },
    .{ "Ydiaeresis", 0x0178 },
});

const named_greek_keysyms = std.StaticStringMap(u21).initComptime(.{
    .{ "Greek_ALPHA", 0x0391 },
    .{ "Greek_BETA", 0x0392 },
    .{ "Greek_GAMMA", 0x0393 },
    .{ "Greek_DELTA", 0x0394 },
    .{ "Greek_EPSILON", 0x0395 },
    .{ "Greek_ZETA", 0x0396 },
    .{ "Greek_ETA", 0x0397 },
    .{ "Greek_THETA", 0x0398 },
    .{ "Greek_IOTA", 0x0399 },
    .{ "Greek_KAPPA", 0x039a },
    .{ "Greek_LAMDA", 0x039b },
    .{ "Greek_LAMBDA", 0x039b },
    .{ "Greek_MU", 0x039c },
    .{ "Greek_NU", 0x039d },
    .{ "Greek_XI", 0x039e },
    .{ "Greek_OMICRON", 0x039f },
    .{ "Greek_PI", 0x03a0 },
    .{ "Greek_RHO", 0x03a1 },
    .{ "Greek_SIGMA", 0x03a3 },
    .{ "Greek_TAU", 0x03a4 },
    .{ "Greek_UPSILON", 0x03a5 },
    .{ "Greek_PHI", 0x03a6 },
    .{ "Greek_CHI", 0x03a7 },
    .{ "Greek_PSI", 0x03a8 },
    .{ "Greek_OMEGA", 0x03a9 },
    .{ "Greek_alpha", 0x03b1 },
    .{ "Greek_beta", 0x03b2 },
    .{ "Greek_gamma", 0x03b3 },
    .{ "Greek_delta", 0x03b4 },
    .{ "Greek_epsilon", 0x03b5 },
    .{ "Greek_zeta", 0x03b6 },
    .{ "Greek_eta", 0x03b7 },
    .{ "Greek_theta", 0x03b8 },
    .{ "Greek_iota", 0x03b9 },
    .{ "Greek_kappa", 0x03ba },
    .{ "Greek_lamda", 0x03bb },
    .{ "Greek_lambda", 0x03bb },
    .{ "Greek_mu", 0x03bc },
    .{ "Greek_nu", 0x03bd },
    .{ "Greek_xi", 0x03be },
    .{ "Greek_omicron", 0x03bf },
    .{ "Greek_pi", 0x03c0 },
    .{ "Greek_rho", 0x03c1 },
    .{ "Greek_sigma", 0x03c3 },
    .{ "Greek_finalsmallsigma", 0x03c2 },
    .{ "Greek_tau", 0x03c4 },
    .{ "Greek_upsilon", 0x03c5 },
    .{ "Greek_phi", 0x03c6 },
    .{ "Greek_chi", 0x03c7 },
    .{ "Greek_psi", 0x03c8 },
    .{ "Greek_omega", 0x03c9 },
});

const named_hebrew_keysyms = std.StaticStringMap(u21).initComptime(.{
    .{ "hebrew_aleph", 0x05d0 },
    .{ "hebrew_bet", 0x05d1 },
    .{ "hebrew_beth", 0x05d1 },
    .{ "hebrew_gimel", 0x05d2 },
    .{ "hebrew_gimmel", 0x05d2 },
    .{ "hebrew_dalet", 0x05d3 },
    .{ "hebrew_daleth", 0x05d3 },
    .{ "hebrew_he", 0x05d4 },
    .{ "hebrew_waw", 0x05d5 },
    .{ "hebrew_zain", 0x05d6 },
    .{ "hebrew_zayin", 0x05d6 },
    .{ "hebrew_chet", 0x05d7 },
    .{ "hebrew_het", 0x05d7 },
    .{ "hebrew_tet", 0x05d8 },
    .{ "hebrew_teth", 0x05d8 },
    .{ "hebrew_yod", 0x05d9 },
    .{ "hebrew_finalkaph", 0x05da },
    .{ "hebrew_kaph", 0x05db },
    .{ "hebrew_lamed", 0x05dc },
    .{ "hebrew_finalmem", 0x05dd },
    .{ "hebrew_mem", 0x05de },
    .{ "hebrew_finalnun", 0x05df },
    .{ "hebrew_nun", 0x05e0 },
    .{ "hebrew_samech", 0x05e1 },
    .{ "hebrew_samekh", 0x05e1 },
    .{ "hebrew_ayin", 0x05e2 },
    .{ "hebrew_finalpe", 0x05e3 },
    .{ "hebrew_pe", 0x05e4 },
    .{ "hebrew_finalzade", 0x05e5 },
    .{ "hebrew_zade", 0x05e6 },
    .{ "hebrew_qoph", 0x05e7 },
    .{ "hebrew_kuf", 0x05e7 },
    .{ "hebrew_qof", 0x05e7 },
    .{ "hebrew_resh", 0x05e8 },
    .{ "hebrew_shin", 0x05e9 },
    .{ "hebrew_taw", 0x05ea },
    .{ "hebrew_taf", 0x05ea },
    .{ "Hebrew_aleph", 0x05d0 },
    .{ "Hebrew_bet", 0x05d1 },
    .{ "Hebrew_gimel", 0x05d2 },
    .{ "Hebrew_dalet", 0x05d3 },
    .{ "Hebrew_he", 0x05d4 },
    .{ "Hebrew_waw", 0x05d5 },
    .{ "Hebrew_zain", 0x05d6 },
    .{ "Hebrew_chet", 0x05d7 },
    .{ "Hebrew_tet", 0x05d8 },
    .{ "Hebrew_yod", 0x05d9 },
    .{ "Hebrew_finalkaph", 0x05da },
    .{ "Hebrew_kaph", 0x05db },
    .{ "Hebrew_lamed", 0x05dc },
    .{ "Hebrew_finalmem", 0x05dd },
    .{ "Hebrew_mem", 0x05de },
    .{ "Hebrew_finalnun", 0x05df },
    .{ "Hebrew_nun", 0x05e0 },
    .{ "Hebrew_samech", 0x05e1 },
    .{ "Hebrew_ayin", 0x05e2 },
    .{ "Hebrew_finalpe", 0x05e3 },
    .{ "Hebrew_pe", 0x05e4 },
    .{ "Hebrew_finalzade", 0x05e5 },
    .{ "Hebrew_zade", 0x05e6 },
    .{ "Hebrew_qoph", 0x05e7 },
    .{ "Hebrew_resh", 0x05e8 },
    .{ "Hebrew_shin", 0x05e9 },
    .{ "Hebrew_taw", 0x05ea },
});

const named_arabic_keysyms = std.StaticStringMap(u21).initComptime(.{
    .{ "Arabic_comma", 0x060c },
    .{ "Arabic_semicolon", 0x061b },
    .{ "Arabic_question_mark", 0x061f },
    .{ "Arabic_hamza", 0x0621 },
    .{ "Arabic_maddaonalef", 0x0622 },
    .{ "Arabic_hamzaonalef", 0x0623 },
    .{ "Arabic_hamzaonwaw", 0x0624 },
    .{ "Arabic_hamzaunderalef", 0x0625 },
    .{ "Arabic_hamzaonyeh", 0x0626 },
    .{ "Arabic_alef", 0x0627 },
    .{ "Arabic_beh", 0x0628 },
    .{ "Arabic_tehmarbuta", 0x0629 },
    .{ "Arabic_teh", 0x062a },
    .{ "Arabic_theh", 0x062b },
    .{ "Arabic_jeem", 0x062c },
    .{ "Arabic_hah", 0x062d },
    .{ "Arabic_khah", 0x062e },
    .{ "Arabic_dal", 0x062f },
    .{ "Arabic_thal", 0x0630 },
    .{ "Arabic_ra", 0x0631 },
    .{ "Arabic_zain", 0x0632 },
    .{ "Arabic_seen", 0x0633 },
    .{ "Arabic_sheen", 0x0634 },
    .{ "Arabic_sad", 0x0635 },
    .{ "Arabic_dad", 0x0636 },
    .{ "Arabic_tah", 0x0637 },
    .{ "Arabic_zah", 0x0638 },
    .{ "Arabic_ain", 0x0639 },
    .{ "Arabic_ghain", 0x063a },
    .{ "Arabic_tatweel", 0x0640 },
    .{ "Arabic_feh", 0x0641 },
    .{ "Arabic_qaf", 0x0642 },
    .{ "Arabic_kaf", 0x0643 },
    .{ "Arabic_lam", 0x0644 },
    .{ "Arabic_meem", 0x0645 },
    .{ "Arabic_noon", 0x0646 },
    .{ "Arabic_heh", 0x0647 },
    .{ "Arabic_waw", 0x0648 },
    .{ "Arabic_alefmaksura", 0x0649 },
    .{ "Arabic_yeh", 0x064a },
    .{ "Arabic_fathatan", 0x064b },
    .{ "Arabic_dammatan", 0x064c },
    .{ "Arabic_kasratan", 0x064d },
    .{ "Arabic_fatha", 0x064e },
    .{ "Arabic_damma", 0x064f },
    .{ "Arabic_kasra", 0x0650 },
    .{ "Arabic_shadda", 0x0651 },
    .{ "Arabic_sukun", 0x0652 },
});

const named_armenian_keysyms = std.StaticStringMap(u21).initComptime(.{
    .{ "Armenian_ligature_ew", 0x0587 },
    .{ "Armenian_full_stop", 0x0589 },
    .{ "Armenian_verjaket", 0x0589 },
    .{ "Armenian_separation_mark", 0x055d },
    .{ "Armenian_but", 0x055d },
    .{ "Armenian_hyphen", 0x058a },
    .{ "Armenian_yentamna", 0x058a },
    .{ "Armenian_exclam", 0x055c },
    .{ "Armenian_amanak", 0x055c },
    .{ "Armenian_accent", 0x055b },
    .{ "Armenian_shesht", 0x055b },
    .{ "Armenian_question", 0x055e },
    .{ "Armenian_paruyk", 0x055e },
    .{ "Armenian_apostrophe", 0x055a },
    .{ "Armenian_AYB", 0x0531 },
    .{ "Armenian_ayb", 0x0561 },
    .{ "Armenian_BEN", 0x0532 },
    .{ "Armenian_ben", 0x0562 },
    .{ "Armenian_GIM", 0x0533 },
    .{ "Armenian_gim", 0x0563 },
    .{ "Armenian_DA", 0x0534 },
    .{ "Armenian_da", 0x0564 },
    .{ "Armenian_YECH", 0x0535 },
    .{ "Armenian_yech", 0x0565 },
    .{ "Armenian_ZA", 0x0536 },
    .{ "Armenian_za", 0x0566 },
    .{ "Armenian_E", 0x0537 },
    .{ "Armenian_e", 0x0567 },
    .{ "Armenian_AT", 0x0538 },
    .{ "Armenian_at", 0x0568 },
    .{ "Armenian_TO", 0x0539 },
    .{ "Armenian_to", 0x0569 },
    .{ "Armenian_ZHE", 0x053a },
    .{ "Armenian_zhe", 0x056a },
    .{ "Armenian_INI", 0x053b },
    .{ "Armenian_ini", 0x056b },
    .{ "Armenian_LYUN", 0x053c },
    .{ "Armenian_lyun", 0x056c },
    .{ "Armenian_KHE", 0x053d },
    .{ "Armenian_khe", 0x056d },
    .{ "Armenian_TSA", 0x053e },
    .{ "Armenian_tsa", 0x056e },
    .{ "Armenian_KEN", 0x053f },
    .{ "Armenian_ken", 0x056f },
    .{ "Armenian_HO", 0x0540 },
    .{ "Armenian_ho", 0x0570 },
    .{ "Armenian_DZA", 0x0541 },
    .{ "Armenian_dza", 0x0571 },
    .{ "Armenian_GHAT", 0x0542 },
    .{ "Armenian_ghat", 0x0572 },
    .{ "Armenian_TCHE", 0x0543 },
    .{ "Armenian_tche", 0x0573 },
    .{ "Armenian_MEN", 0x0544 },
    .{ "Armenian_men", 0x0574 },
    .{ "Armenian_HI", 0x0545 },
    .{ "Armenian_hi", 0x0575 },
    .{ "Armenian_NU", 0x0546 },
    .{ "Armenian_nu", 0x0576 },
    .{ "Armenian_SHA", 0x0547 },
    .{ "Armenian_sha", 0x0577 },
    .{ "Armenian_VO", 0x0548 },
    .{ "Armenian_vo", 0x0578 },
    .{ "Armenian_CHA", 0x0549 },
    .{ "Armenian_cha", 0x0579 },
    .{ "Armenian_PE", 0x054a },
    .{ "Armenian_pe", 0x057a },
    .{ "Armenian_JE", 0x054b },
    .{ "Armenian_je", 0x057b },
    .{ "Armenian_RA", 0x054c },
    .{ "Armenian_ra", 0x057c },
    .{ "Armenian_SE", 0x054d },
    .{ "Armenian_se", 0x057d },
    .{ "Armenian_VEV", 0x054e },
    .{ "Armenian_vev", 0x057e },
    .{ "Armenian_TYUN", 0x054f },
    .{ "Armenian_tyun", 0x057f },
    .{ "Armenian_RE", 0x0550 },
    .{ "Armenian_re", 0x0580 },
    .{ "Armenian_TSO", 0x0551 },
    .{ "Armenian_tso", 0x0581 },
    .{ "Armenian_VYUN", 0x0552 },
    .{ "Armenian_vyun", 0x0582 },
    .{ "Armenian_PYUR", 0x0553 },
    .{ "Armenian_pyur", 0x0583 },
    .{ "Armenian_KE", 0x0554 },
    .{ "Armenian_ke", 0x0584 },
    .{ "Armenian_O", 0x0555 },
    .{ "Armenian_o", 0x0585 },
    .{ "Armenian_FE", 0x0556 },
    .{ "Armenian_fe", 0x0586 },
});

const named_georgian_keysyms = std.StaticStringMap(u21).initComptime(.{
    .{ "Georgian_an", 0x10d0 },
    .{ "Georgian_ban", 0x10d1 },
    .{ "Georgian_gan", 0x10d2 },
    .{ "Georgian_don", 0x10d3 },
    .{ "Georgian_en", 0x10d4 },
    .{ "Georgian_vin", 0x10d5 },
    .{ "Georgian_zen", 0x10d6 },
    .{ "Georgian_tan", 0x10d7 },
    .{ "Georgian_in", 0x10d8 },
    .{ "Georgian_kan", 0x10d9 },
    .{ "Georgian_las", 0x10da },
    .{ "Georgian_man", 0x10db },
    .{ "Georgian_nar", 0x10dc },
    .{ "Georgian_on", 0x10dd },
    .{ "Georgian_par", 0x10de },
    .{ "Georgian_zhar", 0x10df },
    .{ "Georgian_rae", 0x10e0 },
    .{ "Georgian_san", 0x10e1 },
    .{ "Georgian_tar", 0x10e2 },
    .{ "Georgian_un", 0x10e3 },
    .{ "Georgian_phar", 0x10e4 },
    .{ "Georgian_khar", 0x10e5 },
    .{ "Georgian_ghan", 0x10e6 },
    .{ "Georgian_qar", 0x10e7 },
    .{ "Georgian_shin", 0x10e8 },
    .{ "Georgian_chin", 0x10e9 },
    .{ "Georgian_can", 0x10ea },
    .{ "Georgian_jil", 0x10eb },
    .{ "Georgian_cil", 0x10ec },
    .{ "Georgian_char", 0x10ed },
    .{ "Georgian_xan", 0x10ee },
    .{ "Georgian_jhan", 0x10ef },
    .{ "Georgian_hae", 0x10f0 },
    .{ "Georgian_he", 0x10f1 },
    .{ "Georgian_hie", 0x10f2 },
    .{ "Georgian_we", 0x10f3 },
    .{ "Georgian_har", 0x10f4 },
    .{ "Georgian_hoe", 0x10f5 },
    .{ "Georgian_fi", 0x10f6 },
});

const named_thai_keysyms = std.StaticStringMap(u21).initComptime(.{
    .{ "Thai_kokai", 0x0e01 },
    .{ "Thai_khokhai", 0x0e02 },
    .{ "Thai_khokhuat", 0x0e03 },
    .{ "Thai_khokhwai", 0x0e04 },
    .{ "Thai_khokhon", 0x0e05 },
    .{ "Thai_khorakhang", 0x0e06 },
    .{ "Thai_ngongu", 0x0e07 },
    .{ "Thai_chochan", 0x0e08 },
    .{ "Thai_choching", 0x0e09 },
    .{ "Thai_chochang", 0x0e0a },
    .{ "Thai_soso", 0x0e0b },
    .{ "Thai_chochoe", 0x0e0c },
    .{ "Thai_yoying", 0x0e0d },
    .{ "Thai_dochada", 0x0e0e },
    .{ "Thai_topatak", 0x0e0f },
    .{ "Thai_thothan", 0x0e10 },
    .{ "Thai_thonangmontho", 0x0e11 },
    .{ "Thai_thophuthao", 0x0e12 },
    .{ "Thai_nonen", 0x0e13 },
    .{ "Thai_dodek", 0x0e14 },
    .{ "Thai_totao", 0x0e15 },
    .{ "Thai_thothung", 0x0e16 },
    .{ "Thai_thothahan", 0x0e17 },
    .{ "Thai_thothong", 0x0e18 },
    .{ "Thai_nonu", 0x0e19 },
    .{ "Thai_bobaimai", 0x0e1a },
    .{ "Thai_popla", 0x0e1b },
    .{ "Thai_phophung", 0x0e1c },
    .{ "Thai_fofa", 0x0e1d },
    .{ "Thai_phophan", 0x0e1e },
    .{ "Thai_fofan", 0x0e1f },
    .{ "Thai_phosamphao", 0x0e20 },
    .{ "Thai_moma", 0x0e21 },
    .{ "Thai_yoyak", 0x0e22 },
    .{ "Thai_rorua", 0x0e23 },
    .{ "Thai_ru", 0x0e24 },
    .{ "Thai_loling", 0x0e25 },
    .{ "Thai_lu", 0x0e26 },
    .{ "Thai_wowaen", 0x0e27 },
    .{ "Thai_sosala", 0x0e28 },
    .{ "Thai_sorusi", 0x0e29 },
    .{ "Thai_sosua", 0x0e2a },
    .{ "Thai_hohip", 0x0e2b },
    .{ "Thai_lochula", 0x0e2c },
    .{ "Thai_oang", 0x0e2d },
    .{ "Thai_honokhuk", 0x0e2e },
    .{ "Thai_paiyannoi", 0x0e2f },
    .{ "Thai_saraa", 0x0e30 },
    .{ "Thai_maihanakat", 0x0e31 },
    .{ "Thai_saraaa", 0x0e32 },
    .{ "Thai_saraam", 0x0e33 },
    .{ "Thai_sarai", 0x0e34 },
    .{ "Thai_saraii", 0x0e35 },
    .{ "Thai_saraue", 0x0e36 },
    .{ "Thai_sarauee", 0x0e37 },
    .{ "Thai_sarau", 0x0e38 },
    .{ "Thai_sarauu", 0x0e39 },
    .{ "Thai_phinthu", 0x0e3a },
    .{ "Thai_baht", 0x0e3f },
    .{ "Thai_sarae", 0x0e40 },
    .{ "Thai_saraae", 0x0e41 },
    .{ "Thai_sarao", 0x0e42 },
    .{ "Thai_saraaimaimuan", 0x0e43 },
    .{ "Thai_saraaimaimalai", 0x0e44 },
    .{ "Thai_lakkhangyao", 0x0e45 },
    .{ "Thai_maiyamok", 0x0e46 },
    .{ "Thai_maitaikhu", 0x0e47 },
    .{ "Thai_maiek", 0x0e48 },
    .{ "Thai_maitho", 0x0e49 },
    .{ "Thai_maitri", 0x0e4a },
    .{ "Thai_maichattawa", 0x0e4b },
    .{ "Thai_thanthakhat", 0x0e4c },
    .{ "Thai_nikhahit", 0x0e4d },
    .{ "Thai_leksun", 0x0e50 },
    .{ "Thai_leknung", 0x0e51 },
    .{ "Thai_leksong", 0x0e52 },
    .{ "Thai_leksam", 0x0e53 },
    .{ "Thai_leksi", 0x0e54 },
    .{ "Thai_lekha", 0x0e55 },
    .{ "Thai_lekhok", 0x0e56 },
    .{ "Thai_lekchet", 0x0e57 },
    .{ "Thai_lekpaet", 0x0e58 },
    .{ "Thai_lekkao", 0x0e59 },
});

/// ISO-8859-2 codepoints for X11 Latin-2 keysyms `0x01a0`–`0x01ff`.
const latin2_01a0 = [_]u21{
    0x00a0, 0x0104, 0x02d8, 0x0141, 0x00a4, 0x013d, 0x015a, 0x00a7,
    0x00a8, 0x0160, 0x015e, 0x0164, 0x0179, 0x00ad, 0x017d, 0x017b,
    0x00b0, 0x0105, 0x02db, 0x0142, 0x00b4, 0x013e, 0x015b, 0x02c7,
    0x00b8, 0x0161, 0x015f, 0x0165, 0x017a, 0x02dd, 0x017e, 0x017c,
    0x0154, 0x00c1, 0x00c2, 0x0102, 0x00c4, 0x0139, 0x0106, 0x00c7,
    0x010c, 0x00c9, 0x0118, 0x00cb, 0x011a, 0x00cd, 0x00ce, 0x010e,
    0x0110, 0x0143, 0x0147, 0x00d3, 0x00d4, 0x0150, 0x00d6, 0x00d7,
    0x0158, 0x016e, 0x00da, 0x0170, 0x00dc, 0x00dd, 0x0162, 0x00df,
    0x0155, 0x00e1, 0x00e2, 0x0103, 0x00e4, 0x013a, 0x0107, 0x00e7,
    0x010d, 0x00e9, 0x0119, 0x00eb, 0x011b, 0x00ed, 0x00ee, 0x010f,
    0x0111, 0x0144, 0x0148, 0x00f3, 0x00f4, 0x0151, 0x00f6, 0x00f7,
    0x0159, 0x016f, 0x00fa, 0x0171, 0x00fc, 0x00fd, 0x0163, 0x02d9,
};

/// Resolves a keysym name to a plain character, if it is one. Covers the
/// bare-letter/digit case ("a", "A", "5") and the named-punctuation table
/// above; returns null for anything else (a named key, or an unrecognized
/// keysym this bounded parser does not translate).
pub fn charForKeysym(name: []const u8) ?u21 {
    if (name.len == 1 and std.ascii.isPrint(name[0])) return name[0];
    if (std.mem.eql(u8, name, "EuroSign") or std.mem.eql(u8, name, "euro")) return 0x20ac;
    if (named_char_keysyms.get(name)) |character| return character;
    if (named_cyrillic_keysyms.get(name)) |character| return character;
    if (named_latin_ext_keysyms.get(name)) |character| return character;
    if (named_greek_keysyms.get(name)) |character| return character;
    if (named_hebrew_keysyms.get(name)) |character| return character;
    if (named_arabic_keysyms.get(name)) |character| return character;
    if (named_armenian_keysyms.get(name)) |character| return character;
    if (named_georgian_keysyms.get(name)) |character| return character;
    if (named_thai_keysyms.get(name)) |character| return character;
    if (name.len >= 5 and name.len <= 7 and name[0] == 'U') {
        const value = std.fmt.parseInt(u21, name[1..], 16) catch return null;
        if (value > 0x10ffff or (value >= 0xd800 and value <= 0xdfff)) return null;
        return value;
    }
    return null;
}

/// Legacy X11 Cyrillic keysyms used by a second keyboard group.
pub fn charForX11Cyrillic(sym: u32) ?u21 {
    if (sym == 0x06a3) return 0x0451;
    if (sym == 0x06b3) return 0x0401;
    if (sym >= 0x06c0 and sym <= 0x06ff) {
        const lower = cyrillic_06c0[(sym - 0x06c0) & 0x1f];
        return if (sym >= 0x06e0) lower - 0x20 else lower;
    }
    return null;
}

/// Legacy X11 Latin-2 keysyms used by Central European layouts.
pub fn charForX11Latin2(sym: u32) ?u21 {
    if (sym < 0x01a0 or sym > 0x01ff) return null;
    return latin2_01a0[sym - 0x01a0];
}

/// Legacy X11 Greek keysyms. SIGMA skips U+03A2; final sigma is 0x07f3.
pub fn charForX11Greek(sym: u32) ?u21 {
    if (sym >= 0x07c1 and sym <= 0x07d1) return @intCast(0x0391 + (sym - 0x07c1));
    if (sym >= 0x07d2 and sym <= 0x07d8) return @intCast(0x03a3 + (sym - 0x07d2));
    if (sym >= 0x07e1 and sym <= 0x07f1) return @intCast(0x03b1 + (sym - 0x07e1));
    if (sym == 0x07f2) return 0x03c3;
    if (sym == 0x07f3) return 0x03c2;
    if (sym >= 0x07f4 and sym <= 0x07f9) return @intCast(0x03c4 + (sym - 0x07f4));
    return null;
}

/// Legacy X11 Hebrew keysyms. `0x0ce0`–`0x0cfa` map onto U+05D0–U+05EA.
pub fn charForX11Hebrew(sym: u32) ?u21 {
    if (sym == 0x0cdf) return 0x2017;
    if (sym >= 0x0ce0 and sym <= 0x0cfa) return @intCast(0x05d0 + (sym - 0x0ce0));
    return null;
}

/// Legacy X11 Arabic keysyms. `0x05c1`–`0x05f2` sit 0x60 below U+0621–U+0652.
pub fn charForX11Arabic(sym: u32) ?u21 {
    return switch (sym) {
        0x05ac => 0x060c,
        0x05bb => 0x061b,
        0x05bf => 0x061f,
        0x05c1...0x05da => @intCast(sym + 0x60),
        0x05e0...0x05f2 => @intCast(sym + 0x60),
        else => null,
    };
}

/// Legacy X11 Armenian keysyms. Letters `0x14b2`–`0x14fd` pair upper/lower
/// onto U+0531–U+0556 / U+0561–U+0586; a few punctuation codes sit below.
pub fn charForX11Armenian(sym: u32) ?u21 {
    return switch (sym) {
        0x14a1 => 0x0587,
        0x14a3 => 0x0589,
        0x14a4 => 0x055d,
        0x14a5 => 0x058a,
        0x14a7 => 0x055c,
        0x14a8 => 0x055b,
        0x14a9 => 0x055e,
        0x14b2...0x14fd => blk: {
            const i = sym - 0x14b2;
            break :blk @as(u21, @intCast(if (i % 2 == 0) 0x0531 + i / 2 else 0x0561 + i / 2));
        },
        else => null,
    };
}

/// Legacy X11 Georgian keysyms. `0x15d0`–`0x15f6` map onto U+10D0–U+10F6.
pub fn charForX11Georgian(sym: u32) ?u21 {
    if (sym < 0x15d0 or sym > 0x15f6) return null;
    return @intCast(0x10d0 + (sym - 0x15d0));
}

/// Legacy X11 Thai keysyms. `0x0da1`–`0x0df9` sit 0x60 below U+0E01–U+0E59,
/// skipping the unused U+0E3B–U+0E3E hole.
pub fn charForX11Thai(sym: u32) ?u21 {
    if (sym < 0x0da1 or sym > 0x0df9) return null;
    const ch: u21 = @intCast(sym + 0x60);
    if (ch >= 0x0e3b and ch <= 0x0e3e) return null;
    return ch;
}

/// ISO-8859-15 leftovers used by Western European layouts (OE, Ydiaeresis).
pub fn charForX11Latin9(sym: u32) ?u21 {
    return switch (sym) {
        0x13bc => 0x0152,
        0x13bd => 0x0153,
        0x13be => 0x0178,
        else => null,
    };
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

test "parse keeps a second keysym list as keyboard group 2" {
    const text =
        \\xkb_keymap {
        \\  xkb_keycodes "evdev" {
        \\      <AC01> = 38;
        \\  };
        \\  xkb_symbols "pc+us+ru:2" {
        \\      key <AC01> { [ a, A ], [ Cyrillic_ef, Cyrillic_EF ] };
        \\  };
        \\};
    ;
    var keymap = try parse(std.testing.allocator, 1, text);
    defer keymap.deinit();
    try std.testing.expectEqualStrings("a", keymap.keysymForGroupLevel(30, 0, .base).?);
    try std.testing.expectEqualStrings("Cyrillic_ef", keymap.keysymForGroupLevel(30, 1, .base).?);
    try std.testing.expectEqualStrings("Cyrillic_EF", keymap.keysymForGroupLevel(30, 1, .shift).?);
    try std.testing.expectEqual(@as(u21, 0x0444), charForKeysym("Cyrillic_ef").?);
    try std.testing.expectEqual(@as(u21, 0x0424), charForKeysym("Cyrillic_EF").?);
    try std.testing.expectEqual(@as(u21, 0x0444), charForX11Cyrillic(0x06c6).?);
    try std.testing.expectEqual(@as(u21, 0x0424), charForX11Cyrillic(0x06e6).?);
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
    try std.testing.expectEqual(@as(u21, 0x0142), charForKeysym("lstroke").?);
    try std.testing.expectEqual(@as(u21, 0x0151), charForKeysym("odoubleacute").?);
    try std.testing.expectEqual(@as(u21, 0x0142), charForX11Latin2(0x01b3).?);
    try std.testing.expectEqual(@as(u21, 0x0151), charForX11Latin2(0x01f5).?);
    try std.testing.expectEqual(@as(u21, 0x03b1), charForKeysym("Greek_alpha").?);
    try std.testing.expectEqual(@as(u21, 0x03a3), charForKeysym("Greek_SIGMA").?);
    try std.testing.expectEqual(@as(u21, 0x03c2), charForX11Greek(0x07f3).?);
    try std.testing.expectEqual(@as(u21, 0x03a9), charForX11Greek(0x07d8).?);
    try std.testing.expectEqual(@as(u21, 0x05d0), charForKeysym("hebrew_aleph").?);
    try std.testing.expectEqual(@as(u21, 0x05ea), charForKeysym("hebrew_taw").?);
    try std.testing.expectEqual(@as(u21, 0x05d0), charForX11Hebrew(0x0ce0).?);
    try std.testing.expectEqual(@as(u21, 0x05da), charForX11Hebrew(0x0cea).?);
    try std.testing.expectEqual(@as(u21, 0x05ea), charForX11Hebrew(0x0cfa).?);
    try std.testing.expectEqual(@as(u21, 0x2017), charForX11Hebrew(0x0cdf).?);
    try std.testing.expectEqual(@as(u21, 0x0627), charForKeysym("Arabic_alef").?);
    try std.testing.expectEqual(@as(u21, 0x064a), charForKeysym("Arabic_yeh").?);
    try std.testing.expectEqual(@as(u21, 0x0627), charForX11Arabic(0x05c7).?);
    try std.testing.expectEqual(@as(u21, 0x064a), charForX11Arabic(0x05ea).?);
    try std.testing.expectEqual(@as(u21, 0x0652), charForX11Arabic(0x05f2).?);
    try std.testing.expectEqual(@as(u21, 0x0152), charForKeysym("OE").?);
    try std.testing.expectEqual(@as(u21, 0x0153), charForX11Latin9(0x13bd).?);
    try std.testing.expectEqual(@as(u21, 0x0178), charForX11Latin9(0x13be).?);
    try std.testing.expectEqual(@as(u21, 0x0561), charForKeysym("Armenian_ayb").?);
    try std.testing.expectEqual(@as(u21, 0x0531), charForKeysym("Armenian_AYB").?);
    try std.testing.expectEqual(@as(u21, 0x0589), charForKeysym("Armenian_verjaket").?);
    try std.testing.expectEqual(@as(u21, 0x0531), charForX11Armenian(0x14b2).?);
    try std.testing.expectEqual(@as(u21, 0x0561), charForX11Armenian(0x14b3).?);
    try std.testing.expectEqual(@as(u21, 0x0586), charForX11Armenian(0x14fd).?);
    try std.testing.expectEqual(@as(u21, 0x10d0), charForKeysym("Georgian_an").?);
    try std.testing.expectEqual(@as(u21, 0x10f6), charForKeysym("Georgian_fi").?);
    try std.testing.expectEqual(@as(u21, 0x10d0), charForX11Georgian(0x15d0).?);
    try std.testing.expectEqual(@as(u21, 0x10f6), charForX11Georgian(0x15f6).?);
    try std.testing.expectEqual(@as(u21, 0x0e01), charForKeysym("Thai_kokai").?);
    try std.testing.expectEqual(@as(u21, 0x0e3f), charForKeysym("Thai_baht").?);
    try std.testing.expectEqual(@as(u21, 0x0e59), charForKeysym("Thai_lekkao").?);
    try std.testing.expectEqual(@as(u21, 0x0e01), charForX11Thai(0x0da1).?);
    try std.testing.expectEqual(@as(u21, 0x0e3f), charForX11Thai(0x0ddf).?);
    try std.testing.expectEqual(@as(u21, 0x0e59), charForX11Thai(0x0df9).?);
    try std.testing.expect(charForX11Thai(0x0ddb) == null);
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
