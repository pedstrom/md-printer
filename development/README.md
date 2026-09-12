# Developing Markdown Printer

Markdown Printer contains a native SwiftUI/AppKit macOS app and a separate SwiftUI/UIKit iPhone viewer. The shared parser and syntax tree, each platform’s renderer and PDF generator, preview, save path, print path, and Finder Quick Look renderer are all local and dependency-free. Sparkle 2 supplies the isolated macOS update client; it does not participate in document rendering.

The full app uses the generated PDF as the single source of truth for preview, save, and print. The embedded `MarkdownPrinterQuickLook.appex` is a separate continuous reading surface that shares `MarkdownPrinterCore` before PDF pagination. Its testable behavior lives in the `MarkdownPrinterQuickLookSupport` SwiftPM library; the Xcode app-extension target under `QuickLookExtension/` is only the `QLPreviewingController` bridge required by macOS.

## Requirements

- macOS 14 Sonoma or newer
- Xcode with Swift 6.1, the iOS 26 SDK, and an iOS 26 simulator
- A paid Apple Developer team and connected iOS 26 iPhone only for the non-seven-day device build

## Build and run

All build and run utilities live in `scripts/build-and-run/`.

```sh
scripts/build-and-run/run_app.sh
```

This builds a universal Apple Silicon and Intel app at `build/Markdown Printer.app` and opens it. The same build embeds a universal Quick Look extension at `Contents/PlugIns/MarkdownPrinterQuickLook.appex`, gives it the host's display version and build number, applies its read-only sandbox entitlements, signs it before the outer app, and validates the nested bundle. To build without launching:

```sh
scripts/build-and-run/build_app.sh
```

To render a Markdown file from the command line:

```sh
scripts/build-and-run/render_markdown.sh Examples/showcase.md /private/tmp/showcase.pdf
```

### Build and install the iPhone app

Open `iOS/MarkdownPrinterIOS.xcodeproj` in Xcode. The **MarkdownPrinterIOS** scheme builds version 1.0 (build 1) for iPhone only with bundle ID `com.peteedstrom.markdown-printer.ios`. The target uses automatic signing and deliberately does not track a development-team identifier; select the paid team available in your local Xcode account before running on a phone.

For a reproducible command-line build, signature check, provisioning-profile lifetime check, and optional install, use:

```sh
scripts/build-and-run/build_ios_device.sh --install
```

The helper derives the paid team from the local Apple Development certificate unless `MARKDOWN_PRINTER_IOS_TEAM_ID` is set. It also accepts `MARKDOWN_PRINTER_IOS_DEVICE_ID` when more than one phone is connected. It verifies the embedded profile matches the requested team and refuses profiles with a seven-day-or-shorter lifetime. Certificates and provisioning profiles remain in the login Keychain and Xcode-managed local storage.

The iOS target hosts `UIDocumentBrowserViewController`, so Recents, Shared, Browse, Open In, local files, iCloud Drive, and other system file providers stay under Apple’s document APIs. The active `MobileDocumentSession` owns security-scoped access, coordinates reads, refreshes provider changes, and caches one asynchronous Letter PDF per document revision. The native SwiftUI screen renderer is independent from the Core Graphics/TextKit print renderer, while both consume the same shared Markdown syntax tree.

To create the signed and Apple-notarized ZIP archive used for GitHub releases, first store notarization credentials in the login Keychain and identify the Developer ID Application certificate:

```sh
xcrun notarytool store-credentials "MarkdownPrinterNotary"
security find-identity -v -p codesigning
```

Then run the release packager with the full signing identity and Keychain profile name:

```sh
MARKDOWN_PRINTER_SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
MARKDOWN_PRINTER_NOTARY_PROFILE="MarkdownPrinterNotary" \
scripts/build-and-run/package_release.sh
```

The packager embeds Sparkle with its framework symlinks intact, signs every helper, framework, and the Quick Look extension from the inside out, enables the hardened runtime, adds secure timestamps, waits for Apple to accept the submission, staples the ticket to the app, and validates the final archive with `codesign`, `stapler`, Gatekeeper, runtime-linkage, entitlements, matching nested versions, and universal-architecture checks. Notarization credentials stay in the macOS Keychain and are never stored in the repository.

