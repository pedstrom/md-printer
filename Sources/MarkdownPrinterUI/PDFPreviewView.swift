import PDFKit
import SwiftUI

public struct PDFPreviewView: NSViewRepresentable {
    public let data: Data

    public init(data: Data) {
        self.data = data
    }

    public func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.displaysPageBreaks = true
        view.backgroundColor = .windowBackgroundColor
        return view
    }

    public func updateNSView(_ view: PDFView, context: Context) {
        guard view.document?.dataRepresentation() != data else { return }
        guard let document = PDFDocument(data: data) else { return }
        view.document = document
        view.autoScales = true
        if let firstPage = document.page(at: 0) {
            let bounds = firstPage.bounds(for: .cropBox)
            view.go(
                to: CGRect(x: bounds.minX, y: bounds.minY, width: 1, height: 1),
                on: firstPage
            )
        }
    }
}
