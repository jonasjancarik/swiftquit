//
//  TerminationController.swift
//  Swift Quit
//

import AppKit
import Combine
import Foundation

struct TerminationDiagnosticEntry: Identifiable, Equatable {
    let id = UUID()
    let timestamp: Date
    let appName: String
    let pid: pid_t
    let pollSummary: String
    let decisionSummary: String
}

@MainActor
final class TerminationDiagnostics: ObservableObject {
    @Published private(set) var recentEntries: [TerminationDiagnosticEntry] = []

    func record(appName: String, pid: pid_t, pollSummary: String, decisionSummary: String, now: Date) {
        recentEntries.insert(
            TerminationDiagnosticEntry(
                timestamp: now,
                appName: appName,
                pid: pid,
                pollSummary: pollSummary,
                decisionSummary: decisionSummary
            ),
            at: 0
        )

        if recentEntries.count > 20 {
            recentEntries.removeLast(recentEntries.count - 20)
        }
    }

    func clear() {
        recentEntries.removeAll()
    }
}

struct TerminationCooldownTracker {
    private let cooldownDuration: TimeInterval
    private(set) var expirationDates: [pid_t: Date] = [:]

    nonisolated init(cooldownDuration: TimeInterval) {
        self.cooldownDuration = cooldownDuration
    }

    @discardableResult
    nonisolated mutating func recordCooldown(for pid: pid_t, now: Date) -> Date {
        let expirationDate = now.addingTimeInterval(cooldownDuration)
        expirationDates[pid] = expirationDate
        return expirationDate
    }

    nonisolated mutating func isCoolingDown(for pid: pid_t, now: Date) -> Bool {
        guard let expirationDate = expirationDates[pid] else {
            return false
        }

        if expirationDate <= now {
            expirationDates.removeValue(forKey: pid)
            return false
        }

        return true
    }

    @discardableResult
    nonisolated mutating func clear(for pid: pid_t) -> Bool {
        expirationDates.removeValue(forKey: pid) != nil
    }

    nonisolated mutating func clearAll() {
        expirationDates.removeAll()
    }

    @discardableResult
    nonisolated mutating func clearIfAppHasOpenWindows(
        for pid: pid_t,
        pollResult: WindowPollResult,
        safetyOptions: SafetyOptions
    ) -> Bool {
        guard case .windows(let windows) = pollResult,
              windows.contains(where: { $0.qualifiesAsOpen(using: safetyOptions) }) else {
            return false
        }

        return clear(for: pid)
    }
}

@MainActor
final class TerminationController {
    struct Configuration {
        var terminationGracePeriod: TimeInterval = 1
        var refusalCooldown: TimeInterval = 5
    }

    private let settingsStore: SettingsStore
    private let monitor: AccessibilityMonitoring
    private let engine: TerminationEngine
    private let diagnostics: TerminationDiagnostics
    private let configuration: Configuration
    private let now: () -> Date

    private var tasksByPID: [pid_t: Task<Void, Never>] = [:]
    private var cooldownTracker: TerminationCooldownTracker
    private var pendingTerminationVerificationPIDs = Set<pid_t>()
    private(set) var isPaused = false

    init(
        settingsStore: SettingsStore,
        monitor: AccessibilityMonitoring,
        engine: TerminationEngine,
        diagnostics: TerminationDiagnostics,
        configuration: Configuration = Configuration(),
        now: @escaping () -> Date = Date.init
    ) {
        self.settingsStore = settingsStore
        self.monitor = monitor
        self.engine = engine
        self.diagnostics = diagnostics
        self.configuration = configuration
        self.now = now
        self.cooldownTracker = TerminationCooldownTracker(cooldownDuration: configuration.refusalCooldown)

        self.monitor.windowChangeHandler = { [weak self] pid in
            self?.handleWindowChange(for: pid)
        }
    }

    func cancelAll() {
        tasksByPID.values.forEach { $0.cancel() }
        tasksByPID.removeAll()
        pendingTerminationVerificationPIDs.removeAll()
        cooldownTracker.clearAll()
        diagnostics.clear()
    }

    func setPaused(_ isPaused: Bool) {
        self.isPaused = isPaused

        if isPaused {
            tasksByPID.values.forEach { $0.cancel() }
            tasksByPID.removeAll()
            pendingTerminationVerificationPIDs.removeAll()
        }

        AppLoggers.termination.info("Termination monitoring \(isPaused ? "paused" : "resumed", privacy: .public)")
    }

    private func handleWindowChange(for pid: pid_t) {
        guard pid != ProcessInfo.processInfo.processIdentifier else {
            return
        }

        guard !isPaused else {
            AppLoggers.termination.debug("Ignoring window change for PID \(pid, privacy: .public) while monitoring is paused")
            return
        }

        guard !pendingTerminationVerificationPIDs.contains(pid) else {
            AppLoggers.termination.debug("Ignoring window change for PID \(pid, privacy: .public) while quit verification is pending")
            return
        }

        cancelTask(for: pid)
        scheduleEvaluation(for: pid, attempt: 0, after: TimeInterval(settingsStore.settings.closeDelaySeconds))
    }

    private func scheduleEvaluation(for pid: pid_t, attempt: Int, after delay: TimeInterval) {
        tasksByPID[pid] = Task { [weak self] in
            guard let self else {
                return
            }

            if delay > 0 {
                try? await Task.sleep(for: .seconds(delay))
            }

            guard !Task.isCancelled else {
                return
            }

            self.evaluate(pid: pid, attempt: attempt)
        }
    }

