import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
import SwiftProtobuf

public struct ActiveBuild: Equatable, Sendable {
    public var ref: String
    public var frontend: String
    public var target: String?
    public var completedSteps: Int
    public var totalSteps: Int
    public var cachedSteps: Int
    public var warnings: Int
    public var frontendAttrs: [String: String]

    public init(
        ref: String,
        frontend: String,
        target: String?,
        completedSteps: Int,
        totalSteps: Int,
        cachedSteps: Int,
        warnings: Int,
        frontendAttrs: [String: String] = [:]
    ) {
        self.ref = ref
        self.frontend = frontend
        self.target = target
        self.completedSteps = completedSteps
        self.totalSteps = totalSteps
        self.cachedSteps = cachedSteps
        self.warnings = warnings
        self.frontendAttrs = frontendAttrs
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

public struct RecentBuild: Equatable, Sendable, Identifiable {
    public var id: String { ref }
    public var ref: String
    public var frontend: String
    public var target: String?
    public var completedSteps: Int
    public var totalSteps: Int
    public var cachedSteps: Int
    public var warnings: Int
    public var createdAt: Date?
    public var completedAt: Date?
    public var errorMessage: String?
    public var errorCode: Int?
    public var frontendAttrs: [String: String]
    public var trace: BuildHistoryDescriptor?
    public var pinned: Bool

    public init(
        ref: String,
        frontend: String,
        target: String?,
        completedSteps: Int,
        totalSteps: Int,
        cachedSteps: Int,
        warnings: Int,
        createdAt: Date?,
        completedAt: Date?,
        errorMessage: String?,
        errorCode: Int? = nil,
        frontendAttrs: [String: String] = [:],
        trace: BuildHistoryDescriptor? = nil,
        pinned: Bool = false
    ) {
        self.ref = ref
        self.frontend = frontend
        self.target = target
        self.completedSteps = completedSteps
        self.totalSteps = totalSteps
        self.cachedSteps = cachedSteps
        self.warnings = warnings
        self.createdAt = createdAt
        self.completedAt = completedAt
        self.errorMessage = errorMessage
        self.errorCode = errorCode
        self.frontendAttrs = frontendAttrs
        self.trace = trace
        self.pinned = pinned
    }

    public var succeeded: Bool { errorMessage == nil }
}

public struct BuildHistorySnapshot: Equatable, Sendable {
    public var active: [ActiveBuild]
    public var recent: [RecentBuild]

    public init(active: [ActiveBuild], recent: [RecentBuild]) {
        self.active = active
        self.recent = recent
    }
}

public struct BuildHistoryDescriptor: Equatable, Sendable {
    public var mediaType: String
    public var digest: String
    public var size: Int64
    public var annotations: [String: String]

    public init(mediaType: String, digest: String, size: Int64, annotations: [String: String]) {
        self.mediaType = mediaType
        self.digest = digest
        self.size = size
        self.annotations = annotations
    }
}

public enum BuildLogEventKind: Equatable, Sendable {
    case log
    case vertex
    case warning
    case error
}

public struct BuildLogLine: Equatable, Sendable {
    public var timestamp: Date?
    public var message: String
    public var kind: BuildLogEventKind

    public init(timestamp: Date?, message: String, kind: BuildLogEventKind = .log) {
        self.timestamp = timestamp
        self.message = message
        self.kind = kind
    }
}

public enum RecentBuildsStatus: Equatable, Sendable {
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
            return count == 0 ? "No recent builds" : "\(count) recent"
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
    public func recentBuilds(limit: Int = 20) async throws -> [RecentBuild] {
        let transport = try HTTP2ClientTransport.Posix(
            target: .unixDomainSocket(path: socketPath),
            transportSecurity: .plaintext
        )

        return try await withGRPCClient(transport: transport) { client in
            var request = Moby_Buildkit_V1_BuildHistoryRequest()
            request.activeOnly = false
            request.earlyExit = true
            request.limit = Int32(limit)

            let control = Moby_Buildkit_V1_Control.Client(wrapping: client)
            return try await control.listenBuildHistory(request) { response in
                var buildsByRef: [String: RecentBuild] = [:]
                for try await event in response.messages {
                    apply(event, to: &buildsByRef)
                }
                return sortedRecentBuilds(buildsByRef, limit: limit)
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

    @available(macOS 15.0, *)
    public func watchBuildHistory(
        limit: Int = 20,
        onUpdate: @Sendable @escaping (BuildHistorySnapshot) async -> Void
    ) async throws {
        let transport = try HTTP2ClientTransport.Posix(
            target: .unixDomainSocket(path: socketPath),
            transportSecurity: .plaintext
        )

        try await withGRPCClient(transport: transport) { client in
            var request = Moby_Buildkit_V1_BuildHistoryRequest()
            request.activeOnly = false
            request.earlyExit = false
            request.limit = Int32(limit)

            let control = Moby_Buildkit_V1_Control.Client(wrapping: client)
            try await control.listenBuildHistory(request) { response in
                var activeByRef: [String: ActiveBuild] = [:]
                var recentByRef: [String: RecentBuild] = [:]
                await onUpdate(BuildHistorySnapshot(active: [], recent: []))
                for try await event in response.messages {
                    try Task.checkCancellation()
                    apply(event, to: &activeByRef)
                    apply(event, to: &recentByRef)
                    await onUpdate(BuildHistorySnapshot(
                        active: activeByRef.values.sorted { $0.ref < $1.ref },
                        recent: sortedRecentBuilds(recentByRef, limit: limit)
                    ))
                }
            }
        }
    }

    @available(macOS 15.0, *)
    public func buildLogs(ref: String) async throws -> [BuildLogLine] {
        let transport = try HTTP2ClientTransport.Posix(
            target: .unixDomainSocket(path: socketPath),
            transportSecurity: .plaintext
        )

        return try await withGRPCClient(transport: transport) { client in
            var request = Moby_Buildkit_V1_StatusRequest()
            request.ref = ref

            let control = Moby_Buildkit_V1_Control.Client(wrapping: client)
            return try await control.status(request) { response in
                var lines: [BuildLogLine] = []
                for try await update in response.messages {
                    lines.append(contentsOf: buildLogLines(from: update))
                }
                return lines
            }
        }
    }

    @available(macOS 15.0, *)
    public func watchBuildLogs(
        ref: String,
        onUpdate: @Sendable @escaping ([BuildLogLine]) async -> Void
    ) async throws {
        let transport = try HTTP2ClientTransport.Posix(
            target: .unixDomainSocket(path: socketPath),
            transportSecurity: .plaintext
        )

        try await withGRPCClient(transport: transport) { client in
            var request = Moby_Buildkit_V1_StatusRequest()
            request.ref = ref

            let control = Moby_Buildkit_V1_Control.Client(wrapping: client)
            try await control.status(request) { response in
                for try await update in response.messages {
                    try Task.checkCancellation()
                    let lines = buildLogLines(from: update)
                    if !lines.isEmpty {
                        await onUpdate(lines)
                    }
                }
            }
        }
    }

    @available(macOS 15.0, *)
    public func buildTrace(_ descriptor: BuildHistoryDescriptor) async throws -> Data {
        let transport = try HTTP2ClientTransport.Posix(
            target: .unixDomainSocket(path: socketPath),
            transportSecurity: .plaintext
        )

        return try await withGRPCClient(transport: transport) { client in
            var request = Containerd_Services_Content_V1_ReadContentRequest()
            request.digest = descriptor.digest
            request.size = descriptor.size

            let content = Containerd_Services_Content_V1_Content.Client(wrapping: client)
            return try await content.read(request) { response in
                var data = Data()
                for try await chunk in response.messages {
                    data.append(chunk.data)
                }
                return data
            }
        }
    }

    @available(macOS 15.0, *)
    public func updateBuildHistory(ref: String, pinned: Bool? = nil, delete: Bool = false, finalize: Bool = false) async throws {
        let transport = try HTTP2ClientTransport.Posix(
            target: .unixDomainSocket(path: socketPath),
            transportSecurity: .plaintext
        )

        try await withGRPCClient(transport: transport) { client in
            var request = Moby_Buildkit_V1_UpdateBuildHistoryRequest()
            request.ref = ref
            if let pinned {
                request.pinned = pinned
            }
            request.delete = delete
            request.finalize = finalize

            let control = Moby_Buildkit_V1_Control.Client(wrapping: client)
            _ = try await control.updateBuildHistory(request)
        }
    }
}

func buildLogLines(from update: Moby_Buildkit_V1_StatusResponse) -> [BuildLogLine] {
    var lines: [BuildLogLine] = []

    for vertex in update.vertexes {
        let name = vertex.name.isEmpty ? vertex.digest : vertex.name
        guard !name.isEmpty else { continue }
        if !vertex.error.isEmpty {
            lines.append(BuildLogLine(timestamp: nil, message: "failed: \(name): \(vertex.error)", kind: .error))
        } else if vertex.cached {
            lines.append(BuildLogLine(timestamp: nil, message: "cached: \(name)", kind: .vertex))
        } else {
            lines.append(BuildLogLine(timestamp: nil, message: "started: \(name)", kind: .vertex))
        }
    }

    for log in update.logs {
        let text = String(decoding: log.msg, as: UTF8.self).trimmingCharacters(in: .newlines)
        guard !text.isEmpty else { continue }
        lines.append(BuildLogLine(timestamp: log.hasTimestamp ? log.timestamp.date : nil, message: text, kind: .log))
    }

    for warning in update.warnings {
        let short = String(decoding: warning.short, as: UTF8.self).trimmingCharacters(in: .newlines)
        guard !short.isEmpty else { continue }
        var message = "warning: \(short)"
        if !warning.url.isEmpty {
            message += " (\(warning.url))"
        }
        lines.append(BuildLogLine(timestamp: nil, message: message, kind: .warning))
        for detail in warning.detail {
            let text = String(decoding: detail, as: UTF8.self).trimmingCharacters(in: .newlines)
            guard !text.isEmpty else { continue }
            lines.append(BuildLogLine(timestamp: nil, message: "warning detail: \(text)", kind: .warning))
        }
    }

    return lines
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

private func sortedRecentBuilds(_ buildsByRef: [String: RecentBuild], limit: Int) -> [RecentBuild] {
    Array(buildsByRef.values.sorted { lhs, rhs in
        switch (lhs.completedAt, rhs.completedAt) {
        case let (l?, r?): return l > r
        case (_?, nil): return true
        case (nil, _?): return false
        case (nil, nil): return lhs.ref > rhs.ref
        }
    }.prefix(limit))
}

private func apply(_ event: Moby_Buildkit_V1_BuildHistoryEvent, to buildsByRef: inout [String: RecentBuild]) {
    let record = event.record
    guard !record.ref.isEmpty else { return }

    switch event.type {
    case .started, .complete:
        buildsByRef[record.ref] = RecentBuild(record: record)
    case .deleted:
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
            warnings: Int(record.numWarnings),
            frontendAttrs: record.frontendAttrs
        )
    }
}

extension RecentBuild {
    init(record: Moby_Buildkit_V1_BuildHistoryRecord) {
        self.init(
            ref: record.ref,
            frontend: record.frontend.isEmpty ? "unknown" : record.frontend,
            target: record.frontendAttrs["target"],
            completedSteps: Int(record.numCompletedSteps),
            totalSteps: Int(record.numTotalSteps),
            cachedSteps: Int(record.numCachedSteps),
            warnings: Int(record.numWarnings),
            createdAt: record.hasCreatedAt ? record.createdAt.date : nil,
            completedAt: record.hasCompletedAt ? record.completedAt.date : nil,
            errorMessage: record.hasError && !record.error.message.isEmpty ? record.error.message : nil,
            errorCode: record.hasError ? Int(record.error.code) : nil,
            frontendAttrs: record.frontendAttrs,
            trace: record.hasTrace ? BuildHistoryDescriptor(record.trace) : nil,
            pinned: record.pinned
        )
    }
}

extension BuildHistoryDescriptor {
    init(_ descriptor: Moby_Buildkit_V1_Descriptor) {
        self.init(
            mediaType: descriptor.mediaType,
            digest: descriptor.digest,
            size: descriptor.size,
            annotations: descriptor.annotations
        )
    }
}

private extension Google_Protobuf_Timestamp {
    var date: Date {
        Date(timeIntervalSince1970: TimeInterval(seconds) + TimeInterval(nanos) / 1_000_000_000)
    }
}
