import AppKit
import ApplicationServices
import Foundation
import OSLog
import ServiceManagement
import SwiftUI

struct RefreshMetrics: Equatable, Sendable {
    fileprivate(set) var refreshCount = 0
    fileprivate(set) var lastCandidateCount = 0
    fileprivate(set) var lastVisibleWindowCount = 0
    fileprivate(set) var lastDurationMilliseconds = 0.0
}

/// AX and Core Graphics can disagree while a window is moving. Preserve an already-
/// rendered identity for as long as either authoritative source still reports it,
/// rather than making a time-based guess about whether the window was closed.
enum TaskbarRefreshCause: Equatable, Sendable {
    case ordinary
    case activeSpaceChanged
}

enum TaskbarItemResolver {
    static func currentItem(for requested: TaskbarItem, in state: TaskbarState) -> TaskbarItem? {
        let items = Array(state.itemsByDisplay.values.joined())
        if let exact = items.first(where: { $0.id == requested.id }) {
            return exact
        }
        guard let cgWindowNumber = requested.cgWindowNumber else { return nil }
        let physicalMatches = items.filter {
            $0.pid == requested.pid && $0.cgWindowNumber == cgWindowNumber
        }
        return physicalMatches.count == 1 ? physicalMatches[0] : nil
    }

    static func representsSameWindow(_ lhs: TaskbarItem, _ rhs: TaskbarItem) -> Bool {
        if lhs.id == rhs.id { return true }
        guard let lhsWindowNumber = lhs.cgWindowNumber,
            let rhsWindowNumber = rhs.cgWindowNumber
        else { return false }
        return lhs.pid == rhs.pid && lhsWindowNumber == rhsWindowNumber
    }
}

struct TaskbarStateContinuity {
    func resolve(
        previous: TaskbarState,
        incoming: TaskbarState,
        snapshot: RawWindowSnapshot,
        cause: TaskbarRefreshCause = .ordinary
    ) -> TaskbarState {
        let incomingItems = Array(incoming.itemsByDisplay.values.joined())
        let incomingIDs = Set(incomingItems.map(\.id))
        var claimedCGWindows = Set(incomingItems.compactMap(PhysicalWindowIdentity.init))
        var resolvedItemsByDisplay = incoming.itemsByDisplay

        for item in previous.itemsByDisplay.values.joined() where !incomingIDs.contains(item.id) {
            // AX element equality can occasionally turn over and assign a new stable ID
            // while CG still identifies the same physical window. The incoming item owns
            // that current AX reference; retaining the old alias would render duplicates
            // and leave actions attached to the stale ID.
            if let identity = PhysicalWindowIdentity(item), claimedCGWindows.contains(identity) {
                continue
            }
            guard
                let retained = retainedItem(
                    for: item,
                    snapshot: snapshot,
                    cause: cause
                ),
                !incomingIDs.contains(retained.id)
            else {
                continue
            }
            if let identity = PhysicalWindowIdentity(retained),
                !claimedCGWindows.insert(identity).inserted
            {
                continue
            }
            resolvedItemsByDisplay[retained.displayIdentifier, default: []].append(retained)
        }

        resolvedItemsByDisplay = resolvedItemsByDisplay.mapValues { items in
            WindowOrdering.sorted(WindowDeduplicator.deduplicate(items))
        }
        return TaskbarState(
            displays: incoming.displays,
            itemsByDisplay: resolvedItemsByDisplay,
            fullscreenDisplayIdentifiers: incoming.fullscreenDisplayIdentifiers
        )
    }

    private struct PhysicalWindowIdentity: Hashable {
        let pid: Int32
        let cgWindowNumber: UInt32

        init?(_ item: TaskbarItem) {
            guard let cgWindowNumber = item.cgWindowNumber else { return nil }
            pid = item.pid
            self.cgWindowNumber = cgWindowNumber
        }
    }

    private func retainedItem(
        for item: TaskbarItem,
        snapshot: RawWindowSnapshot,
        cause: TaskbarRefreshCause
    ) -> TaskbarItem? {
        let candidate = matchingCandidate(for: item, candidates: snapshot.candidates)
        if let candidate, hasAuthoritativeIneligibility(candidate) {
            return nil
        }

        if let cgWindow = matchingCGWindow(for: item, windows: snapshot.cgWindows) {
            let displayIdentifier = displayIdentifier(
                for: cgWindow.bounds,
                fallback: item.displayIdentifier,
                displays: snapshot.displays
            )
            return refreshedItem(
                item,
                candidate: candidate,
                cgWindow: cgWindow,
                displayIdentifier: displayIdentifier,
                frontmostPID: snapshot.frontmostPID
            )
        }

        // Native tab containers keep every tab in the AX window list, but Core
        // Graphics marks only the selected tab's exact window identity on-screen.
        // Treat a matching off-screen record as positive replacement evidence;
        // unlike a missing CG record, it is not an inconclusive move-time gap.
        if let candidate,
            !candidate.isMinimized,
            !candidate.applicationIsHidden,
            hasExactOffScreenCGWindow(
                for: item,
                candidate: candidate,
                windows: snapshot.cgWindows
            )
        {
            return nil
        }

        // A Space change makes the current on-screen CG list authoritative for
        // membership. Do not let an AX-only candidate from the prior Space leak
        // into the new one.
        guard cause != .activeSpaceChanged else { return nil }

        if let candidate {
            // AX exposes native macOS tabs as separate windows. When their container is
            // minimized, previously hidden tab siblings can all report `AXMinimized`
            // despite never having matched a physical on-screen CG window. Keep only
            // minimized items with positive prior physical-window evidence.
            guard !candidate.isMinimized || item.cgWindowNumber != nil else { return nil }
            let displayIdentifier = displayIdentifier(
                for: candidate.frame,
                fallback: item.displayIdentifier,
                displays: snapshot.displays
            )
            return refreshedItem(
                item,
                candidate: candidate,
                cgWindow: nil,
                displayIdentifier: displayIdentifier,
                frontmostPID: snapshot.frontmostPID
            )
        }

        // A successful AX window-list read may still have an element whose
        // attributes could not be decoded. Its stable ID is positive existence
        // evidence even though no WindowCandidate was projected.
        if snapshot.evidence.observedAXWindowIDs.contains(item.id) {
            return item
        }

        // If the provider could not read this application's AX window list, the
        // omission is inconclusive. Keep the rendered item until a later event
        // yields authoritative evidence; this is deliberately not a timer.
        guard snapshot.evidence.isComplete else { return item }
        guard snapshot.evidence.knownApplicationPIDs.contains(item.pid) else {
            return nil
        }
        guard snapshot.evidence.axWindowListReadPIDs.contains(item.pid) else {
            return item
        }

        // The application's AX window list was read successfully, and neither
        // that list nor the current CG list contains this identity.
        return nil
    }

    private func matchingCandidate(
        for item: TaskbarItem,
        candidates: [WindowCandidate]
    ) -> WindowCandidate? {
        let stableMatches = candidates.filter { candidate in
            candidate.stableKey == item.id
                || (candidate.stableKey != nil && candidate.stableKey == item.stableOrderKey)
                || (candidate.nativeTabGroupID != nil
                    && (candidate.nativeTabGroupID == item.nativeTabGroupID
                        || candidate.nativeTabGroupID == item.id))
        }
        let representativeMatches = stableMatches.filter(\.isNativeTabGroupRepresentative)
        if representativeMatches.count == 1 {
            return representativeMatches[0]
        }
        guard representativeMatches.isEmpty, item.stableOrderKey == nil else { return nil }

        // Older/fallback identities are based on a CG window number. If AX has
        // temporarily omitted that identity, only a unique same-title candidate
        // from the owning process is safe to associate; another window from the
        // same process alone is not positive identity evidence.
        let processMatches = candidates.filter {
            return $0.pid == item.pid
                && CGWindowMatcher.normalized($0.title)
                    == CGWindowMatcher.normalized(item.title)
        }
        return processMatches.count == 1 ? processMatches[0] : nil
    }

    private func matchingCGWindow(
        for item: TaskbarItem,
        windows: [CGWindowMetadata]
    ) -> CGWindowMetadata? {
        guard let windowNumber = item.cgWindowNumber else { return nil }
        let matches = windows.filter {
            $0.windowNumber == windowNumber
                && $0.ownerPID == item.pid
                && $0.layer == 0
                && $0.isOnScreen
        }
        return matches.count == 1 ? matches[0] : nil
    }

    private func hasExactOffScreenCGWindow(
        for item: TaskbarItem,
        candidate: WindowCandidate,
        windows: [CGWindowMetadata]
    ) -> Bool {
        guard let windowNumber = item.cgWindowNumber,
            candidate.cgWindowNumber == windowNumber
        else {
            return false
        }
        let matches = windows.filter {
            $0.windowNumber == windowNumber
                && $0.ownerPID == item.pid
                && $0.layer == 0
        }
        return matches.count == 1 && !matches[0].isOnScreen
    }

    private func hasAuthoritativeIneligibility(_ candidate: WindowCandidate) -> Bool {
        guard candidate.applicationIsRunning,
            candidate.applicationIsRegular,
            candidate.role == "AXWindow",
            candidate.subrole == "AXStandardWindow" || candidate.subrole == "AXDialog",
            !candidate.isHidden || candidate.applicationIsHidden
        else {
            return true
        }

        // A missing or malformed frame is an incomplete AX read, not proof that
        // the window was closed. A finite frame below the normal eligibility
        // threshold is authoritative ineligibility.
        guard let frame = candidate.frame, frame.isFiniteGeometry else { return false }
        return frame.width < WindowEligibility.defaultMinimumSize.width
            || frame.height < WindowEligibility.defaultMinimumSize.height
            || frame.width <= 0
            || frame.height <= 0
    }

    private func displayIdentifier(
        for frame: CGRect?,
        fallback: String,
        displays: [DisplayDescriptor]
    ) -> String {
        guard let frame, let identifier = DisplayMapper.identifier(for: frame, displays: displays)
        else {
            return fallback
        }
        return identifier
    }

    private func refreshedItem(
        _ item: TaskbarItem,
        candidate: WindowCandidate?,
        cgWindow: CGWindowMetadata?,
        displayIdentifier: String,
        frontmostPID: Int32?
    ) -> TaskbarItem {
        let isMinimized = candidate?.isMinimized ?? item.isMinimized
        let isHidden = candidate?.applicationIsHidden ?? item.isHidden
        let isActive: Bool
        if let candidate {
            isActive =
                !candidate.isMinimized
                && !candidate.applicationIsHidden
                && frontmostPID == candidate.pid
                && (candidate.isFocused || candidate.isMain)
        } else {
            isActive = item.isActive
        }
        let nativeTabs: [TaskbarTab]
        if let candidate, !candidate.nativeTabs.isEmpty {
            nativeTabs = candidate.nativeTabs
        } else {
            nativeTabs = item.nativeTabs
        }
        return TaskbarItem(
            id: item.id,
            pid: candidate?.pid ?? item.pid,
            applicationName: candidate?.localizedApplicationName ?? item.applicationName,
            applicationIdentity: candidate?.applicationIdentity ?? item.applicationIdentity,
            applicationBundlePath: candidate?.applicationBundlePath ?? item.applicationBundlePath,
            title: candidate?.title ?? item.title,
            displayIdentifier: displayIdentifier,
            cgWindowNumber: cgWindow?.windowNumber ?? item.cgWindowNumber,
            stableOrderKey: item.stableOrderKey ?? candidate?.nativeTabGroupID
                ?? candidate?.stableKey,
            isHidden: isHidden,
            isMinimized: isMinimized,
            isActive: isActive,
            nativeTabGroupID: candidate?.nativeTabGroupID ?? item.nativeTabGroupID,
            nativeTabs: nativeTabs
        )
    }
}

private struct TaskbarWorkAreaAdjustment {
    let displayIdentifier: String
    let originalFrame: CGRect
    var appliedFrame: CGRect
    var hasObservedAppliedFrame: Bool
    var attemptCount: Int
}

@MainActor
final class TaskbarStore {
    private struct PrimaryClickFocusReturn {
        let activatedItem: TaskbarItem
        let returnItem: TaskbarItem
    }

    private static let maximumWorkAreaAdjustmentAttempts = 5
    private static let windowDisappearanceConfirmationDelay = Duration.milliseconds(350)
    private let provider: any WindowSnapshotProvider
    private let logger = Logger(subsystem: "com.tinytaskbar", category: "refresh")
    private var pendingRefresh: Task<Void, Never>?
    private var pendingWindowDisappearanceConfirmation: Task<Void, Never>?
    private var pendingWorkAreaVerification: Task<Void, Never>?
    private var continuity = TaskbarStateContinuity()
    private var pendingRefreshCause: TaskbarRefreshCause = .ordinary
    private var activeSpaceNotificationToken: NSObjectProtocol?
    private var latestFramesByItemID: [String: CGRect] = [:]
    private var latestDisplaysByID: [String: DisplayDescriptor] = [:]
    private var taskbarHeightsByDisplay: [String: CGFloat] = [:]
    private var workAreaAdjustments: [String: TaskbarWorkAreaAdjustment] = [:]
    private var primaryClickFocusReturn: PrimaryClickFocusReturn?
    private(set) var state = TaskbarState.empty
    private(set) var lifecycleState: LifecycleState = .stopped
    private(set) var accessibilityAvailable = false
    private(set) var metrics = RefreshMetrics()

