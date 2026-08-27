# Product Development Log

## 2026-08-27 — Preview-style Markdown viewer for iPhone

- Replaced per-file linked-document authorization with a one-time containing-folder grant. The app keeps the folder's security scope active, persists its bookmark across launches, and then opens linked Markdown and local resources anywhere inside that user-authorized folder without another picker.
- Added edge-swipe Back navigation for linked Markdown documents: swipe left from the right edge as requested, or use the standard inward swipe from the left edge, while preserving horizontal table and code scrolling in the document body.
- Fixed **Share PDF → Print** by giving the system Print activity the cached PDF bytes while other share destinations retain the named temporary file, avoiding iOS's erroneous protected-PDF failure.
- Added a separate iPhone-only iOS 26 Xcode project with Apple’s native document browser, Viewer registration for `.md`, `.markdown`, `.mdown`, and `.mkd`, automatic signing without a tracked team ID, and reusable app artwork.
- Added continuous native SwiftUI rendering for headings, inline formatting, lists and task states, quotations, footnotes, horizontal rules, raw HTML, local images and readable placeholders, horizontally scrollable code and aligned tables, Dynamic Type, adaptive appearances, selectable text, linked-document navigation, and exact-phrase search with case and whole-word options.
- Added coordinated security-scoped document sessions, provider-aware Rename/Move/Duplicate availability, original-Markdown sharing, Info metadata, source refresh, Preview-style toolbar hiding, and one revision-cached PDF result shared by Share PDF, Export, and AirPrint.
- Added a dedicated mobile TextKit/Core Graphics exporter for searchable, linked, page-numbered portrait US Letter output with fixed 54-point margins, Avenir Next prose, monospaced code, local images, placeholders, footnotes, tables, and multi-page flow without changing macOS output.
- Added iOS unit, structural PDF, and UI coverage plus a simulator gate enforcing at least 95% testable mobile-support line coverage, real-device paid-team signature/profile validation that rejects seven-day Personal Team builds, and local-device installation support.

## 2026-08-27 — Version 1.4.3

- Promoted the native tabs, thumbnail and sharing controls, workspace reopening, Page Setup and footer parity, Preview-style viewing commands, broader CommonMark compatibility, performance work, bundled Help, dark-mode refinements, and restored Command-W behavior together as version 1.4.3, build 12.
- Framed the release around a more consistent, polished Mac experience across windows, menus, previewing, output, and session continuity.

## 2026-08-27 — Restored native Command-W closing

- Reconnected the File → Close command to the focused native window so Command-W closes the selected document tab when tabbed and closes standalone document, welcome, and Help windows otherwise.
- Kept one standard Close item immediately after the session-reopening command and disabled it when no closable window is focused.

## 2026-08-27 — Bundled offline Help

- Added a reusable native Help window with selectable, accessible, locally bundled guidance for opening, exporting, navigating, searching, thumbnails, tabs, restoration, page setup, printing, Finder, Quick Look, local images, and privacy.
- Added Help → Markdown Printer Help and Help → Keyboard Shortcuts, with both commands reusing the same resizable window and routing directly to the requested section.
- Documented app-specific keyboard shortcuts, including both Space/Shift-Space and Option-arrow page navigation.

## 2026-08-27 — Consistent dark-mode canvas surfaces

- Made the welcome and preparing views expand with resized windows while preserving their existing minimum size, and left their background transparent so the native window surface remains continuous in dark mode.
- Removed the custom PDF background override so PDFKit uses its standard neutral under-page canvas instead of tinting the document surround like an ordinary window.
- Added native layout, transparency, and PDF-view regression tests for the dark-mode surface corrections.

## 2026-08-27 — Immediate Page Setup inheritance reset

- Added an official native Page Setup accessory for documents with explicit layout overrides, without changing the default Page Setup sheet in Settings.
- Made Use Default Page Setup dismiss the sheet immediately, discard unconfirmed controls, regenerate from the current app default, and restore inheritance for later default changes.
- Kept the explicit override and last valid preview intact when regeneration fails, with the existing document error presentation handling the failure.

## 2026-08-27 — State-aware PDF viewing commands

- Separated page and zoom commands from PDF search into a focused per-window viewing controller backed by PDFKit's live capabilities.
- Made Zoom In, Zoom Out, Previous Page, and Next Page disable at their actual boundaries while retaining Actual Size, Zoom to Fit, Option-arrow, Space/Shift-Space, and Command zoom shortcuts.
- Kept viewing state synchronized across page and scale changes, buffered live-preview swaps, restored viewports, and SwiftUI attachment and teardown boundaries.

