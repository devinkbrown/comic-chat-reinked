//! Small native desktop-service bridge for pure-Zig Unix builds.
//!
//! The window backends remain direct protocol implementations and now own the
//! primary clipboard path. These helpers are the fallback when a compositor or
//! X server cannot complete the native transfer (including `wl-paste --primary`
//! / `xclip -selection primary` when PRIMARY is missing), plus notifications
//! (`notify-send --urgency=normal --icon=applications-internet`), file selection, document opening, and
//! printing. `xdg-open` can carry an outgoing activation / startup token.
//! Incoming desktop file-list MIME, receive-only RTF, and receive-only
//! COMPOUND_TEXT are parsed here. Every call is
//! bounded and failure is non-fatal, so minimal installations retain the
//! internal application fallback.

const std = @import("std");
const linux = std.os.linux;

const max_clipboard_bytes = 1024 * 1024;
const max_service_output = 1024 * 1024;

pub const Desktop = enum { x11, wayland };

/// Reads `/proc/self/environ` so Linux backends can inspect DISPLAY,
/// WAYLAND_DISPLAY, XAUTHORITY, and toolkit scale variables without libc.
pub fn readEnviron(gpa: std.mem.Allocator) ![]u8 {
    const fd = try openReadOnly("/proc/self/environ");
    defer _ = linux.close(fd);

    var env: std.ArrayList(u8) = .empty;
    errdefer env.deinit(gpa);
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = try readSomeFd(fd, &buf);
        if (n == 0) break;
        try env.appendSlice(gpa, buf[0..n]);
    }
    return env.toOwnedSlice(gpa);
}

/// Desktop startup token used to take focus after a launcher/file-manager open.
/// `XDG_ACTIVATION_TOKEN` wins; `DESKTOP_STARTUP_ID` is the older X11 name.
/// NUL-terminated `remove: ID=<token>` body for X11 `_NET_STARTUP_INFO`.
/// Spaces and backslashes in the token are escaped with a leading `\`.
pub fn startupRemoveMessage(token: []const u8, buf: []u8) ?[]const u8 {
    const prefix = "remove: ID=";
    if (prefix.len >= buf.len) return null;
    @memcpy(buf[0..prefix.len], prefix);
    var n: usize = prefix.len;
    for (token) |c| {
        if ((c == ' ' or c == '\\') and n + 1 >= buf.len) return null;
        if (c == ' ' or c == '\\') {
            buf[n] = '\\';
            n += 1;
        }
        if (n + 1 >= buf.len) return null;
        buf[n] = c;
        n += 1;
    }
    if (n >= buf.len) return null;
    buf[n] = 0;
    return buf[0 .. n + 1];
}

pub fn startupToken(env: []const u8) ?[]const u8 {
    if (environValue(env, "XDG_ACTIVATION_TOKEN")) |token| {
        if (token.len != 0) return token;
    }
    if (environValue(env, "DESKTOP_STARTUP_ID")) |token| {
        if (token.len != 0) return token;
    }
    return null;
}

pub fn environValue(env: []const u8, name: []const u8) ?[]const u8 {
    var start: usize = 0;
    while (start < env.len) {
        const rest = env[start..];
        const item_len = std.mem.indexOfScalar(u8, rest, 0) orelse rest.len;
        const item = rest[0..item_len];
        if (item.len > name.len and item[name.len] == '=' and std.mem.eql(u8, item[0..name.len], name)) {
            return item[name.len + 1 ..];
        }
        start += item_len + 1;
    }
    return null;
}

/// Integer framebuffer scale from toolkit environment variables.
/// `GDK_SCALE` / `QT_SCALE_FACTOR` win because XWayland often leaves `Xft.dpi`
/// at 96 while the desktop is already 2×.
pub fn scaleFromEnvironment(env: []const u8) ?u32 {
    if (gdkScaleProduct(env)) |scale| return scale;
    if (environValue(env, "QT_SCALE_FACTOR")) |value| {
        if (parsePositiveScale(value)) |scale| return scale;
    }
    if (environValue(env, "QT_SCREEN_SCALE_FACTORS")) |value| {
        if (parseQtScreenScale(value)) |scale| return scale;
    }
    return null;
}

fn gdkScaleProduct(env: []const u8) ?u32 {
    const gdk = environValue(env, "GDK_SCALE");
    const dpi = environValue(env, "GDK_DPI_SCALE");
    if (gdk == null and dpi == null) return null;
    var product: f32 = 1;
    var any = false;
    if (gdk) |value| {
        if (parseScaleFactor(value, 1, 8)) |scale| {
            product *= scale;
            any = true;
        }
    }
    if (dpi) |value| {
        if (parseScaleFactor(value, 0.25, 8)) |scale| {
            product *= scale;
            any = true;
        }
    }
    if (!any) return null;
    return clampScale(product);
}

fn parseQtScreenScale(value: []const u8) ?u32 {
    var rest = std.mem.trim(u8, value, " \t");
    if (std.mem.indexOfScalar(u8, rest, ';')) |semi| rest = rest[0..semi];
    if (std.mem.lastIndexOfScalar(u8, rest, '=')) |eq| rest = rest[eq + 1 ..];
    return parsePositiveScale(rest);
}

fn parseScaleFactor(value: []const u8, min: f32, max: f32) ?f32 {
    const trimmed = std.mem.trim(u8, value, " \t");
    if (trimmed.len == 0) return null;
    if (std.fmt.parseInt(u32, trimmed, 10)) |scale| {
        const as_float: f32 = @floatFromInt(scale);
        if (as_float < min or as_float > max) return null;
        return as_float;
    } else |_| {}
    const parsed = std.fmt.parseFloat(f32, trimmed) catch return null;
    if (parsed < min or parsed > max) return null;
    return parsed;
}

fn clampScale(value: f32) ?u32 {
    if (value < 1 or value > 8) return null;
    const rounded: u32 = @intFromFloat(@round(value));
    if (rounded < 1 or rounded > 8) return null;
    return rounded;
}

pub fn scaleFromDpi(dpi: u32) u32 {
    if (dpi < 1) return 1;
    const rounded = (dpi + 48) / 96;
    return @min(8, @max(1, rounded));
}

/// Integer scale from an X11 screen's pixel width and reported millimeter
/// width. Ignores missing, ~96dpi, and implausible sizes so a bogus 1mm
/// width cannot jump the framebuffer to 8×.
pub fn scaleFromScreenMm(width_px: u32, width_mm: u32) ?u32 {
    if (width_px == 0 or width_mm == 0) return null;
    const dpi = (width_px * 254) / (width_mm * 10);
    if (dpi < 144 or dpi > 480) return null;
    return scaleFromDpi(dpi);
}

/// First usable payload from a drop: a `file:` URI or desktop file-list
/// becomes a local path, otherwise the first non-empty line is text.
pub fn firstDropText(text: []const u8, buf: []u8) ?[]const u8 {
    if (firstPathFromDesktopFiles(text, buf)) |path| return path;
    if (firstPathFromUriList(text, buf)) |path| return path;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const n = @min(line.len, buf.len);
        if (n == 0) return null;
        @memcpy(buf[0..n], line[0..n]);
        return buf[0..n];
    }
    return null;
}

/// Receive-only desktop file-list MIME (Nautilus, Firefox). Not offered on copy.
pub fn isDesktopFileMime(mime: []const u8) bool {
    return std.ascii.eqlIgnoreCase(mime, "x-special/gnome-copied-files") or
        std.ascii.eqlIgnoreCase(mime, "x-special/nautilus-clipboard") or
        std.ascii.eqlIgnoreCase(mime, "text/x-moz-url") or
        std.ascii.eqlIgnoreCase(mime, "application/x-moz-file") or
        std.ascii.eqlIgnoreCase(mime, "application/x-kde4-urilist") or
        std.ascii.eqlIgnoreCase(mime, "application/x-kde5-urilist") or
        std.ascii.eqlIgnoreCase(mime, "text/x-moz-url-priv");
}

/// Receive-only ICCCM `COMPOUND_TEXT` (xterm/Emacs). Not advertised on copy.
pub fn isCompoundTextMime(mime: []const u8) bool {
    return mimeTypeEquals(mime, "COMPOUND_TEXT");
}

/// Receive-only URI list MIME, including the `text/x-uri-list` alias.
pub fn isUriListMime(mime: []const u8) bool {
    return mimeTypeEquals(mime, "text/uri-list") or mimeTypeEquals(mime, "text/x-uri-list");
}

