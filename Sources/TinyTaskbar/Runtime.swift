import AppKit
import ApplicationServices
import Foundation
import OSLog
import ServiceManagement

struct RefreshMetrics: Equatable, Sendable {
    fileprivate(set) var refreshCount = 0
    fileprivate(set) var lastCandidateCount = 0
    fileprivate(set) var lastVisibleWindowCount = 0
    fileprivate(set) var lastDurationMilliseconds = 0.0
}

@MainActor
final class TaskbarStore {
    private let provider: any WindowSnapshotProvider
    private let logger = Logger(subsystem: "com.tinytaskbar", category: "refresh")
    private var pendingRefresh: Task<Void, Never>?
    private(set) var state = TaskbarState.empty
    private(set) var lifecycleState: LifecycleState = .stopped
    private(set) var accessibilityAvailable = false
    private(set) var metrics = RefreshMetrics()

    var onStateChange: (@MainActor (TaskbarState) -> Void)?

    init(provider: any WindowSnapshotProvider) {
        self.provider = provider
    }

    func start(accessibilityTrusted: Bool) {
        lifecycleState = LifecycleReducer.reduce(
            state: lifecycleState,
            event: .launched(accessibilityTrusted: accessibilityTrusted)
        )
        accessibilityAvailable = accessibilityTrusted
        if accessibilityTrusted {
            requestRefresh()
        }
    }

    func setAccessibilityAvailable(_ available: Bool) {
        accessibilityAvailable = available
        lifecycleState = LifecycleReducer.reduce(
            state: lifecycleState,
            event: .accessibilityChanged(available)
        )

        guard available else {
            pendingRefresh?.cancel()
            pendingRefresh = nil
            if state != .empty {
                state = .empty
                onStateChange?(state)
            }
            return
        }

        requestRefresh()
    }

    func requestRefresh() {
        guard accessibilityAvailable, pendingRefresh == nil else { return }

        pendingRefresh = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: 50_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.pendingRefresh = nil
            self?.refreshNow()
        }
    }

    func refreshNow() {
        guard accessibilityAvailable else { return }

        let start = DispatchTime.now().uptimeNanoseconds
        let snapshot = provider.snapshot()
        let projected = WindowProjection.project(
            candidates: snapshot.candidates,
            cgWindows: snapshot.cgWindows,
            displays: snapshot.displays,
            selfPID: ProcessInfo.processInfo.processIdentifier,
            frontmostPID: snapshot.frontmostPID
        )
        let elapsed = DispatchTime.now().uptimeNanoseconds - start
        let durationMilliseconds = Double(elapsed) / 1_000_000

        metrics.refreshCount += 1
        metrics.lastCandidateCount = snapshot.candidates.count
        metrics.lastVisibleWindowCount = projected.itemsByDisplay.values.reduce(0) { $0 + $1.count }
        metrics.lastDurationMilliseconds = durationMilliseconds
        logger.debug(
            "refresh candidates=\(snapshot.candidates.count, privacy: .public) visible=\(self.metrics.lastVisibleWindowCount, privacy: .public) duration_ms=\(durationMilliseconds, privacy: .public)"
        )

        if projected != state {
            state = projected
            onStateChange?(state)
        }
    }

    func activate(_ item: TaskbarItem) {
        guard accessibilityAvailable else { return }
        if item.isActive {
            provider.minimize(item)
        } else {
            provider.activate(item)
        }
        requestRefresh()
    }

    func close(_ item: TaskbarItem) {
        guard accessibilityAvailable else { return }
        provider.close(item)
        requestRefresh()
    }

    func stop() {
        pendingRefresh?.cancel()
        pendingRefresh = nil
        lifecycleState = LifecycleReducer.reduce(state: lifecycleState, event: .stopped)
        accessibilityAvailable = false
        if state != .empty {
            state = .empty
            onStateChange?(state)
        }
    }
}

enum AccessibilityPermissionRequestDecision: Equatable, Sendable {
    case request
    case alreadyRequested
}

struct AccessibilityPermissionRequestState: Equatable, Sendable {
    private(set) var didRequest = false

    mutating func decision() -> AccessibilityPermissionRequestDecision {
        guard !didRequest else { return .alreadyRequested }
        didRequest = true
        return .request
    }
}

