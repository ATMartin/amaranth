# 0007 — Google Calendar integration spec (direct API)

Date: 2026-10-27 · Status: **Proposed, pending the user's review.** Tasks T62–T66 (Milestone P) are in
`docs/implementation-tasks.json` as proposed; Milestone P is not placed in the milestone order.

Source: the user, 2026-10-27, after Milestone O: "I use Google Calendar extensively, not the local Apple Calendar
app … I'd prefer the direct integration to MacOS's defaults: we may pull more data in later." Builds on spec 0006 and
Milestone O (T56–T61); everything 0006 says about approval, people, privacy and the reminder still applies unless
this spec says otherwise.

## Why direct, and what it changes

The cheaper route is adding the Google account in System Settings → Internet Accounts, which 0006/Milestone O already
reads through EventKit with no code changes. The user chose a direct integration instead because Amaranth may later
pull data that Apple's sync doesn't carry (see "Later, not in this milestone"), and so Amaranth's Google data doesn't
depend on macOS's sync interval or on a Workspace admin allowing Apple's calendar sync.

This **reverses three earlier decisions**, which this spec amends once accepted:

- 0006 non-goal "No cloud calendar APIs (Google, Microsoft Graph), no OAuth, and no network access for this feature."
  becomes: no cloud calendar API except Google Calendar, read-only, after the user connects an account.
- 0006 Approach: "Amaranth gets no account, token, or network access of its own." Amaranth will hold a Google refresh
  token (Keychain) and make HTTPS calls to Google.
- Development plan §11: networking outside the explicit model-install action. The amended rule: Amaranth makes no
  network request unless the user installs models or has connected a Google account, and then only to the Google
  hosts listed under "Network boundary". Nothing about meetings (audio, transcripts, notes, people, titles) is ever
  sent; calls carry only time ranges, calendar ids and sync tokens.

Unchanged: no accounts or cloud of Amaranth's own (0005), no auto-record, no writing to any calendar, always ask
before linking (0006 Decision 1), unlink keeps people (Decision 3), nothing exported beyond the T49 fields.

## Goals

1. **Connect a Google account** from Settings → Calendar: "Connect Google Calendar…" opens the system browser to
   Google's consent page; after consent, the row shows the account email, the last sync time and "Disconnect".
   Disconnect revokes the token at Google, deletes it from the Keychain and deletes every cached Google event.
2. **Google events everywhere EventKit events go today:** the header chip's picker, "Event changed since linking" /
   "no longer in your calendar", the Record suggestion (T59), attendees as people (T58), rename suggestions (T60) and
   the optional reminder (T61). The calendar checkboxes in Settings list Google calendars alongside the Mac's, grouped
   by source.
3. **Fresh at Record.** When Record is pressed with a connected account, fetch events around now (one request per
   chosen calendar, 3 s timeout) before building the prompt, so an invite sent a minute ago is offered. Capture
   start never waits on it: the prompt appears or updates when the fetch returns, from the cache if it fails.
4. **No duplicates when both sources see the same event.** A Google account also added to macOS shows each event twice
   (EventKit and Google). Merge by iCalUID + occurrence start, preferring the Google copy.
5. **Works offline.** Everything reads from a local cache; offline, the chip and prompt use cached events and Settings
   says "Offline · last synced 10:42". No error dialogs while recording.

## Explicit non-goals

- No writing to Google Calendar (no RSVP, notes, attachments or links), and no write scopes requested.
- No Google data beyond calendar lists and events in this milestone (no Gmail, Drive, Contacts/People, Meet).
- No push notifications from Google (watch channels need a public HTTPS endpoint, i.e. a server); polling only.
- No server, proxy or Amaranth account. The app talks to Google directly.
- No auto-record, unchanged from 0006.
- More than one Google account: not in this milestone (the data model allows it; the UI connects one).

## Google setup (needs the user)

Google requires an OAuth client registered in a Google Cloud project, and only the account owner can create it:

1. Create a project at console.cloud.google.com, enable the **Google Calendar API**.
2. OAuth consent screen: app name "Amaranth", user type **External** (personal Gmail) or **Internal** (a Workspace
   account whose organization owns the project), scopes listed below, the user's own address as a test user.
