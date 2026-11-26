import SwiftUI

/// Wraps grouped controls in `GlassEffectContainer` on iOS 26+ (enabling Liquid Glass
/// merging and fluid morphing) while rendering transparently on iOS 18–25.
struct AdaptiveGlassGroup<Content: View>: View {
    let spacing: CGFloat
    @ViewBuilder let content: () -> Content

    init(spacing: CGFloat = 10, @ViewBuilder content: @escaping () -> Content) {
        self.spacing = spacing
        self.content = content
    }

    var body: some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) {
                content()
            }
        } else {
            content()
        }
        #else
        content()
        #endif
    }
}

enum AdaptiveInterfaceStyle {
    static var isLiquidGlassActive: Bool {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            return true
        }
        #endif
        return false
    }

    static var displayName: String {
        isLiquidGlassActive ? "Liquid Glass (iOS 26+)" : "Standard (iOS 18)"
    }
}

extension View {
    /// Applies Liquid Glass surface on iOS 26+, falling back to semantic surface + optional stroke on iOS 18–25.
    @ViewBuilder
    func adaptiveGlassSurface<S: InsettableShape>(
        in shape: S,
        tint: Color? = nil,
        interactive: Bool = false,
        fallbackBackground: Color = Color(.secondarySystemGroupedBackground),
        fallbackStroke: Color? = nil
    ) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            let base: Glass = {
                var glass = Glass.regular
                if let tint {
                    glass = glass.tint(tint)
                }
                if interactive {
                    glass = glass.interactive()
                }
                return glass
            }()
            self.glassEffect(base, in: shape)
        } else {
            legacySurface(in: shape, background: fallbackBackground, stroke: fallbackStroke)
        }
        #else
        legacySurface(in: shape, background: fallbackBackground, stroke: fallbackStroke)
        #endif
    }

    @ViewBuilder
    private func legacySurface<S: InsettableShape>(
        in shape: S,
        background: Color,
        stroke: Color?
    ) -> some View {
        if let stroke {
            self
                .background(background, in: shape)
                .overlay(shape.strokeBorder(stroke, lineWidth: 1))
        } else {
            self.background(background, in: shape)
        }
    }

    /// Uses `.buttonStyle(.glass)` on iOS 26+ and `.buttonStyle(.bordered)` on iOS 18–25.
    @ViewBuilder
    func adaptiveGlassButton() -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            self.buttonStyle(.glass)
        } else {
            self.buttonStyle(.bordered)
        }
        #else
        self.buttonStyle(.bordered)
        #endif
    }

    /// Uses `.buttonStyle(.glassProminent)` on iOS 26+ and `.buttonStyle(.borderedProminent)` on iOS 18–25.
    @ViewBuilder
    func adaptiveGlassProminentButton() -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            self.buttonStyle(.glassProminent)
        } else {
            self.buttonStyle(.borderedProminent)
        }
        #else
        self.buttonStyle(.borderedProminent)
        #endif
    }

    /// Minimizes the floating Liquid Glass tab bar on scroll down on iOS 26+; no-op on iOS 18–25.
    @ViewBuilder
    func adaptiveTabBarMinimizeOnScroll() -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            self.tabBarMinimizeBehavior(.onScrollDown)
        } else {
            self
        }
        #else
        self
        #endif
    }

    /// Attaches a floating top safe-area bar on iOS 26+ via `safeAreaBar(edge: .top)` and omits on iOS 18–25
    /// where the caller renders the compact inline header inside content.
    @ViewBuilder
    func adaptiveTopSafeAreaBar<BarContent: View>(
        @ViewBuilder content: @escaping () -> BarContent
    ) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            self.safeAreaBar(edge: .top) {
                content()
            }
        } else {
            self
        }
        #else
        self
        #endif
    }
}
