# Task contract: CC-20260824-01

## Outcome

Close real IRC/IRCX/TLS/session/DCC/UDI correctness and reliability gaps in
the portable backend against Microsoft Comic Chat wire behavior and a modern
Onyx TLS IRC server, without redesigning desktop UI.

## Route

- Score: `2 + 1 + 2 + 1 = 6`
- Primary lane: `balanced`
- Required reviewer: `frontier` (critical domain: protocol-compatibility, tls, credentials)
- Maximum parallel lanes: `3` (independent read-only scouts; one writer)
- Critical domain: `protocol-compatibility`

## Ownership

- Owned paths:
  - `src/net/` (IRC/IRCX, CAP/SASL, TLS, transport, session store, reconnect policy, client composition)
  - `src/proto/` (UDI, DCC, keystring, record only if wire-related)
  - `src/comic/session.zig` (NAMES/JOIN/PART roster and annotation consumption)
  - `src/comic/notify.zig` and `src/comic/rules.zig` only if they own WHO/LIST snapshot correctness that backend state depends on
  - focused tests aggregated from `src/root.zig`
  - protocol docs only if a closed gap changes a documented invariant
- Read-only dependencies:
  - `docs/WORKERS.md`, `docs/PROTOCOL.md`, `docs/MICROSOFT_WIRE_AUDIT.md`
  - `docs/audits/2026-07-22-comicchat-onyx-ircv3-parity.md`
  - IRCX draft 04, Microsoft source commit `c7df00f60bc8e9fdef413f139e61f7c37e024684`
  - `third_party/onyx-server` pinned revision
- Forbidden paths:
  - desktop UI chrome, layout, styling, menus, dialogs (`src/client/` view/chrome, `src/platform/*` except if a backend-owned DCC consent hook is already there)
  - renderer/layout/raster (`src/comic/original_*`, `strip.zig`)
  - asset files, golden raster hashes
- Base commit: `74b19bd1fc3dc07f252616f009dfabdc79011330` (current `main`)

## Evidence and constraints

- Existing behavior: docs claim exact IRCX discovery, UDI send/receive, PROP/ACCESS/LISTX, DCC consent, SASL, SESSION RESUME, reconnect restoration.
- Source/reference evidence: `ircproto.cpp`, `ircsock.cpp`, `protsupp.cpp`, IRCX draft 04, Onyx session/TLS contract.
- Invariants from `docs/WORKERS.md`:
  - no SDL; pinned Onyx TLS; no insecure fallback
  - no mutable protocol globals or detached worker ownership
  - parsed messages borrow framing storage
  - `client.zig` is the only live composition layer
  - DCC consent/progress owned by app; `client.zig` only serializes offers
  - only validated JOIN/NAMES/history atoms on reconnect; never replay uncertain PRIVMSG

## Acceptance criteria

- [x] Real correctness/reliability bugs in owned backend surfaces are fixed, not merely documented
- [x] Focused tests pin each closed gap
- [x] `zig build test` passes
- [x] `zig build` linux/amd64 still builds
- [x] `git diff --check` clean
- [x] PR lists what was fixed and honest leftovers
- [x] No desktop UI redesign

## Wave 9 leftovers in scope

- Delay NICK/USER until CAP END when SASL credentials are present
- Exception/invite list MODE +e/+I on the existing ban-dialog / channel-mode path; show 346-349
- Rejoin workspace rooms that restoration does not already cover
- Show remaining live numerics 329 and send failure 486

## Wave 10 leftovers in scope

- SILENCE on the existing Ban and User List dialogs (`s`/`silence`/`ignore`, `s:mask`, `-s:mask`; User List filter `silence`/`ignore`)
- Remember silence masks and away text across reconnect; resend after 001
- Consume TAGMSG/EDIT/REDACT as action lines without a message editor
- Show leftover live numerics 042, 271, 272, 335, 379 and send failures 439, 511
- Skip SASL EXTERNAL, NetMeeting, onyx/e2ee, remote art, and PR #11 UI

