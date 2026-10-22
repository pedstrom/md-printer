# Markdown support

[All documentation](README.md) · [Mac guide](mac-guide.md) · [iPhone and iPad guide](ios-support.md)

Markdown Printer shares its parser across Mac, Finder Quick Look, iPhone, and iPad. Each reading or export surface uses that syntax tree with its own native layout.

## Supported formatting

- ATX and Setext headings, paragraphs, and horizontal rules.
- Bold, italics, bold italics, strikethrough, and `<u>underlining</u>`. Standard `__strong__` remains bold.
- Ordinary, ordered, nested, and task lists; quotations.
- Tables, inline code, fenced code, and indented code.
- Inline and reference links, bare autolinks, section links, and footnotes.
- Local inline and reference images, and standalone HTML `<img>` tags.
- Entity references, Unicode, and the `<br>` line-break extension.

Prose and headings use Avenir Next, with a system-font fallback if unavailable. Code uses a true monospaced system font. PDF exports use searchable US Letter pages with page numbers. Mac Word exports preserve editable formatting, links, tables, and images.

## Images

Local images resolve relative to the Markdown file's folder and preserve their proportions. Missing or corrupt images have readable placeholders.

In Mac PDFs, table images fit inside each cell's measured content area and padding. Near a page break, an image row may shrink by up to 15% to stay with a short following caption row. Larger overruns move to the next page; exceptionally tall images first fit within a full page. Images keep their proportions throughout.

Secure remote images load automatically when a document opens. On Mac, **Settings > General > Automatically download remote images** is on by default; turn it off for manual downloads. Click an unavailable image to download or retry it, or use its context menu to download every remote image in the document. On iPhone and iPad, tap an unavailable image to retry. Downloads go to the app's disposable cache and are never written beside the Markdown file.

Finder Quick Look stays offline and may lack permission to read neighboring local images. Its placeholders show a centered filename without the full path. In the mobile app, granting access to the containing folder can enable linked local images and documents.

## Links, sections, and task lists

Bare `https://example.com`, `http://example.com`, `www.example.com`, `hello@example.com`, `mailto:hello@example.com`, and `xmpp:hello@example.com/resource` become links using [GFM’s extended autolink rules](https://github.github.com/gfm/#autolinks-extension-). Visible text is preserved, with trailing punctuation and unmatched closing parentheses excluded from the link. Code, raw HTML, image descriptions, and existing link labels do not gain nested links.

Use `- [ ] Pending`, `- [x] Done`, or `- [X] Done` for read-only checkboxes. Whitespace must follow the marker; tabs, nesting, continuation paragraphs, and mixed ordinary/task lists are supported.

Use `[Packing](#packing-list)` to jump to `## Packing List`, or `[Packing](other.md#packing-list)` to open a section in another local Markdown file. Relative paths resolve from the source Markdown file’s folder. Following [GitHub’s heading rules](https://docs.github.com/en/get-started/writing-on-github/getting-started-with-writing-and-formatting-on-github/basic-writing-and-formatting-syntax#section-links), anchors use lowercase heading content, remove formatting and punctuation, replace spaces with hyphens, retain Unicode letters and underscores, and resolve collisions in document order with numeric suffixes such as `-1`. All six heading levels, including headings inside quotations and lists, receive anchors. Percent-escaped filenames and fragments are supported. Custom HTML anchors are outside this support.

Same-document sections work in Mac preview, continuous Finder Quick Look, and the iPhone/iPad reader. Quick Look requests cross-file section navigation through the Mac app's registered local URL route without requesting access to sibling files. The Quick Look host controls whether that app launch is allowed; if it declines, the preview shows a notice to open the source file in Markdown Printer using the toolbar. Missing same-document sections do not open an external application; a cross-file heading failure in the app reports the missing section while leaving the opened document available.

PDF exports contain native heading destinations and GoTo links; Word exports contain Word-safe heading bookmarks and internal hyperlinks. Cross-file links in both formats remain standard `file:` URLs with fragments. Outside Markdown Printer, heading navigation depends on the receiving viewer and associated app.

PDFs generated on Mac also contain a clickable heading outline. All six heading levels appear in source order, nested under the nearest preceding higher-level heading, including headings inside lists and quotations. In macOS Preview, choose **View > Table of Contents** to show it.

## Compatibility and HTML

Markdown Printer implements selected CommonMark 0.31.2 syntax rather than claiming complete CommonMark conformance. Its compatibility suite currently matches 641 of the specification's 652 normative examples (98.3%), including every example for headings, emphasis, code spans and blocks, references, autolinks, entities, raw HTML, images, and line breaks. The remaining gaps are uncommon block-quote and deeply nested-list edge cases plus one unusual link-label case.

Arbitrary raw HTML is displayed as literal, code-styled source and is never executed. A standalone `<img>` tag is the narrow exception: it uses the same image handling as Markdown image syntax on each platform, as described above. The app's established `<u>` underline and `<br>` line-break extensions remain available.

The compatibility count above was rechecked on October 13, 2026. The [CommonMark fixtures](../Tests/MarkdownPrinterCoreTests/Fixtures/CommonMark/README.md) record their upstream source and license; the development guide explains how to [run verification](../development/README.md#test-and-verify).
