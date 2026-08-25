//! IRCX client-data key strings and property-change diffing.
//!
//! Ports the pinned Microsoft Comic Chat source's semicolon-delimited
//! `key=value` mini-format and its pure client-data update logic:
//! - `protsupp.cpp:5062-5127`: the format contract and `FindInKeyString`'s
//!   position-based scanner, including quote-aware semicolon skipping.
//! - `protsupp.cpp:5133-5184`: `ChangeKeyString` removal/reappend mutation,
//!   literal-quote rejection, conditional quoting, and maximum-size check.
//! - `protsupp.cpp:5189-5236`: `GetValueFromKeyString` and its observable
//!   trailing-semicolon/surrounding-quote trimming.
//! - `protsupp.cpp:5241-5262`: `EnumKeyString`, represented here by an
//!   allocation-free Zig iterator whose returned slices borrow the input.
//! - `ircproto.cpp:737-767`: `CIrcProto::HandleClientDataChange`'s exact
//!   two-pass new-then-old property diff.
//! - `ircproto.cpp:1389-1404`: the pure mutate portion of `ChangeProperty`.
//!
//! As elsewhere in this portable tree (notably `proto/dcc.zig`'s CTCP
//! quoting port), byte offsets and delimiters are handled as ASCII/UTF-8
//! bytes rather than reproducing the source's MBCS helper calls. Values may
//! be surrounded by one pair of quotes to protect `=` and `;`; quotes are
//! not an escape syntax, and `ChangeKeyString` rejects a literal `"` in a
//! value exactly as `protsupp.cpp:5159-5161` does.
//!
//! Explicitly out of scope: `ChangeProperty`'s `IsIRCX`/room-owner gate and
//! `ChatSetClientData` live PROP send (`ircproto.cpp:1395-1404`), plus the
//! `CCQuery`/`CQueryPtrList` query-correlation plumbing in `query.cpp` and
//! `query.h`. This module returns generic `{ key, ?value }` changes instead
//! of performing I/O. `OnPropertyChange` recognizes `bk` as a backdrop
//! (`protsupp.cpp:3455-3470`); live 818/PROP CLIENT replies feed that key
//! into `Transcript.setBackdrop` for bundled names only.

const std = @import("std");

/// One decoded key-string pair. Both slices borrow from the iterator's input.
pub const Pair = struct {
    key: []const u8,
    value: []const u8,
};

const Match = struct {
    key_pos: usize,
    value_pos: usize,
    value_end: usize,
    /// Start of the following pair in the original slice, or null when this
    /// is the last pair. This is `pnNextValPos == -1` in
    /// `FindInKeyString` (protsupp.cpp:5123-5125).
    next_pair_pos: ?usize,
};

/// `FindInKeyString` (protsupp.cpp:5072-5127). `wanted_key == null` is the
/// source's enumeration mode and selects the first pair. Positions stay
/// relative to `key_string`, including after skipped pairs, so callers can
/// reproduce `ChangeKeyString`'s exact position-based splice.
fn findInKeyString(key_string: []const u8, wanted_key: ?[]const u8) ?Match {
    var pair_start: usize = 0;
    while (pair_start < key_string.len) {
        // OurMbsChr(..., '=') at protsupp.cpp:5093/5107. The portable tree
        // deliberately treats the wire blob as bytes rather than MBCS.
        const equals_rel = std.mem.indexOfScalar(u8, key_string[pair_start..], '=') orelse return null;
        const equals = pair_start + equals_rel;

        const found = if (wanted_key) |key|
            std.mem.eql(u8, key_string[pair_start..equals], key)
        else
            true;

        // The critical source rule at protsupp.cpp:5110-5117: only a quote
        // immediately after '=' changes delimiter scanning. If present and
        // closed, semicolon search begins after that closing quote, so an
        // embedded semicolon remains part of the value. An unclosed opening
        // quote consumes the remainder, matching psz becoming NULL.
        const value_pos = equals + 1;
        var separator_search = value_pos;
        if (separator_search < key_string.len and key_string[separator_search] == '"') {
            const closing_rel = std.mem.indexOfScalar(u8, key_string[separator_search + 1 ..], '"') orelse {
                if (found) {
                    return .{
                        .key_pos = pair_start,
                        .value_pos = value_pos,
                        .value_end = key_string.len,
                        .next_pair_pos = null,
                    };
                }
                return null;
            };
            separator_search += 1 + closing_rel + 1;
        }

        const separator = if (separator_search < key_string.len)
            if (std.mem.indexOfScalar(u8, key_string[separator_search..], ';')) |rel|
                separator_search + rel
            else
                null
        else
            null;
        const next_pair_pos = if (separator) |at|
            if (at + 1 < key_string.len) at + 1 else null
        else
            null;

        if (found) {
            return .{
                .key_pos = pair_start,
                .value_pos = value_pos,
                // `GetValueFromKeyString` receives the separator and trims
                // it only when it is the last byte (protsupp.cpp:5217-5225).
                // Slicing before it is the same observable value for valid
                // key strings and also handles a single trailing separator.
                .value_end = separator orelse key_string.len,
                .next_pair_pos = next_pair_pos,
            };
        }

        pair_start = next_pair_pos orelse return null;
    }
    return null;
}

