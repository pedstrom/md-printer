# Markdown Printer for iPhone and iPad Support

Markdown Printer opens local Markdown files and turns them into polished, searchable PDFs without uploading the source document.

## Getting started

1. Open Markdown Printer and choose a `.md`, `.markdown`, `.mdown`, or `.mkd` file from Files.
2. Use the **Find** field at the bottom to search the open document. The keyboard and result controls appear only after you tap the field.
3. Use the share icon beside the filename to send, save, or print the generated PDF from the system share sheet.

The filename in the top bar identifies the open document. Manage the source Markdown file in Files. About, privacy, and support remain available from the information button in the document browser.

If iCloud or another file provider needs time to download a selected document, the opening screen keeps a **Back** button available immediately. Going back returns to the document browser and cancels Markdown Printer's pending read; it does not remove or change the source file.

Markdown Printer opens the selected Markdown as a read-only viewer and does not ask other apps to save it before reading. Opening, viewing, searching, and generating a PDF do not write the source file. iCloud and other File Providers may still update download, synchronization, last-used, or access metadata while making a cloud-only file available, and an imported copy has its own creation metadata.

## iPad windows and keyboard

The iPad app supports portrait (including upside-down), landscape, and resizable windows on iPadOS 26 or newer. Reading layout follows the available window space, including while another app shares the display. Tables and code can scroll horizontally within the document.

Each window keeps its own document, linked-document history, search, reading position, and PDF actions. Choose **New Window** from the menu bar to browse another document. Markdown shared from another app or dropped from Files opens separately when the receiving window already contains a document; an existing matching document window is activated when available. An empty browser window opens the selected file directly. Files with the same filename in different folders remain separate documents.

Tap a local Markdown link to navigate in the same window. Touch and hold its text and choose **Open in New Window** to open it separately. **Back** returns through linked documents; the root **Back** action returns that window to Files. Close Window closes only that window.

| Command | Shortcut |
| --- | --- |
| New Window | Command-N |
| Open | Command-O |
| Find | Command-F |
| Next / previous result | Command-G / Shift-Command-G |
| Finish finding | Escape |
| Share PDF | Shift-Command-S |
| Print PDF | Command-P |
| Close Window | Command-W |

PDF sharing uses an anchored system popover on iPad. **Save to Files**, sharing, and printing all use the same locally generated PDF. Window size and reading text size do not change the PDF’s US Letter page layout.

Open windows restore their document references and reading state locally. Restoration does not save document contents or reopen a window that you closed. If a referenced file moved, was removed, or needs permission, use **Retry**, **Allow Folder Access**, or **Browse** to recover. An unavailable file does not prevent other windows from working.

On iPhone, incoming shared Markdown continues to replace the current document immediately.

## iCloud status

The document browser immediately shows files that iOS already has available, then checks iCloud without blocking browsing. The compact message above the browser means:

- **Checking iCloud…** — a check began at launch, after Retry, or after returning to the browser when its last successful check is more than five minutes old.
- **Checked for updates at [time]** — iCloud's metadata service responded at that time. This intentionally says “Checked,” not “Synced” or “Up to date.”
- **iCloud is taking longer than usual — showing available files** — the check has taken more than eight seconds; the current file list remains usable.
- **Offline — showing available files** — iOS reports that the network is unavailable. A new check begins when connectivity returns.
- **Couldn’t check iCloud — showing available files** — the check could not start or did not respond within 30 seconds. Tap **Retry** to try again.
- **iCloud Drive unavailable** — iOS reports no available iCloud Drive Documents account. The app checks again when the account or app state changes.

Apple's per-file cloud badges and download progress remain the source of truth for individual documents. iOS does not provide document-browser apps with one authoritative count of every item still pending across iCloud and other file providers, so Markdown Printer does not display a potentially misleading pending count.

When a Markdown link points to another local file, the app may ask once for access to the containing folder. The permission is stored only on the device and can be removed by deleting the app.

Secure remote images referenced by an open document load automatically. If an image is unavailable, its readable placeholder remains and can be tapped to retry. Downloaded images stay in Markdown Printer's disposable app cache; the app never writes them beside the Markdown file. iOS may remove cached copies when it needs space.

## Get help

Email [pete@edstrom.net](mailto:pete@edstrom.net), search existing reports, or [open a support issue](https://github.com/pedstrom/md-printer/issues). Include the iOS version, app version, file extension, and the steps that led to the problem. Do not attach a private document unless you intend to make it public.

See the [privacy policy](privacy-policy.md) for the app's data practices.
