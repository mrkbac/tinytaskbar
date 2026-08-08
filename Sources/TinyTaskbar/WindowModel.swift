import CoreGraphics
import Foundation

/// The public metadata that Core Graphics makes available for an on-screen window.
/// Its coordinate system is the Quartz screen space used by AX positions after conversion.
struct CGWindowMetadata: Equatable, Sendable {
    let windowNumber: UInt32?
    let ownerPID: Int32
    let layer: Int
    let bounds: CGRect
    let title: String
    let isOnScreen: Bool

    init(
        windowNumber: UInt32? = nil,
        ownerPID: Int32,
        layer: Int = 0,
        bounds: CGRect,
        title: String = "",
        isOnScreen: Bool = true
    ) {
        self.windowNumber = windowNumber
        self.ownerPID = ownerPID
        self.layer = layer
        self.bounds = bounds
        self.title = title
        self.isOnScreen = isOnScreen
    }
}

/// A display has both a Quartz frame for projection and an AppKit frame for its panel.
struct DisplayDescriptor: Equatable, Sendable {
    let identifier: String
    let frame: CGRect
    let appKitFrame: CGRect
    let appKitVisibleFrame: CGRect
    let ordinal: Int

    init(
        identifier: String,
        frame: CGRect,
        appKitFrame: CGRect? = nil,
        appKitVisibleFrame: CGRect? = nil,
        ordinal: Int = 0
    ) {
        self.identifier = identifier
        self.frame = frame
        let resolvedAppKitFrame = appKitFrame ?? frame
        self.appKitFrame = resolvedAppKitFrame
        self.appKitVisibleFrame = appKitVisibleFrame ?? resolvedAppKitFrame
        self.ordinal = ordinal
    }
}

/// AX-derived data before it has been matched to the public Core Graphics window list.
struct WindowCandidate: Equatable, Sendable {
    let stableKey: String?
    let pid: Int32
    let applicationName: String
    let applicationIdentity: String?
    let localizedApplicationName: String
    let applicationIsRunning: Bool
    let applicationIsRegular: Bool
    let applicationIsHidden: Bool
    let role: String
    let subrole: String
    let title: String
    let frame: CGRect?
    let isHidden: Bool
    let isMinimized: Bool
    let isFocused: Bool
    let isMain: Bool

    init(
        stableKey: String? = nil,
        pid: Int32,
        applicationName: String,
        applicationIdentity: String? = nil,
        localizedApplicationName: String? = nil,
        applicationIsRunning: Bool = true,
        applicationIsRegular: Bool = true,
        applicationIsHidden: Bool = false,
        role: String = "AXWindow",
        subrole: String = "AXStandardWindow",
        title: String = "",
        frame: CGRect?,
        isHidden: Bool = false,
        isMinimized: Bool = false,
        isFocused: Bool = false,
        isMain: Bool = false
    ) {
        self.stableKey = stableKey
        self.pid = pid
        self.applicationName = applicationName
        self.applicationIdentity = applicationIdentity
        self.localizedApplicationName = localizedApplicationName ?? applicationName
        self.applicationIsRunning = applicationIsRunning
        self.applicationIsRegular = applicationIsRegular
        self.applicationIsHidden = applicationIsHidden
        self.role = role
        self.subrole = subrole
        self.title = title
        self.frame = frame
        self.isHidden = isHidden
        self.isMinimized = isMinimized
        self.isFocused = isFocused
        self.isMain = isMain
    }
}

struct TaskbarItem: Equatable, Sendable, Identifiable {
    let id: String
    let pid: Int32
    let applicationName: String
    let applicationIdentity: String?
    let title: String
    let displayIdentifier: String
    let cgWindowNumber: UInt32?
    let isActive: Bool

