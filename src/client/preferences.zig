//! Persistent portable application preferences.
//!
//! Microsoft Comic Chat stored these values in the Windows Registry.  The
//! portable client keeps the same ownership in one bounded, human-inspectable
//! file. Values are percent escaped, so untrusted profile/rule text can never
//! inject another record or escape its field.

const std = @import("std");
const files = @import("files.zig");

pub const max_preferences_bytes: usize = 256 * 1024;
pub const max_rules: usize = 64;
pub const max_notifications: usize = 128;
pub const max_recent_files: usize = 16;
pub const max_favorite_rooms: usize = 32;
pub const max_rule_sets: usize = 32;

pub const Rule = struct {
    name: []u8,
    event: []u8,
    filter: []u8,
    action: []u8,
    value: []u8,
    set_name: []u8,
    enabled: bool,
    case_sensitive: bool,
    maximum_occurrences: u16,
    interval_s: u16,

    fn deinit(self: *Rule, gpa: std.mem.Allocator) void {
        gpa.free(self.name);
        gpa.free(self.event);
        gpa.free(self.filter);
        gpa.free(self.action);
        gpa.free(self.value);
        gpa.free(self.set_name);
    }
};

pub const Notification = struct {
    nickname: []u8,
    user_mask: []u8,
    host_mask: []u8,
    network: []u8,
    enabled: bool,

    fn deinit(self: *Notification, gpa: std.mem.Allocator) void {
        gpa.free(self.nickname);
        gpa.free(self.user_mask);
        gpa.free(self.host_mask);
        gpa.free(self.network);
    }
};

