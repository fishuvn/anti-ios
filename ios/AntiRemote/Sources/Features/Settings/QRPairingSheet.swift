import AntiCore
@preconcurrency import AVFoundation
import SwiftUI
import UIKit

struct QRPairingSheet: View {
    let prefillURI: String?

    @Environment(\.dismiss) private var dismiss
    @Environment(ConnectionStore.self) private var connection

    @State private var cameraStatus: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
    @State private var manualURI: String
    @State private var isClaiming = false
    @State private var errorMessage: String?

    init(prefillURI: String? = nil) {
        self.prefillURI = prefillURI
        _manualURI = State(initialValue: prefillURI ?? "")
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    cameraSection

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Or Paste Pairing Link")
                            .font(.headline)

                        TextField("antiremote://pair?url=...&code=...", text: $manualURI, axis: .vertical)
                            .font(.footnote.monospaced())
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .padding(12)
                            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                        Button {
                            Task { await claim(uri: manualURI) }
                        } label: {
                            Group {
                                if isClaiming {
                                    ProgressView()
                                } else {
                                    Label("Pair Host", systemImage: "link.badge.plus")
                                }
                            }
                            .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isClaiming || manualURI.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    .padding(.horizontal)

                    if let errorMessage {
                        ErrorBannerView(message: errorMessage)
                            .padding(.horizontal)
                    }
                }
                .padding(.vertical)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Pair Remote Bridge")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task {
                if let prefillURI, !prefillURI.isEmpty {
                    await claim(uri: prefillURI)
                }
            }
        }
    }

    @ViewBuilder
    private var cameraSection: some View {
        #if targetEnvironment(simulator)
        ContentUnavailableView(
            "Camera Unavailable in Simulator",
            systemImage: "qrcode.viewfinder",
            description: Text("Paste the `antiremote://pair?...` URI printed by your remote bridge below to pair.")
        )
        .padding(.horizontal)
        #else
        switch cameraStatus {
        case .notDetermined:
            VStack(spacing: 12) {
                Image(systemName: "qrcode.viewfinder")
                    .font(.largeTitle)
                    .foregroundStyle(Color.accentColor)
                Text("Scan Terminal QR Code")
                    .font(.headline)
                Text("Camera access is used solely on-device to read the one-time pairing QR printed by `antiremote-bridge` on your remote machine.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Allow Camera & Scan") {
                    Task {
                        let granted = await AVCaptureDevice.requestAccess(for: .video)
                        cameraStatus = granted ? .authorized : .denied
                    }
                }
                .buttonStyle(.borderedProminent)
                .frame(minHeight: 44)
            }
            .padding(20)
            .frame(maxWidth: .infinity)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .padding(.horizontal)

        case .authorized:
            QRScannerPreview { scanned in
                guard !isClaiming else { return }
                manualURI = scanned
                Task { await claim(uri: scanned) }
            }
            .frame(height: 280)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(0.6), lineWidth: 2)
            )
            .padding(.horizontal)
            .accessibilityLabel("QR code viewfinder")

        case .denied, .restricted:
            ContentUnavailableView {
                Label("Camera Access Disabled", systemImage: "camera.fill")
            } description: {
                Text("Enable Camera in iOS Settings to scan QR codes, or paste the pairing link below.")
            } actions: {
                if let settingsURL = URL(string: UIApplication.openSettingsURLString) {
                    Link("Open Settings", destination: settingsURL)
                        .buttonStyle(.bordered)
                }
            }
            .padding(.horizontal)

        @unknown default:
            EmptyView()
        }
        #endif
    }

    private func claim(uri: String) async {
        isClaiming = true
        errorMessage = nil
        defer { isClaiming = false }
        do {
            _ = try await connection.pairHost(from: uri)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

#if !targetEnvironment(simulator)
private struct QRScannerPreview: UIViewRepresentable {
    let onDetect: @MainActor (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onDetect: onDetect)
    }

    func makeUIView(context: Context) -> PreviewContainerView {
        let view = PreviewContainerView()
        context.coordinator.configure(in: view)
        return view
    }

    func updateUIView(_ uiView: PreviewContainerView, context: Context) {}

    static func dismantleUIView(_ uiView: PreviewContainerView, coordinator: Coordinator) {
        coordinator.stop()
    }

    final class PreviewContainerView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer {
            layer as! AVCaptureVideoPreviewLayer
        }
    }

    final class Coordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate, @unchecked Sendable {
        private let onDetect: @MainActor (String) -> Void
        private let session = AVCaptureSession()
        private let queue = DispatchQueue(label: "com.antiremote.qr.session")
        private var hasEmitted = false

        init(onDetect: @escaping @MainActor (String) -> Void) {
            self.onDetect = onDetect
        }

        @MainActor
        func configure(in view: PreviewContainerView) {
            view.previewLayer.session = session
            view.previewLayer.videoGravity = .resizeAspectFill
            queue.async { [self] in
                guard let device = AVCaptureDevice.default(for: .video),
                      let input = try? AVCaptureDeviceInput(device: device),
                      self.session.canAddInput(input)
                else { return }

                self.session.beginConfiguration()
                self.session.addInput(input)
                let output = AVCaptureMetadataOutput()
                if self.session.canAddOutput(output) {
                    self.session.addOutput(output)
                    output.setMetadataObjectsDelegate(self, queue: self.queue)
                    output.metadataObjectTypes = [.qr]
                }
                self.session.commitConfiguration()
                self.session.startRunning()
            }
        }

        func stop() {
            queue.async { [self] in
                if self.session.isRunning {
                    self.session.stopRunning()
                }
            }
        }

        nonisolated func metadataOutput(
            _ output: AVCaptureMetadataOutput,
            didOutput metadataObjects: [AVMetadataObject],
            from connection: AVCaptureConnection
        ) {
            guard !hasEmitted,
                  let obj = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
                  let value = obj.stringValue,
                  value.lowercased().hasPrefix("antiremote://")
            else { return }
            hasEmitted = true
            session.stopRunning()
            Task { @MainActor in
                self.onDetect(value)
            }
        }
    }
}
#endif
