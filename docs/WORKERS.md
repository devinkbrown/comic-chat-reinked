# Worker brief — Comic Chat

For model selection, parallel-lane sizing, escalation, and cross-model handoff,
follow [`.ai/WORKFLOW.md`](../.ai/WORKFLOW.md). Repository invariants and build
gates in this document remain authoritative.

This repository ships one portable implementation under `src/`. It uses a
software framebuffer renderer with direct X11, Wayland, and Win32 backends and
no SDL. TLS is supplied by the pinned portable Onyx TLS implementation.

The portable tree is currently tested with Zig
`0.17.0-dev.1282+c0f9b51d8`. Its standard gates are:

```sh
zig build test
zig build
zig build -Dtarget=x86_64-linux
zig build -Dtarget=aarch64-linux
zig build -Dtarget=x86_64-windows
zig build -Dtarget=x86-windows
zig build -Dtarget=aarch64-windows
```

## Rendering source of truth

The historical Comic Chat repository at
<https://github.com/microsoft/comic-chat> is the external behavioral reference.
Do not introduce a second heuristic layout or balloon path. The source-derived
portable pipeline is split across:

- `src/comic/original_page.zig`: AddLine/AddReaction, title accounting,
  retries, clones, continuations, and the shared random stream.
- `src/comic/original_layout.zig`: avatar ordering, geometry, and talk-to
  relationships.
- `src/comic/original_balloon.zig`: source line breaking, placement, tails,
  thought/action shapes, and whisper dashes.
- `src/comic/original_figure.zig`: AVB component selection, masks, ROPs, and
  logical-coordinate figure placement.
- `src/comic/original_title.zig` and `original_raster.zig`: title layout and
  the 2300-logical-unit-to-315-pixel software rasterizer.
- `src/comic/strip.zig`: public transcript-to-page integration. All shipped
  strip and panel rendering must route through this source pipeline.
- `src/comic/rules.zig`: the dynamic auto-response rule engine (event/action
  data model, text serialization, matching, keyword substitution, flood
  guard, and WHO/LIST snapshot diffing for the daemon-driven events). Does
  not include the MFC rule-editor dialogs, Registry/`.crs` binary
  persistence, or RTF formatting-run preservation across substitution - see
  the module's own doc comment for the exact boundary and what is inferred
  rather than verified (`bIsMatch`'s wildcard mask algorithm is not in the
  pinned snapshot).
- `src/comic/notify.zig`: the notify list / buddy-list feature (watched
  nickname/user/host/network entries, operator-driven wildcard-mask
  assembly for the WHO query and reply matching, and the tracked-user
  online/offline overlay driven by folding successive WHO-poll snapshots).
  Does not include the MFC notify-list dialog, Registry binary persistence
  (`CCNotif` has no text grammar to fall back to, unlike `CCRule`), or list
  sort order - see the module's own doc comment for the exact boundary,
  including why it does not reuse `rules.zig`'s `newUsers`/`goneUsers` (a
  different diff key).

Fixed source-parity contracts live in `src/comic/source_*_test.zig`. When a
deliberate source-derived raster change updates a golden hash, record the
upstream routine that justifies the change rather than merely refreshing the
hash.

## Platform boundaries

- Portable core code under `assets/`, `comic/`, `net/`, `proto/`, and
  `render/` must remain independent of the window system.
- `src/platform/x11.zig` and `wayland.zig` implement the native Linux paths.
  A nonempty `WAYLAND_DISPLAY` selects Wayland; there is no automatic X11
  fallback after a Wayland connection failure.
- `src/platform/win32.zig` uses direct Win32 declarations and presents the
  same software framebuffer; no MFC layer is part of this product.
- `src/client/` owns portable view/input behavior shared by native backends.
- The direct Wayland keyboard path parses the compositor's real XKB keymap
  (`src/platform/xkb.zig`, base + Shift + AltGr/ISO Level3 when a third
  keysym is listed, plus group 2 when a second keysym list is published),
  implements client-side key-repeat (`repeat_info` + `Window.checkRepeat`),
  and applies a bounded dead-key / Multi_key composer plus optional XCompose
  locale tables (`XCOMPOSEFILE`, `~/.XCompose`, system `%L`, capped file
  size/entries/include depth). A US evdev fallback remains before the first
  keymap arrives or for an out-of-scope keysym. Do not claim a full
  input-method editor — committed IME text uses text-input-v3 when
  advertised, with a multiline hint and a bounded composer-strip cursor
  rectangle. X11 claims focus via `WM_TAKE_FOCUS` / FocusIn, resets compose
  on FocusOut, honors group bits 13–14, and refreshes GetKeyboardMapping on
  MappingNotify without dropping queued events. Wayland restores held
  Shift/Ctrl/Alt/Super from the keyboard-enter keys array. It does not
  speak XIM. Text and `file:` drops use XDND / `wl_data_device` and are
  injected as existing key events (no new Event variant); Wayland sends
  `data_offer.set_actions` copy when accepting a drop. Clipboard MIME
  includes `text/plain;charset=utf8`, `text/uri-list`, and
  `UTF16_STRING` / `text/plain;charset=utf-16` on receive, with UTF-8 BOM
  strip and UTF-16 decode. X11 paste prefers the owner's TARGETS list and
  stashes events that arrive during GetProperty. Central European Latin-2
  / named keysyms type without an IME. X11 re-reads `Xft.dpi` when the root
  `RESOURCE_MANAGER` property changes, falls back to screen millimeter
  size, and reinstalls the scaled cursor plus physical WM size hints.
  Wayland binds `wl_compositor` at v6 when advertised and honors
  `preferred_buffer_scale`. Both backends track maximized/fullscreen
  window state; X11 also tracks `_NET_WM_STATE_HIDDEN` and ICCCM
  `WM_STATE` / `WM_CHANGE_STATE`, and Wayland records tiled/suspended xdg
  states. When advertised, Wayland requests server-side decorations. X11 installs a scaled core cursor and `_NET_WM_ICON`, and
  `notify` sets urgency / `_NET_WM_STATE_DEMANDS_ATTENTION` until FocusIn.
  Wayland uses `wp_cursor_shape_v1` or a scaled shm arrow and
  `xdg_toplevel_icon_v1` when advertised. See `xkb.zig` and
  `compose_file.zig` for the exact parsing scope. Do not add an AT-SPI bus
  or a Wayland→X11 fallback.

