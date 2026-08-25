//! High-level IRC client: ties the transport, line framer, and command
//! builders together, with automatic PING/PONG keepalive.
//!
//! The message-handling decision (`autoRespond`) is a pure function tested
//! without a socket; `Client` is the live glue over `Transport`.

const std = @import("std");
const irc = @import("irc.zig");
const ircv3 = @import("ircv3.zig");
const sasl = @import("sasl.zig");
const features_mod = @import("features.zig");
const irc_map = @import("irc_map.zig");
const policy = @import("connection_policy.zig");
const sts_store = @import("sts_store.zig");
const session_store = @import("session_store.zig");
const message = @import("message.zig");
const transport = @import("transport.zig");
const dcc = @import("../proto/dcc.zig");
const Transport = transport.Transport;

pub const Message = message.Message;
pub const ConnectOptions = transport.ConnectOptions;
pub const Security = transport.Security;
pub const TypingStatus = enum { active, paused, done };
pub const PinsOperation = enum { list, add, delete, clear };
pub const MonitorOperation = enum { add, remove, clear, list, status };
pub const SilenceOperation = enum { list, add, remove };
pub const AcceptOperation = enum { list, add, remove };

const desired_without_sasl = blk: {
    var names: [ircv3.default_desired_capabilities.len - 1][]const u8 = undefined;
    var at: usize = 0;
    for (ircv3.default_desired_capabilities) |name| {
        if (!std.mem.eql(u8, name, "sasl")) {
            names[at] = name;
            at += 1;
        }
    }
    break :blk names;
};

pub const RegistrationOptions = struct {
    want_ircx: bool = true,
    credentials: ?*sasl.Credentials = null,
    sasl_preference: []const sasl.Mechanism = &sasl.default_preference,
    /// Required when SASL is enabled so SCRAM nonces come from the platform
    /// CSPRNG. Kept optional for registrations which do not authenticate.
    io: ?std.Io = null,
    sts: ?*sts_store.Store = null,
    session: ?*session_store.Store = null,
    session_path: ?[]const u8 = null,
    now_seconds: u64 = 0,
};

/// If `msg` requires an automatic protocol reply (currently just PING→PONG),
/// append it to `out` and return true.
pub fn autoRespond(
    out: *std.ArrayList(u8),
    gpa: std.mem.Allocator,
    msg: Message,
) !bool {
    if (std.ascii.eqlIgnoreCase(msg.command, "PING")) {
        try irc.writePong(out, gpa, msg.param(0) orelse "");
        return true;
    }
    return false;
}

const Registration = struct {
    cap: ircv3.Session,
    sasl_session: ?sasl.Session = null,
    credentials: ?*sasl.Credentials,
    sasl_preference: []const sasl.Mechanism,
    io: ?std.Io,
    store: ?*sts_store.Store,
    session: ?*session_store.Store,
    session_path: ?[]const u8,
    now_seconds: u64,
    security: Security,
    host: []const u8,
    want_ircx: bool,
    ircx_probe_sent: bool = false,
    ircx_enable_sent: bool = false,
    done: bool = false,
    authenticated: bool = false,
    session_commands_sent: bool = false,
    nick_sent: bool = false,
    nick_storage: ?[]u8 = null,
    user_storage: ?[]u8 = null,
    realname_storage: ?[]u8 = null,
    nonce: [24]u8 = undefined,

    fn init(
        gpa: std.mem.Allocator,
        host: []const u8,
        security: Security,
        options: RegistrationOptions,
    ) Registration {
        return .{
            .cap = ircv3.Session.init(gpa, .{
                .desired = if (options.credentials != null)
                    &ircv3.default_desired_capabilities
                else
                    &desired_without_sasl,
            }),
            .credentials = options.credentials,
            .sasl_preference = options.sasl_preference,
            .io = options.io,
            .store = options.sts,
            .session = options.session,
            .session_path = options.session_path,
            .now_seconds = options.now_seconds,
            .security = security,
            .host = host,
            .want_ircx = options.want_ircx,
        };
    }

    fn deinit(self: *Registration) void {
        if (self.sasl_session) |*session| session.deinit();
        if (self.nick_storage) |storage| self.cap.gpa.free(storage);
        if (self.user_storage) |storage| self.cap.gpa.free(storage);
        if (self.realname_storage) |storage| self.cap.gpa.free(storage);
        self.cap.deinit();
        if (self.credentials) |credentials| {
            if (!credentials.zeroized) credentials.zeroize();
        }
        self.* = undefined;
    }

    fn consume(
        self: *Registration,
        out: *std.ArrayList(u8),
        msg: *const Message,
        sts_upgrade_port: *?u16,
    ) !bool {
        if (self.want_ircx and self.ircx_probe_sent and
            std.mem.eql(u8, msg.command, "800") and msg.param_count >= 2)
        {
            if (std.mem.eql(u8, msg.params[1], "0") and !self.ircx_enable_sent) {
                try irc.writeIrcx(out, self.cap.gpa);
                self.ircx_enable_sent = true;
                return true;
            }
            // State one must reach the application so it can select DATA for
            // Comic Chat annotations and comment controls.
            if (std.mem.eql(u8, msg.params[1], "1")) return false;
        }

        if (std.ascii.eqlIgnoreCase(msg.command, "CAP")) {
            const event = try self.cap.handle(out, msg.*);
            try self.applySts(sts_upgrade_port);
            try self.handleCapEvent(out, event);
            return true;
        }

        if (!self.done and std.mem.eql(u8, msg.command, "421") and
            msg.param(1) != null and std.ascii.eqlIgnoreCase(msg.param(1).?, "CAP"))
        {
            try self.finish(out);
            return true;
        }

        if (self.sasl_session) |*session| {
            if (std.ascii.eqlIgnoreCase(msg.command, "AUTHENTICATE") or isSaslNumeric(msg.command)) {
                // After CAP/SASL finishes, later 90x replies are session
                // events (reauth failure, logout) and must reach the app.
                if (self.done) return false;
                const event = session.handle(out, msg.*) catch |err| switch (err) {
                    error.ServerSignatureMismatch => {
                        const cap_event = try self.cap.saslComplete(out);
                        try self.handleCapEvent(out, cap_event);
                        return true;
                    },
                    else => return err,
                };
                switch (event) {
                    .succeeded, .already_authenticated => {
                        self.authenticated = true;
                        const cap_event = try self.cap.saslComplete(out);
                        try self.handleCapEvent(out, cap_event);
                    },
                    .failed => {
                        const cap_event = try self.cap.saslComplete(out);
                        try self.handleCapEvent(out, cap_event);
                    },
                    else => {},
                }
                return true;
            }
        }

        // Onyx may still emit 433/437 while a second same-account attachment
        // is waiting for 001 + SESSION RESUME. Do not surface that as a
        // hard nick failure when a reusable credential is ready.
        if (self.authenticated and !self.session_commands_sent and self.hasResumeToken() and
            (std.mem.eql(u8, msg.command, "433") or std.mem.eql(u8, msg.command, "437")))
            return true;

        return false;
    }

    fn handleCapEvent(self: *Registration, out: *std.ArrayList(u8), event: ircv3.Event) !void {
        switch (event) {
            .sasl_ready => if (self.credentials) |credentials| {
                if (self.security == .plaintext) {
                    credentials.zeroize();
                    const completed = try self.cap.saslComplete(out);
                    try self.handleCapEvent(out, completed);
                    return;
                }
                if (self.sasl_session) |*old| old.deinit();
                self.sasl_session = sasl.Session.init(self.cap.gpa, credentials, .{ .preference = self.sasl_preference });
                const capability = self.cap.offered.get("sasl");
                self.sasl_session.?.setAdvertisement(if (capability) |entry| entry.value else null);
                var random: [18]u8 = undefined;
                try std.Io.randomSecure(self.io orelse return error.SecureRandomUnavailable, &random);
                defer std.crypto.secureZero(u8, &random);
                _ = std.base64.standard.Encoder.encode(&self.nonce, &random);
                _ = self.sasl_session.?.start(out, &self.nonce) catch |err| switch (err) {
                    error.NoSupportedMechanism => {
                        credentials.zeroize();
                        const completed = try self.cap.saslComplete(out);
                        try self.handleCapEvent(out, completed);
                        return;
                    },
                    else => return err,
                };
            } else {
                const completed = try self.cap.saslComplete(out);
                try self.handleCapEvent(out, completed);
            },
            .complete => try self.finish(out),
            else => {},
        }
    }

    fn finish(self: *Registration, out: *std.ArrayList(u8)) !void {
        if (self.done) return;
        if (self.want_ircx and !self.ircx_probe_sent) {
            try irc.writeIrcxProbe(out, self.cap.gpa);
            self.ircx_probe_sent = true;
        }
        try emitRegisterIdentity(self, out, self.cap.gpa);
        if (self.credentials) |credentials| {
            if (self.sasl_session == null and !credentials.zeroized) credentials.zeroize();
        }
        self.done = true;
    }

    fn applySts(self: *Registration, upgrade_port: *?u16) !void {
        const update = self.cap.takeStsPolicyUpdate(switch (self.security) {
            .plaintext => .plaintext,
            .tls => .tls_verified,
        });
        switch (update) {
            .none, .invalid => {},
            .upgrade_port => |port| {
                upgrade_port.* = port;
                return error.StsUpgradeRequired;
            },
            .persistence => |policy_value| if (self.store) |store| {
                try store.update(self.host, policy_value.duration_seconds, self.currentNowSeconds());
            },
        }
    }

    fn currentNowSeconds(self: *const Registration) u64 {
        if (self.io) |io| {
            const wall = std.Io.Clock.real.now(io).toSeconds();
            if (wall > 0) return @intCast(wall);
        }
        return self.now_seconds;
    }

    fn hasResumeToken(self: *const Registration) bool {
        const store = self.session orelse return false;
        return store.resumeToken(self.currentNowSeconds()) != null;
    }

    fn sendSessionCommands(self: *Registration, out: *std.ArrayList(u8)) !bool {
        if (self.session_commands_sent or !self.authenticated) return false;
        self.session_commands_sent = true;
        if (self.session) |store| if (store.resumeToken(self.currentNowSeconds())) |token| {
            try out.appendSlice(self.cap.gpa, "SESSION RESUME ");
            try out.appendSlice(self.cap.gpa, token);
            try out.appendSlice(self.cap.gpa, "\r\n");
        };
        try out.appendSlice(self.cap.gpa, "SESSION TOKEN\r\n");
        try out.appendSlice(self.cap.gpa, "SESSIONTOKEN\r\n");
        return true;
    }

    fn observeSessionCredential(self: *Registration, msg: Message) !void {
        const store = self.session orelse return;
        if (!try store.observe(msg)) return;
        if (self.session_path) |path| try store.saveFile(self.io orelse return, path);
    }
};

fn rememberRegisterIdentity(
    registration: *Registration,
    gpa: std.mem.Allocator,
    nick: []const u8,
    user: []const u8,
    realname: []const u8,
) !void {
    const owned_nick = try gpa.dupe(u8, nick);
    errdefer gpa.free(owned_nick);
    const owned_user = try gpa.dupe(u8, user);
    errdefer gpa.free(owned_user);
    const owned_realname = try gpa.dupe(u8, realname);
    errdefer gpa.free(owned_realname);
    if (registration.nick_storage) |old| gpa.free(old);
    if (registration.user_storage) |old| gpa.free(old);
    if (registration.realname_storage) |old| gpa.free(old);
    registration.nick_storage = owned_nick;
    registration.user_storage = owned_user;
    registration.realname_storage = owned_realname;
}

fn emitRegisterIdentity(registration: *Registration, out: *std.ArrayList(u8), gpa: std.mem.Allocator) !void {
    if (registration.nick_sent) return;
    const nick = registration.nick_storage orelse return;
    const user = registration.user_storage orelse return;
    const realname = registration.realname_storage orelse return;
    try irc.writeNick(out, gpa, nick);
    try irc.writeUser(out, gpa, user, realname);
    registration.nick_sent = true;
}

fn appendRegistrationStart(
    registration: *Registration,
    out: *std.ArrayList(u8),
    gpa: std.mem.Allocator,
    nick: []const u8,
    user: []const u8,
    realname: []const u8,
) !void {
    // Microsoft probes before it sends NICK/USER (ircsock.cpp:1048-1053).
    // Do the same ahead of modern CAP negotiation so an IRCX server can
    // complete both numeric 800 phases before the first room JOIN.
    if (registration.want_ircx) {
        try irc.writeIrcxProbe(out, gpa);
        registration.ircx_probe_sent = true;
    }
    try registration.cap.begin(out);
    try rememberRegisterIdentity(registration, gpa, nick, user, realname);
    // When SASL credentials are present, wait for CAP END so the reserved
    // account nick is claimed after AUTHENTICATE rather than racing 433.
    if (registration.credentials == null) try emitRegisterIdentity(registration, out, gpa);
}

fn isSaslNumeric(command: []const u8) bool {
    if (command.len != 3 or command[0] != '9' or command[1] != '0') return false;
    return command[2] >= '0' and command[2] <= '8';
}