    var onStateChange: (@MainActor (TaskbarState) -> Void)?

    init(provider: any WindowSnapshotProvider) {
        self.provider = provider
    }

    func start(accessibilityTrusted: Bool) {
        lifecycleState = LifecycleReducer.reduce(
            state: lifecycleState,
            event: .launched(accessibilityTrusted: accessibilityTrusted)
        )
        accessibilityAvailable = accessibilityTrusted
        if accessibilityTrusted {
            observeActiveSpaceChanges()
            requestRefresh()
        }
    }

    func setAccessibilityAvailable(_ available: Bool) {
        if !available, accessibilityAvailable {
            releaseTaskbarWorkAreas()
        }
        accessibilityAvailable = available
        lifecycleState = LifecycleReducer.reduce(
            state: lifecycleState,
            event: .accessibilityChanged(available)
        )

        guard available else {
            pendingRefresh?.cancel()
            pendingRefresh = nil
            pendingWindowDisappearanceConfirmation?.cancel()
            pendingWindowDisappearanceConfirmation = nil
            pendingRefreshCause = .ordinary
            primaryClickFocusReturn = nil
            removeActiveSpaceObserver()
            if state != .empty {
                state = .empty
                onStateChange?(state)
            }
            return
        }

        observeActiveSpaceChanges()
        requestRefresh()
    }

    func requestRefresh(cause: TaskbarRefreshCause = .ordinary) {
        guard accessibilityAvailable else { return }
        if cause == .activeSpaceChanged {
            pendingRefreshCause = .activeSpaceChanged
        }
        guard pendingRefresh == nil else { return }

        pendingRefresh = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: 50_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.pendingRefresh = nil
            self?.refreshNow()
        }
    }

    func requestWindowDisappearanceConfirmation() {
        guard accessibilityAvailable else { return }
        pendingWindowDisappearanceConfirmation?.cancel()
        pendingWindowDisappearanceConfirmation = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.windowDisappearanceConfirmationDelay)
            guard !Task.isCancelled, let self, self.accessibilityAvailable else { return }
            self.pendingWindowDisappearanceConfirmation = nil
            self.refreshNow()
        }
    }

    func refreshNow() {
        guard accessibilityAvailable else { return }

        let start = DispatchTime.now().uptimeNanoseconds
        let snapshot = provider.snapshot()
        latestFramesByItemID = Dictionary(
            uniqueKeysWithValues: snapshot.candidates.compactMap { candidate in
                guard candidate.isNativeTabGroupRepresentative,
                    let id = candidate.nativeTabGroupID ?? candidate.stableKey,
                    let frame = candidate.frame
                else {
                    return nil
                }
                return (id, frame)
            })
        latestDisplaysByID = Dictionary(
            uniqueKeysWithValues: snapshot.displays.map { ($0.identifier, $0) })
        let projected = WindowProjection.project(
            candidates: snapshot.candidates,
            cgWindows: snapshot.cgWindows,
            displays: snapshot.displays,
            selfPID: ProcessInfo.processInfo.processIdentifier,
            frontmostPID: snapshot.frontmostPID
        )
        let cause = pendingRefreshCause
        pendingRefreshCause = .ordinary
        let resolved = continuity.resolve(
            previous: state,
            incoming: projected,
            snapshot: snapshot,
            cause: cause
        )
        let elapsed = DispatchTime.now().uptimeNanoseconds - start
        let durationMilliseconds = Double(elapsed) / 1_000_000

        metrics.refreshCount += 1
        metrics.lastCandidateCount = snapshot.candidates.count
        metrics.lastVisibleWindowCount = resolved.itemsByDisplay.values.reduce(0) { $0 + $1.count }
        metrics.lastDurationMilliseconds = durationMilliseconds
        logger.debug(
            "refresh candidates=\(snapshot.candidates.count, privacy: .public) visible=\(self.metrics.lastVisibleWindowCount, privacy: .public) duration_ms=\(durationMilliseconds, privacy: .public)"
        )

        if resolved != state {
            state = resolved
            onStateChange?(state)
        } else if cause == .activeSpaceChanged {
            // Rendering must still run for an empty or otherwise identical Space:
            // AppDelegate may need to create or reuse the panel attached to that
            // Desktop even when its projected taskbar contents equal the old state.
            onStateChange?(state)
        }
        applyTaskbarWorkAreas()
    }

    func setTaskbarWorkAreaHeights(_ heightsByDisplay: [String: CGFloat]) {
        guard accessibilityAvailable else { return }
        let positiveHeights = heightsByDisplay.filter { $0.value > 0 }
        let removedDisplayIdentifiers = Set(taskbarHeightsByDisplay.keys).subtracting(
            positiveHeights.keys)
        releaseTaskbarWorkAreas(on: removedDisplayIdentifiers)
        if positiveHeights.isEmpty {
            releaseTaskbarWorkAreas()
            taskbarHeightsByDisplay = [:]
            return
        }
        taskbarHeightsByDisplay = positiveHeights
        applyTaskbarWorkAreas()
    }

    func activate(_ item: TaskbarItem) {
        guard accessibilityAvailable else { return }

        // A rendered item can be one event behind the actual frontmost window.
        // Refresh synchronously so a second click toggles the window that is truly
        // focused now, rather than trusting stale button presentation state.
        refreshNow()
        guard
            let currentItem = TaskbarItemResolver.currentItem(for: item, in: state)
        else {
            return
        }

        if currentItem.isActive {
            provider.minimize(currentItem)
        } else {
            provider.activate(currentItem)
        }
        requestRefresh()
    }

    func performPrimaryClick(
        _ requestedItem: TaskbarItem,
        activeWindowBehavior: ActiveWindowClickBehavior
    ) {
        guard accessibilityAvailable else { return }
        refreshNow()
        guard
            let item = TaskbarItemResolver.currentItem(for: requestedItem, in: state)
        else { return }

        if item.isActive {
            if activeWindowBehavior == .minimize {
                if let returnItem = primaryClickReturnItem(for: item) {
                    // Move focus away first. Minimizing a frontmost window can make macOS
                    // promote a sibling from the same app before another app is activated.
                    provider.activate(returnItem)
                }
                primaryClickFocusReturn = nil
                provider.minimize(item)
            }
        } else {
            rememberPrimaryClickReturn(for: item)
            provider.activate(item)
        }
        requestRefresh()
    }

    func execute(
        _ command: WindowCommand,
        excludingApplicationIdentities excludedIdentities: Set<String> = []
    ) {
        guard accessibilityAvailable else { return }
        refreshNow()
        if command == .minimizeAll {
            for item in WindowOrdering.sorted(Array(state.itemsByDisplay.values.joined()))
            where !item.isMinimized && !item.isHidden
                && !(item.applicationIdentity.map { excludedIdentities.contains($0) } ?? false)
            {
                provider.minimize(item)
            }
            requestRefresh()
            return
        }
        let requestedItem: TaskbarItem
        switch command {
        case .activate(let item), .minimize(let item), .restore(let item),
            .close(let item), .closeTabGroup(let item), .minimizeOthers(let item):
            requestedItem = item
        case .selectTab(let item, _), .closeTab(let item, _):
            requestedItem = item
        case .minimizeAll:
            return
        }
        guard
            let item = TaskbarItemResolver.currentItem(for: requestedItem, in: state)
        else { return }
        switch command {
        case .activate, .restore:
            provider.activate(item)
        case .minimize:
            provider.minimize(item)
        case .selectTab(_, let tab):
            provider.selectTab(tab, in: item)
        case .closeTab(_, let tab):
            provider.closeTab(tab, in: item)
            requestWindowDisappearanceConfirmation()
        case .closeTabGroup:
            provider.closeTabGroup(item)
            requestWindowDisappearanceConfirmation()
        case .close:
            provider.close(item)
            requestWindowDisappearanceConfirmation()
        case .minimizeOthers:
            let currentItems = state.itemsByDisplay[item.displayIdentifier] ?? []
            for other in currentItems
            where other.id != item.id && !other.isMinimized && !other.isHidden
                && !(other.applicationIdentity.map { excludedIdentities.contains($0) } ?? false)
            {
                provider.minimize(other)
            }
            provider.activate(item)
        case .minimizeAll:
            return
        }
        requestRefresh()
    }

    func close(_ item: TaskbarItem) {
        guard accessibilityAvailable else { return }
        provider.close(item)
        requestRefresh()
        requestWindowDisappearanceConfirmation()
    }

    func stop() {
        releaseTaskbarWorkAreas()
        pendingRefresh?.cancel()
        pendingRefresh = nil
        pendingWindowDisappearanceConfirmation?.cancel()
        pendingWindowDisappearanceConfirmation = nil
        pendingWorkAreaVerification?.cancel()
        pendingWorkAreaVerification = nil
        pendingRefreshCause = .ordinary
        primaryClickFocusReturn = nil
        removeActiveSpaceObserver()
        lifecycleState = LifecycleReducer.reduce(state: lifecycleState, event: .stopped)
        accessibilityAvailable = false
        if state != .empty {
            state = .empty
            onStateChange?(state)
        }
    }

    private func applyTaskbarWorkAreas() {
        guard accessibilityAvailable, !taskbarHeightsByDisplay.isEmpty else { return }
        let itemsByID = Dictionary(
            uniqueKeysWithValues: state.itemsByDisplay.values.joined().map { ($0.id, $0) })
        workAreaAdjustments = workAreaAdjustments.filter { itemsByID[$0.key] != nil }

        for item in itemsByID.values where !item.isMinimized && !item.isHidden {
            guard let currentFrame = latestFramesByItemID[item.id],
                let display = latestDisplaysByID[item.displayIdentifier],
                let taskbarHeight = taskbarHeightsByDisplay[item.displayIdentifier]
            else { continue }

            if var adjustment = workAreaAdjustments[item.id] {
                if currentFrame.approximatelyEquals(adjustment.appliedFrame, tolerance: 4) {
                    adjustment.hasObservedAppliedFrame = true
                    adjustment.attemptCount = 0
                    workAreaAdjustments[item.id] = adjustment
                } else if !currentFrame.approximatelyEquals(
                    adjustment.originalFrame, tolerance: 4)
                {
                    workAreaAdjustments.removeValue(forKey: item.id)
                }
                if workAreaAdjustments[item.id] != nil {
                    guard
                        let target = TaskbarPanelLayout.constrainedFullHeightWindowFrame(
                            for: adjustment.originalFrame,
                            on: display,
                            taskbarHeight: taskbarHeight)
                    else {
                        workAreaAdjustments.removeValue(forKey: item.id)
                        continue
                    }
                    guard !currentFrame.approximatelyEquals(target, tolerance: 1) else { continue }
                    if !adjustment.hasObservedAppliedFrame,
                        adjustment.attemptCount
                            >= Self.maximumWorkAreaAdjustmentAttempts
                    {
                        // Avoid an AX write loop for a window that rejects resizing. A later
                        // real window event starts another bounded correction cycle.
                        workAreaAdjustments.removeValue(forKey: item.id)
                        continue
                    }
                    _ = provider.setHeight(target.height, for: item)
                    adjustment.appliedFrame = target
                    adjustment.hasObservedAppliedFrame = false
                    adjustment.attemptCount += 1
                    workAreaAdjustments[item.id] = adjustment
                    scheduleWorkAreaVerification()
                    continue
                }
            }

            guard
                let target = TaskbarPanelLayout.constrainedFullHeightWindowFrame(
                    for: currentFrame,
                    on: display,
                    taskbarHeight: taskbarHeight)
            else { continue }
            _ = provider.setHeight(target.height, for: item)
            workAreaAdjustments[item.id] = TaskbarWorkAreaAdjustment(
                displayIdentifier: item.displayIdentifier,
                originalFrame: currentFrame,
                appliedFrame: target,
                hasObservedAppliedFrame: false,
                attemptCount: 1)
            scheduleWorkAreaVerification()
        }
    }

    private func rememberPrimaryClickReturn(for item: TaskbarItem) {
        let activeItem = state.itemsByDisplay.values.joined().first {
            $0.isActive && !TaskbarItemResolver.representsSameWindow($0, item)
        }
        primaryClickFocusReturn = activeItem.map {
            PrimaryClickFocusReturn(activatedItem: item, returnItem: $0)
        }
    }

    private func primaryClickReturnItem(for item: TaskbarItem) -> TaskbarItem? {
        guard let focusReturn = primaryClickFocusReturn,
            TaskbarItemResolver.representsSameWindow(focusReturn.activatedItem, item)
        else { return nil }
        return TaskbarItemResolver.currentItem(for: focusReturn.returnItem, in: state)
    }

    private func scheduleWorkAreaVerification() {
        guard pendingWorkAreaVerification == nil else { return }
        pendingWorkAreaVerification = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: 150_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.pendingWorkAreaVerification = nil
            self?.refreshNow()
        }
    }

    private func releaseTaskbarWorkAreas() {
        pendingWorkAreaVerification?.cancel()
        pendingWorkAreaVerification = nil
        guard accessibilityAvailable else {
            workAreaAdjustments = [:]
            return
        }
        let itemsByID = Dictionary(
            uniqueKeysWithValues: state.itemsByDisplay.values.joined().map { ($0.id, $0) })
        for (itemID, adjustment) in workAreaAdjustments {
            guard let item = itemsByID[itemID],
                let currentFrame = latestFramesByItemID[itemID],
                currentFrame.approximatelyEquals(adjustment.appliedFrame, tolerance: 4)
                    || (!adjustment.hasObservedAppliedFrame
                        && currentFrame.approximatelyEquals(
                            adjustment.originalFrame, tolerance: 4))
            else { continue }
            _ = provider.setHeight(adjustment.originalFrame.height, for: item)
        }
        workAreaAdjustments = [:]
    }

    private func releaseTaskbarWorkAreas(on displayIdentifiers: Set<String>) {
        guard !displayIdentifiers.isEmpty else { return }
        guard accessibilityAvailable else {
            workAreaAdjustments = workAreaAdjustments.filter {
                !displayIdentifiers.contains($0.value.displayIdentifier)
            }
            return
        }
        let itemsByID = Dictionary(
            uniqueKeysWithValues: state.itemsByDisplay.values.joined().map { ($0.id, $0) })
        let adjustmentIDs = workAreaAdjustments.compactMap { itemID, adjustment in
            displayIdentifiers.contains(adjustment.displayIdentifier) ? itemID : nil
        }
        for itemID in adjustmentIDs {
            guard let adjustment = workAreaAdjustments.removeValue(forKey: itemID),
                let item = itemsByID[itemID],
                let currentFrame = latestFramesByItemID[itemID],
                currentFrame.approximatelyEquals(adjustment.appliedFrame, tolerance: 4)
                    || (!adjustment.hasObservedAppliedFrame
                        && currentFrame.approximatelyEquals(
                            adjustment.originalFrame, tolerance: 4))
            else { continue }
            _ = provider.setHeight(adjustment.originalFrame.height, for: item)
        }
    }

    private func observeActiveSpaceChanges() {
        guard activeSpaceNotificationToken == nil else { return }
        let center = NSWorkspace.shared.notificationCenter
        activeSpaceNotificationToken = center.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.accessibilityAvailable else { return }
                self.requestRefresh(cause: .activeSpaceChanged)
            }
        }
    }

    private func removeActiveSpaceObserver() {
        if let token = activeSpaceNotificationToken {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
            activeSpaceNotificationToken = nil
        }
    }

}

