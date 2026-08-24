//! Map IRC participants to Comic Chat avatars and collect a transcript, so a
//! live conversation can be rendered as a comic strip.

const std = @import("std");
const dcc = @import("../proto/dcc.zig");
const formatting = @import("formatting.zig");
const original_page = @import("original_page.zig");
const irc_message = @import("../net/message.zig");
const udi = @import("../proto/udi.zig");

pub const avatars = [_][]const u8{
    "anna",     "armando", "bolo",     "cro",     "dan",   "denise",
    "hugh",     "jordan",  "kevin",    "kwensa",  "lance", "lynnea",
    "margaret", "maynard", "mike",     "rebecca", "sage",  "scotty",
    "susan",    "tiki",    "tongtyed", "xeno",
};

/// Generated Color AVBs are the portable client's default cast; original
/// source AVBs remain available only through the explicit Original family.
pub const default_avatars = [_][]const u8{
    "anna color",     "armando color", "bolo color",     "cro color",     "dan color",   "denise color",
    "hugh color",     "jordan color",  "kevin color",    "kwensa color",  "lance color", "lynnea color",
    "margaret color", "maynard color", "mike color",     "rebecca color", "sage color",  "scotty color",
    "susan color",    "tiki color",    "tongtyed color", "xeno color",
};

pub const avatar_announcement_prefix = "# Appears as ";
pub const ctcp_action_prefix = "\x01ACTION ";
pub const ctcp_sound_prefix = "\x01SOUND ";
pub const ctcp_away_prefix = "\x01AWAY";

/// Unwrap the conventional CTCP ACTION payload emitted by `SlashMeOrThink`.
/// The slice still borrows from the UDI-stripped wire message.
pub fn ctcpActionText(text: []const u8) ?[]const u8 {
    return ctcpCommandPayload(text, "ACTION");
}

pub const SoundControl = struct {
    name: []const u8,
    message: []const u8,
};

pub fn ctcpSound(text: []const u8) ?SoundControl {
    const payload = ctcpCommandPayload(text, "SOUND") orelse return null;
    const separator = firstUnquotedCtcpSpace(payload) orelse payload.len;
    if (separator == 0) return null;
    return .{
        .name = payload[0..separator],
        .message = if (separator < payload.len) payload[separator + 1 ..] else "",
    };
}

fn ctcpCommandPayload(text: []const u8, command: []const u8) ?[]const u8 {
    if (text.len < 2 or text[0] != 0x01 or text[text.len - 1] != 0x01) return null;
    const body = text[1 .. text.len - 1];
    if (body.len < command.len or !std.ascii.eqlIgnoreCase(body[0..command.len], command)) return null;
    if (body.len == command.len) return null;
    if (body[command.len] != ' ') return null;
    return body[command.len + 1 ..];
}

/// Split SOUND on the first raw space. CTCP-quoted spaces are `\x10@` and
/// must stay inside the filename token until `ctcpUnquote`.
fn firstUnquotedCtcpSpace(payload: []const u8) ?usize {
    var index: usize = 0;
    while (index < payload.len) : (index += 1) {
        if (payload[index] == 0x10) {
            if (index + 1 < payload.len) index += 1;
            continue;
        }
        if (payload[index] == ' ') return index;
    }
    return null;
}

/// Microsoft broadcasts `\x01AWAY [message]\x01` to each joined room after
/// the standard IRC AWAY command. An empty payload clears away state.
pub fn ctcpAwayMessage(text: []const u8) ?[]const u8 {
    if (text.len < ctcp_away_prefix.len + 1 or text[text.len - 1] != 0x01)
        return null;
    if (!std.ascii.eqlIgnoreCase(text[0..ctcp_away_prefix.len], ctcp_away_prefix))
        return null;
    if (text.len == ctcp_away_prefix.len + 1) return "";
    if (text[ctcp_away_prefix.len] != ' ') return null;
    return text[ctcp_away_prefix.len + 1 .. text.len - 1];
}

/// Return the canonical bundled avatar name used by the renderer.
pub fn bundledAvatarByName(name: []const u8) ?[]const u8 {
    for (avatars) |avatar| {
        if (std.ascii.eqlIgnoreCase(avatar, name)) return avatar;
    }
    // The live source control is a compact token (`AnnaColor.`), while the
    // portable renderer keeps family display names readable (`anna color`).
    // Accept the compact color spelling emitted on IRC and resolve it to the
    // generated AVB selected by the peer.
    for (avatars, 0..) |avatar, index| {
        const suffix = "color";
        if (name.len == avatar.len + suffix.len and
            std.ascii.eqlIgnoreCase(name[0..avatar.len], avatar) and
            std.ascii.eqlIgnoreCase(name[avatar.len..], suffix))
            return default_avatars[index];
    }
    // Generated HD and Color AVBs plus the source-faithful originals are
    // canonical runtime families, not UI-only display names.  Keep this
    // normalization alongside the wire validator so avatar announcements and
    // locally applied character choices reach strip.avatarByName unchanged.
    const families = [_][]const u8{ " hd", " color", " original" };
    for (families) |family| {
        if (name.len <= family.len or !std.ascii.eqlIgnoreCase(name[name.len - family.len ..], family)) continue;
        const base = name[0 .. name.len - family.len];
        for (avatars) |avatar| if (std.ascii.eqlIgnoreCase(avatar, base)) return name;
    }
    return null;
}

/// Return the source-era avatar token suitable for `# Appears as ...`.
///
/// Generated families intentionally use display names such as `anna color`,
/// but the Microsoft comment grammar uses a single filename-like token.  Keep
/// the richer local selection for Reinked while announcing the base cast name
/// so original Comic Chat clients can resolve it instead of rejecting the
/// whole control message.
pub fn avatarAnnouncementName(name: []const u8) ?[]const u8 {
    return bundledAvatarByName(name);
}

test "generated avatar families announce their legacy-compatible base name" {
    try std.testing.expectEqualStrings("anna color", avatarAnnouncementName("anna color").?);
    try std.testing.expectEqualStrings("Tiki HD", avatarAnnouncementName("Tiki HD").?);
    try std.testing.expectEqualStrings("xeno original", avatarAnnouncementName("xeno original").?);
    try std.testing.expectEqualStrings("anna color", bundledAvatarByName("AnnaColor").?);
    try std.testing.expect(avatarAnnouncementName("not a bundled avatar") == null);
}

/// Result of parsing the source client's `ProcessComment` avatar control.
/// Recognized-but-invalid controls are distinguished from ordinary chat so a
/// malformed announcement is still consumed instead of becoming a balloon.
pub const AvatarAnnouncement = union(enum) {
    not_control,
    invalid,
    none,
    avatar: []const u8,
};

/// Parse `# Appears as <name>[.<url>]`. The optional URL is validated but
/// intentionally ignored: this port only selects avatars bundled with it.
pub fn parseAvatarAnnouncement(text: []const u8) AvatarAnnouncement {
    if (!std.mem.startsWith(u8, text, avatar_announcement_prefix)) return .not_control;

    const value = text[avatar_announcement_prefix.len..];
    if (value.len == 0) return .invalid;
    const dot = std.mem.indexOfScalar(u8, value, '.');
    const name = if (dot) |index| value[0..index] else value;
    if (name.len == 0) return .invalid;

    // Families use a single space suffix (HD, Color, Original).  Acceptance
    // remains strict because bundledAvatarByName below recognizes only exact
    // base/family names; reject controls and punctuation here.
    for (name) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and ch != '_' and ch != '-' and ch != ' ') return .invalid;
    }

    // ChatAnnounceNewAvatar emits a terminal period after the local avatar
    // token.  A period followed by bytes remains the optional source URL;
    // the terminal punctuation is not an empty URL.
    if (dot) |index| {
        if (index + 1 < value.len) {
            const url = value[index + 1 ..];
            for (url) |ch| {
                if (ch <= ' ' or ch > '~') return .invalid;
            }
        }
    }

    if (std.ascii.eqlIgnoreCase(name, "NONE")) return .none;
    return if (bundledAvatarByName(name)) |avatar| .{ .avatar = avatar } else .invalid;
}

pub const get_info_prefix = " GetInfo";
pub const heres_info_prefix = " HeresInfo: ";
pub const get_char_info_prefix = " GetCharInfo";
pub const backdrop_prefix = " BDrop: ";
pub const backdrop2_prefix = " BDrop2: ";

