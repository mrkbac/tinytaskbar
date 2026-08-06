import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import OSLog

@MainActor
protocol WindowSnapshotProvider: AnyObject {
    func snapshot() -> RawWindowSnapshot
    func activate(_ item: TaskbarItem)
}

struct RawWindowSnapshot: Equatable, Sendable {
    let candidates: [WindowCandidate]
    let cgWindows: [CGWindowMetadata]
    let displays: [DisplayDescriptor]
    let frontmostPID: Int32?
}

@MainActor
final class SystemWindowSnapshotProvider: WindowSnapshotProvider {
    private let logger = Logger(subsystem: "com.tinytaskbar", category: "accessibility")
    private let inspector = AXWindowInspector()
    private lazy var observerRegistry = AXObserverRegistry(logger: logger) { [weak self] in
        self?.onChange?()
    }
    private var axElementsByStableKey: [String: AXUIElement] = [:]

    var onChange: (@MainActor @Sendable () -> Void)?

    func snapshot() -> RawWindowSnapshot {
        let cgWindows = CGWindowReader.onScreenWindows()
        let displays = DisplayReader.current()
        let applications = NSWorkspace.shared.runningApplications.filter { application in
            application.activationPolicy == .regular && !application.isTerminated
                && application.processIdentifier != ProcessInfo.processInfo.processIdentifier
        }

        var candidates: [WindowCandidate] = []
        var observerRecords: [AXApplicationRecord] = []
        var nextElements: [String: AXUIElement] = [:]

        for application in applications {
            let records = inspector.enumerate(application)
            var elements: [String: AXUIElement] = [:]
            for record in records {
                candidates.append(record.candidate)
                let observerKey = observerKey(for: record.candidate, cgWindows: cgWindows)
                elements[observerKey] = record.element
                if let match = CGWindowMatcher.match(
                    candidate: record.candidate, windows: cgWindows)
                {
                    nextElements[
                        record.candidate.stableKey
                            ?? StableWindowKey.make(
                                candidate: record.candidate,
                                cgWindow: match
                            )] = record.element
                }
            }
            observerRecords.append(
                AXApplicationRecord(
                    pid: application.processIdentifier,
                    applicationElement: AXUIElementCreateApplication(application.processIdentifier),
                    windowElements: elements
                )
            )
        }

        observerRegistry.update(with: observerRecords)
        axElementsByStableKey = nextElements

        return RawWindowSnapshot(
            candidates: candidates,
            cgWindows: cgWindows,
            displays: displays,
            frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier
        )
    }

    func activate(_ item: TaskbarItem) {
        guard let element = axElementsByStableKey[item.id] else {
            logger.debug(
                "Activation skipped because AX reference is stale for \(item.id, privacy: .public)")
            return
        }

        // The snapshot can race a minimize or focus change. Each operation is best effort;
        // AX documents invalid references and unsupported attributes as ordinary failures.
        _ = AXUIElementSetAttributeValue(
            element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        if let application = NSRunningApplication(processIdentifier: item.pid) {
            _ = application.activate(options: [])
        }
        _ = AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
        _ = AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        _ = AXUIElementPerformAction(element, kAXRaiseAction as CFString)

        onChange?()
    }

    private func observerKey(
        for candidate: WindowCandidate,
        cgWindows: [CGWindowMetadata]
    ) -> String {
        guard let match = CGWindowMatcher.match(candidate: candidate, windows: cgWindows) else {
            let frame = candidate.frame ?? .zero
            let coordinates = [frame.minX, frame.minY, frame.width, frame.height]
                .map { String(Int($0.rounded())) }
                .joined(separator: ":")
            return
                "ax-observer:\(candidate.pid):\(CGWindowMatcher.normalized(candidate.title)):\(coordinates)"
        }
        return candidate.stableKey ?? StableWindowKey.make(candidate: candidate, cgWindow: match)
    }
}

@MainActor
private final class AXWindowInspector {
    private let mainDisplayBounds = CGDisplayBounds(CGMainDisplayID())

