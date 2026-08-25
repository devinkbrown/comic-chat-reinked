//! Portable registry for every dialog/property-page template in chat.rc.
//!
//! The registry is intentionally exhaustive: application routing refers to a
//! typed ID instead of scattering legacy resource numbers through the UI.

const std = @import("std");

pub const Id = enum {
    about,
    room_list,
    settings,
    personal,
    character,
    background,
    kick,
    nickname,
    channel,
    channel_properties,
    ban,
    invite,
    sound,
    set_text_font,
    user_list,
    whisper,
    comics_view,
    automation,
    rules,
    edit_rule,
    channel_create,
    channel_password,
    file_transfer,
    motd,
    setup,
    away,
    text_font,
    choose_color,
    invitation,
    advanced_event_params,
    rule_sets,
    add_to_sets,
    rename_loaded_set,
    rename_set,
    notifications,
    advanced_rule_settings,
    notification_users,
    servers,
    password,
    create_set,
    open_conversation,
    save_conversation,
    export_image,
    ircx_properties,
    room_access,
    ircx_events,
    call_link,
    member_profile,
    open_locator,
    recent_files,
    favorite_rooms,
    print_preview,
    connection_features,
};

pub const Group = enum { application, connection, rooms, automation, files };

pub const Spec = struct {
    id: Id,
    resource: []const u8,
    title: []const u8,
    group: Group,
    source_w: u16,
    source_h: u16,
};

/// Visible controls for the portable dialog surface. The first editable field
/// is bound to the shared modal editor; remaining rows expose the rest of the
/// established dialog contract without collapsing every dialog into one placeholder.
pub const FieldKind = enum { text, password, choice, list, preview, readonly };
pub const Field = struct { label: []const u8, hint: []const u8 = "", kind: FieldKind = .text };

