// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Minimal Bird contributors

(() => {
  'use strict';
  if (window.__minimalBirdInstalled) return;
  window.__minimalBirdInstalled = true;

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
  let restoring = false;
  const inertNodes = new Set();
  let authoringClick = false;
  const authorizedUploads = new WeakSet();
  const popoverSelector = '[role="dialog"], [role="menu"], [role="listbox"], [role="group"][tabindex="0"]';
  const forbiddenSurface = '[data-testid="tweet"], [data-testid="cellInnerDiv"], [data-testid="sidebarColumn"], header[role="banner"]';
  const popovers = new Set();
  const popupPaths = new Set();
  let popupRequest = null;
  let lastEditor = null;
  let lastSelection = null;

  function post(message) {
    window.webkit?.messageHandlers?.focus?.postMessage(message);
  }

  function editable(node) {
    return node instanceof Element && (node.isContentEditable
      || node.matches('textarea, input:not([type="file"]):not([type="hidden"]):not([type="button"]):not([type="submit"]):not([type="radio"]):not([type="checkbox"])'));
  }

  /// Top-level post editors in document order. A thread has one per post.
  function editorsIn(root) {
    const all = [...root.querySelectorAll(editorSelector)];
    return all.filter(node => !all.some(other => other !== node && other.contains(node)));
  }

  /// Restores keyboard focus to the editor after native menus, sheets, and
  /// popups. It never takes focus from a control the person is using inside
  /// the composer, such as a newly added thread post, a poll choice or a button.
  function focusEditor(force = false, preferred = null) {
    if (!surface?.isConnected || popovers.size) return false;
    const editors = editorsIn(surface);
    if (!editors.length) return false;
    const active = document.activeElement;
    if (surface.contains(active) && active !== surface) {
      if (editable(active)) return true;
      if (!force) return false;
    }
    const editor = preferred && editors.includes(preferred) ? preferred
      : lastEditor?.isConnected && editors.includes(lastEditor) ? lastEditor : editors[0];
    if (editor.closest('[inert]')) return false;
    editor.focus({ preventScroll: true });
    if (editor === lastEditor && lastSelection && editor.contains(lastSelection.commonAncestorContainer)) {
      const selection = getSelection();
      selection.removeAllRanges(); selection.addRange(lastSelection);
    }
    return document.activeElement === editor;
  }
  window.__minimalBirdFocusEditor = () => focusEditor();

  document.addEventListener('focusin', event => {
    if (!surface?.contains(event.target) || !editable(event.target)) return;
    if (lastEditor !== event.target) lastSelection = null;
    lastEditor = event.target;
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
        node.removeAttribute('data-mb-popover'); popovers.delete(node);
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
            child.removeAttribute('data-mb-popover'); popovers.delete(child);
          }
        }
        popovers.add(node);
        node.setAttribute('data-mb-popover', '');
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
    if (hadPopover && !popovers.size && document.hasFocus()) queueMicrotask(() => focusEditor());
  }

  function report(state, extra = {}) {
    const message = { state, ...extra };
    const key = JSON.stringify(message);
    if (key === lastState) return;
    lastState = key;
    post(message);
  }

  function postText(editor) {
    return (editor.innerText || '').replace(/ /g, ' ').replace(/^\n+|\s+$/g, '');
  }

  /// Sends the composer's text to the native app, which keeps it as a local
  /// draft. `extras` marks content a text draft cannot keep (media, polls).
  function updateDraft(force = false) {
    if (restoring || !surface?.isConnected) return;
    const editors = editorsIn(surface);
    if (!editors.length) return;
    const posts = editors.map(postText);
    const attachments = hasAuthoringMedia(surface);
    const fileInputs = new Set([...surface.querySelectorAll('input[type="file"]'),
      ...[...document.querySelectorAll('input[type="file"][data-testid="fileInput"]')].filter(input => authorizedUploads.has(input))]);
    const selectedFiles = [...fileInputs].some(input => input.files?.length);
    if (attachments) pendingMedia = false;
    const extras = pendingMedia || attachments || selectedFiles
      || [...surface.querySelectorAll('input:not([type="file"]):not([type="hidden"]), textarea')].some(input => input.value.trim().length > 0)
      || [...surface.querySelectorAll('[contenteditable="true"]')].some(field => !editors.some(editor => editor === field
        || editor.contains(field) || field.contains(editor)) && field.textContent.trim().length > 0);
    const dirty = extras || posts.some(text => text.trim().length > 0);
    const key = JSON.stringify([dirty, extras, posts]);
    if (!force && key === lastDraft) return;
    lastDraft = key;
    post({ state: 'draft', dirty, extras, posts });
  }

  const style = document.createElement('style');
  style.id = 'minimal-bird-curtain';
  style.textContent = `
    :root {
      --mb-paper: #faf9f6; --mb-ink: #2b3230; --mb-muted: #80847c; --mb-faint: #a9aaa1;
      --mb-line: #e6e4dc; --mb-accent: #b8492e; --mb-accent-hover: #a33f27;
      --mb-tint: rgba(184, 73, 46, 0.09); --mb-accent-line: rgba(184, 73, 46, 0.38);
      --mb-font: -apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", sans-serif;
    }
    html { visibility: hidden !important; background: var(--mb-paper) !important; }
    body * { visibility: hidden !important; pointer-events: none !important; }
    [data-mb-surface], [data-mb-surface] *, [data-mb-popover], [data-mb-popover] * {
      visibility: visible !important; pointer-events: auto !important;
    }
    [data-mb-surface] button *, [data-mb-popover] button * { pointer-events: none !important; }
    [data-mb-popup-path] {
      transform: none !important; filter: none !important; backdrop-filter: none !important;
      -webkit-backdrop-filter: none !important; perspective: none !important;
      contain: none !important; will-change: auto !important; opacity: 1 !important;
      overflow: visible !important; clip: auto !important; clip-path: none !important;
    }
    [data-mb-popover] {
      position: fixed !important; inset: auto !important; left: 50% !important;
      bottom: 64px !important; transform: translateX(-50%) !important;
      width: 360px !important; min-width: 0 !important;
      max-width: calc(100vw - 40px) !important; box-sizing: border-box !important;
      max-height: calc(100vh - 96px) !important; overflow: auto !important;
      z-index: 100 !important; background: var(--mb-paper) !important;
      border: 1px solid var(--mb-line) !important; border-radius: 14px !important;
      box-shadow: 0 1px 2px #2b32300f, 0 12px 36px #2b323024 !important;
    }
    [data-mb-hidden], [data-mb-hidden] *,
    [data-testid="sidebarColumn"], [data-testid="sidebarColumn"] *,
    header[role="banner"], header[role="banner"] *,
    [data-testid="tweet"], [data-testid="tweet"] *,
    [aria-label="Timeline: Your Home Timeline"],
    [aria-label="Timeline: Your Home Timeline"] * {
      visibility: hidden !important; pointer-events: none !important;
    }
    [data-mb-hidden] { display: none !important; }
    /* Close/back keep their slot so X's header keeps Post where X put it. */
    [data-mb-concealed], [data-mb-concealed] * { visibility: hidden !important; pointer-events: none !important; }
    html, body { background: var(--mb-paper) !important; }
    html:has([data-mb-surface="composer"]),
    body:has([data-mb-surface="composer"]) { overflow: hidden !important; }
    [data-mb-surface="composer"] {
      position: fixed !important; top: 0 !important; left: 0 !important;
      right: 0 !important; bottom: 0 !important;
      width: 100% !important; max-width: none !important;
      min-width: 0 !important; min-height: 0 !important;
      height: 100% !important; max-height: none !important;
      margin: 0 !important; border: none !important;
      border-radius: 0 !important; overflow-y: auto !important;
      background: var(--mb-paper) !important; padding: 4px 16px 16px !important;
      box-sizing: border-box !important; box-shadow: none !important;
    }

    /* One calm skin over whatever layout X renders: a single composer, a
       thread, polls, link cards or media. Tones are measured from X's own
       computed colors (see applyTones), so no layout or class name is assumed. */
    [data-mb-surface="composer"], [data-mb-surface="composer"] *,
    [data-mb-popover], [data-mb-popover] * {
      font-family: var(--mb-font) !important;
      -webkit-font-smoothing: antialiased;
    }
    [data-mb-surface="composer"] * { box-shadow: none !important; }
    [data-mb-surface="composer"] ::selection { background: rgba(184, 73, 46, 0.16); }
    [data-mb-surface] [data-mb-fg="ink"], [data-mb-popover] [data-mb-fg="ink"] { color: var(--mb-ink) !important; }
    [data-mb-surface] [data-mb-fg="muted"], [data-mb-popover] [data-mb-fg="muted"] { color: var(--mb-muted) !important; }
    [data-mb-surface] [data-mb-fg="accent"], [data-mb-popover] [data-mb-fg="accent"] { color: var(--mb-accent) !important; }
    [data-mb-surface] [data-mb-bg="paper"], [data-mb-popover] [data-mb-bg="paper"] { background-color: var(--mb-paper) !important; }
    [data-mb-surface] [data-mb-bg="line"], [data-mb-popover] [data-mb-bg="line"] { background-color: var(--mb-line) !important; }
    [data-mb-surface] [data-mb-bg="accent"], [data-mb-popover] [data-mb-bg="accent"] { background-color: var(--mb-accent) !important; }
    [data-mb-surface] [data-mb-bg="tint"], [data-mb-popover] [data-mb-bg="tint"] { background-color: var(--mb-tint) !important; }
    [data-mb-surface] [data-mb-bd="line"], [data-mb-popover] [data-mb-bd="line"] { border-color: var(--mb-line) !important; }
    [data-mb-surface] [data-mb-bd="accent"], [data-mb-popover] [data-mb-bd="accent"] { border-color: var(--mb-accent-line) !important; }
    [data-mb-surface] [data-mb-stroke="accent"], [data-mb-popover] [data-mb-stroke="accent"] { stroke: var(--mb-accent) !important; }
    [data-mb-surface] [data-mb-stroke="line"], [data-mb-popover] [data-mb-stroke="line"] { stroke: var(--mb-line) !important; }
    [data-mb-surface] [data-mb-fill="accent"], [data-mb-popover] [data-mb-fill="accent"] { fill: var(--mb-accent) !important; }

    /* Toolbar icons stay quiet; the accent is kept for Post, links and progress. */
    [data-mb-surface="composer"] [data-testid="toolBar"] [data-mb-fg="accent"] { color: var(--mb-muted) !important; }
    [data-mb-surface="composer"] [data-testid="toolBar"] [data-mb-fill="accent"] { fill: var(--mb-muted) !important; }
    [data-mb-surface="composer"] [data-testid="toolBar"] [data-mb-bg="tint"] { background-color: rgba(43, 50, 48, 0.07) !important; }

    [data-mb-surface="composer"] [data-testid^="tweetTextarea_"],
    [data-mb-surface="composer"] .public-DraftEditorPlaceholder-root,
    [data-mb-surface="composer"] .public-DraftEditorPlaceholder-inner {
      font-size: 18px !important; line-height: 1.5 !important; letter-spacing: -0.01em !important;
    }
    [data-mb-surface="composer"] .public-DraftEditorPlaceholder-root,
    [data-mb-surface="composer"] .public-DraftEditorPlaceholder-inner { color: var(--mb-faint) !important; }
    [data-mb-surface="composer"] [contenteditable="true"] { caret-color: var(--mb-accent); }
    [data-mb-surface="composer"] [data-testid="tweetButton"],
    [data-mb-surface="composer"] [data-testid="tweetButtonInline"] {
      border-radius: 999px !important; border-color: transparent !important;
      transition: background-color 120ms ease, opacity 120ms ease;
    }
    [data-mb-surface="composer"] [data-testid="tweetButton"]:is([disabled], [aria-disabled="true"]),
    [data-mb-surface="composer"] [data-testid="tweetButtonInline"]:is([disabled], [aria-disabled="true"]) {
      opacity: 1 !important; background-color: #d9d4c9 !important;
    }
    [data-mb-surface="composer"] [data-testid="tweetButton"] *,
    [data-mb-surface="composer"] [data-testid="tweetButtonInline"] * {
      font-weight: 600 !important; letter-spacing: 0 !important;
    }
    [data-mb-surface="composer"] [data-testid="unsentButton"],
    [data-mb-surface="composer"] [data-testid="gifSearchButton"],
    [data-mb-surface="composer"] [data-testid="geoButton"],
    [data-mb-surface="composer"] [data-testid="scheduleOption"],
    [data-mb-surface="composer"] [data-testid="contentDisclosureButton"] { display: none !important; }
  `;

  function attachStyle() {
    if (document.documentElement && !style.isConnected) document.documentElement.appendChild(style);
  }

  // ---- Tones: map X's palette onto the app's palette by measured color. ----

  const tones = new WeakMap();
  const toneAttributes = ['data-mb-fg', 'data-mb-bg', 'data-mb-bd', 'data-mb-stroke', 'data-mb-fill'];
  const skipTone = new Set(['IMG', 'VIDEO', 'CANVAS', 'SOURCE', 'PICTURE', 'STYLE', 'SCRIPT', 'IFRAME', 'BR']);

  function parseColor(value) {
    const match = /^rgba?\(([^)]+)\)$/.exec(value || '');
    if (!match) return null;
    const parts = match[1].split(/[\s,/]+/).filter(Boolean).map(part =>
      part.endsWith('%') ? parseFloat(part) / 100 : Number(part));
    if (parts.length < 3 || parts.some(Number.isNaN)) return null;
    return { r: parts[0] / 255, g: parts[1] / 255, b: parts[2] / 255, a: parts.length > 3 ? parts[3] : 1 };
  }

  /// 'blue' is X's accent family; neutrals are split by lightness.
  function colorKind(color) {
    if (!color || color.a < 0.04) return null;
    const max = Math.max(color.r, color.g, color.b), min = Math.min(color.r, color.g, color.b);
    const delta = max - min, lightness = (max + min) / 2;
    const saturation = delta === 0 ? 0 : delta / (1 - Math.abs(2 * lightness - 1));
    if (saturation < 0.25 || delta < 0.08) return lightness < 0.3 ? 'dark' : lightness > 0.86 ? 'light' : 'grey';
    let hue = max === color.r ? ((color.g - color.b) / delta) % 6
      : max === color.g ? (color.b - color.r) / delta + 2 : (color.r - color.g) / delta + 4;
    hue = (hue * 60 + 360) % 360;
    return hue >= 188 && hue <= 218 && saturation > 0.45 ? 'blue' : 'other';
  }

  function measureTone(node, computed) {
    const marks = [];
    const fg = colorKind(parseColor(computed.color));
    if (fg === 'dark') marks.push(['data-mb-fg', 'ink']);
    else if (fg === 'grey') marks.push(['data-mb-fg', 'muted']);
    else if (fg === 'blue') marks.push(['data-mb-fg', 'accent']);
    const background = parseColor(computed.backgroundColor);
    const bg = colorKind(background);
    if (bg === 'blue') marks.push(['data-mb-bg', background.a > 0.85 ? 'accent' : 'tint']);
    else if ((bg === 'light' || bg === 'grey') && background.a > 0.5) {
      // Thin opaque rules (thread connectors, dividers) become hairlines;
      // white panels and translucent headers become the warm page color.
      const thin = node.offsetWidth > 0 && node.offsetHeight > 0 && (node.offsetWidth <= 4 || node.offsetHeight <= 2);
      if (thin) marks.push(['data-mb-bg', 'line']);
      else if (bg === 'light') marks.push(['data-mb-bg', 'paper']);
    }
    const bordered = ['Top', 'Right', 'Bottom', 'Left'].some(side =>
      parseFloat(computed[`border${side}Width`]) > 0 && computed[`border${side}Style`] !== 'none');
    if (bordered) {
      const border = colorKind(parseColor(computed.borderTopColor) || parseColor(computed.borderBottomColor));
      if (border === 'blue') marks.push(['data-mb-bd', 'accent']);
      else if (border && border !== 'other') marks.push(['data-mb-bd', 'line']);
    }
    if (node instanceof SVGElement) {
      const stroke = colorKind(parseColor(computed.stroke));
      if (stroke === 'blue') marks.push(['data-mb-stroke', 'accent']);
      else if (stroke === 'light' || stroke === 'grey') marks.push(['data-mb-stroke', 'line']);
      if (colorKind(parseColor(computed.fill)) === 'blue') marks.push(['data-mb-fill', 'accent']);
    }
    return marks;
  }

  function applyTones(roots) {
    const changed = [];
    for (const root of roots) {
      if (!root?.isConnected) continue;
      for (const node of [root, ...root.querySelectorAll('*')]) {
        if (skipTone.has(node.tagName)) continue;
        const signature = (node.getAttribute('class') || '') + '\n' + (node.getAttribute('style') || '');
        if (tones.get(node) === signature) continue;
        tones.set(node, signature);
        changed.push(node);
      }
    }
    if (!changed.length) return;
    // Clear, then read every style, then write: one style recalculation per scan.
    for (const node of changed) for (const name of toneAttributes) node.removeAttribute(name);
    const measured = changed.map(node => [node, measureTone(node, getComputedStyle(node))]);
    for (const [node, marks] of measured) for (const [name, value] of marks) node.setAttribute(name, value);
  }

  function hideSurface() {
    document.querySelectorAll('[data-mb-surface]').forEach(node => node.removeAttribute('data-mb-surface'));
    surface = null;
    popovers.forEach(node => node.removeAttribute('data-mb-popover'));
    popovers.clear();
    popupPaths.forEach(node => node.removeAttribute('data-mb-popup-path'));
    popupPaths.clear();
    popupRequest = null;
  }

  function showSurface(node, mode) {
    if (surface !== node) {
      hideSurface();
      node.setAttribute('data-mb-surface', mode);
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
      if (!nextPopupPaths.has(path)) { path.removeAttribute('data-mb-popup-path'); popupPaths.delete(path); }
    }
    for (const path of nextPopupPaths) {
      if (!popupPaths.has(path)) { path.setAttribute('data-mb-popup-path', ''); popupPaths.add(path); }
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
      if (!nextInert.has(node)) { node.inert = false; node.removeAttribute('data-mb-inert'); inertNodes.delete(node); }
    }
    for (const node of nextInert) {
      if (!node.inert) { node.inert = true; node.setAttribute('data-mb-inert', ''); inertNodes.add(node); }
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

  function hasAuthoringMedia(root) {
    if (root.querySelector('[data-testid="attachments"], [data-testid="mediaPreview"], [data-testid="tweetPhoto"], video, canvas')) return true;
    // Avatars and link-card previews come back from the text; they are not attachments.
    const ignored = node => node.closest('[data-testid^="UserAvatar-Container-"], [data-testid^="card."], a[aria-disabled="true"]');
    if ([...root.querySelectorAll('img[src]')].some(image => !ignored(image))) return true;
    return [...root.querySelectorAll('div')].some(node => !ignored(node) && getComputedStyle(node).backgroundImage.includes('url('));
  }

  function restrictSurface(root, mode) {
    root.querySelectorAll('a[href]').forEach(link => {
      const destination = routeOf(link.href);
      // Help links and profile links cannot open a browser from this app.
      if (destination === 'blocked' || destination === 'landing') {
        if (link.querySelector('img') || link.matches('[data-testid^="UserAvatar-Container-"]')
            || link.querySelector('[data-testid^="UserAvatar-Container-"]')) {
          // Keep the composer's avatar, but never make it a doorway to a profile.
          link.removeAttribute('data-mb-hidden');
          link.setAttribute('tabindex', '-1');
          link.setAttribute('aria-disabled', 'true');
        } else {
          link.setAttribute('data-mb-hidden', '');
        }
      }
    });
    if (mode === 'composer') {
      root.querySelectorAll('[data-testid="app-bar-close"], [data-testid="app-bar-back"]').forEach(node => {
        node.setAttribute('data-mb-concealed', '');
        node.setAttribute('tabindex', '-1');
        node.setAttribute('aria-hidden', 'true');
      });
      root.querySelectorAll('[data-testid="AppTabBar_Home_Link"]').forEach(node => node.setAttribute('data-mb-hidden', ''));
    } else if (mode === 'login') {
      root.querySelectorAll('iframe[src*="accounts.google.com"], iframe[src*="appleid.apple.com"]').forEach(frame => frame.setAttribute('data-mb-hidden', ''));
      root.querySelectorAll('button, [role="button"]').forEach(button => {
        if (/\b(Google|Apple)\b/i.test((button.textContent || '') + ' ' + (button.getAttribute('aria-label') || '')) || /apple|google/i.test(button.dataset.testid || '')) {
          button.setAttribute('data-mb-hidden', '');
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
        showSurface(root, 'composer');
        updatePopovers(root);
        showSurface(root, 'composer');
        applyTones([root, ...popovers]);
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
    if (window.__minimalBirdDiagnose && surface?.querySelector(editorSelector)) {
      // Geometry and flags only: never include text, file names, values or URLs.
      const describe = node => {
        const bounds = node.getBoundingClientRect();
        const testID = node.getAttribute('data-testid');
        return { tag: node.tagName, role: node.getAttribute('role'),
          testID: ['fileInput', 'toolBar', 'tweetButton', 'tweetButtonInline', 'addButton'].includes(testID) ? testID : null,
          linkRoute: node.matches('a[href]') ? routeOf(node.href) : null,
          inert: !!node.closest('[inert]'), disabled: !!node.disabled, width: bounds.width, height: bounds.height };
      };
      post({ state: 'diagnostic', details: JSON.stringify({
        target: describe(target), ancestors: [target.parentElement, target.parentElement?.parentElement,
          target.parentElement?.parentElement?.parentElement].filter(Boolean).map(describe), inside: surface.contains(target),
        editors: editorsIn(surface).length,
        inputs: [...document.querySelectorAll('input[type="file"]')].map(input => ({ ...describe(input),
          parent: describe(input.parentElement), owner: input.closest('button') ? describe(input.closest('button')) : null }))
      }) });
      setTimeout(() => post({ state: 'diagnostic', details: JSON.stringify({
        popupCandidates: [...document.querySelectorAll(popoverSelector)].map(node => ({ ...describe(node), inside: !!surface?.contains(node),
          parents: [node.parentElement, node.parentElement?.parentElement, node.parentElement?.parentElement?.parentElement].filter(Boolean).map(parent => ({ ...describe(parent), tabIndex: parent.getAttribute('tabindex'), fields: parent.querySelectorAll('input:not([type="file"]),textarea').length })) })),
        dropdowns: document.querySelectorAll('[data-testid="Dropdown"]').length,
        activePopovers: popovers.size, focusedTag: document.activeElement?.tagName,
        editable: editable(document.activeElement), editors: surface ? editorsIn(surface).length : 0
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
    if (target.closest('[data-mb-concealed]') || (link && !['composer', 'login'].includes(routeOf(link.href)))) {
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
    // Activate the original input directly when X mounts it beside its media
    // button. X's press responder can miss clicks on a resized toolbar,
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
    const postButton = target.closest(postSelector);
    if (postButton && !postButton.disabled && postButton.getAttribute('aria-disabled') !== 'true') postRequested = true;
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
        && !button.matches(postSelector)) requestPopover(button, true);
  }, true);

  // Blank space around the writing area should act like the editor, even when
  // X's contenteditable only occupies its first line. Wrappers around several
  // posts are left to X, which activates the thread post that was clicked.
  document.addEventListener('mousedown', event => {
    const target = event.target instanceof Element ? event.target : null;
    if (event.button !== 0 || !target || !surface?.contains(target) || popovers.size
        || target.closest('button, a, input, textarea, select, label, [role="button"], [contenteditable="true"]')) return;
    const inside = editorsIn(surface).filter(editor => target.contains(editor));
    if (target !== surface && inside.length !== 1) return;
    if (focusEditor(true, inside[0])) event.preventDefault();
  }, true);

  document.addEventListener('keydown', event => {
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
    queueMicrotask(() => updateDraft());
  }, true);
  document.addEventListener('change', event => {
    if (event.target instanceof HTMLInputElement && event.target.type === 'file'
        && (surface?.contains(event.target) || authorizedUploads.has(event.target)) && event.target.files?.length) {
      pendingMedia = true;
      queueMicrotask(() => updateDraft());
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
  window.__minimalBirdOpenComposer = () => {
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

  // ---- Drafts: put saved text back into X's own editor. ----

  const pause = ms => new Promise(resolve => setTimeout(resolve, ms));
  async function waitFor(probe, timeout) {
    const end = performance.now() + timeout;
    for (;;) {
      const value = probe();
      if (value || performance.now() > end) return value;
      await pause(40);
    }
  }
  const comparable = text => text.replace(/\s+/g, ' ').trim();

  function selectContents(editor) {
    const range = document.createRange();
    range.selectNodeContents(editor);
    const selection = getSelection();
    selection.removeAllRanges(); selection.addRange(range);
  }

  /// Replaces one editor's text the way a person would: select everything and
  /// paste. X's editor keeps its own model, line breaks and character count.
  async function insertInto(editor, text) {
    if (comparable(postText(editor)) === comparable(text)) return true;
    editor.focus({ preventScroll: true });
    selectContents(editor);
    await pause(50); // Let the editor observe the new selection first.
    const before = postText(editor);
    const transfer = new DataTransfer();
    transfer.setData('text/plain', text);
    editor.dispatchEvent(new ClipboardEvent('paste', { bubbles: true, cancelable: true, clipboardData: transfer }));
    await pause(50);
    if (postText(editor) === before) {
      // No paste handler took it; fall back to native editing.
      selectContents(editor);
      document.execCommand('insertText', false, text);
      await pause(20);
    }
    return comparable(postText(editor)) === comparable(text);
  }

  /// Native drafts call this with a list of posts. Returns 'ok', 'partial',
  /// 'failed', 'reload' (the composer already holds a thread) or 'unavailable'.
  window.__minimalBirdInsertPosts = async posts => {
    if (!Array.isArray(posts) || !posts.length || posts.some(text => typeof text !== 'string')) return 'failed';
    const ready = await waitFor(() => routeOf(location.href) === 'composer' && surface?.isConnected
      && editorsIn(surface).length > 0, 4000);
    if (!ready || restoring) return 'unavailable';
    if (editorsIn(surface).length > 1) return 'reload';
    restoring = true;
    let inserted = 0;
    try {
      for (const [index, text] of posts.entries()) {
        let editor = editorsIn(surface)[index];
        if (!editor) {
          const add = surface.querySelector('[data-testid="addButton"]');
          if (!add || add.disabled || add.getAttribute('aria-disabled') === 'true') break;
          add.click();
          editor = await waitFor(() => surface?.isConnected && editorsIn(surface)[index], 2500);
          if (!editor) break;
        }
        if (!(await insertInto(editor, text))) break;
        inserted += 1;
      }
    } finally {
      restoring = false;
      updateDraft(true);
    }
    return inserted === posts.length ? 'ok' : inserted ? 'partial' : 'failed';
  };

  document.addEventListener('DOMContentLoaded', scheduleScan);
  scheduleScan();
})();
