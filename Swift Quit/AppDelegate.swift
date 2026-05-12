//
//  AppDelegate.swift
//  Swift Quit
//

import AppKit

enum LaunchSource: String {
    case manual
    case background
    case unknown
}

struct LaunchSourceClassifier {
    func classify(isDefaultLaunch: Bool?, isConfirmedBackgroundLaunch: Bool = false) -> LaunchSource {
        if isConfirmedBackgroundLaunch {
            return .background
        }

        guard isDefaultLaunch != nil else {
            return .unknown
        }

        return .manual
    }

    func classify(notification: Notification, isConfirmedBackgroundLaunch: Bool = false) -> LaunchSource {
        let isDefaultLaunch = (notification.userInfo?[NSApplication.launchIsDefaultUserInfoKey] as? NSNumber)?.boolValue
        return classify(isDefaultLaunch: isDefaultLaunch, isConfirmedBackgroundLaunch: isConfirmedBackgroundLaunch)
    }
}

enum SettingsPresentationTrigger {
    case coldLaunch(source: LaunchSource)
    case activation
    case reopen
    case menuBar

    var logDescription: String {
        switch self {
        case .coldLaunch(let source):
            "coldLaunch(\(source.rawValue))"
        case .activation:
            "activation"
        case .reopen:
            "reopen"
        case .menuBar:
            "menuBar"
        }
    }
}

struct SettingsPresentationPolicy {
    nonisolated func shouldPresentSettings(
        for trigger: SettingsPresentationTrigger,
        settings: AppSettings,
        isAccessibilityTrusted: Bool
    ) -> Bool {
        switch trigger {
        case .coldLaunch(.manual), .coldLaunch(.unknown):
            true
        case .coldLaunch(.background):
            !isAccessibilityTrusted || !settings.launchHidden || !settings.menuBarIconEnabled
        case .activation:
            false
        case .reopen, .menuBar:
            true
        }
    }
}

struct AccessibilityLaunchPromptPolicy {
    private let settingsPresentationPolicy = SettingsPresentationPolicy()

    func shouldPromptForMissingPermissionOnLaunch(
        for trigger: SettingsPresentationTrigger,
        settings: AppSettings,
        isAccessibilityTrusted: Bool,
        isRunningUnitTests: Bool
    ) -> Bool {
        guard !isRunningUnitTests, !isAccessibilityTrusted else {
            return false
        }

        guard case .coldLaunch = trigger else {
            return false
        }

        return settingsPresentationPolicy.shouldPresentSettings(
            for: trigger,
            settings: settings,
            isAccessibilityTrusted: isAccessibilityTrusted
        )
    }
}

enum AccessibilityMonitoringStartupAction: Equatable {
    case wireTerminationHandling
    case refreshTrustedState(Bool)
}

struct AccessibilityMonitoringStartupPolicy {
    nonisolated func actions(isTrusted: Bool) -> [AccessibilityMonitoringStartupAction] {
        if isTrusted {
            return [.wireTerminationHandling, .refreshTrustedState(true)]
        }

        return [.refreshTrustedState(false)]
    }
}

struct RuntimeEnvironment {
    let isRunningUnitTests: Bool

    nonisolated static var current: RuntimeEnvironment {
        RuntimeEnvironment(
            isRunningUnitTests: isRunningUnitTests(
                environment: ProcessInfo.processInfo.environment,
                classLookup: NSClassFromString
            )
        )
    }