    init(
        id: String,
        pid: Int32,
        applicationName: String,
        applicationIdentity: String? = nil,
        title: String,
        displayIdentifier: String,
        cgWindowNumber: UInt32?,
        isActive: Bool
    ) {
        self.id = id
        self.pid = pid
        self.applicationName = applicationName
        self.applicationIdentity = applicationIdentity
        self.title = title
        self.displayIdentifier = displayIdentifier
        self.cgWindowNumber = cgWindowNumber
        self.isActive = isActive
    }

    var displayTitle: String {
        title.isEmpty ? applicationName : title
    }

    func buttonTitle(showsWindowTitles: Bool) -> String {
        showsWindowTitles ? displayTitle : applicationName
    }

    var accessibilityLabel: String {
        "\(applicationName), \(displayTitle)"
    }

    var tooltip: String {
        "Activate \(applicationName): \(displayTitle)"
    }
}

struct TaskbarState: Equatable, Sendable {
    let displays: [DisplayDescriptor]
    let itemsByDisplay: [String: [TaskbarItem]]

    static let empty = TaskbarState(displays: [], itemsByDisplay: [:])
}

struct TinyTaskbarPreferences: Equatable, Sendable {
    var onboardingComplete = false
    var showsWindowTitles = true

    static let defaults = TinyTaskbarPreferences()
}

extension CGRect {
    var isFiniteGeometry: Bool {
        minX.isFinite && minY.isFinite && maxX.isFinite && maxY.isFinite
            && width.isFinite && height.isFinite
    }
}

/// AX positions and CG window bounds already use the same global top-left screen space.
enum AXScreenCoordinateMapper {
    static func toCGScreen(_ frame: CGRect) -> CGRect {
        frame
    }
}

struct WindowEligibility: Sendable {
    static let defaultMinimumSize = CGSize(width: 80, height: 40)

    let minimumSize: CGSize

    init(minimumSize: CGSize = WindowEligibility.defaultMinimumSize) {
        self.minimumSize = minimumSize
    }

    func isEligible(_ candidate: WindowCandidate, selfPID: Int32) -> Bool {
        guard candidate.pid != selfPID,
            candidate.applicationIsRunning,
            candidate.applicationIsRegular,
            !candidate.applicationIsHidden,
            candidate.role == "AXWindow",
            candidate.subrole == "AXStandardWindow" || candidate.subrole == "AXDialog",
            !candidate.isHidden,
            !candidate.isMinimized,
            let frame = candidate.frame,
            frame.width >= minimumSize.width,
            frame.height >= minimumSize.height,
            frame.isFiniteGeometry
        else {
            return false
        }

        return frame.width > 0 && frame.height > 0
    }
}

enum CGWindowMatcher {
    static let boundsTolerance: CGFloat = 4

    static func match(candidate: WindowCandidate, windows: [CGWindowMetadata]) -> CGWindowMetadata?
    {
        guard let index = matchIndex(candidate: candidate, windows: windows) else { return nil }
        return windows[index]
    }

    static func matchIndex(
        candidate: WindowCandidate,
        windows: [CGWindowMetadata],
        excluding excludedIndices: Set<Int> = []
    ) -> Int? {
        guard let frame = candidate.frame, frame.isFiniteGeometry else { return nil }

        let base = windows.indices
            .filter { index in
                let window = windows[index]
                return !excludedIndices.contains(index)
                    && window.ownerPID == candidate.pid
                    && window.layer == 0
                    && window.isOnScreen
                    && window.bounds.isFiniteGeometry
            }
            .sorted { preferredWindow(windows[$0], windows[$1]) }
        guard !base.isEmpty else { return nil }

        let boundsMatches = base.filter {
            approximatelyEqual(windows[$0].bounds, frame, tolerance: boundsTolerance)
        }
        guard !boundsMatches.isEmpty else { return nil }

        if !candidate.title.isEmpty {
            let titleMatches = boundsMatches.filter {
                !windows[$0].title.isEmpty
                    && normalized(windows[$0].title) == normalized(candidate.title)
            }
            if titleMatches.count == 1 {
                return titleMatches[0]
            }
            if titleMatches.count > 1 {
                return titleMatches.sorted {
                    preferredWindow(windows[$0], windows[$1])
                }.first
            }
        }

        // AX and CG title updates can arrive in different event-loop turns. Geometry is
        // authoritative when it identifies exactly one layer-zero window for the PID;
        // title is only needed to disambiguate otherwise identical bounds.
        if boundsMatches.count == 1 {
            return boundsMatches[0]
        }

        return nil
    }

