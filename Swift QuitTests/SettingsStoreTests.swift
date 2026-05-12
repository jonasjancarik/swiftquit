//
//  SettingsStoreTests.swift
//  Swift QuitTests
//

import AppKit
import Foundation
import ServiceManagement
import XCTest
@testable import Swift_Quit

final class SettingsStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()

        suiteName = "SwiftQuitTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    @MainActor
    func testLegacySettingsMigrateCorrectly() {
        defaults.set([
            "launchAtLogin": "true",
            "menubarIconEnabled": "false",
            "excludeBehaviour": "includeApps",
            "launchHidden": "false",
            "closeDelay": "5",
        ], forKey: "SwiftQuitSettings")
        defaults.set(["/Applications/Test App.app"], forKey: "SwiftQuitExcludedApps")

        let store = SettingsStore(
            userDefaults: defaults,
            applicationCatalog: FakeApplicationCatalog()
        )

        XCTAssertTrue(store.settings.launchAtLoginEnabled)
        XCTAssertFalse(store.settings.menuBarIconEnabled)
        XCTAssertEqual(store.settings.ruleMode, .onlyIncluded)
        XCTAssertFalse(store.settings.launchHidden)
        XCTAssertEqual(store.settings.closeDelaySeconds, 5)
        XCTAssertEqual(store.settings.trackedApps.first?.bundleIdentifier, "com.example.TestApp")
    }

    @MainActor
    func testMigratedBundleIdentifiersRemainStableAfterAppMoves() throws {
        defaults.set([
            "excludeBehaviour": "includeApps",
        ], forKey: "SwiftQuitSettings")
        defaults.set(["/Applications/Test App.app"], forKey: "SwiftQuitExcludedApps")

        let store = SettingsStore(
            userDefaults: defaults,
            applicationCatalog: FakeApplicationCatalog()
        )

        let rule = try XCTUnwrap(store.settings.trackedApps.first)
        XCTAssertTrue(
            rule.matches(
                bundleIdentifier: "com.example.TestApp",
                bundleURL: URL(fileURLWithPath: "/Applications/Utilities/Test App.app")
            )
        )
    }

    @MainActor
    func testMigrationIsIdempotent() {
        defaults.set([
            "excludeBehaviour": "excludeApps",
        ], forKey: "SwiftQuitSettings")
        defaults.set(["/Applications/Test App.app"], forKey: "SwiftQuitExcludedApps")

        let firstStore = SettingsStore(
            userDefaults: defaults,
            applicationCatalog: FakeApplicationCatalog()
        )
        let secondStore = SettingsStore(
            userDefaults: defaults,
            applicationCatalog: FakeApplicationCatalog()
        )

        XCTAssertEqual(firstStore.settings, secondStore.settings)
    }

    @MainActor
    func testRecordedMigrationVersionPreventsReapplyingLegacyDefaults() {
        defaults.set([
            "launchAtLogin": "true",
        ], forKey: "SwiftQuitSettings")
        defaults.set(AppSettings.currentMigrationVersion, forKey: "SwiftQuitMigrationVersion")

        let store = SettingsStore(
            userDefaults: defaults,
            applicationCatalog: FakeApplicationCatalog()
        )

        XCTAssertEqual(store.settings, .default)
    }

    @MainActor
    func testVersionOneStoredSettingsGainDefaultSafetyOptions() throws {
        let storedSettingsWithoutSafetyOptions = """
        {
            "launchAtLoginEnabled": false,
            "menuBarIconEnabled": true,
            "launchHidden": true,
            "closeDelaySeconds": 2,
            "ruleMode": "allExceptExcluded",
            "safetyProfile": "balanced",
            "trackedApps": []
        }
        """
        defaults.set(Data(storedSettingsWithoutSafetyOptions.utf8), forKey: "SwiftQuitSettingsV2")

        let store = SettingsStore(
            userDefaults: defaults,
            applicationCatalog: FakeApplicationCatalog()
        )

        XCTAssertEqual(store.settings.safetyOptions, .default)
        XCTAssertEqual(defaults.integer(forKey: "SwiftQuitMigrationVersion"), AppSettings.currentMigrationVersion)
        let persistedData = try XCTUnwrap(defaults.data(forKey: "SwiftQuitSettingsV2"))
        let persistedSettings = try JSONDecoder().decode(AppSettings.self, from: persistedData)
        XCTAssertEqual(persistedSettings.safetyOptions, .default)
    }

    @MainActor
    func testLaunchAtLoginRequiresApprovalStateIsNotOverwrittenAfterToggle() {
        let client = FakeSettingsLoginItemClient()
        client.statusValue = .notRegistered
        client.registerError = makeSettingsServiceManagementError(
            code: kSMErrorLaunchDeniedByUser,
            description: "Approval required"
        )
        let viewModel = makeViewModel(loginItemClient: client)

        viewModel.launchAtLoginEnabled = true

        XCTAssertTrue(client.registerCalled)
        XCTAssertTrue(viewModel.launchAtLoginEnabled)
        XCTAssertEqual(viewModel.loginItemState, .requiresApproval)
    }

    @MainActor
    func testLaunchAtLoginErrorStateIsNotOverwrittenAfterToggle() {
        let client = FakeSettingsLoginItemClient()
        client.statusValue = .notRegistered
        client.registerError = NSError(
            domain: "SettingsStoreTests",
            code: 99,
            userInfo: [NSLocalizedDescriptionKey: "Disk said no"]
        )
        let viewModel = makeViewModel(loginItemClient: client)

        viewModel.launchAtLoginEnabled = true

        XCTAssertTrue(client.registerCalled)
        XCTAssertTrue(viewModel.launchAtLoginEnabled)
        XCTAssertEqual(viewModel.loginItemState, .error("macOS reported: Disk said no"))
    }

    @MainActor
    func testMigratedLaunchAtLoginDesiredStateRetriesRegistrationOnStartup() {
        defaults.set([
            "launchAtLogin": "true",
        ], forKey: "SwiftQuitSettings")

        let client = FakeSettingsLoginItemClient()
        client.statusValue = .notRegistered
        let viewModel = makeViewModel(loginItemClient: client)

        XCTAssertTrue(client.registerCalled)
        XCTAssertTrue(viewModel.launchAtLoginEnabled)
        XCTAssertEqual(viewModel.loginItemState, .enabled)
    }

    @MainActor
    private func makeViewModel(loginItemClient: FakeSettingsLoginItemClient) -> SettingsViewModel {
        let store = SettingsStore(
            userDefaults: defaults,
            applicationCatalog: FakeApplicationCatalog()
        )
        let loginItemController = LoginItemController(client: loginItemClient)

        return SettingsViewModel(
            settingsStore: store,
            applicationCatalog: FakeApplicationCatalog(),
            permissionController: AccessibilityPermissionController(),
            loginItemController: loginItemController,
            terminationDiagnostics: TerminationDiagnostics(),
            appInfo: AppInfo(displayName: "Swift Quit", version: "1", build: "1", icon: NSImage()),
            applyMenuBarVisibility: { _ in },
            refreshAccessibilityState: { _, _ in }
        )
    }
}

