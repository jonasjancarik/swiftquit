//
//  SettingsWindowController.swift
//  Swift Quit
//

import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let viewModel: SettingsViewModel
    private var activationPolicyBeforeShowingWindow: NSApplication.ActivationPolicy?

    private lazy var hostingController = NSHostingController(rootView: SettingsRootView(viewModel: viewModel))

    private lazy var window: NSWindow = {
        let window = NSWindow(contentViewController: hostingController)
        window.title = "Swift Quit"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 720, height: 620))
        window.minSize = NSSize(width: 720, height: 620)
        window.center()
        window.collectionBehavior = [.moveToActiveSpace]
        window.setFrameAutosaveName("SwiftQuitSettings")
        window.delegate = self
        return window
    }()

    init(viewModel: SettingsViewModel) {
        self.viewModel = viewModel
    }

    func show() {
        viewModel.handleSettingsWindowBecameVisible()
        activateForSettingsPresentation()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        reinforceForegroundPresentation()
    }

    func windowWillClose(_ notification: Notification) {
        restoreActivationPolicyIfNeeded()
    }

    private func activateForSettingsPresentation() {
        if activationPolicyBeforeShowingWindow == nil {
            activationPolicyBeforeShowingWindow = NSApp.activationPolicy()
        }

        if NSApp.activationPolicy() != .regular {
            _ = NSApp.setActivationPolicy(.regular)
        }

        _ = NSRunningApplication.current.activate(options: [.activateAllWindows])
        NSApp.activate()
    }

    private func restoreActivationPolicyIfNeeded() {
        guard let activationPolicyBeforeShowingWindow else {
            return
        }

        if NSApp.activationPolicy() != activationPolicyBeforeShowingWindow {
            _ = NSApp.setActivationPolicy(activationPolicyBeforeShowingWindow)
        }

        self.activationPolicyBeforeShowingWindow = nil
    }

    private func reinforceForegroundPresentation() {
        Task { @MainActor [weak self] in
            await Task.yield()

            guard let self else {
                return
            }

            activateForSettingsPresentation()
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
        }
    }
}
