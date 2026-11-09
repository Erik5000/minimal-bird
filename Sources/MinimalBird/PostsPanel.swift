// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Minimal Bird contributors

import AppKit

/// One of the signed-in account's posts. It holds no counts.
struct OwnPost: Equatable, Identifiable {
    let id: String
    let text: String
    let time: Date?
    let media: Bool

    var label: String { text.isEmpty ? (media ? "Photo or video" : "Post without text") : text }
}

/// The account's own posts and replies as native rows. X's page stays hidden behind it.
@MainActor
final class PostsPanel: NSView {
    var onUpdate: ((String) -> Void)?
    var onQuote: ((String) -> Void)?
    var onOlder: (() -> Void)?
    private let heading = NSTextField(labelWithString: "My posts")
    private let detail = NSTextField(labelWithString: "Your posts and replies on X")
    private let scroll = NSScrollView()
    private let list = NSStackView()
    private let olderButton = NSButton(title: "Show older posts", target: nil, action: nil)
    private var shown: [OwnPost] = []

    var rowCount: Int { shown.count }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Palette.paper.cgColor
        heading.font = .systemFont(ofSize: 24, weight: .semibold)
        heading.textColor = Palette.ink
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = Palette.muted
        olderButton.bezelStyle = .push
        olderButton.controlSize = .regular
        olderButton.target = self
        olderButton.action = #selector(showOlder)
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
        for child in [heading, detail, scroll] {
            child.translatesAutoresizingMaskIntoConstraints = false
            addSubview(child)
        }
        list.translatesAutoresizingMaskIntoConstraints = false
        document.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            heading.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            heading.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            detail.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 6),
            detail.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            scroll.topAnchor.constraint(equalTo: detail.bottomAnchor, constant: 16),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            list.topAnchor.constraint(equalTo: document.topAnchor),
            list.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            list.bottomAnchor.constraint(equalTo: document.bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("Use init()") }
    override var acceptsFirstResponder: Bool { true }

    /// Rebuilds the rows only when the posts changed, so scrolling stays calm.
    func update(_ posts: [OwnPost]) {
        guard posts != shown else { return }
        shown = posts
        list.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for post in posts {
            let row = PostRow(post: post)
            row.onUpdate = { [weak self] in self?.onUpdate?(post.id) }
            row.onQuote = { [weak self] in self?.onQuote?(post.id) }
            list.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
        }
        if !posts.isEmpty { list.addArrangedSubview(olderButton) }
    }

    @objc private func showOlder() { onOlder?() }
}

@MainActor
private final class PostRow: NSView {
    var onUpdate: (() -> Void)?
    var onQuote: (() -> Void)?

    init(post: OwnPost) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Palette.hover.cgColor
        layer?.cornerRadius = 12
        toolTip = post.label
        let text = NSTextField(wrappingLabelWithString: post.label)
        text.font = .systemFont(ofSize: 13)
        text.textColor = post.text.isEmpty ? Palette.muted : Palette.ink
        text.maximumNumberOfLines = 4
        text.lineBreakMode = .byTruncatingTail
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let when = post.time.map { DateFormatter.localizedString(from: $0, dateStyle: .medium, timeStyle: .short) } ?? ""
        let detail = NSTextField(labelWithString: when)
        detail.font = .systemFont(ofSize: 10)
        detail.textColor = Palette.muted
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let update = NSButton(title: "Update", target: self, action: #selector(updatePost))
        let quote = NSButton(title: "Quote", target: self, action: #selector(quotePost))
        for button in [update, quote] { button.bezelStyle = .push; button.controlSize = .regular }
        update.toolTip = "Add a new post under this one"
        quote.toolTip = "Write a new post that quotes this one"
        update.setAccessibilityLabel("Update post: \(post.label)")
        quote.setAccessibilityLabel("Quote post: \(post.label)")
        let actions = NSStackView(views: [update, quote])
        actions.spacing = 6
        for child in [text, detail, actions] {
            child.translatesAutoresizingMaskIntoConstraints = false
            addSubview(child)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 128),
            text.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            text.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            text.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            text.heightAnchor.constraint(equalToConstant: 68),
            detail.leadingAnchor.constraint(equalTo: text.leadingAnchor),
            detail.centerYAnchor.constraint(equalTo: actions.centerYAnchor),
            detail.trailingAnchor.constraint(lessThanOrEqualTo: actions.leadingAnchor, constant: -8),
            actions.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            actions.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10)
        ])
    }

    required init?(coder: NSCoder) { fatalError("Use init(post:)") }
    @objc private func updatePost() { onUpdate?() }
    @objc private func quotePost() { onQuote?() }
}