3. Create an OAuth client of type **Desktop app**. Google calls its client secret non-confidential for installed
   apps; it is still kept out of git: it goes in `Config/GoogleOAuth.xcconfig` (gitignored), and builds without it
   hide the Google option.

**Testing-mode limit.** An External app left in "Testing" status gets refresh tokens that expire after 7 days, so the
user would reconnect weekly. The ways out are an Internal app (Workspace only, no expiry, no verification) or
Google's verification of the sensitive scopes (privacy policy URL, homepage, demo video, typically weeks). See open
question 1.

## Sign-in flow

- OAuth 2.0 authorization code with PKCE (S256), redirect to a loopback listener on `127.0.0.1:<random port>`
  (Google's recommended desktop flow; custom URL schemes aren't allowed for new desktop clients). The browser is the
  system browser (`NSWorkspace.open`), never an embedded web view.
- The listener accepts exactly one request whose `state` matches, answers with a "You can close this tab" page, and
  stops; it times out after 5 minutes.
- **Scopes:** `calendar.calendarlist.readonly` and `calendar.events.readonly` (narrower than `calendar.readonly`),
  plus `openid email` to show which account is connected. Later data needs new scopes through incremental consent,
  each one a separate decision.
- Refresh token → Keychain (generic password, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, not synced).
  Access tokens live in memory only. Nothing token-related is logged.
- A refresh that fails with `invalid_grant` (revoked, expired test-mode token, password change) sets the state to
  "Reconnect needed": the chip and Settings say so, cached events stay usable, and no browser opens until the user
  clicks Reconnect. Never prompts during a recording, same rule as 0006.

## Sync

- `CalendarList.list` on connect and every sync; the user picks calendars (default: the primary calendar and those the
  user owns or has selected in Google).
- `Events.list` per chosen calendar with `singleEvents=true` (recurring events expanded), fields limited with the
  `fields` parameter to what the mapping needs. First sync covers −14 days … +2 days; after that `syncToken`
  incremental sync; `410 Gone` → full resync of that calendar.
- **When:** at launch (not when a self-test is running), every 5 minutes while the app runs, on picker open, at
  Record (Goal 3), on wake from sleep. Exponential backoff on `429`/`5xx`; `401` → one refresh, then "Reconnect needed".
- **Older days:** the picker for a meeting older than the cached window fetches that day on demand and caches it
  for the session only.
- **Cache:** its own SQLite file next to the library database (`google-calendar.sqlite`), `secure_delete` on, the
  same file protection as the library. It holds only mapped fields (below), never the raw JSON.

## Data mapping

| Field | Google source | Notes |
|---|---|---|
| `CalendarEvent.id` | `iCalUID` + `@` + occurrence start | Same shape as EventKit's (identifier@start); Google's `iCalUID` is expected to equal EventKit's `calendarItemExternalIdentifier` for the same event synced over CalDAV; Goal 4 merges on it. T64 verifies this on a real account and falls back to title + start + end if it doesn't hold. |
| `title` | `summary` | Missing → "(No title)", as Google shows. |
| `start`, `end` | `start.dateTime`, `end.dateTime` | All-day events (`start.date`) are marked all-day and ignored by the suggestion, as today. |
| cancelled | `status == "cancelled"` | |
| declined by me | the attendee with `self == true` has `responseStatus == "declined"` | |
| attendees | `attendees[]`: `displayName`, `email`, `self`, `resource`, `organizer` | `resource == true` → room, skipped. `self` → current user, listed first. |
| `calendarName` | the calendar's `summaryOverride` or `summary` | |
| `LinkedEvent.source` | new case `.google` | Domain contract change (0002): adds an enum case; older builds can't decode a `.google` link. |

Not read: `description`, `location`, `hangoutLink`, `conferenceData`, `attachments`, `extendedProperties`. The
`fields` parameter keeps them out of the response, not just out of storage.

**Attendees without a display name.** Google often returns only an email for invitees outside the user's contacts,
so many Google attendees would fall into 0006's "N unnamed" bucket. 0006 rules out using the email's local part as a
name. See open question 3.