/// Receive-only RTF. Not advertised on copy.
pub fn isRtfMime(mime: []const u8) bool {
    return mimeTypeEquals(mime, "text/rtf") or mimeTypeEquals(mime, "application/rtf");
}

fn mimeTypeEquals(mime: []const u8, prefix: []const u8) bool {
    if (mime.len < prefix.len) return false;
    if (!std.ascii.eqlIgnoreCase(mime[0..prefix.len], prefix)) return false;
    return mime.len == prefix.len or mime[prefix.len] == ';';
}

/// First local path from `x-special/gnome-copied-files`, `text/x-moz-url`,
/// a bare absolute path, or a `text/uri-list` body.
pub fn firstPathFromDesktopFiles(text: []const u8, buf: []u8) ?[]const u8 {
    var rest = text;
    if (std.mem.indexOfScalar(u8, rest, '\n')) |nl| {
        const head = std.mem.trim(u8, rest[0..nl], " \t\r");
        if (std.ascii.eqlIgnoreCase(head, "copy") or
            std.ascii.eqlIgnoreCase(head, "cut") or
            std.ascii.eqlIgnoreCase(head, "link"))
        {
            rest = rest[nl + 1 ..];
        }
    }
    if (firstPathFromUriList(rest, buf)) |path| return path;
    var lines = std.mem.splitScalar(u8, rest, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (line[0] != '/') continue;
        const n = @min(line.len, buf.len);
        if (n == 0) return null;
        @memcpy(buf[0..n], line[0..n]);
        return buf[0..n];
    }
    return null;
}

/// First `file:` path in a `text/uri-list` body. Other schemes are skipped.
pub fn firstPathFromUriList(text: []const u8, buf: []u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (!std.mem.startsWith(u8, line, "file:")) continue;
        return fileUrlToPath(line, buf);
    }
    return null;
}

fn fileUrlToPath(url: []const u8, buf: []u8) ?[]const u8 {
    var rest = url["file:".len..];
    if (std.mem.startsWith(u8, rest, "//")) {
        rest = rest[2..];
        if (std.mem.startsWith(u8, rest, "localhost")) {
            rest = rest["localhost".len..];
        } else if (rest.len != 0 and rest[0] != '/') {
            return null;
        }
    }
    if (std.mem.indexOfScalar(u8, rest, '?')) |q| rest = rest[0..q];
    if (std.mem.indexOfScalar(u8, rest, '#')) |h| rest = rest[0..h];
    if (rest.len == 0) return null;
    return percentDecode(rest, buf);
}

/// True for `text/html` and `text/html;charset=...` (receive-only MIME).
pub fn isHtmlMime(mime: []const u8) bool {
    return mimeTypeEquals(mime, "text/html");
}

/// Last-resort clipboard/drop payload: strip a bounded RTF document to text.
/// Groups such as font/color tables and pictures are skipped. `\uN` and `\'hh`
/// become Unicode / Latin-1 characters.
pub fn rtfToPlainText(gpa: std.mem.Allocator, rtf: []const u8) ![]u8 {
    const start = std.mem.indexOf(u8, rtf, "{\\rtf") orelse {
        return normalizeClipboardNewlinesOwned(gpa, try gpa.dupe(u8, rtf));
    };
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = start;
    var skip_depth: u8 = 0;
    var group_depth: u8 = 0;
    while (i < rtf.len) {
        const c = rtf[i];
        if (c == '{') {
            group_depth +|= 1;
            i += 1;
            if (skip_depth != 0) {
                skip_depth +|= 1;
                continue;
            }
            if (rtfDestinationIsSkip(rtf[i..])) {
                skip_depth = 1;
            }
            continue;
        }
        if (c == '}') {
            if (group_depth != 0) group_depth -= 1;
            if (skip_depth != 0) skip_depth -= 1;
            i += 1;
            continue;
        }
        if (c == '\\') {
            const parsed = parseRtfControl(rtf[i..]);
            i += parsed.consumed;
            if (skip_depth != 0) continue;
            switch (parsed.kind) {
                .literal => try out.append(gpa, parsed.literal),
                .newline => {
                    if (out.items.len != 0 and out.items[out.items.len - 1] != '\n') try out.append(gpa, '\n');
                },
                .tab => try out.append(gpa, '\t'),
                .hex => try out.append(gpa, parsed.literal),
                .unicode => {
                    var encoded: [4]u8 = undefined;
                    const n = std.unicode.utf8Encode(parsed.codepoint, &encoded) catch continue;
                    try out.appendSlice(gpa, encoded[0..n]);
                    if (i < rtf.len and rtf[i] != '\\' and rtf[i] != '{' and rtf[i] != '}') i += 1;
                },
                .skip => {},
            }
            continue;
        }
        if (c == '\r' or c == '\n') {
            i += 1;
            continue;
        }
        if (skip_depth == 0) try out.append(gpa, c);
        i += 1;
    }
    return normalizeClipboardNewlinesOwned(gpa, try out.toOwnedSlice(gpa));
}

const RtfControl = struct {
    kind: enum { literal, newline, tab, hex, unicode, skip },
    literal: u8 = 0,
    codepoint: u21 = 0,
    consumed: usize,
};

fn parseRtfControl(text: []const u8) RtfControl {
    if (text.len < 2) return .{ .kind = .skip, .consumed = text.len };
    const next = text[1];
    if (next == '\\' or next == '{' or next == '}') return .{ .kind = .literal, .literal = next, .consumed = 2 };
    if (next == '\'') {
        if (text.len < 4) return .{ .kind = .skip, .consumed = text.len };
        const hi = hexNibble(text[2]) orelse return .{ .kind = .skip, .consumed = 2 };
        const lo = hexNibble(text[3]) orelse return .{ .kind = .skip, .consumed = 2 };
        return .{ .kind = .hex, .literal = @intCast((hi << 4) | lo), .consumed = 4 };
    }
    if (next == '~') return .{ .kind = .literal, .literal = ' ', .consumed = 2 };
    if (next == '-' or next == '_') return .{ .kind = .literal, .literal = '-', .consumed = 2 };
    var i: usize = 1;
    while (i < text.len and std.ascii.isAlphabetic(text[i])) : (i += 1) {}
    const name = text[1..i];
    var signed: i32 = 0;
    var have_num = false;
    if (i < text.len and (text[i] == '-' or std.ascii.isDigit(text[i]))) {
        have_num = true;
        var neg = false;
        if (text[i] == '-') {
            neg = true;
            i += 1;
        }
        var value: i32 = 0;
        while (i < text.len and std.ascii.isDigit(text[i])) : (i += 1) {
            value = value * 10 + @as(i32, text[i] - '0');
        }
        signed = if (neg) -value else value;
    }
    if (i < text.len and text[i] == ' ') i += 1;
    if (std.ascii.eqlIgnoreCase(name, "par") or std.ascii.eqlIgnoreCase(name, "line") or
        std.ascii.eqlIgnoreCase(name, "page"))
    {
        return .{ .kind = .newline, .consumed = i };
    }
    if (std.ascii.eqlIgnoreCase(name, "tab")) return .{ .kind = .tab, .consumed = i };
    if (std.ascii.eqlIgnoreCase(name, "u") and have_num) {
        const raw: i32 = if (signed < 0) signed + 65536 else signed;
        const code: u21 = if (raw >= 0 and raw <= 0x10ffff) @intCast(raw) else 0xfffd;
        return .{ .kind = .unicode, .codepoint = code, .consumed = i };
    }
    return .{ .kind = .skip, .consumed = i };
}

fn rtfDestinationIsSkip(rest: []const u8) bool {
    var i: usize = 0;
    while (i < rest.len and (rest[i] == ' ' or rest[i] == '\r' or rest[i] == '\n')) : (i += 1) {}
    if (i >= rest.len or rest[i] != '\\') return false;
    if (i + 1 < rest.len and rest[i + 1] == '*') return true;
    i += 1;
    var end = i;
    while (end < rest.len and std.ascii.isAlphabetic(rest[end])) : (end += 1) {}
    const name = rest[i..end];
    return std.ascii.eqlIgnoreCase(name, "fonttbl") or
        std.ascii.eqlIgnoreCase(name, "colortbl") or
        std.ascii.eqlIgnoreCase(name, "stylesheet") or
        std.ascii.eqlIgnoreCase(name, "info") or
        std.ascii.eqlIgnoreCase(name, "pict") or
        std.ascii.eqlIgnoreCase(name, "header") or
        std.ascii.eqlIgnoreCase(name, "footer") or
        std.ascii.eqlIgnoreCase(name, "object");
}

