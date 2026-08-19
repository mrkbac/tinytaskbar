#if DEBUG
    import Foundation
    import Testing

    @testable import TinyTaskbar

    struct DebugFixtureTests {
        @Test("debug fixture parsing accepts only the explicit supported names")
        func fixtureParsing() {
            #expect(
                DebugFixture.parse(arguments: ["TinyTaskbar", "--ui-test-fixture=normal"])
                    == .normal)
            #expect(
                DebugFixture.parse(arguments: ["--ui-test-fixture=overflow"]) == .overflow)
            #expect(DebugFixture.parse(arguments: ["--ui-test-fixture=empty"]) == .empty)
            #expect(DebugFixture.parse(arguments: ["--ui-test-fixture=unknown"]) == nil)
            #expect(DebugFixture.parse(arguments: ["--fixture=normal"]) == nil)
        }

        @Test("indicator fixture is explicit and decorates deterministic applications")
        func indicatorFixtureParsing() {
            #expect(DebugFixture.indicators(arguments: ["TinyTaskbar"]) == .empty)

            let indicators = DebugFixture.indicators(
                arguments: ["TinyTaskbar", "--ui-test-indicators"])
            #expect(indicators.attentionPIDs == [10_001])
            #expect(
                indicators.badgesByApplicationIdentity
                    == ["com.tinytaskbar.fixture.app1": "7"])
            #expect(!DebugFixture.usesCompactIconLayout(arguments: ["TinyTaskbar"]))
            #expect(
                DebugFixture.usesCompactIconLayout(
                    arguments: ["TinyTaskbar", "--ui-test-compact-icons"]))
        }

        @Test("fixture activation moves the mocked frontmost window")
        @MainActor
        func activationChangesActiveWindow() {
            let provider = DebugFixtureWindowSnapshotProvider(fixture: .normal)
            let initial = provider.snapshot()
            guard initial.candidates.count >= 2 else {
                Issue.record("normal fixture did not create two windows")
                return
            }
            let first = initial.candidates[0]
            let selected = initial.candidates[1]
            let item = TaskbarItem(
                id: selected.stableKey!,
                pid: selected.pid,
                applicationName: selected.applicationName,
                title: selected.title,
                displayIdentifier: initial.displays[0].identifier,
                cgWindowNumber: nil,
                isActive: false
            )

            provider.activate(item)
            let activated = provider.snapshot()

            #expect(activated.frontmostPID == selected.pid)
            #expect(activated.candidates.first { $0.pid == selected.pid }?.isFocused == true)
            #expect(activated.candidates.first { $0.pid == first.pid }?.isFocused == false)
        }

        @Test("fixture minimizes and restores the selected mocked window")
        @MainActor
        func minimizeAndRestoreWindow() {
            let provider = DebugFixtureWindowSnapshotProvider(fixture: .normal)
            let initial = provider.snapshot()
            guard let selected = initial.candidates.first else {
                Issue.record("normal fixture did not create a window")
                return
            }
            let item = TaskbarItem(
                id: selected.stableKey!,
                pid: selected.pid,
                applicationName: selected.applicationName,
                title: selected.title,
                displayIdentifier: initial.displays[0].identifier,
                cgWindowNumber: nil,
                isActive: true
            )

            provider.minimize(item)
            let minimized = provider.snapshot()
            #expect(minimized.candidates.first { $0.pid == selected.pid }?.isMinimized == true)
            #expect(!minimized.cgWindows.contains { $0.ownerPID == selected.pid })

            provider.activate(item)
            let restored = provider.snapshot()
            #expect(restored.candidates.first { $0.pid == selected.pid }?.isMinimized == false)
            #expect(restored.frontmostPID == selected.pid)
        }

        @Test("fixture close removes only the selected mocked window")
        @MainActor
        func closeRemovesSelectedWindow() {
            let provider = DebugFixtureWindowSnapshotProvider(fixture: .normal)
            let initial = provider.snapshot()
            guard let selected = initial.candidates.first else {
                Issue.record("normal fixture did not create a window")
                return
            }
            let item = TaskbarItem(
                id: selected.stableKey!,
                pid: selected.pid,
                applicationName: selected.applicationName,
                title: selected.title,
                displayIdentifier: initial.displays[0].identifier,
                cgWindowNumber: nil,
                isActive: false
            )

            provider.close(item)
            let closed = provider.snapshot()

            #expect(closed.candidates.count == initial.candidates.count - 1)
            #expect(!closed.candidates.contains { $0.pid == selected.pid })
            #expect(closed.frontmostPID == closed.candidates.first?.pid)
            #expect(closed.candidates.first?.isFocused == true)
        }

        @Test("fixture store executes semantic window commands end to end")
        @MainActor
        func storeCommandRoundTrip() {
            let provider = DebugFixtureWindowSnapshotProvider(fixture: .normal)
            let store = TaskbarStore(provider: provider)
            store.start(accessibilityTrusted: true)
            store.refreshNow()
            defer { store.stop() }

            guard let initialItem = store.state.itemsByDisplay.values.joined().first else {
                Issue.record("normal fixture did not project a taskbar item")
                return
            }
            store.execute(.minimize(initialItem))
            store.refreshNow()
            #expect(
                store.state.itemsByDisplay.values.joined().first(where: {
                    $0.id == initialItem.id
                })?.isMinimized == true)

            store.execute(.restore(initialItem))
            store.refreshNow()
            #expect(
                store.state.itemsByDisplay.values.joined().first(where: {
                    $0.id == initialItem.id
                })?.isMinimized == false)

            store.execute(.close(initialItem))
            store.refreshNow()
            #expect(
                !store.state.itemsByDisplay.values.joined().contains(where: {
                    $0.id == initialItem.id
                }))
        }

        @Test("normal fixture provides stable app identities and multiple windows")
        @MainActor
        func applicationIdentityCoverage() {
            let snapshot = DebugFixtureWindowSnapshotProvider(fixture: .normal).snapshot()
            #expect(snapshot.candidates.allSatisfy { $0.applicationIdentity != nil })
            #expect(snapshot.candidates.allSatisfy { $0.applicationBundlePath != nil })
            let grouped = Dictionary(grouping: snapshot.candidates) { $0.applicationIdentity }
            #expect(grouped.values.contains { $0.count > 1 })
            #expect(
                Set(snapshot.candidates.compactMap(\.stableKey)).count == snapshot.candidates.count)
        }

        @Test("overflow fixture retains numeric creation order")
        @MainActor
        func overflowCreationOrder() {
            let provider = DebugFixtureWindowSnapshotProvider(fixture: .overflow)
            let snapshot = provider.snapshot()
            let state = WindowProjection.project(
                candidates: snapshot.candidates,
                cgWindows: snapshot.cgWindows,
                displays: snapshot.displays,
                selfPID: Int32(ProcessInfo.processInfo.processIdentifier),
                frontmostPID: snapshot.frontmostPID)
            guard let displayID = snapshot.displays.first?.identifier else {
                Issue.record("overflow fixture did not provide a display")
                return
            }
            #expect(
                state.itemsByDisplay[displayID]?.prefix(12).map(\.id)
                    == (1...12).map { String(format: "fixture-window:%03d", $0) })
        }
    }
#endif
