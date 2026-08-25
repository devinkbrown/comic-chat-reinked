//! Comic Chat: Reinked — source-faithful Microsoft Comic Chat continuation (CLI/app).
//!
//! Subcommands:
//!   (none) / app                         open the desktop client
//!   render-bg | render-panel | render-figure | render-strip | topng
//!                                        source art/render diagnostics
//!   render-ui                            desktop UI preview PNG
//!   window <avatar>                      native backend smoke
//!   connect | chat-comic | app           IRC and interactive comic clients
//!
//! Platform windows only present the shared software-rendered client view.

const std = @import("std");
const builtin = @import("builtin");
const cc = @import("comicchat");

/// Diagnostics stay on stderr so image subcommands can reserve stdout for
/// binary PPM/PNG data on every supported platform.
fn elog(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(fmt, args);
}

/// Microsoft IRCX numeric 800 carries the negotiated state after the nick:
/// `800 <nick> 1 ...` means enabled, while the source's `MODE ISIRCX` probe
/// can legitimately return state `0` before the client issues `IRCX`.
fn ircxNumericEnabled(msg: *const cc.net.message.Message) bool {
    return std.mem.eql(u8, msg.command, "800") and
        msg.param_count >= 2 and
        std.mem.eql(u8, msg.params[1], "1");
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const minimal = init.minimal;

    // Collect argv through Zig's Init parameter. The
    // allocator-based iterator is the cross-platform form (Windows requires it).
    var it = try minimal.args.iterateAllocator(gpa);
    defer it.deinit();
    const executable = it.next() orelse "reinked";
    var argv: [32][]const u8 = undefined;
    var argc: usize = 0;
    while (it.next()) |a| : (argc += 1) {
        if (argc >= argv.len) break;
        argv[argc] = a;
    }

    if (argc >= 1 and std.mem.eql(u8, argv[0], "render-bg")) {
        try runRenderBg(gpa, init.io, if (argc >= 2) argv[1] else "field");
        return;
    }

    if (argc >= 1 and std.mem.eql(u8, argv[0], "render-panel")) {
        const bg = if (argc >= 2) argv[1] else "field";
        const speaker = if (argc >= 3) argv[2] else "ANNA";
        const text = if (argc >= 4) argv[3] else "Hello from the source-faithful Comic Chat renderer!";
        try runRenderPanel(gpa, init.io, bg, speaker, text);
        return;
    }

    if (argc >= 1 and std.mem.eql(u8, argv[0], "render-figure")) {
        const emo = if (argc >= 3) (cc.comic.emotion.Emotion.fromName(argv[2]) orelse .neutral) else .neutral;
        try runRenderFigure(gpa, init.io, if (argc >= 2) argv[1] else "anna", emo.headIndex());
        return;
    }

    if (argc >= 1 and std.mem.eql(u8, argv[0], "render-strip")) {
        try runRenderStrip(gpa, init.io);
        return;
    }

    if (argc >= 1 and std.mem.eql(u8, argv[0], "topng")) {
        try runToPng(gpa, init.io, if (argc >= 2) argv[1] else "field");
        return;
    }

    if (argc >= 1 and std.mem.eql(u8, argv[0], "render-ui")) {
        try runUiPreview(gpa, init.io, if (argc >= 2) argv[1] else "main");
        return;
    }

    if (argc >= 1 and std.mem.eql(u8, argv[0], "window")) {
        const prefer_wayland = if (comptime builtin.os.tag == .linux)
            minimal.environ.containsUnemptyConstant("WAYLAND_DISPLAY")
        else
            false;
        const display = if (comptime builtin.os.tag == .windows) null else minimal.environ.getPosix("DISPLAY");
        try runWindow(gpa, if (argc >= 2) argv[1] else "anna", prefer_wayland, display);
        return;
    }

    const startup_document: ?[]const u8 = if (argc == 1 and isStartupDocument(argv[0])) argv[0] else null;
    if (argc == 0 or startup_document != null or (argc >= 1 and std.mem.eql(u8, argv[0], "app"))) {
        const app_args: []const []const u8 = if (argc == 0 or startup_document != null) &.{} else argv[1..argc];
        const connection = parseConnectionArgs(app_args, false) orelse {
            printConnectionUsage("app", false);
            return;
        };
        var runtime = try ConnectionRuntime.init(gpa, init.io, &connection, executable);
        defer runtime.deinit();
        defer runtime.save() catch |err| elog("STS policy save failed: {s}\n", .{@errorName(err)});
        const prefer_wayland = if (comptime builtin.os.tag == .linux)
            minimal.environ.containsUnemptyConstant("WAYLAND_DISPLAY")
        else
            false;
        const display = if (comptime builtin.os.tag == .windows) null else minimal.environ.getPosix("DISPLAY");
        try runInteractive(
            gpa,
            connection.host,
            connection.port,
            connection.nick,
            connection.channel,
            prefer_wayland,
            display,
            startup_document,
            &runtime,
            init.io,
        );
        return;
    }

    if (argc >= 1 and std.mem.eql(u8, argv[0], "chat-comic")) {
        const connection = parseConnectionArgs(argv[1..argc], true) orelse {
            printConnectionUsage("chat-comic", true);
            return;
        };
        const maxlines: usize = if (connection.extra) |value|
            (std.fmt.parseInt(usize, value, 10) catch 6)
        else
            6;
        var runtime = try ConnectionRuntime.init(gpa, init.io, &connection, executable);
        defer runtime.deinit();
        defer runtime.save() catch |err| elog("STS policy save failed: {s}\n", .{@errorName(err)});
        try runChatComic(
            gpa,
            init.io,
            connection.host,
            connection.port,
            connection.nick,
            connection.channel,
            maxlines,
            runtime.connect_options,
            runtime.registrationOptions(),
        );
        return;
    }

    if (argc >= 1 and std.mem.eql(u8, argv[0], "connect")) {
        const connection = parseConnectionArgs(argv[1..argc], false) orelse {
            printConnectionUsage("connect", false);
            return;
        };
        var runtime = try ConnectionRuntime.init(gpa, init.io, &connection, executable);
        defer runtime.deinit();
        defer runtime.save() catch |err| elog("STS policy save failed: {s}\n", .{@errorName(err)});
        try runConnect(
            gpa,
            init.io,
            connection.host,
            connection.port,
            connection.nick,
            connection.channel,
            runtime.connect_options,
            runtime.registrationOptions(),
        );
        return;
    }

    try runCodecDemo(gpa);
}

fn isStartupDocument(path: []const u8) bool {
    const extension = std.fs.path.extension(path);
    return std.ascii.eqlIgnoreCase(extension, ".ccc") or std.ascii.eqlIgnoreCase(extension, ".ccr");
}

const default_tls_port: u16 = 6697;
const default_server = "eshmaki.me";
const default_server_alternative = "ircx.us";
const default_channel = "#root";
const default_nick = "comicchat";

const AuthArgs = struct {
    user: ?[]const u8 = null,
    authzid: ?[]const u8 = null,
    password_file: ?[]const u8 = null,
    mechanism: ?cc.net.sasl.Mechanism = null,
    external: bool = false,

    fn enabled(self: AuthArgs) bool {
        return self.user != null or self.authzid != null or self.password_file != null or
            self.mechanism != null or self.external;
    }
};

const ConnectionArgs = struct {
    host: []const u8,
    port: u16 = default_tls_port,
    nick: []const u8,
    channel: []const u8,
    extra: ?[]const u8 = null,
    options: cc.net.client.ConnectOptions = .{},
    auth: AuthArgs = .{},
    sts_file: []const u8 = ".comicchat-sts",
    session_file: []const u8 = ".comicchat-session",
};

fn parseConnectionArgs(args: []const []const u8, allow_extra: bool) ?ConnectionArgs {
    var positional: [5][]const u8 = undefined;
    var positional_count: usize = 0;
    var options = cc.net.client.ConnectOptions{};
    var auth: AuthArgs = .{};
    var sts_file: []const u8 = ".comicchat-sts";
    var session_file: []const u8 = ".comicchat-session";
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--plaintext")) {
            options.security = .plaintext;
            continue;
        }
        if (std.mem.eql(u8, arg, "--tls")) {
            options.security = .tls;
            continue;
        }
        if (std.mem.eql(u8, arg, "--ca-file")) {
            index += 1;
            if (index >= args.len) return null;
            options.ca_file = args[index];
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--ca-file=")) {
            const value = arg["--ca-file=".len..];
            if (value.len == 0) return null;
            options.ca_file = value;
            continue;
        }
        if (std.mem.eql(u8, arg, "--tls-cert")) {
            index += 1;
            if (index >= args.len or args[index].len == 0) return null;
            options.client_cert_file = args[index];
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--tls-cert=")) {
            options.client_cert_file = nonEmptyValue(arg, "--tls-cert=") orelse return null;
            continue;
        }
        if (std.mem.eql(u8, arg, "--socks5") or std.mem.eql(u8, arg, "--http-proxy")) {
            const use_socks = std.mem.eql(u8, arg, "--socks5");
            index += 1;
            if (index >= args.len) return null;
            const endpoint = parseProxyEndpoint(args[index]) orelse return null;
            options.proxy = if (use_socks) .{ .socks5 = endpoint } else .{ .http_connect = endpoint };
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--socks5=") or std.mem.startsWith(u8, arg, "--http-proxy=")) {
            const use_socks = std.mem.startsWith(u8, arg, "--socks5=");
            const prefix = if (use_socks) "--socks5=" else "--http-proxy=";
            const endpoint = parseProxyEndpoint(arg[prefix.len..]) orelse return null;
            options.proxy = if (use_socks) .{ .socks5 = endpoint } else .{ .http_connect = endpoint };
            continue;
        }
        if (std.mem.eql(u8, arg, "--connect-timeout-ms")) {
            index += 1;
            if (index >= args.len) return null;
            options.connect_timeout_ms = std.fmt.parseInt(u32, args[index], 10) catch return null;
            if (options.connect_timeout_ms == 0) return null;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--connect-timeout-ms=")) {
            const value = nonEmptyValue(arg, "--connect-timeout-ms=") orelse return null;
            options.connect_timeout_ms = std.fmt.parseInt(u32, value, 10) catch return null;
            if (options.connect_timeout_ms == 0) return null;
            continue;
        }
        if (std.mem.eql(u8, arg, "--sasl-user")) {
            index += 1;
            if (index >= args.len or args[index].len == 0) return null;
            auth.user = args[index];
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--sasl-user=")) {
            auth.user = nonEmptyValue(arg, "--sasl-user=") orelse return null;
            continue;
        }
        if (std.mem.eql(u8, arg, "--sasl-authzid")) {
            index += 1;
            if (index >= args.len) return null;
            auth.authzid = args[index];
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--sasl-authzid=")) {
            auth.authzid = arg["--sasl-authzid=".len..];
            continue;
        }
        if (std.mem.eql(u8, arg, "--sasl-password-file")) {
            index += 1;
            if (index >= args.len or args[index].len == 0) return null;
            auth.password_file = args[index];
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--sasl-password-file=")) {
            auth.password_file = nonEmptyValue(arg, "--sasl-password-file=") orelse return null;
            continue;
        }
        if (std.mem.eql(u8, arg, "--sasl-mechanism")) {
            index += 1;
            if (index >= args.len) return null;
            auth.mechanism = cc.net.sasl.Mechanism.parse(args[index]) orelse return null;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--sasl-mechanism=")) {
            const value = nonEmptyValue(arg, "--sasl-mechanism=") orelse return null;
            auth.mechanism = cc.net.sasl.Mechanism.parse(value) orelse return null;
            continue;
        }
        if (std.mem.eql(u8, arg, "--sasl-external")) {
            auth.external = true;
            auth.mechanism = .external;
            continue;
        }
        if (std.mem.eql(u8, arg, "--sts-file")) {
            index += 1;
            if (index >= args.len or args[index].len == 0) return null;
            sts_file = args[index];
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--sts-file=")) {
            sts_file = nonEmptyValue(arg, "--sts-file=") orelse return null;
            continue;
        }
        if (std.mem.eql(u8, arg, "--session-file")) {
            index += 1;
            if (index >= args.len or args[index].len == 0) return null;
            session_file = args[index];
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--session-file=")) {
            session_file = nonEmptyValue(arg, "--session-file=") orelse return null;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--")) return null;
        if (positional_count == positional.len) return null;
        positional[positional_count] = arg;
        positional_count += 1;
    }
    var result: ConnectionArgs = undefined;
    if (positional_count == 0) {
        result = .{
            .host = default_server,
            .nick = default_nick,
            .channel = default_channel,
            .options = options,
            .auth = auth,
            .sts_file = sts_file,
            .session_file = session_file,
        };
    } else if (positional_count == 1) {
        result = .{
            .host = default_server,
            .nick = positional[0],
            .channel = default_channel,
            .options = options,
            .auth = auth,
            .sts_file = sts_file,
            .session_file = session_file,
        };
    } else if (positional_count == 2) {
        result = .{
            .host = positional[0],
            .nick = positional[1],
            .channel = default_channel,
            .options = options,
            .auth = auth,
            .sts_file = sts_file,
            .session_file = session_file,
        };
    } else if (positional_count < 3) {
        return null;
    } else if (std.fmt.parseInt(u16, positional[1], 10)) |port| {
        if (positional_count < 4) return null;
        result = .{
            .host = positional[0],
            .port = port,
            .nick = positional[2],
            .channel = positional[3],
            .options = options,
            .auth = auth,
            .sts_file = sts_file,
            .session_file = session_file,
        };
        if (positional_count > 4) result.extra = positional[4];
    } else |_| {
        result = .{
            .host = positional[0],
            .nick = positional[1],
            .channel = positional[2],
            .options = options,
            .auth = auth,
            .sts_file = sts_file,
            .session_file = session_file,
        };
        if (positional_count > 3) result.extra = positional[3];
        if (positional_count > 4) return null;
    }
    if (!allow_extra and result.extra != null) return null;
    return result;
}

fn nonEmptyValue(arg: []const u8, comptime prefix: []const u8) ?[]const u8 {
    const value = arg[prefix.len..];
    return if (value.len == 0) null else value;
}

fn parseProxyEndpoint(raw: []const u8) ?cc.net.transport.ProxyEndpoint {
    if (raw.len == 0) return null;
    var host: []const u8 = undefined;
    var port_text: []const u8 = undefined;
    if (raw[0] == '[') {
        const close = std.mem.indexOfScalar(u8, raw, ']') orelse return null;
        if (close <= 1 or close + 2 > raw.len or raw[close + 1] != ':') return null;
        host = raw[1..close];
        port_text = raw[close + 2 ..];
    } else {
        const colon = std.mem.lastIndexOfScalar(u8, raw, ':') orelse return null;
        if (colon == 0) return null;
        host = raw[0..colon];
        port_text = raw[colon + 1 ..];
    }
    const port = std.fmt.parseInt(u16, port_text, 10) catch return null;
    if (port == 0 or std.mem.indexOfAny(u8, host, " \r\n\x00") != null) return null;
    return .{ .host = host, .port = port };
}

fn printConnectionUsage(command: []const u8, allow_extra: bool) void {
    std.debug.print(
        "usage: reinked {s} <nick> (hosts: eshmaki.me or ircx.us; default: eshmaki.me #root) | <host> <nick> [#channel] | <host> [port=6697] <nick> <#channel>{s} [--ca-file <pem>] [--tls-cert <cert-and-key.pem>] [--plaintext] [--socks5 host:port|--http-proxy host:port] [--connect-timeout-ms <ms>] [--sasl-user <name> --sasl-password-file <path>] [--sasl-mechanism SCRAM-SHA-256|EXTERNAL|PLAIN] [--sts-file <path>] [--session-file <path>]\n",
        .{ command, if (allow_extra) " [maxlines]" else "" },
    );
}

test "connection defaults use eshmaki root" {
    const args = [_][]const u8{"alex"};
    const connection = parseConnectionArgs(&args, false).?;
    try std.testing.expectEqualStrings("eshmaki.me", connection.host);
    try std.testing.expectEqualStrings("alex", connection.nick);
    try std.testing.expectEqualStrings("#root", connection.channel);
}

test "built-in host choices include the IRCX service" {
    try std.testing.expectEqualStrings("ircx.us", default_server_alternative);
}

test "empty app arguments open the configured desktop default" {
    const connection = parseConnectionArgs(&.{}, false).?;
    try std.testing.expectEqualStrings("eshmaki.me", connection.host);
    try std.testing.expectEqualStrings("comicchat", connection.nick);
    try std.testing.expectEqualStrings("#root", connection.channel);
}

test "explicit host retains the default channel" {
    const args = [_][]const u8{ "irc.example", "alex" };
    const connection = parseConnectionArgs(&args, false).?;
    try std.testing.expectEqualStrings("irc.example", connection.host);
    try std.testing.expectEqualStrings("#root", connection.channel);
}

test "desktop startup recognizes conversation and locator documents only" {
    try std.testing.expect(isStartupDocument("saved.CCC"));
    try std.testing.expect(isStartupDocument("invite.ccr"));
    try std.testing.expect(!isStartupDocument("rules.ccrules"));
    try std.testing.expect(!isStartupDocument("comicchat.exe"));
}

const ConnectionRuntime = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    sts_path: []const u8,
    sts: cc.net.sts_store.Store,
    session_path: []const u8,
    session: cc.net.session_store.Store,
    preferences_path: []const u8,
    preferences: cc.client.preferences.Store,
    connect_options: cc.net.client.ConnectOptions,
    now_seconds: u64,
    auth: AuthArgs,
    nick: []const u8,
    authzid_storage: ?[]u8 = null,
    authcid_storage: ?[]u8 = null,
    password_storage: ?[]u8 = null,
    credentials: ?cc.net.sasl.Credentials = null,
    preference: [1]cc.net.sasl.Mechanism = undefined,
    preference_len: usize = 0,
    executable: []const u8,

    fn init(gpa: std.mem.Allocator, io: std.Io, args: *const ConnectionArgs, executable: []const u8) !ConnectionRuntime {
        const wall_seconds = std.Io.Clock.real.now(io).toSeconds();
        const now_seconds: u64 = if (wall_seconds > 0) @intCast(wall_seconds) else 0;
        const stores = stores: {
            var sts = try cc.net.sts_store.Store.loadFile(gpa, io, args.sts_file);
            errdefer sts.deinit();
            var session = try cc.net.session_store.Store.loadFile(
                gpa,
                io,
                args.session_file,
                args.host,
                args.auth.user orelse args.nick,
            );
            errdefer session.deinit();
            const preferences = try cc.client.preferences.Store.loadFile(gpa, io, ".comicchat-preferences");
            break :stores .{ .sts = sts, .session = session, .preferences = preferences };
        };
        var runtime = ConnectionRuntime{
            .gpa = gpa,
            .io = io,
            .sts_path = args.sts_file,
            .sts = stores.sts,
            .session_path = args.session_file,
            .session = stores.session,
            .preferences_path = ".comicchat-preferences",
            .preferences = stores.preferences,
            .connect_options = args.options,
            .now_seconds = now_seconds,
            .auth = args.auth,
            .nick = args.nick,
            .executable = executable,
        };
        errdefer runtime.deinit();

        // A cached STS policy always overrides a plaintext command-line
        // request. This is the downgrade protection the persisted policy is
        // intended to provide.
        if (runtime.sts.requiresTls(args.host, now_seconds)) runtime.connect_options.security = .tls;
        try runtime.loadCredentials();
        return runtime;
    }

    fn loadCredentials(self: *ConnectionRuntime) !void {
        if (!self.auth.enabled()) return;
        if (self.connect_options.security == .plaintext) return error.SaslRequiresTls;

        const selected = self.auth.mechanism;
        const external_available = self.auth.external or selected == .external;
        if (!external_available and self.auth.password_file == null) return error.MissingSaslPasswordFile;

        self.authzid_storage = try self.gpa.dupe(u8, self.auth.authzid orelse "");
        self.authcid_storage = try self.gpa.dupe(u8, self.auth.user orelse self.nick);
        if (self.auth.password_file) |path| {
            self.password_storage = try std.Io.Dir.cwd().readFileAlloc(self.io, path, self.gpa, .limited(64 * 1024));
        } else {
            self.password_storage = try self.gpa.dupe(u8, "");
        }
        var password_len = self.password_storage.?.len;
        while (password_len > 0 and
            (self.password_storage.?[password_len - 1] == '\r' or self.password_storage.?[password_len - 1] == '\n'))
        {
            password_len -= 1;
        }
        const password = self.password_storage.?[0..password_len];
        self.credentials = .{
            .authorization_identity = self.authzid_storage.?,
            .authentication_identity = self.authcid_storage.?,
            .password = password,
            .external_available = external_available,
        };
        if (selected) |mechanism| {
            self.preference[0] = mechanism;
            self.preference_len = 1;
        }
    }

    fn registrationOptions(self: *ConnectionRuntime) cc.net.client.RegistrationOptions {
        return .{
            .credentials = if (self.credentials) |*credentials| credentials else null,
            .sasl_preference = if (self.preference_len == 1) self.preference[0..1] else &cc.net.sasl.default_preference,
            .io = self.io,
            .sts = &self.sts,
            .session = &self.session,
            .session_path = self.session_path,
            .now_seconds = self.now_seconds,
        };
    }

    /// Credentials are single-attempt mutable buffers. Reconnects reload the
    /// password file only after the previous SASL session wiped and released
    /// its copy, so no reusable cleartext command or queue entry survives.
    fn registrationOptionsForAttempt(self: *ConnectionRuntime) !cc.net.client.RegistrationOptions {
        if (self.credentials) |credentials| if (credentials.zeroized) {
            self.clearCredentialStorage();
            try self.loadCredentials();
        };
        return self.registrationOptions();
    }

    fn save(self: *ConnectionRuntime) !void {
        try self.sts.saveFile(self.io, self.sts_path);
        try self.session.saveFile(self.io, self.session_path);
        try self.preferences.saveFile(self.io, self.preferences_path);
    }

    fn rebindEndpoint(self: *ConnectionRuntime, host: []const u8, requested_security: cc.net.client.Security) !void {
        try self.session.saveFile(self.io, self.session_path);
        var replacement = try cc.net.session_store.Store.loadFile(
            self.gpa,
            self.io,
            self.session_path,
            host,
            self.auth.user orelse self.nick,
        );
        errdefer replacement.deinit();
        self.session.deinit();
        self.session = replacement;
        self.connect_options.security = requested_security;
        if (self.sts.requiresTls(host, self.now_seconds)) self.connect_options.security = .tls;
    }

    fn deinit(self: *ConnectionRuntime) void {
        if (self.credentials) |*credentials| if (!credentials.zeroized) credentials.zeroize();
        self.clearCredentialStorage();
        self.session.deinit();
        self.preferences.deinit();
        self.sts.deinit();
        self.* = undefined;
    }

    fn clearCredentialStorage(self: *ConnectionRuntime) void {
        if (self.authzid_storage) |storage| {
            std.crypto.secureZero(u8, storage);
            self.gpa.free(storage);
            self.authzid_storage = null;
        }
        if (self.authcid_storage) |storage| {
            std.crypto.secureZero(u8, storage);
            self.gpa.free(storage);
            self.authcid_storage = null;
        }
        if (self.password_storage) |storage| {
            std.crypto.secureZero(u8, storage);
            self.gpa.free(storage);
            self.password_storage = null;
        }
        self.credentials = null;
    }
};

fn monotonicMilliseconds(io: std.Io) u64 {
    const milliseconds = std.Io.Clock.awake.now(io).toMilliseconds();
    return if (milliseconds > 0) @intCast(milliseconds) else 0;
}

fn runCodecDemo(gpa: std.mem.Allocator) !void {
    std.debug.print("Comic Chat portable source port — record codec demo\n\n", .{});

    const record = cc.proto.record;
    var doc: std.ArrayList(u8) = .empty;
    defer doc.deinit(gpa);

    try record.writeRecord(&doc, gpa, "#CHATCONVERSATION", &.{});
    try record.writeRecord(&doc, gpa, "join", &.{ "Anna", "Anna Example" });
    try record.writeComicchar(&doc, gpa, "Anna", "character information unavailable");
    try record.writeSay(&doc, gpa, "Anna", "(G:0 0 0 E:0 0 0 R:1 M:1)", "Hi from Comic Chat!");

    std.debug.print("--- encoded transcript ---\n{s}\n", .{doc.items});
    std.debug.print("--- decoded records ---\n", .{});
    var it = record.DocumentIterator.init(doc.items);
    while (it.next()) |rec| {
        std.debug.print("  {s}", .{@tagName(rec.type)});
        var i: usize = 0;
        while (i < rec.field_count) : (i += 1) std.debug.print(" | {s}", .{rec.fields[i]});
        std.debug.print("\n", .{});
    }
}

fn writeStdout(io: std.Io, bytes: []const u8) !void {
    try std.Io.File.stdout().writeStreamingAll(io, bytes);
}