/// Last-resort clipboard/drop payload: strip tags from `text/html`.
/// Leaves already-plain text unchanged. Script/style bodies are dropped.
pub fn htmlToPlainText(gpa: std.mem.Allocator, html: []const u8) ![]u8 {
    if (std.mem.indexOfScalar(u8, html, '<') == null and std.mem.indexOfScalar(u8, html, '&') == null) {
        return normalizeClipboardNewlinesOwned(gpa, try gpa.dupe(u8, html));
    }
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    var skip_depth: u8 = 0;
    while (i < html.len) {
        if (html[i] == '<') {
            const end = std.mem.indexOfScalarPos(u8, html, i + 1, '>') orelse break;
            const raw = html[i + 1 .. end];
            const closing = raw.len != 0 and raw[0] == '/';
            const inner = std.mem.trim(u8, raw, " \t\r\n/");
            var name = inner;
            if (std.mem.indexOfAny(u8, inner, " \t\r\n")) |sp| name = inner[0..sp];
            if (isHtmlBreak(name)) {
                if (skip_depth == 0 and !closing and out.items.len != 0) try out.append(gpa, '\n');
            } else if (isHtmlSkip(name)) {
                if (!closing) {
                    skip_depth +|= 1;
                } else if (skip_depth != 0) {
                    skip_depth -= 1;
                }
            }
            i = end + 1;
            continue;
        }
        if (skip_depth != 0) {
            i += 1;
            continue;
        }
        if (html[i] == '&') {
            const decoded = decodeHtmlEntity(html[i..]);
            try out.appendSlice(gpa, decoded.bytes[0..decoded.len]);
            i += decoded.consumed;
            continue;
        }
        try out.append(gpa, html[i]);
        i += 1;
    }
    return normalizeClipboardNewlinesOwned(gpa, try out.toOwnedSlice(gpa));
}

fn isHtmlBreak(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, "br") or
        std.ascii.eqlIgnoreCase(name, "p") or
        std.ascii.eqlIgnoreCase(name, "div") or
        std.ascii.eqlIgnoreCase(name, "tr") or
        std.ascii.eqlIgnoreCase(name, "li");
}

fn isHtmlSkip(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, "script") or std.ascii.eqlIgnoreCase(name, "style");
}

fn decodeHtmlEntity(text: []const u8) struct { bytes: [4]u8, len: u8, consumed: usize } {
    if (text.len >= 5 and std.mem.startsWith(u8, text, "&amp;")) return .{ .bytes = "&\x00\x00\x00".*, .len = 1, .consumed = 5 };
    if (text.len >= 4 and std.mem.startsWith(u8, text, "&lt;")) return .{ .bytes = "<\x00\x00\x00".*, .len = 1, .consumed = 4 };
    if (text.len >= 4 and std.mem.startsWith(u8, text, "&gt;")) return .{ .bytes = ">\x00\x00\x00".*, .len = 1, .consumed = 4 };
    if (text.len >= 6 and std.mem.startsWith(u8, text, "&nbsp;")) return .{ .bytes = " \x00\x00\x00".*, .len = 1, .consumed = 6 };
    if (text.len >= 4 and text[1] == '#') {
        const semi = std.mem.indexOfScalarPos(u8, text, 2, ';') orelse return .{ .bytes = "&\x00\x00\x00".*, .len = 1, .consumed = 1 };
        const digits = text[2..semi];
        const value = if (digits.len != 0 and (digits[0] == 'x' or digits[0] == 'X'))
            std.fmt.parseInt(u21, digits[1..], 16) catch return .{ .bytes = "&\x00\x00\x00".*, .len = 1, .consumed = 1 }
        else
            std.fmt.parseInt(u21, digits, 10) catch return .{ .bytes = "&\x00\x00\x00".*, .len = 1, .consumed = 1 };
        var encoded: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(value, &encoded) catch return .{ .bytes = "&\x00\x00\x00".*, .len = 1, .consumed = 1 };
        var bytes: [4]u8 = @splat(0);
        @memcpy(bytes[0..n], encoded[0..n]);
        return .{ .bytes = bytes, .len = @intCast(n), .consumed = semi + 1 };
    }
    return .{ .bytes = "&\x00\x00\x00".*, .len = 1, .consumed = 1 };
}

/// Clipboard bytes to UTF-8: strip a UTF-8 BOM or decode UTF-16 with BOM.
pub fn clipboardBytesToUtf8(gpa: std.mem.Allocator, bytes: []const u8) ![]u8 {
    if (std.mem.startsWith(u8, bytes, "\xEF\xBB\xBF")) {
        return normalizeClipboardNewlinesOwned(gpa, try gpa.dupe(u8, bytes[3..]));
    }
    if (bytes.len >= 2 and bytes.len % 2 == 0) {
        if (std.mem.startsWith(u8, bytes, "\xFF\xFE")) {
            return normalizeClipboardNewlinesOwned(gpa, try utf16ToUtf8(gpa, bytes[2..], .little));
        }
        if (std.mem.startsWith(u8, bytes, "\xFE\xFF")) {
            return normalizeClipboardNewlinesOwned(gpa, try utf16ToUtf8(gpa, bytes[2..], .big));
        }
    }
    return normalizeClipboardNewlinesOwned(gpa, try gpa.dupe(u8, bytes));
}

/// Receive-only ICCCM COMPOUND_TEXT. Default charset is ISO-8859-1. `ESC % G`
/// / `ESC %/G` switch to UTF-8; `ESC ( B` is ASCII; unknown 94^n sets are
/// skipped until the next ESC. A body with no ESC that is already valid
/// UTF-8 is kept as UTF-8.
pub fn compoundTextToUtf8(gpa: std.mem.Allocator, bytes: []const u8) ![]u8 {
    if (std.mem.indexOfScalar(u8, bytes, 0x1b) == null) {
        if (std.unicode.utf8ValidateSlice(bytes)) {
            return normalizeClipboardNewlinesOwned(gpa, try gpa.dupe(u8, bytes));
        }
        return latin1ToUtf8(gpa, bytes);
    }
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var cset: CompoundCharset = .latin1;
    var i: usize = 0;
    while (i < bytes.len) {
        if (bytes[i] == 0x1b) {
            const esc = parseCompoundEscape(bytes[i..]);
            i += esc.consumed;
            if (esc.skip) {
                while (i < bytes.len and bytes[i] != 0x1b) : (i += 1) {}
            } else {
                cset = esc.cset;
            }
            continue;
        }
        switch (cset) {
            .ascii => {
                if (bytes[i] < 0x80) try out.append(gpa, bytes[i]);
                i += 1;
            },
            .latin1 => {
                try appendLatin1(&out, gpa, bytes[i]);
                i += 1;
            },
            .utf8 => {
                const n = std.unicode.utf8ByteSequenceLength(bytes[i]) catch 1;
                if (i + n <= bytes.len and std.unicode.utf8ValidateSlice(bytes[i .. i + n])) {
                    try out.appendSlice(gpa, bytes[i .. i + n]);
                    i += n;
                } else {
                    try out.append(gpa, '?');
                    i += 1;
                }
            },
        }
    }
    return normalizeClipboardNewlinesOwned(gpa, try out.toOwnedSlice(gpa));
}

const CompoundCharset = enum { latin1, utf8, ascii };

const CompoundEscape = struct {
    consumed: usize,
    cset: CompoundCharset,
    skip: bool,
};

fn parseCompoundEscape(text: []const u8) CompoundEscape {
    if (text.len < 2) return .{ .consumed = 1, .cset = .latin1, .skip = false };
    if (text.len >= 3 and text[1] == '%' and text[2] == 'G') {
        return .{ .consumed = 3, .cset = .utf8, .skip = false };
    }
    if (text.len >= 4 and text[1] == '%' and text[2] == '/' and text[3] == 'G') {
        return .{ .consumed = 4, .cset = .utf8, .skip = false };
    }
    if (text[1] == '(' or text[1] == ')') {
        if (text.len < 3) return .{ .consumed = 2, .cset = .ascii, .skip = false };
        if (text[2] == 'B' or text[2] == 'J' or text[2] == '0') {
            return .{ .consumed = 3, .cset = .ascii, .skip = false };
        }
        return .{ .consumed = 3, .cset = .latin1, .skip = false };
    }
    if (text[1] == '-' and text.len >= 3) {
        return .{ .consumed = 3, .cset = .latin1, .skip = false };
    }
    if (text[1] == '$') {
        var n: usize = 2;
        if (n < text.len and (text[n] == '(' or text[n] == ')' or text[n] == '-' or text[n] == '.')) n += 1;
        if (n < text.len) n += 1;
        return .{ .consumed = n, .cset = .latin1, .skip = true };
    }
    return .{ .consumed = 2, .cset = .latin1, .skip = false };
}