## 2026-08-27 — Broader CommonMark compatibility and performance guardrails

- Expanded the parser from the seven previously missing feature families into the high-frequency CommonMark interactions around delimiter runs, exact code-span fences, hard and soft breaks, ATX closing sequences, tabs, lazy block-quote continuation, nested lists, list marker identity, tight and loose lists, and inline-link precedence.
- Pinned all 652 normative CommonMark 0.31.2 examples in the test target with a shared normalized serializer and raised the non-regression floor to 620 examples; the current implementation matches 641 examples (98.3%), with the remaining gaps isolated to unusual block-quote, link-label, list-item, and deeply nested-list cases.
- Parsed each opened document once and reused its block tree for the app, PDF/Word export, and Finder Quick Look instead of reparsing independently for each rendering surface.
- Moved parsing and attributed rendering off the main actor for document-window preparation, kept AppKit TextKit pagination on its required actor, and divided pagination and drawing into cancellation-aware yielding units so large documents do not freeze interaction.
- Replaced repeated whole-document Word XML scans and mutations with indexed token lookup and reverse-ordered batch replacement, removing the dominant large-document export bottleneck.
- Added a deterministic release benchmark and verification gate for 100 KB and 1 MB feature-heavy documents, covering absolute parser/render/export latency, main-actor stalls, peak resident memory, and bounded 10× scaling. The gate keeps 100 KB PDF and Word preparation below one and 1.5 seconds respectively, 1 MB output below six and eight seconds, and sampled main-actor stalls below 150 ms at the stress size.

## 2026-08-26 — Export-backed Save As command

- Removed the read-only Markdown source document's generated **Save** command and replaced the generated **Save As…** behavior with the same PDF/Microsoft Word export flow used by the toolbar Save button.
- Kept Command-S on the toolbar export action, added the standard Shift-Command-S shortcut to **File → Save As…**, and covered preferred-format suggestions, one-save format overrides, cancellation, write errors, updater activity deferral, and regenerated File-menu cleanup.

## 2026-08-26 — Preview-style menus, zoom, and page navigation

- Replaced the generated source-document Share submenu with the focused **Share PDF… / Share Microsoft Word…** command, placed **Show in Finder** with the native import/export group, and kept Page Setup and Print in the standard print group.
- Made **Reopen Windows from Last Session** reinstall itself whenever SwiftUI rebuilds the File menu, while remaining visibly disabled when the stored workspace has nothing additional to open.
- Reduced the read-only Edit menu to relevant selection and Find actions, removing unavailable editing, writing, autofill, dictation, and character-entry commands.
- Removed the custom Window-menu tab-bar command so macOS supplies one standard **View → Show/Hide Tab Bar** item instead of duplicate Window entries.
- Added Preview-style **Actual Size** (Command-0), **Zoom to Fit** (Command-9), **Zoom In/Out** (Command-Plus/Minus), and **Previous/Next Page** (Option-Up/Down) commands under View.
- Kept Space and Shift-Space as secondary next/previous-page shortcuts while displaying the canonical Option-arrow equivalents in the menu, and added focused controller, PDFKit key-event, and menu-rebuilding coverage.

## 2026-08-26 — Native page setup, printing, and footer parity

- Added focused **File → Page Setup…** and **File → Print…** commands backed by the native macOS sheets, with the toolbar Print button using the same generated-PDF-at-100-percent path.
- Added persisted Letter/portrait/100% defaults with fixed 0.75-inch print-safe margins, transactional per-document overrides, immediate preview regeneration, inherited-default propagation, and workspace restoration of explicit setups.
- Reorganized Settings into General and Page tabs, with a native default Page Setup sheet plus independently configurable left and right footer menus for blank, source date, source date and time, document title, filename, or normalized custom text.
- Added searchable, non-overlapping Avenir Next PDF footer columns around the existing centered page number, including ellipsis truncation, and editable Word three-column footers with a native PAGE field.
- Made PDF, save, drag, share, print, and Word output share paper, orientation, scale, fixed margins, and source metadata; Word section XML now matches the PDF page while retaining editable body content and scaled typography.
- Prevented the production Sparkle bridge from starting update or UI work inside an XCTest host, so verification cannot surface misleading “xctest” updater alerts.
- Added focused validation for page-model persistence and fallback, source modification timestamps, inherited and explicit setup behavior, print fidelity, localized footer resolution, PDF footer positioning and truncation, Word relationships/content types/footer fields/section properties, and workspace round trips.

