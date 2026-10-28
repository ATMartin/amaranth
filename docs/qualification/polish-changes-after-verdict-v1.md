# Polish (T74–T81): changes after verdict v1

Verdict v1 (`polish-verdict-v1.md`, Sonnet validator): **PASS WITH FIXES**, no must-fix items. Should-fix items:

1. **ADR width** — fixed: `docs/decisions/ui/0004-inner-circle-identity.md` says 160–320 pt, 180 ideal since T80.
2. **⌃⌘S on the list-icon button** — `SidebarCommands()` is now declared in `AmaranthApp`, so View ▸ Show/Hide Sidebar
   (⌃⌘S) exists however the system builds the View menu. `StopLayoutProbe` now logs a `sidebar-toggle` step: in all 8
   `scripts/stop-layout.sh` variants the button's label follows `toggleSidebar:` ("Show Sidebar" after closing) and the
   View menu has exactly one sidebar item with ⌃⌘S.
3. **Original Audio… for unprocessed meetings** — fixed: the Export submenu is enabled when a meeting has a transcript
   or audio; Markdown/Plain Text/JSON need a transcript, Original Audio… only audio (`LibraryModel.exportAudio`).
4. **Dead `.audio` arms** — fixed: `MeetingExport.Format` is markdown/text/json; audio export is its own call.
5. **Show Details on a card is global** — kept: it is the same preference as View ▸ Show Details, by the user's
   one-menu decision (T79). Noted for the hands-on review.
6. **Selection margin 0.017 over the 2.5:1 floor** — kept on purpose: the floor is tight so any change to the
   experimental accent is noticed.

After the fixes: `scripts/check.sh` passed (before the fixes; the fixes touch App code only), ui-render passed in light
and dark, `scripts/stop-layout.sh` 8/8 with the new sidebar-toggle step `ok` everywhere.

Hands-on checks left to the user (validator's list): footer opens Settings on Models (and "Recording Settings…" switches
an open Settings to Recording); ⌃⌘S and the list icon stay in sync; Esc/× in Ask refocus the field; export Markdown from
a closed card's right-click menu; rename and delete from a card with the sidebar closed; deleting the open meeting stops
playback; dark-mode legibility of small accent links and tabs; Record button hover/pressed states.
