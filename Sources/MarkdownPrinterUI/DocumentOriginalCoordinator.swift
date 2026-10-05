import AppKit
import MarkdownPrinterCore

/// Routes an optional original into the same session used by ordinary opens.
@MainActor
public final class DocumentOriginalCoordinator {
    public static let shared = DocumentOriginalCoordinator()
    public let store: OriginalSnapshotStore
    private final class SessionReference {
        weak var session: DocumentSession?
        init(_ session: DocumentSession) { self.session = session }
    }
    private var sessions: [URL: SessionReference] = [:]
    private var restorationErrors: [URL: Error] = [:]
    private var pending: [URL: OriginalDocumentSnapshot] = [:]
    private var queuedSnapshotCounts: [UUID: Int] = [:]

    public init(store: OriginalSnapshotStore = OriginalSnapshotStore()) { self.store = store }

    public func enqueue(_ request: MarkdownOpenRequest) throws {
        guard let id = request.originalID else { return }
        let snapshot = try store.load(id)
        restorationErrors.removeValue(forKey: request.fileURL)
        if let session = sessions[request.fileURL]?.session {
            queuedSnapshotCounts[id, default: 0] += 1
            Task {
                defer {
                    let remaining = (queuedSnapshotCounts[id] ?? 1) - 1
                    if remaining == 0 { queuedSnapshotCounts.removeValue(forKey: id) }
                    else { queuedSnapshotCounts[id] = remaining }
                }
                do { try await session.setOriginalSnapshot(snapshot) }
                catch { session.report(error: error) }
            }
        } else {
            pending[request.fileURL] = snapshot
        }
        store.consume(id)
    }

    package func reportRestorationError(_ error: Error, for url: URL) { restorationErrors[url.standardizedFileURL] = error }

    package func register(_ session: DocumentSession, for url: URL?) throws -> OriginalDocumentSnapshot? {
        guard let url else {
            updateRegistration(session, for: nil)
            return nil
        }
        let key = url.standardizedFileURL
        if let error = restorationErrors.removeValue(forKey: key) { throw error }
        updateRegistration(session, for: key)
        return pending.removeValue(forKey: key)
    }

    package func updateRegistration(_ session: DocumentSession, for url: URL?) {
        let key = url?.standardizedFileURL
        sessions = sessions.filter { $0.value.session != nil && ($0.key == key || $0.value.session !== session) }
        if let key { sessions[key] = SessionReference(session) }
    }

    package var retainedOriginalIDs: Set<UUID> {
        Set(sessions.values.compactMap { $0.session?.originalSnapshot?.id })
            .union(pending.values.map(\.id))
            .union(queuedSnapshotCounts.keys)
    }

    package func collect(retaining restoredIDs: Set<UUID>) {
        try? store.collect(retaining: restoredIDs.union(retainedOriginalIDs))
    }
}
