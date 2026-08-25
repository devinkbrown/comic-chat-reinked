# Portable ComicChat Completeness Audit

**Date:** 2026-07-20
**Scope:** the complete repository, with product reachability evaluated from
the portable executable rather than inferred from module or test existence.

## Verdict

The repository contains a portable rendering, protocol, transport and
native-window foundation. The historical Microsoft source is an external,
pinned behavioral reference; it is not vendored. The portable desktop application now has an
interactive Microsoft-shaped shell, unified pointer/touch input, multi-room and
multi-window chat, Unicode/IME editing, an exhaustive dialog registry,
persistent automation and notification workflows, IRCX administration,
backdrop application, and owned DCC transfer state. All source-facing product
workflows are reachable or explicitly retired for security. The remaining
platform boundary is exposing the existing semantic accessibility tree through
full UIA/AT-SPI provider adapters; it is not a missing Microsoft Comic Chat
workflow.

This distinction is important:

- **Reachable** means a user can exercise the feature through `comicchat app`
  or a documented CLI subcommand.
- **Substrate** means a tested library implementation exists but the desktop
  application has no workflow that invokes it.
- **Partial** means the application exposes only part of the source contract.
- **Missing** means no portable implementation was found.

## Repository and build coverage

- The historical upstream checkout was previously verified against its pinned
  revision before this repository was migrated to the portable-only layout.
- The portable tree is rooted under `src/`. `src/root.zig`
  explicitly references every portable module and the four source-parity test
  modules so their inline tests are compiled and run.
- The current release test gate reports 440 passed tests and one intentionally
  skipped platform-conditional test.
- Native Linux plus first-class `x86_64-linux` and `aarch64-linux` targets,
  and x86_64 Windows, FreeBSD, and OpenBSD release builds pass.
- Published binaries are stripped so source paths and other build-machine debug
  metadata are not retained. The source archive includes the source tree and the crypto,
  protocol, and certificate-loader subset exported from the exact pinned Onyx
  revision. Binary archives contain only the executable, current documentation,
  licenses, and third-party notices.

## Product completeness matrix

