import SwiftUI

struct ErrorBannerView: View {
    let message: String
    var retryTitle: String = "Retry"
    var onRetry: (() -> Void)?

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .accessibilityHidden(true)

            Text(message)
                .font(.footnote)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let onRetry {
                Button(retryTitle, action: onRetry)
                    .font(.footnote.weight(.semibold))
                    .adaptiveGlassButton()
                    .controlSize(.small)
                    .frame(minHeight: 44)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .adaptiveGlassSurface(
            in: RoundedRectangle(cornerRadius: 14, style: .continuous),
            tint: Color.red.opacity(0.16),
            interactive: false,
            fallbackBackground: Color(.secondarySystemGroupedBackground),
            fallbackStroke: Color.red.opacity(0.35)
        )
        .accessibilityElement(children: .contain)
    }
}

#Preview("Error Banner") {
    ErrorBannerView(message: "Could not reach remote bridge at 192.168.1.42:8787.", onRetry: {})
        .padding()
}
