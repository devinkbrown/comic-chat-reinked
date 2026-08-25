//! Application obligations created by negotiated IRCv3 capabilities.
//!
//! This module is transport-independent. It owns participant/metadata state,
//! optimistic echo and label correlation, redaction tombstones, and BATCH
//! aggregation (including draft/multiline and history/event playback).

const std = @import("std");
const message = @import("message.zig");
const irc_map = @import("irc_map.zig");

pub const Limits = struct {
    max_open_batches: usize = 32,
    max_batch_lines: usize = 1024,
    max_batch_bytes: usize = 1024 * 1024,
    max_pending_echoes: usize = 256,
    max_seen_msgids: usize = 256,
    max_outstanding_labels: usize = 512,
    max_state_entries: usize = 4096,
};

const OwnedOptional = ?[]u8;

pub const Identity = struct {
    nick: []u8,
    account: OwnedOptional = null,
    away: OwnedOptional = null,
    user: OwnedOptional = null,
    host: OwnedOptional = null,
    realname: OwnedOptional = null,
    bot: bool = false,
    oper: bool = false,

    fn deinit(self: *Identity, gpa: std.mem.Allocator) void {
        gpa.free(self.nick);
        freeOptional(gpa, self.account);
        freeOptional(gpa, self.away);
        freeOptional(gpa, self.user);
        freeOptional(gpa, self.host);
        freeOptional(gpa, self.realname);
        self.* = undefined;
    }
};

pub const ChannelRename = struct { old: []u8, new: []u8 };
pub const ReadMarker = struct { target: []u8, timestamp: []u8 };
pub const Metadata = struct { target: []u8, key: []u8, value: OwnedOptional };
pub const IsupportToken = struct { name: []u8, value: OwnedOptional };
pub const StandardReply = struct {
    severity: enum { fail, warn, note },
    command: []u8,
    code: []u8,
    description: []u8,

    fn deinit(self: *StandardReply, gpa: std.mem.Allocator) void {
        gpa.free(self.command);
        gpa.free(self.code);
        gpa.free(self.description);
        self.* = undefined;
    }
};

const Echo = struct { target: []u8, text: []u8 };
const Label = struct { value: []u8 };

