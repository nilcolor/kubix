# Architecture

Kubix composes native pod and deployment browsers, remote shell sessions, and
bounded log viewers. It is bearer-authenticated and read-only except for one
write: deleting a pod, behind a confirmation. [README.md](README.md) describes setup and supported
features, and [CHANGELOG.md](CHANGELOG.md) what each version added.

## Modules and mutation ownership

```text
kubix app (SwiftUI, AppKit, Ghostty, Metal, composition)
    |                         |
    v                         v
KubixRuntime -------------> KubixCore
```

Arrows mean imports/dependencies. `KubixRuntime` depends on `KubixCore`; the app
composes both. Core does not import Runtime or the app.

- `KubixCore/Sources/KubixCore/`: kubeconfig/Yams decoding and provenance,
  credential identity/cache policy, API/request/Table/watch models, remotecommand
  and local bridge codecs, log buffers, observable session state, `AppActions`,
  and injectable protocols. It has no AppKit/Ghostty/Metal dependency.
  The kubeconfig loader includes an injectable filesystem reader; "Core" does
  not mean every convenience adapter is mathematically pure.
- `KubixCore/Sources/KubixRuntime/`: process/plugin resolution and authentication,
  Security/URLSession transport, watch/details/log/exec services, Darwin PTY and
  Unix socket IO. It remains importable by host-free tests.
- `kubix/`: `AppComposition`, browser opening, native views, terminal rendering,
  app lifecycle, and opt-in Debug validation scenes.

`@MainActor AppActions` is the single app-state/session mutation seam.
`AppStore` and sessions are observable; views send actions instead of owning
network tasks, credential processes, or terminal teardown. Runtime services
deliver awaited MainActor updates through Core protocols. Cancellation is paired
with attempt/generation checks so late callbacks cannot resurrect closed sessions
or obsolete selection work.

Session UUIDs are stable identifiers, **not a shipped control API**. A future
control service can call the same actions; there is no general listener,
arbitrary-command endpoint, or `kubixctl` in v0.1. Fixed Debug validation modes
are not that service.

## Configuration, identity, and authentication

### Immutable inputs

`KubeconfigLoader` merges the process's colon-separated `KUBECONFIG` or default
file. First named definitions win across files; malformed/duplicate definitions
within a file fail. Each retained cluster/user/context records its source file.
Relative CA/token/client-material references and path-containing exec commands
resolve from that source, not the GUI working directory. `~`/`~/` are supported,
not `~other-user`.

`Kubeconfig.resolve` is the activation gate: it rejects invalid references,
embedded URL credentials, and nonempty explicit proxies before credential or
CA-file IO. `ResolvedContext` is an immutable snapshot. The transport registry
keys on the complete snapshot, not a picker label, and shares its creation task.
Registry entries remain until shutdown; it is not an LRU cache.

`CredentialIdentity` privately encodes cluster/user configuration and provenance
plus effective authentication settings, executable, and environment. Context
display name/namespace do not define authentication identity. These canonical
bytes can contain secrets: they are process-local equality keys, not persistable
hashes or diagnostic identifiers. Cache entries have monotonic generations;
a stale rejection must not evict a newer credential.

The existing method priority is nonempty token, tokenFile, exec, then static
certificate/key, otherwise deliberate anonymous access. A selected invalid
method fails without weaker fallback. Static certificate authentication is
rejected without loading its private material. Exec certificate-only and combined
token/certificate results are rejected before caching, and transport independently
rejects certificate-bearing credentials. Client identity import, keychain
integration, certificate rotation, and handshake validation are deferred.
Server trust is separate and implemented.

#### Client certificates: what actually blocks them (re-measured 2026-09-21)

The 2026-09-12 entry here said this was a signing constraint. That was wrong, and the probe it told
the next person to re-run is now committed as `scripts/keychain-probe.sh` — it reports the bundle's
own signature beside its results, so an answer can never be read against the wrong signature again.

`URLSession` answers a client-certificate challenge with `URLCredential(identity:…)`, so a
`SecIdentity` is required, and there is no `SecIdentityCreate(certificate, key)`. Measured in the real
app bundle, ad-hoc signed and non-sandboxed, on macOS 26:

| call | ad-hoc, no login keychain | ad-hoc, real login keychain |
| --- | --- | --- |
| `SecKeyCreateWithData` / `SecCertificateCreateWithData` | ok | ok |
| `SecItemAdd` private key, default keychain | `-25307` no keychain | **ok** |
| `SecItemAdd` private key, data protection keychain | `-34018` | `-34018` |
| `SecPKCS12Import` into the keychain | `-25307` no keychain | **ok — a `SecIdentity`** |
| **`SecPKCS12Import` with `kSecImportToMemoryOnly`** | **ok — a `SecIdentity`** | **ok** |
| `URLSession` client-certificate handshake with that identity | **HTTP 200** | HTTP 200 |
| the same request with the identity withheld | fails `-1005` | fails `-1005` |

The earlier `-34018` for a private key in the *default* keychain was measured without a login keychain
in reach — the first column reproduces it as `-25307` under an isolated `HOME`. Only the data
protection keychain needs an entitlement, and nothing needs it.

