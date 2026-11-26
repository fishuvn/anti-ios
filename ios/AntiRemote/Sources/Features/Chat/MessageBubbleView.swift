import AntiCore
import SwiftUI
import UIKit

struct MessageBubbleView: View {
    let message: ChatMessage
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showTools = false
    @State private var copied = false

    private var isUser: Bool { message.role == .user }

    var body: some View {
        VStack(alignment: isUser ? .trailing : .leading, spacing: 6) {
            HStack(spacing: 6) {
                if !isUser {
                    Image(systemName: "sparkles")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                        .accessibilityHidden(true)
                    Text("Antigravity")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                } else {
                    Spacer(minLength: 0)
                    if let cmd = message.slashCommand {
                        Text(cmd)
                            .font(.caption2.monospaced().weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.12), in: Capsule())
                    }
                    Text("Operator")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }

                if message.status == .streaming {
                    streamingIndicator
                } else if message.status == .cancelled {
                    SemanticStatusBadge(title: "Cancelled", symbol: "stop.circle", tone: .warning)
                } else if message.status == .failed {
                    SemanticStatusBadge(title: "Failed", symbol: "exclamationmark.circle", tone: .negative)
                }
            }

            if !message.toolEvents.isEmpty {
                toolEventsStrip
            }

            VStack(alignment: .leading, spacing: 8) {
                if message.content.isEmpty && message.status == .streaming {
                    Text("Streaming response...")
                        .font(.body)
                        .foregroundStyle(.secondary)
                } else {
                    Text(localizedMarkdown(message.content))
                        .font(.body)
                        .foregroundStyle(isUser ? Color.white : Color.primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(bubbleBackground, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .frame(maxWidth: isUser ? 320 : .infinity, alignment: isUser ? .trailing : .leading)
            .contextMenu {
                Button {
                    UIPasteboard.general.string = message.content
                    copied = true
                } label: {
                    Label("Copy Message", systemImage: "doc.on.doc")
                }
            }

            HStack(spacing: 12) {
                if isUser { Spacer(minLength: 0) }
                Text(message.createdAt, format: .dateTime.hour().minute())
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                if !isUser && !message.content.isEmpty && message.status != .streaming {
                    Button {
                        UIPasteboard.general.string = message.content
                        copied = true
                    } label: {
                        Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Copy assistant reply")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var streamingIndicator: some View {
        HStack(spacing: 4) {
            if reduceMotion {
                Image(systemName: "circle.fill")
                    .font(.caption2)
                    .foregroundStyle(Color.accentColor)
            } else {
                ProgressView()
                    .controlSize(.mini)
            }
            Text("Live")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Color.accentColor)
        }
        .accessibilityLabel("Streaming live response")
    }

    private var bubbleBackground: Color {
        if isUser {
            return Color.accentColor
        }
        return Color(.secondarySystemGroupedBackground)
    }

    @ViewBuilder
    private var toolEventsStrip: some View {
        DisclosureGroup(isExpanded: $showTools) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(message.toolEvents) { tool in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: toolSymbol(for: tool.status))
                            .font(.caption)
                            .foregroundStyle(toolTone(for: tool.status))
                            .padding(.top, 2)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(tool.name)
                                .font(.caption.monospaced().weight(.semibold))
                                .foregroundStyle(.primary)
                            Text(tool.summary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(.top, 6)
        } label: {
            Label(
                "\(message.toolEvents.count) tool \(message.toolEvents.count == 1 ? "event" : "events")",
                systemImage: "wrench.and.screwdriver"
            )
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func toolSymbol(for status: String) -> String {
        switch status.lowercased() {
        case "completed": "checkmark.circle.fill"
        case "failed": "xmark.circle.fill"
        default: "clock.arrow.circlepath"
        }
    }

    private func toolTone(for status: String) -> Color {
        switch status.lowercased() {
        case "completed": .green
        case "failed": .red
        default: .orange
        }
    }

    private func localizedMarkdown(_ raw: String) -> AttributedString {
        if let parsed = try? AttributedString(
            markdown: raw,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            return parsed
        }
        return AttributedString(raw)
    }
}

#Preview("Message Bubbles") {
    VStack(spacing: 12) {
        MessageBubbleView(message: ChatMessage(
            id: "1",
            role: .user,
            content: "/plan Audit remote deploy scripts",
            slashCommand: "/plan"
        ))
        MessageBubbleView(message: ChatMessage(
            id: "2",
            role: .assistant,
            content: "Execution plan drafted:\n1. Inspect `bridge/src/server.mjs`.\n2. Run `npm test`.",
            status: .completed,
            toolEvents: [
                ToolActivityEvent(id: "t1", name: "slash:/plan", status: "completed", summary: "Analyzed workspace", timestamp: Date()),
            ]
        ))
    }
    .padding()
}
