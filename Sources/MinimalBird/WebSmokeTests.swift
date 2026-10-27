// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Minimal Bird contributors

import AppKit
import WebKit
import FocusCore

/// Run with --self-test. Exercises the actual WebKit engine without credentials,
/// network requests, or publishing anything. Assertions inspect computed CSS.
@MainActor
final class WebSmokeTests: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
    private var web: WKWebView!
    private var messages: [[String: Any]] = []
    private var loaded: CheckedContinuation<Void, Never>?
    private var failures = 0
    private var selectedFiles: [URL]?
    private var openPanelCount = 0

    func run() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(self, name: "focus")
        configuration.userContentController.addUserScript(WKUserScript(
            source: Resource.read("focus", extension: "js")!, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: 760, height: 600), configuration: configuration)
        web.navigationDelegate = self
        web.uiDelegate = self
        Task {
            try? await Task.sleep(for: .seconds(40))
            print("FAIL: WebKit tests timed out. Run in an unrestricted desktop session.")
            exit(1)
        }
        Task {
            do {
                try await exercise()
                if let folder = ProcessInfo.processInfo.environment["MINIMAL_BIRD_SNAPSHOTS"] {
                    await snapshots(to: URL(fileURLWithPath: folder, isDirectory: true))
                }
            }
            catch { failures += 1; print("FAIL: \(error)") }
            print(failures == 0 ? "All WebKit smoke tests passed." : "\(failures) WebKit smoke test(s) failed.")
            exit(failures == 0 ? 0 : 1)
        }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if let body = message.body as? [String: Any] { messages.append(body) }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded?.resume()
        loaded = nil
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        openPanelCount += 1
        completionHandler(selectedFiles)
    }

    private func load(_ body: String, path: String) async {
        messages = []
        await withCheckedContinuation { continuation in
            loaded = continuation
            web.loadHTMLString("<!doctype html><html><head><meta charset='utf-8'><meta http-equiv='Content-Security-Policy' content=\"img-src data: blob:\"></head><body>\(body)</body></html>",
                               baseURL: URL(string: "https://x.com" + path))
        }
        try? await Task.sleep(for: .milliseconds(100))
    }

    @discardableResult private func js(_ source: String) async throws -> Any? {
        try await web.evaluateJavaScript(source)
    }

    private func check(_ title: String, _ expression: String) async throws {
        let value = try await js(expression) as? Bool == true
        if !value { failures += 1 }
        print("\(value ? "PASS" : "FAIL"): \(title)")
    }

    private func expect(_ title: String, _ passed: Bool) {
        if !passed { failures += 1 }
        print("\(passed ? "PASS" : "FAIL"): \(title)")
    }

    /// Only synthetic fixtures reach this helper. Include the DOM on failure
    /// so differences between supported WebKit versions can be diagnosed.
    private func editorDetails(_ page: WKWebView) async -> String {
        (try? await page.evaluateJavaScript("JSON.stringify([...document.querySelectorAll('[contenteditable=true]')].map(e=>({text:e.innerText,html:e.innerHTML})))")) as? String ?? "unavailable"
    }

    private func exercise() async throws {
        let fixture = """
        <header role="banner"><button id="notifications">Notifications 99</button><a id="newPost" data-testid="SideNav_NewTweet_Button" href="/compose/post">New post</a></header>
        <main><article data-testid="tweet" id="feed">Distracting feed</article><button id="explore">Explore</button></main>
        <div data-testid="SideNav_AccountSwitcher_Button">Writer @writer</div>
        <div id="layers"><div role="dialog" id="composer">
          <button data-testid="app-bar-close" id="close">Close</button>
          <a href="/writer" id="avatar"><img src="https://fixtures.invalid/avatar.png" alt="Your avatar"></a>
          <div id="writingHost"><div data-testid="tweetTextarea_0RichTextInputContainer"><div data-testid="tweetTextarea_0" contenteditable="true" id="editor"></div></div></div>
          <div data-testid="toolBar"><input type="file" id="file"><button aria-label="Add photos or video">Media</button></div>
          <button data-testid="tweetButton" id="post">Post</button>
        </div></div>
        """
        await load(fixture, path: "/compose/post")
        try await check("composer is visible", "getComputedStyle(document.querySelector('#editor')).visibility === 'visible'")
        try await check("feed and notifications stay hidden", "['feed','notifications','explore'].every(id => getComputedStyle(document.getElementById(id)).visibility === 'hidden')")
        try await check("background excluded from keyboard and accessibility", "document.querySelector('main').inert && document.querySelector('header').inert")
        try await check("close button is concealed in place and cannot be used", "(()=>{const c=document.querySelector('#close'),s=getComputedStyle(c);return s.visibility==='hidden' && s.pointerEvents==='none' && !c.dispatchEvent(new MouseEvent('click',{bubbles:true,cancelable:true}))})()")
        try await check("profile avatar remains visible", "getComputedStyle(document.querySelector('#avatar img')).visibility === 'visible'")
        try await exerciseFocusAndPopovers()
        web.setFrameSize(NSSize(width: 480, height: 420))
        try await Task.sleep(for: .milliseconds(50))
        try await check("composer fills a narrow window", "(()=>{const r=document.querySelector('#composer').getBoundingClientRect();return r.width===innerWidth && r.height===innerHeight})()")
        web.setFrameSize(NSSize(width: 760, height: 600))
        try await check("Post stays below the writing area and inside the window", "(()=>{const p=document.querySelector('#post').getBoundingClientRect(),e=document.querySelector('#editor').getBoundingClientRect();return p.top > e.bottom && p.right <= innerWidth && p.bottom <= innerHeight})()")
        try await check("styling preserves the original editor and upload input parents", "document.querySelector('#editor').parentElement.dataset.testid === 'tweetTextarea_0RichTextInputContainer' && document.querySelector('#file').parentElement.dataset.testid === 'toolBar'")
        try await check("wrappers retain measurable geometry", "(()=>{const r=document.querySelector('#writingHost').getBoundingClientRect();return r.width>0 && r.height>0})()")
        try await js("const media=document.createElement('div');media.dataset.testid='attachments';media.id='preview';media.textContent='Chart attachment';document.querySelector('#writingHost').appendChild(media);void 0")
        try await Task.sleep(for: .milliseconds(50))
        try await check("new media previews remain visible after layout changes", "getComputedStyle(document.querySelector('#preview')).display !== 'none' && document.querySelector('#preview').getBoundingClientRect().height > 0")
        try await js("const next=document.createElement('div');next.id='thread';next.dataset.testid='tweetTextarea_1';next.contentEditable='true';next.textContent='Second post';document.querySelector('#writingHost').appendChild(next);void 0")
        try await Task.sleep(for: .milliseconds(50))
        try await check("additional thread editors stay visible", "getComputedStyle(document.querySelector('#thread')).visibility === 'visible' && document.querySelector('#thread').getBoundingClientRect().height > 0")
        try await js("document.querySelector('#thread').remove();document.querySelector('#preview').remove();void 0")
        try await js("const poll=document.createElement('input');poll.id='poll';poll.value='First option';document.querySelector('#writingHost').appendChild(poll);void 0")
        try await Task.sleep(for: .milliseconds(50))
        if messages.last(where: { $0["state"] as? String == "draft" })?["dirty"] as? Bool != true {
            failures += 1; print("FAIL: poll text protects a draft even with an empty post")
        } else { print("PASS: poll text protects a draft even with an empty post") }
        try await js("document.querySelector('#poll').remove();void 0")
        if !messages.contains(where: { $0["handle"] as? String == "@writer" }) { failures += 1; print("FAIL: account label") }
        try await js("document.querySelector('#editor').textContent='A draft'; document.querySelector('#editor').dispatchEvent(new Event('input', {bubbles:true}))")
        try await Task.sleep(for: .milliseconds(50))
        if messages.last(where: { $0["state"] as? String == "draft" })?["dirty"] as? Bool != true {
            failures += 1; print("FAIL: draft protection")
        } else { print("PASS: draft protection") }
        try await js("document.querySelector('#editor').dispatchEvent(new Event('input', {bubbles:true}));queueMicrotask(()=>{document.querySelector('#editor').textContent=''})")
        try await Task.sleep(for: .milliseconds(50))
        if messages.last(where: { $0["state"] as? String == "draft" })?["dirty"] as? Bool != false {
            failures += 1; print("FAIL: clearing text after input resets draft protection")
        } else { print("PASS: clearing text after input resets draft protection") }
        try await check("profile link click is blocked", "!document.querySelector('#avatar').dispatchEvent(new MouseEvent('click', {bubbles:true,cancelable:true}))")
        try await js("document.querySelector('#post').click(); history.pushState({}, '', '/home'); document.querySelector('#composer').remove()")
        try await Task.sleep(for: .milliseconds(50))
        try await check("feed stays hidden after submission", "getComputedStyle(document.querySelector('#feed')).visibility === 'hidden'")
        if !messages.contains(where: { $0["state"] as? String == "finished" }) { failures += 1; print("FAIL: post completion curtain") }
        else { print("PASS: post completion curtain") }
        try await js("document.querySelector('#newPost').addEventListener('click', event => { event.preventDefault(); history.pushState({}, '', '/home?%40modal=%2Fcompose%2Fpost'); document.querySelector('#layers').innerHTML = `<div role='dialog'><div id='warmEditor' data-testid='tweetTextarea_0' contenteditable='true'></div><button data-testid='tweetButton'>Post</button></div>`; }); window.__fixtureMarker = 123")
        try await check("background navigation remains blocked", "!document.querySelector('#newPost').dispatchEvent(new MouseEvent('click', {bubbles:true,cancelable:true}))")
        try await check("native new-post action reuses X navigation", "window.__minimalBirdOpenComposer() === true")
        try await Task.sleep(for: .milliseconds(50))
        try await check("warm composer opens without replacing the document", "window.__fixtureMarker === 123 && getComputedStyle(document.querySelector('#warmEditor')).visibility === 'visible'")
        try await check("feed stays hidden during warm open", "getComputedStyle(document.querySelector('#feed')).visibility === 'hidden'")

        await load("<main><div id='unknown'>An unrecognized X layout</div></main>", path: "/compose/post")
        try await check("unknown layouts fail closed", "getComputedStyle(document.querySelector('#unknown')).visibility === 'hidden'")
        try await js("document.body.innerHTML = `<div role='dialog'><div data-testid='tweetTextarea_0' contenteditable='true' id='dynamic'></div><button data-testid='tweetButton'>Post</button></div><article data-testid='tweet' id='newfeed'>New feed</article>`")
        try await Task.sleep(for: .milliseconds(50))
        try await check("late React composer is recognized", "getComputedStyle(document.querySelector('#dynamic')).visibility === 'visible'")
        try await check("late feed insertion stays hidden", "getComputedStyle(document.querySelector('#newfeed')).visibility === 'hidden'")
        try await js("history.pushState({}, '', '/notifications')")
        try await check("SPA navigation closes curtain synchronously", "!document.querySelector('[data-mb-surface]')")

        await load("<article data-testid='tweet' id='feed'>Feed</article><div role='dialog'><h1>Sign in to X</h1><input name='text' id='username'><button id='google'>Sign in with Google</button><button id='googleLabel' aria-label='Über Google anmelden'></button><button id='next'>Next</button></div>", path: "/i/jf/onboarding/web")
        try await check("username login is visible", "getComputedStyle(document.querySelector('#username')).visibility === 'visible'")
        try await check("feed behind login stays hidden", "getComputedStyle(document.querySelector('#feed')).visibility === 'hidden'")
        try await check("unsupported OAuth is hidden", "getComputedStyle(document.querySelector('#google')).display === 'none'")
        try await check("localized OAuth labels are hidden", "getComputedStyle(document.querySelector('#googleLabel')).display === 'none'")
        try await check("login controls remain usable", "getComputedStyle(document.querySelector('#next')).pointerEvents === 'auto'")

        await load("<main><div id='standalone'><nav><button data-testid='app-bar-back' id='back'>Back</button><button data-testid='tweetButton'>Post</button></nav><div data-testid='UserAvatar-Container-writer'></div><div data-testid='tweetTextarea_0' contenteditable='true' id='editor'></div><nav role='navigation'><input type='file'></nav></div></main>", path: "/compose/post")
        try await check("standalone composer with navigation toolbar is visible", "getComputedStyle(document.querySelector('#editor')).visibility === 'visible'")
        try await check("standalone back button stays hidden", "getComputedStyle(document.querySelector('#back')).visibility === 'hidden'")
        try await exerciseSkin()
        try await exerciseThreadsAndDrafts()
        try await exerciseAuthoring()
        try await checkAccountStores()
        try await exerciseNativeDraftRecovery()
    }

    private func exerciseFocusAndPopovers() async throws {
        try await js("""
            const editor=document.querySelector('#editor');
            editor.textContent='Hello';editor.focus();
            const range=document.createRange();range.setStart(editor.firstChild,2);range.collapse(true);
            getSelection().removeAllRanges();getSelection().addRange(range);void 0
            """)
        try await Task.sleep(for: .milliseconds(50))
        try await js("document.activeElement.blur();window.__minimalBirdFocusEditor()")
        try await check("returning from a native menu restores editor and caret", "document.activeElement.id==='editor' && getSelection().anchorOffset===2")
        try await js("document.execCommand('insertText',false,'!')")
        try await check("typing resumes at the saved caret", "document.querySelector('#editor').textContent==='He!llo'")
        try await js("""
            const choice=document.createElement('input');choice.id='focusChoice';
            document.querySelector('#composer').appendChild(choice);choice.focus();void 0
            """)
        try await check("restoring focus does not steal a poll input", "window.__minimalBirdFocusEditor() && document.activeElement.id==='focusChoice'")
        try await js("document.querySelector('#focusChoice').remove();document.querySelector('#editor').textContent='';void 0")
        try await Task.sleep(for: .milliseconds(50))
        try await js("document.querySelector('[data-testid=toolBar] button').focus();window.__minimalBirdFocusEditor()")
        try await check("focus restoration leaves a composer control the person is using", "document.activeElement.getAttribute('aria-label')==='Add photos or video'")
        try await js("document.querySelector('#writingHost').dispatchEvent(new MouseEvent('mousedown',{bubbles:true,cancelable:true,button:0}))")
        try await check("blank writing space restores editable focus", "document.activeElement.id==='editor'")
        try await js("""
            const unsolicited=document.createElement('div');unsolicited.role='dialog';unsolicited.id='unsolicited';
            unsolicited.innerHTML='<button>Unrelated dialog</button>';document.body.appendChild(unsolicited);
            const tools=document.querySelector('[data-testid=toolBar]');
            const trigger=document.createElement('button');trigger.id='popupTrigger';trigger.textContent='Reply settings';tools.appendChild(trigger);
            trigger.onclick=()=>{
              const menu=document.createElement('div');menu.role='menu';menu.id='authoringPopup';
              menu.innerHTML='<input id="popupField"><button id="closePopup" data-testid="app-bar-close">Close</button>';
              menu.querySelector('button').onclick=()=>menu.remove();
              menu.onkeydown=e=>{if(e.key==='Escape') menu.remove()};document.body.appendChild(menu);
              const bad=document.createElement('div');bad.role='dialog';bad.id='badPopup';
              bad.innerHTML='<article data-testid="tweet">Must stay hidden</article>';document.body.appendChild(bad);
            };void 0
            """)
        try await Task.sleep(for: .milliseconds(50))
        try await check("unsolicited dialogs stay hidden", "getComputedStyle(document.querySelector('#unsolicited')).visibility==='hidden' && document.querySelector('#unsolicited').inert")
        try await js("document.querySelector('#popupTrigger').click()")
        try await Task.sleep(for: .milliseconds(50))
        try await check("authoring popup is visible and interactive outside composer", "getComputedStyle(document.querySelector('#authoringPopup')).visibility==='visible' && !document.querySelector('#authoringPopup').closest('[inert]')")
        try await check("popup recognition never reveals tweets or unrelated dialogs", "getComputedStyle(document.querySelector('#badPopup')).visibility==='hidden' && getComputedStyle(document.querySelector('#unsolicited')).visibility==='hidden' && document.querySelector('main').inert")
        try await js("document.querySelector('#popupField').focus()")
        try await check("native focus restoration leaves authoring popup active", "!window.__minimalBirdFocusEditor() && document.activeElement.id==='popupField'")
        try await check("popup close control remains visible", "getComputedStyle(document.querySelector('#closePopup')).display!=='none'")
        try await js("document.querySelector('#popupField').dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',bubbles:true,cancelable:true}))")
        try await Task.sleep(for: .milliseconds(50))
        try await check("Escape exits the popup while preserving composer", "!document.querySelector('#authoringPopup') && getComputedStyle(document.querySelector('#editor')).visibility==='visible'")
        try await check("editor can resume after popup exit", "window.__minimalBirdFocusEditor() && document.activeElement.id==='editor'")
        try await js("document.querySelector('#popupTrigger').click()")
        try await Task.sleep(for: .milliseconds(50))
        try await js("document.querySelector('#closePopup').click()")
        try await Task.sleep(for: .milliseconds(50))
        try await check("popup close button keeps its original handler", "!document.querySelector('#authoringPopup')")
        try await js("""
            document.querySelector('#popupTrigger').onclick=null;
            document.querySelector('#popupTrigger').onpointerup=()=>{
              const group=document.createElement('div');group.role='group';group.tabIndex=0;group.id='groupPopup';
              group.innerHTML='<input id="emojiSearch" aria-label="Search"><div role="listbox"><button>Emoji</button></div>';
              const portal=document.createElement('div');portal.id='popupPortal';
              portal.style='position:absolute;left:900px;top:900px;width:1px;height:1px;transform:translate(100px,100px);overflow:hidden;clip-path:inset(0)';
              group.onkeydown=e=>{if(e.key==='Escape') portal.remove()};portal.appendChild(group);document.body.appendChild(portal);
            };
            document.querySelector('#popupTrigger').dispatchEvent(new PointerEvent('pointerdown',{bubbles:true,button:0}));
            document.querySelector('#popupTrigger').dispatchEvent(new PointerEvent('pointerup',{bubbles:true,button:0}));
            document.querySelector('#popupTrigger').click()
            """)
        try await Task.sleep(for: .milliseconds(50))
        try await check("focusable popup group exposes search alongside its listbox", "getComputedStyle(document.querySelector('#emojiSearch')).visibility==='visible' && !document.querySelector('#emojiSearch').closest('[inert]')")
        try await check("popup escapes transformed and clipped anchors within the window", "(()=>{const r=document.querySelector('#groupPopup').getBoundingClientRect(),p=getComputedStyle(document.querySelector('#popupPortal'));return r.left>=0 && r.top>=0 && r.right<=innerWidth && r.bottom<=innerHeight && p.clipPath==='none' && p.overflow==='visible'})()")
        try await js("document.querySelector('#emojiSearch').focus();document.querySelector('#emojiSearch').dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',bubbles:true,cancelable:true}))")
        try await Task.sleep(for: .milliseconds(50))
        try await check("Escape exits a focusable popup group", "!document.querySelector('#groupPopup') && window.__minimalBirdFocusEditor()")
        try await js("document.querySelectorAll('#popupTrigger,#unsolicited,#badPopup').forEach(n=>n.remove());void 0")
    }

    private func lastDraft() -> [String: Any]? {
        messages.last(where: { $0["state"] as? String == "draft" })
    }

    private func exerciseSkin() async throws {
        await load("""
            <main id="background"><article data-testid="tweet">Feed</article></main>
            <div role="dialog" id="composer" style="background:rgb(255,255,255)">
              <div id="scrim" style="position:absolute;inset:0;background:rgba(0,0,0,0.4)"></div>
              <div id="panel" style="background:rgb(255,255,255);border:1px solid rgb(207,217,222);color:rgb(15,20,25)">
                <button id="audience" style="color:rgb(29,155,240);border:1px solid rgb(207,217,222)">Everyone</button>
                <div data-testid="tweetTextarea_0" contenteditable="true" id="editor" style="font-family:Georgia;color:rgb(15,20,25)">Read <span id="link" style="color:rgb(29,155,240)">example.com</span></div>
                <div id="secondary" style="color:rgb(83,100,113)">Everyone can reply</div>
                <div id="rule" style="width:2px;height:40px;background:rgb(207,217,222)"></div>
              </div>
              <div data-testid="toolBar"><button id="tool" style="color:rgb(29,155,240)">Media<svg width="20" height="20"><path id="toolIcon" d="M2 2h16v16H2z" style="fill:none;stroke:currentColor"/></svg></button>
                <svg width="26" height="26"><circle id="ring" cx="13" cy="13" r="11" style="fill:none;stroke:rgb(29,155,240)"/></svg>
                <div id="remove" style="background:rgba(15,20,25,0.75);color:rgb(255,255,255)">Remove</div></div>
              <button data-testid="tweetButton" id="post" style="background:rgb(29,155,240);color:rgb(255,255,255)">Post</button>
            </div>
            """, path: "/compose/post")
        try await Task.sleep(for: .milliseconds(50))
        let accent = "rgb(184, 73, 46)", paper = "rgb(250, 249, 246)", line = "rgb(230, 228, 220)"
        try await check("X's accent becomes the app accent for Post and links", "getComputedStyle(document.querySelector('#post')).backgroundColor==='\(accent)' && getComputedStyle(document.querySelector('#link')).color==='\(accent)' && getComputedStyle(document.querySelector('#audience')).color==='\(accent)'")
        try await check("white panels take the warm page color with hairline borders", "getComputedStyle(document.querySelector('#panel')).backgroundColor==='\(paper)' && getComputedStyle(document.querySelector('#panel')).borderTopColor==='\(line)'")
        try await check("a modal's dimming backdrop is cleared", "getComputedStyle(document.querySelector('#scrim')).backgroundColor==='rgba(0, 0, 0, 0)'")
        try await check("thread connectors become hairlines", "getComputedStyle(document.querySelector('#rule')).backgroundColor==='\(line)'")
        try await check("text uses the app's ink and muted tones", "getComputedStyle(document.querySelector('#editor')).color==='rgb(43, 50, 48)' && getComputedStyle(document.querySelector('#secondary')).color==='rgb(128, 132, 124)'")
        try await check("toolbar icons stay quiet", "getComputedStyle(document.querySelector('#tool')).color==='rgb(128, 132, 124)' && getComputedStyle(document.querySelector('#toolIcon')).stroke==='rgb(128, 132, 124)'")
        try await check("the character ring keeps the accent", "getComputedStyle(document.querySelector('#ring')).stroke==='\(accent)'")
        try await check("one system typeface across the composer", "getComputedStyle(document.querySelector('#editor')).fontFamily.includes('apple-system') && getComputedStyle(document.querySelector('#post')).fontFamily.includes('apple-system')")
        try await check("overlay controls on media keep their contrast", "getComputedStyle(document.querySelector('#remove')).backgroundColor==='rgba(15, 20, 25, 0.75)' && getComputedStyle(document.querySelector('#remove')).color==='rgb(255, 255, 255)'")
        try await js("document.querySelector('#post').style.backgroundColor='rgb(26,140,216)';void 0")
        try await Task.sleep(for: .milliseconds(50))
        try await check("restyled controls are measured again", "getComputedStyle(document.querySelector('#post')).backgroundColor==='\(accent)'")
    }

    private func exerciseThreadsAndDrafts() async throws {
        // Popup focus recovery runs only in an active document. A detached web
        // view would miss the live bug even if it detected the exposed popup.
        let originalFrame = web.frame
        let window = NSWindow(contentRect: originalFrame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = web
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(web)
        NSApp.activate(ignoringOtherApps: true)
        defer { window.contentView = nil; window.close(); web.frame = originalFrame }
        let thread = """
            <main id="background"><article data-testid="tweet">Feed</article></main>
            <div role="dialog" id="composer">
              <div id="posts"><div data-testid="tweetTextarea_0" contenteditable="true" id="editor" style="white-space:pre-wrap"></div></div>
              <div data-testid="toolBar"><button id="media" aria-label="Add photos or video">Media</button>
                <button data-testid="addButton" id="add" aria-label="Add post">+</button></div>
              <button data-testid="tweetButton" id="post">Post</button>
            </div>
            <script>
              let next = 1;
              // Like X, add a post and focus it on a later tick.
              document.querySelector('#add').onclick = () => {
                const editor = document.createElement('div');
                editor.dataset.testid = 'tweetTextarea_' + next++; editor.contentEditable = 'true'; editor.style.minHeight = '20px'; editor.style.whiteSpace = 'pre-wrap';
                document.querySelector('#posts').appendChild(editor);
                setTimeout(() => {
                  editor.focus();
                  // X also mounts a dormant audience portal during thread
                  // changes. Add post did not request this popup.
                  document.querySelector('#dormantAudienceHost')?.remove();
                  const host = document.createElement('div'); host.id = 'dormantAudienceHost';
                  host.style.cssText = 'opacity:0;pointer-events:none';
                  host.innerHTML = '<div role="listbox" tabindex="0" id="dormantAudience"><button>Everyone</button></div>';
                  document.body.appendChild(host);
                }, 30);
              };
            </script>
            """
        await load(thread, path: "/compose/post")
        // App activation and WebKit focus cross process boundaries. Wait for
        // the real focused document before exercising popup recovery.
        for _ in 0..<50 {
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(web)
            NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps])
            try await js("document.querySelector('#editor').focus()")
            if (try await js("document.hasFocus()")) as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(40))
        }
        try await js("{const e=document.querySelector('#editor');e.focus();e.textContent='First post';e.dispatchEvent(new Event('input',{bubbles:true}))}")
        try await Task.sleep(for: .milliseconds(50))
        if (try await js("document.hasFocus()")) as? Bool != true {
            print("Thread fixture focus: active=\(NSApp.isActive), key=\(window.isKeyWindow), visible=\(window.isVisible), responder=\(String(describing: window.firstResponder)), frame=\(web.frame)")
        }
        try await check("thread regression runs with document focus", "document.hasFocus()")
        if lastDraft()?["posts"] as? [String] != ["First post"] || lastDraft()?["extras"] as? Bool != false {
            failures += 1; print("FAIL: composer text is reported for local drafts")
        } else { print("PASS: composer text is reported for local drafts") }
        try await js("document.querySelector('#add').focus();document.querySelector('#add').click()")
        try await Task.sleep(for: .milliseconds(10))
        try await js("window.__minimalBirdFocusEditor()") // A native focus restore while X is still adding the post.
        try await Task.sleep(for: .milliseconds(80))
        try await js("window.__minimalBirdFocusEditor()")
        try await check("a newly added thread post keeps keyboard focus", "document.activeElement.dataset.testid==='tweetTextarea_1'")
        try await check("Add post does not expose a dormant audience popup", "getComputedStyle(document.querySelector('#dormantAudience')).visibility==='hidden' && !!document.querySelector('#dormantAudience').closest('[inert]')")
        try await js("document.execCommand('insertText',false,'Second post')")
        try await Task.sleep(for: .milliseconds(50))
        if lastDraft()?["posts"] as? [String] != ["First post", "Second post"] {
            failures += 1; print("FAIL: every post of a thread is reported in order")
        } else { print("PASS: every post of a thread is reported in order") }
        try await js("document.querySelector('#editor').focus();document.querySelector('[data-testid=tweetTextarea_1]').focus()")
        try await check("an earlier thread post can be focused again", "document.activeElement.dataset.testid==='tweetTextarea_1'")
        let reload = try await web.callAsyncJavaScript("return await window.__minimalBirdInsertPosts(posts)",
                                                       arguments: ["posts": ["Other"]], in: nil, contentWorld: .page) as? String
        if reload != "reload" { failures += 1; print("FAIL: opening a draft over a thread asks for a fresh composer") }
        else { print("PASS: opening a draft over a thread asks for a fresh composer") }

        await load(thread, path: "/compose/post")
        try await js("document.querySelector('#editor').textContent='Old text';document.querySelector('#editor').dispatchEvent(new Event('input',{bubbles:true}))")
        try await Task.sleep(for: .milliseconds(50))
        let outcome = try await web.callAsyncJavaScript("return await window.__minimalBirdInsertPosts(posts)",
                                                        arguments: ["posts": ["Hello\nthere", "And a reply"]], in: nil, contentWorld: .page) as? String
        if outcome != "ok" {
            failures += 1
            print("FAIL: a saved thread is put back into X's editors (\(outcome ?? "nil")); \(await editorDetails(web))")
        }
        else { print("PASS: a saved thread is put back into X's editors") }
        try await check("restored text replaces the old text", "(()=>{const e=[...document.querySelectorAll('[data-testid^=tweetTextarea_]')];return e.length===2 && e[0].innerText.replace(/\\s+/g,' ').trim()==='Hello there' && e[1].innerText.trim()==='And a reply'})()")
        try await Task.sleep(for: .milliseconds(50))
        if lastDraft()?["posts"] as? [String] != ["Hello\nthere", "And a reply"] {
            failures += 1; print("FAIL: restored text is reported once insertion finishes")
        } else { print("PASS: restored text is reported once insertion finishes") }

        // An editor with its own paste handling (as X's does) must not get the text twice.
        await load(thread, path: "/compose/post")
        try await js("""
            document.querySelector('#editor').addEventListener('paste', event => {
              event.preventDefault(); window.fixturePastes = (window.fixturePastes || 0) + 1;
              event.currentTarget.textContent = event.clipboardData.getData('text/plain');
            });void 0
            """)
        let pasted = try await web.callAsyncJavaScript("return await window.__minimalBirdInsertPosts(posts)",
                                                       arguments: ["posts": ["Only once"]], in: nil, contentWorld: .page) as? String
        try await check("editors that handle paste receive the text exactly once", "\(pasted == "ok") && window.fixturePastes===1 && document.querySelector('#editor').textContent==='Only once'")

        await load(thread, path: "/compose/post")
        try await js("document.querySelector('#editor').textContent='Hello world';void 0")
        let exact = try await web.callAsyncJavaScript("return await window.__minimalBirdInsertPosts(posts)",
                                                      arguments: ["posts": ["Hello\nworld"]], in: nil, contentWorld: .page) as? String
        if exact != "ok" { print("Line-break fixture: \(await editorDetails(web))") }
        try await check("restoring a draft replaces spaces with its saved line breaks", "\(exact == "ok") && window.__minimalBirdDraftSnapshot().posts[0]==='Hello\\nworld'")
        let spaced = try await web.callAsyncJavaScript("return await window.__minimalBirdInsertPosts(posts)",
                                                       arguments: ["posts": ["  Hello  world  "]], in: nil, contentWorld: .page) as? String
        try await check("draft restoration preserves repeated and edge spaces", "\(spaced == "ok") && document.querySelector('#editor').innerText.replace(/\\u00a0/g,' ')==='  Hello  world  '")

        try await js("document.querySelector('#editor').innerHTML='<div data-block=\"true\"><br></div>';window.__minimalBirdReportDraft()")
        try await Task.sleep(for: .milliseconds(50))
        expect("an empty Draft.js block has no saved layout newline", lastDraft()?["posts"] as? [String] == [""])
        try await js("document.querySelector('#editor').innerHTML='<div data-block=\"true\">  First  line  </div><div data-block=\"true\"><br></div><div data-block=\"true\">Last line</div><div data-block=\"true\"><br></div>';window.__minimalBirdReportDraft()")
        try await Task.sleep(for: .milliseconds(50))
        expect("Draft.js text preserves blank lines and spaces without layout breaks", lastDraft()?["posts"] as? [String] == ["  First  line  \n\nLast line\n"])
        try await js("document.querySelector('#editor').innerHTML='<span>  First  line  </span><div><br></div><div>Last line</div><div><br></div>';window.__minimalBirdReportDraft()")
        try await Task.sleep(for: .milliseconds(50))
        expect("native paragraphs preserve blank lines and edge spaces", lastDraft()?["posts"] as? [String] == ["  First  line  \n\nLast line\n"])
        try await js("document.querySelector('#editor').innerHTML='<p><br></p><p>First<br>Second</p>';window.__minimalBirdReportDraft()")
        try await Task.sleep(for: .milliseconds(50))
        expect("native paragraphs preserve leading blank lines and explicit breaks", lastDraft()?["posts"] as? [String] == ["\nFirst\nSecond"])
    }

    /// Exercise the real controller/store bridge, not just the injected script.
    /// Everything lives in disposable stores and synthetic windows.
    private func exerciseNativeDraftRecovery() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MinimalBirdRecovery-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let previousExpansion = UserDefaults.standard.object(forKey: "DraftsExpanded")
        var windows: [NSWindow] = []
        defer {
            windows.forEach { $0.close() }
            UserDefaults.standard.set(previousExpansion, forKey: "DraftsExpanded")
            try? FileManager.default.removeItem(at: folder)
        }
        func waitFor(_ condition: () async throws -> Bool) async throws {
            for _ in 0..<150 {
                if try await condition() { return }
                try await Task.sleep(for: .milliseconds(40))
            }
            throw NSError(domain: "Draft recovery fixture timed out", code: 1)
        }
        func prepareToLeave(_ controller: ComposerController) async -> Bool {
            await withCheckedContinuation { continuation in
                controller.prepareToLeave { continuation.resume(returning: $0) }
            }
        }
        func composer(_ store: DraftStore, threaded: Bool = false) async throws -> (ComposerController, WKWebView, DraftsPanel) {
            let controller = ComposerController(dataStore: .nonPersistent(), drafts: store)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 580, height: 660),
                                  styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.contentViewController = controller
            window.setContentSize(NSSize(width: 580, height: 660))
            window.isReleasedWhenClosed = false
            windows.append(window)
            window.makeKeyAndOrderFront(nil)
            let page = controller.view.subviews.compactMap { $0 as? WKWebView }.first!
            let panel = controller.view.subviews.compactMap { $0 as? DraftsPanel }.first!
            controller.showFixture("""
                <!doctype html><html><body><div role="dialog">
                <div id="postEditors"><div id="editor" data-testid="tweetTextarea_0" contenteditable="true" style="white-space:pre-wrap"></div></div>
                \(threaded ? "<button id='add' data-testid='addButton'>+</button>" : "")
                <button data-testid="tweetButton" onclick="window.nativeSubmissions=(window.nativeSubmissions||0)+1">Post</button>
                </div><script>
                window.nativeAddKeys=0;
                const add=document.querySelector('#add');
                if(add) {
                  add.onkeydown=event=>{
                    if(event.key!==' ') return;
                    window.nativeAddKeys++;
                    const submit=document.querySelector('[data-testid="tweetButton"]');
                    const stray=new KeyboardEvent('keydown',{key:'Enter',bubbles:true,cancelable:true});
                    submit.dispatchEvent(stray);window.restoreFocusGuard=stray.defaultPrevented;
                    submit.click();
                  };
                  add.onclick=()=>{
                    const editor=document.createElement('div');editor.contentEditable='true';
                    editor.dataset.testid='tweetTextarea_'+document.querySelectorAll('[contenteditable=true]').length;
                    editor.style.whiteSpace='pre-wrap';document.querySelector('#postEditors').appendChild(editor);editor.focus();
                  };
                }
                </script></body></html>
                """)
            try await waitFor {
                guard !page.isHidden else { return false }
                return (try? await page.evaluateJavaScript("!!document.querySelector('[data-mb-surface]')")) as? Bool == true
            }
            return (controller, page, panel)
        }

        let store = DraftStore(url: folder.appendingPathComponent("partial.json"))
        let original = store.save(["First post", "Second post", "Third post"], id: nil)!
        let (controller, page, panel) = try await composer(store)
        // The person may switch apps while a draft is opening. Restoration
        // must still reach its own web view without requiring a key window.
        controller.view.window?.orderOut(nil)
        expect("draft restore fixture covers a background window", controller.view.window?.isKeyWindow == false)
        _ = try await page.evaluateJavaScript("window.fixtureNativeInputs=0;document.querySelector('#editor').addEventListener('beforeinput',()=>window.fixtureNativeInputs++);void 0")
        panel.onOpen?(original) // No add-post button: only the first post can open.
        expect("leaving during draft restoration is blocked", !controller.confirmDiscard())
        try await waitFor { store.drafts.count == 2 }
        expect("draft restoration uses WebKit native text input", (try await page.evaluateJavaScript("window.fixtureNativeInputs>0")) as? Bool == true)
        _ = try await page.evaluateJavaScript("document.querySelector('#editor').textContent='First post edited';document.querySelector('#editor').dispatchEvent(new Event('input',{bubbles:true}));void 0")
        try await waitFor { store.drafts.contains { $0.posts == ["First post edited"] } }
        expect("partial thread edits retain every post in the original draft", store.draft(original)?.posts == ["First post", "Second post", "Third post"])
        expect("partial recovery can be saved before leaving", controller.confirmDiscard())
        expect("full and partial drafts both survive reopening", DraftStore(url: folder.appendingPathComponent("partial.json")).drafts.count == 2)
        panel.setExpanded(true)
        // Check that the recovery command is present without touching the
        // user's clipboard during a self-test.
        func hasCopyCommand(_ view: NSView) -> Bool {
            view.menu?.items.contains(where: { $0.title == "Copy draft text" }) == true
                || view.subviews.contains(where: hasCopyCommand)
        }
        expect("saved drafts expose a copy-text recovery command", hasCopyCommand(panel))

        let fullStore = DraftStore(url: nil)
        let fullID = fullStore.save(["Line one\nLine two", "Second post", "\n"], id: nil)!
        let (fullController, fullPage, fullPanel) = try await composer(fullStore, threaded: true)
        fullController.view.window?.orderOut(nil)
        fullPanel.onOpen?(fullID)
        do {
            try await waitFor { fullStore.draft(fullID)?.posts == ["Line one\nLine two", "Second post", ""] }
        } catch {
            print("Native thread fixture: \(fullPanel.status); \(await editorDetails(fullPage))")
            throw error
        }
        expect("native activation restores every thread post with line breaks", (try await fullPage.evaluateJavaScript("JSON.stringify(window.__minimalBirdDraftSnapshot().posts)===JSON.stringify(['Line one\\nLine two','Second post',''])")) as? Bool == true)
        expect("thread restoration activates Add post through its native key handler", (try await fullPage.evaluateJavaScript("window.nativeAddKeys===2")) as? Bool == true)
        expect("thread restoration never activates Post", (try await fullPage.evaluateJavaScript("!window.nativeSubmissions")) as? Bool == true)
        expect("thread restoration blocks Enter after unexpected focus changes", (try await fullPage.evaluateJavaScript("window.restoreFocusGuard")) as? Bool == true)
        expect("a fully restored thread keeps its original draft identity", fullStore.drafts.count == 1 && fullStore.draft(fullID) != nil)

        let blocked = folder.appendingPathComponent("not-a-directory")
        try Data().write(to: blocked)
        let failedStore = DraftStore(url: blocked.appendingPathComponent("drafts.json"))
        let (unsaved, failedPage, failedPanel) = try await composer(failedStore)
        _ = try await failedPage.evaluateJavaScript("document.querySelector('#editor').textContent='Keep this text';document.querySelector('#editor').dispatchEvent(new Event('input',{bubbles:true}));void 0")
        try await waitFor { failedStore.drafts.count == 1 }
        expect("native persistence reports a disk error", !unsaved.persistDrafts())
        expect("disk save failure remains visible", failedPanel.status.contains("not saved"))
        failedPanel.status = ""
        unsaved.saveDraft()
        try await waitFor { failedPanel.status.contains("not saved") }
        expect("Save draft keeps the editor open after a disk error", !failedPanel.isExpanded && !failedPage.isHidden)
        let quitAfterDiskError = await prepareToLeave(unsaved)
        expect("quit is cancelled when the current draft cannot be written", !quitAfterDiskError && !failedPage.isHidden)
        var showedSaveAlert = false
        let dismissal = Timer(timeInterval: 0.1, repeats: true) { _ in
            MainActor.assumeIsolated {
                if NSApp.modalWindow != nil { showedSaveAlert = true; NSApp.abortModal() }
            }
        }
        RunLoop.main.add(dismissal, forMode: .modalPanel)
        let canLeave = unsaved.confirmDiscard()
        dismissal.invalidate()
        expect("save failure shows a warning and blocks quit or reload", showedSaveAlert && !canLeave)
        try FileManager.default.removeItem(at: blocked)
        expect("saving and leaving recover after the disk error is fixed", unsaved.confirmDiscard())
        expect("failed-save recovery retains the exact text", DraftStore(url: blocked.appendingPathComponent("drafts.json")).drafts.first?.posts == ["Keep this text"])

        let continuousURL = folder.appendingPathComponent("continuous.json")
        let continuousStore = DraftStore(url: continuousURL)
        let (typing, typingPage, _) = try await composer(continuousStore)
        for index in 0..<8 {
            _ = try await typingPage.evaluateJavaScript("document.querySelector('#editor').textContent='Continuous typing \(index)';document.querySelector('#editor').dispatchEvent(new Event('input',{bubbles:true}));void 0")
            try await Task.sleep(for: .milliseconds(200))
        }
        expect("continuous typing writes drafts without an idle gap", !DraftStore(url: continuousURL).drafts.isEmpty)
        expect("leaving flushes the latest typed text", typing.confirmDiscard()
            && DraftStore(url: continuousURL).drafts.first?.posts == ["Continuous typing 7"])

        // Exercise actual buttons, including a text change made inside the
        // snapshot call before any queued draft message can reach the app.
        func button(_ title: String, in view: NSView) -> NSButton? {
            if let button = view as? NSButton, button.title == title { return button }
            return view.subviews.lazy.compactMap { button(title, in: $0) }.first
        }
        let libraryURL = folder.appendingPathComponent("library.json")
        let libraryStore = DraftStore(url: libraryURL)
        let (_, libraryPage, libraryPanel) = try await composer(libraryStore, threaded: true)
        _ = try await libraryPage.evaluateJavaScript("document.querySelector('#editor').textContent='Cached text';document.querySelector('#editor').dispatchEvent(new Event('input',{bubbles:true}));void 0")
        try await waitFor { libraryStore.drafts.count == 1 }
        let libraryID = libraryStore.drafts[0].id
        _ = try await libraryPage.evaluateJavaScript("""
            const readSnapshot=window.__minimalBirdDraftSnapshot;
            window.__minimalBirdDraftSnapshot=()=>{
              document.querySelector('#editor').textContent='Saved from button\\nSecond line';
              window.__minimalBirdDraftSnapshot=readSnapshot;
              return readSnapshot();
            };void 0
            """)
        button("Save draft", in: libraryPanel)?.performClick(nil)
        try await waitFor { libraryPanel.isExpanded }
        expect("Save draft reads the latest editor text before leaving", DraftStore(url: libraryURL).draft(libraryID)?.posts == ["Saved from button\nSecond line"])
        expect("Save draft opens a library with visible Edit and Delete buttons", button("Edit", in: libraryPanel) != nil && button("Delete", in: libraryPanel) != nil)
        expect("Save draft reports success only after the disk write", libraryPanel.status == "Saved to Draft library.")
        _ = try await libraryPage.evaluateJavaScript("window.webkit.messageHandlers.focus.postMessage({state:'draft',documentID:window.__minimalBirdDocumentID,posts:[''],dirty:false,extras:false});window.webkit.messageHandlers.focus.postMessage({state:'finished',documentID:'obsolete-document'});void 0")
        try await Task.sleep(for: .milliseconds(80))
        expect("late page messages cannot erase a draft from the library", libraryStore.draft(libraryID)?.posts == ["Saved from button\nSecond line"])
        button("Edit", in: libraryPanel)?.performClick(nil)
        expect("Edit returns to the saved draft's editor", !libraryPanel.isExpanded)
        _ = try await libraryPage.evaluateJavaScript("document.querySelector('#editor').textContent='Edited saved draft';document.querySelector('#editor').dispatchEvent(new Event('input',{bubbles:true}));void 0")
        button("Save draft", in: libraryPanel)?.performClick(nil)
        try await waitFor { libraryPanel.isExpanded }
        expect("editing and saving updates one library draft", DraftStore(url: libraryURL).drafts.count == 1 && DraftStore(url: libraryURL).draft(libraryID)?.posts == ["Edited saved draft"])
        button("New draft", in: libraryPanel)?.performClick(nil)
        try await waitFor { !libraryPanel.isExpanded && !libraryPage.isHidden }
        expect("New draft opens an empty editor without deleting the saved draft", (try await libraryPage.evaluateJavaScript("document.querySelector('#editor').textContent===''")) as? Bool == true && DraftStore(url: libraryURL).draft(libraryID) != nil)
        button("Draft library", in: libraryPanel)?.performClick(nil)
        try await waitFor { libraryPanel.isExpanded }
        button("Edit", in: libraryPanel)?.performClick(nil)
        try await waitFor { libraryPanel.status == "Draft opened" }
        expect("Edit restores a saved draft after New draft", (try await libraryPage.evaluateJavaScript("document.querySelector('#editor').textContent==='Edited saved draft'")) as? Bool == true)
        _ = try await libraryPage.evaluateJavaScript("document.querySelector('#editor').textContent='';document.querySelector('#editor').dispatchEvent(new Event('input',{bubbles:true}));void 0")
        button("Save draft", in: libraryPanel)?.performClick(nil)
        try await waitFor { libraryPanel.isExpanded }
        expect("clearing the editor does not delete a saved library draft", DraftStore(url: libraryURL).draft(libraryID)?.posts == ["Edited saved draft"])
        button("Edit", in: libraryPanel)?.performClick(nil)
        try await waitFor { libraryPanel.status == "Draft opened" }
        _ = try await libraryPage.evaluateJavaScript("window.__minimalBirdDraftSnapshot=()=>null;void 0")
        button("New draft", in: libraryPanel)?.performClick(nil)
        try await waitFor { libraryPanel.status.contains("Could not read the editor") }
        let retainedText = (try await libraryPage.evaluateJavaScript("document.querySelector('#editor').textContent==='Edited saved draft'")) as? Bool == true
        expect("New draft stays put when the editor snapshot is unavailable", !libraryPanel.isExpanded && retainedText)
        libraryPanel.setExpanded(true)
        func searchField(in view: NSView) -> NSSearchField? {
            (view as? NSSearchField) ?? view.subviews.lazy.compactMap { searchField(in: $0) }.first
        }
        let search = searchField(in: libraryPanel)!
        search.stringValue = "No matching draft"
        search.sendAction(search.action, to: search.target)
        expect("the draft library filters saved text", button("Edit", in: libraryPanel) == nil)
        search.stringValue = "Edited saved"
        search.sendAction(search.action, to: search.target)
        expect("a matching library draft has an explicit Edit action", button("Edit", in: libraryPanel) != nil)
        func answerDelete(_ answer: NSApplication.ModalResponse) {
            let dismissal = Timer(timeInterval: 0.05, repeats: true) { _ in
                MainActor.assumeIsolated { if NSApp.modalWindow != nil { NSApp.stopModal(withCode: answer) } }
            }
            RunLoop.main.add(dismissal, forMode: .modalPanel)
            button("Delete", in: libraryPanel)?.performClick(nil)
            dismissal.invalidate()
        }
        answerDelete(.alertFirstButtonReturn)
        expect("cancelling Delete preserves the saved draft", DraftStore(url: libraryURL).draft(libraryID) != nil)
        answerDelete(.alertSecondButtonReturn)
        expect("confirmed Delete removes only the selected saved draft", libraryStore.drafts.isEmpty && DraftStore(url: libraryURL).drafts.isEmpty)

        let quitURL = folder.appendingPathComponent("quit-input.json")
        let quitStore = DraftStore(url: quitURL)
        let (quitting, quitPage, quitPanel) = try await composer(quitStore)
        _ = try await quitPage.evaluateJavaScript("document.querySelector('#editor').textContent='Saved before';document.querySelector('#editor').dispatchEvent(new Event('input',{bubbles:true}));void 0")
        try await waitFor { quitStore.drafts.first?.posts == ["Saved before"] }
        _ = quitting.persistDrafts()
        _ = try await quitPage.evaluateJavaScript("const e=document.querySelector('#editor');e.focus();const r=document.createRange();r.selectNodeContents(e);r.collapse(false);getSelection().removeAllRanges();getSelection().addRange(r);void 0")
        quitting.view.window?.makeFirstResponder(quitPage)
        let nativeInput = quitting.view.window?.firstResponder as? NSTextInputClient
        nativeInput?.insertText(" latest input", replacementRange: NSRange(location: NSNotFound, length: 0))
        var quitResult: Bool?
        quitting.prepareToLeave { quitResult = $0 }
        expect("quit waits for native text input to reach WebKit", nativeInput != nil && quitResult == nil)
        let concurrentQuit = await prepareToLeave(quitting)
        expect("a second leave request cannot bypass a pending editor capture", !concurrentQuit)
        try await waitFor { quitResult != nil }
        expect("quit persists the last native input before allowing termination", quitResult == true
            && DraftStore(url: quitURL).drafts.first?.posts == ["Saved before latest input"])
        _ = try await quitPage.evaluateJavaScript("window.fixtureReadDraft=window.__minimalBirdReadDraft;window.__minimalBirdReadDraft=async()=>null;void 0")
        let unreadableQuit = await prepareToLeave(quitting)
        expect("quit is cancelled when the editor cannot be read", !unreadableQuit && !quitPage.isHidden)
        quitPanel.status = ""
        quitting.signOut()
        try await waitFor { quitPanel.status.contains("Could not read the editor") }
        let retainedAfterSignOut = (try await quitPage.evaluateJavaScript("document.querySelector('#editor').textContent==='Saved before latest input'")) as? Bool == true
        expect("sign-out retains the session when editor capture fails", !quitPage.isHidden && retainedAfterSignOut)
        _ = try await quitPage.evaluateJavaScript("window.fixturePendingRead=new Promise(()=>{});window.__minimalBirdReadDraft=()=>window.fixturePendingRead;void 0")
        let timedOutQuit = await prepareToLeave(quitting)
        expect("an unresponsive editor cancels quit instead of leaving it pending", !timedOutQuit
            && quitPanel.status.contains("did not respond"))
        _ = try await quitPage.evaluateJavaScript("window.__minimalBirdReadDraft=window.fixtureReadDraft;void 0")
        let retryQuit = await prepareToLeave(quitting)
        expect("quit can be retried after the editor responds again", retryQuit)

        let queuedURL = folder.appendingPathComponent("queued-input.json")
        let queuedStore = DraftStore(url: queuedURL)
        let (_, queuedPage, queuedPanel) = try await composer(queuedStore)
        _ = try await queuedPage.evaluateJavaScript("""
            document.querySelector('#editor').textContent='Before queued input';
            setTimeout(()=>{
              document.querySelector('#editor').textContent='Including the last queued input';
              document.querySelector('#editor').dispatchEvent(new Event('input',{bubbles:true}));
            },60);void 0
            """)
        button("Save draft", in: queuedPanel)?.performClick(nil)
        try await waitFor { queuedPanel.isExpanded }
        expect("Save draft includes input still queued when its button is clicked", DraftStore(url: queuedURL).drafts.first?.posts == ["Including the last queued input"])
    }

    private func exerciseAuthoring() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MinimalBirdUpload-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let sample = folder.appendingPathComponent("upload-fixture.png")
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 40,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                      isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        for y in 0..<40 { for x in 0..<64 { bitmap.setColor(Palette.accent, atX: x, y: y) } }
        try bitmap.representation(using: .png, properties: [:])!.write(to: sample)
        await load("""
            <main id="background"><article data-testid="tweet">Feed</article></main>
            <div id="uploadPortal"><input type="file" data-testid="fileInput" id="externalFile"><button id="unrelated">Unrelated</button></div>
            <div role="dialog" id="composer">
              <div data-testid="tweetTextarea_0" contenteditable="true" id="editor"></div>
              <div data-testid="toolBar"><button id="media" aria-label="Add photos or video">Media</button><button id="pollButton">Poll</button></div>
              <button data-testid="tweetButton" id="post">Post</button>
            </div>
            """, path: "/compose/post")
        try await js("""
            const file=document.querySelector('#externalFile'), root=document.querySelector('#composer');
            document.querySelector('#media').onclick=()=>file.click();
            file.onchange=()=>{
              if (!file.files.length) return;
              window.fixtureSelectionCount=file.files.length;
              const reader=new FileReader();
              reader.onload=()=>{
                window.fixtureReadBytes=reader.result.byteLength;
                window.fixtureBytes=reader.result;
                const preview=document.createElement('div');preview.id='uploaded';
                const url=URL.createObjectURL(new Blob([reader.result],{type:'image/png'}));
                preview.innerHTML='<img width="160" height="100" alt="Selected image"><button id="removeImage">Remove image</button>';
                preview.querySelector('img').onload=()=>{window.fixtureReadCount=(window.fixtureReadCount||0)+1;};
                preview.querySelector('img').src=url;
                preview.querySelector('button').onclick=()=>{preview.remove();URL.revokeObjectURL(url);file.value='';};
                file.value=''; // React may reset the input once it has read the file.
                root.appendChild(preview);
              };
              reader.readAsArrayBuffer(file.files[0]);
            };
            document.querySelector('#pollButton').onclick=()=>{
              const poll=document.createElement('div');poll.id='pollForm';
              poll.innerHTML='<div role="textbox" contenteditable="true" aria-label="Choice 1">Option</div><button id="removePoll" aria-label="Remove poll">Remove poll</button>';
              poll.querySelector('button').onclick=()=>poll.remove();root.appendChild(poll);
            }; void 0
            """)
        try await check("external upload input stays usable without exposing its siblings", "!document.querySelector('#externalFile').closest('[inert]') && document.querySelector('#unrelated').inert && getComputedStyle(document.querySelector('#unrelated')).visibility==='hidden'")
        try await check("unrequested external file input activation is blocked", "!document.querySelector('#externalFile').dispatchEvent(new MouseEvent('click',{bubbles:true,cancelable:true}))")
        selectedFiles = [sample]
        let before = openPanelCount
        try await js("document.querySelector('#media').click()")
        for _ in 0..<20 {
            if try await js("Boolean(window.fixtureReadBytes) && document.querySelector('#uploaded img')?.naturalWidth===64") as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        if openPanelCount != before + 1 { failures += 1; print("FAIL: media action reaches WebKit's native file chooser") }
        else { print("PASS: media action reaches WebKit's native file chooser") }
        try await check("selected image is readable through the original file input", "window.fixtureSelectionCount===1 && window.fixtureReadBytes > 0")
        if messages.last(where: { $0["state"] as? String == "draft" })?["dirty"] as? Bool != true {
            failures += 1; print("FAIL: preview protects a draft after React resets the file input")
        } else { print("PASS: preview protects a draft after React resets the file input") }
        try await check("unfamiliar preview and its remove button stay usable", "(()=>{const b=document.querySelector('#removeImage');return b && b.getBoundingClientRect().height>0 && getComputedStyle(b).visibility==='visible' && !b.closest('[inert]')})()")
        try await check("attachment pixels decode and the thumbnail has visible geometry", "(()=>{const img=document.querySelector('#uploaded img');return img.naturalWidth===64 && img.naturalHeight===40 && img.getBoundingClientRect().height>0 && getComputedStyle(img).visibility==='visible'})()")
        try await js("document.querySelector('#removeImage').click()")
        try await Task.sleep(for: .milliseconds(50))
        try await check("image can be removed", "!document.querySelector('#uploaded') && document.querySelector('#externalFile').files.length===0")
        if messages.last(where: { $0["state"] as? String == "draft" })?["dirty"] as? Bool != false {
            failures += 1; print("FAIL: removing image clears the attachment-only draft")
        } else { print("PASS: removing image clears the attachment-only draft") }
        selectedFiles = nil
        let beforeCancel = openPanelCount
        try await js("document.querySelector('#media').click()")
        try await Task.sleep(for: .milliseconds(100))
        if openPanelCount != beforeCancel + 1 { failures += 1; print("FAIL: file chooser can be opened again and cancelled") }
        else { print("PASS: file chooser can be opened again and cancelled") }
        try await check("cancelled image selection leaves the composer unchanged", "!document.querySelector('#uploaded') && document.querySelector('#externalFile').files.length===0")
        // Current X mounts the input beside a media button whose press responder
        // can fail after layout flattening. Exercise our direct input activation
        // without a working button handler, then verify the original change path.
        try await js("""
            const media=document.querySelector('#media'), holder=document.createElement('div');
            media.before(holder);holder.append(media,document.querySelector('#externalFile'));
            media.onclick=null;void 0
            """)
        try await Task.sleep(for: .milliseconds(50))
        selectedFiles = [sample]
        let beforeAssociated = openPanelCount
        let beforeRead = try await js("window.fixtureReadCount") as? Int ?? 0
        try await js("document.querySelector('#media').click()")
        for _ in 0..<20 {
            if (try await js("window.fixtureReadCount") as? Int ?? 0) > beforeRead { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        if openPanelCount != beforeAssociated + 1 {
            failures += 1; print("FAIL: associated media button activates original input exactly once")
        } else { print("PASS: associated media button activates original input exactly once") }
        try await check("associated input keeps original readable preview handler", "window.fixtureReadCount===\(beforeRead + 1) && document.querySelector('#uploaded img').naturalWidth===64")
        try await js("document.querySelector('#removeImage').click();document.querySelector('#media').setAttribute('aria-disabled','true')")
        let beforeDisabled = openPanelCount
        try await js("document.querySelector('#media').click()")
        try await Task.sleep(for: .milliseconds(50))
        if openPanelCount != beforeDisabled {
            failures += 1; print("FAIL: disabled media control cannot activate upload")
        } else { print("PASS: disabled media control cannot activate upload") }
        try await js("document.querySelector('#media').removeAttribute('aria-disabled')")
        selectedFiles = nil
        try await exercisePasteAndDrop()
        try await js("document.querySelector('#pollButton').click()")
        try await Task.sleep(for: .milliseconds(50))
        if messages.last(where: { $0["state"] as? String == "draft" })?["dirty"] as? Bool != true {
            failures += 1; print("FAIL: contenteditable poll choices protect an otherwise empty draft")
        } else { print("PASS: contenteditable poll choices protect an otherwise empty draft") }
        try await js("document.querySelector('#removePoll').click()")
        try await js("document.querySelector('#editor').textContent='Keep my text';document.querySelector('#pollButton').click()")
        try await Task.sleep(for: .milliseconds(50))
        try await check("poll exit stays visible even with contenteditable choices", "(()=>{const b=document.querySelector('#removePoll');return b.getBoundingClientRect().height>0 && getComputedStyle(b).visibility==='visible'})()")
        try await js("document.querySelector('#removePoll').click()")
        try await Task.sleep(for: .milliseconds(50))
        try await check("removing a poll preserves text", "!document.querySelector('#pollForm') && document.querySelector('#editor').textContent==='Keep my text' && getComputedStyle(document.querySelector('#background')).visibility==='hidden'")
        try await js("""
            document.querySelector('#editor').textContent='';
            const photo=document.createElement('div');photo.id='backgroundPhoto';photo.style.width='160px';photo.style.height='100px';
            document.querySelector('#editor').parentElement.appendChild(photo);void 0
            """)
        try await Task.sleep(for: .milliseconds(50))
        try await js("document.querySelector('#backgroundPhoto').style.backgroundImage=`url(${URL.createObjectURL(new Blob([window.fixtureBytes],{type:'image/png'}))})`;void 0")
        try await Task.sleep(for: .milliseconds(50))
        try await check("background-image preview without buttons survives a late style change", "(()=>{const p=document.querySelector('#backgroundPhoto');return getComputedStyle(p).backgroundImage!=='none' && p.getBoundingClientRect().height===100 && getComputedStyle(p).visibility==='visible'})()")
        if messages.last(where: { $0["state"] as? String == "draft" })?["dirty"] as? Bool != true {
            failures += 1; print("FAIL: background-image attachments participate in draft protection")
        } else { print("PASS: background-image attachments participate in draft protection") }
        try await js("document.querySelector('#backgroundPhoto').remove();void 0")
    }

    private func exercisePasteAndDrop() async throws {
        let pickerCount = openPanelCount
        for method in ["paste", "drop", "bodyPaste"] {
            let before = try await js("window.fixtureReadCount") as? Int ?? 0
            try await js("""
                (()=>{
                const transfer=new DataTransfer();transfer.items.add(new File([window.fixtureBytes],'\(method).png',{type:'image/png'}));
                const editor=\(method == "bodyPaste" ? "document.body" : "document.querySelector('#editor')");
                editor.dispatchEvent(\(method != "drop" ? "new ClipboardEvent('paste',{bubbles:true,cancelable:true,clipboardData:transfer})" : "new DragEvent('drop',{bubbles:true,cancelable:true,dataTransfer:transfer})"));
                })()
                """)
            for _ in 0..<20 {
                if (try await js("window.fixtureReadCount") as? Int ?? 0) > before { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            try await check("\(method) sends image bytes to X's original upload handler", "window.fixtureReadCount===\(before + 1) && document.querySelector('#uploaded img').naturalWidth===64")
            try await check("\(method) thumbnail stays visible and removable", "(()=>{const p=document.querySelector('#uploaded');return p.getBoundingClientRect().height>0 && getComputedStyle(p).visibility==='visible' && !document.querySelector('#removeImage').closest('[inert]')})()")
            try await js("document.querySelector('#removeImage').click()")
            try await Task.sleep(for: .milliseconds(50))
        }
        if openPanelCount != pickerCount { failures += 1; print("FAIL: paste and drop avoid opening a file chooser") }
        else { print("PASS: paste and drop avoid opening a file chooser") }
        try await check("plain text paste remains available", "(()=>{const d=new DataTransfer();d.setData('text/plain','ordinary text');return document.querySelector('#editor').dispatchEvent(new ClipboardEvent('paste',{bubbles:true,cancelable:true,clipboardData:d}))})()")
        try await check("file drag is accepted inside the composer", "(()=>{const d=new DataTransfer();d.items.add(new File([window.fixtureBytes],'drop.png',{type:'image/png'}));return !document.querySelector('#editor').dispatchEvent(new DragEvent('dragover',{bubbles:true,cancelable:true,dataTransfer:d}))})()")
        let before = try await js("window.fixtureReadCount") as? Int ?? 0
        try await js("const outside=new DataTransfer();outside.items.add(new File([window.fixtureBytes],'outside.png',{type:'image/png'}));document.querySelector('#unrelated').dispatchEvent(new DragEvent('drop',{bubbles:true,cancelable:true,dataTransfer:outside}));void 0")
        try await Task.sleep(for: .milliseconds(50))
        try await check("dropping outside the composer does not attach a file", "window.fixtureReadCount===\(before) && !document.querySelector('#uploaded')")
    }

    /// Renders the real window around synthetic X pages for visual review.
    /// Set MINIMAL_BIRD_SNAPSHOTS to a folder; nothing contacts X.
    private func snapshots(to folder: URL) async {
        let previousExpansion = UserDefaults.standard.object(forKey: "DraftsExpanded")
        UserDefaults.standard.set(false, forKey: "DraftsExpanded")
        defer { UserDefaults.standard.set(previousExpansion, forKey: "DraftsExpanded") }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let avatar = "data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' width='40' height='40'><rect width='40' height='40' fill='%237d8a86'/></svg>"
        let blue = "rgb(29,155,240)", grey = "rgb(83,100,113)", rule = "rgb(207,217,222)"
        func post(_ index: Int, _ text: String, active: Bool) -> String {
            let connector: String = index == 0 ? "<div style='width:2px;flex:1;margin-top:4px;background:\(rule)'></div>" : ""
            let audience: String = index == 0 ? "<button style='color:\(blue);border:1px solid \(rule);border-radius:999px;padding:2px 12px;font-weight:700;font-size:14px;background:#fff'>Everyone</button>" : ""
            let top: String = index == 0 ? "4" : "12"
            let opacity: String = active ? "1" : "0.5"
            let parts: [String] = [
                "<div style='display:flex;gap:10px;padding-top:\(top)px;opacity:\(opacity)'>",
                "<div style='display:flex;flex-direction:column;align-items:center;width:40px'>",
                "<div data-testid='UserAvatar-Container-writer'><img src=\"\(avatar)\" style='width:40px;height:40px;border-radius:50%'></div>",
                connector, "</div><div style='flex:1;min-width:0'>", audience,
                "<div data-testid='tweetTextarea_\(index)RichTextInputContainer' style='padding:10px 0'>",
                "<div data-testid='tweetTextarea_\(index)' contenteditable='true' style='font-size:20px;line-height:24px;outline:none;color:rgb(15,20,25)'>",
                text, "</div></div></div></div>"
            ]
            return parts.joined()
        }
        let tools = ["M4 5h16v14H4z", "M5 12h14M12 5v14", "M12 3a9 9 0 1 0 0 18a9 9 0 1 0 0-18z"].map { (path: String) -> String in
            "<button aria-label='Tool' style='color:\(blue);background:none;border:0'><svg viewBox='0 0 24 24' width='20' height='20' style='fill:none;stroke:currentColor;stroke-width:2'><path d='\(path)'/></svg></button>"
        }.joined()
        let first = post(0, "Design your working environment. Social media always drags; it is hard to keep the willpower not to get pulled into the feed.<br>So I built a small composer: <span style='color:\(blue)'>github.com/Erik5000/minimal-bird</span>", active: true)
        let second = post(1, "", active: false)
        let page = """
            <!doctype html><html><head><meta charset="utf-8"></head><body style="margin:0;background:#fff;font-family:Helvetica;color:rgb(15,20,25)">
            <main><article data-testid="tweet">Feed</article></main>
            <div role="dialog" style="background:#fff">
              <div style="display:flex;justify-content:space-between;align-items:center;height:52px">
                <button data-testid="app-bar-close">X</button>
                <div style="display:flex;gap:12px"><button data-testid="unsentButton" style="color:\(blue)">Drafts</button>
                <button data-testid="tweetButton" disabled aria-disabled="true" style="background:\(blue);color:#fff;border:0;border-radius:999px;padding:0 16px;height:36px;font-weight:700;font-size:15px;opacity:.5">Post all</button></div>
              </div>
              \(first)
              <div style="margin-left:50px;display:flex;border:1px solid \(rule);border-radius:16px;overflow:hidden" data-testid="card.wrapper">
                <div style="width:110px;height:96px;background:rgb(247,249,249)"></div>
                <div style="padding:12px;font-size:15px;border-left:1px solid \(rule)"><div style="color:\(grey)">github.com</div><div>Minimal Bird: a distraction-free composer</div></div>
              </div>
              <div style="padding-left:50px;border-bottom:1px solid rgb(239,243,244)"><button aria-label="Everyone can reply" style="color:\(blue);font-weight:700;font-size:14px;padding:10px 0;background:none;border:0">Everyone can reply</button></div>
              <div data-testid="toolBar" style="display:flex;justify-content:space-between;align-items:center;padding:8px 0 8px 40px">
                <div style="display:flex;gap:14px">\(tools)</div>
                <div style="display:flex;align-items:center;gap:10px">
                  <svg width="26" height="26"><circle cx="13" cy="13" r="11" fill="none" stroke-width="2" style="stroke:rgb(239,243,244)"/><circle cx="13" cy="13" r="11" fill="none" stroke-width="2" stroke-dasharray="44 100" style="stroke:\(blue)"/></svg>
                  <button data-testid="addButton" aria-label="Add post" style="color:\(blue);border:1px solid \(rule);border-radius:50%;width:26px;height:26px;background:none">+</button>
                </div>
              </div>
              \(second)
            </div></body></html>
            """
        let store = DraftStore(url: nil)
        store.save(["Notes on calm software: fewer surfaces, more finishing."], id: nil, now: Date().addingTimeInterval(-7_200))
        store.save(["A thread about small tools", "Second part of the thread"], id: nil, now: Date().addingTimeInterval(-86_400 * 2))
        store.save(["Reply idea for later"], id: nil, now: Date().addingTimeInterval(-600))
        let delegate = AppDelegate()
        let controller = ComposerController(dataStore: .nonPersistent(), drafts: store)
        let window = delegate.makePreviewWindow(for: controller, handle: "@writer")
        window.setContentSize(NSSize(width: 580, height: 660))
        window.makeKeyAndOrderFront(nil)
        controller.showFixture(page)
        try? await Task.sleep(for: .seconds(2))
        await write(controller, "composer.png", to: folder)
        controller.toggleDrafts()
        try? await Task.sleep(for: .milliseconds(600))
        expect("long draft titles keep the library window compact", abs(window.contentView!.bounds.width - 580) < 1)
        await write(controller, "composer-drafts.png", to: folder)
        window.setContentSize(NSSize(width: 440, height: 660))
        try? await Task.sleep(for: .milliseconds(100))
        expect("the draft library fits the minimum window width", abs(window.contentView!.bounds.width - 440) < 1)
        await write(controller, "library-narrow.png", to: folder)
        window.setContentSize(NSSize(width: 580, height: 660))
        controller.start(demo: true)
        try? await Task.sleep(for: .milliseconds(300))
        await write(controller, "welcome.png", to: folder)
        window.close()
    }

    private func write(_ controller: ComposerController, _ name: String, to folder: URL) async {
        guard let rep = await controller.snapshotWindow(), let data = rep.representation(using: .png, properties: [:]) else {
            print("NOTE: snapshot \(name) unavailable"); return
        }
        try? data.write(to: folder.appendingPathComponent(name))
        print("Snapshot: \(name)")
    }

    private func checkAccountStores() async throws {
        let firstID = UUID(), secondID = UUID()
        await exerciseAccountStores(firstID: firstID, secondID: secondID)
        // Drain callback/autorelease references before removing these disposable stores.
        try await Task.sleep(for: .milliseconds(100))
        try await WKWebsiteDataStore.remove(forIdentifier: firstID)
        try await WKWebsiteDataStore.remove(forIdentifier: secondID)
    }

    private func exerciseAccountStores(firstID: UUID, secondID: UUID) async {
        let first = autoreleasepool { WKWebsiteDataStore(forIdentifier: firstID) }
        let second = autoreleasepool { WKWebsiteDataStore(forIdentifier: secondID) }
        let cookie = HTTPCookie(properties: [.domain: "fixtures.invalid", .path: "/", .name: "fixture-session", .value: "test-only", .expires: Date().addingTimeInterval(60)])!
        await first.httpCookieStore.setCookie(cookie)
        let otherCookies = await second.httpCookieStore.allCookies()
        let restored = autoreleasepool { WKWebsiteDataStore(forIdentifier: firstID) }
        let restoredCookies = await restored.httpCookieStore.allCookies()
        let isolated = !otherCookies.contains(where: { $0.name == "fixture-session" })
            && restoredCookies.contains(where: { $0.name == "fixture-session" })
        if !isolated { failures += 1 }
        print("\(isolated ? "PASS" : "FAIL"): persistent account stores are isolated and reopen by identifier")
        await first.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        await second.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
    }
}