pub const Store = struct {
    gpa: std.mem.Allocator,
    profile: std.ArrayList(u8) = .empty,
    display_name: std.ArrayList(u8) = .empty,
    homepage: std.ArrayList(u8) = .empty,
    email: std.ArrayList(u8) = .empty,
    backdrop: std.ArrayList(u8) = .empty,
    greeting_mode: std.ArrayList(u8) = .empty,
    greeting: std.ArrayList(u8) = .empty,
    auto_ignore_count: u16 = 8,
    auto_ignore_interval_s: u16 = 10,
    rules: std.ArrayList(Rule) = .empty,
    notifications: std.ArrayList(Notification) = .empty,
    notification_delivery: std.ArrayList(u8) = .empty,
    text_font: std.ArrayList(u8) = .empty,
    text_style: std.ArrayList(u8) = .empty,
    text_color: std.ArrayList(u8) = .empty,
    ui_text_mode: bool = false,
    ui_comic_columns: u8 = 4,
    ui_members_visible: bool = true,
    ui_member_list: bool = false,
    ui_dark_mode: bool = false,
    ui_accent: u8 = 0,
    ui_high_contrast: bool = false,
    ui_status_detailed: bool = true,
    recent_files: std.ArrayList([]u8) = .empty,
    favorite_rooms: std.ArrayList([]u8) = .empty,
    rule_sets: std.ArrayList([]u8) = .empty,
    /// SASL authentication identity only. The password stays in the file
    /// named by `sasl_password_file` and is never written here.
    sasl_user: std.ArrayList(u8) = .empty,
    sasl_password_file: std.ArrayList(u8) = .empty,
    server_host: std.ArrayList(u8) = .empty,
    server_port: u16 = 0,
    server_tls: bool = true,

    pub fn init(gpa: std.mem.Allocator) Store {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Store) void {
        self.profile.deinit(self.gpa);
        self.display_name.deinit(self.gpa);
        self.homepage.deinit(self.gpa);
        self.email.deinit(self.gpa);
        self.backdrop.deinit(self.gpa);
        self.greeting_mode.deinit(self.gpa);
        self.greeting.deinit(self.gpa);
        for (self.rules.items) |*rule| rule.deinit(self.gpa);
        self.rules.deinit(self.gpa);
        for (self.notifications.items) |*notification| notification.deinit(self.gpa);
        self.notifications.deinit(self.gpa);
        self.notification_delivery.deinit(self.gpa);
        self.text_font.deinit(self.gpa);
        self.text_style.deinit(self.gpa);
        self.text_color.deinit(self.gpa);
        deinitStrings(self.gpa, &self.recent_files);
        deinitStrings(self.gpa, &self.favorite_rooms);
        deinitStrings(self.gpa, &self.rule_sets);
        self.sasl_user.deinit(self.gpa);
        self.sasl_password_file.deinit(self.gpa);
        self.server_host.deinit(self.gpa);
        self.* = undefined;
    }

    pub fn loadFile(gpa: std.mem.Allocator, io: std.Io, path: []const u8) !Store {
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(max_preferences_bytes)) catch |err| switch (err) {
            error.FileNotFound => return init(gpa),
            else => return err,
        };
        defer gpa.free(bytes);
        return parse(gpa, bytes);
    }

    pub fn saveFile(self: *const Store, io: std.Io, path: []const u8) !void {
        const bytes = try self.encode();
        defer self.gpa.free(bytes);
        try files.saveBytesAtomic(io, self.gpa, path, bytes);
    }

    pub fn profileText(self: *const Store) []const u8 {
        return if (self.profile.items.len == 0)
            "This person is too lazy to create a profile entry."
        else
            self.profile.items;
    }

    pub fn backdropName(self: *const Store) []const u8 {
        return if (self.backdrop.items.len == 0) "color apartment" else self.backdrop.items;
    }

    pub fn greetingMode(self: *const Store) []const u8 {
        return if (self.greeting_mode.items.len == 0) "None" else self.greeting_mode.items;
    }

    pub fn notificationDelivery(self: *const Store) []const u8 {
        return if (self.notification_delivery.items.len == 0) "In-app banner" else self.notification_delivery.items;
    }

    pub fn textFont(self: *const Store) []const u8 {
        return if (self.text_font.items.len == 0) "Comic Neue 16" else self.text_font.items;
    }

    pub fn textStyle(self: *const Store) []const u8 {
        return if (self.text_style.items.len == 0) "Regular" else self.text_style.items;
    }

    pub fn textColor(self: *const Store) []const u8 {
        return if (self.text_color.items.len == 0) "#172033" else self.text_color.items;
    }

    pub fn setProfile(self: *Store, profile: []const u8, display_name: []const u8, homepage: []const u8, email: []const u8) !void {
        try replace(&self.profile, self.gpa, profile);
        try replace(&self.display_name, self.gpa, display_name);
        try replace(&self.homepage, self.gpa, homepage);
        try replace(&self.email, self.gpa, email);
    }

    pub fn setBackdrop(self: *Store, value: []const u8) !void {
        try replace(&self.backdrop, self.gpa, value);
    }

    pub fn setAutomation(self: *Store, mode: []const u8, greeting: []const u8, count: u16, interval_s: u16) !void {
        try replace(&self.greeting_mode, self.gpa, mode);
        try replace(&self.greeting, self.gpa, greeting);
        self.auto_ignore_count = count;
        self.auto_ignore_interval_s = interval_s;
    }

    pub fn setNotificationDelivery(self: *Store, value: []const u8) !void {
        try replace(&self.notification_delivery, self.gpa, value);
    }

    pub fn setSaslAuth(self: *Store, user: []const u8, password_file: []const u8) !void {
        try replace(&self.sasl_user, self.gpa, user);
        try replace(&self.sasl_password_file, self.gpa, password_file);
    }

    pub fn setServerProfile(self: *Store, host: []const u8, port: u16, tls: bool) !void {
        try replace(&self.server_host, self.gpa, host);
        self.server_port = port;
        self.server_tls = tls;
    }

    pub fn setTextAppearance(self: *Store, font: []const u8, style: []const u8, color: []const u8) !void {
        if (!validHexColor(color)) return error.InvalidColor;
        try replace(&self.text_font, self.gpa, font);
        try replace(&self.text_style, self.gpa, style);
        try replace(&self.text_color, self.gpa, color);
    }

    pub fn setUiLayout(self: *Store, text_mode: bool, comic_columns: u8, members_visible: bool, member_list: bool) void {
        self.ui_text_mode = text_mode;
        self.ui_comic_columns = std.math.clamp(comic_columns, 1, 6);
        self.ui_members_visible = members_visible;
        self.ui_member_list = member_list;
    }

    pub fn setUiTheme(self: *Store, dark_mode: bool, accent: u8, high_contrast: bool, status_detailed: bool) void {
        self.ui_dark_mode = dark_mode;
        self.ui_accent = @min(accent, 2);
        self.ui_high_contrast = high_contrast;
        self.ui_status_detailed = status_detailed;
    }

    pub fn rememberFile(self: *Store, path: []const u8) !void {
        try rememberBounded(self.gpa, &self.recent_files, path, max_recent_files);
    }

    pub fn removeRecentFile(self: *Store, path: []const u8) bool {
        return removeString(self.gpa, &self.recent_files, path);
    }

    pub fn addFavoriteRoom(self: *Store, room: []const u8) !void {
        if (room.len < 2 or (room[0] != '#' and room[0] != '&') or std.mem.indexOfAny(u8, room, " ,\r\n\x00") != null)
            return error.InvalidRoomName;
        try rememberBounded(self.gpa, &self.favorite_rooms, room, max_favorite_rooms);
    }

    pub fn removeFavoriteRoom(self: *Store, room: []const u8) bool {
        return removeString(self.gpa, &self.favorite_rooms, room);
    }

    pub fn addRuleSet(self: *Store, name: []const u8) !void {
        if (std.mem.trim(u8, name, " \t").len == 0) return error.InvalidRuleSetName;
        try rememberBounded(self.gpa, &self.rule_sets, name, max_rule_sets);
    }

    pub fn renameRuleSet(self: *Store, old_name: []const u8, new_name: []const u8) !void {
        if (std.mem.trim(u8, new_name, " \t").len == 0) return error.InvalidRuleSetName;
        for (self.rule_sets.items) |*entry| {
            if (!std.ascii.eqlIgnoreCase(entry.*, old_name)) continue;
            const replacement = try self.gpa.dupe(u8, new_name);
            self.gpa.free(entry.*);
            entry.* = replacement;
            return;
        }
        return error.RuleSetNotFound;
    }

    pub fn upsertRule(self: *Store, input: struct {
        name: []const u8,
        event: []const u8,
        filter: []const u8,
        action: []const u8,
        value: []const u8,
        set_name: []const u8 = "",
        enabled: bool = true,
        case_sensitive: bool = false,
        maximum_occurrences: u16 = 0,
        interval_s: u16 = 0,
    }) !void {
        for (self.rules.items) |*rule| if (std.ascii.eqlIgnoreCase(rule.name, input.name)) {
            const replacement = try cloneRule(self.gpa, input);
            rule.deinit(self.gpa);
            rule.* = replacement;
            return;
        };
        if (self.rules.items.len >= max_rules) return error.TooManyRules;
        var rule = try cloneRule(self.gpa, input);
        errdefer rule.deinit(self.gpa);
        try self.rules.append(self.gpa, rule);
    }

    pub fn assignRuleSet(self: *Store, rule_name: []const u8, set_name: []const u8) !void {
        var found_set = set_name.len == 0;
        for (self.rule_sets.items) |entry| if (std.ascii.eqlIgnoreCase(entry, set_name)) {
            found_set = true;
            break;
        };
        if (!found_set) return error.RuleSetNotFound;
        for (self.rules.items) |*rule| {
            if (!std.ascii.eqlIgnoreCase(rule.name, rule_name)) continue;
            const replacement = try self.gpa.dupe(u8, set_name);
            self.gpa.free(rule.set_name);
            rule.set_name = replacement;
            return;
        }
        return error.RuleNotFound;
    }

    pub fn configureRule(self: *Store, rule_name: []const u8, case_sensitive: bool, maximum_occurrences: u16, interval_s: u16) !void {
        for (self.rules.items) |*rule| {
            if (!std.ascii.eqlIgnoreCase(rule.name, rule_name)) continue;
            rule.case_sensitive = case_sensitive;
            rule.maximum_occurrences = maximum_occurrences;
            rule.interval_s = interval_s;
            return;
        }
        return error.RuleNotFound;
    }

    pub fn exportRulesFile(self: *const Store, io: std.Io, path: []const u8, selected_set: ?[]const u8) !void {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(self.gpa);
        try out.appendSlice(self.gpa, "COMICCHAT-RULES 1\n");
        if (selected_set) |name| try appendRecord(&out, self.gpa, "rule_set", name);
        for (self.rules.items) |rule| {
            if (selected_set) |name| if (!std.ascii.eqlIgnoreCase(rule.set_name, name)) continue;
            var maximum: [16]u8 = undefined;
            var interval: [16]u8 = undefined;
            try appendComposite(&out, self.gpa, "rule", &.{
                rule.name,
                rule.event,
                rule.filter,
                rule.action,
                rule.value,
                rule.set_name,
                if (rule.enabled) "1" else "0",
                if (rule.case_sensitive) "1" else "0",
                try std.fmt.bufPrint(&maximum, "{d}", .{rule.maximum_occurrences}),
                try std.fmt.bufPrint(&interval, "{d}", .{rule.interval_s}),
            });
        }
        try files.saveBytesAtomic(io, self.gpa, path, out.items);
    }

    pub fn importRulesFile(self: *Store, io: std.Io, path: []const u8) !void {
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, self.gpa, .limited(max_preferences_bytes));
        defer self.gpa.free(bytes);
        var lines = std.mem.splitScalar(u8, bytes, '\n');
        if (!std.mem.eql(u8, std.mem.trimEnd(u8, lines.next() orelse "", "\r"), "COMICCHAT-RULES 1"))
            return error.InvalidRulesHeader;
        while (lines.next()) |raw| {
            const line = std.mem.trimEnd(u8, raw, "\r");
            const equals = std.mem.indexOfScalar(u8, line, '=') orelse continue;
            const key = line[0..equals];
            if (std.mem.eql(u8, key, "rule_set")) {
                const name = try decode(self.gpa, line[equals + 1 ..]);
                defer self.gpa.free(name);
                try self.addRuleSet(name);
            } else if (std.mem.eql(u8, key, "rule")) {
                const parts = try decodeComposite(self.gpa, line[equals + 1 ..], 10);
                defer freeParts(self.gpa, parts);
                if (parts.len != 10) return error.InvalidRule;
                if (parts[5].len != 0) try self.addRuleSet(parts[5]);
                try self.upsertRule(.{
                    .name = parts[0],
                    .event = parts[1],
                    .filter = parts[2],
                    .action = parts[3],
                    .value = parts[4],
                    .set_name = parts[5],
                    .enabled = std.mem.eql(u8, parts[6], "1"),
                    .case_sensitive = std.mem.eql(u8, parts[7], "1"),
                    .maximum_occurrences = std.fmt.parseInt(u16, parts[8], 10) catch return error.InvalidRule,
                    .interval_s = std.fmt.parseInt(u16, parts[9], 10) catch return error.InvalidRule,
                });
            }
        }
    }

    pub fn upsertNotification(self: *Store, input: struct {
        nickname: []const u8,
        user_mask: []const u8,
        host_mask: []const u8,
        network: []const u8,
        enabled: bool = true,
    }) !void {
        for (self.notifications.items) |*notification| if (std.ascii.eqlIgnoreCase(notification.nickname, input.nickname)) {
            const replacement = try cloneNotification(self.gpa, input);
            notification.deinit(self.gpa);
            notification.* = replacement;
            return;
        };
        if (self.notifications.items.len >= max_notifications) return error.TooManyNotifications;
        var notification = try cloneNotification(self.gpa, input);
        errdefer notification.deinit(self.gpa);
        try self.notifications.append(self.gpa, notification);
    }

    fn encode(self: *const Store) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(self.gpa);
        try out.appendSlice(self.gpa, "COMICCHAT-PREFERENCES 1\n");
        try appendRecord(&out, self.gpa, "profile", self.profile.items);
        try appendRecord(&out, self.gpa, "display_name", self.display_name.items);
        try appendRecord(&out, self.gpa, "homepage", self.homepage.items);
        try appendRecord(&out, self.gpa, "email", self.email.items);
        try appendRecord(&out, self.gpa, "backdrop", self.backdropName());
        try appendRecord(&out, self.gpa, "greeting_mode", self.greetingMode());
        try appendRecord(&out, self.gpa, "greeting", self.greeting.items);
        var number: [16]u8 = undefined;
        try appendRecord(&out, self.gpa, "auto_ignore_count", try std.fmt.bufPrint(&number, "{d}", .{self.auto_ignore_count}));
        try appendRecord(&out, self.gpa, "auto_ignore_interval", try std.fmt.bufPrint(&number, "{d}", .{self.auto_ignore_interval_s}));
        try appendRecord(&out, self.gpa, "notification_delivery", self.notificationDelivery());
        try appendRecord(&out, self.gpa, "text_font", self.textFont());
        try appendRecord(&out, self.gpa, "text_style", self.textStyle());
        try appendRecord(&out, self.gpa, "text_color", self.textColor());
        try appendRecord(&out, self.gpa, "ui_text_mode", if (self.ui_text_mode) "1" else "0");
        try appendRecord(&out, self.gpa, "ui_comic_columns", try std.fmt.bufPrint(&number, "{d}", .{self.ui_comic_columns}));
        try appendRecord(&out, self.gpa, "ui_members_visible", if (self.ui_members_visible) "1" else "0");
        try appendRecord(&out, self.gpa, "ui_member_list", if (self.ui_member_list) "1" else "0");
        try appendRecord(&out, self.gpa, "ui_dark_mode", if (self.ui_dark_mode) "1" else "0");
        try appendRecord(&out, self.gpa, "ui_accent", try std.fmt.bufPrint(&number, "{d}", .{self.ui_accent}));
        try appendRecord(&out, self.gpa, "ui_high_contrast", if (self.ui_high_contrast) "1" else "0");
        try appendRecord(&out, self.gpa, "ui_status_detailed", if (self.ui_status_detailed) "1" else "0");
        if (self.sasl_user.items.len != 0) try appendRecord(&out, self.gpa, "sasl_user", self.sasl_user.items);
        if (self.sasl_password_file.items.len != 0) try appendRecord(&out, self.gpa, "sasl_password_file", self.sasl_password_file.items);
        if (self.server_host.items.len != 0) try appendRecord(&out, self.gpa, "server_host", self.server_host.items);
        if (self.server_port != 0) try appendRecord(&out, self.gpa, "server_port", try std.fmt.bufPrint(&number, "{d}", .{self.server_port}));
        try appendRecord(&out, self.gpa, "server_tls", if (self.server_tls) "1" else "0");
        for (self.recent_files.items) |path| try appendRecord(&out, self.gpa, "recent_file", path);
        for (self.favorite_rooms.items) |room| try appendRecord(&out, self.gpa, "favorite_room", room);
        for (self.rule_sets.items) |name| try appendRecord(&out, self.gpa, "rule_set", name);
        for (self.rules.items) |rule| {
            var maximum: [16]u8 = undefined;
            var interval: [16]u8 = undefined;
            try appendComposite(&out, self.gpa, "rule", &.{
                rule.name,
                rule.event,
                rule.filter,
                rule.action,
                rule.value,
                rule.set_name,
                if (rule.enabled) "1" else "0",
                if (rule.case_sensitive) "1" else "0",
                try std.fmt.bufPrint(&maximum, "{d}", .{rule.maximum_occurrences}),
                try std.fmt.bufPrint(&interval, "{d}", .{rule.interval_s}),
            });
        }
        for (self.notifications.items) |notification| try appendComposite(&out, self.gpa, "notification", &.{ notification.nickname, notification.user_mask, notification.host_mask, notification.network, if (notification.enabled) "1" else "0" });
        if (out.items.len > max_preferences_bytes) return error.PreferencesTooLarge;
        return out.toOwnedSlice(self.gpa);
    }
};

