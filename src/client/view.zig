//! Modern portable Comic Chat client view.
//!
//! The workspace geometry follows the established splitter composition:
//! room tabs above an 80/20 conversation/member split, a fixed-height say
//! window below the page/text view, and (in comic mode) a 30/70 member/bodycam
//! split on the right. Ink Sunday chrome frames a source-faithful page.

const std = @import("std");
const session = @import("../comic/session.zig");
const strip = @import("../comic/strip.zig");
const figure = @import("../comic/figure.zig");
const bgb = @import("../assets/bgb.zig");
const canvas_mod = @import("../render/canvas.zig");
const geometry = @import("geometry.zig");
const shell_mod = @import("shell.zig");
const hit_test = @import("hit_test.zig");
const dialogs = @import("dialogs.zig");
const input_mod = @import("input.zig");
const accessibility = @import("accessibility.zig");
const ui = @import("ui.zig");
const platform_event = @import("../platform/event.zig");

const Canvas = canvas_mod.Canvas;
const Rect = geometry.Rect;
const TextSelection = input_mod.Editor.Selection;

/// The desktop presentation defaults to the generated HD avatar family. The
/// source-faithful comic pipeline still resolves its historical asset names in
/// `strip`, so this boundary never alters source raster behavior.
fn displayAvatarByName(name: []const u8) ?[]const u8 {
    const eql = std.ascii.eqlIgnoreCase;
    if (eql(name, "anna")) return strip.avatarByName("anna hd");
    if (eql(name, "armando")) return strip.avatarByName("armando hd");
    if (eql(name, "bolo")) return strip.avatarByName("bolo hd");
    if (eql(name, "cro")) return strip.avatarByName("cro hd");
    if (eql(name, "dan")) return strip.avatarByName("dan hd");
    if (eql(name, "denise")) return strip.avatarByName("denise hd");
    if (eql(name, "hugh")) return strip.avatarByName("hugh hd");
    if (eql(name, "jordan")) return strip.avatarByName("jordan hd");
    if (eql(name, "kevin")) return strip.avatarByName("kevin hd");
    if (eql(name, "kwensa")) return strip.avatarByName("kwensa hd");
    if (eql(name, "lance")) return strip.avatarByName("lance hd");
    if (eql(name, "lynnea")) return strip.avatarByName("lynnea hd");
    if (eql(name, "margaret")) return strip.avatarByName("margaret hd");
    if (eql(name, "maynard")) return strip.avatarByName("maynard hd");
    if (eql(name, "mike")) return strip.avatarByName("mike hd");
    if (eql(name, "rebecca")) return strip.avatarByName("rebecca hd");
    if (eql(name, "sage")) return strip.avatarByName("sage hd");
    if (eql(name, "scotty")) return strip.avatarByName("scotty hd");
    if (eql(name, "susan")) return strip.avatarByName("susan hd");
    if (eql(name, "tiki")) return strip.avatarByName("tiki hd");
    if (eql(name, "tongtyed")) return strip.avatarByName("tongtyed hd");
    if (eql(name, "xeno")) return strip.avatarByName("xeno hd");
    return strip.avatarByName(name);
}

pub const min_width: u32 = 640;
pub const min_height: u32 = 480;

pub const Action = union(enum) {
    none,
    menu: u8,
    toolbar: u8,
    room_tab: usize,
    composer_cursor: struct { x: i32, y: i32 },
    composer_format: u8,
    transcript_command: u8,
    send_expression,
    child_window,
    send,
    quit,
    connection,
    dialog_accept: dialogs.Id,
    dialog_cancel: dialogs.Id,
    dialog_browse: dialogs.Id,
};

const ColumnControlHover = enum { decrease, increase };
const StatusActionHover = enum { connection, settings };
const ContextKind = enum { member, body_camera };
const DialogGalleryFocus = enum { family, previous, selected, next };
const MemberViewport = struct { visible: usize, step: usize };

fn memberViewport(rect: Rect, icon_mode: bool) MemberViewport {
    const content_h = @max(0, rect.h - 30);
    if (icon_mode) {
        const columns: usize = @intCast(@max(1, @divTrunc(rect.w, 88)));
        const rows: usize = @intCast(@max(1, @divTrunc(content_h, 82)));
        return .{ .visible = columns * rows, .step = columns };
    }
    return .{
        .visible = @intCast(@max(1, @divTrunc(content_h - 7, 24))),
        .step = 1,
    };
}

