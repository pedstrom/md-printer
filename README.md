<p align="center">
  <img src="Resources/MarkdownPrinterIcon.png" width="144" alt="Markdown Printer app icon">
</p>

<h1 align="center">Markdown Printer</h1>

<p align="center">Turn Markdown files into clean, printable PDFs on your Mac.</p>

<p align="center">
  <a href="https://github.com/pedstrom/md-printer/releases/latest/download/Markdown-Printer.zip"><strong>Download Markdown Printer 1.0.4</strong></a>
</p>

Markdown is suddenly everywhere. AI tools, coding assistants, note apps, and research workflows are producing copious `.md` files, but those files are not always pleasant to print, share, or read away from an editor. Markdown Printer gives them a polished page without sending the document anywhere.

Drop one file—or a whole batch—onto the app. Each document opens in its own window as a finished PDF that you can save, print, or drag directly into Finder, Microsoft Teams, Messages, and other apps that accept PDF attachments.

## What it does

- Formats headings, paragraphs, bold, italics, underlining, strikethrough, links, lists, quotations, tables, and local images
- Uses Avenir Next for the document and a proper monospaced font for code
- Produces searchable, US Letter PDFs with page numbers
- Opens multiple Markdown files at once, each in its own window
- Lets you hold and drag the PDF preview directly to the Desktop or another app
- Keeps your files entirely on your Mac: no account, upload, analytics, or remote rendering

The PDF in the preview is the same PDF that gets saved, printed, or dragged out of the app. Saved and dragged PDFs keep the original Markdown filename with the extension changed to `.pdf`. A dragged PDF is prepared locally only when the drag begins, so apps that accept normal Mac file attachments receive a concrete file with the correct name. Local images are resolved relative to the Markdown file; missing or remote images are shown as placeholders instead of being fetched from the internet.

## Install

Markdown Printer requires macOS 14 Sonoma or newer.

1. [Download Markdown Printer](https://github.com/pedstrom/md-printer/releases/latest/download/Markdown-Printer.zip).
2. Unzip it and move **Markdown Printer** to your Applications folder.
3. Open the app, then drop Markdown files onto it or use Finder's **Open With** command.

The release is signed with a Developer ID certificate and notarized by Apple, so it opens through the normal macOS security flow.

## About this project

I vibe coded Markdown Printer in an afternoon because I wanted the growing pile of AI-generated Markdown on my Mac to look good on paper. If it is helpful to you, awesome. If not, feel free to move on.

— Peter Edstrom

Want to inspect or build it yourself? The developer commands and project structure live in the [development guide](development/README.md).

## Support

> ☕ **Found this project useful?** You can [buy me a coffee](https://buymeacoffee.com/peteedstrom) to support more small, practical, independent tools.

## License

Markdown Printer is available under the [MIT License](LICENSE).