## Wave 11 leftovers in scope

- Apply advertised `PREFIX` / `CASEMAPPING` / `CHANTYPES` on the live path (Onyx `ascii` + `(YQqov)*!.@+`)
- Forward `470` room redirects without dropping the destination or join key
- Show leftover live numerics 010, 020, 276, 308, 310, 320, 351, 391 and send failures 431, 443, 451, 461, 462, 479, 484, 485
- Reset ISUPPORT maps on disconnect so the next 005 can replace them

## Wave 12 leftovers in scope

- Apply advertised `CHANMODES` / `STATUSMSG` / length limits (`NICKLEN`, `CHANNELLEN`, `KEYLEN`, `TOPICLEN`, `AWAYLEN`, `KICKLEN`, `CHANLIMIT`)
- Republish stored IRCX `CLIENT` keystrings after reconnect (own JOIN or numeric 800)
- Show leftover live numerics 256-259, 302, 303, 321, 369, 371, 374 and send failures 406, 468, 524
- Reset the new maps and limits on disconnect with the rest of ISUPPORT

## Wave 13 leftovers in scope

- Apply advertised `NETWORK` to notify matching, and `MAXTARGETS` / `MONITOR` / `SILENCE` to send/subscribe caps
- Apply numeric `043` SAVENICK to the live nick so a forced rename does not desync session identity
- Show leftover live numerics 015-017, 043, 270, 281, 282, 301, 304, 316, 325, 328, 344, 360, 364, 365, 373, 382, 717, 718, 824, 825
- Show leftover send failures 402, 407, 411, 416, 440, 456-458, 480, 489, 492, 494, 716, 821-823

## Wave 14 leftovers in scope

- Show leftover live numerics 305/306 (self away confirm) after roster update
- Show leftover send failures 410, 513, 517, 525, 531 (NOCOMICDATA)
- Treat 435 BANNICKCHANGE as a nick failure
- Show inbound self user MODE (`MODE me +i`) in the active room
- Keep last invite and last key-channel hints across reconnect
- Skip SASL EXTERNAL, password-dialog SASL, NetMeeting, onyx/e2ee, remote art, stored-only ISUPPORT, and PR #11 UI

## Wave 15 leftovers in scope

- Treat 520 OPERONLY and 480 join-throttle as join denials (forget restoration)
- Treat 437 UNAVAILRESOURCE as join-denied when the target is a channel, nick-failure otherwise
- Show leftover CREATE failure 926 CHANNELEXIST
- Clear the current notify-online snapshot on disconnect so stale presence does not survive
- Skip SASL EXTERNAL, password-dialog SASL, NetMeeting, onyx/e2ee, remote art, stored-only ISUPPORT, operator STATS/TRACE/USERS, and PR #11 UI

## Wave 16 leftovers in scope

- Treat 489 SECUREONLY (`+S`) as a join denial when the target room is not joined, so restoration is forgotten
- Keep 489 as a command failure when the room is already joined (voice/send)
- Skip SASL EXTERNAL, password-dialog SASL, NetMeeting, onyx/e2ee, remote art, stored-only ISUPPORT, operator STATS/TRACE/USERS, METADATA (no live UI), and PR #11 UI

## Wave 17 leftovers in scope

- Map connection-failure status to human sentences; do not show raw Zig `@errorName` in the status bar
- Rejoin only rooms that still `want_rejoin` after 001 (forget parted, kicked, join-denied, and 470 source rooms)
- Retarget last-key and last-invite hints when 470 forwards a room
- Skip SASL EXTERNAL, password-dialog SASL, NetMeeting, onyx/e2ee, remote art, stored-only ISUPPORT, operator STATS/TRACE/USERS, METADATA (no live UI), and PR #11 UI

## Wave 20 leftovers in scope

