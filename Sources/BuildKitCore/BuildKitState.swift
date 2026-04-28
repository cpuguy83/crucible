import Foundation

/// Coarse lifecycle state of the BuildKit daemon, as observed by the supervisor.
///
/// The supervisor owns the canonical state and emits transitions to UI layers.
/// Keep this enum simple; per-step progress (e.g. "pulling image",
/// "creating rootfs") is conveyed via ``BuildKitProgress`` events on a
/// separate channel.
public enum BuildKitState: Sendable, Equatable {
    case stopped
    case starting
    case running(endpoint: BuildKitEndpoint)
    case degraded(reason: String, endpoint: BuildKitEndpoint?)
    case stopping
    case error(String)
}

/// Where host clients can reach buildkitd.
///
/// In v1 we always present this to the user as a unix socket path on the host;
/// the backend may internally use vsock or TCP and bridge it to that socket.
public struct BuildKitEndpoint: Sendable, Equatable, Hashable {
    /// Filesystem path to the unix domain socket on the host.
    public var socketPath: String

    public init(socketPath: String) {
        self.socketPath = socketPath
    }

    /// `unix://` URL form suitable for `BUILDKIT_HOST` and
    /// `docker buildx create --driver remote`.
    public var url: String { "unix://\(socketPath)" }
}

/// Granular progress signal emitted during long-running transitions
/// (image pull, rootfs build, VM boot). Purely advisory; not part of state.
public struct BuildKitProgress: Sendable, Equatable {
    public enum Phase: String, Sendable {
        case downloadingKernel
        case pullingImage
        case preparingRootfs
        case bootingVM
        case startingDaemon
        case healthCheck
        case shuttingDown
    }

    public var phase: Phase
    public var message: String
    /// 0.0...1.0 if known, nil otherwise.
    public var fraction: Double?

    public init(phase: Phase, message: String, fraction: Double? = nil) {
        self.phase = phase
        self.message = message
        self.fraction = fraction
    }
}
