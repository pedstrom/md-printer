# Markdown Printer for Mac

[All documentation](README.md) · [Markdown support](markdown-support.md) · [Project and downloads](../README.md)

Open local Markdown and work with a finished, searchable PDF. The preview is the same paginated PDF you save or print; editable Microsoft Word is an optional export.

## Open and read

Use **File > Open**, Finder's **Open With**, or drop Markdown files onto the app. A batch opens each document in its own window. Supported extensions are `.md`, `.markdown`, `.mdown`, and `.mkd`. **File > Open Recent** retains up to twenty files.

Use **Command-F** to find text in the PDF, **Command-G** for the next match, and **Shift-Command-G** for the previous match. Text is selectable and copyable, and section links jump to headings. The **Pages** sidebar provides page thumbnails; **View > Show/Hide Sidebar** controls its visibility.

Saved PDFs include a nested, clickable outline of the document's headings. In macOS Preview, choose **View > Table of Contents** to browse it and jump directly to a section.

## Save, share, print, and drag

PDF is the default export. **Markdown Printer > Settings** can make Microsoft Word the default for Save, Share, and dragging. The Save dialog can change formats for one export without changing that preference. Word exports retain editable text, formatting, links, tables, and local images.

Use **Command-S** to save or **Command-P** to print. You can also hold the preview until its export badge appears, then drag the document into Finder, Messages, Microsoft Teams, or another app that accepts file attachments. Hold **Option** while dragging or clicking **Share** to use the other format once.

Saved and dragged files keep the original Markdown filename with a `.pdf` or `.docx` extension. Dragged files are prepared locally when the drag begins. Opening, searching, exporting, and printing do not edit the Markdown source.

## Compare versions

Choose **File > Compare with Git Version…** (**Control-Command-G**) to select a commit that changed the current file, or **Compare with Older Version…** to supply another Markdown file. **Clear Change Highlighting** (**Control-Command-H**) removes the comparison.

### Markings in PDF and Word

Changed phrases receive continuous yellow highlights, including their internal spaces. Substantial rewrites highlight passages while preserving meaningful unchanged sections; new or moved paragraphs, formatting changes, and changed link targets are also highlighted.

Short removed words and phrases appear in small red callouts with an unstruck caret (`^`) followed by wording with strikethrough. Complete prose removals use plain red summaries such as `^ removed 3 sentences` or `^ removed 2 paragraphs`, with whole-paragraph counts taking priority over sentence counts. Partial prose fragments longer than 12 words use an exact deleted-word count such as `^ removed 18 words`; surviving words in broad rewrite excerpts are excluded from that count. Complete table, list, and subsection removals use structural summaries such as `^ removed 1 table`, `^ removed 3 list items`, or `^ removed 1 section`. Headings and list items are not counted as whole paragraphs, and literal code retains its removed wording. Summary labels prefer enough space for their complete count and unit.

The current text does not move. Callout wording uses precise removals even when a broad rewrite is highlighted. Table callouts truncate before their cell boundary. Available body and cell gaps are preferred over page margins, and the caret stays at the deletion boundary when wording is displaced. PDF connectors are dashed, attach to the nearest available edge of the removed wording, and avoid current text, other notes, and carets. Text removals at the same boundary share one caret; separate removals keep separate anchors. Space limits never block a successful comparison: callouts shorten with an ellipsis, and an ellipsis at the deletion boundary replaces the floating label when it cannot fit or connect safely. When a PDF callout needs a page margin, it omits the caret and wraps up to four lines to show the removed wording, with a leader to its location.

Standalone prose whitespace and minor punctuation changes receive no highlight. Minor punctuation-only removals and ordinary initial-capitalization changes omit the red callout; numbers, negations, quantity symbols, acronyms, images, and code remain meaningful changes. Fragmented replacements in rewritten sentences use a single old-phrase excerpt instead of many individual-word callouts. Changed image references get a yellow border; removed images get `^ removed image`. Image files themselves are not compared.

The original stays fixed while the current file refreshes, and its local snapshot survives session restoration even if the original was temporary. PDF and Word exports include these markings; Word retains editable body text and floating deletion callouts.

### Review in the Changes sidebar

The Mac sidebar offers **Pages** and **Changes**. Pages retains the native page thumbnails. After a comparison succeeds, Changes opens with its first change selected and keyboard focus ready for immediate arrow navigation. Reopening Changes focuses the remembered selection. Its heading-grouped list sits above complete, selectable **Earlier** and **Current** passages. The list and details scroll independently; drag their divider or resize the sidebar to give long passages more room.

Comparison aligns sections and their Markdown structure before comparing words. Whole added lists and sections, removed subsections, and complete table additions or removals appear as single entries. Changed table rows keep their complete cells together and match row identifiers and column meanings; table/list rewrites and paragraph consolidation retain complete Earlier and Current passages. Consecutive complete prose additions and removals are combined. Sidebar highlights use the same coherent current passages as the PDF, while removed-word detail retains exact evidence. Entry numbers, heading groups, arrow navigation, and preview numbers follow one sequence, including renamed sections.

Click an entry or use Previous/Next to visit its current PDF location, including changes in collapsed groups. With Changes open, click a changed paragraph or removal note in the PDF to reveal and select its list entry, then immediately use the arrow keys. Selecting from the PDF keeps its reading position. Text selection and copying, double clicks, modified clicks, links, and held export drags keep their normal behavior. In the Changes list or details, Down/Right Arrow visits the next change and Up/Left Arrow visits the previous change; navigation stops at both ends.