## 2026-08-26 — Manual full-workspace reopening

- Added **File → Reopen Windows from Last Session** immediately after Open Recent, disabled when every saved document is already open, while keeping normal launches on the welcome window and preserving the last snapshot until the next normal termination.
- Added a versioned, local-only workspace schema that restores document windows, frames, tab groups, tab order, selected tabs, mixed welcome tabs, PDF zoom/page/scroll position, thumbnail visibility/width/scroll position, and tab-bar visibility without storing Markdown or generated PDF content.
- Moved automatic updater relaunches onto the same consume-once workspace payload while retaining compatibility with legacy path-only and per-window update records, and kept update-triggered termination from replacing the normal last-session snapshot.
- Added skip-and-continue restoration for already-open, missing, unreadable, or failed documents with one concise error summary after the remaining workspace opens.
- Added deterministic coverage for version validation, manual snapshot lifetime, updater compatibility, menu placement and enablement, tab topology, welcome-tab rules, selection, sidebar state, duplicate avoidance, and partial-failure restoration.

## 2026-08-26 — Native thumbnails, sharing, and Finder actions

- Added an off-by-default, resizable PDFKit thumbnail sidebar with a leading title-bar toggle and a focused **View → Show/Hide Thumbnails** command; thumbnails scale with the 120–260 point sidebar, the divider has a generous invisible drag target, dragging fully left collapses it, the divider disappears completely when closed, and the persistent sidebar follows page selection and rebinds across buffered PDF refreshes without replacing the visible preview.
- Added **File → Show in Finder** for source-backed documents and removed only macOS's generated **Duplicate** item while preserving the rest of the standard File menu.
- Added a standard Share toolbar item and dynamic **File → Share PDF… / Share Microsoft Word…** command that anchors the picker to the toolbar control, shares the selected export format as an exact, private temporary file, and participates in updater activity deferral until the picker completes or is cancelled.
- Added deterministic coverage for sidebar visibility, sizing, rebinding, Finder routing, share bytes, filenames, cleanup, cancellation, activity deferral, errors, and targeted File-menu filtering.

## 2026-08-26 — Entirely missing CommonMark families

- Added two-phase block and inline parsing for Setext headings, indented code blocks, forward and backward reference links and images with titles, core angle-bracket autolinks, HTML5 named and numeric entities, and all seven CommonMark HTML-block forms plus inline raw HTML.
- Kept raw HTML entirely inert and offline by rendering inline forms like inline code and block forms like fenced code; raw links and images never become annotations, attachments, interpreted markup, or network requests, while the existing `<u>` and `<br>` extensions retain precedence.
- Generated a compiled production entity lookup from the authoritative WHATWG HTML5 snapshot with its checksum, without adding a runtime resource, network lookup, or package dependency.
- Pinned all 166 normative CommonMark 0.31.2 examples from the seven added sections in the test target with source, version, checksum, and license attribution, and validated them through a normalized test-only AST-to-HTML serializer.
- Added focused parser, document-title, renderer, PDF annotation/searchability, editable Word link/image/style, local-only image, and Finder Quick Look parity regressions, and expanded the showcase and public support wording without claiming complete CommonMark conformance.

## 2026-08-26 — Native window tabs

- Added direct **File → New Window** and **File → New Tab** commands with Command-N and Command-T, removing the generated New submenu and its misleading New Document option while preserving Open and Open Recent.
- Made both Command-T and the tab bar's plus button create a new tab that uses the existing blank welcome view until a Markdown file is chosen.
- Added the standard **Window → Show/Hide Tab Bar** command with Shift-Command-T, keeping the command disabled when multiple tabs make the tab bar mandatory.
- Converted the welcome scene to independent window instances and explicitly grouped new home tabs with the active welcome or document window, while closing only the chosen home tab after its file opens.
- Added deterministic AppKit coverage for tab grouping, concurrent tab requests, tab-bar visibility, key-window changes, and standalone fallback behavior.

## 2026-08-26 — Version 1.4.2

