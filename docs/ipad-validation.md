# iPad validation

Native support targets iOS and iPadOS 26 or later. App Store submission is a separate release step.

## Automated and simulator checks

The verification gate runs iPhone, iPad mini, and 13-inch iPad unit and UI suites, plus an 11-inch iPad landscape smoke test. It validates device families, every iPad orientation, multiple scenes, launch-screen metadata, read-only document registration, and the privacy manifest in the built app.

Routing and local restoration tests cover empty windows, separate documents, identical filenames at different paths, duplicate and pending opens, independent navigation/search state, corrupt or unavailable bookmarks, per-scene storage, and disposal. PDF tests cover generation cancellation, identical print/share bytes, anchored popovers, rotation updates, and temporary-file lifetime through completion.

Native UI checks exercise external URL handoff, linked navigation, document windows, search, rotation, window resizing, large text, sharing, Save to Files, print options, and background/relaunch restoration. Keyboard shortcuts and pointer behavior also require physical-device acceptance below. The accessibility description audit permits literal document filenames, which are user content rather than authored control labels.

Generated review artifacts belong under the ignored `build/ipad-validation/` directory. The signed universal iPhone/iPad archive belongs under `build/app-store/`. Keep simulator screenshots and physical-device results separate. Use the 13-inch screenshots required by [App Store Connect](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications).

Keyboard checks cover Command-F, Command-G, Shift-Command-G, Command-P, and native text editing. On the installed 26.5 Simulator, an initial harmless key event is needed before synthesized Command shortcuts arrive reliably. Escape is reserved by Simulator keyboard capture, so its native responder callback is checked in unit tests and still requires physical-device acceptance. The Print context-menu path was also exercised during focused validation. XCUIApplication.open restarts the process, so external-URL smoke tests do not prove warm handoff; live reuse is tested through linked-document window actions. These checks are not physical-keyboard acceptance.

## Results — September 14, 2026

Validated with Xcode 26.6 and the iOS/iPadOS 26.5 Simulator runtime:

| Target | Unit tests | UI tests |
| --- | ---: | ---: |
| macOS | 301 passed | Native PDF review |
| iPhone 17 Pro | 69 passed | 17 passed; 11 iPad-only cases skipped |
| iPad Pro 13-inch (M5) | 69 passed | 26 passed; 2 iPhone gesture cases skipped |
| iPad mini (A17 Pro) | 69 passed | 26 passed; 2 iPhone gesture cases skipped |
| iPad Pro 11-inch (M5) | — | Landscape smoke passed |

`scripts/verify.sh --include-ios` passed, including performance checks and universal Mac app validation. Line coverage was **95.19%** for testable Mac production code, **96.74%** for mobile support, and **98.08%** for the new window routing, restoration, keyboard, and PDF presentation support. Verification preserves a separate result bundle and coverage profile for every device/target run.

Reviewed the 13-inch reader in portrait and landscape, dark appearance with text selection, large text, narrow-window Find, the native share popover, Save to Files, print options, and all three pages of the exported PDF fixture. Use full-screen iPad captures: app-bounded screenshots crop incorrectly after rotation on this Simulator runtime.

The local review directory contains `ipad-13-field-notes-portrait.png`, `ipad-13-field-notes-landscape.png`, the interaction screenshots, `exported-fixture.pdf`, and its rendered pages. This September 14 validation used iOS version 1.0, build 1. The subsequent [iOS 1.1 release handoff](ios-1.1-release.md) keeps versioned packages and fresh gate results separate from App Store submission.

## Physical iPad acceptance — pending

No physical iPad was connected during implementation. Before declaring device acceptance, record the iPad model, OS version, build, date, and result for each item:

- Open local, iCloud, and third-party-provider Markdown from Files and another app, with the app cold and warm; test offline files, moved files, revoked folder grants, Retry, and Browse.
- Drop Files into an empty reader window and a window already displaying a document. Open two files with the same name from separate folders, reopen each, and close one while the other is loading or generating a PDF.
- Use a hardware keyboard and trackpad: New Window, Open, Find, next/previous match, Share PDF, Print, Close, Escape, pointer targeting, selectable text, and native back navigation.
- Resize and rotate in both portrait directions and both landscapes during loading, search, PDF preparation, sharing, and printing. Check narrow/short windows with the onscreen keyboard and accessibility text sizes.
- Complete Save to Files through a real provider and an AirPrint job. Confirm that the generated PDF retains searchable text, links, pagination, and image proportions.
- Use VoiceOver heading navigation and control focus in light and dark appearance, including search results, permission recovery, and the share/print interfaces.

Simulator success does not establish physical provider, hardware-input, VoiceOver, or AirPrint acceptance.
