//! Minimal pure-Zig X11 window backend.
//!
//! Talks to the X server over `/tmp/.X11-unix/X<n>` (pathname, then abstract)
//! or TCP port `6000+N` for `host:N` / `localhost:N` / `ssh -X`, with
//! MIT-MAGIC-COOKIE-1 from Xauthority, and uploads an RGBA framebuffer with
//! PutImage. No Xlib, no C imports.
//!
//! Two layers:
//!   * `show(...)` — one-shot: open a window, draw an image, wait for a
//!     keypress / close.
//!   * `Window` — interactive: open/present/nextEvent/fd, with keyboard
//!     translation (GetKeyboardMapping, including Mod5/AltGr, group bits
//!     13–14, MappingNotify refresh that does not drop queued events, and
//!     bounded dead-key/Multi_key compose plus optional XCompose locale
//!     tables; compose resets on FocusOut), integer HiDPI scale (env +
//!     `Xft.dpi`, refreshed on root `RESOURCE_MANAGER` changes, XSETTINGS
//!     `Gdk/WindowScalingFactor` / `Xft/DPI`, RANDR
//!     `ScreenChangeNotify` plus cached per-output millimeters when the
//!     window moves, VisibilityNotify (skip Expose while fully obscured),
//!     XI2 touch mapped to the shared pointer contract when the device is
//!     not already pointer-emulating,
//!     with the
//!     core cursor and physical WM size hints reinstalled), ICCCM
//!     Mod2 NumLock keypad columns, Mod3 Mode_switch as group 2,
//!     CLIPBOARD+PRIMARY (INCR, UTF8_STRING then STRING/TEXT/GTK text MIME
//!     including `text/plain;charset=utf8`, `text/uri-list`,
//!     receive-only `text/x-uri-list`, receive-only `text/rtf`,
//!     receive-only `COMPOUND_TEXT`, receive-only desktop file-list MIME, and
//!     `UTF16_STRING`, TIMESTAMP, MULTIPLE atom-pair requests, Armenian/Georgian
//!     keysyms, extra Ukrainian/Belarusian/Serbian/Macedonian Cyrillic,
//!     Shift+Insert / XF86Paste CLIPBOARD paste as typed keys, receive-only
//!     `text/html`, ConvertSelection user timestamps, middle-click PRIMARY
//!     paste as typed keys (with `xclip`/`xsel` PRIMARY fallback; CLIPBOARD
//!     paste does not read PRIMARY and local text is used only while we
//!     still own CLIPBOARD), receive-only ISO-8859-1/2/3/4/5/6/7/8/9/15, Windows-1252, and Markdown MIME,
//!     invalid UTF-8 paste decoded as Latin-1, TARGETS-first XDND with
//!     position hover via TranslateCoordinates and LeaveNotify / XdndLeave
//!     hover clear,
//!     clipboard-manager handoff, UTF-8 BOM
//!     strip / UTF-16 decode), XDND text/`file:` drops injected as typed
//!     keys, `_NET_WM_STATE` maximize/fullscreen/hidden/shaded plus ICCCM
//!     FocusIn/leaving-hidden expose, `WM_STATE` / `WM_CHANGE_STATE` iconic tracking (`present()` skips
//!     while NET hidden, ICCCM iconic, unmapped, shaded, or fully obscured; MapNotify exposes), a scaled
//!     core pointer cursor, `_NET_WM_ICON` at 16/32/64/128 (reinstalled on scale change), urgency on `notify` (cleared on
//!     FocusIn), EWMH ping/type/icon name/user time/startup id plus
//!     `_NET_STARTUP_INFO` remove after MapWindow, outgoing `DESKTOP_STARTUP_ID`
//!     for `xdg-open`, EnterNotify cursor restore and pointer move
//!     (grab/ungrab and pointer-focus details ignored), wheel releases ignored,
//!     XSETTINGS owner re-watch after DestroyNotify (that owner does not close
//!     the chat),
//!     allowed actions,
//!     WM_TAKE_FOCUS, WM_LOCALE_NAME, physical WM size hints, and
//!     resize/close events, suitable for a poll(2)-driven client event loop.

const std = @import("std");
const linux = std.os.linux;
const net = std.Io.net;
const shared_event = @import("event.zig");
const services = @import("services.zig");
const xkb = @import("xkb.zig");

const image_depth = 24;
const z_pixmap = 2;

const input_output = 1;

const event_key_press: u32 = 1 << 0;
const event_button_press: u32 = 1 << 2;
const event_button_release: u32 = 1 << 3;
const event_enter_window: u32 = 1 << 4;
const event_leave_window: u32 = 1 << 5;
const notify_mode_grab: u8 = 1;
const notify_mode_ungrab: u8 = 2;
const notify_detail_pointer: u8 = 7;
const notify_detail_pointer_root: u8 = 8;
const event_pointer_motion: u32 = 1 << 6;
const event_exposure: u32 = 1 << 15;
const event_visibility_change: u32 = 1 << 16;
const event_structure: u32 = 1 << 17;
const visibility_fully_obscured: u8 = 2;
const generic_event: u8 = 35;
const xi_query_version: u8 = 47;
const xi_select_events: u8 = 46;
const xi_touch_begin: u16 = 18;
const xi_touch_update: u16 = 19;
const xi_touch_end: u16 = 20;
const xi_all_master_devices: u16 = 1;
const xi_touch_emulating_pointer: u32 = 1 << 17;
const max_randr_crtcs: usize = 8;
const event_focus_change: u32 = 1 << 21;
const event_property_change: u32 = 1 << 22;

const cw_back_pixel: u32 = 1 << 1;
const cw_border_pixel: u32 = 1 << 3;
const cw_event_mask: u32 = 1 << 11;

const gc_foreground: u32 = 1 << 2;
const gc_background: u32 = 1 << 3;

const atom_atom = 4;
const atom_cardinal = 6;
const atom_integer = 19;
const atom_string = 31;
const atom_primary = 1;
const atom_wm_class = 67;
const atom_wm_hints = 35;
const atom_wm_client_machine = 36;
const atom_wm_icon_name = 37;
const atom_wm_name = 39;
const atom_wm_normal_hints = 40;
const atom_wm_size_hints = 41;
const atom_resource_manager = 23;
const prop_replace = 0;
const property_new_value: u8 = 0;
const property_deleted: u8 = 1;
const size_hint_p_min: u32 = 1 << 4;
const size_hint_p_max: u32 = 1 << 5;
const size_hint_p_base: u32 = 1 << 8;
const incr_chunk_bytes: usize = 16 * 1024;
const family_internet: u16 = 0;
const family_local: u16 = 256;
const family_wild: u16 = 65535;
const max_clipboard_bytes = 1024 * 1024;

const request_put_image_header_units = 6;
const min_max_request_units = 64;

const XConn = struct {
    io: std.Io,
    stream: net.Stream,
    next_id: u32,
    resource_mask: u32,
    screen: Screen,
    max_request_units: u16,
    min_keycode: u8,
    max_keycode: u8,
    wm_protocols: u32 = 0,
    wm_delete_window: u32 = 0,
    clipboard: u32 = 0,
    utf8_string: u32 = 0,
    targets: u32 = 0,
    incr: u32 = 0,
    net_wm_name: u32 = 0,
    net_wm_icon_name: u32 = 0,
    net_wm_pid: u32 = 0,
    net_startup_id: u32 = 0,
    net_startup_info: u32 = 0,
    net_startup_info_begin: u32 = 0,
    net_wm_ping: u32 = 0,
    net_wm_user_time: u32 = 0,
    net_wm_window_type: u32 = 0,
    net_wm_window_type_normal: u32 = 0,
    net_wm_allowed_actions: u32 = 0,
    wm_take_focus: u32 = 0,
    wm_locale_name: u32 = 0,
    text: u32 = 0,
    timestamp: u32 = 0,
    clipboard_manager: u32 = 0,
    save_targets: u32 = 0,
    mime_text_plain: u32 = 0,
    mime_text_utf8: u32 = 0,
    mime_text_utf8_alt: u32 = 0,
    mime_uri_list: u32 = 0,
    xdnd_aware: u32 = 0,
    xdnd_enter: u32 = 0,
    xdnd_position: u32 = 0,
    xdnd_status: u32 = 0,
    xdnd_leave: u32 = 0,
    xdnd_drop: u32 = 0,
    xdnd_finished: u32 = 0,
    xdnd_selection: u32 = 0,
    xdnd_type_list: u32 = 0,
    xdnd_action_copy: u32 = 0,
    net_wm_state: u32 = 0,
    net_wm_state_max_horz: u32 = 0,
    net_wm_state_max_vert: u32 = 0,
    net_wm_state_fullscreen: u32 = 0,
    net_wm_icon: u32 = 0,
    net_wm_state_attention: u32 = 0,
    net_wm_state_hidden: u32 = 0,
    net_wm_state_shaded: u32 = 0,
    utf16_string: u32 = 0,
    mime_text_html: u32 = 0,
    mime_text_html_utf8: u32 = 0,
    mime_text_html_utf8_alt: u32 = 0,
    mime_gnome_copied: u32 = 0,
    mime_moz_url: u32 = 0,
    mime_moz_file: u32 = 0,
    mime_kde_urilist: u32 = 0,
    mime_nautilus: u32 = 0,
    mime_uri_list_alt: u32 = 0,
    mime_rtf: u32 = 0,
    mime_rtf_app: u32 = 0,
    compound_text: u32 = 0,
    mime_kde5_urilist: u32 = 0,
    mime_kde_suggestedfilename: u32 = 0,
    mime_moz_url_priv: u32 = 0,
    mime_text_latin1: u32 = 0,
    mime_text_latin1_alt: u32 = 0,
    mime_text_latin9: u32 = 0,
    mime_text_latin9_alt: u32 = 0,
    mime_text_latin2: u32 = 0,
    mime_text_latin2_alt: u32 = 0,
    mime_text_latin5: u32 = 0,
    mime_text_latin5_alt: u32 = 0,
    mime_text_cyrillic: u32 = 0,
    mime_text_cyrillic_alt: u32 = 0,
    mime_text_greek: u32 = 0,
    mime_text_greek_alt: u32 = 0,
    mime_text_latin3: u32 = 0,
    mime_text_latin3_alt: u32 = 0,
    mime_text_latin4: u32 = 0,
    mime_text_latin4_alt: u32 = 0,
    mime_text_arabic: u32 = 0,
    mime_text_arabic_alt: u32 = 0,
    mime_text_hebrew: u32 = 0,
    mime_text_hebrew_alt: u32 = 0,
    mime_text_cp1252: u32 = 0,
    mime_text_cp1252_alt: u32 = 0,
    mime_text_markdown: u32 = 0,
    mime_text_markdown_alt: u32 = 0,
    xsettings_s0: u32 = 0,
    xsettings_settings: u32 = 0,
    xsettings_window: u32 = 0,
    wm_state: u32 = 0,
    wm_change_state: u32 = 0,
    multiple: u32 = 0,
    atom_pair: u32 = 0,
    randr_opcode: u8 = 0,
    randr_event: u8 = 0,
    xi_opcode: u8 = 0,

    fn allocId(self: *XConn) !u32 {
        const slot = self.next_id & self.resource_mask;
        if (slot == 0 and self.next_id != 0) return error.ResourceIdsExhausted;
        self.next_id += 1;
        return (self.screen.resource_base & ~self.resource_mask) | slot;
    }
};

const ScaleSource = enum { env, xft, xsettings, physical, fallback };

const RandrCrtc = struct {
    x: i32 = 0,
    y: i32 = 0,
    width: u32 = 0,
    height: u32 = 0,
    width_mm: u32 = 0,
};

const Screen = struct {
    resource_base: u32,
    resource_mask: u32,
    root: u32,
    root_visual: u32,
    root_depth: u8,
    white_pixel: u32,
    black_pixel: u32,
    width_px: u16 = 0,
    width_mm: u16 = 0,
};

const Display = struct {
    host: []const u8,
    number: u16,
    local: bool,
};

const Auth = struct {
    name: []const u8 = &.{},
    data: []const u8 = &.{},
};

const Setup = struct {
    screen: Screen,
    max_request_units: u16,
    min_keycode: u8,
    max_keycode: u8,
};

// --- Events -----------------------------------------------------------------

pub const Key = shared_event.Key;
pub const Event = shared_event.Event;

// --- Keyboard mapping --------------------------------------------------------

/// Keycode → keysym table fetched with GetKeyboardMapping. Translation itself
/// is pure and testable without a server.
pub const Keymap = struct {
    syms: []u32,
    per: u8,
    min: u8,

    pub fn deinit(self: *Keymap, gpa: std.mem.Allocator) void {
        gpa.free(self.syms);
        self.* = undefined;
    }

    pub fn keysym(self: *const Keymap, keycode: u8, state: u16) u32 {
        if (keycode < self.min or self.per == 0) return 0;
        const idx = @as(usize, keycode - self.min) * self.per;
        if (idx >= self.syms.len) return 0;
        const s0 = self.syms[idx];
        const s1 = if (self.per > 1 and idx + 1 < self.syms.len) self.syms[idx + 1] else 0;
        const s2 = if (self.per > 2 and idx + 2 < self.syms.len) self.syms[idx + 2] else 0;
        const s3 = if (self.per > 3 and idx + 3 < self.syms.len) self.syms[idx + 3] else 0;

        const shift = (state & 0x1) != 0;
        const lock = (state & 0x2) != 0;
        const num_lock = (state & xkb.x11_mod2_num_lock) != 0;
        const level3 = (state & 0x80) != 0; // Mod5 / ISO_Level3_Shift
        var group = (state >> 13) & 0x3;
        if (group == 0 and (state & xkb.x11_mod3_mode_switch) != 0) group = 1;

        if (group != 0) {
            const g0_idx = idx + @as(usize, group) * 2;
            const key_end = idx + self.per;
            if (g0_idx < key_end and g0_idx < self.syms.len) {
                const g0 = self.syms[g0_idx];
                const g1 = if (g0_idx + 1 < key_end and g0_idx + 1 < self.syms.len) self.syms[g0_idx + 1] else 0;
                if (xkb.isX11KeypadKeysym(g0) or xkb.isX11KeypadKeysym(g1)) {
                    const grouped = if (xkb.keypadUsesNumeric(num_lock, shift) and g1 != 0) g1 else g0;
                    if (grouped != 0) return grouped;
                }
                var grouped = g0;
                if (shift and g1 != 0) grouped = g1;
                if ((shift and g1 == 0) or (lock and !shift)) {
                    if (grouped >= 'a' and grouped <= 'z') grouped -= 32;
                }
                if (grouped != 0) return grouped;
            }
        }

        if (level3 and (s2 != 0 or s3 != 0)) {
            if (shift and s3 != 0) return s3;
            if (s2 != 0) return s2;
        }

        if (xkb.isX11KeypadKeysym(s0) or xkb.isX11KeypadKeysym(s1)) {
            if (xkb.keypadUsesNumeric(num_lock, shift) and s1 != 0) return s1;
            return s0;
        }

        var sym = s0;
        if (shift and s1 != 0) sym = s1;
        // Alphabetic case rules (X11 §5): when the shifted column is NoSymbol,
        // the pair is the lower/upper case of column 0; CapsLock upcases too.
        if ((shift and s1 == 0) or (lock and !shift)) {
            if (sym >= 'a' and sym <= 'z') sym -= 32;
        }
        return sym;
    }

    pub fn translate(self: *const Keymap, keycode: u8, state: u16) Key {
        return keysymToKey(self.keysym(keycode, state));
    }
};

pub fn keysymToKey(sym: u32) Key {
    if (sym >= 0x20 and sym <= 0xff) return .{ .char = @intCast(sym) };
    if (sym >= 0x01000000 and sym <= 0x0110ffff) return .{ .char = @intCast(sym - 0x01000000) };
    if (xkb.charForX11Cyrillic(sym)) |ch| return .{ .char = ch };
    if (xkb.charForX11Latin2(sym)) |ch| return .{ .char = ch };
    if (xkb.charForX11Greek(sym)) |ch| return .{ .char = ch };
    if (xkb.charForX11Hebrew(sym)) |ch| return .{ .char = ch };
    if (xkb.charForX11Arabic(sym)) |ch| return .{ .char = ch };
    if (xkb.charForX11Latin9(sym)) |ch| return .{ .char = ch };
    if (xkb.charForX11Latin3(sym)) |ch| return .{ .char = ch };
    if (xkb.charForX11Latin4(sym)) |ch| return .{ .char = ch };
    if (xkb.charForX11Armenian(sym)) |ch| return .{ .char = ch };
    if (xkb.charForX11Georgian(sym)) |ch| return .{ .char = ch };
    if (xkb.charForX11Thai(sym)) |ch| return .{ .char = ch };
    return switch (sym) {
        0xff08 => .backspace,
        0xff09 => .tab,
        0xff0d, 0xff8d => .enter, // Return, KP_Enter
        0xff1b => .escape,
        0xff50, 0xff95 => .home,
        0xff51, 0xff96 => .left,
        0xff52, 0xff97 => .up,
        0xff53, 0xff98 => .right,
        0xff54, 0xff99 => .down,
        0xff57, 0xff9c => .end,
        0xff55, 0xff9a => .page_up,
        0xff56, 0xff9b => .page_down,
        0xffff, 0xff9f => .delete,
        0xffaa => .{ .char = '*' },
        0xffab => .{ .char = '+' },
        0xffac => .{ .char = ',' },
        0xffad => .{ .char = '-' },
        0xffae => .{ .char = '.' },
        0xffaf => .{ .char = '/' },
        0xffb0...0xffb9 => .{ .char = '0' + @as(u21, @intCast(sym - 0xffb0)) },
        else => .other,
    };
}

// --- One-shot viewer ----------------------------------------------------------

/// Open a local X11 window, draw `pixels` (0xAARRGGBB), and run until keypress
/// or WM close. DISPLAY is read at runtime; tests/builds do not need X.
pub fn show(gpa: std.mem.Allocator, pixels: []const u32, w: u32, h: u32) !void {
    const win = try Window.open(gpa, w, h, "comicchat");
    defer win.deinit();
    try win.present(pixels, w, h);
    while (true) {
        switch (try win.nextEvent()) {
            .key, .close => return,
            .expose => try win.present(pixels, w, h),
            else => {},
        }
    }
}

// --- Interactive window --------------------------------------------------------

