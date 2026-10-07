# Kubix

Kubix is a native macOS Kubernetes client: a SwiftUI/AppKit pod browser with
embedded Ghostty terminals and streaming container logs. v0.1 is a walking
skeleton, not a full cluster-management product.

It talks directly to the Kubernetes API using `URLSession`, server-side Tables,
watches, HTTP logs, and `v5.channel.k8s.io` WebSocket exec.

- **No bundled or required `kubectl`.**
- **No separate helper app.** The same executable runs as `kubix --pty-bridge`
  to relay terminal bytes and sizes. That branch does not acquire credentials or
  make Kubernetes requests; authentication stays in the parent app.
- **No resource-mutation UI.** Browsing is read-only, but an interactive shell
  is not a read-only sandbox: commands can modify the container or access other
  systems according to its permissions and credentials. Open shells only where
  you are authorized.

## Build from source

Requirements:

- macOS 15 or later (the configured deployment target).
- Full Xcode selected as the active developer directory, with a Swift 6
  toolchain, macOS SDK, and Metal compiler. Command Line Tools alone are not the
  app-build toolchain.
- Homebrew, Git, Make, and `xcodegen`; `swiftlint` for linting.
- Zig **0.15.2**, obtained by setup through Homebrew's `zig@0.15`.
  Setup installs that formula if missing and rejects a different Zig version.
- Network access for initial source/dependency restoration. Setup can download
  Xcode's Metal Toolchain component when `xcrun metal` is unavailable.

From an existing checkout:

```sh
brew install xcodegen swiftlint
make prep
make build
open build/DerivedData/Build/Products/Debug/kubix.app
```

`make prep && make build` is the clean-checkout build path. Setup builds pinned
Ghostty commit `4dcb09ada0c0909717d92547623b26eafa50ca8a` from source, stages
`GhosttyKit.xcframework` plus bundled themes, shell integration, and terminfo,
and reuses matching prepared artifacts. `make build` also runs setup and XcodeGen,
then builds the Debug app at the path above. `make run` builds and opens it.
`make release` builds the shipping configuration and reports its signature and
entitlements; it is not notarized, which it says rather than treating as an error.

The project builds for the **host's native architecture**, not a universal
binary. The local app is ad-hoc signed with hardened runtime; signing for
distribution and notarization are not provided by this workflow.
`project.yml` is authoritative; `kubix.xcodeproj` is generated.

## Configure and browse

Kubix reads the app process's colon-separated `KUBECONFIG`, or `~/.kube/config`
when it is unset/empty. A Finder-launched app need not inherit your terminal's
environment. Missing files in a multi-file list are skipped; duplicate named
entries across files use the first definition. File references and relative
exec paths resolve against the kubeconfig file that supplied the entry.

1. Launch. The sidebar lists every resolvable context and **nothing is
   connected**: no credentials are acquired and no request is made. Invalid or
   unsupported contexts have configuration diagnostics under the list rather
   than silently activating.
2. **Connect** a cluster — the button on its sidebar row, its context menu, or
   Return on the selected row. Connect acquires credentials, which may start
   browser sign-in, and then makes one unnamespaced `GET /version` request.
   It does not list pods. Selecting a cluster row only shows its pane.
3. Choose **Pods** or **Deployments** under a connected cluster's **Workload**
   group to list and watch its namespace. Exactly one watch runs at a time, so
   moving between the two kinds — or to another connected cluster — retires the
   previous watch and re-lists. Deployments show the server's columns plus the
   computed Age; CPU and Memory are pods-only, because the metrics API reports
   per pod.
4. Pick a namespace from the selector, or type one and press Return. Where the
   cluster permits `list namespaces`, the selector holds the cluster's own
   namespaces, refreshed when you open it (at most once every 30 seconds).
   Where it does not, the selector falls back to the context's namespace plus
   namespaces you have entered before, with no error: **namespace-list
   permission is not required**, and typing a known name works either way.
   Typing alone is a draft — committing re-lists only while a list is selected
   on a connected cluster, and re-lists whichever kind that is.
5. Use **Shell** and **Logs** above the table, or a row's context menu, or Return
   on a row. When a pod has several eligible containers each button opens a menu
   of them, with the role the pod gives each one; choosing one opens the session.
   Sessions of both kinds share one tab strip under the table.