pub const State = struct {
    gpa: std.mem.Allocator,
    limits: Limits,
    self_nick: []u8,
    identities: std.ArrayList(Identity) = .empty,
    channel_renames: std.ArrayList(ChannelRename) = .empty,
    read_markers: std.ArrayList(ReadMarker) = .empty,
    metadata: std.ArrayList(Metadata) = .empty,
    isupport_tokens: std.ArrayList(IsupportToken) = .empty,
    casemapping: irc_map.CaseMapping = .rfc1459,
    prefixes: irc_map.PrefixMap = .default,
    chantypes: irc_map.ChanTypes = .default,
    chanmodes: irc_map.ChanModes = .default,
    statusmsg: irc_map.StatusMsg = .default,
    session_limits: irc_map.SessionLimits = .{},
    extban: irc_map.Extban = .{},
    network: [64]u8 = @splat(0),
    network_len: u8 = 0,
    redacted_ids: std.ArrayList([]u8) = .empty,
    seen_msgids: std.ArrayList([]u8) = .empty,
    pending_echoes: std.ArrayList(Echo) = .empty,
    outstanding_labels: std.ArrayList(Label) = .empty,
    completed_labels: std.ArrayList([]u8) = .empty,
    last_reply: ?StandardReply = null,
    next_label: u64 = 1,

    pub fn init(gpa: std.mem.Allocator, self_nick: []const u8, limits: Limits) !State {
        return .{ .gpa = gpa, .limits = limits, .self_nick = try gpa.dupe(u8, self_nick) };
    }

    pub fn deinit(self: *State) void {
        for (self.identities.items) |*entry| entry.deinit(self.gpa);
        self.identities.deinit(self.gpa);
        for (self.channel_renames.items) |entry| {
            self.gpa.free(entry.old);
            self.gpa.free(entry.new);
        }
        self.channel_renames.deinit(self.gpa);
        for (self.read_markers.items) |entry| {
            self.gpa.free(entry.target);
            self.gpa.free(entry.timestamp);
        }
        self.read_markers.deinit(self.gpa);
        for (self.metadata.items) |entry| {
            self.gpa.free(entry.target);
            self.gpa.free(entry.key);
            freeOptional(self.gpa, entry.value);
        }
        self.metadata.deinit(self.gpa);
        for (self.isupport_tokens.items) |entry| {
            self.gpa.free(entry.name);
            freeOptional(self.gpa, entry.value);
        }
        self.isupport_tokens.deinit(self.gpa);
        freeStringList(self.gpa, &self.redacted_ids);
        freeStringList(self.gpa, &self.seen_msgids);
        for (self.pending_echoes.items) |entry| {
            self.gpa.free(entry.target);
            self.gpa.free(entry.text);
        }
        self.pending_echoes.deinit(self.gpa);
        for (self.outstanding_labels.items) |entry| self.gpa.free(entry.value);
        self.outstanding_labels.deinit(self.gpa);
        freeStringList(self.gpa, &self.completed_labels);
        if (self.last_reply) |*reply| reply.deinit(self.gpa);
        self.gpa.free(self.self_nick);
        self.* = undefined;
    }

    pub fn identity(self: *const State, nick: []const u8) ?*const Identity {
        for (self.identities.items) |*entry| {
            if (irc_map.eql(self.casemapping, entry.nick, nick)) return entry;
        }
        return null;
    }

    pub fn isupport(self: *const State, name: []const u8) ?*const IsupportToken {
        for (self.isupport_tokens.items) |*entry| {
            if (std.ascii.eqlIgnoreCase(entry.name, name)) return entry;
        }
        return null;
    }

    /// Record an optimistic local display so the matching echo-message reply
    /// can be suppressed exactly once. Oldest entries are dropped at the bound.
    pub fn recordEcho(self: *State, target: []const u8, text: []const u8) !void {
        if (self.pending_echoes.items.len == self.limits.max_pending_echoes) {
            const old = self.pending_echoes.orderedRemove(0);
            self.gpa.free(old.target);
            self.gpa.free(old.text);
        }
        const owned_target = try self.gpa.dupe(u8, target);
        errdefer self.gpa.free(owned_target);
        const owned_text = try self.gpa.dupe(u8, text);
        errdefer self.gpa.free(owned_text);
        try self.pending_echoes.append(self.gpa, .{ .target = owned_target, .text = owned_text });
    }

    /// Allocate and track a correlation label. The returned slice is owned by
    /// State and remains valid until the response completes or deinit.
    pub fn createLabel(self: *State) ![]const u8 {
        if (self.outstanding_labels.items.len >= self.limits.max_outstanding_labels)
            return error.LabelBackpressure;
        var buffer: [32]u8 = undefined;
        const value = try std.fmt.bufPrint(&buffer, "cc-{x}", .{self.next_label});
        self.next_label +%= 1;
        const owned = try self.gpa.dupe(u8, value);
        errdefer self.gpa.free(owned);
        try self.outstanding_labels.append(self.gpa, .{ .value = owned });
        return owned;
    }

    pub fn takeCompletedLabel(self: *State) ?[]u8 {
        if (self.completed_labels.items.len == 0) return null;
        return self.completed_labels.orderedRemove(0);
    }

    pub fn completeLabel(self: *State, value: []const u8) !bool {
        for (self.outstanding_labels.items, 0..) |entry, index| {
            if (!std.mem.eql(u8, entry.value, value)) continue;
            try self.completed_labels.ensureUnusedCapacity(self.gpa, 1);
            const completed = self.outstanding_labels.orderedRemove(index).value;
            self.completed_labels.appendAssumeCapacity(completed);
            return true;
        }
        return false;
    }

    /// Update negotiated feature state. Returns true when a message is a
    /// duplicate optimistic echo or references a redacted msgid and should not
    /// be delivered to the UI.
    pub fn observe(self: *State, msg: *const message.Message) !bool {
        if (try self.completeTaggedLabel(msg)) {}
        const source_nick = if (msg.prefix) |prefix| nickFromPrefix(prefix) else "";

        if (msg.tag("account")) |tag| {
            if (tag.raw_value) |raw| {
                const decoded = try decodedTagOrCopy(self.gpa, raw);
                defer self.gpa.free(decoded);
                try self.setIdentityField(source_nick, .account, decoded);
            }
        }
        if (source_nick.len != 0 and (msg.tag("bot") != null or msg.tag("draft/oper") != null)) {
            const entry = try self.ensureIdentity(source_nick);
            if (msg.tag("bot") != null) entry.bot = true;
            if (msg.tag("draft/oper") != null) entry.oper = true;
        }
        if (std.ascii.eqlIgnoreCase(msg.command, "ACCOUNT")) {
            const raw = msg.param(0) orelse "*";
            try self.setIdentityField(source_nick, .account, if (std.mem.eql(u8, raw, "*")) null else raw);
        } else if (std.ascii.eqlIgnoreCase(msg.command, "AWAY")) {
            try self.setIdentityField(source_nick, .away, msg.param(0));
        } else if (std.ascii.eqlIgnoreCase(msg.command, "CHGHOST")) {
            try self.setIdentityField(source_nick, .user, msg.param(0));
            try self.setIdentityField(source_nick, .host, msg.param(1));
        } else if (std.ascii.eqlIgnoreCase(msg.command, "SETNAME")) {
            try self.setIdentityField(source_nick, .realname, msg.param(0));
        } else if (std.ascii.eqlIgnoreCase(msg.command, "NICK")) {
            if (msg.param(0)) |new_nick| {
                try self.renameIdentity(source_nick, new_nick);
                if (source_nick.len != 0 and irc_map.eql(self.casemapping, source_nick, self.self_nick)) {
                    const owned = try self.gpa.dupe(u8, new_nick);
                    self.gpa.free(self.self_nick);
                    self.self_nick = owned;
                }
            }
        } else if (std.ascii.eqlIgnoreCase(msg.command, "JOIN") and msg.param_count >= 3) {
            const account = msg.param(1).?;
            try self.setIdentityField(source_nick, .account, if (std.mem.eql(u8, account, "*")) null else account);
            try self.setIdentityField(source_nick, .realname, msg.param(2));
        } else if (std.ascii.eqlIgnoreCase(msg.command, "RENAME")) {
            if (msg.param(0)) |old| if (msg.param(1)) |new| try self.putRename(old, new);
        } else if (std.ascii.eqlIgnoreCase(msg.command, "MARKREAD")) {
            if (msg.param(0)) |target| if (msg.param(1)) |timestamp| try self.putMarker(target, timestamp);
        } else if (std.ascii.eqlIgnoreCase(msg.command, "METADATA")) {
            if (msg.param(0)) |target| if (msg.param(1)) |key| try self.putMetadata(target, key, msg.param(3));
        } else if (std.mem.eql(u8, msg.command, "005")) {
            try self.observeIsupport(msg);
        } else if (std.ascii.eqlIgnoreCase(msg.command, "REDACT")) {
            if (msg.param(1)) |msgid| try self.putRedaction(msgid);
        } else if (std.ascii.eqlIgnoreCase(msg.command, "FAIL") or
            std.ascii.eqlIgnoreCase(msg.command, "WARN") or
            std.ascii.eqlIgnoreCase(msg.command, "NOTE"))
        {
            try self.putStandardReply(msg);
        }

        if (msg.tag("msgid")) |tag| if (tag.raw_value) |msgid| {
            if (stringListContains(self.redacted_ids.items, msgid)) return true;
            if (std.ascii.eqlIgnoreCase(msg.command, "PRIVMSG") or
                std.ascii.eqlIgnoreCase(msg.command, "NOTICE") or
                std.ascii.eqlIgnoreCase(msg.command, "TAGMSG"))
            {
                if (try self.noteSeenMsgid(msgid)) return true;
            }
        };

        if ((std.ascii.eqlIgnoreCase(msg.command, "PRIVMSG") or
            std.ascii.eqlIgnoreCase(msg.command, "NOTICE")) and
            irc_map.eql(self.casemapping, source_nick, self.self_nick))
        {
            const target = msg.param(0) orelse "";
            const text = msg.param(1) orelse "";
            for (self.pending_echoes.items, 0..) |entry, index| {
                if (!irc_map.eql(self.casemapping, entry.target, target) or !std.mem.eql(u8, entry.text, text)) continue;
                const matched = self.pending_echoes.orderedRemove(index);
                self.gpa.free(matched.target);
                self.gpa.free(matched.text);
                return true;
            }
        }
        return false;
    }

    fn ensureIdentity(self: *State, nick: []const u8) !*Identity {
        for (self.identities.items) |*entry| {
            if (irc_map.eql(self.casemapping, entry.nick, nick)) return entry;
        }
        if (nick.len == 0) return error.InvalidIdentityEvent;
        if (self.identities.items.len >= self.limits.max_state_entries) return error.StateBackpressure;
        const owned_nick = try self.gpa.dupe(u8, nick);
        errdefer self.gpa.free(owned_nick);
        try self.identities.append(self.gpa, .{ .nick = owned_nick });
        return &self.identities.items[self.identities.items.len - 1];
    }

    const IdentityField = enum { account, away, user, host, realname };
    fn setIdentityField(self: *State, nick: []const u8, field: IdentityField, value: ?[]const u8) !void {
        if (nick.len == 0) return;
        const entry = try self.ensureIdentity(nick);
        const slot: *OwnedOptional = switch (field) {
            .account => &entry.account,
            .away => &entry.away,
            .user => &entry.user,
            .host => &entry.host,
            .realname => &entry.realname,
        };
        const copy = if (value) |raw| try self.gpa.dupe(u8, raw) else null;
        freeOptional(self.gpa, slot.*);
        slot.* = copy;
    }

    fn putRename(self: *State, old: []const u8, new: []const u8) !void {
        for (self.channel_renames.items) |*entry| {
            if (!std.ascii.eqlIgnoreCase(entry.old, old)) continue;
            const replacement = try self.gpa.dupe(u8, new);
            self.gpa.free(entry.new);
            entry.new = replacement;
            return;
        }
        try boundedPairAppend(ChannelRename, self.gpa, &self.channel_renames, self.limits.max_state_entries, old, new);
    }

    fn putMarker(self: *State, target: []const u8, timestamp: []const u8) !void {
        for (self.read_markers.items) |*entry| {
            if (!std.ascii.eqlIgnoreCase(entry.target, target)) continue;
            const replacement = try self.gpa.dupe(u8, timestamp);
            self.gpa.free(entry.timestamp);
            entry.timestamp = replacement;
            return;
        }
        try boundedPairAppend(ReadMarker, self.gpa, &self.read_markers, self.limits.max_state_entries, target, timestamp);
    }

    fn putMetadata(self: *State, target: []const u8, key: []const u8, value: ?[]const u8) !void {
        for (self.metadata.items) |*entry| {
            if (!std.ascii.eqlIgnoreCase(entry.target, target) or !std.mem.eql(u8, entry.key, key)) continue;
            const replacement = if (value) |raw| try self.gpa.dupe(u8, raw) else null;
            freeOptional(self.gpa, entry.value);
            entry.value = replacement;
            return;
        }
        if (self.metadata.items.len >= self.limits.max_state_entries) return error.StateBackpressure;
        const owned_target = try self.gpa.dupe(u8, target);
        errdefer self.gpa.free(owned_target);
        const owned_key = try self.gpa.dupe(u8, key);
        errdefer self.gpa.free(owned_key);
        const owned_value = if (value) |raw| try self.gpa.dupe(u8, raw) else null;
        errdefer freeOptional(self.gpa, owned_value);
        try self.metadata.append(self.gpa, .{ .target = owned_target, .key = owned_key, .value = owned_value });
    }

    fn observeIsupport(self: *State, msg: *const message.Message) !void {
        if (msg.param_count < 2) return;
        var index: usize = 1; // parameter zero is our nick
        while (index + 1 < msg.param_count) : (index += 1) {
            const raw = msg.params[index];
            if (raw.len == 0) continue;
            if (raw[0] == '-') {
                self.removeIsupport(raw[1..]);
                continue;
            }
            const equals = std.mem.indexOfScalar(u8, raw, '=') orelse raw.len;
            const name = raw[0..equals];
            if (!validIsupportName(name)) continue;
            const value = if (equals < raw.len) raw[equals + 1 ..] else null;
            try self.putIsupport(name, value);
        }
        self.refreshAdvertisedMaps();
    }

    pub fn networkName(self: *const State) []const u8 {
        return self.network[0..self.network_len];
    }

    pub fn advertised(self: *const State) irc_map.Advertised {
        return .{
            .casemapping = self.casemapping,
            .prefixes = self.prefixes,
            .chantypes = self.chantypes,
            .chanmodes = self.chanmodes,
            .statusmsg = self.statusmsg,
            .session_limits = self.session_limits,
            .extban = self.extban,
        };
    }

    fn refreshAdvertisedMaps(self: *State) void {
        self.casemapping = if (self.isupport("CASEMAPPING")) |token|
            irc_map.parseCaseMapping(token.value orelse "")
        else
            .rfc1459;
        self.prefixes = if (self.isupport("PREFIX")) |token|
            if (token.value) |value| irc_map.PrefixMap.parse(value) orelse .default else .default
        else
            .default;
        self.chantypes = if (self.isupport("CHANTYPES")) |token|
            if (token.value) |value| irc_map.ChanTypes.parse(value) else .default
        else
            .default;
        self.chanmodes = if (self.isupport("CHANMODES")) |token|
            if (token.value) |value| irc_map.ChanModes.parse(value) else .default
        else
            .default;
        self.statusmsg = if (self.isupport("STATUSMSG")) |token|
            if (token.value) |value| irc_map.StatusMsg.parse(value) else irc_map.StatusMsg.fromPrefix(self.prefixes)
        else
            irc_map.StatusMsg.fromPrefix(self.prefixes);
        self.session_limits = .{};
        if (self.isupport("NICKLEN")) |token| if (token.value) |value| {
            self.session_limits.nicklen = irc_map.SessionLimits.parseCount(value);
        };
        if (self.isupport("CHANNELLEN")) |token| if (token.value) |value| {
            self.session_limits.channellen = irc_map.SessionLimits.parseCount(value);
        };
        if (self.isupport("TOPICLEN")) |token| if (token.value) |value| {
            self.session_limits.topiclen = irc_map.SessionLimits.parseCount(value);
        };
        if (self.isupport("AWAYLEN")) |token| if (token.value) |value| {
            self.session_limits.awaylen = irc_map.SessionLimits.parseCount(value);
        };
        if (self.isupport("KICKLEN")) |token| if (token.value) |value| {
            self.session_limits.kicklen = irc_map.SessionLimits.parseCount(value);
        };
        if (self.isupport("KEYLEN")) |token| if (token.value) |value| {
            self.session_limits.keylen = irc_map.SessionLimits.parseCount(value);
        };
        if (self.isupport("CHANLIMIT")) |token| if (token.value) |value| {
            self.session_limits.chanlimit = irc_map.SessionLimits.parseChanlimit(value);
        };
        if (self.isupport("MAXTARGETS")) |token| if (token.value) |value| {
            self.session_limits.maxtargets = irc_map.SessionLimits.parseCount(value);
        };
        if (self.isupport("MONITOR")) |token| if (token.value) |value| {
            self.session_limits.monitor = irc_map.SessionLimits.parseCount(value);
        };
        if (self.isupport("SILENCE")) |token| if (token.value) |value| {
            self.session_limits.silence = irc_map.SessionLimits.parseCount(value);
        };
        if (self.isupport("MODES")) |token| if (token.value) |value| {
            self.session_limits.modes = irc_map.SessionLimits.parseCount(value);
        };
        if (self.isupport("MAXLIST")) |token| if (token.value) |value| {
            self.session_limits.maxlist = irc_map.SessionLimits.parseMaxlist(value);
        };
        if (self.isupport("BOT")) |token| if (token.value) |value| {
            self.session_limits.bot = if (value.len != 0) value[0] else 0;
        };
        self.session_limits.whox = self.isupport("WHOX") != null;
        self.session_limits.utf8only = self.isupport("UTF8ONLY") != null;
        self.extban = if (self.isupport("EXTBAN")) |token|
            if (token.value) |value| irc_map.Extban.parse(value) else .{}
        else
            .{};
        self.network_len = 0;
        if (self.isupport("NETWORK")) |token| if (token.value) |value| {
            const n = @min(value.len, self.network.len);
            @memcpy(self.network[0..n], value[0..n]);
            self.network_len = @intCast(n);
        };
    }

    fn putIsupport(self: *State, name: []const u8, value: ?[]const u8) !void {
        for (self.isupport_tokens.items) |*entry| {
            if (!std.ascii.eqlIgnoreCase(entry.name, name)) continue;
            const replacement = if (value) |raw| try self.gpa.dupe(u8, raw) else null;
            freeOptional(self.gpa, entry.value);
            entry.value = replacement;
            return;
        }
        if (self.isupport_tokens.items.len >= self.limits.max_state_entries) return error.StateBackpressure;
        const owned_name = try self.gpa.dupe(u8, name);
        errdefer self.gpa.free(owned_name);
        const owned_value = if (value) |raw| try self.gpa.dupe(u8, raw) else null;
        errdefer freeOptional(self.gpa, owned_value);
        try self.isupport_tokens.append(self.gpa, .{ .name = owned_name, .value = owned_value });
    }

    fn removeIsupport(self: *State, name: []const u8) void {
        for (self.isupport_tokens.items, 0..) |entry, index| {
            if (!std.ascii.eqlIgnoreCase(entry.name, name)) continue;
            const removed = self.isupport_tokens.swapRemove(index);
            self.gpa.free(removed.name);
            freeOptional(self.gpa, removed.value);
            return;
        }
    }

    fn renameIdentity(self: *State, old_nick: []const u8, new_nick: []const u8) !void {
        if (old_nick.len == 0 or new_nick.len == 0) return;
        var old_index: ?usize = null;
        var new_index: ?usize = null;
        for (self.identities.items, 0..) |entry, index| {
            if (irc_map.eql(self.casemapping, entry.nick, old_nick)) old_index = index;
            if (irc_map.eql(self.casemapping, entry.nick, new_nick)) new_index = index;
        }
        const source_index = old_index orelse return;
        if (new_index) |target_index| {
            if (target_index == source_index) return;
            var source = self.identities.orderedRemove(source_index);
            const adjusted_target = if (source_index < target_index) target_index - 1 else target_index;
            var target = &self.identities.items[adjusted_target];
            moveMissingIdentityField(&target.account, &source.account);
            moveMissingIdentityField(&target.away, &source.away);
            moveMissingIdentityField(&target.user, &source.user);
            moveMissingIdentityField(&target.host, &source.host);
            moveMissingIdentityField(&target.realname, &source.realname);
            target.bot = target.bot or source.bot;
            target.oper = target.oper or source.oper;
            source.deinit(self.gpa);
            return;
        }
        const replacement = try self.gpa.dupe(u8, new_nick);
        self.gpa.free(self.identities.items[source_index].nick);
        self.identities.items[source_index].nick = replacement;
    }

    fn putRedaction(self: *State, msgid: []const u8) !void {
        if (stringListContains(self.redacted_ids.items, msgid)) return;
        if (self.redacted_ids.items.len >= self.limits.max_state_entries) {
            const old = self.redacted_ids.orderedRemove(0);
            self.gpa.free(old);
        }
        const owned = try self.gpa.dupe(u8, msgid);
        errdefer self.gpa.free(owned);
        try self.redacted_ids.append(self.gpa, owned);
    }

    /// Returns true when this msgid was already delivered (bouncer + CHATHISTORY overlap).
    fn noteSeenMsgid(self: *State, msgid: []const u8) !bool {
        if (stringListContains(self.seen_msgids.items, msgid)) return true;
        if (self.seen_msgids.items.len >= self.limits.max_seen_msgids) {
            const old = self.seen_msgids.orderedRemove(0);
            self.gpa.free(old);
        }
        const owned = try self.gpa.dupe(u8, msgid);
        errdefer self.gpa.free(owned);
        try self.seen_msgids.append(self.gpa, owned);
        return false;
    }

    fn putStandardReply(self: *State, msg: *const message.Message) !void {
        const command = msg.param(0) orelse return;
        const code = msg.param(1) orelse return;
        const description = msg.param(msg.param_count - 1) orelse "";
        var replacement = StandardReply{
            .severity = if (std.ascii.eqlIgnoreCase(msg.command, "FAIL")) .fail else if (std.ascii.eqlIgnoreCase(msg.command, "WARN")) .warn else .note,
            .command = try self.gpa.dupe(u8, command),
            .code = undefined,
            .description = undefined,
        };
        errdefer self.gpa.free(replacement.command);
        replacement.code = try self.gpa.dupe(u8, code);
        errdefer self.gpa.free(replacement.code);
        replacement.description = try self.gpa.dupe(u8, description);
        if (self.last_reply) |*old| old.deinit(self.gpa);
        self.last_reply = replacement;
    }

    fn completeTaggedLabel(self: *State, msg: *const message.Message) !bool {
        const tag = msg.tag("label") orelse return false;
        const raw = tag.raw_value orelse return false;
        return self.completeLabel(raw);
    }
};