/// The small text-comment controls beyond the avatar announcement
/// (`protsupp.cpp:902-962`'s `ProcessComment` dispatch table). Callers pass
/// the message with the leading `#` already stripped, matching
/// `parseAvatarAnnouncement`. Source matches these with a plain `strncmp`
/// prefix check rather than requiring an exact remainder, so a message with
/// trailing garbage is still recognized.
pub const ProfileControl = union(enum) {
    not_control,
    /// ` GetInfo` - a profile request; no payload.
    get_info,
    /// ` GetCharInfo` - a request to resend our avatar name/URL. No
    /// payload. Source triggers `ChatAnnounceNewAvatar` with the real URL
    /// (protsupp.cpp:926-939); this port does not implement avatar file
    /// transfer (`filesend.cpp`), so recognizing the request is as far as
    /// it goes.
    get_char_info,
    /// ` HeresInfo: <profile>` - a profile reply. Source only displays this
    /// when the receiver actually asked (protsupp.cpp:948, the `RF_PROFILE`
    /// request counter); this pure parser does not track that state.
    heres_info: []const u8,
};

pub fn parseProfileControl(text: []const u8) ProfileControl {
    if (std.mem.startsWith(u8, text, get_info_prefix)) return .get_info;
    if (std.mem.startsWith(u8, text, get_char_info_prefix)) return .get_char_info;
    if (std.mem.startsWith(u8, text, heres_info_prefix))
        return .{ .heres_info = text[heres_info_prefix.len..] };
    return .not_control;
}

/// One backdrop-sync announcement (protsupp.cpp:964-1017's `BACKGRNDPREFIX`
/// / `NEWBACKGRNDPREFIX` handlers).
pub const BackdropAnnouncement = struct {
    /// Name exactly as sent (extension retained, e.g. "cave.bmp").
    name: []const u8,
    /// Name truncated at the first '.', matching `g_szLastBackdropName`
    /// (protsupp.cpp:1005-1008) - the value a later legacy ` BDrop: `
    /// message is compared against before a real client applies it.
    base_name: []const u8,
    /// Null when no URL segment followed the name.
    url: ?[]const u8,
};

pub const BackdropControl = union(enum) {
    not_control,
    /// Recognized but a no-op: the source only acts `if (*szBackdropName)`
    /// (protsupp.cpp:1003) or `if (*strToEnd)` (protsupp.cpp:977).
    empty,
    /// ` BDrop2: name[,url]` - the modern form (protsupp.cpp:988-1017).
    sync: BackdropAnnouncement,
    /// ` BDrop: name` - the legacy compat form sent second by
    /// `ChatSyncBackDrop` for old clients (protsupp.cpp:964-983). The
    /// source applies it only when `name` differs case-insensitively from
    /// the last BDrop2 base name; `Transcript.applyBackdropControl` owns
    /// that comparison.
    legacy: []const u8,
};

/// Port of `GetToken2`'s begin/end-separator scan (protsupp.cpp:257-283):
/// skip whitespace or a `seps_begin` byte, then take bytes until whitespace
/// or a `seps_end` byte. Returns `null` when nothing but skipped bytes
/// remain, matching the source returning `NULL` when `!*szStart`.
fn getToken2(text: []const u8, seps_begin: []const u8, seps_end: []const u8) ?struct { token: []const u8, rest: []const u8 } {
    var start: usize = 0;
    while (start < text.len and (std.ascii.isWhitespace(text[start]) or std.mem.indexOfScalar(u8, seps_begin, text[start]) != null))
        start += 1;
    if (start == text.len) return null;
    var end = start;
    while (end < text.len and !std.ascii.isWhitespace(text[end]) and std.mem.indexOfScalar(u8, seps_end, text[end]) == null)
        end += 1;
    return .{ .token = text[start..end], .rest = text[end..] };
}

pub fn parseBackdropControl(text: []const u8) BackdropControl {
    if (std.mem.startsWith(u8, text, backdrop2_prefix)) {
        const rest = text[backdrop2_prefix.len..];
        const name_tok = getToken2(rest, ",", ",") orelse return .empty;
        if (name_tok.token.len == 0) return .empty;
        const url_tok = getToken2(name_tok.rest, ",", ",)");
        const dot = std.mem.indexOfScalar(u8, name_tok.token, '.');
        return .{ .sync = .{
            .name = name_tok.token,
            .base_name = if (dot) |i| name_tok.token[0..i] else name_tok.token,
            .url = if (url_tok) |u| u.token else null,
        } };
    }
    if (std.mem.startsWith(u8, text, backdrop_prefix)) {
        const rest = text[backdrop_prefix.len..];
        var i: usize = 0;
        while (i < rest.len and std.ascii.isWhitespace(rest[i])) i += 1;
        if (i == rest.len) return .empty;
        return .{ .legacy = rest[i..] };
    }
    return .not_control;
}

/// Deterministic, case-insensitive nick → generated Color avatar (FNV-1a).
pub fn avatarForNick(nick: []const u8) []const u8 {
    var h: u64 = 0xcbf29ce484222325;
    for (nick) |ch| {
        h = (h ^ std.ascii.toLower(ch)) *% 0x100000001b3;
    }
    return default_avatars[@intCast(h % default_avatars.len)];
}

/// "nick!user@host" or ":nick!.." → "nick".
pub fn nickFromPrefix(prefix: []const u8) []const u8 {
    var p = prefix;
    if (p.len > 0 and p[0] == ':') p = p[1..];
    const bang = std.mem.indexOfScalar(u8, p, '!') orelse p.len;
    return p[0..bang];
}

pub const TalkTarget = struct {
    nick: []const u8,
    avatar: []const u8,
};

pub const Line = struct {
    nick: []const u8,
    avatar: []const u8,
    text: []const u8,
    /// Source `CDWordArray` state changes, indexed into the control-free text.
    formatting: []const formatting.Change = &.{},
    /// Optional semantic pose override for local/non-UDI callers.
    pose_text: ?[]const u8 = null,
    /// Exact cooked avatar state from the live UDI.  Null means the old client
    /// would derive a pose from message text instead (`ChatPreSendText`).
    pose_state: ?udi.PoseState = null,
    talk_targets: []const TalkTarget = &.{},
    modes: u16 = original_page.bm_say,
};

pub const AddOptions = struct {
    pose_text: ?[]const u8 = null,
    pose_state: ?udi.PoseState = null,
    /// Stable IRC nick identities explicitly addressed by this speaker.
    talk_target_nicks: []const []const u8 = &.{},
    modes: u16 = original_page.bm_say,
};

/// Live channel-member state used by the source `AddStarsAux` title pass.
/// The transcript owns `nick`; avatar names refer to the canonical static list.
pub const MemberRole = enum(u8) {
    member,
    voice,
    halfop,
    operator,
    owner,

    pub fn canModerate(self: MemberRole) bool {
        return @intFromEnum(self) >= @intFromEnum(MemberRole.halfop);
    }

    pub fn badge(self: MemberRole) []const u8 {
        return switch (self) {
            .member => "",
            .voice => "+",
            .halfop => "%",
            .operator => "@",
            .owner => "~",
        };
    }
};

pub const RosterEntry = struct {
    nick: []u8,
    avatar: []const u8,
    is_self: bool = false,
    sends: u32 = 0,
    departed: bool = false,
    away: bool = false,
    role: MemberRole = .member,
    status_modes: u8 = 0,
    /// Generation last listed in a 353 burst. Used with `Transcript.names_generation`
    /// so 366 can retire members absent from the completed NAMES snapshot.
    names_generation: u32 = 0,
};