pub const Client = struct {
    gpa: std.mem.Allocator,
    transport: *Transport,
    host: []u8,
    port: u16,
    connect_options: ConnectOptions,
    framer: irc.LineFramer,
    out: std.ArrayList(u8) = .empty,
    tx: policy.TxQueue,
    deadlines: policy.Deadlines,
    policy_now_ms: u64 = 0,
    policy_started_ms: u64 = 0,
    registration: ?Registration = null,
    features: ?features_mod.State = null,
    aggregator: features_mod.Aggregator,
    logical_line: ?[]u8 = null,
    sts_upgrade_port: ?u16 = null,
    typing_targets: std.ArrayList(TypingTarget) = .empty,
    restoration: ?policy.Restoration = null,
    quit_requested: bool = false,
    rx: [8192]u8 = undefined,

    pub fn connect(gpa: std.mem.Allocator, host: []const u8, port: u16) !Client {
        return connectWithOptions(gpa, host, port, .{});
    }

    pub fn connectWithOptions(
        gpa: std.mem.Allocator,
        host: []const u8,
        port: u16,
        options: ConnectOptions,
    ) !Client {
        const connected = try Transport.connectWithOptions(gpa, host, port, options);
        errdefer connected.deinit();
        return fromTransport(gpa, host, port, options, connected);
    }

    /// Bind a completed async transport to the protocol client. Ownership of
    /// `connected` transfers on success and remains with the caller on error.
    pub fn fromTransport(
        gpa: std.mem.Allocator,
        host: []const u8,
        port: u16,
        options: ConnectOptions,
        connected: *Transport,
    ) !Client {
        const owned_host = try gpa.dupe(u8, host);
        errdefer gpa.free(owned_host);
        return .{
            .gpa = gpa,
            .transport = connected,
            .host = owned_host,
            .port = port,
            .connect_options = options,
            .framer = irc.LineFramer.init(gpa),
            .tx = policy.TxQueue.init(gpa, .{}, 0, 2, 4),
            .deadlines = policy.Deadlines.init(0, .{}),
            .aggregator = features_mod.Aggregator.init(gpa, .{}),
        };
    }

    pub fn deinit(self: *Client) void {
        if (self.registration) |*registration| {
            if (registration.store) |store| {
                const elapsed_seconds = (self.policy_now_ms -| self.policy_started_ms) / 1000;
                store.rescheduleOnDisconnect(self.host, registration.currentNowSeconds() +| elapsed_seconds);
            }
            registration.deinit();
        }
        if (self.features) |*state| state.deinit();
        if (self.restoration) |*restoration| restoration.deinit();
        self.aggregator.deinit();
        self.tx.deinit();
        for (self.typing_targets.items) |entry| self.gpa.free(entry.target);
        self.typing_targets.deinit(self.gpa);
        if (self.logical_line) |line| self.gpa.free(line);
        self.framer.deinit();
        sasl.secureClear(&self.out);
        self.out.deinit(self.gpa);
        self.transport.deinit();
        self.gpa.free(self.host);
    }

    fn queueOut(self: *Client, priority: policy.Priority, replay_safe: bool, sensitive: bool) !void {
        if (self.out.items.len == 0) return;
        errdefer if (sensitive) sasl.secureClear(&self.out);
        try self.tx.enqueue(self.out.items, priority, replay_safe, sensitive);
        if (sensitive) sasl.secureClear(&self.out) else self.out.clearRetainingCapacity();
        try self.drainTx();
    }

    fn drainTx(self: *Client) !void {
        // Keep native event loops responsive even when a reconnect restores a
        // large control backlog.  The queue remains priority ordered and the
        // next tick continues draining without dropping replay-safe traffic.
        var writes: usize = 0;
        const max_writes_per_tick = 16;
        while (writes < max_writes_per_tick) {
            const next_item = self.tx.peek(self.policy_now_ms) orelse break;
            self.transport.send(next_item.bytes) catch |err| {
                self.tx.markUncertain(next_item.index);
                return err;
            };
            self.tx.confirmSent(next_item.index);
            writes += 1;
        }
    }

    pub fn tick(self: *Client, now_ms: u64) !void {
        if (self.policy_started_ms == 0) {
            self.policy_started_ms = now_ms;
            self.deadlines = policy.Deadlines.init(now_ms, .{});
        }
        self.policy_now_ms = now_ms;
        try self.drainTx();
        switch (self.deadlines.tick(now_ms)) {
            .none => {},
            .send_ping => {
                try self.out.appendSlice(self.gpa, "PING :comicchat-keepalive\r\n");
                try self.queueOut(.control, false, false);
            },
            .disconnect => return error.ConnectionDeadlineExceeded,
        }
    }

    pub fn register(
        self: *Client,
        nick: []const u8,
        user: []const u8,
        realname: []const u8,
        want_ircx: bool,
    ) !void {
        return self.registerWithOptions(nick, user, realname, .{ .want_ircx = want_ircx });
    }

    /// Start registration without waiting. CAP/SASL advances as receive calls
    /// feed messages through bufferedNext/next.
    pub fn registerWithOptions(
        self: *Client,
        nick: []const u8,
        user: []const u8,
        realname: []const u8,
        options: RegistrationOptions,
    ) !void {
        if (self.registration != null) return error.RegistrationAlreadyStarted;
        self.registration = Registration.init(self.gpa, self.host, self.connect_options.security, options);
        errdefer {
            self.registration.?.deinit();
            self.registration = null;
        }
        self.features = try features_mod.State.init(self.gpa, nick, .{});
        errdefer {
            self.features.?.deinit();
            self.features = null;
        }
        try appendRegistrationStart(&self.registration.?, &self.out, self.gpa, nick, user, realname);
        try self.queueOut(.control, false, false);
    }

    pub fn join(self: *Client, channel: []const u8) !void {
        return self.joinWithKey(channel, "");
    }

    /// Source `ChatJoinAux` emits `JOIN <room> <password>` when the Enter Room
    /// dialog supplies its optional password.
    pub fn joinWithKey(self: *Client, channel: []const u8, key: []const u8) !void {
        try self.rejectSessionLimits(channel, key);
        if (key.len == 0)
            try self.appendCommand("JOIN", &.{channel})
        else
            try self.appendCommand("JOIN", &.{ channel, key });
        if (self.capabilityEnabled("no-implicit-names") or self.capabilityEnabled("draft/no-implicit-names"))
            try self.appendCommand("NAMES", &.{channel});
        try self.ownedRestoration().rememberJoin(channel, key, null);
        try self.queueOut(.interactive, true, false);
    }

    /// Microsoft IRCX `ChatCreateAux` wire order is
    /// `CREATE <room> [creation-modes] [limit] [password]`.
    pub fn create(self: *Client, channel: []const u8, creation_modes: []const u8, limit: []const u8, key: []const u8) !void {
        try self.rejectSessionLimits(channel, key);
        var params: [4][]const u8 = undefined;
        var count: usize = 0;
        params[count] = channel;
        count += 1;
        for ([_][]const u8{ creation_modes, limit, key }) |value| {
            if (value.len == 0) continue;
            params[count] = value;
            count += 1;
        }
        try self.appendCommand("CREATE", params[0..count]);
        try self.ownedRestoration().rememberJoin(channel, key, null);
        try self.queueOut(.interactive, true, false);
    }

    pub fn quit(self: *Client, reason: []const u8) !void {
        self.quit_requested = true;
        if (reason.len == 0)
            try self.appendCommand("QUIT", &.{})
        else {
            try self.validateOutgoingText(reason);
            try self.appendCommandTrailing("QUIT", &.{reason});
        }
        try self.queueOut(.control, true, false);
    }

    pub fn part(self: *Client, channel: []const u8) !void {
        return self.partReason(channel, "");
    }

    pub fn partReason(self: *Client, channel: []const u8, reason: []const u8) !void {
        if (reason.len == 0) {
            try self.appendCommand("PART", &.{channel});
        } else {
            try self.validateOutgoingText(reason);
            try self.appendCommandTrailing("PART", &.{ channel, reason });
        }
        if (self.restoration) |*restoration| restoration.forget(channel);
        try self.queueOut(.interactive, true, false);
    }

    pub fn changeNick(self: *Client, nick: []const u8) !void {
        const limits = self.advertisedLimits();
        if (irc_map.SessionLimits.exceeds(limits.nicklen, nick)) return error.InvalidIrcParameter;
        try self.appendCommand("NICK", &.{nick});
        try self.queueOut(.interactive, true, false);
    }

    pub fn setAway(self: *Client, message_text: []const u8) !void {
        const clipped = irc_map.SessionLimits.clip(self.advertisedLimits().awaylen, message_text);
        if (clipped.len == 0) {
            try self.appendCommand("AWAY", &.{});
        } else {
            try self.validateOutgoingText(clipped);
            try self.appendCommandTrailing("AWAY", &.{clipped});
        }
        try self.queueOut(.interactive, true, false);
    }

    pub fn kick(self: *Client, channel: []const u8, nick: []const u8, reason: []const u8) !void {
        // The source always includes the trailing reason, including an empty
        // one: `KICK <room> <nick> :<reason>`.
        const clipped = irc_map.SessionLimits.clip(self.advertisedLimits().kicklen, reason);
        try self.validateOutgoingText(clipped);
        try self.appendCommandTrailing("KICK", &.{ channel, nick, clipped });
        try self.queueOut(.interactive, true, false);
    }

    pub fn invite(self: *Client, nick: []const u8, channel: []const u8) !void {
        try self.appendCommand("INVITE", &.{ nick, channel });
        try self.queueOut(.interactive, true, false);
    }

    pub fn setBan(self: *Client, channel: []const u8, mask: []const u8) !void {
        try self.appendCommand("MODE", &.{ channel, "+b", mask });
        try self.queueOut(.interactive, true, false);
    }

    pub fn clearBan(self: *Client, channel: []const u8, mask: []const u8) !void {
        try self.appendCommand("MODE", &.{ channel, "-b", mask });
        try self.queueOut(.interactive, true, false);
    }

    pub fn listBans(self: *Client, channel: []const u8) !void {
        try self.appendCommand("MODE", &.{ channel, "+b" });
        try self.queueOut(.interactive, true, false);
    }

    pub fn setException(self: *Client, channel: []const u8, mask: []const u8) !void {
        try self.appendListMode(channel, '+', self.exceptsLetter(), mask);
    }

    pub fn clearException(self: *Client, channel: []const u8, mask: []const u8) !void {
        try self.appendListMode(channel, '-', self.exceptsLetter(), mask);
    }

    pub fn listExceptions(self: *Client, channel: []const u8) !void {
        try self.appendListMode(channel, '+', self.exceptsLetter(), null);
    }

    pub fn setInviteMask(self: *Client, channel: []const u8, mask: []const u8) !void {
        try self.appendListMode(channel, '+', self.invexLetter(), mask);
    }

    pub fn clearInviteMask(self: *Client, channel: []const u8, mask: []const u8) !void {
        try self.appendListMode(channel, '-', self.invexLetter(), mask);
    }

    pub fn listInviteMasks(self: *Client, channel: []const u8) !void {
        try self.appendListMode(channel, '+', self.invexLetter(), null);
    }

    pub fn setTopic(self: *Client, channel: []const u8, topic: []const u8) !void {
        const clipped = irc_map.SessionLimits.clip(self.advertisedLimits().topiclen, topic);
        try self.validateOutgoingText(clipped);
        try self.appendCommandTrailing("TOPIC", &.{ channel, clipped });
        try self.queueOut(.interactive, true, false);
    }

    /// IRCv3 `SETNAME :<realname>` when the `setname` capability is ACK'd.
    pub fn setName(self: *Client, realname: []const u8) !void {
        try self.requireCapability("setname");
        if (realname.len == 0) return error.InvalidIrcParameter;
        try self.validateOutgoingText(realname);
        try self.appendCommandTrailing("SETNAME", &.{realname});
        try self.queueOut(.interactive, true, false);
    }

    pub fn knock(self: *Client, channel: []const u8, reason: ?[]const u8) !void {
        if (!isChannelTarget(channel)) return error.InvalidIrcParameter;
        if (reason) |text| {
            try self.validateOutgoingText(text);
            try self.appendCommandTrailing("KNOCK", &.{ channel, text });
        } else try self.appendCommand("KNOCK", &.{channel});
        try self.queueOut(.interactive, true, false);
    }

    pub fn renameChannel(self: *Client, old_channel: []const u8, new_channel: []const u8, reason: ?[]const u8) !void {
        if (!isChannelTarget(old_channel) or !isChannelTarget(new_channel)) return error.InvalidIrcParameter;
        if (reason) |text| {
            try self.validateOutgoingText(text);
            try self.appendCommandTrailing("RENAME", &.{ old_channel, new_channel, text });
        } else try self.appendCommand("RENAME", &.{ old_channel, new_channel });
        try self.queueOut(.interactive, true, false);
    }

    pub fn tempModeAdd(self: *Client, channel: []const u8, flag: []const u8, parameter: ?[]const u8, duration_seconds: u32) !void {
        if (!isChannelTarget(channel) or !validIrcAtom(flag) or duration_seconds == 0) return error.InvalidIrcParameter;
        var duration: [10]u8 = undefined;
        const text = try std.fmt.bufPrint(&duration, "{d}", .{duration_seconds});
        if (parameter) |value| {
            if (!validIrcAtom(value)) return error.InvalidIrcParameter;
            try self.appendCommand("TEMPMODE", &.{ "ADD", channel, flag, value, text });
        } else try self.appendCommand("TEMPMODE", &.{ "ADD", channel, flag, text });
        try self.queueOut(.interactive, true, false);
    }

    pub fn tempModeCancel(self: *Client, channel: []const u8, flag: []const u8, parameter: ?[]const u8) !void {
        if (!isChannelTarget(channel) or !validIrcAtom(flag)) return error.InvalidIrcParameter;
        if (parameter) |value| {
            if (!validIrcAtom(value)) return error.InvalidIrcParameter;
            try self.appendCommand("TEMPMODE", &.{ "CANCEL", channel, flag, value });
        } else try self.appendCommand("TEMPMODE", &.{ "CANCEL", channel, flag });
        try self.queueOut(.interactive, true, false);
    }

    pub fn tempModeSweep(self: *Client) !void {
        try self.appendCommand("TEMPMODE", &.{"SWEEP"});
        try self.queueOut(.interactive, true, false);
    }

    /// Onyx `CLEAR <#channel> USERS [KEEP <rank>] [ALLOW <accounts>] [:reason]`.
    pub fn clearChannelUsers(self: *Client, channel: []const u8, keep_rank: ?[]const u8, allow_accounts: ?[]const u8, reason: ?[]const u8) !void {
        if (!isChannelTarget(channel)) return error.InvalidIrcParameter;
        var params: [7][]const u8 = undefined;
        var count: usize = 0;
        params[count] = channel;
        count += 1;
        params[count] = "USERS";
        count += 1;
        if (keep_rank) |rank| {
            if (!validIrcAtom(rank)) return error.InvalidIrcParameter;
            params[count] = "KEEP";
            count += 1;
            params[count] = rank;
            count += 1;
        }
        if (allow_accounts) |accounts| {
            if (accounts.len == 0 or std.mem.indexOfAny(u8, accounts, " \r\n\x00") != null) return error.InvalidIrcParameter;
            params[count] = "ALLOW";
            count += 1;
            params[count] = accounts;
            count += 1;
        }
        if (reason) |text| {
            try self.validateOutgoingText(text);
            params[count] = text;
            count += 1;
            try self.appendCommandTrailing("CLEAR", params[0..count]);
        } else try self.appendCommand("CLEAR", params[0..count]);
        try self.queueOut(.interactive, true, false);
    }

    /// Onyx `PINS <#channel> [LIST|ADD <msgid>|DEL <msgid>|CLEAR]`.
    /// Authorization remains exclusively server-owned.
    pub fn pins(self: *Client, channel: []const u8, operation: PinsOperation, msgid: ?[]const u8) !void {
        if (!isChannelTarget(channel)) return error.InvalidIrcParameter;
        switch (operation) {
            .list => if (msgid != null) return error.InvalidIrcParameter else try self.appendCommand("PINS", &.{ channel, "LIST" }),
            .clear => if (msgid != null) return error.InvalidIrcParameter else try self.appendCommand("PINS", &.{ channel, "CLEAR" }),
            .add, .delete => {
                const id = msgid orelse return error.InvalidIrcParameter;
                if (!validHistorySelectorForPin(id)) return error.InvalidIrcParameter;
                try self.appendCommand("PINS", &.{ channel, if (operation == .add) "ADD" else "DEL", id });
            },
        }
        try self.queueOut(.interactive, true, false);
    }

    /// Onyx `MONITOR <+|-|C|L|S> [nick[,nick]...]` subscription command.
    pub fn monitor(self: *Client, operation: MonitorOperation, nicks: ?[]const u8) !void {
        const verb = switch (operation) {
            .add => "+",
            .remove => "-",
            .clear => "C",
            .list => "L",
            .status => "S",
        };
        if (operation == .add or operation == .remove) {
            const names = nicks orelse return error.InvalidIrcParameter;
            if (!validMonitorList(names)) return error.InvalidIrcParameter;
            try self.rejectTooManyTargets(names);
            try self.appendCommand("MONITOR", &.{ verb, names });
        } else {
            if (nicks != null) return error.InvalidIrcParameter;
            try self.appendCommand("MONITOR", &.{verb});
        }
        try self.queueOut(.interactive, true, false);
    }

    /// Onyx `SILENCE [<mask>|+<mask>|-<mask>]` sender-mask control.
    pub fn silence(self: *Client, operation: SilenceOperation, mask: ?[]const u8) !void {
        if (operation == .list) {
            if (mask != null) return error.InvalidIrcParameter;
            try self.appendCommand("SILENCE", &.{});
        } else {
            const raw = mask orelse return error.InvalidIrcParameter;
            if (!validSilenceMask(raw)) return error.InvalidIrcParameter;
            var token: std.ArrayList(u8) = .empty;
            defer token.deinit(self.gpa);
            try token.append(self.gpa, if (operation == .add) '+' else '-');
            try token.appendSlice(self.gpa, raw);
            try self.appendCommand("SILENCE", &.{token.items});
        }
        try self.queueOut(.interactive, true, false);
    }

    pub fn accept(self: *Client, operation: AcceptOperation, nick: ?[]const u8) !void {
        if (operation == .list) {
            if (nick != null) return error.InvalidIrcParameter;
            try self.appendCommand("ACCEPT", &.{"*"});
        } else {
            const value = nick orelse return error.InvalidIrcParameter;
            if (!validAcceptNick(value)) return error.InvalidIrcParameter;
            var token: std.ArrayList(u8) = .empty;
            defer token.deinit(self.gpa);
            try token.append(self.gpa, if (operation == .add) '+' else '-');
            try token.appendSlice(self.gpa, value);
            try self.appendCommand("ACCEPT", &.{token.items});
        }
        try self.queueOut(.interactive, true, false);
    }

    pub fn setMode(self: *Client, target: []const u8, modes: []const u8, argument: []const u8) !void {
        if (argument.len == 0) {
            if (self.shouldSplitModes(modes)) {
                try self.appendSplitModes(target, modes);
            } else try self.appendCommand("MODE", &.{ target, modes });
        } else try self.appendCommand("MODE", &.{ target, modes, argument });
        try self.queueOut(.interactive, true, false);
    }

    fn advertisedModeCount(self: *const Client) usize {
        return self.advertisedLimits().modes;
    }

    fn shouldSplitModes(self: *const Client, modes: []const u8) bool {
        const limit = self.advertisedModeCount();
        if (limit == 0) return false;
        var flags: usize = 0;
        for (modes) |ch| {
            if (ch == '+' or ch == '-') continue;
            flags += 1;
        }
        return flags > limit;
    }

    fn appendSplitModes(self: *Client, target: []const u8, modes: []const u8) !void {
        const limit = self.advertisedModeCount();
        var sign: u8 = '+';
        var packed_modes: [18]u8 = undefined;
        var used: usize = 0;
        var flags: usize = 0;
        for (modes) |ch| {
            if (ch == '+' or ch == '-') {
                if (used != 0) {
                    try self.appendCommand("MODE", &.{ target, packed_modes[0..used] });
                    used = 0;
                    flags = 0;
                }
                sign = ch;
                continue;
            }
            if (used == 0) {
                packed_modes[0] = sign;
                used = 1;
            }
            packed_modes[used] = ch;
            used += 1;
            flags += 1;
            if (flags >= limit) {
                try self.appendCommand("MODE", &.{ target, packed_modes[0..used] });
                used = 0;
                flags = 0;
            }
        }
        if (used != 0) try self.appendCommand("MODE", &.{ target, packed_modes[0..used] });
    }

    /// `MODE <channel>` query. Onyx answers `324` with `+k`/`+l` values for members.
    pub fn queryMode(self: *Client, target: []const u8) !void {
        try self.appendCommand("MODE", &.{target});
        try self.queueOut(.interactive, true, false);
    }

    /// Microsoft uses LISTX for the extended room browser when IRCX is live.
    /// Ordinary LIST never accepts invented LISTX query atoms (`N=`, `>10`).
    pub fn listRooms(self: *Client, filter: []const u8, limit: []const u8, ircx_data: bool) !void {
        if (!ircx_data) {
            if (filter.len != 0 and !validListMask(filter)) return error.InvalidIrcParameter;
            if (filter.len == 0) try self.appendCommand("LIST", &.{}) else try self.appendCommand("LIST", &.{filter});
        } else if (filter.len == 0 and limit.len == 0) {
            try self.appendCommand("LISTX", &.{});
        } else if (filter.len == 0) {
            if (!validListxLimit(limit)) return error.InvalidIrcParameter;
            try self.appendCommand("LISTX", &.{limit});
        } else if (limit.len == 0) {
            if (!validListxQuery(filter)) return error.InvalidIrcParameter;
            try self.appendCommand("LISTX", &.{filter});
        } else {
            if (!validListxQuery(filter) or !validListxLimit(limit)) return error.InvalidIrcParameter;
            try self.appendCommand("LISTX", &.{ filter, limit });
        }
        try self.queueOut(.interactive, true, false);
    }

    pub fn queryProperty(self: *Client, entity: []const u8, property: []const u8) !void {
        if (!validPropertyList(property)) return error.InvalidIrcParameter;
        try self.appendCommand("PROP", &.{ entity, property });
        try self.queueOut(.interactive, true, false);
    }

    pub fn setProperty(self: *Client, entity: []const u8, property: []const u8, value: []const u8) !void {
        if (!validPropertyList(property)) return error.InvalidIrcParameter;
        try self.validateOutgoingText(value);
        try self.appendCommandTrailing("PROP", &.{ entity, property, value });
        try self.queueOut(.interactive, true, false);
    }

    pub fn accessList(self: *Client, channel: []const u8) !void {
        try self.appendCommand("ACCESS", &.{ channel, "LIST" });
        try self.queueOut(.interactive, true, false);
    }

    pub fn accessDelete(self: *Client, channel: []const u8, level: []const u8, mask: []const u8) !void {
        // IRCX draft 04 §5.1 names the removal operation `DELETE` (not the
        // convenient but non-standard abbreviation `DEL`). Keep this exact so
        // draft-conforming servers do not reject an otherwise valid ACL edit.
        if (!validAccessLevel(level) or !validAccessMask(mask)) return error.InvalidIrcParameter;
        try self.appendCommand("ACCESS", &.{ channel, "DELETE", level, mask });
        try self.queueOut(.interactive, true, false);
    }

    pub fn accessClear(self: *Client, channel: []const u8, level: []const u8) !void {
        var params: [3][]const u8 = .{ channel, "CLEAR", "" };
        var count: usize = 2;
        if (level.len != 0) {
            if (!validAccessLevel(level)) return error.InvalidIrcParameter;
            params[count] = level;
            count += 1;
        }
        try self.appendCommand("ACCESS", params[0..count]);
        try self.queueOut(.interactive, true, false);
    }

    pub fn accessAdd(self: *Client, channel: []const u8, level: []const u8, mask: []const u8, duration: []const u8, reason: []const u8) !void {
        if (!validAccessLevel(level) or !validAccessMask(mask) or !validAccessDuration(duration))
            return error.InvalidIrcParameter;
        var params: [7][]const u8 = .{ channel, "ADD", level, mask, "", "", "" };
        var count: usize = 4;
        if (duration.len != 0) {
            params[count] = duration;
            count += 1;
        }
        if (reason.len != 0) {
            try self.validateOutgoingText(reason);
            if (duration.len == 0) {
                params[count] = "0";
                count += 1;
            }
            params[count] = reason;
            count += 1;
            try self.appendCommandTrailing("ACCESS", params[0..count]);
        } else {
            try self.appendCommand("ACCESS", params[0..count]);
        }
        try self.queueOut(.interactive, true, false);
    }

    pub fn who(self: *Client, mask: []const u8) !void {
        if (mask.len == 0) try self.appendCommand("WHO", &.{}) else try self.appendCommand("WHO", &.{mask});
        try self.queueOut(.bulk, true, false);
    }

    // Onyx query/status surface. Each method is intentionally bounded to IRC
    // atoms and stays on the ordinary interactive/bulk queue.
    pub fn ison(self: *Client, nicks: []const u8) !void {
        try self.sendNickList("ISON", nicks, .bulk);
    }
    pub fn userhost(self: *Client, nicks: []const u8) !void {
        try self.sendNickList("USERHOST", nicks, .bulk);
    }
    pub fn whois(self: *Client, nick: []const u8) !void {
        try self.sendRequiredAtom("WHOIS", nick, .bulk);
    }
    pub fn whowas(self: *Client, nick: []const u8) !void {
        try self.sendRequiredAtom("WHOWAS", nick, .bulk);
    }
    pub fn help(self: *Client, topic: ?[]const u8) !void {
        try self.sendOptionalAtom("HELP", topic, .bulk);
    }
    pub fn version(self: *Client, server: ?[]const u8) !void {
        try self.sendOptionalAtom("VERSION", server, .bulk);
    }
    pub fn serverTime(self: *Client, server: ?[]const u8) !void {
        try self.sendOptionalAtom("TIME", server, .bulk);
    }
    pub fn admin(self: *Client, server: ?[]const u8) !void {
        try self.sendOptionalAtom("ADMIN", server, .bulk);
    }
    pub fn info(self: *Client, server: ?[]const u8) !void {
        try self.sendOptionalAtom("INFO", server, .bulk);
    }
    pub fn motd(self: *Client, server: ?[]const u8) !void {
        try self.sendOptionalAtom("MOTD", server, .bulk);
    }
    pub fn lusers(self: *Client) !void {
        try self.sendNoArgs("LUSERS", .bulk);
    }
    pub fn users(self: *Client) !void {
        try self.sendNoArgs("USERS", .bulk);
    }
    pub fn links(self: *Client) !void {
        try self.sendNoArgs("LINKS", .bulk);
    }
    pub fn map(self: *Client) !void {
        try self.sendNoArgs("MAP", .bulk);
    }
    pub fn commands(self: *Client, filter: ?[]const u8) !void {
        try self.sendOptionalAtom("COMMANDS", filter, .bulk);
    }
    pub fn welcome(self: *Client) !void {
        try self.sendNoArgs("WELCOME", .interactive);
    }
    pub fn welcomeClear(self: *Client) !void {
        try self.appendCommand("WELCOME", &.{"CLEAR"});
        try self.queueOut(.interactive, true, false);
    }
    pub fn welcomeAdd(self: *Client, line: []const u8) !void {
        if (line.len == 0) return error.InvalidIrcParameter;
        try self.validateOutgoingText(line);
        try self.appendCommandTrailing("WELCOME", &.{ "ADD", line });
        try self.queueOut(.interactive, true, false);
    }
    pub fn memoSend(self: *Client, account: []const u8, text: []const u8) !void {
        if (account.len == 0 or text.len == 0) return error.InvalidIrcParameter;
        try self.validateOutgoingText(text);
        try self.appendCommandTrailing("MEMO", &.{ "SEND", account, text });
        try self.queueOut(.interactive, true, false);
    }
    pub fn accountInfo(self: *Client, account: ?[]const u8) !void {
        try self.sendOptionalAtom("ACCOUNTINFO", account, .bulk);
    }
    pub fn saslInfo(self: *Client) !void {
        try self.sendNoArgs("SASLINFO", .bulk);
    }
    pub fn privs(self: *Client) !void {
        try self.sendNoArgs("PRIVS", .bulk);
    }
    pub fn sessionList(self: *Client) !void {
        try self.appendCommand("SESSION", &.{"LIST"});
        try self.queueOut(.bulk, false, false);
    }

    pub fn eventList(self: *Client, event: []const u8) !void {
        if (event.len == 0) try self.appendCommand("EVENT", &.{"LIST"}) else try self.appendCommand("EVENT", &.{ "LIST", event });
        try self.queueOut(.interactive, true, false);
    }

    pub fn eventChange(self: *Client, add: bool, event: []const u8, mask: []const u8) !void {
        if (event.len == 0) return error.InvalidIrcParameter;
        const operation = if (add) "ADD" else "DELETE";
        if (mask.len == 0) try self.appendCommand("EVENT", &.{ operation, event }) else try self.appendCommand("EVENT", &.{ operation, event, mask });
        try self.queueOut(.interactive, true, false);
    }

    /// In addition to standard `AWAY`, Microsoft broadcasts this CTCP control
    /// to every joined room so peers can update their local member state.
    pub fn sendAwayControl(self: *Client, target: []const u8, message_text: []const u8) !void {
        if (std.mem.indexOfAny(u8, message_text, "\r\n\x00\x01") != null)
            return error.InvalidIrcParameter;
        var wire: std.ArrayList(u8) = .empty;
        defer wire.deinit(self.gpa);
        try wire.appendSlice(self.gpa, "\x01AWAY");
        if (message_text.len != 0) {
            try wire.append(self.gpa, ' ');
            try wire.appendSlice(self.gpa, message_text);
        }
        try wire.append(self.gpa, 0x01);
        return self.privmsg(target, wire.items);
    }

    pub fn privmsg(self: *Client, target: []const u8, text: []const u8) !void {
        try self.validateOutgoingText(text);
        try self.recordOutgoingEcho(target, text);
        try self.appendCommandTrailing("PRIVMSG", &.{ target, text });
        try self.queueOut(.interactive, false, false);
    }

    pub fn notice(self: *Client, target: []const u8, text: []const u8) !void {
        try self.validateOutgoingText(text);
        try self.appendCommandTrailing("NOTICE", &.{ target, text });
        try self.queueOut(.interactive, false, false);
    }

    /// Send a named-conversation message using Onyx's narrow `onyx/topics`
    /// capability. The tag is valid without generic `message-tags`.
    pub fn privmsgWithTopic(self: *Client, target: []const u8, topic: []const u8, text: []const u8) !void {
        return self.sendWithTopic("PRIVMSG", target, topic, text);
    }

    /// NOTICE counterpart to `privmsgWithTopic`.
    pub fn noticeWithTopic(self: *Client, target: []const u8, topic: []const u8, text: []const u8) !void {
        return self.sendWithTopic("NOTICE", target, topic, text);
    }

    /// Associate a direct message with a channel. Onyx's channel-context
    /// capability defines the tag semantics, while generic `message-tags`
    /// remains the relay authorization for this draft extension.
    pub fn privmsgWithChannelContext(self: *Client, target: []const u8, channel: []const u8, text: []const u8) !void {
        try self.requireCapability("draft/channel-context");
        try self.requireClientTagCapability("");
        if (isChannelTarget(target) or !validChannelContext(channel)) return error.InvalidIrcParameter;
        try self.validateOutgoingText(text);
        var tags: std.ArrayList(u8) = .empty;
        defer tags.deinit(self.gpa);
        try tags.appendSlice(self.gpa, "+draft/channel-context=");
        try message.escapeTagValue(&tags, self.gpa, channel);
        try self.recordOutgoingEcho(target, text);
        try self.appendCommandWithTagsAndTrailing("PRIVMSG", &.{ target, text }, tags.items, true);
        try self.queueOut(.interactive, false, false);
    }

    fn recordOutgoingEcho(self: *Client, target: []const u8, text: []const u8) !void {
        if (self.features) |*state| try state.recordEcho(target, text);
    }

    pub fn ctcpRequest(self: *Client, target: []const u8, command: []const u8, payload: ?[]const u8) !void {
        return self.sendCtcp(.privmsg, target, command, payload);
    }

    /// Emit the NOTICE form used by Microsoft's CTCP information replies.
    /// A non-null empty payload intentionally retains the separating space.
    pub fn ctcpReply(self: *Client, target: []const u8, command: []const u8, payload: ?[]const u8) !void {
        return self.sendCtcp(.notice, target, command, payload);
    }

    fn sendCtcp(self: *Client, kind: enum { privmsg, notice }, target: []const u8, command: []const u8, payload: ?[]const u8) !void {
        if (command.len == 0 or std.mem.indexOfAny(u8, command, " \r\n\x00\x01") != null)
            return error.InvalidIrcParameter;
        var wire: std.ArrayList(u8) = .empty;
        defer wire.deinit(self.gpa);
        try wire.append(self.gpa, 0x01);
        try wire.appendSlice(self.gpa, command);
        if (payload) |value| {
            if (std.mem.indexOfAny(u8, value, "\r\n\x00\x01") != null)
                return error.InvalidIrcParameter;
            try wire.append(self.gpa, ' ');
            try wire.appendSlice(self.gpa, value);
        }
        try wire.append(self.gpa, 0x01);
        return switch (kind) {
            .privmsg => self.privmsg(target, wire.items),
            .notice => self.notice(target, wire.items),
        };
    }

    pub fn sendCallLink(self: *Client, target: []const u8, link: []const u8) !void {
        if (link.len == 0 or link.len > 400 or std.mem.indexOfAny(u8, link, " \r\n\x00\x01") != null)
            return error.InvalidIrcParameter;
        var wire: std.ArrayList(u8) = .empty;
        defer wire.deinit(self.gpa);
        try wire.appendSlice(self.gpa, "\x01X-COMICCHAT-CALL ");
        try wire.appendSlice(self.gpa, link);
        try wire.append(self.gpa, 0x01);
        try self.privmsg(target, wire.items);
    }

    pub fn refuseLegacyNetMeeting(self: *Client, target: []const u8) !void {
        return self.ctcpReply(target, "NETMEET", "NOHAVE");
    }

    pub fn reply(self: *Client, target: []const u8, msgid: []const u8, text: []const u8) !void {
        try self.requireClientTagCapability("draft/reply");
        if (!validMessageReference(msgid)) return error.InvalidMessageReference;
        try self.validateOutgoingText(text);
        var tags: std.ArrayList(u8) = .empty;
        defer tags.deinit(self.gpa);
        try tags.appendSlice(self.gpa, "+draft/reply=");
        try message.escapeTagValue(&tags, self.gpa, msgid);
        try self.recordOutgoingEcho(target, text);
        try self.appendCommandWithNarrowTags("PRIVMSG", &.{ target, text }, tags.items);
        try self.queueOut(.interactive, false, false);
    }

    /// Onyx `SEARCH <target> :<query>` capability path. Results return through
    /// the normal CHATHISTORY/BATCH receive pipeline.
    pub fn search(self: *Client, target: []const u8, query: []const u8) !void {
        try self.requireCapability("draft/search");
        if (target.len == 0 or query.len == 0) return error.InvalidIrcParameter;
        try self.validateOutgoingText(query);
        try self.appendCommandTrailing("SEARCH", &.{ target, query });
        try self.queueOut(.bulk, false, false);
    }

    /// Request the newest bounded CHATHISTORY window before `selector` (`*`,
    /// `msgid=<id>`, or `timestamp=<ISO8601Z>`).
    pub fn chatHistoryLatest(self: *Client, target: []const u8, selector: []const u8, limit: u16) !void {
        try self.sendChatHistoryLatest(target, selector, limit, null);
    }

    /// Onyx named-conversation variant of `chatHistoryLatest`.
    pub fn chatHistoryLatestTopic(self: *Client, target: []const u8, selector: []const u8, limit: u16, topic: []const u8) !void {
        try self.sendChatHistoryLatest(target, selector, limit, topic);
    }

    pub fn chatHistoryBefore(self: *Client, target: []const u8, selector: []const u8, limit: u16) !void {
        try self.sendChatHistoryBound("BEFORE", target, selector, limit);
    }
    pub fn chatHistoryAfter(self: *Client, target: []const u8, selector: []const u8, limit: u16) !void {
        try self.sendChatHistoryBound("AFTER", target, selector, limit);
    }
    pub fn chatHistoryAround(self: *Client, target: []const u8, selector: []const u8, limit: u16) !void {
        try self.sendChatHistoryBound("AROUND", target, selector, limit);
    }
    pub fn chatHistoryAroundWithSecond(self: *Client, target: []const u8, center: []const u8, second: []const u8, limit: u16) !void {
        try self.requireCapability("draft/chathistory");
        if (!validHistoryTarget(target) or !validHistorySelector(center) or !validHistorySelector(second)) return error.InvalidIrcParameter;
        var buf: [5]u8 = undefined;
        const text = try std.fmt.bufPrint(&buf, "{d}", .{limit});
        try self.appendCommand("CHATHISTORY", &.{ "AROUND", target, center, second, text });
        try self.queueOut(.bulk, false, false);
    }
    pub fn chatHistoryBetween(self: *Client, target: []const u8, first: []const u8, second: []const u8, limit: u16) !void {
        try self.requireCapability("draft/chathistory");
        if (!validHistoryTarget(target) or !validHistorySelector(first) or !validHistorySelector(second)) return error.InvalidIrcParameter;
        var buf: [5]u8 = undefined;
        const text = try std.fmt.bufPrint(&buf, "{d}", .{limit});
        try self.appendCommand("CHATHISTORY", &.{ "BETWEEN", target, first, second, text });
        try self.queueOut(.bulk, false, false);
    }
    pub fn chatHistoryTargets(self: *Client, first: []const u8, second: []const u8, limit: u16) !void {
        try self.requireCapability("draft/chathistory");
        if (!validHistoryTargetsSelector(first) or !validHistoryTargetsSelector(second) or limit == 0 or limit > 1000) return error.InvalidIrcParameter;
        var buf: [5]u8 = undefined;
        const text = try std.fmt.bufPrint(&buf, "{d}", .{limit});
        try self.appendCommand("CHATHISTORY", &.{ "TARGETS", first, second, text });
        try self.queueOut(.bulk, false, false);
    }

    /// Onyx `EDIT <target> <msgid> :<text>` path. The server enforces original
    /// sender ownership and broadcasts an edit-tagged replacement to capable
    /// peers; the client validates only its own wire invariants.
    pub fn editMessage(self: *Client, target: []const u8, msgid: []const u8, text: []const u8) !void {
        try self.requireCapability("draft/message-editing");
        if (!validMessageReference(msgid) or text.len == 0) return error.InvalidIrcParameter;
        try self.validateOutgoingText(text);
        try self.appendCommandTrailing("EDIT", &.{ target, msgid, text });
        try self.queueOut(.interactive, false, false);
    }

    /// Onyx `REDACT <channel> <msgid> [:reason]` path. Authorization remains
    /// server-owned; a missing reason deliberately remains an ordinary parameter
    /// form so the daemon uses its default audit reason.
    pub fn redactMessage(self: *Client, channel: []const u8, msgid: []const u8, reason: ?[]const u8) !void {
        try self.requireCapability("draft/message-redaction");
        if (channel.len == 0 or !validMessageReference(msgid)) return error.InvalidIrcParameter;
        if (reason) |text| {
            try self.validateOutgoingText(text);
            try self.appendCommandTrailing("REDACT", &.{ channel, msgid, text });
        } else {
            try self.appendCommand("REDACT", &.{ channel, msgid });
        }
        try self.queueOut(.interactive, false, false);
    }

    /// Onyx `MARKREAD <target> [timestamp=<rfc3339>|*]` path. Passing null
    /// requests the current marker; `*` explicitly clears it on the server.
    pub fn markRead(self: *Client, target: []const u8, marker: ?[]const u8) !void {
        try self.requireCapability("draft/read-marker");
        if (target.len == 0) return error.InvalidIrcParameter;
        if (marker) |value| {
            if (!std.mem.eql(u8, value, "*") and !std.mem.startsWith(u8, value, "timestamp=")) return error.InvalidIrcParameter;
            try self.appendCommand("MARKREAD", &.{ target, value });
        } else {
            try self.appendCommand("MARKREAD", &.{target});
        }
        try self.queueOut(.interactive, false, false);
    }

    /// Metadata-2 command builder for GET/LIST/SET/CLEAR. `value` is sent as
    /// the forced trailing field so an empty value expresses deletion exactly as
    /// the Onyx metadata handler expects.
    pub fn metadata(self: *Client, target: []const u8, operation: []const u8, key: ?[]const u8, visibility: ?[]const u8, value: ?[]const u8) !void {
        try self.requireCapability("draft/metadata-2");
        if (target.len == 0 or !validMetadataOperation(operation)) return error.InvalidIrcParameter;
        var params: [5][]const u8 = undefined;
        var count: usize = 0;
        params[count] = target;
        count += 1;
        params[count] = operation;
        count += 1;
        if (key) |item| {
            if (item.len == 0) return error.InvalidIrcParameter;
            params[count] = item;
            count += 1;
        }
        if (visibility) |item| {
            if (item.len == 0) return error.InvalidIrcParameter;
            params[count] = item;
            count += 1;
        }
        if (value) |text| {
            try self.validateOutgoingText(text);
            params[count] = text;
            count += 1;
            try self.appendCommandTrailing("METADATA", params[0..count]);
        } else {
            try self.appendCommand("METADATA", params[0..count]);
        }
        try self.queueOut(.interactive, false, false);
    }

    pub fn react(self: *Client, target: []const u8, msgid: []const u8, reaction: []const u8, remove: bool) !void {
        try self.requireClientTagCapability("draft/react");
        if (!validMessageReference(msgid)) return error.InvalidMessageReference;
        if (reaction.len > 256 or !std.unicode.utf8ValidateSlice(reaction)) return error.InvalidReaction;
        var tags: std.ArrayList(u8) = .empty;
        defer tags.deinit(self.gpa);
        try tags.appendSlice(self.gpa, "+draft/reply=");
        try message.escapeTagValue(&tags, self.gpa, msgid);
        try tags.appendSlice(self.gpa, if (remove) ";+draft/unreact=" else ";+draft/react=");
        try message.escapeTagValue(&tags, self.gpa, reaction);
        try self.appendCommandWithNarrowTags("TAGMSG", &.{target}, tags.items);
        try self.queueOut(.interactive, false, false);
    }

    /// Send a privacy-sensitive typing indicator. Callers opt in explicitly;
    /// the per-target three-second throttle is required by the pinned spec.
    pub fn typing(self: *Client, target: []const u8, status: TypingStatus) !void {
        if (target.len == 0 or std.mem.indexOfAny(u8, target, " \r\n\x00") != null)
            return error.InvalidIrcParameter;
        for (self.typing_targets.items) |*entry| {
            if (!std.ascii.eqlIgnoreCase(entry.target, target)) continue;
            if (self.policy_now_ms -| entry.last_ms < 3000) return error.TypingRateLimited;
            entry.last_ms = self.policy_now_ms;
            return self.sendTyping(target, status);
        }
        if (self.typing_targets.items.len >= 256) {
            const oldest = self.typing_targets.orderedRemove(0);
            self.gpa.free(oldest.target);
        }
        const owned = try self.gpa.dupe(u8, target);
        errdefer self.gpa.free(owned);
        try self.typing_targets.append(self.gpa, .{ .target = owned, .last_ms = self.policy_now_ms });
        return self.sendTyping(target, status);
    }

    /// Source `ChatAnnounceNewAvatar` passes this comment as the annotation
    /// argument: IRCX therefore carries it in `DATA ... CCUDI1`, while plain
    /// IRC carries the same bytes in a `PRIVMSG`.
    pub fn announceAvatar(self: *Client, target: []const u8, avatar: []const u8, ircx_data: bool) !void {
        if (avatar.len == 0 or std.mem.indexOfAny(u8, avatar, ".\r\n") != null)
            return error.InvalidIrcParameter;
        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(self.gpa);
        try text.appendSlice(self.gpa, "# Appears as ");
        // The original client uses a display-cased character token followed
        // by a period.  Keep this precise comment shape: old Comic Chat
        // clients parse it as their avatar-control sentence, rather than as
        // an arbitrary generated asset name.
        var capitalize = true;
        for (avatar) |ch| {
            if (ch == ' ') {
                capitalize = true;
                continue;
            }
            if (!std.ascii.isAlphanumeric(ch) and ch != '_' and ch != '-') return error.InvalidIrcParameter;
            try text.append(self.gpa, if (capitalize) std.ascii.toUpper(ch) else ch);
            capitalize = false;
        }
        try text.append(self.gpa, '.');
        return self.comicComment(target, text.items, ircx_data);
    }

    pub fn comicData(self: *Client, target: []const u8, annotation: []const u8) !void {
        return self.ircxTaggedData("DATA", target, "CCUDI1", annotation);
    }

    /// IRCX draft 04 §5.4: request a tagged payload. This is deliberately a
    /// separate wire verb from DATA so peer applications can distinguish a
    /// request from an unsolicited update.
    pub fn ircxRequest(self: *Client, target: []const u8, tag: []const u8, payload: []const u8) !void {
        return self.ircxTaggedData("REQUEST", target, tag, payload);
    }

    /// IRCX draft 04 §5.4: reply to a tagged REQUEST.
    pub fn ircxReply(self: *Client, target: []const u8, tag: []const u8, payload: []const u8) !void {
        return self.ircxTaggedData("REPLY", target, tag, payload);
    }

    /// IRCX draft 04 §5.13 contextual whisper. Unlike a private PRIVMSG, the
    /// channel and recipient list remain visible on the wire, allowing an IRCX
    /// peer to display the whisper in its channel context.
    pub fn whisper(self: *Client, channel: []const u8, recipients: []const u8, text: []const u8) !void {
        if (channel.len == 0 or recipients.len == 0) return error.InvalidIrcParameter;
        try self.rejectTooManyTargets(recipients);
        try self.validateOutgoingText(text);
        try self.appendCommandTrailing("WHISPER", &.{ channel, recipients, text });
        try self.queueOut(.interactive, false, false);
    }

    /// IRCX draft 04 §5.2 legacy SASL envelope. Modern CAP SASL remains the
    /// normal registration path; this method exists for an IRCX-only server
    /// and deliberately requires verified TLS. The caller owns the mechanism
    /// payload and it is zeroed once copied into the sensitive transmit queue.
    pub fn ircxAuth(self: *Client, mechanism: []const u8, sequence: []const u8, payload: ?[]u8) !void {
        defer if (payload) |secret| std.crypto.secureZero(u8, secret);
        if (self.connect_options.security != .tls) return error.AccountRegistrationRequiresTls;
        if (!validIrcAtom(mechanism) or !validIrcxAuthSequence(sequence)) return error.InvalidIrcParameter;
        if (payload) |secret| {
            if (std.mem.indexOfAny(u8, secret, "\r\n\x00") != null) return error.InvalidIrcParameter;
            try self.appendCommandTrailing("AUTH", &.{ mechanism, sequence, secret });
        } else {
            try self.appendCommand("AUTH", &.{ mechanism, sequence });
        }
        // AUTH carries credentials but is an application-initiated IRCX
        // message, not a transport keepalive; use the sensitive interactive
        // queue just like account registration so normal backpressure applies.
        try self.queueOut(.interactive, false, true);
    }

    fn ircxTaggedData(self: *Client, command: []const u8, target: []const u8, tag: []const u8, payload: []const u8) !void {
        if (target.len == 0 or !validIrcxDataTag(tag)) return error.InvalidIrcParameter;
        try self.validateOutgoingText(payload);
        try self.appendCommandTrailing(command, &.{ target, tag, payload });
        try self.queueOut(.interactive, false, false);
    }

    /// `bChatSendSound` sends no UDI. Its entire wire payload is the source
    /// CTCP form `SOUND <filename> <accompanying-message>` in a PRIVMSG.
    pub fn sendSound(self: *Client, target: []const u8, filename: []const u8, accompanying_message: []const u8) !void {
        if (filename.len == 0 or std.mem.indexOfScalar(u8, filename, 0) != null)
            return error.InvalidIrcParameter;
        if (std.mem.indexOfAny(u8, accompanying_message, "\r\n\x00\x01") != null)
            return error.InvalidIrcParameter;

        const quoted_filename = try dcc.ctcpQuote(self.gpa, filename);
        defer if (quoted_filename) |owned| self.gpa.free(owned);
        const wire_filename = quoted_filename orelse filename;

        var wire: std.ArrayList(u8) = .empty;
        defer wire.deinit(self.gpa);
        try wire.appendSlice(self.gpa, "\x01SOUND ");
        try wire.appendSlice(self.gpa, wire_filename);
        try wire.append(self.gpa, ' ');
        try wire.appendSlice(self.gpa, accompanying_message);
        try wire.append(self.gpa, 0x01);
        return self.privmsg(target, wire.items);
    }

    /// `# GetInfo` (`ChatGetInfo`, protsupp.cpp:3415-3422): request the
    /// target's profile text.
    pub fn requestProfile(self: *Client, target: []const u8, ircx_data: bool) !void {
        return self.comicComment(target, "# GetInfo", ircx_data);
    }

    /// `# HeresInfo: <profile>` (protsupp.cpp:919-920): reply to a profile
    /// request.
    pub fn sendProfile(self: *Client, target: []const u8, profile: []const u8) !void {
        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(self.gpa);
        try text.appendSlice(self.gpa, "# HeresInfo: ");
        try text.appendSlice(self.gpa, profile);
        return self.privmsg(target, text.items);
    }

    /// `# GetCharInfo` (`ChatGetAvatarInfo`, protsupp.cpp:3424-3430): ask the
    /// target to (re)announce its avatar name/URL. This port has no avatar
    /// file-transfer path (`filesend.cpp`), so a reply only ever updates the
    /// name via `announceAvatar`/`parseAvatarAnnouncement`.
    pub fn requestAvatarInfo(self: *Client, target: []const u8, ircx_data: bool) !void {
        return self.comicComment(target, "# GetCharInfo", ircx_data);
    }

    /// `ChatSendFile`'s offer (filesend.cpp:130-198): announce a `DCC SEND`
    /// avatar/file offer. Only composes and sends the CTCP message; the
    /// caller drives the actual transfer via `proto.dcc.sendFile` once the
    /// peer connects (this port has no MFC progress-dialog/thread
    /// equivalent to launch it automatically).
    pub fn offerFile(self: *Client, target: []const u8, offer: dcc.SendOffer) !void {
        const wire = try dcc.encodeSendOffer(self.gpa, offer);
        defer self.gpa.free(wire);
        return self.privmsg(target, wire);
    }

    /// `ChatSyncBackDrop` (protsupp.cpp:3432-3453): announce a channel
    /// backdrop change, in both the modern and legacy-compat wire forms so
    /// either kind of receiver picks it up. `name` keeps its extension
    /// (e.g. "cave.bmp"); `url` may be omitted.
    pub fn syncBackdrop(self: *Client, target: []const u8, name: []const u8, url: ?[]const u8, ircx_data: bool) !void {
        if (name.len == 0) return error.InvalidIrcParameter;

        var modern: std.ArrayList(u8) = .empty;
        defer modern.deinit(self.gpa);
        try modern.appendSlice(self.gpa, "# BDrop2: ");
        try modern.appendSlice(self.gpa, name);
        try modern.append(self.gpa, ',');
        if (url) |u| try modern.appendSlice(self.gpa, u);
        try self.comicComment(target, modern.items, ircx_data);

        const dot = std.mem.indexOfScalar(u8, name, '.');
        const base_name = if (dot) |i| name[0..i] else name;
        var legacy: std.ArrayList(u8) = .empty;
        defer legacy.deinit(self.gpa);
        // BACKGRNDPREFIX already ends in a space, and protsupp.cpp:3447's
        // format string ("#%s %s") adds one more, so a real client emits a
        // double space here. Preserved verbatim: the receiver skips all
        // whitespace after the prefix (protsupp.cpp:975-976).
        try legacy.appendSlice(self.gpa, "# BDrop:  ");
        try legacy.appendSlice(self.gpa, base_name);
        try self.comicComment(target, legacy.items, ircx_data);
    }

    fn comicComment(self: *Client, target: []const u8, text: []const u8, ircx_data: bool) !void {
        // Source Comic Chat keeps these controls in PRIVMSG even on IRCX
        // while comic data is enabled, which is its interoperable default.
        _ = ircx_data;
        return self.privmsg(target, text);
    }

    pub fn accountRegister(
        self: *Client,
        account_or_star: []const u8,
        email_or_star: []const u8,
        password: []u8,
    ) !void {
        defer std.crypto.secureZero(u8, password);
        try self.validateOutgoingText(account_or_star);
        try self.validateOutgoingText(email_or_star);
        try self.validateOutgoingText(password);
        try self.appendCommand("REGISTER", &.{ account_or_star, email_or_star, password });
        try self.queueOut(.interactive, false, true);
    }

    pub fn accountVerify(self: *Client, account_or_star: []const u8, code: []u8) !void {
        defer std.crypto.secureZero(u8, code);
        try self.appendCommand("VERIFY", &.{ account_or_star, code });
        try self.queueOut(.interactive, false, true);
    }

    pub fn identify(self: *Client, account: []const u8, password: []const u8, totp: []const u8) !void {
        if (account.len == 0 or password.len == 0) return error.InvalidIrcParameter;
        try self.validateOutgoingText(account);
        try self.validateOutgoingText(password);
        if (totp.len != 0) try self.validateOutgoingText(totp);
        if (totp.len == 0)
            try self.appendCommandTrailing("IDENTIFY", &.{ account, password })
        else
            try self.appendCommandTrailing("IDENTIFY", &.{ account, password, totp });
        try self.queueOut(.interactive, false, true);
    }

    pub fn logoutAccount(self: *Client) !void {
        try self.appendCommand("LOGOUT", &.{});
        try self.queueOut(.interactive, true, false);
    }

    pub fn dropAccount(self: *Client, account: []const u8, password: []const u8) !void {
        if (account.len == 0 or password.len == 0) return error.InvalidIrcParameter;
        try self.validateOutgoingText(account);
        try self.validateOutgoingText(password);
        try self.appendCommandTrailing("DROP", &.{ account, password });
        try self.queueOut(.interactive, false, true);
    }

    pub fn ghost(self: *Client, nick: []const u8, password: []const u8) !void {
        if (nick.len == 0 or password.len == 0) return error.InvalidIrcParameter;
        try self.validateOutgoingText(nick);
        try self.validateOutgoingText(password);
        try self.appendCommandTrailing("GHOST", &.{ nick, password });
        try self.queueOut(.interactive, false, true);
    }

    pub fn recover(self: *Client, nick: []const u8) !void {
        if (nick.len == 0) return error.InvalidIrcParameter;
        try self.appendCommand("RECOVER", &.{nick});
        try self.queueOut(.interactive, true, false);
    }

    pub fn release(self: *Client, nick: []const u8) !void {
        if (nick.len == 0) return error.InvalidIrcParameter;
        try self.appendCommand("RELEASE", &.{nick});
        try self.queueOut(.interactive, true, false);
    }

    pub fn sendService(self: *Client, command: []const u8, args: []const []const u8) !void {
        if (command.len == 0 or std.mem.indexOfAny(u8, command, " \r\n\x00") != null)
            return error.InvalidIrcParameter;
        for (args) |arg| try self.validateOutgoingText(arg);
        if (args.len == 0)
            try self.appendCommand(command, &.{})
        else
            try self.appendCommandTrailing(command, args);
        try self.queueOut(.interactive, true, false);
    }

    pub fn capabilityEnabled(self: *const Client, name: []const u8) bool {
        if (self.registration) |*registration| return registration.cap.enabled.contains(name);
        return false;
    }

    pub fn hasRestorationTargets(self: *const Client) bool {
        return if (self.restoration) |restoration| restoration.targetCount() != 0 else false;
    }

    pub fn restoresChannel(self: *const Client, channel: []const u8) bool {
        const restoration = self.restoration orelse return false;
        const mapping = if (self.features) |*state| state.casemapping else .rfc1459;
        for (restoration.targets.items) |entry| {
            if (irc_map.eql(mapping, entry.channel, channel)) return true;
        }
        return false;
    }

    pub fn takeRestoration(self: *Client, dest: *policy.Restoration) void {
        if (self.restoration) |*restoration| restoration.moveTo(dest);
    }

    pub fn adoptRestoration(self: *Client, source: *policy.Restoration) void {
        if (source.targetCount() == 0) return;
        self.ownedRestoration().moveFrom(source);
    }

    pub fn forgetRestoration(self: *Client, channel: []const u8) void {
        if (self.restoration) |*restoration| restoration.forget(channel);
    }

    pub fn setRestorationKey(self: *Client, channel: []const u8, key: []const u8) void {
        if (self.restoration) |*restoration| restoration.setJoinKey(channel, key) catch {};
    }

    pub fn renameRestoration(self: *Client, old_channel: []const u8, new_channel: []const u8) void {
        const restoration = if (self.restoration) |*value| value else return;
        var key_storage: [512]u8 = undefined;
        var after_storage: [520]u8 = undefined;
        var key: []const u8 = "";
        var after: ?[]const u8 = null;
        for (restoration.targets.items) |entry| {
            const mapping = if (self.features) |*state| state.casemapping else .rfc1459;
            if (!irc_map.eql(mapping, entry.channel, old_channel)) continue;
            if (entry.key) |value| {
                if (value.len > key_storage.len) return;
                @memcpy(key_storage[0..value.len], value);
                key = key_storage[0..value.len];
            }
            if (entry.after) |value| {
                if (value.len > after_storage.len) return;
                @memcpy(after_storage[0..value.len], value);
                after = after_storage[0..value.len];
            }
            break;
        }
        restoration.forget(old_channel);
        restoration.rememberJoin(new_channel, key, after) catch {};
    }

    fn ownedRestoration(self: *Client) *policy.Restoration {
        if (self.restoration == null) self.restoration = policy.Restoration.init(self.gpa);
        return &self.restoration.?;
    }

    fn queueRestoration(self: *Client) !void {
        if (self.capabilityEnabled("onyx/session-sync")) return;
        const restoration = if (self.restoration) |*value| value else return;
        if (restoration.targetCount() == 0) return;
        const history_limit: u16 = self.advertisedChatHistoryLimit();
        try restoration.appendCommands(&self.out, self.gpa, history_limit);
        try self.queueOut(.interactive, true, false);
    }

    /// Onyx `onyx/session-sync` projects membership for a resumed session.
    /// First visits still JOIN `want_rejoin` rooms.
    pub fn projectsSessionChannels(self: *const Client) bool {
        if (!self.capabilityEnabled("onyx/session-sync")) return false;
        if (self.hasRestorationTargets()) return true;
        return if (self.registration) |registration| registration.hasResumeToken() else false;
    }

    fn noteHistoryCursor(self: *Client, msg: *const Message) void {
        const restoration = if (self.restoration) |*value| value else return;
        if (restoration.targetCount() == 0) return;
        if (!std.ascii.eqlIgnoreCase(msg.command, "PRIVMSG") and !std.ascii.eqlIgnoreCase(msg.command, "NOTICE"))
            return;
        const target = msg.param(0) orelse return;
        var found = false;
        for (restoration.targets.items) |entry| {
            const mapping = if (self.features) |*state| state.casemapping else .rfc1459;
            if (irc_map.eql(mapping, entry.channel, target)) {
                found = true;
                break;
            }
        }
        if (!found) return;
        var buffer: [520]u8 = undefined;
        const reference = if (msg.tag("msgid")) |tag| blk: {
            const raw = tag.raw_value orelse return;
            break :blk std.fmt.bufPrint(&buffer, "msgid={s}", .{raw}) catch return;
        } else if (msg.tag("time")) |tag| blk: {
            const raw = tag.raw_value orelse return;
            break :blk std.fmt.bufPrint(&buffer, "timestamp={s}", .{raw}) catch return;
        } else return;
        restoration.remember(target, reference) catch {};
    }

    fn requireCapability(self: *const Client, name: []const u8) !void {
        if (!self.capabilityEnabled(name)) return error.CapabilityNotEnabled;
    }

    /// Onyx relays the named activity tag when either generic message-tags or
    /// its narrow draft capability is negotiated. Prefer the generic path when
    /// available, but do not reject a standards-compliant narrow-only peer.
    fn requireClientTagCapability(self: *const Client, narrow: []const u8) !void {
        if (!self.capabilityEnabled("message-tags") and !self.capabilityEnabled(narrow))
            return error.MessageTagsNotEnabled;
    }

    pub fn appendEnabledCapabilities(self: *const Client, out: *std.ArrayList(u8), gpa: std.mem.Allocator) !void {
        const registration = if (self.registration) |*value| value else return;
        for (registration.cap.enabled.entries.items, 0..) |capability, index| {
            if (index != 0) try out.appendSlice(gpa, ", ");
            try out.appendSlice(gpa, capability.name);
        }
    }

    pub fn authenticated(self: *const Client) bool {
        return if (self.registration) |registration| registration.authenticated else false;
    }

    pub fn usesTls(self: *const Client) bool {
        return self.connect_options.security == .tls;
    }

    pub fn refreshCapabilities(self: *Client) !void {
        const registration = if (self.registration) |*value| value else return error.RegistrationNotStarted;
        try registration.cap.requestList(&self.out);
        try self.queueOut(.control, false, false);
    }

    pub fn featureState(self: *const Client) ?*const features_mod.State {
        if (self.features) |*state| return state;
        return null;
    }

    fn advertisedLimits(self: *const Client) irc_map.SessionLimits {
        return if (self.featureState()) |state| state.session_limits else .{};
    }

    fn exceptsLetter(self: *const Client) u8 {
        const letter = self.advertisedLimits().excepts;
        return if (letter == 0) 'e' else letter;
    }

    fn invexLetter(self: *const Client) u8 {
        const letter = self.advertisedLimits().invex;
        return if (letter == 0) 'I' else letter;
    }

    fn advertisedChatHistoryLimit(self: *const Client) u16 {
        if (!self.capabilityEnabled("draft/chathistory")) return 0;
        const advertised = self.advertisedLimits().chathistory;
        if (advertised == 0) return 100;
        return @intCast(@min(advertised, 65535));
    }

    fn appendListMode(self: *Client, channel: []const u8, sign: u8, letter: u8, mask: ?[]const u8) !void {
        const flag = [_]u8{ sign, letter };
        if (mask) |value|
            try self.appendCommand("MODE", &.{ channel, &flag, value })
        else
            try self.appendCommand("MODE", &.{ channel, &flag });
        try self.queueOut(.interactive, true, false);
    }

    fn rejectSessionLimits(self: *const Client, channel: []const u8, key: []const u8) !void {
        const limits = self.advertisedLimits();
        if (irc_map.SessionLimits.exceeds(limits.channellen, channel)) return error.InvalidIrcParameter;
        if (irc_map.SessionLimits.exceeds(limits.keylen, key)) return error.InvalidIrcParameter;
        if (limits.chanlimit != 0 and !self.restoresChannel(channel)) {
            const current = if (self.restoration) |restoration| restoration.targetCount() else 0;
            if (current >= limits.chanlimit) return error.InvalidIrcParameter;
        }
    }

    fn rejectTooManyTargets(self: *const Client, list: []const u8) !void {
        const cap = self.advertisedLimits().maxtargets;
        if (irc_map.SessionLimits.exceedsCount(cap, irc_map.SessionLimits.targetCount(list)))
            return error.InvalidIrcParameter;
    }

    pub fn takeStsUpgradePort(self: *Client) ?u16 {
        const port = self.sts_upgrade_port;
        self.sts_upgrade_port = null;
        return port;
    }

    fn appendCommand(self: *Client, command: []const u8, params: []const []const u8) !void {
        return self.appendCommandWithTagsAndTrailing(command, params, null, false);
    }

    fn appendCommandTrailing(self: *Client, command: []const u8, params: []const []const u8) !void {
        return self.appendCommandWithTagsAndTrailing(command, params, null, true);
    }

    fn appendCommandWithTags(self: *Client, command: []const u8, params: []const []const u8, client_tags: ?[]const u8) !void {
        try self.requireClientTagCapability("");
        return self.appendCommandWithTagsAndTrailing(command, params, client_tags, false);
    }

    /// Caller has already checked its specific narrow capability.
    fn appendCommandWithNarrowTags(self: *Client, command: []const u8, params: []const []const u8, client_tags: []const u8) !void {
        return self.appendCommandWithTagsAndTrailing(command, params, client_tags, false);
    }

    fn appendCommandWithTagsAndTrailing(self: *Client, command: []const u8, params: []const []const u8, client_tags: ?[]const u8, force_trailing: bool) !void {
        var msg = Message{ .command = command, .force_trailing = force_trailing };
        if (params.len > message.max_params) return error.InvalidIrcParameter;
        for (params, 0..) |param, index| msg.params[index] = param;
        msg.param_count = params.len;
        var tags: std.ArrayList(u8) = .empty;
        defer tags.deinit(self.gpa);
        if (client_tags) |raw| try tags.appendSlice(self.gpa, raw);
        if (self.capabilityEnabled("labeled-response")) if (self.features) |*state| {
            const label = try state.createLabel();
            if (tags.items.len != 0) try tags.append(self.gpa, ';');
            try tags.print(self.gpa, "label={s}", .{label});
        };
        if (tags.items.len != 0) msg.tag_data = tags.items;
        try message.write(&self.out, self.gpa, msg);
    }

    fn sendTyping(self: *Client, target: []const u8, status: TypingStatus) !void {
        try self.requireClientTagCapability("draft/typing");
        var buffer: [32]u8 = undefined;
        const tags = try std.fmt.bufPrint(&buffer, "+typing={s}", .{@tagName(status)});
        try self.appendCommandWithNarrowTags("TAGMSG", &.{target}, tags);
        try self.queueOut(.interactive, false, false);
    }

    fn sendChatHistoryLatest(self: *Client, target: []const u8, selector: []const u8, limit: u16, topic: ?[]const u8) !void {
        try self.requireCapability("draft/chathistory");
        if (!validHistoryTarget(target) or !validHistorySelector(selector)) return error.InvalidIrcParameter;
        var limit_buffer: [5]u8 = undefined;
        const limit_text = try std.fmt.bufPrint(&limit_buffer, "{d}", .{limit});
        if (topic) |label| {
            try self.requireClientTagCapability("onyx/topics");
            if (!validTopicLabel(label)) return error.InvalidIrcParameter;
            var tags: std.ArrayList(u8) = .empty;
            defer tags.deinit(self.gpa);
            try tags.appendSlice(self.gpa, "+onyx/topic=");
            try message.escapeTagValue(&tags, self.gpa, label);
            try self.appendCommandWithTagsAndTrailing("CHATHISTORY", &.{ "LATEST", target, selector, limit_text }, tags.items, false);
        } else {
            try self.appendCommand("CHATHISTORY", &.{ "LATEST", target, selector, limit_text });
        }
        try self.queueOut(.bulk, false, false);
    }

    fn sendNoArgs(self: *Client, command: []const u8, priority: policy.Priority) !void {
        try self.appendCommand(command, &.{});
        try self.queueOut(priority, true, false);
    }
    fn sendRequiredAtom(self: *Client, command: []const u8, value: []const u8, priority: policy.Priority) !void {
        if (!validIrcAtom(value)) return error.InvalidIrcParameter;
        try self.appendCommand(command, &.{value});
        try self.queueOut(priority, true, false);
    }
    fn sendNickList(self: *Client, command: []const u8, nicks: []const u8, priority: policy.Priority) !void {
        var args: [16][]const u8 = undefined;
        var count: usize = 0;
        var it = std.mem.tokenizeAny(u8, nicks, " ,\t");
        while (it.next()) |nick| {
            if (count == args.len) break;
            if (!validIrcAtom(nick)) return error.InvalidIrcParameter;
            args[count] = nick;
            count += 1;
        }
        if (count == 0) return error.InvalidIrcParameter;
        if (count == 1)
            try self.appendCommand(command, args[0..count])
        else
            try self.appendCommandTrailing(command, args[0..count]);
        try self.queueOut(priority, true, false);
    }
    fn sendOptionalAtom(self: *Client, command: []const u8, value: ?[]const u8, priority: policy.Priority) !void {
        if (value) |atom| try self.sendRequiredAtom(command, atom, priority) else try self.sendNoArgs(command, priority);
    }

    fn sendChatHistoryBound(self: *Client, subcommand: []const u8, target: []const u8, selector: []const u8, limit: u16) !void {
        try self.requireCapability("draft/chathistory");
        if (!validHistoryTarget(target) or !validHistorySelector(selector)) return error.InvalidIrcParameter;
        var buf: [5]u8 = undefined;
        const text = try std.fmt.bufPrint(&buf, "{d}", .{limit});
        try self.appendCommand("CHATHISTORY", &.{ subcommand, target, selector, text });
        try self.queueOut(.bulk, false, false);
    }

    fn sendWithTopic(self: *Client, command: []const u8, target: []const u8, topic: []const u8, text: []const u8) !void {
        try self.requireClientTagCapability("onyx/topics");
        if (!isChannelTarget(target) or !validTopicLabel(topic)) return error.InvalidIrcParameter;
        try self.validateOutgoingText(text);
        var tags: std.ArrayList(u8) = .empty;
        defer tags.deinit(self.gpa);
        try tags.appendSlice(self.gpa, "+onyx/topic=");
        try message.escapeTagValue(&tags, self.gpa, topic);
        if (std.mem.eql(u8, command, "PRIVMSG")) try self.recordOutgoingEcho(target, text);
        try self.appendCommandWithTagsAndTrailing(command, &.{ target, text }, tags.items, true);
        try self.queueOut(.interactive, false, false);
    }

    fn validateOutgoingText(self: *const Client, text: []const u8) !void {
        if (self.features) |*state| {
            if (state.isupport("UTF8ONLY") != null and !std.unicode.utf8ValidateSlice(text))
                return error.InvalidUtf8;
        }
    }

    /// Native socket handle for a platform poll/select loop. The client keeps
    /// ownership; callers use this only to wait for readability.
    pub fn fd(self: *const Client) i32 {
        return self.transport.fd();
    }

    /// Read one available chunk into the line framer. Event-driven callers
    /// invoke this only after their poller reports `fd()` readable. Returns
    /// false when the peer closed the connection.
    pub fn receive(self: *Client) !bool {
        const n = try self.transport.recv(&self.rx);
        if (n == 0) return false;
        try self.framer.push(self.rx[0..n]);
        return true;
    }

    /// Null means the timeout expired, false means EOF, and true means bytes
    /// were added to the line framer.
    pub fn receiveTimeout(self: *Client, milliseconds: i64) !?bool {
        const maybe_n = try self.transport.recvTimeout(&self.rx, milliseconds);
        const n = maybe_n orelse return null;
        if (n == 0) return false;
        try self.framer.push(self.rx[0..n]);
        return true;
    }

    /// Parse one already-buffered message without reading the socket. PING is
    /// answered here so both blocking and event-driven users get keepalives.
    pub fn bufferedNext(self: *Client) !?Message {
        if (self.logical_line) |line| {
            self.gpa.free(line);
            self.logical_line = null;
        }

        while (self.aggregator.takeReady()) |line| {
            self.logical_line = line;
            const msg = message.parse(line);
            if (self.features) |*state| {
                if (try state.observe(&msg)) {
                    self.gpa.free(line);
                    self.logical_line = null;
                    continue;
                }
            }
            return msg;
        }

        while (true) {
            const line = (try self.framer.next()) orelse return null;
            const msg = message.parse(line);
            self.deadlines.observeRx(self.policy_now_ms);
            if (std.mem.eql(u8, msg.command, "001")) self.deadlines.markRegistered();

            if (try autoRespond(&self.out, self.gpa, msg)) {
                try self.queueOut(.control, false, false);
                continue;
            }

            if (self.registration) |*registration| {
                if (try registration.consume(&self.out, &msg, &self.sts_upgrade_port)) {
                    // AUTHENTICATE output may contain reversible credentials.
                    // Always wipe the retained allocation after control sends.
                    try self.queueOut(.control, false, true);
                    continue;
                }
                try registration.observeSessionCredential(msg);
                if (std.mem.eql(u8, msg.command, "001")) {
                    if (try registration.sendSessionCommands(&self.out))
                        try self.queueOut(.control, false, true);
                    try self.queueRestoration();
                }
            }
            self.noteHistoryCursor(&msg);

            if (try self.aggregator.ingest(line)) {
                while (self.aggregator.takeCompletedLabel()) |label| {
                    defer self.gpa.free(label);
                    if (self.features) |*state| _ = try state.completeLabel(label);
                }
                while (self.aggregator.takeReady()) |ready| {
                    self.logical_line = ready;
                    const logical = message.parse(ready);
                    if (self.features) |*state| {
                        if (try state.observe(&logical)) {
                            self.gpa.free(ready);
                            self.logical_line = null;
                            continue;
                        }
                    }
                    return logical;
                }
                continue;
            }

            if (self.features) |*state| if (try state.observe(&msg)) continue;
            return msg;
        }
    }

    /// Return the next protocol message, reading from the socket as needed.
    /// PING is answered automatically. Returns null at end of stream. The
    /// returned Message borrows from internal storage and is valid until the
    /// next call to `next`.
    pub fn next(self: *Client) !?Message {
        while (true) {
            if (try self.bufferedNext()) |msg| return msg;
            if (!try self.receive()) return null;
        }
    }
};

