# Roadmap

## M1 — Skeleton ✅
- SwiftPM package with `BuildKitCore`, `BuildKitContainerization`, `BuildKitContainerCLI`.
- `BuildKitBackend` protocol, `BuildKitState`, `BuildKitSettings`, validator,
  `BuildKitSupervisor` actor, `StubBackend`.
- `Crucible.app` target via XcodeGen; ad-hoc signed with virtualization entitlement.
- Unit tests for validator + supervisor.
- README, LICENSE, Makefile, .gitignore.

## M2 — Containerization backend MVP ✅ (code; pending hardware acceptance)
- `KernelLocator`: resolution chain — override path → Crucible-cached download
  → apple/container CLI install dir → fresh download via `KernelDownloader`.
- `KernelDownloader`: mirrors `apple/containerization`'s
  `make fetch-default-kernel` — fetches the Kata Containers static release
  tarball (pinned URL), extracts `opt/kata/share/kata-containers/vmlinux.container`
  via `ContainerizationArchive`, caches the binary at a stable hash-keyed path.
- Download progress is forwarded to `BuildKitBackend.progressStream` as
  `BuildKitProgress(phase: .downloadingKernel, ...)` with byte counts and a
  fraction when content-length is known.
- `LineWriter`: `Containerization.Writer` adapter that splits guest stdio into
  newline-delimited strings and pipes them into `BuildKitBackend.logStream`.
- `ContainerizationBackend`:
  - Build local OCI `LocalContentStore` + `ImageStore` under
    `~/Library/Application Support/Crucible/`.
  - `ContainerManager(kernel:initfsReference:imageStore:network:)` pulls vminit.
  - `manager.create(_:reference:)` pulls + unpacks `moby/buildkit` into a
    cached ext4 rootfs (`containers/crucible-buildkitd/rootfs.ext4`).
  - `UnixSocketConfiguration(.outOf)` exposes `/run/buildkit/buildkitd.sock`
    (guest) at `~/Library/Application Support/Crucible/buildkitd.sock` (host).
  - `useInit = true` so signals/zombies are handled inside the container.
  - `container.create()` then `container.start()` launches buildkitd.
  - In-guest health check: `container.exec("buildctl debug workers")` polled
    until success or 60s timeout. Confirms kernel compatibility, daemon
    readiness, and OCI worker health in one shot.
  - Background `wait()` task transitions to `.degraded` if buildkitd exits
    unexpectedly.
  - Graceful `stop()` / `restart()` / `pullImage()`.

### M2 outstanding
- **Acceptance test on real Apple silicon hardware**: requires network access
  to fetch the Kata kernel tarball (~140 MiB compressed, first run only),
  the vminit OCI image, and `docker.io/moby/buildkit:latest`. Verify
  `BUILDKIT_HOST=unix://~/Library/Application\ Support/Crucible/buildkitd.sock buildctl debug workers`
  works from the host.

## M3 — Tray actions wired to real backend
- Replace `TrayViewModel`'s static state observation with subscriptions to
  `supervisor.stateStream()` / `progressStream()`.
- "Pull / update image" menu action calling `supervisor.pullImage()`.
- Logs window tailing `logStream`.
- Error UX: surface `BuildKitBackendError` cases legibly.

## M4 — Settings window
- Editable backend kind, image reference, init reference, host socket
  path, CPU, memory, kernel override, autostart.
- Validation surfacing (already implemented in `BuildKitSettingsValidator`).
- Persistence to `~/Library/Application Support/Crucible/settings.json`.
- Live-reload behavior on save (stop/restart if backend kind changed).

## M5 — CLI backend
- `ContainerCLIBackend` real impl shelling out to `container`.
- Discover binary, run `container run` + own host UDS exposure.

## M6 — Polish
- Autostart via `SMAppService`.
- Packaging script (`.app` zip), Developer ID signing config.
- Notarization plumbing.

## Later
- Build history & active solves panel (gRPC `Control` API).
- Cache prune UI.
- Multi-instance / multi-version buildkitd.
- SHA256 verification of the downloaded kernel tarball against a pinned
  digest (currently we trust the GitHub release URL).
- Bundle a kernel inside the `.app` to skip the first-run download entirely.
