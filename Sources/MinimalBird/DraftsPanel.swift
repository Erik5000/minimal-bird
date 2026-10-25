// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Minimal Bird contributors

import AppKit
import FocusCore

/// The strip below the composer: a "Drafts" disclosure with a short list of
/// saved drafts, and a quiet status line. Its controls never take keyboard
/// focus, so typing always stays in the composer.
@MainActor
final class DraftsPanel: NSView {
    var onOpen: ((UUID) -> Void)?
    var onDelete: ((UUID) -> Void)?
    var onToggle: ((Bool) -> Void)?
    private(set) var isExpanded: Bool

    private let toggle = NSButton()
    private let chevron = NSImageView()
    private let title = NSTextField(labelWithString: "Drafts")
    private let count = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let scroll = NSScrollView()
    private let list = NSStackView()
    private let empty = NSTextField(wrappingLabelWithString: "Text you write is saved here as you type, on this Mac only.")
    private var listHeight: NSLayoutConstraint!
    private var drafts: [Draft] = []
    private var current: UUID?
    private var shownRows: [String] = []
    private var statusTimer: Timer?
    private static let rowHeight: CGFloat = 48
    private static let maxRows: CGFloat = 4.5
    private static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    init(expanded: Bool) {
        isExpanded = expanded
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Palette.paper.cgColor

        let rule = NSView()
        rule.wantsLayer = true
        rule.layer?.backgroundColor = Palette.line.cgColor

        chevron.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)
        chevron.symbolConfiguration = .init(pointSize: 9, weight: .bold)
        chevron.contentTintColor = Palette.muted
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        title.textColor = Palette.ink
        count.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        count.textColor = Palette.muted
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = Palette.muted
        statusLabel.alignment = .right
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // A transparent button covers the disclosure label for a large hit area.
        toggle.title = ""
        toggle.isBordered = false
        toggle.isTransparent = true
        toggle.refusesFirstResponder = true
        toggle.target = self
        toggle.action = #selector(toggleExpanded)
        toggle.setAccessibilityLabel("Drafts")
        toggle.toolTip = "Show or hide drafts (⌘D)"

        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 0
        list.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 6, right: 0)
        let document = FlippedView()
        document.addSubview(list)
        scroll.documentView = document
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.scrollerStyle = .overlay
        empty.font = .systemFont(ofSize: 12)
        empty.textColor = Palette.muted

        for child in [rule, chevron, title, count, statusLabel, toggle, scroll, empty] {
            child.translatesAutoresizingMaskIntoConstraints = false
            addSubview(child)
        }
        list.translatesAutoresizingMaskIntoConstraints = false
        document.translatesAutoresizingMaskIntoConstraints = false
        listHeight = scroll.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            rule.topAnchor.constraint(equalTo: topAnchor),
            rule.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            rule.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            rule.heightAnchor.constraint(equalToConstant: 1),
            chevron.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            chevron.centerYAnchor.constraint(equalTo: topAnchor, constant: 20),
            chevron.widthAnchor.constraint(equalToConstant: 10),
            title.leadingAnchor.constraint(equalTo: chevron.trailingAnchor, constant: 7),
            title.centerYAnchor.constraint(equalTo: chevron.centerYAnchor),
            count.leadingAnchor.constraint(equalTo: title.trailingAnchor, constant: 6),
            count.firstBaselineAnchor.constraint(equalTo: title.firstBaselineAnchor),
            toggle.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            toggle.trailingAnchor.constraint(equalTo: count.trailingAnchor, constant: 8),
            toggle.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            toggle.heightAnchor.constraint(equalToConstant: 28),
            statusLabel.leadingAnchor.constraint(greaterThanOrEqualTo: toggle.trailingAnchor, constant: 12),
            statusLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            statusLabel.centerYAnchor.constraint(equalTo: chevron.centerYAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor, constant: 40),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            listHeight,
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            list.topAnchor.constraint(equalTo: document.topAnchor),
            list.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            list.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            empty.topAnchor.constraint(equalTo: scroll.topAnchor, constant: 2),
            empty.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 37),
            empty.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -20)
        ])
        applyExpansion(animated: false)
    }

    required init?(coder: NSCoder) { fatalError("Use init(expanded:)") }

    var status: String {
        get { statusLabel.stringValue }
        set { statusTimer?.invalidate(); statusLabel.stringValue = newValue }
    }

    /// A short confirmation that fades back to the persistent status.
    func flash(_ message: String) {
        let previous = statusTimer == nil ? statusLabel.stringValue : ""
        statusTimer?.invalidate()
        statusLabel.stringValue = message
        statusTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.statusLabel.stringValue == message else { return }
                self.statusLabel.stringValue = previous
                self.statusTimer = nil
            }
        }
    }

    func update(drafts: [Draft], current: UUID?) {
        self.drafts = drafts
        self.current = current
        count.stringValue = drafts.isEmpty ? "" : "\(drafts.count)"
        toggle.setAccessibilityValue(drafts.isEmpty ? "No drafts" : "\(drafts.count) drafts")
        if isExpanded { rebuildRows() }
    }

    /// Rows exist only while the list is open, and are rebuilt only when what
    /// they show changes, so saving on every keystroke stays cheap.
    private func rebuildRows() {
        let now = Date()
        let rows = drafts.map { draft -> (Draft, String, Bool) in
            let isCurrent = draft.id == current
            let when = isCurrent ? "Editing now" : Self.relative.localizedString(for: draft.updated, relativeTo: now)
            let posts = draft.posts.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
            return (draft, posts > 1 ? "\(when) · \(posts) posts" : when, isCurrent)
        }
        let signature = rows.map { "\($0.0.id)|\($0.0.preview)|\($0.1)" }
        guard signature != shownRows else { return }
        shownRows = signature
        list.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (draft, detail, isCurrent) in rows {
            let row = DraftRow(title: draft.preview, detail: detail, isCurrent: isCurrent)
            let id = draft.id
            row.onOpen = { [weak self] in self?.onOpen?(id) }
            row.onDelete = { [weak self] in self?.onDelete?(id) }
            list.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
        }
        applyExpansion(animated: false)
    }

    func setExpanded(_ expanded: Bool) {
        guard expanded != isExpanded else { return }
        isExpanded = expanded
        if expanded { rebuildRows() } else {
            list.arrangedSubviews.forEach { $0.removeFromSuperview() }
            shownRows = []
        }
        applyExpansion(animated: true)
        onToggle?(expanded)
    }

    @objc private func toggleExpanded() { setExpanded(!isExpanded) }

    private func applyExpansion(animated: Bool) {
        let rows = CGFloat(drafts.count)
        let height = !isExpanded ? 0 : rows == 0 ? 34 : min(rows, Self.maxRows) * Self.rowHeight + 6
        empty.isHidden = !isExpanded || rows > 0
        scroll.isHidden = !isExpanded
        chevron.image = NSImage(systemSymbolName: isExpanded ? "chevron.down" : "chevron.right", accessibilityDescription: nil)
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.allowsImplicitAnimation = true
                listHeight.animator().constant = height
                superview?.layoutSubtreeIfNeeded()
            }
        } else {
            listHeight.constant = height
        }
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// One draft: its first line, when it was saved, and a delete button on hover.
@MainActor
private final class DraftRow: NSView {
    var onOpen: (() -> Void)?
    var onDelete: (() -> Void)?
    private let isCurrent: Bool
    private let highlight = NSView()
    private let delete = NSButton()
    private var hovering = false { didSet { refresh() } }

