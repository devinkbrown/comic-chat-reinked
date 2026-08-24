//! Deterministic production connection policy primitives.
//!
//! Socket backends stay small: bounded priority queues, flood control,
//! deadlines, reconnect scheduling, address racing, restoration, and proxy
//! handshakes are pure/testable here.

const std = @import("std");
const message = @import("message.zig");

pub const Limits = struct {
    tx_messages: usize = 512,
    tx_bytes: usize = 512 * 1024,
    rx_messages: usize = 1024,
    rx_bytes: usize = 1024 * 1024,
};

pub const Priority = enum(u2) { control, interactive, bulk };

pub const TxItem = struct {
    bytes: []u8,
    priority: Priority,
    /// Only idempotent protocol restoration may survive a reconnect. Chat
    /// messages are deliberately never replayed after an uncertain send.
    replay_safe: bool,
    sensitive: bool,
};

pub const TxQueue = struct {
    gpa: std.mem.Allocator,
    limits: Limits,
    items: std.ArrayList(TxItem) = .empty,
    bytes: usize = 0,
    bucket: TokenBucket,

    pub fn init(gpa: std.mem.Allocator, limits: Limits, now_ms: u64, rate_per_second: u32, burst: u32) TxQueue {
        return .{
            .gpa = gpa,
            .limits = limits,
            .bucket = TokenBucket.init(now_ms, rate_per_second, burst),
        };
    }

    pub fn deinit(self: *TxQueue) void {
        for (self.items.items) |item| {
            if (item.sensitive) std.crypto.secureZero(u8, item.bytes);
            self.gpa.free(item.bytes);
        }
        self.items.deinit(self.gpa);
        self.* = undefined;
    }

    pub fn enqueue(self: *TxQueue, bytes: []const u8, priority: Priority, replay_safe: bool, sensitive: bool) !void {
        if (self.items.items.len >= self.limits.tx_messages or self.bytes + bytes.len > self.limits.tx_bytes)
            return error.TxBackpressure;
        const owned = try self.gpa.dupe(u8, bytes);
        errdefer {
            if (sensitive) std.crypto.secureZero(u8, owned);
            self.gpa.free(owned);
        }
        try self.items.append(self.gpa, .{ .bytes = owned, .priority = priority, .replay_safe = replay_safe, .sensitive = sensitive });
        self.bytes += owned.len;
    }

    /// Borrow the next sendable item. Control traffic (CAP/AUTH/PONG) always
    /// preempts chat and does not wait behind the chat flood bucket.
    pub fn peek(self: *TxQueue, now_ms: u64) ?struct { index: usize, bytes: []const u8 } {
        var best: ?usize = null;
        for (self.items.items, 0..) |item, index| {
            if (best == null or @intFromEnum(item.priority) < @intFromEnum(self.items.items[best.?].priority))
                best = index;
        }
        const index = best orelse return null;
        if (self.items.items[index].priority != .control and !self.bucket.consume(now_ms, 1)) return null;
        return .{ .index = index, .bytes = self.items.items[index].bytes };
    }

    pub fn confirmSent(self: *TxQueue, index: usize) void {
        const sent = self.items.orderedRemove(index);
        self.bytes -= sent.bytes.len;
        if (sent.sensitive) std.crypto.secureZero(u8, sent.bytes);
        self.gpa.free(sent.bytes);
    }

    /// A transport error after a write began has unknown delivery status.
    /// Drop that item instead of risking a duplicated chat message.
    pub fn markUncertain(self: *TxQueue, index: usize) void {
        self.confirmSent(index);
    }

    pub fn prepareReconnect(self: *TxQueue) void {
        var index: usize = 0;
        while (index < self.items.items.len) {
            if (self.items.items[index].replay_safe) {
                index += 1;
                continue;
            }
            self.confirmSent(index);
        }
    }
};

