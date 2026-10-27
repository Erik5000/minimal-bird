# Launch check — 0.8.0 build 21, 2026-10-27

Fixed a reproduced loss of the last typed characters when quitting. Quit now
waits for the current WebKit editor text and a successful disk write for every
opened account. It checks the active account first. A read error, timeout, disk
error, or unfinished restoration cancels quitting. Sign-out uses the same
editor capture before clearing the session.

Validation: 14 unit tests and all 148 WebKit/native UI checks passed, including
the rendered-window checks. The suite covers native input immediately followed
by quit, concurrent leave requests, failed reads and writes, timeout, retry,
and sign-out capture failure. A separate disposable app test exercised the
actual macOS termination loop and verified the last input on disk after exit.
The universal app build, code signature, JavaScript and shell syntax, and Git
whitespace checks passed. Both architectures target macOS 14.

Launch preview files remain local and are ignored by Git. The build remains
ad-hoc signed and is not notarized. This check used synthetic pages and did not
test live publication to X.

---

# Draft library update — 0.8.0 build 20, 2026-10-27

The composer now has visible **Save draft**, **New draft**, and **Draft library**
buttons. Save draft writes the current thread and returns to a full-window
library. The library provides search, previews, save times, and visible Edit
and Delete buttons. Edit reopens a saved thread; saving updates the same entry.
Delete requires confirmation. Clearing the editor preserves the saved draft.

The earlier New post path flushed the native cache without first reading the
current editor. The new Save, New draft, library, switch-draft, and reload paths
read every post directly from WebKit before leaving. They wait briefly for
queued input, keep editor focus until the read completes, and confirm the disk
write. A failed or timed-out read leaves the editor open. A failed write also
blocks the transition. Messages from old documents and messages arriving while
the library is open cannot erase or replace saved text.

Attachments remain in the open composer after Save draft. The library stores
text only. Starting another draft still warns before removing attachments.
Existing accounts, draft IDs, and local storage paths are retained.

Regression checks cover the actual native buttons, the last queued input,
same-entry edits, fresh composers, library search, delete/cancel, failed reads,
failed disk writes, and stale document messages. Visual checks cover normal and
minimum-width windows. Logs and rendered views are in `build/draft-library-*`.
Existing draft files were copied to `build/draft-backup-2026-10-27` before the
update. All of these local artifacts are ignored by Git.

Validation: 14 unit tests and all 140 WebKit/native UI checks passed. The
universal build and installed code signature passed verification. Live checks
confirmed Save draft → library → Edit, immediate typing followed by Save, and
New draft → library → Edit. The temporary check text was removed. The original
draft IDs and post text match the backup exactly. No post was published.

---

# Update review — 0.8.0, 2026-10-26

Reviewed `fa08250..4db4d4d` on `claude/laughing-turing-kevk7e`, then fixed the
findings below in the local working tree. Build 18 includes the draft fixes,
the live Add post focus fix, and native restoration of saved threads.

## Findings fixed

1. **P1 — Partial thread restoration overwrote the full draft.** The visible
   posts now use a separate draft ID. The original remains complete and cannot
   be evicted by the partial copy at the store's size limit. Control-click a
   saved draft to copy all its text. Reload, new post, and quit are blocked while
   restoration runs. Stale restoration callbacks cannot attach to a new load.

2. **P2 — Disk write failures were silent.** Persistence now returns its result
   and retains pending changes after an error. The app shows a persistent status
   message. Quit, reload, new post, draft switching, and sign-out require a
   successful save. The error dialog lets the user copy all drafts. Saving and
   leaving work again after the storage problem is fixed.

3. **P2 — Restoration ignored whitespace differences.** Text comparison now
   preserves line breaks and repeated, leading, and trailing spaces. Only line
   endings and WebKit's nonbreaking space representation are normalized. The
   script verifies the restored text before reporting success.

4. **P2 — Continuous typing postponed every disk save.** The first change now
   sets a 0.6-second deadline. Later keystrokes do not move it. Leaving flushes
   pending changes. The README explains that an abrupt crash can still lose
   changes made since the last successful write.

5. **P2 — Add post exposed an unrelated audience popup.** The live app added
   the next post but treated the audience controls mounted during the change as
   a requested popup. That popup took keyboard focus. Add post no longer
   authorizes popup activation, for mouse, keyboard, or draft restoration.
   The regression fixture mounts a dormant audience portal with the new post.
   It runs in a focused native window and checks that typing reaches the new
   editor. The earlier detached fixture did not exercise popup focus recovery.

