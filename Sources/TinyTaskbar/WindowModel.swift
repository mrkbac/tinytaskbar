import CoreGraphics
import Foundation

/// The public metadata that Core Graphics makes available for a window.
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
    let isMain: Bool

    init(
        identifier: String,
        frame: CGRect,
        appKitFrame: CGRect? = nil,
        appKitVisibleFrame: CGRect? = nil,
        ordinal: Int = 0,
        isMain: Bool = false
    ) {
        self.identifier = identifier
        self.frame = frame
        let resolvedAppKitFrame = appKitFrame ?? frame
        self.appKitFrame = resolvedAppKitFrame
        self.appKitVisibleFrame = appKitVisibleFrame ?? resolvedAppKitFrame
        self.ordinal = ordinal
        self.isMain = isMain
    }
}

struct TaskbarTab: Equatable, Sendable, Identifiable {
    let id: String
    let title: String
    let isSelected: Bool
    let index: Int

    init(id: String, title: String, isSelected: Bool, index: Int = 0) {
        self.id = id
        self.title = title
        self.isSelected = isSelected
        self.index = index
    }
}

/// AX-derived data before it has been matched to the public Core Graphics window list.
struct WindowCandidate: Equatable, Sendable {
    let stableKey: String?
    let cgWindowNumber: UInt32?
    let pid: Int32
    let applicationName: String
    let applicationIdentity: String?
    let applicationBundlePath: String?
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
    let isFullscreen: Bool
    let isFocused: Bool
    let isMain: Bool
    let nativeTabGroupID: String?
    let nativeTabs: [TaskbarTab]

    init(
        stableKey: String? = nil,
        cgWindowNumber: UInt32? = nil,
        pid: Int32,
        applicationName: String,
        applicationIdentity: String? = nil,
        applicationBundlePath: String? = nil,
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
        isFullscreen: Bool = false,
        isFocused: Bool = false,
        isMain: Bool = false,
        nativeTabGroupID: String? = nil,
        nativeTabs: [TaskbarTab] = []
    ) {
        self.stableKey = stableKey
        self.cgWindowNumber = cgWindowNumber
        self.pid = pid
        self.applicationName = applicationName
        self.applicationIdentity = applicationIdentity
        self.applicationBundlePath = applicationBundlePath
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
        self.isFullscreen = isFullscreen
        self.isFocused = isFocused
        self.isMain = isMain
        self.nativeTabGroupID = nativeTabGroupID
        self.nativeTabs = nativeTabs
    }

    var isNativeTabGroupRepresentative: Bool {
        nativeTabGroupID == nil || !nativeTabs.isEmpty
    }

    func represents(_ item: TaskbarItem) -> Bool {
        guard pid == item.pid else { return false }
        if let groupID = item.nativeTabGroupID {
            return nativeTabGroupID == groupID
        }
        if let stableKey, stableKey == item.id {
            return true
        }
        guard let cgWindowNumber, let itemWindowNumber = item.cgWindowNumber else {
            return false
        }
        return cgWindowNumber == itemWindowNumber
    }

    func assigningNativeTabGroup(id: String, tabs: [TaskbarTab]) -> WindowCandidate {
        WindowCandidate(
            stableKey: stableKey,
            cgWindowNumber: cgWindowNumber,
            pid: pid,
            applicationName: applicationName,
            applicationIdentity: applicationIdentity,
            applicationBundlePath: applicationBundlePath,
            localizedApplicationName: localizedApplicationName,
            applicationIsRunning: applicationIsRunning,
            applicationIsRegular: applicationIsRegular,
            applicationIsHidden: applicationIsHidden,
            role: role,
            subrole: subrole,
            title: title,
            frame: frame,
            isHidden: isHidden,
            isMinimized: isMinimized,
            isFullscreen: isFullscreen,
            isFocused: isFocused,
            isMain: isMain,
            nativeTabGroupID: id,
            nativeTabs: tabs
        )
    }

    func replacingFrame(_ frame: CGRect) -> WindowCandidate {
        WindowCandidate(
            stableKey: stableKey,
            cgWindowNumber: cgWindowNumber,
            pid: pid,
            applicationName: applicationName,
            applicationIdentity: applicationIdentity,
            applicationBundlePath: applicationBundlePath,
            localizedApplicationName: localizedApplicationName,
            applicationIsRunning: applicationIsRunning,
            applicationIsRegular: applicationIsRegular,
            applicationIsHidden: applicationIsHidden,
            role: role,
            subrole: subrole,
            title: title,
            frame: frame,
            isHidden: isHidden,
            isMinimized: isMinimized,
            isFullscreen: isFullscreen,
            isFocused: isFocused,
            isMain: isMain,
            nativeTabGroupID: nativeTabGroupID,
            nativeTabs: nativeTabs
        )
    }
}

