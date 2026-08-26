import Foundation

enum HarborURLHandoffError: LocalizedError, Equatable, Sendable {
    case unsupportedAction
    case missingDownloadURL
    case invalidDownloadURL
    case unsupportedDownloadScheme

    nonisolated var errorDescription: String? {
        switch self {
        case .unsupportedAction:
            "This Harbor link does not contain a supported action. Use harbor://download?url=…"
        case .missingDownloadURL:
            "This Harbor link does not include a download URL."
        case .invalidDownloadURL:
            "The download URL in this Harbor link is malformed."
        case .unsupportedDownloadScheme:
            "Harbor handoff links support only HTTP and HTTPS download URLs."
        }
    }
}

enum HarborURLHandoff {
    nonisolated static func downloadURL(from handoffURL: URL) -> Result<URL, HarborURLHandoffError> {
        guard handoffURL.scheme?.lowercased() == "harbor",
              let components = URLComponents(url: handoffURL, resolvingAgainstBaseURL: false)
        else {
            return .failure(.unsupportedAction)
        }

        let pathAction = components.path
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .lowercased()
        let hostAction = components.host?.lowercased()
        let action = (hostAction?.isEmpty == false ? hostAction : nil) ?? pathAction
        guard action == "download" else {
            return .failure(.unsupportedAction)
        }

        // TODO: Add optional filename or destination parameters only when an integration needs them.

        guard let encodedDownloadURL = components.queryItems?
            .first(where: { $0.name == "url" })?
            .value,
            encodedDownloadURL.isEmpty == false
        else {
            return .failure(.missingDownloadURL)
        }

        guard let downloadComponents = URLComponents(string: encodedDownloadURL),
              let scheme = downloadComponents.scheme?.lowercased()
        else {
            return .failure(.invalidDownloadURL)
        }

        guard scheme == "http" || scheme == "https" else {
            return .failure(.unsupportedDownloadScheme)
        }

        guard downloadComponents.host?.isEmpty == false,
              let downloadURL = downloadComponents.url
        else {
            return .failure(.invalidDownloadURL)
        }

        return .success(downloadURL)
    }
}
