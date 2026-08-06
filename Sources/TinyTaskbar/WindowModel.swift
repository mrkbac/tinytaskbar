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
    let ordinal: Int

    init(identifier: String, frame: CGRect, appKitFrame: CGRect? = nil, ordinal: Int = 0) {
        self.identifier = identifier
        self.frame = frame
        self.appKitFrame = appKitFrame ?? frame
        self.ordinal = ordinal
    }
}

/// AX-derived data before it has been matched to the public Core Graphics window list.
struct WindowCandidate: Equatable, Sendable {
    let stableKey: String?
    let pid: Int32
    let applicationName: String
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
    let title: String
    let displayIdentifier: String
    let cgWindowNumber: UInt32?
    let isActive: Bool

    var displayTitle: String {
        title.isEmpty ? applicationName : title
    }
}

struct TaskbarState: Equatable, Sendable {
    let displays: [DisplayDescriptor]
    let itemsByDisplay: [String: [TaskbarItem]]

    static let empty = TaskbarState(displays: [], itemsByDisplay: [:])
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
            frame.width.isFinite,
            frame.height.isFinite,
            frame.minX.isFinite,
            frame.minY.isFinite
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
        guard let frame = candidate.frame else { return nil }

        let base = windows.filter {
            $0.ownerPID == candidate.pid && $0.layer == 0 && $0.isOnScreen
        }
        guard !base.isEmpty else { return nil }

        let boundsMatches = base.filter {
            approximatelyEqual($0.bounds, frame, tolerance: boundsTolerance)
        }

        if !candidate.title.isEmpty {
            let titleMatches = base.filter {
                normalized($0.title) == normalized(candidate.title)
            }
            if let exact = titleMatches.first(where: {
                approximatelyEqual($0.bounds, frame, tolerance: boundsTolerance)
            }) {
                return exact
            }
        }

        return boundsMatches.first
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
            if lhs.isActive != rhs.isActive { return lhs.isActive }

            let lhsApplication = lhs.applicationName.lowercased()
            let rhsApplication = rhs.applicationName.lowercased()
            if lhsApplication != rhsApplication { return lhsApplication < rhsApplication }

            let lhsTitle = CGWindowMatcher.normalized(lhs.title)
            let rhsTitle = CGWindowMatcher.normalized(rhs.title)
            if lhsTitle != rhsTitle { return lhsTitle < rhsTitle }

            return lhs.id < rhs.id
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
            if item.isActive && !existing.isActive {
                byID[item.id] = item
            } else if item.cgWindowNumber != nil && existing.cgWindowNumber == nil {
                byID[item.id] = item
            }
        }
        return Array(byID.values)
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

        for candidate in candidates {
            guard eligibility.isEligible(candidate, selfPID: selfPID),
                let cgWindow = CGWindowMatcher.match(candidate: candidate, windows: cgWindows),
                let frame = candidate.frame,
                let displayIdentifier = DisplayMapper.identifier(for: frame, displays: displays)
            else {
                continue
            }

            let id =
                candidate.stableKey
                ?? StableWindowKey.make(
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
        return TaskbarState(displays: displays, itemsByDisplay: ordered)
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