- Promoted the native File-menu bug fix, update-relaunch window restoration, Fit Page command, drag-readiness feedback, and larger welcome artwork together as version 1.4.2, build 11.
- Updated the public download label, release notes, host and extension metadata, and release verification assertions for the signed, notarized polish update.

## 2026-08-25 — Larger welcome artwork

- Doubled the welcome screen's document artwork from 64×70 to 128×140 points so it reads as a deliberate focal element in the empty window.
- Kept the Finder document icon, app icon, preview drag thumbnail, and underlying artwork asset unchanged.
- Added deterministic coverage for the welcome-only display dimensions.

## 2026-08-25 — Visible hold-to-drag readiness

- Made the preview thumbnail appear as soon as the PDF or Word hold gesture becomes ready, before the pointer starts moving.
- Kept file materialization deferred until actual dragging begins, and removed the readiness thumbnail on release or cancellation.
- Added deterministic native-view coverage for configured and unavailable export payloads.

## 2026-08-24 — Current-page Fit Page command

- Added **View → Fit Page** with Command-0, fitting the complete current PDF page inside the document window while retaining continuous vertical scrolling.
- Kept the command scoped to the focused document window and disabled it when no PDF is available.
- Added deterministic coverage for command routing, current-page retention, and complete viewport containment.

## 2026-08-19 — Update relaunch window restoration

- Extended the existing successful-update relaunch path to preserve each open document window's size, screen position, PDF zoom, page, and normalized scroll location immediately before Sparkle installs the update.
- Restored window geometry through the same document-window lifecycle used by normal opens, clamping saved frames to the currently available screens before restoring the PDF viewport after native layout settles.
- Kept persisted viewport state local, numeric, build-specific, and single-use; no Markdown text or PDF text anchors are written to preferences, and older path-only relaunch records remain compatible.
- Added focused round-trip coverage for multipage scrolling, zoom, window geometry, invalid stored state, legacy records, and changed screen arrangements.

## 2026-08-19 — Native File Open command

- Restored SwiftUI's native **File → Open…** command with Command-O plus **Open Recent** and **Clear Menu** by removing the welcome scene's empty new-item command override.
- Kept all three commands on the existing `DocumentGroup` path so system-maintained recents, Finder events, drag-and-drop, Markdown links, and the welcome chooser continue to open the same document windows.

## 2026-08-18 — Version 1.4.1

- Promoted the crash-free PDF search attachment and document-window teardown fix as version 1.4.1, build 10.
- Updated the public download label, release notes, host and extension metadata, and release verification assertions for the signed, notarized bug-fix update.

## 2026-08-18 — Crash-free document-window teardown

- Prevented PDF search-state publication from re-entering SwiftUI while a document window's native PDF preview is being attached or dismantled, eliminating an exclusivity abort seen when closing or quitting with a document open and the corresponding undefined-behavior warning during window creation.
- Kept search-target disconnection and highlight cleanup immediate, deferred observable attachment and command-state resets past SwiftUI's representable update boundary, and added focused lifecycle coverage for both publication boundaries.

## 2026-08-18 — Version 1.4.0

- Promoted bundled continuous Finder Quick Look, the opt-in default-Markdown-app action, Finder document artwork, and the consolidated Settings controls together as version 1.4.0, build 9.
- Updated the public download label, release notes, host and extension metadata, and release verification assertions for the signed, notarized update.

## 2026-08-18 — Manual update check in Settings

- Added a **Check for Updates…** button beside the automatic-update-check preference, reusing the same Sparkle availability state and manual-check action as the application menu.

## 2026-08-18 — Bundled continuous Finder Quick Look

