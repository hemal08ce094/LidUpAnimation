import SwiftUI

/// Liquid Glass where the OS supports it (macOS 26+), a plain material
/// underneath on macOS 15–25. Same shape either way, so nothing jumps
/// around when this ships on an older system.
private struct AdaptiveGlassBackground: ViewModifier {
    var cornerRadius: CGFloat

    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius))
        } else {
            content.background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
        }
    }
}

extension View {
    func adaptiveGlass(cornerRadius: CGFloat = 16) -> some View {
        modifier(AdaptiveGlassBackground(cornerRadius: cornerRadius))
    }
}