/// Accumulates conversation lines, owning copies of the text (wire buffers are
/// reused by the framer, so we must dupe).
pub const Transcript = struct {
    gpa: std.mem.Allocator,
    lines: std.ArrayList(Line) = .empty,
    roster: std.ArrayList(RosterEntry) = .empty,
    backdrop_storage: ?[]u8 = null,
    last_bdrop2_base: ?[]u8 = null,
    names_generation: u32 = 0,
    names_sync_active: bool = false,

    pub fn init(gpa: std.mem.Allocator) Transcript {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Transcript) void {
        for (self.lines.items) |line| deinitLine(self.gpa, line);
        self.lines.deinit(self.gpa);
        for (self.roster.items) |entry| self.gpa.free(entry.nick);
        self.roster.deinit(self.gpa);
        if (self.backdrop_storage) |name| self.gpa.free(name);
        if (self.last_bdrop2_base) |name| self.gpa.free(name);
    }

    pub fn setBackdrop(self: *Transcript, name: []const u8) !void {
        const bundled = bundledBackdropByName(name) orelse return error.UnknownBackdrop;
        const replacement = try self.gpa.dupe(u8, bundled);
        if (self.backdrop_storage) |old| self.gpa.free(old);
        self.backdrop_storage = replacement;
    }

    pub fn resolvedBackdrop(self: *const Transcript) []const u8 {
        return self.backdrop_storage orelse "color apartment";
    }

    /// Consume a parsed `# BDrop2` / `# BDrop` control. A legacy BDrop whose
    /// name matches the last BDrop2 base is ignored, matching
    /// `g_szLastBackdropName` in `protsupp.cpp:964-1017`.
    pub fn applyBackdropControl(self: *Transcript, control: BackdropControl) !bool {
        switch (control) {
            .not_control => return false,
            .empty => return true,
            .sync => |announcement| {
                const replacement = try self.gpa.dupe(u8, announcement.base_name);
                if (self.last_bdrop2_base) |old| self.gpa.free(old);
                self.last_bdrop2_base = replacement;
                if (bundledBackdropByName(announcement.base_name)) |name| try self.setBackdrop(name);
                return true;
            },
            .legacy => |name| {
                if (self.last_bdrop2_base) |base| {
                    if (std.ascii.eqlIgnoreCase(name, base)) return true;
                }
                if (bundledBackdropByName(name)) |bundled| try self.setBackdrop(bundled);
                return true;
            },
        }
    }

    /// Resolve a participant through their most recent source announcement,
    /// falling back to the deterministic portable assignment.
    pub fn resolvedAvatar(self: *const Transcript, nick: []const u8) []const u8 {
        if (self.findRosterIndex(nick)) |index| return self.roster.items[index].avatar;
        return avatarForNick(nick);
    }

    pub fn activeMemberCount(self: *const Transcript) usize {
        var active_count: usize = 0;
        for (self.roster.items) |member| if (!member.departed) {
            active_count += 1;
        };
        return active_count;
    }

    /// Establish the local participant before NAMES arrives. `AddStarsAux`
    /// always inserts this member first regardless of activity or send count.
    pub fn setSelf(self: *Transcript, nick: []const u8) !void {
        for (self.roster.items) |*entry| entry.is_self = false;
        const index = try self.ensureParticipant(nick, true);
        self.roster.items[index].is_self = true;
        self.roster.items[index].departed = false;
    }

    /// Fold the IRC membership events that fed the old client's member map
    /// into portable title-panel state. Returns whether the roster changed.
    pub fn observeIrc(
        self: *Transcript,
        msg: *const irc_message.Message,
        channel: []const u8,
        self_nick: []const u8,
    ) !bool {
        if (std.ascii.eqlIgnoreCase(msg.command, "353")) {
            const names_channel = namesReplyChannel(msg) orelse return false;
            if (!std.ascii.eqlIgnoreCase(names_channel, channel)) return false;
            if (!self.names_sync_active) {
                self.names_generation +%= 1;
                self.names_sync_active = true;
            }
            var changed = false;
            var names = std.mem.tokenizeScalar(u8, msg.params[msg.param_count - 1], ' ');
            while (names.next()) |decorated| {
                var nick = decorated;
                var role: MemberRole = .member;
                var status_modes: u8 = 0;
                while (nick.len > 0 and isNickStatus(nick[0])) {
                    role = highestRole(role, roleForPrefix(nick[0]));
                    status_modes |= modeBitForPrefix(nick[0]);
                    nick = nick[1..];
                }
                const bang = std.mem.indexOfScalar(u8, nick, '!') orelse nick.len;
                nick = nick[0..bang];
                if (nick.len == 0) continue;
                const existing = self.findRosterIndex(nick);
                const index = try self.ensureParticipant(
                    nick,
                    std.ascii.eqlIgnoreCase(nick, self_nick),
                );
                if (existing == null or self.roster.items[index].departed) changed = true;
                self.roster.items[index].departed = false;
                self.roster.items[index].names_generation = self.names_generation;
                if (self.roster.items[index].role != role) changed = true;
                self.roster.items[index].role = role;
                self.roster.items[index].status_modes = status_modes;
            }
            return changed;
        }

        if (std.ascii.eqlIgnoreCase(msg.command, "366")) {
            const names_channel = endOfNamesChannel(msg) orelse return false;
            if (!std.ascii.eqlIgnoreCase(names_channel, channel)) return false;
            if (!self.names_sync_active) {
                self.names_generation +%= 1;
            }
            self.names_sync_active = false;
            var changed = false;
            for (self.roster.items) |*entry| {
                if (entry.names_generation == self.names_generation) continue;
                if (entry.is_self) continue;
                if (entry.departed) continue;
                entry.departed = true;
                changed = true;
            }
            return changed;
        }

        if (std.ascii.eqlIgnoreCase(msg.command, "JOIN")) {
            const joined_channel = msg.param(0) orelse return false;
            if (!std.ascii.eqlIgnoreCase(joined_channel, channel)) return false;
            const prefix = msg.prefix orelse return false;
            const nick = nickFromPrefix(prefix);
            if (nick.len == 0) return false;
            const existing = self.findRosterIndex(nick);
            const index = try self.ensureParticipant(
                nick,
                std.ascii.eqlIgnoreCase(nick, self_nick),
            );
            const changed = existing == null or self.roster.items[index].departed;
            self.roster.items[index].departed = false;
            self.roster.items[index].away = false;
            self.roster.items[index].role = .member;
            self.roster.items[index].status_modes = 0;
            return changed;
        }

        if (std.ascii.eqlIgnoreCase(msg.command, "MODE")) {
            if (msg.param_count < 2) return false;
            if (!std.ascii.eqlIgnoreCase(msg.params[0], channel)) return false;
            const modes = msg.params[1];
            var adding = true;
            var parameter_index: usize = 2;
            var changed = false;
            for (modes) |mode| switch (mode) {
                '+' => adding = true,
                '-' => adding = false,
                'q', 'a', 'o', 'h', 'v' => {
                    if (parameter_index >= msg.param_count) continue;
                    const nick = msg.params[parameter_index];
                    parameter_index += 1;
                    const index = self.findRosterIndex(nick) orelse continue;
                    const bit = modeBit(mode);
                    const old_modes = self.roster.items[index].status_modes;
                    if (adding)
                        self.roster.items[index].status_modes |= bit
                    else
                        self.roster.items[index].status_modes &= ~bit;
                    if (old_modes != self.roster.items[index].status_modes) changed = true;
                    const replacement = highestRoleForModes(self.roster.items[index].status_modes);
                    if (replacement != self.roster.items[index].role) {
                        self.roster.items[index].role = replacement;
                        changed = true;
                    }
                },
                'b', 'e', 'I', 'k' => {
                    if (parameter_index < msg.param_count) parameter_index += 1;
                },
                'l' => {
                    if (adding and parameter_index < msg.param_count) parameter_index += 1;
                },
                else => {},
            };
            return changed;
        }

        if (std.ascii.eqlIgnoreCase(msg.command, "KICK")) {
            if (msg.param_count < 2) return false;
            if (!std.ascii.eqlIgnoreCase(msg.params[0], channel)) return false;
            return self.markDeparted(msg.params[1]);
        }

        if (std.ascii.eqlIgnoreCase(msg.command, "PART")) {
            const parted_channel = msg.param(0) orelse return false;
            if (!std.ascii.eqlIgnoreCase(parted_channel, channel)) return false;
            const prefix = msg.prefix orelse return false;
            return self.markDeparted(nickFromPrefix(prefix));
        }

        if (std.ascii.eqlIgnoreCase(msg.command, "QUIT")) {
            const prefix = msg.prefix orelse return false;
            return self.markDeparted(nickFromPrefix(prefix));
        }

        if (std.ascii.eqlIgnoreCase(msg.command, "AWAY")) {
            const prefix = msg.prefix orelse return false;
            const nick = nickFromPrefix(prefix);
            if (nick.len == 0) return false;
            const index = try self.ensureParticipant(nick, std.ascii.eqlIgnoreCase(nick, self_nick));
            const away = if (msg.param(0)) |text| text.len != 0 else false;
            if (self.roster.items[index].away == away) return false;
            self.roster.items[index].away = away;
            return true;
        }

        if (std.ascii.eqlIgnoreCase(msg.command, "KILL")) {
            return self.markDeparted(msg.param(0) orelse return false);
        }

        if (std.mem.eql(u8, msg.command, "301")) {
            const nick = msg.param(1) orelse return false;
            const index = try self.ensureParticipant(nick, std.ascii.eqlIgnoreCase(nick, self_nick));
            if (self.roster.items[index].away) return false;
            self.roster.items[index].away = true;
            return true;
        }

        if (std.ascii.eqlIgnoreCase(msg.command, "NICK")) {
            const prefix = msg.prefix orelse return false;
            const old_nick = nickFromPrefix(prefix);
            const new_nick = msg.param(0) orelse return false;
            if (old_nick.len == 0 or new_nick.len == 0) return false;
            const old_index = self.findRosterIndex(old_nick) orelse return false;
            const owned_new = try self.gpa.dupe(u8, new_nick);
            errdefer self.gpa.free(owned_new);
            if (self.findRosterIndex(new_nick)) |new_index| {
                if (new_index != old_index) {
                    const old = self.roster.items[old_index];
                    var target = &self.roster.items[new_index];
                    target.avatar = old.avatar;
                    target.is_self = target.is_self or old.is_self;
                    // Keep the surviving identity present if either side is
                    // still in the room. A departed ghost must not evict an
                    // active homonym during a nick collision merge.
                    target.departed = target.departed and old.departed;
                    target.away = target.away or old.away;
                    target.role = highestRole(target.role, old.role);
                    target.status_modes |= old.status_modes;
                    target.sends = saturatingAdd(target.sends, old.sends);
                    self.gpa.free(owned_new);
                    const removed = self.roster.orderedRemove(old_index);
                    self.gpa.free(removed.nick);
                    return true;
                }
            }
            self.gpa.free(self.roster.items[old_index].nick);
            self.roster.items[old_index].nick = owned_new;
            return true;
        }

        return false;
    }

    /// Set an explicit bundled avatar, or clear the override for source NONE.
    pub fn setAvatar(self: *Transcript, nick: []const u8, avatar: ?[]const u8) !void {
        const canonical = if (avatar) |name|
            bundledAvatarByName(name) orelse return error.UnknownAvatar
        else
            null;
        const index = try self.ensureParticipant(nick, false);
        self.roster.items[index].avatar = canonical orelse avatarForNick(self.roster.items[index].nick);
        self.roster.items[index].departed = false;
    }

    /// Apply and consume a source avatar control. Returns false only for an
    /// ordinary chat message. Unknown/malformed announced avatars are hidden
    /// just as `ProcessComment` hid comments before `ProcessSay`.
    pub fn consumeAvatarAnnouncement(self: *Transcript, nick: []const u8, text: []const u8) !bool {
        switch (parseAvatarAnnouncement(text)) {
            .not_control => return false,
            .invalid => return true,
            .none => try self.setAvatar(nick, null),
            .avatar => |avatar| try self.setAvatar(nick, avatar),
        }
        return true;
    }

    pub fn add(self: *Transcript, nick: []const u8, text: []const u8) !void {
        return self.addWithOptions(nick, text, .{});
    }

    pub fn insertPageBreak(self: *Transcript, nick: []const u8, index: usize) !void {
        const bounded = @min(index, self.lines.items.len);
        try self.addWithOptions(nick, "<Brk>", .{});
        const line = self.lines.pop().?;
        self.lines.insert(self.gpa, bounded, line) catch |err| {
            self.lines.append(self.gpa, line) catch deinitLine(self.gpa, line);
            return err;
        };
    }

    pub fn removeLine(self: *Transcript, index: usize) bool {
        if (index >= self.lines.items.len) return false;
        const line = self.lines.orderedRemove(index);
        if (!std.mem.eql(u8, line.text, "<Brk>")) if (self.findRosterIndex(line.nick)) |roster_index| {
            self.roster.items[roster_index].sends -|= 1;
        };
        deinitLine(self.gpa, line);
        return true;
    }

    pub fn addWithOptions(
        self: *Transcript,
        nick: []const u8,
        text: []const u8,
        options: AddOptions,
    ) !void {
        const roster_index = try self.ensureParticipant(nick, false);
        self.roster.items[roster_index].departed = false;
        const n = try self.gpa.dupe(u8, nick);
        errdefer self.gpa.free(n);
        // SayEntry parses the UDI first, then runs SzControlLess over the
        // readable message. `addWireMessage` performs that outer UDI step;
        // every line becomes owned control-free text here.
        const parsed_text = try formatting.parse(self.gpa, text);
        const t = parsed_text.text;
        errdefer self.gpa.free(t);
        const format_changes = parsed_text.changes;
        errdefer self.gpa.free(format_changes);
        const pose = if (options.pose_text) |value| try self.gpa.dupe(u8, value) else null;
        errdefer if (pose) |value| self.gpa.free(value);
        const targets = try self.gpa.alloc(TalkTarget, options.talk_target_nicks.len);
        var initialized: usize = 0;
        errdefer {
            for (targets[0..initialized]) |target| self.gpa.free(target.nick);
            self.gpa.free(targets);
        }
        for (options.talk_target_nicks, 0..) |target_nick, index| {
            const owned_nick = try self.gpa.dupe(u8, target_nick);
            targets[index] = .{ .nick = owned_nick, .avatar = self.resolvedAvatar(owned_nick) };
            initialized += 1;
        }
        try self.lines.append(self.gpa, .{
            .nick = n,
            .avatar = self.roster.items[roster_index].avatar,
            .text = t,
            .formatting = format_changes,
            .pose_text = pose,
            .pose_state = options.pose_state,
            .talk_targets = targets,
            .modes = options.modes,
        });
        // `CChatDoc::ProcessLine` calls TallySpeech for every non-break line.
        // Avatar announcements are consumed before reaching this path.
        if (!std.mem.eql(u8, t, "<Brk>"))
            self.roster.items[roster_index].sends = saturatingAdd(
                self.roster.items[roster_index].sends,
                1,
            );
    }

    /// Decode the old client's non-IRCX embedded UDI, or apply a preceding
    /// IRCX `DATA ... CCUDI1` annotation, before taking ownership of the
    /// readable message. Malformed annotations degrade to ordinary IRC text.
    pub fn addWireMessage(
        self: *Transcript,
        nick: []const u8,
        wire_message: []const u8,
        is_private: bool,
        pending_annotation: ?[]const u8,
    ) !void {
        const parsed = udi.parseMessage(wire_message, is_private) catch null;
        var text = wire_message;
        var modes: u16 = if (is_private) original_page.bm_whisper else original_page.bm_say;
        var annotation: ?udi.Annotation = null;
        if (parsed) |message| {
            text = message.text;
            modes = message.modes;
            annotation = message.annotation;
        }
        if (annotation == null) {
            if (pending_annotation) |wire| {
                if (udi.parseAnnotation(wire)) |decoded| {
                    annotation = decoded;
                    modes = if (is_private) udi.privateModes(decoded.modes) else decoded.modes;
                } else |_| {}
            }
        }

        var action_prepared = false;
        var sound_text: std.ArrayList(u8) = .empty;
        defer sound_text.deinit(self.gpa);
        if (ctcpSound(text)) |sound| {
            const unquoted_name = try dcc.ctcpUnquote(self.gpa, sound.name);
            defer if (unquoted_name) |owned| self.gpa.free(owned);
            const display_name = unquoted_name orelse sound.name;
            try sound_text.appendSlice(self.gpa, nick);
            if (sound.message.len != 0) {
                try sound_text.append(self.gpa, ' ');
                try sound_text.appendSlice(self.gpa, sound.message);
            }
            try sound_text.appendSlice(self.gpa, " (");
            try sound_text.appendSlice(self.gpa, display_name);
            try sound_text.append(self.gpa, ')');
            text = sound_text.items;
            modes = (modes & original_page.bm_whisper) | original_page.bm_action;
            action_prepared = true;
        }

        // ProcessSay removes the UDI first. Non-comics clients then arrive as
        // CTCP ACTION; keep a private whisper bit while selecting ACTION.
        if (ctcpActionText(text)) |action_text| {
            text = action_text;
            modes = (modes & original_page.bm_whisper) | original_page.bm_action;
        }

        // Both PrepareComicsAction (raw text + UDI M5) and PrepareTextAction
        // (CTCP fallback) prefix the sender's screen name before the box is
        // handed to ProcessLine.
        var action_text: std.ArrayList(u8) = .empty;
        defer action_text.deinit(self.gpa);
        if (modes & original_page.bm_action != 0 and !action_prepared) {
            try action_text.appendSlice(self.gpa, nick);
            try action_text.append(self.gpa, ' ');
            try action_text.appendSlice(self.gpa, text);
            text = action_text.items;
        }

        var target_nicks: std.ArrayList([]const u8) = .empty;
        defer target_nicks.deinit(self.gpa);
        if (annotation) |decoded| {
            var it = decoded.talkTos();
            while (it.next()) |target| try target_nicks.append(self.gpa, target);
        }
        try self.addWithOptions(nick, text, .{
            .pose_state = if (annotation) |decoded| decoded.poseState() else null,
            .talk_target_nicks = target_nicks.items,
            .modes = modes,
        });
    }

    /// Keep only the newest `limit` lines. Interactive sessions call this
    /// after appending so a channel left open for days has bounded memory use.
    pub fn trimTo(self: *Transcript, limit: usize) void {
        if (self.lines.items.len <= limit) return;
        const remove_count = self.lines.items.len - limit;
        for (self.lines.items[0..remove_count]) |line| deinitLine(self.gpa, line);
        std.mem.copyForwards(
            Line,
            self.lines.items[0..limit],
            self.lines.items[remove_count..],
        );
        self.lines.items.len = limit;
    }

    pub fn count(self: *const Transcript) usize {
        return self.lines.items.len;
    }

    /// Consume the source CTCP away broadcast without turning it into a chat
    /// bubble. Returns false for any other message.
    pub fn consumeAwayControl(self: *Transcript, nick: []const u8, wire: []const u8) !bool {
        const message_text = ctcpAwayMessage(wire) orelse return false;
        _ = try self.setAway(nick, message_text.len != 0);
        return true;
    }

    pub fn setAway(self: *Transcript, nick: []const u8, away: bool) !bool {
        const index = try self.ensureParticipant(nick, false);
        if (self.roster.items[index].away == away) return false;
        self.roster.items[index].away = away;
        return true;
    }

    fn findRosterIndex(self: *const Transcript, nick: []const u8) ?usize {
        for (self.roster.items, 0..) |entry, index| {
            if (std.ascii.eqlIgnoreCase(entry.nick, nick)) return index;
        }
        return null;
    }

    fn ensureParticipant(self: *Transcript, nick: []const u8, is_self: bool) !usize {
        if (self.findRosterIndex(nick)) |index| {
            if (is_self) self.roster.items[index].is_self = true;
            return index;
        }
        const owned_nick = try self.gpa.dupe(u8, nick);
        errdefer self.gpa.free(owned_nick);
        try self.roster.append(self.gpa, .{
            .nick = owned_nick,
            .avatar = avatarForNick(owned_nick),
            .is_self = is_self,
        });
        return self.roster.items.len - 1;
    }

    fn markDeparted(self: *Transcript, nick: []const u8) bool {
        const index = self.findRosterIndex(nick) orelse return false;
        if (self.roster.items[index].departed) return false;
        self.roster.items[index].departed = true;
        return true;
    }
};

