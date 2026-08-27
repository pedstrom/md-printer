# Markdown Printer Showcase

This page demonstrates **strong text**, *emphasis*, ***both together***, <u>underlining</u>, ~~strikethrough~~, with `inline code` in a true monospaced font.

Setext heading
===============

Entities decode after Markdown structure: &copy; &AElig; &#9731;.

## Lists and quotations

> A polished PDF should remain readable, searchable, and faithful to the source Markdown.

- A regular bullet
- [x] A completed task
- [ ] An open task
  - A nested item with **strong text**
  - A second nested item

- A loose item with its own paragraph.

  Its continuation retains the looser spacing.
- The next loose item

3. An ordered item beginning at three
4. Another ordered item

Delimiter runs follow CommonMark precedence: ***strong emphasis***, **strong with *nested emphasis***, and `code containing **literal markers**`.

## Table

| Feature | Status | Notes |
| :--- | :---: | ---: |
| Headings | Ready | 6 levels |
| Local images | Ready | Aspect-fit |

## Code

```swift
let document = try MarkdownDocument.load(from: inputURL)
let pdf = try PDFExporter().pdfData(from: renderer.render(document: document))
```

    Indented code remains literal too.
        Excess indentation is preserved.

---

Links remain available in the PDF, including [OpenAI](https://openai.com), [a reference link][reference], and the core autolink <reader@example.com>.

Inline raw HTML such as <kbd>Command-P</kbd> is shown literally in a code style. An HTML block is also preserved as inert source:

<div class="print-example">
  <img src="https://example.com/not-fetched.png" alt="Never fetched">
</div>

## Footnotes

Footnote references become compact superscript links instead of exposing their Markdown markers.[^sample]

[^sample]: Footnote text is collected here in a smaller, print-friendly style with a link back to its first reference.

### Missing image behavior

![A deliberately missing sample image](missing-showcase-image.png)

![The same missing image through a reference][missing-image]

[reference]: https://commonmark.org/ "CommonMark"
[missing-image]: missing-showcase-image.png "Missing local fixture"
