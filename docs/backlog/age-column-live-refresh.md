---
worth: later
where: KubixCore/Sources/KubixCore/Model/PodTablePresentation.swift:65
added: 2026-09-11
---
# assess computing Age locally so it ticks instead of freezing

Age comes from the server-side Table API as a **pre-rendered string** — the apiserver prints `"43m"`
into the cell when it builds the row. A new row only arrives on a MODIFIED event or a relist, so a
Running pod nobody touches keeps its original Age text indefinitely. Observed 2026-09-11 on a 223-pod
namespace: rows sat at `43m` while newly created pods correctly appeared at `1s`, confirming the watch
itself is live. `kubectl get pods` behaves the same way; this is a property of Table printing, not a
missing feature.

The data for a local computation is already in hand: the watch requests `includeObject=Metadata`, so
every `PodRow` carries `metadata.creationTimestamp`
(`KubixCore/Sources/KubixCore/API/Table.swift:87`). Rendering age from that plus a ~1s tick would make
it move.

**Unresolved — this is why it is `later`:** whether a ticking Age is worth its two costs.

1. **It needs a deliberate exception to a deliberate rule.** `PodTablePresentation` is schema-agnostic
   by design: "Server cell positions, never pod-specific column names, define the display and sort
   keys." Rendering age locally means recognising *that* column by name. The exception is narrow and
   defensible — for pods, AGE is the only duration column and is always creationTimestamp-derived —
   but it cannot be generalised, because another resource's duration column (a CronJob's
   `LAST SCHEDULE`, say) derives from a different timestamp. Taking it means documenting it as an
   exception in `CLAUDE.md` and `ARCHITECTURE.md`, not quietly widening the rule.
2. **A naive implementation fights the table.** Recomputing the presentation each tick changes every
   displayed age string, so `NativePodTable.update` sees changed rows and calls `reloadData()` — 223
   rows a second, against live scrolling and selection. It has to refresh only the age column for
   visible rows instead.

If it lands, it **subsumes** the age-column-sorts-lexically item: sorting a real `Date` is numeric, so
the duration-string parsing that item describes becomes unnecessary. Decide this one first.
