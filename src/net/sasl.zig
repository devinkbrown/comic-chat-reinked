//! Pure IRCv3.1/3.2 SASL client state machine.
//!
//! Pinned protocol reference: `ircv3-specifications` commit
//! `5eca32ce8cbc0c8f9d123529ef221d8da9516b65`,
//! `extensions/sasl-3.1.md` and `extensions/sasl-3.2.md`.
//! SCRAM-SHA-256 follows RFC 5802 and the RFC 7677 SHA-256 profile.
//!
//! This module owns no socket and emits wire commands into a caller-owned
//! buffer. Credentials remain in caller-owned mutable slices and are securely
//! zeroed when the exchange reaches a terminal state or `Session.deinit` runs.
//! The caller must transmit and then `secureClear` the output buffer because a
//! PLAIN response necessarily contains a reversible Base64 credential tuple.

const std = @import("std");
const message = @import("message.zig");

const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
const Sha256 = std.crypto.hash.sha2.Sha256;
const b64_encoder = std.base64.standard.Encoder;
const b64_decoder = std.base64.standard.Decoder;

pub const authenticate_chunk_size: usize = 400;
pub const max_encoded_challenge: usize = 64 * 1024;
pub const min_scram_iterations: u32 = 4096;
pub const max_scram_iterations: u32 = 1_000_000;

pub const Error = std.mem.Allocator.Error || error{
    InvalidState,
    InvalidAuthenticateChunk,
    ChallengeTooLong,
    InvalidBase64,
    InvalidIdentity,
    InvalidNonce,
    InvalidScramMessage,
    InvalidScramIterations,
    ServerSignatureMismatch,
    NoSupportedMechanism,
    OutputTooLong,
};

pub const Mechanism = enum(u2) {
    scram_sha_256,
    external,
    plain,

    pub fn wireName(self: Mechanism) []const u8 {
        return switch (self) {
            .scram_sha_256 => "SCRAM-SHA-256",
            .external => "EXTERNAL",
            .plain => "PLAIN",
        };
    }

    pub fn parse(raw: []const u8) ?Mechanism {
        inline for (std.enums.values(Mechanism)) |candidate| {
            if (std.ascii.eqlIgnoreCase(raw, candidate.wireName())) return candidate;
        }
        return null;
    }
};

pub const default_preference = [_]Mechanism{ .scram_sha_256, .external, .plain };

/// Mutable storage is supplied and remains owned by the caller. `Session`
/// borrows these slices and wipes all three on success, terminal failure, or
/// deinitialization; it never frees them.
pub const Credentials = struct {
    authorization_identity: []u8,
    authentication_identity: []u8,
    password: []u8,
    external_available: bool = false,
    zeroized: bool = false,

    pub fn zeroize(self: *Credentials) void {
        std.crypto.secureZero(u8, self.authorization_identity);
        std.crypto.secureZero(u8, self.authentication_identity);
        std.crypto.secureZero(u8, self.password);
        self.zeroized = true;
    }
};

pub const Config = struct {
    preference: []const Mechanism = &default_preference,
};

pub const Phase = enum {
    idle,
    awaiting_initial,
    awaiting_server_first,
    awaiting_server_final,
    awaiting_result,
    awaiting_abort,
    complete,
    failed,
};

pub const Event = enum {
    none,
    started,
    response_sent,
    retrying,
    mechanisms_updated,
    logged_in,
    logged_out,
    succeeded,
    failed,
    already_authenticated,
};

const MechanismSet = struct {
    bits: u8 = 0,

    fn insert(self: *MechanismSet, mechanism: Mechanism) void {
        self.bits |= @as(u8, 1) << @intFromEnum(mechanism);
    }

    fn contains(self: MechanismSet, mechanism: Mechanism) bool {
        return self.bits & (@as(u8, 1) << @intFromEnum(mechanism)) != 0;
    }
};

