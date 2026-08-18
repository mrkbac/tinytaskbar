import Foundation
import Testing

@testable import TinyTaskbar

@MainActor
struct DockVisibilityTests {
    @Test("hiding and restoring preserves every affected Dock preference")
    func preservesDockPreferences() throws {
        let suiteName = "TinyTaskbarTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = MemoryDockPreferences(
            values: [
                "autohide": .boolean(false),
                "autohide-delay": .double(0.2),
            ])
        let controller = DockVisibilityController(
            preferences: preferences,
            defaults: defaults)

        try controller.setHidden(true)

        #expect(preferences.values["autohide"] == .boolean(true))
        #expect(
            preferences.values["autohide-delay"]
                == .double(DockVisibilityController.hiddenRevealDelay))
        #expect(preferences.values["autohide-time-modifier"] == .double(0))
        #expect(preferences.values["orientation"] == .string("left"))
        #expect(preferences.values["no-bouncing"] == .boolean(true))
        #expect(preferences.restartCount == 1)

        try controller.setHidden(false)

        #expect(preferences.values["autohide"] == .boolean(false))
        #expect(preferences.values["autohide-delay"] == .double(0.2))
        #expect(preferences.values["autohide-time-modifier"] == nil)
        #expect(preferences.values["orientation"] == nil)
        #expect(preferences.values["no-bouncing"] == nil)
        #expect(preferences.restartCount == 2)
    }

    @Test("a persisted backup survives a controller restart")
    func persistedBackupSurvivesRestart() throws {
        let suiteName = "TinyTaskbarTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = MemoryDockPreferences(
            values: [
                "autohide": .boolean(false),
                "autohide-delay": .double(0.5),
                "autohide-time-modifier": .double(0.25),
                "orientation": .string("bottom"),
                "no-bouncing": .boolean(false),
            ])

        try DockVisibilityController(preferences: preferences, defaults: defaults)
            .setHidden(true)
        try DockVisibilityController(preferences: preferences, defaults: defaults)
            .setHidden(true)
        try DockVisibilityController(preferences: preferences, defaults: defaults)
            .setHidden(false)

        #expect(preferences.values["autohide"] == .boolean(false))
        #expect(preferences.values["autohide-delay"] == .double(0.5))
        #expect(preferences.values["autohide-time-modifier"] == .double(0.25))
        #expect(preferences.values["orientation"] == .string("bottom"))
        #expect(preferences.values["no-bouncing"] == .boolean(false))
    }

    @Test("restoring without a saved change leaves the Dock untouched")
    func restoreWithoutBackupIsNoop() throws {
        let suiteName = "TinyTaskbarTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = MemoryDockPreferences(values: ["autohide": .boolean(false)])
        let controller = DockVisibilityController(
            preferences: preferences,
            defaults: defaults)

        try controller.setHidden(false)

        #expect(preferences.values == ["autohide": .boolean(false)])
        #expect(preferences.restartCount == 0)
    }

    @Test("an unreadable backup never gets replaced with already modified values")
    func unreadableBackupFailsClosed() {
        let suiteName = "TinyTaskbarTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(
            Data("not a Dock snapshot".utf8),
            forKey: "dockVisibility.originalPreferences.v1")
        let original = ["autohide": DockPreferenceValue.boolean(false)]
        let preferences = MemoryDockPreferences(values: original)
        let controller = DockVisibilityController(
            preferences: preferences,
            defaults: defaults)
        var didThrow = false

        do {
            try controller.setHidden(true)
        } catch {
            didThrow = true
        }

        #expect(didThrow)
        #expect(preferences.values == original)
        #expect(preferences.restartCount == 0)
    }
}

@MainActor
private final class MemoryDockPreferences: DockPreferencesAccess {
    var values: [String: DockPreferenceValue]
    private(set) var restartCount = 0

    init(values: [String: DockPreferenceValue]) {
        self.values = values
    }

    func value(forKey key: String) -> DockPreferenceValue? {
        values[key]
    }

    func setValue(_ value: DockPreferenceValue?, forKey key: String) {
        values[key] = value
    }

    func synchronize() throws {}

    func restartDock() throws {
        restartCount += 1
    }
}
