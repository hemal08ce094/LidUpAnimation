import SwiftUI

/// A visual mood for the fold.
///
/// Each style layers a duotone wash over the live picture that deepens as
/// the fold progresses, on top of the same blur-and-darken model every
/// style shares. `classic` has zero strength, so it renders pixel-for-pixel
/// the way the original release always has.
enum FoldStyle: String, CaseIterable, Identifiable, Codable, Sendable {
    case classic
    case auroraGlass
    case inkWash
    case coolDusk

    var id: String { rawValue }

    var title: String {
        switch self {
        case .classic: return "Classic"
        case .auroraGlass: return "Aurora Glass"
        case .inkWash: return "Ink Wash"
        case .coolDusk: return "Cool Dusk"
        }
    }

    var subtitle: String {
        switch self {
        case .classic: return "The original fold. Neutral black, no tint."
        case .auroraGlass: return "A cool violet-to-teal glow along the hinge."
        case .inkWash: return "Warm sepia, like ink settling on paper."
        case .coolDusk: return "Deep indigo dusk with a faint blue rim."
        }
    }

    var symbolName: String {
        switch self {
        case .classic: return "laptopcomputer"
        case .auroraGlass: return "sparkles"
        case .inkWash: return "scribble.variable"
        case .coolDusk: return "moon.stars.fill"
        }
    }

    /// Swatch colours for the picker UI. These are display-only; the render
    /// tint below is what actually reaches the shader.
    var swatch: [Color] {
        switch self {
        case .classic:
            return [Color(white: 0.12), Color(white: 0.38)]
        case .auroraGlass:
            return [Color(red: 0.20, green: 0.55, blue: 0.85), Color(red: 0.35, green: 0.85, blue: 0.65)]
        case .inkWash:
            return [Color(red: 0.30, green: 0.20, blue: 0.10), Color(red: 0.75, green: 0.60, blue: 0.40)]
        case .coolDusk:
            return [Color(red: 0.10, green: 0.10, blue: 0.35), Color(red: 0.30, green: 0.45, blue: 0.80)]
        }
    }

    /// Shadow tone, highlight tone (linear-light 0...1 RGB) and blend
    /// strength (0 disables the tint entirely — `classic`'s value).
    var tone: (shadow: SIMD3<Double>, highlight: SIMD3<Double>, strength: Double) {
        switch self {
        case .classic:
            return (.zero, .zero, 0)
        case .auroraGlass:
            return (SIMD3(0.02, 0.05, 0.10), SIMD3(0.25, 0.65, 0.60), 0.55)
        case .inkWash:
            return (SIMD3(0.08, 0.05, 0.02), SIMD3(0.55, 0.42, 0.28), 0.60)
        case .coolDusk:
            return (SIMD3(0.03, 0.02, 0.10), SIMD3(0.20, 0.24, 0.55), 0.55)
        }
    }
}