pub const Session = struct {
    gpa: std.mem.Allocator,
    credentials: *Credentials,
    config: Config,
    phase: Phase = .idle,
    selected: ?Mechanism = null,
    attempted: MechanismSet = .{},
    advertised: MechanismSet = .{},
    advertisement_known: bool = false,
    incoming: std.ArrayList(u8) = .empty,
    client_nonce: []const u8 = "",
    gs2_header: std.ArrayList(u8) = .empty,
    client_first_bare: std.ArrayList(u8) = .empty,
    expected_server_signature: [Sha256.digest_length]u8 = @splat(0),
    server_signature_ready: bool = false,
    server_signature_verified: bool = false,

    pub fn init(gpa: std.mem.Allocator, credentials: *Credentials, config: Config) Session {
        return .{ .gpa = gpa, .credentials = credentials, .config = config };
    }

    pub fn deinit(self: *Session) void {
        self.secureClearInternal();
        self.incoming.deinit(self.gpa);
        self.gs2_header.deinit(self.gpa);
        self.client_first_bare.deinit(self.gpa);
        self.credentials.zeroize();
        self.* = undefined;
    }

    /// CAP 302 supplies a comma-separated mechanism value. Null means the
    /// server advertised `sasl` without a value, so configured mechanisms may
    /// still be attempted as required by IRCv3.2.
    pub fn setAdvertisement(self: *Session, value: ?[]const u8) void {
        self.advertised = .{};
        self.advertisement_known = value != null;
        var iterator = std.mem.splitScalar(u8, value orelse "", ',');
        while (iterator.next()) |raw| {
            if (Mechanism.parse(raw)) |mechanism| self.advertised.insert(mechanism);
        }
    }

    /// Start after the server ACKs the `sasl` capability. The nonce is
    /// caller-supplied so production code can use its platform CSPRNG and tests
    /// can remain deterministic. It must outlive this session.
    pub fn start(self: *Session, out: *std.ArrayList(u8), client_nonce: []const u8) Error!Event {
        if (self.phase != .idle) return error.InvalidState;
        try validateNonce(client_nonce);
        self.client_nonce = client_nonce;
        return self.startNext(out, .started);
    }

    pub fn handle(self: *Session, out: *std.ArrayList(u8), msg: message.Message) Error!Event {
        if (std.ascii.eqlIgnoreCase(msg.command, "AUTHENTICATE")) {
            const fragment = msg.param(0) orelse return error.InvalidAuthenticateChunk;
            return self.handleAuthenticate(out, fragment);
        }

        if (std.mem.eql(u8, msg.command, "900")) return .logged_in;
        if (std.mem.eql(u8, msg.command, "901")) return .logged_out;
        if (std.mem.eql(u8, msg.command, "908")) {
            self.setAdvertisement(msg.param(1));
            return .mechanisms_updated;
        }
        if (std.mem.eql(u8, msg.command, "903")) {
            if (self.selected == .scram_sha_256 and !self.server_signature_verified) {
                // A success numeric without a verified server-final is a
                // hard auth failure. Return `.failed` so registration can
                // still emit CAP END instead of stalling in waiting_sasl.
                self.finish(.failed);
                return .failed;
            }
            self.finish(.complete);
            return .succeeded;
        }
        if (std.mem.eql(u8, msg.command, "907")) {
            self.finish(.complete);
            return .already_authenticated;
        }
        if (std.mem.eql(u8, msg.command, "902")) {
            self.finish(.failed);
            return .failed;
        }
        if (std.mem.eql(u8, msg.command, "904") or
            std.mem.eql(u8, msg.command, "905") or
            std.mem.eql(u8, msg.command, "906"))
        {
            if (self.phase == .complete or self.phase == .failed) return .failed;
            return self.startNext(out, .retrying) catch |err| switch (err) {
                error.NoSupportedMechanism => {
                    self.finish(.failed);
                    return .failed;
                },
                else => |other| return other,
            };
        }
        return .none;
    }

    fn startNext(self: *Session, out: *std.ArrayList(u8), event: Event) Error!Event {
        self.clearAttemptState();
        for (self.config.preference) |candidate| {
            if (self.attempted.contains(candidate)) continue;
            if (self.advertisement_known and !self.advertised.contains(candidate)) continue;
            if (!self.mechanismUsable(candidate)) continue;
            self.attempted.insert(candidate);
            self.selected = candidate;
            self.phase = .awaiting_initial;
            try appendCommand(out, self.gpa, candidate.wireName());
            return event;
        }
        return error.NoSupportedMechanism;
    }

    fn mechanismUsable(self: *const Session, mechanism: Mechanism) bool {
        return switch (mechanism) {
            .external => self.credentials.external_available,
            .plain, .scram_sha_256 => self.credentials.authentication_identity.len != 0,
        };
    }

    fn handleAuthenticate(self: *Session, out: *std.ArrayList(u8), fragment: []const u8) Error!Event {
        if (fragment.len > authenticate_chunk_size or fragment.len == 0 or
            std.mem.indexOfAny(u8, fragment, " \r\n\x00") != null)
            return error.InvalidAuthenticateChunk;

        if (std.mem.eql(u8, fragment, "+")) {
            if (self.incoming.items.len == 0) return self.handleChallenge(out, "");
            return self.finishIncoming(out);
        }
        if (std.mem.eql(u8, fragment, "*")) return error.InvalidAuthenticateChunk;
        if (self.incoming.items.len + fragment.len > max_encoded_challenge)
            return error.ChallengeTooLong;
        try self.incoming.appendSlice(self.gpa, fragment);
        if (fragment.len == authenticate_chunk_size) return .none;
        return self.finishIncoming(out);
    }

    fn finishIncoming(self: *Session, out: *std.ArrayList(u8)) Error!Event {
        const encoded = self.incoming.items;
        defer secureClearList(&self.incoming);
        const decoded_len = b64_decoder.calcSizeForSlice(encoded) catch return error.InvalidBase64;
        const decoded = try self.gpa.alloc(u8, decoded_len);
        defer {
            std.crypto.secureZero(u8, decoded);
            self.gpa.free(decoded);
        }
        b64_decoder.decode(decoded, encoded) catch return error.InvalidBase64;
        return self.handleChallenge(out, decoded);
    }

    fn handleChallenge(self: *Session, out: *std.ArrayList(u8), challenge: []const u8) Error!Event {
        const selected = self.selected orelse return error.InvalidState;
        return switch (self.phase) {
            .awaiting_initial => switch (selected) {
                .plain => if (challenge.len == 0) self.sendPlain(out) else error.InvalidScramMessage,
                .external => if (challenge.len == 0) self.sendExternal(out) else error.InvalidScramMessage,
                .scram_sha_256 => if (challenge.len == 0) self.sendScramFirst(out) else error.InvalidScramMessage,
            },
            .awaiting_server_first => if (selected == .scram_sha_256)
                self.sendScramFinal(out, challenge)
            else
                error.InvalidState,
            .awaiting_server_final => if (selected == .scram_sha_256)
                self.verifyScramFinal(out, challenge)
            else
                error.InvalidState,
            else => error.InvalidState,
        };
    }

    fn sendPlain(self: *Session, out: *std.ArrayList(u8)) Error!Event {
        const credentials = self.credentials;
        try validatePlainField(credentials.authorization_identity, true);
        try validatePlainField(credentials.authentication_identity, false);
        try validatePlainField(credentials.password, true);
        const length = credentials.authorization_identity.len + 1 +
            credentials.authentication_identity.len + 1 + credentials.password.len;
        const raw = try self.gpa.alloc(u8, length);
        defer {
            std.crypto.secureZero(u8, raw);
            self.gpa.free(raw);
        }
        var at: usize = 0;
        @memcpy(raw[at..][0..credentials.authorization_identity.len], credentials.authorization_identity);
        at += credentials.authorization_identity.len;
        raw[at] = 0;
        at += 1;
        @memcpy(raw[at..][0..credentials.authentication_identity.len], credentials.authentication_identity);
        at += credentials.authentication_identity.len;
        raw[at] = 0;
        at += 1;
        @memcpy(raw[at..][0..credentials.password.len], credentials.password);
        try appendPayload(out, self.gpa, raw);
        self.phase = .awaiting_result;
        return .response_sent;
    }

    fn sendExternal(self: *Session, out: *std.ArrayList(u8)) Error!Event {
        try validatePlainField(self.credentials.authorization_identity, true);
        try appendPayload(out, self.gpa, self.credentials.authorization_identity);
        self.phase = .awaiting_result;
        return .response_sent;
    }

    fn sendScramFirst(self: *Session, out: *std.ArrayList(u8)) Error!Event {
        try validateScramPassword(self.credentials.password);
        self.gs2_header.clearRetainingCapacity();
        self.client_first_bare.clearRetainingCapacity();
        if (self.credentials.authorization_identity.len == 0) {
            try self.gs2_header.appendSlice(self.gpa, "n,,");
        } else {
            try self.gs2_header.appendSlice(self.gpa, "n,a=");
            try appendScramName(&self.gs2_header, self.gpa, self.credentials.authorization_identity);
            try self.gs2_header.append(self.gpa, ',');
        }
        try self.client_first_bare.appendSlice(self.gpa, "n=");
        try appendScramName(&self.client_first_bare, self.gpa, self.credentials.authentication_identity);
        try self.client_first_bare.appendSlice(self.gpa, ",r=");
        try self.client_first_bare.appendSlice(self.gpa, self.client_nonce);

        var first: std.ArrayList(u8) = .empty;
        defer secureDeinit(&first, self.gpa);
        try first.appendSlice(self.gpa, self.gs2_header.items);
        try first.appendSlice(self.gpa, self.client_first_bare.items);
        try appendPayload(out, self.gpa, first.items);
        self.phase = .awaiting_server_first;
        return .response_sent;
    }

    fn sendScramFinal(self: *Session, out: *std.ArrayList(u8), server_first: []const u8) Error!Event {
        const parsed = try parseServerFirst(server_first, self.client_nonce);
        const salt_len = b64_decoder.calcSizeForSlice(parsed.salt) catch return error.InvalidBase64;
        if (salt_len > 1024) return error.InvalidScramMessage;
        const salt = try self.gpa.alloc(u8, salt_len);
        defer {
            std.crypto.secureZero(u8, salt);
            self.gpa.free(salt);
        }
        b64_decoder.decode(salt, parsed.salt) catch return error.InvalidBase64;

        var channel_binding_encoded: [b64_encoder.calcSize(512)]u8 = undefined;
        if (self.gs2_header.items.len > 512) return error.InvalidIdentity;
        const channel_binding = b64_encoder.encode(&channel_binding_encoded, self.gs2_header.items);

        var final_without_proof: std.ArrayList(u8) = .empty;
        defer secureDeinit(&final_without_proof, self.gpa);
        try final_without_proof.appendSlice(self.gpa, "c=");
        try final_without_proof.appendSlice(self.gpa, channel_binding);
        try final_without_proof.appendSlice(self.gpa, ",r=");
        try final_without_proof.appendSlice(self.gpa, parsed.nonce);

        var auth_message: std.ArrayList(u8) = .empty;
        defer secureDeinit(&auth_message, self.gpa);
        try auth_message.appendSlice(self.gpa, self.client_first_bare.items);
        try auth_message.append(self.gpa, ',');
        try auth_message.appendSlice(self.gpa, server_first);
        try auth_message.append(self.gpa, ',');
        try auth_message.appendSlice(self.gpa, final_without_proof.items);

        var salted_password: [Sha256.digest_length]u8 = undefined;
        defer std.crypto.secureZero(u8, &salted_password);
        std.crypto.pwhash.pbkdf2(
            &salted_password,
            self.credentials.password,
            salt,
            parsed.iterations,
            HmacSha256,
        ) catch return error.InvalidScramIterations;

        var client_key: [Sha256.digest_length]u8 = undefined;
        defer std.crypto.secureZero(u8, &client_key);
        HmacSha256.create(&client_key, "Client Key", &salted_password);
        var stored_key: [Sha256.digest_length]u8 = undefined;
        defer std.crypto.secureZero(u8, &stored_key);
        Sha256.hash(&client_key, &stored_key, .{});
        var client_signature: [Sha256.digest_length]u8 = undefined;
        defer std.crypto.secureZero(u8, &client_signature);
        HmacSha256.create(&client_signature, auth_message.items, &stored_key);
        var proof: [Sha256.digest_length]u8 = undefined;
        defer std.crypto.secureZero(u8, &proof);
        for (&proof, 0..) |*byte, index| byte.* = client_key[index] ^ client_signature[index];

        var server_key: [Sha256.digest_length]u8 = undefined;
        defer std.crypto.secureZero(u8, &server_key);
        HmacSha256.create(&server_key, "Server Key", &salted_password);
        HmacSha256.create(&self.expected_server_signature, auth_message.items, &server_key);
        self.server_signature_ready = true;

        var proof_encoded: [b64_encoder.calcSize(Sha256.digest_length)]u8 = undefined;
        const proof_text = b64_encoder.encode(&proof_encoded, &proof);
        var final: std.ArrayList(u8) = .empty;
        defer secureDeinit(&final, self.gpa);
        try final.appendSlice(self.gpa, final_without_proof.items);
        try final.appendSlice(self.gpa, ",p=");
        try final.appendSlice(self.gpa, proof_text);
        try appendPayload(out, self.gpa, final.items);
        self.phase = .awaiting_server_final;
        return .response_sent;
    }

    fn verifyScramFinal(self: *Session, out: *std.ArrayList(u8), server_final: []const u8) Error!Event {
        if (!self.server_signature_ready) return error.InvalidState;
        const parsed = try parseServerFinal(server_final);
        const verifier = switch (parsed) {
            .server_error => {
                try appendCommand(out, self.gpa, "+");
                self.phase = .awaiting_result;
                return .response_sent;
            },
            .verifier => |value| value,
        };
        const decoded_len = b64_decoder.calcSizeForSlice(verifier) catch return error.InvalidBase64;
        if (decoded_len != Sha256.digest_length) return self.abortBadSignature(out);
        var decoded: [Sha256.digest_length]u8 = undefined;
        defer std.crypto.secureZero(u8, &decoded);
        b64_decoder.decode(&decoded, verifier) catch return error.InvalidBase64;
        if (!std.crypto.timing_safe.eql([Sha256.digest_length]u8, decoded, self.expected_server_signature))
            return self.abortBadSignature(out);
        self.server_signature_verified = true;
        try appendCommand(out, self.gpa, "+");
        self.phase = .awaiting_result;
        return .response_sent;
    }

    fn abortBadSignature(self: *Session, out: *std.ArrayList(u8)) Error!Event {
        try appendCommand(out, self.gpa, "*");
        self.phase = .awaiting_abort;
        return error.ServerSignatureMismatch;
    }

    fn clearAttemptState(self: *Session) void {
        secureClearList(&self.incoming);
        secureClearList(&self.gs2_header);
        secureClearList(&self.client_first_bare);
        std.crypto.secureZero(u8, &self.expected_server_signature);
        self.server_signature_ready = false;
        self.server_signature_verified = false;
        self.selected = null;
    }

    fn secureClearInternal(self: *Session) void {
        self.clearAttemptState();
    }

    fn finish(self: *Session, phase: Phase) void {
        self.phase = phase;
        self.secureClearInternal();
        self.credentials.zeroize();
    }
};

