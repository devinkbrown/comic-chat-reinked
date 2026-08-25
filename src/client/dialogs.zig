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
    .{ .id = .room_list, .resource = "IDD_ROOMLIST", .title = "Browse rooms", .group = .rooms, .source_w = 400, .source_h = 255 },
    .{ .id = .settings, .resource = "IDD_SETTINGSPAGE", .title = "Studio", .group = .application, .source_w = 360, .source_h = 300 },
    .{ .id = .personal, .resource = "IDD_PERSONALPAGE_IRC", .title = "CAST card", .group = .connection, .source_w = 252, .source_h = 218 },
    .{ .id = .character, .resource = "IDD_CHARACTERPAGE", .title = "Choose character", .group = .connection, .source_w = 360, .source_h = 260 },
    .{ .id = .background, .resource = "IDD_BACKGROUNDPAGE", .title = "Backdrop", .group = .connection, .source_w = 252, .source_h = 218 },
    .{ .id = .kick, .resource = "IDD_KICK", .title = "Kick CAST", .group = .rooms, .source_w = 186, .source_h = 89 },
    .{ .id = .nickname, .resource = "IDD_NICKNAME", .title = "Sign-in name", .group = .connection, .source_w = 188, .source_h = 71 },
    .{ .id = .channel, .resource = "IDD_CHANNEL", .title = "Join room", .group = .rooms, .source_w = 144, .source_h = 110 },
    .{ .id = .channel_properties, .resource = "IDD_CHANNELPROP", .title = "Room details", .group = .rooms, .source_w = 186, .source_h = 196 },
    .{ .id = .ban, .resource = "IDD_BAN", .title = "Ban or free", .group = .rooms, .source_w = 186, .source_h = 170 },
    .{ .id = .invite, .resource = "IDD_INVITE", .title = "Invite CAST", .group = .rooms, .source_w = 186, .source_h = 89 },
    .{ .id = .sound, .resource = "IDD_SOUND_DLG", .title = "Send sound", .group = .rooms, .source_w = 188, .source_h = 228 },
    .{ .id = .set_text_font, .resource = "IDD_SETTEXTFONT", .title = "Text font", .group = .connection, .source_w = 264, .source_h = 261 },
    .{ .id = .user_list, .resource = "IDD_USERLIST", .title = "CAST list", .group = .rooms, .source_w = 395, .source_h = 263 },
    .{ .id = .whisper, .resource = "IDD_WHISPERBOX", .title = "Whisper", .group = .rooms, .source_w = 334, .source_h = 196 },
    .{ .id = .comics_view, .resource = "IDD_COMICS_VIEW", .title = "Page layout", .group = .connection, .source_w = 252, .source_h = 218 },
    .{ .id = .automation, .resource = "IDD_AUTOMATION_PAGE", .title = "Greeting", .group = .automation, .source_w = 252, .source_h = 218 },
    .{ .id = .rules, .resource = "IDD_RULESPAGE", .title = "Rule book", .group = .automation, .source_w = 252, .source_h = 218 },
    .{ .id = .edit_rule, .resource = "IDD_EDITRULE", .title = "Change rule", .group = .automation, .source_w = 265, .source_h = 260 },
    .{ .id = .channel_create, .resource = "IDD_CHANNELCREATE", .title = "Create room", .group = .rooms, .source_w = 186, .source_h = 194 },
    .{ .id = .channel_password, .resource = "IDD_CHANPASSWORD", .title = "Room password", .group = .rooms, .source_w = 173, .source_h = 86 },
    .{ .id = .file_transfer, .resource = "IDD_FILE_TRANSFER", .title = "File transfer", .group = .files, .source_w = 300, .source_h = 236 },
    .{ .id = .motd, .resource = "IDD_MOTD", .title = "Bulletin", .group = .rooms, .source_w = 298, .source_h = 146 },
    .{ .id = .setup, .resource = "IDD_SETUPDIALOG", .title = "Wire setup", .group = .connection, .source_w = 252, .source_h = 218 },
    .{ .id = .away, .resource = "IDD_AWAYDLG", .title = "Away message", .group = .rooms, .source_w = 186, .source_h = 87 },
    .{ .id = .text_font, .resource = "IDD_TEXTFONTPAGE_IRC", .title = "Text font", .group = .connection, .source_w = 252, .source_h = 218 },
    .{ .id = .choose_color, .resource = "IDD_CHOOSECOLOR", .title = "Choose ink", .group = .connection, .source_w = 118, .source_h = 38 },
    .{ .id = .invitation, .resource = "IDD_INVITATION", .title = "Room invitation", .group = .rooms, .source_w = 186, .source_h = 93 },
    .{ .id = .advanced_event_params, .resource = "IDD_ADVANCEDEVENTPARAMS", .title = "Rule caps", .group = .automation, .source_w = 186, .source_h = 85 },
    .{ .id = .rule_sets, .resource = "IDD_RULESETSPAGE", .title = "Rule sets", .group = .automation, .source_w = 252, .source_h = 218 },
    .{ .id = .add_to_sets, .resource = "IDD_ADDTOSETS", .title = "Add to rule sets", .group = .automation, .source_w = 252, .source_h = 161 },
    .{ .id = .rename_loaded_set, .resource = "IDD_RENAMELOADEDSET", .title = "Rename open set", .group = .automation, .source_w = 258, .source_h = 103 },
    .{ .id = .rename_set, .resource = "IDD_RENAMESET", .title = "Rename rule set", .group = .automation, .source_w = 226, .source_h = 79 },
    .{ .id = .notifications, .resource = "IDD_NOTIFICATIONS", .title = "Watch CAST", .group = .automation, .source_w = 252, .source_h = 218 },
    .{ .id = .advanced_rule_settings, .resource = "IDD_ADVANCEDRULESETTINGS", .title = "Rule matching", .group = .automation, .source_w = 186, .source_h = 95 },
    .{ .id = .notification_users, .resource = "IDD_NOTIFICATIONUSERS", .title = "Live CAST", .group = .automation, .source_w = 262, .source_h = 111 },
    .{ .id = .servers, .resource = "IDD_SERVERSPAGE", .title = "Wire list", .group = .connection, .source_w = 252, .source_h = 218 },
    .{ .id = .password, .resource = "IDD_PASSWORD", .title = "Sign in", .group = .connection, .source_w = 198, .source_h = 127 },
    .{ .id = .create_set, .resource = "IDD_CREATESET", .title = "Create rule set", .group = .automation, .source_w = 226, .source_h = 79 },
    .{ .id = .open_conversation, .resource = "PORTABLE_OPEN_CONVERSATION", .title = "Open conversation", .group = .files, .source_w = 300, .source_h = 108 },
    .{ .id = .save_conversation, .resource = "PORTABLE_SAVE_CONVERSATION", .title = "Save conversation", .group = .files, .source_w = 300, .source_h = 108 },
    .{ .id = .export_image, .resource = "PORTABLE_EXPORT_IMAGE", .title = "Export Sunday page", .group = .files, .source_w = 300, .source_h = 108 },
    .{ .id = .ircx_properties, .resource = "PORTABLE_IRCX_PROPERTIES", .title = "Named properties", .group = .rooms, .source_w = 300, .source_h = 210 },
    .{ .id = .room_access, .resource = "PORTABLE_ROOM_ACCESS", .title = "Room access", .group = .rooms, .source_w = 300, .source_h = 236 },
    .{ .id = .ircx_events, .resource = "PORTABLE_IRCX_EVENTS", .title = "Room events", .group = .rooms, .source_w = 300, .source_h = 184 },
    .{ .id = .call_link, .resource = "PORTABLE_CALL_LINK", .title = "Send call link", .group = .connection, .source_w = 300, .source_h = 184 },
    .{ .id = .member_profile, .resource = "PORTABLE_MEMBER_PROFILE", .title = "CAST profile", .group = .connection, .source_w = 300, .source_h = 132 },
    .{ .id = .open_locator, .resource = "PORTABLE_OPEN_LOCATOR", .title = "Open locator", .group = .files, .source_w = 300, .source_h = 108 },
    .{ .id = .recent_files, .resource = "PORTABLE_RECENT_FILES", .title = "Recent conversations", .group = .files, .source_w = 340, .source_h = 150 },
    .{ .id = .favorite_rooms, .resource = "PORTABLE_FAVORITE_ROOMS", .title = "Favorite rooms", .group = .rooms, .source_w = 320, .source_h = 184 },
    .{ .id = .print_preview, .resource = "PORTABLE_PRINT_PREVIEW", .title = "Sunday PDF", .group = .files, .source_w = 320, .source_h = 150 },
    .{ .id = .connection_features, .resource = "PORTABLE_CONNECTION_FEATURES", .title = "Wire features", .group = .connection, .source_w = 360, .source_h = 210 },
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
        .password => "Account password",
        .channel_password => "Room password",
        .choose_color => "Ink",
        .sound => "Sound",
        .set_text_font, .text_font => "Font name and size",
        .rename_loaded_set, .rename_set, .create_set => "Rule set name",
        .advanced_event_params => "Rule caps",
        .file_transfer => "File path",
        .open_conversation, .recent_files => "Conversation file",
        .open_locator => "Locator file",
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
        .setup => &.{ .{ .label = "Host", .hint = "Host name or address" }, .{ .label = "Port", .hint = "6697" }, .{ .label = "TLS", .hint = "Verified TLS", .kind = .choice } },
        .servers => &.{ .{ .label = "Wire", .hint = "Live Onyx node", .kind = .choice }, .{ .label = "Port", .hint = "6697" }, .{ .label = "TLS", .hint = "Implicit TLS", .kind = .choice } },
        .settings => &.{
            .{ .label = "Color theme", .hint = "Light or dark studio", .kind = .choice },
            .{ .label = "Accent", .hint = "Vermillion, violet, or forest", .kind = .choice },
            .{ .label = "Contrast", .hint = "Ink weight on chrome", .kind = .choice },
            .{ .label = "Page view", .hint = "Sunday page or conversation", .kind = .choice },
            .{ .label = "Panels across", .hint = "One to six across the page", .kind = .choice },
            .{ .label = "CAST rail", .hint = "CAST rail visibility", .kind = .choice },
            .{ .label = "CAST layout", .hint = "Portraits or compact list", .kind = .choice },
            .{ .label = "Activity", .hint = "Activity panel density", .kind = .choice },
        },
        .personal => &.{ .{ .label = "Profile text", .hint = "Shown on your CAST card" }, .{ .label = "Sign-in name", .hint = "Visible sign-in name" }, .{ .label = "Homepage", .hint = "Optional" }, .{ .label = "Email", .hint = "Optional" } },
        .character => &.{
            .{ .label = "Character", .kind = .choice },
            .{ .label = "Mood", .kind = .choice },
            .{ .label = "Character gallery", .hint = "Previous, selected, and next", .kind = .preview },
        },
        .background => &.{ .{ .label = "Backdrop name", .kind = .choice }, .{ .label = "Preview", .hint = "Bundled background", .kind = .preview } },
        .nickname => &.{.{ .label = "Sign-in name", .hint = "Visible on the Sunday page" }},
        .password => &.{ .{ .label = "Wire account", .hint = "Wire account name" }, .{ .label = "Account password", .hint = "Account password", .kind = .password } },
        .channel => &.{ .{ .label = "Room name", .hint = "#room" }, .{ .label = "Room password", .hint = "If the room is locked", .kind = .password } },
        .channel_create => &.{
            .{ .label = "Room name", .hint = "#room" },
            .{ .label = "Topic", .hint = "Optional" },
            .{ .label = "Room options", .hint = "Optional; one word" },
            .{ .label = "CAST cap", .hint = "Optional" },
            .{ .label = "Room password", .kind = .password },
        },
        .channel_properties => &.{ .{ .label = "Topic", .hint = "Shown on the Sunday page" }, .{ .label = "Room options", .hint = "Optional; one word" }, .{ .label = "CAST cap", .hint = "Optional" }, .{ .label = "Room password", .kind = .password }, .{ .label = "Room note", .hint = "Topic, options and cap", .kind = .readonly } },
        .channel_password => &.{.{ .label = "Room password", .hint = "Needed if the room is locked" }},
        .room_list => &.{ .{ .label = "Room search", .hint = "For example #root or a size filter" }, .{ .label = "Room to join", .hint = "Optional, for example #root" }, .{ .label = "List cap", .hint = "Optional; blank means unlimited" } },
        .user_list => &.{ .{ .label = "CAST member", .hint = "Choose a visible CAST member" }, .{ .label = "Name filter", .hint = "Optional name filter" } },
        .kick => &.{ .{ .label = "CAST member", .hint = "Visible CAST member" }, .{ .label = "Reason", .hint = "Optional" }, .{ .label = "Also ban", .hint = "Optional name pattern" } },
        .ban => &.{.{ .label = "Ban pattern", .hint = "Name pattern, such as nick!*@*" }},
        .invite, .whisper => &.{.{ .label = "CAST member", .hint = "Visible CAST member" }},
        .notification_users => &.{ .{ .label = "On the wire now", .hint = "Watch again to query saved notifications", .kind = .readonly }, .{ .label = "CAST member", .hint = "Choose a live CAST member" }, .{ .label = "CAST how", .kind = .choice }, .{ .label = "Room", .hint = "Join path, for example #root" } },
        .away => &.{.{ .label = "Away message", .hint = "Posted while you are away" }},
        .sound => &.{ .{ .label = "Sound", .kind = .choice }, .{ .label = "With ink", .hint = "Optional" } },
        .set_text_font, .text_font => &.{ .{ .label = "Font name and size", .kind = .choice }, .{ .label = "Style", .hint = "Bold", .kind = .choice } },
        .choose_color => &.{ .{ .label = "Ink", .hint = "#RRGGBB or name" }, .{ .label = "Preview", .hint = "Current ink", .kind = .preview } },
        .comics_view => &.{ .{ .label = "Page view", .hint = "Sunday page or conversation", .kind = .choice }, .{ .label = "Panels across", .hint = "4 panels", .kind = .choice } },
        .automation => &.{ .{ .label = "Greeting how", .kind = .choice }, .{ .label = "Greeting", .hint = "Use %nick% for the arriving CAST" }, .{ .label = "Repeat cap", .hint = "8" }, .{ .label = "Repeat window", .hint = "Seconds" } },
        .rules, .edit_rule => &.{ .{ .label = "Rule name", .hint = "Short label" }, .{ .label = "Event", .kind = .choice }, .{ .label = "Match text", .hint = "Optional text or name pattern" }, .{ .label = "Action", .kind = .choice }, .{ .label = "Action text", .hint = "Message, room or sound" } },
        .rule_sets => &.{ .{ .label = "Set how", .kind = .choice }, .{ .label = "Rule set name" }, .{ .label = "Rule file", .hint = "Optional .ccrules path" } },
        .add_to_sets => &.{ .{ .label = "Rule name" }, .{ .label = "Rule set" } },
        .rename_loaded_set, .rename_set => &.{ .{ .label = "Open set" }, .{ .label = "New set name" } },
        .create_set => &.{.{ .label = "Rule set name" }},
        .advanced_event_params => &.{ .{ .label = "Rule name" }, .{ .label = "Repeat cap", .hint = "0 means unlimited" }, .{ .label = "Repeat window", .hint = "Seconds; 0 means any interval" } },
        .advanced_rule_settings => &.{ .{ .label = "Rule name" }, .{ .label = "Rule on", .kind = .choice }, .{ .label = "Case", .kind = .choice } },
        .notifications => &.{ .{ .label = "Name", .hint = "Name or * pattern" }, .{ .label = "Account pattern", .hint = "*" }, .{ .label = "Address pattern", .hint = "*" }, .{ .label = "Wire", .hint = "Optional wire" }, .{ .label = "Watch how", .kind = .choice } },
        .file_transfer => &.{ .{ .label = "Direction", .kind = .choice }, .{ .label = "CAST member", .hint = "Visible sign-in name" }, .{ .label = "File or save path", .hint = "Local path" }, .{ .label = "Host / size", .hint = "Address when offering a file" }, .{ .label = "Port / status", .hint = "Listening port, or transfer progress" } },
        .open_conversation => &.{.{ .label = "Conversation file", .hint = "Path to a .ccc file" }},
        .save_conversation => &.{.{ .label = "Conversation file", .hint = "Save as .ccc" }},
        .export_image => &.{.{ .label = "Image file", .hint = "Export as .png" }},
        .open_locator => &.{.{ .label = "Locator file", .hint = "Path to a .ccr file" }},
        .recent_files => &.{ .{ .label = "Recent conversation", .hint = "Most recent path; edit to choose another" }, .{ .label = "Open or remove", .kind = .choice } },
        .favorite_rooms => &.{ .{ .label = "Room", .hint = "#room" }, .{ .label = "Join or save", .kind = .choice } },
        .print_preview => &.{ .{ .label = "PDF file", .hint = "Save printable preview as .pdf" }, .{ .label = "After save", .kind = .choice } },
        .connection_features => &.{ .{ .label = "Wire", .kind = .readonly }, .{ .label = "Sign-in", .kind = .readonly }, .{ .label = "Room extras", .kind = .readonly }, .{ .label = "On this wire", .kind = .readonly } },
        .motd => &.{.{ .label = "Bulletin", .hint = "From the wire", .kind = .readonly }},
        .invitation => &.{ .{ .label = "Room", .hint = "#room" }, .{ .label = "Note", .hint = "Optional" } },
        .about => &.{ .{ .label = "Comic Chat", .hint = "Portable Ink Sunday client", .kind = .readonly }, .{ .label = "License", .hint = "AGPL-3.0-or-later / printed page", .kind = .readonly } },
        .ircx_properties => &.{ .{ .label = "Room", .hint = "Current room by default" }, .{ .label = "Property list", .hint = "Topic, greeting, or other room properties" }, .{ .label = "Value", .hint = "Leave empty to remove" }, .{ .label = "Property how", .kind = .choice } },
        .room_access => &.{ .{ .label = "Access how", .kind = .choice }, .{ .label = "Access", .kind = .choice }, .{ .label = "Name pattern", .hint = "Name or address pattern, such as *!*@*" }, .{ .label = "Timeout", .hint = "Minutes; 0 means unlimited" }, .{ .label = "Reason", .hint = "Optional" } },
        .ircx_events => &.{ .{ .label = "Event how", .kind = .choice }, .{ .label = "Event", .hint = "Room, CAST, server, connection, or link", .kind = .choice }, .{ .label = "Event filter", .hint = "Optional; one word" } },
        .call_link => &.{ .{ .label = "CAST member", .hint = "Visible sign-in name" }, .{ .label = "Meeting link", .hint = "https://..." }, .{ .label = "Safe link", .hint = "Portable safe-link invitation", .kind = .readonly } },
        .member_profile => &.{ .{ .label = "CAST member", .hint = "Visible CAST member" }, .{ .label = "Profile", .hint = "Profile is shown in the conversation", .kind = .readonly } },
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
        .setup => if (index == 2) &.{ "Verified TLS", "Plaintext (unsafe)" } else &.{},
        .servers => if (index == 0) &.{ "eshmaki.me", "ircx.us" } else if (index == 2) &.{ "Verified TLS", "Plaintext (unsafe)" } else &.{},
        .settings => switch (index) {
            0 => &.{ "Light studio", "Dark studio" },
            1 => &.{ "Vermillion", "Violet", "Forest" },
            2 => &.{ "Usual", "High contrast" },
            3 => &.{ "Comic", "Text" },
            4 => &.{ "4 panels", "3 panels", "2 panels", "1 panel", "5 panels", "6 panels" },
            5 => &.{ "Shown", "Hidden" },
            6 => &.{ "Portraits", "List" },
            7 => &.{ "Full", "Tight" },
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
        .automation => if (index == 0) &.{ "Off", "Whisper", "Say" } else &.{},
        .rules, .edit_rule => if (index == 1)
            &.{ "Message", "Whisper", "Join", "Leave", "Kick", "Invitation" }
        else if (index == 3)
            &.{ "Notify", "Reply", "Action", "Sound", "Join room", "Ignore" }
        else
            &.{},
        .notifications => if (index == 4) &.{ "Page banner", "Sound and page", "Off" } else &.{},
        .file_transfer => if (index == 0) &.{ "Send file", "Receive offer" } else &.{},
        .notification_users => if (index == 2) &.{ "Watch again", "Whisper", "Invite CAST", "Join room", "Clear" } else &.{},
        .ircx_properties => if (index == 3) &.{ "Read", "Read common", "Write", "Remove" } else &.{},
        .room_access => if (index == 0)
            &.{ "Show", "Add", "Remove", "Clear all" }
        else if (index == 1)
            &.{ "Voice", "Host", "Owner", "Grant", "Deny" }
        else
            &.{},
        .ircx_events => if (index == 0)
            &.{ "Show", "Add", "Remove" }
        else if (index == 1)
            &.{ "Room", "CAST", "Server", "Connection", "Link" }
        else
            &.{},
        .rule_sets => if (index == 0) &.{ "Create", "Rename", "Assign rule", "Rule caps", "Rule matching", "Import", "Export" } else &.{},
        .advanced_rule_settings => if (index == 1 or index == 2) &.{ "On", "Off" } else &.{},
        .recent_files => if (index == 1) &.{ "Open", "Remove" } else &.{},
        .favorite_rooms => if (index == 1) &.{ "Join", "Add this room", "Remove" } else &.{},
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
        .setup => "Open wire",
        .settings => "Save studio",
        .servers => "Open wire",
        .personal => "Save card",
        .character => "Choose character",
        .background => "Choose backdrop",
        .text_font, .set_text_font => "Save font",
        .choose_color => "Save ink",
        .comics_view => "Save layout",
        .room_list => "Join room",
        .user_list => "Choose CAST",
        .channel => "Join room",
        .channel_create => "Create room",
        .kick => "Kick CAST",
        .ban => "Save ban",
        .invite => "Invite CAST",
        .whisper => "Whisper",
        .file_transfer => "Start transfer",
        .open_conversation => "Open conversation",
        .save_conversation => "Save conversation",
        .export_image => "Export Sunday page",
        .open_locator => "Open locator",
        .recent_files => "Open conversation",
        .favorite_rooms => "Save favorites",
        .print_preview => "Save PDF",
        .away => "Save away",
        .automation, .rules, .edit_rule, .advanced_event_params, .advanced_rule_settings => "Save rule",
        .rule_sets => "Save set",
        .add_to_sets => "Add rule",
        .rename_loaded_set, .rename_set => "Rename set",
        .create_set => "Create set",
        .notifications => "Save watch",
        .notification_users => "Use CAST",
        .ircx_properties => "Save properties",
        .room_access => "Save access",
        .ircx_events => "Save events",
        .call_link => "Send call link",
        .member_profile => "Request CAST",
        .about, .motd, .connection_features => "Close",
        .nickname => "Save sign-in name",
        .password => "Sign in",
        .channel_password => "Unlock room",
        .invitation => "Accept invitation",
        .channel_properties => "Save room",
        .sound => "Send sound",
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
/// category token on the wire. Visible CAST maps to MEMBER; leftover
/// Member/USER labels still map so saved choices keep working.
pub fn matchesAny(value: []const u8, names: []const []const u8) bool {
    for (names) |name| if (std.ascii.eqlIgnoreCase(value, name)) return true;
    return false;
}

pub fn eventNameToken(label: []const u8) []const u8 {
    if (std.ascii.eqlIgnoreCase(label, "Room") or std.ascii.eqlIgnoreCase(label, "CHANNEL")) return "CHANNEL";
    if (std.ascii.eqlIgnoreCase(label, "CAST") or std.ascii.eqlIgnoreCase(label, "Member") or std.ascii.eqlIgnoreCase(label, "MEMBER") or std.ascii.eqlIgnoreCase(label, "USER")) return "MEMBER";
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
    try std.testing.expectEqualStrings("Host", fields(.setup)[0].label);
    try std.testing.expectEqualStrings("Light studio", choiceOptions(.settings, 0)[0]);
    try std.testing.expectEqualStrings("Vermillion", choiceOptions(.settings, 1)[0]);
    try std.testing.expectEqualStrings("Portraits", choiceOptions(.settings, 6)[0]);
    try std.testing.expectEqualStrings("Verified TLS", choiceOptions(.setup, 2)[0]);
    try std.testing.expectEqualStrings("Page layout", get(.comics_view).title);
    try std.testing.expectEqualStrings("Join room", get(.channel).title);
    try std.testing.expectEqualStrings("Whisper", get(.whisper).title);
    try std.testing.expectEqualStrings("Wire setup", get(.setup).title);
    try std.testing.expectEqualStrings("Wire features", get(.connection_features).title);
    try std.testing.expectEqualStrings("Open wire", primaryLabel(.setup));
    try std.testing.expectEqualStrings("Save ban", primaryLabel(.ban));
    try std.testing.expectEqualStrings("Save room", primaryLabel(.channel_properties));
    try std.testing.expectEqualStrings("Room details", get(.channel_properties).title);
    try std.testing.expectEqualStrings("Choose ink", get(.choose_color).title);
    try std.testing.expectEqualStrings("Room invitation", get(.invitation).title);
    try std.testing.expectEqualStrings("Invite CAST", choiceOptions(.notification_users, 2)[2]);
    try std.testing.expectEqualStrings("Sign in", primaryLabel(.password));
    try std.testing.expectEqualStrings("Sign in", get(.password).title);
    try std.testing.expectEqualStrings("Backdrop", get(.background).title);
    try std.testing.expectEqualStrings("Export Sunday page", get(.export_image).title);
    try std.testing.expectEqualStrings("Locator file", prompt(.open_locator).?);
    try std.testing.expectEqualStrings("Save sign-in name", primaryLabel(.nickname));
    try std.testing.expectEqualStrings("Sign-in name", get(.nickname).title);
    try std.testing.expectEqualStrings("Sign-in name", fields(.nickname)[0].label);
    try std.testing.expectEqualStrings("Choose CAST", primaryLabel(.user_list));
    try std.testing.expectEqualStrings("Send sound", primaryLabel(.sound));
    try std.testing.expectEqualStrings("Open conversation", primaryLabel(.open_conversation));
    try std.testing.expectEqualStrings("Save conversation", primaryLabel(.save_conversation));
    try std.testing.expectEqualStrings("Export Sunday page", primaryLabel(.export_image));
    try std.testing.expectEqualStrings("Page view", fields(.settings)[3].label);
    try std.testing.expectEqualStrings("TLS", fields(.setup)[2].label);
    try std.testing.expectEqualStrings("Sign-in name", fields(.personal)[1].label);
    try std.testing.expectEqualStrings("Homepage", fields(.personal)[2].label);
    try std.testing.expectEqualStrings("Email", fields(.personal)[3].label);
    try std.testing.expectEqualStrings("Profile", fields(.member_profile)[1].label);
    try std.testing.expectEqualStrings("Remove", choiceOptions(.recent_files, 1)[1]);
    try std.testing.expectEqualStrings("Open or remove", fields(.recent_files)[1].label);
    try std.testing.expectEqualStrings("Join or save", fields(.favorite_rooms)[1].label);
    try std.testing.expectEqualStrings("After save", fields(.print_preview)[1].label);
    try std.testing.expectEqualStrings("CAST how", fields(.notification_users)[2].label);
    try std.testing.expectEqualStrings("Current ink", fields(.choose_color)[1].hint);
    try std.testing.expectEqualStrings("Wire account name", fields(.password)[0].hint);
    try std.testing.expectEqualStrings("From the wire", fields(.motd)[0].hint);
    try std.testing.expectEqualStrings("Optional wire", fields(.notifications)[3].hint);
    try std.testing.expectEqualStrings("Join room", primaryLabel(.channel));
    try std.testing.expectEqualStrings("Save card", primaryLabel(.personal));
    try std.testing.expectEqualStrings("CAST card", get(.personal).title);
    try std.testing.expectEqualStrings("Open locator", get(.open_locator).title);
    try std.testing.expectEqualStrings("CAST", choiceOptions(.ircx_events, 1)[1]);
    try std.testing.expectEqualStrings("Room, CAST, server, connection, or link", fields(.ircx_events)[1].hint);
    try std.testing.expectEqualStrings("Use %nick% for the arriving CAST", fields(.automation)[1].hint);
    try std.testing.expectEqualStrings("Save away", primaryLabel(.away));
    try std.testing.expectEqualStrings("Save studio", primaryLabel(.settings));
    try std.testing.expectEqualStrings("Save ink", primaryLabel(.choose_color));
    try std.testing.expectEqualStrings("Kick CAST", primaryLabel(.kick));
    try std.testing.expectEqualStrings("Invite CAST", primaryLabel(.invite));
    try std.testing.expectEqualStrings("Request CAST", primaryLabel(.member_profile));
    try std.testing.expectEqualStrings("Wire list", get(.servers).title);
    try std.testing.expectEqualStrings("Open wire", primaryLabel(.servers));
    try std.testing.expectEqualStrings("Accept invitation", primaryLabel(.invitation));
    try std.testing.expectEqualStrings("Open conversation", primaryLabel(.recent_files));
    try std.testing.expectEqualStrings("Save favorites", primaryLabel(.favorite_rooms));
    try std.testing.expectEqualStrings("Save PDF", primaryLabel(.print_preview));
    try std.testing.expectEqualStrings("Sunday PDF", get(.print_preview).title);
    try std.testing.expectEqualStrings("Accent", fields(.settings)[1].label);
    try std.testing.expectEqualStrings("Color theme", fields(.settings)[0].label);
    try std.testing.expectEqualStrings("Ink", fields(.choose_color)[0].label);
    try std.testing.expectEqualStrings("Change rule", get(.edit_rule).title);
    try std.testing.expectEqualStrings("Rule book", get(.rules).title);
    try std.testing.expectEqualStrings("Named properties", get(.ircx_properties).title);
    try std.testing.expectEqualStrings("Watch CAST", get(.notifications).title);
    try std.testing.expectEqualStrings("Room events", get(.ircx_events).title);
    try std.testing.expectEqualStrings("Room search", fields(.room_list)[0].label);
    try std.testing.expectEqualStrings("Save properties", primaryLabel(.ircx_properties));
    try std.testing.expectEqualStrings("Save access", primaryLabel(.room_access));
    try std.testing.expectEqualStrings("Save events", primaryLabel(.ircx_events));
    try std.testing.expectEqualStrings("Room extras", fields(.connection_features)[2].label);
    try std.testing.expectEqualStrings("Room", fields(.ircx_properties)[0].label);
    try std.testing.expectEqualStrings("Room options", fields(.channel_create)[2].label);
    try std.testing.expectEqualStrings("Room options", fields(.channel_properties)[1].label);
    try std.testing.expectEqualStrings("CAST rail", fields(.settings)[5].label);
    try std.testing.expectEqualStrings("CAST layout", fields(.settings)[6].label);
    try std.testing.expectEqualStrings("Activity", fields(.settings)[7].label);
    try std.testing.expectEqualStrings("Full", choiceOptions(.settings, 7)[0]);
    try std.testing.expectEqualStrings("Wire list", get(.servers).title);
    try std.testing.expectEqualStrings("CAST profile", get(.member_profile).title);
    try std.testing.expectEqualStrings("Kick CAST", get(.kick).title);
    try std.testing.expectEqualStrings("Invite CAST", get(.invite).title);
    try std.testing.expectEqualStrings("CAST cap", fields(.channel_create)[3].label);
    try std.testing.expectEqualStrings("CAST cap", fields(.channel_properties)[2].label);
    try std.testing.expectEqualStrings("CAST member", fields(.whisper)[0].label);
    try std.testing.expectEqualStrings("CAST member", fields(.file_transfer)[1].label);
    try std.testing.expectEqualStrings("CAST member", fields(.call_link)[0].label);
    try std.testing.expectEqualStrings("CAST member", fields(.member_profile)[0].label);
    try std.testing.expectEqualStrings("Visible sign-in name", fields(.file_transfer)[1].hint);
    try std.testing.expectEqualStrings("Topic, greeting, or other room properties", fields(.ircx_properties)[1].hint);
    try std.testing.expectEqualStrings("Account pattern", fields(.notifications)[1].label);
    try std.testing.expectEqualStrings("Address pattern", fields(.notifications)[2].label);
    try std.testing.expectEqualStrings("Browse rooms", get(.room_list).title);
    try std.testing.expectEqualStrings("Ban or free", get(.ban).title);
    try std.testing.expectEqualStrings("Send call link", get(.call_link).title);
    try std.testing.expectEqualStrings("Voice", choiceOptions(.room_access, 1)[0]);
    try std.testing.expectEqualStrings("Read common", choiceOptions(.ircx_properties, 3)[1]);
    try std.testing.expectEqualStrings("Show", choiceOptions(.room_access, 0)[0]);
    try std.testing.expectEqualStrings("Show", choiceOptions(.ircx_events, 0)[0]);
    try std.testing.expectEqualStrings("Ban pattern", fields(.ban)[0].label);
    try std.testing.expectEqualStrings("Host / size", fields(.file_transfer)[3].label);
    try std.testing.expectEqualStrings("Name pattern", fields(.room_access)[2].label);
    try std.testing.expectEqualStrings("Event filter", fields(.ircx_events)[2].label);
    try std.testing.expectEqualStrings("Bulletin", get(.motd).title);
    try std.testing.expectEqualStrings("Bulletin", fields(.motd)[0].label);
    try std.testing.expectEqualStrings("Sign-in", fields(.connection_features)[1].label);
    try std.testing.expectEqualStrings("On this wire", fields(.connection_features)[3].label);
    try std.testing.expectEqualStrings("Wire", fields(.connection_features)[0].label);
    try std.testing.expectEqualStrings("Mood", fields(.character)[1].label);
    try std.testing.expectEqualStrings("Room password", fields(.channel)[1].label);
    try std.testing.expectEqualStrings("List cap", fields(.room_list)[2].label);
    try std.testing.expectEqualStrings("Wire", fields(.notifications)[3].label);
    try std.testing.expectEqualStrings("Watch how", fields(.notifications)[4].label);
    try std.testing.expectEqualStrings("Safe link", fields(.call_link)[2].label);
    try std.testing.expectEqualStrings("Rule caps", choiceOptions(.rule_sets, 0)[3]);
    try std.testing.expectEqualStrings("Rule matching", choiceOptions(.rule_sets, 0)[4]);
    try std.testing.expectEqualStrings("Add this room", choiceOptions(.favorite_rooms, 1)[1]);
    try std.testing.expectEqualStrings("Page banner", choiceOptions(.notifications, 4)[0]);
    try std.testing.expectEqualStrings("Away message", get(.away).title);
    try std.testing.expectEqualStrings("Live CAST", get(.notification_users).title);
    try std.testing.expectEqualStrings("Choose a live CAST member", fields(.notification_users)[1].hint);
    try std.testing.expectEqualStrings("On the wire now", fields(.notification_users)[0].label);
    try std.testing.expectEqualStrings("Rename open set", get(.rename_loaded_set).title);
    try std.testing.expectEqualStrings("Page view", fields(.comics_view)[0].label);
    try std.testing.expectEqualStrings("Sunday page or conversation", fields(.settings)[3].hint);
    try std.testing.expectEqualStrings("Sunday page or conversation", fields(.comics_view)[0].hint);
    try std.testing.expectEqualStrings("Rule caps", get(.advanced_event_params).title);
    try std.testing.expectEqualStrings("Repeat cap", fields(.automation)[2].label);
    try std.testing.expectEqualStrings("Repeat window", fields(.automation)[3].label);
    try std.testing.expectEqualStrings("Seconds", fields(.automation)[3].hint);
    try std.testing.expectEqualStrings("Repeat cap", fields(.advanced_event_params)[1].label);
    try std.testing.expectEqualStrings("Repeat window", fields(.advanced_event_params)[2].label);
    try std.testing.expectEqualStrings("Wire account", fields(.password)[0].label);
    try std.testing.expectEqualStrings("Greeting how", fields(.automation)[0].label);
    try std.testing.expectEqualStrings("Match text", fields(.rules)[2].label);
    try std.testing.expectEqualStrings("Action text", fields(.rules)[4].label);
    try std.testing.expectEqualStrings("Action", fields(.rules)[3].label);
    try std.testing.expectEqualStrings("Rule file", fields(.rule_sets)[2].label);
    try std.testing.expectEqualStrings("Open set", fields(.rename_set)[0].label);
    try std.testing.expectEqualStrings("New set name", fields(.rename_set)[1].label);
    try std.testing.expectEqualStrings("Access", fields(.room_access)[1].label);
    try std.testing.expectEqualStrings("Sound", fields(.sound)[0].label);
    try std.testing.expectEqualStrings("Chime.wav", choiceOptions(.sound, 0)[0]);
    try std.testing.expectEqualStrings("Account password", fields(.password)[1].label);
    try std.testing.expectEqualStrings("Also ban", fields(.kick)[2].label);
    try std.testing.expectEqualStrings("Name filter", fields(.user_list)[1].label);
    try std.testing.expectEqualStrings("Note", fields(.invitation)[1].label);
    try std.testing.expectEqualStrings("Rule on", fields(.advanced_rule_settings)[1].label);
    try std.testing.expectEqualStrings("Case", fields(.advanced_rule_settings)[2].label);
    try std.testing.expectEqualStrings("Studio", get(.settings).title);
    try std.testing.expectEqualStrings("Greeting", get(.automation).title);
    try std.testing.expectEqualStrings("Rule matching", get(.advanced_rule_settings).title);
    try std.testing.expectEqualStrings("Ink", prompt(.choose_color).?);
    try std.testing.expectEqualStrings("Timeout", fields(.room_access)[3].label);
    try std.testing.expectEqualStrings("With ink", fields(.sound)[1].label);
    try std.testing.expectEqualStrings("Save set", primaryLabel(.rule_sets));
    try std.testing.expectEqualStrings("Use CAST", primaryLabel(.notification_users));
    try std.testing.expectEqualStrings("Add rule", primaryLabel(.add_to_sets));
    try std.testing.expectEqualStrings("Rename set", primaryLabel(.rename_set));
    try std.testing.expectEqualStrings("Create set", primaryLabel(.create_set));
    try std.testing.expectEqualStrings("Save rule", primaryLabel(.rules));
    try std.testing.expectEqualStrings("Save watch", primaryLabel(.notifications));
    try std.testing.expectEqualStrings("Address when offering a file", fields(.file_transfer)[3].hint);
    try std.testing.expectEqualStrings("Room", choiceOptions(.ircx_events, 1)[0]);
    try std.testing.expectEqualStrings("Link", choiceOptions(.ircx_events, 1)[4]);
    try std.testing.expectEqualStrings("Room note", fields(.channel_properties)[4].label);
    try std.testing.expectEqualStrings("Wire", fields(.servers)[0].label);
    try std.testing.expectEqualStrings("Live Onyx node", fields(.servers)[0].hint);
    try std.testing.expectEqualStrings("Implicit TLS", fields(.servers)[2].hint);
    try std.testing.expectEqualStrings("eshmaki.me", choiceOptions(.servers, 0)[0]);
    try std.testing.expectEqualStrings("ircx.us", choiceOptions(.servers, 0)[1]);
    try std.testing.expectEqualStrings("Verified TLS", choiceOptions(.servers, 2)[0]);
    try std.testing.expectEqualStrings("Host", fields(.setup)[0].label);
    try std.testing.expectEqualStrings("Set how", fields(.rule_sets)[0].label);
    try std.testing.expectEqualStrings("Property how", fields(.ircx_properties)[3].label);
    try std.testing.expectEqualStrings("Access how", fields(.room_access)[0].label);
    try std.testing.expectEqualStrings("Event how", fields(.ircx_events)[0].label);
    try std.testing.expectEqualStrings("Action", fields(.rules)[3].label);
    try std.testing.expectEqualStrings("Account password", prompt(.password).?);
    try std.testing.expectEqualStrings("Room password", prompt(.channel_password).?);
    try std.testing.expectEqualStrings("Sound", prompt(.sound).?);
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
    try std.testing.expectEqualStrings("MEMBER", eventNameToken("CAST"));
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
    try std.testing.expect(matchesAny("Remove from list", &.{ "Remove", "Remove from list" }));
    try std.testing.expect(matchesAny("Advanced limits", &.{ "Rule caps", "Rule limits", "Advanced limits" }));
    try std.testing.expect(matchesAny("Add current room", &.{ "Add this room", "Add current room" }));
    try std.testing.expect(matchesAny("Clear all", &.{ "Clear", "Clear all" }));
    try std.testing.expect(matchesAny("Also ban pattern", &.{ "Also ban", "Also ban pattern" }));
    try std.testing.expect(matchesAny("Repeat window seconds", &.{ "Repeat window", "Repeat window seconds" }));
    try std.testing.expect(matchesAny("Save rule", &.{ "Save set", "Apply set", "Add rule", "Save rule" }));
    try std.testing.expect(matchesAny("Save notifications", &.{ "Save watch", "Use CAST", "Apply CAST", "Save notifications" }));
    try std.testing.expect(matchesAny("Rules", &.{ "Rule book", "Rules" }));
    try std.testing.expect(matchesAny("Edit rule", &.{ "Change rule", "Edit rule" }));
    try std.testing.expect(matchesAny("Summary", &.{ "Room note", "Summary" }));
    try std.testing.expect(matchesAny("Copy lines", &.{ "Copy ink", "Copy lines" }));
    try std.testing.expect(matchesAny("Insert page break", &.{ "Insert page fold", "Insert page break" }));
    try std.testing.expect(matchesAny("Delete lines", &.{ "Clear ink", "Delete lines" }));
    try std.testing.expect(matchesAny("Open room separately", &.{ "Open room aside", "Open room separately" }));
    try std.testing.expect(matchesAny("File", &.{ "Page", "File" }));
    try std.testing.expect(matchesAny("Edit", &.{ "Ink", "Edit" }));
    try std.testing.expect(matchesAny("View", &.{ "Show", "View" }));
    try std.testing.expect(matchesAny("Invitation note", &.{ "Note", "Invitation note" }));
    try std.testing.expect(matchesAny("Name filter", &.{ "Filter", "Name filter" }));
    try std.testing.expect(matchesAny("Greeting mode", &.{ "Greeting how", "Greeting mode" }));
    try std.testing.expect(matchesAny("Repeat limit", &.{ "Repeat cap", "Repeat limit" }));
    try std.testing.expect(matchesAny("Action value", &.{ "Action text", "Action value" }));
    try std.testing.expect(matchesAny("Level", &.{ "Access", "Level" }));
    try std.testing.expect(matchesAny("Page mode", &.{ "Page view", "Page mode" }));
    try std.testing.expect(matchesAny("Sound file", &.{ "Sound", "Sound file" }));
    try std.testing.expect(matchesAny("Import or export file", &.{ "Rule file", "Import or export file" }));
    try std.testing.expect(matchesAny("Current rule set", &.{ "Open set", "Current rule set" }));
    try std.testing.expect(matchesAny("New name", &.{ "New set name", "New name" }));
    try std.testing.expect(matchesAny("Account", &.{ "Wire account", "Account" }));
    try std.testing.expect(matchesAny("Sound name", &.{ "Sound", "Sound name" }));
    try std.testing.expect(matchesAny("Connect before browsing rooms.", &.{ "Connect first to browse rooms.", "Connect before browsing rooms." }));
    try std.testing.expect(matchesAny("Settings", &.{ "Studio", "Settings" }));
    try std.testing.expect(matchesAny("Save settings", &.{ "Save studio", "Save settings" }));
    try std.testing.expect(matchesAny("Automation", &.{ "Greeting", "Automation" }));
    try std.testing.expect(matchesAny("Rule settings", &.{ "Rule matching", "Rule settings" }));
    try std.testing.expect(matchesAny("Ink value", &.{ "Ink", "Ink value" }));
    try std.testing.expect(matchesAny("List limit", &.{ "List cap", "List limit" }));
    try std.testing.expect(matchesAny("Fill the first field before continuing.", &.{ "Fill the first field first.", "Fill the first field before continuing." }));
    try std.testing.expect(matchesAny("Online notifications", &.{ "Watch CAST", "Online notifications" }));
    try std.testing.expect(matchesAny("Online CAST", &.{ "Live CAST", "Online CAST" }));
    try std.testing.expect(matchesAny("Online now", &.{ "On the wire now", "Online now" }));
    try std.testing.expect(matchesAny("CAST limit", &.{ "CAST cap", "CAST limit" }));
    try std.testing.expect(matchesAny("Rule limits", &.{ "Rule caps", "Rule limits" }));
    try std.testing.expect(matchesAny("Choose a valid sound name.", &.{ "Choose a valid sound.", "Choose a valid sound name." }));
    try std.testing.expect(matchesAny("Quit", &.{ "Close Comic Chat", "Quit" }));
    try std.testing.expect(matchesAny("Bold selection", &.{ "Bold ink", "Bold selection" }));
    try std.testing.expect(matchesAny("Italic selection", &.{ "Italic ink", "Italic selection" }));
    try std.testing.expect(matchesAny("Underline selection", &.{ "Underline ink", "Underline selection" }));
    try std.testing.expect(matchesAny("Freeze expression", &.{ "Hold expression", "Freeze expression" }));
    try std.testing.expect(matchesAny("Unfreeze expression", &.{ "Release expression", "Unfreeze expression" }));
    try std.testing.expect(matchesAny("Return to neutral", &.{ "Neutral expression", "Return to neutral" }));
    try std.testing.expect(matchesAny("Change character", &.{ "Choose character", "Change character" }));
    try std.testing.expect(matchesAny("Choose file", &.{ "Pick path", "Choose file" }));
    try std.testing.expect(matchesAny("Expression", &.{ "Mood", "Expression" }));
    try std.testing.expect(matchesAny("Notice", &.{ "Watch how", "Notice" }));
    try std.testing.expect(matchesAny("With balloon", &.{ "With ink", "With balloon" }));
    try std.testing.expect(matchesAny("Give the rule a name.", &.{ "Name the rule.", "Give the rule a name." }));
    try std.testing.expect(matchesAny("The saved notification rules will be queried now.", &.{ "Watch CAST will query the wire now.", "The saved notification rules will be queried now." }));
    try std.testing.expect(matchesAny("Ban or release", &.{ "Ban or free", "Ban or release" }));
    try std.testing.expect(matchesAny("Standard", &.{ "Usual", "Standard" }));
    try std.testing.expect(matchesAny("Secure link", &.{ "Safe link", "Secure link" }));
    try std.testing.expect(matchesAny("Save how", &.{ "After save", "Save how" }));
    try std.testing.expect(matchesAny("None", &.{ "Off", "None" }));
    try std.testing.expect(matchesAny("Disabled", &.{ "Off", "Disabled" }));
    try std.testing.expect(matchesAny("The room could not open on its own.", &.{ "The room could not open aside.", "The room could not open on its own." }));
    try std.testing.expect(matchesAny("None yet", &.{ "None on this wire yet", "None yet" }));
    try std.testing.expect(matchesAny("Icons", &.{ "Portraits", "Icons" }));
    try std.testing.expect(matchesAny("CAST icons", &.{ "CAST portraits", "CAST icons" }));
    try std.testing.expect(matchesAny("CAST pane", &.{ "CAST rail", "CAST pane" }));
    try std.testing.expect(matchesAny("Match case", &.{ "Case", "Match case" }));
    try std.testing.expect(matchesAny("In-app banner", &.{ "Page banner", "In-app banner" }));
    try std.testing.expect(matchesAny("Sound and banner", &.{ "Sound and page", "Sound and banner" }));
    try std.testing.expect(matchesAny("Apply set", &.{ "Save set", "Apply set" }));
    try std.testing.expect(matchesAny("Apply CAST", &.{ "Use CAST", "Apply CAST" }));
    try std.testing.expect(matchesAny("Read common properties", &.{ "Read common", "Read common properties" }));
    try std.testing.expect(matchesAny("Get common properties", &.{ "Read common", "Get common properties", "Read common properties" }));
    try std.testing.expect(matchesAny("Yes", &.{ "On", "Yes" }));
    try std.testing.expect(matchesAny("No", &.{ "Off", "No" }));
    try std.testing.expect(matchesAny("Detailed", &.{ "Full", "Detailed" }));
    try std.testing.expect(matchesAny("Compact", &.{ "Tight", "Compact" }));
    try std.testing.expect(matchesAny("Status details", &.{ "Activity", "Status details" }));
    try std.testing.expect(matchesAny("Property action", &.{ "Property how", "Property action" }));
    try std.testing.expect(matchesAny("Access action", &.{ "Access how", "Access action" }));
    try std.testing.expect(matchesAny("Event action", &.{ "Event how", "Event action" }));
    try std.testing.expect(matchesAny("CAST action", &.{ "CAST how", "CAST action" }));
    try std.testing.expect(matchesAny("Set action", &.{ "Set how", "Set action" }));
    try std.testing.expect(matchesAny("Refresh", &.{ "Watch again", "Refresh" }));
    try std.testing.expect(matchesAny("Clear list", &.{ "Clear", "Clear list" }));
    try std.testing.expect(matchesAny("CAST actions", &.{ "CAST menu", "CAST actions" }));
    try std.testing.expect(matchesAny("Figure actions", &.{ "Figure menu", "Figure actions" }));
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