pub const View = struct {
    gpa: std.mem.Allocator,
    canvas: Canvas,
    shell: shell_mod.State = .{},
    active_dialog: ?dialogs.Id = null,
    dialog_notice: []const u8 = "",
    hovered_dialog_button: ?ui.DialogButton = null,
    hovered_dialog_field: ?usize = null,
    hovered_dialog_browse: ?usize = null,
    active_menu: ?u8 = null,
    hovered_menu: ?u8 = null,
    hovered_menu_item: ?u8 = null,
    hovered_toolbar: ?u8 = null,
    hovered_say_action: ?u8 = null,
    focused_toolbar: u8 = 0,
    focused_say_action: u8 = 0,
    hovered_composer: bool = false,
    hovered_status: bool = false,
    hovered_status_tab: bool = false,
    hovered_room_tab: ?usize = null,
    hovered_status_action: ?StatusActionHover = null,
    hovered_column_control: ?ColumnControlHover = null,
    hovered_member: ?usize = null,
    status_panel_open: bool = false,
    status_detailed: bool = true,
    appearance: ui.Appearance = .{},
    context_menu: ?ContextKind = null,
    context_x: i32 = 0,
    context_y: i32 = 0,
    hovered_context_item: ?u8 = null,
    focused_context_item: ?u8 = null,
    emotion_dragging: bool = false,
    dialog_editors: [8]input_mod.Editor,
    dialog_field: usize = 0,
    dialog_first_field: usize = 0,
    dialog_action_focus: ?ui.DialogButton = null,
    dialog_browse_focus: bool = false,
    dialog_gallery_focus: ?DialogGalleryFocus = null,
    room_tab_count: usize = 1,
    room_tab_first: usize = 0,
    can_moderate: bool = false,

    pub fn init(gpa: std.mem.Allocator, initial_width: u32, initial_height: u32) !View {
        return .{
            .gpa = gpa,
            .canvas = try Canvas.init(gpa, @max(initial_width, min_width), @max(initial_height, min_height)),
            .dialog_editors = .{
                input_mod.Editor.init(gpa),
                input_mod.Editor.init(gpa),
                input_mod.Editor.init(gpa),
                input_mod.Editor.init(gpa),
                input_mod.Editor.init(gpa),
                input_mod.Editor.init(gpa),
                input_mod.Editor.init(gpa),
                input_mod.Editor.init(gpa),
            },
        };
    }

    pub fn deinit(self: *View) void {
        self.canvas.deinit(self.gpa);
        for (&self.dialog_editors) |*editor| editor.deinit();
    }

    pub fn resize(self: *View, new_width: u32, new_height: u32) !void {
        const w = @max(new_width, min_width);
        const h = @max(new_height, min_height);
        if (w == self.canvas.width and h == self.canvas.height) return;
        const replacement = try Canvas.init(self.gpa, w, h);
        self.canvas.deinit(self.gpa);
        self.canvas = replacement;
    }

    pub fn pixels(self: *const View) []const u32 {
        return self.canvas.px;
    }

    pub fn width(self: *const View) u32 {
        return self.canvas.width;
    }

    pub fn height(self: *const View) u32 {
        return self.canvas.height;
    }

    pub fn cycleFocus(self: *View) void {
        self.shell.cycleFocus();
    }

    pub fn cycleFocusBackward(self: *View) void {
        self.shell.cycleFocusBackward();
    }

    pub fn focusComposer(self: *View) void {
        self.shell.focusComposer();
    }

    /// Keyboard ownership for composite controls. Lists use roving selection;
    /// the body camera keeps the source arrow-key and Home behavior.
    pub fn handleFocusedKey(self: *View, key: platform_event.Key, member_count: usize) bool {
        if (self.status_panel_open and key == .escape) {
            self.status_panel_open = false;
            self.hovered_status_action = null;
            return true;
        }
        switch (self.shell.focus) {
            .members => switch (key) {
                .up => self.shell.moveMemberSelection(member_count, -1),
                .down => self.shell.moveMemberSelection(member_count, 1),
                .home => if (member_count > 0) self.shell.selectMember(0),
                .end => if (member_count > 0) self.shell.selectMember(member_count - 1),
                else => return false,
            },
            .emotion => switch (key) {
                .left => self.shell.moveEmotion(-1, 0),
                .right => self.shell.moveEmotion(1, 0),
                .up => self.shell.moveEmotion(0, -1),
                .down => self.shell.moveEmotion(0, 1),
                .home => self.shell.neutralEmotion(),
                else => return false,
            },
            else => return false,
        }
        if (self.shell.focus == .members) if (self.shell.selected_member) |selected| {
            const layout = geometry.Layout.compute(self.canvas.width, self.canvas.height, self.shell.content_mode == .comic, self.shell.show_members);
            const viewport = memberViewport(layout.members, self.shell.member_view == .icons);
            self.shell.revealMember(member_count, viewport.visible, selected);
        };
        return true;
    }

    /// Commands that own a roving focus return the same public Action used by
    /// pointer activation.  This keeps the platform dispatcher authoritative
    /// for side effects such as sending, quitting, and opening a file picker.
    pub fn handleFocusedActionKey(self: *View, key: platform_event.Key) ?Action {
        switch (self.shell.focus) {
            .toolbar => switch (key) {
                .left, .up => self.focused_toolbar = (self.focused_toolbar + @as(u8, @intCast(ui.ToolbarLayout.button_count)) - 1) % @as(u8, @intCast(ui.ToolbarLayout.button_count)),
                .right, .down => self.focused_toolbar = (self.focused_toolbar + 1) % @as(u8, @intCast(ui.ToolbarLayout.button_count)),
                .home => self.focused_toolbar = 0,
                .end => self.focused_toolbar = @intCast(ui.ToolbarLayout.button_count - 1),
                .enter => return self.activateToolbar(ui.ToolbarLayout.command_ids[self.focused_toolbar]),
                else => return null,
            },
            .say_actions => switch (key) {
                .left, .up => self.focused_say_action = (self.focused_say_action + @as(u8, @intCast(geometry.say_button_count)) - 1) % @as(u8, @intCast(geometry.say_button_count)),
                .right, .down => self.focused_say_action = (self.focused_say_action + 1) % @as(u8, @intCast(geometry.say_button_count)),
                .home => self.focused_say_action = 0,
                .end => self.focused_say_action = @intCast(geometry.say_button_count - 1),
                .enter => return self.activateSayAction(self.focused_say_action),
                else => return null,
            },
            else => return null,
        }
        return .none;
    }

    pub fn handleContextMenuKey(self: *View, key: platform_event.Key) ?Action {
        const kind = self.context_menu orelse return null;
        switch (key) {
            .escape => {
                self.context_menu = null;
                self.hovered_context_item = null;
                self.focused_context_item = null;
            },
            .up => self.focused_context_item = nextEnabledContextItem(kind, self.focused_context_item orelse 0, false, self.can_moderate),
            .down => self.focused_context_item = nextEnabledContextItem(kind, self.focused_context_item orelse contextItemCount(kind) - 1, true, self.can_moderate),
            .home => self.focused_context_item = firstEnabledContextItem(kind, self.can_moderate),
            .end => self.focused_context_item = lastEnabledContextItem(kind, self.can_moderate),
            .enter => {
                const item = self.focused_context_item orelse firstEnabledContextItem(kind, self.can_moderate);
                self.context_menu = null;
                self.hovered_context_item = null;
                self.focused_context_item = null;
                if (kind == .body_camera and item == 3) return .send_expression;
                self.invokeContextItem(kind, item);
            },
            else => return null,
        }
        return .none;
    }

    pub fn handleTranscriptKey(self: *View, key: platform_event.Key, total_lines: usize, extend: bool) bool {
        if (self.shell.focus != .transcript) return false;
        switch (key) {
            .up => self.shell.moveTranscriptSelection(total_lines, -1, extend),
            .down => self.shell.moveTranscriptSelection(total_lines, 1, extend),
            .home => self.shell.selectTranscriptLine(total_lines, 0, extend),
            .end => if (total_lines > 0) self.shell.selectTranscriptLine(total_lines, total_lines - 1, extend),
            else => return false,
        }
        return true;
    }

    /// Keyboard navigation for the complete menu bar. A menu owns arrow,
    /// Home/End, Enter, and Escape until it closes so commands never leak into
    /// the composer or transcript.
    pub fn handleMenuKey(self: *View, key: platform_event.Key) ?Action {
        const menu = self.active_menu orelse {
            if (self.shell.focus != .navigation) return null;
            switch (key) {
                .enter, .down => {
                    self.active_menu = self.hovered_menu orelse 0;
                    self.hovered_menu_item = firstEnabledMenuItem(self.active_menu.?, self.can_moderate);
                    return .none;
                },
                else => return null,
            }
        };
        switch (key) {
            .escape => {
                self.active_menu = null;
                self.hovered_menu_item = null;
            },
            .left, .right => {
                const count: u8 = @intCast(menu_labels.len);
                self.active_menu = if (key == .left) (menu + count - 1) % count else (menu + 1) % count;
                self.hovered_menu_item = firstEnabledMenuItem(self.active_menu.?, self.can_moderate);
            },
            .up => self.hovered_menu_item = nextEnabledMenuItem(menu, self.hovered_menu_item orelse 0, false, self.can_moderate),
            .down => self.hovered_menu_item = nextEnabledMenuItem(menu, self.hovered_menu_item orelse menuItemCount(menu) - 1, true, self.can_moderate),
            .home => self.hovered_menu_item = firstEnabledMenuItem(menu, self.can_moderate),
            .end => self.hovered_menu_item = lastEnabledMenuItem(menu, self.can_moderate),
            .enter => return self.activateMenuItem(menu, self.hovered_menu_item orelse firstEnabledMenuItem(menu, self.can_moderate)),
            else => return .none,
        }
        return .none;
    }

    pub fn pageEarlier(self: *View, total_lines: usize) void {
        self.shell.pageEarlier(total_lines, 9);
    }

    pub fn pageLater(self: *View) void {
        self.shell.pageLater(9);
    }

    pub fn jumpLatest(self: *View) void {
        self.shell.jumpLatest();
    }

    pub fn setContentMode(self: *View, mode: shell_mod.ContentMode) void {
        self.shell.setContentMode(mode);
    }

    pub fn setAppearance(self: *View, appearance: ui.Appearance, status_detailed: bool) void {
        self.appearance = appearance;
        self.status_detailed = status_detailed;
    }

    pub fn currentEmotionLabel(self: *const View) []const u8 {
        return emotionLabel(self.shell.emotion_x, self.shell.emotion_y);
    }

    pub fn toggleMembers(self: *View) void {
        self.shell.toggleMembers();
    }

    pub fn openDialog(self: *View, id: dialogs.Id) void {
        self.active_menu = null;
        for (&self.dialog_editors) |*editor| editor.clear();
        for (dialogs.fields(id), 0..) |field, index| {
            if (index >= self.dialog_editors.len or field.kind != .choice) continue;
            const options = dialogs.choiceOptions(id, index);
            if (options.len > 0) self.dialog_editors[index].paste(options[0]) catch {};
        }
        self.dialog_field = 0;
        self.dialog_first_field = 0;
        self.dialog_action_focus = null;
        self.dialog_browse_focus = false;
        self.dialog_gallery_focus = null;
        var has_focusable_field = false;
        for (dialogs.fields(id), 0..) |field, index| if (dialogFieldFocusable(field)) {
            self.dialog_field = index;
            has_focusable_field = true;
            break;
        };
        if (!has_focusable_field) self.dialog_action_focus = .primary;
        self.dialog_notice = "";
        self.hovered_dialog_button = null;
        self.hovered_dialog_field = null;
        self.hovered_dialog_browse = null;
        self.hovered_say_action = null;
        self.hovered_status = false;
        self.hovered_status_tab = false;
        self.hovered_room_tab = null;
        self.hovered_column_control = null;
        self.hovered_member = null;
        self.context_menu = null;
        self.hovered_context_item = null;
        self.active_dialog = id;
    }

    pub fn openConnectionDialog(self: *View, host: []const u8, port: u16, use_tls: bool) void {
        self.openEndpointDialog(.setup, host, port, use_tls);
    }

    pub fn openEndpointDialog(self: *View, id: dialogs.Id, host: []const u8, port: u16, use_tls: bool) void {
        std.debug.assert(id == .setup or id == .servers);
        self.openDialog(id);
        var port_buffer: [5]u8 = undefined;
        const port_text = std.fmt.bufPrint(&port_buffer, "{d}", .{port}) catch "6697";
        const values = [_][]const u8{ host, port_text, if (use_tls) "Verified TLS" else "Plaintext (unsafe)" };
        for (values, 0..) |value, index| {
            self.dialog_editors[index].clear();
            self.dialog_editors[index].paste(value) catch {};
        }
    }

    pub fn openDialogByResource(self: *View, resource: []const u8) bool {
        const id = dialogs.fromResource(resource) orelse return false;
        self.openDialog(id);
        return true;
    }

    pub fn closeDialog(self: *View) bool {
        if (self.active_dialog == null) return false;
        self.active_dialog = null;
        self.hovered_dialog_button = null;
        self.hovered_dialog_field = null;
        self.hovered_dialog_browse = null;
        self.dialog_action_focus = null;
        return true;
    }

    /// Update transient pointer affordances.  The original client depended on
    /// raised Win32 controls; this port keeps the source geometry but gives the
    /// custom-drawn controls an equivalent hover response and plain-language
    /// status hint.
    pub fn handlePointerMove(self: *View, pointer: platform_event.Pointer, member_count: usize) bool {
        if (self.active_dialog) |id| {
            const dialog_layout = dialogLayout(self.canvas.width, self.canvas.height, dialogs.get(id));
            const next = ui.dialogButtonAt(dialog_layout, pointer.x, pointer.y);
            const next_field = dialog_layout.fieldIndexAtScrolled(pointer.x, pointer.y, self.dialog_first_field);
            const next_browse = if (dialogBrowseField(id)) |index|
                if (ui.contains(dialogBrowseRect(dialog_layout.fieldRectScrolled(index, self.dialog_first_field)), pointer.x, pointer.y)) index else null
            else
                null;
            const changed = self.hovered_dialog_button != next or self.hovered_dialog_field != next_field or self.hovered_dialog_browse != next_browse or self.hovered_menu != null or self.hovered_toolbar != null or self.hovered_say_action != null or self.hovered_composer or self.hovered_status or self.hovered_status_tab or self.hovered_room_tab != null or self.hovered_column_control != null or self.hovered_member != null;
            self.hovered_dialog_button = next;
            self.hovered_dialog_field = next_field;
            self.hovered_dialog_browse = next_browse;
            self.hovered_menu = null;
            self.hovered_menu_item = null;
            self.hovered_toolbar = null;
            self.hovered_say_action = null;
            self.hovered_composer = false;
            self.hovered_status = false;
            self.hovered_status_tab = false;
            self.hovered_room_tab = null;
            self.hovered_column_control = null;
            self.hovered_member = null;
            return changed;
        }
        if (self.status_panel_open) {
            const status_layout = ui.StatusPanelLayout.init(self.canvas.width, self.canvas.height, self.status_detailed);
            if (ui.contains(status_layout.rect, pointer.x, pointer.y)) {
                const action: ?StatusActionHover = if (ui.contains(status_layout.connection, pointer.x, pointer.y))
                    .connection
                else if (ui.contains(status_layout.settings, pointer.x, pointer.y))
                    .settings
                else
                    null;
                return self.setStatusActionHover(action);
            }
        }
        if (self.context_menu) |kind| {
            const next = contextPopupItem(self.canvas.width, self.canvas.height, kind, self.context_x, self.context_y, pointer.x, pointer.y);
            const changed = self.hovered_context_item != next;
            self.hovered_context_item = next;
            return changed;
        }
        if (self.active_menu) |menu| {
            const layout = geometry.Layout.compute(self.canvas.width, self.canvas.height, self.shell.content_mode == .comic, self.shell.show_members);
            const target = hit_test.shell(layout, self.shell.content_mode == .comic, self.shell.member_view == .icons, pointer.x, pointer.y, member_count);
            if (target == .menu) {
                const next_menu = target.menu;
                const changed = self.active_menu != next_menu or self.hovered_menu != next_menu or self.hovered_menu_item != null or self.hovered_say_action != null or self.hovered_status or self.hovered_status_tab or self.hovered_room_tab != null or self.hovered_column_control != null or self.hovered_member != null;
                self.active_menu = next_menu;
                self.hovered_menu = next_menu;
                self.hovered_menu_item = null;
                self.hovered_toolbar = null;
                self.hovered_say_action = null;
                self.hovered_status = false;
                self.hovered_status_tab = false;
                self.hovered_room_tab = null;
                self.hovered_column_control = null;
                self.hovered_member = null;
                return changed;
            }
            const item = menuPopupItem(self.canvas.width, menu, pointer.x, pointer.y);
            const changed = self.hovered_menu_item != item or self.hovered_menu != null or self.hovered_toolbar != null or self.hovered_say_action != null or self.hovered_status or self.hovered_status_tab or self.hovered_room_tab != null or self.hovered_column_control != null or self.hovered_member != null;
            self.hovered_menu_item = item;
            self.hovered_menu = null;
            self.hovered_toolbar = null;
            self.hovered_say_action = null;
            self.hovered_status = false;
            self.hovered_status_tab = false;
            self.hovered_room_tab = null;
            self.hovered_column_control = null;
            self.hovered_member = null;
            return changed;
        }
        const comic_mode = self.shell.content_mode == .comic;
        const layout = geometry.Layout.compute(self.canvas.width, self.canvas.height, comic_mode, self.shell.show_members);
        if (self.emotion_dragging) {
            if (comic_mode and self.setEmotionFromPoint(layout, pointer.x, pointer.y)) return true;
            return false;
        }
        const target = self.mapMemberTarget(
            hit_test.shell(layout, comic_mode, self.shell.member_view == .icons, pointer.x, pointer.y, member_count),
            member_count,
        );
        return switch (target) {
            .menu => |index| self.setHover(index, null),
            .toolbar => |index| self.setHover(null, index),
            .say_action => |index| self.setContentHover(index, null, null),
            .composer => self.setComposerHover(),
            .status_window => self.setStatusTabHover(),
            .room_tab => if (roomTabIndexAt(self, layout, comic_mode, pointer.x)) |index|
                self.setRoomTabHover(index)
            else
                self.setHover(null, null),
            .connection_status => self.setStatusHover(),
            .comic_columns_decrease => self.setContentHover(null, .decrease, null),
            .comic_columns_increase => self.setContentHover(null, .increase, null),
            .member => |index| self.setContentHover(null, null, index),
            else => self.setHover(null, null),
        };
    }

    fn setHover(self: *View, menu: ?u8, toolbar: ?u8) bool {
        const changed = self.hovered_menu != menu or self.hovered_menu_item != null or self.hovered_toolbar != toolbar or self.hovered_say_action != null or self.hovered_composer or self.hovered_status or self.hovered_status_tab or self.hovered_room_tab != null or self.hovered_status_action != null or self.hovered_column_control != null or self.hovered_member != null;
        self.hovered_menu = menu;
        self.hovered_menu_item = null;
        self.hovered_toolbar = toolbar;
        self.hovered_say_action = null;
        self.hovered_composer = false;
        self.hovered_status = false;
        self.hovered_status_tab = false;
        self.hovered_room_tab = null;
        self.hovered_status_action = null;
        self.hovered_column_control = null;
        self.hovered_member = null;
        return changed;
    }

    fn setContentHover(self: *View, say_action: ?u8, column_control: ?ColumnControlHover, member: ?usize) bool {
        const changed = self.hovered_menu != null or self.hovered_menu_item != null or self.hovered_toolbar != null or self.hovered_say_action != say_action or self.hovered_composer or self.hovered_status or self.hovered_status_tab or self.hovered_room_tab != null or self.hovered_status_action != null or self.hovered_column_control != column_control or self.hovered_member != member;
        self.hovered_menu = null;
        self.hovered_menu_item = null;
        self.hovered_toolbar = null;
        self.hovered_say_action = say_action;
        self.hovered_composer = false;
        self.hovered_status = false;
        self.hovered_status_tab = false;
        self.hovered_room_tab = null;
        self.hovered_status_action = null;
        self.hovered_column_control = column_control;
        self.hovered_member = member;
        return changed;
    }

    fn setComposerHover(self: *View) bool {
        const changed = self.hovered_menu != null or self.hovered_menu_item != null or self.hovered_toolbar != null or self.hovered_say_action != null or !self.hovered_composer or self.hovered_status or self.hovered_status_tab or self.hovered_room_tab != null or self.hovered_status_action != null or self.hovered_column_control != null or self.hovered_member != null;
        self.hovered_menu = null;
        self.hovered_menu_item = null;
        self.hovered_toolbar = null;
        self.hovered_say_action = null;
        self.hovered_composer = true;
        self.hovered_status = false;
        self.hovered_status_tab = false;
        self.hovered_room_tab = null;
        self.hovered_status_action = null;
        self.hovered_column_control = null;
        self.hovered_member = null;
        return changed;
    }

    fn setStatusHover(self: *View) bool {
        const changed = self.hovered_menu != null or self.hovered_menu_item != null or self.hovered_toolbar != null or self.hovered_say_action != null or self.hovered_composer or !self.hovered_status or self.hovered_status_tab or self.hovered_room_tab != null or self.hovered_status_action != null or self.hovered_column_control != null or self.hovered_member != null;
        self.hovered_menu = null;
        self.hovered_menu_item = null;
        self.hovered_toolbar = null;
        self.hovered_say_action = null;
        self.hovered_composer = false;
        self.hovered_status = true;
        self.hovered_status_tab = false;
        self.hovered_room_tab = null;
        self.hovered_status_action = null;
        self.hovered_column_control = null;
        self.hovered_member = null;
        return changed;
    }

    fn setStatusTabHover(self: *View) bool {
        const changed = self.hovered_menu != null or self.hovered_menu_item != null or self.hovered_toolbar != null or self.hovered_say_action != null or self.hovered_composer or self.hovered_status or !self.hovered_status_tab or self.hovered_room_tab != null or self.hovered_status_action != null or self.hovered_column_control != null or self.hovered_member != null;
        self.hovered_menu = null;
        self.hovered_menu_item = null;
        self.hovered_toolbar = null;
        self.hovered_say_action = null;
        self.hovered_composer = false;
        self.hovered_status = false;
        self.hovered_status_tab = true;
        self.hovered_room_tab = null;
        self.hovered_status_action = null;
        self.hovered_column_control = null;
        self.hovered_member = null;
        return changed;
    }

    fn setRoomTabHover(self: *View, tab: usize) bool {
        const changed = self.hovered_menu != null or self.hovered_menu_item != null or self.hovered_toolbar != null or self.hovered_say_action != null or self.hovered_composer or self.hovered_status or self.hovered_status_tab or self.hovered_room_tab != tab or self.hovered_status_action != null or self.hovered_column_control != null or self.hovered_member != null;
        self.hovered_menu = null;
        self.hovered_menu_item = null;
        self.hovered_toolbar = null;
        self.hovered_say_action = null;
        self.hovered_composer = false;
        self.hovered_status = false;
        self.hovered_status_tab = false;
        self.hovered_room_tab = tab;
        self.hovered_status_action = null;
        self.hovered_column_control = null;
        self.hovered_member = null;
        return changed;
    }

    fn setStatusActionHover(self: *View, action: ?StatusActionHover) bool {
        const changed = self.hovered_menu != null or self.hovered_menu_item != null or self.hovered_toolbar != null or self.hovered_say_action != null or self.hovered_composer or self.hovered_status or self.hovered_status_tab or self.hovered_room_tab != null or self.hovered_status_action != action or self.hovered_column_control != null or self.hovered_member != null;
        self.hovered_menu = null;
        self.hovered_menu_item = null;
        self.hovered_toolbar = null;
        self.hovered_say_action = null;
        self.hovered_composer = false;
        self.hovered_status = false;
        self.hovered_status_tab = false;
        self.hovered_room_tab = null;
        self.hovered_status_action = action;
        self.hovered_column_control = null;
        self.hovered_member = null;
        return changed;
    }

    pub fn dialogValue(self: *const View) []const u8 {
        return self.dialog_editors[0].text();
    }

    pub fn dialogValueAt(self: *const View, index: usize) []const u8 {
        return self.dialog_editors[@min(index, self.dialog_editors.len - 1)].text();
    }

    pub fn setDialogValueAt(self: *View, index: usize, value: []const u8) !void {
        if (index >= self.dialog_editors.len) return;
        self.dialog_editors[index].clear();
        try self.dialog_editors[index].paste(value);
    }

    pub fn activeDialogEditor(self: *View) ?*input_mod.Editor {
        const id = self.active_dialog orelse return null;
        if (!dialogs.fieldAcceptsText(id, self.dialog_field)) return null;
        if (self.dialog_field >= self.dialog_editors.len) return null;
        return &self.dialog_editors[self.dialog_field];
    }

    pub fn setDialogNotice(self: *View, notice: []const u8) void {
        self.dialog_notice = notice;
    }

    pub fn handleDialogKey(self: *View, key: platform_event.Key, modifiers: platform_event.Modifiers) !?Action {
        const id = self.active_dialog orelse return null;
        const field_count = @min(dialogs.fields(id).len, self.dialog_editors.len);
        const editor = &self.dialog_editors[self.dialog_field];
        switch (key) {
            .escape => {
                _ = self.closeDialog();
                return .{ .dialog_cancel = id };
            },
            .enter => {
                if (self.dialog_browse_focus) return .{ .dialog_browse = id };
                if (self.dialog_gallery_focus) |gallery_focus| {
                    if (self.dialog_field == 0) {
                        switch (gallery_focus) {
                            .family => self.cycleCharacterFamily(true),
                            .previous => self.cycleDialogChoiceDirection(.character, 0, false),
                            .selected => {},
                            .next => self.cycleDialogChoiceDirection(.character, 0, true),
                        }
                        self.syncCharacterSelectionSummary();
                        return .none;
                    }
                }
                if (self.dialog_action_focus == .cancel) {
                    _ = self.closeDialog();
                    return .{ .dialog_cancel = id };
                }
                return .{ .dialog_accept = id };
            },
            .tab => {
                if (id == .character and self.dialog_gallery_focus != null) {
                    if (modifiers.shift) {
                        self.dialog_gallery_focus = null;
                        self.dialog_field = 0;
                    } else {
                        self.dialog_gallery_focus = null;
                        self.dialog_field = 1;
                    }
                    self.ensureDialogFieldVisible(id);
                    return .none;
                }
                if (!modifiers.shift and id == .character and self.dialog_action_focus == null and self.dialog_field == 0) {
                    self.dialog_gallery_focus = .family;
                    return .none;
                }
                if (!modifiers.shift and self.dialog_action_focus == null and !self.dialog_browse_focus and dialogBrowseField(id) == self.dialog_field) {
                    self.dialog_browse_focus = true;
                    return .none;
                }
                if (self.dialog_browse_focus) {
                    self.dialog_browse_focus = false;
                    if (modifiers.shift) {
                        self.dialog_field = dialogBrowseField(id).?;
                        self.ensureDialogFieldVisible(id);
                        return .none;
                    }
                }
                const action_count: usize = if (dialogs.showsCancel(id)) 2 else 1;
                const total = field_count + action_count;
                if (total != 0) {
                    var position: usize = if (self.dialog_action_focus) |button|
                        field_count + @as(usize, if (button == .primary) 0 else 1)
                    else
                        self.dialog_field;
                    var attempts: usize = 0;
                    while (attempts < total) : (attempts += 1) {
                        position = if (modifiers.shift) (position + total - 1) % total else (position + 1) % total;
                        if (position >= field_count or dialogFieldFocusable(dialogs.fields(id)[position])) break;
                    }
                    if (position < field_count) {
                        self.dialog_field = position;
                        self.dialog_action_focus = null;
                        self.dialog_browse_focus = false;
                        self.ensureDialogFieldVisible(id);
                    } else {
                        self.dialog_action_focus = if (position == field_count) .primary else .cancel;
                    }
                }
            },
            .char => |ch| {
                if (self.dialog_browse_focus) return .none;
                if (modifiers.control) {
                    const shortcut = if (ch <= 0x7f) std.ascii.toLower(@intCast(ch)) else 0;
                    switch (shortcut) {
                        'a' => editor.selectAll(),
                        'z' => editor.undo(),
                        'y' => editor.redo(),
                        else => {},
                    }
                } else if (dialogs.fieldAcceptsText(id, self.dialog_field) and editor.text().len < 512) {
                    try editor.insert(ch);
                    self.dialog_notice = "";
                }
            },
            .backspace => if (dialogs.fieldAcceptsText(id, self.dialog_field) and self.dialog_action_focus == null and !self.dialog_browse_focus) {
                editor.backspace();
                self.dialog_notice = "";
            },
            .delete => if (dialogs.fieldAcceptsText(id, self.dialog_field) and self.dialog_action_focus == null and !self.dialog_browse_focus) {
                editor.delete();
                self.dialog_notice = "";
            },
            .left => if (self.dialog_action_focus == null and !self.dialog_browse_focus) {
                if (self.dialog_gallery_focus) |gallery_focus| {
                    if (self.dialog_field == 0) {
                        switch (gallery_focus) {
                            .family => self.cycleCharacterFamily(false),
                            .previous, .selected, .next => self.cycleDialogChoiceDirection(.character, 0, false),
                        }
                        self.syncCharacterSelectionSummary();
                        return .none;
                    }
                }
                if (dialogs.fields(id)[self.dialog_field].kind == .choice)
                    self.cycleDialogChoiceDirection(id, self.dialog_field, false)
                else if (dialogs.fieldAcceptsText(id, self.dialog_field))
                    if (modifiers.shift) editor.extendLeft() else editor.left();
            },
            .right => if (self.dialog_action_focus == null and !self.dialog_browse_focus) {
                if (self.dialog_gallery_focus) |gallery_focus| {
                    if (self.dialog_field == 0) {
                        switch (gallery_focus) {
                            .family => self.cycleCharacterFamily(true),
                            .previous, .selected, .next => self.cycleDialogChoiceDirection(.character, 0, true),
                        }
                        self.syncCharacterSelectionSummary();
                        return .none;
                    }
                }
                if (dialogs.fields(id)[self.dialog_field].kind == .choice)
                    self.cycleDialogChoiceDirection(id, self.dialog_field, true)
                else if (dialogs.fieldAcceptsText(id, self.dialog_field))
                    if (modifiers.shift) editor.extendRight() else editor.right();
            },
            .home => if (dialogs.fieldAcceptsText(id, self.dialog_field) and self.dialog_action_focus == null and !self.dialog_browse_focus) {
                if (modifiers.shift) editor.extendHome() else editor.home();
            },
            .end => if (dialogs.fieldAcceptsText(id, self.dialog_field) and self.dialog_action_focus == null and !self.dialog_browse_focus) {
                if (modifiers.shift) editor.extendEnd() else editor.end();
            },
            else => {},
        }
        return .none;
    }

    fn ensureDialogFieldVisible(self: *View, id: dialogs.Id) void {
        const layout = dialogLayout(self.canvas.width, self.canvas.height, dialogs.get(id));
        const visible = layout.visibleRows();
        if (self.dialog_field < self.dialog_first_field) self.dialog_first_field = self.dialog_field;
        if (self.dialog_field >= self.dialog_first_field + visible)
            self.dialog_first_field = self.dialog_field - visible + 1;
        const count = dialogs.fields(id).len;
        self.dialog_first_field = @min(self.dialog_first_field, count -| visible);
    }

    pub fn handlePointer(self: *View, pointer: platform_event.Pointer, total_lines: usize, member_count: usize) Action {
        if (pointer.kind == .up) {
            self.emotion_dragging = false;
            return .none;
        }
        if (self.active_dialog) |id| {
            const spec = dialogs.get(id);
            const dialog_layout = dialogLayout(self.canvas.width, self.canvas.height, spec);
            if (pointer.kind == .wheel) {
                const visible = dialog_layout.visibleRows();
                const maximum = dialogs.fields(id).len -| visible;
                if (pointer.wheel_y < 0) self.dialog_first_field = @min(maximum, self.dialog_first_field + 1);
                if (pointer.wheel_y > 0) self.dialog_first_field -|= 1;
                return .none;
            }
            if (pointer.kind != .down or pointer.button != .primary) return .none;
            if (ui.dialogButtonAt(dialog_layout, pointer.x, pointer.y)) |button| {
                self.dialog_action_focus = button;
                switch (button) {
                    .primary => return .{ .dialog_accept = id },
                    .cancel => {
                        _ = self.closeDialog();
                        return .{ .dialog_cancel = id };
                    },
                }
            }
            if (id == .character and ui.contains(characterGalleryRect(dialog_layout, self.dialog_first_field), pointer.x, pointer.y)) {
                const gallery = characterGalleryRect(dialog_layout, self.dialog_first_field);
                const family_rect = characterFamilyRect(gallery);
                if (family_rect.h > 0 and ui.contains(family_rect, pointer.x, pointer.y)) {
                    const options = dialogs.choiceOptions(.character, 0);
                    const family_len = options.len / 3;
                    const family = @min(@as(usize, @intCast(@divTrunc(pointer.x - family_rect.x, @max(1, @divTrunc(family_rect.w, 3))))), @as(usize, 2));
                    self.selectCharacterFamily(family, family_len);
                    self.dialog_gallery_focus = .family;
                } else if (pointer.x < gallery.x + @divTrunc(gallery.w, 3)) {
                    self.dialog_gallery_focus = .previous;
                    self.cycleDialogChoiceDirection(id, 0, false);
                } else if (pointer.x >= gallery.x + @divTrunc(gallery.w * 2, 3)) {
                    self.dialog_gallery_focus = .next;
                    self.cycleDialogChoiceDirection(id, 0, true);
                }
                self.syncCharacterSelectionSummary();
                return .none;
            }
            if (dialog_layout.fieldIndexAtScrolled(pointer.x, pointer.y, self.dialog_first_field)) |index| {
                if (index < self.dialog_editors.len) {
                    if (dialogBrowseField(id) == index and ui.contains(dialogBrowseRect(dialog_layout.fieldRectScrolled(index, self.dialog_first_field)), pointer.x, pointer.y)) {
                        self.dialog_browse_focus = true;
                        return .{ .dialog_browse = id };
                    }
                    self.dialog_field = index;
                    self.dialog_action_focus = null;
                    self.dialog_browse_focus = false;
                    const field = dialogs.fields(id)[index];
                    if (field.kind == .choice) {
                        self.cycleDialogChoice(id, index);
                        self.dialog_notice = "";
                    } else if (dialogs.fieldAcceptsText(id, index)) {
                        const field_rect = dialog_layout.fieldRectScrolled(index, self.dialog_first_field);
                        const editor = &self.dialog_editors[index];
                        const content_width = field_rect.w - if (field.kind == .password) @as(i32, 46) else @as(i32, 20);
                        const window = visibleTextWindow(editor.text(), editor.cursor, content_width);
                        placeEditorCursor(editor, window, pointer.x - field_rect.x - 11);
                    }
                }
            }
            return .none;
        }
        if (self.status_panel_open and pointer.kind == .down and pointer.button == .primary) {
            const status_layout = ui.StatusPanelLayout.init(self.canvas.width, self.canvas.height, self.status_detailed);
            const panel = status_layout.rect;
            if (!ui.contains(panel, pointer.x, pointer.y)) {
                self.status_panel_open = false;
                self.hovered_status_action = null;
                return .none;
            }
            if (ui.contains(status_layout.connection, pointer.x, pointer.y)) {
                self.status_panel_open = false;
                self.hovered_status_action = null;
                return .connection;
            }
            if (ui.contains(status_layout.settings, pointer.x, pointer.y)) {
                self.status_panel_open = false;
                self.hovered_status_action = null;
                self.openDialog(.settings);
                return .none;
            }
            return .none;
        }
        if (self.context_menu) |kind| {
            if (pointer.kind != .down or pointer.button != .primary) return .none;
            const item = contextPopupItem(self.canvas.width, self.canvas.height, kind, self.context_x, self.context_y, pointer.x, pointer.y);
            self.context_menu = null;
            self.hovered_context_item = null;
            if (item) |selected| {
                if (!contextItemEnabled(kind, selected, self.can_moderate)) return .none;
                if (kind == .body_camera and selected == 3) return .send_expression;
                self.invokeContextItem(kind, selected);
            }
            return .none;
        }
        if (self.active_menu) |menu| {
            if (pointer.kind != .down or pointer.button != .primary) return .none;
            if (menuPopupItem(self.canvas.width, menu, pointer.x, pointer.y)) |item| {
                return self.activateMenuItem(menu, item);
            }
            self.active_menu = null;
            self.hovered_menu_item = null;
            return .{ .menu = menu };
        }
        const comic_mode = self.shell.content_mode == .comic;
        const layout = geometry.Layout.compute(self.canvas.width, self.canvas.height, comic_mode, self.shell.show_members);
        const target = self.mapMemberTarget(
            hit_test.shell(layout, comic_mode, self.shell.member_view == .icons, pointer.x, pointer.y, member_count),
            member_count,
        );
        if (pointer.kind == .wheel) {
            if (hit_test.contains(layout.members, pointer.x, pointer.y)) {
                const viewport = memberViewport(layout.members, self.shell.member_view == .icons);
                self.shell.scrollMembers(member_count, viewport.visible, viewport.step, pointer.wheel_y < 0);
                return .none;
            }
            switch (target) {
                .transcript => if (pointer.wheel_y > 0) self.pageEarlier(total_lines) else if (pointer.wheel_y < 0) self.pageLater(),
                else => {},
            }
            return .none;
        }
        if (pointer.kind == .down and pointer.button == .secondary) {
            switch (target) {
                .member => |index| {
                    self.shell.selectMember(index);
                    self.openContextMenu(.member, pointer.x, pointer.y);
                },
                .emotion => self.openContextMenu(.body_camera, pointer.x, pointer.y),
                else => {},
            }
            return .none;
        }
        if (pointer.kind != .down or pointer.button != .primary) return .none;
        return switch (target) {
            .none => .none,
            .menu => |index| menu: {
                self.active_menu = index;
                self.shell.focus = .navigation;
                break :menu .{ .menu = index };
            },
            .toolbar => |index| toolbar: {
                self.shell.focus = .toolbar;
                for (ui.ToolbarLayout.command_ids, 0..) |command, position| {
                    if (command == index) self.focused_toolbar = @intCast(position);
                }
                break :toolbar self.activateToolbar(index);
            },
            .room_tab => room: {
                self.shell.focus = .navigation;
                break :room if (roomTabIndexAt(self, layout, comic_mode, pointer.x)) |index|
                    .{ .room_tab = index }
                else
                    .none;
            },
            .comic_columns_decrease => columns: {
                self.shell.decreaseComicColumns();
                break :columns .none;
            },
            .comic_columns_increase => columns: {
                self.shell.increaseComicColumns();
                break :columns .none;
            },
            .transcript => focus: {
                if (self.selectTranscriptAt(layout.transcript, pointer.x, pointer.y, total_lines)) self.shell.focus = .transcript;
                break :focus .none;
            },
            .composer => focus: {
                self.shell.focus = .composer;
                break :focus .{ .composer_cursor = .{ .x = pointer.x, .y = pointer.y } };
            },
            .say_action => |index| say: {
                break :say self.activateSayAction(index);
            },
            .member => |index| selected: {
                self.shell.selectMember(index);
                break :selected .none;
            },
            .emotion => emotion: {
                if (pointer.clicks >= 2 and !ui.contains(ui.moodDialInterior(emotionWheelRect(layout)), pointer.x, pointer.y)) {
                    self.openDialog(.character);
                    break :emotion .none;
                }
                self.emotion_dragging = self.setEmotionFromPoint(layout, pointer.x, pointer.y);
                if (!self.emotion_dragging) self.shell.focus = .emotion;
                break :emotion .none;
            },
            .status_window, .connection_status => status: {
                self.status_panel_open = !self.status_panel_open;
                if (!self.status_panel_open) self.hovered_status_action = null;
                self.active_menu = null;
                break :status .none;
            },
        };
    }

    fn mapMemberTarget(self: *const View, target: hit_test.Target, member_count: usize) hit_test.Target {
        return switch (target) {
            .member => |visible_index| mapped: {
                const index = self.shell.member_offset + visible_index;
                break :mapped if (index < member_count) .{ .member = index } else .none;
            },
            else => target,
        };
    }

    fn selectTranscriptAt(self: *View, rect: Rect, x: i32, y: i32, total_lines: usize) bool {
        _ = x;
        if (total_lines == 0 or rect.h <= 0) return false;
        const text_header_h: i32 = 30;
        const text_row_h: i32 = 46;
        const capacity: usize = if (self.shell.content_mode == .text)
            @intCast(@max(1, @divTrunc(rect.h - text_header_h - 10, text_row_h)))
        else
            9;
        const range = self.shell.visibleRange(total_lines, capacity);
        if (range.end <= range.start) return false;
        if (self.shell.content_mode == .text) {
            const first_row_y = rect.y + text_header_h + 4;
            const last_row_y = first_row_y + @as(i32, @intCast(range.end - range.start)) * text_row_h;
            if (y < first_row_y or y >= last_row_y) return false;
        }
        const relative = if (self.shell.content_mode == .text)
            std.math.clamp(y - rect.y - text_header_h - 4, 0, @max(0, @as(i32, @intCast(range.end - range.start)) * text_row_h - 1))
        else
            std.math.clamp(y - rect.y, 0, rect.h - 1);
        const visible_index: usize = if (self.shell.content_mode == .text)
            @intCast(@min(range.end - range.start - 1, @as(usize, @intCast(@divTrunc(relative, text_row_h)))))
        else
            @intCast(@min(range.end - range.start - 1, @as(usize, @intCast(@divTrunc(relative * @as(i32, @intCast(range.end - range.start)), @max(1, rect.h))))));
        self.shell.selectTranscriptLine(total_lines, range.start + visible_index, false);
        return true;
    }

    pub fn placeComposerCursor(self: *View, editor: *input_mod.Editor, pointer_x: i32, pointer_y: i32) void {
        const layout = geometry.Layout.compute(self.canvas.width, self.canvas.height, self.shell.content_mode == .comic, self.shell.show_members);
        const editor_layout = ui.ComposerEditorLayout.init(layout.say_editor);
        const viewport = composerViewport(editor.text(), editor.cursor, editor_layout.content.w);
        if (viewport.count == 0) return;
        const row = editor_layout.rowAtY(pointer_y, viewport.count);
        placeEditorCursor(editor, viewport.rows[@min(row, viewport.count - 1)].window, pointer_x - editor_layout.content.x);
    }

    fn openContextMenu(self: *View, kind: ContextKind, x: i32, y: i32) void {
        self.active_menu = null;
        self.context_menu = kind;
        self.context_x = x;
        self.context_y = y;
        self.hovered_context_item = null;
        self.focused_context_item = firstEnabledContextItem(kind, self.can_moderate);
    }

    fn activateToolbar(self: *View, index: u8) Action {
        if (index == 0) return .connection;
        switch (index) {
            1, 3, 19, 20, 21, 22 => {},
            2 => self.openDialog(.channel),
            4 => self.openDialog(.channel_create),
            5 => self.setContentMode(.comic),
            6 => self.setContentMode(.text),
            7, 9 => self.openDialog(.room_list),
            8 => self.toggleMembers(),
            10 => self.openDialog(.away),
            11, 14, 15, 16 => self.openDialog(.personal),
            12 => self.openDialog(.notifications),
            13 => self.openDialog(.whisper),
            17 => self.openDialog(.set_text_font),
            18, 23 => self.openDialog(.choose_color),
            else => {},
        }
        return .{ .toolbar = index };
    }

    fn activateSayAction(self: *View, index: u8) Action {
        self.focused_say_action = index;
        self.shell.focus = .say_actions;
        if (index == @intFromEnum(shell_mod.SayMode.sound)) {
            self.openDialog(.sound);
            return .none;
        }
        self.shell.setSayMode(@enumFromInt(index));
        self.shell.focus = .say_actions;
        return .send;
    }

    fn invokeContextItem(self: *View, kind: ContextKind, item: u8) void {
        switch (kind) {
            .body_camera => switch (item) {
                0 => self.shell.toggleEmotionFreeze(),
                1 => self.openDialog(.character),
                2 => {
                    self.shell.emotion_frozen = false;
                    self.shell.neutralEmotion();
                },
                else => {},
            },
            .member => switch (item) {
                0 => {
                    self.shell.setSayMode(.whisper);
                },
                1 => self.openDialog(.member_profile),
                2 => self.openDialog(.invite),
                3 => self.openDialog(.kick),
                else => self.openDialog(.ban),
            },
        }
    }

    fn cycleDialogChoice(self: *View, id: dialogs.Id, index: usize) void {
        self.cycleDialogChoiceDirection(id, index, true);
    }

    fn cycleDialogChoiceDirection(self: *View, id: dialogs.Id, index: usize, forward: bool) void {
        const options = dialogs.choiceOptions(id, index);
        if (options.len == 0 or index >= self.dialog_editors.len) return;
        const editor = &self.dialog_editors[index];
        var next: usize = 0;
        for (options, 0..) |option, option_index| {
            if (std.mem.eql(u8, editor.text(), option)) {
                if (id == .character and index == 0 and options.len % 3 == 0) {
                    const family_len = options.len / 3;
                    const family_start = @divTrunc(option_index, family_len) * family_len;
                    const family_index = option_index - family_start;
                    next = family_start + if (forward) (family_index + 1) % family_len else (family_index + family_len - 1) % family_len;
                } else {
                    next = if (forward) (option_index + 1) % options.len else (option_index + options.len - 1) % options.len;
                }
                break;
            }
        }
        editor.clear();
        editor.paste(options[next]) catch {};
        if (id == .character) self.syncCharacterSelectionSummary();
    }

    fn syncCharacterSelectionSummary(self: *View) void {
        const expression = self.dialogValueAt(1);
        if (std.ascii.eqlIgnoreCase(expression, "Neutral")) {
            self.shell.neutralEmotion();
        } else {
            const point = if (std.ascii.eqlIgnoreCase(expression, "Happy"))
                .{ @as(i32, 36), @as(i32, 0) }
            else if (std.ascii.eqlIgnoreCase(expression, "Laughing"))
                .{ @as(i32, 28), @as(i32, -28) }
            else if (std.ascii.eqlIgnoreCase(expression, "Angry"))
                .{ @as(i32, -28), @as(i32, -28) }
            else if (std.ascii.eqlIgnoreCase(expression, "Sad"))
                .{ @as(i32, -36), @as(i32, 0) }
            else
                .{ @as(i32, 0), @as(i32, -36) };
            self.shell.setEmotionPoint(point[0], point[1], 48);
        }
    }

    fn selectCharacterFamily(self: *View, family: usize, family_len: usize) void {
        const options = dialogs.choiceOptions(.character, 0);
        if (family_len == 0 or options.len < family_len * 3) return;
        const editor = &self.dialog_editors[0];
        var character_index: usize = 0;
        for (options, 0..) |option, index| if (std.ascii.eqlIgnoreCase(option, editor.text())) {
            character_index = index % family_len;
            break;
        };
        editor.clear();
        editor.paste(options[family * family_len + character_index]) catch {};
    }

    fn cycleCharacterFamily(self: *View, forward: bool) void {
        const options = dialogs.choiceOptions(.character, 0);
        if (options.len == 0 or options.len % 3 != 0) return;
        const family_len = options.len / 3;
        var current: usize = 0;
        for (options, 0..) |option, index| if (std.ascii.eqlIgnoreCase(option, self.dialog_editors[0].text())) {
            current = @divTrunc(index, family_len);
            break;
        };
        self.selectCharacterFamily(if (forward) (current + 1) % 3 else (current + 2) % 3, family_len);
    }

    fn setEmotionFromPoint(self: *View, layout: geometry.Layout, x: i32, y: i32) bool {
        const dial = ui.moodDialInterior(emotionWheelRect(layout));
        if (dial.w < 72 or dial.h < 72 or !ui.contains(dial, x, y)) return false;
        const cx = dial.x + @divTrunc(dial.w, 2);
        const cy = dial.y + @divTrunc(dial.h, 2);
        const radius = @max(1, @min(@divTrunc(dial.w, 2), @divTrunc(dial.h, 2)) - 9);
        const dx = x - cx;
        const dy = y - cy;
        if (dx * dx + dy * dy > radius * radius) return false;
        self.shell.setEmotionPoint(dx, dy, radius);
        return true;
    }

    /// Render the complete Microsoft-shaped application frame and chat buffer.
    pub fn render(
        self: *View,
        title: []const u8,
        status: []const u8,
        transcript: *const session.Transcript,
        input: []const u8,
        cursor: usize,
    ) !void {
        const tabs = [_]Tab{.{ .label = title }};
        return self.renderTabs(status, transcript, input, cursor, null, &tabs, 0);
    }

    pub const Tab = struct { label: []const u8, unread: u32 = 0 };

    pub fn renderTabs(
        self: *View,
        status: []const u8,
        transcript: *const session.Transcript,
        input: []const u8,
        cursor: usize,
        selection: ?TextSelection,
        tabs: []const Tab,
        active_tab: usize,
    ) !void {
        ui.activateAppearance(self.appearance);
        defer ui.activateAppearance(.{});
        self.can_moderate = false;
        for (transcript.roster.items) |member| if (member.is_self and !member.departed) {
            self.can_moderate = member.role.canModerate();
            break;
        };
        self.room_tab_count = tabs.len;
        const comic_mode = self.shell.content_mode == .comic;
        const layout = geometry.Layout.compute(self.canvas.width, self.canvas.height, comic_mode, self.shell.show_members);
        updateTabViewport(self, layout, comic_mode, tabs.len, active_tab);
        self.canvas.clear(ui.current.chrome);

        drawMenuBar(&self.canvas, layout.menu, self.active_menu, self.hovered_menu);
        drawToolBar(&self.canvas, layout.toolbar, comic_mode, self.hovered_toolbar, if (self.shell.focus == .toolbar) self.focused_toolbar else null);
        drawTabBar(&self.canvas, layout, tabs, active_tab, self.room_tab_first, self.shell.focus == .navigation, comic_mode, self.shell.comic_columns, self.hovered_column_control, self.status_panel_open, self.hovered_status_tab, self.hovered_room_tab);
        drawSplitters(&self.canvas, layout, comic_mode);

        if (comic_mode) {
            try self.drawComicBuffer(layout.transcript, transcript);
        } else {
            self.drawTextBuffer(layout.transcript, transcript);
        }
        if (layout.right.w > 0) {
            ui.drawInspectorRail(&self.canvas, layout.right);
            try self.drawMemberList(layout.members, transcript, self.shell.member_view == .icons);
            if (comic_mode) try self.drawBodyCamera(layout.body_camera, transcript);
        }
        drawSayWindow(&self.canvas, layout, input, cursor, selection, self.shell.focus == .composer, self.hovered_composer, self.shell.say_mode, self.hovered_say_action, if (self.shell.focus == .say_actions) self.focused_say_action else null);
        drawStatusBar(&self.canvas, layout.status, self.hoveredToolbarLabel() orelse status, transcript.activeMemberCount(), self.hovered_status);

        if (self.shell.focus == .transcript) drawFocus(&self.canvas, layout.transcript);
        if (self.shell.focus == .members) drawFocus(&self.canvas, layout.members);
        if (self.shell.focus == .emotion) drawFocus(&self.canvas, layout.body_camera);
        if (self.hovered_toolbar) |index| drawToolbarTooltip(&self.canvas, layout, index);
        if (self.hovered_say_action) |index| drawSayActionTooltip(&self.canvas, layout, index);
        if (self.active_menu) |menu| drawMenuPopup(&self.canvas, menu, self.hovered_menu_item, self.shell, self.can_moderate);
        if (self.context_menu) |kind| drawContextPopup(&self.canvas, kind, self.context_x, self.context_y, self.hovered_context_item orelse self.focused_context_item, self.shell.emotion_frozen, self.can_moderate);
        if (self.status_panel_open) drawStatusPanel(&self.canvas, status, transcript.activeMemberCount(), self.shell, self.appearance, self.status_detailed, self.hovered_status_action);
        if (self.active_dialog) |id| drawDialog(&self.canvas, dialogs.get(id), &self.dialog_editors, self.dialog_field, self.dialog_first_field, self.dialog_action_focus, self.hovered_dialog_field, self.hovered_dialog_browse, self.dialog_notice, self.hovered_dialog_button);
    }

    fn hoveredToolbarLabel(self: *const View) ?[]const u8 {
        const index = self.hovered_toolbar orelse return null;
        return toolbarLabel(index);
    }

    pub fn semanticSnapshot(self: *const View, status: []const u8, tabs: []const Tab, active_tab: usize) accessibility.Snapshot {
        const comic_mode = self.shell.content_mode == .comic;
        const layout = geometry.Layout.compute(self.canvas.width, self.canvas.height, comic_mode, self.shell.show_members);
        var snapshot: accessibility.Snapshot = .{ .status = status };
        snapshot.append(.{ .id = "comic-chat", .role = .window, .bounds = .{ .x = 0, .y = 0, .w = @intCast(self.canvas.width), .h = @intCast(self.canvas.height) }, .label = "Comic Chat" });
        snapshot.append(.{ .id = "menu", .role = .menu_bar, .bounds = layout.menu, .label = "Application menu", .focused = self.shell.focus == .navigation });
        snapshot.append(.{ .id = "toolbar", .role = .toolbar, .bounds = layout.toolbar, .label = "Application tools", .focused = self.shell.focus == .toolbar });
        const toolbar_layout = ui.ToolbarLayout.init(layout.toolbar);
        for (ui.ToolbarLayout.command_ids, 0..) |command, index| if (toolbar_layout.buttonRect(index)) |bounds| snapshot.append(.{
            .id = toolbarSemanticId(index),
            .role = .button,
            .bounds = bounds,
            .label = toolbarLabel(command),
            .focused = self.shell.focus == .toolbar and self.focused_toolbar == index,
        });
        snapshot.append(.{ .id = "rooms", .role = .tab_list, .bounds = layout.tabs, .label = "Rooms", .focused = self.shell.focus == .navigation });
        if (comic_mode and layout.transcript.w >= 430) {
            snapshot.append(.{ .id = "comic-columns-decrease", .role = .button, .bounds = geometry.comicColumnDecrease(layout), .label = "Fewer panels across" });
            snapshot.append(.{ .id = "comic-columns-increase", .role = .button, .bounds = geometry.comicColumnIncrease(layout), .label = "More panels across" });
        }
        const viewport = tabViewport(layout, comic_mode);
        for (tabs[self.room_tab_first..], self.room_tab_first..) |tab, index| {
            const slot: i32 = @intCast(index - self.room_tab_first);
            const tab_x = viewport.first_x + slot * 164;
            if (tab_x + 164 > viewport.right) break;
            snapshot.append(.{
                .id = "room-tab",
                .role = .tab,
                .bounds = .{ .x = tab_x, .y = layout.tabs.y + 5, .w = 164, .h = layout.tabs.h - 5 },
                .label = tab.label,
                .selected = index == active_tab,
                .focused = index == active_tab and self.shell.focus == .navigation,
            });
        }
        snapshot.append(.{ .id = "transcript", .role = .transcript, .bounds = layout.transcript, .label = "Conversation", .focused = self.shell.focus == .transcript });
        if (layout.right.w > 0) snapshot.append(.{ .id = "members", .role = .member_list, .bounds = layout.members, .label = "Members", .focused = self.shell.focus == .members });
        snapshot.append(.{ .id = "composer", .role = .composer, .bounds = layout.say_editor, .label = "Message", .focused = self.shell.focus == .composer });
        var action_index: i32 = 0;
        while (action_index < geometry.say_button_count) : (action_index += 1) snapshot.append(.{
            .id = sayActionSemanticId(@intCast(action_index)),
            .role = .say_action,
            .bounds = .{ .x = layout.say_actions.x + action_index * layout.say_action_size, .y = layout.say_actions.y, .w = layout.say_action_size, .h = layout.say_actions.h },
            .label = sayActionLabel(@intCast(action_index)),
            .selected = @as(i32, @intFromEnum(self.shell.say_mode)) == action_index,
            .focused = self.shell.focus == .say_actions and self.focused_say_action == action_index,
        });
        snapshot.append(.{ .id = "status-tab", .role = .button, .bounds = .{ .x = layout.tabs.x, .y = layout.tabs.y, .w = 108, .h = layout.tabs.h }, .label = "Status", .selected = self.status_panel_open, .focused = self.hovered_status_tab });
        snapshot.append(.{ .id = "status", .role = .button, .bounds = layout.status, .label = status, .focused = self.hovered_status });
        if (self.status_panel_open) snapshot.append(.{ .id = "status-panel", .role = .dialog, .bounds = statusPanelRect(self.canvas.width, self.canvas.height, self.status_detailed), .label = "Connection and activity status", .focused = true });
        if (self.active_menu) |menu| {
            const popup = ui.PopupLayout.menu(self.canvas.width, menuStart(menu), geometry.menu_height, menuPopupRect(self.canvas.width, menu).w, menuItemCount(menu));
            snapshot.append(.{ .id = "active-menu", .role = .menu, .bounds = popup.rect, .label = menu_labels[menu], .focused = true });
            var item: u8 = 0;
            while (item < menuItemCount(menu)) : (item += 1) snapshot.append(.{
                .id = "menu-item",
                .role = .menu_item,
                .bounds = popup.itemRect(item).?,
                .label = menuItemLabel(menu, item),
                .selected = self.hovered_menu_item == item,
                .enabled = menuItemEnabled(menu, item, self.can_moderate),
            });
        }
        if (self.context_menu) |kind| {
            const popup = ui.PopupLayout.anchored(self.canvas.width, self.canvas.height, self.context_x, self.context_y, 196, contextItemCount(kind));
            snapshot.append(.{ .id = "context-menu", .role = .menu, .bounds = popup.rect, .label = if (kind == .member) "Member actions" else "Body camera actions", .focused = true });
            var item: u8 = 0;
            while (item < contextItemCount(kind)) : (item += 1) snapshot.append(.{
                .id = contextSemanticId(kind, item),
                .role = .menu_item,
                .bounds = popup.itemRect(item).?,
                .label = contextItemLabel(kind, item, self.shell.emotion_frozen),
                .selected = self.focused_context_item == item,
                .focused = self.focused_context_item == item,
                .enabled = contextItemEnabled(kind, item, self.can_moderate),
            });
        }
        if (self.active_dialog) |id| {
            // A modal owns the semantic tree while open. Background controls
            // remain visible behind the scrim but cannot receive focus.
            snapshot.len = 1;
            const dialog_layout = dialogLayout(self.canvas.width, self.canvas.height, dialogs.get(id));
            snapshot.append(.{ .id = "dialog", .role = .dialog, .bounds = dialog_layout.rect, .label = dialogs.get(id).title });
            const field_ids = [_][]const u8{ "dialog-field-1", "dialog-field-2", "dialog-field-3", "dialog-field-4", "dialog-field-5", "dialog-field-6", "dialog-field-7", "dialog-field-8" };
            const visible_rows = dialog_layout.visibleRows();
            for (dialogs.fields(id), 0..) |field, index| {
                if (index < self.dialog_first_field or index >= self.dialog_first_field + visible_rows) continue;
                snapshot.append(.{
                    .id = field_ids[@min(index, field_ids.len - 1)],
                    .role = switch (field.kind) {
                        .choice => .combo_box,
                        .list => .list_item,
                        else => .input,
                    },
                    .bounds = dialog_layout.fieldRectScrolled(index, self.dialog_first_field),
                    .label = field.label,
                    .focused = self.dialog_action_focus == null and self.dialog_field == index,
                    .enabled = field.kind != .readonly and field.kind != .preview,
                });
            }
            if (dialogBrowseField(id)) |index| if (index >= self.dialog_first_field and index < self.dialog_first_field + visible_rows) snapshot.append(.{
                .id = "dialog-browse",
                .role = .button,
                .bounds = dialogBrowseRect(dialog_layout.fieldRectScrolled(index, self.dialog_first_field)),
                .label = "Browse files",
                .focused = self.dialog_browse_focus,
            });
            if (id == .character) {
                const gallery = characterGalleryRect(dialog_layout, self.dialog_first_field);
                const family = characterFamilyRect(gallery);
                const cards = characterGalleryCardsRect(gallery);
                const family_labels = [_][]const u8{ "HD characters", "Color characters", "Original characters" };
                const family_ids = [_][]const u8{ "dialog-character-family-hd", "dialog-character-family-color", "dialog-character-family-original" };
                if (family.h > 0) for (family_labels, 0..) |label, index| snapshot.append(.{
                    .id = family_ids[index],
                    .role = .button,
                    .bounds = .{ .x = family.x + @as(i32, @intCast(index)) * @divTrunc(family.w, 3), .y = family.y, .w = @divTrunc(family.w, 3), .h = family.h },
                    .label = label,
                    .focused = self.dialog_gallery_focus == .family,
                });
                const card_w = @divTrunc(cards.w - 16, 3);
                const card_labels = [_][]const u8{ "Previous character", "Selected character", "Next character" };
                const card_ids = [_][]const u8{ "dialog-character-previous", "dialog-character-selected", "dialog-character-next" };
                if (card_w > 12) for (card_labels, 0..) |label, index| snapshot.append(.{
                    .id = card_ids[index],
                    .role = .button,
                    .bounds = .{ .x = cards.x + 6 + @as(i32, @intCast(index)) * card_w, .y = cards.y + 4, .w = card_w - 6, .h = cards.h - 8 },
                    .label = label,
                    .selected = index == 1,
                    .focused = self.dialog_gallery_focus == @as(DialogGalleryFocus, switch (index) {
                        0 => .previous,
                        1 => .selected,
                        else => .next,
                    }),
                });
            }
            snapshot.append(.{ .id = "dialog-accept", .role = .button, .bounds = dialog_layout.primary, .label = dialogs.primaryLabel(id), .focused = self.dialog_action_focus == .primary });
            if (dialogs.showsCancel(id)) snapshot.append(.{ .id = "dialog-cancel", .role = .button, .bounds = dialog_layout.cancel, .label = "Cancel", .focused = self.dialog_action_focus == .cancel });
        }
        return snapshot;
    }

    fn drawComicBuffer(self: *View, rect: Rect, transcript: *const session.Transcript) !void {
        ui.drawContentSurface(&self.canvas, rect, true);
        if (rect.w <= 0 or rect.h <= 0) return;

        const all = transcript.lines.items;
        const range = self.shell.visibleRange(all.len, 9);
        // Source AddLine/hysteresis/RNG consume the whole prefix. A 9-line
        // slice would replan those panels as a new first page.
        const prefix = all[0..range.end];
        const lines = try self.gpa.alloc(strip.Line, prefix.len);
        defer self.gpa.free(lines);
        const target_views = try self.gpa.alloc([]strip.Participant, prefix.len);
        var target_views_count: usize = 0;
        defer {
            for (target_views[0..target_views_count]) |targets| self.gpa.free(targets);
            self.gpa.free(target_views);
        }
        for (prefix, 0..) |line, i| {
            const targets = try self.gpa.alloc(strip.Participant, line.talk_targets.len);
            target_views[i] = targets;
            target_views_count += 1;
            for (line.talk_targets, 0..) |target, target_index| targets[target_index] = .{
                .identity = target.nick,
                .display_name = target.nick,
                .avatar = target.avatar,
            };
            lines[i] = .{
                .identity = line.nick,
                .display_name = line.nick,
                .avatar = line.avatar,
                .text = line.text,
                .formatting = line.formatting,
                .pose_text = line.pose_text,
                .pose_state = line.pose_state,
                .talk_targets = targets,
                .modes = line.modes,
            };
        }

        const title_roster = try self.gpa.alloc(strip.TitleParticipant, transcript.roster.items.len);
        defer self.gpa.free(title_roster);
        for (transcript.roster.items, 0..) |member, index| title_roster[index] = .{
            .identity = member.nick,
            .display_name = member.nick,
            .avatar = member.avatar,
            .is_self = member.is_self,
            .sends = member.sends,
            .departed = member.departed,
        };

        const backdrop = dialogBackgroundByName(transcript.resolvedBackdrop()) orelse dialogBackgroundByName("field").?;
        var page = try strip.renderWithOptions(self.gpa, lines, .{
            .title_roster = title_roster,
            .backdrop = backdrop,
            .page_columns = self.shell.comic_columns,
            .reserve_page_columns = true,
        });
        defer page.deinit(self.gpa);
        blitSourcePage(&self.canvas, page.pixels, page.width, page.height, rect.x + 8, rect.y + 8, rect.w - 16, rect.h - 16);

        if (all.len == 0) {
            const caption_w = @min(400, @max(220, rect.w - 40));
            const caption_h: i32 = 88;
            ui.drawEmptyCaption(&self.canvas, .{
                .x = rect.x + @divTrunc(rect.w - caption_w, 2),
                .y = rect.bottom() - caption_h - 12,
                .w = caption_w,
                .h = caption_h,
            }, "Sunday page is open", "Ink a line and press Enter");
        }

        if (self.shell.history_offset > 0) {
            ui.drawHistoryBanner(&self.canvas, rect, "Earlier page — Page Down returns to the latest panels");
        }
        ui.drawVerticalScrollbar(&self.canvas, rect, all.len, 9, range.start);
    }

    fn drawTextBuffer(self: *View, rect: Rect, transcript: *const session.Transcript) void {
        ui.drawContentSurface(&self.canvas, rect, false);
        if (transcript.lines.items.len == 0) {
            drawEmptyBuffer(&self.canvas, rect, "Ink a line and press Enter", 1);
            return;
        }
        // The text view is a calm reading surface rather than a debug log:
        // room context stays visible, messages have a two-line rhythm, and
        // room state remains visible, and browsing exposes a keyboard path back
        // to live discussion without covering transcript rows.
        const header_h: i32 = 30;
        const row_h: i32 = 46;
        ui.drawConversationHeader(&self.canvas, rect, transcript.lines.items.len, transcript.activeMemberCount(), self.shell.history_offset == 0);
        const capacity: usize = @intCast(@max(1, @divTrunc(rect.h - header_h - 10, row_h)));
        const range = self.shell.visibleRange(transcript.lines.items.len, capacity);
        var y = rect.y + header_h + 4;
        for (transcript.lines.items[range.start..range.end], 0..) |line, index| {
            const absolute_index = range.start + index;
            const selection = self.shell.transcriptSelection();
            const selected = if (selection) |selected_range| absolute_index >= selected_range.start and absolute_index < selected_range.end else false;
            const continued = absolute_index != 0 and std.ascii.eqlIgnoreCase(transcript.lines.items[absolute_index - 1].nick, line.nick);
            const own = isSelfSpeaker(transcript, line.nick);
            ui.drawMessageRow(&self.canvas, .{ .x = rect.x, .y = y, .w = rect.w, .h = row_h }, line.nick, line.text, index % 2 == 0, selected, continued, own);
            y += row_h;
            if (y + row_h > rect.bottom()) break;
        }
        ui.drawVerticalScrollbar(&self.canvas, rect, transcript.lines.items.len, capacity, range.start);
    }

    fn isSelfSpeaker(transcript: *const session.Transcript, nick: []const u8) bool {
        for (transcript.roster.items) |member| {
            if (member.is_self and std.ascii.eqlIgnoreCase(member.nick, nick)) return true;
        }
        return false;
    }

    fn drawMemberList(self: *View, rect: Rect, transcript: *const session.Transcript, icon_mode: bool) !void {
        ui.drawMemberRailSurface(&self.canvas, rect);
        if (rect.h <= 0) return;
        var count_buf: [16]u8 = undefined;
        const count = std.fmt.bufPrint(&count_buf, "{d}", .{transcript.activeMemberCount()}) catch "0";
        ui.drawPaneCountHeader(&self.canvas, rect, "CAST", count);
        const content = Rect{ .x = rect.x, .y = rect.y + 30, .w = rect.w, .h = @max(0, rect.h - 30) };
        if (transcript.roster.items.len == 0) {
            ui.drawEmptyStateCallout(&self.canvas, .{ .x = content.x + 8, .y = content.y + 10, .w = @max(0, content.w - 16), .h = 44 }, "The playbill is empty", "People take a panel when they join");
            return;
        }
        const viewport = memberViewport(rect, icon_mode);
        self.normalizeMemberViewport(transcript.roster.items.len, viewport.visible);
        if (icon_mode) return self.drawMemberIcons(content, transcript);
        var y = content.y + 7;
        const visible_rows: usize = @intCast(@max(1, @divTrunc(content.h - 7, 24)));
        const start = @min(self.shell.member_offset, transcript.roster.items.len);
        for (transcript.roster.items[start..], start..) |member, index| {
            if (y + 24 > content.bottom()) break;
            const selected = if (self.shell.selected_member) |selected_index| selected_index == index else member.is_self;
            ui.drawMemberRow(&self.canvas, .{ .x = content.x, .y = y, .w = content.w, .h = 24 }, member.nick, member.role.badge(), selected, member.departed, member.away, self.hovered_member == index);
            y += 24;
        }
        ui.drawVerticalScrollbar(&self.canvas, content, transcript.roster.items.len, visible_rows, start);
    }

    fn drawMemberIcons(self: *View, rect: Rect, transcript: *const session.Transcript) !void {
        const columns = @max(1, @divTrunc(rect.w, 88));
        const cell_w = @divTrunc(rect.w, columns);
        const cell_h: i32 = 82;
        const visible_rows = @max(1, @divTrunc(rect.h, cell_h));
        const visible_items: usize = @intCast(visible_rows * columns);
        const start = @min(self.shell.member_offset, transcript.roster.items.len);
        for (transcript.roster.items[start..], 0..) |member, visible_index| {
            const index = start + visible_index;
            const column: i32 = @intCast(visible_index % @as(usize, @intCast(columns)));
            const row: i32 = @intCast(visible_index / @as(usize, @intCast(columns)));
            const cell = Rect{
                .x = rect.x + column * cell_w,
                .y = rect.y + row * cell_h,
                .w = cell_w,
                .h = cell_h,
            };
            if (cell.bottom() > rect.bottom()) break;
            const selected = if (self.shell.selected_member) |selected_index| selected_index == index else member.is_self;
            ui.drawMemberCard(&self.canvas, cell, selected, member.departed, member.away, self.hovered_member == index);
            const avatar = displayAvatarByName(member.avatar) orelse continue;
            var icon = bgb.decodeIcon(self.gpa, avatar) catch continue;
            defer icon.deinit(self.gpa);
            blitHeightBottomAlphaSmooth(&self.canvas, icon.pixels, icon.width, icon.height, cell.x + @divTrunc(cell.w - 52, 2), cell.y + 6, 52, 52);
            if (member.role.badge().len != 0) ui.drawPill(&self.canvas, .{ .x = cell.right() - 25, .y = cell.y + 5, .w = 20, .h = 18 }, member.role.badge(), true);
            const name_w = Canvas.uiTextWidth(member.nick);
            drawTextEllipsized(
                &self.canvas,
                member.nick,
                cell.x + @max(3, @divTrunc(cell.w - name_w, 2)),
                cell.y + 59,
                cell.w - 6,
                if (member.departed) ui.current.secondary else ui.current.ink,
            );
        }
        ui.drawVerticalScrollbar(&self.canvas, rect, transcript.roster.items.len, visible_items, start);
    }

    fn normalizeMemberViewport(self: *View, member_count: usize, visible: usize) void {
        if (member_count == 0) {
            self.shell.member_offset = 0;
            self.shell.selected_member = null;
            return;
        }
        self.shell.member_offset = @min(self.shell.member_offset, member_count - 1);
        _ = visible;
        if (self.shell.selected_member) |selected| {
            if (selected >= member_count) self.shell.selected_member = member_count - 1;
        }
    }

    fn drawBodyCamera(self: *View, rect: Rect, transcript: *const session.Transcript) !void {
        if (rect.w <= 0 or rect.h <= 0) return;
        ui.drawCharacterPane(&self.canvas, rect);

        // bodycam.cpp: CacheBullSide uses min(width, 159), disabling the wheel
        // below 93 pixels. The figure occupies the remaining white rectangle.
        const wheel_side = if (rect.w >= 93) @min(rect.w, 159) else 0;
        const body_h = @max(0, rect.h - wheel_side);

        var avatar_name: []const u8 = "anna";
        var character_name: []const u8 = "Character";
        if (self.shell.selected_member) |selected_index| {
            if (selected_index < transcript.roster.items.len) {
                const member = transcript.roster.items[selected_index];
                avatar_name = member.avatar;
                character_name = member.nick;
            }
        } else for (transcript.roster.items) |member| if (member.is_self) {
            avatar_name = member.avatar;
            character_name = member.nick;
            break;
        };
        const avb_data = displayAvatarByName(avatar_name) orelse return;
        var rendered = selected: {
            const selected_emotion = self.shell.selectedEmotion();
            if (selected_emotion == .neutral) break :selected figure.assembleForText(self.gpa, avb_data, "") catch return;
            const pose = figure.poseStateForEmotion(self.gpa, avb_data, selected_emotion, self.shell.selectedEmotionIntensity()) catch return;
            const detailed = figure.assembleDetailedForSourcePose(self.gpa, avb_data, pose) catch return;
            break :selected detailed.image;
        };
        defer rendered.deinit(self.gpa);
        blitHeightBottomAlphaSmooth(
            &self.canvas,
            rendered.pixels,
            rendered.width,
            rendered.height,
            rect.x + 12,
            rect.y + 30,
            @max(0, rect.w - 24),
            @max(0, body_h - 30),
        );
        if (wheel_side > 0) ui.drawMoodDial(&self.canvas, emotionWheelRectFromPane(rect), emotionLabel(self.shell.emotion_x, self.shell.emotion_y), self.shell.emotion_x, self.shell.emotion_y, self.shell.emotion_radius);
        // Avatar pixels can be opaque even around the figure. Draw the card
        // header last so it remains legible on every source avatar.
        ui.drawIdentityPaneHeader(&self.canvas, rect, "Character", character_name);
    }

    fn invokeMenuItem(self: *View, menu: u8, item: u8) void {
        switch (menu) {
            0 => switch (item) {
                0 => self.openDialog(.open_conversation),
                1 => self.openDialog(.open_locator),
                2 => self.openDialog(.recent_files),
                3 => self.openDialog(.save_conversation),
                4 => self.openDialog(.export_image),
                5 => self.openDialog(.print_preview),
                else => {},
            },
            1 => if (item == 3) self.openDialog(.settings),
            2 => switch (item) {
                0 => self.setContentMode(.comic),
                1 => self.setContentMode(.text),
                2 => self.toggleMembers(),
                3 => self.shell.setMemberView(.icons),
                4 => self.shell.setMemberView(.list),
                else => self.openDialog(.comics_view),
            },
            3 => switch (item) {
                0 => self.openDialog(.set_text_font),
                1 => self.openDialog(.choose_color),
                2 => self.openDialog(.background),
                3 => self.openDialog(.character),
                4 => self.openDialog(.personal),
                else => {},
            },
            4 => switch (item) {
                0 => self.openDialog(.room_list),
                1 => self.openDialog(.channel),
                2 => self.openDialog(.channel_create),
                3 => self.openDialog(.channel_properties),
                4 => self.openDialog(.away),
                5 => self.openDialog(.motd),
                6 => self.openDialog(.ircx_properties),
                7 => self.openDialog(.room_access),
                8 => self.openDialog(.ircx_events),
                9 => self.openDialog(.favorite_rooms),
                else => {},
            },
            5 => switch (item) {
                0 => self.openDialog(.user_list),
                1 => self.openDialog(.member_profile),
                2 => self.openDialog(.whisper),
                3 => self.openDialog(.invite),
                4 => self.openDialog(.kick),
                5 => self.openDialog(.ban),
                6 => self.openDialog(.file_transfer),
                else => self.openDialog(.call_link),
            },
            6 => switch (item) {
                0 => self.openDialog(.setup),
                1 => self.openDialog(.connection_features),
                2 => self.openDialog(.automation),
                3 => self.openDialog(.rules),
                4 => self.openDialog(.rule_sets),
                5 => self.openDialog(.notifications),
                6 => self.openDialog(.notification_users),
                else => self.openDialog(.about),
            },
            else => {},
        }
    }

    fn activateMenuItem(self: *View, menu: u8, item: u8) Action {
        self.active_menu = null;
        self.hovered_menu_item = null;
        if (!menuItemEnabled(menu, item, self.can_moderate)) return .none;
        if (isConnectionMenuItem(menu, item)) return .connection;
        if (isQuitMenuItem(menu, item)) return .quit;
        if (menu == 1 and item < 3) return .{ .transcript_command = item };
        if (menu == 3 and item >= 5) return .{ .composer_format = item - 5 };
        if (menu == 4 and item == 10) return .child_window;
        self.invokeMenuItem(menu, item);
        return .{ .menu = menu };
    }
};

