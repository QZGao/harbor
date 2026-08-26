import Foundation
import XCTest
@testable import Harbor

final class HarborURLHandoffTests: XCTestCase {
    func testDownloadHandoffDecodesHTTPURL() throws {
        let handoffURL = try XCTUnwrap(
            URL(string: "harbor://download?url=https%3A%2F%2Fexample.com%2Ffile.zip%3Ftoken%3Dabc")
        )

        let downloadURL = try HarborURLHandoff.downloadURL(from: handoffURL).get()

        XCTAssertEqual(downloadURL.absoluteString, "https://example.com/file.zip?token=abc")
    }

    func testDownloadHandoffAlsoAcceptsPathAction() throws {
        let handoffURL = try XCTUnwrap(
            URL(string: "harbor:///download?url=http%3A%2F%2Fexample.com%2Farchive.zip")
        )

        let downloadURL = try HarborURLHandoff.downloadURL(from: handoffURL).get()

        XCTAssertEqual(downloadURL.absoluteString, "http://example.com/archive.zip")
    }

    func testDownloadHandoffRejectsMissingURL() throws {
        let handoffURL = try XCTUnwrap(URL(string: "harbor://download"))

        XCTAssertThrowsError(try HarborURLHandoff.downloadURL(from: handoffURL).get()) { error in
            XCTAssertEqual(error as? HarborURLHandoffError, .missingDownloadURL)
        }
    }

    func testDownloadHandoffRejectsUnsupportedTargetScheme() throws {
        let handoffURL = try XCTUnwrap(
            URL(string: "harbor://download?url=ftp%3A%2F%2Fexample.com%2Farchive.zip")
        )

        XCTAssertThrowsError(try HarborURLHandoff.downloadURL(from: handoffURL).get()) { error in
            XCTAssertEqual(error as? HarborURLHandoffError, .unsupportedDownloadScheme)
        }
    }

    func testDownloadHandoffRejectsMalformedTargetURL() throws {
        let handoffURL = try XCTUnwrap(
            URL(string: "harbor://download?url=not-a-url")
        )

        XCTAssertThrowsError(try HarborURLHandoff.downloadURL(from: handoffURL).get()) { error in
            XCTAssertEqual(error as? HarborURLHandoffError, .invalidDownloadURL)
        }
    }

    func testDownloadHandoffRejectsUnknownAction() throws {
        let handoffURL = try XCTUnwrap(
            URL(string: "harbor://queue?url=https%3A%2F%2Fexample.com%2Ffile.zip")
        )

        XCTAssertThrowsError(try HarborURLHandoff.downloadURL(from: handoffURL).get()) { error in
            XCTAssertEqual(error as? HarborURLHandoffError, .unsupportedAction)
        }
    }
}