enum SettingsActivationPolicy: Equatable, Sendable {
    case accessory
    case regular
}

enum SettingsVisibilityEvent: Equatable, Sendable {
    case show
    case close
}

struct SettingsActivationPolicyState: Equatable, Sendable {
    private(set) var policy: SettingsActivationPolicy = .accessory

    mutating func apply(_ event: SettingsVisibilityEvent) -> SettingsActivationPolicy {
        switch event {
        case .show:
            policy = .regular
        case .close:
            policy = .accessory
        }
        return policy
    }
}

@MainActor
final class TinyTaskbarPreferencesStore {
    private static let onboardingCompleteKey = "onboardingComplete"
    private static let showsWindowTitlesKey = "showsWindowTitles"

    private let defaults: UserDefaults
    private(set) var values: TinyTaskbarPreferences

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        values = TinyTaskbarPreferences(
            onboardingComplete: defaults.object(forKey: Self.onboardingCompleteKey) as? Bool
                ?? TinyTaskbarPreferences.defaults.onboardingComplete,
            showsWindowTitles: defaults.object(forKey: Self.showsWindowTitlesKey) as? Bool
                ?? TinyTaskbarPreferences.defaults.showsWindowTitles
        )
    }

    func setOnboardingComplete(_ complete: Bool) {
        values.onboardingComplete = complete
        defaults.set(complete, forKey: Self.onboardingCompleteKey)
    }

    func setShowsWindowTitles(_ shows: Bool) {
        values.showsWindowTitles = shows
        defaults.set(shows, forKey: Self.showsWindowTitlesKey)
    }
}

@MainActor
final class TinyTaskbarSettingsWindow: NSWindow, NSWindowDelegate {
    private static let fixedContentSize = NSSize(width: 640, height: 340)

    var onAccessibilityRequest: (@MainActor () -> Void)?
    var onShowsWindowTitlesChanged: (@MainActor (Bool) -> Void)?
    var onDone: (@MainActor () -> Void)?
    var onQuit: (@MainActor () -> Void)?
    var onClosed: (@MainActor () -> Void)?

    private let accessibilityStatusLabel: NSTextField
    private let accessibilityButton: NSButton
    private let launchAtLoginSwitch: NSSwitch
    private let launchAtLoginStatusLabel: NSTextField
    private let showWindowTitlesSwitch: NSSwitch
    private let doneButton: NSButton
    private let quitButton: NSButton
    private let launchAtLoginService: SMAppService

