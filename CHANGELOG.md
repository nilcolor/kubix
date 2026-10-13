# Changelog

Kubix is a native macOS Kubernetes client. Versions are read-only plus logs and
shells, except where an entry says otherwise.

## v0.3 — 2026-10-13

- **Delete a pod**, the first write. **Delete Pod…** on a pod row's context menu
  asks first, naming the pod, namespace and cluster, and the request carries the
  listed row's UID as a server-side precondition: a pod recreated under the same
  name since it was listed is refused, not deleted. Normal grace period, no force
  delete. Under a controller this restarts one replica. Needs `delete pods`.
- Deployments offer no delete: it would take every replica with it.

## v0.2 — 2026-10-07

- **List of Deployments, with aggregated logs.** `Deployments` sits beside
  `Pods` under a connected cluster, in the same table with the same namespace
  scope, search, Wide, sort and computed Age. No shell: a deployment has no
  single container to exec into.
- **Logs follow every pod of a deployment in one tab**, each line labelled with
  the pod that logged it. Kubernetes has no aggregated log endpoint, so this is
  one stream per pod, interleaved locally — the same thing `kubectl` does, up to
  50 pods rather than refusing above 5. The pods are found through the
  deployment's ReplicaSets rather than its labels, because a Deployment's
  selector is not required to be unique and matching on labels alone can tail a
  neighbouring deployment's pods. Needs `list replicasets` as well as
  `list pods`.
- One pod being unready does not fail the tab, which matters because a rollout
  always has one. The pod set is fixed until Resume, and the tab says so.
- No CPU or Memory column for deployments: the metrics API reports per pod and
  has no deployment resource.

## v0.1 — "Walking Skeleton" — 2026-09-21

- **Connectivity to Kubernetes clusters** through the kubeconfig's exec
  credential plugins, including browser sign-in and shared, cached credentials.
  AWS EKS is the verified path, with its own sign-in recovery and `aws-vault`
  wrapper handling; any other exec plugin goes through the same generic route.
  Connect is one explicit `GET /version` — selecting a cluster never requests
  anything on its own.
- **List of pods, with console and logs.** A complete paginated snapshot before
  any watch, rendered in a native table with search, Wide, sort, a namespace
  picker that uses the cluster's own list where RBAC allows, CPU and Memory from
  the metrics API, and an Age the app computes because the server's freezes.
- **Shells and log tails share one deck of tabs.** Shells run over a WebSocket
  exec through a same-binary PTY bridge into embedded Ghostty terminals; log
  tails are bounded rings with backpressure and a virtualized viewer, with
  Resume as an explicit new tail rather than a replay.
- **Dashboard mockup** on the cluster overview pane, labelled
  "Design preview — not requested from the cluster".

### Not in either version

Client certificates, notarized distribution, writes of any kind (scale, rollout
restart, delete, edit), and resources beyond pods and deployments.
