import AppKit
import ApplicationServices
import Foundation
import OSLog

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
        provider.activate(item)
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

@MainActor
final class AccessibilityPermissionController {
    private var didPrompt = false
    private let onStatusChanged: @MainActor (Bool) -> Void

    init(onStatusChanged: @escaping @MainActor (Bool) -> Void) {
        self.onStatusChanged = onStatusChanged
    }

    func checkAndPromptIfNeeded() -> Bool {
        guard !AXIsProcessTrusted() else { return true }
        guard !didPrompt else { return false }
        didPrompt = true

        // The SDK exports this documented key as mutable CF storage, which strict
        // concurrency correctly refuses to capture. Its public value is stable.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        presentExplanation()
        return false
    }

    private func presentExplanation() {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "TinyTaskbar needs Accessibility access"
        alert.informativeText =
            "Accessibility lets TinyTaskbar read window titles and focus a window when you click its item. No screen recording or window thumbnails are used."
        alert.addButton(withTitle: "Open Accessibility Settings")
        alert.addButton(withTitle: "Continue Without Taskbars")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn,
            let url = URL(
                string:
                    "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        {
            NSWorkspace.shared.open(url)
        }
        onStatusChanged(AXIsProcessTrusted())
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
        onActivate: @escaping @MainActor (TaskbarItem) -> Void
    ) {
        barView = TaskbarBarView(onActivate: onActivate)
        super.init(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
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

    func update(frame: NSRect, items: [TaskbarItem]) {
        setFrame(frame, display: false)
        barView.update(items: items)
    }
}

@MainActor
private final class TaskbarBarView: NSView {
    private let visualEffectView = NSVisualEffectView()
    private let scrollView = NSScrollView()
    private let stackView = NSStackView()
    private var currentItems: [TaskbarItem] = []
    private var buttons: [ObjectIdentifier: TaskbarItem] = [:]
    private var iconCache: [Int32: NSImage] = [:]
    private let onActivate: @MainActor (TaskbarItem) -> Void

    init(onActivate: @escaping @MainActor (TaskbarItem) -> Void) {
        self.onActivate = onActivate
        super.init(frame: .zero)

        wantsLayer = true
        layer?.cornerRadius = 8

        visualEffectView.material = .hudWindow
        visualEffectView.blendingMode = .behindWindow
        visualEffectView.state = .active
        visualEffectView.wantsLayer = true
        visualEffectView.layer?.cornerRadius = 8
        visualEffectView.layer?.masksToBounds = true
        addSubview(visualEffectView)

        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = true
        scrollView.horizontalScrollElasticity = .allowed
        scrollView.scrollerStyle = .overlay
        visualEffectView.addSubview(scrollView)

        stackView.orientation = .horizontal
        stackView.alignment = .centerY
        stackView.spacing = 4
        stackView.edgeInsets = NSEdgeInsets(top: 4, left: 6, bottom: 4, right: 6)
        stackView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = stackView
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        visualEffectView.frame = bounds
        scrollView.frame = visualEffectView.bounds
        let fittingSize = stackView.fittingSize
        stackView.frame.size = CGSize(
            width: max(fittingSize.width, scrollView.contentView.bounds.width),
            height: scrollView.contentView.bounds.height
        )
        stackView.frame.origin = .zero
    }

    func update(items: [TaskbarItem]) {
        guard items != currentItems else { return }
        currentItems = items
        buttons.removeAll()
        for view in stackView.arrangedSubviews {
            stackView.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        for item in items {
            let button = makeButton(for: item)
            buttons[ObjectIdentifier(button)] = item
            stackView.addArrangedSubview(button)
        }
        needsLayout = true
    }

    private func makeButton(for item: TaskbarItem) -> NSButton {
        let button = NSButton(
            title: item.displayTitle, target: self, action: #selector(activateButton(_:)))
        button.isBordered = false
        button.setButtonType(.momentaryPushIn)
        button.font = .systemFont(ofSize: 12, weight: item.isActive ? .semibold : .regular)
        button.lineBreakMode = .byTruncatingTail
        button.alignment = .left
        button.imagePosition = .imageLeading
        button.imageScaling = .scaleProportionallyDown
        button.contentTintColor = item.isActive ? .controlAccentColor : .labelColor
        button.toolTip = "Activate \(item.applicationName): \(item.displayTitle)"
        button.setAccessibilityRole(.button)
        button.setAccessibilityLabel("\(item.applicationName), \(item.displayTitle)")
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(greaterThanOrEqualToConstant: 110).isActive = true
        button.widthAnchor.constraint(lessThanOrEqualToConstant: 260).isActive = true
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        button.wantsLayer = true
        button.layer?.cornerRadius = 5
        button.layer?.backgroundColor =
            item.isActive
            ? NSColor.controlAccentColor.withAlphaComponent(0.22).cgColor
            : NSColor.clear.cgColor

        if let icon = icon(for: item.pid) {
            button.image = icon
        }
        return button
    }

    private func icon(for pid: Int32) -> NSImage? {
        if let cached = iconCache[pid] { return cached }
        let icon =
            NSRunningApplication(processIdentifier: pid)?.icon
            ?? NSImage(named: NSImage.applicationIconName)
        if let icon {
            icon.size = NSSize(width: 18, height: 18)
            iconCache[pid] = icon
        }
        return icon
    }

    @objc private func activateButton(_ sender: NSButton) {
        guard let item = buttons[ObjectIdentifier(sender)] else { return }
        onActivate(item)
    }
}