const ServerFirst = struct {
    nonce: []const u8,
    salt: []const u8,
    iterations: u32,
};

fn parseServerFirst(raw: []const u8, client_nonce: []const u8) Error!ServerFirst {
    var nonce: ?[]const u8 = null;
    var salt: ?[]const u8 = null;
    var iterations: ?u32 = null;
    var fields = std.mem.splitScalar(u8, raw, ',');
    while (fields.next()) |field| {
        if (field.len < 3 or field[1] != '=') return error.InvalidScramMessage;
        const value = field[2..];
        switch (field[0]) {
            'm' => return error.InvalidScramMessage,
            'r' => {
                if (nonce != null) return error.InvalidScramMessage;
                nonce = value;
            },
            's' => {
                if (salt != null) return error.InvalidScramMessage;
                salt = value;
            },
            'i' => {
                if (iterations != null) return error.InvalidScramMessage;
                if (value.len == 0 or value[0] < '1' or value[0] > '9')
                    return error.InvalidScramIterations;
                for (value[1..]) |byte| {
                    if (!std.ascii.isDigit(byte)) return error.InvalidScramIterations;
                }
                const parsed = std.fmt.parseInt(u32, value, 10) catch return error.InvalidScramIterations;
                if (parsed < min_scram_iterations or parsed > max_scram_iterations)
                    return error.InvalidScramIterations;
                iterations = parsed;
            },
            else => {},
        }
    }
    const server_nonce = nonce orelse return error.InvalidScramMessage;
    try validateNonce(server_nonce);
    if (server_nonce.len <= client_nonce.len or !std.mem.startsWith(u8, server_nonce, client_nonce))
        return error.InvalidNonce;
    const server_salt = salt orelse return error.InvalidScramMessage;
    if (server_salt.len == 0) return error.InvalidScramMessage;
    return .{
        .nonce = server_nonce,
        .salt = server_salt,
        .iterations = iterations orelse return error.InvalidScramMessage,
    };
}