pub fn parse(gpa: std.mem.Allocator, bytes: []const u8) !Store {
    if (bytes.len > max_preferences_bytes) return error.PreferencesTooLarge;
    var store = Store.init(gpa);
    errdefer store.deinit();
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    const header = std.mem.trimEnd(u8, lines.next() orelse "", "\r");
    if (!std.mem.eql(u8, header, "COMICCHAT-PREFERENCES 1")) return error.InvalidPreferencesHeader;
    while (lines.next()) |raw_line| {
        const line = std.mem.trimEnd(u8, raw_line, "\r");
        if (line.len == 0) continue;
        const equals = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = line[0..equals];
        const value = line[equals + 1 ..];
        if (std.mem.eql(u8, key, "rule")) {
            const parts = try decodeComposite(gpa, value, 10);
            defer freeParts(gpa, parts);
            if (parts.len == 6) {
                try store.upsertRule(.{ .name = parts[0], .event = parts[1], .filter = parts[2], .action = parts[3], .value = parts[4], .enabled = std.mem.eql(u8, parts[5], "1") });
            } else if (parts.len == 10) {
                try store.upsertRule(.{
                    .name = parts[0],
                    .event = parts[1],
                    .filter = parts[2],
                    .action = parts[3],
                    .value = parts[4],
                    .set_name = parts[5],
                    .enabled = std.mem.eql(u8, parts[6], "1"),
                    .case_sensitive = std.mem.eql(u8, parts[7], "1"),
                    .maximum_occurrences = std.fmt.parseInt(u16, parts[8], 10) catch 0,
                    .interval_s = std.fmt.parseInt(u16, parts[9], 10) catch 0,
                });
            }
            continue;
        }
        if (std.mem.eql(u8, key, "notification")) {
            const parts = try decodeComposite(gpa, value, 5);
            defer freeParts(gpa, parts);
            if (parts.len == 5) try store.upsertNotification(.{ .nickname = parts[0], .user_mask = parts[1], .host_mask = parts[2], .network = parts[3], .enabled = std.mem.eql(u8, parts[4], "1") });
            continue;
        }
        const decoded = try decode(gpa, value);
        defer gpa.free(decoded);
        if (std.mem.eql(u8, key, "profile")) try replace(&store.profile, gpa, decoded) else if (std.mem.eql(u8, key, "display_name")) try replace(&store.display_name, gpa, decoded) else if (std.mem.eql(u8, key, "homepage")) try replace(&store.homepage, gpa, decoded) else if (std.mem.eql(u8, key, "email")) try replace(&store.email, gpa, decoded) else if (std.mem.eql(u8, key, "backdrop")) try store.setBackdrop(decoded) else if (std.mem.eql(u8, key, "greeting_mode")) try replace(&store.greeting_mode, gpa, decoded) else if (std.mem.eql(u8, key, "greeting")) try replace(&store.greeting, gpa, decoded) else if (std.mem.eql(u8, key, "auto_ignore_count")) store.auto_ignore_count = std.fmt.parseInt(u16, decoded, 10) catch store.auto_ignore_count else if (std.mem.eql(u8, key, "auto_ignore_interval")) store.auto_ignore_interval_s = std.fmt.parseInt(u16, decoded, 10) catch store.auto_ignore_interval_s else if (std.mem.eql(u8, key, "notification_delivery")) try replace(&store.notification_delivery, gpa, decoded) else if (std.mem.eql(u8, key, "text_font")) try replace(&store.text_font, gpa, decoded) else if (std.mem.eql(u8, key, "text_style")) try replace(&store.text_style, gpa, decoded) else if (std.mem.eql(u8, key, "text_color")) {
            if (validHexColor(decoded)) try replace(&store.text_color, gpa, decoded);
        } else if (std.mem.eql(u8, key, "ui_text_mode")) store.ui_text_mode = std.mem.eql(u8, decoded, "1") else if (std.mem.eql(u8, key, "ui_comic_columns")) store.ui_comic_columns = std.math.clamp(std.fmt.parseInt(u8, decoded, 10) catch 4, 1, 6) else if (std.mem.eql(u8, key, "ui_members_visible")) store.ui_members_visible = std.mem.eql(u8, decoded, "1") else if (std.mem.eql(u8, key, "ui_member_list")) store.ui_member_list = std.mem.eql(u8, decoded, "1") else if (std.mem.eql(u8, key, "ui_dark_mode")) store.ui_dark_mode = std.mem.eql(u8, decoded, "1") else if (std.mem.eql(u8, key, "ui_accent")) store.ui_accent = @min(std.fmt.parseInt(u8, decoded, 10) catch 0, 2) else if (std.mem.eql(u8, key, "ui_high_contrast")) store.ui_high_contrast = std.mem.eql(u8, decoded, "1") else if (std.mem.eql(u8, key, "ui_status_detailed")) store.ui_status_detailed = std.mem.eql(u8, decoded, "1") else if (std.mem.eql(u8, key, "sasl_user")) try replace(&store.sasl_user, gpa, decoded) else if (std.mem.eql(u8, key, "sasl_password_file")) try replace(&store.sasl_password_file, gpa, decoded) else if (std.mem.eql(u8, key, "server_host")) try replace(&store.server_host, gpa, decoded) else if (std.mem.eql(u8, key, "server_port")) store.server_port = std.fmt.parseInt(u16, decoded, 10) catch 0 else if (std.mem.eql(u8, key, "server_tls")) store.server_tls = !std.mem.eql(u8, decoded, "0") else if (std.mem.eql(u8, key, "recent_file")) try rememberBounded(gpa, &store.recent_files, decoded, max_recent_files) else if (std.mem.eql(u8, key, "favorite_room")) try store.addFavoriteRoom(decoded) else if (std.mem.eql(u8, key, "rule_set")) try store.addRuleSet(decoded);
    }
    return store;
}

