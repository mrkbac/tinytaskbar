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

    @Test("ordered taskbar document, stack, and button stay vertically centered")
    @MainActor
    func taskbarDocumentAndButtonMidpoints() {
        let frame = NSRect(x: 0, y: 0, width: 700, height: TaskbarPanelLayout.defaultHeight)
        let panel = TaskbarPanel(frame: frame, onActivate: { _ in }, onClose: { _ in })
        defer { panel.close() }

        panel.update(
            frame: frame,
            items: [makeTaskbarItem(id: "midpoint")],
            showsWindowTitles: true
        )
        panel.orderFrontRegardless()
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.contentView?.displayIfNeeded()
        panel.contentView?.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        panel.contentView?.layoutSubtreeIfNeeded()

        guard let contentView = panel.contentView,
            let scrollView = allSubviews(of: contentView).compactMap({ $0 as? NSScrollView }).first,
            let documentView = scrollView.documentView,
            let stackView = documentView as? NSStackView,
            let button = taskbarButtons(in: panel).first
        else {
            Issue.record("taskbar scroll/document hierarchy was not rendered")
            return
        }

        scrollView.layoutSubtreeIfNeeded()
        stackView.layoutSubtreeIfNeeded()
        let contentFrame = contentView.convert(scrollView.bounds, from: scrollView)
        let documentFrame = contentView.convert(documentView.bounds, from: documentView)
        let stackFrame = contentView.convert(stackView.bounds, from: stackView)
        let buttonFrame = contentView.convert(button.bounds, from: button)
        let contentMidpoint = contentFrame.midY

        #expect(abs(scrollView.contentView.bounds.height - contentFrame.height) <= 1)
        #expect(abs(documentFrame.midY - contentMidpoint) <= 1)
        #expect(abs(stackFrame.midY - contentMidpoint) <= 1)
        #expect(abs(buttonFrame.midY - contentMidpoint) <= 1)
    }

    @Test("first layout after a zero-sized panel establishes the full content height")
    @MainActor
    func taskbarFirstLayoutAfterResize() {
        let zeroFrame = NSRect.zero
        let frame = NSRect(x: 0, y: 0, width: 700, height: TaskbarPanelLayout.defaultHeight)
        let panel = TaskbarPanel(frame: zeroFrame, onActivate: { _ in }, onClose: { _ in })
        defer { panel.close() }

        panel.update(
            frame: frame,
            items: [makeTaskbarItem(id: "first-pass")],
            showsWindowTitles: true
        )
        panel.contentView?.layoutSubtreeIfNeeded()

        guard let contentView = panel.contentView,
            let scrollView = allSubviews(of: contentView).compactMap({ $0 as? NSScrollView }).first,
            let stackView = scrollView.documentView as? NSStackView,
            let button = taskbarButtons(in: panel).first
        else {
            Issue.record("taskbar first-pass hierarchy was not rendered")
            return
        }

        let contentFrame = contentView.convert(scrollView.bounds, from: scrollView)
        let stackFrame = contentView.convert(stackView.bounds, from: stackView)
        let buttonFrame = contentView.convert(button.bounds, from: button)
        let expectedHeight = TaskbarPanelLayout.contentHeight

        #expect(abs(stackFrame.height - expectedHeight) <= 1)
        #expect(abs(buttonFrame.height - expectedHeight) <= 1)
        #expect(abs(stackFrame.midY - contentFrame.midY) <= 1)
        #expect(abs(buttonFrame.midY - contentFrame.midY) <= 1)
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

    @Test("repeated AX/CG gaps retain item identity and order for a long move")
    func transientSnapshotContinuity() {
        let display = DisplayDescriptor(
            identifier: "main",
            frame: CGRect(x: 0, y: 0, width: 1_200, height: 800)
        )
        let first = TaskbarItem(
            id: "first", pid: 10, applicationName: "First", title: "First",
            displayIdentifier: "main", cgWindowNumber: 10, stableOrderKey: "a",
            isActive: true)
        let middle = TaskbarItem(
            id: "middle", pid: 20, applicationName: "Middle", title: "Middle",
            displayIdentifier: "main", cgWindowNumber: 20, stableOrderKey: "b",
            isActive: false)
        let last = TaskbarItem(
            id: "last", pid: 30, applicationName: "Last", title: "Last",
            displayIdentifier: "main", cgWindowNumber: 30, stableOrderKey: "c",
            isActive: false)
        let initial = TaskbarState(
            displays: [display],
            itemsByDisplay: ["main": [first, middle, last]]
        )
        let transient = TaskbarState(
            displays: [display],
            itemsByDisplay: ["main": [first, last]]
        )
        let movingCandidate = WindowCandidate(
            stableKey: "middle",
            pid: 20,
            applicationName: "Middle",
            title: "Middle",
            frame: CGRect(x: 400, y: 100, width: 500, height: 300)
        )
        let movingSnapshot = RawWindowSnapshot(
            candidates: [movingCandidate],
            cgWindows: [],
            displays: [display],
            frontmostPID: nil,
            evidence: WindowSnapshotEvidence(
                isComplete: true,
                knownApplicationPIDs: [20],
                axWindowListReadPIDs: [20],
                observedAXWindowIDs: ["middle"]
            )
        )
        let continuity = TaskbarStateContinuity()
        var resolved = initial

        // Twenty event-driven refreshes represent a multi-second drag. The
        // same AX identity remains authoritative while CG matching is absent.
        for _ in 0..<20 {
            resolved = continuity.resolve(
                previous: resolved,
                incoming: transient,
                snapshot: movingSnapshot
            )
        }

        #expect(resolved.itemsByDisplay["main"]?.map(\.id) == ["first", "middle", "last"])
    }

    @Test("authoritative hidden and absent evidence removes items promptly")
    func authoritativeRemovalEvidence() {
        let display = DisplayDescriptor(
            identifier: "main",
            frame: CGRect(x: 0, y: 0, width: 1_200, height: 800)
        )
        let hiddenItem = TaskbarItem(
            id: "hidden", pid: 10, applicationName: "Hidden", title: "Hidden",
            displayIdentifier: "main", cgWindowNumber: 10, stableOrderKey: "hidden",
            isActive: false)
        let hiddenCandidate = WindowCandidate(
            stableKey: "hidden",
            pid: 10,
            applicationName: "Hidden",
            title: "Hidden",
            frame: CGRect(x: 100, y: 100, width: 500, height: 300),
            isHidden: true
        )
        let hiddenSnapshot = RawWindowSnapshot(
            candidates: [hiddenCandidate],
            cgWindows: [],
            displays: [display],
            frontmostPID: nil,
            evidence: WindowSnapshotEvidence(
                isComplete: true,
                knownApplicationPIDs: [10],
                axWindowListReadPIDs: [10],
                observedAXWindowIDs: ["hidden"]
            )
        )
        let emptyState = TaskbarState(displays: [display], itemsByDisplay: [:])
        let continuity = TaskbarStateContinuity()

        let hiddenResult = continuity.resolve(
            previous: TaskbarState(displays: [display], itemsByDisplay: ["main": [hiddenItem]]),
            incoming: emptyState,
            snapshot: hiddenSnapshot
        )
        #expect(hiddenResult.itemsByDisplay.isEmpty)

        let closedItem = TaskbarItem(
            id: "closed", pid: 11, applicationName: "Closed", title: "Closed",
            displayIdentifier: "main", cgWindowNumber: 11, stableOrderKey: "closed",
            isActive: false)
        let closedSnapshot = RawWindowSnapshot(
            candidates: [],
            cgWindows: [],
            displays: [display],
            frontmostPID: nil,
            evidence: WindowSnapshotEvidence(
                isComplete: true,
                knownApplicationPIDs: [11],
                axWindowListReadPIDs: [11]
            )
        )
        let closedResult = continuity.resolve(
            previous: TaskbarState(displays: [display], itemsByDisplay: ["main": [closedItem]]),
            incoming: emptyState,
            snapshot: closedSnapshot
        )
        #expect(closedResult.itemsByDisplay.isEmpty)
    }

    @Test("failed AX reads remain inconclusive but a complete AX list confirms absence")
    func axEvidenceDistinguishesIncompleteReads() {
        let display = DisplayDescriptor(
            identifier: "main",
            frame: CGRect(x: 0, y: 0, width: 1_200, height: 800)
        )
        let item = TaskbarItem(
            id: "window", pid: 10, applicationName: "Window", title: "Window",
            displayIdentifier: "main", cgWindowNumber: 10, stableOrderKey: "window",
            isActive: false)
        let previous = TaskbarState(displays: [display], itemsByDisplay: ["main": [item]])
        let incoming = TaskbarState(displays: [display], itemsByDisplay: [:])
        let continuity = TaskbarStateContinuity()

        let failedRead = RawWindowSnapshot(
            candidates: [], cgWindows: [], displays: [display], frontmostPID: nil,
            evidence: WindowSnapshotEvidence(
                isComplete: true,
                knownApplicationPIDs: [10]
            )
        )
        let retainedAfterFailedRead = continuity.resolve(
            previous: previous,
            incoming: incoming,
            snapshot: failedRead
        )
        #expect(retainedAfterFailedRead.itemsByDisplay["main"]?.map(\.id) == ["window"])

        let attributesIncomplete = RawWindowSnapshot(
            candidates: [], cgWindows: [], displays: [display], frontmostPID: nil,
            evidence: WindowSnapshotEvidence(
                isComplete: true,
                knownApplicationPIDs: [10],
                axWindowListReadPIDs: [10],
                observedAXWindowIDs: ["window"]
            )
        )
        let retainedAfterAttributeFailure = continuity.resolve(
            previous: previous,
            incoming: incoming,
            snapshot: attributesIncomplete
        )
        #expect(retainedAfterAttributeFailure.itemsByDisplay["main"]?.map(\.id) == ["window"])

        let completeAbsence = RawWindowSnapshot(
            candidates: [], cgWindows: [], displays: [display], frontmostPID: nil,
            evidence: WindowSnapshotEvidence(
                isComplete: true,
                knownApplicationPIDs: [10],
                axWindowListReadPIDs: [10]
            )
        )
        let removedAfterCompleteRead = continuity.resolve(
            previous: previous,
            incoming: incoming,
            snapshot: completeAbsence
        )
        #expect(removedAfterCompleteRead.itemsByDisplay.isEmpty)
    }

    @Test("moving an item between displays updates its display without a stale duplicate")
    func crossDisplayContinuity() {
        let left = DisplayDescriptor(
            identifier: "left",
            frame: CGRect(x: 0, y: 0, width: 1_000, height: 700)
        )
        let right = DisplayDescriptor(
            identifier: "right",
            frame: CGRect(x: 1_000, y: 0, width: 1_000, height: 700)
        )
        let leftItem = TaskbarItem(
            id: "moving", pid: 10, applicationName: "Moving", title: "Moving",
            displayIdentifier: "left", cgWindowNumber: 10, stableOrderKey: "moving",
            isActive: true)
        let rightItem = TaskbarItem(
            id: "moving", pid: 10, applicationName: "Moving", title: "Moving",
            displayIdentifier: "right", cgWindowNumber: 10, stableOrderKey: "moving",
            isActive: true)
        let previous = TaskbarState(
            displays: [left, right], itemsByDisplay: ["left": [leftItem]])
        let incoming = TaskbarState(
            displays: [left, right], itemsByDisplay: [:])
        let movingCandidate = WindowCandidate(
            stableKey: "moving",
            pid: 10,
            applicationName: "Moving",
            title: "Moving",
            frame: CGRect(x: 1_200, y: 100, width: 500, height: 300),
            isFocused: true,
            isMain: true
        )
        let movingSnapshot = RawWindowSnapshot(
            candidates: [movingCandidate],
            cgWindows: [],
            displays: [left, right],
            frontmostPID: 10,
            evidence: WindowSnapshotEvidence(
                isComplete: true,
                knownApplicationPIDs: [10],
                axWindowListReadPIDs: [10],
                observedAXWindowIDs: ["moving"]
            )
        )
        let continuity = TaskbarStateContinuity()

        let resolved = continuity.resolve(
            previous: previous,
            incoming: incoming,
            snapshot: movingSnapshot
        )

        #expect(resolved.itemsByDisplay["left"] == nil)
        #expect(resolved.itemsByDisplay["right"]?.map(\.id) == ["moving"])
        #expect(resolved.itemsByDisplay.values.joined().map(\.id) == ["moving"])
        #expect(resolved.itemsByDisplay["right"]?.first == rightItem)
    }

    @Test("active Space refresh removes AX-only items from the prior Space")
    func activeSpaceChangeInvalidatesAXOnlyItems() {
        let display = DisplayDescriptor(
            identifier: "main",
            frame: CGRect(x: 0, y: 0, width: 1_200, height: 800)
        )
        let item = TaskbarItem(
            id: "prior-space", pid: 10, applicationName: "Prior", title: "Prior",
            displayIdentifier: "main", cgWindowNumber: 10, stableOrderKey: "prior-space",
            isActive: false)
        let candidate = WindowCandidate(
            stableKey: "prior-space",
            pid: 10,
            applicationName: "Prior",
            title: "Prior",
            frame: CGRect(x: 100, y: 100, width: 500, height: 300)
        )
        let snapshot = RawWindowSnapshot(
            candidates: [candidate],
            cgWindows: [],
            displays: [display],
            frontmostPID: nil,
            evidence: WindowSnapshotEvidence(
                isComplete: true,
                knownApplicationPIDs: [10],
                axWindowListReadPIDs: [10],
                observedAXWindowIDs: ["prior-space"]
            )
        )
        let previous = TaskbarState(displays: [display], itemsByDisplay: ["main": [item]])
        let incoming = TaskbarState(displays: [display], itemsByDisplay: [:])

        let resolved = TaskbarStateContinuity().resolve(
            previous: previous,
            incoming: incoming,
            snapshot: snapshot,
            cause: .activeSpaceChanged
        )

        #expect(resolved.itemsByDisplay.isEmpty)
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
                stableKey: "fixture-window",
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
                frontmostPID: minimized ? nil : fixturePID,
                evidence: WindowSnapshotEvidence(
                    isComplete: true,
                    knownApplicationPIDs: [fixturePID],
                    axWindowListReadPIDs: [fixturePID],
                    observedAXWindowIDs: ["fixture-window"]
                )
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
            frontmostPID: nil,
            evidence: WindowSnapshotEvidence(
                isComplete: true,
                knownApplicationPIDs: [fixturePID],
                axWindowListReadPIDs: [fixturePID]
            )
        )
        store.refreshNow()
        #expect(store.state.itemsByDisplay.isEmpty)
        #expect(emittedStates.count == 5)
    }

    @Test("window toggle refreshes actual focus and stops after Accessibility revocation")
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

        // The button still says active, but the system snapshot has moved focus.
        // The click must activate, not minimize based on stale presentation state.
        provider.snapshotValue = makeFixtureSnapshot(isActive: false)
        store.activate(item)
        #expect(provider.activationCount == 1)

        guard let inactiveItem = store.state.itemsByDisplay["main"]?.first else {
            Issue.record("inactive fixture item was not projected")
            return
        }
        #expect(!inactiveItem.isActive)

        // The inverse race must also toggle from the fresh system focus.
        provider.snapshotValue = makeFixtureSnapshot()
        store.activate(inactiveItem)
        #expect(provider.minimizeCount == 2)

        store.close(item)
        #expect(provider.closeCount == 1)

        store.setAccessibilityAvailable(false)
        store.activate(item)
        store.activate(inactiveItem)
        store.close(item)
        #expect(provider.activationCount == 1)
        #expect(provider.minimizeCount == 2)
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

    private func makeFixtureSnapshot(isActive: Bool = true) -> RawWindowSnapshot {
        let candidate = WindowCandidate(
            pid: fixturePID,
            applicationName: "Fixture",
            title: "Document",
            frame: CGRect(x: 100, y: 100, width: 500, height: 300),
            isFocused: isActive,
            isMain: isActive
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
            frontmostPID: isActive ? fixturePID : nil
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