So the identity route works today: no Apple Developer account, no entitlement, no keychain write, and
no deprecated API. The handshake is proven against a local `openssl s_server` demanding a client
certificate, and the withheld-identity row is there to show the server was really demanding one.

What remains is not signing but format. A kubeconfig carries PEM
(`client-certificate-data`, `client-key-data`) and `SecPKCS12Import` wants a PKCS#12, so the app would
have to assemble one in memory. A container with neither encryption nor MAC is refused (`-26275`),
so that writer needs DER plus PBES2 — PBKDF2 and AES-CBC through CommonCrypto — and a MAC. That is
roughly a day's work with tests, against a feature whose alternative is a ServiceAccount token that
works now.

Two routes were rejected before and stay rejected: deprecated legacy-keychain APIs
(`SecKeychainCreate`, `SecItemImport`, `SecIdentityCreateWithCertificate`), and a second TLS stack.
A third is now available but unattractive: importing into the user's login keychain works even
ad-hoc, but it writes their key into their keychain as a side effect of opening a cluster.

**Until it is built.** Local clusters ship client-certificate users by default, which is why
`orbstack` and `docker-desktop` appear broken rather than unsupported. A ServiceAccount token in a
`token:` or `tokenFile:` user works today with no code change and does not expire.

### Acquisition and login

`PluginResolver` combines inherited environment, cached best-effort login-shell
PATH, kubeconfig exec environment, and app search directories/absolute overrides.
Relative PATH entries are not executable candidates. It preserves the configured
argv rather than evaluating it as shell text. `CredentialRunner` supplies
`KUBERNETES_EXEC_INFO`, with `interactive: false` and optional cluster info,
then validates the exact v1/v1beta1 response version.

`ProcessRunner` launches the executable directly with stdin closed and cwd `/`.
Its dispatch worker fairly drains nonblocking stdout/stderr with cancellation
and deadlines; blocking poll does not occupy Swift's cooperative executor.
Credential stdout is private and capped at 1 MiB. Stderr instructions are
incrementally decoded and delivered without waiting for newline. Owned process
groups are verified before cleanup signals; this is not permission to signal
unrelated user processes.

`CredentialProvider` owns the in-memory cache and single-flight acquisitions.
Expiry refresh is demand-driven, up to 60 seconds early but no earlier than half
the acquired credential's remaining lifetime. No-expiry credentials have no
time-based refresh (including cached token-file contents); generation invalidation
can trigger reacquisition. There is no background browser-login scheduler.

`AuthenticationService` is the credential facade injected into every transport.
`SharedOperation` gives independent waiters cancellation; the last waiter or
explicit shared Cancel stops owned work. Unsubscribing a UI progress observer
does not itself cancel login. Waiter completion is not worker teardown: separate
lifetime owners retain cancelled acquisitions, login refreshes, browser logins,
and PATH discovery until cleanup finishes, even after active/retry indexes replace
or evict them. `AppActions.shutdownAndWait` closes the authentication facade and
its child owners to new work, cancels them, and joins that cleanup before returning.
Direct AWS logins share a key incorporating the
resolved executable, profile or explicitly bound SSO session, effective
environment, and relevant options. One successful login coordinates post-login
credential reacquisition.

The direct helper recognizes supported `aws eks get-token` syntax, checks AWS CLI
v2, and runs `aws sso login` for an already-configured, nonconflicting profile.
Unknown wrappers, including configured `aws-vault` chains, remain generic plugins:
the app never strips their wrapper or invents a replacement profile/login.
Manual **Authenticate configured plugin -> browser approval -> Retry
authentication** is intentional. Retry uses the captured operation/context;
it is not automatic browser-completion detection.

Auth settings saves are serialized. New resolutions see new settings and a
refreshed PATH baseline; active operations keep their old captured plan and may
finish under it. Context/settings changes do not retarget a running shell or
silently replace the configuration of an in-flight login. Credential identities
separate old and new settings. Settings persist only nonsecret path/profile/
timeout choices in the app's Application Support directory, not credentials.
Requested-save, successful-commit and draft revisions are distinct: a failed queued
save cannot discard an earlier success, and old completions cannot overwrite newer
drafts or successes. Authentication recovery compares the acquired identity's
immutable context/settings association and the captured pod generation, not an
exec identity against a context-only cache key.

The authenticated transport tags sanitized plugin-resolution/process failures only
around credential acquisition. `WatchService` maps that tag to pod authentication
failure, so explicit Retry can restart discovery after a nonzero configured-plugin
exit. Log error normalization preserves the same safe tag for shared authentication
recovery guidance, without retaining provider or server payloads.
Network/API failures remain separate; cancellation and terminal 403 behavior
are unchanged. The authentication session retains the safe process diagnostic,
not credential stdout or terminal browser instructions.

### Window chrome

