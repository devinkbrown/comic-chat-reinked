# Desktop UI library

Comic Chat's desktop chrome is rendered by the portable Zig UI library in
`src/client/ui.zig`. Native X11, Wayland, Win32, FreeBSD, and OpenBSD backends
all present the same framebuffer and therefore share the same interaction and
visual contract.

## Design contract

- Application chrome uses the embedded neutral sans-serif atlas in
  `src/render/font_ui.zig`. Comic Neue is reserved for authored comic content.
- The desktop product is **Ink Sunday**: warm newsprint, vermillion speech
  accents, ink frames, and a speech-balloon brand. Fluent cobalt chrome is
  retired. Accents remain cobalt/vermillion, violet, or forest, with optional
  high-contrast text/border treatment. Dark mode is an ink studio around
  deliberately stable light comic and character-art paper; authored raster
  pixels are never inverted or post-processed.
- The established 80/20 conversation/inspector and 30/70 member/character
  proportions remain recognizable, while control heights and spacing are
  sized for a modern desktop.
- The radial mood dial remains the signature interaction. It supports direct
  click, captured drag, arrow-key adjustment, Home-to-neutral, a visible
  intensity puck, and a right-click Freeze/Character/Neutral menu.
- Mood expressions use a newly drawn, high-contrast face set with consistent
  geometry rather than the original tiny pixel marks.
- The conversation well is a printed 1:1 comic page: newsprint matte, a double
  ink frame with vermillion corner ticks, and source-faithful strip pixels
  inside. Chrome never redraws balloons or figures. An empty conversation still
  routes through `strip.render` and only overlays a caption balloon. At minimum
  window sizes the caption collapses to a compact instruction instead of
  overflowing the available buffer. Structural chrome strokes stay at least
  two framebuffer pixels (`ui.stroke`) so nearest-neighbour 2x/3x HiDPI scale
  keeps masthead rules, page ticks, and plate frames readable. CAST portraits
  keep the same bottom-aligned blit; only the playbill plate around them is
  chrome.
- Shell chrome is an ink masthead, paper tool rack, playbill inspector headers,
  and a caption-box composer. Dialogs use the same masthead as the application.
- Comic pages default to four panels across. The room strip exposes an
  accessible minus/plus stepper for live one-to-six-column density changes;
  rendered pages remain top-aligned as conversation history grows. Desktop
  pages reserve the selected column count even when a row contains only one
  message or a break control, preventing sparse panels from being scaled to
  the full buffer.
- Draw geometry, pointer targets, focus, and accessibility bounds must derive
  from the same layout values.
- The desktop surface enforces a 640x480 minimum. Below 760 pixels wide the
  inspector collapses so the composer and comic buffer remain usable.
- Roster and character previews use alpha-aware smooth scaling and larger
  portrait targets. Authored art inside comic panels stays source-faithful.
- The inspector is one continuous rail rather than nested gray cards. Members
  support icon/list modes, keyboard roving, wheel scrolling, retained viewport
  position, selection, hover, and context menus. Visible cards always map back
  to their actual live-roster entry after scrolling.
- History and long rosters expose deterministic scroll position indicators.
- Dialog fields are typed: text, password, choice, list, preview, and read-only
  controls render and interact according to their actual purpose. The shared
  input surface includes hover and focus states, a focus halo and baseline,
  secure-entry adornment, an explicit caret-to-placeholder gap, selection,
  mouse caret placement, horizontal caret tracking for long values, and
  visible validation. `DialogLayout` reserves a dedicated notice/progress row
  so a five-field transfer or administration dialog cannot paint validation
  over its final input or action buttons. Character and backdrop choices cover
  every bundled asset and show live previews.
- The condensed toolbar is intentionally modern; commands that do not belong
  in the primary strip remain reachable through menus and context actions.
  File, Edit, View, Format, Room, Member, and Tools each have one distinct
  responsibility: Settings appears once in Edit, connection management once in
  Tools, and file transfer once in Member.