pub const specs = [_]Spec{
    .{ .id = .about, .resource = "IDD_ABOUTBOX", .title = "About Comic Chat", .group = .files, .source_w = 279, .source_h = 137 },
    .{ .id = .room_list, .resource = "IDD_ROOMLIST", .title = "Room list", .group = .rooms, .source_w = 400, .source_h = 255 },
    .{ .id = .settings, .resource = "IDD_SETTINGSPAGE", .title = "Settings", .group = .application, .source_w = 360, .source_h = 300 },
    .{ .id = .personal, .resource = "IDD_PERSONALPAGE_IRC", .title = "Personal profile", .group = .connection, .source_w = 252, .source_h = 218 },
    .{ .id = .character, .resource = "IDD_CHARACTERPAGE", .title = "Choose character", .group = .connection, .source_w = 360, .source_h = 260 },
    .{ .id = .background, .resource = "IDD_BACKGROUNDPAGE", .title = "Background", .group = .connection, .source_w = 252, .source_h = 218 },
    .{ .id = .kick, .resource = "IDD_KICK", .title = "Kick member", .group = .rooms, .source_w = 186, .source_h = 89 },
    .{ .id = .nickname, .resource = "IDD_NICKNAME", .title = "Sign-in name", .group = .connection, .source_w = 188, .source_h = 71 },
    .{ .id = .channel, .resource = "IDD_CHANNEL", .title = "Join room", .group = .rooms, .source_w = 144, .source_h = 110 },
    .{ .id = .channel_properties, .resource = "IDD_CHANNELPROP", .title = "Room properties", .group = .rooms, .source_w = 186, .source_h = 196 },
    .{ .id = .ban, .resource = "IDD_BAN", .title = "Ban or unban", .group = .rooms, .source_w = 186, .source_h = 170 },
    .{ .id = .invite, .resource = "IDD_INVITE", .title = "Invite member", .group = .rooms, .source_w = 186, .source_h = 89 },
    .{ .id = .sound, .resource = "IDD_SOUND_DLG", .title = "Send sound", .group = .rooms, .source_w = 188, .source_h = 228 },
    .{ .id = .set_text_font, .resource = "IDD_SETTEXTFONT", .title = "Text font", .group = .connection, .source_w = 264, .source_h = 261 },
    .{ .id = .user_list, .resource = "IDD_USERLIST", .title = "CAST list", .group = .rooms, .source_w = 395, .source_h = 263 },
    .{ .id = .whisper, .resource = "IDD_WHISPERBOX", .title = "Whisper", .group = .rooms, .source_w = 334, .source_h = 196 },
    .{ .id = .comics_view, .resource = "IDD_COMICS_VIEW", .title = "Page layout", .group = .connection, .source_w = 252, .source_h = 218 },
    .{ .id = .automation, .resource = "IDD_AUTOMATION_PAGE", .title = "Automation", .group = .automation, .source_w = 252, .source_h = 218 },
    .{ .id = .rules, .resource = "IDD_RULESPAGE", .title = "Rules", .group = .automation, .source_w = 252, .source_h = 218 },
    .{ .id = .edit_rule, .resource = "IDD_EDITRULE", .title = "Edit rule", .group = .automation, .source_w = 265, .source_h = 260 },
    .{ .id = .channel_create, .resource = "IDD_CHANNELCREATE", .title = "Create room", .group = .rooms, .source_w = 186, .source_h = 194 },
    .{ .id = .channel_password, .resource = "IDD_CHANPASSWORD", .title = "Room password", .group = .rooms, .source_w = 173, .source_h = 86 },
    .{ .id = .file_transfer, .resource = "IDD_FILE_TRANSFER", .title = "File transfer", .group = .files, .source_w = 300, .source_h = 236 },
    .{ .id = .motd, .resource = "IDD_MOTD", .title = "Bulletin", .group = .rooms, .source_w = 298, .source_h = 146 },
    .{ .id = .setup, .resource = "IDD_SETUPDIALOG", .title = "Connection setup", .group = .connection, .source_w = 252, .source_h = 218 },
    .{ .id = .away, .resource = "IDD_AWAYDLG", .title = "Away message", .group = .rooms, .source_w = 186, .source_h = 87 },
    .{ .id = .text_font, .resource = "IDD_TEXTFONTPAGE_IRC", .title = "Text font", .group = .connection, .source_w = 252, .source_h = 218 },
    .{ .id = .choose_color, .resource = "IDD_CHOOSECOLOR", .title = "Choose color", .group = .connection, .source_w = 118, .source_h = 38 },
    .{ .id = .invitation, .resource = "IDD_INVITATION", .title = "Invitation", .group = .rooms, .source_w = 186, .source_h = 93 },
    .{ .id = .advanced_event_params, .resource = "IDD_ADVANCEDEVENTPARAMS", .title = "Rule limits", .group = .automation, .source_w = 186, .source_h = 85 },
    .{ .id = .rule_sets, .resource = "IDD_RULESETSPAGE", .title = "Rule sets", .group = .automation, .source_w = 252, .source_h = 218 },
    .{ .id = .add_to_sets, .resource = "IDD_ADDTOSETS", .title = "Add to rule sets", .group = .automation, .source_w = 252, .source_h = 161 },
    .{ .id = .rename_loaded_set, .resource = "IDD_RENAMELOADEDSET", .title = "Rename open set", .group = .automation, .source_w = 258, .source_h = 103 },
    .{ .id = .rename_set, .resource = "IDD_RENAMESET", .title = "Rename rule set", .group = .automation, .source_w = 226, .source_h = 79 },
    .{ .id = .notifications, .resource = "IDD_NOTIFICATIONS", .title = "Online notifications", .group = .automation, .source_w = 252, .source_h = 218 },
    .{ .id = .advanced_rule_settings, .resource = "IDD_ADVANCEDRULESETTINGS", .title = "Rule settings", .group = .automation, .source_w = 186, .source_h = 95 },
    .{ .id = .notification_users, .resource = "IDD_NOTIFICATIONUSERS", .title = "Online CAST", .group = .automation, .source_w = 262, .source_h = 111 },
    .{ .id = .servers, .resource = "IDD_SERVERSPAGE", .title = "Servers", .group = .connection, .source_w = 252, .source_h = 218 },
    .{ .id = .password, .resource = "IDD_PASSWORD", .title = "Password", .group = .connection, .source_w = 198, .source_h = 127 },
    .{ .id = .create_set, .resource = "IDD_CREATESET", .title = "Create rule set", .group = .automation, .source_w = 226, .source_h = 79 },
    .{ .id = .open_conversation, .resource = "PORTABLE_OPEN_CONVERSATION", .title = "Open conversation", .group = .files, .source_w = 300, .source_h = 108 },
    .{ .id = .save_conversation, .resource = "PORTABLE_SAVE_CONVERSATION", .title = "Save conversation", .group = .files, .source_w = 300, .source_h = 108 },
    .{ .id = .export_image, .resource = "PORTABLE_EXPORT_IMAGE", .title = "Export comic image", .group = .files, .source_w = 300, .source_h = 108 },
    .{ .id = .ircx_properties, .resource = "PORTABLE_IRCX_PROPERTIES", .title = "Named properties", .group = .rooms, .source_w = 300, .source_h = 210 },
    .{ .id = .room_access, .resource = "PORTABLE_ROOM_ACCESS", .title = "Room access", .group = .rooms, .source_w = 300, .source_h = 236 },
    .{ .id = .ircx_events, .resource = "PORTABLE_IRCX_EVENTS", .title = "Room events", .group = .rooms, .source_w = 300, .source_h = 184 },
    .{ .id = .call_link, .resource = "PORTABLE_CALL_LINK", .title = "Call link", .group = .connection, .source_w = 300, .source_h = 184 },
    .{ .id = .member_profile, .resource = "PORTABLE_MEMBER_PROFILE", .title = "Member profile", .group = .connection, .source_w = 300, .source_h = 132 },
    .{ .id = .open_locator, .resource = "PORTABLE_OPEN_LOCATOR", .title = "Open chat locator", .group = .files, .source_w = 300, .source_h = 108 },
    .{ .id = .recent_files, .resource = "PORTABLE_RECENT_FILES", .title = "Recent conversations", .group = .files, .source_w = 340, .source_h = 150 },
    .{ .id = .favorite_rooms, .resource = "PORTABLE_FAVORITE_ROOMS", .title = "Favorite rooms", .group = .rooms, .source_w = 320, .source_h = 184 },
    .{ .id = .print_preview, .resource = "PORTABLE_PRINT_PREVIEW", .title = "Print and PDF preview", .group = .files, .source_w = 320, .source_h = 150 },
    .{ .id = .connection_features, .resource = "PORTABLE_CONNECTION_FEATURES", .title = "Connection features", .group = .connection, .source_w = 360, .source_h = 210 },
};