The window is a `NavigationSplitView`, and the controls above the table are real toolbar items with a
`.searchable` search field, because the system draws that material and a hand-built row of buttons in
the content area cannot match it. The detail column declares a real `minWidth`: an unbounded maximum
alone reads to the split view as no demand, and it then grows the sidebar to *its* maximum, which is
what made an earlier hand-rolled `HStack` look necessary. It was not — measured, the system column
holds its width across a window resize, keeps a user's drag across one, never scrolls sideways, honours
its min and max, and collapses past the minimum for free.

### Launching outside a terminal

A Finder-launched app inherits none of the user's shell environment: `PATH` is the
bare system default, so no tool manager's shims and no Homebrew prefix are
visible, and a configured plugin that resolves perfectly from a terminal cannot be
found. `ShellPath` therefore probes an **interactive** login shell — `-ilc`, not
`-lc` — because Homebrew, mise, asdf and rbenv are configured in `.zshrc`, which a
login shell never reads. The probe is marker-framed so an rc file that prints does
not corrupt the result, bounded at ten seconds (measured against a real shell
loading version managers, not chosen for symmetry with unrelated drain bounds),
and cached per settings revision so the cost is paid once. Failure falls back to
the inherited PATH with a surfaced diagnostic.

`PluginResolver` then appends `/opt/homebrew/bin`, `/usr/local/bin` and
`~/.local/bin` after the discovered PATH, so a normally installed plugin resolves
even when the probe recovers nothing — a shell whose setup is TTY-guarded, or one
whose flags the probe does not speak. They are last, so the kubeconfig's own
command, a configured override and the discovered PATH all win first. Because the
effective environment is part of a credential's cache key, changing what the
search path contains invalidates previously cached credentials once.

### Privacy boundary

Auth progress may contain secret-bearing verification URLs/device codes.
`AuthSession` retains at most 8 KiB of UTF-8 instructions and clears them on a
terminal state; bounded queues/history limit delivery and retry metadata.
Only live HTTPS URLs without URL user/password are offered to the app's browser
adapter. Browser opening stays out of Core/Runtime.

Do not persist credential stdout, auth progress, kubeconfig/environment dumps,
real terminal/log payloads, or screenshots of live auth/logs as evidence.
Redacted descriptions are not a universal secret scrubber: structured request,
Status, terminal, and log content must still be treated as sensitive. HTTP
diagnostics discard arbitrary/oversized bodies, bound decoded Status fields,
and redact the current bearer token; remote exec Status remains server content.
In-stream watch Status errors instead retain only code, allowlisted reason and
nonnegative retry delay, discarding free text/details before state or receipt storage.
Unsupported kubeconfig auth-provider/basic-auth/impersonation markers reject only
the selected context before credentials/IO and survive supported model round trips.
Kubix's credentials are memory-only, while external plugins may maintain their
own normal stores. The bridge is given socket/nonce configuration, not acquired
Kubernetes credentials; it is a relay, not a credential broker or security sandbox.

## Transport and liveness

`ContextTransportRegistry` supplies one `URLSessionTransport` per resolved
context. Each has purpose-specific ephemeral sessions sharing an immutable
`ClusterTrustPolicy`: no URL cache, cookie storage, or URL credential storage;
TLS 1.2 minimum; configured CA data/files and hostname/`tls-server-name`
validation through Security. Custom anchors replace system anchors for that
policy. `insecure-skip-tls-verify` is honored with a visible warning.
HTTP endpoints remain accepted, so TLS guarantees apply only to HTTPS/WSS.
Explicit kubeconfig proxy support is rejected, not silently bypassed.

Redirects are refused, even on the same host, to avoid forwarding bearer tokens.
Credentials are acquired before the network deadline and attached only in
transport. Ordinary requests/upgrade can make one refresh attempt on an exposed
401; 403 is terminal. WatchService owns its separate bounded refresh/retry budget
using transport-owner-bound receipts carrying the **actual acquired** identity and
generation. A different transport cannot consume the receipt, and stale generations
cannot invalidate replacements. No transport entry point invents a browser
login command, though configured credential plugins can initiate browser auth.

| Operation | Current policy |
| --- | --- |
| Ordinary requests / finite log reads | 30 s idle, 60 s total |
| Watch | 300 s server lease; 330 s idle/total client deadline |
| WebSocket upgrade | 30 s, after credential acquisition |
| Established exec liveness | First ping at 15 s; next 15 s after pong; 15 s pong deadline |
| Log follow / WebSocket session resource | 24 h idle, 7 days total |
| Authentication | Default 600 s for login plus reacquisition |

The native WebSocket delegate must report exactly `v5.channel.k8s.io`.
No older protocol is interpreted as v5. Foundation sometimes does not expose an
upgrade HTTP response/body; that case reports `upgradeResponseUnavailable`
instead of inventing a status or issuing a potentially duplicate exec probe.
An exposed HTTP rejection and a post-upgrade remotecommand Status are distinct.

An independent bounded receive pump keeps Foundation's pong callbacks moving
under consumer backpressure. Messages/queued bytes are capped at 1 MiB and the
queue at 256 messages; overflow fails visibly rather than dropping terminal data.
Heartbeat cancellation unblocks pending work. Credential expiry does not replay
an established shell; a new request can refresh while that shell stays active.

