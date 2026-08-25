//! Minimal native Wayland window backend, implemented directly on the wire.
//!
//! This module has no libwayland, libxkbcommon, C import, or XWayland
//! dependency. It binds the core globals and stable xdg-shell v1, presents the
//! shared software framebuffer through mmap-backed ARGB8888 `wl_buffer`s, and
//! translates keyboard events into the same public event shape as the X11
//! backend.
//!
//! Keyboard: the compositor-provided XKB keymap fd is received (see
//! `xkb.zig`'s bounded text-format parser) and drives translation for the
//! configured layout's base, Shift, AltGr/ISO Level3, and group-2 symbols
//! — non-US and dual-layout keymaps produce their real characters, not a
//! hardcoded US table. Client-side key repeat (Wayland deliberately leaves
//! this to the client, unlike X11's native auto-repeat) is implemented via
//! `repeat_info` + `Window.checkRepeat`. Keyboard leave resets compose.
//!
//! Dead-key and Multi_key sequences are composed client-side from the keymap
//! names (see `xkb.Compose`), including an optional bounded XCompose locale
//! table. Committed IME text is received through text-input-v3 when the
//! compositor advertises it; IME preedit suppresses the keyboard/compose
//! path. text-input-v3 also gets a multiline content hint and a bounded
//! cursor rectangle so IME candidate windows sit on the composer strip.
//! Fractional buffer scale uses `wp_fractional_scale_v1` +
//! `wp_viewporter` when advertised, otherwise `wl_surface.preferred_buffer_scale`
//! (compositor v6) or the entered `wl_output` integer scale; the fallback
//! shm cursor is refreshed when that scale changes. Keyboard enter restores
//! held Shift/Ctrl/Alt/Super from the keys array and Caps Lock from the
//! conventional Lock modifier bit when the compositor reports it. Clipboard uses
//! `wl_data_device` and `zwp_primary_selection_v1` when present, including
//! `text/plain;charset=utf8` and `text/uri-list`, with UTF-8 BOM strip /
//! UTF-16 decode (including `text/plain;charset=utf-16` / `UTF16_STRING`
//! on receive only), receive-only `text/html`, and receive-only desktop
//! file-list MIME (`x-special/gnome-copied-files`, `text/x-moz-url`,
//! `application/x-moz-file`). Middle-click pastes PRIMARY as typed keys
//! and falls back to `wl-paste --primary` when the native primary protocol
//! is missing. `present()` skips commits while the toplevel is suspended.
//! Text and `file:` drops arrive as typed keys (no new
//! Event variant) and `data_offer.set_actions(copy, copy)` is sent when
//! accepting a drop. A `wp_cursor_shape_v1` default pointer is used when
//! advertised, otherwise a scaled shm arrow. `xdg_toplevel_icon_v1` is set
//! when advertised. A supplied `XDG_ACTIVATION_TOKEN` is consumed through
//! `xdg_activation_v1` so a launcher-started window can take focus (not
//! used for notify/urgency). When a decoration manager is advertised, the client
//! requests server-side decorations (`zxdg` or `xdg`) and re-requests SSD
//! once if the compositor configures client-side mode. xdg-shell records
//! maximized/fullscreen/tiled/suspended configure states, records
//! `wm_capabilities` / `configure_bounds` when xdg-shell is v5+, and advertises
//! the same min/max size as the X11 WM hints. `present()` attaches a
//! `wl_surface.frame` callback and coalesces later commits until it fires.
//! High-resolution
//! `axis_value120` wheels snap to the same logical ticks as discrete axes.

const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;
const net = std.Io.net;
const xkb = @import("xkb.zig");
const shared_event = @import("event.zig");
const services = @import("services.zig");

const wl_display: u32 = 1;
const max_message_size: usize = 1024 * 1024;
const shm_argb8888: u32 = 0;
const seat_pointer: u32 = 1 << 0;
const seat_keyboard: u32 = 1 << 1;
const seat_touch: u32 = 1 << 2;

// Request opcodes from wayland.xml and stable/xdg-shell/xdg-shell.xml.
const display_sync: u16 = 0;
const display_get_registry: u16 = 1;
const registry_bind: u16 = 0;
const compositor_create_surface: u16 = 0;
const shm_create_pool: u16 = 0;
const shm_pool_create_buffer: u16 = 0;
const shm_pool_destroy: u16 = 1;
const buffer_destroy: u16 = 0;
const surface_destroy: u16 = 0;
const surface_attach: u16 = 1;
const surface_damage: u16 = 2;
const surface_frame: u16 = 3;
const surface_commit: u16 = 6;
const surface_set_buffer_scale: u16 = 8;
const surface_damage_buffer: u16 = 9;
const seat_get_pointer: u16 = 0;
const seat_get_keyboard: u16 = 1;
const seat_get_touch: u16 = 2;
const seat_release: u16 = 3;
const pointer_set_cursor: u16 = 0;
const cursor_shape_get_pointer: u16 = 1;
const cursor_shape_set_shape: u16 = 1;
const cursor_shape_default: u32 = 1;
const toplevel_icon_create_icon: u16 = 1;
const toplevel_icon_set_icon: u16 = 2;
const toplevel_icon_set_name: u16 = 1;
const toplevel_icon_add_buffer: u16 = 2;
const keyboard_release: u16 = 0;
const data_device_manager_create_data_source: u16 = 0;
const data_device_manager_get_data_device: u16 = 1;
const data_source_offer: u16 = 0;
const data_source_destroy: u16 = 1;
const data_device_set_selection: u16 = 1;
const data_device_release: u16 = 2;
const data_offer_receive: u16 = 1;
const data_offer_destroy: u16 = 2;
const viewporter_get_viewport: u16 = 1;
const viewport_destroy: u16 = 0;
const viewport_set_destination: u16 = 2;
const fractional_manager_get_fractional_scale: u16 = 1;
const primary_manager_create_source: u16 = 0;
const primary_manager_get_device: u16 = 1;
const primary_device_set_selection: u16 = 0;
const primary_device_destroy: u16 = 1;
const primary_source_offer: u16 = 0;
const primary_source_destroy: u16 = 1;
const primary_offer_receive: u16 = 0;
const primary_offer_destroy: u16 = 1;
const max_outputs: usize = 8;
const max_clipboard_bytes = 1024 * 1024;
const xdg_wm_base_destroy: u16 = 0;
const xdg_wm_base_get_xdg_surface: u16 = 2;
const xdg_wm_base_pong: u16 = 3;
const xdg_surface_destroy: u16 = 0;
const xdg_surface_get_toplevel: u16 = 1;
const xdg_surface_ack_configure: u16 = 4;
const xdg_toplevel_destroy: u16 = 0;
const xdg_toplevel_set_title: u16 = 2;
const xdg_toplevel_set_app_id: u16 = 3;
const xdg_activation_activate: u16 = 2;
const xdg_toplevel_set_max_size: u16 = 7;
const xdg_toplevel_set_min_size: u16 = 8;
const xdg_min_width: u32 = 160;
const xdg_min_height: u32 = 120;
const xdg_max_width: u32 = 8192;
const xdg_max_height: u32 = 8192;
const xdg_state_maximized: u32 = 1;
const xdg_state_fullscreen: u32 = 2;
const xdg_state_activated: u32 = 4;
const xdg_state_tiled_left: u32 = 5;
const xdg_state_tiled_right: u32 = 6;
const xdg_state_tiled_top: u32 = 7;
const xdg_state_tiled_bottom: u32 = 8;
const xdg_state_suspended: u32 = 9;
const xdg_wm_cap_window_menu: u32 = 1;
const xdg_wm_cap_maximize: u32 = 2;
const xdg_wm_cap_fullscreen: u32 = 3;
const xdg_wm_cap_minimize: u32 = 4;
const xkb_mod_lock: u32 = 1 << 1;
const data_offer_accept: u16 = 0;
const data_offer_finish: u16 = 3;
const data_offer_set_actions: u16 = 4;
const dnd_action_copy: u32 = 1;
const decoration_get_toplevel: u16 = 1;
const decoration_set_mode: u16 = 1;
const decoration_mode_client_side: u32 = 1;
const decoration_mode_server_side: u32 = 2;
const text_input_destroy: u16 = 0;
const text_input_enable: u16 = 1;
const text_input_disable: u16 = 2;
const text_input_set_content_type: u16 = 5;
const text_input_set_cursor_rectangle: u16 = 6;
const text_input_commit: u16 = 7;
const text_input_hint_multiline: u32 = 0x400;
const ime_cursor_height: i32 = 24;
const ime_cursor_margin: i32 = 8;

const text_mime_types = [_][]const u8{
    "text/plain;charset=utf-8",
    "text/plain;charset=utf8",
    "text/plain",
    "text/uri-list",
    "TEXT",
    "STRING",
    "UTF8_STRING",
};

/// Accepted on paste/drop only. Not advertised by `offerTextMimes` because
/// the source payload is UTF-8.
const utf16_mime_types = [_][]const u8{
    "text/plain;charset=utf-16",
    "UTF16_STRING",
};

/// Accepted on paste/drop only. Not advertised by `offerTextMimes`.
const html_mime_types = [_][]const u8{
    "text/html",
    "text/html;charset=utf-8",
    "text/html;charset=utf8",
};

/// Accepted on paste/drop only. Not advertised by `offerTextMimes`.
const desktop_file_mime_types = [_][]const u8{
    "x-special/gnome-copied-files",
    "text/x-moz-url",
    "application/x-moz-file",
};

pub const Key = shared_event.Key;
pub const Event = shared_event.Event;

const Global = struct {
    name: u32 = 0,
    version: u32 = 0,
};

const Globals = struct {
    compositor: Global = .{},
    shm: Global = .{},
    seat: Global = .{},
    xdg_wm_base: Global = .{},
    outputs: [max_outputs]Global = @splat(.{}),
    output_count: u8 = 0,
    text_input_manager: Global = .{},
    data_device_manager: Global = .{},
    viewporter: Global = .{},
    fractional_manager: Global = .{},
    primary_manager: Global = .{},
    cursor_shape_manager: Global = .{},
    toplevel_icon_manager: Global = .{},
    decoration_manager: Global = .{},
    decoration_zxdg: bool = true,
    activation: Global = .{},

    fn record(self: *Globals, name: u32, interface: []const u8, version: u32) void {
        const value = Global{ .name = name, .version = version };
        if (std.mem.eql(u8, interface, "wl_compositor") and self.compositor.name == 0) {
            self.compositor = value;
        } else if (std.mem.eql(u8, interface, "wl_shm") and self.shm.name == 0) {
            self.shm = value;
        } else if (std.mem.eql(u8, interface, "wl_seat") and self.seat.name == 0) {
            self.seat = value;
        } else if (std.mem.eql(u8, interface, "xdg_wm_base") and self.xdg_wm_base.name == 0) {
            self.xdg_wm_base = value;
        } else if (std.mem.eql(u8, interface, "wl_output") and self.output_count < max_outputs) {
            self.outputs[self.output_count] = value;
            self.output_count += 1;
        } else if (std.mem.eql(u8, interface, "zwp_text_input_manager_v3") and self.text_input_manager.name == 0) {
            self.text_input_manager = value;
        } else if (std.mem.eql(u8, interface, "wl_data_device_manager") and self.data_device_manager.name == 0) {
            self.data_device_manager = value;
        } else if (std.mem.eql(u8, interface, "wp_viewporter") and self.viewporter.name == 0) {
            self.viewporter = value;
        } else if (std.mem.eql(u8, interface, "wp_fractional_scale_manager_v1") and self.fractional_manager.name == 0) {
            self.fractional_manager = value;
        } else if (std.mem.eql(u8, interface, "zwp_primary_selection_device_manager_v1") and self.primary_manager.name == 0) {
            self.primary_manager = value;
        } else if (std.mem.eql(u8, interface, "wp_cursor_shape_manager_v1") and self.cursor_shape_manager.name == 0) {
            self.cursor_shape_manager = value;
        } else if (std.mem.eql(u8, interface, "xdg_toplevel_icon_manager_v1") and self.toplevel_icon_manager.name == 0) {
            self.toplevel_icon_manager = value;
        } else if (std.mem.eql(u8, interface, "zxdg_decoration_manager_v1") and self.decoration_manager.name == 0) {
            self.decoration_manager = value;
            self.decoration_zxdg = true;
        } else if (std.mem.eql(u8, interface, "xdg_decoration_manager_v1") and self.decoration_manager.name == 0) {
            self.decoration_manager = value;
            self.decoration_zxdg = false;
        } else if (std.mem.eql(u8, interface, "xdg_activation_v1") and self.activation.name == 0) {
            self.activation = value;
        }
    }
};

const Message = struct {
    object: u32,
    opcode: u16,
    body: []u8,

    fn deinit(self: Message, gpa: std.mem.Allocator) void {
        gpa.free(self.body);
    }
};

const Connection = struct {
    io: std.Io,
    stream: net.Stream,
    next_id: u32 = 2,
    /// A file descriptor delivered by SCM_RIGHTS on the most recent read that
    /// has not yet been claimed by a specific event handler (e.g.
    /// wl_keyboard.keymap). Wayland attaches at most one fd per message this
    /// client parses, and the handler that expects one claims it via
    /// `takePendingFd` in the same dispatch turn that read it.
    pending_fd: ?posix.fd_t = null,

    fn allocId(self: *Connection) !u32 {
        if (self.next_id >= 0xff000000) return error.ObjectIdsExhausted;
        const id = self.next_id;
        self.next_id += 1;
        return id;
    }

    /// Returns and clears the fd captured by the most recent `readExact`, if
    /// any. Closes and discards a stale unclaimed fd from an earlier message
    /// before returning the new one, since this client only ever expects one
    /// fd in flight at a time.
    fn takePendingFd(self: *Connection) ?posix.fd_t {
        const fd_value = self.pending_fd;
        self.pending_fd = null;
        return fd_value;
    }

    fn writeAll(self: *Connection, bytes: []const u8) !void {
        var off: usize = 0;
        while (off < bytes.len) {
            const n = try self.io.vtable.netWrite(
                self.io.userdata,
                self.stream.socket.handle,
                "",
                &[_][]const u8{bytes[off..]},
                1,
            );
            if (n == 0) return error.WriteZero;
            off += n;
        }
    }

    /// Every message read goes through raw `recvmsg`, not the `Io` vtable, so
    /// an SCM_RIGHTS fd attached to any byte in this read (the compositor
    /// sends wl_keyboard.keymap's fd alongside its 16-byte wire message) is
    /// captured rather than silently dropped by a plain `read`/`recv`. This
    /// mirrors `writeWithFd`'s raw-syscall approach on the send side.
    fn readExact(self: *Connection, dst: []u8) !void {
        const header_space = comptime alignForward(@sizeOf(linux.cmsghdr), @alignOf(linux.cmsghdr));
        const control_space = comptime header_space + alignForward(@sizeOf(i32), @alignOf(linux.cmsghdr));

        var off: usize = 0;
        while (off < dst.len) {
            var control: [control_space]u8 align(@alignOf(linux.cmsghdr)) = @splat(0);
            var iov: posix.iovec = .{ .base = dst[off..].ptr, .len = dst.len - off };
            var msg: linux.msghdr = .{
                .name = null,
                .namelen = 0,
                .iov = (&iov)[0..1],
                .iovlen = 1,
                .control = &control,
                .controllen = control.len,
                .flags = 0,
            };

            const n: usize = while (true) {
                const rc = linux.recvmsg(self.stream.socket.handle, &msg, linux.MSG.CMSG_CLOEXEC);
                switch (linux.errno(rc)) {
                    .SUCCESS => break @intCast(rc),
                    .INTR => continue,
                    .AGAIN => return error.WouldBlock,
                    .CONNRESET, .NOTCONN => return error.ConnectionResetByPeer,
                    else => return error.ReadFailed,
                }
            };
            if (n == 0) return error.EndOfStream;
            off += n;

            if (msg.controllen >= header_space + @sizeOf(i32)) {
                const cmsg: *const linux.cmsghdr = @ptrCast(&control);
                if (cmsg.level == linux.SOL.SOCKET and cmsg.type == linux.SCM.RIGHTS) {
                    const received: i32 = @as(*const i32, @ptrCast(@alignCast(control[header_space..].ptr))).*;
                    if (self.pending_fd) |stale| _ = linux.close(stale);
                    self.pending_fd = received;
                }
            }
        }
    }

    fn readMessage(self: *Connection, gpa: std.mem.Allocator) !Message {
        var wire_header: [8]u8 = undefined;
        try self.readExact(&wire_header);
        const object = get32(wire_header[0..4]);
        const word = get32(wire_header[4..8]);
        const opcode: u16 = @intCast(word & 0xffff);
        const size: usize = @intCast(word >> 16);
        if (object == 0 or size < 8 or (size & 3) != 0 or size > max_message_size) {
            return error.InvalidWaylandMessage;
        }
        const body = try gpa.alloc(u8, size - 8);
        errdefer gpa.free(body);
        try self.readExact(body);
        return .{ .object = object, .opcode = opcode, .body = body };
    }

    /// Send a Wayland request whose signature contains one `fd` argument.
    /// File descriptors consume no bytes in the Wayland wire payload and are
    /// attached to the first byte with SCM_RIGHTS.
    fn writeWithFd(self: *Connection, bytes: []const u8, fd_value: i32) !void {
        const header_space = comptime alignForward(@sizeOf(linux.cmsghdr), @alignOf(linux.cmsghdr));
        const control_space = comptime header_space + alignForward(@sizeOf(i32), @alignOf(linux.cmsghdr));
        var control: [control_space]u8 align(@alignOf(linux.cmsghdr)) = @splat(0);

        const cmsg: *linux.cmsghdr = @ptrCast(&control);
        cmsg.* = .{
            .len = header_space + @sizeOf(i32),
            .level = linux.SOL.SOCKET,
            .type = linux.SCM.RIGHTS,
        };
        std.mem.writeInt(i32, control[header_space .. header_space + @sizeOf(i32)], fd_value, .native);

        var iov: posix.iovec_const = .{ .base = bytes.ptr, .len = bytes.len };
        const msg: linux.msghdr_const = .{
            .name = null,
            .namelen = 0,
            .iov = (&iov)[0..1],
            .iovlen = 1,
            .control = &control,
            .controllen = control.len,
            .flags = 0,
        };

        var sent: usize = 0;
        while (true) {
            const rc = linux.sendmsg(self.stream.socket.handle, &msg, linux.MSG.NOSIGNAL);
            switch (linux.errno(rc)) {
                .SUCCESS => {
                    sent = @intCast(rc);
                    break;
                },
                .INTR => continue,
                .AGAIN => return error.WouldBlock,
                .PIPE, .NOTCONN => return error.ConnectionResetByPeer,
                .NOBUFS, .NOMEM => return error.SystemResources,
                else => return error.SendFdFailed,
            }
        }
        if (sent == 0) return error.WriteZero;
        if (sent < bytes.len) try self.writeAll(bytes[sent..]);
    }
};