const ServerFinal = union(enum) {
    verifier: []const u8,
    server_error: []const u8,
};

fn parseServerFinal(raw: []const u8) Error!ServerFinal {
    var verifier: ?[]const u8 = null;
    var server_error: ?[]const u8 = null;
    var fields = std.mem.splitScalar(u8, raw, ',');
    while (fields.next()) |field| {
        if (field.len < 3 or field[1] != '=') return error.InvalidScramMessage;
        switch (field[0]) {
            'v' => {
                if (verifier != null) return error.InvalidScramMessage;
                verifier = field[2..];
            },
            'e' => {
                if (server_error != null) return error.InvalidScramMessage;
                if (field.len == 2) return error.InvalidScramMessage;
                server_error = field[2..];
            },
            else => {},
        }
    }
    if ((server_error == null) == (verifier == null)) return error.InvalidScramMessage;
    if (server_error) |value| return .{ .server_error = value };
    return .{ .verifier = verifier.? };
}

fn validateNonce(nonce: []const u8) Error!void {
    if (nonce.len == 0) return error.InvalidNonce;
    for (nonce) |byte| {
        if (byte < 0x21 or byte > 0x7e or byte == ',') return error.InvalidNonce;
    }
}

fn validatePlainField(field: []const u8, empty_allowed: bool) Error!void {
    if ((!empty_allowed and field.len == 0) or
        std.mem.indexOfScalar(u8, field, 0) != null or
        !std.unicode.utf8ValidateSlice(field))
        return error.InvalidIdentity;
}

