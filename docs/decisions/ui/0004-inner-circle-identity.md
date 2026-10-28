# UI 0004: Inner Circle / Forest identity

Date: 2026-10-27 · Status: **Adopted.** Supersedes the colour tokens and type sizes of [UI 0003](0003-visual-language.md);
its icon-over-badge and less-chrome rules still apply.
Source: the approved design handoff in `docs/design-handoff/` (package 1.0.0: `AGENT_INSTRUCTIONS.txt`,
`Design/tokens.json`, `Preview/index.html`).

## Choices made with the user (2026-10-27)
- **Type scale:** the handoff's sizes are the Default text size (14 pt body, 12 pt metadata, 25 pt meeting title in
  Arial Rounded MT Bold, nothing essential under 11 pt). This replaces T36's compact density. Smaller (0.9×) and
  Larger (1.2×) still scale from it.
- **Ask:** a collapsible right-hand pane (`.inspector`, 230–380 pt, 250 ideal) instead of the bottom bar and its
  floating results. Same field, scope, answers and matches. ⌘K opens the pane and focuses the field. Opening a match
  keeps the results, so the next one is a click away.
- **Record:** still one click (speed-first, T31). The chevron's options popover is the handoff's setup surface:
  heading, labelled fields, "Audio and transcription stay on this Mac", one Start recording button.
- **App icon:** a layered `App/Resources/Amaranth.icon` hand-written from `Icons/Composer` (wine tile with a cream
  ring in light, Forest tile with a blush ring in dark, sage seed, system glass). actool builds light, dark and tintable
  stacks plus a flattened `.icns`. **Not verified here:** how the Clear and Tinted looks render; check them in Icon
  Composer or the Dock. The fixed Forest `AmaranthAppIcon` set was not imported (one icon source only).

## Tokens
Named colours in `App/Resources/Assets.xcassets` (Any = light, Dark = dark), mirrored in `Presentation/AppPalette.swift`
for `Tests/UI/PaletteContrastTests.swift`. That test also checks that the catalog and the palette agree.

| Asset | Swift | Use | Light | Dark |
|---|---|---|---|---|
| AmaranthCanvas | `Color.canvas` | sidebar, playback strip, Ask pane, notices | `#F3ECE5` | `#1D2621` |
| AmaranthSurface | `Color.surface` | notes, transcript, fields, dialogs | `#FFFAF5` | `#28342C` |
| AmaranthText | `Color.brandText` | primary copy | `#382A2F` | `#F5F0E6` |
| AmaranthSecondaryText | `Color.brandSecondary` | metadata | `#716068` | `#B9C3B5` |
| AmaranthAccent | `Color.brandAccent`, `Color.link`, global accent | tabs, links, playback, focus, primary actions | `#752C44` | `#E3A4B6` |
| AmaranthSage | `Color.sage`, `Color.statusOK` | local status, decisions edge | `#416552` | `#A5C5A2` |
| AmaranthControlBorder | `Color.controlBorder` | outlines, hairlines | `#97828B` | `#738375` |
| AmaranthSelection | `Color.selection` | selected meeting/match/jumped-to line, with a 3 pt accent edge | `#E9DCD9` | `#3C4138` |
| AmaranthOnAccent | `Color.onAccent` | labels on a filled accent button | `#FFFAF5` | `#28342C` |
| AmaranthWarning | `Color.statusAttention` | audio gaps, flags, details to confirm | `#8D431A` | `#EDB48B` |
| AmaranthDanger | `Color.statusFailed` | destructive actions, failures, record dot | `#9A343E` | `#EDB0B9` |

Speaker discs keep their eight hues in light. In dark they are mixed toward cream with forest initials, because the
Forest surface is too light for the deep discs (2.6:1). The selected sidebar row draws its metadata in the text colour,
because secondary text is 4.39:1 on Selection in light.

Controls that macOS would fill with the accent and label in white (the segmented control, `.borderedProminent`, the
button-style toggle, the `List` key-window selection) are drawn with `BrandSegmented`, `.brandProminent`,
`BrandChipToggleStyle`, and the custom library list, all in `App/Shared/BrandStyles.swift` and `LibraryView.swift`.
White on the dark-mode blush is about 1.6:1.

## Layout
- Library: 160–320 pt (200 ideal), grouped by day (Today, Yesterday, weekday, date), each row "9:30 AM · 24 min".
  Rows are buttons in a focusable list (↑/↓ move, selected trait for VoiceOver). A quiet "Processing on this Mac"
  sits at the bottom.
- Meeting header: eyebrow date and time, rounded title, then people, calendar, length and status. Export and the
  delete menu moved here from the toolbar (the handoff's share access in the header). Tabs are underlined: Notes ·
  Transcript · Audio details. Playback (play, position, scrubber, length) sits under the tabs on every tab.
- Transcript (Columns): a time column, then the speaker's name above the words, with a hairline between runs.
  Unknown speakers say "Unknown speaker" and offer Identify (the speaker menu). Bubbles remain an opt-in setting.
- Notes: a "Meeting notes · Draft" eyebrow, the overview's first item as a lede, Decisions in sage-edged blocks, Next
  steps with owner and date (or "No owner stated · no date stated"), Still open, and Details to confirm (limitations).
  Below a hairline: Your notes and Private scratchpad, storage unchanged. Source links still show with Details on (T25).
- Audio details: a plain-language headline, one notice per stretch of missing audio (`Presentation/AudioDetails.swift`
  reports only the source, times, and whether the other source has audio there, never a cause), with Listen around.
  Then sources, storage and retention, the raw events under a disclosure, and Delete audio… (confirmation as before).
- Menu bar: the `AmaranthMenuBar` template glyph at 20 × 18 pt, plus a pixel-aligned record dot, pause bars or "!"
  during a session (`App/Shared/MenuBarIcon.swift`). Its accessibility label is "Amaranth, idle/recording/…". Proofs
  at 1x/2x on four bar backgrounds come from `ui-render` (`menu-bar-icon-1x.png`, `-2x.png`).
