import Foundation
import Testing

@testable import TinyTaskbar

struct FeatureModelTests {
    @Test("retained defaults preserve existing behavior")
    func retainedDefaults() {
        let preferences = TinyTaskbarPreferences.defaults
        #expect(preferences.activeWindowClickBehavior == .minimize)
        #expect(preferences.orderingMode == .windowOrder)
        #expect(preferences.labelMode == .windowTitle)
        #expect(preferences.density == .standard)
        #expect(preferences.buttonWidth == .balanced)
        #expect(preferences.overflowBehavior == .shrinkThenScroll)
        #expect(preferences.displayMode == .windowDisplay)
        #expect(preferences.pinnedApplications.isEmpty)
        #expect(preferences.excludedApplications.isEmpty)
    }

    @Test("invalid typed preferences retain current defaults")
    @MainActor
    func invalidTypedPreferenceDefaults() {
        let suite = "TinyTaskbarTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("removed-mode", forKey: "labelMode")
        defaults.set("removed-width", forKey: "buttonWidth")
        defaults.set("removed-overflow", forKey: "overflowBehavior")
        defaults.set("removed-display-mode", forKey: "displayMode")
        let preferences = TinyTaskbarPreferencesStore(defaults: defaults).values
        #expect(preferences.labelMode == .windowTitle)
        #expect(preferences.buttonWidth == .balanced)
        #expect(preferences.overflowBehavior == .shrinkThenScroll)
        #expect(preferences.displayMode == .windowDisplay)
    }