/// The core deliberately accepts only the ASCII subset which is unchanged by
/// SASLprep. Callers with internationalized SCRAM credentials must prepare
/// them before this layer grows a complete RFC 4013 implementation.
fn validateScramPassword(password: []const u8) Error!void {
    for (password) |byte| {
        if (byte < 0x20 or byte > 0x7e) return error.InvalidIdentity;
    }
}

fn appendScramName(out: *std.ArrayList(u8), gpa: std.mem.Allocator, raw: []const u8) Error!void {
    for (raw) |byte| switch (byte) {
        ',' => try out.appendSlice(gpa, "=2C"),
        '=' => try out.appendSlice(gpa, "=3D"),
        0...0x1f, 0x7f...0xff => return error.InvalidIdentity,
        else => try out.append(gpa, byte),
    };
}

fn appendCommand(out: *std.ArrayList(u8), gpa: std.mem.Allocator, parameter: []const u8) Error!void {
    if (parameter.len == 0 or parameter.len > authenticate_chunk_size or
        std.mem.indexOfAny(u8, parameter, " \r\n\x00") != null)
        return error.InvalidAuthenticateChunk;
    const start = out.items.len;
    errdefer {
        std.crypto.secureZero(u8, out.items[start..]);
        out.items.len = start;
    }
    try out.appendSlice(gpa, "AUTHENTICATE ");
    try out.appendSlice(gpa, parameter);
    try out.appendSlice(gpa, "\r\n");
}

/// Base64-encode and split one SASL response exactly as IRCv3.1 requires.
pub fn appendPayload(out: *std.ArrayList(u8), gpa: std.mem.Allocator, raw: []const u8) Error!void {
    const start = out.items.len;
    errdefer {
        std.crypto.secureZero(u8, out.items[start..]);
        out.items.len = start;
    }
    if (raw.len == 0) return appendCommand(out, gpa, "+");
    const encoded_len = b64_encoder.calcSize(raw.len);
    const encoded = try gpa.alloc(u8, encoded_len);
    defer {
        std.crypto.secureZero(u8, encoded);
        gpa.free(encoded);
    }
    _ = b64_encoder.encode(encoded, raw);
    var at: usize = 0;
    while (at < encoded.len) {
        const end = @min(encoded.len, at + authenticate_chunk_size);
        try appendCommand(out, gpa, encoded[at..end]);
        at = end;
    }
    if (encoded.len % authenticate_chunk_size == 0) try appendCommand(out, gpa, "+");
}

/// Wipe commands after the transport has consumed them. This is mandatory for
/// buffers which may have held PLAIN credentials.
pub fn secureClear(out: *std.ArrayList(u8)) void {
    secureClearList(out);
}