@MainActor
private final class FakeApplicationCatalog: ApplicationCataloging {
    func chooseApplication() -> TrackedAppRule? {
        nil
    }

    func trackedRule(for bundleURL: URL) -> TrackedAppRule? {
        TrackedAppRule(
            bundleIdentifier: "com.example.TestApp",
            bundleURL: bundleURL.standardizedFileURL,
            displayName: "Test App"
        )
    }

    func resolvedRule(for rule: TrackedAppRule) -> ResolvedTrackedAppRule {
        ResolvedTrackedAppRule(
            rule: rule,
            displayName: rule.displayName,
            bundleIdentifier: rule.bundleIdentifier,
            resolvedURL: rule.bundleURL,
            secondaryText: rule.bundleIdentifier,
            icon: NSImage()
        )
    }
}

@MainActor
private final class FakeSettingsLoginItemClient: LoginItemClient {
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

        statusValue = .enabled
    }

    func unregister() throws {
        unregisterCalled = true
        if let unregisterError {
            throw unregisterError
        }

        statusValue = .notRegistered
    }

    func openSystemSettings() {}
}

private func makeSettingsServiceManagementError(code: Int, description: String) -> NSError {
    NSError(
        domain: SMAppServiceErrorDomain,
        code: code,
        userInfo: [NSLocalizedDescriptionKey: description]
    )
}

