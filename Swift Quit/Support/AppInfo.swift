//
//  AppInfo.swift
//  Swift Quit
//

import AppKit
import Foundation

struct AppInfo {
    let displayName: String
    let version: String
    let build: String
    let icon: NSImage

    static var current: AppInfo {
        let bundle = Bundle.main
        let displayName = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? "Swift Quit"

        return AppInfo(
            displayName: displayName,
            version: (bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "Unknown",
            build: (bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "Unknown",
            icon: NSWorkspace.shared.icon(forFile: bundle.bundlePath)
        )
    }

    var versionSummary: String {
        "Version \(version) (\(build))"
    }
}
