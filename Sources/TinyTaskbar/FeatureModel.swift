import Foundation

enum TaskbarAppearance {
    static let panelHeight: CGFloat = 30
    static let iconSize: CGFloat = 18
    static let buttonHeight: CGFloat = 28
}

struct TaskbarPresentationState: Equatable, Sendable {
    let displays: [DisplayDescriptor]
    let itemsByDisplay: [String: [TaskbarItem]]

    static let empty = TaskbarPresentationState(displays: [], itemsByDisplay: [:])
}

enum TaskbarPresentationBuilder {
    static func build(state: TaskbarState) -> TaskbarPresentationState {
        var itemsByDisplay: [String: [TaskbarItem]] = [:]
        for display in state.displays {
            itemsByDisplay[display.identifier] = WindowOrdering.sorted(
                state.itemsByDisplay[display.identifier] ?? [])
        }
        return TaskbarPresentationState(
            displays: state.displays, itemsByDisplay: itemsByDisplay)
    }
}

enum WindowCommand: Equatable, Sendable {
    case activate(TaskbarItem)
    case minimize(TaskbarItem)
    case minimizeAll
    case restore(TaskbarItem)
    case setFullscreen(TaskbarItem, Bool)
    case selectTab(TaskbarItem, TaskbarTab)
    case closeTab(TaskbarItem, TaskbarTab)
    case closeTabGroup(TaskbarItem)
    case close(TaskbarItem)
}

enum MinimizeAllTargets {
    static func resolve(in state: TaskbarState) -> [TaskbarItem] {
        WindowOrdering.sorted(Array(state.itemsByDisplay.values.joined())).filter {
            !$0.isMinimized && !$0.isHidden
        }
    }
}

struct WindowFullscreenCapability: Equatable, Sendable {
    let isFullscreen: Bool
    let isSettable: Bool
}

struct ApplicationMenuCommand: Equatable, Sendable {
    let title: String
    let commandCharacter: String
    let commandModifiers: UInt32
}

enum ApplicationCommand: Equatable, Sendable {
    case performMenuCommand(TaskbarItem, ApplicationMenuCommand)
}
