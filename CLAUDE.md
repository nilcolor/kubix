# Kubix contributor conventions

Read [README.md](README.md) for setup/scope and [ARCHITECTURE.md](ARCHITECTURE.md)
for ownership, authentication, and streaming contracts. Native validation and
evidence boundaries are in [docs/terminal-integration.md](docs/terminal-integration.md).

## Structure and tools

- Swift 6, strict concurrency, macOS 14 deployment target. Full Xcode/Metal,
  Homebrew, XcodeGen, and Zig 0.15.2 build the native app; SwiftLint is strict.
- `KubixCore/Package.swift` defines `KubixCore` and `KubixRuntime`. Runtime imports
  Core; the app imports both. Core must not import Runtime, AppKit, Ghostty, or
  Metal. Concrete process/network/PTY services belong in Runtime, not the app.
- `kubix/` owns composition, SwiftUI/AppKit adapters, Ghostty, and Debug drivers.
  `project.yml` is authoritative; do not hand-edit generated Xcode projects.
  Ghostty is pinned in `scripts/setup.sh`; upgrade deliberately with native checks.
- `make prep && make build` builds the Debug app; `make run` builds/opens it.
  `make test` runs both host-free Swift Testing targets under
  `KubixCore/Tests/{KubixCoreTests,KubixRuntimeTests}`.
  Use `swift test --package-path KubixCore --filter <SuiteOrTest>` for focused
  checks and `make lint` for strict lint. Docs-only changes need no build/tests
  unless a documentation-specific check exists.

## Preserve these contracts

- Route app-state/session changes through MainActor `AppActions`, not views.
  Services own IO; views never own stream or terminal lifetimes.
- Capture immutable context/target identities and stable session UUIDs.
  Use cancellation plus generation/attempt checks to reject stale callbacks.
  Fresh Pod details must match the original row UID; only running regular
  containers are shell candidates. Logs may target all declared container kinds.
- Keep credential acquisition/cache/login shared and generation-aware. Preserve
  source-relative kubeconfig paths, exact plugin argv/profile chains, and
  effective settings/environment identity. Never replace a configured wrapper
  with an invented direct AWS command. Browser recovery is explicit manual Retry;
  stdin-only/Always plugins and client certificates remain outside v0.1.
- Keep auth instructions/credentials transient and separate from diagnostics.
  Server CA/hostname validation is supported independently of deferred client
  certificates. Reject explicit `proxy-url` before credential/material/network IO.
- Install complete paginated Table snapshots before watching. Resource versions
  are opaque. Preserve watch lease/deadline/retry budgets and visible stale/error
  states; opening a connection or receiving a bookmark does not reset failures.
- Never replay a started exec after transport/auth failure or equate local child
  exit with remote status. Log Resume revalidates the original UID and starts a
  marked tail segment, not lossless/duplicate-free replay. Bound buffers and
  propagate backpressure; close/quit must cancel and join owned work.
- Keep the same-binary PTY bridge credential-free: raw terminal bytes, serialized
  framed IO, nonce/peer validation, fixed short socket paths, exact owned cleanup.
  Signal callbacks only notify; descriptor owners perform IO and teardown.
- The session alone frees a Ghostty surface, exactly once. Retain C strings and
  userdata through free; copy borrowed callback data and dispatch UI work to the
  main actor. SwiftUI rehosting must not destroy a running terminal.

## Validation and scope discipline

- Test real production services/actions through injected transports, clocks,
  processes, and encoded fixtures, not just success-shaped fake UI state.
  Host-free tests need no Ghostty/app host/Metal/cluster/user credentials.
- After relevant app changes, use existing controlled native checks:
  `bash scripts/test-terminal.sh` and `bash scripts/test-pod-ui.sh` after building.
  These require a GUI/Metal session and are not live cluster/auth evidence.
- Live validation is read-only by default and needs explicit target authorization.
  Do not create/delete resources to manufacture watch events, force auth expiry,
  alter credential stores, or run container writes/service signals. A real shell
  is not intrinsically read-only. Distinguish LIVE observations, reused LIVE
  evidence, and CONTROLLED synthetic scale/fault/native checks in reports.
- Never retain real kubeconfig, credentials, plugin output, authorization URLs,
  device codes, log/terminal payloads, or live auth/log screenshots as evidence.
  Use sanitized state/count/timing metadata and synthetic fixtures.
- No kubectl dependency, separate helper app, or general control API until
  explicitly scoped. UUIDs/AppActions reserve a future seam; Debug drivers are
  not a general automation interface. Do not broaden pod-only v0.1 incidentally.
