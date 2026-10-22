# 0004 — Milestone restructure and performance priority

Date: 2026-10-22 · Status: Accepted (user decisions after the first real recorded meeting)

| Topic | Decision | Consequence |
|---|---|---|
| **Milestone order** | Milestone D is reduced to **T14 (live text)**. T12 (qualification) and T13 (packaged test build) move to a new final **Milestone F, release qualification**. The new **Milestone E** (T16–T21, `docs/milestone-e-performance-plan.md`) runs between them. | Release qualification measures the faster pipeline once, instead of being repeated. T14's "T12 and T13 must validate it" now refers to Milestone F. T13's existing tooling (`scripts/build-release.sh`, notices, tester guide) is partial T13 work, not Milestone D work. |
| **Processing during recording** | Allowed, as an experiment. It replaces plan §10's "pause background inference on new recording" and processing/0001's suspension while recording. | Guarded by capture-health, thermal and memory back-off (Milestone E gate G6). A single setting restores the v0 policy. The user rolls it back if they see problems the safeguards miss. |
| **Speed vs quality** | Speed comes first for transcription, because back-to-back meetings leave no idle time. Notes may run in the background and be slower. | Transcription may lose a small, bounded amount of quality (Milestone E gate G5). Notes keep their quality checks and run at the lowest priority. |
