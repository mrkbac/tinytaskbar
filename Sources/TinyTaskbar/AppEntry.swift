import AppKit
import Foundation

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var provider: SystemWindowSnapshotProvider?
    private var store: TaskbarStore?
    private var eventObserver: SystemEventObserver?
    private let preferencesStore = TinyTaskbarPreferencesStore()
    private var permissionRequestState = AccessibilityPermissionRequestState()
    private var settingsWindow: TinyTaskbarSettingsWindow?
    private var panels: [String: TaskbarPanel] = [:]

    func applicationDidFinishLaunching(_: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let provider = SystemWindowSnapshotProvider()
        let store = TaskbarStore(provider: provider)
        self.provider = provider
        self.store = store

        provider.onChange = { [weak store] in
            store?.requestRefresh()
        }
        store.onStateChange = { [weak self] state in
            self?.render(state: state)
        }

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
        self.settingsWindow = settingsWindow

        let eventObserver = SystemEventObserver { [weak store] in
            store?.requestRefresh()
        }
        eventObserver.start()
        self.eventObserver = eventObserver

        let trusted = AXIsProcessTrusted()
        store.start(accessibilityTrusted: trusted)
        if !trusted || !preferencesStore.values.onboardingComplete {
            showSettingsWindow()
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
        store?.stop()
        for panel in panels.values {
            panel.orderOut(nil)
        }
        panels.removeAll()
        settingsWindow?.orderOut(nil)
    }

    private func render(state: TaskbarState) {
        guard store?.accessibilityAvailable == true else {
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
                    frame: display.appKitFrame,
                    onActivate: { [weak self] item in
                        self?.store?.activate(item)
                    })
                panels[display.identifier] = panel
            }

            let frame = panelFrame(for: display.appKitFrame)
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
        let trusted = AXIsProcessTrusted()
        store?.setAccessibilityAvailable(trusted)
        settingsWindow?.refresh(
            accessibilityTrusted: trusted,
            showsWindowTitles: preferencesStore.values.showsWindowTitles,
            accessibilityRequestWasMade: permissionRequestState.didRequest
        )
    }

    private func showSettingsWindow() {
        guard let settingsWindow else { return }
        refreshPermissionStatus()
        if !settingsWindow.isVisible {
            settingsWindow.center()
        }
        NSApp.activate()
        settingsWindow.makeKeyAndOrderFront(nil)
    }

    private func requestAccessibility() {
        if !AXIsProcessTrusted(),
            permissionRequestState.decision() == .request
        {
            // The SDK exports this documented key as mutable CF storage, which strict
            // concurrency correctly refuses to capture. Its public value is stable.
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
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
        if let state = store?.state {
            render(state: state)
        }
    }

    private func panelFrame(for screenFrame: NSRect) -> NSRect {
        let height: CGFloat = 42
        let horizontalInset: CGFloat = 8
        let bottomInset: CGFloat = 8
        return NSRect(
            x: screenFrame.minX + horizontalInset,
            y: screenFrame.minY + bottomInset,
            width: max(80, screenFrame.width - horizontalInset * 2),
            height: height
        )
    }
}
