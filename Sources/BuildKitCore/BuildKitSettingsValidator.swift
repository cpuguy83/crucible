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
        case backendUnavailable(BuildKitSettings.BackendKind)
        case daemonConfigTooLarge(Int)
        case daemonConfigMalformed(String)
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

        if s.backend == .containerCLI {
            issues.append(.backendUnavailable(.containerCLI))
        }

        let configBytes = s.daemonConfigTOML.utf8.count
        if configBytes > 256 * 1024 {
            issues.append(.daemonConfigTooLarge(configBytes))
        } else if let issue = validateDaemonConfigShape(s.daemonConfigTOML) {
            issues.append(.daemonConfigMalformed(issue))
        }

        return issues
    }

    static func validateDaemonConfigShape(_ config: String) -> String? {
        let trimmed = config.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        for (index, rawLine) in config.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let lineNumber = index + 1
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }

            if let quoteIssue = validateQuotes(line) {
                return "line \(lineNumber): \(quoteIssue)"
            }

            if line.hasPrefix("[") {
                guard line.hasSuffix("]") else { return "line \(lineNumber): section header is missing closing ]" }
                var inner = line
                while inner.hasPrefix("[") { inner.removeFirst() }
                while inner.hasSuffix("]") { inner.removeLast() }
                if inner.trimmingCharacters(in: CharacterSet.whitespaces).isEmpty {
                    return "line \(lineNumber): section header is empty"
                }
                continue
            }

            if line.contains("=") { continue }
            return "line \(lineNumber): expected key = value or [section]"
        }

        return nil
    }

    private static func validateQuotes(_ line: String) -> String? {
        var single = false
        var double = false
        var escaped = false

        for ch in line {
            if escaped {
                escaped = false
                continue
            }
            if double && ch == "\\" {
                escaped = true
                continue
            }
            if ch == "'" && !double { single.toggle() }
            if ch == "\"" && !single { double.toggle() }
        }

        if single { return "unterminated single-quoted string" }
        if double { return "unterminated double-quoted string" }
        return nil
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
