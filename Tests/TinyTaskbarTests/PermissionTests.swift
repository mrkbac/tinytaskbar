import AppKit
import Foundation
import Testing

@testable import TinyTaskbar

struct PermissionTests {
    @Test("Settings layout keeps finite nonnegative view geometry")
    @MainActor
    func settingsLayoutGeometryIsValid() {
        let window = TinyTaskbarSettingsWindow()
        defer { window.close() }

        window.refresh(
            accessibilityTrusted: false,
            showsWindowTitles: true,
            accessibilityRequestWasMade: false
        )
        window.contentView?.layoutSubtreeIfNeeded()

        #expect(window.contentView?.bounds.size == NSSize(width: 640, height: 340))
        var pendingViews = window.contentView.map { [$0] } ?? []
        while let view = pendingViews.popLast() {
            #expect(view.frame.origin.x.isFinite)
            #expect(view.frame.origin.y.isFinite)
            #expect(view.frame.width.isFinite)
            #expect(view.frame.height.isFinite)
            #expect(view.frame.width >= 0)
            #expect(view.frame.height >= 0)
            pendingViews.append(contentsOf: view.subviews)
        }
    }

    @Test("Taskbar window items expose only the native Close context command")
    @MainActor
    func taskbarContextMenuClosesSelectedItem() {
        let item = TaskbarItem(
            id: "context-window",
            pid: 42,
            applicationName: "Editor",
            title: "Document",
            displayIdentifier: "main",
            cgWindowNumber: 7,
            isActive: false
        )
        var activatedItem: TaskbarItem?
        var closedItem: TaskbarItem?
        let frame = NSRect(x: 0, y: 0, width: 600, height: 30)
        let panel = TaskbarPanel(
            frame: frame,
            onActivate: { activatedItem = $0 },
            onClose: { closedItem = $0 }
        )
        defer { panel.close() }
        panel.update(frame: frame, items: [item], showsWindowTitles: true)
        panel.contentView?.layoutSubtreeIfNeeded()

        var pendingViews = panel.contentView.map { [$0] } ?? []
        var itemButton: TaskbarButton?
        while let view = pendingViews.popLast() {
            if let button = view as? TaskbarButton {
                itemButton = button
                break
            }
            pendingViews.append(contentsOf: view.subviews)
        }
        guard let closeItem = itemButton?.contextualMenu?.items.first,
            let action = closeItem.action
        else {
            Issue.record("taskbar Close context command was not rendered")
            return
        }

        #expect(itemButton?.menu == nil)
        #expect(itemButton?.contextualMenu?.items.map(\.title) == ["Close"])
        #expect(closeItem.image?.isTemplate == true)
        #expect(closeItem.image?.size == NSSize(width: 13, height: 13))
        itemButton?.performClick(nil)
        #expect(activatedItem?.id == item.id)
        #expect(NSApplication.shared.sendAction(action, to: closeItem.target, from: closeItem))
        #expect(closedItem?.id == item.id)
    }

    @Test("retained taskbar buttons update active and minimized state in place")
    @MainActor
    func retainedButtonsUpdateInPlace() {
        let frame = NSRect(x: 0, y: 0, width: 700, height: TaskbarPanelLayout.defaultHeight)
        let panel = TaskbarPanel(frame: frame, onActivate: { _ in }, onClose: { _ in })
        defer { panel.close() }

        let first = makeTaskbarItem(id: "first", title: "First")
        let second = makeTaskbarItem(id: "second", title: "Second")
        panel.update(frame: frame, items: [first, second], showsWindowTitles: true)
        panel.contentView?.layoutSubtreeIfNeeded()

        let initialButtons = Dictionary(
            uniqueKeysWithValues: taskbarButtons(in: panel).map { ($0.itemID, $0) })
        guard let initialFirst = initialButtons["first"],
            let initialSecond = initialButtons["second"]
        else {
            Issue.record("initial taskbar buttons were not rendered")
            return
        }

        let activeFirst = makeTaskbarItem(
            id: "first", title: "Renamed", isActive: true)
        let minimizedSecond = makeTaskbarItem(
            id: "second", title: "Second", isMinimized: true)
        panel.update(
            frame: frame,
            items: [activeFirst, minimizedSecond],
            showsWindowTitles: true
        )
        panel.contentView?.layoutSubtreeIfNeeded()

        let updatedButtons = Dictionary(
            uniqueKeysWithValues: taskbarButtons(in: panel).map { ($0.itemID, $0) })
        guard let updatedFirst = updatedButtons["first"],
            let updatedSecond = updatedButtons["second"]
        else {
            Issue.record("updated taskbar buttons were not rendered")
            return
        }

        #expect(ObjectIdentifier(updatedFirst) == ObjectIdentifier(initialFirst))
        #expect(ObjectIdentifier(updatedSecond) == ObjectIdentifier(initialSecond))
        #expect(updatedFirst.title == "Renamed")
        #expect(updatedFirst.toolTip == activeFirst.tooltip)
        #expect(updatedFirst.accessibilityLabel() == activeFirst.accessibilityLabel)
        #expect(updatedFirst.alphaValue == 1)
        #expect(abs(updatedSecond.alphaValue - 0.65) < 0.001)
        #expect(updatedFirst.contextualMenu === initialFirst.contextualMenu)
        #expect(
            updatedFirst.contextualMenu?.items.first?.representedObject as? String
                == activeFirst.id)