pub const Aggregator = struct {
    gpa: std.mem.Allocator,
    limits: Limits,
    open: std.ArrayList(Batch) = .empty,
    ready: std.ArrayList([]u8) = .empty,
    completed_labels: std.ArrayList([]u8) = .empty,
    total_lines: usize = 0,
    total_bytes: usize = 0,

    const Batch = struct {
        id: []u8,
        kind: []u8,
        target: OwnedOptional,
        parent: OwnedOptional,
        label: OwnedOptional,
        tags: OwnedOptional,
        lines: std.ArrayList([]u8) = .empty,

        fn deinit(self: *Batch, gpa: std.mem.Allocator) void {
            gpa.free(self.id);
            gpa.free(self.kind);
            freeOptional(gpa, self.target);
            freeOptional(gpa, self.parent);
            freeOptional(gpa, self.label);
            freeOptional(gpa, self.tags);
            freeStringList(gpa, &self.lines);
            self.* = undefined;
        }
    };

    pub fn init(gpa: std.mem.Allocator, limits: Limits) Aggregator {
        return .{ .gpa = gpa, .limits = limits };
    }

    pub fn deinit(self: *Aggregator) void {
        for (self.open.items) |*batch| batch.deinit(self.gpa);
        self.open.deinit(self.gpa);
        freeStringList(self.gpa, &self.ready);
        freeStringList(self.gpa, &self.completed_labels);
        self.* = undefined;
    }

    /// Consume a raw IRC line. True means it belongs to BATCH control/content
    /// and must not be delivered directly. Completed logical messages become
    /// available through `takeReady`.
    pub fn ingest(self: *Aggregator, raw: []const u8) !bool {
        const msg = message.parse(raw);
        if (std.ascii.eqlIgnoreCase(msg.command, "BATCH")) {
            const reference = msg.param(0) orelse return error.InvalidBatch;
            if (reference.len < 2) return error.InvalidBatch;
            if (reference[0] == '+') return self.startBatch(&msg, reference[1..]);
            if (reference[0] == '-') return self.endBatch(&msg, reference[1..]);
            return error.InvalidBatch;
        }
        const batch_tag = msg.tag("batch") orelse return false;
        const id = batch_tag.raw_value orelse return error.InvalidBatch;
        if (!validBatchReference(id)) return error.InvalidBatch;
        const index = self.findBatch(id) orelse return false;
        try self.appendLine(index, raw);
        return true;
    }

    pub fn takeReady(self: *Aggregator) ?[]u8 {
        if (self.ready.items.len == 0) return null;
        return self.ready.orderedRemove(0);
    }

    pub fn takeCompletedLabel(self: *Aggregator) ?[]u8 {
        if (self.completed_labels.items.len == 0) return null;
        return self.completed_labels.orderedRemove(0);
    }

    fn startBatch(self: *Aggregator, msg: *const message.Message, id: []const u8) !bool {
        if (!validBatchReference(id)) return error.InvalidBatch;
        if (self.findBatch(id) != null or self.open.items.len >= self.limits.max_open_batches)
            return error.BatchBackpressure;
        const kind = msg.param(1) orelse return error.InvalidBatch;
        const owned_id = try self.gpa.dupe(u8, id);
        errdefer self.gpa.free(owned_id);
        const owned_kind = try self.gpa.dupe(u8, kind);
        errdefer self.gpa.free(owned_kind);
        const target = if (msg.param(2)) |raw| try self.gpa.dupe(u8, raw) else null;
        errdefer freeOptional(self.gpa, target);
        const parent = if (msg.tag("batch")) |tag| if (tag.raw_value) |raw| try self.gpa.dupe(u8, raw) else null else null;
        errdefer freeOptional(self.gpa, parent);
        if (parent) |parent_id| {
            if (!validBatchReference(parent_id) or self.findBatch(parent_id) == null) return error.InvalidBatch;
        }
        const label = if (msg.tag("label")) |tag| if (tag.raw_value) |raw| try self.gpa.dupe(u8, raw) else null else null;
        errdefer freeOptional(self.gpa, label);
        const tags = try copySemanticTags(self.gpa, msg.tag_data);
        errdefer freeOptional(self.gpa, tags);
        try self.open.append(self.gpa, .{ .id = owned_id, .kind = owned_kind, .target = target, .parent = parent, .label = label, .tags = tags });
        return true;
    }

    fn endBatch(self: *Aggregator, msg: *const message.Message, id: []const u8) !bool {
        if (!validBatchReference(id)) return error.InvalidBatch;
        const index = self.findBatch(id) orelse return error.InvalidBatch;
        const closing_parent = if (msg.tag("batch")) |tag| tag.raw_value else null;
        const opening_parent = self.open.items[index].parent;
        if ((opening_parent == null) != (closing_parent == null) or
            (opening_parent != null and !std.mem.eql(u8, opening_parent.?, closing_parent.?)))
            return error.InvalidBatch;
        var batch = self.open.orderedRemove(index);
        defer batch.deinit(self.gpa);
        self.total_lines -= batch.lines.items.len;
        for (batch.lines.items) |line| self.total_bytes -= line.len;

        var produced: std.ArrayList([]u8) = .empty;
        defer produced.deinit(self.gpa);
        var produced_owns_items = true;
        errdefer if (produced_owns_items) for (produced.items) |line| self.gpa.free(line);
        if (std.ascii.eqlIgnoreCase(batch.kind, "draft/multiline")) {
            if (try self.combineMultiline(&batch)) |line| {
                produced.append(self.gpa, line) catch |err| {
                    self.gpa.free(line);
                    return err;
                };
            }
        } else {
            for (batch.lines.items) |line| {
                const copy = try self.gpa.dupe(u8, line);
                produced.append(self.gpa, copy) catch |err| {
                    self.gpa.free(copy);
                    return err;
                };
            }
        }

        if (batch.parent) |parent| {
            const parent_index = self.findBatch(parent) orelse return error.InvalidBatch;
            var produced_bytes: usize = 0;
            for (produced.items) |line| produced_bytes += line.len;
            if (self.total_lines + produced.items.len > self.limits.max_batch_lines or
                self.total_bytes + produced_bytes > self.limits.max_batch_bytes)
                return error.BatchBackpressure;
            // All fallible work happens before ownership transfer, so an OOM
            // cannot leave a partially appended child batch in its parent.
            try self.open.items[parent_index].lines.ensureUnusedCapacity(self.gpa, produced.items.len);
            for (produced.items) |line| self.open.items[parent_index].lines.appendAssumeCapacity(line);
            self.total_lines += produced.items.len;
            self.total_bytes += produced_bytes;
        } else {
            try self.ready.ensureUnusedCapacity(self.gpa, produced.items.len);
            const completed_label = if (batch.label) |label| try self.gpa.dupe(u8, label) else null;
            errdefer freeOptional(self.gpa, completed_label);
            if (completed_label != null) try self.completed_labels.ensureUnusedCapacity(self.gpa, 1);
            for (produced.items) |line| self.ready.appendAssumeCapacity(line);
            if (completed_label) |label| self.completed_labels.appendAssumeCapacity(label);
        }
        produced.clearRetainingCapacity();
        produced_owns_items = false;
        return true;
    }

    fn appendLine(self: *Aggregator, index: usize, raw: []const u8) !void {
        if (self.total_lines >= self.limits.max_batch_lines or
            self.total_bytes + raw.len > self.limits.max_batch_bytes)
            return error.BatchBackpressure;
        const owned = try self.gpa.dupe(u8, raw);
        errdefer self.gpa.free(owned);
        try self.open.items[index].lines.append(self.gpa, owned);
        self.total_lines += 1;
        self.total_bytes += raw.len;
    }

    fn combineMultiline(self: *Aggregator, batch: *const Batch) !?[]u8 {
        var combined: std.ArrayList(u8) = .empty;
        defer combined.deinit(self.gpa);
        var first_message: ?message.Message = null;
        var first_command: ?[]const u8 = null;
        var nonempty = false;
        for (batch.lines.items) |raw| {
            const msg = message.parse(raw);
            if (!std.ascii.eqlIgnoreCase(msg.command, "PRIVMSG") and !std.ascii.eqlIgnoreCase(msg.command, "NOTICE"))
                return error.InvalidMultilineBatch;
            const target = msg.param(0) orelse return error.InvalidMultilineBatch;
            if (!std.ascii.eqlIgnoreCase(target, batch.target orelse return error.InvalidMultilineBatch))
                return error.InvalidMultilineBatch;
            const text = msg.param(1) orelse return error.InvalidMultilineBatch;
            const concat = msg.tag("draft/multiline-concat");
            if (concat) |tag| if (tag.raw_value != null) return error.InvalidMultilineBatch;
            if (first_command) |command| {
                if (!std.ascii.eqlIgnoreCase(command, msg.command)) return error.InvalidMultilineBatch;
            } else {
                first_command = msg.command;
            }
            if (text.len != 0) nonempty = true;
            if (first_message == null) {
                if (concat != null and text.len == 0)
                    return error.InvalidMultilineBatch;
                first_message = msg;
            } else if (concat == null) {
                try combined.append(self.gpa, '\n');
            } else if (text.len == 0) {
                return error.InvalidMultilineBatch;
            }
            try combined.appendSlice(self.gpa, text);
        }
        if (!nonempty) return error.InvalidMultilineBatch;
        const first = first_message orelse return error.InvalidMultilineBatch;
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(self.gpa);
        if (batch.tags) |tags| {
            try out.append(self.gpa, '@');
            try out.appendSlice(self.gpa, tags);
            try out.append(self.gpa, ' ');
        }
        if (first.prefix) |prefix| {
            try out.append(self.gpa, ':');
            try out.appendSlice(self.gpa, prefix);
            try out.append(self.gpa, ' ');
        }
        try out.appendSlice(self.gpa, first.command);
        try out.append(self.gpa, ' ');
        try out.appendSlice(self.gpa, batch.target orelse first.param(0) orelse return null);
        try out.appendSlice(self.gpa, " :");
        try out.appendSlice(self.gpa, combined.items);
        return try out.toOwnedSlice(self.gpa);
    }

    fn findBatch(self: *const Aggregator, id: []const u8) ?usize {
        for (self.open.items, 0..) |batch, index| if (std.mem.eql(u8, batch.id, id)) return index;
        return null;
    }
};

