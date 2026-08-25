# Comic Chat protocol and asset formats

The behavioral reference for this document is the MIT-licensed historical
Comic Chat source at commit `c7df00f60bc8e9fdef413f139e61f7c37e024684`,
especially `histent.cpp`, `protsupp.cpp`, `ircproto.cpp`, `ircsock.cpp`,
`avbfile.h`, and `avbfile.cpp`. It is an external reference at
<https://github.com/microsoft/comic-chat>; this portable repository does not
vendor the retired MFC/C++ tree.

## Live transport: comic metadata over IRC

Comic Chat is an IRC client. Registration and conversation use ordinary IRC
commands including `NICK`, `USER`, `JOIN`, `PRIVMSG`, `NOTICE`, `PING`, and
`PONG`. The old client can negotiate Microsoft's IRCX extensions, but it also
has a non-IRCX representation.

Microsoft probes IRCX before login with `MODE ISIRCX`. A numeric 800 state `0`
means the server supports IRCX but it is not enabled, so the client sends
`IRCX`; only the following numeric 800 state `1` enables `DATA ... CCUDI1`.
An ISUPPORT advertisement does not substitute for that state transition. The
portable client preserves this ordering, with modern CAP/SASL negotiation
between the probe and NICK/USER. When SASL credentials are present, NICK/USER
wait for a terminal SASL result and `CAP END` so the reserved account nick is
not raced before `AUTHENTICATE`.

The portable client secures that stream with the pinned Onyx TLS implementation
at commit `06bb3500b4fd62e2f307cb4004340c58062c0f59`. TLS is the default and
the omitted port defaults to 6697. The client sends SNI and verifies both the
certificate chain and requested hostname. It loads common Unix system bundles
or the Windows ROOT certificate store; `--ca-file <pem>` supplies an explicit
replacement bundle. Missing roots, handshake errors, and verification errors
fail the connection without falling back to plaintext. `--plaintext` is an
explicit compatibility option for trusted local deployments only.

Per-message user-display information (UDI) has this compact byte grammar:

```text
#G<gesture><gesture-emotion><gesture-intensity>
 E<expression><expression-emotion><expression-intensity>
 [R]M<mode>[T<nick>[,<nick>...]]
```

The line breaks above are only for readability; the actual annotation is one
contiguous string. Every numeric field is encoded as one byte with value
`index + '0'`, not as an arbitrary-length decimal number. `R` marks an
explicitly requested pose. Serial modes are 1 = say, 2 = whisper, 3 = think,
and 5 = action; other serial values are read as say by the released client.

- The source-compatible sender prefixes readable text inside one message,
  including when IRCX is available:
  `PRIVMSG target :(#G...E...M...) readable text`.
- Reinked accepts a peer's standalone `DATA target CCUDI1 :#G...E...M...`
  representation, but does not require that optional extension to interoperate
  with original clients.

In comic mode, action text remains ordinary readable text; serial mode `M5`
selects the box balloon. The CTCP `ACTION` wrapper is only Microsoft's
non-comic fallback. The optional `T` suffix carries the selected member (and
always carries the whisper recipient), matching `bInsertAnnotations` rather
than relying on the IRC target alone.

This distinction matters: a saved conversation record is not copied wholesale
into an IRC `PRIVMSG`. Separate live control comments begin with `#` and use
source-defined phrases such as ` Appears as `, ` GetInfo`, ` HeresInfo: `,
` BDrop: `, ` BDrop2: `, and ` GetCharInfo`. Microsoft passes these comment
controls through the annotation argument. With Comic Chat data enabled (the
source default), they are regular `PRIVMSG` bytes such as `# Appears as Tiki.`.
The portable receiver also accepts a peer's IRCX `DATA` representation.

