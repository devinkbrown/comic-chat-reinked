//! End-to-end acceptance fixtures for the Microsoft-source rendering path.
//!
//! Source anchors at upstream commit
//! `c7df00f60bc8e9fdef413f139e61f7c37e024684`:
//! - `panel.cpp:56-62`: two panels per row and 144-unit interstices.
//! - `panel.cpp:641-674`: panel art/elements followed by the clipped border.
//! - `panel.cpp:726-819`: first-panel establishing layout and avatar scaling.
//! - `panel.cpp:1079-1135`: implicit first conversation panel, repeated
//!   speakers, shared seeded layout, retries, and continuations.
//! - `panel.cpp:1141-1182`: `<Chr>` reaction body replacement/addition.
//! - `panel.cpp:1279-1297`: the implicit borderless title panel.
//! - `panel.cpp:1266-1275`: page extents.
//! - `fonts.cpp:98-140`: panel-scaled title and Starring metrics.
//! - `chatdoc.cpp:164-168,205-235` and `panel.cpp:451-474`: a new comic has
//!   a null title, so the random resource title consumes the first document
//!   RNG value before title/conversation panel seeds are assigned.
//! - `bodycam.cpp:524-573`: logical body rectangles and source rounding.
//!
//! Run directly with:
//! `zig test -Mroot=src/root.zig --test-filter source`

const std = @import("std");
const strip = @import("strip.zig");
const original_figure = @import("original_figure.zig");
const original_layout = @import("original_layout.zig");
const original_raster = @import("original_raster.zig");
const original_title = @import("original_title.zig");
const canvas_mod = @import("../render/canvas.zig");
const Canvas = canvas_mod.Canvas;
const black = canvas_mod.black;
const white = canvas_mod.white;

fn pixel(image: strip.Image, x: u32, y: u32) u32 {
    return image.pixels[@as(usize, y) * image.width + x];
}

fn sourceRound(value: f64) u32 {
    return @intFromFloat(value + 0.5);
}

fn expectedBorderThickness() u32 {
    return sourceRound(
        @as(f64, @floatFromInt(original_title.border_width)) *
            @as(f64, @floatFromInt(strip.panel_width)) /
            @as(f64, @floatFromInt(original_layout.default_unit_width)),
    );
}

/// Explicit little-endian FNV-1a over ARGB words. This is intentionally not a
/// library hash whose implementation could change independently of pixels.
fn pixelHash(pixels: []const u32) u64 {
    var hash: u64 = 0xcbf29ce484222325;
    for (pixels) |argb| {
        inline for (0..4) |byte_index| {
            const byte: u8 = @truncate(argb >> @as(u5, @intCast(byte_index * 8)));
            hash = (hash ^ byte) *% 0x100000001b3;
        }
    }
    return hash;
}

fn regionHash(image: strip.Image, x: u32, y: u32, width: u32, height: u32) u64 {
    var hash: u64 = 0xcbf29ce484222325;
    var row: u32 = 0;
    while (row < height) : (row += 1) {
        var column: u32 = 0;
        while (column < width) : (column += 1) {
            const argb = pixel(image, x + column, y + row);
            inline for (0..4) |byte_index| {
                const byte: u8 = @truncate(argb >> @as(u5, @intCast(byte_index * 8)));
                hash = (hash ^ byte) *% 0x100000001b3;
            }
        }
    }
    return hash;
}

test "empty transcript still renders the implicit borderless title panel" {
    const gpa = std.testing.allocator;
    var image = try strip.render(gpa, &.{});
    defer image.deinit(gpa);

    try std.testing.expectEqual(strip.panel_width, image.width);
    try std.testing.expectEqual(strip.panel_height, image.height);
    // AddTitle explicitly disables the border and backdrop. Its labels do not
    // cover the clipped panel corner.
    try std.testing.expectEqual(white, pixel(image, 0, 0));
    try std.testing.expectEqual(white, pixel(image, image.width - 1, image.height - 1));
}

