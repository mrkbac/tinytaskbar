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
    }

    @MainActor
    final class DebugFixturePermissionProvider: AccessibilityPermissionProvider {
        func isTrusted() -> Bool { true }

        func requestAccess() -> Bool { false }
    }

    @MainActor
    final class DebugFixtureWindowSnapshotProvider: WindowSnapshotProvider {
        let fixture: DebugFixture
        var onChange: (@MainActor @Sendable () -> Void)?
        private var activePID: Int32?
        private var closedPIDs: Set<Int32> = []
        private var minimizedPIDs: Set<Int32> = []

        init(fixture: DebugFixture) {
            self.fixture = fixture
        }

        func snapshot() -> RawWindowSnapshot {
            let displays = DisplayReader.current()
            let resolvedDisplays = displays.isEmpty ? [syntheticDisplay] : displays
            let candidates = makeCandidates(displays: resolvedDisplays)
            let cgWindows = candidates.filter { !$0.isMinimized }.enumerated().map {
                index, candidate in
                CGWindowMetadata(
                    windowNumber: UInt32(50_000 + index),
                    ownerPID: candidate.pid,
                    bounds: candidate.frame ?? .zero,
                    title: candidate.title
                )
            }
            return RawWindowSnapshot(
                candidates: candidates,
                cgWindows: cgWindows,
                displays: resolvedDisplays,
                frontmostPID: activePID ?? candidates.first?.pid
            )
        }

        func activate(_ item: TaskbarItem) {
            minimizedPIDs.remove(item.pid)
            activePID = item.pid
            onChange?()
        }

        func minimize(_ item: TaskbarItem) {
            minimizedPIDs.insert(item.pid)
            if activePID == item.pid {
                activePID = nil
            }
            onChange?()
        }

        func close(_ item: TaskbarItem) {
            closedPIDs.insert(item.pid)
            if activePID == item.pid {
                activePID = nil
            }
            onChange?()
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
                    let pid = Int32(10_000 + globalIndex)
                    let applicationName = "Fixture App \(globalIndex + 1)"
                    let title = "Window \(globalIndex + 1) — 文書 🚀"
                    if !closedPIDs.contains(pid) {
                        let isMinimized = minimizedPIDs.contains(pid)
                        let isActive =
                            !isMinimized
                            && (activePID.map { $0 == pid } ?? !assignedFallbackActiveWindow)
                        assignedFallbackActiveWindow = assignedFallbackActiveWindow || isActive
                        candidates.append(
                            WindowCandidate(
                                stableKey: "fixture-window:\(pid)",
                                pid: pid,
                                applicationName: applicationName,
                                localizedApplicationName: applicationName,
                                title: title,
                                frame: CGRect(x: x, y: y, width: width, height: height),
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
