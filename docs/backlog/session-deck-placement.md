---
worth: later
where: kubix/Views/ContentView.swift:17
added: 2026-09-11
---
# shells and logs have no place in the new layout

The wireframe behind the UI shell redesign (docs/plans/20260911-ui-shell-redesign.md) shows a sidebar and a resource table. It does not show
terminals or log tails, and those are the app's actual point — so the redesign cannot proceed past
layout without deciding where they go.

Current shape: a `VSplitView` under the detail pane, with the deck omitted entirely until a session
exists (the redesign fixed the empty-state height, so a fresh launch no longer reserves it). The deck's
tab strip is still a horizontal `ScrollView` of plain `Button`s with an `xmark` beside each, selection
shown only by `fontWeight`; it is not a tab control and does not look like one.

**Unresolved:** tabs inside the detail pane, a collapsible bottom drawer, or detached windows per
session. Detached windows fit "a shell is a long-lived thing you keep while browsing elsewhere" — which
the code already guarantees, since sessions keep their original context/namespace/pod/container — but
multi-window means the Ghostty surface lifetime story gets re-examined, and "the session alone frees a
surface, exactly once" plus "SwiftUI rehosting must not destroy a running terminal" are the contracts
most expensive to get wrong. Decide before the redesign moves anything.

While in here: selection is encoded across two variables, `selectedExecSessionID` and
`selectedLogSessionID` (`AppStore.swift:39` and `:22`), which is why `isSelected` has to read
`store.selectedLogSessionID == nil && store.selectedExecSessionID == id`
(`kubix/Views/ExecSessionDeck.swift:51`). One selection expressed as two fields has an unrepresentable-
state gap — both set — that the views paper over. A single `selectedSession` enum removes the clause and
the gap, and is worth folding into whatever layout wins.