fn avatarByName(name: []const u8) ?[]const u8 {
    if (cc.comic.strip.avatarByName(name)) |avatar| return avatar;
    const eql = std.ascii.eqlIgnoreCase;
    if (eql(name, "anna")) return @embedFile("assets/testdata/anna.avb");
    if (eql(name, "armando")) return @embedFile("assets/testdata/armando.avb");
    if (eql(name, "bolo")) return @embedFile("assets/testdata/bolo.avb");
    if (eql(name, "cro")) return @embedFile("assets/testdata/cro.avb");
    if (eql(name, "dan")) return @embedFile("assets/testdata/dan.avb");
    if (eql(name, "denise")) return @embedFile("assets/testdata/denise.avb");
    if (eql(name, "hugh")) return @embedFile("assets/testdata/hugh.avb");
    if (eql(name, "jordan")) return @embedFile("assets/testdata/jordan.avb");
    if (eql(name, "kevin")) return @embedFile("assets/testdata/kevin.avb");
    if (eql(name, "kwensa")) return @embedFile("assets/testdata/kwensa.avb");
    if (eql(name, "lance")) return @embedFile("assets/testdata/lance.avb");
    if (eql(name, "lynnea")) return @embedFile("assets/testdata/lynnea.avb");
    if (eql(name, "margaret")) return @embedFile("assets/testdata/margaret.avb");
    if (eql(name, "maynard")) return @embedFile("assets/testdata/maynard.avb");
    if (eql(name, "mike")) return @embedFile("assets/testdata/mike.avb");
    if (eql(name, "rebecca")) return @embedFile("assets/testdata/rebecca.avb");
    if (eql(name, "sage")) return @embedFile("assets/testdata/sage.avb");
    if (eql(name, "scotty")) return @embedFile("assets/testdata/scotty.avb");
    if (eql(name, "susan")) return @embedFile("assets/testdata/susan.avb");
    if (eql(name, "tiki")) return @embedFile("assets/testdata/tiki.avb");
    if (eql(name, "tiki hd")) return @embedFile("assets/generated/tiki-reimagined-hd-v1.avb");
    if (eql(name, "tongtyed")) return @embedFile("assets/testdata/tongtyed.avb");
    if (eql(name, "xeno")) return @embedFile("assets/testdata/xeno.avb");
    if (eql(name, "anna hd")) return @embedFile("assets/generated/anna-reimagined-hd-v1.avb");
    if (eql(name, "armando hd")) return @embedFile("assets/generated/armando-reimagined-hd-v1.avb");
    if (eql(name, "bolo hd")) return @embedFile("assets/generated/bolo-reimagined-hd-v1.avb");
    if (eql(name, "cro hd")) return @embedFile("assets/generated/cro-reimagined-hd-v1.avb");
    if (eql(name, "dan hd")) return @embedFile("assets/generated/dan-reimagined-hd-v1.avb");
    if (eql(name, "denise hd")) return @embedFile("assets/generated/denise-reimagined-hd-v1.avb");
    if (eql(name, "hugh hd")) return @embedFile("assets/generated/hugh-reimagined-hd-v1.avb");
    if (eql(name, "jordan hd")) return @embedFile("assets/generated/jordan-reimagined-hd-v1.avb");
    if (eql(name, "kevin hd")) return @embedFile("assets/generated/kevin-reimagined-hd-v1.avb");
    if (eql(name, "kwensa hd")) return @embedFile("assets/generated/kwensa-reimagined-hd-v1.avb");
    if (eql(name, "lance hd")) return @embedFile("assets/generated/lance-reimagined-hd-v1.avb");
    if (eql(name, "lynnea hd")) return @embedFile("assets/generated/lynnea-reimagined-hd-v1.avb");
    if (eql(name, "margaret hd")) return @embedFile("assets/generated/margaret-reimagined-hd-v1.avb");
    if (eql(name, "maynard hd")) return @embedFile("assets/generated/maynard-reimagined-hd-v1.avb");
    if (eql(name, "mike hd")) return @embedFile("assets/generated/mike-reimagined-hd-v1.avb");
    if (eql(name, "rebecca hd")) return @embedFile("assets/generated/rebecca-reimagined-hd-v1.avb");
    if (eql(name, "sage hd")) return @embedFile("assets/generated/sage-reimagined-hd-v1.avb");
    if (eql(name, "scotty hd")) return @embedFile("assets/generated/scotty-reimagined-hd-v1.avb");
    if (eql(name, "susan hd")) return @embedFile("assets/generated/susan-reimagined-hd-v1.avb");
    if (eql(name, "tongtyed hd")) return @embedFile("assets/generated/tongtyed-reimagined-hd-v1.avb");
    if (eql(name, "xeno hd")) return @embedFile("assets/generated/xeno-reimagined-hd-v1.avb");
    if (eql(name, "anna color")) return @embedFile("assets/generated/anna-color-hd-v1.avb");
    if (eql(name, "armando color")) return @embedFile("assets/generated/armando-color-hd-v1.avb");
    if (eql(name, "bolo color")) return @embedFile("assets/generated/bolo-color-hd-v1.avb");
    if (eql(name, "cro color")) return @embedFile("assets/generated/cro-color-hd-v1.avb");
    if (eql(name, "dan color")) return @embedFile("assets/generated/dan-color-hd-v1.avb");
    if (eql(name, "denise color")) return @embedFile("assets/generated/denise-color-hd-v1.avb");
    if (eql(name, "hugh color")) return @embedFile("assets/generated/hugh-color-hd-v1.avb");
    if (eql(name, "jordan color")) return @embedFile("assets/generated/jordan-color-hd-v1.avb");
    if (eql(name, "kevin color")) return @embedFile("assets/generated/kevin-color-hd-v1.avb");
    if (eql(name, "kwensa color")) return @embedFile("assets/generated/kwensa-color-hd-v1.avb");
    if (eql(name, "lance color")) return @embedFile("assets/generated/lance-color-hd-v1.avb");
    if (eql(name, "lynnea color")) return @embedFile("assets/generated/lynnea-color-hd-v1.avb");
    if (eql(name, "margaret color")) return @embedFile("assets/generated/margaret-color-hd-v1.avb");
    if (eql(name, "maynard color")) return @embedFile("assets/generated/maynard-color-hd-v1.avb");
    if (eql(name, "mike color")) return @embedFile("assets/generated/mike-color-hd-v1.avb");
    if (eql(name, "rebecca color")) return @embedFile("assets/generated/rebecca-color-hd-v1.avb");
    if (eql(name, "sage color")) return @embedFile("assets/generated/sage-color-hd-v1.avb");
    if (eql(name, "scotty color")) return @embedFile("assets/generated/scotty-color-hd-v1.avb");
    if (eql(name, "susan color")) return @embedFile("assets/generated/susan-color-hd-v1.avb");
    if (eql(name, "tiki color")) return @embedFile("assets/generated/tiki-color-hd-v2.avb");
    if (eql(name, "tongtyed color")) return @embedFile("assets/generated/tongtyed-color-hd-v1.avb");
    if (eql(name, "xeno color")) return @embedFile("assets/generated/xeno-color-hd-v1.avb");
    return null;
}

fn bgByName(name: []const u8) ?[]const u8 {
    const eql = std.mem.eql;
    if (eql(u8, name, "field")) return @embedFile("assets/testdata/field.bgb");
    if (eql(u8, name, "volcano")) return @embedFile("assets/testdata/volcano.bgb");
    if (eql(u8, name, "den")) return @embedFile("assets/testdata/den.bgb");
    if (eql(u8, name, "room")) return @embedFile("assets/testdata/room.bgb");
    if (eql(u8, name, "pastoral")) return @embedFile("assets/testdata/pastoral.bgb");
    if (eql(u8, name, "hd apartment")) return @embedFile("assets/generated/hd-apartment.bgb");
    if (eql(u8, name, "hd rooftop")) return @embedFile("assets/generated/hd-rooftop.bgb");
    if (eql(u8, name, "hd cafe")) return @embedFile("assets/generated/hd-cafe.bgb");
    if (eql(u8, name, "hd park")) return @embedFile("assets/generated/hd-park.bgb");
    if (eql(u8, name, "hd space corridor")) return @embedFile("assets/generated/hd-space-corridor.bgb");
    if (eql(u8, name, "hd boardwalk")) return @embedFile("assets/generated/hd-boardwalk.bgb");
    if (eql(u8, name, "hd school hall")) return @embedFile("assets/generated/hd-school-hall.bgb");
    if (eql(u8, name, "hd rainy street")) return @embedFile("assets/generated/hd-rainy-street.bgb");
    if (eql(u8, name, "hd library")) return @embedFile("assets/generated/hd-library.bgb");
    if (eql(u8, name, "hd campsite")) return @embedFile("assets/generated/hd-campsite.bgb");
    if (eql(u8, name, "color apartment")) return @embedFile("assets/generated/color-apartment.bgb");
    if (eql(u8, name, "color rooftop")) return @embedFile("assets/generated/color-rooftop.bgb");
    if (eql(u8, name, "color cafe")) return @embedFile("assets/generated/color-cafe.bgb");
    if (eql(u8, name, "color park")) return @embedFile("assets/generated/color-park.bgb");
    if (eql(u8, name, "color space corridor")) return @embedFile("assets/generated/color-space-corridor.bgb");
    if (eql(u8, name, "color boardwalk")) return @embedFile("assets/generated/color-boardwalk.bgb");
    if (eql(u8, name, "color school hall")) return @embedFile("assets/generated/color-school-hall.bgb");
    if (eql(u8, name, "color rainy street")) return @embedFile("assets/generated/color-rainy-street.bgb");
    if (eql(u8, name, "color library")) return @embedFile("assets/generated/color-library.bgb");
    if (eql(u8, name, "color campsite")) return @embedFile("assets/generated/color-campsite.bgb");
    if (eql(u8, name, "whacky spaceship bridge")) return @embedFile("assets/generated/whacky-spaceship-bridge.bgb");
    if (eql(u8, name, "whacky asteroid diner")) return @embedFile("assets/generated/whacky-asteroid-diner.bgb");
    if (eql(u8, name, "whacky sky island market")) return @embedFile("assets/generated/whacky-sky-island-market.bgb");
    if (eql(u8, name, "whacky underwater dome")) return @embedFile("assets/generated/whacky-underwater-dome.bgb");
    if (eql(u8, name, "whacky friendly castle")) return @embedFile("assets/generated/whacky-friendly-castle.bgb");
    if (eql(u8, name, "whacky pinball interior")) return @embedFile("assets/generated/whacky-pinball-interior.bgb");
    if (eql(u8, name, "whacky cosmic laundromat")) return @embedFile("assets/generated/whacky-cosmic-laundromat.bgb");
    if (eql(u8, name, "whacky cloud train station")) return @embedFile("assets/generated/whacky-cloud-train-station.bgb");
    if (eql(u8, name, "whacky mushroom village")) return @embedFile("assets/generated/whacky-mushroom-village.bgb");
    if (eql(u8, name, "whacky arcade planetarium")) return @embedFile("assets/generated/whacky-arcade-planetarium.bgb");
    return null;
}

/// Emit RGBA pixels (0xAARRGGBB, top-down) as a binary PPM (P6) on stdout.
fn emitPpm(gpa: std.mem.Allocator, io: std.Io, pixels: []const u32, w: u32, h: u32) !void {
    var ppm: std.ArrayList(u8) = .empty;
    defer ppm.deinit(gpa);
    var hdr: [64]u8 = undefined;
    try ppm.appendSlice(gpa, try std.fmt.bufPrint(&hdr, "P6\n{d} {d}\n255\n", .{ w, h }));
    for (pixels) |px| {
        try ppm.append(gpa, @intCast((px >> 16) & 0xff));
        try ppm.append(gpa, @intCast((px >> 8) & 0xff));
        try ppm.append(gpa, @intCast(px & 0xff));
    }
    try writeStdout(io, ppm.items);
}

/// Decode a named embedded background and emit it as PPM on stdout.
fn runRenderBg(gpa: std.mem.Allocator, io: std.Io, name: []const u8) !void {
    const data = bgByName(name) orelse {
        elog("unknown background '{s}' (field|volcano|den|room|pastoral)\n", .{name});
        return;
    };
    var img = try cc.assets.bgb.decodeBackground(gpa, data);
    defer img.deinit(gpa);
    try emitPpm(gpa, io, img.pixels, img.width, img.height);
}

/// Render a one-line source page (implicit title plus conversation panel) and
/// emit it as PPM on stdout.
fn runRenderPanel(gpa: std.mem.Allocator, io: std.Io, bg: []const u8, speaker: []const u8, text: []const u8) !void {
    const data = bgByName(bg) orelse {
        elog("unknown background '{s}'\n", .{bg});
        return;
    };
    var page = try cc.comic.strip.renderWithOptions(
        gpa,
        &.{.{ .speaker = speaker, .text = text }},
        .{ .backdrop = data },
    );
    defer page.deinit(gpa);
    try emitPpm(gpa, io, page.pixels, page.width, page.height);
}

/// Composite an avatar's head + body layers into the full standing figure and
/// emit it as PPM on stdout. (Comic Chat stores head expressions and body
/// gestures separately — the "emotion wheel" — and composites at the neck.)
/// Render a single complete pose centered on white (for creature/totem avatars
/// that have no head/body split).
fn renderSolo(gpa: std.mem.Allocator, io: std.Io, img: cc.assets.bgb.Image) !void {
    const pad: i32 = 10;
    const W: u32 = img.width + 2 * @as(u32, @intCast(pad));
    const H: u32 = img.height + 2 * @as(u32, @intCast(pad));
    var cf = try cc.render.canvas.Canvas.init(gpa, W, H);
    defer cf.deinit(gpa);
    cf.clear(cc.render.canvas.white);
    composite(&cf, img.pixels, img.width, img.height, pad, pad, 0);
    try emitPpm(gpa, io, cf.px, W, H);
}

fn runRenderFigure(gpa: std.mem.Allocator, io: std.Io, name: []const u8, emotion: usize) !void {
    const avb = avatarByName(name) orelse {
        elog("unknown avatar '{s}'\n", .{name});
        return;
    };
    var fig = cc.comic.figure.assemble(gpa, avb, emotion, 0) catch {
        elog("could not assemble figure for '{s}'\n", .{name});
        return;
    };
    defer fig.deinit(gpa);

    const pad: i32 = 10;
    const W: u32 = fig.width + 2 * @as(u32, @intCast(pad));
    const H: u32 = fig.height + 2 * @as(u32, @intCast(pad));
    var c = try cc.render.canvas.Canvas.init(gpa, W, H);
    defer c.deinit(gpa);
    c.clear(cc.render.canvas.white);
    cc.comic.figure.composite(&c, fig.pixels, fig.width, fig.height, pad, pad);
    try emitPpm(gpa, io, c.px, W, H);
}

fn rowWidth(img: cc.assets.bgb.Image, y: i32) i32 {
    if (y < 0 or y >= img.height) return 0;
    const row = @as(usize, @intCast(y)) * img.width;
    var n: i32 = 0;
    var x: u32 = 0;
    while (x < img.width) : (x += 1) {
        if (img.pixels[row + x] >> 24 != 0) n += 1;
    }
    return n;
}

/// First row (top→down) where the figure flares wider than its neck — the
/// shoulder line. The head's bottom is seated here.
fn shoulderRow(img: cc.assets.bgb.Image) i32 {
    const t = topInkRow(img);
    var neck: i32 = std.math.maxInt(i32);
    var y: i32 = t;
    while (y < t + 40 and y < img.height) : (y += 1) {
        const w = rowWidth(img, y);
        if (w > 0 and w < neck) neck = w;
    }
    if (neck == std.math.maxInt(i32)) neck = 1;
    const threshold = @max(@divTrunc(neck * 17, 10), neck + 18);
    y = t;
    while (y < img.height) : (y += 1) {
        if (rowWidth(img, y) >= threshold) return y;
    }
    return t + 20;
}

fn topInkRow(img: cc.assets.bgb.Image) i32 {
    var y: u32 = 0;
    while (y < img.height) : (y += 1) {
        var x: u32 = 0;
        while (x < img.width) : (x += 1) if (img.pixels[y * img.width + x] >> 24 != 0) return @intCast(y);
    }
    return 0;
}

/// Lowest row with ink within ±18px of the neck column `nx` — the base of the
/// neck, ignoring hair/ornaments that hang lower on the sides.
fn headNeckBottom(img: cc.assets.bgb.Image, nx: i32) i32 {
    const x0: u32 = @intCast(@max(@as(i32, 0), nx - 18));
    const x1: u32 = @intCast(@min(@as(i32, @intCast(img.width)), nx + 18));
    var y: i32 = @as(i32, @intCast(img.height)) - 1;
    while (y >= 0) : (y -= 1) {
        const row = @as(usize, @intCast(y)) * img.width;
        var x: u32 = x0;
        while (x < x1) : (x += 1) if (img.pixels[row + x] >> 24 != 0) return y;
    }
    return @as(i32, @intCast(img.height)) - 1;
}

fn botInkRow(img: cc.assets.bgb.Image) i32 {
    var y: i32 = @as(i32, @intCast(img.height)) - 1;
    while (y >= 0) : (y -= 1) {
        const row = @as(usize, @intCast(y)) * img.width;
        var x: u32 = 0;
        while (x < img.width) : (x += 1) if (img.pixels[row + x] >> 24 != 0) return y;
    }
    return @as(i32, @intCast(img.height)) - 1;
}

/// Horizontal centroid of opaque pixels over rows [y0, y1).
fn centroidX(img: cc.assets.bgb.Image, y0: i32, y1: i32) i32 {
    var sum: i64 = 0;
    var cnt: i64 = 0;
    var y: i32 = @max(0, y0);
    const ye: i32 = @min(@as(i32, @intCast(img.height)), y1);
    while (y < ye) : (y += 1) {
        const row = @as(usize, @intCast(y)) * img.width;
        var x: u32 = 0;
        while (x < img.width) : (x += 1) {
            if (img.pixels[row + x] >> 24 != 0) {
                sum += x;
                cnt += 1;
            }
        }
    }
    if (cnt == 0) return @intCast(img.width / 2);
    return @intCast(@divTrunc(sum, cnt));
}

/// Composite a transparent-keyed pose image, skipping the right `crop_r`
/// columns. Black ink always wins: a white pixel never paints over existing
/// black, so an upper layer's white "sticker" can't erase the lower layer's
/// linework (e.g. the body's collar/neck lines under the head).
fn composite(c: *cc.render.canvas.Canvas, src: []const u32, sw: u32, sh: u32, dx: i32, dy: i32, crop_r: u32) void {
    var y: u32 = 0;
    while (y < sh) : (y += 1) {
        var x: u32 = 0;
        while (x + crop_r < sw) : (x += 1) {
            const p = src[y * sw + x];
            if (p >> 24 == 0) continue; // transparent
            const ox = dx + @as(i32, @intCast(x));
            const oy = dy + @as(i32, @intCast(y));
            if (ox < 0 or oy < 0 or ox >= c.width or oy >= c.height) continue;
            const di = @as(usize, @intCast(oy)) * c.width + @as(usize, @intCast(ox));
            c.px[di] = p; // upper layer occludes (head drawn on top of body)
        }
    }
}

/// Connect to IRC, gather channel messages, and render the conversation as a
/// comic strip (each speaker mapped to an avatar). Emits PPM on stdout.
fn runChatComic(
    gpa: std.mem.Allocator,
    io: std.Io,
    host: []const u8,
    port: u16,
    nick: []const u8,
    channel: []const u8,
    maxlines: usize,
    connect_options: cc.net.client.ConnectOptions,
    registration_options: cc.net.client.RegistrationOptions,
) !void {
    var client = try cc.net.client.Client.connectWithOptions(gpa, host, port, connect_options);
    defer client.deinit();
    try client.registerWithOptions(nick, nick, "Comic Chat portable", registration_options);

    var transcript = cc.comic.session.Transcript.init(gpa);
    defer transcript.deinit();
    try transcript.setSelf(nick);
    var metadata_state: ChatState = .{};
    defer metadata_state.deinit(gpa);

    var budget: usize = 0;
    while (budget < 400 and transcript.count() < maxlines) : (budget += 1) {
        const msg = (try client.next()) orelse break;
        _ = try transcript.observeIrc(&msg, channel, nick);
        if (ircxNumericEnabled(&msg)) {
            metadata_state.ircx_data = true;
        }
        if (!metadata_state.join_requested and std.mem.eql(u8, msg.command, "001")) {
            try client.join(channel);
            metadata_state.join_requested = true;
        } else if (std.mem.eql(u8, msg.command, "JOIN")) {
            const who = if (msg.prefix) |p| cc.comic.session.nickFromPrefix(p) else "";
            const joined_channel = msg.param(0) orelse "";
            if (std.ascii.eqlIgnoreCase(who, nick) and std.ascii.eqlIgnoreCase(joined_channel, channel))
                try finishJoin(&client, &transcript, nick, channel, &metadata_state);
        } else if (std.mem.eql(u8, msg.command, "366")) {
            const joined_channel = msg.param(1) orelse msg.param(0) orelse "";
            if (metadata_state.join_requested and std.ascii.eqlIgnoreCase(joined_channel, channel))
                try finishJoin(&client, &transcript, nick, channel, &metadata_state);
        } else if (std.mem.eql(u8, msg.command, "DATA")) {
            const target = msg.param(0) orelse continue;
            const kind = msg.param(1) orelse continue;
            const wire = msg.param(2) orelse continue;
            if (!std.ascii.eqlIgnoreCase(target, channel) or !std.mem.eql(u8, kind, "CCUDI1")) continue;
            const who = if (msg.prefix) |prefix| cc.comic.session.nickFromPrefix(prefix) else continue;
            if (try processComicControl(io, &client, &transcript, who, wire, nick, metadata_state.ircx_data, null)) continue;
            _ = cc.proto.udi.parseAnnotation(wire) catch continue;
            try metadata_state.rememberUdi(gpa, target, who, wire);
        } else if (std.mem.eql(u8, msg.command, "PRIVMSG")) {
            const target = msg.param(0) orelse continue;
            if (!std.ascii.eqlIgnoreCase(target, channel)) continue;
            const text = msg.param(1) orelse continue;
            const who = if (msg.prefix) |p| cc.comic.session.nickFromPrefix(p) else "someone";
            if (try processComicControl(io, &client, &transcript, who, text, nick, metadata_state.ircx_data, null)) continue;
            var pending = metadata_state.takeUdi(target, who);
            defer if (pending) |*entry| entry.deinit(gpa);
            try transcript.addWireMessage(who, text, false, if (pending) |entry| entry.wire else null);
        }
    }
    elog("collected {d} lines\n", .{transcript.count()});
    if (transcript.count() == 0) return;

    var lines = try gpa.alloc(cc.comic.strip.Line, transcript.count());
    defer gpa.free(lines);
    var target_count: usize = 0;
    for (transcript.lines.items) |line| target_count += line.talk_targets.len;
    const targets = try gpa.alloc(cc.comic.strip.Participant, target_count);
    defer gpa.free(targets);
    var target_offset: usize = 0;
    for (transcript.lines.items, 0..) |line, index| {
        const target_start = target_offset;
        for (line.talk_targets) |target| {
            targets[target_offset] = .{
                .identity = target.nick,
                .display_name = target.nick,
                .avatar = target.avatar,
            };
            target_offset += 1;
        }
        lines[index] = .{
            .identity = line.nick,
            .display_name = line.nick,
            .avatar = line.avatar,
            .text = line.text,
            .formatting = line.formatting,
            .pose_text = line.pose_text,
            .pose_state = line.pose_state,
            .talk_targets = targets[target_start..target_offset],
            .modes = line.modes,
        };
    }

    const title_roster = try gpa.alloc(cc.comic.strip.TitleParticipant, transcript.roster.items.len);
    defer gpa.free(title_roster);
    for (transcript.roster.items, 0..) |member, index| title_roster[index] = .{
        .identity = member.nick,
        .display_name = member.nick,
        .avatar = member.avatar,
        .is_self = member.is_self,
        .sends = member.sends,
        .departed = member.departed,
    };

    var strip = try cc.comic.strip.renderWithOptions(gpa, lines, .{ .title_roster = title_roster });
    defer strip.deinit(gpa);
    try emitPpm(gpa, io, strip.pixels, strip.width, strip.height);
}

/// Run the real interactive application using the native platform transport.
fn runInteractive(
    gpa: std.mem.Allocator,
    host: []const u8,
    port: u16,
    nick: []const u8,
    channel: []const u8,
    prefer_wayland: bool,
    display: ?[]const u8,
    startup_document: ?[]const u8,
    runtime: *ConnectionRuntime,
    io: std.Io,
) !void {
    if (comptime builtin.os.tag == .linux) {
        if (prefer_wayland) return runInteractiveWayland(gpa, host, port, nick, channel, startup_document, runtime, io);
        return runInteractiveX11(gpa, host, port, nick, channel, display, startup_document, runtime, io);
    } else if (comptime builtin.os.tag == .windows) {
        return runInteractiveWin32(gpa, host, port, nick, channel, startup_document, runtime, io);
    } else if (comptime builtin.os.tag == .freebsd or builtin.os.tag == .openbsd) {
        return runInteractiveX11(gpa, host, port, nick, channel, display, startup_document, runtime, io);
    } else {
        std.debug.print("the interactive window backend is not implemented for {s} yet\n", .{@tagName(builtin.os.tag)});
    }
}

const PendingUdi = struct {
    target: []u8,
    nick: []u8,
    wire: []u8,

    fn deinit(self: *PendingUdi, gpa: std.mem.Allocator) void {
        gpa.free(self.target);
        gpa.free(self.nick);
        gpa.free(self.wire);
        self.* = undefined;
    }
};

