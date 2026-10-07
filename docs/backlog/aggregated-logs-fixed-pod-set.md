---
worth: yes
where: KubixCore/Sources/KubixCore/Model/AppActions+DeploymentOpen.swift:121
added: 2026-10-07
---
# a deployment's log tab does not adopt pods started after it opened

The pod set is resolved once, when the tab opens, and again only on Resume. Through a rollout the tab
therefore goes quiet: its sources end as the old replicas terminate, and the new ones are never
picked up. The status line says so — "The set is fixed until Resume, so pods started since will not
appear" — so the behaviour is explained rather than mysterious, which is why this was shipped as-is.

Adopting them live means watching pods scoped to the deployment's label selector: a second watch,
with its own lease, deadline and retry budget, running for as long as the tab is open. That is a
real piece of work, not a line, and it interacts with the one-watch invariant — this would be a
second concurrent watch whose lifetime is a session's rather than the selection's.

Cheaper middle grounds worth weighing first:

- **Re-resolve on a cadence** while the tab is following, reusing the existing one-shot resolution.
  No new watch; a rollout is picked up within the interval instead of instantly.
- **Re-resolve when every source has ended**, which is exactly the rollout case and costs one extra
  list at the moment the tab would otherwise go silent.

The second is close to free and removes most of the symptom. Whether that is enough, or whether the
tab should genuinely follow a moving set, is the decision.