enum AccessibilityPermissionRequestDecision: Equatable, Sendable {
    case request
    case alreadyRequested
}

struct AccessibilityPermissionRequestState: Equatable, Sendable {
    private(set) var didRequest = false

    mutating func decision() -> AccessibilityPermissionRequestDecision {
        guard !didRequest else { return .alreadyRequested }
        didRequest = true
        return .request
    }
}

enum SettingsActivationPolicy: Equatable, Sendable {
    case accessory
    case regular
}

enum SettingsVisibilityEvent: Equatable, Sendable {
    case show
    case close
}

struct SettingsActivationPolicyState: Equatable, Sendable {
    private(set) var policy: SettingsActivationPolicy = .accessory

    mutating func apply(_ event: SettingsVisibilityEvent) -> SettingsActivationPolicy {
        switch event {
        case .show:
            policy = .regular
        case .close:
            policy = .accessory
        }
        return policy
    }
}

@MainActor
final class TinyTaskbarPreferencesStore {
    private static let onboardingCompleteKey = "onboardingComplete"
    private static let hideMacDockKey = "hideMacDock"
    private static let activeWindowClickBehaviorKey = "activeWindowClickBehavior"
    private static let orderingModeKey = "orderingMode"
    private static let labelModeKey = "labelMode"
    private static let densityKey = "density"
    private static let buttonWidthKey = "buttonWidth"
    private static let overflowBehaviorKey = "overflowBehavior"
    private static let displayModeKey = "displayMode"
    private static let pinnedApplicationsKey = "pinnedApplications"
    private static let excludedApplicationsKey = "excludedApplications"

    private let defaults: UserDefaults
    private(set) var values: TinyTaskbarPreferences

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let labelMode =
            TaskbarLabelMode(rawValue: defaults.string(forKey: Self.labelModeKey) ?? "")
            ?? .windowTitle
        values = TinyTaskbarPreferences(
            onboardingComplete: defaults.object(forKey: Self.onboardingCompleteKey) as? Bool
                ?? TinyTaskbarPreferences.defaults.onboardingComplete,
            hideMacDock: defaults.object(forKey: Self.hideMacDockKey) as? Bool
                ?? TinyTaskbarPreferences.defaults.hideMacDock,
            activeWindowClickBehavior: ActiveWindowClickBehavior(
                rawValue: defaults.string(forKey: Self.activeWindowClickBehaviorKey) ?? "")
                ?? .minimize,
            orderingMode: TaskbarOrderingMode(
                rawValue: defaults.string(forKey: Self.orderingModeKey) ?? "")
                ?? .windowOrder,
            labelMode: labelMode,
            density: TaskbarDensity(
                rawValue: defaults.string(forKey: Self.densityKey) ?? "")
                ?? .standard,
            buttonWidth: TaskbarButtonWidth(
                rawValue: defaults.string(forKey: Self.buttonWidthKey) ?? "")
                ?? .balanced,
            overflowBehavior: TaskbarOverflowBehavior(
                rawValue: defaults.string(forKey: Self.overflowBehaviorKey) ?? "")
                ?? .shrinkThenScroll,
            displayMode: TaskbarDisplayMode(
                rawValue: defaults.string(forKey: Self.displayModeKey) ?? "")
                ?? .windowDisplay,
            pinnedApplications: Self.decodeRecords(
                defaults.data(forKey: Self.pinnedApplicationsKey)),
            excludedApplications: Self.decodeRecords(
                defaults.data(forKey: Self.excludedApplicationsKey))
        )
    }

    func setOnboardingComplete(_ complete: Bool) {
        values.onboardingComplete = complete
        defaults.set(complete, forKey: Self.onboardingCompleteKey)
    }

    func setHideMacDock(_ hidden: Bool) {
        values.hideMacDock = hidden
        defaults.set(hidden, forKey: Self.hideMacDockKey)
    }

    func setActiveWindowClickBehavior(_ behavior: ActiveWindowClickBehavior) {
        values.activeWindowClickBehavior = behavior
        defaults.set(behavior.rawValue, forKey: Self.activeWindowClickBehaviorKey)
    }

    func setOrderingMode(_ mode: TaskbarOrderingMode) {
        values.orderingMode = mode
        defaults.set(mode.rawValue, forKey: Self.orderingModeKey)
    }

    func setLabelMode(_ mode: TaskbarLabelMode) {
        values.labelMode = mode
        defaults.set(mode.rawValue, forKey: Self.labelModeKey)
    }

    func setDensity(_ density: TaskbarDensity) {
        values.density = density
        defaults.set(density.rawValue, forKey: Self.densityKey)
    }

    func setButtonWidth(_ buttonWidth: TaskbarButtonWidth) {
        values.buttonWidth = buttonWidth
        defaults.set(buttonWidth.rawValue, forKey: Self.buttonWidthKey)
    }

    func setOverflowBehavior(_ behavior: TaskbarOverflowBehavior) {
        values.overflowBehavior = behavior
        defaults.set(behavior.rawValue, forKey: Self.overflowBehaviorKey)
    }

    func setDisplayMode(_ mode: TaskbarDisplayMode) {
        values.displayMode = mode
        defaults.set(mode.rawValue, forKey: Self.displayModeKey)
    }

    func pin(_ record: ApplicationRecord) {
        guard record.isValid else { return }
        values.excludedApplications.removeAll { $0.identity == record.identity }
        var updated = record
        if let existing = values.pinnedApplications.first(where: {
            $0.identity == record.identity
        }) {
            updated.sequence = existing.sequence
        } else {
            updated.sequence = (values.pinnedApplications.map(\.sequence).max() ?? -1) + 1
        }
        values.pinnedApplications.removeAll { $0.identity == record.identity }
        values.pinnedApplications.append(updated)
        persistApplicationRecords()
    }

    func unpin(identity: String) {
        values.pinnedApplications.removeAll { $0.identity == identity }
        persistApplicationRecords()
    }

    func exclude(_ record: ApplicationRecord) {
        guard record.isValid else { return }
        values.pinnedApplications.removeAll { $0.identity == record.identity }
        var updated = record
        updated.sequence = 0
        values.excludedApplications.removeAll { $0.identity == record.identity }
        values.excludedApplications.append(updated)
        persistApplicationRecords()
    }

    func restoreFromExclusions(identity: String) {
        values.excludedApplications.removeAll { $0.identity == identity }
        persistApplicationRecords()
    }

    func resetPins() {
        values.pinnedApplications = []
        persistApplicationRecords()
    }

    func resetExclusions() {
        values.excludedApplications = []
        persistApplicationRecords()
    }

    private func persistApplicationRecords() {
        let encoder = JSONEncoder()
        defaults.set(
            try? encoder.encode(values.pinnedApplications),
            forKey: Self.pinnedApplicationsKey)
        defaults.set(
            try? encoder.encode(values.excludedApplications),
            forKey: Self.excludedApplicationsKey)
    }

    private static func decodeRecords(_ data: Data?) -> [ApplicationRecord] {
        guard let data,
            let records = try? JSONDecoder().decode(
                LossyApplicationRecords.self, from: data
            ).records
        else { return [] }
        return records.filter(\.isValid)
    }
}

private struct LossyApplicationRecords: Decodable {
    let records: [ApplicationRecord]

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var decoded: [ApplicationRecord] = []
        while !container.isAtEnd {
            if let record = try? container.decode(ApplicationRecord.self) {
                decoded.append(record)
            } else {
                _ = try container.decode(DiscardedJSONValue.self)
            }
        }
        records = decoded
    }
}

private indirect enum DiscardedJSONValue: Decodable {
    case value

    init(from decoder: Decoder) throws {
        if var array = try? decoder.unkeyedContainer() {
            while !array.isAtEnd { _ = try array.decode(DiscardedJSONValue.self) }
            self = .value
            return
        }
        if let keyed = try? decoder.container(keyedBy: DynamicCodingKey.self) {
            for key in keyed.allKeys {
                _ = try keyed.decode(DiscardedJSONValue.self, forKey: key)
            }
            self = .value
            return
        }
        let value = try decoder.singleValueContainer()
        if value.decodeNil() || (try? value.decode(Bool.self)) != nil
            || (try? value.decode(Double.self)) != nil
            || (try? value.decode(String.self)) != nil
        {
            self = .value
            return
        }
        throw DecodingError.dataCorruptedError(
            in: value, debugDescription: "Unsupported JSON value")
    }
}

private struct DynamicCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}

enum TinyTaskbarSettingsSection: Int, CaseIterable, Hashable, Sendable {
    case general
    case behavior
    case appearance
    case applications

    var title: String {
        switch self {
        case .general: "General"
        case .behavior: "Behavior"
        case .appearance: "Appearance"
        case .applications: "Applications"
        }
    }

    var systemImageName: String {
        switch self {
        case .general: "gearshape"
        case .behavior: "cursorarrow.click"
        case .appearance: "paintbrush"
        case .applications: "square.grid.2x2"
        }
    }
}

@MainActor
final class TinyTaskbarSettingsModel: ObservableObject {
    @Published private(set) var selectedSection = TinyTaskbarSettingsSection.general
    @Published private(set) var accessibilityTrusted = false
    @Published private(set) var accessibilityRequestWasMade = false
    @Published private(set) var preferences = TinyTaskbarPreferences.defaults
    @Published private(set) var launchAtLoginError: String?
    @Published private(set) var dockVisibilityError: String?

