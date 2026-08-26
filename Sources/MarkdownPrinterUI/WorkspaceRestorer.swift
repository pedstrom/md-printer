import Foundation

package struct WorkspaceRestoreResult: Equatable {
    package let openedDocumentCount: Int
    package let failedDocumentNames: [String]
}

@MainActor
package enum WorkspaceRestorer {
    package static func restore(
        _ workspace: WorkspaceSnapshot,
        restorationController: OpenDocumentRestorationController,
        tabCoordinator: WindowTabCoordinator,
        openDocument: @escaping (URL) async throws -> Void,
        openWelcome: @escaping (UUID) -> Void,
        isReadableFile: @escaping (URL) -> Bool = {
            FileManager.default.isReadableFile(atPath: $0.path)
        }
    ) async -> WorkspaceRestoreResult {
        restorationController.prepareWindowStates(for: workspace)
        var openedDocumentCount = 0
        var failedDocumentNames: [String] = []

        for group in workspace.groups {
            let hasRestorableDocument = group.tabs.contains { tab in
                guard let url = tab.documentURL else { return false }
                return restorationController.isDocumentOpen(at: url) || isReadableFile(url)
            }
            guard hasRestorableDocument else {
                failedDocumentNames.append(contentsOf: group.tabs.compactMap { tab in
                    tab.documentURL?.lastPathComponent
                })
                continue
            }

            for (tabIndex, tab) in group.tabs.enumerated() {
                let isSelected = tabIndex == group.selectedTabIndex
                switch tab.kind {
                case .welcome:
                    let identifier = tabCoordinator.prepareWorkspaceWelcome(
                        groupIdentifier: group.identifier,
                        isSelected: isSelected,
                        isTabBarVisible: group.isTabBarVisible
                    )
                    openWelcome(identifier)
                    await settleWindowAttachment()

                case .document:
                    guard let url = tab.documentURL else { continue }
                    if restorationController.isDocumentOpen(at: url) {
                        tabCoordinator.useOpenDocument(
                            at: url,
                            groupIdentifier: group.identifier,
                            isSelected: isSelected,
                            isTabBarVisible: group.isTabBarVisible
                        )
                        continue
                    }
                    guard isReadableFile(url) else {
                        failedDocumentNames.append(url.lastPathComponent)
                        continue
                    }
                    tabCoordinator.prepareWorkspaceDocument(
                        at: url,
                        groupIdentifier: group.identifier,
                        isSelected: isSelected,
                        isTabBarVisible: group.isTabBarVisible
                    )
                    do {
                        try await openDocument(url)
                        openedDocumentCount += 1
                        await settleWindowAttachment()
                    } catch {
                        tabCoordinator.cancelWorkspaceDocument(
                            at: url,
                            groupIdentifier: group.identifier
                        )
                        failedDocumentNames.append(url.lastPathComponent)
                    }
                }
            }
        }

        await settleWindowAttachment()
        tabCoordinator.finishWorkspaceRestoration()
        return WorkspaceRestoreResult(
            openedDocumentCount: openedDocumentCount,
            failedDocumentNames: Array(Set(failedDocumentNames)).sorted()
        )
    }

    private static func settleWindowAttachment() async {
        await Task.yield()
        await Task.yield()
    }
}

package struct WorkspaceRestorationSummaryError: LocalizedError, Equatable {
    package let failedDocumentNames: [String]

    package init(failedDocumentNames: [String]) {
        self.failedDocumentNames = failedDocumentNames
    }

    package var errorDescription: String? {
        guard !failedDocumentNames.isEmpty else { return nil }
        let names = failedDocumentNames.joined(separator: ", ")
        let noun = failedDocumentNames.count == 1 ? "document" : "documents"
        return "Couldn’t reopen \(failedDocumentNames.count) \(noun): \(names)."
    }
}