fn latin1ToUtf8(gpa: std.mem.Allocator, bytes: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (bytes) |c| try appendLatin1(&out, gpa, c);
    return normalizeClipboardNewlinesOwned(gpa, try out.toOwnedSlice(gpa));
}

fn appendLatin1(out: *std.ArrayList(u8), gpa: std.mem.Allocator, c: u8) !void {
    if (c < 0x80) {
        try out.append(gpa, c);
        return;
    }
    var buf: [2]u8 = undefined;
    const n = std.unicode.utf8Encode(c, &buf) catch {
        try out.append(gpa, '?');
        return;
    };
    try out.appendSlice(gpa, buf[0..n]);
}

/// Decode `UTF16_STRING` / UTF-16 clipboard bytes. Honors a BOM when present,
/// otherwise assumes little-endian (the usual X11/Windows convention).
pub fn clipboardUtf16BytesToUtf8(gpa: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const decoded = blk: {
        if (bytes.len >= 2) {
            if (std.mem.startsWith(u8, bytes, "\xFF\xFE")) {
                break :blk try utf16ToUtf8(gpa, bytes[2..], .little);
            }
            if (std.mem.startsWith(u8, bytes, "\xFE\xFF")) {
                break :blk try utf16ToUtf8(gpa, bytes[2..], .big);
            }
        }
        break :blk try utf16ToUtf8(gpa, bytes, .little);
    };
    return normalizeClipboardNewlinesOwned(gpa, decoded);
}

/// Collapse CR/LF and lone CR to LF so Windows and some GTK pastes match Unix.
pub fn normalizeClipboardNewlines(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    if (std.mem.indexOfScalar(u8, text, '\r') == null) return gpa.dupe(u8, text);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == '\r') {
            try out.append(gpa, '\n');
            if (i + 1 < text.len and text[i + 1] == '\n') {
                i += 2;
            } else {
                i += 1;
            }
            continue;
        }
        try out.append(gpa, text[i]);
        i += 1;
    }
    return out.toOwnedSlice(gpa);
}

fn normalizeClipboardNewlinesOwned(gpa: std.mem.Allocator, owned: []u8) ![]u8 {
    if (std.mem.indexOfScalar(u8, owned, '\r') == null) return owned;
    const next = try normalizeClipboardNewlines(gpa, owned);
    gpa.free(owned);
    return next;
}

fn utf16ToUtf8(gpa: std.mem.Allocator, bytes: []const u8, endian: std.builtin.Endian) ![]u8 {
    if (bytes.len % 2 != 0) return error.TruncatedUtf16;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    while (i + 1 < bytes.len) {
        const unit = std.mem.readInt(u16, bytes[i..][0..2], endian);
        i += 2;
        var codepoint: u21 = unit;
        if (unit >= 0xD800 and unit <= 0xDBFF) {
            if (i + 1 >= bytes.len) return error.TruncatedUtf16;
            const low = std.mem.readInt(u16, bytes[i..][0..2], endian);
            i += 2;
            if (low < 0xDC00 or low > 0xDFFF) return error.InvalidUtf16;
            codepoint = 0x10000 + (((@as(u21, unit) - 0xD800) << 10) | (low - 0xDC00));
        } else if (unit >= 0xDC00 and unit <= 0xDFFF) {
            return error.InvalidUtf16;
        }
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(codepoint, &buf) catch return error.InvalidUtf16;
        try out.appendSlice(gpa, buf[0..n]);
    }
    return out.toOwnedSlice(gpa);
}

fn percentDecode(src: []const u8, buf: []u8) ?[]const u8 {
    var out: usize = 0;
    var i: usize = 0;
    while (i < src.len) {
        if (out >= buf.len) return null;
        if (src[i] == '%' and i + 2 < src.len) {
            const hi = hexNibble(src[i + 1]) orelse return null;
            const lo = hexNibble(src[i + 2]) orelse return null;
            buf[out] = (hi << 4) | lo;
            out += 1;
            i += 3;
            continue;
        }
        buf[out] = if (src[i] == '+') ' ' else src[i];
        out += 1;
        i += 1;
    }
    return buf[0..out];
}

fn hexNibble(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

/// Integer framebuffer scale from an XSETTINGS blob (`_XSETTINGS_SETTINGS`).
/// Prefers `Gdk/WindowScalingFactor`, then `Xft/DPI` (1024ths of a point).
pub fn parseXsettingsScale(bytes: []const u8) ?u32 {
    const parsed = parseXsettings(bytes) orelse return null;
    if (parsed.gdk_scale) |scale| return scale;
    if (parsed.xft_dpi) |dpi| return scaleFromDpi(dpi);
    return null;
}

const XsettingsValues = struct {
    gdk_scale: ?u32 = null,
    xft_dpi: ?u32 = null,
};

fn parseXsettings(bytes: []const u8) ?XsettingsValues {
    if (bytes.len < 12) return null;
    const order = bytes[0];
    if (order != 'l' and order != 'B') return null;
    const count = xsettingsGet32(order, bytes[8..12]) orelse return null;
    var off: usize = 12;
    var values = XsettingsValues{};
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        if (off + 4 > bytes.len) return null;
        const typ = bytes[off];
        const name_len = xsettingsGet16(order, bytes[off + 2 .. off + 4]) orelse return null;
        off += 4;
        if (off + name_len > bytes.len) return null;
        const name = bytes[off .. off + name_len];
        off += name_len;
        off = std.mem.alignForward(usize, off, 4);
        if (off + 4 > bytes.len) return null;
        off += 4; // last-change-serial
        switch (typ) {
            0 => { // integer
                if (off + 4 > bytes.len) return null;
                const raw = xsettingsGet32(order, bytes[off .. off + 4]) orelse return null;
                off += 4;
                if (std.mem.eql(u8, name, "Gdk/WindowScalingFactor")) {
                    if (raw >= 1 and raw <= 8) values.gdk_scale = raw;
                } else if (std.mem.eql(u8, name, "Xft/DPI")) {
                    const dpi = raw / 1024;
                    if (dpi >= 1 and dpi <= 768) values.xft_dpi = dpi;
                }
            },
            1 => { // string
                if (off + 4 > bytes.len) return null;
                const str_len = xsettingsGet32(order, bytes[off .. off + 4]) orelse return null;
                off += 4;
                if (off + str_len > bytes.len) return null;
                off += str_len;
                off = std.mem.alignForward(usize, off, 4);
            },
            2 => { // color
                if (off + 8 > bytes.len) return null;
                off += 8;
            },
            else => return null,
        }
    }
    return values;
}

fn xsettingsGet16(order: u8, bytes: []const u8) ?u16 {
    if (bytes.len < 2) return null;
    return switch (order) {
        'l' => @as(u16, bytes[0]) | (@as(u16, bytes[1]) << 8),
        'B' => (@as(u16, bytes[0]) << 8) | @as(u16, bytes[1]),
        else => null,
    };
}

fn xsettingsGet32(order: u8, bytes: []const u8) ?u32 {
    if (bytes.len < 4) return null;
    return switch (order) {
        'l' => @as(u32, bytes[0]) | (@as(u32, bytes[1]) << 8) | (@as(u32, bytes[2]) << 16) | (@as(u32, bytes[3]) << 24),
        'B' => (@as(u32, bytes[0]) << 24) | (@as(u32, bytes[1]) << 16) | (@as(u32, bytes[2]) << 8) | @as(u32, bytes[3]),
        else => null,
    };
}

pub fn parseXftDpi(resources: []const u8) ?u32 {
    var lines = std.mem.splitScalar(u8, resources, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (!std.mem.startsWith(u8, trimmed, "Xft.dpi")) continue;
        const colon = std.mem.indexOfScalar(u8, trimmed, ':') orelse continue;
        const value = std.mem.trim(u8, trimmed[colon + 1 ..], " \t");
        if (value.len == 0) continue;
        if (std.fmt.parseInt(u32, value, 10)) |dpi| {
            if (dpi >= 1 and dpi <= 768) return dpi;
        } else |_| {}
        const parsed = std.fmt.parseFloat(f32, value) catch continue;
        if (parsed >= 1 and parsed <= 768) return @intFromFloat(@round(parsed));
    }
    return null;
}