- Added a sandboxed, network-free Finder Quick Look preview extension inside the app bundle, backed by a testable SwiftPM support library and the existing native Markdown parser and attributed-text renderer before PDF pagination.
- Added continuous, selectable, screen-optimized Avenir Next rendering with adaptive colors, a responsive 680-point reading column, full Markdown structure, links, bidirectional footnote navigation, offline image behavior, and path-free error presentation while leaving the full app's PDF preview, save, print, and export bytes unchanged.
- Added a Finder Quick Look Settings section with Space and Command-Y instructions, app-removal behavior, the durable activation path, a normal System Settings button, and an opt-in, verified default-Markdown-app request using public `NSWorkspace` APIs.
- Added a dedicated transparent Markdown document icon, reused it on the app's open screen, and bundled multi-resolution `.icns` registration so Finder can display the same document-and-mountains artwork when Markdown Printer becomes the default, without changing the app icon.
- Stabilized the provider identity, path, executable, content-type declarations, matching host version/build metadata, universal architecture, read-only sandbox entitlements, nested signing order, hardened release validation, and notarized ZIP checks so in-place updates replace the same provider.
- Added focused rendering, loader, resizing, selection, footnote, invalid-input, Settings-copy, System Settings navigation, default-handler state/error, and bundle-contract tests plus native Quick Look and update-path QA instructions.
- Verified the real Finder provider with both Space and Command-Y, continuous scrolling, full-screen resizing, selection/copying, links, bidirectional footnotes, tables, code, offline placeholders, and light/dark appearance; confirmed the Settings controls and macOS's enabled provider state, with screenshots kept outside the repository.
- Consolidated the opt-in default-app action to one request for Markdown Printer's declared Markdown content type, which covers all four supported extensions and avoids repeated macOS consent prompts.
- Exercised Sparkle's actual download, replacement, and relaunch flow with disposable Developer ID- and EdDSA-signed QA builds: build 800 had no provider, build 801 introduced it, and build 802 replaced it at the same path and identity while System Settings retained the enabled state. Removing the disposable host removed its provider registration, and no QA files or registration remained.

## 2026-08-18 — Reliable release linkage validation

- Made the ZIP-metadata and Sparkle runtime-linkage gates inspect captured command output, preventing `pipefail` from mistaking an early successful `grep` match for a missing runtime search path when the producer receives `SIGPIPE`.

## 2026-08-18 — Historical release-notes backfill

- Added durable Markdown release notes for every previously published version from 1.0 through 1.2.0, reconstructed from the matching GitHub Release descriptions and repository tag history.
- Preserved the historical distribution boundary: versions 1.0 through 1.0.2 were ad-hoc signed, while Developer ID signing and Apple notarization began with 1.0.3.

## 2026-08-17 — Codified updater release operations

- Expanded the Markdown Printer change-gate skill so requests to prepare or publish a GitHub/Sparkle release trigger the complete version, signing, notarization, three-asset appcast, authorization, stable-publication, and public-verification workflow.
- Made the pre-publication stopping point and Pete's separate publication authorization explicit, and documented the three generated assets as one immutable signed set.

## 2026-08-17 — Version 1.3.0 and secure self-updates

- Added a native Sparkle 2.9.2 update experience with manual **Check for Updates…**, daily checks enabled by default, a directly bound Settings preference, standard install/remind/skip choices, and quiet scheduled-network failures.
- Required EdDSA-signed feeds, release notes, and ZIP archives; disabled system profiling and automatic downloads; and required validation before archive extraction.
- Preserved open Markdown document URLs across the one successful update relaunch and postponed installation relaunch while a Save or Print sheet is active.
- Embedded Sparkle in the custom universal SwiftPM app bundle with preserved framework symlinks, an explicit runtime search path, inside-out signing for every helper, and architecture/signature validation.
- Kept local ad-hoc builds launchable without same-team library validation while reserving the hardened runtime for the production bundle, where the app and every Sparkle component receive the same Developer ID identity.
- Extended the notarized release workflow to generate and locally verify the three GitHub Release assets with immutable tag URLs, plus a post-publication verifier for the stable release, `latest` feed, notarization, Gatekeeper, and ZIP digest.
- Added focused updater, document-restoration, and relaunch-deferral regressions; updated privacy and developer documentation; and promoted the updater-enabled baseline as version 1.3.0, build 8.

## 2026-08-17 — Version 1.2.0

- Promoted seamless live Markdown refresh, stable viewport preservation, and native PDF find together as version 1.2.0, build 7.
- Updated the public download label and release verification metadata for the signed, notarized GitHub release ZIP.

## 2026-08-17 — Native PDF find

- Added per-document search of the generated PDF with a compact movable floating panel, live result counts, case-insensitive matching, viewport-relative initial selection, and wrapping next/previous navigation.
- Added the standard Command-F, Command-G, and Shift-Command-G shortcuts plus one Edit > Find submenu, while keeping search chrome off-screen when it is not in use.
- Used a native search field so the first Command-F focuses an empty query without selecting the document, later invocations select only the retained query, and Escape closes the panel without clearing search state.
- Preserved each window's query and current match after dismissal, showed secondary match highlights only while searching, and prepared refreshed-PDF search state behind the visible preview before its atomic swap.
- Added deterministic coverage for controller lifecycle, independent windows, search matching and navigation, buffered refreshes, removed and returning matches, and query changes during staging; verified the complete workflow in the native app.