pub const RxQueue = struct {
    gpa: std.mem.Allocator,
    limits: Limits,
    items: std.ArrayList([]u8) = .empty,
    bytes: usize = 0,

    pub fn init(gpa: std.mem.Allocator, limits: Limits) RxQueue {
        return .{ .gpa = gpa, .limits = limits };
    }

    pub fn deinit(self: *RxQueue) void {
        for (self.items.items) |item| self.gpa.free(item);
        self.items.deinit(self.gpa);
        self.* = undefined;
    }

    pub fn push(self: *RxQueue, line: []const u8) !void {
        if (self.items.items.len >= self.limits.rx_messages or self.bytes + line.len > self.limits.rx_bytes)
            return error.RxBackpressure;
        const owned = try self.gpa.dupe(u8, line);
        errdefer self.gpa.free(owned);
        try self.items.append(self.gpa, owned);
        self.bytes += owned.len;
    }

    pub fn pop(self: *RxQueue) ?[]u8 {
        if (self.items.items.len == 0) return null;
        const item = self.items.orderedRemove(0);
        self.bytes -= item.len;
        return item;
    }
};

pub const TokenBucket = struct {
    rate_per_second: u32,
    burst: u32,
    tokens_milli: u64,
    last_ms: u64,

    pub fn init(now_ms: u64, rate_per_second: u32, burst: u32) TokenBucket {
        return .{ .rate_per_second = rate_per_second, .burst = burst, .tokens_milli = @as(u64, burst) * 1000, .last_ms = now_ms };
    }

    pub fn consume(self: *TokenBucket, now_ms: u64, amount: u32) bool {
        const elapsed = now_ms -| self.last_ms;
        self.last_ms = now_ms;
        self.tokens_milli = @min(
            @as(u64, self.burst) * 1000,
            self.tokens_milli + elapsed * self.rate_per_second,
        );
        const required = @as(u64, amount) * 1000;
        if (self.tokens_milli < required) return false;
        self.tokens_milli -= required;
        return true;
    }
};

pub const DeadlineConfig = struct {
    handshake_ms: u64 = 15_000,
    idle_ping_ms: u64 = 90_000,
    ping_grace_ms: u64 = 30_000,
};

pub const DeadlineAction = enum { none, send_ping, disconnect };

pub const Deadlines = struct {
    config: DeadlineConfig,
    connected_at: u64,
    last_rx: u64,
    ping_sent_at: ?u64 = null,
    registered: bool = false,

    pub fn init(now_ms: u64, config: DeadlineConfig) Deadlines {
        return .{ .config = config, .connected_at = now_ms, .last_rx = now_ms };
    }

    pub fn observeRx(self: *Deadlines, now_ms: u64) void {
        self.last_rx = now_ms;
        self.ping_sent_at = null;
    }

    pub fn markRegistered(self: *Deadlines) void {
        self.registered = true;
    }

    pub fn tick(self: *Deadlines, now_ms: u64) DeadlineAction {
        if (!self.registered and now_ms -| self.connected_at >= self.config.handshake_ms) return .disconnect;
        if (self.ping_sent_at) |sent| {
            if (now_ms -| sent >= self.config.ping_grace_ms) return .disconnect;
            return .none;
        }
        if (now_ms -| self.last_rx >= self.config.idle_ping_ms) {
            self.ping_sent_at = now_ms;
            return .send_ping;
        }
        return .none;
    }
};

pub const Backoff = struct {
    base_ms: u64 = 500,
    max_ms: u64 = 60_000,
    attempt: u6 = 0,
    random_state: u64,

    pub fn init(seed: u64) Backoff {
        return .{ .random_state = if (seed == 0) 0x9e3779b97f4a7c15 else seed };
    }

    pub fn reset(self: *Backoff) void {
        self.attempt = 0;
    }

    pub fn nextDelay(self: *Backoff) u64 {
        const shift: u6 = @min(self.attempt, 16);
        const cap = @min(self.max_ms, self.base_ms << shift);
        if (self.attempt < 63) self.attempt += 1;
        self.random_state ^= self.random_state << 13;
        self.random_state ^= self.random_state >> 7;
        self.random_state ^= self.random_state << 17;
        // Full jitter in [0, cap], avoiding synchronized reconnect storms.
        return self.random_state % (cap + 1);
    }
};

pub const ReconnectPhase = enum { idle, connecting, connected, waiting, canceled };

