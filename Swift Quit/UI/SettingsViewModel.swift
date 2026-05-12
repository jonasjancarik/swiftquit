//
//  SettingsViewModel.swift
//  Swift Quit
//

import Combine
import AppKit
import Foundation

@MainActor
final class SettingsViewModel: ObservableObject {
    let permissionController: AccessibilityPermissionController
    let loginItemController: LoginItemController
    let terminationDiagnostics: TerminationDiagnostics
    let appInfo: AppInfo

    private let settingsStore: SettingsStore
    private let applicationCatalog: ApplicationCataloging
    private let applyMenuBarVisibility: (Bool) -> Void
    private let refreshAccessibilityState: (_ promptIfNeeded: Bool, _ presentAlert: Bool) -> Void

    private var isSynchronizing = false

    @Published var permissionGranted = false
    @Published var launchAtLoginEnabled = false {
        didSet {
            guard !isSynchronizing, launchAtLoginEnabled != oldValue else { return }
            settingsStore.update { $0.launchAtLoginEnabled = launchAtLoginEnabled }
            loginItemController.setEnabled(launchAtLoginEnabled)
            loginItemState = loginItemController.state
        }
    }

    @Published var menuBarIconEnabled = true {
        didSet {
            guard !isSynchronizing, menuBarIconEnabled != oldValue else { return }

            if !menuBarIconEnabled, !confirmMenuBarIconHide() {
                isSynchronizing = true
                menuBarIconEnabled = true
                isSynchronizing = false
                return
            }

            settingsStore.update { $0.menuBarIconEnabled = menuBarIconEnabled }
            applyMenuBarVisibility(menuBarIconEnabled)
        }
    }

    @Published var launchHidden = true {
        didSet {
            guard !isSynchronizing, launchHidden != oldValue else { return }
            settingsStore.update { $0.launchHidden = launchHidden }
        }
    }

    @Published var closeDelaySeconds = AppSettings.default.closeDelaySeconds {
        didSet {
            guard !isSynchronizing else { return }

            closeDelaySeconds = max(1, closeDelaySeconds)
            settingsStore.update { $0.closeDelaySeconds = closeDelaySeconds }
        }
    }

    @Published var ruleMode = AppSettings.default.ruleMode {
        didSet {
            guard !isSynchronizing, ruleMode != oldValue else { return }
            settingsStore.update { $0.ruleMode = ruleMode }
        }
    }

    @Published var safetyProfile = AppSettings.default.safetyProfile {
        didSet {
            guard !isSynchronizing, safetyProfile != oldValue else { return }
            settingsStore.update { $0.safetyProfile = safetyProfile }
        }
    }

    @Published var protectBrowserHosts = SafetyOptions.default.protectBrowserHosts {
        didSet {
            guard !isSynchronizing, protectBrowserHosts != oldValue else { return }
            settingsStore.update { $0.safetyOptions.protectBrowserHosts = protectBrowserHosts }
        }
    }

    @Published var protectAccessoryApps = SafetyOptions.default.protectAccessoryApps {
        didSet {
            guard !isSynchronizing, protectAccessoryApps != oldValue else { return }
            settingsStore.update { $0.safetyOptions.protectAccessoryApps = protectAccessoryApps }
        }
    }

    @Published var countMinimizedWindowsAsOpen = SafetyOptions.default.countMinimizedWindowsAsOpen {
        didSet {
            guard !isSynchronizing, countMinimizedWindowsAsOpen != oldValue else { return }
            settingsStore.update { $0.safetyOptions.countMinimizedWindowsAsOpen = countMinimizedWindowsAsOpen }
        }
    }

    @Published var countHiddenWindowsAsOpen = SafetyOptions.default.countHiddenWindowsAsOpen {
        didSet {
            guard !isSynchronizing, countHiddenWindowsAsOpen != oldValue else { return }
            settingsStore.update { $0.safetyOptions.countHiddenWindowsAsOpen = countHiddenWindowsAsOpen }
        }
    }

    @Published var trackedApps: [TrackedAppRule] = [] {
        didSet {
            guard !isSynchronizing else { return }
            settingsStore.replaceTrackedApps(trackedApps)
        }
    }

    @Published var selectedRuleIDs = Set<TrackedAppRule.ID>()
    @Published var loginItemState: LoginItemState = .notRegistered
    @Published var lastOperationErrorMessage: String?

