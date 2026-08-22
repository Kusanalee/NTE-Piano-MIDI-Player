import SwiftUI

/// One place that turns the user's glass-opacity preference into an actual background layer,
/// instead of scattering `.opacity(...)` calls across every card and panel in the app.
private struct GlassBackground: ViewModifier {
    var cornerRadius: CGFloat
    var opacity: Double

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.clear)
                    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                    .opacity(opacity)
            }
    }
}

extension View {
    /// Applies a Liquid Glass panel background whose visibility follows the user's
    /// "Glass opacity" setting.
    func glassPanel(cornerRadius: CGFloat = 16, opacity: Double) -> some View {
        modifier(GlassBackground(cornerRadius: cornerRadius, opacity: opacity))
    }
}