    private static func approximatelyEqual(
        _ lhs: CGRect,
        _ rhs: CGRect,
        tolerance: CGFloat
    ) -> Bool {
        abs(lhs.minX - rhs.minX) <= tolerance && abs(lhs.minY - rhs.minY) <= tolerance
            && abs(lhs.width - rhs.width) <= tolerance && abs(lhs.height - rhs.height) <= tolerance
    }

    static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    private static func preferredWindow(
        _ lhs: CGWindowMetadata,
        _ rhs: CGWindowMetadata
    ) -> Bool {
        let lhsNumber = lhs.windowNumber ?? .max
        let rhsNumber = rhs.windowNumber ?? .max
        if lhsNumber != rhsNumber { return lhsNumber < rhsNumber }
        let lhsTitle = normalized(lhs.title)
        let rhsTitle = normalized(rhs.title)
        if lhsTitle != rhsTitle { return lhsTitle < rhsTitle }
        if lhs.bounds.minX != rhs.bounds.minX { return lhs.bounds.minX < rhs.bounds.minX }
        if lhs.bounds.minY != rhs.bounds.minY { return lhs.bounds.minY < rhs.bounds.minY }
        if lhs.bounds.width != rhs.bounds.width { return lhs.bounds.width < rhs.bounds.width }
        return lhs.bounds.height < rhs.bounds.height
    }
}

enum TaskbarPanelLayout {
    static let defaultHeight: CGFloat = 30
    static let defaultHorizontalInset: CGFloat = 0
    static let defaultBottomInset: CGFloat = 0

    static func frame(
        for display: DisplayDescriptor,
        height: CGFloat = defaultHeight,
        horizontalInset: CGFloat = defaultHorizontalInset,
        bottomInset: CGFloat = defaultBottomInset
    ) -> CGRect {
        let fullFrame = display.appKitFrame
        let visibleFrame = display.appKitVisibleFrame
        guard fullFrame.isFiniteGeometry, visibleFrame.isFiniteGeometry else { return .zero }

        let horizontalMin = min(max(fullFrame.minX, visibleFrame.minX), fullFrame.maxX)
        let horizontalMax = max(
            horizontalMin,
            min(fullFrame.maxX, visibleFrame.maxX)
        )
        let horizontalWidth = max(0, horizontalMax - horizontalMin)
        let safeHorizontalInset = min(
            max(0, horizontalInset),
            horizontalWidth / 2
        )
        let width = max(0, horizontalWidth - safeHorizontalInset * 2)
        let bottom = max(
            fullFrame.minY + max(0, bottomInset),
            visibleFrame.minY + max(0, bottomInset)
        )
        let availableHeight = max(0, fullFrame.maxY - bottom)
        let panelHeight = min(max(0, height), availableHeight)
        return CGRect(
            x: horizontalMin + safeHorizontalInset,
            y: bottom,
            width: width,
            height: panelHeight
        )
    }
}

enum TaskbarButtonLayout {
    static let titleOnMinimumWidth: CGFloat = 110
    static let titleOffMinimumWidth: CGFloat = 72
    static let titleOnMaximumWidth: CGFloat = 260
    static let titleOffMaximumWidth: CGFloat = 190