const PendingPresent = struct {
    buffer_id: u32,
    pixel_w: u32,
    pixel_h: u32,
    logical_w: u32,
    logical_h: u32,
    use_viewport: bool,
};

const Buffer = struct {
    id: u32,
    width: u32,
    height: u32,
    memory: []align(std.heap.page_size_min) u8,
    busy: bool = false,

    fn deinit(self: *Buffer) void {
        posix.munmap(self.memory);
        self.* = undefined;
    }
};

/// Open a native Wayland window, display an image, and wait for a key or close.
pub fn show(gpa: std.mem.Allocator, pixels: []const u32, w: u32, h: u32) !void {
    const window = try Window.open(gpa, w, h, "comicchat");
    defer window.deinit();
    try window.present(pixels, w, h);
    while (true) {
        switch (try window.nextEvent()) {
            .key, .close => return,
            .expose => try window.present(pixels, w, h),
            else => {},
        }
    }
}

/// A heap-pinned native Wayland xdg-toplevel.
pub const Window = struct {
    gpa: std.mem.Allocator,
    threaded: std.Io.Threaded,
    conn: Connection,

    registry_id: u32 = 0,
    compositor_id: u32 = 0,
    compositor_version: u32 = 0,
    shm_id: u32 = 0,
    seat_id: u32 = 0,
    seat_version: u32 = 0,
    keyboard_id: u32 = 0,
    pointer_id: u32 = 0,
    touch_id: u32 = 0,
    touch_contact: ?i32 = null,
    pointer_x: i32 = 0,
    pointer_y: i32 = 0,
    last_primary_click_ms: u32 = 0,
    last_primary_x: i32 = 0,
    last_primary_y: i32 = 0,
    surface_id: u32 = 0,
    xdg_wm_base_id: u32 = 0,
    xdg_surface_id: u32 = 0,
    xdg_toplevel_id: u32 = 0,
    output_ids: [max_outputs]u32 = @splat(0),
    output_scales: [max_outputs]u32 = @splat(1),
    output_width_px: [max_outputs]u32 = @splat(0),
    output_width_mm: [max_outputs]u32 = @splat(0),
    output_have_scale: [max_outputs]bool = @splat(false),
    output_count: u8 = 0,
    entered_outputs: [max_outputs]u32 = @splat(0),
    entered_count: u8 = 0,
    output_scale: u32 = 1,
    preferred_buffer_scale: u32 = 0,
    viewporter_id: u32 = 0,
    viewport_id: u32 = 0,
    fractional_manager_id: u32 = 0,
    fractional_scale_id: u32 = 0,
    fractional_scale_120: u32 = 0,
    primary_manager_id: u32 = 0,
    primary_device_id: u32 = 0,
    primary_source_id: u32 = 0,
    primary_offer_id: u32 = 0,
    pending_primary_offer_id: u32 = 0,
    primary_offer_has_text: bool = false,
    pending_primary_offer_has_text: bool = false,
    text_input_manager_id: u32 = 0,
    text_input_id: u32 = 0,
    data_device_manager_id: u32 = 0,
    data_device_id: u32 = 0,
    data_source_id: u32 = 0,
    data_offer_id: u32 = 0,
    pending_offer_id: u32 = 0,
    offer_has_text: bool = false,
    pending_offer_has_text: bool = false,
    pending_drop_mime: []const u8 = "",
    dnd_offer_id: u32 = 0,
    dnd_has_text: bool = false,
    dnd_mime: []const u8 = "",
    toplevel_maximized: bool = false,
    toplevel_fullscreen: bool = false,
    toplevel_tiled: bool = false,
    toplevel_suspended: bool = false,
    bounds_width: i32 = 0,
    bounds_height: i32 = 0,
    wm_can_window_menu: bool = false,
    wm_can_maximize: bool = false,
    wm_can_fullscreen: bool = false,
    wm_can_minimize: bool = false,
    caps_from_compositor: bool = false,
    cursor_shape_manager_id: u32 = 0,
    cursor_shape_device_id: u32 = 0,
    cursor_surface_id: u32 = 0,
    cursor_buffer: ?Buffer = null,
    cursor_hotspot_x: i32 = 1,
    cursor_hotspot_y: i32 = 1,
    toplevel_icon_manager_id: u32 = 0,
    toplevel_icon_id: u32 = 0,
    icon_buffer: ?Buffer = null,
    decoration_manager_id: u32 = 0,
    decoration_id: u32 = 0,
    decoration_mode: u32 = 0,
    decoration_retry: bool = false,
    activation_id: u32 = 0,
    startup_token: []const u8 = "",
    frame_callback_id: u32 = 0,
    pending_present: ?PendingPresent = null,
    last_serial: u32 = 0,
    middle_paste: bool = false,
    clipboard_text: []u8 = &.{},
    axis_have_discrete: bool = false,
    ime_composing: bool = false,
    last_committed: ?u21 = null,
    compose_table: ?xkb.ComposeTable = null,
    compose: xkb.Compose = .{},
    committed_text: std.ArrayList(u21) = .empty,
    committed_text_offset: usize = 0,

    width: u32,
    height: u32,
    pending_width: i32 = 0,
    pending_height: i32 = 0,
    configured: bool = false,
    argb_supported: bool = false,
    shift_left: bool = false,
    shift_right: bool = false,
    control_left: bool = false,
    control_right: bool = false,
    alt_left: bool = false,
    alt_right: bool = false,
    super_left: bool = false,
    super_right: bool = false,
    caps_lock: bool = false,
    /// The compositor's layout, once a keymap event with a supported format
    /// has been received and successfully parsed. Null before that (falls
    /// back to evdevToKey's hardcoded US table) and if the compositor sent
    /// an unsupported format or a keymap this bounded parser could not read.
    xkb_keymap: ?xkb.Keymap = null,
    xkb_group: u32 = 0,
    /// Repeats per second and initial hold delay from the compositor's
    /// repeat_info (wl_keyboard v4+); non-positive rate means repeat is
    /// disabled entirely, matching the Wayland protocol's own convention.
    repeat_rate_per_sec: i32 = 0,
    repeat_delay_ms: i32 = 0,
    /// The evdev code and effective shift state of the one non-modifier key
    /// currently held, so `checkRepeat` can keep synthesizing key events
    /// without a matching wire message for each one — Wayland deliberately
    /// leaves repeat entirely to the client (see the module doc).
    held_key_code: ?u32 = null,
    held_key_shift: bool = false,
    held_key_control: bool = false,
    next_repeat_at_ms: u64 = 0,
    buffers: std.ArrayList(Buffer) = .empty,

    pub fn open(gpa: std.mem.Allocator, w: u32, h: u32, title: []const u8) !*Window {
        if (w == 0 or h == 0 or w > std.math.maxInt(i32) or h > std.math.maxInt(i32)) {
            return error.InvalidWindowSize;
        }
        const socket_path = try waylandSocketPath(gpa);
        defer gpa.free(socket_path);

        const self = try gpa.create(Window);
        errdefer gpa.destroy(self);
        self.* = .{
            .gpa = gpa,
            .threaded = std.Io.Threaded.init(gpa, .{}),
            .conn = undefined,
            .width = w,
            .height = h,
        };
        errdefer self.threaded.deinit();
        {
            const env = try services.readEnviron(gpa);
            defer gpa.free(env);
            self.loadComposeFromEnv(env);
            if (services.startupToken(env)) |token| {
                self.startup_token = gpa.dupe(u8, token) catch "";
            }
        }
        errdefer self.unloadCompose();

        const io = self.threaded.io();
        const stream = try openUnixSocket(io, socket_path);
        errdefer stream.close(io);
        self.conn = .{ .io = io, .stream = stream };

        var globals: Globals = .{};
        try self.discoverGlobals(&globals);
        if (globals.compositor.name == 0) return error.MissingWaylandCompositor;
        if (globals.shm.name == 0) return error.MissingWaylandShm;
        if (globals.seat.name == 0) return error.MissingWaylandSeat;
        if (globals.xdg_wm_base.name == 0) return error.MissingXdgWmBase;

        self.compositor_id = try self.conn.allocId();
        self.compositor_version = @min(globals.compositor.version, 6);
        try sendBind(&self.conn, self.gpa, self.registry_id, globals.compositor, "wl_compositor", self.compositor_version, self.compositor_id);

        self.shm_id = try self.conn.allocId();
        try sendBind(&self.conn, self.gpa, self.registry_id, globals.shm, "wl_shm", 1, self.shm_id);

        self.seat_id = try self.conn.allocId();
        self.seat_version = @min(globals.seat.version, 8);
        try sendBind(&self.conn, self.gpa, self.registry_id, globals.seat, "wl_seat", self.seat_version, self.seat_id);

        self.xdg_wm_base_id = try self.conn.allocId();
        try sendBind(&self.conn, self.gpa, self.registry_id, globals.xdg_wm_base, "xdg_wm_base", @min(globals.xdg_wm_base.version, 6), self.xdg_wm_base_id);

        var output_i: u8 = 0;
        while (output_i < globals.output_count) : (output_i += 1) {
            const output_id = try self.conn.allocId();
            try sendBind(&self.conn, self.gpa, self.registry_id, globals.outputs[output_i], "wl_output", @min(globals.outputs[output_i].version, 2), output_id);
            self.output_ids[self.output_count] = output_id;
            self.output_scales[self.output_count] = 1;
            self.output_count += 1;
        }
        if (globals.data_device_manager.name != 0) {
            self.data_device_manager_id = try self.conn.allocId();
            try sendBind(&self.conn, self.gpa, self.registry_id, globals.data_device_manager, "wl_data_device_manager", @min(globals.data_device_manager.version, 3), self.data_device_manager_id);
            self.data_device_id = try self.conn.allocId();
            try sendTwoU32(&self.conn, self.data_device_manager_id, data_device_manager_get_data_device, self.data_device_id, self.seat_id);
        }
        if (globals.primary_manager.name != 0) {
            self.primary_manager_id = try self.conn.allocId();
            try sendBind(&self.conn, self.gpa, self.registry_id, globals.primary_manager, "zwp_primary_selection_device_manager_v1", 1, self.primary_manager_id);
            self.primary_device_id = try self.conn.allocId();
            try sendTwoU32(&self.conn, self.primary_manager_id, primary_manager_get_device, self.primary_device_id, self.seat_id);
        }
        if (globals.cursor_shape_manager.name != 0) {
            self.cursor_shape_manager_id = try self.conn.allocId();
            try sendBind(&self.conn, self.gpa, self.registry_id, globals.cursor_shape_manager, "wp_cursor_shape_manager_v1", 1, self.cursor_shape_manager_id);
        }
        if (globals.toplevel_icon_manager.name != 0) {
            self.toplevel_icon_manager_id = try self.conn.allocId();
            try sendBind(&self.conn, self.gpa, self.registry_id, globals.toplevel_icon_manager, "xdg_toplevel_icon_manager_v1", 1, self.toplevel_icon_manager_id);
        }
        if (globals.decoration_manager.name != 0) {
            self.decoration_manager_id = try self.conn.allocId();
            try sendBind(
                &self.conn,
                self.gpa,
                self.registry_id,
                globals.decoration_manager,
                if (globals.decoration_zxdg) "zxdg_decoration_manager_v1" else "xdg_decoration_manager_v1",
                1,
                self.decoration_manager_id,
            );
        }
        if (globals.activation.name != 0) {
            self.activation_id = try self.conn.allocId();
            try sendBind(&self.conn, self.gpa, self.registry_id, globals.activation, "xdg_activation_v1", 1, self.activation_id);
        }
        if (globals.text_input_manager.name != 0) {
            self.text_input_manager_id = try self.conn.allocId();
            try sendBind(&self.conn, self.gpa, self.registry_id, globals.text_input_manager, "zwp_text_input_manager_v3", 1, self.text_input_manager_id);
            self.text_input_id = try self.conn.allocId();
            try sendTwoU32(&self.conn, self.text_input_manager_id, 1, self.text_input_id, self.seat_id);
        }

        self.surface_id = try self.conn.allocId();
        try sendOneU32(&self.conn, self.compositor_id, compositor_create_surface, self.surface_id);
        if (globals.viewporter.name != 0 and globals.fractional_manager.name != 0) {
            self.viewporter_id = try self.conn.allocId();
            try sendBind(&self.conn, self.gpa, self.registry_id, globals.viewporter, "wp_viewporter", 1, self.viewporter_id);
            self.viewport_id = try self.conn.allocId();
            try sendTwoU32(&self.conn, self.viewporter_id, viewporter_get_viewport, self.viewport_id, self.surface_id);
            self.fractional_manager_id = try self.conn.allocId();
            try sendBind(&self.conn, self.gpa, self.registry_id, globals.fractional_manager, "wp_fractional_scale_manager_v1", 1, self.fractional_manager_id);
            self.fractional_scale_id = try self.conn.allocId();
            try sendTwoU32(&self.conn, self.fractional_manager_id, fractional_manager_get_fractional_scale, self.fractional_scale_id, self.surface_id);
        }
        self.xdg_surface_id = try self.conn.allocId();
        try sendTwoU32(&self.conn, self.xdg_wm_base_id, xdg_wm_base_get_xdg_surface, self.xdg_surface_id, self.surface_id);
        self.xdg_toplevel_id = try self.conn.allocId();
        try sendOneU32(&self.conn, self.xdg_surface_id, xdg_surface_get_toplevel, self.xdg_toplevel_id);
        try sendString(&self.conn, self.gpa, self.xdg_toplevel_id, xdg_toplevel_set_title, title);
        try sendString(&self.conn, self.gpa, self.xdg_toplevel_id, xdg_toplevel_set_app_id, "comicchat");
        try sendTwoU32(&self.conn, self.xdg_toplevel_id, xdg_toplevel_set_min_size, xdg_min_width, xdg_min_height);
        try sendTwoU32(&self.conn, self.xdg_toplevel_id, xdg_toplevel_set_max_size, xdg_max_width, xdg_max_height);
        if (self.decoration_manager_id != 0) {
            self.decoration_id = try self.conn.allocId();
            try sendTwoU32(&self.conn, self.decoration_manager_id, decoration_get_toplevel, self.decoration_id, self.xdg_toplevel_id);
            try sendOneU32(&self.conn, self.decoration_id, decoration_set_mode, decoration_mode_server_side);
        }

        // xdg-shell forbids attaching a buffer before this initial, empty
        // commit has elicited a configure which the client acknowledges.
        try sendEmpty(&self.conn, self.surface_id, surface_commit);
        while (!self.configured) {
            const msg = try self.conn.readMessage(self.gpa);
            defer msg.deinit(self.gpa);
            _ = try self.dispatch(msg);
        }
        if (!self.argb_supported) return error.Argb8888Unsupported;
        self.installToplevelIcon() catch {};
        self.activateStartupToken() catch {};
        return self;
    }

    pub fn writeClipboard(self: *Window, text: []const u8) !void {
        if (self.writeClipboardNative(text)) |_| return else |_| {
            return services.writeClipboard(self.conn.io, .wayland, text);
        }
    }

    pub fn readClipboard(self: *Window, gpa: std.mem.Allocator) !?[]u8 {
        if (self.readClipboardNative(gpa)) |text| {
            return text;
        } else |_| {
            return services.readClipboard(gpa, self.conn.io, .wayland);
        }
    }

    pub fn chooseFile(self: *Window, gpa: std.mem.Allocator, save: bool, title: []const u8) !?[]u8 {
        return services.chooseFile(gpa, self.conn.io, save, title);
    }

    pub fn openPath(self: *Window, gpa: std.mem.Allocator, path: []const u8) !void {
        return services.openPath(gpa, self.conn.io, path);
    }

    pub fn printPath(self: *Window, gpa: std.mem.Allocator, path: []const u8) !void {
        return services.printPath(gpa, self.conn.io, path);
    }

    pub fn notify(self: *Window, gpa: std.mem.Allocator, title: []const u8, body: []const u8) !void {
        return services.notify(gpa, self.conn.io, title, body);
    }

    pub fn deinit(self: *Window) void {
        self.destroyProtocolObjects() catch {};
        self.conn.stream.close(self.conn.io);
        if (self.xkb_keymap) |*keymap| keymap.deinit();
        if (self.clipboard_text.len != 0) self.gpa.free(self.clipboard_text);
        if (self.startup_token.len != 0) self.gpa.free(self.startup_token);
        for (self.buffers.items) |*buffer| buffer.deinit();
        self.buffers.deinit(self.gpa);
        if (self.cursor_buffer) |*buffer| buffer.deinit();
        if (self.icon_buffer) |*buffer| buffer.deinit();
        self.committed_text.deinit(self.gpa);
        self.threaded.deinit();
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

    /// Pollable Wayland connection socket.
    pub fn fd(self: *const Window) i32 {
        return self.conn.stream.socket.handle;
    }

    /// Commit a full 0xAARRGGBB frame through a reusable ARGB8888 wl_buffer.
    pub fn present(self: *Window, pixels: []const u32, w: u32, h: u32) !void {
        if (!self.configured) return error.SurfaceNotConfigured;
        if (self.toplevel_suspended) return;
        if (w == 0 or h == 0 or w > std.math.maxInt(i32) or h > std.math.maxInt(i32)) {
            return error.InvalidWindowSize;
        }
        const count = try std.math.mul(usize, @as(usize, w), @as(usize, h));
        if (pixels.len != count) return error.BadFramebufferSize;

        const dims = self.bufferDimensions(w, h);
        const pixel_w = dims.w;
        const pixel_h = dims.h;
        self.discardIdleBuffersExcept(pixel_w, pixel_h);
        var index: ?usize = null;
        for (self.buffers.items, 0..) |buffer, i| {
            if (!buffer.busy and buffer.width == pixel_w and buffer.height == pixel_h) {
                index = i;
                break;
            }
        }
        if (index == null) {
            try self.buffers.append(self.gpa, try self.createBuffer(pixel_w, pixel_h));
            index = self.buffers.items.len - 1;
        }
        const buffer = &self.buffers.items[index.?];
        const destination: []u32 = std.mem.bytesAsSlice(u32, buffer.memory);
        scaleNearestTo(destination, pixels, w, h, pixel_w, pixel_h);
        buffer.busy = true;

        const pending = PendingPresent{
            .buffer_id = buffer.id,
            .pixel_w = pixel_w,
            .pixel_h = pixel_h,
            .logical_w = w,
            .logical_h = h,
            .use_viewport = dims.use_viewport,
        };
        if (self.frame_callback_id != 0) {
            if (self.pending_present) |old| {
                if (old.buffer_id != pending.buffer_id) self.unbusyBuffer(old.buffer_id);
            }
            self.pending_present = pending;
            return;
        }
        try self.attachAndCommit(pending);
        self.requestFrame();
    }

    fn attachAndCommit(self: *Window, pending: PendingPresent) !void {
        if (self.compositor_version >= 3) {
            try sendOneU32(&self.conn, self.surface_id, surface_set_buffer_scale, if (pending.use_viewport) 1 else self.output_scale);
        }
        if (pending.use_viewport) {
            try sendTwoU32(
                &self.conn,
                self.viewport_id,
                viewport_set_destination,
                @bitCast(@as(i32, @intCast(pending.logical_w))),
                @bitCast(@as(i32, @intCast(pending.logical_h))),
            );
        }
        try sendAttach(&self.conn, self.surface_id, pending.buffer_id);
        if (self.compositor_version >= 4) {
            try sendDamage(&self.conn, self.surface_id, surface_damage_buffer, pending.pixel_w, pending.pixel_h);
        } else {
            try sendDamage(&self.conn, self.surface_id, surface_damage, pending.logical_w, pending.logical_h);
        }
        try sendEmpty(&self.conn, self.surface_id, surface_commit);
    }

    fn requestFrame(self: *Window) void {
        if (self.frame_callback_id != 0) return;
        const callback = self.conn.allocId() catch return;
        sendOneU32(&self.conn, self.surface_id, surface_frame, callback) catch return;
        self.frame_callback_id = callback;
    }

    fn finishFrameCallback(self: *Window) void {
        self.frame_callback_id = 0;
        const pending = self.pending_present orelse return;
        self.pending_present = null;
        self.attachAndCommit(pending) catch {
            self.unbusyBuffer(pending.buffer_id);
            return;
        };
        self.requestFrame();
    }

    fn unbusyBuffer(self: *Window, buffer_id: u32) void {
        for (self.buffers.items) |*buffer| {
            if (buffer.id == buffer_id) {
                buffer.busy = false;
                return;
            }
        }
    }

    fn shouldDeferPresent(frame_callback_id: u32) bool {
        return frame_callback_id != 0;
    }

    fn bufferDimensions(self: *const Window, logical_w: u32, logical_h: u32) struct { w: u32, h: u32, use_viewport: bool } {
        if (self.viewport_id != 0 and self.fractional_scale_120 != 0) {
            return .{
                .w = scale120(logical_w, self.fractional_scale_120),
                .h = scale120(logical_h, self.fractional_scale_120),
                .use_viewport = true,
            };
        }
        return .{
            .w = logical_w * self.output_scale,
            .h = logical_h * self.output_scale,
            .use_viewport = false,
        };
    }

    /// Read and dispatch exactly one wire event. Protocol-only events (buffer
    /// release, ping, keymap, seat name) are handled internally and reported
    /// as `.other`. Keeping this one-message boundary is required by poll-based
    /// callers: a release can be the only readable message, and waiting here
    /// for a later visible event would starve the IRC socket indefinitely.
    pub fn nextEvent(self: *Window) !Event {
        if (self.takeCommittedKey()) |event| return event;
        const msg = try self.conn.readMessage(self.gpa);
        defer msg.deinit(self.gpa);
        return try self.dispatch(msg) orelse .other;
    }

    /// Synthesizes the next key-repeat event, if a key is held and its
    /// repeat interval has elapsed. Unlike X11 (which gets repeat for free
    /// from the X server's own auto-repeat), Wayland deliberately leaves
    /// this entirely to the client (see the module doc) — callers must poll
    /// this on every loop tick, not only when the compositor socket has
    /// data ready, since a repeat fires with no new wire message at all.
    /// Always recomputes the next deadline from the current time rather
    /// than accumulating fixed steps, so a delayed poll loop does not fire
    /// a burst of catch-up repeats once it resumes.
    pub fn checkRepeat(self: *Window) ?Event {
        if (self.takeCommittedKey()) |event| return event;
        if (self.ime_composing) return null;
        const code = self.held_key_code orelse return null;
        if (self.repeat_rate_per_sec <= 0) return null;
        const now = nowMs(self.conn.io);
        if (now < self.next_repeat_at_ms) return null;
        const interval_ms: u64 = @intCast(@max(1, @divTrunc(1000, self.repeat_rate_per_sec)));
        self.next_repeat_at_ms = now +| interval_ms;
        return .{ .key = .{
            .key = self.translateKey(code, self.held_key_shift),
            .modifiers = .{
                .shift = self.held_key_shift,
                .control = self.held_key_control,
                .alt = self.alt_left or self.alt_right,
                .super = self.super_left or self.super_right,
            },
        } };
    }

    fn discoverGlobals(self: *Window, globals: *Globals) !void {
        self.registry_id = try self.conn.allocId();
        try sendOneU32(&self.conn, wl_display, display_get_registry, self.registry_id);
        const callback = try self.conn.allocId();
        try sendOneU32(&self.conn, wl_display, display_sync, callback);

        while (true) {
            const msg = try self.conn.readMessage(self.gpa);
            defer msg.deinit(self.gpa);
            if (msg.object == wl_display and msg.opcode == 0) return error.WaylandProtocolError;
            if (msg.object == self.registry_id and msg.opcode == 0) {
                const global = try parseRegistryGlobal(msg.body);
                globals.record(global.name, global.interface, global.version);
            } else if (msg.object == callback and msg.opcode == 0) {
                if (msg.body.len != 4) return error.InvalidWaylandMessage;
                return;
            }
        }
    }

    fn dispatch(self: *Window, msg: Message) !?Event {
        if (msg.object == wl_display) {
            if (msg.opcode == 0) return error.WaylandProtocolError;
            return null; // delete_id
        }
        if (msg.object == self.xdg_wm_base_id) {
            if (msg.opcode == 0) {
                if (msg.body.len != 4) return error.InvalidWaylandMessage;
                try sendOneU32(&self.conn, self.xdg_wm_base_id, xdg_wm_base_pong, get32(msg.body));
            }
            return null;
        }
        if (msg.object == self.shm_id) {
            if (msg.opcode == 0) {
                if (msg.body.len != 4) return error.InvalidWaylandMessage;
                if (get32(msg.body) == shm_argb8888) self.argb_supported = true;
            }
            return null;
        }
        if (msg.object == self.seat_id) {
            if (msg.opcode == 0) {
                if (msg.body.len != 4) return error.InvalidWaylandMessage;
                try self.updateSeatCapabilities(get32(msg.body));
            }
            return null;
        }
        if (self.outputIndex(msg.object)) |index| {
            switch (msg.opcode) {
                0 => { // geometry(..., physical_width, physical_height, ...)
                    if (msg.body.len < 16) return error.InvalidWaylandMessage;
                    const mm = getI32(msg.body[8..12]);
                    self.output_width_mm[index] = if (mm > 0) @intCast(mm) else 0;
                    self.applyOutputMmScale(index);
                },
                1 => { // mode(flags, width, height, refresh)
                    if (msg.body.len != 16) return error.InvalidWaylandMessage;
                    const px = getI32(msg.body[4..8]);
                    self.output_width_px[index] = if (px > 0) @intCast(px) else 0;
                    self.applyOutputMmScale(index);
                },
                3 => { // scale(factor)
                    if (msg.body.len != 4) return error.InvalidWaylandMessage;
                    const announced = getI32(msg.body);
                    if (announced > 0 and announced <= 8) {
                        self.output_have_scale[index] = true;
                        self.output_scales[index] = @intCast(announced);
                    }
                },
                else => {},
            }
            const previous = self.output_scale;
            self.output_scale = self.currentOutputScale();
            if (self.configured and previous != self.output_scale) {
                self.refreshFallbackCursor();
                return Event.expose;
            }
            return null;
        }
        if (self.fractional_scale_id != 0 and msg.object == self.fractional_scale_id) {
            if (msg.opcode == 0) {
                if (msg.body.len != 4) return error.InvalidWaylandMessage;
                const previous = self.fractional_scale_120;
                self.fractional_scale_120 = get32(msg.body);
                if (self.configured and previous != self.fractional_scale_120) return Event.expose;
            }
            return null;
        }
        if (self.data_device_id != 0 and msg.object == self.data_device_id) {
            return try self.dataDeviceEvent(msg.opcode, msg.body);
        }
        if (self.data_source_id != 0 and msg.object == self.data_source_id) {
            return try self.dataSourceEvent(msg.opcode, msg.body);
        }
        if (self.data_offer_id != 0 and msg.object == self.data_offer_id) {
            return try self.dataOfferEvent(msg.opcode, msg.body);
        }
        if (self.dnd_offer_id != 0 and msg.object == self.dnd_offer_id) {
            return try self.dataOfferEvent(msg.opcode, msg.body);
        }
        if (self.pending_offer_id != 0 and msg.object == self.pending_offer_id) {
            return try self.dataOfferEvent(msg.opcode, msg.body);
        }
        if (self.primary_device_id != 0 and msg.object == self.primary_device_id) {
            return try self.primaryDeviceEvent(msg.opcode, msg.body);
        }
        if (self.primary_source_id != 0 and msg.object == self.primary_source_id) {
            return try self.primarySourceEvent(msg.opcode, msg.body);
        }
        if (self.primary_offer_id != 0 and msg.object == self.primary_offer_id) {
            return try self.primaryOfferEvent(msg.opcode, msg.body);
        }
        if (self.pending_primary_offer_id != 0 and msg.object == self.pending_primary_offer_id) {
            return try self.primaryOfferEvent(msg.opcode, msg.body);
        }
        if (self.text_input_id != 0 and msg.object == self.text_input_id) {
            return try self.textInputEvent(msg.opcode, msg.body);
        }
        if (self.keyboard_id != 0 and msg.object == self.keyboard_id) {
            return try self.keyboardEvent(msg.opcode, msg.body);
        }
        if (self.pointer_id != 0 and msg.object == self.pointer_id) {
            return try self.pointerEvent(msg.opcode, msg.body);
        }
        if (self.touch_id != 0 and msg.object == self.touch_id) {
            return try self.touchEvent(msg.opcode, msg.body);
        }
        if (self.frame_callback_id != 0 and msg.object == self.frame_callback_id) {
            self.finishFrameCallback();
            return null;
        }
        if (self.decoration_id != 0 and msg.object == self.decoration_id) {
            if (msg.opcode == 0 and msg.body.len >= 4) {
                const mode = get32(msg.body);
                self.decoration_mode = mode;
                if (decorationModeIsClientSide(mode) and !self.decoration_retry) {
                    self.decoration_retry = true;
                    sendOneU32(&self.conn, self.decoration_id, decoration_set_mode, decoration_mode_server_side) catch {};
                }
            }
            return null;
        }
        if (msg.object == self.xdg_toplevel_id) {
            switch (msg.opcode) {
                0 => {
                    if (msg.body.len < 12) return error.InvalidWaylandMessage;
                    self.pending_width = clampToBounds(getI32(msg.body[0..4]), self.bounds_width);
                    self.pending_height = clampToBounds(getI32(msg.body[4..8]), self.bounds_height);
                    const array_len: usize = @intCast(get32(msg.body[8..12]));
                    if (array_len > msg.body.len - 12) return error.InvalidWaylandMessage;
                    if (12 + pad4(array_len) != msg.body.len) return error.InvalidWaylandMessage;
                    const states = msg.body[12 .. 12 + array_len];
                    self.toplevel_maximized = configureContainsState(states, xdg_state_maximized);
                    self.toplevel_fullscreen = configureContainsState(states, xdg_state_fullscreen);
                    self.toplevel_tiled = configureContainsState(states, xdg_state_tiled_left) or
                        configureContainsState(states, xdg_state_tiled_right) or
                        configureContainsState(states, xdg_state_tiled_top) or
                        configureContainsState(states, xdg_state_tiled_bottom);
                    self.toplevel_suspended = configureContainsState(states, xdg_state_suspended);
                    if (configureContainsState(states, xdg_state_activated)) {
                        self.refreshTextInput() catch {};
                    }
                    return null;
                },
                1 => return Event.close,
                2 => { // configure_bounds(width, height), xdg-shell v4
                    if (msg.body.len < 8) return error.InvalidWaylandMessage;
                    self.bounds_width = getI32(msg.body[0..4]);
                    self.bounds_height = getI32(msg.body[4..8]);
                    return null;
                },
                3 => { // wm_capabilities(array), xdg-shell v5
                    if (msg.body.len < 4) return error.InvalidWaylandMessage;
                    const array_len: usize = @intCast(get32(msg.body[0..4]));
                    if (array_len > msg.body.len - 4) return error.InvalidWaylandMessage;
                    if (4 + pad4(array_len) != msg.body.len) return error.InvalidWaylandMessage;
                    const caps = msg.body[4 .. 4 + array_len];
                    self.wm_can_window_menu = configureContainsState(caps, xdg_wm_cap_window_menu);
                    self.wm_can_maximize = configureContainsState(caps, xdg_wm_cap_maximize);
                    self.wm_can_fullscreen = configureContainsState(caps, xdg_wm_cap_fullscreen);
                    self.wm_can_minimize = configureContainsState(caps, xdg_wm_cap_minimize);
                    return null;
                },
                else => return null,
            }
        }
        if (msg.object == self.xdg_surface_id) {
            if (msg.opcode != 0) return null;
            if (msg.body.len != 4) return error.InvalidWaylandMessage;
            try sendOneU32(&self.conn, self.xdg_surface_id, xdg_surface_ack_configure, get32(msg.body));
            const old_w = self.width;
            const old_h = self.height;
            if (self.pending_width > 0) self.width = @intCast(self.pending_width);
            if (self.pending_height > 0) self.height = @intCast(self.pending_height);
            self.pending_width = 0;
            self.pending_height = 0;
            self.configured = true;
            if (self.width != old_w or self.height != old_h) {
                self.refreshTextInput() catch {};
                return .{ .resize = .{ .w = self.width, .h = self.height } };
            }
            self.refreshTextInput() catch {};
            return Event.expose;
        }
        if (msg.object == self.surface_id) return try self.surfaceEvent(msg.opcode, msg.body);
        for (self.buffers.items) |*buffer| {
            if (msg.object == buffer.id) {
                if (msg.opcode == 0) buffer.busy = false;
                return null;
            }
        }
        return null;
    }

    fn updateSeatCapabilities(self: *Window, capabilities: u32) !void {
        if ((capabilities & seat_pointer) != 0) {
            if (self.pointer_id == 0) {
                self.pointer_id = try self.conn.allocId();
                try sendOneU32(&self.conn, self.seat_id, seat_get_pointer, self.pointer_id);
                if (self.cursor_shape_manager_id != 0 and self.cursor_shape_device_id == 0) {
                    self.cursor_shape_device_id = try self.conn.allocId();
                    try sendTwoU32(&self.conn, self.cursor_shape_manager_id, cursor_shape_get_pointer, self.cursor_shape_device_id, self.pointer_id);
                }
            }
        } else if (self.pointer_id != 0) {
            if (self.seat_version >= 3) try sendEmpty(&self.conn, self.pointer_id, pointer_release);
            self.pointer_id = 0;
        }
        if ((capabilities & seat_keyboard) != 0) {
            if (self.keyboard_id == 0) {
                self.keyboard_id = try self.conn.allocId();
                try sendOneU32(&self.conn, self.seat_id, seat_get_keyboard, self.keyboard_id);
            }
        } else if (self.keyboard_id != 0) {
            if (self.seat_version >= 3) try sendEmpty(&self.conn, self.keyboard_id, keyboard_release);
            self.keyboard_id = 0;
            self.shift_left = false;
            self.shift_right = false;
            self.control_left = false;
            self.control_right = false;
            self.alt_left = false;
            self.alt_right = false;
            self.super_left = false;
            self.super_right = false;
            self.held_key_code = null;
        }
        if ((capabilities & seat_touch) != 0) {
            if (self.touch_id == 0) {
                self.touch_id = try self.conn.allocId();
                try sendOneU32(&self.conn, self.seat_id, seat_get_touch, self.touch_id);
            }
        } else if (self.touch_id != 0) {
            if (self.seat_version >= 3) try sendEmpty(&self.conn, self.touch_id, 0);
            self.touch_id = 0;
            self.touch_contact = null;
        }
    }

    fn touchEvent(self: *Window, opcode: u16, body: []const u8) !?Event {
        switch (opcode) {
            0 => { // down(serial, time, surface, id, x, y)
                if (body.len != 24) return error.InvalidWaylandMessage;
                if (self.touch_contact != null) return null;
                self.touch_contact = getI32(body[12..16]);
                self.pointer_x = @divTrunc(getI32(body[16..20]), 256);
                self.pointer_y = @divTrunc(getI32(body[20..24]), 256);
                return .{ .pointer = .{ .kind = .down, .x = self.pointer_x, .y = self.pointer_y, .button = .primary } };
            },
            1 => { // up(serial, time, id)
                if (body.len != 12) return error.InvalidWaylandMessage;
                if (self.touch_contact == null or self.touch_contact.? != getI32(body[8..12])) return null;
                self.touch_contact = null;
                return .{ .pointer = .{ .kind = .up, .x = self.pointer_x, .y = self.pointer_y, .button = .primary } };
            },
            2 => { // motion(time, id, x, y)
                if (body.len != 16) return error.InvalidWaylandMessage;
                if (self.touch_contact == null or self.touch_contact.? != getI32(body[4..8])) return null;
                self.pointer_x = @divTrunc(getI32(body[8..12]), 256);
                self.pointer_y = @divTrunc(getI32(body[12..16]), 256);
                return .{ .pointer = .{ .kind = .move, .x = self.pointer_x, .y = self.pointer_y, .button = .primary } };
            },
            4 => { // cancel
                if (body.len != 0) return error.InvalidWaylandMessage;
                if (self.touch_contact == null) return null;
                self.touch_contact = null;
                return .{ .pointer = .{ .kind = .up, .x = self.pointer_x, .y = self.pointer_y, .button = .primary } };
            },
            3, 5, 6 => return null,
            else => return null,
        }
    }

    fn textInputEvent(self: *Window, opcode: u16, body: []const u8) !?Event {
        switch (opcode) {
            0 => { // enter(surface)
                if (body.len != 4 or get32(body) != self.surface_id) return error.InvalidWaylandMessage;
                try self.enableTextInput();
            },
            1 => { // leave(surface)
                if (body.len != 4) return error.InvalidWaylandMessage;
                self.ime_composing = false;
                self.last_committed = null;
                try sendEmpty(&self.conn, self.text_input_id, text_input_disable);
                try sendEmpty(&self.conn, self.text_input_id, text_input_commit);
            },
            2 => { // preedit_string(text, cursor_begin, cursor_end)
                const text = try parseLeadingString(body);
                self.ime_composing = text.len != 0;
            },
            3 => { // commit_string(text)
                const text = try parseWireString(body);
                if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidWaylandString;
                var view = try std.unicode.Utf8View.init(text);
                var iterator = view.iterator();
                var last: ?u21 = null;
                while (iterator.nextCodepoint()) |codepoint| {
                    if (self.committed_text.items.len - self.committed_text_offset >= 4096) break;
                    try self.committed_text.append(self.gpa, codepoint);
                    last = codepoint;
                }
                self.last_committed = last;
                self.ime_composing = false;
                return self.takeCommittedKey();
            },
            4 => {}, // delete_surrounding_text
            5 => self.ime_composing = false, // done
            else => {},
        }
        return null;
    }

    fn enableTextInput(self: *Window) !void {
        if (self.text_input_id == 0) return;
        try sendEmpty(&self.conn, self.text_input_id, text_input_enable);
        try sendTwoU32(&self.conn, self.text_input_id, text_input_set_content_type, text_input_hint_multiline, 0);
        try self.sendCursorRectangle();
        try sendEmpty(&self.conn, self.text_input_id, text_input_commit);
    }

    fn refreshTextInput(self: *Window) !void {
        if (self.text_input_id == 0 or !self.configured) return;
        try self.sendCursorRectangle();
        try sendEmpty(&self.conn, self.text_input_id, text_input_commit);
    }

    fn sendCursorRectangle(self: *Window) !void {
        const rect = imeCursorRect(self.width, self.height);
        try sendFourI32(
            &self.conn,
            self.text_input_id,
            text_input_set_cursor_rectangle,
            rect.x,
            rect.y,
            rect.w,
            rect.h,
        );
    }

    fn takeCommittedKey(self: *Window) ?Event {
        if (self.committed_text_offset >= self.committed_text.items.len) {
            self.committed_text.clearRetainingCapacity();
            self.committed_text_offset = 0;
            return null;
        }
        const codepoint = self.committed_text.items[self.committed_text_offset];
        self.committed_text_offset += 1;
        return .{ .key = .{ .key = .{ .char = codepoint }, .modifiers = .{} } };
    }

    fn pointerEvent(self: *Window, opcode: u16, body: []const u8) !?Event {
        switch (opcode) {
            0 => { // enter(serial, surface, x, y)
                if (body.len != 16) return error.InvalidWaylandMessage;
                self.last_serial = get32(body[0..4]);
                self.pointer_x = @divTrunc(getI32(body[8..12]), 256);
                self.pointer_y = @divTrunc(getI32(body[12..16]), 256);
                self.applyPointerCursor();
                return .{ .pointer = .{ .kind = .move, .x = self.pointer_x, .y = self.pointer_y } };
            },
            1 => { // leave(serial, surface)
                if (body.len != 8) return error.InvalidWaylandMessage;
                return null;
            },
            2 => { // motion(time, x, y)
                if (body.len != 12) return error.InvalidWaylandMessage;
                self.pointer_x = @divTrunc(getI32(body[4..8]), 256);
                self.pointer_y = @divTrunc(getI32(body[8..12]), 256);
                return .{ .pointer = .{ .kind = .move, .x = self.pointer_x, .y = self.pointer_y } };
            },
            3 => { // button(serial, time, button, state)
                if (body.len != 16) return error.InvalidWaylandMessage;
                self.last_serial = get32(body[0..4]);
                self.applyPointerCursor();
                const button: shared_event.PointerButton = switch (get32(body[8..12])) {
                    0x110 => .primary,
                    0x111 => .secondary,
                    0x112 => .middle,
                    else => .none,
                };
                const pressed = get32(body[12..16]) != 0;
                if (pressed and button == .middle) {
                    if (self.pastePrimaryAsKeys()) |ev| {
                        self.middle_paste = true;
                        return ev;
                    }
                }
                if (!pressed and button == .middle and self.middle_paste) {
                    self.middle_paste = false;
                    return null;
                }
                var clicks: u8 = 1;
                if (pressed and button == .primary) {
                    const now = get32(body[4..8]);
                    const near = @abs(self.pointer_x - self.last_primary_x) <= 4 and @abs(self.pointer_y - self.last_primary_y) <= 4;
                    if (near and now -% self.last_primary_click_ms <= 500) clicks = 2;
                    self.last_primary_click_ms = now;
                    self.last_primary_x = self.pointer_x;
                    self.last_primary_y = self.pointer_y;
                }
                return .{ .pointer = .{
                    .kind = if (pressed) .down else .up,
                    .x = self.pointer_x,
                    .y = self.pointer_y,
                    .button = button,
                    .clicks = clicks,
                } };
            },
            4 => { // axis(time, axis, value)
                if (body.len != 12) return error.InvalidWaylandMessage;
                if (self.axis_have_discrete) return null;
                if (get32(body[4..8]) != 0) return null;
                const value = getI32(body[8..12]);
                return .{ .pointer = .{
                    .kind = .wheel,
                    .x = self.pointer_x,
                    .y = self.pointer_y,
                    .wheel_y = if (value < 0) 1 else if (value > 0) -1 else 0,
                } };
            },
            5 => { // frame
                self.axis_have_discrete = false;
                return null;
            },
            8 => { // axis_discrete(axis, discrete)
                if (body.len != 8) return error.InvalidWaylandMessage;
                if (get32(body[0..4]) != 0) return null;
                self.axis_have_discrete = true;
                const discrete = getI32(body[4..8]);
                return .{ .pointer = .{
                    .kind = .wheel,
                    .x = self.pointer_x,
                    .y = self.pointer_y,
                    .wheel_y = if (discrete < 0) 1 else if (discrete > 0) -1 else 0,
                } };
            },
            9 => { // axis_value120(axis, value120)
                if (body.len != 8) return error.InvalidWaylandMessage;
                if (get32(body[0..4]) != 0) return null;
                self.axis_have_discrete = true;
                const value = getI32(body[4..8]);
                return .{ .pointer = .{
                    .kind = .wheel,
                    .x = self.pointer_x,
                    .y = self.pointer_y,
                    .wheel_y = if (value < 0) 1 else if (value > 0) -1 else 0,
                } };
            },
            else => return null,
        }
    }

    fn keyboardEvent(self: *Window, opcode: u16, body: []const u8) !?Event {
        switch (opcode) {
            0 => { // keymap(format, fd, size); fd is ancillary, not in body
                if (body.len != 8) return error.InvalidWaylandMessage;
                const format = get32(body[0..4]);
                const size = get32(body[4..8]);
                if (self.conn.takePendingFd()) |fd_value| {
                    defer _ = linux.close(fd_value);
                    if (self.loadKeymap(fd_value, format, size)) |parsed| {
                        if (self.xkb_keymap) |*old| old.deinit();
                        self.xkb_keymap = parsed;
                    } else |_| {
                        // Unsupported format or a malformed keymap this bounded
                        // parser cannot read: keep whatever keymap (or none) we
                        // already had rather than failing the connection over a
                        // layout we cannot represent. evdevToKey remains the
                        // fallback either way.
                    }
                }
                return null;
            },
            1 => { // enter(serial, surface, keys array)
                if (body.len < 12) return error.InvalidWaylandMessage;
                self.last_serial = get32(body[0..4]);
                const keys_len: usize = @intCast(get32(body[8..12]));
                if (12 + pad4(keys_len) != body.len) return error.InvalidWaylandMessage;
                self.applyHeldKeys(body[12 .. 12 + keys_len]);
                self.refreshTextInput() catch {};
                return null;
            },
            2 => { // leave
                if (body.len != 8) return error.InvalidWaylandMessage;
                self.shift_left = false;
                self.shift_right = false;
                self.control_left = false;
                self.control_right = false;
                self.alt_left = false;
                self.alt_right = false;
                self.super_left = false;
                self.super_right = false;
                self.held_key_code = null;
                self.ime_composing = false;
                self.compose.reset();
                return null;
            },
            3 => { // key(serial, time, key, state)
                if (body.len != 16) return error.InvalidWaylandMessage;
                self.last_serial = get32(body[0..4]);
                const code = get32(body[8..12]);
                const state = get32(body[12..16]);
                const down = state != 0;
                switch (code) {
                    42 => self.shift_left = down,
                    54 => self.shift_right = down,
                    29 => self.control_left = down,
                    97 => self.control_right = down,
                    56 => self.alt_left = down,
                    100 => self.alt_right = down,
                    125 => self.super_left = down,
                    126 => self.super_right = down,
                    58 => if (state == 1) {
                        self.caps_lock = !self.caps_lock;
                    },
                    else => {},
                }
                const is_modifier = code == 42 or code == 54 or code == 29 or code == 97 or code == 56 or code == 100 or code == 125 or code == 126 or code == 58;
                if (!is_modifier) {
                    if (down) {
                        self.held_key_code = code;
                        self.held_key_shift = self.shift_left or self.shift_right;
                        self.held_key_control = self.control_left or self.control_right;
                        self.next_repeat_at_ms = nowMs(self.conn.io) +| @as(u64, @intCast(@max(0, self.repeat_delay_ms)));
                    } else if (self.held_key_code == code) {
                        self.held_key_code = null;
                    }
                }
                if (!down) {
                    return null;
                }
                if (is_modifier) return null;
                if (self.ime_composing) return null;
                const shifted = self.shift_left or self.shift_right;
                const control = self.control_left or self.control_right;
                const key = self.translateComposed(code, shifted, control);
                if (key) |translated| {
                    if (shouldSuppressImeDuplicate(self.last_committed, translated)) {
                        self.last_committed = null;
                        self.held_key_code = null;
                        return null;
                    }
                    self.last_committed = null;
                }
                if (key == null) {
                    self.held_key_code = null;
                    return null;
                }
                return .{ .key = .{
                    .key = key.?,
                    .modifiers = .{
                        .shift = shifted,
                        .control = control,
                        .alt = self.alt_left or self.alt_right,
                        .super = self.super_left or self.super_right,
                    },
                } };
            },
            4 => { // modifiers(serial, depressed, latched, locked, group)
                if (body.len != 20) return error.InvalidWaylandMessage;
                // Depressed Shift/Ctrl/Alt/Super stay on the evdev key bits
                // because those indices are not stable across keymaps. Caps
                // Lock is the conventional Lock modifier (bit 1) in virtually
                // every XKB map; when the compositor reports it, prefer that
                // over the local evdev toggle so a lock already held at
                // keyboard enter is not missed. Group is the layout slot.
                const locked = get32(body[12..16]);
                self.caps_lock = capsLockFromLocked(locked, self.caps_lock, &self.caps_from_compositor);
                self.xkb_group = get32(body[16..20]);
                return null;
            },
            5 => { // repeat_info(rate, delay), available because the seat is bound at v4+
                if (body.len != 8) return error.InvalidWaylandMessage;
                self.repeat_rate_per_sec = getI32(body[0..4]);
                self.repeat_delay_ms = getI32(body[4..8]);
                return null;
            },
            else => return null,
        }
    }

    /// mmaps and parses a compositor-supplied keymap fd. The mapping is
    /// unmapped before returning either way: `xkb.parse` copies everything
    /// it needs into the returned `Keymap`'s own arena, so the raw text is
    /// not needed past this call.
    fn loadKeymap(self: *Window, fd_value: posix.fd_t, format: u32, size: u32) !xkb.Keymap {
        if (size == 0) return error.EmptyKeymap;
        const mapped = try posix.mmap(null, size, .{ .READ = true }, .{ .TYPE = .PRIVATE }, fd_value, 0);
        defer posix.munmap(mapped);
        const text_len = std.mem.indexOfScalar(u8, mapped, 0) orelse mapped.len;
        return xkb.parse(self.gpa, format, mapped[0..text_len]);
    }

    /// Translates one physical key press using the compositor's real layout
    /// when available, falling back to evdevToKey's US table otherwise (no
    /// keymap yet, an unsupported/unparseable one, or a keysym this bounded
    /// translator does not represent).
    ///
    /// Caps Lock only affects alphabetic keys (matching evdevToKey's
    /// existing shift-XOR-caps behavior for letters): the key's own
    /// unshifted keysym decides whether it is one, then the *effective*
    /// shift state — physical shift XOR caps lock for a letter, physical
    /// shift alone otherwise — selects which of the keymap's two levels to
    /// read, rather than hand-flipping ASCII case after the fact (which
    /// would silently be wrong for a layout where the shifted symbol is not
    /// simply the base character's uppercase form).
    fn translateKey(self: *Window, code: u32, shift: bool) Key {
        if (self.xkb_keymap) |*keymap| {
            if (self.xkb_group == 0 and self.alt_right) {
                if (keymap.keysymForLevel(code, .level3)) |keysym| {
                    if (xkb.charForKeysym(keysym)) |ch| return .{ .char = ch };
                    if (xkb.namedKeyForKeysym(keysym)) |named| return namedKeyToKey(named);
                }
            }
            if (keymap.keysymForGroupLevel(code, self.xkb_group, .base)) |base_keysym| {
                const is_letter = base_keysym.len == 1 and std.ascii.isAlphabetic(base_keysym[0]);
                const effective_shift = if (is_letter) (shift != self.caps_lock) else shift;
                if (keymap.keysymForGroupLevel(code, self.xkb_group, if (effective_shift) .shift else .base)) |keysym| {
                    if (xkb.charForKeysym(keysym)) |ch| return .{ .char = ch };
                    if (xkb.namedKeyForKeysym(keysym)) |named| return namedKeyToKey(named);
                }
            }
        }
        return evdevToKey(code, shift, self.caps_lock);
    }

    fn currentKeysymName(self: *const Window, code: u32, shift: bool) ?[]const u8 {
        const keymap = self.xkb_keymap orelse return null;
        if (self.xkb_group == 0 and self.alt_right) {
            if (keymap.keysymForLevel(code, .level3)) |name| return name;
        }
        if (keymap.keysymForGroupLevel(code, self.xkb_group, .base)) |base_keysym| {
            const is_letter = base_keysym.len == 1 and std.ascii.isAlphabetic(base_keysym[0]);
            const effective_shift = if (is_letter) (shift != self.caps_lock) else shift;
            return keymap.keysymForGroupLevel(code, self.xkb_group, if (effective_shift) .shift else .base);
        }
        return null;
    }

    fn translateComposed(self: *Window, code: u32, shift: bool, control: bool) ?Key {
        if (control) {
            self.compose.reset();
            return self.translateKey(code, shift);
        }
        if (self.currentKeysymName(code, shift)) |name| {
            switch (self.compose.feedName(name)) {
                .pending => return null,
                .char => |ch| return .{ .char = ch },
                .pass => {},
            }
        }
        const key = self.translateKey(code, shift);
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
                if (self.compose.active()) self.compose.reset();
                break :blk key;
            },
        };
    }

    fn outputIndex(self: *const Window, id: u32) ?usize {
        var i: usize = 0;
        while (i < self.output_count) : (i += 1) {
            if (self.output_ids[i] == id) return i;
        }
        return null;
    }

    fn currentOutputScale(self: *const Window) u32 {
        if (self.preferred_buffer_scale != 0) return self.preferred_buffer_scale;
        var scale: u32 = 1;
        var i: usize = 0;
        while (i < self.entered_count) : (i += 1) {
            if (self.outputIndex(self.entered_outputs[i])) |index| {
                scale = @max(scale, self.output_scales[index]);
            }
        }
        if (self.entered_count == 0 and self.output_count != 0) {
            var j: usize = 0;
            while (j < self.output_count) : (j += 1) scale = @max(scale, self.output_scales[j]);
        }
        return scale;
    }

    fn applyHeldKeys(self: *Window, keys: []const u8) void {
        const mods = heldModsFromKeyArray(keys);
        self.shift_left = mods.shift;
        self.shift_right = false;
        self.control_left = mods.control;
        self.control_right = false;
        self.alt_left = mods.alt;
        self.alt_right = false;
        self.super_left = mods.super;
        self.super_right = false;
        if (heldNonModifierFromKeyArray(keys)) |code| {
            self.held_key_code = code;
            self.held_key_shift = mods.shift;
            self.held_key_control = mods.control;
            if (self.repeat_delay_ms > 0) {
                self.next_repeat_at_ms = nowMs(self.conn.io) +| @as(u64, @intCast(self.repeat_delay_ms));
            }
        }
    }

    fn applyOutputMmScale(self: *Window, index: usize) void {
        if (self.output_have_scale[index]) return;
        if (services.scaleFromScreenMm(self.output_width_px[index], self.output_width_mm[index])) |scale| {
            self.output_scales[index] = scale;
        }
    }

    fn surfaceEvent(self: *Window, opcode: u16, body: []const u8) !?Event {
        switch (opcode) {
            0 => { // enter(output)
                if (body.len != 4) return null;
                const output = get32(body);
                if (self.indexOfEntered(output) != null) return null;
                if (self.entered_count >= max_outputs) return null;
                self.entered_outputs[self.entered_count] = output;
                self.entered_count += 1;
            },
            1 => { // leave(output)
                if (body.len != 4) return null;
                const output = get32(body);
                if (self.indexOfEntered(output)) |index| {
                    self.entered_count -= 1;
                    self.entered_outputs[index] = self.entered_outputs[self.entered_count];
                    self.entered_outputs[self.entered_count] = 0;
                }
            },
            2 => { // preferred_buffer_scale(factor), compositor v6
                if (body.len != 4) return null;
                self.preferred_buffer_scale = get32(body);
            },
            else => return null,
        }
        const previous = self.output_scale;
        self.output_scale = self.currentOutputScale();
        if (self.configured and previous != self.output_scale) {
            self.refreshFallbackCursor();
            return Event.expose;
        }
        return null;
    }

    fn indexOfEntered(self: *const Window, output: u32) ?usize {
        var i: usize = 0;
        while (i < self.entered_count) : (i += 1) {
            if (self.entered_outputs[i] == output) return i;
        }
        return null;
    }

    fn pastePrimaryAsKeys(self: *Window) ?Event {
        if (self.readPrimaryNative(self.gpa)) |text| {
            if (text) |bytes| {
                defer self.gpa.free(bytes);
                return self.enqueueDropText(bytes) catch null;
            }
        } else |_| {}
        const fallback = services.readPrimary(self.gpa, self.conn.io, .wayland) catch return null;
        const bytes = fallback orelse return null;
        defer self.gpa.free(bytes);
        return self.enqueueDropText(bytes) catch null;
    }

    fn readPrimaryNative(self: *Window, gpa: std.mem.Allocator) !?[]u8 {
        if (self.clipboard_text.len != 0 and self.primary_source_id != 0) {
            return try gpa.dupe(u8, self.clipboard_text);
        }
        if (self.primary_offer_id != 0 and self.primary_offer_has_text) {
            return try self.receiveOffer(gpa, self.primary_offer_id, primary_offer_receive);
        }
        return null;
    }

    fn writeClipboardNative(self: *Window, text: []const u8) !void {
        if (text.len > max_clipboard_bytes) return error.ClipboardTooLarge;
        if (self.data_device_id == 0) return error.MissingDataDevice;
        if (self.last_serial == 0) return error.MissingSelectionSerial;
        const copy = try self.gpa.dupe(u8, text);
        if (self.clipboard_text.len != 0) self.gpa.free(self.clipboard_text);
        self.clipboard_text = copy;
        if (self.data_source_id != 0) {
            sendEmpty(&self.conn, self.data_source_id, data_source_destroy) catch {};
            self.data_source_id = 0;
        }
        self.data_source_id = try self.conn.allocId();
        try sendOneU32(&self.conn, self.data_device_manager_id, data_device_manager_create_data_source, self.data_source_id);
        try self.offerTextMimes(self.data_source_id, data_source_offer);
        try sendTwoU32(&self.conn, self.data_device_id, data_device_set_selection, self.data_source_id, self.last_serial);
        if (self.primary_device_id != 0) {
            if (self.primary_source_id != 0) {
                sendEmpty(&self.conn, self.primary_source_id, primary_source_destroy) catch {};
                self.primary_source_id = 0;
            }
            self.primary_source_id = try self.conn.allocId();
            try sendOneU32(&self.conn, self.primary_manager_id, primary_manager_create_source, self.primary_source_id);
            try self.offerTextMimes(self.primary_source_id, primary_source_offer);
            try sendTwoU32(&self.conn, self.primary_device_id, primary_device_set_selection, self.primary_source_id, self.last_serial);
        }
    }

    fn readClipboardNative(self: *Window, gpa: std.mem.Allocator) !?[]u8 {
        if (self.clipboard_text.len != 0 and (self.data_source_id != 0 or self.primary_source_id != 0)) {
            return try gpa.dupe(u8, self.clipboard_text);
        }
        if (self.data_offer_id != 0 and self.offer_has_text) {
            return try self.receiveOffer(gpa, self.data_offer_id, data_offer_receive);
        }
        if (self.primary_offer_id != 0 and self.primary_offer_has_text) {
            return try self.receiveOffer(gpa, self.primary_offer_id, primary_offer_receive);
        }
        return error.MissingDataOffer;
    }

    fn receiveOffer(self: *Window, gpa: std.mem.Allocator, offer_id: u32, opcode: u16) ![]u8 {
        var last_empty: ?[]u8 = null;
        for (desktop_file_mime_types) |mime| {
            if (self.receiveMime(gpa, offer_id, opcode, mime)) |text| {
                if (text.len != 0) {
                    if (last_empty) |prev| gpa.free(prev);
                    if (self.takeDesktopFilePath(gpa, text)) |path| return path;
                    return decodeClipboardBytes(gpa, text);
                }
                if (last_empty) |prev| gpa.free(prev);
                last_empty = text;
            } else |_| {}
        }
        for (text_mime_types) |mime| {
            if (self.receiveMime(gpa, offer_id, opcode, mime)) |text| {
                if (text.len != 0) {
                    if (last_empty) |prev| gpa.free(prev);
                    if (std.mem.eql(u8, mime, "text/uri-list")) {
                        if (self.takeDesktopFilePath(gpa, text)) |path| return path;
                    }
                    return decodeClipboardBytes(gpa, text);
                }
                if (last_empty) |prev| gpa.free(prev);
                last_empty = text;
            } else |_| {}
        }
        for (utf16_mime_types) |mime| {
            if (self.receiveMime(gpa, offer_id, opcode, mime)) |text| {
                if (text.len != 0) {
                    if (last_empty) |prev| gpa.free(prev);
                    const decoded = services.clipboardUtf16BytesToUtf8(gpa, text) catch {
                        return decodeClipboardBytes(gpa, text);
                    };
                    gpa.free(text);
                    return decoded;
                }
                if (last_empty) |prev| gpa.free(prev);
                last_empty = text;
            } else |_| {}
        }
        for (html_mime_types) |mime| {
            if (self.receiveMime(gpa, offer_id, opcode, mime)) |text| {
                if (text.len != 0) {
                    if (last_empty) |prev| gpa.free(prev);
                    const decoded = decodeClipboardBytes(gpa, text) catch return text;
                    const plain = services.htmlToPlainText(gpa, decoded) catch return decoded;
                    gpa.free(decoded);
                    return plain;
                }
                if (last_empty) |prev| gpa.free(prev);
                last_empty = text;
            } else |_| {}
        }
        if (last_empty) |text| return decodeClipboardBytes(gpa, text);
        return error.MissingDataOffer;
    }

    fn takeDesktopFilePath(_: *Window, gpa: std.mem.Allocator, bytes: []u8) ?[]u8 {
        var scratch: [1024]u8 = undefined;
        const path = services.firstPathFromDesktopFiles(bytes, &scratch) orelse
            services.firstPathFromUriList(bytes, &scratch) orelse return null;
        const owned = gpa.dupe(u8, path) catch return null;
        gpa.free(bytes);
        return owned;
    }

    fn offerTextMimes(self: *Window, source_id: u32, opcode: u16) !void {
        for (text_mime_types) |mime| {
            try sendString(&self.conn, self.gpa, source_id, opcode, mime);
        }
    }

    fn receiveMime(self: *Window, gpa: std.mem.Allocator, offer_id: u32, opcode: u16, mime: []const u8) ![]u8 {
        var fds: [2]i32 = undefined;
        switch (linux.errno(linux.pipe2(&fds, .{ .CLOEXEC = true }))) {
            .SUCCESS => {},
            else => return error.PipeFailed,
        }
        defer _ = linux.close(fds[0]);
        try sendReceiveFd(&self.conn, offer_id, opcode, mime, fds[1]);
        _ = linux.close(fds[1]);
        try self.roundtrip();
        return try readFdAll(gpa, fds[0], max_clipboard_bytes);
    }

    fn roundtrip(self: *Window) !void {
        const callback = try self.conn.allocId();
        try sendOneU32(&self.conn, wl_display, display_sync, callback);
        while (true) {
            const msg = try self.conn.readMessage(self.gpa);
            defer msg.deinit(self.gpa);
            if (msg.object == callback and msg.opcode == 0) return;
            _ = try self.dispatch(msg);
        }
    }

    fn dataDeviceEvent(self: *Window, opcode: u16, body: []const u8) !?Event {
        switch (opcode) {
            0 => { // data_offer
                if (body.len != 4) return error.InvalidWaylandMessage;
                if (self.pending_offer_id != 0 and self.pending_offer_id != self.data_offer_id and self.pending_offer_id != self.dnd_offer_id) {
                    sendEmpty(&self.conn, self.pending_offer_id, data_offer_destroy) catch {};
                }
                self.pending_offer_id = get32(body);
                self.pending_offer_has_text = false;
                self.pending_drop_mime = "";
            },
            1 => { // enter(serial, surface, x, y, id)
                if (body.len != 20) return error.InvalidWaylandMessage;
                self.last_serial = get32(body[0..4]);
                self.pointer_x = @divTrunc(getI32(body[8..12]), 256);
                self.pointer_y = @divTrunc(getI32(body[12..16]), 256);
                const id = get32(body[16..20]);
                self.dnd_offer_id = id;
                self.dnd_has_text = id != 0 and id == self.pending_offer_id and self.pending_offer_has_text;
                self.dnd_mime = self.pending_drop_mime;
                if (self.dnd_has_text) {
                    self.acceptDrop(id, self.last_serial) catch {};
                }
            },
            2 => { // leave
                self.clearDndOffer();
            },
            3 => { // motion(time, x, y)
                if (body.len != 12) return error.InvalidWaylandMessage;
                self.pointer_x = @divTrunc(getI32(body[4..8]), 256);
                self.pointer_y = @divTrunc(getI32(body[8..12]), 256);
            },
            4 => { // drop
                return self.takeDrop();
            },
            5 => { // selection
                if (body.len != 4) return error.InvalidWaylandMessage;
                const id = get32(body);
                if (self.data_offer_id != 0 and self.data_offer_id != id) {
                    sendEmpty(&self.conn, self.data_offer_id, data_offer_destroy) catch {};
                }
                self.data_offer_id = id;
                self.offer_has_text = id != 0 and id == self.pending_offer_id and self.pending_offer_has_text;
                if (id == 0) self.offer_has_text = false;
            },
            else => {},
        }
        return null;
    }

    fn acceptDrop(self: *Window, offer_id: u32, serial: u32) !void {
        const mime = if (self.dnd_mime.len != 0) self.dnd_mime else "text/plain;charset=utf-8";
        try sendAccept(&self.conn, self.gpa, offer_id, data_offer_accept, serial, mime);
        sendTwoU32(&self.conn, offer_id, data_offer_set_actions, dnd_action_copy, dnd_action_copy) catch {};
    }

    fn takeDrop(self: *Window) ?Event {
        const offer_id = self.dnd_offer_id;
        if (offer_id == 0 or !self.dnd_has_text) {
            self.clearDndOffer();
            return null;
        }
        const bytes = self.receiveOffer(self.gpa, offer_id, data_offer_receive) catch {
            self.clearDndOffer();
            return null;
        };
        defer self.gpa.free(bytes);
        sendEmpty(&self.conn, offer_id, data_offer_finish) catch {};
        self.clearDndOffer();
        return self.enqueueDropText(bytes) catch null;
    }

    fn enqueueDropText(self: *Window, bytes: []const u8) !?Event {
        var scratch: [1024]u8 = undefined;
        const payload = services.firstDropText(bytes, &scratch) orelse bytes;
        if (!std.unicode.utf8ValidateSlice(payload)) return null;
        var view = try std.unicode.Utf8View.init(payload);
        var iterator = view.iterator();
        while (iterator.nextCodepoint()) |codepoint| {
            if (self.committed_text.items.len - self.committed_text_offset >= 4096) break;
            try self.committed_text.append(self.gpa, codepoint);
        }
        return self.takeCommittedKey();
    }

    fn clearDndOffer(self: *Window) void {
        if (self.dnd_offer_id != 0 and self.dnd_offer_id != self.data_offer_id) {
            sendEmpty(&self.conn, self.dnd_offer_id, data_offer_destroy) catch {};
        }
        self.dnd_offer_id = 0;
        self.dnd_has_text = false;
        self.dnd_mime = "";
    }

    fn dataSourceEvent(self: *Window, opcode: u16, body: []const u8) !?Event {
        switch (opcode) {
            1 => { // send(mime, fd)
                _ = try parseWireString(body);
                if (self.conn.takePendingFd()) |fd_value| {
                    defer _ = linux.close(fd_value);
                    writeAllFd(fd_value, self.clipboard_text) catch {};
                }
            },
            2 => { // cancelled
                if (self.data_source_id != 0) {
                    sendEmpty(&self.conn, self.data_source_id, data_source_destroy) catch {};
                    self.data_source_id = 0;
                }
            },
            else => {},
        }
        return null;
    }

    fn dataOfferEvent(self: *Window, opcode: u16, body: []const u8) !?Event {
        if (opcode != 0) return null;
        const mime = try parseWireString(body);
        if (isPlainTextMime(mime)) {
            if (self.pending_offer_id != 0) {
                self.pending_offer_has_text = true;
                if (knownTextMime(mime)) |known| {
                    if (self.pending_drop_mime.len == 0 or textMimeRank(known) > textMimeRank(self.pending_drop_mime)) {
                        self.pending_drop_mime = known;
                    }
                }
            }
            if (self.data_offer_id != 0) self.offer_has_text = true;
            if (self.dnd_offer_id != 0 and self.dnd_offer_id == self.pending_offer_id) {
                self.dnd_has_text = true;
                if (knownTextMime(mime)) |known| {
                    if (self.dnd_mime.len == 0 or textMimeRank(known) > textMimeRank(self.dnd_mime)) {
                        self.dnd_mime = known;
                    }
                    self.acceptDrop(self.dnd_offer_id, self.last_serial) catch {};
                }
            }
        }
        return null;
    }

    fn primaryDeviceEvent(self: *Window, opcode: u16, body: []const u8) !?Event {
        switch (opcode) {
            0 => { // data_offer
                if (body.len != 4) return error.InvalidWaylandMessage;
                if (self.pending_primary_offer_id != 0 and self.pending_primary_offer_id != self.primary_offer_id) {
                    sendEmpty(&self.conn, self.pending_primary_offer_id, primary_offer_destroy) catch {};
                }
                self.pending_primary_offer_id = get32(body);
                self.pending_primary_offer_has_text = false;
            },
            1 => { // selection
                if (body.len != 4) return error.InvalidWaylandMessage;
                const id = get32(body);
                if (self.primary_offer_id != 0 and self.primary_offer_id != id) {
                    sendEmpty(&self.conn, self.primary_offer_id, primary_offer_destroy) catch {};
                }
                self.primary_offer_id = id;
                self.primary_offer_has_text = id != 0 and id == self.pending_primary_offer_id and self.pending_primary_offer_has_text;
                if (id == 0) self.primary_offer_has_text = false;
            },
            else => {},
        }
        return null;
    }

    fn primarySourceEvent(self: *Window, opcode: u16, body: []const u8) !?Event {
        switch (opcode) {
            0 => { // send(mime, fd)
                _ = try parseWireString(body);
                if (self.conn.takePendingFd()) |fd_value| {
                    defer _ = linux.close(fd_value);
                    writeAllFd(fd_value, self.clipboard_text) catch {};
                }
            },
            1 => { // cancelled
                if (self.primary_source_id != 0) {
                    sendEmpty(&self.conn, self.primary_source_id, primary_source_destroy) catch {};
                    self.primary_source_id = 0;
                }
            },
            else => {},
        }
        return null;
    }

    fn primaryOfferEvent(self: *Window, opcode: u16, body: []const u8) !?Event {
        if (opcode != 0) return null;
        const mime = try parseWireString(body);
        if (isPlainTextMime(mime)) {
            if (self.pending_primary_offer_id != 0) self.pending_primary_offer_has_text = true;
            if (self.primary_offer_id != 0) self.primary_offer_has_text = true;
        }
        return null;
    }

    fn refreshFallbackCursor(self: *Window) void {
        if (self.cursor_shape_device_id != 0) return;
        if (self.cursor_buffer) |*buffer| {
            sendEmpty(&self.conn, buffer.id, buffer_destroy) catch {};
            buffer.deinit();
            self.cursor_buffer = null;
        }
        self.applyPointerCursor();
    }

    fn applyPointerCursor(self: *Window) void {
        if (self.pointer_id == 0 or self.last_serial == 0) return;
        if (self.cursor_shape_device_id != 0) {
            sendTwoU32(&self.conn, self.cursor_shape_device_id, cursor_shape_set_shape, self.last_serial, cursor_shape_default) catch {};
            return;
        }
        self.ensureFallbackCursor() catch return;
        sendSetCursor(&self.conn, self.pointer_id, self.last_serial, self.cursor_surface_id, self.cursor_hotspot_x, self.cursor_hotspot_y) catch {};
    }

    fn ensureFallbackCursor(self: *Window) !void {
        if (self.cursor_surface_id != 0 and self.cursor_buffer != null) return;
        const size: u32 = services.cursorPixelSize(self.output_scale, "", "");
        const count = try std.math.mul(usize, @as(usize, size), @as(usize, size));
        const pixels = try self.gpa.alloc(u32, count);
        defer self.gpa.free(pixels);
        services.fillArrowCursor(pixels, size);
        const buffer = try self.createBuffer(size, size);
        const destination: []u32 = std.mem.bytesAsSlice(u32, buffer.memory);
        @memcpy(destination[0..count], pixels);
        if (self.cursor_surface_id == 0) {
            self.cursor_surface_id = try self.conn.allocId();
            try sendOneU32(&self.conn, self.compositor_id, compositor_create_surface, self.cursor_surface_id);
        }
        try sendAttach(&self.conn, self.cursor_surface_id, buffer.id);
        try sendDamage(&self.conn, self.cursor_surface_id, surface_damage, size, size);
        try sendEmpty(&self.conn, self.cursor_surface_id, surface_commit);
        const hot = services.arrowHotspot(size);
        self.cursor_hotspot_x = @intCast(hot.x);
        self.cursor_hotspot_y = @intCast(hot.y);
        self.cursor_buffer = buffer;
    }

    fn installToplevelIcon(self: *Window) !void {
        if (self.toplevel_icon_manager_id == 0 or self.xdg_toplevel_id == 0) return;
        self.toplevel_icon_id = try self.conn.allocId();
        try sendOneU32(&self.conn, self.toplevel_icon_manager_id, toplevel_icon_create_icon, self.toplevel_icon_id);
        try sendString(&self.conn, self.gpa, self.toplevel_icon_id, toplevel_icon_set_name, "applications-internet");
        const size: u32 = 32;
        var pixels: [32 * 32]u32 = undefined;
        services.fillWindowMark(&pixels, size);
        const buffer = try self.createBuffer(size, size);
        const destination: []u32 = std.mem.bytesAsSlice(u32, buffer.memory);
        @memcpy(destination[0 .. 32 * 32], &pixels);
        try sendTwoU32(&self.conn, self.toplevel_icon_id, toplevel_icon_add_buffer, buffer.id, 1);
        try sendTwoU32(&self.conn, self.toplevel_icon_manager_id, toplevel_icon_set_icon, self.xdg_toplevel_id, self.toplevel_icon_id);
        self.icon_buffer = buffer;
    }

    fn activateStartupToken(self: *Window) !void {
        if (self.activation_id == 0 or self.surface_id == 0 or self.startup_token.len == 0) return;
        try sendStringU32(&self.conn, self.gpa, self.activation_id, xdg_activation_activate, self.startup_token, self.surface_id);
        self.gpa.free(self.startup_token);
        self.startup_token = "";
    }

    fn createBuffer(self: *Window, w: u32, h: u32) !Buffer {
        const stride = try std.math.mul(usize, @as(usize, w), 4);
        const byte_len = try std.math.mul(usize, stride, @as(usize, h));
        if (stride > std.math.maxInt(i32) or byte_len > std.math.maxInt(i32)) return error.FramebufferTooLarge;

        const fd_value = try posix.memfd_create("comicchat-wayland", linux.MFD.CLOEXEC);
        defer _ = linux.close(fd_value);
        try truncateFd(fd_value, @intCast(byte_len));
        const memory = try posix.mmap(
            null,
            byte_len,
            .{ .READ = true, .WRITE = true },
            .{ .TYPE = .SHARED },
            fd_value,
            0,
        );
        errdefer posix.munmap(memory);

        const pool_id = try self.conn.allocId();
        var pool_req: [16]u8 = @splat(0);
        header(&pool_req, self.shm_id, shm_create_pool);
        put32(pool_req[8..12], pool_id);
        putI32(pool_req[12..16], @intCast(byte_len));
        try self.conn.writeWithFd(&pool_req, fd_value);

        const buffer_id = try self.conn.allocId();
        var buffer_req: [32]u8 = @splat(0);
        header(&buffer_req, pool_id, shm_pool_create_buffer);
        put32(buffer_req[8..12], buffer_id);
        putI32(buffer_req[12..16], 0);
        putI32(buffer_req[16..20], @intCast(w));
        putI32(buffer_req[20..24], @intCast(h));
        putI32(buffer_req[24..28], @intCast(stride));
        put32(buffer_req[28..32], shm_argb8888);
        try self.conn.writeAll(&buffer_req);
        try sendEmpty(&self.conn, pool_id, shm_pool_destroy);

        return .{ .id = buffer_id, .width = w, .height = h, .memory = memory };
    }

    fn discardIdleBuffersExcept(self: *Window, w: u32, h: u32) void {
        var i: usize = 0;
        while (i < self.buffers.items.len) {
            const buffer = self.buffers.items[i];
            if (!buffer.busy and (buffer.width != w or buffer.height != h)) {
                sendEmpty(&self.conn, buffer.id, buffer_destroy) catch {};
                var removed = self.buffers.swapRemove(i);
                removed.deinit();
            } else {
                i += 1;
            }
        }
    }

    fn destroyProtocolObjects(self: *Window) !void {
        for (self.buffers.items) |buffer| try sendEmpty(&self.conn, buffer.id, buffer_destroy);
        if (self.keyboard_id != 0 and self.seat_version >= 3) try sendEmpty(&self.conn, self.keyboard_id, keyboard_release);
        if (self.pointer_id != 0 and self.seat_version >= 3) try sendEmpty(&self.conn, self.pointer_id, pointer_release);
        if (self.touch_id != 0 and self.seat_version >= 3) try sendEmpty(&self.conn, self.touch_id, 0);
        if (self.data_source_id != 0) try sendEmpty(&self.conn, self.data_source_id, data_source_destroy);
        if (self.data_offer_id != 0) try sendEmpty(&self.conn, self.data_offer_id, data_offer_destroy);
        if (self.pending_offer_id != 0 and self.pending_offer_id != self.data_offer_id) try sendEmpty(&self.conn, self.pending_offer_id, data_offer_destroy);
        if (self.data_device_id != 0 and self.seat_version >= 3) try sendEmpty(&self.conn, self.data_device_id, data_device_release);
        if (self.primary_source_id != 0) try sendEmpty(&self.conn, self.primary_source_id, primary_source_destroy);
        if (self.primary_offer_id != 0) try sendEmpty(&self.conn, self.primary_offer_id, primary_offer_destroy);
        if (self.pending_primary_offer_id != 0 and self.pending_primary_offer_id != self.primary_offer_id) try sendEmpty(&self.conn, self.pending_primary_offer_id, primary_offer_destroy);
        if (self.primary_device_id != 0) try sendEmpty(&self.conn, self.primary_device_id, primary_device_destroy);
        if (self.viewport_id != 0) try sendEmpty(&self.conn, self.viewport_id, viewport_destroy);
        if (self.fractional_scale_id != 0) try sendEmpty(&self.conn, self.fractional_scale_id, 0);
        if (self.viewporter_id != 0) try sendEmpty(&self.conn, self.viewporter_id, 0);
        if (self.fractional_manager_id != 0) try sendEmpty(&self.conn, self.fractional_manager_id, 0);
        if (self.primary_manager_id != 0) try sendEmpty(&self.conn, self.primary_manager_id, 2);
        if (self.text_input_id != 0) try sendEmpty(&self.conn, self.text_input_id, text_input_destroy);
        if (self.text_input_manager_id != 0) try sendEmpty(&self.conn, self.text_input_manager_id, 0);
        if (self.cursor_shape_device_id != 0) try sendEmpty(&self.conn, self.cursor_shape_device_id, 0);
        if (self.cursor_shape_manager_id != 0) try sendEmpty(&self.conn, self.cursor_shape_manager_id, 0);
        if (self.cursor_surface_id != 0) try sendEmpty(&self.conn, self.cursor_surface_id, surface_destroy);
        if (self.cursor_buffer) |buffer| try sendEmpty(&self.conn, buffer.id, buffer_destroy);
        if (self.toplevel_icon_id != 0) try sendEmpty(&self.conn, self.toplevel_icon_id, 0);
        if (self.icon_buffer) |buffer| try sendEmpty(&self.conn, buffer.id, buffer_destroy);
        if (self.toplevel_icon_manager_id != 0) try sendEmpty(&self.conn, self.toplevel_icon_manager_id, 0);
        if (self.decoration_id != 0) try sendEmpty(&self.conn, self.decoration_id, 0);
        if (self.decoration_manager_id != 0) try sendEmpty(&self.conn, self.decoration_manager_id, 0);
        if (self.activation_id != 0) try sendEmpty(&self.conn, self.activation_id, 0);
        if (self.xdg_toplevel_id != 0) try sendEmpty(&self.conn, self.xdg_toplevel_id, xdg_toplevel_destroy);
        if (self.xdg_surface_id != 0) try sendEmpty(&self.conn, self.xdg_surface_id, xdg_surface_destroy);
        if (self.surface_id != 0) try sendEmpty(&self.conn, self.surface_id, surface_destroy);
        if (self.xdg_wm_base_id != 0) try sendEmpty(&self.conn, self.xdg_wm_base_id, xdg_wm_base_destroy);
        if (self.seat_id != 0 and self.seat_version >= 5) try sendEmpty(&self.conn, self.seat_id, seat_release);
    }
};

