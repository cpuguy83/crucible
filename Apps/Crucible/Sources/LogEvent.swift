import Foundation
import SwiftUI

enum LogSource: String, CaseIterable, Identifiable, Sendable {
    case supervisor = "Supervisor"
    case progress = "Progress"
    case state = "State"
    case buildkitd = "BuildKit"
    case buildx = "Buildx"

    var id: String { rawValue }

    var color: Color {
        switch self {
        case .supervisor: .secondary
        case .progress: .blue
        case .state: .purple
        case .buildkitd: .primary
        case .buildx: .green
        }
    }
}

enum LogLevel: String, Sendable {
    case debug
    case info
    case warning
    case error
}

struct LogEvent: Identifiable, Sendable, Equatable {
    let id: UUID
    let timestamp: Date
    let source: LogSource
    let level: LogLevel?
    let message: String

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        source: LogSource,
        level: LogLevel? = nil,
        message: String
    ) {
        self.id = id
        self.timestamp = timestamp
        self.source = source
        self.level = level
        self.message = message
    }

    var rawLine: String {
        let stamp = Self.timestampFormatter.string(from: timestamp)
        let levelPart = level.map { " [\($0.rawValue.uppercased())]" } ?? ""
        return "\(stamp) [\(source.rawValue)]\(levelPart) \(message)"
    }

    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()
}