/// Pure scheduling state for an async connection owner. STS upgrades bypass
/// jitter and atomically replace the endpoint with verified TLS; ordinary
/// disconnects use full-jitter exponential backoff.
pub const ReconnectController = struct {
    phase: ReconnectPhase = .idle,
    port: u16,
    force_tls: bool = false,
    next_attempt_ms: u64 = 0,
    backoff: Backoff,

    pub fn init(port: u16, seed: u64) ReconnectController {
        return .{ .port = port, .backoff = .init(seed) };
    }

    pub fn start(self: *ReconnectController) bool {
        if (self.phase == .canceled or self.phase == .connecting) return false;
        self.phase = .connecting;
        return true;
    }

    pub fn connected(self: *ReconnectController) void {
        if (self.phase == .canceled) return;
        self.phase = .connected;
        self.backoff.reset();
    }

    pub fn disconnected(self: *ReconnectController, now_ms: u64) void {
        if (self.phase == .canceled) return;
        self.next_attempt_ms = now_ms +| self.backoff.nextDelay();
        self.phase = .waiting;
    }

    pub fn stsUpgrade(self: *ReconnectController, port: u16, now_ms: u64) !void {
        if (port == 0) return error.InvalidStsPort;
        if (self.phase == .canceled) return error.ReconnectCanceled;
        self.port = port;
        self.force_tls = true;
        self.next_attempt_ms = now_ms;
        self.phase = .waiting;
    }

    pub fn due(self: *ReconnectController, now_ms: u64) bool {
        if (self.phase != .waiting or now_ms < self.next_attempt_ms) return false;
        self.phase = .connecting;
        return true;
    }

    pub fn cancel(self: *ReconnectController) void {
        self.phase = .canceled;
    }
};

pub const AddressFamily = enum { ipv6, ipv4 };
pub const AddressCandidate = struct { index: usize, family: AddressFamily, start_after_ms: u64 };

/// RFC 8305-style interleave plan. Resolution and actual socket cancellation
/// remain transport responsibilities.
pub fn happyEyeballsPlan(
    out: *std.ArrayList(AddressCandidate),
    gpa: std.mem.Allocator,
    families: []const AddressFamily,
    delay_ms: u64,
) !void {
    var next_v6: usize = 0;
    var next_v4: usize = 0;
    var emitted: usize = 0;
    var prefer: AddressFamily = if (families.len != 0) families[0] else .ipv6;
    while (emitted < families.len) : (emitted += 1) {
        var found: ?usize = null;
        var at = if (prefer == .ipv6) next_v6 else next_v4;
        while (at < families.len) : (at += 1) if (families[at] == prefer) {
            found = at;
            break;
        };
        if (found == null) {
            prefer = if (prefer == .ipv6) .ipv4 else .ipv6;
            at = if (prefer == .ipv6) next_v6 else next_v4;
            while (at < families.len) : (at += 1) if (families[at] == prefer) {
                found = at;
                break;
            };
        }
        const index = found orelse break;
        if (prefer == .ipv6) next_v6 = index + 1 else next_v4 = index + 1;
        try out.append(gpa, .{ .index = index, .family = prefer, .start_after_ms = @as(u64, @intCast(emitted)) * delay_ms });
        prefer = if (prefer == .ipv6) .ipv4 else .ipv6;
    }
}

pub const RestoreTarget = struct {
    channel: []u8,
    key: ?[]u8 = null,
    after: ?[]u8 = null,
};

