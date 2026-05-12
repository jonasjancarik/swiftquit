//
//  ApplicationCatalog.swift
//  Swift Quit
//

import AppKit
import UniformTypeIdentifiers

protocol ApplicationCataloging: AnyObject {
    func chooseApplication() -> TrackedAppRule?
    func trackedRule(for bundleURL: URL) -> TrackedAppRule?
    func resolvedRule(for rule: TrackedAppRule) -> ResolvedTrackedAppRule
}

struct ResolvedTrackedAppRule: Identifiable {
    let rule: TrackedAppRule
    let displayName: String
    let bundleIdentifier: String?
    let resolvedURL: URL?
    let secondaryText: String?
    let icon: NSImage

    var id: String { rule.id }
}

@MainActor
final class ApplicationCatalog: ApplicationCataloging {
    nonisolated static let protectedBundleIdentifiers: Set<String> = [
        "onebadidea.Swift-Quit",
        "com.apple.finder",
        "com.apple.dock",
        "com.apple.systemuiserver",
        "com.apple.notificationcenterui",
        "com.apple.controlcenter",
        "com.apple.Spotlight",
        "com.apple.loginwindow",
    ]

    nonisolated static let browserHostBundleIdentifiers: Set<String> = [
        "com.apple.Safari",
        "com.google.Chrome",
        "company.thebrowser.Browser",
        "com.brave.Browser",
        "com.microsoft.edgemac",
        "org.mozilla.firefox",
    ]

    nonisolated static let browserWebAppBundleIdentifierPrefixes: Set<String> = [
        "com.apple.Safari.WebApp.",
        "com.google.Chrome.app.",
        "company.thebrowser.Browser.app.",
        "com.brave.Browser.app.",
        "com.microsoft.edgemac.app.",
        "org.mozilla.firefox.webapp.",
    ]

    func chooseApplication() -> TrackedAppRule? {
        let panel = NSOpenPanel()
        panel.title = "Choose Application"
        panel.message = "Pick an app for Swift Quit to include or exclude."
        panel.prompt = "Add App"
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.treatsFilePackagesAsDirectories = false
        panel.resolvesAliases = true

        guard panel.runModal() == .OK, let bundleURL = panel.url else {
            return nil
        }

        return trackedRule(for: bundleURL)
    }

    func trackedRule(for bundleURL: URL) -> TrackedAppRule? {
        let resolvedURL = bundleURL.resolvingSymlinksInPath().standardizedFileURL
        guard resolvedURL.pathExtension.caseInsensitiveCompare("app") == .orderedSame else {
            return nil
        }

        let bundle = Bundle(url: resolvedURL)
        let displayName = bundleDisplayName(bundle: bundle, fallbackURL: resolvedURL)

        return TrackedAppRule(
            bundleIdentifier: bundle?.bundleIdentifier,
            bundleURL: resolvedURL,
            displayName: displayName ?? resolvedURL.deletingPathExtension().lastPathComponent
        ).normalized()
    }

    func resolvedRule(for rule: TrackedAppRule) -> ResolvedTrackedAppRule {
        let resolvedURL = resolveURL(for: rule)
        let bundle = resolvedURL.flatMap(Bundle.init(url:))
        let displayName = bundleDisplayName(bundle: bundle, fallbackURL: resolvedURL) ?? rule.displayName
        let bundleIdentifier = bundle?.bundleIdentifier ?? rule.bundleIdentifier
        let secondaryText = bundleIdentifier ?? resolvedURL?.path

        return ResolvedTrackedAppRule(
            rule: rule,
            displayName: displayName,
            bundleIdentifier: bundleIdentifier,
            resolvedURL: resolvedURL,
            secondaryText: secondaryText,
            icon: icon(for: resolvedURL)
        )
    }

    private func resolveURL(for rule: TrackedAppRule) -> URL? {
        if let bundleIdentifier = rule.bundleIdentifier,
           let workspaceURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            return workspaceURL.standardizedFileURL
        }

        return rule.bundleURL?.standardizedFileURL
    }

    private func icon(for bundleURL: URL?) -> NSImage {
        guard let bundleURL else {
            return NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
        }

        return NSWorkspace.shared.icon(forFile: bundleURL.path)
    }

    private func bundleDisplayName(bundle: Bundle?, fallbackURL: URL?) -> String? {
        if let localizedDisplayName = bundle?.localizedInfoDictionary?["CFBundleDisplayName"] as? String, !localizedDisplayName.isEmpty {
            return localizedDisplayName
        }

        if let bundleName = bundle?.localizedInfoDictionary?["CFBundleName"] as? String, !bundleName.isEmpty {
            return bundleName
        }

        if let displayName = bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String, !displayName.isEmpty {
            return displayName
        }

        if let bundleName = bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String, !bundleName.isEmpty {
            return bundleName
        }

        return fallbackURL?.deletingPathExtension().lastPathComponent
    }
}
