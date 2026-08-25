//! Onyx Server reusable-session credential parsing and persistence.

const std = @import("std");
const builtin = @import("builtin");
const message = @import("message.zig");

pub const header = "# comicchat-session-v1\n";
pub const max_credential_length: usize = 4 * 1024;
pub const max_store_bytes: usize = 16 * 1024;

pub const Kind = enum { local, mesh, sasl };

pub const Credential = struct {
    kind: Kind,
    token: []const u8,
    expires_at: ?u64 = null,
};

pub fn validCredential(token: []const u8) bool {
    return token.len != 0 and token.len <= max_credential_length and
        std.mem.indexOfAny(u8, token, " \t\r\n\x00\x0b\x0c\x7f") == null;
}

pub fn parseCredential(msg: message.Message) ?Credential {
    const prefix = msg.prefix orelse return null;
    if (std.mem.indexOfAny(u8, prefix, "!@") != null) return null;
    if (std.ascii.eqlIgnoreCase(msg.command, "NOTICE")) {
        const body = msg.param(msg.param_count -| 1) orelse return null;
        return parseBody(body) orelse parseSaslBody(body);
    }
    if (!std.ascii.eqlIgnoreCase(msg.command, "NOTE") or msg.param_count < 3 or
        !std.ascii.eqlIgnoreCase(msg.param(0) orelse return null, "SESSION")) return null;
    const kind = parseKind(msg.param(1) orelse return null) orelse return null;
    const token = msg.param(2) orelse return null;
    if (!validCredential(token)) return null;
    var expires_at: ?u64 = null;
    var index: usize = 3;
    while (index < msg.param_count) : (index += 1) {
        const field = msg.params[index];
        const eq = std.mem.indexOfScalar(u8, field, '=') orelse return null;
        if (eq == 0 or eq + 1 == field.len) return null;
        if (std.ascii.eqlIgnoreCase(field[0..eq], "expires")) {
            if (expires_at != null or field.len - eq - 1 > 16) return null;
            expires_at = std.fmt.parseInt(u64, field[eq + 1 ..], 10) catch return null;
        }
    }
    return .{ .kind = kind, .token = token, .expires_at = expires_at };
}

fn parseBody(raw: []const u8) ?Credential {
    var fields = std.mem.tokenizeAny(u8, raw, " \t");
    if (!std.ascii.eqlIgnoreCase(fields.next() orelse return null, "SESSION")) return null;
    const kind = parseKind(fields.next() orelse return null) orelse return null;
    const token = fields.next() orelse return null;
    if (!validCredential(token)) return null;
    var expires_at: ?u64 = null;
    while (fields.next()) |field| {
        const eq = std.mem.indexOfScalar(u8, field, '=') orelse return null;
        if (eq == 0 or eq + 1 == field.len) return null;
        if (std.ascii.eqlIgnoreCase(field[0..eq], "expires")) {
            if (expires_at != null or field.len - eq - 1 > 16) return null;
            expires_at = std.fmt.parseInt(u64, field[eq + 1 ..], 10) catch return null;
        }
    }
    return .{ .kind = kind, .token = token, .expires_at = expires_at };
}

fn parseSaslBody(raw: []const u8) ?Credential {
    var fields = std.mem.tokenizeAny(u8, raw, " \t");
    if (!std.ascii.eqlIgnoreCase(fields.next() orelse return null, "SESSIONTOKEN")) return null;
    _ = fields.next() orelse return null; // account
    const token = fields.next() orelse return null;
    if (!validCredential(token)) return null;
    var expires_at: ?u64 = null;
    while (fields.next()) |field| {
        const eq = std.mem.indexOfScalar(u8, field, '=') orelse return null;
        if (eq == 0 or eq + 1 == field.len) return null;
        if (std.ascii.eqlIgnoreCase(field[0..eq], "expires")) {
            if (expires_at != null or field.len - eq - 1 > 16) return null;
            expires_at = std.fmt.parseInt(u64, field[eq + 1 ..], 10) catch return null;
        }
    }
    return .{ .kind = .sasl, .token = token, .expires_at = expires_at };
}