    init(title: String, detail: String, isCurrent: Bool) {
        self.isCurrent = isCurrent
        super.init(frame: .zero)
        let marker = NSView()
        marker.wantsLayer = true
        marker.layer?.cornerRadius = 3
        marker.layer?.backgroundColor = (isCurrent ? Palette.accent : Palette.line).cgColor
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13, weight: isCurrent ? .medium : .regular)
        titleLabel.textColor = Palette.ink
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let detailLabel = NSTextField(labelWithString: detail)
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = isCurrent ? Palette.accent : Palette.muted
        highlight.wantsLayer = true
        highlight.layer?.cornerRadius = 8
        delete.image = NSImage(systemSymbolName: "trash", accessibilityDescription: "Delete draft")
        delete.symbolConfiguration = .init(pointSize: 11, weight: .regular)
        delete.isBordered = false
        delete.refusesFirstResponder = true
        delete.contentTintColor = Palette.muted
        delete.target = self
        delete.action = #selector(deleteDraft)
        delete.toolTip = "Delete draft"
        for child in [highlight, marker, titleLabel, detailLabel, delete] {
            child.translatesAutoresizingMaskIntoConstraints = false
            addSubview(child)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 48),
            highlight.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            highlight.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            highlight.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            highlight.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            marker.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            marker.centerYAnchor.constraint(equalTo: centerYAnchor),
            marker.widthAnchor.constraint(equalToConstant: 6),
            marker.heightAnchor.constraint(equalToConstant: 6),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 29),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: delete.leadingAnchor, constant: -8),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            detailLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            detailLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 1),
            delete.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            delete.centerYAnchor.constraint(equalTo: centerYAnchor),
            delete.widthAnchor.constraint(equalToConstant: 22),
            delete.heightAnchor.constraint(equalToConstant: 22)
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(isCurrent ? "\(title), being edited" : "Open draft: \(title)")
        toolTip = isCurrent ? nil : "Open this draft"
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("Use init(title:detail:isCurrent:)") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        guard !isCurrent, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onOpen?()
    }
    override func accessibilityPerformPress() -> Bool {
        guard !isCurrent else { return false }
        onOpen?()
        return true
    }

    @objc private func deleteDraft() { onDelete?() }

    private func refresh() {
        highlight.layer?.backgroundColor = (hovering && !isCurrent ? Palette.hover : .clear).cgColor
        delete.isHidden = isCurrent || !hovering
    }
}
