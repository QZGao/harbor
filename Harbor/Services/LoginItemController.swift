import ServiceManagement

enum LoginItemStatus: Equatable {
    case disabled
    case enabled
    case requiresApproval
    case unavailable
}

protocol LoginItemControlling {
    var status: LoginItemStatus { get }
    func setEnabled(_ isEnabled: Bool) throws
}

struct SystemLoginItemController: LoginItemControlling {
    var status: LoginItemStatus {
        switch SMAppService.mainApp.status {
        case .notRegistered:
            .disabled
        case .enabled:
            .enabled
        case .requiresApproval:
            .requiresApproval
        case .notFound:
            .unavailable
        @unknown default:
            .unavailable
        }
    }

    func setEnabled(_ isEnabled: Bool) throws {
        if isEnabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
