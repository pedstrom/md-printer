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
9. For an app-version change, run `scripts/build-and-run/package_release.sh` from the verified commit and validate the resulting ZIP before pushing.
10. When Pete has authorized release publication, push the commit and matching version tag, refresh the GitHub release asset, and verify the public download.

## Gate Policy

- Do not commit production code unless tests, 95% coverage, the release build, and app-bundle validation pass.
- Minimal app/CLI entrypoints and thin declarative preview views may be excluded from line coverage. Do not exclude parsing, rendering, pagination, PDF generation, document state, save, or print behavior.
- Keep generated PDFs, screenshots, app bundles, local IDE state, and temporary files out of commits.
- Use `git status --short --untracked-files=all` before staging and before handoff.
