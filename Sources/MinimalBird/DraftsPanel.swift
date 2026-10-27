// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Minimal Bird contributors

import AppKit
import FocusCore

/// Explicit composer actions and a full-window library of saved text drafts.
@MainActor
final class DraftsPanel: NSView {
    var onOpen: ((UUID) -> Void)?
    var onDelete: ((UUID) -> Void)?
    var onCopy: ((UUID) -> Void)?
    var onToggle: ((Bool) -> Void)?
    var onSave: (() -> Void)?
    var onNew: (() -> Void)?
    var onLibrary: (() -> Void)?
    var onResume: (() -> Void)?
    private(set) var isExpanded: Bool
    private let libraryButton = NSButton(title: "Draft library", target: nil, action: nil)
    private let newButton = NSButton(title: "New draft", target: nil, action: nil)
    private let saveButton = NSButton(title: "Save draft", target: nil, action: nil)
    private let resumeButton = NSButton(title: "Back to editor", target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "")
    private let heading = NSTextField(labelWithString: "Draft library")
    private let detail = NSTextField(labelWithString: "Text drafts on this Mac")
    private let search = NSSearchField()
    private let scroll = NSScrollView()
    private let list = NSStackView()
    private let empty = NSTextField(wrappingLabelWithString: "")
    private var compactHeight: NSLayoutConstraint!
    private var libraryBottom: NSLayoutConstraint!
    private var drafts: [Draft] = []
    private var current: UUID?
    private var shownRows: [String] = []
    private var statusTimer: Timer?
    private var persistentStatus = ""
    private var busy = false
    private var canSave = false

    init(expanded: Bool) {
        isExpanded = expanded
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Palette.paper.cgColor
        let rule = NSView()
        rule.wantsLayer = true
        rule.layer?.backgroundColor = Palette.line.cgColor
        let actions = NSStackView(views: [libraryButton, resumeButton, NSView(), newButton, saveButton])
        actions.orientation = .horizontal
        actions.spacing = 8
        for button in [libraryButton, newButton, saveButton, resumeButton] {
            button.bezelStyle = .push
            button.controlSize = .large
            button.font = .systemFont(ofSize: 12, weight: .medium)
            button.target = self
            button.setContentHuggingPriority(.required, for: .horizontal)
        }
        libraryButton.action = #selector(openLibrary)
        newButton.action = #selector(newDraft)
        saveButton.action = #selector(saveDraft)
        resumeButton.action = #selector(resumeDraft)
        saveButton.bezelColor = Palette.accent
        saveButton.toolTip = "Save the current text and return to Draft library (⌘S)"
        newButton.toolTip = "Save the current text and start a new draft (⌘N)"
        libraryButton.toolTip = "Save the current text and open Draft library (⌘D)"
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = Palette.muted
        statusLabel.lineBreakMode = .byTruncatingTail
        heading.font = .systemFont(ofSize: 24, weight: .semibold)
        heading.textColor = Palette.ink
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = Palette.muted
        search.placeholderString = "Search drafts"
        search.setAccessibilityLabel("Search drafts")
        search.target = self
        search.action = #selector(searchChanged)
        search.sendsSearchStringImmediately = true
        empty.font = .systemFont(ofSize: 14)
        empty.textColor = Palette.muted
        empty.alignment = .center
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 8
        let document = FlippedView()
        document.addSubview(list)
        scroll.documentView = document
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        for child in [rule, actions, statusLabel, heading, detail, search, scroll, empty] {
            child.translatesAutoresizingMaskIntoConstraints = false
            addSubview(child)
        }
        list.translatesAutoresizingMaskIntoConstraints = false
        document.translatesAutoresizingMaskIntoConstraints = false
        compactHeight = heightAnchor.constraint(equalToConstant: 82)
        libraryBottom = scroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16)
        NSLayoutConstraint.activate([
            rule.topAnchor.constraint(equalTo: topAnchor),
            rule.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            rule.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            rule.heightAnchor.constraint(equalToConstant: 1),
            actions.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            actions.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            actions.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            actions.heightAnchor.constraint(equalToConstant: 32),
            statusLabel.topAnchor.constraint(equalTo: actions.bottomAnchor, constant: 8),
            statusLabel.leadingAnchor.constraint(equalTo: actions.leadingAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: actions.trailingAnchor),
            heading.topAnchor.constraint(equalTo: topAnchor, constant: 96),
            heading.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            detail.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 6),
            detail.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            search.topAnchor.constraint(equalTo: detail.bottomAnchor, constant: 20),
            search.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            search.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            search.heightAnchor.constraint(equalToConstant: 28),
            scroll.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 16),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            list.topAnchor.constraint(equalTo: document.topAnchor),
            list.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            list.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            empty.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 40),
            empty.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 32),
            empty.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -32)
        ])
        applyMode()
    }

    required init?(coder: NSCoder) { fatalError("Use init(expanded:)") }
    override var acceptsFirstResponder: Bool { true }
    var status: String {
        get { statusLabel.stringValue }
        set {
            statusTimer?.invalidate()
            statusTimer = nil
            persistentStatus = newValue
            statusLabel.stringValue = newValue
        }
    }
    func flash(_ message: String) {
        statusTimer?.invalidate()
        statusLabel.stringValue = message
        statusTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.statusLabel.stringValue == message else { return }
                self.statusLabel.stringValue = self.persistentStatus
                self.statusTimer = nil
            }
        }
    }
    func update(drafts: [Draft], current: UUID?) {
        self.drafts = drafts
        self.current = current
        detail.stringValue = "\(drafts.count) \(drafts.count == 1 ? "draft" : "drafts") · Text saved on this Mac"
        if isExpanded { rebuildRows() }
    }
    func updateActions(canSave: Bool, busy: Bool) {
        self.canSave = canSave
        self.busy = busy
        saveButton.isEnabled = canSave && !busy
        for button in [newButton, libraryButton, resumeButton] { button.isEnabled = !busy }
        search.isEnabled = !busy
    }
    func setExpanded(_ expanded: Bool) {
        guard expanded != isExpanded else { return }
        isExpanded = expanded
        applyMode()
        if expanded { rebuildRows() }
        onToggle?(expanded)
    }
    private func applyMode() {
        compactHeight.isActive = !isExpanded
        libraryBottom.isActive = isExpanded
        libraryButton.isHidden = isExpanded
        saveButton.isHidden = isExpanded
        resumeButton.isHidden = !isExpanded
        for child in [heading, detail, search, scroll, empty] { child.isHidden = !isExpanded }
        updateActions(canSave: canSave, busy: busy)
    }
    private func rebuildRows() {
        let query = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let visible = drafts.filter { query.isEmpty || $0.posts.joined(separator: "\n").localizedCaseInsensitiveContains(query) }
        let signature = visible.map { "\($0.id)|\($0.updated)|\($0.posts)|\($0.id == current)" }
        empty.stringValue = drafts.isEmpty ? "No drafts yet. Write a post, then choose Save draft." : "No drafts match your search."
        empty.isHidden = !isExpanded || !visible.isEmpty
        guard signature != shownRows else { return }
        shownRows = signature
        list.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for draft in visible {
            let row = DraftRow(draft: draft)
            row.onOpen = { [weak self] in self?.onOpen?(draft.id) }
            row.onDelete = { [weak self] in self?.onDelete?(draft.id) }
            row.onCopy = { [weak self] in self?.onCopy?(draft.id) }
            list.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
        }
    }
    @objc private func openLibrary() { onLibrary?() }
    @objc private func newDraft() { onNew?() }
    @objc private func saveDraft() { onSave?() }
    @objc private func resumeDraft() { onResume?() }
    @objc private func searchChanged() { rebuildRows() }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