| Area | State | Evidence and boundary |
|---|---|---|
| Repository shape | Portable-first | The live tree contains the Zig product, runtime assets, documentation, and tooling; the retired MFC/C++ source is external-only. |
| Source comic rendering | Reachable | Original page, title, layout, balloon, figure and raster modules feed the shared strip path; CLI render commands and the app use them. Golden/source-parity tests cover the rendering pipeline. |
| AVB/BGB content | Reachable | Authored character/backdrop decoding, icons, masks and figure composition are used by the renderer and UI. Program chrome uses modern glyphs; product art remains original. |
| Shell geometry | Reachable | The modern seven-menu/condensed-toolbar chrome retains the 29px tabs, 80/20 main split, 30/70 comic side split, 23px composer and status panes through shared geometry. |
| Comic/text buffers | Reachable | Both modes, one-to-six-column density, sparse/break-only geometry, history paging, range selection/copy/delete, page-break insertion, native Open/Save, atomic `.ccc` persistence, PNG export, and dependency-free PDF open/print are reachable. |
| Body camera | Reachable | The reimagined dial uses source thresholds. Pointer drag, touch, keyboard arrows/Home, Freeze, Character, Neutral, source-shaped double-click Character, and immediate `<Chr>` Send Expression are live. |
| Member list | Reachable | NAMES/JOIN/PART/QUIT/NICK/MODE update roster membership and voice/half-op/operator/owner badges. Icon/list modes, bounded scrolling, keyboard reveal, selection, character preview, and right-click actions are reachable. |
| Menus/toolbars/buttons | Reachable | Seven complete menus and the condensed toolbar route to typed workflows. Permission-aware Room/Member commands visibly disable and refuse activation for non-moderators. |
| Composer | Reachable | UTF-8-safe multiline editing, selection, mouse caret placement, native/internal clipboard fallback, undo/redo, source formatting controls, Windows IME, Wayland text-input-v3 commits, and the 400-byte per-line wire bound are live. |
| Live IRC/IRCX comic chat | Reachable core | Connect/register/reconnect, source-ordered two-stage IRCX discovery, multi-room JOIN/PART, password JOIN, CREATE/TOPIC, reasoned KICK/ban/invite, exact PROP/ACCESS/LISTX/EVENT workflows and visible replies, channel and private-message routing, source-exact IRCX `DATA CCUDI1` versus embedded UDI, raw comic action text, UDI talk-to recipients, SOUND/AWAY/information CTCP controls, avatar/profile/backdrop controls, and all five say modes are wired. |
| TLS, proxies, CAP, SASL, STS | Reachable | The live client composes verified TLS, proxy connection, IRCv3 negotiation, SASL and persisted STS. Credential input is file-based and refused over plaintext. |
| Resolver and sockets | Reachable | The Onyx DNS wire codec and resolv.conf policy drive hostname lookup. Pure-Zig native socket adapters cover Unix and direct Winsock; Wine falls back to the Windows DNS service only when direct UDP resolution is unavailable. No C transport or resolver source is shipped. |
| Onyx reusable sessions | Reachable | TOKEN/MTOKEN parsing, host/account-scoped persistence, expiry and resume preference are implemented in `src/net/session_store.zig:19-187` and connected through `ConnectionRuntime`. This supports separate same-account/same-nick clients when the server honors `SESSION RESUME`. |
| Modern IRC feature state | Reachable | `net/client.zig` owns `ircv3.Session` and `features.State`; visible server replies and Connection Features expose transport, SASL, IRCX, and enabled IRCv3 capability state. |
| Profiles/backdrops | Reachable core | Personal profile, display name, optional email/homepage, and selected backdrop persist in `.comicchat-preferences`. Member profile requests and replies are visible. Received bundled `BDrop`/`BDrop2` controls update the room renderer; remote backdrop and avatar downloads remain deliberately disabled. |
| DCC transfer | Reachable | Source-shaped DCC SEND offers and cumulative ACK loops are owned by a consent dialog and background worker. Native selection, exclusive bounded receive creation, no partial file, progress, cancellation, and validated send input are live. |
| IRCX key strings | Reachable protocol, separate substrate | PROP query/set/delete, ACCESS list/add/delete/clear, LISTX query/limit, and operator EVENT list/add/delete are live and use draft-exact wire grammar. The standalone key-string mutation/diff helper remains available for future structured CLIENT-property editing. |
| Automation rules | Reachable | Greeting/flood controls, persistent rules, rule sets, rename/assignment, bounded import/export, case matching, occurrence limits, and notify/reply/action/sound/join/ignore actions are live. |
| Notifications | Reachable | Persistent WHO masks drive transcript transitions, native desktop notification delivery, and refresh/clear/whisper/invite/join actions. |
| `.ccc` / `.ccr` | Reachable | Bounded codecs, native pickers, atomic conversation open/save, locator server/room/character/backdrop application, recent files, direct document startup, and optional file associations are live. |
| Multiple rooms/windows | Reachable | Up to 64 room tabs own independent state; favorites, commands, clickable tabs, and separately spawned room windows are live. |
| Microsoft dialogs | Reachable | All 40 historical templates plus 13 portable workflows have typed IDs, adaptive geometry, modal routing, validation, selection, live preview, native browse, and connected acceptance behavior. |
| Pointer/touch | Reachable | X11, Wayland, and Win32 share motion/button/wheel targeting; Wayland binds `wl_touch`, while Windows/X11 retain their native pointer-emulation paths. Linux backends install a default pointer cursor (X11 scaled core cursor; Wayland `wp_cursor_shape_v1` or a scaled shm arrow) and snap `axis_value120` wheels to the same ticks. |
| Clipboard/IME/accessibility | Reachable with adapter boundary | Windows Unicode clipboard/IME, X11 ICCCM `CLIPBOARD`/`PRIMARY` (INCR, UTF8_STRING then STRING/TEXT/GTK text MIME including `text/plain;charset=utf8`, `text/uri-list`, and `UTF16_STRING`, `TIMESTAMP`, `MULTIPLE` atom-pair requests, receive-only `text/html`, clipboard-manager handoff, UTF-8 BOM strip / UTF-16 decode / CR/LF→LF; paste prefers the owner's TARGETS list and a user ConvertSelection timestamp; XDND prefers TARGETS and the drop timestamp; middle-click pastes PRIMARY as typed keys), and Wayland `wl_data_device` plus `zwp_primary_selection_v1` are live, with `xclip`/`xsel`/`wl-copy` as fallback. Text and `file:` drops use XDND / `wl_data_device` and are injected as typed keys; Wayland sends `data_offer.set_actions(copy)` on accept and accepts UTF-16 and `text/html` text MIME on receive only. Middle-click pastes PRIMARY as typed keys. Keyboard enter refreshes text-input. Wayland accepts text-input-v3 commits with a multiline hint and composer-strip cursor rectangle, and de-dupes only the confirming keysym. X11 claims focus via `WM_TAKE_FOCUS`/FocusIn, resets compose on FocusOut, honors group bits 13–14 and MappingNotify, advertises `WM_LOCALE_NAME` plus `_NET_WM_ALLOWED_ACTIONS`, sets `_NET_WM_ICON` and `_NET_STARTUP_ID`, and raises urgency on `notify`. Wayland uses keymap group 2, restores held modifiers from the keyboard-enter keys array, applies Caps Lock from the conventional Lock modifier bit, consumes `XDG_ACTIVATION_TOKEN` via `xdg_activation_v1` for startup focus, requests server-side decorations when advertised (retrying SSD once on a CSD configure), coalesces `present()` behind `wl_surface.frame`, and sets `xdg_toplevel_icon_v1` when advertised. Named Armenian, Georgian, and Thai keysyms type without an IME. Both Linux backends track maximized/fullscreen window state; X11 also tracks hidden plus ICCCM `WM_STATE` / `WM_CHANGE_STATE` and skips Expose while fully obscured, and Wayland records tiled/suspended plus `wm_capabilities` / `configure_bounds` when xdg-shell is v5+. A full IME editor and AT-SPI/UIA provider transport remain out of scope. |
| DPI scaling | Reachable | Wayland tracks entered `wl_output` integer scale, `wl_surface.preferred_buffer_scale` when the compositor is bound at v6, output millimeter geometry when no scale event arrives, and `wp_fractional_scale_v1`/`wp_viewporter` when advertised, and refreshes the fallback shm cursor when that scale changes; X11 uses `GDK_SCALE`×`GDK_DPI_SCALE` / `QT_SCALE_FACTOR` / `QT_SCREEN_SCALE_FACTORS` / `Xft.dpi`, re-reads `Xft.dpi` on root `RESOURCE_MANAGER` changes, listens for RANDR `ScreenChangeNotify`, caches per-output millimeters so a window move can refresh integer scale, falls back to screen millimeter size, and reinstalls the scaled cursor plus physical WM size hints; both Linux backends size the default pointer from `XCURSOR_SIZE` / `Xcursor.size` / framebuffer scale; Win32 uses per-monitor-v2 logical geometry and scaled presentation. |
| Printing | Reachable | A dependency-free PDF 1.4 backend exports the current view; the print dialog can save, open, or submit it to the native desktop print service. |

## Source UI contract status

The implemented shell follows the Microsoft menu order and major geometry,
including its chat buffer composition and body camera. Modernization is limited
to application chrome: toolbar and say-window program icons/buttons are modern;
characters, backdrops, panels and emotion-face art remain authored source art.

The portable UI must not be called complete until each of these source-facing
contracts is either reachable or deliberately classified obsolete:

1. Source-facing Microsoft workflows must remain reachable or explicitly
   classified as retired for security.
2. The stable semantic tree must stay aligned with draw/hit geometry while
   native UIA/AT-SPI provider work proceeds independently.

## Verification performed

```text
PASS  zig fmt --check build.zig source_ui_assets.zig src
PASS  zig build test --summary all
PASS  zig build --summary all
PASS  zig build -Dtarget=x86_64-windows -Doptimize=ReleaseSafe
PASS  zig build -Dtarget=x86_64-linux -Doptimize=ReleaseSafe
PASS  zig build -Dtarget=aarch64-linux -Doptimize=ReleaseSafe
PASS  zig build -Dtarget=x86_64-freebsd -Doptimize=ReleaseSafe
PASS  zig build -Dtarget=x86_64-openbsd -Doptimize=ReleaseSafe
PASS  git diff --check
PASS  portable-only tree contains no retired MFC/C++ source directory
PASS  record-codec demo, 650x1655 strip PPM, and 315x315 backdrop PNG
PASS  all 53 dialogs at 640x480, 800x600, and 960x720 without field/action overlap
PASS  every compact menu popup and command row remains on-screen and clickable
PASS  Xvfb X11 menu, Settings input/Tab, Escape, and composer event smoke
PASS  headless Wine live TLS connect, status dialog, native Open picker,
      reconnect, member scroll/select/context menu, top menu, and composer input
PASS  six Linux/Windows deterministic UI surfaces are byte-identical
PASS  release archive checksums verified for all four binary packages and the
      source archive containing the required pinned Onyx TLS source subset
```

Environment-only acceptance still required for a supplied client certificate:
a live `eshmaki.me` SASL EXTERNAL login and two simultaneous same-nickname
session attachments, plus physical Windows and real-compositor Wayland assistive
technology checks. No personal certificate is embedded or retained by this
repository or its release packages.