    func enumerate(_ application: NSRunningApplication) -> [AXWindowRecord] {
        let applicationElement = AXUIElementCreateApplication(application.processIdentifier)
        guard let rawWindows = copyAttribute(applicationElement, kAXWindowsAttribute) else {
            return []
        }

        let windows: [AXUIElement]
        if let typed = rawWindows as? [AXUIElement] {
            windows = typed
        } else if let array = rawWindows as? NSArray {
            windows = array.map { $0 as! AXUIElement }
        } else {
            return []
        }

        let applicationName =
            application.localizedName ?? application.bundleIdentifier ?? "Application"
        return windows.compactMap { element in
            guard let role = stringAttribute(element, kAXRoleAttribute),
                let subrole = stringAttribute(element, kAXSubroleAttribute),
                let position = pointAttribute(element, kAXPositionAttribute),
                let size = sizeAttribute(element, kAXSizeAttribute)
            else {
                return nil
            }

            let axFrame = CGRect(origin: position, size: size)
            let frame = convertAXFrameToQuartz(axFrame)
            let title = stringAttribute(element, kAXTitleAttribute) ?? ""
            let candidate = WindowCandidate(
                pid: application.processIdentifier,
                applicationName: applicationName,
                localizedApplicationName: applicationName,
                applicationIsRunning: !application.isTerminated,
                applicationIsRegular: application.activationPolicy == .regular,
                applicationIsHidden: application.isHidden,
                role: role,
                subrole: subrole,
                title: title,
                frame: frame,
                isHidden: boolAttribute(element, kAXHiddenAttribute) ?? false,
                isMinimized: boolAttribute(element, kAXMinimizedAttribute) ?? false,
                isFocused: boolAttribute(element, kAXFocusedAttribute) ?? false,
                isMain: boolAttribute(element, kAXMainAttribute) ?? false
            )
            return AXWindowRecord(candidate: candidate, element: element)
        }
    }

    private func convertAXFrameToQuartz(_ frame: CGRect) -> CGRect {
        // AX and CG both describe screen positions from the top-left. The main display
        // height is the public conversion anchor for AppKit's bottom-left coordinates.
        let quartzY = mainDisplayBounds.minY + mainDisplayBounds.height - frame.maxY
        return CGRect(x: frame.minX, y: quartzY, width: frame.width, height: frame.height)
    }

    private func copyAttribute(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        return error == .success ? value : nil
    }

    private func stringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        guard let value = copyAttribute(element, attribute) else { return nil }
        if let string = value as? String { return string }
        if let string = value as? NSString { return string as String }
        return nil
    }

    private func boolAttribute(_ element: AXUIElement, _ attribute: String) -> Bool? {
        guard let value = copyAttribute(element, attribute) else { return nil }
        return (value as? NSNumber)?.boolValue
    }

    private func pointAttribute(_ element: AXUIElement, _ attribute: String) -> CGPoint? {
        guard let value = copyAttribute(element, attribute),
            CFGetTypeID(value) == AXValueGetTypeID(),
            let axValue = value as! AXValue?,
            AXValueGetType(axValue) == .cgPoint
        else {
            return nil
        }
        var point = CGPoint.zero
        guard AXValueGetValue(axValue, .cgPoint, &point) else { return nil }
        return point
    }

    private func sizeAttribute(_ element: AXUIElement, _ attribute: String) -> CGSize? {
        guard let value = copyAttribute(element, attribute),
            CFGetTypeID(value) == AXValueGetTypeID(),
            let axValue = value as! AXValue?,
            AXValueGetType(axValue) == .cgSize
        else {
            return nil
        }
        var size = CGSize.zero
        guard AXValueGetValue(axValue, .cgSize, &size) else { return nil }
        return size
    }
}

@MainActor
private struct AXWindowRecord {
    let candidate: WindowCandidate
    let element: AXUIElement
}

@MainActor
private struct AXApplicationRecord {
    let pid: pid_t
    let applicationElement: AXUIElement
    let windowElements: [String: AXUIElement]
}

@MainActor
private final class AXObserverRegistry {
    private let logger: Logger
    private let onNotification: @MainActor @Sendable () -> Void
    private var observers: [pid_t: AXApplicationObserver] = [:]

    init(
        logger: Logger,
        onNotification: @escaping @MainActor @Sendable () -> Void
    ) {
        self.logger = logger
        self.onNotification = onNotification
    }

    func update(with records: [AXApplicationRecord]) {
        let activePIDs = Set(records.map(\.pid))
        let stalePIDs = observers.keys.filter { !activePIDs.contains($0) }
        for pid in stalePIDs {
            observers[pid]?.stop()
            observers.removeValue(forKey: pid)
        }

        for record in records {
            let observer: AXApplicationObserver
            if let existing = observers[record.pid] {
                observer = existing
            } else {
                guard
                    let created = AXApplicationObserver(
                        pid: record.pid,
                        applicationElement: record.applicationElement,
                        logger: logger,
                        onNotification: onNotification
                    )
                else {
                    continue
                }
                observers[record.pid] = created
                observer = created
            }
            observer.updateWindowElements(record.windowElements)
        }
    }
}

@MainActor
private final class AXApplicationObserver: @unchecked Sendable {
    private let pid: pid_t
    private let logger: Logger
    private let onNotification: @MainActor @Sendable () -> Void
    private var observer: AXObserver?
    private var applicationElement: AXUIElement
    private var windowElements: [String: AXUIElement] = [:]