/// A live X11 window. Heap-pinned (owns its Io runtime, whose vtable points
/// back into the struct), so `open` returns a pointer that must not move.
pub const Window = struct {
    gpa: std.mem.Allocator,
    threaded: std.Io.Threaded,
    conn: XConn,
    window: u32,
    gc: u32,
    width: u32,
    height: u32,
    pixel_width: u32,
    pixel_height: u32,
    scale: u32,
    keymap: Keymap,
    last_primary_click_ms: u32,
    last_primary_x: i32,
    last_primary_y: i32,
    clipboard_text: []u8,
    owns_clipboard: bool,
    owns_primary: bool,
    incr_requestor: u32,
    incr_property: u32,
    incr_target: u32,
    incr_offset: usize,
    clipboard_time: u32,
    last_user_time: u32,
    selection_time: u32,
    middle_paste: bool,
    compose_table: ?xkb.ComposeTable,
    compose: xkb.Compose,
    pending_chars: std.ArrayList(u21),
    xdnd_source: u32,
    xdnd_has_text: bool,
    wm_max_horz: bool,
    wm_max_vert: bool,
    wm_fullscreen: bool,
    cursor_id: u32,
    wm_urgent: bool,
    wm_hidden: bool,
    wm_net_hidden: bool,
    wm_icccm_hidden: bool,
    wm_unmapped: bool,
    wm_shaded: bool,
    fully_obscured: bool,
    scale_source: ScaleSource,
    randr_crtcs: [max_randr_crtcs]RandrCrtc,
    randr_crtc_count: u8,
    pending_events: std.ArrayList([32]u8),
    generic_extra: [64]u8 = @splat(0),
    generic_extra_len: usize = 0,
    touch_contact: ?u32 = null,
    xsettings_window: u32 = 0,

    pub fn open(gpa: std.mem.Allocator, w: u32, h: u32, title: []const u8) !*Window {
        if (w == 0 or h == 0 or w > std.math.maxInt(u16) or h > std.math.maxInt(u16)) {
            return error.InvalidWindowSize;
        }
        const display = try readDisplay(gpa);
        defer gpa.free(display);
        return openWithDisplay(gpa, w, h, title, display);
    }

    pub fn openWithDisplay(gpa: std.mem.Allocator, w: u32, h: u32, title: []const u8, display: []const u8) !*Window {
        if (w == 0 or h == 0 or w > std.math.maxInt(u16) or h > std.math.maxInt(u16)) {
            return error.InvalidWindowSize;
        }
        const parsed = try parseDisplay(display);
        const env = try services.readEnviron(gpa);
        defer gpa.free(env);

        const self = try gpa.create(Window);
        errdefer gpa.destroy(self);
        self.* = .{
            .gpa = gpa,
            .threaded = std.Io.Threaded.init(gpa, .{}),
            .conn = undefined,
            .window = 0,
            .gc = 0,
            .width = w,
            .height = h,
            .pixel_width = w,
            .pixel_height = h,
            .scale = 1,
            .keymap = .{ .syms = &.{}, .per = 0, .min = 0 },
            .last_primary_click_ms = 0,
            .last_primary_x = 0,
            .last_primary_y = 0,
            .clipboard_text = &.{},
            .owns_clipboard = false,
            .owns_primary = false,
            .incr_requestor = 0,
            .incr_property = 0,
            .incr_target = 0,
            .incr_offset = 0,
            .clipboard_time = 0,
            .last_user_time = 0,
            .selection_time = 0,
            .middle_paste = false,
            .compose_table = null,
            .compose = .{},
            .pending_chars = .empty,
            .xdnd_source = 0,
            .xdnd_has_text = false,
            .wm_max_horz = false,
            .wm_max_vert = false,
            .wm_fullscreen = false,
            .cursor_id = 0,
            .wm_urgent = false,
            .wm_hidden = false,
            .wm_net_hidden = false,
            .wm_icccm_hidden = false,
            .wm_unmapped = false,
            .wm_shaded = false,
            .fully_obscured = false,
            .scale_source = .fallback,
            .randr_crtcs = @splat(.{}),
            .randr_crtc_count = 0,
            .pending_events = .empty,
            .generic_extra = @splat(0),
            .generic_extra_len = 0,
            .touch_contact = null,
            .xsettings_window = 0,
        };
        self.loadComposeFromEnv(env);
        errdefer self.unloadCompose();
        errdefer self.threaded.deinit();
        const io = self.threaded.io();

        self.conn = try connectDisplay(gpa, io, parsed, env);
        errdefer self.conn.stream.close(io);
        if (self.conn.screen.root_depth != image_depth) return error.UnsupportedDepth;

        try internSessionAtoms(&self.conn);
        enableRandr(&self.conn) catch {};
        self.watchXsettings();
        const detected = try detectScale(gpa, &self.conn, env, &self.pending_events, 0, 0, 0, self.randrCrtcs());
        self.scale = detected.scale;
        self.scale_source = detected.source;
        const pixel_w = try std.math.mul(u32, w, self.scale);
        const pixel_h = try std.math.mul(u32, h, self.scale);
        if (pixel_w > std.math.maxInt(u16) or pixel_h > std.math.maxInt(u16)) return error.InvalidWindowSize;
        self.pixel_width = pixel_w;
        self.pixel_height = pixel_h;

        self.window = try self.conn.allocId();
        self.gc = try self.conn.allocId();
        try createWindow(&self.conn, self.window, @intCast(pixel_w), @intCast(pixel_h));
        enableXi2(&self.conn, self.window) catch {};
        try createGc(&self.conn, self.gc, self.window);
        try installWmClose(&self.conn, self.window);
        try setTitle(&self.conn, self.window, title);
        try setWmClass(&self.conn, self.window, "comicchat", "Reinked");
        try setNetWmPid(&self.conn, self.window);
        try setNetStartupId(&self.conn, self.window, env);
        try setWmHints(&self.conn, self.window);
        try setNetWmWindowType(&self.conn, self.window);
        try setAllowedActions(&self.conn, self.window);
        try setWmLocaleName(&self.conn, self.window, env);
        try setClientMachine(&self.conn, self.window);
        try setSizeHints(&self.conn, self.window, pixel_w, pixel_h, self.scale);
        try setXdndAware(&self.conn, self.window);
        try setNetWmState(&self.conn, self.window, &.{});
        try selectRootPropertyNotify(&self.conn);
        try setNetWmIcon(self.gpa, &self.conn, self.window);
        self.cursor_id = installScaledCursor(self.gpa, &self.conn, self.window, self.scale, env, &self.pending_events) catch 0;
        self.keymap = try fetchKeymap(gpa, &self.conn);
        errdefer self.keymap.deinit(gpa);
        try mapWindow(&self.conn, self.window);
        sendStartupRemove(&self.conn, self.window, env) catch {};
        self.refreshRandrCrtcs();
        if (self.refreshOutputScale()) |_| {}
        return self;
    }

    pub fn deinit(self: *Window) void {
        self.handoverClipboard();
        if (self.clipboard_text.len != 0) self.gpa.free(self.clipboard_text);
        self.keymap.deinit(self.gpa);
        self.conn.stream.close(self.conn.io);
        self.threaded.deinit();
        self.pending_chars.deinit(self.gpa);
        self.pending_events.deinit(self.gpa);
        if (self.cursor_id != 0) freeCursor(&self.conn, self.cursor_id) catch {};
        self.unloadCompose();
        self.gpa.destroy(self);
    }

    fn loadComposeFromEnv(self: *Window, env: []const u8) void {
        self.compose_table = xkb.loadComposeTable(self.gpa, env) catch null;
        if (self.compose_table) |*table| {
            self.compose.table = table;
        }
    }

    fn unloadCompose(self: *Window) void {
        self.compose.table = null;
        self.compose.reset();
        if (self.compose_table) |*table| {
            table.deinit();
            self.compose_table = null;
        }
    }

    /// Socket handle, for poll(2)-based event loops.
    pub fn fd(self: *const Window) i32 {
        return self.conn.stream.socket.handle;
    }

    /// Upload a full logical frame. `w`/`h` are logical pixels; HiDPI scale is
    /// applied here so the client keeps 96-DPI geometry.
    pub fn present(self: *Window, pixels: []const u32, w: u32, h: u32) !void {
        if (self.wm_hidden or self.fully_obscured) return;
        if (pixels.len != @as(usize, w) * @as(usize, h)) return error.BadFramebufferSize;
        if (self.scale <= 1) {
            try putImage(self.gpa, &self.conn, self.window, self.gc, pixels, w, h);
            return;
        }
        const pixel_w = try std.math.mul(u32, w, self.scale);
        const pixel_h = try std.math.mul(u32, h, self.scale);
        const scaled = try self.gpa.alloc(u32, try std.math.mul(usize, @as(usize, pixel_w), @as(usize, pixel_h)));
        defer self.gpa.free(scaled);
        scaleNearest(scaled, pixels, w, h, self.scale);
        try putImage(self.gpa, &self.conn, self.window, self.gc, scaled, pixel_w, pixel_h);
    }

    pub fn writeClipboard(self: *Window, text: []const u8) !void {
        if (self.writeClipboardNative(text)) |_| return else |_| {
            return services.writeClipboard(self.conn.io, .x11, text);
        }
    }

    pub fn readClipboard(self: *Window, gpa: std.mem.Allocator) !?[]u8 {
        if (self.readClipboardNative(gpa)) |text| {
            return text;
        } else |_| {
            return services.readClipboard(gpa, self.conn.io, .x11);
        }
    }

    pub fn chooseFile(self: *Window, gpa: std.mem.Allocator, save: bool, title: []const u8) !?[]u8 {
        return services.chooseFile(gpa, self.conn.io, save, title);
    }

    pub fn openPath(self: *Window, gpa: std.mem.Allocator, path: []const u8) !void {
        var token_buf: [80]u8 = undefined;
        const time: u32 = if (self.last_user_time != 0) self.last_user_time else 1;
        return services.openPathActivated(gpa, self.conn.io, path, services.generatedStartupIdTimed(&token_buf, time));
    }

    pub fn printPath(self: *Window, gpa: std.mem.Allocator, path: []const u8) !void {
        return services.printPath(gpa, self.conn.io, path);
    }

    pub fn notify(self: *Window, gpa: std.mem.Allocator, title: []const u8, body: []const u8) !void {
        self.demandAttention();
        return services.notify(gpa, self.conn.io, title, body);
    }

    /// Blocking read of the next event. Call only when data is available
    /// (after poll) to avoid stalling, or when blocking is intended.
    pub fn nextEvent(self: *Window) !Event {
        if (self.takePendingKey()) |event| return event;
        if (self.pending_events.items.len != 0) {
            const raw = self.pending_events.orderedRemove(0);
            return self.decode(raw);
        }
        var raw: [32]u8 = undefined;
        try readExact(&self.conn, &raw);
        self.generic_extra_len = consumeGenericExtra(&self.conn, raw, &self.generic_extra) catch 0;
        return self.decode(raw);
    }

    fn decode(self: *Window, event: [32]u8) Event {
        const kind = event[0] & 0x7f;
        if (self.conn.randr_event != 0 and kind == self.conn.randr_event) {
            return self.handleRandrScreenChange(event);
        }
        if (kind == generic_event) return self.decodeXiTouch(event);
        switch (kind) {
            0 => return .close, // request error; treat as fatal for the UI
            2 => { // KeyPress
                self.noteUserTime(get32(event[4..8]));
                const keycode = event[1];
                const state = get16(event[28..30]);
                const modifiers = shared_event.Modifiers{
                    .shift = state & 1 != 0,
                    .control = state & 4 != 0,
                    .alt = state & 8 != 0 or state & 0x80 != 0,
                    .super = state & 64 != 0,
                };
                if (xkb.isClipboardPasteKeysym(self.keymap.keysym(keycode, state), modifiers.shift, modifiers.control)) {
                    if (self.pasteClipboardAsKeys()) |ev| return ev;
                }
                const key = self.translateComposed(keycode, state, modifiers.control);
                if (key == null) return .other;
                return .{ .key = .{ .key = key.?, .modifiers = modifiers } };
            },
            4, 5, 6 => {
                if (kind != 6) self.noteUserTime(get32(event[4..8]));
                const raw_x: i32 = @as(i16, @bitCast(get16(event[24..26])));
                const raw_y: i32 = @as(i16, @bitCast(get16(event[26..28])));
                const x = physicalPointToLogical(raw_x, self.scale);
                const y = physicalPointToLogical(raw_y, self.scale);
                if (kind == 6) return .{ .pointer = .{ .kind = .move, .x = x, .y = y } };
                const detail = event[1];
                if (detail == 4 or detail == 5) {
                    if (kind != 4) return .other;
                    return .{ .pointer = .{
                        .kind = .wheel,
                        .x = x,
                        .y = y,
                        .wheel_y = if (detail == 4) 1 else -1,
                    } };
                }
                if (detail >= 6) return .other;
                const button: shared_event.PointerButton = switch (detail) {
                    1 => .primary,
                    2 => .middle,
                    3 => .secondary,
                    else => .none,
                };
                if (kind == 4 and button == .middle) {
                    if (self.pastePrimaryAsKeys()) |ev| {
                        self.middle_paste = true;
                        return ev;
                    }
                }
                if (kind == 5 and button == .middle and self.middle_paste) {
                    self.middle_paste = false;
                    return .other;
                }
                var clicks: u8 = 1;
                if (kind == 4 and button == .primary) {
                    const now = get32(event[4..8]);
                    const near = @abs(x - self.last_primary_x) <= 4 and @abs(y - self.last_primary_y) <= 4;
                    if (near and now -% self.last_primary_click_ms <= 500) clicks = 2;
                    self.last_primary_click_ms = now;
                    self.last_primary_x = x;
                    self.last_primary_y = y;
                }
                if (kind == 4) self.claimFocus(get32(event[4..8]));
                return .{ .pointer = .{
                    .kind = if (kind == 4) .down else .up,
                    .x = x,
                    .y = y,
                    .button = button,
                    .clicks = clicks,
                } };
            },
            7 => { // EnterNotify
                if (x11NotifyModeIsGrab(event[30])) return .other;
                self.noteUserTime(get32(event[4..8]));
                if (self.cursor_id != 0) defineCursor(&self.conn, self.window, self.cursor_id) catch {};
                const raw_x: i32 = @as(i16, @bitCast(get16(event[24..26])));
                const raw_y: i32 = @as(i16, @bitCast(get16(event[26..28])));
                return .{ .pointer = .{
                    .kind = .move,
                    .x = physicalPointToLogical(raw_x, self.scale),
                    .y = physicalPointToLogical(raw_y, self.scale),
                } };
            },
            8 => { // LeaveNotify
                if (x11NotifyModeIsGrab(event[30])) return .other;
                return .{ .pointer = .{ .kind = .move, .x = -1, .y = -1 } };
            },
            9 => { // FocusIn
                if (x11NotifyModeIsGrab(event[8]) or x11FocusDetailIsPointer(event[1])) return .other;
                self.clearAttention();
                self.claimFocus(self.last_user_time);
                return .expose;
            },
            10 => { // FocusOut
                if (x11NotifyModeIsGrab(event[8]) or x11FocusDetailIsPointer(event[1])) return .other;
                self.compose.reset();
                return .other;
            },
            18 => { // UnmapNotify
                if (!self.structureEventIsOurs(event)) return .other;
                self.wm_unmapped = true;
                self.syncHidden();
                return .other;
            },
            19 => { // MapNotify
                if (!self.structureEventIsOurs(event)) return .other;
                self.wm_unmapped = false;
                self.readWmState();
                self.refreshRandrCrtcs();
                if (self.refreshOutputScale()) |ev| return ev;
                return .expose;
            },
            15 => { // VisibilityNotify
                const was_obscured = self.fully_obscured;
                self.fully_obscured = visibilityIsFullyObscured(event[8]);
                if (was_obscured and !self.fully_obscured) return .expose;
                return .other;
            },
            34 => { // MappingNotify
                if (event[1] == 1) self.refreshKeymap();
                return .other;
            },
            12 => { // Expose
                if (self.fully_obscured) return .other;
                return .expose;
            },
            17 => { // DestroyNotify
                const event_win = get32(event[4..8]);
                const destroyed = get32(event[8..12]);
                if (destroyed == self.window or event_win == self.window) return .close;
                if (self.conn.xsettings_window != 0 and
                    (destroyed == self.conn.xsettings_window or event_win == self.conn.xsettings_window))
                {
                    self.xsettings_window = 0;
                    self.conn.xsettings_window = 0;
                    self.watchXsettings();
                    if (self.refreshScale()) |ev| return ev;
                }
                return .other;
            },
            22 => { // ConfigureNotify
                if (!self.structureEventIsOurs(event)) return .other;
                const pixel_w: u32 = get16(event[20..22]);
                const pixel_h: u32 = get16(event[22..24]);
                if (pixel_w == 0 or pixel_h == 0) return .other;
                const size_changed = pixel_w != self.pixel_width or pixel_h != self.pixel_height;
                self.pixel_width = pixel_w;
                self.pixel_height = pixel_h;
                const scale_ev = self.refreshOutputScale();
                const w = physicalToLogical(pixel_w, self.scale);
                const h = physicalToLogical(pixel_h, self.scale);
                if (w != self.width or h != self.height) {
                    self.width = w;
                    self.height = h;
                    return .{ .resize = .{ .w = w, .h = h } };
                }
                if (size_changed) {
                    self.width = w;
                    self.height = h;
                    return .{ .resize = .{ .w = w, .h = h } };
                }
                return scale_ev orelse .other;
            },
            28 => { // PropertyNotify
                const window = get32(event[4..8]);
                const atom = get32(event[8..12]);
                if (window == self.conn.screen.root and atom == atom_resource_manager) {
                    if (self.refreshScale()) |ev| return ev;
                }
                if (self.conn.xsettings_window != 0 and window == self.conn.xsettings_window and atom == self.conn.xsettings_settings) {
                    if (self.refreshScale()) |ev| return ev;
                }
                if (window == self.window and atom == self.conn.net_wm_state) {
                    const was_hidden = self.wm_hidden;
                    self.readNetWmState();
                    if (was_hidden and !self.wm_hidden) return .expose;
                }
                if (window == self.window and atom == self.conn.wm_state) {
                    const was_hidden = self.wm_hidden;
                    self.readWmState();
                    if (was_hidden and !self.wm_hidden) return .expose;
                }
                self.continueIncr(event);
                return .other;
            },
            29 => { // SelectionClear
                self.handleSelectionClear(event);
                return .other;
            },
            30 => { // SelectionRequest
                self.serveSelectionRequest(event) catch {};
                return .other;
            },
            33 => { // ClientMessage
                const typ = get32(event[8..12]);
                if (typ == self.conn.wm_protocols) {
                    const protocol = get32(event[12..16]);
                    if (protocol == self.conn.wm_delete_window) return .close;
                    if (self.conn.net_wm_ping != 0 and protocol == self.conn.net_wm_ping) {
                        self.replyNetWmPing(event) catch {};
                    }
                    if (self.conn.wm_take_focus != 0 and protocol == self.conn.wm_take_focus) {
                        self.claimFocus(get32(event[16..20]));
                    }
                } else if (typ == self.conn.xdnd_enter) {
                    self.handleXdndEnter(event);
                } else if (typ == self.conn.xdnd_position) {
                    if (self.handleXdndPosition(event) catch null) |ev| return ev;
                } else if (typ == self.conn.xdnd_leave) {
                    self.xdnd_source = 0;
                    self.xdnd_has_text = false;
                    return .{ .pointer = .{ .kind = .move, .x = -1, .y = -1 } };
                } else if (typ == self.conn.xdnd_drop) {
                    if (self.takeXdndDrop(event)) |ev| return ev;
                } else if (typ == self.conn.net_wm_state) {
                    const was_hidden = self.wm_hidden;
                    self.applyNetWmStateMessage(event);
                    if (was_hidden and !self.wm_hidden) return .expose;
                } else if (typ == self.conn.wm_change_state) {
                    const was_hidden = self.wm_hidden;
                    self.applyWmChangeState(event);
                    if (was_hidden and !self.wm_hidden) return .expose;
                }
                return .other;
            },
            else => return .other,
        }
    }

    fn writeClipboardNative(self: *Window, text: []const u8) !void {
        if (text.len > max_clipboard_bytes) return error.ClipboardTooLarge;
        if (self.conn.clipboard == 0) return error.ClipboardUnavailable;
        const copy = try self.gpa.dupe(u8, text);
        if (self.clipboard_text.len != 0) self.gpa.free(self.clipboard_text);
        self.clipboard_text = copy;
        self.clipboard_time = if (self.last_user_time != 0) self.last_user_time else 1;
        try setSelectionOwner(&self.conn, self.window, self.conn.clipboard, self.clipboard_time);
        try setSelectionOwner(&self.conn, self.window, atom_primary, self.clipboard_time);
        self.owns_clipboard = true;
        self.owns_primary = true;
    }

    fn readClipboardNative(self: *Window, gpa: std.mem.Allocator) !?[]u8 {
        if (self.owns_clipboard) {
            if (self.clipboard_text.len == 0) return null;
            return try gpa.dupe(u8, self.clipboard_text);
        }
        if (self.conn.clipboard == 0 or self.conn.utf8_string == 0) return error.ClipboardUnavailable;
        if (self.convertAndRead(gpa, self.conn.clipboard)) |text| {
            if (text != null) return text;
        } else |_| {}
        return null;
    }

    fn decodeClipboardBytes(_: *Window, gpa: std.mem.Allocator, bytes: []u8) ![]u8 {
        const decoded = services.clipboardBytesToUtf8(gpa, bytes) catch return bytes;
        gpa.free(bytes);
        return decoded;
    }

    fn convertAndRead(self: *Window, gpa: std.mem.Allocator, selection: u32) !?[]u8 {
        if (self.bestOfferedTextTarget(gpa, selection)) |target| {
            if (self.readOneTextTarget(gpa, selection, target)) |text| {
                if (text != null) return text;
            } else |_| {}
        }
        if (self.convertTarget(gpa, selection, self.conn.utf8_string, self.conn.utf8_string)) |text| {
            if (text) |bytes| {
                if (bytes.len != 0) return try self.decodeClipboardBytes(gpa, bytes);
                gpa.free(bytes);
            }
        } else |_| {}
        if (self.convertTarget(gpa, selection, atom_string, atom_string)) |text| {
            if (text) |bytes| {
                if (bytes.len != 0) return try self.decodeClipboardBytes(gpa, bytes);
                gpa.free(bytes);
            }
        } else |_| {}
        if (self.conn.mime_text_utf8 != 0) {
            if (self.convertTarget(gpa, selection, self.conn.mime_text_utf8, self.conn.mime_text_utf8)) |text| {
                if (text) |bytes| {
                    if (bytes.len != 0) return try self.decodeClipboardBytes(gpa, bytes);
                    gpa.free(bytes);
                }
            } else |_| {}
        }
        if (self.conn.mime_text_utf8_alt != 0) {
            if (self.convertTarget(gpa, selection, self.conn.mime_text_utf8_alt, self.conn.mime_text_utf8_alt)) |text| {
                if (text) |bytes| {
                    if (bytes.len != 0) return try self.decodeClipboardBytes(gpa, bytes);
                    gpa.free(bytes);
                }
            } else |_| {}
        }
        if (self.conn.mime_text_plain != 0) {
            if (self.convertTarget(gpa, selection, self.conn.mime_text_plain, self.conn.mime_text_plain)) |text| {
                if (text) |bytes| {
                    if (bytes.len != 0) return try self.decodeClipboardBytes(gpa, bytes);
                    gpa.free(bytes);
                }
            } else |_| {}
        }
        if (self.conn.utf16_string != 0) {
            if (self.convertTarget(gpa, selection, self.conn.utf16_string, self.conn.utf16_string)) |text| {
                if (text) |bytes| {
                    if (bytes.len != 0) {
                        const decoded = services.clipboardUtf16BytesToUtf8(gpa, bytes) catch {
                            return try self.decodeClipboardBytes(gpa, bytes);
                        };
                        gpa.free(bytes);
                        return decoded;
                    }
                    gpa.free(bytes);
                }
            } else |_| {}
        }
        if (self.conn.mime_uri_list != 0) {
            if (self.convertTarget(gpa, selection, self.conn.mime_uri_list, self.conn.mime_uri_list)) |text| {
                if (text) |bytes| {
                    if (self.takeUriListPath(gpa, bytes)) |path| return path;
                    if (bytes.len != 0) return try self.decodeClipboardBytes(gpa, bytes);
                    gpa.free(bytes);
                }
            } else |_| {}
        }
        if (self.conn.mime_uri_list_alt != 0) {
            if (self.convertTarget(gpa, selection, self.conn.mime_uri_list_alt, self.conn.mime_uri_list_alt)) |text| {
                if (text) |bytes| {
                    if (self.takeUriListPath(gpa, bytes)) |path| return path;
                    if (bytes.len != 0) return try self.decodeClipboardBytes(gpa, bytes);
                    gpa.free(bytes);
                }
            } else |_| {}
        }
        if (self.readDesktopFileTarget(gpa, selection, self.conn.mime_gnome_copied)) |path| return path;
        if (self.readDesktopFileTarget(gpa, selection, self.conn.mime_moz_url)) |path| return path;
        if (self.readDesktopFileTarget(gpa, selection, self.conn.mime_moz_file)) |path| return path;
        if (self.readDesktopFileTarget(gpa, selection, self.conn.mime_kde_urilist)) |path| return path;
        if (self.readDesktopFileTarget(gpa, selection, self.conn.mime_kde5_urilist)) |path| return path;
        if (self.readDesktopFileTarget(gpa, selection, self.conn.mime_kde_suggestedfilename)) |path| return path;
        if (self.readDesktopFileTarget(gpa, selection, self.conn.mime_nautilus)) |path| return path;
        if (self.readDesktopFileTarget(gpa, selection, self.conn.mime_moz_url_priv)) |path| return path;
        if (self.readCompoundTextTarget(gpa, selection, self.conn.compound_text)) |text| return text;
        if (self.conn.text == 0) return null;
        if (self.convertTarget(gpa, selection, self.conn.text, self.conn.text)) |text| {
            if (text) |bytes| return try self.decodeTextBytes(gpa, bytes);
        } else |_| {}
        if (self.readHtmlTarget(gpa, selection, self.conn.mime_text_html)) |text| return text;
        if (self.readHtmlTarget(gpa, selection, self.conn.mime_text_html_utf8)) |text| return text;
        if (self.readHtmlTarget(gpa, selection, self.conn.mime_text_html_utf8_alt)) |text| return text;
        if (self.readRtfTarget(gpa, selection, self.conn.mime_rtf)) |text| return text;
        if (self.readRtfTarget(gpa, selection, self.conn.mime_rtf_app)) |text| return text;
        if (self.readCharsetTarget(gpa, selection, self.conn.mime_text_latin1, "ISO-8859-1")) |text| return text;
        if (self.readCharsetTarget(gpa, selection, self.conn.mime_text_latin1_alt, "ISO-8859-1")) |text| return text;
        if (self.readCharsetTarget(gpa, selection, self.conn.mime_text_latin9, "ISO-8859-15")) |text| return text;
        if (self.readCharsetTarget(gpa, selection, self.conn.mime_text_latin9_alt, "ISO-8859-15")) |text| return text;
        if (self.readCharsetTarget(gpa, selection, self.conn.mime_text_latin2, "ISO-8859-2")) |text| return text;
        if (self.readCharsetTarget(gpa, selection, self.conn.mime_text_latin2_alt, "ISO-8859-2")) |text| return text;
        if (self.readCharsetTarget(gpa, selection, self.conn.mime_text_latin5, "ISO-8859-9")) |text| return text;
        if (self.readCharsetTarget(gpa, selection, self.conn.mime_text_latin5_alt, "ISO-8859-9")) |text| return text;
        if (self.readCharsetTarget(gpa, selection, self.conn.mime_text_cyrillic, "ISO-8859-5")) |text| return text;
        if (self.readCharsetTarget(gpa, selection, self.conn.mime_text_cyrillic_alt, "ISO-8859-5")) |text| return text;
        if (self.readCharsetTarget(gpa, selection, self.conn.mime_text_greek, "ISO-8859-7")) |text| return text;
        if (self.readCharsetTarget(gpa, selection, self.conn.mime_text_greek_alt, "ISO-8859-7")) |text| return text;
        if (self.readCharsetTarget(gpa, selection, self.conn.mime_text_latin3, "ISO-8859-3")) |text| return text;
        if (self.readCharsetTarget(gpa, selection, self.conn.mime_text_latin3_alt, "ISO-8859-3")) |text| return text;
        if (self.readCharsetTarget(gpa, selection, self.conn.mime_text_latin4, "ISO-8859-4")) |text| return text;
        if (self.readCharsetTarget(gpa, selection, self.conn.mime_text_latin4_alt, "ISO-8859-4")) |text| return text;
        if (self.readCharsetTarget(gpa, selection, self.conn.mime_text_arabic, "ISO-8859-6")) |text| return text;
        if (self.readCharsetTarget(gpa, selection, self.conn.mime_text_arabic_alt, "ISO-8859-6")) |text| return text;
        if (self.readCharsetTarget(gpa, selection, self.conn.mime_text_hebrew, "ISO-8859-8")) |text| return text;
        if (self.readCharsetTarget(gpa, selection, self.conn.mime_text_hebrew_alt, "ISO-8859-8")) |text| return text;
        if (self.readCharsetTarget(gpa, selection, self.conn.mime_text_cp1252, "windows-1252")) |text| return text;
        if (self.readCharsetTarget(gpa, selection, self.conn.mime_text_cp1252_alt, "windows-1252")) |text| return text;
        if (self.readPlainTarget(gpa, selection, self.conn.mime_text_markdown)) |text| return text;
        if (self.readPlainTarget(gpa, selection, self.conn.mime_text_markdown_alt)) |text| return text;
        if (self.readDesktopFileTarget(gpa, selection, self.conn.mime_uri_list_alt)) |path| return path;
        return null;
    }

    fn readRtfTarget(self: *Window, gpa: std.mem.Allocator, selection: u32, target: u32) ?[]u8 {
        if (target == 0) return null;
        const text = (self.convertTarget(gpa, selection, target, target) catch return null) orelse return null;
        if (text.len == 0) {
            gpa.free(text);
            return null;
        }
        return self.decodeRtfBytes(gpa, text) catch null;
    }

    fn readHtmlTarget(self: *Window, gpa: std.mem.Allocator, selection: u32, target: u32) ?[]u8 {
        if (target == 0) return null;
        const text = (self.convertTarget(gpa, selection, target, target) catch return null) orelse return null;
        if (text.len == 0) {
            gpa.free(text);
            return null;
        }
        return self.decodeHtmlBytes(gpa, text) catch null;
    }

    fn decodeHtmlBytes(self: *Window, gpa: std.mem.Allocator, bytes: []u8) ![]u8 {
        const decoded = try self.decodeClipboardBytes(gpa, bytes);
        const plain = services.htmlToPlainText(gpa, decoded) catch return decoded;
        gpa.free(decoded);
        return plain;
    }

    fn decodeRtfBytes(self: *Window, gpa: std.mem.Allocator, bytes: []u8) ![]u8 {
        const decoded = try self.decodeClipboardBytes(gpa, bytes);
        const plain = services.rtfToPlainText(gpa, decoded) catch return decoded;
        gpa.free(decoded);
        return plain;
    }

    fn bestOfferedTextTarget(self: *Window, gpa: std.mem.Allocator, selection: u32) ?u32 {
        if (self.conn.targets == 0) return null;
        const bytes = (self.convertTarget(gpa, selection, self.conn.targets, self.conn.targets) catch return null) orelse return null;
        defer gpa.free(bytes);
        return preferredTextAtom(&self.conn, bytes);
    }

    fn readOneTextTarget(self: *Window, gpa: std.mem.Allocator, selection: u32, target: u32) !?[]u8 {
        if (target == 0) return null;
        const text = try self.convertTarget(gpa, selection, target, target);
        const bytes = text orelse return null;
        if (bytes.len == 0) {
            gpa.free(bytes);
            return null;
        }
        if (isUriListAtom(&self.conn, target) or isDesktopFileAtom(&self.conn, target)) {
            if (self.takeUriListPath(gpa, bytes)) |path| return path;
        }
        if (target == self.conn.utf16_string) {
            const decoded = services.clipboardUtf16BytesToUtf8(gpa, bytes) catch {
                return try self.decodeClipboardBytes(gpa, bytes);
            };
            gpa.free(bytes);
            return decoded;
        }
        if (isHtmlAtom(&self.conn, target)) {
            return try self.decodeHtmlBytes(gpa, bytes);
        }
        if (isRtfAtom(&self.conn, target)) {
            return try self.decodeRtfBytes(gpa, bytes);
        }
        if (target == self.conn.compound_text or target == self.conn.text) {
            return try self.decodeTextBytes(gpa, bytes);
        }
        if (isLatin1Atom(&self.conn, target)) {
            const decoded = services.decodePlainByCharset(gpa, bytes, "ISO-8859-1") catch return bytes;
            gpa.free(bytes);
            return decoded;
        }
        if (isLatin9Atom(&self.conn, target)) {
            const decoded = services.decodePlainByCharset(gpa, bytes, "ISO-8859-15") catch return bytes;
            gpa.free(bytes);
            return decoded;
        }
        if (isLatin2Atom(&self.conn, target)) {
            const decoded = services.decodePlainByCharset(gpa, bytes, "ISO-8859-2") catch return bytes;
            gpa.free(bytes);
            return decoded;
        }
        if (isLatin5Atom(&self.conn, target)) {
            const decoded = services.decodePlainByCharset(gpa, bytes, "ISO-8859-9") catch return bytes;
            gpa.free(bytes);
            return decoded;
        }
        if (isCyrillicAtom(&self.conn, target)) {
            const decoded = services.decodePlainByCharset(gpa, bytes, "ISO-8859-5") catch return bytes;
            gpa.free(bytes);
            return decoded;
        }
        if (isGreekAtom(&self.conn, target)) {
            const decoded = services.decodePlainByCharset(gpa, bytes, "ISO-8859-7") catch return bytes;
            gpa.free(bytes);
            return decoded;
        }
        if (isLatin3Atom(&self.conn, target)) {
            const decoded = services.decodePlainByCharset(gpa, bytes, "ISO-8859-3") catch return bytes;
            gpa.free(bytes);
            return decoded;
        }
        if (isLatin4Atom(&self.conn, target)) {
            const decoded = services.decodePlainByCharset(gpa, bytes, "ISO-8859-4") catch return bytes;
            gpa.free(bytes);
            return decoded;
        }
        if (isArabicAtom(&self.conn, target)) {
            const decoded = services.decodePlainByCharset(gpa, bytes, "ISO-8859-6") catch return bytes;
            gpa.free(bytes);
            return decoded;
        }
        if (isHebrewAtom(&self.conn, target)) {
            const decoded = services.decodePlainByCharset(gpa, bytes, "ISO-8859-8") catch return bytes;
            gpa.free(bytes);
            return decoded;
        }
        if (isCp1252Atom(&self.conn, target)) {
            const decoded = services.decodePlainByCharset(gpa, bytes, "windows-1252") catch return bytes;
            gpa.free(bytes);
            return decoded;
        }
        return try self.decodeClipboardBytes(gpa, bytes);
    }

    fn readCharsetTarget(self: *Window, gpa: std.mem.Allocator, selection: u32, target: u32, charset: []const u8) ?[]u8 {
        if (target == 0) return null;
        const text = (self.convertTarget(gpa, selection, target, target) catch return null) orelse return null;
        const decoded = services.decodePlainByCharset(gpa, text, charset) catch {
            gpa.free(text);
            return null;
        };
        gpa.free(text);
        return decoded;
    }

    fn readPlainTarget(self: *Window, gpa: std.mem.Allocator, selection: u32, target: u32) ?[]u8 {
        if (target == 0) return null;
        const text = (self.convertTarget(gpa, selection, target, target) catch return null) orelse return null;
        return self.decodeClipboardBytes(gpa, text) catch null;
    }

    fn readCompoundTextTarget(self: *Window, gpa: std.mem.Allocator, selection: u32, target: u32) ?[]u8 {
        if (target == 0) return null;
        const text = (self.convertTarget(gpa, selection, target, target) catch return null) orelse return null;
        return self.decodeTextBytes(gpa, text) catch null;
    }

    fn decodeTextBytes(_: *Window, gpa: std.mem.Allocator, bytes: []u8) ![]u8 {
        const decoded = services.compoundTextToUtf8(gpa, bytes) catch return bytes;
        gpa.free(bytes);
        return decoded;
    }

    fn readDesktopFileTarget(self: *Window, gpa: std.mem.Allocator, selection: u32, target: u32) ?[]u8 {
        if (target == 0) return null;
        const text = (self.convertTarget(gpa, selection, target, target) catch return null) orelse return null;
        if (self.takeUriListPath(gpa, text)) |path| return path;
        gpa.free(text);
        return null;
    }

    fn takeUriListPath(_: *Window, gpa: std.mem.Allocator, bytes: []u8) ?[]u8 {
        var scratch: [1024]u8 = undefined;
        const path = services.firstPathFromDesktopFiles(bytes, &scratch) orelse
            services.firstPathFromUriList(bytes, &scratch) orelse return null;
        const owned = gpa.dupe(u8, path) catch return null;
        gpa.free(bytes);
        return owned;
    }

    fn convertStamp(self: *const Window) u32 {
        if (self.selection_time != 0) return self.selection_time;
        if (self.last_user_time != 0) return self.last_user_time;
        return 1;
    }

    fn pastePrimaryAsKeys(self: *Window) ?Event {
        const bytes = self.takePrimaryBytes() orelse return null;
        defer self.gpa.free(bytes);
        return self.enqueueDropText(bytes) catch null;
    }

    fn pasteClipboardAsKeys(self: *Window) ?Event {
        const bytes = self.takeClipboardBytes() orelse return null;
        defer self.gpa.free(bytes);
        return self.enqueueDropText(bytes) catch null;
    }

    fn takeClipboardBytes(self: *Window) ?[]u8 {
        if (self.readClipboardNative(self.gpa)) |text| {
            if (text) |bytes| return bytes;
        } else |_| {}
        return services.readClipboard(self.gpa, self.conn.io, .x11) catch null;
    }

    fn takePrimaryBytes(self: *Window) ?[]u8 {
        if (self.readPrimaryNative(self.gpa)) |text| {
            if (text) |bytes| return bytes;
        } else |_| {}
        return services.readPrimary(self.gpa, self.conn.io, .x11) catch null;
    }

    fn readPrimaryNative(self: *Window, gpa: std.mem.Allocator) !?[]u8 {
        if (self.owns_primary or self.owns_clipboard) {
            if (self.clipboard_text.len == 0) return null;
            return try gpa.dupe(u8, self.clipboard_text);
        }
        return self.convertAndRead(gpa, atom_primary);
    }

    fn convertTarget(self: *Window, gpa: std.mem.Allocator, selection: u32, target: u32, property: u32) !?[]u8 {
        try convertSelection(&self.conn, self.window, selection, target, property, self.convertStamp());
        var attempts: u16 = 0;
        while (attempts < 64) : (attempts += 1) {
            var raw: [32]u8 = undefined;
            try readExact(&self.conn, &raw);
            self.generic_extra_len = consumeGenericExtra(&self.conn, raw, &self.generic_extra) catch 0;
            const kind = raw[0] & 0x7f;
            if (kind == 31) {
                if (get32(raw[8..12]) != self.window) continue;
                if (get32(raw[20..24]) == 0) return null;
                return try self.readSelectionProperty(gpa, property);
            }
            if (kind == 0) return error.X11ServerError;
            if (!self.handleProtocolEvent(raw) and self.pending_events.items.len < 32) {
                self.pending_events.append(self.gpa, raw) catch {};
            }
        }
        return error.ClipboardTimeout;
    }

    fn translateComposed(self: *Window, keycode: u8, state: u16, control: bool) ?Key {
        const sym = self.keymap.keysym(keycode, state);
        if (control) {
            self.compose.reset();
            return keysymToKey(sym);
        }
        if (xkb.keysymNameForX11(sym)) |name| {
            switch (self.compose.feedName(name)) {
                .pending => return null,
                .char => |ch| return .{ .char = ch },
                .pass => {},
            }
        } else if (xkb.deadForX11(sym)) |dead| {
            return switch (self.compose.feedDead(dead)) {
                .pending => null,
                .char => |ch| .{ .char = ch },
                .pass => keysymToKey(sym),
            };
        } else if (sym == xkb.x11_multi_key) {
            _ = self.compose.feedMulti();
            return null;
        }
        const key = keysymToKey(sym);
        return switch (key) {
            .escape => blk: {
                self.compose.reset();
                break :blk .escape;
            },
            .char => |ch| switch (self.compose.feedChar(ch)) {
                .pending => null,
                .char => |out| .{ .char = out },
                .pass => .{ .char = ch },
            },
            else => blk: {
                self.compose.reset();
                break :blk key;
            },
        };
    }

    fn noteUserTime(self: *Window, time: u32) void {
        if (time != 0) self.last_user_time = time;
        if (self.conn.net_wm_user_time == 0 or time == 0) return;
        changeProperty32(&self.conn, self.window, self.conn.net_wm_user_time, atom_cardinal, &.{time}) catch {};
    }

    fn claimFocus(self: *Window, time: u32) void {
        const stamp = if (time != 0) time else self.last_user_time;
        setInputFocus(&self.conn, self.window, stamp) catch {};
    }

    fn replyNetWmPing(self: *Window, event: [32]u8) !void {
        var req: [44]u8 = @splat(0);
        req[0] = 25; // SendEvent
        req[1] = 1; // propagate
        put16(req[2..4], 11);
        put32(req[4..8], self.conn.screen.root);
        put32(req[8..12], (1 << 19) | (1 << 20)); // SubstructureNotify | SubstructureRedirect
        req[12] = 33;
        req[13] = 32;
        put32(req[16..20], self.window);
        put32(req[20..24], get32(event[8..12]));
        put32(req[24..28], get32(event[12..16]));
        put32(req[28..32], get32(event[16..20]));
        put32(req[32..36], get32(event[20..24]));
        put32(req[36..40], get32(event[24..28]));
        put32(req[40..44], get32(event[28..32]));
        try writeAll(&self.conn, &req);
    }

    fn readSelectionProperty(self: *Window, gpa: std.mem.Allocator, property: u32) !?[]u8 {
        const first = getWindowPropertyRaw(gpa, &self.conn, self.window, property, true, &self.pending_events) catch return null;
        if (self.conn.incr != 0 and first.typ == self.conn.incr) {
            gpa.free(first.bytes);
            return try self.readIncrProperty(gpa, property);
        }
        return first.bytes;
    }

    fn readIncrProperty(self: *Window, gpa: std.mem.Allocator, property: u32) ![]u8 {
        var acc: std.ArrayList(u8) = .empty;
        errdefer acc.deinit(gpa);
        var attempts: u16 = 0;
        while (attempts < 256) : (attempts += 1) {
            var raw: [32]u8 = undefined;
            try readExact(&self.conn, &raw);
            self.generic_extra_len = consumeGenericExtra(&self.conn, raw, &self.generic_extra) catch 0;
            const kind = raw[0] & 0x7f;
            if (kind == 28) {
                if (get32(raw[4..8]) != self.window or get32(raw[8..12]) != property) {
                    self.continueIncr(raw);
                    continue;
                }
                if (raw[16] != property_new_value) continue;
                const chunk = getWindowPropertyRaw(gpa, &self.conn, self.window, property, true, &self.pending_events) catch continue;
                defer gpa.free(chunk.bytes);
                if (chunk.bytes.len == 0) return try acc.toOwnedSlice(gpa);
                if (acc.items.len + chunk.bytes.len > max_clipboard_bytes) return error.ClipboardTooLarge;
                try acc.appendSlice(gpa, chunk.bytes);
                continue;
            }
            if (kind == 0) return error.X11ServerError;
            if (!self.handleProtocolEvent(raw) and self.pending_events.items.len < 32) {
                self.pending_events.append(self.gpa, raw) catch {};
            }
        }
        return error.ClipboardTimeout;
    }

    fn structureEventIsOurs(self: *const Window, event: [32]u8) bool {
        const event_win = get32(event[4..8]);
        const window = get32(event[8..12]);
        return event_win == self.window or window == self.window;
    }

    fn watchXsettings(self: *Window) void {
        if (self.conn.xsettings_s0 == 0) return;
        const owner = getSelectionOwnerStashing(self.gpa, &self.conn, self.conn.xsettings_s0, &self.pending_events) catch return;
        if (owner == 0) {
            self.xsettings_window = 0;
            self.conn.xsettings_window = 0;
            return;
        }
        if (owner == self.conn.xsettings_window) return;
        self.xsettings_window = owner;
        self.conn.xsettings_window = owner;
        selectXsettingsEvents(&self.conn, owner) catch {};
    }

    fn decodeXiTouch(self: *Window, event: [32]u8) Event {
        if (self.conn.xi_opcode == 0 or event[1] != self.conn.xi_opcode) return .other;
        const evtype = get16(event[8..10]);
        if (evtype != xi_touch_begin and evtype != xi_touch_update and evtype != xi_touch_end) return .other;
        if (self.generic_extra_len < 28) return .other;
        const flags = get32(self.generic_extra[24..28]);
        if (flags & xi_touch_emulating_pointer != 0) return .other;
        const raw_x = fp1616ToI32(get32(self.generic_extra[8..12]));
        const raw_y = fp1616ToI32(get32(self.generic_extra[12..16]));
        const x = physicalPointToLogical(raw_x, self.scale);
        const y = physicalPointToLogical(raw_y, self.scale);
        const touch_id = get32(event[16..20]);
        if (evtype == xi_touch_begin) {
            if (self.touch_contact != null) return .other;
            self.touch_contact = touch_id;
            self.noteUserTime(get32(event[12..16]));
            self.claimFocus(get32(event[12..16]));
            return .{ .pointer = .{ .kind = .down, .x = x, .y = y, .button = .primary } };
        }
        if (self.touch_contact == null or self.touch_contact.? != touch_id) return .other;
        if (evtype == xi_touch_update) {
            return .{ .pointer = .{ .kind = .move, .x = x, .y = y } };
        }
        self.touch_contact = null;
        return .{ .pointer = .{ .kind = .up, .x = x, .y = y, .button = .primary } };
    }

    fn handleProtocolEvent(self: *Window, event: [32]u8) bool {
        const kind = event[0] & 0x7f;
        switch (kind) {
            28 => {
                self.continueIncr(event);
                return true;
            },
            29 => {
                self.handleSelectionClear(event);
                return true;
            },
            30 => {
                self.serveSelectionRequest(event) catch {};
                return true;
            },
            else => return false,
        }
    }

    fn handleSelectionClear(self: *Window, event: [32]u8) void {
        const selection = get32(event[8..12]);
        if (selection == self.conn.clipboard) self.owns_clipboard = false;
        if (selection == atom_primary) self.owns_primary = false;
        if (!self.owns_clipboard and !self.owns_primary and self.clipboard_text.len != 0) {
            self.gpa.free(self.clipboard_text);
            self.clipboard_text = &.{};
        }
    }

    fn serveSelectionRequest(self: *Window, event: [32]u8) !void {
        const requestor = get32(event[12..16]);
        const selection = get32(event[16..20]);
        const target = get32(event[20..24]);
        var property = get32(event[24..28]);
        if (property == 0) property = target;
        const ours = (selection == self.conn.clipboard and self.owns_clipboard) or
            (selection == atom_primary and self.owns_primary);
        var served: u32 = 0;
        if (ours and property != 0) {
            if (target == self.conn.targets) {
                var atoms: [14]u32 = undefined;
                var n: usize = 0;
                atoms[n] = self.conn.targets;
                n += 1;
                if (self.conn.multiple != 0) {
                    atoms[n] = self.conn.multiple;
                    n += 1;
                }
                if (self.conn.timestamp != 0) {
                    atoms[n] = self.conn.timestamp;
                    n += 1;
                }
                if (self.conn.utf8_string != 0) {
                    atoms[n] = self.conn.utf8_string;
                    n += 1;
                }
                atoms[n] = atom_string;
                n += 1;
                if (self.conn.text != 0) {
                    atoms[n] = self.conn.text;
                    n += 1;
                }
                if (self.conn.mime_text_utf8 != 0) {
                    atoms[n] = self.conn.mime_text_utf8;
                    n += 1;
                }
                if (self.conn.mime_text_plain != 0) {
                    atoms[n] = self.conn.mime_text_plain;
                    n += 1;
                }
                if (self.conn.mime_text_utf8_alt != 0) {
                    atoms[n] = self.conn.mime_text_utf8_alt;
                    n += 1;
                }
                if (self.conn.mime_uri_list != 0) {
                    atoms[n] = self.conn.mime_uri_list;
                    n += 1;
                }
                if (self.conn.incr != 0) {
                    atoms[n] = self.conn.incr;
                    n += 1;
                }
                try changePropertyAtoms(&self.conn, requestor, property, atoms[0..n]);
                served = property;
            } else if (target == self.conn.multiple) {
                if (self.serveMultiple(requestor, property)) {
                    served = property;
                } else |_| {}
            } else if (target == self.conn.timestamp) {
                const stamp = if (self.clipboard_time != 0) self.clipboard_time else 1;
                try changeProperty32(&self.conn, requestor, property, atom_integer, &.{stamp});
                served = property;
            } else if (isClipboardTextTarget(&self.conn, target)) {
                if (self.clipboard_text.len > incrThreshold(&self.conn) and self.conn.incr != 0) {
                    try selectPropertyNotify(&self.conn, requestor);
                    const size: u32 = @intCast(self.clipboard_text.len);
                    try changeProperty32(&self.conn, requestor, property, self.conn.incr, &.{size});
                    self.incr_requestor = requestor;
                    self.incr_property = property;
                    self.incr_target = target;
                    self.incr_offset = 0;
                    served = property;
                } else {
                    try changePropertyBytes(&self.conn, requestor, property, target, self.clipboard_text);
                    served = property;
                }
            }
        }
        try sendSelectionNotify(&self.conn, requestor, get32(event[4..8]), selection, target, served);
    }

    fn continueIncr(self: *Window, event: [32]u8) void {
        if (self.incr_requestor == 0) return;
        if (get32(event[4..8]) != self.incr_requestor) return;
        if (get32(event[8..12]) != self.incr_property) return;
        if (event[16] != property_deleted) return;
        self.sendIncrChunk() catch {
            self.incr_requestor = 0;
            self.incr_offset = 0;
        };
    }

    fn sendIncrChunk(self: *Window) !void {
        const start = self.incr_offset;
        if (start >= self.clipboard_text.len) {
            try changePropertyBytes(&self.conn, self.incr_requestor, self.incr_property, self.incr_target, &.{});
            self.incr_requestor = 0;
            self.incr_offset = 0;
            return;
        }
        const n = @min(self.clipboard_text.len - start, incr_chunk_bytes);
        try changePropertyBytes(&self.conn, self.incr_requestor, self.incr_property, self.incr_target, self.clipboard_text[start .. start + n]);
        self.incr_offset = start + n;
    }

    fn handoverClipboard(self: *Window) void {
        if (!self.owns_clipboard or self.clipboard_text.len == 0) return;
        if (self.conn.clipboard_manager == 0 or self.conn.save_targets == 0) return;
        const owner = getSelectionOwner(&self.conn, self.conn.clipboard_manager) catch return;
        if (owner == 0) return;
        var targets: [8]u32 = undefined;
        var n: usize = 0;
        if (self.conn.utf8_string != 0) {
            targets[n] = self.conn.utf8_string;
            n += 1;
        }
        targets[n] = atom_string;
        n += 1;
        if (self.conn.text != 0) {
            targets[n] = self.conn.text;
            n += 1;
        }
        if (self.conn.mime_text_utf8 != 0) {
            targets[n] = self.conn.mime_text_utf8;
            n += 1;
        }
        if (self.conn.mime_text_plain != 0) {
            targets[n] = self.conn.mime_text_plain;
            n += 1;
        }
        if (self.conn.mime_text_utf8_alt != 0) {
            targets[n] = self.conn.mime_text_utf8_alt;
            n += 1;
        }
        if (self.conn.mime_uri_list != 0) {
            targets[n] = self.conn.mime_uri_list;
            n += 1;
        }
        changePropertyAtoms(&self.conn, self.window, self.conn.save_targets, targets[0..n]) catch return;
        convertSelection(&self.conn, self.window, self.conn.clipboard_manager, self.conn.save_targets, self.conn.save_targets, self.convertStamp()) catch return;
        var attempts: u16 = 0;
        while (attempts < 32) : (attempts += 1) {
            var raw: [32]u8 = undefined;
            readExact(&self.conn, &raw) catch return;
            self.generic_extra_len = consumeGenericExtra(&self.conn, raw, &self.generic_extra) catch 0;
            const kind = raw[0] & 0x7f;
            if (kind == 31) return;
            _ = self.handleProtocolEvent(raw);
            if (kind == 0) return;
        }
    }

    fn takePendingKey(self: *Window) ?Event {
        if (self.pending_chars.items.len == 0) return null;
        const ch = self.pending_chars.orderedRemove(0);
        return .{ .key = .{ .key = .{ .char = ch } } };
    }

    fn enqueueDropText(self: *Window, bytes: []const u8) !?Event {
        const payload = try services.firstDropTextUtf8(self.gpa, bytes);
        defer self.gpa.free(payload);
        var view = try std.unicode.Utf8View.init(payload);
        var iterator = view.iterator();
        while (iterator.nextCodepoint()) |codepoint| {
            if (self.pending_chars.items.len >= 4096) break;
            try self.pending_chars.append(self.gpa, codepoint);
        }
        return self.takePendingKey();
    }

    fn refreshScale(self: *Window) ?Event {
        self.watchXsettings();
        const env = services.readEnviron(self.gpa) catch return null;
        defer self.gpa.free(env);
        const detected = detectScale(self.gpa, &self.conn, env, &self.pending_events, self.window, self.pixel_width, self.pixel_height, self.randrCrtcs()) catch return null;
        return self.applyScale(detected.scale, detected.source, env);
    }

    fn refreshOutputScale(self: *Window) ?Event {
        if (self.scale_source == .env or self.scale_source == .xft) return null;
        const env = services.readEnviron(self.gpa) catch return null;
        defer self.gpa.free(env);
        const scale = scaleFromCachedCrtcs(self.gpa, &self.conn, self.window, self.pixel_width, self.pixel_height, self.randrCrtcs(), &self.pending_events) orelse return null;
        return self.applyScale(scale, .physical, env);
    }

    fn applyScale(self: *Window, new_scale: u32, source: ScaleSource, env: []const u8) ?Event {
        if (new_scale == self.scale) {
            self.scale_source = source;
            return null;
        }
        self.scale = new_scale;
        self.scale_source = source;
        if (self.cursor_id != 0) freeCursor(&self.conn, self.cursor_id) catch {};
        self.cursor_id = installScaledCursor(self.gpa, &self.conn, self.window, new_scale, env, &self.pending_events) catch 0;
        setNetWmIcon(self.gpa, &self.conn, self.window) catch {};
        setSizeHints(&self.conn, self.window, self.pixel_width, self.pixel_height, new_scale) catch {};
        const w = physicalToLogical(self.pixel_width, new_scale);
        const h = physicalToLogical(self.pixel_height, new_scale);
        if (w == self.width and h == self.height) return .expose;
        self.width = w;
        self.height = h;
        return .{ .resize = .{ .w = w, .h = h } };
    }

    fn randrCrtcs(self: *const Window) []const RandrCrtc {
        return self.randr_crtcs[0..self.randr_crtc_count];
    }

    fn refreshRandrCrtcs(self: *Window) void {
        const next = fetchRandrCrtcs(self.gpa, &self.conn, &self.pending_events) catch return;
        self.randr_crtcs = next.crtcs;
        self.randr_crtc_count = next.count;
    }

    fn serveMultiple(self: *Window, requestor: u32, property: u32) !void {
        if (self.conn.multiple == 0 or self.conn.atom_pair == 0 or property == 0) return error.ClipboardUnavailable;
        const bytes = try getWindowProperty(self.gpa, &self.conn, requestor, property, &self.pending_events);
        defer self.gpa.free(bytes);
        if (bytes.len < 8 or bytes.len % 8 != 0 or bytes.len > 64 * 4) return error.BadMultiple;
        var pairs: [32]u32 = undefined;
        const count = bytes.len / 4;
        var i: usize = 0;
        while (i < count) : (i += 1) {
            pairs[i] = get32(bytes[i * 4 ..][0..4]);
        }
        var pair_i: usize = 0;
        while (pair_i + 1 < count) : (pair_i += 2) {
            const pair_target = pairs[pair_i];
            var pair_prop = pairs[pair_i + 1];
            if (pair_prop == 0) pair_prop = pair_target;
            if (!self.servePairTarget(requestor, pair_target, pair_prop)) {
                pairs[pair_i + 1] = 0;
            }
        }
        try changeProperty32(&self.conn, requestor, property, self.conn.atom_pair, pairs[0..count]);
    }

    fn servePairTarget(self: *Window, requestor: u32, target: u32, property: u32) bool {
        if (property == 0 or target == 0) return false;
        if (target == self.conn.targets) {
            var atoms: [4]u32 = undefined;
            var n: usize = 0;
            atoms[n] = self.conn.targets;
            n += 1;
            if (self.conn.utf8_string != 0) {
                atoms[n] = self.conn.utf8_string;
                n += 1;
            }
            atoms[n] = atom_string;
            n += 1;
            changePropertyAtoms(&self.conn, requestor, property, atoms[0..n]) catch return false;
            return true;
        }
        if (target == self.conn.timestamp) {
            const stamp = if (self.clipboard_time != 0) self.clipboard_time else 1;
            changeProperty32(&self.conn, requestor, property, atom_integer, &.{stamp}) catch return false;
            return true;
        }
        if (!isClipboardTextTarget(&self.conn, target)) return false;
        if (self.clipboard_text.len > max_clipboard_bytes) return false;
        changePropertyBytes(&self.conn, requestor, property, target, self.clipboard_text) catch return false;
        return true;
    }

    fn handleXdndEnter(self: *Window, event: [32]u8) void {
        self.xdnd_source = get32(event[12..16]);
        const info = get32(event[16..20]);
        const types = [_]u32{ get32(event[20..24]), get32(event[24..28]), get32(event[28..32]) };
        self.xdnd_has_text = false;
        for (types) |typ| {
            if (isClipboardTextTarget(&self.conn, typ)) self.xdnd_has_text = true;
        }
        if (!self.xdnd_has_text and (info & 1) != 0) self.readXdndTypeList();
    }

    fn readXdndTypeList(self: *Window) void {
        if (self.xdnd_source == 0 or self.conn.xdnd_type_list == 0) return;
        const bytes = getWindowProperty(self.gpa, &self.conn, self.xdnd_source, self.conn.xdnd_type_list, &self.pending_events) catch return;
        defer self.gpa.free(bytes);
        var off: usize = 0;
        while (off + 4 <= bytes.len) : (off += 4) {
            if (isClipboardTextTarget(&self.conn, get32(bytes[off..][0..4]))) {
                self.xdnd_has_text = true;
                return;
            }
        }
    }

    fn handleXdndPosition(self: *Window, event: [32]u8) !?Event {
        const source = get32(event[12..16]);
        if (source != 0) self.xdnd_source = source;
        const time = get32(event[24..28]);
        if (time != 0) self.noteUserTime(time);
        const flags: u32 = if (self.xdnd_has_text) 0x3 else 0x2; // accept? + no rectangle
        try sendXdndClientMessage(&self.conn, self.xdnd_source, self.conn.xdnd_status, .{
            self.window,
            flags,
            0,
            0,
            self.conn.xdnd_action_copy,
        });
        const root = xdndRootPoint(get32(event[20..24]));
        if (self.translateRootToLocal(root.x, root.y)) |local| {
            return .{ .pointer = .{
                .kind = .move,
                .x = physicalPointToLogical(local.x, self.scale),
                .y = physicalPointToLogical(local.y, self.scale),
            } };
        }
        return null;
    }

    fn translateRootToLocal(self: *Window, root_x: i32, root_y: i32) ?struct { x: i32, y: i32 } {
        var req: [16]u8 = @splat(0);
        req[0] = 40;
        put16(req[2..4], 4);
        put32(req[4..8], self.conn.screen.root);
        put32(req[8..12], self.window);
        put16(req[12..14], @bitCast(@as(i16, @truncate(root_x))));
        put16(req[14..16], @bitCast(@as(i16, @truncate(root_y))));
        writeAll(&self.conn, &req) catch return null;
        const reply = readReplyStashing(self.gpa, &self.conn, &self.pending_events) catch return null;
        if (reply[1] == 0) return null;
        return .{
            .x = @as(i16, @bitCast(get16(reply[16..18]))),
            .y = @as(i16, @bitCast(get16(reply[18..20]))),
        };
    }

    fn takeXdndDrop(self: *Window, event: [32]u8) ?Event {
        const source = get32(event[12..16]);
        if (source != 0) self.xdnd_source = source;
        if (self.xdnd_source == 0 or !self.xdnd_has_text or self.conn.xdnd_selection == 0) {
            self.finishXdnd(false);
            return null;
        }
        const drop_time = get32(event[20..24]);
        if (drop_time != 0) self.selection_time = drop_time;
        const text = self.convertAndRead(self.gpa, self.conn.xdnd_selection) catch null;
        self.selection_time = 0;
        self.finishXdnd(text != null);
        if (text) |bytes| {
            defer self.gpa.free(bytes);
            return self.enqueueDropText(bytes) catch null;
        }
        return null;
    }

    fn convertFirstTextTarget(self: *Window, gpa: std.mem.Allocator, selection: u32) !?[]u8 {
        return self.convertAndRead(gpa, selection);
    }

    fn finishXdnd(self: *Window, accepted: bool) void {
        if (self.xdnd_source != 0 and self.conn.xdnd_finished != 0) {
            sendXdndClientMessage(&self.conn, self.xdnd_source, self.conn.xdnd_finished, .{
                self.window,
                if (accepted) 1 else 0,
                self.conn.xdnd_action_copy,
                0,
                0,
            }) catch {};
        }
        self.xdnd_source = 0;
        self.xdnd_has_text = false;
    }

    fn applyNetWmStateMessage(self: *Window, event: [32]u8) void {
        const action = get32(event[12..16]);
        const first = get32(event[16..20]);
        const second = get32(event[20..24]);
        self.applyNetWmStateAtom(action, first);
        if (second != 0) self.applyNetWmStateAtom(action, second);
    }

    fn applyNetWmStateAtom(self: *Window, action: u32, atom: u32) void {
        if (atom == 0) return;
        const add = action == 1 or (action == 2 and !self.hasNetWmState(atom));
        const remove = action == 0 or (action == 2 and self.hasNetWmState(atom));
        if (atom == self.conn.net_wm_state_max_horz) {
            if (add) self.wm_max_horz = true;
            if (remove) self.wm_max_horz = false;
        } else if (atom == self.conn.net_wm_state_max_vert) {
            if (add) self.wm_max_vert = true;
            if (remove) self.wm_max_vert = false;
        } else if (atom == self.conn.net_wm_state_fullscreen) {
            if (add) self.wm_fullscreen = true;
            if (remove) self.wm_fullscreen = false;
        } else if (atom == self.conn.net_wm_state_hidden) {
            if (add) self.wm_net_hidden = true;
            if (remove) self.wm_net_hidden = false;
            self.syncHidden();
        } else if (atom == self.conn.net_wm_state_shaded) {
            if (add) self.wm_shaded = true;
            if (remove) self.wm_shaded = false;
            self.syncHidden();
        }
    }

    fn hasNetWmState(self: *const Window, atom: u32) bool {
        if (atom == self.conn.net_wm_state_max_horz) return self.wm_max_horz;
        if (atom == self.conn.net_wm_state_max_vert) return self.wm_max_vert;
        if (atom == self.conn.net_wm_state_fullscreen) return self.wm_fullscreen;
        if (atom == self.conn.net_wm_state_hidden) return self.wm_net_hidden;
        if (atom == self.conn.net_wm_state_shaded) return self.wm_shaded;
        return false;
    }

    fn syncHidden(self: *Window) void {
        self.wm_hidden = combinedWmHidden(self.wm_net_hidden, self.wm_icccm_hidden, self.wm_unmapped, self.wm_shaded);
    }

    fn demandAttention(self: *Window) void {
        self.wm_urgent = true;
        writeWmHints(&self.conn, self.window, true) catch {};
        sendNetWmStateClient(&self.conn, self.window, 1, self.conn.net_wm_state_attention) catch {};
    }

    fn clearAttention(self: *Window) void {
        if (!self.wm_urgent) return;
        self.wm_urgent = false;
        writeWmHints(&self.conn, self.window, false) catch {};
        sendNetWmStateClient(&self.conn, self.window, 0, self.conn.net_wm_state_attention) catch {};
    }

    fn readNetWmState(self: *Window) void {
        if (self.conn.net_wm_state == 0) return;
        const bytes = getWindowProperty(self.gpa, &self.conn, self.window, self.conn.net_wm_state, &self.pending_events) catch return;
        defer self.gpa.free(bytes);
        self.wm_max_horz = false;
        self.wm_max_vert = false;
        self.wm_fullscreen = false;
        self.wm_net_hidden = false;
        self.wm_shaded = false;
        var off: usize = 0;
        while (off + 4 <= bytes.len) : (off += 4) {
            const atom = get32(bytes[off..][0..4]);
            if (atom == self.conn.net_wm_state_max_horz) self.wm_max_horz = true;
            if (atom == self.conn.net_wm_state_max_vert) self.wm_max_vert = true;
            if (atom == self.conn.net_wm_state_fullscreen) self.wm_fullscreen = true;
            if (atom == self.conn.net_wm_state_hidden) self.wm_net_hidden = true;
            if (atom == self.conn.net_wm_state_shaded) self.wm_shaded = true;
        }
        self.syncHidden();
    }

    fn readWmState(self: *Window) void {
        defer self.syncHidden();
        if (self.conn.wm_state == 0) return;
        const bytes = getWindowProperty(self.gpa, &self.conn, self.window, self.conn.wm_state, &self.pending_events) catch return;
        defer self.gpa.free(bytes);
        if (bytes.len < 4) return;
        self.wm_icccm_hidden = wmStateIsHidden(get32(bytes[0..4]));
    }

    fn applyWmChangeState(self: *Window, event: [32]u8) void {
        self.wm_icccm_hidden = wmStateIsHidden(get32(event[12..16]));
        self.syncHidden();
    }

    fn handleRandrScreenChange(self: *Window, event: [32]u8) Event {
        const dims = randrScreenChangeSize(event);
        if (dims.width_px != 0) self.conn.screen.width_px = dims.width_px;
        if (dims.width_mm != 0) self.conn.screen.width_mm = dims.width_mm;
        self.refreshRandrCrtcs();
        return self.refreshScale() orelse .other;
    }

    fn refreshKeymap(self: *Window) void {
        const next = fetchKeymapStashing(self.gpa, &self.conn, &self.pending_events) catch return;
        self.keymap.deinit(self.gpa);
        self.keymap = next;
    }
};