@MainActor
final class SettingsPresentationPolicyTests: XCTestCase {
    func testDefaultLaunchWithEnabledLoginItemClassifiesAsManual() {
        let classifier = LaunchSourceClassifier()

        XCTAssertEqual(
            classifier.classify(isDefaultLaunch: true),
            .manual
        )
    }

    func testConfirmedBackgroundLaunchClassifiesAsBackground() {
        let classifier = LaunchSourceClassifier()

        XCTAssertEqual(
            classifier.classify(isDefaultLaunch: true, isConfirmedBackgroundLaunch: true),
            .background
        )
    }

    func testDefaultLaunchWithoutLoginItemClassifiesAsManual() {
        let classifier = LaunchSourceClassifier()

        XCTAssertEqual(
            classifier.classify(isDefaultLaunch: true),
            .manual
        )
    }

    func testNonDefaultLaunchClassifiesAsManual() {
        let classifier = LaunchSourceClassifier()

        XCTAssertEqual(
            classifier.classify(isDefaultLaunch: false),
            .manual
        )
    }

    func testMissingLaunchFlagClassifiesAsUnknown() {
        let classifier = LaunchSourceClassifier()

        XCTAssertEqual(
            classifier.classify(isDefaultLaunch: nil),
            .unknown
        )
    }

    func testNotificationLaunchClassificationReadsDefaultLaunchFlag() {
        let classifier = LaunchSourceClassifier()
        let notification = Notification(
            name: NSApplication.didFinishLaunchingNotification,
            object: nil,
            userInfo: [NSApplication.launchIsDefaultUserInfoKey: NSNumber(value: true)]
        )

        XCTAssertEqual(
            classifier.classify(notification: notification),
            .manual
        )
    }

    func testTrustedAccessibilityStartupWiresTerminationBeforeStartingMonitor() {
        let policy = AccessibilityMonitoringStartupPolicy()

        XCTAssertEqual(
            policy.actions(isTrusted: true),
            [.wireTerminationHandling, .refreshTrustedState(true)]
        )
    }

    func testUntrustedAccessibilityStartupOnlyRefreshesMonitorState() {
        let policy = AccessibilityMonitoringStartupPolicy()

        XCTAssertEqual(policy.actions(isTrusted: false), [.refreshTrustedState(false)])
    }

    func testActivationPolicyRestorationRestoresPreviousPolicy() {
        let restoration = ActivationPolicyRestoration(previousPolicy: .accessory)

        XCTAssertEqual(restoration.policyToRestore(after: .regular), .accessory)
        XCTAssertNil(restoration.policyToRestore(after: .accessory))
    }

    func testManualColdLaunchAlwaysPresentsSettings() {
        let policy = SettingsPresentationPolicy()
        var settings = AppSettings.default
        settings.launchHidden = true
        settings.menuBarIconEnabled = true

        XCTAssertTrue(
            policy.shouldPresentSettings(
                for: .coldLaunch(source: .manual),
                settings: settings,
                isAccessibilityTrusted: true
            )
        )
    }

    func testUnknownColdLaunchDefaultsToPresentingSettings() {
        let policy = SettingsPresentationPolicy()
        var settings = AppSettings.default
        settings.launchHidden = true
        settings.menuBarIconEnabled = true

        XCTAssertTrue(
            policy.shouldPresentSettings(
                for: .coldLaunch(source: .unknown),
                settings: settings,
                isAccessibilityTrusted: true
            )
        )
    }

    func testBackgroundColdLaunchCanStayHiddenWhenSystemStateIsHealthy() {
        let policy = SettingsPresentationPolicy()
        var settings = AppSettings.default
        settings.launchHidden = true
        settings.menuBarIconEnabled = true

        XCTAssertFalse(
            policy.shouldPresentSettings(
                for: .coldLaunch(source: .background),
                settings: settings,
                isAccessibilityTrusted: true
            )
        )
    }

