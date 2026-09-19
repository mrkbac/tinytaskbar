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

        #expect(abs((window.contentView?.bounds.width ?? 0) - 570) <= 2)
        #expect(window.contentView?.bounds.height == 500)
        #expect(!(window.contentViewController is NSSplitViewController))
        let settingsSubviews = window.contentView.map(allSubviews(of:)) ?? []
        #expect(settingsSubviews.compactMap { $0 as? NSScrollView }.isEmpty)
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

    @Test("Settings uses one compact page")
    @MainActor
    func settingsUsesSinglePage() {
        let window = TinyTaskbarSettingsWindow()
        defer { window.close() }

        #expect(window.title == "TinyTaskbar Settings")
        #expect(window.contentViewController?.children.isEmpty == true)
    }

    @Test("Settings form changes update the model and route callbacks")
    @MainActor
    func settingsFormChangesRouteCallbacks() {
        let model = TinyTaskbarSettingsModel()
        var receivedDockVisibility: Bool?
        model.onHideMacDockChanged = {
            receivedDockVisibility = $0
            return nil
        }

        model.setHideMacDock(true)

        #expect(model.preferences.hideMacDock)
        #expect(receivedDockVisibility == true)
    }

    @Test("Taskbar window menu keeps compact baseline commands")
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
        #expect(contextMenu.items.map(\.title) == ["Minimize", "Minimize All", "", "Close"])
        #expect(panel.contentView?.menu == nil)
        if let minimizeItem = contextMenu.items.first,
            let minimizeAction = minimizeItem.action
        {
            #expect(
                NSApplication.shared.sendAction(
                    minimizeAction, to: minimizeItem.target, from: minimizeItem))
            #expect(windowCommand == .minimize(item))
        } else {
            Issue.record("taskbar Minimize command was not rendered")
        }
        if let minimizeAllItem = contextMenu.items.dropFirst().first,
            let minimizeAllAction = minimizeAllItem.action
        {
            #expect(
                NSApplication.shared.sendAction(
                    minimizeAllAction, to: minimizeAllItem.target, from: minimizeAllItem))
            #expect(windowCommand == .minimizeAll)
        } else {
            Issue.record("taskbar Minimize All command was not rendered")
        }
        itemButton?.performClick(nil)
        #expect(activatedItem?.id == item.id)
        #expect(NSApplication.shared.sendAction(action, to: closeItem.target, from: closeItem))
        #expect(closedItem?.id == item.id)
    }

    @Test("Taskbar window menu exposes the exact window fullscreen capability")
    @MainActor
    func taskbarContextMenuTogglesFullscreenWhenExposed() {
        let item = TaskbarItem(
            id: "fullscreen-window",
            pid: 42,
            applicationName: "Editor",
            title: "Document",
            displayIdentifier: "main",
            cgWindowNumber: 7,
            isActive: false
        )
        var command: WindowCommand?
        let frame = NSRect(x: 0, y: 0, width: 600, height: 30)
        let panel = TaskbarPanel(
            frame: frame,
            onActivate: { _ in },
            onClose: { _ in },
            onWindowCommand: { command = $0 },
            fullscreenCapability: { _ in
                WindowFullscreenCapability(isFullscreen: false, isSettable: true)
            }
        )
        defer { panel.close() }
        update(panel, frame: frame, items: [item])
        panel.contentView?.layoutSubtreeIfNeeded()

        guard let button = taskbarButtons(in: panel).first,
            let enterMenu = button.onMenuRequested?(),
            enterMenu.items.count == 5,
            let action = enterMenu.items[2].action
        else {
            Issue.record("fullscreen context command was not rendered")
            return
        }
        #expect(
            enterMenu.items.map(\.title)
                == ["Minimize", "Minimize All", "Enter Full Screen", "", "Close"])
        #expect(enterMenu.items[2].isEnabled)
        #expect(
            NSApplication.shared.sendAction(
                action, to: enterMenu.items[2].target, from: enterMenu.items[2]))
        #expect(command == .setFullscreen(item, true))

        let readOnlyPanel = TaskbarPanel(
            frame: frame,
            onActivate: { _ in },
            onClose: { _ in },
            fullscreenCapability: { _ in
                WindowFullscreenCapability(isFullscreen: true, isSettable: false)
            }
        )
        defer { readOnlyPanel.close() }
        update(readOnlyPanel, frame: frame, items: [item])
        guard let exitMenu = taskbarButtons(in: readOnlyPanel).first?.onMenuRequested?() else {
            Issue.record("fullscreen context command did not refresh")
            return
        }
        #expect(exitMenu.items[2].title == "Exit Full Screen")
        #expect(!exitMenu.items[2].isEnabled)
    }

    @Test("taskbar context menu stays anchored to the right-click location")
    @MainActor
    func taskbarContextMenuStaysAtRightClick() {
        let clickLocation = NSPoint(x: 237, y: 14)
        let menuSize = NSSize(width: 170, height: 122)

        let location = TaskbarButton.contextMenuScreenLocation(
            clickLocation: clickLocation,
            menuSize: menuSize)

        #expect(location.x == clickLocation.x)
        #expect(location.y - menuSize.height == clickLocation.y)
    }

    @Test("Taskbar window menu copies supported application menu command labels")
    @MainActor
    func taskbarContextMenuCopiesApplicationMenuCommands() {
        let item = TaskbarItem(
            id: "context-window",
            pid: 42,
            applicationName: "Editor",
            title: "Document",
            displayIdentifier: "main",
            cgWindowNumber: 7,
            isActive: false
        )
        let newDocumentCommand = ApplicationMenuCommand(
            title: "New Text File", commandCharacter: "n", commandModifiers: 0)
        let newWindowCommand = ApplicationMenuCommand(
            title: "New Editor Window", commandCharacter: "n",
            commandModifiers: AXMenuItemModifiers.shift.rawValue)
        let newTabCommand = ApplicationMenuCommand(
            title: "New Tab", commandCharacter: "t", commandModifiers: 0)
        var requestedItem: TaskbarItem?
        var applicationCommands: [ApplicationCommand] = []
        let frame = NSRect(x: 0, y: 0, width: 600, height: 30)
        let panel = TaskbarPanel(
            frame: frame,
            onActivate: { _ in },
            onClose: { _ in },
            applicationMenuCommands: {
                requestedItem = $0
                return [newDocumentCommand, newWindowCommand, newTabCommand]
            },
            onApplicationCommand: { applicationCommands.append($0) }
        )
        defer { panel.close() }
        update(panel, frame: frame, items: [item])
        panel.contentView?.layoutSubtreeIfNeeded()

        #expect(requestedItem == nil)
        guard let button = taskbarButtons(in: panel).first,
            let menu = button.onMenuRequested?(),
            let newDocumentItem = menu.items.first,
            let newDocumentAction = newDocumentItem.action,
            let newWindowItem = menu.items.dropFirst().first,
            let newWindowAction = newWindowItem.action,
            let newTabItem = menu.items.dropFirst(2).first,
            let newTabAction = newTabItem.action
        else {
            Issue.record("supported application menu commands were not rendered")
            return
        }

        #expect(requestedItem == item)
        #expect(
            menu.items.map(\.title) == [
                "New Text File", "New Editor Window", "New Tab", "", "Minimize",
                "Minimize All", "", "Close",
            ])
        #expect(
            NSApplication.shared.sendAction(
                newDocumentAction, to: newDocumentItem.target, from: newDocumentItem))
        #expect(
            NSApplication.shared.sendAction(
                newWindowAction, to: newWindowItem.target, from: newWindowItem))
        #expect(
            NSApplication.shared.sendAction(
                newTabAction, to: newTabItem.target, from: newTabItem))
        #expect(
            applicationCommands == [
                .performMenuCommand(item, newDocumentCommand),
                .performMenuCommand(item, newWindowCommand),
                .performMenuCommand(item, newTabCommand),
            ])
    }

    @Test("taskbar panels hide from Mission Control and remain attached to one Space")
    @MainActor
    func taskbarPanelUsesTransientPerSpaceWindowBehavior() {
        let panel = TaskbarPanel(
            frame: NSRect(x: 0, y: 0, width: 600, height: 30),
            onActivate: { _ in },
            onClose: { _ in })
        defer { panel.close() }

        #expect(panel.collectionBehavior.contains(.transient))
        #expect(!panel.collectionBehavior.contains(.managed))
        #expect(!panel.collectionBehavior.contains(.stationary))
        #expect(!panel.collectionBehavior.contains(.canJoinAllSpaces))
        #expect(!panel.collectionBehavior.contains(.moveToActiveSpace))
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
        #expect(updatedSecond.onMenuRequested?().items.first?.title == "Restore")

        update(panel, frame: frame, items: [activeFirst, minimizedSecond])
        panel.contentView?.layoutSubtreeIfNeeded()
        #expect(
            updatedFirst.widthConstraint?.constant
                == TaskbarButtonLayout.preferredWidth)
    }

    @Test("drag hover activates the exact retained window once per drag")
    @MainActor
    func dragHoverActivatesExactWindowOnce() {
        let frame = NSRect(x: 0, y: 0, width: 700, height: TaskbarPanelLayout.defaultHeight)
        let first = makeTaskbarItem(id: "first", title: "First")
        let second = makeTaskbarItem(id: "second", title: "Second")
        var commands: [WindowCommand] = []
        let panel = TaskbarPanel(
            frame: frame,
            onActivate: { _ in },
            onClose: { _ in },
            onWindowCommand: { commands.append($0) })
        defer { panel.close() }

        update(panel, frame: frame, items: [first, second])
        panel.contentView?.layoutSubtreeIfNeeded()
        guard
            let secondButton = taskbarButtons(in: panel).first(where: {
                $0.itemID == second.id
            })
        else {
            Issue.record("second taskbar button was not rendered")
            return
        }
        let dragDestination = panel.contentView.flatMap { contentView in
            ([contentView] + allSubviews(of: contentView)).first {
                $0.registeredDraggedTypes.contains(.fileURL)
            }
        }
        #expect(dragDestination != nil)
        #expect(!(dragDestination is TaskbarButton))
        #expect(dragDestination?.registeredDraggedTypes.contains(.URL) == true)
        #expect(dragDestination?.registeredDraggedTypes.contains(.string) == true)

        secondButton.beginDragHover(sequenceNumber: 41)
        secondButton.activatePendingDragHover(sequenceNumber: 41)
        #expect(commands == [.activate(second)])

        secondButton.beginDragHover(sequenceNumber: 41)
        secondButton.activatePendingDragHover(sequenceNumber: 41)
        #expect(commands == [.activate(second)])

        secondButton.beginDragHover(sequenceNumber: 42)
        secondButton.cancelDragHover()
        secondButton.activatePendingDragHover(sequenceNumber: 42)
        #expect(commands == [.activate(second)])

        secondButton.beginDragHover(sequenceNumber: 42)
        secondButton.activatePendingDragHover(sequenceNumber: 42)
        #expect(commands == [.activate(second), .activate(second)])
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

    @Test("application indicators decorate one stable button without reflow")
    @MainActor
    func applicationIndicatorsDoNotReflowTaskbar() {
        let frame = NSRect(x: 0, y: 0, width: 700, height: TaskbarPanelLayout.defaultHeight)
        let panel = TaskbarPanel(frame: frame, onActivate: { _ in }, onClose: { _ in })
        defer { panel.close() }

        let first = makeTaskbarItem(
            id: "first", applicationIdentity: "com.example.shared", pid: 77)
        let second = makeTaskbarItem(
            id: "second", applicationIdentity: "com.example.shared", pid: 77)
        update(panel, frame: frame, items: [first, second])
        panel.contentView?.layoutSubtreeIfNeeded()
        let initialFrames = Dictionary(
            uniqueKeysWithValues: taskbarButtons(in: panel).map { ($0.itemID, $0.frame) })

        panel.updateIndicators(
            ApplicationIndicatorSnapshot(
                attentionPIDs: [77],
                badgesByApplicationIdentity: ["com.example.shared": "12345"]))
        panel.contentView?.layoutSubtreeIfNeeded()
        let buttons = Dictionary(
            uniqueKeysWithValues: taskbarButtons(in: panel).map { ($0.itemID, $0) })

        #expect(buttons["first"]?.presentsApplicationAttention == true)
        #expect(buttons["first"]?.presentedBadge == "123…")
        #expect(buttons["first"]?.accessibilityLabel()?.contains("badge 12345") == true)
        #expect(buttons["second"]?.presentsApplicationAttention == false)
        #expect(buttons["second"]?.presentedBadge == nil)
        #expect(
            Dictionary(uniqueKeysWithValues: buttons.map { ($0.key, $0.value.frame) })
                == initialFrames)

        panel.updateIndicators(.empty)
        #expect(buttons["first"]?.presentsApplicationAttention == false)
        #expect(buttons["first"]?.presentedBadge == nil)
    }

    @Test("attention treatment is conspicuous without changing geometry")
    func applicationAttentionAppearance() {
        #expect(TaskbarAttentionAppearance.borderWidth >= 2)
        #expect(TaskbarAttentionAppearance.borderAlpha >= 0.9)
        #expect(TaskbarAttentionAppearance.fillAlpha >= 0.2)
        #expect(TaskbarAttentionAppearance.pulseMinimumOpacity >= 0.5)
        #expect(TaskbarAttentionAppearance.pulseDuration <= 0.65)
    }

    @Test("application indicator fixtures render from the production panel")
    @MainActor
    func applicationIndicatorFixturesRender() throws {
        let directoryURL = ProcessInfo.processInfo.environment[
            "TINYTASKBAR_RENDER_FIXTURES_DIR"
        ].map { URL(fileURLWithPath: $0, isDirectory: true) }
        if let directoryURL {
            try FileManager.default.createDirectory(
                at: directoryURL, withIntermediateDirectories: true)
        }

        try renderApplicationIndicatorFixture(
            frame: NSRect(x: 0, y: 0, width: 280, height: 26),
            to: directoryURL?.appendingPathComponent("indicators-compact.png"))
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
        #expect(buttonFrame.minX == TaskbarPanelLayout.contentLeadingInset)
        #expect(buttonFrame.minY >= contentView.bounds.minY)
        #expect(buttonFrame.maxY <= separator.frame.minY)
        #expect(separator.frame.isFiniteGeometry)
        #expect(separator.frame.minX == contentView.bounds.minX)
        #expect(separator.frame.width == contentView.bounds.width)
        #expect(separator.frame.maxY == contentView.bounds.maxY)
        #expect(separator.frame.height == TaskbarPanelLayout.topSeparatorHeight)
        #expect(separator.layer?.backgroundColor != nil)
        let visualBounds = TaskbarPanelLayout.visualBounds(in: contentView.bounds)
        let topGap = separator.frame.minY - buttonFrame.maxY
        let bottomGap = buttonFrame.minY - visualBounds.minY
        #expect(topGap == TaskbarPanelLayout.contentVerticalInset)
        #expect(bottomGap == TaskbarPanelLayout.contentVerticalInset)
        #expect(topGap == bottomGap)
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
        let iconOnlyImageFrame = cell.positionedImageFrame(original, imageOnly: true)
        let labeledImageFrame = cell.positionedImageFrame(original, imageOnly: false)
        let titleFrame = cell.insetTitleFrame(original)

        #expect(imageFrame.minX == original.minX + TaskbarButtonCell.contentLeadingInset)
        #expect(imageFrame.size == original.size)
        #expect(iconOnlyImageFrame == original)
        #expect(labeledImageFrame == imageFrame)
        #expect(titleFrame.minX == original.minX + TaskbarButtonCell.contentLeadingInset)
        #expect(titleFrame.maxX == original.maxX)
        #expect(titleFrame.minY == original.minY)
        #expect(titleFrame.height == original.height)
    }

    @Test("notification badge stays inside the button and overlaps the icon corner")
    @MainActor
    func notificationBadgeAnchorsToIconCorner() {
        let bounds = NSRect(x: 0, y: 0, width: 180, height: 27)
        let imageFrame = NSRect(x: 5, y: 5, width: 18, height: 18)
        let badgeFrame = TaskbarBadgeAppearance.frame(
            textSize: NSSize(width: 6, height: 9),
            imageFrame: imageFrame,
            controlBounds: bounds,
            coordinateSystemIsFlipped: false)
        let flippedBadgeFrame = TaskbarBadgeAppearance.frame(
            textSize: NSSize(width: 6, height: 9),
            imageFrame: imageFrame,
            controlBounds: bounds,
            coordinateSystemIsFlipped: true)
        let longBadgeFrame = TaskbarBadgeAppearance.frame(
            textSize: NSSize(width: 20, height: 9),
            imageFrame: imageFrame,
            controlBounds: bounds,
            coordinateSystemIsFlipped: true)

        #expect(bounds.contains(badgeFrame))
        #expect(badgeFrame.midX > imageFrame.midX)
        #expect(badgeFrame.midY > imageFrame.midY)
        #expect(badgeFrame.intersects(imageFrame))
        #expect(bounds.contains(flippedBadgeFrame))
        #expect(flippedBadgeFrame.midX > imageFrame.midX)
        #expect(flippedBadgeFrame.midY < imageFrame.midY)
        #expect(flippedBadgeFrame.intersects(imageFrame))
        #expect(longBadgeFrame.maxX <= imageFrame.maxX + 4)
        #expect(longBadgeFrame.intersects(imageFrame))
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

    @Test("taskbar owns the window resize seam without moving its content")
    @MainActor
    func taskbarRestoresArrowCursor() {
        let frame = NSRect(x: 0, y: 0, width: 700, height: TaskbarPanelLayout.defaultHeight)
        let panel = TaskbarPanel(frame: frame, onActivate: { _ in }, onClose: { _ in })
        defer {
            NSCursor.arrow.set()
            panel.close()
        }
        panel.update(frame: frame, items: [])
        panel.contentView?.layoutSubtreeIfNeeded()

        guard
            let event = NSEvent.mouseEvent(
                with: .mouseMoved,
                location: NSPoint(x: frame.maxX - 1, y: frame.maxY - 1),
                modifierFlags: [],
                timestamp: 0,
                windowNumber: panel.windowNumber,
                context: nil,
                eventNumber: 1,
                clickCount: 0,
                pressure: 0)
        else {
            Issue.record("taskbar cursor update fixture could not be created")
            return
        }

        guard let contentView = panel.contentView,
            let separator = allSubviews(of: contentView).first(where: {
                $0.identifier?.rawValue == TaskbarPanelLayout.topSeparatorIdentifier
            })
        else {
            Issue.record("taskbar seam fixture was not rendered")
            return
        }

        let interactionFrame = TaskbarPanelLayout.interactionFrame(for: frame)
        let shieldPoint = NSPoint(
            x: contentView.bounds.midX,
            y: contentView.bounds.maxY - TaskbarPanelLayout.cursorSeamOverlap / 2)
        #expect(panel.frame == interactionFrame)
        #expect(panel.isOpaque)
        #expect(panel.backgroundColor == .windowBackgroundColor)
        #expect(separator.frame.minY == TaskbarPanelLayout.defaultHeight)
        #expect(separator.frame.maxY == contentView.bounds.maxY)
        #expect(separator.frame.contains(shieldPoint))
        #expect(contentView.hitTest(shieldPoint) === contentView)
        #expect(panel.acceptsMouseMovedEvents)
        NSCursor.resizeUpDown.set()
        panel.sendEvent(event)
        #expect(NSCursor.current === NSCursor.arrow)
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

    @Test("preferences default and persisted state transitions")
    @MainActor
    func preferencesPersist() {
        let suiteName = "TinyTaskbarTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = TinyTaskbarPreferencesStore(defaults: defaults)
        #expect(store.values == .defaults)

        store.setOnboardingComplete(true)
        store.setHideMacDock(true)

        let reloaded = TinyTaskbarPreferencesStore(defaults: defaults)
        var expected = TinyTaskbarPreferences.defaults
        expected.onboardingComplete = true
        expected.hideMacDock = true
        #expect(reloaded.values == expected)
    }

    @Test("taskbar title and accessibility label include window identity")
    func windowTitlePreservesAccessibilityLabel() {
        let item = TaskbarItem(
            id: "window",
            pid: 10,
            applicationName: "Editor",
            title: "Project.swift",
            displayIdentifier: "main",
            cgWindowNumber: nil,
            isActive: false
        )

        #expect(item.displayTitle == "Project.swift")
        #expect(item.accessibilityLabel == "Editor, Project.swift")
    }

    @Test("application icons fall back to the bundle path without caching a placeholder")
    func applicationIconSourceFallback() {
        var requestedPaths: [String] = []
        let iconForFile: (String) -> String = { path in
            requestedPaths.append(path)
            return "bundle-icon"
        }

        #expect(
            ApplicationIconSourceResolver.resolve(
                runningApplicationIcon: "running-icon",
                applicationBundlePath: "/Applications/Google Chrome.app",
                iconForFile: iconForFile
            ) == "running-icon")
        #expect(requestedPaths.isEmpty)
        #expect(
            ApplicationIconSourceResolver.resolve(
                runningApplicationIcon: nil,
                applicationBundlePath: "/Applications/Google Chrome.app",
                iconForFile: iconForFile
            ) == "bundle-icon")
        #expect(requestedPaths == ["/Applications/Google Chrome.app"])
    }

    @Test("hover card preserves the full title and application identity")
    @MainActor
    func hoverCardShowsFullTitle() {
        let title = String(repeating: "A very long document title ", count: 12)
        let icon = NSImage(systemSymbolName: "doc", accessibilityDescription: nil)
        var didCloseWindow = false
        let controller = TaskbarHoverCardViewController(
            applicationName: "Editor",
            title: title,
            icon: icon,
            onCloseWindow: { didCloseWindow = true }
        )
        controller.loadView()

        #expect(controller.titleLabel.stringValue == title)
        #expect(controller.titleLabel.maximumNumberOfLines == 0)
        #expect(controller.titleLabel.lineBreakMode == .byCharWrapping)
        #expect(controller.applicationLabel.stringValue == "Editor")
        #expect(!controller.applicationLabel.isHidden)
        #expect((controller.iconView as? NSImageView)?.image != nil)
        #expect(
            controller.preferredContentSize.width
                <= TaskbarHoverCardViewController.padding * 2
                + TaskbarHoverCardViewController.iconSize
                + TaskbarHoverCardViewController.spacing
                + TaskbarHoverCardViewController.maximumTextWidth
                + TaskbarHoverCardViewController.closeControlWidth)
        #expect(controller.closeWindowButton?.image != nil)
        #expect(controller.closeWindowButton?.acceptsFirstMouse(for: nil) == true)
        #expect(controller.closeWindowButton?.accessibilityLabel() == "Close Editor window")
        if let closeWindowButton = controller.closeWindowButton {
            #expect(closeWindowButton.target === controller)
            #expect(
                closeWindowButton.action
                    == #selector(TaskbarHoverCardViewController.closeWindow))
        }
        controller.closeWindow()
        #expect(didCloseWindow)
        #expect(controller.preferredContentSize.height > 44)
    }

    @Test("hover card document proxy revalidates a copy-only file URL without reflow")
    @MainActor
    func hoverCardDocumentProxyIsCurrentAndCopyOnly() {
        let firstURL = URL(fileURLWithPath: "/tmp/first image.png")
        let currentURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("TinyTaskbarTests-\(UUID().uuidString).png")
        #expect(FileManager.default.createFile(atPath: currentURL.path, contents: Data()))
        defer { try? FileManager.default.removeItem(at: currentURL) }
        var requests = 0
        let proxyController = TaskbarHoverCardViewController(
            applicationName: "Preview",
            title: "current image.png",
            icon: nil,
            documentURL: {
                requests += 1
                return requests == 1 ? firstURL : currentURL
            })
        let ordinaryController = TaskbarHoverCardViewController(
            applicationName: "Preview",
            title: "current image.png",
            icon: nil)
        proxyController.loadView()
        ordinaryController.loadView()
        proxyController.view.layoutSubtreeIfNeeded()
        ordinaryController.view.layoutSubtreeIfNeeded()

        guard let proxyView = proxyController.documentProxyView,
            let pasteboardWriter = proxyView.pasteboardWriterForCurrentDocument()
        else {
            Issue.record("verified document proxy was not rendered")
            return
        }
        #expect(requests == 2)
        #expect(
            pasteboardWriter.string(forType: .fileURL).flatMap(URL.init(string:))
                == currentURL)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        #expect(pasteboard.writeObjects([pasteboardWriter]))
        let writtenURLs =
            pasteboard.readObjects(
                forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true]) as? [URL]
        #expect(writtenURLs == [currentURL])
        #expect(TaskbarDocumentProxyView.sourceOperationMask == .copy)
        #expect(TaskbarDocumentProxyView.ignoresModifierKeys)
        #expect(proxyController.iconView === proxyView)
        #expect(proxyController.preferredContentSize == ordinaryController.preferredContentSize)
        #expect(proxyView.frame.size == ordinaryController.iconView.frame.size)
        #expect(proxyView.frame.size == NSSize(width: 24, height: 24))
        let proxyCenter = proxyController.view.convert(
            NSPoint(x: proxyView.bounds.midX, y: proxyView.bounds.midY),
            from: proxyView)
        #expect(proxyController.view.hitTest(proxyCenter) === proxyView)

        let mouseDown = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1)
        let mouseDragged = NSEvent.mouseEvent(
            with: .leftMouseDragged,
            location: NSPoint(x: 8, y: 8),
            modifierFlags: [],
            timestamp: 0.1,
            windowNumber: 0,
            context: nil,
            eventNumber: 2,
            clickCount: 1,
            pressure: 1)
        var initiatingEvent: NSEvent?
        var draggedURL: URL?
        var dragStates: [Bool] = []
        let eventProxy = TaskbarDocumentProxyView(
            image: NSImage(size: NSSize(width: 24, height: 24)),
            documentURL: { currentURL },
            onDragStateChanged: { dragStates.append($0) },
            dragSessionStarter: { _, items, event, _ in
                initiatingEvent = event
                draggedURL = (items.first?.item as? NSPasteboardItem)?
                    .string(forType: .fileURL)
                    .flatMap(URL.init(string:))
            })
        eventProxy.frame.size = NSSize(width: 24, height: 24)
        guard let mouseDown, let mouseDragged else {
            Issue.record("could not construct document drag events")
            return
        }
        eventProxy.mouseDown(with: mouseDown)
        eventProxy.mouseDragged(with: mouseDragged)
        #expect(initiatingEvent === mouseDown)
        #expect(initiatingEvent?.type == .leftMouseDown)
        #expect(draggedURL == currentURL)
        #expect(dragStates == [true])

        let unsupportedController = TaskbarHoverCardViewController(
            applicationName: "Preview",
            title: "Unsaved",
            icon: nil,
            documentURL: { nil })
        unsupportedController.loadView()
        #expect(unsupportedController.documentProxyView == nil)
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
        var documentURLRequests = 0
        let controller = TaskbarHoverCardViewController(
            applicationName: "Terminal",
            title: "Alpha project",
            icon: nil,
            documentURL: {
                documentURLRequests += 1
                return URL(fileURLWithPath: "/tmp/unsupported-tab-group.txt")
            },
            tabs: tabs,
            onSelectTab: { selectedTab = $0 },
            onCloseTab: { closedTab = $0 }
        )
        controller.loadView()

        #expect(controller.tabButtons.map(\.title) == tabs.map(\.title))
        #expect(controller.tabButtons.allSatisfy { $0.image == nil })
        #expect(controller.tabButtons[0].layer?.borderWidth == 1)
        #expect(controller.tabButtons[1].layer?.borderWidth == 0)
        #expect(controller.tabCloseButtons.count == tabs.count)
        #expect(controller.tabCloseButtons.allSatisfy { $0.acceptsFirstMouse(for: nil) })
        #expect(controller.closeWindowButton == nil)
        #expect(controller.documentProxyView == nil)
        #expect(documentURLRequests == 0)
        #expect(controller.applicationLabel.stringValue == "Terminal")
        #expect(controller.titleLabel.stringValue == "3 Tabs")
        #expect(controller.preferredContentSize.height > 100)
        #expect(controller.view is TaskbarHoverCardView)
        controller.tabButtons[1].performClick(nil)
        #expect(selectedTab == tabs[1])
        controller.tabCloseButtons[2].performClick(nil)
        #expect(closedTab == tabs[2])
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

    @Test("prepared window activation performs one application ordering transition")
    func windowActivationOrder() {
        #expect(
            WindowActivationSequence.preparationSteps == [
                .unminimize,
                .makeMain,
                .makeFocusedWindow,
            ])
        #expect(
            WindowActivationSequence.completionSteps(targetWasPrepared: true) == [
                .activateApplication
            ])
        #expect(
            WindowActivationSequence.completionSteps(targetWasPrepared: false) == [
                .activateApplication,
                .focus,
                .raise,
            ])
    }

    @Test("Application menu matching accepts unique Command-N family and Command-T shortcuts")
    func newWindowMenuCommandMatching() {
        let commandN = ApplicationMenuItemDescriptor(
            title: "Nouveau document", commandCharacter: "n", commandModifiers: 0,
            isEnabled: true, actions: [kAXPressAction])
        let commandT = ApplicationMenuItemDescriptor(
            title: "Neuer Tab", commandCharacter: "T", commandModifiers: 0,
            isEnabled: true, actions: [kAXPressAction])
        let shifted = ApplicationMenuItemDescriptor(
            title: "New Window", commandCharacter: "N",
            commandModifiers: AXMenuItemModifiers.shift.rawValue,
            isEnabled: true, actions: [kAXPressAction])
        let disabled = ApplicationMenuItemDescriptor(
            title: "New Window", commandCharacter: "n", commandModifiers: 0,
            isEnabled: false, actions: [kAXPressAction])
        let wrongAction = ApplicationMenuItemDescriptor(
            title: "New Window", commandCharacter: "n", commandModifiers: 0,
            isEnabled: true, actions: [])
        let wrongShortcut = ApplicationMenuItemDescriptor(
            title: "Open", commandCharacter: "o", commandModifiers: 0,
            isEnabled: true, actions: [kAXPressAction])
        let noCommand = ApplicationMenuItemDescriptor(
            title: "New Window", commandCharacter: "n",
            commandModifiers: AXMenuItemModifiers.noCommand.rawValue,
            isEnabled: true, actions: [kAXPressAction])

        #expect(
            ApplicationMenuCommandMatcher.command(for: commandN)
                == ApplicationMenuCommand(
                    title: "Nouveau document", commandCharacter: "n", commandModifiers: 0))
        #expect(
            ApplicationMenuCommandMatcher.command(for: commandT)
                == ApplicationMenuCommand(
                    title: "Neuer Tab", commandCharacter: "t", commandModifiers: 0))
        #expect(
            ApplicationMenuCommandMatcher.command(for: shifted)
                == ApplicationMenuCommand(
                    title: "New Window", commandCharacter: "n",
                    commandModifiers: AXMenuItemModifiers.shift.rawValue))
        #expect(ApplicationMenuCommandMatcher.command(for: disabled) == nil)
        #expect(ApplicationMenuCommandMatcher.command(for: wrongAction) == nil)
        #expect(ApplicationMenuCommandMatcher.command(for: wrongShortcut) == nil)
        #expect(ApplicationMenuCommandMatcher.command(for: noCommand) == nil)
        #expect(
            ApplicationMenuCommandMatcher.uniqueCommands(in: [commandT, commandN]) == [
                ApplicationMenuCommand(
                    title: "Nouveau document", commandCharacter: "n", commandModifiers: 0),
                ApplicationMenuCommand(
                    title: "Neuer Tab", commandCharacter: "t", commandModifiers: 0),
            ])
        #expect(
            ApplicationMenuCommandMatcher.uniqueCommands(in: [commandN, commandN, commandT]) == [
                ApplicationMenuCommand(
                    title: "Neuer Tab", commandCharacter: "t", commandModifiers: 0)
            ])
        #expect(
            ApplicationMenuCommandMatcher.uniqueCommands(in: [commandT, shifted, commandN]) == [
                ApplicationMenuCommand(
                    title: "Nouveau document", commandCharacter: "n", commandModifiers: 0),
                ApplicationMenuCommand(
                    title: "New Window", commandCharacter: "n",
                    commandModifiers: AXMenuItemModifiers.shift.rawValue),
                ApplicationMenuCommand(
                    title: "Neuer Tab", commandCharacter: "t", commandModifiers: 0),
            ])
    }

    @Test("Application menu matching stops at the first leftmost command branch")
    func applicationMenuBranchMatching() {
        let commandN = ApplicationMenuItemDescriptor(
            title: "New Window", commandCharacter: "n", commandModifiers: 0,
            isEnabled: true, actions: [kAXPressAction])
        let commandT = ApplicationMenuItemDescriptor(
            title: "New Tab", commandCharacter: "t", commandModifiers: 0,
            isEnabled: true, actions: [kAXPressAction])
        let laterDuplicate = ApplicationMenuItemDescriptor(
            title: "Large later menu", commandCharacter: "n", commandModifiers: 0,
            isEnabled: true, actions: [kAXPressAction])

        #expect(
            ApplicationMenuCommandMatcher.firstUniqueCommands(
                in: [
                    [],
                    [commandN, commandT],
                    [laterDuplicate],
                ],
                descriptors: { $0 }) == [
                    ApplicationMenuCommand(
                        title: "New Window", commandCharacter: "n", commandModifiers: 0),
                    ApplicationMenuCommand(
                        title: "New Tab", commandCharacter: "t", commandModifiers: 0),
                ])
    }

    @Test("actionable references survive only exact live physical identity gaps")
    func actionableReferenceContinuity() {
        let resolved = ActionableReferenceContinuity.resolve(
            current: ["current": 20, "replacement": 30],
            previous: ["retained": 10, "replacement": 11, "closed": 12, "ambiguous": 13],
            liveKeys: ["current", "retained", "replacement", "ambiguous"],
            ambiguousKeys: ["ambiguous"])

        #expect(resolved == ["current": 20, "retained": 10, "replacement": 30])
    }

    @Test("AX refresh planning reads only dirty and newly launched applications")
    func axApplicationRefreshPlanning() {
        let targeted = AXApplicationRefreshPlan.resolve(
            runningApplicationPIDs: [1, 2, 3],
            cachedApplicationPIDs: [1, 2],
            dirtyApplicationPIDs: [2, 99],
            refreshAll: false
        )
        let complete = AXApplicationRefreshPlan.resolve(
            runningApplicationPIDs: [1, 2, 3],
            cachedApplicationPIDs: [1, 2, 3],
            dirtyApplicationPIDs: [],
            refreshAll: true
        )
        let unchanged = AXApplicationRefreshPlan.resolve(
            runningApplicationPIDs: [1, 2, 3],
            cachedApplicationPIDs: [1, 2, 3],
            dirtyApplicationPIDs: [],
            refreshAll: false
        )
        let retry = AXApplicationRefreshPlan.remainingDirtyApplicationPIDs(
            current: [2],
            attempted: [2, 3],
            successfullyRead: [3],
            running: [1, 2, 3]
        )

        #expect(targeted.applicationPIDs == [2, 3])
        #expect(complete.applicationPIDs == [1, 2, 3])
        #expect(unchanged.applicationPIDs.isEmpty)
        #expect(retry == [2])
    }

    @Test("cached AX identities survive snapshots that reuse an application")
    func retainedAXApplicationIdentity() {
        var registry = WindowElementIdentityRegistry<Int>(elementsEqual: ==)
        registry.beginSnapshot()
        let original = registry.identifier(for: 42, namespace: "123")
        registry.endSnapshot()

        registry.beginSnapshot()
        registry.retain(namespace: "123")
        registry.endSnapshot()
        registry.beginSnapshot()
        registry.retain(namespace: "123")
        registry.endSnapshot()
        registry.beginSnapshot()
        let reused = registry.identifier(for: 42, namespace: "123")
        registry.endSnapshot()

        #expect(reused == original)
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

    @Test("Fullscreen capability distinguishes exposed, read-only, and inconclusive attributes")
    func fullscreenCapabilityRequiresSuccessfulBooleanRead() {
        #expect(
            AXFullscreenCapabilityResolver.resolve(
                readError: .success,
                value: false,
                settableError: .success,
                isSettable: true)
                == WindowFullscreenCapability(isFullscreen: false, isSettable: true))
        #expect(
            AXFullscreenCapabilityResolver.resolve(
                readError: .success,
                value: true,
                settableError: .cannotComplete,
                isSettable: true)
                == WindowFullscreenCapability(isFullscreen: true, isSettable: false))
        #expect(
            AXFullscreenCapabilityResolver.resolve(
                readError: .attributeUnsupported,
                value: false,
                settableError: .success,
                isSettable: true) == nil)
        #expect(
            AXFullscreenCapabilityResolver.resolve(
                readError: .success,
                value: nil,
                settableError: .success,
                isSettable: true) == nil)
    }

    @Test("document proxy accepts only verified existing local file URLs")
    func documentURLCapabilityFiltering() {
        let expectedPath = "/tmp/Saved Image.png"
        let existingFile: (String) -> Bool = { $0 == expectedPath }
        let direct = AXDocumentURLResolver.verifiedLocalFileURL(
            from: "file:///tmp/Saved%20Image.png",
            fileExists: existingFile)
        let localhost = AXDocumentURLResolver.verifiedLocalFileURL(
            from: "file://localhost/tmp/Saved%20Image.png",
            fileExists: existingFile)

        #expect(direct?.path == expectedPath)
        #expect(localhost?.path == expectedPath)
        #expect(
            AXDocumentURLResolver.verifiedLocalFileURL(
                from: "file:///tmp/Missing.png",
                fileExists: { _ in false }) == nil)
        for unsupported in [
            nil,
            "",
            " file:///tmp/Saved%20Image.png",
            "https://example.com/Saved%20Image.png",
            "file://fileserver/tmp/Saved%20Image.png",
            "file:Saved%20Image.png",
            "file:///tmp/Saved%20Image.png?version=2",
            "file:///tmp/Saved%20Image.png#page=1",
        ] as [String?] {
            #expect(
                AXDocumentURLResolver.verifiedLocalFileURL(
                    from: unsupported,
                    fileExists: existingFile) == nil)
        }
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
        #expect(TaskbarHoverPresenter.interactivePollDelay == .milliseconds(80))
        let corridor = TaskbarHoverPresenter.interactionCorridor(
            anchorFrame: NSRect(x: 100, y: 0, width: 120, height: 30),
            popoverFrame: NSRect(x: 80, y: 36, width: 200, height: 180))
        #expect(corridor.contains(NSPoint(x: 160, y: 33)))
        #expect(corridor.contains(NSPoint(x: 270, y: 200)))
        #expect(!corridor.contains(NSPoint(x: 300, y: 33)))
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

    @Test("Application menu capability and execution stay scoped to the selected application")
    @MainActor
    func applicationMenuCommandUsesCurrentItem() {
        let provider = MockWindowSnapshotProvider(snapshot: makeFixtureSnapshot())
        let menuCommand = ApplicationMenuCommand(
            title: "New Fixture Window", commandCharacter: "n",
            commandModifiers: AXMenuItemModifiers.shift.rawValue)
        provider.applicationMenuCommandsValue = [menuCommand]
        let store = TaskbarStore(provider: provider)
        defer { store.stop() }
        store.start(accessibilityTrusted: true)
        store.refreshNow()
        guard let item = store.state.itemsByDisplay["main"]?.first else {
            Issue.record("fixture item was not projected")
            return
        }

        #expect(store.applicationMenuCommands(for: item) == [menuCommand])
        store.execute(.performMenuCommand(item, menuCommand))

        #expect(provider.applicationMenuCommandItemIDs == [item.id])
        #expect(provider.performedApplicationMenuCommands.map(\.itemID) == [item.id])
        #expect(provider.performedApplicationMenuCommands.map(\.command) == [menuCommand])
    }

    @Test("Fullscreen capability and execution stay scoped to the current exact item")
    @MainActor
    func fullscreenCommandUsesCurrentItem() {
        let provider = MockWindowSnapshotProvider(snapshot: makeFixtureSnapshot())
        provider.fullscreenCapabilityValue = WindowFullscreenCapability(
            isFullscreen: false, isSettable: true)
        let store = TaskbarStore(provider: provider)
        defer { store.stop() }
        store.start(accessibilityTrusted: true)
        store.refreshNow()
        guard let item = store.state.itemsByDisplay["main"]?.first else {
            Issue.record("fixture item was not projected")
            return
        }

        #expect(
            store.fullscreenCapability(for: item)
                == WindowFullscreenCapability(isFullscreen: false, isSettable: true))
        store.execute(.setFullscreen(item, true))

        #expect(provider.fullscreenCapabilityItemIDs == [item.id])
        #expect(provider.fullscreenUpdates.map(\.itemID) == [item.id])
        #expect(provider.fullscreenUpdates.map(\.fullscreen) == [true])
    }

    @Test("document capability follows current exact identity and rejects stale absence")
    @MainActor
    func documentURLUsesCurrentExactItem() {
        let provider = MockWindowSnapshotProvider(
            snapshot: identitySnapshot(stableKey: "old-identity"))
        let documentURL = URL(fileURLWithPath: "/tmp/current-document.png")
        provider.documentURLValue = documentURL
        let store = TaskbarStore(provider: provider)
        defer { store.stop() }
        store.start(accessibilityTrusted: true)
        store.refreshNow()
        guard let oldItem = store.state.itemsByDisplay["main"]?.first else {
            Issue.record("old fixture identity was not projected")
            return
        }

        provider.snapshotValue = identitySnapshot(stableKey: "new-identity")
        store.refreshNow()
        #expect(store.documentURL(for: oldItem) == documentURL)
        #expect(provider.documentURLItemIDs == ["new-identity"])

        provider.snapshotValue = RawWindowSnapshot(
            candidates: [],
            cgWindows: [],
            displays: [fixtureDisplay],
            frontmostPID: nil,
            evidence: WindowSnapshotEvidence(
                isComplete: true,
                knownApplicationPIDs: [fixturePID],
                axWindowListReadPIDs: [fixturePID],
                observedAXWindowIDs: []))
        store.refreshNow()
        #expect(store.documentURL(for: oldItem) == nil)
        #expect(provider.documentURLItemIDs == ["new-identity"])
    }

    @Test("standard titled presentation remains vertically contained")
    @MainActor
    func standardTitleGeometry() {
        let frame = NSRect(
            x: 0, y: 0, width: 500, height: TaskbarAppearance.panelHeight)
        let item = makeTaskbarItem(id: "standard")
        let panel = TaskbarPanel(frame: frame, onActivate: { _ in }, onClose: { _ in })
        defer { panel.close() }
        panel.update(frame: frame, items: [item])
        panel.contentView?.layoutSubtreeIfNeeded()
        guard let contentView = panel.contentView,
            let button = taskbarButtons(in: panel).first,
            let scrollView = allSubviews(of: contentView).compactMap({ $0 as? NSScrollView }).first
        else {
            Issue.record("standard presentation was not rendered")
            return
        }
        let buttonFrame = contentView.convert(button.bounds, from: button)
        #expect(button.title == item.displayTitle)
        #expect(button.heightConstraint?.constant == TaskbarAppearance.buttonHeight)
        #expect(button.frame.height == TaskbarAppearance.buttonHeight)
        #expect(button.accessibilityLabel() == item.accessibilityLabel)
        #expect(buttonFrame.minY >= contentView.bounds.minY)
        #expect(buttonFrame.maxY <= contentView.bounds.maxY)
        #expect(
            abs(buttonFrame.minX - TaskbarPanelLayout.contentLeadingInset) < 0.5)
        #expect(scrollView.hasHorizontalScroller == false)
        #expect(scrollView.horizontalScroller == nil)
    }

    @Test("window-title presentation survives a retained-window refresh")
    @MainActor
    func windowTitlePresentationSurvivesRefresh() {
        let frame = NSRect(x: 0, y: 0, width: 500, height: 26)
        let initial = makeTaskbarItem(id: "icon-refresh", title: "Initial")
        let panel = TaskbarPanel(frame: frame, onActivate: { _ in }, onClose: { _ in })
        defer { panel.close() }
        panel.update(frame: frame, items: [initial])
        panel.contentView?.layoutSubtreeIfNeeded()
        guard let button = taskbarButtons(in: panel).first else {
            Issue.record("window-title button was not rendered")
            return
        }
        #expect(button.title == "Initial")
        #expect(button.imagePosition == .imageLeading)
        #expect(button.alignment == .left)

        let refreshed = makeTaskbarItem(
            id: "icon-refresh", title: "Updated", isActive: true)
        panel.update(frame: frame, items: [refreshed])

        #expect(button.title == "Updated")
        #expect(button.imagePosition == .imageLeading)
        #expect(button.alignment == .left)
    }

    @Test("taskbar shrinks labels before scrolling")
    @MainActor
    func taskbarOverflowPresentation() {
        let items = (0..<5).map { makeTaskbarItem(id: "overflow-\($0)") }
        let panel = TaskbarPanel(
            frame: NSRect(x: 0, y: 0, width: 700, height: 26),
            onActivate: { _ in },
            onClose: { _ in })
        defer { panel.close() }
        panel.update(
            frame: NSRect(x: 0, y: 0, width: 700, height: 26),
            items: items)
        panel.contentView?.layoutSubtreeIfNeeded()
        var buttons = taskbarButtons(in: panel)
        let roomyScrollView = allSubviews(of: panel.contentView!).compactMap { $0 as? NSScrollView }
            .first
        #expect(buttons.count == 5)
        #expect(buttons.allSatisfy { $0.frame.width <= 168 && $0.frame.width >= 102 })
        #expect(
            (roomyScrollView?.documentView?.frame.width ?? .greatestFiniteMagnitude)
                <= (roomyScrollView?.contentView.bounds.width ?? 0) + 1)

        let narrowFrame = NSRect(x: 0, y: 0, width: 480, height: 26)
        panel.update(
            frame: narrowFrame,
            items: items)
        panel.contentView?.layoutSubtreeIfNeeded()
        buttons = taskbarButtons(in: panel)
        let scrollingView = allSubviews(of: panel.contentView!).compactMap { $0 as? NSScrollView }
            .first
        #expect(buttons.allSatisfy { abs($0.frame.width - 102) <= 1 })
        #expect(
            (scrollingView?.documentView?.frame.width ?? 0)
                > (scrollingView?.contentView.bounds.width ?? .greatestFiniteMagnitude))
        #expect(buttons.allSatisfy { !$0.title.isEmpty })
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
        // Rendering an unchanged taskbar must not immediately repeat the AX write.
        store.setTaskbarWorkAreaHeights(["main": 30])
        #expect(provider.heightUpdates.count == 1)

        // A later verification snapshot still retries if another window manager
        // overwrote the change before the applied frame was observed.
        store.refreshNow()
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

    @Test("publishing a refresh applies each work-area correction once")
    @MainActor
    func publishedRefreshAppliesWorkAreaOnce() {
        let display = DisplayDescriptor(
            identifier: "main",
            frame: CGRect(x: 0, y: 0, width: 1_440, height: 900),
            appKitFrame: CGRect(x: 0, y: 0, width: 1_440, height: 900),
            appKitVisibleFrame: CGRect(x: 80, y: 50, width: 1_360, height: 825))
        let frame = TaskbarPanelLayout.nativeWindowWorkArea(for: display)
        let candidate = WindowCandidate(
            stableKey: "maximized-window",
            pid: fixturePID,
            applicationName: "Fixture",
            title: "Maximized",
            frame: frame,
            isFocused: true,
            isMain: true)
        let provider = MockWindowSnapshotProvider(
            snapshot: RawWindowSnapshot(
                candidates: [candidate],
                cgWindows: [
                    CGWindowMetadata(
                        windowNumber: 88,
                        ownerPID: fixturePID,
                        bounds: frame,
                        title: candidate.title)
                ],
                displays: [display],
                frontmostPID: fixturePID))
        let store = TaskbarStore(provider: provider)
        store.onStateChange = { [weak store] _ in
            store?.setTaskbarWorkAreaHeights(["main": 30])
        }
        store.start(accessibilityTrusted: true)
        store.refreshNow()
        defer { store.stop() }

        #expect(provider.heightUpdates.count == 1)
    }

    @Test("hiding one display taskbar restores only that display's work area")
    @MainActor
    func perDisplayTaskbarHidingRestoresWorkArea() {
        let left = DisplayDescriptor(
            identifier: "left",
            frame: CGRect(x: 0, y: 0, width: 800, height: 600),
            appKitFrame: CGRect(x: 0, y: 0, width: 800, height: 600),
            appKitVisibleFrame: CGRect(x: 0, y: 30, width: 800, height: 570))
        let right = DisplayDescriptor(
            identifier: "right",
            frame: CGRect(x: 800, y: 0, width: 800, height: 600),
            appKitFrame: CGRect(x: 800, y: 0, width: 800, height: 600),
            appKitVisibleFrame: CGRect(x: 800, y: 30, width: 800, height: 570))
        let leftWorkArea = TaskbarPanelLayout.nativeWindowWorkArea(for: left)
        let rightWorkArea = TaskbarPanelLayout.nativeWindowWorkArea(for: right)

        func snapshot(leftFrame: CGRect, rightFrame: CGRect) -> RawWindowSnapshot {
            let leftWindow = WindowCandidate(
                stableKey: "left-window",
                pid: 10,
                applicationName: "Left",
                title: "Left",
                frame: leftFrame)
            let rightWindow = WindowCandidate(
                stableKey: "right-window",
                pid: 20,
                applicationName: "Right",
                title: "Right",
                frame: rightFrame)
            return RawWindowSnapshot(
                candidates: [leftWindow, rightWindow],
                cgWindows: [
                    CGWindowMetadata(
                        windowNumber: 10,
                        ownerPID: 10,
                        bounds: leftFrame,
                        title: leftWindow.title),
                    CGWindowMetadata(
                        windowNumber: 20,
                        ownerPID: 20,
                        bounds: rightFrame,
                        title: rightWindow.title),
                ],
                displays: [left, right],
                frontmostPID: 10)
        }

        let provider = MockWindowSnapshotProvider(
            snapshot: snapshot(leftFrame: leftWorkArea, rightFrame: rightWorkArea))
        let store = TaskbarStore(provider: provider)
        store.start(accessibilityTrusted: true)
        store.refreshNow()
        defer { store.stop() }

        store.setTaskbarWorkAreaHeights(["left": 30, "right": 30])
        #expect(provider.heightUpdates.count == 2)

        let constrainedLeft = CGRect(
            origin: leftWorkArea.origin,
            size: CGSize(width: leftWorkArea.width, height: 540))
        let constrainedRight = CGRect(
            origin: rightWorkArea.origin,
            size: CGSize(width: rightWorkArea.width, height: 540))
        provider.snapshotValue = snapshot(
            leftFrame: constrainedLeft,
            rightFrame: constrainedRight)
        store.refreshNow()

        store.setTaskbarWorkAreaHeights(["right": 30])
        #expect(provider.heightUpdates.count == 3)
        #expect(provider.heightUpdates.last?.itemID == "left-window")
        #expect(provider.heightUpdates.last?.height == leftWorkArea.height)
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

    @Test("noisy AX changes use a trailing debounce")
    @MainActor
    func deferredRefreshRequestsSettleBeforeSnapshot() async {
        let provider = MockWindowSnapshotProvider(snapshot: makeFixtureSnapshot())
        let store = TaskbarStore(provider: provider)
        defer { store.stop() }

        store.start(accessibilityTrusted: true)
        await waitForSnapshot(from: provider)
        let initialSnapshotCount = provider.snapshotCount

        store.requestRefresh(change: .deferred)
        try? await Task.sleep(for: .milliseconds(150))
        store.requestRefresh(change: .deferred)
        try? await Task.sleep(for: .milliseconds(150))
        #expect(provider.snapshotCount == initialSnapshotCount)

        try? await Task.sleep(for: .milliseconds(150))
        #expect(provider.snapshotCount == initialSnapshotCount + 1)
    }

    @Test("ordinary events preempt deferred refreshes")
    @MainActor
    func ordinaryRefreshPreemptsDeferredRefresh() async {
        let provider = MockWindowSnapshotProvider(snapshot: makeFixtureSnapshot())
        let store = TaskbarStore(provider: provider)
        defer { store.stop() }

        store.start(accessibilityTrusted: true)
        await waitForSnapshot(from: provider)
        let initialSnapshotCount = provider.snapshotCount

        store.requestRefresh(change: .deferred)
        store.requestRefresh()
        try? await Task.sleep(for: .milliseconds(100))

        #expect(provider.snapshotCount == initialSnapshotCount + 1)
    }

    @Test("destroyed-window confirmation rereads only the affected application")
    @MainActor
    func destroyedWindowConfirmationRereadsAffectedApplication() async {
        let provider = MockWindowSnapshotProvider(snapshot: makeFixtureSnapshot())
        let store = TaskbarStore(provider: provider)
        defer { store.stop() }

        store.start(accessibilityTrusted: true)
        await waitForSnapshot(from: provider)
        let initialSnapshotCount = provider.snapshotCount
        let closedSnapshot = RawWindowSnapshot(
            candidates: [],
            cgWindows: [],
            displays: [fixtureDisplay],
            frontmostPID: nil,
            evidence: WindowSnapshotEvidence(
                isComplete: true,
                knownApplicationPIDs: [fixturePID],
                axWindowListReadPIDs: [fixturePID]
            )
        )
        provider.onInvalidateApplication = { pid in
            guard pid == self.fixturePID, provider.invalidatedPIDs.count == 2 else { return }
            provider.snapshotValue = closedSnapshot
        }

        // The destruction callback invalidates once, but its immediate read can
        // still return the just-destroyed AX element. The delayed confirmation
        // must invalidate that PID again before trusting a second read.
        provider.invalidateApplication(fixturePID)
        provider.invalidateWindowServer()
        store.requestRefresh(change: .windowDestroyed)
        store.requestWindowMutationConfirmation(applicationPID: fixturePID)

        let clock = ContinuousClock()
        let immediateDeadline = clock.now.advanced(by: .milliseconds(250))
        while provider.snapshotCount < initialSnapshotCount + 1,
            clock.now < immediateDeadline
        {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(store.state.itemsByDisplay["main"]?.count == 1)

        let confirmationDeadline = clock.now.advanced(by: .seconds(1))
        while provider.snapshotCount < initialSnapshotCount + 2,
            clock.now < confirmationDeadline
        {
            try? await Task.sleep(for: .milliseconds(10))
        }

        #expect(provider.invalidatedPIDs == [fixturePID, fixturePID])
        #expect(provider.invalidateAllCount == 0)
        #expect(provider.invalidateWindowServerCount == 2)
        #expect(store.state.itemsByDisplay.isEmpty)
    }

    @Test("AX notification classes protect full refreshes from noisy streams")
    func axNotificationRefreshClassification() {
        #expect(WindowSnapshotChange.fromAXNotification("AXWindowMoved") == .deferred)
        #expect(WindowSnapshotChange.fromAXNotification("AXWindowResized") == .deferred)
        #expect(WindowSnapshotChange.fromAXNotification("AXTitleChanged") == .deferred)
        #expect(
            WindowSnapshotChange.fromAXNotification("AXFocusedWindowChanged") == .deferred)
        #expect(
            WindowSnapshotChange.fromAXNotification("AXUIElementDestroyed")
                == .windowDestroyed)
        #expect(
            WindowSnapshotChange.fromAXNotification("AXWindowCreated") == .ordinary)
        #expect(
            WindowSnapshotChange.invalidatesWindowServer(
                forAXNotification: "AXWindowMiniaturized"))
        #expect(
            WindowSnapshotChange.invalidatesWindowServer(
                forAXNotification: "AXFocusedWindowChanged"))
        #expect(
            !WindowSnapshotChange.invalidatesWindowServer(
                forAXNotification: "AXTitleChanged"))
    }

    @Test(
        "focus changes remove closed windows without a destruction event but preserve failed AX reads",
        arguments: ["AXFocusedWindowChanged", "AXMainWindowChanged"], [true, false]
    )
    @MainActor
    func focusChangeAfterWindowClose(notification: String, didReadWindowList: Bool) {
        let initial = makeFixtureSnapshot()
        let provider = MockWindowSnapshotProvider(snapshot: initial)
        let store = TaskbarStore(provider: provider)
        defer { store.stop() }
        store.start(accessibilityTrusted: true)
        store.refreshNow()
        #expect(store.state.itemsByDisplay["main"]?.count == 1)

        // The application stays running and AX omits the closed window. Without
        // invalidation, the cached on-screen CG record keeps its button alive.
        let invalidatesCG = WindowSnapshotChange.invalidatesWindowServer(
            forAXNotification: notification)
        provider.snapshotValue = RawWindowSnapshot(
            candidates: [],
            cgWindows: invalidatesCG ? [] : initial.cgWindows,
            displays: initial.displays,
            frontmostPID: fixturePID,
            evidence: WindowSnapshotEvidence(
                isComplete: true,
                knownApplicationPIDs: [fixturePID],
                axWindowListReadPIDs: didReadWindowList ? [fixturePID] : []
            )
        )
        store.refreshNow()

        #expect(store.state.itemsByDisplay.isEmpty == didReadWindowList)
    }

    @Test("active Space refresh republishes an unchanged state")
    @MainActor
    func activeSpaceRefreshRepublishesUnchangedState() async {
        let provider = MockWindowSnapshotProvider(snapshot: makeFixtureSnapshot())
        let store = TaskbarStore(provider: provider)
        defer { store.stop() }

        store.start(accessibilityTrusted: true)
        await waitForSnapshot(from: provider)
        let initialSnapshotCount = provider.snapshotCount
        var publicationCount = 0
        store.onStateChange = { _ in publicationCount += 1 }

        store.requestRefresh(cause: .activeSpaceChanged)
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while provider.snapshotCount == initialSnapshotCount, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }

        #expect(provider.snapshotCount == initialSnapshotCount + 1)
        #expect(publicationCount == 1)
        #expect(provider.invalidateAllCount == 1)
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

        store.performPrimaryClick(item)
        #expect(provider.minimizeCount == 1)

        // The button still says active, but the system snapshot has moved focus.
        // The click must activate, not minimize based on stale presentation state.
        provider.snapshotValue = makeFixtureSnapshot(isActive: false)
        store.performPrimaryClick(item)
        #expect(provider.activationCount == 1)

        guard let inactiveItem = store.state.itemsByDisplay["main"]?.first else {
            Issue.record("inactive fixture item was not projected")
            return
        }
        #expect(!inactiveItem.isActive)

        // The inverse race must also toggle from the fresh system focus.
        provider.snapshotValue = makeFixtureSnapshot()
        store.performPrimaryClick(inactiveItem)
        #expect(provider.minimizeCount == 2)

        store.execute(.close(item))
        #expect(provider.closeCount == 1)

        store.setAccessibilityAvailable(false)
        store.performPrimaryClick(item)
        store.performPrimaryClick(inactiveItem)
        store.execute(.close(item))
        #expect(provider.activationCount == 1)
        #expect(provider.minimizeCount == 2)
        #expect(provider.closeCount == 1)
    }

    @Test("primary click uses fresh focus and always minimizes the active window")
    @MainActor
    func primaryClickUsesFreshState() {
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

        store.performPrimaryClick(staleInactiveItem)
        #expect(provider.minimizeCount == 1)
        #expect(provider.activationCount == 0)
        #expect(provider.invalidatedPIDs == [activeItem.pid])

        provider.snapshotValue = makeFixtureSnapshot(isActive: false)
        let staleActiveItem = copy(activeItem, isActive: true)
        store.performPrimaryClick(staleActiveItem)
        #expect(provider.minimizeCount == 1)
        #expect(provider.activationCount == 1)
        #expect(provider.invalidatedPIDs == [activeItem.pid, activeItem.pid])

        store.setAccessibilityAvailable(false)
        store.performPrimaryClick(staleActiveItem)
        #expect(provider.minimizeCount == 1)
        #expect(provider.activationCount == 1)
    }

    @Test("Minimize All refreshes and minimizes every eligible window deterministically")
    @MainActor
    func minimizeAllWindows() throws {
        let provider = MockWindowSnapshotProvider(
            snapshot: focusToggleSnapshot(activeWindow: "chatgpt"))
        let store = TaskbarStore(provider: provider)
        store.start(accessibilityTrusted: true)
        store.refreshNow()
        defer { store.stop() }
        let expected = MinimizeAllTargets.resolve(in: store.state).map(\.id)

        let intentController = TinyTaskbarIntentController(store: store)
        try intentController.minimizeAll()

        #expect(provider.minimizedItemIDs == expected)
        #expect(provider.activationCount == 0)
        #expect(provider.invalidateAllCount == 1)
        #expect(provider.invalidateWindowServerCount == 1)
    }

    @Test("Minimize All intent requires active Accessibility access")
    @MainActor
    func minimizeAllIntentRequiresAccessibility() {
        let store = TaskbarStore(provider: MockWindowSnapshotProvider())
        let intentController = TinyTaskbarIntentController(store: store)

        do {
            try intentController.minimizeAll()
            Issue.record("intent unexpectedly ran without Accessibility")
        } catch {
            #expect(error as? TinyTaskbarIntentError == .unavailable)
        }
    }

    @Test("focused primary click directly minimizes the selected physical window")
    @MainActor
    func focusedPrimaryClickMatchesNativeMinimize() {
        let provider = MockWindowSnapshotProvider(
            snapshot: focusToggleSnapshot(activeWindow: "chatgpt"))
        let store = TaskbarStore(provider: provider)
        store.start(accessibilityTrusted: true)
        store.refreshNow()
        defer { store.stop() }

        let initialItems = Array(store.state.itemsByDisplay.values.joined())
        guard let chatGPT = initialItems.first(where: { $0.title == "ChatGPT" }),
            let chromeOne = initialItems.first(where: { $0.title == "Chrome One" }),
            let chromeTwo = initialItems.first(where: { $0.title == "Chrome Two" })
        else {
            Issue.record("focus-toggle fixture windows were not projected")
            return
        }

        store.performPrimaryClick(chromeOne)
        #expect(provider.events == [.activate(chromeOne.id)])

        provider.events = []
        provider.snapshotValue = focusToggleSnapshot(activeWindow: "chrome-one")
        store.performPrimaryClick(chromeOne)
        #expect(provider.events == [.minimize(chromeOne.id)])

        provider.events = []
        provider.snapshotValue = focusToggleSnapshot(activeWindow: "chatgpt")
        store.performPrimaryClick(chromeOne)
        #expect(provider.events == [.activate(chromeOne.id)])

        provider.events = []
        provider.snapshotValue = focusToggleSnapshot(activeWindow: "chrome-one")
        store.performPrimaryClick(chromeOne)
        #expect(provider.events == [.minimize(chromeOne.id)])

        #expect(!provider.activatedItemIDs.contains(chatGPT.id))
        #expect(!provider.activatedItemIDs.contains(chromeTwo.id))
        #expect(provider.invalidateWindowServerCount == 0)
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

        store.performPrimaryClick(oldItem)

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

    private func focusToggleSnapshot(activeWindow: String) -> RawWindowSnapshot {
        let inputs: [(key: String, pid: Int32, app: String, title: String, frame: CGRect)] = [
            (
                "chatgpt", fixturePID, "ChatGPT", "ChatGPT",
                CGRect(x: 50, y: 100, width: 300, height: 500)
            ),
            (
                "chrome-one", fixturePID + 1, "Google Chrome", "Chrome One",
                CGRect(x: 400, y: 100, width: 300, height: 500)
            ),
            (
                "chrome-two", fixturePID + 1, "Google Chrome", "Chrome Two",
                CGRect(x: 750, y: 100, width: 300, height: 500)
            ),
        ]
        let candidates = inputs.map { input in
            WindowCandidate(
                stableKey: input.key,
                pid: input.pid,
                applicationName: input.app,
                title: input.title,
                frame: input.frame,
                isFocused: input.key == activeWindow,
                isMain: input.key == activeWindow
            )
        }
        let activePID = inputs.first(where: { $0.key == activeWindow })?.pid
        let cgWindows = inputs.enumerated().sorted { lhs, rhs in
            if lhs.element.key == activeWindow { return true }
            if rhs.element.key == activeWindow { return false }
            if (lhs.element.pid == activePID) != (rhs.element.pid == activePID) {
                return lhs.element.pid == activePID
            }
            return lhs.offset < rhs.offset
        }.map { index, input in
            CGWindowMetadata(
                windowNumber: UInt32(100 + index),
                ownerPID: input.pid,
                bounds: input.frame,
                title: input.title
            )
        }
        return RawWindowSnapshot(
            candidates: candidates,
            cgWindows: cgWindows,
            displays: [fixtureDisplay],
            frontmostPID: activePID
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
    private func renderApplicationIndicatorFixture(
        frame: NSRect,
        to outputURL: URL?
    ) throws {
        let applicationIdentity = "com.example.indicator-fixture"
        let longBadgeApplicationIdentity = "com.example.long-badge-fixture"
        let pid: Int32 = 77
        let panel = TaskbarPanel(frame: frame, onActivate: { _ in }, onClose: { _ in })
        defer { panel.close() }
        panel.update(
            frame: frame,
            items: [
                makeTaskbarItem(
                    id: "first", title: "Inbox", applicationIdentity: applicationIdentity,
                    pid: pid),
                makeTaskbarItem(
                    id: "second", title: "Second window",
                    applicationIdentity: applicationIdentity, pid: pid),
                makeTaskbarItem(
                    id: "third", title: "Long badge",
                    applicationIdentity: longBadgeApplicationIdentity, pid: 88),
            ],
            indicators: ApplicationIndicatorSnapshot(
                attentionPIDs: [pid],
                badgesByApplicationIdentity: [
                    applicationIdentity: "7",
                    longBadgeApplicationIdentity: "1234",
                ]))
        guard let contentView = panel.contentView else {
            throw CocoaError(.fileWriteUnknown)
        }
        contentView.layoutSubtreeIfNeeded()
        contentView.displayIfNeeded()
        guard
            let representation = contentView.bitmapImageRepForCachingDisplay(in: contentView.bounds)
        else {
            throw CocoaError(.fileWriteUnknown)
        }
        contentView.cacheDisplay(in: contentView.bounds, to: representation)
        guard let png = representation.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        if let outputURL {
            try png.write(to: outputURL, options: .atomic)
        }
    }

    @MainActor
    private func makeTaskbarItem(
        id: String,
        title: String? = nil,
        isMinimized: Bool = false,
        isActive: Bool = false,
        applicationIdentity: String? = nil,
        pid: Int32? = nil
    ) -> TaskbarItem {
        TaskbarItem(
            id: id,
            pid: pid ?? Int32(id.hashValue & 0x7fff) + 1,
            applicationName: "App " + id,
            applicationIdentity: applicationIdentity,
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
        items: [TaskbarItem]
    ) {
        panel.update(frame: frame, items: items)
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
    enum Event: Equatable {
        case activate(String)
        case minimize(String)
    }

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
    var events: [Event] = []
    var heightUpdates: [(itemID: String, height: CGFloat)] = []
    var applicationMenuCommandsValue: [ApplicationMenuCommand] = []
    var fullscreenCapabilityValue: WindowFullscreenCapability?
    var fullscreenCapabilityItemIDs: [String] = []
    var fullscreenUpdates: [(itemID: String, fullscreen: Bool)] = []
    var documentURLValue: URL?
    var documentURLItemIDs: [String] = []
    var applicationMenuCommandItemIDs: [String] = []
    var performedApplicationMenuCommands: [(itemID: String, command: ApplicationMenuCommand)] = []
    var invalidatedPIDs: [pid_t] = []
    var invalidateAllCount = 0
    var invalidateWindowServerCount = 0
    var onChange: (@MainActor @Sendable (WindowSnapshotChange, pid_t) -> Void)?
    var onInvalidateApplication: ((pid_t) -> Void)?

    init(snapshot: RawWindowSnapshot? = nil) {
        if let snapshot {
            snapshotValue = snapshot
        }
    }

    func snapshot() -> RawWindowSnapshot {
        snapshotCount += 1
        return snapshotValue
    }

    func invalidateApplication(_ pid: pid_t) {
        invalidatedPIDs.append(pid)
        onInvalidateApplication?(pid)
    }

    func invalidateAllApplications() {
        invalidateAllCount += 1
    }

    func invalidateWindowServer() {
        invalidateWindowServerCount += 1
    }

    func activate(_ item: TaskbarItem) {
        activationCount += 1
        activatedItemIDs.append(item.id)
        events.append(.activate(item.id))
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
        events.append(.minimize(item.id))
    }

    func fullscreenCapability(for item: TaskbarItem) -> WindowFullscreenCapability? {
        fullscreenCapabilityItemIDs.append(item.id)
        return fullscreenCapabilityValue
    }

    func setFullscreen(_ fullscreen: Bool, for item: TaskbarItem) {
        fullscreenUpdates.append((item.id, fullscreen))
    }

    func documentURL(for item: TaskbarItem) -> URL? {
        documentURLItemIDs.append(item.id)
        return documentURLValue
    }

    func close(_: TaskbarItem) {
        closeCount += 1
    }

    func applicationMenuCommands(for item: TaskbarItem) -> [ApplicationMenuCommand] {
        applicationMenuCommandItemIDs.append(item.id)
        return applicationMenuCommandsValue
    }

    func performApplicationMenuCommand(
        _ command: ApplicationMenuCommand,
        for item: TaskbarItem
    ) {
        performedApplicationMenuCommands.append((item.id, command))
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
