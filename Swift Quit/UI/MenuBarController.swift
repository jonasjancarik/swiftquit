//
//  MenuBarController.swift
//  Swift Quit
//

import AppKit

@MainActor
final class MenuBarController: NSObject {
    private enum Constants {
        static let fallbackTitle = "SQ"
        static let buttonToolTip = "Swift Quit"
        static let symbolName = "xmark.circle"
    }

    private let openSettingsAction: () -> Void
    private let openDiagnosticsAction: () -> Void
    private let togglePauseAction: () -> Bool
    private let terminateAction: () -> Void

    private var statusItem: NSStatusItem?
    private var pauseItem: NSMenuItem?
    private var isPaused = false

    init(
        openSettingsAction: @escaping () -> Void,
        openDiagnosticsAction: @escaping () -> Void,
        togglePauseAction: @escaping () -> Bool,
        terminateAction: @escaping () -> Void
    ) {
        self.openSettingsAction = openSettingsAction
        self.openDiagnosticsAction = openDiagnosticsAction
        self.togglePauseAction = togglePauseAction
        self.terminateAction = terminateAction
        super.init()
    }

    func setVisible(_ isVisible: Bool) {
        if isVisible {
            ensureStatusItem()
        } else {
            removeStatusItem()
        }
    }

    private func ensureStatusItem() {
        guard statusItem == nil else {
            return
        }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()

        let settingsItem = menuItem(
            title: "Settings...",
            systemImage: "gearshape",
            action: #selector(openSettingsMenuItemSelected),
            keyEquivalent: ","
        )
        menu.addItem(settingsItem)

        let diagnosticsItem = menuItem(
            title: "Diagnostics",
            systemImage: "stethoscope",
            action: #selector(openDiagnosticsMenuItemSelected)
        )
        menu.addItem(diagnosticsItem)

        let pauseItem = menuItem(
            title: pauseTitle,
            systemImage: pauseSystemImage,
            action: #selector(togglePauseMenuItemSelected)
        )
        self.pauseItem = pauseItem
        menu.addItem(pauseItem)

        menu.addItem(.separator())

        let quitItem = menuItem(
            title: "Quit Swift Quit",
            systemImage: "power",
            action: #selector(quitMenuItemSelected),
            keyEquivalent: "q"
        )
        menu.addItem(quitItem)

        item.menu = menu

        if let button = item.button {
            configure(button: button)
        }

        statusItem = item
        AppLoggers.menuBar.info("Menu bar item shown")
    }

    private func removeStatusItem() {
        guard let statusItem else {
            return
        }

        NSStatusBar.system.removeStatusItem(statusItem)
        self.statusItem = nil
        self.pauseItem = nil
        AppLoggers.menuBar.info("Menu bar item hidden")
    }

    @objc
    private func openSettingsMenuItemSelected() {
        openSettingsAction()
    }

    @objc
    private func openDiagnosticsMenuItemSelected() {
        openDiagnosticsAction()
    }

    @objc
    private func togglePauseMenuItemSelected() {
        isPaused = togglePauseAction()
        pauseItem?.title = pauseTitle
        pauseItem?.image = symbolImage(named: pauseSystemImage, accessibilityDescription: pauseTitle)
    }

    @objc
    private func quitMenuItemSelected() {
        terminateAction()
    }

    private func configure(button: NSStatusBarButton) {
        button.toolTip = Constants.buttonToolTip
        button.imagePosition = .imageOnly
        button.title = ""

        if let menuBarImage = loadMenuBarImage() {
            button.image = menuBarImage
            return
        }

        button.image = nil
        button.title = Constants.fallbackTitle
        button.imagePosition = .noImage
        AppLoggers.menuBar.error("Failed to load menu bar icon asset; using text fallback")
    }

    private func loadMenuBarImage() -> NSImage? {
        if let assetImage = NSImage(named: NSImage.Name("MenuIcon")) {
            assetImage.isTemplate = true
            assetImage.size = NSSize(width: 18, height: 18)
            return assetImage
        }

        guard let symbolImage = NSImage(
            systemSymbolName: Constants.symbolName,
            accessibilityDescription: Constants.buttonToolTip
        ) else {
            return nil
        }

        symbolImage.isTemplate = true
        symbolImage.size = NSSize(width: 18, height: 18)
        AppLoggers.menuBar.notice("Menu bar icon asset was unavailable; using SF Symbol fallback")
        return symbolImage
    }

    private var pauseTitle: String {
        isPaused ? "Resume Monitoring" : "Pause Monitoring"
    }

    private var pauseSystemImage: String {
        isPaused ? "play.fill" : "pause.fill"
    }

    private func menuItem(
        title: String,
        systemImage: String,
        action: Selector,
        keyEquivalent: String = ""
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        item.image = symbolImage(named: systemImage, accessibilityDescription: title)
        return item
    }

    private func symbolImage(named name: String, accessibilityDescription: String) -> NSImage? {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: accessibilityDescription)
        image?.isTemplate = true
        return image
    }
}