fn validBatchReference(reference: []const u8) bool {
    if (reference.len == 0) return false;
    for (reference) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '-') return false;
    }
    return true;
}

fn validIsupportName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '-' and byte != '/') return false;
    }
    return true;
}

fn moveMissingIdentityField(target: *OwnedOptional, source: *OwnedOptional) void {
    if (target.* == null) {
        target.* = source.*;
        source.* = null;
    }
}

fn copySemanticTags(gpa: std.mem.Allocator, raw_tags: ?[]const u8) !?[]u8 {
    const raw = raw_tags orelse return null;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    var fields = std.mem.splitScalar(u8, raw, ';');
    while (fields.next()) |field| {
        if (field.len == 0) continue;
        const equals = std.mem.indexOfScalar(u8, field, '=') orelse field.len;
        const key = field[0..equals];
        if (std.mem.eql(u8, key, "batch") or std.mem.eql(u8, key, "label")) continue;
        if (out.items.len != 0) try out.append(gpa, ';');
        try out.appendSlice(gpa, field);
    }
    return if (out.items.len == 0) null else try out.toOwnedSlice(gpa);
}

fn nickFromPrefix(prefix: []const u8) []const u8 {
    const bang = std.mem.indexOfScalar(u8, prefix, '!') orelse prefix.len;
    return prefix[0..bang];
}