fn secureDeinit(list: *std.ArrayList(u8), gpa: std.mem.Allocator) void {
    wipeListCapacity(list);
    list.deinit(gpa);
}

fn secureClearList(list: *std.ArrayList(u8)) void {
    wipeListCapacity(list);
    // `clearRetainingCapacity` deliberately poisons the old logical slice with
    // `undefined` in safety builds, which would undo the secure wipe.
    list.items.len = 0;
}

fn wipeListCapacity(list: *std.ArrayList(u8)) void {
    if (list.capacity != 0) std.crypto.secureZero(u8, list.items.ptr[0..list.capacity]);
}

test "IRCv3.1 PLAIN transcript and terminal credential zeroization" {
    const gpa = std.testing.allocator;
    var authzid = [_]u8{ 'j', 'i', 'l', 'l', 'e', 's' };
    var authcid = authzid;
    var password = [_]u8{ 's', 'e', 's', 'a', 'm', 'e' };
    var credentials = Credentials{
        .authorization_identity = &authzid,
        .authentication_identity = &authcid,
        .password = &password,
    };
    const preference = [_]Mechanism{.plain};
    var session = Session.init(gpa, &credentials, .{ .preference = &preference });
    defer session.deinit();
    session.setAdvertisement("PLAIN");
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);

    try std.testing.expectEqual(Event.started, try session.start(&out, "deterministic-nonce"));
    try std.testing.expectEqualStrings("AUTHENTICATE PLAIN\r\n", out.items);
    out.clearRetainingCapacity();
    try std.testing.expectEqual(
        Event.response_sent,
        try session.handle(&out, message.parse("AUTHENTICATE +")),
    );
    try std.testing.expectEqualStrings(
        "AUTHENTICATE amlsbGVzAGppbGxlcwBzZXNhbWU=\r\n",
        out.items,
    );
    try std.testing.expectEqual(Event.logged_in, try session.handle(&out, message.parse(":irc 900 jilles host account :logged in")));
    try std.testing.expectEqual(Event.succeeded, try session.handle(&out, message.parse(":irc 903 jilles :success")));
    try std.testing.expect(credentials.zeroized);
    try std.testing.expectEqualSlices(u8, &@as([6]u8, @splat(0)), &authzid);
    try std.testing.expectEqualSlices(u8, &@as([6]u8, @splat(0)), &authcid);
    try std.testing.expectEqualSlices(u8, &@as([6]u8, @splat(0)), &password);
}

test "AUTHENTICATE responses use 400-byte chunks and a terminal plus" {
    const gpa = std.testing.allocator;
    var raw: [300]u8 = @splat('x');
    defer std.crypto.secureZero(u8, &raw);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try appendPayload(&out, gpa, &raw);

    var lines = std.mem.splitSequence(u8, out.items, "\r\n");
    const first = lines.next().?;
    try std.testing.expectEqual(@as(usize, "AUTHENTICATE ".len + authenticate_chunk_size), first.len);
    try std.testing.expectEqualStrings("AUTHENTICATE +", lines.next().?);
    try std.testing.expectEqualStrings("", lines.next().?);
}

test "incoming exact-400 chunk waits for its continuation" {
    const gpa = std.testing.allocator;
    var authzid: [0]u8 = .{};
    var authcid = [_]u8{'u'};
    var password = [_]u8{'p'};
    var credentials = Credentials{
        .authorization_identity = &authzid,
        .authentication_identity = &authcid,
        .password = &password,
    };
    var session = Session.init(gpa, &credentials, .{});
    defer session.deinit();
    session.selected = .scram_sha_256;
    session.phase = .awaiting_server_first;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    var first: ["AUTHENTICATE ".len + authenticate_chunk_size]u8 = undefined;
    @memcpy(first[0.."AUTHENTICATE ".len], "AUTHENTICATE ");
    @memset(first["AUTHENTICATE ".len..], 'Q');

    try std.testing.expectEqual(Event.none, try session.handle(&out, message.parse(&first)));
    try std.testing.expectEqual(authenticate_chunk_size, session.incoming.items.len);
    try std.testing.expectError(
        error.InvalidScramMessage,
        session.handle(&out, message.parse("AUTHENTICATE QQ==")),
    );
    try std.testing.expectEqual(@as(usize, 0), session.incoming.items.len);
}

test "mechanism advertisement filters preference and failures retry the next mechanism" {
    const gpa = std.testing.allocator;
    var authzid = [_]u8{ 'c', 'e', 'r', 't' };
    var authcid = [_]u8{ 'u', 's', 'e', 'r' };
    var password = [_]u8{ 'p', 'a', 's', 's' };
    var credentials = Credentials{
        .authorization_identity = &authzid,
        .authentication_identity = &authcid,
        .password = &password,
        .external_available = true,
    };
    const preference = [_]Mechanism{ .plain, .external, .scram_sha_256 };
    var session = Session.init(gpa, &credentials, .{ .preference = &preference });
    defer session.deinit();
    session.setAdvertisement("PLAIN,EXTERNAL,UNKNOWN");
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);

    _ = try session.start(&out, "nonce");
    try std.testing.expectEqualStrings("AUTHENTICATE PLAIN\r\n", out.items);
    out.clearRetainingCapacity();
    try std.testing.expectEqual(
        Event.retrying,
        try session.handle(&out, message.parse(":irc 904 nick :failed")),
    );
    try std.testing.expectEqualStrings("AUTHENTICATE EXTERNAL\r\n", out.items);
    out.clearRetainingCapacity();
    try std.testing.expectEqual(Event.failed, try session.handle(&out, message.parse(":irc 905 nick :too long")));
    try std.testing.expect(credentials.zeroized);
}