const menu_labels = [_][]const u8{ "File", "Edit", "View", "Format", "Room", "Member", "Tools" };

fn menuStart(menu: u8) i32 {
    var x: i32 = 170;
    var index: u8 = 0;
    while (index < menu and index < menu_labels.len) : (index += 1) x += Canvas.uiTextWidth(menu_labels[index]) + 28;
    return x;
}

fn menuItemCount(menu: u8) u8 {
    return switch (menu) {
        0 => 7,
        3 => 8,
        2 => 6,
        4 => 11,
        5 => 8,
        6 => 8,
        1 => 4,
        else => 1,
    };
}

fn menuItemLabel(menu: u8, item: u8) []const u8 {
    return switch (menu) {
        0 => switch (item) {
            0 => "Open conversation",
            1 => "Open chat locator",
            2 => "Recent conversations",
            3 => "Save conversation",
            4 => "Export comic image",
            5 => "Print and PDF preview",
            else => "Exit",
        },
        1 => switch (item) {
            0 => "Copy selected messages",
            1 => "Insert page break",
            2 => "Delete selected messages",
            else => "Settings",
        },
        2 => switch (item) {
            0 => "Comic view",
            1 => "Text view",
            2 => "Show members",
            3 => "Member icons",
            4 => "Member list",
            else => "Comic view options",
        },
        3 => switch (item) {
            0 => "Text font",
            1 => "Text color",
            2 => "Background",
            3 => "Character",
            4 => "Personal profile",
            5 => "Bold selection",
            6 => "Italic selection",
            else => "Underline selection",
        },
        4 => switch (item) {
            0 => "Room list",
            1 => "Enter room",
            2 => "Create room",
            3 => "Room properties",
            4 => "Set away message",
            5 => "Message of the day",
            6 => "IRCX properties",
            7 => "Room access",
            8 => "IRCX operator events",
            9 => "Favorite rooms",
            else => "Open room in new window",
        },
        5 => switch (item) {
            0 => "User list",
            1 => "Member profile",
            2 => "Whisper",
            3 => "Invite member",
            4 => "Kick member",
            5 => "Ban or unban",
            6 => "File transfer",
            else => "Send call link",
        },
        6 => switch (item) {
            0 => "Connection setup",
            1 => "Connection features",
            2 => "Automation",
            3 => "Rules",
            4 => "Rule sets",
            5 => "Logon notifications",
            6 => "Online notification users",
            else => "About Comic Chat",
        },
        else => "Settings",
    };
}