fn replace(list: *std.ArrayList(u8), gpa: std.mem.Allocator, value: []const u8) !void {
    if (value.len > 4096) return error.ValueTooLong;
    list.clearRetainingCapacity();
    try list.appendSlice(gpa, value);
}

fn validHexColor(value: []const u8) bool {
    if (value.len != 7 or value[0] != '#') return false;
    for (value[1..]) |byte| _ = std.fmt.charToDigit(byte, 16) catch return false;
    return true;
}

fn rememberBounded(gpa: std.mem.Allocator, list: *std.ArrayList([]u8), value: []const u8, maximum: usize) !void {
    if (value.len == 0 or value.len > 4096 or std.mem.indexOfAny(u8, value, "\r\n\x00") != null) return error.InvalidValue;
    var existing: ?usize = null;
    for (list.items, 0..) |entry, index| if (std.ascii.eqlIgnoreCase(entry, value)) {
        existing = index;
        break;
    };
    if (existing) |index| {
        const owned = list.orderedRemove(index);
        try list.insert(gpa, 0, owned);
        return;
    }
    const owned = try gpa.dupe(u8, value);
    errdefer gpa.free(owned);
    try list.insert(gpa, 0, owned);
    if (list.items.len > maximum) gpa.free(list.pop().?);
}