## 2026-08-17 — Seamless live Markdown refresh

- Added per-window local source monitoring with coordinated-file notifications, re-arming file and parent-directory filesystem watchers for both in-place and atomic saves, and a 150 ms trailing debounce so open previews update automatically after external Markdown edits.
- Published each regenerated document, styled text, and PDF as one session snapshot while retaining the last valid preview across read or render failures.
- Buffered the native PDFKit preview so every replacement is laid out, drawn, and restored in a fresh PDF view behind the visible preview before an animation-free atomic swap; no later refresh reuses a PDFKit surface that has already been displayed and retired.
- Kept the outgoing PDF continuously painted above staging, retired it only after handoff and a compositor settling delay, and disabled AppKit and Core Animation transitions so every refresh follows the same no-blank path while exposing only the active PDF to accessibility.
- Preserved zoom and the actual visible page-boundary position instead of trusting PDFKit's potentially stale current destination, distributed semantic anchors across the complete viewport, discarded non-finite PDFKit table geometry, limited repeated anchors to their closest occurrence, and rejected anchors whose cross-page placement would otherwise clamp to a page top.
- Preserved page-offset fallbacks, rejected stale prepared revisions, and corrected initial PDF navigation to the true top of page one instead of its lower edge beside page two.
- Preserved the Markdown H1 as the window title throughout refreshes with one window-attached title authority.
- Added deterministic coverage for monitoring, atomic snapshots, fresh staging across consecutive updates, stale revisions, prose and table viewport anchors, early and later-page boundary fallbacks, distant duplicate and impossible cross-page anchors, title stability, accessibility handoff, and first-page positioning; verified repeated later-page edits in the native app without a blank redraw.

## 2026-08-13 — Version 1.1.0

- Promoted heading-aware pagination, optional editable Word export, linked footnotes, and Word blockquote fidelity together as version 1.1.0, build 6.
- Updated the public download label and release verification metadata for the signed, notarized GitHub release ZIP.

## 2026-08-13 — Word blockquote fidelity

- Preserved Markdown blockquotes as editable Word paragraphs while adding the same visual hierarchy used by PDF: a thin gray left rule, modest left indent, and italic text.
- Applied the Word-specific paragraph treatment to every line of a multi-line quote without changing PDF preview, print, or pagination behavior.
- Added DOCX regression coverage for multi-line quotes containing bold text, external links, and linked footnote references, plus a nearby code block to prevent false-positive quote styling.

## 2026-08-12 — Linked, print-friendly footnotes

- Added labeled Markdown footnotes with numbering by first citation, compact superscript references, repeated-reference reuse, and small-format definitions collected after the document body.
- Added bidirectional reference-to-note navigation in PDF and Microsoft Word exports without exposing valid footnote Markdown markers in rendered content.
- Added parser, typography, numbering, PDF annotation, DOCX bookmark, and multi-page navigation regressions plus a representative showcase fixture for native visual review.

## 2026-08-12 — Optional Microsoft Word export

- Added editable Microsoft Word (`.docx`) export alongside the unchanged PDF preview and print path, preserving styled text, links, tables, Unicode, local images, and offline-image placeholders.
- Added a standard Settings window whose persistent PDF-or-Word preference controls the initial Save format and the concrete file produced when dragging from the preview; PDF remains the default.
- Replaced the fixed Save PDF action with a neutral Save dialog that can override the format for one export without changing Settings.
- Generalized private drag-file materialization and cleanup for exact PDF or DOCX bytes, filenames, type information, permissions, cancellation, and accepted-drop retention.
- Added focused regressions for DOCX package structure and editable content, exporter failures, session data and filenames, preferences, per-save overrides, and both drag formats.

## 2026-08-12 — Keep headings with following content

- Marked every rendered H1–H6 paragraph with native heading metadata for pagination without changing its typography.
- Added a TextKit pagination pass that moves a bottom-of-page heading group forward unless it already has two following visual rows, while using all available content for shorter sections.
- Added regressions for every heading level, wrapped and consecutive headings, paragraphs, lists, quotations, code, tables, images, and end-of-document behavior.

## 2026-08-12 — Version 1.0.4