fn isConnectionMenuItem(menu: u8, item: u8) bool {
    return menu == 6 and item == 0;
}

fn isQuitMenuItem(menu: u8, item: u8) bool {
    return menu == 0 and item == 6;
}

fn menuPopupRect(canvas_width: u32, menu: u8) Rect {
    var content_width: i32 = 210;
    var item: u8 = 0;
    while (item < menuItemCount(menu)) : (item += 1)
        content_width = @max(content_width, Canvas.uiTextWidth(menuItemLabel(menu, item)) + 52);
    return ui.PopupLayout.menu(canvas_width, menuStart(menu), geometry.menu_height, content_width, menuItemCount(menu)).rect;
}

fn menuPopupItem(canvas_width: u32, menu: u8, x: i32, y: i32) ?u8 {
    const layout = ui.PopupLayout.menu(canvas_width, menuStart(menu), geometry.menu_height, menuPopupRect(canvas_width, menu).w, menuItemCount(menu));
    return layout.itemAt(x, y);
}

fn drawMenuBar(c: *Canvas, rect: Rect, active: ?u8, hovered: ?u8) void {
    ui.drawMenuBarSurface(c, rect);
    ui.drawAppBrand(c, rect, "Comic Chat");
    var x = rect.x + 170;
    for (menu_labels, 0..) |item, raw_index| {
        const index: u8 = @intCast(raw_index);
        const selected = active == index or hovered == index;
        const item_w = Canvas.uiTextWidth(item) + 16;
        const edition_reserve: i32 = if (rect.w >= 760) Canvas.uiTextWidth(ui.mastheadEdition(rect.w)) + 42 else 8;
        if (x + item_w > rect.right() - edition_reserve) break;
        ui.drawMenuLabel(c, x, rect.y, item_w, item, selected);
        x += Canvas.uiTextWidth(item) + 28;
    }
}

fn drawMenuPopup(c: *Canvas, menu: u8, hovered: ?u8, shell: shell_mod.State, can_moderate: bool) void {
    const layout = ui.PopupLayout.menu(c.width, menuStart(menu), geometry.menu_height, menuPopupRect(c.width, menu).w, menuItemCount(menu));
    const rect = layout.rect;
    ui.drawPopupListSurface(c, layout);
    var item: u8 = 0;
    while (item < menuItemCount(menu)) : (item += 1) {
        const item_rect = layout.itemRect(item).?;
        if (menuStartsGroup(menu, item))
            ui.drawMenuGroupDivider(c, rect, item_rect.y);
        const enabled = menuItemEnabled(menu, item, can_moderate);
        ui.drawMenuItem(c, item_rect.x, item_rect.y, item_rect.w, menuItemLabel(menu, item), hovered == item, menuItemChecked(menu, item, shell), enabled);
    }
}

fn menuStartsGroup(menu: u8, item: u8) bool {
    return switch (menu) {
        0 => item == 3 or item == 6,
        1 => item == 3,
        2 => item == 2 or item == 5,
        3 => item == 2 or item == 5,
        4 => item == 3 or item == 6 or item == 9 or item == 10,
        5 => item == 2 or item == 4 or item == 6,
        6 => item == 2 or item == 5 or item == 7,
        else => false,
    };
}

fn menuItemEnabled(menu: u8, item: u8, can_moderate: bool) bool {
    if (can_moderate) return true;
    return !((menu == 4 and (item == 3 or item == 7 or item == 8)) or
        (menu == 5 and (item == 4 or item == 5)));
}

fn firstEnabledMenuItem(menu: u8, can_moderate: bool) u8 {
    var item: u8 = 0;
    while (item < menuItemCount(menu)) : (item += 1) if (menuItemEnabled(menu, item, can_moderate)) return item;
    return 0;
}

fn lastEnabledMenuItem(menu: u8, can_moderate: bool) u8 {
    var item = menuItemCount(menu);
    while (item > 0) {
        item -= 1;
        if (menuItemEnabled(menu, item, can_moderate)) return item;
    }
    return 0;
}

fn nextEnabledMenuItem(menu: u8, current: u8, forward: bool, can_moderate: bool) u8 {
    const count = menuItemCount(menu);
    var item = current;
    var checked: u8 = 0;
    while (checked < count) : (checked += 1) {
        item = if (forward) (item + 1) % count else (item + count - 1) % count;
        if (menuItemEnabled(menu, item, can_moderate)) return item;
    }
    return current;
}

fn menuItemChecked(menu: u8, item: u8, shell: shell_mod.State) bool {
    return switch (menu) {
        2 => switch (item) {
            0 => shell.content_mode == .comic,
            1 => shell.content_mode == .text,
            2 => shell.show_members,
            3 => shell.member_view == .icons,
            4 => shell.member_view == .list,
            else => false,
        },
        6 => false,
        else => false,
    };
}

fn contextItemCount(kind: ContextKind) u8 {
    return if (kind == .member) 5 else 4;
}

fn contextItemLabel(kind: ContextKind, item: u8, frozen: bool) []const u8 {
    return switch (kind) {
        .member => switch (item) {
            0 => "Whisper",
            1 => "Personal profile",
            2 => "Invite to room",
            3 => "Kick from room",
            else => "Ban or unban",
        },
        .body_camera => switch (item) {
            0 => if (frozen) "Unfreeze expression" else "Freeze expression",
            1 => "Change character",
            2 => "Return to neutral",
            else => "Send expression",
        },
    };
}

fn contextPopupRect(width: u32, height: u32, kind: ContextKind, anchor_x: i32, anchor_y: i32) Rect {
    return ui.PopupLayout.anchored(width, height, anchor_x, anchor_y, 196, contextItemCount(kind)).rect;
}

fn contextPopupItem(width: u32, height: u32, kind: ContextKind, anchor_x: i32, anchor_y: i32, x: i32, y: i32) ?u8 {
    const layout = ui.PopupLayout.anchored(width, height, anchor_x, anchor_y, 196, contextItemCount(kind));
    return layout.itemAt(x, y);
}

fn drawContextPopup(c: *Canvas, kind: ContextKind, anchor_x: i32, anchor_y: i32, hovered: ?u8, frozen: bool, can_moderate: bool) void {
    const layout = ui.PopupLayout.anchored(c.width, c.height, anchor_x, anchor_y, 196, contextItemCount(kind));
    ui.drawPopupListSurface(c, layout);
    var item: u8 = 0;
    while (item < contextItemCount(kind)) : (item += 1) {
        const item_rect = layout.itemRect(item).?;
        const enabled = contextItemEnabled(kind, item, can_moderate);
        ui.drawMenuItem(c, item_rect.x, item_rect.y, item_rect.w, contextItemLabel(kind, item, frozen), hovered == item, kind == .body_camera and item == 0 and frozen, enabled);
    }
}