    @Test("application record persistence discards only invalid records")
    @MainActor
    func lossyApplicationRecordPersistence() {
        let suite = "TinyTaskbarTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let json = """
            [
              {"identity":"com.example.Editor","bundleIdentifier":"com.example.Editor","bundlePath":null,"localizedName":"Editor","sequence":0},
              {"broken":true},
              {"identity":"","bundleIdentifier":null,"bundlePath":null,"localizedName":"Invalid","sequence":2}
            ]
            """
        defaults.set(Data(json.utf8), forKey: "pinnedApplications")
        let records = TinyTaskbarPreferencesStore(defaults: defaults).values.pinnedApplications
        #expect(records.map(\.identity) == ["com.example.Editor"])
    }

    @Test("pinning and exclusion are mutually exclusive and last action wins")
    @MainActor
    func pinExclusionConflict() {
        let suite = "TinyTaskbarTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = TinyTaskbarPreferencesStore(defaults: defaults)
        let app = application("com.example.Editor", name: "Editor")

        store.exclude(app)
        store.pin(app)
        #expect(store.values.excludedApplications.isEmpty)
        #expect(store.values.pinnedApplications.map(\.identity) == [app.identity])

        store.exclude(app)
        #expect(store.values.pinnedApplications.isEmpty)
        #expect(store.values.excludedApplications.map(\.identity) == [app.identity])
    }

    @Test("pinned content leads each display and closed pins become launchers")
    func pinnedPresentation() {
        let pinned = application("com.example.Editor", name: "Editor")
        let other = application("com.example.Browser", name: "Browser")
        let displays = [display("left"), display("right")]
        let state = TaskbarState(
            displays: displays,
            itemsByDisplay: [
                "left": [
                    item("browser", app: other, display: "left", order: "1"),
                    item("editor", app: pinned, display: "left", order: "2"),
                ],
                "right": [item("browser-right", app: other, display: "right", order: "1")],
            ])
        var preferences = TinyTaskbarPreferences.defaults
        preferences.pinnedApplications = [pinned]
        let presentation = TaskbarPresentationBuilder.build(state: state, preferences: preferences)

        #expect(
            presentation.entriesByDisplay["left"]?.map(\.id) == [
                "editor", "separator:left", "browser",
            ])
        #expect(
            presentation.entriesByDisplay["right"]?.map(\.id) == [
                "launcher:com.example.Editor", "separator:right", "browser-right",
            ])
    }

    @Test("exclusions remove every app window and grouping preserves first occurrence")
    func exclusionAndGrouping() {
        let editor = application("com.example.Editor", name: "Editor")
        let browser = application("com.example.Browser", name: "Browser")
        let state = TaskbarState(
            displays: [display("main")],
            itemsByDisplay: [
                "main": [
                    item("editor-1", app: editor, display: "main", order: "1"),
                    item("browser-1", app: browser, display: "main", order: "2"),
                    item("editor-2", app: editor, display: "main", order: "3"),
                ]
            ])
        var grouped = TinyTaskbarPreferences.defaults
        grouped.orderingMode = .groupByApplication
        #expect(
            TaskbarPresentationBuilder.build(state: state, preferences: grouped)
                .entriesByDisplay["main"]?.map(\.id)
                == ["editor-1", "editor-2", "browser-1"])

        grouped.excludedApplications = [editor]
        #expect(
            TaskbarPresentationBuilder.build(state: state, preferences: grouped)
                .entriesByDisplay["main"]?.map(\.id) == ["browser-1"])
    }

    @Test("multi-display modes preserve ownership, mirror windows, or use only main")
    func multiDisplayModes() {
        let app = application("com.example.Editor", name: "Editor")
        let left = display("left", ordinal: 1)
        let main = display("main", ordinal: 0, isMain: true)
        let state = TaskbarState(
            displays: [left, main],
            itemsByDisplay: [
                "left": [item("left-window", app: app, display: "left", order: "1")],
                "main": [item("main-window", app: app, display: "main", order: "2")],
            ])

        var preferences = TinyTaskbarPreferences.defaults
        let owned = TaskbarPresentationBuilder.build(state: state, preferences: preferences)
        #expect(owned.entriesByDisplay["left"]?.map(\.id) == ["left-window"])
        #expect(owned.entriesByDisplay["main"]?.map(\.id) == ["main-window"])

        preferences.displayMode = .everyDisplay
        let mirrored = TaskbarPresentationBuilder.build(state: state, preferences: preferences)
        #expect(mirrored.entriesByDisplay["left"]?.map(\.id) == ["left-window", "main-window"])
        #expect(mirrored.entriesByDisplay["main"]?.map(\.id) == ["left-window", "main-window"])

        preferences.displayMode = .mainDisplayOnly
        let mainOnly = TaskbarPresentationBuilder.build(state: state, preferences: preferences)
        #expect(mainOnly.displays.map(\.identifier) == ["main"])
        #expect(mainOnly.entriesByDisplay["main"]?.map(\.id) == ["left-window", "main-window"])
        #expect(mainOnly.entriesByDisplay["left"] == nil)
    }

    @Test("multi-display mode persists as a typed preference")
    @MainActor
    func multiDisplayModePersistence() {
        let suite = "TinyTaskbarTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = TinyTaskbarPreferencesStore(defaults: defaults)

        store.setDisplayMode(.everyDisplay)

        #expect(TinyTaskbarPreferencesStore(defaults: defaults).values.displayMode == .everyDisplay)
    }

    @Test("label and density constants cover every reviewed combination")
    func appearanceConstants() {
        let app = application("com.example.Editor", name: "Editor")
        let window = item("window", app: app, display: "main", order: "1")
        #expect(window.buttonTitle(labelMode: .windowTitle) == "Window window")
        #expect(window.buttonTitle(labelMode: .applicationName) == "Editor")
        #expect(window.buttonTitle(labelMode: .iconOnly).isEmpty)
        #expect(window.accessibilityLabel == "Editor, Window window")
        #expect(TaskbarDensity.standard.panelHeight == 30)
        #expect(TaskbarDensity.compact.panelHeight == 26)
        #expect(TaskbarButtonLayout.widthRange(labelMode: .iconOnly, density: .compact) == 28...28)
    }

    @Test("overflow shrinks labels before scrolling and can switch to icons")
    func overflowResolution() {
        let comfortable = TaskbarOverflowLayout.resolve(
            viewportWidth: 900,
            windowCount: 5,
            fixedContentWidth: 10,
            requestedLabelMode: .windowTitle,
            density: .standard,
            buttonWidth: .balanced,
            behavior: .shrinkThenScroll)
        #expect(comfortable.labelMode == .windowTitle)
        #expect(comfortable.windowWidth == 178)
        #expect(!comfortable.requiresScrolling)

        let scrolling = TaskbarOverflowLayout.resolve(
            viewportWidth: 500,
            windowCount: 5,
            fixedContentWidth: 10,
            requestedLabelMode: .windowTitle,
            density: .standard,
            buttonWidth: .balanced,
            behavior: .shrinkThenScroll)
        #expect(scrolling.labelMode == .windowTitle)
        #expect(scrolling.windowWidth == TaskbarButtonLayout.titleOnMinimumWidth)
        #expect(scrolling.requiresScrolling)

        let automaticIcons = TaskbarOverflowLayout.resolve(
            viewportWidth: 500,
            windowCount: 5,
            fixedContentWidth: 10,
            requestedLabelMode: .windowTitle,
            density: .standard,
            buttonWidth: .balanced,
            behavior: .automaticIcons)
        #expect(automaticIcons.labelMode == .iconOnly)
        #expect(automaticIcons.windowWidth == 32)
        #expect(!automaticIcons.requiresScrolling)
    }

    @Test("button width presets adjust both compression and preferred width")
    func buttonWidthPresets() {
        let narrow = TaskbarButtonLayout.widthRange(
            labelMode: .windowTitle, density: .standard, buttonWidth: .narrow)
        let balanced = TaskbarButtonLayout.widthRange(
            labelMode: .windowTitle, density: .standard, buttonWidth: .balanced)
        let wide = TaskbarButtonLayout.widthRange(
            labelMode: .windowTitle, density: .standard, buttonWidth: .wide)
        #expect(narrow.lowerBound < balanced.lowerBound)
        #expect(narrow.upperBound < balanced.upperBound)
        #expect(wide.lowerBound > balanced.lowerBound)
        #expect(wide.upperBound > balanced.upperBound)
    }

    private func application(_ identity: String, name: String) -> ApplicationRecord {
        ApplicationRecord(
            identity: identity,
            bundleIdentifier: identity,
            bundlePath: "/Applications/\(name).app",
            localizedName: name,
            sequence: 0)
    }

    private func display(
        _ id: String,
        ordinal: Int = 0,
        isMain: Bool = false
    ) -> DisplayDescriptor {
        DisplayDescriptor(
            identifier: id,
            frame: CGRect(x: 0, y: 0, width: 1000, height: 800),
            ordinal: ordinal,
            isMain: isMain)
    }

    private func item(
        _ id: String,
        app: ApplicationRecord,
        display: String,
        order: String
    ) -> TaskbarItem {
        TaskbarItem(
            id: id,
            pid: 10,
            applicationName: app.localizedName,
            applicationIdentity: app.identity,
            applicationBundlePath: app.bundlePath,
            title: "Window \(id)",
            displayIdentifier: display,
            cgWindowNumber: nil,
            stableOrderKey: order,
            isActive: false)
    }
}