pub fn bundledBackdropByName(name: []const u8) ?[]const u8 {
    const dot = std.mem.indexOfScalar(u8, name, '.');
    const base = if (dot) |index| name[0..index] else name;
    for ([_][]const u8{ "field", "volcano", "den", "room", "pastoral", "hd apartment", "hd rooftop", "hd cafe", "hd park", "hd space corridor", "hd boardwalk", "hd school hall", "hd rainy street", "hd library", "hd campsite", "color apartment", "color rooftop", "color cafe", "color park", "color space corridor", "color boardwalk", "color school hall", "color rainy street", "color library", "color campsite", "whacky spaceship bridge", "whacky asteroid diner", "whacky sky island market", "whacky underwater dome", "whacky friendly castle", "whacky pinball interior", "whacky cosmic laundromat", "whacky cloud train station", "whacky mushroom village", "whacky arcade planetarium" }) |candidate| {
        if (std.ascii.eqlIgnoreCase(base, candidate)) return candidate;
    }
    return null;
}

test "transcript applies only bundled backdrop names" {
    var transcript = Transcript.init(std.testing.allocator);
    defer transcript.deinit();
    try std.testing.expectEqualStrings("color apartment", transcript.resolvedBackdrop());
    try transcript.setBackdrop("Volcano.bgb");
    try std.testing.expectEqualStrings("volcano", transcript.resolvedBackdrop());
    try std.testing.expectError(error.UnknownBackdrop, transcript.setBackdrop("https://example.test/remote.bgb"));
    try std.testing.expectEqualStrings("volcano", transcript.resolvedBackdrop());
}