/// `GetValueFromKeyString` (protsupp.cpp:5189-5236). The result borrows from
/// `key_string`; null means the key was absent. A single surrounding quote
/// pair is removed only when the first and last value bytes are both quotes
/// (`protsupp.cpp:5227-5232`).
pub fn getValue(key_string: []const u8, key: []const u8) ?[]const u8 {
    const found = findInKeyString(key_string, key) orelse return null;
    var value = key_string[found.value_pos..found.value_end];
    if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"')
        value = value[1 .. value.len - 1];
    return value;
}

/// Allocation-free idiomatic equivalent of `EnumKeyString`'s advancing
/// `LPCSTR&` (protsupp.cpp:5241-5262). Each returned pair borrows from the
/// input passed to `init` and remains valid as long as that input does.
pub const Iterator = struct {
    remaining: []const u8,

    pub fn init(key_string: []const u8) Iterator {
        return .{ .remaining = key_string };
    }

    pub fn next(self: *Iterator) ?Pair {
        if (self.remaining.len == 0) return null;
        const found = findInKeyString(self.remaining, null) orelse {
            self.remaining = "";
            return null;
        };
        const key = self.remaining[found.key_pos .. found.value_pos - 1];
        var value = self.remaining[found.value_pos..found.value_end];
        if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"')
            value = value[1 .. value.len - 1];
        self.remaining = if (found.next_pair_pos) |at| self.remaining[at..] else "";
        return .{ .key = key, .value = value };
    }
};

pub const ChangeError = std.mem.Allocator.Error || error{
    InvalidKey,
    ValueContainsQuote,
    KeyStringTooLong,
};

fn validKey(key: []const u8) bool {
    return key.len != 0 and std.mem.indexOfAny(u8, key, "=;\"") == null;
}

/// Pure, owning port of `ChangeKeyString` (protsupp.cpp:5133-5184).
/// Existing entries are removed at the byte positions returned by the
/// scanner, then a nonempty replacement is appended. Null or empty values
/// delete. Values containing `=` or `;` are quoted, while any literal `"`
/// is rejected first (`protsupp.cpp:5159-5164`). The caller owns the result.
///
/// The source asserts rather than reports malformed keys at lines 5141-5142;
/// this bounded public Zig API returns `error.InvalidKey`. It also measures
/// the actual serialized result, including `=`, when enforcing `max_size`,
/// which is the documented "would make the string longer" contract at
/// lines 5130-5131/5165-5170.
pub fn changeKeyString(
    gpa: std.mem.Allocator,
    key_string: []const u8,
    key: []const u8,
    value: ?[]const u8,
    max_size: usize,
) ChangeError![]u8 {
    if (!validKey(key)) return error.InvalidKey;
    if (value) |present| {
        if (std.mem.indexOfScalar(u8, present, '"') != null)
            return error.ValueContainsQuote;
    }

    // `strNew.Left(nKeyPos) + strNew.Mid(nNextValPos)` removes a middle
    // pair; `Left(nKeyPos - 1)` removes both a last pair and its preceding
    // semicolon (protsupp.cpp:5145-5152). Guarding key_pos zero expresses
    // the intended empty result for a one-pair string without C's negative
    // CString count.
    var prefix = key_string;
    var suffix: []const u8 = "";
    if (findInKeyString(key_string, key)) |found| {
        if (found.next_pair_pos) |next| {
            prefix = key_string[0..found.key_pos];
            suffix = key_string[next..];
        } else {
            const prefix_end = if (found.key_pos == 0) 0 else found.key_pos - 1;
            prefix = key_string[0..prefix_end];
        }
    }

    const base_len = prefix.len + suffix.len;
    const present = value orelse "";
    const deleting = present.len == 0;
    const needs_quoting = !deleting and std.mem.indexOfAny(u8, present, "=;") != null;
    const added_len = if (deleting)
        0
    else
        @as(usize, @intFromBool(base_len != 0)) + key.len + 1 + present.len +
            (if (needs_quoting) @as(usize, 2) else 0);
    const result_len = base_len + added_len;
    if (result_len > max_size) return error.KeyStringTooLong;

    const out = try gpa.alloc(u8, result_len);
    var at: usize = 0;
    @memcpy(out[at..][0..prefix.len], prefix);
    at += prefix.len;
    @memcpy(out[at..][0..suffix.len], suffix);
    at += suffix.len;

    if (!deleting) {
        if (at != 0) {
            out[at] = ';';
            at += 1;
        }
        @memcpy(out[at..][0..key.len], key);
        at += key.len;
        out[at] = '=';
        at += 1;
        if (needs_quoting) {
            out[at] = '"';
            at += 1;
        }
        @memcpy(out[at..][0..present.len], present);
        at += present.len;
        if (needs_quoting) {
            out[at] = '"';
            at += 1;
        }
    }
    std.debug.assert(at == result_len);
    return out;
}