    var onSelectedSectionChanged: (@MainActor (TinyTaskbarSettingsSection) -> Void)?
    var onAccessibilityRequest: (@MainActor () -> Void)?
    var onHideMacDockChanged: (@MainActor (Bool) -> String?)?
    var onActiveWindowClickChanged: (@MainActor (ActiveWindowClickBehavior) -> Void)?
    var onOrderingChanged: (@MainActor (TaskbarOrderingMode) -> Void)?
    var onLabelModeChanged: (@MainActor (TaskbarLabelMode) -> Void)?
    var onDensityChanged: (@MainActor (TaskbarDensity) -> Void)?
    var onButtonWidthChanged: (@MainActor (TaskbarButtonWidth) -> Void)?
    var onOverflowBehaviorChanged: (@MainActor (TaskbarOverflowBehavior) -> Void)?
    var onDisplayModeChanged: (@MainActor (TaskbarDisplayMode) -> Void)?
    var onApplications: (@MainActor () -> Void)?

    private let launchAtLoginService = SMAppService.mainApp

    var applicationsSummary: String {
        let pinnedCount = preferences.pinnedApplications.count
        let excludedCount = preferences.excludedApplications.count
        return pinnedCount == 0 && excludedCount == 0
            ? "No custom rules"
            : "\(pinnedCount) pinned, \(excludedCount) excluded"
    }

    var launchAtLoginEnabled: Bool {
        launchAtLoginService.status == .enabled || launchAtLoginService.status == .requiresApproval
    }

    var launchAtLoginAvailable: Bool {
        launchAtLoginService.status == .enabled || launchAtLoginService.status == .notRegistered
    }

    var launchAtLoginStatus: String? {
        if let launchAtLoginError { return launchAtLoginError }
        switch launchAtLoginService.status {
        case .enabled, .notRegistered: return nil
        case .requiresApproval: return "Approval required in System Settings"
        case .notFound: return "Unavailable for this app bundle"
        @unknown default: return "Unavailable"
        }
    }

    func refresh(
        accessibilityTrusted: Bool,
        preferences: TinyTaskbarPreferences,
        accessibilityRequestWasMade: Bool
    ) {
        self.accessibilityTrusted = accessibilityTrusted
        self.preferences = preferences
        self.accessibilityRequestWasMade = accessibilityRequestWasMade
        launchAtLoginError = nil
        dockVisibilityError = nil
    }

    func select(_ section: TinyTaskbarSettingsSection) {
        guard selectedSection != section else { return }
        selectedSection = section
        onSelectedSectionChanged?(section)
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try launchAtLoginService.register()
            } else {
                try launchAtLoginService.unregister()
            }
            launchAtLoginError = nil
            objectWillChange.send()
        } catch {
            launchAtLoginError = "Could not update: \(error.localizedDescription)"
        }
    }

    func setHideMacDock(_ hidden: Bool) {
        if let error = onHideMacDockChanged?(hidden) {
            dockVisibilityError = error
            return
        }
        preferences.hideMacDock = hidden
        dockVisibilityError = nil
    }

    func setActiveWindowClick(_ value: ActiveWindowClickBehavior) {
        preferences.activeWindowClickBehavior = value
        onActiveWindowClickChanged?(value)
    }

    func setOrdering(_ value: TaskbarOrderingMode) {
        preferences.orderingMode = value
        onOrderingChanged?(value)
    }

    func setLabelMode(_ value: TaskbarLabelMode) {
        preferences.labelMode = value
        onLabelModeChanged?(value)
    }

    func setDensity(_ value: TaskbarDensity) {
        preferences.density = value
        onDensityChanged?(value)
    }

    func setButtonWidth(_ value: TaskbarButtonWidth) {
        preferences.buttonWidth = value
        onButtonWidthChanged?(value)
    }

    func setOverflowBehavior(_ value: TaskbarOverflowBehavior) {
        preferences.overflowBehavior = value
        onOverflowBehaviorChanged?(value)
    }

    func setDisplayMode(_ value: TaskbarDisplayMode) {
        preferences.displayMode = value
        onDisplayModeChanged?(value)
    }
}

private struct TinyTaskbarSettingsSidebar: View {
    @ObservedObject var model: TinyTaskbarSettingsModel

    var body: some View {
        List(selection: selection) {
            Section("TinyTaskbar") {
                ForEach(TinyTaskbarSettingsSection.allCases, id: \.self) { section in
                    Label(section.title, systemImage: section.systemImageName)
                        .tag(section)
                }
            }
        }
        .listStyle(.sidebar)
    }

    private var selection: Binding<TinyTaskbarSettingsSection?> {
        Binding(
            get: { model.selectedSection },
            set: { if let section = $0 { model.select(section) } })
    }
}

private struct TinyTaskbarSettingsDetail: View {
    @ObservedObject var model: TinyTaskbarSettingsModel

