import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2

public struct ActiveBuild: Equatable, Sendable {
    public var ref: String
    public var frontend: String
    public var target: String?
    public var completedSteps: Int
    public var totalSteps: Int
    public var cachedSteps: Int
    public var warnings: Int

    public init(
        ref: String,
        frontend: String,
        target: String?,
        completedSteps: Int,
        totalSteps: Int,
        cachedSteps: Int,
        warnings: Int
    ) {
        self.ref = ref
        self.frontend = frontend
        self.target = target
        self.completedSteps = completedSteps
        self.totalSteps = totalSteps
        self.cachedSteps = cachedSteps
        self.warnings = warnings
    }
}

public enum ActiveBuildStatus: Equatable, Sendable {
    case notChecked
    case checking
    case reconnecting(String)
    case stopped
    case unavailable(String)
    case ready(Int)

    public var displayText: String {
        switch self {
        case .notChecked:
            return "Not checked"
        case .checking:
            return "Checking..."
        case .reconnecting(let message):
            return "Reconnecting: \(message)"
        case .stopped:
            return "BuildKit is not running"
        case .unavailable(let message):
            return "Unavailable: \(message)"
        case .ready(let count):
            return count == 0 ? "No active builds" : "\(count) active"
        }
    }
}

public func isTransientActiveBuildError(_ error: Error) -> Bool {
    guard let rpcError = error as? RPCError else { return false }
    return rpcError.code == .unavailable
}

public struct BuildHistoryClient: Sendable {
    public var socketPath: String

    public init(socketPath: String) {
        self.socketPath = socketPath
    }

    @available(macOS 15.0, *)
    public func activeBuilds(limit: Int = 20) async throws -> [ActiveBuild] {
        let transport = try HTTP2ClientTransport.Posix(
            target: .unixDomainSocket(path: socketPath),
            transportSecurity: .plaintext
        )

        return try await withGRPCClient(transport: transport) { client in
            var request = Moby_Buildkit_V1_BuildHistoryRequest()
            request.activeOnly = true
            request.earlyExit = true
            request.limit = Int32(limit)

            let control = Moby_Buildkit_V1_Control.Client(wrapping: client)
            return try await control.listenBuildHistory(request) { response in
                var buildsByRef: [String: ActiveBuild] = [:]
                for try await event in response.messages {
                    apply(event, to: &buildsByRef)
                }
                return buildsByRef.values.sorted { $0.ref < $1.ref }
            }
        }
    }

    @available(macOS 15.0, *)
    public func watchActiveBuilds(
        limit: Int = 20,
        onUpdate: @Sendable @escaping ([ActiveBuild]) async -> Void
    ) async throws {
        let transport = try HTTP2ClientTransport.Posix(
            target: .unixDomainSocket(path: socketPath),
            transportSecurity: .plaintext
        )

        try await withGRPCClient(transport: transport) { client in
            var request = Moby_Buildkit_V1_BuildHistoryRequest()
            request.activeOnly = true
            request.earlyExit = false
            request.limit = Int32(limit)

            let control = Moby_Buildkit_V1_Control.Client(wrapping: client)
            try await control.listenBuildHistory(request) { response in
                var buildsByRef: [String: ActiveBuild] = [:]
                await onUpdate([])
                for try await event in response.messages {
                    try Task.checkCancellation()
                    apply(event, to: &buildsByRef)
                    await onUpdate(buildsByRef.values.sorted { $0.ref < $1.ref })
                }
            }
        }
    }
}

private func apply(_ event: Moby_Buildkit_V1_BuildHistoryEvent, to buildsByRef: inout [String: ActiveBuild]) {
    let record = event.record
    guard !record.ref.isEmpty else { return }

    switch event.type {
    case .started:
        buildsByRef[record.ref] = ActiveBuild(record: record)
    case .complete, .deleted:
        buildsByRef.removeValue(forKey: record.ref)
    case .UNRECOGNIZED:
        return
    }
}

extension ActiveBuild {
    init(record: Moby_Buildkit_V1_BuildHistoryRecord) {
        self.init(
            ref: record.ref,
            frontend: record.frontend.isEmpty ? "unknown" : record.frontend,
            target: record.frontendAttrs["target"],
            completedSteps: Int(record.numCompletedSteps),
            totalSteps: Int(record.numTotalSteps),
            cachedSteps: Int(record.numCachedSteps),
            warnings: Int(record.numWarnings)
        )
    }
}