test "901 is informational and 906 retries a remaining advertised mechanism" {
    const gpa = std.testing.allocator;
    var authzid = [_]u8{ 'c', 'e', 'r', 't' };
    var authcid = [_]u8{ 'u', 's', 'e', 'r' };
    var password = [_]u8{ 'p', 'a', 's', 's' };
    var credentials = Credentials{
        .authorization_identity = &authzid,
        .authentication_identity = &authcid,
        .password = &password,
        .external_available = true,
    };
    const preference = [_]Mechanism{ .plain, .external };
    var session = Session.init(gpa, &credentials, .{ .preference = &preference });
    defer session.deinit();
    session.setAdvertisement("PLAIN,EXTERNAL");
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    _ = try session.start(&out, "nonce");

    try std.testing.expectEqual(Event.logged_out, try session.handle(&out, message.parse(":irc 901 nick :logged out")));
    try std.testing.expect(!credentials.zeroized);
    out.clearRetainingCapacity();
    try std.testing.expectEqual(Event.retrying, try session.handle(&out, message.parse(":irc 906 nick :aborted")));
    try std.testing.expectEqualStrings("AUTHENTICATE EXTERNAL\r\n", out.items);
    try std.testing.expect(!credentials.zeroized);
}

test "908 refreshes mechanisms and 902 and 907 are terminal" {
    const gpa = std.testing.allocator;
    var authzid = [_]u8{'a'};
    var authcid = [_]u8{'b'};
    var password = [_]u8{'c'};
    var credentials = Credentials{
        .authorization_identity = &authzid,
        .authentication_identity = &authcid,
        .password = &password,
    };
    var session = Session.init(gpa, &credentials, .{});
    defer session.deinit();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try std.testing.expectEqual(
        Event.mechanisms_updated,
        try session.handle(&out, message.parse(":irc 908 nick SCRAM-SHA-256,PLAIN :available")),
    );
    try std.testing.expect(session.advertised.contains(.scram_sha_256));
    _ = try session.start(&out, "nonce");
    try std.testing.expectEqual(Event.failed, try session.handle(&out, message.parse(":irc 902 nick :account mismatch")));
    try std.testing.expect(credentials.zeroized);

    var authzid2 = [_]u8{'a'};
    var authcid2 = [_]u8{'b'};
    var password2 = [_]u8{'c'};
    var credentials2 = Credentials{
        .authorization_identity = &authzid2,
        .authentication_identity = &authcid2,
        .password = &password2,
    };
    var session2 = Session.init(gpa, &credentials2, .{});
    defer session2.deinit();
    try std.testing.expectEqual(Event.already_authenticated, try session2.handle(&out, message.parse(":irc 907 nick :already")));
    try std.testing.expect(credentials2.zeroized);
}

test "904 after a completed exchange is a failure rather than silence" {
    const gpa = std.testing.allocator;
    var authzid = [_]u8{'a'};
    var authcid = [_]u8{'b'};
    var password = [_]u8{'c'};
    var credentials = Credentials{
        .authorization_identity = &authzid,
        .authentication_identity = &authcid,
        .password = &password,
    };
    var session = Session.init(gpa, &credentials, .{});
    defer session.deinit();
    session.phase = .complete;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try std.testing.expectEqual(Event.failed, try session.handle(&out, message.parse(":irc 904 nick :SASL authentication failed")));
    try std.testing.expectEqual(@as(usize, 0), out.items.len);
}