fn deinitStrings(gpa: std.mem.Allocator, list: *std.ArrayList([]u8)) void {
    for (list.items) |item| gpa.free(item);
    list.deinit(gpa);
}

fn removeString(gpa: std.mem.Allocator, list: *std.ArrayList([]u8), value: []const u8) bool {
    for (list.items, 0..) |entry, index| {
        if (!std.ascii.eqlIgnoreCase(entry, value)) continue;
        gpa.free(entry);
        _ = list.orderedRemove(index);
        return true;
    }
    return false;
}

fn cloneRule(gpa: std.mem.Allocator, input: anytype) !Rule {
    const name = try gpa.dupe(u8, input.name);
    errdefer gpa.free(name);
    const event = try gpa.dupe(u8, input.event);
    errdefer gpa.free(event);
    const filter = try gpa.dupe(u8, input.filter);
    errdefer gpa.free(filter);
    const action = try gpa.dupe(u8, input.action);
    errdefer gpa.free(action);
    const value = try gpa.dupe(u8, input.value);
    errdefer gpa.free(value);
    const set_name = try gpa.dupe(u8, input.set_name);
    return .{
        .name = name,
        .event = event,
        .filter = filter,
        .action = action,
        .value = value,
        .set_name = set_name,
        .enabled = input.enabled,
        .case_sensitive = input.case_sensitive,
        .maximum_occurrences = input.maximum_occurrences,
        .interval_s = input.interval_s,
    };
}