fn parseKind(raw: []const u8) ?Kind {
    if (std.ascii.eqlIgnoreCase(raw, "TOKEN")) return .local;
    if (std.ascii.eqlIgnoreCase(raw, "MTOKEN")) return .mesh;
    if (std.ascii.eqlIgnoreCase(raw, "SASL")) return .sasl;
    return null;
}

pub const Store = struct {
    gpa: std.mem.Allocator,
    host: []u8,
    account: []u8,
    local: ?[]u8 = null,
    mesh: ?[]u8 = null,
    mesh_expires_at: ?u64 = null,
    sasl: ?[]u8 = null,
    sasl_expires_at: ?u64 = null,
    dirty: bool = false,

    pub fn init(gpa: std.mem.Allocator, host: []const u8, account: []const u8) !Store {
        const owned_host = try lowerDup(gpa, host);
        errdefer gpa.free(owned_host);
        const owned_account = try lowerDup(gpa, account);
        return .{ .gpa = gpa, .host = owned_host, .account = owned_account };
    }

    pub fn deinit(self: *Store) void {
        self.clearToken(&self.local);
        self.clearToken(&self.mesh);
        self.clearToken(&self.sasl);
        self.gpa.free(self.host);
        self.gpa.free(self.account);
        self.* = undefined;
    }

    pub fn loadFile(gpa: std.mem.Allocator, io: std.Io, path: []const u8, host: []const u8, account: []const u8) !Store {
        var store = try Store.init(gpa, host, account);
        errdefer store.deinit();
        const data = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(max_store_bytes)) catch |err| switch (err) {
            error.FileNotFound => return store,
            else => return err,
        };
        defer gpa.free(data);
        var lines = std.mem.splitScalar(u8, data, '\n');
        if (!std.mem.eql(u8, lines.next() orelse return error.InvalidSessionStore, std.mem.trimEnd(u8, header, "\n")))
            return error.InvalidSessionStore;
        const identity = std.mem.trim(u8, lines.next() orelse return error.InvalidSessionStore, "\r");
        var identity_fields = std.mem.splitScalar(u8, identity, '\t');
        const stored_host = identity_fields.next() orelse return error.InvalidSessionStore;
        const stored_account = identity_fields.next() orelse return error.InvalidSessionStore;
        if (identity_fields.next() != null) return error.InvalidSessionStore;
        if (!std.ascii.eqlIgnoreCase(stored_host, host) or !std.ascii.eqlIgnoreCase(stored_account, account)) return store;
        while (lines.next()) |raw_line| {
            const line = std.mem.trim(u8, raw_line, "\r");
            if (line.len == 0) continue;
            var fields = std.mem.splitScalar(u8, line, '\t');
            const kind = parseKind(fields.next() orelse return error.InvalidSessionStore) orelse return error.InvalidSessionStore;
            const token = fields.next() orelse return error.InvalidSessionStore;
            const expiry = fields.next();
            if (fields.next() != null or !validCredential(token)) return error.InvalidSessionStore;
            const parsed_expiry = if (expiry) |value| if (value.len == 0) null else std.fmt.parseInt(u64, value, 10) catch return error.InvalidSessionStore else null;
            try store.replace(kind, token, parsed_expiry);
        }
        store.dirty = false;
        return store;
    }

    pub fn observe(self: *Store, msg: message.Message) !bool {
        const credential = parseCredential(msg) orelse return false;
        try self.replace(credential.kind, credential.token, credential.expires_at);
        return true;
    }

    pub fn resumeToken(self: *Store, now_seconds: u64) ?[]const u8 {
        if (self.mesh) |token| {
            if (self.mesh_expires_at == null or self.mesh_expires_at.? > now_seconds) return token;
            self.clearToken(&self.mesh);
            self.mesh_expires_at = null;
            self.dirty = true;
        }
        return self.local;
    }

    pub fn saveFile(self: *Store, io: std.Io, path: []const u8) !void {
        if (!self.dirty) return;
        var bytes: std.ArrayList(u8) = .empty;
        defer bytes.deinit(self.gpa);
        try bytes.appendSlice(self.gpa, header);
        try bytes.print(self.gpa, "{s}\t{s}\n", .{ self.host, self.account });
        if (self.local) |token| try bytes.print(self.gpa, "TOKEN\t{s}\t\n", .{token});
        if (self.mesh) |token| {
            if (self.mesh_expires_at) |expiry|
                try bytes.print(self.gpa, "MTOKEN\t{s}\t{d}\n", .{ token, expiry })
            else
                try bytes.print(self.gpa, "MTOKEN\t{s}\t\n", .{token});
        }
        if (self.sasl) |token| {
            if (self.sasl_expires_at) |expiry|
                try bytes.print(self.gpa, "SASL\t{s}\t{d}\n", .{ token, expiry })
            else
                try bytes.print(self.gpa, "SASL\t{s}\t\n", .{token});
        }
        const temporary = try std.fmt.allocPrint(self.gpa, "{s}.tmp", .{path});
        defer self.gpa.free(temporary);
        const cwd = std.Io.Dir.cwd();
        try cwd.writeFile(io, .{
            .sub_path = temporary,
            .data = bytes.items,
            .flags = .{ .permissions = if (builtin.os.tag == .windows)
                .default_file
            else
                .fromMode(0o600) },
        });
        try cwd.rename(temporary, cwd, path, io);
        self.dirty = false;
    }

    fn replace(self: *Store, kind: Kind, token: []const u8, expires_at: ?u64) !void {
        if (!validCredential(token)) return error.InvalidSessionCredential;
        const owned = try self.gpa.dupe(u8, token);
        switch (kind) {
            .local => {
                self.clearToken(&self.local);
                self.local = owned;
            },
            .mesh => {
                self.clearToken(&self.mesh);
                self.mesh = owned;
                self.mesh_expires_at = expires_at;
            },
            .sasl => {
                self.clearToken(&self.sasl);
                self.sasl = owned;
                self.sasl_expires_at = expires_at;
            },
        }
        self.dirty = true;
    }

    fn clearToken(self: *Store, slot: *?[]u8) void {
        if (slot.*) |token| {
            std.crypto.secureZero(u8, token);
            self.gpa.free(token);
            slot.* = null;
        }
    }
};

