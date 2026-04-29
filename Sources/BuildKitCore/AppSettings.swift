import Foundation

public struct AppSettings: Sendable, Equatable, Codable {
    public var selectedBuilderID: String
    public var builders: [BuilderConfig]
    public var buildxName: String

    private enum CodingKeys: String, CodingKey {
        case selectedBuilderID
        case builders
        case buildxName
    }

    public init(
        selectedBuilderID: String = BuilderConfig.defaultManagedID,
        builders: [BuilderConfig] = [.defaultManaged],
        buildxName: String = BuildxCommands.defaultBuilderName
    ) {
        self.selectedBuilderID = selectedBuilderID
        self.builders = builders.isEmpty ? [.defaultManaged] : builders
        self.buildxName = BuildxCommands.isValidBuilderName(buildxName) ? buildxName : BuildxCommands.defaultBuilderName
        if !self.builders.contains(where: { $0.id == self.selectedBuilderID }) {
            self.selectedBuilderID = self.builders[0].id
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            selectedBuilderID: try c.decodeIfPresent(String.self, forKey: .selectedBuilderID) ?? BuilderConfig.defaultManagedID,
            builders: try c.decodeIfPresent([BuilderConfig].self, forKey: .builders) ?? [.defaultManaged],
            buildxName: try c.decodeIfPresent(String.self, forKey: .buildxName) ?? BuildxCommands.defaultBuilderName
        )
    }

    public var selectedBuilder: BuilderConfig {
        builders.first { $0.id == selectedBuilderID } ?? builders[0]
    }

    public var selectedManagedSettings: BuildKitSettings {
        guard case .managedBuildKit(let settings) = selectedBuilder.kind else {
            return BuildKitSettings()
        }
        return settings
    }

    public var selectedBuilderIsManaged: Bool { selectedBuilder.isManagedBuildKit }

    public func replacingSelectedManagedSettings(_ settings: BuildKitSettings) -> AppSettings {
        var copy = self
        guard let index = copy.builders.firstIndex(where: { $0.id == copy.selectedBuilderID }) else {
            return copy
        }
        guard case .managedBuildKit = copy.builders[index].kind else {
            return copy
        }
        copy.builders[index].kind = .managedBuildKit(settings)
        return copy
    }

    public static func migrating(_ settings: BuildKitSettings) -> AppSettings {
        AppSettings(builders: [.managed(id: BuilderConfig.defaultManagedID, name: "Crucible", settings: settings)])
    }
}

public struct BuilderConfig: Sendable, Equatable, Codable, Identifiable {
    public static let defaultManagedID = "crucible"

    public var id: String
    public var name: String
    public var kind: BuilderKind

    public init(id: String, name: String, kind: BuilderKind) {
        self.id = id
        self.name = name
        self.kind = kind
    }

    public var isManagedBuildKit: Bool { kind.isManagedBuildKit }

    public static let `defaultManaged` = BuilderConfig(
        id: defaultManagedID,
        name: "Crucible",
        kind: .managedBuildKit(BuildKitSettings())
    )

    public static func managed(id: String, name: String, settings: BuildKitSettings) -> BuilderConfig {
        BuilderConfig(id: id, name: name, kind: .managedBuildKit(settings))
    }
}

public enum BuilderKind: Sendable, Equatable, Codable {
    case managedBuildKit(BuildKitSettings)
    case managedDocker(ManagedDockerSettings)

    private enum CodingKeys: String, CodingKey {
        case type
        case managedBuildKit
        case managedDocker
    }

    private enum KindType: String, Codable {
        case managedBuildKit
        case managedDocker
    }

    public var isManagedBuildKit: Bool {
        if case .managedBuildKit = self { return true }
        return false
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(KindType.self, forKey: .type) {
        case .managedBuildKit:
            self = .managedBuildKit(try c.decode(BuildKitSettings.self, forKey: .managedBuildKit))
        case .managedDocker:
            self = .managedDocker(try c.decode(ManagedDockerSettings.self, forKey: .managedDocker))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .managedBuildKit(let settings):
            try c.encode(KindType.managedBuildKit, forKey: .type)
            try c.encode(settings, forKey: .managedBuildKit)
        case .managedDocker(let settings):
            try c.encode(KindType.managedDocker, forKey: .type)
            try c.encode(settings, forKey: .managedDocker)
        }
    }
}

public struct ManagedDockerSettings: Sendable, Equatable, Codable {
    public enum BuildKitTransportMode: String, Sendable, Codable {
        case auto
        case directH2C
        case legacyGrpcUpgrade
    }

    public var imageReference: String
    public var transportMode: BuildKitTransportMode

    public init(
        imageReference: String = "docker.io/library/docker:dind",
        transportMode: BuildKitTransportMode = .auto
    ) {
        self.imageReference = imageReference
        self.transportMode = transportMode
    }
}