A pale yellow band, amber outline, and circular change number identify the selected passage in the preview. The band includes related removal notes in the margin and continues separately on each page of a long passage. Navigation normally places the passage about a quarter of the way down the preview to retain context above; tall passages use less space above, and comfortably visible passages stay in place. The initial comparison selection does not scroll. Hiding the sidebar removes the band; reopening Changes restores the selected entry’s emphasis without navigating. This selection emphasis stays out of PDF and Word exports.

Removed passages navigate to their deletion boundary and retain their full wording even when a printed note is shortened or summarized. Formatting, link targets, and image references are described explicitly; image pixels are not compared.

Scrolling preserves the selection, ordinary live refreshes retain sidebar choices, and workspace reopening restores the sidebar layout and reading state. **View → Show/Hide Sidebar** controls visibility. Clearing comparison markings returns to Pages.

### Choose a Git version

The native Git picker shows locally available history reachable from `HEAD`, with commit dates, messages, and IDs, and follows detected renames. Use **Up/Down** to select a version and **Return** to compare, or double-click a row. Git must already be installed. Reading history and comparing never changes the repository or fetches remote history. The newest committed version is selected for an edited file; a file that already matches it defaults to the preceding distinct version. The selected historical text and commit timestamp are captured together and remain fixed after reopening.

### Dates in comparison footers

When a configured footer includes a date, differing dates appear on two lines: the current file’s modification date above the original date. The current date has a yellow background; the original is red with strikethrough, with no labels. Existing date/time/time-zone preferences apply to both. Git originals use their commit timestamp; ordinary file originals use their captured file modification time. Matching displayed dates stay ordinary, and unavailable original dates are omitted. PDF and editable Word exports include the same styled footer dates.

### Open a comparison from the command line

AI or shell workflows can open the current file with an explicit original:

```sh
"/Applications/Markdown Printer.app/Contents/MacOS/MarkdownPrinterCLI" open current.md --original older.md
```

Without `--original`, `open` accepts multiple files and opens them normally. An original requires exactly one current file. The app reads both inputs locally and snapshots the original text and file modification timestamp before the CLI returns. Use the native Git picker to capture a historical commit timestamp directly; a file extracted elsewhere from Git retains only the timestamp available on that file.

## Live refresh and unavailable sources

Open documents refresh automatically when their source files change, preserving the window, zoom, and reading position.

On Mac, background source changes never require dismissing a read-error dialog. If a source temporarily disappears or cannot be read, the last successful preview remains visible while the app retries. After about two seconds, a compact banner says “Source file unavailable. Showing the last rendered version.” A successful read refreshes the document as needed and clears the banner, including when its content is unchanged. Confirmed renames and moves update the source filename, relative image/link folder, and window restoration location automatically. If the source stays unavailable, you can close the window and open another file.

## Restore your workspace

After a normal quit, **File → Reopen Windows from Last Session** restores your Mac documents, tabs, window positions and sizes, preview zoom, and scroll positions. Installing an app update restores the same workspace automatically. Windows stay on an available screen if a display has been disconnected; changed document pagination uses the saved page-relative reading position.

## Finder Quick Look and file defaults

Select a Markdown file in Finder and press **Space** or **Command-Y**. Quick Look provides a continuous reading view with selectable text, adaptive light/dark colors, links, and footnotes. It reuses the native Markdown renderer before PDF pagination; the full app still previews the print-ready PDF.

The Quick Look extension is bundled inside the app, so removing Markdown Printer also removes its Quick Look capability. If macOS has disabled it, open **System Settings > General > Login Items & Extensions > Quick Look ⓘ** and turn on Markdown Printer. The app's Settings includes that path and an **Open System Settings…** button.

Quick Look stays offline. macOS may withhold access to neighboring image files even when they render in the full app. Unavailable images appear in bordered boxes with centered filenames, without full paths. See [image behavior](markdown-support.md#images) and the [Quick Look product contract](quick-look-product-contract.md) for details.

Markdown Printer does not silently change your default viewer. Choose **Make Markdown Printer Default** in Settings if you want supported Markdown files to open in it when double-clicked. macOS may ask for consent; the request applies to the declared Markdown content type covering all four extensions.

## Updates and privacy

The downloadable Mac release is signed with a Developer ID certificate and notarized by Apple. Use **Markdown Printer > Check for Updates…** to check for a newer stable version. Versions before 1.3.0 require one manual installation of a current release to gain the updater.

By default, the app checks GitHub daily for signed stable updates. Automatic checks can be disabled in Settings. Updates download and install only after your approval; checks do not send system profiles, analytics, or document contents.

Document rendering stays on your Mac. Remote images are requested only when you choose to download them; Finder Quick Look never downloads them. See the [privacy policy](privacy-policy.md).

## Keyboard reference

| Action | Shortcut |
| --- | --- |
| Open | Command-O |
| Save | Command-S |
| Print | Command-P |
| Find | Command-F |
| Next / previous match | Command-G / Shift-Command-G |
| Compare with Git version | Control-Command-G |
| Clear change highlighting | Control-Command-H |
| Select Git version / compare | Up or Down / Return |
| Next / previous change in Changes | Down or Right / Up or Left |
| Preview in Finder | Space or Command-Y |

For help, [search or open an issue](https://github.com/pedstrom/md-printer/issues). Include the macOS version, app version, and steps to reproduce; use a sample document you are comfortable sharing publicly.