        panel.update(frame: frame, items: [activeFirst, minimizedSecond], showsWindowTitles: false)
        panel.contentView?.layoutSubtreeIfNeeded()
        #expect(
            updatedFirst.minimumWidthConstraint?.constant
                == TaskbarButtonLayout.titleOffMinimumWidth)
        #expect(
            updatedFirst.maximumWidthConstraint?.constant
                == TaskbarButtonLayout.titleOffMaximumWidth)
    }

    @Test("taskbar reconciliation removes stale items, adds new items, and follows requested order")
    @MainActor
    func taskbarReconciliationPreservesRetainedOrder() {
        let frame = NSRect(x: 0, y: 0, width: 700, height: TaskbarPanelLayout.defaultHeight)
        let panel = TaskbarPanel(frame: frame, onActivate: { _ in }, onClose: { _ in })
        defer { panel.close() }

        let first = makeTaskbarItem(id: "first")
        let second = makeTaskbarItem(id: "second")
        let third = makeTaskbarItem(id: "third")
        panel.update(frame: frame, items: [first, second, third], showsWindowTitles: true)
        panel.contentView?.layoutSubtreeIfNeeded()
        let initialButtons = Dictionary(
            uniqueKeysWithValues: taskbarButtons(in: panel).map { ($0.itemID, $0) })

        let replacement = makeTaskbarItem(id: "replacement")
        panel.update(
            frame: frame,
            items: [third, first, replacement],
            showsWindowTitles: true
        )
        panel.contentView?.layoutSubtreeIfNeeded()
        let reconciledButtons = taskbarButtons(in: panel)

        #expect(reconciledButtons.map(\.itemID) == ["third", "first", "replacement"])
        #expect(
            reconciledButtons.first { $0.itemID == "third" }.map(ObjectIdentifier.init)
                == initialButtons["third"].map(ObjectIdentifier.init))
        #expect(
            reconciledButtons.first { $0.itemID == "first" }.map(ObjectIdentifier.init)
                == initialButtons["first"].map(ObjectIdentifier.init))
        #expect(!reconciledButtons.contains { $0.itemID == "second" })
        #expect(
            !reconciledButtons.contains {
                guard let initialSecond = initialButtons["second"] else { return false }
                return ObjectIdentifier($0) == ObjectIdentifier(initialSecond)
            })
    }

    @Test("taskbar content stays finite and inset below a visible top separator")
    @MainActor
    func taskbarContentGeometry() {
        let frame = NSRect(x: 0, y: 0, width: 700, height: TaskbarPanelLayout.defaultHeight)
        let panel = TaskbarPanel(frame: frame, onActivate: { _ in }, onClose: { _ in })
        defer { panel.close() }

        panel.update(
            frame: frame,
            items: [makeTaskbarItem(id: "geometry")],
            showsWindowTitles: true
        )
        panel.contentView?.layoutSubtreeIfNeeded()

        guard let contentView = panel.contentView,
            let separator = allSubviews(of: contentView).first(where: {
                $0.identifier?.rawValue == TaskbarPanelLayout.topSeparatorIdentifier
            }),
            let button = taskbarButtons(in: panel).first
        else {
            Issue.record("taskbar separator or button was not rendered")
            return
        }

        let buttonFrame = contentView.convert(button.bounds, from: button)
        #expect(buttonFrame.isFiniteGeometry)
        #expect(buttonFrame.minY >= contentView.bounds.minY)
        #expect(buttonFrame.maxY <= separator.frame.minY)
        #expect(separator.frame.isFiniteGeometry)
        #expect(separator.frame.minX == contentView.bounds.minX)
        #expect(separator.frame.width == contentView.bounds.width)
        #expect(separator.frame.maxY == contentView.bounds.maxY)
        #expect(separator.frame.height == TaskbarPanelLayout.topSeparatorHeight)
        #expect(separator.layer?.backgroundColor != nil)
        #expect(
            separator.frame.minY - buttonFrame.maxY
                >= TaskbarPanelLayout.contentVerticalInset
        )
    }

    @Test("explicit Accessibility requests are offered at most once per launch")
    func requestDecisionIsOneShot() {
        var state = AccessibilityPermissionRequestState()

        #expect(state.decision() == .request)
        #expect(state.didRequest)
        #expect(state.decision() == .alreadyRequested)
    }

    @Test("Settings visibility temporarily uses regular activation")
    func settingsActivationPolicyTransitions() {
        var state = SettingsActivationPolicyState()

        #expect(state.policy == .accessory)
        #expect(state.apply(.show) == .regular)
        #expect(state.policy == .regular)
        #expect(state.apply(.close) == .accessory)
        #expect(state.policy == .accessory)
    }

    @Test("preferences default and persisted state transitions")
    @MainActor
    func preferencesPersist() {
        let suiteName = "TinyTaskbarTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = TinyTaskbarPreferencesStore(defaults: defaults)
        #expect(store.values == .defaults)

        store.setOnboardingComplete(true)
        store.setShowsWindowTitles(false)

        let reloaded = TinyTaskbarPreferencesStore(defaults: defaults)
        #expect(
            reloaded.values
                == TinyTaskbarPreferences(onboardingComplete: true, showsWindowTitles: false))
    }

    @Test("title preference hides only the compact button title")
    func titlePreferencePreservesAccessibilityLabel() {
        let item = TaskbarItem(
            id: "window",
            pid: 10,
            applicationName: "Editor",
            title: "Project.swift",
            displayIdentifier: "main",
            cgWindowNumber: nil,
            isActive: false
        )

        #expect(item.buttonTitle(showsWindowTitles: true) == "Project.swift")
        #expect(item.buttonTitle(showsWindowTitles: false) == "Editor")
        #expect(item.accessibilityLabel == "Editor, Project.swift")
        #expect(item.tooltip == "Activate Editor: Project.swift")
    }

    @Test("denied launch never enumerates or emits taskbar state")
    @MainActor
    func deniedLaunchDoesNotEnumerate() {
        let provider = MockWindowSnapshotProvider()
        let store = TaskbarStore(provider: provider)
        var stateChangeCount = 0
        store.onStateChange = { _ in stateChangeCount += 1 }

        store.start(accessibilityTrusted: false)

        #expect(provider.snapshotCount == 0)
        #expect(stateChangeCount == 0)
        #expect(store.state == .empty)
        #expect(store.lifecycleState == .awaitingAccessibility)
    }

    @Test("granting Accessibility refreshes and revocation clears state")
    @MainActor
    func accessibilityTransitionsDriveRefresh() async {
        let provider = MockWindowSnapshotProvider()
        let store = TaskbarStore(provider: provider)
        provider.snapshotValue = makeFixtureSnapshot()
        defer { store.stop() }

        store.start(accessibilityTrusted: false)
        store.setAccessibilityAvailable(true)
        await waitForSnapshot(from: provider)

        #expect(provider.snapshotCount == 1)
        #expect(store.state.itemsByDisplay["main"]?.count == 1)
        #expect(store.lifecycleState == .running)

        store.setAccessibilityAvailable(false)

        #expect(store.state == .empty)
        #expect(store.lifecycleState == .runningWithoutAccessibility)
        #expect(provider.snapshotCount == 1)
    }

    @Test("repeated refresh requests coalesce into one snapshot")
    @MainActor
    func refreshRequestsCoalesce() async {
        let provider = MockWindowSnapshotProvider(snapshot: makeFixtureSnapshot())
        let store = TaskbarStore(provider: provider)
        defer { store.stop() }

        store.start(accessibilityTrusted: false)
        store.setAccessibilityAvailable(true)
        store.requestRefresh()
        store.requestRefresh()
        await waitForSnapshot(from: provider)

        #expect(provider.snapshotCount == 1)
    }

    @Test("malformed and empty provider snapshots remain safe")
    @MainActor
    func malformedSnapshotsAreIsolated() {
        let provider = MockWindowSnapshotProvider()
        let store = TaskbarStore(provider: provider)
        store.start(accessibilityTrusted: true)
        defer { store.stop() }

        store.refreshNow()
        #expect(provider.snapshotCount == 1)
        #expect(store.state == .empty)

        let malformedCandidate = WindowCandidate(
            pid: fixturePID,
            applicationName: "Malformed",
            frame: CGRect(x: CGFloat.nan, y: 0, width: 500, height: 300)
        )
        provider.snapshotValue = RawWindowSnapshot(
            candidates: [malformedCandidate],
            cgWindows: [
                CGWindowMetadata(
                    ownerPID: fixturePID,
                    bounds: CGRect(x: CGFloat.nan, y: 0, width: 500, height: 300)
                )
            ],
            displays: [fixtureDisplay],
            frontmostPID: fixturePID
        )
        store.refreshNow()

        #expect(provider.snapshotCount == 2)
        #expect(store.state.itemsByDisplay.isEmpty)
    }

    @Test("window lifecycle snapshots open, move, minimize, restore, and close")
    @MainActor
    func windowLifecycleSnapshots() {
        let provider = MockWindowSnapshotProvider()
        let store = TaskbarStore(provider: provider)
        let left = DisplayDescriptor(
            identifier: "left",
            frame: CGRect(x: 0, y: 0, width: 1_000, height: 700)
        )
        let right = DisplayDescriptor(
            identifier: "right",
            frame: CGRect(x: 1_000, y: 0, width: 1_000, height: 700)
        )
        let leftFrame = CGRect(x: 100, y: 100, width: 500, height: 300)
        let rightFrame = CGRect(x: 1_200, y: 100, width: 500, height: 300)
        var emittedStates: [TaskbarState] = []
        store.onStateChange = { emittedStates.append($0) }
        defer { store.stop() }

        func snapshot(frame: CGRect, minimized: Bool = false) -> RawWindowSnapshot {
            let candidate = WindowCandidate(
                pid: fixturePID,
                applicationName: "Fixture",
                title: "Document",
                frame: frame,
                isMinimized: minimized
            )
            return RawWindowSnapshot(
                candidates: [candidate],
                cgWindows: minimized
                    ? []
                    : [
                        CGWindowMetadata(
                            windowNumber: 77,
                            ownerPID: fixturePID,
                            bounds: frame,
                            title: candidate.title
                        )
                    ],
                displays: [left, right],
                frontmostPID: minimized ? nil : fixturePID
            )
        }

        provider.snapshotValue = snapshot(frame: leftFrame)
        store.start(accessibilityTrusted: true)
        store.refreshNow()
        #expect(store.state.itemsByDisplay["left"]?.count == 1)

        provider.snapshotValue = snapshot(frame: rightFrame)
        store.refreshNow()
        #expect(store.state.itemsByDisplay["left"] == nil)
        #expect(store.state.itemsByDisplay["right"]?.count == 1)

        provider.snapshotValue = snapshot(frame: rightFrame, minimized: true)
        store.refreshNow()
        #expect(store.state.itemsByDisplay["right"]?.first?.isMinimized == true)
        #expect(store.state.itemsByDisplay["right"]?.first?.isActive == false)

        provider.snapshotValue = snapshot(frame: rightFrame)
        store.refreshNow()
        #expect(store.state.itemsByDisplay["right"]?.count == 1)

        provider.snapshotValue = RawWindowSnapshot(
            candidates: [],
            cgWindows: [],
            displays: [left, right],
            frontmostPID: nil
        )
        store.refreshNow()
        #expect(store.state.itemsByDisplay.isEmpty)
        #expect(emittedStates.count == 5)
    }

    @Test("stale window operations are ignored after Accessibility revocation")
    @MainActor
    func staleActivationIsSafe() {
        let provider = MockWindowSnapshotProvider(snapshot: makeFixtureSnapshot())
        let store = TaskbarStore(provider: provider)
        store.start(accessibilityTrusted: true)
        store.refreshNow()
        defer { store.stop() }

        guard let item = store.state.itemsByDisplay["main"]?.first else {
            Issue.record("fixture item was not projected")
            return
        }

        store.activate(item)
        #expect(provider.minimizeCount == 1)
        let inactiveItem = TaskbarItem(
            id: item.id,
            pid: item.pid,
            applicationName: item.applicationName,
            applicationIdentity: item.applicationIdentity,
            title: item.title,
            displayIdentifier: item.displayIdentifier,
            cgWindowNumber: item.cgWindowNumber,
            stableOrderKey: item.stableOrderKey,
            isMinimized: true,
            isActive: false
        )
        store.activate(inactiveItem)
        #expect(provider.activationCount == 1)
        store.close(item)
        #expect(provider.closeCount == 1)

        store.setAccessibilityAvailable(false)
        store.activate(item)
        store.activate(inactiveItem)
        store.close(item)
        #expect(provider.activationCount == 1)
        #expect(provider.minimizeCount == 1)
        #expect(provider.closeCount == 1)
    }

    @Test("injected Accessibility provider exposes trust and request calls")
    @MainActor
    func accessibilityProviderSeam() {
        let provider = MockAccessibilityPermissionProvider(trusted: false)

        #expect(!provider.isTrusted())
        #expect(provider.requestAccess())
        #expect(provider.requestCount == 1)
    }

    private func makeFixtureSnapshot() -> RawWindowSnapshot {
        let candidate = WindowCandidate(
            pid: fixturePID,
            applicationName: "Fixture",
            title: "Document",
            frame: CGRect(x: 100, y: 100, width: 500, height: 300),
            isFocused: true,
            isMain: true
        )
        return RawWindowSnapshot(
            candidates: [candidate],
            cgWindows: [
                CGWindowMetadata(
                    windowNumber: 77,
                    ownerPID: fixturePID,
                    bounds: candidate.frame!,
                    title: candidate.title
                )
            ],
            displays: [fixtureDisplay],
            frontmostPID: fixturePID
        )
    }

    @MainActor
    private func waitForSnapshot(from provider: MockWindowSnapshotProvider) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while provider.snapshotCount == 0, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private var fixtureDisplay: DisplayDescriptor {
        DisplayDescriptor(
            identifier: "main",
            frame: CGRect(x: 0, y: 0, width: 1_200, height: 800)
        )
    }

    private var fixturePID: Int32 {
        Int32(ProcessInfo.processInfo.processIdentifier + 1)
    }

    @MainActor
    private func makeTaskbarItem(
        id: String,
        title: String? = nil,
        isMinimized: Bool = false,
        isActive: Bool = false
    ) -> TaskbarItem {
        TaskbarItem(
            id: id,
            pid: Int32(id.hashValue & 0x7fff) + 1,
            applicationName: "App " + id,
            title: title ?? id,
            displayIdentifier: "main",
            cgWindowNumber: nil,
            isMinimized: isMinimized,
            isActive: isActive
        )
    }

    @MainActor
    private func taskbarButtons(in panel: TaskbarPanel) -> [TaskbarButton] {
        guard let contentView = panel.contentView else { return [] }
        return allSubviews(of: contentView).compactMap { $0 as? TaskbarButton }
    }

    @MainActor
    private func allSubviews(of view: NSView) -> [NSView] {
        view.subviews.reduce(into: []) { result, subview in
            result.append(subview)
            result.append(contentsOf: allSubviews(of: subview))
        }
    }
}

@MainActor
private final class MockWindowSnapshotProvider: WindowSnapshotProvider {
    var snapshotValue: RawWindowSnapshot = RawWindowSnapshot(
        candidates: [], cgWindows: [], displays: [], frontmostPID: nil)
    var snapshotCount = 0
    var activationCount = 0
    var minimizeCount = 0
    var closeCount = 0
    var onChange: (@MainActor @Sendable () -> Void)?

    init(snapshot: RawWindowSnapshot? = nil) {
        if let snapshot {
            snapshotValue = snapshot
        }
    }

    func snapshot() -> RawWindowSnapshot {
        snapshotCount += 1
        return snapshotValue
    }

    func activate(_: TaskbarItem) {
        activationCount += 1
    }

    func minimize(_: TaskbarItem) {
        minimizeCount += 1
    }

    func close(_: TaskbarItem) {
        closeCount += 1
    }
}

@MainActor
private final class MockAccessibilityPermissionProvider: AccessibilityPermissionProvider {
    var trusted: Bool
    var requestCount = 0

    init(trusted: Bool) {
        self.trusted = trusted
    }

    func isTrusted() -> Bool {
        trusted
    }

    func requestAccess() -> Bool {
        requestCount += 1
        trusted = true
        return true
    }
}
