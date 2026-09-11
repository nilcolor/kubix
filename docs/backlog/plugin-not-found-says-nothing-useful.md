---
worth: yes
where: KubixCore/Sources/KubixRuntime/Auth/PluginResolver.swift:10
added: 2026-09-12
---
# the plugin-not-found diagnostic drops everything it was given, including installHint

`PluginDiagnostic` carries `installHint`, `source`, `searchedPath` and
`baselineDiagnostic`, and renders none of them:

```swift
public var description: String { "Authentication plugin not found. Configure Plugin Path (details redacted)." }
```

Two separate losses.

**`installHint` is never shown anywhere in the app.** It comes from the kubeconfig's own
`exec.installHint`, authored by whoever wrote the kubeconfig, and Kubernetes defines it precisely as
the text to show a user when the plugin cannot be found — `kubectl` prints it in exactly this
situation. It is not environment and not command arguments, so the privacy boundary
("Resolver diagnostics deliberately omit the effective environment and command arguments",
`AuthPresentation.swift:25`) does not cover it. Showing it verbatim is free.

**The shell probe reports failure loudly and useless success silently.** `ShellPath` only sets a
diagnostic when the probe *fails* (`usedFallback`). When it succeeds but returns a PATH that happens
not to contain the user's tools, nothing is surfaced at all — so the user sees a redacted shrug with no
hint that PATH is the subject.

That asymmetry cost a debugging session on 2026-09-12: an app launched from Finder reported
"plugin not found" while the same app started with `open` from a terminal worked. The probe had
succeeded in 13ms and returned a PATH without Homebrew, because `-lc` does not read `.zshrc`. Commit
d6d6fdd fixed the *resolution* (interactive login shell, ten-second budget, standard install locations
searched last), so fewer people will reach this message — but anyone who does still gets nothing to act
on.

Wanted: the `installHint` verbatim, plus sanitized metadata that names the subject without dumping it —
how many directories were searched, whether the PATH came from discovery or from the inherited
fallback, and whether the standard locations were reached. A count and a provenance word, never paths.
Related: [[scattered-diagnostics]], which is about where such messages appear rather than what they say.
