//
//  TerminationEngine.swift
//  Swift Quit
//

import AppKit
import Foundation

enum TerminationDecision: Equatable {
    case terminate
    case skip(reason: String)
    case retry(after: TimeInterval, reason: String)
}

enum WindowPollResult: Equatable {
    case windows([WindowSnapshot])
    case ambiguous(String)
}

enum WindowVisibility: Equatable {
    case visible
    case hidden
    case unknown
}

struct ApplicationSnapshot: Equatable {
    let bundleIdentifier: String?
    let bundleURL: URL?
    let localizedName: String?
    let activationPolicy: NSApplication.ActivationPolicy
    let isHidden: Bool

    init(
        bundleIdentifier: String?,
        bundleURL: URL?,
        localizedName: String?,
        activationPolicy: NSApplication.ActivationPolicy,
        isHidden: Bool
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.bundleURL = bundleURL?.standardizedFileURL
        self.localizedName = localizedName
        self.activationPolicy = activationPolicy
        self.isHidden = isHidden
    }

    init(application: NSRunningApplication) {
        bundleIdentifier = application.bundleIdentifier
        bundleURL = application.bundleURL?.standardizedFileURL
        localizedName = application.localizedName
        activationPolicy = application.activationPolicy
        isHidden = application.isHidden
    }
}

struct WindowSnapshot: Equatable, Identifiable {
    let role: String
    let subrole: String?
    let title: String?
    let isMinimized: Bool
    let visibility: WindowVisibility

    nonisolated var id: String {
        "\(role)|\(subrole ?? "")|\(title ?? "")|\(isMinimized)|\(visibility)"
    }

    init(
        role: String,
        subrole: String?,
        title: String?,
        isMinimized: Bool,
        visibility: WindowVisibility = .unknown
    ) {
        self.role = role
        self.subrole = subrole
        self.title = title
        self.isMinimized = isMinimized
        self.visibility = visibility
    }

    nonisolated func qualifiesAsOpen(using safetyOptions: SafetyOptions) -> Bool {
        let topLevelRoles = [
            kAXWindowRole as String,
            kAXSheetRole as String,
        ]

        let topLevelSubroles = [
            kAXStandardWindowSubrole as String,
            kAXDialogSubrole as String,
            kAXSystemDialogSubrole as String,
        ]

        let isTopLevelWindow = topLevelRoles.contains(role) || topLevelSubroles.contains(subrole ?? "")
        guard isTopLevelWindow else {
            return false
        }

        if isMinimized {
            return safetyOptions.countMinimizedWindowsAsOpen
        }

        if case .hidden = visibility {
            return safetyOptions.countHiddenWindowsAsOpen
        }

        return true
    }
}

struct TerminationEngine {
    let protectedBundleIdentifiers: Set<String>
    let browserHostBundleIdentifiers: Set<String>
    let browserWebAppBundleIdentifierPrefixes: Set<String>

    init(
        protectedBundleIdentifiers: Set<String>,
        browserHostBundleIdentifiers: Set<String>,
        browserWebAppBundleIdentifierPrefixes: Set<String> = []
    ) {
        self.protectedBundleIdentifiers = Self.normalized(identifiers: protectedBundleIdentifiers)
        self.browserHostBundleIdentifiers = Self.normalized(identifiers: browserHostBundleIdentifiers)
        self.browserWebAppBundleIdentifierPrefixes = Self.normalized(identifiers: browserWebAppBundleIdentifierPrefixes)
    }

    func evaluate(
        app: ApplicationSnapshot,
        pollResult: WindowPollResult,
        settings: AppSettings,
        attempt: Int
    ) -> TerminationDecision {
        let normalizedBundleIdentifier = app.bundleIdentifier?.normalizedBundleIdentifier

        if let bundleIdentifier = normalizedBundleIdentifier,
           protectedBundleIdentifiers.contains(bundleIdentifier) {
            return .skip(reason: "Protected system app")
        }

        let matchingRule = settings.trackedApps.first {
            $0.matches(bundleIdentifier: app.bundleIdentifier, bundleURL: app.bundleURL)
        }

        let isExplicitlyIncluded = settings.ruleMode == .onlyIncluded && matchingRule != nil

        switch settings.ruleMode {
        case .onlyIncluded:
            guard isExplicitlyIncluded else {
                return .skip(reason: "App is not included")
            }
        case .allExceptExcluded:
            if matchingRule != nil {
                return .skip(reason: "App is explicitly excluded")
            }
        }

        if settings.safetyOptions.protectAccessoryApps {
            guard app.activationPolicy == .regular else {
                return .skip(reason: "Non-regular application")
            }
        }

        if app.isHidden, settings.safetyOptions.countHiddenWindowsAsOpen {
            return .skip(reason: "Application is hidden")
        }

        if settings.safetyOptions.protectBrowserHosts,
           let bundleIdentifier = normalizedBundleIdentifier {
            if browserHostBundleIdentifiers.contains(bundleIdentifier) {
                return .skip(reason: "Protected browser host")
            }

            if isBrowserWebAppBundleIdentifier(bundleIdentifier) {
                return .skip(reason: "Protected browser web app")
            }
        }

        switch pollResult {
        case .ambiguous(let reason):
            switch settings.safetyProfile {
            case .conservative:
                return .skip(reason: "AX state ambiguous: \(reason)")
            case .balanced:
                if attempt == 0 {
                    return .retry(after: 0.5, reason: "Retrying after AX ambiguity")
                }

                return .skip(reason: "AX state remained ambiguous: \(reason)")
            case .aggressive:
                return .skip(reason: "AX state ambiguous: \(reason)")
            }

        case .windows(let windows):
            let qualifyingWindows = windows.filter { $0.qualifiesAsOpen(using: settings.safetyOptions) }

            guard qualifyingWindows.isEmpty else {
                return .skip(reason: "App still has \(qualifyingWindows.count) open window(s)")
            }

            switch settings.safetyProfile {
            case .conservative:
                if attempt == 0 {
                    return .retry(after: 0.75, reason: "Confirming zero-window state")
                }

                return .terminate
            case .balanced, .aggressive:
                return .terminate
            }
        }
    }

    private static func normalized(identifiers: Set<String>) -> Set<String> {
        Set(identifiers.map(\.normalizedBundleIdentifier))
    }

    private func isBrowserWebAppBundleIdentifier(_ bundleIdentifier: String) -> Bool {
        browserWebAppBundleIdentifierPrefixes.contains { prefix in
            bundleIdentifier.hasPrefix(prefix)
        }
    }
}

private extension String {
    var normalizedBundleIdentifier: String {
        trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
