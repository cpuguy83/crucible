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
        selectedBuilderID: String = BuilderConfig.defaultBuildKitID,
        builders: [BuilderConfig] = [.defaultBuildKit],
        buildxName: String = BuildxCommands.defaultBuilderName
    ) {
        self.selectedBuilderID = selectedBuilderID
        self.builders = builders.isEmpty ? [.defaultBuildKit] : builders
        self.buildxName = BuildxCommands.isValidBuilderName(buildxName) ? buildxName : BuildxCommands.defaultBuilderName
        if !self.builders.contains(where: { $0.id == self.selectedBuilderID }) {
            self.selectedBuilderID = self.builders[0].id
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            selectedBuilderID: try c.decodeIfPresent(String.self, forKey: .selectedBuilderID) ?? BuilderConfig.defaultBuildKitID,
            builders: try c.decodeIfPresent([BuilderConfig].self, forKey: .builders) ?? [.defaultBuildKit],
            buildxName: try c.decodeIfPresent(String.self, forKey: .buildxName) ?? BuildxCommands.defaultBuilderName
        )
    }

    public var selectedBuilder: BuilderConfig {
        builders.first { $0.id == selectedBuilderID } ?? builders[0]
    }

    public var selectedBuildKitSettings: BuildKitSettings {
        guard case .buildKit(let settings) = selectedBuilder.kind else {
            return BuildKitSettings()
        }
        return settings
    }

    public var selectedBuilderIsBuildKit: Bool { selectedBuilder.isBuildKit }

    public var selectedDockerSettings: DockerSettings {
        guard case .docker(let settings) = selectedBuilder.kind else {
            return DockerSettings()
        }
        return settings
    }

    public func selectingBuilder(id: String) -> AppSettings {
        AppSettings(
            selectedBuilderID: id,
            builders: builders,
            buildxName: buildxName
        )
    }

    public func upsertingBuilder(_ builder: BuilderConfig, select: Bool = false) -> AppSettings {
        var copy = self
        if let index = copy.builders.firstIndex(where: { $0.id == builder.id }) {
            copy.builders[index] = builder
        } else {
            copy.builders.append(builder)
        }
        if select {
            copy.selectedBuilderID = builder.id
        }
        return AppSettings(selectedBuilderID: copy.selectedBuilderID, builders: copy.builders, buildxName: copy.buildxName)
    }

    public func replacingSelectedBuildKitSettings(_ settings: BuildKitSettings) -> AppSettings {
        var copy = self
        guard let index = copy.builders.firstIndex(where: { $0.id == copy.selectedBuilderID }) else {
            return copy
        }
        guard case .buildKit = copy.builders[index].kind else {
            return copy
        }
        copy.builders[index].kind = .buildKit(settings)
        return copy
    }

    public func replacingSelectedDockerSettings(_ settings: DockerSettings) -> AppSettings {
        var copy = self
        guard let index = copy.builders.firstIndex(where: { $0.id == copy.selectedBuilderID }) else {
            return copy
        }
        guard case .docker = copy.builders[index].kind else {
            return copy
        }
        copy.builders[index].kind = .docker(settings)
        return copy
    }

    public static func migrating(_ settings: BuildKitSettings) -> AppSettings {
        AppSettings(builders: [.buildKit(id: BuilderConfig.defaultBuildKitID, name: "Crucible", settings: settings)])
    }
}

public struct BuilderConfig: Sendable, Equatable, Codable, Identifiable {
    public static let defaultBuildKitID = "crucible"

    public var id: String
    public var name: String
    public var kind: BuilderKind

    public init(id: String, name: String, kind: BuilderKind) {
        self.id = id
        self.name = name
        self.kind = kind
    }

    public var isBuildKit: Bool { kind.isBuildKit }

    public static let defaultBuildKit = BuilderConfig(
        id: defaultBuildKitID,
        name: "Crucible",
        kind: .buildKit(BuildKitSettings())
    )

    public static func buildKit(id: String, name: String, settings: BuildKitSettings) -> BuilderConfig {
        BuilderConfig(id: id, name: name, kind: .buildKit(settings))
    }

    public static func docker(id: String, name: String, settings: DockerSettings = DockerSettings()) -> BuilderConfig {
        BuilderConfig(id: id, name: name, kind: .docker(settings))
    }
}

public enum BuilderKind: Sendable, Equatable, Codable {
    case buildKit(BuildKitSettings)
    case docker(DockerSettings)

    private enum CodingKeys: String, CodingKey {
        case type
        case buildKit
        case docker
        case managedBuildKit
        case managedDocker
    }

    private enum KindType: String, Codable {
        case buildKit
        case docker
        case managedBuildKit
        case managedDocker
    }

    public var isBuildKit: Bool {
        if case .buildKit = self { return true }
        return false
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(KindType.self, forKey: .type) {
        case .buildKit:
            self = .buildKit(try c.decode(BuildKitSettings.self, forKey: .buildKit))
        case .managedBuildKit:
            self = .buildKit(try c.decode(BuildKitSettings.self, forKey: .managedBuildKit))
        case .docker:
            self = .docker(try c.decode(DockerSettings.self, forKey: .docker))
        case .managedDocker:
            self = .docker(try c.decode(DockerSettings.self, forKey: .managedDocker))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .buildKit(let settings):
            try c.encode(KindType.buildKit, forKey: .type)
            try c.encode(settings, forKey: .buildKit)
        case .docker(let settings):
            try c.encode(KindType.docker, forKey: .type)
            try c.encode(settings, forKey: .docker)
        }
    }
}

public struct DockerSettings: Sendable, Equatable, Codable {
    public enum BuildKitTransportMode: String, Sendable, Codable {
        case auto
        case directH2C
        case legacyGrpcUpgrade
    }

    public var imageReference: String
    public var transportMode: BuildKitTransportMode

    private enum CodingKeys: String, CodingKey {
        case imageReference
        case transportMode
    }

    public init(
        imageReference: String = "docker.io/library/docker:dind",
        transportMode: BuildKitTransportMode = .auto
    ) {
        self.imageReference = imageReference
        self.transportMode = transportMode
    }

    public init(from decoder: Decoder) throws {
        let defaults = DockerSettings()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            imageReference: try c.decodeIfPresent(String.self, forKey: .imageReference) ?? defaults.imageReference,
            transportMode: try c.decodeIfPresent(BuildKitTransportMode.self, forKey: .transportMode) ?? defaults.transportMode
        )
    }
}
