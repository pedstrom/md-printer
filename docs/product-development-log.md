# Product Development Log

## 2026-08-12 — Version 1.0.4

- Released concrete PDF file-URL dragging for destinations such as Microsoft Teams as version 1.0.4, build 5.
- Refreshed the public README download label and the signed, notarized GitHub release ZIP.

## 2026-08-12 — Compatible PDF attachments for Microsoft Teams

- Replaced preview file-promise drags with concrete local PDF file URLs so destinations such as Microsoft Teams receive the same attachment form as a Finder drag.
- Preserved the original Markdown basename for the dragged PDF while isolating repeated names in private temporary directories.
- Added bounded cleanup for canceled, accepted, and abandoned drag artifacts without changing preview, save, print, or PDF bytes.
- Added regression coverage for file-URL pasteboard data, exact bytes and filenames, private permissions, cleanup timing, and error forwarding.

## 2026-08-11 — Version 1.0.3 and notarized distribution

- Replaced ad-hoc release signing with Developer ID Application signing, hardened runtime, and a secure timestamp.
- Added automated Apple notarization, ticket stapling, final signature validation, and Gatekeeper assessment to the release packager.
- Released the notarized distribution workflow and support link as version 1.0.3, build 4.
- Updated installation guidance for the normal macOS security flow while keeping credentials in the local Keychain.

## 2026-07-27 — Version 1.0.2

- Released the width-responsive preview and direct PDF-dragging improvements as version 1.0.2, build 3.
- Refreshed the public README download label and the GitHub latest-release ZIP.

## 2026-07-27 — Drag PDFs directly from the preview

- Added a native hold-then-drag gesture to the PDF preview so the complete generated PDF can be dropped onto the Desktop or into apps that accept PDF attachments.
- Kept quick PDF drags available for text selection and used a standard macOS file promise so the destination receives the same bytes shown in the preview.
- Changed Save PDF and dragged-file defaults to preserve the original Markdown filename while replacing its extension with `.pdf`; H1 text remains the window title only.
- Added regressions for source-filename precedence, compound extensions, file-promise type, exact promised bytes, write failures, and press-gesture configuration.

## 2026-07-22 — Local Markdown links and version 1.0.1

- Resolved relative document links against the open Markdown file's folder before writing PDF annotations.
- Routed clicks on local Markdown links back through the app's document opener so linked files open in their own Markdown Printer windows; web and other file links retain normal macOS handling.
- Bumped the app to version 1.0.1, build 2.
- Added an explicit release gate requiring the distributable ZIP to be rebuilt and validated before a version push, followed by verification of the refreshed public release asset.

## 2026-07-22 — MIT license and public About link

- Licensed Markdown Printer under the MIT License and linked the license from the public README.
- Added a clickable MIT License link to the standard macOS About panel while preserving the app name, version, icon, and Peter Edstrom copyright metadata.
- Removed references to unrelated private project names from the current public documentation.

## 2026-07-21 — Public 1.0 release

- Promoted the app to version 1.0 and added Peter Edstrom's name to the standard macOS About panel metadata.
- Rewrote the public README around direct app download, local-first product benefits, multi-document use, and the afternoon vibe-coding origin story.
- Moved build and run utilities into a dedicated folder, added a developer guide, and added a reproducible ZIP packager for GitHub releases.
- Made the downloadable app universal so the same 1.0 ZIP runs natively on both Apple Silicon and Intel Macs that support macOS 14.

## 2026-07-21 — Multi-document windows

- Added native multi-document handling so batches sent from Finder, Open With, the file chooser, or drag-and-drop open one independent preview window per Markdown file.
- Made the welcome chooser accept multiple selections and changed drop handling to collect every Markdown file instead of stopping after the first one.
- Preserved per-document H1 window titles and independent Save PDF and Print actions in every window.

## 2026-07-21 — Quit after the final window closes

- Added native macOS lifecycle handling so closing the last Markdown Printer window terminates the app instead of leaving it running without a window.
- Preserved normal multi-window behavior: the app remains active while any document window is still open.

## 2026-07-21 — Centered page-number footers

- Added a small Avenir Next page number centered in the existing bottom margin of every generated PDF page.
- Kept page numbers outside the document text area so pagination and content placement remain unchanged across preview, save, and print.

## 2026-07-21 — Compact heading and list transitions

- Removed the redundant blank line after level-two through level-six headings, cutting their visible following space roughly in half while retaining the renderer's intentional paragraph spacing.
- Removed the extra blank line between an introductory paragraph and the list that immediately follows it, keeping the paragraph and its bullets visually connected.

