import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import OSLog

// Accessibility has no supported public AX-to-CG identity bridge. TinyTaskbar uses this
// single private symbol so already-minimized windows can be joined to their exact public
// Core Graphics records without title/frame guesses. Keep all Space management on public
// APIs; this declaration is intentionally isolated for compatibility review.
@_silgen_name("_AXUIElementGetWindow")
private func axUIElementGetWindowID(
    _ element: AXUIElement,
    _ identifier: UnsafeMutablePointer<CGWindowID>
) -> AXError

private struct AXPhysicalWindowIdentity: Hashable {
    let pid: Int32
    let cgWindowNumber: UInt32
}

enum ActionableReferenceContinuity {
    static func resolve<Key: Hashable, Reference>(
        current: [Key: Reference],
        previous: [Key: Reference],
        liveKeys: Set<Key>,
        ambiguousKeys: Set<Key>
    ) -> [Key: Reference] {
        var resolved = current
        for (key, reference) in previous
        where liveKeys.contains(key)
            && !ambiguousKeys.contains(key)
            && resolved[key] == nil
        {
            resolved[key] = reference
        }
        return resolved
    }
}

enum WindowSnapshotChange: Equatable, Sendable {
    case ordinary
    case windowDestroyed
}

@MainActor
protocol WindowSnapshotProvider: AnyObject {
    var onChange: (@MainActor @Sendable (WindowSnapshotChange) -> Void)? { get set }
    func snapshot() -> RawWindowSnapshot
    func activate(_ item: TaskbarItem)
    func selectTab(_ tab: TaskbarTab, in item: TaskbarItem)
    func closeTab(_ tab: TaskbarTab, in item: TaskbarItem)
    func closeTabGroup(_ item: TaskbarItem)
    func minimize(_ item: TaskbarItem)
    func close(_ item: TaskbarItem)
    @discardableResult
    func setHeight(_ height: CGFloat, for item: TaskbarItem) -> Bool
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

struct WindowSnapshotEvidence: Equatable, Sendable {
    let isComplete: Bool
    let knownApplicationPIDs: Set<Int32>
    let axWindowListReadPIDs: Set<Int32>
    let observedAXWindowIDs: Set<String>

    init(
        isComplete: Bool = false,
        knownApplicationPIDs: Set<Int32> = [],
        axWindowListReadPIDs: Set<Int32> = [],
        observedAXWindowIDs: Set<String> = []
    ) {
        self.isComplete = isComplete
        self.knownApplicationPIDs = knownApplicationPIDs
        self.axWindowListReadPIDs = axWindowListReadPIDs
        self.observedAXWindowIDs = observedAXWindowIDs
    }

    static let unknown = WindowSnapshotEvidence()
}

struct RawWindowSnapshot: Equatable, Sendable {
    let candidates: [WindowCandidate]
    let cgWindows: [CGWindowMetadata]
    let cgAssignments: [Int: Int]?
    let displays: [DisplayDescriptor]
    let frontmostPID: Int32?
    let evidence: WindowSnapshotEvidence

    init(
        candidates: [WindowCandidate],
        cgWindows: [CGWindowMetadata],
        cgAssignments: [Int: Int]? = nil,
        displays: [DisplayDescriptor],
        frontmostPID: Int32?,
        evidence: WindowSnapshotEvidence = .unknown
    ) {
        self.candidates = candidates
        self.cgWindows = cgWindows
        self.cgAssignments = cgAssignments
        self.displays = displays
        self.frontmostPID = frontmostPID
        self.evidence = evidence
    }
}

enum AXMessagingPolicy {
    /// Bounds a single synchronous AX request so one unresponsive process cannot
    /// indefinitely block TinyTaskbar's main-actor refresh path.
    static let timeoutSeconds: Float = 0.25
}

struct WindowElementIdentityRegistry<Element> {
    private struct Entry {
        let element: Element
        let identifier: String
        var lastSeenGeneration: UInt64
    }

    private var entriesByNamespace: [String: [Entry]] = [:]
    private var generation: UInt64 = 0
    private var nextIdentifier: UInt64 = 0
    private let elementsEqual: (Element, Element) -> Bool

    init(elementsEqual: @escaping (Element, Element) -> Bool) {
        self.elementsEqual = elementsEqual
    }

    mutating func beginSnapshot() {
        generation &+= 1
    }