test "every generated backdrop is accepted for local and remote comic state" {
    const generated = [_][]const u8{
        "hd apartment",            "hd rooftop",            "hd cafe",                  "hd park",                "hd space corridor",      "hd boardwalk",            "hd school hall",           "hd rainy street",            "hd library",              "hd campsite",
        "color apartment",         "color rooftop",         "color cafe",               "color park",             "color space corridor",   "color boardwalk",         "color school hall",        "color rainy street",         "color library",           "color campsite",
        "whacky spaceship bridge", "whacky asteroid diner", "whacky sky island market", "whacky underwater dome", "whacky friendly castle", "whacky pinball interior", "whacky cosmic laundromat", "whacky cloud train station", "whacky mushroom village", "whacky arcade planetarium",
    };
    var transcript = Transcript.init(std.testing.allocator);
    defer transcript.deinit();
    inline for (generated) |name| {
        try transcript.setBackdrop(name);
        try std.testing.expectEqualStrings(name, transcript.resolvedBackdrop());
        try std.testing.expectEqualStrings(name, bundledBackdropByName(name ++ ".bgb").?);
    }
}

/// RFC 2812 `353 <me> <type> <channel> :<nicks>` plus the 3-parameter form
/// and a glued type prefix (`=#room`). The last parameter is always the
/// nick list; the channel is the last earlier token that looks like one.
fn namesReplyChannel(msg: *const irc_message.Message) ?[]const u8 {
    if (msg.param_count < 2) return null;
    var index = msg.param_count - 2;
    while (true) {
        if (channelToken(msg.params[index])) |channel| return channel;
        if (index == 0) break;
        index -= 1;
    }
    return null;
}

/// RFC 2812 `366 <me> <channel> :End of /NAMES list`.
fn endOfNamesChannel(msg: *const irc_message.Message) ?[]const u8 {
    if (msg.param_count >= 2) {
        if (channelToken(msg.params[1])) |channel| return channel;
    }
    if (msg.param_count >= 1) return channelToken(msg.params[0]);
    return null;
}

fn channelToken(token: []const u8) ?[]const u8 {
    var value = token;
    if (value.len >= 2 and
        (value[0] == '=' or value[0] == '*' or value[0] == '@') and
        isChannelPrefix(value[1]))
        value = value[1..];
    return if (value.len > 0 and isChannelPrefix(value[0])) value else null;
}

fn isChannelPrefix(ch: u8) bool {
    return ch == '#' or ch == '&' or ch == '+' or ch == '!';
}

fn isNickStatus(ch: u8) bool {
    return ch == '~' or ch == '&' or ch == '@' or ch == '%' or ch == '+';
}

fn roleForPrefix(ch: u8) MemberRole {
    return switch (ch) {
        '~', '&' => .owner,
        '@' => .operator,
        '%' => .halfop,
        '+' => .voice,
        else => .member,
    };
}

fn modeBitForPrefix(ch: u8) u8 {
    return switch (ch) {
        '~' => modeBit('q'),
        '&' => modeBit('a'),
        '@' => modeBit('o'),
        '%' => modeBit('h'),
        '+' => modeBit('v'),
        else => 0,
    };
}

fn roleForMode(mode: u8) MemberRole {
    return switch (mode) {
        'q', 'a' => .owner,
        'o' => .operator,
        'h' => .halfop,
        'v' => .voice,
        else => .member,
    };
}

fn highestRole(a: MemberRole, b: MemberRole) MemberRole {
    return if (@intFromEnum(a) >= @intFromEnum(b)) a else b;
}

fn modeBit(mode: u8) u8 {
    return switch (mode) {
        'q' => 1 << 5,
        'a' => 1 << 4,
        'o' => 1 << 3,
        'h' => 1 << 2,
        'v' => 1 << 1,
        else => 0,
    };
}

fn highestRoleForModes(modes: u8) MemberRole {
    if (modes & (modeBit('q') | modeBit('a')) != 0) return .owner;
    if (modes & modeBit('o') != 0) return .operator;
    if (modes & modeBit('h') != 0) return .halfop;
    if (modes & modeBit('v') != 0) return .voice;
    return .member;
}

fn saturatingAdd(a: u32, b: u32) u32 {
    return if (std.math.maxInt(u32) - a < b) std.math.maxInt(u32) else a + b;
}

fn deinitLine(gpa: std.mem.Allocator, line: Line) void {
    gpa.free(line.nick);
    gpa.free(line.text);
    gpa.free(line.formatting);
    if (line.pose_text) |pose| gpa.free(pose);
    for (line.talk_targets) |target| gpa.free(target.nick);
    gpa.free(line.talk_targets);
}

test "avatarForNick is deterministic, case-insensitive, and always valid" {
    const a = avatarForNick("Bob");
    try std.testing.expectEqualStrings(a, avatarForNick("bob"));
    try std.testing.expectEqualStrings(a, avatarForNick("BOB"));
    var found = false;
    for (default_avatars) |av| {
        if (std.mem.eql(u8, av, a)) found = true;
    }
    try std.testing.expect(found);
}

test "avatar announcement parser is strict and canonicalizes bundled names" {
    try std.testing.expectEqualStrings(
        "anna",
        parseAvatarAnnouncement("# Appears as AnNa").avatar,
    );
    try std.testing.expectEqualStrings(
        "xeno",
        parseAvatarAnnouncement("# Appears as XENO.https://example.invalid/xeno.avb").avatar,
    );
    try std.testing.expectEqualStrings("Anna HD", parseAvatarAnnouncement("# Appears as Anna HD").avatar);
    try std.testing.expectEqualStrings("Xeno Color", parseAvatarAnnouncement("# Appears as Xeno Color").avatar);
    try std.testing.expectEqualStrings("Tiki Original", parseAvatarAnnouncement("# Appears as Tiki Original").avatar);
    try std.testing.expectEqualStrings("anna", parseAvatarAnnouncement("# Appears as Anna.").avatar);
    try std.testing.expectEqualStrings("anna color", parseAvatarAnnouncement("# Appears as AnnaColor.").avatar);
    try std.testing.expect(parseAvatarAnnouncement("# Appears as none") == .none);
    try std.testing.expect(parseAvatarAnnouncement("hello") == .not_control);
    try std.testing.expect(parseAvatarAnnouncement("# appears as anna") == .not_control);
    try std.testing.expect(parseAvatarAnnouncement("# Appears as ") == .invalid);
    try std.testing.expect(parseAvatarAnnouncement("# Appears as anna ") == .invalid);
    try std.testing.expect(parseAvatarAnnouncement("# Appears as unknown") == .invalid);
    try std.testing.expect(parseAvatarAnnouncement("# Appears as anna.bad\nurl") == .invalid);
}