test "logical two-column 144 interstice maps to source-rounded device pixels" {
    const gpa = std.testing.allocator;
    const expected_interstice = sourceRound(
        144.0 * @as(f64, @floatFromInt(strip.panel_width)) /
            @as(f64, @floatFromInt(original_layout.default_unit_width)),
    );
    try std.testing.expectEqual(@as(u32, 20), expected_interstice);
    try std.testing.expectEqual(expected_interstice, strip.device_interstice);
    try std.testing.expectEqual(@as(u32, 2), strip.columns);

    var image = try strip.render(gpa, &.{.{ .speaker = "anna", .text = "Hi." }});
    defer image.deinit(gpa);
    const conversation_x = strip.panel_width + expected_interstice;
    try std.testing.expectEqual(2 * strip.panel_width + expected_interstice, image.width);
    try std.testing.expectEqual(strip.panel_height, image.height);

    // Page composition clears the 144-unit interstice; the next pixel is the
    // clipped black border of the first conversational panel.
    var x = strip.panel_width;
    while (x < conversation_x) : (x += 1)
        try std.testing.expectEqual(white, pixel(image, x, 0));
    try std.testing.expectEqual(black, pixel(image, conversation_x, 0));
}

test "repeated speaker starts a fresh panel on the second device row" {
    const gpa = std.testing.allocator;
    const lines = [_]strip.Line{
        .{ .speaker = "anna", .text = "One." },
        .{ .speaker = "anna", .text = "Two." },
    };
    var image = try strip.render(gpa, &lines);
    defer image.deinit(gpa);

    const second_row_y = strip.panel_height + strip.device_interstice;
    try std.testing.expectEqual(2 * strip.panel_width + strip.device_interstice, image.width);
    try std.testing.expectEqual(2 * strip.panel_height + strip.device_interstice, image.height);
    try std.testing.expectEqual(black, pixel(image, 0, second_row_y));
    var y = strip.panel_height;
    while (y < second_row_y) : (y += 1)
        try std.testing.expectEqual(white, pixel(image, 100, y));
}

test "first conversational panel stays establishing while repeated speaker is fresh" {
    const gpa = std.testing.allocator;
    const first_only = [_]strip.Line{.{ .speaker = "anna", .text = "One." }};
    const repeated = [_]strip.Line{
        .{ .speaker = "anna", .text = "One." },
        .{ .speaker = "anna", .text = "Two." },
    };
    var first = try strip.render(gpa, &first_only);
    defer first.deinit(gpa);
    var page = try strip.render(gpa, &repeated);
    defer page.deinit(gpa);

    // Adding a later panel cannot relayout/zoom the already established first
    // panel. The mature fresh panel may use LayoutAvatars' zoom-in branch.
    try std.testing.expectEqualSlices(u32, first.pixels, page.pixels[0..first.pixels.len]);
    const first_panel_hash = regionHash(first, strip.panel_width + strip.device_interstice, 0, strip.panel_width, strip.panel_height);
    const mature_panel_hash = regionHash(page, 0, strip.panel_height + strip.device_interstice, strip.panel_width, strip.panel_height);
    try std.testing.expectEqual(@as(u64, 0x6c42a88c60abf335), first_panel_hash);
    try std.testing.expectEqual(@as(u64, 0x16e0fbde68ed6b10), mature_panel_hash);
    try std.testing.expect(first_panel_hash != mature_panel_hash);
}

