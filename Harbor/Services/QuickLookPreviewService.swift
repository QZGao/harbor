import Foundation
import QuickLookUI

@MainActor
protocol QuickLookPreviewing: AnyObject {
    func preview(urls: [URL])
}

@MainActor
final class QuickLookPreviewService: NSObject, QuickLookPreviewing, QLPreviewPanelDataSource {
    private var previewURLs: [URL] = []

    func preview(urls: [URL]) {
        guard urls.isEmpty == false,
              let panel = QLPreviewPanel.shared() else {
            return
        }

        previewURLs = urls
        panel.dataSource = self
        panel.currentPreviewItemIndex = 0
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        previewURLs.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        previewURLs[index] as NSURL
    }
}
