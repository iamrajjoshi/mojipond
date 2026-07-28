import Foundation

protocol PreferencesPersisting {
    func load() -> MojiPondPreferences
    func save(_ preferences: MojiPondPreferences)
}

/// Keeps the small user-preference document in UserDefaults while preserving a
/// single Codable source of truth for the runtime and every settings surface.
struct UserDefaultsPreferencesStore: PreferencesPersisting {
    static let storageKey = "preferences.document"

    private enum LegacyKey {
        static let isEnabled = "app.isEnabled"
        static let trigger = "shortcuts.trigger"
        static let acceptsTab = "shortcuts.acceptTab"
        static let acceptsReturn = "shortcuts.acceptReturn"
        static let exactReplacement = "shortcuts.exactReplacement"
        static let doubleTriggerBrowser = "shortcuts.doubleTriggerBrowser"
        static let stickersEnabled = "media.stickersEnabled"
        static let giphyEnabled = "media.giphyEnabled"
    }

    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> MojiPondPreferences {
        if let data = defaults.data(forKey: Self.storageKey) {
            guard var decoded = try? JSONDecoder().decode(
                MojiPondPreferences.self,
                from: data
            ), decoded.schemaVersion
                <= MojiPondPreferences.currentSchemaVersion else {
                return .defaults
            }
            decoded.schemaVersion = MojiPondPreferences.currentSchemaVersion
            save(decoded)
            return decoded
        }

        let migrated = migrateLegacyValues()
        save(migrated)
        return migrated
    }

    func save(_ preferences: MojiPondPreferences) {
        guard let data = try? JSONEncoder().encode(preferences) else {
            return
        }
        defaults.set(data, forKey: Self.storageKey)
    }

    private func migrateLegacyValues() -> MojiPondPreferences {
        var preferences = MojiPondPreferences.defaults

        if defaults.object(forKey: LegacyKey.isEnabled) != nil {
            preferences.activationMode = defaults.bool(forKey: LegacyKey.isEnabled)
                ? .enabled
                : .paused
        }
        if let rawTrigger = defaults.string(forKey: LegacyKey.trigger),
           let trigger = ShortcodeTrigger(rawValue: rawTrigger) {
            preferences.shortcode.trigger = trigger
        }
        if defaults.object(forKey: LegacyKey.acceptsTab) != nil {
            preferences.shortcode.acceptsTab = defaults.bool(
                forKey: LegacyKey.acceptsTab
            )
        }
        if defaults.object(forKey: LegacyKey.acceptsReturn) != nil {
            preferences.shortcode.acceptsReturn = defaults.bool(
                forKey: LegacyKey.acceptsReturn
            )
        }
        if defaults.object(forKey: LegacyKey.exactReplacement) != nil {
            preferences.shortcode.replacesOnExactClosingTrigger = defaults.bool(
                forKey: LegacyKey.exactReplacement
            )
        }
        if defaults.object(forKey: LegacyKey.doubleTriggerBrowser) != nil {
            preferences.shortcode.opensBrowserOnDoubleTrigger = defaults.bool(
                forKey: LegacyKey.doubleTriggerBrowser
            )
        }
        if defaults.object(forKey: LegacyKey.stickersEnabled) != nil {
            preferences.network.allowsStickerSearch = defaults.bool(
                forKey: LegacyKey.stickersEnabled
            )
        }
        if defaults.object(forKey: LegacyKey.giphyEnabled) != nil {
            preferences.network.allowsGIFSearch = defaults.bool(
                forKey: LegacyKey.giphyEnabled
            )
        }

        return preferences
    }
}
