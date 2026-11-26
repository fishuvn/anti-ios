import UIKit

@MainActor
final class HapticManager {
    static let shared = HapticManager()

    enum Kind {
        case selection
        case lightImpact
        case mediumImpact
        case success
        case warning
        case error
    }

    private let selectionGenerator = UISelectionFeedbackGenerator()
    private let lightImpactGenerator = UIImpactFeedbackGenerator(style: .light)
    private let mediumImpactGenerator = UIImpactFeedbackGenerator(style: .medium)
    private let notificationGenerator = UINotificationFeedbackGenerator()

    private init() {
        selectionGenerator.prepare()
    }

    func fire(_ kind: Kind, enabled: Bool) {
        guard enabled else { return }
        switch kind {
        case .selection:
            selectionGenerator.selectionChanged()
        case .lightImpact:
            lightImpactGenerator.impactOccurred()
        case .mediumImpact:
            mediumImpactGenerator.impactOccurred()
        case .success:
            notificationGenerator.notificationOccurred(.success)
        case .warning:
            notificationGenerator.notificationOccurred(.warning)
        case .error:
            notificationGenerator.notificationOccurred(.error)
        }
    }
}