    init() {
        accessibilityStatusLabel = NSTextField(labelWithString: "Required")
        accessibilityButton = NSButton(
            title: "Enable Accessibility…", target: nil, action: nil)
        launchAtLoginSwitch = NSSwitch()
        launchAtLoginStatusLabel = NSTextField(wrappingLabelWithString: "Off")
        showWindowTitlesSwitch = NSSwitch()
        doneButton = NSButton(title: "Done", target: nil, action: nil)
        quitButton = NSButton(title: "Quit TinyTaskbar", target: nil, action: nil)
        launchAtLoginService = SMAppService.mainApp

        super.init(
            contentRect: NSRect(origin: .zero, size: Self.fixedContentSize),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )

        let fixedContentView = NSView(
            frame: NSRect(origin: .zero, size: Self.fixedContentSize))
        fixedContentView.autoresizingMask = [.width, .height]
        contentView = fixedContentView

        title = "TinyTaskbar Settings"
        isReleasedWhenClosed = false
        isMovableByWindowBackground = true
        level = .normal
        collectionBehavior = [.moveToActiveSpace]
        hidesOnDeactivate = false
        delegate = self
        setupInterface()
        contentView?.layoutSubtreeIfNeeded()
        contentMinSize = Self.fixedContentSize
        contentMaxSize = Self.fixedContentSize
        setContentSize(Self.fixedContentSize)
        restoreFixedContentSize()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func refresh(
        accessibilityTrusted: Bool,
        showsWindowTitles: Bool,
        accessibilityRequestWasMade: Bool
    ) {
        accessibilityStatusLabel.stringValue = accessibilityTrusted ? "Granted" : "Required"
        accessibilityStatusLabel.textColor =
            accessibilityTrusted
            ? .systemGreen
            : .secondaryLabelColor
        accessibilityButton.title =
            accessibilityTrusted || accessibilityRequestWasMade
            ? "Open Accessibility Settings…"
            : "Enable Accessibility…"
        accessibilityButton.setAccessibilityLabel(accessibilityButton.title)
        showWindowTitlesSwitch.state = showsWindowTitles ? .on : .off
        refreshLaunchAtLoginStatus()
    }

    func restoreFixedContentSize() {
        let contentRect = NSRect(origin: .zero, size: Self.fixedContentSize)
        let targetFrameSize = frameRect(forContentRect: contentRect).size
        setFrame(
            NSRect(origin: frame.origin, size: targetFrameSize),
            display: isVisible
        )
        contentView?.frame = contentRect
    }

    func windowWillClose(_: Notification) {
        onClosed?()
        NSApp.deactivate()
    }

    private func setupInterface() {
        let heading = NSTextField(labelWithString: "TinyTaskbar")
        heading.font = .systemFont(ofSize: 22, weight: .semibold)
        heading.alignment = .left
        heading.setContentHuggingPriority(.required, for: .horizontal)
        let headingSpacer = NSView()
        headingSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        headingSpacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let headingRow = NSStackView(views: [heading, headingSpacer])
        headingRow.alignment = .centerY
        headingRow.distribution = .fill

        let introduction = NSTextField(
            wrappingLabelWithString:
                "A compact taskbar for the windows visible on your displays. Accessibility is required to read window titles and focus a window when you select it. No screen recording or thumbnails are used."
        )
        introduction.maximumNumberOfLines = 0
        introduction.alignment = .left

        accessibilityButton.bezelStyle = .rounded
        accessibilityButton.target = self
        accessibilityButton.action = #selector(accessibilityButtonPressed)
        accessibilityButton.setAccessibilityLabel("Enable Accessibility")

        launchAtLoginSwitch.target = self
        launchAtLoginSwitch.action = #selector(launchAtLoginChanged(_:))
        launchAtLoginSwitch.setAccessibilityLabel("Launch TinyTaskbar at login")
        launchAtLoginStatusLabel.maximumNumberOfLines = 2
        launchAtLoginStatusLabel.lineBreakMode = .byWordWrapping
        launchAtLoginStatusLabel.setContentCompressionResistancePriority(
            .required, for: .horizontal)
        launchAtLoginStatusLabel.widthAnchor.constraint(equalToConstant: 190).isActive = true

        showWindowTitlesSwitch.target = self
        showWindowTitlesSwitch.action = #selector(showWindowTitlesChanged(_:))
        showWindowTitlesSwitch.setAccessibilityLabel("Show window titles")

        doneButton.bezelStyle = .rounded
        doneButton.keyEquivalent = "\r"
        doneButton.target = self
        doneButton.action = #selector(doneButtonPressed)
        doneButton.setAccessibilityLabel("Done")

        quitButton.bezelStyle = .rounded
        quitButton.target = self
        quitButton.action = #selector(quitButtonPressed)
        quitButton.setAccessibilityLabel("Quit TinyTaskbar")

        let accessibilityControls = NSStackView(
            views: [accessibilityStatusLabel, accessibilityButton])
        accessibilityControls.alignment = .centerY
        accessibilityControls.spacing = 10
        accessibilityControls.setContentHuggingPriority(.required, for: .horizontal)
        accessibilityControls.setContentCompressionResistancePriority(
            .required, for: .horizontal)
        accessibilityButton.setContentHuggingPriority(.required, for: .horizontal)
        accessibilityButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        let accessibilityRow = makeRow(
            title: "Accessibility",
            detail: "Required for semantic window discovery and focus/raise.",
            accessory: accessibilityControls
        )

        let launchControls = NSStackView(
            views: [launchAtLoginSwitch, launchAtLoginStatusLabel])
        launchControls.alignment = .centerY
        launchControls.spacing = 10
        launchControls.setContentHuggingPriority(.required, for: .horizontal)
        launchControls.setContentCompressionResistancePriority(.required, for: .horizontal)
        let launchRow = makeRow(
            title: "Launch at Login",
            detail: "Start TinyTaskbar automatically when you sign in.",
            accessory: launchControls
        )

        let titleControls = NSStackView(views: [showWindowTitlesSwitch])
        titleControls.setContentHuggingPriority(.required, for: .horizontal)
        let titleRow = makeRow(
            title: "Show Window Titles",
            detail: "When off, compact buttons show only the owning app name.",
            accessory: titleControls
        )

        let buttonSpacer = NSView()
        buttonSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        buttonSpacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let buttonRow = NSStackView(views: [buttonSpacer, quitButton, doneButton])
        buttonRow.alignment = .centerY
        buttonRow.spacing = 10
        buttonRow.setContentHuggingPriority(.required, for: .horizontal)
        buttonRow.distribution = .fill

        let arrangedRows = [
            headingRow,
            introduction,
            accessibilityRow,
            launchRow,
            titleRow,
            buttonRow,
        ]
        let stack = NSStackView(views: arrangedRows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false

        guard let contentView else { return }
        let horizontalInset: CGFloat = 28
        let topInset: CGFloat = 26
        let bottomInset: CGFloat = 24
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(
                equalTo: contentView.leadingAnchor, constant: horizontalInset),
            stack.trailingAnchor.constraint(
                equalTo: contentView.trailingAnchor, constant: -horizontalInset),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: topInset),
            stack.bottomAnchor.constraint(
                equalTo: contentView.bottomAnchor, constant: -bottomInset),
        ])
        for row in arrangedRows {
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        quitButton.setContentHuggingPriority(.required, for: .horizontal)
        doneButton.setContentHuggingPriority(.required, for: .horizontal)
        doneButton.setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    private func makeRow(title: String, detail: String, accessory: NSView) -> NSStackView {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        titleLabel.alignment = .left
        let detailLabel = NSTextField(wrappingLabelWithString: detail)
        detailLabel.maximumNumberOfLines = 0
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.alignment = .left

        let text = NSStackView(views: [titleLabel, detailLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 3
        text.setContentHuggingPriority(.defaultLow, for: .horizontal)
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: [text, accessory])
        row.alignment = .centerY
        row.distribution = .fill
        row.spacing = 16
        row.setContentCompressionResistancePriority(.required, for: .horizontal)
        return row
    }

    private func refreshLaunchAtLoginStatus() {
        switch launchAtLoginService.status {
        case .enabled:
            launchAtLoginSwitch.state = .on
            launchAtLoginSwitch.isEnabled = true
            launchAtLoginStatusLabel.stringValue = "On"
        case .notRegistered:
            launchAtLoginSwitch.state = .off
            launchAtLoginSwitch.isEnabled = true
            launchAtLoginStatusLabel.stringValue = "Off"
        case .requiresApproval:
            launchAtLoginSwitch.state = .on
            launchAtLoginSwitch.isEnabled = false
            launchAtLoginStatusLabel.stringValue = "Approval required in System Settings"
        case .notFound:
            launchAtLoginSwitch.state = .off
            launchAtLoginSwitch.isEnabled = false
            launchAtLoginStatusLabel.stringValue = "Unavailable for this app bundle"
        @unknown default:
            launchAtLoginSwitch.state = .off
            launchAtLoginSwitch.isEnabled = false
            launchAtLoginStatusLabel.stringValue = "Unavailable"
        }
        launchAtLoginStatusLabel.textColor = .secondaryLabelColor
    }

    @objc private func accessibilityButtonPressed() {
        onAccessibilityRequest?()
    }

    @objc private func launchAtLoginChanged(_ sender: NSSwitch) {
        do {
            if sender.state == .on {
                try launchAtLoginService.register()
            } else {
                try launchAtLoginService.unregister()
            }
            refreshLaunchAtLoginStatus()
        } catch {
            sender.state = launchAtLoginService.status == .enabled ? .on : .off
            sender.isEnabled = false
            launchAtLoginStatusLabel.stringValue =
                "Could not update: \(error.localizedDescription)"
            launchAtLoginStatusLabel.textColor = .systemOrange
        }
    }

    @objc private func showWindowTitlesChanged(_ sender: NSSwitch) {
        onShowsWindowTitlesChanged?(sender.state == .on)
    }

    @objc private func doneButtonPressed() {
        onDone?()
    }

    @objc private func quitButtonPressed() {
        onQuit?()
    }
}

@MainActor
final class SystemEventObserver {
    private var tokens: [NSObjectProtocol] = []
    private let handler: @MainActor () -> Void

    init(handler: @escaping @MainActor () -> Void) {
        self.handler = handler
    }

    func start() {
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        let workspaceNotifications: [Notification.Name] = [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.didHideApplicationNotification,
            NSWorkspace.didUnhideApplicationNotification,
            NSWorkspace.activeSpaceDidChangeNotification,
        ]
        for name in workspaceNotifications {
            tokens.append(
                workspaceCenter.addObserver(forName: name, object: nil, queue: .main) {
                    [weak self] _ in
                    Task { @MainActor [weak self] in
                        self?.handler()
                    }
                }
            )
        }

        tokens.append(
            NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.handler()
                }
            }
        )
    }

