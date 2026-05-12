//
//  TerminationEngineTests.swift
//  Swift QuitTests
//

import AppKit
import XCTest
@testable import Swift_Quit

final class TerminationEngineTests: XCTestCase {
    @MainActor
    func testProtectedAppsNeverQuit() {
        let engine = makeEngine()
        let app = ApplicationSnapshot(
            bundleIdentifier: "com.apple.finder",
            bundleURL: URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app"),
            localizedName: "Finder",
            activationPolicy: .regular,
            isHidden: false
        )

        let decision = engine.evaluate(app: app, pollResult: .windows([]), settings: .default, attempt: 0)
        XCTAssertEqual(decision, .skip(reason: "Protected system app"))
    }

    @MainActor
    func testProtectedBundleIdentifiersMatchCaseInsensitively() {
        let engine = makeEngine()
        let app = makeRegularApp(bundleIdentifier: "COM.APPLE.SPOTLIGHT", name: "Spotlight")

        let decision = engine.evaluate(app: app, pollResult: .windows([]), settings: .default, attempt: 0)

        XCTAssertEqual(decision, .skip(reason: "Protected system app"))
    }

    @MainActor
    func testKnownSystemAppsNeverTerminate() {
        let engine = makeEngine()
        let protectedApps = [
            ("com.apple.finder", "Finder"),
            ("com.apple.dock", "Dock"),
            ("com.apple.Spotlight", "Spotlight"),
            ("com.apple.controlcenter", "Control Center"),
            ("com.apple.systemuiserver", "SystemUIServer"),
            ("com.apple.loginwindow", "loginwindow"),
            ("onebadidea.swift-quit", "Swift Quit"),
        ]

        for (bundleIdentifier, name) in protectedApps {
            let decision = engine.evaluate(
                app: makeRegularApp(bundleIdentifier: bundleIdentifier, name: name),
                pollResult: .windows([]),
                settings: aggressiveExplicitIncludeSettings(for: bundleIdentifier, allowAllRiskyOverrides: true),
                attempt: 0
            )

            XCTAssertEqual(decision, .skip(reason: "Protected system app"), name)
        }
    }

    @MainActor
    func testRegularAppWithOpenWindowDoesNotQuit() {
        let engine = makeEngine()
        let decision = engine.evaluate(
            app: makeRegularApp(),
            pollResult: .windows([
                WindowSnapshot(role: kAXWindowRole as String, subrole: kAXStandardWindowSubrole as String, title: "Main", isMinimized: false)
            ]),
            settings: .default,
            attempt: 0
        )

        XCTAssertEqual(decision, .skip(reason: "App still has 1 open window(s)"))
    }

    @MainActor
    func testRegularAppWithNoWindowsQuitsInBalancedMode() {
        let engine = makeEngine()
        let decision = engine.evaluate(app: makeRegularApp(), pollResult: .windows([]), settings: .default, attempt: 0)
        XCTAssertEqual(decision, .terminate)
    }

    @MainActor
    func testBalancedProfileRetriesOnceForAmbiguousAXState() {
        let engine = makeEngine()
        let firstDecision = engine.evaluate(
            app: makeRegularApp(),
            pollResult: .ambiguous("cannotComplete"),
            settings: .default,
            attempt: 0
        )
        XCTAssertEqual(firstDecision, .retry(after: 0.5, reason: "Retrying after AX ambiguity"))

        let secondDecision = engine.evaluate(
            app: makeRegularApp(),
            pollResult: .ambiguous("cannotComplete"),
            settings: .default,
            attempt: 1
        )
        XCTAssertEqual(secondDecision, .skip(reason: "AX state remained ambiguous: cannotComplete"))
    }

    @MainActor
    func testConservativeProfileRequiresTwoZeroWindowPolls() {
        let engine = makeEngine()
        var settings = AppSettings.default
        settings.safetyProfile = .conservative

        let firstDecision = engine.evaluate(app: makeRegularApp(), pollResult: .windows([]), settings: settings, attempt: 0)
        XCTAssertEqual(firstDecision, .retry(after: 0.75, reason: "Confirming zero-window state"))

        let secondDecision = engine.evaluate(app: makeRegularApp(), pollResult: .windows([]), settings: settings, attempt: 1)
        XCTAssertEqual(secondDecision, .terminate)
    }

