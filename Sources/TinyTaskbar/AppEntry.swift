import AppKit
import Foundation

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var provider: SystemWindowSnapshotProvider?
    private var store: TaskbarStore?
    private var eventObserver: SystemEventObserver?
    private var permissionController: AccessibilityPermissionController?
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

        let permissionController = AccessibilityPermissionController { [weak self] trusted in
            self?.store?.setAccessibilityAvailable(trusted)
        }
        self.permissionController = permissionController

        let eventObserver = SystemEventObserver { [weak store] in
            store?.requestRefresh()
        }
        eventObserver.start()
        self.eventObserver = eventObserver

        let trusted = permissionController.checkAndPromptIfNeeded()
        store.start(accessibilityTrusted: trusted)
    }

    func applicationWillTerminate(_: Notification) {
        eventObserver?.stop()
        store?.stop()
        for panel in panels.values {
            panel.orderOut(nil)
        }
        panels.removeAll()
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
            panel.update(frame: frame, items: state.itemsByDisplay[display.identifier] ?? [])
            panel.orderFrontRegardless()
        }

        for (identifier, panel) in panels where !displayIDs.contains(identifier) {
            panel.orderOut(nil)
            panels.removeValue(forKey: identifier)
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
