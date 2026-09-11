---
worth: later
where: kubix/Views/ClusterSidebar.swift:111
added: 2026-09-11
---
# Disconnect is hover-only on the sidebar row, asymmetric with Connect

Disconnect has three routes: the trailing button on a connected sidebar row, gated behind
`opacity(hovering ? 1 : 0)`; that row's context menu; and a plain visible button in the cluster's own
pane. Connect, by contrast, is a persistent button on a disconnected row — so the pair is asymmetric
exactly where a user would expect symmetry.

Surfaced 2026-09-11 when the maintainer asked for Disconnect to be *added*, not having found it. On
being shown the hover and cluster-pane routes he chose to keep both as they are: "fine for now, can be
updated later."

**Unresolved:** whether the hover gate costs anything now that its location is known. It may simply be
fine — a rarely-wanted, watch-destroying action that stays out of the way is a defensible design, and
one person failing to find it once is not evidence that it keeps happening. Revisit if it is missed
again, or when a keyboard route lands with `no-menu-commands`.

Kept rather than deleted so a later review does not re-file "Disconnect is hidden" as a new finding:
the placement is deliberate and has been accepted once already.

If it is changed, the cheapest option is revealing it whenever the row is *selected* rather than merely
hovered, which keeps quiet rows clean. The native driver cannot click SwiftUI buttons, so any change
needs a human pass or an `AppActions`-level assertion plus a look at the real window.