- The Status tab and bottom connection strip open a shared, keyboard-dismissable
  activity panel. It reports connection state, active members, view density,
  member presentation, and studio appearance without covering the composer.
- Settings uses eight persisted choices and scrolls its field viewport at the
  640x480 minimum. Character selection provides adjacent-cast browsing, a live
  expression choice, larger source-faithful portraits, selectable Color avatar
  variants, and contained actions. The gallery resolves the same native AVB
  selected at runtime, so a color portrait cannot silently fall back to a
  monochrome preview. Its adjacent cards always wrap within the selected
  HD, Color, or Original family; previews never mix body, head, or color
  treatments from different families. A compact segmented family selector
  switches between them while retaining the current identity. HD and Color are
  the normal avatar families; Original is a compatibility choice.

The desktop inspector, roster, and character chooser resolve a plain legacy
identity to its generated HD presentation avatar. This is deliberately a
client-view mapping: the source-faithful comic strip renderer keeps its pinned
historical assets and golden-raster contract.
- Popup rows expose disabled states for role-gated moderation commands. Member
  rows and cards show live IRC role badges without modifying authored art.
- File-path controls use the same input geometry with a distinct Browse action;
  the action opens the native platform picker and never makes the full field
  look hovered.

## Keyboard and semantic contract

The framebuffer UI exposes the same interactive model to keyboard users and
native accessibility adapters. Tab order includes the menu/navigation region,
the compact toolbar, transcript, composer, message-mode tiles, member rail,
and comic emotion dial when visible. Toolbar and message-mode tiles use a
roving focus: Arrow keys and Home/End move the visible focus ring, and Enter
invokes the same action as a pointer click. Context menus own Arrow, Home/End,
Enter, and Escape until dismissed; disabled moderation rows are never chosen.

Modal dialogs keep background controls out of the semantic tree. Browse is an
individual button after its file-path field. The character picker exposes its
HD/Color/Original family segments and previous/current/next cards as separate
controls. The semantic snapshot has a bounded 256-node capacity and records
truncation so adapters can fail visibly instead of silently losing controls.

## Reusable primitives

`Theme` defines the canonical light values; `Appearance`, `Palette`, and
`paletteFor()` resolve the active draw-time color set. `ControlState` and
`resolveControlColors()` define normal, hovered, selected, focused, pressed,
and disabled behavior. New screens should compose the existing primitives:

- `drawSurface`, `drawRoundedBorder`, and `fillRoundedRect`
- `drawAaDisc`, `drawAaLine`, `drawAaRing`, and `drawAaCircleOutline` for
  supersampled compact icon artwork
- `drawButton`, `drawCommandTile`, `drawActionTile`, and `drawFocusRing`
- `drawPill`, `drawTooltip`, `drawTooltipWithHint`, `drawNotice`, `drawDialogActionBar`, and `drawHistoryBanner`
- `drawDialogFieldLabel`, `drawMenuGroupDivider`, and `drawContentHeading` for
  consistent dense-form, popup, and information hierarchy
- `drawEmptyStateCallout` for stable empty-workspace and empty-roster guidance
- `drawInputControl`, `InputKind`, `InputState`, `drawComposerField`, and
  `DialogLayout`
- `drawTextSelection`, `drawTextCaret`, `drawTextOverflowMark`, and
  `drawBrowseButton` for editable field adornments
- `drawBrandMark`, `drawPageWell`, `drawInkChip`, `drawInkPlate`, `drawInkRule`, `drawMemberRailSurface`, `drawStatusIdentity`, and
  `drawPreviewChoiceCard` for shell identity, the printed page well, playbill chips, and compact client surfaces
- `drawAppBrand`, `drawPaneCountHeader`, and `drawDismissHint` for stable
  shell identity, inspector headers, and temporary-popover keyboard guidance
