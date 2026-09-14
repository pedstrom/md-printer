#if canImport(UIKit)
import Combine
import Foundation
import UIKit
import UniformTypeIdentifiers

public final class MobilePDFActivityItem: NSObject, UIActivityItemSource {
    public let data: Data
    public let fileURL: URL
    public var placeholderItem: Any { fileURL }
    public var dataTypeIdentifier: String { UTType.pdf.identifier }
    public init(data: Data, fileURL: URL) { self.data = data; self.fileURL = fileURL }
    public func activityViewControllerPlaceholderItem(_ activityViewController: UIActivityViewController) -> Any { placeholderItem }
    public func item(for activityType: UIActivity.ActivityType?) -> Any {
        activityType == .print ? data : fileURL
    }
    public func activityViewController(_ activityViewController: UIActivityViewController, itemForActivityType activityType: UIActivity.ActivityType?) -> Any? { item(for: activityType) }
    public func activityViewController(_ activityViewController: UIActivityViewController, dataTypeIdentifierForActivityType activityType: UIActivity.ActivityType?) -> String { dataTypeIdentifier }
}

public enum MobilePDFShareStore {
    public static func write(data: Data, filename: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarkdownPrinterShare-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(URL(fileURLWithPath: filename).lastPathComponent)
        do { try data.write(to: url, options: .atomic) }
        catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        return url
    }
}

public enum MobilePDFPresentationError: LocalizedError {
    case unavailable
    public var errorDescription: String? { "Close the current sheet, then try again." }
}

@MainActor
public final class MobilePDFPresentationController: NSObject, ObservableObject, UIAdaptivePresentationControllerDelegate {
    public weak var anchor: UIView?
    public private(set) var sharedURL: URL?
    public private(set) var activityController: UIActivityViewController?
    private var printController: UIPrintInteractionController?
    private static weak var printOwner: MobilePDFPresentationController?
    private let presentActivity: (UIViewController, UIViewController) -> Void
    private let presentPrint: (UIPrintInteractionController, Data, UIView, @escaping (UIPrintInteractionController, Bool, Error?) -> Void) -> Bool

    public init(
        presentActivity: @escaping (UIViewController, UIViewController) -> Void = { host, activity in host.present(activity, animated: true) },
        presentPrint: @escaping (UIPrintInteractionController, Data, UIView, @escaping (UIPrintInteractionController, Bool, Error?) -> Void) -> Bool = { controller, data, anchor, completion in
            controller.printingItem = data
            if anchor.traitCollection.userInterfaceIdiom == .pad {
                return controller.present(from: anchor.bounds, in: anchor, animated: true, completionHandler: completion)
            }
            return controller.present(animated: true, completionHandler: completion)
        }
    ) {
        self.presentActivity = presentActivity
        self.presentPrint = presentPrint
        super.init()
    }

    private func presentationHost() throws -> (UIView, UIViewController) {
        guard let anchor, anchor.window != nil else { throw MobilePDFPresentationError.unavailable }
        var responder: UIResponder? = anchor
        while let current = responder {
            if let host = current as? UIViewController {
                guard host.presentedViewController == nil else { throw MobilePDFPresentationError.unavailable }
                return (anchor, host)
            }
            responder = current.next
        }
        throw MobilePDFPresentationError.unavailable
    }

    public func share(data: Data, filename: String) throws {
        guard activityController == nil, printController == nil else { throw MobilePDFPresentationError.unavailable }
        let (anchor, host) = try presentationHost()
        let url = try MobilePDFShareStore.write(data: data, filename: filename)
        let activity = UIActivityViewController(activityItems: [MobilePDFActivityItem(data: data, fileURL: url)], applicationActivities: nil)
        activity.view.accessibilityIdentifier = "share-sheet"
        sharedURL = url
        activityController = activity
        // Capture self until the activity finishes, even if its document window closes.
        activity.completionWithItemsHandler = { [self] _, _, _, _ in finishSharing() }
        if let popover = activity.popoverPresentationController {
            popover.sourceView = anchor
            popover.sourceRect = anchor.bounds
            popover.permittedArrowDirections = [.up, .down]
        }
        presentActivity(host, activity)
        activity.presentationController?.delegate = self
    }

    public func updateAnchor() {
        guard let anchor else { return }
        activityController?.popoverPresentationController?.sourceRect = anchor.bounds
    }

    public func finishSharing() {
        if let sharedURL { try? FileManager.default.removeItem(at: sharedURL.deletingLastPathComponent()) }
        sharedURL = nil
        activityController?.completionWithItemsHandler = nil
        activityController = nil
    }

    public func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        finishSharing()
    }

    public func printPDF(data: Data, filename: String, onError: @escaping (String) -> Void) throws {
        guard activityController == nil, Self.printOwner == nil else { throw MobilePDFPresentationError.unavailable }
        let (anchor, _) = try presentationHost()
        let controller = UIPrintInteractionController.shared
        let info = UIPrintInfo(dictionary: nil)
        info.jobName = filename
        info.outputType = .general
        controller.printInfo = info
        printController = controller
        Self.printOwner = self
        let accepted = presentPrint(controller, data, anchor) { [self] _, _, error in
            finishPrinting()
            if let error { onError(error.localizedDescription) }
        }
        if !accepted {
            finishPrinting()
            throw MobilePDFPresentationError.unavailable
        }
    }

    private func finishPrinting() {
        printController?.printingItem = nil
        printController = nil
        Self.printOwner = nil
    }
}
#endif