test "transcript consumes announcements and resolves speakers and talk targets" {
    const gpa = std.testing.allocator;
    var transcript = Transcript.init(gpa);
    defer transcript.deinit();

    try transcript.add("Bob", "before announcement");
    const historical_avatar = transcript.lines.items[0].avatar;
    const announcement = if (std.mem.eql(u8, historical_avatar, "xeno"))
        "# Appears as ANNA"
    else
        "# Appears as XENO";
    const selected_avatar: []const u8 = if (std.mem.eql(u8, historical_avatar, "xeno")) "anna" else "xeno";
    var mutable_nick = [_]u8{ 'B', 'o', 'b' };
    try std.testing.expect(try transcript.consumeAvatarAnnouncement(&mutable_nick, announcement));
    @memset(&mutable_nick, 'x');
    try std.testing.expectEqual(@as(usize, 1), transcript.count());
    try std.testing.expectEqualStrings(historical_avatar, transcript.lines.items[0].avatar);
    try std.testing.expectEqualStrings(selected_avatar, transcript.resolvedAvatar("bob"));

    try transcript.add("BOB", "hello");
    try transcript.addWithOptions("Alice", "hi Bob", .{ .talk_target_nicks = &.{"bOb"} });
    try std.testing.expectEqualStrings(selected_avatar, transcript.lines.items[1].avatar);
    try std.testing.expectEqualStrings(selected_avatar, transcript.lines.items[2].talk_targets[0].avatar);

    try std.testing.expect(try transcript.consumeAvatarAnnouncement("Bob", "# Appears as unknown"));
    try std.testing.expectEqualStrings(selected_avatar, transcript.resolvedAvatar("bob"));
    try std.testing.expect(try transcript.consumeAvatarAnnouncement("Bob", "# Appears as NONE"));
    try std.testing.expectEqualStrings(avatarForNick("bob"), transcript.resolvedAvatar("bob"));
    try std.testing.expect(!(try transcript.consumeAvatarAnnouncement("Bob", "ordinary text")));
}

test "profile control parser matches source prefixes" {
    try std.testing.expect(parseProfileControl(" GetInfo") == .get_info);
    try std.testing.expect(parseProfileControl(" GetInfoNow") == .get_info); // strncmp prefix match
    try std.testing.expect(parseProfileControl(" GetCharInfo") == .get_char_info);
    try std.testing.expectEqualStrings("likes long walks", parseProfileControl(" HeresInfo: likes long walks").heres_info);
    try std.testing.expect(parseProfileControl(" HeresInfo: ") == .heres_info);
    try std.testing.expectEqualStrings("", parseProfileControl(" HeresInfo: ").heres_info);
    try std.testing.expect(parseProfileControl("ordinary text") == .not_control);
    try std.testing.expect(parseProfileControl(" Appears as anna") == .not_control);
}

test "backdrop control parser matches both wire forms and their quirks" {
    const sync = parseBackdropControl(" BDrop2: cave.bmp,https://example.invalid/cave.bmp").sync;
    try std.testing.expectEqualStrings("cave.bmp", sync.name);
    try std.testing.expectEqualStrings("cave", sync.base_name);
    try std.testing.expectEqualStrings("https://example.invalid/cave.bmp", sync.url.?);

    const no_url = parseBackdropControl(" BDrop2: cave.bmp,").sync;
    try std.testing.expectEqualStrings("cave.bmp", no_url.name);
    try std.testing.expect(no_url.url == null);

    const no_dot = parseBackdropControl(" BDrop2: cave").sync;
    try std.testing.expectEqualStrings("cave", no_dot.name);
    try std.testing.expectEqualStrings("cave", no_dot.base_name);
    try std.testing.expect(no_dot.url == null);

    try std.testing.expect(parseBackdropControl(" BDrop2: ") == .empty);
    // GetToken's begin/end separator sets are identical (protsupp.cpp:317-320),
    // so a leading comma is itself skipped as a delimiter rather than
    // producing an empty name field.
    try std.testing.expectEqualStrings("url", parseBackdropControl(" BDrop2: ,url").sync.name);

    // Real senders double the space here (BACKGRNDPREFIX already ends in
    // one, and protsupp.cpp:3447's format string adds another); the
    // receiver skips all whitespace after the prefix regardless.
    try std.testing.expectEqualStrings("cave", parseBackdropControl(" BDrop:  cave").legacy);
    try std.testing.expectEqualStrings("cave", parseBackdropControl(" BDrop: cave").legacy);
    try std.testing.expect(parseBackdropControl(" BDrop: ") == .empty);
    try std.testing.expect(parseBackdropControl(" BDrop:    ") == .empty);

    try std.testing.expect(parseBackdropControl("ordinary text") == .not_control);
}

test "nickFromPrefix strips user@host and leading colon" {
    try std.testing.expectEqualStrings("anna", nickFromPrefix(":anna!u@h"));
    try std.testing.expectEqualStrings("bob", nickFromPrefix("bob!user@host"));
    try std.testing.expectEqualStrings("srv", nickFromPrefix("srv"));
}

test "live roster follows NAMES membership speech and current avatars" {
    const gpa = std.testing.allocator;
    var transcript = Transcript.init(gpa);
    defer transcript.deinit();

    try transcript.setSelf("Me");
    var names = irc_message.parse(":server 353 Me = #room :@Me +Alice %Bob");
    try std.testing.expect(try transcript.observeIrc(&names, "#room", "Me"));
    try std.testing.expectEqual(@as(usize, 3), transcript.roster.items.len);
    try std.testing.expectEqual(@as(usize, 3), transcript.activeMemberCount());
    try std.testing.expect(transcript.roster.items[transcript.findRosterIndex("me").?].is_self);
    try std.testing.expectEqual(MemberRole.operator, transcript.roster.items[transcript.findRosterIndex("me").?].role);
    try std.testing.expectEqual(MemberRole.voice, transcript.roster.items[transcript.findRosterIndex("Alice").?].role);
    try std.testing.expectEqual(MemberRole.halfop, transcript.roster.items[transcript.findRosterIndex("Bob").?].role);
    try std.testing.expect(transcript.findRosterIndex("@Me") == null);
    try std.testing.expect(transcript.findRosterIndex("+Alice") == null);

    var promote = irc_message.parse(":server MODE #room +ov Alice Bob");
    try std.testing.expect(try transcript.observeIrc(&promote, "#room", "Me"));
    try std.testing.expectEqual(MemberRole.operator, transcript.roster.items[transcript.findRosterIndex("Alice").?].role);
    try std.testing.expectEqual(MemberRole.halfop, transcript.roster.items[transcript.findRosterIndex("Bob").?].role);
    var demote = irc_message.parse(":server MODE #room -o Alice");
    try std.testing.expect(try transcript.observeIrc(&demote, "#room", "Me"));
    try std.testing.expectEqual(MemberRole.voice, transcript.roster.items[transcript.findRosterIndex("Alice").?].role);

    var elevated = irc_message.parse(":server MODE #room +qa Alice Alice");
    try std.testing.expect(try transcript.observeIrc(&elevated, "#room", "Me"));
    try std.testing.expectEqual(MemberRole.owner, transcript.roster.items[transcript.findRosterIndex("Alice").?].role);
    var remove_founder = irc_message.parse(":server MODE #room -q Alice");
    try std.testing.expect(try transcript.observeIrc(&remove_founder, "#room", "Me"));
    try std.testing.expectEqual(MemberRole.owner, transcript.roster.items[transcript.findRosterIndex("Alice").?].role);
    var remove_admin = irc_message.parse(":server MODE #room -a Alice");
    try std.testing.expect(try transcript.observeIrc(&remove_admin, "#room", "Me"));
    try std.testing.expectEqual(MemberRole.voice, transcript.roster.items[transcript.findRosterIndex("Alice").?].role);

    const first_avatar = transcript.resolvedAvatar("Alice");
    try transcript.add("Alice", "before");
    const replacement: []const u8 = if (std.mem.eql(u8, first_avatar, "anna")) "xeno" else "anna";
    var announcement_buf: [64]u8 = undefined;
    const announcement = try std.fmt.bufPrint(
        &announcement_buf,
        "# Appears as {s}",
        .{replacement},
    );
    try std.testing.expect(try transcript.consumeAvatarAnnouncement("Alice", announcement));
    try transcript.add("Alice", "after");
    try transcript.add("Bob", "<Brk>");
    try std.testing.expectEqualStrings(first_avatar, transcript.lines.items[0].avatar);
    try std.testing.expectEqualStrings(replacement, transcript.lines.items[1].avatar);
    try std.testing.expectEqual(@as(u32, 2), transcript.roster.items[transcript.findRosterIndex("Alice").?].sends);
    try std.testing.expectEqual(@as(u32, 0), transcript.roster.items[transcript.findRosterIndex("Bob").?].sends);

    var part = irc_message.parse(":Bob!u@h PART #room :later");
    try std.testing.expect(try transcript.observeIrc(&part, "#room", "Me"));
    try std.testing.expect(transcript.roster.items[transcript.findRosterIndex("Bob").?].departed);
    try std.testing.expectEqual(@as(usize, 2), transcript.activeMemberCount());

    var rename = irc_message.parse(":Alice!u@h NICK :Alicia");
    try std.testing.expect(try transcript.observeIrc(&rename, "#room", "Me"));
    try std.testing.expect(transcript.findRosterIndex("Alice") == null);
    const alicia = transcript.roster.items[transcript.findRosterIndex("Alicia").?];
    try std.testing.expectEqualStrings(replacement, alicia.avatar);
    try std.testing.expectEqual(@as(u32, 2), alicia.sends);

    var quit = irc_message.parse(":Alicia!u@h QUIT :gone");
    try std.testing.expect(try transcript.observeIrc(&quit, "#room", "Me"));
    try std.testing.expect(transcript.roster.items[transcript.findRosterIndex("Alicia").?].departed);
    try std.testing.expectEqual(@as(usize, 1), transcript.activeMemberCount());
    var join = irc_message.parse(":Alicia!u@h JOIN :#room");
    try std.testing.expect(try transcript.observeIrc(&join, "#room", "Me"));
    try std.testing.expect(!transcript.roster.items[transcript.findRosterIndex("Alicia").?].departed);
    try std.testing.expectEqual(@as(usize, 2), transcript.activeMemberCount());

    var kick = irc_message.parse(":op!u@h KICK #room Alicia :out");
    try std.testing.expect(try transcript.observeIrc(&kick, "#room", "Me"));
    try std.testing.expect(transcript.roster.items[transcript.findRosterIndex("Alicia").?].departed);
    try std.testing.expectEqual(@as(usize, 1), transcript.activeMemberCount());

    var rejoin = irc_message.parse(":Alicia!u@h JOIN :#room");
    try std.testing.expect(try transcript.observeIrc(&rejoin, "#room", "Me"));
    var ban_then_op = irc_message.parse(":op!u@h MODE #room +bo bad!*@* Alicia");
    try std.testing.expect(try transcript.observeIrc(&ban_then_op, "#room", "Me"));
    try std.testing.expectEqual(MemberRole.operator, transcript.roster.items[transcript.findRosterIndex("Alicia").?].role);
    var empty_kick = irc_message.parse(":op!u@h KICK #room Alicia");
    try std.testing.expect(try transcript.observeIrc(&empty_kick, "#room", "Me"));
    try std.testing.expect(transcript.roster.items[transcript.findRosterIndex("Alicia").?].departed);
}