- `drawSegmentedChoice` for direct gallery-family selection without a long
  cycle through unrelated asset variants
- `drawStatusTabContent`, `drawConversationTab`, `drawLabeledStepper`, and
  `drawStatusMetric` for the active-room navigation and activity surfaces
- `StatusPanelLayout` and `drawEllipsized` for responsive activity geometry
  and one consistent text-overflow treatment across every client surface
- `drawAnchoredPopoverSurface` and `drawStatusMetricCard` for temporary
  shell feedback with a visible origin and scannable information hierarchy

All application labels use `drawEllipsized`, which preserves complete words
when truncation is necessary. Optional identity chips are hidden when their
full nickname cannot fit; they are never rendered as a clipped word.
- `ToolGlyph`, `SayGlyph`, `drawToolGlyph`, and `drawSayGlyph` for every
  palette-aware toolbar and composer icon. Their shared anti-aliased stroke
  weight and tile state treatment are the application icon system; icon colors
  must come from the active palette rather than hard-coded RGB values.
- `MoodGlyph` and `drawMoodGlyph` for the full nine-expression radial dial;
  its selected and resting faces inherit the active application palette.
- `moodDialInterior` and `drawMoodDial` for the complete radial control,
  sharing exact visual and pointer bounds across client rendering and input.
- `PopupLayout` and `drawPopupListSurface` for menu and context popups that
  share clamped bounds, row targets, and surface treatment.
- `ToolbarLayout` for common group, command, hit-test, and tooltip geometry.
- `AssetPreviewLayout` and `drawAssetPreviewFrame` for decoded character and
  backdrop content framed by one responsive preview treatment.
- `ComposerEditorLayout`, `drawComposerEditor`, and
  `drawComposerOverflowMarks` for one composer surface with aligned content,
  selection, caret, and overflow geometry.
- `drawMenuItem`, `drawTab`, `drawMemberCard`, and `drawMessageRow`
- `drawPaneHeader`, `drawExpressionPanel`, and `drawStatusBar`
- `drawInspectorRail` and `drawVerticalScrollbar`

Do not add ad-hoc colors or use Comic Neue for application controls. Add a
token or reusable primitive when a new state is genuinely required.

`drawMessageRow` uses a responsive fixed speaker rail: this aligns transcript
copy across rows and keeps ordinary nicknames whole without allowing each row
to push its message column to a different horizontal position.

## Conversation component index

The first fifty stable building blocks are cataloged below.  New room surfaces
should compose these instead of drawing ad-hoc rectangles; the conversation
set carries room state, local-speaker treatment, and catch-up state through the
same themed palette.

1. `Palette`; 2. `Appearance`; 3. `paletteFor`; 4. `activateAppearance`;
5. `ControlState`; 6. `resolveControlColors`; 7. `contains`;
8. `fillRoundedRect`; 9. `drawRoundedBorder`; 10. `drawAaDisc`;
11. `drawAaRing`; 12. `drawAaCircleOutline`; 13. `drawAaLine`;
14. `drawSurface`; 15. `drawPill`; 16. `drawTooltip`; 17. `drawButton`;
18. `drawModalBackdrop`; 19. `drawDialogSurface`; 20. `drawNotice`;
21. `drawInputControl`; 22. `drawCommandTile`; 23. `drawActionTile`;
24. `drawFocusRing`; 25. `drawStepper`; 26. `drawVerticalScrollbar`;
27. `drawMenuItem`; 28. `drawMenuLabel`; 29. `drawMenuBarSurface`;
30. `drawToolbarSurface`; 31. `drawToolbarGroup`; 32. `drawPopupSurface`;
33. `drawToolbarSeparator`; 34. `drawSplitter`; 35. `drawContentSurface`;
36. `drawTabStrip`; 37. `drawStatusTab`; 38. `drawTab`; 39. `drawStatusBar`;
40. `drawConversationPresenceDot`; 41. `drawConversationTitle`;
42. `drawConversationSummary`; 43. `drawConversationStateBadge`;
44. `drawConversationRule`; 45. `drawConversationHeader`;
46. `drawMessageRow`; 47. `drawMemberRow`; 48. `drawMemberCard`;
49. `drawPaneHeaderReserved`; 50. `drawComposerField`.

