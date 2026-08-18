# Finder Quick Look Product Contract

Markdown Printer includes one full-size Finder Quick Look preview provider. It also bundles a static Markdown document icon for Finder when Markdown Printer owns the file association, but does not provide content-derived icon thumbnails.

## Rendering

- Finder Quick Look is a continuous, screen-optimized native TextKit view. It reuses `MarkdownPrinterCore` after parsing and before PDF pagination.
- The full app remains unchanged: its PDF bytes are the single source of truth for app preview, save, and print.
- Quick Look uses Avenir Next at 13 points for body copy, proportionally enlarged headings, a centered reading column no wider than 680 points, native monospaced code, and adaptive system colors.
- Text is vertically scrollable, selectable, and copyable. Supported Markdown formatting, links, and bidirectional footnote navigation remain interactive.
- The extension reads and parses asynchronously, does not monitor or retain the source file, does not generate a PDF, and does not launch the host app as part of preview generation.

## Local-first and sandbox behavior

- The extension uses Apple's App Sandbox with read-only user-selected-file access and no network entitlement.
- Remote images are never fetched. Local images are attempted through the shared renderer. When Quick Look cannot access a sibling image, the readable existing image placeholder is the expected result.
- User-facing preview errors are concise and never contain document content or private file paths.

## Installation, updates, and removal

- The provider is always embedded at `Markdown Printer.app/Contents/PlugIns/MarkdownPrinterQuickLook.appex` with bundle ID `com.peteedstrom.markdown-printer.quicklook` and executable name `MarkdownPrinterQuickLook`.
- Host and extension display versions and build numbers always match. The extension is universal, signed before the host, and validated as nested code in development and release bundles.
- Stable identity and path allow Launch Services to treat an in-place Sparkle replacement as an update of the same provider. Production code does not invoke `pluginkit`, reset Quick Look, or use deprecated or private registration APIs.
- macOS controls extension activation. Settings provides Space and Command-Y usage instructions, the durable System Settings path, a normal **Open System Settings…** button, and no guidance about competing preview providers.
- Removing the host app removes its embedded provider.

## Markdown file defaults

- Quick Look activation and the default application for opening Markdown are independent choices.
- Markdown Printer declares the honest `Viewer` role with `Default` handler rank, but never silently replaces the user's default application.
- Settings offers an explicit **Make Markdown Printer Default** action using `NSWorkspace.setDefaultApplication`. It makes one consent request for the app's declared `net.daringfireball.markdown` content type, whose declaration covers `.md`, `.markdown`, `.mdown`, and `.mkd`, never requests generic plain text, and reports success only after `NSWorkspace.urlForApplication(toOpen:)` verifies that type.
- The declared Markdown document type names the bundled `MarkdownDocumentIcon.icns`, so Finder can use the approved document-and-mountains artwork after the association changes while the app icon remains unchanged.
