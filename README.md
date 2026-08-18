<p align="center">
  <img src="Resources/MarkdownPrinterIcon.png" width="144" alt="Markdown Printer app icon">
</p>

<h1 align="center">Markdown Printer</h1>

<p align="center">Turn Markdown files into clean, printable PDFs on your Mac.</p>

<p align="center">
  <a href="https://github.com/pedstrom/md-printer/releases/latest/download/Markdown-Printer.zip"><strong>Download Markdown Printer 1.4.1</strong></a>
</p>

Markdown is suddenly everywhere. AI tools, coding assistants, note apps, and research workflows are producing copious `.md` files, but those files are not always pleasant to print, share, or read away from an editor. Markdown Printer gives them a polished page without sending the document anywhere.

Drop one file—or a whole batch—onto the app. Each document opens in its own window as a finished PDF that you can save, print, or drag directly into Finder, Microsoft Teams, Messages, and other apps. When coworkers need something editable, save or drag a Microsoft Word version instead.

## What it does

- Formats headings, paragraphs, bold, italics, underlining, strikethrough, links, footnotes, lists, quotations, tables, and local images
- Previews Markdown directly in Finder with a continuous, screen-optimized Quick Look view: select a file and press Space or Command-Y
- Uses Avenir Next for the document and a proper monospaced font for code
- Produces searchable, US Letter PDFs with page numbers
- Exports editable Microsoft Word documents with formatting, links, tables, and local images
- Opens multiple Markdown files at once, each in its own window
- Refreshes open documents automatically when their Markdown files change while preserving the window, zoom, and reading position
- Finds text in the rendered PDF with the standard Command-F, Command-G, and Shift-Command-G shortcuts
- Checks GitHub for signed stable updates and installs them only after you approve
- Lets you hold and drag the preferred PDF or Word export directly to the Desktop or another app
- Keeps your files entirely on your Mac: no account, upload, analytics, or remote rendering

The PDF in the app preview is the same print-ready, paginated PDF that gets saved or printed. Finder Quick Look is intentionally different: it reuses the native Markdown renderer before PDF pagination to provide a continuous, screen-optimized reading view with selectable text and adaptive light/dark colors. PDF remains the default export, while **Markdown Printer > Settings** can make Microsoft Word the default for both Save and dragging; the Save dialog can also switch formats for one export. Saved and dragged files keep the original Markdown filename with the appropriate `.pdf` or `.docx` extension. A dragged file is prepared locally only when the drag begins, so apps that accept normal Mac file attachments receive a concrete file with the correct name. Local images are resolved relative to the Markdown file; missing or remote images are shown as placeholders instead of being fetched from the internet. Because macOS gives the Quick Look sandbox access to the selected Markdown file but may withhold access to neighboring files, a relative local image can also appear as a readable placeholder in Finder even when it renders in the full app.

## Install

Markdown Printer requires macOS 14 Sonoma or newer.

1. [Download Markdown Printer](https://github.com/pedstrom/md-printer/releases/latest/download/Markdown-Printer.zip).
2. Unzip it and move **Markdown Printer** to your Applications folder.
3. Open the app, then drop Markdown files onto it or use Finder's **Open With** command.

The Finder Quick Look extension is bundled inside the app, so removing Markdown Printer also removes its Quick Look capability. To use it, select a Markdown file in Finder and press Space or Command-Y. If macOS has disabled the extension, open **System Settings → General → Login Items & Extensions → Quick Look ⓘ** and turn on Markdown Printer. The app's Settings window includes that written path and an **Open System Settings…** button.

Markdown Printer advertises itself as a viewer for Markdown without silently changing an existing default. If you want Markdown files to open in it when double-clicked, use **Make Markdown Printer Default** in the app's Settings. macOS may ask for consent and records the choice by Markdown content type rather than by filename extension; Markdown Printer makes one request for its declared Markdown type, which covers `.md`, `.markdown`, `.mdown`, and `.mkd`.

The release is signed with a Developer ID certificate and notarized by Apple, so it opens through the normal macOS security flow.

Version 1.3.0 is the first release that includes the updater. If you have an older version, install 1.3.0 manually once; future stable releases can be installed with **Markdown Printer > Check for Updates…**.

## Privacy and update checks

Document rendering remains entirely local. The Quick Look extension is sandboxed, has no network entitlement, and never fetches remote images. By default, the full Markdown Printer app makes an ordinary HTTPS request to GitHub at most once per day to see whether a signed stable release is newer. It does not send system-profile information, analytics, or document content. Automatic checks can be disabled in **Markdown Printer > Settings**, and an update is downloaded only after you choose **Install Update**.

## About this project

I vibe coded Markdown Printer in an afternoon because I wanted the growing pile of AI-generated Markdown on my Mac to look good on paper. If it is helpful to you, awesome. If not, feel free to move on.

— Peter Edstrom

Want to inspect or build it yourself? The developer commands and project structure live in the [development guide](development/README.md).

## Support

> ☕ **Found this project useful?** You can [buy me a coffee](https://buymeacoffee.com/peteedstrom) to support more small, practical, independent tools.

## License

Markdown Printer is available under the [MIT License](LICENSE).
