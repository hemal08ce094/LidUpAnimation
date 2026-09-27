import Drawably
import SwiftUI
import Symbols
import ThinkingOrbs
import TipKit

/// A one-time nudge towards the new style picker.
struct FoldStyleTip: Tip {
    var title: Text { Text("Try a fold style") }
    var message: Text? { Text("Pick a mood for the fold — aurora, ink or dusk — and preview it right here.") }
    var image: Image? { Image(systemName: "paintpalette") }
}

/// The style picker: four sketched cards, one per fold mood, with a live
/// full-screen preview a tap away.
struct StyleGalleryView: View {
    @ObservedObject var preferences: Preferences
    @ObservedObject var controller: LidController
    var dismiss: () -> Void

    private let paper = Color(nsColor: .windowBackgroundColor)

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                ThinkingOrb(.composing, size: .small)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Fold styles").font(.title3.bold())
                    Text("Pick a mood. Preview plays it right away.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done", action: dismiss)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(10)
            .adaptiveGlass(cornerRadius: 12)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                ForEach(FoldStyle.allCases) { style in
                    styleCard(style)
                }
            }

            Button {
                controller.runPreview()
            } label: {
                Label("Preview this style", systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!preferences.isEnabled || controller.isPreviewing || controller.phase != .idle)
            .accessibilityHint(Text("Plays the fold once, without moving the lid."))
        }
        .padding(18)
        .frame(width: 420)
        .drawably(stroke: .accentColor, fill: .accentColor, paper: paper)
    }

    private func styleCard(_ style: FoldStyle) -> some View {
        let isSelected = preferences.foldStyle == style
        return Button {
            withAnimation(.easeInOut(duration: 0.2)) { preferences.foldStyle = style }
        } label: {
            DrawablyCard {
                VStack(alignment: .leading, spacing: 8) {
                    LinearGradient(colors: style.swatch, startPoint: .topLeading, endPoint: .bottomTrailing)
                        .frame(height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            Image(systemName: style.symbolName)
                                .foregroundStyle(.white)
                                .font(.title3)
                                .shadow(radius: 2)
                        )
                    Text(style.title).font(.subheadline.bold()).foregroundStyle(.primary)
                    Text(style.subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(2)
            }
        }
        .buttonStyle(.plain)
        // The selection mark stays a plain, native symbol — legible in both
        // themes and both states, unlike a sketched checkbox would be.
        .overlay(alignment: .topTrailing) {
            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, Color.accentColor)
                    .font(.title3)
                    .padding(6)
                    .symbolEffect(.bounce, value: isSelected)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(style.title). \(style.subtitle)"))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : [.isButton])
    }
}