const TypingTarget = struct { target: []u8, last_ms: u64 };

fn validMessageReference(reference: []const u8) bool {
    return reference.len != 0 and reference[0] != ':' and
        std.mem.indexOfAny(u8, reference, " \r\n\x00") == null;
}

/// IRCX draft 04 §5.4 reserves a compact tag grammar for DATA, REQUEST, and
/// REPLY. Reject malformed tags locally rather than relying on server-specific
/// recovery, and leave authorization of SYS/ADM/OWN/HST prefixes to the server.
fn validIrcxDataTag(tag: []const u8) bool {
    if (tag.len == 0 or tag.len > 15) return false;
    if (!std.ascii.isAlphabetic(tag[0])) return false;
    for (tag) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '.') return false;
    return true;
}

fn validIrcAtom(value: []const u8) bool {
    return value.len != 0 and std.mem.indexOfAny(u8, value, " \r\n\x00:") == null;
}

/// Ordinary LIST accepts a channel mask, not invented LISTX query atoms.
fn validListMask(value: []const u8) bool {
    if (value.len == 0 or std.mem.indexOfAny(u8, value, " \r\n\x00") != null) return false;
    if (std.mem.indexOfScalar(u8, value, '=') != null) return false;
    var parts = std.mem.splitScalar(u8, value, ',');
    while (parts.next()) |part| {
        if (part.len == 0) return false;
        if (part[0] == '>' or part[0] == '<') return false;
    }
    return true;
}

