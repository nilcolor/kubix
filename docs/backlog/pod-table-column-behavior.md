---
worth: yes
where: kubix/Views/PodTableView.swift:148
added: 2026-09-11
---
# column widths are guessed from the title and search ignores hidden columns

Carried forward from `pod-search-field.md`, whose placement and labeling half shipped with the UI shell
redesign (docs/plans/20260911-ui-shell-redesign.md). Two pieces were explicitly out of scope there:

- **Widths are guessed and discarded.** Each column's width is
  `min(260, max(110, name.count * 9 + 24))`, recomputed from scratch whenever the server schema
  changes, so a width the user dragged is silently reset on the next column change.
  `allowsColumnReordering` is also off (`:91`).
- **Search cannot match hidden columns.** `PodTablePresentation` filters only over visible columns, on
  purpose — "A hidden column must not invisibly control either sorting or filtering". That reasoning is
  about *sorting*: a search for a node name silently finds nothing until Wide is checked, with no hint
  that matches exist in hidden columns. Searching may deserve the opposite answer plus a hint, which is
  a decision, not a bug fix.

Neither blocks anything. The first is small and self-contained; the second needs the decision made
first.
