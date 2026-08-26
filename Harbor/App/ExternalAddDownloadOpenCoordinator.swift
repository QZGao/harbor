import AppKit
import Foundation

@MainActor
final class ExternalAddDownloadOpenCoordinator {
    static let shared = ExternalAddDownloadOpenCoordinator()

    private var pendingURLs: [URL] = []
    private var pendingErrorMessages: [String] = []
    private var handler: (([URL], [String]) -> Void)?

    private init() {}

    @discardableResult
    func receive(urls: [URL]) -> Bool {
        var supportedURLs: [URL] = []
        var errorMessages: [String] = []

        for url in urls {
            if url.scheme?.lowercased() == "harbor" {
                switch HarborURLHandoff.downloadURL(from: url) {
                case let .success(downloadURL):
                    supportedURLs.append(downloadURL)
                case let .failure(error):
                    errorMessages.append(error.localizedDescription)
                }
            } else {
                supportedURLs.append(contentsOf: DownloadSourceImportService.supportedURLs(from: [url]))
            }
        }

        guard supportedURLs.isEmpty == false || errorMessages.isEmpty == false else {
            return false
        }

        pendingURLs.append(contentsOf: supportedURLs)
        pendingErrorMessages.append(contentsOf: errorMessages)
        bringHarborToFront()
        drainPendingURLsIfNeeded()
        return true
    }

    func installHandler(_ handler: @escaping ([URL], [String]) -> Void) {
        self.handler = handler
        drainPendingURLsIfNeeded()
    }

    private func drainPendingURLsIfNeeded() {
        guard let handler,
              pendingURLs.isEmpty == false || pendingErrorMessages.isEmpty == false
        else {
            return
        }

        let urls = pendingURLs
        let errorMessages = pendingErrorMessages
        pendingURLs.removeAll()
        pendingErrorMessages.removeAll()
        handler(urls, errorMessages)
    }

    private func bringHarborToFront() {
        NSApp.activate(ignoringOtherApps: true)

        if let window = NSApp.windows.first(where: { $0.canBecomeMain }) ?? NSApp.windows.first {
            window.makeKeyAndOrderFront(nil)
        }
    }
}
