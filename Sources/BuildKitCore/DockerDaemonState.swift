import Foundation

public enum DockerDaemonState: Sendable, Equatable {
    case stopped
    case starting
    case running(endpoint: DockerDaemonEndpoint)
    case stopping
    case error(String)
}

public struct DockerDaemonEndpoint: Sendable, Equatable, Hashable {
    public var socketPath: String

    public init(socketPath: String) {
        self.socketPath = socketPath
    }

    public var url: String { "unix://\(socketPath)" }
}
