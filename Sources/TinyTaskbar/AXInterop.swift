import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import OSLog

@MainActor
protocol WindowSnapshotProvider: AnyObject {
    var onChange: (@MainActor @Sendable () -> Void)? { get set }
    func snapshot() -> RawWindowSnapshot
    func activate(_ item: TaskbarItem)
}

@MainActor
protocol AccessibilityPermissionProvider: AnyObject {
    func isTrusted() -> Bool
    func requestAccess() -> Bool
}

@MainActor
final class SystemAccessibilityPermissionProvider: AccessibilityPermissionProvider {
    func isTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    func requestAccess() -> Bool {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }
}

struct RawWindowSnapshot: Equatable, Sendable {
    let candidates: [WindowCandidate]
    let cgWindows: [CGWindowMetadata]
    let displays: [DisplayDescriptor]
    let frontmostPID: Int32?
}

enum AXMessagingPolicy {
    /// Bounds a single synchronous AX request so one unresponsive process cannot
    /// indefinitely block TinyTaskbar's main-actor refresh path.
    static let timeoutSeconds: Float = 0.25
}

@MainActor
final class SystemWindowSnapshotProvider: WindowSnapshotProvider {
    private let logger = Logger(subsystem: "com.tinytaskbar", category: "accessibility")
    private lazy var inspector = AXWindowInspector(logger: logger)
    private lazy var observerRegistry = AXObserverRegistry(logger: logger) { [weak self] in
        self?.onChange?()
    }
    private var axElementsByStableKey: [String: AXUIElement] = [:]

    var onChange: (@MainActor @Sendable () -> Void)?

    init() {
        let error = AXUIElementSetMessagingTimeout(
            AXUIElementCreateSystemWide(),
            AXMessagingPolicy.timeoutSeconds
        )
        if error != .success {
            logger.error(
                "could not set AX messaging timeout error=\(error.rawValue, privacy: .public)"
            )
        }
    }

