# Markdown Printer Agent Instructions

These instructions apply to the whole repository.

## Working Agreement

- Treat this as a native, local-first macOS app for turning Markdown files into polished PDFs.
- Keep all document content on the Mac. Do not add uploads, analytics, cloud services, remote image fetching, or a WebView rendering dependency unless Pete explicitly asks.
- Use Avenir Next for rendered prose and headings, with an explicit system-font fallback only when the font is unavailable. Use a true monospaced system font for inline and fenced code.
- Favor small, coherent changes with clear commits. Do not leave meaningful completed work uncommitted.
- Update `docs/product-development-log.md` for meaningful product, architecture, rendering, testing, or workflow changes.

## Architecture

- Use Swift, SwiftUI, AppKit, TextKit, CoreGraphics, PDFKit, SwiftPM, and XCTest.
- Keep parsing, rich-text rendering, image resolution, pagination, and PDF generation independent from the SwiftUI composition layer.
- The generated PDF is the source of truth for preview, save, and print; do not maintain three subtly different rendering paths.
- Route File > Open, Finder Open With, Dock/open events, and drag-and-drop through the same `DocumentSession` loading path.
- Resolve embedded images from local file URLs relative to the Markdown file. Show a readable placeholder for missing, corrupt, or remote images.
- Markdown underline syntax is `<u>text</u>`. Preserve standard `__strong__` behavior.

## Testing Bar

- Add or update tests with every production behavior change.
- Maintain at least 95% line coverage across testable production Swift. The only coverage exclusions may be minimal executable entry points and thin SwiftUI/AppKit composition views; core rendering and platform adapters stay covered.
- Run the narrowest relevant XCTest set first, then `scripts/verify.sh` before committing.
- Cover headings, inline styles, underline, lists, quotes, tables, code, links, Unicode, image success/failure, multi-page text, multi-page tables, PDF page size, searchable text, link annotations, saving, and printing seams.
- For rendering changes, build a real PDF fixture and inspect its rendered pages in addition to structural tests.
- If a test, coverage check, release build, bundle check, or visual check fails, keep iterating until it is green or report the exact blocker.

## Commit Discipline

- Stage intentionally and inspect the staged diff for non-trivial work.
- Commit through `scripts/commit_staged.sh "Message"` so the staged verification gate and commit remain paired.
- Keep generated PDFs, app bundles, DerivedData, local machine state, and secrets out of Git.
- Treat Finder/sync duplicate-copy artifacts as repository hygiene failures.

## Local Skills

- Use `.codex/skills/md-printer-macos/SKILL.md` for product behavior, native architecture, Markdown formatting, images, PDF fidelity, and XCTest expectations.
- Use `.codex/skills/md-printer-change-gate/SKILL.md` for focused tests, full verification, coverage, staging, and commits.
- Use `.codex/skills/md-printer-native-screenshots/SKILL.md` for real app and rendered-PDF visual checks.
