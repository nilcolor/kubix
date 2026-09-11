---
worth: yes
added: 2026-09-11
---
# eight independent diagnostic channels, each rendered wherever its view happens to sit

Errors and warnings reach the user through eight separate pieces of store state, each rendered as loose
orange (or red) `Text` by whichever view owns it:

| state | rendered in |
| --- | --- |
| `configurationDiagnostics` | `ContextPicker` |
| `namespaceDiagnostic` | `NamespacePicker` |
| `pluginPresentation.diagnostic` | `AuthProgressView` |
| `authenticationDiagnostic` | `AuthProgressView` |
| `settingsDiagnostic` | `AuthSettingsView` (sheet) |
| `podShellDiagnostic` | `PodTableView` |
| `podLogDiagnostic` | `PodTableView` |
| `PodTablePresentation.message` when `.failed` | `PodTableView` |

Plus `insecureSkipTLSVerify` warnings duplicated inline in three views.

Consequences today: the top three live inside a `ScrollView` capped at 260pt, so they can be scrolled
out of sight; nothing is dismissible; nothing carries a severity or a timestamp, so you cannot tell a
stale message from a live one; and two unrelated failures render as two anonymous orange paragraphs in
different parts of the window. This is the other half of the "no idea why" complaint in
[[opaque-reconnecting-state]] — the app frequently *is* explaining itself, somewhere the user is not
looking.

Wanted: one presentation path for user-facing problems — severity, source (config / auth / pods / shell /
logs), a timestamp, and a dismiss — with the per-feature state feeding it rather than each view
inventing its own label. The TLS warning is a *standing condition*, not an event, so it wants a
persistent badge on the context rather than a message in the same stream.

Constraint that must survive: auth instructions, verification URLs, device codes, tokens, and plugin
stdout stay transient and stay out of diagnostics. A unified store with history is exactly the shape
that would accidentally retain them, so whatever lands here must keep that boundary explicit.

Best done alongside the UI shell redesign (docs/plans/20260911-ui-shell-redesign.md), which has to find a home for this anyway.