Source anchors: `API/TransportPolicy.swift`, Runtime `API/URLSessionTransport.swift`,
`ClusterTrustDelegate.swift`, `URLSessionWebSocketConnection.swift`,
`HeartbeatWebSocket.swift`, and `WebSocketReceiveBuffer.swift`.

## Complete resource snapshots and watches

**One watch, parameterized by kind.** `ResourceKind` is the whole difference
between the lists the app can show: the API group (pods are `api/v1`,
deployments `apis/apps/v1`), the resource segment, the noun its counts read
with, and two capabilities. `supportsShell` is pods-only because a deployment
has no single container to exec into; `supportsUsageColumns` is pods-only
because `metrics.k8s.io` reports per pod and has no deployment resource. The
pagination, resource-version, budget and retry machinery below is the same code
for every kind, and the row type carries a UID, metadata and printed cells
without caring which kind produced them.

`WatchService` requests namespaced metadata Tables in 500-row pages and follows
every continuation token. `ResourceSnapshot` validates consistent opaque resource
version and schema, namespace/identity/cell shape, duplicate UIDs, cursor cycles,
and budgets (1,000 pages, 100,000 rows, 128 MiB cumulative encoded input,
16 KiB cursor). These are application snapshot bounds, not a quota for all
Foundation allocations. Partial pages never become a complete published list.

Only after installing a complete snapshot does the service open a watch at its
resource version and publish `live`. `WatchState` owns ordered UID rows, optional
schema, latest **opaque** resource version, and retry/refresh budgets. Headerless
updates retain the schema. Data events advance resource version without requiring
bookmarks; bookmarks also advance it but do not prove a healthy full lease.

- Healthy EOF after the 300-second lease, before the client deadline, renews
  from the latest version with rows/schema retained and resets failure budgets.
- Early EOF, connection loss, timeout, 429, and 5xx back off while retaining
  last-known rows. Retry ceilings grow from 1 to 30 seconds with jitter;
  `Retry-After` can extend the delay. There are six retry attempts.
- A 410 expires the snapshot: rows/schema/version are cleared and the entire
  list is rebuilt, including after an expired continuation. Relists have a
  bounded six-attempt budget, not an infinite restart loop.
- 401 has one credential-refresh budget; exhausted refresh, 403, malformed
  streams, invalid snapshots, or exhausted retries stop visibly.
- Merely opening a connection, receiving a bookmark/event, or completing a
  relist does not reset failed-session budgets. Cancellation stops the owner
  without fabricating a server failure.

A complete snapshot whose watch is not yet established publishes `listed`, not `connecting`. The
distinction is not cosmetic: an apiserver defers a quiet watch's response until its first bookmark, so
an idle namespace measured 62 seconds between an installed, correct, empty list and `live`, and even a
busy one has been measured at 12 seconds. Calling that `connecting` tells the user nothing has arrived
while correct rows are on screen. `connecting` keeps its meaning — no complete snapshot yet, and any
rows shown are last-known and possibly stale.

The login-shell PATH probe is started at composition rather than on first use, because an interactive
shell loading version managers takes seconds and that cost otherwise lands inside the user's first
Connect.

**The store keeps one list slot and the kind it holds.** Exactly one watch runs,
so `rows`, `columns` and `connection` belong to `listKind` and to no other, and
an update carries the kind it describes: a publication that arrives after the
selection moved to another kind cannot be rendered under the wrong columns
rather than merely being unlikely to. Moving between `Pods` and `Deployments`
retires the previous watch the way moving `Pods` between clusters does, and
re-lists; the filter carries over, the sort self-heals when the schema changes,
and a selection cannot survive because the UIDs differ.

While `Deployments` is selected nothing watches pods, so an open pod log tab
stops receiving deletion evidence. That is absence of evidence, not false
evidence — the tail itself still fails when the pod goes — and the logs are not
paused, because the context and namespace have not changed.

The native Table view handles server columns, Wide/search/sort/selection
presentation. Initial configuration load is idle. Namespace drafts are committed
explicitly. Suggestions are local in-memory history until a cluster's own list
arrives; see the namespace discovery section below.
Refresh/context/reload cancels prior watch work and clears its presentation.
Generation checks reject late publications.

### Columns the app computes

A Table was once displayed exactly as printed. Two things a list needs are not in it, so the
presentation adds them on top of the server's columns, which keep their cell positions as ids.

- **Age.** The server prints an age once, when it builds the row, so a quiet pod's Age froze at its
  last event. The server's Age column is recognised by name and drawn from `metadata.creationTimestamp`
  instead, formatted as `kubectl get` does (`duration.HumanDuration`). It sorts by creation time,
  which never changes, so the presentation needs no clock; only the native table ticks, once a
  second, redrawing the Age cells that are on screen. A row without a creation time keeps the text
  the server printed.
- **CPU and Memory**, for pods only. From `metrics.k8s.io/v1beta1`, which has no watch: it is polled every fifteen
  seconds for as long as the pod watch runs, under the watch's generation, and retires with it. Values
  read as `kubectl top` prints them — CPU rounded up to a millicore, memory down to a mebibyte — and
  sort by the exact value. A pod with no sample shows `—` and sorts last either way: Pending,
  completed and just-started pods have none, which was a third of a live namespace.

