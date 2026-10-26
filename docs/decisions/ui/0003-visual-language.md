# UI 0003: Visual language — light and dark, icons over text badges, less chrome

Date: 2026-10-26 · Tasks: T43, T44, T45 (Milestone K) · Status: **Adopted.**
Source: design review 2026-10-23 (13:03–14:11 light mode; 08:05–08:20 and 14:00–14:11 "lighter weight, smaller
text, lots of small informative icons, less skeuomorphic").

## Tokens
| Token | Where | Light | Dark |
|---|---|---|---|
| `Color.statusOK` | healthy source, audio saved, models verified | `#1E7B34` | `#30D158` |
| `Color.statusAttention` | needs a look: gaps, flags, stale notes, clipping, interrupted, low disk | `#A84F00` | `#FF9230` |
| `Color.statusFailed` | failed or not recording: recording dot, failed processing, permission denied | `#C81E1E` | `#FF6961` |
| `Color.link` | clickable times (system `linkColor`) | `#0068DA` | `#419CFF` |
| Speaker discs | `AppPalette.speakers`, one set for both appearances | 8 hues at equal luminance | same |
| Text, backgrounds, separators | system semantic colours (`.primary`, `.secondary`, `windowBackgroundColor`, …) | system | system |
| Type | `AppStyle.Role` (T36): 10–17 pt, scaled by Settings → Appearance → Text size | | |
| Spacing | `AppStyle.half/grid/double`: 4 / 8 / 16 pt | | |
| Inline icons | `AppStyle.iconSmall/icon/iconLarge`: 11 / 12 / 13 pt, scaled with text size | | |

Status colours are defined in `Presentation/AppPalette.swift` and checked by `Tests/UI/PaletteContrastTests.swift`:
≥ 4.5:1 against the window background, the under-page background and their own 12 % tint, in both appearances;
white initials ≥ 4.5:1 on every speaker disc and each disc ≥ 3:1 against both window backgrounds. The stock
`systemGreen`/`systemOrange` are about 2:1 on white, which is why they are no longer used for text.
Apple's own `secondaryLabelColor` (≈ 3.9:1 on white) is kept as is: it is the platform convention for secondary text
and changing it would make Amaranth look unlike other Mac apps.

## Appearance
Settings → Appearance → Appearance: Match system (default) / Light / Dark, stored as `appearance` and applied with
`NSApp.appearance`, so the main window, Settings and the menu-bar menu follow it. The toolbar sun/moon button (sun in
dark mode, moon in light mode; trailing, before Export) and View → Switch to Light/Dark Mode (⌘⇧L) store the
opposite of what is on screen; Match system remains in Settings.

## Icon conventions
- SF Symbols only (no emoji or custom SVGs yet). Every icon that stands alone has a tooltip and a VoiceOver label
  that says in words what the icon means.
- Source of a line: `mic.fill` (your microphone) / `speaker.wave.2.fill` (system audio), secondary colour, replacing
  the "MIC"/"SYS" text badges (transcript Details, live text, health popover).
- Transcript flags (overlap, speaker uncertain, echo, check text, edited) are icon-only in both modes, in the attention
  colour; the tooltip explains, the caption is the VoiceOver label.
- Recording strip: Pause/Resume icon-only (tooltip names the shortcut); Stop and Save keeps its words.
- Toolbar and header controls (ⓘ Details, sun/moon) are 13 pt; onboarding's welcome icons stay larger (a one-off
  screen, not part of the working UI).

## Less chrome
- Notes state banners are one line with icon, text and a small button; no box.
- Your notes / Private scratchpad: no GroupBox around the editor (the editor draws its own field border).
- The recorder banner above the detail pane keeps its bar background: it carries errors and permission problems.

## What stays textual (safety-relevant)
Anything about missing audio, recording permission or failed processing keeps words on screen, not only an icon:
the recorder banner (errors, permission denied, missing microphone, recovery), "Stop and Save", the "Interrupted"
label in the strip, the notes "could not be generated" and "regenerating failed" banners, transcript gap rows with
Details on, the header's Audio and Processing badges with Details on, the health popover's per-source status text,
and the Recording tab (out of scope, unchanged). Where a safety state is shown as a glyph for density (the sidebar
status glyph from T27, the strip's source glyphs from T31), it already has a tooltip and VoiceOver label, and the
words are one click away (header badges, health popover).

## Known limitations
- Offscreen ui-render captures can't draw sidebar vibrancy, so the main-window captures show an empty sidebar; the
  sidebar has its own capture.
- The menu-bar menu is rendered as a stand-in view (its items), not the real system menu.
- The View-menu title "Switch to Light/Dark Mode" is computed when the menu is built; if the system flips appearance
  while Match system is chosen, the title updates the next time the menu opens.

Evidence: `docs/qualification/evidence/2026-10-26/appearance/{light,dark}/` (every screen),
`docs/qualification/evidence/2026-10-26/t45/` (before/after, both appearances).