    func stop() {
        for token in tokens {
            NotificationCenter.default.removeObserver(token)
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
        tokens.removeAll()
    }
}

@MainActor
final class TaskbarPanel: NSPanel {
    private let barView: TaskbarBarView

    init(
        frame: NSRect,
        onActivate: @escaping @MainActor (TaskbarItem) -> Void,
        onClose: @escaping @MainActor (TaskbarItem) -> Void
    ) {
        barView = TaskbarBarView(onActivate: onActivate, onClose: onClose)
        super.init(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .statusBar
        collectionBehavior = [
            .canJoinAllSpaces,
            .canJoinAllApplications,
            .fullScreenAuxiliary,
            .ignoresCycle,
        ]
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        isMovable = false
        isReleasedWhenClosed = false
        contentView = barView
    }

    override var canBecomeKey: Bool { false }

    override var canBecomeMain: Bool { false }

    func update(frame: NSRect, items: [TaskbarItem], showsWindowTitles: Bool) {
        if self.frame != frame {
            setFrame(frame, display: false)
        }
        barView.update(items: items, showsWindowTitles: showsWindowTitles)
    }
}

@MainActor
final class TaskbarButton: NSButton {
    var contextualMenu: NSMenu?
    var itemID = ""
    var minimumWidthConstraint: NSLayoutConstraint?
    var maximumWidthConstraint: NSLayoutConstraint?
    var heightConstraint: NSLayoutConstraint?

