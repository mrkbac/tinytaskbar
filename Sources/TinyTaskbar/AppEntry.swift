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
    private let skipsOnboarding: Bool
    private var eventObserver: SystemEventObserver?
    private let preferencesStore = TinyTaskbarPreferencesStore()
    private var permissionRequestState = AccessibilityPermissionRequestState()
    private var settingsActivationState = SettingsActivationPolicyState()
    private var settingsWindow: TinyTaskbarSettingsWindow?
    private var panels: [String: TaskbarPanel] = [:]

    static func makeDefault() -> AppDelegate {
        #if DEBUG
            if let fixture = DebugFixture.parse(arguments: CommandLine.arguments) {
                return AppDelegate(
                    accessibilityProvider: DebugFixturePermissionProvider(),
                    provider: DebugFixtureWindowSnapshotProvider(fixture: fixture),
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
        skipsOnboarding: Bool = false
    ) {
        self.accessibilityProvider = accessibilityProvider
        self.provider = provider
        self.store = TaskbarStore(provider: provider)
        self.skipsOnboarding = skipsOnboarding
        super.init()
    }

    func applicationDidFinishLaunching(_: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let provider = self.provider
        let store = self.store
        provider.onChange = { [weak store] in
            store?.requestRefresh()
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
    }

    private func render(state: TaskbarState) {
        guard store.accessibilityAvailable else {
            for panel in panels.values {
                panel.orderOut(nil)
            }
            return
        }

        let displayIDs = Set(state.displays.map(\.identifier))
        for display in state.displays {
            let panel: TaskbarPanel
            if let existing = panels[display.identifier] {
                panel = existing
            } else {
                panel = TaskbarPanel(
                    frame: TaskbarPanelLayout.frame(for: display),
                    onActivate: { [weak self] item in
                        self?.store.activate(item)
                    })
                panels[display.identifier] = panel
            }

            let frame = TaskbarPanelLayout.frame(for: display)
            panel.update(
                frame: frame,
                items: state.itemsByDisplay[display.identifier] ?? [],
                showsWindowTitles: preferencesStore.values.showsWindowTitles
            )
            panel.orderFrontRegardless()
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
            showsWindowTitles: preferencesStore.values.showsWindowTitles,
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
        settingsWindow.onShowsWindowTitlesChanged = { [weak self] shows in
            self?.setShowsWindowTitles(shows)
        }
        settingsWindow.onDone = { [weak self] in
            self?.finishOnboarding()
        }
        settingsWindow.onQuit = {
            NSApp.terminate(nil)
        }
        settingsWindow.onClosed = { [weak self] in
            self?.restoreAccessoryActivationPolicy()
        }
        self.settingsWindow = settingsWindow
        return settingsWindow
    }

    private func restoreAccessoryActivationPolicy() {
        _ = settingsActivationState.apply(.close)
        NSApp.setActivationPolicy(.accessory)
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

    private func finishOnboarding() {
        preferencesStore.setOnboardingComplete(true)
        settingsWindow?.close()
    }

    private func setShowsWindowTitles(_ shows: Bool) {
        preferencesStore.setShowsWindowTitles(shows)
        render(state: store.state)
    }
}
