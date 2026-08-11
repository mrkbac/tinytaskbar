import AppKit

@MainActor
private final class ApplicationRecordButton: NSButton {
    var applicationIdentity = ""
}

@MainActor
final class ApplicationsManagementWindow: NSWindow {
    var onUnpin: (@MainActor (String) -> Void)?
    var onRestore: (@MainActor (String) -> Void)?
    var onResetPins: (@MainActor () -> Void)?
    var onResetExclusions: (@MainActor () -> Void)?

    private let pinnedStack = NSStackView()
    private let excludedStack = NSStackView()
    private let scrollView = NSScrollView()
    private let documentView = NSView()
    private let contentStack = NSStackView()

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 420),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        title = "Applications"
        isReleasedWhenClosed = false
        setupInterface()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func refresh(preferences: TinyTaskbarPreferences) {
        rebuild(
            pinnedStack,
            records: preferences.pinnedApplications.sorted { $0.sequence < $1.sequence },
            actionTitle: "Unpin", action: #selector(unpin(_:)))
        rebuild(
            excludedStack,
            records: preferences.excludedApplications.sorted {
                $0.localizedName.localizedCaseInsensitiveCompare($1.localizedName)
                    == .orderedAscending
            },
            actionTitle: "Show Again", action: #selector(restore(_:)))
        updateDocumentSize()
    }

    private func setupInterface() {
        for stack in [pinnedStack, excludedStack] {
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 6
        }
        let pinnedSection = section(
            title: "Pinned Applications", stack: pinnedStack,
            resetAction: #selector(resetPins))
        let excludedSection = section(
            title: "Excluded Applications", stack: excludedStack,
            resetAction: #selector(resetExclusions))
        let done = NSButton(title: "Done", target: self, action: #selector(done))
        done.keyEquivalent = "\r"
        let buttonSpacer = NSView()
        let buttonRow = NSStackView(views: [buttonSpacer, done])
        buttonRow.alignment = .centerY
        contentStack.setViews([pinnedSection, excludedSection, buttonRow], in: .top)
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 20
        contentStack.translatesAutoresizingMaskIntoConstraints = false

        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(contentStack)
        scrollView.documentView = documentView

        guard let contentView else { return }
        contentView.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: contentView.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            contentStack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor, constant: 24),
            contentStack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor, constant: -24),
            contentStack.topAnchor.constraint(equalTo: documentView.topAnchor, constant: 22),
            contentStack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor, constant: -22),
        ])
        pinnedSection.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
        excludedSection.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
        buttonRow.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
        contentView.layoutSubtreeIfNeeded()
        updateDocumentSize()
    }

    private func section(
        title: String, stack: NSStackView, resetAction: Selector
    ) -> NSStackView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        let reset = NSButton(title: "Reset All", target: self, action: resetAction)
        let heading = NSStackView(views: [label, NSView(), reset])
        heading.alignment = .centerY
        let section = NSStackView(views: [heading, stack])
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = 8
        heading.widthAnchor.constraint(equalTo: section.widthAnchor).isActive = true
        stack.widthAnchor.constraint(equalTo: section.widthAnchor).isActive = true
        return section
    }

    private func rebuild(
        _ stack: NSStackView,
        records: [ApplicationRecord],
        actionTitle: String,
        action: Selector
    ) {
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        guard !records.isEmpty else {
            let empty = NSTextField(labelWithString: "None")
            empty.textColor = .secondaryLabelColor
            stack.addArrangedSubview(empty)
            return
        }
        for record in records {
            let icon = NSImageView()
            icon.image = record.bundlePath.map { NSWorkspace.shared.icon(forFile: $0) }
                ?? NSImage(systemSymbolName: "app", accessibilityDescription: nil)
            icon.imageScaling = .scaleProportionallyDown
            icon.widthAnchor.constraint(equalToConstant: 24).isActive = true
            icon.heightAnchor.constraint(equalToConstant: 24).isActive = true
            let button = ApplicationRecordButton(title: actionTitle, target: self, action: action)
            button.applicationIdentity = record.identity
            let row = NSStackView(
                views: [icon, NSTextField(labelWithString: record.localizedName), NSView(), button])
            row.alignment = .centerY
            row.spacing = 8
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }

    private func updateDocumentSize() {
        scrollView.layoutSubtreeIfNeeded()
        let width = max(1, scrollView.contentSize.width)
        documentView.frame.size.width = width
        documentView.layoutSubtreeIfNeeded()
        let height = max(scrollView.contentSize.height, contentStack.fittingSize.height + 44)
        documentView.frame = NSRect(x: 0, y: 0, width: width, height: height)
        documentView.layoutSubtreeIfNeeded()
    }

    @objc private func unpin(_ sender: ApplicationRecordButton) {
        onUnpin?(sender.applicationIdentity)
    }
    @objc private func restore(_ sender: ApplicationRecordButton) {
        onRestore?(sender.applicationIdentity)
    }
    @objc private func resetPins() { onResetPins?() }
    @objc private func resetExclusions() { onResetExclusions?() }
    @objc private func done() {
        if let sheetParent {
            sheetParent.endSheet(self)
        } else {
            close()
        }
    }
}
