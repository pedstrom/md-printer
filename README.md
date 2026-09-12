<p align="center">
  <img src="Resources/MarkdownPrinterIcon.png" width="144" alt="Markdown Printer app icon">
</p>

<h1 align="center">Markdown Printer</h1>

<p align="center">Turn Markdown files into clean, printable PDFs on your Mac.</p>

<p align="center">
  <a href="https://github.com/pedstrom/md-printer/releases/latest/download/Markdown-Printer.zip"><strong>Download Markdown Printer 1.4.4</strong></a>
</p>

Markdown is suddenly everywhere. AI tools, coding assistants, note apps, and research workflows are producing copious `.md` files, but those files are not always pleasant to print, share, or read away from an editor. Markdown Printer gives them a polished page without sending the document anywhere.

Drop one file—or a whole batch—onto the app. Each document opens in its own window as a finished PDF that you can save, print, or drag directly into Finder, Microsoft Teams, Messages, and other apps. When coworkers need something editable, save or drag a Microsoft Word version instead.

## What it does

- Formats ATX and Setext headings, paragraphs, bold, italics, underlining, strikethrough, inline and reference links, core autolinks, footnotes, lists, quotations, tables, fenced and indented code, entity references, and inline or reference images
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

The PDF in the app preview is the same print-ready, paginated PDF that gets saved or printed. Finder Quick Look is intentionally different: it reuses the native Markdown renderer before PDF pagination to provide a continuous, screen-optimized reading view with selectable text and adaptive light/dark colors. PDF remains the default export, while **Markdown Printer > Settings** can make Microsoft Word the default for both Save and dragging; the Save dialog can also switch formats for one export. Saved and dragged files keep the original Markdown filename with the appropriate `.pdf` or `.docx` extension. A dragged file is prepared locally only when the drag begins, so apps that accept normal Mac file attachments receive a concrete file with the correct name. Local images are resolved relative to the Markdown file. On Mac, a remote image begins as a readable placeholder; click it to download that image, or use its context menu to download every remote image in the document. On iPhone, secure remote images are fetched automatically when their document opens. Downloads are kept in the app's disposable cache and are never written beside the Markdown file. Finder Quick Look stays offline. Because macOS gives the Quick Look sandbox access to the selected Markdown file but may withhold access to neighboring files, a relative local image can also appear as a readable placeholder in Finder even when it renders in the full app.

Markdown Printer implements selected CommonMark 0.31.2 syntax rather than claiming complete CommonMark conformance. Its compatibility suite currently matches 641 of the specification's 652 normative examples (98.3%), including every example for headings, emphasis, code spans and blocks, references, autolinks, entities, raw HTML, images, and line breaks. The remaining gaps are uncommon block-quote and deeply nested-list edge cases plus one unusual link-label case. Arbitrary raw HTML is displayed as literal, code-styled source and is never executed. A standalone `<img>` tag is the narrow exception: it uses the same local or user-initiated remote-image pipeline as Markdown image syntax. The app's established `<u>` underline and `<br>` line-break extensions remain available.

## Install

Markdown Printer requires macOS 14 Sonoma or newer.

1. [Download Markdown Printer](https://github.com/pedstrom/md-printer/releases/latest/download/Markdown-Printer.zip).
2. Unzip it and move **Markdown Printer** to your Applications folder.
3. Open the app, then drop Markdown files onto it or use Finder's **Open With** command.

The Finder Quick Look extension is bundled inside the app, so removing Markdown Printer also removes its Quick Look capability. To use it, select a Markdown file in Finder and press Space or Command-Y. If macOS has disabled the extension, open **System Settings → General → Login Items & Extensions → Quick Look ⓘ** and turn on Markdown Printer. The app's Settings window includes that written path and an **Open System Settings…** button.

Markdown Printer advertises itself as a viewer for Markdown without silently changing an existing default. If you want Markdown files to open in it when double-clicked, use **Make Markdown Printer Default** in the app's Settings. macOS may ask for consent and records the choice by Markdown content type rather than by filename extension; Markdown Printer makes one request for its declared Markdown type, which covers `.md`, `.markdown`, `.mdown`, and `.mkd`.

The release is signed with a Developer ID certificate and notarized by Apple, so it opens through the normal macOS security flow.

### iPhone app

The repository also contains an iPhone-only iOS 26 viewer in [`iOS/MarkdownPrinterIOS.xcodeproj`](iOS/MarkdownPrinterIOS.xcodeproj). It uses Apple’s native document browser for Recents, Shared, and Browse, with a compact status strip that checks iCloud metadata without hiding files already available on the device. Apple’s per-file cloud indicators remain authoritative; the app does not invent a provider-wide pending count that iOS cannot reliably supply. The viewer renders Markdown as a continuous, selectable SwiftUI document with adaptive colors, Dynamic Type, images, horizontally scrollable code and tables, search, linked-document navigation, and Preview-style toolbar hiding. Its bottom Find field is ready without an extra mode button, while the icon beside the filename opens the system share sheet to send, save, or print the one locally generated portrait US Letter PDF. If a file provider restricts sibling access, choose the containing folder once; Markdown Printer remembers that grant across launches so linked Markdown and local resources inside the authorized folder open directly until access is revoked in Settings. Secure remote images load automatically into the disposable app cache, with readable placeholders retained when an image is unavailable.

The iPhone app is currently a build-from-source target rather than an App Store release. Open the Xcode project, select the **MarkdownPrinterIOS** target, choose a paid Apple Developer team under **Signing & Capabilities**, connect an iPhone running iOS 26 or newer, and Run. A free Personal Team profile expires after seven days. The paid-team device helper refuses such a profile and reports the actual provisioning lifetime before optionally installing:

```sh
scripts/build-and-run/build_ios_device.sh --install
```

The paid team is read from the Mac’s Apple Development certificate (or `MARKDOWN_PRINTER_IOS_TEAM_ID`) and is not stored in the repository.

Version 1.3.0 is the first release that includes the updater. If you have an older version, install 1.3.0 manually once; future stable releases can be installed with **Markdown Printer > Check for Updates…**.

## Privacy and update checks

Document rendering remains local and Markdown Printer never uploads document contents. The Mac app makes a secure image request only when you choose to download a remote image; the iPhone app makes secure requests automatically for remote images referenced by the document you open. Results are stored in the app's disposable cache, not beside the document. The Quick Look extension is sandboxed, has no network entitlement, and never fetches remote images. By default, the full Mac app also makes an ordinary HTTPS request to GitHub at most once per day to see whether a signed stable release is newer. It does not send system-profile information, analytics, or document content. Automatic checks can be disabled in **Markdown Printer > Settings**, and an update is downloaded only after you choose **Install Update**.

## About this project

I vibe coded Markdown Printer in an afternoon because I wanted the growing pile of AI-generated Markdown on my Mac to look good on paper. If it is helpful to you, awesome. If not, feel free to move on.

— Peter Edstrom

Want to inspect or build it yourself? The developer commands and project structure live in the [development guide](development/README.md).

## Support

> ☕ **Found this project useful?** You can [buy me a coffee](https://buymeacoffee.com/peteedstrom) to support more small, practical, independent tools.

## License

Markdown Printer is available under the [MIT License](LICENSE).