fn validListxQuery(value: []const u8) bool {
    return value.len != 0 and value.len <= 510 and std.mem.indexOfAny(u8, value, " \r\n\x00") == null;
}

fn validListxLimit(value: []const u8) bool {
    if (value.len == 0 or value.len > 10) return false;
    for (value) |byte| if (!std.ascii.isDigit(byte)) return false;
    return true;
}

fn validPropertyList(value: []const u8) bool {
    if (value.len == 0 or value.len > 510) return false;
    if (std.mem.eql(u8, value, "*")) return true;
    if (std.mem.indexOfAny(u8, value, " \r\n\x00") != null) return false;
    var parts = std.mem.splitScalar(u8, value, ',');
    var seen = false;
    while (parts.next()) |part| {
        if (part.len == 0 or part.len > 64) return false;
        for (part) |byte| {
            if (!std.ascii.isAlphanumeric(byte) and byte != '_' and byte != '-' and byte != '.') return false;
        }
        seen = true;
    }
    return seen;
}

fn validAccessLevel(value: []const u8) bool {
    return std.ascii.eqlIgnoreCase(value, "DENY") or
        std.ascii.eqlIgnoreCase(value, "GRANT") or
        std.ascii.eqlIgnoreCase(value, "VOICE") or
        std.ascii.eqlIgnoreCase(value, "HOST") or
        std.ascii.eqlIgnoreCase(value, "OWNER");
}

