import AppKit
import ApplicationServices
import Darwin
import Foundation
import OSLog

struct ApplicationIndicatorSnapshot: Equatable, Sendable {
    var attentionPIDs: Set<pid_t> = []
    var badgesByApplicationIdentity: [String: String] = [:]

    static let empty = ApplicationIndicatorSnapshot()
}

struct LaunchServicesAttentionEvent: Equatable, Sendable {
    let applicationSerialNumber: String
    let wantsAttention: Bool
}

enum LaunchServicesAttentionEventParser {
    static func parse(_ line: String) -> LaunchServicesAttentionEvent? {
        guard line.contains("kLSNotifyApplicationWantsAttentionChanged"),
            let asn = value(
                after: "\"LSASN\"=", in: line,
                endingAt: { $0 == "," || $0 == " " || $0 == "}" }),
            asn.hasPrefix("ASN:"),
            let rawAttention = value(
                after: "\"LSWantsAttention\"=", in: line,
                endingAt: { $0 == "," || $0 == " " || $0 == "}" })
        else {
            return nil
        }
        switch rawAttention {
        case "true":
            return LaunchServicesAttentionEvent(
                applicationSerialNumber: asn, wantsAttention: true)
        case "false":
            return LaunchServicesAttentionEvent(
                applicationSerialNumber: asn, wantsAttention: false)
        default:
            return nil
        }
    }

    private static func value(
        after marker: String,
        in line: String,
        endingAt isTerminator: (Character) -> Bool
    ) -> String? {
        guard let markerRange = line.range(of: marker) else { return nil }
        let suffix = line[markerRange.upperBound...]
        let end = suffix.firstIndex(where: isTerminator) ?? suffix.endIndex
        let value = suffix[..<end]
        return value.isEmpty ? nil : String(value)
    }
}

enum LaunchServicesApplicationSerialNumberParser {
    static func parse(_ output: String) -> [String] {
        var seen = Set<String>()
        return output.split(whereSeparator: { character in
            character.isWhitespace || character == "," || character == "(" || character == ")"
        }).compactMap { rawToken in
            var token = rawToken.trimmingCharacters(
                in: CharacterSet(charactersIn: "\"'[]{}"))
            if let decoration = token.range(of: "-\"") {
                token = "\(token[..<decoration.lowerBound]):"
            }
            guard token.hasPrefix("ASN:0x"), token.contains("-0x"), token.hasSuffix(":"),
                token.count <= 80, seen.insert(token).inserted
            else { return nil }
            return token
        }
    }
}

struct BoundedUTF8LineBuffer {
    private static let maximumBufferedBytes = 64 * 1024
    private(set) var data = Data()

    mutating func append(_ incoming: Data) -> [String] {
        guard !incoming.isEmpty else { return [] }
        data.append(incoming)
        if data.count > Self.maximumBufferedBytes {
            data = data.suffix(Self.maximumBufferedBytes)
            if let newline = data.firstIndex(of: 0x0A) {
                data.removeSubrange(data.startIndex...newline)
            }
        }

        var lines: [String] = []
        while let newline = data.firstIndex(of: 0x0A) {
            let lineData = data[..<newline]
            data.removeSubrange(data.startIndex...newline)
            if let line = String(data: lineData, encoding: .utf8) {
                lines.append(line)
            }
        }
        return lines
    }
}

struct BoundedAttentionEventQueue {
    let maximumCount: Int
    private(set) var events: [LaunchServicesAttentionEvent] = []

    init(maximumCount: Int = 256) {
        self.maximumCount = max(1, maximumCount)
    }

    var isEmpty: Bool { events.isEmpty }

    mutating func enqueue(_ event: LaunchServicesAttentionEvent) {
        if let existingIndex = events.lastIndex(where: {
            $0.applicationSerialNumber == event.applicationSerialNumber
        }) {
            events[existingIndex] = event
            return
        }
        if events.count >= maximumCount {
            events.removeFirst()
        }
        events.append(event)
    }

