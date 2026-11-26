import SwiftUI

public enum AppTab: String, Identifiable, Hashable, CaseIterable, Sendable {
    case chat
    case control
    case workspace
    case settings

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .chat: "Chat"
        case .control: "Control"
        case .workspace: "Workspace"
        case .settings: "Settings"
        }
    }

    public var systemImage: String {
        switch self {
        case .chat: "bubble.left.and.text.bubble.right"
        case .control: "slider.horizontal.3"
        case .workspace: "folder"
        case .settings: "gear"
        }
    }
}

public enum Route: Hashable, Sendable {
    case workspaceDirectory(workspaceID: String, relativePath: String, title: String)
    case filePreview(workspaceID: String, relativePath: String, title: String)
}

public enum SheetDestination: Identifiable, Hashable, Sendable {
    case hostSwitcher
    case addHost
    case qrPairing(prefillURI: String? = nil)
    case commandPalette
    case sessionPicker

    public var id: String {
        switch self {
        case .hostSwitcher: "hostSwitcher"
        case .addHost: "addHost"
        case .qrPairing: "qrPairing"
        case .commandPalette: "commandPalette"
        case .sessionPicker: "sessionPicker"
        }
    }
}

@MainActor
@Observable
final class RouterPath {
    var path: [Route] = []
    var presentedSheet: SheetDestination?

    func navigate(to route: Route) {
        path.append(route)
    }

    func reset() {
        path = []
    }
}

@MainActor
@Observable
final class TabRouter {
    private var routers: [AppTab: RouterPath] = [:]

    func router(for tab: AppTab) -> RouterPath {
        if let existing = routers[tab] {
            return existing
        }
        let created = RouterPath()
        routers[tab] = created
        return created
    }

    func binding(for tab: AppTab) -> Binding<[Route]> {
        let router = router(for: tab)
        return Binding(
            get: { router.path },
            set: { router.path = $0 }
        )
    }

    func sheetBinding(for tab: AppTab) -> Binding<SheetDestination?> {
        let router = router(for: tab)
        return Binding(
            get: { router.presentedSheet },
            set: { router.presentedSheet = $0 }
        )
    }

    func resetAllPaths() {
        for router in routers.values {
            router.reset()
        }
    }
}
