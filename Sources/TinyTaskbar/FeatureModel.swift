import Foundation

enum TaskbarAppearance {
    static let panelHeight: CGFloat = 30
    static let iconSize: CGFloat = 18
    static let buttonHeight: CGFloat = 27
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
    case restore(TaskbarItem)
    case selectTab(TaskbarItem, TaskbarTab)
    case closeTab(TaskbarItem, TaskbarTab)
    case closeTabGroup(TaskbarItem)
    case close(TaskbarItem)
}
