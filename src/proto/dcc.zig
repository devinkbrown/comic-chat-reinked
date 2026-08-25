//! Comic Chat's custom ACK'd DCC SEND avatar-file transfer.
//!
//! Ports `filesend.cpp`'s wire protocol and socket state machine, minus the
//! MFC progress-dialog/threading UI (`CFileProgress`, `CFileReceiveDialog`),
//! which has no portable equivalent and is not attempted here.
//!
//! Source anchors:
//! - `filesend.cpp:23`, `:174-176`: the CTCP `DCC SEND` offer message.
//! - `filesend.cpp:202-312`: `SendFileThread` - listen, accept, 1024-byte
//!   chunked stop-and-wait send loop, 4-byte big-endian cumulative ACK.
//! - `filesend.cpp:346-437`: `ChatReceiveFile` - offer token parsing.
//! - `filesend.cpp:439-523`: `ReceiveFileThread` - connect, 8192-byte recv
//!   loop, one ACK sent after every chunk.
//! - `histent.cpp:769-927`: `CTCPQuoteString`/`CTCPUnQuoteString`, the CTCP
//!   low-level quoting scheme protecting the filename token from embedded
//!   spaces/CR/LF/0x01.
//!
//! Unlike plain fire-and-forget IRC DCC SEND, this is a stop-and-wait
//! protocol: the sender waits for the receiver's cumulative-bytes ACK after
//! every chunk before sending the next one. A generic (non-Comic-Chat) DCC
//! peer that never sends these ACKs will stall `sendFile` until
//! `recv_timeout_ms` elapses.
//!
//! `g_chLLQuoteIRCX` and its sibling byte constants (`g_chAtSign`, `g_chEOS`,
//! `g_chLF`, `g_chCR`, `g_chSpace`) are not present in the pinned
//! historical source snapshot - they are declared in a file outside the
//! imported provenance set. The source's own comment names the scheme
//! precisely - "Quotes strings according to the CTCP draft, Feb. 2, 1997" -
//! so this port uses that public specification's low-level quote byte
//! (0x10 / DLE) rather than guessing. Flagged here as inferred from the
//! named external spec, not read directly from the pinned commit.

const std = @import("std");
const net = std.Io.net;

pub const ctcp_quote: u8 = 0x10;

/// `CTCPQuoteString` (histent.cpp:772-829). Returns `null` when `text`
/// contains none of the bytes that require quoting, matching the source
/// returning `FALSE` and leaving the caller's string untouched.
pub fn ctcpQuote(gpa: std.mem.Allocator, text: []const u8) !?[]u8 {
    if (std.mem.indexOfAny(u8, text, " \n\r\x01") == null and
        std.mem.indexOfScalar(u8, text, ctcp_quote) == null)
        return null;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (text) |byte| {
        switch (byte) {
            '\n' => try out.appendSlice(gpa, &.{ ctcp_quote, 'n' }),
            '\r' => try out.appendSlice(gpa, &.{ ctcp_quote, 'r' }),
            ' ' => try out.appendSlice(gpa, &.{ ctcp_quote, '@' }),
            0x01 => try out.appendSlice(gpa, &.{ ctcp_quote, '1' }),
            ctcp_quote => try out.appendSlice(gpa, &.{ ctcp_quote, ctcp_quote }),
            else => try out.append(gpa, byte),
        }
    }
    return try out.toOwnedSlice(gpa);
}

/// `CTCPUnQuoteString` (histent.cpp:834-927). Returns `null` when `text` has
/// no quote escapes at all, or a malformed one, matching the source
/// returning `FALSE` in both cases (the caller keeps the original string).
pub fn ctcpUnquote(gpa: std.mem.Allocator, text: []const u8) !?[]u8 {
    var saw_escape = false;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] != ctcp_quote) continue;
        if (i + 1 >= text.len) return null;
        switch (text[i + 1]) {
            '1', '@', 'n', 'r', ctcp_quote => {},
            else => return null,
        }
        saw_escape = true;
        i += 1;
    }
    if (!saw_escape) return null;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    i = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] == ctcp_quote) {
            switch (text[i + 1]) {
                'n' => try out.append(gpa, '\n'),
                'r' => try out.append(gpa, '\r'),
                '1' => try out.append(gpa, 0x01),
                '@' => try out.append(gpa, ' '),
                ctcp_quote => try out.append(gpa, ctcp_quote),
                else => unreachable, // validated in the first pass above
            }
            i += 1;
        } else {
            try out.append(gpa, text[i]);
        }
    }
    return try out.toOwnedSlice(gpa);
}

