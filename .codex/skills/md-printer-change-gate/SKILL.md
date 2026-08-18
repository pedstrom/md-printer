---
name: md-printer-change-gate
description: Use when validating, staging, or committing Markdown Printer changes, and when preparing, signing, notarizing, publishing, or verifying a versioned GitHub/Sparkle update release. Covers focused tests, the 95% coverage gate, intentional commits, app-bundle validation, the three signed release assets, Pete's publication authorization, and post-publication updater checks.
---

# Markdown Printer Change Gate

## Change Flow

1. Keep the change focused on one coherent product, code, test, documentation, or workflow outcome.
2. Run the narrowest relevant XCTest set first.
3. Fix and rerun failures until green or a concrete external blocker is proven.
4. Update `docs/product-development-log.md` for meaningful changes.
5. Run `scripts/verify.sh`.
6. Generate and visually inspect a representative PDF when formatting or pagination changed.
7. Stage only the files belonging to the change and inspect the staged diff.
8. Commit with `scripts/commit_staged.sh "Message"`.

## Prepare a Versioned Update Release

1. Choose the display version and a strictly higher build number. Update both `CFBundleShortVersionString` and `CFBundleVersion`, every current-version assertion or download label, and `release-notes/<display-version>.md`.
2. Complete the Change Flow and commit the verified source before packaging.
3. Confirm that Sparkle's EdDSA private key is available only through the login Keychain and that a protected, recoverable backup exists outside the repository. Keep only `SUPublicEDKey` in tracked files.
4. From the verified commit, run `scripts/build-and-run/package_release.sh` with the full Developer ID Application identity and the notarytool Keychain profile. Require Apple acceptance, a stapled ticket, Gatekeeper acceptance, a validated universal ZIP, correct runtime linkage, and valid nested signatures.
5. Require `build/release-assets/v<display-version>/` to contain exactly:
   - `Markdown-Printer.zip`
   - `Markdown-Printer.md`
   - `appcast.xml`
6. Run the local update-asset verification. Require EdDSA verification for the feed, ZIP, and Markdown release notes; matching recorded lengths; the expected version/build; immutable `releases/download/v<display-version>/...` URLs; and a recorded SHA-256 digest.
7. Treat the three generated assets as one immutable set. If either the ZIP or release notes changes, regenerate and reverify the entire set.
8. Report the verified commit, version/build, notarization result, asset paths, and ZIP digest. Stop before any push, tag, GitHub Release mutation, or publication unless Pete has separately authorized publication.

## Publish Only After Pete Authorizes It

1. Push the verified commit and create/push tag `v<display-version>` at that exact commit.
2. Create or update a draft GitHub Release for the matching tag.
3. Upload all three locally verified assets without renaming or modifying them.
4. Confirm the draft contains the complete asset set, then publish it as a normal stable release. Do not mark it as a prerelease; drafts and prereleases are not updater channels.
5. Run `scripts/build-and-run/verify_published_release.sh v<display-version>`.
6. Require the public ZIP digest to match the local notarized archive, the tagged and `latest/download/appcast.xml` feeds to match, public EdDSA signatures to verify, and the downloaded app to pass codesign, stapler, and Gatekeeper validation.
7. Do not report the release complete while any public verification fails.

Installed apps discover updates only through the stable GitHub Release asset at `https://github.com/pedstrom/md-printer/releases/latest/download/appcast.xml`. Sparkle compares the monotonically increasing build number, displays the signed Markdown release notes, and downloads the signed ZIP only after the user approves installation.

## Gate Policy

- Do not commit production code unless tests, 95% coverage, the release build, and app-bundle validation pass.
- Minimal app/CLI entrypoints and thin declarative preview views may be excluded from line coverage. Do not exclude parsing, rendering, pagination, PDF generation, document state, save, or print behavior.
- Keep generated PDFs, screenshots, app bundles, local IDE state, and temporary files out of commits.
- Keep the Sparkle EdDSA private key and every backup outside the repository. Embed only `SUPublicEDKey`.
- Do not enable update-system profiling, automatic downloading, prerelease channels, deltas, or release publication without an explicit product decision.
- Do not assume that a request to prepare, build, test, sign, notarize, or draft a release authorizes pushing a tag or publishing it.
- Use `git status --short --untracked-files=all` before staging and before handoff.