pub fn parseXcursorSize(resources: []const u8) ?u32 {
    var lines = std.mem.splitScalar(u8, resources, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (!std.mem.startsWith(u8, trimmed, "Xcursor.size")) continue;
        const colon = std.mem.indexOfScalar(u8, trimmed, ':') orelse continue;
        const value = std.mem.trim(u8, trimmed[colon + 1 ..], " \t");
        return parseCursorPx(value);
    }
    return null;
}

pub fn cursorPixelSize(scale: u32, env: []const u8, resources: []const u8) u32 {
    if (environValue(env, "XCURSOR_SIZE")) |value| {
        if (parseCursorPx(value)) |size| return size;
    }
    if (parseXcursorSize(resources)) |size| return size;
    return @min(64, @max(16, 16 * @max(scale, 1)));
}

fn parseCursorPx(value: []const u8) ?u32 {
    const trimmed = std.mem.trim(u8, value, " \t");
    if (trimmed.len == 0) return null;
    const parsed = std.fmt.parseInt(u32, trimmed, 10) catch return null;
    if (parsed < 8 or parsed > 128) return null;
    return parsed;
}

/// Geometric taskbar mark: navy tile, cream balloon. Not comic artwork.
pub fn fillWindowMark(dst: []u32, size: u32) void {
    if (size == 0 or dst.len < @as(usize, size) * @as(usize, size)) return;
    const navy: u32 = 0xff16324f;
    const cream: u32 = 0xfff4e6c8;
    const ink: u32 = 0xff2b1d12;
    @memset(dst[0 .. @as(usize, size) * @as(usize, size)], 0);
    const margin = @max(1, size / 8);
    var y: u32 = 0;
    while (y < size) : (y += 1) {
        var x: u32 = 0;
        while (x < size) : (x += 1) {
            const edge = x < margin or y < margin or x + margin >= size or y + margin >= size;
            dst[@as(usize, y) * size + x] = if (edge) ink else navy;
        }
    }
    const balloon_x0 = size / 4;
    const balloon_x1 = size - size / 6;
    const balloon_y0 = size / 5;
    const balloon_y1 = size - size / 3;
    var by = balloon_y0;
    while (by < balloon_y1) : (by += 1) {
        var bx = balloon_x0;
        while (bx < balloon_x1) : (bx += 1) {
            dst[@as(usize, by) * size + bx] = cream;
        }
    }
    var tail: u32 = 0;
    while (tail < size / 5) : (tail += 1) {
        const tx = balloon_x0 + tail;
        const ty = balloon_y1 + tail / 2;
        if (tx < size and ty < size) dst[@as(usize, ty) * size + tx] = cream;
    }
}

/// Classic left-pointing arrow with a white outline. `size` is the pixmap edge.
pub fn fillArrowCursor(dst: []u32, size: u32) void {
    if (size == 0 or dst.len < @as(usize, size) * @as(usize, size)) return;
    @memset(dst[0 .. @as(usize, size) * @as(usize, size)], 0);
    const src_w: u32 = 12;
    const src_h: u32 = 16;
    const outline = [_]u16{
        0b100000000000,
        0b110000000000,
        0b111000000000,
        0b111100000000,
        0b111110000000,
        0b111111000000,
        0b111111100000,
        0b111111110000,
        0b111111111000,
        0b111111000000,
        0b110111000000,
        0b100011100000,
        0b000011100000,
        0b000001110000,
        0b000001110000,
        0b000000110000,
    };
    const fill = [_]u16{
        0b000000000000,
        0b010000000000,
        0b011000000000,
        0b011100000000,
        0b011110000000,
        0b011111000000,
        0b011111100000,
        0b011111110000,
        0b011110000000,
        0b010110000000,
        0b000011000000,
        0b000011000000,
        0b000001100000,
        0b000001100000,
        0b000000100000,
        0b000000000000,
    };
    var y: u32 = 0;
    while (y < size) : (y += 1) {
        const sy = @min(src_h - 1, (y * src_h) / size);
        var x: u32 = 0;
        while (x < size) : (x += 1) {
            const sx = @min(src_w - 1, (x * src_w) / size);
            const bit: u16 = @as(u16, 1) << @intCast(src_w - 1 - sx);
            if (outline[sy] & bit == 0) continue;
            dst[@as(usize, y) * size + x] = if (fill[sy] & bit != 0) 0xff000000 else 0xffffffff;
        }
    }
}

pub fn arrowHotspot(size: u32) struct { x: u32, y: u32 } {
    const edge = @max(size, 1);
    return .{ .x = @max(1, edge / 16), .y = @max(1, edge / 16) };
}

pub fn packNetWmIcon(gpa: std.mem.Allocator, sizes: []const u32) ![]u32 {
    var total: usize = 0;
    for (sizes) |size| {
        if (size == 0 or size > 64) return error.InvalidIconSize;
        total = try std.math.add(usize, total, 2 + @as(usize, size) * @as(usize, size));
    }
    const out = try gpa.alloc(u32, total);
    errdefer gpa.free(out);
    var off: usize = 0;
    for (sizes) |size| {
        out[off] = size;
        out[off + 1] = size;
        fillWindowMark(out[off + 2 .. off + 2 + @as(usize, size) * @as(usize, size)], size);
        off += 2 + @as(usize, size) * @as(usize, size);
    }
    return out;
}

pub fn bitmapStride(width: u32) usize {
    return ((@as(usize, width) + 31) / 32) * 4;
}

/// `source_fill` writes only the black arrow body; otherwise every opaque pixel.
pub fn encodeBitmapPlane(dst: []u8, pixels: []const u32, width: u32, height: u32, source_fill: bool) void {
    const stride = bitmapStride(width);
    @memset(dst, 0);
    var y: u32 = 0;
    while (y < height) : (y += 1) {
        var x: u32 = 0;
        while (x < width) : (x += 1) {
            const px = pixels[@as(usize, y) * width + x];
            if (px >> 24 < 0x80) continue;
            if (source_fill and (px & 0x00ffffff) != 0) continue;
            const bit: u3 = @intCast(x & 7);
            dst[@as(usize, y) * stride + x / 8] |= @as(u8, 1) << bit;
        }
    }
}

fn parsePositiveScale(value: []const u8) ?u32 {
    const trimmed = std.mem.trim(u8, value, " \t");
    if (trimmed.len == 0) return null;
    if (std.fmt.parseInt(u32, trimmed, 10)) |scale| {
        if (scale >= 1 and scale <= 8) return scale;
        return null;
    } else |_| {}
    const parsed = std.fmt.parseFloat(f32, trimmed) catch return null;
    if (parsed < 1 or parsed > 8) return null;
    const rounded: u32 = @intFromFloat(@round(parsed));
    if (rounded < 1 or rounded > 8) return null;
    return rounded;
}

/// Connects a UNIX-domain stream without going through `std.Io.net.UnixAddress`.
/// Abstract-namespace misses return `ECONNREFUSED` (111); Zig's helper treats
/// that as `Unexpected` and dumps a stack. Map the usual "no server" errnos
/// here so a missing X11/Wayland socket is a clean `ServerUnavailable`.
pub fn connectUnixStream(io: std.Io, path: []const u8) !std.Io.net.Stream {
    _ = io;
    const fd = try connectUnixFd(path);
    return .{ .socket = .{
        .handle = fd,
        .address = .{ .ip4 = .loopback(0) },
    } };
}

