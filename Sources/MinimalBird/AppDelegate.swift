// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Minimal Bird contributors

import AppKit
import WebKit
import FocusCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow!
    private var controller: ComposerController!
    private var testRunner: WebSmokeTests?
    private var terminationPending = false
    private lazy var accounts = AccountProfiles()
    private var controllers: [UUID: ComposerController] = [:]
    private var accountsMenu = NSMenu(title: "Accounts")
    private let accountButton = NSButton()

    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--self-test") {
            testRunner = WebSmokeTests()
            testRunner?.run()
            return
        }
        controller = controllerFor(accounts.profiles.first { $0.id == accounts.selectedID }!)
        buildMenu()
        window = makeWindow(for: controller)
        updateWindowTitle()
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("ComposerWindow.v2")
        if !window.setFrameUsingName("ComposerWindow.v2") { window.center() }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        controller.start(demo: CommandLine.arguments.contains("--demo"))
    }

    private func makeWindow(for content: ComposerController) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 580, height: 660),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "Minimal Bird"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = Palette.paper
        window.appearance = NSAppearance(named: .aqua)
        window.minSize = NSSize(width: 440, height: 460)
        window.contentViewController = content
        window.addTitlebarAccessoryViewController(makeAccountAccessory())
        return window
    }

    /// The app's window around a given controller, for visual snapshots in the
    /// self-test. It has no menus, saved frame or account storage.
    func makePreviewWindow(for content: ComposerController, handle: String) -> NSWindow {
        let preview = makeWindow(for: content)
        accountButton.title = handle
        preview.isReleasedWhenClosed = false
        return preview
    }

    private func controllerFor(_ profile: AccountProfile) -> ComposerController {
        if let existing = controllers[profile.id] { return existing }
        let store = profile.usesDefaultStore ? WKWebsiteDataStore.default() : WKWebsiteDataStore(forIdentifier: profile.id)
        let next = ComposerController(dataStore: store, drafts: DraftStore(url: DraftStore.defaultURL(for: profile.id)))
        next.accountChanged = { [weak self] handle in
            guard let self else { return }
            self.accounts.updateLabel(handle, for: profile.id)
            self.refreshAccountsMenu()
            self.updateWindowTitle()
        }
        controllers[profile.id] = next
        return next
    }

    private func makeAccountsMenu() -> NSMenu {
        let menu = NSMenu(title: "Accounts")
        fillAccountsMenu(menu)
        return menu
    }

    /// The account name sits quietly in the title bar, clear of X's own
    /// controls, and opens the account and app actions.
    private func makeAccountAccessory() -> NSTitlebarAccessoryViewController {
        accountButton.isBordered = false
        accountButton.refusesFirstResponder = true
        accountButton.font = .systemFont(ofSize: 12, weight: .medium)
        accountButton.contentTintColor = Palette.muted
        accountButton.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 8, weight: .semibold))
        accountButton.imagePosition = .imageTrailing
        accountButton.imageHugsTitle = true
        accountButton.target = self
        accountButton.action = #selector(showAccountMenu(_:))
        accountButton.toolTip = "Accounts and options"
        accountButton.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 28))
        container.addSubview(accountButton)
        NSLayoutConstraint.activate([
            accountButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            accountButton.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            accountButton.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor)
        ])
        let accessory = NSTitlebarAccessoryViewController()
        accessory.view = container
        accessory.layoutAttribute = .trailing
        return accessory
    }

    @objc private func showAccountMenu(_ sender: NSButton) {
        let menu = NSMenu()
        fillAccountsMenu(menu)
        menu.addItem(.separator())
        for (title, action, key) in [("New draft", #selector(ComposerController.newPost), "n"),
                                     ("Save draft", #selector(ComposerController.saveDraft), "s"),
                                     ("Reload X", #selector(ComposerController.reloadPage), "r"),
                                     ("Draft library", #selector(ComposerController.showDraftLibrary), "d")] {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
            item.target = controller
        }
        menu.addItem(.separator())
        let signOut = menu.addItem(withTitle: "Sign out…", action: #selector(ComposerController.signOut), keyEquivalent: "")
        signOut.target = controller
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 6), in: sender)
        controller.restoreEditorFocus()
    }

    private func fillAccountsMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        for (index, profile) in accounts.profiles.enumerated() {
            let item = NSMenuItem(title: profile.label, action: #selector(switchAccount(_:)), keyEquivalent: index < 9 ? String(index + 1) : "")
            item.target = self
            item.representedObject = profile.id
            item.state = profile.id == accounts.selectedID ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let add = menu.addItem(withTitle: "Add account…", action: #selector(addAccount), keyEquivalent: "")
        add.target = self
    }

    private func refreshAccountsMenu() { fillAccountsMenu(accountsMenu) }

    private func updateWindowTitle() {
        guard let window else { return }
        let label = accounts.profiles.first { $0.id == accounts.selectedID }?.label ?? ""
        window.title = accounts.profiles.count > 1 ? "Minimal Bird · \(label)" : "Minimal Bird"
        accountButton.title = label.hasPrefix("@") ? label : accounts.profiles.count > 1 ? label : "Account"
        accountButton.setAccessibilityLabel("Account: \(accountButton.title)")
    }

    @objc private func switchAccount(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID, id != accounts.selectedID,
              let profile = accounts.profiles.first(where: { $0.id == id }) else { return }
        accounts.select(id)
        activateAccount(profile)
    }

    private func activateAccount(_ profile: AccountProfile) {
        let isNew = controllers[profile.id] == nil
        controller = controllerFor(profile)
        // Other controllers remain alive, preserving their sessions and drafts.
        displayController(controller)
        buildMenu()
        updateWindowTitle()
        if isNew { controller.start() } else { controller.resume() }
        window.makeKeyAndOrderFront(nil)
        controller.restoreEditorFocus()
    }

    private func displayController(_ next: ComposerController) {
        let frame = window.frame
        next.view.frame = window.contentView?.bounds ?? .zero
        window.contentViewController = next
        window.setFrame(frame, display: true)
    }

    @objc private func addAccount() {
        activateAccount(accounts.add())
    }

    private func buildMenu() {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Minimal Bird", action: #selector(about), keyEquivalent: "")
        let signOut = appMenu.addItem(withTitle: "Sign out…", action: #selector(ComposerController.signOut), keyEquivalent: "")
        signOut.target = controller
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Minimal Bird", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Minimal Bird", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        menu.addItem(appItem)
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        for (title, selector, key) in [("Undo", "undo:", "z"), ("Cut", "cut:", "x"),
                                       ("Copy", "copy:", "c"), ("Paste", "paste:", "v"),
                                       ("Select All", "selectAll:", "a")] {
            edit.addItem(withTitle: title, action: Selector(selector), keyEquivalent: key)
        }
        let redo = NSMenuItem(title: "Redo", action: NSSelectorFromString("redo:"), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.insertItem(redo, at: 1)
        editItem.submenu = edit
        menu.addItem(editItem)
        let fileItem = NSMenuItem()
        let file = NSMenu(title: "File")
        let newPost = file.addItem(withTitle: "New draft", action: #selector(ComposerController.newPost), keyEquivalent: "n")
        newPost.target = controller
        let saveDraft = file.addItem(withTitle: "Save draft", action: #selector(ComposerController.saveDraft), keyEquivalent: "s")
        saveDraft.target = controller
        let reload = file.addItem(withTitle: "Reload X", action: #selector(ComposerController.reloadPage), keyEquivalent: "r")
        reload.target = controller
        file.addItem(.separator())
        let toggleDrafts = file.addItem(withTitle: "Draft library", action: #selector(ComposerController.showDraftLibrary), keyEquivalent: "d")
        toggleDrafts.target = controller
        file.addItem(.separator())
        file.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileItem.submenu = file
        menu.insertItem(fileItem, at: 1)
        let accountItem = NSMenuItem()
        // An NSMenu cannot belong to two parent items. Rebuilding the main
        // menu requires a fresh submenu, rather than reattaching the old one.
        accountsMenu = makeAccountsMenu()
        accountItem.submenu = accountsMenu
        menu.addItem(accountItem)
        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Show Composer", action: #selector(showComposer), keyEquivalent: "0")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = windowMenu
        menu.addItem(windowItem)
        NSApp.windowsMenu = windowMenu
        NSApp.mainMenu = menu
    }

    @objc private func about() {
        let alert = NSAlert()
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        alert.messageText = version.map { "Minimal Bird \($0)" } ?? "Minimal Bird"
        alert.informativeText = "A little space to write, post, and get on with your day.\n\nUses X’s website in Apple WebKit. No API keys. No analytics. Drafts stay on this Mac.\n\nFree software under GNU GPL v3.0 only.\nCopyright © 2026 Minimal Bird contributors.\nProvided without warranty.\n\nInspired by Search by Office Commun.\nIndependent software, not affiliated with X."
        alert.addButton(withTitle: "OK")
        let license = Bundle.main.url(forResource: "LICENSE", withExtension: "txt")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        if license != nil { alert.addButton(withTitle: "License…") }
        if alert.runModal() == .alertSecondButtonReturn, let license {
            showLicense(license)
        }
        controller.restoreEditorFocus()
    }

    private func showLicense(_ license: String) {
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 560, height: 300))
        text.string = license
        text.isEditable = false
        text.isSelectable = true
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        text.textContainerInset = NSSize(width: 8, height: 8)
        text.textContainer?.widthTracksTextView = true
        let scroll = NSScrollView(frame: text.frame)
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = text
        text.setSelectedRange(NSRange(location: 0, length: 0))
        text.scrollRangeToVisible(NSRange(location: 0, length: 0))
        let alert = NSAlert()
        alert.messageText = "GNU General Public License v3.0"
        alert.informativeText = "You may use, modify, and share Minimal Bird under these terms. This software comes without warranty."
        alert.accessoryView = scroll
        let done = alert.addButton(withTitle: "Done")
        alert.window.initialFirstResponder = done
        // NSAlert lays out and focuses accessory views when its modal loop starts.
        // Reset the scroll position after that layout, so the license opens at its title.
        DispatchQueue.main.async {
            alert.window.makeFirstResponder(done)
            scroll.contentView.scroll(to: .zero)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        alert.runModal()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // The retained window/controller preserve the draft and WebKit process.
        return true
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func windowDidBecomeKey(_ notification: Notification) { controller?.restoreEditorFocus() }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showComposer()
        return false
    }
    @objc private func showComposer() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        controller.resume()
    }
    func applicationWillTerminate(_ notification: Notification) {
        controllers.values.forEach { $0.persistDrafts() }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminationPending else { return .terminateLater }
        terminationPending = true
        // Capture the active editor before changing the window's controller.
        let profiles = accounts.profiles.filter { $0.id == accounts.selectedID }
            + accounts.profiles.filter { $0.id != accounts.selectedID }
        Task { @MainActor in
            for profile in profiles {
                guard let candidate = controllers[profile.id] else { continue }
                displayController(candidate)
                let canLeave = await withCheckedContinuation { continuation in
                    candidate.prepareToLeave { continuation.resume(returning: $0) }
                }
                if !canLeave {
                    accounts.select(profile.id)
                    controller = candidate
                    buildMenu()
                    updateWindowTitle()
                    window.makeKeyAndOrderFront(nil)
                    controller.restoreEditorFocus()
                    terminationPending = false
                    sender.reply(toApplicationShouldTerminate: false)
                    return
                }
            }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