fn contextItemEnabled(kind: ContextKind, item: u8, can_moderate: bool) bool {
    return kind != .member or item < 3 or can_moderate;
}

fn contextSemanticId(kind: ContextKind, item: u8) []const u8 {
    const member = [_][]const u8{ "context-member-whisper", "context-member-profile", "context-member-invite", "context-member-kick", "context-member-ban" };
    const camera = [_][]const u8{ "context-camera-freeze", "context-camera-character", "context-camera-neutral", "context-camera-expression" };
    return if (kind == .member) member[item] else camera[item];
}

fn firstEnabledContextItem(kind: ContextKind, can_moderate: bool) u8 {
    return nextEnabledContextItem(kind, 0, true, can_moderate);
}

fn lastEnabledContextItem(kind: ContextKind, can_moderate: bool) u8 {
    return nextEnabledContextItem(kind, contextItemCount(kind) - 1, false, can_moderate);
}

fn nextEnabledContextItem(kind: ContextKind, start: u8, forward: bool, can_moderate: bool) u8 {
    const count = contextItemCount(kind);
    var item = start % count;
    var attempts: u8 = 0;
    while (attempts < count) : (attempts += 1) {
        if (contextItemEnabled(kind, item, can_moderate)) return item;
        item = if (forward) (item + 1) % count else (item + count - 1) % count;
    }
    return 0;
}

fn drawToolBar(c: *Canvas, rect: Rect, comic_mode: bool, hovered: ?u8, focused: ?u8) void {
    ui.drawToolbarSurface(c, rect);
    const toolbar_layout = ui.ToolbarLayout.init(rect);
    for (ui.ToolbarLayout.group_counts, 0..) |_, group| if (toolbar_layout.groupRect(group)) |group_rect| ui.drawToolbarGroup(c, group_rect);
    const primary = [_]struct { glyph: ToolGlyph, index: u8, selected: bool }{
        .{ .glyph = .connect, .index = 0, .selected = false },
        .{ .glyph = .enter_room, .index = 2, .selected = false },
        .{ .glyph = .create_room, .index = 4, .selected = false },
        .{ .glyph = .comic, .index = 5, .selected = comic_mode },
        .{ .glyph = .text, .index = 6, .selected = !comic_mode },
        .{ .glyph = .rooms, .index = 7, .selected = false },
        .{ .glyph = .members, .index = 8, .selected = false },
        .{ .glyph = .away, .index = 10, .selected = false },
        .{ .glyph = .identity, .index = 11, .selected = false },
        .{ .glyph = .whisper, .index = 13, .selected = false },
        .{ .glyph = .font, .index = 17, .selected = false },
        .{ .glyph = .color, .index = 18, .selected = false },
    };
    for (primary, 0..) |item, position| {
        if (toolbar_layout.buttonRect(position)) |button| {
            _ = drawModernToolButton(c, item.glyph, button.x, button.y, item.selected, hovered == item.index);
            if (focused == @as(u8, @intCast(position))) ui.drawFocusRing(c, button);
        }
    }
}

const ToolGlyph = ui.ToolGlyph;

fn toolbarLabel(index: u8) []const u8 {
    return switch (index) {
        0 => "Connection setup",
        1 => "Disconnect",
        2 => "Enter room",
        3 => "Leave room",
        4 => "Create room",
        5 => "Comic view",
        6 => "Text view",
        7 => "Browse rooms",
        8 => "Show or hide members",
        9 => "Favorite rooms",
        10 => "Set away message",
        11 => "Personal profile",
        12 => "Ignore member",
        13 => "Send a whisper",
        14 => "Email member",
        15 => "Open home page",
        16 => "Start meeting",
        17 => "Choose text font",
        18 => "Choose text color",
        19 => "Bold",
        20 => "Italic",
        21 => "Underline",
        22 => "Fixed-width text",
        23 => "Insert symbol",
        else => "Comic Chat tool",
    };
}

fn toolbarSemanticId(index: usize) []const u8 {
    const ids = [_][]const u8{ "toolbar-connect", "toolbar-enter-room", "toolbar-create-room", "toolbar-comic", "toolbar-text", "toolbar-rooms", "toolbar-members", "toolbar-away", "toolbar-profile", "toolbar-whisper", "toolbar-font", "toolbar-color" };
    return ids[index];
}

fn sayActionSemanticId(index: u8) []const u8 {
    const ids = [_][]const u8{ "say-action-say", "say-action-think", "say-action-whisper", "say-action-action", "say-action-sound" };
    return ids[index];
}

fn toolbarButtonX(rect: Rect, index: u8) ?i32 {
    const toolbar_layout = ui.ToolbarLayout.init(rect);
    for (ui.ToolbarLayout.command_ids, 0..) |id, position| if (id == index) return (toolbar_layout.buttonRect(position) orelse return null).x;
    return null;
}

fn drawToolbarTooltip(c: *Canvas, layout: geometry.Layout, index: u8) void {
    const button_x = toolbarButtonX(layout.toolbar, index) orelse return;
    const label = toolbarLabel(index);
    const hint = toolbarHint(index);
    const width = @min(230, Canvas.uiTextWidth(label) + Canvas.uiTextWidth(hint) + 38);
    const x = std.math.clamp(button_x - 4, 6, @max(6, layout.toolbar.right() - width - 6));
    ui.drawTooltipWithHint(c, .{ .x = x, .y = layout.tabs.bottom() + 7, .w = width, .h = 28 }, label, hint);
}

fn toolbarHint(index: u8) []const u8 {
    return switch (index) {
        0 => "File",
        2 => "Network",
        4, 7 => "Layout",
        5, 13 => "Member",
        6 => "Refresh",
        8 => "Message",
        10, 17 => "Text",
        11 => "Profile",
        18 => "Color",
        else => "Tool",
    };
}

fn drawModernToolButton(c: *Canvas, glyph: ToolGlyph, x: i32, y: i32, selected: bool, hovered: bool) i32 {
    const glyph_color = ui.drawCommandTile(c, x, y, selected, hovered);
    ui.drawToolGlyph(c, glyph, x + 8, y + 8, glyph_color);
    return x + 32;
}

fn drawToolbarSeparator(c: *Canvas, x: i32, rect: Rect) i32 {
    return ui.drawToolbarSeparator(c, x, rect);
}

const TabViewport = struct {
    first_x: i32,
    right: i32,
    capacity: usize,
};

fn tabViewport(layout: geometry.Layout, comic_mode: bool) TabViewport {
    const first_x = layout.tabs.x + 114;
    const right = if (comic_mode and layout.transcript.w >= 430)
        geometry.comicColumnControl(layout).x - 8
    else
        layout.tabs.right() - 8;
    const available = @max(0, right - first_x);
    return .{
        .first_x = first_x,
        .right = right,
        .capacity = @intCast(@max(1, @divTrunc(available, 164))),
    };
}

fn roomTabIndexAt(self: *const View, layout: geometry.Layout, comic_mode: bool, x: i32) ?usize {
    const first_x = layout.tabs.x + 114;
    const tab_width: i32 = 164;
    const viewport = tabViewport(layout, comic_mode);
    if (x >= viewport.right) return null;
    const raw = @divTrunc(x - first_x, tab_width);
    if (raw < 0) return null;
    const index = self.room_tab_first + @as(usize, @intCast(raw));
    if (index >= self.room_tab_count) return null;
    return index;
}

fn updateTabViewport(self: *View, layout: geometry.Layout, comic_mode: bool, count: usize, active: usize) void {
    const capacity = tabViewport(layout, comic_mode).capacity;
    if (count <= capacity) {
        self.room_tab_first = 0;
        return;
    }
    const bounded_active = @min(active, count - 1);
    if (bounded_active < self.room_tab_first) self.room_tab_first = bounded_active;
    if (bounded_active >= self.room_tab_first + capacity) self.room_tab_first = bounded_active - capacity + 1;
    self.room_tab_first = @min(self.room_tab_first, count - capacity);
}

fn drawTabBar(c: *Canvas, layout: geometry.Layout, tabs: []const View.Tab, active: usize, first_visible: usize, focused: bool, comic_mode: bool, comic_columns: u8, column_hover: ?ColumnControlHover, status_selected: bool, status_hovered: bool, hovered_room: ?usize) void {
    const rect = layout.tabs;
    ui.drawTabStrip(c, rect);
    const status_w: i32 = 108;
    ui.drawStatusTab(c, rect, status_selected, status_hovered);
    ui.drawStatusTabContent(c, rect, status_selected);
    const viewport = tabViewport(layout, comic_mode);
    const first_x = rect.x + status_w + 6;
    const tab_w: i32 = 164;
    for (tabs[first_visible..], first_visible..) |tab, index| {
        const slot: i32 = @intCast(index - first_visible);
        const x = first_x + slot * tab_w;
        if (x + tab_w > viewport.right) break;
        const width = tab_w;
        ui.drawConversationTab(c, .{ .x = x, .y = rect.y + 5, .w = width, .h = rect.h - 5 }, tab.label, tab.unread, index == active, focused and index == active, hovered_room == index);
    }
    if (comic_mode and layout.transcript.w >= 430) drawComicColumnControl(c, layout, comic_columns, column_hover);
}

fn drawComicColumnControl(c: *Canvas, layout: geometry.Layout, columns: u8, hovered: ?ColumnControlHover) void {
    const control = geometry.comicColumnControl(layout);
    var label_buf: [16]u8 = undefined;
    const label = std.fmt.bufPrint(&label_buf, "{d} across", .{columns}) catch "4 across";
    ui.drawLabeledStepper(c, control, label, hovered == .decrease, hovered == .increase);
}

fn sayActionLabel(index: u8) []const u8 {
    return switch (index) {
        0 => "Say",
        1 => "Think",
        2 => "Whisper",
        3 => "Action",
        4 => "Sound",
        else => "Action",
    };
}

fn drawSplitters(c: *Canvas, layout: geometry.Layout, comic_mode: bool) void {
    if (layout.right.w > 0)
        ui.drawSplitter(c, .{ .x = layout.transcript.right(), .y = layout.buffer.y, .w = geometry.splitter, .h = layout.buffer.h });
    ui.drawSplitter(c, .{ .x = layout.transcript.x, .y = layout.transcript.bottom(), .w = layout.transcript.w, .h = geometry.splitter });
    if (comic_mode) ui.drawSplitter(c, .{ .x = layout.right.x, .y = layout.members.bottom(), .w = layout.right.w, .h = geometry.splitter });
}

const TextWindow = struct {
    start: usize,
    end: usize,
    left_hidden: bool,
    right_hidden: bool,
};

const ComposerRow = struct {
    window: TextWindow,
    cursor_row: bool,
};

const ComposerViewport = struct {
    rows: [2]ComposerRow = undefined,
    count: usize = 0,
};

fn composerViewport(text: []const u8, cursor: usize, max_width: i32) ComposerViewport {
    var viewport: ComposerViewport = .{};
    const safe_cursor = @min(cursor, text.len);
    const current_start = if (std.mem.lastIndexOfScalar(u8, text[0..safe_cursor], '\n')) |newline| newline + 1 else 0;
    const current_end = if (std.mem.indexOfScalar(u8, text[safe_cursor..], '\n')) |relative| safe_cursor + relative else text.len;
    const current_local = visibleTextWindow(text[current_start..current_end], safe_cursor - current_start, max_width);
    const current = ComposerRow{
        .window = .{
            .start = current_start + current_local.start,
            .end = current_start + current_local.end,
            .left_hidden = current_local.left_hidden,
            .right_hidden = current_local.right_hidden,
        },
        .cursor_row = true,
    };

    if (current_start > 0) {
        const previous_end = current_start - 1;
        const previous_start = if (std.mem.lastIndexOfScalar(u8, text[0..previous_end], '\n')) |newline| newline + 1 else 0;
        const previous_local = visibleTextWindow(text[previous_start..previous_end], 0, max_width);
        viewport.rows[0] = .{
            .window = .{
                .start = previous_start + previous_local.start,
                .end = previous_start + previous_local.end,
                .left_hidden = previous_local.left_hidden or previous_start > 0,
                .right_hidden = previous_local.right_hidden,
            },
            .cursor_row = false,
        };
        viewport.rows[1] = current;
        viewport.count = 2;
    } else {
        viewport.rows[0] = current;
        viewport.count = 1;
        if (current_end < text.len) {
            const next_start = current_end + 1;
            const next_end = if (std.mem.indexOfScalar(u8, text[next_start..], '\n')) |relative| next_start + relative else text.len;
            const next_local = visibleTextWindow(text[next_start..next_end], 0, max_width);
            viewport.rows[1] = .{
                .window = .{
                    .start = next_start + next_local.start,
                    .end = next_start + next_local.end,
                    .left_hidden = next_local.left_hidden,
                    .right_hidden = next_local.right_hidden or next_end < text.len,
                },
                .cursor_row = false,
            };
            viewport.count = 2;
        }
    }
    if (viewport.count > 1) {
        viewport.rows[0].window.right_hidden = viewport.rows[0].window.right_hidden or viewport.rows[0].window.end < text.len;
        viewport.rows[1].window.left_hidden = viewport.rows[1].window.left_hidden or viewport.rows[1].window.start > 0;
    }
    return viewport;
}

const focused_placeholder_gap: i32 = 8;

fn placeholderGap(focused: bool) i32 {
    return if (focused) focused_placeholder_gap else 0;
}

fn previousUtf8Boundary(text: []const u8, index: usize) usize {
    if (index == 0) return 0;
    var result = @min(index, text.len) - 1;
    while (result > 0 and text[result] & 0xc0 == 0x80) result -= 1;
    return result;
}

fn nextUtf8Boundary(text: []const u8, index: usize) usize {
    if (index >= text.len) return text.len;
    var result = index + 1;
    while (result < text.len and text[result] & 0xc0 == 0x80) result += 1;
    return result;
}

/// Keep the caret visible in a single-line field while retaining as much
/// surrounding context as the control can show.
fn visibleTextWindow(text: []const u8, cursor: usize, max_width: i32) TextWindow {
    if (Canvas.uiTextWidth(text) <= max_width) return .{ .start = 0, .end = text.len, .left_hidden = false, .right_hidden = false };
    const safe_cursor = @min(cursor, text.len);
    const reserved = @max(8, max_width - 12);
    var start = safe_cursor;
    while (start > 0) {
        const previous = previousUtf8Boundary(text, start);
        if (Canvas.uiTextWidth(text[previous..safe_cursor]) > reserved) break;
        start = previous;
    }
    var end = safe_cursor;
    while (end < text.len) {
        const next = nextUtf8Boundary(text, end);
        if (Canvas.uiTextWidth(text[start..next]) > reserved) break;
        end = next;
    }
    while (end < text.len and start < safe_cursor) {
        const next = nextUtf8Boundary(text, end);
        const previous = nextUtf8Boundary(text, start);
        if (Canvas.uiTextWidth(text[previous..next]) > reserved) break;
        start = previous;
        end = next;
    }
    return .{ .start = start, .end = end, .left_hidden = start > 0, .right_hidden = end < text.len };
}

fn placeEditorCursor(editor: *input_mod.Editor, window: TextWindow, local_x: i32) void {
    const text = editor.text();
    if (local_x <= 0) {
        editor.cursor = window.start;
        editor.selection_anchor = null;
        return;
    }
    var index = window.start;
    while (index < window.end) {
        const next = nextUtf8Boundary(text, index);
        const left = Canvas.uiTextWidth(text[window.start..index]);
        const right = Canvas.uiTextWidth(text[window.start..next]);
        if (local_x < left + @divTrunc(right - left, 2)) break;
        index = next;
    }
    editor.cursor = index;
    editor.selection_anchor = null;
}

fn drawSayWindow(c: *Canvas, layout: geometry.Layout, input: []const u8, cursor: usize, selection: ?TextSelection, focused: bool, hovered: bool, say_mode: shell_mod.SayMode, hovered_action: ?u8, focused_action: ?u8) void {
    const edit = layout.say_editor;
    ui.drawComposerSurface(c, layout.say);
    const editor_layout = ui.ComposerEditorLayout.init(edit);
    ui.drawComposerEditor(c, editor_layout, focused, hovered, input.len > 0);
    const content_rect = editor_layout.content;
    if (input.len == 0) {
        const placeholder_x = edit.x + 18 + placeholderGap(focused);
        const enter_w: i32 = if (edit.w >= 240) Canvas.uiTextWidth("Enter") + 20 else 0;
        drawTextEllipsized(c, "Ink the next balloon...", placeholder_x, edit.y + 13, edit.right() - placeholder_x - 18 - enter_w, ui.current.secondary);
        if (enter_w > 0) {
            ui.drawInkPlate(c, edit.right() - enter_w - 10, edit.y + 13, enter_w, 18, 2, if (focused) ui.current.accent else ui.current.layer);
            drawTextEllipsized(c, "Enter", edit.right() - enter_w - 2, edit.y + 14, enter_w - 16, if (focused) ui.current.layer else ui.current.ink);
        }
    } else {
        const viewport = composerViewport(input, cursor, content_rect.w);
        for (viewport.rows[0..viewport.count], 0..) |row, row_index| {
            const window = row.window;
            const text_y = editor_layout.rowY(row_index, viewport.count);
            if (selection) |range| {
                const start = @max(window.start, @min(range.start, window.end));
                const end = @max(start, @min(range.end, window.end));
                if (end > start) {
                    const selection_x = content_rect.x + Canvas.uiTextWidth(input[window.start..start]);
                    const selection_w = Canvas.uiTextWidth(input[start..end]);
                    ui.drawTextSelection(c, editor_layout.selectionRect(selection_x, text_y, selection_w));
                }
            }
            drawTextEllipsized(c, input[window.start..window.end], content_rect.x, text_y, content_rect.w, ui.current.ink);
            if (row.cursor_row and focused) {
                const safe_cursor = std.math.clamp(@min(cursor, input.len), window.start, window.end);
                const caret_x = editor_layout.caretX(content_rect.x + Canvas.uiTextWidth(input[window.start..safe_cursor]));
                ui.drawTextCaret(c, caret_x, text_y + 1, 16);
            }
        }
        const cursor_row = if (viewport.count > 1 and viewport.rows[1].cursor_row) viewport.rows[1].window else viewport.rows[0].window;
        ui.drawComposerOverflowMarks(c, editor_layout, cursor_row.left_hidden, cursor_row.right_hidden);
    }

    const glyphs = [_]ui.SayGlyph{ .say, .think, .whisper, .action, .sound };
    var x = layout.say_actions.x;
    for (glyphs, 0..) |glyph, index| {
        const selected = @intFromEnum(say_mode) == index;
        const glyph_color = ui.drawActionTile(c, x, layout.say_actions.y, layout.say_action_size, layout.say_actions.h, selected, hovered_action == @as(u8, @intCast(index)));
        ui.drawSayGlyph(c, glyph, x + @divTrunc(layout.say_action_size - 16, 2), layout.say_actions.y + 18, glyph_color);
        if (focused_action == @as(u8, @intCast(index))) ui.drawFocusRing(c, .{ .x = x, .y = layout.say_actions.y, .w = layout.say_action_size, .h = layout.say_actions.h });
        x += layout.say_action_size;
    }
}

fn drawSayActionTooltip(c: *Canvas, layout: geometry.Layout, index: u8) void {
    if (index >= geometry.say_button_count) return;
    const label = sayActionLabel(index);
    const width = Canvas.uiTextWidth(label) + 20;
    const action_x = layout.say_actions.x + @as(i32, index) * layout.say_action_size;
    const x = std.math.clamp(action_x + @divTrunc(layout.say_action_size - width, 2), 6, @max(6, layout.transcript.right() - width - 6));
    ui.drawTooltip(c, .{ .x = x, .y = layout.say.y - 34, .w = width, .h = 28 }, label);
}

fn drawStatusBar(c: *Canvas, rect: Rect, status: []const u8, member_count: usize, hovered: bool) void {
    ui.drawStatusBar(c, rect.x, rect.y, rect.w, rect.h, status, member_count, hovered);
}

fn statusPanelRect(width: u32, height: u32, detailed: bool) Rect {
    return ui.StatusPanelLayout.init(width, height, detailed).rect;
}

fn drawStatusPanel(c: *Canvas, status: []const u8, member_count: usize, shell: shell_mod.State, appearance: ui.Appearance, detailed: bool, hovered_action: ?StatusActionHover) void {
    const panel_layout = ui.StatusPanelLayout.init(c.width, c.height, detailed);
    const panel = panel_layout.rect;
    const show_details = panel_layout.show_details;
    ui.drawAnchoredPopoverSurface(c, panel, panel.x + 30);
    const tone = ui.statusTone(status);
    ui.drawStatusIdentity(c, .{ .x = panel.x + 16, .y = panel.y + 15, .w = 34, .h = 34 }, tone);
    ui.drawContentHeading(c, .{ .x = panel.x + 62, .y = panel.y + 14, .w = panel.w - 82, .h = 36 }, "On the wire", status);
    ui.drawSectionRule(c, panel.x + 16, panel.y + 60, panel.w - 32);

    var members_buf: [32]u8 = undefined;
    const members = std.fmt.bufPrint(&members_buf, "{d} active member{s}", .{ member_count, if (member_count == 1) "" else "s" }) catch "Member activity";
    var panels_buf: [32]u8 = undefined;
    const panels = std.fmt.bufPrint(&panels_buf, "{d} panels across", .{shell.comic_columns}) catch "Panel layout";
    const metric_gap: i32 = 8;
    const metric_w = @divTrunc(panel.w - 36 - metric_gap, 2);
    const first_metric_y = panel.y + 69;
    if (panel_layout.show_metrics) {
        ui.drawStatusMetricCard(c, .{ .x = panel.x + 18, .y = first_metric_y, .w = metric_w, .h = 38 }, "CAST", members);
        ui.drawStatusMetricCard(c, .{ .x = panel.x + 18 + metric_w + metric_gap, .y = first_metric_y, .w = metric_w, .h = 38 }, "PAGE", if (shell.content_mode == .comic) panels else "Text transcript");
    }
    if (show_details) {
        const detail_y = first_metric_y + 40;
        ui.drawStatusMetricCard(c, .{ .x = panel.x + 18, .y = detail_y, .w = metric_w, .h = 38 }, "MEMBERS", if (!shell.show_members) "Pane hidden" else if (shell.member_view == .icons) "Portrait cards" else "Compact list");
        const theme_label = switch (appearance.accent) {
            .cobalt => "Vermillion",
            .violet => "Violet",
            .forest => "Forest",
        };
        var studio_buf: [32]u8 = undefined;
        const studio = if (appearance.mode == .dark)
            std.fmt.bufPrint(&studio_buf, "Dark · {s}", .{theme_label}) catch "Dark studio"
        else
            theme_label;
        ui.drawStatusMetricCard(c, .{ .x = panel.x + 18 + metric_w + metric_gap, .y = detail_y, .w = metric_w, .h = 38 }, "INK", studio);
    }
    if (panel_layout.show_actions) {
        const connection = panel_layout.connection;
        const settings = panel_layout.settings;
        ui.drawButton(c, connection.x, connection.y, connection.w, "Connection setup", .primary, hovered_action == .connection);
        ui.drawButton(c, settings.x, settings.y, settings.w, "Settings", .secondary, hovered_action == .settings);
        ui.drawDismissHint(c, panel, "Esc closes");
    }
}

