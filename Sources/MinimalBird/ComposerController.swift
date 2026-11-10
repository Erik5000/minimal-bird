// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Minimal Bird contributors

import AppKit
import WebKit
import UniformTypeIdentifiers
import FocusCore

/// Shared with the web skin in focus.js (the --mb-* variables).
enum Palette {
    static let paper = NSColor(srgbRed: 0.980, green: 0.976, blue: 0.965, alpha: 1)
    static let ink = NSColor(srgbRed: 0.169, green: 0.196, blue: 0.188, alpha: 1)
    static let muted = NSColor(srgbRed: 0.502, green: 0.518, blue: 0.486, alpha: 1)
    static let accent = NSColor(srgbRed: 0.722, green: 0.286, blue: 0.180, alpha: 1)
    static let line = NSColor(srgbRed: 0.902, green: 0.894, blue: 0.863, alpha: 1)
    static let hover = NSColor(srgbRed: 0.169, green: 0.196, blue: 0.188, alpha: 0.05)
}

@MainActor
final class ComposerController: NSViewController, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    private var webView: WKWebView!
    private let cover = NSView()
    private let coverTitle = NSTextField(labelWithString: "")
    private let coverDetail = NSTextField(wrappingLabelWithString: "")
    private let coverIcon = NSImageView()
    private let coverButton = NSButton(title: "", target: nil, action: nil)
    private let spinner = NSProgressIndicator()
    private var draftsPanel: DraftsPanel!
    private var postsPanel: PostsPanel!
    private var libraryTop: NSLayoutConstraint!
    private var timeout: Timer?
    private var state = "loading"
    private var draft = false
    private var unsavedExtras = false
    private var demo = false
    private var redirects = 0
    private var lastRedirect = Date.distantPast
    private var openedAt = Date()
    private var warmOpening = false
    private var lastKeyRecovery = Date.distantPast
    private let dataStore: WKWebsiteDataStore
    private let drafts: DraftStore
    /// The saved draft the composer's text belongs to.
    private var currentDraftID: UUID?
    private var pendingDraft: Draft?
    private var restoringDraft = false
    private var capturingDraft = false
    private var captureAttempt: UUID?
    private var activeDocumentID: String?
    private var navigationGeneration = UUID()
    private var fixtureHTML: String?
    private var restorationID: UUID?
    private var restorationTextRequests = Set<Int>()
    private var restorationAddRequests = Set<Int>()
    private var protectedDraftID: UUID?
    private var saveFailed = false
    private let saveFailureMessage = "Drafts not saved. Keep this app open."
    private var persistTimer: Timer?
    private var refreshTimer: Timer?
    /// The signed-in account, as X's composer reports it.
    private var ownHandle: String?
    /// The old post the open composer updates or quotes.
    private var currentTarget: PostTarget?
    private var quoteAttempt: UUID?
    private var ownPosts: [String: OwnPost] = [:]
    /// The draft to reopen with Back to editor after My posts.
    private var draftBeforePosts: UUID?
    /// WebKit pauses list updates in a hidden view. Keep X's page drawn, under
    /// its curtain and a native view, while the app works with the post pages.
    private var webAwake = false
    /// The state to return to when X's page comes back after a release.
    private var releasedState = "composer"
    private var releaseAttempt: UUID?
    /// The space above the action bar. The web view changes after a release.
    private let webArea = NSLayoutGuide()
    private let postTimes: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    var canShowPosts: Bool { ownHandle != nil }
    var accountChanged: ((String) -> Void)?

    init(dataStore: WKWebsiteDataStore, drafts: DraftStore) {
        self.dataStore = dataStore
        self.drafts = drafts
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("Use init(dataStore:drafts:)") }

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = Palette.paper.cgColor

        draftsPanel = DraftsPanel(expanded: false)
        draftsPanel.onToggle = { [weak self] expanded in
            guard let self else { return }
            UserDefaults.standard.set(expanded, forKey: "DraftsExpanded")
            self.libraryTop.isActive = expanded
            self.webView.isHidden = expanded || !(["composer", "login", "posts"].contains(self.state) || self.webAwake)
            self.syncPostsPanel()
            self.view.layoutSubtreeIfNeeded()
            if expanded { self.view.window?.makeFirstResponder(self.draftsPanel) }
            else { self.restoreEditorFocus() }
        }
        draftsPanel.onOpen = { [weak self] id in self?.openDraft(id) }
        draftsPanel.onDelete = { [weak self] id in self?.deleteDraft(id) }
        draftsPanel.onCopy = { [weak self] id in self?.copyDraft(id) }
        draftsPanel.onSave = { [weak self] in self?.saveDraft() }
        draftsPanel.onNew = { [weak self] in self?.newPost() }
        draftsPanel.onLibrary = { [weak self] in self?.showDraftLibrary() }
        draftsPanel.onResume = { [weak self] in self?.resumeDraft() }
        draftsPanel.onPosts = { [weak self] in self?.showPosts() }

        postsPanel = PostsPanel()
        postsPanel.isHidden = true
        postsPanel.onUpdate = { [weak self] id in self?.openPost(PostTarget(kind: .reply, id: id)) }
        postsPanel.onQuote = { [weak self] id in self?.openPost(PostTarget(kind: .quote, id: id)) }
        postsPanel.onOlder = { [weak self] in self?.showOlderPosts() }

        cover.wantsLayer = true
        cover.layer?.backgroundColor = Palette.paper.cgColor
        coverIcon.contentTintColor = Palette.accent
        coverIcon.symbolConfiguration = .init(pointSize: 26, weight: .light)
        coverTitle.font = .systemFont(ofSize: 20, weight: .semibold)
        coverTitle.textColor = Palette.ink
        coverTitle.alignment = .center
        coverDetail.font = .systemFont(ofSize: 13)
        coverDetail.textColor = Palette.muted
        coverDetail.alignment = .center
        coverDetail.maximumNumberOfLines = 5
        coverButton.target = self
        coverButton.action = #selector(coverAction)
        coverButton.bezelStyle = .push
        coverButton.controlSize = .large
        coverButton.bezelColor = Palette.accent
        spinner.style = .spinning
        spinner.controlSize = .small
        let coverStack = NSStackView(views: [coverIcon, coverTitle, coverDetail, spinner, coverButton])
        coverStack.orientation = .vertical
        coverStack.alignment = .centerX
        coverStack.spacing = 12
        coverStack.setCustomSpacing(6, after: coverTitle)
        coverStack.setCustomSpacing(20, after: coverDetail)
        cover.addSubview(coverStack)
        for child in [cover, postsPanel!, draftsPanel!] {
            child.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(child)
        }
        coverStack.translatesAutoresizingMaskIntoConstraints = false
        libraryTop = draftsPanel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor)
        view.addLayoutGuide(webArea)
        NSLayoutConstraint.activate([
            webArea.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            webArea.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webArea.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webArea.bottomAnchor.constraint(equalTo: draftsPanel.topAnchor),
            draftsPanel.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            draftsPanel.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            draftsPanel.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            cover.topAnchor.constraint(equalTo: webArea.topAnchor),
            cover.leadingAnchor.constraint(equalTo: webArea.leadingAnchor),
            cover.trailingAnchor.constraint(equalTo: webArea.trailingAnchor),
            cover.bottomAnchor.constraint(equalTo: webArea.bottomAnchor),
            postsPanel.topAnchor.constraint(equalTo: webArea.topAnchor),
            postsPanel.leadingAnchor.constraint(equalTo: webArea.leadingAnchor),
            postsPanel.trailingAnchor.constraint(equalTo: webArea.trailingAnchor),
            postsPanel.bottomAnchor.constraint(equalTo: webArea.bottomAnchor),
            coverStack.centerXAnchor.constraint(equalTo: cover.centerXAnchor),
            coverStack.centerYAnchor.constraint(equalTo: cover.centerYAnchor, constant: -16),
            coverStack.widthAnchor.constraint(equalTo: cover.widthAnchor, constant: -64),
            coverDetail.widthAnchor.constraint(lessThanOrEqualToConstant: 340),
            coverIcon.heightAnchor.constraint(equalToConstant: 36)
        ])
        installWebView()
        refreshDrafts()
    }

    /// Adds a web view without a page. It starts no web process until it loads one.
    private func installWebView() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        configuration.userContentController.add(WeakFocusHandler(self), name: "focus")
        webView = WKWebView(frame: .zero, configuration: configuration)
        installUserScripts()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsLinkPreview = false
        // A Safari-compatible UA avoids embedded-browser fallback pages. WebKit
        // still provides the real engine and the normal website session.
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"
        webView.underPageBackgroundColor = Palette.paper
        webView.isHidden = true
        webView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(webView, positioned: .below, relativeTo: cover)
        // In a wide view X opens its composer as a dialog over the page behind
        // it, and the next full page load can stay blank. One column keeps X in
        // the full-page composer layout that the app is checked against.
        let fillWidth = webView.widthAnchor.constraint(equalTo: webArea.widthAnchor)
        fillWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: webArea.topAnchor),
            webView.bottomAnchor.constraint(equalTo: webArea.bottomAnchor),
            webView.centerXAnchor.constraint(equalTo: webArea.centerXAnchor),
            webView.widthAnchor.constraint(lessThanOrEqualToConstant: 640),
            webView.widthAnchor.constraint(lessThanOrEqualTo: webArea.widthAnchor),
            fillWidth
        ])
    }

    /// focus.js reads the handle once at document start. A handle change
    /// therefore takes effect with the next page the app loads.
    private func installUserScripts() {
        let scripts = webView.configuration.userContentController
        scripts.removeAllUserScripts()
        var sources: [String] = []
        if CommandLine.arguments.contains("--diagnose") { sources.append("window.__minimalBirdDiagnose = true;") }
        if let ownHandle, NavigationPolicy.postsURL(handle: ownHandle) != nil { // Letters, digits and _ only.
            sources.append("window.__minimalBirdOwnHandle = '\(ownHandle)';")
        }
        if let source = Resource.read("focus", extension: "js") { sources.append(source) }
        for source in sources {
            scripts.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
    }

    private func setOwnHandle(_ handle: String?) {
        guard handle != ownHandle else { return }
        ownHandle = handle
        installUserScripts()
        syncPostsPanel()
    }

    private func syncPostsPanel() {
        postsPanel?.isHidden = state != "posts" || draftsExpanded
        draftsPanel?.updatePostsAction(canShow: canShowPosts, showing: state == "posts")
    }

    // WebKit sends key events the page did not mark as handled back up the
    // responder chain. X's editor inserts typed text itself, so WebKit reports
    // ordinary keystrokes as unhandled; without this, NSWindow answers each one
    // with the system alert sound. If focus had drifted away from the editor,
    // the first stray key brings it back.
    override func keyDown(with event: NSEvent) {
        guard !event.modifierFlags.contains(.command), Date().timeIntervalSince(lastKeyRecovery) > 1 else { return }
        lastKeyRecovery = Date()
        restoreEditorFocus()
    }

    func start(demo: Bool = false) {
        fixtureHTML = nil
        self.demo = demo
        _ = view
        if demo {
            draftsPanel.setExpanded(false)
            showCover(title: "A quiet place to write.", detail: "Sign in to X to start. Your feed stays out of sight.", symbol: "square.and.pencil", button: "Open X")
        } else {
            loadComposer()
            if !drafts.drafts.isEmpty && UserDefaults.standard.bool(forKey: "DraftsExpanded") {
                draftsPanel.setExpanded(true)
            }
        }
    }

    /// Self-test only: shows a synthetic composer page instead of X.
    func showFixture(_ html: String) {
        _ = view
        fixtureHTML = html
        state = "loading"
        webView.loadHTMLString(html, baseURL: NavigationPolicy.composerURL)
    }

    /// Self-test only: the synthetic page for the next load, at its real address.
    func setFixture(_ html: String) { fixtureHTML = html }

    private func loadPage(_ url: URL) {
        if let fixtureHTML { webView.loadHTMLString(fixtureHTML, baseURL: url) }
        else { webView.load(URLRequest(url: url)) }
    }

    /// Self-test only: the window with the web content drawn in, since a
    /// view snapshot cannot capture WebKit's separate rendering process.
    func snapshotWindow() async -> NSBitmapImageRep? {
        guard let frameView = view.window?.contentView?.superview,
              let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) else { return nil }
        frameView.cacheDisplay(in: frameView.bounds, to: rep)
        guard !webView.isHidden, cover.isHidden, postsPanel.isHidden, let page = try? await webView.takeSnapshot(configuration: nil) else { return rep }
        let rect = webView.convert(webView.bounds, to: frameView)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        page.draw(in: rect)
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    private func showCover(title: String, detail: String, symbol: String, button: String? = nil, loading: Bool = false) {
        webView.isHidden = !webAwake
        cover.isHidden = false
        syncPostsPanel()
        coverTitle.stringValue = title
        coverDetail.stringValue = detail
        coverDetail.isHidden = detail.isEmpty
        coverIcon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        coverButton.title = button ?? "Try again"
        coverButton.isHidden = button == nil
        spinner.isHidden = !loading
        if loading { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
    }

    /// Loads a fresh composer document. Its text is either already saved in
    /// Drafts or waiting in `pendingDraft`, so it never inherits a draft.
    /// With a target, X's own reply or quote composer opens for that post.
    private func loadComposer(target: PostTarget? = nil) {
        var url = NavigationPolicy.composerURL
        if let target {
            let linked = target.kind == .reply ? NavigationPolicy.replyURL(to: target.id)
                : ownHandle.flatMap { NavigationPolicy.statusURL(handle: $0, id: target.id) }
            guard let linked else {
                pendingDraft = nil
                draftsPanel.flash("Wait for X to finish opening, then try again.")
                return
            }
            url = linked
        }
        beginLoad(target: target, awake: target?.kind == .quote, title: target == nil ? "Opening X…" : "Opening your post…")
        loadPage(url)
        armTimeout()
    }

    private func beginLoad(target: PostTarget?, awake: Bool, title: String) {
        activeDocumentID = nil
        navigationGeneration = UUID()
        restorationID = nil
        restoringDraft = false
        protectedDraftID = nil
        draft = false
        unsavedExtras = false
        currentDraftID = nil
        currentTarget = target
        quoteAttempt = nil
        webAwake = awake
        refreshDrafts()
        state = "loading"
        openedAt = Date()
        warmOpening = false
        showCover(title: title, detail: "", symbol: "square.and.pencil", loading: true)
    }

    private func armTimeout() {
        timeout?.invalidate()
        timeout = Timer.scheduledTimer(withTimeInterval: 25, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.state == "loading" else { return }
                if self.webAwake {
                    self.showCover(title: "Your post didn’t open.", detail: "X hasn’t shown this page. Go back and try again; if it persists, X may have changed its layout.",
                        symbol: "eye.slash", button: "Back to writing")
                    return
                }
                self.showCover(title: "Your feed stays out of sight.",
                    detail: "X hasn’t shown a recognizable sign-in form or composer. Try again; if it persists, X may have changed its layout.",
                    symbol: "eye.slash", button: "Try again")
            }
        }
    }

    @objc private func coverAction() {
        demo = false
        if state == "error" { reloadKeepingText() } else { newPost() }
    }

    func resume() {
        if state == "released" { wakeWebContent() }
        else if state == "finished" { newPost() }
        else { restoreEditorFocus() }
    }

    /// Returning from native menus/sheets can leave a button or the window as
    /// first responder. Restore both AppKit and DOM focus, keeping the selection.
    func restoreEditorFocus() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.state == "composer", !self.webView.isHidden,
                  !self.draftsPanel.isExpanded, !self.capturingDraft,
                  let window = self.viewIfLoaded?.window, window.isKeyWindow,
                  window.attachedSheet == nil else { return }
            window.makeFirstResponder(self.webView)
            self.webView.evaluateJavaScript("window.__minimalBirdFocusEditor?.() ?? false", completionHandler: nil)
        }
    }

    @objc func newPost() {
        afterSavingComposer(discardExtras: true) { [weak self] in
            guard let self else { return }
            self.pendingDraft = nil
            self.draftsPanel.setExpanded(false)
            self.loadComposer()
        }
    }

    /// Save and leave the editor only after reading its current text and
    /// confirming the atomic disk write. Never rely on a queued autosave.
    @objc func saveDraft() {
        afterSavingComposer(discardExtras: false) { [weak self] in
            guard let self else { return }
            self.draftsPanel.setExpanded(true)
            self.draftsPanel.status = self.currentDraftID == nil ? "No text to save. Choose New draft to start writing."
                : self.unsavedExtras ? "Text saved. Attachments remain in the open editor." : "Saved to Draft library."
        }
    }

    @objc func showDraftLibrary() {
        afterSavingComposer(discardExtras: false) { [weak self] in self?.draftsPanel.setExpanded(true) }
    }

    /// Saves the current text, then shows the account's own posts.
    @objc func showPosts() {
        afterSavingComposer(discardExtras: true) { [weak self] in
            guard let self else { return }
            self.draftsPanel.setExpanded(false)
            self.loadPosts()
        }
    }

    private func loadPosts() {
        guard let ownHandle, let url = NavigationPolicy.postsURL(handle: ownHandle) else {
            draftsPanel.flash("Wait for X to finish opening, then try again.")
            return
        }
        let leavingPosts = state == "posts" || (state == "released" && releasedState == "posts")
        draftBeforePosts = currentDraftID ?? (leavingPosts ? draftBeforePosts : nil)
        pendingDraft = nil
        ownPosts = [:]
        postsPanel.update([])
        beginLoad(target: nil, awake: true, title: "Opening your posts…")
        loadPage(url)
        armTimeout()
    }

    private func openPost(_ target: PostTarget) {
        guard !capturingDraft, !restoringDraft else { return }
        pendingDraft = nil
        if target.kind == .quote && state == "posts" { quoteFromList(target) }
        else { loadComposer(target: target) }
    }

    /// X's list is already loaded behind the native rows, so Quote needs no
    /// new page. If X has dropped that post from its list, open the post's page.
    private func quoteFromList(_ target: PostTarget) {
        let attempt = UUID()
        quoteAttempt = attempt
        currentTarget = target
        currentDraftID = nil
        state = "loading"
        showCover(title: "Opening your post…", detail: "", symbol: "square.and.pencil", loading: true)
        armTimeout()
        webView.callAsyncJavaScript("return await window.__minimalBirdOpenQuote(id, 400)", arguments: ["id": target.id], in: nil, in: .page) { [weak self] result in
            guard let self, self.quoteAttempt == attempt else { return }
            if (try? result.get()) as? String == "ok" { return } // focus.js reports the composer.
            self.quoteAttempt = nil
            self.loadComposer(target: target)
        }
    }

    private func mergeOwnPosts(_ value: Any?) {
        guard let rows = value as? [[String: Any]] else { return }
        for row in rows.prefix(100) {
            guard let id = row["id"] as? String, NavigationPolicy.replyURL(to: id) != nil else { continue }
            ownPosts[id] = OwnPost(id: id, text: String((row["text"] as? String ?? "").prefix(30_000)),
                                   time: (row["time"] as? String).flatMap(postTimes.date(from:)),
                                   media: row["media"] as? Bool ?? false)
        }
        postsPanel.update(ownPosts.values.sorted {
            ($0.time ?? .distantPast, $0.id) > ($1.time ?? .distantPast, $1.id)
        })
    }

    /// X adds older posts when its page reaches the end of the list.
    private func showOlderPosts() {
        let before = ownPosts.count
        webView.evaluateJavaScript("window.__minimalBirdShowOlderPosts?.() ?? false", completionHandler: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self, self.state == "posts", self.ownPosts.count == before else { return }
            self.draftsPanel.flash("No older posts appeared.")
        }
    }

    /// X's post page is open under the curtain. Ask it for its quote composer.
    private func openPendingQuote() {
        guard let target = currentTarget, target.kind == .quote else { redirectToComposer(); return }
        guard quoteAttempt == nil else { return }
        let attempt = UUID()
        quoteAttempt = attempt
        webView.callAsyncJavaScript("return await window.__minimalBirdOpenQuote(id)", arguments: ["id": target.id], in: nil, in: .page) { [weak self] result in
            guard let self, self.quoteAttempt == attempt else { return }
            if (try? result.get()) as? String == "ok" { return } // X opens the composer; focus.js reports it.
            self.draftsPanel.flash("X didn’t open this post. Try again.")
            self.currentTarget = nil
            self.loadPosts()
        }
    }

    private func returnToComposer() {
        let saved = draftBeforePosts.flatMap { drafts.draft($0) }
        draftBeforePosts = nil
        pendingDraft = saved
        draftsPanel.setExpanded(false)
        loadComposer(target: saved?.target)
    }

    @objc func resumeDraft() {
        guard !capturingDraft, !restoringDraft else { return }
        if state == "released" {
            if releasedState == "posts" { state = "posts"; returnToComposer(); return }
            draftsPanel.setExpanded(false)
            wakeWebContent()
            return
        }
        if state == "posts" { returnToComposer(); return }
        draftsPanel.setExpanded(false)
        restoreEditorFocus()
    }

    private func afterSavingComposer(discardExtras: Bool, action: @escaping () -> Void) {
        captureAndSaveComposer(discardExtras: discardExtras) { saved in
            if saved { action() }
        }
    }

    /// Quitting must wait for WebKit's queued native input before allowing
    /// the process to exit. Every failure cancels the pending termination.
    func prepareToLeave(completion: @escaping (Bool) -> Void) {
        captureAndSaveComposer(discardExtras: true, completion: completion)
    }

    private func captureAndSaveComposer(discardExtras: Bool, completion: @escaping (Bool) -> Void) {
        guard !capturingDraft, !restoringDraft else {
            draftsPanel.flash("Wait for the draft to finish opening or saving.")
            completion(false)
            return
        }
        guard state == "composer", !draftsPanel.isExpanded else {
            completion(persistDrafts() && (!discardExtras || confirmDiscard()))
            return
        }
        capturingDraft = true
        let attempt = UUID()
        captureAttempt = attempt
        refreshDrafts()
        draftsPanel.status = "Saving draft…"
        let document = activeDocumentID
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.captureAttempt == attempt else { return }
            self.captureAttempt = nil
            self.capturingDraft = false
            self.draftsPanel.status = "The editor did not respond. Your draft is still open. Try Save draft again."
            self.refreshDrafts()
            completion(false)
        }
        webView.callAsyncJavaScript("return await window.__minimalBirdReadDraft?.() ?? null", arguments: [:], in: nil, in: .page) { [weak self] result in
            guard let self, self.captureAttempt == attempt else { return }
            self.captureAttempt = nil
            self.capturingDraft = false
            defer { self.refreshDrafts() }
            guard self.activeDocumentID == document,
                  let snapshot = (try? result.get()) as? [String: Any], snapshot["documentID"] as? String == document,
                  let posts = snapshot["posts"] as? [String], !posts.isEmpty, posts.count <= 50 else {
                self.draftsPanel.status = "Could not read the editor. Your draft is still open. Try Save draft again."
                self.restoreEditorFocus()
                completion(false)
                return
            }
            self.draft = snapshot["dirty"] as? Bool ?? false
            self.unsavedExtras = snapshot["extras"] as? Bool ?? false
            self.autosave(posts)
            if !Draft.hasText(posts) { self.currentDraftID = nil }
            guard self.persistDrafts(), !discardExtras || self.confirmDiscard() else {
                self.restoreEditorFocus()
                completion(false)
                return
            }
            self.draftsPanel.status = self.currentDraftID == nil ? "" : "All changes saved on this Mac."
            completion(true)
        }
    }

    @objc func reloadPage() {
        if state == "released" { wakeWebContent(); return }
        if state == "posts" { loadPosts(); return }
        afterSavingComposer(discardExtras: true) { [weak self] in self?.reloadKeepingText() }
    }

    /// Reloads X and puts the composer's saved text back afterwards.
    private func reloadKeepingText() {
        redirects = 0
        if pendingDraft == nil, let id = currentDraftID, let saved = drafts.draft(id) { pendingDraft = saved }
        currentDraftID = nil
        loadComposer(target: currentTarget)
    }

    @objc func toggleDrafts() {
        if draftsPanel.isExpanded { resumeDraft() } else { showDraftLibrary() }
    }

    var draftsExpanded: Bool { draftsPanel?.isExpanded ?? false }

    /// Confirm removal of content after capturing the editor. This only
    /// flushes the native cache; callers that leave must capture it first.
    func confirmDiscard() -> Bool {
        guard !restoringDraft, !capturingDraft else {
            draftsPanel.flash("Wait for the draft to open.")
            return false
        }
        guard persistDrafts() else {
            let alert = NSAlert()
            alert.messageText = "Your drafts could not be saved."
            alert.informativeText = "Your text is still in this app. Keep it open and check the free space and permissions on this Mac. You can copy your drafts before trying again."
            alert.addButton(withTitle: "Keep writing")
            alert.addButton(withTitle: "Copy all drafts")
            if alert.runModal() == .alertSecondButtonReturn {
                copyText(drafts.drafts.map { $0.posts.joined(separator: "\n\n") }.joined(separator: "\n\n---\n\n"))
            }
            restoreEditorFocus()
            return false
        }
        guard draft, unsavedExtras else { return true }
        let alert = NSAlert()
        alert.messageText = "Remove attachments?"
        alert.informativeText = drafts.draft(currentDraftID ?? UUID()) != nil
            ? "Your text is saved in Drafts, but attached media and polls can’t be kept and will be removed."
            : "Attached media and polls can’t be kept in Drafts and will be removed."
        alert.addButton(withTitle: "Keep writing")
        alert.addButton(withTitle: "Remove and continue")
        let discard = alert.runModal() == .alertSecondButtonReturn
        if !discard { restoreEditorFocus() }
        return discard
    }

    @objc func signOut() {
        afterSavingComposer(discardExtras: true) { [weak self] in self?.clearSession() }
    }

    private func clearSession() {
        let alert = NSAlert()
        alert.messageText = "Sign out of this app?"
        alert.informativeText = "This removes Minimal Bird’s cookies and website data for this account. Your drafts stay on this Mac, and your other browsers stay signed in."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Sign out")
        guard alert.runModal() == .alertSecondButtonReturn else { restoreEditorFocus(); return }
        timeout?.invalidate()
        webView.stopLoading()
        webView.loadHTMLString("", baseURL: nil)
        draft = false
        currentDraftID = nil
        pendingDraft = nil
        currentTarget = nil
        draftBeforePosts = nil
        webAwake = false
        setOwnHandle(nil)
        state = "signingOut"
        showCover(title: "Clearing your session…", detail: "", symbol: "person.crop.circle", loading: true)
        webView.configuration.websiteDataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) { [weak self] in
            self?.redirects = 0
            self?.loadComposer()
        }
    }

    // MARK: Releasing X's page

    var isReleased: Bool { state == "released" }
    var releaseInProgress: Bool { releaseAttempt != nil }

    /// Frees X's page and its web process while the window stays out of sight.
    /// Attachments and polls exist only in the page, so they keep it loaded.
    /// The caller tries again later when this stops without a release.
    func releaseWebContent() {
        guard releaseAttempt == nil, !["released", "loading", "login", "postTarget", "signingOut"].contains(state),
              !restoringDraft, !capturingDraft, pendingDraft == nil else { return }
        guard state == "composer" else { discardPage(); return }
        let attempt = UUID()
        releaseAttempt = attempt
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            if self?.releaseAttempt == attempt { self?.releaseAttempt = nil }
        }
        // WebKit delays timers in a hidden page, and no typed input can still
        // be on its way. Read the editor directly, without the settling wait.
        let document = activeDocumentID
        webView.callAsyncJavaScript("return window.__minimalBirdDraftSnapshot?.() ?? null", arguments: [:], in: nil, in: .page) { [weak self] result in
            guard let self, self.releaseAttempt == attempt else { return }
            self.releaseAttempt = nil
            guard self.state == "composer", self.activeDocumentID == document, !self.restoringDraft, !self.capturingDraft,
                  let snapshot = (try? result.get()) as? [String: Any], snapshot["documentID"] as? String == document,
                  snapshot["extras"] as? Bool == false,
                  let posts = snapshot["posts"] as? [String], !posts.isEmpty, posts.count <= 50 else { return }
            self.autosave(posts)
            if !Draft.hasText(posts) { self.currentDraftID = nil }
            guard self.persistDrafts() else { return }
            self.discardPage()
        }
    }

    /// The window came back while the editor was being read.
    func cancelRelease() { releaseAttempt = nil }

    /// Keeps the draft, target and handle. Only the page leaves.
    private func discardPage() {
        timeout?.invalidate()
        activeDocumentID = nil
        navigationGeneration = UUID()
        quoteAttempt = nil
        webAwake = false
        draft = false
        unsavedExtras = false
        releasedState = state
        state = "released"
        let page = webView!
        page.stopLoading()
        page.navigationDelegate = nil
        page.uiDelegate = nil
        page.configuration.userContentController.removeScriptMessageHandler(forName: "focus")
        page.configuration.userContentController.removeAllUserScripts()
        page.removeFromSuperview()
        // AppKit kept the old web view until the first responder changed.
        view.window?.makeFirstResponder(nil)
        installWebView()
        showCover(title: "Opening X…", detail: "", symbol: "square.and.pencil")
        refreshDrafts()
    }

    /// Loads X again after a release and puts the saved text back.
    func wakeWebContent() {
        // The library is native. X loads when the person leaves it.
        guard state == "released", !draftsExpanded else { return }
        state = releasedState
        if state == "posts" { loadPosts() } else { reloadKeepingText() }
    }

    // MARK: Drafts

    private func refreshDrafts() {
        draftsPanel?.update(drafts: drafts.drafts, current: currentDraftID)
        draftsPanel?.updateActions(canSave: state == "composer", busy: restoringDraft || capturingDraft)
    }

    private func schedulePersist() {
        // Keep the first deadline. Repeated keystrokes must not postpone a save.
        guard persistTimer == nil else { return }
        let timer = Timer(timeInterval: 0.6, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.persistDrafts() }
        }
        persistTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    @discardableResult
    func persistDrafts() -> Bool {
        persistTimer?.invalidate()
        persistTimer = nil
        switch drafts.persist() {
        case .success:
            if saveFailed || (currentDraftID != nil && !draftsExpanded) { draftsPanel?.status = "All changes saved on this Mac." }
            saveFailed = false
            return true
        case .failure:
            saveFailed = true
            draftsPanel?.status = saveFailureMessage
            return false
        }
    }

    private func autosave(_ posts: [String]) {
        guard !restoringDraft, !capturingDraft, !draftsExpanded, state == "composer" else { return }
        if Draft.hasText(posts) {
            if let id = currentDraftID, drafts.draft(id)?.posts == posts { return }
            currentDraftID = drafts.save(posts, id: currentDraftID, preserving: protectedDraftID, target: currentTarget)
        } else { return } // Only the explicit Delete action removes saved text.
        if !saveFailed { draftsPanel.status = "Saving changes…" }
        schedulePersist()
        // Typing saves continuously; the list catches up a moment later.
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.refreshDrafts() }
        }
    }

    private func deleteDraft(_ id: UUID) {
        guard !capturingDraft, !restoringDraft, let saved = drafts.draft(id) else { return }
        let alert = NSAlert()
        alert.messageText = "Delete this draft?"
        alert.informativeText = "\(saved.preview)\n\nThis removes the saved text from this Mac."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Delete draft")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        drafts.remove(id)
        guard persistDrafts() else {
            drafts.save(saved.posts, id: saved.id, now: saved.updated, target: saved.target)
            refreshDrafts()
            return
        }
        if currentDraftID == id { pendingDraft = nil; loadComposer() }
        draftsPanel.status = "Draft deleted."
        refreshDrafts()
        restoreEditorFocus()
    }

    private func copyText(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func copyDraft(_ id: UUID) {
        guard let saved = drafts.draft(id) else { return }
        copyText(saved.posts.joined(separator: "\n\n"))
        draftsPanel.flash("Draft text copied")
        restoreEditorFocus()
    }

    private func openDraft(_ id: UUID) {
        guard drafts.draft(id) != nil else { return }
        if id == currentDraftID, state == "composer", draftsPanel.isExpanded { resumeDraft(); return }
        afterSavingComposer(discardExtras: true) { [weak self] in self?.restoreSavedDraft(id) }
    }

    private func restoreSavedDraft(_ id: UUID) {
        guard let saved = drafts.draft(id) else { return }
        if saved.target?.kind == .quote && ownHandle == nil {
            draftsPanel.flash("Wait for X to finish opening, then try again.")
            return
        }
        draftsPanel.setExpanded(false)
        pendingDraft = saved
        if state == "composer" && !unsavedExtras && currentTarget == saved.target {
            insertPendingDraft()
        } else if state != "loading" || demo || currentTarget != saved.target {
            demo = false
            currentDraftID = nil
            loadComposer(target: saved.target)
        } // While loading, the draft is inserted once the composer appears.
    }

    /// Puts a saved draft into X's editor. The composer's previous text stays
    /// in its own draft; edits from here on update the opened one.
    private func insertPendingDraft() {
        guard let saved = pendingDraft, state == "composer", !restoringDraft else { return }
        restoringDraft = true
        let attempt = UUID()
        restorationID = attempt
        restorationTextRequests = []
        restorationAddRequests = []
        currentDraftID = nil
        protectedDraftID = saved.id
        refreshDrafts()
        view.window?.makeFirstResponder(webView)
        webView.callAsyncJavaScript("return await window.__minimalBirdInsertPosts(posts, restoreToken)",
                                    arguments: ["posts": saved.posts, "restoreToken": attempt.uuidString], in: nil, in: .page) { [weak self] result in
            guard let self, self.restorationID == attempt else { return }
            self.restorationID = nil
            self.restoringDraft = false
            let outcome = (try? result.get()) as? String ?? "failed"
            if CommandLine.arguments.contains("--diagnose") { print("Draft restore outcome: \(outcome)"); fflush(stdout) }
            switch outcome {
            case "ok":
                self.currentDraftID = saved.id
                self.protectedDraftID = nil
                self.pendingDraft = nil
                self.draft = true
                self.draftsPanel.status = self.saveFailed ? self.saveFailureMessage : ""
                self.draftsPanel.flash("Draft opened")
                self.restoreEditorFocus()
            case "partial":
                // The visible prefix becomes a separate draft. The original
                // stays complete, even at the store's size limit.
                self.pendingDraft = nil
                self.draftsPanel.status = "Partial thread. Full text stays in Drafts."
                self.restoreEditorFocus()
            case "reload":
                // The composer holds a thread; start from a clean one, then insert.
                self.currentDraftID = nil
                self.loadComposer(target: self.currentTarget)
            default:
                self.pendingDraft = nil
                self.currentDraftID = nil
                self.draftsPanel.flash("Couldn’t open the draft here. It’s still in Drafts.")
            }
            if outcome != "reload" {
                // The final JS report can arrive before the async callback.
                // Request it again after choosing the correct draft identity.
                self.webView.evaluateJavaScript("window.__minimalBirdReportDraft?.()", completionHandler: nil)
            }
            self.refreshDrafts()
        }
    }

    // MARK: Messages from focus.js

    /// Use WebKit's native text-input path so X updates its controlled editor
    /// model. Synthetic paste or DOM editing can be rolled back by React. The
    /// page can request only text from the draft the user is currently opening.
    private func insertRestorationText(_ body: [String: Any]) {
        if CommandLine.arguments.contains("--diagnose") {
            print("Draft input request: restoring=\(restoringDraft), state=\(state), key=\(webView.window?.isKeyWindow ?? false), responder=\(String(describing: webView.window?.firstResponder.map { type(of: $0) }))")
            fflush(stdout)
        }
        guard restoringDraft, state == "composer", let attempt = restorationID,
              body["token"] as? String == attempt.uuidString,
              let index = body["index"] as? Int, let saved = pendingDraft,
              saved.posts.indices.contains(index), !restorationTextRequests.contains(index),
              let window = webView.window else { return }
        window.makeFirstResponder(webView)
        guard let input = window.firstResponder as? NSTextInputClient else { return }
        restorationTextRequests.insert(index)
        input.insertText(saved.posts[index], replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    /// X's press handler needs a native activation when restoring a thread.
    /// The script focuses only Add post before making this scoped request.
    private func addRestorationPost(_ body: [String: Any]) {
        guard restoringDraft, state == "composer", let attempt = restorationID,
              body["token"] as? String == attempt.uuidString,
              let index = body["index"] as? Int, index > 0, let saved = pendingDraft,
              saved.posts.indices.contains(index), !restorationAddRequests.contains(index),
              let window = webView.window else { return }
        window.makeFirstResponder(webView)
        restorationAddRequests.insert(index)
        for type: NSEvent.EventType in [.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49) else { continue }
            window.sendEvent(event)
        }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame,
              let url = message.frameInfo.request.url,
              NavigationPolicy.destination(for: url, ownHandle: ownHandle) != .blocked,
              let body = message.body as? [String: Any], let next = body["state"] as? String,
              state != "signingOut" else { return }
        guard let activeDocumentID, body["documentID"] as? String == activeDocumentID else { return }
        if next == "draft" {
            guard state == "composer", !draftsExpanded, !capturingDraft else { return }
            draft = body["dirty"] as? Bool ?? false
            unsavedExtras = body["extras"] as? Bool ?? false
            if let posts = body["posts"] as? [String], posts.count <= 50 { autosave(posts) }
            return
        }
        if next == "restoreText" {
            insertRestorationText(body)
            return
        }
        if next == "restoreAdd" {
            addRestorationPost(body)
            return
        }
        if next == "diagnostic" {
            if CommandLine.arguments.contains("--diagnose"), let details = body["details"] as? String {
                print("Authoring: \(details)"); fflush(stdout)
            }
            return
        }
        if next == "composer", let handle = body["handle"] as? String,
           handle.range(of: "^@[A-Za-z0-9_]{1,15}$", options: .regularExpression) != nil {
            accountChanged?(handle)
            setOwnHandle(handle)
        }
        let previousState = state
        if next == "finished" && (draftsExpanded || capturingDraft) { return }
        state = next
        defer {
            draftsPanel.updateActions(canSave: state == "composer", busy: restoringDraft || capturingDraft)
            syncPostsPanel()
        }
        if CommandLine.arguments.contains("--diagnose") { print("Focus state: \(next), elapsed: \(String(format: "%.2f", Date().timeIntervalSince(openedAt)))s, warm: \(warmOpening)"); fflush(stdout) }
        switch next {
        case "posts":
            timeout?.invalidate()
            cover.isHidden = true
            webView.isHidden = draftsExpanded // It stays awake under the native list.
            mergeOwnPosts(body["posts"])
            if previousState != "posts" { draftsPanel.status = saveFailed ? saveFailureMessage : "" }
        case "postTarget":
            // X left the composer without a post. Return to the list.
            if previousState == "composer" { loadPosts() } else { openPendingQuote() }
        case "composer", "login":
            timeout?.invalidate()
            webAwake = false
            cover.isHidden = true
            webView.isHidden = draftsExpanded
            draftsPanel.status = saveFailed ? saveFailureMessage : next == "login" ? "Sign in with your X username and password." : ""
            if next == "composer", previousState != "composer" {
                if pendingDraft != nil { insertPendingDraft() } else { restoreEditorFocus() }
            }
        case "finished":
            timeout?.invalidate()
            webAwake = false
            // X closed the composer after Post; the posted text leaves Drafts.
            if let id = currentDraftID { drafts.remove(id); persistDrafts() }
            currentDraftID = nil
            currentTarget = nil
            draft = false
            unsavedExtras = false
            refreshDrafts()
            showCover(title: "Posted. Back to your day.", detail: "X took it from here.", symbol: "checkmark.circle", button: "New post")
            draftsPanel.status = ""
        case "needsComposer":
            redirectToComposer()
        case "blocked":
            showCover(title: "Stay with your thought.", detail: "Only the composer is available here.", symbol: "eye.slash", button: "Back to writing")
        default:
            showCover(title: currentTarget != nil ? "Opening your post…" : webAwake ? "Opening your posts…" : "Opening composer…",
                      detail: "", symbol: "square.and.pencil", loading: true)
            armTimeout()
        }
    }

    private func redirectToComposer() {
        if Date().timeIntervalSince(lastRedirect) > 20 { redirects = 0 }
        redirects += 1
        lastRedirect = Date()
        guard redirects <= 3 else {
            state = "blocked"
            webAwake = false
            showCover(title: "X needs a moment.", detail: "The composer keeps redirecting. Please try again shortly.", symbol: "arrow.clockwise", button: "Try again")
            return
        }
        loadComposer(target: currentTarget)
    }

    // MARK: WebKit

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if CommandLine.arguments.contains("--diagnose"), let url = navigationAction.request.url {
            // Never log query strings, fragments, credentials, or form contents.
            print("Navigation: \(url.scheme ?? "")://\(url.host ?? "")\(url.path)")
            fflush(stdout)
        }
        guard navigationAction.targetFrame?.isMainFrame != false else {
            decisionHandler(.allow) // Authentication challenges may use embedded frames.
            return
        }
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        if url.absoluteString == "about:blank" { decisionHandler(.allow); return }
        let destination = NavigationPolicy.destination(for: url, ownHandle: ownHandle)
        // A post page loads only when the app asked for it to quote that post.
        let quotePageExpected = state == "loading" && currentTarget?.kind == .quote && quoteAttempt == nil
        guard destination != .blocked, destination != .postTarget || quotePageExpected else {
            draftsPanel.flash("Only posting is available in Minimal Bird.")
            decisionHandler(.cancel)
            return
        }
        if navigationAction.targetFrame == nil {
            decisionHandler(.cancel)
            webView.load(navigationAction.request)
            return
        }
        webView.isHidden = !webAwake
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard state != "signingOut" else { return }
        activeDocumentID = nil
        navigationGeneration = UUID()
        state = "loading"
        showCover(title: "Opening X…", detail: "", symbol: "square.and.pencil", loading: true)
        armTimeout()
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        bindCurrentDocument()
    }

    private func bindCurrentDocument() {
        let generation = navigationGeneration
        webView.evaluateJavaScript("window.__minimalBirdDocumentID ?? null") { [weak self] value, _ in
            guard let self, self.navigationGeneration == generation, let id = value as? String,
                  self.activeDocumentID != id else { return }
            self.activeDocumentID = id
            self.webView.evaluateJavaScript("window.__minimalBirdRefresh?.()", completionHandler: nil)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        bindCurrentDocument()
        guard CommandLine.arguments.contains("--diagnose") else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard let self else { return }
            let value = try? await self.webView.evaluateJavaScript("JSON.stringify({surfaces:document.querySelectorAll('[data-mb-surface]').length,editors:document.querySelectorAll('[contenteditable=true]').length})")
            print("Native state: \(self.state); layout: \(value ?? "unavailable")")
            fflush(stdout)
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failed(error) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed(error) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        state = "error"
        draft = false
        unsavedExtras = false
        showCover(title: "Your writing space paused.", detail: "The web process stopped. Your text is safe in Drafts; reload to reconnect to X.", symbol: "arrow.clockwise", button: "Reload")
    }

    private func failed(_ error: Error) {
        guard (error as NSError).code != NSURLErrorCancelled else { return }
        timeout?.invalidate()
        state = "error"
        draft = false
        unsavedExtras = false
        showCover(title: "Couldn’t reach X.", detail: error.localizedDescription, symbol: "wifi.slash", button: "Try again")
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image, .movie]
        guard let window = view.window else { completionHandler(nil); return }
        panel.beginSheetModal(for: window) { [weak self] result in
            completionHandler(result == .OK ? panel.urls : nil)
            self?.restoreEditorFocus()
        }
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = "X"
        alert.informativeText = message
        alert.runModal()
        completionHandler()
        restoreEditorFocus()
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = "X"
        alert.informativeText = message
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        completionHandler(alert.runModal() == .alertFirstButtonReturn)
        restoreEditorFocus()
    }
}

/// WKUserContentController retains handlers; keep that ownership from retaining
/// the controller and its web view after a session is released.
@MainActor
private final class WeakFocusHandler: NSObject, WKScriptMessageHandler {
    private weak var target: ComposerController?
    init(_ target: ComposerController) { self.target = target }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}

enum Resource {
    static func read(_ name: String, extension ext: String) -> String? {
        guard let url = Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Resources") else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }
}
