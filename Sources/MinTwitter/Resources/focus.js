// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Min Twitter contributors

(() => {
  'use strict';
  if (window.__minTwitterInstalled) return;
  window.__minTwitterInstalled = true;

  const composerPaths = new Set(['/compose/post', '/compose/tweet']);
  const loginPaths = new Set(['/login', '/i/flow/login', '/i/jf/onboarding/web', '/account/access',
    '/account/login_challenge', '/account/begin_password_reset', '/account/reset_password']);
  const landingPaths = new Set(['/', '/home', '/i/flow/consent_flow']);
  const editorSelector = '[data-testid^="tweetTextarea_"][contenteditable="true"], [data-testid^="tweetTextarea_"] [contenteditable="true"]';
  const postSelector = '[data-testid="tweetButton"], [data-testid="tweetButtonInline"]';
  let surface = null;
  let lastState = '';
  let hadComposer = false;
  let postRequested = false;
  let finished = false;
  let scheduled = false;
  let internalNavigation = false;
  let lastDraft = null;
  let pendingMedia = false;
  const inertNodes = new Set();
  const identities = new WeakMap();
  const layouts = new WeakMap();
  const fallbackAvatars = new WeakMap();
  let avatarURL = null;
  let authoringClick = false;
  const authorizedUploads = new WeakSet();
  const popoverSelector = '[role="dialog"], [role="menu"], [role="listbox"], [role="group"][tabindex="0"]';
  const forbiddenSurface = '[data-testid="tweet"], [data-testid="cellInnerDiv"], [data-testid="sidebarColumn"], header[role="banner"]';
  const popovers = new Set();
  const popupPaths = new Set();
  let popupRequest = null;
  let lastEditor = null;
  let lastSelection = null;

  function editable(node) {
    return node instanceof Element && (node.isContentEditable
      || node.matches('textarea, input:not([type="file"]):not([type="hidden"]):not([type="button"]):not([type="submit"]):not([type="radio"]):not([type="checkbox"])'));
  }

  function focusEditor() {
    if (!surface?.isConnected || !surface.querySelector(editorSelector) || popovers.size) return false;
    if (surface.contains(document.activeElement) && editable(document.activeElement)) return true;
    const editor = lastEditor?.isConnected && surface.contains(lastEditor) ? lastEditor : surface.querySelector(editorSelector);
    if (!editor || editor.closest('[inert]')) return false;
    editor.focus({ preventScroll: true });
    if (lastSelection && editor.contains(lastSelection.commonAncestorContainer)) {
      const selection = getSelection();
      selection.removeAllRanges(); selection.addRange(lastSelection);
    }
    return document.activeElement === editor;
  }
  window.__minTwitterFocusEditor = focusEditor;

  document.addEventListener('focusin', event => {
    if (surface?.contains(event.target) && editable(event.target)) lastEditor = event.target;
  });
  document.addEventListener('selectionchange', () => {
    const selection = getSelection();
    if (lastEditor?.isConnected && selection.rangeCount && lastEditor.contains(selection.anchorNode)
        && lastEditor.contains(selection.focusNode)) lastSelection = selection.getRangeAt(0).cloneRange();
  });

  function requestPopover(trigger, pressStart = false) {
    if (!pressStart && popupRequest?.trigger === trigger && performance.now() <= popupRequest.until) return;
    popupRequest = { trigger, until: performance.now() + 1500,
      existing: new Set([...document.querySelectorAll(popoverSelector)].filter(node => node.getClientRects().length)) };
  }

  function updatePopovers(root) {
    const hadPopover = popovers.size > 0;
    for (const node of popovers) {
      if (!node.isConnected || !node.getClientRects().length || node.getAttribute('aria-hidden') === 'true'
          || node.closest(forbiddenSurface) || node.querySelector(forbiddenSurface)) {
        node.removeAttribute('data-mt-popover'); popovers.delete(node);
      }
    }
    if (popupRequest && performance.now() <= popupRequest.until) {
      for (const node of document.querySelectorAll(popoverSelector)) {
        if (popupRequest.existing.has(node) || root.contains(node) || node.contains(root)
            || node.closest(forbiddenSurface) || node.querySelector(forbiddenSurface)
            || node.querySelector(editorSelector) || !node.getClientRects().length
            || node.getAttribute('aria-hidden') === 'true'
            || [...popovers].some(popup => popup !== node && popup.contains(node))) continue;
        for (const child of popovers) {
          if (child !== node && node.contains(child)) {
            child.removeAttribute('data-mt-popover'); popovers.delete(child);
          }
        }
        popovers.add(node);
        node.setAttribute('data-mt-popover', '');
        restrictSurface(node, 'authoring'); // Keep the popup's own close/back controls.
      }
    } else { popupRequest = null; }
    if (popovers.size && ![...popovers].some(popup => popup.contains(document.activeElement))) {
      // X can try to focus a newly mounted portal before our mutation scan has
      // removed inert from its path. Retry after all allowed paths are restored.
      const popup = [...popovers][0];
      queueMicrotask(() => {
        if (!popup.isConnected || popup.closest('[inert]') || !document.hasFocus()
            || popup.contains(document.activeElement)) return;
        const field = [...popup.querySelectorAll('input, textarea')].find(editable);
        const target = field || (popup.hasAttribute('tabindex') ? popup
          : popup.querySelector('button, [tabindex="0"], input'));
        target?.focus({ preventScroll: true });
      });
    }
    if (hadPopover && !popovers.size && document.hasFocus()) queueMicrotask(focusEditor);
  }

  function report(state, extra = {}) {
    const message = { state, ...extra };
    const key = JSON.stringify(message);
    if (key === lastState) return;
    lastState = key;
    window.webkit?.messageHandlers?.focus?.postMessage(message);
  }

  function updateDraft() {
    if (!surface?.isConnected || !surface.querySelector(editorSelector)) return;
    const attachments = hasAuthoringMedia(surface);
    const fileInputs = new Set([...surface.querySelectorAll('input[type="file"]'),
      ...[...document.querySelectorAll('input[type="file"][data-testid="fileInput"]')].filter(input => authorizedUploads.has(input))]);
    const selectedFiles = [...fileInputs].some(input => input.files?.length);
    if (attachments) pendingMedia = false;
    const dirty = pendingMedia || attachments
      || selectedFiles
      || [...surface.querySelectorAll('input:not([type="file"]):not([type="hidden"]), textarea')].some(input => input.value.trim().length > 0)
      || [...surface.querySelectorAll('[contenteditable="true"]')].some(editor => editor.textContent.trim().length > 0);
    if (dirty === lastDraft) return;
    lastDraft = dirty;
    window.webkit?.messageHandlers?.focus?.postMessage({ state: 'draft', dirty });
  }

  const style = document.createElement('style');
  style.id = 'min-twitter-curtain';
  style.textContent = `
    html { visibility: hidden !important; background: #faf9f6 !important; }
    body * { visibility: hidden !important; pointer-events: none !important; }
    [data-mt-surface], [data-mt-surface] *, [data-mt-popover], [data-mt-popover] * {
      visibility: visible !important; pointer-events: auto !important;
    }
    [data-mt-surface] button *, [data-mt-popover] button * { pointer-events: none !important; }
    [data-mt-popup-path] {
      transform: none !important; filter: none !important; backdrop-filter: none !important;
      -webkit-backdrop-filter: none !important; perspective: none !important;
      contain: none !important; will-change: auto !important; opacity: 1 !important;
      overflow: visible !important; clip: auto !important; clip-path: none !important;
    }
    [data-mt-popover] {
      position: fixed !important; inset: auto !important; left: 50% !important;
      bottom: 76px !important; transform: translateX(-50%) !important;
      width: 360px !important; min-width: 0 !important;
      max-width: calc(100vw - 48px) !important; box-sizing: border-box !important;
      max-height: calc(100vh - 110px) !important; overflow: auto !important;
      z-index: 100 !important; background: #faf9f6 !important;
      border: 1px solid #e4e4dd !important; border-radius: 12px !important;
      box-shadow: 0 8px 32px #30342e26 !important;
    }
    [data-mt-hidden], [data-mt-hidden] *,
    [data-testid="sidebarColumn"], [data-testid="sidebarColumn"] *,
    header[role="banner"], header[role="banner"] *,
    [data-testid="tweet"], [data-testid="tweet"] *,
    [aria-label="Timeline: Your Home Timeline"],
    [aria-label="Timeline: Your Home Timeline"] * {
      visibility: hidden !important; pointer-events: none !important;
    }
    [data-mt-hidden] { display: none !important; }
    [data-mt-surface] { box-shadow: none !important; }
    html, body { background: #faf9f6 !important; }
    html:has([data-mt-surface="composer"]),
    body:has([data-mt-surface="composer"]) { overflow: hidden !important; }
    [data-mt-surface="composer"] {
      position: fixed !important; top: 0 !important; left: 0 !important;
      right: 0 !important; bottom: 0 !important;
      width: 100% !important; max-width: none !important;
      min-width: 0 !important; min-height: 0 !important;
      height: 100% !important; max-height: none !important;
      margin: 0 !important; border: none !important;
      border-radius: 0 !important; overflow-y: auto !important;
      background: #faf9f6 !important; padding: 24px 28px !important;
      box-sizing: border-box !important;
    }
    [data-mt-layout="bridge"] {
      display: grid !important; grid-template-columns: subgrid !important;
      grid-template-rows: subgrid !important; grid-area: 1 / 1 / -1 / -1 !important;
      position: static !important; width: auto !important; height: auto !important;
      min-width: 0 !important; min-height: 0 !important; max-width: none !important;
      max-height: none !important; margin: 0 !important; padding: 0 !important;
      border: 0 !important; background: transparent !important; overflow: visible !important;
      backdrop-filter: none !important; -webkit-backdrop-filter: none !important;
      filter: none !important; transform: none !important; will-change: auto !important;
      contain: none !important; opacity: 1 !important; z-index: auto !important;
      align-self: stretch !important; justify-self: stretch !important;
      pointer-events: none !important;
    }
    [data-mt-layout="omit"] { display: none !important; }
    [data-mt-surface="composer"][data-mt-designed] {
      display: grid !important;
      grid-template-columns: 38px minmax(0, 1fr);
      grid-template-rows: 38px minmax(110px, 1fr) auto 18px 40px;
      gap: 16px 12px !important;
      align-content: stretch !important;
    }
    [data-mt-part="avatar"] {
      display: block !important; flex-shrink: 0 !important;
      grid-area: 1 / 1 !important; width: 36px !important;
      height: 36px !important; min-width: 0 !important;
      margin: 0 !important; align-self: center !important;
      object-fit: cover !important; border-radius: 50% !important;
    }
    [data-mt-part="avatar"] div, [data-mt-part="avatar"] a {
      display: block !important; width: 100% !important; height: 100% !important;
      min-width: 0 !important; min-height: 0 !important;
    }
    [data-mt-part="avatar"] img {
      display: block !important; width: 100% !important; height: 100% !important;
      object-fit: cover !important; border-radius: 50% !important;
    }
    [data-mt-part="identity"] {
      grid-area: 1 / 2 !important; align-self: center;
      padding-right: 28px; color: #33372f !important;
      font: 600 13px -apple-system, BlinkMacSystemFont, sans-serif;
      line-height: 20px; cursor: pointer;
    }
    [data-mt-part="identity"]:focus-visible { outline: 2px solid #b8492e; outline-offset: 4px; border-radius: 3px; }
    [data-mt-part="identity"] small {
      display: block; color: #97978e !important; font-size: 11px; font-weight: 400;
    }
    [data-mt-part="writing"] {
      grid-area: 2 / 1 / 3 / -1 !important;
      min-height: 110px !important; height: 100% !important;
      max-height: none !important; width: 100% !important;
      margin: 0 !important; overflow-y: auto !important;
      color: #30342e !important; background: transparent !important;
      border: none !important; padding-top: 8px !important;
      box-sizing: border-box !important;
    }
    [data-mt-part="writing"] div {
      background-color: transparent !important; border: none !important;
    }
    [data-mt-part="writing"] [contenteditable="true"],
    [data-mt-part="writing"][contenteditable="true"],
    [data-mt-part="writing"] .public-DraftEditorPlaceholder-root {
      font: 400 20px/1.6 -apple-system, BlinkMacSystemFont, sans-serif !important;
      letter-spacing: -0.3px !important;
    }
    [data-mt-part="writing"] .public-DraftEditorPlaceholder-root { color: #aaa99f !important; }
    [data-mt-part="writing"] .public-DraftEditorPlaceholder-inner {
      font: 400 20px/1.6 -apple-system, BlinkMacSystemFont, sans-serif !important;
      color: #aaa99f !important; letter-spacing: -0.3px !important;
    }
    [data-mt-part="media"] {
      grid-area: 3 / 1 / 4 / -1 !important; max-height: 150px !important;
      overflow-y: auto !important; border-radius: 10px !important;
    }
    [data-mt-part="reply"] {
      grid-area: 4 / 1 / 5 / -1 !important; justify-self: start !important;
      color: #8c8e84 !important; font-size: 11px !important;
      height: 18px !important; min-height: 0 !important; padding: 0 !important;
      background: transparent !important;
    }
    [data-mt-part="reply"] * { color: #8c8e84 !important; font-size: 11px !important; }
    [data-mt-part="reply"] svg { width: 12px !important; height: 12px !important; }
    [data-mt-part="tools"] {
      grid-area: 5 / 1 / 6 / -1 !important;
      height: 40px !important; min-height: 0 !important; width: 100% !important;
      border: none !important; border-top: 1px solid #e4e4dd !important;
      padding: 9px 112px 0 0 !important; margin: 0 !important;
      box-sizing: border-box !important; background: transparent !important;
    }
    [data-mt-part="tools"] div, [data-mt-part="tools"] nav { background-color: transparent !important; border: none !important; }
    [data-mt-part="tools"] nav,
    [data-mt-part="tools"] [role="tablist"] { height: 30px !important; min-height: 30px !important; }
    [data-mt-part="tools"] button { color: #858d81 !important; width: 30px !important; height: 30px !important; }
    [data-mt-part="tools"] svg { width: 18px !important; height: 18px !important; color: #858d81 !important; }
    [data-mt-part="tools"] [data-testid="ScrollSnap-prevButtonWrapper"],
    [data-mt-part="tools"] [data-testid="ScrollSnap-nextButtonWrapper"] { display: none !important; }
    [data-mt-surface="composer"][data-mt-designed] [data-testid="tweetButton"],
    [data-mt-surface="composer"][data-mt-designed] [data-testid="tweetButtonInline"] {
      position: fixed !important; right: 28px !important; bottom: 24px !important;
      width: 86px !important; min-width: 86px !important; height: 34px !important;
      min-height: 34px !important; margin: 0 !important; padding: 0 15px !important;
      background-color: #b8492e !important; border: none !important;
      border-radius: 9px !important; z-index: 2 !important;
      font: 600 13px -apple-system, BlinkMacSystemFont, sans-serif !important;
    }
    [data-mt-surface="composer"] [data-testid="tweetButton"] *,
    [data-mt-surface="composer"] [data-testid="tweetButtonInline"] * { font-size: 13px !important; }
    [data-mt-surface="composer"] [data-testid="unsentButton"],
    [data-mt-surface="composer"] [data-testid="gifSearchButton"],
    [data-mt-surface="composer"] [data-testid="geoButton"],
    [data-mt-surface="composer"] [data-testid="scheduleOption"],
    [data-mt-surface="composer"] [data-testid="contentDisclosureButton"] { display: none !important; }
  `;

  function attachStyle() {
    if (document.documentElement && !style.isConnected) document.documentElement.appendChild(style);
  }

  function hideSurface() {
    document.querySelectorAll('[data-mt-surface]').forEach(node => node.removeAttribute('data-mt-surface'));
    surface = null;
    popovers.forEach(node => node.removeAttribute('data-mt-popover'));
    popovers.clear();
    popupPaths.forEach(node => node.removeAttribute('data-mt-popup-path'));
    popupPaths.clear();
    popupRequest = null;
  }

  function showSurface(node, mode) {
    if (surface !== node) {
      hideSurface();
      node.setAttribute('data-mt-surface', mode);
      surface = node;
    }
    // Remove the rest of the page from keyboard navigation and accessibility.
    // X may mount its hidden upload input beside, rather than inside, the
    // composer. Keep that input's path usable without revealing its siblings.
    const supported = mode === 'composer'
      ? [...document.querySelectorAll('input[type="file"][data-testid="fileInput"]'), ...popovers] : [];
    const nextPopupPaths = new Set();
    for (const popup of popovers) {
      let ancestor = popup.parentElement;
      while (ancestor) { nextPopupPaths.add(ancestor); ancestor = ancestor.parentElement; }
    }
    for (const path of popupPaths) {
      if (!nextPopupPaths.has(path)) { path.removeAttribute('data-mt-popup-path'); popupPaths.delete(path); }
    }
    for (const path of nextPopupPaths) {
      if (!popupPaths.has(path)) { path.setAttribute('data-mt-popup-path', ''); popupPaths.add(path); }
    }
    const allowedBranches = new Set();
    for (const leaf of [node, ...supported]) {
      let branch = leaf;
      while (branch) { allowedBranches.add(branch); branch = branch.parentElement; }
    }
    const nextInert = new Set();
    for (const branch of allowedBranches) {
      if (branch === node || node.contains(branch) || supported.includes(branch)) continue;
      for (const child of branch.children) {
        if (!allowedBranches.has(child) && !['STYLE', 'SCRIPT', 'LINK'].includes(child.tagName)) nextInert.add(child);
      }
    }
    for (const node of inertNodes) {
      if (!nextInert.has(node)) { node.inert = false; node.removeAttribute('data-mt-inert'); inertNodes.delete(node); }
    }
    for (const node of nextInert) {
      if (!node.inert) { node.inert = true; node.setAttribute('data-mt-inert', ''); inertNodes.add(node); }
    }
  }

  function routeOf(raw) {
    try {
      const url = new URL(raw, location.href);
      if (url.protocol !== 'https:' || !['x.com', 'www.x.com', 'twitter.com', 'www.twitter.com'].includes(url.hostname)
          || url.username || url.password || (url.port && url.port !== '443')) return 'blocked';
      const path = url.pathname.replace(/\/$/, '') || '/';
      if (composerPaths.has(path)) return 'composer';
      // X's newer sign-in flow returns to a composer modal on the home route.
      // Recognize that modal in place instead of reloading the whole website.
      if (landingPaths.has(path) && composerPaths.has(url.searchParams.get('@modal'))) return 'composer';
      if (loginPaths.has(path)) return 'login';
      if (landingPaths.has(path)) return 'landing';
      return 'blocked';
    } catch { return 'blocked'; }
  }

  function findComposer() {
    if (surface?.isConnected && surface.querySelector(editorSelector) && surface.querySelector(postSelector)) return surface;
    const editor = document.querySelector(editorSelector);
    if (!editor) return null;
    const dialog = editor.closest('[role="dialog"]');
    if (dialog?.querySelector(postSelector)) return dialog;
    // X can use an inline composer at narrow window sizes. Select only its
    // smallest self-contained ancestor; never expose the primary column.
    let candidate = editor.parentElement;
    while (candidate && candidate !== document.body) {
      if (candidate.querySelector('[data-testid="tweet"], [data-testid="AppTabBar_Home_Link"], [data-testid="sidebarColumn"], [data-testid="cellInnerDiv"]')) return null;
      if (candidate.querySelector(postSelector)) return candidate;
      candidate = candidate.parentElement;
    }
    return null;
  }

  function profile() {
    // Read only the account label, never timeline content or login fields.
    const account = document.querySelector('[data-testid="SideNav_AccountSwitcher_Button"]');
    const avatar = findComposer()?.querySelector('[data-testid^="UserAvatar-Container-"]');
    const avatarHandle = avatar?.dataset.testid?.match(/^UserAvatar-Container-([A-Za-z0-9_]{1,15})$/)?.[1];
    const handle = account?.textContent?.match(/@[A-Za-z0-9_]{1,15}\b/)?.[0] || (avatarHandle ? '@' + avatarHandle : null);
    return handle ? { handle } : {};
  }

  function composerAvatar(root) {
    const original = root.querySelector('[data-testid^="UserAvatar-Container-"]:not([data-mt-fallback-avatar])')
      || root.querySelector('a:has(img)');
    const account = document.querySelector('[data-testid="SideNav_AccountSwitcher_Button"]');
    const handle = profile().handle?.slice(1);
    const matching = handle ? document.querySelector(`[data-testid="UserAvatar-Container-${handle}"] img`) : null;
    const image = original?.querySelector('img') || account?.querySelector('img') || matching;
    if (image?.src?.startsWith('https://')) avatarURL = image.src;
    if (original) {
      fallbackAvatars.get(root)?.remove();
      fallbackAvatars.delete(root);
      return original;
    }
    // At desktop breakpoints X places the avatar outside the smallest inline
    // composer. Render just its image here, without exposing that larger page.
    if (!avatarURL) return null;
    let avatar = fallbackAvatars.get(root);
    if (!avatar?.isConnected) {
      avatar = document.createElement('img');
      avatar.setAttribute('data-mt-fallback-avatar', '');
      avatar.alt = 'Your profile picture';
      fallbackAvatars.set(root, avatar);
      root.appendChild(avatar);
    }
    if (avatar.src !== avatarURL) avatar.src = avatarURL;
    return avatar;
  }

  function clearDesign(root) {
    root.querySelectorAll('[data-mt-layout], [data-mt-part]').forEach(node => {
      node.removeAttribute('data-mt-layout');
      node.removeAttribute('data-mt-part');
    });
    root.removeAttribute('data-mt-designed');
    identities.get(root)?.remove();
    identities.delete(root);
    fallbackAvatars.get(root)?.remove();
    fallbackAvatars.delete(root);
    layouts.delete(root);
  }

  function hasAuthoringMedia(root) {
    if (root.querySelector('[data-testid="attachments"], [data-testid="mediaPreview"], [data-testid="tweetPhoto"], video, canvas')) return true;
    const isAvatar = node => node.closest('[data-testid^="UserAvatar-Container-"], [data-mt-part="avatar"], [data-mt-fallback-avatar], a[aria-disabled="true"]');
    if ([...root.querySelectorAll('img[src]')].some(image => !isAvatar(image))) return true;
    return [...root.querySelectorAll('div')].some(node => !isAvatar(node) && getComputedStyle(node).backgroundImage.includes('url('));
  }

  function designComposer(root) {
    const editor = root.querySelector(editorSelector);
    const post = root.querySelector(postSelector);
    if (!editor || !post) return;
    // Keep X's expanded authoring layout for threads, polls, and other forms.
    // Compact styling must never hide a newly added editor or form input.
    if (hasAuthoringMedia(root) || root.querySelectorAll(editorSelector).length > 1
        || root.querySelector('input:not([type="file"]):not([type="hidden"]), textarea')) {
      clearDesign(root);
      return;
    }
    const writing = editor.closest('[data-testid$="RichTextInputContainer"]') || editor;
    const avatar = composerAvatar(root);
    const tools = root.querySelector('[data-testid="toolBar"]');
    const reply = [...root.querySelectorAll('button[aria-label]')].find(button =>
      !tools?.contains(button) && button !== post
      && /reply|antwort|responder|répond|返信/i.test(button.getAttribute('aria-label') || '')
      && !['app-bar-back', 'app-bar-close', 'unsentButton'].includes(button.dataset.testid));
    let identity = identities.get(root);
    if (!identity?.isConnected) {
      identity = document.createElement('div');
      identity.setAttribute('data-mt-part', 'identity');
      identity.setAttribute('role', 'button');
      identity.setAttribute('tabindex', '0');
      identity.setAttribute('title', 'Switch accounts');
      identities.set(root, identity);
      root.appendChild(identity);
    }
    const handle = profile().handle || 'Your account';
    if (identity.dataset.handle !== handle) {
      identity.replaceChildren(document.createTextNode(handle));
      const caption = document.createElement('small');
      caption.textContent = 'Posting on X';
      identity.appendChild(caption);
      identity.dataset.handle = handle;
    }
    const media = [...root.querySelectorAll('[data-testid="attachments"], [data-testid="mediaPreview"], [role="alert"]')];
    const parts = new Map([[identity, 'identity'], [writing, 'writing'], [post, 'post']]);
    if (avatar) parts.set(avatar, 'avatar');
    if (tools) parts.set(tools, 'tools');
    if (reply) parts.set(reply, 'reply');
    media.forEach(node => { if (!writing.contains(node)) parts.set(node, 'media'); });
    // Never omit an unfamiliar authoring control. X's poll/remove-media buttons
    // and newer preview wrappers are not guaranteed to use our known test IDs.
    const extraControls = [...root.querySelectorAll('button, [role="button"], [contenteditable="true"], input, textarea, select')]
      .filter(control => ![...parts.keys()].some(part => part === control || part.contains(control))
        && !control.closest('[data-mt-hidden]')
        && !control.matches('input[type="file"], input[type="hidden"], [data-testid="unsentButton"]'));
    if (extraControls.length) { clearDesign(root); return; }
    const previous = layouts.get(root);
    if (previous && previous.parts.size === parts.size
        && [...parts].every(([node, kind]) => previous.parts.get(node) === kind)
        && [...previous.bridges].every(([node, children]) => node.isConnected
          && children.length === node.children.length
          && children.every((child, index) => child === node.children[index]))) return;
    // Subgrid retains real wrapper geometry for X's press/anchor measurements.
    // display:contents makes those rectangles zero and can disable authoring
    // controls even when their buttons look correct. DOM parents stay intact.
    root.querySelectorAll('[data-mt-layout]').forEach(node => node.removeAttribute('data-mt-layout'));
    root.querySelectorAll('[data-mt-part]').forEach(node => {
      if (!parts.has(node)) node.removeAttribute('data-mt-part');
    });
    const bridges = new Set([root]);
    for (const [part, kind] of parts) {
      part.setAttribute('data-mt-part', kind);
      let ancestor = part.parentElement;
      while (ancestor && ancestor !== root) {
        if (!parts.has(ancestor)) bridges.add(ancestor);
        ancestor = ancestor.parentElement;
      }
    }
    for (const bridge of bridges) {
      if (bridge !== root) bridge.setAttribute('data-mt-layout', 'bridge');
      for (const child of bridge.children) {
        if (!parts.has(child) && !bridges.has(child) && !['STYLE', 'SCRIPT'].includes(child.tagName)) {
          child.setAttribute('data-mt-layout', 'omit');
        }
      }
    }
    root.setAttribute('data-mt-designed', '');
    layouts.set(root, { parts, bridges: new Map([...bridges].map(node => [node, [...node.children]])) });
  }

  function restrictSurface(root, mode) {
    root.querySelectorAll('a[href]').forEach(link => {
      const destination = routeOf(link.href);
      // Help links and profile links cannot open a browser from this app.
      if (destination === 'blocked' || destination === 'landing') {
        if (link.querySelector('img') || link.matches('[data-testid^="UserAvatar-Container-"]')
            || link.querySelector('[data-testid^="UserAvatar-Container-"]')) {
          // Keep the composer's avatar, but never make it a doorway to a profile.
          link.removeAttribute('data-mt-hidden');
          link.setAttribute('tabindex', '-1');
          link.setAttribute('aria-disabled', 'true');
        } else {
          link.setAttribute('data-mt-hidden', '');
        }
      }
    });
    if (mode === 'composer') {
      root.querySelectorAll('[data-testid="app-bar-close"], [data-testid="app-bar-back"], [data-testid="AppTabBar_Home_Link"]').forEach(node => node.setAttribute('data-mt-hidden', ''));
    } else if (mode === 'login') {
      root.querySelectorAll('iframe[src*="accounts.google.com"], iframe[src*="appleid.apple.com"]').forEach(frame => frame.setAttribute('data-mt-hidden', ''));
      root.querySelectorAll('button, [role="button"]').forEach(button => {
        if (/\b(Google|Apple)\b/i.test((button.textContent || '') + ' ' + (button.getAttribute('aria-label') || '')) || /apple|google/i.test(button.dataset.testid || '')) {
          button.setAttribute('data-mt-hidden', '');
        }
      });
    }
  }

  function scan() {
    scheduled = false;
    observer.disconnect();
    attachStyle();
    const route = routeOf(location.href);
    if (finished) {
      hideSurface();
    } else if (route === 'login') {
      const root = [...document.querySelectorAll('[role="dialog"]')].find(node => !node.querySelector('[data-testid="tweet"]'))
        || document.querySelector('form');
      if (root) {
        restrictSurface(root, 'login');
        showSurface(root, 'login');
        report('login');
      } else {
        hideSurface();
        report('loading');
      }
    } else if (route === 'composer') {
      const root = findComposer();
      if (root) {
        restrictSurface(root, 'composer');
        designComposer(root);
        showSurface(root, 'composer');
        updatePopovers(root);
        showSurface(root, 'composer');
        hadComposer = true;
        report('composer', profile());
        updateDraft();
      } else {
        hideSurface();
        report('loading');
      }
    } else {
      hideSurface();
      if (hadComposer && postRequested) {
        finished = true;
        pendingMedia = false;
        lastDraft = null;
        // Do not claim a successful post from a click or a disappearing dialog.
        // X owns submission; the native completion screen states this explicitly.
        report('finished');
      } else if (route === 'landing') {
        report('needsComposer');
      } else {
        report('blocked');
      }
    }
    observer.observe(document, { childList: true, subtree: true, attributes: true,
      attributeFilter: ['role', 'data-testid', 'contenteditable', 'href', 'src', 'aria-label', 'aria-hidden', 'disabled', 'style', 'class'], characterData: true });
  }

  function scheduleScan() {
    if (!scheduled) {
      scheduled = true;
      // Mutation observers and this microtask run before the next paint.
      queueMicrotask(scan);
    }
  }

  const observer = new MutationObserver(records => {
    if (records.some(record => {
      if (record.type === 'characterData') return surface?.contains(record.target);
      if (record.type === 'attributes' && ['style', 'class'].includes(record.attributeName)) {
        return !surface || surface.contains(record.target) || popupRequest || [...popovers].some(node => node.contains(record.target));
      }
      return true;
    })) scheduleScan();
  });
  attachStyle();
  observer.observe(document, { childList: true, subtree: true });

  // React navigation does not reach WKNavigationDelegate. Close the curtain
  // synchronously before every history change, then inspect the new surface.
  for (const method of ['pushState', 'replaceState']) {
    const original = history[method];
    history[method] = function (...args) {
      hideSurface();
      const result = original.apply(this, args);
      scheduleScan();
      return result;
    };
  }
  addEventListener('popstate', () => { hideSurface(); scheduleScan(); });
  addEventListener('hashchange', scheduleScan);

  document.addEventListener('click', event => {
    const target = event.target instanceof Element ? event.target : event.target?.parentElement;
    if (!target) return;
    if (window.__minTwitterDiagnose && surface?.querySelector(editorSelector)) {
      // Geometry and flags only: never include text, file names, values or URLs.
      const describe = node => {
        const bounds = node.getBoundingClientRect();
        const testID = node.getAttribute('data-testid');
        return { tag: node.tagName, role: node.getAttribute('role'),
          testID: ['fileInput', 'toolBar', 'tweetButton', 'tweetButtonInline'].includes(testID) ? testID : null,
          linkRoute: node.matches('a[href]') ? routeOf(node.href) : null,
          inert: !!node.closest('[inert]'), omitted: !!node.closest('[data-mt-layout="omit"]'),
          disabled: !!node.disabled, width: bounds.width, height: bounds.height };
      };
      window.webkit?.messageHandlers?.focus?.postMessage({ state: 'diagnostic', details: JSON.stringify({
        target: describe(target), ancestors: [target.parentElement, target.parentElement?.parentElement,
          target.parentElement?.parentElement?.parentElement].filter(Boolean).map(describe), inside: surface.contains(target),
        inputs: [...document.querySelectorAll('input[type="file"]')].map(input => ({ ...describe(input),
          parent: describe(input.parentElement), owner: input.closest('button') ? describe(input.closest('button')) : null }))
      }) });
      setTimeout(() => window.webkit?.messageHandlers?.focus?.postMessage({ state: 'diagnostic', details: JSON.stringify({
        popupCandidates: [...document.querySelectorAll(popoverSelector)].map(node => ({ ...describe(node), inside: !!surface?.contains(node),
          parents: [node.parentElement, node.parentElement?.parentElement, node.parentElement?.parentElement?.parentElement].filter(Boolean).map(parent => ({ ...describe(parent), tabIndex: parent.getAttribute('tabindex'), fields: parent.querySelectorAll('input:not([type="file"]),textarea').length })) })),
        dropdowns: document.querySelectorAll('[data-testid="Dropdown"]').length,
        activePopovers: popovers.size, focusedTag: document.activeElement?.tagName,
        editable: editable(document.activeElement)
      }) }), 200);
    }
    if (target instanceof HTMLInputElement && target.type === 'file') {
      if (surface?.querySelector(editorSelector) && (surface.contains(target)
          || (authoringClick && target.dataset.testid === 'fileInput'))) {
        authorizedUploads.add(target);
        return; // Preserve X's programmatic file-input activation.
      }
    }
    const link = target.closest('a[href]');
    if (link && !['composer', 'login'].includes(routeOf(link.href))) {
      event.preventDefault();
      event.stopImmediatePropagation();
      return;
    }
    const inPopover = [...popovers].some(node => node.contains(target));
    if (!surface?.contains(target) && !inPopover && !internalNavigation) {
      event.preventDefault();
      event.stopImmediatePropagation();
      return;
    }
    if (target.closest('[data-mt-part="identity"]')) {
      event.preventDefault();
      event.stopImmediatePropagation();
      window.webkit?.messageHandlers?.focus?.postMessage({ state: 'accounts' });
      return;
    }
    // Activate the original input directly when X mounts it beside its media
    // button. CSS layout flattening can disrupt X's pointer/press responder,
    // although the file input and its React change handler remain intact.
    const button = target.closest('button');
    const upload = button && !button.matches(postSelector) && button.closest('[data-testid="toolBar"]') && surface?.contains(button)
      ? [...document.querySelectorAll('input[type="file"][data-testid="fileInput"]')]
        .find(input => input.parentElement?.contains(button)
          && input.parentElement.querySelectorAll('button').length === 1) : null;
    if (upload && !upload.disabled && !button.disabled && button.getAttribute('aria-disabled') !== 'true') {
      authorizedUploads.add(upload);
      authoringClick = true;
      event.preventDefault();
      event.stopImmediatePropagation();
      upload.click();
      setTimeout(() => { authoringClick = false; }, 0);
      return;
    }
    const post = target.closest(postSelector);
    if (post && !post.disabled && post.getAttribute('aria-disabled') !== 'true') postRequested = true;
    else if (surface?.querySelector(editorSelector)) {
      const trigger = button || target.closest('[role="button"]');
      if (trigger && !trigger.matches(postSelector) && !trigger.disabled && trigger.getAttribute('aria-disabled') !== 'true') requestPopover(trigger);
      authoringClick = true;
      // For real user events, WebKit can run a microtask checkpoint between
      // our capture listener and React's bubble listener. Keep permission for
      // this event's whole task so React can activate its external file input.
      setTimeout(() => { authoringClick = false; }, 0);
    }
  }, true);

  // X may mount a popup in its pointer-up handler, before click is dispatched.
  // Record the existing dialogs before that press, with click as the keyboard
  // and programmatic activation fallback.
  document.addEventListener('pointerdown', event => {
    const button = event.target instanceof Element ? event.target.closest('button, [role="button"]') : null;
    if (event.button === 0 && button && surface?.contains(button) && surface.querySelector(editorSelector)
        && !button.disabled && button.getAttribute('aria-disabled') !== 'true'
        && !button.matches(postSelector + ', [data-mt-part="identity"]')) requestPopover(button, true);
  }, true);

  // The large blank writing region should act like an editor, even when X's
  // contenteditable element only occupies its first line. Don't intercept
  // selection, form fields, buttons, previews, or clicks inside authoring popups.
  document.addEventListener('mousedown', event => {
    const target = event.target instanceof Element ? event.target : null;
    if (event.button !== 0 || !target || !surface?.hasAttribute('data-mt-designed') || popovers.size
        || !surface.contains(target) || target.closest('button, a, input, textarea, select, [role="button"], [contenteditable="true"]')) return;
    if ((target === surface || target.closest('[data-mt-part="writing"]')) && focusEditor()) event.preventDefault();
  }, true);

  document.addEventListener('keydown', event => {
    if (event.target instanceof Element && event.target.closest('[data-mt-part="identity"]')
        && ['Enter', ' '].includes(event.key)) {
      event.preventDefault();
      event.stopImmediatePropagation();
      window.webkit?.messageHandlers?.focus?.postMessage({ state: 'accounts' });
      return;
    }
    const button = event.target instanceof Element ? event.target.closest('button, [role="button"]') : null;
    if (['Enter', ' '].includes(event.key) && !event.metaKey && !event.ctrlKey && !event.altKey
        && button && surface?.contains(button) && surface.querySelector(editorSelector)
        && !button.disabled && button.getAttribute('aria-disabled') !== 'true'
        && !button.matches(postSelector)) requestPopover(button, true);
    // Escape must not dismiss the main composer and expose the home page.
    if (event.key === 'Escape' && surface?.querySelector(editorSelector)
        && popovers.size === 0) {
      event.preventDefault();
      event.stopImmediatePropagation();
    }
    if ((event.metaKey || event.ctrlKey) && event.key === 'Enter' && surface?.contains(event.target)) {
      postRequested = true;
    }
  }, true);

  document.addEventListener('input', event => {
    if (!surface?.contains(event.target) || !surface.querySelector(editorSelector)) return;
    // DraftJS can commit its DOM after the input handler. Read after the event,
    // and let the mutation scan confirm the final rendered text as a backup.
    queueMicrotask(updateDraft);
  }, true);
  document.addEventListener('change', event => {
    if (event.target instanceof HTMLInputElement && event.target.type === 'file'
        && (surface?.contains(event.target) || authorizedUploads.has(event.target)) && event.target.files?.length) {
      pendingMedia = true;
      queueMicrotask(updateDraft);
    }
  }, true);

  function attachTransferredFiles(files) {
    if (!surface?.isConnected || routeOf(location.href) !== 'composer') return false;
    const supported = [...files].filter(file => /^(image|video)\//.test(file.type)
      || (!file.type && /\.(png|jpe?g|gif|webp|avif|heic|heif|mp4|mov|m4v)$/i.test(file.name)));
    if (!supported.length) return false;
    const input = surface.querySelector('input[type="file"]')
      || document.querySelector('input[type="file"][data-testid="fileInput"]');
    if (!input || input.disabled) return false;
    const transfer = new DataTransfer();
    supported.forEach(file => transfer.items.add(file));
    input.files = transfer.files;
    authorizedUploads.add(input);
    pendingMedia = true;
    // X's original change handler still owns limits, previews and uploading.
    input.dispatchEvent(new Event('change', { bubbles: true }));
    scheduleScan();
    return true;
  }

  document.addEventListener('paste', event => {
    if (!surface?.isConnected || !event.clipboardData) return;
    if (!surface.contains(event.target) && ![document, document.body, document.documentElement].includes(event.target)) return;
    const files = event.clipboardData.files.length ? event.clipboardData.files
      : [...event.clipboardData.items].map(item => item.getAsFile()).filter(Boolean);
    if (attachTransferredFiles(files)) {
      event.preventDefault();
      event.stopImmediatePropagation();
    }
  }, true);
  document.addEventListener('dragover', event => {
    if (surface?.contains(event.target) && event.dataTransfer?.types.includes('Files')) {
      event.preventDefault();
      event.dataTransfer.dropEffect = 'copy';
    }
  }, true);
  document.addEventListener('drop', event => {
    if (!surface?.contains(event.target) || !event.dataTransfer?.files.length) return;
    if (attachTransferredFiles(event.dataTransfer.files)) {
      event.preventDefault();
      event.stopImmediatePropagation();
    }
  }, true);

  // Invoked only by the native New Post action. Use X's existing router and
  // loaded assets; never open a feed or submit a post from this helper.
  window.__minTwitterOpenComposer = () => {
    const existing = findComposer();
    finished = false;
    postRequested = false;
    lastDraft = null;
    lastState = '';
    if (existing && routeOf(location.href) === 'composer') { scan(); return true; }
    const button = document.querySelector('[data-testid="SideNav_NewTweet_Button"]')
      || document.querySelector('a[href="/compose/post"], a[href="/compose/tweet"]');
    if (!button) return false;
    internalNavigation = true;
    try { button.click(); } finally { internalNavigation = false; }
    scheduleScan();
    return true;
  };

  document.addEventListener('DOMContentLoaded', scheduleScan);
  scheduleScan();
})();