    func testBackgroundColdLaunchPresentsSettingsWhenAccessibilityIsMissing() {
        let policy = SettingsPresentationPolicy()
        XCTAssertTrue(
            policy.shouldPresentSettings(
                for: .coldLaunch(source: .background),
                settings: .default,
                isAccessibilityTrusted: false
            )
        )
    }

    func testBackgroundColdLaunchPresentsSettingsWhenAutomaticLaunchHidingIsDisabled() {
        let policy = SettingsPresentationPolicy()
        var settings = AppSettings.default
        settings.launchHidden = false

        XCTAssertTrue(
            policy.shouldPresentSettings(
                for: .coldLaunch(source: .background),
                settings: settings,
                isAccessibilityTrusted: true
            )
        )
    }

    func testBackgroundColdLaunchPresentsSettingsWhenMenuBarIconIsHidden() {
        let policy = SettingsPresentationPolicy()
        var settings = AppSettings.default
        settings.menuBarIconEnabled = false

        XCTAssertTrue(
            policy.shouldPresentSettings(
                for: .coldLaunch(source: .background),
                settings: settings,
                isAccessibilityTrusted: true
            )
        )
    }

    func testAccessibilityPromptPolicyPromptsForMissingPermissionOnVisibleColdLaunch() {
        let policy = AccessibilityLaunchPromptPolicy()

        XCTAssertTrue(
            policy.shouldPromptForMissingPermissionOnLaunch(
                for: .coldLaunch(source: .background),
                settings: .default,
                isAccessibilityTrusted: false,
                isRunningUnitTests: false
            )
        )
    }

    func testAccessibilityPromptPolicyDoesNotPromptWhenTrusted() {
        let policy = AccessibilityLaunchPromptPolicy()

        XCTAssertFalse(
            policy.shouldPromptForMissingPermissionOnLaunch(
                for: .coldLaunch(source: .manual),
                settings: .default,
                isAccessibilityTrusted: true,
                isRunningUnitTests: false
            )
        )
    }

    func testAccessibilityPromptPolicyDoesNotPromptDuringUnitTests() {
        let policy = AccessibilityLaunchPromptPolicy()

        XCTAssertFalse(
            policy.shouldPromptForMissingPermissionOnLaunch(
                for: .coldLaunch(source: .manual),
                settings: .default,
                isAccessibilityTrusted: false,
                isRunningUnitTests: true
            )
        )
    }

    func testActivationDoesNotPresentSettings() {
        let policy = SettingsPresentationPolicy()
        XCTAssertFalse(policy.shouldPresentSettings(for: .activation, settings: .default, isAccessibilityTrusted: true))
    }

    func testReopenStillPresentsSettings() {
        let policy = SettingsPresentationPolicy()
        XCTAssertTrue(policy.shouldPresentSettings(for: .reopen, settings: .default, isAccessibilityTrusted: true))
    }
}

final class RuntimeEnvironmentTests: XCTestCase {
    func testRuntimeEnvironmentDetectsXCTestConfigurationPath() {
        XCTAssertTrue(
            RuntimeEnvironment.isRunningUnitTests(
                environment: ["XCTestConfigurationFilePath": "/tmp/tests.xctestconfiguration"],
                classLookup: { _ in nil }
            )
        )
    }

    func testRuntimeEnvironmentDetectsXCTestSessionIdentifier() {
        XCTAssertTrue(
            RuntimeEnvironment.isRunningUnitTests(
                environment: ["XCTestSessionIdentifier": UUID().uuidString],
                classLookup: { _ in nil }
            )
        )
    }

    func testRuntimeEnvironmentDetectsLoadedXCTestClass() {
        XCTAssertTrue(
            RuntimeEnvironment.isRunningUnitTests(
                environment: [:],
                classLookup: { name in name == "XCTest.XCTestCase" ? NSObject.self : nil }
            )
        )
    }

    func testRuntimeEnvironmentIgnoresNormalProcess() {
        XCTAssertFalse(
            RuntimeEnvironment.isRunningUnitTests(
                environment: [:],
                classLookup: { _ in nil }
            )
        )
    }
}