    @MainActor
    func testConservativeProfileStillConfirmsExplicitlyIncludedApps() {
        let engine = makeEngine()
        var settings = AppSettings.default
        settings.ruleMode = .onlyIncluded
        settings.safetyProfile = .conservative
        settings.trackedApps = [
            TrackedAppRule(
                bundleIdentifier: "com.example.Editor",
                bundleURL: URL(fileURLWithPath: "/Applications/Editor.app"),
                displayName: "Editor"
            )
        ]

        let firstDecision = engine.evaluate(app: makeRegularApp(), pollResult: .windows([]), settings: settings, attempt: 0)
        XCTAssertEqual(firstDecision, .retry(after: 0.75, reason: "Confirming zero-window state"))

        let secondDecision = engine.evaluate(app: makeRegularApp(), pollResult: .windows([]), settings: settings, attempt: 1)
        XCTAssertEqual(secondDecision, .terminate)
    }

    @MainActor
    func testMinimizedWindowsCountAsOpenByDefault() {
        let engine = makeEngine()
        let decision = engine.evaluate(
            app: makeRegularApp(),
            pollResult: .windows([
                WindowSnapshot(
                    role: kAXWindowRole as String,
                    subrole: kAXStandardWindowSubrole as String,
                    title: "Minimized",
                    isMinimized: true
                )
            ]),
            settings: .default,
            attempt: 0
        )

        XCTAssertEqual(decision, .skip(reason: "App still has 1 open window(s)"))
    }

    @MainActor
    func testMinimizedWindowsCanBeIgnoredWhenSafetyOptionDisabled() {
        let engine = makeEngine()
        var settings = AppSettings.default
        settings.safetyOptions.countMinimizedWindowsAsOpen = false

        let decision = engine.evaluate(
            app: makeRegularApp(),
            pollResult: .windows([
                WindowSnapshot(
                    role: kAXWindowRole as String,
                    subrole: kAXStandardWindowSubrole as String,
                    title: "Minimized",
                    isMinimized: true
                )
            ]),
            settings: settings,
            attempt: 0
        )

        XCTAssertEqual(decision, .terminate)
    }

    @MainActor
    func testHiddenWindowsCountAsOpenByDefault() {
        let engine = makeEngine()
        let decision = engine.evaluate(
            app: makeRegularApp(),
            pollResult: .windows([
                WindowSnapshot(
                    role: kAXWindowRole as String,
                    subrole: kAXStandardWindowSubrole as String,
                    title: "Hidden",
                    isMinimized: false,
                    visibility: .hidden
                )
            ]),
            settings: .default,
            attempt: 0
        )

        XCTAssertEqual(decision, .skip(reason: "App still has 1 open window(s)"))
    }

    @MainActor
    func testHiddenApplicationCountsAsOpenByDefault() {
        let engine = makeEngine()
        let decision = engine.evaluate(
            app: makeRegularApp(isHidden: true),
            pollResult: .windows([]),
            settings: .default,
            attempt: 0
        )

        XCTAssertEqual(decision, .skip(reason: "Application is hidden"))
    }

    @MainActor
    func testHiddenApplicationCanTerminateWhenSafetyOptionDisabled() {
        let engine = makeEngine()
        var settings = AppSettings.default
        settings.safetyOptions.countHiddenWindowsAsOpen = false

        let decision = engine.evaluate(
            app: makeRegularApp(isHidden: true),
            pollResult: .windows([]),
            settings: settings,
            attempt: 0
        )

        XCTAssertEqual(decision, .terminate)
    }

    @MainActor
    func testBrowserHostsAreProtectedCaseInsensitivelyByDefault() {
        let engine = makeEngine()
        let browserHost = makeRegularApp(bundleIdentifier: "COM.GOOGLE.CHROME", name: "Google Chrome")

        let decision = engine.evaluate(app: browserHost, pollResult: .windows([]), settings: .default, attempt: 0)

        XCTAssertEqual(decision, .skip(reason: "Protected browser host"))
    }