    mutating func popFirst() -> LaunchServicesAttentionEvent? {
        guard !events.isEmpty else { return nil }
        return events.removeFirst()
    }

    mutating func removeAll() {
        events.removeAll(keepingCapacity: false)
    }
}

@MainActor
final class SystemApplicationAttentionObserver: @unchecked Sendable {
    nonisolated static let listenerArguments = [
        "-currentSession", "listen", "+wantsAttentionChanged", "wait", "300",
    ]
    nonisolated static let currentAttentionArguments = [
        "-currentSession", "find", "kLSApplicationDesiresAttentionKey=true",
    ]
    private static let restartDelays: [Duration] = [
        .seconds(1), .seconds(5), .seconds(30), .seconds(120), .seconds(300),
    ]

    private let logger = Logger(subsystem: "com.tinytaskbar", category: "attention")
    private var listener: Process?
    private var outputPipe: Pipe?
    private var lineBuffer = BoundedUTF8LineBuffer()
    private var generation = 0
    private var restartAttempt = 0
    private var restartTask: Task<Void, Never>?
    private var seedTask: Task<Void, Never>?
    private var pendingEvents = BoundedAttentionEventQueue()
    private var isResolvingEvent = false
    private var pidByApplicationSerialNumber: [String: pid_t] = [:]
    private var activeAttentionPIDs: Set<pid_t> = []
    private var applicationSerialNumbersUpdatedSinceSeed: Set<String> = []
    private var workspaceToken: NSObjectProtocol?
    private var shouldRun = false
    private var lifecycleGeneration = 0

    var onChange: (@MainActor (Set<pid_t>) -> Void)?

    func start() {
        guard !shouldRun else { return }
        shouldRun = true
        lifecycleGeneration &+= 1
        restartAttempt = 0
        applicationSerialNumbersUpdatedSinceSeed.removeAll()
        observeApplicationTermination()
        launchListener()
        seedCurrentAttentionApplications(generation: lifecycleGeneration)
    }

