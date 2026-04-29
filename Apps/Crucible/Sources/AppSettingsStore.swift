import Foundation
import BuildKitCore

enum AppSettingsStore {
    static var settingsURL: URL {
        StorageUsage.appSupportDirectory().appendingPathComponent("settings.json")
    }

    static func load() -> AppSettings {
        let url = settingsURL
        guard let data = try? Data(contentsOf: url) else { return AppSettings() }

        let decoder = JSONDecoder()
        if let settings = try? decoder.decode(AppSettings.self, from: data) {
            try? save(settings)
            return settings
        }

        if let legacy = try? decoder.decode(BuildKitSettings.self, from: data) {
            let migrated = AppSettings.migrating(legacy)
            try? save(migrated)
            return migrated
        }

        return AppSettings()
    }

    static func save(_ settings: AppSettings) throws {
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

    static func delete() throws {
        let url = settingsURL
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
}