fn decodedTagOrCopy(gpa: std.mem.Allocator, raw: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try message.unescapeTagValue(&out, gpa, raw);
    return out.toOwnedSlice(gpa);
}

fn freeOptional(gpa: std.mem.Allocator, value: OwnedOptional) void {
    if (value) |owned| gpa.free(owned);
}

fn freeStringList(gpa: std.mem.Allocator, list: *std.ArrayList([]u8)) void {
    for (list.items) |entry| gpa.free(entry);
    list.deinit(gpa);
}

fn stringListContains(list: []const []u8, needle: []const u8) bool {
    for (list) |entry| if (std.mem.eql(u8, entry, needle)) return true;
    return false;
}

fn boundedPairAppend(
    comptime T: type,
    gpa: std.mem.Allocator,
    list: *std.ArrayList(T),
    limit: usize,
    first: []const u8,
    second: []const u8,
) !void {
    if (list.items.len >= limit) return error.StateBackpressure;
    const a = try gpa.dupe(u8, first);
    errdefer gpa.free(a);
    const b = try gpa.dupe(u8, second);
    errdefer gpa.free(b);
    const value: T = if (comptime T == ChannelRename)
        .{ .old = a, .new = b }
    else if (comptime T == ReadMarker)
        .{ .target = a, .timestamp = b }
    else
        @compileError("unsupported pair type");
    try list.append(gpa, value);
}