test "NAMES 366 retires members missing from the snapshot" {
    const gpa = std.testing.allocator;
    var transcript = Transcript.init(gpa);
    defer transcript.deinit();

    try transcript.setSelf("Me");
    var first = irc_message.parse(":server 353 Me = #room :@Me +Alice Bob");
    try std.testing.expect(try transcript.observeIrc(&first, "#room", "Me"));
    var end_first = irc_message.parse(":server 366 Me #room :End of /NAMES list");
    try std.testing.expect(!try transcript.observeIrc(&end_first, "#room", "Me"));
    try std.testing.expectEqual(@as(usize, 3), transcript.activeMemberCount());

    var reconnect = irc_message.parse(":server 353 Me = #room :@Me +Alice");
    _ = try transcript.observeIrc(&reconnect, "#room", "Me");
    var end_reconnect = irc_message.parse(":server 366 Me #room :End of /NAMES list");
    try std.testing.expect(try transcript.observeIrc(&end_reconnect, "#room", "Me"));
    try std.testing.expect(transcript.roster.items[transcript.findRosterIndex("Bob").?].departed);
    try std.testing.expect(!transcript.roster.items[transcript.findRosterIndex("Alice").?].departed);
    try std.testing.expectEqual(@as(usize, 2), transcript.activeMemberCount());
}

test "353 does not clear away and accepts compact channel tokens" {
    const gpa = std.testing.allocator;
    var transcript = Transcript.init(gpa);
    defer transcript.deinit();

    try transcript.setSelf("Me");
    try std.testing.expect(try transcript.consumeAwayControl("Alice", "\x01AWAY coffee\x01"));
    var compact = irc_message.parse(":server 353 Me =#room :@Me +Alice");
    try std.testing.expect(try transcript.observeIrc(&compact, "#room", "Me"));
    try std.testing.expect(transcript.roster.items[transcript.findRosterIndex("Alice").?].away);

    var three_param = irc_message.parse(":server 353 Me #room :@Me +Alice Carol");
    try std.testing.expect(try transcript.observeIrc(&three_param, "#room", "Me"));
    try std.testing.expect(transcript.roster.items[transcript.findRosterIndex("Alice").?].away);
    try std.testing.expect(transcript.findRosterIndex("Carol") != null);
}

test "nick collision merge keeps an active member present" {
    const gpa = std.testing.allocator;
    var transcript = Transcript.init(gpa);
    defer transcript.deinit();

    try transcript.setSelf("Me");
    var names = irc_message.parse(":server 353 Me = #room :Me Old Alice");
    try std.testing.expect(try transcript.observeIrc(&names, "#room", "Me"));
    try std.testing.expect(try transcript.setAway("Alice", true));
    var part = irc_message.parse(":Old!u@h PART #room");
    try std.testing.expect(try transcript.observeIrc(&part, "#room", "Me"));
    try std.testing.expect(transcript.roster.items[transcript.findRosterIndex("Old").?].departed);
    var rename = irc_message.parse(":Old!u@h NICK :Alice");
    try std.testing.expect(try transcript.observeIrc(&rename, "#room", "Me"));
    try std.testing.expect(transcript.findRosterIndex("Old") == null);
    try std.testing.expect(!transcript.roster.items[transcript.findRosterIndex("Alice").?].departed);
    try std.testing.expect(transcript.roster.items[transcript.findRosterIndex("Alice").?].away);
}

test "page break insertion and selected line removal preserve ownership and tallies" {
    var transcript = Transcript.init(std.testing.allocator);
    defer transcript.deinit();
    try transcript.add("Alice", "one");
    try transcript.add("Bob", "two");
    try transcript.insertPageBreak("Me", 1);
    try std.testing.expectEqual(@as(usize, 3), transcript.lines.items.len);
    try std.testing.expectEqualStrings("<Brk>", transcript.lines.items[1].text);
    try std.testing.expectEqual(@as(u32, 0), transcript.roster.items[transcript.findRosterIndex("Me").?].sends);
    try std.testing.expect(transcript.removeLine(0));
    try std.testing.expectEqual(@as(u32, 0), transcript.roster.items[transcript.findRosterIndex("Alice").?].sends);
    try std.testing.expect(!transcript.removeLine(99));
}

test "transcript owns its copies" {
    const gpa = std.testing.allocator;
    var t = Transcript.init(gpa);
    defer t.deinit();
    var buf: [16]u8 = undefined;
    @memcpy(buf[0..5], "hello");
    try t.add("zoe", buf[0..5]);
    @memset(buf[0..5], 'x'); // mutate the source; transcript must be unaffected
    try std.testing.expectEqual(@as(usize, 1), t.count());
    try std.testing.expectEqualStrings("hello", t.lines.items[0].text);
    try std.testing.expect(t.lines.items[0].avatar.len > 0);
}

test "transcript trimTo retains newest lines and releases old ownership" {
    const gpa = std.testing.allocator;
    var t = Transcript.init(gpa);
    defer t.deinit();
    try t.add("a", "one");
    try t.add("b", "two");
    try t.add("c", "three");
    t.trimTo(2);
    try std.testing.expectEqual(@as(usize, 2), t.count());
    try std.testing.expectEqualStrings("two", t.lines.items[0].text);
    try std.testing.expectEqualStrings("three", t.lines.items[1].text);
    t.trimTo(0);
    try std.testing.expectEqual(@as(usize, 0), t.count());
}