    static func widthRange(showsWindowTitles: Bool) -> ClosedRange<CGFloat> {
        if showsWindowTitles {
            return titleOnMinimumWidth...titleOnMaximumWidth
        }
        return titleOffMinimumWidth...titleOffMaximumWidth
    }
}

enum DisplayMapper {
    static func identifier(
        for frame: CGRect,
        displays: [DisplayDescriptor]
    ) -> String? {
        guard !displays.isEmpty else { return nil }

        let intersections = displays.map { display in
            (display: display, area: intersectionArea(frame, display.frame))
        }
        let positive = intersections.filter { $0.area > 0 }
        if let best = positive.sorted(by: preferredIntersection).first {
            return best.display.identifier
        }

        let center = CGPoint(x: frame.midX, y: frame.midY)
        let containing = displays.filter { $0.frame.contains(center) }
        if let best = containing.sorted(by: preferredDisplay).first {
            return best.identifier
        }

        return
            displays
            .map { ($0, distanceSquared(from: center, to: $0.frame)) }
            .sorted {
                if $0.1 != $1.1 { return $0.1 < $1.1 }
                return preferredDisplay($0.0, $1.0)
            }
            .first?.0.identifier
    }

    static func intersectionArea(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull else { return 0 }
        return max(0, intersection.width) * max(0, intersection.height)
    }

    private static func preferredIntersection(
        _ lhs: (display: DisplayDescriptor, area: CGFloat),
        _ rhs: (display: DisplayDescriptor, area: CGFloat)
    ) -> Bool {
        if lhs.area != rhs.area { return lhs.area > rhs.area }
        return preferredDisplay(lhs.display, rhs.display)
    }

    private static func preferredDisplay(_ lhs: DisplayDescriptor, _ rhs: DisplayDescriptor) -> Bool
    {
        if lhs.identifier != rhs.identifier { return lhs.identifier < rhs.identifier }
        return lhs.ordinal < rhs.ordinal
    }

    private static func distanceSquared(from point: CGPoint, to rect: CGRect) -> CGFloat {
        let dx: CGFloat
        if point.x < rect.minX {
            dx = rect.minX - point.x
        } else if point.x > rect.maxX {
            dx = point.x - rect.maxX
        } else {
            dx = 0
        }

        let dy: CGFloat
        if point.y < rect.minY {
            dy = rect.minY - point.y
        } else if point.y > rect.maxY {
            dy = point.y - rect.maxY
        } else {
            dy = 0
        }

        return dx * dx + dy * dy
    }
}

enum WindowOrdering {
    static func sorted(_ items: [TaskbarItem]) -> [TaskbarItem] {
        items.sorted { lhs, rhs in
            switch (lhs.cgWindowNumber, rhs.cgWindowNumber) {
            case (let lhsWindowNumber?, let rhsWindowNumber?)
            where lhsWindowNumber != rhsWindowNumber:
                return lhsWindowNumber < rhsWindowNumber
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                break
            }

            let lhsApplication = lhs.applicationName.lowercased()
            let rhsApplication = rhs.applicationName.lowercased()
            if lhsApplication != rhsApplication { return lhsApplication < rhsApplication }

            if lhs.id != rhs.id { return lhs.id < rhs.id }

            let lhsTitle = CGWindowMatcher.normalized(lhs.title)
            let rhsTitle = CGWindowMatcher.normalized(rhs.title)
            if lhsTitle != rhsTitle { return lhsTitle < rhsTitle }

            return lhs.pid < rhs.pid
        }
    }
}

enum WindowDeduplicator {
    static func deduplicate(_ items: [TaskbarItem]) -> [TaskbarItem] {
        var byID: [String: TaskbarItem] = [:]
        for item in items {
            guard let existing = byID[item.id] else {
                byID[item.id] = item
                continue
            }
            if preferred(item, over: existing) {
                byID[item.id] = item
            }
        }
        return Array(byID.values)
    }