pub const microsoft_dialog_count: usize = 40;

pub fn get(id: Id) Spec {
    return specs[@intFromEnum(id)];
}

pub fn fromResource(name: []const u8) ?Id {
    for (specs) |spec| if (std.ascii.eqlIgnoreCase(name, spec.resource)) return spec.id;
    return null;
}

pub fn prompt(id: Id) ?[]const u8 {
    return switch (id) {
        .channel, .channel_create => "Room name",
        .nickname => "Sign-in name",
        .kick, .ban, .invite, .whisper, .call_link, .member_profile => "CAST member",
        .away => "Away message",
        .password, .channel_password => "Password",
        .choose_color => "Color value",
        .sound => "Sound name",
        .set_text_font, .text_font => "Font name and size",
        .rename_loaded_set, .rename_set, .create_set => "Rule set name",
        .advanced_event_params => "Rule limits",
        .file_transfer => "File path",
        .open_conversation, .recent_files => "Conversation file",
        .open_locator => "Chat locator file",
        .save_conversation => "Conversation file",
        .export_image => "PNG file",
        .print_preview => "PDF file",
        .background => "Backdrop name",
        .character => "Character name",
        .personal => "Profile text",
        else => null,
    };
}

pub fn fields(id: Id) []const Field {
    return switch (id) {
        .setup, .servers => &.{ .{ .label = "Server", .hint = "Host name or address" }, .{ .label = "Port", .hint = "6697" }, .{ .label = "Security", .hint = "Verified TLS", .kind = .choice } },
        .settings => &.{
            .{ .label = "Color theme", .hint = "Light or dark studio", .kind = .choice },
            .{ .label = "Accent color", .hint = "Vermillion, violet, or forest", .kind = .choice },
            .{ .label = "Contrast", .hint = "Ink weight on chrome", .kind = .choice },
            .{ .label = "Conversation view", .hint = "Sunday page or conversation", .kind = .choice },
            .{ .label = "Panels across", .hint = "One to six across the page", .kind = .choice },
            .{ .label = "Member pane", .hint = "CAST rail visibility", .kind = .choice },
            .{ .label = "Member layout", .hint = "Portraits or compact list", .kind = .choice },
            .{ .label = "Status details", .hint = "Activity panel density", .kind = .choice },
        },
        .personal => &.{ .{ .label = "Profile text", .hint = "Shown on your CAST card" }, .{ .label = "Display name", .hint = "Visible sign-in name" }, .{ .label = "Homepage", .hint = "Optional" }, .{ .label = "Email", .hint = "Optional" } },
        .character => &.{
            .{ .label = "Character", .kind = .choice },
            .{ .label = "Expression preview", .kind = .choice },
            .{ .label = "Character gallery", .hint = "Previous, selected, and next", .kind = .preview },
        },
        .background => &.{ .{ .label = "Backdrop name", .kind = .choice }, .{ .label = "Preview", .hint = "Bundled background", .kind = .preview } },
        .nickname => &.{.{ .label = "Sign-in name", .hint = "Visible on the Sunday page" }},
        .password => &.{ .{ .label = "Account", .hint = "Server account name" }, .{ .label = "Password", .hint = "Account password", .kind = .password } },
        .channel => &.{ .{ .label = "Room name", .hint = "#room" }, .{ .label = "Optional password", .hint = "If the room is locked", .kind = .password } },
        .channel_create => &.{
            .{ .label = "Room name", .hint = "#room" },
            .{ .label = "Topic", .hint = "Optional" },
            .{ .label = "Room options", .hint = "Optional; one word" },
            .{ .label = "Maximum users", .hint = "Optional" },
            .{ .label = "Optional password", .kind = .password },
        },
        .channel_properties => &.{ .{ .label = "Topic", .hint = "Shown on the Sunday page" }, .{ .label = "Room options", .hint = "Optional; one word" }, .{ .label = "Maximum users", .hint = "Optional" }, .{ .label = "Optional password", .kind = .password }, .{ .label = "Summary", .hint = "Topic, options and limits", .kind = .readonly } },
        .channel_password => &.{.{ .label = "Room password", .hint = "Needed if the room is locked" }},
        .room_list => &.{ .{ .label = "Room search", .hint = "For example #root or a size filter" }, .{ .label = "Room to join", .hint = "Optional, for example #root" }, .{ .label = "Result limit", .hint = "Optional; blank means unlimited" } },
        .user_list => &.{ .{ .label = "CAST member", .hint = "Choose a visible room member" }, .{ .label = "Filter", .hint = "Optional name filter" } },
        .kick => &.{ .{ .label = "CAST member", .hint = "Visible CAST member" }, .{ .label = "Reason", .hint = "Optional" }, .{ .label = "Also ban pattern", .hint = "Optional" } },
        .ban => &.{.{ .label = "Ban pattern", .hint = "Name pattern, such as nick!*@*" }},
        .invite, .whisper => &.{.{ .label = "CAST member", .hint = "Visible CAST member" }},
        .notification_users => &.{ .{ .label = "Online now", .hint = "Refresh to query saved notifications", .kind = .readonly }, .{ .label = "Member", .hint = "Select an online CAST member" }, .{ .label = "Action", .kind = .choice }, .{ .label = "Room", .hint = "For Join room, for example #root" } },
        .away => &.{.{ .label = "Away message", .hint = "Posted while you are away" }},
        .sound => &.{ .{ .label = "Sound file", .kind = .choice }, .{ .label = "Accompanying message", .hint = "Optional" } },
        .set_text_font, .text_font => &.{ .{ .label = "Font name and size", .kind = .choice }, .{ .label = "Style", .hint = "Bold", .kind = .choice } },
        .choose_color => &.{ .{ .label = "Color value", .hint = "#RRGGBB or name" }, .{ .label = "Preview", .hint = "Current theme color", .kind = .preview } },
        .comics_view => &.{ .{ .label = "Page mode", .hint = "Sunday page or conversation", .kind = .choice }, .{ .label = "Panels across", .hint = "4 panels", .kind = .choice } },
        .automation => &.{ .{ .label = "Greeting mode", .kind = .choice }, .{ .label = "Greeting", .hint = "Use %nick% for the arriving member" }, .{ .label = "Repeat limit", .hint = "8" }, .{ .label = "Repeat window seconds", .hint = "10" } },
        .rules, .edit_rule => &.{ .{ .label = "Rule name", .hint = "Short label" }, .{ .label = "Event", .kind = .choice }, .{ .label = "Filter", .hint = "Optional text or name pattern" }, .{ .label = "Action", .kind = .choice }, .{ .label = "Action value", .hint = "Message, room or sound" } },
        .rule_sets => &.{ .{ .label = "Action", .kind = .choice }, .{ .label = "Rule set name" }, .{ .label = "Import or export file", .hint = "Optional .ccrules path" } },
        .add_to_sets => &.{ .{ .label = "Rule name" }, .{ .label = "Rule set" } },
        .rename_loaded_set, .rename_set => &.{ .{ .label = "Current rule set" }, .{ .label = "New name" } },
        .create_set => &.{.{ .label = "Rule set name" }},
        .advanced_event_params => &.{ .{ .label = "Rule name" }, .{ .label = "Repeat limit", .hint = "0 means unlimited" }, .{ .label = "Repeat window seconds", .hint = "0 means any interval" } },
        .advanced_rule_settings => &.{ .{ .label = "Rule name" }, .{ .label = "Enabled", .kind = .choice }, .{ .label = "Case-sensitive match", .kind = .choice } },
        .notifications => &.{ .{ .label = "Name", .hint = "Name or * pattern" }, .{ .label = "Account pattern", .hint = "*" }, .{ .label = "Address pattern", .hint = "*" }, .{ .label = "Network", .hint = "Optional server" }, .{ .label = "Delivery", .kind = .choice } },
        .file_transfer => &.{ .{ .label = "Direction", .kind = .choice }, .{ .label = "Member", .hint = "CAST nickname" }, .{ .label = "File or save path", .hint = "Local path" }, .{ .label = "Host / size", .hint = "Address when offering a file" }, .{ .label = "Port / status", .hint = "Listening port, or transfer progress" } },
        .open_conversation => &.{.{ .label = "Conversation file", .hint = "Path to a .ccc file" }},
        .save_conversation => &.{.{ .label = "Conversation file", .hint = "Save as .ccc" }},
        .export_image => &.{.{ .label = "Image file", .hint = "Export as .png" }},
        .open_locator => &.{.{ .label = "Locator file", .hint = "Path to a .ccr file" }},
        .recent_files => &.{ .{ .label = "Recent conversation", .hint = "Most recent path; edit to choose another" }, .{ .label = "Action", .kind = .choice } },
        .favorite_rooms => &.{ .{ .label = "Room", .hint = "#room" }, .{ .label = "Action", .kind = .choice } },
        .print_preview => &.{ .{ .label = "PDF file", .hint = "Save printable preview as .pdf" }, .{ .label = "Action", .kind = .choice } },
        .connection_features => &.{ .{ .label = "Transport", .kind = .readonly }, .{ .label = "Sign-in", .kind = .readonly }, .{ .label = "Room extras", .kind = .readonly }, .{ .label = "Enabled features", .kind = .readonly } },
        .motd => &.{.{ .label = "Bulletin", .hint = "Server supplied", .kind = .readonly }},
        .invitation => &.{ .{ .label = "Room", .hint = "#room" }, .{ .label = "Invitation note", .hint = "Optional" } },
        .about => &.{ .{ .label = "Comic Chat", .hint = "Portable Ink Sunday client", .kind = .readonly }, .{ .label = "License", .hint = "AGPL-3.0-or-later / printed page", .kind = .readonly } },
        .ircx_properties => &.{ .{ .label = "Room", .hint = "Current room by default" }, .{ .label = "Property list", .hint = "Topic, on-join, or other room properties" }, .{ .label = "Value", .hint = "Leave empty to remove" }, .{ .label = "Action", .kind = .choice } },
        .room_access => &.{ .{ .label = "Action", .kind = .choice }, .{ .label = "Level", .kind = .choice }, .{ .label = "Name pattern", .hint = "Name or address pattern, such as *!*@*" }, .{ .label = "Timeout minutes", .hint = "Optional; 0 means unlimited" }, .{ .label = "Reason", .hint = "Optional" } },
        .ircx_events => &.{ .{ .label = "Action", .kind = .choice }, .{ .label = "Event", .hint = "Room, member, server, or connection", .kind = .choice }, .{ .label = "Filter", .hint = "Optional; one word" } },
        .call_link => &.{ .{ .label = "Member", .hint = "CAST nickname" }, .{ .label = "Meeting link", .hint = "https://..." }, .{ .label = "Compatibility", .hint = "Portable secure-link invitation", .kind = .readonly } },
        .member_profile => &.{ .{ .label = "Member", .hint = "Visible CAST member" }, .{ .label = "Result", .hint = "Profile is shown in the conversation", .kind = .readonly } },
    };
}