## Change rules

- Keep rendering and platform presentation in Zig with no SDL. Onyx TLS at the
  exact `third_party/onyx-server` gitlink revision is the deliberate transport exception; do not
  replace it with an unpinned system library or weaken certificate checks.
- A source checkout must initialize that submodule with
  `git submodule update --init --recursive`. The published source archive
  already contains the pinned crypto, protocol, and certificate-loader subset
  used by ComicChat.
- Add focused inline tests and aggregate a new test-only module from
  `src/root.zig` when necessary.
- Do not add or redistribute AVB/BGB files without an exact source path,
  checksum, and applicable license. The current portable asset audit and Xeno
  import procedure are in `PORTABLE_ASSET_PROVENANCE.md`.
- Keep generated font changes reproducible through `tools/generate_font.py`
  and retain `src/render/COMIC_NEUE_LICENSE.txt`.
- Preserve unrelated working-tree changes. Use `zig fmt` for Zig edits and
  finish with `zig build test` plus `git diff --check`.

## Useful APIs

- `cc = @import("comicchat")` imports `src/root.zig`.
- `cc.assets.avb` and `cc.assets.bgb` parse source AVB/BGB records and images.
- `cc.comic.strip.render` / `renderWithOptions` produce source-layout pages.
- `cc.comic.original_figure.drawForTextLogical` draws authored AVB layers
  using source logical geometry.
- `cc.render.canvas.Canvas` is the shared RGBA software framebuffer.
- `cc.net.client.Client` provides IRC connect/register/join/message behavior;
  `cc.proto.record` handles Comic Chat tagged records.

The portable IRC transport defaults to verified TLS and port 6697. Plaintext
exists only behind the explicit `--plaintext` compatibility flag; there is no
automatic insecure fallback.

## Modern portable network boundary

Keep `src/net/` ownership-oriented and transport-independent above the socket:

- `message.zig` and `irc.zig` are immutable parse views plus bounded framing.
- `ircv3.zig` and `sasl.zig` are pure typed registration state machines.
- `features.zig` owns negotiated identity, ISUPPORT, label, echo, redaction,
  metadata, and nested BATCH state.
- `connection_policy.zig` owns bounded priority/backpressure queues, token
  buckets, deadlines, reconnect jitter, safe restoration, and proxy codecs.
- `transport.zig` owns the joinable async connector, bounded IPv6/IPv4 address
  race, real SOCKS5/HTTP CONNECT handshake, and winning-socket TLS handoff.
- `client.zig` is the only live composition layer; it advances registration
  from receive events and never waits synchronously for a CAP or SASL reply.
- `sts_store.zig` owns the bounded host policy database and atomic persistence.
- `proto/dcc.zig` owns the live comic-tag side protocols carried outside
  `.ccc` archives: the CTCP `DCC SEND` avatar/file offer (with its CTCP
  low-level quoting) and the stop-and-wait, ACK'd chunked transfer socket
  state machine (`sendFileControlled`/`receiveFileControlled`). `main.zig`
  owns the consent, progress, cancellation, listener readiness, exclusive
  destination, and worker lifetime; `client.zig` only serializes the offer.
- `proto/keystring.zig` owns IRCX semicolon-delimited client-data key strings,
  bounded pure property mutation, enumeration, and two-pass property diffing;
  `client.zig` owns typed PROP/ACCESS/LISTX/EVENT command serialization and the
  app owns their dialogs and visible replies.
- `client/preferences.zig` owns bounded, percent-escaped profile, backdrop,
  automation-rule, flood, and notification persistence. It replaces the old
  Windows Registry boundary and must never store credentials or certificates.

The native app opens its window before connection setup. `AsyncNetwork` polls
the connector, performs first-contact STS TLS upgrades, and schedules jittered
reconnects; platform event loops must never call the blocking compatibility
`Client.connectWithOptions` path.

Do not introduce mutable protocol globals, detached worker ownership, raw
credential logging, unbounded receive collections, or direct UI-to-socket
serialization. Parsed messages borrow framing storage; copy only the fields
that must survive the next receive into an owning bounded structure. Rendering
and comic-layout code must not depend on network transport details.