    func stop() {
        shouldRun = false
        lifecycleGeneration &+= 1
        generation &+= 1
        restartTask?.cancel()
        restartTask = nil
        seedTask?.cancel()
        seedTask = nil
        pendingEvents.removeAll()
        isResolvingEvent = false
        pidByApplicationSerialNumber.removeAll()
        applicationSerialNumbersUpdatedSinceSeed.removeAll()
        if let workspaceToken {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceToken)
            self.workspaceToken = nil
        }
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        if let listener, listener.isRunning {
            listener.terminate()
        }
        listener = nil
        outputPipe = nil
        lineBuffer = BoundedUTF8LineBuffer()
        publish([])
    }

    private func launchListener() {
        guard shouldRun, listener == nil else { return }
        generation &+= 1
        let launchGeneration = generation
        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/lsappinfo")
        process.arguments = Self.listenerArguments
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { @MainActor [weak self] in
                self?.consume(data, generation: launchGeneration)
            }
        }
        process.terminationHandler = { [weak self] process in
            Task { @MainActor [weak self] in
                self?.listenerDidTerminate(
                    generation: launchGeneration,
                    terminationStatus: process.terminationStatus)
            }
        }

        do {
            try process.run()
            listener = process
            outputPipe = pipe
            logger.debug("attention listener started")
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            logger.error("could not start attention listener: \(error.localizedDescription)")
            scheduleRestart(generation: launchGeneration)
        }
    }

    private func consume(_ data: Data, generation: Int) {
        guard shouldRun, generation == self.generation else { return }
        for line in lineBuffer.append(data) {
            if let event = LaunchServicesAttentionEventParser.parse(line) {
                if seedTask != nil {
                    applicationSerialNumbersUpdatedSinceSeed.insert(
                        event.applicationSerialNumber)
                }
                pendingEvents.enqueue(event)
            }
        }
        resolveNextEventIfNeeded(generation: generation)
    }

    private func resolveNextEventIfNeeded(generation: Int) {
        guard shouldRun, generation == self.generation,
            !isResolvingEvent, !pendingEvents.isEmpty
        else { return }
        isResolvingEvent = true
        guard let event = pendingEvents.popFirst() else {
            isResolvingEvent = false
            return
        }
        if let pid = pidByApplicationSerialNumber[event.applicationSerialNumber] {
            apply(event, pid: pid)
            isResolvingEvent = false
            resolveNextEventIfNeeded(generation: generation)
            return
        }

        Task.detached(priority: .utility) { [weak self] in
            let pid = Self.lookupPID(for: event.applicationSerialNumber)
            await MainActor.run { [weak self] in
                guard let self, self.shouldRun, generation == self.generation else { return }
                if let pid {
                    self.pidByApplicationSerialNumber[event.applicationSerialNumber] = pid
                    self.apply(event, pid: pid)
                }
                self.isResolvingEvent = false
                self.resolveNextEventIfNeeded(generation: generation)
            }
        }
    }

    private func apply(_ event: LaunchServicesAttentionEvent, pid: pid_t) {
        if event.wantsAttention {
            activeAttentionPIDs.insert(pid)
        } else {
            activeAttentionPIDs.remove(pid)
            pidByApplicationSerialNumber.removeValue(forKey: event.applicationSerialNumber)
        }
        publish(activeAttentionPIDs)
    }

    private func publish(_ pids: Set<pid_t>) {
        activeAttentionPIDs = pids
        onChange?(pids)
    }

    private func seedCurrentAttentionApplications(generation: Int) {
        seedTask?.cancel()
        seedTask = Task.detached(priority: .utility) { [weak self] in
            let applications = Self.lookupCurrentAttentionApplications()
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self, self.shouldRun, generation == self.lifecycleGeneration else {
                    return
                }
                self.seedTask = nil
                var nextPIDs = self.activeAttentionPIDs
                for (applicationSerialNumber, pid) in applications
                where !self.applicationSerialNumbersUpdatedSinceSeed.contains(
                    applicationSerialNumber)
                {
                    self.pidByApplicationSerialNumber[applicationSerialNumber] = pid
                    nextPIDs.insert(pid)
                }
                self.applicationSerialNumbersUpdatedSinceSeed.removeAll(
                    keepingCapacity: false)
                if nextPIDs != self.activeAttentionPIDs {
                    self.publish(nextPIDs)
                }
            }
        }
    }

    private func listenerDidTerminate(generation: Int, terminationStatus: Int32) {
        guard generation == self.generation else { return }
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        outputPipe = nil
        listener = nil
        guard shouldRun else { return }
        if terminationStatus == 0 {
            restartAttempt = 0
            scheduleRestart(generation: generation, delay: .milliseconds(100))
            return
        }
        logger.notice("attention listener exited; scheduling bounded restart")
        scheduleRestart(generation: generation)
    }

    private func scheduleRestart(generation: Int, delay explicitDelay: Duration? = nil) {
        guard shouldRun, restartTask == nil else { return }
        let index = min(restartAttempt, Self.restartDelays.count - 1)
        let delay = explicitDelay ?? Self.restartDelays[index]
        if explicitDelay == nil {
            restartAttempt += 1
        }
        restartTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, self.shouldRun,
                generation == self.generation
            else { return }
            self.restartTask = nil
            self.launchListener()
        }
    }

    private func observeApplicationTermination() {
        workspaceToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard
                let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication
            else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                let pid = application.processIdentifier
                guard self.activeAttentionPIDs.remove(pid) != nil else { return }
                self.pidByApplicationSerialNumber = self.pidByApplicationSerialNumber.filter {
                    $0.value != pid
                }
                self.onChange?(self.activeAttentionPIDs)
            }
        }
    }

    nonisolated private static func lookupPID(for applicationSerialNumber: String) -> pid_t? {
        guard applicationSerialNumber.hasPrefix("ASN:"),
            applicationSerialNumber.count <= 80
        else { return nil }
        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/lsappinfo")
        process.arguments = [
            "info", "-only", "pid", "-app", applicationSerialNumber,
        ]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8),
            let equals = output.firstIndex(of: "=")
        else { return nil }
        let rawPID = output[output.index(after: equals)...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return pid_t(rawPID)
    }

    nonisolated private static func lookupCurrentAttentionApplications() -> [String: pid_t] {
        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/lsappinfo")
        process.arguments = currentAttentionArguments
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return [:]
        }
        guard process.terminationStatus == 0 else { return [:] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return [:] }
        return Dictionary(
            uniqueKeysWithValues: LaunchServicesApplicationSerialNumberParser.parse(output)
                .compactMap { applicationSerialNumber in
                    lookupPID(for: applicationSerialNumber).map {
                        (applicationSerialNumber, $0)
                    }
                })
    }
}