fn nextToken(text: []const u8) ?struct { token: []const u8, rest: []const u8 } {
    // `GetToken(mesg, &mesg, "")` (filesend.cpp:352 etc.): an empty
    // separator set collapses `GetToken2` to a plain whitespace tokenizer.
    var start: usize = 0;
    while (start < text.len and std.ascii.isWhitespace(text[start])) start += 1;
    if (start == text.len) return null;
    var end = start;
    while (end < text.len and !std.ascii.isWhitespace(text[end])) end += 1;
    return .{ .token = text[start..end], .rest = text[end..] };
}

/// One `DCC SEND` offer (filesend.cpp:174-175, :346-380).
pub const SendOffer = struct {
    /// CTCP-unquoted filename (an embedded space, if any, already decoded).
    filename: []const u8,
    /// Host IP as a plain decimal integer on the wire, matching
    /// `GetMyIP()`/`ntohl` (filesend.cpp:155-156, :364, :455).
    host_ip: u32,
    port: u16,
    /// Null when the sender omitted the size field (filesend.cpp:369-371).
    size: ?u64,
};

/// `ChatSendFile`'s offer line (filesend.cpp:174-176): `"\x01DCC SEND
/// <quoted-name> <host-ip> <port> <size>\x01"`. This port's own sender
/// always knows the file size, matching the source's own client.
pub fn encodeSendOffer(gpa: std.mem.Allocator, offer: SendOffer) ![]u8 {
    const quoted = try ctcpQuote(gpa, offer.filename);
    defer if (quoted) |q| gpa.free(q);
    const filename_field = quoted orelse offer.filename;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, "\x01DCC SEND ");
    try out.appendSlice(gpa, filename_field);

    var num_buf: [24]u8 = undefined;
    try out.append(gpa, ' ');
    try out.appendSlice(gpa, try std.fmt.bufPrint(&num_buf, "{d}", .{offer.host_ip}));
    try out.append(gpa, ' ');
    try out.appendSlice(gpa, try std.fmt.bufPrint(&num_buf, "{d}", .{offer.port}));
    if (offer.size) |size| {
        try out.append(gpa, ' ');
        try out.appendSlice(gpa, try std.fmt.bufPrint(&num_buf, "{d}", .{size}));
    }
    try out.append(gpa, 0x01);
    return try out.toOwnedSlice(gpa);
}

/// Case-insensitive CTCP `DCC SEND` recognition. The consent path must use
/// this instead of a literal `startsWith("\x01DCC SEND ")` so mixed-case
/// offers still reach the approval dialog.
pub fn looksLikeDccControl(text: []const u8) bool {
    if (text.len < 5 or !std.ascii.eqlIgnoreCase(text[0..4], "\x01DCC") or text[4] != ' ')
        return false;
    return text[text.len - 1] == 0x01;
}

pub fn looksLikeSendOffer(text: []const u8) bool {
    if (!looksLikeDccControl(text))
        return false;
    var rest = text[5..];
    if (rest.len > 0 and rest[rest.len - 1] == 0x01)
        rest = rest[0 .. rest.len - 1];
    const send_tok = nextToken(rest) orelse return false;
    return std.ascii.eqlIgnoreCase(send_tok.token, "SEND");
}

/// `ircsock.cpp:1718-1725` (the `\x01DCC ` marker) plus `ChatReceiveFile`
/// (filesend.cpp:346-380). `text` is the full raw message, e.g. as it
/// arrives in a PRIVMSG body. On success, `result.filename` is
/// caller-owned (`gpa.free`); returns `null` for anything not recognized
/// as a `DCC SEND` offer, matching the source silently ignoring it
/// (`ChatReceiveFile`'s early `return`s) rather than reporting a specific
/// parse error. Unlike `atol`/`atoi`'s silent leading-digit parse, a
/// malformed numeric field here is rejected rather than truncated -
/// stricter than the source, but only on already-malformed input.
pub fn parseSendOffer(gpa: std.mem.Allocator, text: []const u8) !?SendOffer {
    if (!looksLikeSendOffer(text))
        return null;
    var rest = text[5..];
    if (rest.len > 0 and rest[rest.len - 1] == 0x01)
        rest = rest[0 .. rest.len - 1];

    const send_tok = nextToken(rest) orelse return null;
    if (!std.ascii.eqlIgnoreCase(send_tok.token, "SEND")) return null;
    rest = send_tok.rest;

    const name_tok = nextToken(rest) orelse return null;
    rest = name_tok.rest;
    const unquoted = try ctcpUnquote(gpa, name_tok.token);
    const filename = unquoted orelse try gpa.dupe(u8, name_tok.token);
    errdefer gpa.free(filename);

    const ip_tok = nextToken(rest) orelse return null;
    rest = ip_tok.rest;
    const host_ip = std.fmt.parseInt(u32, ip_tok.token, 10) catch return null;

    const port_tok = nextToken(rest) orelse return null;
    rest = port_tok.rest;
    const port = std.fmt.parseInt(u16, port_tok.token, 10) catch return null;

    const size: ?u64 = if (nextToken(rest)) |size_tok|
        std.fmt.parseInt(u64, size_tok.token, 10) catch null
    else
        null;

    return .{ .filename = filename, .host_ip = host_ip, .port = port, .size = size };
}