fn drawEmptyBuffer(c: *Canvas, rect: Rect, text: []const u8, columns: u8) void {
    ui.drawEmptyState(c, rect.x, rect.y, rect.w, rect.h, text, columns);
}

fn drawFocus(c: *Canvas, rect: Rect) void {
    ui.drawFocusRing(c, rect);
}

fn drawTextEllipsized(c: *Canvas, text: []const u8, x: i32, y: i32, max_w: i32, color: u32) void {
    ui.drawEllipsized(c, text, x, y, max_w, color);
}

fn blitFit(c: *Canvas, src: []const u32, sw: u32, sh: u32, x: i32, y: i32, max_w: i32, max_h: i32) void {
    blitSourcePage(c, src, sw, sh, x, y, max_w, max_h);
}

/// Fit a source-rasterized page into the well without shifting it off the
/// top-left origin. The 14px vertical bias used to invent extra mat.
fn blitSourcePage(c: *Canvas, src: []const u32, sw: u32, sh: u32, x: i32, y: i32, max_w: i32, max_h: i32) void {
    const fit = fitRect(sw, sh, x, y, max_w, max_h) orelse return;
    const stride = strip.panel_height + strip.device_interstice;
    const rows: u32 = if (sh == 0 or stride == 0) 0 else (sh + strip.device_interstice) / stride;
    const max_rows: u32 = 3;
    const show_rows = if (rows == 0) 0 else @min(rows, max_rows);
    const first_row = rows - show_rows;
    const src_y = first_row * stride;
    const src_h = if (sh > src_y) sh - src_y else sh;
    if (src_h == 0) return;
    const crop = fitRect(sw, src_h, x, y, max_w, max_h) orelse fit;
    var oy: i32 = 0;
    while (oy < crop.h) : (oy += 1) {
        const sy: u32 = src_y + @as(u32, @intCast(@divTrunc(@as(i64, oy) * src_h, crop.h)));
        var ox: i32 = 0;
        while (ox < crop.w) : (ox += 1) {
            const sx: u32 = @intCast(@divTrunc(@as(i64, ox) * sw, crop.w));
            c.set(crop.x + ox, crop.y + oy, src[@as(usize, sy) * sw + sx]);
        }
    }
}

fn blitHeightBottomAlphaSmooth(c: *Canvas, src: []const u32, sw: u32, sh: u32, x: i32, y: i32, area_w: i32, area_h: i32) void {
    if (sw == 0 or sh == 0 or area_w <= 0 or area_h <= 0) return;
    var draw_h = area_h;
    var draw_w: i32 = @max(1, @as(i32, @intCast(@divTrunc(@as(i64, sw) * draw_h, sh))));
    if (draw_w > area_w) {
        draw_w = area_w;
        draw_h = @max(1, @as(i32, @intCast(@divTrunc(@as(i64, sh) * draw_w, sw))));
    }
    const draw_x = x + @divTrunc(area_w - draw_w, 2);
    const draw_y = y + area_h - draw_h;
    var oy: i32 = 0;
    while (oy < draw_h) : (oy += 1) {
        const sy_fp: u64 = if (draw_h <= 1 or sh <= 1) 0 else @intCast(@divTrunc(@as(i64, oy) * (@as(i64, sh) - 1) * 65536, draw_h - 1));
        var ox: i32 = 0;
        while (ox < draw_w) : (ox += 1) {
            const sx_fp: u64 = if (draw_w <= 1 or sw <= 1) 0 else @intCast(@divTrunc(@as(i64, ox) * (@as(i64, sw) - 1) * 65536, draw_w - 1));
            const sample = bilinearAlphaSample(src, sw, sh, sx_fp, sy_fp);
            if (sample.alpha != 0) c.blendPixel(draw_x + ox, draw_y + oy, sample.rgb, sample.alpha);
        }
    }
}

const AlphaSample = struct { rgb: u32, alpha: u32 };

fn bilinearAlphaSample(src: []const u32, sw: u32, sh: u32, sx_fp: u64, sy_fp: u64) AlphaSample {
    const x0: u32 = @intCast(@min(@as(u64, sw - 1), sx_fp >> 16));
    const y0: u32 = @intCast(@min(@as(u64, sh - 1), sy_fp >> 16));
    const x1 = @min(sw - 1, x0 + 1);
    const y1 = @min(sh - 1, y0 + 1);
    const fx = sx_fp & 0xffff;
    const fy = sy_fp & 0xffff;
    const one: u64 = 65536;
    const weights = [_]u64{ (one - fx) * (one - fy), fx * (one - fy), (one - fx) * fy, fx * fy };
    const pixels = [_]u32{
        src[@as(usize, y0) * @as(usize, sw) + @as(usize, x0)],
        src[@as(usize, y0) * @as(usize, sw) + @as(usize, x1)],
        src[@as(usize, y1) * @as(usize, sw) + @as(usize, x0)],
        src[@as(usize, y1) * @as(usize, sw) + @as(usize, x1)],
    };
    var weighted_alpha: u64 = 0;
    var red: u64 = 0;
    var green: u64 = 0;
    var blue: u64 = 0;
    for (pixels, weights) |pixel, weight| {
        const alpha = @as(u64, pixel >> 24);
        const alpha_weight = alpha * weight;
        weighted_alpha += alpha_weight;
        red += @as(u64, (pixel >> 16) & 0xff) * alpha_weight;
        green += @as(u64, (pixel >> 8) & 0xff) * alpha_weight;
        blue += @as(u64, pixel & 0xff) * alpha_weight;
    }
    if (weighted_alpha == 0) return .{ .rgb = 0, .alpha = 0 };
    const alpha: u32 = @intCast(@min(@as(u64, 255), weighted_alpha >> 32));
    const rgb = (@as(u32, @intCast(red / weighted_alpha)) << 16) |
        (@as(u32, @intCast(green / weighted_alpha)) << 8) |
        @as(u32, @intCast(blue / weighted_alpha));
    return .{ .rgb = rgb, .alpha = alpha };
}

fn emotionWheelRect(layout: geometry.Layout) Rect {
    return emotionWheelRectFromPane(layout.body_camera);
}

fn emotionWheelRectFromPane(pane: Rect) Rect {
    const wheel_side = if (pane.w >= 93) @min(pane.w, 159) else 0;
    return .{ .x = pane.x, .y = pane.bottom() - wheel_side, .w = pane.w, .h = wheel_side };
}

fn emotionGridCoordinate(value: i16) i32 {
    if (value < -5) return 0;
    if (value > 5) return 2;
    return 1;
}

fn emotionLabel(x: i16, y: i16) []const u8 {
    const col = emotionGridCoordinate(x);
    const row = emotionGridCoordinate(y);
    return switch (row * 3 + col) {
        0 => "Angry",
        1 => "Loud",
        2 => "Laughing",
        3 => "Sad",
        4 => "Neutral",
        5 => "Happy",
        6 => "Uneasy",
        7 => "Bored",
        else => "Coy",
    };
}

fn bmpU16(bytes: []const u8, offset: usize) u16 {
    return @as(u16, bytes[offset]) | @as(u16, bytes[offset + 1]) << 8;
}

fn bmpU32(bytes: []const u8, offset: usize) u32 {
    return @as(u32, bytes[offset]) |
        @as(u32, bytes[offset + 1]) << 8 |
        @as(u32, bytes[offset + 2]) << 16 |
        @as(u32, bytes[offset + 3]) << 24;
}

fn drawBmp8(c: *Canvas, bytes: []const u8, dx: i32, dy: i32) void {
    if (bytes.len < 54 or bmpU16(bytes, 0) != 0x4d42 or bmpU16(bytes, 28) != 8) return;
    drawBmpRegion(c, bytes, 0, 0, bmpU32(bytes, 18), bmpU32(bytes, 22), dx, dy, false);
}

fn drawBmpRegion(c: *Canvas, bytes: []const u8, source_x: usize, source_y: usize, region_w: usize, region_h: usize, dx: i32, dy: i32, transparent_corner: bool) void {
    if (bytes.len < 54 or bmpU16(bytes, 0) != 0x4d42) return;
    const bits: usize = bmpU32(bytes, 10);
    const width: usize = bmpU32(bytes, 18);
    const height: usize = bmpU32(bytes, 22);
    const depth: usize = bmpU16(bytes, 28);
    if (depth != 4 and depth != 8) return;
    const palette: usize = 14 + bmpU32(bytes, 14);
    const stride = ((width * depth + 31) / 32) * 4;
    const palette_len: usize = (@as(usize, 1) << @intCast(depth)) * 4;
    if (width == 0 or height == 0 or source_x + region_w > width or source_y + region_h > height or
        bits + stride * height > bytes.len or palette + palette_len > bytes.len) return;
    const corner_row = bits + (height - 1 - source_y) * stride;
    const corner_index: u8 = if (depth == 8)
        bytes[corner_row + source_x]
    else if (source_x % 2 == 0)
        bytes[corner_row + source_x / 2] >> 4
    else
        bytes[corner_row + source_x / 2] & 0x0f;
    var y: usize = 0;
    while (y < region_h) : (y += 1) {
        const source_row = bits + (height - 1 - (source_y + y)) * stride;
        var x: usize = 0;
        while (x < region_w) : (x += 1) {
            const pixel_x = source_x + x;
            const color_index: u8 = if (depth == 8)
                bytes[source_row + pixel_x]
            else if (pixel_x % 2 == 0)
                bytes[source_row + pixel_x / 2] >> 4
            else
                bytes[source_row + pixel_x / 2] & 0x0f;
            if (transparent_corner and color_index == corner_index) continue;
            const entry = palette + @as(usize, color_index) * 4;
            const color = 0xff000000 | @as(u32, bytes[entry + 2]) << 16 |
                @as(u32, bytes[entry + 1]) << 8 | bytes[entry];
            c.set(dx + @as(i32, @intCast(x)), dy + @as(i32, @intCast(y)), color);
        }
    }
}

fn fitRect(sw: u32, sh: u32, x: i32, y: i32, max_w: i32, max_h: i32) ?Rect {
    if (sw == 0 or sh == 0 or max_w <= 0 or max_h <= 0) return null;
    var dw = max_w;
    var dh: i32 = @intCast(@divTrunc(@as(i64, sh) * dw, sw));
    if (dh > max_h) {
        dh = max_h;
        dw = @intCast(@divTrunc(@as(i64, sw) * dh, sh));
    }
    dw = @max(dw, 1);
    dh = @max(dh, 1);
    return .{
        .x = x + @divTrunc(max_w - dw, 2),
        .y = y + @divTrunc(max_h - dh, 2),
        .w = dw,
        .h = dh,
    };
}

fn dialogLayout(width: u32, height: u32, spec: dialogs.Spec) ui.DialogLayout {
    return ui.DialogLayout.init(width, height, spec.source_w, spec.source_h, dialogs.fields(spec.id).len, dialogPrimaryButtonWidth(spec.id), dialogs.showsCancel(spec.id));
}

fn settingsKicker(id: dialogs.Id, index: usize) []const u8 {
    if (id != .settings) return "";
    return switch (index) {
        0 => "STUDIO",
        3 => "PAGE",
        5 => "CAST",
        else => "",
    };
}

fn dialogFieldFocusable(field: dialogs.Field) bool {
    return field.kind != .readonly and field.kind != .preview;
}

fn drawDialog(c: *Canvas, spec: dialogs.Spec, editors: *const [8]input_mod.Editor, active_field: usize, first_field: usize, action_focus: ?ui.DialogButton, hovered_field: ?usize, hovered_browse: ?usize, notice: []const u8, hovered_button: ?ui.DialogButton) void {
    ui.drawModalBackdrop(c);
    const dialog_layout = dialogLayout(c.width, c.height, spec);
    const rect = dialog_layout.rect;
    const group_text = switch (spec.id) {
        .settings => "Ink, Sunday page density, and the CAST",
        .character => "Choose who stands on the page",
        .background => "The paper behind every panel",
        .setup, .servers => "Server and transport security",
        .password => "Secure account sign-in",
        .sound => "Choose a sound and message",
        .comics_view => "How the page is arranged",
        .about => "Portable Ink Sunday client",
        else => switch (spec.group) {
            .application => "Application preferences",
            .connection => "Connection, identity, and appearance",
            .rooms => "Rooms and member workflow",
            .automation => "Automation and notifications",
            .files => "Application and file workflow",
        },
    };
    ui.drawDialogSurface(c, rect, spec.title, group_text);
    const fields = dialogs.fields(spec.id);
    for (fields, 0..) |field, index| {
        if (index < first_field) continue;
        const row_y = dialog_layout.fieldLabelYScrolled(index, first_field);
        if (row_y + 40 > rect.bottom() - 43) break;
        const kicker = settingsKicker(spec.id, index);
        const kicker_w: i32 = if (kicker.len == 0) 0 else Canvas.uiTextWidth(kicker) + 18;
        ui.drawDialogFieldLabel(c, .{ .x = rect.x + 20, .y = row_y, .w = rect.w - 40 - kicker_w, .h = 17 }, field.label, index == active_field);
        if (kicker_w > 0) ui.drawInkChip(c, .{ .x = rect.right() - kicker_w - 22, .y = row_y - 1, .w = kicker_w, .h = 18 }, kicker, true);
        var field_rect = dialog_layout.fieldRectScrolled(index, first_field);
        if (spec.id == .character and field.kind == .preview) field_rect = characterGalleryRect(dialog_layout, first_field);
        const field_y = field_rect.y;
        const field_active = action_focus == null and index == active_field;
        const field_hovered = hovered_field == index;
        const value = if (index < editors.len) editors[index].text() else "";
        const state: ui.InputState = .{
            .focused = field_active,
            .hovered = field_hovered,
            .populated = value.len != 0,
            .invalid = notice.len != 0 and field_active and dialogs.fieldAcceptsText(spec.id, index),
        };
        switch (field.kind) {
            .text => ui.drawInputControl(c, field_rect, .text, state),
            .password => ui.drawInputControl(c, field_rect, .password, state),
            .choice => ui.drawInputControl(c, field_rect, .choice, state),
            .list => ui.drawInputControl(c, field_rect, .list, state),
            .preview => {
                ui.drawInputControl(c, field_rect, .preview, state);
                drawDialogPreview(c, spec.id, editors, field_rect);
            },
            .readonly => ui.drawInputControl(c, field_rect, .readonly, state),
        }
        if (dialogBrowseField(spec.id) == index) {
            const browse = dialogBrowseRect(field_rect);
            ui.drawBrowseButton(c, browse, hovered_browse == index);
        }
        if (index < editors.len) {
            const editor = &editors[index];
            const browse_width: i32 = if (dialogBrowseField(spec.id) == index) 78 else 0;
            const text_width = field_rect.w - browse_width - if (field.kind == .password or field.kind == .choice) @as(i32, 46) else if (field.kind == .list or field.kind == .readonly) @as(i32, 40) else @as(i32, 20);
            const window = visibleTextWindow(value, editor.cursor, text_width);
            const visible = value[window.start..window.end];
            const value_x = field_rect.x + if (field.kind == .list or field.kind == .readonly) @as(i32, 32) else @as(i32, 11);
            if (field_active and dialogs.fieldAcceptsText(spec.id, index)) if (editor.selection()) |range| {
                const start = @max(window.start, @min(range.start, window.end));
                const end = @max(start, @min(range.end, window.end));
                if (end > start) {
                    const selection_x = value_x + Canvas.uiTextWidth(value[window.start..start]);
                    ui.drawTextSelection(c, .{ .x = selection_x, .y = field_y + 5, .w = Canvas.uiTextWidth(value[start..end]), .h = 20 });
                }
            };
            if (value.len != 0 and field.kind == .password) {
                var mask: [64]u8 = undefined;
                const mask_len = @min(visible.len, mask.len);
                @memset(mask[0..mask_len], '*');
                drawTextEllipsized(c, mask[0..mask_len], value_x, field_y + 4, text_width, ui.current.ink);
            } else if (value.len != 0) {
                drawTextEllipsized(c, visible, value_x, field_y + 4, text_width, ui.current.ink);
                ui.drawInputOverflowMarks(c, field_rect, window.left_hidden, window.right_hidden);
            }
            if (field_active and dialogs.fieldAcceptsText(spec.id, index)) {
                const safe_cursor = @min(editor.cursor, value.len);
                const visible_cursor = std.math.clamp(safe_cursor, window.start, window.end);
                const caret_x = @min(field_rect.right() - 40, value_x + Canvas.uiTextWidth(value[window.start..visible_cursor]));
                ui.drawTextCaret(c, caret_x, field_y + 6, 18);
            }
        }
        const custom_preview = field.kind == .preview and (spec.id == .character or spec.id == .background);
        if (editors[index].text().len == 0 and !custom_preview) {
            const base_hint_x = field_rect.x + if (field.kind == .list or field.kind == .readonly) @as(i32, 28) else if (field.kind == .preview) @as(i32, 72) else @as(i32, 10);
            const hint_x = base_hint_x + placeholderGap(field_active and dialogs.fieldAcceptsText(spec.id, index));
            const hint_right = field_rect.right() - if (field.kind == .choice) @as(i32, 42) else @as(i32, 10);
            drawTextEllipsized(c, field.hint, hint_x, field_y + 4, hint_right - hint_x, ui.current.secondary);
        }
    }

    const visible_rows = dialog_layout.visibleRows();
    if (fields.len > visible_rows) ui.drawVerticalScrollbar(c, .{
        .x = rect.right() - 13,
        .y = dialog_layout.body_y,
        .w = 8,
        .h = @max(1, dialog_layout.primary.y - dialog_layout.body_y - 8),
    }, fields.len, visible_rows, first_field);

    ui.drawDialogActionBar(c, rect, dialog_layout.primary.y - 8);
    if (notice.len != 0) ui.drawNotice(c, rect.x + 14, dialog_layout.primary.y - 22, rect.w - 28, notice, .warning);
    drawDialogButton(c, dialog_layout.primary.x, dialog_layout.primary.y, dialog_layout.primary.w, dialogs.primaryLabel(spec.id), .primary, hovered_button == .primary or action_focus == .primary);
    if (dialogs.showsCancel(spec.id))
        drawDialogButton(c, dialog_layout.cancel.x, dialog_layout.cancel.y, dialog_layout.cancel.w, "Cancel", .secondary, hovered_button == .cancel or action_focus == .cancel);
}

fn dialogBrowseField(id: dialogs.Id) ?usize {
    return switch (id) {
        .open_conversation, .save_conversation, .export_image, .open_locator, .print_preview => 0,
        .file_transfer, .rule_sets => 2,
        else => null,
    };
}

fn dialogBrowseRect(field: Rect) Rect {
    return .{ .x = field.right() - 74, .y = field.y + 2, .w = 72, .h = field.h - 4 };
}

fn dialogBackgroundByName(name: []const u8) ?[]const u8 {
    if (std.ascii.eqlIgnoreCase(name, "field")) return @embedFile("../assets/testdata/field.bgb");
    if (std.ascii.eqlIgnoreCase(name, "volcano")) return @embedFile("../assets/testdata/volcano.bgb");
    if (std.ascii.eqlIgnoreCase(name, "den")) return @embedFile("../assets/testdata/den.bgb");
    if (std.ascii.eqlIgnoreCase(name, "room")) return @embedFile("../assets/testdata/room.bgb");
    if (std.ascii.eqlIgnoreCase(name, "pastoral")) return @embedFile("../assets/testdata/pastoral.bgb");
    if (std.ascii.eqlIgnoreCase(name, "hd apartment")) return @embedFile("../assets/generated/hd-apartment.bgb");
    if (std.ascii.eqlIgnoreCase(name, "hd rooftop")) return @embedFile("../assets/generated/hd-rooftop.bgb");
    if (std.ascii.eqlIgnoreCase(name, "hd cafe")) return @embedFile("../assets/generated/hd-cafe.bgb");
    if (std.ascii.eqlIgnoreCase(name, "hd park")) return @embedFile("../assets/generated/hd-park.bgb");
    if (std.ascii.eqlIgnoreCase(name, "hd space corridor")) return @embedFile("../assets/generated/hd-space-corridor.bgb");
    if (std.ascii.eqlIgnoreCase(name, "hd boardwalk")) return @embedFile("../assets/generated/hd-boardwalk.bgb");
    if (std.ascii.eqlIgnoreCase(name, "hd school hall")) return @embedFile("../assets/generated/hd-school-hall.bgb");
    if (std.ascii.eqlIgnoreCase(name, "hd rainy street")) return @embedFile("../assets/generated/hd-rainy-street.bgb");
    if (std.ascii.eqlIgnoreCase(name, "hd library")) return @embedFile("../assets/generated/hd-library.bgb");
    if (std.ascii.eqlIgnoreCase(name, "hd campsite")) return @embedFile("../assets/generated/hd-campsite.bgb");
    if (std.ascii.eqlIgnoreCase(name, "color apartment")) return @embedFile("../assets/generated/color-apartment.bgb");
    if (std.ascii.eqlIgnoreCase(name, "color rooftop")) return @embedFile("../assets/generated/color-rooftop.bgb");
    if (std.ascii.eqlIgnoreCase(name, "color cafe")) return @embedFile("../assets/generated/color-cafe.bgb");
    if (std.ascii.eqlIgnoreCase(name, "color park")) return @embedFile("../assets/generated/color-park.bgb");
    if (std.ascii.eqlIgnoreCase(name, "color space corridor")) return @embedFile("../assets/generated/color-space-corridor.bgb");
    if (std.ascii.eqlIgnoreCase(name, "color boardwalk")) return @embedFile("../assets/generated/color-boardwalk.bgb");
    if (std.ascii.eqlIgnoreCase(name, "color school hall")) return @embedFile("../assets/generated/color-school-hall.bgb");
    if (std.ascii.eqlIgnoreCase(name, "color rainy street")) return @embedFile("../assets/generated/color-rainy-street.bgb");
    if (std.ascii.eqlIgnoreCase(name, "color library")) return @embedFile("../assets/generated/color-library.bgb");
    if (std.ascii.eqlIgnoreCase(name, "color campsite")) return @embedFile("../assets/generated/color-campsite.bgb");
    if (std.ascii.eqlIgnoreCase(name, "whacky spaceship bridge")) return @embedFile("../assets/generated/whacky-spaceship-bridge.bgb");
    if (std.ascii.eqlIgnoreCase(name, "whacky asteroid diner")) return @embedFile("../assets/generated/whacky-asteroid-diner.bgb");
    if (std.ascii.eqlIgnoreCase(name, "whacky sky island market")) return @embedFile("../assets/generated/whacky-sky-island-market.bgb");
    if (std.ascii.eqlIgnoreCase(name, "whacky underwater dome")) return @embedFile("../assets/generated/whacky-underwater-dome.bgb");
    if (std.ascii.eqlIgnoreCase(name, "whacky friendly castle")) return @embedFile("../assets/generated/whacky-friendly-castle.bgb");
    if (std.ascii.eqlIgnoreCase(name, "whacky pinball interior")) return @embedFile("../assets/generated/whacky-pinball-interior.bgb");
    if (std.ascii.eqlIgnoreCase(name, "whacky cosmic laundromat")) return @embedFile("../assets/generated/whacky-cosmic-laundromat.bgb");
    if (std.ascii.eqlIgnoreCase(name, "whacky cloud train station")) return @embedFile("../assets/generated/whacky-cloud-train-station.bgb");
    if (std.ascii.eqlIgnoreCase(name, "whacky mushroom village")) return @embedFile("../assets/generated/whacky-mushroom-village.bgb");
    if (std.ascii.eqlIgnoreCase(name, "whacky arcade planetarium")) return @embedFile("../assets/generated/whacky-arcade-planetarium.bgb");
    return null;
}