fn connectUnixFd(path: []const u8) !i32 {
    const max_path = @sizeOf(linux.sockaddr.un) - @sizeOf(linux.sa_family_t);
    if (path.len >= max_path) return error.NameTooLong;
    const rc = linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
    switch (linux.errno(rc)) {
        .SUCCESS => {},
        .NFILE, .MFILE, .NOBUFS, .NOMEM => return error.SystemResources,
        .AFNOSUPPORT, .PROTONOSUPPORT => return error.AddressFamilyUnsupported,
        else => return error.Unexpected,
    }
    const fd: i32 = @intCast(rc);

    var addr = std.mem.zeroes(linux.sockaddr.un);
    addr.family = linux.AF.UNIX;
    @memcpy(addr.path[0..path.len], path);
    // Pathname sockets include a trailing NUL in the address length.
    // Abstract sockets (`path[0] == 0`) use the exact byte count, no extra NUL.
    const addr_len: u32 = if (path.len > 0 and path[0] == 0)
        @intCast(@sizeOf(linux.sa_family_t) + path.len)
    else
        @intCast(@sizeOf(linux.sa_family_t) + path.len + 1);

    const connect_rc = linux.connect(fd, &addr, addr_len);
    switch (linux.errno(connect_rc)) {
        .SUCCESS => return fd,
        .NOENT, .CONNREFUSED, .AGAIN, .TIMEDOUT, .NETUNREACH, .HOSTUNREACH, .ADDRNOTAVAIL, .NOTCONN => {
            _ = linux.close(fd);
            return error.ServerUnavailable;
        },
        .ACCES, .PERM => {
            _ = linux.close(fd);
            return error.AccessDenied;
        },
        else => {
            _ = linux.close(fd);
            return error.Unexpected;
        },
    }
}

pub fn writeClipboard(io: std.Io, desktop: Desktop, text: []const u8) !void {
    if (text.len > max_clipboard_bytes) return error.ClipboardTooLarge;
    const argv_groups: []const []const []const u8 = switch (desktop) {
        .wayland => &.{
            &.{ "wl-copy", "--type", "text/plain;charset=utf-8" },
            &.{"wl-copy"},
        },
        .x11 => &.{
            &.{ "xclip", "-selection", "clipboard", "-in" },
            &.{ "xsel", "--clipboard", "--input" },
        },
    };
    var last_err: anyerror = error.DesktopServiceFailed;
    for (argv_groups) |argv| {
        writeClipboardArgv(io, text, argv) catch |err| {
            last_err = err;
            continue;
        };
        return;
    }
    return last_err;
}

fn writeClipboardArgv(io: std.Io, text: []const u8, argv: []const []const u8) !void {
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .stdin = .pipe,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    defer child.kill(io);
    const stdin = child.stdin orelse return error.MissingChildStdin;
    try stdin.writeStreamingAll(io, text);
    stdin.close(io);
    child.stdin = null;
    const term = try child.wait(io);
    if (!term.success()) return error.DesktopServiceFailed;
}

pub fn readClipboard(gpa: std.mem.Allocator, io: std.Io, desktop: Desktop) !?[]u8 {
    return readSelection(gpa, io, desktop, .clipboard);
}

/// PRIMARY / mouse-selection paste when the native protocol is missing.
pub fn readPrimary(gpa: std.mem.Allocator, io: std.Io, desktop: Desktop) !?[]u8 {
    return readSelection(gpa, io, desktop, .primary);
}

const SelectionKind = enum { clipboard, primary };

fn readSelection(gpa: std.mem.Allocator, io: std.Io, desktop: Desktop, kind: SelectionKind) !?[]u8 {
    const argv_groups: []const []const []const u8 = switch (desktop) {
        .wayland => switch (kind) {
            .clipboard => &.{
                &.{ "wl-paste", "--no-newline", "--type", "text" },
                &.{ "wl-paste", "--no-newline" },
            },
            .primary => &.{
                &.{ "wl-paste", "--primary", "--no-newline", "--type", "text" },
                &.{ "wl-paste", "--primary", "--no-newline" },
            },
        },
        .x11 => switch (kind) {
            .clipboard => &.{
                &.{ "xclip", "-selection", "clipboard", "-out" },
                &.{ "xsel", "--clipboard", "--output" },
            },
            .primary => &.{
                &.{ "xclip", "-selection", "primary", "-out" },
                &.{ "xsel", "--primary", "--output" },
            },
        },
    };
    for (argv_groups) |argv| {
        if (readClipboardArgv(gpa, io, argv)) |text| {
            return text;
        } else |_| continue;
    }
    return null;
}

fn readClipboardArgv(gpa: std.mem.Allocator, io: std.Io, argv: []const []const u8) !?[]u8 {
    var result = try std.process.run(gpa, io, .{
        .argv = argv,
        .stdout_limit = .limited(max_clipboard_bytes),
        .stderr_limit = .limited(4096),
    });
    defer gpa.free(result.stderr);
    if (!result.term.success()) {
        gpa.free(result.stdout);
        return null;
    }
    return result.stdout;
}

pub fn chooseFile(gpa: std.mem.Allocator, io: std.Io, save: bool, title: []const u8) !?[]u8 {
    const mode = if (save) "--save" else "--file-selection";
    const argv = if (save)
        &[_][]const u8{ "zenity", "--file-selection", mode, "--confirm-overwrite", "--title", title }
    else
        &[_][]const u8{ "zenity", mode, "--title", title };
    var result = std.process.run(gpa, io, .{
        .argv = argv,
        .stdout_limit = .limited(max_service_output),
        .stderr_limit = .limited(4096),
    }) catch return chooseFileKdialog(gpa, io, save, title);
    defer gpa.free(result.stderr);
    if (!result.term.success()) {
        gpa.free(result.stdout);
        return null;
    }
    return trimOwnedResult(gpa, result.stdout);
}

fn chooseFileKdialog(gpa: std.mem.Allocator, io: std.Io, save: bool, title: []const u8) !?[]u8 {
    const action = if (save) "--getsavefilename" else "--getopenfilename";
    const argv = [_][]const u8{ "kdialog", "--title", title, action, "." };
    var result = try std.process.run(gpa, io, .{
        .argv = &argv,
        .stdout_limit = .limited(max_service_output),
        .stderr_limit = .limited(4096),
    });
    defer gpa.free(result.stderr);
    if (!result.term.success()) {
        gpa.free(result.stdout);
        return null;
    }
    return trimOwnedResult(gpa, result.stdout);
}

const notify_urgency_flag = "--urgency=normal";
const notify_icon_flag = "--icon=applications-internet";

pub fn notify(gpa: std.mem.Allocator, io: std.Io, title: []const u8, body: []const u8) !void {
    if (title.len > 256 or body.len > 4096) return error.NotificationTooLarge;
    var result = try std.process.run(gpa, io, .{
        .argv = &.{ "notify-send", notify_urgency_flag, notify_icon_flag, "--app-name=Comic Chat", title, body },
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(4096),
    });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    if (!result.term.success()) return error.DesktopServiceFailed;
}

pub fn openPath(gpa: std.mem.Allocator, io: std.Io, path: []const u8) !void {
    return openPathActivated(gpa, io, path, null);
}

/// Opens a path/URL with `xdg-open`, exporting an activation token so the
/// launched window can take focus. `token` becomes both
/// `XDG_ACTIVATION_TOKEN` and `DESKTOP_STARTUP_ID`.
pub fn openPathActivated(gpa: std.mem.Allocator, io: std.Io, path: []const u8, token: ?[]const u8) !void {
    if (token) |value| {
        var act_buf: [576]u8 = undefined;
        var start_buf: [576]u8 = undefined;
        if (activationEnvArgs(value, &act_buf, &start_buf)) |env| {
            return runNoOutput(gpa, io, &.{ "env", env.activation, env.startup, "xdg-open", path });
        }
    }
    return runNoOutput(gpa, io, &.{ "xdg-open", path });
}

pub fn generatedStartupId(buf: []u8) ?[]const u8 {
    return generatedStartupIdTimed(buf, 1);
}

pub fn generatedStartupIdTimed(buf: []u8, time: u32) ?[]const u8 {
    const pid: u32 = @intCast(@max(0, linux.getpid()));
    return std.fmt.bufPrint(buf, "reinked-{d}-{d}", .{ pid, time }) catch null;
}

pub fn activationEnvArgs(token: []const u8, act_buf: []u8, start_buf: []u8) ?struct { activation: []const u8, startup: []const u8 } {
    if (token.len == 0 or token.len >= 512) return null;
    if (std.mem.indexOfScalar(u8, token, 0) != null) return null;
    const activation = std.fmt.bufPrint(act_buf, "XDG_ACTIVATION_TOKEN={s}", .{token}) catch return null;
    const startup = std.fmt.bufPrint(start_buf, "DESKTOP_STARTUP_ID={s}", .{token}) catch return null;
    return .{ .activation = activation, .startup = startup };
}

pub fn printPath(gpa: std.mem.Allocator, io: std.Io, path: []const u8) !void {
    runNoOutput(gpa, io, &.{ "lp", path }) catch return runNoOutput(gpa, io, &.{ "lpr", path });
}