fn exerciseFeatureAllocationFailures(gpa: std.mem.Allocator) !void {
    var state = try State.init(gpa, "self", .{});
    defer state.deinit();
    _ = try state.observe(&message.parse("@account=alice\\sacct :Alice!u@h JOIN #room alice :Alice Example"));
    _ = try state.observe(&message.parse(":Alice!u@h AWAY :at lunch"));
    _ = try state.observe(&message.parse(":irc METADATA #room theme * dark"));
    _ = try state.observe(&message.parse(":irc 005 self UTF8ONLY draft/ICON=https://example/icon.png :supported"));
    try state.recordEcho("#room", "hello");
    const label = try state.createLabel();
    _ = try state.completeLabel(label);

    var aggregator = Aggregator.init(gpa, .{});
    defer aggregator.deinit();
    _ = try aggregator.ingest("@label=req :irc BATCH +history chathistory #room");
    _ = try aggregator.ingest("@batch=history;msgid=abc :irc BATCH +multi draft/multiline #room");
    _ = try aggregator.ingest("@batch=multi :alice!u@h PRIVMSG #room :hello ");
    _ = try aggregator.ingest("@batch=multi;draft/multiline-concat :alice!u@h PRIVMSG #room :world");
    _ = try aggregator.ingest("@batch=history :irc BATCH -multi");
    _ = try aggregator.ingest(":irc BATCH -history");
    while (aggregator.takeReady()) |line| gpa.free(line);
    while (aggregator.takeCompletedLabel()) |completed| gpa.free(completed);
}