    @MainActor
    func testSafariWebAppWrappersAreProtectedByDefault() {
        let engine = makeEngine()
        let webApp = makeRegularApp(bundleIdentifier: "com.apple.Safari.WebApp.12345678", name: "Dashboard")

        let decision = engine.evaluate(app: webApp, pollResult: .windows([]), settings: .default, attempt: 0)

        XCTAssertEqual(decision, .skip(reason: "Protected browser web app"))
    }

    @MainActor
    func testChromiumWebAppWrappersAreProtectedByDefault() {
        let engine = makeEngine()
        let webApp = makeRegularApp(bundleIdentifier: "COM.GOOGLE.CHROME.APP.ABCDEF", name: "Docs")

        let decision = engine.evaluate(app: webApp, pollResult: .windows([]), settings: .default, attempt: 0)

        XCTAssertEqual(decision, .skip(reason: "Protected browser web app"))
    }

    @MainActor
    func testExplicitIncludeStillPreservesBrowserHostByDefault() {
        let engine = makeEngine()
        var settings = AppSettings.default
        settings.ruleMode = .onlyIncluded
        settings.trackedApps = [
            TrackedAppRule(
                bundleIdentifier: "com.google.Chrome",
                bundleURL: URL(fileURLWithPath: "/Applications/Google Chrome.app"),
                displayName: "Google Chrome"
            )
        ]

        let browserHost = makeRegularApp(bundleIdentifier: "com.google.Chrome", name: "Google Chrome")

        let decision = engine.evaluate(app: browserHost, pollResult: .windows([]), settings: settings, attempt: 0)
        XCTAssertEqual(decision, .skip(reason: "Protected browser host"))
    }

    @MainActor
    func testExplicitIncludeCanOverrideBrowserProtectionWhenSafetyOptionDisabled() {
        let engine = makeEngine()
        var settings = aggressiveExplicitIncludeSettings(for: "com.google.Chrome", allowAllRiskyOverrides: false)
        settings.safetyOptions.protectBrowserHosts = false

        let browserHost = makeRegularApp(bundleIdentifier: "com.google.Chrome", name: "Google Chrome")

        let decision = engine.evaluate(app: browserHost, pollResult: .windows([]), settings: settings, attempt: 0)
        XCTAssertEqual(decision, .terminate)
    }

    @MainActor
    func testAccessoryAppsAreProtectedByDefault() {
        let engine = makeEngine()
        let decision = engine.evaluate(
            app: makeRegularApp(activationPolicy: .accessory),
            pollResult: .windows([]),
            settings: .default,
            attempt: 0
        )

        XCTAssertEqual(decision, .skip(reason: "Non-regular application"))
    }

    @MainActor
    func testExplicitIncludeCanOverrideAccessoryProtectionWhenSafetyOptionDisabled() {
        let engine = makeEngine()
        var settings = aggressiveExplicitIncludeSettings(for: "com.example.MenuUtility", allowAllRiskyOverrides: false)
        settings.safetyOptions.protectAccessoryApps = false

        let app = makeRegularApp(
            bundleIdentifier: "com.example.MenuUtility",
            name: "Menu Utility",
            activationPolicy: .accessory
        )

        let decision = engine.evaluate(app: app, pollResult: .windows([]), settings: settings, attempt: 0)

        XCTAssertEqual(decision, .terminate)
    }

    @MainActor
    func testExplicitExcludeOverridesProfileBehavior() {
        let engine = makeEngine()
        var settings = AppSettings.default
        settings.trackedApps = [
            TrackedAppRule(
                bundleIdentifier: "com.example.Editor",
                bundleURL: URL(fileURLWithPath: "/Applications/Editor.app"),
                displayName: "Editor"
            )
        ]

        let decision = engine.evaluate(app: makeRegularApp(), pollResult: .windows([]), settings: settings, attempt: 0)
        XCTAssertEqual(decision, .skip(reason: "App is explicitly excluded"))
    }

    @MainActor
    private func makeEngine() -> TerminationEngine {
        TerminationEngine(
            protectedBundleIdentifiers: ApplicationCatalog.protectedBundleIdentifiers,
            browserHostBundleIdentifiers: ApplicationCatalog.browserHostBundleIdentifiers,
            browserWebAppBundleIdentifierPrefixes: ApplicationCatalog.browserWebAppBundleIdentifierPrefixes
        )
    }