The portable live client implements `# Appears as <name>[.<url>]` for bundled
avatars in either outer transport, consumes the control without creating a
speech balloon, and retains the selected avatar for later messages and talk-to
bodies. It intentionally does not download the optional URL. Profile requests
receive the saved one-line profile or the source default, member-profile
replies become visible action rows, and character-info requests trigger a fresh
avatar announcement. Backdrop comments select the matching bundled BGB in the
room renderer; unknown names and remote URLs are consumed without downloading
untrusted content.

The portable IRC framing and command path lives under [`src/net/`](../src/net/).
The compact live codec is [`src/proto/udi.zig`](../src/proto/udi.zig), and the
interactive client accepts both embedded and IRCX `CCUDI1` forms. It carries
the raw authored face/torso/body record ordinals, emotion/intensity bytes,
requested flag, mode, and talk-to list into the AVB renderer. Outgoing text is
run through the source-derived pose rules before encoding; negotiated IRCX uses
the standalone `DATA` form and ordinary IRC uses the embedded form. The saved
transcript codec below is implemented in
[`src/proto/record.zig`](../src/proto/record.zig).

### Inline text formatting and actions

After UDI removal, `SayEntry` strips the released client's inline controls and
records format-state changes at offsets in the clean text. The portable path
does the same for bold (`02`), colour (`03`), fixed-pitch (`11`), symbol
(`12`), italic (`16`), and underline (`1f`) bytes. Colour numbers use the
source 16-entry Windows palette modulo 16; URLs receive the source link state
and exact blue foreground. The base balloon face is already bold, italic uses
the checked-in Bold Italic atlas for both measurement and rasterization, and
underline is drawn at the source baseline. Controls never occupy text-layout
space, and continuation panels reset the old ellipsis then restore the active
state after the new ellipsis exactly like `CutFormattingArray`,
`PullFormattingOffsets`, and `PushFormattingOffsets`.

Foreground and background with the same palette index request transparent
text. The software renderer preserves the run's advance while omitting its
ink. Other background colours remain in the owned format state but are not
painted because the original balloon DC uses transparent background mode.
Fixed-pitch and symbol selection are likewise preserved in state; the portable
build currently falls back to the bundled Comic Neue atlases because it does
not ship equivalent fixed-pitch or symbol faces.

IRC CTCP actions use `\x01ACTION text\x01` in Microsoft's text-mode fallback.
Incoming actions are unwrapped and render with `BM_ACTION` (plus `BM_WHISPER`
for a private message). In comic mode, `/me text` follows
`PrepareComicsAction`: the readable message remains raw text and UDI serial
mode `M5` selects the action box.

Sounds are separate from UDI. `bChatSendSound` sends one source CTCP payload,
`\x01SOUND <file> <accompanying-message>\x01`, in a `PRIVMSG`. The portable
sound dialog mirrors that contract with a sound-file choice and editable
accompanying message; receiving clients display the sender and message as an
action box followed by the sound filename in parentheses.

Enter Room sends `JOIN <room> [password]`. Create Room sends Microsoft IRCX's
`CREATE <room> [creation-modes] [limit] [password]` and queues its optional
topic after creation. Kick always sends the source trailing form
`KICK <room> <nick> :<reason>`, including an empty reason; its optional ban is
sent first as `MODE <room> +b <mask>`.

Away has two synchronized layers: standard `AWAY :message` (or bare `AWAY` to
clear it), followed by `\x01AWAY [message]\x01` in every joined room. Incoming
controls update the roster indicator and are not inserted as comic speech.
VERSION, PING, TIME, EMAIL, URL, and CLIENTINFO probes receive source-shaped
NOTICE replies. EMAIL and URL are empty by default and return only values the
user explicitly saved in the local preferences editor.

### IRCX application workflows

The Room menu exposes the IRCX draft's typed management paths after numeric
800 state 1 enables IRCX:

- `LISTX <query-list> [limit]`, with comma-separated query terms and a numeric
  result bound. Non-IRCX servers receive ordinary `LIST`.