test "feature and BATCH ownership survives every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseFeatureAllocationFailures,
        .{},
    );
}

test "capability state tracks identity, rename, marker, metadata, and standard replies" {
    const gpa = std.testing.allocator;
    var state = try State.init(gpa, "self", .{});
    defer state.deinit();

    _ = try state.observe(&message.parse("@account=alice\\sacct :Alice!old@host JOIN #room alice :Alice Example"));
    _ = try state.observe(&message.parse(":Alice!old@host AWAY :at lunch"));
    _ = try state.observe(&message.parse(":Alice!old@host CHGHOST newuser newhost"));
    _ = try state.observe(&message.parse(":Alice!newuser@newhost SETNAME :Alice Changed"));
    const alice = state.identity("alice").?;
    try std.testing.expectEqualStrings("alice", alice.account.?);
    try std.testing.expectEqualStrings("at lunch", alice.away.?);
    try std.testing.expectEqualStrings("newuser", alice.user.?);
    try std.testing.expectEqualStrings("newhost", alice.host.?);
    try std.testing.expectEqualStrings("Alice Changed", alice.realname.?);

    _ = try state.observe(&message.parse("@bot;draft/oper=staff :Alice!newuser@newhost PRIVMSG #room hi"));
    try std.testing.expect(state.identity("alice").?.bot);
    try std.testing.expect(state.identity("alice").?.oper);
    _ = try state.observe(&message.parse(":Alice!newuser@newhost NICK Alicia"));
    try std.testing.expect(state.identity("alice") == null);
    try std.testing.expectEqualStrings("newhost", state.identity("alicia").?.host.?);

    _ = try state.observe(&message.parse(":op!u@h RENAME #old #new :cleanup"));
    _ = try state.observe(&message.parse(":irc MARKREAD #new timestamp=2026-07-16T12:00:00.000Z"));
    _ = try state.observe(&message.parse(":irc METADATA #new topic-color * blue"));
    _ = try state.observe(&message.parse(":irc FAIL METADATA KEY_INVALID bad :Invalid key"));
    try std.testing.expectEqualStrings("#new", state.channel_renames.items[0].new);
    try std.testing.expectEqualStrings("timestamp=2026-07-16T12:00:00.000Z", state.read_markers.items[0].timestamp);
    try std.testing.expectEqualStrings("blue", state.metadata.items[0].value.?);
    try std.testing.expectEqualStrings("KEY_INVALID", state.last_reply.?.code);

    _ = try state.observe(&message.parse(":irc 005 self UTF8ONLY CHATHISTORY=100 CLIENTTAGDENY=typing draft/ICON=https://example/icon.png :are supported"));
    try std.testing.expect(state.isupport("utf8only") != null);
    try std.testing.expectEqualStrings("100", state.isupport("CHATHISTORY").?.value.?);
    try std.testing.expectEqualStrings("https://example/icon.png", state.isupport("draft/icon").?.value.?);
    _ = try state.observe(&message.parse(":irc 005 self -UTF8ONLY :are supported"));
    try std.testing.expect(state.isupport("UTF8ONLY") == null);
    _ = try state.observe(&message.parse(":irc 005 self CASEMAPPING=ascii PREFIX=(YQqov)*!.@+ CHANTYPES=#& STATUSMSG=!.@+ CHANMODES=beIZ,k,lfj,imnstCTNMSgWOAVUFD NICKLEN=64 CHANNELLEN=64 KEYLEN=64 TOPICLEN=390 AWAYLEN=256 KICKLEN=307 CHANLIMIT=#&:50 :are supported"));
    try std.testing.expectEqual(irc_map.CaseMapping.ascii, state.casemapping);
    try std.testing.expect(state.prefixes.isSymbol('*'));
    try std.testing.expect(state.prefixes.isMode('Y'));
    try std.testing.expect(!state.prefixes.isSymbol('~'));
    try std.testing.expect(state.chantypes.contains('#'));
    try std.testing.expect(state.chanmodes.takesParam('Z', true));
    try std.testing.expect(state.chanmodes.takesParam('f', true));
    try std.testing.expect(!state.statusmsg.contains('*'));
    try std.testing.expect(state.statusmsg.contains('!'));
    try std.testing.expectEqual(@as(usize, 64), state.session_limits.nicklen);
    try std.testing.expectEqual(@as(usize, 50), state.session_limits.chanlimit);
    try std.testing.expectEqual(@as(usize, 390), state.session_limits.topiclen);
    _ = try state.observe(&message.parse(":irc 005 self NETWORK=Onyx MAXTARGETS=4 MONITOR=128 SILENCE=32 MODES=1 MAXLIST=beIZ:100 EXTBAN=$,acgmrz BOT=B WHOX :are supported"));
    try std.testing.expectEqualStrings("Onyx", state.networkName());
    try std.testing.expectEqual(@as(usize, 4), state.session_limits.maxtargets);
    try std.testing.expectEqual(@as(usize, 128), state.session_limits.monitor);
    try std.testing.expectEqual(@as(usize, 32), state.session_limits.silence);
    try std.testing.expectEqual(@as(usize, 1), state.session_limits.modes);
    try std.testing.expectEqual(@as(usize, 100), state.session_limits.maxlist);
    try std.testing.expect(state.session_limits.whox);
    try std.testing.expectEqual(@as(u8, 'B'), state.session_limits.bot);
    try std.testing.expect(state.extban.allows('a'));
    try std.testing.expect(!state.extban.allows('x'));
    _ = try state.observe(&message.parse(":irc 005 self -NICKLEN :are supported"));
    try std.testing.expectEqual(@as(usize, 0), state.session_limits.nicklen);
    try std.testing.expectEqual(@as(usize, 50), state.session_limits.chanlimit);
    try std.testing.expectEqualStrings("Onyx", state.networkName());
}

