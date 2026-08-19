import AppKit
import Foundation
import OSLog

@main
@MainActor
struct TinyTaskbarMain {
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate.makeDefault()
        application.delegate = delegate
        withExtendedLifetime(delegate) {
            application.run()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let logger = Logger(subsystem: "com.tinytaskbar", category: "ui")
    private let accessibilityProvider: any AccessibilityPermissionProvider
    private let provider: any WindowSnapshotProvider
    private let store: TaskbarStore
    private let dockVisibilityManager: any DockVisibilityManaging
    private let skipsOnboarding: Bool
    private var eventObserver: SystemEventObserver?
    private var attentionObserver: SystemApplicationAttentionObserver?
    private var badgeObserver: SystemDockBadgeObserver?
    private var applicationIndicators = ApplicationIndicatorSnapshot.empty
    private let preferencesStore: TinyTaskbarPreferencesStore
    private let temporaryPreferencesSuiteName: String?
    private var permissionRequestState = AccessibilityPermissionRequestState()
    private var settingsActivationState = SettingsActivationPolicyState()
    private var settingsWindow: TinyTaskbarSettingsWindow?
    // Keep each panel attached to the Space where it was created. A single
    // `.canJoinAllSpaces` panel is cloned by WindowServer during an interactive
    // Space swipe, so both halves necessarily show the same (source-Space)
    // contents. Cached per-Space panels let WindowServer compose each Desktop
    // with the taskbar state last observed there.
    private var panelsByDisplay: [String: [TaskbarPanel]] = [:]
    private var statusItem: NSStatusItem?

    static func makeDefault() -> AppDelegate {
        #if DEBUG
            if let fixture = DebugFixture.parse(arguments: CommandLine.arguments) {
                let suiteName =
                    "com.tinytaskbar.fixture.\(ProcessInfo.processInfo.processIdentifier)"
                let defaults = UserDefaults(suiteName: suiteName)!
                defaults.removePersistentDomain(forName: suiteName)
                let preferencesStore = TinyTaskbarPreferencesStore(defaults: defaults)
                let delegate = AppDelegate(
                    accessibilityProvider: DebugFixturePermissionProvider(),
                    provider: DebugFixtureWindowSnapshotProvider(fixture: fixture),
                    dockVisibilityManager: NoopDockVisibilityManager(),
                    preferencesStore: preferencesStore,
                    temporaryPreferencesSuiteName: suiteName,
                    skipsOnboarding: true
                )
                delegate.applicationIndicators = DebugFixture.indicators(
                    arguments: CommandLine.arguments)
                return delegate
            }
        #endif
        return AppDelegate()
    }

    init(
        accessibilityProvider: any AccessibilityPermissionProvider =
            SystemAccessibilityPermissionProvider(),
        provider: any WindowSnapshotProvider = SystemWindowSnapshotProvider(),
        dockVisibilityManager: any DockVisibilityManaging = DockVisibilityController(),
        preferencesStore: TinyTaskbarPreferencesStore = TinyTaskbarPreferencesStore(),
        temporaryPreferencesSuiteName: String? = nil,
        skipsOnboarding: Bool = false
    ) {
        self.accessibilityProvider = accessibilityProvider
        self.provider = provider
        self.store = TaskbarStore(provider: provider)
        self.dockVisibilityManager = dockVisibilityManager
        self.preferencesStore = preferencesStore
        self.temporaryPreferencesSuiteName = temporaryPreferencesSuiteName
        self.skipsOnboarding = skipsOnboarding
        super.init()
    }

    func applicationDidFinishLaunching(_: Notification) {
        NSApp.setActivationPolicy(.accessory)
        installStatusItem()
        applySavedDockVisibility()

        let provider = self.provider
        let store = self.store
        provider.onChange = { [weak store] change in
            store?.requestRefresh()
            if change == .windowDestroyed {
                store?.requestWindowDisappearanceConfirmation()
            }
        }
        store.onStateChange = { [weak self] state in
            self?.render(state: state)
        }

        let eventObserver = SystemEventObserver { [weak store] in
            store?.requestRefresh()
        }
        eventObserver.start()
        self.eventObserver = eventObserver

        let trusted = accessibilityProvider.isTrusted()
        startApplicationIndicators(accessibilityTrusted: trusted)
        let onboardingComplete =
            skipsOnboarding || preferencesStore.values.onboardingComplete
        logger.info(
            "application did finish launching trusted=\(trusted, privacy: .public) onboarding_complete=\(onboardingComplete, privacy: .public)"
        )
        store.start(accessibilityTrusted: trusted)
        if !trusted || !onboardingComplete {
            Task { @MainActor [weak self] in
                await Task.yield()
                self?.showSettingsWindow()
            }
        }
    }

    func applicationDidBecomeActive(_: Notification) {
        refreshPermissionStatus()
    }

    func applicationShouldHandleReopen(_: NSApplication, hasVisibleWindows _: Bool) -> Bool {
        showSettingsWindow()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_: Notification) {
        eventObserver?.stop()
        attentionObserver?.stop()
        badgeObserver?.stop()
        store.stop()
        discardTaskbarPanels()
        settingsWindow?.orderOut(nil)
        restoreDockOnTermination()
        if let temporaryPreferencesSuiteName {
            UserDefaults().removePersistentDomain(forName: temporaryPreferencesSuiteName)
        }
    }

    private func render(state: TaskbarState) {
        let representedApplicationIdentities = Set(
            state.itemsByDisplay.values.joined().compactMap(\.applicationIdentity))
        badgeObserver?.setObservedApplicationIdentities(
            representedApplicationIdentities)
        guard store.accessibilityAvailable else {
            store.setTaskbarWorkAreaHeights([:])
            discardTaskbarPanels()
            return
        }

        let presentation = TaskbarPresentationBuilder.build(state: state)
        let taskbarHeight = TaskbarAppearance.panelHeight
        let visibleDisplays = presentation.displays.filter {
            !state.fullscreenDisplayIdentifiers.contains($0.identifier)
        }
        store.setTaskbarWorkAreaHeights(
            Dictionary(
                uniqueKeysWithValues: visibleDisplays.map {
                    ($0.identifier, taskbarHeight)
                }))

        let displayIDs = Set(presentation.displays.map(\.identifier))
        for display in presentation.displays {
            if state.fullscreenDisplayIdentifiers.contains(display.identifier) {
                for panel in panelsByDisplay[display.identifier] ?? []
                where panel.isOnActiveSpace {
                    panel.orderOut(nil)
                }
                continue
            }
            let panel: TaskbarPanel
            if let existing = activeTaskbarPanel(for: display.identifier) {
                panel = existing
            } else {
                panel = makeTaskbarPanel(for: display)
                panelsByDisplay[display.identifier, default: []].append(panel)
            }

            let frame = TaskbarPanelLayout.frame(
                for: display, height: TaskbarAppearance.panelHeight)
            panel.update(
                frame: frame,
                items: presentation.itemsByDisplay[display.identifier] ?? [],
                indicators: applicationIndicators
            )
            if !panel.isVisible {
                panel.orderFrontRegardless()
            }
        }

        let removedDisplayIDs = Set(panelsByDisplay.keys).subtracting(displayIDs)
        for identifier in removedDisplayIDs {
            for panel in panelsByDisplay.removeValue(forKey: identifier) ?? [] {
                panel.orderOut(nil)
            }
        }
    }

    private func activeTaskbarPanel(for displayIdentifier: String) -> TaskbarPanel? {
        guard var cachedPanels = panelsByDisplay[displayIdentifier] else { return nil }
        let activePanels = cachedPanels.filter(\.isOnActiveSpace)
        guard let selectedPanel = activePanels.last else { return nil }

        // Removing a Desktop can migrate its windows onto another Desktop. If
        // that leaves multiple cached taskbars active, retain the newest panel
        // and discard the migrated duplicates.
        let duplicates = Array(activePanels.dropLast())
        for panel in duplicates {
            panel.orderOut(nil)
        }
        cachedPanels.removeAll { candidate in
            duplicates.contains { $0 === candidate }
        }
        panelsByDisplay[displayIdentifier] = cachedPanels
        return selectedPanel
    }

    private func makeTaskbarPanel(for display: DisplayDescriptor) -> TaskbarPanel {
        TaskbarPanel(
            frame: TaskbarPanelLayout.frame(
                for: display, height: TaskbarAppearance.panelHeight),
            onActivate: { [weak self] item in
                self?.handlePrimaryClick(item)
            },
            onClose: { [weak self] item in
                self?.store.execute(.close(item))
            },
            onWindowCommand: { [weak self] command in
                self?.store.execute(command)
            })
    }

    private func discardTaskbarPanels() {
        for panel in panelsByDisplay.values.joined() {
            panel.orderOut(nil)
        }
        panelsByDisplay.removeAll()
    }

    private func refreshPermissionStatus() {
        let trusted = accessibilityProvider.isTrusted()
        store.setAccessibilityAvailable(trusted)
        if trusted {
            badgeObserver?.start()
        } else {
            badgeObserver?.stop()
        }
        settingsWindow?.refresh(
            accessibilityTrusted: trusted,
            preferences: preferencesStore.values,
            accessibilityRequestWasMade: permissionRequestState.didRequest
        )
    }

    private func startApplicationIndicators(accessibilityTrusted: Bool) {
        // Debug fixtures must remain deterministic and independent of the host's
        // LaunchServices and Dock state.
        guard temporaryPreferencesSuiteName == nil else { return }

        let attentionObserver = SystemApplicationAttentionObserver()
        attentionObserver.onChange = { [weak self] pids in
            guard let self, pids != self.applicationIndicators.attentionPIDs else { return }
            self.applicationIndicators.attentionPIDs = pids
            self.refreshPanelIndicators()
        }
        attentionObserver.start()
        self.attentionObserver = attentionObserver

        let badgeObserver = SystemDockBadgeObserver()
        badgeObserver.onChange = { [weak self] badges in
            guard
                let self,
                badges != self.applicationIndicators.badgesByApplicationIdentity
            else { return }
            self.applicationIndicators.badgesByApplicationIdentity = badges
            self.refreshPanelIndicators()
        }
        self.badgeObserver = badgeObserver
        if accessibilityTrusted {
            badgeObserver.start()
        }
    }

    private func refreshPanelIndicators() {
        for panel in panelsByDisplay.values.joined() {
            panel.updateIndicators(applicationIndicators)
        }
    }

    private func showSettingsWindow() {
        let settingsWindow = settingsWindow ?? makeSettingsWindow()
        settingsWindow.restoreFixedContentSize()
        _ = settingsActivationState.apply(.show)
        let policyChanged = NSApp.setActivationPolicy(.regular)
        if !policyChanged {
            logger.error(
                "could not switch settings activation policy current=\(NSApp.activationPolicy().rawValue, privacy: .public)"
            )
        }
        refreshPermissionStatus()
        if !settingsWindow.isVisible {
            settingsWindow.center()
        }
        NSApp.activate()
        settingsWindow.orderFrontRegardless()
        if settingsWindow.canBecomeKey {
            settingsWindow.makeKey()
        }
        // The first WindowServer order performs an intrinsic fitting pass. Reassert
        // the intentional fixed form size afterward, then center the final frame.
        settingsWindow.restoreFixedContentSize()
        settingsWindow.center()
        Task { @MainActor [weak self, weak settingsWindow] in
            await Task.yield()
            guard let settingsWindow, settingsWindow.isVisible else { return }
            settingsWindow.restoreFixedContentSize()
            settingsWindow.center()
            self?.logger.debug(
                "settings shown active=\(NSApp.isActive, privacy: .public) visible=\(settingsWindow.isVisible, privacy: .public) window_number=\(settingsWindow.windowNumber, privacy: .public)"
            )
        }
    }

    private func makeSettingsWindow() -> TinyTaskbarSettingsWindow {
        let settingsWindow = TinyTaskbarSettingsWindow()
        settingsWindow.onAccessibilityRequest = { [weak self] in
            self?.requestAccessibility()
        }
        settingsWindow.onHideMacDockChanged = { [weak self] hidden in
            self?.setDockHidden(hidden)
        }
        settingsWindow.onClosed = { [weak self] in
            guard let self else { return }
            self.preferencesStore.setOnboardingComplete(true)
            self.settingsWindow = nil
            self.restoreAccessoryActivationPolicy()
        }
        self.settingsWindow = settingsWindow
        return settingsWindow
    }

    private func restoreAccessoryActivationPolicy() {
        _ = settingsActivationState.apply(.close)
        NSApp.setActivationPolicy(.accessory)
    }

    private func applySavedDockVisibility() {
        do {
            try dockVisibilityManager.setHidden(preferencesStore.values.hideMacDock)
        } catch {
            logger.error(
                "could not apply Dock visibility: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func setDockHidden(_ hidden: Bool) -> String? {
        do {
            try dockVisibilityManager.setHidden(hidden)
            preferencesStore.setHideMacDock(hidden)
            return nil
        } catch {
            logger.error(
                "could not update Dock visibility hidden=\(hidden, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            return error.localizedDescription
        }
    }

    private func restoreDockOnTermination() {
        do {
            try dockVisibilityManager.setHidden(false)
        } catch {
            logger.error(
                "could not restore Dock visibility on termination: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func requestAccessibility() {
        if !accessibilityProvider.isTrusted(),
            permissionRequestState.decision() == .request
        {
            _ = accessibilityProvider.requestAccess()
        }

        if let url = URL(
            string:
                "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        {
            NSWorkspace.shared.open(url)
        }
        refreshPermissionStatus()
    }

    private func handlePrimaryClick(_ item: TaskbarItem) {
        store.performPrimaryClick(item)
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(
            systemSymbolName: "rectangle.bottomthird.inset.filled",
            accessibilityDescription: "TinyTaskbar")
        let menu = NSMenu()
        menu.addItem(
            withTitle: "Settings…",
            action: #selector(openSettings(_:)),
            keyEquivalent: ",")
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Quit TinyTaskbar",
            action: #selector(quitApplication(_:)),
            keyEquivalent: "q")
        for menuItem in menu.items { menuItem.target = self }
        item.menu = menu
        statusItem = item
    }

    @objc private func openSettings(_: NSMenuItem) {
        showSettingsWindow()
    }

    @objc private func quitApplication(_: NSMenuItem) {
        NSApp.terminate(nil)
    }
}
