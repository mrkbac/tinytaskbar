import Foundation
import Testing

@testable import TinyTaskbar

struct PermissionTests {
    @Test("explicit Accessibility requests are offered at most once per launch")
    func requestDecisionIsOneShot() {
        var state = AccessibilityPermissionRequestState()

        #expect(state.decision() == .request)
        #expect(state.didRequest)
        #expect(state.decision() == .alreadyRequested)
    }

    @Test("Settings visibility temporarily uses regular activation")
    func settingsActivationPolicyTransitions() {
        var state = SettingsActivationPolicyState()

        #expect(state.policy == .accessory)
        #expect(state.apply(.show) == .regular)
        #expect(state.policy == .regular)
        #expect(state.apply(.close) == .accessory)
        #expect(state.policy == .accessory)
    }

    @Test("preferences default and persisted state transitions")
    @MainActor
    func preferencesPersist() {
        let suiteName = "TinyTaskbarTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = TinyTaskbarPreferencesStore(defaults: defaults)
        #expect(store.values == .defaults)

        store.setOnboardingComplete(true)
        store.setShowsWindowTitles(false)

        let reloaded = TinyTaskbarPreferencesStore(defaults: defaults)
        #expect(
            reloaded.values
                == TinyTaskbarPreferences(onboardingComplete: true, showsWindowTitles: false))
    }

    @Test("title preference hides only the compact button title")
    func titlePreferencePreservesAccessibilityLabel() {
        let item = TaskbarItem(
            id: "window",
            pid: 10,
            applicationName: "Editor",
            title: "Project.swift",
            displayIdentifier: "main",
            cgWindowNumber: nil,
            isActive: false
        )

        #expect(item.buttonTitle(showsWindowTitles: true) == "Project.swift")
        #expect(item.buttonTitle(showsWindowTitles: false) == "Editor")
        #expect(item.accessibilityLabel == "Editor, Project.swift")
        #expect(item.tooltip == "Activate Editor: Project.swift")
    }

    @Test("denied launch never enumerates or emits taskbar state")
    @MainActor
    func deniedLaunchDoesNotEnumerate() {
        let provider = MockWindowSnapshotProvider()
        let store = TaskbarStore(provider: provider)
        var stateChangeCount = 0
        store.onStateChange = { _ in stateChangeCount += 1 }

        store.start(accessibilityTrusted: false)

        #expect(provider.snapshotCount == 0)
        #expect(stateChangeCount == 0)
        #expect(store.state == .empty)
        #expect(store.lifecycleState == .awaitingAccessibility)
    }

    @Test("granting Accessibility refreshes and revocation clears state")
    @MainActor
    func accessibilityTransitionsDriveRefresh() async {
        let provider = MockWindowSnapshotProvider()
        let store = TaskbarStore(provider: provider)
        provider.snapshotValue = makeFixtureSnapshot()
        defer { store.stop() }

        store.start(accessibilityTrusted: false)
        store.setAccessibilityAvailable(true)
        try? await Task.sleep(nanoseconds: 100_000_000)

        #expect(provider.snapshotCount == 1)
        #expect(store.state.itemsByDisplay["main"]?.count == 1)
        #expect(store.lifecycleState == .running)

        store.setAccessibilityAvailable(false)

        #expect(store.state == .empty)
        #expect(store.lifecycleState == .runningWithoutAccessibility)
        #expect(provider.snapshotCount == 1)
    }

    @Test("repeated refresh requests coalesce into one snapshot")
    @MainActor
    func refreshRequestsCoalesce() async {
        let provider = MockWindowSnapshotProvider(snapshot: makeFixtureSnapshot())
        let store = TaskbarStore(provider: provider)
        defer { store.stop() }

        store.start(accessibilityTrusted: false)
        store.setAccessibilityAvailable(true)
        store.requestRefresh()
        store.requestRefresh()
        try? await Task.sleep(nanoseconds: 100_000_000)

        #expect(provider.snapshotCount == 1)
    }

    @Test("malformed and empty provider snapshots remain safe")
    @MainActor
    func malformedSnapshotsAreIsolated() {
        let provider = MockWindowSnapshotProvider()
        let store = TaskbarStore(provider: provider)
        store.start(accessibilityTrusted: true)
        defer { store.stop() }

        store.refreshNow()
        #expect(provider.snapshotCount == 1)
        #expect(store.state == .empty)

        let malformedCandidate = WindowCandidate(
            pid: fixturePID,
            applicationName: "Malformed",
            frame: CGRect(x: CGFloat.nan, y: 0, width: 500, height: 300)
        )
        provider.snapshotValue = RawWindowSnapshot(
            candidates: [malformedCandidate],
            cgWindows: [
                CGWindowMetadata(
                    ownerPID: fixturePID,
                    bounds: CGRect(x: CGFloat.nan, y: 0, width: 500, height: 300)
                )
            ],
            displays: [fixtureDisplay],
            frontmostPID: fixturePID
        )
        store.refreshNow()

        #expect(provider.snapshotCount == 2)
        #expect(store.state.itemsByDisplay.isEmpty)
    }

    @Test("stale activation is ignored after Accessibility revocation")
    @MainActor
    func staleActivationIsSafe() {
        let provider = MockWindowSnapshotProvider(snapshot: makeFixtureSnapshot())
        let store = TaskbarStore(provider: provider)
        store.start(accessibilityTrusted: true)
        store.refreshNow()
        defer { store.stop() }

        guard let item = store.state.itemsByDisplay["main"]?.first else {
            Issue.record("fixture item was not projected")
            return
        }

        store.activate(item)
        #expect(provider.activationCount == 1)

        store.setAccessibilityAvailable(false)
        store.activate(item)
        #expect(provider.activationCount == 1)
    }

    @Test("injected Accessibility provider exposes trust and request calls")
    @MainActor
    func accessibilityProviderSeam() {
        let provider = MockAccessibilityPermissionProvider(trusted: false)

        #expect(!provider.isTrusted())
        #expect(provider.requestAccess())
        #expect(provider.requestCount == 1)
    }

    private func makeFixtureSnapshot() -> RawWindowSnapshot {
        let candidate = WindowCandidate(
            pid: fixturePID,
            applicationName: "Fixture",
            title: "Document",
            frame: CGRect(x: 100, y: 100, width: 500, height: 300),
            isFocused: true,
            isMain: true
        )
        return RawWindowSnapshot(
            candidates: [candidate],
            cgWindows: [
                CGWindowMetadata(
                    windowNumber: 77,
                    ownerPID: fixturePID,
                    bounds: candidate.frame!,
                    title: candidate.title
                )
            ],
            displays: [fixtureDisplay],
            frontmostPID: fixturePID
        )
    }

    private var fixtureDisplay: DisplayDescriptor {
        DisplayDescriptor(
            identifier: "main",
            frame: CGRect(x: 0, y: 0, width: 1_200, height: 800)
        )
    }

    private var fixturePID: Int32 {
        Int32(ProcessInfo.processInfo.processIdentifier + 1)
    }
}

@MainActor
private final class MockWindowSnapshotProvider: WindowSnapshotProvider {
    var snapshotValue: RawWindowSnapshot = RawWindowSnapshot(
        candidates: [], cgWindows: [], displays: [], frontmostPID: nil)
    var snapshotCount = 0
    var activationCount = 0
    var onChange: (@MainActor @Sendable () -> Void)?

    init(snapshot: RawWindowSnapshot? = nil) {
        if let snapshot {
            snapshotValue = snapshot
        }
    }

    func snapshot() -> RawWindowSnapshot {
        snapshotCount += 1
        return snapshotValue
    }

    func activate(_: TaskbarItem) {
        activationCount += 1
    }
}

@MainActor
private final class MockAccessibilityPermissionProvider: AccessibilityPermissionProvider {
    var trusted: Bool
    var requestCount = 0

    init(trusted: Bool) {
        self.trusted = trusted
    }

    func isTrusted() -> Bool {
        trusted
    }

    func requestAccess() -> Bool {
        requestCount += 1
        trusted = true
        return true
    }
}