## Network boundary

- Hosts: `accounts.google.com` (consent, in the browser), `oauth2.googleapis.com` (token, revoke),
  `www.googleapis.com` (Calendar API, userinfo). Nothing else, no analytics, no Google SDK: plain `URLSession`.
- No request before the user connects, and none after Disconnect.
- T12's offline qualification keeps passing with no account connected; a new check records connection attempts with
  an account connected and allows only the hosts above.

## Privacy

- 0006's rules carry over: emails stored only with "Keep attendee email addresses" on, never exported; deleting a
  meeting removes its snapshot and calendar people; "Remove Calendar Data from All Meetings" also clears the cache.
- Disconnect: revoke at Google, delete the Keychain item, delete the cache file and checkpoint/truncate its WAL. A
  bytes test proves cached titles and attendee names are gone from disk.
- Linked-event snapshots in meetings stay after Disconnect (like turning EventKit access off); the Remove action
  clears them.
- Settings → Calendar states what is sent and to whom, in one line: "Amaranth asks Google for your calendar events.
  Nothing about your recordings is sent."

## Later, not in this milestone

Each would be its own spec decision, with its own scope and consent: people's names for email-only attendees
(People API / directory), the event description or agenda as context for notes, Meet links and conference details,
attachments, more than one Google account, Microsoft 365.

## Testing approach

- The Google source implements the existing `CalendarSource` protocol, reading from the cache, so T57–T61's logic and
  tests apply unchanged; a `GoogleCalendarClient` protocol with a fake lets sync be tested without the network.
- HTTP tests use a `URLProtocol` mock server (as `Tests/Models/RepairAndHTTPTests.swift` does): paging, `syncToken`,
  `410` resync, `401` refresh, `invalid_grant`, `429` backoff, offline.
- OAuth tests: PKCE verifier/challenge, `state` mismatch rejected, listener timeout, Keychain round trip (test
  service name).
- Mapping table tests from recorded-shape JSON fixtures written by hand (never real events).
- Merge tests: the same event from both sources appears once, Google preferred; a link made through EventKit still
  shows its live status.
- A real-account self-test (`--self-test google-calendar`, counts only) needs a person, like `calendar-access`.

## Proposed task breakdown (Milestone P, pending review)

| Task | Title | Depends on |
|---|---|---|
| T62 | Google sign-in: build-time client config, loopback + PKCE flow, Keychain token, refresh/revoke, "Reconnect needed", Settings → Calendar account row | T61 |
| T63 | Google sync and cache: calendar list, events with `singleEvents`, `syncToken` incremental sync, backoff, cache with secure delete, sync triggers, on-demand older days | T62 |
| T64 | Google as a calendar source: mapping, `LinkedEvent.Source.google`, merging with EventKit by iCalUID, calendar checkboxes by source, live status and reminder for Google events | T63 |
| T65 | Fresh at Record: fetch around now when Record is pressed without delaying capture, prompt updates on arrival, offline and "Reconnect needed" states in the chip and strip | T64 |
| T66 | Privacy and network qualification: Disconnect bytes test, cache in "Remove Calendar Data", allowed-hosts check with an account connected, offline check without one, `--self-test google-calendar`, checklist items | T64 |

Order: T62 → T63 → T64 → (T65, T66).

## Open questions for the user

1. **Testing mode or verification?** Personal Gmail in Testing mode means reconnecting every 7 days. If the calendar
   is a Workspace account, an Internal app avoids that. Which account, and is weekly reconnecting acceptable for now?
2. **Who creates the Google Cloud project?** It needs the user's Google login (about 10 minutes, steps above).
   The validator would need a connected account to check real sync (read-only, counts only, as in Milestone O).
3. **Email-only attendees:** keep 0006's rule (count them as unnamed), or show the email as the name when "Keep
   attendee email addresses" is on?
4. **Keep EventKit as well?** Proposed: yes, both sources, merged (Goal 4). Alternative: Google only when connected.
5. **Cache window:** −14 days … +2 days proposed.
6. **Placement** in the milestone order (currently J → L → T21 → F).