fn validAccessMask(value: []const u8) bool {
    return value.len != 0 and value.len <= 256 and std.mem.indexOfAny(u8, value, " \r\n\x00") == null;
}

fn validAccessDuration(value: []const u8) bool {
    if (value.len == 0) return true;
    if (value.len > 10) return false;
    for (value) |byte| if (!std.ascii.isDigit(byte)) return false;
    return true;
}

fn validIrcxAuthSequence(value: []const u8) bool {
    return std.mem.eql(u8, value, "I") or std.mem.eql(u8, value, "S") or std.mem.eql(u8, value, "*");
}

fn validMetadataOperation(value: []const u8) bool {
    return std.ascii.eqlIgnoreCase(value, "GET") or
        std.ascii.eqlIgnoreCase(value, "LIST") or
        std.ascii.eqlIgnoreCase(value, "SET") or
        std.ascii.eqlIgnoreCase(value, "CLEAR");
}

fn validTopicLabel(value: []const u8) bool {
    if (value.len == 0 or value.len > 50 or !std.unicode.utf8ValidateSlice(value)) return false;
    for (value) |byte| if (byte < 0x20 or byte == 0x7f or byte == ',') return false;
    return true;
}

fn validHistoryTarget(value: []const u8) bool {
    if (value.len == 0 or value.len > 128 or std.mem.eql(u8, value, "*")) return false;
    for (value) |byte| if (byte <= ' ' or byte == 0x7f or byte == ',') return false;
    return true;
}

fn validHistorySelectorForPin(value: []const u8) bool {
    if (value.len == 0 or value.len > 64) return false;
    for (value) |byte| if (byte <= ' ' or byte == 0x7f or byte == ';' or byte == '\\') return false;
    return true;
}

fn validMonitorList(value: []const u8) bool {
    if (value.len == 0 or value.len > 510) return false;
    var names = std.mem.splitScalar(u8, value, ',');
    while (names.next()) |name| {
        if (name.len == 0 or name.len > 64 or std.mem.indexOfAny(u8, name, " \r\n\x00,@") != null) return false;
    }
    return true;
}

fn validSilenceMask(value: []const u8) bool {
    return value.len != 0 and value.len <= 256 and std.mem.indexOfAny(u8, value, " \r\n\x00") == null;
}

fn validHistorySelector(value: []const u8) bool {
    if (std.mem.eql(u8, value, "*")) return true;
    if (std.mem.startsWith(u8, value, "msgid=")) {
        const msgid = value["msgid=".len..];
        if (msgid.len == 0 or msgid.len > 128) return false;
        for (msgid) |byte| if (byte <= ' ' or byte == 0x7f or byte == ';' or byte == '\\') return false;
        return true;
    }
    if (std.mem.startsWith(u8, value, "timestamp=")) return validHistoryTimestamp(value["timestamp=".len..]);
    return false;
}