fn readDisplay(gpa: std.mem.Allocator) ![]u8 {
    const env = try services.readEnviron(gpa);
    defer gpa.free(env);
    const value = services.environValue(env, "DISPLAY") orelse return error.DisplayUnset;
    if (value.len == 0) return error.DisplayUnset;
    return gpa.dupe(u8, value);
}

fn parseDisplay(display: []const u8) !Display {
    const colon = std.mem.lastIndexOfScalar(u8, display, ':') orelse return error.InvalidDisplay;
    var i = colon + 1;
    const start = i;
    while (i < display.len and display[i] >= '0' and display[i] <= '9') : (i += 1) {}
    if (i == start) return error.InvalidDisplay;
    var host = display[0..colon];
    if (host.len >= 2 and host[0] == '[' and host[host.len - 1] == ']') {
        host = host[1 .. host.len - 1];
    }
    const local = host.len == 0 or std.mem.eql(u8, host, "unix");
    return .{
        .host = host,
        .number = try std.fmt.parseInt(u16, display[start..i], 10),
        .local = local,
    };
}

fn connectDisplay(gpa: std.mem.Allocator, io: std.Io, display: Display, env: []const u8) !XConn {
    const stream = if (display.local)
        try connectLocalUnix(io, display.number)
    else
        try connectTcp(io, display.host, display.number);
    errdefer stream.close(io);

    var hostname_buf: [64]u8 = undefined;
    const hostname = if (display.local) localHostname(&hostname_buf) else display.host;
    var display_number_buf: [8]u8 = undefined;
    const display_number = try std.fmt.bufPrint(&display_number_buf, "{d}", .{display.number});
    var auth_storage: [256]u8 = undefined;
    const auth = readMatchingAuth(env, hostname, display_number, display.local, &auth_storage) catch Auth{};

    try writeSetupHello(io, stream, auth);

    var header: [8]u8 = undefined;
    try readExactRaw(io, stream, &header);
    const extra_len = @as(usize, get16(header[6..8])) * 4;
    if (header[0] != 1) {
        const extra = try gpa.alloc(u8, extra_len);
        defer gpa.free(extra);
        try readExactRaw(io, stream, extra);
        return error.X11SetupFailed;
    }

    const body = try gpa.alloc(u8, extra_len);
    defer gpa.free(body);
    try readExactRaw(io, stream, body);
    const setup = try parseSetup(body);

    return .{
        .io = io,
        .stream = stream,
        .next_id = 1,
        .resource_mask = setup.screen.resource_mask,
        .screen = setup.screen,
        .max_request_units = @max(setup.max_request_units, min_max_request_units),
        .min_keycode = setup.min_keycode,
        .max_keycode = setup.max_keycode,
    };
}

