# Contextual search fixtures (Milestone V, T109)

Synthetic meetings and labeled questions for contextual Ask. No real meeting text, no real people's data. Two sets with
**disjoint meetings and scenarios**: `dev.json` (tuning) and `heldout.json` (frozen before tuning; only scored, never tuned on).
`amaranth-bench ctx-eval` seeds each set into its own isolated library (plus generic filler meetings) and runs it.

```jsonc
{
  "version": 1,
  "set": "dev" | "heldout",
  "about": "who wrote it, how, what it covers",
  "reference_now": "2026-11-06T16:00:00-05:00",   // default request time (a Friday), ISO 8601 with offset
  "timezone": "America/New_York",                 // request timezone; meeting starts are absolute instants
  "meetings": [{
    "key": "h-trane-1",                 // unique; segment IDs become "<key>-s<lineIndex>"
    "title": "Resourcing sync",
    "start": "2026-11-03T10:00:00-05:00",
    "speakers": ["Speaker 1", "Speaker 2", "Andrew"],   // shown names by speaker index; "Speaker n" = anonymous; "Me" = user renamed that speaker to Me
    "people": ["Andrew Chen", "Priya Shah"],            // attendees from the calendar (NOT proof anyone spoke)
    "folder": null | "Clients",
    "lines": [[0, "So where are we on Trane?"], [1, "..."]],   // [speaker index, text]; 0-based line index = position
    "notes": [{"text": "...", "author": "user" | "generated"}],  // current notes document lines (optional)
    "edits": [                                          // optional current-content edits applied after transcription
      {"op": "correct", "line": 12, "from": "nineteen", "to": "twenty nine"},   // from = exact word(s) in that line
      {"op": "delete_line", "line": 5},
      {"op": "trim_before", "line": 3}                  // lines before 3 removed (Start from Here)
    ],
    "indexing": "complete" | "unindexed",               // unindexed: embeddings not built yet (incomplete-index cases)
    "deleted": false                                    // true: meeting deleted; nothing of it may come back
  }],
  "questions": [{
    "id": "h01",
    "scenario": "trane-staffing",      // questions sharing a scenario share meetings; dev and heldout scenarios never overlap
    "categories": ["paraphrase", "person_date", "multipart", "cross_meeting", "followup", "lexical", "unanswerable",
                   "ambiguous", "adversarial", "negation", "changed_plan", "self", "dst_boundary", "notes_only",
                   "incomplete_index", "trimmed", "speaker_vs_mentioned", "decision_status", "staffing", "commitments"],
    "question": "...",
    "request_time": "2026-11-06T16:00:00-05:00",   // optional; defaults to reference_now
    "scope": {"kind": "all"} | {"kind": "meeting", "meeting": "<key>"} | {"kind": "folder", "folder": "Clients"},
    "follows": null | "h00",          // follow-up: asked in the same session right after that question
    "expected_behavior": "answer" | "qualify" | "clarify" | "abstain" | "partial",
    "expected_meaning": "one or two sentences: what a fully correct answer says",
    "required_points": ["each fact a fully correct answer must contain"],
    "required_spans": [{"meeting": "<key>", "lines": [12, 13]}],   // each entry = one required evidence piece; covered if ANY listed line is retrieved
    "required_notes": [{"meeting": "<key>", "notes": [0]}],        // optional: evidence only in notes (note line indexes); one piece per entry
    "forbidden": ["claims a fully correct answer must NOT make (wrong person/period, invented decision, ...)"],
    "expected_date_range": null | {"start": "2026-10-26", "end": "2026-11-01", "kind": "calendar_week" | "rolling" | "day"},  // inclusive local dates of the MEETING filter
    "rationale": "why this is the expected behavior"
  }]
}
```

Semantics (frozen in T109, `docs/qualification/milestone-v/t109-semantics.md`): "last week" = previous Monday–Sunday
calendar week; "in/over the last week", "past seven days" = rolling 7×24 h before request time (2026-10-30 17:00 −04:00 for the
reference time, since DST ended in between); "today" = local
midnight → request time; "this week" = this Monday 00:00 → request time; dates *discussed* (e.g. "planning for 2027",
"goal for next quarter") are topic, not meeting filters. "I/my/me" resolves only through a speaker shown as "Me"
(user renamed it) — otherwise qualify (label commitments by speaker) or clarify. Attendee lists never prove speech.