    func snapshot() -> RawWindowSnapshot {
        let cgWindows = CGWindowReader.onScreenWindows()
        let displays = DisplayReader.current()
        let applications = NSWorkspace.shared.runningApplications.filter { application in
            application.activationPolicy == .regular && !application.isTerminated
                && application.processIdentifier != ProcessInfo.processInfo.processIdentifier
        }

        var candidates: [WindowCandidate] = []
        var applicationInputs: [AXApplicationInput] = []
        var allRecords: [AXWindowRecord] = []
        var nextElements: [String: AXUIElement] = [:]

        for application in applications {
            let records = inspector.enumerate(application)
            let startIndex = allRecords.count
            allRecords.append(contentsOf: records)
            candidates.append(contentsOf: records.map(\.candidate))
            applicationInputs.append(
                AXApplicationInput(
                    pid: application.processIdentifier,
                    applicationElement: AXUIElementCreateApplication(application.processIdentifier),
                    records: records,
                    startIndex: startIndex
                )
            )
        }

        let assignments = WindowCGAssignment.assign(
            candidates: candidates,
            cgWindows: cgWindows,
            selfPID: ProcessInfo.processInfo.processIdentifier
        )
        for (candidateIndex, record) in allRecords.enumerated() {
            guard let cgWindowIndex = assignments[candidateIndex] else { continue }
            let cgWindow = cgWindows[cgWindowIndex]
            let key = WindowObservationKey.itemKey(
                candidate: record.candidate,
                cgWindow: cgWindow
            )
            nextElements[key] = record.element
        }

        let observerRecords = applicationInputs.map { input in
            var elements: [String: AXUIElement] = [:]
            for (ordinal, record) in input.records.enumerated() {
                let candidateIndex = input.startIndex + ordinal
                let cgWindow = assignments[candidateIndex].map { cgWindows[$0] }
                let key = WindowObservationKey.observerKey(
                    candidate: record.candidate,
                    cgWindow: cgWindow,
                    ordinal: ordinal
                )
                elements[key] = record.element
            }
            return AXApplicationRecord(
                pid: input.pid,
                applicationElement: input.applicationElement,
                windowElements: elements
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
        var failures: [String] = []
        let minimizeError = AXUIElementSetAttributeValue(
            element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        if minimizeError != .success {
            failures.append("unminimize=\(minimizeError.rawValue)")
        }
        if let application = NSRunningApplication(processIdentifier: item.pid) {
            if !application.activate(options: []) {
                failures.append("activate=false")
            }
        } else {
            failures.append("application=missing")
        }
        let mainError = AXUIElementSetAttributeValue(
            element, kAXMainAttribute as CFString, kCFBooleanTrue)
        if mainError != .success {
            failures.append("main=\(mainError.rawValue)")
        }
        let focusError = AXUIElementSetAttributeValue(
            element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        if focusError != .success {
            failures.append("focus=\(focusError.rawValue)")
        }
        let raiseError = AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        if raiseError != .success {
            failures.append("raise=\(raiseError.rawValue)")
        }
        if !failures.isEmpty {
            let summary = failures.joined(separator: ",")
            logger.debug(
                "activation completed with failures pid=\(item.pid, privacy: .public) operations=\(summary, privacy: .public)"
            )
        }

        onChange?()
    }
}

@MainActor
private final class AXWindowInspector {
    private static let windowAttributes: [String] = [
        kAXRoleAttribute,
        kAXSubroleAttribute,
        kAXPositionAttribute,
        kAXSizeAttribute,
        kAXTitleAttribute,
        kAXHiddenAttribute,
        kAXMinimizedAttribute,
        kAXFocusedAttribute,
        kAXMainAttribute,
    ]

    private let logger: Logger

    init(logger: Logger) {
        self.logger = logger
    }

    func enumerate(_ application: NSRunningApplication) -> [AXWindowRecord] {
        let applicationElement = AXUIElementCreateApplication(application.processIdentifier)
        var rawWindows: CFTypeRef?
        let windowListError = AXUIElementCopyAttributeValue(
            applicationElement,
            kAXWindowsAttribute as CFString,
            &rawWindows
        )
        guard windowListError == .success, let rawWindows else {
            logger.debug(
                "AX window list unavailable pid=\(application.processIdentifier, privacy: .public) error=\(windowListError.rawValue, privacy: .public)"
            )
            return []
        }

        let windows: [AXUIElement]
        if let typed = rawWindows as? [AXUIElement] {
            windows = typed
        } else if let array = rawWindows as? NSArray {
            windows = array.compactMap { value in
                let cfValue = value as CFTypeRef
                guard CFGetTypeID(cfValue) == AXUIElementGetTypeID()
                else {
                    return nil
                }
                return (cfValue as! AXUIElement)
            }
        } else {
            return []
        }

        let applicationName =
            application.localizedName ?? application.bundleIdentifier ?? "Application"
        let applicationIdentity =
            application.bundleIdentifier
            ?? application.bundleURL?.standardizedFileURL.path
            ?? application.executableURL?.standardizedFileURL.path
        var records: [AXWindowRecord] = []
        var batchFailures: [Int32: Int] = [:]
        var malformedCount = 0

        for element in windows {
            var rawValues: CFArray?
            let error = AXUIElementCopyMultipleAttributeValues(
                element,
                Self.windowAttributes as CFArray,
                [],
                &rawValues
            )
            guard error == .success,
                let values = rawValues as? [Any],
                values.count == Self.windowAttributes.count
            else {
                batchFailures[error.rawValue, default: 0] += 1
                continue
            }

            guard let role = stringValue(values[0]),
                let subrole = stringValue(values[1]),
                let position = pointValue(values[2]),
                let size = sizeValue(values[3])
            else {
                malformedCount += 1
                continue
            }

            let axFrame = CGRect(origin: position, size: size)
            let candidate = WindowCandidate(
                pid: application.processIdentifier,
                applicationName: applicationName,
                applicationIdentity: applicationIdentity,
                localizedApplicationName: applicationName,
                applicationIsRunning: !application.isTerminated,
                applicationIsRegular: application.activationPolicy == .regular,
                applicationIsHidden: application.isHidden,
                role: role,
                subrole: subrole,
                title: stringValue(values[4]) ?? "",
                frame: AXScreenCoordinateMapper.toCGScreen(axFrame),
                isHidden: boolValue(values[5]) ?? false,
                isMinimized: boolValue(values[6]) ?? false,
                isFocused: boolValue(values[7]) ?? false,
                isMain: boolValue(values[8]) ?? false
            )
            records.append(AXWindowRecord(candidate: candidate, element: element))
        }

        if !batchFailures.isEmpty || malformedCount > 0 {
            let errors = batchFailures.keys.sorted().map { code in
                "\(code):\(batchFailures[code] ?? 0)"
            }.joined(separator: ",")
            logger.debug(
                "AX window attributes skipped pid=\(application.processIdentifier, privacy: .public) batch_errors=\(errors, privacy: .public) malformed=\(malformedCount, privacy: .public)"
            )
        }
        return records
    }

    private func stringValue(_ value: Any) -> String? {
        if let string = value as? String { return string }
        if let string = value as? NSString { return string as String }
        return nil
    }

    private func boolValue(_ value: Any) -> Bool? {
        (value as? NSNumber)?.boolValue
    }

    private func pointValue(_ value: Any) -> CGPoint? {
        let cfValue = value as CFTypeRef
        guard CFGetTypeID(cfValue) == AXValueGetTypeID(),
            let axValue = cfValue as! AXValue?,
            AXValueGetType(axValue) == .cgPoint
        else {
            return nil
        }
        var point = CGPoint.zero
        guard AXValueGetValue(axValue, .cgPoint, &point) else { return nil }
        return point
    }

    private func sizeValue(_ value: Any) -> CGSize? {
        let cfValue = value as CFTypeRef
        guard CFGetTypeID(cfValue) == AXValueGetTypeID(),
            let axValue = cfValue as! AXValue?,
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
private struct AXApplicationInput {
    let pid: pid_t
    let applicationElement: AXUIElement
    let records: [AXWindowRecord]
    let startIndex: Int
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
                appKitVisibleFrame: screen.visibleFrame,
                ordinal: ordinal
            )
        }
    }
}