pub const Restoration = struct {
    pub const max_targets: usize = 256;
    gpa: std.mem.Allocator,
    targets: std.ArrayList(RestoreTarget) = .empty,

    pub fn init(gpa: std.mem.Allocator) Restoration {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Restoration) void {
        for (self.targets.items) |target| {
            self.gpa.free(target.channel);
            if (target.key) |value| self.gpa.free(value);
            if (target.after) |value| self.gpa.free(value);
        }
        self.targets.deinit(self.gpa);
        self.* = undefined;
    }

    pub fn remember(self: *Restoration, channel: []const u8, last_timestamp_or_msgid: ?[]const u8) !void {
        return self.rememberJoin(channel, "", last_timestamp_or_msgid);
    }

    /// Record an idempotent JOIN target. `key` is the optional channel
    /// password (`JOIN <room> <password>`), never a PRIVMSG payload.
    pub fn rememberJoin(self: *Restoration, channel: []const u8, key: []const u8, last_timestamp_or_msgid: ?[]const u8) !void {
        if (!validRestoreAtom(channel, false)) return error.InvalidRestoreTarget;
        if (key.len != 0 and !validRestoreAtom(key, true)) return error.InvalidRestoreTarget;
        if (last_timestamp_or_msgid) |reference| {
            if (!validRestoreAtom(reference, true) or
                (!std.mem.startsWith(u8, reference, "timestamp=") and !std.mem.startsWith(u8, reference, "msgid=")))
                return error.InvalidHistoryReference;
        }
        for (self.targets.items) |*target| {
            if (!std.ascii.eqlIgnoreCase(target.channel, channel)) continue;
            const replacement = if (last_timestamp_or_msgid) |value| try self.gpa.dupe(u8, value) else null;
            if (target.after) |old| self.gpa.free(old);
            target.after = replacement;
            if (key.len != 0) {
                const owned_key = try self.gpa.dupe(u8, key);
                if (target.key) |old| self.gpa.free(old);
                target.key = owned_key;
            }
            return;
        }
        if (self.targets.items.len >= max_targets) return error.RestoreBackpressure;
        const owned_channel = try self.gpa.dupe(u8, channel);
        errdefer self.gpa.free(owned_channel);
        const owned_key = if (key.len != 0) try self.gpa.dupe(u8, key) else null;
        errdefer if (owned_key) |value| self.gpa.free(value);
        const owned_after = if (last_timestamp_or_msgid) |value| try self.gpa.dupe(u8, value) else null;
        errdefer if (owned_after) |value| self.gpa.free(value);
        try self.targets.append(self.gpa, .{ .channel = owned_channel, .key = owned_key, .after = owned_after });
    }

    pub fn forget(self: *Restoration, channel: []const u8) void {
        for (self.targets.items, 0..) |target, index| {
            if (!std.ascii.eqlIgnoreCase(target.channel, channel)) continue;
            const removed = self.targets.orderedRemove(index);
            self.gpa.free(removed.channel);
            if (removed.key) |value| self.gpa.free(value);
            if (removed.after) |value| self.gpa.free(value);
            return;
        }
    }

    /// Idempotent restoration only: JOIN, explicit NAMES, then bounded history
    /// catch-up. Pending PRIVMSG content is intentionally absent.
    pub fn appendCommands(self: *const Restoration, out: *std.ArrayList(u8), gpa: std.mem.Allocator, history_limit: u16) !void {
        if (history_limit == 0) return error.InvalidHistoryLimit;
        for (self.targets.items) |target| {
            var join = message.Message{ .command = "JOIN" };
            join.params[0] = target.channel;
            if (target.key) |key| {
                join.params[1] = key;
                join.param_count = 2;
            } else {
                join.param_count = 1;
            }
            try message.write(out, gpa, join);
            var names = message.Message{ .command = "NAMES" };
            names.params[0] = target.channel;
            names.param_count = 1;
            try message.write(out, gpa, names);
            if (target.after) |after| {
                var limit_buffer: [8]u8 = undefined;
                const limit = try std.fmt.bufPrint(&limit_buffer, "{d}", .{history_limit});
                var history = message.Message{ .command = "CHATHISTORY" };
                history.params[0] = "AFTER";
                history.params[1] = target.channel;
                history.params[2] = after;
                history.params[3] = limit;
                history.param_count = 4;
                try message.write(out, gpa, history);
            }
        }
    }
};

pub const socks5 = struct {
    pub fn appendGreeting(out: *std.ArrayList(u8), gpa: std.mem.Allocator) !void {
        try out.appendSlice(gpa, &.{ 0x05, 0x01, 0x00 });
    }

    pub fn parseGreeting(reply: []const u8) !void {
        if (reply.len != 2 or reply[0] != 0x05 or reply[1] != 0x00) return error.ProxyAuthenticationRequired;
    }

    pub fn appendConnect(out: *std.ArrayList(u8), gpa: std.mem.Allocator, host: []const u8, port: u16) !void {
        if (host.len == 0 or host.len > 255 or std.mem.indexOfScalar(u8, host, 0) != null) return error.InvalidProxyTarget;
        try out.appendSlice(gpa, &.{ 0x05, 0x01, 0x00, 0x03 });
        try out.append(gpa, @intCast(host.len));
        try out.appendSlice(gpa, host);
        try out.append(gpa, @intCast(port >> 8));
        try out.append(gpa, @intCast(port & 0xff));
    }

    pub fn parseConnectPrefix(reply: []const u8) !void {
        if (reply.len < 4 or reply[0] != 0x05 or reply[1] != 0x00 or reply[2] != 0x00)
            return error.ProxyConnectFailed;
    }
};

