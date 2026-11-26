import AntiCore
import SwiftUI

struct ConnectionStatusPill: View {
    let hostName: String
    let state: ConnectionState
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbolName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(tintColor)
                Text(hostName)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                    .foregroundStyle(.primary)
            }
            .padding(.horizontal, 10)
            .frame(minHeight: 36)
            .adaptiveGlassSurface(
                in: Capsule(),
                interactive: true,
                fallbackBackground: Color(.secondarySystemFill)
            )
        }
        .buttonStyle(.plain)
        .frame(minWidth: 44, minHeight: 44)
        .accessibilityLabel("Host \(hostName), \(state.label)")
        .accessibilityHint("Opens the host switcher.")
    }

    private var symbolName: String {
        switch state {
        case .connected: "checkmark.circle.fill"
        case .connecting: "arrow.triangle.2.circlepath"
        case .disconnected: "wifi.slash"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    private var tintColor: Color {
        switch state {
        case .connected: .green
        case .connecting: .orange
        case .disconnected: .secondary
        case .failed: .red
        }
    }
}

struct SemanticStatusBadge: View {
    let title: String
    let symbol: String
    let tone: Tone

    enum Tone {
        case positive
        case warning
        case negative
        case neutral

        var color: Color {
            switch self {
            case .positive: .green
            case .warning: .orange
            case .negative: .red
            case .neutral: .secondary
            }
        }
    }

    var body: some View {
        Label(title, systemImage: symbol)
            .font(.caption.weight(.semibold))
            .foregroundStyle(tone.color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(tone.color.opacity(0.14), in: Capsule())
            .accessibilityElement(children: .combine)
    }
}

#Preview("Status Badges") {
    VStack(spacing: 12) {
        ConnectionStatusPill(hostName: "Demo Rig", state: .connected(latencyMs: 14), action: {})
        ConnectionStatusPill(hostName: "dev-box", state: .failed("Timeout"), action: {})
        SemanticStatusBadge(title: "Running", symbol: "bolt.fill", tone: .positive)
        SemanticStatusBadge(title: "Stopped", symbol: "pause.circle.fill", tone: .neutral)
    }
    .padding()
}
