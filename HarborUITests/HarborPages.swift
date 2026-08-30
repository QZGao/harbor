import XCTest

@MainActor
struct HarborMainWindowPage {
    let app: XCUIApplication

    var window: XCUIElement { app.windows["Harbor"].firstMatch }
    var root: XCUIElement { app.descendants(matching: .any)["harbor.root"].firstMatch }
    var sidebar: XCUIElement { app.descendants(matching: .any)["harbor.sidebar"].firstMatch }
    var downloadsTable: XCUIElement { app.descendants(matching: .any)["downloads.table"].firstMatch }
    var newDownload: XCUIElement { app.buttons["toolbar.new-download"].firstMatch }
    var pauseResumeAll: XCUIElement { app.buttons["toolbar.pause-resume-all"].firstMatch }
    var search: XCUIElement { app.searchFields["Search downloads"].firstMatch }

    func filter(_ name: String) -> XCUIElement {
        app.descendants(matching: .any)["sidebar.filter.\(name)"].firstMatch
    }
}

@MainActor
struct HarborAddDownloadPage {
    let app: XCUIApplication

    var sheet: XCUIElement { app.descendants(matching: .any)["add-download.sheet"].firstMatch }
    var source: XCUIElement { app.textFields["add-download.source"].firstMatch }
    var startImmediately: XCUIElement { app.switches["add-download.start-immediately"].firstMatch }
    var paste: XCUIElement { app.buttons["add-download.paste"].firstMatch }
    var cancel: XCUIElement { app.buttons["add-download.cancel"].firstMatch }
    var preview: XCUIElement { app.buttons["add-download.preview"].firstMatch }
    var submit: XCUIElement { app.buttons["add-download.submit"].firstMatch }
    var tryAsMedia: XCUIElement { app.buttons["add-download.try-as-media"].firstMatch }
    var mediaPermission: XCUIElement { app.switches["add-download.media-permission"].firstMatch }
}

@MainActor
struct HarborDownloadTablePage {
    let app: XCUIApplication

    func name(_ value: String) -> XCUIElement { app.staticTexts[value].firstMatch }

    func status(_ value: String, downloadID: String) -> XCUIElement {
        app.descendants(matching: .any).matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@ AND (label == %@ OR value == %@)",
                "downloads.status.\(downloadID).",
                value,
                value
            )
        ).firstMatch
    }
}

@MainActor
struct HarborInspectorPage {
    let app: XCUIApplication

    var inspector: XCUIElement { app.descendants(matching: .any)["download.inspector"].firstMatch }
    var primaryAction: XCUIElement { app.buttons["download.inspector.primary-action"].firstMatch }
    var secondaryAction: XCUIElement { app.buttons["download.inspector.secondary-action"].firstMatch }
    var moreActions: XCUIElement { app.buttons["download.inspector.more-actions"].firstMatch }
}

@MainActor
struct HarborTorrentPreviewPage {
    let app: XCUIApplication

    var sheet: XCUIElement { app.descendants(matching: .any)["torrent-contents.sheet"].firstMatch }
    var table: XCUIElement { app.descendants(matching: .any)["torrent-contents.table"].firstMatch }
    var selectAll: XCUIElement { app.buttons["Select All"].firstMatch }
    var selectNone: XCUIElement { app.buttons["Select None"].firstMatch }
    var add: XCUIElement { app.sheets.element(boundBy: 1).buttons["Add Download"].firstMatch }
    var cancel: XCUIElement { app.sheets.element(boundBy: 1).buttons["Cancel"].firstMatch }
}

@MainActor
struct HarborBrowserPage {
    let app: XCUIApplication

    var sheet: XCUIElement { app.descendants(matching: .any)["browser-download.sheet"].firstMatch }
    var webView: XCUIElement { app.webViews["browser-download.web-view"].firstMatch }
    var cancel: XCUIElement { app.buttons["browser-download.cancel"].firstMatch }
}

@MainActor
struct HarborSettingsPage {
    let app: XCUIApplication

    var window: XCUIElement {
        app.windows.matching(NSPredicate(format: "title CONTAINS 'Settings'")).firstMatch
    }

    func tab(_ name: String) -> XCUIElement { app.buttons[name].firstMatch }
}