6. Use the **Search** field, **Wide**, column sorting, and arrow-key selection.
   Columns come from the server's Table schema, plus three the app computes:
   **Age** from each pod's creation time, so it keeps ticking and sorts by age
   rather than as text, and **CPU** and **Memory** from the metrics API when the
   cluster serves it (they read as `kubectl top` prints them, and show `—` for a
   pod with no sample yet). Pages are collected completely
   before watching, and a complete list says **Listed** while its watch is still
   being established — an idle namespace can wait about a minute for the
   apiserver's first bookmark, and those rows are already correct.
   Reconnecting/failed rows are explicitly last-known data.
   **Retry pods** uses the committed target, not an unfinished namespace draft.
7. **Disconnect** abandons that cluster's watch. Running shells and log tails
   are not closed: they keep their original context, namespace, pod and
   container, and tails pause as they do for any scope change.
8. Press Return on a row or use **Shell** on its context menu. Kubix fetches
   fresh Pod details and checks the row UID before selecting a container.
   Only **running regular containers** are eligible; readiness is not required.
   Multiple eligible containers get a picker, preferring an eligible
   `kubectl.kubernetes.io/default-container` annotation. This annotation does
   not require the `kubectl` executable.

A shell's pane closes itself when the remote command exits, since a finished
session cannot be reconnected and its pane holds nothing usable; a nonzero exit
leaves its code beside the table, so a container without a usable shell does not
disappear without explanation. A **failed** session keeps its pane, which carries
the reason and **Retry shell**.

The shell runs `bash` if available, otherwise `sh`, via `env` with
`TERM=xterm-256color`. The container needs `env` and `sh`; `bash` is optional. Running
shells keep their original context/namespace/pod/container and stable session ID
when you browse elsewhere. They are not reconnected or replayed after failure.