const PendingDcc = struct {
    sender: []u8,
    filename: []u8,
    host_ip: u32,
    port: u16,
    size: ?u64,

    fn deinit(self: *PendingDcc, gpa: std.mem.Allocator) void {
        gpa.free(self.sender);
        gpa.free(self.filename);
        self.* = undefined;
    }
};

const TransferStatus = enum(u8) { waiting, running, completed, cancelled, failed };

fn transferStatusLabel(status: TransferStatus) []const u8 {
    return switch (status) {
        .waiting => "Waiting",
        .running => "Transferring",
        .completed => "Completed",
        .cancelled => "Cancelled",
        .failed => "Failed",
    };
}

const DccWorkerContext = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    mode: enum { receive, send },
    host_ip: u32 = 0,
    port: u16,
    expected_size: ?u64 = null,
    destination: ?[]u8 = null,
    payload: ?[]u8 = null,
    received: std.atomic.Value(u64) = .init(0),
    cancel_requested: std.atomic.Value(bool) = .init(false),
    status: std.atomic.Value(u8) = .init(@intFromEnum(TransferStatus.waiting)),
    ready: std.atomic.Value(bool) = .init(false),
    socket_mutex: std.Io.Mutex = .init,
    active_socket: ?std.Io.net.Socket.Handle = null,

    pub fn cancelled(self: *const DccWorkerContext) bool {
        return self.cancel_requested.load(.acquire);
    }

    pub fn progress(self: *DccWorkerContext, received: u64, _: ?u64) void {
        self.received.store(received, .release);
    }

    pub fn socketOpened(self: *DccWorkerContext, handle: std.Io.net.Socket.Handle) void {
        self.socket_mutex.lockUncancelable(self.io);
        defer self.socket_mutex.unlock(self.io);
        self.active_socket = handle;
        self.ready.store(true, .release);
    }

    pub fn socketClosed(self: *DccWorkerContext) void {
        self.socket_mutex.lockUncancelable(self.io);
        defer self.socket_mutex.unlock(self.io);
        self.active_socket = null;
    }

    fn requestCancel(self: *DccWorkerContext) void {
        self.cancel_requested.store(true, .release);
        self.socket_mutex.lockUncancelable(self.io);
        defer self.socket_mutex.unlock(self.io);
        const handle = self.active_socket orelse return;
        var stream: std.Io.net.Stream = .{ .socket = .{ .handle = handle, .address = .{ .ip4 = .unspecified(0) } } };
        stream.shutdown(self.io, .both) catch {};
    }

    fn deinit(self: *DccWorkerContext) void {
        if (self.destination) |path| self.gpa.free(path);
        if (self.payload) |bytes| self.gpa.free(bytes);
        self.gpa.destroy(self);
    }
};

const DccTransfer = struct {
    context: *DccWorkerContext,
    thread: ?std.Thread,
    terminal_announced: bool = false,

    fn requestCancel(self: *DccTransfer) void {
        self.context.requestCancel();
    }

    fn status(self: *const DccTransfer) TransferStatus {
        return @enumFromInt(self.context.status.load(.acquire));
    }

    fn deinit(self: *DccTransfer) void {
        self.requestCancel();
        if (self.thread) |thread| thread.join();
        self.context.deinit();
        self.* = undefined;
    }
};

const FloodEntry = struct {
    nick: []u8,
    window_start_ms: u64,
    count: u16 = 0,
    ignored: bool = false,
};

fn runDccWorker(context: *DccWorkerContext) void {
    context.status.store(@intFromEnum(TransferStatus.running), .release);
    switch (context.mode) {
        .receive => {
            const bytes = cc.proto.dcc.receiveFileControlled(
                context.gpa,
                context.io,
                context.host_ip,
                context.port,
                context.expected_size,
                context,
            ) catch |err| {
                context.status.store(@intFromEnum(if (err == error.DccCancelled) TransferStatus.cancelled else TransferStatus.failed), .release);
                return;
            };
            defer context.gpa.free(bytes);
            if (context.cancelled()) {
                context.status.store(@intFromEnum(TransferStatus.cancelled), .release);
                return;
            }
            cc.client.files.saveBytesNew(context.io, context.destination.?, bytes) catch {
                context.status.store(@intFromEnum(TransferStatus.failed), .release);
                return;
            };
            context.received.store(bytes.len, .release);
        },
        .send => {
            cc.proto.dcc.sendFileControlled(context.io, context.port, context.payload.?, context) catch |err| {
                context.status.store(@intFromEnum(if (err == error.DccCancelled) TransferStatus.cancelled else TransferStatus.failed), .release);
                return;
            };
            context.received.store(context.payload.?.len, .release);
        },
    }
    context.status.store(@intFromEnum(TransferStatus.completed), .release);
}

const ChatState = struct {
    status: []const u8 = "connecting",
    status_storage: [160]u8 = undefined,
    joined: bool = false,
    join_requested: bool = false,
    avatar_announced: bool = false,
    ircx_data: bool = false,
    pending_udi: std.ArrayList(PendingUdi) = .empty,
    pending_dcc: ?PendingDcc = null,
    transfer: ?DccTransfer = null,
    last_notification_poll_ms: u64 = 0,
    notification_poll_pending: usize = 0,
    notification_current: std.ArrayList([]u8) = .empty,
    notification_previous: std.ArrayList([]u8) = .empty,
    last_transfer_bytes: u64 = 0,
    flood_entries: std.ArrayList(FloodEntry) = .empty,
    desktop_notification: ?[]u8 = null,

    fn deinit(self: *ChatState, gpa: std.mem.Allocator) void {
        for (self.pending_udi.items) |*entry| entry.deinit(gpa);
        self.pending_udi.deinit(gpa);
        if (self.pending_dcc) |*offer| offer.deinit(gpa);
        if (self.transfer) |*transfer| transfer.deinit();
        freeStringList(gpa, &self.notification_current);
        freeStringList(gpa, &self.notification_previous);
        for (self.flood_entries.items) |entry| gpa.free(entry.nick);
        self.flood_entries.deinit(gpa);
        if (self.desktop_notification) |message| gpa.free(message);
        self.* = undefined;
    }

    fn rememberUdi(self: *ChatState, gpa: std.mem.Allocator, target: []const u8, nick: []const u8, wire: []const u8) !void {
        for (self.pending_udi.items) |*entry| {
            if (!std.ascii.eqlIgnoreCase(entry.target, target) or !std.ascii.eqlIgnoreCase(entry.nick, nick)) continue;
            const replacement = try gpa.dupe(u8, wire);
            gpa.free(entry.wire);
            entry.wire = replacement;
            return;
        }
        const owned_target = try gpa.dupe(u8, target);
        errdefer gpa.free(owned_target);
        const owned_nick = try gpa.dupe(u8, nick);
        errdefer gpa.free(owned_nick);
        const owned_wire = try gpa.dupe(u8, wire);
        errdefer gpa.free(owned_wire);
        try self.pending_udi.append(gpa, .{ .target = owned_target, .nick = owned_nick, .wire = owned_wire });
    }

    fn takeUdi(self: *ChatState, target: []const u8, nick: []const u8) ?PendingUdi {
        for (self.pending_udi.items, 0..) |entry, index| {
            if (std.ascii.eqlIgnoreCase(entry.target, target) and std.ascii.eqlIgnoreCase(entry.nick, nick))
                return self.pending_udi.orderedRemove(index);
        }
        return null;
    }

    fn setConnectionFailure(self: *ChatState, err: anyerror) void {
        self.status = std.fmt.bufPrint(
            &self.status_storage,
            "Wire failed ({s}) - open Wire setup",
            .{connectionFailureDetail(err)},
        ) catch "Wire failed - open Wire setup";
    }

    fn rememberDccOffer(self: *ChatState, gpa: std.mem.Allocator, sender: []const u8, offer: cc.proto.dcc.SendOffer) !void {
        if (self.pending_dcc) |*old| old.deinit(gpa);
        self.pending_dcc = .{
            .sender = try gpa.dupe(u8, sender),
            .filename = try gpa.dupe(u8, offer.filename),
            .host_ip = offer.host_ip,
            .port = offer.port,
            .size = offer.size,
        };
    }
};

fn freeStringList(gpa: std.mem.Allocator, list: *std.ArrayList([]u8)) void {
    for (list.items) |value| gpa.free(value);
    list.deinit(gpa);
}

/// JOIN and end-of-NAMES may both confirm the same join. Announce the current
/// deterministic/selected self avatar only once, after either confirmation.
fn finishJoin(
    client: *cc.net.client.Client,
    transcript: *cc.comic.session.Transcript,
    nick: []const u8,
    channel: []const u8,
    state: *ChatState,
) !void {
    state.joined = true;
    state.status = "connected";
    if (state.avatar_announced) return;
    try announceRoomAvatar(client, channel, transcript.resolvedAvatar(nick), state.ircx_data);
    state.avatar_announced = true;
}

/// Modern generated avatars remain a local rendering choice.  The source
/// Comic Chat control only accepts a single legacy avatar token, so normalize
/// a selected family name before putting it on the IRC wire.
fn announceRoomAvatar(
    client: *cc.net.client.Client,
    target: []const u8,
    selected_avatar: []const u8,
    ircx_data: bool,
) !void {
    const wire_avatar = cc.comic.session.avatarAnnouncementName(selected_avatar) orelse return error.UnknownAvatar;
    try client.announceAvatar(target, wire_avatar, ircx_data);
}

const UiEventResult = struct {
    keep_running: bool = true,
    redraw: bool = false,
};

const NetworkEvent = union(enum) {
    none,
    connecting,
    transport_ready,
    retry_scheduled: anyerror,
    sts_upgrading,
};

/// UI-owned nonblocking connection lifecycle. DNS/TCP/proxy/TLS runs inside
/// Transport.Connector; this owner only swaps immutable endpoint snapshots,
/// registers a completed client, and schedules bounded reconnects.
const AsyncNetwork = struct {
    gpa: std.mem.Allocator,
    host: []u8,
    nick: []const u8,
    base_options: cc.net.client.ConnectOptions,
    runtime: *ConnectionRuntime,
    reconnect: cc.net.connection_policy.ReconnectController,
    connector: ?*cc.net.transport.Connector = null,
    client: ?cc.net.client.Client = null,

    fn init(
        gpa: std.mem.Allocator,
        host: []const u8,
        port: u16,
        nick: []const u8,
        runtime: *ConnectionRuntime,
    ) !AsyncNetwork {
        const owned_host = try gpa.dupe(u8, host);
        errdefer gpa.free(owned_host);
        var self = AsyncNetwork{
            .gpa = gpa,
            .host = owned_host,
            .nick = nick,
            .base_options = runtime.connect_options,
            .runtime = runtime,
            .reconnect = .init(port, 0x434f4d4943434841),
        };
        _ = self.reconnect.start();
        try self.startConnector();
        return self;
    }

    fn deinit(self: *AsyncNetwork) void {
        self.stop();
        self.gpa.free(self.host);
        self.* = undefined;
    }

    fn stop(self: *AsyncNetwork) void {
        self.reconnect.cancel();
        if (self.connector) |connector| {
            connector.deinit();
            self.connector = null;
        }
        if (self.client) |*client| {
            client.deinit();
            self.client = null;
        }
    }

    fn reconfigure(self: *AsyncNetwork, host: []const u8, port: u16, security: cc.net.client.Security, now_ms: u64) !void {
        if (host.len == 0 or host.len > 253 or std.mem.indexOfAny(u8, host, " \t\r\n\x00") != null) return error.InvalidHost;
        if (port == 0) return error.InvalidPort;
        const replacement_host = try self.gpa.dupe(u8, host);
        var owns_replacement = true;
        errdefer if (owns_replacement) self.gpa.free(replacement_host);
        try self.runtime.rebindEndpoint(host, security);
        self.stop();
        self.gpa.free(self.host);
        self.host = replacement_host;
        owns_replacement = false;
        self.base_options = self.runtime.connect_options;
        self.reconnect = .init(port, 0x434f4d4943434841);
        _ = self.reconnect.start();
        self.startConnector() catch |err| {
            self.reconnect.disconnected(now_ms);
            return err;
        };
    }

    fn effectiveOptions(self: *const AsyncNetwork) cc.net.client.ConnectOptions {
        var options = self.base_options;
        if (self.reconnect.force_tls) options.security = .tls;
        return options;
    }

    fn startConnector(self: *AsyncNetwork) !void {
        if (self.connector != null or self.client != null) return error.InvalidReconnectState;
        self.connector = try cc.net.transport.Connector.start(
            self.gpa,
            self.host,
            self.reconnect.port,
            self.effectiveOptions(),
        );
    }

    fn tick(self: *AsyncNetwork, now_ms: u64) !NetworkEvent {
        if (self.client) |*client| {
            client.tick(now_ms) catch |err| return self.fail(now_ms, err);
            return .none;
        }
        if (self.connector) |connector| {
            const maybe_transport = connector.poll() catch |err| {
                connector.deinit();
                self.connector = null;
                self.reconnect.disconnected(now_ms);
                return .{ .retry_scheduled = err };
            };
            const connected = maybe_transport orelse return .none;
            connector.deinit();
            self.connector = null;
            var client = cc.net.client.Client.fromTransport(
                self.gpa,
                self.host,
                self.reconnect.port,
                self.effectiveOptions(),
                connected,
            ) catch |err| {
                connected.deinit();
                self.reconnect.disconnected(now_ms);
                return .{ .retry_scheduled = err };
            };
            var owns_client = true;
            defer if (owns_client) client.deinit();
            const registration_options = self.runtime.registrationOptionsForAttempt() catch |err| {
                self.reconnect.disconnected(now_ms);
                return .{ .retry_scheduled = err };
            };
            client.registerWithOptions(self.nick, self.nick, "Comic Chat for Zig", registration_options) catch |err| {
                self.reconnect.disconnected(now_ms);
                return .{ .retry_scheduled = err };
            };
            client.tick(now_ms) catch |err| {
                self.reconnect.disconnected(now_ms);
                return .{ .retry_scheduled = err };
            };
            self.client = client;
            owns_client = false;
            self.reconnect.connected();
            return .transport_ready;
        }
        if (self.reconnect.due(now_ms)) {
            self.startConnector() catch |err| {
                self.reconnect.disconnected(now_ms);
                return .{ .retry_scheduled = err };
            };
            return .connecting;
        }
        return .none;
    }

    fn fail(self: *AsyncNetwork, now_ms: u64, failure: anyerror) NetworkEvent {
        var upgrade_port: ?u16 = null;
        if (self.client) |*client| {
            upgrade_port = client.takeStsUpgradePort();
            client.deinit();
            self.client = null;
        }
        if (upgrade_port) |tls_port| {
            self.reconnect.stsUpgrade(tls_port, now_ms) catch |err| {
                self.reconnect.disconnected(now_ms);
                return .{ .retry_scheduled = err };
            };
            return .sts_upgrading;
        }
        self.reconnect.disconnected(now_ms);
        return .{ .retry_scheduled = failure };
    }

    fn clientPtr(self: *AsyncNetwork) ?*cc.net.client.Client {
        if (self.client) |*client| return client;
        return null;
    }
};

fn applyNetworkEvent(event: NetworkEvent, state: *ChatState) bool {
    return switch (event) {
        .none => false,
        .connecting => changed: {
            state.status = "connecting";
            break :changed true;
        },
        .transport_ready => changed: {
            state.status = "registering";
            break :changed true;
        },
        .retry_scheduled => |err| changed: {
            resetChatConnectionState(state);
            state.setConnectionFailure(err);
            break :changed true;
        },
        .sts_upgrading => changed: {
            resetChatConnectionState(state);
            state.status = "upgrading to TLS";
            break :changed true;
        },
    };
}

fn connectionFailureDetail(err: anyerror) []const u8 {
    const name = @errorName(err);
    if (std.mem.indexOf(u8, name, "Tls") != null or std.mem.indexOf(u8, name, "Certificate") != null) return "TLS";
    if (std.mem.indexOf(u8, name, "Refused") != null) return "refused";
    if (std.mem.indexOf(u8, name, "TimedOut") != null or std.mem.indexOf(u8, name, "Timeout") != null) return "timeout";
    if (std.mem.indexOf(u8, name, "Reset") != null) return "reset";
    if (std.mem.indexOf(u8, name, "Unreachable") != null or std.mem.indexOf(u8, name, "UnknownHost") != null or std.mem.indexOf(u8, name, "Name") != null) return "unreachable";
    return "wire";
}

fn shouldPersistViewLayout(action: cc.client.view.Action) bool {
    return switch (action) {
        .persist_layout => true,
        .toolbar => |index| index == 5 or index == 6 or index == 8,
        else => false,
    };
}

fn persistViewLayout(io: std.Io, view: *cc.client.view.View, preferences: *cc.client.preferences.Store, path: []const u8) !void {
    preferences.setUiLayout(
        view.shell.content_mode == .text,
        view.shell.comic_columns,
        view.shell.show_members,
        view.shell.member_view == .list,
    );
    try preferences.saveFile(io, path);
}

fn resetChatConnectionState(state: *ChatState) void {
    state.joined = false;
    state.join_requested = false;
    state.avatar_announced = false;
    state.notification_poll_pending = 0;
    state.last_notification_poll_ms = 0;
}

fn tickBackgroundFeatures(
    view: *cc.client.view.View,
    network: *AsyncNetwork,
    state: *ChatState,
    workspace: *cc.client.workspace.Workspace,
    now_ms: u64,
) !bool {
    var redraw = false;
    if (state.transfer) |*transfer| {
        const transfer_status = transfer.status();
        const transferred = transfer.context.received.load(.acquire);
        if (transferred != state.last_transfer_bytes) {
            state.last_transfer_bytes = transferred;
            redraw = true;
        }
        if (view.active_dialog == .file_transfer) {
            var amount: [96]u8 = undefined;
            try view.setDialogValueAt(3, try std.fmt.bufPrint(&amount, "{d} / {d} bytes", .{ transferred, transfer.context.expected_size orelse 0 }));
            try view.setDialogValueAt(4, transferStatusLabel(transfer_status));
        }
        if (transfer_status != .waiting and transfer_status != .running and !transfer.terminal_announced) {
            if (transfer.thread) |thread| {
                thread.join();
                transfer.thread = null;
            }
            if (workspace.activeRoom()) |active_room| {
                const message = switch (transfer_status) {
                    .completed => "File transfer completed.",
                    .cancelled => "File transfer cancelled. No partial file was kept.",
                    else => "File transfer failed. No partial file was kept.",
                };
                try active_room.transcript.addWithOptions("File transfer", message, .{ .modes = cc.proto.udi.bm_action });
            }
            transfer.terminal_announced = true;
            redraw = true;
        }
    }

    const client = network.clientPtr() orelse return redraw;
    const preferences = &network.runtime.preferences;
    if (state.notification_poll_pending == 0 and
        preferences.notifications.items.len != 0 and
        !std.ascii.eqlIgnoreCase(preferences.notificationDelivery(), "Disabled") and
        (state.last_notification_poll_ms == 0 or now_ms -| state.last_notification_poll_ms >= 60_000))
    {
        for (state.notification_current.items) |entry| workspace.gpa.free(entry);
        state.notification_current.clearRetainingCapacity();
        for (preferences.notifications.items) |notification| if (notification.enabled) {
            try client.who(notification.nickname);
            state.notification_poll_pending += 1;
        };
        state.last_notification_poll_ms = now_ms;
    }
    return redraw;
}

fn runInteractiveX11(gpa: std.mem.Allocator, host: []const u8, port: u16, nick: []const u8, channel: []const u8, display: ?[]const u8, startup_document: ?[]const u8, runtime: *ConnectionRuntime, io: std.Io) !void {
    return runInteractivePollBackend(cc.platform.x11, gpa, host, port, nick, channel, display, startup_document, runtime, io);
}

fn runInteractiveWayland(gpa: std.mem.Allocator, host: []const u8, port: u16, nick: []const u8, channel: []const u8, startup_document: ?[]const u8, runtime: *ConnectionRuntime, io: std.Io) !void {
    return runInteractivePollBackend(cc.platform.wayland, gpa, host, port, nick, channel, null, startup_document, runtime, io);
}

fn runInteractivePollBackend(
    comptime Backend: type,
    gpa: std.mem.Allocator,
    host: []const u8,
    port: u16,
    nick: []const u8,
    channel: []const u8,
    display: ?[]const u8,
    startup_document: ?[]const u8,
    runtime: *ConnectionRuntime,
    io: std.Io,
) !void {
    const posix = std.posix;

    const win = if (comptime @hasDecl(Backend.Window, "openWithDisplay"))
        try Backend.Window.openWithDisplay(gpa, 960, 720, "Comic Chat / Sunday", display orelse return error.DisplayUnset)
    else
        try Backend.Window.open(gpa, 960, 720, "Comic Chat / Sunday");
    defer win.deinit();
    var view = try cc.client.view.View.init(gpa, win.width, win.height);
    defer view.deinit();
    var workspace = try cc.client.workspace.Workspace.init(gpa, nick);
    defer workspace.deinit();
    _ = try workspace.ensure(channel);
    var state: ChatState = .{};
    defer state.deinit(gpa);
    var network = try AsyncNetwork.init(gpa, host, port, nick, runtime);
    defer network.deinit();
    applyStoredUiPreferences(&view, &network.runtime.preferences);
    if (startup_document) |path| try loadStartupDocument(gpa, io, path, &network, &state, &workspace, nick);

    try presentWorkspace(win, &view, state.status, &workspace);

    var poll_fds = [_]posix.pollfd{
        .{ .fd = win.fd(), .events = posix.POLL.IN | posix.POLL.ERR, .revents = 0 },
        .{ .fd = -1, .events = posix.POLL.IN | posix.POLL.ERR, .revents = 0 },
    };

    // Wayland deliberately leaves key-repeat to the client (see
    // platform/wayland.zig's module doc) — Window.checkRepeat must be
    // polled regularly even with no compositor traffic at all, so a backend
    // that implements it gets a short poll timeout instead of the normal
    // up-to-1000ms one. X11 (no checkRepeat: real auto-repeat arrives as
    // ordinary wire KeyPress events the existing revents check already
    // handles) keeps its current cadence.
    const has_client_side_repeat = @hasDecl(Backend.Window, "checkRepeat");
    const repeat_poll_timeout_ms = 15;

    while (true) {
        var redraw = false;
        const base_timeout: i32 = if (network.clientPtr() == null) 50 else 1000;
        const timeout = if (has_client_side_repeat) @min(base_timeout, repeat_poll_timeout_ms) else base_timeout;
        _ = try posix.poll(&poll_fds, timeout);
        const now_ms = monotonicMilliseconds(io);
        redraw = applyNetworkEvent(try network.tick(now_ms), &state) or redraw;
        redraw = (try tickBackgroundFeatures(&view, &network, &state, &workspace, now_ms)) or redraw;
        poll_fds[1].fd = if (network.clientPtr()) |client| client.fd() else -1;

        if ((poll_fds[0].revents & (posix.POLL.ERR | posix.POLL.HUP | posix.POLL.NVAL)) != 0) return;
        if ((poll_fds[0].revents & posix.POLL.IN) != 0) {
            const event_result = try handleWindowEvent(
                gpa,
                io,
                win,
                try win.nextEvent(),
                &view,
                &network,
                &state,
                &workspace,
                nick,
                channel,
            );
            if (!event_result.keep_running) return;
            redraw = redraw or event_result.redraw;
        }
        if (has_client_side_repeat) {
            if (win.checkRepeat()) |repeat_event| {
                const event_result = try handleWindowEvent(
                    gpa,
                    io,
                    win,
                    repeat_event,
                    &view,
                    &network,
                    &state,
                    &workspace,
                    nick,
                    channel,
                );
                if (!event_result.keep_running) return;
                redraw = redraw or event_result.redraw;
            }
        }

        if (network.clientPtr()) |client| if ((poll_fds[1].revents & posix.POLL.IN) != 0) {
            const maybe_received: ?bool = client.receive() catch |err| failed: {
                redraw = applyNetworkEvent(network.fail(now_ms, err), &state) or redraw;
                poll_fds[1].fd = -1;
                break :failed null;
            };
            if (maybe_received) |received| {
                if (!received) {
                    redraw = applyNetworkEvent(network.fail(now_ms, error.EndOfStream), &state) or redraw;
                    poll_fds[1].fd = -1;
                } else if (network.clientPtr()) |active| {
                    const processed = processWorkspaceMessages(io, active, &view, &runtime.preferences, &workspace, nick, channel, &state) catch |err| failed: {
                        redraw = applyNetworkEvent(network.fail(now_ms, err), &state) or redraw;
                        poll_fds[1].fd = -1;
                        break :failed false;
                    };
                    redraw = redraw or processed;
                    deliverDesktopNotification(win, gpa, &state);
                }
            }
        };
        if (network.clientPtr() != null and
            (poll_fds[1].revents & (posix.POLL.ERR | posix.POLL.HUP | posix.POLL.NVAL)) != 0)
        {
            redraw = applyNetworkEvent(network.fail(now_ms, error.ConnectionResetByPeer), &state) or redraw;
            poll_fds[1].fd = -1;
        }

        if (redraw) try presentWorkspace(win, &view, state.status, &workspace);
    }
}

