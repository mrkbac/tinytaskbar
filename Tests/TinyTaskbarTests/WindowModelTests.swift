import CoreGraphics
import Testing

@testable import TinyTaskbar

struct WindowModelTests {
    @Test("candidate frame replacement preserves window identity and state")
    func candidateFrameReplacement() {
        let original = WindowCandidate(
            stableKey: "window-1",
            cgWindowNumber: 42,
            pid: 10,
            applicationName: "Editor",
            title: "Document",
            frame: CGRect(x: 10, y: 20, width: 800, height: 600),
            isFocused: true,
            nativeTabGroupID: "group-1",
            nativeTabs: [TaskbarTab(id: "tab-1", title: "Document", isSelected: true)]
        )
        let replacement = CGRect(x: 10, y: 20, width: 800, height: 570)

        let updated = original.replacingFrame(replacement)

        #expect(updated.frame == replacement)
        #expect(updated.replacingFrame(original.frame!) == original)
    }

    @Test("candidate matches only the selected physical window or native tab group")
    func candidateRepresentsTaskbarItem() {
        let candidate = WindowCandidate(
            stableKey: "window-1",
            cgWindowNumber: 42,
            pid: 10,
            applicationName: "Editor",
            title: "Document",
            frame: CGRect(x: 10, y: 20, width: 800, height: 600)
        )
        let exact = TaskbarItem(
            id: "window-1", pid: 10, applicationName: "Editor", title: "Document",
            displayIdentifier: "main", cgWindowNumber: 42, isActive: false)
        let samePhysicalWindow = TaskbarItem(
            id: "different-stable-key", pid: 10, applicationName: "Editor",
            title: "Document", displayIdentifier: "main", cgWindowNumber: 42,
            isActive: false)
        let sibling = TaskbarItem(
            id: "window-2", pid: 10, applicationName: "Editor", title: "Other",
            displayIdentifier: "main", cgWindowNumber: 43, isActive: false)

        #expect(candidate.represents(exact))
        #expect(candidate.represents(samePhysicalWindow))
        #expect(!candidate.represents(sibling))

        let groupedCandidate = candidate.assigningNativeTabGroup(
            id: "group-1",
            tabs: [TaskbarTab(id: "tab-1", title: "Document", isSelected: true)]
        )
        let groupedItem = TaskbarItem(
            id: "group-1", pid: 10, applicationName: "Editor", title: "Document",
            displayIdentifier: "main", cgWindowNumber: 42, isActive: false,
            nativeTabGroupID: "group-1")
        #expect(groupedCandidate.represents(groupedItem))
        #expect(!candidate.represents(groupedItem))
    }

    @Test("window identities do not depend on hash uniqueness")
    func collisionSafeWindowIdentityRegistry() {
        struct CollidingElement: Hashable {
            let value: Int

            func hash(into hasher: inout Hasher) {
                hasher.combine(0)
            }
        }

        var registry = WindowElementIdentityRegistry<CollidingElement> {
            $0.value == $1.value
        }
        registry.beginSnapshot()
        let first = registry.identifier(for: CollidingElement(value: 1), namespace: "42")
        let second = registry.identifier(for: CollidingElement(value: 2), namespace: "42")
        let repeatedFirst = registry.identifier(
            for: CollidingElement(value: 1), namespace: "42")
        registry.endSnapshot()

        #expect(first != second)
        #expect(repeatedFirst == first)
    }