- Do not PART the last remaining room from the toolbar or `/part` (keeps `want_rejoin` for 001)
- Invite-only `473` fills `last_invite_channel` for the invitation dialog
- ACCESS/PROP/WHISPER errors `913`–`919`/`923`–`925` are command failures, not raw workflow dumps
- Skip SASL EXTERNAL, password-dialog SASL, NetMeeting, onyx/e2ee, remote art, stored-only ISUPPORT, operator STATS/TRACE/USERS, METADATA (no live UI), and PR #11 UI

## Wave 34 leftovers in scope

- Session-sync still JOINs first-visit `want_rejoin` rooms that restoration does not already cover
- Keep `SETPASS` visible (inbound reply and `/setpass`); apply advertised `ACCOUNTEXTBAN`
- Apply advertised `CHATHISTORY` as the restoration history bound
- Honor advertised `EXCEPTS` / `INVEX` mode letters on the ban-dialog MODE path
- `/knock`, `/search`, and `/setname` stay live; `InvalidUtf8` on TOPIC/AWAY/greeting stays English
- Skip NetMeeting, remote art, `onyx/e2ee`, WEBAUTHN, SASLprep, operator
  STATS/TRACE/USERS, METADATA unless a live dialog sends it, and PR #11 chrome

## Wave 35 leftovers in scope

- Query slashes that were comic PRIVMSG stay on the wire: WHOIS/WHOWAS/WHO/ISON/
  USERHOST/MOTD/VERSION/TIME/ADMIN/INFO/LUSERS/COMMANDS/NAMES/LIST
- Send/session slashes `/msg`, `/notice`, `/nick`, `/topic`, and `/invite` stay
  live; `/part [#channel] [reason]` no longer becomes comic speech; `/away` stays
  on the dialog (persists `away_message`)
- Dialog `InvalidUtf8` on topic/kick/PROP/ACCESS stays English; `setProperty` and
  `accessAdd` validate UTF-8
- Skip NetMeeting, remote art, `onyx/e2ee`, WEBAUTHN, SASLprep, operator
  STATS/TRACE/USERS, METADATA unless a live dialog sends it, and PR #11 chrome
- Leave SASL EXTERNAL cert, `draft/pre-away` after 001, TARGMAX vs MAXTARGETS,
  and `FAIL JOIN TEMPORARILY_UNAVAILABLE` keeping `want_rejoin`

## Wave 36 leftovers in scope

- `/mode` and `/kick` composer slashes stay on the wire instead of comic PRIVMSG
- Skip NetMeeting, remote art, `onyx/e2ee`, WEBAUTHN, SASLprep, operator
  STATS/TRACE/USERS, METADATA unless a live dialog sends it, and PR #11 chrome

## Wave 37 leftovers in scope

- `/join #channel key` stores the key and JOINs; `/JOIN` is case-insensitive
- `/quit [reason]` quits instead of becoming comic speech
- `/create`, `/rename`, `/ctcp`, and `/ping` stay on the wire
- Skip NetMeeting, remote art, `onyx/e2ee`, WEBAUTHN, SASLprep, operator
  STATS/TRACE/USERS, METADATA unless a live dialog sends it, and PR #11 chrome

## Wave 33 leftovers in scope

- Server NOTICE/NOTE without a user prefix stay as Server lines (SESSION TOKEN,
  IDENTIFY, REGISTER) and are not flood-dropped
- Honor advertised `IRCX` so PROP/ACCESS/CLIENT work before numeric 800
- Keep remaining live service verbs visible (`SESSION`, `TOTP`, `HELP` 704–706,
  `MODEX` 826/827); `/clear` stays local. Map `InvalidUtf8` to English
- Skip NetMeeting, remote art, `onyx/e2ee`, WEBAUTHN, SASLprep, operator
  STATS/TRACE/USERS, METADATA unless a live dialog sends it, and PR #11 chrome

## Wave 32 leftovers in scope

- Onyx Server is first-class: `onyx/session-sync` ACK plus a resume/restoration
  skips the 001 JOIN storm; `want_rejoin` still JOINs first visits and servers
  that do not ACK session-sync