- Released concrete PDF file-URL dragging for destinations such as Microsoft Teams as version 1.0.4, build 5.
- Refreshed the public README download label and the signed, notarized GitHub release ZIP.

## 2026-08-12 — Compatible PDF attachments for Microsoft Teams

- Replaced preview file-promise drags with concrete local PDF file URLs so destinations such as Microsoft Teams receive the same attachment form as a Finder drag.
- Preserved the original Markdown basename for the dragged PDF while isolating repeated names in private temporary directories.
- Added bounded cleanup for canceled, accepted, and abandoned drag artifacts without changing preview, save, print, or PDF bytes.
- Added regression coverage for file-URL pasteboard data, exact bytes and filenames, private permissions, cleanup timing, and error forwarding.

## 2026-08-11 — Version 1.0.3 and notarized distribution

- Replaced ad-hoc release signing with Developer ID Application signing, hardened runtime, and a secure timestamp.
- Added automated Apple notarization, ticket stapling, final signature validation, and Gatekeeper assessment to the release packager.
- Released the notarized distribution workflow and support link as version 1.0.3, build 4.
- Updated installation guidance for the normal macOS security flow while keeping credentials in the local Keychain.

## 2026-07-27 — Version 1.0.2

- Released the width-responsive preview and direct PDF-dragging improvements as version 1.0.2, build 3.
- Refreshed the public README download label and the GitHub latest-release ZIP.

## 2026-07-27 — Drag PDFs directly from the preview

- Added a native hold-then-drag gesture to the PDF preview so the complete generated PDF can be dropped onto the Desktop or into apps that accept PDF attachments.
- Kept quick PDF drags available for text selection and used a standard macOS file promise so the destination receives the same bytes shown in the preview.
- Changed Save PDF and dragged-file defaults to preserve the original Markdown filename while replacing its extension with `.pdf`; H1 text remains the window title only.
- Added regressions for source-filename precedence, compound extensions, file-promise type, exact promised bytes, write failures, and press-gesture configuration.

## 2026-07-22 — Local Markdown links and version 1.0.1

- Resolved relative document links against the open Markdown file's folder before writing PDF annotations.
- Routed clicks on local Markdown links back through the app's document opener so linked files open in their own Markdown Printer windows; web and other file links retain normal macOS handling.
- Bumped the app to version 1.0.1, build 2.
- Added an explicit release gate requiring the distributable ZIP to be rebuilt and validated before a version push, followed by verification of the refreshed public release asset.

## 2026-07-22 — MIT license and public About link

- Licensed Markdown Printer under the MIT License and linked the license from the public README.
- Added a clickable MIT License link to the standard macOS About panel while preserving the app name, version, icon, and Peter Edstrom copyright metadata.
- Removed references to unrelated private project names from the current public documentation.

## 2026-07-21 — Public 1.0 release

- Promoted the app to version 1.0 and added Peter Edstrom's name to the standard macOS About panel metadata.
- Rewrote the public README around direct app download, local-first product benefits, multi-document use, and the afternoon vibe-coding origin story.
- Moved build and run utilities into a dedicated folder, added a developer guide, and added a reproducible ZIP packager for GitHub releases.
- Made the downloadable app universal so the same 1.0 ZIP runs natively on both Apple Silicon and Intel Macs that support macOS 14.

## 2026-07-21 — Multi-document windows

- Added native multi-document handling so batches sent from Finder, Open With, the file chooser, or drag-and-drop open one independent preview window per Markdown file.
- Made the welcome chooser accept multiple selections and changed drop handling to collect every Markdown file instead of stopping after the first one.
- Preserved per-document H1 window titles and independent Save PDF and Print actions in every window.

## 2026-07-21 — Quit after the final window closes

- Added native macOS lifecycle handling so closing the last Markdown Printer window terminates the app instead of leaving it running without a window.
- Preserved normal multi-window behavior: the app remains active while any document window is still open.

## 2026-07-21 — Centered page-number footers

- Added a small Avenir Next page number centered in the existing bottom margin of every generated PDF page.
- Kept page numbers outside the document text area so pagination and content placement remain unchanged across preview, save, and print.

## 2026-07-21 — Compact heading and list transitions

- Removed the redundant blank line after level-two through level-six headings, cutting their visible following space roughly in half while retaining the renderer's intentional paragraph spacing.
- Removed the extra blank line between an introductory paragraph and the list that immediately follows it, keeping the paragraph and its bullets visually connected.