fn drawDialogPreview(c: *Canvas, id: dialogs.Id, editors: *const [8]input_mod.Editor, rect: Rect) void {
    const selected = editors[0].text();
    switch (id) {
        .character => {
            const options = dialogs.choiceOptions(.character, 0);
            var selected_index: usize = 0;
            for (options, 0..) |option, index| if (std.ascii.eqlIgnoreCase(option, selected)) {
                selected_index = index;
                break;
            };
            const family_len = if (options.len % 3 == 0) options.len / 3 else options.len;
            const family_start = @divTrunc(selected_index, family_len) * family_len;
            const family_index = selected_index - family_start;
            const family_rect = characterFamilyRect(rect);
            if (family_rect.h > 0) ui.drawSegmentedChoice(c, family_rect, &.{ "HD", "Color", "Original" }, @divTrunc(selected_index, family_len));
            const indices = [_]usize{
                family_start + (family_index + family_len - 1) % family_len,
                selected_index,
                family_start + (family_index + 1) % family_len,
            };
            const cards_rect = characterGalleryCardsRect(rect);
            const card_w = @divTrunc(cards_rect.w - 16, 3);
            if (card_w <= 12) return;
            for (indices, 0..) |option_index, card_index| {
                const name = options[option_index];
                const x = cards_rect.x + 6 + @as(i32, @intCast(card_index)) * card_w;
                const active = card_index == 1;
                const preview = ui.AssetPreviewLayout.card(.{ .x = x, .y = cards_rect.y + 4, .w = card_w - 6, .h = cards_rect.h - 8 });
                ui.drawAssetPreviewFrame(c, preview, active);
                const avatar = displayAvatarByName(name) orelse continue;
                var icon = bgb.decodeIcon(std.heap.page_allocator, avatar) catch continue;
                defer icon.deinit(std.heap.page_allocator);
                blitHeightBottomAlphaSmooth(c, icon.pixels, icon.width, icon.height, preview.artwork.x, preview.artwork.y, preview.artwork.w, preview.artwork.h);
                if (preview.label.h > 0) drawTextEllipsized(c, name, preview.label.x, preview.label.y, preview.label.w, if (active) ui.current.accent else ui.current.secondary);
            }
        },
        .background => {
            const name = if (selected.len == 0) "Field" else selected;
            const data = dialogBackgroundByName(name) orelse return;
            var image = bgb.decodeBackground(std.heap.page_allocator, data) catch return;
            defer image.deinit(std.heap.page_allocator);
            const preview = ui.AssetPreviewLayout.inlinePreview(rect, 60);
            ui.drawAssetPreviewFrame(c, preview, false);
            blitFit(c, image.pixels, image.width, image.height, preview.artwork.x, preview.artwork.y, preview.artwork.w, preview.artwork.h);
            drawTextEllipsized(c, name, preview.label.x, preview.label.y, preview.label.w, ui.current.ink);
        },
        else => {},
    }
}

fn characterGalleryRect(layout: ui.DialogLayout, first_field: usize) Rect {
    var rect = layout.fieldRectScrolled(2, first_field);
    rect.h = @min(96, @max(30, layout.primary.y - rect.y - 28));
    return rect;
}

fn characterFamilyRect(gallery: Rect) Rect {
    if (gallery.h < 72) return .{ .x = gallery.x, .y = gallery.y, .w = gallery.w, .h = 0 };
    return .{ .x = gallery.x + 6, .y = gallery.y + 4, .w = gallery.w - 12, .h = 22 };
}

fn characterGalleryCardsRect(gallery: Rect) Rect {
    const family = characterFamilyRect(gallery);
    if (family.h == 0) return gallery;
    return .{ .x = gallery.x, .y = family.bottom() + 2, .w = gallery.w, .h = gallery.bottom() - family.bottom() - 2 };
}

fn dialogPrimaryButtonWidth(id: dialogs.Id) i32 {
    return @max(84, Canvas.uiTextWidth(dialogs.primaryLabel(id)) + 24);
}

fn drawDialogButton(c: *Canvas, x: i32, y: i32, width: i32, label: []const u8, kind: ui.ButtonKind, hovered: bool) void {
    ui.drawButton(c, x, y, width, label, kind, hovered);
}

test "view renders modern empty buffer and ui.current.chrome" {
    const gpa = std.testing.allocator;
    var view = try View.init(gpa, 960, 720);
    defer view.deinit();
    var transcript = session.Transcript.init(gpa);
    defer transcript.deinit();
    try transcript.setSelf("anna");

    try view.render("Comic Chat | #root | anna", "connected", &transcript, "hello", 3);
    const layout = geometry.Layout.compute(960, 720, true, true);
    try std.testing.expectEqual(ui.current.navigation, view.pixels()[0]);
    try std.testing.expectEqual(ui.current.ink, view.pixels()[@as(usize, @intCast(layout.tabs.bottom() - 1)) * 960]);
    try std.testing.expectEqual(ui.current.ink, view.pixels()[@as(usize, @intCast(layout.say.y + 1)) * 960 + 2]);

    const wheel = emotionWheelRect(layout);
    const dial = ui.moodDialInterior(wheel);
    try std.testing.expectEqual(ui.current.accent, view.pixels()[@as(usize, @intCast(wheel.y + 13)) * 960 + @as(usize, @intCast(layout.body_camera.x + 20))]);
    try std.testing.expectEqual(ui.current.paper, view.pixels()[@as(usize, @intCast(dial.y + @divTrunc(dial.h, 2))) * 960 + @as(usize, @intCast(dial.x + @divTrunc(dial.w, 2) + 20))]);
}

test "emotion dial selects and drags only within its circular control" {
    const gpa = std.testing.allocator;
    var view = try View.init(gpa, 960, 720);
    defer view.deinit();
    const layout = geometry.Layout.compute(960, 720, true, true);
    const dial = ui.moodDialInterior(emotionWheelRect(layout));
    const cx = dial.x + @divTrunc(dial.w, 2);
    const cy = dial.y + @divTrunc(dial.h, 2);

    _ = view.handlePointer(.{ .kind = .down, .x = cx + 12, .y = cy, .button = .primary }, 0, 0);
    try std.testing.expect(view.emotion_dragging);
    try std.testing.expect(view.shell.emotion_x > 0);
    _ = view.handlePointerMove(.{ .kind = .move, .x = cx - 18, .y = cy }, 0);
    try std.testing.expect(view.shell.emotion_x < 0);
    _ = view.handlePointer(.{ .kind = .up, .x = cx - 18, .y = cy, .button = .primary }, 0, 0);
    try std.testing.expect(!view.emotion_dragging);
}

test "view exposes a semantic shell snapshot without inspecting pixels" {
    var view = try View.init(std.testing.allocator, 960, 720);
    defer view.deinit();
    const tabs = [_]View.Tab{ .{ .label = "#root" }, .{ .label = "#onyx", .unread = 2 } };
    const snapshot = view.semanticSnapshot("connected", &tabs, 0);
    try std.testing.expect(snapshot.items().len >= 12);
    try std.testing.expectEqual(accessibility.Role.window, snapshot.items()[0].role);
    var found_selected_tab = false;
    for (snapshot.items()) |item| {
        if (item.role == .tab and item.selected) found_selected_tab = true;
    }
    try std.testing.expect(found_selected_tab);
}

test "toolbar and composer actions keep one keyboard-focused semantic control" {
    var view = try View.init(std.testing.allocator, 960, 720);
    defer view.deinit();
    view.shell.focus = .toolbar;
    _ = view.handleFocusedActionKey(.end);
    try std.testing.expectEqual(@as(u8, ui.ToolbarLayout.button_count - 1), view.focused_toolbar);
    const tabs = [_]View.Tab{.{ .label = "#root" }};
    var snapshot = view.semanticSnapshot("connected", &tabs, 0);
    var focused_toolbar_count: usize = 0;
    for (snapshot.items()) |node| {
        if (node.focused and std.mem.startsWith(u8, node.id, "toolbar-")) focused_toolbar_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), focused_toolbar_count);
    view.shell.focus = .say_actions;
    _ = view.handleFocusedActionKey(.right);
    snapshot = view.semanticSnapshot("connected", &tabs, 0);
    var focused_action_count: usize = 0;
    for (snapshot.items()) |node| {
        if (node.focused and std.mem.startsWith(u8, node.id, "say-action-")) focused_action_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), focused_action_count);
}

test "context menu keyboard skips disabled moderation controls" {
    var view = try View.init(std.testing.allocator, 960, 720);
    defer view.deinit();
    view.openContextMenu(.member, 200, 200);
    try std.testing.expectEqual(@as(?u8, 0), view.focused_context_item);
    _ = view.handleContextMenuKey(.end);
    try std.testing.expectEqual(@as(?u8, 2), view.focused_context_item);
    _ = view.handleContextMenuKey(.escape);
    try std.testing.expect(view.context_menu == null);
}

test "menu clicks select navigation without opening a modal dialog" {
    var view = try View.init(std.testing.allocator, 960, 720);
    defer view.deinit();
    const action = view.handlePointer(.{ .kind = .down, .x = 174, .y = 10, .button = .primary }, 0, 0);
    try std.testing.expectEqual(Action{ .menu = 0 }, action);
    try std.testing.expect(view.active_dialog == null);
    try std.testing.expectEqual(shell_mod.Focus.navigation, view.shell.focus);
}

test "every menu popup and command row stays reachable at minimum width" {
    const width: u32 = min_width;
    var menu: u8 = 0;
    while (menu < menu_labels.len) : (menu += 1) {
        const popup = menuPopupRect(width, menu);
        try std.testing.expect(popup.x >= 0);
        try std.testing.expect(popup.right() <= width);
        try std.testing.expect(popup.y >= geometry.menu_height);
        var item: u8 = 0;
        while (item < menuItemCount(menu)) : (item += 1) {
            const item_y = popup.y + 8 + @as(i32, item) * 29;
            try std.testing.expectEqual(item, menuPopupItem(width, menu, popup.x + 12, item_y).?);
        }
    }

    var view = try View.init(std.testing.allocator, min_width, min_height);
    defer view.deinit();
    view.active_menu = 6;
    const more = menuPopupRect(width, 6);
    _ = view.handlePointer(.{ .kind = .down, .x = more.x + 12, .y = more.y + 8 + 7 * 29, .button = .primary }, 0, 0);
    try std.testing.expectEqual(dialogs.Id.about, view.active_dialog.?);
}

test "comic density stepper changes the live four-across layout" {
    var view = try View.init(std.testing.allocator, 960, 720);
    defer view.deinit();
    const layout = geometry.Layout.compute(960, 720, true, true);
    const increase = geometry.comicColumnIncrease(layout);
    _ = view.handlePointer(.{ .kind = .down, .x = increase.x + 3, .y = increase.y + 3, .button = .primary }, 0, 0);
    try std.testing.expectEqual(@as(u8, 5), view.shell.comic_columns);
    const decrease = geometry.comicColumnDecrease(layout);
    _ = view.handlePointer(.{ .kind = .down, .x = decrease.x + 3, .y = decrease.y + 3, .button = .primary }, 0, 0);
    try std.testing.expectEqual(@as(u8, 4), view.shell.comic_columns);
}

test "composer and member controls expose hover state" {
    var view = try View.init(std.testing.allocator, 960, 720);
    defer view.deinit();
    const layout = geometry.Layout.compute(960, 720, true, true);
    const whisper_x = layout.say_actions.x + 2 * layout.say_action_size + 4;
    try std.testing.expect(view.handlePointerMove(.{ .kind = .move, .x = whisper_x, .y = layout.say_actions.y + 8 }, 2));
    try std.testing.expectEqual(@as(?u8, 2), view.hovered_say_action);
    try std.testing.expect(view.handlePointerMove(.{ .kind = .move, .x = layout.members.x + 8, .y = layout.members.y + 35 }, 2));
    try std.testing.expectEqual(@as(?usize, 0), view.hovered_member);
}

test "sound action opens its source dialog instead of sending malformed UDI" {
    var view = try View.init(std.testing.allocator, 960, 720);
    defer view.deinit();
    const layout = geometry.Layout.compute(960, 720, true, true);
    const sound_x = layout.say_actions.x + 4 * layout.say_action_size + 4;
    const action = view.handlePointer(.{
        .kind = .down,
        .x = sound_x,
        .y = layout.say_actions.y + 8,
        .button = .primary,
    }, 0, 0);
    try std.testing.expectEqual(Action.none, action);
    try std.testing.expectEqual(dialogs.Id.sound, view.active_dialog.?);
    try std.testing.expectEqual(shell_mod.SayMode.say, view.shell.say_mode);
}

test "status and connect toolbar expose a prefilled connection workflow" {
    var view = try View.init(std.testing.allocator, 960, 720);
    defer view.deinit();
    const layout = geometry.Layout.compute(960, 720, true, true);

    try std.testing.expect(view.handlePointerMove(.{ .kind = .move, .x = layout.status.x + 24, .y = layout.status.y + 10 }, 0));
    try std.testing.expect(view.hovered_status);
    try std.testing.expectEqual(Action.none, view.handlePointer(.{ .kind = .down, .x = layout.status.x + 24, .y = layout.status.y + 10, .button = .primary }, 0, 0));
    try std.testing.expect(view.status_panel_open);
    const status_layout = ui.StatusPanelLayout.init(view.width(), view.height(), true);
    const connection = status_layout.connection;
    try std.testing.expect(view.handlePointerMove(.{ .kind = .move, .x = connection.x + 5, .y = connection.y + 5 }, 0));
    try std.testing.expectEqual(@as(?StatusActionHover, .connection), view.hovered_status_action);
    try std.testing.expect(!view.hovered_status);
    try std.testing.expect(view.handlePointerMove(.{ .kind = .move, .x = status_layout.rect.x + 8, .y = status_layout.rect.y + 70 }, 0));
    try std.testing.expect(view.hovered_status_action == null);
    try std.testing.expect(view.handlePointerMove(.{ .kind = .move, .x = connection.x + 5, .y = connection.y + 5 }, 0));
    try std.testing.expectEqual(@as(?StatusActionHover, .connection), view.hovered_status_action);
    try std.testing.expectEqual(Action.connection, view.handlePointer(.{ .kind = .down, .x = connection.x + 5, .y = connection.y + 5, .button = .primary }, 0, 0));
    try std.testing.expect(!view.status_panel_open);
    try std.testing.expect(view.hovered_status_action == null);
    try std.testing.expectEqual(Action.none, view.handlePointer(.{ .kind = .down, .x = layout.status.x + 24, .y = layout.status.y + 10, .button = .primary }, 0, 0));
    try std.testing.expect(view.status_panel_open);
    try std.testing.expect(view.hovered_status_action == null);
    try std.testing.expect(view.handleFocusedKey(.escape, 0));

    try std.testing.expectEqual(Action.connection, view.handlePointer(.{ .kind = .down, .x = layout.toolbar.x + 16, .y = layout.toolbar.y + 12, .button = .primary }, 0, 0));
    view.openConnectionDialog("eshmaki.me", 6697, true);
    try std.testing.expectEqual(dialogs.Id.setup, view.active_dialog.?);
    try std.testing.expectEqualStrings("eshmaki.me", view.dialogValueAt(0));
    try std.testing.expectEqualStrings("6697", view.dialogValueAt(1));
    try std.testing.expectEqualStrings("Verified TLS", view.dialogValueAt(2));
}

test "status tab hover is independent of the bottom status bar" {
    var view = try View.init(std.testing.allocator, 960, 720);
    defer view.deinit();
    const layout = geometry.Layout.compute(960, 720, true, true);
    try std.testing.expect(view.handlePointerMove(.{ .kind = .move, .x = layout.tabs.x + 20, .y = layout.tabs.y + 10 }, 0));
    try std.testing.expect(view.hovered_status_tab);
    try std.testing.expect(!view.hovered_status);
    try std.testing.expect(view.handlePointerMove(.{ .kind = .move, .x = layout.status.x + 24, .y = layout.status.y + 10 }, 0));
    try std.testing.expect(view.hovered_status);
    try std.testing.expect(!view.hovered_status_tab);
}

test "room tabs expose hover independently of the status stamp" {
    var view = try View.init(std.testing.allocator, 960, 720);
    defer view.deinit();
    view.room_tab_count = 2;
    const layout = geometry.Layout.compute(960, 720, true, true);
    try std.testing.expect(view.handlePointerMove(.{ .kind = .move, .x = layout.tabs.x + 130, .y = layout.tabs.y + 10 }, 2));
    try std.testing.expectEqual(@as(?usize, 0), view.hovered_room_tab);
    try std.testing.expect(!view.hovered_status_tab);
    try std.testing.expect(view.handlePointerMove(.{ .kind = .move, .x = layout.tabs.x + 20, .y = layout.tabs.y + 10 }, 2));
    try std.testing.expect(view.hovered_status_tab);
    try std.testing.expect(view.hovered_room_tab == null);
}

test "settings menu opens application preferences instead of connection setup" {
    var view = try View.init(std.testing.allocator, 960, 720);
    defer view.deinit();
    const routes = [_]struct { menu: u8, item: u8 }{.{ .menu = 1, .item = 3 }};
    for (routes) |route| {
        view.active_menu = route.menu;
        const popup = menuPopupRect(view.width(), route.menu);
        const action = view.handlePointer(.{
            .kind = .down,
            .x = popup.x + 12,
            .y = popup.y + 8 + @as(i32, route.item) * 29,
            .button = .primary,
        }, 0, 0);
        try std.testing.expectEqual(Action{ .menu = route.menu }, action);
        try std.testing.expectEqual(dialogs.Id.settings, view.active_dialog.?);
        try std.testing.expectEqualStrings("Light studio", view.dialogValueAt(0));
        try std.testing.expectEqualStrings("Cobalt", view.dialogValueAt(1));
        try std.testing.expectEqualStrings("Standard", view.dialogValueAt(2));
        try std.testing.expectEqualStrings("Comic", view.dialogValueAt(3));
        try std.testing.expectEqualStrings("4 panels", view.dialogValueAt(4));
        _ = view.closeDialog();
    }
}

test "menu keyboard navigation wraps skips disabled commands and activates settings" {
    var view = try View.init(std.testing.allocator, 960, 720);
    defer view.deinit();
    view.shell.focus = .navigation;

    try std.testing.expectEqual(Action.none, view.handleMenuKey(.enter).?);
    try std.testing.expectEqual(@as(?u8, 0), view.active_menu);
    try std.testing.expectEqual(@as(?u8, 0), view.hovered_menu_item);
    try std.testing.expectEqual(Action.none, view.handleMenuKey(.left).?);
    try std.testing.expectEqual(@as(?u8, 6), view.active_menu);
    try std.testing.expectEqual(Action.none, view.handleMenuKey(.end).?);
    try std.testing.expectEqual(@as(?u8, 7), view.hovered_menu_item);
    try std.testing.expectEqual(Action.none, view.handleMenuKey(.escape).?);
    try std.testing.expect(view.active_menu == null);

    view.active_menu = 5;
    view.hovered_menu_item = 3;
    try std.testing.expectEqual(Action.none, view.handleMenuKey(.down).?);
    try std.testing.expectEqual(@as(?u8, 6), view.hovered_menu_item);

    view.active_menu = 1;
    view.hovered_menu_item = 3;
    try std.testing.expectEqual(Action{ .menu = 1 }, view.handleMenuKey(.enter).?);
    try std.testing.expectEqual(dialogs.Id.settings, view.active_dialog.?);
}

test "menu information architecture has one settings connection and transfer entry" {
    var settings_count: usize = 0;
    var connection_count: usize = 0;
    var transfer_count: usize = 0;
    var menu: u8 = 0;
    while (menu < menu_labels.len) : (menu += 1) {
        var item: u8 = 0;
        while (item < menuItemCount(menu)) : (item += 1) {
            const label = menuItemLabel(menu, item);
            if (std.mem.eql(u8, label, "Settings")) settings_count += 1;
            if (std.mem.eql(u8, label, "Connection setup")) connection_count += 1;
            if (std.ascii.eqlIgnoreCase(label, "File transfer")) transfer_count += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 1), settings_count);
    try std.testing.expectEqual(@as(usize, 1), connection_count);
    try std.testing.expectEqual(@as(usize, 1), transfer_count);
}

test "extensive settings reveal focused controls in the compact dialog viewport" {
    var view = try View.init(std.testing.allocator, min_width, min_height);
    defer view.deinit();
    view.openDialog(.settings);
    const layout = dialogLayout(view.width(), view.height(), dialogs.get(.settings));
    try std.testing.expect(layout.visibleRows() < dialogs.fields(.settings).len);
    var tabs: usize = 0;
    while (tabs < 7) : (tabs += 1) _ = try view.handleDialogKey(.tab, .{});
    try std.testing.expectEqual(@as(usize, 7), view.dialog_field);
    try std.testing.expect(view.dialog_first_field > 0);
    try std.testing.expect(view.dialog_field < view.dialog_first_field + layout.visibleRows());
}