fn runInteractiveWin32(gpa: std.mem.Allocator, host: []const u8, port: u16, nick: []const u8, channel: []const u8, startup_document: ?[]const u8, runtime: *ConnectionRuntime, io: std.Io) !void {
    const Win32 = cc.platform.win32;

    const win = try Win32.Window.open(gpa, 960, 720, "Comic Chat / Sunday");
    defer win.deinit();
    var view = try cc.client.view.View.init(gpa, win.width, win.height);
    defer view.deinit();
    var workspace = try cc.client.workspace.Workspace.init(gpa, nick);
    defer workspace.deinit();
    _ = try workspace.ensure(channel);
    var state: ChatState = .{};
    defer state.deinit(gpa);
    var network = try AsyncNetwork.init(gpa, host, port, nick, runtime);
    defer network.deinit();
    applyStoredUiPreferences(&view, &network.runtime.preferences);
    if (startup_document) |path| try loadStartupDocument(gpa, io, path, &network, &state, &workspace, nick);
    try presentWorkspace(win, &view, state.status, &workspace);

    while (true) {
        var redraw = false;
        const now_ms = monotonicMilliseconds(io);
        redraw = applyNetworkEvent(try network.tick(now_ms), &state) or redraw;
        redraw = (try tickBackgroundFeatures(&view, &network, &state, &workspace, now_ms)) or redraw;
        while (try win.pollEvent()) |event| {
            const event_result = try handleWindowEvent(
                gpa,
                io,
                win,
                event,
                &view,
                &network,
                &state,
                &workspace,
                nick,
                channel,
            );
            if (!event_result.keep_running) return;
            redraw = redraw or event_result.redraw;
        }

        if (network.clientPtr()) |client| {
            const receive_result = client.receiveTimeout(16) catch |err| disconnected: {
                redraw = applyNetworkEvent(network.fail(now_ms, err), &state) or redraw;
                break :disconnected null;
            };
            if (receive_result) |received| {
                if (!received) {
                    redraw = applyNetworkEvent(network.fail(now_ms, error.EndOfStream), &state) or redraw;
                } else if (network.clientPtr()) |active| {
                    const processed = processWorkspaceMessages(io, active, &view, &runtime.preferences, &workspace, nick, channel, &state) catch |err| failed: {
                        redraw = applyNetworkEvent(network.fail(now_ms, err), &state) or redraw;
                        break :failed false;
                    };
                    redraw = redraw or processed;
                    deliverDesktopNotification(win, gpa, &state);
                }
            }
        } else {
            try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(16), .awake);
        }

        if (redraw) try presentWorkspace(win, &view, state.status, &workspace);
    }
}

fn handleWindowEvent(
    gpa: std.mem.Allocator,
    io: std.Io,
    window: anytype,
    event: anytype,
    view: *cc.client.view.View,
    network: *AsyncNetwork,
    state: *ChatState,
    workspace: *cc.client.workspace.Workspace,
    nick: []const u8,
    channel: []const u8,
) !UiEventResult {
    _ = channel;
    const client = network.clientPtr();
    const room = workspace.activeRoom() orelse return .{};
    const transcript = &room.transcript;
    const editor = &room.editor;
    return switch (event) {
        .close => .{ .keep_running = false },
        .expose => .{ .redraw = true },
        .resize => |size| resized: {
            try view.resize(size.w, size.h);
            break :resized .{ .redraw = true };
        },
        .key => |key_input| key_result: {
            const key = key_input.key;
            if (view.active_dialog != null) {
                if (key_input.modifiers.control) if (view.activeDialogEditor()) |dialog_editor| {
                    if (try handleEditorShortcut(window, dialog_editor, key, workspace))
                        break :key_result .{ .redraw = true };
                };
                if (try view.handleDialogKey(key, key_input.modifiers)) |action| switch (action) {
                    .dialog_browse => |id| try browseDialogFile(gpa, window, view, id),
                    else => try applyDialogAction(gpa, io, window, action, view, network, state, workspace, nick),
                };
                break :key_result .{ .redraw = true };
            }
            const previous_dialog = view.active_dialog;
            if (view.handleMenuAccelerator(key, key_input.modifiers.alt)) |_|
                break :key_result .{ .redraw = true };
            if (view.handleContextMenuKey(key)) |action| {
                const keep_running = switch (action) {
                    .send_expression => expression: {
                        var expression_editor = cc.client.input.Editor.init(gpa);
                        defer expression_editor.deinit();
                        try expression_editor.paste("<Chr>");
                        break :expression try handleInputKey(gpa, cc.platform.event.Key{ .enter = {} }, view, &expression_editor, client, transcript, nick, room.name, room.joined or state.joined, state.ircx_data);
                    },
                    else => true,
                };
                if (previous_dialog != view.active_dialog) try prefillOpenedDialog(view, transcript, editor.text(), &network.runtime.preferences, state, network.clientPtr());
                break :key_result .{ .keep_running = keep_running, .redraw = true };
            }
            if (view.handleFocusedActionKey(key)) |action| {
                const keep_running = switch (action) {
                    .quit => false,
                    .send => try handleWorkspaceInputKey(gpa, io, cc.platform.event.Key{ .enter = {} }, view, editor, client, workspace, nick, state.joined, state.ircx_data, &network.runtime.preferences, network.runtime.preferences_path),
                    .connection => connection: {
                        view.openConnectionDialog(network.host, network.reconnect.port, network.effectiveOptions().security == .tls);
                        break :connection true;
                    },
                    .toolbar => |index| toolbar: {
                        if (index == 1) break :toolbar false;
                        if (index >= 19 and index <= 22) {
                            const control: u8 = switch (index) {
                                19 => cc.comic.formatting.control.bold,
                                20 => cc.comic.formatting.control.italic,
                                21 => cc.comic.formatting.control.underline,
                                else => cc.comic.formatting.control.fixed_pitch,
                            };
                            if (editor.text().len + (if (editor.selection() == null) @as(usize, 1) else @as(usize, 2)) <= 400) try editor.toggleControl(control);
                        }
                        break :toolbar true;
                    },
                    else => true,
                };
                if (previous_dialog != view.active_dialog) try prefillOpenedDialog(view, transcript, editor.text(), &network.runtime.preferences, state, network.clientPtr());
                if (shouldPersistViewLayout(action)) try persistViewLayout(io, view, &network.runtime.preferences, network.runtime.preferences_path);
                break :key_result .{ .keep_running = keep_running, .redraw = true };
            }
            if (view.handleMenuKey(key)) |action| {
                if (previous_dialog != view.active_dialog)
                    try prefillOpenedDialog(view, transcript, editor.text(), &network.runtime.preferences, state, network.clientPtr());
                const keep_running = switch (action) {
                    .quit => false,
                    .connection => connection: {
                        view.openConnectionDialog(network.host, network.reconnect.port, network.effectiveOptions().security == .tls);
                        break :connection true;
                    },
                    .transcript_command => |command| transcript_command: {
                        switch (command) {
                            0 => {
                                try copyTranscriptSelection(workspace, transcript, view.shell.transcriptSelection());
                                syncClipboardToNative(window, workspace);
                            },
                            1 => {
                                const at = if (view.shell.transcriptSelection()) |selection| selection.end else transcript.lines.items.len;
                                try transcript.insertPageBreak(nick, at);
                                view.shell.selectTranscriptLine(transcript.lines.items.len, @min(at, transcript.lines.items.len - 1), false);
                            },
                            else => removeTranscriptSelection(transcript, &view.shell),
                        }
                        break :transcript_command true;
                    },
                    .composer_format => |format_index| format: {
                        const control: u8 = switch (format_index) {
                            0 => cc.comic.formatting.control.bold,
                            1 => cc.comic.formatting.control.italic,
                            else => cc.comic.formatting.control.underline,
                        };
                        if (editor.text().len + (if (editor.selection() == null) @as(usize, 1) else @as(usize, 2)) <= 400)
                            try editor.toggleControl(control);
                        break :format true;
                    },
                    .child_window => child: {
                        spawnRoomWindow(gpa, io, network.runtime.executable, network.host, network.reconnect.port, nick, room.name) catch {
                            view.openDialog(.channel);
                            view.setDialogNotice("The room could not be opened separately.");
                        };
                        break :child true;
                    },
                    else => true,
                };
                if (shouldPersistViewLayout(action)) try persistViewLayout(io, view, &network.runtime.preferences, network.runtime.preferences_path);
                break :key_result .{ .keep_running = keep_running, .redraw = true };
            }
            if (view.handleTranscriptKey(key, transcript.lines.items.len, key_input.modifiers.shift))
                break :key_result .{ .redraw = true };
            if (key_input.modifiers.control and view.shell.focus == .transcript and try handleTranscriptShortcut(window, key, workspace, transcript, view))
                break :key_result .{ .redraw = true };
            if (key == .enter and key_input.modifiers.shift and view.shell.focus == .composer) {
                if (editor.text().len < 400) try editor.insert('\n');
                break :key_result .{ .redraw = true };
            }
            if (view.handleFocusedKey(key, transcript.roster.items.len))
                break :key_result .{ .redraw = true };
            if (key_input.modifiers.control and try handleEditorShortcut(window, editor, key, workspace))
                break :key_result .{ .redraw = true };
            if (key_input.modifiers.shift and key == .tab) {
                view.cycleFocusBackward();
                break :key_result .{ .redraw = true };
            }
            if (key_input.modifiers.shift and handleEditorSelectionKey(editor, key))
                break :key_result .{ .redraw = true };
            break :key_result .{
                .keep_running = try handleWorkspaceInputKey(gpa, io, key, view, editor, client, workspace, nick, state.joined, state.ircx_data, &network.runtime.preferences, network.runtime.preferences_path),
                .redraw = true,
            };
        },
        .pointer => |pointer| pointer_result: {
            if (pointer.kind == .move) break :pointer_result .{ .redraw = view.handlePointerMove(pointer, transcript.roster.items.len) };
            const previous_dialog = view.active_dialog;
            const action = view.handlePointer(pointer, transcript.count(), transcript.roster.items.len);
            if (previous_dialog != view.active_dialog)
                try prefillOpenedDialog(view, transcript, editor.text(), &network.runtime.preferences, state, network.clientPtr());
            const keep_running = switch (action) {
                .quit => false,
                .send => try handleWorkspaceInputKey(gpa, io, cc.platform.event.Key{ .enter = {} }, view, editor, client, workspace, nick, state.joined, state.ircx_data, &network.runtime.preferences, network.runtime.preferences_path),
                .connection => connection: {
                    view.openConnectionDialog(network.host, network.reconnect.port, network.effectiveOptions().security == .tls);
                    break :connection true;
                },
                .toolbar => |index| toolbar: {
                    if (index == 1) break :toolbar false;
                    if (index == 3) {
                        if (workspace.active) |active_index| {
                            const active_room = &workspace.rooms.items[active_index];
                            if (client) |connected_client| try connected_client.part(active_room.name);
                            if (workspace.rooms.items.len > 1) _ = workspace.remove(active_index);
                        }
                    }
                    if (index >= 19 and index <= 22) {
                        const control: u8 = switch (index) {
                            19 => cc.comic.formatting.control.bold,
                            20 => cc.comic.formatting.control.italic,
                            21 => cc.comic.formatting.control.underline,
                            else => cc.comic.formatting.control.fixed_pitch,
                        };
                        if (editor.text().len + (if (editor.selection() == null) @as(usize, 1) else @as(usize, 2)) <= 400)
                            try editor.toggleControl(control);
                    }
                    break :toolbar true;
                },
                .room_tab => |index| workspace.activate(index),
                .composer_cursor => |coordinates| cursor: {
                    view.placeComposerCursor(editor, coordinates.x, coordinates.y);
                    break :cursor true;
                },
                .composer_format => |format_index| format: {
                    const control: u8 = switch (format_index) {
                        0 => cc.comic.formatting.control.bold,
                        1 => cc.comic.formatting.control.italic,
                        else => cc.comic.formatting.control.underline,
                    };
                    if (editor.text().len + (if (editor.selection() == null) @as(usize, 1) else @as(usize, 2)) <= 400)
                        try editor.toggleControl(control);
                    break :format true;
                },
                .transcript_command => |command| transcript_command: {
                    switch (command) {
                        0 => {
                            try copyTranscriptSelection(workspace, transcript, view.shell.transcriptSelection());
                            syncClipboardToNative(window, workspace);
                        },
                        1 => {
                            const at = if (view.shell.transcriptSelection()) |selection| selection.end else transcript.lines.items.len;
                            try transcript.insertPageBreak(nick, at);
                            view.shell.selectTranscriptLine(transcript.lines.items.len, @min(at, transcript.lines.items.len - 1), false);
                        },
                        else => removeTranscriptSelection(transcript, &view.shell),
                    }
                    break :transcript_command true;
                },
                .send_expression => expression: {
                    var expression_editor = cc.client.input.Editor.init(gpa);
                    defer expression_editor.deinit();
                    try expression_editor.paste("<Chr>");
                    break :expression try handleInputKey(gpa, cc.platform.event.Key{ .enter = {} }, view, &expression_editor, client, transcript, nick, room.name, room.joined or state.joined, state.ircx_data);
                },
                .child_window => child: {
                    spawnRoomWindow(gpa, io, network.runtime.executable, network.host, network.reconnect.port, nick, room.name) catch {
                        view.openDialog(.channel);
                        view.setDialogNotice("The room could not be opened separately.");
                    };
                    break :child true;
                },
                .dialog_browse => |id| browse: {
                    try browseDialogFile(gpa, window, view, id);
                    break :browse true;
                },
                .dialog_accept, .dialog_cancel => apply: {
                    try applyDialogAction(gpa, io, window, action, view, network, state, workspace, nick);
                    break :apply true;
                },
                else => true,
            };
            if (shouldPersistViewLayout(action)) try persistViewLayout(io, view, &network.runtime.preferences, network.runtime.preferences_path);
            break :pointer_result .{ .keep_running = keep_running, .redraw = true };
        },
        .other => .{},
    };
}

fn loadStartupDocument(
    gpa: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    network: *AsyncNetwork,
    state: *ChatState,
    workspace: *cc.client.workspace.Workspace,
    nick: []const u8,
) !void {
    if (std.ascii.eqlIgnoreCase(std.fs.path.extension(path), ".ccc")) {
        var transcript = try cc.client.files.loadConversation(io, gpa, path);
        errdefer transcript.deinit();
        try transcript.setSelf(nick);
        const room = workspace.activeRoom() orelse return error.NoActiveRoom;
        room.transcript.deinit();
        room.transcript = transcript;
        try network.runtime.preferences.rememberFile(path);
        try network.runtime.preferences.saveFile(io, network.runtime.preferences_path);
        return;
    }

    const document = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(cc.client.files.max_document_bytes));
    defer gpa.free(document);
    const locator = try cc.client.files.parseLocator(document);
    var room_index = workspace.active orelse return error.NoActiveRoom;
    if (locator.channel) |channel| {
        room_index = try workspace.ensure(channel);
        _ = workspace.activate(room_index);
    }
    if (locator.character) |character| if (cc.comic.session.bundledAvatarByName(character)) |avatar|
        try workspace.rooms.items[room_index].transcript.setAvatar(nick, avatar);
    if (locator.backdrop) |backdrop| if (cc.comic.session.bundledBackdropByName(backdrop)) |bundled| {
        try workspace.rooms.items[room_index].transcript.setBackdrop(bundled);
        try network.runtime.preferences.setBackdrop(bundled);
    };
    if (locator.server) |server| if (!std.ascii.eqlIgnoreCase(server, network.host)) {
        try network.reconfigure(server, network.reconnect.port, network.effectiveOptions().security, monotonicMilliseconds(io));
        resetChatConnectionState(state);
    };
    try network.runtime.preferences.saveFile(io, network.runtime.preferences_path);
}

fn prefillOpenedDialog(
    view: *cc.client.view.View,
    transcript: *const cc.comic.session.Transcript,
    composer_text: []const u8,
    preferences: *const cc.client.preferences.Store,
    state: *const ChatState,
    client: ?*const cc.net.client.Client,
) !void {
    const id = view.active_dialog orelse return;
    switch (id) {
        .settings => {
            try view.setDialogValueAt(0, if (view.appearance.mode == .dark) "Dark studio" else "Light studio");
            try view.setDialogValueAt(1, switch (view.appearance.accent) {
                .cobalt => "Vermillion",
                .violet => "Violet",
                .forest => "Forest",
            });
            try view.setDialogValueAt(2, if (view.appearance.high_contrast) "High contrast" else "Standard");
            try view.setDialogValueAt(3, if (view.shell.content_mode == .comic) "Comic" else "Text");
            var panels: [16]u8 = undefined;
            try view.setDialogValueAt(4, try std.fmt.bufPrint(&panels, "{d} panels", .{view.shell.comic_columns}));
            try view.setDialogValueAt(5, if (view.shell.show_members) "Shown" else "Hidden");
            try view.setDialogValueAt(6, if (view.shell.member_view == .icons) "Icons" else "List");
            try view.setDialogValueAt(7, if (view.status_detailed) "Detailed" else "Compact");
        },
        .about => {
            try view.setDialogValueAt(0, "Comic Chat");
            try view.setDialogValueAt(1, "AGPL-3.0-or-later / printed page");
        },
        .comics_view => {
            try view.setDialogValueAt(0, if (view.shell.content_mode == .comic) "Comic" else "Text");
            var comics_panels: [16]u8 = undefined;
            try view.setDialogValueAt(1, try std.fmt.bufPrint(&comics_panels, "{d} panels", .{view.shell.comic_columns}));
        },
        .character => {
            for (transcript.roster.items) |member| if (member.is_self and !member.departed) {
                for (cc.client.dialogs.choiceOptions(.character, 0)) |option| if (std.ascii.eqlIgnoreCase(option, member.avatar)) {
                    try view.setDialogValueAt(0, option);
                    break;
                };
                break;
            };
            try view.setDialogValueAt(1, view.currentEmotionLabel());
        },
        .personal => {
            try view.setDialogValueAt(0, preferences.profile.items);
            try view.setDialogValueAt(1, preferences.display_name.items);
            try view.setDialogValueAt(2, preferences.homepage.items);
            try view.setDialogValueAt(3, preferences.email.items);
        },
        .background => try view.setDialogValueAt(0, transcript.resolvedBackdrop()),
        .automation => {
            try view.setDialogValueAt(0, preferences.greetingMode());
            try view.setDialogValueAt(1, preferences.greeting.items);
            var number: [16]u8 = undefined;
            try view.setDialogValueAt(2, try std.fmt.bufPrint(&number, "{d}", .{preferences.auto_ignore_count}));
            try view.setDialogValueAt(3, try std.fmt.bufPrint(&number, "{d}", .{preferences.auto_ignore_interval_s}));
        },
        .notifications => {
            try view.setDialogValueAt(1, "*");
            try view.setDialogValueAt(2, "*");
            try view.setDialogValueAt(4, preferences.notificationDelivery());
        },
        .notification_users => {
            var online: std.ArrayList(u8) = .empty;
            defer online.deinit(view.gpa);
            for (state.notification_current.items, 0..) |member, index| {
                if (index != 0) try online.appendSlice(view.gpa, ", ");
                try online.appendSlice(view.gpa, member);
            }
            try view.setDialogValueAt(0, if (online.items.len == 0) "No matching CAST in the last refresh" else online.items);
            if (state.notification_current.items.len != 0) try view.setDialogValueAt(1, state.notification_current.items[0]);
            try view.setDialogValueAt(2, "Refresh");
        },
        .ircx_properties => try view.setDialogValueAt(0, ""),
        .ircx_events => try view.setDialogValueAt(0, "Show"),
        .set_text_font, .text_font => {
            try view.setDialogValueAt(0, preferences.textFont());
            try view.setDialogValueAt(1, preferences.textStyle());
        },
        .choose_color => try view.setDialogValueAt(0, preferences.textColor()),
        .recent_files => {
            if (preferences.recent_files.items.len != 0) try view.setDialogValueAt(0, preferences.recent_files.items[0]);
            try view.setDialogValueAt(1, "Open");
        },
        .favorite_rooms => {
            if (preferences.favorite_rooms.items.len != 0)
                try view.setDialogValueAt(0, preferences.favorite_rooms.items[0]);
            try view.setDialogValueAt(1, "Join");
        },
        .print_preview => {
            try view.setDialogValueAt(0, "comicchat-print.pdf");
            try view.setDialogValueAt(1, "Save PDF");
        },
        .setup => {
            if (view.dialogValueAt(0).len == 0) {
                try view.setDialogValueAt(0, if (client) |connected| connected.host else "eshmaki.me");
                try view.setDialogValueAt(1, "6697");
                try view.setDialogValueAt(2, "Verified TLS");
            }
        },
        .servers => {
            try view.setDialogValueAt(0, onyxWirePreset(if (client) |connected| connected.host else ""));
            try view.setDialogValueAt(1, "6697");
            try view.setDialogValueAt(2, "Verified TLS");
        },
        .connection_features => {
            try view.setDialogValueAt(0, if (client) |connected| if (connected.usesTls()) "Verified TLS" else "Plaintext (unsafe)" else "Off the wire");
            try view.setDialogValueAt(1, if (client) |connected| if (connected.authenticated()) "Signed in" else "Signing in" else "Off the wire");
            try view.setDialogValueAt(2, if (state.ircx_data) "Live" else "Hold");
            if (client) |connected| {
                var capabilities: std.ArrayList(u8) = .empty;
                defer capabilities.deinit(view.gpa);
                try connected.appendEnabledCapabilities(&capabilities, view.gpa);
                try view.setDialogValueAt(3, if (capabilities.items.len == 0) "None yet" else capabilities.items);
            } else {
                try view.setDialogValueAt(3, "Waiting on the wire");
            }
        },
        .rule_sets => {
            try view.setDialogValueAt(0, "Create");
            if (preferences.rule_sets.items.len != 0) try view.setDialogValueAt(1, preferences.rule_sets.items[0]);
        },
        .add_to_sets => {
            if (preferences.rules.items.len != 0) try view.setDialogValueAt(0, preferences.rules.items[0].name);
            if (preferences.rule_sets.items.len != 0) try view.setDialogValueAt(1, preferences.rule_sets.items[0]);
        },
        .rename_loaded_set, .rename_set => if (preferences.rule_sets.items.len != 0)
            try view.setDialogValueAt(0, preferences.rule_sets.items[0]),
        .advanced_event_params => if (preferences.rules.items.len != 0) {
            const rule = preferences.rules.items[0];
            try view.setDialogValueAt(0, rule.name);
            var maximum: [16]u8 = undefined;
            var interval: [16]u8 = undefined;
            try view.setDialogValueAt(1, try std.fmt.bufPrint(&maximum, "{d}", .{rule.maximum_occurrences}));
            try view.setDialogValueAt(2, try std.fmt.bufPrint(&interval, "{d}", .{rule.interval_s}));
        },
        .advanced_rule_settings => if (preferences.rules.items.len != 0) {
            const rule = preferences.rules.items[0];
            try view.setDialogValueAt(0, rule.name);
            try view.setDialogValueAt(1, if (rule.enabled) "Yes" else "No");
            try view.setDialogValueAt(2, if (rule.case_sensitive) "Yes" else "No");
        },
        else => {},
    }
    if (id == .sound) {
        try view.setDialogValueAt(1, composer_text);
        return;
    }
    const selected_index = view.shell.selected_member orelse return;
    if (selected_index >= transcript.roster.items.len) return;
    const member = transcript.roster.items[selected_index];
    if (member.departed) return;
    switch (id) {
        .kick, .invite, .whisper => try view.setDialogValueAt(0, member.nick),
        .file_transfer => try view.setDialogValueAt(1, member.nick),
        .call_link => try view.setDialogValueAt(0, member.nick),
        .member_profile => try view.setDialogValueAt(0, member.nick),
        .ban => {
            var mask: [256]u8 = undefined;
            const value = std.fmt.bufPrint(&mask, "{s}!*@*", .{member.nick}) catch member.nick;
            try view.setDialogValueAt(0, value);
        },
        else => {},
    }
}

fn applyStoredUiPreferences(view: *cc.client.view.View, preferences: *const cc.client.preferences.Store) void {
    view.setContentMode(if (preferences.ui_text_mode) .text else .comic);
    view.shell.setComicColumns(preferences.ui_comic_columns);
    view.shell.setMemberView(if (preferences.ui_member_list) .list else .icons);
    view.shell.setMembersVisible(preferences.ui_members_visible);
    view.setAppearance(.{
        .mode = if (preferences.ui_dark_mode) .dark else .light,
        .accent = switch (preferences.ui_accent) {
            1 => .violet,
            2 => .forest,
            else => .cobalt,
        },
        .high_contrast = preferences.ui_high_contrast,
    }, preferences.ui_status_detailed);
}

fn handleEditorSelectionKey(editor: *cc.client.input.Editor, key: cc.platform.event.Key) bool {
    switch (key) {
        .left => editor.extendLeft(),
        .right => editor.extendRight(),
        .home => editor.extendHome(),
        .end => editor.extendEnd(),
        else => return false,
    }
    return true;
}

