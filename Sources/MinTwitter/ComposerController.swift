// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Min Twitter contributors

import AppKit
import WebKit
import UniformTypeIdentifiers
import FocusCore

enum Palette {
    static let paper = NSColor(calibratedRed: 0.98, green: 0.975, blue: 0.965, alpha: 1)
    static let ink = NSColor(calibratedRed: 0.18, green: 0.21, blue: 0.20, alpha: 1)
    static let muted = NSColor(calibratedRed: 0.47, green: 0.49, blue: 0.46, alpha: 1)
    static let accent = NSColor(calibratedRed: 0.72, green: 0.29, blue: 0.18, alpha: 1)
    static let line = NSColor(calibratedRed: 0.88, green: 0.88, blue: 0.85, alpha: 1)
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
    private let status = NSTextField(labelWithString: "")
    private var timeout: Timer?
    private var state = "loading"
    private var draft = false
    private var demo = false
    private var redirects = 0
    private var lastRedirect = Date.distantPast
    private var openedAt = Date()
    private var warmOpening = false
    private let dataStore: WKWebsiteDataStore
    var accountMenu: (() -> NSMenu)?
    var accountChanged: ((String) -> Void)?

    init(dataStore: WKWebsiteDataStore) {
        self.dataStore = dataStore
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("Use init(dataStore:)") }

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
            configuration.userContentController.addUserScript(WKUserScript(source: "window.__minTwitterDiagnose = true;",
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

        let more = NSButton(image: NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "Options")!, target: self, action: #selector(showOptions(_:)))
        more.isBordered = false
        more.refusesFirstResponder = true
        more.contentTintColor = Palette.muted
        cover.wantsLayer = true
        cover.layer?.backgroundColor = Palette.paper.cgColor
        coverIcon.contentTintColor = Palette.accent
        coverIcon.symbolConfiguration = .init(pointSize: 28, weight: .light)
        coverTitle.font = .systemFont(ofSize: 21, weight: .medium)
        coverTitle.textColor = Palette.ink
        coverTitle.alignment = .center
        coverDetail.font = .systemFont(ofSize: 12)
        coverDetail.textColor = Palette.muted
        coverDetail.alignment = .center
        coverDetail.maximumNumberOfLines = 5
        coverButton.target = self
        coverButton.action = #selector(coverAction)
        coverButton.bezelStyle = .rounded
        coverButton.controlSize = .regular
        coverButton.contentTintColor = Palette.accent
        spinner.style = .spinning
        spinner.controlSize = .small
        let coverStack = NSStackView(views: [coverIcon, coverTitle, coverDetail, spinner, coverButton])
        coverStack.orientation = .vertical
        coverStack.alignment = .centerX
        coverStack.spacing = 14
        cover.addSubview(coverStack)
        status.font = .systemFont(ofSize: 10)
        status.textColor = Palette.muted
        status.alignment = .center
        status.lineBreakMode = .byTruncatingTail
        status.stringValue = ""
        for child in [webView!, cover, status, more] {
            child.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(child)
        }
        coverStack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            more.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 30),
            more.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -22),
            more.widthAnchor.constraint(equalToConstant: 24),
            more.heightAnchor.constraint(equalToConstant: 24),
            webView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8),
            cover.topAnchor.constraint(equalTo: webView.topAnchor),
            cover.leadingAnchor.constraint(equalTo: webView.leadingAnchor),
            cover.trailingAnchor.constraint(equalTo: webView.trailingAnchor),
            cover.bottomAnchor.constraint(equalTo: webView.bottomAnchor),
            coverStack.centerXAnchor.constraint(equalTo: cover.centerXAnchor),
            coverStack.centerYAnchor.constraint(equalTo: cover.centerYAnchor, constant: -12),
            coverStack.widthAnchor.constraint(equalTo: cover.widthAnchor, constant: -64),
            coverDetail.widthAnchor.constraint(lessThanOrEqualToConstant: 360),
            coverIcon.heightAnchor.constraint(equalToConstant: 38),
            status.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            status.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            status.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -2)
        ])
    }

    @objc private func showOptions(_ sender: NSButton) {
        let menu = NSMenu()
        if let accounts = accountMenu?() {
            let item = NSMenuItem(title: "Switch account", action: nil, keyEquivalent: "")
            item.submenu = accounts
            menu.addItem(item)
            menu.addItem(.separator())
        }
        for (title, action) in [("New post", #selector(newPost)), ("Reload X", #selector(reloadPage)), ("Sign out…", #selector(signOut))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
        restoreEditorFocus()
    }

    func start(demo: Bool = false) {
        self.demo = demo
        _ = view
        if demo {
            showCover(title: "A space to write.", detail: "Sign in to X to start.", symbol: "square.and.pencil", button: "Open X")
        } else {
            loadComposer()
        }
    }

    private func showCover(title: String, detail: String, symbol: String, button: String? = nil, loading: Bool = false) {
        webView.isHidden = true
        cover.isHidden = false
        coverTitle.stringValue = title
        coverDetail.stringValue = detail
        coverIcon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        coverButton.title = button ?? "Try again"
        coverButton.isHidden = button == nil
        spinner.isHidden = !loading
        if loading { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
    }

    private func loadComposer() {
        draft = false
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
        newPost()
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
            self.webView.evaluateJavaScript("window.__minTwitterFocusEditor?.() ?? false", completionHandler: nil)
        }
    }

    @objc func newPost() {
        guard confirmDiscard() else { return }
        if draft { loadComposer(); return }
        redirects = 0
        if ["finished", "composer", "blocked"].contains(state) {
            openedAt = Date()
            warmOpening = true
            state = "loading"
            showCover(title: "Opening composer…", detail: "", symbol: "square.and.pencil", loading: true)
            webView.evaluateJavaScript("window.__minTwitterOpenComposer?.() ?? false") { [weak self] result, _ in
                guard let self else { return }
                if result as? Bool == true { self.armTimeout() }
                else { self.loadComposer() }
            }
        } else { loadComposer() }
    }

    @objc func reloadPage() {
        guard confirmDiscard() else { return }
        redirects = 0
        loadComposer()
    }

    func confirmDiscard() -> Bool {
        guard draft else { return true }
        let alert = NSAlert()
        alert.messageText = "Leave this draft?"
        alert.informativeText = "Text or attachments in the composer may be lost."
        alert.addButton(withTitle: "Keep writing")
        alert.addButton(withTitle: "Discard and continue")
        let discard = alert.runModal() == .alertSecondButtonReturn
        if !discard { restoreEditorFocus() }
        return discard
    }

    @objc func signOut() {
        guard confirmDiscard() else { return }
        let alert = NSAlert()
        alert.messageText = "Sign out of this app?"
        alert.informativeText = "This removes Min Twitter’s cookies and website data. Your other browsers stay signed in."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Sign out")
        guard alert.runModal() == .alertSecondButtonReturn else { restoreEditorFocus(); return }
        timeout?.invalidate()
        webView.stopLoading()
        webView.loadHTMLString("", baseURL: nil)
        draft = false
        state = "signingOut"
        showCover(title: "Clearing your session…", detail: "", symbol: "person.crop.circle", loading: true)
        webView.configuration.websiteDataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) { [weak self] in
            self?.redirects = 0
            self?.loadComposer()
        }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame,
              let url = message.frameInfo.request.url,
              NavigationPolicy.destination(for: url) != .blocked,
              let body = message.body as? [String: Any], let next = body["state"] as? String,
              state != "signingOut" else { return }
        if next == "draft" {
            draft = body["dirty"] as? Bool ?? false
            return
        }
        if next == "diagnostic" {
            if CommandLine.arguments.contains("--diagnose"), let details = body["details"] as? String {
                print("Authoring: \(details)"); fflush(stdout)
            }
            return
        }
        if next == "accounts" {
            accountMenu?().popUp(positioning: nil, at: NSPoint(x: 28, y: view.bounds.height - view.safeAreaInsets.top - 66), in: view)
            restoreEditorFocus()
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
            status.stringValue = next == "login" ? "Use your X username and password." : ""
            if next == "composer", previousState != "composer" {
                restoreEditorFocus()
            }
        case "finished":
            timeout?.invalidate()
            draft = false
            showCover(title: "Back to your day.", detail: "", symbol: "checkmark", button: "New post")
            status.stringValue = ""
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
            status.stringValue = "Only posting is available in Min Twitter."
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
            let value = try? await self.webView.evaluateJavaScript("JSON.stringify({surfaces:document.querySelectorAll('[data-mt-surface]').length,editors:document.querySelectorAll('[contenteditable=true]').length})")
            print("Native state: \(self.state); layout: \(value ?? "unavailable")")
            fflush(stdout)
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failed(error) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed(error) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        state = "error"
        showCover(title: "Your writing space paused.", detail: "The web process stopped. Reload to reconnect to X.", symbol: "arrow.clockwise", button: "Reload")
    }

    private func failed(_ error: Error) {
        guard (error as NSError).code != NSURLErrorCancelled else { return }
        timeout?.invalidate()
        state = "error"
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