const RegistryGlobal = struct {
    name: u32,
    interface: []const u8,
    version: u32,
};

fn parseRegistryGlobal(body: []const u8) !RegistryGlobal {
    if (body.len < 12) return error.InvalidWaylandMessage;
    const name = get32(body[0..4]);
    const string_len: usize = @intCast(get32(body[4..8]));
    if (string_len == 0) return error.InvalidWaylandString;
    if (string_len > body.len - 8) return error.InvalidWaylandMessage;
    const string_end = 8 + string_len;
    const version_off = 8 + pad4(string_len);
    if (string_end > body.len or version_off + 4 != body.len or body[string_end - 1] != 0) {
        return error.InvalidWaylandMessage;
    }
    return .{
        .name = name,
        .interface = body[8 .. string_end - 1],
        .version = get32(body[version_off .. version_off + 4]),
    };
}

fn parseWireString(body: []const u8) ![]const u8 {
    if (body.len < 4) return error.InvalidWaylandMessage;
    const length: usize = @intCast(get32(body[0..4]));
    if (length == 0) {
        if (body.len != 4) return error.InvalidWaylandMessage;
        return "";
    }
    if (length > body.len - 4 or body.len != 4 + pad4(length) or body[3 + length] != 0)
        return error.InvalidWaylandMessage;
    return body[4 .. 3 + length];
}

