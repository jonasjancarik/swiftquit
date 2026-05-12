//
//  AppSettings.swift
//  Swift Quit
//

import Foundation

enum RuleMode: String, CaseIterable, Codable, Identifiable {
    case allExceptExcluded
    case onlyIncluded

    var id: String { rawValue }

    var title: String {
        switch self {
        case .allExceptExcluded:
            "All Apps Except Listed"
        case .onlyIncluded:
            "Only Listed Apps"
        }
    }

    var detail: String {
        switch self {
        case .allExceptExcluded:
            "Swift Quit applies broadly, but skips any app listed below."
        case .onlyIncluded:
            "Swift Quit only applies to apps you explicitly list below."
        }
    }
}

enum TerminationSafetyProfile: String, CaseIterable, Codable, Identifiable {
    case conservative
    case balanced
    case aggressive

    var id: String { rawValue }

    var title: String {
        rawValue.capitalized
    }

    var detail: String {
        switch self {
        case .conservative:
            "Double-check empty-window state and skip anything ambiguous."
        case .balanced:
            "Good default: protects common problem apps while still auto-quitting broadly."
        case .aggressive:
            "Quit any non-protected app as soon as it reaches a clear zero-window state."
        }
    }
}

struct SafetyOptions: Codable, Equatable {
    var protectBrowserHosts: Bool
    var protectAccessoryApps: Bool
    var countMinimizedWindowsAsOpen: Bool
    var countHiddenWindowsAsOpen: Bool

    static let `default` = SafetyOptions(
        protectBrowserHosts: true,
        protectAccessoryApps: true,
        countMinimizedWindowsAsOpen: true,
        countHiddenWindowsAsOpen: true
    )
}

struct TrackedAppRule: Codable, Hashable, Identifiable {
    var bundleIdentifier: String?
    var bundleURL: URL?
    var displayName: String

    var id: String {
        bundleIdentifier?.lowercased() ?? bundleURL?.standardizedFileURL.path ?? displayName
    }

    func matches(bundleIdentifier candidateBundleIdentifier: String?, bundleURL candidateBundleURL: URL?) -> Bool {
        if let bundleIdentifier, let candidateBundleIdentifier {
            return bundleIdentifier.caseInsensitiveCompare(candidateBundleIdentifier) == .orderedSame
        }

        guard let bundleURL, let candidateBundleURL else {
            return false
        }

        return bundleURL.standardizedFileURL.path == candidateBundleURL.standardizedFileURL.path
    }

    func normalized() -> TrackedAppRule {
        TrackedAppRule(
            bundleIdentifier: bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
            bundleURL: bundleURL?.standardizedFileURL,
            displayName: displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}

struct AppSettings: Codable, Equatable {
    static let currentMigrationVersion = 2

    var launchAtLoginEnabled: Bool
    var menuBarIconEnabled: Bool
    var launchHidden: Bool
    var closeDelaySeconds: Int
    var ruleMode: RuleMode
    var safetyProfile: TerminationSafetyProfile
    var safetyOptions: SafetyOptions
    var trackedApps: [TrackedAppRule]

    static let `default` = AppSettings(
        launchAtLoginEnabled: false,
        menuBarIconEnabled: true,
        launchHidden: true,
        closeDelaySeconds: 2,
        ruleMode: .allExceptExcluded,
        safetyProfile: .balanced,
        safetyOptions: .default,
        trackedApps: []
    )

    private enum CodingKeys: String, CodingKey {
        case launchAtLoginEnabled
        case menuBarIconEnabled
        case launchHidden
        case closeDelaySeconds
        case ruleMode
        case safetyProfile
        case safetyOptions
        case trackedApps
    }

    init(
        launchAtLoginEnabled: Bool,
        menuBarIconEnabled: Bool,
        launchHidden: Bool,
        closeDelaySeconds: Int,
        ruleMode: RuleMode,
        safetyProfile: TerminationSafetyProfile,
        safetyOptions: SafetyOptions,
        trackedApps: [TrackedAppRule]
    ) {
        self.launchAtLoginEnabled = launchAtLoginEnabled
        self.menuBarIconEnabled = menuBarIconEnabled
        self.launchHidden = launchHidden
        self.closeDelaySeconds = closeDelaySeconds
        self.ruleMode = ruleMode
        self.safetyProfile = safetyProfile
        self.safetyOptions = safetyOptions
        self.trackedApps = trackedApps
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        launchAtLoginEnabled = try container.decode(Bool.self, forKey: .launchAtLoginEnabled)
        menuBarIconEnabled = try container.decode(Bool.self, forKey: .menuBarIconEnabled)
        launchHidden = try container.decode(Bool.self, forKey: .launchHidden)
        closeDelaySeconds = try container.decode(Int.self, forKey: .closeDelaySeconds)
        ruleMode = try container.decode(RuleMode.self, forKey: .ruleMode)
        safetyProfile = try container.decode(TerminationSafetyProfile.self, forKey: .safetyProfile)
        safetyOptions = try container.decodeIfPresent(SafetyOptions.self, forKey: .safetyOptions) ?? .default
        trackedApps = try container.decode([TrackedAppRule].self, forKey: .trackedApps)
    }

    mutating func normalize() {
        closeDelaySeconds = max(1, closeDelaySeconds)

        var seenRuleIDs = Set<String>()
        trackedApps = trackedApps
            .map { $0.normalized() }
            .filter { !($0.displayName.isEmpty && $0.bundleIdentifier == nil && $0.bundleURL == nil) }
            .filter { rule in
                seenRuleIDs.insert(rule.id).inserted
            }
    }
}