test "transcript owns reaction pose and explicit talk target identities" {
    const gpa = std.testing.allocator;
    var t = Transcript.init(gpa);
    defer t.deinit();
    const targets = [_][]const u8{ "Bob", "Carol" };
    try t.addWithOptions("Alice", "<Chr>", .{
        .pose_text = "happy",
        .talk_target_nicks = &targets,
    });
    try std.testing.expectEqualStrings("Alice", t.lines.items[0].nick);
    try std.testing.expectEqualStrings("happy", t.lines.items[0].pose_text.?);
    try std.testing.expect(t.lines.items[0].pose_state == null);
    try std.testing.expectEqual(@as(usize, 2), t.lines.items[0].talk_targets.len);
    try std.testing.expectEqualStrings("Bob", t.lines.items[0].talk_targets[0].nick);
    try std.testing.expectEqual(original_page.bm_say, t.lines.items[0].modes);
    try std.testing.expectEqualStrings(
        avatarForNick("Bob"),
        t.lines.items[0].talk_targets[0].avatar,
    );
}

test "transcript decodes embedded and pending source UDI" {
    const gpa = std.testing.allocator;
    var transcript = Transcript.init(gpa);
    defer transcript.deinit();

    try transcript.addWireMessage("Alice", "(#G000E000M3TBob,Carol) thinking", false, null);
    try std.testing.expectEqualStrings("thinking", transcript.lines.items[0].text);
    try std.testing.expectEqual(original_page.bm_think, transcript.lines.items[0].modes);
    try std.testing.expectEqual(udi.PoseState{
        .gesture = .{ .index = 0, .emotion = 0, .intensity = 0 },
        .expression = .{ .index = 0, .emotion = 0, .intensity = 0 },
        .requested = false,
    }, transcript.lines.items[0].pose_state.?);
    try std.testing.expectEqual(@as(usize, 2), transcript.lines.items[0].talk_targets.len);
    try std.testing.expectEqualStrings("Bob", transcript.lines.items[0].talk_targets[0].nick);

    try transcript.addWireMessage("Bob", "quiet", false, "#G000E000M2TAlice");
    try std.testing.expectEqualStrings("quiet", transcript.lines.items[1].text);
    try std.testing.expectEqual(original_page.bm_whisper, transcript.lines.items[1].modes);
    try std.testing.expect(transcript.lines.items[1].pose_state != null);
    try std.testing.expectEqualStrings("Alice", transcript.lines.items[1].talk_targets[0].nick);

    try transcript.addWireMessage("Carol", "(#broken) shown", false, null);
    try std.testing.expectEqualStrings("(#broken) shown", transcript.lines.items[2].text);
    try std.testing.expectEqual(original_page.bm_say, transcript.lines.items[2].modes);
    try std.testing.expect(transcript.lines.items[2].pose_state == null);
}

test "transcript strips formatting after UDI and owns clean text plus offsets" {
    const gpa = std.testing.allocator;
    var transcript = Transcript.init(gpa);
    defer transcript.deinit();

    var wire = [_]u8{ '(', '#', 'G', '0', '0', '0', 'E', '0', '0', '0', 'M', '1', ')', ' ', 'A', 0x16, 'B', 0x16, 'C' };
    try transcript.addWireMessage("Alice", &wire, false, null);
    @memset(&wire, 'x');

    const line = transcript.lines.items[0];
    try std.testing.expectEqualStrings("ABC", line.text);
    try std.testing.expectEqualSlices(formatting.Change, &.{
        .{ .offset = 1, .format = formatting.effect.italic },
        .{ .offset = 2, .format = 0 },
    }, line.formatting);
    try std.testing.expect(line.pose_state != null);
}

test "source action preparation prefixes the speaker for comic and CTCP forms" {
    const gpa = std.testing.allocator;
    var transcript = Transcript.init(gpa);
    defer transcript.deinit();

    try transcript.addWireMessage(
        "Alice",
        "(#G000E000M5) \x01ACTION \x16waves\x16\x01",
        false,
        null,
    );
    const line = transcript.lines.items[0];
    try std.testing.expectEqualStrings("Alice waves", line.text);
    try std.testing.expectEqual(original_page.bm_action, line.modes);
    try std.testing.expectEqualSlices(formatting.Change, &.{
        .{ .offset = 6, .format = formatting.effect.italic },
    }, line.formatting);

    try transcript.addWireMessage("Bob", "\x01ACTION shrugs\x01", true, null);
    try std.testing.expectEqualStrings("Bob shrugs", transcript.lines.items[1].text);
    try std.testing.expectEqual(
        original_page.bm_action | original_page.bm_whisper,
        transcript.lines.items[1].modes,
    );

    try transcript.addWireMessage("Cro", "waves", false, "#G000E000M5");
    try std.testing.expectEqualStrings("Cro waves", transcript.lines.items[2].text);
    try std.testing.expectEqual(original_page.bm_action, transcript.lines.items[2].modes);

    try transcript.addWireMessage("Dan", "psst", true, "#G000E000M5");
    try std.testing.expectEqualStrings("Dan psst", transcript.lines.items[3].text);
    try std.testing.expectEqual(
        original_page.bm_action | original_page.bm_whisper,
        transcript.lines.items[3].modes,
    );
}

test "source SOUND control becomes an action box with sender and filename" {
    const gpa = std.testing.allocator;
    var transcript = Transcript.init(gpa);
    defer transcript.deinit();

    try transcript.addWireMessage("Alice", "\x01SOUND Chime hello there\x01", false, null);
    try std.testing.expectEqualStrings("Alice hello there (Chime)", transcript.lines.items[0].text);
    try std.testing.expectEqual(original_page.bm_action, transcript.lines.items[0].modes);

    try transcript.addWireMessage("Bob", "\x01SOUND Knock \x01", true, null);
    try std.testing.expectEqualStrings("Bob (Knock)", transcript.lines.items[1].text);
    try std.testing.expectEqual(original_page.bm_action | original_page.bm_whisper, transcript.lines.items[1].modes);

    try transcript.addWireMessage("Cro", "\x01SOUND Door\x10@bell.wav come in\x01", false, null);
    try std.testing.expectEqualStrings("Cro come in (Door bell.wav)", transcript.lines.items[2].text);

    try transcript.addWireMessage("Dan", "\x01sound chime quietly\x01", false, null);
    try std.testing.expectEqualStrings("Dan quietly (chime)", transcript.lines.items[3].text);
    try transcript.addWireMessage("Eve", "\x01action waves\x01", false, null);
    try std.testing.expectEqualStrings("Eve waves", transcript.lines.items[4].text);
    try std.testing.expectEqual(original_page.bm_action, transcript.lines.items[4].modes);
}

test "legacy BDrop matching the last BDrop2 base does not replace the backdrop" {
    var transcript = Transcript.init(std.testing.allocator);
    defer transcript.deinit();

    try std.testing.expect(try transcript.applyBackdropControl(parseBackdropControl(" BDrop2: Volcano.bgb,")));
    try std.testing.expectEqualStrings("volcano", transcript.resolvedBackdrop());
    try std.testing.expect(try transcript.applyBackdropControl(parseBackdropControl(" BDrop:  Volcano")));
    try std.testing.expectEqualStrings("volcano", transcript.resolvedBackdrop());
    try std.testing.expect(try transcript.applyBackdropControl(parseBackdropControl(" BDrop:  room")));
    try std.testing.expectEqualStrings("room", transcript.resolvedBackdrop());
}

test "source AWAY control updates roster without adding a comic line" {
    var transcript = Transcript.init(std.testing.allocator);
    defer transcript.deinit();

    try std.testing.expect(try transcript.consumeAwayControl("Alice", "\x01AWAY getting coffee\x01"));
    const alice = transcript.findRosterIndex("Alice").?;
    try std.testing.expect(transcript.roster.items[alice].away);
    try std.testing.expectEqual(@as(usize, 0), transcript.lines.items.len);

    try std.testing.expect(try transcript.consumeAwayControl("Alice", "\x01AWAY\x01"));
    try std.testing.expect(!transcript.roster.items[alice].away);

    var away_notify = irc_message.parse(":Alice!u@h AWAY :afk");
    try std.testing.expect(try transcript.observeIrc(&away_notify, "#room", "Me"));
    try std.testing.expect(transcript.roster.items[alice].away);
    var back = irc_message.parse(":Alice!u@h AWAY");
    try std.testing.expect(try transcript.observeIrc(&back, "#room", "Me"));
    try std.testing.expect(!transcript.roster.items[alice].away);

    var rpl_away = irc_message.parse(":server 301 Me Bob :gone fishing");
    try std.testing.expect(try transcript.observeIrc(&rpl_away, "#room", "Me"));
    const bob = transcript.findRosterIndex("Bob").?;
    try std.testing.expect(transcript.roster.items[bob].away);

    var kill = irc_message.parse(":oper!u@h KILL Bob :banned");
    try std.testing.expect(try transcript.observeIrc(&kill, "#room", "Me"));
    try std.testing.expect(transcript.roster.items[bob].departed);
    try std.testing.expect(!try transcript.consumeAwayControl("Alice", "ordinary text"));
}
