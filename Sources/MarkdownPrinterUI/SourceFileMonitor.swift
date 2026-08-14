@preconcurrency import Foundation
import Darwin

@MainActor
protocol SourceChangeMonitoring: AnyObject {
    var sourceURL: URL { get }
    var isMonitoring: Bool { get }

    func start()
    func stop()
}

@MainActor
final class SourceFileMonitor: NSObject, SourceChangeMonitoring {
    let sourceURL: URL
    private let debounceInterval: TimeInterval
    private let onChange: () -> Void
    private let operationQueue: OperationQueue
    private var pendingChange: DispatchWorkItem?
    private var directorySource: DispatchSourceFileSystemObject?
    private var sourceFileSource: DispatchSourceFileSystemObject?
    private var pendingSourceFileRestart: DispatchWorkItem?
    private(set) var isMonitoring = false

    init(
        sourceURL: URL,
        debounceInterval: TimeInterval = 0.15,
        onChange: @escaping () -> Void
    ) {
        self.sourceURL = sourceURL.standardizedFileURL
        self.debounceInterval = debounceInterval
        self.onChange = onChange
        self.operationQueue = OperationQueue()
        super.init()
        operationQueue.name = "Markdown Printer source monitoring"
        operationQueue.maxConcurrentOperationCount = 1
        operationQueue.underlyingQueue = .main
    }

    deinit {
        pendingChange?.cancel()
        pendingSourceFileRestart?.cancel()
        directorySource?.cancel()
        sourceFileSource?.cancel()
        if isMonitoring {
            NSFileCoordinator.removeFilePresenter(self)
        }
    }

    func start() {
        guard !isMonitoring else { return }
        isMonitoring = true
        NSFileCoordinator.addFilePresenter(self)
        startDirectorySource()
        startSourceFileSource()
    }

    func stop() {
        guard isMonitoring else { return }
        isMonitoring = false
        pendingChange?.cancel()
        pendingChange = nil
        pendingSourceFileRestart?.cancel()
        pendingSourceFileRestart = nil
        directorySource?.cancel()
        directorySource = nil
        sourceFileSource?.cancel()
        sourceFileSource = nil
        NSFileCoordinator.removeFilePresenter(self)
    }

    private func scheduleChange() {
        guard isMonitoring else { return }
        pendingChange?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.isMonitoring else { return }
            self.pendingChange = nil
            self.onChange()
        }
        pendingChange = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + debounceInterval, execute: workItem)
    }

    private func isSourceURL(_ url: URL) -> Bool {
        url.standardizedFileURL == sourceURL
    }

    private func startDirectorySource() {
        let directoryURL = sourceURL.deletingLastPathComponent()
        let descriptor = open(directoryURL.path, O_EVTONLY)
        guard descriptor >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .delete, .rename, .attrib, .extend],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            self.scheduleChange()
            self.restartSourceFileSource()
        }
        source.setCancelHandler {
            close(descriptor)
        }
        directorySource = source
        source.resume()
    }

    private func startSourceFileSource() {
        guard isMonitoring, sourceFileSource == nil else { return }
        let descriptor = open(sourceURL.path, O_EVTONLY)
        guard descriptor >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .delete, .rename, .attrib, .extend, .revoke],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let events = self.sourceFileSource?.data ?? []
            let requiresRestart = !events.intersection([.delete, .rename, .revoke]).isEmpty
            self.scheduleChange()
            if requiresRestart {
                self.restartSourceFileSource()
            }
        }
        source.setCancelHandler {
            close(descriptor)
        }
        sourceFileSource = source
        source.resume()
    }

    private func restartSourceFileSource() {
        sourceFileSource?.cancel()
        sourceFileSource = nil
        scheduleSourceFileRestart()
    }

    private func scheduleSourceFileRestart() {
        guard isMonitoring else { return }
        pendingSourceFileRestart?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.isMonitoring else { return }
            self.pendingSourceFileRestart = nil
            self.startSourceFileSource()
        }
        pendingSourceFileRestart = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02, execute: workItem)
    }
}

extension SourceFileMonitor: NSFilePresenter {
    nonisolated var presentedItemURL: URL? {
        sourceURL.deletingLastPathComponent()
    }

    nonisolated var presentedItemOperationQueue: OperationQueue {
        operationQueue
    }

    nonisolated func presentedItemDidChange() {
        Task { @MainActor [weak self] in
            self?.scheduleChange()
        }
    }

    nonisolated func presentedSubitemDidChange(at url: URL) {
        Task { @MainActor [weak self] in
            guard let self, self.isSourceURL(url) else { return }
            self.scheduleChange()
        }
    }

    nonisolated func presentedSubitem(at oldURL: URL, didMoveTo newURL: URL) {
        Task { @MainActor [weak self] in
            guard let self,
                  self.isSourceURL(oldURL) || self.isSourceURL(newURL)
            else { return }
            self.scheduleChange()
        }
    }

    nonisolated func accommodatePresentedSubitemDeletion(
        at url: URL,
        completionHandler: @escaping (Error?) -> Void
    ) {
        Task { @MainActor [weak self] in
            if let self, self.isSourceURL(url) {
                self.scheduleChange()
            }
            completionHandler(nil)
        }
    }
}
