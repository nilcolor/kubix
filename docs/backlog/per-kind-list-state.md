---
worth: later
where: KubixCore/Sources/KubixCore/Model/AppStore.swift:21
added: 2026-10-07
---
# the list's filter, sort and selection are shared across kinds rather than remembered per kind

One watch runs, so the store keeps one slot: `rows`, `columns`, `connection`, `listFilter`,
`listWide`, `listSort`, `selectedRowUID` and the `listKind` they belong to. Moving between `Pods` and
`Deployments` keeps the filter text, drops the selection (the UIDs differ, so the presentation
cannot keep it) and resets the sort (the schema changed, which already clears it).

That was chosen because it needs no extra state and each outcome is defensible on its own: carrying
a search term across kinds is usually what a person wants, and a sort by column *index* means
nothing against a different schema. What is unexamined is whether a round trip should restore what
you left: going Pods → Deployments → Pods loses the sort and the selected row you had.

Remembering per kind is a dictionary keyed by `ResourceKind` and a restore on selection, plus a
decision about what happens when a remembered row no longer exists. Small, but it is state that has
to be reconciled on every reload and namespace change, so it earns its keep only if the round trip
actually annoys someone.

No symptom beyond mild forgetfulness; nothing is shown incorrectly.
