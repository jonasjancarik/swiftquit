//
//  LoginItemControllerTests.swift
//  Swift QuitTests
//

import Foundation
import ServiceManagement
import XCTest
@testable import Swift_Quit

final class LoginItemControllerTests: XCTestCase {
    @MainActor
    func testRefreshReflectsCurrentStatus() {
        let client = FakeLoginItemClient()
        client.statusValue = .enabled

        let controller = LoginItemController(client: client)
        XCTAssertEqual(controller.state, .enabled)

        client.statusValue = .requiresApproval
        controller.refresh()

        XCTAssertEqual(controller.state, .requiresApproval)
    }

    @MainActor
    func testEnableRegistersClient() {
        let client = FakeLoginItemClient()
        client.statusValue = .enabled

        let controller = LoginItemController(client: client)
        controller.setEnabled(true)

        XCTAssertTrue(client.registerCalled)
        XCTAssertEqual(controller.state, .enabled)
    }

    @MainActor
    func testAlreadyRegisteredRefreshesToEnabledState() {
        let client = FakeLoginItemClient()
        client.statusValue = .enabled
        client.registerError = makeServiceManagementError(code: kSMErrorAlreadyRegistered, description: "Already registered")

        let controller = LoginItemController(client: client)
        controller.setEnabled(true)

        XCTAssertTrue(client.registerCalled)
        XCTAssertEqual(controller.state, .enabled)
    }

    @MainActor
    func testLaunchDeniedByUserMapsToRequiresApproval() {
        let client = FakeLoginItemClient()
        client.registerError = makeServiceManagementError(code: kSMErrorLaunchDeniedByUser, description: "Approval required")

        let controller = LoginItemController(client: client)
        controller.setEnabled(true)

        XCTAssertEqual(controller.state, .requiresApproval)
    }

    @MainActor
    func testUnregisterNotFoundRefreshesToDisabledState() {
        let client = FakeLoginItemClient()
        client.statusValue = .notRegistered
        client.unregisterError = makeServiceManagementError(code: kSMErrorJobNotFound, description: "Missing job")

        let controller = LoginItemController(client: client)
        controller.setEnabled(false)

        XCTAssertTrue(client.unregisterCalled)
        XCTAssertEqual(controller.state, .notRegistered)
    }

    @MainActor
    func testUnknownErrorsAreSurfacedAsRecoveryState() {
        let client = FakeLoginItemClient()
        client.registerError = NSError(domain: "Test", code: 7, userInfo: [NSLocalizedDescriptionKey: "Nope"])

        let controller = LoginItemController(client: client)
        controller.setEnabled(true)

        XCTAssertEqual(controller.state, .error("macOS reported: Nope"))
        XCTAssertTrue(controller.state.detail.contains("Open Login Items in System Settings"))
    }

    @MainActor
    func testRequiresApprovalStateStillReadsAsEnabled() {
        let client = FakeLoginItemClient()
        client.statusValue = .requiresApproval

        let controller = LoginItemController(client: client)
        XCTAssertEqual(controller.state, .requiresApproval)
        XCTAssertTrue(controller.isEnabled)
    }

    @MainActor
    func testNotFoundStatusMapsToAttentionState() {
        let client = FakeLoginItemClient()
        client.statusValue = .notFound

        let controller = LoginItemController(client: client)
        XCTAssertEqual(controller.state, .notFound)
        XCTAssertTrue(controller.state.requiresAttention)
    }
}

@MainActor
private final class FakeLoginItemClient: LoginItemClient {
    var statusValue: SMAppService.Status = .notRegistered
    var registerCalled = false
    var unregisterCalled = false
    var registerError: Error?
    var unregisterError: Error?

    var status: SMAppService.Status {
        statusValue
    }

    func register() throws {
        registerCalled = true
        if let registerError {
            throw registerError
        }
    }

    func unregister() throws {
        unregisterCalled = true
        if let unregisterError {
            throw unregisterError
        }
    }

    func openSystemSettings() {}
}

private func makeServiceManagementError(code: Int, description: String) -> NSError {
    NSError(
        domain: SMAppServiceErrorDomain,
        code: code,
        userInfo: [NSLocalizedDescriptionKey: description]
    )
}
