//
//  SettingsRootView.swift
//  Swift Quit
//

import SwiftUI

struct SettingsRootView: View {
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        Form {
            if !viewModel.permissionGranted {
                Section {
                    PermissionBanner(viewModel: viewModel)
                }
            }

            BehaviorSection(viewModel: viewModel)
            SafetySection(viewModel: viewModel)
            RuleSection(viewModel: viewModel)
            DiagnosticsSection(viewModel: viewModel, diagnostics: viewModel.terminationDiagnostics)
            AboutSection(appInfo: viewModel.appInfo)

            if let errorMessage = viewModel.lastOperationErrorMessage {
                Section {
                    Text(errorMessage)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .accessibilityLabel("Error: \(errorMessage)")
                }
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .frame(minWidth: 720, minHeight: 620)
    }
}

private struct PermissionBanner: View {
    let viewModel: SettingsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Accessibility access is required for Swift Quit to monitor app windows.", systemImage: "hand.raised.fill")
                .font(.headline)

            Text("Open Privacy & Security > Accessibility, then return here and Swift Quit will re-check access automatically.")
                .foregroundStyle(.secondary)

            HStack {
                Button("Open Accessibility Settings", action: viewModel.openAccessibilitySettings)
                Button("Prompt Again", action: viewModel.recheckAccessibilityAccess)
            }
        }
        .padding(14)
        .permissionBannerSurface()
    }
}

private struct BehaviorSection: View {
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        Section("Behavior") {
            Toggle("Start Swift Quit at login", isOn: $viewModel.launchAtLoginEnabled)

            LabeledContent("Login item status") {
                Text(viewModel.loginItemState.title)
                    .foregroundStyle(viewModel.loginItemState.requiresAttention ? .orange : .secondary)
            }

            Text(viewModel.loginItemState.detail)
                .font(.callout)
                .foregroundStyle(.secondary)

            if viewModel.loginItemState.requiresAttention {
                Button("Open Login Items in System Settings", action: viewModel.openLoginItemsSettings)
            }

            Toggle("Show menu bar icon", isOn: $viewModel.menuBarIconEnabled)
            Toggle(
                "Hide settings after confirmed background launch",
                isOn: Binding(
                    get: { viewModel.launchHidden },
                    set: { viewModel.launchHidden = $0 }
                )
            )

            Text("Clicking the red close button quits an app when that is its last standard window. If other windows are open, only the clicked window closes.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

private struct SafetySection: View {
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        Section("Safety") {
            Toggle("Keep browsers and web apps running", isOn: $viewModel.protectBrowserHosts)
            Toggle("Keep accessory and background apps running", isOn: $viewModel.protectAccessoryApps)
            Toggle("Count minimized windows as open", isOn: $viewModel.countMinimizedWindowsAsOpen)
            Toggle("Count hidden apps and windows as open", isOn: $viewModel.countHiddenWindowsAsOpen)

            Text("Active protections: \(viewModel.activeSafetySummary.isEmpty ? "None" : viewModel.activeSafetySummary)")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

private struct RuleSection: View {
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        Section("App Rules") {
            Picker("Scope", selection: $viewModel.ruleMode) {
                ForEach(RuleMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }

            Text(viewModel.ruleModeSummary)
                .font(.callout)
                .foregroundStyle(.secondary)

            List(selection: $viewModel.selectedRuleIDs) {
                ForEach(viewModel.resolvedTrackedApps) { resolvedRule in
                    AppRuleRowView(resolvedRule: resolvedRule)
                        .tag(resolvedRule.id)
                }
            }
            .frame(minHeight: 220)
            .overlay {
                if viewModel.resolvedTrackedApps.isEmpty {
                    ContentUnavailableView(
                        "No Apps Listed",
                        systemImage: "app.badge",
                        description: Text("Add apps here to tailor Swift Quit's include or exclude list.")
                    )
                }
            }

            HStack {
                Button("Add App", systemImage: "plus", action: viewModel.addTrackedApp)
                Button("Remove Selected App", systemImage: "minus", action: viewModel.removeSelectedTrackedApps)
                    .disabled(viewModel.selectedRuleIDs.isEmpty)
            }
        }
    }
}

private struct DiagnosticsSection: View {
    @ObservedObject var viewModel: SettingsViewModel
    @ObservedObject var diagnostics: TerminationDiagnostics

    var body: some View {
        Section("Diagnostics") {
            LabeledContent("Accessibility") {
                Text(viewModel.permissionGranted ? "Granted" : "Missing")
                    .foregroundStyle(viewModel.permissionGranted ? Color.secondary : Color.orange)
            }

            LabeledContent("Launch at login") {
                Text(viewModel.loginItemState.title)
                    .foregroundStyle(viewModel.loginItemState.requiresAttention ? Color.orange : Color.secondary)
            }

            LabeledContent("Active safety") {
                Text(viewModel.activeSafetySummary.isEmpty ? "None" : viewModel.activeSafetySummary)
                    .foregroundStyle(.secondary)
            }

            if diagnostics.recentEntries.isEmpty {
                Text("No termination checks recorded yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(diagnostics.recentEntries.prefix(6)) { entry in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(entry.appName)
                                .font(.callout)
                            Spacer()
                            Text(entry.timestamp.formatted(date: .omitted, time: .standard))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Text("\(entry.decisionSummary) - \(entry.pollSummary)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }
}

private struct AboutSection: View {
    let appInfo: AppInfo

    var body: some View {
        Section("About") {
            HStack(spacing: 16) {
                Image(nsImage: appInfo.icon)
                    .resizable()
                    .frame(width: 48, height: 48)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    Text(appInfo.displayName)
                        .font(.headline)

                    Text(appInfo.versionSummary)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

private extension View {
    @ViewBuilder
    func permissionBannerSurface() -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        } else {
            self.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }
}
