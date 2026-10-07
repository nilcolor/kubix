---
worth: later
where: KubixCore/Sources/KubixCore/Model/ResourceKind.swift:51
added: 2026-10-07
---
# deployments show no CPU or Memory, because the metrics API has no deployment resource

`supportsUsageColumns` is pods-only. `metrics.k8s.io/v1beta1` reports per pod and has nothing for a
workload, so a deployment's number would have to be summed from its pods — which means identifying
them, and then deciding what the sum means.

Two ways to identify them, both with a cost the pod path does not have:

- **ownerReferences**, pods → ReplicaSets → Deployment. Exact, including excluding pods that merely
  carry the labels, but it needs `ownerReferences` decoded in `KubernetesObjectMetadata` (absent
  today) and two namespace-wide metadata lists per poll, where the pod table's own poll is one
  request.
- **The selector**, which aggregated logs already resolves (`DeploymentPodService`). One scoped list,
  but a selector matches whatever carries the labels, so the sum can include pods the deployment does
  not control.

**The unresolved part is not the plumbing, it is what the column should say.** Summed usage over a
deployment's pods is not comparable to a pod's own: it moves with the replica count, so a rollout
makes it jump, and a half-scaled deployment reads lower than the same workload at rest. A per-pod
average, a sum, and a sum against requests are three different columns, and which of them a person
wants is the decision this is waiting on. Until that is settled the column would be a number nobody
can act on.

No user-visible symptom beyond the absence, which the pane states by simply not having the columns.
