# Crucible

A macOS menubar app that runs and supervises a [BuildKit](https://github.com/moby/buildkit)
daemon on top of Apple's [Containerization](https://github.com/apple/containerization)
framework, and exposes it to host build clients (`docker buildx`, `buildctl`) over a
local unix socket.

> Status: **early / experimental**. Apple silicon + macOS 26 only.

## Why

`apple/containerization` gives macOS a first-class way to run Linux containers in
lightweight VMs. BuildKit is the de-facto OCI image builder. Crucible glues the
two together with a tray UI so you can run `docker buildx build` against a
buildkitd that lives in an Apple-managed Linux VM, with no Docker Desktop or
colima in the picture.

## Architecture (v1)

- **BuildKitCore** — backend-agnostic supervisor + state machine.
- **BuildKitContainerization** — default backend, links `apple/containerization`
  as a SwiftPM dependency.
- **BuildKitContainerCLI** — opt-in backend that shells out to the
  [`apple/container`](https://github.com/apple/container) CLI for users who
  prefer that path.
- **BuildKitSocketProxy** — vsock ↔ unix-socket bridge so host clients can talk
  to buildkitd at a stable filesystem path.
- **Crucible.app** — SwiftUI `MenuBarExtra` tray UI.

BuildKit runs as a single long-lived container using the upstream
`moby/buildkit:buildx-stable-1` image (user-overridable). The kernel comes from
`apple/containerization`'s optimized default kernel.

## Repository layout

```
Package.swift               # library targets (testable, headless)
Sources/
  BuildKitCore/             # supervisor, state, settings, protocols
  BuildKitContainerization/ # framework-backed implementation
  BuildKitContainerCLI/     # `container` CLI-backed implementation
  BuildKitSocketProxy/      # vsock <-> unix proxy
  BuildKitImage/            # OCI pull / rootfs assembly helpers
Apps/Crucible/              # macOS .app target (Xcode-managed)
Tests/                      # unit tests
images/buildkitd/           # docs / pinned image references
scripts/                    # bootstrap, sign, notarize helpers
docs/                       # design notes
```

## Requirements

- Apple silicon Mac
- macOS 26 (Tahoe)
- Xcode 26 / Swift 6.x

## Building

```bash
make build      # swift build for libraries
make test       # unit tests
make app        # build Crucible.app via xcodebuild
make run        # build and launch the app
```

The Xcode project is generated from `project.yml` via [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`). Both `project.yml` and the generated `Crucible.xcodeproj`
are committed; regenerate with `make project`.

## License

Apache-2.0. See [LICENSE](LICENSE).