    mutating func identifier(for element: Element, namespace: String) -> String {
        var entries = entriesByNamespace[namespace] ?? []
        if let index = entries.firstIndex(where: { elementsEqual($0.element, element) }) {
            entries[index].lastSeenGeneration = generation
            let identifier = entries[index].identifier
            entriesByNamespace[namespace] = entries
            return identifier
        }

        nextIdentifier &+= 1
        let identifier = "ax-window:\(namespace):\(nextIdentifier)"
        entries.append(
            Entry(
                element: element,
                identifier: identifier,
                lastSeenGeneration: generation
            )
        )
        entriesByNamespace[namespace] = entries
        return identifier
    }

    mutating func endSnapshot() {
        let oldestRetainedGeneration = generation > 1 ? generation - 1 : 0
        entriesByNamespace = entriesByNamespace.compactMapValues { entries in
            let retained = entries.filter {
                $0.lastSeenGeneration >= oldestRetainedGeneration
            }
            return retained.isEmpty ? nil : retained
        }
    }
}

@MainActor
enum NativeTabSelectionSequence {
    @discardableResult
    static func perform(
        activateGroup: () -> Void,
        refreshGroup: () -> Void,
        pressTab: () -> AXError,
        refresh: () -> Void
    ) -> AXError {
        activateGroup()
        refreshGroup()
        let error = pressTab()
        if error == .success {
            refresh()
        }
        return error
    }
}

enum WindowActivationStep: Equatable {
    case unminimize
    case makeMain
    case makeFocusedWindow
    case activateApplication
    case focus
    case raise
}

enum WindowActivationSequence {
    static let steps: [WindowActivationStep] = [
        .unminimize,
        .makeMain,
        .makeFocusedWindow,
        .activateApplication,
        .focus,
        .raise,
    ]
}

enum NativeTabSelectionTarget {
    static func resolve<Element>(
        stableElement: Element?,
        currentElements: [Element],
        index: Int
    ) -> Element? {
        if let stableElement { return stableElement }
        guard currentElements.indices.contains(index) else { return nil }
        return currentElements[index]
    }
}

enum AXActionSupport {
    static func contains(_ action: String, in advertisedActions: [String]) -> Bool {
        advertisedActions.contains(action)
    }
}

@MainActor
final class SystemWindowSnapshotProvider: WindowSnapshotProvider {
    private let logger = Logger(subsystem: "com.tinytaskbar", category: "accessibility")
    private lazy var inspector = AXWindowInspector(logger: logger)
    private lazy var observerRegistry = AXObserverRegistry(logger: logger) {
        [weak self] notification in
        self?.onChange?(
            notification == kAXUIElementDestroyedNotification ? .windowDestroyed : .ordinary)
    }
    private var identityRegistry = WindowElementIdentityRegistry<AXUIElement> {
        CFEqual($0, $1)
    }
    private var tabGroupIdentityRegistry = WindowElementIdentityRegistry<AXUIElement> {
        CFEqual($0, $1)
    }
    private var tabIdentityRegistry = WindowElementIdentityRegistry<AXUIElement> {
        CFEqual($0, $1)
    }
    private var axElementsByStableKey: [String: AXUIElement] = [:]
    private var axElementsByPhysicalIdentity: [AXPhysicalWindowIdentity: AXUIElement] = [:]
    private var axTabElementsByID: [String: AXUIElement] = [:]
    private var axTabElementsByGroupID: [String: [AXUIElement]] = [:]
    private var axTabGroupsByPID: [Int32: [[AXUIElement]]] = [:]
    private var axWindowElementsByGroupID: [String: [AXUIElement]] = [:]
    private var axWindowGroupsByPID: [Int32: [[AXUIElement]]] = [:]

    var onChange: (@MainActor @Sendable (WindowSnapshotChange) -> Void)?

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
        identityRegistry.beginSnapshot()
        tabGroupIdentityRegistry.beginSnapshot()
        tabIdentityRegistry.beginSnapshot()
        defer {
            identityRegistry.endSnapshot()
            tabGroupIdentityRegistry.endSnapshot()
            tabIdentityRegistry.endSnapshot()
        }
        let cgWindows = CGWindowReader.allWindows()
        let displays = DisplayReader.current()
        let applications = NSWorkspace.shared.runningApplications.filter { application in
            application.activationPolicy == .regular && !application.isTerminated
                && application.processIdentifier != ProcessInfo.processInfo.processIdentifier
        }
        let knownApplicationPIDs = Set(applications.map(\.processIdentifier))

