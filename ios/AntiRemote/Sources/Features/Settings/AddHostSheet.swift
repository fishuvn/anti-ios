import AntiCore
import SwiftUI

struct AddHostSheet: View {
    enum AuthMethod: String, CaseIterable, Identifiable {
        case pairingCode = "Pairing Code"
        case bearerToken = "Bearer Token"
        var id: String { rawValue }
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(ConnectionStore.self) private var connection

    @State private var name = ""
    @State private var urlString = ""
    @State private var authMethod: AuthMethod = .pairingCode
    @State private var pairingCode = ""
    @State private var bearerToken = ""
    @State private var isSubmitting = false
    @State private var errorMessage: String?

    @FocusState private var focusedField: Field?

    private enum Field {
        case name, url, secret
    }

    private var canSubmit: Bool {
        let trimmedURL = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty else { return false }
        switch authMethod {
        case .pairingCode:
            return pairingCode.trimmingCharacters(in: .whitespacesAndNewlines).count >= 4
        case .bearerToken:
            return bearerToken.trimmingCharacters(in: .whitespacesAndNewlines).count >= 16
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Host Label (optional)", text: $name)
                        .textContentType(.organizationName)
                        .focused($focusedField, equals: .name)
                        .submitLabel(.next)
                        .onSubmit { focusedField = .url }

                    TextField("https://100.x.y.z:8787 or http://192.168.1.10:8787", text: $urlString)
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focusedField, equals: .url)
                        .submitLabel(.next)
                        .onSubmit { focusedField = .secret }
                } header: {
                    Text("Bridge Endpoint")
                } footer: {
                    Text("Use HTTPS over Tailscale/VPN or local LAN IP (`NSAllowsLocalNetworking` enabled).")
                }

                Section("Authentication") {
                    Picker("Method", selection: $authMethod) {
                        ForEach(AuthMethod.allCases) { item in
                            Text(item.rawValue).tag(item)
                        }
                    }
                    .pickerStyle(.segmented)

                    if authMethod == .pairingCode {
                        TextField("One-Time Code (e.g. A7K9-M2P4)", text: $pairingCode)
                            .textContentType(.oneTimeCode)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                            .font(.body.monospaced())
                            .focused($focusedField, equals: .secret)
                    } else {
                        SecureField("Bridge Bearer Token", text: $bearerToken)
                            .textContentType(.password)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .focused($focusedField, equals: .secret)
                    }
                }

                if let errorMessage {
                    Section {
                        ErrorBannerView(message: errorMessage)
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                    }
                }
            }
            .navigationTitle("Add Remote Host")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSubmitting ? "Pairing..." : "Connect") {
                        Task { await submit() }
                    }
                    .disabled(!canSubmit || isSubmitting)
                }
            }
            .onAppear {
                focusedField = .url
            }
        }
    }

    private func submit() async {
        isSubmitting = true
        errorMessage = nil
        defer { isSubmitting = false }
        do {
            _ = try await connection.addManualHost(
                name: name,
                urlString: urlString,
                pairingCode: authMethod == .pairingCode ? pairingCode : nil,
                bearerToken: authMethod == .bearerToken ? bearerToken : nil
            )
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