fn handleEditorShortcut(
    window: anytype,
    editor: *cc.client.input.Editor,
    key: cc.platform.event.Key,
    workspace: *cc.client.workspace.Workspace,
) !bool {
    const codepoint = switch (key) {
        .char => |ch| if (ch <= 0x7f) std.ascii.toLower(@intCast(ch)) else return false,
        else => return false,
    };
    switch (codepoint) {
        'a' => editor.selectAll(),
        'c' => if (try editor.copySelection()) |text| {
            defer editor.gpa.free(text);
            try workspace.setClipboard(text);
            syncClipboardToNative(window, workspace);
        },
        'x' => if (try editor.cutSelection()) |text| {
            defer editor.gpa.free(text);
            try workspace.setClipboard(text);
            syncClipboardToNative(window, workspace);
        },
        'v' => {
            try syncClipboardFromNative(window, workspace);
            try editor.paste(workspace.clipboard.items);
        },
        'z' => editor.undo(),
        'y' => editor.redo(),
        else => return false,
    }
    return true;
}

fn handleTranscriptShortcut(
    window: anytype,
    key: cc.platform.event.Key,
    workspace: *cc.client.workspace.Workspace,
    transcript: *cc.comic.session.Transcript,
    view: *cc.client.view.View,
) !bool {
    const codepoint = switch (key) {
        .char => |ch| if (ch <= 0x7f) std.ascii.toLower(@intCast(ch)) else return false,
        else => return false,
    };
    switch (codepoint) {
        'a' => {
            if (transcript.lines.items.len != 0) {
                view.shell.selectTranscriptLine(transcript.lines.items.len, 0, false);
                view.shell.selectTranscriptLine(transcript.lines.items.len, transcript.lines.items.len - 1, true);
            }
        },
        'c' => {
            try copyTranscriptSelection(workspace, transcript, view.shell.transcriptSelection());
            syncClipboardToNative(window, workspace);
        },
        else => return false,
    }
    return true;
}

fn syncClipboardToNative(window: anytype, workspace: *cc.client.workspace.Workspace) void {
    if (comptime @hasDecl(@TypeOf(window.*), "writeClipboard"))
        window.writeClipboard(workspace.clipboard.items) catch {};
}

fn syncClipboardFromNative(window: anytype, workspace: *cc.client.workspace.Workspace) !void {
    if (comptime @hasDecl(@TypeOf(window.*), "readClipboard")) {
        const native = window.readClipboard(workspace.gpa) catch return;
        if (native) |text| {
            defer workspace.gpa.free(text);
            if (std.unicode.utf8ValidateSlice(text)) try workspace.setClipboard(text);
        }
    }
}

fn copyTranscriptSelection(
    workspace: *cc.client.workspace.Workspace,
    transcript: *const cc.comic.session.Transcript,
    maybe_selection: ?cc.client.shell.TranscriptSelection,
) !void {
    const selection = maybe_selection orelse return;
    const start = @min(selection.start, transcript.lines.items.len);
    const end = @min(selection.end, transcript.lines.items.len);
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(workspace.gpa);
    for (transcript.lines.items[start..end], 0..) |line, index| {
        if (index != 0) try text.append(workspace.gpa, '\n');
        if (!std.mem.eql(u8, line.text, "<Brk>")) {
            if (line.nick.len != 0) {
                try text.appendSlice(workspace.gpa, line.nick);
                try text.appendSlice(workspace.gpa, ": ");
            }
            try text.appendSlice(workspace.gpa, line.text);
        }
    }
    try workspace.setClipboard(text.items);
}

fn removeTranscriptSelection(transcript: *cc.comic.session.Transcript, shell: *cc.client.shell.State) void {
    const selection = shell.transcriptSelection() orelse return;
    const start = @min(selection.start, transcript.lines.items.len);
    var end = @min(selection.end, transcript.lines.items.len);
    while (end > start) {
        end -= 1;
        _ = transcript.removeLine(end);
    }
    if (transcript.lines.items.len == 0) {
        shell.transcript_cursor = null;
        shell.transcript_anchor = null;
    } else {
        shell.selectTranscriptLine(transcript.lines.items.len, @min(start, transcript.lines.items.len - 1), false);
    }
}

fn applyDialogAction(
    gpa: std.mem.Allocator,
    io: std.Io,
    window: anytype,
    action: cc.client.view.Action,
    view: *cc.client.view.View,
    network: *AsyncNetwork,
    state: *ChatState,
    workspace: *cc.client.workspace.Workspace,
    nick: []const u8,
) !void {
    switch (action) {
        .dialog_cancel => |cancelled_id| {
            if (cancelled_id == .file_transfer) {
                if (state.transfer) |*transfer| transfer.requestCancel();
                if (state.pending_dcc) |*offer| {
                    offer.deinit(gpa);
                    state.pending_dcc = null;
                }
            }
            return;
        },
        else => {},
    }
    const id = switch (action) {
        .dialog_accept => |id| id,
        else => return,
    };
    const value = std.mem.trim(u8, view.dialogValue(), " \t");
    if (id == .setup or id == .servers) {
        const request = parseConnectionDialog(value, view.dialogValueAt(1), view.dialogValueAt(2)) catch |err| {
            view.setDialogNotice(switch (err) {
                error.InvalidHost => "Enter a valid host name without spaces.",
                error.InvalidPort => "Port must be between 1 and 65535.",
            });
            return;
        };
        network.reconfigure(request.host, request.port, request.security, monotonicMilliseconds(io)) catch {
            view.setDialogNotice("Wire failed. Check the host and TLS.");
            return;
        };
        resetChatConnectionState(state);
        state.status = "connecting";
        _ = view.closeDialog();
        return;
    }
    if (cc.client.dialogs.requiresInput(id) and value.len == 0) {
        view.setDialogNotice("Fill the first field before continuing.");
        return;
    }
    const maybe_client = network.clientPtr();
    const room = workspace.activeRoom() orelse return;
    const preferences = &network.runtime.preferences;
    switch (id) {
        .settings => {
            const dark_mode = std.ascii.eqlIgnoreCase(view.dialogValueAt(0), "Dark studio");
            const accent: u8 = cc.client.dialogs.accentIndex(view.dialogValueAt(1));
            const high_contrast = std.ascii.eqlIgnoreCase(view.dialogValueAt(2), "High contrast");
            const text_mode = std.ascii.eqlIgnoreCase(view.dialogValueAt(3), "Text");
            const comic_columns = comicColumnsFromDialog(view.dialogValueAt(4));
            const members_visible = !std.ascii.eqlIgnoreCase(view.dialogValueAt(5), "Hidden");
            const member_list = std.ascii.eqlIgnoreCase(view.dialogValueAt(6), "List");
            const status_detailed = !std.ascii.eqlIgnoreCase(view.dialogValueAt(7), "Compact");
            preferences.setUiLayout(text_mode, comic_columns, members_visible, member_list);
            preferences.setUiTheme(dark_mode, accent, high_contrast, status_detailed);
            try preferences.saveFile(io, network.runtime.preferences_path);
            applyStoredUiPreferences(view, preferences);
        },
        .room_list => {
            const client = maybe_client orelse {
                view.setDialogNotice("Connect before browsing rooms.");
                return;
            };
            const limit = std.mem.trim(u8, view.dialogValueAt(2), " \t");
            if (std.mem.indexOfAny(u8, value, " \r\n\x00") != null) {
                view.setDialogNotice("Separate search terms with commas, not spaces.");
                return;
            }
            if (limit.len != 0) {
                for (limit) |byte| if (!std.ascii.isDigit(byte)) {
                    view.setDialogNotice("The room search limit must be a number.");
                    return;
                };
            }
            try client.listRooms(value, limit, state.ircx_data);
            const room_to_join = std.mem.trim(u8, view.dialogValueAt(1), " \t");
            if (room_to_join.len != 0) {
                const index = workspace.ensure(room_to_join) catch {
                    view.setDialogNotice("Enter a valid room name beginning with # or &.");
                    return;
                };
                _ = workspace.activate(index);
                try client.join(room_to_join);
            }
        },
        .channel => {
            const index = workspace.ensure(value) catch return;
            _ = workspace.activate(index);
            if (maybe_client) |client| try client.joinWithKey(value, view.dialogValueAt(1));
        },
        .invitation => {
            const client = maybe_client orelse {
                view.setDialogNotice("Connect before accepting an invitation.");
                return;
            };
            const index = workspace.ensure(value) catch {
                view.setDialogNotice("Enter a valid room beginning with # or &.");
                return;
            };
            _ = workspace.activate(index);
            try client.join(value);
        },
        .channel_password => {
            const client = maybe_client orelse {
                view.setDialogNotice("Connect before unlocking a room.");
                return;
            };
            try client.joinWithKey(room.name, value);
        },
        .password => {
            view.setDialogNotice("Account passwords stay in the password file.");
            return;
        },
        .channel_create => {
            const creation_modes = std.mem.trim(u8, view.dialogValueAt(2), " \t");
            const limit = std.mem.trim(u8, view.dialogValueAt(3), " \t");
            if (creation_modes.len != 0 and std.mem.indexOfAny(u8, creation_modes, " \r\n\x00") != null) {
                view.setDialogNotice("Enter room options as one word, without spaces.");
                return;
            }
            if (limit.len != 0) {
                for (limit) |byte| if (!std.ascii.isDigit(byte)) {
                    view.setDialogNotice("CAST limit must be a positive number.");
                    return;
                };
                if ((std.fmt.parseUnsigned(u32, limit, 10) catch 0) == 0) {
                    view.setDialogNotice("CAST limit must be a positive number.");
                    return;
                }
            }
            const index = workspace.ensure(value) catch return;
            _ = workspace.activate(index);
            if (maybe_client) |client| {
                try client.create(value, creation_modes, limit, view.dialogValueAt(4));
                const topic = view.dialogValueAt(1);
                if (topic.len != 0) try client.setTopic(value, topic);
            }
        },
        .comics_view => {
            view.setContentMode(if (std.ascii.eqlIgnoreCase(view.dialogValueAt(0), "Text")) .text else .comic);
            view.shell.setComicColumns(comicColumnsFromDialog(view.dialogValueAt(1)));
            try persistViewLayout(io, view, preferences, network.runtime.preferences_path);
        },
        .character => {
            const selected = cc.comic.session.bundledAvatarByName(value) orelse return;
            try room.transcript.setAvatar(nick, selected);
            if (maybe_client) |client| try announceRoomAvatar(client, room.name, selected, state.ircx_data);
        },
        .background => {
            const selected = cc.comic.session.bundledBackdropByName(value) orelse {
                view.setDialogNotice("Choose one of the bundled Comic Chat backdrops.");
                return;
            };
            try room.transcript.setBackdrop(selected);
            try preferences.setBackdrop(selected);
            try preferences.saveFile(io, network.runtime.preferences_path);
            if (maybe_client) |client| try client.syncBackdrop(room.name, selected, null, state.ircx_data);
        },
        .personal => {
            if (hasWireControl(value) or hasWireControl(view.dialogValueAt(1)) or hasWireControl(view.dialogValueAt(2)) or hasWireControl(view.dialogValueAt(3))) {
                view.setDialogNotice("Profile fields must stay on one line.");
                return;
            }
            try preferences.setProfile(value, view.dialogValueAt(1), view.dialogValueAt(2), view.dialogValueAt(3));
            try preferences.saveFile(io, network.runtime.preferences_path);
        },
        .set_text_font, .text_font => {
            try preferences.setTextAppearance(value, view.dialogValueAt(1), preferences.textColor());
            try preferences.saveFile(io, network.runtime.preferences_path);
        },
        .choose_color => {
            preferences.setTextAppearance(preferences.textFont(), preferences.textStyle(), value) catch {
                view.setDialogNotice("Enter a color as #RRGGBB.");
                return;
            };
            try preferences.saveFile(io, network.runtime.preferences_path);
        },
        .channel_properties => {
            const client = maybe_client orelse {
                view.setDialogNotice("Connect before changing room properties.");
                return;
            };
            try client.setTopic(room.name, value);
            const modes = std.mem.trim(u8, view.dialogValueAt(1), " \t");
            if (modes.len != 0) try client.setMode(room.name, modes, "");
            const limit = std.mem.trim(u8, view.dialogValueAt(2), " \t");
            if (limit.len != 0) try client.setMode(room.name, "+l", limit);
            const key = view.dialogValueAt(3);
            if (key.len != 0) try client.setMode(room.name, "+k", key);
        },
        .ircx_properties => {
            if (!state.ircx_data) {
                view.setDialogNotice("Named properties need a live Sunday connection.");
                return;
            }
            const client = maybe_client orelse {
                view.setDialogNotice("Connect before using room properties.");
                return;
            };
            const entity = if (value.len == 0) room.name else value;
            const property = std.mem.trim(u8, view.dialogValueAt(1), " \t");
            const property_value = view.dialogValueAt(2);
            const operation = view.dialogValueAt(3);
            if (std.mem.indexOfAny(u8, entity, " \r\n\x00") != null or std.mem.indexOfAny(u8, property, " \r\n\x00") != null or hasWireControl(property_value)) {
                view.setDialogNotice("Room and property names cannot contain spaces; values must stay on one line.");
                return;
            }
            if (cc.client.dialogs.matchesAny(operation, &.{ "Get common", "Get common properties", "Read common properties" })) {
                try client.queryProperty(entity, "OID,NAME,CREATION,LANGUAGE,TOPIC,SUBJECT,CLIENT,ONJOIN,ONPART,LAG");
            } else if (cc.client.dialogs.matchesAny(operation, &.{ "Get", "Read" })) {
                if (property.len == 0) {
                    view.setDialogNotice("Enter one or more comma-separated property names.");
                    return;
                }
                try client.queryProperty(entity, property);
            } else {
                if (property.len == 0) {
                    view.setDialogNotice("Enter the property to change.");
                    return;
                }
                try client.setProperty(entity, property, if (cc.client.dialogs.matchesAny(operation, &.{ "Delete", "Remove" })) "" else property_value);
            }
        },
        .room_access => {
            if (!state.ircx_data) {
                view.setDialogNotice("Room access needs a live Sunday connection.");
                return;
            }
            const client = maybe_client orelse {
                view.setDialogNotice("Connect before changing room access.");
                return;
            };
            const operation = value;
            const level = cc.client.dialogs.accessLevelToken(view.dialogValueAt(1));
            const mask = std.mem.trim(u8, view.dialogValueAt(2), " \t");
            if (cc.client.dialogs.matchesAny(operation, &.{ "List", "Show" })) {
                try client.accessList(room.name);
            } else if (cc.client.dialogs.matchesAny(operation, &.{ "Delete", "Remove", "Clear", "Clear all" })) {
                if (mask.len == 0 and !cc.client.dialogs.matchesAny(operation, &.{ "Clear", "Clear all" })) {
                    view.setDialogNotice("Enter the name pattern to remove.");
                    return;
                }
                if (!cc.client.dialogs.matchesAny(operation, &.{ "Clear", "Clear all" }) and std.mem.indexOfAny(u8, mask, " \r\n\x00") != null) {
                    view.setDialogNotice("Use one name pattern without spaces.");
                    return;
                }
                if (cc.client.dialogs.matchesAny(operation, &.{ "Clear", "Clear all" }))
                    try client.accessClear(room.name, level)
                else
                    try client.accessDelete(room.name, level, mask);
            } else {
                if (mask.len == 0) {
                    view.setDialogNotice("Enter a name pattern, such as nick!*@*.");
                    return;
                }
                const timeout = std.mem.trim(u8, view.dialogValueAt(3), " \t");
                for (timeout) |byte| if (!std.ascii.isDigit(byte)) {
                    view.setDialogNotice("The access timeout must be a number of minutes.");
                    return;
                };
                if (std.mem.indexOfAny(u8, mask, " \r\n\x00") != null or hasWireControl(view.dialogValueAt(4))) {
                    view.setDialogNotice("Use a single name pattern and a one-line reason.");
                    return;
                }
                try client.accessAdd(room.name, level, mask, view.dialogValueAt(3), view.dialogValueAt(4));
            }
        },
        .ircx_events => {
            if (!state.ircx_data) {
                view.setDialogNotice("Room events need a live Sunday connection.");
                return;
            }
            const client = maybe_client orelse {
                view.setDialogNotice("Connect before managing room events.");
                return;
            };
            const operation = value;
            const event = cc.client.dialogs.eventNameToken(std.mem.trim(u8, view.dialogValueAt(1), " \t"));
            const mask = std.mem.trim(u8, view.dialogValueAt(2), " \t");
            if (std.mem.indexOfAny(u8, mask, " \r\n\x00") != null) {
                view.setDialogNotice("The optional event filter must be one word.");
                return;
            }
            if (cc.client.dialogs.matchesAny(operation, &.{ "List", "Show" })) {
                try client.eventList(event);
            } else {
                if (event.len == 0 or std.mem.indexOfAny(u8, event, " \r\n\x00") != null) {
                    view.setDialogNotice("Choose one event.");
                    return;
                }
                try client.eventChange(std.ascii.eqlIgnoreCase(operation, "Add"), event, mask);
            }
        },
        .automation => {
            const count = std.fmt.parseInt(u16, std.mem.trim(u8, view.dialogValueAt(2), " \t"), 10) catch 8;
            const interval = std.fmt.parseInt(u16, std.mem.trim(u8, view.dialogValueAt(3), " \t"), 10) catch 10;
            if (count == 0 or interval == 0) {
                view.setDialogNotice("Repeat limits must be positive numbers.");
                return;
            }
            if (hasWireControl(view.dialogValueAt(1))) {
                view.setDialogNotice("The greeting must stay on one line.");
                return;
            }
            try preferences.setAutomation(value, view.dialogValueAt(1), count, interval);
            try preferences.saveFile(io, network.runtime.preferences_path);
        },
        .rules, .edit_rule => {
            if (value.len == 0) {
                view.setDialogNotice("Give the rule a name.");
                return;
            }
            if (hasWireControl(view.dialogValueAt(4))) {
                view.setDialogNotice("Automation action values must stay on one line.");
                return;
            }
            try preferences.upsertRule(.{
                .name = value,
                .event = view.dialogValueAt(1),
                .filter = view.dialogValueAt(2),
                .action = view.dialogValueAt(3),
                .value = view.dialogValueAt(4),
            });
            try preferences.saveFile(io, network.runtime.preferences_path);
        },
        .rule_sets => {
            const operation = value;
            if (std.ascii.eqlIgnoreCase(operation, "Rename")) {
                view.openDialog(.rename_set);
                try prefillOpenedDialog(view, &room.transcript, room.editor.text(), preferences, state, maybe_client);
                return;
            }
            if (std.ascii.eqlIgnoreCase(operation, "Assign rule")) {
                view.openDialog(.add_to_sets);
                try prefillOpenedDialog(view, &room.transcript, room.editor.text(), preferences, state, maybe_client);
                return;
            }
            if (cc.client.dialogs.matchesAny(operation, &.{ "Rule limits", "Advanced limits" })) {
                view.openDialog(.advanced_event_params);
                try prefillOpenedDialog(view, &room.transcript, room.editor.text(), preferences, state, maybe_client);
                return;
            }
            if (cc.client.dialogs.matchesAny(operation, &.{ "Rule matching", "Advanced matching" })) {
                view.openDialog(.advanced_rule_settings);
                try prefillOpenedDialog(view, &room.transcript, room.editor.text(), preferences, state, maybe_client);
                return;
            }
            const set_name = std.mem.trim(u8, view.dialogValueAt(1), " \t");
            const path = std.mem.trim(u8, view.dialogValueAt(2), " \t");
            if (std.ascii.eqlIgnoreCase(operation, "Create")) {
                preferences.addRuleSet(set_name) catch {
                    view.setDialogNotice("Enter a unique rule-set name.");
                    return;
                };
            } else if (std.ascii.eqlIgnoreCase(operation, "Import")) {
                preferences.importRulesFile(io, path) catch {
                    view.setDialogNotice("Could not import that .ccrules file.");
                    return;
                };
            } else if (std.ascii.eqlIgnoreCase(operation, "Export")) {
                preferences.exportRulesFile(io, path, if (set_name.len == 0) null else set_name) catch {
                    view.setDialogNotice("Could not export rules to that location.");
                    return;
                };
            }
            try preferences.saveFile(io, network.runtime.preferences_path);
        },
        .create_set => {
            preferences.addRuleSet(value) catch {
                view.setDialogNotice("Enter a unique rule-set name.");
                return;
            };
            try preferences.saveFile(io, network.runtime.preferences_path);
        },
        .rename_loaded_set, .rename_set => {
            preferences.renameRuleSet(value, view.dialogValueAt(1)) catch {
                view.setDialogNotice("Choose an existing set and enter a new name.");
                return;
            };
            try preferences.saveFile(io, network.runtime.preferences_path);
        },
        .add_to_sets => {
            preferences.assignRuleSet(value, view.dialogValueAt(1)) catch {
                view.setDialogNotice("Choose an existing rule and rule set.");
                return;
            };
            try preferences.saveFile(io, network.runtime.preferences_path);
        },
        .advanced_event_params => {
            const maximum = std.fmt.parseInt(u16, std.mem.trim(u8, view.dialogValueAt(1), " \t"), 10) catch {
                view.setDialogNotice("Repeat limit must be a number.");
                return;
            };
            const interval = std.fmt.parseInt(u16, std.mem.trim(u8, view.dialogValueAt(2), " \t"), 10) catch {
                view.setDialogNotice("Repeat window must be a number.");
                return;
            };
            const rule = findRule(preferences, value) orelse {
                view.setDialogNotice("Choose an existing rule.");
                return;
            };
            try preferences.configureRule(value, rule.case_sensitive, maximum, interval);
            try preferences.saveFile(io, network.runtime.preferences_path);
        },
        .advanced_rule_settings => {
            const rule = findRule(preferences, value) orelse {
                view.setDialogNotice("Choose an existing rule.");
                return;
            };
            rule.enabled = std.ascii.eqlIgnoreCase(view.dialogValueAt(1), "Yes");
            try preferences.configureRule(value, std.ascii.eqlIgnoreCase(view.dialogValueAt(2), "Yes"), rule.maximum_occurrences, rule.interval_s);
            try preferences.saveFile(io, network.runtime.preferences_path);
        },
        .notifications => {
            if (value.len == 0) {
                view.setDialogNotice("Enter a name or * pattern to watch.");
                return;
            }
            const delivery = view.dialogValueAt(4);
            try preferences.setNotificationDelivery(delivery);
            try preferences.upsertNotification(.{
                .nickname = value,
                .user_mask = if (view.dialogValueAt(1).len == 0) "*" else view.dialogValueAt(1),
                .host_mask = if (view.dialogValueAt(2).len == 0) "*" else view.dialogValueAt(2),
                .network = view.dialogValueAt(3),
                .enabled = !std.ascii.eqlIgnoreCase(delivery, "Disabled"),
            });
            try preferences.saveFile(io, network.runtime.preferences_path);
            state.last_notification_poll_ms = 0;
        },
        .notification_users => {
            const operation = view.dialogValueAt(2);
            if (std.ascii.eqlIgnoreCase(operation, "Refresh")) {
                state.notification_poll_pending = 0;
                state.last_notification_poll_ms = 0;
                view.setDialogNotice("The saved notification rules will be queried now.");
                return;
            }
            if (std.ascii.eqlIgnoreCase(operation, "Clear list")) {
                for (state.notification_current.items) |entry| gpa.free(entry);
                state.notification_current.clearRetainingCapacity();
                for (state.notification_previous.items) |entry| gpa.free(entry);
                state.notification_previous.clearRetainingCapacity();
            } else if (std.ascii.eqlIgnoreCase(operation, "Join room")) {
                const client = maybe_client orelse {
                    view.setDialogNotice("Connect before joining a room.");
                    return;
                };
                const target_room = std.mem.trim(u8, view.dialogValueAt(3), " \t");
                const index = workspace.ensure(target_room) catch {
                    view.setDialogNotice("Enter a valid room beginning with # or &.");
                    return;
                };
                _ = workspace.activate(index);
                try client.join(target_room);
            } else {
                const member = std.mem.trim(u8, view.dialogValueAt(1), " \t");
                if (!containsIgnoreCase(state.notification_current.items, member)) {
                    view.setDialogNotice("Choose a CAST member from the refreshed online list.");
                    return;
                }
                if (std.ascii.eqlIgnoreCase(operation, "Whisper")) {
                    const selected = selectRosterMember(&room.transcript, member) orelse {
                        view.setDialogNotice("That CAST member is not in this room.");
                        return;
                    };
                    view.shell.selectMember(selected);
                    view.shell.setSayMode(.whisper);
                } else if (cc.client.dialogs.matchesAny(operation, &.{ "Invite CAST", "Invite to current room" })) {
                    const client = maybe_client orelse {
                        view.setDialogNotice("Connect before sending an invitation.");
                        return;
                    };
                    try client.invite(member, room.name);
                }
            }
        },
        .file_transfer => try applyFileTransferDialog(gpa, io, view, maybe_client, state, room),
        .call_link => {
            const client = maybe_client orelse {
                view.setDialogNotice("Connect before sending a call link.");
                return;
            };
            const link = view.dialogValueAt(1);
            if (!validMeetingLink(link)) {
                view.setDialogNotice("Enter a complete HTTPS meeting link without spaces.");
                return;
            }
            if (selectRosterMember(&room.transcript, value) == null) {
                view.setDialogNotice("That CAST member is not in the current room.");
                return;
            }
            try client.sendCallLink(value, link);
        },
        .member_profile => {
            const client = maybe_client orelse {
                view.setDialogNotice("Connect before requesting a CAST profile.");
                return;
            };
            if (selectRosterMember(&room.transcript, value) == null) {
                view.setDialogNotice("That CAST member is not in the current room.");
                return;
            }
            try client.requestProfile(value, state.ircx_data);
            try room.transcript.addWithOptions("Profile", "Profile request sent; the reply will appear here.", .{ .modes = cc.proto.udi.bm_action });
        },
        .sound => {
            const client = maybe_client orelse {
                view.setDialogNotice("Connect before sending a sound.");
                return;
            };
            if (std.mem.indexOfAny(u8, value, "\r\n\x00\x01") != null) {
                view.setDialogNotice("Choose a valid sound name.");
                return;
            }
            const accompanying_message = view.dialogValueAt(1);
            const is_private = view.shell.say_mode == .whisper;
            const target = if (is_private) target: {
                const member_index = view.shell.selected_member orelse {
                    view.setDialogNotice("Choose a CAST member before sending a whisper sound.");
                    return;
                };
                if (member_index >= room.transcript.roster.items.len or room.transcript.roster.items[member_index].departed) {
                    view.setDialogNotice("That CAST member is no longer in the room.");
                    return;
                }
                break :target room.transcript.roster.items[member_index].nick;
            } else room.name;
            try client.sendSound(target, value, accompanying_message);

            var display: std.ArrayList(u8) = .empty;
            defer display.deinit(gpa);
            try display.appendSlice(gpa, nick);
            if (accompanying_message.len != 0) {
                try display.append(gpa, ' ');
                try display.appendSlice(gpa, accompanying_message);
            }
            try display.appendSlice(gpa, " (");
            try display.appendSlice(gpa, value);
            try display.append(gpa, ')');
            try room.transcript.addWithOptions(nick, display.items, .{
                .modes = cc.proto.udi.bm_action | if (is_private) cc.proto.udi.bm_whisper else 0,
            });
            room.editor.clear();
            view.shell.setSayMode(.say);
            view.jumpLatest();
        },
        .nickname => if (maybe_client) |client| try client.changeNick(value),
        .away => if (maybe_client) |client| {
            try client.setAway(value);
            for (workspace.rooms.items) |*joined_room| {
                if (joined_room.joined) try client.sendAwayControl(joined_room.name, value);
            }
        },
        .kick => if (maybe_client) |client| {
            const ban_mask = std.mem.trim(u8, view.dialogValueAt(2), " \t");
            if (ban_mask.len != 0) try client.setBan(room.name, ban_mask);
            try client.kick(room.name, value, view.dialogValueAt(1));
        },
        .ban => if (maybe_client) |client| try client.setBan(room.name, value),
        .invite => if (maybe_client) |client| try client.invite(value, room.name),
        .user_list, .whisper => {
            const selected = selectRosterMember(&room.transcript, value) orelse {
                view.setDialogNotice("That CAST member is not in the current room.");
                return;
            };
            view.shell.selectMember(selected);
            if (id == .whisper) view.shell.setSayMode(.whisper);
        },
        .open_conversation => {
            var loaded = cc.client.files.loadConversation(io, gpa, value) catch {
                view.setDialogNotice("Could not open that conversation file.");
                return;
            };
            errdefer loaded.deinit();
            try loaded.setSelf(nick);
            room.transcript.deinit();
            room.transcript = loaded;
            view.jumpLatest();
            try preferences.rememberFile(value);
            try preferences.saveFile(io, network.runtime.preferences_path);
        },
        .recent_files => {
            if (cc.client.dialogs.matchesAny(view.dialogValueAt(1), &.{ "Remove", "Remove from list" })) {
                _ = preferences.removeRecentFile(value);
                try preferences.saveFile(io, network.runtime.preferences_path);
            } else {
                var loaded = cc.client.files.loadConversation(io, gpa, value) catch {
                    view.setDialogNotice("That recent conversation is no longer available.");
                    return;
                };
                errdefer loaded.deinit();
                try loaded.setSelf(nick);
                room.transcript.deinit();
                room.transcript = loaded;
                view.jumpLatest();
                try preferences.rememberFile(value);
                try preferences.saveFile(io, network.runtime.preferences_path);
            }
        },
        .save_conversation => {
            cc.client.files.saveConversation(io, gpa, value, &room.transcript) catch {
                view.setDialogNotice("Could not save to that location.");
                return;
            };
            try preferences.rememberFile(value);
            try preferences.saveFile(io, network.runtime.preferences_path);
        },
        .open_locator => {
            const document = std.Io.Dir.cwd().readFileAlloc(io, value, gpa, .limited(cc.client.files.max_document_bytes)) catch {
                view.setDialogNotice("Could not open that locator.");
                return;
            };
            defer gpa.free(document);
            const locator = cc.client.files.parseLocator(document) catch {
                view.setDialogNotice("That file is not a valid Comic Chat locator.");
                return;
            };
            var locator_room_index = workspace.active.?;
            const changes_server = if (locator.server) |server| !std.ascii.eqlIgnoreCase(server, network.host) else false;
            if (locator.channel) |located_room| {
                const index = workspace.ensure(located_room) catch {
                    view.setDialogNotice("The locator contains an invalid room.");
                    return;
                };
                _ = workspace.activate(index);
                locator_room_index = index;
                if (!changes_server) if (maybe_client) |client| try client.join(located_room);
            }
            if (locator.character) |character| if (cc.comic.session.bundledAvatarByName(character)) |avatar| {
                try workspace.rooms.items[locator_room_index].transcript.setAvatar(nick, avatar);
            };
            if (locator.backdrop) |backdrop| if (cc.comic.session.bundledBackdropByName(backdrop)) |bundled| {
                try workspace.rooms.items[locator_room_index].transcript.setBackdrop(bundled);
                try preferences.setBackdrop(bundled);
            };
            if (locator.server) |server| if (changes_server) {
                network.reconfigure(server, network.reconnect.port, network.effectiveOptions().security, monotonicMilliseconds(io)) catch {
                    view.setDialogNotice("The locator wire could not be opened.");
                    return;
                };
                resetChatConnectionState(state);
            };
            try preferences.saveFile(io, network.runtime.preferences_path);
        },
        .export_image => {
            const png = cc.render.png.encode(gpa, view.pixels(), view.width(), view.height()) catch {
                view.setDialogNotice("Could not render the current view.");
                return;
            };
            defer gpa.free(png);
            cc.client.files.saveBytesAtomic(io, gpa, value, png) catch {
                view.setDialogNotice("Could not export to that location.");
                return;
            };
        },
        .print_preview => {
            const pdf = cc.render.pdf.encode(gpa, view.pixels(), view.width(), view.height()) catch {
                view.setDialogNotice("Could not create a printable preview.");
                return;
            };
            defer gpa.free(pdf);
            cc.client.files.saveBytesAtomic(io, gpa, value, pdf) catch {
                view.setDialogNotice("Could not save the printable PDF.");
                return;
            };
            const print_action = view.dialogValueAt(1);
            if (std.ascii.eqlIgnoreCase(print_action, "Save PDF and open"))
                openDesktopPath(window, gpa, value) catch {
                    view.setDialogNotice("The PDF was saved, but no document viewer could be opened.");
                    return;
                };
            if (std.ascii.eqlIgnoreCase(print_action, "Save PDF and print"))
                printDesktopPath(window, gpa, value) catch {
                    view.setDialogNotice("The PDF was saved, but no desktop print service was available.");
                    return;
                };
        },
        .favorite_rooms => {
            const operation = view.dialogValueAt(1);
            if (cc.client.dialogs.matchesAny(operation, &.{ "Add this room", "Add current room" })) {
                try preferences.addFavoriteRoom(room.name);
                try preferences.saveFile(io, network.runtime.preferences_path);
            } else if (std.ascii.eqlIgnoreCase(operation, "Remove")) {
                _ = preferences.removeFavoriteRoom(value);
                try preferences.saveFile(io, network.runtime.preferences_path);
            } else {
                const index = workspace.ensure(value) catch {
                    view.setDialogNotice("Enter a valid favorite room beginning with # or &.");
                    return;
                };
                _ = workspace.activate(index);
                if (maybe_client) |client| try client.join(value);
            }
        },
        else => {},
    }
    _ = view.closeDialog();
}

