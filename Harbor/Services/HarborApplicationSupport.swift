import Foundation

enum HarborApplicationSupport {
    nonisolated static var isRunningUnitTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    nonisolated static func directoryURL(fileManager: FileManager = .default) -> URL {
        let rootURL = overrideURL()
            ?? unitTestRootURL(fileManager: fileManager)
            ?? (try? fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            ))
            ?? fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)

        return rootURL.appendingPathComponent("Harbor", isDirectory: true)
    }

    private nonisolated static func unitTestRootURL(fileManager: FileManager) -> URL? {
        guard isRunningUnitTests else {
            return nil
        }

        // Keep the application test host from reading or rewriting a user's live Harbor state.
        return fileManager.temporaryDirectory.appendingPathComponent(
            "HarborTests-\(ProcessInfo.processInfo.processIdentifier)",
            isDirectory: true
        )
    }

    private nonisolated static func overrideURL() -> URL? {
        if let path = nonBlankPath(ProcessInfo.processInfo.environment["HARBOR_APPLICATION_SUPPORT_DIR"]) {
            return URL(fileURLWithPath: path, isDirectory: true)
        }

        guard let index = CommandLine.arguments.firstIndex(of: "--harbor-application-support-directory") else {
            return nil
        }

        let valueIndex = CommandLine.arguments.index(after: index)
        guard CommandLine.arguments.indices.contains(valueIndex),
              let path = nonBlankPath(CommandLine.arguments[valueIndex]) else {
            return nil
        }

        // TODO: Keep this CLI hook for release smoke tests until Harbor has a formal UI test target.
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private nonisolated static func nonBlankPath(_ path: String?) -> String? {
        let trimmed = path?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}
