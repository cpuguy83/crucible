import Foundation
import BuildKitContainerization

struct PrerequisiteCheck: Sendable, Equatable {
    enum Status: Sendable, Equatable {
        case ok
        case warning
        case failed

        var symbol: String {
            switch self {
            case .ok: "checkmark.circle.fill"
            case .warning: "exclamationmark.triangle.fill"
            case .failed: "xmark.circle.fill"
            }
        }
    }

    var name: String
    var status: Status
    var detail: String
}
