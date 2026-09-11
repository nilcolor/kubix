---
worth: yes
where: KubixCore/Sources/KubixCore/Model/NamespaceSelection.swift:3
added: 2026-09-11
---
# no namespace list for a connected cluster

Once connected there is still no way to see what namespaces exist — you type one and press Return. The
"Suggestions" menu offers only the context's configured namespace plus namespaces you already typed
yourself (`NamespaceSelection.suggestions`), so on a fresh cluster it is a one-item menu.

This is deliberate, not an oversight: `NamespaceSelection` is documented "Never discovers namespaces
from the cluster", and the UI caption promises "No namespace-list permission needed". Plenty of clusters
deny `list namespaces` to human users, and a picker that 403s on open is worse than a text field.

So the item is additive, not a replacement: when `GET /api/v1/namespaces` succeeds, populate the picker
from it and keep it fresh; when it 403s, silently fall back to today's typed entry with local history,
no scary diagnostic. Selection should work by mouse and by typing with completion over whatever list is
available — typed entry must stay usable when the list is empty, which rules out a plain `Picker` and
points at a combo box / searchable menu.

**Open implementation choice, not a reason to defer:** whether to use a namespace *watch* (live
add/remove) or a one-shot list refreshed on connect. The watch costs another lease/deadline/retry
budget to maintain, for a list that changes approximately never. Leaning one-shot on connect plus
manual refresh; decide at the start of the work.
Blocked on nothing, but cheaper after the explicit-connect work (docs/plans/20260911-ui-shell-redesign.md) gives connect a real lifecycle to
hang the list fetch off.
