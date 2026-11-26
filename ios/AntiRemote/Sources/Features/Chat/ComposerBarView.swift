import AntiCore
import SwiftUI

struct ComposerBarView: View {
    @Binding var text: String
    let quickCommands: [SlashCommandItem]
    let isStreaming: Bool
    let isSending: Bool
    let isDisabled: Bool
    var isFocused: FocusState<Bool>.Binding
    let onSend: () -> Void
    let onStop: () -> Void
    let onTriggerCommand: (SlashCommandItem) -> Void
    let onOpenPalette: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            if !quickCommands.isEmpty {
                quickSlashDeck
            }

            HStack(alignment: .bottom, spacing: 8) {
                Button(action: onOpenPalette) {
                    Image(systemName: "command")
                        .font(.body.weight(.semibold))
                        .frame(width: 44, height: 44)
                        .background(Color(.secondarySystemFill), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Slash commands")
                .accessibilityHint("Opens the full searchable slash-command deck.")

                TextField("Message Antigravity or type /command...", text: $text, axis: .vertical)
                    .lineLimit(1 ... 5)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .strokeBorder(Color(.separator).opacity(0.45), lineWidth: 1)
                    )
                    .focused(isFocused)
                    .submitLabel(.send)
                    .onSubmit {
                        if canSend { onSend() }
                    }
                    .disabled(isDisabled)

                if isStreaming {
                    Button(role: .destructive, action: onStop) {
                        Image(systemName: "stop.fill")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .background(Color.red, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Stop active run")
                } else {
                    Button(action: onSend) {
                        Group {
                            if isSending {
                                ProgressView()
                                    .tint(.white)
                            } else {
                                Image(systemName: "arrow.up")
                                    .font(.body.weight(.bold))
                                    .foregroundStyle(.white)
                            }
                        }
                        .frame(width: 44, height: 44)
                        .background(canSend ? Color.accentColor : Color(.quaternaryLabel), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSend)
                    .accessibilityLabel("Send message")
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
        .padding(.top, 8)
        .background(.bar)
        .overlay(alignment: .top) {
            Divider()
        }
    }

    private var canSend: Bool {
        !isDisabled && !isSending && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var quickSlashDeck: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(quickCommands.prefix(6)) { cmd in
                    Button {
                        onTriggerCommand(cmd)
                    } label: {
                        Label(cmd.command, systemImage: cmd.symbol)
                            .font(.footnote.monospaced().weight(.medium))
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 12)
                            .frame(minHeight: 36)
                            .background(Color(.secondarySystemGroupedBackground), in: Capsule())
                            .overlay(
                                Capsule()
                                    .strokeBorder(Color(.separator).opacity(0.4), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                    .frame(minHeight: 44)
                    .disabled(isDisabled || isSending)
                    .accessibilityLabel("\(cmd.title), \(cmd.command)")
                    .accessibilityHint(cmd.autoSend ? "Runs immediately on remote host." : "Inserts command into composer.")
                }
            }
            .padding(.horizontal, 12)
        }
    }
}

#Preview("Composer Bar") {
    @Previewable @State var draft = ""
    @Previewable @FocusState var focused: Bool
    ComposerBarView(
        text: $draft,
        quickCommands: [
            SlashCommandItem(id: "plan", command: "/plan", title: "Plan", description: "", symbol: "list.bullet.clipboard", category: "workflow", template: "/plan ", autoSend: false),
            SlashCommandItem(id: "agents", command: "/agents", title: "Agents", description: "", symbol: "person.3.sequence", category: "control", template: "/agents", autoSend: true),
            SlashCommandItem(id: "compact", command: "/compact", title: "Compact", description: "", symbol: "arrow.down.right.and.arrow.up.left", category: "session", template: "/compact", autoSend: true),
        ],
        isStreaming: false,
        isSending: false,
        isDisabled: false,
        isFocused: $focused,
        onSend: {},
        onStop: {},
        onTriggerCommand: { _ in },
        onOpenPalette: {}
    )
}
