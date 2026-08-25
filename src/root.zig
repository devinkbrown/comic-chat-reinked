//! comicchat library root — source-derived portable core and native backends.

const std = @import("std");
const builtin = @import("builtin");

pub const proto = struct {
    pub const record = @import("proto/record.zig");
    pub const udi = @import("proto/udi.zig");
    pub const dcc = @import("proto/dcc.zig");
    pub const keystring = @import("proto/keystring.zig");
};

pub const assets = struct {
    pub const avb = @import("assets/avb.zig");
    pub const bgb = @import("assets/bgb.zig");
};

pub const comic = struct {
    pub const formatting = @import("comic/formatting.zig");
    pub const figure = @import("comic/figure.zig");
    pub const strip = @import("comic/strip.zig");
    pub const layout = @import("comic/layout.zig");
    pub const session = @import("comic/session.zig");
    pub const emotion = @import("comic/emotion.zig");
    pub const original_layout = @import("comic/original_layout.zig");
    pub const original_balloon = @import("comic/original_balloon.zig");
    pub const original_page = @import("comic/original_page.zig");
    pub const original_title = @import("comic/original_title.zig");
    pub const original_raster = @import("comic/original_raster.zig");
    pub const original_figure = @import("comic/original_figure.zig");
    pub const rules = @import("comic/rules.zig");
    pub const notify = @import("comic/notify.zig");
};

pub const render = struct {
    pub const canvas = @import("render/canvas.zig");
    pub const font = @import("render/font.zig");
    pub const png = @import("render/png.zig");
    pub const pdf = @import("render/pdf.zig");
};

pub const platform = struct {
    pub const event = @import("platform/event.zig");
    pub const services = @import("platform/services.zig");
    pub const x11 = @import("platform/x11.zig");
    pub const win32 = @import("platform/win32.zig");
    pub const wayland = if (builtin.os.tag == .linux) @import("platform/wayland.zig") else struct {};
};

pub const client = struct {
    pub const geometry = @import("client/geometry.zig");
    pub const hit_test = @import("client/hit_test.zig");
    pub const dialogs = @import("client/dialogs.zig");
    pub const workspace = @import("client/workspace.zig");
    pub const files = @import("client/files.zig");
    pub const preferences = @import("client/preferences.zig");
    pub const accessibility = @import("client/accessibility.zig");
    pub const input = @import("client/input.zig");
    pub const shell = @import("client/shell.zig");
    pub const ui = @import("client/ui.zig");
    pub const view = @import("client/view.zig");
};

pub const net = struct {
    pub const message = @import("net/message.zig");
    pub const ircv3 = @import("net/ircv3.zig");
    pub const sasl = @import("net/sasl.zig");
    pub const features = @import("net/features.zig");
    pub const irc_map = @import("net/irc_map.zig");
    pub const connection_policy = @import("net/connection_policy.zig");
    pub const sts_store = @import("net/sts_store.zig");
    pub const session_store = @import("net/session_store.zig");
    pub const irc = @import("net/irc.zig");
    pub const transport = @import("net/transport.zig");
    pub const tls = @import("net/tls.zig");
    pub const client = @import("net/client.zig");
};

test {
    // 0.16 dropped refAllDeclsRecursive; reference each module so its tests run.
    std.testing.refAllDecls(@This());
    _ = @import("proto/record.zig");
    _ = @import("proto/udi.zig");
    _ = @import("proto/dcc.zig");
    _ = @import("proto/keystring.zig");
    _ = @import("assets/avb.zig");
    _ = @import("assets/bgb.zig");
    _ = @import("render/canvas.zig");
    _ = @import("comic/figure.zig");
    _ = @import("comic/formatting.zig");
    _ = @import("comic/strip.zig");
    _ = @import("comic/layout.zig");
    _ = @import("comic/session.zig");
    _ = @import("comic/emotion.zig");
    _ = @import("comic/original_layout.zig");
    _ = @import("comic/original_balloon.zig");
    _ = @import("comic/original_page.zig");
    _ = @import("comic/original_title.zig");
    _ = @import("comic/original_raster.zig");
    _ = @import("comic/original_figure.zig");
    _ = @import("comic/rules.zig");
    _ = @import("comic/notify.zig");
    _ = @import("comic/source_parity_test.zig");
    _ = @import("comic/source_page_balloon_test.zig");
    _ = @import("comic/source_strip_test.zig");
    _ = @import("comic/source_modes_test.zig");
    _ = @import("render/png.zig");
    _ = @import("render/pdf.zig");
    _ = @import("platform/event.zig");
    _ = @import("platform/services.zig");
    _ = @import("platform/x11.zig");
    _ = @import("platform/win32.zig");
    if (builtin.os.tag == .linux) {
        _ = @import("platform/wayland.zig");
        _ = @import("platform/xkb.zig");
    }
    _ = @import("client/geometry.zig");
    _ = @import("client/hit_test.zig");
    _ = @import("client/dialogs.zig");
    _ = @import("client/workspace.zig");
    _ = @import("client/files.zig");
    _ = @import("client/preferences.zig");
    _ = @import("client/input.zig");
    _ = @import("client/shell.zig");
    _ = @import("client/ui.zig");
    _ = @import("client/view.zig");
    _ = @import("net/message.zig");
    _ = @import("net/ircv3.zig");
    _ = @import("net/sasl.zig");
    _ = @import("net/features.zig");
    _ = @import("net/irc_map.zig");
    _ = @import("net/connection_policy.zig");
    _ = @import("net/sts_store.zig");
    _ = @import("net/session_store.zig");
    _ = @import("net/irc.zig");
    _ = @import("net/transport.zig"); // compile-checked (no live socket test)
    _ = @import("net/tls.zig");
    _ = @import("net/client.zig");
}
