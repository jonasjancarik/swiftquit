//
//  AccessibilityPermissionController.swift
//  Swift Quit
//

import AppKit
@preconcurrency import ApplicationServices

struct ActivationPolicyRestoration {
    let previousPolicy: NSApplication.ActivationPolicy

    nonisolated func policyToRestore(after currentPolicy: NSApplication.ActivationPolicy) -> NSApplication.ActivationPolicy? {
        currentPolicy == previousPolicy ? nil : previousPolicy
    }
}

@MainActor
final class AccessibilityPermissionController {
    private(set) var isTrusted: Bool

    init() {
        isTrusted = AXIsProcessTrusted()
    }

    @discardableResult
    func refresh(promptIfNeeded: Bool = false) -> Bool {
        let trusted: Bool

        if promptIfNeeded {
            let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            let options = [promptKey: true] as CFDictionary
            trusted = AXIsProcessTrustedWithOptions(options)
        } else {
            trusted = AXIsProcessTrustedWithOptions(nil)
        }

        isTrusted = trusted
        return trusted
    }

    func openSystemSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else {
            return
        }

        NSWorkspace.shared.open(url)
    }

    func presentMissingPermissionAlert() {
        let alert = NSAlert()
        alert.messageText = "Accessibility Permission Required"
        alert.informativeText = """
        Swift Quit needs Accessibility access to detect when app windows close.

        Open System Settings, review Privacy & Security > Accessibility, then return to Swift Quit and it will re-check access automatically.
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open Accessibility Settings")
        alert.addButton(withTitle: "Later")

        let activationRestoration = ActivationPolicyRestoration(previousPolicy: NSApp.activationPolicy())
        prepareForModalPresentation()
        let response = alert.runModal()
        restoreActivationPolicyIfNeeded(using: activationRestoration)

        if response == .alertFirstButtonReturn {
            openSystemSettings()
        }
    }

    private func prepareForModalPresentation() {
        if NSApp.activationPolicy() != .regular {
            _ = NSApp.setActivationPolicy(.regular)
        }

        NSApp.activate()
    }

    private func restoreActivationPolicyIfNeeded(using activationRestoration: ActivationPolicyRestoration) {
        guard let policyToRestore = activationRestoration.policyToRestore(after: NSApp.activationPolicy()) else {
            return
        }

        _ = NSApp.setActivationPolicy(policyToRestore)
    }
}