    nonisolated static func isRunningUnitTests(
        environment: [String: String],
        classLookup: (String) -> AnyClass?
    ) -> Bool {
        environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestSessionIdentifier"] != nil
            || classLookup("XCTest.XCTestCase") != nil
    }
}

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static var sharedDelegate: AppDelegate?

    private let runtimeEnvironment: RuntimeEnvironment
    private let launchSourceClassifier = LaunchSourceClassifier()
    private let settingsPresentationPolicy = SettingsPresentationPolicy()
    private let accessibilityLaunchPromptPolicy = AccessibilityLaunchPromptPolicy()
    private let accessibilityMonitoringStartupPolicy = AccessibilityMonitoringStartupPolicy()

    private lazy var applicationCatalog = ApplicationCatalog()
    private lazy var settingsStore = SettingsStore(applicationCatalog: applicationCatalog)
    private lazy var permissionController = AccessibilityPermissionController()
    private lazy var loginItemController = LoginItemController()
    private lazy var accessibilityMonitor = AccessibilityMonitor()
    private lazy var terminationDiagnostics = TerminationDiagnostics()
    private lazy var terminationController = TerminationController(
        settingsStore: settingsStore,
        monitor: accessibilityMonitor,
        engine: TerminationEngine(
            protectedBundleIdentifiers: ApplicationCatalog.protectedBundleIdentifiers,
            browserHostBundleIdentifiers: ApplicationCatalog.browserHostBundleIdentifiers,
            browserWebAppBundleIdentifierPrefixes: ApplicationCatalog.browserWebAppBundleIdentifierPrefixes
        ),
        diagnostics: terminationDiagnostics
    )

    private lazy var settingsViewModel = SettingsViewModel(
        settingsStore: settingsStore,
        applicationCatalog: applicationCatalog,
        permissionController: permissionController,
        loginItemController: loginItemController,
        terminationDiagnostics: terminationDiagnostics,
        appInfo: .current,
        applyMenuBarVisibility: { [weak self] isVisible in
            self?.menuBarController.setVisible(isVisible)
        },
        refreshAccessibilityState: { [weak self] promptIfNeeded, presentAlert in
            self?.refreshAccessibilityState(promptIfNeeded: promptIfNeeded, presentAlert: presentAlert)
        }
    )

    private lazy var settingsWindowController = SettingsWindowController(viewModel: settingsViewModel)

    private lazy var menuBarController = MenuBarController(
        openSettingsAction: { [weak self] in
            self?.presentSettings(for: .menuBar)
        },
        openDiagnosticsAction: { [weak self] in
            self?.presentSettings(for: .menuBar)
        },
        togglePauseAction: { [weak self] in
            guard let self else {
                return false
            }

            let newPausedState = !terminationController.isPaused
            terminationController.setPaused(newPausedState)
            return newPausedState
        },
        terminateAction: {
            NSApp.terminate(nil)
        }
    )

    init(runtimeEnvironment: RuntimeEnvironment = .current) {
        self.runtimeEnvironment = runtimeEnvironment

        super.init()
    }

    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        sharedDelegate = delegate
        application.delegate = delegate
        application.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !runtimeEnvironment.isRunningUnitTests else {
            AppLoggers.app.info("Skipping app launch side effects while running unit tests")
            return
        }

        menuBarController.setVisible(settingsStore.settings.menuBarIconEnabled)
        settingsViewModel.recheckSystemState()

        let launchSource = launchSourceClassifier.classify(
            notification: notification,
            isConfirmedBackgroundLaunch: false
        )
        let trigger = SettingsPresentationTrigger.coldLaunch(source: launchSource)
        let shouldPromptForPermission = accessibilityLaunchPromptPolicy.shouldPromptForMissingPermissionOnLaunch(
            for: trigger,
            settings: settingsStore.settings,
            isAccessibilityTrusted: permissionController.isTrusted,
            isRunningUnitTests: runtimeEnvironment.isRunningUnitTests
        )

        refreshAccessibilityState(promptIfNeeded: shouldPromptForPermission, presentAlert: shouldPromptForPermission)
        presentSettingsAfterLaunch(for: trigger)

        AppLoggers.app.info("Swift Quit finished launching")
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard !runtimeEnvironment.isRunningUnitTests else {
            return
        }

        settingsViewModel.recheckSystemState()
        refreshAccessibilityState(promptIfNeeded: false, presentAlert: false)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !runtimeEnvironment.isRunningUnitTests else {
            return false
        }

        presentSettings(for: .reopen)
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard !runtimeEnvironment.isRunningUnitTests else {
            return
        }

        terminationController.cancelAll()
        accessibilityMonitor.stop()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    private func refreshAccessibilityState(promptIfNeeded: Bool, presentAlert: Bool) {
        let isTrusted = permissionController.refresh(promptIfNeeded: promptIfNeeded)

        settingsViewModel.recheckPermissionState()
        refreshAccessibilityMonitoringState(isTrusted: isTrusted)

        if isTrusted {
            return
        }

        terminationController.cancelAll()

        if presentAlert {
            permissionController.presentMissingPermissionAlert()
        }
    }

    private func refreshAccessibilityMonitoringState(isTrusted: Bool) {
        for action in accessibilityMonitoringStartupPolicy.actions(isTrusted: isTrusted) {
            switch action {
            case .wireTerminationHandling:
                _ = terminationController
            case .refreshTrustedState(let trustedState):
                accessibilityMonitor.refreshTrustedState(isTrusted: trustedState)
            }
        }
    }

    private func presentSettings(for trigger: SettingsPresentationTrigger) {
        guard settingsPresentationPolicy.shouldPresentSettings(
            for: trigger,
            settings: settingsStore.settings,
            isAccessibilityTrusted: permissionController.isTrusted
        ) else {
            return
        }

        AppLoggers.settings.debug("Presenting settings for trigger \(trigger.logDescription, privacy: .public)")
        settingsWindowController.show()
    }

    private func presentSettingsAfterLaunch(for trigger: SettingsPresentationTrigger) {
        DispatchQueue.main.async { [weak self] in
            self?.presentSettings(for: trigger)
        }
    }
}