fn validHistoryTimestamp(value: []const u8) bool {
    if (value.len != 24 or value[4] != '-' or value[7] != '-' or value[10] != 'T' or value[13] != ':' or value[16] != ':' or value[19] != '.' or value[23] != 'Z') return false;
    const year = std.fmt.parseUnsigned(u16, value[0..4], 10) catch return false;
    const month = std.fmt.parseUnsigned(u8, value[5..7], 10) catch return false;
    const day = std.fmt.parseUnsigned(u8, value[8..10], 10) catch return false;
    const hour = std.fmt.parseUnsigned(u8, value[11..13], 10) catch return false;
    const minute = std.fmt.parseUnsigned(u8, value[14..16], 10) catch return false;
    const second = std.fmt.parseUnsigned(u8, value[17..19], 10) catch return false;
    _ = std.fmt.parseUnsigned(u16, value[20..23], 10) catch return false;
    if (year < 1970 or month < 1 or month > 12 or hour > 23 or minute > 59 or second > 59) return false;
    const month_enum: std.time.epoch.Month = @enumFromInt(month);
    return day >= 1 and day <= std.time.epoch.getDaysInMonth(year, month_enum);
}

fn validAcceptNick(value: []const u8) bool {
    if (value.len == 0 or value.len > 64) return false;
    for (value) |byte| if (!std.ascii.isAlphanumeric(byte) and std.mem.indexOfScalar(u8, "[]\\`_^{}|-", byte) == null) return false;
    return true;
}

fn validHistoryTargetsSelector(value: []const u8) bool {
    return std.mem.eql(u8, value, "*") or (std.mem.startsWith(u8, value, "timestamp=") and validHistoryTimestamp(value["timestamp=".len..]));
}

fn isChannelTarget(value: []const u8) bool {
    return value.len != 0 and switch (value[0]) {
        '#', '&', '+', '!' => true,
        else => false,
    };
}

fn validChannelContext(value: []const u8) bool {
    if (value.len < 2 or value.len > 64 or !isChannelTarget(value)) return false;
    for (value[1..]) |byte| switch (byte) {
        0...0x20, 0x7f, ',', ';', '\\' => return false,
        else => {},
    };
    return true;
}

// --- Tests ----------------------------------------------------------------

test "QUIT serializes a trailing reason" {
    const gpa = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    var msg = message.Message{ .command = "QUIT", .force_trailing = true };
    msg.params[0] = "Comic Chat";
    msg.param_count = 1;
    try message.write(&out, gpa, msg);
    try std.testing.expectEqualStrings("QUIT :Comic Chat\r\n", out.items);
}

test "autoRespond answers PING with matching PONG" {
    const gpa = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);

    const did = try autoRespond(&out, gpa, message.parse("PING :abc123"));
    try std.testing.expect(did);
    try std.testing.expectEqualStrings("PONG abc123\r\n", out.items);
}

test "autoRespond ignores non-PING" {
    const gpa = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);

    const did = try autoRespond(&out, gpa, message.parse(":srv PRIVMSG me :hi"));
    try std.testing.expect(!did);
    try std.testing.expectEqual(@as(usize, 0), out.items.len);
}

test "authenticated registration resumes once then requests a fresh session token" {
    const gpa = std.testing.allocator;
    var store = try session_store.Store.init(gpa, "server.example", "alex");
    defer store.deinit();
    try std.testing.expect(try store.observe(message.parse(":server.example NOTICE alex :SESSION TOKEN reusable")));
    var registration = Registration.init(gpa, "eshmaki.me", .tls, .{
        .session = &store,
        .now_seconds = 100,
    });
    defer registration.deinit();
    registration.authenticated = true;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);

    try std.testing.expect(try registration.sendSessionCommands(&out));
    try std.testing.expectEqualStrings("SESSION RESUME reusable\r\nSESSION TOKEN\r\nSESSIONTOKEN\r\n", out.items);
    try std.testing.expect(!try registration.sendSessionCommands(&out));
}

test "unauthenticated registration never transmits a session bearer" {
    const gpa = std.testing.allocator;
    var store = try session_store.Store.init(gpa, "server.example", "alex");
    defer store.deinit();
    try std.testing.expect(try store.observe(message.parse(":server.example NOTICE alex :SESSION TOKEN reusable")));
    var registration = Registration.init(gpa, "eshmaki.me", .tls, .{ .session = &store });
    defer registration.deinit();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);

    try std.testing.expect(!try registration.sendSessionCommands(&out));
    try std.testing.expectEqual(@as(usize, 0), out.items.len);
}

test "authenticated resume swallows 433 until SESSION commands are sent" {
    const gpa = std.testing.allocator;
    var store = try session_store.Store.init(gpa, "server.example", "alex");
    defer store.deinit();
    try std.testing.expect(try store.observe(message.parse(":server.example NOTICE alex :SESSION TOKEN reusable")));
    var registration = Registration.init(gpa, "eshmaki.me", .tls, .{
        .session = &store,
        .now_seconds = 100,
    });
    defer registration.deinit();
    registration.authenticated = true;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    var upgrade: ?u16 = null;
    var collision = message.parse(":irc 433 * alex :Nickname is already in use");
    try std.testing.expect(try registration.consume(&out, &collision, &upgrade));
    try std.testing.expectEqual(@as(usize, 0), out.items.len);
    try std.testing.expect(try registration.sendSessionCommands(&out));
    var later = message.parse(":irc 433 alex newnick :Nickname is already in use");
    try std.testing.expect(!try registration.consume(&out, &later, &upgrade));
}

test "post-registration SASL numerics are not swallowed" {
    const gpa = std.testing.allocator;
    var authzid = [_]u8{};
    var authcid = [_]u8{ 'u', 's', 'e', 'r' };
    var password = [_]u8{ 'p', 'w' };
    var credentials = sasl.Credentials{
        .authorization_identity = &authzid,
        .authentication_identity = &authcid,
        .password = &password,
    };
    var registration = Registration.init(gpa, "irc.example", .tls, .{ .credentials = &credentials });
    defer registration.deinit();
    registration.done = true;
    registration.sasl_session = sasl.Session.init(gpa, &credentials, .{});
    registration.sasl_session.?.phase = .complete;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    var upgrade: ?u16 = null;
    var failed = message.parse(":irc 904 user :SASL authentication failed");
    try std.testing.expect(!try registration.consume(&out, &failed, &upgrade));
    try std.testing.expectEqual(@as(usize, 0), out.items.len);
}

test "unsigned SCRAM 903 completes CAP instead of stalling registration" {
    const gpa = std.testing.allocator;
    var authzid = [_]u8{};
    var authcid = [_]u8{ 'u', 's', 'e', 'r' };
    var password = [_]u8{ 'p', 'w' };
    var credentials = sasl.Credentials{
        .authorization_identity = &authzid,
        .authentication_identity = &authcid,
        .password = &password,
    };
    const preference = [_]sasl.Mechanism{.scram_sha_256};
    var registration = Registration.init(gpa, "irc.example", .tls, .{
        .credentials = &credentials,
        .sasl_preference = &preference,
        .io = std.testing.io,
    });
    defer registration.deinit();
    registration.sasl_session = sasl.Session.init(gpa, &credentials, .{ .preference = &preference });
    registration.sasl_session.?.selected = .scram_sha_256;
    registration.sasl_session.?.phase = .awaiting_result;
    registration.cap.phase = .waiting_sasl;
    registration.cap.registration_open = true;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    var upgrade: ?u16 = null;
    var success = message.parse(":irc 903 user :SASL authentication successful");
    try std.testing.expect(try registration.consume(&out, &success, &upgrade));
    try std.testing.expectEqualStrings("CAP END\r\nMODE ISIRCX\r\n", out.items);
    try std.testing.expect(registration.done);
    try std.testing.expect(!registration.authenticated);
}

test "registration advances CAP then follows Microsoft IRCX probe and enable states" {
    const gpa = std.testing.allocator;
    var registration = Registration.init(gpa, "irc.example", .tls, .{});
    defer registration.deinit();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    var upgrade: ?u16 = null;

    try registration.cap.begin(&out);
    out.clearRetainingCapacity();
    var ls = message.parse(":irc CAP * LS :message-tags echo-message");
    try std.testing.expect(try registration.consume(&out, &ls, &upgrade));
    try std.testing.expect(std.mem.startsWith(u8, out.items, "CAP REQ :"));
    try std.testing.expect(std.mem.indexOf(u8, out.items, "IRCX") == null);

    out.clearRetainingCapacity();
    var ack = message.parse(":irc CAP * ACK :echo-message message-tags");
    try std.testing.expect(try registration.consume(&out, &ack, &upgrade));
    try std.testing.expectEqualStrings("CAP END\r\nMODE ISIRCX\r\n", out.items);
    try std.testing.expect(registration.done);

    out.clearRetainingCapacity();
    var probe_reply = message.parse(":irc 800 * 0 0 ANON 512 *");
    try std.testing.expect(try registration.consume(&out, &probe_reply, &upgrade));
    try std.testing.expectEqualStrings("IRCX\r\n", out.items);

    out.clearRetainingCapacity();
    var enabled_reply = message.parse(":irc 800 comicchat 1 0 ANON 512 *");
    try std.testing.expect(!try registration.consume(&out, &enabled_reply, &upgrade));
    try std.testing.expectEqual(@as(usize, 0), out.items.len);
}

test "registration drives PLAIN SASL and zeroizes caller credentials" {
    const gpa = std.testing.allocator;
    var authzid = [_]u8{};
    var authcid = [_]u8{ 'a', 'l', 'i', 'c', 'e' };
    var password = [_]u8{ 's', 'e', 'c', 'r', 'e', 't' };
    var credentials = sasl.Credentials{
        .authorization_identity = &authzid,
        .authentication_identity = &authcid,
        .password = &password,
    };
    const preference = [_]sasl.Mechanism{.plain};
    var registration = Registration.init(gpa, "irc.example", .tls, .{
        .credentials = &credentials,
        .sasl_preference = &preference,
        .io = std.testing.io,
    });
    defer registration.deinit();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    defer sasl.secureClear(&out);
    var upgrade: ?u16 = null;

    try registration.cap.begin(&out);
    sasl.secureClear(&out);
    var ls = message.parse(":irc CAP * LS :sasl=PLAIN");
    _ = try registration.consume(&out, &ls, &upgrade);
    sasl.secureClear(&out);
    var ack = message.parse(":irc CAP * ACK :sasl");
    _ = try registration.consume(&out, &ack, &upgrade);
    try std.testing.expectEqualStrings("AUTHENTICATE PLAIN\r\n", out.items);

    sasl.secureClear(&out);
    var challenge = message.parse("AUTHENTICATE +");
    _ = try registration.consume(&out, &challenge, &upgrade);
    try std.testing.expect(std.mem.startsWith(u8, out.items, "AUTHENTICATE "));

    sasl.secureClear(&out);
    var success = message.parse(":irc 903 alice :SASL authentication successful");
    _ = try registration.consume(&out, &success, &upgrade);
    try std.testing.expectEqualStrings("CAP END\r\nMODE ISIRCX\r\n", out.items);
    try std.testing.expect(credentials.zeroized);
    try std.testing.expectEqualSlices(u8, &@as([6]u8, @splat(0)), &password);
}

test "plaintext STS advertisement fails closed with the upgrade port" {
    const gpa = std.testing.allocator;
    var registration = Registration.init(gpa, "irc.example", .plaintext, .{});
    defer registration.deinit();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    var upgrade: ?u16 = null;

    try registration.cap.begin(&out);
    out.clearRetainingCapacity();
    var ls = message.parse(":irc CAP * LS :sts=duration=3600,port=6697");
    try std.testing.expectError(error.StsUpgradeRequired, registration.consume(&out, &ls, &upgrade));
    try std.testing.expectEqual(@as(?u16, 6697), upgrade);
}

test "unsupported advertised SASL mechanisms complete CAP without blocking registration" {
    const gpa = std.testing.allocator;
    var authzid = [_]u8{};
    var authcid = [_]u8{ 'm', 'e' };
    var password = [_]u8{ 'p', 'w' };
    var credentials = sasl.Credentials{
        .authorization_identity = &authzid,
        .authentication_identity = &authcid,
        .password = &password,
    };
    const only_external = [_]sasl.Mechanism{.external};
    var registration = Registration.init(gpa, "irc.example", .tls, .{
        .credentials = &credentials,
        .sasl_preference = &only_external,
        .io = std.testing.io,
    });
    defer registration.deinit();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    var upgrade: ?u16 = null;
    try registration.cap.begin(&out);
    out.clearRetainingCapacity();
    var ls = message.parse(":irc CAP * LS :sasl=EXTERNAL");
    _ = try registration.consume(&out, &ls, &upgrade);
    out.clearRetainingCapacity();
    var ack = message.parse(":irc CAP * ACK :sasl");
    _ = try registration.consume(&out, &ack, &upgrade);
    try std.testing.expectEqualStrings("CAP END\r\nMODE ISIRCX\r\n", out.items);
    try std.testing.expect(registration.done);
    try std.testing.expect(credentials.zeroized);
}

test "plaintext SASL advertisement completes CAP without AUTHENTICATE" {
    const gpa = std.testing.allocator;
    var authzid = [_]u8{};
    var authcid = [_]u8{ 'a', 'l', 'i', 'c', 'e' };
    var password = [_]u8{ 's', 'e', 'c', 'r', 'e', 't' };
    var credentials = sasl.Credentials{
        .authorization_identity = &authzid,
        .authentication_identity = &authcid,
        .password = &password,
    };
    const preference = [_]sasl.Mechanism{.plain};
    var registration = Registration.init(gpa, "irc.example", .plaintext, .{
        .credentials = &credentials,
        .sasl_preference = &preference,
        .io = std.testing.io,
    });
    defer registration.deinit();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    var upgrade: ?u16 = null;
    try registration.cap.begin(&out);
    out.clearRetainingCapacity();
    var ls = message.parse(":irc CAP * LS :sasl=PLAIN");
    _ = try registration.consume(&out, &ls, &upgrade);
    out.clearRetainingCapacity();
    var ack = message.parse(":irc CAP * ACK :sasl");
    _ = try registration.consume(&out, &ack, &upgrade);
    try std.testing.expectEqualStrings("CAP END\r\nMODE ISIRCX\r\n", out.items);
    try std.testing.expect(registration.done);
    try std.testing.expect(credentials.zeroized);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "AUTHENTICATE") == null);
}

