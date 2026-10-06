package struct MarkdownPrinterHelpCopyablePrompt: Equatable {
    package let title: String
    package let text: String
    package let exampleTitle: String
    package let example: String

    package var searchableTexts: [String] { [title, text, exampleTitle, example] }
}

extension MarkdownPrinterHelpContent {
    package static let codexComparisonSkillPrompt = """
    Create a user-level Codex skill named markdown-printer-compare, available in every project on this Mac. Use the skill-creator skill if available. Discover and use the user-level skills directory supported by my Codex installation, outside project repositories. Give SKILL.md valid name and description frontmatter so Codex uses it when I ask to compare a Markdown file with a previous version or show what changed.

    The skill should resolve the current Markdown file and the older version I request, either an existing local file or a Git revision. If “previous version” is ambiguous, ask one concise question. Read Git history without checking out, restoring, or modifying working files; materialize historical Markdown in a private temporary .md file when needed.

    Launch Markdown Printer using its bundled CLI with this syntax, substituting the actual absolute file paths:

    "/Applications/Markdown Printer.app/Contents/MacOS/MarkdownPrinterCLI" open "/absolute/path/current.md" --original "/absolute/path/older.md"

    Pass exactly one current file with --original; the current file comes first and the older file is the original. Quote shell paths safely, or pass arguments as an array. If the app is installed elsewhere, locate its bundle and use Contents/MacOS/MarkdownPrinterCLI there. If the app or CLI is unavailable, explain what is missing.

    Markdown Printer snapshots the original locally before the CLI returns, keeps it fixed while the current file refreshes, and includes change highlighting in the preview and PDF/Word exports. After a successful launch, delete only temporary originals created by this skill. Keep document content on this Mac and leave source files unchanged. Report the current file, the baseline file or Git revision, and whether the launch succeeded. Validate the skill and show me an example request I can use.
    """

    package static let codexComparisonSkillSection = MarkdownPrinterHelpSection(
        id: .codexComparisons,
        title: "Set Up Codex Comparisons",
        paragraphs: [
            "Set up Codex comparisons once on each Mac. Click Copy prompt below, paste it into a Codex chat on this Mac, and send it. The skill will be available across projects for your user on this Mac.",
            "Markdown Printer must be installed on the Mac where Codex runs. Codex retrieves the older version and launches the comparison."
        ],
        copyablePrompt: MarkdownPrinterHelpCopyablePrompt(
            title: "Prompt to paste into Codex",
            text: codexComparisonSkillPrompt,
            exampleTitle: "After setup, try…",
            example: "Compare notes.md with its version at Git revision HEAD. You can also name an older local Markdown file."
        )
    )
}
