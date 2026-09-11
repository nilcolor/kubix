---
worth: yes
where: KubixCore/Sources/KubixRuntime/API/URLSessionTransport.swift:151
added: 2026-09-11
---
# a 401 retry redacts the Status body against the refreshed token, keeping an echo of the rejected one

`APIError.response(code:body:resource:redacting:)` replaces the bearer token it is given with
`[redacted]` inside the server's `Status` message. The credential loop passes the token of the
*current* attempt. On a 401 the loop invalidates and re-acquires, so attempt 1 redacts against the
**new** token — and a `Status` body that echoes the **old**, just-rejected token is retained verbatim
in the error that reaches the UI.

Observed while writing `ClusterProbeServiceTests`: with a body of
`{"kind":"Status","message":"denied <token-0>"}`, a 403 yields `denied [redacted]` while a 401 yields
`denied <token-0>`. The 401 case is asserted as-is there, with a pointer to this item, so the test
documents real behavior rather than the intended behavior.

Not probe-specific — every managed request takes the same path, so a pod list or log request with a
token-echoing 401 body behaves identically.

Mild in impact: the leaked token is one the server has already rejected and the cache has already
invalidated. It is still a credential in a diagnostic string, which
`CLAUDE.md`'s "keep auth instructions/credentials transient and separate from diagnostics" is meant to
prevent. The fix is to redact against every token used in the operation (or to redact the previous
attempt's token as well as the current one) rather than only the last.