/// Pure portion of `CIrcProto::ChangeProperty` (ircproto.cpp:1389-1404):
/// apply the key-string mutation with the source call site's 255-byte limit.
/// Permission checks and live network resynchronization are deliberately
/// outside this module, as documented above.
pub fn changeProperty(
    gpa: std.mem.Allocator,
    current: []const u8,
    property: []const u8,
    value: ?[]const u8,
) ChangeError![]u8 {
    return changeKeyString(gpa, current, property, value, 255);
}

/// One `OnPropertyChange(key, value_or_null)` call represented as data.
/// Slices borrow from the old/new blobs passed to `handleClientDataChange`;
/// only the returned list allocation is caller-owned.
pub const PropertyChange = struct {
    key: []const u8,
    value: ?[]const u8,
};

/// `CIrcProto::HandleClientDataChange` (ircproto.cpp:737-767), retaining its
/// source two-pass structure rather than replacing it with a map: pass zero
/// enumerates the new string and emits additions/modifications; pass one
/// enumerates the old string and emits removals only. This produces generic
/// changes for every property key and performs no backdrop-specific I/O.
pub fn handleClientDataChange(
    gpa: std.mem.Allocator,
    old_client_data: []const u8,
    new_client_data: []const u8,
) std.mem.Allocator.Error![]PropertyChange {
    const property_strings = [2][]const u8{ new_client_data, old_client_data };
    var changes: std.ArrayList(PropertyChange) = .empty;
    errdefer changes.deinit(gpa);

    for (property_strings, 0..) |property_string, pass| {
        var it = Iterator.init(property_string);
        while (it.next()) |pair| {
            const other_value = getValue(property_strings[1 - pass], pair.key);
            if (other_value == null) {
                // ircproto.cpp:755-759: absent from old on pass 0 means
                // added; absent from new on pass 1 means removed.
                try changes.append(gpa, .{
                    .key = pair.key,
                    .value = if (pass == 1) null else pair.value,
                });
            } else if (pass == 0 and !std.mem.eql(u8, other_value.?, pair.value)) {
                // ircproto.cpp:760-763: modifications fire once, from the
                // new-string pass, and carry the new value.
                try changes.append(gpa, .{ .key = pair.key, .value = pair.value });
            }
        }
    }
    return changes.toOwnedSlice(gpa);
}

test "plain values get and enumerate, including one trailing separator" {
    try std.testing.expectEqualStrings("hello", getValue("msg=hello;id=200", "msg").?);
    try std.testing.expectEqualStrings("hello", getValue("msg=hello;", "msg").?);
    try std.testing.expect(getValue("msg=hello", "missing") == null);

    var it = Iterator.init("msg=hello;id=200");
    const first = it.next().?;
    try std.testing.expectEqualStrings("msg", first.key);
    try std.testing.expectEqualStrings("hello", first.value);
    const second = it.next().?;
    try std.testing.expectEqualStrings("id", second.key);
    try std.testing.expectEqualStrings("200", second.value);
    try std.testing.expect(it.next() == null);
}