6. **P2 — X rolled back restored text and synthetic Add post clicks.** Saved
   text now enters through WebKit's native text-input interface. Thread
   restoration focuses Add post and uses native keyboard activation. Each
   request is bound to the selected draft, restore attempt, and post index.
   Space activates Add post without inserting a newline in the new editor.
   Restoration blocks submission clicks and activation keys on unexpected targets.
   Text is checked again after X updates its editor. Restoration also works
   when the app's window is in the background.

7. **P2 — New Post left the saved draft marked as being edited.** A fresh
   composer now refreshes the draft list immediately. The saved row can be
   opened again. A successful restore clears an earlier partial-thread warning.

8. **P2 — Empty editor blocks added false line breaks to drafts.** Draft.js
   text now comes from its line blocks. Whitespace-only posts save as empty
   text, including legacy drafts with placeholder line breaks. Blank lines and
   edge spaces within nonempty posts remain intact. This prevents a false
   partial restore when a saved thread contains a blank post.

## Validation

- 14 unit tests passed, including disk-error retry and protection at the size limit.
- 121 of 122 WebKit checks passed in the final build. Native text input,
  three-post restoration, submission guards, and draft recovery passed.
  The remaining check requires a focused native test window. macOS kept the
  test app inactive (`active=false`, `key=false`), even through Launch Services.
  Its focus assertion remains in place. This is an outstanding test-environment
  limitation; the final suite must not be reported as fully passing.
- The universal app build passed. Both arm64 and x86_64 slices target macOS 14.
- The app's local signature passed verification.
- JavaScript syntax, shell syntax, and diff whitespace checks passed.
- Reviewed the generated composer and expanded-drafts window images.
- The checked-in self-test now exercises partial restoration, copy-command
  availability, save-error warnings, blocked quit/reload, retry, continuous
  typing, and flushing before leaving. It uses the real controller and script
  with synthetic content and disposable stores.
- Live X authoring checks confirmed Add post accepts typing in the next editor
  without an extra click. A three-post draft reopened with its line breaks.
  The original draft reopened with its empty second post. All temporary test
  text was removed, and the original draft was left open in installed build 18.

Local evidence is in `build/final-thread-unit.log`, `build/final-thread-webkit.log`,
`build/final-thread-build.log`, and `build/review-snapshots/`. These files are
ignored by Git. Live authoring used the existing signed-in session. No sign-in
flow or publication was tested. The build is ad-hoc signed, not notarized.

## X/Twitter launch draft

Requested format: one launch post and a short demo video. Live authoring passed.
The final recording still needs a prepared demo account and text.

Suggested post:

> I built Minimal Bird for the times I want to post, then get back to work.
>
> A small Mac app for writing on X. The feed and notifications stay out of sight.
>
> Free and open source.
> https://github.com/Erik5000/minimal-bird

Suggested 20-second demo:

- 0–3 seconds: Show the app and the line “Post to X. Keep the feed out of sight.”
- 3–8 seconds: Type a short post in the composer.
- 8–13 seconds: Start a new post. Open Drafts and restore the saved text.
- 13–17 seconds: Switch between two prepared accounts.
- 17–20 seconds: Show the app name, repository address, and “Free and open source.”

Use prepared demo text. Do not expose private account details. Stop before
submission. The video can show a post ready to send without publishing it.
Until a notarized build exists, describe the download as an experimental Mac
build and include the source-build option in the release reply.

---

# Previous release review — 0.6.0, 2026-10-07

Polish update (0.8.0): typing no longer plays the macOS alert sound. X's editor inserts text itself, so WebKit returned each keystroke up the responder chain as unhandled and the window beeped; the composer controller now ends that chain quietly. The compact layout, which switched to X's raw layout whenever the audience pill, a link card, a thread, or a poll appeared, is replaced by a structure-independent skin: X's computed colors are mapped onto the app palette and the composer uses one system typeface. Focus restoration no longer takes focus from a control inside the composer, which had returned focus to the first post after X added a thread post. Composer text, including threads, is now saved locally per account as drafts (a private file on this Mac) and listed in a collapsible panel; opening a draft pastes its posts back into X's editors. Account and app actions moved from an overlay button to the title bar. CI uploads window snapshots rendered from synthetic pages.

Rename update (0.7.0): the app is now Minimal Bird, with the bundle identifier `io.github.erik5000.minimalbird`. Saved accounts and sessions from earlier builds do not carry over. Sign in again after the update.

Publication update (0.6.1): the first public source snapshot uses GPL-3.0-only, includes Search/Office Commun inspiration credits, and bundles its license and notices in the app. The About dialog exposes the license. The experimental app ZIP is distributed alongside its exact corresponding source and checksums; it remains ad-hoc signed and not notarized.

Reviewed all application source, account storage and navigation policy, WebKit filtering, window and draft lifecycle, icon generation, tests, CI, and build/install/release scripts. This is a source and integration review of Minimal Bird, not a security audit of X's website.

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
