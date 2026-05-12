//
//  LoginItemController.swift
//  Swift Quit
//

import Foundation
import ServiceManagement

protocol LoginItemClient {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
    func openSystemSettings()
}

struct SystemLoginItemClient: LoginItemClient {
    private var service: SMAppService { .mainApp }

    var status: SMAppService.Status {
        service.status
    }

    func register() throws {
        try service.register()
    }

    func unregister() throws {
        try service.unregister()
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

private enum LoginItemOperation {
    case register
    case unregister
}

private struct LoginItemServiceError {
    let code: Int

    init?(error: Error) {
        let nsError = error as NSError
        guard nsError.domain == SMAppServiceErrorDomain else {
            return nil
        }

        code = nsError.code
    }
}

enum LoginItemState: Equatable {
    case enabled
    case notRegistered
    case requiresApproval
    case notFound
    case error(String)

    var title: String {
        switch self {
        case .enabled:
            "Enabled"
        case .notRegistered:
            "Disabled"
        case .requiresApproval:
            "Needs Approval"
        case .notFound:
            "Unavailable"
        case .error:
            "Error"
        }
    }

    var detail: String {
        switch self {
        case .enabled:
            "Swift Quit is configured to launch at login."
        case .notRegistered:
            "Swift Quit is not configured to launch at login."
        case .requiresApproval:
            "macOS needs approval in Login Items before Swift Quit can launch automatically."
        case .notFound:
            "macOS could not find the login item registration."
        case .error(let message):
            "Swift Quit couldn't update launch at login automatically. Open Login Items in System Settings, then try again. \(message)"
        }
    }

    var isEnabled: Bool {
        switch self {
        case .enabled, .requiresApproval:
            true
        case .notRegistered, .notFound, .error:
            false
        }
    }

    var requiresAttention: Bool {
        switch self {
        case .requiresApproval, .notFound, .error:
            true
        case .enabled, .notRegistered:
            false
        }
    }
}

@MainActor
final class LoginItemController {
    private let client: LoginItemClient

    private(set) var state: LoginItemState

    init(client: LoginItemClient = SystemLoginItemClient()) {
        self.client = client
        self.state = Self.mapStatus(client.status)
    }

    var isEnabled: Bool {
        state.isEnabled
    }

    func refresh() {
        state = Self.mapStatus(client.status)
    }

    func setEnabled(_ isEnabled: Bool) {
        do {
            if isEnabled {
                try client.register()
            } else {
                try client.unregister()
            }

            refresh()
        } catch {
            let operation: LoginItemOperation = isEnabled ? .register : .unregister

            if handleKnownError(error, operation: operation) {
                return
            }

            AppLoggers.loginItem.error("Failed to update login item: \(error.localizedDescription, privacy: .public)")
            state = .error("macOS reported: \(error.localizedDescription)")
        }
    }

    func openSystemSettings() {
        client.openSystemSettings()
    }

    private static func mapStatus(_ status: SMAppService.Status) -> LoginItemState {
        switch status {
        case .enabled:
            .enabled
        case .notRegistered:
            .notRegistered
        case .requiresApproval:
            .requiresApproval
        case .notFound:
            .notFound
        @unknown default:
            .error("Swift Quit encountered an unknown login item state.")
        }
    }

    private func handleKnownError(_ error: Error, operation: LoginItemOperation) -> Bool {
        guard let serviceError = LoginItemServiceError(error: error) else {
            return false
        }

        switch (operation, serviceError.code) {
        case (.register, kSMErrorAlreadyRegistered):
            AppLoggers.loginItem.notice("Login item was already registered; refreshing state")
            refresh()
            return true

        case (.register, kSMErrorLaunchDeniedByUser):
            AppLoggers.loginItem.notice("Login item registration requires user approval")
            state = .requiresApproval
            return true

        case (.unregister, kSMErrorJobNotFound):
            AppLoggers.loginItem.notice("Login item was already unregistered; refreshing state")
            refresh()
            return true

        default:
            return false
        }
    }
}
