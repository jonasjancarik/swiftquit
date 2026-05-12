//
//  AccessibilityMonitor.swift
//  Swift Quit
//

import AppKit
@preconcurrency import ApplicationServices
import Foundation

@MainActor
protocol AccessibilityMonitoring: AnyObject {
    var windowChangeHandler: ((pid_t) -> Void)? { get set }
    func refreshTrustedState(isTrusted: Bool)
    func stop()
    func pollWindows(for application: NSRunningApplication) -> WindowPollResult
}

struct AccessibilityNotificationHandlingPolicy {
    func shouldRefreshWindowRegistrations(for notification: String) -> Bool {
        [
            kAXWindowCreatedNotification as String,
            kAXFocusedWindowChangedNotification as String,
            kAXApplicationShownNotification as String,
        ].contains(notification)
    }
}

@MainActor
final class AccessibilityMonitor: AccessibilityMonitoring {
    nonisolated private static let callback: AXObserverCallback = { _, element, notification, refcon in
        guard let refcon else {
            return
        }

        let monitor = Unmanaged<AccessibilityMonitor>.fromOpaque(refcon).takeUnretainedValue()
        let notificationName = notification as String
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)

        guard pid > 0 else {
            return
        }

        Task { @MainActor in
            monitor.handleNotification(pid: pid, notification: notificationName)
        }
    }

    private enum WindowElementCopyResult {
        case success([AXUIElement])
        case failure(AXError)
    }

    private enum WindowSnapshotResult {
        case success(WindowSnapshot)
        case stale
        case failure(String)
    }

    private enum OptionalBoolReadResult {
        case value(Bool)
        case unknown
        case stale
        case failure(String)
    }

    var windowChangeHandler: ((pid_t) -> Void)?

    private let notificationHandlingPolicy = AccessibilityNotificationHandlingPolicy()
    private var isTrusted = false
    private var observers: [pid_t: AXObserver] = [:]
    private var launchObserver: NSObjectProtocol?
    private var terminateObserver: NSObjectProtocol?

    func refreshTrustedState(isTrusted: Bool) {
        guard self.isTrusted != isTrusted else {
            if isTrusted {
                start()
            }
            return
        }

        self.isTrusted = isTrusted

        if isTrusted {
            start()
        } else {
            stop()
        }
    }

    func stop() {
        if let launchObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(launchObserver)
            self.launchObserver = nil
        }

        if let terminateObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(terminateObserver)
            self.terminateObserver = nil
        }

        observers.values.forEach {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource($0), .commonModes)
        }
        observers.removeAll()
    }

    func pollWindows(for application: NSRunningApplication) -> WindowPollResult {
        guard isTrusted else {
            return .ambiguous("Accessibility permission missing")
        }

        let appElement = AXUIElementCreateApplication(application.processIdentifier)

        switch copyWindowElements(for: appElement) {
        case .failure(let error):
            return .ambiguous("Failed to copy AX windows: \(describe(error: error))")
        case .success(let windows):
            var snapshots: [WindowSnapshot] = []

            for window in windows {
                switch snapshot(for: window) {
                case .failure(let message):
                    return .ambiguous(message)
                case .stale:
                    continue
                case .success(let snapshot):
                    snapshots.append(snapshot)
                }
            }

            return .windows(snapshots)
        }
    }

    private func start() {
        guard isTrusted else {
            return
        }

        if launchObserver == nil {
            let notificationCenter = NSWorkspace.shared.notificationCenter

            launchObserver = notificationCenter.addObserver(
                forName: NSWorkspace.didLaunchApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
                    return
                }

                let processIdentifier = application.processIdentifier
                Task { @MainActor [weak self] in
                    guard let application = NSRunningApplication(processIdentifier: processIdentifier) else {
                        return
                    }

                    self?.attach(to: application)
                }
            }

            terminateObserver = notificationCenter.addObserver(
                forName: NSWorkspace.didTerminateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
                    return
                }

                let processIdentifier = application.processIdentifier
                Task { @MainActor [weak self] in
                    self?.detachObserver(for: processIdentifier)
                }
            }
        }

        for application in NSWorkspace.shared.runningApplications {
            attach(to: application)
        }
    }

    private func attach(to application: NSRunningApplication) {
        guard shouldObserve(application) else {
            return
        }

        if observers[application.processIdentifier] != nil {
            return
        }

        var observerReference: AXObserver?
        let createResult = AXObserverCreate(application.processIdentifier, Self.callback, &observerReference)

        guard createResult == .success, let observerReference else {
            AppLoggers.accessibility.debug("Skipping PID \(application.processIdentifier, privacy: .public) AX observer: \(self.describe(error: createResult), privacy: .public)")
            return
        }

        observers[application.processIdentifier] = observerReference
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observerReference), .commonModes)

        let applicationElement = AXUIElementCreateApplication(application.processIdentifier)
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        register(notification: kAXWindowCreatedNotification as CFString, on: applicationElement, observer: observerReference, refcon: refcon)
        register(notification: kAXApplicationHiddenNotification as CFString, on: applicationElement, observer: observerReference, refcon: refcon)
        register(notification: kAXApplicationShownNotification as CFString, on: applicationElement, observer: observerReference, refcon: refcon)
        register(notification: kAXFocusedWindowChangedNotification as CFString, on: applicationElement, observer: observerReference, refcon: refcon)

        registerCurrentWindows(for: application.processIdentifier, observer: observerReference, refcon: refcon)
    }

    private func detachObserver(for pid: pid_t) {
        guard let observer = observers.removeValue(forKey: pid) else {
            return
        }

        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
    }

    private func registerCurrentWindows(for pid: pid_t, observer: AXObserver, refcon: UnsafeMutableRawPointer) {
        let applicationElement = AXUIElementCreateApplication(pid)

        switch copyWindowElements(for: applicationElement) {
        case .failure(let error):
            AppLoggers.accessibility.debug("Failed to register current windows for PID \(pid, privacy: .public): \(self.describe(error: error), privacy: .public)")
        case .success(let windows):
            windows.forEach { registerWindowNotifications(for: $0, observer: observer, refcon: refcon) }
        }
    }

    private func registerWindowNotifications(for element: AXUIElement, observer: AXObserver, refcon: UnsafeMutableRawPointer) {
        register(notification: kAXUIElementDestroyedNotification as CFString, on: element, observer: observer, refcon: refcon)
        register(notification: kAXWindowMiniaturizedNotification as CFString, on: element, observer: observer, refcon: refcon)
        register(notification: kAXWindowDeminiaturizedNotification as CFString, on: element, observer: observer, refcon: refcon)
        register(notification: kAXWindowMovedNotification as CFString, on: element, observer: observer, refcon: refcon)
        register(notification: kAXWindowResizedNotification as CFString, on: element, observer: observer, refcon: refcon)
    }

    private func register(
        notification: CFString,
        on element: AXUIElement,
        observer: AXObserver,
        refcon: UnsafeMutableRawPointer
    ) {
        let result = AXObserverAddNotification(observer, element, notification, refcon)

        switch result {
        case .success, .notificationAlreadyRegistered, .notificationUnsupported:
            return
        default:
            AppLoggers.accessibility.debug("AXObserverAddNotification failed: \(self.describe(error: result), privacy: .public)")
        }
    }

    private func handleNotification(pid: pid_t, notification: String) {
        if notificationHandlingPolicy.shouldRefreshWindowRegistrations(for: notification),
           let observer = observers[pid] {
            let refcon = Unmanaged.passUnretained(self).toOpaque()
            registerCurrentWindows(for: pid, observer: observer, refcon: refcon)
        }

        windowChangeHandler?(pid)
    }

    private func shouldObserve(_ application: NSRunningApplication) -> Bool {
        guard isTrusted else {
            return false
        }

        let pid = application.processIdentifier
        return pid > 0 && pid != ProcessInfo.processInfo.processIdentifier && !application.isTerminated
    }

    private func copyWindowElements(for applicationElement: AXUIElement) -> WindowElementCopyResult {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(applicationElement, kAXWindowsAttribute as CFString, &value)

        if error == .success, let windows = value as? [AXUIElement] {
            return .success(windows)
        }

        if error == .noValue {
            return .success([])
        }

        return .failure(error)
    }

    private func snapshot(for window: AXUIElement) -> WindowSnapshotResult {
        let roleResult = copyStringAttribute(kAXRoleAttribute as CFString, from: window)

        guard roleResult.error == .success else {
            return snapshotFailure(attribute: "AXRole", error: roleResult.error)
        }

        guard let role = roleResult.value else {
            return .stale
        }

        let subrole = copyStringAttribute(kAXSubroleAttribute as CFString, from: window)
        let title = copyStringAttribute(kAXTitleAttribute as CFString, from: window)
        let isMinimizedResult = copyOptionalBoolAttribute(kAXMinimizedAttribute as CFString, from: window)
        let hiddenResult = copyOptionalBoolAttribute(kAXHiddenAttribute as CFString, from: window)

        let isMinimized: Bool
        switch isMinimizedResult {
        case .value(let value):
            isMinimized = value
        case .unknown:
            isMinimized = false
        case .stale:
            return .stale
        case .failure(let message):
            return .failure(message)
        }

        let visibility: WindowVisibility
        switch hiddenResult {
        case .value(let isHidden):
            visibility = isHidden ? .hidden : .visible
        case .unknown:
            visibility = .unknown
        case .stale:
            return .stale
        case .failure(let message):
            return .failure(message)
        }

        return .success(
            WindowSnapshot(
                role: role,
                subrole: subrole.value,
                title: title.value,
                isMinimized: isMinimized,
                visibility: visibility
            )
        )
    }

    private func copyStringAttribute(_ attribute: CFString, from element: AXUIElement) -> (value: String?, error: AXError) {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute, &value)

        return (value as? String, error)
    }

    private func copyOptionalBoolAttribute(_ attribute: CFString, from element: AXUIElement) -> OptionalBoolReadResult {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute, &value)

        switch error {
        case .success:
            return .value((value as? Bool) ?? false)
        case .noValue, .attributeUnsupported:
            return .unknown
        case .invalidUIElement:
            return .stale
        default:
            return .failure("Failed to copy \(attribute): \(describe(error: error))")
        }
    }

    private func snapshotFailure(attribute: String, error: AXError) -> WindowSnapshotResult {
        switch error {
        case .invalidUIElement, .noValue:
            .stale
        case .attributeUnsupported:
            .stale
        default:
            .failure("Failed to copy \(attribute): \(describe(error: error))")
        }
    }

    private func describe(error: AXError) -> String {
        switch error {
        case .success:
            "success"
        case .failure:
            "failure"
        case .illegalArgument:
            "illegalArgument"
        case .invalidUIElement:
            "invalidUIElement"
        case .invalidUIElementObserver:
            "invalidUIElementObserver"
        case .cannotComplete:
            "cannotComplete"
        case .attributeUnsupported:
            "attributeUnsupported"
        case .actionUnsupported:
            "actionUnsupported"
        case .notificationUnsupported:
            "notificationUnsupported"
        case .notImplemented:
            "notImplemented"
        case .notificationAlreadyRegistered:
            "notificationAlreadyRegistered"
        case .notificationNotRegistered:
            "notificationNotRegistered"
        case .apiDisabled:
            "apiDisabled"
        case .noValue:
            "noValue"
        case .parameterizedAttributeUnsupported:
            "parameterizedAttributeUnsupported"
        case .notEnoughPrecision:
            "notEnoughPrecision"
        @unknown default:
            "unknown"
        }
    }
}
