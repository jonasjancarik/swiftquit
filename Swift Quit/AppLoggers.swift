//
//  AppLoggers.swift
//  Swift Quit
//

import Foundation
import OSLog

enum AppLoggers {
    nonisolated private static let subsystem = Bundle.main.bundleIdentifier ?? "onebadidea.Swift-Quit"

    nonisolated static let app = Logger(subsystem: subsystem, category: "App")
    nonisolated static let settings = Logger(subsystem: subsystem, category: "Settings")
    nonisolated static let accessibility = Logger(subsystem: subsystem, category: "Accessibility")
    nonisolated static let loginItem = Logger(subsystem: subsystem, category: "LoginItem")
    nonisolated static let termination = Logger(subsystem: subsystem, category: "Termination")
    nonisolated static let menuBar = Logger(subsystem: subsystem, category: "MenuBar")
}
