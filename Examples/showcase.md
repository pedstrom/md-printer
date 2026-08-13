# Markdown Printer Showcase

This page demonstrates **strong text**, *emphasis*, ***both together***, <u>underlining</u>, ~~strikethrough~~, with `inline code` in a true monospaced font.

## Lists and quotations

> A polished PDF should remain readable, searchable, and faithful to the source Markdown.

- A regular bullet
- [x] A completed task
- [ ] An open task

3. An ordered item beginning at three
4. Another ordered item

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

---

Links remain available in the PDF, including [OpenAI](https://openai.com).

## Footnotes

Footnote references become compact superscript links instead of exposing their Markdown markers.[^sample]

[^sample]: Footnote text is collected here in a smaller, print-friendly style with a link back to its first reference.

### Missing image behavior

![A deliberately missing sample image](missing-showcase-image.png)