@MainActor
final class LaunchServicesApplicationInformationSeedReader {
    private typealias CopySharedMemoryFunction =
        @convention(c) (Int32, Bool) -> UnsafeMutableRawPointer?
    private typealias ReadSeedFunction = @convention(c) (UnsafeRawPointer) -> UInt32

    nonisolated(unsafe) private let libraryHandle: UnsafeMutableRawPointer
    nonisolated(unsafe) private let sharedMemory: UnsafeMutableRawPointer
    private let readSeedFunction: ReadSeedFunction

    init?() {
        guard
            let libraryHandle = dlopen(
                "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/LaunchServices",
                RTLD_LAZY),
            let copySymbol = dlsym(
                libraryHandle, "_LSSharedMemoryCopyForSessionID"),
            let readSeedSymbol = dlsym(
                libraryHandle, "_LSSharedMemoryGetApplicationInformationSeed")
        else { return nil }

        let copySharedMemory = unsafeBitCast(
            copySymbol, to: CopySharedMemoryFunction.self)
        let readSeedFunction = unsafeBitCast(
            readSeedSymbol, to: ReadSeedFunction.self)
        guard let sharedMemory = copySharedMemory(-1, true) else {
            dlclose(libraryHandle)
            return nil
        }
        self.libraryHandle = libraryHandle
        self.sharedMemory = sharedMemory
        self.readSeedFunction = readSeedFunction
    }

    func read() -> UInt32 {
        readSeedFunction(sharedMemory)
    }

    deinit {
        Unmanaged<AnyObject>.fromOpaque(sharedMemory).release()
        dlclose(libraryHandle)
    }
}

@MainActor
final class SystemDockBadgeObserver: @unchecked Sendable {
    private struct BadgeItem {
        let identity: String
        let element: AXUIElement
    }

    private static let statusLabelAttribute = "AXStatusLabel" as CFString
    nonisolated static let badgeChangeNotificationNames = [
        kAXValueChangedNotification,
        kAXTitleChangedNotification,
        "AXStatusLabelChanged",
    ]
    private static let maximumTraversalDepth = 5
    private static let maximumElementCount = 512
    // Dock does not emit a reliable public badge-change notification. A cheap
    // LaunchServices shared-memory seed detects application metadata changes;
    // only a changed seed causes cached Dock status labels to be read. If that
    // implementation surface disappears, fall back to a low-frequency scan.
    nonisolated private static let seedCheckInterval = Duration.seconds(1)
    nonisolated private static let fallbackBadgeRefreshInterval = Duration.seconds(10)
    nonisolated private static let minimumScanInterval = Duration.seconds(1)
    nonisolated static let applicationMembershipRefreshDelay = Duration.seconds(1)
    private static let attachmentRetryDelays: [Duration] = [
        .milliseconds(250), .seconds(1), .seconds(5), .seconds(30),
    ]