    @Test("AX frames preserve global top-left CG screen coordinates")
    func axCoordinatesRemainUnchanged() {
        let axFrame = CGRect(x: -1280, y: 100, width: 640, height: 400)

        let cgFrame = AXScreenCoordinateMapper.toCGScreen(axFrame)

        #expect(cgFrame == axFrame)
        #expect(cgFrame.minY == 100)
    }

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
                pid: 6,
                applicationName: "App",
                applicationIsRegular: false,
                frame: CGRect(x: 0, y: 0, width: 300, height: 200)
            ),
            WindowCandidate(
                pid: 7,
                applicationName: "App",
                applicationIsRunning: false,
                frame: CGRect(x: 0, y: 0, width: 300, height: 200)
            ),
            WindowCandidate(
                pid: 9,
                applicationName: "App",
                role: "AXSheet",
                frame: CGRect(x: 0, y: 0, width: 300, height: 200)
            ),
            WindowCandidate(
                pid: 10,
                applicationName: "App",
                subrole: "AXPopover",
                frame: CGRect(x: 0, y: 0, width: 300, height: 200)
            ),
            WindowCandidate(
                pid: 11,
                applicationName: "App",
                frame: CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 200)
            ),
            WindowCandidate(
                pid: 12,
                applicationName: "App",
                frame: CGRect(x: 0, y: 0, width: 300, height: -CGFloat.infinity)
            ),
        ]

        for candidate in candidates {
            #expect(!eligibility.isEligible(candidate, selfPID: 999))
        }

        let minimized = WindowCandidate(
            pid: 5,
            applicationName: "App",
            frame: CGRect(x: 0, y: 0, width: 300, height: 200),
            isMinimized: true
        )
        #expect(eligibility.isEligible(minimized, selfPID: 999))

        let hidden = WindowCandidate(
            pid: 8,
            applicationName: "App",
            applicationIsHidden: true,
            frame: CGRect(x: 0, y: 0, width: 300, height: 200),
            isHidden: true
        )
        #expect(eligibility.isEligible(hidden, selfPID: 999))
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
        let wrongPID = CGWindowMetadata(
            ownerPID: 11,
            bounds: candidate.frame!,
            title: "Document"
        )
        let wrongBounds = CGWindowMetadata(
            ownerPID: 10,
            bounds: CGRect(x: 200, y: 100, width: 500, height: 300),
            title: "Document"
        )
        let wrongTitle = CGWindowMetadata(
            ownerPID: 10,
            bounds: candidate.frame!,
            title: "Other document"
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
        #expect(
            CGWindowMatcher.match(
                candidate: candidate,
                windows: [wrongPID, wrongBounds, wrongTitle]
            ) == wrongTitle)

        let ambiguousA = CGWindowMetadata(
            windowNumber: 21,
            ownerPID: 10,
            bounds: candidate.frame!,
            title: "First stale title"
        )
        let ambiguousB = CGWindowMetadata(
            windowNumber: 22,
            ownerPID: 10,
            bounds: candidate.frame!,
            title: "Second stale title"
        )
        #expect(
            CGWindowMatcher.match(candidate: candidate, windows: [ambiguousA, ambiguousB]) == nil)
    }

    @Test("projection reuses supplied Core Graphics assignments")
    func projectionUsesSuppliedAssignments() {
        let frame = CGRect(x: 100, y: 100, width: 500, height: 300)
        let candidate = WindowCandidate(
            pid: 10,
            applicationName: "Editor",
            title: "Document",
            frame: frame)
        let window = CGWindowMetadata(
            windowNumber: 12,
            ownerPID: 10,
            bounds: frame,
            title: candidate.title)
        let display = DisplayDescriptor(
            identifier: "main",
            frame: CGRect(x: 0, y: 0, width: 1_440, height: 900))

        let withoutAssignment = WindowProjection.project(
            candidates: [candidate],
            cgWindows: [window],
            assignments: [:],
            displays: [display],
            selfPID: 999)
        let withAssignment = WindowProjection.project(
            candidates: [candidate],
            cgWindows: [window],
            assignments: [0: 0],
            displays: [display],
            selfPID: 999)

        #expect(withoutAssignment.itemsByDisplay["main"] == nil)
        #expect(withAssignment.itemsByDisplay["main"]?.count == 1)
    }

    @Test("projection does not promote AX-only minimized native tabs")
    func minimizedNativeTabsRequirePriorPhysicalEvidence() {
        let frame = CGRect(x: 100, y: 100, width: 500, height: 300)
        let display = DisplayDescriptor(
            identifier: "main",
            frame: CGRect(x: 0, y: 0, width: 1_440, height: 900)
        )
        let candidates = ["selected-tab", "background-tab"].map { key in
            WindowCandidate(
                stableKey: key,
                pid: 10,
                applicationName: "Terminal",
                title: key,
                frame: frame,
                isMinimized: true
            )
        }

        let state = WindowProjection.project(
            candidates: candidates,
            cgWindows: [],
            displays: [display],
            selfPID: 999
        )

        #expect(state.itemsByDisplay.isEmpty)
    }

    @Test("minimized native tab group projects as one selectable taskbar item")
    func minimizedNativeTabGroupCollapsesPhysicalSiblings() {
        let frame = CGRect(x: 100, y: 100, width: 500, height: 300)
        let display = DisplayDescriptor(
            identifier: "main",
            frame: CGRect(x: 0, y: 0, width: 1_440, height: 900)
        )
        let tabs = [
            TaskbarTab(id: "tab-alpha", title: "Alpha", isSelected: true),
            TaskbarTab(id: "tab-beta", title: "Beta", isSelected: false),
            TaskbarTab(id: "tab-gamma", title: "Gamma", isSelected: false),
        ]
        let candidates = [
            WindowCandidate(
                stableKey: "window-alpha",
                cgWindowNumber: 41,
                pid: 10,
                applicationName: "Terminal",
                title: "Alpha",
                frame: frame,
                isMinimized: true,
                nativeTabGroupID: "native-group",
                nativeTabs: tabs
            ),
            WindowCandidate(
                stableKey: "window-beta",
                cgWindowNumber: 42,
                pid: 10,
                applicationName: "Terminal",
                title: "Previous Beta title",
                frame: frame,
                isMinimized: true
            ),
            WindowCandidate(
                stableKey: "window-gamma",
                cgWindowNumber: 43,
                pid: 10,
                applicationName: "Terminal",
                title: "Gamma",
                frame: frame,
                isMinimized: true
            ),
        ]
        let cgWindows = zip(candidates, UInt32(41)...UInt32(43)).map { candidate, number in
            CGWindowMetadata(
                windowNumber: number,
                ownerPID: 10,
                bounds: frame,
                title: candidate.title,
                isOnScreen: false
            )
        }

        let resolvedCandidates = NativeTabGroupMembershipResolver.assign(candidates)
        let state = WindowProjection.project(
            candidates: resolvedCandidates,
            cgWindows: cgWindows,
            displays: [display],
            selfPID: 999
        )

        let item = state.itemsByDisplay["main"]?.first
        #expect(state.itemsByDisplay["main"]?.count == 1)
        #expect(Set(resolvedCandidates.compactMap(\.nativeTabGroupID)) == ["native-group"])
        #expect(item?.id == "native-group")
        #expect(item?.nativeTabs == tabs)
        #expect(item?.isMinimized == true)
    }

    @Test("cold-start projection includes an exactly identified minimized window")
    func minimizedWindowUsesExactOffScreenIdentity() {
        let frame = CGRect(x: 100, y: 100, width: 500, height: 300)
        let display = DisplayDescriptor(
            identifier: "main",
            frame: CGRect(x: 0, y: 0, width: 1_440, height: 900)
        )
        let minimized = WindowCandidate(
            stableKey: "minimized",
            cgWindowNumber: 42,
            pid: 10,
            applicationName: "Editor",
            title: "Document",
            frame: frame,
            isMinimized: true
        )
        let offScreen = CGWindowMetadata(
            windowNumber: 42,
            ownerPID: 10,
            bounds: CGRect(x: 800, y: 700, width: 120, height: 80),
            title: "Stale CG title",
            isOnScreen: false
        )

        let state = WindowProjection.project(
            candidates: [minimized],
            cgWindows: [offScreen],
            displays: [display],
            selfPID: 999
        )

        #expect(state.itemsByDisplay["main"]?.count == 1)
        let item = state.itemsByDisplay["main"]?.first
        #expect(item?.id == "minimized")
        #expect(item?.cgWindowNumber == 42)
        #expect(item?.isMinimized == true)
    }

    @Test("cold-start projection does not promote hidden off-screen records")
    func hiddenWindowRequiresPriorOnScreenEvidence() {
        let frame = CGRect(x: 100, y: 100, width: 500, height: 300)
        let display = DisplayDescriptor(
            identifier: "main",
            frame: CGRect(x: 0, y: 0, width: 1_440, height: 900)
        )
        let hidden = WindowCandidate(
            stableKey: "hidden",
            cgWindowNumber: 43,
            pid: 10,
            applicationName: "Editor",
            applicationIsHidden: true,
            title: "Document",
            frame: frame
        )
        let offScreen = CGWindowMetadata(
            windowNumber: 43,
            ownerPID: 10,
            bounds: frame,
            title: "Document",
            isOnScreen: false
        )

        let state = WindowProjection.project(
            candidates: [hidden],
            cgWindows: [offScreen],
            displays: [display],
            selfPID: 999
        )

        #expect(state.itemsByDisplay.isEmpty)
    }

    @Test("off-screen projection never guesses a minimized window identity")
    func minimizedWindowWithoutIdentityStaysExcluded() {
        let frame = CGRect(x: 100, y: 100, width: 500, height: 300)
        let display = DisplayDescriptor(
            identifier: "main",
            frame: CGRect(x: 0, y: 0, width: 1_440, height: 900)
        )
        let ambiguous = WindowCandidate(
            stableKey: "ambiguous",
            pid: 10,
            applicationName: "Terminal",
            title: "Tab",
            frame: frame,
            isMinimized: true
        )
        let offScreen = CGWindowMetadata(
            windowNumber: 42,
            ownerPID: 10,
            bounds: frame,
            title: "Tab",
            isOnScreen: false
        )

        let state = WindowProjection.project(
            candidates: [ambiguous],
            cgWindows: [offScreen],
            displays: [display],
            selfPID: 999
        )

        #expect(state.itemsByDisplay.isEmpty)
    }

    @Test("exact identity does not admit a non-minimized window from another Space")
    func offSpaceWindowStaysExcluded() {
        let frame = CGRect(x: 100, y: 100, width: 500, height: 300)
        let display = DisplayDescriptor(
            identifier: "main",
            frame: CGRect(x: 0, y: 0, width: 1_440, height: 900)
        )
        let offSpace = WindowCandidate(
            stableKey: "other-space",
            cgWindowNumber: 42,
            pid: 10,
            applicationName: "Editor",
            title: "Document",
            frame: frame
        )
        let offScreen = CGWindowMetadata(
            windowNumber: 42,
            ownerPID: 10,
            bounds: frame,
            title: "Document",
            isOnScreen: false
        )

        let state = WindowProjection.project(
            candidates: [offSpace],
            cgWindows: [offScreen],
            displays: [display],
            selfPID: 999
        )

        #expect(state.itemsByDisplay.isEmpty)
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

        let overlappingA = DisplayDescriptor(
            identifier: "a", frame: CGRect(x: 0, y: 0, width: 600, height: 500))
        let overlappingB = DisplayDescriptor(
            identifier: "b", frame: CGRect(x: 400, y: 0, width: 600, height: 500))
        #expect(
            DisplayMapper.identifier(
                for: CGRect(x: 350, y: 100, width: 300, height: 200),
                displays: [overlappingB, overlappingA]
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

    @Test("panel placement respects bottom and side Docks")
    func panelPlacementUsesVisibleFrame() {
        let bottomDock = DisplayDescriptor(
            identifier: "main",
            frame: CGRect(x: 0, y: 0, width: 1_440, height: 900),
            appKitFrame: CGRect(x: 0, y: 0, width: 1_440, height: 900),
            appKitVisibleFrame: CGRect(x: 0, y: 70, width: 1_440, height: 830)
        )
        let sideDock = DisplayDescriptor(
            identifier: "side",
            frame: CGRect(x: 1_440, y: 0, width: 1_440, height: 900),
            appKitFrame: CGRect(x: 1_440, y: 0, width: 1_440, height: 900),
            appKitVisibleFrame: CGRect(x: 1_520, y: 0, width: 1_360, height: 900)
        )
        let rightDock = DisplayDescriptor(
            identifier: "right",
            frame: CGRect(x: 1_440, y: 0, width: 1_440, height: 900),
            appKitFrame: CGRect(x: 1_440, y: 0, width: 1_440, height: 900),
            appKitVisibleFrame: CGRect(x: 1_440, y: 0, width: 1_360, height: 900)
        )

        let bottomFrame = TaskbarPanelLayout.frame(for: bottomDock)
        let sideFrame = TaskbarPanelLayout.frame(for: sideDock)
        let rightFrame = TaskbarPanelLayout.frame(for: rightDock)

        #expect(bottomFrame.minY == 70)
        #expect(bottomFrame.height == TaskbarAppearance.panelHeight)
        #expect(sideFrame.minY == 0)
        #expect(sideFrame.minX == 1_520)
        #expect(sideFrame.width == 1_360)
        #expect(rightFrame.minY == 0)
        #expect(rightFrame.minX == 1_440)
        #expect(rightFrame.width == 1_360)
    }

    @Test("panel placement stays bounded on tiny and negative-origin displays")
    func panelPlacementHandlesTinyAndNegativeDisplays() {
        let tiny = DisplayDescriptor(
            identifier: "tiny",
            frame: CGRect(x: -100, y: 20, width: 50, height: 30),
            appKitFrame: CGRect(x: -100, y: 20, width: 50, height: 30),
            appKitVisibleFrame: CGRect(x: -100, y: 20, width: 50, height: 30)
        )
        let frame = TaskbarPanelLayout.frame(for: tiny)
        #expect(frame.minX >= tiny.appKitFrame.minX)
        #expect(frame.maxX <= tiny.appKitFrame.maxX)
        #expect(frame.minY >= tiny.appKitFrame.minY)
        #expect(frame.maxY <= tiny.appKitFrame.maxY)

        let negative = DisplayDescriptor(
            identifier: "negative",
            frame: CGRect(x: -1_920, y: -100, width: 1_920, height: 1_080)
        )
        let negativeFrame = TaskbarPanelLayout.frame(for: negative)
        #expect(negativeFrame.minX == -1_920)
        #expect(negativeFrame.minY == -100)
    }

    @Test("fullscreen windows suppress only their own display taskbar")
    func fullscreenWindowsIdentifyTheirDisplay() {
        let left = DisplayDescriptor(
            identifier: "left",
            frame: CGRect(x: 0, y: 0, width: 1_440, height: 900))
        let right = DisplayDescriptor(
            identifier: "right",
            frame: CGRect(x: 1_440, y: 0, width: 1_920, height: 1_080))
        let fullscreen = WindowCandidate(
            stableKey: "fullscreen",
            pid: 10,
            applicationName: "Video",
            title: "Fullscreen",
            frame: CGRect(x: 1_440, y: 120, width: 1_920, height: 960),
            isFullscreen: true,
            isFocused: true,
            isMain: true)
        let ordinary = WindowCandidate(
            stableKey: "ordinary",
            pid: 20,
            applicationName: "Editor",
            title: "Document",
            frame: CGRect(x: 100, y: 100, width: 900, height: 700))

        let state = WindowProjection.project(
            candidates: [fullscreen, ordinary],
            cgWindows: [
                CGWindowMetadata(
                    windowNumber: 10,
                    ownerPID: 10,
                    bounds: fullscreen.frame!,
                    title: fullscreen.title),
                CGWindowMetadata(
                    windowNumber: 20,
                    ownerPID: 20,
                    bounds: ordinary.frame!,
                    title: ordinary.title),
            ],
            displays: [left, right],
            selfPID: 99,
            frontmostPID: 10)

        #expect(state.fullscreenDisplayIdentifiers == ["right"])
    }

    @Test("full-display geometry remains a fullscreen fallback")
    func fullscreenGeometryFallbackIdentifiesDisplay() {
        let display = DisplayDescriptor(
            identifier: "main",
            frame: CGRect(x: 0, y: 0, width: 1_440, height: 900))
        let candidate = WindowCandidate(
            stableKey: "borderless-fullscreen",
            pid: 10,
            applicationName: "Player",
            title: "Video",
            frame: display.frame)

        let state = WindowProjection.project(
            candidates: [candidate],
            cgWindows: [
                CGWindowMetadata(
                    windowNumber: 10,
                    ownerPID: 10,
                    bounds: display.frame,
                    title: candidate.title)
            ],
            displays: [display],
            selfPID: 99)

        #expect(state.fullscreenDisplayIdentifiers == ["main"])
    }

    @Test("hidden and minimized fullscreen windows do not suppress taskbars")
    func inactiveFullscreenWindowsDoNotSuppressTaskbars() {
        let display = DisplayDescriptor(
            identifier: "main",
            frame: CGRect(x: 0, y: 0, width: 1_440, height: 900))
        let hidden = WindowCandidate(
            stableKey: "hidden",
            cgWindowNumber: 10,
            pid: 10,
            applicationName: "Hidden",
            applicationIsHidden: true,
            title: "Hidden Fullscreen",
            frame: display.frame)
        let minimized = WindowCandidate(
            stableKey: "minimized",
            cgWindowNumber: 20,
            pid: 20,
            applicationName: "Minimized",
            title: "Minimized Fullscreen",
            frame: display.frame,
            isMinimized: true)

        let state = WindowProjection.project(
            candidates: [hidden, minimized],
            cgWindows: [
                CGWindowMetadata(
                    windowNumber: 10,
                    ownerPID: 10,
                    bounds: display.frame,
                    title: hidden.title,
                    isOnScreen: false),
                CGWindowMetadata(
                    windowNumber: 20,
                    ownerPID: 20,
                    bounds: display.frame,
                    title: minimized.title,
                    isOnScreen: false),
            ],
            displays: [display],
            selfPID: 99)

        #expect(state.fullscreenDisplayIdentifiers.isEmpty)
    }

    @Test("ordering stays stable when the active window changes")
    func stableOrdering() {
        let items = [
            TaskbarItem(
                id: "z", pid: 1, applicationName: "Beta", title: "A", displayIdentifier: "main",
                cgWindowNumber: nil, isActive: true),
            TaskbarItem(
                id: "b", pid: 2, applicationName: "Alpha", title: "Z", displayIdentifier: "main",
                cgWindowNumber: nil, isActive: false),
            TaskbarItem(
                id: "a", pid: 3, applicationName: "Alpha", title: "A", displayIdentifier: "main",
                cgWindowNumber: nil, isActive: false),
        ]

        #expect(WindowOrdering.sorted(items).map(\.id) == ["a", "b", "z"])
    }

    @Test("numbered windows retain creation-style order instead of lexical order")
    func numberedWindowOrdering() {
        let items = [
            TaskbarItem(
                id: "window-10", pid: 10, applicationName: "App 10", title: "Window 10",
                displayIdentifier: "main", cgWindowNumber: 10, isActive: true),
            TaskbarItem(
                id: "window-2", pid: 2, applicationName: "App 2", title: "Window 2",
                displayIdentifier: "main", cgWindowNumber: 2, isActive: false),
            TaskbarItem(
                id: "window-1", pid: 1, applicationName: "App 1", title: "Window 1",
                displayIdentifier: "main", cgWindowNumber: 1, isActive: false),
        ]

        #expect(WindowOrdering.sorted(items).map(\.id) == ["window-1", "window-2", "window-10"])
    }

    @Test("numbered and unnumbered windows use one total stable order")
    func mixedWindowNumberOrdering() {
        let items = [
            TaskbarItem(
                id: "numbered-2", pid: 2, applicationName: "Alpha", title: "Two",
                displayIdentifier: "main", cgWindowNumber: 2, isActive: false),
            TaskbarItem(
                id: "unnumbered", pid: 3, applicationName: "Beta", title: "Unknown",
                displayIdentifier: "main", cgWindowNumber: nil, isActive: true),
            TaskbarItem(
                id: "numbered-1", pid: 1, applicationName: "Zulu", title: "One",
                displayIdentifier: "main", cgWindowNumber: 1, isActive: false),
        ]

        #expect(
            WindowOrdering.sorted(items).map(\.id)
                == ["numbered-1", "numbered-2", "unnumbered"])
    }

    @Test("minimize and restore preserve stable item identity and order")
    func minimizedWindowIdentityAndOrder() {
        let display = DisplayDescriptor(
            identifier: "main",
            frame: CGRect(x: 0, y: 0, width: 1_200, height: 800)
        )
        let firstFrame = CGRect(x: 50, y: 50, width: 400, height: 300)
        let secondFrame = CGRect(x: 500, y: 50, width: 400, height: 300)

        func candidate(
            key: String,
            pid: Int32,
            title: String,
            frame: CGRect,
            minimized: Bool = false
        ) -> WindowCandidate {
            WindowCandidate(
                stableKey: key,
                pid: pid,
                applicationName: title,
                title: title,
                frame: frame,
                isMinimized: minimized,
                isFocused: !minimized && key == "stable-first",
                isMain: !minimized && key == "stable-first"
            )
        }

        let initialCandidates = [
            candidate(key: "stable-first", pid: 10, title: "First", frame: firstFrame),
            candidate(key: "stable-second", pid: 11, title: "Second", frame: secondFrame),
        ]
        let initialCGWindows = [
            CGWindowMetadata(windowNumber: 10, ownerPID: 10, bounds: firstFrame),
            CGWindowMetadata(windowNumber: 11, ownerPID: 11, bounds: secondFrame),
        ]
        let initial = WindowProjection.project(
            candidates: initialCandidates,
            cgWindows: initialCGWindows,
            displays: [display],
            selfPID: 999,
            frontmostPID: 10
        )

        let minimizedCandidates = [
            candidate(
                key: "stable-first", pid: 10, title: "First", frame: firstFrame,
                minimized: true),
            initialCandidates[1],
        ]
        let minimizedProjection = WindowProjection.project(
            candidates: minimizedCandidates,
            cgWindows: [initialCGWindows[1]],
            displays: [display],
            selfPID: 999,
            frontmostPID: 11
        )
        let minimized = TaskbarStateContinuity().resolve(
            previous: initial,
            incoming: minimizedProjection,
            snapshot: RawWindowSnapshot(
                candidates: minimizedCandidates,
                cgWindows: [initialCGWindows[1]],
                displays: [display],
                frontmostPID: 11,
                evidence: WindowSnapshotEvidence(
                    isComplete: true,
                    knownApplicationPIDs: [10, 11],
                    axWindowListReadPIDs: [10, 11],
                    observedAXWindowIDs: ["stable-first", "stable-second"]
                )
            )
        )
        let restored = WindowProjection.project(
            candidates: initialCandidates,
            cgWindows: initialCGWindows,
            displays: [display],
            selfPID: 999,
            frontmostPID: 10
        )

        #expect(initial.itemsByDisplay["main"]?.map(\.id) == ["stable-first", "stable-second"])
        #expect(minimized.itemsByDisplay["main"]?.map(\.id) == ["stable-first", "stable-second"])
        #expect(minimized.itemsByDisplay["main"]?.first?.isMinimized == true)
        #expect(restored.itemsByDisplay["main"]?.map(\.id) == ["stable-first", "stable-second"])
    }

    @Test("only the frontmost application can provide an active item")
    func activeStateRequiresFrontmostApplication() {
        let alpha = WindowCandidate(
            stableKey: "alpha",
            pid: 10,
            applicationName: "Alpha",
            title: "Alpha window",
            frame: CGRect(x: 0, y: 0, width: 400, height: 300),
            isMain: true
        )
        let beta = WindowCandidate(
            stableKey: "beta",
            pid: 20,
            applicationName: "Beta",
            title: "Beta window",
            frame: CGRect(x: 500, y: 0, width: 400, height: 300),
            isMain: true
        )
        let displays = [
            DisplayDescriptor(
                identifier: "main",
                frame: CGRect(x: 0, y: 0, width: 1_000, height: 600)
            )
        ]
        let cgWindows = [
            CGWindowMetadata(ownerPID: 10, bounds: alpha.frame!),
            CGWindowMetadata(ownerPID: 20, bounds: beta.frame!),
        ]

        let frontmost = WindowProjection.project(
            candidates: [alpha, beta],
            cgWindows: cgWindows,
            displays: displays,
            selfPID: 999,
            frontmostPID: 20
        ).itemsByDisplay["main"]!
        #expect(frontmost.map(\.pid) == [10, 20])
        #expect(frontmost.map(\.isActive) == [false, true])

        let noFrontmost = WindowProjection.project(
            candidates: [alpha, beta],
            cgWindows: cgWindows,
            displays: displays,
            selfPID: 999,
            frontmostPID: nil
        ).itemsByDisplay["main"]!
        #expect(noFrontmost.allSatisfy { !$0.isActive })
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

    @Test("one CG window is consumed by only one AX candidate")
    func oneToOneWindowMatching() {
        let frame = CGRect(x: 100, y: 100, width: 500, height: 300)
        let candidates = [
            WindowCandidate(pid: 10, applicationName: "Editor", title: "Same", frame: frame),
            WindowCandidate(pid: 10, applicationName: "Editor", title: "Same", frame: frame),
        ]
        let display = DisplayDescriptor(
            identifier: "main", frame: CGRect(x: 0, y: 0, width: 1_000, height: 700))
        let oneWindow = CGWindowMetadata(
            windowNumber: 10, ownerPID: 10, bounds: frame, title: "Same")
        let twoWindows = [
            CGWindowMetadata(windowNumber: 20, ownerPID: 10, bounds: frame, title: "Same"),
            oneWindow,
        ]

        let collapsed = WindowProjection.project(
            candidates: candidates,
            cgWindows: [oneWindow],
            displays: [display],
            selfPID: 999
        )
        #expect(collapsed.itemsByDisplay["main"]?.count == 1)

        let assignments = WindowCGAssignment.assign(
            candidates: candidates,
            cgWindows: twoWindows,
            selfPID: 999
        )
        #expect(assignments.count == 2)
        #expect(assignments[0] != assignments[1])

        let distinct = WindowProjection.project(
            candidates: Array(candidates.reversed()),
            cgWindows: twoWindows,
            displays: [display],
            selfPID: 999
        )
        #expect(distinct.itemsByDisplay["main"]?.map(\.cgWindowNumber) == [10, 20])
    }

    @Test("activation and observer keys stay unique for consumed CG windows")
    func activationKeysFollowOneToOneAssignments() {
        let frame = CGRect(x: 100, y: 100, width: 500, height: 300)
        let candidates = [
            WindowCandidate(pid: 10, applicationName: "Editor", title: "Same", frame: frame),
            WindowCandidate(pid: 10, applicationName: "Editor", title: "Same", frame: frame),
        ]
        let cgWindows = [
            CGWindowMetadata(windowNumber: 20, ownerPID: 10, bounds: frame, title: "Same"),
            CGWindowMetadata(windowNumber: 10, ownerPID: 10, bounds: frame, title: "Same"),
        ]
        let assignments = WindowCGAssignment.assign(
            candidates: candidates,
            cgWindows: cgWindows,
            selfPID: 999
        )

        let activationKeys = candidates.indices.compactMap { index -> String? in
            guard let cgIndex = assignments[index] else { return nil }
            return WindowObservationKey.itemKey(
                candidate: candidates[index],
                cgWindow: cgWindows[cgIndex]
            )
        }
        let observerKeys = candidates.indices.compactMap { index -> String? in
            let cgWindow = assignments[index].map { cgWindows[$0] }
            return WindowObservationKey.observerKey(
                candidate: candidates[index],
                cgWindow: cgWindow,
                ordinal: index
            )
        }

        #expect(activationKeys.count == 2)
        #expect(Set(activationKeys).count == 2)
        #expect(Set(observerKeys).count == 2)
        #expect(activationKeys.allSatisfy { $0.hasPrefix("cg:10:") })
        #expect(observerKeys.allSatisfy { $0.hasPrefix("cg-observer:10:") })
    }

    @Test("projection is deterministic under input permutation")
    func projectionPermutationIsStable() {
        let displays = [
            DisplayDescriptor(
                identifier: "b", frame: CGRect(x: 500, y: 0, width: 500, height: 600)),
            DisplayDescriptor(identifier: "a", frame: CGRect(x: 0, y: 0, width: 500, height: 600)),
        ]
        let candidates = (0..<6).map { index in
            WindowCandidate(
                pid: Int32(index + 1),
                applicationName: index.isMultiple(of: 2) ? "Alpha" : "Beta",
                title: "Title \(index)",
                frame: CGRect(
                    x: index < 3 ? 40 : 540,
                    y: 80 + CGFloat(index) * 40,
                    width: 220,
                    height: 160
                )
            )
        }
        let cgWindows = candidates.enumerated().map { index, candidate in
            CGWindowMetadata(
                windowNumber: UInt32(100 + index),
                ownerPID: candidate.pid,
                bounds: candidate.frame!,
                title: candidate.title
            )
        }

        let first = WindowProjection.project(
            candidates: candidates,
            cgWindows: cgWindows,
            displays: displays,
            selfPID: 999,
            frontmostPID: 3
        )
        let second = WindowProjection.project(
            candidates: Array(candidates.reversed()),
            cgWindows: Array(cgWindows.reversed()),
            displays: Array(displays.reversed()),
            selfPID: 999,
            frontmostPID: 3
        )
        #expect(first == second)
    }

    @Test("empty displays and long Unicode titles remain safe")
    func emptyDisplaysAndUnicode() {
        let candidate = WindowCandidate(
            pid: 10,
            applicationName: "Éditeur",
            applicationIdentity: "com.example.editor",
            title: "Résumé — 文書 🚀 — Пример",
            frame: CGRect(x: 0, y: 0, width: 400, height: 300)
        )
        let cg = CGWindowMetadata(
            windowNumber: 1, ownerPID: 10, bounds: candidate.frame!, title: candidate.title)
        let empty = WindowProjection.project(
            candidates: [candidate], cgWindows: [cg], displays: [], selfPID: 999)
        #expect(empty == .empty)

        let item = WindowProjection.project(
            candidates: [candidate],
            cgWindows: [cg],
            displays: [
                DisplayDescriptor(
                    identifier: "main", frame: CGRect(x: 0, y: 0, width: 800, height: 600))
            ],
            selfPID: 999
        ).itemsByDisplay["main"]!.first!
        #expect(item.accessibilityLabel.contains(candidate.title))
        #expect(item.tooltip.contains(candidate.title))
        #expect(item.applicationIdentity == candidate.applicationIdentity)
    }

    @Test("projection handles 120 windows for overflow")
    func projectionStressOverflow() {
        let display = DisplayDescriptor(
            identifier: "main", frame: CGRect(x: 0, y: 0, width: 4_000, height: 2_000))
        let candidates = (0..<120).map { index in
            let frame = CGRect(
                x: 20 + CGFloat(index % 20) * 180,
                y: 40 + CGFloat(index / 20) * 240,
                width: 160,
                height: 180
            )
            return WindowCandidate(
                pid: Int32(index + 1),
                applicationName: "App \(index)",
                title: "Window \(index)",
                frame: frame,
                isMain: index == 0
            )
        }
        let cgWindows = candidates.enumerated().map { index, candidate in
            CGWindowMetadata(
                windowNumber: UInt32(index + 1),
                ownerPID: candidate.pid,
                bounds: candidate.frame!,
                title: candidate.title
            )
        }

        let state = WindowProjection.project(
            candidates: candidates,
            cgWindows: cgWindows,
            displays: [display],
            selfPID: 999,
            frontmostPID: 1
        )
        #expect(state.itemsByDisplay["main"]?.count == 120)
        #expect(state.itemsByDisplay["main"]?.first?.isActive == true)
    }

    @Test("button sizing is fixed to the balanced range")
    func buttonSizingRange() {
        #expect(TaskbarButtonLayout.minimumWidth == 102)
        #expect(TaskbarButtonLayout.preferredWidth == 168)
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