test "quoted value semicolon is not a pair boundary" {
    const blob = "msg=\"hello; what is your name\";id=200";
    try std.testing.expectEqualStrings("hello; what is your name", getValue(blob, "msg").?);

    var it = Iterator.init(blob);
    const message = it.next().?;
    try std.testing.expectEqualStrings("msg", message.key);
    try std.testing.expectEqualStrings("hello; what is your name", message.value);
    const id = it.next().?;
    try std.testing.expectEqualStrings("id", id.key);
    try std.testing.expectEqualStrings("200", id.value);
    try std.testing.expect(it.next() == null);
}

test "change quotes equals and semicolon values" {
    const gpa = std.testing.allocator;

    const with_equals = try changeKeyString(gpa, "", "expr", "a=b", 255);
    defer gpa.free(with_equals);
    try std.testing.expectEqualStrings("expr=\"a=b\"", with_equals);
    try std.testing.expectEqualStrings("a=b", getValue(with_equals, "expr").?);

    const with_semicolon = try changeKeyString(gpa, with_equals, "msg", "hello; there", 255);
    defer gpa.free(with_semicolon);
    try std.testing.expectEqualStrings("expr=\"a=b\";msg=\"hello; there\"", with_semicolon);
    try std.testing.expectEqualStrings("hello; there", getValue(with_semicolon, "msg").?);
}

test "change rejects a literal quote in the value" {
    try std.testing.expectError(
        error.ValueContainsQuote,
        changeKeyString(std.testing.allocator, "msg=old", "msg", "say \"hello\"", 255),
    );
}

test "change splices by source positions then appends and deletes" {
    const gpa = std.testing.allocator;

    const changed = try changeKeyString(gpa, "id=1;msg=old;theme=dark", "msg", "new", 255);
    defer gpa.free(changed);
    try std.testing.expectEqualStrings("id=1;theme=dark;msg=new", changed);

    const deleted_middle = try changeKeyString(gpa, changed, "theme", null, 255);
    defer gpa.free(deleted_middle);
    try std.testing.expectEqualStrings("id=1;msg=new", deleted_middle);

    const deleted_last = try changeKeyString(gpa, "id=1;theme=dark", "theme", "", 255);
    defer gpa.free(deleted_last);
    try std.testing.expectEqualStrings("id=1", deleted_last);

    const deleted_only = try changeKeyString(gpa, "id=1", "id", null, 255);
    defer gpa.free(deleted_only);
    try std.testing.expectEqualStrings("", deleted_only);
}

test "change enforces the post-splice size and ChangeProperty uses 255" {
    const gpa = std.testing.allocator;

    try std.testing.expectError(error.KeyStringTooLong, changeKeyString(gpa, "", "id", "200", 5));
    const exact = try changeKeyString(gpa, "", "id", "200", 6);
    defer gpa.free(exact);
    try std.testing.expectEqualStrings("id=200", exact);

    var too_long_value: [253]u8 = undefined;
    @memset(&too_long_value, 'x');
    try std.testing.expectError(
        error.KeyStringTooLong,
        changeProperty(gpa, "", "key", &too_long_value),
    );
}

test "client-data diff preserves source two-pass added modified removed order" {
    const gpa = std.testing.allocator;
    const old = "same=x;modified=old;removed=gone";
    const new = "same=x;modified=new;added=fresh";
    const changes = try handleClientDataChange(gpa, old, new);
    defer gpa.free(changes);

    try std.testing.expectEqual(@as(usize, 3), changes.len);
    try std.testing.expectEqualStrings("modified", changes[0].key);
    try std.testing.expectEqualStrings("new", changes[0].value.?);
    try std.testing.expectEqualStrings("added", changes[1].key);
    try std.testing.expectEqualStrings("fresh", changes[1].value.?);
    try std.testing.expectEqualStrings("removed", changes[2].key);
    try std.testing.expect(changes[2].value == null);
}

test "client-data diff reports a property removed from an otherwise empty blob" {
    const gpa = std.testing.allocator;
    const changes = try handleClientDataChange(gpa, "bk=cave.bmp,https://example.invalid/cave.bmp", "");
    defer gpa.free(changes);

    try std.testing.expectEqual(@as(usize, 1), changes.len);
    try std.testing.expectEqualStrings("bk", changes[0].key);
    try std.testing.expect(changes[0].value == null);
}
