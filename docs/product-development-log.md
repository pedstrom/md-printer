# Product Development Log

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
- Adapted the useful Blutti and Dram Scout repository conventions into local agent instructions, product and change-gate skills, a product log, focused commit workflow, release verification, and an enforced 95% testable-production line-coverage floor.
- Added a rendered-page visual QA pass and corrected the CoreGraphics coordinate transform so PDF text is upright and begins at the intended top margin; an integration assertion now guards heading placement.
- A native app-window smoke test found PDFKit initially preserving an offset that clipped the first heading beneath the toolbar; the preview now explicitly opens at the top of page one.
- Hardened repeatable local packaging by removing Finder/resource-fork metadata from the generated app bundle before ad-hoc signing.
