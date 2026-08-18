import CoreFoundation
import Foundation

enum DockPreferenceValue: Codable, Equatable {
    case boolean(Bool)
    case integer(Int)
    case double(Double)
    case string(String)
}

struct DockPreferencesSnapshot: Codable, Equatable {
    let autohide: DockPreferenceValue?
    let autohideDelay: DockPreferenceValue?
    let autohideTimeModifier: DockPreferenceValue?
    let orientation: DockPreferenceValue?
    let noBouncing: DockPreferenceValue?
}

@MainActor
protocol DockPreferencesAccess: AnyObject {
    func value(forKey key: String) -> DockPreferenceValue?
    func setValue(_ value: DockPreferenceValue?, forKey key: String)
    func synchronize() throws
    func restartDock() throws
}

@MainActor
protocol DockVisibilityManaging: AnyObject {
    func setHidden(_ hidden: Bool) throws
}

enum DockVisibilityError: LocalizedError {
    case couldNotSaveBackup
    case couldNotReadBackup
    case couldNotSynchronize
    case couldNotRestart(Int32)

    var errorDescription: String? {
        switch self {
        case .couldNotSaveBackup:
            "Could not save the current Dock settings."
        case .couldNotReadBackup:
            "The saved Dock settings could not be read, so TinyTaskbar left the Dock unchanged."
        case .couldNotSynchronize:
            "macOS did not accept the updated Dock settings."
        case .couldNotRestart(let status):
            "The Dock could not be restarted (status \(status))."
        }
    }
}

@MainActor
final class DockVisibilityController: DockVisibilityManaging {
    static let hiddenRevealDelay = 86_400.0

    private static let autohideKey = "autohide"
    private static let autohideDelayKey = "autohide-delay"
    private static let autohideTimeModifierKey = "autohide-time-modifier"
    private static let orientationKey = "orientation"
    private static let noBouncingKey = "no-bouncing"
    private static let backupKey = "dockVisibility.originalPreferences.v1"

    private let preferences: any DockPreferencesAccess
    private let defaults: UserDefaults

    init(
        preferences: any DockPreferencesAccess = SystemDockPreferencesAccess(),
        defaults: UserDefaults = .standard
    ) {
        self.preferences = preferences
        self.defaults = defaults
    }

    func setHidden(_ hidden: Bool) throws {
        if hidden {
            try hideDock()
        } else {
            try restoreDock()
        }
    }

    private func hideDock() throws {
        if try savedSnapshot() == nil {
            let snapshot = currentSnapshot()
            guard let encoded = try? JSONEncoder().encode(snapshot) else {
                throw DockVisibilityError.couldNotSaveBackup
            }
            defaults.set(encoded, forKey: Self.backupKey)
            guard defaults.synchronize() else {
                throw DockVisibilityError.couldNotSaveBackup
            }
        }

        preferences.setValue(.boolean(true), forKey: Self.autohideKey)
        preferences.setValue(.double(Self.hiddenRevealDelay), forKey: Self.autohideDelayKey)
        preferences.setValue(.double(0), forKey: Self.autohideTimeModifierKey)
        preferences.setValue(.string("left"), forKey: Self.orientationKey)
        preferences.setValue(.boolean(true), forKey: Self.noBouncingKey)
        try preferences.synchronize()
        try preferences.restartDock()
    }

    private func restoreDock() throws {
        guard let snapshot = try savedSnapshot() else { return }
        preferences.setValue(snapshot.autohide, forKey: Self.autohideKey)
        preferences.setValue(snapshot.autohideDelay, forKey: Self.autohideDelayKey)
        preferences.setValue(
            snapshot.autohideTimeModifier,
            forKey: Self.autohideTimeModifierKey)
        preferences.setValue(snapshot.orientation, forKey: Self.orientationKey)
        preferences.setValue(snapshot.noBouncing, forKey: Self.noBouncingKey)
        try preferences.synchronize()
        try preferences.restartDock()
        defaults.removeObject(forKey: Self.backupKey)
        _ = defaults.synchronize()
    }

    private func currentSnapshot() -> DockPreferencesSnapshot {
        DockPreferencesSnapshot(
            autohide: preferences.value(forKey: Self.autohideKey),
            autohideDelay: preferences.value(forKey: Self.autohideDelayKey),
            autohideTimeModifier: preferences.value(forKey: Self.autohideTimeModifierKey),
            orientation: preferences.value(forKey: Self.orientationKey),
            noBouncing: preferences.value(forKey: Self.noBouncingKey))
    }

    private func savedSnapshot() throws -> DockPreferencesSnapshot? {
        guard let data = defaults.data(forKey: Self.backupKey) else { return nil }
        guard let snapshot = try? JSONDecoder().decode(DockPreferencesSnapshot.self, from: data)
        else { throw DockVisibilityError.couldNotReadBackup }
        return snapshot
    }
}

@MainActor
final class SystemDockPreferencesAccess: DockPreferencesAccess {
    private let applicationID = "com.apple.dock" as CFString

    func value(forKey key: String) -> DockPreferenceValue? {
        guard
            let value = CFPreferencesCopyValue(
                key as CFString,
                applicationID,
                kCFPreferencesCurrentUser,
                kCFPreferencesAnyHost)
        else { return nil }

        if CFGetTypeID(value) == CFBooleanGetTypeID(), let boolean = value as? Bool {
            return .boolean(boolean)
        }
        if CFGetTypeID(value) == CFNumberGetTypeID(), let number = value as? NSNumber {
            let type = String(cString: number.objCType)
            return ["f", "d"].contains(type)
                ? .double(number.doubleValue)
                : .integer(number.intValue)
        }
        if CFGetTypeID(value) == CFStringGetTypeID(), let string = value as? String {
            return .string(string)
        }
        return nil
    }

    func setValue(_ value: DockPreferenceValue?, forKey key: String) {
        CFPreferencesSetValue(
            key as CFString,
            value?.propertyListValue,
            applicationID,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost)
    }

    func synchronize() throws {
        guard
            CFPreferencesSynchronize(
                applicationID,
                kCFPreferencesCurrentUser,
                kCFPreferencesAnyHost)
        else { throw DockVisibilityError.couldNotSynchronize }
    }

    func restartDock() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        process.arguments = ["Dock"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 || process.terminationStatus == 1 else {
            throw DockVisibilityError.couldNotRestart(process.terminationStatus)
        }
    }
}

extension DockPreferenceValue {
    fileprivate var propertyListValue: CFPropertyList {
        switch self {
        case .boolean(let value):
            NSNumber(value: value)
        case .integer(let value):
            NSNumber(value: value)
        case .double(let value):
            NSNumber(value: value)
        case .string(let value):
            NSString(string: value)
        }
    }
}

@MainActor
final class NoopDockVisibilityManager: DockVisibilityManaging {
    func setHidden(_: Bool) throws {}
}