pub const http_connect = struct {
    pub fn appendRequest(out: *std.ArrayList(u8), gpa: std.mem.Allocator, host: []const u8, port: u16) !void {
        if (host.len == 0 or std.mem.indexOfAny(u8, host, " \r\n\x00") != null) return error.InvalidProxyTarget;
        if (std.mem.indexOfScalar(u8, host, ':') != null and host[0] != '[') {
            try out.print(gpa, "CONNECT [{s}]:{d} HTTP/1.1\r\nHost: [{s}]:{d}\r\nProxy-Connection: Keep-Alive\r\n\r\n", .{ host, port, host, port });
        } else {
            try out.print(gpa, "CONNECT {s}:{d} HTTP/1.1\r\nHost: {s}:{d}\r\nProxy-Connection: Keep-Alive\r\n\r\n", .{ host, port, host, port });
        }
    }

    pub fn parseResponse(headers: []const u8) !void {
        const end = std.mem.indexOf(u8, headers, "\r\n") orelse return error.InvalidProxyResponse;
        const status = headers[0..end];
        if (!std.mem.startsWith(u8, status, "HTTP/1.1 2") and !std.mem.startsWith(u8, status, "HTTP/1.0 2"))
            return error.ProxyConnectFailed;
    }
};

fn validRestoreAtom(value: []const u8, allow_equals: bool) bool {
    if (value.len == 0 or value.len > 510 or std.mem.indexOfAny(u8, value, " \r\n\x00") != null) return false;
    if (!allow_equals and value[0] == ':') return false;
    return true;
}

test "priority queue bypasses flood control and never replays uncertain chat" {
    const gpa = std.testing.allocator;
    var queue = TxQueue.init(gpa, .{}, 0, 1, 1);
    defer queue.deinit();
    try queue.enqueue("PRIVMSG #c one\r\n", .interactive, false, false);
    try queue.enqueue("AUTHENTICATE +\r\n", .control, false, true);
    try std.testing.expectEqualStrings("AUTHENTICATE +\r\n", queue.peek(0).?.bytes);
    queue.confirmSent(queue.peek(0).?.index);
    const chat = queue.peek(0).?;
    queue.markUncertain(chat.index);
    try std.testing.expect(queue.peek(0) == null);
}

test "bounded queues and token bucket are deterministic under faults" {
    const gpa = std.testing.allocator;
    var tx = TxQueue.init(gpa, .{ .tx_messages = 1, .tx_bytes = 8 }, 0, 1, 1);
    defer tx.deinit();
    try tx.enqueue("1234", .bulk, true, false);
    try std.testing.expectError(error.TxBackpressure, tx.enqueue("x", .bulk, true, false));
    _ = tx.peek(0).?;
    tx.confirmSent(0);
    try tx.enqueue("next", .bulk, true, false);
    try std.testing.expect(tx.peek(999) == null);
    try std.testing.expect(tx.peek(1000) != null);

    var rx = RxQueue.init(gpa, .{ .rx_messages = 1, .rx_bytes = 4 });
    defer rx.deinit();
    try rx.push("1234");
    try std.testing.expectError(error.RxBackpressure, rx.push("x"));
    gpa.free(rx.pop().?);
}

test "handshake idle and ping deadlines fail closed" {
    var handshake = Deadlines.init(100, .{ .handshake_ms = 50 });
    try std.testing.expectEqual(DeadlineAction.none, handshake.tick(149));
    try std.testing.expectEqual(DeadlineAction.disconnect, handshake.tick(150));

    var idle = Deadlines.init(0, .{ .idle_ping_ms = 100, .ping_grace_ms = 25 });
    idle.markRegistered();
    try std.testing.expectEqual(DeadlineAction.send_ping, idle.tick(100));
    try std.testing.expectEqual(DeadlineAction.disconnect, idle.tick(125));

    var responsive = Deadlines.init(0, .{ .idle_ping_ms = 100, .ping_grace_ms = 25 });
    responsive.markRegistered();
    try std.testing.expectEqual(DeadlineAction.send_ping, responsive.tick(100));
    responsive.observeRx(110);
    try std.testing.expectEqual(DeadlineAction.none, responsive.tick(209));
    try std.testing.expectEqual(DeadlineAction.send_ping, responsive.tick(210));
}