    var body: some View {
        Group {
            switch model.selectedSection {
            case .general: general
            case .behavior: behavior
            case .appearance: appearance
            case .applications: applications
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var general: some View {
        Form {
            Section("Permissions") {
                LabeledContent {
                    HStack {
                        Text(model.accessibilityTrusted ? "Granted" : "Required")
                            .foregroundStyle(model.accessibilityTrusted ? .green : .secondary)
                        Button(model.accessibilityButtonTitle) {
                            model.onAccessibilityRequest?()
                        }
                    }
                } label: {
                    Text("Accessibility")
                    Text("Required to discover, focus, and manage windows.")
                }
            }
            Section {
                Toggle(
                    isOn: Binding(
                        get: { model.launchAtLoginEnabled },
                        set: { model.setLaunchAtLogin($0) }
                    )
                ) {
                    Text("Launch at Login")
                    Text("Start TinyTaskbar automatically when you sign in.")
                }
                .disabled(!model.launchAtLoginAvailable)
            } header: {
                Text("Startup")
            } footer: {
                if let status = model.launchAtLoginStatus {
                    Text(status)
                }
            }
            Section {
                Toggle(
                    isOn: Binding(
                        get: { model.preferences.hideMacDock },
                        set: { model.setHideMacDock($0) }
                    )
                ) {
                    Text("Fully hide the Mac Dock")
                    Text("Prevent edge reveal while TinyTaskbar is running.")
                }
            } header: {
                Text("Desktop")
            } footer: {
                if let error = model.dockVisibilityError {
                    Text(error)
                } else {
                    Text(
                        "Your previous Dock settings are restored when TinyTaskbar quits. Applying or restoring this restarts the Dock, which can briefly affect the desktop and minimized windows."
                    )
                }
            }
        }
        .formStyle(.grouped)
    }

    private var behavior: some View {
        Form {
            Section("Windows") {
                Picker(
                    selection: Binding(
                        get: { model.preferences.activeWindowClickBehavior },
                        set: { model.setActiveWindowClick($0) }
                    )
                ) {
                    Text("Minimize").tag(ActiveWindowClickBehavior.minimize)
                    Text("Do Nothing").tag(ActiveWindowClickBehavior.doNothing)
                } label: {
                    Text("Active Window Click")
                    Text("Choose what happens when you click the focused window.")
                }
                Picker(
                    selection: Binding(
                        get: { model.preferences.orderingMode },
                        set: { model.setOrdering($0) }
                    )
                ) {
                    Text("Window Order").tag(TaskbarOrderingMode.windowOrder)
                    Text("Group by Application").tag(TaskbarOrderingMode.groupByApplication)
                } label: {
                    Text("Ordering")
                    Text("Keep a stable window order or group windows by application.")
                }
            }
            Section("Displays") {
                Picker(
                    selection: Binding(
                        get: { model.preferences.displayMode },
                        set: { model.setDisplayMode($0) }
                    )
                ) {
                    Text("Window's Display").tag(TaskbarDisplayMode.windowDisplay)
                    Text("Every Display").tag(TaskbarDisplayMode.everyDisplay)
                    Text("Main Display Only").tag(TaskbarDisplayMode.mainDisplayOnly)
                } label: {
                    Text("Multiple Displays")
                    Text("Choose where taskbars appear and which windows they contain.")
                }
            }
        }
        .formStyle(.grouped)
    }

    private var appearance: some View {
        Form {
            Section("Taskbar") {
                Picker(
                    selection: Binding(
                        get: { model.preferences.labelMode },
                        set: { model.setLabelMode($0) }
                    )
                ) {
                    Text("Window Title").tag(TaskbarLabelMode.windowTitle)
                    Text("Application Name").tag(TaskbarLabelMode.applicationName)
                    Text("Icon Only").tag(TaskbarLabelMode.iconOnly)
                } label: {
                    Text("Labels")
                    Text("Choose the text shown beside each application icon.")
                }
                Picker(
                    selection: Binding(
                        get: { model.preferences.buttonWidth },
                        set: { model.setButtonWidth($0) }
                    )
                ) {
                    Text("Narrow").tag(TaskbarButtonWidth.narrow)
                    Text("Balanced").tag(TaskbarButtonWidth.balanced)
                    Text("Wide").tag(TaskbarButtonWidth.wide)
                } label: {
                    Text("Button Width")
                    Text("Set the preferred width used before the taskbar compresses.")
                }
                Picker(
                    selection: Binding(
                        get: { model.preferences.overflowBehavior },
                        set: { model.setOverflowBehavior($0) }
                    )
                ) {
                    Text("Shrink, Then Scroll").tag(TaskbarOverflowBehavior.shrinkThenScroll)
                    Text("Switch to Icons").tag(TaskbarOverflowBehavior.automaticIcons)
                } label: {
                    Text("When Space Runs Out")
                    Text("Shrink labels and scroll, or temporarily switch to icons.")
                }
                Picker(
                    selection: Binding(
                        get: { model.preferences.density },
                        set: { model.setDensity($0) }
                    )
                ) {
                    Text("Standard").tag(TaskbarDensity.standard)
                    Text("Compact").tag(TaskbarDensity.compact)
                } label: {
                    Text("Bar Size")
                    Text("Use the standard 30-point bar or a compact 26-point bar.")
                }
            }
        }
        .formStyle(.grouped)
    }

    private var applications: some View {
        Form {
            Section {
                LabeledContent {
                    Button("Manage…") { model.onApplications?() }
                } label: {
                    Text("Pinned & Excluded")
                    Text("Manage pinned launchers and applications that never appear.")
                }
            } header: {
                Text("Applications")
            } footer: {
                Text(model.applicationsSummary)
            }
        }
        .formStyle(.grouped)
    }
}

extension TinyTaskbarSettingsModel {
    fileprivate var accessibilityButtonTitle: String {
        accessibilityTrusted || accessibilityRequestWasMade
            ? "Open System Settings…"
            : "Enable Accessibility…"
    }
}

@MainActor
final class TinyTaskbarSettingsWindow: NSWindow, NSWindowDelegate, NSToolbarDelegate {
    private static let fixedContentSize = NSSize(width: 800, height: 600)
    private static let sidebarWidth: CGFloat = 215

    var onAccessibilityRequest: (@MainActor () -> Void)? {
        didSet { model.onAccessibilityRequest = onAccessibilityRequest }
    }
    var onHideMacDockChanged: (@MainActor (Bool) -> String?)? {
        didSet { model.onHideMacDockChanged = onHideMacDockChanged }
    }
    var onActiveWindowClickChanged: (@MainActor (ActiveWindowClickBehavior) -> Void)? {
        didSet { model.onActiveWindowClickChanged = onActiveWindowClickChanged }
    }
    var onOrderingChanged: (@MainActor (TaskbarOrderingMode) -> Void)? {
        didSet { model.onOrderingChanged = onOrderingChanged }
    }
    var onLabelModeChanged: (@MainActor (TaskbarLabelMode) -> Void)? {
        didSet { model.onLabelModeChanged = onLabelModeChanged }
    }
    var onDensityChanged: (@MainActor (TaskbarDensity) -> Void)? {
        didSet { model.onDensityChanged = onDensityChanged }
    }
    var onButtonWidthChanged: (@MainActor (TaskbarButtonWidth) -> Void)? {
        didSet { model.onButtonWidthChanged = onButtonWidthChanged }
    }
    var onOverflowBehaviorChanged: (@MainActor (TaskbarOverflowBehavior) -> Void)? {
        didSet { model.onOverflowBehaviorChanged = onOverflowBehaviorChanged }
    }
    var onDisplayModeChanged: (@MainActor (TaskbarDisplayMode) -> Void)? {
        didSet { model.onDisplayModeChanged = onDisplayModeChanged }
    }
    var onApplications: (@MainActor () -> Void)? {
        didSet { model.onApplications = onApplications }
    }
    var onClosed: (@MainActor () -> Void)?

    private let model = TinyTaskbarSettingsModel()
    var selectedSection: TinyTaskbarSettingsSection { model.selectedSection }
    var applicationsSummary: String { model.applicationsSummary }

    init() {
        super.init(
            contentRect: NSRect(origin: .zero, size: Self.fixedContentSize),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)

        title = model.selectedSection.title
        isReleasedWhenClosed = false
        isMovableByWindowBackground = false
        level = .normal
        collectionBehavior = [.moveToActiveSpace]
        hidesOnDeactivate = false
        toolbarStyle = .unified
        titlebarSeparatorStyle = .none
        delegate = self

        let splitController = NSSplitViewController()
        let sidebarItem = NSSplitViewItem(
            sidebarWithViewController: NSHostingController(
                rootView: TinyTaskbarSettingsSidebar(model: model)))
        sidebarItem.minimumThickness = Self.sidebarWidth
        sidebarItem.maximumThickness = Self.sidebarWidth
        sidebarItem.canCollapse = false
        let detailItem = NSSplitViewItem(
            viewController: NSHostingController(
                rootView: TinyTaskbarSettingsDetail(model: model)))
        detailItem.minimumThickness = 480
        splitController.addSplitViewItem(sidebarItem)
        splitController.addSplitViewItem(detailItem)
        contentViewController = splitController

        let toolbar = NSToolbar(identifier: "TinyTaskbarSettingsToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.allowsDisplayModeCustomization = false
        self.toolbar = toolbar

        model.onSelectedSectionChanged = { [weak self] section in
            self?.title = section.title
        }
        contentMinSize = Self.fixedContentSize
        contentMaxSize = Self.fixedContentSize
        restoreFixedContentSize()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func refresh(
        accessibilityTrusted: Bool,
        preferences: TinyTaskbarPreferences,
        accessibilityRequestWasMade: Bool
    ) {
        model.refresh(
            accessibilityTrusted: accessibilityTrusted,
            preferences: preferences,
            accessibilityRequestWasMade: accessibilityRequestWasMade)
    }

    func selectSection(_ section: TinyTaskbarSettingsSection) {
        model.select(section)
    }

    func restoreFixedContentSize() {
        let contentRect = NSRect(origin: .zero, size: Self.fixedContentSize)
        let targetFrameSize = frameRect(forContentRect: contentRect).size
        setFrame(
            NSRect(origin: frame.origin, size: targetFrameSize),
            display: isVisible)
        contentView?.frame = contentRect
    }

    func windowWillClose(_: Notification) {
        onClosed?()
        NSApp.deactivate()
    }

    func toolbarDefaultItemIdentifiers(_: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.sidebarTrackingSeparator]
    }

    func toolbarAllowedItemIdentifiers(_: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.sidebarTrackingSeparator]
    }
}

@MainActor
final class SystemEventObserver {
    private var tokens: [NSObjectProtocol] = []
    private let handler: @MainActor () -> Void

    init(handler: @escaping @MainActor () -> Void) {
        self.handler = handler
    }

    func start() {
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        let workspaceNotifications: [Notification.Name] = [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.didHideApplicationNotification,
            NSWorkspace.didUnhideApplicationNotification,
            NSWorkspace.activeSpaceDidChangeNotification,
        ]
        for name in workspaceNotifications {
            tokens.append(
                workspaceCenter.addObserver(forName: name, object: nil, queue: .main) {
                    [weak self] _ in
                    Task { @MainActor [weak self] in
                        self?.handler()
                    }
                }
            )
        }

        tokens.append(
            NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.handler()
                }
            }
        )
    }

    func stop() {
        for token in tokens {
            NotificationCenter.default.removeObserver(token)
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
        tokens.removeAll()
    }
}

@MainActor
final class TaskbarPanel: NSPanel {
    private let barView: TaskbarBarView

    init(
        frame: NSRect,
        onActivate: @escaping @MainActor (TaskbarItem) -> Void,
        onClose: @escaping @MainActor (TaskbarItem) -> Void,
        onWindowCommand: @escaping @MainActor (WindowCommand) -> Void = { _ in },
        onApplicationCommand: @escaping @MainActor (ApplicationCommand) -> Void = { _ in },
        onGlobalCommand: @escaping @MainActor (GlobalCommand) -> Void = { _ in }
    ) {
        barView = TaskbarBarView(
            onActivate: onActivate,
            onClose: onClose,
            onWindowCommand: onWindowCommand,
            onApplicationCommand: onApplicationCommand,
            onGlobalCommand: onGlobalCommand)
        super.init(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .statusBar
        collectionBehavior = [
            .managed,
            .canJoinAllApplications,
            .fullScreenAuxiliary,
            .ignoresCycle,
        ]
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        isMovable = false
        isReleasedWhenClosed = false
        contentView = barView
    }

    override var canBecomeKey: Bool { false }

    override var canBecomeMain: Bool { false }

    func update(
        frame: NSRect,
        entries: [TaskbarPresentationEntry],
        preferences: TinyTaskbarPreferences
    ) {
        if self.frame != frame { setFrame(frame, display: false) }
        barView.update(entries: entries, preferences: preferences)
        barView.layoutSubtreeIfNeeded()
    }
}

@MainActor
class TaskbarHoverButton: NSButton {
    var onHoverChanged: (@MainActor (TaskbarHoverButton, Bool) -> Void)?
    var onPrimaryInteraction: (@MainActor (TaskbarHoverButton) -> Void)?
    private(set) var isPointerInside = false
    private var hoverTrackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        hoverTrackingArea = trackingArea
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        guard !isPointerInside else { return }
        isPointerInside = true
        onHoverChanged?(self, true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        guard isPointerInside else { return }
        isPointerInside = false
        onHoverChanged?(self, false)
    }

    override func acceptsFirstMouse(for _: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        onPrimaryInteraction?(self)
        super.mouseDown(with: event)
    }
}

@MainActor
final class TaskbarButtonCell: NSButtonCell {
    static let contentLeadingInset: CGFloat = 3

    override func drawImage(_ image: NSImage, withFrame frame: NSRect, in controlView: NSView) {
        super.drawImage(image, withFrame: insetImageFrame(frame), in: controlView)
    }

    override func drawTitle(
        _ title: NSAttributedString,
        withFrame frame: NSRect,
        in controlView: NSView
    ) -> NSRect {
        super.drawTitle(title, withFrame: insetTitleFrame(frame), in: controlView)
    }

    func insetImageFrame(_ frame: NSRect) -> NSRect {
        frame.offsetBy(dx: Self.contentLeadingInset, dy: 0)
    }

    func insetTitleFrame(_ frame: NSRect) -> NSRect {
        NSRect(
            x: frame.minX + Self.contentLeadingInset,
            y: frame.minY,
            width: max(0, frame.width - Self.contentLeadingInset),
            height: frame.height)
    }
}

@MainActor
private enum TaskbarSelectionAppearance {
    static let cornerRadius: CGFloat = 6

    static func apply(to layer: CALayer?, isSelected: Bool, isHovered: Bool = false) {
        guard let layer else { return }
        layer.cornerRadius = cornerRadius
        layer.cornerCurve = .continuous
        layer.masksToBounds = true
        layer.backgroundColor =
            isSelected
            ? NSColor.controlAccentColor.withAlphaComponent(0.18).cgColor
            : isHovered
                ? NSColor.labelColor.withAlphaComponent(0.06).cgColor
                : NSColor.clear.cgColor
        layer.borderWidth = isSelected ? 1 : 0
        layer.borderColor =
            isSelected
            ? NSColor.controlAccentColor.withAlphaComponent(0.48).cgColor
            : NSColor.clear.cgColor
    }
}

@MainActor
final class TaskbarButton: TaskbarHoverButton {
    var contextualMenu: NSMenu?
    var itemID = ""
    var widthConstraint: NSLayoutConstraint?
    var heightConstraint: NSLayoutConstraint?
    var onMiddleClick: (@MainActor () -> Void)?
    var onMenuRequested: (@MainActor () -> NSMenu)?
    var preferredIntrinsicHeight = TaskbarPanelLayout.contentHeight {
        didSet { invalidateIntrinsicContentSize() }
    }
    private(set) var presentsActiveFocus = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        cell = TaskbarButtonCell(textCell: "")
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        cell = TaskbarButtonCell(textCell: "")
    }

    override var intrinsicContentSize: NSSize {
        var size = super.intrinsicContentSize
        size.height = preferredIntrinsicHeight
        return size
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(
            NSSize(width: newSize.width, height: min(newSize.height, preferredIntrinsicHeight)))
    }

    override func setFrameOrigin(_ newOrigin: NSPoint) {
        super.setFrameOrigin(NSPoint(x: newOrigin.x, y: max(0, newOrigin.y)))
    }

    override func menu(for _: NSEvent) -> NSMenu? {
        let refreshed = onMenuRequested?() ?? contextualMenu
        contextualMenu = refreshed
        return refreshed
    }

    override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2 else {
            super.otherMouseDown(with: event)
            return
        }
        onMiddleClick?()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateFocusAppearance()
    }

    func setActiveFocus(_ active: Bool) {
        guard presentsActiveFocus != active else { return }
        presentsActiveFocus = active
        updateFocusAppearance()
    }

    private func updateFocusAppearance() {
        TaskbarSelectionAppearance.apply(to: layer, isSelected: presentsActiveFocus)
    }
}

@MainActor
final class TaskbarLauncherButton: TaskbarHoverButton {
    var applicationIdentity = ""
    var contextualMenu: NSMenu?
    var widthConstraint: NSLayoutConstraint?
    var heightConstraint: NSLayoutConstraint?
    var preferredIntrinsicHeight = TaskbarPanelLayout.contentHeight {
        didSet { invalidateIntrinsicContentSize() }
    }

    override var intrinsicContentSize: NSSize {
        var size = super.intrinsicContentSize
        size.height = preferredIntrinsicHeight
        return size
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(
            NSSize(width: newSize.width, height: min(newSize.height, preferredIntrinsicHeight)))
    }

    override func setFrameOrigin(_ newOrigin: NSPoint) {
        super.setFrameOrigin(NSPoint(x: newOrigin.x, y: max(0, newOrigin.y)))
    }

    override func menu(for _: NSEvent) -> NSMenu? { contextualMenu }
}

@MainActor
final class TaskbarHoverCardView: NSView {
    var onHoverChanged: (@MainActor (Bool) -> Void)?
    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let next = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(next)
        tracking = next
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        onHoverChanged?(true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onHoverChanged?(false)
    }
}

@MainActor
private final class TaskbarTabButton: TaskbarHoverButton {
    var isSelectedTab = false {
        didSet { updateSelectionAppearance() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        cell = TaskbarButtonCell(textCell: "")
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        cell = TaskbarButtonCell(textCell: "")
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        updateSelectionAppearance()
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        updateSelectionAppearance()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateSelectionAppearance()
    }

    override func acceptsFirstMouse(for _: NSEvent?) -> Bool { true }

    private func updateSelectionAppearance() {
        TaskbarSelectionAppearance.apply(
            to: layer,
            isSelected: isSelectedTab,
            isHovered: isPointerInside)
    }
}

@MainActor
private final class TaskbarCloseButton: NSButton {
    override func acceptsFirstMouse(for _: NSEvent?) -> Bool { true }
}

@MainActor
private final class TaskbarTabListView: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
final class TaskbarHoverCardViewController: NSViewController {
    static let maximumTextWidth: CGFloat = 360
    static let minimumTextWidth: CGFloat = 120
    static let iconSize: CGFloat = 24
    static let padding: CGFloat = 10
    static let spacing: CGFloat = 8
    static let closeControlWidth: CGFloat = 32
    static let tabRowHeight: CGFloat = 26
    static let maximumTabListHeight: CGFloat = 234

    let applicationLabel: NSTextField
    let titleLabel: NSTextField
    let iconView: NSImageView
    let closeWindowButton: NSButton?
    private(set) var tabButtons: [NSButton] = []
    private(set) var tabCloseButtons: [NSButton] = []

    private let tabs: [TaskbarTab]
    private let onSelectTab: @MainActor (TaskbarTab) -> Void
    private let onCloseTab: @MainActor (TaskbarTab) -> Void
    private let onCloseWindow: @MainActor () -> Void
    private let showsTabList: Bool
    private let headerHeight: CGFloat
    private let tabListHeight: CGFloat