test "RFC 7677 SCRAM-SHA-256 vector verifies nonce, proof, and server signature" {
    const gpa = std.testing.allocator;
    var authzid: [0]u8 = .{};
    var authcid = [_]u8{ 'u', 's', 'e', 'r' };
    var password = [_]u8{ 'p', 'e', 'n', 'c', 'i', 'l' };
    var credentials = Credentials{
        .authorization_identity = &authzid,
        .authentication_identity = &authcid,
        .password = &password,
    };
    const preference = [_]Mechanism{.scram_sha_256};
    var session = Session.init(gpa, &credentials, .{ .preference = &preference });
    defer session.deinit();
    session.setAdvertisement("SCRAM-SHA-256");
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);

    _ = try session.start(&out, "rOprNGfwEbeRWgbNEkqO");
    try std.testing.expectEqualStrings("AUTHENTICATE SCRAM-SHA-256\r\n", out.items);
    out.clearRetainingCapacity();
    _ = try session.handle(&out, message.parse("AUTHENTICATE +"));
    try std.testing.expectEqualStrings(
        "AUTHENTICATE biwsbj11c2VyLHI9ck9wck5HZndFYmVSV2diTkVrcU8=\r\n",
        out.items,
    );
    out.clearRetainingCapacity();
    _ = try session.handle(&out, message.parse(
        "AUTHENTICATE cj1yT3ByTkdmd0ViZVJXZ2JORWtxTyVodllEcFdVYTJSYVRDQWZ1eEZJbGopaE5sRiRrMCxzPVcyMlphSjBTTlk3c29Fc1VFamI2Z1E9PSxpPTQwOTY=",
    ));
    try std.testing.expectEqualStrings(
        "AUTHENTICATE Yz1iaXdzLHI9ck9wck5HZndFYmVSV2diTkVrcU8laHZZRHBXVWEyUmFUQ0FmdXhGSWxqKWhObEYkazAscD1kSHpiWmFwV0lrNGpVaE4rVXRlOXl0YWc5empmTUhnc3FtbWl6N0FuZFZRPQ==\r\n",
        out.items,
    );
    out.clearRetainingCapacity();
    _ = try session.handle(&out, message.parse(
        "AUTHENTICATE dj02cnJpVFJCaTIzV3BSUi93dHVwK21NaFVaVW4vZEI1bkxUSlJzamw5NUc0PQ==",
    ));
    try std.testing.expectEqualStrings("AUTHENTICATE +\r\n", out.items);
    try std.testing.expect(session.server_signature_verified);
    try std.testing.expectEqual(Event.succeeded, try session.handle(&out, message.parse(":irc 903 user :success")));
}

test "SCRAM rejects a non-extending nonce and aborts a bad server signature" {
    const gpa = std.testing.allocator;
    var authzid: [0]u8 = .{};
    var authcid = [_]u8{ 'u', 's', 'e', 'r' };
    var password = [_]u8{ 'p', 'e', 'n', 'c', 'i', 'l' };
    var credentials = Credentials{
        .authorization_identity = &authzid,
        .authentication_identity = &authcid,
        .password = &password,
    };
    const preference = [_]Mechanism{.scram_sha_256};
    var session = Session.init(gpa, &credentials, .{ .preference = &preference });
    defer session.deinit();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    _ = try session.start(&out, "clientnonce");
    out.clearRetainingCapacity();
    _ = try session.handle(&out, message.parse("AUTHENTICATE +"));
    out.clearRetainingCapacity();
    try std.testing.expectError(
        error.InvalidNonce,
        session.handle(&out, message.parse("AUTHENTICATE cj1jbGllbnRub25jZSxzPVcyMlphSjBTTlk3c29Fc1VFamI2Z1E9PSxpPTQwOTY=")),
    );

    session.phase = .awaiting_server_final;
    session.server_signature_ready = true;
    session.expected_server_signature = @splat(0xaa);
    out.clearRetainingCapacity();
    try std.testing.expectError(
        error.ServerSignatureMismatch,
        session.handle(&out, message.parse("AUTHENTICATE dj1BQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQT0=")),
    );
    try std.testing.expectEqualStrings("AUTHENTICATE *\r\n", out.items);
    try std.testing.expectEqual(Phase.awaiting_abort, session.phase);
}

test "unsigned SCRAM 903 is a terminal failure, not a success" {
    const gpa = std.testing.allocator;
    var authzid: [0]u8 = .{};
    var authcid = [_]u8{'u'};
    var password = [_]u8{'p'};
    var credentials = Credentials{
        .authorization_identity = &authzid,
        .authentication_identity = &authcid,
        .password = &password,
    };
    var session = Session.init(gpa, &credentials, .{});
    defer session.deinit();
    session.selected = .scram_sha_256;
    session.phase = .awaiting_result;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try std.testing.expectEqual(Event.failed, try session.handle(&out, message.parse(":irc 903 user :success")));
    try std.testing.expectEqual(Phase.failed, session.phase);
    try std.testing.expect(credentials.zeroized);
}

test "SCRAM server-final error is acknowledged so the failure numeric can drive retry" {
    const gpa = std.testing.allocator;
    var authzid: [0]u8 = .{};
    var authcid = [_]u8{'u'};
    var password = [_]u8{'p'};
    var credentials = Credentials{
        .authorization_identity = &authzid,
        .authentication_identity = &authcid,
        .password = &password,
    };
    var session = Session.init(gpa, &credentials, .{});
    defer session.deinit();
    session.selected = .scram_sha_256;
    session.phase = .awaiting_server_final;
    session.server_signature_ready = true;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);

    try std.testing.expectEqual(
        Event.response_sent,
        try session.handle(&out, message.parse("AUTHENTICATE ZT1pbnZhbGlkLXByb29m")),
    );
    try std.testing.expectEqualStrings("AUTHENTICATE +\r\n", out.items);
    try std.testing.expectEqual(Phase.awaiting_result, session.phase);
}

test "secureClear wipes retained capacity, including bytes past the current length" {
    const gpa = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try out.appendSlice(gpa, "reversible-secret-material");
    out.clearRetainingCapacity();
    try out.appendSlice(gpa, "short");
    secureClear(&out);
    try std.testing.expectEqual(@as(usize, 0), out.items.len);
    for (out.items.ptr[0..out.capacity]) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
}
