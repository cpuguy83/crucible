import Foundation

public enum BuilderConfigValidator {
    public enum Issue: Error, Sendable, Equatable {
        case buildKit(BuildKitSettingsValidator.Issue)
        case dockerImageReferenceEmpty
        case dockerImageReferenceMalformed(String)
        case dockerInitfsReferenceEmpty
        case dockerInitfsReferenceMalformed(String)
        case dockerCPUCountOutOfRange(Int)
        case dockerMemoryOutOfRange(Int)
        case dockerDaemonConfigTooLarge(Int)
        case dockerDaemonConfigMalformed(String)
    }

    public static func validate(_ builder: BuilderConfig) -> [Issue] {
        switch builder.kind {
        case .buildKit(let settings):
            return BuildKitSettingsValidator.validate(settings).map(Issue.buildKit)
        case .docker(let settings):
            return validate(settings)
        }
    }

    public static func validate(_ settings: DockerSettings) -> [Issue] {
        var issues: [Issue] = []
        let ref = settings.imageReference.trimmingCharacters(in: .whitespaces)
        if ref.isEmpty {
            return [.dockerImageReferenceEmpty]
        }
        if !BuildKitSettingsValidator.isPlausibleImageReference(ref) {
            issues.append(.dockerImageReferenceMalformed(ref))
        }

        let initfsRef = settings.initfsReference.trimmingCharacters(in: .whitespaces)
        if initfsRef.isEmpty {
            issues.append(.dockerInitfsReferenceEmpty)
        } else if !BuildKitSettingsValidator.isPlausibleImageReference(initfsRef) {
            issues.append(.dockerInitfsReferenceMalformed(initfsRef))
        }

        if settings.cpuCount < 1 || settings.cpuCount > 64 {
            issues.append(.dockerCPUCountOutOfRange(settings.cpuCount))
        }

        if settings.memoryMiB < 512 || settings.memoryMiB > 256 * 1024 {
            issues.append(.dockerMemoryOutOfRange(settings.memoryMiB))
        }

        let configBytes = settings.daemonConfigJSON.utf8.count
        if configBytes > 256 * 1024 {
            issues.append(.dockerDaemonConfigTooLarge(configBytes))
        } else if let issue = validateDockerDaemonConfig(settings.daemonConfigJSON) {
            issues.append(.dockerDaemonConfigMalformed(issue))
        }
        return issues
    }

    private static func validateDockerDaemonConfig(_ config: String) -> String? {
        let trimmed = config.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let data = trimmed.data(using: .utf8) else { return "config is not valid UTF-8" }
        do {
            let object = try JSONSerialization.jsonObject(with: data)
            guard object is [String: Any] else { return "top-level value must be a JSON object" }
        } catch {
            return error.localizedDescription
        }
        return nil
    }
}
