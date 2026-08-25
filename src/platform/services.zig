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
}

test "unix connect maps a missing pathname socket to ServerUnavailable" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    try std.testing.expectError(
        error.ServerUnavailable,
        connectUnixStream(threaded.io(), "/tmp/.comicchat-missing-unix-socket-test"),
    );
}

test "Xft.dpi parser accepts integer and fractional resource lines" {
    try std.testing.expectEqual(@as(u32, 192), parseXftDpi("Xft.antialias: 1\nXft.dpi: 192\n").?);
    try std.testing.expectEqual(@as(u32, 144), parseXftDpi("Xft.dpi:\t143.7\r\n").?);
    try std.testing.expect(parseXftDpi("Xcursor.size: 24\n") == null);
}
