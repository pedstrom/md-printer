# Developing Markdown Printer

Markdown Printer is a native SwiftUI/AppKit macOS app. The parser, attributed-text renderer, PDF generator, preview, save path, and print path are all local and dependency-free.

## Requirements

- macOS 14 Sonoma or newer
- Xcode with Swift 6.1 or newer

## Build and run

All build and run utilities live in `scripts/build-and-run/`.

```sh
scripts/build-and-run/run_app.sh
```

This builds a universal Apple Silicon and Intel app at `build/Markdown Printer.app` and opens it. To build without launching:

```sh
scripts/build-and-run/build_app.sh
```

To render a Markdown file from the command line:

```sh
scripts/build-and-run/render_markdown.sh Examples/showcase.md /private/tmp/showcase.pdf
```

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

The packager enables the hardened runtime, adds a secure timestamp, waits for Apple to accept the submission, staples the ticket to the app, creates `build/Markdown-Printer.zip`, and validates the final archive with `codesign`, `stapler`, and Gatekeeper. Notarization credentials stay in the macOS Keychain and are never stored in the repository.

## Test and verify

```sh
scripts/verify.sh
```

The release gate runs all XCTest coverage, enforces at least 95% testable-production line coverage, builds the release app, validates its bundle metadata and icon, checks every shell script, and rejects common repository-hygiene problems.

See [AGENTS.md](../AGENTS.md) and the repo-local skills under `.codex/skills/` for the project's working conventions.