    init?(
        pid: pid_t,
        applicationElement: AXUIElement,
        logger: Logger,
        onNotification: @escaping @MainActor @Sendable () -> Void
    ) {
        self.pid = pid
        self.applicationElement = applicationElement
        self.logger = logger
        self.onNotification = onNotification

        var createdObserver: AXObserver?
        let error = AXObserverCreate(
            pid,
            axObserverCallback,
            &createdObserver
        )
        guard error == .success, let createdObserver else { return nil }
        observer = createdObserver

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let appNotifications: [String] = [
            kAXWindowCreatedNotification,
            kAXUIElementDestroyedNotification,
            kAXFocusedWindowChangedNotification,
            kAXMainWindowChangedNotification,
            kAXApplicationHiddenNotification,
            kAXApplicationShownNotification,
        ]
        for notification in appNotifications {
            addNotification(notification, to: applicationElement, refcon: refcon)
        }

        let source = AXObserverGetRunLoopSource(createdObserver)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
    }

    func updateWindowElements(_ elements: [String: AXUIElement]) {
        guard let observer else { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let notifications: [String] = [
            kAXWindowMovedNotification,
            kAXWindowResizedNotification,
            kAXWindowMiniaturizedNotification,
            kAXWindowDeminiaturizedNotification,
            kAXTitleChangedNotification,
            kAXUIElementDestroyedNotification,
        ]

        for (key, element) in windowElements where elements[key] == nil {
            for notification in notifications {
                _ = AXObserverRemoveNotification(observer, element, notification as CFString)
            }
        }

        for (key, element) in elements where windowElements[key] == nil {
            for notification in notifications {
                addNotification(notification, to: element, refcon: refcon)
            }
        }
        windowElements = elements
    }

    func stop() {
        guard let observer else { return }
        let source = AXObserverGetRunLoopSource(observer)
        CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
        self.observer = nil
    }

    private func addNotification(
        _ notification: String,
        to element: AXUIElement,
        refcon: UnsafeMutableRawPointer
    ) {
        guard let observer else { return }
        let error = AXObserverAddNotification(observer, element, notification as CFString, refcon)
        if error != .success && error != .notificationAlreadyRegistered {
            logger.debug(
                "AX notification unavailable for pid \(self.pid, privacy: .public): \(notification, privacy: .public) (\(error.rawValue, privacy: .public))"
            )
        }
    }

    private func handleNotification() {
        onNotification()
    }

    nonisolated func notificationReceived() {
        Task { @MainActor [weak self] in
            self?.handleNotification()
        }
    }
}

private func axObserverCallback(
    _: AXObserver,
    _: AXUIElement,
    _: CFString,
    _ refcon: UnsafeMutableRawPointer?
) {
    guard let refcon else { return }
    let observer = Unmanaged<AXApplicationObserver>.fromOpaque(refcon).takeUnretainedValue()
    observer.notificationReceived()
}

enum CGWindowReader {
    static func onScreenWindows() -> [CGWindowMetadata] {
        guard
            let rawWindows = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements],
                kCGNullWindowID
            ) as? [[String: Any]]
        else {
            return []
        }

        return rawWindows.compactMap { dictionary in
            guard let ownerPID = (dictionary[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                let layer = (dictionary[kCGWindowLayer as String] as? NSNumber)?.intValue,
                let rawBounds = dictionary[kCGWindowBounds as String] as? NSDictionary
            else {
                return nil
            }

            var bounds = CGRect.zero
            guard CGRectMakeWithDictionaryRepresentation(rawBounds as CFDictionary, &bounds) else {
                return nil
            }

            let windowNumber = (dictionary[kCGWindowNumber as String] as? NSNumber)
                .map { UInt32(clamping: $0.int64Value) }
            let title = dictionary[kCGWindowName as String] as? String ?? ""
            let isOnScreen =
                (dictionary[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false
            return CGWindowMetadata(
                windowNumber: windowNumber,
                ownerPID: ownerPID,
                layer: layer,
                bounds: bounds,
                title: title,
                isOnScreen: isOnScreen
            )
        }
    }
}

enum DisplayReader {
    static func current() -> [DisplayDescriptor] {
        NSScreen.screens.enumerated().map { ordinal, screen in
            let displayNumber =
                screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            let displayID =
                displayNumber.map { CGDirectDisplayID($0.uint32Value) } ?? CGMainDisplayID()
            return DisplayDescriptor(
                identifier: "display:\(displayID):\(ordinal)",
                frame: CGDisplayBounds(displayID),
                appKitFrame: screen.frame,
                ordinal: ordinal
            )
        }
    }
}