A deployment has no usage columns at all, and no poll runs while one is selected. The metrics API
reports per pod; a deployment's number would mean walking pods → ReplicaSets → Deployment
ownerReferences and summing, which is a feature of its own rather than a column.

Availability is per cluster, so the columns do not vanish and return with each namespace change. A
404 means no metrics API and is not asked again until reconnect; a 403 stops that namespace's poll
without judging the cluster; anything else is retried. Numbers that stop being refreshed are cleared
after three minutes rather than shown as current. The metrics API names a pod but carries no UID, so
a sample whose window began before the pod was created is rejected: it belongs to a predecessor
recreated under the same name.

Live columns are not search keys — a filter matching `5m` would silently stop matching as the age
ticked past it. And a presentation that changes only cell contents redraws only those rows instead of
reloading the table, so a poll does not fight the user's scroll position and selection.

### Per-cluster connection versus the single active watch

`AppStore.clusters` holds one `ClusterStatus` per resolved context, each carrying
that context's immutable snapshot and a state of disconnected/connecting/
connected/failed. Its failure carries a rendered reason string, not an
`APIError`: credential acquisition, unsupported kubeconfig shapes and transport
errors all reach it without a common error type.

**Connect is one unnamespaced `GET /version`.** `ClusterProbeService` issues it
through the same per-context `Transport` a watch would use, so credentials are
acquired transport-side and a plugin can still request browser approval; the
transport never opens a browser itself. Success therefore means credentials were
accepted and the apiserver answered — never that any namespaced resource is
authorized. A list 403 is reported in the pane of a still-connected
cluster. Connect attempts are generation-keyed per cluster, so a superseded
probe cannot write its outcome, and probe tasks are cancelled and joined by
shutdown like every other owned task.

**Many clusters may be connected; exactly one watch runs.** `SidebarSelection`
is `.cluster(name)` or `.list(name, kind)`; grouping rows such as `Workload` are
not selection cases, so they cannot reach a watch. A `.list` on a connected
cluster is the only route into discovery, and moving it between clusters — or
between kinds on one cluster — cancels and joins the previous watch before
starting one. Selecting a cluster row is focus alone:
`selectedContext` means "the cluster in focus", which is also the cluster whose
pane is on screen, so the auth actions keyed to it always act on what the user
is looking at. Committing a namespace re-lists only while a `.list` is selected on
a connected cluster, and re-lists whichever kind that is; otherwise it commits
and starts nothing, because visible rows must never describe a namespace other
than the committed one.

### Namespace discovery

`ClusterStatus.namespaces` is a per-cluster `NamespaceDiscovery`: `unknown` (not
asked), `listed([String])` or `unavailable`. `unknown` and `unavailable` are
distinct on purpose — without that, a cluster that refused the request could not
be told from one never asked, and would be asked again every time the picker
opened.

`NamespaceListService` requests `/api/v1/namespaces` as a metadata-only Table and
follows its cursor under a page and byte budget; exceeding either throws rather
than returning a truncated list, because the caller *replaces* local history with
a complete one. A listed result therefore wins over typed history, and history is
still recorded so losing the permission later does not lose the names the user
typed.

A successful Connect lists once and clears any previous refusal — pressing Connect
asks for the whole handshake again, permissions included. Otherwise the only
refresh is the picker opening, throttled to 30 seconds by monotonic seconds, never
wall-clock dates. `unavailable` is silent and never retried automatically: a denied
list is a normal configuration, not a problem to report. The request goes through
the per-context transport, so it can acquire credentials and surface sign-in like
any other request; what it must never do is unseat the connection, so a listing
failure leaves the cluster `connected` and only marks discovery `unavailable`.

Results are keyed to the captured `ResolvedContext`, not the context name, so a
reload that redefines a cluster under the same name discards a list computed
against the old snapshot. The picker shows only the focused cluster's namespaces,
so a background cluster finishing its list cannot replace what is on screen.

Kubeconfig reload reconciles both through pure functions
(`ClusterStatus.reconcile`, `SidebarSelection.reconcile`) applied by
`AppActions`: a context keeps its state only while its whole snapshot is
unchanged, a removed context drops out, and a `.pods` selection whose cluster is
no longer connected falls back to that cluster's pane. Disconnect abandons the
cluster's watch and never its sessions — a running shell keeps the context,
namespace, pod and container it was opened against, and log tails pause as they
do for any scope change.

## Fresh selection and session lifecycles

Table cells are not container metadata. Shell and Logs fetch plain-JSON
`PodDetails` through the shared authenticated transport, retaining only identity,
default-container annotation, declared containers and states. The returned UID,
name, and namespace must match the captured row. Pending work also carries row
revision, selection/pod generations, and configuration revision.

Changing context/namespace, refreshing/reloading, filtering out/deleting/replacing
the row, changing its revision, or confirming an old picker cannot resurrect
pending work. Shell candidates are running regular containers only; readiness
is not required. Logs accept every declared container kind. Authentication and
WebSocket negotiation precede bridge/surface allocation. Once running, a shell
relinquishes its selection guard and keeps its immutable `ExecTarget`/UUID.

