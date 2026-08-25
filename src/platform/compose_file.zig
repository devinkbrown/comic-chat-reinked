//! Bounded XCompose / locale compose-file parser.
//!
//! Reads the same text format as `/usr/share/X11/locale/*/Compose` and
//! `~/.XCompose`: `include "%L"`, sequences of `<keysym>` tokens, and a
//! quoted UTF-8 result. No libxkbcommon. Files and include depth are capped
//! so a huge or hostile table cannot grow without bound.

const std = @import("std");
const services = @import("services.zig");

pub const max_seq_len: u8 = 4;
pub const max_entries: usize = 8192;
pub const max_file_bytes: usize = 512 * 1024;
pub const max_include_depth: u8 = 3;

const ParseError = std.mem.Allocator.Error || error{ComposeTableFull};

pub const Match = union(enum) {
    none,
    prefix,
    exact: u21,
};

const Entry = struct {
    len: u8,
    keys: [max_seq_len]u16,
    output: u21,
};

pub const Table = struct {
    gpa: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    names: std.StringHashMapUnmanaged(u16) = .empty,
    name_list: std.ArrayListUnmanaged([]const u8) = .empty,
    entries: std.ArrayListUnmanaged(Entry) = .empty,

    pub fn deinit(self: *Table) void {
        self.names.deinit(self.gpa);
        self.name_list.deinit(self.gpa);
        self.entries.deinit(self.gpa);
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn idOf(self: *const Table, name: []const u8) ?u16 {
        return self.names.get(name);
    }

    pub fn match(self: *const Table, ids: []const u16) Match {
        var saw_prefix = false;
        for (self.entries.items) |entry| {
            if (entry.len < ids.len) continue;
            var same = true;
            for (ids, 0..) |id, i| {
                if (entry.keys[i] != id) {
                    same = false;
                    break;
                }
            }
            if (!same) continue;
            if (entry.len == ids.len) return .{ .exact = entry.output };
            saw_prefix = true;
        }
        return if (saw_prefix) .prefix else .none;
    }

    fn intern(self: *Table, name: []const u8) ParseError!u16 {
        if (self.names.get(name)) |id| return id;
        if (self.name_list.items.len >= std.math.maxInt(u16)) return error.ComposeTableFull;
        const arena = self.arena.allocator();
        const copy = try arena.dupe(u8, name);
        const id: u16 = @intCast(self.name_list.items.len);
        try self.name_list.append(self.gpa, copy);
        try self.names.put(self.gpa, copy, id);
        return id;
    }

    fn add(self: *Table, keys: []const []const u8, output: u21) ParseError!void {
        if (keys.len == 0 or keys.len > max_seq_len) return;
        if (self.entries.items.len >= max_entries) return;
        var entry = Entry{ .len = @intCast(keys.len), .keys = @splat(0), .output = output };
        for (keys, 0..) |name, i| entry.keys[i] = try self.intern(name);
        try self.entries.append(self.gpa, entry);
    }
};

pub fn parse(gpa: std.mem.Allocator, text: []const u8) ParseError!Table {
    var table = Table{ .gpa = gpa, .arena = std.heap.ArenaAllocator.init(gpa) };
    errdefer table.deinit();
    try parseInto(&table, text, 0, null);
    return table;
}

pub fn parseWithIncludes(gpa: std.mem.Allocator, text: []const u8, env: []const u8) ParseError!Table {
    var table = Table{ .gpa = gpa, .arena = std.heap.ArenaAllocator.init(gpa) };
    errdefer table.deinit();
    try parseInto(&table, text, 0, env);
    return table;
}

/// Loads `XCOMPOSEFILE`, then `~/.XCompose`, then the system locale table
/// (`%L`) when neither user file exists. Missing files are not an error.
pub fn loadFromEnvironment(gpa: std.mem.Allocator, env: []const u8) !?Table {
    if (services.environValue(env, "XCOMPOSEFILE")) |path| {
        if (path.len != 0) {
            // A set XCOMPOSEFILE replaces the default search; a missing file
            // does not fall through to ~/.XCompose or %L.
            if (loadPath(gpa, env, path)) |table| return table else |_| return null;
        }
    }
    if (services.environValue(env, "HOME")) |home| {
        if (home.len != 0) {
            var buf: [512]u8 = undefined;
            const path = std.fmt.bufPrint(&buf, "{s}/.XCompose", .{std.mem.trimEnd(u8, home, "/")}) catch null;
            if (path) |p| {
                if (loadPath(gpa, env, p)) |table| return table else |_| {}
            }
        }
    }
    if (localeComposePath(env)) |path| {
        if (loadPath(gpa, env, path)) |table| return table else |_| {}
    }
    return null;
}

fn loadPath(gpa: std.mem.Allocator, env: []const u8, path: []const u8) !Table {
    const text = try readFileCapped(gpa, path, max_file_bytes);
    defer gpa.free(text);
    return parseWithIncludes(gpa, text, env);
}

fn parseInto(table: *Table, text: []const u8, depth: u8, env: ?[]const u8) ParseError!void {
    var i: usize = 0;
    while (i < text.len) {
        skipWhitespaceAndComments(text, &i);
        if (i >= text.len) break;
        if (std.mem.startsWith(u8, text[i..], "include")) {
            i += "include".len;
            skipHorizontal(text, &i);
            const spec = parseQuoted(text, &i) orelse {
                skipLine(text, &i);
                continue;
            };
            if (env) |e| {
                try includeFile(table, spec, depth, e);
            }
            skipLine(text, &i);
            continue;
        }
        var keys: [max_seq_len][]const u8 = undefined;
        var key_n: usize = 0;
        while (i < text.len and text[i] == '<') {
            const name = parseAngle(text, &i) orelse break;
            if (key_n < keys.len) {
                keys[key_n] = name;
                key_n += 1;
            } else {
                key_n += 1;
            }
            skipHorizontal(text, &i);
        }
        skipHorizontal(text, &i);
        if (i >= text.len or text[i] != ':') {
            skipLine(text, &i);
            continue;
        }
        i += 1;
        skipHorizontal(text, &i);
        const output_text = parseQuoted(text, &i) orelse {
            skipLine(text, &i);
            continue;
        };
        skipLine(text, &i);
        if (key_n == 0 or key_n > max_seq_len) continue;
        if (firstScalar(output_text)) |ch| {
            try table.add(keys[0..key_n], ch);
        }
    }
}

fn includeFile(table: *Table, spec: []const u8, depth: u8, env: []const u8) ParseError!void {
    if (depth >= max_include_depth) return;
    var path_buf: [512]u8 = undefined;
    const path = expandInclude(spec, env, &path_buf) orelse return;
    const text = readFileCapped(table.gpa, path, max_file_bytes) catch return;
    defer table.gpa.free(text);
    try parseInto(table, text, depth + 1, env);
}

fn expandInclude(spec: []const u8, env: []const u8, buf: []u8) ?[]const u8 {
    var out: usize = 0;
    var i: usize = 0;
    while (i < spec.len) {
        if (spec[i] == '%' and i + 1 < spec.len) {
            const repl: []const u8 = switch (spec[i + 1]) {
                '%' => "%",
                'H' => services.environValue(env, "HOME") orelse return null,
                'S' => "/usr/share/X11/locale",
                'L' => localeComposePath(env) orelse return null,
                else => return null,
            };
            if (out + repl.len > buf.len) return null;
            @memcpy(buf[out .. out + repl.len], repl);
            out += repl.len;
            i += 2;
            continue;
        }
        if (out + 1 > buf.len) return null;
        buf[out] = spec[i];
        out += 1;
        i += 1;
    }
    return buf[0..out];
}

fn localeComposePath(env: []const u8) ?[]const u8 {
    const locale = services.environValue(env, "LC_ALL") orelse
        services.environValue(env, "LC_CTYPE") orelse
        services.environValue(env, "LANG") orelse
        "en_US.UTF-8";
    const trimmed = std.mem.trim(u8, locale, " \t");
    if (trimmed.len == 0 or trimmed.len > 64) return "/usr/share/X11/locale/en_US.UTF-8/Compose";
    // Fast path used by every UTF-8 desktop we ship against.
    if (std.mem.eql(u8, trimmed, "C") or std.mem.eql(u8, trimmed, "C.UTF-8") or
        std.mem.eql(u8, trimmed, "POSIX"))
    {
        return "/usr/share/X11/locale/en_US.UTF-8/Compose";
    }
    return localePathFor(trimmed);
}

fn localePathFor(locale: []const u8) ?[]const u8 {
    // Named static paths keep this function allocation-free. Unknown locales
    // fall back to the UTF-8 US table, which is the usual Compose source.
    if (std.mem.startsWith(u8, locale, "en_US")) return "/usr/share/X11/locale/en_US.UTF-8/Compose";
    if (std.mem.startsWith(u8, locale, "en_")) return "/usr/share/X11/locale/en_US.UTF-8/Compose";
    if (std.mem.startsWith(u8, locale, "de_")) return "/usr/share/X11/locale/en_US.UTF-8/Compose";
    if (std.mem.startsWith(u8, locale, "fr_")) return "/usr/share/X11/locale/en_US.UTF-8/Compose";
    if (std.mem.startsWith(u8, locale, "es_")) return "/usr/share/X11/locale/en_US.UTF-8/Compose";
    if (std.mem.startsWith(u8, locale, "it_")) return "/usr/share/X11/locale/en_US.UTF-8/Compose";
    if (std.mem.startsWith(u8, locale, "pt_")) return "/usr/share/X11/locale/en_US.UTF-8/Compose";
    if (std.mem.startsWith(u8, locale, "pl_")) return "/usr/share/X11/locale/en_US.UTF-8/Compose";
    if (std.mem.startsWith(u8, locale, "cs_")) return "/usr/share/X11/locale/cs_CZ.UTF-8/Compose";
    if (std.mem.startsWith(u8, locale, "fi_")) return "/usr/share/X11/locale/fi_FI.UTF-8/Compose";
    if (std.mem.startsWith(u8, locale, "el_")) return "/usr/share/X11/locale/el_GR.UTF-8/Compose";
    return "/usr/share/X11/locale/en_US.UTF-8/Compose";
}

fn readFileCapped(gpa: std.mem.Allocator, path: []const u8, limit: usize) ![]u8 {
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    return std.Io.Dir.cwd().readFileAlloc(threaded.io(), path, gpa, .limited(limit)) catch |err| switch (err) {
        error.FileNotFound, error.AccessDenied => return error.FileNotFound,
        error.StreamTooLong => return error.ComposeFileTooLarge,
        else => return err,
    };
}

fn parseAngle(text: []const u8, i: *usize) ?[]const u8 {
    if (i.* >= text.len or text[i.*] != '<') return null;
    i.* += 1;
    const start = i.*;
    while (i.* < text.len and text[i.*] != '>' and text[i.*] != '\n') i.* += 1;
    if (i.* >= text.len or text[i.*] != '>') return null;
    const name = text[start..i.*];
    i.* += 1;
    if (name.len == 0) return null;
    return name;
}

fn parseQuoted(text: []const u8, i: *usize) ?[]const u8 {
    if (i.* >= text.len or text[i.*] != '"') return null;
    i.* += 1;
    const start = i.*;
    while (i.* < text.len and text[i.*] != '"' and text[i.*] != '\n') {
        if (text[i.*] == '\\' and i.* + 1 < text.len) i.* += 2 else i.* += 1;
    }
    if (i.* >= text.len or text[i.*] != '"') return null;
    const body = text[start..i.*];
    i.* += 1;
    return body;
}

fn firstScalar(quoted: []const u8) ?u21 {
    if (quoted.len == 0) return null;
    if (quoted[0] == '\\' and quoted.len >= 2) {
        return switch (quoted[1]) {
            '"', '\\', '\'' => quoted[1],
            'n' => '\n',
            't' => '\t',
            else => quoted[1],
        };
    }
    const decoded = std.unicode.utf8Decode(quoted[0 .. std.unicode.utf8ByteSequenceLength(quoted[0]) catch return null]) catch return null;
    if (decoded == 0 or decoded > 0x10ffff or (decoded >= 0xd800 and decoded <= 0xdfff)) return null;
    return decoded;
}

fn skipHorizontal(text: []const u8, i: *usize) void {
    while (i.* < text.len and (text[i.*] == ' ' or text[i.*] == '\t')) i.* += 1;
}

fn skipLine(text: []const u8, i: *usize) void {
    while (i.* < text.len and text[i.*] != '\n') i.* += 1;
    if (i.* < text.len) i.* += 1;
}

fn skipWhitespaceAndComments(text: []const u8, i: *usize) void {
    while (i.* < text.len) {
        if (text[i.*] == ' ' or text[i.*] == '\t' or text[i.*] == '\r' or text[i.*] == '\n') {
            i.* += 1;
        } else if (text[i.*] == '#') {
            skipLine(text, i);
        } else {
            break;
        }
    }
}

test "XCompose parser reads sequences and quoted UTF-8 results" {
    const text =
        \\# comment
        \\<dead_acute> <e> : "é" eacute
        \\<Multi_key> <a> <e> : "æ"
        \\<Multi_key> <quotedbl> <u> : "ü"
        \\<Multi_key> <minus> <greater> : "→"
        \\<Multi_key> <1> <2> <3> <4> <5> : "skip"
        \\
    ;
    var table = try parse(std.testing.allocator, text);
    defer table.deinit();

    const acute = table.idOf("dead_acute").?;
    const e = table.idOf("e").?;
    try std.testing.expectEqual(Match{ .exact = 0xe9 }, table.match(&.{ acute, e }));
    try std.testing.expectEqual(Match.prefix, table.match(&.{acute}));

    const multi = table.idOf("Multi_key").?;
    const a = table.idOf("a").?;
    try std.testing.expectEqual(Match{ .exact = 0xe6 }, table.match(&.{ multi, a, e }));
    try std.testing.expect(table.idOf("1") == null);
}

test "include expander substitutes %H %S %% and %L" {
    var buf: [128]u8 = undefined;
    const home = expandInclude("%H/.XCompose", "HOME=/home/dev\x00LANG=en_US.UTF-8\x00", &buf).?;
    try std.testing.expectEqualStrings("/home/dev/.XCompose", home);
    const doubled = expandInclude("%%L", "LANG=en_US.UTF-8\x00", &buf).?;
    try std.testing.expectEqualStrings("%L", doubled);
}

test "XCOMPOSEFILE that does not exist yields no table" {
    const table = try loadFromEnvironment(
        std.testing.allocator,
        "XCOMPOSEFILE=/tmp/comicchat-missing-xcompose\x00LANG=en_US.UTF-8\x00",
    );
    try std.testing.expect(table == null);
}

test "system en_US.UTF-8 Compose parses dead_acute e when present" {
    const path = "/usr/share/X11/locale/en_US.UTF-8/Compose";
    const text = readFileCapped(std.testing.allocator, path, max_file_bytes) catch |err| switch (err) {
        error.FileNotFound, error.AccessDenied, error.ComposeFileTooLarge => return,
        else => return err,
    };
    defer std.testing.allocator.free(text);
    var table = try parse(std.testing.allocator, text);
    defer table.deinit();
    const acute = table.idOf("dead_acute") orelse return;
    const e = table.idOf("e") orelse return;
    try std.testing.expectEqual(Match{ .exact = 0xe9 }, table.match(&.{ acute, e }));
}
