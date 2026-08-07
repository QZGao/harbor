import Foundation
import XCTest
@testable import Harbor

final class BatchAddDownloadTests: XCTestCase {
    func testSupportedURLsFromTextParsesOnePerLine() {
        let text = """
        https://example.com/a.zip
        https://example.com/b.dmg
        magnet:?xt=urn:btih:abcdef
        """

        let urls = DownloadSourceImportService.supportedURLs(fromText: text)

        XCTAssertEqual(
            urls.map(\.absoluteString),
            [
                "https://example.com/a.zip",
                "https://example.com/b.dmg",
                "magnet:?xt=urn:btih:abcdef"
            ]
        )
    }

    func testSupportedURLsFromTextSkipsBlanksAndDuplicatesAndJunk() {
        let text = """
        https://example.com/a.zip

        not a url at all
        https://example.com/a.zip
        https://example.com/b.zip
        """

        let urls = DownloadSourceImportService.supportedURLs(fromText: text)

        XCTAssertEqual(
            urls.map(\.absoluteString),
            [
                "https://example.com/a.zip",
                "https://example.com/b.zip"
            ]
        )
    }

    func testBatchRequestsShareDestinationAndStartBehavior() {
        let destination = URL(fileURLWithPath: "/tmp/harbor-batch", isDirectory: true)
        let urls = [
            URL(string: "https://example.com/a.zip")!,
            URL(string: "magnet:?xt=urn:btih:abcdef")!,
            URL(string: "https://example.com/linux.torrent")!
        ]

        let requests = AddDownloadRequest.batch(
            from: urls,
            destinationFolder: destination,
            shouldStartImmediately: false
        )

        XCTAssertEqual(requests.count, 3)
        XCTAssertTrue(requests.allSatisfy { $0.destinationFolder == destination })
        XCTAssertTrue(requests.allSatisfy { $0.shouldStartImmediately == false })
        XCTAssertTrue(requests.allSatisfy { $0.customFilename == nil })

        XCTAssertEqual(requests[0].sourceKind, .directURL)
        XCTAssertEqual(requests[1].sourceKind, .magnetLink)
        XCTAssertEqual(requests[2].sourceKind, .torrentFile)
    }

    func testBatchRequestsDropUnsupportedURLs() {
        let destination = URL(fileURLWithPath: "/tmp/harbor-batch", isDirectory: true)
        let urls = [
            URL(string: "https://example.com/a.zip")!,
            URL(string: "ftp://example.com/legacy")!
        ]

        let requests = AddDownloadRequest.batch(
            from: urls,
            destinationFolder: destination,
            shouldStartImmediately: true
        )

        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.sourceURL.absoluteString, "https://example.com/a.zip")
    }
}