fn writeSetupHello(io: std.Io, stream: net.Stream, auth: Auth) !void {
    if (auth.name.len > std.math.maxInt(u16) or auth.data.len > std.math.maxInt(u16)) {
        return error.AuthTooLarge;
    }
    const name_pad = pad4(auth.name.len);
    const data_pad = pad4(auth.data.len);
    var stack: [12 + 256]u8 = undefined;
    const total = 12 + name_pad + data_pad;
    const hello = if (total <= stack.len) stack[0..total] else return error.AuthTooLarge;
    @memset(hello, 0);
    hello[0] = 'l';
    put16(hello[2..4], 11);
    put16(hello[6..8], @intCast(auth.name.len));
    put16(hello[8..10], @intCast(auth.data.len));
    if (auth.name.len != 0) @memcpy(hello[12 .. 12 + auth.name.len], auth.name);
    if (auth.data.len != 0) @memcpy(hello[12 + name_pad .. 12 + name_pad + auth.data.len], auth.data);
    try writeAllRaw(io, stream, hello);
}

/// Parse the connection-setup "additional data" (everything after the 8-byte
/// success header). Fixed part per the X11 protocol spec:
///   0  release, 4 resource-id-base, 8 resource-id-mask, 12 motion-buffer-size,
///   16 vendor length (u16), 18 maximum-request-length (u16),
///   20 #screens (u8), 21 #formats (u8), 22 image-byte-order, 23 bit-order,
///   24 scanline-unit, 25 scanline-pad, 26 min-keycode, 27 max-keycode,
///   28..32 unused, 32 vendor string (padded), then formats (8B each),
///   then screens.
fn parseSetup(body: []const u8) !Setup {
    if (body.len < 32) return error.ShortSetupReply;
    const resource_base = get32(body[4..8]);
    const resource_mask = get32(body[8..12]);
    const vendor_len = get16(body[16..18]);
    const max_request = get16(body[18..20]);
    const roots_len = body[20];
    const formats_len = body[21];
    const min_keycode = body[26];
    const max_keycode = body[27];
    if (roots_len == 0) return error.NoScreen;

    const off: usize = 32 + pad4(vendor_len) + @as(usize, formats_len) * 8;
    if (off + 40 > body.len) return error.ShortSetupReply;

    const root = get32(body[off + 0 .. off + 4]);
    const white = get32(body[off + 8 .. off + 12]);
    const black = get32(body[off + 12 .. off + 16]);
    const root_visual = get32(body[off + 32 .. off + 36]);
    const root_depth = body[off + 38];
    const width_px = get16(body[off + 20 .. off + 22]);
    const width_mm = get16(body[off + 24 .. off + 26]);

    return .{
        .screen = .{
            .resource_base = resource_base,
            .resource_mask = resource_mask,
            .root = root,
            .root_visual = root_visual,
            .root_depth = root_depth,
            .white_pixel = white,
            .black_pixel = black,
            .width_px = width_px,
            .width_mm = width_mm,
        },
        .max_request_units = max_request,
        .min_keycode = min_keycode,
        .max_keycode = max_keycode,
    };
}

fn createWindow(conn: *XConn, window: u32, w: u16, h: u16) !void {
    const values = [_]u32{
        conn.screen.white_pixel,
        conn.screen.black_pixel,
        event_key_press | event_button_press | event_button_release |
            event_enter_window | event_leave_window | event_pointer_motion | event_exposure | event_visibility_change |
            event_structure | event_focus_change | event_property_change,
    };
    const value_mask = cw_back_pixel | cw_border_pixel | cw_event_mask;
    var req: [44]u8 = @splat(0);
    req[0] = 1;
    req[1] = conn.screen.root_depth;
    put16(req[2..4], @intCast(req.len / 4));
    put32(req[4..8], window);
    put32(req[8..12], conn.screen.root);
    put16(req[16..18], w);
    put16(req[18..20], h);
    put16(req[22..24], input_output);
    put32(req[24..28], conn.screen.root_visual);
    put32(req[28..32], value_mask);
    put32(req[32..36], values[0]);
    put32(req[36..40], values[1]);
    put32(req[40..44], values[2]);
    try writeAll(conn, &req);
}

fn createGc(conn: *XConn, gc: u32, drawable: u32) !void {
    var req: [24]u8 = @splat(0);
    req[0] = 55;
    put16(req[2..4], @intCast(req.len / 4));
    put32(req[4..8], gc);
    put32(req[8..12], drawable);
    put32(req[12..16], gc_foreground | gc_background);
    put32(req[16..20], conn.screen.black_pixel);
    put32(req[20..24], conn.screen.white_pixel);
    try writeAll(conn, &req);
}