    init(
        applicationName: String,
        title: String,
        icon: NSImage?,
        tabs: [TaskbarTab] = [],
        onSelectTab: @escaping @MainActor (TaskbarTab) -> Void = { _ in },
        onCloseTab: @escaping @MainActor (TaskbarTab) -> Void = { _ in },
        onCloseWindow: @escaping @MainActor () -> Void = {}
    ) {
        showsTabList = tabs.count > 1
        let displayedTitle = showsTabList ? "\(tabs.count) Tabs" : title
        applicationLabel = NSTextField(labelWithString: applicationName)
        titleLabel = NSTextField(wrappingLabelWithString: displayedTitle)
        iconView = NSImageView(image: icon ?? NSImage())
        closeWindowButton = showsTabList ? nil : TaskbarCloseButton()
        self.tabs = tabs
        self.onSelectTab = onSelectTab
        self.onCloseTab = onCloseTab
        self.onCloseWindow = onCloseWindow

        let titleFont = NSFont.systemFont(ofSize: 12, weight: .medium)
        let applicationFont = NSFont.systemFont(ofSize: 10, weight: .regular)
        let showsApplication = showsTabList || applicationName != displayedTitle
        let displayedTitleFont = showsTabList ? applicationFont : titleFont
        let displayedApplicationFont = showsTabList ? titleFont : applicationFont
        let titleNaturalWidth = ceil(
            (displayedTitle as NSString).size(withAttributes: [.font: displayedTitleFont]).width)
        let applicationNaturalWidth =
            showsApplication
            ? ceil(
                (applicationName as NSString).size(
                    withAttributes: [.font: displayedApplicationFont]
                ).width)
            : 0
        let tabNaturalWidth =
            tabs.map {
                ceil(($0.title as NSString).size(withAttributes: [.font: titleFont]).width) + 36
            }.max() ?? 0
        let textWidth = min(
            Self.maximumTextWidth,
            max(
                Self.minimumTextWidth,
                max(titleNaturalWidth, max(applicationNaturalWidth, tabNaturalWidth))
            )
        )
        let titleHeight = ceil(
            (displayedTitle as NSString).boundingRect(
                with: NSSize(width: textWidth, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: displayedTitleFont]
            ).height)
        let applicationHeight =
            showsApplication ? ceil(displayedApplicationFont.boundingRectForFont.height) : 0
        let textHeight = titleHeight + applicationHeight + (showsApplication ? 2 : 0)
        headerHeight = Self.padding + max(Self.iconSize, textHeight) + Self.padding
        tabListHeight =
            tabs.count > 1
            ? min(Self.maximumTabListHeight, CGFloat(tabs.count) * Self.tabRowHeight + 8)
            : 0
        super.init(nibName: nil, bundle: nil)
        preferredContentSize = NSSize(
            width: Self.padding + Self.iconSize + Self.spacing + textWidth
                + (closeWindowButton == nil ? 0 : Self.closeControlWidth) + Self.padding,
            height: headerHeight + (tabListHeight > 0 ? 1 + tabListHeight : 0)
        )
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let container = TaskbarHoverCardView(
            frame: NSRect(origin: .zero, size: preferredContentSize))
        iconView.imageScaling = .scaleProportionallyDown
        iconView.translatesAutoresizingMaskIntoConstraints = false

        applicationLabel.font = .systemFont(
            ofSize: showsTabList ? 12 : 10,
            weight: showsTabList ? .medium : .regular)
        applicationLabel.textColor = showsTabList ? .labelColor : .secondaryLabelColor
        applicationLabel.isHidden =
            !showsTabList && applicationLabel.stringValue == titleLabel.stringValue
        titleLabel.font = .systemFont(
            ofSize: showsTabList ? 10 : 12,
            weight: showsTabList ? .regular : .medium)
        titleLabel.textColor = showsTabList ? .secondaryLabelColor : .labelColor
        titleLabel.maximumNumberOfLines = showsTabList ? 1 : 0
        titleLabel.lineBreakMode = showsTabList ? .byTruncatingTail : .byCharWrapping

        let textStack = NSStackView(views: [applicationLabel, titleLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2
        textStack.translatesAutoresizingMaskIntoConstraints = false

        let header = NSView()
        header.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(iconView)
        header.addSubview(textStack)
        if let closeWindowButton {
            configureCloseButton(
                closeWindowButton,
                accessibilityLabel: "Close \(applicationLabel.stringValue) window",
                action: #selector(closeWindow))
            closeWindowButton.image = closeWindowButton.image?.withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold))
            closeWindowButton.contentTintColor = .labelColor
            header.addSubview(closeWindowButton)
        }
        container.addSubview(header)
        var headerConstraints = [
            header.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            header.topAnchor.constraint(equalTo: container.topAnchor),
            header.heightAnchor.constraint(equalToConstant: headerHeight),
            iconView.leadingAnchor.constraint(
                equalTo: header.leadingAnchor, constant: Self.padding),
            iconView.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: Self.iconSize),
            iconView.heightAnchor.constraint(equalToConstant: Self.iconSize),
            textStack.leadingAnchor.constraint(
                equalTo: iconView.trailingAnchor, constant: Self.spacing),
            textStack.centerYAnchor.constraint(equalTo: header.centerYAnchor),
        ]
        if let closeWindowButton {
            headerConstraints += [
                closeWindowButton.trailingAnchor.constraint(
                    equalTo: header.trailingAnchor, constant: -6),
                closeWindowButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
                closeWindowButton.widthAnchor.constraint(equalToConstant: 28),
                closeWindowButton.heightAnchor.constraint(equalToConstant: 28),
                textStack.trailingAnchor.constraint(
                    lessThanOrEqualTo: closeWindowButton.leadingAnchor, constant: -4),
            ]
        } else {
            headerConstraints.append(
                textStack.trailingAnchor.constraint(
                    equalTo: header.trailingAnchor, constant: -Self.padding))
        }
        NSLayoutConstraint.activate(headerConstraints)

        if tabListHeight > 0 {
            addTabList(to: container, below: header)
        }
        view = container
    }

    private func addTabList(to container: NSView, below header: NSView) {
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        let documentHeight = CGFloat(tabs.count) * Self.tabRowHeight + 8
        let document = TaskbarTabListView(
            frame: NSRect(
                x: 0,
                y: 0,
                width: preferredContentSize.width,
                height: documentHeight
            ))
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)

        tabButtons = []
        tabCloseButtons = []
        for (index, tab) in tabs.enumerated() {
            let row = NSView()
            row.translatesAutoresizingMaskIntoConstraints = false
            let button = TaskbarTabButton(
                title: tab.title,
                target: self,
                action: #selector(selectTab(_:))
            )
            button.tag = index
            button.bezelStyle = .inline
            button.isBordered = false
            button.setButtonType(.momentaryPushIn)
            button.alignment = .left
            button.font = .systemFont(ofSize: 12, weight: .regular)
            button.lineBreakMode = .byTruncatingTail
            button.imagePosition = .noImage
            button.wantsLayer = true
            button.isSelectedTab = tab.isSelected
            button.setAccessibilityLabel(tab.title)
            button.setAccessibilityValue(tab.isSelected ? "Selected tab" : "Tab")
            button.translatesAutoresizingMaskIntoConstraints = false
            let closeButton = TaskbarCloseButton()
            closeButton.tag = index
            configureCloseButton(
                closeButton,
                accessibilityLabel: "Close \(tab.title)",
                action: #selector(closeTab(_:)))
            row.addSubview(button)
            row.addSubview(closeButton)
            NSLayoutConstraint.activate([
                row.widthAnchor.constraint(equalToConstant: preferredContentSize.width - 12),
                row.heightAnchor.constraint(equalToConstant: Self.tabRowHeight),
                button.leadingAnchor.constraint(equalTo: row.leadingAnchor),
                button.topAnchor.constraint(equalTo: row.topAnchor),
                button.bottomAnchor.constraint(equalTo: row.bottomAnchor),
                button.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -2),
                closeButton.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -2),
                closeButton.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                closeButton.widthAnchor.constraint(equalToConstant: 22),
                closeButton.heightAnchor.constraint(equalToConstant: 22),
            ])
            stack.addArrangedSubview(row)
            tabButtons.append(button)
            tabCloseButtons.append(closeButton)
        }
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -6),
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 4),
        ])

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = false
        scroll.hasVerticalScroller = documentHeight > tabListHeight
        scroll.autohidesScrollers = true
        scroll.documentView = document
        scroll.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(separator)
        container.addSubview(scroll)
        NSLayoutConstraint.activate([
            separator.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            separator.topAnchor.constraint(equalTo: header.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: separator.bottomAnchor),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }

    @objc private func selectTab(_ sender: NSButton) {
        guard tabs.indices.contains(sender.tag) else { return }
        onSelectTab(tabs[sender.tag])
    }

    @objc private func closeTab(_ sender: NSButton) {
        guard tabs.indices.contains(sender.tag) else { return }
        onCloseTab(tabs[sender.tag])
    }

    @objc private func closeWindow() {
        onCloseWindow()
    }

    private func configureCloseButton(
        _ button: NSButton,
        accessibilityLabel: String,
        action: Selector
    ) {
        button.target = self
        button.action = action
        button.bezelStyle = .inline
        button.isBordered = false
        button.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)
        button.image = button.image?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 10, weight: .medium))
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = accessibilityLabel
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setAccessibilityLabel(accessibilityLabel)
    }
}

@MainActor
final class TaskbarHoverPresenter {
    private static let delay = Duration.milliseconds(300)
    static let interactivePollDelay = Duration.milliseconds(80)
    static let interactionMargin: CGFloat = 8
    static let popoverBehavior = NSPopover.Behavior.applicationDefined

    private var pendingShow: Task<Void, Never>?
    private var pendingHide: Task<Void, Never>?
    private weak var requestedAnchor: TaskbarHoverButton?
    private var popover: NSPopover?

    func schedule(
        applicationName: String,
        title: String,
        icon: NSImage?,
        tabs: [TaskbarTab] = [],
        onSelectTab: @escaping @MainActor (TaskbarTab) -> Void = { _ in },
        onCloseTab: @escaping @MainActor (TaskbarTab) -> Void = { _ in },
        onCloseWindow: @escaping @MainActor () -> Void = {},
        from anchor: TaskbarHoverButton
    ) {
        hide()
        requestedAnchor = anchor
        pendingShow = Task { @MainActor [weak self, weak anchor] in
            try? await Task.sleep(for: Self.delay)
            guard !Task.isCancelled,
                let self,
                let anchor,
                self.requestedAnchor === anchor,
                anchor.isPointerInside,
                anchor.window?.isVisible == true
            else { return }

            let controller = TaskbarHoverCardViewController(
                applicationName: applicationName,
                title: title,
                icon: icon,
                tabs: tabs,
                onSelectTab: { [weak self] tab in
                    onSelectTab(tab)
                    self?.hide()
                },
                onCloseTab: { [weak self] tab in
                    onCloseTab(tab)
                    self?.hide()
                },
                onCloseWindow: { [weak self] in
                    onCloseWindow()
                    self?.hide()
                }
            )
            controller.loadView()
            if let hoverView = controller.view as? TaskbarHoverCardView {
                hoverView.onHoverChanged = { [weak self] hovering in
                    if hovering {
                        self?.pendingHide?.cancel()
                        self?.pendingHide = nil
                    } else {
                        self?.scheduleInteractiveHide()
                    }
                }
            }
            let popover = NSPopover()
            popover.animates = false
            popover.behavior = Self.popoverBehavior
            popover.contentViewController = controller
            self.popover = popover
            popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        }
    }

    func pointerExited(from anchor: TaskbarHoverButton) {
        guard requestedAnchor === anchor else { return }
        guard popover != nil else {
            hide(from: anchor)
            return
        }
        scheduleInteractiveHide()
    }

    func hide(from anchor: TaskbarHoverButton? = nil) {
        if let anchor, requestedAnchor !== anchor { return }
        pendingShow?.cancel()
        pendingShow = nil
        pendingHide?.cancel()
        pendingHide = nil
        requestedAnchor = nil
        popover?.performClose(nil)
        popover = nil
    }

    private func scheduleInteractiveHide() {
        pendingHide?.cancel()
        pendingHide = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.interactivePollDelay)
                guard !Task.isCancelled, let self else { return }
                if self.pointerIsInsideInteractionCorridor { continue }
                self.hide()
                return
            }
        }
    }

    private var pointerIsInsideInteractionCorridor: Bool {
        guard let anchor = requestedAnchor,
            let anchorWindow = anchor.window,
            let popoverWindow = popover?.contentViewController?.view.window
        else { return false }
        let anchorFrame = anchorWindow.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        return Self.interactionCorridor(
            anchorFrame: anchorFrame,
            popoverFrame: popoverWindow.frame
        ).contains(NSEvent.mouseLocation)
    }

    static func interactionCorridor(anchorFrame: NSRect, popoverFrame: NSRect) -> NSRect {
        anchorFrame.union(popoverFrame).insetBy(
            dx: -interactionMargin,
            dy: -interactionMargin)
    }
}

@MainActor
final class TaskbarScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        guard let documentView else { return super.scrollWheel(with: event) }
        let maximumX = max(0, documentView.frame.width - contentView.bounds.width)
        guard maximumX > 0 else { return }
        let delta =
            abs(event.scrollingDeltaX) >= abs(event.scrollingDeltaY)
            ? event.scrollingDeltaX : event.scrollingDeltaY
        let x = min(maximumX, max(0, contentView.bounds.origin.x + delta))
        contentView.scroll(to: NSPoint(x: x, y: 0))
        reflectScrolledClipView(contentView)
    }
}

@MainActor
private final class TaskbarBarView: NSView {
    private struct ApplicationIconKey: Hashable {
        let stableIdentity: String

        init(item: TaskbarItem) {
            stableIdentity = item.applicationIdentity ?? "name:\(item.applicationName)"
        }
    }

