# Contributing

Use X's website and Apple frameworks; keep posting under the user's control.
Feeds, notifications, engagement, and external navigation must stay hidden.

Run `swift test --disable-sandbox`, build with `./scripts/build-app.sh`, and
run the packaged executable with `--self-test`. Rendering tests use synthetic
pages and an isolated WebKit store. Never use a real public post as an automated
test. Update the fixtures when changing surface recognition or navigation.

Keep credentials, cookies, personal handles, diagnostics, signing certificates,
and generated build files out of commits. Include the macOS and X layout/flow
in bug reports, with any personal content removed from screenshots.

App icon source is `scripts/make-icon.swift`; no external assets are required.
Builds are locally signed. Notarized binary distribution requires the distributor's
own Developer ID signing and notarization.

Contributions are licensed under GNU GPL v3.0 only (`GPL-3.0-only`), matching the project. Keep existing copyright and license notices, and use compatible licensing for any new dependencies.