fn browseDialogFile(gpa: std.mem.Allocator, window: anytype, view: *cc.client.view.View, id: cc.client.dialogs.Id) !void {
    if (comptime !@hasDecl(@TypeOf(window.*), "chooseFile")) {
        view.setDialogNotice("Native file selection is unavailable on this platform; enter a path.");
        return;
    } else {
        const save = switch (id) {
            .save_conversation, .export_image, .print_preview => true,
            .file_transfer => std.ascii.eqlIgnoreCase(view.dialogValueAt(0), "Receive offer"),
            .rule_sets => std.ascii.eqlIgnoreCase(view.dialogValueAt(0), "Export"),
            else => false,
        };
        const field: usize = switch (id) {
            .file_transfer, .rule_sets => 2,
            else => 0,
        };
        const selected = window.chooseFile(gpa, save, cc.client.dialogs.get(id).title) catch {
            view.setDialogNotice("The desktop file picker could not be opened; enter a path.");
            return;
        };
        if (selected) |path| {
            defer gpa.free(path);
            try view.setDialogValueAt(field, path);
            view.setDialogNotice("");
        }
    }
}

fn openDesktopPath(window: anytype, gpa: std.mem.Allocator, path: []const u8) !void {
    if (comptime @hasDecl(@TypeOf(window.*), "openPath")) return window.openPath(gpa, path);
    return error.DesktopServiceUnavailable;
}

fn printDesktopPath(window: anytype, gpa: std.mem.Allocator, path: []const u8) !void {
    if (comptime @hasDecl(@TypeOf(window.*), "printPath")) return window.printPath(gpa, path);
    return error.DesktopServiceUnavailable;
}

fn spawnRoomWindow(gpa: std.mem.Allocator, io: std.Io, executable: []const u8, host: []const u8, port: u16, nick: []const u8, room: []const u8) !void {
    var port_buffer: [5]u8 = undefined;
    const port_text = try std.fmt.bufPrint(&port_buffer, "{d}", .{port});
    const child = try gpa.create(std.process.Child);
    errdefer gpa.destroy(child);
    child.* = try std.process.spawn(io, .{
        .argv = &.{ executable, "app", host, port_text, nick, room },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
        .create_no_window = false,
    });
    errdefer child.kill(io);
    const reaper = try std.Thread.spawn(.{}, reapRoomWindow, .{ gpa, io, child });
    reaper.detach();
}

fn reapRoomWindow(gpa: std.mem.Allocator, io: std.Io, child: *std.process.Child) void {
    _ = child.wait(io) catch {};
    gpa.destroy(child);
}

fn applyFileTransferDialog(
    gpa: std.mem.Allocator,
    io: std.Io,
    view: *cc.client.view.View,
    maybe_client: ?*cc.net.client.Client,
    state: *ChatState,
    room: *cc.client.workspace.Room,
) !void {
    if (state.transfer) |*existing| switch (existing.status()) {
        .waiting, .running => {
            view.setDialogNotice("A file transfer is already running. Cancel it before starting another.");
            return;
        },
        else => {
            existing.deinit();
            state.transfer = null;
        },
    };

    const direction = view.dialogValueAt(0);
    if (std.ascii.eqlIgnoreCase(direction, "Receive offer")) {
        const pending = state.pending_dcc orelse {
            view.setDialogNotice("There is no pending incoming file offer.");
            return;
        };
        const destination = std.mem.trim(u8, view.dialogValueAt(2), " \t");
        if (!validTransferPath(destination)) {
            view.setDialogNotice("Choose a non-empty save path without control characters.");
            return;
        }
        const exists = if (std.Io.Dir.cwd().statFile(io, destination, .{})) |_| true else |err| switch (err) {
            error.FileNotFound => false,
            else => {
                view.setDialogNotice("The save path cannot be checked safely.");
                return;
            },
        };
        if (exists) {
            view.setDialogNotice("That file already exists. Choose a new save path.");
            return;
        }
        const owned_destination = try gpa.dupe(u8, destination);
        errdefer gpa.free(owned_destination);
        const context = try gpa.create(DccWorkerContext);
        errdefer gpa.destroy(context);
        context.* = .{
            .gpa = gpa,
            .io = io,
            .mode = .receive,
            .host_ip = pending.host_ip,
            .port = pending.port,
            .expected_size = pending.size,
            .destination = owned_destination,
        };
        const thread = try std.Thread.spawn(.{}, runDccWorker, .{context});
        state.transfer = .{ .context = context, .thread = thread };
        if (state.pending_dcc) |*offer| offer.deinit(gpa);
        state.pending_dcc = null;
        room.transcript.addWithOptions("File transfer", "Incoming transfer started. Open the file only after it completes.", .{ .modes = cc.proto.udi.bm_action }) catch {};
        return;
    }

    const client = maybe_client orelse {
        view.setDialogNotice("Connect before sending a file.");
        return;
    };
    const target = std.mem.trim(u8, view.dialogValueAt(1), " \t");
    if (selectRosterMember(&room.transcript, target) == null) {
        view.setDialogNotice("Choose a CAST member who is still in the current room.");
        return;
    }
    const path = std.mem.trim(u8, view.dialogValueAt(2), " \t");
    if (!validTransferPath(path)) {
        view.setDialogNotice("Choose a valid file path.");
        return;
    }
    const payload = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(cc.client.files.max_document_bytes)) catch {
        view.setDialogNotice("That file could not be read or is larger than 16 MiB.");
        return;
    };
    errdefer gpa.free(payload);
    if (payload.len == 0) {
        gpa.free(payload);
        view.setDialogNotice("Empty files cannot be sent.");
        return;
    }
    const host_ip = parseIpv4Number(view.dialogValueAt(3)) orelse {
        view.setDialogNotice("Enter the IPv4 address the other CAST member should connect to.");
        return;
    };
    const port = std.fmt.parseInt(u16, std.mem.trim(u8, view.dialogValueAt(4), " \t"), 10) catch {
        view.setDialogNotice("Enter a transfer port between 1 and 65535.");
        return;
    };
    if (port == 0) {
        view.setDialogNotice("Enter a transfer port between 1 and 65535.");
        return;
    }
    var filename_buffer: [192]u8 = undefined;
    const filename = safeIncomingFilename(path, &filename_buffer);
    const context = try gpa.create(DccWorkerContext);
    errdefer gpa.destroy(context);
    context.* = .{ .gpa = gpa, .io = io, .mode = .send, .port = port, .expected_size = payload.len, .payload = payload };
    const thread = try std.Thread.spawn(.{}, runDccWorker, .{context});
    state.transfer = .{ .context = context, .thread = thread };
    var attempts: u8 = 0;
    while (!context.ready.load(.acquire) and attempts < 100 and (state.transfer.?.status() == .waiting or state.transfer.?.status() == .running)) : (attempts += 1)
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(5), .awake) catch {
            state.transfer.?.deinit();
            state.transfer = null;
            view.setDialogNotice("The transfer listener was interrupted before it became ready.");
            return;
        };
    if (!context.ready.load(.acquire)) {
        state.transfer.?.deinit();
        state.transfer = null;
        view.setDialogNotice("The transfer port could not be opened.");
        return;
    }
    client.offerFile(target, .{ .filename = filename, .host_ip = host_ip, .port = port, .size = payload.len }) catch {
        state.transfer.?.deinit();
        state.transfer = null;
        view.setDialogNotice("The file offer could not be sent.");
        return;
    };
    room.transcript.addWithOptions("File transfer", "Outgoing transfer is waiting for the recipient.", .{ .modes = cc.proto.udi.bm_action }) catch {};
}

fn validTransferPath(path: []const u8) bool {
    return path.len > 0 and path.len <= 1024 and std.mem.indexOfAny(u8, path, "\r\n\x00") == null;
}

fn parseIpv4Number(text: []const u8) ?u32 {
    const trimmed = std.mem.trim(u8, text, " \t");
    if (std.mem.indexOfScalar(u8, trimmed, '.')) |_| {
        var parts = std.mem.splitScalar(u8, trimmed, '.');
        var bytes: [4]u8 = undefined;
        var count: usize = 0;
        while (parts.next()) |part| {
            if (count >= bytes.len or part.len == 0) return null;
            bytes[count] = std.fmt.parseInt(u8, part, 10) catch return null;
            count += 1;
        }
        if (count != 4) return null;
        return std.mem.readInt(u32, &bytes, .big);
    }
    return std.fmt.parseInt(u32, trimmed, 10) catch null;
}

fn selectRosterMember(transcript: *const cc.comic.session.Transcript, nick: []const u8) ?usize {
    for (transcript.roster.items, 0..) |member, index| {
        if (!member.departed and std.ascii.eqlIgnoreCase(member.nick, nick)) return index;
    }
    return null;
}

fn findRule(preferences: *cc.client.preferences.Store, name: []const u8) ?*cc.client.preferences.Rule {
    for (preferences.rules.items) |*rule| if (std.ascii.eqlIgnoreCase(rule.name, name)) return rule;
    return null;
}

fn comicColumnsFromDialog(value: []const u8) u8 {
    const trimmed = std.mem.trim(u8, value, " \t");
    if (trimmed.len == 0 or trimmed[0] < '1' or trimmed[0] > '6') return 4;
    return trimmed[0] - '0';
}

const ConnectionDialogRequest = struct {
    host: []const u8,
    port: u16,
    security: cc.net.client.Security,
};

fn onyxWirePreset(host: []const u8) []const u8 {
    if (std.ascii.eqlIgnoreCase(host, "ircx.us")) return "ircx.us";
    return "eshmaki.me";
}

fn parseConnectionDialog(host_text: []const u8, port_text: []const u8, security_text: []const u8) error{ InvalidHost, InvalidPort }!ConnectionDialogRequest {
    const host = std.mem.trim(u8, host_text, " \t");
    if (host.len == 0 or host.len > 253 or std.mem.indexOfAny(u8, host, " \t\r\n\x00") != null) return error.InvalidHost;
    const port = std.fmt.parseInt(u16, std.mem.trim(u8, port_text, " \t"), 10) catch return error.InvalidPort;
    if (port == 0) return error.InvalidPort;
    return .{
        .host = host,
        .port = port,
        .security = if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, security_text, " \t"), "Plaintext (unsafe)")) .plaintext else .tls,
    };
}

test "connection dialog validates a usable endpoint" {
    const secure = try parseConnectionDialog(" eshmaki.me ", "6697", "Verified TLS");
    try std.testing.expectEqualStrings("eshmaki.me", secure.host);
    try std.testing.expectEqual(@as(u16, 6697), secure.port);
    try std.testing.expectEqual(cc.net.client.Security.tls, secure.security);
    const plaintext = try parseConnectionDialog("irc.example", "6667", "Plaintext (unsafe)");
    try std.testing.expectEqual(cc.net.client.Security.plaintext, plaintext.security);
    try std.testing.expectError(error.InvalidHost, parseConnectionDialog("bad host", "6697", "Verified TLS"));
    try std.testing.expectError(error.InvalidPort, parseConnectionDialog("eshmaki.me", "0", "Verified TLS"));
    try std.testing.expectError(error.InvalidPort, parseConnectionDialog("eshmaki.me", "nope", "Verified TLS"));
}

test "wire list preset prefers live Onyx nodes" {
    try std.testing.expectEqualStrings("eshmaki.me", onyxWirePreset(""));
    try std.testing.expectEqualStrings("eshmaki.me", onyxWirePreset("example.test"));
    try std.testing.expectEqualStrings("eshmaki.me", onyxWirePreset("eshmaki.me"));
    try std.testing.expectEqualStrings("ircx.us", onyxWirePreset("IRCX.US"));
}

test "connection failures remain actionable" {
    var state: ChatState = .{ .joined = true, .join_requested = true };
    try std.testing.expect(applyNetworkEvent(.{ .retry_scheduled = error.ConnectionRefused }, &state));
    try std.testing.expect(!state.joined);
    try std.testing.expectEqualStrings("refused", connectionFailureDetail(error.ConnectionRefused));
    try std.testing.expectEqualStrings("TLS", connectionFailureDetail(error.TlsHandshakeFailed));
    try std.testing.expect(std.mem.indexOf(u8, state.status, "refused") != null);
    try std.testing.expect(std.mem.indexOf(u8, state.status, "Wire failed") != null);
    try std.testing.expect(std.mem.indexOf(u8, state.status, "open Wire setup") != null);
}

test "comic view choices remain bounded and roster selection ignores departed users" {
    try std.testing.expectEqual(@as(u8, 4), comicColumnsFromDialog("4 panels"));
    try std.testing.expectEqual(@as(u8, 6), comicColumnsFromDialog(" 6 panels"));
    try std.testing.expectEqual(@as(u8, 4), comicColumnsFromDialog("Fit window"));

    var transcript = cc.comic.session.Transcript.init(std.testing.allocator);
    defer transcript.deinit();
    try transcript.setSelf("Me");
    var names = cc.net.message.parse(":server 353 Me = #root :Me Alice Bob");
    try std.testing.expect(try transcript.observeIrc(&names, "#root", "Me"));
    try std.testing.expect(selectRosterMember(&transcript, "alice") != null);
    var part = cc.net.message.parse(":Alice!u@h PART #root :gone");
    try std.testing.expect(try transcript.observeIrc(&part, "#root", "Me"));
    try std.testing.expect(selectRosterMember(&transcript, "alice") == null);
}

fn handleWorkspaceInputKey(
    gpa: std.mem.Allocator,
    io: std.Io,
    key: cc.platform.event.Key,
    view: *cc.client.view.View,
    editor: *cc.client.input.Editor,
    maybe_client: ?*cc.net.client.Client,
    workspace: *cc.client.workspace.Workspace,
    nick: []const u8,
    connected: bool,
    ircx_data: bool,
    preferences: *cc.client.preferences.Store,
    preferences_path: []const u8,
) !bool {
    if (key == .enter and editor.text().len > 0) {
        const text = editor.text();
        if (std.mem.indexOfScalar(u8, text, '\n') != null) {
            const multiline = try editor.take();
            defer gpa.free(multiline);
            var lines = std.mem.splitScalar(u8, multiline, '\n');
            while (lines.next()) |line| {
                if (line.len == 0) continue;
                try editor.paste(line);
                if (!try handleWorkspaceInputKey(gpa, io, cc.platform.event.Key{ .enter = {} }, view, editor, maybe_client, workspace, nick, connected, ircx_data, preferences, preferences_path)) return false;
            }
            return true;
        }
        if (std.mem.startsWith(u8, text, "/save ")) {
            const path = std.mem.trim(u8, text[6..], " \t");
            const room = workspace.activeRoom() orelse return true;
            cc.client.files.saveConversation(io, gpa, path, &room.transcript) catch return true;
            const consumed = try editor.take();
            gpa.free(consumed);
            return true;
        }
        if (std.mem.startsWith(u8, text, "/open ")) {
            const path = std.mem.trim(u8, text[6..], " \t");
            var loaded = cc.client.files.loadConversation(io, gpa, path) catch return true;
            errdefer loaded.deinit();
            try loaded.setSelf(nick);
            const room = workspace.activeRoom() orelse return true;
            room.transcript.deinit();
            room.transcript = loaded;
            const consumed = try editor.take();
            gpa.free(consumed);
            view.jumpLatest();
            return true;
        }
        if (std.mem.startsWith(u8, text, "/export ")) {
            const path = std.mem.trim(u8, text[8..], " \t");
            const png = cc.render.png.encode(gpa, view.pixels(), view.width(), view.height()) catch return true;
            defer gpa.free(png);
            cc.client.files.saveBytesAtomic(io, gpa, path, png) catch return true;
            const consumed = try editor.take();
            gpa.free(consumed);
            return true;
        }
        if (std.mem.startsWith(u8, text, "/join ")) {
            const name = std.mem.trim(u8, text[6..], " \t");
            const index = workspace.ensure(name) catch return true;
            _ = workspace.activate(index);
            if (maybe_client) |client| try client.join(name);
            const consumed = try editor.take();
            gpa.free(consumed);
            return true;
        }
        if (std.mem.startsWith(u8, text, "/switch ")) {
            const name = std.mem.trim(u8, text[8..], " \t");
            if (workspace.find(name)) |index| _ = workspace.activate(index);
            const consumed = try editor.take();
            gpa.free(consumed);
            return true;
        }
        if (std.mem.eql(u8, text, "/part")) {
            if (workspace.active) |index| {
                if (workspace.rooms.items.len > 1) {
                    if (maybe_client) |client| try client.part(workspace.rooms.items[index].name);
                    _ = workspace.remove(index);
                }
            }
            const consumed = try editor.take();
            gpa.free(consumed);
            return true;
        }
    }
    const room = workspace.activeRoom() orelse return true;
    const mode = view.shell.content_mode;
    const members = view.shell.show_members;
    const columns = view.shell.comic_columns;
    const keep_running = try handleInputKey(gpa, key, view, editor, maybe_client, &room.transcript, nick, room.name, room.joined or connected, ircx_data);
    if (view.shell.content_mode != mode or view.shell.show_members != members or view.shell.comic_columns != columns)
        try persistViewLayout(io, view, preferences, preferences_path);
    return keep_running;
}