- Bouncer/CHATHISTORY msgid dedup; SASL SESSION-TOKEN + SCRAM-SHA-512 + EXTERNAL;
  password-dialog IDENTIFY + persisted SASL file; account/service slashes as
  real commands (MEMO, not TEGAMI); REGISTER/IDENTIFY replies visible; `491`
  is a command failure
- Honor advertised `MODES` (split MODE lines), `EXTBAN`, `MAXLIST`, `BOT`, `WHOX`,
  `UTF8ONLY`; persist the Onyx TLS 6697 profile in existing prefs fields
- Skip NetMeeting, remote art, `onyx/e2ee` group crypto, WEBAUTHN, operator
  STATS/TRACE/USERS, METADATA unless a live dialog sends it, and PR #11 chrome

## Wave 31 leftovers in scope

- Invite/kick nicknames and ban/except/invite/kick masks reject spaces in the dialog (`INVITE`/`KICK` nick is a middle parameter and would otherwise throw `InvalidIrcParameter` out of the UI)
- Kick reason, CREATE pending topic, and channel-properties topic/key reject control bytes; JOIN/366 `setTopic` of a leftover pending topic does not tear the session
- Skip SASL EXTERNAL, password-dialog SASL, NetMeeting, onyx/e2ee, remote art, stored-only ISUPPORT, operator STATS/TRACE/USERS, METADATA (no live UI), and PR #11 UI

## Wave 30 leftovers in scope

- Ban dialog `+b` / `ban` / `b:` match `+e` / `+I` (list vs add); add uses the stripped mask
- Channel-properties mode tokens reject spaces, same as CREATE (Onyx otherwise mis-parses `MODE +n t`)
- Skip SASL EXTERNAL, password-dialog SASL, NetMeeting, onyx/e2ee, remote art, stored-only ISUPPORT, operator STATS/TRACE/USERS, METADATA (no live UI), and PR #11 UI

## Wave 29 leftovers in scope

- Channel-properties `+l` rejects a non-positive limit in the dialog (Onyx otherwise swallows `MODE +l abc` with no numeric)
- Sound accompanying text with CTCP/control bytes is rejected before `SOUND` is sent
- Skip SASL EXTERNAL, password-dialog SASL, NetMeeting, onyx/e2ee, remote art, stored-only ISUPPORT, operator STATS/TRACE/USERS, METADATA (no live UI), and PR #11 UI

## Wave 28 leftovers in scope

- After `470`, query dest `MODE` and apply `324` `+k` so a forwarded room stores the dest key, not only a copied source key
- `324` without a key parameter does not wipe a stored join key (Onyx shows `+k` to non-members without the value)
- Skip SASL EXTERNAL, password-dialog SASL, NetMeeting, onyx/e2ee, remote art, stored-only ISUPPORT, operator STATS/TRACE/USERS, METADATA (no live UI), and PR #11 UI

## Wave 27 leftovers in scope

- LIST/ACCESS/PROP/MONITOR dialog sends that fail client-side validation stay as English notices, not a raw `error.InvalidIrcParameter` out of the UI
- Away text with CTCP/control bytes is rejected before `AWAY` is sent
- Skip SASL EXTERNAL, password-dialog SASL, NetMeeting, onyx/e2ee, remote art, stored-only ISUPPORT, operator STATS/TRACE/USERS, METADATA (no live UI), and PR #11 UI

## Wave 26 leftovers in scope

- Live JOIN/CREATE/NICK over advertised KEYLEN/CHANNELLEN/NICKLEN/CHANLIMIT stay in the dialog or transcript; do not throw `error.InvalidIrcParameter` out of the UI or 001 rejoin
- `workspace.ensure` TooManyRooms is "opened as many rooms as the server allows", not an invalid-name notice
- `/join` writes those notices instead of swallowing the name or crashing the composer
- Channel-properties `+k` rejects an over-long key before storing it for reconnect
- Skip SASL EXTERNAL, password-dialog SASL, NetMeeting, onyx/e2ee, remote art, stored-only ISUPPORT, operator STATS/TRACE/USERS, METADATA (no live UI), and PR #11 UI