test "reply reaction and typing commands are bounded tagged client messages" {
    const gpa = std.testing.allocator;
    const owned_host = try gpa.dupe(u8, "irc.example");
    var client = Client{
        .gpa = gpa,
        .transport = undefined,
        .host = owned_host,
        .port = 6697,
        .connect_options = .{},
        .framer = irc.LineFramer.init(gpa),
        // A zero burst keeps commands queued, avoiding a live transport in
        // this deterministic command-generation test.
        .tx = policy.TxQueue.init(gpa, .{}, 0, 1, 0),
        .deadlines = policy.Deadlines.init(0, .{}),
        .aggregator = features_mod.Aggregator.init(gpa, .{}),
        .policy_now_ms = 1000,
    };
    client.registration = Registration.init(gpa, owned_host, .tls, .{});
    try std.testing.expectError(error.CapabilityNotEnabled, client.search("#c", "release checklist"));
    try std.testing.expectError(error.CapabilityNotEnabled, client.editMessage("#c", "msg-1", "corrected text"));
    try std.testing.expectError(error.CapabilityNotEnabled, client.redactMessage("#c", "msg-1", null));
    try std.testing.expectError(error.CapabilityNotEnabled, client.markRead("#c", null));
    try std.testing.expectError(error.CapabilityNotEnabled, client.metadata("*", "GET", null, null, null));
    try std.testing.expectError(error.CapabilityNotEnabled, client.chatHistoryLatest("#c", "*", 20));
    try std.testing.expectError(error.MessageTagsNotEnabled, client.privmsgWithTopic("#c", "general", "hello"));
    try std.testing.expectError(error.CapabilityNotEnabled, client.privmsgWithChannelContext("alice", "#c", "hello"));
    // Keep this command-builder test independent from the global desired
    // profile: the profile intentionally evolves with the capability catalog.
    const desired = [_][]const u8{
        "batch",
        "draft/account-registration",
        "labeled-response",
        "message-tags",
        "draft/chathistory",
        "draft/search",
        "draft/message-editing",
        "draft/message-redaction",
        "draft/read-marker",
        "draft/metadata-2",
        "onyx/topics",
        "draft/channel-context",
    };
    client.registration.?.cap.config.desired = &desired;
    client.features = try features_mod.State.init(gpa, "me", .{});
    try client.registration.?.cap.begin(&client.out);
    client.out.clearRetainingCapacity();
    _ = try client.registration.?.cap.handle(&client.out, message.parse(":irc CAP * LS :batch draft/account-registration labeled-response message-tags draft/chathistory draft/search draft/message-editing draft/message-redaction draft/read-marker draft/metadata-2 onyx/topics draft/channel-context"));
    client.out.clearRetainingCapacity();
    _ = try client.registration.?.cap.handle(&client.out, message.parse(":irc CAP * ACK :batch draft/account-registration labeled-response message-tags draft/chathistory draft/search draft/message-editing draft/message-redaction draft/read-marker draft/metadata-2 onyx/topics draft/channel-context"));
    client.out.clearRetainingCapacity();
    defer {
        if (client.restoration) |*restoration| restoration.deinit();
        client.registration.?.deinit();
        client.features.?.deinit();
        client.aggregator.deinit();
        client.tx.deinit();
        for (client.typing_targets.items) |entry| gpa.free(entry.target);
        client.typing_targets.deinit(gpa);
        client.framer.deinit();
        sasl.secureClear(&client.out);
        client.out.deinit(gpa);
        gpa.free(owned_host);
    }

    try client.reply("#c", "msg-1", "reply text");
    try std.testing.expect(std.mem.indexOf(u8, client.tx.items.items[0].bytes, "+draft/reply=msg-1") != null);
    try std.testing.expect(std.mem.indexOf(u8, client.tx.items.items[0].bytes, "label=cc-1") != null);
    try client.react("#c", "msg-1", "wave", false);
    try std.testing.expect(std.mem.indexOf(u8, client.tx.items.items[1].bytes, "+draft/react=wave") != null);
    try client.typing("#c", .active);
    try std.testing.expectError(error.TypingRateLimited, client.typing("#c", .paused));
    client.policy_now_ms = 4000;
    try client.typing("#c", .done);
    try std.testing.expect(std.mem.indexOf(u8, client.tx.items.items[3].bytes, "+typing=done") != null);

    try client.search("#c", "release checklist");
    try client.editMessage("#c", "msg-1", "corrected text");
    try client.redactMessage("#c", "msg-1", "off-topic");
    try client.markRead("#c", "timestamp=2026-07-22T00:00:00Z");
    try client.metadata("*", "SET", "theme", "public", "ink");
    try std.testing.expectError(error.InvalidIrcParameter, client.chatHistoryLatest("*", "*", 20));
    try std.testing.expectError(error.InvalidIrcParameter, client.chatHistoryLatest("#c", "bogus", 20));
    try std.testing.expectError(error.InvalidIrcParameter, client.chatHistoryLatest("#c", "msgid=bad;id", 20));
    try std.testing.expectError(error.InvalidIrcParameter, client.chatHistoryLatest("#c", "timestamp=2026-02-30T00:00:00.000Z", 20));
    try std.testing.expectError(error.InvalidIrcParameter, client.privmsgWithTopic("alice", "general", "topic text"));
    try std.testing.expectError(error.InvalidIrcParameter, client.privmsgWithTopic("#c", "bad,label", "topic text"));
    try std.testing.expectError(error.InvalidIrcParameter, client.privmsgWithChannelContext("#c", "#other", "direct text"));
    try std.testing.expectError(error.InvalidIrcParameter, client.privmsgWithChannelContext("alice", "not-a-channel", "direct text"));
    try client.privmsgWithTopic("#c", "release plan", "topic text");
    try client.noticeWithTopic("#c", "release plan", "topic notice");
    try client.privmsgWithChannelContext("alice", "#c", "direct text");
    try client.chatHistoryLatest("#c", "msgid=msg-1", 20);
    try client.chatHistoryLatestTopic("#c", "timestamp=2026-07-22T00:00:00.000Z", 20, "release plan");
    try std.testing.expect(std.mem.indexOf(u8, client.tx.items.items[4].bytes, "SEARCH #c :release checklist") != null);
    try std.testing.expect(std.mem.indexOf(u8, client.tx.items.items[5].bytes, "EDIT #c msg-1 :corrected text") != null);
    try std.testing.expect(std.mem.indexOf(u8, client.tx.items.items[6].bytes, "REDACT #c msg-1 :off-topic") != null);
    try std.testing.expect(std.mem.indexOf(u8, client.tx.items.items[7].bytes, "MARKREAD #c timestamp=2026-07-22T00:00:00Z") != null);
    try std.testing.expect(std.mem.indexOf(u8, client.tx.items.items[8].bytes, "METADATA * SET theme public :ink") != null);
    try std.testing.expect(std.mem.indexOf(u8, client.tx.items.items[9].bytes, "+onyx/topic=release\\splan") != null);
    try std.testing.expect(std.mem.indexOf(u8, client.tx.items.items[9].bytes, "PRIVMSG #c :topic text") != null);
    try std.testing.expect(std.mem.indexOf(u8, client.tx.items.items[10].bytes, "+onyx/topic=release\\splan") != null);
    try std.testing.expect(std.mem.indexOf(u8, client.tx.items.items[10].bytes, "NOTICE #c :topic notice") != null);
    try std.testing.expect(std.mem.indexOf(u8, client.tx.items.items[11].bytes, "+draft/channel-context=#c") != null);
    try std.testing.expect(std.mem.indexOf(u8, client.tx.items.items[11].bytes, "PRIVMSG alice :direct text") != null);
    try std.testing.expect(std.mem.indexOf(u8, client.tx.items.items[12].bytes, "CHATHISTORY LATEST #c msgid=msg-1 20") != null);
    try std.testing.expect(std.mem.indexOf(u8, client.tx.items.items[13].bytes, "+onyx/topic=release\\splan") != null);
    try std.testing.expect(std.mem.indexOf(u8, client.tx.items.items[13].bytes, "CHATHISTORY LATEST #c timestamp=2026-07-22T00:00:00.000Z 20") != null);

    _ = try client.features.?.observe(&message.parse(":irc 005 me UTF8ONLY :are supported"));
    try std.testing.expectError(error.InvalidUtf8, client.privmsg("#c", &.{0xff}));
    try std.testing.expectError(error.InvalidMessageReference, client.reply("#c", "bad id", "text"));

    var password = [_]u8{ 'p', 'w' };
    try client.accountRegister("*", "user@example.test", &password);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0 }, &password);
    try std.testing.expect(client.tx.items.items[14].sensitive);
    try std.testing.expect(std.mem.indexOf(u8, client.tx.items.items[14].bytes, "REGISTER * user@example.test pw") != null);
    try client.pins("#c", .list, null);
    try client.pins("#c", .add, "msg-1");
    try client.pins("#c", .delete, "msg-1");
    try client.pins("#c", .clear, null);
    try std.testing.expect(std.mem.indexOf(u8, client.tx.items.items[15].bytes, "PINS #c LIST\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, client.tx.items.items[16].bytes, "PINS #c ADD msg-1\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, client.tx.items.items[17].bytes, "PINS #c DEL msg-1\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, client.tx.items.items[18].bytes, "PINS #c CLEAR\r\n") != null);
    try std.testing.expectError(error.InvalidIrcParameter, client.pins("#c", .add, "bad;id"));
    try client.monitor(.add, "alice,bob");
    try client.monitor(.remove, "alice");
    try client.monitor(.clear, null);
    try client.monitor(.list, null);
    try client.monitor(.status, null);
    try std.testing.expect(std.mem.indexOf(u8, client.tx.items.items[19].bytes, "MONITOR + alice,bob\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, client.tx.items.items[20].bytes, "MONITOR - alice\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, client.tx.items.items[21].bytes, "MONITOR C\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, client.tx.items.items[22].bytes, "MONITOR L\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, client.tx.items.items[23].bytes, "MONITOR S\r\n") != null);
    try client.silence(.list, null);
    try client.silence(.add, "*!*@bad.example");
    try client.silence(.remove, "*!*@bad.example");
    try std.testing.expect(std.mem.indexOf(u8, client.tx.items.items[24].bytes, "SILENCE\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, client.tx.items.items[25].bytes, "SILENCE +*!*@bad.example\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, client.tx.items.items[26].bytes, "SILENCE -*!*@bad.example\r\n") != null);
    try client.chatHistoryBefore("#c", "msgid=msg-2", 10);
    try client.chatHistoryAfter("#c", "timestamp=2026-07-22T00:00:00.000Z", 10);
    try client.chatHistoryAround("#c", "msgid=msg-3", 10);
    try client.chatHistoryAroundWithSecond("#c", "msgid=msg-3", "timestamp=2026-07-22T00:00:00.000Z", 10);
    try client.chatHistoryBetween("#c", "msgid=msg-1", "msgid=msg-4", 10);
    try client.chatHistoryTargets("*", "timestamp=2026-07-22T00:00:00.000Z", 10);
    try client.accept(.list, null);
    try client.accept(.add, "alice");
    try client.accept(.remove, "alice");
    try std.testing.expect(std.mem.indexOf(u8, client.tx.items.items[27].bytes, "CHATHISTORY BEFORE #c msgid=msg-2 10") != null);
    try std.testing.expect(std.mem.indexOf(u8, client.tx.items.items[28].bytes, "CHATHISTORY AFTER #c timestamp=2026-07-22T00:00:00.000Z 10") != null);
    try std.testing.expect(std.mem.indexOf(u8, client.tx.items.items[29].bytes, "CHATHISTORY AROUND #c msgid=msg-3 10") != null);
    try std.testing.expect(std.mem.indexOf(u8, client.tx.items.items[30].bytes, "CHATHISTORY AROUND #c msgid=msg-3 timestamp=2026-07-22T00:00:00.000Z 10") != null);
    try std.testing.expect(std.mem.indexOf(u8, client.tx.items.items[31].bytes, "CHATHISTORY BETWEEN #c msgid=msg-1 msgid=msg-4 10") != null);
    try std.testing.expect(std.mem.indexOf(u8, client.tx.items.items[32].bytes, "CHATHISTORY TARGETS * timestamp=2026-07-22T00:00:00.000Z 10") != null);
    try std.testing.expect(std.mem.indexOf(u8, client.tx.items.items[33].bytes, "ACCEPT *\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, client.tx.items.items[34].bytes, "ACCEPT +alice\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, client.tx.items.items[35].bytes, "ACCEPT -alice\r\n") != null);
    try std.testing.expectError(error.InvalidIrcParameter, client.chatHistoryTargets("*", "*", 0));
    try std.testing.expectError(error.InvalidIrcParameter, client.accept(.add, "alice@example"));
}

test "Onyx narrow tag capabilities and no-implicit-names alias work without message-tags" {
    const gpa = std.testing.allocator;
    const owned_host = try gpa.dupe(u8, "irc.example");
    var client = Client{
        .gpa = gpa,
        .transport = undefined,
        .host = owned_host,
        .port = 6697,
        .connect_options = .{},
        .framer = irc.LineFramer.init(gpa),
        .tx = policy.TxQueue.init(gpa, .{}, 0, 1, 0),
        .deadlines = policy.Deadlines.init(0, .{}),
        .aggregator = features_mod.Aggregator.init(gpa, .{}),
        .policy_now_ms = 4000,
    };
    client.registration = Registration.init(gpa, owned_host, .tls, .{});
    const desired = [_][]const u8{ "draft/reply", "draft/react", "draft/typing", "draft/no-implicit-names", "onyx/topics", "draft/channel-context" };
    client.registration.?.cap.config.desired = &desired;
    try client.registration.?.cap.begin(&client.out);
    client.out.clearRetainingCapacity();
    _ = try client.registration.?.cap.handle(&client.out, message.parse(":irc CAP * LS :draft/reply draft/react draft/typing draft/no-implicit-names onyx/topics draft/channel-context"));
    client.out.clearRetainingCapacity();
    _ = try client.registration.?.cap.handle(&client.out, message.parse(":irc CAP * ACK :draft/reply draft/react draft/typing draft/no-implicit-names onyx/topics draft/channel-context"));
    client.out.clearRetainingCapacity();
    defer {
        if (client.restoration) |*restoration| restoration.deinit();
        client.registration.?.deinit();
        client.aggregator.deinit();
        client.tx.deinit();
        for (client.typing_targets.items) |entry| gpa.free(entry.target);
        client.typing_targets.deinit(gpa);
        client.framer.deinit();
        client.out.deinit(gpa);
        gpa.free(owned_host);
    }

    try client.reply("#c", "msg-1", "reply text");
    try client.react("#c", "msg-1", "wave", false);
    try client.typing("#c", .active);
    try client.privmsgWithTopic("#c", "general", "topic text");
    try std.testing.expectError(error.MessageTagsNotEnabled, client.privmsgWithChannelContext("alice", "#c", "direct text"));
    try client.join("#c");
    try std.testing.expect(std.mem.indexOf(u8, client.tx.items.items[0].bytes, "+draft/reply=msg-1") != null);
    try std.testing.expect(std.mem.indexOf(u8, client.tx.items.items[1].bytes, "+draft/react=wave") != null);
    try std.testing.expect(std.mem.indexOf(u8, client.tx.items.items[2].bytes, "+typing=active") != null);
    try std.testing.expect(std.mem.indexOf(u8, client.tx.items.items[3].bytes, "+onyx/topic=general PRIVMSG #c :topic text") != null);
    try std.testing.expectEqualStrings("JOIN #c\r\nNAMES #c\r\n", client.tx.items.items[4].bytes);
}

test "channel context requires both its semantic and generic relay capabilities" {
    const gpa = std.testing.allocator;
    const owned_host = try gpa.dupe(u8, "irc.example");
    var client = Client{
        .gpa = gpa,
        .transport = undefined,
        .host = owned_host,
        .port = 6697,
        .connect_options = .{},
        .framer = irc.LineFramer.init(gpa),
        .tx = policy.TxQueue.init(gpa, .{}, 0, 1, 0),
        .deadlines = policy.Deadlines.init(0, .{}),
        .aggregator = features_mod.Aggregator.init(gpa, .{}),
    };
    client.registration = Registration.init(gpa, owned_host, .tls, .{});
    const desired = [_][]const u8{"message-tags"};
    client.registration.?.cap.config.desired = &desired;
    try client.registration.?.cap.begin(&client.out);
    client.out.clearRetainingCapacity();
    _ = try client.registration.?.cap.handle(&client.out, message.parse(":irc CAP * LS :message-tags"));
    client.out.clearRetainingCapacity();
    _ = try client.registration.?.cap.handle(&client.out, message.parse(":irc CAP * ACK :message-tags"));
    client.out.clearRetainingCapacity();
    defer {
        if (client.restoration) |*restoration| restoration.deinit();
        client.registration.?.deinit();
        client.aggregator.deinit();
        client.tx.deinit();
        client.framer.deinit();
        client.out.deinit(gpa);
        gpa.free(owned_host);
    }
    try std.testing.expectError(error.CapabilityNotEnabled, client.privmsgWithChannelContext("alice", "#c", "direct text"));
}

test "Onyx topic and channel-context bounds match the pinned protocol helpers" {
    var topic_max: [50]u8 = undefined;
    @memset(topic_max[0..], 't');
    var topic_over: [51]u8 = undefined;
    @memset(topic_over[0..], 't');
    try std.testing.expect(validTopicLabel(&topic_max));
    try std.testing.expect(!validTopicLabel(&topic_over));
    try std.testing.expect(validTopicLabel("semi;colon"));
    try std.testing.expect(validTopicLabel("slash\\label"));
    var escaped: std.ArrayList(u8) = .empty;
    defer escaped.deinit(std.testing.allocator);
    try message.escapeTagValue(&escaped, std.testing.allocator, "semi;slash\\label");
    try std.testing.expectEqualStrings("semi\\:slash\\\\label", escaped.items);

    var context_max: [64]u8 = undefined;
    @memset(context_max[0..], 'c');
    context_max[0] = '#';
    var context_over: [65]u8 = undefined;
    @memset(context_over[0..], 'c');
    context_over[0] = '#';
    try std.testing.expect(validChannelContext(&context_max));
    try std.testing.expect(!validChannelContext(&context_over));
    try std.testing.expect(!validChannelContext("#semi;colon"));
    try std.testing.expect(!validChannelContext("#back\\slash"));
}

test "live registration probes IRCX before CAP NICK and USER" {
    const gpa = std.testing.allocator;
    var registration = Registration.init(gpa, "irc.example", .tls, .{ .want_ircx = true });
    defer registration.deinit();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);

    try appendRegistrationStart(&registration, &out, gpa, "comicchat", "comicchat", "Comic Chat");
    try std.testing.expectEqualStrings(
        "MODE ISIRCX\r\nCAP LS 302\r\nNICK comicchat\r\nUSER comicchat 0 * :Comic Chat\r\n",
        out.items,
    );
    try std.testing.expect(registration.ircx_probe_sent);
    try std.testing.expect(registration.nick_sent);
}

