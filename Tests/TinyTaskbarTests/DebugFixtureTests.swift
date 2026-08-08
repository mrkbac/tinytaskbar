#if DEBUG
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
                id: "fixture-selection",
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
                id: "fixture-close",
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
    }
#endif