        var candidates: [WindowCandidate] = []
        var applicationInputs: [AXApplicationInput] = []
        var allRecords: [AXWindowRecord] = []
        var nextElements: [String: AXUIElement] = [:]
        var nextTabElements: [String: AXUIElement] = [:]
        var nextTabElementsByGroupID: [String: [AXUIElement]] = [:]
        var nextTabGroupsByPID: [Int32: [[AXUIElement]]] = [:]
        var nextWindowElementsByGroupID: [String: [AXUIElement]] = [:]
        var nextWindowGroupsByPID: [Int32: [String: [AXUIElement]]] = [:]
        var nextPhysicalElements: [AXPhysicalWindowIdentity: AXUIElement] = [:]
        var ambiguousPhysicalIdentities: Set<AXPhysicalWindowIdentity> = []
        var axWindowListReadPIDs: Set<Int32> = []
        var observedAXWindowIDs: Set<String> = []

        for application in applications {
            let namespace = String(application.processIdentifier)
            let enumeration = inspector.enumerate(
                application,
                stableKeyForElement: { [unowned self] element in
                    identityRegistry.identifier(for: element, namespace: namespace)
                },
                stableKeyForTabGroup: { [unowned self] element in
                    tabGroupIdentityRegistry.identifier(
                        for: element,
                        namespace: "tab-group:\(namespace)"
                    )
                },
                stableKeyForTab: { [unowned self] element in
                    tabIdentityRegistry.identifier(
                        for: element,
                        namespace: "tab:\(namespace)"
                    )
                }
            )
            if enumeration.didReadWindowList {
                axWindowListReadPIDs.insert(application.processIdentifier)
            }
            observedAXWindowIDs.formUnion(enumeration.observedWindowIDs)
            let records = enumeration.records
            for record in records {
                nextTabElements.merge(record.tabElementsByID) { current, _ in current }
                if let groupID = record.candidate.nativeTabGroupID,
                    !record.tabElements.isEmpty
                {
                    nextTabElementsByGroupID[groupID] = record.tabElements
                    nextTabGroupsByPID[record.candidate.pid, default: []].append(
                        record.tabElements)
                }
                if let groupID = record.candidate.nativeTabGroupID {
                    nextWindowElementsByGroupID[groupID, default: []].append(record.element)
                    nextWindowGroupsByPID[record.candidate.pid, default: [:]][
                        groupID, default: []
                    ].append(record.element)
                }
            }
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
        let eligibility = WindowEligibility()
        for (candidateIndex, record) in allRecords.enumerated() {
            let cgWindow = assignments[candidateIndex].map { cgWindows[$0] }
            guard
                record.candidate.isNativeTabGroupRepresentative,
                eligibility.isEligible(
                    record.candidate,
                    selfPID: ProcessInfo.processInfo.processIdentifier
                )
            else {
                continue
            }
            let key = WindowObservationKey.itemKey(
                candidate: record.candidate,
                cgWindow: cgWindow
            )
            nextElements[key] = record.element
            if let cgWindowNumber = record.candidate.cgWindowNumber {
                let identity = AXPhysicalWindowIdentity(
                    pid: record.candidate.pid,
                    cgWindowNumber: cgWindowNumber)
                if nextPhysicalElements.removeValue(forKey: identity) != nil {
                    ambiguousPhysicalIdentities.insert(identity)
                } else if !ambiguousPhysicalIdentities.contains(identity) {
                    nextPhysicalElements[identity] = record.element
                }
            }
        }

        let livePhysicalIdentities = Set(
            cgWindows.compactMap { window -> AXPhysicalWindowIdentity? in
                guard window.layer == 0,
                    knownApplicationPIDs.contains(window.ownerPID),
                    let windowNumber = window.windowNumber
                else { return nil }
                return AXPhysicalWindowIdentity(
                    pid: window.ownerPID,
                    cgWindowNumber: windowNumber)
            })
        // A transient AX timeout can yield no record for a still-live window. State
        // continuity intentionally keeps its button; keep the matching actionable
        // reference too, but only while the exact public physical identity remains
        // unique and live. A successful later enumeration replaces this reference.
        nextPhysicalElements = ActionableReferenceContinuity.resolve(
            current: nextPhysicalElements,
            previous: axElementsByPhysicalIdentity,
            liveKeys: livePhysicalIdentities,
            ambiguousKeys: ambiguousPhysicalIdentities)

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
        axElementsByPhysicalIdentity = nextPhysicalElements
        axTabElementsByID = nextTabElements
        axTabElementsByGroupID = nextTabElementsByGroupID
        axTabGroupsByPID = nextTabGroupsByPID
        axWindowElementsByGroupID = nextWindowElementsByGroupID
        axWindowGroupsByPID = nextWindowGroupsByPID.mapValues { Array($0.values) }

        return RawWindowSnapshot(
            candidates: candidates,
            cgWindows: cgWindows,
            cgAssignments: assignments,
            displays: displays,
            frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier,
            evidence: WindowSnapshotEvidence(
                isComplete: true,
                knownApplicationPIDs: knownApplicationPIDs,
                axWindowListReadPIDs: axWindowListReadPIDs,
                observedAXWindowIDs: observedAXWindowIDs
            )
        )
    }