test "logical body geometry is source-rounded before one device mapping" {
    const gpa = std.testing.allocator;
    var canvas = try Canvas.init(gpa, strip.panel_width, strip.panel_height);
    defer canvas.deinit(gpa);
    canvas.clear(white);
    const geometry = try original_figure.drawForTextLogical(
        gpa,
        &canvas,
        strip.avatarByName("anna").?,
        "Hello!",
        .{
            .client = .{ .left = 137, .top = -900, .right = 1974, .bottom = -2200 },
            .transform = original_raster.Transform.panel315(),
        },
    );
    try std.testing.expectEqual(
        original_figure.LogicalRect{ .left = 763, .top = -900, .right = 1347, .bottom = -2200 },
        geometry.logical.full,
    );
    try std.testing.expectEqual(
        original_figure.LogicalRect{ .left = 763, .top = -900, .right = 1305, .bottom = -1288 },
        geometry.logical.head.?,
    );
    try std.testing.expectEqual(
        original_figure.LogicalRect{ .left = 817, .top = -1146, .right = 1348, .bottom = -2201 },
        geometry.logical.torso,
    );
    try std.testing.expectEqual(
        original_figure.Rect{ .x = 104, .y = 123, .w = 80, .h = 178 },
        geometry.device.full,
    );
    try std.testing.expectEqual(
        original_figure.Rect{ .x = 104, .y = 123, .w = 75, .h = 53 },
        geometry.device.head.?,
    );
    try std.testing.expectEqual(
        original_figure.Rect{ .x = 112, .y = 157, .w = 73, .h = 144 },
        geometry.device.torso,
    );
    try std.testing.expectEqual(
        original_raster.Transform.panel315().map(.{ .x = geometry.logical.full.left, .y = geometry.logical.full.top }).x,
        geometry.device.full.x,
    );
}

test "scaled title metrics draw authored participant icons" {
    const gpa = std.testing.allocator;
    const fonts = original_title.fontConstruction(-240);
    try std.testing.expectEqual(@as(i32, -288), fonts.title_request_height);
    try std.testing.expectEqual(@as(i32, -240), fonts.shout_request_height);

    var empty = try strip.render(gpa, &.{});
    defer empty.deinit(gpa);
    var with_star = try strip.render(gpa, &.{.{ .speaker = "anna", .text = "Hi." }});
    defer with_star.deinit(gpa);
    const empty_hash = regionHash(empty, 0, 0, strip.panel_width, strip.panel_height);
    const starred_hash = regionHash(with_star, 0, 0, strip.panel_width, strip.panel_height);
    try std.testing.expectEqual(@as(u64, 0xa62f64877e1db6d0), empty_hash);
    try std.testing.expectEqual(@as(u64, 0x57ccc49b4d4dacf1), starred_hash);
    try std.testing.expect(empty_hash != starred_hash);
}

test "Chr adds or replaces a body without drawing literal reaction text" {
    const gpa = std.testing.allocator;
    const baseline_lines = [_]strip.Line{.{ .speaker = "anna", .text = "Hello." }};
    const add_reaction_lines = [_]strip.Line{
        .{ .speaker = "anna", .text = "Hello." },
        .{ .speaker = "kevin", .text = "<Chr>" },
    };
    const replace_reaction_lines = [_]strip.Line{
        .{ .speaker = "anna", .text = "Hello." },
        .{ .speaker = "anna", .text = "<Chr>" },
    };
    const ordinary_repeat_lines = [_]strip.Line{
        .{ .speaker = "anna", .text = "Hello." },
        .{ .speaker = "anna", .text = "Another spoken line." },
    };

    var baseline = try strip.render(gpa, &baseline_lines);
    defer baseline.deinit(gpa);
    var added = try strip.render(gpa, &add_reaction_lines);
    defer added.deinit(gpa);
    var replaced = try strip.render(gpa, &replace_reaction_lines);
    defer replaced.deinit(gpa);
    var ordinary = try strip.render(gpa, &ordinary_repeat_lines);
    defer ordinary.deinit(gpa);

    try std.testing.expectEqual(strip.panel_height, added.height);
    try std.testing.expectEqual(strip.panel_height, replaced.height);
    try std.testing.expectEqual(2 * strip.panel_height + strip.device_interstice, ordinary.height);
    const baseline_panel = regionHash(baseline, strip.panel_width + strip.device_interstice, 0, strip.panel_width, strip.panel_height);
    const added_panel = regionHash(added, strip.panel_width + strip.device_interstice, 0, strip.panel_width, strip.panel_height);
    const replaced_panel = regionHash(replaced, strip.panel_width + strip.device_interstice, 0, strip.panel_width, strip.panel_height);
    // The new participant changes avatar composition, while replacing Anna's
    // body retains exactly one pre-existing spoken balloon and changes only
    // the authored pose. A literal `<Chr>` balloon changes these fixed panels.
    try std.testing.expectEqual(@as(u64, 0x426cbcd147d16469), baseline_panel);
    try std.testing.expectEqual(@as(u64, 0x7aa2231ddcd74b43), added_panel);
    try std.testing.expectEqual(@as(u64, 0x56381883c81f7e64), replaced_panel);
    try std.testing.expect(added_panel != baseline_panel);
    try std.testing.expect(replaced_panel != baseline_panel);
}

