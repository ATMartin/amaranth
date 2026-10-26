# UI 0002: Conversation-bubble transcript (T37 exploration)

Date: 2026-10-26 · Task: T37 (optional, Milestone I) · Status: **Available behind a setting; recommendation: keep
Columns as the default.** The default is unchanged until the user decides otherwise.

## What was built
Settings → Appearance → Transcript style: **Columns** (T35, default) / **Bubbles**. Bubbles use the same list rows as
Columns, so every row keeps its id, context menu (Correct Text, Assign to Speaker, Mark Uncertain, Play from Here),
selection highlight and evidence jump. Microphone rows (you) are right-aligned in the accent tint; system-audio rows are
left-aligned in the speaker's colour; the disc and name sit above the first bubble of each run; the time (click to
play), flags and, with Details on, the MIC/SYS badge are a small caption beside each bubble. Gaps draw exactly as in
Columns (hairlines in skim mode, full rows with Details).

Checks: `--self-test ui-render` evidence jump passes in both styles (row selected and centred, both when the pane is
showing and when it opens with the focus set), at Default and Larger text; bubble renders of each fixture in skim and
Details mode. Speaker colours are now assigned per meeting so up to 8 speakers never share one (the plain hash gave
two of four speakers the same pink), and blue is left out of the palette because it is the accent (your bubbles).

## Evaluation
Meetings: the 4-speaker "Build Carolina check-in" (49 min, separate mic and system tracks) and the 2-minute "Test
(Youtopia recording)" (one mixed track) from the user's library, plus the fixtures (screenshots of the user's meetings
stay out of git; fixture screenshots: `docs/qualification/evidence/2026-10-26/t37/`). Main window 1280×826, Default text:

| Meeting | Columns: rows visible | Bubbles: rows visible |
|---|---|---|
| Build Carolina check-in (4 speakers) | 29 | 15 |
| Test (Youtopia), 2 min | 24 | 15 |
| Synthetic two-hour, 4 speakers | 23 | 11 |

- **What reads well:** on a two-person call, or whenever the microphone track is separate, the left/right split makes
  "what did I say vs. what did they say" instant, and short back-and-forth reads like a chat, as in Granola.
- **What does not:** with 3+ remote speakers every speaker is on the left, so the side carries no information and the
  colour and name above each bubble do all the work. Turns alternate constantly in real meetings, so almost every bubble
  starts a run and repeats its name line: half as many rows fit as in Columns. Mixed single-track recordings (like the
  2-minute test) have no microphone side at all. Long turns become wide blocks that are harder to scan than the aligned
  text column.
- The user's daily use is multi-speaker meetings and skimming long transcripts (design review 01:31–02:45), where
  Columns is denser and aligned.

## Recommendation
Keep **Columns** as the default. Keep Bubbles as an option for people who prefer it on 1:1s. Possible follow-ups if
the user wants Bubbles to be better: use Bubbles automatically for two-speaker meetings, or as the *live* view while
recording (the review asked for the Granola-style live transcript at 10:09–10:19); show the name line only when the
speaker differs from two turns ago. Not done here (scope was an exploration).