pub fn acceptsText(id: Id) bool {
    for (fields(id)) |field| if (field.kind == .text or field.kind == .password) return true;
    return false;
}

pub fn fieldAcceptsText(id: Id, index: usize) bool {
    const all = fields(id);
    if (index >= all.len) return false;
    return all[index].kind == .text or all[index].kind == .password;
}

pub fn choiceOptions(id: Id, index: usize) []const []const u8 {
    return switch (id) {
        .setup, .servers => if (index == 2) &.{ "Verified TLS", "Plaintext (unsafe)" } else &.{},
        .settings => switch (index) {
            0 => &.{ "Light studio", "Dark studio" },
            1 => &.{ "Vermillion", "Violet", "Forest" },
            2 => &.{ "Standard", "High contrast" },
            3 => &.{ "Comic", "Text" },
            4 => &.{ "4 panels", "3 panels", "2 panels", "1 panel", "5 panels", "6 panels" },
            5 => &.{ "Shown", "Hidden" },
            6 => &.{ "Icons", "List" },
            7 => &.{ "Detailed", "Compact" },
            else => &.{},
        },
        .character => if (index == 0)
            &.{
                "Anna HD",         "Armando HD",        "Bolo HD",          "Cro HD",        "Dan HD",           "Denise HD",       "Hugh HD",         "Jordan HD",       "Kevin HD",       "Kwensa HD",         "Lance HD",
                "Lynnea HD",       "Margaret HD",       "Maynard HD",       "Mike HD",       "Rebecca HD",       "Sage HD",         "Scotty HD",       "Susan HD",        "Tiki HD",        "Tongtyed HD",       "Xeno HD",
                "Anna Color",      "Armando Color",     "Bolo Color",       "Cro Color",     "Dan Color",        "Denise Color",    "Hugh Color",      "Jordan Color",    "Kevin Color",    "Kwensa Color",      "Lance Color",
                "Lynnea Color",    "Margaret Color",    "Maynard Color",    "Mike Color",    "Rebecca Color",    "Sage Color",      "Scotty Color",    "Susan Color",     "Tiki Color",     "Tongtyed Color",    "Xeno Color",
                "Anna Original",   "Armando Original",  "Bolo Original",    "Cro Original",  "Dan Original",     "Denise Original", "Hugh Original",   "Jordan Original", "Kevin Original", "Kwensa Original",   "Lance Original",
                "Lynnea Original", "Margaret Original", "Maynard Original", "Mike Original", "Rebecca Original", "Sage Original",   "Scotty Original", "Susan Original",  "Tiki Original",  "Tongtyed Original", "Xeno Original",
            }
        else if (index == 1)
            &.{ "Neutral", "Happy", "Laughing", "Angry", "Sad", "Surprised" }
        else
            &.{},
        .background => if (index == 0) &.{
            "Field",                   "Volcano",                  "Den",                        "Room",                    "Pastoral",
            "HD Apartment",            "HD Rooftop",               "HD Cafe",                    "HD Park",                 "HD Space Corridor",
            "HD Boardwalk",            "HD School Hall",           "HD Rainy Street",            "HD Library",              "HD Campsite",
            "Color Apartment",         "Color Rooftop",            "Color Cafe",                 "Color Park",              "Color Space Corridor",
            "Color Boardwalk",         "Color School Hall",        "Color Rainy Street",         "Color Library",           "Color Campsite",
            "Whacky Spaceship Bridge", "Whacky Asteroid Diner",    "Whacky Sky Island Market",   "Whacky Underwater Dome",  "Whacky Friendly Castle",
            "Whacky Pinball Interior", "Whacky Cosmic Laundromat", "Whacky Cloud Train Station", "Whacky Mushroom Village", "Whacky Arcade Planetarium",
        } else &.{},
        .sound => if (index == 0) &.{ "Chime.wav", "Knock.wav", "Laugh.wav", "Applause.wav" } else &.{},
        .set_text_font, .text_font => if (index == 0) &.{ "Comic Neue 14", "Comic Neue 16", "Comic Neue 18" } else &.{ "Regular", "Bold", "Italic" },
        .comics_view => if (index == 0) &.{ "Comic", "Text" } else &.{ "4 panels", "3 panels", "2 panels", "1 panel", "5 panels", "6 panels" },
        .automation => if (index == 0) &.{ "None", "Whisper", "Say" } else &.{},
        .rules, .edit_rule => if (index == 1)
            &.{ "Message", "Whisper", "Join", "Leave", "Kick", "Invitation" }
        else if (index == 3)
            &.{ "Notify", "Reply", "Action", "Sound", "Join room", "Ignore" }
        else
            &.{},
        .notifications => if (index == 4) &.{ "In-app banner", "Sound and banner", "Disabled" } else &.{},
        .file_transfer => if (index == 0) &.{ "Send file", "Receive offer" } else &.{},
        .notification_users => if (index == 2) &.{ "Refresh", "Whisper", "Invite to current room", "Join room", "Clear list" } else &.{},
        .ircx_properties => if (index == 3) &.{ "Read", "Read common properties", "Write", "Remove" } else &.{},
        .room_access => if (index == 0)
            &.{ "Show", "Add", "Remove", "Clear all" }
        else if (index == 1)
            &.{ "Voice", "Host", "Owner", "Grant", "Deny" }
        else
            &.{},
        .ircx_events => if (index == 0)
            &.{ "Show", "Add", "Remove" }
        else if (index == 1)
            &.{ "Room", "Member", "Server", "Connection", "Link" }
        else
            &.{},
        .rule_sets => if (index == 0) &.{ "Create", "Rename", "Assign rule", "Advanced limits", "Advanced matching", "Import", "Export" } else &.{},
        .advanced_rule_settings => if (index == 1 or index == 2) &.{ "Yes", "No" } else &.{},
        .recent_files => if (index == 1) &.{ "Open", "Remove from list" } else &.{},
        .favorite_rooms => if (index == 1) &.{ "Join", "Add current room", "Remove" } else &.{},
        .print_preview => if (index == 1) &.{ "Save PDF", "Save PDF and open", "Save PDF and print" } else &.{},
        else => &.{},
    };
}

