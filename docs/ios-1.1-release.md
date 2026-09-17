# iOS 1.1 release handoff

Version **1.1**, build **2**, adds native iPad support to the existing iPhone app. Use the existing Markdown Printer App Store Connect record and bundle identifier `com.peteedstrom.markdown-printer.ios`. The Mac version is independent.

## Local release package

Run the full staged gate with `scripts/commit_staged.sh --include-ios`, then archive and export from the verified commit using `scripts/build-and-run/archive_ios_app_store.sh --export`. Supply the existing signing team through `MARKDOWN_PRINTER_IOS_TEAM_ID`; keep it out of tracked files. Set version-specific archive and export destinations to preserve earlier packages.

The local handoff directory is `build/app-store/ios-1.1/`:

- `MarkdownPrinterIOS-1.1.xcarchive` — signed iPhone/iPad archive.
- `export/Markdown Printer.ipa` — App Store distribution package for upload.
- `screenshots/ipad-13/` — native 13-inch iPad reader screenshots.
- `whats-new.txt` — copy-ready version notes.
- `review-notes.txt` and `Markdown Guide.md` — review instructions and a local sample document.
- `validation-results.json` — exact commit, test results, bundle checks, and package digest.

Generated packages and screenshots stay outside Git. Exporting the IPA does not upload it or submit a version for review.

## App Store Connect walkthrough

1. Sign in to [App Store Connect](https://appstoreconnect.apple.com/) and open **Apps > Markdown Printer**. If version 1.1 already exists, open it. Otherwise, once the current version is **Ready for Distribution**, use the **+** beside **iOS App**, enter **1.1**, and choose **Create**. Use the existing app record; iPad support belongs to this iOS version. Existing metadata carries forward. [Apple's version instructions](https://developer.apple.com/help/app-store-connect/update-your-app/create-a-new-version/)
2. Upload the prepared IPA with **Transporter**, or open the archive in Xcode Organizer and use **Distribute App > App Store Connect > Upload**. Preserve version **1.1** and build **2**. Wait for processing, then choose that build in the version's **Build** section. Uploading is separate from submitting for review. [Apple's upload instructions](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds/)
3. Keep the existing iPhone screenshots if they still match the app. Add the provided iPad images under **iPad 13-inch Display**. Accepted dimensions include **2064 × 2752** portrait and **2752 × 2064** landscape; iPad screenshots are required for iPad support. [Apple's screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications/)
4. Paste `whats-new.txt` into **What's New in This Version**. Review the inherited description so it mentions iPhone and iPad. Preserve current pricing and availability unless intentionally changing them.
5. Confirm the existing support and privacy URLs, app privacy answers, age rating, export-compliance state, and App Review contact information remain accurate. Add `review-notes.txt` and attach the sample Markdown document if useful. The app has no account or login requirement. Record physical-iPad results in the [acceptance checklist](ipad-validation.md) before declaring device acceptance.
6. Choose the release option deliberately. **Manually release this version** gives a final release step after approval. Save the version, review remaining validation messages, then use **Add for Review** and the final submission action when ready. Follow the labels shown by App Store Connect if they differ.

## What's New

Use the customer-facing paragraphs and bullets in [the iOS 1.1 release notes](../release-notes/ios-1.1.md), excluding the heading and final version/build line. The generated `whats-new.txt` contains that text ready to paste.

## Review notes

This update adds native iPad support, resizable document windows, per-window restoration, keyboard commands, and anchored PDF sharing. The app opens Markdown from the native Files browser. No sign-in, account, subscription, or in-app purchase is required to use the installed app.

Save the attached sample Markdown document to Files, open it in Markdown Printer, and use the share icon to generate a searchable PDF. Save to Files and Print use that PDF. On iPad, use New Window to open another document; touch and hold a local Markdown link for Open in New Window. The app reads source files without editing them and generates PDFs locally. Secure remote images referenced by a document may be fetched into the disposable local cache.