    private func evaluate(pid: pid_t, attempt: Int) {
        guard let application = NSRunningApplication(processIdentifier: pid), !application.isTerminated else {
            clearTracking(for: pid)
            return
        }

        let appName = application.localizedName ?? "<unknown>"
        let settings = settingsStore.settings
        let pollResult = monitor.pollWindows(for: application)

        if cooldownTracker.clearIfAppHasOpenWindows(
            for: pid,
            pollResult: pollResult,
            safetyOptions: settings.safetyOptions
        ) {
            AppLoggers.termination.debug("Cleared cooldown for PID \(pid, privacy: .public) because open windows returned")
        }

        let decision = engine.evaluate(
            app: ApplicationSnapshot(application: application),
            pollResult: pollResult,
            settings: settings,
            attempt: attempt
        )
        let pollSummary = pollDescription(pollResult, safetyOptions: settings.safetyOptions)
        let decisionSummary = decisionDescription(decision)

        AppLoggers.termination.debug(
            "Evaluated PID \(pid, privacy: .public) (\(appName, privacy: .public)): poll=\(pollSummary, privacy: .public), decision=\(decisionSummary, privacy: .public)"
        )
        diagnostics.record(
            appName: appName,
            pid: pid,
            pollSummary: pollSummary,
            decisionSummary: decisionSummary,
            now: now()
        )

        if cooldownTracker.isCoolingDown(for: pid, now: now()) {
            switch decision {
            case .skip:
                break
            case .retry, .terminate:
                AppLoggers.termination.notice("Suppressing PID \(pid, privacy: .public) while quit cooldown is active")
                cancelTask(for: pid)
                return
            }
        }

        switch decision {
        case .terminate:
            attemptTermination(application, pid: pid)

        case .skip(let reason):
            AppLoggers.termination.debug("Skipping termination for PID \(pid, privacy: .public): \(reason, privacy: .public)")
            cancelTask(for: pid)

        case .retry(let delay, let reason):
            AppLoggers.termination.debug("Retrying termination check for PID \(pid, privacy: .public): \(reason, privacy: .public)")
            scheduleEvaluation(for: pid, attempt: attempt + 1, after: delay)
        }
    }

    private func cancelTask(for pid: pid_t) {
        tasksByPID[pid]?.cancel()
        tasksByPID.removeValue(forKey: pid)
    }

    private func clearTracking(for pid: pid_t) {
        pendingTerminationVerificationPIDs.remove(pid)
        _ = cooldownTracker.clear(for: pid)
        cancelTask(for: pid)
    }

    private func attemptTermination(_ application: NSRunningApplication, pid: pid_t) {
        let appName = application.localizedName ?? "<unknown>"
        AppLoggers.termination.info("Requesting termination for \(appName, privacy: .public)")

        let accepted = application.terminate()
        guard accepted else {
            let expirationDate = cooldownTracker.recordCooldown(for: pid, now: now())
            AppLoggers.termination.notice(
                "Terminate request was refused for PID \(pid, privacy: .public); entering cooldown until \(expirationDate.formatted(), privacy: .public)"
            )
            cancelTask(for: pid)
            return
        }

        pendingTerminationVerificationPIDs.insert(pid)
        AppLoggers.termination.debug("Terminate request accepted for PID \(pid, privacy: .public); verifying shutdown after grace period")
        scheduleGraceCheck(for: pid, appName: appName)
    }

    private func scheduleGraceCheck(for pid: pid_t, appName: String) {
        tasksByPID[pid] = Task { [weak self] in
            guard let self else {
                return
            }

            if configuration.terminationGracePeriod > 0 {
                try? await Task.sleep(for: .seconds(configuration.terminationGracePeriod))
            }

            guard !Task.isCancelled else {
                return
            }

            self.verifyTerminationOutcome(for: pid, appName: appName)
        }
    }

    private func verifyTerminationOutcome(for pid: pid_t, appName: String) {
        defer {
            pendingTerminationVerificationPIDs.remove(pid)
        }

        guard let application = NSRunningApplication(processIdentifier: pid), !application.isTerminated else {
            AppLoggers.termination.info("\(appName, privacy: .public) terminated successfully")
            clearTracking(for: pid)
            return
        }

        let expirationDate = cooldownTracker.recordCooldown(for: pid, now: now())
        AppLoggers.termination.notice(
            "\(appName, privacy: .public) remained alive after a quit request; entering cooldown until \(expirationDate.formatted(), privacy: .public)"
        )
        cancelTask(for: pid)
    }

    private func pollDescription(_ pollResult: WindowPollResult, safetyOptions: SafetyOptions) -> String {
        switch pollResult {
        case .ambiguous(let reason):
            return "ambiguous(\(reason))"
        case .windows(let windows):
            let qualifyingCount = windows.filter { $0.qualifiesAsOpen(using: safetyOptions) }.count
            return "windows(total: \(windows.count), qualifying: \(qualifyingCount))"
        }
    }

    private func decisionDescription(_ decision: TerminationDecision) -> String {
        switch decision {
        case .terminate:
            "terminate"
        case .skip(let reason):
            "skip(\(reason))"
        case .retry(let delay, let reason):
            "retry(after: \(delay), reason: \(reason))"
        }
    }
}