Kubernetes exec/log endpoints are name-addressed. Fresh UID checks detect observed
replacement, but cannot make details GET and exec/log GET atomic; there is no
server-side UID precondition. Do not describe this as race-free Pod binding.

### Deleting a pod

Delete is the one write, offered on a pod row's context menu only. Requesting it
captures the context, committed namespace, name, row UID and configuration
revision, and shows a confirmation naming all three of pod, namespace and
cluster; nothing is sent until it is confirmed. Confirm re-checks that context,
namespace and revision, then sends one `DELETE` carrying `DeleteOptions` with
`preconditions.uid` set to the row's UID.

Unlike exec and logs, this binding is server-enforced: a pod recreated under the
same name is refused with 409, not deleted. So there is no fresh details GET
first — it would only narrow a race the precondition closes. The default grace
period applies; there is no force delete.

The dialog is dismissed by a real scope change (`cancelList`: context, namespace,
kind, reload), not by the selected row's revision changing, which for a
crash-looping pod is every few seconds. Success says nothing: the watch shows the
pod terminating and then gone. A refusal or transport failure floats a diagnostic
naming the pod; a transport failure says the delete may or may not have happened,
because it may have reached the server. Only a 401 is retried, through the
transport's usual single refresh, since the server did not act on it. Shutdown
cancels and joins an in-flight delete, which stops waiting for an answer, not the
delete.

### One deck for both kinds of session

Shells and log tails share one strip, ordered by when they were opened, so the
store keeps one `SessionSelection` rather than a selected shell and a selected
log: two fields could represent two visible sessions, which the deck cannot show.
Collapsing the deck unmounts the bodies and leaves every session running — the
native check asserts the surface is not freed and the same terminal view is
remounted on restore.

Choosing a container is a menu on the button that asked for it, listing what the
pod declares with the role it gives each one — the `default-container`
annotation, a native sidecar's `restartPolicy: Always`, init and ephemeral — and
its state. Choosing opens immediately; there is no confirm step. A single
candidate opens without a menu. Switching container from a running session opens
a second session, or focuses the container's existing one, and never rebinds a
live session: a log tail revalidates through its own target, a shell reruns the
selected row's details.

`AppActions` owns tasks, attempt tokens, and `TerminalSurfaceLifetime`.
Tab switching/rehosting never frees the session's surface. Context/namespace
changes and reload pause logs without relabeling their retained data, while
running shells remain. Quit calls `shutdownAndWait`, joins owned watch/details/
auth/log/exec/settings work, then the app frees Ghostty.

### Bounded logs, not replay storage

`LogService` awaits each delivered batch before reading more. `LogLineDecoder`
keeps at most 16 KiB per unfinished line, discards overflow through newline, and
marks truncation/UTF-8 repair. It flushes partial text on EOF/interruption.
Chunks are limited to 64 KiB and batches to 64 lines. Each `LogBuffer` is a
fixed-slot ring capped at 2,000 entries and 2 MiB of UTF-8 text.

URLSession AsyncBytes is pull-based and its task is suspended between log reads
to stop new ingress under backpressure. Foundation/kernel in-flight buffers
remain outside an application-configurable byte quota. The native log view
virtualizes rows; filtering is local. Scrolling away from Latest preserves
retained-ID/pixel-offset anchoring, with an oldest-retained fallback on eviction.

Clean EOF, Pause, pre-open failure, and post-open interruption are distinct.
There is no automatic replay. Resume validates the **original UID** and container
again, keeps the buffer, and adds a fresh 200-line-tail segment boundary.
The gap may lose lines and the tail may duplicate them. A container switch creates
a new immutable target/UUID, leaving old lines in the old tab.

An authoritative complete **live** watch snapshot removing the UID cancels
following/connecting logs and reports deleted/replaced. A connecting or partial
relist is not deletion evidence. Resume rejects replacement independently.
Close drops the log buffer rather than retaining it as history.

### Aggregated logs: one tab, many streams

**Kubernetes has no aggregated log endpoint.** `apps/v1` Deployments expose only
`status` and `scale`; `pods/{name}/log` is the only log endpoint in the API. So
every client that shows a workload's logs — `kubectl` included, through
`--all-pods` — opens one stream per pod and interleaves them itself, and the
number of streams is the client's choice rather than a protocol limit.
`kubectl`'s `--max-log-requests` (default 5) is a client-side concurrency guard
applied only when following, and above it `kubectl` **refuses**. Kubix keeps the
guard and drops the refusal: a GUI tails the whole set up to
`TransportPolicy.maximumConcurrentLogStreams` (50) and says so when the set does
not fit, instead of making the user pass a flag and try again.

A `LogSession` therefore holds a `LogScope` — what the tab follows — and a
`LogSource` per stream, each with its own task and attempt token, all delivering
into the tab's one buffer. A pod's tab is the one-source case, so there is one
lifecycle, one deck tab and one close path rather than two of each.

