---
worth: yes
where: KubixCore/Sources/KubixCore/Model/PodTablePresentation.swift:120
added: 2026-09-11
---
# "Reconnecting" spins for a long time without saying why or for how long

Any `.connecting` with rows already loaded renders as a spinner plus "Reconnecting — N last-known pods;
updates are not live." That single string covers every cause — credential refresh, a dropped watch, a
403 being retried, a plugin waiting on browser sign-in — and carries no attempt count, no elapsed time,
and no indication of the remaining budget before it gives up. Observed in use: minutes of spinner with
nothing to read and no way to tell whether waiting or pressing something was correct.

It is also indistinguishable from a *first* connect that is slow, which is the other half of
the explicit-connect work (docs/plans/20260911-ui-shell-redesign.md): `refreshPods` sets `.connecting` for both the initial attempt and every
retry, and the only thing separating the two messages is whether `total == 0`.

Wanted: surface the cause (auth vs. watch vs. transport), the attempt number, and either elapsed time
or the deadline, so a long wait is legible. `WatchService` already distinguishes these internally —
e.g. it throws `APIError.watch(.credentialRefreshLimit)` when refresh attempts run out
(`KubixCore/Sources/KubixRuntime/Services/WatchService.swift:66`) — so the information exists and is
being flattened on the way to `PodConnection`. Keep the existing rule that opening a connection or
receiving a bookmark does not reset the failure count; the point is to show that count, not soften it.

Diagnostics only — no auth instructions, credentials, or plugin output in the visible string.

**Narrowed 2026-09-11:** the UI shell redesign separated *connecting to a cluster* from *watching pods*,
so a first connect now has its own visible state and reason on the cluster row. What remains here is the
retry message itself: a `.connecting` watch with rows already loaded still renders one string for every
cause, with no attempt count, elapsed time or remaining budget.
