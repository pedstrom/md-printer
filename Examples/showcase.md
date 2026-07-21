# Markdown Printer Showcase

This page demonstrates **strong text**, *emphasis*, ***both together***, <u>underlining</u>, ~~strikethrough~~, and `inline code` in Avenir Next.

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

### Missing image behavior

![A deliberately missing sample image](missing-showcase-image.png)