pub fn requiresInput(id: Id) bool {
    return switch (id) {
        .about, .motd, .comics_view, .automation, .rules, .rule_sets, .notifications, .notification_users, .servers, .settings, .setup, .room_list, .recent_files, .favorite_rooms, .ircx_properties, .room_access, .ircx_events, .connection_features => false,
        else => true,
    };
}

pub fn primaryLabel(id: Id) []const u8 {
    return switch (id) {
        .setup => "Connect",
        .settings => "Apply settings",
        .servers => "Save changes",
        .personal => "Save profile",
        .character => "Choose character",
        .background => "Choose backdrop",
        .text_font, .set_text_font => "Apply font",
        .choose_color => "Apply color",
        .comics_view => "Apply layout",
        .room_list => "Join room",
        .user_list => "Select CAST",
        .channel => "Join room",
        .channel_create => "Create room",
        .kick => "Kick",
        .ban => "Apply ban",
        .invite => "Invite",
        .whisper => "Whisper",
        .file_transfer => "Start transfer",
        .open_conversation => "Open",
        .save_conversation => "Save",
        .export_image => "Export",
        .open_locator => "Open locator",
        .recent_files => "Open recent",
        .favorite_rooms => "Update favorites",
        .print_preview => "Create PDF",
        .away => "Set away",
        .automation, .rules, .edit_rule, .rule_sets, .add_to_sets, .rename_loaded_set, .rename_set, .create_set, .advanced_event_params, .advanced_rule_settings => "Save rule",
        .notifications, .notification_users => "Save notifications",
        .ircx_properties => "Save properties",
        .room_access => "Save access",
        .ircx_events => "Save events",
        .call_link => "Send call link",
        .member_profile => "Request profile",
        .about, .motd, .connection_features => "Close",
        .nickname => "Set sign-in name",
        .password => "Sign in",
        .channel_password => "Unlock room",
        .invitation => "Accept",
        .channel_properties => "Apply room",
        .sound => "Send",
    };
}