test "shared page and balloon CRT stream produces byte-identical output" {
    const gpa = std.testing.allocator;
    const lines = [_]strip.Line{
        .{ .speaker = "anna", .text = "Hello from the source renderer." },
        .{ .speaker = "kevin", .text = "The random stream is shared." },
        .{ .speaker = "anna", .text = "This repeated speaker starts fresh." },
    };
    var first = try strip.render(gpa, &lines);
    defer first.deinit(gpa);
    var second = try strip.render(gpa, &lines);
    defer second.deinit(gpa);

    try std.testing.expectEqual(first.width, second.width);
    try std.testing.expectEqual(first.height, second.height);
    try std.testing.expectEqualSlices(u32, first.pixels, second.pixels);
    try std.testing.expectEqual(pixelHash(first.pixels), pixelHash(second.pixels));
}

test "conversation panel border is the clipped inner half of the 120-unit pen" {
    const gpa = std.testing.allocator;
    var image = try strip.render(gpa, &.{.{ .speaker = "anna", .text = "Border." }});
    defer image.deinit(gpa);

    const origin_x = strip.panel_width + strip.device_interstice;
    const thickness = expectedBorderThickness();
    try std.testing.expectEqual(@as(u32, 8), thickness);

    var inset: u32 = 0;
    while (inset < thickness) : (inset += 1) {
        try std.testing.expectEqual(black, pixel(image, origin_x + 150, inset));
        try std.testing.expectEqual(black, pixel(image, origin_x + inset, 150));
        try std.testing.expectEqual(black, pixel(image, origin_x + 150, strip.panel_height - 1 - inset));
        try std.testing.expectEqual(black, pixel(image, origin_x + strip.panel_width - 1 - inset, 150));
    }
    // The field backdrop at this stable sample begins immediately inside the
    // clipped border, proving we did not rasterize the full 120 units inward.
    try std.testing.expect(pixel(image, origin_x + thickness, 150) != black);
}

test "fixed source strip pixel fixture" {
    const gpa = std.testing.allocator;
    const lines = [_]strip.Line{
        .{ .speaker = "anna", .text = "Hello from the source renderer." },
        .{ .speaker = "kevin", .text = "The random stream is shared." },
        .{ .speaker = "anna", .text = "This repeated speaker starts fresh." },
    };
    var image = try strip.render(gpa, &lines);
    defer image.deinit(gpa);

    const hash = pixelHash(image.pixels);
    try std.testing.expectEqual(@as(u32, 650), image.width);
    try std.testing.expectEqual(@as(u32, 650), image.height);
    try std.testing.expectEqual(@as(u64, 0xa5f59c9cf450aa75), hash);
}

test "generated color avatars use the source page planner and stay deterministic" {
    const gpa = std.testing.allocator;
    const lines = [_]strip.Line{
        .{ .speaker = "anna color", .text = "Hello from the color cast." },
        .{ .speaker = "kevin color", .text = "The planner is shared." },
        .{ .speaker = "anna color", .text = "A repeated speaker still starts fresh." },
    };
    var first = try strip.render(gpa, &lines);
    defer first.deinit(gpa);
    var second = try strip.render(gpa, &lines);
    defer second.deinit(gpa);

    try std.testing.expectEqual(@as(u32, 650), first.width);
    try std.testing.expectEqual(@as(u32, 650), first.height);
    try std.testing.expectEqualSlices(u32, first.pixels, second.pixels);
    try std.testing.expectEqual(pixelHash(first.pixels), pixelHash(second.pixels));
}