fn cloneNotification(gpa: std.mem.Allocator, input: anytype) !Notification {
    const nickname = try gpa.dupe(u8, input.nickname);
    errdefer gpa.free(nickname);
    const user_mask = try gpa.dupe(u8, input.user_mask);
    errdefer gpa.free(user_mask);
    const host_mask = try gpa.dupe(u8, input.host_mask);
    errdefer gpa.free(host_mask);
    const network = try gpa.dupe(u8, input.network);
    return .{ .nickname = nickname, .user_mask = user_mask, .host_mask = host_mask, .network = network, .enabled = input.enabled };
}

fn appendRecord(out: *std.ArrayList(u8), gpa: std.mem.Allocator, key: []const u8, value: []const u8) !void {
    try out.appendSlice(gpa, key);
    try out.append(gpa, '=');
    try appendEscaped(out, gpa, value);
    try out.append(gpa, '\n');
}

fn appendComposite(out: *std.ArrayList(u8), gpa: std.mem.Allocator, key: []const u8, fields: []const []const u8) !void {
    try out.appendSlice(gpa, key);
    try out.append(gpa, '=');
    for (fields, 0..) |field, index| {
        if (index != 0) try out.append(gpa, '\t');
        try appendEscaped(out, gpa, field);
    }
    try out.append(gpa, '\n');
}