## 2026-07-21 — Content-aware table columns

- Replaced equal-width table columns with a constrained content-aware layout: each column retains a readable minimum, while prose-heavy columns receive more of the remaining page width.
- Kept balanced tables balanced and added regressions for both equal two-column layouts and narrow/wide/narrow three-column layouts.
- Made PDF foreground, secondary, and link colors appearance-independent so rendering while macOS is in Dark Mode cannot produce white text on white paper.

## 2026-07-27 — Width-responsive PDF preview

- Made the continuous PDF preview refit to the available width whenever the document window becomes wider or narrower.
- Preserved the initial full-page launch fit and limited responsive zoom changes to width changes, so resizing only the window height does not unexpectedly alter the PDF scale.
- Added native PDFView regressions for both width-responsive scaling and height-only resizing.

## 2026-07-21 — More compact document typography

- Reduced body copy from 12 to 10 points and tightened the complete heading scale, with a larger reduction at the oversized top levels.
- Kept inline and fenced code proportional to the smaller body text so documents fit materially more content on each page without losing their typographic hierarchy.

## 2026-07-21 — Retro printer app icon

- Added a simple, original macOS app icon that combines a printer and Markdown page with a restrained mid-century travel-poster palette and screen-print texture.
- Added a reproducible icon builder and package verification so every release bundle includes the full macOS icon set.

## 2026-07-21 — Simplified document window

- Removed the Open Markdown toolbar button from document windows, leaving only Save PDF and Print; the empty welcome screen still provides its initial file chooser.
- Removed the duplicate filename/font-status strip above the PDF preview.
- Made the first level-one Markdown heading the live macOS window title, with the filename retained as the fallback when a document has no H1.
- Added standard Command-S and Command-P shortcuts for the Save PDF and Print dialogs.

## 2026-07-21 — Full-page launch and Space navigation

- Changed the initial window to a portrait-oriented size and made the continuous PDF preview initially use PDFKit's best-fit scale, so the complete first Letter page is visible at launch.
- Made the preview the initial keyboard focus and mapped an unmodified Space key to advance exactly one PDF page.
- Added native PDFView regressions for full first-page visibility and one-page Space navigation.

## 2026-07-21 — Print margin fidelity

- Removed the print path's second 54-point margin layer and disabled page-to-fit scaling, so printing and Print-dialog PDF saves preserve the generated Letter page's original size and placement.
- Added a print-to-PDF regression that compares the printed page size and heading position with the in-app preview PDF.

## 2026-07-21 — Continuous quotation borders

- Replaced the quotation's first-line `│` glyph with a native TextKit left border, so the rule spans the full height of wrapped and explicit multi-line quoted text.
- Added left and vertical insets that keep italic quotation text comfortably separated from the rule.

## 2026-07-21 — Code typography and spacing

- Switched inline and fenced code from Avenir Next to the native monospaced system font so code alignment and character widths are correct.
- Rebuilt fenced code backgrounds with native text-block padding, giving code consistent breathing room on all four sides instead of letting the background begin at the first glyph.

## 2026-07-21 — Native Markdown-to-PDF foundation

- Created a native macOS app that accepts Markdown through an Open panel, app file-open events, and drag-and-drop.
- Chose a dependency-free native rendering pipeline: a testable Markdown parser and Avenir Next attributed renderer, TextKit pagination, CoreGraphics PDF generation, and PDFKit preview/print. This keeps documents local and ensures preview, save, and print use identical PDF bytes.
- Added formatted headings, inline emphasis, strong text, `<u>` underlining, strikethrough, code, links, quotes, ordered/unordered/task lists, horizontal rules, native searchable tables, and aspect-fitted local images with visible missing/remote-image placeholders.
- Registered Markdown document extensions in a real macOS `.app` bundle and added build, run, and command-line fixture-rendering workflows.
- Added local agent instructions, product and change-gate skills, a product log, focused commit workflow, release verification, and an enforced 95% testable-production line-coverage floor.
- Added a rendered-page visual QA pass and corrected the CoreGraphics coordinate transform so PDF text is upright and begins at the intended top margin; an integration assertion now guards heading placement.
- A native app-window smoke test found PDFKit initially preserving an offset that clipped the first heading beneath the toolbar; the preview now explicitly opens at the top of page one.
- Hardened repeatable local packaging by removing Finder/resource-fork metadata from the generated app bundle before ad-hoc signing.