fn installWmClose(conn: *XConn, window: u32) !void {
    conn.wm_protocols = try internAtom(conn, "WM_PROTOCOLS");
    conn.wm_delete_window = try internAtom(conn, "WM_DELETE_WINDOW");
    if (conn.net_wm_ping == 0) conn.net_wm_ping = try internAtom(conn, "_NET_WM_PING");
    if (conn.wm_take_focus == 0) conn.wm_take_focus = try internAtom(conn, "WM_TAKE_FOCUS");

    const atoms = [_]u32{ conn.wm_delete_window, conn.net_wm_ping, conn.wm_take_focus };
    try changePropertyAtoms(conn, window, conn.wm_protocols, &atoms);
}

fn setTitle(conn: *XConn, window: u32, title: []const u8) !void {
    if (title.len == 0 or title.len > 255) return;
    try changePropertyBytes(conn, window, atom_wm_name, atom_string, title);
    try changePropertyBytes(conn, window, atom_wm_icon_name, atom_string, title);
    if (conn.net_wm_name != 0 and conn.utf8_string != 0) {
        try changePropertyBytes(conn, window, conn.net_wm_name, conn.utf8_string, title);
    }
    if (conn.net_wm_icon_name != 0 and conn.utf8_string != 0) {
        try changePropertyBytes(conn, window, conn.net_wm_icon_name, conn.utf8_string, title);
    }
}

fn setWmClass(conn: *XConn, window: u32, instance: []const u8, class_name: []const u8) !void {
    if (instance.len == 0 or class_name.len == 0) return;
    var buf: [256]u8 = undefined;
    if (instance.len + class_name.len + 2 > buf.len) return;
    @memcpy(buf[0..instance.len], instance);
    buf[instance.len] = 0;
    @memcpy(buf[instance.len + 1 .. instance.len + 1 + class_name.len], class_name);
    buf[instance.len + 1 + class_name.len] = 0;
    try changePropertyBytes(conn, window, atom_wm_class, atom_string, buf[0 .. instance.len + class_name.len + 2]);
}

fn setNetWmPid(conn: *XConn, window: u32) !void {
    if (conn.net_wm_pid == 0) return;
    const pid: u32 = @intCast(@max(0, linux.getpid()));
    try changeProperty32(conn, window, conn.net_wm_pid, atom_cardinal, &.{pid});
}

fn setNetStartupId(conn: *XConn, window: u32, env: []const u8) !void {
    if (conn.net_startup_id == 0) return;
    const token = services.startupToken(env) orelse return;
    if (token.len > 256) return;
    const typ = if (conn.utf8_string != 0) conn.utf8_string else atom_string;
    try changePropertyBytes(conn, window, conn.net_startup_id, typ, token);
}

fn sendStartupRemove(conn: *XConn, window: u32, env: []const u8) !void {
    const token = services.startupToken(env) orelse return;
    if (conn.net_startup_info_begin == 0 or conn.net_startup_info == 0) return;
    var buf: [320]u8 = undefined;
    const message = services.startupRemoveMessage(token, &buf) orelse return;
    var off: usize = 0;
    var first = true;
    while (off < message.len) {
        var chunk: [20]u8 = @splat(0);
        const take = @min(20, message.len - off);
        @memcpy(chunk[0..take], message[off .. off + take]);
        try sendStartupInfoChunk(conn, window, if (first) conn.net_startup_info_begin else conn.net_startup_info, chunk);
        first = false;
        off += take;
    }
}

fn sendStartupInfoChunk(conn: *XConn, window: u32, typ: u32, data: [20]u8) !void {
    var req: [44]u8 = @splat(0);
    req[0] = 25;
    req[1] = 1;
    put16(req[2..4], 11);
    put32(req[4..8], conn.screen.root);
    put32(req[8..12], (1 << 19) | (1 << 20));
    req[12] = 33;
    req[13] = 8;
    put32(req[16..20], window);
    put32(req[20..24], typ);
    @memcpy(req[24..44], &data);
    try writeAll(conn, &req);
}

fn setWmHints(conn: *XConn, window: u32) !void {
    try writeWmHints(conn, window, false);
}

fn writeWmHints(conn: *XConn, window: u32, urgent: bool) !void {
    var hints: [9]u32 = @splat(0);
    hints[0] = 1 | 2; // InputHint | StateHint
    if (urgent) hints[0] |= 1 << 8; // UrgencyHint
    hints[1] = 1; // input
    hints[2] = 1; // NormalState
    try changeProperty32(conn, window, atom_wm_hints, atom_wm_hints, &hints);
}

fn setNetWmWindowType(conn: *XConn, window: u32) !void {
    if (conn.net_wm_window_type == 0 or conn.net_wm_window_type_normal == 0) return;
    try changeProperty32(conn, window, conn.net_wm_window_type, atom_atom, &.{conn.net_wm_window_type_normal});
}

fn setAllowedActions(conn: *XConn, window: u32) !void {
    if (conn.net_wm_allowed_actions == 0) return;
    const move = internAtom(conn, "_NET_WM_ACTION_MOVE") catch return;
    const resize = internAtom(conn, "_NET_WM_ACTION_RESIZE") catch return;
    const minimize = internAtom(conn, "_NET_WM_ACTION_MINIMIZE") catch return;
    const maximize_horz = internAtom(conn, "_NET_WM_ACTION_MAXIMIZE_HORZ") catch return;
    const maximize_vert = internAtom(conn, "_NET_WM_ACTION_MAXIMIZE_VERT") catch return;
    const fullscreen = internAtom(conn, "_NET_WM_ACTION_FULLSCREEN") catch return;
    const close = internAtom(conn, "_NET_WM_ACTION_CLOSE") catch return;
    try changePropertyAtoms(conn, window, conn.net_wm_allowed_actions, &.{
        move, resize, minimize, maximize_horz, maximize_vert, fullscreen, close,
    });
}

fn setWmLocaleName(conn: *XConn, window: u32, env: []const u8) !void {
    if (conn.wm_locale_name == 0) return;
    const locale = services.environValue(env, "LC_ALL") orelse
        services.environValue(env, "LC_CTYPE") orelse
        services.environValue(env, "LANG") orelse
        "C";
    const trimmed = std.mem.trim(u8, locale, " \t");
    if (trimmed.len == 0 or trimmed.len > 64) return;
    try changePropertyBytes(conn, window, conn.wm_locale_name, atom_string, trimmed);
}

fn setClientMachine(conn: *XConn, window: u32) !void {
    var hostname_buf: [64]u8 = undefined;
    const hostname = localHostname(&hostname_buf);
    if (hostname.len == 0) return;
    try changePropertyBytes(conn, window, atom_wm_client_machine, atom_string, hostname);
}

fn internAtom(conn: *XConn, name: []const u8) !u32 {
    if (name.len > std.math.maxInt(u16)) return error.NameTooLong;
    const padded = pad4(name.len);
    var req = try std.heap.page_allocator.alloc(u8, 8 + padded);
    defer std.heap.page_allocator.free(req);
    @memset(req, 0);
    req[0] = 16;
    req[1] = 0;
    put16(req[2..4], @intCast(req.len / 4));
    put16(req[4..6], @intCast(name.len));
    @memcpy(req[8 .. 8 + name.len], name);
    try writeAll(conn, req);

    const reply = try readReply(conn);
    return get32(reply[8..12]);
}

/// GetKeyboardMapping for the full keycode range.
fn fetchKeymap(gpa: std.mem.Allocator, conn: *XConn) !Keymap {
    const count: u8 = conn.max_keycode - conn.min_keycode + 1;
    var req: [8]u8 = @splat(0);
    req[0] = 101;
    put16(req[2..4], 2);
    req[4] = conn.min_keycode;
    req[5] = count;
    try writeAll(conn, &req);

    return finishKeymap(gpa, conn, try readReply(conn), conn.min_keycode);
}

/// Same as fetchKeymap, but queues MappingNotify-adjacent events instead of
/// dropping them. Used after the event loop has started.
fn fetchKeymapStashing(gpa: std.mem.Allocator, conn: *XConn, stash: *std.ArrayList([32]u8)) !Keymap {
    const count: u8 = conn.max_keycode - conn.min_keycode + 1;
    var req: [8]u8 = @splat(0);
    req[0] = 101;
    put16(req[2..4], 2);
    req[4] = conn.min_keycode;
    req[5] = count;
    try writeAll(conn, &req);
    return finishKeymap(gpa, conn, try readReplyStashing(gpa, conn, stash), conn.min_keycode);
}

fn finishKeymap(gpa: std.mem.Allocator, conn: *XConn, header: [32]u8, min: u8) !Keymap {
    const per = header[1];
    const total = @as(usize, get32(header[4..8]));
    const syms = try gpa.alloc(u32, total);
    errdefer gpa.free(syms);
    const raw = try gpa.alloc(u8, total * 4);
    defer gpa.free(raw);
    try readExact(conn, raw);
    for (syms, 0..) |*s, i| s.* = get32(raw[i * 4 .. i * 4 + 4]);
    return .{ .syms = syms, .per = per, .min = min };
}

/// Wait for the next reply, skipping (discarding) any events that arrive
/// first. Only used during setup, before the event loop starts.
fn readReply(conn: *XConn) ![32]u8 {
    return readReplyMaybeStashing(undefined, conn, null);
}

fn readReplyStashing(gpa: std.mem.Allocator, conn: *XConn, stash: *std.ArrayList([32]u8)) ![32]u8 {
    return readReplyMaybeStashing(gpa, conn, stash);
}

fn consumeGenericExtra(conn: *XConn, header: [32]u8, dest: ?[]u8) !usize {
    if ((header[0] & 0x7f) != generic_event) return 0;
    const n = try std.math.mul(usize, get32(header[4..8]), 4);
    var copied: usize = 0;
    var remain = n;
    var tmp: [256]u8 = undefined;
    while (remain > 0) {
        const chunk = @min(remain, tmp.len);
        try readExact(conn, tmp[0..chunk]);
        if (dest) |out| {
            const take = @min(out.len - copied, chunk);
            if (take != 0) {
                @memcpy(out[copied..][0..take], tmp[0..take]);
                copied += take;
            }
        }
        remain -= chunk;
    }
    return copied;
}

fn genericEventExtraBytes(header: [32]u8) usize {
    if ((header[0] & 0x7f) != generic_event) return 0;
    return @as(usize, get32(header[4..8])) * 4;
}

fn fp1616ToI32(bits: u32) i32 {
    return @divTrunc(@as(i32, @bitCast(bits)), 65536);
}

fn readReplyMaybeStashing(gpa: std.mem.Allocator, conn: *XConn, stash: ?*std.ArrayList([32]u8)) ![32]u8 {
    while (true) {
        var head: [32]u8 = undefined;
        try readExact(conn, &head);
        if ((head[0] & 0x7f) == generic_event) {
            _ = consumeGenericExtra(conn, head, null) catch {};
        }
        switch (head[0]) {
            0 => return error.X11ServerError,
            1 => return head,
            else => {
                if (stash) |list| {
                    if (list.items.len < 32) try list.append(gpa, head);
                }
            },
        }
    }
}

fn mapWindow(conn: *XConn, window: u32) !void {
    var req: [8]u8 = @splat(0);
    req[0] = 8;
    put16(req[2..4], 2);
    put32(req[4..8], window);
    try writeAll(conn, &req);
}

fn putImage(
    gpa: std.mem.Allocator,
    conn: *XConn,
    drawable: u32,
    gc: u32,
    pixels: []const u32,
    w: u32,
    h: u32,
) !void {
    const row_bytes = try std.math.mul(usize, w, 4);
    const max_units = @max(conn.max_request_units, min_max_request_units);
    if (max_units <= request_put_image_header_units) return error.MaxRequestTooSmall;
    const max_payload = (@as(usize, max_units) - request_put_image_header_units) * 4;
    const rows_per_chunk = @divFloor(max_payload, row_bytes);
    if (rows_per_chunk == 0) return error.ImageTooWide;

    const chunk_rows = @min(rows_per_chunk, h);
    const chunk_bytes = row_bytes * @as(usize, chunk_rows);
    var data = try gpa.alloc(u8, pad4(chunk_bytes));
    defer gpa.free(data);

    var y: u32 = 0;
    while (y < h) {
        const rows: u32 = @intCast(@min(@as(usize, h - y), rows_per_chunk));
        const raw_len = row_bytes * @as(usize, rows);
        encodeBgrx(data[0..raw_len], pixels[@as(usize, y) * w ..], w, rows);
        @memset(data[raw_len..pad4(raw_len)], 0);

        var header: [24]u8 = @splat(0);
        header[0] = 72;
        header[1] = z_pixmap;
        put16(header[2..4], @intCast(request_put_image_header_units + pad4(raw_len) / 4));
        put32(header[4..8], drawable);
        put32(header[8..12], gc);
        put16(header[12..14], @intCast(w));
        put16(header[14..16], @intCast(rows));
        put16(header[16..18], 0);
        put16(header[18..20], @intCast(y));
        header[21] = image_depth;
        try writeAll(conn, &header);
        try writeAll(conn, data[0..pad4(raw_len)]);

        y += rows;
    }
}

fn encodeBgrx(dst: []u8, pixels: []const u32, w: u32, h: u32) void {
    var i: usize = 0;
    const count = @as(usize, w) * @as(usize, h);
    while (i < count) : (i += 1) {
        const px = pixels[i];
        dst[i * 4 + 0] = @intCast(px & 0xff);
        dst[i * 4 + 1] = @intCast((px >> 8) & 0xff);
        dst[i * 4 + 2] = @intCast((px >> 16) & 0xff);
        dst[i * 4 + 3] = 0;
    }
}

fn connectLocalUnix(io: std.Io, number: u16) !net.Stream {
    var path_buf: [64]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "/tmp/.X11-unix/X{d}", .{number});
    return openUnixSocket(io, path) catch {
        var abstract_buf: [65]u8 = undefined;
        abstract_buf[0] = 0;
        const rest = try std.fmt.bufPrint(abstract_buf[1..], "/tmp/.X11-unix/X{d}", .{number});
        return openUnixSocket(io, abstract_buf[0 .. 1 + rest.len]);
    };
}

fn connectTcp(io: std.Io, host: []const u8, number: u16) !net.Stream {
    const port = std.math.add(u16, 6000, number) catch return error.InvalidDisplay;
    if (net.IpAddress.parseIp4(host, port)) |addr| {
        return addr.connect(io, .{ .mode = .stream }) catch |err| return mapTcpError(err);
    } else |_| {}
    if (net.IpAddress.parseIp6(host, port)) |addr| {
        return addr.connect(io, .{ .mode = .stream }) catch |err| return mapTcpError(err);
    } else |_| {}
    const name = net.HostName.init(host) catch return error.InvalidDisplay;
    return name.connect(io, port, .{ .mode = .stream }) catch |err| return mapTcpError(err);
}

fn mapTcpError(err: anyerror) anyerror {
    return switch (err) {
        error.ConnectionRefused,
        error.NetworkUnreachable,
        error.HostUnreachable,
        error.ConnectionTimedOut,
        error.ConnectionResetByPeer,
        error.UnknownHostName,
        error.NameNotFound,
        error.AddressNotAvailable,
        error.AddressFamilyUnsupported,
        => error.XServerUnavailable,
        else => err,
    };
}

fn openUnixSocket(io: std.Io, path: []const u8) !net.Stream {
    return services.connectUnixStream(io, path) catch |err| switch (err) {
        error.ServerUnavailable => error.XServerUnavailable,
        error.AccessDenied => error.AccessDenied,
        else => err,
    };
}

fn incrThreshold(conn: *const XConn) usize {
    const max_units = @max(conn.max_request_units, min_max_request_units);
    if (max_units <= 8) return incr_chunk_bytes;
    return @min((@as(usize, max_units) - 8) * 4 / 2, incr_chunk_bytes);
}

fn setSizeHints(conn: *XConn, window: u32, pixel_w: u32, pixel_h: u32, scale: u32) !void {
    const s = @max(scale, 1);
    var hints: [18]u32 = @splat(0);
    hints[0] = size_hint_p_min | size_hint_p_max | size_hint_p_base;
    hints[5] = 160 * s;
    hints[6] = 120 * s;
    hints[7] = @min(8192 * s, 32767);
    hints[8] = @min(8192 * s, 32767);
    hints[15] = pixel_w;
    hints[16] = pixel_h;
    try changeProperty32(conn, window, atom_wm_normal_hints, atom_wm_size_hints, &hints);
}

fn selectPropertyNotify(conn: *XConn, window: u32) !void {
    try selectWindowEvents(conn, window, event_property_change);
}

fn selectXsettingsEvents(conn: *XConn, window: u32) !void {
    try selectWindowEvents(conn, window, event_property_change | event_structure);
}

