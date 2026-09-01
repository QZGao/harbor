import Foundation
import XCTest

private struct LiveMediaCase: Decodable {
    enum Operation: String, Decodable {
        case metadata
        case download
    }

    let id: String
    let platform: String
    let url: URL
    let expectedExtractor: String
    let expectedMediaType: String
    let operation: Operation
    let lastVerifiedAt: String?
}

@MainActor
final class HarborLiveCanaryUITests: HarborUITestCase {
    override func setUpWithError() throws {
        guard ProcessInfo.processInfo.environment["HARBOR_UI_ALLOW_LIVE_NETWORK"] == "YES" else {
            throw XCTSkip("Set HARBOR_UI_ALLOW_LIVE_NETWORK=YES to run public live-link canaries.")
        }
        try super.setUpWithError()
    }

    func testPublicMediaCanaries() throws {
        continueAfterFailure = true
        let cases = try loadCases()
        XCTAssertEqual(Set(cases.map(\.platform)).count, 12)

        launchHarbor()
        for mediaCase in cases {
            XCTContext.runActivity(named: "\(mediaCase.platform): \(mediaCase.id)") { activity in
                openAddSheet()
                let source = app.textFields["add-download.source"].firstMatch
                source.click()
                source.typeText(mediaCase.url.absoluteString)

                let permission = app.switches["add-download.media-permission"].firstMatch
                guard permission.waitForExistence(timeout: 120) else {
                    let diagnostics = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
                    diagnostics.name = "\(mediaCase.platform) preview failure"
                    diagnostics.lifetime = .keepAlways
                    activity.add(diagnostics)
                    XCTFail(
                        "\(mediaCase.platform) did not produce media metadata. Expected extractor " +
                        "\(mediaCase.expectedExtractor), type \(mediaCase.expectedMediaType), " +
                        "last verified \(mediaCase.lastVerifiedAt ?? "not yet verified locally")."
                    )
                    if app.buttons["add-download.cancel"].exists {
                        app.buttons["add-download.cancel"].click()
                    }
                    return
                }

                let metadata = app.descendants(matching: .any)["add-download.media-metadata"].firstMatch
                XCTAssertTrue(metadata.waitForExistence(timeout: 5), "Media metadata was not exposed to UI tests.")
                XCTAssertEqual(
                    metadata.value as? String,
                    "extractor=\(mediaCase.expectedExtractor);type=\(mediaCase.expectedMediaType)"
                )

                if mediaCase.operation == .download {
                    let existingDownloads = downloadReferences()
                    app.buttons["add-download.submit"].click()
                    let download = waitForNewDownload(excluding: existingDownloads)
                    waitForStatus("Completed", download: download, timeout: 180)
                } else {
                    app.buttons["add-download.cancel"].click()
                }
            }
        }
    }

    private func loadCases() throws -> [LiveMediaCase] {
        let bundle = Bundle(for: Self.self)
        let url = try XCTUnwrap(bundle.url(forResource: "live-links", withExtension: "json"))
        return try JSONDecoder().decode([LiveMediaCase].self, from: Data(contentsOf: url))
    }
}
