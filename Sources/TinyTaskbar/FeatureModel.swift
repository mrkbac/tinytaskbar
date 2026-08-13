import Foundation

enum ActiveWindowClickBehavior: String, CaseIterable, Codable, Sendable {
    case minimize
    case doNothing
}

enum TaskbarOrderingMode: String, CaseIterable, Codable, Sendable {
    case windowOrder
    case groupByApplication
}

enum TaskbarLabelMode: String, CaseIterable, Codable, Sendable {
    case windowTitle
    case applicationName
    case iconOnly
}

enum TaskbarDensity: String, CaseIterable, Codable, Sendable {
    case standard
    case compact

    var panelHeight: CGFloat { self == .standard ? 30 : 26 }
    var iconSize: CGFloat { self == .standard ? 18 : 16 }
    var buttonHeight: CGFloat { self == .standard ? 27 : 23 }
}

enum TaskbarButtonWidth: String, CaseIterable, Codable, Sendable {
    case narrow
    case balanced
    case wide
}

enum TaskbarOverflowBehavior: String, CaseIterable, Codable, Sendable {
    case shrinkThenScroll
    case automaticIcons
}

enum TaskbarDisplayMode: String, CaseIterable, Codable, Sendable {
    case windowDisplay
    case everyDisplay
    case mainDisplayOnly
}

struct ApplicationRecord: Codable, Equatable, Hashable, Sendable, Identifiable {
    let identity: String
    var bundleIdentifier: String?
    var bundlePath: String?
    var localizedName: String
    var sequence: Int

    var id: String { identity }

    var isValid: Bool {
        !identity.isEmpty && !localizedName.isEmpty
            && (bundleIdentifier?.isEmpty == false || bundlePath?.isEmpty == false)
    }
}

enum TaskbarPresentationEntry: Equatable, Sendable, Identifiable {
    case window(TaskbarItem)
    case launcher(ApplicationRecord)
    case separator(String)

    var id: String {
        switch self {
        case .window(let item): item.id
        case .launcher(let application): "launcher:\(application.identity)"
        case .separator(let id): "separator:\(id)"
        }
    }
}

struct TaskbarPresentationState: Equatable, Sendable {
    let displays: [DisplayDescriptor]
    let entriesByDisplay: [String: [TaskbarPresentationEntry]]

    static let empty = TaskbarPresentationState(displays: [], entriesByDisplay: [:])
}

enum TaskbarPresentationBuilder {
    static func build(
        state: TaskbarState,
        preferences: TinyTaskbarPreferences
    ) -> TaskbarPresentationState {
        let excluded = Set(preferences.excludedApplications.map(\.identity))
        let pins = preferences.pinnedApplications
            .filter(\.isValid)
            .sorted { lhs, rhs in
                if lhs.sequence != rhs.sequence { return lhs.sequence < rhs.sequence }
                return lhs.identity < rhs.identity
            }
        let pinnedIdentities = Set(pins.map(\.identity))
        var entriesByDisplay: [String: [TaskbarPresentationEntry]] = [:]

        let presentationDisplays: [DisplayDescriptor]
        switch preferences.displayMode {
        case .windowDisplay, .everyDisplay:
            presentationDisplays = state.displays
        case .mainDisplayOnly:
            presentationDisplays =
                state.displays.first(where: \.isMain)
                .map { [$0] }
                ?? state.displays.min(by: { $0.ordinal < $1.ordinal }).map { [$0] }
                ?? []
        }
        let allItems = Array(state.itemsByDisplay.values.joined())

        for display in presentationDisplays {
            let displayItems =
                preferences.displayMode == .windowDisplay
                ? (state.itemsByDisplay[display.identifier] ?? [])
                : allItems
            let eligible = displayItems.filter { item in
                guard let identity = item.applicationIdentity else { return true }
                return !excluded.contains(identity)
            }
            var pinnedEntries: [TaskbarPresentationEntry] = []
            for pin in pins {
                let windows = eligible.filter { $0.applicationIdentity == pin.identity }
                if windows.isEmpty {
                    pinnedEntries.append(.launcher(pin))
                } else {
                    pinnedEntries.append(
                        contentsOf: ordered(windows, mode: preferences.orderingMode).map(
                            TaskbarPresentationEntry.window))
                }
            }
            let remaining = eligible.filter { item in
                guard let identity = item.applicationIdentity else { return true }
                return !pinnedIdentities.contains(identity)
            }
            var entries = pinnedEntries
            let orderedRemaining = ordered(remaining, mode: preferences.orderingMode)
            let hasPinnedWindows = pinnedEntries.contains { entry in
                if case .window = entry { return true }
                return false
            }
            if hasPinnedWindows && !orderedRemaining.isEmpty {
                entries.append(.separator(display.identifier))
            }
            entries.append(contentsOf: orderedRemaining.map(TaskbarPresentationEntry.window))
            entriesByDisplay[display.identifier] = entries
        }
        return TaskbarPresentationState(
            displays: presentationDisplays, entriesByDisplay: entriesByDisplay)
    }

    private static func ordered(
        _ items: [TaskbarItem],
        mode: TaskbarOrderingMode
    ) -> [TaskbarItem] {
        let stable = WindowOrdering.sorted(items)
        guard mode == .groupByApplication else { return stable }
        var groups: [String: [TaskbarItem]] = [:]
        var identities: [String] = []
        for item in stable {
            let identity = item.applicationIdentity ?? "pid:\(item.pid)"
            if groups[identity] == nil { identities.append(identity) }
            groups[identity, default: []].append(item)
        }
        return identities.flatMap { groups[$0] ?? [] }
    }
}

enum WindowCommand: Equatable, Sendable {
    case activate(TaskbarItem)
    case minimize(TaskbarItem)
    case minimizeAll
    case restore(TaskbarItem)
    case selectTab(TaskbarItem, TaskbarTab)
    case closeTab(TaskbarItem, TaskbarTab)
    case closeTabGroup(TaskbarItem)
    case close(TaskbarItem)
    case minimizeOthers(TaskbarItem)
}

enum ApplicationCommand: Equatable, Sendable {
    case launch(ApplicationRecord)
    case pin(ApplicationRecord)
    case unpin(String)
    case exclude(ApplicationRecord)
    case restoreFromExclusions(String)
}

enum GlobalCommand: Equatable, Sendable {
    case setTaskbarsVisible(Bool)
    case showSettings
    case quit
}