fn appendEscaped(out: *std.ArrayList(u8), gpa: std.mem.Allocator, value: []const u8) !void {
    const hex = "0123456789ABCDEF";
    for (value) |byte| {
        if (std.ascii.isAlphanumeric(byte) or std.mem.indexOfScalar(u8, " .,_-:/#*!?@+", byte) != null) {
            try out.append(gpa, byte);
        } else {
            try out.appendSlice(gpa, &.{ '%', hex[byte >> 4], hex[byte & 0x0f] });
        }
    }
}

fn decode(gpa: std.mem.Allocator, value: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var index: usize = 0;
    while (index < value.len) {
        if (value[index] == '%' and index + 2 < value.len) {
            const hi = std.fmt.charToDigit(value[index + 1], 16) catch return error.InvalidEscape;
            const lo = std.fmt.charToDigit(value[index + 2], 16) catch return error.InvalidEscape;
            try out.append(gpa, @intCast(hi * 16 + lo));
            index += 3;
        } else {
            try out.append(gpa, value[index]);
            index += 1;
        }
    }
    return out.toOwnedSlice(gpa);
}

fn decodeComposite(gpa: std.mem.Allocator, value: []const u8, max_fields: usize) ![][]u8 {
    var out: std.ArrayList([]u8) = .empty;
    errdefer {
        for (out.items) |part| gpa.free(part);
        out.deinit(gpa);
    }
    var parts = std.mem.splitScalar(u8, value, '\t');
    while (parts.next()) |part| {
        if (out.items.len >= max_fields) return error.TooManyFields;
        try out.append(gpa, try decode(gpa, part));
    }
    return out.toOwnedSlice(gpa);
}

fn freeParts(gpa: std.mem.Allocator, parts: [][]u8) void {
    for (parts) |part| gpa.free(part);
    gpa.free(parts);
}

