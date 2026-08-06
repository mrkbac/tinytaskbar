import CoreGraphics
import Testing

@testable import TinyTaskbar

struct WindowModelTests {
    @Test("eligibility accepts standard and dialog windows")
    func eligibleWindowRules() {
        let eligibility = WindowEligibility()
        let standard = WindowCandidate(
            pid: 10,
            applicationName: "Editor",
            title: "Document",
            frame: CGRect(x: 20, y: 20, width: 500, height: 300)
        )
        let dialog = WindowCandidate(
            pid: 11,
            applicationName: "Editor",
            subrole: "AXDialog",
            title: "Save",
            frame: CGRect(x: 40, y: 40, width: 320, height: 180)
        )

        #expect(eligibility.isEligible(standard, selfPID: 999))
        #expect(eligibility.isEligible(dialog, selfPID: 999))
        #expect(!eligibility.isEligible(standard, selfPID: 10))
    }

    @Test("eligibility rejects malformed and transient candidates")
    func ineligibleWindowRules() {
        let eligibility = WindowEligibility()
        let candidates = [
            WindowCandidate(pid: 1, applicationName: "App", frame: nil),
            WindowCandidate(
                pid: 2,
                applicationName: "App",
                subrole: "AXFloatingWindow",
                frame: CGRect(x: 0, y: 0, width: 300, height: 200)
            ),
            WindowCandidate(
                pid: 3,
                applicationName: "App",
                frame: CGRect(x: 0, y: 0, width: 20, height: 20)
            ),
            WindowCandidate(
                pid: 4,
                applicationName: "App",
                frame: CGRect(x: 0, y: 0, width: 300, height: 200),
                isHidden: true
            ),
            WindowCandidate(
                pid: 5,
                applicationName: "App",
                frame: CGRect(x: 0, y: 0, width: 300, height: 200),
                isMinimized: true
            ),
            WindowCandidate(
                pid: 6,
                applicationName: "App",
                applicationIsRegular: false,
                frame: CGRect(x: 0, y: 0, width: 300, height: 200)
            ),
        ]

        for candidate in candidates {
            #expect(!eligibility.isEligible(candidate, selfPID: 999))
        }
    }