test "queue and backoff stress remain within hard limits" {
    const gpa = std.testing.allocator;
    var queue = TxQueue.init(gpa, .{}, 0, 1000, 512);
    defer queue.deinit();
    for (0..512) |_| try queue.enqueue("PRIVMSG #c :bounded\r\n", .interactive, false, false);
    try std.testing.expectError(error.TxBackpressure, queue.enqueue("overflow", .interactive, false, false));
    try std.testing.expect(queue.bytes <= queue.limits.tx_bytes);

    var backoff = Backoff.init(0x1234);
    for (0..10_000) |_| try std.testing.expect(backoff.nextDelay() <= backoff.max_ms);
}

test "reconnect scheduling is bounded cancellable and STS upgrades immediately" {
    var reconnect = ReconnectController.init(6667, 42);
    try std.testing.expect(reconnect.start());
    reconnect.connected();
    reconnect.disconnected(1_000);
    try std.testing.expect(reconnect.next_attempt_ms >= 1_000);
    try std.testing.expect(reconnect.next_attempt_ms <= 1_500);
    try std.testing.expect(!reconnect.due(reconnect.next_attempt_ms - 1));
    try std.testing.expect(reconnect.due(reconnect.next_attempt_ms));
    try reconnect.stsUpgrade(6697, 2_000);
    try std.testing.expect(reconnect.force_tls);
    try std.testing.expectEqual(@as(u16, 6697), reconnect.port);
    try std.testing.expect(reconnect.due(2_000));
    reconnect.cancel();
    try std.testing.expect(!reconnect.start());
    try std.testing.expectError(error.ReconnectCanceled, reconnect.stsUpgrade(7000, 3_000));
}

test "reconnect jitter, happy eyeballs, restore, and proxy codecs" {
    const gpa = std.testing.allocator;
    var a = Backoff.init(42);
    var b = Backoff.init(42);
    try std.testing.expectEqual(a.nextDelay(), b.nextDelay());
    try std.testing.expect(a.nextDelay() <= 1000);

    var plan: std.ArrayList(AddressCandidate) = .empty;
    defer plan.deinit(gpa);
    try happyEyeballsPlan(&plan, gpa, &.{ .ipv6, .ipv6, .ipv4, .ipv4 }, 250);
    try std.testing.expectEqual(AddressFamily.ipv6, plan.items[0].family);
    try std.testing.expectEqual(AddressFamily.ipv4, plan.items[1].family);
    try std.testing.expectEqual(@as(u64, 250), plan.items[1].start_after_ms);

    var restore = Restoration.init(gpa);
    defer restore.deinit();
    try restore.remember("#comic", "timestamp=2026-07-16T00:00:00.000Z");
    try restore.rememberJoin("#locked", "swordfish", null);
    try std.testing.expectError(error.InvalidRestoreTarget, restore.remember("#comic\r\nOPER root", null));
    try std.testing.expectError(error.InvalidRestoreTarget, restore.rememberJoin("#locked", "bad\r\nOPER", null));
    try std.testing.expectError(error.InvalidHistoryReference, restore.remember("#comic", "timestamp=x\r\nPRIVMSG #c pwn"));
    var commands: std.ArrayList(u8) = .empty;
    defer commands.deinit(gpa);
    try restore.appendCommands(&commands, gpa, 100);
    try std.testing.expect(std.mem.indexOf(u8, commands.items, "PRIVMSG") == null);
    try std.testing.expect(std.mem.indexOf(u8, commands.items, "CHATHISTORY AFTER") != null);
    try std.testing.expect(std.mem.indexOf(u8, commands.items, "JOIN #locked swordfish") != null);
    restore.forget("#locked");
    commands.clearRetainingCapacity();
    try restore.appendCommands(&commands, gpa, 100);
    try std.testing.expect(std.mem.indexOf(u8, commands.items, "JOIN #locked") == null);

    var wire: std.ArrayList(u8) = .empty;
    defer wire.deinit(gpa);
    try socks5.appendGreeting(&wire, gpa);
    try std.testing.expectEqualSlices(u8, &.{ 5, 1, 0 }, wire.items);
    try socks5.parseGreeting(&.{ 5, 0 });
    wire.clearRetainingCapacity();
    try http_connect.appendRequest(&wire, gpa, "irc.example", 6697);
    try http_connect.parseResponse("HTTP/1.1 200 Connection established\r\n\r\n");
    wire.clearRetainingCapacity();
    try http_connect.appendRequest(&wire, gpa, "2001:db8::1", 6697);
    try std.testing.expect(std.mem.startsWith(u8, wire.items, "CONNECT [2001:db8::1]:6697"));
}
