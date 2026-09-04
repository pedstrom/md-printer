# Markdown Printer for iPhone Support

Markdown Printer opens local Markdown files and turns them into polished, searchable PDFs without uploading the source document.

## Getting started

1. Open Markdown Printer and choose a `.md`, `.markdown`, `.mdown`, or `.mkd` file from Files.
2. If you do not have a document handy, tap **Sample** in the document browser.
3. Use **Find** in the bottom toolbar to search the open document.
4. Use **Share PDF** to send, save, or print the generated PDF from the system share sheet.

The filename in the top bar identifies the open document. Manage the source Markdown file in Files. About, privacy, and support remain available from the information button in the document browser.

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

Remote images are intentionally not downloaded. Keep image files beside the Markdown document, or in a linked local folder the app can access.

## Get help

Search existing reports or [open a support issue](https://github.com/pedstrom/md-printer/issues). Include the iOS version, app version, file extension, and the steps that led to the problem. Do not attach a private document unless you intend to make it public.

See the [privacy policy](privacy-policy.md) for the app's data practices.
