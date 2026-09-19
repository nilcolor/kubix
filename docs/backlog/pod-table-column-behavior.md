---
worth: yes
where: kubix/Views/PodTableView.swift:255
added: 2026-09-11
---
# a dragged column width is reset on every rebuild, and search ignores hidden columns

Carried forward from `pod-search-field.md`, whose placement and labeling half shipped with the UI shell
redesign (docs/plans/20260911-ui-shell-redesign.md). Two pieces were explicitly out of scope there:

- **A dragged width does not survive a rebuild.** Since 2026-09-19 columns are fitted to their
  content when they are rebuilt — the first 200 rows in display order, `Name` up to 480pt — and left
  alone while they stand, so a drag lasts until the next rebuild: a namespace change, Wide, or the
  usage columns arriving. Remembering a dragged width by column name across rebuilds is what remains.
  `allowsColumnReordering` is also off.
- **Search cannot match hidden columns.** `PodTablePresentation` filters only over visible columns, on
  purpose — "A hidden column must not invisibly control either sorting or filtering". That reasoning is
  about *sorting*: a search for a node name silently finds nothing until Wide is checked, with no hint
  that matches exist in hidden columns. Searching may deserve the opposite answer plus a hint, which is
  a decision, not a bug fix.

Neither blocks anything. The first is small and self-contained; the second needs the decision made
first. The computed columns (Age, CPU, Memory) are deliberately not search keys, which is a separate
decision recorded in ARCHITECTURE.md, not part of this one.
