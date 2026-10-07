---
worth: later
where: KubixCore/Sources/KubixCore/API/DeploymentDetails.swift:73
added: 2026-10-07
---
# a deployment whose selector uses matchExpressions cannot open logs

`DeploymentDetails` refuses a selector carrying `matchExpressions` with
`DeploymentDetailsError.setBasedSelector`, which the pane reports and which points the user at the
Pods list instead. Only `matchLabels` is rendered into the `labelSelector` query.

This was a deliberate scope call, not an oversight. Serializing `In`, `NotIn`, `Exists` and
`DoesNotExist` into the label-selector grammar is perhaps twenty lines, but the failure mode is the
reason it was left out: a mistake does not error, it selects a different set of pods and looks like
it worked. `LabelSelector` already validates keys and values against the label grammar for the same
reason — `,` and `=` are the grammar's own separators, so a malformed key is a *different* selector
rather than an invalid one.

**Whether this is worth doing depends on whether anyone hits it.** Deployments created by people,
Helm and most operators use `matchLabels`; `matchExpressions` on a Deployment selector is rare, and
a Deployment's selector is immutable after creation, so it cannot drift into one. If it does come up,
the work is `LabelSelector` gaining a set-based form plus tests for each operator, each value
validated the same way, and anything it cannot render exactly still refused rather than approximated.

Symptom when hit: logs on that one deployment report why and open nothing. Its pods' logs still work.
