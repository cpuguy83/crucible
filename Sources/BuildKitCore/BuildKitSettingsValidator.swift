import Foundation

/// Validates settings before they're persisted. Pure; no I/O.
public enum BuildKitSettingsValidator {
    public enum Issue: Error, Sendable, Equatable {
        case imageReferenceEmpty
        case imageReferenceMalformed(String)
        case socketPathEmpty
        case socketPathNotAbsolute(String)
        case cpuCountOutOfRange(Int)
        case memoryOutOfRange(Int)
    }

    public static func validate(_ s: BuildKitSettings) -> [Issue] {
        var issues: [Issue] = []

        let ref = s.imageReference.trimmingCharacters(in: .whitespaces)
        if ref.isEmpty {
            issues.append(.imageReferenceEmpty)
        } else if !isPlausibleImageReference(ref) {
            issues.append(.imageReferenceMalformed(ref))
        }

        if s.hostSocketPath.isEmpty {
            issues.append(.socketPathEmpty)
        } else if !s.hostSocketPath.hasPrefix("/") {
            issues.append(.socketPathNotAbsolute(s.hostSocketPath))
        }

        if s.cpuCount < 1 || s.cpuCount > 64 {
            issues.append(.cpuCountOutOfRange(s.cpuCount))
        }

        if s.memoryMiB < 512 || s.memoryMiB > 256 * 1024 {
            issues.append(.memoryOutOfRange(s.memoryMiB))
        }

        return issues
    }

    /// Cheap structural check. Real OCI reference parsing is delegated to the
    /// backend at pull time; this just rejects obviously broken inputs early.
    static func isPlausibleImageReference(_ ref: String) -> Bool {
        // Must contain at least one of `:` (tag) or `@` (digest), and a name part.
        guard ref.contains(":") || ref.contains("@") else { return false }
        // No whitespace.
        if ref.contains(" ") || ref.contains("\t") { return false }
        // Must start with an alphanumeric or registry host char.
        guard let first = ref.first, first.isLetter || first.isNumber else { return false }
        return true
    }
}
