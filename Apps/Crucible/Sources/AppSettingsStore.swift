import Foundation
import BuildKitCore

enum AppSettingsStore {
    static var settingsURL: URL {
        StorageUsage.appSupportDirectory().appendingPathComponent("settings.json")
    }

    static func load() -> BuildKitSettings {
        let url = settingsURL
        guard let data = try? Data(contentsOf: url),
              let settings = try? JSONDecoder().decode(BuildKitSettings.self, from: data)
        else { return BuildKitSettings(autoStart: true) }
        return settings
    }

    static func save(_ settings: BuildKitSettings) throws {
        let url = settingsURL
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(settings)
        try data.write(to: url, options: [.atomic])
    }
}