    func activate(_ item: TaskbarItem) {
        let application = NSRunningApplication(processIdentifier: item.pid)
        if application?.isHidden == true, application?.unhide() != true {
            logger.debug(
                "Unhide failed pid=\(item.pid, privacy: .public)"
            )
        }
        guard let element = actionableElement(for: item) else {
            logger.debug(
                "Activation skipped because AX reference is stale for \(item.id, privacy: .public)")
            return
        }

        // Prepare the selected window before activating its application. AppKit activation
        // then brings forward only that main/key window; an app-wide AXFrontmost write here
        // can promote sibling windows too (notably separate Chrome windows).
        //
        // The snapshot can race a minimize or focus change. Each operation is best effort;
        // AX documents invalid references and unsupported attributes as ordinary failures.
        var failures: [String] = []
        let applicationElement = AXUIElementCreateApplication(item.pid)
        for step in WindowActivationSequence.steps {
            switch step {
            case .unminimize:
                let error = AXUIElementSetAttributeValue(
                    element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
                if error != .success {
                    failures.append("unminimize=\(error.rawValue)")
                }
            case .makeMain:
                let error = AXUIElementSetAttributeValue(
                    element, kAXMainAttribute as CFString, kCFBooleanTrue)
                if error != .success {
                    failures.append("main=\(error.rawValue)")
                }
            case .makeFocusedWindow:
                var isSettable = DarwinBoolean(false)
                let settableError = AXUIElementIsAttributeSettable(
                    applicationElement,
                    kAXFocusedWindowAttribute as CFString,
                    &isSettable
                )
                if settableError == .success, isSettable.boolValue {
                    let error = AXUIElementSetAttributeValue(
                        applicationElement,
                        kAXFocusedWindowAttribute as CFString,
                        element
                    )
                    if error != .success {
                        failures.append("focused_window=\(error.rawValue)")
                    }
                } else if settableError != .success {
                    failures.append("focused_window_settable=\(settableError.rawValue)")
                } else {
                    failures.append("focused_window=not_settable")
                }
            case .activateApplication:
                if let application {
                    if !application.activate(options: []) {
                        failures.append("activate=false")
                    }
                } else {
                    failures.append("application=missing")
                }
            case .focus:
                let error = AXUIElementSetAttributeValue(
                    element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
                if error != .success {
                    failures.append("focus=\(error.rawValue)")
                }
            case .raise:
                let error = AXUIElementPerformAction(element, kAXRaiseAction as CFString)
                if error != .success {
                    failures.append("raise=\(error.rawValue)")
                }
            }
        }
        if !failures.isEmpty {
            let summary = failures.joined(separator: ",")
            logger.debug(
                "activation completed with failures pid=\(item.pid, privacy: .public) operations=\(summary, privacy: .public)"
            )
        }

        onChange?(.ordinary)
    }

    func selectTab(_ tab: TaskbarTab, in item: TaskbarItem) {
        var foundCurrentElement = false
        let pressError = NativeTabSelectionSequence.perform(
            activateGroup: { activate(item) },
            refreshGroup: { _ = snapshot() },
            pressTab: {
                let elementsForGroup = item.nativeTabGroupID.flatMap {
                    axTabElementsByGroupID[$0]
                }
                let groupsForPID = axTabGroupsByPID[item.pid] ?? []
                let currentElements =
                    elementsForGroup ?? (groupsForPID.count == 1 ? groupsForPID[0] : [])
                guard
                    let tabElement = NativeTabSelectionTarget.resolve(
                        stableElement: axTabElementsByID[tab.id],
                        currentElements: currentElements,
                        index: tab.index)
                else { return .invalidUIElement }
                foundCurrentElement = true
                return AXUIElementPerformAction(tabElement, kAXPressAction as CFString)
            },
            refresh: { onChange?(.ordinary) }
        )
        if !foundCurrentElement {
            logger.debug(
                "Tab selection stopped because no current AX element exists for \(tab.id, privacy: .public)"
            )
        } else if pressError != .success {
            logger.debug(
                "Tab selection failed pid=\(item.pid, privacy: .public) error=\(pressError.rawValue, privacy: .public)"
            )
        }
    }

    func closeTab(_ tab: TaskbarTab, in item: TaskbarItem) {
        _ = snapshot()
        let currentElements = currentTabElements(for: item)
        guard
            let tabElement = NativeTabSelectionTarget.resolve(
                stableElement: axTabElementsByID[tab.id],
                currentElements: currentElements,
                index: tab.index)
        else {
            logger.debug(
                "Tab close stopped because no current AX element exists for \(tab.id, privacy: .public)"
            )
            return
        }

        let exposesAlternateUI = supportsAction(
            kAXShowAlternateUIAction as String,
            on: tabElement)
        if exposesAlternateUI {
            _ = AXUIElementPerformAction(
                tabElement,
                kAXShowAlternateUIAction as CFString)
        }
        defer {
            if exposesAlternateUI,
                supportsAction(kAXShowDefaultUIAction as String, on: tabElement)
            {
                _ = AXUIElementPerformAction(
                    tabElement,
                    kAXShowDefaultUIAction as CFString)
            }
        }
        guard let closeButton = tabCloseButton(for: tabElement) else {
            logger.debug(
                "Tab close stopped because the tab exposes no close control pid=\(item.pid, privacy: .public)"
            )
            return
        }
        guard supportsAction(kAXPressAction as String, on: closeButton) else {
            logger.debug(
                "Tab close stopped because the close control does not advertise AXPress pid=\(item.pid, privacy: .public)"
            )
            return
        }
        let closeError = AXUIElementPerformAction(closeButton, kAXPressAction as CFString)
        if closeError != .success {
            logger.debug(
                "Tab close failed pid=\(item.pid, privacy: .public) error=\(closeError.rawValue, privacy: .public)"
            )
        }
        onChange?(closeError == .success ? .windowDestroyed : .ordinary)
    }

    func closeTabGroup(_ item: TaskbarItem) {
        _ = snapshot()
        let elementsForGroup = item.nativeTabGroupID.flatMap {
            axWindowElementsByGroupID[$0]
        }
        let groupsForPID = axWindowGroupsByPID[item.pid] ?? []
        let windowElements =
            elementsForGroup ?? (groupsForPID.count == 1 ? groupsForPID[0] : [])
        guard !windowElements.isEmpty else {
            close(item)
            return
        }
        var didCloseWindow = false
        for element in windowElements {
            didCloseWindow = pressCloseButton(for: element) == .success || didCloseWindow
        }
        onChange?(didCloseWindow ? .windowDestroyed : .ordinary)
    }

    func minimize(_ item: TaskbarItem) {
        guard let element = actionableElement(for: item) else {
            logger.debug(
                "Minimize skipped because AX reference is stale for \(item.id, privacy: .public)"
            )
            return
        }

        let error = AXUIElementSetAttributeValue(
            element,
            kAXMinimizedAttribute as CFString,
            kCFBooleanTrue
        )
        if error != .success {
            logger.debug(
                "Minimize failed pid=\(item.pid, privacy: .public) error=\(error.rawValue, privacy: .public)"
            )
        }
        onChange?(.ordinary)
    }

    func close(_ item: TaskbarItem) {
        guard let element = actionableElement(for: item) else {
            logger.debug(
                "Close skipped because AX reference is stale for \(item.id, privacy: .public)")
            return
        }

        let pressError = pressCloseButton(for: element)
        if pressError == .success {
            axElementsByStableKey.removeValue(forKey: item.id)
            if let cgWindowNumber = item.cgWindowNumber {
                axElementsByPhysicalIdentity.removeValue(
                    forKey: AXPhysicalWindowIdentity(
                        pid: item.pid,
                        cgWindowNumber: cgWindowNumber))
            }
        } else {
            logger.debug(
                "Close action failed pid=\(item.pid, privacy: .public) error=\(pressError.rawValue, privacy: .public)"
            )
        }
        // A modal save prompt can make AX report cannotComplete even though the
        // press was delivered. Refresh once and let the target application's
        // resulting window state remain authoritative.
        onChange?(pressError == .success ? .windowDestroyed : .ordinary)
    }

    private func currentTabElements(for item: TaskbarItem) -> [AXUIElement] {
        if let groupID = item.nativeTabGroupID,
            let elements = axTabElementsByGroupID[groupID]
        {
            return elements
        }
        let groupsForPID = axTabGroupsByPID[item.pid] ?? []
        return groupsForPID.count == 1 ? groupsForPID[0] : []
    }

    private func tabCloseButton(for tabElement: AXUIElement) -> AXUIElement? {
        axElementArray(kAXChildrenAttribute, from: tabElement).first { element in
            stringAttribute(kAXSubroleAttribute, from: element) == kAXCloseButtonSubrole as String
        }
    }

    private func pressCloseButton(for element: AXUIElement) -> AXError {
        var rawCloseButton: CFTypeRef?
        let copyError = AXUIElementCopyAttributeValue(
            element,
            kAXCloseButtonAttribute as CFString,
            &rawCloseButton
        )
        guard copyError == .success,
            let rawCloseButton,
            CFGetTypeID(rawCloseButton) == AXUIElementGetTypeID()
        else { return copyError }
        return AXUIElementPerformAction(
            rawCloseButton as! AXUIElement,
            kAXPressAction as CFString)
    }

    private func axElementArray(_ attribute: String, from element: AXUIElement) -> [AXUIElement] {
        var rawValue: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(element, attribute as CFString, &rawValue) == .success,
            let rawValue
        else { return [] }
        if let elements = rawValue as? [AXUIElement] { return elements }
        guard let array = rawValue as? NSArray else { return [] }
        return array.compactMap { value in
            let cfValue = value as CFTypeRef
            guard CFGetTypeID(cfValue) == AXUIElementGetTypeID() else { return nil }
            return (cfValue as! AXUIElement)
        }
    }

    private func stringAttribute(_ attribute: String, from element: AXUIElement) -> String? {
        var rawValue: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(element, attribute as CFString, &rawValue) == .success,
            let rawValue
        else { return nil }
        return rawValue as? String
    }

    private func supportsAction(_ action: String, on element: AXUIElement) -> Bool {
        var rawActions: CFArray?
        guard AXUIElementCopyActionNames(element, &rawActions) == .success,
            let actions = rawActions as? [String]
        else { return false }
        return AXActionSupport.contains(action, in: actions)
    }

    @discardableResult
    func setHeight(_ height: CGFloat, for item: TaskbarItem) -> Bool {
        guard height.isFinite, height > 0,
            let element = actionableElement(for: item)
        else {
            logger.debug(
                "Height update skipped because the AX reference or geometry is invalid for \(item.id, privacy: .public)"
            )
            return false
        }

        // Window managers commonly write position and size separately. Preserve the live
        // width so a late taskbar correction cannot undo their horizontal layout.
        var rawSize: CFTypeRef?
        let readError = AXUIElementCopyAttributeValue(
            element, kAXSizeAttribute as CFString, &rawSize)
        guard readError == .success, let rawSize,
            CFGetTypeID(rawSize) == AXValueGetTypeID(),
            let currentSizeValue = rawSize as! AXValue?,
            AXValueGetType(currentSizeValue) == .cgSize
        else {
            logger.debug(
                "Height update skipped because the live width is unavailable pid=\(item.pid, privacy: .public) error=\(readError.rawValue, privacy: .public)"
            )
            return false
        }
        var mutableSize = CGSize.zero
        guard AXValueGetValue(currentSizeValue, .cgSize, &mutableSize),
            mutableSize.width.isFinite, mutableSize.width > 0
        else {
            return false
        }
        mutableSize.height = height
        guard let sizeValue = AXValueCreate(.cgSize, &mutableSize) else { return false }
        let sizeError = AXUIElementSetAttributeValue(
            element, kAXSizeAttribute as CFString, sizeValue)
        let succeeded = sizeError == .success
        if !succeeded {
            logger.debug(
                "Height update failed pid=\(item.pid, privacy: .public) error=\(sizeError.rawValue, privacy: .public)"
            )
        }
        return succeeded
    }

    private func actionableElement(for item: TaskbarItem) -> AXUIElement? {
        if let exact = axElementsByStableKey[item.id] { return exact }
        guard let cgWindowNumber = item.cgWindowNumber else { return nil }
        return axElementsByPhysicalIdentity[
            AXPhysicalWindowIdentity(pid: item.pid, cgWindowNumber: cgWindowNumber)
        ]
    }
}

@MainActor
private final class AXWindowInspector {
    private static let fullscreenAttribute =
        NSAccessibility.Attribute(rawValue: "AXFullScreen").rawValue
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

    func enumerate(
        _ application: NSRunningApplication,
        stableKeyForElement: (AXUIElement) -> String,
        stableKeyForTabGroup: (AXUIElement) -> String,
        stableKeyForTab: (AXUIElement) -> String
    ) -> AXWindowEnumerationResult {
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
            return AXWindowEnumerationResult(
                records: [], observedWindowIDs: [], didReadWindowList: false)
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
            return AXWindowEnumerationResult(
                records: [], observedWindowIDs: [], didReadWindowList: false)
        }

        let applicationName =
            application.localizedName ?? application.bundleIdentifier ?? "Application"
        let applicationIdentity =
            application.bundleIdentifier
            ?? application.bundleURL?.standardizedFileURL.path
            ?? application.executableURL?.standardizedFileURL.path
        var records: [AXWindowRecord] = []
        var observedWindowIDs: Set<String> = []
        var batchFailures: [Int32: Int] = [:]
        var malformedCount = 0

        for element in windows {
            let stableKey = stableKeyForElement(element)
            observedWindowIDs.insert(stableKey)
            var rawWindowNumber = CGWindowID.zero
            let windowIDError = axUIElementGetWindowID(element, &rawWindowNumber)
            let cgWindowNumber =
                windowIDError == .success && rawWindowNumber != 0 ? rawWindowNumber : nil
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
            var candidate = WindowCandidate(
                stableKey: stableKey,
                cgWindowNumber: cgWindowNumber,
                pid: application.processIdentifier,
                applicationName: applicationName,
                applicationIdentity: applicationIdentity,
                applicationBundlePath: application.bundleURL?.standardizedFileURL.path
                    ?? application.executableURL?.standardizedFileURL.path,
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
                isFullscreen: boolAttribute(Self.fullscreenAttribute, from: element) ?? false,
                isFocused: boolValue(values[7]) ?? false,
                isMain: boolValue(values[8]) ?? false
            )
            let nativeTabGroup = inspectNativeTabGroup(
                in: element,
                stableKeyForTabGroup: stableKeyForTabGroup,
                stableKeyForTab: stableKeyForTab
            )
            if let nativeTabGroup {
                candidate = candidate.assigningNativeTabGroup(
                    id: nativeTabGroup.id,
                    tabs: nativeTabGroup.tabs
                )
            }
            records.append(
                AXWindowRecord(
                    candidate: candidate,
                    element: element,
                    tabElementsByID: nativeTabGroup?.elementsByID ?? [:],
                    tabElements: nativeTabGroup?.elements ?? []
                )
            )
        }

        if !batchFailures.isEmpty || malformedCount > 0 {
            let errors = batchFailures.keys.sorted().map { code in
                "\(code):\(batchFailures[code] ?? 0)"
            }.joined(separator: ",")
            logger.debug(
                "AX window attributes skipped pid=\(application.processIdentifier, privacy: .public) batch_errors=\(errors, privacy: .public) malformed=\(malformedCount, privacy: .public)"
            )
        }
        return AXWindowEnumerationResult(
            records: assignNativeTabGroupMembership(records),
            observedWindowIDs: observedWindowIDs,
            didReadWindowList: true
        )
    }

    private func inspectNativeTabGroup(
        in window: AXUIElement,
        stableKeyForTabGroup: (AXUIElement) -> String,
        stableKeyForTab: (AXUIElement) -> String
    ) -> AXNativeTabGroupInspection? {
        guard let children = elementArrayAttribute(kAXChildrenAttribute, from: window) else {
            return nil
        }
        let tabGroups = children.filter {
            stringAttribute(kAXRoleAttribute, from: $0) == kAXTabGroupRole as String
        }
        guard tabGroups.count == 1,
            let tabElements = elementArrayAttribute(kAXTabsAttribute, from: tabGroups[0]),
            tabElements.count > 1
        else {
            return nil
        }

        var tabs: [TaskbarTab] = []
        var elementsByID: [String: AXUIElement] = [:]
        for (index, element) in tabElements.enumerated() {
            let attributes = [
                kAXRoleAttribute,
                kAXSubroleAttribute,
                kAXTitleAttribute,
                kAXValueAttribute,
            ]
            var rawValues: CFArray?
            guard
                AXUIElementCopyMultipleAttributeValues(
                    element,
                    attributes as CFArray,
                    [],
                    &rawValues
                ) == .success,
                let values = rawValues as? [Any],
                values.count == attributes.count,
                stringValue(values[0]) == kAXRadioButtonRole as String,
                stringValue(values[1]) == NSAccessibility.Subrole.tabButtonSubrole.rawValue
            else {
                return nil
            }
            let id = stableKeyForTab(element)
            let title = stringValue(values[2]) ?? "Tab \(index + 1)"
            tabs.append(
                TaskbarTab(
                    id: id,
                    title: title,
                    isSelected: boolValue(values[3]) ?? false,
                    index: index
                )
            )
            elementsByID[id] = element
        }

        return AXNativeTabGroupInspection(
            id: stableKeyForTabGroup(tabGroups[0]),
            tabs: tabs,
            elementsByID: elementsByID,
            elements: tabElements
        )
    }

    private func assignNativeTabGroupMembership(
        _ records: [AXWindowRecord]
    ) -> [AXWindowRecord] {
        let candidates = NativeTabGroupMembershipResolver.assign(records.map(\.candidate))
        return zip(records, candidates).map { record, candidate in
            AXWindowRecord(
                candidate: candidate,
                element: record.element,
                tabElementsByID: record.tabElementsByID,
                tabElements: record.tabElements
            )
        }
    }

    private func elementArrayAttribute(
        _ attribute: String,
        from element: AXUIElement
    ) -> [AXUIElement]? {
        var rawValue: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(
                element,
                attribute as CFString,
                &rawValue
            ) == .success,
            let rawValue
        else {
            return nil
        }
        if let elements = rawValue as? [AXUIElement] { return elements }
        guard let array = rawValue as? NSArray else { return nil }
        return array.compactMap { value in
            let cfValue = value as CFTypeRef
            guard CFGetTypeID(cfValue) == AXUIElementGetTypeID() else { return nil }
            return (cfValue as! AXUIElement)
        }
    }

    private func stringAttribute(_ attribute: String, from element: AXUIElement) -> String? {
        var rawValue: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(
                element,
                attribute as CFString,
                &rawValue
            ) == .success,
            let rawValue
        else {
            return nil
        }
        return stringValue(rawValue)
    }

    private func stringValue(_ value: Any) -> String? {
        if let string = value as? String { return string }
        if let string = value as? NSString { return string as String }
        return nil
    }

    private func boolValue(_ value: Any) -> Bool? {
        (value as? NSNumber)?.boolValue
    }

    private func boolAttribute(_ attribute: String, from element: AXUIElement) -> Bool? {
        var rawValue: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(element, attribute as CFString, &rawValue) == .success,
            let rawValue
        else { return nil }
        return boolValue(rawValue)
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
private struct AXWindowEnumerationResult {
    let records: [AXWindowRecord]
    let observedWindowIDs: Set<String>
    let didReadWindowList: Bool
}

@MainActor
private struct AXWindowRecord {
    let candidate: WindowCandidate
    let element: AXUIElement
    let tabElementsByID: [String: AXUIElement]
    let tabElements: [AXUIElement]
}

@MainActor
private struct AXNativeTabGroupInspection {
    let id: String
    let tabs: [TaskbarTab]
    let elementsByID: [String: AXUIElement]
    let elements: [AXUIElement]
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
    private let onNotification: @MainActor @Sendable (String) -> Void
    private var observers: [pid_t: AXApplicationObserver] = [:]

    init(
        logger: Logger,
        onNotification: @escaping @MainActor @Sendable (String) -> Void
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
    private let onNotification: @MainActor @Sendable (String) -> Void
    private var observer: AXObserver?
    private var applicationElement: AXUIElement
    private var windowElements: [String: AXUIElement] = [:]

    init?(
        pid: pid_t,
        applicationElement: AXUIElement,
        logger: Logger,
        onNotification: @escaping @MainActor @Sendable (String) -> Void
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

    private func handleNotification(_ notification: String) {
        onNotification(notification)
    }

    nonisolated func notificationReceived(_ notification: String) {
        Task { @MainActor [weak self] in
            self?.handleNotification(notification)
        }
    }
}

private func axObserverCallback(
    _: AXObserver,
    _: AXUIElement,
    notification: CFString,
    _ refcon: UnsafeMutableRawPointer?
) {
    guard let refcon else { return }
    let observer = Unmanaged<AXApplicationObserver>.fromOpaque(refcon).takeUnretainedValue()
    observer.notificationReceived(notification as String)
}

enum CGWindowReader {
    static func allWindows() -> [CGWindowMetadata] {
        windows(options: [.optionAll, .excludeDesktopElements])
    }

    private static func windows(options: CGWindowListOption) -> [CGWindowMetadata] {
        guard
            let rawWindows = CGWindowListCopyWindowInfo(
                options,
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
                ordinal: ordinal,
                isMain: displayID == CGMainDisplayID()
            )
        }
    }
}