    override func menu(for _: NSEvent) -> NSMenu? {
        contextualMenu
    }
}

@MainActor
private final class TaskbarBarView: NSView {
    private struct ApplicationIconKey: Hashable {
        let stableIdentity: String

        init(item: TaskbarItem) {
            stableIdentity = item.applicationIdentity ?? "name:\(item.applicationName)"
        }
    }

    private let visualEffectView = NSVisualEffectView()
    private let scrollView = NSScrollView()
    private let stackView = NSStackView()
    private let separatorView = NSView()
    private var currentItems: [TaskbarItem] = []
    private var currentShowsWindowTitles = true
    private var buttons: [ObjectIdentifier: TaskbarItem] = [:]
    private var buttonsByID: [String: TaskbarButton] = [:]
    private var iconCache: [ApplicationIconKey: NSImage] = [:]
    private let onActivate: @MainActor (TaskbarItem) -> Void
    private let onClose: @MainActor (TaskbarItem) -> Void

    init(
        onActivate: @escaping @MainActor (TaskbarItem) -> Void,
        onClose: @escaping @MainActor (TaskbarItem) -> Void
    ) {
        self.onActivate = onActivate
        self.onClose = onClose
        super.init(frame: .zero)

        wantsLayer = true
        layer?.cornerRadius = 0

        visualEffectView.material = .headerView
        visualEffectView.blendingMode = .behindWindow
        visualEffectView.state = .active
        visualEffectView.isEmphasized = false
        visualEffectView.wantsLayer = true
        visualEffectView.layer?.cornerRadius = 0
        addSubview(visualEffectView)

        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = false
        // Keep the horizontal document scrollable without allowing a legacy
        // scroller to reserve 17pt of the 30pt taskbar viewport.
        scrollView.hasHorizontalScroller = false
        scrollView.horizontalScrollElasticity = .allowed
        visualEffectView.addSubview(scrollView)

        stackView.orientation = .horizontal
        stackView.alignment = .centerY
        stackView.spacing = 1
        stackView.edgeInsets = NSEdgeInsets()
        // The document view is positioned by the scroll view's clip view and by the
        // explicit frame in layout(). It must remain frame-managed; disabling
        // autoresizing here lets AppKit's document-view constraints pin it to the
        // clip view's top edge after the parent layout pass.
        stackView.translatesAutoresizingMaskIntoConstraints = true
        scrollView.documentView = stackView

        separatorView.identifier = NSUserInterfaceItemIdentifier(
            TaskbarPanelLayout.topSeparatorIdentifier)
        separatorView.wantsLayer = true
        separatorView.layer?.backgroundColor =
            NSColor.separatorColor.withAlphaComponent(0.65).cgColor
        addSubview(separatorView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        visualEffectView.frame = bounds
        let availableHeight = max(0, bounds.height)
        let separatorHeight = min(TaskbarPanelLayout.topSeparatorHeight, availableHeight)
        let verticalInset = min(
            TaskbarPanelLayout.contentVerticalInset,
            max(0, (availableHeight - separatorHeight) / 2)
        )
        separatorView.frame = NSRect(
            x: bounds.minX,
            y: bounds.maxY - separatorHeight,
            width: max(0, bounds.width),
            height: separatorHeight
        )

        let contentMinY = bounds.minY + verticalInset
        let contentMaxY = max(
            contentMinY,
            bounds.maxY - separatorHeight - verticalInset
        )
        let contentFrame = NSRect(
            x: bounds.minX,
            y: contentMinY,
            width: max(0, bounds.width),
            height: max(0, contentMaxY - contentMinY)
        )
        scrollView.frame = contentFrame
        // Refresh the clip view after changing the viewport, but do not use its
        // bounds for document sizing: on a first pass or display resize those
        // bounds can still describe the previous viewport.
        scrollView.layoutSubtreeIfNeeded()
        let buttonHeight = min(TaskbarPanelLayout.contentHeight, contentFrame.height)
        for button in buttonsByID.values {
            button.heightConstraint?.constant = buttonHeight
        }
        let fittingSize = stackView.fittingSize
        stackView.frame.size = CGSize(
            width: max(fittingSize.width, contentFrame.width),
            height: contentFrame.height
        )
        stackView.frame.origin = .zero
        stackView.layoutSubtreeIfNeeded()
    }

    func update(items: [TaskbarItem], showsWindowTitles: Bool) {
        guard items != currentItems || showsWindowTitles != currentShowsWindowTitles else {
            return
        }
        currentItems = items
        currentShowsWindowTitles = showsWindowTitles
        let currentIconKeys = Set(items.map(ApplicationIconKey.init))
        iconCache = iconCache.filter { currentIconKeys.contains($0.key) }

        let desiredIDs = items.map(\.id)
        let desiredIDSet = Set(desiredIDs)
        let staleIDs = buttonsByID.keys.filter { !desiredIDSet.contains($0) }
        for itemID in staleIDs {
            guard let button = buttonsByID.removeValue(forKey: itemID) else { continue }
            stackView.removeArrangedSubview(button)
            button.removeFromSuperview()
        }

        for item in items {
            if let button = buttonsByID[item.id] {
                updateButton(button, for: item, showsWindowTitles: showsWindowTitles)
            } else {
                let button = makeButton(for: item, showsWindowTitles: showsWindowTitles)
                buttonsByID[item.id] = button
                stackView.addArrangedSubview(button)
            }
        }

        buttons = items.reduce(into: [ObjectIdentifier: TaskbarItem]()) { result, item in
            guard let button = buttonsByID[item.id] else { return }
            result[ObjectIdentifier(button)] = item
        }
        reorderButtonsIfNeeded(to: desiredIDs)
        needsLayout = true
    }

    private func makeButton(for item: TaskbarItem, showsWindowTitles: Bool) -> TaskbarButton {
        let button = TaskbarButton(
            title: item.buttonTitle(showsWindowTitles: showsWindowTitles),
            target: self,
            action: #selector(activateButton(_:))
        )
        button.itemID = item.id
        button.isBordered = false
        button.setButtonType(.momentaryPushIn)
        button.lineBreakMode = .byTruncatingTail
        button.alignment = .left
        button.imagePosition = .imageLeading
        button.imageScaling = .scaleProportionallyDown
        button.setAccessibilityRole(.button)
        button.contextualMenu = makeContextualMenu(for: item)
        button.translatesAutoresizingMaskIntoConstraints = false
        let widthRange = TaskbarButtonLayout.widthRange(showsWindowTitles: showsWindowTitles)
        button.minimumWidthConstraint = button.widthAnchor.constraint(
            greaterThanOrEqualToConstant: widthRange.lowerBound)
        button.minimumWidthConstraint?.isActive = true
        button.maximumWidthConstraint = button.widthAnchor.constraint(
            lessThanOrEqualToConstant: widthRange.upperBound)
        button.maximumWidthConstraint?.isActive = true
        button.heightConstraint = button.heightAnchor.constraint(
            equalToConstant: TaskbarPanelLayout.contentHeight)
        button.heightConstraint?.isActive = true
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        button.wantsLayer = true
        button.layer?.cornerRadius = 0
        updateButton(button, for: item, showsWindowTitles: showsWindowTitles)
        return button
    }

    private func updateButton(
        _ button: TaskbarButton,
        for item: TaskbarItem,
        showsWindowTitles: Bool
    ) {
        button.itemID = item.id
        button.title = item.buttonTitle(showsWindowTitles: showsWindowTitles)
        button.font = .systemFont(ofSize: 12, weight: item.isActive ? .semibold : .regular)
        button.contentTintColor = .labelColor
        button.alphaValue = item.isMinimized ? 0.65 : 1
        button.toolTip = item.tooltip
        button.setAccessibilityRole(.button)
        button.setAccessibilityLabel(item.accessibilityLabel)
        button.image = icon(for: item)

        let widthRange = TaskbarButtonLayout.widthRange(showsWindowTitles: showsWindowTitles)
        if button.minimumWidthConstraint?.constant != widthRange.lowerBound {
            button.minimumWidthConstraint?.constant = widthRange.lowerBound
        }
        if button.maximumWidthConstraint?.constant != widthRange.upperBound {
            button.maximumWidthConstraint?.constant = widthRange.upperBound
        }
        button.contextualMenu = button.contextualMenu ?? makeContextualMenu(for: item)
        button.contextualMenu?.items.first?.representedObject = item.id
        button.layer?.backgroundColor =
            item.isActive
            ? NSColor.labelColor.withAlphaComponent(0.10).cgColor
            : NSColor.clear.cgColor
    }

    private func makeContextualMenu(for item: TaskbarItem) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let closeItem = NSMenuItem(
            title: "Close",
            action: #selector(closeWindow(_:)),
            keyEquivalent: ""
        )
        closeItem.target = self
        closeItem.representedObject = item.id
        if let closeImage = NSImage(
            systemSymbolName: "xmark",
            accessibilityDescription: "Close"
        ) {
            closeImage.size = NSSize(width: 13, height: 13)
            closeImage.isTemplate = true
            closeItem.image = closeImage
        }
        menu.addItem(closeItem)
        return menu
    }

