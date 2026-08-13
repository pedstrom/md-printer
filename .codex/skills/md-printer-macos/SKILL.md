---
name: md-printer-macos
description: Use when changing the native Markdown Printer macOS app, including Markdown parsing, Avenir Next formatting, local images, PDF pagination, preview, save, print, drag-and-drop, file-open behavior, or XCTest coverage.
---

# Markdown Printer macOS

Use this skill for product or implementation work in this repository.

## Product Contract

- Accept Markdown through the Open command, Finder Open With/app file events, and window drag-and-drop.
- Use the first level-one Markdown heading as the macOS document-window title, falling back to the filename when no H1 exists. Keep document-window chrome minimal: Save and Print only, with no duplicate metadata strip inside the window. Command-S opens Save and Command-P opens Print.
- Show the actual generated PDF in a native PDFKit preview.
- Open at a portrait-oriented size with the complete first PDF page visible. In the preview, an unmodified Space key advances exactly one page while retaining continuous vertical scrolling.
- Save the same PDF bytes shown in the preview. Print that complete PDF page at its original scale without adding a second set of margins; the generated page already contains its print-safe margins.
- Offer editable Microsoft Word export as an optional local DOCX path. Keep PDF as the default, provide a standard Settings preference shared by Save and preview dragging, and allow a one-save format override without changing that preference.
- Format prose in Avenir Next with deliberate heading, bold, italic, and bold-italic variants. Use a true monospaced system font for inline and fenced code, with visible internal padding inside fenced code blocks.
- Support headings 1–6, paragraphs, bold, emphasis, `<u>` underline, strikethrough, inline/fenced code, links, linked footnotes, quotes, ordered/unordered/task lists, horizontal rules, tables, and local embedded images. Render footnote references as numbered superscripts and collect their definitions in a compact end-note section. Render quotations with a native continuous left border that spans every wrapped line in the quoted block.
- Keep remote images offline and visible as placeholders. Resolve local relative images against the Markdown file's folder and preserve aspect ratio within the printable area.
- Use US Letter pages with print-safe margins unless a later product decision adds configurable paper sizes.

## Native Architecture

- Keep the SwiftUI shell thin.
- Keep parser, renderer, image handling, TextKit pagination, and CoreGraphics PDF generation in `MarkdownPrinterCore`.
- Use `DocumentSession` as the shared UI workflow seam.
- Use PDFKit for preview and printing. Do not introduce WebKit, an HTML renderer, a hosted service, or third-party Markdown dependency without a demonstrated need.
- Register Markdown extensions in the app bundle so Finder can send files to the app.

## Testing Expectations

- Every changed production behavior gets a deterministic XCTest.
- Maintain 95% or better line coverage across testable production Swift.
- Lock down page size, multi-page flow, searchable text, table flow, image scaling/placeholders, link annotations, initial preview fit, one-page keyboard navigation, and print-to-PDF placement fidelity with PDFKit integration tests.
- After a rendering change, generate `Examples/showcase.md` through `scripts/build-and-run/render_markdown.sh` and inspect rendered pages outside the repo.
- Use `md-printer-change-gate` after focused tests pass.