pub const accept_timeout_ms: u32 = 120_000; // filesend.cpp:32 ACCEPT_TIMEOUT
pub const recv_timeout_ms: u32 = 60_000; // filesend.cpp:33 RECV_TIMEOUT
pub const send_chunk_size: usize = 1024; // filesend.cpp:254 char buff[1024]
pub const recv_chunk_size: usize = 8192; // filesend.cpp:481 char buff[8192]

fn streamWriteAll(io: std.Io, stream: *const net.Stream, bytes: []const u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const n = try io.vtable.netWrite(io.userdata, stream.socket.handle, "", &[_][]const u8{bytes[offset..]}, 1);
        if (n == 0) return error.WriteZero;
        offset += n;
    }
}

fn streamReadTimeout(io: std.Io, stream: *const net.Stream, dst: []u8, timeout_ms: u32) !usize {
    var iov = [_][]u8{dst};
    const result = io.operateTimeout(.{ .net_read = .{
        .socket_handle = stream.socket.handle,
        .data = iov[0..],
    } }, .{ .duration = .{
        .raw = std.Io.Duration.fromMilliseconds(timeout_ms),
        .clock = .awake,
    } }) catch |err| switch (err) {
        error.Timeout => return error.DccTimeout,
        else => return err,
    };
    const received = try result.net_read;
    if (received == 0) return error.DccPeerClosed;
    return received;
}

fn streamReadExact(io: std.Io, stream: *const net.Stream, dst: []u8, timeout_ms: u32) !void {
    var offset: usize = 0;
    while (offset < dst.len) offset += try streamReadTimeout(io, stream, dst[offset..], timeout_ms);
}

/// `SendFileThread` (filesend.cpp:202-312), minus the MFC progress dialog.
/// Listens on `port`, accepts exactly one connection, then streams `data`
/// in `send_chunk_size` chunks, waiting after each chunk for the peer's
/// 4-byte big-endian cumulative-bytes-received ACK before sending the next
/// one. `data` is held in memory for the whole transfer; this port does
/// not stream incrementally from disk the way the source reads its file
/// handle chunk-by-chunk.
pub fn sendFile(io: std.Io, port: u16, data: []const u8) !void {
    var control: NullTransferControl = .{};
    return sendFileControlled(io, port, data, &control);
}

pub fn sendFileControlled(io: std.Io, port: u16, data: []const u8, control: anytype) !void {
    if (control.cancelled()) return error.DccCancelled;
    var address: net.IpAddress = .{ .ip4 = .unspecified(port) };
    var server = try address.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);
    control.socketOpened(server.socket.handle);
    defer control.socketClosed();

    var stream = server.accept(io) catch |err| {
        if (control.cancelled()) return error.DccCancelled;
        return err;
    };
    defer stream.close(io);
    control.socketOpened(stream.socket.handle);

    var total_sent: usize = 0;
    while (total_sent < data.len) {
        if (control.cancelled()) return error.DccCancelled;
        const chunk_len = @min(send_chunk_size, data.len - total_sent);
        try streamWriteAll(io, &stream, data[total_sent .. total_sent + chunk_len]);
        total_sent += chunk_len;

        var acked: u64 = 0;
        while (acked < total_sent) {
            var ack_bytes: [4]u8 = undefined;
            try streamReadExact(io, &stream, &ack_bytes, recv_timeout_ms);
            acked = std.mem.readInt(u32, &ack_bytes, .big);
        }
        control.progress(total_sent, data.len);
    }
}