    private static func preferred(_ lhs: TaskbarItem, over rhs: TaskbarItem) -> Bool {
        if lhs.isActive != rhs.isActive { return lhs.isActive }
        if (lhs.cgWindowNumber != nil) != (rhs.cgWindowNumber != nil) {
            return lhs.cgWindowNumber != nil
        }
        if lhs.applicationName != rhs.applicationName {
            return lhs.applicationName < rhs.applicationName
        }
        let lhsTitle = CGWindowMatcher.normalized(lhs.title)
        let rhsTitle = CGWindowMatcher.normalized(rhs.title)
        if lhsTitle != rhsTitle { return lhsTitle < rhsTitle }
        if lhs.displayIdentifier != rhs.displayIdentifier {
            return lhs.displayIdentifier < rhs.displayIdentifier
        }
        return (lhs.cgWindowNumber ?? .max) < (rhs.cgWindowNumber ?? .max)
    }
}

enum WindowCandidateOrdering {
    static func preferred(_ lhs: WindowCandidate, _ rhs: WindowCandidate) -> Bool {
        if lhs.pid != rhs.pid { return lhs.pid < rhs.pid }
        let lhsStableKey = lhs.stableKey ?? ""
        let rhsStableKey = rhs.stableKey ?? ""
        if lhsStableKey != rhsStableKey { return lhsStableKey < rhsStableKey }
        let lhsTitle = CGWindowMatcher.normalized(lhs.title)
        let rhsTitle = CGWindowMatcher.normalized(rhs.title)
        if lhsTitle != rhsTitle { return lhsTitle < rhsTitle }
        let lhsFrame = lhs.frame ?? .zero
        let rhsFrame = rhs.frame ?? .zero
        if lhsFrame.minX != rhsFrame.minX { return lhsFrame.minX < rhsFrame.minX }
        if lhsFrame.minY != rhsFrame.minY { return lhsFrame.minY < rhsFrame.minY }
        if lhsFrame.width != rhsFrame.width { return lhsFrame.width < rhsFrame.width }
        if lhsFrame.height != rhsFrame.height { return lhsFrame.height < rhsFrame.height }
        if lhs.isFocused != rhs.isFocused { return lhs.isFocused }
        return lhs.isMain && !rhs.isMain
    }
}

enum WindowCGAssignment {
    static func assign(
        candidates: [WindowCandidate],
        cgWindows: [CGWindowMetadata],
        selfPID: Int32,
        eligibility: WindowEligibility = WindowEligibility()
    ) -> [Int: Int] {
        var assignments: [Int: Int] = [:]
        var usedCGWindowIndices = Set<Int>()
        let orderedCandidateIndices = candidates.indices
            .filter { eligibility.isEligible(candidates[$0], selfPID: selfPID) }
            .sorted { WindowCandidateOrdering.preferred(candidates[$0], candidates[$1]) }

        for candidateIndex in orderedCandidateIndices {
            guard
                let cgWindowIndex = CGWindowMatcher.matchIndex(
                    candidate: candidates[candidateIndex],
                    windows: cgWindows,
                    excluding: usedCGWindowIndices
                )
            else {
                continue
            }
            assignments[candidateIndex] = cgWindowIndex
            usedCGWindowIndices.insert(cgWindowIndex)
        }
        return assignments
    }
}