fn parseLeadingString(body: []const u8) ![]const u8 {
    if (body.len < 4) return error.InvalidWaylandMessage;
    const length: usize = @intCast(get32(body[0..4]));
    if (length == 0) return "";
    if (length > body.len - 4 or body[3 + length] != 0) return error.InvalidWaylandMessage;
    return body[4 .. 3 + length];
}

fn sendBind(
    conn: *Connection,
    gpa: std.mem.Allocator,
    registry: u32,
    global: Global,
    interface: []const u8,
    version: u32,
    id: u32,
) !void {
    const string_size = try encodedStringSize(interface);
    const total = try std.math.add(usize, 20, string_size);
    if (total > std.math.maxInt(u16)) return error.WaylandMessageTooLarge;
    const req = try gpa.alloc(u8, total);
    defer gpa.free(req);
    @memset(req, 0);
    header(req, registry, registry_bind);
    put32(req[8..12], global.name);
    encodeString(req[12 .. 12 + string_size], interface);
    put32(req[12 + string_size .. 16 + string_size], version);
    put32(req[16 + string_size .. 20 + string_size], id);
    try conn.writeAll(req);
}

fn sendReceiveFd(conn: *Connection, object: u32, opcode: u16, mime: []const u8, fd_value: i32) !void {
    const string_size = try encodedStringSize(mime);
    const total = try std.math.add(usize, 8, string_size);
    if (total > 64) return error.WaylandMessageTooLarge;
    var req: [64]u8 = @splat(0);
    header(req[0..total], object, opcode);
    encodeString(req[8 .. 8 + string_size], mime);
    try conn.writeWithFd(req[0..total], fd_value);
}

