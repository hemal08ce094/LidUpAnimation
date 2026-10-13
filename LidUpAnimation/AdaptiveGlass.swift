import SwiftUI

/// Liquid Glass where the OS supports it (macOS 26+), a plain material
/// underneath on macOS 15–25. Same shape either way, so nothing jumps
/// around when this ships on an older system.
private struct AdaptiveGlassBackground: ViewModifier {
    var cornerRadius: CGFloat

    // Offscreen store-stage snapshots cannot draw glass vibrancy, so they use the material.
    #if DEBUG
    private let usesGlass = ProcessInfo.processInfo.environment["STAGE_SNAP"] == nil
    #else
    private let usesGlass = true
    #endif

    func body(content: Content) -> some View {
        if #available(macOS 26, *), usesGlass {
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