test "SASL registration delays NICK until CAP END" {
    const gpa = std.testing.allocator;
    var authzid = [_]u8{};
    var authcid = [_]u8{ 'a', 'l', 'i', 'c', 'e' };
    var password = [_]u8{ 's', 'e', 'c', 'r', 'e', 't' };
    var credentials = sasl.Credentials{
        .authorization_identity = &authzid,
        .authentication_identity = &authcid,
        .password = &password,
    };
    const preference = [_]sasl.Mechanism{.plain};
    var registration = Registration.init(gpa, "irc.example", .tls, .{
        .credentials = &credentials,
        .sasl_preference = &preference,
        .io = std.testing.io,
        .want_ircx = true,
    });
    defer registration.deinit();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    defer sasl.secureClear(&out);
    var upgrade: ?u16 = null;

    try appendRegistrationStart(&registration, &out, gpa, "alice", "alice", "Alice Example");
    try std.testing.expectEqualStrings("MODE ISIRCX\r\nCAP LS 302\r\n", out.items);
    try std.testing.expect(!registration.nick_sent);

    sasl.secureClear(&out);
    var ls = message.parse(":irc CAP * LS :sasl=PLAIN");
    _ = try registration.consume(&out, &ls, &upgrade);
    sasl.secureClear(&out);
    var ack = message.parse(":irc CAP * ACK :sasl");
    _ = try registration.consume(&out, &ack, &upgrade);
    try std.testing.expectEqualStrings("AUTHENTICATE PLAIN\r\n", out.items);

    sasl.secureClear(&out);
    var challenge = message.parse("AUTHENTICATE +");
    _ = try registration.consume(&out, &challenge, &upgrade);
    try std.testing.expect(std.mem.startsWith(u8, out.items, "AUTHENTICATE "));

    sasl.secureClear(&out);
    var success = message.parse(":irc 903 alice :SASL authentication successful");
    _ = try registration.consume(&out, &success, &upgrade);
    try std.testing.expect(std.mem.startsWith(u8, out.items, "CAP END\r\n"));
    try std.testing.expect(std.mem.indexOf(u8, out.items, "NICK alice\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "USER alice 0 * :Alice Example\r\n") != null);
    try std.testing.expect(registration.nick_sent);
    try std.testing.expect(registration.done);
}

test "Microsoft comment controls retain the source PRIVMSG form on IRCX" {
    const gpa = std.testing.allocator;
    const owned_host = try gpa.dupe(u8, "irc.example");
    var client = Client{
        .gpa = gpa,
        .transport = undefined,
        .host = owned_host,
        .port = 6697,
        .connect_options = .{},
        .framer = irc.LineFramer.init(gpa),
        .tx = policy.TxQueue.init(gpa, .{}, 0, 1, 0),
        .deadlines = policy.Deadlines.init(0, .{}),
        .aggregator = features_mod.Aggregator.init(gpa, .{}),
    };
    defer {
        if (client.restoration) |*restoration| restoration.deinit();
        client.aggregator.deinit();
        client.tx.deinit();
        client.framer.deinit();
        client.out.deinit(gpa);
        gpa.free(owned_host);
    }

    try client.announceAvatar("#root", "anna", false);
    try std.testing.expectEqualStrings(
        "PRIVMSG #root :# Appears as Anna.\r\n",
        client.tx.items.items[0].bytes,
    );
    try client.comicData("#root", "#G123E456M1");
    try std.testing.expectEqualStrings(
        "DATA #root CCUDI1 :#G123E456M1\r\n",
        client.tx.items.items[1].bytes,
    );
    try client.announceAvatar("#root", "anna", true);
    try std.testing.expectEqualStrings(
        "PRIVMSG #root :# Appears as Anna.\r\n",
        client.tx.items.items[2].bytes,
    );
    try client.announceAvatar("#root", "anna color", false);
    try std.testing.expectEqualStrings(
        "PRIVMSG #root :# Appears as AnnaColor.\r\n",
        client.tx.items.items[3].bytes,
    );
    try client.syncBackdrop("#root", "room.bgb", null, true);
    try std.testing.expectEqualStrings(
        "PRIVMSG #root :# BDrop2: room.bgb,\r\n",
        client.tx.items.items[4].bytes,
    );
    try std.testing.expectEqualStrings(
        "PRIVMSG #root :# BDrop:  room\r\n",
        client.tx.items.items[5].bytes,
    );
    try client.sendSound("#root", "Chime.wav", "hello there");
    try std.testing.expectEqualStrings(
        "PRIVMSG #root :\x01SOUND Chime.wav hello there\x01\r\n",
        client.tx.items.items[6].bytes,
    );
    try client.sendSound("alice", "Door bell.wav", "come in");
    try std.testing.expectEqualStrings(
        "PRIVMSG alice :\x01SOUND Door\x10@bell.wav come in\x01\r\n",
        client.tx.items.items[7].bytes,
    );
    try client.joinWithKey("#locked", "swordfish");
    try std.testing.expectEqualStrings(
        "JOIN #locked swordfish\r\n",
        client.tx.items.items[8].bytes,
    );
    try client.create("#new", "+nt", "42", "secret");
    try std.testing.expectEqualStrings(
        "CREATE #new +nt 42 secret\r\n",
        client.tx.items.items[9].bytes,
    );
    try client.kick("#root", "trouble", "flooding the room");
    try std.testing.expectEqualStrings(
        "KICK #root trouble :flooding the room\r\n",
        client.tx.items.items[10].bytes,
    );
    try client.kick("#root", "quiet", "");
    try std.testing.expectEqualStrings(
        "KICK #root quiet :\r\n",
        client.tx.items.items[11].bytes,
    );
    try client.setTopic("#root", "Welcome");
    try std.testing.expectEqualStrings(
        "TOPIC #root :Welcome\r\n",
        client.tx.items.items[12].bytes,
    );
    try client.sendAwayControl("#root", "getting coffee");
    try std.testing.expectEqualStrings(
        "PRIVMSG #root :\x01AWAY getting coffee\x01\r\n",
        client.tx.items.items[13].bytes,
    );
    try client.ctcpReply("alice", "PING", "12345");
    try std.testing.expectEqualStrings(
        "NOTICE alice :\x01PING 12345\x01\r\n",
        client.tx.items.items[14].bytes,
    );
    try client.ctcpReply("alice", "EMAIL", "");
    try std.testing.expectEqualStrings(
        "NOTICE alice :\x01EMAIL \x01\r\n",
        client.tx.items.items[15].bytes,
    );
}

test "IRCX workflow commands follow the draft wire grammar" {
    const gpa = std.testing.allocator;
    const owned_host = try gpa.dupe(u8, "irc.example");
    var client = Client{
        .gpa = gpa,
        .transport = undefined,
        .host = owned_host,
        .port = 6697,
        .connect_options = .{},
        .framer = irc.LineFramer.init(gpa),
        .tx = policy.TxQueue.init(gpa, .{}, 0, 1, 0),
        .deadlines = policy.Deadlines.init(0, .{}),
        .aggregator = features_mod.Aggregator.init(gpa, .{}),
    };
    defer {
        if (client.restoration) |*restoration| restoration.deinit();
        client.aggregator.deinit();
        client.tx.deinit();
        client.framer.deinit();
        client.out.deinit(gpa);
        gpa.free(owned_host);
    }

    try client.listRooms("N=#root,>10", "25", true);
    try client.queryProperty("#root", "TOPIC,ONJOIN");
    try client.setProperty("#root", "TOPIC", "New topic");
    try client.accessList("#root");
    try client.accessAdd("#root", "HOST", "anna!*@*", "", "trusted helper");
    try client.accessDelete("#root", "HOST", "anna!*@*");
    try client.accessClear("#root", "DENY");
    try client.eventList("CHANNEL");
    try client.eventChange(true, "MEMBER", "*!*@*");
    try client.ircxRequest("#root", "APP.INFO", "version?");
    try client.ircxReply("#root", "APP.INFO", "ComicChat");
    try client.whisper("#root", "anna,bob", "secret panel plan");
    var auth = [_]u8{ 's', 'e', 'c', 'r', 'e', 't' };
    try client.ircxAuth("PLAIN", "I", &auth);
    try std.testing.expect(std.mem.allEqual(u8, &auth, 0));

    const expected = [_][]const u8{
        "LISTX N=#root,>10 25\r\n",
        "PROP #root TOPIC,ONJOIN\r\n",
        "PROP #root TOPIC :New topic\r\n",
        "ACCESS #root LIST\r\n",
        "ACCESS #root ADD HOST anna!*@* 0 :trusted helper\r\n",
        "ACCESS #root DELETE HOST anna!*@*\r\n",
        "ACCESS #root CLEAR DENY\r\n",
        "EVENT LIST CHANNEL\r\n",
        "EVENT ADD MEMBER *!*@*\r\n",
        "REQUEST #root APP.INFO :version?\r\n",
        "REPLY #root APP.INFO :ComicChat\r\n",
        "WHISPER #root anna,bob :secret panel plan\r\n",
        "AUTH PLAIN I :secret\r\n",
    };
    try std.testing.expectEqual(expected.len, client.tx.items.items.len);
    for (expected, client.tx.items.items) |wire, item| try std.testing.expectEqualStrings(wire, item.bytes);
}

test "LIST ACCESS and PROP reject invented or invalid atoms" {
    const gpa = std.testing.allocator;
    const owned_host = try gpa.dupe(u8, "irc.example");
    var client = Client{
        .gpa = gpa,
        .transport = undefined,
        .host = owned_host,
        .port = 6697,
        .connect_options = .{},
        .framer = irc.LineFramer.init(gpa),
        .tx = policy.TxQueue.init(gpa, .{}, 0, 1, 0),
        .deadlines = policy.Deadlines.init(0, .{}),
        .aggregator = features_mod.Aggregator.init(gpa, .{}),
    };
    defer {
        if (client.restoration) |*restoration| restoration.deinit();
        client.aggregator.deinit();
        client.tx.deinit();
        client.framer.deinit();
        client.out.deinit(gpa);
        gpa.free(owned_host);
    }

    try std.testing.expectError(error.InvalidIrcParameter, client.listRooms("N=#root", "", false));
    try std.testing.expectError(error.InvalidIrcParameter, client.listRooms("#root,>10", "", false));
    try client.listRooms("#root,#lobby", "", false);
    try client.listRooms("", "25", true);
    try std.testing.expectError(error.InvalidIrcParameter, client.listRooms("", "nope", true));
    try std.testing.expectError(error.InvalidIrcParameter, client.queryProperty("#root", "TOPIC ONJOIN"));
    try std.testing.expectError(error.InvalidIrcParameter, client.setProperty("#root", "TOPIC TOPIC", "x"));
    try client.queryProperty("#root", "*");
    try client.setProperty("#root", "TOPIC", "");
    try std.testing.expectError(error.InvalidIrcParameter, client.accessAdd("#root", "FOUNDER", "anna!*@*", "", ""));
    try std.testing.expectError(error.InvalidIrcParameter, client.accessAdd("#root", "HOST", "anna !*@*", "", ""));
    try std.testing.expectError(error.InvalidIrcParameter, client.accessAdd("#root", "HOST", "anna!*@*", "soon", ""));
    try client.accessAdd("#root", "grant", "anna!*@*", "15", "");
    try std.testing.expectEqualStrings("LIST #root,#lobby\r\n", client.tx.items.items[0].bytes);
    try std.testing.expectEqualStrings("LISTX 25\r\n", client.tx.items.items[1].bytes);
    try std.testing.expectEqualStrings("PROP #root *\r\n", client.tx.items.items[2].bytes);
    try std.testing.expectEqualStrings("PROP #root TOPIC :\r\n", client.tx.items.items[3].bytes);
    try std.testing.expectEqualStrings("ACCESS #root ADD grant anna!*@* 15\r\n", client.tx.items.items[4].bytes);
}

test "join and create remember restoration and replay JOIN without chat" {
    const gpa = std.testing.allocator;
    const owned_host = try gpa.dupe(u8, "irc.example");
    var client = Client{
        .gpa = gpa,
        .transport = undefined,
        .host = owned_host,
        .port = 6697,
        .connect_options = .{},
        .framer = irc.LineFramer.init(gpa),
        .tx = policy.TxQueue.init(gpa, .{}, 0, 1, 0),
        .deadlines = policy.Deadlines.init(0, .{}),
        .aggregator = features_mod.Aggregator.init(gpa, .{}),
    };
    defer {
        if (client.restoration) |*restoration| restoration.deinit();
        client.aggregator.deinit();
        client.tx.deinit();
        client.framer.deinit();
        client.out.deinit(gpa);
        gpa.free(owned_host);
    }

    try client.joinWithKey("#locked", "swordfish");
    try client.create("#new", "+nt", "42", "secret");
    try std.testing.expect(client.hasRestorationTargets());
    client.noteHistoryCursor(&message.parse("@msgid=abc :alice PRIVMSG #locked :hello"));
    try client.part("#new");
    try std.testing.expect(client.hasRestorationTargets());

    var held = policy.Restoration.init(gpa);
    defer held.deinit();
    client.takeRestoration(&held);
    try std.testing.expect(!client.hasRestorationTargets());
    try std.testing.expectEqual(@as(usize, 1), held.targetCount());
    try std.testing.expectEqualStrings("msgid=abc", held.targets.items[0].after.?);

    var replay: std.ArrayList(u8) = .empty;
    defer replay.deinit(gpa);
    try held.appendCommands(&replay, gpa, 0);
    try std.testing.expect(std.mem.indexOf(u8, replay.items, "JOIN #locked swordfish") != null);
    try std.testing.expect(std.mem.indexOf(u8, replay.items, "NAMES #locked") != null);
    try std.testing.expect(std.mem.indexOf(u8, replay.items, "CHATHISTORY") == null);
    try std.testing.expect(std.mem.indexOf(u8, replay.items, "PRIVMSG") == null);

    client.adoptRestoration(&held);
    try std.testing.expect(client.hasRestorationTargets());
    client.renameRestoration("#locked", "#vault");
    try std.testing.expect(client.hasRestorationTargets());
    try client.queueRestoration();
    const queued = client.tx.items.items[client.tx.items.items.len - 1].bytes;
    try std.testing.expect(std.mem.indexOf(u8, queued, "JOIN #vault swordfish") != null);
    try std.testing.expect(std.mem.indexOf(u8, queued, "CHATHISTORY") == null);
    client.forgetRestoration("#vault");
    try std.testing.expect(!client.hasRestorationTargets());
}

test "outgoing PRIVMSG records an echo without echo-message" {
    const gpa = std.testing.allocator;
    const owned_host = try gpa.dupe(u8, "irc.example");
    var client = Client{
        .gpa = gpa,
        .transport = undefined,
        .host = owned_host,
        .port = 6697,
        .connect_options = .{},
        .framer = irc.LineFramer.init(gpa),
        .tx = policy.TxQueue.init(gpa, .{}, 0, 1, 0),
        .deadlines = policy.Deadlines.init(0, .{}),
        .aggregator = features_mod.Aggregator.init(gpa, .{}),
    };
    client.features = try features_mod.State.init(gpa, "me", .{});
    defer {
        if (client.restoration) |*restoration| restoration.deinit();
        client.features.?.deinit();
        client.aggregator.deinit();
        client.tx.deinit();
        client.framer.deinit();
        client.out.deinit(gpa);
        gpa.free(owned_host);
    }

    try client.privmsg("#c", "hello");
    try std.testing.expect(!client.capabilityEnabled("echo-message"));
    try std.testing.expect(try client.features.?.observe(&message.parse(":me!u@h PRIVMSG #c :hello")));
    try std.testing.expect(!try client.features.?.observe(&message.parse(":me!u@h PRIVMSG #c :hello")));
}

test "session-sync skips restoration JOINs and MODES splits advertised lines" {
    const gpa = std.testing.allocator;
    const owned_host = try gpa.dupe(u8, "eshmaki.me");
    var client = Client{
        .gpa = gpa,
        .transport = undefined,
        .host = owned_host,
        .port = 6697,
        .connect_options = .{ .security = .plaintext },
        .framer = irc.LineFramer.init(gpa),
        .tx = policy.TxQueue.init(gpa, .{}, 0, 1, 0),
        .deadlines = policy.Deadlines.init(0, .{}),
        .aggregator = features_mod.Aggregator.init(gpa, .{}),
    };
    client.features = try features_mod.State.init(gpa, "me", .{});
    client.registration = Registration.init(gpa, owned_host, .plaintext, .{});
    defer {
        if (client.restoration) |*restoration| restoration.deinit();
        client.registration.?.deinit();
        client.features.?.deinit();
        client.aggregator.deinit();
        client.tx.deinit();
        client.framer.deinit();
        client.out.deinit(gpa);
        gpa.free(owned_host);
    }

    try client.identify("alice", "secret", "");
    try std.testing.expect(std.mem.indexOf(u8, client.tx.items.items[client.tx.items.items.len - 1].bytes, "IDENTIFY alice") != null);
    var password = [_]u8{ 'h', 'o', 'r', 's', 'e' };
    try client.accountRegister("alice", "*", &password);
    try std.testing.expect(std.mem.indexOf(u8, client.tx.items.items[client.tx.items.items.len - 1].bytes, "REGISTER alice *") != null);
    try client.sendService("MEMO", &.{"LIST"});
    try std.testing.expect(std.mem.indexOf(u8, client.tx.items.items[client.tx.items.items.len - 1].bytes, "MEMO") != null);

    if (client.features) |*state|
        _ = try state.observe(&message.parse(":irc 005 me MODES=1 :are supported"));
    try client.setMode("#root", "+imn", "");
    const last = client.tx.items.items[client.tx.items.items.len - 1].bytes;
    try std.testing.expect(std.mem.indexOf(u8, last, "MODE #root +i\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, last, "MODE #root +m\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, last, "MODE #root +n\r\n") != null);

    try client.joinWithKey("#root", "swordfish");
    try std.testing.expect(client.hasRestorationTargets());
    try std.testing.expect(!client.projectsSessionChannels());
    try client.registration.?.cap.begin(&client.out);
    client.out.clearRetainingCapacity();
    _ = try client.registration.?.cap.handle(&client.out, message.parse(":irc CAP * LS :onyx/session-sync"));
    client.out.clearRetainingCapacity();
    _ = try client.registration.?.cap.handle(&client.out, message.parse(":irc CAP * ACK :onyx/session-sync"));
    try std.testing.expect(client.projectsSessionChannels());
    const before = client.tx.items.items.len;
    try client.queueRestoration();
    try std.testing.expectEqual(before, client.tx.items.items.len);
}

test "advertised ACCOUNTEXTBAN, CHATHISTORY, EXCEPTS, and UTF-8 stay live" {
    const gpa = std.testing.allocator;
    const owned_host = try gpa.dupe(u8, "eshmaki.me");
    var client = Client{
        .gpa = gpa,
        .transport = undefined,
        .host = owned_host,
        .port = 6697,
        .connect_options = .{ .security = .plaintext },
        .framer = irc.LineFramer.init(gpa),
        .tx = policy.TxQueue.init(gpa, .{}, 0, 1, 0),
        .deadlines = policy.Deadlines.init(0, .{}),
        .aggregator = features_mod.Aggregator.init(gpa, .{}),
    };
    client.features = try features_mod.State.init(gpa, "me", .{});
    client.registration = Registration.init(gpa, owned_host, .plaintext, .{});
    defer {
        if (client.restoration) |*restoration| restoration.deinit();
        client.registration.?.deinit();
        client.features.?.deinit();
        client.aggregator.deinit();
        client.tx.deinit();
        client.framer.deinit();
        client.out.deinit(gpa);
        gpa.free(owned_host);
    }

    if (client.features) |*state|
        _ = try state.observe(&message.parse(":irc 005 me UTF8ONLY CHATHISTORY=50 EXCEPTS=x INVEX=y ACCOUNTEXTBAN=a :are supported"));
    try std.testing.expect(client.features.?.extban.allows('a'));
    try std.testing.expectError(error.InvalidUtf8, client.setTopic("#root", &.{0xff}));
    try std.testing.expectError(error.InvalidUtf8, client.setAway(&.{0xff}));
    try std.testing.expectError(error.InvalidUtf8, client.setProperty("#root", "TOPIC", &.{0xff}));
    try std.testing.expectError(error.InvalidUtf8, client.accessAdd("#root", "HOST", "anna!*@*", "", &.{0xff}));
    try client.ison("alice bob");
    try std.testing.expect(std.mem.indexOf(u8, client.tx.items.items[client.tx.items.items.len - 1].bytes, "ISON alice :bob") != null);
    try client.partReason("#root", "later");
    try std.testing.expect(std.mem.indexOf(u8, client.tx.items.items[client.tx.items.items.len - 1].bytes, "PART #root :later") != null);
    try client.ctcpRequest("alice", "VERSION", null);
    try std.testing.expect(std.mem.indexOf(u8, client.tx.items.items[client.tx.items.items.len - 1].bytes, "PRIVMSG alice :\x01VERSION\x01") != null);
    try client.setException("#root", "alice!*@*");
    try client.setInviteMask("#root", "bob!*@*");
    try std.testing.expect(std.mem.indexOf(u8, client.tx.items.items[client.tx.items.items.len - 2].bytes, "MODE #root +x alice!*@*") != null);
    try std.testing.expect(std.mem.indexOf(u8, client.tx.items.items[client.tx.items.items.len - 1].bytes, "MODE #root +y bob!*@*") != null);

    try client.registration.?.cap.begin(&client.out);
    client.out.clearRetainingCapacity();
    _ = try client.registration.?.cap.handle(&client.out, message.parse(":irc CAP * LS :setname draft/chathistory"));
    client.out.clearRetainingCapacity();
    _ = try client.registration.?.cap.handle(&client.out, message.parse(":irc CAP * ACK :setname draft/chathistory"));
    try client.setName("Alice Example");
    try std.testing.expect(std.mem.indexOf(u8, client.tx.items.items[client.tx.items.items.len - 1].bytes, "SETNAME :Alice Example") != null);
    try client.ownedRestoration().remember("#hist", "msgid=msg-1");
    const hist_before = client.tx.items.items.len;
    try client.queueRestoration();
    try std.testing.expect(std.mem.indexOf(u8, client.tx.items.items[hist_before].bytes, "CHATHISTORY AFTER #hist msgid=msg-1 50") != null);
}

test "IRCX tagged data rejects malformed draft tags" {
    try std.testing.expect(validIrcxDataTag("CCUDI1"));
    try std.testing.expect(validIrcxDataTag("APP.INFO"));
    try std.testing.expect(!validIrcxDataTag("1BAD"));
    try std.testing.expect(!validIrcxDataTag("BAD-TAG"));
    try std.testing.expect(!validIrcxDataTag("this-tag-is-far-too-long"));
    try std.testing.expect(validIrcxAuthSequence("I"));
    try std.testing.expect(validIrcxAuthSequence("S"));
    try std.testing.expect(validIrcxAuthSequence("*"));
    try std.testing.expect(!validIrcxAuthSequence("Q"));
}
