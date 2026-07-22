---
name: md-printer-native-screenshots
description: Use when visually validating Markdown Printer with the real macOS app or rendered PDF pages, including fixture generation, app launch, screenshots, and artifact cleanup.
---

# Markdown Printer Native Visual Checks

1. Build the real app with `scripts/build-and-run/build_app.sh` and keep the generated `.app` under ignored `build/`.
2. Render `Examples/showcase.md` to a PDF in `/private/tmp`, or open that fixture in the native app.
3. Inspect representative first, table, image, and later pages using the native PDF preview or rendered page PNGs.
4. Check Avenir Next typography, heading hierarchy, emphasis/underline, table borders and alignment, image aspect ratio, page margins, and page breaks.
5. Capture screenshots outside the repository, normally under `/private/tmp/md-printer-screenshots`, and return absolute image links.
6. Never commit generated PDFs, PNGs, app bundles, or machine-specific state.
