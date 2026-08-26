import Foundation
import Testing

@testable import TinyTaskbar

struct FeatureModelTests {
    @Test("defaults contain only persisted user choices")
    func retainedDefaults() {
        #expect(TinyTaskbarPreferences.defaults == TinyTaskbarPreferences())
        #expect(!TinyTaskbarPreferences.defaults.onboardingComplete)
        #expect(!TinyTaskbarPreferences.defaults.hideMacDock)
    }

    @Test("removed customization and application preferences are ignored")
    @MainActor
    func removedPreferencesAreIgnored() {
        let suite = "TinyTaskbarTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("removed-mode", forKey: "labelMode")
        defaults.set("removed-width", forKey: "buttonWidth")
        defaults.set("removed-overflow", forKey: "overflowBehavior")
        defaults.set("removed-display-mode", forKey: "displayMode")
        defaults.set(Data("[]".utf8), forKey: "pinnedApplications")
        defaults.set(Data("[]".utf8), forKey: "excludedApplications")
        #expect(TinyTaskbarPreferencesStore(defaults: defaults).values == .defaults)
    }

    @Test("presentation preserves stable window order")
    func stablePresentation() {
        let state = TaskbarState(
            displays: [display("main")],
            itemsByDisplay: [
                "main": [
                    item("third", display: "main", order: "3"),
                    item("first", display: "main", order: "1"),
                    item("second", display: "main", order: "2"),
                ]
            ])

        let presentation = TaskbarPresentationBuilder.build(state: state)
        #expect(presentation.itemsByDisplay["main"]?.map(\.id) == ["first", "second", "third"])
    }

    @Test("windows remain on their physical displays")
    func physicalDisplayOwnership() {
        let left = display("left", ordinal: 1)
        let main = display("main", ordinal: 0, isMain: true)
        let state = TaskbarState(
            displays: [left, main],
            itemsByDisplay: [
                "left": [item("left-window", display: "left", order: "1")],
                "main": [item("main-window", display: "main", order: "2")],
            ])

        let presentation = TaskbarPresentationBuilder.build(state: state)
        #expect(presentation.itemsByDisplay["left"]?.map(\.id) == ["left-window"])
        #expect(presentation.itemsByDisplay["main"]?.map(\.id) == ["main-window"])
    }

    @Test("fixed standard appearance uses window titles and balanced widths")
    func fixedAppearance() {
        let window = item("window", display: "main", order: "1")
        #expect(window.buttonTitle == "Window window")
        #expect(window.accessibilityLabel == "Editor, Window window")
        #expect(TaskbarAppearance.panelHeight == 30)
        #expect(TaskbarAppearance.buttonHeight == 27)
        #expect(TaskbarAppearance.iconSize == 18)
        #expect(TaskbarButtonLayout.widthRange == 102...168)
    }

    @Test("overflow shrinks titled buttons before scrolling")
    func overflowResolution() {
        let comfortable = TaskbarOverflowLayout.resolve(
            viewportWidth: 900,
            windowCount: 5,
            fixedContentWidth: 10)
        #expect(comfortable.windowWidth == 168)
        #expect(!comfortable.requiresScrolling)

        let scrolling = TaskbarOverflowLayout.resolve(
            viewportWidth: 500,
            windowCount: 5,
            fixedContentWidth: 10)
        #expect(scrolling.windowWidth == TaskbarButtonLayout.minimumWidth)
        #expect(scrolling.requiresScrolling)
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

    private func item(_ id: String, display: String, order: String) -> TaskbarItem {
        TaskbarItem(
            id: id,
            pid: 10,
            applicationName: "Editor",
            applicationIdentity: "com.example.Editor",
            applicationBundlePath: "/Applications/Editor.app",
            title: "Window \(id)",
            displayIdentifier: display,
            cgWindowNumber: nil,
            stableOrderKey: order,
            isActive: false)
    }
}