    private let visualEffectView = NSVisualEffectView()
    private let scrollView = TaskbarScrollView()
    private let stackView = NSStackView()
    private let separatorView = NSView()
    private var currentItems: [TaskbarItem] = []
    private var buttons: [ObjectIdentifier: TaskbarItem] = [:]
    private var buttonsByID: [String: TaskbarButton] = [:]
    private var launchersByID: [String: TaskbarLauncherButton] = [:]
    private var dividersByID: [String: NSBox] = [:]
    private var iconCache: [ApplicationIconKey: NSImage] = [:]
    private let hoverPresenter = TaskbarHoverPresenter()
    private let onActivate: @MainActor (TaskbarItem) -> Void
    private let onClose: @MainActor (TaskbarItem) -> Void
    private let onWindowCommand: @MainActor (WindowCommand) -> Void
    private let onApplicationCommand: @MainActor (ApplicationCommand) -> Void
    private let onGlobalCommand: @MainActor (GlobalCommand) -> Void
    private var currentEntries: [TaskbarPresentationEntry] = []
    private var currentPreferences = TinyTaskbarPreferences.defaults

    init(
        onActivate: @escaping @MainActor (TaskbarItem) -> Void,
        onClose: @escaping @MainActor (TaskbarItem) -> Void,
        onWindowCommand: @escaping @MainActor (WindowCommand) -> Void,
        onApplicationCommand: @escaping @MainActor (ApplicationCommand) -> Void,
        onGlobalCommand: @escaping @MainActor (GlobalCommand) -> Void
    ) {
        self.onActivate = onActivate
        self.onClose = onClose
        self.onWindowCommand = onWindowCommand
        self.onApplicationCommand = onApplicationCommand
        self.onGlobalCommand = onGlobalCommand
        super.init(frame: .zero)

        wantsLayer = true
        layer?.cornerRadius = 0

        visualEffectView.material = .headerView
        visualEffectView.blendingMode = .behindWindow
        visualEffectView.state = .active
        visualEffectView.isEmphasized = false
        visualEffectView.wantsLayer = true
        visualEffectView.layer?.cornerRadius = 0
        addSubview(visualEffectView)

        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = false
        // Keep the horizontal document scrollable without allowing a traditional
        // scroller to reserve 17pt of the 30pt taskbar viewport.
        scrollView.hasHorizontalScroller = false
        scrollView.horizontalScrollElasticity = .allowed
        visualEffectView.addSubview(scrollView)

        stackView.orientation = .horizontal
        stackView.alignment = .centerY
        stackView.spacing = 2
        stackView.edgeInsets = NSEdgeInsets(
            top: 0,
            left: TaskbarPanelLayout.contentLeadingInset,
            bottom: 0,
            right: 0)
        // The document view is positioned by the scroll view's clip view and by the
        // explicit frame in layout(). It must remain frame-managed; disabling
        // autoresizing here lets AppKit's document-view constraints pin it to the
        // clip view's top edge after the parent layout pass.
        stackView.translatesAutoresizingMaskIntoConstraints = true
        scrollView.documentView = stackView

        separatorView.identifier = NSUserInterfaceItemIdentifier(
            TaskbarPanelLayout.topSeparatorIdentifier)
        separatorView.wantsLayer = true
        separatorView.layer?.backgroundColor =
            NSColor.separatorColor.withAlphaComponent(0.65).cgColor
        addSubview(separatorView)
        let backgroundMenu = NSMenu()
        backgroundMenu.addItem(tinyTaskbarMenuItem())
        backgroundMenu.addItem(.separator())
        backgroundMenu.addItem(menuItem("Minimize All", action: #selector(minimizeAll)))
        menu = backgroundMenu
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Preserve the bottom edge as a Fitts's-law target. The visible controls
        // remain vertically inset, but the otherwise empty strip at y == 0 must
        // behave like the control directly above it.
        if bottomEdgeControl(at: point) != nil {
            return self
        }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard event.buttonNumber == 0, let control = bottomEdgeControl(at: point) else {
            super.mouseDown(with: event)
            return
        }
        control.performClick(nil)
    }

    override func layout() {
        super.layout()
        visualEffectView.frame = bounds
        let availableHeight = max(0, bounds.height)
        let separatorHeight = min(TaskbarPanelLayout.topSeparatorHeight, availableHeight)
        let verticalInset = min(
            TaskbarPanelLayout.contentVerticalInset,
            max(0, (availableHeight - separatorHeight) / 2)
        )
        separatorView.frame = NSRect(
            x: bounds.minX,
            y: bounds.maxY - separatorHeight,
            width: max(0, bounds.width),
            height: separatorHeight
        )

        let contentMinY = bounds.minY + verticalInset
        let contentMaxY = max(
            contentMinY,
            bounds.maxY - separatorHeight - verticalInset
        )
        let contentFrame = NSRect(
            x: bounds.minX,
            y: contentMinY,
            width: max(0, bounds.width),
            height: max(0, contentMaxY - contentMinY)
        )
        scrollView.frame = contentFrame
        // Refresh the clip view after changing the viewport, but do not use its
        // bounds for document sizing: on a first pass or display resize those
        // bounds can still describe the previous viewport.
        scrollView.layoutSubtreeIfNeeded()
        let buttonHeight = min(TaskbarPanelLayout.contentHeight, contentFrame.height)
        for button in buttonsByID.values {
            button.heightConstraint?.constant = buttonHeight
        }
        let overflowLayout = resolveOverflowLayout(viewportWidth: contentFrame.width)
        apply(overflowLayout)
        let fittingSize = stackView.fittingSize
        stackView.frame.size = CGSize(
            width: max(overflowLayout.contentWidth, fittingSize.width, contentFrame.width),
            height: contentFrame.height
        )
        stackView.frame.origin = .zero
        stackView.layoutSubtreeIfNeeded()
        for button in buttonsByID.values {
            button.frame.size.height = buttonHeight
            button.frame.origin.y = max(0, (contentFrame.height - buttonHeight) / 2)
        }
        for button in launchersByID.values {
            let height = min(currentPreferences.density.buttonHeight, contentFrame.height)
            button.frame.size.height = height
            button.frame.origin.y = max(0, (contentFrame.height - height) / 2)
        }
        let maximumX = max(0, stackView.frame.width - scrollView.contentView.bounds.width)
        if scrollView.contentView.bounds.origin.x > maximumX {
            scrollView.contentView.scroll(to: NSPoint(x: maximumX, y: 0))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }

    private func bottomEdgeControl(at point: NSPoint) -> NSButton? {
        guard bounds.contains(point),
            point.y >= bounds.minY,
            point.y < scrollView.frame.minY
        else { return nil }

        let stackPoint = stackView.convert(point, from: self)
        return stackView.arrangedSubviews.compactMap { $0 as? NSButton }.first {
            stackPoint.x >= $0.frame.minX && stackPoint.x < $0.frame.maxX
        }
    }

    func update(entries: [TaskbarPresentationEntry], preferences: TinyTaskbarPreferences) {
        let items = entries.compactMap { entry -> TaskbarItem? in
            guard case .window(let item) = entry else { return nil }
            return item
        }
        guard entries != currentEntries || preferences != currentPreferences else { return }
        currentItems = items
        currentEntries = entries
        currentPreferences = preferences
        let currentIconKeys = Set(items.map(ApplicationIconKey.init))
        iconCache = iconCache.filter { currentIconKeys.contains($0.key) }

        let desiredIDs = entries.map(\.id)
        let desiredIDSet = Set(desiredIDs)
        let staleIDs = buttonsByID.keys.filter { !desiredIDSet.contains($0) }
        for itemID in staleIDs {
            guard let button = buttonsByID.removeValue(forKey: itemID) else { continue }
            hoverPresenter.hide(from: button)
            stackView.removeArrangedSubview(button)
            button.removeFromSuperview()
        }
        for id in launchersByID.keys.filter({ !desiredIDSet.contains($0) }) {
            guard let view = launchersByID.removeValue(forKey: id) else { continue }
            hoverPresenter.hide(from: view)
            stackView.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for id in dividersByID.keys.filter({ !desiredIDSet.contains($0) }) {
            guard let view = dividersByID.removeValue(forKey: id) else { continue }
            stackView.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        for item in items {
            if let button = buttonsByID[item.id] {
                updateButton(
                    button, for: item, labelMode: preferences.labelMode,
                    density: preferences.density)
            } else {
                let button = makeButton(
                    for: item, labelMode: preferences.labelMode,
                    density: preferences.density)
                buttonsByID[item.id] = button
                stackView.addArrangedSubview(button)
            }
        }
        for entry in entries {
            switch entry {
            case .window:
                break
            case .launcher(let application):
                let button = launchersByID[entry.id] ?? makeLauncher(application)
                button.identifier = NSUserInterfaceItemIdentifier(entry.id)
                updateLauncher(button, application: application, density: preferences.density)
                if launchersByID[entry.id] == nil {
                    launchersByID[entry.id] = button
                    stackView.addArrangedSubview(button)
                }
            case .separator:
                if dividersByID[entry.id] == nil {
                    let divider = NSBox()
                    divider.boxType = .separator
                    divider.identifier = NSUserInterfaceItemIdentifier(entry.id)
                    divider.translatesAutoresizingMaskIntoConstraints = false
                    divider.widthAnchor.constraint(equalToConstant: 1).isActive = true
                    divider.heightAnchor.constraint(
                        equalToConstant: preferences.density.buttonHeight - 6
                    ).isActive = true
                    dividersByID[entry.id] = divider
                    stackView.addArrangedSubview(divider)
                }
            }
        }

        buttons = items.reduce(into: [ObjectIdentifier: TaskbarItem]()) { result, item in
            guard let button = buttonsByID[item.id] else { return }
            result[ObjectIdentifier(button)] = item
        }
        reorderViewsIfNeeded(to: desiredIDs)
        needsLayout = true
    }

    private func makeButton(
        for item: TaskbarItem,
        labelMode: TaskbarLabelMode,
        density: TaskbarDensity
    ) -> TaskbarButton {
        let button = TaskbarButton(
            title: item.buttonTitle(labelMode: labelMode),
            target: self,
            action: #selector(activateButton(_:))
        )
        button.itemID = item.id
        button.identifier = NSUserInterfaceItemIdentifier(item.id)
        button.bezelStyle = .inline
        button.isBordered = false
        button.setButtonType(.momentaryPushIn)
        button.lineBreakMode = .byTruncatingTail
        button.alignment = .left
        button.imagePosition = .imageLeading
        button.imageScaling = .scaleProportionallyDown
        button.setAccessibilityRole(.button)
        button.contextualMenu = makeContextualMenu(for: item)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthConstraint = button.widthAnchor.constraint(
            equalToConstant: TaskbarButtonLayout.preferredWidth(
                labelMode: labelMode,
                density: density,
                buttonWidth: currentPreferences.buttonWidth))
        button.widthConstraint?.isActive = true
        button.heightConstraint = button.heightAnchor.constraint(
            equalToConstant: density.buttonHeight)
        button.heightConstraint?.isActive = true
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        button.setContentHuggingPriority(.defaultLow, for: .vertical)
        button.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        button.wantsLayer = true
        button.layer?.cornerRadius = 6
        button.layer?.cornerCurve = .continuous
        updateButton(button, for: item, labelMode: labelMode, density: density)
        return button
    }

    private func updateButton(
        _ button: TaskbarButton,
        for item: TaskbarItem,
        labelMode: TaskbarLabelMode,
        density: TaskbarDensity
    ) {
        button.itemID = item.id
        button.title = item.buttonTitle(labelMode: labelMode)
        button.controlSize = density == .compact ? .small : .regular
        button.preferredIntrinsicHeight = density.buttonHeight
        button.onMiddleClick = { [weak self] in self?.onWindowCommand(.close(item)) }
        button.onPrimaryInteraction = { [weak self] anchor in
            self?.hoverPresenter.hide(from: anchor)
        }
        button.onHoverChanged = { [weak self] anchor, hovering in
            guard let self, let windowButton = anchor as? TaskbarButton else { return }
            if hovering,
                let current = self.currentItems.first(where: { $0.id == windowButton.itemID })
            {
                self.hoverPresenter.schedule(
                    applicationName: current.applicationName,
                    title: current.displayTitle,
                    icon: anchor.image,
                    tabs: current.nativeTabs,
                    onSelectTab: { [weak self] tab in
                        self?.onWindowCommand(.selectTab(current, tab))
                    },
                    onCloseTab: { [weak self] tab in
                        self?.onWindowCommand(.closeTab(current, tab))
                    },
                    onCloseWindow: { [weak self] in
                        self?.onWindowCommand(.close(current))
                    },
                    from: anchor
                )
            } else {
                self.hoverPresenter.pointerExited(from: anchor)
            }
        }
        button.onMenuRequested = { [weak self] in
            guard let self,
                let current = self.currentItems.first(where: { $0.id == item.id })
            else { return NSMenu() }
            return self.makeContextualMenu(for: current)
        }
        // Focus styling must never participate in intrinsic sizing: changing font weight
        // here makes every downstream taskbar item visibly reflow as focus moves.
        button.font = .systemFont(ofSize: 12, weight: .medium)
        button.contentTintColor = .labelColor
        button.alphaValue = item.isMinimized || item.isHidden ? 0.65 : 1
        // The custom hover card provides the complete title without the system
        // tooltip delay or truncation, while accessibility keeps the action label.
        button.toolTip = nil
        button.setAccessibilityRole(.button)
        button.setAccessibilityLabel(item.accessibilityLabel)
        button.image = icon(for: item)

        button.widthConstraint?.constant = TaskbarButtonLayout.preferredWidth(
            labelMode: labelMode,
            density: density,
            buttonWidth: currentPreferences.buttonWidth)
        button.heightConstraint?.constant = density.buttonHeight
        button.image?.size = NSSize(width: density.iconSize, height: density.iconSize)
        button.contextualMenu = makeContextualMenu(for: item)
        button.setActiveFocus(item.isActive)
    }

    private func resolveOverflowLayout(viewportWidth: CGFloat) -> TaskbarOverflowLayout {
        let launcherWidth = max(28, currentPreferences.density.buttonHeight)
        let nonWindowWidth =
            CGFloat(launchersByID.count) * launcherWidth
            + CGFloat(dividersByID.count)
            + CGFloat(max(0, currentEntries.count - 1)) * stackView.spacing
            + stackView.edgeInsets.left
            + stackView.edgeInsets.right
        return TaskbarOverflowLayout.resolve(
            viewportWidth: viewportWidth,
            windowCount: currentItems.count,
            fixedContentWidth: nonWindowWidth,
            requestedLabelMode: currentPreferences.labelMode,
            density: currentPreferences.density,
            buttonWidth: currentPreferences.buttonWidth,
            behavior: currentPreferences.overflowBehavior
        )
    }

    private func apply(_ overflowLayout: TaskbarOverflowLayout) {
        for item in currentItems {
            guard let button = buttonsByID[item.id] else { continue }
            button.title = item.buttonTitle(labelMode: overflowLayout.labelMode)
            button.widthConstraint?.constant = overflowLayout.windowWidth
            button.imagePosition =
                overflowLayout.labelMode == .iconOnly ? .imageOnly : .imageLeading
            button.alignment = overflowLayout.labelMode == .iconOnly ? .center : .left
        }
    }

    private func makeContextualMenu(for item: TaskbarItem) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let visibilityActionTitle =
            item.isHidden ? "Show" : (item.isMinimized ? "Restore" : "Minimize")
        menu.addItem(
            windowMenuItem(
                visibilityActionTitle, action: #selector(toggleMinimize(_:)),
                item: item))
        menu.addItem(menuItem("Minimize All", action: #selector(minimizeAll)))
        menu.addItem(
            windowMenuItem("Minimize Others", action: #selector(minimizeOthers(_:)), item: item))
        menu.addItem(.separator())
        menu.addItem(tinyTaskbarMenuItem(for: item))
        menu.addItem(.separator())
        let closeTitle = item.nativeTabs.count > 1 ? "Close All Tabs" : "Close"
        menu.addItem(windowMenuItem(closeTitle, action: #selector(closeWindow(_:)), item: item))
        return menu
    }

    private func tinyTaskbarMenuItem(for item: TaskbarItem? = nil) -> NSMenuItem {
        let parent = NSMenuItem(title: "TinyTaskbar", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "TinyTaskbar")
        submenu.autoenablesItems = false

        if let item {
            if let identity = item.applicationIdentity, record(for: item) != nil {
                let pinned = currentPreferences.pinnedApplications.contains {
                    $0.identity == identity
                }
                submenu.addItem(
                    windowMenuItem(
                        pinned ? "Unpin Application" : "Pin Application",
                        action: #selector(togglePin(_:)), item: item))
                submenu.addItem(
                    windowMenuItem(
                        "Never Show This App", action: #selector(excludeApplication(_:)),
                        item: item))
            } else {
                let pin = windowMenuItem(
                    "Pin Application", action: #selector(togglePin(_:)), item: item)
                pin.isEnabled = false
                submenu.addItem(pin)
                let exclude = windowMenuItem(
                    "Never Show This App", action: #selector(excludeApplication(_:)), item: item)
                exclude.isEnabled = false
                submenu.addItem(exclude)
            }
            submenu.addItem(.separator())
        }

        submenu.addItem(menuItem("Settings…", action: #selector(showSettings)))
        submenu.addItem(menuItem("Quit TinyTaskbar", action: #selector(quitApplication)))
        parent.submenu = submenu
        return parent
    }

    private func reorderViewsIfNeeded(to desiredIDs: [String]) {
        let currentIDs = stackView.arrangedSubviews.compactMap { $0.identifier?.rawValue }
        guard currentIDs != desiredIDs else { return }

        let allViews = Dictionary(
            uniqueKeysWithValues: stackView.arrangedSubviews.compactMap {
                view -> (String, NSView)? in
                guard let id = view.identifier?.rawValue else { return nil }
                return (id, view)
            })
        for view in stackView.arrangedSubviews {
            stackView.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for id in desiredIDs {
            if let view = allViews[id] { stackView.addArrangedSubview(view) }
        }
    }

    private func makeLauncher(_ application: ApplicationRecord) -> TaskbarLauncherButton {
        let button = TaskbarLauncherButton(
            title: "", target: self, action: #selector(launchApplication(_:)))
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.setAccessibilityRole(.button)
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }

    private func updateLauncher(
        _ button: TaskbarLauncherButton,
        application: ApplicationRecord,
        density: TaskbarDensity
    ) {
        button.applicationIdentity = application.identity
        button.controlSize = density == .compact ? .small : .regular
        button.preferredIntrinsicHeight = density.buttonHeight
        button.toolTip = nil
        button.setAccessibilityLabel("Open \(application.localizedName)")
        let source =
            application.bundlePath.map { NSWorkspace.shared.icon(forFile: $0) }
            ?? NSImage(systemSymbolName: "app", accessibilityDescription: nil)
        button.image = source?.copy() as? NSImage
        button.onHoverChanged = { [weak self] anchor, hovering in
            guard let self, let launcher = anchor as? TaskbarLauncherButton else { return }
            if hovering,
                let current = self.currentPreferences.pinnedApplications.first(where: {
                    $0.identity == launcher.applicationIdentity
                })
            {
                self.hoverPresenter.schedule(
                    applicationName: current.localizedName,
                    title: current.localizedName,
                    icon: anchor.image,
                    from: anchor
                )
            } else {
                self.hoverPresenter.hide(from: anchor)
            }
        }
        button.onPrimaryInteraction = { [weak self] anchor in
            self?.hoverPresenter.hide(from: anchor)
        }
        button.image?.size = NSSize(width: density.iconSize, height: density.iconSize)
        if button.widthConstraint == nil {
            button.widthConstraint = button.widthAnchor.constraint(
                equalToConstant: max(28, density.buttonHeight))
            button.widthConstraint?.isActive = true
        }
        if button.heightConstraint == nil {
            button.heightConstraint = button.heightAnchor.constraint(
                equalToConstant: density.buttonHeight)
            button.heightConstraint?.isActive = true
        }
        button.widthConstraint?.constant = max(28, density.buttonHeight)
        button.heightConstraint?.constant = density.buttonHeight
        let menu = NSMenu()
        menu.addItem(
            applicationMenuItem(
                "Open", action: #selector(openPinnedApplication(_:)), application: application))
        menu.addItem(.separator())
        menu.addItem(tinyTaskbarMenuItem(for: application))
        button.contextualMenu = menu
    }

    private func tinyTaskbarMenuItem(for application: ApplicationRecord) -> NSMenuItem {
        let parent = NSMenuItem(title: "TinyTaskbar", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "TinyTaskbar")
        submenu.addItem(
            applicationMenuItem(
                "Unpin Application", action: #selector(unpinApplication(_:)),
                application: application))
        submenu.addItem(
            applicationMenuItem(
                "Never Show This App", action: #selector(excludePinnedApplication(_:)),
                application: application))
        submenu.addItem(.separator())
        submenu.addItem(menuItem("Settings…", action: #selector(showSettings)))
        submenu.addItem(menuItem("Quit TinyTaskbar", action: #selector(quitApplication)))
        parent.submenu = submenu
        return parent
    }

    private func menuItem(_ title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    private func windowMenuItem(
        _ title: String, action: Selector, item: TaskbarItem
    ) -> NSMenuItem {
        let menuItem = self.menuItem(title, action: action)
        menuItem.representedObject = item.id
        return menuItem
    }

    private func applicationMenuItem(
        _ title: String, action: Selector, application: ApplicationRecord
    ) -> NSMenuItem {
        let item = menuItem(title, action: action)
        item.representedObject = application.identity
        return item
    }

    private func icon(for item: TaskbarItem) -> NSImage? {
        let key = ApplicationIconKey(item: item)
        if let cached = iconCache[key] { return cached }
        let source =
            NSRunningApplication(processIdentifier: item.pid)?.icon
            ?? NSImage(systemSymbolName: "macwindow", accessibilityDescription: nil)
            ?? NSImage(named: NSImage.applicationIconName)
        if let source,
            let icon = source.copy() as? NSImage
        {
            icon.size = NSSize(width: 18, height: 18)
            iconCache[key] = icon
            return icon
        }
        return nil
    }

    @objc private func activateButton(_ sender: NSButton) {
        hoverPresenter.hide()
        guard let item = buttons[ObjectIdentifier(sender)] else { return }
        if NSApp.currentEvent?.modifierFlags.contains(.option) == true {
            onWindowCommand(.minimizeOthers(item))
        } else {
            onActivate(item)
        }
    }

    @objc private func closeWindow(_ sender: NSMenuItem) {
        guard let itemID = sender.representedObject as? String,
            let item = currentItems.first(where: { $0.id == itemID })
        else {
            return
        }
        if item.nativeTabs.count > 1 {
            onWindowCommand(.closeTabGroup(item))
        } else {
            onClose(item)
        }
    }

    private func currentItem(_ sender: NSMenuItem) -> TaskbarItem? {
        guard let id = sender.representedObject as? String else { return nil }
        return currentItems.first { $0.id == id }
    }

    private func currentApplication(_ sender: NSMenuItem) -> ApplicationRecord? {
        guard let id = sender.representedObject as? String else { return nil }
        return currentPreferences.pinnedApplications.first { $0.identity == id }
    }

    private func record(for item: TaskbarItem) -> ApplicationRecord? {
        guard let identity = item.applicationIdentity,
            item.applicationBundlePath != nil || identity.contains(".")
        else { return nil }
        return ApplicationRecord(
            identity: identity,
            bundleIdentifier: identity.contains("/") ? nil : identity,
            bundlePath: item.applicationBundlePath,
            localizedName: item.applicationName,
            sequence: 0)
    }

    @objc private func toggleMinimize(_ sender: NSMenuItem) {
        guard let item = currentItem(sender) else { return }
        onWindowCommand(
            item.isHidden || item.isMinimized ? .restore(item) : .minimize(item))
    }
    @objc private func minimizeOthers(_ sender: NSMenuItem) {
        if let item = currentItem(sender) { onWindowCommand(.minimizeOthers(item)) }
    }
    @objc private func minimizeAll() { onWindowCommand(.minimizeAll) }
    @objc private func togglePin(_ sender: NSMenuItem) {
        guard let item = currentItem(sender), let record = record(for: item) else { return }
        let pinned = currentPreferences.pinnedApplications.contains {
            $0.identity == record.identity
        }
        onApplicationCommand(pinned ? .unpin(record.identity) : .pin(record))
    }
    @objc private func excludeApplication(_ sender: NSMenuItem) {
        guard let item = currentItem(sender), let record = record(for: item) else { return }
        onApplicationCommand(.exclude(record))
    }
    @objc private func launchApplication(_ sender: TaskbarLauncherButton) {
        hoverPresenter.hide()
        let id = sender.applicationIdentity
        guard
            let app = currentPreferences.pinnedApplications.first(where: { $0.identity == id })
        else { return }
        onApplicationCommand(.launch(app))
    }
    @objc private func openPinnedApplication(_ sender: NSMenuItem) {
        if let app = currentApplication(sender) { onApplicationCommand(.launch(app)) }
    }
    @objc private func unpinApplication(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String { onApplicationCommand(.unpin(id)) }
    }
    @objc private func excludePinnedApplication(_ sender: NSMenuItem) {
        if let app = currentApplication(sender) { onApplicationCommand(.exclude(app)) }
    }
    @objc private func showSettings() { onGlobalCommand(.showSettings) }
    @objc private func quitApplication() { onGlobalCommand(.quit) }
}