struct TaskbarItem: Equatable, Sendable, Identifiable {
    let id: String
    let pid: Int32
    let applicationName: String
    let applicationIdentity: String?
    let applicationBundlePath: String?
    let title: String
    let displayIdentifier: String
    let cgWindowNumber: UInt32?
    let stableOrderKey: String?
    let isHidden: Bool
    let isMinimized: Bool
    let isActive: Bool
    let nativeTabGroupID: String?
    let nativeTabs: [TaskbarTab]

    init(
        id: String,
        pid: Int32,
        applicationName: String,
        applicationIdentity: String? = nil,
        applicationBundlePath: String? = nil,
        title: String,
        displayIdentifier: String,
        cgWindowNumber: UInt32?,
        stableOrderKey: String? = nil,
        isHidden: Bool = false,
        isMinimized: Bool = false,
        isActive: Bool,
        nativeTabGroupID: String? = nil,
        nativeTabs: [TaskbarTab] = []
    ) {
        self.id = id
        self.pid = pid
        self.applicationName = applicationName
        self.applicationIdentity = applicationIdentity
        self.applicationBundlePath = applicationBundlePath
        self.title = title
        self.displayIdentifier = displayIdentifier
        self.cgWindowNumber = cgWindowNumber
        self.stableOrderKey = stableOrderKey
        self.isHidden = isHidden
        self.isMinimized = isMinimized
        self.isActive = isActive
        self.nativeTabGroupID = nativeTabGroupID
        self.nativeTabs = nativeTabs
    }

    var displayTitle: String {
        title.isEmpty ? applicationName : title
    }

    var buttonTitle: String { displayTitle }

    var accessibilityLabel: String {
        "\(applicationName), \(displayTitle)"
    }

    var tooltip: String {
        if isHidden {
            return "Show \(applicationName): \(displayTitle)"
        }
        if isActive {
            return "Minimize \(applicationName): \(displayTitle)"
        }
        if isMinimized {
            return "Restore \(applicationName): \(displayTitle)"
        }
        return "Activate \(applicationName): \(displayTitle)"
    }
}

struct TaskbarState: Equatable, Sendable {
    let displays: [DisplayDescriptor]
    let itemsByDisplay: [String: [TaskbarItem]]
    let fullscreenDisplayIdentifiers: Set<String>

    init(
        displays: [DisplayDescriptor],
        itemsByDisplay: [String: [TaskbarItem]],
        fullscreenDisplayIdentifiers: Set<String> = []
    ) {
        self.displays = displays
        self.itemsByDisplay = itemsByDisplay
        self.fullscreenDisplayIdentifiers = fullscreenDisplayIdentifiers
    }

    static let empty = TaskbarState(displays: [], itemsByDisplay: [:])
}

enum NativeTabGroupMembershipResolver {
    static func assign(_ candidates: [WindowCandidate]) -> [WindowCandidate] {
        var resolved = candidates
        var claimedIndices = Set<Int>()
        let ownerIndices = candidates.indices.filter { candidates[$0].nativeTabs.count > 1 }

        for ownerIndex in ownerIndices {
            let owner = candidates[ownerIndex]
            guard let groupID = owner.nativeTabGroupID,
                let ownerFrame = owner.frame
            else {
                continue
            }
            let ownerTabIndex =
                owner.nativeTabs.firstIndex(where: \.isSelected)
                ?? owner.nativeTabs.firstIndex {
                    CGWindowMatcher.normalized($0.title)
                        == CGWindowMatcher.normalized(owner.title)
                }
            guard let ownerTabIndex else { continue }

            var matchedIndices = [ownerIndex]
            let eligiblePeerIndices = candidates.indices
                .filter { index in
                    index != ownerIndex
                        && !claimedIndices.contains(index)
                        && candidates[index].nativeTabs.isEmpty
                        && candidates[index].pid == owner.pid
                        && candidates[index].isMinimized == owner.isMinimized
                        && approximatelyEqual(candidates[index].frame, ownerFrame)
                }
                .sorted { lhs, rhs in
                    (candidates[lhs].stableKey ?? "") < (candidates[rhs].stableKey ?? "")
                }
            var availableIndices = eligiblePeerIndices
            var isComplete = true
            for tabIndex in owner.nativeTabs.indices where tabIndex != ownerTabIndex {
                let title = CGWindowMatcher.normalized(owner.nativeTabs[tabIndex].title)
                guard
                    let matchOffset = availableIndices.firstIndex(where: { index in
                        CGWindowMatcher.normalized(candidates[index].title) == title
                    })
                else {
                    isComplete = false
                    break
                }
                matchedIndices.append(availableIndices.remove(at: matchOffset))
            }
            if !isComplete,
                eligiblePeerIndices.count == owner.nativeTabs.count - 1
            {
                // Native window and tab titles can update in adjacent event-loop
                // turns. An exact tab count plus identical geometry is sufficient
                // fallback evidence once the AXTabGroup itself is authoritative.
                matchedIndices = [ownerIndex] + eligiblePeerIndices
                isComplete = true
            }
            guard isComplete, matchedIndices.count == owner.nativeTabs.count else { continue }

            claimedIndices.formUnion(matchedIndices)
            for index in matchedIndices where index != ownerIndex {
                resolved[index] = candidates[index].assigningNativeTabGroup(id: groupID, tabs: [])
            }
        }
        return resolved
    }