/// `ReceiveFileThread` (filesend.cpp:439-523), minus the MFC progress
/// dialog. Connects to `host_ip:port`, then receives up to `expected_size`
/// bytes, sending back a 4-byte big-endian cumulative-bytes-received ACK
/// after every chunk. The returned buffer is caller-owned.
///
/// NOTE on `expected_size == null`: the source's own receive loop tests
/// `totalRead >= fileTX->fileSize`, and an unknown size is represented as
/// `fileSize = -1` (filesend.cpp:370). Since any non-negative `totalRead`
/// satisfies `>= -1`, the *original* client actually stops after its very
/// first `recv()` for an unknown-size transfer - almost certainly an
/// upstream bug, not an intentional "receive until close" mode. This port
/// preserves that literally (returning after the first chunk) rather than
/// guessing a "more correct" behavior the source never implements; our own
/// `sendFile`/`encodeSendOffer` always supply a real size, so a peer of
/// this port never triggers it.
pub fn receiveFile(gpa: std.mem.Allocator, io: std.Io, host_ip: u32, port: u16, expected_size: ?u64) ![]u8 {
    var control: NullTransferControl = .{};
    return receiveFileControlled(gpa, io, host_ip, port, expected_size, &control);
}

pub const NullTransferControl = struct {
    pub fn cancelled(_: *const NullTransferControl) bool {
        return false;
    }
    pub fn progress(_: *NullTransferControl, _: u64, _: ?u64) void {}
    pub fn socketOpened(_: *NullTransferControl, _: net.Socket.Handle) void {}
    pub fn socketClosed(_: *NullTransferControl) void {}
};

/// Receive with application-owned progress and cancellation. Reads use short
/// timeout slices so Cancel is observed promptly while preserving the source's
/// overall 60-second receive timeout.
pub fn receiveFileControlled(gpa: std.mem.Allocator, io: std.Io, host_ip: u32, port: u16, expected_size: ?u64, control: anytype) ![]u8 {
    if (control.cancelled()) return error.DccCancelled;
    if (expected_size == 0) return gpa.alloc(u8, 0);
    var addr_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &addr_bytes, host_ip, .big);
    var address: net.IpAddress = .{ .ip4 = .{ .bytes = addr_bytes, .port = port } };
    var stream = try address.connect(io, .{ .mode = .stream });
    defer stream.close(io);
    control.socketOpened(stream.socket.handle);
    defer control.socketClosed();

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    var buf: [recv_chunk_size]u8 = undefined;
    var idle_ms: u32 = 0;
    while (true) {
        if (control.cancelled()) return error.DccCancelled;
        const n = streamReadTimeout(io, &stream, &buf, 250) catch |err| switch (err) {
            error.DccTimeout => {
                idle_ms +|= 250;
                if (idle_ms >= recv_timeout_ms) return error.DccTimeout;
                continue;
            },
            else => return err,
        };
        idle_ms = 0;
        var take = n;
        if (expected_size) |size| {
            const remaining = size -| out.items.len;
            take = @min(take, remaining);
        }
        try out.appendSlice(gpa, buf[0..take]);
        control.progress(out.items.len, expected_size);

        var ack_bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &ack_bytes, @as(u32, @intCast(out.items.len)), .big);
        try streamWriteAll(io, &stream, &ack_bytes);

        if (expected_size) |size| {
            if (out.items.len >= size) break;
        } else break; // source quirk: stops after the first chunk (see doc comment)
    }
    return try out.toOwnedSlice(gpa);
}

test "ctcpQuote/ctcpUnquote round-trip the escaped byte set and pass through plain text" {
    const gpa = std.testing.allocator;

    try std.testing.expect(try ctcpQuote(gpa, "plain-name.avb") == null);
    try std.testing.expect(try ctcpUnquote(gpa, "plain-name.avb") == null);

    const quoted = (try ctcpQuote(gpa, "my avatar\r\n\x01\x10.avb")).?;
    defer gpa.free(quoted);
    try std.testing.expectEqualStrings("my\x10@avatar\x10r\x10n\x101\x10\x10.avb", quoted);

    const unquoted = (try ctcpUnquote(gpa, quoted)).?;
    defer gpa.free(unquoted);
    try std.testing.expectEqualStrings("my avatar\r\n\x01\x10.avb", unquoted);
}

