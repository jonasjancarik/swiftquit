//
//  AppRuleRowView.swift
//  Swift Quit
//

import SwiftUI

struct AppRuleRowView: View {
    let resolvedRule: ResolvedTrackedAppRule

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: resolvedRule.icon)
                .resizable()
                .frame(width: 24, height: 24)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(resolvedRule.displayName)
                    .font(.body)

                if let secondaryText = resolvedRule.secondaryText, !secondaryText.isEmpty {
                    Text(secondaryText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(.vertical, 2)
    }
}