test "preferences round-trip profile rules notifications and escaped text" {
    const gpa = std.testing.allocator;
    var source = Store.init(gpa);
    defer source.deinit();
    try source.setProfile("hello\nworld", "Comic User", "https://example.test", "");
    try source.setBackdrop("den");
    try source.setAutomation("Whisper", "Welcome, %nick%!", 5, 12);
    try source.setNotificationDelivery("In-app banner");
    try source.setTextAppearance("Comic Neue 18", "Italic", "#334455");
    source.setUiLayout(true, 6, false, true);
    source.setUiTheme(true, 2, true, false);
    try source.rememberFile("saved/example.ccc");
    try source.addFavoriteRoom("#comic-art");
    try source.addRuleSet("Quiet hours");
    try source.upsertRule(.{ .name = "Hello", .event = "Message", .filter = "ping|pong", .action = "Reply", .value = "hello\nthere", .set_name = "Quiet hours", .case_sensitive = true, .maximum_occurrences = 3, .interval_s = 60 });
    try source.upsertNotification(.{ .nickname = "Anna", .user_mask = "*", .host_mask = "*.test", .network = "eshmaki.me" });
    try source.setSaslAuth("alex", ".comicchat-sasl");
    try source.setServerProfile("eshmaki.me", 6697, true);
    const encoded = try source.encode();
    defer gpa.free(encoded);
    try std.testing.expect(std.mem.indexOfScalar(u8, encoded, '\r') == null);
    var decoded = try parse(gpa, encoded);
    defer decoded.deinit();
    try std.testing.expectEqualStrings("hello\nworld", decoded.profile.items);
    try std.testing.expectEqualStrings("ping|pong", decoded.rules.items[0].filter);
    try std.testing.expectEqualStrings("*.test", decoded.notifications.items[0].host_mask);
    try std.testing.expectEqual(@as(u16, 12), decoded.auto_ignore_interval_s);
    try std.testing.expectEqualStrings("Comic Neue 18", decoded.textFont());
    try std.testing.expectEqualStrings("#334455", decoded.textColor());
    try std.testing.expect(decoded.ui_text_mode);
    try std.testing.expectEqual(@as(u8, 6), decoded.ui_comic_columns);
    try std.testing.expect(!decoded.ui_members_visible);
    try std.testing.expect(decoded.ui_member_list);
    try std.testing.expect(decoded.ui_dark_mode);
    try std.testing.expectEqual(@as(u8, 2), decoded.ui_accent);
    try std.testing.expect(decoded.ui_high_contrast);
    try std.testing.expect(!decoded.ui_status_detailed);
    try std.testing.expectEqualStrings("saved/example.ccc", decoded.recent_files.items[0]);
    try std.testing.expectEqualStrings("#comic-art", decoded.favorite_rooms.items[0]);
    try std.testing.expectEqualStrings("Quiet hours", decoded.rule_sets.items[0]);
    try std.testing.expectEqualStrings("Quiet hours", decoded.rules.items[0].set_name);
    try std.testing.expectEqualStrings("alex", decoded.sasl_user.items);
    try std.testing.expectEqualStrings(".comicchat-sasl", decoded.sasl_password_file.items);
    try std.testing.expectEqualStrings("eshmaki.me", decoded.server_host.items);
    try std.testing.expectEqual(@as(u16, 6697), decoded.server_port);
    try std.testing.expect(decoded.server_tls);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "secret") == null);
    try std.testing.expect(decoded.rules.items[0].case_sensitive);
    try std.testing.expectEqual(@as(u16, 3), decoded.rules.items[0].maximum_occurrences);
}

test "recent files are deduplicated and bounded newest first" {
    var store = Store.init(std.testing.allocator);
    defer store.deinit();
    var buffer: [64]u8 = undefined;
    for (0..max_recent_files + 3) |index| try store.rememberFile(try std.fmt.bufPrint(&buffer, "file-{d}.ccc", .{index}));
    try std.testing.expectEqual(max_recent_files, store.recent_files.items.len);
    try store.rememberFile("file-5.ccc");
    try std.testing.expectEqualStrings("file-5.ccc", store.recent_files.items[0]);
}

test "rule files round trip advanced settings and set membership" {
    var source = Store.init(std.testing.allocator);
    defer source.deinit();
    try source.addRuleSet("Moderation");
    try source.upsertRule(.{ .name = "Flood", .event = "Message", .filter = "buy now", .action = "Ignore", .value = "", .set_name = "Moderation", .case_sensitive = true, .maximum_occurrences = 2, .interval_s = 30 });

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    try out.appendSlice(std.testing.allocator, "COMICCHAT-RULES 1\n");
    try appendRecord(&out, std.testing.allocator, "rule_set", "Moderation");
    const rule = source.rules.items[0];
    try appendComposite(&out, std.testing.allocator, "rule", &.{ rule.name, rule.event, rule.filter, rule.action, rule.value, rule.set_name, "1", "1", "2", "30" });

    var imported = Store.init(std.testing.allocator);
    defer imported.deinit();
    var lines = std.mem.splitScalar(u8, out.items, '\n');
    try std.testing.expectEqualStrings("COMICCHAT-RULES 1", lines.next().?);
    const set_line = lines.next().?;
    const set_name = try decode(std.testing.allocator, set_line["rule_set=".len..]);
    defer std.testing.allocator.free(set_name);
    try imported.addRuleSet(set_name);
    const rule_line = lines.next().?;
    const parts = try decodeComposite(std.testing.allocator, rule_line["rule=".len..], 10);
    defer freeParts(std.testing.allocator, parts);
    try imported.upsertRule(.{ .name = parts[0], .event = parts[1], .filter = parts[2], .action = parts[3], .value = parts[4], .set_name = parts[5], .case_sensitive = true, .maximum_occurrences = 2, .interval_s = 30 });
    try std.testing.expectEqualStrings("Moderation", imported.rules.items[0].set_name);
}