test "later color-avatar lines do not relayout the established first panel" {
    const gpa = std.testing.allocator;
    const first_only = [_]strip.Line{.{ .speaker = "anna color", .text = "One." }};
    const repeated = [_]strip.Line{
        .{ .speaker = "anna color", .text = "One." },
        .{ .speaker = "anna color", .text = "Two." },
    };
    var first = try strip.render(gpa, &first_only);
    defer first.deinit(gpa);
    var page = try strip.render(gpa, &repeated);
    defer page.deinit(gpa);

    try std.testing.expectEqualSlices(u32, first.pixels, page.pixels[0..first.pixels.len]);
    const first_panel_hash = regionHash(first, strip.panel_width + strip.device_interstice, 0, strip.panel_width, strip.panel_height);
    const mature_panel_hash = regionHash(page, 0, strip.panel_height + strip.device_interstice, strip.panel_width, strip.panel_height);
    try std.testing.expect(first_panel_hash != mature_panel_hash);
}

fn countChromatic(image: strip.Image, x: u32, y: u32, width: u32, height: u32) usize {
    var count: usize = 0;
    var row: u32 = 0;
    while (row < height) : (row += 1) {
        var column: u32 = 0;
        while (column < width) : (column += 1) {
            const argb = pixel(image, x + column, y + row);
            const red: u8 = @truncate(argb >> 16);
            const green: u8 = @truncate(argb >> 8);
            const blue: u8 = @truncate(argb);
            if (red != green or green != blue) count += 1;
        }
    }
    return count;
}

test "Color female close-up is not a feet-only crop of the padded card" {
    const gpa = std.testing.allocator;
    const lines = [_]strip.Line{
        .{ .speaker = "anna color", .text = "One." },
        .{ .speaker = "anna color", .text = "Two." },
    };
    var page = try strip.render(gpa, &lines);
    defer page.deinit(gpa);

    const x: u32 = 0;
    const y: u32 = strip.panel_height + strip.device_interstice;
    const w = strip.panel_width;
    const h = strip.panel_height;
    const all = countChromatic(page, x, y, w, h);
    try std.testing.expect(all > 1000);

    var min_y: u32 = h;
    var max_y: u32 = 0;
    var row: u32 = 0;
    while (row < h) : (row += 1) {
        if (countChromatic(page, x, y + row, w, 1) == 0) continue;
        min_y = @min(min_y, row);
        max_y = @max(max_y, row + 1);
    }
    try std.testing.expect(max_y > min_y);
    const span = max_y - min_y;
    // A feet-only crop of the padded card occupies a thin band at the bottom.
    try std.testing.expect(span * 4 >= h);
    try std.testing.expect(min_y + span / 3 < (h * 3) / 4);
}

test "a last-nine transcript window loses first-panel establishing geometry" {
    const gpa = std.testing.allocator;
    const full = [_]strip.Line{
        .{ .speaker = "anna", .text = "One." },
        .{ .speaker = "anna", .text = "Two." },
        .{ .speaker = "anna", .text = "Three." },
        .{ .speaker = "anna", .text = "Four." },
        .{ .speaker = "anna", .text = "Five." },
        .{ .speaker = "anna", .text = "Six." },
        .{ .speaker = "anna", .text = "Seven." },
        .{ .speaker = "anna", .text = "Eight." },
        .{ .speaker = "anna", .text = "Nine." },
        .{ .speaker = "anna", .text = "Ten." },
    };
    var prefix = try strip.render(gpa, &full);
    defer prefix.deinit(gpa);
    var windowed = try strip.render(gpa, full[1..]);
    defer windowed.deinit(gpa);

    // AddLine treats the first conversational panel as establishing. Dropping
    // the first line makes "Two." the establishing shot and changes every
    // later panel's seed and hysteresis.
    try std.testing.expect(prefix.height > windowed.height);
    const prefix_first = regionHash(prefix, strip.panel_width + strip.device_interstice, 0, strip.panel_width, strip.panel_height);
    const windowed_first = regionHash(windowed, strip.panel_width + strip.device_interstice, 0, strip.panel_width, strip.panel_height);
    try std.testing.expect(prefix_first != windowed_first);
}
