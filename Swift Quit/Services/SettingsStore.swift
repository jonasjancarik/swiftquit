//
//  SettingsStore.swift
//  Swift Quit
//

import Foundation

@MainActor
final class SettingsStore {
    private enum Keys {
        static let settings = "SwiftQuitSettingsV2"
        static let migrationVersion = "SwiftQuitMigrationVersion"
        static let legacySettings = "SwiftQuitSettings"
        static let legacyTrackedApps = "SwiftQuitExcludedApps"
    }

    private let userDefaults: UserDefaults
    private let applicationCatalog: ApplicationCataloging
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private(set) var settings: AppSettings

    convenience init(userDefaults: UserDefaults = .standard) {
        self.init(userDefaults: userDefaults, applicationCatalog: ApplicationCatalog())
    }

    init(userDefaults: UserDefaults = .standard, applicationCatalog: ApplicationCataloging) {
        self.userDefaults = userDefaults
        self.applicationCatalog = applicationCatalog
        self.settings = AppSettings.default

        load()
    }

    func update(_ mutate: (inout AppSettings) -> Void) {
        mutate(&settings)
        settings.normalize()
        persist()
    }

    func replaceTrackedApps(_ trackedApps: [TrackedAppRule]) {
        update { settings in
            settings.trackedApps = trackedApps
        }
    }

    private func load() {
        if let data = userDefaults.data(forKey: Keys.settings) {
            do {
                settings = try decoder.decode(AppSettings.self, from: data)
                settings.normalize()
                persist()
                return
            } catch {
                AppLoggers.settings.error("Failed to decode v2 settings: \(error.localizedDescription)")
            }
        }

        if let migratedSettings = migrateLegacySettingsIfNeeded() {
            settings = migratedSettings
        } else {
            settings = AppSettings.default
        }

        settings.normalize()
        persist()
    }

    private func persist() {
        do {
            let data = try encoder.encode(settings)
            userDefaults.set(data, forKey: Keys.settings)
            userDefaults.set(AppSettings.currentMigrationVersion, forKey: Keys.migrationVersion)
        } catch {
            AppLoggers.settings.error("Failed to persist settings: \(error.localizedDescription)")
        }
    }

    private func migrateLegacySettingsIfNeeded() -> AppSettings? {
        let recordedMigrationVersion = userDefaults.integer(forKey: Keys.migrationVersion)
        guard recordedMigrationVersion < AppSettings.currentMigrationVersion else {
            return nil
        }

        let legacySettings = userDefaults.object(forKey: Keys.legacySettings) as? [String: String] ?? [:]
        let legacyTrackedApps = userDefaults.object(forKey: Keys.legacyTrackedApps) as? [String] ?? []

        guard !legacySettings.isEmpty || !legacyTrackedApps.isEmpty else {
            return nil
        }

        var migrated = AppSettings.default
        migrated.launchAtLoginEnabled = legacySettings["launchAtLogin"] == "true"
        migrated.menuBarIconEnabled = legacySettings["menubarIconEnabled"] != "false"
        migrated.launchHidden = legacySettings["launchHidden"] != "false"
        migrated.closeDelaySeconds = Int(legacySettings["closeDelay"] ?? "") ?? AppSettings.default.closeDelaySeconds
        migrated.ruleMode = legacySettings["excludeBehaviour"] == "includeApps" ? .onlyIncluded : .allExceptExcluded
        migrated.trackedApps = legacyTrackedApps.compactMap { path in
            let bundleURL = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL

            if let rule = applicationCatalog.trackedRule(for: bundleURL) {
                return rule
            }

            return TrackedAppRule(
                bundleIdentifier: nil,
                bundleURL: bundleURL,
                displayName: bundleURL.deletingPathExtension().lastPathComponent
            )
        }

        AppLoggers.settings.info("Migrated legacy Swift Quit settings")
        return migrated
    }
}