fn selectWindowEvents(conn: *XConn, window: u32, mask: u32) !void {
    var req: [16]u8 = @splat(0);
    req[0] = 2;
    put16(req[2..4], 4);
    put32(req[4..8], window);
    put32(req[8..12], cw_event_mask);
    put32(req[12..16], mask);
    try writeAll(conn, &req);
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

fn readSomeRaw(io: std.Io, stream: net.Stream, dst: []u8) !usize {
    var iov = [_][]u8{dst};
    return stream.read(io, iov[0..]);
}

fn readExactRaw(io: std.Io, stream: net.Stream, dst: []u8) !void {
    var off: usize = 0;
    while (off < dst.len) {
        const n = try readSomeRaw(io, stream, dst[off..]);
        if (n == 0) return error.EndOfStream;
        off += n;
    }
}

fn readExact(conn: *XConn, dst: []u8) !void {
    try readExactRaw(conn.io, conn.stream, dst);
}

fn writeAllRaw(io: std.Io, stream: net.Stream, bytes: []const u8) !void {
    var off: usize = 0;
    while (off < bytes.len) {
        const n = try io.vtable.netWrite(
            io.userdata,
            stream.socket.handle,
            "",
            &[_][]const u8{bytes[off..]},
            1,
        );
        if (n == 0) return error.WriteZero;
        off += n;
    }
}

fn writeAll(conn: *XConn, bytes: []const u8) !void {
    try writeAllRaw(conn.io, conn.stream, bytes);
}

fn internSessionAtoms(conn: *XConn) !void {
    conn.clipboard = try internAtom(conn, "CLIPBOARD");
    conn.utf8_string = try internAtom(conn, "UTF8_STRING");
    conn.targets = try internAtom(conn, "TARGETS");
    conn.incr = try internAtom(conn, "INCR");
    conn.net_wm_name = try internAtom(conn, "_NET_WM_NAME");
    conn.net_wm_icon_name = try internAtom(conn, "_NET_WM_ICON_NAME");
    conn.net_wm_pid = try internAtom(conn, "_NET_WM_PID");
    conn.net_startup_id = try internAtom(conn, "_NET_STARTUP_ID");
    conn.net_startup_info = try internAtom(conn, "_NET_STARTUP_INFO");
    conn.net_startup_info_begin = try internAtom(conn, "_NET_STARTUP_INFO_BEGIN");
    conn.net_wm_ping = try internAtom(conn, "_NET_WM_PING");
    conn.net_wm_user_time = try internAtom(conn, "_NET_WM_USER_TIME");
    conn.net_wm_window_type = try internAtom(conn, "_NET_WM_WINDOW_TYPE");
    conn.net_wm_window_type_normal = try internAtom(conn, "_NET_WM_WINDOW_TYPE_NORMAL");
    conn.text = try internAtom(conn, "TEXT");
    conn.timestamp = try internAtom(conn, "TIMESTAMP");
    conn.clipboard_manager = try internAtom(conn, "CLIPBOARD_MANAGER");
    conn.save_targets = try internAtom(conn, "SAVE_TARGETS");
    conn.mime_text_plain = try internAtom(conn, "text/plain");
    conn.mime_text_utf8 = try internAtom(conn, "text/plain;charset=utf-8");
    conn.mime_text_utf8_alt = try internAtom(conn, "text/plain;charset=utf8");
    conn.mime_uri_list = try internAtom(conn, "text/uri-list");
    conn.net_wm_allowed_actions = try internAtom(conn, "_NET_WM_ALLOWED_ACTIONS");
    conn.wm_take_focus = try internAtom(conn, "WM_TAKE_FOCUS");
    conn.wm_locale_name = try internAtom(conn, "WM_LOCALE_NAME");
    conn.xdnd_aware = try internAtom(conn, "XdndAware");
    conn.xdnd_enter = try internAtom(conn, "XdndEnter");
    conn.xdnd_position = try internAtom(conn, "XdndPosition");
    conn.xdnd_status = try internAtom(conn, "XdndStatus");
    conn.xdnd_leave = try internAtom(conn, "XdndLeave");
    conn.xdnd_drop = try internAtom(conn, "XdndDrop");
    conn.xdnd_finished = try internAtom(conn, "XdndFinished");
    conn.xdnd_selection = try internAtom(conn, "XdndSelection");
    conn.xdnd_type_list = try internAtom(conn, "XdndTypeList");
    conn.xdnd_action_copy = try internAtom(conn, "XdndActionCopy");
    conn.net_wm_state = try internAtom(conn, "_NET_WM_STATE");
    conn.net_wm_state_max_horz = try internAtom(conn, "_NET_WM_STATE_MAXIMIZED_HORZ");
    conn.net_wm_state_max_vert = try internAtom(conn, "_NET_WM_STATE_MAXIMIZED_VERT");
    conn.net_wm_state_fullscreen = try internAtom(conn, "_NET_WM_STATE_FULLSCREEN");
    conn.net_wm_icon = try internAtom(conn, "_NET_WM_ICON");
    conn.net_wm_state_attention = try internAtom(conn, "_NET_WM_STATE_DEMANDS_ATTENTION");
    conn.net_wm_state_hidden = try internAtom(conn, "_NET_WM_STATE_HIDDEN");
    conn.net_wm_state_shaded = try internAtom(conn, "_NET_WM_STATE_SHADED");
    conn.utf16_string = try internAtom(conn, "UTF16_STRING");
    conn.mime_text_html = try internAtom(conn, "text/html");
    conn.mime_text_html_utf8 = try internAtom(conn, "text/html;charset=utf-8");
    conn.mime_text_html_utf8_alt = try internAtom(conn, "text/html;charset=utf8");
    conn.mime_gnome_copied = try internAtom(conn, "x-special/gnome-copied-files");
    conn.mime_moz_url = try internAtom(conn, "text/x-moz-url");
    conn.mime_moz_file = try internAtom(conn, "application/x-moz-file");
    conn.mime_kde_urilist = try internAtom(conn, "application/x-kde4-urilist");
    conn.mime_nautilus = try internAtom(conn, "x-special/nautilus-clipboard");
    conn.mime_uri_list_alt = try internAtom(conn, "text/x-uri-list");
    conn.mime_rtf = try internAtom(conn, "text/rtf");
    conn.mime_rtf_app = try internAtom(conn, "application/rtf");
    conn.compound_text = try internAtom(conn, "COMPOUND_TEXT");
    conn.mime_kde5_urilist = try internAtom(conn, "application/x-kde5-urilist");
    conn.mime_kde_suggestedfilename = try internAtom(conn, "application/x-kde-suggestedfilename");
    conn.mime_moz_url_priv = try internAtom(conn, "text/x-moz-url-priv");
    conn.mime_text_latin1 = try internAtom(conn, "text/plain;charset=ISO-8859-1");
    conn.mime_text_latin1_alt = try internAtom(conn, "text/plain;charset=iso-8859-1");
    conn.mime_text_latin9 = try internAtom(conn, "text/plain;charset=ISO-8859-15");
    conn.mime_text_latin9_alt = try internAtom(conn, "text/plain;charset=iso-8859-15");
    conn.mime_text_latin2 = try internAtom(conn, "text/plain;charset=ISO-8859-2");
    conn.mime_text_latin2_alt = try internAtom(conn, "text/plain;charset=iso-8859-2");
    conn.mime_text_latin5 = try internAtom(conn, "text/plain;charset=ISO-8859-9");
    conn.mime_text_latin5_alt = try internAtom(conn, "text/plain;charset=iso-8859-9");
    conn.mime_text_cyrillic = try internAtom(conn, "text/plain;charset=ISO-8859-5");
    conn.mime_text_cyrillic_alt = try internAtom(conn, "text/plain;charset=iso-8859-5");
    conn.mime_text_greek = try internAtom(conn, "text/plain;charset=ISO-8859-7");
    conn.mime_text_greek_alt = try internAtom(conn, "text/plain;charset=iso-8859-7");
    conn.mime_text_latin3 = try internAtom(conn, "text/plain;charset=ISO-8859-3");
    conn.mime_text_latin3_alt = try internAtom(conn, "text/plain;charset=iso-8859-3");
    conn.mime_text_latin4 = try internAtom(conn, "text/plain;charset=ISO-8859-4");
    conn.mime_text_latin4_alt = try internAtom(conn, "text/plain;charset=iso-8859-4");
    conn.mime_text_arabic = try internAtom(conn, "text/plain;charset=ISO-8859-6");
    conn.mime_text_arabic_alt = try internAtom(conn, "text/plain;charset=iso-8859-6");
    conn.mime_text_hebrew = try internAtom(conn, "text/plain;charset=ISO-8859-8");
    conn.mime_text_hebrew_alt = try internAtom(conn, "text/plain;charset=iso-8859-8");
    conn.mime_text_cp1252 = try internAtom(conn, "text/plain;charset=windows-1252");
    conn.mime_text_cp1252_alt = try internAtom(conn, "text/plain;charset=cp1252");
    conn.mime_text_markdown = try internAtom(conn, "text/markdown");
    conn.mime_text_markdown_alt = try internAtom(conn, "text/x-markdown");
    conn.xsettings_s0 = try internAtom(conn, "_XSETTINGS_S0");
    conn.xsettings_settings = try internAtom(conn, "_XSETTINGS_SETTINGS");
    conn.wm_state = try internAtom(conn, "WM_STATE");
    conn.wm_change_state = try internAtom(conn, "WM_CHANGE_STATE");
    conn.multiple = try internAtom(conn, "MULTIPLE");
    conn.atom_pair = try internAtom(conn, "ATOM_PAIR");
}

fn setNetWmIcon(gpa: std.mem.Allocator, conn: *XConn, window: u32) !void {
    if (conn.net_wm_icon == 0) return;
    const candidates = [_][]const u32{
        &.{ 16, 32, 64, 128 },
        &.{ 16, 32, 64 },
        &.{ 16, 32 },
    };
    for (candidates) |sizes| {
        const packed_icon = try services.packNetWmIcon(gpa, sizes);
        defer gpa.free(packed_icon);
        if (changePropertyCardinals(conn, window, conn.net_wm_icon, packed_icon)) |_| return else |_| {}
    }
}

fn installScaledCursor(gpa: std.mem.Allocator, conn: *XConn, window: u32, scale: u32, env: []const u8, stash: ?*std.ArrayList([32]u8)) !u32 {
    var resources: []u8 = &.{};
    if (getWindowProperty(gpa, conn, conn.screen.root, atom_resource_manager, stash)) |bytes| {
        resources = bytes;
    } else |_| {}
    defer if (resources.len != 0) gpa.free(resources);
    const size = services.cursorPixelSize(scale, env, resources);
    const count = try std.math.mul(usize, @as(usize, size), @as(usize, size));
    const pixels = try gpa.alloc(u32, count);
    defer gpa.free(pixels);
    services.fillArrowCursor(pixels, size);
    const stride = services.bitmapStride(size);
    const plane_len = stride * @as(usize, size);
    const source_bits = try gpa.alloc(u8, plane_len);
    defer gpa.free(source_bits);
    const mask_bits = try gpa.alloc(u8, plane_len);
    defer gpa.free(mask_bits);
    services.encodeBitmapPlane(source_bits, pixels, size, size, true);
    services.encodeBitmapPlane(mask_bits, pixels, size, size, false);

    const source = try conn.allocId();
    const mask = try conn.allocId();
    const gc = try conn.allocId();
    const cursor = try conn.allocId();
    try createPixmap(conn, source, 1, @intCast(size), @intCast(size));
    try createPixmap(conn, mask, 1, @intCast(size), @intCast(size));
    try createMonoGc(conn, gc, source);
    try putBitmap(conn, source, gc, source_bits, size, size);
    try putBitmap(conn, mask, gc, mask_bits, size, size);
    const hot = services.arrowHotspot(size);
    try createCursor(conn, cursor, source, mask, hot.x, hot.y);
    try defineCursor(conn, window, cursor);
    freeGc(conn, gc) catch {};
    freePixmap(conn, source) catch {};
    freePixmap(conn, mask) catch {};
    return cursor;
}

fn sendNetWmStateClient(conn: *XConn, window: u32, action: u32, atom: u32) !void {
    if (conn.net_wm_state == 0 or atom == 0) return;
    var req: [44]u8 = @splat(0);
    req[0] = 25; // SendEvent
    req[1] = 1;
    put16(req[2..4], 11);
    put32(req[4..8], conn.screen.root);
    put32(req[8..12], (1 << 19) | (1 << 20));
    req[12] = 33;
    req[13] = 32;
    put32(req[16..20], window);
    put32(req[20..24], conn.net_wm_state);
    put32(req[24..28], action);
    put32(req[28..32], atom);
    put32(req[36..40], 1); // source: application
    try writeAll(conn, &req);
}

fn setXdndAware(conn: *XConn, window: u32) !void {
    if (conn.xdnd_aware == 0) return;
    try changeProperty32(conn, window, conn.xdnd_aware, atom_atom, &.{5});
}

fn setNetWmState(conn: *XConn, window: u32, atoms: []const u32) !void {
    if (conn.net_wm_state == 0) return;
    try changePropertyAtoms(conn, window, conn.net_wm_state, atoms);
}

fn selectRootPropertyNotify(conn: *XConn) !void {
    try selectPropertyNotify(conn, conn.screen.root);
}

fn queryExtension(conn: *XConn, name: []const u8) !?struct { major: u8, first_event: u8 } {
    const padded = pad4(name.len);
    const req = try std.heap.page_allocator.alloc(u8, 8 + padded);
    defer std.heap.page_allocator.free(req);
    @memset(req, 0);
    req[0] = 98;
    put16(req[2..4], @intCast(req.len / 4));
    put16(req[4..6], @intCast(name.len));
    @memcpy(req[8 .. 8 + name.len], name);
    try writeAll(conn, req);
    const reply = try readReply(conn);
    if (reply[1] == 0) return null;
    return .{ .major = reply[8], .first_event = reply[9] };
}

fn enableRandr(conn: *XConn) !void {
    const ext = (try queryExtension(conn, "RANDR")) orelse return;
    if (ext.major == 0 or ext.first_event == 0) return;
    conn.randr_opcode = ext.major;
    conn.randr_event = ext.first_event;
    var version_req: [12]u8 = @splat(0);
    version_req[0] = ext.major;
    put16(version_req[2..4], 3);
    put32(version_req[4..8], 1);
    put32(version_req[8..12], 2);
    try writeAll(conn, &version_req);
    _ = try readReply(conn);
    var select_req: [12]u8 = @splat(0);
    select_req[0] = ext.major;
    select_req[1] = 4;
    put16(select_req[2..4], 3);
    put32(select_req[4..8], conn.screen.root);
    put16(select_req[8..10], 1); // RRScreenChangeNotifyMask
    try writeAll(conn, &select_req);
}

fn randrScreenChangeSize(event: [32]u8) struct { width_px: u16, width_mm: u16 } {
    return .{
        .width_px = get16(event[24..26]),
        .width_mm = get16(event[28..30]),
    };
}

fn sendXdndClientMessage(conn: *XConn, dest: u32, typ: u32, data: [5]u32) !void {
    if (dest == 0 or typ == 0) return;
    var req: [44]u8 = @splat(0);
    req[0] = 25; // SendEvent
    put16(req[2..4], 11);
    put32(req[4..8], dest);
    req[12] = 33;
    req[13] = 32;
    put32(req[16..20], dest);
    put32(req[20..24], typ);
    put32(req[24..28], data[0]);
    put32(req[28..32], data[1]);
    put32(req[32..36], data[2]);
    put32(req[36..40], data[3]);
    put32(req[40..44], data[4]);
    try writeAll(conn, &req);
}

fn detectScale(
    gpa: std.mem.Allocator,
    conn: *XConn,
    env: []const u8,
    stash: ?*std.ArrayList([32]u8),
    window: u32,
    pixel_w: u32,
    pixel_h: u32,
    crtcs: []const RandrCrtc,
) !struct { scale: u32, source: ScaleSource } {
    if (services.scaleFromEnvironment(env)) |scale| return .{ .scale = scale, .source = .env };
    if (scaleFromXsettings(gpa, conn, stash)) |scale| return .{ .scale = scale, .source = .xsettings };
    if (getWindowProperty(gpa, conn, conn.screen.root, atom_resource_manager, stash)) |resources| {
        defer gpa.free(resources);
        if (services.parseXftDpi(resources)) |dpi| return .{ .scale = services.scaleFromDpi(dpi), .source = .xft };
    } else |_| {}
    if (scaleFromCachedCrtcs(gpa, conn, window, pixel_w, pixel_h, crtcs, stash)) |scale| return .{ .scale = scale, .source = .physical };
    if (services.scaleFromScreenMm(conn.screen.width_px, conn.screen.width_mm)) |scale| {
        return .{ .scale = scale, .source = .physical };
    }
    return .{ .scale = 1, .source = .fallback };
}

fn scaleFromXsettings(gpa: std.mem.Allocator, conn: *XConn, stash: ?*std.ArrayList([32]u8)) ?u32 {
    if (conn.xsettings_settings == 0 or conn.xsettings_window == 0) return null;
    const bytes = getWindowProperty(gpa, conn, conn.xsettings_window, conn.xsettings_settings, stash) catch return null;
    defer gpa.free(bytes);
    return services.parseXsettingsScale(bytes);
}

fn enableXi2(conn: *XConn, window: u32) !void {
    const ext = (try queryExtension(conn, "XInputExtension")) orelse return;
    if (ext.major == 0) return;
    var version_req: [8]u8 = @splat(0);
    version_req[0] = ext.major;
    version_req[1] = xi_query_version;
    put16(version_req[2..4], 2);
    put16(version_req[4..6], 2);
    put16(version_req[6..8], 2);
    try writeAll(conn, &version_req);
    const reply = try readReply(conn);
    const major = get16(reply[8..10]);
    const minor = get16(reply[10..12]);
    if (major < 2 or (major == 2 and minor < 2)) return;
    conn.xi_opcode = ext.major;
    var sel: [20]u8 = @splat(0);
    sel[0] = ext.major;
    sel[1] = xi_select_events;
    put16(sel[2..4], 5);
    put32(sel[4..8], window);
    put16(sel[8..10], 1);
    put16(sel[12..14], xi_all_master_devices);
    put16(sel[14..16], 1);
    sel[18] = xiTouchMaskByte();
    try writeAll(conn, &sel);
}

fn xiTouchMaskByte() u8 {
    return (1 << (xi_touch_begin & 7)) | (1 << (xi_touch_update & 7)) | (1 << (xi_touch_end & 7));
}

fn scaleFromCachedCrtcs(gpa: std.mem.Allocator, conn: *XConn, window: u32, pixel_w: u32, pixel_h: u32, crtcs: []const RandrCrtc, stash: ?*std.ArrayList([32]u8)) ?u32 {
    if (window == 0 or crtcs.len == 0) return null;
    const pos = translateWindowToRoot(gpa, conn, window, stash) orelse return null;
    const x = pos.x + @divTrunc(@as(i32, @intCast(pixel_w)), 2);
    const y = pos.y + @divTrunc(@as(i32, @intCast(pixel_h)), 2);
    const crtc = crtcContaining(crtcs, x, y) orelse crtcContaining(crtcs, pos.x, pos.y) orelse return null;
    return services.scaleFromScreenMm(crtc.width, crtc.width_mm);
}

fn visibilityIsFullyObscured(state: u8) bool {
    return state == visibility_fully_obscured;
}

fn crtcContains(crtc: RandrCrtc, x: i32, y: i32) bool {
    if (crtc.width == 0 or crtc.height == 0) return false;
    return x >= crtc.x and y >= crtc.y and
        x < crtc.x + @as(i32, @intCast(crtc.width)) and
        y < crtc.y + @as(i32, @intCast(crtc.height));
}

fn crtcContaining(crtcs: []const RandrCrtc, x: i32, y: i32) ?RandrCrtc {
    for (crtcs) |crtc| {
        if (crtcContains(crtc, x, y)) return crtc;
    }
    return null;
}

fn translateWindowToRoot(gpa: std.mem.Allocator, conn: *XConn, window: u32, stash: ?*std.ArrayList([32]u8)) ?struct { x: i32, y: i32 } {
    var req: [16]u8 = @splat(0);
    req[0] = 40; // TranslateCoordinates
    put16(req[2..4], 4);
    put32(req[4..8], window);
    put32(req[8..12], conn.screen.root);
    writeAll(conn, &req) catch return null;
    const reply = readReplyMaybeStashing(gpa, conn, stash) catch return null;
    if (reply[1] == 0) return null;
    const x: i32 = @as(i16, @bitCast(get16(reply[12..14])));
    const y: i32 = @as(i16, @bitCast(get16(reply[14..16])));
    return .{ .x = x, .y = y };
}

fn readReplyExtra(gpa: std.mem.Allocator, conn: *XConn, stash: ?*std.ArrayList([32]u8)) !struct { header: [32]u8, extra: []u8 } {
    const header = try readReplyMaybeStashing(gpa, conn, stash);
    const extra_words = get32(header[4..8]);
    if (extra_words > 256 * 1024) return error.ReplyTooLarge;
    const extra = try gpa.alloc(u8, extra_words * 4);
    errdefer gpa.free(extra);
    if (extra.len != 0) try readExact(conn, extra);
    return .{ .header = header, .extra = extra };
}

fn fetchRandrCrtcs(gpa: std.mem.Allocator, conn: *XConn, stash: ?*std.ArrayList([32]u8)) !struct { crtcs: [max_randr_crtcs]RandrCrtc, count: u8 } {
    var result: [max_randr_crtcs]RandrCrtc = @splat(.{});
    if (conn.randr_opcode == 0) return .{ .crtcs = result, .count = 0 };
    var req: [8]u8 = @splat(0);
    req[0] = conn.randr_opcode;
    req[1] = 25; // GetScreenResourcesCurrent
    put16(req[2..4], 2);
    put32(req[4..8], conn.screen.root);
    try writeAll(conn, &req);
    const resources = try readReplyExtra(gpa, conn, stash);
    defer gpa.free(resources.extra);
    const n_crtcs = get16(resources.header[16..18]);
    const config_ts = get32(resources.header[12..16]);
    const crtc_bytes = @as(usize, n_crtcs) * 4;
    if (resources.extra.len < crtc_bytes) return .{ .crtcs = result, .count = 0 };
    var count: u8 = 0;
    var i: usize = 0;
    while (i < n_crtcs and count < max_randr_crtcs) : (i += 1) {
        const crtc_id = get32(resources.extra[i * 4 ..][0..4]);
        if (crtc_id == 0) continue;
        if (randrCrtcInfo(gpa, conn, crtc_id, config_ts, stash)) |crtc| {
            result[count] = crtc;
            count += 1;
        } else |_| {}
    }
    return .{ .crtcs = result, .count = count };
}

fn randrCrtcInfo(
    gpa: std.mem.Allocator,
    conn: *XConn,
    crtc: u32,
    config_ts: u32,
    stash: ?*std.ArrayList([32]u8),
) !RandrCrtc {
    var req: [12]u8 = @splat(0);
    req[0] = conn.randr_opcode;
    req[1] = 20; // GetCrtcInfo
    put16(req[2..4], 3);
    put32(req[4..8], crtc);
    put32(req[8..12], config_ts);
    try writeAll(conn, &req);
    const reply = try readReplyExtra(gpa, conn, stash);
    defer gpa.free(reply.extra);
    if (reply.header[1] != 0) return error.CrtcUnavailable;
    const mode = get32(reply.header[16..20]);
    const width: u32 = get16(reply.header[12..14]);
    const height: u32 = get16(reply.header[14..16]);
    if (mode == 0 or width == 0 or height == 0) return error.CrtcDisabled;
    const x: i32 = @as(i16, @bitCast(get16(reply.header[8..10])));
    const y: i32 = @as(i16, @bitCast(get16(reply.header[10..12])));
    var width_mm: u32 = 0;
    const n_outputs = get16(reply.header[24..26]);
    if (n_outputs != 0 and reply.extra.len >= 4) {
        const output = get32(reply.extra[0..4]);
        width_mm = randrOutputWidthMm(gpa, conn, output, config_ts, stash) catch 0;
    }
    return .{
        .x = x,
        .y = y,
        .width = width,
        .height = height,
        .width_mm = width_mm,
    };
}

fn randrOutputWidthMm(
    gpa: std.mem.Allocator,
    conn: *XConn,
    output: u32,
    config_ts: u32,
    stash: ?*std.ArrayList([32]u8),
) !u32 {
    var req: [12]u8 = @splat(0);
    req[0] = conn.randr_opcode;
    req[1] = 9; // GetOutputInfo
    put16(req[2..4], 3);
    put32(req[4..8], output);
    put32(req[8..12], config_ts);
    try writeAll(conn, &req);
    const reply = try readReplyExtra(gpa, conn, stash);
    defer gpa.free(reply.extra);
    if (reply.header[1] != 0) return error.OutputUnavailable;
    return get32(reply.header[12..16]);
}

fn localHostname(buf: []u8) []const u8 {
    var uts: linux.utsname = undefined;
    if (linux.errno(linux.uname(&uts)) != .SUCCESS) return "localhost";
    const name = std.mem.sliceTo(&uts.nodename, 0);
    const n = @min(buf.len, name.len);
    @memcpy(buf[0..n], name[0..n]);
    return buf[0..n];
}

const XauthRecord = struct {
    family: u16,
    address: []const u8,
    number: []const u8,
    name: []const u8,
    data: []const u8,
};

fn nextXauthRecord(bytes: []const u8, offset: *usize) !?XauthRecord {
    if (offset.* >= bytes.len) return null;
    if (bytes.len - offset.* < 2) return error.TruncatedXauth;
    const family = std.mem.readInt(u16, bytes[offset.*..][0..2], .big);
    offset.* += 2;
    const address = try takeXauthCounted(bytes, offset);
    const number = try takeXauthCounted(bytes, offset);
    const name = try takeXauthCounted(bytes, offset);
    const data = try takeXauthCounted(bytes, offset);
    return .{
        .family = family,
        .address = address,
        .number = number,
        .name = name,
        .data = data,
    };
}

fn takeXauthCounted(bytes: []const u8, offset: *usize) ![]const u8 {
    if (bytes.len - offset.* < 2) return error.TruncatedXauth;
    const len = std.mem.readInt(u16, bytes[offset.*..][0..2], .big);
    offset.* += 2;
    if (bytes.len - offset.* < len) return error.TruncatedXauth;
    const slice = bytes[offset.* .. offset.* + len];
    offset.* += len;
    return slice;
}

fn isLoopbackHost(host: []const u8) bool {
    return std.mem.eql(u8, host, "localhost") or
        std.mem.eql(u8, host, "127.0.0.1") or
        std.mem.eql(u8, host, "::1");
}

fn internetAddressMatches(address: []const u8, hostname: []const u8) bool {
    if (std.mem.eql(u8, address, hostname)) return true;
    if (isLoopbackHost(hostname) and std.mem.eql(u8, address, &[_]u8{ 127, 0, 0, 1 })) return true;
    if (net.Ip4Address.parse(hostname, 0)) |ip4| {
        return std.mem.eql(u8, address, &ip4.bytes);
    } else |_| {}
    return false;
}

fn xauthMatches(record: XauthRecord, hostname: []const u8, display_number: []const u8, local: bool) bool {
    if (!std.mem.eql(u8, record.name, "MIT-MAGIC-COOKIE-1")) return false;
    if (record.number.len != 0 and !std.mem.eql(u8, record.number, display_number)) return false;
    return switch (record.family) {
        family_wild => true,
        family_local => std.mem.eql(u8, record.address, hostname),
        family_internet => internetAddressMatches(record.address, hostname) or
            (local and std.mem.eql(u8, record.address, &[_]u8{ 127, 0, 0, 1 })),
        else => false,
    };
}

fn selectXauth(bytes: []const u8, hostname: []const u8, display_number: []const u8, local: bool) !?XauthRecord {
    var offset: usize = 0;
    var fallback: ?XauthRecord = null;
    while (try nextXauthRecord(bytes, &offset)) |record| {
        if (!xauthMatches(record, hostname, display_number, local)) continue;
        if (local and record.family == family_local) return record;
        if (!local and record.family == family_internet) return record;
        if (fallback == null) fallback = record;
    }
    return fallback;
}

fn readMatchingAuth(env: []const u8, hostname: []const u8, display_number: []const u8, local: bool, storage: []u8) !Auth {
    var path_buf: [512]u8 = undefined;
    const path = xauthPath(env, &path_buf) orelse return error.NoAuthFile;
    var zpath: [513]u8 = undefined;
    if (path.len >= zpath.len) return error.NameTooLong;
    @memcpy(zpath[0..path.len], path);
    zpath[path.len] = 0;
    const fd = try openReadOnly(@ptrCast(zpath[0 .. path.len + 1]));
    defer _ = linux.close(fd);
    var file: std.ArrayList(u8) = .empty;
    defer file.deinit(std.heap.page_allocator);
    var scratch: [4096]u8 = undefined;
    while (true) {
        const n = try readSomeFd(fd, &scratch);
        if (n == 0) break;
        if (file.items.len + n > 64 * 1024) return error.AuthTooLarge;
        try file.appendSlice(std.heap.page_allocator, scratch[0..n]);
    }
    const record = (try selectXauth(file.items, hostname, display_number, local)) orelse return error.NoMatchingAuth;
    if (record.name.len + record.data.len > storage.len) return error.AuthTooLarge;
    @memcpy(storage[0..record.name.len], record.name);
    @memcpy(storage[record.name.len .. record.name.len + record.data.len], record.data);
    return .{
        .name = storage[0..record.name.len],
        .data = storage[record.name.len .. record.name.len + record.data.len],
    };
}

fn xauthPath(env: []const u8, buf: []u8) ?[]const u8 {
    if (services.environValue(env, "XAUTHORITY")) |value| {
        if (value.len != 0 and value.len <= buf.len) {
            @memcpy(buf[0..value.len], value);
            return buf[0..value.len];
        }
    }
    const home = services.environValue(env, "HOME") orelse return null;
    if (home.len + "/.Xauthority".len > buf.len) return null;
    @memcpy(buf[0..home.len], home);
    @memcpy(buf[home.len .. home.len + "/.Xauthority".len], "/.Xauthority");
    return buf[0 .. home.len + "/.Xauthority".len];
}

const PropertyValue = struct {
    typ: u32,
    bytes: []u8,
};

fn getWindowProperty(gpa: std.mem.Allocator, conn: *XConn, window: u32, property: u32, stash: ?*std.ArrayList([32]u8)) ![]u8 {
    return (try getWindowPropertyRaw(gpa, conn, window, property, false, stash)).bytes;
}

fn getWindowPropertyRaw(gpa: std.mem.Allocator, conn: *XConn, window: u32, property: u32, delete: bool, stash: ?*std.ArrayList([32]u8)) !PropertyValue {
    var req: [24]u8 = @splat(0);
    req[0] = 20;
    req[1] = if (delete) 1 else 0;
    put16(req[2..4], 6);
    put32(req[4..8], window);
    put32(req[8..12], property);
    put32(req[16..20], 0);
    put32(req[20..24], 256 * 1024);
    try writeAll(conn, &req);

    const reply = try readReplyMaybeStashing(gpa, conn, stash);
    const extra_words = get32(reply[4..8]);
    const extra = try gpa.alloc(u8, extra_words * 4);
    errdefer gpa.free(extra);
    if (extra.len != 0) try readExact(conn, extra);
    const typ = get32(reply[8..12]);
    if (reply[1] == 0 or typ == 0) {
        gpa.free(extra);
        return error.NoProperty;
    }
    const value_len: usize = @intCast(get32(reply[16..20]));
    const format = reply[1];
    const bytes_len: usize = switch (format) {
        8 => value_len,
        16 => value_len * 2,
        32 => value_len * 4,
        else => {
            gpa.free(extra);
            return error.UnsupportedPropertyFormat;
        },
    };
    if (bytes_len > extra.len) {
        gpa.free(extra);
        return error.ShortProperty;
    }
    if (bytes_len == extra.len) return .{ .typ = typ, .bytes = extra };
    const trimmed = try gpa.dupe(u8, extra[0..bytes_len]);
    gpa.free(extra);
    return .{ .typ = typ, .bytes = trimmed };
}

fn changePropertyBytes(conn: *XConn, window: u32, property: u32, typ: u32, bytes: []const u8) !void {
    if (bytes.len > max_clipboard_bytes) return error.PropertyTooLarge;
    const padded = pad4(bytes.len);
    const need = 24 + padded;
    const req = try std.heap.page_allocator.alloc(u8, need);
    defer std.heap.page_allocator.free(req);
    @memset(req, 0);
    req[0] = 18;
    req[1] = prop_replace;
    put16(req[2..4], @intCast(req.len / 4));
    put32(req[4..8], window);
    put32(req[8..12], property);
    put32(req[12..16], typ);
    req[16] = 8;
    put32(req[20..24], @intCast(bytes.len));
    if (bytes.len != 0) @memcpy(req[24 .. 24 + bytes.len], bytes);
    try writeAll(conn, req);
}

fn changePropertyAtoms(conn: *XConn, window: u32, property: u32, atoms: []const u32) !void {
    try changeProperty32(conn, window, property, atom_atom, atoms);
}

fn changeProperty32(conn: *XConn, window: u32, property: u32, typ: u32, values: []const u32) !void {
    if (values.len > 64) return error.PropertyTooLarge;
    var req: [24 + 256]u8 = @splat(0);
    const total = 24 + values.len * 4;
    req[0] = 18;
    req[1] = prop_replace;
    put16(req[2..4], @intCast(total / 4));
    put32(req[4..8], window);
    put32(req[8..12], property);
    put32(req[12..16], typ);
    req[16] = 32;
    put32(req[20..24], @intCast(values.len));
    for (values, 0..) |value, i| put32(req[24 + i * 4 .. 28 + i * 4], value);
    try writeAll(conn, req[0..total]);
}

fn changePropertyCardinals(conn: *XConn, window: u32, property: u32, values: []const u32) !void {
    // `_NET_WM_ICON` at 16/32/64/128 is ~22k CARD32s; the old 16k cap
    // rejected a single 128px mark.
    const header_units: usize = 6;
    const max_units = @max(@as(usize, conn.max_request_units), min_max_request_units);
    if (values.len + header_units > max_units or values.len + header_units > std.math.maxInt(u16)) {
        return error.PropertyTooLarge;
    }
    const total = 24 + values.len * 4;
    const req = try std.heap.page_allocator.alloc(u8, total);
    defer std.heap.page_allocator.free(req);
    @memset(req, 0);
    req[0] = 18;
    req[1] = prop_replace;
    put16(req[2..4], @intCast(total / 4));
    put32(req[4..8], window);
    put32(req[8..12], property);
    put32(req[12..16], atom_cardinal);
    req[16] = 32;
    put32(req[20..24], @intCast(values.len));
    for (values, 0..) |value, i| put32(req[24 + i * 4 .. 28 + i * 4], value);
    try writeAll(conn, req);
}

fn createPixmap(conn: *XConn, pixmap: u32, depth: u8, w: u16, h: u16) !void {
    var req: [16]u8 = @splat(0);
    req[0] = 53;
    req[1] = depth;
    put16(req[2..4], 4);
    put32(req[4..8], pixmap);
    put32(req[8..12], conn.screen.root);
    put16(req[12..14], w);
    put16(req[14..16], h);
    try writeAll(conn, &req);
}

fn createMonoGc(conn: *XConn, gc: u32, drawable: u32) !void {
    var req: [24]u8 = @splat(0);
    req[0] = 55;
    put16(req[2..4], 6);
    put32(req[4..8], gc);
    put32(req[8..12], drawable);
    put32(req[12..16], gc_foreground | gc_background);
    put32(req[16..20], 1);
    put32(req[20..24], 0);
    try writeAll(conn, &req);
}

fn putBitmap(conn: *XConn, drawable: u32, gc: u32, bits: []const u8, w: u32, h: u32) !void {
    const padded = pad4(bits.len);
    const req = try std.heap.page_allocator.alloc(u8, 24 + padded);
    defer std.heap.page_allocator.free(req);
    @memset(req, 0);
    req[0] = 72;
    req[1] = z_pixmap;
    put16(req[2..4], @intCast((24 + padded) / 4));
    put32(req[4..8], drawable);
    put32(req[8..12], gc);
    put16(req[12..14], @intCast(w));
    put16(req[14..16], @intCast(h));
    req[21] = 1;
    if (bits.len != 0) @memcpy(req[24 .. 24 + bits.len], bits);
    try writeAll(conn, req);
}

fn createCursor(conn: *XConn, cursor: u32, source: u32, mask: u32, hot_x: u32, hot_y: u32) !void {
    var req: [32]u8 = @splat(0);
    req[0] = 93;
    put16(req[2..4], 8);
    put32(req[4..8], cursor);
    put32(req[8..12], source);
    put32(req[12..16], mask);
    put16(req[16..18], 0);
    put16(req[18..20], 0);
    put16(req[20..22], 0);
    put16(req[22..24], 0xffff);
    put16(req[24..26], 0xffff);
    put16(req[26..28], 0xffff);
    put16(req[28..30], @intCast(hot_x));
    put16(req[30..32], @intCast(hot_y));
    try writeAll(conn, &req);
}

fn defineCursor(conn: *XConn, window: u32, cursor: u32) !void {
    var req: [16]u8 = @splat(0);
    req[0] = 2;
    put16(req[2..4], 4);
    put32(req[4..8], window);
    put32(req[8..12], 1 << 14); // CWCursor
    put32(req[12..16], cursor);
    try writeAll(conn, &req);
}

fn freeCursor(conn: *XConn, cursor: u32) !void {
    var req: [8]u8 = @splat(0);
    req[0] = 95;
    put16(req[2..4], 2);
    put32(req[4..8], cursor);
    try writeAll(conn, &req);
}

fn freePixmap(conn: *XConn, pixmap: u32) !void {
    var req: [8]u8 = @splat(0);
    req[0] = 54;
    put16(req[2..4], 2);
    put32(req[4..8], pixmap);
    try writeAll(conn, &req);
}

fn freeGc(conn: *XConn, gc: u32) !void {
    var req: [8]u8 = @splat(0);
    req[0] = 60;
    put16(req[2..4], 2);
    put32(req[4..8], gc);
    try writeAll(conn, &req);
}

fn wmStateIsHidden(state: u32) bool {
    return state != 1; // ICCCM NormalState=1; Withdrawn=0, Iconic=3
}

fn combinedWmHidden(net_hidden: bool, icccm_hidden: bool, unmapped: bool, shaded: bool) bool {
    return net_hidden or icccm_hidden or unmapped or shaded;
}

fn textAtomRank(conn: *const XConn, atom: u32) u8 {
    if (atom == 0) return 0;
    if (atom == conn.utf8_string) return 7;
    if (atom == conn.mime_text_utf8) return 6;
    if (atom == conn.mime_text_utf8_alt) return 5;
    if (atom == conn.mime_text_plain) return 4;
    if (atom == conn.utf16_string or isUriListAtom(conn, atom) or isDesktopFileAtom(conn, atom)) return 3;
    if (isLatin1Atom(conn, atom) or isLatin9Atom(conn, atom) or isLatin2Atom(conn, atom) or isLatin5Atom(conn, atom) or
        isCyrillicAtom(conn, atom) or isGreekAtom(conn, atom) or isLatin3Atom(conn, atom) or isLatin4Atom(conn, atom) or
        isArabicAtom(conn, atom) or isHebrewAtom(conn, atom) or isCp1252Atom(conn, atom)) return 3;
    if (atom == conn.text or atom == conn.compound_text) return 2;
    if (atom == atom_string) return 1;
    if (isHtmlAtom(conn, atom) or isRtfAtom(conn, atom) or isMarkdownAtom(conn, atom)) return 1;
    return 0;
}

fn isHtmlAtom(conn: *const XConn, atom: u32) bool {
    return atom != 0 and (atom == conn.mime_text_html or atom == conn.mime_text_html_utf8 or atom == conn.mime_text_html_utf8_alt);
}

fn isUriListAtom(conn: *const XConn, atom: u32) bool {
    return atom != 0 and (atom == conn.mime_uri_list or atom == conn.mime_uri_list_alt);
}

fn isRtfAtom(conn: *const XConn, atom: u32) bool {
    return atom != 0 and (atom == conn.mime_rtf or atom == conn.mime_rtf_app);
}

fn isLatin1Atom(conn: *const XConn, atom: u32) bool {
    return atom != 0 and (atom == conn.mime_text_latin1 or atom == conn.mime_text_latin1_alt);
}

fn isLatin9Atom(conn: *const XConn, atom: u32) bool {
    return atom != 0 and (atom == conn.mime_text_latin9 or atom == conn.mime_text_latin9_alt);
}

fn isLatin2Atom(conn: *const XConn, atom: u32) bool {
    return atom != 0 and (atom == conn.mime_text_latin2 or atom == conn.mime_text_latin2_alt);
}

fn isLatin5Atom(conn: *const XConn, atom: u32) bool {
    return atom != 0 and (atom == conn.mime_text_latin5 or atom == conn.mime_text_latin5_alt);
}

fn isCyrillicAtom(conn: *const XConn, atom: u32) bool {
    return atom != 0 and (atom == conn.mime_text_cyrillic or atom == conn.mime_text_cyrillic_alt);
}

fn isGreekAtom(conn: *const XConn, atom: u32) bool {
    return atom != 0 and (atom == conn.mime_text_greek or atom == conn.mime_text_greek_alt);
}

fn isLatin3Atom(conn: *const XConn, atom: u32) bool {
    return atom != 0 and (atom == conn.mime_text_latin3 or atom == conn.mime_text_latin3_alt);
}

fn isLatin4Atom(conn: *const XConn, atom: u32) bool {
    return atom != 0 and (atom == conn.mime_text_latin4 or atom == conn.mime_text_latin4_alt);
}

fn isArabicAtom(conn: *const XConn, atom: u32) bool {
    return atom != 0 and (atom == conn.mime_text_arabic or atom == conn.mime_text_arabic_alt);
}

fn isHebrewAtom(conn: *const XConn, atom: u32) bool {
    return atom != 0 and (atom == conn.mime_text_hebrew or atom == conn.mime_text_hebrew_alt);
}

fn isCp1252Atom(conn: *const XConn, atom: u32) bool {
    return atom != 0 and (atom == conn.mime_text_cp1252 or atom == conn.mime_text_cp1252_alt);
}

fn x11NotifyModeIsGrab(mode: u8) bool {
    return mode == notify_mode_grab or mode == notify_mode_ungrab;
}

fn x11FocusDetailIsPointer(detail: u8) bool {
    return detail == notify_detail_pointer or detail == notify_detail_pointer_root;
}

fn isMarkdownAtom(conn: *const XConn, atom: u32) bool {
    return atom != 0 and (atom == conn.mime_text_markdown or atom == conn.mime_text_markdown_alt);
}

fn isDesktopFileAtom(conn: *const XConn, atom: u32) bool {
    return atom != 0 and (atom == conn.mime_gnome_copied or atom == conn.mime_moz_url or atom == conn.mime_moz_file or
        atom == conn.mime_kde_urilist or atom == conn.mime_kde5_urilist or atom == conn.mime_kde_suggestedfilename or
        atom == conn.mime_nautilus or atom == conn.mime_moz_url_priv);
}

fn preferredTextAtom(conn: *const XConn, atoms: []const u8) ?u32 {
    var best: u32 = 0;
    var best_rank: u8 = 0;
    var off: usize = 0;
    while (off + 4 <= atoms.len) : (off += 4) {
        const atom = get32(atoms[off..][0..4]);
        const rank = textAtomRank(conn, atom);
        if (rank > best_rank) {
            best_rank = rank;
            best = atom;
        }
    }
    return if (best != 0) best else null;
}

fn isClipboardTextTarget(conn: *const XConn, target: u32) bool {
    if (target == 0) return false;
    return target == conn.utf8_string or target == atom_string or target == conn.text or
        target == conn.mime_text_plain or target == conn.mime_text_utf8 or
        target == conn.mime_text_utf8_alt or isUriListAtom(conn, target) or
        target == conn.utf16_string or isHtmlAtom(conn, target) or isRtfAtom(conn, target) or
        isDesktopFileAtom(conn, target) or target == conn.compound_text or
        isLatin1Atom(conn, target) or isLatin9Atom(conn, target) or
        isLatin2Atom(conn, target) or isLatin5Atom(conn, target) or
        isCyrillicAtom(conn, target) or isGreekAtom(conn, target) or
        isLatin3Atom(conn, target) or isLatin4Atom(conn, target) or
        isArabicAtom(conn, target) or isHebrewAtom(conn, target) or
        isCp1252Atom(conn, target) or isMarkdownAtom(conn, target);
}

fn setSelectionOwner(conn: *XConn, window: u32, selection: u32, time: u32) !void {
    var req: [16]u8 = @splat(0);
    req[0] = 22;
    put16(req[2..4], 4);
    put32(req[4..8], window);
    put32(req[8..12], selection);
    put32(req[12..16], time);
    try writeAll(conn, &req);
}

fn getSelectionOwner(conn: *XConn, selection: u32) !u32 {
    return getSelectionOwnerMaybeStashing(undefined, conn, selection, null);
}

fn getSelectionOwnerStashing(gpa: std.mem.Allocator, conn: *XConn, selection: u32, stash: *std.ArrayList([32]u8)) !u32 {
    return getSelectionOwnerMaybeStashing(gpa, conn, selection, stash);
}

fn getSelectionOwnerMaybeStashing(gpa: std.mem.Allocator, conn: *XConn, selection: u32, stash: ?*std.ArrayList([32]u8)) !u32 {
    var req: [8]u8 = @splat(0);
    req[0] = 23;
    put16(req[2..4], 2);
    put32(req[4..8], selection);
    try writeAll(conn, &req);
    const reply = try readReplyMaybeStashing(gpa, conn, stash);
    return get32(reply[8..12]);
}

fn setInputFocus(conn: *XConn, window: u32, time: u32) !void {
    var req: [12]u8 = @splat(0);
    req[0] = 42;
    req[1] = 1; // revert to PointerRoot
    put16(req[2..4], 3);
    put32(req[4..8], window);
    put32(req[8..12], time);
    try writeAll(conn, &req);
}

fn convertSelection(conn: *XConn, requestor: u32, selection: u32, target: u32, property: u32, time: u32) !void {
    var req: [24]u8 = @splat(0);
    req[0] = 24;
    put16(req[2..4], 6);
    put32(req[4..8], requestor);
    put32(req[8..12], selection);
    put32(req[12..16], target);
    put32(req[16..20], property);
    put32(req[20..24], if (time != 0) time else 1);
    try writeAll(conn, &req);
}

fn convertSelectionTime(last_user_time: u32, selection_time: u32) u32 {
    if (selection_time != 0) return selection_time;
    if (last_user_time != 0) return last_user_time;
    return 1;
}

fn sendSelectionNotify(conn: *XConn, requestor: u32, time: u32, selection: u32, target: u32, property: u32) !void {
    var req: [44]u8 = @splat(0);
    req[0] = 25;
    put16(req[2..4], 11);
    put32(req[4..8], requestor);
    req[12] = 31;
    put32(req[16..20], time);
    put32(req[20..24], requestor);
    put32(req[24..28], selection);
    put32(req[28..32], target);
    put32(req[32..36], property);
    try writeAll(conn, &req);
}

fn scaleNearest(dst: []u32, src: []const u32, w: u32, h: u32, scale: u32) void {
    const pixel_w = w * scale;
    var y: u32 = 0;
    while (y < h) : (y += 1) {
        var scale_y: u32 = 0;
        while (scale_y < scale) : (scale_y += 1) {
            var x: u32 = 0;
            while (x < w) : (x += 1) {
                const pixel = src[@as(usize, y) * w + x];
                var scale_x: u32 = 0;
                while (scale_x < scale) : (scale_x += 1) {
                    dst[@as(usize, y * scale + scale_y) * pixel_w + x * scale + scale_x] = pixel;
                }
            }
        }
    }
}

fn physicalToLogical(value: u32, scale: u32) u32 {
    const denom = @max(scale, 1);
    return @max(1, (value + denom / 2) / denom);
}

fn physicalPointToLogical(value: i32, scale: u32) i32 {
    return @divTrunc(value, @as(i32, @intCast(@max(scale, 1))));
}

pub fn pad4(n: usize) usize {
    return (n + 3) & ~@as(usize, 3);
}

pub fn putImageUnits(byte_len: usize) usize {
    return request_put_image_header_units + pad4(byte_len) / 4;
}

fn get16(bytes: []const u8) u16 {
    return std.mem.readInt(u16, bytes[0..2], .little);
}

fn get32(bytes: []const u8) u32 {
    return std.mem.readInt(u32, bytes[0..4], .little);
}

fn put16(bytes: []u8, value: u16) void {
    std.mem.writeInt(u16, bytes[0..2], value, .little);
}

fn put32(bytes: []u8, value: u32) void {
    std.mem.writeInt(u32, bytes[0..4], value, .little);
}

// --- Tests --------------------------------------------------------------------

test "x11 request padding and PutImage length math" {
    try std.testing.expectEqual(@as(usize, 0), pad4(0));
    try std.testing.expectEqual(@as(usize, 4), pad4(1));
    try std.testing.expectEqual(@as(usize, 4), pad4(4));
    try std.testing.expectEqual(@as(usize, 8), pad4(5));
    try std.testing.expectEqual(@as(usize, 7), putImageUnits(1));
    try std.testing.expectEqual(@as(usize, 8), putImageUnits(8));
}

test "x11 BGRX encoder ignores alpha and uses little-endian XImage order" {
    var out: [8]u8 = undefined;
    encodeBgrx(&out, &[_]u32{ 0xff112233, 0x80445566 }, 2, 1);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x33, 0x22, 0x11, 0, 0x66, 0x55, 0x44, 0 }, &out);
}

