# Lower Garden validation, verdict v1

Overall: PASS (no must-fix items; two optional should-fix notes).

## Must-fix
None.

## Should-fix (optional)
1. App/Library/LibraryView.swift (MeetingRow background, 92% Canvas card): over the garden the unselected rows' rounded
   backing shows as faint lighter rectangles at the right edge (visible in light/220x760 and 160x760 captures behind the
   "Dropped system audio" / "Standup with a pause" / "Launch checklist (edited)" rows; dark is subtler). This follows the
   spec (92% row backing) and the mockup shows the same, so it is a taste call, not a defect. Not in the real-window
   captures, where the garden sits below the rows.
2. App/Library/LibraryView.swift: `.background { LowerGardenWatermark() }` sits on a view whose background extends under
   the toolbar safe area, so the fade's 0..1 span is probably the sidebar plus title-bar strip rather than strictly the
   body below the title bar (spec section 3). The effect is a few points at most and the top 20% is blank either way.
   Not confirmed in code; no action needed unless exact fade stops matter.

## Review against AGENT_INSTRUCTIONS 2-6
- Resources (sec 2): the three sets are in Assets.xcassets, same names. Contents.json is as delivered and the mask is a
  template image. AppPalette `named` includes both colours, so assetCatalogMatchesThePalette covers them. Hex values match
  (416552/A5C5A2, 6D5C64/B9C3B5). The new selected-metadata contrast check is present.
- Geometry (sec 3): 390x585, bottom-trailing, offset (+105,+24), clipped, fixed point size. Stops 0/.2/.58/.76/.91/1 match
  the recipe. Opacity 0.12 is applied once, as `.opacity` after the mask. The image has no baked fade. The tint comes
  from a single foregroundStyle on a template image, so alpha is the mask.
- ZStack to aligned frame deviation: justified. The handoff's ZStack(.bottomTrailing){Color.clear; Image} takes the
  390 pt ideal width of the image, and its parent .frame(geometry.size) then centres that wider stack. At 220 pt the art
  would sit about 85 pt right of the approved spot (the 390 - 220 = 170 overflow, split evenly). `.frame(w,h,alignment:
  .bottomTrailing)` on the offset image anchors to the trailing edge, matching the CSS right:-105px/bottom:-24px and the
  approved screenshots. The captures confirm it: art position relative to the trailing edge is identical at 220 and 320 pt.
  The aligned frame also keeps the view at the proposed size, so there is no layout effect.
- Layering (sec 3/5): attached once as a background of the whole sidebar body (ScrollViewReader + footer inset), above the
  Canvas fill and outside the ScrollView, so it does not scroll with rows. Rows, footer and controls sit above it.
- Backing (sec 4): unselected rows get Canvas at 92% as a background shape only (text is untouched). The selected row is
  opaque Selection. The footer is opaque Canvas. Selected metadata uses the Selected Metadata colour. The day and Folders
  eyebrows use brandText through a defaulted `Eyebrow.color` parameter, so other callers are unchanged.
- Accessibility (sec 6): allowsHitTesting(false) and accessibilityHidden(true) are on the GeometryReader. Hiding is driven
  by the environment (colorSchemeContrast, accessibilityReduceTransparency), so it is live. The view is not rendered when
  hidden. There is no animation and no settings UI.
- Hidden branch: the `if` removes the GeometryReader, so the background contributes nothing to layout either way.
- Not verified here: live toggling of the system settings, scrolling with a long list, VoiceOver, 1x displays. These are
  covered by checklist items 75-77, per the brief.

## Evidence
- Ran ui-render myself (Debug build, output /private/tmp/claude-501/lg-ui): `{"result":"pass","test":"ui-render"}`. In
  both light and dark, all five lower-garden steps (160x760, 220x760, 320x760, 220x420, 220x1000) have top=0, footer=0,
  band>0 (for example 220x760 light: band 64726; 220x420: 34364) and ok=true. `lower-garden-contrast` is ok=true in
  both appearances (the watermark alone draws on Canvas, and Increase Contrast draws nothing).
- Inspected light and dark sidebar-garden-220x760 and light 320x760 and 160x760, and compared them with the approved
  light/dark screenshots. Garden placement, scale, tint and the fade (blank under the rows, strongest in the lower
  middle, gone by the footer) match. The footer text is clear of the art. At 160 the art is cropped at the left as
  expected, and the rows wrap normally.
- Real-window capture w1100/stop-layout-3-stopped.png: the garden sits in the real NavigationSplitView sidebar, fixed
  below the short list, fading out above the footer, clipped at the sidebar edge, with no change to the toolbar and no
  visible bleed into the detail pane.
- Static review of `git show b9fa15a` against the handoff helper and recipe, as above.
- Did not run PaletteContrast or scripts/check.sh (the commit message reports they pass). I did not launch the app against the real library or run stop-layout.sh, and I changed no repo files.