private final class DraftRow: NSView {
    var onOpen: (() -> Void)?
    var onDelete: (() -> Void)?
    var onCopy: (() -> Void)?
    init(draft: Draft) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Palette.hover.cgColor
        layer?.cornerRadius = 12
        let title = NSTextField(labelWithString: draft.preview)
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.textColor = Palette.ink
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let preview = NSTextField(wrappingLabelWithString: draft.posts.joined(separator: "\n\n"))
        preview.font = .systemFont(ofSize: 12)
        preview.textColor = Palette.muted
        preview.maximumNumberOfLines = 2
        preview.lineBreakMode = .byTruncatingTail
        preview.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let posts = draft.posts.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
        let when = DateFormatter.localizedString(from: draft.updated, dateStyle: .short, timeStyle: .short)
        let detail = NSTextField(labelWithString: "\(posts) \(posts == 1 ? "post" : "posts") · Saved \(when)")
        detail.font = .systemFont(ofSize: 10)
        detail.textColor = Palette.muted
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let edit = NSButton(title: "Edit", target: self, action: #selector(editDraft))
        let delete = NSButton(title: "Delete", target: self, action: #selector(deleteDraft))
        for button in [edit, delete] { button.bezelStyle = .push; button.controlSize = .regular }
        edit.setAccessibilityLabel("Edit draft: \(draft.preview)")
        delete.setAccessibilityLabel("Delete draft: \(draft.preview)")
        let actions = NSStackView(views: [edit, delete])
        actions.spacing = 6
        for child in [title, preview, detail, actions] {
            child.translatesAutoresizingMaskIntoConstraints = false
            addSubview(child)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 126),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            title.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            preview.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 6),
            preview.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            preview.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            preview.heightAnchor.constraint(equalToConstant: 32),
            detail.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            detail.centerYAnchor.constraint(equalTo: actions.centerYAnchor),
            detail.trailingAnchor.constraint(lessThanOrEqualTo: actions.leadingAnchor, constant: -8),
            actions.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            actions.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10)
        ])
        let context = NSMenu()
        let copy = context.addItem(withTitle: "Copy draft text", action: #selector(copyDraft), keyEquivalent: "")
        copy.target = self
        menu = context
    }
    required init?(coder: NSCoder) { fatalError("Use init(draft:)") }
    @objc private func editDraft() { onOpen?() }
    @objc private func deleteDraft() { onDelete?() }
    @objc private func copyDraft() { onCopy?() }
}