## Wave 25 leftovers in scope

- Notification MONITOR full `734` is a command failure, like ban `478` and silence `511`
- Skip SASL EXTERNAL, password-dialog SASL, NetMeeting, onyx/e2ee, remote art, stored-only ISUPPORT, operator STATS/TRACE/USERS, METADATA (no live UI), and PR #11 UI

## Wave 24 leftovers in scope

- IRCX properties `906` BADVALUE is a command failure, not a raw 900–908 workflow dump
- Skip SASL EXTERNAL, password-dialog SASL, NetMeeting, onyx/e2ee, remote art, stored-only ISUPPORT, operator STATS/TRACE/USERS, METADATA (no live UI), and PR #11 UI

## Wave 23 leftovers in scope

- `403` NOSUCHCHANNEL is a join denial only before the room is seated; Ban/Kick/Invite/send `403` on a joined room is a command failure and keeps `want_rejoin`
- Skip SASL EXTERNAL, password-dialog SASL, NetMeeting, onyx/e2ee, remote art, stored-only ISUPPORT, operator STATS/TRACE/USERS, METADATA (no live UI), and PR #11 UI

## Wave 22 leftovers in scope

- Ban-dialog `476` BADCHANMASK is a command failure unless the target is a channel
- Send-to-`+R` `477` is a command failure; channel-target `477` (+a) stays a join denial
- Skip SASL EXTERNAL, password-dialog SASL, NetMeeting, onyx/e2ee, remote art, stored-only ISUPPORT, operator STATS/TRACE/USERS, METADATA (no live UI), and PR #11 UI

## Wave 21 leftovers in scope

- Room-properties `MODE +Z` quiet lists `728`/`729` are visible workflow replies
- `442` marks the seat gone without clearing `want_rejoin` or restoration
- `470` copies join key / CLIENT only when the destination has none
- Inbound `RENAME` republishes stored IRCX `CLIENT` under the new name
- Skip SASL EXTERNAL, password-dialog SASL, NetMeeting, onyx/e2ee, remote art, stored-only ISUPPORT, operator STATS/TRACE/USERS, METADATA (no live UI), and PR #11 UI

## Wave 19 leftovers in scope

- Notification Join room, `/join`, and automation Join room reuse the stored key and set `want_rejoin`
- Inbound `RENAME` retargets last-key/last-invite hints and writes a room-renamed line
- Skip SASL EXTERNAL, password-dialog SASL, NetMeeting, onyx/e2ee, remote art, stored-only ISUPPORT, operator STATS/TRACE/USERS, METADATA (no live UI), and PR #11 UI

## Wave 18 leftovers in scope

- Mark the startup and locator rooms `want_rejoin` so the first 001 still JOINs them
- Invitation / favorite / LISTX / locator JOIN reuse the stored room key
- `MODE +k` and the channel-properties key field retarget `last_key_channel`
- Show CREATE `927` ALREADYONCHANNEL, connect `463` host-denied, and `466` you-will-be-banned
- File-transfer dialog status uses English labels, not `@tagName`
- Skip SASL EXTERNAL, password-dialog SASL, NetMeeting, onyx/e2ee, remote art, stored-only ISUPPORT, operator STATS/TRACE/USERS, METADATA (no live UI), and PR #11 UI

## Verification

- Focused gate: new/updated inline tests in owned modules
- Aggregate gate: `zig build test`
- Build gate: `zig build` (linux/amd64)
- Hygiene gate: `git diff --check`

## Authority

- Local edits authorized: `yes`
- External writes authorized: `no` (PR creation is the only GitHub write, via required agent tooling)
- Destructive actions authorized: `no`

## Handoff

- Files changed:
- Commands and outcomes:
- Evidence:
- Residual risk:
- Recommendation: `accept | escalate | discard`