- **The tab's state is derived, never assigned.** One following stream makes the
  tab following; otherwise one connecting makes it connecting; otherwise
  interruption outranks failure outranks a clean end, so a pod that died
  mid-stream is never hidden behind another's EOF. Pause is a recorded flag,
  because a cancelled stream is indistinguishable from several other endings
  from outside. A deployment that resolves to no pods reads `noPods`.
- **One pod going wrong is that pod's problem.** A rollout always has a replica
  that is not ready yet, which answers 400; a tab that failed whenever any of
  its pods did would be unusable on exactly the workloads it is for. The tab
  reports a failure only when no stream ever opened.
- **The pods are found by ownership, not by the selector.** A Deployment's
  `spec.selector` is not required to be unique, and charts routinely give
  `web` and `web-dj-slow` the same `app` label — so the first one's selector
  matches the second one's pods, and a label-based lookup tails both workloads
  while calling it one. Kubernetes answers this with
  `ownerReferences`: pods are owned by a ReplicaSet, which is owned by the
  Deployment. Two selector-scoped metadata Tables, therefore — the deployment's
  ReplicaSets, then the pods those own — and only the **controller** reference
  counts, so a pod adopted by nothing is nobody's to tail. The selector is still
  sent because it keeps both lists cheap on a large namespace; it is a filter
  for the server, not the answer. This needs `list replicasets` as well as
  `list pods`.
- **The pod set is resolved once, at open.** Names, UIDs and creation times are
  all a stream needs, and the container name comes from the template. Nothing
  reads a printed cell — the pods Table prints STATUS, but that is display text,
  not a container's state. New pods from a rollout are **not** adopted live; that
  needs a second, label-scoped pod watch. Resume re-reads the deployment,
  refuses one recreated under the same name, and re-resolves. The status line
  says the set is fixed, so a quiet tab during a rollout is explained.
- **A set-based selector is refused, not approximated.** Serializing
  `In`/`NotIn`/`Exists` into the label-selector grammar has a dozen encoding
  edges, and a mistake does not fail — it tails another workload's pods and
  looks like it worked. `LabelSelector` validates every key and value against
  the label grammar before they reach a URL, because `,` and `=` are the
  grammar's own separators: a key carrying one is a *different* selector rather
  than an invalid one, whatever the percent-encoding.
- **Newest pod first**, applied both by the listing and again where the ceiling
  is applied, so keeping the newest does not depend on a provider's politeness.
- **Lines interleave in arrival order**, not by timestamp: a merge needs a
  reorder window and would stall output to hold it. `timestamps=true` is already
  on, so real times are on screen. Each line carries the pod that logged it
  beside the text rather than prefixed into it, so the filter still matches what
  the pod wrote; the label is drawn only when the tab has more than one stream.
- **The bounds scale with the fan-out.** A 2,000-line ring split between forty
  pods is fifty lines each, which is not a tail, and a 200-line initial tail per
  pod would evict the whole ring before any of it was read. The ring grows by
  500 lines per extra stream to a 20,000-line / 8 MiB ceiling, and the
  per-stream tail is `max(20, 1000 / sources)`. A tab is created before its pods
  are known, so the ring is widened when they arrive — losslessly, preserving
  each retained line's id, because the log viewport anchors on one.
- **The `.logs` URLSession raises `httpMaximumConnectionsPerHost`** to the same
  ceiling. The default is 6, so over HTTP/1.1 the seventh pod's stream would
  queue behind the first six and the tab would claim to follow pods that were
  idle. HTTP/2 multiplexes and the limit should not bite; this no longer depends
  on which is served.

A deployment's log endpoints are name-addressed and take no UID precondition, so
the identity that answered is what proves the object is still the one clicked.
Both the service and the action check it: the action's check is what makes the
guarantee the app's rather than one provider's.

## Remote exec and the local PTY relay

The parent `ExecService` owns authenticated WebSocket, bridge, and outcome.
The same executable's early `--pty-bridge` branch in `kubix/main.swift` runs
before AppKit/app composition. It has no Kubernetes/auth orchestration:

```text
Ghostty surface <-> local raw PTY <-> kubix --pty-bridge
                                      |
                              private Unix socket
                                      |
                              parent ExecService <-> API server WebSocket
```

Normal shell argv selects `bash` or `sh` via `env TERM=xterm-256color`.
This is real remote shell authority, not enforced read-only execution.

### Wire and ownership contracts

- Local frames are one type byte, UInt32 big-endian payload length, then payload.
  Hello is a 32-byte nonce; data is at most 64 KiB; resize is two UInt16 values
  (columns, rows); closeInput has no payload; exit is one byte; failure is one
  of the allowlisted generic messages, never Kubernetes/plugin diagnostics.
- `PTYBridgeServer` creates a private `0700` directory using the fixed
  `/tmp/kubix-XXXXXX` template, not HOME/TMPDIR, and `0600` session sockets.
  Paths are checked against Darwin's 104-byte capacity including the NUL; they
  are never truncated. Local tests can inject a repository-owned short root.
- Socket/nonce are passed as `KUBIX_BRIDGE_SOCK`/`KUBIX_BRIDGE_NONCE` environment
  entries, not argv/logs. Parent checks peer UID. A nonce is consumed on the first
  hello attempt, success or failure. Hello then initial resize must complete
  within the five-second server handshake deadline before input is accepted.
