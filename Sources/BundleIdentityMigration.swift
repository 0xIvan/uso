import Foundation
import ServiceManagement

enum BundleIdentityMigration {
    static let currentIdentifier = "com.ivan.uso"
    static let legacyIdentifier = "local.codex.usage-rings"
    static let pendingLoginItemKey = "restoreLoginItemAfterBundleMigration"

    static func migratePreferences(defaults: UserDefaults = .standard) {
        guard Bundle.main.bundleIdentifier == currentIdentifier,
              !defaults.bool(forKey: "migratedLegacyBundlePreferences") else { return }
        var values = defaults.persistentDomain(forName: currentIdentifier) ?? [:]
        for (key, value) in defaults.persistentDomain(forName: legacyIdentifier) ?? [:] where values[key] == nil && key != "SUFeedURL" {
            values[key] = value
        }
        if let enabled = values["openAtLogin"] as? Bool { values[pendingLoginItemKey] = enabled }
        values["migratedLegacyBundlePreferences"] = true
        defaults.setPersistentDomain(values, forName: currentIdentifier)
    }

    static func restoreLoginItem(defaults: UserDefaults = .standard) throws {
        guard defaults.bool(forKey: pendingLoginItemKey) else { return }
        if SMAppService.mainApp.status != .enabled && SMAppService.mainApp.status != .requiresApproval {
            try SMAppService.mainApp.register()
        }
        if SMAppService.mainApp.status == .enabled || SMAppService.mainApp.status == .requiresApproval {
            defaults.removeObject(forKey: pendingLoginItemKey)
        }
    }
}