    private static func approximatelyEqual(_ frame: CGRect?, _ reference: CGRect) -> Bool {
        guard let frame else { return false }
        let tolerance = CGWindowMatcher.boundsTolerance
        return abs(frame.minX - reference.minX) <= tolerance
            && abs(frame.minY - reference.minY) <= tolerance
            && abs(frame.width - reference.width) <= tolerance
            && abs(frame.height - reference.height) <= tolerance
    }
}

struct TinyTaskbarPreferences: Equatable, Sendable {
    var onboardingComplete = false
    var hideMacDock = false

    init(
        onboardingComplete: Bool = false,
        hideMacDock: Bool = false
    ) {
        self.onboardingComplete = onboardingComplete
        self.hideMacDock = hideMacDock
    }

    static let defaults = TinyTaskbarPreferences()
}

extension CGRect {
    var isFiniteGeometry: Bool {
        minX.isFinite && minY.isFinite && maxX.isFinite && maxY.isFinite
            && width.isFinite && height.isFinite
    }

    func approximatelyEquals(_ other: CGRect, tolerance: CGFloat) -> Bool {
        abs(minX - other.minX) <= tolerance
            && abs(minY - other.minY) <= tolerance
            && abs(width - other.width) <= tolerance
            && abs(height - other.height) <= tolerance
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
            candidate.role == "AXWindow",
            candidate.subrole == "AXStandardWindow" || candidate.subrole == "AXDialog",
            !candidate.isHidden || candidate.applicationIsHidden,
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
        excluding excludedIndices: Set<Int> = [],
        allowOffScreen: Bool = false
    ) -> Int? {
        guard let frame = candidate.frame, frame.isFiniteGeometry else { return nil }

        let base = windows.indices
            .filter { index in
                let window = windows[index]
                return !excludedIndices.contains(index)
                    && window.ownerPID == candidate.pid
                    && window.layer == 0
                    && (allowOffScreen || window.isOnScreen)
                    && window.bounds.isFiniteGeometry
            }
            .sorted { preferredWindow(windows[$0], windows[$1]) }
        guard !base.isEmpty else { return nil }

        if let cgWindowNumber = candidate.cgWindowNumber {
            let identityMatches = base.filter {
                windows[$0].windowNumber == cgWindowNumber
            }
            return identityMatches.count == 1 ? identityMatches[0] : nil
        }

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
    static let defaultHeight = TaskbarAppearance.panelHeight
    static let defaultHorizontalInset: CGFloat = 0
    static let defaultBottomInset: CGFloat = 0
    static let topSeparatorHeight: CGFloat = 1
    static let contentVerticalInset: CGFloat = 1
    static let contentLeadingInset: CGFloat = 6
    static let topSeparatorIdentifier = "TinyTaskbar.TaskbarPanel.topSeparator"

    static var contentHeight: CGFloat {
        max(0, defaultHeight - topSeparatorHeight - contentVerticalInset * 2)
    }

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

    /// Converts AppKit's Dock/menu-bar-aware visible frame into the Quartz/AX
    /// top-left coordinate space used by discovered window frames.
    static func nativeWindowWorkArea(for display: DisplayDescriptor) -> CGRect {
        let full = display.appKitFrame
        let visible = display.appKitVisibleFrame
        guard full.isFiniteGeometry, visible.isFiniteGeometry, display.frame.isFiniteGeometry
        else { return .zero }

        let leftInset = max(0, visible.minX - full.minX)
        let rightInset = max(0, full.maxX - visible.maxX)
        let topInset = max(0, full.maxY - visible.maxY)
        let bottomInset = max(0, visible.minY - full.minY)
        return CGRect(
            x: display.frame.minX + leftInset,
            y: display.frame.minY + topInset,
            width: max(0, display.frame.width - leftInset - rightInset),
            height: max(0, display.frame.height - topInset - bottomInset)
        )
    }

    static func constrainedFullHeightWindowFrame(
        for frame: CGRect,
        on display: DisplayDescriptor,
        taskbarHeight: CGFloat,
        tolerance: CGFloat = 4
    ) -> CGRect? {
        let nativeWorkArea = nativeWindowWorkArea(for: display)
        let spansFullDisplayHeight =
            abs(frame.minY - display.frame.minY) <= tolerance
            && abs(frame.maxY - display.frame.maxY) <= tolerance
        guard !spansFullDisplayHeight,
            abs(frame.minY - nativeWorkArea.minY) <= tolerance,
            abs(frame.maxY - nativeWorkArea.maxY) <= tolerance,
            taskbarHeight > 0,
            frame.height > taskbarHeight
        else { return nil }

        return CGRect(
            origin: frame.origin,
            size: CGSize(
                width: frame.width,
                height: frame.height - taskbarHeight)
        )
    }
}

enum FullscreenWindowDetection {
    static func displayIdentifier(
        for window: CGWindowMetadata,
        displays: [DisplayDescriptor],
        tolerance: CGFloat = 4
    ) -> String? {
        guard window.layer == 0, window.isOnScreen, window.bounds.isFiniteGeometry else {
            return nil
        }
        return displays.first { display in
            abs(window.bounds.minX - display.frame.minX) <= tolerance
                && abs(window.bounds.minY - display.frame.minY) <= tolerance
                && abs(window.bounds.maxX - display.frame.maxX) <= tolerance
                && abs(window.bounds.maxY - display.frame.maxY) <= tolerance
        }?.identifier
    }
}

enum TaskbarButtonLayout {
    static let minimumWidth: CGFloat = 102
    static let preferredWidth: CGFloat = 168
    static let widthRange = minimumWidth...preferredWidth
}

struct TaskbarOverflowLayout: Equatable, Sendable {
    let windowWidth: CGFloat
    let contentWidth: CGFloat
    let requiresScrolling: Bool

