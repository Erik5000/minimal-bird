# Release review — 0.6.0, 2026-10-07

Publication update (0.6.1): the first public source snapshot uses GPL-3.0-only, includes Search/Office Commun inspiration credits, and bundles its license and notices in the app. The About dialog exposes the license. The experimental app ZIP is distributed alongside its exact corresponding source and checksums; it remains ad-hoc signed and not notarized.

Reviewed all application source, account storage and navigation policy, WebKit filtering, window and draft lifecycle, icon generation, tests, CI, and build/install/release scripts. This is a source and integration review of Min Twitter, not a security audit of X's website.

## Findings addressed

- **P2 — Typing loses focus after native menus.** Dismissing the account menu left the account header focused, so subsequent letters did not reach the editor. Native menu, sheet, window, and account transitions now restore WebKit and editor focus. The DOM helper preserves the caret and leaves an active poll field or authoring popup alone. Clicking blank writing space focuses the editor. Live X testing reproduced the original bug and confirmed that typing resumes at the saved insertion point.
- **P2 — Authoring popups were hidden or partly inaccessible.** X mounts reply settings and emoji controls outside the composer, including focusable groups around listboxes. Newly opened authoring popups now receive visible, interactive paths. Their search fields and close controls are retained; feed-containing and unsolicited dialogs remain covered. Popup bounds stay within the app, and focus is retried after removing `inert` from their ancestor path. X continues to own choices and submission.
- **P2 — Compact wrappers had zero-sized measurement rectangles.** Subgrid keeps the original DOM hierarchy and measurable wrapper bounds while retaining the compact layout. Polls, threads, and attachments still fall back to X's original layout.
- **P2 — Updating a bundle could retain removed resources.** Builds and installations now stage a complete verified bundle before replacement. Installation refuses running instances, symbolic-link targets, unrelated apps, and invalid source signatures, and restores the previous app if replacement fails.
- **P3 — WebKit retained its owning controller through the script handler.** A weak forwarding handler breaks that ownership cycle.
- **P3 — Image assertions raced decoding.** The upload fixture now waits for the image's load event as well as file reading. It continues to check actual decoded dimensions and visible removal controls.

The release also adds the standard Redo shortcut and an original bird silhouette icon, rendered from vector source at every macOS icon size.

## Existing fixes retained

The avatar remains visible when X moves it outside the inline composer at desktop widths. Added accounts use distinct persistent WebKit stores while the original account keeps its original store. Open controllers retain drafts across account switches. Quitting checks each opened account, and reload/sign-out warn before discarding a detected draft.

The media button uses X's original file input and change handler. Paste and drop forward supported files to that same handler. Previews, background-image attachments, poll fields, and removal controls remain visible and participate in draft detection. No private X API is called by the app.

## Verification and limits

The WebKit suite contains 79 checks and uses synthetic pages, a nonpersistent store, and two disposable persistent stores. It covers focus and caret restoration, popup isolation and dismissal, avatar resizing, native file selection, image decoding, paste/drop, media and poll removal, drafts, navigation, completion, and warm reopening. Five unit tests cover allowed/blocked destinations, account migration, selection, persistence, and damaged metadata recovery.

Live 0.6.0 checks confirmed account-menu focus and caret restoration, reply settings visibility and Escape dismissal, and emoji search, insertion, and Escape dismissal. These checks use temporary text and the original app icon, with all test content removed and no post published. The previous release verified the real native image chooser and image paste from Preview; live poll removal was also verified. Finder-to-X drag/drop remains covered by fixtures rather than a manual drag. A real second account's authentication and publication require testing by its owner.

X can change its DOM, login rules, available features, and embedded-browser behavior. The filter deliberately covers unknown layouts. Hiding the UI does not prevent X from fetching its usual website data. Drafts are not backed up across quitting or crashes.

## Distribution

Disposable installer checks passed for complete replacement, rollback after a simulated move failure, and rejection of an invalid source signature without altering the installed bundle.

The local package is a universal arm64/x86_64 app with a macOS 14 minimum target, hardened runtime, stripped debug symbols, and an ad-hoc signature. Source packages contain committed files only. Checksums accompany both ZIPs.

The notarized release path supports Developer ID signing, notarization, stapling, and Gatekeeper assessment. It publishes packages into the release directory only after these checks succeed. This path requires the distributor's own certificate and stored notarytool credentials; it has not been exercised with real notarization credentials in this environment. Local ad-hoc packages must not be presented as notarized downloads.
