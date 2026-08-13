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
    private let applicationLauncher: any ApplicationLaunching
    private let skipsOnboarding: Bool
    private var eventObserver: SystemEventObserver?
    private let preferencesStore: TinyTaskbarPreferencesStore
    private let temporaryPreferencesSuiteName: String?
    private var permissionRequestState = AccessibilityPermissionRequestState()
    private var settingsActivationState = SettingsActivationPolicyState()
    private var settingsWindow: TinyTaskbarSettingsWindow?
    private var applicationsWindow: ApplicationsManagementWindow?
    private var panels: [String: TaskbarPanel] = [:]
    private var statusItem: NSStatusItem?
    private var taskbarsVisible = true

    static func makeDefault() -> AppDelegate {
        #if DEBUG
            if let fixture = DebugFixture.parse(arguments: CommandLine.arguments) {
                let suiteName =
                    "com.tinytaskbar.fixture.\(ProcessInfo.processInfo.processIdentifier)"
                let defaults = UserDefaults(suiteName: suiteName)!
                defaults.removePersistentDomain(forName: suiteName)
                return AppDelegate(
                    accessibilityProvider: DebugFixturePermissionProvider(),
                    provider: DebugFixtureWindowSnapshotProvider(fixture: fixture),
                    preferencesStore: TinyTaskbarPreferencesStore(defaults: defaults),
                    temporaryPreferencesSuiteName: suiteName,
                    skipsOnboarding: true
                )
            }
        #endif
        return AppDelegate()
    }

    init(
        accessibilityProvider: any AccessibilityPermissionProvider =
            SystemAccessibilityPermissionProvider(),
        provider: any WindowSnapshotProvider = SystemWindowSnapshotProvider(),
        applicationLauncher: any ApplicationLaunching = WorkspaceApplicationLauncher(),
        preferencesStore: TinyTaskbarPreferencesStore = TinyTaskbarPreferencesStore(),
        temporaryPreferencesSuiteName: String? = nil,
        skipsOnboarding: Bool = false
    ) {
        self.accessibilityProvider = accessibilityProvider
        self.provider = provider
        self.store = TaskbarStore(provider: provider)
        self.applicationLauncher = applicationLauncher
        self.preferencesStore = preferencesStore
        self.temporaryPreferencesSuiteName = temporaryPreferencesSuiteName
        self.skipsOnboarding = skipsOnboarding
        super.init()
    }

    func applicationDidFinishLaunching(_: Notification) {
        NSApp.setActivationPolicy(.accessory)
        installStatusItem()

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
        store.stop()
        for panel in panels.values {
            panel.orderOut(nil)
        }
        panels.removeAll()
        settingsWindow?.orderOut(nil)
        if let temporaryPreferencesSuiteName {
            UserDefaults().removePersistentDomain(forName: temporaryPreferencesSuiteName)
        }
    }

    private func render(state: TaskbarState) {
        guard store.accessibilityAvailable, taskbarsVisible else {
            store.setTaskbarWorkAreaHeights([:])
            for panel in panels.values {
                panel.orderOut(nil)
            }
            return
        }

        let presentation = TaskbarPresentationBuilder.build(
            state: state, preferences: preferencesStore.values)
        let taskbarHeight = preferencesStore.values.density.panelHeight
        store.setTaskbarWorkAreaHeights(
            Dictionary(
                uniqueKeysWithValues: presentation.displays.map {
                    ($0.identifier, taskbarHeight)
                }))

        let displayIDs = Set(presentation.displays.map(\.identifier))
        for display in presentation.displays {
            let panel: TaskbarPanel
            if let existing = panels[display.identifier] {
                panel = existing
            } else {
                panel = TaskbarPanel(
                    frame: TaskbarPanelLayout.frame(
                        for: display, height: preferencesStore.values.density.panelHeight),
                    onActivate: { [weak self] item in
                        self?.handlePrimaryClick(item)
                    },
                    onClose: { [weak self] item in
                        self?.store.execute(.close(item))
                    },
                    onWindowCommand: { [weak self] command in
                        guard let self else { return }
                        self.store.execute(
                            command,
                            excludingApplicationIdentities: Set(
                                self.preferencesStore.values.excludedApplications.map(\.identity)))
                    },
                    onApplicationCommand: { [weak self] command in
                        self?.execute(command)
                    },
                    onGlobalCommand: { [weak self] command in
                        self?.execute(command)
                    })
                panels[display.identifier] = panel
            }

            let frame = TaskbarPanelLayout.frame(
                for: display, height: preferencesStore.values.density.panelHeight)
            panel.update(
                frame: frame,
                entries: presentation.entriesByDisplay[display.identifier] ?? [],
                preferences: preferencesStore.values
            )
            if !panel.isVisible {
                panel.orderFrontRegardless()
            }
        }

        for (identifier, panel) in panels where !displayIDs.contains(identifier) {
            panel.orderOut(nil)
            panels.removeValue(forKey: identifier)
        }
    }

    private func refreshPermissionStatus() {
        let trusted = accessibilityProvider.isTrusted()
        store.setAccessibilityAvailable(trusted)
        settingsWindow?.refresh(
            accessibilityTrusted: trusted,
            preferences: preferencesStore.values,
            accessibilityRequestWasMade: permissionRequestState.didRequest
        )
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
        settingsWindow.onActiveWindowClickChanged = { [weak self] behavior in
            self?.preferencesStore.setActiveWindowClickBehavior(behavior)
        }
        settingsWindow.onOrderingChanged = { [weak self] mode in
            guard let self else { return }
            self.preferencesStore.setOrderingMode(mode)
            self.render(state: self.store.state)
        }
        settingsWindow.onLabelModeChanged = { [weak self] mode in
            guard let self else { return }
            self.preferencesStore.setLabelMode(mode)
            self.render(state: self.store.state)
        }
        settingsWindow.onDensityChanged = { [weak self] density in
            guard let self else { return }
            self.preferencesStore.setDensity(density)
            self.render(state: self.store.state)
        }
        settingsWindow.onButtonWidthChanged = { [weak self] buttonWidth in
            guard let self else { return }
            self.preferencesStore.setButtonWidth(buttonWidth)
            self.render(state: self.store.state)
        }
        settingsWindow.onOverflowBehaviorChanged = { [weak self] behavior in
            guard let self else { return }
            self.preferencesStore.setOverflowBehavior(behavior)
            self.render(state: self.store.state)
        }
        settingsWindow.onDisplayModeChanged = { [weak self] mode in
            guard let self else { return }
            self.preferencesStore.setDisplayMode(mode)
            self.render(state: self.store.state)
        }
        settingsWindow.onApplications = { [weak self] in
            self?.showApplicationsWindow()
        }
        settingsWindow.onClosed = { [weak self] in
            self?.preferencesStore.setOnboardingComplete(true)
            self?.restoreAccessoryActivationPolicy()
        }
        self.settingsWindow = settingsWindow
        return settingsWindow
    }

    private func restoreAccessoryActivationPolicy() {
        _ = settingsActivationState.apply(.close)
        NSApp.setActivationPolicy(.accessory)
    }

    private func showApplicationsWindow() {
        guard let settingsWindow else { return }
        let window = applicationsWindow ?? makeApplicationsWindow()
        window.refresh(preferences: preferencesStore.values)
        guard window.sheetParent == nil else { return }
        settingsWindow.beginSheet(window)
    }

    private func makeApplicationsWindow() -> ApplicationsManagementWindow {
        let window = ApplicationsManagementWindow()
        window.onUnpin = { [weak self, weak window] identity in
            guard let self else { return }
            self.preferencesStore.unpin(identity: identity)
            self.applicationPreferencesDidChange(window)
        }
        window.onRestore = { [weak self, weak window] identity in
            guard let self else { return }
            self.preferencesStore.restoreFromExclusions(identity: identity)
            self.applicationPreferencesDidChange(window)
        }
        window.onResetPins = { [weak self, weak window] in
            guard let self else { return }
            self.preferencesStore.resetPins()
            self.applicationPreferencesDidChange(window)
        }
        window.onResetExclusions = { [weak self, weak window] in
            guard let self else { return }
            self.preferencesStore.resetExclusions()
            self.applicationPreferencesDidChange(window)
        }
        applicationsWindow = window
        return window
    }

    private func applicationPreferencesDidChange(_ window: ApplicationsManagementWindow?) {
        window?.refresh(preferences: preferencesStore.values)
        render(state: store.state)
        refreshPermissionStatus()
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
        store.performPrimaryClick(
            item,
            activeWindowBehavior: preferencesStore.values.activeWindowClickBehavior)
    }

    private func execute(_ command: ApplicationCommand) {
        switch command {
        case .launch(let application):
            _ = applicationLauncher.launch(application)
        case .pin(let application):
            preferencesStore.pin(application)
        case .unpin(let identity):
            preferencesStore.unpin(identity: identity)
        case .exclude(let application):
            preferencesStore.exclude(application)
        case .restoreFromExclusions(let identity):
            preferencesStore.restoreFromExclusions(identity: identity)
        }
        render(state: store.state)
        refreshPermissionStatus()
    }

    private func execute(_ command: GlobalCommand) {
        switch command {
        case .setTaskbarsVisible(let visible):
            taskbarsVisible = visible
            statusItem?.menu?.items.first?.title = visible ? "Hide Taskbars" : "Show Taskbars"
            render(state: store.state)
        case .showSettings:
            showSettingsWindow()
        case .quit:
            NSApp.terminate(nil)
        }
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(
            systemSymbolName: "rectangle.bottomthird.inset.filled",
            accessibilityDescription: "TinyTaskbar")
        let menu = NSMenu()
        menu.addItem(
            withTitle: "Hide Taskbars",
            action: #selector(toggleTaskbars(_:)),
            keyEquivalent: "")
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

    @objc private func toggleTaskbars(_ sender: NSMenuItem) {
        taskbarsVisible.toggle()
        sender.title = taskbarsVisible ? "Hide Taskbars" : "Show Taskbars"
        render(state: store.state)
    }

    @objc private func openSettings(_: NSMenuItem) {
        showSettingsWindow()
    }

    @objc private func quitApplication(_: NSMenuItem) {
        NSApp.terminate(nil)
    }
}
