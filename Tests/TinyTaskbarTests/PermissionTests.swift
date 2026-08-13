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
            preferences: .defaults,
            accessibilityRequestWasMade: false
        )
        window.contentView?.layoutSubtreeIfNeeded()

        #expect(window.contentView?.bounds.size == NSSize(width: 620, height: 640))
        let allSettingsViews = allSubviews(of: window.contentView!)
        let buttonTitles = allSettingsViews.compactMap { ($0 as? NSButton)?.title }
        #expect(!buttonTitles.contains("Done"))
        #expect(!buttonTitles.contains("Quit TinyTaskbar"))
        #expect(buttonTitles.contains("Manage…"))
        let labels = allSettingsViews.compactMap { ($0 as? NSTextField)?.stringValue }
        #expect(labels.contains("General"))
        #expect(labels.contains("Taskbar"))
        #expect(labels.contains("Applications"))
        #expect(allSettingsViews.compactMap { $0 as? NSPopUpButton }.count == 7)
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

    @Test("Settings application summary follows refreshed preferences")
    @MainActor
    func settingsApplicationSummaryRefreshes() {
        let window = TinyTaskbarSettingsWindow()
        defer { window.close() }
        let pinned = ApplicationRecord(
            identity: "com.example.Pinned", bundleIdentifier: "com.example.Pinned",
            localizedName: "Pinned", sequence: 0)
        let excluded = ApplicationRecord(
            identity: "com.example.Excluded", bundleIdentifier: "com.example.Excluded",
            localizedName: "Excluded", sequence: 0)
        var preferences = TinyTaskbarPreferences.defaults
        preferences.pinnedApplications = [pinned]
        preferences.excludedApplications = [excluded]

        window.refresh(
            accessibilityTrusted: true, preferences: preferences,
            accessibilityRequestWasMade: false)
        #expect(
            allSubviews(of: window.contentView!).compactMap { $0 as? NSTextField }
                .contains { $0.stringValue == "1 pinned, 1 excluded" })

        window.refresh(
            accessibilityTrusted: true, preferences: .defaults,
            accessibilityRequestWasMade: false)
        #expect(
            allSubviews(of: window.contentView!).compactMap { $0 as? NSTextField }
                .contains { $0.stringValue == "No custom rules" })
    }

    @Test("Applications management sheet always has an explicit dismissal action")
    @MainActor
    func applicationsSheetCanBeDismissed() {
        let window = ApplicationsManagementWindow()
        defer { window.close() }
        var preferences = TinyTaskbarPreferences.defaults
        preferences.pinnedApplications = (0..<20).map { index in
            ApplicationRecord(
                identity: "com.example.app\(index)",
                bundleIdentifier: "com.example.app\(index)",
                bundlePath: "/Applications/App \(index).app",
                localizedName: "Application \(index)",
                sequence: index)
        }
        window.refresh(preferences: preferences)
        window.contentView?.layoutSubtreeIfNeeded()
        let buttons =
            window.contentView.map { allSubviews(of: $0) }?
            .compactMap { $0 as? NSButton } ?? []
        #expect(buttons.contains { $0.title == "Done" && $0.keyEquivalent == "\r" })
        let scrollView = window.contentView.map { allSubviews(of: $0) }?
            .compactMap { $0 as? NSScrollView }.first
        #expect(scrollView?.hasVerticalScroller == true)
        #expect(
            (scrollView?.documentView?.frame.height ?? 0)
                > (scrollView?.contentView.bounds.height ?? .greatestFiniteMagnitude))
    }

    @Test("Taskbar window menu exposes retained window and global commands")
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
        var windowCommand: WindowCommand?
        let frame = NSRect(x: 0, y: 0, width: 600, height: 30)
        let panel = TaskbarPanel(
            frame: frame,
            onActivate: { activatedItem = $0 },
            onClose: { closedItem = $0 },
            onWindowCommand: { windowCommand = $0 }
        )
        defer { panel.close() }
        update(panel, frame: frame, items: [item])
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
        guard
            let contextMenu = itemButton?.contextualMenu,
            let closeItem = contextMenu.items.last,
            closeItem.title == "Close",
            let action = closeItem.action
        else {
            Issue.record("taskbar Close context command was not rendered")
            return
        }

        #expect(itemButton?.menu == nil)
        #expect(
            contextMenu.items.map(\.title)
                == [
                    "Minimize", "Minimize All", "Minimize Others", "", "TinyTaskbar", "",
                    "Close",
                ])
        let tinyTaskbarItems = contextMenu.items[4].submenu?.items
        #expect(
            tinyTaskbarItems?.map(\.title)
                == [
                    "Pin Application", "Never Show This App", "", "Settings…",
                    "Quit TinyTaskbar",
                ])
        #expect(tinyTaskbarItems?[0].isEnabled == false)
        #expect(tinyTaskbarItems?[1].isEnabled == false)
        #expect(
            panel.contentView?.menu?.items.map(\.title)
                == ["TinyTaskbar", "", "Minimize All"])
        if let minimizeAllItem = panel.contentView?.menu?.items.last,
            let minimizeAllAction = minimizeAllItem.action
        {
            #expect(
                NSApplication.shared.sendAction(
                    minimizeAllAction, to: minimizeAllItem.target, from: minimizeAllItem))
            #expect(windowCommand == .minimizeAll)
        } else {
            Issue.record("empty taskbar Minimize All command was not rendered")
        }
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
        update(panel, frame: frame, items: [first, second])
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
        update(panel, frame: frame, items: [activeFirst, minimizedSecond])
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
        #expect(updatedFirst.toolTip == nil)
        #expect(updatedFirst.onHoverChanged != nil)
        updatedFirst.updateTrackingAreas()
        #expect(!updatedFirst.trackingAreas.isEmpty)
        #expect(updatedFirst.accessibilityLabel() == activeFirst.accessibilityLabel)
        #expect(updatedFirst.alphaValue == 1)
        #expect(abs(updatedSecond.alphaValue - 0.65) < 0.001)
        #expect(updatedFirst.presentsActiveFocus)
        #expect(!updatedSecond.presentsActiveFocus)
        #expect(updatedFirst.layer?.cornerRadius == 6)
        #expect(updatedFirst.layer?.borderWidth == 1)
        #expect(updatedSecond.layer?.borderWidth == 0)
        #expect(updatedFirst.contextualMenu === initialFirst.contextualMenu)
        #expect(
            updatedFirst.contextualMenu?.items.first?.representedObject as? String
                == activeFirst.id)

        update(
            panel,
            frame: frame,
            items: [activeFirst, minimizedSecond],
            labelMode: .applicationName)
        panel.contentView?.layoutSubtreeIfNeeded()
        #expect(
            updatedFirst.widthConstraint?.constant
                == TaskbarButtonLayout.titleOffMaximumWidth)
    }

    @Test("focus and title changes never change taskbar button widths or positions")
    @MainActor
    func focusStylingDoesNotReflowTaskbar() {
        let frame = NSRect(x: 0, y: 0, width: 700, height: TaskbarPanelLayout.defaultHeight)
        let panel = TaskbarPanel(frame: frame, onActivate: { _ in }, onClose: { _ in })
        defer { panel.close() }

        let first = makeTaskbarItem(id: "first", title: "First")
        let second = makeTaskbarItem(id: "second", title: "Second")
        update(panel, frame: frame, items: [first, second])
        panel.contentView?.layoutSubtreeIfNeeded()
        let initialFrames = Dictionary(
            uniqueKeysWithValues: taskbarButtons(in: panel).map { ($0.itemID, $0.frame) })

        update(
            panel,
            frame: frame,
            items: [
                makeTaskbarItem(id: "first", title: "First", isActive: true),
                second,
            ])
        panel.contentView?.layoutSubtreeIfNeeded()
        let firstFocusFrames = Dictionary(
            uniqueKeysWithValues: taskbarButtons(in: panel).map { ($0.itemID, $0.frame) })

        update(
            panel,
            frame: frame,
            items: [
                first,
                makeTaskbarItem(id: "second", title: "Second", isActive: true),
            ])
        panel.contentView?.layoutSubtreeIfNeeded()
        let secondFocusFrames = Dictionary(
            uniqueKeysWithValues: taskbarButtons(in: panel).map { ($0.itemID, $0.frame) })

        update(
            panel,
            frame: frame,
            items: [
                makeTaskbarItem(
                    id: "first",
                    title: "A much longer document title that must truncate in place"),
                makeTaskbarItem(id: "second", title: "Second", isActive: true),
            ])
        panel.contentView?.layoutSubtreeIfNeeded()
        let changedTitleFrames = Dictionary(
            uniqueKeysWithValues: taskbarButtons(in: panel).map { ($0.itemID, $0.frame) })

        #expect(firstFocusFrames == initialFrames)
        #expect(secondFocusFrames == initialFrames)
        #expect(changedTitleFrames == initialFrames)
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
        update(panel, frame: frame, items: [first, second, third])
        panel.contentView?.layoutSubtreeIfNeeded()
        let initialButtons = Dictionary(
            uniqueKeysWithValues: taskbarButtons(in: panel).map { ($0.itemID, $0) })

        let replacement = makeTaskbarItem(id: "replacement")
        update(panel, frame: frame, items: [third, first, replacement])
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

        update(panel, frame: frame, items: [makeTaskbarItem(id: "geometry")])
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
        #expect(buttonFrame.minX >= TaskbarPanelLayout.contentLeadingInset)
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

    @Test("taskbar button content keeps a small leading inset")
    @MainActor
    func taskbarButtonContentLeadingInset() {
        let button = TaskbarButton(frame: NSRect(x: 0, y: 0, width: 180, height: 27))
        guard let cell = button.cell as? TaskbarButtonCell else {
            Issue.record("taskbar button did not install its content cell")
            return
        }
        let original = NSRect(x: 2, y: 3, width: 174, height: 20)
        let imageFrame = cell.insetImageFrame(original)
        let titleFrame = cell.insetTitleFrame(original)

        #expect(imageFrame.minX == original.minX + TaskbarButtonCell.contentLeadingInset)
        #expect(imageFrame.size == original.size)
        #expect(titleFrame.minX == original.minX + TaskbarButtonCell.contentLeadingInset)
        #expect(titleFrame.maxX == original.maxX)
        #expect(titleFrame.minY == original.minY)
        #expect(titleFrame.height == original.height)
    }

    @Test("taskbar bottom edge activates the aligned window button")
    @MainActor
    func taskbarBottomEdgeClick() {
        let frame = NSRect(x: 0, y: 0, width: 700, height: TaskbarPanelLayout.defaultHeight)
        let item = makeTaskbarItem(id: "bottom-edge")
        var activatedItem: TaskbarItem?
        let panel = TaskbarPanel(
            frame: frame,
            onActivate: { activatedItem = $0 },
            onClose: { _ in })
        defer { panel.close() }

        update(panel, frame: frame, items: [item])
        panel.contentView?.layoutSubtreeIfNeeded()

        guard let contentView = panel.contentView,
            let button = taskbarButtons(in: panel).first
        else {
            Issue.record("taskbar button was not rendered")
            return
        }

        let buttonFrame = contentView.convert(button.bounds, from: button)
        let bottomEdgePoint = NSPoint(
            x: buttonFrame.midX,
            y: contentView.bounds.minY + 0.25)
        #expect(!buttonFrame.contains(bottomEdgePoint))
        #expect(contentView.hitTest(bottomEdgePoint) === contentView)

        guard
            let event = NSEvent.mouseEvent(
                with: .leftMouseDown,
                location: contentView.convert(bottomEdgePoint, to: nil),
                modifierFlags: [],
                timestamp: 0,
                windowNumber: panel.windowNumber,
                context: nil,
                eventNumber: 1,
                clickCount: 1,
                pressure: 1)
        else {
            Issue.record("bottom-edge mouse event could not be created")
            return
        }

        contentView.mouseDown(with: event)
        #expect(activatedItem?.id == item.id)
    }

    @Test("ordered taskbar document, stack, and button stay vertically centered")
    @MainActor
    func taskbarDocumentAndButtonMidpoints() {
        let frame = NSRect(x: 0, y: 0, width: 700, height: TaskbarPanelLayout.defaultHeight)
        let panel = TaskbarPanel(frame: frame, onActivate: { _ in }, onClose: { _ in })
        defer { panel.close() }

        update(panel, frame: frame, items: [makeTaskbarItem(id: "midpoint")])
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

        update(panel, frame: frame, items: [makeTaskbarItem(id: "first-pass")])
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
        store.setLabelMode(.applicationName)
        store.setButtonWidth(.wide)
        store.setOverflowBehavior(.automaticIcons)

        let reloaded = TinyTaskbarPreferencesStore(defaults: defaults)
        var expected = TinyTaskbarPreferences.defaults
        expected.onboardingComplete = true
        expected.labelMode = .applicationName
        expected.buttonWidth = .wide
        expected.overflowBehavior = .automaticIcons
        #expect(reloaded.values == expected)
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

        #expect(item.buttonTitle(labelMode: .windowTitle) == "Project.swift")
        #expect(item.buttonTitle(labelMode: .applicationName) == "Editor")
        #expect(item.accessibilityLabel == "Editor, Project.swift")
        #expect(item.tooltip == "Activate Editor: Project.swift")
    }

    @Test("hover card preserves the full title and application identity")
    @MainActor
    func hoverCardShowsFullTitle() {
        let title = String(repeating: "A very long document title ", count: 12)
        let icon = NSImage(systemSymbolName: "doc", accessibilityDescription: nil)
        let controller = TaskbarHoverCardViewController(
            applicationName: "Editor",
            title: title,
            icon: icon
        )
        controller.loadView()

        #expect(controller.titleLabel.stringValue == title)
        #expect(controller.titleLabel.maximumNumberOfLines == 0)
        #expect(controller.titleLabel.lineBreakMode == .byCharWrapping)
        #expect(controller.applicationLabel.stringValue == "Editor")
        #expect(!controller.applicationLabel.isHidden)
        #expect(controller.iconView.image != nil)
        #expect(
            controller.preferredContentSize.width
                <= TaskbarHoverCardViewController.padding * 2
                + TaskbarHoverCardViewController.iconSize
                + TaskbarHoverCardViewController.spacing
                + TaskbarHoverCardViewController.maximumTextWidth
                + TaskbarHoverCardViewController.closeControlWidth)
        #expect(controller.closeApplicationButton.image != nil)
        #expect(controller.preferredContentSize.height > 44)
    }

    @Test("hover card lists native tabs and dispatches the selected tab")
    @MainActor
    func hoverCardSelectsNativeTab() {
        let tabs = [
            TaskbarTab(id: "alpha", title: "Alpha project", isSelected: true),
            TaskbarTab(id: "beta", title: "Beta logs", isSelected: false),
            TaskbarTab(id: "gamma", title: "Gamma shell", isSelected: false),
        ]
        var selectedTab: TaskbarTab?
        var closedTab: TaskbarTab?
        var didCloseApplication = false
        let controller = TaskbarHoverCardViewController(
            applicationName: "Terminal",
            title: "Alpha project",
            icon: nil,
            tabs: tabs,
            onSelectTab: { selectedTab = $0 },
            onCloseTab: { closedTab = $0 },
            onCloseApplication: { didCloseApplication = true }
        )
        controller.loadView()

        #expect(controller.tabButtons.map(\.title) == tabs.map(\.title))
        #expect(controller.tabButtons.allSatisfy { $0.image == nil })
        #expect(controller.tabButtons[0].layer?.borderWidth == 1)
        #expect(controller.tabButtons[1].layer?.borderWidth == 0)
        #expect(controller.tabCloseButtons.count == tabs.count)
        #expect(controller.closeApplicationButton.image != nil)
        #expect(controller.applicationLabel.stringValue == "Terminal")
        #expect(controller.titleLabel.stringValue == "3 Tabs")
        #expect(controller.preferredContentSize.height > 100)
        #expect(controller.view is TaskbarHoverCardView)
        controller.tabButtons[1].performClick(nil)
        #expect(selectedTab == tabs[1])
        controller.tabCloseButtons[2].performClick(nil)
        #expect(closedTab == tabs[2])
        controller.closeApplicationButton.performClick(nil)
        #expect(didCloseApplication)
    }

    @Test("native tab context close dispatches the whole group")
    @MainActor
    func nativeTabContextMenuClosesGroup() {
        let tabs = [
            TaskbarTab(id: "alpha", title: "Alpha", isSelected: true),
            TaskbarTab(id: "beta", title: "Beta", isSelected: false),
        ]
        let item = TaskbarItem(
            id: "native-group", pid: 42, applicationName: "Terminal", title: "Alpha",
            displayIdentifier: "main", cgWindowNumber: 7, isActive: false,
            nativeTabGroupID: "native-group", nativeTabs: tabs)
        var command: WindowCommand?
        var closedItem: TaskbarItem?
        let frame = NSRect(x: 0, y: 0, width: 600, height: 30)
        let panel = TaskbarPanel(
            frame: frame,
            onActivate: { _ in },
            onClose: { closedItem = $0 },
            onWindowCommand: { command = $0 })
        defer { panel.close() }
        update(panel, frame: frame, items: [item])
        panel.contentView?.layoutSubtreeIfNeeded()
        guard let closeItem = taskbarButtons(in: panel).first?.contextualMenu?.items.last,
            let action = closeItem.action
        else {
            Issue.record("native tab group Close command was not rendered")
            return
        }

        #expect(closeItem.title == "Close All Tabs")
        #expect(NSApplication.shared.sendAction(action, to: closeItem.target, from: closeItem))
        #expect(command == .closeTabGroup(item))
        #expect(closedItem == nil)
    }

    @Test("native tab selection focuses the group before pressing the requested tab")
    @MainActor
    func nativeTabSelectionOrder() {
        var events: [String] = []

        let error = NativeTabSelectionSequence.perform(
            activateGroup: { events.append("activate") },
            refreshGroup: { events.append("refresh-group") },
            pressTab: {
                events.append("press")
                return .success
            },
            refresh: { events.append("refresh") }
        )

        #expect(error == .success)
        #expect(events == ["activate", "refresh-group", "press", "refresh"])
    }

    @Test("native tab selection falls back to the current element at the requested index")
    func nativeTabSelectionResolvesStaleIdentity() {
        #expect(
            NativeTabSelectionTarget.resolve(
                stableElement: nil,
                currentElements: ["current-alpha", "current-beta"],
                index: 1
            ) == "current-beta")
        #expect(
            NativeTabSelectionTarget.resolve(
                stableElement: "stable-beta",
                currentElements: ["current-alpha", "current-beta"],
                index: 1
            ) == "stable-beta")
    }

    @Test("hover tracking emits balanced enter and exit events")
    @MainActor
    func hoverTrackingEvents() {
        let button = TaskbarHoverButton(title: "Window", target: nil, action: nil)
        var states: [Bool] = []
        button.onHoverChanged = { _, hovering in states.append(hovering) }
        guard
            let cgEvent = CGEvent(
                mouseEventSource: nil,
                mouseType: .mouseMoved,
                mouseCursorPosition: .zero,
                mouseButton: .left),
            let event = NSEvent(cgEvent: cgEvent)
        else {
            Issue.record("could not construct hover fixture")
            return
        }

        button.mouseEntered(with: event)
        button.mouseEntered(with: event)
        button.mouseExited(with: event)
        button.mouseExited(with: event)

        #expect(states == [true, false])
        #expect(!button.isPointerInside)
        #expect(button.acceptsFirstMouse(for: nil))
        #expect(TaskbarHoverPresenter.popoverBehavior == .applicationDefined)
    }

    @Test("middle click emits exactly one semantic close command")
    @MainActor
    func middleClickClosesExactlyOnce() {
        let item = makeTaskbarItem(id: "middle-click")
        var closeCount = 0
        let frame = NSRect(x: 0, y: 0, width: 500, height: 30)
        let panel = TaskbarPanel(
            frame: frame,
            onActivate: { _ in },
            onClose: { _ in },
            onWindowCommand: { command in
                if case .close(let closed) = command, closed.id == item.id { closeCount += 1 }
            })
        defer { panel.close() }
        update(panel, frame: frame, items: [item])
        panel.contentView?.layoutSubtreeIfNeeded()
        guard let button = taskbarButtons(in: panel).first,
            let cgEvent = CGEvent(
                mouseEventSource: nil,
                mouseType: .otherMouseDown,
                mouseCursorPosition: .zero,
                mouseButton: .center),
            let event = NSEvent(cgEvent: cgEvent)
        else {
            Issue.record("could not construct middle-click fixture")
            return
        }
        button.otherMouseDown(with: event)
        #expect(closeCount == 1)
    }

    @Test("minimize others affects only eligible peers on the target display")
    @MainActor
    func minimizeOthersScope() {
        let displays = [
            DisplayDescriptor(
                identifier: "left", frame: CGRect(x: 0, y: 0, width: 1000, height: 800)),
            DisplayDescriptor(
                identifier: "right", frame: CGRect(x: 1000, y: 0, width: 1000, height: 800)),
        ]
        let candidates = [
            WindowCandidate(
                stableKey: "target", pid: 10, applicationName: "Target",
                applicationIdentity: "com.example.Target",
                applicationBundlePath: "/Applications/Target.app",
                title: "Target", frame: CGRect(x: 10, y: 10, width: 300, height: 300)),
            WindowCandidate(
                stableKey: "peer", pid: 11, applicationName: "Peer",
                applicationIdentity: "com.example.Peer",
                applicationBundlePath: "/Applications/Peer.app",
                title: "Peer", frame: CGRect(x: 350, y: 10, width: 300, height: 300)),
            WindowCandidate(
                stableKey: "excluded", pid: 12, applicationName: "Excluded",
                applicationIdentity: "com.example.Excluded",
                applicationBundlePath: "/Applications/Excluded.app",
                title: "Excluded", frame: CGRect(x: 50, y: 350, width: 300, height: 300)),
            WindowCandidate(
                stableKey: "other-display", pid: 13, applicationName: "Other",
                applicationIdentity: "com.example.Other",
                applicationBundlePath: "/Applications/Other.app",
                title: "Other", frame: CGRect(x: 1100, y: 10, width: 300, height: 300)),
        ]
        let cgWindows = candidates.enumerated().map { index, candidate in
            CGWindowMetadata(
                windowNumber: UInt32(index + 1), ownerPID: candidate.pid,
                bounds: candidate.frame!, title: candidate.title)
        }
        let provider = MockWindowSnapshotProvider(
            snapshot: RawWindowSnapshot(
                candidates: candidates,
                cgWindows: cgWindows,
                displays: displays,
                frontmostPID: 10))
        let store = TaskbarStore(provider: provider)
        store.start(accessibilityTrusted: true)
        store.refreshNow()
        guard
            let target = store.state.itemsByDisplay["left"]?.first(where: {
                $0.id == "target"
            })
        else {
            Issue.record("target was not projected")
            return
        }

        store.execute(
            .minimizeOthers(target),
            excludingApplicationIdentities: ["com.example.Excluded"])

        #expect(provider.minimizedItemIDs == ["peer"])
        #expect(provider.activatedItemIDs == ["target"])
    }

    @Test("select tab command routes through the current group item")
    @MainActor
    func selectTabCommandUsesCurrentItem() {
        let provider = MockWindowSnapshotProvider(snapshot: makeFixtureSnapshot())
        let store = TaskbarStore(provider: provider)
        defer { store.stop() }
        store.start(accessibilityTrusted: true)
        store.refreshNow()
        guard let item = store.state.itemsByDisplay["main"]?.first else {
            Issue.record("fixture item was not projected")
            return
        }
        let tab = TaskbarTab(id: "tab-beta", title: "Beta", isSelected: false)

        store.execute(.selectTab(item, tab))

        #expect(provider.selectedTabIDs == ["tab-beta"])
        #expect(provider.activatedItemIDs == [item.id])
    }

    @Test("tab close commands route individual and whole-group intent")
    @MainActor
    func tabCloseCommandsRouteIntent() {
        let provider = MockWindowSnapshotProvider(snapshot: makeFixtureSnapshot())
        let store = TaskbarStore(provider: provider)
        defer { store.stop() }
        store.start(accessibilityTrusted: true)
        store.refreshNow()
        guard let item = store.state.itemsByDisplay["main"]?.first else {
            Issue.record("fixture item was not projected")
            return
        }
        let tab = TaskbarTab(id: "tab-beta", title: "Beta", isSelected: false, index: 1)

        store.execute(.closeTab(item, tab))
        store.execute(.closeTabGroup(item))

        #expect(provider.closedTabIDs == ["tab-beta"])
        #expect(provider.closedGroupIDs == [item.id])
    }

    @Test("close application closes every projected window with the same identity")
    @MainActor
    func closeApplicationClosesMatchingWindows() {
        let frame = CGRect(x: 100, y: 100, width: 500, height: 300)
        let candidates = ["One", "Two"].enumerated().map { index, title in
            WindowCandidate(
                stableKey: "window-\(index)", pid: fixturePID,
                applicationName: "Fixture", applicationIdentity: "com.example.Fixture",
                title: title, frame: frame.offsetBy(dx: CGFloat(index * 40), dy: 0))
        }
        let cgWindows = candidates.enumerated().map { index, candidate in
            CGWindowMetadata(
                windowNumber: UInt32(index + 1), ownerPID: fixturePID,
                bounds: candidate.frame!, title: candidate.title)
        }
        let provider = MockWindowSnapshotProvider(
            snapshot: RawWindowSnapshot(
                candidates: candidates, cgWindows: cgWindows,
                displays: [fixtureDisplay], frontmostPID: fixturePID))
        let store = TaskbarStore(provider: provider)
        defer { store.stop() }
        store.start(accessibilityTrusted: true)
        store.refreshNow()
        guard let item = store.state.itemsByDisplay["main"]?.first else {
            Issue.record("fixture windows were not projected")
            return
        }

        store.execute(.closeApplication(item))

        #expect(provider.closeCount == 2)
    }

    @Test("minimize all affects every eligible visible window")
    @MainActor
    func minimizeAllScope() {
        let displays = [
            DisplayDescriptor(
                identifier: "left", frame: CGRect(x: 0, y: 0, width: 1000, height: 800)),
            DisplayDescriptor(
                identifier: "right", frame: CGRect(x: 1000, y: 0, width: 1000, height: 800)),
        ]
        let candidates = [
            WindowCandidate(
                stableKey: "left", pid: 10, applicationName: "Left",
                applicationIdentity: "com.example.Left", title: "Left",
                frame: CGRect(x: 10, y: 10, width: 300, height: 300)),
            WindowCandidate(
                stableKey: "right", pid: 11, applicationName: "Right",
                applicationIdentity: "com.example.Right", title: "Right",
                frame: CGRect(x: 1100, y: 10, width: 300, height: 300)),
            WindowCandidate(
                stableKey: "excluded", pid: 12, applicationName: "Excluded",
                applicationIdentity: "com.example.Excluded", title: "Excluded",
                frame: CGRect(x: 350, y: 10, width: 300, height: 300)),
            WindowCandidate(
                stableKey: "minimized", pid: 13, applicationName: "Minimized",
                applicationIdentity: "com.example.Minimized", title: "Minimized",
                frame: CGRect(x: 400, y: 400, width: 300, height: 300), isMinimized: true),
            WindowCandidate(
                stableKey: "hidden", pid: 14, applicationName: "Hidden",
                applicationIdentity: "com.example.Hidden", applicationIsHidden: true,
                title: "Hidden", frame: CGRect(x: 1_450, y: 400, width: 300, height: 300)),
        ]
        let cgWindows = candidates.filter { !$0.isMinimized }.enumerated().map {
            index, candidate in
            CGWindowMetadata(
                windowNumber: UInt32(index + 1), ownerPID: candidate.pid,
                bounds: candidate.frame!, title: candidate.title)
        }
        let provider = MockWindowSnapshotProvider(
            snapshot: RawWindowSnapshot(
                candidates: candidates,
                cgWindows: cgWindows,
                displays: displays,
                frontmostPID: 10))
        let store = TaskbarStore(provider: provider)
        store.start(accessibilityTrusted: true)
        store.refreshNow()

        store.execute(
            .minimizeAll,
            excludingApplicationIdentities: ["com.example.Excluded"])

        #expect(provider.minimizedItemIDs == ["left", "right"])
        #expect(provider.activatedItemIDs.isEmpty)
    }

    @Test("closed pinned launcher uses primary click and retained context commands")
    @MainActor
    func pinnedLauncherInteractions() {
        let app = ApplicationRecord(
            identity: "com.example.Editor",
            bundleIdentifier: "com.example.Editor",
            bundlePath: "/Applications/Editor.app",
            localizedName: "Editor",
            sequence: 0)
        var launched: ApplicationRecord?
        let frame = NSRect(x: 0, y: 0, width: 500, height: 30)
        let panel = TaskbarPanel(
            frame: frame,
            onActivate: { _ in },
            onClose: { _ in },
            onApplicationCommand: { command in
                if case .launch(let application) = command { launched = application }
            })
        defer { panel.close() }
        var preferences = TinyTaskbarPreferences.defaults
        preferences.pinnedApplications = [app]
        panel.update(frame: frame, entries: [.launcher(app)], preferences: preferences)
        panel.contentView?.layoutSubtreeIfNeeded()
        guard
            let launcher = panel.contentView.map({ allSubviews(of: $0) })?
                .compactMap({ $0 as? TaskbarLauncherButton }).first
        else {
            Issue.record("launcher was not rendered")
            return
        }
        #expect(
            launcher.contextualMenu?.items.map(\.title)
                == [
                    "Open", "", "TinyTaskbar",
                ])
        #expect(
            launcher.contextualMenu?.items[2].submenu?.items.map(\.title)
                == [
                    "Unpin Application", "Never Show This App", "", "Settings…",
                    "Quit TinyTaskbar",
                ])
        launcher.performClick(nil)
        #expect(launched == app)
    }

    @Test("closed pinned launcher sits directly beside windows")
    @MainActor
    func pinnedLauncherDividerGeometry() {
        let app = ApplicationRecord(
            identity: "com.example.Pinned",
            bundleIdentifier: "com.example.Pinned",
            localizedName: "Pinned",
            sequence: 0)
        let item = makeTaskbarItem(id: "window")
        let frame = NSRect(x: 0, y: 0, width: 500, height: 30)
        let panel = TaskbarPanel(frame: frame, onActivate: { _ in }, onClose: { _ in })
        defer { panel.close() }

        var preferences = TinyTaskbarPreferences.defaults
        preferences.pinnedApplications = [app]
        panel.update(
            frame: frame,
            entries: [.launcher(app), .window(item)],
            preferences: preferences)
        panel.contentView?.layoutSubtreeIfNeeded()

        guard let contentView = panel.contentView,
            let launcher = allSubviews(of: contentView).compactMap({
                $0 as? TaskbarLauncherButton
            }).first,
            let button = taskbarButtons(in: panel).first
        else {
            Issue.record("pinned launcher transition was not rendered")
            return
        }

        let launcherFrame = contentView.convert(launcher.bounds, from: launcher)
        let buttonFrame = contentView.convert(button.bounds, from: button)
        #expect(buttonFrame.minX - launcherFrame.maxX == 2)
    }

    @Test("compact icon-only presentation remains vertically contained")
    @MainActor
    func compactIconOnlyGeometry() {
        let frame = NSRect(x: 0, y: 0, width: 500, height: 26)
        let item = makeTaskbarItem(id: "compact")
        let panel = TaskbarPanel(frame: frame, onActivate: { _ in }, onClose: { _ in })
        defer { panel.close() }
        var preferences = TinyTaskbarPreferences.defaults
        preferences.labelMode = .iconOnly
        preferences.density = .compact
        panel.update(frame: frame, entries: [.window(item)], preferences: preferences)
        panel.contentView?.layoutSubtreeIfNeeded()
        guard let contentView = panel.contentView,
            let button = taskbarButtons(in: panel).first,
            let scrollView = allSubviews(of: contentView).compactMap({ $0 as? NSScrollView }).first
        else {
            Issue.record("compact presentation was not rendered")
            return
        }
        let buttonFrame = contentView.convert(button.bounds, from: button)
        #expect(button.title.isEmpty)
        #expect(button.heightConstraint?.constant == 23)
        #expect(button.frame.height == 23)
        #expect(button.accessibilityLabel() == item.accessibilityLabel)
        #expect(buttonFrame.minY >= contentView.bounds.minY)
        #expect(buttonFrame.maxY <= contentView.bounds.maxY)
        #expect(scrollView.hasHorizontalScroller == false)
        #expect(scrollView.horizontalScroller == nil)
    }

    @Test("taskbar shrinks labels before scrolling and can switch to icons")
    @MainActor
    func taskbarOverflowPresentation() {
        let items = (0..<5).map { makeTaskbarItem(id: "overflow-\($0)") }
        let panel = TaskbarPanel(
            frame: NSRect(x: 0, y: 0, width: 700, height: 30),
            onActivate: { _ in },
            onClose: { _ in })
        defer { panel.close() }
        var preferences = TinyTaskbarPreferences.defaults

        panel.update(
            frame: NSRect(x: 0, y: 0, width: 700, height: 30),
            entries: items.map(TaskbarPresentationEntry.window),
            preferences: preferences)
        panel.contentView?.layoutSubtreeIfNeeded()
        var buttons = taskbarButtons(in: panel)
        let roomyScrollView = allSubviews(of: panel.contentView!).compactMap { $0 as? NSScrollView }
            .first
        #expect(buttons.count == 5)
        #expect(buttons.allSatisfy { $0.frame.width < 180 && $0.frame.width >= 110 })
        #expect(
            (roomyScrollView?.documentView?.frame.width ?? .greatestFiniteMagnitude)
                <= (roomyScrollView?.contentView.bounds.width ?? 0) + 1)

        let narrowFrame = NSRect(x: 0, y: 0, width: 480, height: 30)
        panel.update(
            frame: narrowFrame,
            entries: items.map(TaskbarPresentationEntry.window),
            preferences: preferences)
        panel.contentView?.layoutSubtreeIfNeeded()
        buttons = taskbarButtons(in: panel)
        let scrollingView = allSubviews(of: panel.contentView!).compactMap { $0 as? NSScrollView }
            .first
        #expect(buttons.allSatisfy { abs($0.frame.width - 110) <= 1 })
        #expect(
            (scrollingView?.documentView?.frame.width ?? 0)
                > (scrollingView?.contentView.bounds.width ?? .greatestFiniteMagnitude))

        preferences.overflowBehavior = .automaticIcons
        panel.update(
            frame: narrowFrame,
            entries: items.map(TaskbarPresentationEntry.window),
            preferences: preferences)
        panel.contentView?.layoutSubtreeIfNeeded()
        buttons = taskbarButtons(in: panel)
        let iconScrollView = allSubviews(of: panel.contentView!).compactMap { $0 as? NSScrollView }
            .first
        #expect(buttons.allSatisfy { $0.title.isEmpty && abs($0.frame.width - 32) <= 1 })
        #expect(
            (iconScrollView?.documentView?.frame.width ?? .greatestFiniteMagnitude)
                <= (iconScrollView?.contentView.bounds.width ?? 0) + 1)
    }

    @Test("maximized windows are constrained above the taskbar and restored when hidden")
    @MainActor
    func maximizedWindowRespectsTaskbarWorkArea() {
        let display = DisplayDescriptor(
            identifier: "main",
            frame: CGRect(x: 0, y: 0, width: 1_440, height: 900),
            appKitFrame: CGRect(x: 0, y: 0, width: 1_440, height: 900),
            appKitVisibleFrame: CGRect(x: 80, y: 50, width: 1_360, height: 825))
        let nativeWorkArea = CGRect(x: 80, y: 25, width: 1_360, height: 825)
        let constrainedFrame = CGRect(x: 80, y: 25, width: 1_360, height: 795)

        #expect(TaskbarPanelLayout.nativeWindowWorkArea(for: display) == nativeWorkArea)
        #expect(
            TaskbarPanelLayout.constrainedFullHeightWindowFrame(
                for: nativeWorkArea, on: display, taskbarHeight: 30)
                == constrainedFrame)
        let leftHalfFrame = CGRect(x: 80, y: 25, width: 680, height: 825)
        #expect(
            TaskbarPanelLayout.constrainedFullHeightWindowFrame(
                for: leftHalfFrame, on: display, taskbarHeight: 30)
                == CGRect(x: 80, y: 25, width: 680, height: 795))
        #expect(
            TaskbarPanelLayout.constrainedFullHeightWindowFrame(
                for: display.frame, on: display, taskbarHeight: 30) == nil)
        #expect(
            TaskbarPanelLayout.constrainedFullHeightWindowFrame(
                for: nativeWorkArea.insetBy(dx: 20, dy: 20),
                on: display,
                taskbarHeight: 30) == nil)

        func snapshot(frame: CGRect) -> RawWindowSnapshot {
            let candidate = WindowCandidate(
                stableKey: "maximized-window",
                pid: fixturePID,
                applicationName: "Fixture",
                title: "Maximized",
                frame: frame,
                isFocused: true,
                isMain: true)
            return RawWindowSnapshot(
                candidates: [candidate],
                cgWindows: [
                    CGWindowMetadata(
                        windowNumber: 88,
                        ownerPID: fixturePID,
                        bounds: frame,
                        title: candidate.title)
                ],
                displays: [display],
                frontmostPID: fixturePID)
        }

        let provider = MockWindowSnapshotProvider(snapshot: snapshot(frame: nativeWorkArea))
        let store = TaskbarStore(provider: provider)
        store.start(accessibilityTrusted: true)
        store.refreshNow()
        defer { store.stop() }

        store.setTaskbarWorkAreaHeights(["main": 30])
        #expect(provider.heightUpdates.count == 1)
        #expect(provider.heightUpdates.last?.itemID == "maximized-window")
        #expect(provider.heightUpdates.last?.height == constrainedFrame.height)
        // A successful AX write can still be immediately overwritten by another window
        // manager. Until the applied frame is observed, verification retries the correction.
        store.setTaskbarWorkAreaHeights(["main": 30])
        #expect(provider.heightUpdates.count == 2)

        provider.snapshotValue = snapshot(frame: constrainedFrame)
        store.refreshNow()
        store.setTaskbarWorkAreaHeights(["main": 26])
        let compactFrame = CGRect(x: 80, y: 25, width: 1_360, height: 799)
        #expect(provider.heightUpdates.count == 3)
        #expect(provider.heightUpdates.last?.height == compactFrame.height)

        provider.snapshotValue = snapshot(frame: compactFrame)
        store.refreshNow()
        store.setTaskbarWorkAreaHeights([:])
        #expect(provider.heightUpdates.count == 4)
        #expect(provider.heightUpdates.last?.height == nativeWorkArea.height)
    }

    @Test("a later maximize and concurrent tile are constrained without overriding manual resize")
    @MainActor
    func maximizeEventAndManualResizeAreSafe() {
        let display = DisplayDescriptor(
            identifier: "main",
            frame: CGRect(x: 0, y: 0, width: 1_200, height: 800),
            appKitFrame: CGRect(x: 0, y: 0, width: 1_200, height: 800),
            appKitVisibleFrame: CGRect(x: 0, y: 40, width: 1_200, height: 735))
        let nativeWorkArea = CGRect(x: 0, y: 25, width: 1_200, height: 735)
        let leftHalfWorkArea = CGRect(x: 0, y: 25, width: 600, height: 735)
        let ordinaryFrame = CGRect(x: 100, y: 100, width: 700, height: 500)
        let manuallyResizedFrame = CGRect(x: 40, y: 60, width: 900, height: 620)

        func snapshot(frame: CGRect) -> RawWindowSnapshot {
            let candidate = WindowCandidate(
                stableKey: "event-window",
                pid: fixturePID,
                applicationName: "Fixture",
                title: "Event Window",
                frame: frame,
                isFocused: true,
                isMain: true)
            return RawWindowSnapshot(
                candidates: [candidate],
                cgWindows: [
                    CGWindowMetadata(
                        windowNumber: 89,
                        ownerPID: fixturePID,
                        bounds: frame,
                        title: candidate.title)
                ],
                displays: [display],
                frontmostPID: fixturePID)
        }

        let provider = MockWindowSnapshotProvider(snapshot: snapshot(frame: ordinaryFrame))
        let store = TaskbarStore(provider: provider)
        store.start(accessibilityTrusted: true)
        store.refreshNow()
        defer { store.stop() }
        store.setTaskbarWorkAreaHeights(["main": 30])
        #expect(provider.heightUpdates.isEmpty)

        // The window changes size but its taskbar identity and active state do not.
        // Enforcement must run on every refresh, not only on presentation changes.
        provider.snapshotValue = snapshot(frame: nativeWorkArea)
        store.refreshNow()
        #expect(provider.heightUpdates.last?.height == 705)

        // Rectangle/Raycast can finish the horizontal tile after TinyTaskbar's first
        // correction. Re-evaluate that new full-height frame immediately, in the same refresh.
        provider.snapshotValue = snapshot(frame: leftHalfWorkArea)
        store.refreshNow()
        #expect(provider.heightUpdates.count == 2)
        #expect(provider.heightUpdates.last?.height == 705)

        provider.snapshotValue = snapshot(frame: manuallyResizedFrame)
        store.refreshNow()
        store.setTaskbarWorkAreaHeights([:])
        #expect(provider.heightUpdates.count == 2)
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

    @Test("close confirms disappearance after an early stale snapshot")
    @MainActor
    func closeSchedulesSettledConfirmation() async {
        let provider = MockWindowSnapshotProvider(snapshot: makeFixtureSnapshot())
        let store = TaskbarStore(provider: provider)
        defer { store.stop() }
        store.start(accessibilityTrusted: true)
        await waitForSnapshot(from: provider)

        guard let item = store.state.itemsByDisplay["main"]?.first else {
            Issue.record("fixture item was not projected")
            return
        }
        store.execute(.close(item))
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            provider.snapshotValue = RawWindowSnapshot(
                candidates: [],
                cgWindows: [],
                displays: [fixtureDisplay],
                frontmostPID: nil,
                evidence: WindowSnapshotEvidence(
                    isComplete: true,
                    knownApplicationPIDs: [fixturePID],
                    axWindowListReadPIDs: [fixturePID]))
        }

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while !store.state.itemsByDisplay.isEmpty, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }

        #expect(store.state.itemsByDisplay.isEmpty)
        #expect(provider.closeCount == 1)
        #expect(provider.snapshotCount >= 4)
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

    @Test("hidden windows remain actionable while confirmed absence removes items")
    func hiddenRetentionAndAuthoritativeRemoval() {
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
            applicationIsHidden: true,
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
        #expect(hiddenResult.itemsByDisplay["main"]?.map(\.id) == ["hidden"])
        #expect(hiddenResult.itemsByDisplay["main"]?.first?.isHidden == true)
        #expect(hiddenResult.itemsByDisplay["main"]?.first?.tooltip == "Show Hidden: Hidden")

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

    @Test("AX identity turnover replaces stale aliases of the same CG window")
    func axIdentityTurnoverDoesNotDuplicateWindows() {
        let display = DisplayDescriptor(
            identifier: "main",
            frame: CGRect(x: 0, y: 0, width: 1_200, height: 800)
        )
        let frame = CGRect(x: 100, y: 100, width: 500, height: 300)
        let staleItems = ["old-1", "old-2"].map { id in
            TaskbarItem(
                id: id,
                pid: 10,
                applicationName: "Editor",
                title: "Document",
                displayIdentifier: "main",
                cgWindowNumber: 42,
                stableOrderKey: id,
                isActive: false
            )
        }
        let currentItem = TaskbarItem(
            id: "current",
            pid: 10,
            applicationName: "Editor",
            title: "Document",
            displayIdentifier: "main",
            cgWindowNumber: 42,
            stableOrderKey: "current",
            isActive: true
        )
        let currentCandidate = WindowCandidate(
            stableKey: "current",
            pid: 10,
            applicationName: "Editor",
            title: "Document",
            frame: frame,
            isFocused: true,
            isMain: true
        )
        let snapshot = RawWindowSnapshot(
            candidates: [currentCandidate],
            cgWindows: [
                CGWindowMetadata(
                    windowNumber: 42,
                    ownerPID: 10,
                    bounds: frame,
                    title: "Document"
                )
            ],
            displays: [display],
            frontmostPID: 10,
            evidence: WindowSnapshotEvidence(
                isComplete: true,
                knownApplicationPIDs: [10],
                axWindowListReadPIDs: [10],
                observedAXWindowIDs: ["current"]
            )
        )

        let resolved = TaskbarStateContinuity().resolve(
            previous: TaskbarState(
                displays: [display],
                itemsByDisplay: ["main": staleItems]
            ),
            incoming: TaskbarState(
                displays: [display],
                itemsByDisplay: ["main": [currentItem]]
            ),
            snapshot: snapshot
        )

        #expect(resolved.itemsByDisplay["main"] == [currentItem])
    }

    @Test("minimizing a native tab group retains only the physically observed tab")
    func minimizedNativeTabSiblingsDoNotBecomeTaskbarItems() {
        let display = DisplayDescriptor(
            identifier: "main",
            frame: CGRect(x: 0, y: 0, width: 1_200, height: 800)
        )
        let frame = CGRect(x: 100, y: 100, width: 500, height: 300)
        let selectedItem = TaskbarItem(
            id: "selected-tab",
            pid: 10,
            applicationName: "Terminal",
            title: "Selected",
            displayIdentifier: "main",
            cgWindowNumber: 42,
            stableOrderKey: "selected-tab",
            isMinimized: false,
            isActive: false
        )
        let candidates = [
            WindowCandidate(
                stableKey: "selected-tab",
                pid: 10,
                applicationName: "Terminal",
                title: "Selected",
                frame: frame,
                isMinimized: true
            ),
            WindowCandidate(
                stableKey: "background-tab",
                pid: 10,
                applicationName: "Terminal",
                title: "Background",
                frame: frame,
                isMinimized: true
            ),
        ]
        let snapshot = RawWindowSnapshot(
            candidates: candidates,
            cgWindows: [],
            displays: [display],
            frontmostPID: nil,
            evidence: WindowSnapshotEvidence(
                isComplete: true,
                knownApplicationPIDs: [10],
                axWindowListReadPIDs: [10],
                observedAXWindowIDs: ["selected-tab", "background-tab"]
            )
        )

        let resolved = TaskbarStateContinuity().resolve(
            previous: TaskbarState(
                displays: [display],
                itemsByDisplay: ["main": [selectedItem]]
            ),
            incoming: WindowProjection.project(
                candidates: candidates,
                cgWindows: [],
                displays: [display],
                selfPID: 999
            ),
            snapshot: snapshot
        )

        #expect(resolved.itemsByDisplay["main"]?.count == 1)
        #expect(resolved.itemsByDisplay["main"]?.first?.id == "selected-tab")
        #expect(resolved.itemsByDisplay["main"]?.first?.cgWindowNumber == 42)
        #expect(resolved.itemsByDisplay["main"]?.first?.isMinimized == true)
    }

    @Test("switching native tabs replaces the previously selected tab")
    func selectedNativeTabReplacesOffScreenSibling() {
        let display = DisplayDescriptor(
            identifier: "main",
            frame: CGRect(x: 0, y: 0, width: 1_200, height: 800)
        )
        let frame = CGRect(x: 100, y: 100, width: 500, height: 300)
        let previousItem = TaskbarItem(
            id: "previous-tab",
            pid: 10,
            applicationName: "Ghostty",
            title: "Previous tab",
            displayIdentifier: "main",
            cgWindowNumber: 41,
            stableOrderKey: "previous-tab",
            isActive: true
        )
        let selectedItem = TaskbarItem(
            id: "selected-tab",
            pid: 10,
            applicationName: "Ghostty",
            title: "Selected tab",
            displayIdentifier: "main",
            cgWindowNumber: 42,
            stableOrderKey: "selected-tab",
            isActive: true
        )
        let candidates = [
            WindowCandidate(
                stableKey: "previous-tab",
                cgWindowNumber: 41,
                pid: 10,
                applicationName: "Ghostty",
                title: "Previous tab",
                frame: frame
            ),
            WindowCandidate(
                stableKey: "selected-tab",
                cgWindowNumber: 42,
                pid: 10,
                applicationName: "Ghostty",
                title: "Selected tab",
                frame: frame,
                isFocused: true,
                isMain: true
            ),
        ]
        let snapshot = RawWindowSnapshot(
            candidates: candidates,
            cgWindows: [
                CGWindowMetadata(
                    windowNumber: 41,
                    ownerPID: 10,
                    bounds: frame,
                    title: "Previous tab",
                    isOnScreen: false
                ),
                CGWindowMetadata(
                    windowNumber: 42,
                    ownerPID: 10,
                    bounds: frame,
                    title: "Selected tab"
                ),
            ],
            displays: [display],
            frontmostPID: 10,
            evidence: WindowSnapshotEvidence(
                isComplete: true,
                knownApplicationPIDs: [10],
                axWindowListReadPIDs: [10],
                observedAXWindowIDs: ["previous-tab", "selected-tab"]
            )
        )

        let resolved = TaskbarStateContinuity().resolve(
            previous: TaskbarState(
                displays: [display],
                itemsByDisplay: ["main": [previousItem]]
            ),
            incoming: TaskbarState(
                displays: [display],
                itemsByDisplay: ["main": [selectedItem]]
            ),
            snapshot: snapshot
        )

        #expect(resolved.itemsByDisplay["main"] == [selectedItem])
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

    @Test("primary click uses fresh focus and the configured active-window behavior")
    @MainActor
    func primaryClickUsesFreshStateAndPreference() {
        let provider = MockWindowSnapshotProvider(snapshot: makeFixtureSnapshot())
        let store = TaskbarStore(provider: provider)
        store.start(accessibilityTrusted: true)
        store.refreshNow()
        defer { store.stop() }

        guard let activeItem = store.state.itemsByDisplay["main"]?.first else {
            Issue.record("fixture item was not projected")
            return
        }
        let staleInactiveItem = copy(activeItem, isActive: false)

        store.performPrimaryClick(staleInactiveItem, activeWindowBehavior: .minimize)
        #expect(provider.minimizeCount == 1)
        #expect(provider.activationCount == 0)

        store.performPrimaryClick(staleInactiveItem, activeWindowBehavior: .doNothing)
        #expect(provider.minimizeCount == 1)
        #expect(provider.activationCount == 0)

        provider.snapshotValue = makeFixtureSnapshot(isActive: false)
        let staleActiveItem = copy(activeItem, isActive: true)
        store.performPrimaryClick(staleActiveItem, activeWindowBehavior: .doNothing)
        #expect(provider.minimizeCount == 1)
        #expect(provider.activationCount == 1)

        store.setAccessibilityAvailable(false)
        store.performPrimaryClick(staleActiveItem, activeWindowBehavior: .minimize)
        #expect(provider.minimizeCount == 1)
        #expect(provider.activationCount == 1)
    }

    @Test("primary click follows physical identity through AX identity turnover")
    @MainActor
    func primaryClickSurvivesIdentityTurnover() {
        let provider = MockWindowSnapshotProvider(
            snapshot: identitySnapshot(stableKey: "old-identity"))
        let store = TaskbarStore(provider: provider)
        store.start(accessibilityTrusted: true)
        store.refreshNow()
        defer { store.stop() }

        guard let oldItem = store.state.itemsByDisplay["main"]?.first else {
            Issue.record("old fixture identity was not projected")
            return
        }
        provider.snapshotValue = identitySnapshot(stableKey: "new-identity")

        store.performPrimaryClick(oldItem, activeWindowBehavior: .minimize)

        #expect(provider.activatedItemIDs == ["new-identity"])
        #expect(store.state.itemsByDisplay["main"]?.map(\.id) == ["new-identity"])
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

    private func identitySnapshot(stableKey: String) -> RawWindowSnapshot {
        let frame = CGRect(x: 100, y: 100, width: 500, height: 300)
        let candidate = WindowCandidate(
            stableKey: stableKey,
            cgWindowNumber: 77,
            pid: fixturePID,
            applicationName: "Fixture",
            title: "Document",
            frame: frame
        )
        return RawWindowSnapshot(
            candidates: [candidate],
            cgWindows: [
                CGWindowMetadata(
                    windowNumber: 77,
                    ownerPID: fixturePID,
                    bounds: frame,
                    title: candidate.title)
            ],
            displays: [fixtureDisplay],
            frontmostPID: nil,
            evidence: WindowSnapshotEvidence(
                isComplete: true,
                knownApplicationPIDs: [fixturePID],
                axWindowListReadPIDs: [fixturePID],
                observedAXWindowIDs: [stableKey]
            )
        )
    }

    private func copy(_ item: TaskbarItem, isActive: Bool) -> TaskbarItem {
        TaskbarItem(
            id: item.id,
            pid: item.pid,
            applicationName: item.applicationName,
            applicationIdentity: item.applicationIdentity,
            applicationBundlePath: item.applicationBundlePath,
            title: item.title,
            displayIdentifier: item.displayIdentifier,
            cgWindowNumber: item.cgWindowNumber,
            isMinimized: item.isMinimized,
            isActive: isActive
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
    private func update(
        _ panel: TaskbarPanel,
        frame: NSRect,
        items: [TaskbarItem],
        labelMode: TaskbarLabelMode = .windowTitle
    ) {
        var preferences = TinyTaskbarPreferences.defaults
        preferences.labelMode = labelMode
        panel.update(
            frame: frame,
            entries: items.map(TaskbarPresentationEntry.window),
            preferences: preferences)
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
    var closedTabIDs: [String] = []
    var closedGroupIDs: [String] = []
    var activatedItemIDs: [String] = []
    var selectedTabIDs: [String] = []
    var minimizedItemIDs: [String] = []
    var heightUpdates: [(itemID: String, height: CGFloat)] = []
    var onChange: (@MainActor @Sendable (WindowSnapshotChange) -> Void)?

    init(snapshot: RawWindowSnapshot? = nil) {
        if let snapshot {
            snapshotValue = snapshot
        }
    }

    func snapshot() -> RawWindowSnapshot {
        snapshotCount += 1
        return snapshotValue
    }

    func activate(_ item: TaskbarItem) {
        activationCount += 1
        activatedItemIDs.append(item.id)
    }

    func selectTab(_ tab: TaskbarTab, in item: TaskbarItem) {
        selectedTabIDs.append(tab.id)
        activate(item)
    }

    func closeTab(_ tab: TaskbarTab, in _: TaskbarItem) {
        closedTabIDs.append(tab.id)
    }

    func closeTabGroup(_ item: TaskbarItem) {
        closedGroupIDs.append(item.id)
    }

    func minimize(_ item: TaskbarItem) {
        minimizeCount += 1
        minimizedItemIDs.append(item.id)
    }

    func close(_: TaskbarItem) {
        closeCount += 1
    }

    @discardableResult
    func setHeight(_ height: CGFloat, for item: TaskbarItem) -> Bool {
        heightUpdates.append((item.id, height))
        return true
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