## Deterministic visual checks

The renderer can produce exact previews without a display server:

```sh
zig build run -- render-ui > ui-preview.png
zig build run -- render-ui conversation > ui-conversation-preview.png
zig build run -- render-ui sparse > ui-sparse-preview.png
zig build run -- render-ui break-only > ui-break-preview.png
zig build run -- render-ui menu > ui-menu-preview.png
zig build run -- render-ui settings > ui-dialog-preview.png
zig build run -- render-ui inputs > ui-input-preview.png
zig build run -- render-ui composer > ui-composer-preview.png
zig build run -- render-ui composer-multiline > ui-composer-multiline-preview.png
zig build run -- render-ui character > ui-character-preview.png
zig build run -- render-ui context > ui-context-preview.png
zig build run -- render-ui hover > ui-hover-preview.png
zig build run -- render-ui say-hover > ui-say-hover-preview.png
zig build run -- render-ui member > ui-member-preview.png
zig build run -- render-ui compact > ui-compact-preview.png
zig build run -- render-ui compact-menu > ui-compact-menu-preview.png
zig build run -- render-ui compact-settings > ui-compact-settings-preview.png
zig build run -- render-ui dark > ui-dark-preview.png
zig build run -- render-ui dark-settings > ui-dark-settings-preview.png
zig build run -- render-ui compact-dark-settings > ui-compact-dark-settings-preview.png
zig build run -- render-ui dark-character > ui-dark-character-preview.png
zig build run -- render-ui status > ui-status-preview.png
zig build run -- render-ui compact-status > ui-compact-status-preview.png
zig build run -- render-ui dark-status > ui-dark-status-preview.png
zig build run -- render-ui multi-tabs > ui-multi-tabs-preview.png
zig build run -- render-ui compact-multi-tabs > ui-compact-multi-tabs-preview.png
zig build run -- render-ui mood-laughing > ui-mood-laughing-preview.png
zig build run -- render-ui dialog-file_transfer > ui-transfer-preview.png
zig build run -- render-ui dialog-room_access > ui-access-preview.png
```

These previews exercise the empty shell, real comic content, menu surface, and
modal surface, populated account/password controls, composer overflow, member
selection, and narrow responsive geometry. The generic `dialog-<enum_name>`
form renders any registered dialog with the exact shared geometry; specialized
sample data is included for IRCX, DCC, automation, notification, profile, and
call-link workflows. Multi-tab captures reserve the density stepper and keep a
later active room visible; the laughing-mood capture exercises the longest
expression chip in the narrow inspector. Run `zig build test --summary all`
with them; pixel checks cover the shell palette and dial while semantic tests
cover control geometry.

The UI acceptance gate also exercises all 53 registered dialogs at 640x480,
800x600, and 960x720; every menu row at the 640px minimum; Debug and
ReleaseSafe tests; native X11 menu/dialog/composer input under Xvfb; and the
same live Win32 interaction path under headless Wine. The Wine path also
exercises status-bar connection setup, invalid-port recovery, verified-TLS
reconnect, live member scrolling/selection/context actions, Settings, Room
List, User List, Comic View density, sparse-page geometry, and composer input.
Linux and Windows `render-ui` output must remain byte-identical for the main,
compact menu, settings, password input, long composer, and conversation
surfaces.

## Font regeneration

The UI atlas is generated from OFL-licensed Liberation Sans Regular:

```sh
python3 tools/generate_ui_font.py /path/to/LiberationSans-Regular.ttf
```

The generator verifies the pinned source hash. Licensing is recorded in
`src/render/LIBERATION_SANS_LICENSE.txt`.