test "x11 DISPLAY parser accepts screen suffix" {
    try std.testing.expectEqual(@as(u16, 0), (try parseDisplay(":0")).number);
    try std.testing.expect((try parseDisplay(":0")).local);
    try std.testing.expectEqualStrings("", (try parseDisplay(":0")).host);
    try std.testing.expectEqual(@as(u16, 12), (try parseDisplay("localhost:12.1")).number);
    try std.testing.expectEqualStrings("localhost", (try parseDisplay("localhost:12.1")).host);
    try std.testing.expect(!(try parseDisplay("localhost:12.1")).local);
    try std.testing.expect(!(try parseDisplay("127.0.0.1:0")).local);
    try std.testing.expect((try parseDisplay("unix:0")).local);
    try std.testing.expect(!(try parseDisplay("remote.example:1")).local);
    try std.testing.expectEqualStrings("::1", (try parseDisplay("[::1]:10")).host);
    try std.testing.expectError(error.InvalidDisplay, parseDisplay("localhost"));
}

test "x11 Xauthority matcher prefers local MIT-MAGIC-COOKIE-1" {
    var file: [64]u8 = @splat(0);
    var off: usize = 0;
    std.mem.writeInt(u16, file[off..][0..2], family_local, .big);
    off += 2;
    std.mem.writeInt(u16, file[off..][0..2], 4, .big);
    off += 2;
    @memcpy(file[off .. off + 4], "host");
    off += 4;
    std.mem.writeInt(u16, file[off..][0..2], 1, .big);
    off += 2;
    file[off] = '0';
    off += 1;
    std.mem.writeInt(u16, file[off..][0..2], 18, .big);
    off += 2;
    @memcpy(file[off .. off + 18], "MIT-MAGIC-COOKIE-1");
    off += 18;
    std.mem.writeInt(u16, file[off..][0..2], 2, .big);
    off += 2;
    file[off] = 0xaa;
    file[off + 1] = 0xbb;
    off += 2;
    const record = (try selectXauth(file[0..off], "host", "0", true)).?;
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xaa, 0xbb }, record.data);
    try std.testing.expect((try selectXauth(file[0..off], "other", "0", true)) == null);
}

test "x11 HiDPI helpers convert physical pixels and nearest-neighbor scale" {
    try std.testing.expectEqual(@as(u32, 480), physicalToLogical(960, 2));
    try std.testing.expectEqual(@as(i32, 10), physicalPointToLogical(21, 2));
    var out: [8]u32 = undefined;
    scaleNearest(&out, &[_]u32{ 0xff112233, 0xff445566 }, 2, 1, 2);
    try std.testing.expectEqual(@as(u32, 0xff112233), out[0]);
    try std.testing.expectEqual(@as(u32, 0xff112233), out[1]);
    try std.testing.expectEqual(@as(u32, 0xff445566), out[2]);
    try std.testing.expectEqual(@as(u32, 0xff445566), out[3]);
}