- One peer is accepted; the listener unlinks only its owned socket name.
  Connected endpoints shutdown before close. Directory/socket cleanup checks
  exact ownership/inode and never recursively removes unrelated paths.
- The child saves termios and applies `cfmakeraw` without flushing queued input,
  restores it on termination, and handles partial/EINTR/nonblocking IO.
  Typed Ctrl-C/Ctrl-D travel as bytes to the remote TTY; actual local stdin EOF
  produces closeInput, not a fabricated successful remote exit.
- SIGWINCH is coalesced into resize; termination signals request cancellation.
  Dispatch signal callbacks only update flags. The worker owns descriptors and
  performs IO/restore/close; callbacks do not close potentially reused descriptors.
- One serialized child socket writer prevents input/resize interleaving, with
  bounded pending input/output and coalesced resize. Duplex pumps poll at most
  every 20 ms. Parent writes are serialized; failed partial writes poison the
  stream rather than appending another frame. Parent output/terminal delivery
  and child final-output drain have two-second bounds.

The parent translates to v5 remotecommand binary channels: stdin 0, stdout 1,
stderr 2, status 3, resize 4 (`Width`/`Height` JSON), and channel-close 255.
TTY requests disable separate stderr. Initial resize goes over the WebSocket
before `running` and before forwarding terminal input.

Only channel-3 `Status Success` or a valid `NonZeroExitCode` with its exit-code
cause yields a remote exit (0 or 1-255). A valid server failure after upgrade,
malformed protocol, transport close without status, heartbeat timeout, and local
child failure are separate outcomes. First observed outcome wins; teardown cannot
overwrite decoded remote status, and a local child's process exit is not proof
of remote success. Terminal failures are never silently replayed.

Source anchors: Core `Bridge/`, `Exec/`, `Model/TerminalConfiguration.swift`;
Runtime `Bridge/`, `Services/ExecService.swift`; app `main.swift`.

## Ghostty C boundary

Ghostty is pinned and built from source; its unstable embedding API is an owned
upgrade cost. `GhosttyApp` initializes bundled resources and a finalized config,
not another terminal application's user configuration or CLI settings.

`GhosttySurfaceView` creates a surface only after a nonzero backing-pixel size
and window attachment. The session retains its view/userdata through
`ghostty_surface_free`. That is the **single idempotent free path**; SwiftUI
`dismantleNSView` does not own it. Persistent C strings, including asynchronous
initial input, outlive surface use and are freed only after the surface.
The temporary environment-pointer array is borrowed only during `surface_new`.

C callbacks can arrive off the main actor. They copy borrowed strings before
returning, recover retained-lifetime userdata, and dispatch AppKit/observable
work to the main queue. They do not synchronously assume MainActor isolation or
carry borrowed callback pointers across an async hop. Queued closures retain
the view and check teardown; only immutable configuration is read directly.
App shutdown frees surfaces before the Ghostty app/config handles.

Keyboard/IME, paste/copy, mouse, focus, appearance, and backing-scale geometry
are adapted in `kubix/Ghostty/`. Terminal-initiated clipboard reads are denied;
clipboard writes requiring confirmation are not silently approved.
Only explicit AppKit paste temporarily enables the synchronous read callback, with
an injected clipboard source in native tests. Ghostty receives unconfirmed text and
requests approval for unsafe pastes. Pending requests complete with empty text on
Cancel/teardown before surface free; sheet completions are identity-guarded.
`TerminalConfiguration.bridge` quotes the app executable because Ghostty parses
an explicit command as shell text.

## Validation boundaries

`make test` / `swift test --package-path KubixCore` runs two Swift Testing targets:

- `KubixCoreTests`: decoding, request/protocol rules, cache/state/selection/
  buffer policy, and action/lifetime races through injected seams.
- `KubixRuntimeTests`: actual service orchestration and adapters with fake
  transports/clocks/materials, encoded fixtures, and controlled local processes,
  pipes, PTYs, and Unix sockets. They must not invoke real cloud plugins,
  browser/keychain, user startup files, or a cluster.

Use a targeted `--filter` for changed behavior, `make lint` for strict SwiftLint,
and `make build` for app changes. The fixed `scripts/test-terminal.sh` and
`scripts/test-pod-ui.sh` additionally require a built Debug app, GUI session, and
Metal. They select controlled inputs before live adapters; native rendering/
lifetime evidence is not browser or cluster authentication evidence.

Acceptance separately records current LIVE normal read-only integration, reused
genuine LIVE browser approval/raw-shell evidence, and CONTROLLED encoded scale/
fault checks (including actual elapsed quiet following beyond 60 seconds).
It does not claim live 1,000+ pods, forced add/delete/RBAC/expiry/fault scenarios,
or a live quiet-minute run. Client certificates remain unimplemented/unvalidated.
Live work requires explicit authorized scope and harmless commands; never
manufacture live events, expiry, or credential-store changes merely to test.
Live acceptance evidence is kept outside the repository.
