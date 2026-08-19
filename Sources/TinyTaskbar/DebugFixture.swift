#if DEBUG
    import AppKit
    import Foundation

    enum DebugFixture: String, CaseIterable, Sendable {
        case normal
        case overflow
        case empty

        static func parse(arguments: [String]) -> DebugFixture? {
            let prefix = "--ui-test-fixture="
            for argument in arguments where argument.hasPrefix(prefix) {
                return DebugFixture(rawValue: String(argument.dropFirst(prefix.count)))
            }
            return nil
        }

        static func indicators(arguments: [String]) -> ApplicationIndicatorSnapshot {
            guard arguments.contains("--ui-test-indicators") else { return .empty }
            return ApplicationIndicatorSnapshot(
                attentionPIDs: [10_001],
                badgesByApplicationIdentity: ["com.tinytaskbar.fixture.app1": "7"])
        }

    }

    @MainActor
    final class DebugFixturePermissionProvider: AccessibilityPermissionProvider {
        func isTrusted() -> Bool { true }

        func requestAccess() -> Bool { false }
    }

    @MainActor
    final class DebugFixtureWindowSnapshotProvider: WindowSnapshotProvider {
        let fixture: DebugFixture
        var onChange: (@MainActor @Sendable (WindowSnapshotChange) -> Void)?
        private var activeItemID: String?
        private var closedItemIDs: Set<String> = []
        private var minimizedItemIDs: Set<String> = []
        private var knownApplicationPIDs: Set<Int32> = []
        private var overriddenFramesByItemID: [String: CGRect] = [:]

        init(fixture: DebugFixture) {
            self.fixture = fixture
        }

        func snapshot() -> RawWindowSnapshot {
            let displays = DisplayReader.current()
            let resolvedDisplays = displays.isEmpty ? [syntheticDisplay] : displays
            let candidates = makeCandidates(displays: resolvedDisplays)
            knownApplicationPIDs.formUnion(candidates.map(\.pid))
            let cgWindows = candidates.filter { !$0.isMinimized }.map { candidate in
                let fixtureNumber =
                    Int(
                        candidate.stableKey?.split(separator: ":").last ?? "0") ?? 0
                return CGWindowMetadata(
                    windowNumber: UInt32(50_000 + max(0, fixtureNumber - 1)),
                    ownerPID: candidate.pid,
                    bounds: candidate.frame ?? .zero,
                    title: candidate.title
                )
            }
            return RawWindowSnapshot(
                candidates: candidates,
                cgWindows: cgWindows,
                displays: resolvedDisplays,
                frontmostPID: candidates.first(where: { $0.stableKey == activeItemID })?.pid
                    ?? candidates.first?.pid,
                evidence: WindowSnapshotEvidence(
                    isComplete: true,
                    knownApplicationPIDs: knownApplicationPIDs,
                    axWindowListReadPIDs: knownApplicationPIDs,
                    observedAXWindowIDs: Set(candidates.compactMap(\.stableKey)))
            )
        }

        func activate(_ item: TaskbarItem) {
            minimizedItemIDs.remove(item.id)
            activeItemID = item.id
            onChange?(.ordinary)
        }

        func selectTab(_: TaskbarTab, in item: TaskbarItem) {
            activate(item)
        }

        func closeTab(_: TaskbarTab, in item: TaskbarItem) {
            close(item)
        }

        func closeTabGroup(_ item: TaskbarItem) {
            close(item)
        }

        func minimize(_ item: TaskbarItem) {
            minimizedItemIDs.insert(item.id)
            if activeItemID == item.id {
                activeItemID = nil
            }
            onChange?(.ordinary)
        }

        func close(_ item: TaskbarItem) {
            closedItemIDs.insert(item.id)
            if activeItemID == item.id {
                activeItemID = nil
            }
            onChange?(.windowDestroyed)
        }

        @discardableResult
        func setHeight(_ height: CGFloat, for item: TaskbarItem) -> Bool {
            guard height.isFinite, height > 0 else { return false }
            guard
                let currentFrame = snapshot().candidates.first(where: {
                    $0.stableKey == item.id
                })?.frame
            else { return false }
            overriddenFramesByItemID[item.id] = CGRect(
                origin: currentFrame.origin,
                size: CGSize(width: currentFrame.width, height: height))
            onChange?(.ordinary)
            return true
        }

        private var syntheticDisplay: DisplayDescriptor {
            DisplayDescriptor(
                identifier: "fixture:display",
                frame: CGRect(x: 0, y: 0, width: 1_280, height: 800),
                appKitFrame: CGRect(x: 0, y: 0, width: 1_280, height: 800),
                appKitVisibleFrame: CGRect(x: 0, y: 0, width: 1_280, height: 800)
            )
        }

        private func makeCandidates(displays: [DisplayDescriptor]) -> [WindowCandidate] {
            guard fixture != .empty else { return [] }

            var candidates: [WindowCandidate] = []
            var globalIndex = 0
            var assignedFallbackActiveWindow = false
            for (displayIndex, display) in displays.enumerated() {
                let count = fixture == .overflow && displayIndex == 0 ? 120 : 4
                let width = min(360, max(160, display.frame.width - 100))
                let height = min(220, max(100, display.frame.height - 100))
                for index in 0..<count {
                    let column = index % 6
                    let row = index / 6
                    let x = display.frame.minX + 40 + CGFloat(column * 24)
                    let y = display.frame.minY + 40 + CGFloat(row * 18)
                    let applicationIndex: Int
                    if fixture == .normal {
                        applicationIndex = globalIndex == 0 ? 0 : (globalIndex + 1) / 2
                    } else {
                        applicationIndex = globalIndex / 3
                    }
                    let pid = Int32(10_000 + applicationIndex)
                    let applicationName = "Fixture App \(applicationIndex + 1)"
                    let applicationIdentity = "com.tinytaskbar.fixture.app\(applicationIndex + 1)"
                    let itemID = String(
                        format: "fixture-window:%03d", globalIndex + 1)
                    let title = "Window \(globalIndex + 1) — 文書 🚀"
                    if !closedItemIDs.contains(itemID) {
                        let isMinimized = minimizedItemIDs.contains(itemID)
                        let isActive =
                            !isMinimized
                            && (activeItemID.map { $0 == itemID } ?? !assignedFallbackActiveWindow)
                        assignedFallbackActiveWindow = assignedFallbackActiveWindow || isActive
                        candidates.append(
                            WindowCandidate(
                                stableKey: itemID,
                                pid: pid,
                                applicationName: applicationName,
                                applicationIdentity: applicationIdentity,
                                applicationBundlePath: "/Applications/\(applicationName).app",
                                localizedApplicationName: applicationName,
                                title: title,
                                frame: overriddenFramesByItemID[itemID]
                                    ?? CGRect(x: x, y: y, width: width, height: height),
                                isMinimized: isMinimized,
                                isFocused: isActive,
                                isMain: isActive
                            )
                        )
                    }
                    globalIndex += 1
                }
            }
            return candidates
        }
    }
#endif
