# 0003 — User-confirmed scope

Date: 2026-10-15 · Task: T01 · Status: Accepted

Confirmed in the plan: M2 family or newer, macOS ≥ 26.5.2, 16 GB supported target, 8 GB investigated,
editable anonymous speaker labels, local retention until the user deletes.

Confirmed at implementation start (2026-10-15):

| Topic | Decision | Consequence |
|---|---|---|
| App identity | "Amaranth", `com.alexmartin.amaranth` | Frozen in 0001 |
| Signing | User will add a free Apple ID team; ad-hoc until then | TCC may re-prompt after rebuilds; notarization pending |
| **Live text** | **Essential** | **T14 is promoted into the release chain** (no longer optional). Contracts model `provisional` vs `final` revisions now. T12 and T13 must validate T14's latency, capture and memory gates. |
| Language / duration | English; 2 h tested, 4 h soak (plan defaults kept) | — |
| Model downloads | Allowed (explicit install only) | — |
| Test hardware | Only an M2 Max (96 GB), macOS 26.5.2 | Base-M2/16 GB and 8 GB gates stay **unverified**. M2 Max results never substitute for them. |
| Corpus | Public and synthetic data first; the user supplies consented real meetings later | Held-out real-call quality gates stay pending until then |