test "echo dedupe, redaction tombstones, and labels are bounded owned state" {
    const gpa = std.testing.allocator;
    var state = try State.init(gpa, "me", .{ .max_pending_echoes = 2 });
    defer state.deinit();
    try state.recordEcho("#c", "hello");
    try std.testing.expect(try state.observe(&message.parse(":me!u@h PRIVMSG #c hello")));
    try std.testing.expect(!try state.observe(&message.parse(":me!u@h PRIVMSG #c hello")));

    _ = try state.observe(&message.parse(":me!u@h NICK :renamed"));
    try std.testing.expectEqualStrings("renamed", state.self_nick);
    try state.recordEcho("#c", "after-nick");
    try std.testing.expect(try state.observe(&message.parse(":renamed!u@h PRIVMSG #c after-nick")));
    try std.testing.expect(!try state.observe(&message.parse(":renamed!u@h PRIVMSG #c after-nick")));

    _ = try state.observe(&message.parse(":op!u@h REDACT #c deadbeef :spam"));
    try std.testing.expect(try state.observe(&message.parse("@msgid=deadbeef :n!u@h PRIVMSG #c hidden")));

    try std.testing.expect(!try state.observe(&message.parse("@msgid=live1 :alice!u@h PRIVMSG #c first")));
    try std.testing.expect(try state.observe(&message.parse("@msgid=live1 :alice!u@h PRIVMSG #c first")));

    const label = try state.createLabel();
    var line: [128]u8 = undefined;
    const tagged = try std.fmt.bufPrint(&line, "@label={s} :irc ACK", .{label});
    _ = try state.observe(&message.parse(tagged));
    const completed = state.takeCompletedLabel().?;
    defer gpa.free(completed);
    try std.testing.expectEqualStrings(label, completed);
}

test "nested history and multiline batches produce one logical multiline message" {
    const gpa = std.testing.allocator;
    var aggregator = Aggregator.init(gpa, .{});
    defer aggregator.deinit();

    try std.testing.expect(try aggregator.ingest(":irc BATCH +history chathistory #c"));
    try std.testing.expect(try aggregator.ingest("@batch=history :irc BATCH +multi draft/multiline #c"));
    try std.testing.expect(try aggregator.ingest("@batch=multi :alice!u@h PRIVMSG #c :hello"));
    try std.testing.expect(try aggregator.ingest("@batch=multi;draft/multiline-concat :alice!u@h PRIVMSG #c : world"));
    try std.testing.expect(try aggregator.ingest("@batch=multi :alice!u@h PRIVMSG #c :continued"));
    try std.testing.expect(try aggregator.ingest("@batch=history :irc BATCH -multi"));
    try std.testing.expect(try aggregator.ingest(":irc BATCH -history"));

    const logical = aggregator.takeReady().?;
    defer gpa.free(logical);
    const parsed = message.parse(logical);
    try std.testing.expectEqualStrings("PRIVMSG", parsed.command);
    try std.testing.expectEqualStrings("#c", parsed.param(0).?);
    try std.testing.expectEqualStrings("hello world\ncontinued", parsed.param(1).?);
    try std.testing.expect(aggregator.takeReady() == null);
}

test "batch aggregate limits fail closed under adversarial transcripts" {
    const gpa = std.testing.allocator;
    var aggregator = Aggregator.init(gpa, .{ .max_open_batches = 1, .max_batch_lines = 1, .max_batch_bytes = 64 });
    defer aggregator.deinit();
    _ = try aggregator.ingest(":irc BATCH +a chathistory #c");
    try std.testing.expectError(error.BatchBackpressure, aggregator.ingest(":irc BATCH +b chathistory #c"));
    _ = try aggregator.ingest("@batch=a :n PRIVMSG #c one");
    try std.testing.expectError(error.BatchBackpressure, aggregator.ingest("@batch=a :n PRIVMSG #c two"));
}

test "multiline preserves semantic opening tags and rejects malformed composition" {
    const gpa = std.testing.allocator;
    var aggregator = Aggregator.init(gpa, .{});
    defer aggregator.deinit();

    _ = try aggregator.ingest("@msgid=abc;time=2026-07-16T00:00:00.000Z;label=req :alice BATCH +m draft/multiline #c");
    _ = try aggregator.ingest("@batch=m :alice PRIVMSG #c :first");
    _ = try aggregator.ingest("@batch=m :alice PRIVMSG #c :second");
    _ = try aggregator.ingest(":alice BATCH -m");
    const logical = aggregator.takeReady().?;
    defer gpa.free(logical);
    const parsed = message.parse(logical);
    try std.testing.expectEqualStrings("abc", parsed.tag("msgid").?.raw_value.?);
    try std.testing.expectEqualStrings("2026-07-16T00:00:00.000Z", parsed.tag("time").?.raw_value.?);
    try std.testing.expect(parsed.tag("label") == null);
    try std.testing.expectEqualStrings("first\nsecond", parsed.param(1).?);
    const completed = aggregator.takeCompletedLabel().?;
    defer gpa.free(completed);
    try std.testing.expectEqualStrings("req", completed);

    _ = try aggregator.ingest(":alice BATCH +bad draft/multiline #c");
    _ = try aggregator.ingest("@batch=bad :alice NOTICE #c :mixed command");
    _ = try aggregator.ingest("@batch=bad :alice PRIVMSG #other :wrong target");
    try std.testing.expectError(error.InvalidMultilineBatch, aggregator.ingest(":alice BATCH -bad"));

    _ = try aggregator.ingest(":alice BATCH +empty draft/multiline #c");
    try std.testing.expectError(error.InvalidMultilineBatch, aggregator.ingest(":alice BATCH -empty"));

    _ = try aggregator.ingest(":alice BATCH +valued draft/multiline #c");
    _ = try aggregator.ingest("@batch=valued;draft/multiline-concat=yes :alice PRIVMSG #c :invalid");
    try std.testing.expectError(error.InvalidMultilineBatch, aggregator.ingest(":alice BATCH -valued"));
}

test "batch references and nested closing parent are validated" {
    const gpa = std.testing.allocator;
    var aggregator = Aggregator.init(gpa, .{});
    defer aggregator.deinit();
    try std.testing.expectError(error.InvalidBatch, aggregator.ingest(":irc BATCH +bad_ref example/type"));
    _ = try aggregator.ingest(":irc BATCH +outer example/type");
    _ = try aggregator.ingest("@batch=outer :irc BATCH +inner example/type");
    try std.testing.expectError(error.InvalidBatch, aggregator.ingest(":irc BATCH -inner"));
    _ = try aggregator.ingest("@batch=outer :irc BATCH -inner");
    _ = try aggregator.ingest(":irc BATCH -outer");
}