/// Informational surfaces have one unambiguous way out. Editing workflows
/// retain Cancel so their pending values can be dismissed without applying.
pub fn showsCancel(id: Id) bool {
    return switch (id) {
        .about, .motd, .connection_features => false,
        else => true,
    };
}

/// Dialog accent strings are chrome. Persistence stays numeric 0/1/2.
/// Vermillion and leftover "Cobalt" both map to accent 0.
pub fn accentIndex(label: []const u8) u8 {
    if (std.ascii.eqlIgnoreCase(label, "Violet")) return 1;
    if (std.ascii.eqlIgnoreCase(label, "Forest")) return 2;
    return 0;
}

/// Room-access choices are Sunday labels. The ACCESS command still needs
/// the IRCX level token on the wire.
pub fn accessLevelToken(label: []const u8) []const u8 {
    if (std.ascii.eqlIgnoreCase(label, "Voice")) return "VOICE";
    if (std.ascii.eqlIgnoreCase(label, "Host")) return "HOST";
    if (std.ascii.eqlIgnoreCase(label, "Owner")) return "OWNER";
    if (std.ascii.eqlIgnoreCase(label, "Grant")) return "GRANT";
    if (std.ascii.eqlIgnoreCase(label, "Deny")) return "DENY";
    return label;
}