    private func reorderButtonsIfNeeded(to desiredIDs: [String]) {
        let currentIDs = stackView.arrangedSubviews.compactMap { view in
            (view as? TaskbarButton)?.itemID
        }
        guard currentIDs != desiredIDs else { return }

        let desiredButtons = desiredIDs.compactMap { buttonsByID[$0] }
        for view in stackView.arrangedSubviews {
            stackView.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for button in desiredButtons {
            stackView.addArrangedSubview(button)
        }
    }

    private func icon(for item: TaskbarItem) -> NSImage? {
        let key = ApplicationIconKey(item: item)
        if let cached = iconCache[key] { return cached }
        let source =
            NSRunningApplication(processIdentifier: item.pid)?.icon
            ?? NSImage(systemSymbolName: "macwindow", accessibilityDescription: nil)
            ?? NSImage(named: NSImage.applicationIconName)
        if let source,
            let icon = source.copy() as? NSImage
        {
            icon.size = NSSize(width: 18, height: 18)
            iconCache[key] = icon
            return icon
        }
        return nil
    }

    @objc private func activateButton(_ sender: NSButton) {
        guard let item = buttons[ObjectIdentifier(sender)] else { return }
        onActivate(item)
    }

    @objc private func closeWindow(_ sender: NSMenuItem) {
        guard let itemID = sender.representedObject as? String,
            let item = currentItems.first(where: { $0.id == itemID })
        else {
            return
        }
        onClose(item)
    }
}