test "character gallery browses adjacent cast members and previews expression" {
    var view = try View.init(std.testing.allocator, 960, 720);
    defer view.deinit();
    view.openDialog(.character);
    try std.testing.expectEqualStrings("Anna HD", view.dialogValueAt(0));
    const layout = dialogLayout(view.width(), view.height(), dialogs.get(.character));
    const gallery = characterGalleryRect(layout, 0);
    const cards = characterGalleryCardsRect(gallery);
    _ = view.handlePointer(.{ .kind = .down, .x = cards.right() - 8, .y = cards.y + 12, .button = .primary }, 0, 0);
    try std.testing.expectEqualStrings("Armando HD", view.dialogValueAt(0));
    const family = characterFamilyRect(gallery);
    _ = view.handlePointer(.{ .kind = .down, .x = family.x + @divTrunc(family.w * 2, 3) + 8, .y = family.y + 10, .button = .primary }, 0, 0);
    try std.testing.expectEqualStrings("Armando Original", view.dialogValueAt(0));
    try view.setDialogValueAt(0, "Xeno Color");
    _ = view.handlePointer(.{ .kind = .down, .x = cards.right() - 8, .y = cards.y + 12, .button = .primary }, 0, 0);
    try std.testing.expectEqualStrings("Anna Color", view.dialogValueAt(0));
    _ = view.handlePointer(.{ .kind = .down, .x = cards.x + 8, .y = cards.y + 12, .button = .primary }, 0, 0);
    try std.testing.expectEqualStrings("Xeno Color", view.dialogValueAt(0));
    view.dialog_field = 1;
    _ = try view.handleDialogKey(.right, .{});
    try std.testing.expectEqualStrings("Happy", view.dialogValueAt(1));
    try std.testing.expectEqualStrings("Happy", view.currentEmotionLabel());
}

test "dialog keyboard focus includes actions and protects typed choices" {
    var view = try View.init(std.testing.allocator, 960, 720);
    defer view.deinit();
    view.openDialog(.settings);
    try std.testing.expectEqualStrings("Light studio", view.dialogValueAt(0));
    _ = try view.handleDialogKey(.left, .{});
    try std.testing.expectEqualStrings("Dark studio", view.dialogValueAt(0));
    _ = try view.handleDialogKey(.backspace, .{});
    try std.testing.expectEqualStrings("Dark studio", view.dialogValueAt(0));

    var tab_count: usize = 0;
    while (tab_count < 8) : (tab_count += 1) _ = try view.handleDialogKey(.tab, .{});
    try std.testing.expectEqual(ui.DialogButton.primary, view.dialog_action_focus.?);
    _ = try view.handleDialogKey(.tab, .{});
    try std.testing.expectEqual(ui.DialogButton.cancel, view.dialog_action_focus.?);
    _ = try view.handleDialogKey(.tab, .{ .shift = true });
    try std.testing.expectEqual(ui.DialogButton.primary, view.dialog_action_focus.?);

    view.openDialog(.about);
    try std.testing.expectEqual(ui.DialogButton.primary, view.dialog_action_focus.?);
    const snapshot = view.semanticSnapshot("offline", &.{.{ .label = "Room" }}, 0);
    var focused: usize = 0;
    var cancel_buttons: usize = 0;
    for (snapshot.items()) |node| {
        if (node.focused) focused += 1;
        if (std.mem.eql(u8, node.id, "dialog-cancel")) cancel_buttons += 1;
        try std.testing.expect(node.role == .window or node.role == .dialog or std.mem.startsWith(u8, node.id, "dialog-"));
    }
    try std.testing.expectEqual(@as(usize, 1), focused);
    try std.testing.expectEqual(@as(usize, 0), cancel_buttons);
}

test "room tabs reserve the comic density control and keep the active room reachable" {
    var view = try View.init(std.testing.allocator, min_width, min_height);
    defer view.deinit();
    var transcript = session.Transcript.init(std.testing.allocator);
    defer transcript.deinit();
    const tabs = [_]View.Tab{ .{ .label = "#one" }, .{ .label = "#two" }, .{ .label = "#three" } };

    try view.renderTabs("connected", &transcript, "", 0, null, &tabs, 2);
    try std.testing.expectEqual(@as(usize, 1), view.room_tab_first);
    const layout = geometry.Layout.compute(min_width, min_height, true, true);
    const viewport = tabViewport(layout, true);
    const snapshot = view.semanticSnapshot("connected", &tabs, 2);
    var visible_tabs: usize = 0;
    for (snapshot.items()) |item| if (item.role == .tab) {
        visible_tabs += 1;
        try std.testing.expect(item.bounds.right() <= viewport.right);
    };
    try std.testing.expectEqual(@as(usize, 2), visible_tabs);

    const first_visible = view.handlePointer(.{ .kind = .down, .x = viewport.first_x + 8, .y = layout.tabs.y + 10, .button = .primary }, 0, 0);
    try std.testing.expectEqual(Action{ .room_tab = 1 }, first_visible);
    const increase = geometry.comicColumnIncrease(layout);
    const stepper = view.handlePointer(.{ .kind = .down, .x = increase.x + 4, .y = increase.y + 4, .button = .primary }, 0, 0);
    try std.testing.expectEqual(Action.none, stepper);
    try std.testing.expectEqual(@as(u8, 5), view.shell.comic_columns);
}

test "body camera and members expose working context menus" {
    var view = try View.init(std.testing.allocator, 960, 720);
    defer view.deinit();
    const layout = geometry.Layout.compute(960, 720, true, true);
    _ = view.handlePointer(.{ .kind = .down, .x = layout.body_camera.x + 30, .y = layout.body_camera.y + 60, .button = .secondary }, 0, 1);
    try std.testing.expectEqual(ContextKind.body_camera, view.context_menu.?);
    const popup = contextPopupRect(view.width(), view.height(), .body_camera, view.context_x, view.context_y);
    _ = view.handlePointer(.{ .kind = .down, .x = popup.x + 12, .y = popup.y + 10, .button = .primary }, 0, 1);
    try std.testing.expect(view.shell.emotion_frozen);
    try std.testing.expect(view.context_menu == null);

    _ = view.handlePointer(.{ .kind = .down, .x = layout.members.x + 12, .y = layout.members.y + 40, .button = .secondary }, 0, 1);
    try std.testing.expectEqual(ContextKind.member, view.context_menu.?);
    try std.testing.expectEqual(@as(?usize, 0), view.shell.selected_member);
}

test "typed connection choices cycle instead of accepting arbitrary text" {
    var view = try View.init(std.testing.allocator, 960, 720);
    defer view.deinit();
    view.openDialog(.setup);
    const layout = dialogLayout(view.width(), view.height(), dialogs.get(.setup));
    const security = layout.fieldRect(2);
    try std.testing.expectEqualStrings("Verified TLS", view.dialogValueAt(2));
    _ = view.handlePointer(.{ .kind = .down, .x = security.x + 4, .y = security.y + 4, .button = .primary }, 0, 0);
    try std.testing.expectEqualStrings("Plaintext (unsafe)", view.dialogValueAt(2));
    _ = view.handlePointer(.{ .kind = .down, .x = security.x + 4, .y = security.y + 4, .button = .primary }, 0, 0);
    try std.testing.expectEqualStrings("Verified TLS", view.dialogValueAt(2));
}

test "correcting a dialog field clears stale validation feedback" {
    var view = try View.init(std.testing.allocator, 960, 720);
    defer view.deinit();
    view.openConnectionDialog("eshmaki.me", 6697, true);
    view.setDialogNotice("Port must be between 1 and 65535.");
    view.dialog_field = 1;
    _ = try view.handleDialogKey(.backspace, .{});
    try std.testing.expectEqualStrings("", view.dialog_notice);

    view.setDialogNotice("Old error");
    const layout = dialogLayout(view.width(), view.height(), dialogs.get(.setup));
    const security = layout.fieldRect(2);
    _ = view.handlePointer(.{ .kind = .down, .x = security.x + 4, .y = security.y + 4, .button = .primary }, 0, 0);
    try std.testing.expectEqualStrings("", view.dialog_notice);
}

test "member wheel scroll maps visible cards to their roster index" {
    var view = try View.init(std.testing.allocator, 960, 720);
    defer view.deinit();
    const layout = geometry.Layout.compute(960, 720, true, true);
    _ = view.handlePointer(.{ .kind = .wheel, .x = layout.members.x + 20, .y = layout.members.y + 50, .wheel_y = -1 }, 0, 7);
    try std.testing.expectEqual(@as(usize, 2), view.shell.member_offset);
    _ = view.handlePointer(.{ .kind = .down, .x = layout.members.x + 20, .y = layout.members.y + 40, .button = .primary }, 0, 7);
    try std.testing.expectEqual(@as(?usize, 2), view.shell.selected_member);
}

test "single line inputs retain a visible caret window and place the cursor by pixel" {
    try std.testing.expectEqual(@as(i32, 0), placeholderGap(false));
    try std.testing.expectEqual(@as(i32, 8), placeholderGap(true));
    const text = "a long input value that is wider than the field";
    const window = visibleTextWindow(text, text.len, 96);
    try std.testing.expect(window.left_hidden);
    try std.testing.expectEqual(text.len, window.end);
    try std.testing.expect(Canvas.uiTextWidth(text[window.start..window.end]) <= 96);

    var editor = input_mod.Editor.init(std.testing.allocator);
    defer editor.deinit();
    try editor.paste("hello world");
    const full = visibleTextWindow(editor.text(), editor.cursor, 200);
    placeEditorCursor(&editor, full, Canvas.uiTextWidth("hello"));
    try std.testing.expectEqual(@as(usize, 5), editor.cursor);
}

test "multiline composer shares a two-row viewport with pointer placement" {
    const text = "first line\nsecond line\nthird line";
    const second_cursor = "first line\nsecond".len;
    const middle = composerViewport(text, second_cursor, 240);
    try std.testing.expectEqual(@as(usize, 2), middle.count);
    try std.testing.expectEqualStrings("first line", text[middle.rows[0].window.start..middle.rows[0].window.end]);
    try std.testing.expectEqualStrings("second line", text[middle.rows[1].window.start..middle.rows[1].window.end]);
    try std.testing.expect(middle.rows[1].cursor_row);

    var view = try View.init(std.testing.allocator, 960, 720);
    defer view.deinit();
    var editor = input_mod.Editor.init(std.testing.allocator);
    defer editor.deinit();
    try editor.paste(text);
    editor.cursor = second_cursor;
    const layout = geometry.Layout.compute(960, 720, true, true);
    view.placeComposerCursor(&editor, layout.say_editor.x + 18 + Canvas.uiTextWidth("first"), layout.say_editor.y + 12);
    try std.testing.expectEqual(@as(usize, "first".len), editor.cursor);
    editor.cursor = second_cursor;
    view.placeComposerCursor(&editor, layout.say_editor.x + 18 + Canvas.uiTextWidth("second"), layout.say_editor.y + 34);
    try std.testing.expectEqual(@as(usize, "first line\nsecond".len), editor.cursor);
}

test "dialog inputs support shift selection and mouse caret placement" {
    var view = try View.init(std.testing.allocator, 960, 720);
    defer view.deinit();
    view.openDialog(.nickname);
    for ("comicchat") |ch| _ = try view.handleDialogKey(.{ .char = ch }, .{});
    _ = try view.handleDialogKey(.home, .{});
    _ = try view.handleDialogKey(.right, .{ .shift = true });
    _ = try view.handleDialogKey(.right, .{ .shift = true });
    try std.testing.expectEqual(@as(usize, 2), view.dialog_editors[0].selection().?.end);

    const layout = dialogLayout(view.width(), view.height(), dialogs.get(.nickname));
    const field = layout.fieldRect(0);
    _ = view.handlePointer(.{ .kind = .down, .x = field.x + 11 + Canvas.uiTextWidth("comic"), .y = field.y + 10, .button = .primary }, 0, 0);
    try std.testing.expectEqual(@as(usize, 5), view.dialog_editors[0].cursor);
    try std.testing.expect(view.dialog_editors[0].selection() == null);
}

test "every dialog keeps fields and actions separated at supported window sizes" {
    const sizes = [_]struct { w: u32, h: u32 }{
        .{ .w = min_width, .h = min_height },
        .{ .w = 800, .h = 600 },
        .{ .w = 960, .h = 720 },
    };
    for (sizes) |size| for (dialogs.specs) |spec| {
        const layout = dialogLayout(size.w, size.h, spec);
        try std.testing.expect(layout.rect.x >= 0 and layout.rect.y >= 0);
        try std.testing.expect(layout.rect.right() <= size.w and layout.rect.bottom() <= size.h);
        try std.testing.expect(layout.primary.x >= layout.rect.x and layout.primary.right() <= layout.rect.right());
        try std.testing.expect(layout.cancel.x >= layout.rect.x and layout.cancel.right() <= layout.rect.right());
        try std.testing.expect(layout.primary.right() <= layout.cancel.x);
        const visible = layout.visibleRows();
        var index: usize = 0;
        while (index < @min(visible, dialogs.fields(spec.id).len)) : (index += 1) {
            const field = layout.fieldRectScrolled(index, 0);
            try std.testing.expect(field.x >= layout.rect.x and field.right() <= layout.rect.right());
            try std.testing.expect(field.y >= layout.body_y and field.bottom() <= layout.primary.y);
            try std.testing.expectEqual(index, layout.fieldIndexAtScrolled(field.x + 2, field.y + 2, 0).?);
            if (index > 0) try std.testing.expect(layout.fieldRectScrolled(index - 1, 0).bottom() <= layout.fieldLabelYScrolled(index, 0));
        }
    };
}

test "alpha-aware avatar scaling does not pull black from transparent pixels" {
    const source = [_]u32{ 0xffffffff, 0x00000000 };
    const sample = bilinearAlphaSample(&source, 2, 1, 32768, 0);
    try std.testing.expect(sample.alpha >= 127 and sample.alpha <= 128);
    try std.testing.expectEqual(@as(u32, 0x00ffffff), sample.rgb);
}

test "every bundled avatar produces a visible mugshot and full figure" {
    const names = [_][]const u8{
        "anna",   "armando",  "bolo",    "cro",  "dan",     "denise", "hugh",   "jordan", "kevin", "kwensa",   "lance",
        "lynnea", "margaret", "maynard", "mike", "rebecca", "sage",   "scotty", "susan",  "tiki",  "tongtyed", "xeno",
    };
    var canvas = try Canvas.init(std.testing.allocator, 120, 180);
    defer canvas.deinit(std.testing.allocator);
    for (names) |name| {
        const data = strip.avatarByName(name) orelse return error.TestUnexpectedResult;
        var icon = try bgb.decodeIcon(std.testing.allocator, data);
        defer icon.deinit(std.testing.allocator);
        try std.testing.expect(icon.width > 0 and icon.height > 0);
        canvas.clear(ui.current.layer);
        blitHeightBottomAlphaSmooth(&canvas, icon.pixels, icon.width, icon.height, 30, 10, 60, 60);
        var visible_icon = false;
        for (canvas.px) |pixel| if (pixel != ui.current.layer) {
            visible_icon = true;
            break;
        };
        try std.testing.expect(visible_icon);

        var full = try figure.assembleForText(std.testing.allocator, data, "");
        defer full.deinit(std.testing.allocator);
        try std.testing.expect(full.width > 0 and full.height > 0);
        canvas.clear(ui.current.layer);
        blitHeightBottomAlphaSmooth(&canvas, full.pixels, full.width, full.height, 10, 10, 100, 160);
        var visible_figure = false;
        for (canvas.px) |pixel| if (pixel != ui.current.layer) {
            visible_figure = true;
            break;
        };
        try std.testing.expect(visible_figure);
        try std.testing.expectEqual(ui.current.layer, canvas.px[0]);
    }
}

test "every selectable color avatar decodes to a visibly colored gallery portrait" {
    for (dialogs.choiceOptions(.character, 0)) |name| {
        if (!std.mem.endsWith(u8, name, "Color")) continue;
        const data = strip.avatarByName(name) orelse return error.TestUnexpectedResult;
        var icon = try bgb.decodeIcon(std.testing.allocator, data);
        defer icon.deinit(std.testing.allocator);
        var colorful = false;
        for (icon.pixels) |pixel| {
            const red: u8 = @truncate(pixel >> 16);
            const green: u8 = @truncate(pixel >> 8);
            const blue: u8 = @truncate(pixel);
            if (red != green or green != blue) {
                colorful = true;
                break;
            }
        }
        try std.testing.expect(colorful);
    }
}

test "dialog dimmer preserves an opaque visible frame" {
    var view = try View.init(std.testing.allocator, 320, 240);
    defer view.deinit();
    var transcript = session.Transcript.init(std.testing.allocator);
    defer transcript.deinit();
    view.openDialog(.settings);
    try view.render("Comic Chat", "offline", &transcript, "", 0);
    const pixel = view.pixels()[0];
    try std.testing.expectEqual(@as(u32, 0xff), pixel >> 24);
    try std.testing.expect((pixel & 0x00ffffff) != 0);
}

test "view switches text/comic buffers, pages history, and resizes" {
    const gpa = std.testing.allocator;
    var view = try View.init(gpa, 640, 480);
    defer view.deinit();
    var transcript = session.Transcript.init(gpa);
    defer transcript.deinit();
    try transcript.setSelf("anna");
    var index: usize = 0;
    while (index < 14) : (index += 1) try transcript.add(if (index % 2 == 0) "anna" else "kevin", "A live chat buffer line");

    view.setContentMode(.text);
    view.pageEarlier(transcript.lines.items.len);
    try view.render("Comic Chat | #root | anna", "connected", &transcript, "", 0);
    try std.testing.expect(view.shell.history_offset > 0);
    try view.resize(960, 720);
    view.setContentMode(.comic);
    try view.render("Comic Chat | #root | anna", "connected", &transcript, "reply", 5);
    try std.testing.expectEqual(@as(u32, 960), view.width());
    try std.testing.expectEqual(@as(u32, 720), view.height());
}

test "text transcript hit testing ignores room chrome and blank space" {
    const gpa = std.testing.allocator;
    var view = try View.init(gpa, 960, 720);
    defer view.deinit();
    var transcript = session.Transcript.init(gpa);
    defer transcript.deinit();
    try transcript.add("anna", "First room message");
    try transcript.add("kevin", "Second room message");
    view.setContentMode(.text);
    const layout = geometry.Layout.compute(view.width(), view.height(), false, view.shell.show_members);

    _ = view.selectTranscriptAt(layout.transcript, layout.transcript.x + 20, layout.transcript.y + 10, transcript.lines.items.len);
    try std.testing.expect(view.shell.transcriptSelection() == null);
    _ = view.handlePointer(.{ .kind = .down, .x = layout.transcript.x + 20, .y = layout.transcript.y + 10, .button = .primary }, transcript.lines.items.len, 0);
    try std.testing.expectEqual(shell_mod.Focus.composer, view.shell.focus);

    const first_row_y = layout.transcript.y + 30 + 4;
    _ = view.selectTranscriptAt(layout.transcript, layout.transcript.x + 20, first_row_y + 8, transcript.lines.items.len);
    try std.testing.expectEqual(@as(?usize, 0), view.shell.transcript_cursor);

    _ = view.selectTranscriptAt(layout.transcript, layout.transcript.x + 20, layout.transcript.bottom() - 8, transcript.lines.items.len);
    try std.testing.expectEqual(@as(?usize, 0), view.shell.transcript_cursor);
}

test "every registered dialog can be opened and rendered" {
    const gpa = std.testing.allocator;
    var view = try View.init(gpa, 960, 720);
    defer view.deinit();
    var transcript = session.Transcript.init(gpa);
    defer transcript.deinit();
    for (dialogs.specs) |spec| {
        view.openDialog(spec.id);
        try view.render("Comic Chat", "connected", &transcript, "", 0);
        try std.testing.expectEqual(spec.id, view.active_dialog.?);
    }
}

test "file workflow dialogs expose a clickable native browse action" {
    var view = try View.init(std.testing.allocator, 960, 720);
    defer view.deinit();
    view.openDialog(.open_conversation);
    const layout = dialogLayout(view.width(), view.height(), dialogs.get(.open_conversation));
    const browse = dialogBrowseRect(layout.fieldRect(0));
    try std.testing.expect(view.handlePointerMove(.{ .kind = .move, .x = layout.fieldRect(0).x + 8, .y = layout.fieldRect(0).y + 8 }, 0));
    try std.testing.expectEqual(@as(?usize, 0), view.hovered_dialog_field);
    try std.testing.expect(view.hovered_dialog_browse == null);
    try std.testing.expect(view.handlePointerMove(.{ .kind = .move, .x = browse.x + 4, .y = browse.y + 4 }, 0));
    try std.testing.expectEqual(@as(?usize, 0), view.hovered_dialog_browse);
    try std.testing.expectEqual(Action{ .dialog_browse = .open_conversation }, view.handlePointer(.{
        .kind = .down,
        .x = browse.x + 4,
        .y = browse.y + 4,
        .button = .primary,
    }, 0, 0));
}

test "scrolled file-transfer browse action keeps its own hover and hit bounds" {
    var view = try View.init(std.testing.allocator, min_width, min_height);
    defer view.deinit();
    view.openDialog(.file_transfer);
    view.dialog_first_field = 1;
    const layout = dialogLayout(view.width(), view.height(), dialogs.get(.file_transfer));
    const field = layout.fieldRectScrolled(2, view.dialog_first_field);
    const browse = dialogBrowseRect(field);
    try std.testing.expect(view.handlePointerMove(.{ .kind = .move, .x = field.x + 8, .y = field.y + 8 }, 0));
    try std.testing.expectEqual(@as(?usize, 2), view.hovered_dialog_field);
    try std.testing.expect(view.hovered_dialog_browse == null);
    try std.testing.expect(view.handlePointerMove(.{ .kind = .move, .x = browse.x + 4, .y = browse.y + 4 }, 0));
    try std.testing.expectEqual(@as(?usize, 2), view.hovered_dialog_browse);
    try std.testing.expectEqual(Action{ .dialog_browse = .file_transfer }, view.handlePointer(.{
        .kind = .down,
        .x = browse.x + 4,
        .y = browse.y + 4,
        .button = .primary,
    }, 0, 0));
}

test "moderation menu actions are disabled until the local role permits them" {
    var view = try View.init(std.testing.allocator, 960, 720);
    defer view.deinit();
    const popup = menuPopupRect(view.width(), 5);
    view.active_menu = 5;
    _ = view.handlePointer(.{ .kind = .down, .x = popup.x + 10, .y = popup.y + 8 + 4 * 29, .button = .primary }, 0, 1);
    try std.testing.expect(view.active_dialog == null);

    view.can_moderate = true;
    view.active_menu = 5;
    _ = view.handlePointer(.{ .kind = .down, .x = popup.x + 10, .y = popup.y + 8 + 4 * 29, .button = .primary }, 0, 1);
    try std.testing.expectEqual(dialogs.Id.kick, view.active_dialog.?);
}
