---
worth: yes
where: KubixCore/Sources/KubixCore/Model/PodTablePresentation.swift:82
added: 2026-09-11
---
# Age sorts lexically, so 2d comes before 44h

The server's pod Table sends AGE as a human duration string — `5m`, `44h`, `2d`, `21d` — and nothing in
Kubix parses durations. Two `.string` cells therefore fall to the final branch of `compare`, which is a
text comparison with `.numeric`: it compares the leading digit runs and ignores the unit suffix entirely.

Ascending order comes out wrong across any unit boundary:

- `2d` before `44h` — 2 < 44 as text, but 2d is 48h.
- `5m` before `10s` — 5 < 10 as text.
- `9h` before `10m` is correct only by accident.

Sorting by Age is the normal way to find what just restarted or what has been up for weeks, so this is
wrong in the exact case it gets used for.

Keep the existing rule that no column *name* gets special treatment — "Server cell positions, never
pod-specific column names, define the display and sort keys". The schema-agnostic fix is to recognise a
duration-shaped string cell (`^\d+(\.\d+)?(ns|us|µs|ms|s|m|h|d|y)$`, and kubectl's compound forms like
`3d4h`) and compare those as durations, with a mixed duration/non-duration pair still falling back to
text so `compare` stays a total order — the comment at line 74 is there because mixing comparison
strategies per pair can form sort cycles, and that hazard applies to this change.

`ColumnDefinition.type` does not help: kubectl's Age column is declared `type: "string"` like any other.

`KubixCore/Tests/KubixCoreTests/PodTablePresentationTests.swift` already covers sorting, so this needs a
case there, not new scaffolding.

**Check [[age-column-live-refresh]] first.** If Age is computed locally from `metadata.creationTimestamp`
instead of read as a server-rendered string, sorting becomes a numeric `Date` comparison and this item
disappears rather than getting fixed. Doing the duration parsing described here first is wasted work if
that decision goes the other way. Unrelated to the UI work in the UI shell redesign (docs/plans/20260911-ui-shell-redesign.md) — fixable today.