fn runNoOutput(gpa: std.mem.Allocator, io: std.Io, argv: []const []const u8) !void {
    var result = try std.process.run(gpa, io, .{
        .argv = argv,
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(4096),
    });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    if (!result.term.success()) return error.DesktopServiceFailed;
}

fn trimOwnedResult(gpa: std.mem.Allocator, owned: []u8) !?[]u8 {
    const trimmed = std.mem.trim(u8, owned, "\r\n");
    if (trimmed.len == 0) {
        gpa.free(owned);
        return null;
    }
    if (trimmed.ptr == owned.ptr and trimmed.len == owned.len) return owned;
    const result = try gpa.dupe(u8, trimmed);
    gpa.free(owned);
    return result;
}

fn openReadOnly(path: [*:0]const u8) !i32 {
    const rc = linux.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    switch (linux.errno(rc)) {
        .SUCCESS => return @intCast(rc),
        .NOENT => return error.FileNotFound,
        .ACCES, .PERM => return error.AccessDenied,
        else => return error.OpenFailed,
    }
}

fn readSomeFd(fd: i32, dst: []u8) !usize {
    while (true) {
        const rc = linux.read(fd, dst.ptr, dst.len);
        switch (linux.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            .AGAIN => return error.WouldBlock,
            .CONNRESET => return error.ConnectionResetByPeer,
            else => return error.ReadFailed,
        }
    }
}

test "desktop service output trimming preserves an owned result" {
    const gpa = std.testing.allocator;
    const raw = try gpa.dupe(u8, "/tmp/chat.ccr\r\n");
    const trimmed = (try trimOwnedResult(gpa, raw)).?;
    defer gpa.free(trimmed);
    try std.testing.expectEqualStrings("/tmp/chat.ccr", trimmed);
}

test "environValue reads NUL-separated assignments" {
    try std.testing.expectEqualStrings("unix:0", environValue("HOME=/home/dev\x00DISPLAY=unix:0\x00", "DISPLAY").?);
    try std.testing.expect(environValue("HOME=/home/dev\x00", "DISPLAY") == null);
}

test "startupToken prefers XDG_ACTIVATION_TOKEN then DESKTOP_STARTUP_ID" {
    try std.testing.expectEqualStrings(
        "tok-1",
        startupToken("WAYLAND_DISPLAY=wayland-0\x00XDG_ACTIVATION_TOKEN=tok-1\x00DESKTOP_STARTUP_ID=old\x00").?,
    );
    try std.testing.expectEqualStrings("start/0", startupToken("DESKTOP_STARTUP_ID=start/0\x00").?);
    try std.testing.expect(startupToken("DISPLAY=:0\x00XDG_ACTIVATION_TOKEN=\x00") == null);
}

test "startupRemoveMessage encodes a NUL-terminated remove ID" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("remove: ID=tok-1\x00", startupRemoveMessage("tok-1", &buf).?);
    try std.testing.expectEqualStrings("remove: ID=foo\\ bar\x00", startupRemoveMessage("foo bar", &buf).?);
    try std.testing.expect(startupRemoveMessage("tok-1", buf[0..8]) == null);
}

test "integer scale comes from toolkit env, then rounded DPI" {
    try std.testing.expectEqual(@as(u32, 2), scaleFromEnvironment("QT_SCALE_FACTOR=1\x00GDK_SCALE=2\x00").?);
    try std.testing.expectEqual(@as(u32, 3), scaleFromEnvironment("QT_SCALE_FACTOR=2.6\x00").?);
    try std.testing.expect(scaleFromEnvironment("GDK_SCALE=0\x00") == null);
    try std.testing.expectEqual(@as(u32, 1), scaleFromEnvironment("GDK_SCALE=2\x00GDK_DPI_SCALE=0.5\x00").?);
    try std.testing.expectEqual(@as(u32, 2), scaleFromEnvironment("QT_SCREEN_SCALE_FACTORS=DP-1=2;HDMI-1=1\x00").?);
    try std.testing.expectEqual(@as(u32, 1), scaleFromDpi(96));
    try std.testing.expectEqual(@as(u32, 2), scaleFromDpi(144));
    try std.testing.expectEqual(@as(u32, 2), scaleFromDpi(192));
    try std.testing.expectEqual(@as(u32, 1), scaleFromDpi(120));
    try std.testing.expectEqual(@as(u32, 2), scaleFromScreenMm(3840, 600).?);
    try std.testing.expect(scaleFromScreenMm(1920, 508) == null);
    try std.testing.expect(scaleFromScreenMm(1920, 0) == null);
}

test "unix connect maps a missing pathname socket to ServerUnavailable" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    try std.testing.expectError(
        error.ServerUnavailable,
        connectUnixStream(threaded.io(), "/tmp/.comicchat-missing-unix-socket-test"),
    );
}

test "uri-list drop prefers a local file path and skips comments" {
    var buf: [128]u8 = undefined;
    const path = firstPathFromUriList("# comment\r\nhttps://example.test/a\r\nfile:///tmp/chat%20room.ccc\r\n", &buf).?;
    try std.testing.expectEqualStrings("/tmp/chat room.ccc", path);
    try std.testing.expectEqualStrings("/tmp/a.ccc", firstPathFromUriList("file://localhost/tmp/a.ccc\n", &buf).?);
    try std.testing.expectEqualStrings("/tmp/b.ccc", firstPathFromUriList("file:/tmp/b.ccc\n", &buf).?);
    try std.testing.expectEqualStrings("/tmp/c.ccc", firstPathFromUriList("file:///tmp/c.ccc?download=1#top\n", &buf).?);
    try std.testing.expect(firstPathFromUriList("file://remote.example/tmp/a.ccc\n", &buf) == null);
    try std.testing.expect(firstPathFromUriList("https://example.test/a\n", &buf) == null);
    try std.testing.expectEqualStrings("hello", firstDropText("hello\n", &buf).?);
}

test "desktop file-list MIME yields a local path and skips copy/cut headers" {
    var buf: [128]u8 = undefined;
    try std.testing.expect(isDesktopFileMime("x-special/gnome-copied-files"));
    try std.testing.expect(isDesktopFileMime("x-special/nautilus-clipboard"));
    try std.testing.expect(isDesktopFileMime("text/x-moz-url"));
    try std.testing.expect(isDesktopFileMime("application/x-moz-file"));
    try std.testing.expect(isDesktopFileMime("application/x-kde4-urilist"));
    try std.testing.expect(isDesktopFileMime("application/x-kde5-urilist"));
    try std.testing.expect(isDesktopFileMime("text/x-moz-url-priv"));
    try std.testing.expect(isCompoundTextMime("COMPOUND_TEXT"));
    try std.testing.expect(isCompoundTextMime("compound_text"));
    try std.testing.expect(!isDesktopFileMime("text/uri-list"));
    try std.testing.expect(isUriListMime("text/uri-list"));
    try std.testing.expect(isUriListMime("text/x-uri-list"));
    try std.testing.expect(isUriListMime("text/x-uri-list;charset=utf-8"));
    try std.testing.expect(!isUriListMime("text/plain"));
    try std.testing.expect(isRtfMime("text/rtf"));
    try std.testing.expect(isRtfMime("application/rtf"));
    try std.testing.expect(isRtfMime("text/rtf;charset=utf-8"));
    try std.testing.expect(!isRtfMime("text/html"));
    try std.testing.expectEqualStrings(
        "/tmp/chat room.ccc",
        firstPathFromDesktopFiles("copy\nfile:///tmp/chat%20room.ccc\n", &buf).?,
    );
    try std.testing.expectEqualStrings("/tmp/a.ccc", firstPathFromDesktopFiles("cut\n/tmp/a.ccc\n", &buf).?);
    try std.testing.expectEqualStrings("/tmp/b.ccc", firstDropText("copy\nfile:///tmp/b.ccc\n", &buf).?);
    try std.testing.expectEqualStrings(
        "/tmp/photo.png",
        firstPathFromDesktopFiles("file:///tmp/photo.png\nPhoto title\n", &buf).?,
    );
    try std.testing.expect(firstPathFromDesktopFiles("copy\nhttps://example.test/a\n", &buf) == null);
}

