# Lower Garden — validation brief

Scope: the approved Lower Garden sidebar watermark from `docs/lower-garden-handoff` (version 1.0.0), and nothing else.
Requirements: `docs/lower-garden-handoff/AGENT_INSTRUCTIONS.txt` (sections 2–7) and `Design/lower-garden.json`; approved
look: `docs/lower-garden-handoff/Preview/Screenshots/{light,dark}{,-drawer}.png` (a browser mockup with sample content;
its search field and "Local by nature." line are not app features to copy).

## What changed

- `App/Resources/Assets.xcassets`: the handoff's three sets copied unchanged (`AmaranthLowerGardenMask` template image
  @1x/@2x, `AmaranthWatermarkTint`, `AmaranthSelectedMetadata`). No name collisions.
- `Presentation/AppPalette.swift`: `watermarkTint`, `selectedMetadata` pairs, in `named` (so
  `assetCatalogMatchesThePalette` checks them); `Tests/UI/PaletteContrastTests.swift`: selected metadata on Selection ≥ 4.5.
- `App/Shared/AppStyle.swift`: `Color.selectedMetadata`, `Color.watermarkTint`.
- `App/Library/LowerGardenWatermark.swift`: the decoration. Adapted from the handoff's helper with one deliberate fix:
  the helper's `ZStack(alignment: .bottomTrailing) { Color.clear; image }` grows to the 390 pt image width and is then
  centred in the narrower sidebar frame, which put the art ~85 pt right of the approved position at 220 pt. The image is
  now placed by `.frame(width:height:alignment: .bottomTrailing)` instead. Hidden (not rendered) for Increase Contrast or
  Reduce Transparency via the SwiftUI environment.
- `App/Library/LibraryView.swift` (`LibrarySidebar`, `MeetingRow`): watermark attached once as `.background` of the whole
  sidebar body (scroll view + footer inset) above the Canvas fill, outside the scroll view; footer gets an opaque Canvas
  backing; unselected meeting rows get Canvas at 92% (backing only); selected row metadata uses Selected Metadata; the
  sidebar's eyebrows (day sections, FOLDERS) use Text (`Eyebrow` gained a `color` parameter, default unchanged).
- `App/Launch/UIRenderSelfTest.swift`: `lower-garden` steps (see below).
- `docs/qualification/ui-manual-checklist.md`: items 75–77 (hands-on checks).

## Evidence to check

- `scripts/check.sh` (swift test, Debug build, os-gate, worker-crash, worker-hang).
- ui-render: `build/DerivedData/Build/Products/Debug/Amaranth.app/Contents/MacOS/Amaranth --self-test ui-render
  --self-test-output <dir>` → `{"result":"pass"}`. The `lower-garden` steps render `LibrarySidebar` at 160×760,
  220×760, 320×760, 220×420, 220×1000 with and without Reduce Transparency, and require: no pixel differs in the top 20%
  (fade) or the bottom 30 pt (opaque footer); the 58–76% band differs. `lower-garden-contrast`: the watermark alone draws
  on Canvas, and with Increase Contrast draws nothing. PNGs: `<dir>/{light,dark}/sidebar-garden-*.png`, `lower-garden-*.png`.
  Offscreen captures are 2×.
- `scripts/stop-layout.sh <dir>`: the real main window (temporary library), 8 variants; `stop-layout-*.png` show the
  sidebar in the real NavigationSplitView. Do not launch the app against the user's real library (their Release app may
  be running).

## Known limits (hands-on, checklist 75–77)

Live toggling of the system Increase Contrast / Reduce Transparency settings, scrolling a long real list, VoiceOver,
context menus and drag over the art, and 1× displays are not automated. Folder rows (not in the mockup) get no backing;
the spec names only meeting rows.
