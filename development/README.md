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

This builds `build/Markdown Printer.app` and opens it. To build without launching:

```sh
scripts/build-and-run/build_app.sh
```

To render a Markdown file from the command line:

```sh
scripts/build-and-run/render_markdown.sh Examples/showcase.md /private/tmp/showcase.pdf
```

To create the same ZIP archive used for GitHub releases:

```sh
scripts/build-and-run/package_release.sh
```

The archive is written to `build/Markdown-Printer.zip`.

## Test and verify

```sh
scripts/verify.sh
```

The release gate runs all XCTest coverage, enforces at least 95% testable-production line coverage, builds the release app, validates its bundle metadata and icon, checks every shell script, and rejects common repository-hygiene problems.

See [AGENTS.md](../AGENTS.md) and the repo-local skills under `.codex/skills/` for the project's working conventions.