fn processWorkspaceMessages(
    io: std.Io,
    client: *cc.net.client.Client,
    view: *cc.client.view.View,
    preferences: *cc.client.preferences.Store,
    workspace: *cc.client.workspace.Workspace,
    nick: []const u8,
    channel: []const u8,
    state: *ChatState,
) !bool {
    var redraw = false;
    while (try client.bufferedNext()) |msg| {
        if (std.ascii.eqlIgnoreCase(msg.command, "QUIT") or std.ascii.eqlIgnoreCase(msg.command, "NICK")) {
            for (workspace.rooms.items) |*room| redraw = (try room.transcript.observeIrc(&msg, room.name, nick)) or redraw;
        } else if (messageRoom(&msg)) |room_name| {
            if (room_name.len > 1 and (room_name[0] == '#' or room_name[0] == '&')) {
                const room_index = try workspace.ensure(room_name);
                redraw = (try workspace.rooms.items[room_index].transcript.observeIrc(&msg, room_name, nick)) or redraw;
            }
        }
        if (std.ascii.eqlIgnoreCase(msg.command, "PART")) {
            const room_name = msg.param(0) orelse "";
            const who = if (msg.prefix) |prefix| cc.comic.session.nickFromPrefix(prefix) else "";
            if (workspace.find(room_name)) |room_index| _ = try runPersistentRules(workspace.gpa, client, &workspace.rooms.items[room_index].transcript, preferences, "Leave", who, room_name, msg.param(1) orelse "");
        } else if (std.ascii.eqlIgnoreCase(msg.command, "KICK")) {
            const room_name = msg.param(0) orelse "";
            const who = msg.param(1) orelse "";
            if (workspace.find(room_name)) |room_index| _ = try runPersistentRules(workspace.gpa, client, &workspace.rooms.items[room_index].transcript, preferences, "Kick", who, room_name, msg.param(2) orelse "");
        } else if (std.ascii.eqlIgnoreCase(msg.command, "INVITE")) {
            if (workspace.activeRoom()) |active_room| _ = try runPersistentRules(workspace.gpa, client, &active_room.transcript, preferences, "Invitation", if (msg.prefix) |prefix| cc.comic.session.nickFromPrefix(prefix) else "", msg.param(1) orelse "", "");
        }
        if (std.mem.eql(u8, msg.command, "352")) {
            try collectNotificationWho(workspace.gpa, state, preferences, &msg, client.host);
            continue;
        }
        if (std.mem.eql(u8, msg.command, "315")) {
            redraw = (try finishNotificationWho(workspace.gpa, state, workspace)) or redraw;
            continue;
        }
        if (isVisibleServerWorkflowReply(msg.command)) {
            if (workspace.activeRoom()) |active_room| try appendServerWorkflowReply(&active_room.transcript, &msg);
            redraw = true;
            continue;
        }
        if (ircxNumericEnabled(&msg)) {
            state.ircx_data = true;
        } else if (!state.join_requested and std.mem.eql(u8, msg.command, "001")) {
            if (workspace.rooms.items.len == 0) {
                try client.join(channel);
            } else for (workspace.rooms.items) |*room| {
                room.joined = false;
                try client.join(room.name);
            }
            state.join_requested = true;
            state.status = "joining";
            redraw = true;
        } else if (std.mem.eql(u8, msg.command, "JOIN")) {
            const who = if (msg.prefix) |p| cc.comic.session.nickFromPrefix(p) else "";
            const joined_channel = msg.param(0) orelse "";
            if (std.ascii.eqlIgnoreCase(who, nick)) {
                const room_index = try workspace.ensure(joined_channel);
                var room = &workspace.rooms.items[room_index];
                room.joined = true;
                state.joined = true;
                state.status = "connected";
                try announceRoomAvatar(client, room.name, room.transcript.resolvedAvatar(nick), state.ircx_data);
                redraw = true;
            } else if (workspace.find(joined_channel)) |room_index| {
                try sendAutomaticGreeting(client, preferences, joined_channel, who);
                _ = try runPersistentRules(workspace.gpa, client, &workspace.rooms.items[room_index].transcript, preferences, "Join", who, joined_channel, "");
                redraw = true;
            }
        } else if (std.mem.eql(u8, msg.command, "366")) {
            const joined_channel = msg.param(1) orelse msg.param(0) orelse "";
            if (workspace.find(joined_channel)) |room_index| {
                workspace.rooms.items[room_index].joined = true;
                state.joined = true;
                state.status = "connected";
                redraw = true;
            }
        } else if (std.mem.eql(u8, msg.command, "DATA")) {
            const target = msg.param(0) orelse continue;
            const kind = msg.param(1) orelse continue;
            const wire = msg.param(2) orelse continue;
            if (!std.mem.eql(u8, kind, "CCUDI1")) continue;
            const room_index = workspace.find(target) orelse if (std.ascii.eqlIgnoreCase(target, nick)) workspace.active orelse continue else continue;
            const who = if (msg.prefix) |prefix| cc.comic.session.nickFromPrefix(prefix) else continue;
            if (try processComicControl(io, client, &workspace.rooms.items[room_index].transcript, who, wire, nick, state.ircx_data, preferences)) {
                redraw = true;
                continue;
            }
            _ = cc.proto.udi.parseAnnotation(wire) catch continue;
            try state.rememberUdi(workspace.gpa, target, who, wire);
        } else if (std.mem.eql(u8, msg.command, "WHISPER")) {
            // IRCX contextual whispers carry both a channel and recipient
            // list. The server has already filtered delivery to us; retain
            // the channel context and render it as a private comic line.
            const target = msg.param(0) orelse continue;
            const room_index = workspace.find(target) orelse continue;
            const text = msg.param(2) orelse continue;
            const who = if (msg.prefix) |p| cc.comic.session.nickFromPrefix(p) else "someone";
            var room = &workspace.rooms.items[room_index];
            try room.transcript.addWireMessage(who, text, true, null);
            room.transcript.trimTo(64);
            if (workspace.active != room_index) room.unread +|= 1;
            redraw = true;
        } else if (std.mem.eql(u8, msg.command, "PRIVMSG")) {
            const target = msg.param(0) orelse continue;
            const is_private = std.ascii.eqlIgnoreCase(target, nick);
            const room_index = workspace.find(target) orelse if (is_private) workspace.active orelse continue else continue;
            var room = &workspace.rooms.items[room_index];
            const transcript = &room.transcript;
            const text = msg.param(1) orelse continue;
            const who = if (msg.prefix) |p| cc.comic.session.nickFromPrefix(p) else "someone";
            if (observeFlood(state, workspace.gpa, who, monotonicMilliseconds(io), preferences.auto_ignore_count, preferences.auto_ignore_interval_s)) {
                redraw = true;
                continue;
            }
            if (try receiveDccOffer(workspace.gpa, view, state, who, text)) {
                redraw = true;
                continue;
            }
            if (try receiveCallControl(client, view, who, text)) {
                redraw = true;
                continue;
            }
            if (try processComicControl(io, client, transcript, who, text, nick, state.ircx_data, preferences)) {
                redraw = true;
                continue;
            }
            if (!std.ascii.eqlIgnoreCase(who, nick) and try runPersistentRules(workspace.gpa, client, transcript, preferences, if (is_private) "Whisper" else "Message", who, room.name, text)) {
                redraw = true;
                continue;
            }
            var pending = state.takeUdi(target, who);
            defer if (pending) |*entry| entry.deinit(transcript.gpa);
            try transcript.addWireMessage(
                who,
                text,
                is_private,
                if (pending) |entry| entry.wire else null,
            );
            transcript.trimTo(64);
            if (workspace.active != room_index) room.unread +|= 1;
            redraw = true;
        } else if (std.mem.eql(u8, msg.command, "433")) {
            state.status = "nickname in use";
            redraw = true;
        }
    }
    return redraw;
}

fn isVisibleServerWorkflowReply(command: []const u8) bool {
    const code = std.fmt.parseInt(u16, command, 10) catch return std.ascii.eqlIgnoreCase(command, "PROP");
    return code == 322 or code == 323 or (code >= 801 and code <= 819) or (code >= 913 and code <= 925);
}

fn appendServerWorkflowReply(transcript: *cc.comic.session.Transcript, msg: *const cc.net.message.Message) !void {
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(transcript.gpa);
    try text.appendSlice(transcript.gpa, msg.command);
    for (msg.params[0..msg.param_count]) |param| {
        try text.append(transcript.gpa, ' ');
        try text.appendSlice(transcript.gpa, param);
    }
    try transcript.addWithOptions("Server", text.items, .{ .modes = cc.proto.udi.bm_action });
}

fn collectNotificationWho(
    gpa: std.mem.Allocator,
    state: *ChatState,
    preferences: *const cc.client.preferences.Store,
    msg: *const cc.net.message.Message,
    network_name: []const u8,
) !void {
    if (msg.param_count < 6) return;
    const user = msg.params[2];
    const host = msg.params[3];
    const nickname = msg.params[5];
    for (preferences.notifications.items) |notification| {
        if (!notification.enabled) continue;
        if (notification.network.len != 0 and !std.ascii.eqlIgnoreCase(notification.network, network_name)) continue;
        var pattern: [512]u8 = undefined;
        const mask = std.fmt.bufPrint(&pattern, "{s}!{s}@{s}", .{ notification.nickname, notification.user_mask, notification.host_mask }) catch continue;
        var identity: [512]u8 = undefined;
        const candidate = std.fmt.bufPrint(&identity, "{s}!{s}@{s}", .{ nickname, user, host }) catch continue;
        if (!cc.comic.rules.globMatchCaseInsensitive(mask, candidate)) continue;
        if (state.notification_current.items.len < 512 and !containsIgnoreCase(state.notification_current.items, nickname))
            try state.notification_current.append(gpa, try gpa.dupe(u8, nickname));
        break;
    }
}

fn finishNotificationWho(gpa: std.mem.Allocator, state: *ChatState, workspace: *cc.client.workspace.Workspace) !bool {
    if (state.notification_poll_pending == 0) return false;
    state.notification_poll_pending -= 1;
    if (state.notification_poll_pending != 0) return false;
    const transcript = if (workspace.activeRoom()) |room| &room.transcript else return false;
    var changed = false;
    for (state.notification_current.items) |current| {
        if (!containsIgnoreCase(state.notification_previous.items, current)) {
            var text: [256]u8 = undefined;
            try transcript.addWithOptions("Notification", std.fmt.bufPrint(&text, "{s} is online.", .{current}) catch "A watched CAST is online.", .{ .modes = cc.proto.udi.bm_action });
            if (state.desktop_notification) |old| gpa.free(old);
            state.desktop_notification = try gpa.dupe(u8, std.fmt.bufPrint(&text, "{s} is online.", .{current}) catch "A watched CAST is online.");
            changed = true;
        }
    }
    for (state.notification_previous.items) |previous| {
        if (!containsIgnoreCase(state.notification_current.items, previous)) {
            var text: [256]u8 = undefined;
            try transcript.addWithOptions("Notification", std.fmt.bufPrint(&text, "{s} went offline.", .{previous}) catch "A watched CAST went offline.", .{ .modes = cc.proto.udi.bm_action });
            if (state.desktop_notification) |old| gpa.free(old);
            state.desktop_notification = try gpa.dupe(u8, std.fmt.bufPrint(&text, "{s} went offline.", .{previous}) catch "A watched CAST went offline.");
            changed = true;
        }
    }
    for (state.notification_previous.items) |entry| gpa.free(entry);
    state.notification_previous.clearRetainingCapacity();
    for (state.notification_current.items) |entry| try state.notification_previous.append(gpa, try gpa.dupe(u8, entry));
    return changed;
}

fn deliverDesktopNotification(window: anytype, gpa: std.mem.Allocator, state: *ChatState) void {
    const message = state.desktop_notification orelse return;
    defer gpa.free(message);
    state.desktop_notification = null;
    if (comptime @hasDecl(@TypeOf(window.*), "notify")) window.notify(gpa, "Comic Chat", message) catch {};
}

fn containsIgnoreCase(items: []const []u8, needle: []const u8) bool {
    for (items) |item| if (std.ascii.eqlIgnoreCase(item, needle)) return true;
    return false;
}

fn observeFlood(state: *ChatState, gpa: std.mem.Allocator, nick: []const u8, now_ms: u64, maximum: u16, interval_s: u16) bool {
    for (state.flood_entries.items) |*entry| if (std.ascii.eqlIgnoreCase(entry.nick, nick)) {
        const interval_ms = @as(u64, interval_s) * 1000;
        if (now_ms -| entry.window_start_ms > interval_ms) {
            entry.window_start_ms = now_ms;
            entry.count = 1;
            entry.ignored = false;
            return false;
        }
        if (entry.ignored) return true;
        entry.count +|= 1;
        if (entry.count > maximum) entry.ignored = true;
        return entry.ignored;
    };
    const owned = gpa.dupe(u8, nick) catch return false;
    state.flood_entries.append(gpa, .{ .nick = owned, .window_start_ms = now_ms, .count = 1 }) catch {
        gpa.free(owned);
    };
    return false;
}

fn sendAutomaticGreeting(client: *cc.net.client.Client, preferences: *const cc.client.preferences.Store, channel: []const u8, nick: []const u8) !void {
    if (preferences.greeting.items.len == 0 or hasWireControl(preferences.greeting.items) or std.ascii.eqlIgnoreCase(preferences.greetingMode(), "None")) return;
    const text = try replaceNickToken(client.gpa, preferences.greeting.items, nick);
    defer client.gpa.free(text);
    try client.privmsg(if (std.ascii.eqlIgnoreCase(preferences.greetingMode(), "Whisper")) nick else channel, text);
}

fn replaceNickToken(gpa: std.mem.Allocator, source: []const u8, nick: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var rest = source;
    while (std.mem.indexOf(u8, rest, "%nick%")) |index| {
        try out.appendSlice(gpa, rest[0..index]);
        try out.appendSlice(gpa, nick);
        rest = rest[index + "%nick%".len ..];
    }
    try out.appendSlice(gpa, rest);
    return out.toOwnedSlice(gpa);
}

/// Returns true when an Ignore action suppresses the triggering message.
fn runPersistentRules(
    gpa: std.mem.Allocator,
    client: *cc.net.client.Client,
    transcript: *cc.comic.session.Transcript,
    preferences: *const cc.client.preferences.Store,
    event: []const u8,
    who: []const u8,
    channel: []const u8,
    message: []const u8,
) !bool {
    var suppress = false;
    for (preferences.rules.items) |rule| {
        if (!rule.enabled or !std.ascii.eqlIgnoreCase(rule.event, event)) continue;
        if (rule.filter.len != 0) {
            const candidate = if (std.ascii.eqlIgnoreCase(event, "Message") or std.ascii.eqlIgnoreCase(event, "Whisper")) message else who;
            if (cc.comic.rules.findSubstring(candidate, rule.filter, false, true) == null and !cc.comic.rules.globMatchCaseInsensitive(rule.filter, candidate)) continue;
        }
        const value = try replaceNickToken(gpa, rule.value, who);
        defer gpa.free(value);
        if (hasWireControl(value)) continue;
        if (std.ascii.eqlIgnoreCase(rule.action, "Ignore")) {
            suppress = true;
        } else if (std.ascii.eqlIgnoreCase(rule.action, "Notify")) {
            try transcript.addWithOptions("Automation", if (value.len == 0) rule.name else value, .{ .modes = cc.proto.udi.bm_action });
        } else if (std.ascii.eqlIgnoreCase(rule.action, "Reply")) {
            if (value.len != 0) try client.privmsg(if (std.ascii.eqlIgnoreCase(event, "Whisper")) who else channel, value);
        } else if (std.ascii.eqlIgnoreCase(rule.action, "Action")) {
            if (value.len != 0) {
                const wire = try std.fmt.allocPrint(gpa, "\x01ACTION {s}\x01", .{value});
                defer gpa.free(wire);
                try client.privmsg(channel, wire);
            }
        } else if (std.ascii.eqlIgnoreCase(rule.action, "Sound")) {
            if (value.len != 0) try client.sendSound(channel, value, "");
        } else if (std.ascii.eqlIgnoreCase(rule.action, "Join room")) {
            if (value.len != 0) try client.join(value);
        }
    }
    return suppress;
}

fn messageRoom(msg: *const cc.net.message.Message) ?[]const u8 {
    if (std.ascii.eqlIgnoreCase(msg.command, "353")) {
        if (msg.param_count < 2) return null;
        return msg.params[msg.param_count - 2];
    }
    if (std.ascii.eqlIgnoreCase(msg.command, "366")) return msg.param(1) orelse msg.param(0);
    if (std.ascii.eqlIgnoreCase(msg.command, "JOIN") or
        std.ascii.eqlIgnoreCase(msg.command, "PART") or
        std.ascii.eqlIgnoreCase(msg.command, "DATA") or
        std.ascii.eqlIgnoreCase(msg.command, "PRIVMSG")) return msg.param(0);
    return null;
}

fn presentView(
    win: anytype,
    view: *cc.client.view.View,
    title: []const u8,
    status: []const u8,
    transcript: *const cc.comic.session.Transcript,
    editor: *const cc.client.input.Editor,
) !void {
    try view.render(title, status, transcript, editor.text(), editor.cursor);
    try win.present(view.pixels(), view.width(), view.height());
}

fn presentWorkspace(
    win: anytype,
    view: *cc.client.view.View,
    status: []const u8,
    workspace: *cc.client.workspace.Workspace,
) !void {
    const room = workspace.activeRoom() orelse return;
    var tabs: [cc.client.workspace.max_rooms]cc.client.view.View.Tab = undefined;
    for (workspace.rooms.items, 0..) |item, index| tabs[index] = .{
        .label = item.name,
        .unread = item.unread,
    };
    try view.renderTabs(status, &room.transcript, room.editor.text(), room.editor.cursor, room.editor.selection(), tabs[0..workspace.rooms.items.len], workspace.active.?);
    if (comptime @hasDecl(@TypeOf(win.*), "setTitle")) {
        var title_buf: [96]u8 = undefined;
        const title = std.fmt.bufPrint(&title_buf, "Comic Chat / Sunday / {s}", .{room.name}) catch "Comic Chat / Sunday";
        win.setTitle(title) catch {};
    }
    try win.present(view.pixels(), view.width(), view.height());
}

const source_default_profile = "This person is too lazy to create a profile entry.";

fn receiveDccOffer(
    gpa: std.mem.Allocator,
    view: *cc.client.view.View,
    state: *ChatState,
    who: []const u8,
    wire: []const u8,
) !bool {
    if (!std.mem.startsWith(u8, wire, "\x01DCC SEND ")) return false;
    const maybe_offer = cc.proto.dcc.parseSendOffer(gpa, wire) catch return true;
    const offer = maybe_offer orelse return false;
    defer gpa.free(offer.filename);
    if (offer.port == 0 or offer.size == null or offer.size.? > cc.client.files.max_document_bytes) return true;
    try state.rememberDccOffer(gpa, who, offer);
    view.openDialog(.file_transfer);
    try view.setDialogValueAt(0, "Receive offer");
    try view.setDialogValueAt(1, who);

    var safe_name: [192]u8 = undefined;
    const filename = safeIncomingFilename(offer.filename, &safe_name);
    var destination: [224]u8 = undefined;
    const save_path = std.fmt.bufPrint(&destination, "received-{s}", .{filename}) catch "received-file.bin";
    try view.setDialogValueAt(2, save_path);
    var size_text: [64]u8 = undefined;
    try view.setDialogValueAt(3, std.fmt.bufPrint(&size_text, "{d} bytes", .{offer.size.?}) catch "size unavailable");
    try view.setDialogValueAt(4, "Waiting for approval");
    view.setDialogNotice("Verify sender and save path before accepting.");
    return true;
}

fn safeIncomingFilename(name: []const u8, buffer: []u8) []const u8 {
    var start: usize = 0;
    for (name, 0..) |byte, index| if (byte == '/' or byte == '\\') {
        start = index + 1;
    };
    const basename = name[start..];
    var count: usize = 0;
    for (basename) |byte| {
        if (count >= buffer.len) break;
        buffer[count] = if (std.ascii.isAlphanumeric(byte) or byte == '.' or byte == '_' or byte == '-') byte else '_';
        count += 1;
    }
    if (count == 0 or std.mem.eql(u8, buffer[0..count], ".") or std.mem.eql(u8, buffer[0..count], "..")) {
        const fallback = "file.bin";
        @memcpy(buffer[0..fallback.len], fallback);
        return buffer[0..fallback.len];
    }
    return buffer[0..count];
}

fn receiveCallControl(client: *cc.net.client.Client, view: *cc.client.view.View, who: []const u8, wire: []const u8) !bool {
    const prefix = "\x01X-COMICCHAT-CALL ";
    if (!std.mem.startsWith(u8, wire, prefix) or wire.len <= prefix.len or wire[wire.len - 1] != 0x01) return false;
    const link = wire[prefix.len .. wire.len - 1];
    if (!validMeetingLink(link)) return true;
    view.openDialog(.call_link);
    try view.setDialogValueAt(0, who);
    try view.setDialogValueAt(1, link);
    try view.setDialogValueAt(2, "Incoming portable call invitation");
    view.setDialogNotice("Copy the verified HTTPS link to your browser when you are ready.");
    _ = client;
    return true;
}

fn validMeetingLink(link: []const u8) bool {
    return link.len <= 400 and std.mem.startsWith(u8, link, "https://") and
        std.mem.indexOfAny(u8, link, " \t\r\n\x00\x01") == null;
}

fn hasWireControl(value: []const u8) bool {
    return std.mem.indexOfAny(u8, value, "\r\n\x00\x01") != null;
}

test "portable transfer and call inputs reject unsafe values" {
    var safe_name: [64]u8 = undefined;
    try std.testing.expectEqualStrings("payload.exe", safeIncomingFilename("../../payload.exe", &safe_name));
    try std.testing.expectEqualStrings("file.bin", safeIncomingFilename("..", &safe_name));
    try std.testing.expectEqual(@as(?u32, 0x7f000001), parseIpv4Number("127.0.0.1"));
    try std.testing.expectEqual(@as(?u32, 0x7f000001), parseIpv4Number("2130706433"));
    try std.testing.expect(validMeetingLink("https://meet.example.test/room"));
    try std.testing.expect(!validMeetingLink("http://meet.example.test/room"));
    try std.testing.expect(!validMeetingLink("https://example.test/bad link"));
}

test "flood suppression expires and nickname templates are bounded" {
    const gpa = std.testing.allocator;
    var state: ChatState = .{};
    defer state.deinit(gpa);
    try std.testing.expect(!observeFlood(&state, gpa, "Anna", 1000, 2, 10));
    try std.testing.expect(!observeFlood(&state, gpa, "anna", 1100, 2, 10));
    try std.testing.expect(observeFlood(&state, gpa, "ANNA", 1200, 2, 10));
    try std.testing.expect(!observeFlood(&state, gpa, "Anna", 12_001, 2, 10));
    const greeting = try replaceNickToken(gpa, "Welcome %nick% - %nick%", "Anna");
    defer gpa.free(greeting);
    try std.testing.expectEqualStrings("Welcome Anna - Anna", greeting);
}

/// Process the comment branch of Microsoft's `OnDataMsg`/`OnTextMsg` before
/// attempting UDI or ordinary speech parsing. IRCX comments and plain-IRC
/// comments carry identical bytes; only their outer command differs.
fn processComicControl(
    io: std.Io,
    client: *cc.net.client.Client,
    transcript: *cc.comic.session.Transcript,
    who: []const u8,
    wire: []const u8,
    self_nick: []const u8,
    ircx_data: bool,
    preferences: ?*cc.client.preferences.Store,
) !bool {
    if (try transcript.consumeAvatarAnnouncement(who, wire)) return true;
    if (try transcript.consumeAwayControl(who, wire)) return true;
    if (try processCtcpRequest(io, client, who, wire, preferences)) return true;
    if (wire.len < 2 or wire[0] != '#' or wire[1] != ' ') return false;

    const comment = wire[1..];
    switch (cc.comic.session.parseProfileControl(comment)) {
        .not_control => {},
        .get_info => {
            const saved = if (preferences) |prefs| prefs.profileText() else source_default_profile;
            try client.sendProfile(who, if (hasWireControl(saved)) source_default_profile else saved);
            return true;
        },
        .get_char_info => {
            try announceRoomAvatar(client, who, transcript.resolvedAvatar(self_nick), ircx_data);
            return true;
        },
        .heres_info => |profile| {
            var display: std.ArrayList(u8) = .empty;
            defer display.deinit(transcript.gpa);
            try display.appendSlice(transcript.gpa, "Profile: ");
            try display.appendSlice(transcript.gpa, profile);
            try transcript.addWithOptions(who, display.items, .{ .modes = cc.proto.udi.bm_action });
            return true;
        },
    }
    switch (cc.comic.session.parseBackdropControl(comment)) {
        .not_control => return false,
        .empty => return true,
        .sync => |announcement| {
            if (cc.comic.session.bundledBackdropByName(announcement.base_name)) |name| try transcript.setBackdrop(name);
            return true;
        },
        .legacy => |name| {
            if (cc.comic.session.bundledBackdropByName(name)) |bundled| try transcript.setBackdrop(bundled);
            return true;
        },
    }
}

