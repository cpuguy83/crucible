import Foundation

public struct BuilderStoragePaths: Sendable, Equatable {
    public var appSupportRoot: URL
    public var builderID: String

    public init(
        appSupportRoot: URL = BuilderStoragePaths.defaultAppSupportRoot(),
        builderID: String = BuilderConfig.defaultBuildKitID
    ) {
        self.appSupportRoot = appSupportRoot
        self.builderID = builderID
    }

    public var root: URL {
        if builderID == BuilderConfig.defaultBuildKitID {
            return appSupportRoot
        }
        return appSupportRoot
            .appendingPathComponent("builders", isDirectory: true)
            .appendingPathComponent(builderID, isDirectory: true)
    }

    public var buildKitSocketURL: URL {
        root.appendingPathComponent("buildkitd.sock")
    }

    public var buildKitStateImageURL: URL {
        root.appendingPathComponent("buildkit-state.ext4")
    }

    public var buildKitDaemonConfigURL: URL {
        root.appendingPathComponent("buildkitd.toml")
    }

    public var dockerSocketURL: URL {
        root.appendingPathComponent("docker.sock")
    }

    public var dockerDataRootURL: URL {
        root.appendingPathComponent("docker-data", isDirectory: true)
    }

    public static func defaultAppSupportRoot() -> URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Crucible", isDirectory: true)
    }
}