fn writeAllFd(fd_value: i32, bytes: []const u8) !void {
    var off: usize = 0;
    while (off < bytes.len) {
        const n = linux.write(fd_value, bytes[off..].ptr, bytes.len - off);
        switch (linux.errno(n)) {
            .SUCCESS => {
                if (n == 0) return error.WriteZero;
                off += @intCast(n);
            },
            .INTR => continue,
            else => return error.WriteFailed,
        }
    }
}

fn readFdAll(gpa: std.mem.Allocator, fd_value: i32, limit: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var scratch: [4096]u8 = undefined;
    while (out.items.len < limit) {
        const n = linux.read(fd_value, &scratch, @min(scratch.len, limit - out.items.len));
        switch (linux.errno(n)) {
            .SUCCESS => {
                if (n == 0) break;
                try out.appendSlice(gpa, scratch[0..@intCast(n)]);
            },
            .INTR => continue,
            else => return error.ReadFailed,
        }
    }
    return out.toOwnedSlice(gpa);
}

fn sendString(conn: *Connection, gpa: std.mem.Allocator, object: u32, opcode: u16, value: []const u8) !void {
    const string_size = try encodedStringSize(value);
    const total = try std.math.add(usize, 8, string_size);
    if (total > std.math.maxInt(u16)) return error.WaylandMessageTooLarge;
    const req = try gpa.alloc(u8, total);
    defer gpa.free(req);
    @memset(req, 0);
    header(req, object, opcode);
    encodeString(req[8..], value);
    try conn.writeAll(req);
}