test "XSETTINGS prefers Gdk/WindowScalingFactor then Xft/DPI" {
    const scale2 = [_]u8{
        'l', 0,   0,   0,
        0,   0,   0,   0,
        1,   0,   0,   0,
        0,   0,   23,  0,
        'G', 'd', 'k', '/',
        'W', 'i', 'n', 'd',
        'o', 'w', 'S', 'c',
        'a', 'l', 'i', 'n',
        'g', 'F', 'a', 'c',
        't', 'o', 'r', 0,
        0,   0,   0,   0,
        2,   0,   0,   0,
    };
    try std.testing.expectEqual(@as(u32, 2), parseXsettingsScale(&scale2).?);

    const dpi192 = [_]u8{
        'B', 0,   0,   0,
        0,   0,   0,   0,
        0,   0,   0,   1,
        0,   0,   0,   7,
        'X', 'f', 't', '/',
        'D', 'P', 'I', 0,
        0,   0,   0,   0,
        0, 3, 0, 0, // 196608 = 192 * 1024
    };
    try std.testing.expectEqual(@as(u32, 2), parseXsettingsScale(&dpi192).?);
    try std.testing.expect(parseXsettingsScale("not-xsettings") == null);
}

test "Xft.dpi parser accepts integer and fractional resource lines" {
    try std.testing.expectEqual(@as(u32, 192), parseXftDpi("Xft.antialias: 1\nXft.dpi: 192\n").?);
    try std.testing.expectEqual(@as(u32, 144), parseXftDpi("Xft.dpi:\t143.7\r\n").?);
    try std.testing.expect(parseXftDpi("Xcursor.size: 24\n") == null);
}

test "cursor size prefers XCURSOR_SIZE then Xcursor.size then framebuffer scale" {
    try std.testing.expectEqual(@as(u32, 48), parseXcursorSize("Xcursor.theme: Adwaita\nXcursor.size: 48\n").?);
    try std.testing.expectEqual(@as(u32, 32), cursorPixelSize(1, "XCURSOR_SIZE=32\x00", "Xcursor.size: 24\n"));
    try std.testing.expectEqual(@as(u32, 24), cursorPixelSize(2, "", "Xcursor.size: 24\n"));
    try std.testing.expectEqual(@as(u32, 32), cursorPixelSize(2, "", ""));
    try std.testing.expectEqual(@as(u32, 16), cursorPixelSize(1, "", ""));
}

test "window mark and arrow cursor produce opaque pixels" {
    var mark: [16 * 16]u32 = undefined;
    fillWindowMark(&mark, 16);
    try std.testing.expectEqual(@as(u32, 0xfff4e6c8), mark[16 * 8 + 8]);
    try std.testing.expectEqual(@as(u32, 0xff2b1d12), mark[0]);
    try std.testing.expectEqual(@as(u32, 0xff16324f), mark[16 * 2 + 2]);
    var arrow: [16 * 16]u32 = undefined;
    fillArrowCursor(&arrow, 16);
    try std.testing.expectEqual(@as(u32, 0xffffffff), arrow[0]);
    try std.testing.expectEqual(@as(u32, 0xff000000), arrow[16 * 2 + 2]);
    const hot = arrowHotspot(32);
    try std.testing.expectEqual(@as(u32, 2), hot.x);
    const packed_icon = try packNetWmIcon(std.testing.allocator, &.{ 16, 32 });
    defer std.testing.allocator.free(packed_icon);
    try std.testing.expectEqual(@as(u32, 16), packed_icon[0]);
    try std.testing.expectEqual(@as(u32, 32), packed_icon[2 + 16 * 16]);
    var bits: [64]u8 = undefined;
    encodeBitmapPlane(&bits, &arrow, 16, 16, false);
    try std.testing.expect(bits[0] & 1 != 0);
}

test "clipboard bytes strip a UTF-8 BOM and decode UTF-16" {
    const gpa = std.testing.allocator;
    const stripped = try clipboardBytesToUtf8(gpa, "\xEF\xBB\xBFhello");
    defer gpa.free(stripped);
    try std.testing.expectEqualStrings("hello", stripped);
    const le = try clipboardBytesToUtf8(gpa, "\xFF\xFE" ++ "h\x00i\x00");
    defer gpa.free(le);
    try std.testing.expectEqualStrings("hi", le);
    const be = try clipboardBytesToUtf8(gpa, "\xFE\xFF" ++ "\x00h\x00i");
    defer gpa.free(be);
    try std.testing.expectEqualStrings("hi", be);
    const raw_le = try clipboardUtf16BytesToUtf8(gpa, "h\x00i\x00");
    defer gpa.free(raw_le);
    try std.testing.expectEqualStrings("hi", raw_le);
    const crlf = try clipboardBytesToUtf8(gpa, "a\r\nb\rc");
    defer gpa.free(crlf);
    try std.testing.expectEqualStrings("a\nb\nc", crlf);
}

test "COMPOUND_TEXT decodes Latin-1, UTF-8 designator, and skips unknown 94-n sets" {
    const gpa = std.testing.allocator;
    const latin = try compoundTextToUtf8(gpa, "caf\xe9");
    defer gpa.free(latin);
    try std.testing.expectEqualStrings("café", latin);
    const utf8 = try compoundTextToUtf8(gpa, "\x1b%Gкафе");
    defer gpa.free(utf8);
    try std.testing.expectEqualStrings("кафе", utf8);
    const already = try compoundTextToUtf8(gpa, "hello");
    defer gpa.free(already);
    try std.testing.expectEqualStrings("hello", already);
    const skipped = try compoundTextToUtf8(gpa, "a\x1b$(Bignored\x1b(B" ++ "b");
    defer gpa.free(skipped);
    try std.testing.expectEqualStrings("ab", skipped);
}

test "notify-send uses a normal urgency hint" {
    try std.testing.expectEqualStrings("--urgency=normal", notify_urgency_flag);
    try std.testing.expectEqualStrings("--icon=applications-internet", notify_icon_flag);
}

test "activation env args export both token names and reject empty or huge tokens" {
    var act: [576]u8 = undefined;
    var start: [576]u8 = undefined;
    const env = activationEnvArgs("focus-1", &act, &start).?;
    try std.testing.expectEqualStrings("XDG_ACTIVATION_TOKEN=focus-1", env.activation);
    try std.testing.expectEqualStrings("DESKTOP_STARTUP_ID=focus-1", env.startup);
    try std.testing.expect(activationEnvArgs("", &act, &start) == null);
    try std.testing.expect(activationEnvArgs("bad\x00token", &act, &start) == null);
    var id_buf: [80]u8 = undefined;
    const generated = generatedStartupIdTimed(&id_buf, 9).?;
    try std.testing.expect(std.mem.startsWith(u8, generated, "reinked-"));
    try std.testing.expect(std.mem.endsWith(u8, generated, "-9"));
}

test "isHtmlMime accepts charset parameters" {
    try std.testing.expect(isHtmlMime("text/html"));
    try std.testing.expect(isHtmlMime("text/html;charset=utf-8"));
    try std.testing.expect(isHtmlMime("TEXT/HTML;charset=UTF-8"));
    try std.testing.expect(!isHtmlMime("text/htmlx"));
    try std.testing.expect(!isHtmlMime("text/plain"));
}

test "rtfToPlainText extracts Unicode and skips destination groups" {
    const gpa = std.testing.allocator;
    const plain = try rtfToPlainText(gpa, "{\\rtf1\\ansi{\\fonttbl\\f0 Arial;}hello \\u8364? world\\par}");
    defer gpa.free(plain);
    try std.testing.expectEqualStrings("hello € world\n", plain);
    const hex = try rtfToPlainText(gpa, "{\\rtf1\\'41\\'62}");
    defer gpa.free(hex);
    try std.testing.expectEqualStrings("Ab", hex);
    const already = try rtfToPlainText(gpa, "already plain");
    defer gpa.free(already);
    try std.testing.expectEqualStrings("already plain", already);
}

test "htmlToPlainText strips tags and decodes common entities" {
    const gpa = std.testing.allocator;
    const plain = try htmlToPlainText(gpa, "already plain");
    defer gpa.free(plain);
    try std.testing.expectEqualStrings("already plain", plain);
    const html = try htmlToPlainText(gpa, "<p>Hello&nbsp;&amp;&lt;world&gt;</p><script>x()</script>done");
    defer gpa.free(html);
    try std.testing.expectEqual(@as(usize, 18), html.len);
    try std.testing.expectEqualStrings("Hello &<world>done", html);
    const numeric = try htmlToPlainText(gpa, "&#x20ac;&#32;ok");
    defer gpa.free(numeric);
    try std.testing.expectEqualStrings("€ ok", numeric);
}