    init(
        settingsStore: SettingsStore,
        applicationCatalog: ApplicationCataloging,
        permissionController: AccessibilityPermissionController,
        loginItemController: LoginItemController,
        terminationDiagnostics: TerminationDiagnostics,
        appInfo: AppInfo,
        applyMenuBarVisibility: @escaping (Bool) -> Void,
        refreshAccessibilityState: @escaping (_ promptIfNeeded: Bool, _ presentAlert: Bool) -> Void
    ) {
        self.settingsStore = settingsStore
        self.applicationCatalog = applicationCatalog
        self.permissionController = permissionController
        self.loginItemController = loginItemController
        self.terminationDiagnostics = terminationDiagnostics
        self.appInfo = appInfo
        self.applyMenuBarVisibility = applyMenuBarVisibility
        self.refreshAccessibilityState = refreshAccessibilityState

        syncFromPersistentState()
        reconcileLoginItemStateWithDesiredSetting()
    }

    var resolvedTrackedApps: [ResolvedTrackedAppRule] {
        trackedApps.map(applicationCatalog.resolvedRule(for:))
    }

    var closeDelaySummary: String {
        closeDelaySeconds == 1 ? "1 second" : "\(closeDelaySeconds) seconds"
    }

    var ruleModeSummary: String {
        ruleMode.detail
    }

    var safetyProfileSummary: String {
        safetyProfile.detail
    }

    var activeSafetySummary: String {
        [
            protectBrowserHosts ? "Browser hosts" : nil,
            protectAccessoryApps ? "Accessory apps" : nil,
            countMinimizedWindowsAsOpen ? "Minimized windows" : nil,
            countHiddenWindowsAsOpen ? "Hidden apps/windows" : nil,
        ]
        .compactMap { $0 }
        .joined(separator: ", ")
    }

    func handleSettingsWindowBecameVisible() {
        recheckSystemState()
    }

    func recheckSystemState() {
        recheckPermissionState()
        recheckLoginItemState()
    }

    func recheckPermissionState() {
        permissionGranted = permissionController.refresh(promptIfNeeded: false)
    }

    func addTrackedApp() {
        lastOperationErrorMessage = nil

        guard let rule = applicationCatalog.chooseApplication() else {
            return
        }

        if trackedApps.contains(where: { $0.id == rule.id }) {
            lastOperationErrorMessage = "\(rule.displayName) is already listed."
            return
        }

        trackedApps.append(rule)
        trackedApps.sort {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    func removeSelectedTrackedApps() {
        trackedApps.removeAll { selectedRuleIDs.contains($0.id) }
        selectedRuleIDs.removeAll()
    }

    func openAccessibilitySettings() {
        permissionController.openSystemSettings()
    }

    func recheckAccessibilityAccess() {
        refreshAccessibilityState(true, false)
        permissionGranted = permissionController.isTrusted
    }

    func openLoginItemsSettings() {
        loginItemController.openSystemSettings()
    }

    private func syncFromPersistentState() {
        isSynchronizing = true
        defer { isSynchronizing = false }

        let settings = settingsStore.settings
        menuBarIconEnabled = settings.menuBarIconEnabled
        launchHidden = settings.launchHidden
        closeDelaySeconds = settings.closeDelaySeconds
        ruleMode = settings.ruleMode
        safetyProfile = settings.safetyProfile
        protectBrowserHosts = settings.safetyOptions.protectBrowserHosts
        protectAccessoryApps = settings.safetyOptions.protectAccessoryApps
        countMinimizedWindowsAsOpen = settings.safetyOptions.countMinimizedWindowsAsOpen
        countHiddenWindowsAsOpen = settings.safetyOptions.countHiddenWindowsAsOpen
        trackedApps = settings.trackedApps
        permissionGranted = permissionController.isTrusted
        launchAtLoginEnabled = settings.launchAtLoginEnabled
    }

    private func recheckLoginItemState() {
        loginItemController.refresh()
        loginItemState = loginItemController.state
    }

    private func reconcileLoginItemStateWithDesiredSetting() {
        loginItemController.refresh()

        let desiredLaunchAtLoginState = settingsStore.settings.launchAtLoginEnabled
        if loginItemController.state.isEnabled != desiredLaunchAtLoginState {
            loginItemController.setEnabled(desiredLaunchAtLoginState)
        }

        loginItemState = loginItemController.state
    }

    private func confirmMenuBarIconHide() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Hide Menu Bar Icon?"
        alert.informativeText = """
        Swift Quit will keep running, but Settings will only be reachable by launching Swift Quit again from Finder, Spotlight, or your Applications folder.
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Hide Icon")
        alert.addButton(withTitle: "Keep Icon")

        return alert.runModal() == .alertFirstButtonReturn
    }
}