    @MainActor
    private func makeRegularApp(
        bundleIdentifier: String = "com.example.Editor",
        name: String = "Editor",
        activationPolicy: NSApplication.ActivationPolicy = .regular,
        isHidden: Bool = false
    ) -> ApplicationSnapshot {
        ApplicationSnapshot(
            bundleIdentifier: bundleIdentifier,
            bundleURL: URL(fileURLWithPath: "/Applications/\(name).app"),
            localizedName: name,
            activationPolicy: activationPolicy,
            isHidden: isHidden
        )
    }

    @MainActor
    private func aggressiveExplicitIncludeSettings(
        for bundleIdentifier: String,
        allowAllRiskyOverrides: Bool
    ) -> AppSettings {
        var settings = AppSettings.default
        settings.ruleMode = .onlyIncluded
        settings.safetyProfile = .aggressive
        settings.trackedApps = [
            TrackedAppRule(
                bundleIdentifier: bundleIdentifier,
                bundleURL: URL(fileURLWithPath: "/Applications/Test.app"),
                displayName: "Test"
            )
        ]

        if allowAllRiskyOverrides {
            settings.safetyOptions = SafetyOptions(
                protectBrowserHosts: false,
                protectAccessoryApps: false,
                countMinimizedWindowsAsOpen: false,
                countHiddenWindowsAsOpen: false
            )
        }

        return settings
    }
}

final class TerminationCooldownTrackerTests: XCTestCase {
    func testFailedTerminationEntersCooldown() {
        let now = Date()
        var tracker = TerminationCooldownTracker(cooldownDuration: 5)

        tracker.recordCooldown(for: 42, now: now)

        XCTAssertTrue(tracker.isCoolingDown(for: 42, now: now.addingTimeInterval(1)))
    }

    func testCooldownSuppressesRepeatedAttemptsUntilExpiration() {
        let now = Date()
        var tracker = TerminationCooldownTracker(cooldownDuration: 5)

        tracker.recordCooldown(for: 42, now: now)

        XCTAssertTrue(tracker.isCoolingDown(for: 42, now: now.addingTimeInterval(4)))
        XCTAssertFalse(tracker.isCoolingDown(for: 42, now: now.addingTimeInterval(6)))
    }

    @MainActor
    func testOpenWindowsClearCooldown() {
        let now = Date()
        var tracker = TerminationCooldownTracker(cooldownDuration: 5)
        tracker.recordCooldown(for: 42, now: now)

        let cleared = tracker.clearIfAppHasOpenWindows(
            for: 42,
            pollResult: .windows([
                WindowSnapshot(
                    role: kAXWindowRole as String,
                    subrole: kAXStandardWindowSubrole as String,
                    title: "Main",
                    isMinimized: false
                )
            ]),
            safetyOptions: .default
        )

        XCTAssertTrue(cleared)
        XCTAssertFalse(tracker.isCoolingDown(for: 42, now: now))
    }

    func testSuccessfulTerminationClearsTrackingImmediately() {
        let now = Date()
        var tracker = TerminationCooldownTracker(cooldownDuration: 5)
        tracker.recordCooldown(for: 42, now: now)

        XCTAssertTrue(tracker.clear(for: 42))
        XCTAssertFalse(tracker.isCoolingDown(for: 42, now: now))
    }
}

@MainActor
final class AccessibilityNotificationHandlingPolicyTests: XCTestCase {
    func testWindowRegistrationRefreshesForCreatedFocusedAndShownNotifications() {
        let policy = AccessibilityNotificationHandlingPolicy()

        XCTAssertTrue(policy.shouldRefreshWindowRegistrations(for: kAXWindowCreatedNotification as String))
        XCTAssertTrue(policy.shouldRefreshWindowRegistrations(for: kAXFocusedWindowChangedNotification as String))
        XCTAssertTrue(policy.shouldRefreshWindowRegistrations(for: kAXApplicationShownNotification as String))
    }

    func testWindowRegistrationDoesNotRefreshForDestroyNotifications() {
        let policy = AccessibilityNotificationHandlingPolicy()

        XCTAssertFalse(policy.shouldRefreshWindowRegistrations(for: kAXUIElementDestroyedNotification as String))
    }
}
