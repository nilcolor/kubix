---
worth: yes
where: kubix/KubixApp.swift:6
added: 2026-09-11
---
# no menu bar commands, no Settings scene, no keyboard shortcuts

`KubixApp` is a single `Window` scene with `.defaultSize` and nothing else — no `.commands`, no
`Settings` scene. So the app ships with only AppKit's default menus and no way to drive it from the
keyboard:

- no ⌘R for refresh (`refreshPods` / `reloadSelectedPods` are button-only);
- no ⌘, for the plugin-path sheet — since the redesign its only door is the "Configure Plugin Path"
  button in a selected cluster's pane, which is reachable but has no keyboard route;
- no ⌘W / ⌘⇧[ ] for session tabs — closing a shell or log means clicking its small `xmark`;
- no ⌘F to focus search (see the search-field work (docs/plans/20260911-ui-shell-redesign.md)), no ⌘L for logs on the selected pod.

`ContainerPicker` is the only place that uses `keyboardShortcut` at all (`.defaultAction` /
`.cancelAction`).

Routing matters here: menu commands fire outside the view hierarchy, so each one must go through
`AppActions` on the MainActor like everything else, and must no-op cleanly when there is no selected
context, no selected pod, or no session — a menu item is enabled in states a button in the relevant
view would never have been visible in.

A `Settings` scene also gets ⌘, for free and is the natural place for the auth settings now living in a
sheet, but that is a bigger move than adding commands; splitting it out is fine.
