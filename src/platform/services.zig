//! Small native desktop-service bridge for pure-Zig Unix builds.
//!
//! The window backends remain direct protocol implementations and now own the
//! primary clipboard path. These helpers are the fallback when a compositor or
//! X server cannot complete the native transfer, plus notifications, file
//! selection, document opening, and printing. Every call is bounded and
//! failure is non-fatal, so minimal installations retain the internal
//! application fallback.

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

/// First usable payload from a drop: a `file:` URI becomes a local path,
/// otherwise the first non-empty line is returned as text.
pub fn firstDropText(text: []const u8, buf: []u8) ?[]const u8 {
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
    const prefix = "text/html";
    if (mime.len < prefix.len) return false;
    if (!std.ascii.eqlIgnoreCase(mime[0..prefix.len], prefix)) return false;
    return mime.len == prefix.len or mime[prefix.len] == ';';
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
    const argv_groups: []const []const []const u8 = switch (desktop) {
        .wayland => &.{
            &.{ "wl-paste", "--no-newline", "--type", "text" },
            &.{ "wl-paste", "--no-newline" },
        },
        .x11 => &.{
            &.{ "xclip", "-selection", "clipboard", "-out" },
            &.{ "xsel", "--clipboard", "--output" },
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

pub fn notify(gpa: std.mem.Allocator, io: std.Io, title: []const u8, body: []const u8) !void {
    if (title.len > 256 or body.len > 4096) return error.NotificationTooLarge;
    var result = try std.process.run(gpa, io, .{
        .argv = &.{ "notify-send", "--app-name=Comic Chat", title, body },
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(4096),
    });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    if (!result.term.success()) return error.DesktopServiceFailed;
}

pub fn openPath(gpa: std.mem.Allocator, io: std.Io, path: []const u8) !void {
    return runNoOutput(gpa, io, &.{ "xdg-open", path });
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

test "isHtmlMime accepts charset parameters" {
    try std.testing.expect(isHtmlMime("text/html"));
    try std.testing.expect(isHtmlMime("text/html;charset=utf-8"));
    try std.testing.expect(isHtmlMime("TEXT/HTML;charset=UTF-8"));
    try std.testing.expect(!isHtmlMime("text/htmlx"));
    try std.testing.expect(!isHtmlMime("text/plain"));
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
