# Milestone O: changes after verdict v1 (PASS WITH FIXES, no must-fix)

Should-fix items:
1. Fixed: `ReminderController.enable()` no longer asks for notification permission while recording.
2. Fixed: the reminder id includes a stable hash of the title, so a retitled event's pending notification is replaced on the next sync. Test `retitledEventReplacesItsPendingReminder`.
3. Fixed: a linked meeting with calendar access still undecided says "Allow calendar access to check this event…" and offers Allow Access… (not "Calendar access is off"). Change Event… shows whenever access can read.
4. Not changed: `CalendarSuggestion.approve` re-upserts the row. The session's saves keep the stored title, and people/link are preserved by `upsertMeeting`, so it self-heals. A title-only setter is left for later.
5. Fixed: the Settings window is 640 pt tall, so Settings → Calendar shows its last button without scrolling.
6. Fixed: "Event changed since linking" shows the event's current title and time inline.
7. Fixed: the "Remove calendar data" help text says chosen speaker names stay.
8. Left to the user: reminder notifications show the event title (also on the lock screen). It is the reminder's purpose, and the reminder is off by default.
9. Not changed (pre-existing, not Milestone O): `ui-render` with `--self-test-output <dir>` logs only to stdout.

Validator left the real library unchanged (row hash identical) and changed one default (Settings tab index), which was restored.