/// Handle the source's private CTCP request/reply surface. Email and homepage
/// replies are intentionally empty: this portable build never exposes local
/// identity data merely because a peer probed it.
fn processCtcpRequest(io: std.Io, client: *cc.net.client.Client, who: []const u8, wire: []const u8, preferences: ?*const cc.client.preferences.Store) !bool {
    if (wire.len < 3 or wire[0] != 0x01 or wire[wire.len - 1] != 0x01) return false;
    const body = wire[1 .. wire.len - 1];
    const separator = std.mem.indexOfScalar(u8, body, ' ');
    const command = if (separator) |index| body[0..index] else body;
    const payload = if (separator) |index| body[index + 1 ..] else null;

    if (std.ascii.eqlIgnoreCase(command, "VERSION") and payload == null) {
        try client.ctcpReply(who, "VERSION", "ComicChat Zig Comic mode");
        return true;
    }
    if (std.ascii.eqlIgnoreCase(command, "PING")) {
        try client.ctcpReply(who, "PING", payload orelse "");
        return true;
    }
    if (std.ascii.eqlIgnoreCase(command, "TIME") and payload == null) {
        var buffer: [64]u8 = undefined;
        const seconds = std.Io.Clock.real.now(io).toSeconds();
        const safe_seconds: u64 = if (seconds > 0) @intCast(seconds) else 0;
        const instant = std.time.epoch.EpochSeconds{ .secs = safe_seconds };
        const year_day = instant.getEpochDay().calculateYearDay();
        const month_day = year_day.calculateMonthDay();
        const day_seconds = instant.getDaySeconds();
        const value = try std.fmt.bufPrint(
            &buffer,
            "{d:0>4}-{d:0>2}-{d:0>2}, {d:0>2}:{d:0>2}:{d:0>2} UTC",
            .{
                year_day.year,
                month_day.month.numeric(),
                @as(u8, month_day.day_index) + 1,
                day_seconds.getHoursIntoDay(),
                day_seconds.getMinutesIntoHour(),
                day_seconds.getSecondsIntoMinute(),
            },
        );
        try client.ctcpReply(who, "TIME", value);
        return true;
    }
    if (std.ascii.eqlIgnoreCase(command, "EMAIL") and payload == null) {
        const saved = if (preferences) |prefs| prefs.email.items else "";
        try client.ctcpReply(who, "EMAIL", if (hasWireControl(saved)) "" else saved);
        return true;
    }
    if (std.ascii.eqlIgnoreCase(command, "URL") and payload == null) {
        const saved = if (preferences) |prefs| prefs.homepage.items else "";
        try client.ctcpReply(who, "URL", if (hasWireControl(saved)) "" else saved);
        return true;
    }
    if (std.ascii.eqlIgnoreCase(command, "CLIENTINFO") and payload == null) {
        try client.ctcpReply(who, "CLIENTINFO", "ACTION AWAY CLIENTINFO DCC EMAIL PING SOUND TIME URL VERSION X-COMICCHAT-CALL");
        return true;
    }
    if (std.ascii.eqlIgnoreCase(command, "NETMEET")) {
        try client.refuseLegacyNetMeeting(who);
        return true;
    }
    // The source explicitly ignores X-VCHAT.
    return std.ascii.eqlIgnoreCase(command, "X-VCHAT");
}

fn handleInputKey(
    gpa: std.mem.Allocator,
    key: anytype,
    view: *cc.client.view.View,
    editor: *cc.client.input.Editor,
    maybe_client: ?*cc.net.client.Client,
    transcript: *cc.comic.session.Transcript,
    nick: []const u8,
    channel: []const u8,
    joined: bool,
    ircx_data: bool,
) !bool {
    switch (key) {
        .char => |ch| {
            view.focusComposer();
            const encoded_len = std.unicode.utf8CodepointSequenceLength(ch) catch return true;
            if (editor.text().len + encoded_len <= 400) try editor.insert(ch);
        },
        .backspace => editor.backspace(),
        .delete => editor.delete(),
        .left => editor.left(),
        .right => editor.right(),
        .home => editor.home(),
        .end => editor.end(),
        .escape => if (!view.closeDialog()) return false,
        .enter => {
            if (view.active_dialog != null) {
                _ = view.closeDialog();
                return true;
            }
            if (editor.text().len == 0) return true;
            const line = try editor.take();
            defer gpa.free(line);
            if (std.mem.eql(u8, line, "/quit")) return false;
            if (std.mem.eql(u8, line, "/clear")) {
                transcript.trimTo(0);
                view.jumpLatest();
                return true;
            }
            if (std.mem.eql(u8, line, "/view comic") or std.mem.eql(u8, line, "/comic")) {
                view.setContentMode(.comic);
                return true;
            }
            if (std.mem.eql(u8, line, "/view text") or std.mem.eql(u8, line, "/text")) {
                view.setContentMode(.text);
                return true;
            }
            if (std.mem.eql(u8, line, "/members")) {
                view.toggleMembers();
                return true;
            }
            if (std.mem.eql(u8, line, "/latest")) {
                view.jumpLatest();
                return true;
            }
            if (std.mem.startsWith(u8, line, "/dialog ")) {
                _ = view.openDialogByResource(std.mem.trim(u8, line["/dialog ".len..], " \t"));
                return true;
            }
            if (!joined) return true;
            const client = maybe_client orelse return true;
            if (std.mem.eql(u8, line, "/avatar") or std.mem.startsWith(u8, line, "/avatar ")) {
                const requested = if (line.len > "/avatar ".len) line["/avatar ".len..] else "";
                const selected = cc.comic.session.bundledAvatarByName(requested) orelse return true;
                try transcript.setAvatar(nick, selected);
                try announceRoomAvatar(client, channel, selected, ircx_data);
                return true;
            }
            const selected_mode = view.shell.say_mode;
            const action_text: ?[]const u8 = if (std.mem.eql(u8, line, "/me"))
                ""
            else if (std.mem.startsWith(u8, line, "/me "))
                line["/me ".len..]
            else if (selected_mode == .action)
                line
            else
                null;
            if (action_text) |body| if (body.len == 0) return true;
            const visible_text = action_text orelse line;
            const modes: u16 = if (action_text != null) cc.proto.udi.bm_action else switch (selected_mode) {
                .say => cc.proto.udi.bm_say,
                .think => cc.proto.udi.bm_think,
                .whisper => cc.proto.udi.bm_whisper,
                .action => unreachable,
                .sound => cc.proto.udi.bm_sound,
            };
            const target = if (selected_mode == .whisper) whisper: {
                const member_index = view.shell.selected_member orelse return true;
                if (member_index >= transcript.roster.items.len) return true;
                if (transcript.roster.items[member_index].departed) return true;
                break :whisper transcript.roster.items[member_index].nick;
            } else channel;
            const is_private = selected_mode == .whisper;
            var talk_to_storage: [1][]const u8 = undefined;
            const talk_tos: []const []const u8 = talk_tos: {
                const member_index = view.shell.selected_member orelse break :talk_tos &.{};
                if (member_index >= transcript.roster.items.len) break :talk_tos &.{};
                const member = transcript.roster.items[member_index];
                if (member.departed) break :talk_tos &.{};
                talk_to_storage[0] = member.nick;
                break :talk_tos &talk_to_storage;
            };
            const avatar_name = transcript.resolvedAvatar(nick);
            const avatar = cc.comic.strip.avatarByName(avatar_name) orelse return error.UnknownAvatar;
            const selected_emotion = view.shell.selectedEmotion();
            const pose_state = if (selected_emotion == .neutral)
                try cc.comic.figure.poseStateForText(gpa, avatar, visible_text)
            else
                try cc.comic.figure.poseStateForEmotion(gpa, avatar, selected_emotion, view.shell.selectedEmotionIntensity());
            var comic_message: std.ArrayList(u8) = .empty;
            defer comic_message.deinit(gpa);
            try cc.proto.udi.encode(&comic_message, gpa, .{
                .gesture = pose_state.gesture,
                .expression = pose_state.expression,
                .requested = pose_state.requested,
                .modes = modes,
                .talk_tos = talk_tos,
            }, true);
            var chat_message: std.ArrayList(u8) = .empty;
            defer chat_message.deinit(gpa);
            try appendSourceComicText(&chat_message, gpa, visible_text);
            // Source Comic Chat sends the canonical embedded UDI form through
            // PRIVMSG even after IRCX is available.  This keeps old clients
            // in the room synchronized without requiring the optional DATA
            // extension; inbound DATA remains accepted for peer compatibility.
            try comic_message.appendSlice(gpa, chat_message.items);
            try client.privmsg(target, comic_message.items);
            try transcript.addWireMessage(nick, comic_message.items, is_private, null);
            view.shell.setSayMode(.say);
            transcript.trimTo(64);
            view.jumpLatest();
        },
        .tab => view.cycleFocus(),
        .page_up => view.pageEarlier(transcript.lines.items.len),
        .page_down => view.pageLater(),
        .up, .down, .other => {},
    }
    return true;
}

/// In comic mode Microsoft sends readable action text unchanged and lets the
/// UDI M5 field select the box balloon. CTCP ACTION is only the non-comics
/// fallback produced by `ProcessNonComicsMsg`.
fn appendSourceComicText(out: *std.ArrayList(u8), gpa: std.mem.Allocator, text: []const u8) !void {
    try out.appendSlice(gpa, text);
}

test "comic action wire keeps source raw text and selected talk-to metadata" {
    const gpa = std.testing.allocator;
    var annotation: std.ArrayList(u8) = .empty;
    defer annotation.deinit(gpa);
    try cc.proto.udi.encode(&annotation, gpa, .{
        .gesture = .{ .index = 1, .emotion = 2, .intensity = 3 },
        .expression = .{ .index = 4, .emotion = 5, .intensity = 6 },
        .modes = cc.proto.udi.bm_action,
        .talk_tos = &.{"alice"},
    }, false);
    try std.testing.expectEqualStrings("#G123E456M5Talice", annotation.items);

    var readable: std.ArrayList(u8) = .empty;
    defer readable.deinit(gpa);
    try appendSourceComicText(&readable, gpa, "waves");
    try std.testing.expectEqualStrings("waves", readable.items);
    try std.testing.expect(std.mem.indexOf(u8, readable.items, cc.comic.session.ctcp_action_prefix) == null);
}

test "IRCX DATA transport requires numeric 800 enabled state" {
    const disabled = cc.net.message.parse(":server 800 comicchat 0 0 :IRCX is supported");
    const enabled = cc.net.message.parse(":server 800 comicchat 1 0 :IRCX enabled");
    const unrelated = cc.net.message.parse(":server 001 comicchat :welcome");
    const advertisement = cc.net.message.parse(":server 005 comicchat IRCX COMICCHAT=DATA :supported");

    try std.testing.expect(!ircxNumericEnabled(&disabled));
    try std.testing.expect(ircxNumericEnabled(&enabled));
    try std.testing.expect(!ircxNumericEnabled(&unrelated));
    try std.testing.expect(!ircxNumericEnabled(&advertisement));
}

fn runRenderStrip(gpa: std.mem.Allocator, io: std.Io) !void {
    const lines = [_]cc.comic.strip.Line{
        .{ .speaker = "anna", .text = "The title panel starts every comic." },
        .{ .speaker = "kevin", .text = "Different speakers may share a panel." },
        .{ .speaker = "anna", .text = "A repeated speaker starts a fresh panel." },
        .{ .speaker = "mike", .text = "Two columns and source-sized interstices." },
        .{ .speaker = "rebecca", .text = "Masks and backdrops follow the old draw order." },
        .{ .speaker = "xeno", .text = "The source renderer returns one complete page." },
    };
    var strip = try cc.comic.strip.render(gpa, &lines);
    defer strip.deinit(gpa);
    try emitPpm(gpa, io, strip.pixels, strip.width, strip.height);
}

fn runToPng(gpa: std.mem.Allocator, io: std.Io, name: []const u8) !void {
    const data = bgByName(name) orelse {
        elog("unknown background '{s}'\n", .{name});
        return;
    };
    var img = try cc.assets.bgb.decodeBackground(gpa, data);
    defer img.deinit(gpa);
    const png = try cc.render.png.encode(gpa, img.pixels, img.width, img.height);
    defer gpa.free(png);
    try writeStdout(io, png);
}

/// Render the shared desktop shell without requiring an X11, Wayland, or
/// Win32 window. This is both a release-preview command and a deterministic
/// visual regression surface for the modern UI library.
fn preview_status(surface: []const u8) []const u8 {
    if (std.mem.eql(u8, surface, "offline")) return "offline";
    if (std.mem.eql(u8, surface, "failed")) return "Wire failed - open Wire setup";
    return "reconnecting";
}

fn runUiPreview(gpa: std.mem.Allocator, io: std.Io, surface: []const u8) !void {
    const compact = std.mem.eql(u8, surface, "compact") or std.mem.startsWith(u8, surface, "compact-");
    var view = try cc.client.view.View.init(gpa, if (compact) 640 else 960, if (compact) 480 else 720);
    defer view.deinit();
    const dark_surface = std.mem.indexOf(u8, surface, "dark") != null;
    if (dark_surface) view.setAppearance(.{ .mode = .dark, .accent = .violet }, true);
    if (std.mem.startsWith(u8, surface, "text-")) view.shell.content_mode = .text;
    var transcript = cc.comic.session.Transcript.init(gpa);
    defer transcript.deinit();
    if (!std.mem.eql(u8, surface, "empty-members")) try transcript.setSelf("comicchat");
    const with_conversation = std.mem.eql(u8, surface, "conversation") or std.mem.eql(u8, surface, "member") or std.mem.eql(u8, surface, "text-conversation");
    if (with_conversation) {
        try transcript.setAvatar("comicchat", "anna");
        try transcript.setAvatar("alex", "armando");
        try transcript.add("alex", "Welcome to #root. The new studio is ready.");
        try transcript.add("comicchat", "Great. The comic view feels much clearer now.");
        for (transcript.roster.items) |*member| {
            if (std.ascii.eqlIgnoreCase(member.nick, "comicchat")) member.role = .owner;
            if (std.ascii.eqlIgnoreCase(member.nick, "alex")) member.role = .operator;
        }
        if (std.mem.eql(u8, surface, "text-conversation")) {
            try transcript.add("comicchat", "The chat buffer now keeps a full thought together instead of turning every sentence into a separate visual interruption.");
            try transcript.add("alex", "That makes the room easier to scan when several people are talking at once.");
            try transcript.add("alex", "The live edge should stay quiet until you are reading older messages.");
            try transcript.add("maya", "I can follow the conversation without losing who said what.");
            try transcript.add("maya", "The composer also feels connected to the conversation instead of detached below it.");
        }
    }
    if (std.mem.eql(u8, surface, "sparse")) {
        try transcript.setAvatar("alex", "armando");
        try transcript.add("alex", "A partially filled row keeps the selected panel density.");
    }
    if (std.mem.eql(u8, surface, "break-only")) try transcript.add("comicchat", "<Brk>");
    if (std.mem.startsWith(u8, surface, "dialog-")) {
        const name = surface["dialog-".len..];
        const id = std.meta.stringToEnum(cc.client.dialogs.Id, name) orelse return error.UnknownDialogPreview;
        view.openDialog(id);
        switch (id) {
            .ircx_properties => {
                try view.setDialogValueAt(0, "#root");
                try view.setDialogValueAt(1, "TOPIC,ONJOIN");
                try view.setDialogValueAt(3, "Read");
            },
            .room_access => {
                try view.setDialogValueAt(0, "Add");
                try view.setDialogValueAt(1, "Host");
                try view.setDialogValueAt(2, "alex!*@*");
                try view.setDialogValueAt(3, "60");
                try view.setDialogValueAt(4, "Room helper");
            },
            .ircx_events => {
                try view.setDialogValueAt(0, "Show");
                try view.setDialogValueAt(1, "CAST");
            },
            .servers => {
                try view.setDialogValueAt(0, "eshmaki.me");
                try view.setDialogValueAt(1, "6697");
                try view.setDialogValueAt(2, "Verified TLS");
            },
            .invitation => try view.setDialogValueAt(0, "#root"),
            .connection_features => {
                try view.setDialogValueAt(0, "Off the wire");
                try view.setDialogValueAt(1, "Off the wire");
                try view.setDialogValueAt(2, "Hold");
                try view.setDialogValueAt(3, "Waiting on the wire");
            },
            .file_transfer => {
                try view.setDialogValueAt(0, "Receive offer");
                try view.setDialogValueAt(1, "alex");
                try view.setDialogValueAt(2, "received-comic.png");
                try view.setDialogValueAt(3, "245760 bytes");
                try view.setDialogValueAt(4, "Waiting for approval");
                view.setDialogNotice("Verify sender and save path before accepting.");
            },
            .automation => {
                try view.setDialogValueAt(0, "Whisper");
                try view.setDialogValueAt(1, "Welcome, %nick%!");
                try view.setDialogValueAt(2, "8");
                try view.setDialogValueAt(3, "10");
            },
            .notifications => {
                try view.setDialogValueAt(0, "alex");
                try view.setDialogValueAt(1, "*");
                try view.setDialogValueAt(2, "*");
                try view.setDialogValueAt(3, "eshmaki.me");
                try view.setDialogValueAt(4, "In-app banner");
            },
            .call_link => {
                try view.setDialogValueAt(0, "alex");
                try view.setDialogValueAt(1, "https://meet.example/room");
                try view.setDialogValueAt(2, "Portable secure-link invitation");
            },
            else => {},
        }
    }
    if (std.mem.eql(u8, surface, "settings")) view.openDialog(.settings);
    if (std.mem.eql(u8, surface, "compact-settings")) view.openDialog(.settings);
    if (std.mem.endsWith(u8, surface, "dark-settings")) {
        view.openDialog(.settings);
        try view.setDialogValueAt(0, "Dark studio");
        try view.setDialogValueAt(1, "Violet");
        try view.setDialogValueAt(2, "High contrast");
    }
    if (std.mem.endsWith(u8, surface, "character")) {
        view.openDialog(.character);
        try view.setDialogValueAt(0, if (std.mem.endsWith(u8, surface, "color-character")) "Xeno Color" else "Xeno HD");
        try view.setDialogValueAt(1, "Laughing");
    }
    if (std.mem.endsWith(u8, surface, "status")) view.status_panel_open = true;
    if (std.mem.eql(u8, surface, "inputs")) {
        view.openDialog(.password);
        for ("comicchat") |ch| _ = try view.handleDialogKey(.{ .char = ch }, .{});
        _ = try view.handleDialogKey(.tab, .{});
        for ("private password") |ch| _ = try view.handleDialogKey(.{ .char = ch }, .{});
        const password_layout = cc.client.ui.DialogLayout.init(view.width(), view.height(), cc.client.dialogs.get(.password).source_w, cc.client.dialogs.get(.password).source_h, cc.client.dialogs.fields(.password).len, 78, true);
        const password_field = password_layout.fieldRect(1);
        _ = view.handlePointerMove(.{ .kind = .move, .x = password_field.x + 20, .y = password_field.y + 12 }, transcript.roster.items.len);
    }
    if (std.mem.eql(u8, surface, "menu")) view.active_menu = 0;
    if (std.mem.eql(u8, surface, "compact-menu")) view.active_menu = 6;
    if (std.mem.eql(u8, surface, "hover")) view.hovered_toolbar = 5;
    if (std.mem.eql(u8, surface, "say-hover")) view.hovered_say_action = 2;
    if (std.mem.eql(u8, surface, "member")) view.shell.selected_member = 1;
    if (std.mem.eql(u8, surface, "mood-laughing")) view.shell.setEmotionPoint(30, -30, 48);
    if (std.mem.eql(u8, surface, "context")) {
        const layout = cc.client.geometry.Layout.compute(view.width(), view.height(), true, true);
        _ = view.handlePointer(.{ .kind = .down, .x = layout.body_camera.x + 30, .y = layout.body_camera.y + 60, .button = .secondary }, transcript.count(), transcript.roster.items.len);
    }
    if (std.mem.eql(u8, surface, "failed")) {
        view.openDialog(.setup);
        view.setDialogNotice("Wire failed. Check the host and TLS.");
    }
    const preview_input = if (std.mem.eql(u8, surface, "composer"))
        "A polished input should keep the caret visible even when the message becomes wider than the available composer field."
    else if (std.mem.eql(u8, surface, "composer-multiline"))
        "First line stays visible.\nThe active second line has its own caret."
    else
        "";
    if (std.mem.eql(u8, surface, "multi-tabs") or std.mem.eql(u8, surface, "compact-multi-tabs")) {
        const tabs = [_]cc.client.view.View.Tab{
            .{ .label = "#root" },
            .{ .label = "#illustration", .unread = 2 },
            .{ .label = "#portable-ui" },
            .{ .label = "#source-parity", .unread = 7 },
        };
        try view.renderTabs(preview_status(surface), &transcript, preview_input, preview_input.len, null, &tabs, tabs.len - 1);
    } else {
        try view.render("#root", preview_status(surface), &transcript, preview_input, preview_input.len);
    }
    const png = try cc.render.png.encode(gpa, view.pixels(), view.width(), view.height());
    defer gpa.free(png);
    try writeStdout(io, png);
}

fn runWindow(gpa: std.mem.Allocator, name: []const u8, prefer_wayland: bool, display: ?[]const u8) !void {
    const avb = avatarByName(name) orelse {
        elog("unknown avatar '{s}'\n", .{name});
        return;
    };
    var fig = cc.comic.figure.assemble(gpa, avb, 0, 0) catch {
        elog("could not assemble figure for '{s}'\n", .{name});
        return;
    };
    defer fig.deinit(gpa);
    const pad: i32 = 18;
    const W: u32 = fig.width + 2 * @as(u32, @intCast(pad));
    const H: u32 = fig.height + 2 * @as(u32, @intCast(pad));
    var c = try cc.render.canvas.Canvas.init(gpa, W, H);
    defer c.deinit(gpa);
    c.clear(cc.render.canvas.white);
    cc.comic.figure.composite(&c, fig.pixels, fig.width, fig.height, pad, pad);
    if (comptime builtin.os.tag == .linux) {
        if (prefer_wayland) {
            cc.platform.wayland.show(gpa, c.px, W, H) catch |err| {
                elog("wayland: {s}\n", .{@errorName(err)});
                return;
            };
        } else {
            const win = cc.platform.x11.Window.openWithDisplay(gpa, W, H, "comicchat", display orelse return error.DisplayUnset) catch |err| {
                elog("x11: {s}\n", .{@errorName(err)});
                return;
            };
            defer win.deinit();
            try win.present(c.px, W, H);
            while (true) switch (try win.nextEvent()) {
                .key, .close => break,
                .expose => try win.present(c.px, W, H),
                else => {},
            };
        }
    } else if (comptime builtin.os.tag == .windows) {
        try cc.platform.win32.show(gpa, c.px, W, H);
    } else if (comptime builtin.os.tag == .freebsd or builtin.os.tag == .openbsd) {
        const win = try cc.platform.x11.Window.openWithDisplay(gpa, W, H, "comicchat", display orelse return error.DisplayUnset);
        defer win.deinit();
        try win.present(c.px, W, H);
        while (true) switch (try win.nextEvent()) {
            .key, .close => break,
            .expose => try win.present(c.px, W, H),
            else => {},
        };
    } else {
        return error.UnsupportedPlatform;
    }
}

fn runConnect(
    gpa: std.mem.Allocator,
    io: std.Io,
    host: []const u8,
    port: u16,
    nick: []const u8,
    channel: []const u8,
    connect_options: cc.net.client.ConnectOptions,
    registration_options: cc.net.client.RegistrationOptions,
) !void {
    elog("connecting to {s}:{d} as {s} ...\n", .{ host, port, nick });

    var client = try cc.net.client.Client.connectWithOptions(gpa, host, port, connect_options);
    defer client.deinit();

    try client.registerWithOptions(nick, nick, "Comic Chat portable", registration_options);
    try client.tick(monotonicMilliseconds(io));

    var registered = false;
    var joined = false;
    var post: usize = 0;
    var seen: usize = 0;

    while (seen < 80) : (seen += 1) {
        const msg = (try client.next()) orelse {
            elog("<eof>\n", .{});
            break;
        };

        elog("<- {s}", .{msg.command});
        var i: usize = 0;
        while (i < msg.param_count) : (i += 1) elog(" [{s}]", .{msg.params[i]});
        elog("\n", .{});

        if (!registered and std.mem.eql(u8, msg.command, "001")) {
            registered = true;
            elog("** registered; joining {s}\n", .{channel});
            try client.join(channel);
        } else if (registered and !joined and std.mem.eql(u8, msg.command, "JOIN")) {
            const who = if (msg.prefix) |prefix| cc.comic.session.nickFromPrefix(prefix) else "";
            const joined_channel = msg.param(0) orelse "";
            if (std.ascii.eqlIgnoreCase(who, nick) and std.ascii.eqlIgnoreCase(joined_channel, channel)) {
                joined = true;
                elog("** joined; sending a line\n", .{});
                try client.privmsg(channel, "Hello from Comic Chat!");
            }
        } else if (registered and !joined and std.mem.eql(u8, msg.command, "366")) {
            const joined_channel = msg.param(1) orelse msg.param(0) orelse "";
            if (std.ascii.eqlIgnoreCase(joined_channel, channel)) {
                joined = true;
                elog("** joined; sending a line\n", .{});
                try client.privmsg(channel, "Hello from Comic Chat!");
            }
        }

        if (joined) {
            post += 1;
            if (post >= 3) break;
        }
    }
    elog("done.\n", .{});
}
