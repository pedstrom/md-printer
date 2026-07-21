# Markdown Printer

Markdown Printer is a native macOS app that turns local Markdown files into polished, printable PDFs. Drop a file into the window, open one from Finder or the app, then save or print the PDF shown in the preview.

## What it formats

- Avenir Next body text and headings, with true monospaced inline and fenced code
- Bold, italic, bold-italic, `<u>underlined</u>`, and strikethrough text
- Ordered, unordered, and task lists
- Block quotes, inline code, fenced code blocks, links, and horizontal rules
- Searchable native tables with alignment
- PNG, JPEG, GIF, and other macOS-readable images referenced by local paths

Images are resolved relative to the Markdown file. Missing, corrupt, and remote images become visible placeholders instead of silently disappearing or making a network request.

## Build and run

The project requires macOS 14 or newer and Xcode/Swift 6.1 or newer.

```sh
scripts/run_app.sh
```

This builds `build/Markdown Printer.app` and opens it. The app registers `.md`, `.markdown`, `.mdown`, and `.mkd` as Markdown documents, so it can also be selected through Finder's Open With menu after it has been launched once.

To render without opening the GUI:

```sh
scripts/render_markdown.sh Examples/showcase.md /private/tmp/showcase.pdf
```

## Verification

```sh
scripts/verify.sh
```

The verification gate runs XCTest with code coverage, requires at least 95% line coverage across testable production Swift, builds the release app, validates the `.app` bundle, checks shell scripts and the property list, and rejects common repository-hygiene problems. Only the minimal executable entrypoints and thin declarative SwiftUI/PDFKit views are excluded from the coverage calculation.

See [AGENTS.md](AGENTS.md) and the repo-local skills under `.codex/skills/` for the borrowed Blutti/Dram Scout working conventions.
