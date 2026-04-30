import Foundation

public enum BuilderConfigValidator {
    public enum Issue: Error, Sendable, Equatable {
        case buildKit(BuildKitSettingsValidator.Issue)
        case dockerImageReferenceEmpty
        case dockerImageReferenceMalformed(String)
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
        let ref = settings.imageReference.trimmingCharacters(in: .whitespaces)
        if ref.isEmpty {
            return [.dockerImageReferenceEmpty]
        }
        if !BuildKitSettingsValidator.isPlausibleImageReference(ref) {
            return [.dockerImageReferenceMalformed(ref)]
        }
        return []
    }
}