    static func resolve(
        viewportWidth: CGFloat,
        windowCount: Int,
        fixedContentWidth: CGFloat
    ) -> TaskbarOverflowLayout {
        let viewportWidth = max(0, viewportWidth)
        let fixedContentWidth = max(0, fixedContentWidth)
        guard windowCount > 0 else {
            return TaskbarOverflowLayout(
                windowWidth: 0,
                contentWidth: fixedContentWidth,
                requiresScrolling: fixedContentWidth > viewportWidth
            )
        }

        let availableWindowWidth = max(0, viewportWidth - fixedContentWidth)
        let availablePerWindow = availableWindowWidth / CGFloat(windowCount)
        let resolvedWindowWidth = min(
            TaskbarButtonLayout.widthRange.upperBound,
            max(TaskbarButtonLayout.widthRange.lowerBound, availablePerWindow)
        )
        let contentWidth = fixedContentWidth + resolvedWindowWidth * CGFloat(windowCount)
        return TaskbarOverflowLayout(
            windowWidth: resolvedWindowWidth,
            contentWidth: contentWidth,
            requiresScrolling: contentWidth > viewportWidth + 0.5
        )
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
            switch (lhs.stableOrderKey, rhs.stableOrderKey) {
            case (let lhsKey?, let rhsKey?) where lhsKey != rhsKey:
                return lhsKey < rhsKey
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                break
            }

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
            .filter {
                candidates[$0].isNativeTabGroupRepresentative
                    && eligibility.isEligible(candidates[$0], selfPID: selfPID)
            }
            .sorted { WindowCandidateOrdering.preferred(candidates[$0], candidates[$1]) }

        for candidateIndex in orderedCandidateIndices {
            guard
                let cgWindowIndex = CGWindowMatcher.matchIndex(
                    candidate: candidates[candidateIndex],
                    windows: cgWindows,
                    excluding: usedCGWindowIndices,
                    allowOffScreen: (candidates[candidateIndex].isMinimized
                        || candidates[candidateIndex].applicationIsHidden)
                        && candidates[candidateIndex].cgWindowNumber != nil
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
        assignments suppliedAssignments: [Int: Int]? = nil,
        displays: [DisplayDescriptor],
        selfPID: Int32,
        frontmostPID: Int32? = nil,
        eligibility: WindowEligibility = WindowEligibility()
    ) -> TaskbarState {
        var projected: [TaskbarItem] = []
        var fullscreenDisplayIdentifiers: Set<String> = []
        let assignments =
            suppliedAssignments
            ?? WindowCGAssignment.assign(
                candidates: candidates,
                cgWindows: cgWindows,
                selfPID: selfPID,
                eligibility: WindowEligibility(minimumSize: eligibility.minimumSize)
            )

        for candidateIndex in candidates.indices {
            let candidate = candidates[candidateIndex]
            guard
                eligibility.isEligible(candidate, selfPID: selfPID),
                let frame = candidate.frame,
                let displayIdentifier = DisplayMapper.identifier(for: frame, displays: displays)
            else {
                continue
            }

            // Only project windows with physical-window evidence. Normal windows must
            // be on-screen; minimized windows may use their exact AX-derived CG window
            // number to match an off-screen `.optionAll` record. AX-only minimized
            // candidates remain excluded, so ambiguous tab siblings are never admitted
            // through title/frame guesses alone. Hidden applications are retained by
            // continuity only after their windows were physically observed on-screen;
            // admitting every hidden off-screen record would also admit background tabs.
            guard let cgWindowIndex = assignments[candidateIndex] else { continue }
            let cgWindow = cgWindows[cgWindowIndex]
            guard cgWindow.isOnScreen || candidate.isMinimized else { continue }

            if !candidate.applicationIsHidden,
                !candidate.isHidden,
                !candidate.isMinimized,
                candidate.isFullscreen
            {
                fullscreenDisplayIdentifiers.insert(displayIdentifier)
            } else if !candidate.applicationIsHidden,
                !candidate.isHidden,
                !candidate.isMinimized,
                let geometryDisplayIdentifier = FullscreenWindowDetection.displayIdentifier(
                    for: cgWindow,
                    displays: displays)
            {
                fullscreenDisplayIdentifiers.insert(geometryDisplayIdentifier)
            }

            let id =
                WindowObservationKey.itemKey(
                    candidate: candidate,
                    cgWindow: cgWindow
                )
            let isActive =
                !candidate.isMinimized && !candidate.applicationIsHidden
                && frontmostPID == candidate.pid
                && (candidate.isFocused || candidate.isMain)
            projected.append(
                TaskbarItem(
                    id: id,
                    pid: candidate.pid,
                    applicationName: candidate.localizedApplicationName,
                    applicationIdentity: candidate.applicationIdentity,
                    applicationBundlePath: candidate.applicationBundlePath,
                    title: candidate.title,
                    displayIdentifier: displayIdentifier,
                    cgWindowNumber: cgWindow.windowNumber,
                    stableOrderKey: candidate.nativeTabGroupID ?? candidate.stableKey,
                    isHidden: candidate.applicationIsHidden,
                    isMinimized: candidate.isMinimized,
                    isActive: isActive,
                    nativeTabGroupID: candidate.nativeTabGroupID,
                    nativeTabs: candidate.nativeTabs
                )
            )
        }

        let grouped = Dictionary(grouping: WindowDeduplicator.deduplicate(projected)) {
            $0.displayIdentifier
        }
        let ordered = grouped.mapValues(WindowOrdering.sorted)
        let orderedDisplays = displays.sorted(by: preferredDisplay)
        return TaskbarState(
            displays: orderedDisplays,
            itemsByDisplay: ordered,
            fullscreenDisplayIdentifiers: fullscreenDisplayIdentifiers)
    }

    private static func preferredDisplay(_ lhs: DisplayDescriptor, _ rhs: DisplayDescriptor) -> Bool
    {
        if lhs.identifier != rhs.identifier { return lhs.identifier < rhs.identifier }
        return lhs.ordinal < rhs.ordinal
    }
}

enum StableWindowKey {
    static func make(candidate: WindowCandidate, cgWindow: CGWindowMetadata?) -> String {
        if let windowNumber = cgWindow?.windowNumber {
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
    static func itemKey(candidate: WindowCandidate, cgWindow: CGWindowMetadata?) -> String {
        candidate.nativeTabGroupID
            ?? candidate.stableKey
            ?? StableWindowKey.make(candidate: candidate, cgWindow: cgWindow)
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
