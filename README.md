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
buildkitd that lives in an Apple-managed Linux VM.

## Architecture (v1)

- **BuildKitCore** — backend-agnostic supervisor + state machine.
- **BuildKitContainerization** — default backend, links `apple/containerization`
  as a SwiftPM dependency.
- **BuildKitContainerCLI** — opt-in backend that shells out to the
  [`apple/container`](https://github.com/apple/container) CLI for users who
  prefer that path.
- **Crucible.app** — SwiftUI `MenuBarExtra` tray UI.

BuildKit runs as a single long-lived container using the upstream
`moby/buildkit:buildx-stable-1` image (user-overridable). The kernel comes from
the same Kata static release path used by Apple Containerization's default
kernel flow, pinned by URL and SHA256. Rosetta is enabled automatically when
available, binfmt_misc is registered in the VM, and BuildKit advertises both
`linux/arm64` and `linux/amd64` unless the user overrides worker platforms in
`buildkitd.toml`.

## Features

- Menubar lifecycle controls: start, stop, restart, logs, settings.
- Direct Apple Containerization backend by default.
- Optional Apple `container` CLI backend for comparison/debugging.
- Host unix socket exposure for `buildctl` and `docker buildx`.
- Persistent BuildKit state on an ext4 disk image.
- Custom BuildKit image reference and custom `buildkitd.toml`.
- Buildx registration/recreation/removal helpers.
- Storage inspection, prune/reset controls, and factory reset.
- Native logs window with search/filter/follow/export/copy.
- Diagnostics pane with prerequisites, effective daemon config, and copyable
  summary.

## Repository layout

```
Package.swift               # library targets (testable, headless)
Sources/
  BuildKitCore/             # supervisor, state, settings, protocols
  BuildKitContainerization/ # framework-backed implementation
  BuildKitContainerCLI/     # `container` CLI-backed implementation
Apps/Crucible/              # macOS .app target (Xcode-managed)
Tests/                      # unit tests
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
make dist       # build build/dist/Crucible.zip
```

The Xcode project is generated from `project.yml` via [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`). Both `project.yml` and the generated `Crucible.xcodeproj`
are committed; regenerate with `make project`.

## Smoke Tests

The headless smoke driver needs the virtualization entitlement when using the
framework backend:

```bash
swift build --product crucibled
codesign --force --sign - --entitlements Apps/Crucible/Resources/Crucible.entitlements .build/debug/crucibled
.build/debug/crucibled --smoke
```

The optional CLI backend can be smoked independently. It uses an isolated temp
socket and app root, starts `container system`, and passes Crucible's managed
kernel with `--kernel`:

```bash
swift build --product crucibled
.build/debug/crucibled --backend cli --smoke
```

To verify a running app daemon from the host:

```bash
BUILDKIT_HOST="unix://$HOME/Library/Application Support/Crucible/buildkitd.sock" buildctl debug workers
docker buildx inspect crucible
```

Expected worker platforms include `linux/arm64` and `linux/amd64` on Apple
silicon when Rosetta is available.

## Release Builds

Local zip builds do not require signing credentials:

```bash
make dist
```

Developer ID release/notarization targets are scaffolded and use environment
variables:

```bash
DEVELOPER_ID_APPLICATION="Developer ID Application: Example (TEAMID)" make release-zip
NOTARY_PROFILE="notarytool-keychain-profile" make notarize
make staple
```

## License

Apache-2.0. See [LICENSE](LICENSE).
