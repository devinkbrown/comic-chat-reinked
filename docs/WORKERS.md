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
  keysym is listed, plus groups 2–4 when extra keysym lists are published),
  implements client-side key-repeat (`repeat_info` + `Window.checkRepeat`),
  and applies a bounded dead-key / Multi_key composer plus optional XCompose
  locale tables (`XCOMPOSEFILE`, `~/.XCompose`, system `%L`, capped file
  size/entries/include depth). A US evdev fallback remains before the first
  keymap arrives or for an out-of-scope keysym. Do not claim a full
  input-method editor — committed IME text uses text-input-v3 when
  advertised, with a multiline hint and a bounded composer-strip cursor
  rectangle.   X11 claims focus via `WM_TAKE_FOCUS` / FocusIn, resets compose
  on FocusOut, honors group bits 13–14, refreshes GetKeyboardMapping on
  MappingNotify without dropping queued events, and reads GetModifierMapping
  so Caps Lock, NumLock, Mode_switch, AltGr, and Super follow the server's
  modifier map (including MappingNotify request 0). Wayland restores held
  Shift/Ctrl/Alt/Super from the keyboard-enter keys array and Caps Lock
  from the conventional Lock modifier bit when the compositor reports it,
  honors XKB groups 3–4 with wrap, and refreshes text-input on keyboard enter
  and xdg activate (disabling it when the toplevel is not activated).
  It does not
  speak XIM.   X11 maps XI2 touch contacts to the shared pointer contract when the
  device is not pointer-emulating. Text and `file:` drops use XDND / `wl_data_device` and are
  injected as existing key events (no new Event variant); Wayland sends
  `data_offer.set_actions` copy when accepting a drop and
  `data_offer.finish` after every drop when `wl_data_device_manager` is
  bound at v3+ (including failed or empty offers). Clipboard MIME
  includes `text/plain;charset=utf8`, `text/uri-list`, receive-only
  desktop file-list MIME (`x-special/gnome-copied-files`,
  `x-special/nautilus-clipboard`, `text/x-moz-url`, `application/x-moz-file`,
  `application/x-kde4-urilist`), and
  `UTF16_STRING` / `text/plain;charset=utf-16` / `utf16` on receive, with UTF-8 BOM
  strip and UTF-16 decode. `file:` URIs whose host is localhost, `127.0.0.1`,
  `[::1]`, or this machine's `uname` nodename decode to a local path. Receive-only `text/x-uri-list` is treated like
  `text/uri-list`. Receive-only `text/rtf` / `application/rtf` strip to
  plain text. X11 paste prefers the owner's TARGETS list and
  stashes events that arrive during GetProperty (up to 256 during ConvertSelection / INCR). ConvertSelection uses a
  user timestamp rather than CurrentTime. XDND also prefers TARGETS and
  uses the drop timestamp. Middle-click pastes PRIMARY as typed keys, with
  `wl-paste --primary` / `xclip`/`xsel` PRIMARY fallback when the native
  protocol is missing. Shift+Insert and XF86Paste paste CLIPBOARD as typed
  keys. CLIPBOARD paste does not fall through to PRIMARY, and local
  CLIPBOARD text is used only while this client still owns CLIPBOARD, and
  PRIMARY paste uses local text only while this client still owns PRIMARY.
  ConvertSelection / INCR stashes up to 256 intervening events. A
  Wayland copy before the first seat serial is advertised once a serial
  arrives.   Pointer leave and incoming DnD motion emit pointer moves so
  hover tracks the seat; LeaveNotify / `wl_pointer.leave` emit `.up` for a
  held button before `(-1,-1)`, and XdndLeave
  moves to `(-1,-1)` to clear hover. X11 EnterNotify with Button1 or Button3
  already down emits `.down` then queues the hover move (middle is not
  synthesized). Implicit-grab MotionNotify after LeaveNotify does not
  restore hover, and a later ButtonRelease for an already-released button
  is dropped. X11 Enter/Leave ignore grab/ungrab
  modes, and FocusIn/Out ignore grab/ungrab plus pointer-focus details.
  X11 wheel button releases do not emit pointer up. NumLock XOR Shift selects keypad
  digits on both backends. X11 Mod3 Mode_switch selects group 2.
  Receive-only `COMPOUND_TEXT` decodes to UTF-8, including `ESC - B`
  ISO-8859-2, `ESC - C` ISO-8859-3, `ESC - D` ISO-8859-4, `ESC - b`
  ISO-8859-15, `ESC - M` ISO-8859-9, `ESC - L` ISO-8859-5, `ESC - F`
  ISO-8859-7, `ESC - G` ISO-8859-6, and `ESC - H` ISO-8859-8. Invalid UTF-8 clipboard bytes
  decode as Latin-1, including incoming DnD and Shift+Insert / middle-click
  paste-as-keys. Receive-only ISO-8859-1/2/3/4/5/6/7/8/9/13/15, Windows-1250/1251/1252/1253/1254/1255/1256/1257, and KOI8-R `text/plain` charset MIME
  (both common casings on X11, plus `latin1`/`latin9`/`latin5`/`latin2`/`cyrillic`/`greek` aliases and the bare `KOI8-R` target) and Markdown decode to UTF-8. X11 extra
  mouse buttons 6–9 do not synthesize pointer clicks. Extra KDE5 / Mozilla-priv / KDE suggested-filename file MIME yields a local
  path. Receive-only `text/html` strips tags to plain text.
  Clipboard text normalizes
  CR/LF to LF. `notify-send` uses `--urgency=normal` and
  `--icon=applications-internet`.   Central European Latin-2, Latin-3, Latin-4, Latin-9, Greek, Hebrew, Arabic,
  Armenian, Georgian, Thai, extra Ukrainian/Belarusian/Serbian/Macedonian
  Cyrillic,
  and named keysyms type
  without an IME. X11 paste also serves ICCCM `MULTIPLE` atom-pair
  requests.   X11 re-reads `Xft.dpi` when the root `RESOURCE_MANAGER`
  property changes, reads XSETTINGS `Gdk/WindowScalingFactor` / `Xft/DPI`
  and re-watches the XSETTINGS owner after DestroyNotify or a scale refresh
  (that owner's DestroyNotify does not close the chat; only the toplevel
  DestroyNotify closes, and a destroyed `_NET_WM_USER_TIME_WINDOW` is recreated),
  maps XI2 touch to pointer events when the device is not pointer-emulating,
  listens for RANDR `ScreenChangeNotify`, caches
  per-output millimeters so a window move can refresh integer scale,
  skips Expose while `VisibilityFullyObscured`, falls back to
  screen millimeter size, and reinstalls the scaled cursor plus physical
  WM size hints. Wayland binds `wl_compositor` at v6 when advertised,
  honors `preferred_buffer_scale`, refreshes the fallback shm cursor and
  toplevel icon when `wp_fractional_scale_v1` preferred scale changes, and can derive integer scale from
  output geometry millimeters when no scale event arrives. `axis_stop` clears
  the discrete wheel latch. Keyboard enter
  arms client-side repeat for a held non-modifier key.   Both backends track maximized/fullscreen
  window state; X11 also tracks `_NET_WM_STATE_HIDDEN` / `_NET_WM_STATE_SHADED` and ICCCM
  `WM_STATE` / `WM_CHANGE_STATE` and skips `present()` while NET hidden, ICCCM
  iconic, unmapped, shaded, or fully obscured (MapWindow reads the initial
  `_NET_WM_STATE` / `WM_STATE`; MapNotify exposes; a `_NET_WM_STATE`
  without HIDDEN cannot clear ICCCM Iconic), and Wayland records tiled/suspended xdg
  states plus `wm_capabilities` / `configure_bounds` when xdg-shell is v5+
  and skips `present()` while suspended (leaving suspended or gaining
  activated exposes). X11 FocusIn, leaving hidden, and gaining `_NET_WM_STATE_FOCUSED` expose.
  X11 publishes `_NET_WM_USER_TIME` on a dedicated `_NET_WM_USER_TIME_WINDOW` as well as the toplevel.
  When advertised, Wayland requests server-side decorations and
  re-requests SSD once if the compositor configures client-side mode.
  `present()` waits for `wl_surface.frame` before the next commit. X11 installs a scaled core cursor, `_NET_WM_ICON` at 16/32/64/128, and an ICCCM `WM_HINTS` icon pixmap/mask at 32@1 / 64@2 (reinstalled on scale change), and
  `notify` sets urgency / `_NET_WM_STATE_DEMANDS_ATTENTION` until FocusIn or
  gaining `_NET_WM_STATE_FOCUSED`.
  Wayland uses `wp_cursor_shape_v1` or a scaled shm arrow and
  `xdg_toplevel_icon_v1` (32@1 plus 64@2, reinstalled on integer scale change) when advertised. Wayland consumes
  `XDG_ACTIVATION_TOKEN` via `xdg_activation_v1` and requests a fresh token
  for `xdg-open`; X11 sets `_NET_STARTUP_ID`
  from that token or `DESKTOP_STARTUP_ID`, sends the startup-notification
  remove ClientMessage after MapWindow, and exports a unique startup id
  when opening a path. EnterNotify reinstalls the scaled
  cursor and emits a pointer move; XDND Position translates root
  coordinates into a local hover move. See `xkb.zig` and
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