fn sendStringU32(conn: *Connection, gpa: std.mem.Allocator, object: u32, opcode: u16, value: []const u8, extra: u32) !void {
    const string_size = try encodedStringSize(value);
    const total = try std.math.add(usize, 12, string_size);
    if (total > std.math.maxInt(u16)) return error.WaylandMessageTooLarge;
    const req = try gpa.alloc(u8, total);
    defer gpa.free(req);
    @memset(req, 0);
    header(req, object, opcode);
    encodeString(req[8..], value);
    put32(req[8 + string_size ..][0..4], extra);
    try conn.writeAll(req);
}

fn sendEmpty(conn: *Connection, object: u32, opcode: u16) !void {
    var req: [8]u8 = @splat(0);
    header(&req, object, opcode);
    try conn.writeAll(&req);
}

fn sendOneU32(conn: *Connection, object: u32, opcode: u16, a: u32) !void {
    var req: [12]u8 = @splat(0);
    header(&req, object, opcode);
    put32(req[8..12], a);
    try conn.writeAll(&req);
}

fn sendTwoU32(conn: *Connection, object: u32, opcode: u16, a: u32, b: u32) !void {
    var req: [16]u8 = @splat(0);
    header(&req, object, opcode);
    put32(req[8..12], a);
    put32(req[12..16], b);
    try conn.writeAll(&req);
}

fn sendAccept(conn: *Connection, gpa: std.mem.Allocator, object: u32, opcode: u16, serial: u32, mime: []const u8) !void {
    const string_size = try encodedStringSize(mime);
    const total = try std.math.add(usize, 12, string_size);
    if (total > std.math.maxInt(u16)) return error.WaylandMessageTooLarge;
    const req = try gpa.alloc(u8, total);
    defer gpa.free(req);
    @memset(req, 0);
    header(req, object, opcode);
    put32(req[8..12], serial);
    encodeString(req[12..], mime);
    try conn.writeAll(req);
}

fn sendFourI32(conn: *Connection, object: u32, opcode: u16, a: i32, b: i32, c: i32, d: i32) !void {
    var req: [24]u8 = @splat(0);
    header(&req, object, opcode);
    putI32(req[8..12], a);
    putI32(req[12..16], b);
    putI32(req[16..20], c);
    putI32(req[20..24], d);
    try conn.writeAll(&req);
}

fn decodeClipboardBytes(gpa: std.mem.Allocator, text: []u8) ![]u8 {
    const decoded = services.clipboardBytesToUtf8(gpa, text) catch return text;
    gpa.free(text);
    return decoded;
}

fn sendSetCursor(conn: *Connection, pointer: u32, serial: u32, surface: u32, hotspot_x: i32, hotspot_y: i32) !void {
    var req: [24]u8 = @splat(0);
    header(&req, pointer, pointer_set_cursor);
    put32(req[8..12], serial);
    put32(req[12..16], surface);
    putI32(req[16..20], hotspot_x);
    putI32(req[20..24], hotspot_y);
    try conn.writeAll(&req);
}

fn sendAttach(conn: *Connection, surface: u32, buffer: u32) !void {
    var req: [20]u8 = @splat(0);
    header(&req, surface, surface_attach);
    put32(req[8..12], buffer);
    // x and y are both zero
    try conn.writeAll(&req);
}

fn sendDamage(conn: *Connection, surface: u32, opcode: u16, w: u32, h: u32) !void {
    var req: [24]u8 = @splat(0);
    header(&req, surface, opcode);
    putI32(req[16..20], @intCast(w));
    putI32(req[20..24], @intCast(h));
    try conn.writeAll(&req);
}

fn encodedStringSize(value: []const u8) !usize {
    if (std.mem.indexOfScalar(u8, value, 0) != null) return error.InvalidWaylandString;
    if (value.len > std.math.maxInt(u16) - 8) return error.WaylandMessageTooLarge;
    const with_nul = try std.math.add(usize, value.len, 1);
    return pad4(with_nul) + 4;
}

fn encodeString(dst: []u8, value: []const u8) void {
    const with_nul = value.len + 1;
    put32(dst[0..4], @intCast(with_nul));
    @memcpy(dst[4 .. 4 + value.len], value);
    dst[4 + value.len] = 0;
}

fn header(bytes: []u8, object: u32, opcode: u16) void {
    std.debug.assert(bytes.len >= 8 and bytes.len <= std.math.maxInt(u16) and (bytes.len & 3) == 0);
    put32(bytes[0..4], object);
    put32(bytes[4..8], (@as(u32, @intCast(bytes.len)) << 16) | opcode);
}

fn namedKeyToKey(named: xkb.NamedKey) Key {
    return switch (named) {
        .backspace => .backspace,
        .enter => .enter,
        .escape => .escape,
        .tab => .tab,
        .left => .left,
        .right => .right,
        .up => .up,
        .down => .down,
        .home => .home,
        .end => .end,
        .page_up => .page_up,
        .page_down => .page_down,
        .delete => .delete,
    };
}

fn imeCursorRect(width: u32, height: u32) struct { x: i32, y: i32, w: i32, h: i32 } {
    const margin = ime_cursor_margin;
    const strip = ime_cursor_height;
    const w: i32 = @intCast(width);
    const h: i32 = @intCast(height);
    const box_w = if (w > margin * 2) w - margin * 2 else w;
    const box_h = if (h >= strip) strip else h;
    const y = if (h > box_h) h - box_h else 0;
    const x = if (w > box_w) margin else 0;
    return .{ .x = x, .y = y, .w = box_w, .h = box_h };
}

fn shouldSuppressImeDuplicate(last: ?u21, key: Key) bool {
    const committed = last orelse return false;
    return switch (key) {
        .char => |ch| ch == committed,
        else => false,
    };
}

fn decorationModeIsClientSide(mode: u32) bool {
    return mode == decoration_mode_client_side;
}

fn capsLockFromLocked(locked: u32, current: bool, from_compositor: *bool) bool {
    if (locked & xkb_mod_lock != 0) {
        from_compositor.* = true;
        return true;
    }
    if (from_compositor.*) return false;
    return current;
}

fn clampToBounds(value: i32, bound: i32) i32 {
    if (value > 0 and bound > 0 and value > bound) return bound;
    return value;
}

fn configureContainsState(bytes: []const u8, state: u32) bool {
    var off: usize = 0;
    while (off + 4 <= bytes.len) : (off += 4) {
        if (get32(bytes[off..][0..4]) == state) return true;
    }
    return false;
}

fn isPlainTextMime(mime: []const u8) bool {
    return knownTextMime(mime) != null;
}

fn knownTextMime(mime: []const u8) ?[]const u8 {
    for (text_mime_types) |known| {
        if (std.ascii.eqlIgnoreCase(mime, known)) return known;
    }
    for (utf16_mime_types) |known| {
        if (std.ascii.eqlIgnoreCase(mime, known)) return known;
    }
    for (html_mime_types) |known| {
        if (std.ascii.eqlIgnoreCase(mime, known)) return known;
    }
    for (desktop_file_mime_types) |known| {
        if (std.ascii.eqlIgnoreCase(mime, known)) return known;
    }
    if (services.isHtmlMime(mime)) return "text/html";
    if (services.isDesktopFileMime(mime)) return "x-special/gnome-copied-files";
    return null;
}

fn textMimeRank(mime: []const u8) u8 {
    if (std.mem.eql(u8, mime, "text/plain;charset=utf-8")) return 6;
    if (std.mem.eql(u8, mime, "text/plain;charset=utf8")) return 5;
    if (std.mem.eql(u8, mime, "text/plain")) return 4;
    if (std.mem.eql(u8, mime, "UTF8_STRING")) return 3;
    if (std.mem.eql(u8, mime, "text/plain;charset=utf-16") or std.mem.eql(u8, mime, "UTF16_STRING")) return 3;
    if (std.mem.eql(u8, mime, "text/uri-list") or services.isDesktopFileMime(mime)) return 2;
    if (std.mem.eql(u8, mime, "TEXT") or std.mem.eql(u8, mime, "STRING")) return 1;
    if (services.isHtmlMime(mime)) return 1;
    return 0;
}