test "x11 setup hello encodes MIT-MAGIC-COOKIE-1 lengths" {
    var hello: [12 + 20 + 16]u8 = undefined;
    const auth = Auth{ .name = "MIT-MAGIC-COOKIE-1", .data = "0123456789abcdef" };
    const name_pad = pad4(auth.name.len);
    const total = 12 + name_pad + pad4(auth.data.len);
    @memset(hello[0..total], 0);
    hello[0] = 'l';
    put16(hello[2..4], 11);
    put16(hello[6..8], @intCast(auth.name.len));
    put16(hello[8..10], @intCast(auth.data.len));
    @memcpy(hello[12 .. 12 + auth.name.len], auth.name);
    @memcpy(hello[12 + name_pad .. 12 + name_pad + auth.data.len], auth.data);
    try std.testing.expectEqual(@as(u16, 18), get16(hello[6..8]));
    try std.testing.expectEqual(@as(u16, 16), get16(hello[8..10]));
    try std.testing.expectEqual(@as(usize, 48), total);
}

test "x11 Window rejects an invalid size before contacting the server" {
    try std.testing.expectError(error.InvalidWindowSize, Window.open(std.testing.allocator, 0, 480, "x"));
    try std.testing.expectError(
        error.InvalidWindowSize,
        Window.openWithDisplay(std.testing.allocator, 0, 480, "x", ":0"),
    );
}

test "x11 setup parser reads spec offsets (vendor@16, screens@20, keycodes@26)" {
    // Synthetic setup body: vendor "Test" (4), one format, one screen.
    var body: [32 + 4 + 8 + 40]u8 = @splat(0);
    put32(body[4..8], 0x00400000); // resource base
    put32(body[8..12], 0x000fffff); // resource mask
    put16(body[16..18], 4); // vendor length
    put16(body[18..20], 0xffff); // max request
    body[20] = 1; // screens
    body[21] = 1; // formats
    body[26] = 8; // min keycode
    body[27] = 255; // max keycode
    @memcpy(body[32..36], "Test");
    const s = 32 + 4 + 8; // screen offset
    put32(body[s + 0 .. s + 4], 99); // root window
    put32(body[s + 8 .. s + 12], 0xffffff); // white
    put32(body[s + 12 .. s + 16], 0); // black
    put32(body[s + 32 .. s + 36], 0x21); // root visual
    body[s + 38] = 24; // root depth
    put16(body[s + 20 .. s + 22], 3840);
    put16(body[s + 24 .. s + 26], 600);

    const setup = try parseSetup(&body);
    try std.testing.expectEqual(@as(u32, 99), setup.screen.root);
    try std.testing.expectEqual(@as(u32, 0x21), setup.screen.root_visual);
    try std.testing.expectEqual(@as(u8, 24), setup.screen.root_depth);
    try std.testing.expectEqual(@as(u16, 0xffff), setup.max_request_units);
    try std.testing.expectEqual(@as(u8, 8), setup.min_keycode);
    try std.testing.expectEqual(@as(u8, 255), setup.max_keycode);
    try std.testing.expectEqual(@as(u32, 0xffffff), setup.screen.white_pixel);
    try std.testing.expectEqual(@as(u16, 3840), setup.screen.width_px);
    try std.testing.expectEqual(@as(u16, 600), setup.screen.width_mm);
}

test "ICCCM WM_STATE treats only NormalState as visible" {
    try std.testing.expect(!wmStateIsHidden(1));
    try std.testing.expect(wmStateIsHidden(0));
    try std.testing.expect(wmStateIsHidden(3));
    try std.testing.expect(!combinedWmHidden(false, false, false, false));
    try std.testing.expect(combinedWmHidden(false, true, false, false));
    try std.testing.expect(combinedWmHidden(false, false, true, false));
    try std.testing.expect(combinedWmHidden(false, false, false, true));
    try std.testing.expect(combinedWmHidden(true, false, false, false));
}

test "clipboard text targets include ICCCM and GTK MIME atoms" {
    const conn = XConn{
        .io = undefined,
        .stream = undefined,
        .next_id = 0,
        .resource_mask = 0,
        .screen = undefined,
        .max_request_units = 0,
        .min_keycode = 0,
        .max_keycode = 0,
        .utf8_string = 100,
        .text = 101,
        .mime_text_plain = 102,
        .mime_text_utf8 = 103,
        .timestamp = 104,
        .mime_text_utf8_alt = 105,
        .mime_uri_list = 106,
        .utf16_string = 107,
        .mime_text_html = 108,
        .mime_text_html_utf8 = 109,
        .mime_text_html_utf8_alt = 110,
        .mime_gnome_copied = 111,
        .mime_moz_url = 112,
        .mime_moz_file = 113,
        .mime_kde_urilist = 114,
        .mime_nautilus = 115,
        .mime_uri_list_alt = 116,
        .mime_rtf = 117,
        .mime_rtf_app = 118,
        .compound_text = 119,
        .mime_kde5_urilist = 120,
        .mime_kde_suggestedfilename = 136,
        .mime_moz_url_priv = 121,
        .mime_text_latin1 = 122,
        .mime_text_latin1_alt = 123,
        .mime_text_latin9 = 124,
        .mime_text_latin9_alt = 128,
        .mime_text_latin2 = 127,
        .mime_text_latin2_alt = 129,
        .mime_text_latin5 = 130,
        .mime_text_latin5_alt = 131,
        .mime_text_cyrillic = 132,
        .mime_text_cyrillic_alt = 133,
        .mime_text_greek = 134,
        .mime_text_greek_alt = 135,
        .mime_text_latin3 = 137,
        .mime_text_latin3_alt = 138,
        .mime_text_latin4 = 139,
        .mime_text_latin4_alt = 140,
        .mime_text_arabic = 141,
        .mime_text_arabic_alt = 142,
        .mime_text_hebrew = 143,
        .mime_text_hebrew_alt = 144,
        .mime_text_cp1252 = 145,
        .mime_text_cp1252_alt = 146,
        .mime_text_markdown = 125,
        .mime_text_markdown_alt = 126,
    };
    try std.testing.expect(isClipboardTextTarget(&conn, 100));
    try std.testing.expect(isClipboardTextTarget(&conn, atom_string));
    try std.testing.expect(isClipboardTextTarget(&conn, 103));
    try std.testing.expect(isClipboardTextTarget(&conn, 105));
    try std.testing.expect(isClipboardTextTarget(&conn, 106));
    try std.testing.expect(isClipboardTextTarget(&conn, 107));
    try std.testing.expect(isClipboardTextTarget(&conn, 108));
    try std.testing.expect(isClipboardTextTarget(&conn, 109));
    try std.testing.expect(isClipboardTextTarget(&conn, 110));
    try std.testing.expect(isClipboardTextTarget(&conn, 111));
    try std.testing.expect(isClipboardTextTarget(&conn, 112));
    try std.testing.expect(isClipboardTextTarget(&conn, 113));
    try std.testing.expect(isClipboardTextTarget(&conn, 114));
    try std.testing.expect(isClipboardTextTarget(&conn, 115));
    try std.testing.expect(isClipboardTextTarget(&conn, 116));
    try std.testing.expect(isClipboardTextTarget(&conn, 117));
    try std.testing.expect(isClipboardTextTarget(&conn, 118));
    try std.testing.expect(isClipboardTextTarget(&conn, 119));
    try std.testing.expect(isClipboardTextTarget(&conn, 120));
    try std.testing.expect(isClipboardTextTarget(&conn, 121));
    try std.testing.expect(isClipboardTextTarget(&conn, 122));
    try std.testing.expect(isClipboardTextTarget(&conn, 124));
    try std.testing.expect(isClipboardTextTarget(&conn, 125));
    try std.testing.expect(isClipboardTextTarget(&conn, 126));
    try std.testing.expect(isClipboardTextTarget(&conn, 127));
    try std.testing.expect(isClipboardTextTarget(&conn, 128));
    try std.testing.expect(isClipboardTextTarget(&conn, 129));
    try std.testing.expectEqual(@as(u8, 3), textAtomRank(&conn, 122));
    try std.testing.expectEqual(@as(u8, 3), textAtomRank(&conn, 124));
    try std.testing.expectEqual(@as(u8, 3), textAtomRank(&conn, 127));
    try std.testing.expectEqual(@as(u8, 3), textAtomRank(&conn, 128));
    try std.testing.expectEqual(@as(u8, 1), textAtomRank(&conn, 125));
    try std.testing.expect(!isClipboardTextTarget(&conn, 104));

    var atoms: [12]u8 = undefined;
    put32(atoms[0..4], atom_string);
    put32(atoms[4..8], 100);
    put32(atoms[8..12], 107);
    try std.testing.expectEqual(@as(u32, 100), preferredTextAtom(&conn, &atoms).?);

    var desktop: [8]u8 = undefined;
    put32(desktop[0..4], atom_string);
    put32(desktop[4..8], 111);
    try std.testing.expectEqual(@as(u32, 111), preferredTextAtom(&conn, &desktop).?);
    try std.testing.expectEqual(@as(u8, 3), textAtomRank(&conn, 111));
    try std.testing.expectEqual(@as(u8, 3), textAtomRank(&conn, 116));
    try std.testing.expectEqual(@as(u8, 1), textAtomRank(&conn, 117));
    try std.testing.expectEqual(@as(u8, 1), textAtomRank(&conn, 118));
    try std.testing.expectEqual(@as(u8, 2), textAtomRank(&conn, 119));
    try std.testing.expectEqual(@as(u8, 3), textAtomRank(&conn, 120));
    try std.testing.expect(isDesktopFileAtom(&conn, 121));
    try std.testing.expect(isUriListAtom(&conn, 106));
    try std.testing.expect(isUriListAtom(&conn, 116));
    try std.testing.expect(isRtfAtom(&conn, 117));
    try std.testing.expect(isLatin1Atom(&conn, 122));
    try std.testing.expect(isLatin9Atom(&conn, 124));
    try std.testing.expect(isLatin9Atom(&conn, 128));
    try std.testing.expect(isLatin2Atom(&conn, 127));
    try std.testing.expect(isLatin2Atom(&conn, 129));
    try std.testing.expect(isLatin5Atom(&conn, 130));
    try std.testing.expect(isLatin5Atom(&conn, 131));
    try std.testing.expect(isCyrillicAtom(&conn, 132));
    try std.testing.expect(isCyrillicAtom(&conn, 133));
    try std.testing.expect(isGreekAtom(&conn, 134));
    try std.testing.expect(isGreekAtom(&conn, 135));
    try std.testing.expect(isDesktopFileAtom(&conn, 136));
    try std.testing.expect(isClipboardTextTarget(&conn, 130));
    try std.testing.expect(isClipboardTextTarget(&conn, 132));
    try std.testing.expect(isClipboardTextTarget(&conn, 134));
    try std.testing.expect(isClipboardTextTarget(&conn, 136));
    try std.testing.expectEqual(@as(u8, 3), textAtomRank(&conn, 130));
    try std.testing.expectEqual(@as(u8, 3), textAtomRank(&conn, 132));
    try std.testing.expectEqual(@as(u8, 3), textAtomRank(&conn, 134));
    try std.testing.expectEqual(@as(u8, 3), textAtomRank(&conn, 136));
    try std.testing.expect(isLatin3Atom(&conn, 137));
    try std.testing.expect(isLatin4Atom(&conn, 139));
    try std.testing.expect(isArabicAtom(&conn, 141));
    try std.testing.expect(isHebrewAtom(&conn, 143));
    try std.testing.expect(isCp1252Atom(&conn, 145));
    try std.testing.expect(isClipboardTextTarget(&conn, 137));
    try std.testing.expect(isClipboardTextTarget(&conn, 145));
    try std.testing.expectEqual(@as(u8, 3), textAtomRank(&conn, 137));
    try std.testing.expectEqual(@as(u8, 3), textAtomRank(&conn, 145));
    try std.testing.expect(isMarkdownAtom(&conn, 125));
    try std.testing.expect(x11NotifyModeIsGrab(notify_mode_grab));
    try std.testing.expect(x11NotifyModeIsGrab(notify_mode_ungrab));
    try std.testing.expect(!x11NotifyModeIsGrab(0));
    try std.testing.expect(x11FocusDetailIsPointer(notify_detail_pointer));
    try std.testing.expect(!x11FocusDetailIsPointer(0));
    try std.testing.expectEqual(@as(u32, 1 << 5), event_leave_window);
    const xdnd = xdndRootPoint((@as(u32, 120) << 16) | 80);
    try std.testing.expectEqual(@as(i32, 120), xdnd.x);
    try std.testing.expectEqual(@as(i32, 80), xdnd.y);
}

fn xdndRootPoint(packed_xy: u32) struct { x: i32, y: i32 } {
    return .{
        .x = @as(i16, @bitCast(@as(u16, @truncate(packed_xy >> 16)))),
        .y = @as(i16, @bitCast(@as(u16, @truncate(packed_xy)))),
    };
}

test "x11 dead keysyms stay non-character until the composer combines them" {
    try std.testing.expectEqual(Key.other, keysymToKey(0xfe51));
    try std.testing.expectEqual(xkb.Dead.acute, xkb.deadForX11(0xfe51).?);
    try std.testing.expectEqual(xkb.x11_multi_key, @as(u32, 0xff20));
    try std.testing.expectEqualStrings("dead_acute", xkb.keysymNameForX11(0xfe51).?);
    try std.testing.expectEqualStrings("Multi_key", xkb.keysymNameForX11(xkb.x11_multi_key).?);
}

test "keysymToKey maps printable ASCII and editing keys" {
    try std.testing.expectEqual(Key{ .char = 'a' }, keysymToKey('a'));
    try std.testing.expectEqual(Key{ .char = ' ' }, keysymToKey(' '));
    try std.testing.expectEqual(Key{ .char = '~' }, keysymToKey('~'));
    try std.testing.expectEqual(Key.backspace, keysymToKey(0xff08));
    try std.testing.expectEqual(Key.enter, keysymToKey(0xff0d));
    try std.testing.expectEqual(Key.enter, keysymToKey(0xff8d));
    try std.testing.expectEqual(Key.escape, keysymToKey(0xff1b));
    try std.testing.expectEqual(Key.page_up, keysymToKey(0xff55));
    try std.testing.expectEqual(Key{ .char = '5' }, keysymToKey(0xffb5));
    try std.testing.expectEqual(Key{ .char = '*' }, keysymToKey(0xffaa));
    try std.testing.expectEqual(Key.left, keysymToKey(0xff96));
    try std.testing.expectEqual(Key.other, keysymToKey(0xffe1)); // Shift_L
    try std.testing.expectEqual(Key{ .char = 0x0456 }, keysymToKey(0x06a6));
    try std.testing.expectEqual(Key{ .char = 0x0406 }, keysymToKey(0x06b6));
}

test "Keymap.translate: shift columns and alpha case rules" {
    // Two keycodes starting at min=8, 2 keysyms per keycode:
    //   keycode 8: 'a', NoSymbol  (alpha pair by case rule)
    //   keycode 9: '1', '!'       (explicit shifted column)
    var syms = [_]u32{ 'a', 0, '1', '!' };
    const km = Keymap{ .syms = &syms, .per = 2, .min = 8 };

    try std.testing.expectEqual(Key{ .char = 'a' }, km.translate(8, 0));
    try std.testing.expectEqual(Key{ .char = 'A' }, km.translate(8, 1)); // shift
    try std.testing.expectEqual(Key{ .char = 'A' }, km.translate(8, 2)); // capslock
    try std.testing.expectEqual(Key{ .char = '1' }, km.translate(9, 0));
    try std.testing.expectEqual(Key{ .char = '!' }, km.translate(9, 1));
    try std.testing.expectEqual(Key{ .char = '1' }, km.translate(9, 2)); // lock ≠ shift for digits
    try std.testing.expectEqual(Key.other, km.translate(7, 0)); // below min
}

test "Keymap.translate uses NumLock XOR Shift for keypad columns" {
    var syms = [_]u32{ 0xff95, 0xffb7 };
    const km = Keymap{ .syms = &syms, .per = 2, .min = 79 };
    try std.testing.expectEqual(Key.home, km.translate(79, 0));
    try std.testing.expectEqual(Key{ .char = '7' }, km.translate(79, xkb.x11_mod2_num_lock));
    try std.testing.expectEqual(Key.home, km.translate(79, xkb.x11_mod2_num_lock | 1));
    try std.testing.expectEqual(Key{ .char = '7' }, km.translate(79, 1));
}

test "Keymap.translate uses Mod3 Mode_switch as group 2" {
    var syms = [_]u32{ 'a', 'A', 0x06c6, 0x06e6 };
    const km = Keymap{ .syms = &syms, .per = 4, .min = 38 };
    try std.testing.expectEqual(Key{ .char = 'a' }, km.translate(38, 0));
    try std.testing.expectEqual(Key{ .char = 0x0444 }, km.translate(38, xkb.x11_mod3_mode_switch));
    try std.testing.expectEqual(Key{ .char = 0x0424 }, km.translate(38, xkb.x11_mod3_mode_switch | 1));
}

test "Keymap.translate uses Mod5 for ISO Level3 when a third keysym exists" {
    var syms = [_]u32{ '2', '@', 0xb3, 0xa3 };
    const km = Keymap{ .syms = &syms, .per = 4, .min = 10 };
    try std.testing.expectEqual(Key{ .char = '2' }, km.translate(10, 0));
    try std.testing.expectEqual(Key{ .char = '@' }, km.translate(10, 1));
    try std.testing.expectEqual(Key{ .char = 0xb3 }, km.translate(10, 0x80));
    try std.testing.expectEqual(Key{ .char = 0xa3 }, km.translate(10, 0x81));
}

test "Keymap.translate uses group bits 13-14 without reading the next key" {
    var grouped = [_]u32{ 'a', 'A', 'z', 'Z' };
    const km = Keymap{ .syms = &grouped, .per = 4, .min = 10 };
    try std.testing.expectEqual(Key{ .char = 'a' }, km.translate(10, 0));
    try std.testing.expectEqual(Key{ .char = 'z' }, km.translate(10, 1 << 13));
    try std.testing.expectEqual(Key{ .char = 'Z' }, km.translate(10, (1 << 13) | 1));
    try std.testing.expectEqual(Key{ .char = 0x0444 }, keysymToKey(0x06c6));
    try std.testing.expectEqual(Key{ .char = 0x0424 }, keysymToKey(0x06e6));
    try std.testing.expectEqual(Key{ .char = 0x0142 }, keysymToKey(0x01b3));
    try std.testing.expectEqual(Key{ .char = 0x0151 }, keysymToKey(0x01f5));
    try std.testing.expectEqual(Key{ .char = 0x03b1 }, keysymToKey(0x07e1));
    try std.testing.expectEqual(Key{ .char = 0x03a9 }, keysymToKey(0x07d8));
    try std.testing.expectEqual(Key{ .char = 0x05d0 }, keysymToKey(0x0ce0));
    try std.testing.expectEqual(Key{ .char = 0x05ea }, keysymToKey(0x0cfa));
    try std.testing.expectEqual(Key{ .char = 0x0627 }, keysymToKey(0x05c7));
    try std.testing.expectEqual(Key{ .char = 0x064a }, keysymToKey(0x05ea));
    try std.testing.expectEqual(Key{ .char = 0x0153 }, keysymToKey(0x13bd));
    try std.testing.expectEqual(Key{ .char = 0x0178 }, keysymToKey(0x13be));
    try std.testing.expectEqual(Key{ .char = 0x0127 }, keysymToKey(0x02b1));
    try std.testing.expectEqual(Key{ .char = 0x0130 }, keysymToKey(0x02a9));
    try std.testing.expectEqual(Key{ .char = 0x0138 }, keysymToKey(0x03a2));
    try std.testing.expectEqual(Key{ .char = 0x0101 }, keysymToKey(0x03e0));
    try std.testing.expectEqual(Key{ .char = 0x0561 }, keysymToKey(0x14b3));
    try std.testing.expectEqual(Key{ .char = 0x10d0 }, keysymToKey(0x15d0));
    try std.testing.expectEqual(Key{ .char = 0x0e01 }, keysymToKey(0x0da1));
    try std.testing.expectEqual(Key{ .char = 0x0e59 }, keysymToKey(0x0df9));

    var pair = [_]u32{ 'a', 'A', 'b', 'B' };
    const km2 = Keymap{ .syms = &pair, .per = 2, .min = 8 };
    try std.testing.expectEqual(Key{ .char = 'a' }, km2.translate(8, 1 << 13));
    try std.testing.expectEqual(Key{ .char = 'b' }, km2.translate(9, 0));
}

test "RANDR ScreenChangeNotify size fields sit at spec offsets 24 and 28" {
    var event: [32]u8 = @splat(0);
    put16(event[24..26], 3840);
    put16(event[28..30], 600);
    const dims = randrScreenChangeSize(event);
    try std.testing.expectEqual(@as(u16, 3840), dims.width_px);
    try std.testing.expectEqual(@as(u16, 600), dims.width_mm);
}

test "VisibilityNotify fully-obscured state is 2" {
    try std.testing.expect(!visibilityIsFullyObscured(0));
    try std.testing.expect(!visibilityIsFullyObscured(1));
    try std.testing.expect(visibilityIsFullyObscured(2));
}

test "cached RANDR CRTC hit-test uses inclusive origin and exclusive max" {
    const left = RandrCrtc{ .x = 0, .y = 0, .width = 1920, .height = 1080, .width_mm = 340 };
    const right = RandrCrtc{ .x = 1920, .y = 0, .width = 2560, .height = 1440, .width_mm = 300 };
    const crtcs = [_]RandrCrtc{ left, right };
    try std.testing.expect(crtcContains(left, 10, 10));
    try std.testing.expect(!crtcContains(left, 1920, 10));
    try std.testing.expectEqual(@as(u32, 2560), crtcContaining(&crtcs, 2000, 20).?.width);
    try std.testing.expect(crtcContaining(&crtcs, -1, 0) == null);
}

test "ConvertSelection timestamp prefers the drop time then last user time" {
    try std.testing.expectEqual(@as(u32, 42), convertSelectionTime(7, 42));
    try std.testing.expectEqual(@as(u32, 7), convertSelectionTime(7, 0));
    try std.testing.expectEqual(@as(u32, 1), convertSelectionTime(0, 0));
}

test "MULTIPLE atom-pair payload is an even list of 32-bit atoms" {
    var pairs: [8]u8 = undefined;
    put32(pairs[0..4], 100);
    put32(pairs[4..8], 200);
    try std.testing.expectEqual(@as(usize, 0), pairs.len % 8);
    try std.testing.expectEqual(@as(u32, 100), get32(pairs[0..4]));
    try std.testing.expectEqual(@as(u32, 200), get32(pairs[4..8]));
}

test "GenericEvent extra length is 4 bytes per length unit" {
    var header: [32]u8 = @splat(0);
    header[0] = generic_event;
    put32(header[4..8], 3);
    try std.testing.expectEqual(@as(usize, 12), genericEventExtraBytes(header));
    header[0] = 12;
    try std.testing.expectEqual(@as(usize, 0), genericEventExtraBytes(header));
}

test "XI2 touch mask selects Begin/Update/End and FP1616 is signed 16.16" {
    try std.testing.expectEqual(@as(u8, (1 << 2) | (1 << 3) | (1 << 4)), xiTouchMaskByte());
    try std.testing.expectEqual(@as(i32, 12), fp1616ToI32(12 << 16));
    try std.testing.expectEqual(@as(i32, -3), fp1616ToI32(@bitCast(@as(i32, -3) * 65536)));
}