fn lowerDup(gpa: std.mem.Allocator, value: []const u8) ![]u8 {
    const result = try gpa.alloc(u8, value.len);
    for (value, result) |source, *dest| dest.* = std.ascii.toLower(source);
    return result;
}

test "session credentials parse current notices and reject injection" {
    const local = parseCredential(message.parse(":server.example NOTICE alex :SESSION TOKEN abc123")).?;
    try std.testing.expectEqual(Kind.local, local.kind);
    try std.testing.expectEqualStrings("abc123", local.token);
    const mesh = parseCredential(message.parse(":server.example NOTICE alex :SESSION MTOKEN deadbeef expires=1800000000")).?;
    try std.testing.expectEqual(Kind.mesh, mesh.kind);
    try std.testing.expectEqual(@as(?u64, 1800000000), mesh.expires_at);
    try std.testing.expect(parseCredential(message.parse(":srv NOTICE alex :SESSION TOKEN bad extra")) == null);
    try std.testing.expect(parseCredential(message.parse(":mallory!u@host NOTICE alex :SESSION TOKEN stolen")) == null);
    const note = parseCredential(message.parse(":server.example NOTE SESSION MTOKEN meshcred expires=1800000000")).?;
    try std.testing.expectEqual(Kind.mesh, note.kind);
    try std.testing.expectEqualStrings("meshcred", note.token);
    try std.testing.expectEqual(@as(?u64, 1800000000), note.expires_at);
    const sasl = parseCredential(message.parse(":server.example NOTICE alex :SESSIONTOKEN alice sst_0123456789abcdef0123456789abcdef expires=1800000000")).?;
    try std.testing.expectEqual(Kind.sasl, sasl.kind);
    try std.testing.expectEqualStrings("sst_0123456789abcdef0123456789abcdef", sasl.token);
}

test "session store prefers live mesh token and falls back to local" {
    var store = try Store.init(std.testing.allocator, "SERVER.EXAMPLE", "Alex");
    defer store.deinit();
    try std.testing.expect(try store.observe(message.parse(":srv NOTICE alex :SESSION TOKEN local")));
    try std.testing.expect(try store.observe(message.parse(":srv NOTICE alex :SESSION MTOKEN mesh expires=200")));
    try std.testing.expectEqualStrings("mesh", store.resumeToken(199).?);
    try std.testing.expectEqualStrings("local", store.resumeToken(200).?);
}
