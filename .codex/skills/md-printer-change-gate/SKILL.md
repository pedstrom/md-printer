---
name: md-printer-change-gate
description: Use when validating, staging, or committing Markdown Printer changes, including focused tests, the 95% coverage gate, release build, app-bundle validation, and intentional commits.
---

# Markdown Printer Change Gate

## Required Flow

1. Keep the change focused on one coherent product, code, test, documentation, or workflow outcome.
2. Run the narrowest relevant XCTest set first.
3. Fix and rerun failures until green or a concrete external blocker is proven.
4. Update `docs/product-development-log.md` for meaningful changes.
5. Run `scripts/verify.sh`.
6. Generate and visually inspect a representative PDF when formatting or pagination changed.
7. Stage only the files belonging to the change and inspect the staged diff.
8. Commit with `scripts/commit_staged.sh "Message"`.
9. For an app-version change, run `scripts/build-and-run/package_release.sh` from the verified commit with the Developer ID identity and notarytool Keychain profile. Require Apple acceptance, a stapled ticket, a passing Gatekeeper assessment, a validated universal ZIP, and a locally verified signed three-asset update set before pushing.
10. Check that `build/release-assets/v<version>/` contains only `Markdown-Printer.zip`, `Markdown-Printer.md`, and `appcast.xml`; the appcast must use the immutable tag-specific URLs, and the release notes and archive signatures must verify with Sparkle's Keychain key.
11. Only after Pete separately authorizes publication, push the commit and matching version tag, create or update a draft GitHub Release, upload all three assets, and publish the stable release.
12. Run `scripts/build-and-run/verify_published_release.sh v<version>` and require the published ZIP digest to match the local notarized archive, the `latest` appcast to match the tagged appcast, and public signature, notarization, and Gatekeeper validation to pass.

## Gate Policy

- Do not commit production code unless tests, 95% coverage, the release build, and app-bundle validation pass.
- Minimal app/CLI entrypoints and thin declarative preview views may be excluded from line coverage. Do not exclude parsing, rendering, pagination, PDF generation, document state, save, or print behavior.
- Keep generated PDFs, screenshots, app bundles, local IDE state, and temporary files out of commits.
- Keep the Sparkle EdDSA private key and every backup outside the repository. Embed only `SUPublicEDKey`.
- Do not enable update-system profiling, automatic downloading, prerelease channels, deltas, or release publication without an explicit product decision.
- Use `git status --short --untracked-files=all` before staging and before handoff.
