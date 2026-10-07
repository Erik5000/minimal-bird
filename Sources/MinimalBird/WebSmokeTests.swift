// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Minimal Bird contributors

import AppKit
import WebKit

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
            try? await Task.sleep(for: .seconds(20))
            print("FAIL: WebKit tests timed out. Run in an unrestricted desktop session.")
            exit(1)
        }
        Task {
            do { try await exercise() }
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
        try await check("close button is hidden", "getComputedStyle(document.querySelector('#close')).display === 'none'")
        try await check("profile avatar remains visible", "getComputedStyle(document.querySelector('#avatar img')).visibility === 'visible'")
        try await js("document.querySelector('[data-mb-part=identity]').click()")
        try await Task.sleep(for: .milliseconds(50))
        if messages.last?["state"] as? String != "accounts" {
            failures += 1; print("FAIL: profile header opens native account menu")
        } else { print("PASS: profile header opens native account menu") }
        try await exerciseFocusAndPopovers()
        web.setFrameSize(NSSize(width: 1680, height: 960))
        try await js("document.querySelector('[data-testid=SideNav_AccountSwitcher_Button]').appendChild(document.querySelector('#avatar'));void 0")
        try await Task.sleep(for: .milliseconds(50))
        try await check("avatar stays in the composer when X moves it outside at wide sizes", "(()=>{const a=document.querySelector('[data-mb-fallback-avatar]'),r=a?.getBoundingClientRect();return a?.src==='https://fixtures.invalid/avatar.png' && r.width===36 && r.height===36 && getComputedStyle(a).visibility==='visible' && document.querySelector('main').inert})()")
        web.setFrameSize(NSSize(width: 480, height: 420))
        try await js("document.querySelector('#composer').appendChild(document.querySelector('#avatar'));document.querySelector('#avatar').style.display='none';void 0")
        try await Task.sleep(for: .milliseconds(50))
        try await check("original avatar returns without duplication after narrowing", "!document.querySelector('[data-mb-fallback-avatar]') && document.querySelector('#avatar').getBoundingClientRect().width===36 && getComputedStyle(document.querySelector('#avatar')).display !== 'none'")
        web.setFrameSize(NSSize(width: 760, height: 600))
        try await check("Post stays below the writing area and inside the window", "(()=>{const p=document.querySelector('#post').getBoundingClientRect(),e=document.querySelector('#editor').getBoundingClientRect();return p.top > e.bottom && p.right <= innerWidth && p.bottom <= innerHeight})()")
        try await check("styling preserves the original editor and upload input parents", "document.querySelector('#editor').parentElement.dataset.testid === 'tweetTextarea_0RichTextInputContainer' && document.querySelector('#file').parentElement.dataset.testid === 'toolBar'")
        try await check("compact wrappers retain measurable geometry", "(()=>{const r=document.querySelector('#writingHost').getBoundingClientRect();return r.width>0 && r.height>0})()")
        try await js("const media=document.createElement('div');media.dataset.testid='attachments';media.id='preview';media.textContent='Chart attachment';document.querySelector('#writingHost').appendChild(media);void 0")
        try await Task.sleep(for: .milliseconds(50))
        try await check("new media previews remain visible after layout changes", "getComputedStyle(document.querySelector('#preview')).display !== 'none' && document.querySelector('#preview').getBoundingClientRect().height > 0")
        try await js("const next=document.createElement('div');next.id='thread';next.dataset.testid='tweetTextarea_1';next.contentEditable='true';next.textContent='Second post';document.querySelector('#writingHost').appendChild(next);void 0")
        try await Task.sleep(for: .milliseconds(50))
        try await check("expanded authoring falls back without hiding additional editors", "!document.querySelector('#composer').hasAttribute('data-mb-designed') && getComputedStyle(document.querySelector('#thread')).visibility === 'visible' && document.querySelector('#thread').getBoundingClientRect().height > 0")
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
        try await check("standalone back button stays hidden", "getComputedStyle(document.querySelector('#back')).display === 'none'")
        try await exerciseAuthoring()
        try await checkAccountStores()
    }

    private func exerciseFocusAndPopovers() async throws {
        try await js("""
            const editor=document.querySelector('#editor');
            editor.textContent='Hello';editor.focus();
            const range=document.createRange();range.setStart(editor.firstChild,2);range.collapse(true);
            getSelection().removeAllRanges();getSelection().addRange(range);void 0
            """)
        try await Task.sleep(for: .milliseconds(50))
        try await js("document.querySelector('[data-mb-part=identity]').focus();window.__minimalBirdFocusEditor()")
        try await check("returning from account menu restores editor and caret", "document.activeElement.id==='editor' && getSelection().anchorOffset===2")
        try await js("document.execCommand('insertText',false,'!')")
        try await check("typing resumes at the saved caret", "document.querySelector('#editor').textContent==='He!llo'")
        try await js("""
            const choice=document.createElement('input');choice.id='focusChoice';
            document.querySelector('#composer').appendChild(choice);choice.focus();void 0
            """)
        try await check("restoring focus does not steal a poll input", "window.__minimalBirdFocusEditor() && document.activeElement.id==='focusChoice'")
        try await js("document.querySelector('#focusChoice').remove();document.querySelector('#editor').textContent='';void 0")
        try await Task.sleep(for: .milliseconds(50))
        try await js("document.querySelector('[data-mb-part=identity]').focus();document.querySelector('[data-mb-part=writing]').dispatchEvent(new MouseEvent('mousedown',{bubbles:true,cancelable:true,button:0}))")
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
        try await check("image can be removed and compact writing restored", "!document.querySelector('#uploaded') && document.querySelector('#externalFile').files.length===0 && document.querySelector('#composer').hasAttribute('data-mb-designed')")
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
        try await check("poll exit stays visible even with contenteditable choices", "(()=>{const b=document.querySelector('#removePoll');return b.getBoundingClientRect().height>0 && getComputedStyle(b).visibility==='visible' && !document.querySelector('#composer').hasAttribute('data-mb-designed')})()")
        try await js("document.querySelector('#removePoll').click()")
        try await Task.sleep(for: .milliseconds(50))
        try await check("removing a poll preserves text and returns to compact writing", "!document.querySelector('#pollForm') && document.querySelector('#editor').textContent==='Keep my text' && document.querySelector('#composer').hasAttribute('data-mb-designed') && getComputedStyle(document.querySelector('#background')).visibility==='hidden'")
        try await js("""
            document.querySelector('#editor').textContent='';
            const photo=document.createElement('div');photo.id='backgroundPhoto';photo.style.width='160px';photo.style.height='100px';
            document.querySelector('#editor').parentElement.appendChild(photo);void 0
            """)
        try await Task.sleep(for: .milliseconds(50))
        try await js("document.querySelector('#backgroundPhoto').style.backgroundImage=`url(${URL.createObjectURL(new Blob([window.fixtureBytes],{type:'image/png'}))})`;void 0")
        try await Task.sleep(for: .milliseconds(50))
        try await check("background-image preview without buttons survives a late style change", "(()=>{const p=document.querySelector('#backgroundPhoto');return getComputedStyle(p).backgroundImage!=='none' && p.getBoundingClientRect().height===100 && getComputedStyle(p).visibility==='visible' && !document.querySelector('#composer').hasAttribute('data-mb-designed')})()")
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