const HeldMods = struct {
    shift: bool = false,
    control: bool = false,
    alt: bool = false,
    super: bool = false,
};

fn heldModsFromKeyArray(keys: []const u8) HeldMods {
    var mods: HeldMods = .{};
    var off: usize = 0;
    while (off + 4 <= keys.len) : (off += 4) {
        switch (get32(keys[off..][0..4])) {
            42, 54 => mods.shift = true,
            29, 97 => mods.control = true,
            56, 100 => mods.alt = true,
            125, 126 => mods.super = true,
            else => {},
        }
    }
    return mods;
}

fn isModifierEvdev(code: u32) bool {
    return switch (code) {
        29, 42, 54, 56, 58, 97, 100, 125, 126 => true,
        else => false,
    };
}

fn heldNonModifierFromKeyArray(keys: []const u8) ?u32 {
    var off: usize = 0;
    while (off + 4 <= keys.len) : (off += 4) {
        const code = get32(keys[off..][0..4]);
        if (!isModifierEvdev(code)) return code;
    }
    return null;
}

fn evdevToKey(code: u32, shift: bool, caps_lock: bool) Key {
    return switch (code) {
        1 => .escape,
        14 => .backspace,
        15 => .tab,
        28, 96 => .enter,
        102 => .home,
        103 => .up,
        104 => .page_up,
        105 => .left,
        106 => .right,
        107 => .end,
        108 => .down,
        109 => .page_down,
        111 => .delete,
        2 => asciiPair('1', '!', shift),
        3 => asciiPair('2', '@', shift),
        4 => asciiPair('3', '#', shift),
        5 => asciiPair('4', '$', shift),
        6 => asciiPair('5', '%', shift),
        7 => asciiPair('6', '^', shift),
        8 => asciiPair('7', '&', shift),
        9 => asciiPair('8', '*', shift),
        10 => asciiPair('9', '(', shift),
        11 => asciiPair('0', ')', shift),
        12 => asciiPair('-', '_', shift),
        13 => asciiPair('=', '+', shift),
        16 => asciiLetter('q', shift, caps_lock),
        17 => asciiLetter('w', shift, caps_lock),
        18 => asciiLetter('e', shift, caps_lock),
        19 => asciiLetter('r', shift, caps_lock),
        20 => asciiLetter('t', shift, caps_lock),
        21 => asciiLetter('y', shift, caps_lock),
        22 => asciiLetter('u', shift, caps_lock),
        23 => asciiLetter('i', shift, caps_lock),
        24 => asciiLetter('o', shift, caps_lock),
        25 => asciiLetter('p', shift, caps_lock),
        26 => asciiPair('[', '{', shift),
        27 => asciiPair(']', '}', shift),
        30 => asciiLetter('a', shift, caps_lock),
        31 => asciiLetter('s', shift, caps_lock),
        32 => asciiLetter('d', shift, caps_lock),
        33 => asciiLetter('f', shift, caps_lock),
        34 => asciiLetter('g', shift, caps_lock),
        35 => asciiLetter('h', shift, caps_lock),
        36 => asciiLetter('j', shift, caps_lock),
        37 => asciiLetter('k', shift, caps_lock),
        38 => asciiLetter('l', shift, caps_lock),
        39 => asciiPair(';', ':', shift),
        40 => asciiPair('\'', '"', shift),
        41 => asciiPair('`', '~', shift),
        43 => asciiPair('\\', '|', shift),
        44 => asciiLetter('z', shift, caps_lock),
        45 => asciiLetter('x', shift, caps_lock),
        46 => asciiLetter('c', shift, caps_lock),
        47 => asciiLetter('v', shift, caps_lock),
        48 => asciiLetter('b', shift, caps_lock),
        49 => asciiLetter('n', shift, caps_lock),
        50 => asciiLetter('m', shift, caps_lock),
        51 => asciiPair(',', '<', shift),
        52 => asciiPair('.', '>', shift),
        53 => asciiPair('/', '?', shift),
        57 => .{ .char = ' ' },
        else => .other,
    };
}

fn asciiPair(normal: u8, shifted: u8, shift: bool) Key {
    return .{ .char = if (shift) shifted else normal };
}

fn asciiLetter(lower: u8, shift: bool, caps_lock: bool) Key {
    return .{ .char = if (shift != caps_lock) lower - ('a' - 'A') else lower };
}

fn waylandSocketPath(gpa: std.mem.Allocator) ![]u8 {
    const env = try services.readEnviron(gpa);
    defer gpa.free(env);
    return socketPathFromEnvironment(gpa, env);
}

fn socketPathFromEnvironment(gpa: std.mem.Allocator, env: []const u8) ![]u8 {
    const display = environmentValue(env, "WAYLAND_DISPLAY") orelse "wayland-0";
    if (display.len == 0) return error.WaylandDisplayUnset;
    if (display[0] == '/') return gpa.dupe(u8, display);
    const runtime = environmentValue(env, "XDG_RUNTIME_DIR") orelse return error.XdgRuntimeDirUnset;
    if (runtime.len == 0) return error.XdgRuntimeDirUnset;
    return std.fmt.allocPrint(gpa, "{s}/{s}", .{ std.mem.trimEnd(u8, runtime, "/"), display });
}

fn environmentValue(env: []const u8, name: []const u8) ?[]const u8 {
    var start: usize = 0;
    while (start < env.len) {
        const rest = env[start..];
        const item_len = std.mem.indexOfScalar(u8, rest, 0) orelse rest.len;
        const item = rest[0..item_len];
        if (item.len > name.len and item[name.len] == '=' and std.mem.eql(u8, item[0..name.len], name)) {
            return item[name.len + 1 ..];
        }
        start += item_len + 1;
    }
    return null;
}

fn openUnixSocket(io: std.Io, path: []const u8) !net.Stream {
    return services.connectUnixStream(io, path) catch |err| switch (err) {
        error.ServerUnavailable => error.WaylandUnavailable,
        error.AccessDenied => error.AccessDenied,
        else => err,
    };
}

fn scale120(logical: u32, scale: u32) u32 {
    const value = (@as(u64, logical) * scale + 60) / 120;
    return @intCast(@max(1, value));
}

fn scaleNearestTo(dst: []u32, src: []const u32, src_w: u32, src_h: u32, dst_w: u32, dst_h: u32) void {
    if (src_w == 0 or src_h == 0 or dst_w == 0 or dst_h == 0) return;
    var y: u32 = 0;
    while (y < dst_h) : (y += 1) {
        const sy = y * src_h / dst_h;
        var x: u32 = 0;
        while (x < dst_w) : (x += 1) {
            const sx = x * src_w / dst_w;
            dst[@as(usize, y) * dst_w + x] = src[@as(usize, sy) * src_w + sx];
        }
    }
}

fn truncateFd(fd_value: i32, length: i64) !void {
    const rc = linux.ftruncate(fd_value, length);
    switch (linux.errno(rc)) {
        .SUCCESS => {},
        .INTR => return truncateFd(fd_value, length),
        .FBIG => return error.FileTooBig,
        .NOSPC => return error.NoSpaceLeft,
        else => return error.TruncateFailed,
    }
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

fn readSomeFd(fd_value: i32, dst: []u8) !usize {
    while (true) {
        const rc = linux.read(fd_value, dst.ptr, dst.len);
        switch (linux.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            else => return error.ReadFailed,
        }
    }
}

pub fn pad4(n: usize) usize {
    return (n + 3) & ~@as(usize, 3);
}

fn alignForward(n: usize, alignment: usize) usize {
    return (n + alignment - 1) & ~(alignment - 1);
}

/// Mirrors main.zig's own `monotonicMilliseconds` exactly (same clock, same
/// non-negative clamp) so key-repeat timing recorded here and the poll
/// loop's `checkRepeat` calls agree, whichever `Io` handle each reads it
/// through.
fn nowMs(io: std.Io) u64 {
    const milliseconds = std.Io.Clock.awake.now(io).toMilliseconds();
    return if (milliseconds > 0) @intCast(milliseconds) else 0;
}

fn get32(bytes: []const u8) u32 {
    return std.mem.readInt(u32, bytes[0..4], .native);
}

fn getI32(bytes: []const u8) i32 {
    return @bitCast(get32(bytes));
}

fn put32(bytes: []u8, value: u32) void {
    std.mem.writeInt(u32, bytes[0..4], value, .native);
}

fn putI32(bytes: []u8, value: i32) void {
    put32(bytes, @bitCast(value));
}

// --- Pure protocol and translation tests ------------------------------------

test "Wayland header packs object size and opcode" {
    var req: [12]u8 = @splat(0);
    header(&req, 0x10203040, 0x55aa);
    try std.testing.expectEqual(@as(u32, 0x10203040), get32(req[0..4]));
    try std.testing.expectEqual(@as(u32, 0x000c55aa), get32(req[4..8]));
}

test "Wayland strings include nul and four-byte padding" {
    try std.testing.expectEqual(@as(usize, 8), try encodedStringSize("abc"));
    try std.testing.expectEqual(@as(usize, 12), try encodedStringSize("abcd"));
    var bytes: [12]u8 = @splat(0xcc);
    encodeString(&bytes, "hello");
    try std.testing.expectEqual(@as(u32, 6), get32(bytes[0..4]));
    try std.testing.expectEqualSlices(u8, "hello\x00", bytes[4..10]);
    try std.testing.expectError(error.InvalidWaylandString, encodedStringSize("a\x00b"));
}

test "registry global parser follows Wayland string alignment" {
    var body: [28]u8 = @splat(0);
    put32(body[0..4], 17);
    put32(body[4..8], 14); // "wl_compositor" plus nul
    @memcpy(body[8..21], "wl_compositor");
    body[21] = 0;
    put32(body[24..28], 6);
    const global = try parseRegistryGlobal(&body);
    try std.testing.expectEqual(@as(u32, 17), global.name);
    try std.testing.expectEqualStrings("wl_compositor", global.interface);
    try std.testing.expectEqual(@as(u32, 6), global.version);
}

test "Wayland socket path honors absolute display and runtime directory" {
    const gpa = std.testing.allocator;
    const relative = try socketPathFromEnvironment(gpa, "XDG_RUNTIME_DIR=/run/user/1000\x00WAYLAND_DISPLAY=wayland-2\x00");
    defer gpa.free(relative);
    try std.testing.expectEqualStrings("/run/user/1000/wayland-2", relative);

    const absolute = try socketPathFromEnvironment(gpa, "WAYLAND_DISPLAY=/tmp/nested/wayland.sock\x00");
    defer gpa.free(absolute);
    try std.testing.expectEqualStrings("/tmp/nested/wayland.sock", absolute);
    try std.testing.expectError(error.XdgRuntimeDirUnset, socketPathFromEnvironment(gpa, "A=B\x00"));
}

test "US evdev fallback maps text modifiers and navigation" {
    try std.testing.expectEqual(Key{ .char = 'a' }, evdevToKey(30, false, false));
    try std.testing.expectEqual(Key{ .char = 'A' }, evdevToKey(30, true, false));
    try std.testing.expectEqual(Key{ .char = 'A' }, evdevToKey(30, false, true));
    try std.testing.expectEqual(Key{ .char = 'a' }, evdevToKey(30, true, true));
    try std.testing.expectEqual(Key{ .char = '!' }, evdevToKey(2, true, false));
    try std.testing.expectEqual(Key.left, evdevToKey(105, false, false));
    try std.testing.expectEqual(Key.delete, evdevToKey(111, false, false));
    try std.testing.expectEqual(Key.other, evdevToKey(59, false, false));
}

test "SCM control alignment is sufficient for one fd" {
    const head = alignForward(@sizeOf(linux.cmsghdr), @alignOf(linux.cmsghdr));
    const space = head + alignForward(@sizeOf(i32), @alignOf(linux.cmsghdr));
    try std.testing.expect(space >= @sizeOf(linux.cmsghdr) + @sizeOf(i32));
    try std.testing.expectEqual(@as(usize, 0), head % @alignOf(i32));
}

test "Wayland fd request transfers SCM_RIGHTS without a wire placeholder" {
    var sockets: [2]i32 = undefined;
    const pair_rc = linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0, &sockets);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(pair_rc));
    defer _ = linux.close(sockets[0]);
    defer _ = linux.close(sockets[1]);

    const sent_fd = try posix.memfd_create("comicchat-wayland-test", linux.MFD.CLOEXEC);
    defer _ = linux.close(sent_fd);

    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    var conn = Connection{
        .io = threaded.io(),
        .stream = .{ .socket = .{ .handle = sockets[0], .address = undefined } },
    };
    var request: [16]u8 = @splat(0);
    header(&request, 7, shm_create_pool);
    put32(request[8..12], 8);
    putI32(request[12..16], 4096);
    try conn.writeWithFd(&request, sent_fd);

    var received: [16]u8 = undefined;
    var control: [64]u8 align(@alignOf(linux.cmsghdr)) = @splat(0);
    var iov: posix.iovec = .{ .base = &received, .len = received.len };
    var msg: linux.msghdr = .{
        .name = null,
        .namelen = 0,
        .iov = (&iov)[0..1],
        .iovlen = 1,
        .control = &control,
        .controllen = control.len,
        .flags = 0,
    };
    const recv_rc = linux.recvmsg(sockets[1], &msg, linux.MSG.CMSG_CLOEXEC);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(recv_rc));
    try std.testing.expectEqual(request.len, @as(usize, @intCast(recv_rc)));
    try std.testing.expectEqualSlices(u8, &request, &received);

    const cmsg: *const linux.cmsghdr = @ptrCast(&control);
    try std.testing.expectEqual(linux.SOL.SOCKET, cmsg.level);
    try std.testing.expectEqual(@as(i32, linux.SCM.RIGHTS), cmsg.type);
    const fd_off = alignForward(@sizeOf(linux.cmsghdr), @alignOf(linux.cmsghdr));
    const received_fd = @as(*const i32, @ptrCast(@alignCast(control[fd_off..].ptr))).*;
    defer _ = linux.close(received_fd);
    try std.testing.expect(received_fd >= 0);
}

test "protocol-only Wayland message returns other without a second blocking read" {
    var sockets: [2]i32 = undefined;
    const pair_rc = linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0, &sockets);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(pair_rc));
    defer _ = linux.close(sockets[0]);
    defer _ = linux.close(sockets[1]);

    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    var window = Window{
        .gpa = std.testing.allocator,
        .threaded = undefined,
        .conn = .{
            .io = threaded.io(),
            .stream = .{ .socket = .{ .handle = sockets[0], .address = undefined } },
        },
        .surface_id = 42,
        .width = 1,
        .height = 1,
    };

    var wire: [8]u8 = @splat(0);
    header(&wire, window.surface_id, 0);
    const written = linux.write(sockets[1], &wire, wire.len);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(written));
    try std.testing.expectEqual(wire.len, @as(usize, @intCast(written)));
    // A regression to the old "loop until visible" implementation observes
    // EOF here and fails instead of returning the protocol-only event.
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.shutdown(sockets[1], linux.SHUT.WR)));

    try std.testing.expectEqual(Event.other, try window.nextEvent());
}

test "readMessage captures an SCM_RIGHTS fd sent alongside the wire message" {
    var sockets: [2]i32 = undefined;
    const pair_rc = linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0, &sockets);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(pair_rc));
    defer _ = linux.close(sockets[0]);
    defer _ = linux.close(sockets[1]);

    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    var reader_conn = Connection{
        .io = threaded.io(),
        .stream = .{ .socket = .{ .handle = sockets[0], .address = undefined } },
    };

    // Mirror the compositor: one sendmsg carrying the wl_keyboard.keymap wire
    // bytes (object=99, opcode=0, body = format:u32=1, size:u32=4096) with an
    // SCM_RIGHTS fd attached, exactly as writeWithFd attaches one on the send
    // side this client already exercises.
    const keymap_fd = try posix.memfd_create("comicchat-wayland-keymap-test", linux.MFD.CLOEXEC);
    const marker = "xkb_keymap_marker";
    const write_rc = linux.write(keymap_fd, marker.ptr, marker.len);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(write_rc));
    try std.testing.expectEqual(marker.len, @as(usize, @intCast(write_rc)));

    var wire: [16]u8 = @splat(0);
    header(&wire, 99, 0);
    put32(wire[8..12], 1);
    put32(wire[12..16], 4096);

    var writer_conn = Connection{
        .io = threaded.io(),
        .stream = .{ .socket = .{ .handle = sockets[1], .address = undefined } },
    };
    try writer_conn.writeWithFd(&wire, keymap_fd);
    _ = linux.close(keymap_fd);

    const msg = try reader_conn.readMessage(std.testing.allocator);
    defer msg.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 99), msg.object);
    try std.testing.expectEqual(@as(u16, 0), msg.opcode);

    const received_fd = reader_conn.takePendingFd() orelse return error.TestExpectedFd;
    defer _ = linux.close(received_fd);
    // keymap_fd is already closed above; the kernel is free to recycle its
    // number for received_fd, so equality here is expected, not proof of a
    // bug. The content readback below is the real correctness proof: the
    // received descriptor genuinely refers to the memfd the writer sent.
    try std.testing.expectEqual(@as(u64, 0), linux.lseek(received_fd, 0, linux.SEEK.SET));
    var readback: [marker.len]u8 = undefined;
    const read_rc = linux.read(received_fd, &readback, readback.len);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(read_rc));
    try std.testing.expectEqual(readback.len, @as(usize, @intCast(read_rc)));
    try std.testing.expectEqualSlices(u8, marker, &readback);

    // The fd is claimed exactly once; a second take sees nothing left over.
    try std.testing.expectEqual(@as(?posix.fd_t, null), reader_conn.takePendingFd());
}