- `PROP <channel> <property>[,<property>]` for queries and
  `PROP <channel> <property> :<value>` for set/delete. The empty trailing value
  is preserved for deletion.
- `ACCESS <object> LIST`, `ADD|DELETE <level> <mask> [timeout [:reason]]`, and
  `CLEAR [level]`. Timeouts are minutes; a reason without an entered timeout
  emits the draft's unlimited `0` value.
- `EVENT LIST [event]` and `EVENT ADD|DELETE <event> [mask]` for authorized
  operators.

The IRCX transport also implements all three draft §5.4 tagged-message verbs:
`DATA`, `REQUEST`, and `REPLY`, with locally validated 1–15 character tags,
plus contextual `WHISPER <channel> <nick-list> :<message>`. Incoming IRCX
whispers remain in their channel context and render as private comic lines.
ACCESS removal emits the normative `DELETE` token; the non-standard `DEL`
abbreviation is never sent.

For IRCX-only services, the client also exposes the draft §5.2 `AUTH` envelope
with `I`, `S`, and abort (`*`) sequence validation. It accepts this only over
verified TLS, marks the queued payload sensitive, and zeroes the caller's
mutable credential bytes after queuing. CAP SASL remains the preferred modern
registration path.

Replies 801-819 and relevant IRCX errors 913-925 are shown in the active room
as server action rows. The exact command bytes are pinned by unit tests against
the [IRCX Internet-Draft](https://datatracker.ietf.org/doc/html/draft-pfenning-irc-extensions-04.txt)
and the Microsoft client source.

### DCC and call invitations

Microsoft's DCC SEND payload and four-byte big-endian cumulative ACK loop are
preserved. Incoming offers are not accepted automatically: the user reviews
the sender, bounded size, and destination first. Received data is held until
complete, then written with exclusive creation; an existing destination is
never replaced, and failed/cancelled transfers retain no partial output.
Outgoing transfers bind the chosen port before advertising the offer and can
interrupt a blocked listener through socket shutdown.

The retired `NETMEET` control is answered with `NETMEET NOHAVE`. Portable call
invitations use `\x01X-COMICCHAT-CALL https://...\x01`; receipt opens a consent
dialog, validates a one-line HTTPS URL, and never launches it automatically.

### IRCv3 CAP and SASL compatibility

The transport-independent negotiation cores are
[`src/net/ircv3.zig`](../src/net/ircv3.zig) and
[`src/net/sasl.zig`](../src/net/sasl.zig). Their wire behavior is pinned to the
official IRCv3 specification checkout at commit
`5eca32ce8cbc0c8f9d123529ef221d8da9516b65`; SCRAM-SHA-256 follows RFC 5802
and RFC 7677. They emit commands into caller-owned buffers and do not log
credentials. Mutable credential slices remain caller-owned and are securely
zeroed at a terminal SASL result or session teardown.

| Surface | Portable behavior |
| --- | --- |
| CAP discovery | `CAP LS 302`, multiline continuation, opaque capability values, and implicit `cap-notify` |
| Selection | Every published client-facing capability is cataloged; prerequisites are selected together, unavailable dependency chains are skipped, and STS is observed but never requested |
| Runtime updates | Split `ACK` sets apply atomically; `NAK`, `NEW` value changes, and immediate `DEL` cancellation update owning offered/enabled maps |
| Registration | `CAP END` waits for all request batches and, when SASL is enabled, for a terminal SASL result |
| SASL framing | Exact 400-byte `AUTHENTICATE` chunks, terminal `+` for exact multiples, incoming chunk reassembly, and abort `*` |
| SASL numerics | `900` through `908`, mechanism advertisement refresh, preference selection, and retry after failed/aborted mechanisms |
| Mechanisms | PLAIN, EXTERNAL, and SCRAM-SHA-256 with bounded PBKDF2 work, strict nonce extension, RFC-vector proof generation, and timing-safe server-signature verification |

PLAIN fields must be caller-prepared valid UTF-8. The current SCRAM core
accepts the ASCII subset unchanged by SASLprep; it deliberately rejects
internationalized identities/passwords until a complete RFC 4013 preparation
layer is available rather than authenticating with subtly wrong bytes.

The live `Client` connects these pure cores to an owning feature-state layer
and bounded connection policy. Its `default_desired_capabilities` profile is
the complete non-deprecated client-facing CAP set in the pinned tree:

| Capability | Implemented portable behavior |
| --- | --- |
| `account-notify`, `account-tag` | Account tags and `ACCOUNT` changes update owned, case-insensitive identity state |
| `draft/account-registration` | Optional value retained verbatim; typed TLS-only `REGISTER`/`VERIFY` sends wipe caller and queue copies, with replies handled through standard replies |
| `away-notify` | `AWAY` changes update identity state |
| `batch` | Case-sensitive references, nesting/parent closure, unknown batch types, labels, and strict count/byte bounds |
| `cap-notify` | Implicit with CAP 302; runtime `NEW`/`DEL` and changed values are applied |
| `draft/channel-rename` | `RENAME` mappings are retained for channel-view migration |
| `draft/chathistory` | `chathistory` and target batches are delivered atomically; reconnect restoration emits bounded `CHATHISTORY AFTER` without replaying chat sends |
| `draft/event-playback` | History state events pass through the same JOIN/PART/QUIT/NICK/MODE/TOPIC feature path |
| `chghost` | User and host changes update identity state |
| `echo-message` | A bounded optimistic-echo queue suppresses one matching server echo |
| `draft/extended-isupport` | `draft/isupport` batches are aggregated and `005` tokens are stored in a bounded owning map, including removals |
| `extended-join` | Account and realname fields from extended JOIN are retained |
| `extended-monitor` | Its AWAY/ACCOUNT/CHGHOST/SETNAME notifications share the normal identity path |
| `invite-notify` | `INVITE` remains a typed generic IRC message for the application event layer |
| `labeled-response` | Outgoing commands get unique bounded labels; direct replies, ACK, and response batches complete correlations |
| `draft/message-redaction` | Case-sensitive message-ID tombstones suppress redacted replay and future delivery |
| `message-tags` | Opaque case-sensitive keys, final-wins duplicate handling, IRCv3 escaping, client-only tags, and `TAGMSG` parsing |
| `draft/metadata-2` | Metadata batches and live `METADATA` key/value updates are retained with state bounds |
| `multi-prefix`, `userhost-in-names` | NAMES parsing strips multiple status prefixes and separates optional `!user@host` data from nick identity |
| `draft/multiline` | Only uniform PRIVMSG or NOTICE lines to the declared target combine; concat/newline rules and opening semantic tags are preserved |
| `no-implicit-names` | Every own JOIN queues an explicit `NAMES` request |
| `draft/oper-tag` | The `draft/oper` tag updates participant operator state |
| `draft/pre-away` | Negotiated so an application may issue `AWAY` during the open registration window |
| `draft/read-marker` | Per-target `MARKREAD` timestamps are retained |
| `sasl` | PLAIN, EXTERNAL, and SCRAM-SHA-256 with mechanism advertisement/retry and terminal credential wiping |
| `server-time` | The opaque `time` tag remains available on each immutable parsed message and survives multiline aggregation |
| `setname` | `SETNAME` updates the participant realname |
| `standard-replies` | The latest typed `FAIL`, `WARN`, or `NOTE` code and description are retained |
| `sts` | Observed only, never requested; plaintext upgrades fail closed and verified-TLS duration policies persist by hostname |

When connected to the pinned Onyx server, the client also exposes
capability-gated builders for `SEARCH`, `EDIT`, `REDACT`, `MARKREAD`, and
`METADATA`. Their exact Onyx registry comparison and wire forms are recorded
in [`docs/audits/2026-07-22-comicchat-onyx-ircv3-parity.md`](audits/2026-07-22-comicchat-onyx-ircv3-parity.md).
`onyx/e2ee` is intentionally never requested until its complete encryption and
decryption control plane is implemented.

The client exposes bounded `CHATHISTORY LATEST` requests after negotiating
`draft/chathistory`, with `*`, `msgid=...`, or `timestamp=...` selectors.
Onyx topic-filtered replay uses the same escaped `+onyx/topic` tag as live
named-conversation messages.

### Onyx reusable sessions and same-nick clients

After successful SASL and numeric `001`, the portable client follows the live
Onyx client contract: it sends `SESSION RESUME <credential>` when a stored
credential exists, then `SESSION TOKEN`. Current server `NOTICE` forms for
`SESSION TOKEN` and `SESSION MTOKEN ... expires=<unix-seconds>` are parsed with
a 4 KiB single-atom bound and accepted only from server prefixes. The portable
mesh credential is preferred until its advertised expiry; the local credential
is the fallback. Credentials are stored per host/account in an atomic,
owner-readable file.

Onyx Server admits a second SASL-authenticated connection requesting the same
nickname and account without `433`, but it remains a separate delivery group
until it presents the first client's exact reusable credential. Successful
`SESSION RESUME` adds the connection as another live attachment; it does not
disconnect the existing client.

The pinned client-tag specifications are covered as well. Typed send methods
produce `+draft/reply`, `+draft/react`, `+draft/unreact`, and rate-limited `+typing`
messages when either generic `message-tags` or their corresponding narrow Onyx
draft capability is enabled; incoming `TAGMSG`, `EDIT`, and `REDACT` appear as
action lines in the live transcript and do not rewrite comic history.
Onyx named conversations use the narrow `onyx/topics` capability and emit
escaped `+onyx/topic=<label>` tags on `PRIVMSG` or `NOTICE`, without requiring
generic tags. Contextual direct messages use
`+draft/channel-context=<channel>` only when both `draft/channel-context` and
generic `message-tags` are negotiated. This is ComicChat's conservative
semantic policy; the daemon's generic client-tag relay itself is authorized by
`message-tags`. Unknown future tags remain accessible through the generic tag
iterator. `msgid`, bot/oper tags, UTF8ONLY, CLIENTTAGDENY,
CHATHISTORY, MSGREFTYPES, MONITOR, WHOX, BOT, NETWORK, and draft ICON
advertisements are either interpreted by feature state or retained in the
ISUPPORT map. Advertised `PREFIX`, `CASEMAPPING`, and `CHANTYPES` are applied
to live NAMES/MODE decorations, nick/channel comparison, and STATUSMSG
targets instead of remaining stored-only. WEBIRC and WebSocket are separate gateway/transport modes, not
IRC capabilities, and are intentionally outside the native TCP/TLS transport.
The deprecated `tls` STARTTLS capability and deprecated DH SASL mechanisms are
deliberately not requested: the connection begins with verified TLS, and the
supported SASL mechanisms avoid the pinned tree's retired cryptography.

The `draft/account-registration` value remains an opaque stored CAP value; the
specification defines no CAP dependency for it (its use of standard replies is
a message-framework dependency). STS is never sent in `CAP REQ`.
`takeStsPolicyUpdate` instead produces a required plaintext upgrade port or a
verified-TLS persistence policy. `Client` applies hostname-keyed persistence;
the interactive `AsyncNetwork` owner closes a first-contact plaintext stream
and immediately reconnects to the advertised port with certificate-verified
TLS. Ordinary disconnects use bounded full-jitter reconnect scheduling and
never fall back from TLS to plaintext.

### Modern network architecture and hard limits

The portable path contains no mutable protocol globals and starts no detached
threads. Interactive connection setup uses one heap-pinned, joinable
`Transport.Connector`; a two-reference lifetime keeps cancellation race-free,
and the UI only polls its immutable completion state. Every long-lived
allocation belongs to that connector, `Client`, `Registration`, `State`,
`Aggregator`, `TxQueue`, or `Store`; deinitialization has one explicit owner.
Parsed `Message` values are immutable borrowed views, and any value that must
outlive the next receive is copied into bounded owning state.

```text
UI poll -> async DNS/address race -> optional SOCKS5/HTTP CONNECT -> verified TLS/plain stream
verified TLS/plain stream -> LineFramer -> CAP/SASL Registration
                                      -> BATCH Aggregator -> feature State -> UI
UI command -> validated serializer -> priority TxQueue -> stream
```

CAP/SASL and feature transitions are socket-independent state machines. The
Wayland/X11 loop polls connector completion every 50 ms while offline and the
Win32 loop keeps pumping messages on a 16 ms cadence. Host lookup races a
bounded 32-result IPv6/IPv4 candidate queue and cancels losing sockets. Proxy
handshakes and TLS run on the connector worker, so none can block either UI.
Control traffic (`CAP`, `AUTHENTICATE`, `PONG`)
preempts flood-limited interactive and bulk traffic. A send with uncertain
delivery is discarded; only explicit idempotent restoration commands may be
retained for reconnect, never an uncertain `PRIVMSG`.

| Resource | Hard bound |
| --- | --- |
| Incoming IRC line | 512-byte IRC body plus 8191-byte server/client tag envelope |
| Outgoing client tags | 4094 bytes, valid UTF-8, with CR/LF/NUL injection rejected |
| CAP state | 1024 capabilities and 256 KiB owned name/value storage per map |
| SASL challenge | 64 KiB encoded; PBKDF2 iterations 4096 through 1,000,000 |
| Open/queued batches | 32 open, 1024 lines, 1 MiB aggregate content |
| Feature state | 4096 entries per bounded map, 256 pending echoes, 512 labels, 256 typing targets |
| Transmit/receive policy queues | 512 messages/512 KiB TX; 1024 messages/1 MiB RX |
| Reconnect restoration | 256 targets; only validated JOIN/NAMES/history atoms |
| STS persistence | 4096 hosts and a 1 MiB on-disk parse limit |
| Address/proxy setup | 32 raced DNS results, 15 s default per-attempt/read timeout, 32 KiB HTTP header cap |

Credential-bearing output is marked sensitive at queue insertion, wiped on
successful send, uncertain send, allocation failure, and teardown. CLI SASL
accepts passwords only from a file, refuses authentication over plaintext,
and diagnostics report typed error names without command payloads or secrets.

## Saved `.ccc` conversation grammar

`CChatDoc::ChatSaveConversation` writes `#CHATCONVERSATION`, then a sequence of
CRLF-terminated, TAB-delimited records. Canonical writers use lowercase
keywords. The loader dispatches keywords case-insensitively.

| Keyword | Fields after the keyword |
| --- | --- |
| `say` | nick; `(G:... E:... R:... M:...[ T:...])`; escaped message |
| `join` | nick; optional full name |
| `ejoin` | nick; optional full name (participant already present) |
| `part` | nick |
| `changeavatar` | nick; avatar name; avatar URL or empty field |
| `getinfo` | nick; display/history information |
| `comicchar` | nick; unavailable-character information marker (not avatar state) |
| `nick` | old nick; new nick |
| `backdrop` | background name; background URL or empty field |
| `starthistory` | nick; avatar name; comic title |

Inside a `say` message, the archive writer quotes newline as `\n`, carriage
return as `\r`, tab as `\t`, and backslash as `\\`; the loader reverses those
escapes. Balloon modes, authored expression/gesture indices, intensity, and up
to the source-supported talk-to roster are stored in the parenthetical field.

## Saved `.ccr` locator grammar

Locators are a separate file type headed by `#CHATLOCATOR`; they do not share
the `.ccc` record set. The writer emits `IRCSERVER:`, `IRCCHANNEL:`, and
`CXPROMPT:`. The loader also recognizes `CHARACTER:`, `BACKDROP:`,
`COMICSDATA:`, `TITLE:`, `ARTDIR:`, and `VIEW:`. Locator keywords retain their
trailing colon.

The released locator loader scans forward for the exact-case `#CHATLOCATOR`
marker, discards the remainder of that line, and then reads tagged records until
the first blank line. Tag comparisons are case-insensitive. Although the
canonical writer separates each tag and value with a TAB, the loader accepts
other whitespace after the colon and trims whitespace from both ends of the
value. The portable `LocatorIterator` and `parseLocatorLine` APIs preserve these
rules; generic record writing continues to emit canonical TAB-delimited lines.

## `.avb` avatar and `.bgb` backdrop assets

The released tagged format is defined by `avbfile.h` and loaded by
`avbfile.cpp`. A packed six-byte header contains magic `0x8181`, asset kind,
and version, followed by tagged records. Kinds are simple avatar, complex
avatar, and background. Records cover name, flags, icon, style, palette,
copyright, URL/usage metadata, old pose encodings, current face/torso/body pose
tables, and backdrop data.

Each current pose record identifies the authored emotion table entry,
intensity, alignment points, and up to three image references. Image resources
may be an old embedded DIB/BMP or a length-prefixed zlib stream with local,
monochrome, packed masked-monochrome, or dual-mask data. Complex figures retain
the source `HEADMASK`, `TORSOMASK`, and `TORSOFIRST` behavior; packed mask/aura
planes are not treated as ordinary alpha images.

The portable parser and raster decoder are
[`src/assets/avb.zig`](../src/assets/avb.zig) and
[`src/assets/bgb.zig`](../src/assets/bgb.zig). Source-derived pose selection,
mask ROPs, and logical-to-device rounding are in
[`src/comic/original_figure.zig`](../src/comic/original_figure.zig).

## Source-derived page rendering

The portable renderer follows the old implementation's 2300×2300 logical
coordinate system, two-column page, 144-unit interstices, implicit title panel,
avatar history/order/scale, source-seeded CRT random stream, balloon fitting
and retry behavior, Woodring routes, continuations, title icons, masks, and
backdrop crop rounding. The key ports are:

- [`original_layout.zig`](../src/comic/original_layout.zig) — avatar order,
  talk-to expansion, history placement, and backdrop coordinates;
- [`original_balloon.zig`](../src/comic/original_balloon.zig) — line breaking,
  areas, random geometry, routes, tails, thought clouds, and action boxes;
- [`original_page.zig`](../src/comic/original_page.zig) — AddLine/AddReaction,
  cloning, seeds, retry, continuation, and page extents;
- [`original_title.zig`](../src/comic/original_title.zig) — title/star geometry;
- [`original_raster.zig`](../src/comic/original_raster.zig) — GDI-coordinate
  mapping, splines/arcs/dashes, atlas text, and cropped scaling;
- [`strip.zig`](../src/comic/strip.zig) — the integrated portable page path.

For live IRC rendering, [`session.zig`](../src/comic/session.zig) maintains the
title member map from `353`/NAMES, JOIN, PART, QUIT, and NICK. Status prefixes
on NAMES entries are removed, speech counts follow `CChatDoc::TallySpeech`, and
avatar announcements update the member's current avatar without changing the
avatar snapshots already stored on historic lines. The title renderer passes
that map to the `panel.cpp` `AddStarsAux` ordering port: self first, active
members before departed members, then descending send count within each group,
bounded by the source-computed star capacity. Static render callers that do not
provide a live roster continue to infer title participants from their lines.

The portable build uses bundled Comic Neue Bold and Bold Italic under the SIL
Open Font License because Comic Sans MS is proprietary. As in `fonts.cpp` and
`CBWoodringWhisper`, pure whisper balloons use the italic face for both layout
and rasterization; dashed action-whispers retain the normal face. The preserved
Windows client continues to request Comic Sans MS through its original GDI
path.