test "ctcpUnquote rejects a malformed escape and a lone trailing quote byte" {
    const gpa = std.testing.allocator;
    try std.testing.expect(try ctcpUnquote(gpa, "bad\x10Xescape") == null);
    try std.testing.expect(try ctcpUnquote(gpa, "trailing\x10") == null);
}

test "DCC SEND offer encodes and decodes, including a filename needing CTCP quoting" {
    const gpa = std.testing.allocator;

    const wire = try encodeSendOffer(gpa, .{ .filename = "my avatar.avb", .host_ip = 3232235777, .port = 7011, .size = 4096 });
    defer gpa.free(wire);
    try std.testing.expectEqualStrings("\x01DCC SEND my\x10@avatar.avb 3232235777 7011 4096\x01", wire);

    const decoded = (try parseSendOffer(gpa, wire)).?;
    defer gpa.free(decoded.filename);
    try std.testing.expectEqualStrings("my avatar.avb", decoded.filename);
    try std.testing.expectEqual(@as(u32, 3232235777), decoded.host_ip);
    try std.testing.expectEqual(@as(u16, 7011), decoded.port);
    try std.testing.expectEqual(@as(u64, 4096), decoded.size.?);
}

test "parseSendOffer accepts an omitted size field and rejects non-offers" {
    const gpa = std.testing.allocator;

    const no_size = (try parseSendOffer(gpa, "\x01DCC SEND anna.avb 16777343 9000\x01")).?;
    defer gpa.free(no_size.filename);
    try std.testing.expect(no_size.size == null);

    try std.testing.expect(try parseSendOffer(gpa, "ordinary message") == null);
    try std.testing.expect(try parseSendOffer(gpa, "\x01DCC CHAT chat 16777343 9000\x01") == null);
    try std.testing.expect(try parseSendOffer(gpa, "\x01ACTION waves\x01") == null);

    try std.testing.expect(looksLikeSendOffer("\x01dcc send anna.avb 16777343 9000\x01"));
    const mixed = (try parseSendOffer(gpa, "\x01dcc send anna.avb 16777343 9000\x01")).?;
    defer gpa.free(mixed.filename);
    try std.testing.expectEqualStrings("anna.avb", mixed.filename);
    try std.testing.expect(!looksLikeSendOffer("\x01dcc chat chat 16777343 9000\x01"));
    try std.testing.expect(looksLikeDccControl("\x01DCC CHAT chat 16777343 9000\x01"));
    try std.testing.expect(looksLikeDccControl("\x01dcc resume file 9000 64\x01"));
    try std.testing.expect(looksLikeDccControl("\x01DCC SEND\x01"));
    try std.testing.expect(!looksLikeDccControl("\x01ACTION waves\x01"));
    try std.testing.expect(!looksLikeDccControl("ordinary message"));
}

test "sendFile and receiveFile round-trip real bytes over a loopback TCP connection" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const port: u16 = 27011;
    var payload: [send_chunk_size * 3 + 17]u8 = undefined;
    for (&payload, 0..) |*b, i| b.* = @truncate(i);

    const Ctx = struct {
        io: std.Io,
        port: u16,
        payload: []const u8,
        err: ?anyerror = null,
    };
    var ctx: Ctx = .{ .io = io, .port = port, .payload = &payload };

    const sender = try std.Thread.spawn(.{}, struct {
        fn run(c: *Ctx) void {
            sendFile(c.io, c.port, c.payload) catch |err| {
                c.err = err;
            };
        }
    }.run, .{&ctx});

    // Give the listener a moment to bind before the receiver connects.
    try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(50), .awake);

    const loopback_ip: u32 = 0x7f000001; // 127.0.0.1
    const received = try receiveFile(gpa, io, loopback_ip, port, payload.len);
    defer gpa.free(received);

    sender.join();
    try std.testing.expect(ctx.err == null);
    try std.testing.expectEqualSlices(u8, &payload, received);
}

test "controlled DCC receive observes cancellation before connecting" {
    const Cancelled = struct {
        pub fn cancelled(_: *@This()) bool {
            return true;
        }
        pub fn progress(_: *@This(), _: u64, _: ?u64) void {}
        pub fn socketOpened(_: *@This(), _: net.Socket.Handle) void {}
        pub fn socketClosed(_: *@This()) void {}
    };
    var cancelled: Cancelled = .{};
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    try std.testing.expectError(
        error.DccCancelled,
        receiveFileControlled(std.testing.allocator, threaded.io(), 0x7f000001, 27012, 1, &cancelled),
    );
}