/// Operator-event choices are Sunday labels. EVENT still needs the draft
/// category token on the wire.
pub fn matchesAny(value: []const u8, names: []const []const u8) bool {
    for (names) |name| if (std.ascii.eqlIgnoreCase(value, name)) return true;
    return false;
}

pub fn eventNameToken(label: []const u8) []const u8 {
    if (std.ascii.eqlIgnoreCase(label, "Room") or std.ascii.eqlIgnoreCase(label, "CHANNEL")) return "CHANNEL";
    if (std.ascii.eqlIgnoreCase(label, "Member") or std.ascii.eqlIgnoreCase(label, "MEMBER") or std.ascii.eqlIgnoreCase(label, "USER")) return "MEMBER";
    if (std.ascii.eqlIgnoreCase(label, "Server") or std.ascii.eqlIgnoreCase(label, "SERVER")) return "SERVER";
    if (std.ascii.eqlIgnoreCase(label, "Connection") or std.ascii.eqlIgnoreCase(label, "CONNECTION") or std.ascii.eqlIgnoreCase(label, "CONNECT")) return "CONNECTION";
    if (std.ascii.eqlIgnoreCase(label, "Link") or std.ascii.eqlIgnoreCase(label, "Socket") or std.ascii.eqlIgnoreCase(label, "SOCKET")) return "SOCKET";
    return label;
}

test "registry covers all forty Microsoft dialog templates plus portable dialogs" {
    try std.testing.expectEqual(@as(usize, 53), specs.len);
    try std.testing.expectEqual(@as(usize, 40), microsoft_dialog_count);
    var seen: [specs.len]bool = @splat(false);
    for (specs) |spec| {
        const index = @intFromEnum(spec.id);
        try std.testing.expect(!seen[index]);
        seen[index] = true;
        try std.testing.expectEqual(spec.id, fromResource(spec.resource).?);
    }
}

test "application settings are distinct from connection setup" {
    try std.testing.expectEqual(Group.application, get(.settings).group);
    try std.testing.expectEqualStrings("Color theme", fields(.settings)[0].label);
    try std.testing.expectEqualStrings("Server", fields(.setup)[0].label);
    try std.testing.expectEqualStrings("Light studio", choiceOptions(.settings, 0)[0]);
    try std.testing.expectEqualStrings("Vermillion", choiceOptions(.settings, 1)[0]);
    try std.testing.expectEqualStrings("Verified TLS", choiceOptions(.setup, 2)[0]);
    try std.testing.expectEqualStrings("Page layout", get(.comics_view).title);
    try std.testing.expectEqualStrings("Join room", get(.channel).title);
    try std.testing.expectEqualStrings("Whisper", get(.whisper).title);
    try std.testing.expectEqualStrings("Connection setup", get(.setup).title);
    try std.testing.expectEqualStrings("Sign in", primaryLabel(.password));
    try std.testing.expectEqualStrings("Set sign-in name", primaryLabel(.nickname));
    try std.testing.expectEqualStrings("Sign-in name", get(.nickname).title);
    try std.testing.expectEqualStrings("Sign-in name", fields(.nickname)[0].label);
    try std.testing.expectEqualStrings("Select CAST", primaryLabel(.user_list));
    try std.testing.expectEqualStrings("Send", primaryLabel(.sound));
    try std.testing.expectEqualStrings("Join room", primaryLabel(.channel));
    try std.testing.expectEqualStrings("Save profile", primaryLabel(.personal));
    try std.testing.expectEqualStrings("Set away", primaryLabel(.away));
    try std.testing.expectEqualStrings("Edit rule", get(.edit_rule).title);
    try std.testing.expectEqualStrings("Named properties", get(.ircx_properties).title);
    try std.testing.expectEqualStrings("Online notifications", get(.notifications).title);
    try std.testing.expectEqualStrings("Room events", get(.ircx_events).title);
    try std.testing.expectEqualStrings("Room search", fields(.room_list)[0].label);
    try std.testing.expectEqualStrings("Save properties", primaryLabel(.ircx_properties));
    try std.testing.expectEqualStrings("Save access", primaryLabel(.room_access));
    try std.testing.expectEqualStrings("Save events", primaryLabel(.ircx_events));
    try std.testing.expectEqualStrings("Room extras", fields(.connection_features)[2].label);
    try std.testing.expectEqualStrings("Room", fields(.ircx_properties)[0].label);
    try std.testing.expectEqualStrings("Room options", fields(.channel_create)[2].label);
    try std.testing.expectEqualStrings("Room options", fields(.channel_properties)[1].label);
    try std.testing.expectEqualStrings("CAST member", fields(.whisper)[0].label);
    try std.testing.expectEqualStrings("Account pattern", fields(.notifications)[1].label);
    try std.testing.expectEqualStrings("Address pattern", fields(.notifications)[2].label);
    try std.testing.expectEqualStrings("Voice", choiceOptions(.room_access, 1)[0]);
    try std.testing.expectEqualStrings("Read common properties", choiceOptions(.ircx_properties, 3)[1]);
    try std.testing.expectEqualStrings("Show", choiceOptions(.room_access, 0)[0]);
    try std.testing.expectEqualStrings("Show", choiceOptions(.ircx_events, 0)[0]);
    try std.testing.expectEqualStrings("Ban pattern", fields(.ban)[0].label);
    try std.testing.expectEqualStrings("Host / size", fields(.file_transfer)[3].label);
    try std.testing.expectEqualStrings("Name pattern", fields(.room_access)[2].label);
    try std.testing.expectEqualStrings("Filter", fields(.ircx_events)[2].label);
    try std.testing.expectEqualStrings("Bulletin", get(.motd).title);
    try std.testing.expectEqualStrings("Bulletin", fields(.motd)[0].label);
    try std.testing.expectEqualStrings("Sign-in", fields(.connection_features)[1].label);
    try std.testing.expectEqualStrings("Enabled features", fields(.connection_features)[3].label);
    try std.testing.expectEqualStrings("Away message", get(.away).title);
    try std.testing.expectEqualStrings("Online CAST", get(.notification_users).title);
    try std.testing.expectEqualStrings("Select an online CAST member", fields(.notification_users)[1].hint);
    try std.testing.expectEqualStrings("Rename open set", get(.rename_loaded_set).title);
    try std.testing.expectEqualStrings("Page mode", fields(.comics_view)[0].label);
    try std.testing.expectEqualStrings("Sunday page or conversation", fields(.settings)[3].hint);
    try std.testing.expectEqualStrings("Sunday page or conversation", fields(.comics_view)[0].hint);
    try std.testing.expectEqualStrings("Rule limits", get(.advanced_event_params).title);
    try std.testing.expectEqualStrings("Repeat limit", fields(.automation)[2].label);
    try std.testing.expectEqualStrings("Repeat window seconds", fields(.automation)[3].label);
    try std.testing.expectEqualStrings("Repeat limit", fields(.advanced_event_params)[1].label);
    try std.testing.expectEqualStrings("Repeat window seconds", fields(.advanced_event_params)[2].label);
    try std.testing.expectEqualStrings("Address when offering a file", fields(.file_transfer)[3].hint);
    try std.testing.expectEqualStrings("Room", choiceOptions(.ircx_events, 1)[0]);
    try std.testing.expectEqualStrings("Link", choiceOptions(.ircx_events, 1)[4]);
    try std.testing.expectEqualStrings("Summary", fields(.channel_properties)[4].label);
}

