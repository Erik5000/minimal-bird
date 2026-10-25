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
    /// Whether this composer has shown text, so a cleared editor deletes its draft
    /// but a freshly loaded, still-empty composer never does.
    private var composerHadText = false
    private var pendingDraft: Draft?
    private var restoringDraft = false
    private var persistTimer: Timer?
    private var refreshTimer: Timer?
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

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        configuration.userContentController.add(WeakFocusHandler(self), name: "focus")
        if CommandLine.arguments.contains("--diagnose") {
            configuration.userContentController.addUserScript(WKUserScript(source: "window.__minimalBirdDiagnose = true;",
                injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        if let source = Resource.read("focus", extension: "js") {
            configuration.userContentController.addUserScript(WKUserScript(source: source,
                injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsLinkPreview = false
        // A Safari-compatible UA avoids embedded-browser fallback pages. WebKit
        // still provides the real engine and the normal website session.
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"
        webView.underPageBackgroundColor = Palette.paper
        webView.isHidden = true

        draftsPanel = DraftsPanel(expanded: UserDefaults.standard.bool(forKey: "DraftsExpanded"))
        draftsPanel.onToggle = { [weak self] expanded in
            UserDefaults.standard.set(expanded, forKey: "DraftsExpanded")
            self?.restoreEditorFocus()
        }
        draftsPanel.onOpen = { [weak self] id in self?.openDraft(id) }
        draftsPanel.onDelete = { [weak self] id in self?.deleteDraft(id) }

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
        for child in [webView!, cover, draftsPanel!] {
            child.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(child)
        }
        coverStack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: draftsPanel.topAnchor),
            draftsPanel.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            draftsPanel.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            draftsPanel.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            cover.topAnchor.constraint(equalTo: webView.topAnchor),
            cover.leadingAnchor.constraint(equalTo: webView.leadingAnchor),
            cover.trailingAnchor.constraint(equalTo: webView.trailingAnchor),
            cover.bottomAnchor.constraint(equalTo: webView.bottomAnchor),
            coverStack.centerXAnchor.constraint(equalTo: cover.centerXAnchor),
            coverStack.centerYAnchor.constraint(equalTo: cover.centerYAnchor, constant: -16),
            coverStack.widthAnchor.constraint(equalTo: cover.widthAnchor, constant: -64),
            coverDetail.widthAnchor.constraint(lessThanOrEqualToConstant: 340),
            coverIcon.heightAnchor.constraint(equalToConstant: 36)
        ])
        refreshDrafts()
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
        self.demo = demo
        _ = view
        if demo {
            showCover(title: "A quiet place to write.", detail: "Sign in to X to start. Your feed stays out of sight.", symbol: "square.and.pencil", button: "Open X")
        } else {
            loadComposer()
        }
    }

    /// Self-test only: shows a synthetic composer page instead of X.
    func showFixture(_ html: String) {
        _ = view
        state = "loading"
        webView.loadHTMLString(html, baseURL: NavigationPolicy.composerURL)
    }

    /// Self-test only: the window with the web content drawn in, since a
    /// view snapshot cannot capture WebKit's separate rendering process.
    func snapshotWindow() async -> NSBitmapImageRep? {
        guard let frameView = view.window?.contentView?.superview,
              let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) else { return nil }
        frameView.cacheDisplay(in: frameView.bounds, to: rep)
        guard !webView.isHidden, let page = try? await webView.takeSnapshot(configuration: nil) else { return rep }
        let rect = webView.convert(webView.bounds, to: frameView)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        page.draw(in: rect)
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    private func showCover(title: String, detail: String, symbol: String, button: String? = nil, loading: Bool = false) {
        webView.isHidden = true
        cover.isHidden = false
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
    private func loadComposer() {
        draft = false
        unsavedExtras = false
        composerHadText = false
        currentDraftID = nil
        state = "loading"
        openedAt = Date()
        warmOpening = false
        showCover(title: "Opening X…", detail: "", symbol: "square.and.pencil", loading: true)
        webView.load(URLRequest(url: NavigationPolicy.composerURL))
        armTimeout()
    }

    private func armTimeout() {
        timeout?.invalidate()
        timeout = Timer.scheduledTimer(withTimeInterval: 25, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.state == "loading" else { return }
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
        if state == "finished" { newPost() }
        else { restoreEditorFocus() }
    }

    /// Returning from native menus/sheets can leave a button or the window as
    /// first responder. Restore both AppKit and DOM focus, keeping the selection.
    func restoreEditorFocus() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.state == "composer", !self.webView.isHidden,
                  let window = self.viewIfLoaded?.window, window.isKeyWindow,
                  window.attachedSheet == nil else { return }
            window.makeFirstResponder(self.webView)
            self.webView.evaluateJavaScript("window.__minimalBirdFocusEditor?.() ?? false", completionHandler: nil)
        }
    }

    @objc func newPost() {
        guard confirmDiscard() else { return }
        if draft {
            // The text is already in Drafts; start a clean composer.
            if currentDraftID != nil { draftsPanel.flash("Saved to Drafts") }
            currentDraftID = nil
            pendingDraft = nil
            loadComposer()
            return
        }
        redirects = 0
        if ["finished", "composer", "blocked"].contains(state) {
            openedAt = Date()
            warmOpening = true
            state = "loading"
            showCover(title: "Opening composer…", detail: "", symbol: "square.and.pencil", loading: true)
            webView.evaluateJavaScript("window.__minimalBirdOpenComposer?.() ?? false") { [weak self] result, _ in
                guard let self else { return }
                if result as? Bool == true { self.armTimeout() }
                else { self.loadComposer() }
            }
        } else { loadComposer() }
    }

    @objc func reloadPage() {
        guard confirmDiscard() else { return }
        reloadKeepingText()
    }

    /// Reloads X and puts the composer's saved text back afterwards.
    private func reloadKeepingText() {
        redirects = 0
        if pendingDraft == nil, let id = currentDraftID, let saved = drafts.draft(id) { pendingDraft = saved }
        currentDraftID = nil
        loadComposer()
    }

    @objc func toggleDrafts() {
        draftsPanel.setExpanded(!draftsPanel.isExpanded)
    }

    var draftsExpanded: Bool { draftsPanel?.isExpanded ?? false }

    /// Text is kept in Drafts automatically. Only attachments and polls, which
    /// a text draft cannot hold, need confirmation before they are dropped.
    func confirmDiscard() -> Bool {
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
        guard confirmDiscard() else { return }
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
        state = "signingOut"
        showCover(title: "Clearing your session…", detail: "", symbol: "person.crop.circle", loading: true)
        webView.configuration.websiteDataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) { [weak self] in
            self?.redirects = 0
            self?.loadComposer()
        }
    }

    // MARK: Drafts

    private func refreshDrafts() {
        draftsPanel?.update(drafts: drafts.drafts, current: currentDraftID)
    }

    private func schedulePersist() {
        persistTimer?.invalidate()
        persistTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.drafts.persist() }
        }
    }

    func persistDrafts() {
        persistTimer?.invalidate()
        drafts.persist()
    }

    private func autosave(_ posts: [String]) {
        guard !restoringDraft else { return }
        if Draft.hasText(posts) {
            currentDraftID = drafts.save(posts, id: currentDraftID)
            composerHadText = true
        } else if composerHadText {
            // The person cleared the composer; the draft goes with it.
            if let id = currentDraftID { drafts.remove(id) }
            currentDraftID = nil
            composerHadText = false
        } else { return }
        schedulePersist()
        // Typing saves continuously; the list catches up a moment later.
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.refreshDrafts() }
        }
    }

    private func deleteDraft(_ id: UUID) {
        guard id != currentDraftID else { return }
        drafts.remove(id)
        persistDrafts()
        refreshDrafts()
        restoreEditorFocus()
    }

    private func openDraft(_ id: UUID) {
        guard id != currentDraftID, let saved = drafts.draft(id), !restoringDraft, confirmDiscard() else { return }
        pendingDraft = saved
        if state == "composer" && !unsavedExtras {
            insertPendingDraft()
        } else if state != "loading" || demo {
            demo = false
            currentDraftID = nil
            loadComposer()
        } // While loading, the draft is inserted once the composer appears.
    }

    /// Puts a saved draft into X's editor. The composer's previous text stays
    /// in its own draft; edits from here on update the opened one.
    private func insertPendingDraft() {
        guard let saved = pendingDraft, state == "composer", !restoringDraft else { return }
        restoringDraft = true
        currentDraftID = saved.id
        composerHadText = false
        refreshDrafts()
        webView.callAsyncJavaScript("return await window.__minimalBirdInsertPosts(posts)",
                                    arguments: ["posts": saved.posts], in: nil, in: .page) { [weak self] result in
            guard let self else { return }
            self.restoringDraft = false
            let outcome = (try? result.get()) as? String ?? "failed"
            switch outcome {
            case "ok", "partial":
                self.pendingDraft = nil
                self.composerHadText = true
                self.draft = true
                self.draftsPanel.flash(outcome == "ok" ? "Draft opened" : "Opened the first posts; add the rest with +")
                self.restoreEditorFocus()
            case "reload":
                // The composer holds a thread; start from a clean one, then insert.
                self.currentDraftID = nil
                self.loadComposer()
            default:
                self.pendingDraft = nil
                self.currentDraftID = nil
                self.draftsPanel.flash("Couldn’t open the draft here. It’s still in Drafts.")
            }
            self.refreshDrafts()
        }
    }

    // MARK: Messages from focus.js

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame,
              let url = message.frameInfo.request.url,
              NavigationPolicy.destination(for: url) != .blocked,
              let body = message.body as? [String: Any], let next = body["state"] as? String,
              state != "signingOut" else { return }
        if next == "draft" {
            draft = body["dirty"] as? Bool ?? false
            unsavedExtras = body["extras"] as? Bool ?? false
            if let posts = body["posts"] as? [String], posts.count <= 50 { autosave(posts) }
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
        }
        let previousState = state
        state = next
        if CommandLine.arguments.contains("--diagnose") { print("Focus state: \(next), elapsed: \(String(format: "%.2f", Date().timeIntervalSince(openedAt)))s, warm: \(warmOpening)"); fflush(stdout) }
        switch next {
        case "composer", "login":
            timeout?.invalidate()
            cover.isHidden = true
            webView.isHidden = false
            draftsPanel.status = next == "login" ? "Sign in with your X username and password." : ""
            if next == "composer", previousState != "composer" {
                if pendingDraft != nil { insertPendingDraft() } else { restoreEditorFocus() }
            }
        case "finished":
            timeout?.invalidate()
            // X closed the composer after Post; the posted text leaves Drafts.
            if let id = currentDraftID { drafts.remove(id); persistDrafts() }
            currentDraftID = nil
            composerHadText = false
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
            showCover(title: "Opening composer…", detail: "", symbol: "square.and.pencil", loading: true)
            armTimeout()
        }
    }

    private func redirectToComposer() {
        if Date().timeIntervalSince(lastRedirect) > 20 { redirects = 0 }
        redirects += 1
        lastRedirect = Date()
        guard redirects <= 3 else {
            state = "blocked"
            showCover(title: "X needs a moment.", detail: "The composer keeps redirecting. Please try again shortly.", symbol: "arrow.clockwise", button: "Try again")
            return
        }
        loadComposer()
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
        let destination = NavigationPolicy.destination(for: url)
        guard destination != .blocked else {
            draftsPanel.flash("Only posting is available in Minimal Bird.")
            decisionHandler(.cancel)
            return
        }
        if navigationAction.targetFrame == nil {
            decisionHandler(.cancel)
            webView.load(navigationAction.request)
            return
        }
        webView.isHidden = true
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard state != "signingOut" else { return }
        state = "loading"
        showCover(title: "Opening X…", detail: "", symbol: "square.and.pencil", loading: true)
        armTimeout()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
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