test "a real keymap event overrides evdevToKey's US table for the same physical key" {
    var sockets: [2]i32 = undefined;
    const pair_rc = linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0, &sockets);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(pair_rc));
    defer _ = linux.close(sockets[1]);

    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    var window = Window{
        .gpa = std.testing.allocator,
        .threaded = undefined,
        .conn = .{
            .io = threaded.io(),
            .stream = .{ .socket = .{ .handle = sockets[0], .address = undefined } },
        },
        .keyboard_id = 77,
        .width = 1,
        .height = 1,
    };
    defer _ = linux.close(sockets[0]);
    defer if (window.xkb_keymap) |*keymap| keymap.deinit();

    // A minimal synthetic layout that swaps evdev code 30 (the physical key
    // the US table maps to 'a'/'A') to 'q'/'Q', so a passing test proves the
    // keymap was genuinely consulted rather than coincidentally agreeing
    // with the fallback.
    const synthetic_keymap =
        \\xkb_keymap {
        \\  xkb_keycodes "test" {
        \\      <AC01> = 38;
        \\  };
        \\  xkb_symbols "test" {
        \\      key <AC01> { [ q, Q ] };
        \\  };
        \\};
    ;
    const keymap_fd = try posix.memfd_create("comicchat-wayland-keymap-e2e-test", linux.MFD.CLOEXEC);
    defer _ = linux.close(keymap_fd);
    const write_rc = linux.write(keymap_fd, synthetic_keymap.ptr, synthetic_keymap.len);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(write_rc));
    try std.testing.expectEqual(synthetic_keymap.len, @as(usize, @intCast(write_rc)));

    var writer_conn = Connection{
        .io = threaded.io(),
        .stream = .{ .socket = .{ .handle = sockets[1], .address = undefined } },
    };
    var keymap_wire: [16]u8 = @splat(0);
    header(&keymap_wire, window.keyboard_id, 0);
    put32(keymap_wire[8..12], 1); // format = XKB_V1_TEXT
    put32(keymap_wire[12..16], @intCast(synthetic_keymap.len));
    try writer_conn.writeWithFd(&keymap_wire, keymap_fd);

    try std.testing.expectEqual(Event.other, try window.nextEvent());
    try std.testing.expect(window.xkb_keymap != null);

    var key_wire: [24]u8 = @splat(0);
    header(&key_wire, window.keyboard_id, 3);
    put32(key_wire[8..12], 1); // serial
    put32(key_wire[12..16], 0); // time
    put32(key_wire[16..20], 30); // evdev code (the US table's 'a' key)
    put32(key_wire[20..24], 1); // state = pressed
    const key_written = linux.write(sockets[1], &key_wire, key_wire.len);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(key_written));
    try std.testing.expectEqual(key_wire.len, @as(usize, @intCast(key_written)));

    try std.testing.expectEqual(Event{ .key = .{ .key = .{ .char = 'q' } } }, try window.nextEvent());
}

fn checkRepeatTestWindow(threaded: *std.Io.Threaded) Window {
    return Window{
        .gpa = std.testing.allocator,
        .threaded = undefined,
        .conn = .{ .io = threaded.io(), .stream = .{ .socket = .{ .handle = -1, .address = undefined } } },
        .width = 1,
        .height = 1,
    };
}

test "checkRepeat is silent with no key held, a non-positive rate, or before the deadline" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    var window = checkRepeatTestWindow(&threaded);

    // Nothing held at all.
    try std.testing.expectEqual(@as(?Event, null), window.checkRepeat());

    // Held, but the compositor either never sent repeat_info or sent a
    // non-positive rate (repeat explicitly disabled per protocol convention).
    window.held_key_code = 30;
    window.repeat_rate_per_sec = 0;
    try std.testing.expectEqual(@as(?Event, null), window.checkRepeat());

    // Held with a valid rate, but the deadline is far in the future.
    window.repeat_rate_per_sec = 25;
    window.next_repeat_at_ms = nowMs(window.conn.io) +| 60_000;
    try std.testing.expectEqual(@as(?Event, null), window.checkRepeat());
}

test "checkRepeat fires once the deadline has passed and reschedules from now, not by accumulation" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    var window = checkRepeatTestWindow(&threaded);

    window.held_key_code = 30; // evdevToKey's 'a' key, no keymap loaded
    window.held_key_shift = false;
    window.repeat_rate_per_sec = 25; // interval = 40ms
    window.next_repeat_at_ms = nowMs(window.conn.io); // already due

    const before = window.next_repeat_at_ms;
    const event = window.checkRepeat();
    try std.testing.expectEqual(Event{ .key = .{ .key = .{ .char = 'a' } } }, event.?);
    // Rescheduled forward from *now* (>= before, by roughly one interval),
    // not left at the stale deadline that just fired.
    try std.testing.expect(window.next_repeat_at_ms >= before);

    // Immediately checking again is not yet due (the new deadline is ~40ms
    // out), proving this does not fire on every call once due.
    try std.testing.expectEqual(@as(?Event, null), window.checkRepeat());
}

test "releasing the held key stops repeat, and repeat_info updates rate/delay" {
    var sockets: [2]i32 = undefined;
    const pair_rc = linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0, &sockets);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(pair_rc));
    defer _ = linux.close(sockets[1]);

    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    var window = Window{
        .gpa = std.testing.allocator,
        .threaded = undefined,
        .conn = .{ .io = threaded.io(), .stream = .{ .socket = .{ .handle = sockets[0], .address = undefined } } },
        .keyboard_id = 55,
        .width = 1,
        .height = 1,
    };
    defer _ = linux.close(sockets[0]);

    var repeat_info_wire: [16]u8 = @splat(0);
    header(&repeat_info_wire, window.keyboard_id, 5);
    put32(repeat_info_wire[8..12], 33); // rate
    put32(repeat_info_wire[12..16], 500); // delay
    var wrote = linux.write(sockets[1], &repeat_info_wire, repeat_info_wire.len);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(wrote));
    try std.testing.expectEqual(Event.other, try window.nextEvent());
    try std.testing.expectEqual(@as(i32, 33), window.repeat_rate_per_sec);
    try std.testing.expectEqual(@as(i32, 500), window.repeat_delay_ms);

    var key_down: [24]u8 = @splat(0);
    header(&key_down, window.keyboard_id, 3);
    put32(key_down[16..20], 30);
    put32(key_down[20..24], 1); // pressed
    wrote = linux.write(sockets[1], &key_down, key_down.len);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(wrote));
    try std.testing.expectEqual(Event{ .key = .{ .key = .{ .char = 'a' } } }, try window.nextEvent());
    try std.testing.expectEqual(@as(?u32, 30), window.held_key_code);

    var key_up: [24]u8 = @splat(0);
    header(&key_up, window.keyboard_id, 3);
    put32(key_up[16..20], 30);
    put32(key_up[20..24], 0); // released
    wrote = linux.write(sockets[1], &key_up, key_up.len);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(wrote));
    try std.testing.expectEqual(Event.other, try window.nextEvent());
    try std.testing.expectEqual(@as(?u32, null), window.held_key_code);
    try std.testing.expectEqual(@as(?Event, null), window.checkRepeat());
}

test "Wayland Window entry points compile without a compositor" {
    // The invalid size returns before environment/socket access, while making
    // Zig analyze the complete native backend call graph.
    try std.testing.expectError(error.InvalidWindowSize, show(std.testing.allocator, &.{}, 0, 1));
}

test "Wayland output scale follows the entered surface, then the max bound output" {
    var window = Window{
        .gpa = std.testing.allocator,
        .threaded = undefined,
        .conn = .{ .io = undefined, .stream = .{ .socket = .{ .handle = -1, .address = undefined } } },
        .width = 1,
        .height = 1,
        .output_ids = .{ 10, 11, 0, 0, 0, 0, 0, 0 },
        .output_scales = .{ 1, 2, 1, 1, 1, 1, 1, 1 },
        .output_count = 2,
    };
    try std.testing.expectEqual(@as(u32, 2), window.currentOutputScale());
    window.entered_outputs[0] = 10;
    window.entered_count = 1;
    try std.testing.expectEqual(@as(u32, 1), window.currentOutputScale());
    window.entered_outputs[1] = 11;
    window.entered_count = 2;
    try std.testing.expectEqual(@as(u32, 2), window.currentOutputScale());
    window.preferred_buffer_scale = 3;
    try std.testing.expectEqual(@as(u32, 3), window.currentOutputScale());
    window.preferred_buffer_scale = 0;
    window.entered_count = 0;
    window.output_have_scale[0] = false;
    window.output_width_px[0] = 3840;
    window.output_width_mm[0] = 600;
    window.applyOutputMmScale(0);
    try std.testing.expectEqual(@as(u32, 2), window.output_scales[0]);
}

test "Wayland discrete axis wins over continuous axis in the same frame" {
    var sockets: [2]i32 = undefined;
    const pair_rc = linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0, &sockets);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(pair_rc));
    defer _ = linux.close(sockets[1]);

    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    var window = Window{
        .gpa = std.testing.allocator,
        .threaded = undefined,
        .conn = .{ .io = threaded.io(), .stream = .{ .socket = .{ .handle = sockets[0], .address = undefined } } },
        .pointer_id = 9,
        .width = 1,
        .height = 1,
    };
    defer _ = linux.close(sockets[0]);

    var discrete: [16]u8 = @splat(0);
    header(&discrete, window.pointer_id, 8);
    put32(discrete[8..12], 0);
    putI32(discrete[12..16], -1);
    var wrote = linux.write(sockets[1], &discrete, discrete.len);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(wrote));
    try std.testing.expectEqual(Event{ .pointer = .{ .kind = .wheel, .x = 0, .y = 0, .wheel_y = 1 } }, try window.nextEvent());

    var axis: [20]u8 = @splat(0);
    header(&axis, window.pointer_id, 4);
    put32(axis[12..16], 0);
    putI32(axis[16..20], 2560);
    wrote = linux.write(sockets[1], &axis, axis.len);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(wrote));
    try std.testing.expectEqual(Event.other, try window.nextEvent());
}

test "fractional scale 120ths rounds to the nearest buffer size" {
    try std.testing.expectEqual(@as(u32, 100), scale120(100, 120));
    try std.testing.expectEqual(@as(u32, 150), scale120(100, 180));
    try std.testing.expectEqual(@as(u32, 200), scale120(100, 240));
    try std.testing.expectEqual(@as(u32, 1), scale120(0, 180));
}

test "Wayland bufferDimensions prefers fractional viewport over integer output scale" {
    var window = Window{
        .gpa = std.testing.allocator,
        .threaded = undefined,
        .conn = undefined,
        .width = 320,
        .height = 240,
        .output_scale = 2,
        .viewport_id = 7,
        .fractional_scale_120 = 180,
    };
    const dims = window.bufferDimensions(320, 240);
    try std.testing.expect(dims.use_viewport);
    try std.testing.expectEqual(@as(u32, 480), dims.w);
    try std.testing.expectEqual(@as(u32, 360), dims.h);

    window.fractional_scale_120 = 0;
    const fallback = window.bufferDimensions(320, 240);
    try std.testing.expect(!fallback.use_viewport);
    try std.testing.expectEqual(@as(u32, 640), fallback.w);
}

test "nearest-neighbor scale fills an arbitrary destination size" {
    var out: [6]u32 = undefined;
    scaleNearestTo(&out, &[_]u32{ 1, 2 }, 2, 1, 3, 2);
    try std.testing.expectEqual(@as(u32, 1), out[0]);
    try std.testing.expectEqual(@as(u32, 1), out[1]);
    try std.testing.expectEqual(@as(u32, 2), out[2]);
    try std.testing.expectEqual(@as(u32, 1), out[3]);
    try std.testing.expectEqual(@as(u32, 1), out[4]);
    try std.testing.expectEqual(@as(u32, 2), out[5]);
}

test "registry records fractional scale, viewporter, and primary selection" {
    var globals: Globals = .{};
    globals.record(3, "wp_viewporter", 1);
    globals.record(4, "wp_fractional_scale_manager_v1", 1);
    globals.record(5, "zwp_primary_selection_device_manager_v1", 1);
    globals.record(6, "wp_cursor_shape_manager_v1", 1);
    globals.record(7, "xdg_toplevel_icon_manager_v1", 1);
    globals.record(8, "zxdg_decoration_manager_v1", 1);
    globals.record(9, "xdg_activation_v1", 1);
    try std.testing.expectEqual(@as(u32, 3), globals.viewporter.name);
    try std.testing.expectEqual(@as(u32, 4), globals.fractional_manager.name);
    try std.testing.expectEqual(@as(u32, 5), globals.primary_manager.name);
    try std.testing.expectEqual(@as(u32, 6), globals.cursor_shape_manager.name);
    try std.testing.expectEqual(@as(u32, 7), globals.toplevel_icon_manager.name);
    try std.testing.expectEqual(@as(u32, 8), globals.decoration_manager.name);
    try std.testing.expect(globals.decoration_zxdg);
    try std.testing.expectEqual(@as(u32, 9), globals.activation.name);
}

test "plain-text MIME set covers UTF-8 and ICCCM names" {
    try std.testing.expect(isPlainTextMime("text/plain;charset=utf-8"));
    try std.testing.expect(isPlainTextMime("text/plain;charset=utf8"));
    try std.testing.expect(isPlainTextMime("text/uri-list"));
    try std.testing.expect(isPlainTextMime("TEXT"));
    try std.testing.expect(isPlainTextMime("UTF8_STRING"));
    try std.testing.expect(isPlainTextMime("text/plain;charset=utf-16"));
    try std.testing.expect(isPlainTextMime("UTF16_STRING"));
    try std.testing.expect(isPlainTextMime("text/html"));
    try std.testing.expect(isPlainTextMime("text/html;charset=utf-8"));
    try std.testing.expect(isPlainTextMime("x-special/gnome-copied-files"));
    try std.testing.expect(isPlainTextMime("text/x-moz-url"));
    try std.testing.expect(isPlainTextMime("application/x-moz-file"));
    try std.testing.expect(!isPlainTextMime("image/png"));
    try std.testing.expect(textMimeRank("text/plain;charset=utf-8") > textMimeRank("text/uri-list"));
    try std.testing.expect(textMimeRank("text/plain;charset=utf-8") > textMimeRank("UTF16_STRING"));
    try std.testing.expectEqual(textMimeRank("text/uri-list"), textMimeRank("x-special/gnome-copied-files"));
}

test "keyboard-enter key array restores held modifiers" {
    var keys: [8]u8 = undefined;
    put32(keys[0..4], 42);
    put32(keys[4..8], 29);
    const mods = heldModsFromKeyArray(&keys);
    try std.testing.expect(mods.shift);
    try std.testing.expect(mods.control);
    try std.testing.expect(!mods.alt);
    try std.testing.expect(!mods.super);
    try std.testing.expect(!heldModsFromKeyArray(&.{}).shift);
    var mixed: [8]u8 = undefined;
    put32(mixed[0..4], 42);
    put32(mixed[4..8], 30);
    try std.testing.expectEqual(@as(u32, 30), heldNonModifierFromKeyArray(&mixed).?);
    try std.testing.expect(heldNonModifierFromKeyArray(keys[0..4]) == null);
}

test "IME cursor rectangle sits on the bottom composer strip" {
    const rect = imeCursorRect(640, 480);
    try std.testing.expectEqual(@as(i32, 8), rect.x);
    try std.testing.expectEqual(@as(i32, 456), rect.y);
    try std.testing.expectEqual(@as(i32, 624), rect.w);
    try std.testing.expectEqual(@as(i32, 24), rect.h);
    const tiny = imeCursorRect(10, 10);
    try std.testing.expectEqual(@as(i32, 0), tiny.y);
    try std.testing.expectEqual(@as(i32, 10), tiny.h);
}

test "IME de-dupe swallows only the confirming committed character" {
    try std.testing.expect(shouldSuppressImeDuplicate(0xe9, .{ .char = 0xe9 }));
    try std.testing.expect(!shouldSuppressImeDuplicate(0xe9, .{ .char = 'e' }));
    try std.testing.expect(!shouldSuppressImeDuplicate(0xe9, .enter));
    try std.testing.expect(!shouldSuppressImeDuplicate(null, .{ .char = 'a' }));
}

test "xdg toplevel configure states include activated" {
    var states: [8]u8 = undefined;
    put32(states[0..4], 1);
    put32(states[4..8], 4);
    try std.testing.expect(configureContainsState(&states, xdg_state_activated));
    try std.testing.expect(configureContainsState(&states, xdg_state_maximized));
    try std.testing.expect(!configureContainsState(states[0..4], xdg_state_activated));
    var fullscreen: [4]u8 = undefined;
    put32(fullscreen[0..4], xdg_state_fullscreen);
    try std.testing.expect(configureContainsState(&fullscreen, xdg_state_fullscreen));
    try std.testing.expect(!configureContainsState(&fullscreen, xdg_state_maximized));
    var tiled: [4]u8 = undefined;
    put32(tiled[0..4], xdg_state_tiled_left);
    try std.testing.expect(configureContainsState(&tiled, xdg_state_tiled_left));
    var suspended: [4]u8 = undefined;
    put32(suspended[0..4], xdg_state_suspended);
    try std.testing.expect(configureContainsState(&suspended, xdg_state_suspended));
}

test "Wayland present defers a second commit until the frame callback" {
    try std.testing.expect(!Window.shouldDeferPresent(0));
    try std.testing.expect(Window.shouldDeferPresent(7));
}

test "decoration configure retries SSD only for client-side mode" {
    try std.testing.expect(decorationModeIsClientSide(decoration_mode_client_side));
    try std.testing.expect(!decorationModeIsClientSide(decoration_mode_server_side));
    try std.testing.expect(!decorationModeIsClientSide(0));
}

test "Caps Lock follows compositor Lock bit once it has been seen" {
    var from_compositor = false;
    try std.testing.expect(!capsLockFromLocked(0, false, &from_compositor));
    try std.testing.expect(!from_compositor);
    try std.testing.expect(capsLockFromLocked(0, true, &from_compositor));
    try std.testing.expect(capsLockFromLocked(xkb_mod_lock, false, &from_compositor));
    try std.testing.expect(from_compositor);
    try std.testing.expect(!capsLockFromLocked(0, true, &from_compositor));
}

test "xdg configure_bounds clamp only positive oversized sizes" {
    try std.testing.expectEqual(@as(i32, 800), clampToBounds(1024, 800));
    try std.testing.expectEqual(@as(i32, 640), clampToBounds(640, 800));
    try std.testing.expectEqual(@as(i32, 0), clampToBounds(0, 800));
    try std.testing.expectEqual(@as(i32, 1024), clampToBounds(1024, 0));
}

test "xdg wm_capabilities bits include maximize and fullscreen" {
    var caps: [8]u8 = undefined;
    put32(caps[0..4], xdg_wm_cap_maximize);
    put32(caps[4..8], xdg_wm_cap_fullscreen);
    try std.testing.expect(configureContainsState(&caps, xdg_wm_cap_maximize));
    try std.testing.expect(configureContainsState(&caps, xdg_wm_cap_fullscreen));
    try std.testing.expect(!configureContainsState(&caps, xdg_wm_cap_minimize));
}
const pointer_release: u16 = 1;