## Secure update releases

Sparkle's EdDSA private update key belongs in the login Keychain. Generate it once and copy only the displayed public key into `SUPublicEDKey` in `Resources/Info.plist`:

```sh
.build/artifacts/sparkle/Sparkle/bin/generate_keys
```

Immediately export one protected backup to a secure location outside this repository, then remove any unprotected intermediary after confirming the backup can be recovered:

```sh
.build/artifacts/sparkle/Sparkle/bin/generate_keys -x /path/outside-the-repository/sparkle-private-key
```

Every release must increment both `CFBundleShortVersionString` and the monotonically increasing `CFBundleVersion`. Add the Markdown notes at `release-notes/<display-version>.md`, run focused tests and `scripts/verify.sh`, commit the verified source, and only then run `package_release.sh`. The packager produces exactly these uploadable files under `build/release-assets/v<display-version>/`:

- `Markdown-Printer.zip`
- `Markdown-Printer.md`
- `appcast.xml`

The appcast and both linked assets are EdDSA-signed. Its enclosure and release-notes links use the immutable tag-specific GitHub URL, while installed apps discover the stable feed through `https://github.com/pedstrom/md-printer/releases/latest/download/appcast.xml`. Delta updates are intentionally disabled.

Create the matching GitHub Release as a draft and upload all three generated assets before publication. Do not publish, push the tag, or alter an existing public release without Pete's separate authorization. Once publication is authorized and complete, verify the stable release, the `latest` redirect, all signatures, notarization, Gatekeeper, and the public ZIP digest:

```sh
scripts/build-and-run/verify_published_release.sh v1.4.4
```

Drafts and prereleases are not update channels. A release intended for the app must be stable, and the release tag must match the display version exactly.

## Test and verify

```sh
scripts/verify.sh
```

The release gate runs all XCTest coverage, enforces at least 95% testable-production line coverage, builds the release app, validates its bundle metadata, icon, Sparkle configuration, embedded helpers, Quick Look principal class and supported content types, sandbox entitlements, runtime linkage, nested versions and signatures, and universal architectures, checks every shell script, and rejects common repository-hygiene problems.

The same gate runs the iOS unit, structural PDF, and UI suites on an installed iPhone simulator and separately enforces at least 95% line coverage for `MarkdownPrinterMobileSupport`. Run only the iOS gate with:

```sh
scripts/build-and-run/test_ios.sh
```

Set `MARKDOWN_PRINTER_IOS_SIMULATOR_ID` to choose a particular iPhone simulator. Thin SwiftUI view composition is exercised by UI tests but excluded from the mobile-support coverage denominator.

It also builds a release-mode benchmark executable and enforces latency, main-thread responsiveness, memory, and 10× input-scaling budgets for representative 100 KB and 1 MB Markdown documents across parsing, attributed rendering, PDF generation, Finder Quick Look rendering, and Word export. Run that gate alone with:

```sh
scripts/performance_check.sh
```

For native Quick Look QA, first build and open a disposable app copy so Launch Services discovers the embedded provider. Use `qlmanage -p Examples/showcase.md` for a direct provider smoke test, then verify Finder's Space and Command-Y previews, vertical scrolling, resizing, selection/copying, links, footnote jumps, tables, code, long documents, and both appearances. Keep screenshots and disposable app copies outside the repository. Extension activation is a macOS setting; production code does not call `pluginkit`, reset Quick Look, or use private registration APIs.

Update QA must preserve the extension bundle ID `com.peteedstrom.markdown-printer.quicklook`, executable name `MarkdownPrinterQuickLook`, and nested `Contents/PlugIns/MarkdownPrinterQuickLook.appex` path. Exercise an app without the extension updating through Sparkle to the first Quick Look build, then exercise one more in-place Sparkle update. Confirm the provider remains registered and retains its enabled state after the second replacement, and that deleting the disposable host app removes that copy of the provider.

See [AGENTS.md](../AGENTS.md) and the repo-local skills under `.codex/skills/` for the project's working conventions.