    private let logger = Logger(subsystem: "com.tinytaskbar", category: "badges")
    private var observer: AXObserver?
    private var observedElements: [AXUIElement] = []
    private var badgeItems: [BadgeItem] = []
    private var refreshElementsOnNextScan = false
    private var observedApplicationIdentities: Set<String> = []
    private var dockPID: pid_t?
    private var workspaceTokens: [NSObjectProtocol] = []
    private var pendingRefresh: Task<Void, Never>?
    private var pendingRefreshDeadline: ContinuousClock.Instant?
    private var pendingSeedCheck: Task<Void, Never>?
    private var lastScanInstant: ContinuousClock.Instant?
    private var seedReader: LaunchServicesApplicationInformationSeedReader?
    private var lastApplicationInformationSeed: UInt32?
    private var shouldRun = false
    private var badges: [String: String] = [:]
    private var attachmentAttempt = 0

    var onChange: (@MainActor ([String: String]) -> Void)?

    nonisolated static func nextBadgeScanDelay(
        hasObservedApplications: Bool,
        badgesChanged _: Bool
    ) -> Duration? {
        guard hasObservedApplications else { return nil }
        return fallbackBadgeRefreshInterval
    }

    nonisolated static var applicationInformationSeedCheckInterval: Duration {
        seedCheckInterval
    }

    func setObservedApplicationIdentities(_ identities: Set<String>) {
        guard identities != observedApplicationIdentities else { return }
        observedApplicationIdentities = identities
        let retainedBadges = badges.filter { identities.contains($0.key) }
        if retainedBadges != badges {
            badges = retainedBadges
            onChange?(badges)
        }
        if shouldRun {
            if identities.isEmpty {
                pendingSeedCheck?.cancel()
                pendingSeedCheck = nil
            }
            scheduleRefresh()
        }
    }

    func start() {
        guard !shouldRun else { return }
        shouldRun = true
        seedReader = LaunchServicesApplicationInformationSeedReader()
        lastApplicationInformationSeed = seedReader?.read()
        logger.notice(
            "badge metadata seed detector available=\(self.seedReader != nil, privacy: .public)")
        observeDockLifecycle()
        attachToDock()
    }

