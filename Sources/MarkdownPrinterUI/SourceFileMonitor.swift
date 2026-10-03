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
    nonisolated var sourceURL: URL { location.url }
    private nonisolated let location: SourceFileLocation
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
        self.location = SourceFileLocation(url: sourceURL.standardizedFileURL)
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
        if isMonitoring {
            startDirectorySource()
            startSourceFileSource()
            return
        }
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
        guard isMonitoring, directorySource == nil else { return }
        let directoryURL = sourceURL.deletingLastPathComponent()
        let descriptor = open(directoryURL.path, O_EVTONLY)
        guard descriptor >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .delete, .rename, .attrib, .extend, .revoke],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            guard let self, self.isMonitoring, self.directorySource?.handle == descriptor else { return }
            let events = self.directorySource?.data ?? []
            self.followSourceFileMove()
            if !events.intersection([.delete, .rename, .revoke]).isEmpty,
               self.directorySource?.handle == descriptor {
                self.directorySource?.cancel()
                self.directorySource = nil
                self.startDirectorySource()
            }
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
            guard let self, self.isMonitoring, self.sourceFileSource?.handle == descriptor else { return }
            let events = self.sourceFileSource?.data ?? []
            let requiresRestart = !events.intersection([.delete, .rename, .revoke]).isEmpty
            if events.contains(.rename) { self.followSourceFileMove() }
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

    // The open descriptor follows the same file through uncoordinated Finder/CLI moves.
    // Verify its identity at the returned path before adopting that location.
    private func followSourceFileMove() {
        guard let descriptor = sourceFileSource?.handle else { return }
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(descriptor, F_GETPATH, &path) == 0 else { return }
        let url = URL(fileURLWithPath: String(cString: path)).standardizedFileURL
        guard url != sourceURL.resolvingSymlinksInPath().standardizedFileURL else { return }
        var descriptorInfo = stat()
        var pathInfo = stat()
        guard fstat(descriptor, &descriptorInfo) == 0,
              stat(url.path, &pathInfo) == 0,
              descriptorInfo.st_dev == pathInfo.st_dev,
              descriptorInfo.st_ino == pathInfo.st_ino
        else { return }
        moveSource(to: url)
    }

    private func moveSource(to url: URL) {
        let url = url.standardizedFileURL
        guard isMonitoring, url != sourceURL else { return }
        let changesDirectory = url.deletingLastPathComponent() != sourceURL.deletingLastPathComponent()
        if changesDirectory { NSFileCoordinator.removeFilePresenter(self) }
        location.url = url
        if changesDirectory {
            directorySource?.cancel()
            directorySource = nil
            startDirectorySource()
            NSFileCoordinator.addFilePresenter(self)
        }
        restartSourceFileSource()
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

    nonisolated func presentedItemDidMove(to newURL: URL) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.moveSource(to: newURL.appendingPathComponent(self.sourceURL.lastPathComponent))
            self.scheduleChange()
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
            if self.isSourceURL(oldURL) { self.moveSource(to: newURL) }
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

// File presenter properties may be read from outside the main actor.
private final class SourceFileLocation: @unchecked Sendable {
    private let lock = NSLock()
    private var storedURL: URL

    init(url: URL) { storedURL = url }

    var url: URL {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedURL
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            storedURL = newValue
        }
    }
}