test "room access Sunday labels map back to ACCESS wire tokens" {
    try std.testing.expectEqualStrings("VOICE", accessLevelToken("Voice"));
    try std.testing.expectEqualStrings("HOST", accessLevelToken("host"));
    try std.testing.expectEqualStrings("OWNER", accessLevelToken("OWNER"));
    try std.testing.expectEqualStrings("GRANT", accessLevelToken("Grant"));
    try std.testing.expectEqualStrings("DENY", accessLevelToken("Deny"));
    try std.testing.expectEqualStrings("CUSTOM", accessLevelToken("CUSTOM"));
}

test "operator event Sunday labels map back to EVENT wire tokens" {
    try std.testing.expectEqualStrings("CHANNEL", eventNameToken("Room"));
    try std.testing.expectEqualStrings("MEMBER", eventNameToken("member"));
    try std.testing.expectEqualStrings("SERVER", eventNameToken("SERVER"));
    try std.testing.expectEqualStrings("CONNECTION", eventNameToken("Connection"));
    try std.testing.expectEqualStrings("SOCKET", eventNameToken("Link"));
    try std.testing.expectEqualStrings("SOCKET", eventNameToken("Socket"));
    try std.testing.expectEqualStrings("CUSTOM", eventNameToken("CUSTOM"));
}

test "dialog operations accept Sunday labels and leftover verbs" {
    try std.testing.expect(matchesAny("Show", &.{ "List", "Show" }));
    try std.testing.expect(matchesAny("Read", &.{ "Get", "Read" }));
    try std.testing.expect(matchesAny("Remove", &.{ "Delete", "Remove" }));
    try std.testing.expect(matchesAny("Clear all", &.{ "Clear", "Clear all" }));
    try std.testing.expect(!matchesAny("Add", &.{ "List", "Show" }));
}

test "settings accent chrome maps vermillion and leftover cobalt to index 0" {
    try std.testing.expectEqual(@as(u8, 0), accentIndex("Vermillion"));
    try std.testing.expectEqual(@as(u8, 0), accentIndex("Cobalt"));
    try std.testing.expectEqual(@as(u8, 1), accentIndex("Violet"));
    try std.testing.expectEqual(@as(u8, 2), accentIndex("Forest"));
}

test "informational dialogs use one close action" {
    try std.testing.expect(!showsCancel(.about));
    try std.testing.expect(!showsCancel(.motd));
    try std.testing.expect(!showsCancel(.connection_features));
    try std.testing.expect(showsCancel(.settings));
}