**Logs** fetches fresh details and opens a timestamped 200-line tail followed
live. Its container selector includes all declared regular, init, and ephemeral
containers, including waiting/terminated ones; the server may report unavailable
logs. Pause retains the bounded buffer. **Resume** rechecks the original Pod UID
and starts a visibly marked new tail segment: lines can be missing or duplicated.
A replacement Pod is not adopted. Context/namespace changes or kubeconfig reload
pause logs; return to their original scope to Resume. Closing a log tab releases
its retained text. See [terminal integration](docs/terminal-integration.md#pod-logs)
for limits and viewport behavior.

## Authentication and executable discovery

Use only trusted kubeconfigs and trusted installed exec plugins: plugins run as
local executables with your user privileges, not inside a sandbox. Install and
configure each provider's tools and account/profile setup separately; Kubix does
not bundle cloud CLIs or configure cloud accounts.

A cluster whose kubeconfig user carries `client-certificate-data`/`client-key-data` — which is the
default for `orbstack`, `docker-desktop` and most local clusters — cannot be connected. That is a
signing constraint with a measured explanation in
[ARCHITECTURE.md](ARCHITECTURE.md#why-client-certificates-are-not-supported-measured-2026-09-12), not
a missing parser. A ServiceAccount token in a `token:` or `tokenFile:` user works today instead.

Supported authentication is `token`, `tokenFile`, and **token-returning**
ExecCredential `client.authentication.k8s.io/v1` or `v1beta1` plugins. Deliberately
anonymous contexts are possible. A selected malformed credential does not fall
back to anonymous. Legacy `auth-provider`, basic username/password authentication,
and impersonation fields are explicitly unsupported: their selected contexts fail
before credentials/networking, including token-plus-impersonation configurations.
Plugins run with closed stdin; v1 requires `interactiveMode`
set to `Never` or `IfAvailable`. Browser/device-code interaction is supported without
terminal stdin; `Always` and terminal-input-only plugins are not supported.

### Browser approval and Retry

**Authenticate configured plugin** invokes the configured command with its
original arguments and environment overrides. A plugin may reuse credentials,
open a browser, or emit live browser/device instructions. Use **Open Browser**
when an HTTPS fallback is available, and complete approval yourself.

The recovery model is **manual Retry**: if the plugin starts browser
approval but exits unsuccessfully, finish approval and choose **Retry
authentication**. Kubix does not detect browser completion and run a login loop.
Retry belongs to the original operation/context even if the sidebar selection has changed.
Successful Authenticate/Retry resumes authentication-failed discovery only for
the matching context/settings and unchanged committed namespace. It does not
commit a namespace draft, resume another context, or retry a 403. **Retry pods**
also explicitly retries the committed target. Shell authentication failures have a separate
**Retry shell** action; an already-started remote shell is never replayed.

For `aws-vault` or another wrapper, preserve the **exact configured wrapper,
arguments, and profile chain**. Do not strip the wrapper, substitute direct
`aws eks get-token`, or invent another profile to use the AWS helper. Generic
plugin authentication and Retry do not depend on that helper's applicability.

**Sign in with AWS** and **Use device code** appear only for a recognized direct
`aws eks get-token` invocation with a resolvable, consistent profile binding.
This helper requires **AWS CLI v2 and an already-configured IAM Identity
Center/SSO profile**. It runs `aws sso login --profile` using the resolved AWS
executable and aligned environment/profile, then reacquires the configured
ExecCredential. Argument, environment, and app profile conflicts are rejected.
These AWS prerequisites apply to this direct SSO flow, not all generic plugins.
Kubix does not infer an unknown federation wrapper's login command.

Concurrent callers share acquisition and compatible explicit login work.
**Cancel** cancels the shared operation; closing one waiting caller does not
cancel other callers. Authentication has a 600-second default budget, covering
login and reacquisition, separate from network timeouts. Live instructions are
transient and cleared on success, failure, or cancellation; do not screenshot
or persist them, verification URLs, device codes, tokens, or plugin stdout.
Plugins themselves may use their normal external credential stores.

### Configure Plugin Path

This app-only settings sheet provides:

- Additional **absolute search directories**, one per line, prepended to the
  effective plugin PATH.
- An **absolute executable override** for the selected configured command.
- An optional already-configured AWS SSO profile/session binding, keyed by
  kubeconfig **user**, for supported direct AWS invocations.

The resolver first tries a ten-second, best-effort **interactive** login-shell
PATH discovery (`$SHELL -ilc`), so Homebrew, mise, asdf and rbenv setup written
in `.zshrc` is recovered even when the app is launched from Finder and inherits
none of your terminal's environment. The result is cached until settings change.
It still cannot recover setup an rc file guards behind a TTY check, and it runs
your interactive shell configuration in a short-lived subprocess to read `PATH`
only.

If discovery recovers nothing usable, `/opt/homebrew/bin`, `/usr/local/bin` and
`~/.local/bin` are searched last, after the kubeconfig's own command, any
configured override, and the discovered PATH — so a normally installed plugin
still resolves from a Finder launch, and a deliberate choice is never shadowed.
Use stable shim directories or an absolute executable when necessary. Kubeconfig `exec.env`
overrides the inherited/recovered environment; app search directories are then
prepended. Bare commands search absolute PATH entries only. Overrides take
precedence over configured absolute/relative paths.

Nonsecret settings are saved to
`~/Library/Application Support/Kubix/auth-settings.json`; kubeconfig and AWS
files are not edited. `AuthSettings.timeout` is persisted configuration (positive,
at most one day), but the current settings sheet has no timeout field. Saving
settings invalidates resolver settings/PATH caches for subsequent acquisitions;
in-flight work and running shells retain their captured configuration.
Overlapping saves retain the last successful persisted/runtime settings even if
a queued save fails; later unsaved drafts are not overwritten by older completions.

## API permissions and compatibility

Grant only the permissions appropriate to the intended namespace and actions:

| Action | Core API resource | Kubernetes verbs used |
| --- | --- | --- |
| Connect (reachability probe) | `/version` | `get` (unnamespaced, no RBAC beyond the default public-info role) |
| Namespace selector contents (optional) | `namespaces` | `list` (unnamespaced; denial costs only the dropdown contents) |
| Pod table and live updates | `pods` | `list`, `watch` |
| Deployment table and live updates | `deployments` (`apps/v1`) | `list`, `watch` |
| Fresh identity/container validation | `pods` | `get` |
| Deployment selector and template containers | `deployments` (`apps/v1`) | `get` |
| Finding a deployment's pods | `replicasets` (`apps/v1`), `pods` | `list` (label-selector scoped) |
| Interactive shell | `pods/exec` | `get` (GET WebSocket upgrade) |
| Container logs | `pods/log` | `get` |

No namespace-list permission is needed; without it the selector simply falls
back to typed entry and local history. Shell access is powerful even though
the HTTP upgrade uses GET. A 403 is a permissions failure, not a reason to
repeat browser login.

A deployment's logs need more than `deployments`: they are one `pods/log` stream
per pod, because Kubernetes has no aggregated log endpoint. The pods are found
through the deployment's ReplicaSets rather than by its labels — a Deployment's
selector is not required to be unique, so matching on labels alone can tail a
neighbouring deployment's pods as well — which is why `list replicasets` is
needed too. Kubix tails the whole set up to fifty pods and says so when a
deployment has more.

**Connected is not authorized.** The Connect probe proves only that credentials
were accepted and the apiserver answered. Access is per namespace and per
resource, so a 403 is reported in the pane of a cluster that stays connected. On a
cluster that allows anonymous access to `/version`, Connect can also succeed
where nothing else is permitted.

Exec requires **actual negotiation of `v5.channel.k8s.io` by the API server and
every intermediary**. There is no older-protocol fallback and no Kubernetes
version-number compatibility guarantee. Table responses are required for pod
browsing. Check your API endpoint and authorization policies, not just a server
version label.

Ordinary HTTP requests use 30-second idle/60-second total limits. Watches renew
their 300-second server lease with a 330-second client deadline and bounded
retries. Exec upgrade has a separate 30-second deadline; an established session
pings every 15 seconds after the preceding pong and allows 15 seconds for a pong.
Logs follow and WebSocket session resources use 24-hour idle/seven-day total
limits. Quiet following is not subject to the ordinary 60-second request limit.
Interrupted logs require Resume; failed running shells require opening a new session.
Only a valid remote status reports an exit code, including nonzero exits;
API, protocol, heartbeat, and local bridge failures are shown as failures.

### Not supported in v0.1

- **Client-certificate authentication**, both static inline/file material and
  exec-returned certificates. Combined token/certificate plugin results are
  rejected too; there is no silent token fallback. This work is deferred, not
  implemented or handshake-validated. **Server CA validation remains supported.**
- Nonempty kubeconfig `proxy-url`: activation fails before credentials or
  network requests; it never silently bypasses an explicit proxy.
- Terminal-input-only/`interactiveMode: Always` credential plugins.
- Init/ephemeral-container exec (their logs remain available).
- Resource mutation UI, other resource browsers, YAML/apply, Helm, port-forward,
  a general control API/CLI or agent skill, and independent multi-cluster windows.

TLS verifies server CA/hostname, including configured CA data/files and
`tls-server-name`. `insecure-skip-tls-verify` is honored with a visible warning.
The parser also accepts HTTP endpoints; use HTTPS for credentials and traffic
confidentiality.

## Development and evidence

```sh
make help
make test                          # both host-free SwiftPM test targets
swift test --package-path KubixCore --filter WatchServiceTests
make lint                          # strict SwiftLint, including warnings
```

After `make build`, the existing controlled native checks are:

```sh
bash scripts/test-terminal.sh
bash scripts/test-pod-ui.sh
```

They require a logged-in macOS GUI session and Metal; they use fixed synthetic
drivers, not live kubeconfig/cloud/cluster access or a general control endpoint.
Host-free tests do not need the app, Ghostty, Metal, user credentials, or a
cluster (initial SwiftPM dependency restoration is separate).

Acceptance distinguishes **current LIVE normal read-only integration**,
**reused genuine LIVE human browser approval and raw-shell evidence**, and
**CONTROLLED scale/fault/native evidence**. Large-list/add-delete latency,
forced RBAC/expiry/transport faults, and actual quiet following longer than
60 seconds were controlled checks, not claims about a live cluster. No live
resource mutations were used to manufacture events. Certificate auth is excluded.

See [CHANGELOG.md](CHANGELOG.md) for what each version added,
[ARCHITECTURE.md](ARCHITECTURE.md) for ownership and lifecycle contracts,
[CLAUDE.md](CLAUDE.md) for durable contributor conventions, and
[the acceptance notes](docs/terminal-integration.md#read-only-v01-acceptance-task20)
for detailed evidence boundaries.
