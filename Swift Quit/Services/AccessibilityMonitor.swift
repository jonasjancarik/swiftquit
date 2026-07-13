//
//  AccessibilityMonitor.swift
//  Swift Quit
//

import AppKit
@preconcurrency import ApplicationServices
import Foundation

@MainActor
protocol AccessibilityMonitoring: AnyObject {
    var closeButtonClickHandler: ((CloseButtonClickEvent) -> Void)? { get set }
    func refreshTrustedState(isTrusted: Bool)
    func stop()
}

struct CloseButtonClickEvent: Equatable {
    let pid: pid_t
    let clickedWindow: WindowSnapshot
    let pollResult: WindowPollResult
    let clickedWindowIsPresent: Bool
}

@MainActor
final class AccessibilityMonitor: AccessibilityMonitoring {
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

    var closeButtonClickHandler: ((CloseButtonClickEvent) -> Void)?

    private let systemWideElement = AXUIElementCreateSystemWide()
    private var globalMouseMonitor: Any?
    private var isTrusted = false

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
        if let globalMouseMonitor {
            NSEvent.removeMonitor(globalMouseMonitor)
            self.globalMouseMonitor = nil
        }
    }

    private func start() {
        guard isTrusted, globalMouseMonitor == nil else {
            return
        }

        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            MainActor.assumeIsolated {
                self?.handleMouseDown(event)
            }
        }

        if globalMouseMonitor == nil {
            AppLoggers.accessibility.error("Failed to install the global close-button mouse monitor")
        } else {
            AppLoggers.accessibility.info("Global close-button mouse monitor started")
        }
    }

    private func handleMouseDown(_ event: NSEvent) {
        guard isTrusted, let screenPoint = screenPoint(for: event) else {
            return
        }

        var hitElement: AXUIElement?
        let hitResult = AXUIElementCopyElementAtPosition(
            systemWideElement,
            Float(screenPoint.x),
            Float(screenPoint.y),
            &hitElement
        )

        guard hitResult == .success,
              let hitElement,
              copyStringAttribute(kAXSubroleAttribute as CFString, from: hitElement).value == kAXCloseButtonSubrole as String else {
            return
        }

        switch copyOptionalBoolAttribute(kAXEnabledAttribute as CFString, from: hitElement) {
        case .value(true):
            break
        case .value(false), .unknown, .stale, .failure:
            return
        }

        var pid: pid_t = 0
        guard AXUIElementGetPid(hitElement, &pid) == .success,
              pid > 0,
              pid != ProcessInfo.processInfo.processIdentifier,
              let clickedWindow = containingWindow(for: hitElement) else {
            return
        }

        guard case .success(let clickedWindowSnapshot) = snapshot(for: clickedWindow) else {
            return
        }

        let applicationElement = AXUIElementCreateApplication(pid)

        switch copyWindowElements(for: applicationElement) {
        case .failure(let error):
            closeButtonClickHandler?(
                CloseButtonClickEvent(
                    pid: pid,
                    clickedWindow: clickedWindowSnapshot,
                    pollResult: .ambiguous("Failed to copy AX windows: \(describe(error: error))"),
                    clickedWindowIsPresent: false
                )
            )

        case .success(let windows):
            let clickedWindowIsPresent = windows.contains { CFEqual($0, clickedWindow) }
            var snapshots: [WindowSnapshot] = []

            for window in windows {
                switch snapshot(for: window) {
                case .success(let windowSnapshot):
                    snapshots.append(windowSnapshot)
                case .stale:
                    closeButtonClickHandler?(
                        CloseButtonClickEvent(
                            pid: pid,
                            clickedWindow: clickedWindowSnapshot,
                            pollResult: .ambiguous("A window disappeared during the close-button check"),
                            clickedWindowIsPresent: clickedWindowIsPresent
                        )
                    )
                    return
                case .failure(let message):
                    closeButtonClickHandler?(
                        CloseButtonClickEvent(
                            pid: pid,
                            clickedWindow: clickedWindowSnapshot,
                            pollResult: .ambiguous(message),
                            clickedWindowIsPresent: clickedWindowIsPresent
                        )
                    )
                    return
                }
            }

            closeButtonClickHandler?(
                CloseButtonClickEvent(
                    pid: pid,
                    clickedWindow: clickedWindowSnapshot,
                    pollResult: .windows(snapshots),
                    clickedWindowIsPresent: clickedWindowIsPresent
                )
            )
        }
    }

    private func screenPoint(for event: NSEvent) -> CGPoint? {
        event.cgEvent?.location
    }

    private func containingWindow(for element: AXUIElement) -> AXUIElement? {
        var currentElement = element

        for _ in 0..<8 {
            let role = copyStringAttribute(kAXRoleAttribute as CFString, from: currentElement).value
            if role == kAXWindowRole as String || role == kAXSheetRole as String {
                return currentElement
            }

            guard let parent = copyElementAttribute(kAXParentAttribute as CFString, from: currentElement) else {
                return nil
            }

            currentElement = parent
        }

        return nil
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

    private func copyElementAttribute(_ attribute: CFString, from element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }

        return unsafeDowncast(value, to: AXUIElement.self)
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
        case .invalidUIElement, .noValue, .attributeUnsupported:
            .stale
        default:
            .failure("Failed to copy \(attribute): \(describe(error: error))")
        }
    }

    private func describe(error: AXError) -> String {
        switch error {
        case .success: "success"
        case .failure: "failure"
        case .illegalArgument: "illegalArgument"
        case .invalidUIElement: "invalidUIElement"
        case .invalidUIElementObserver: "invalidUIElementObserver"
        case .cannotComplete: "cannotComplete"
        case .attributeUnsupported: "attributeUnsupported"
        case .actionUnsupported: "actionUnsupported"
        case .notificationUnsupported: "notificationUnsupported"
        case .notImplemented: "notImplemented"
        case .notificationAlreadyRegistered: "notificationAlreadyRegistered"
        case .notificationNotRegistered: "notificationNotRegistered"
        case .apiDisabled: "apiDisabled"
        case .noValue: "noValue"
        case .parameterizedAttributeUnsupported: "parameterizedAttributeUnsupported"
        case .notEnoughPrecision: "notEnoughPrecision"
        @unknown default: "unknown"
        }
    }
}
