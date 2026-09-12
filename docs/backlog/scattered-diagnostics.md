---
worth: yes
added: 2026-09-11
---
# eight independent diagnostic channels, each rendered wherever its view happens to sit

Errors and warnings reach the user through eight separate pieces of store state, each rendered as loose
orange (or red) `Text` by whichever view owns it:

| state | rendered in |
| --- | --- |
| `configurationDiagnostics` | `ClusterSidebar` footer |
| `namespaceDiagnostic` | `PodsPane` |
| `pluginPresentation.diagnostic` | `ClusterPane`'s plugin section |
| `authenticationDiagnostic` | `AuthProgressView` |
| `settingsDiagnostic` | `AuthSettingsView` (sheet) |
| `podShellDiagnostic` | `PodTableView` |
| `podLogDiagnostic` | `PodTableView` |
| `PodTablePresentation.message` when `.failed` | `PodTableView` |

Plus `insecureSkipTLSVerify` warnings duplicated inline in four views (`ClusterPane`, `ClusterSidebar`,
`ExecSessionDeck`, `LogView`).

Consequences today: nothing is dismissible; nothing carries a severity or a timestamp, so you cannot
tell a stale message from a live one; and two unrelated failures render as two anonymous orange paragraphs in
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

**Rechecked 2026-09-12** after the UI shell redesign, which moved four of these to new homes without
reducing their number — the redesign found each message a place rather than one path. The auth banner
above the pods table now appears only for sessions that still want something, so a finished sign-in no
longer occupies that space; every other channel is unchanged.