enum WindowProjection {
    static func project(
        candidates: [WindowCandidate],
        cgWindows: [CGWindowMetadata],
        displays: [DisplayDescriptor],
        selfPID: Int32,
        frontmostPID: Int32? = nil,
        eligibility: WindowEligibility = WindowEligibility()
    ) -> TaskbarState {
        var projected: [TaskbarItem] = []
        let assignments = WindowCGAssignment.assign(
            candidates: candidates,
            cgWindows: cgWindows,
            selfPID: selfPID,
            eligibility: WindowEligibility(minimumSize: eligibility.minimumSize)
        )

        for candidateIndex in candidates.indices {
            let candidate = candidates[candidateIndex]
            guard let cgWindowIndex = assignments[candidateIndex] else { continue }
            let cgWindow = cgWindows[cgWindowIndex]
            guard
                let frame = candidate.frame,
                let displayIdentifier = DisplayMapper.identifier(for: frame, displays: displays)
            else {
                continue
            }

            let id =
                WindowObservationKey.itemKey(
                    candidate: candidate,
                    cgWindow: cgWindow
                )
            let isActive =
                frontmostPID == candidate.pid && (candidate.isFocused || candidate.isMain)
            projected.append(
                TaskbarItem(
                    id: id,
                    pid: candidate.pid,
                    applicationName: candidate.localizedApplicationName,
                    applicationIdentity: candidate.applicationIdentity,
                    title: candidate.title,
                    displayIdentifier: displayIdentifier,
                    cgWindowNumber: cgWindow.windowNumber,
                    isActive: isActive
                )
            )
        }

        let grouped = Dictionary(grouping: WindowDeduplicator.deduplicate(projected)) {
            $0.displayIdentifier
        }
        let ordered = grouped.mapValues(WindowOrdering.sorted)
        let orderedDisplays = displays.sorted(by: preferredDisplay)
        return TaskbarState(displays: orderedDisplays, itemsByDisplay: ordered)
    }

    private static func preferredDisplay(_ lhs: DisplayDescriptor, _ rhs: DisplayDescriptor) -> Bool
    {
        if lhs.identifier != rhs.identifier { return lhs.identifier < rhs.identifier }
        return lhs.ordinal < rhs.ordinal
    }
}

enum StableWindowKey {
    static func make(candidate: WindowCandidate, cgWindow: CGWindowMetadata) -> String {
        if let windowNumber = cgWindow.windowNumber {
            return "cg:\(candidate.pid):\(windowNumber)"
        }

        let title = CGWindowMatcher.normalized(candidate.title)
        let frame = candidate.frame ?? .zero
        let coordinates = [frame.minX, frame.minY, frame.width, frame.height]
            .map { String(Int($0.rounded())) }
            .joined(separator: ":")
        return "ax:\(candidate.pid):\(title):\(coordinates)"
    }
}

enum WindowObservationKey {
    static func itemKey(candidate: WindowCandidate, cgWindow: CGWindowMetadata) -> String {
        candidate.stableKey ?? StableWindowKey.make(candidate: candidate, cgWindow: cgWindow)
    }

    static func observerKey(
        candidate: WindowCandidate,
        cgWindow: CGWindowMetadata?,
        ordinal: Int
    ) -> String {
        if let windowNumber = cgWindow?.windowNumber {
            return "cg-observer:\(candidate.pid):\(windowNumber)"
        }

        let frame = candidate.frame ?? .zero
        let coordinates = [frame.minX, frame.minY, frame.width, frame.height]
            .map { String(Int($0.rounded())) }
            .joined(separator: ":")
        let base =
            candidate.stableKey
            ?? "\(CGWindowMatcher.normalized(candidate.title)):\(coordinates)"
        return "ax-observer:\(candidate.pid):\(base):\(ordinal)"
    }
}

enum LifecycleState: Equatable, Sendable {
    case stopped
    case awaitingAccessibility
    case running
    case runningWithoutAccessibility
}

enum LifecycleEvent: Equatable, Sendable {
    case launched(accessibilityTrusted: Bool)
    case accessibilityChanged(Bool)
    case stopped
}

enum LifecycleReducer {
    static func reduce(state: LifecycleState, event: LifecycleEvent) -> LifecycleState {
        switch event {
        case .launched(let accessibilityTrusted):
            return accessibilityTrusted ? .running : .awaitingAccessibility
        case .accessibilityChanged(let trusted):
            return trusted ? .running : .runningWithoutAccessibility
        case .stopped:
            return .stopped
        }
    }
}
