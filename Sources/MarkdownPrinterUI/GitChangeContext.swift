import Foundation
import MarkdownPrinterCore

package struct GitCommitDescription: Equatable, Sendable {
    let id: String
    let subject: String
    let body: String
    let date: Date
}

package struct GitChangeContext: Equatable, Sendable {
    var commits: [String: [GitCommitDescription]] = [:]
    var uncommittedItems: Set<String> = []
}

package protocol GitChangeContextProviding: Sendable {
    func context(current: MarkdownDocument, baseline: OriginalDocumentSnapshot) async throws -> GitChangeContext
}

package struct GitChangeContextLoader: GitChangeContextProviding {
    var service: any GitDocumentHistoryProviding = GitDocumentHistoryService()

    package func context(current: MarkdownDocument, baseline: OriginalDocumentSnapshot) async throws -> GitChangeContext {
        guard let url = current.sourceURL, let id = baseline.gitRevision else { return GitChangeContext() }
        let history = try await service.history(for: url)
        let revisions = try await service.comparisonRevisions(after: id, in: history)
        var documents = [baseline.document]
        for revision in revisions {
            try Task.checkCancellation()
            documents.append(try await service.document(for: revision, in: history))
        }
        documents.append(current)
        let versions = documents
        let worker = Task.detached(priority: .utility) {
            try RevisionCommitAttribution.contributions(in: versions)
        }
        let contributions = try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: { worker.cancel() }
        try Task.checkCancellation()
        let needed = Set(contributions.values.flatMap { $0 }.filter { $0 < revisions.count })
        var descriptions: [Int: GitCommitDescription] = [:]
        for index in needed.sorted() {
            descriptions[index] = try await service.description(for: revisions[index], in: history)
        }
        var context = GitChangeContext()
        for (item, indices) in contributions {
            context.commits[item] = indices.sorted().compactMap { descriptions[$0] }
            if indices.contains(revisions.count) { context.uncommittedItems.insert(item) }
        }
        return context
    }
}