## 2026-07-21 — Content-aware table columns

- Replaced equal-width table columns with a constrained content-aware layout: each column retains a readable minimum, while prose-heavy columns receive more of the remaining page width.
- Kept balanced tables balanced and added regressions for both equal two-column layouts and narrow/wide/narrow three-column layouts.
- Made PDF foreground, secondary, and link colors appearance-independent so rendering while macOS is in Dark Mode cannot produce white text on white paper.

## 2026-07-27 — Width-responsive PDF preview

- Made the continuous PDF preview refit to the available width whenever the document window becomes wider or narrower.
- Preserved the initial full-page launch fit and limited responsive zoom changes to width changes, so resizing only the window height does not unexpectedly alter the PDF scale.
- Added native PDFView regressions for both width-responsive scaling and height-only resizing.

## 2026-07-21 — More compact document typography

- Reduced body copy from 12 to 10 points and tightened the complete heading scale, with a larger reduction at the oversized top levels.
- Kept inline and fenced code proportional to the smaller body text so documents fit materially more content on each page without losing their typographic hierarchy.

## 2026-07-21 — Retro printer app icon

- Added a simple, original macOS app icon that combines a printer and Markdown page with a restrained mid-century travel-poster palette and screen-print texture.
- Added a reproducible icon builder and package verification so every release bundle includes the full macOS icon set.

## 2026-07-21 — Simplified document window

- Removed the Open Markdown toolbar button from document windows, leaving only Save PDF and Print; the empty welcome screen still provides its initial file chooser.
- Removed the duplicate filename/font-status strip above the PDF preview.
- Made the first level-one Markdown heading the live macOS window title, with the filename retained as the fallback when a document has no H1.
- Added standard Command-S and Command-P shortcuts for the Save PDF and Print dialogs.

## 2026-07-21 — Full-page launch and Space navigation

- Changed the initial window to a portrait-oriented size and made the continuous PDF preview initially use PDFKit's best-fit scale, so the complete first Letter page is visible at launch.
- Made the preview the initial keyboard focus and mapped an unmodified Space key to advance exactly one PDF page.
- Added native PDFView regressions for full first-page visibility and one-page Space navigation.

## 2026-07-21 — Print margin fidelity

- Removed the print path's second 54-point margin layer and disabled page-to-fit scaling, so printing and Print-dialog PDF saves preserve the generated Letter page's original size and placement.
- Added a print-to-PDF regression that compares the printed page size and heading position with the in-app preview PDF.

## 2026-07-21 — Continuous quotation borders

- Replaced the quotation's first-line `│` glyph with a native TextKit left border, so the rule spans the full height of wrapped and explicit multi-line quoted text.
- Added left and vertical insets that keep italic quotation text comfortably separated from the rule.

## 2026-07-21 — Code typography and spacing

- Switched inline and fenced code from Avenir Next to the native monospaced system font so code alignment and character widths are correct.
- Rebuilt fenced code backgrounds with native text-block padding, giving code consistent breathing room on all four sides instead of letting the background begin at the first glyph.

## 2026-07-21 — Native Markdown-to-PDF foundation

- Created a native macOS app that accepts Markdown through an Open panel, app file-open events, and drag-and-drop.
- Chose a dependency-free native rendering pipeline: a testable Markdown parser and Avenir Next attributed renderer, TextKit pagination, CoreGraphics PDF generation, and PDFKit preview/print. This keeps documents local and ensures preview, save, and print use identical PDF bytes.
- Added formatted headings, inline emphasis, strong text, `<u>` underlining, strikethrough, code, links, quotes, ordered/unordered/task lists, horizontal rules, native searchable tables, and aspect-fitted local images with visible missing/remote-image placeholders.
- Registered Markdown document extensions in a real macOS `.app` bundle and added build, run, and command-line fixture-rendering workflows.
- Added local agent instructions, product and change-gate skills, a product log, focused commit workflow, release verification, and an enforced 95% testable-production line-coverage floor.
- Added a rendered-page visual QA pass and corrected the CoreGraphics coordinate transform so PDF text is upright and begins at the intended top margin; an integration assertion now guards heading placement.
- A native app-window smoke test found PDFKit initially preserving an offset that clipped the first heading beneath the toolbar; the preview now explicitly opens at the top of page one.
- Hardened repeatable local packaging by removing Finder/resource-fork metadata from the generated app bundle before ad-hoc signing.