    @Test("projection requires an on-screen layer-zero Core Graphics match")
    func conservativeCGMatch() {
        let candidate = WindowCandidate(
            pid: 10,
            applicationName: "Editor",
            title: "Document",
            frame: CGRect(x: 100, y: 100, width: 500, height: 300)
        )
        let display = DisplayDescriptor(
            identifier: "main",
            frame: CGRect(x: 0, y: 0, width: 1440, height: 900)
        )
        let good = CGWindowMetadata(
            windowNumber: 12,
            ownerPID: 10,
            bounds: candidate.frame!,
            title: "Document"
        )
        let wrongLayer = CGWindowMetadata(
            ownerPID: 10,
            layer: 3,
            bounds: candidate.frame!,
            title: "Document"
        )
        let offScreen = CGWindowMetadata(
            ownerPID: 10,
            bounds: candidate.frame!,
            title: "Document",
            isOnScreen: false
        )

        #expect(
            WindowProjection.project(
                candidates: [candidate],
                cgWindows: [good],
                displays: [display],
                selfPID: 999
            ).itemsByDisplay["main"]?.count == 1)
        #expect(
            WindowProjection.project(
                candidates: [candidate],
                cgWindows: [wrongLayer, offScreen],
                displays: [display],
                selfPID: 999
            ) == TaskbarState(displays: [display], itemsByDisplay: [:]))
    }

    @Test("untitled windows use the application name for display")
    func untitledFallback() {
        let candidate = WindowCandidate(
            pid: 10,
            applicationName: "Notes",
            title: "",
            frame: CGRect(x: 0, y: 0, width: 400, height: 300)
        )
        let display = DisplayDescriptor(
            identifier: "main", frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let item = WindowProjection.project(
            candidates: [candidate],
            cgWindows: [CGWindowMetadata(ownerPID: 10, bounds: candidate.frame!)],
            displays: [display],
            selfPID: 999
        ).itemsByDisplay["main"]!.first!

        #expect(item.displayTitle == "Notes")
    }

    @Test("display mapping chooses greatest intersection and deterministic ties")
    func displayIntersectionAndTie() {
        let left = DisplayDescriptor(
            identifier: "a", frame: CGRect(x: 0, y: 0, width: 500, height: 500))
        let right = DisplayDescriptor(
            identifier: "b", frame: CGRect(x: 500, y: 0, width: 500, height: 500))
        #expect(
            DisplayMapper.identifier(
                for: CGRect(x: 400, y: 100, width: 300, height: 200),
                displays: [left, right]
            ) == "b")
        #expect(
            DisplayMapper.identifier(
                for: CGRect(x: 450, y: 100, width: 100, height: 200),
                displays: [right, left]
            ) == "a")
    }

    @Test("display mapping falls back to containing center and nearest screen")
    func displayFallbacks() {
        let left = DisplayDescriptor(
            identifier: "left", frame: CGRect(x: 0, y: 0, width: 500, height: 500))
        let right = DisplayDescriptor(
            identifier: "right", frame: CGRect(x: 600, y: 0, width: 500, height: 500))
        #expect(
            DisplayMapper.identifier(
                for: CGRect(x: 570, y: 200, width: 0, height: 0),
                displays: [left, right]
            ) == "right")
        #expect(
            DisplayMapper.identifier(
                for: CGRect(x: 570, y: 200, width: 40, height: 40),
                displays: [left, right]
            ) == "right")
    }

    @Test("ordering puts active windows first then stable textual keys")
    func stableOrdering() {
        let items = [
            TaskbarItem(
                id: "z", pid: 1, applicationName: "Beta", title: "A", displayIdentifier: "main",
                cgWindowNumber: nil, isActive: false),
            TaskbarItem(
                id: "b", pid: 2, applicationName: "Alpha", title: "Z", displayIdentifier: "main",
                cgWindowNumber: nil, isActive: false),
            TaskbarItem(
                id: "a", pid: 3, applicationName: "Alpha", title: "A", displayIdentifier: "main",
                cgWindowNumber: nil, isActive: true),
        ]

        #expect(WindowOrdering.sorted(items).map(\.id) == ["a", "b", "z"])
    }

    @Test("deduplication keeps the strongest observation")
    func deduplication() {
        let duplicate = TaskbarItem(
            id: "same", pid: 1, applicationName: "App", title: "Window", displayIdentifier: "main",
            cgWindowNumber: nil, isActive: false)
        let active = TaskbarItem(
            id: "same", pid: 1, applicationName: "App", title: "Window", displayIdentifier: "main",
            cgWindowNumber: 8, isActive: true)
        #expect(WindowDeduplicator.deduplicate([duplicate, active]) == [active])
    }

    @Test("lifecycle reducer preserves permission-denied graceful running state")
    func lifecycleTransitions() {
        let awaiting = LifecycleReducer.reduce(
            state: .stopped,
            event: .launched(accessibilityTrusted: false)
        )
        #expect(awaiting == .awaitingAccessibility)
        #expect(
            LifecycleReducer.reduce(state: awaiting, event: .accessibilityChanged(false))
                == .runningWithoutAccessibility)
        #expect(
            LifecycleReducer.reduce(state: awaiting, event: .accessibilityChanged(true)) == .running
        )
        #expect(LifecycleReducer.reduce(state: .running, event: .stopped) == .stopped)
    }

    @Test("malformed projection is isolated without crashing")
    func malformedProjection() {
        let malformed = WindowCandidate(
            pid: 42,
            applicationName: "Malformed",
            frame: CGRect(x: CGFloat.nan, y: 0, width: 400, height: 300)
        )
        let state = WindowProjection.project(
            candidates: [malformed],
            cgWindows: [
                CGWindowMetadata(
                    ownerPID: 42, bounds: CGRect(x: CGFloat.nan, y: 0, width: 400, height: 300))
            ],
            displays: [
                DisplayDescriptor(
                    identifier: "main", frame: CGRect(x: 0, y: 0, width: 800, height: 600))
            ],
            selfPID: 999
        )
        #expect(state.itemsByDisplay.isEmpty)
    }
}