    func stop() {
        shouldRun = false
        pendingRefresh?.cancel()
        pendingRefresh = nil
        pendingRefreshDeadline = nil
        pendingSeedCheck?.cancel()
        pendingSeedCheck = nil
        lastScanInstant = nil
        seedReader = nil
        lastApplicationInformationSeed = nil
        for token in workspaceTokens {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
        workspaceTokens.removeAll()
        detachFromDock()
        badges = [:]
        onChange?([:])
    }

    private func observeDockLifecycle() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
        ] {
            workspaceTokens.append(
                center.addObserver(forName: name, object: nil, queue: .main) {
                    [weak self] notification in
                    guard
                        let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                            as? NSRunningApplication
                    else { return }
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        if application.bundleIdentifier == "com.apple.dock" {
                            self.detachFromDock()
                            if name == NSWorkspace.didLaunchApplicationNotification {
                                self.scheduleRefresh(after: .milliseconds(250))
                            }
                        } else {
                            // Dock contents can change when an ordinary application
                            // launches or exits. Those already-event-driven lifecycle
                            // notifications are enough to keep the observed item set fresh.
                            self.refreshElementsOnNextScan = true
                            self.scheduleRefresh(
                                after: Self.applicationMembershipRefreshDelay)
                        }
                    }
                })
        }
    }

    private func attachToDock() {
        guard shouldRun, AXIsProcessTrusted() else { return }
        guard
            let application = NSRunningApplication.runningApplications(
                withBundleIdentifier: "com.apple.dock"
            ).first
        else {
            scheduleAttachmentRetry()
            return
        }
        attachmentAttempt = 0
        let pid = application.processIdentifier
        let root = AXUIElementCreateApplication(pid)
        dockPID = pid
        var createdObserver: AXObserver?
        let error = AXObserverCreate(pid, dockBadgeObserverCallback, &createdObserver)
        if error == .success, let createdObserver {
            observer = createdObserver
            CFRunLoopAddSource(
                CFRunLoopGetMain(), AXObserverGetRunLoopSource(createdObserver), .defaultMode)
        } else {
            logger.debug("could not create Dock AX observer error=\(error.rawValue)")
        }
        scan(root: root, refreshElements: true)
    }

    private func scan(root: AXUIElement? = nil, refreshElements: Bool = false) {
        guard shouldRun, AXIsProcessTrusted(), let dockPID else { return }
        guard !observedApplicationIdentities.isEmpty else {
            if !badges.isEmpty {
                badges = [:]
                onChange?([:])
            }
            return
        }
        lastScanInstant = ContinuousClock().now
        let root = root ?? AXUIElementCreateApplication(dockPID)
        if refreshElements || refreshElementsOnNextScan || badgeItems.isEmpty {
            let elements = dockApplicationItems(from: root)
            badgeItems = elements.compactMap { element in
                applicationIdentity(for: element).map {
                    BadgeItem(identity: $0, element: element)
                }
            }
            refreshElementsOnNextScan = false
            if let observer {
                removeElementNotifications(observer)
                let observedBadgeElements = badgeItems.compactMap { item in
                    observedApplicationIdentities.contains(item.identity)
                        ? item.element : nil
                }
                // Observe only application Dock items. The Dock root emits broad
                // value changes while icons animate for attention; treating those
                // as badge changes creates an avoidable AX refresh storm.
                observedElements = observedBadgeElements
                let refcon = Unmanaged.passUnretained(self).toOpaque()
                for element in observedElements {
                    for name in Self.badgeChangeNotificationNames {
                        let notification = name as CFString
                        let error = AXObserverAddNotification(
                            observer, element, notification as CFString, refcon)
                        if error != .success && error != .notificationAlreadyRegistered
                            && error != .notificationUnsupported
                        {
                            logger.debug(
                                "Dock AX notification unavailable: \(notification) (\(error.rawValue))"
                            )
                        }
                    }
                }
            }
        }

        var nextBadges: [String: String] = [:]
        for item in badgeItems where observedApplicationIdentities.contains(item.identity) {
            let label = stringAttribute(Self.statusLabelAttribute, from: item.element)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let label, !label.isEmpty else { continue }
            nextBadges[item.identity] = String(label.prefix(64))
        }
        let changed = nextBadges != badges
        if changed {
            badges = nextBadges
            onChange?(badges)
        }
        if seedReader != nil {
            scheduleSeedCheck()
        } else if let nextDelay = Self.nextBadgeScanDelay(
            hasObservedApplications: !observedApplicationIdentities.isEmpty,
            badgesChanged: changed)
        {
            scheduleRefresh(after: nextDelay)
        }
    }

    private func dockApplicationItems(from root: AXUIElement) -> [AXUIElement] {
        var queue: [(AXUIElement, Int)] = [(root, 0)]
        var cursor = 0
        var result: [AXUIElement] = []
        while cursor < queue.count, cursor < Self.maximumElementCount {
            let (element, depth) = queue[cursor]
            cursor += 1
            if stringAttribute(kAXSubroleAttribute as CFString, from: element)
                == "AXApplicationDockItem"
            {
                result.append(element)
                continue
            }
            guard depth < Self.maximumTraversalDepth else { continue }
            for child in elementArrayAttribute(kAXChildrenAttribute as CFString, from: element) {
                queue.append((child, depth + 1))
                if queue.count >= Self.maximumElementCount { break }
            }
        }
        return result
    }

    private func applicationIdentity(for element: AXUIElement) -> String? {
        var rawValue: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(element, kAXURLAttribute as CFString, &rawValue)
                == .success,
            let rawValue
        else { return nil }
        let url: URL?
        if CFGetTypeID(rawValue) == CFURLGetTypeID() {
            url = rawValue as? URL
        } else if let path = rawValue as? String {
            url = path.hasPrefix("file:") ? URL(string: path) : URL(fileURLWithPath: path)
        } else {
            url = nil
        }
        guard let url else { return nil }
        let standardizedURL = url.standardizedFileURL
        return Bundle(url: standardizedURL)?.bundleIdentifier ?? standardizedURL.path
    }

    private func elementArrayAttribute(
        _ attribute: CFString,
        from element: AXUIElement
    ) -> [AXUIElement] {
        var rawValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &rawValue) == .success,
            let rawValue
        else { return [] }
        if let elements = rawValue as? [AXUIElement] { return elements }
        guard let values = rawValue as? NSArray else { return [] }
        return values.compactMap { value in
            let cfValue = value as CFTypeRef
            guard CFGetTypeID(cfValue) == AXUIElementGetTypeID() else { return nil }
            return (cfValue as! AXUIElement)
        }
    }

    private func stringAttribute(
        _ attribute: CFString,
        from element: AXUIElement
    ) -> String? {
        var rawValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &rawValue) == .success,
            let rawValue, CFGetTypeID(rawValue) == CFStringGetTypeID()
        else { return nil }
        return rawValue as? String
    }

    private func scheduleRefresh(after delay: Duration = .milliseconds(50)) {
        guard shouldRun else { return }
        let clock = ContinuousClock()
        let now = clock.now
        var deadline = now.advanced(by: delay)
        if let lastScanInstant {
            deadline = max(
                deadline,
                lastScanInstant.advanced(by: Self.minimumScanInterval))
        }
        if let pendingRefreshDeadline, pendingRefreshDeadline <= deadline {
            return
        }
        pendingRefresh?.cancel()
        pendingRefreshDeadline = deadline
        pendingRefresh = Task { @MainActor [weak self] in
            try? await Task.sleep(until: deadline, clock: clock)
            guard !Task.isCancelled, let self, self.shouldRun else { return }
            self.pendingRefresh = nil
            self.pendingRefreshDeadline = nil
            if self.dockPID == nil {
                self.attachToDock()
            } else {
                self.scan()
            }
        }
    }

    private func scheduleAttachmentRetry() {
        guard attachmentAttempt < Self.attachmentRetryDelays.count else { return }
        let delay = Self.attachmentRetryDelays[attachmentAttempt]
        attachmentAttempt += 1
        scheduleRefresh(after: delay)
    }

    private func scheduleSeedCheck() {
        guard shouldRun, !observedApplicationIdentities.isEmpty,
            seedReader != nil, pendingSeedCheck == nil
        else { return }
        pendingSeedCheck = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.seedCheckInterval)
            guard !Task.isCancelled, let self, self.shouldRun,
                let seedReader = self.seedReader
            else { return }
            self.pendingSeedCheck = nil
            let seed = seedReader.read()
            if seed != self.lastApplicationInformationSeed {
                self.lastApplicationInformationSeed = seed
                self.logger.debug(
                    "application metadata changed; checking represented badge labels")
                self.scheduleRefresh()
            }
            self.scheduleSeedCheck()
        }
    }

    private func removeElementNotifications(_ observer: AXObserver) {
        for element in observedElements {
            for name in Self.badgeChangeNotificationNames {
                let notification = name as CFString
                _ = AXObserverRemoveNotification(observer, element, notification as CFString)
            }
        }
        observedElements.removeAll()
    }

    private func detachFromDock() {
        pendingRefresh?.cancel()
        pendingRefresh = nil
        pendingRefreshDeadline = nil
        pendingSeedCheck?.cancel()
        pendingSeedCheck = nil
        lastScanInstant = nil
        if let observer {
            removeElementNotifications(observer)
            CFRunLoopRemoveSource(
                CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        observer = nil
        dockPID = nil
        attachmentAttempt = 0
        observedElements.removeAll()
        badgeItems.removeAll()
        refreshElementsOnNextScan = false
        if !badges.isEmpty {
            badges = [:]
            onChange?([:])
        }
    }

    nonisolated func notificationReceived() {
        Task { @MainActor [weak self] in
            self?.scheduleRefresh()
        }
    }
}

private func dockBadgeObserverCallback(
    _: AXObserver,
    _: AXUIElement,
    _: CFString,
    _ refcon: UnsafeMutableRawPointer?
) {
    guard let refcon else { return }
    let observer = Unmanaged<SystemDockBadgeObserver>.fromOpaque(refcon).takeUnretainedValue()
    observer.notificationReceived()
}
