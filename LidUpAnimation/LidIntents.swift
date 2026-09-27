import AppIntents
import SwiftUI
import ThinkingOrbs

/// The fold style, exposed to Siri and Shortcuts.
enum FoldStyleAppEnum: String, AppEnum {
    case classic, auroraGlass, inkWash, coolDusk

    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Fold Style")
    static var caseDisplayRepresentations: [FoldStyleAppEnum: DisplayRepresentation] = [
        .classic: DisplayRepresentation(title: "Classic"),
        .auroraGlass: DisplayRepresentation(title: "Aurora Glass"),
        .inkWash: DisplayRepresentation(title: "Ink Wash"),
        .coolDusk: DisplayRepresentation(title: "Cool Dusk"),
    ]

    var style: FoldStyle {
        switch self {
        case .classic: return .classic
        case .auroraGlass: return .auroraGlass
        case .inkWash: return .inkWash
        case .coolDusk: return .coolDusk
        }
    }
}

/// A tiny status card shown under an intent's spoken reply.
private struct FoldSnippetView: View {
    let orb: OrbState
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 12) {
            ThinkingOrb(orb, size: .small)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12)
    }
}

struct PreviewFoldIntent: AppIntent {
    static var title: LocalizedStringResource = "Preview the Fold"
    static var description = IntentDescription("Plays the lid fold once, without moving the lid.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ShowsSnippetView {
        guard Preferences.shared.isEnabled else {
            return .result(dialog: "The lid fold is turned off. Turn it on first.")
        }
        guard let controller = LidBridge.shared.controller, controller.phase == .idle, !controller.isPreviewing else {
            return .result(dialog: "The fold is already playing.")
        }
        controller.runPreview()
        let style = Preferences.shared.foldStyle
        return .result(
            dialog: "Previewing the fold.",
            view: FoldSnippetView(orb: .shaping, title: "Previewing the fold", subtitle: style.title)
        )
    }
}

struct EnableFoldIntent: AppIntent {
    static var title: LocalizedStringResource = "Turn On the Lid Fold"
    static var description = IntentDescription("Turns the lid fold back on.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        Preferences.shared.isEnabled = true
        return .result(dialog: "The lid fold is on.")
    }
}

struct DisableFoldIntent: AppIntent {
    static var title: LocalizedStringResource = "Turn Off the Lid Fold"
    static var description = IntentDescription("Pauses the lid fold until it's turned back on.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        Preferences.shared.isEnabled = false
        return .result(dialog: "The lid fold is off.")
    }
}

struct SetFoldStyleIntent: AppIntent {
    static var title: LocalizedStringResource = "Set the Fold Style"
    static var description = IntentDescription("Chooses the visual style the fold plays in.")

    @Parameter(title: "Style")
    var style: FoldStyleAppEnum

    static var parameterSummary: some ParameterSummary {
        Summary("Set the fold style to \(\.$style)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ShowsSnippetView {
        let chosen = style.style
        Preferences.shared.foldStyle = chosen
        return .result(
            dialog: "The fold style is now \(chosen.title).",
            view: FoldSnippetView(orb: .composing, title: chosen.title, subtitle: chosen.subtitle)
        )
    }
}

struct LidStatusIntent: AppIntent {
    static var title: LocalizedStringResource = "Check the Lid Fold Status"
    static var description = IntentDescription("Reports the current lid angle and whether the fold is watching, playing or off.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ShowsSnippetView {
        guard let controller = LidBridge.shared.controller, controller.isSensorAvailable else {
            return .result(dialog: "No lid angle sensor was found on this laptop.")
        }
        let angle = Int(controller.currentAngle.rounded())
        let phaseText: String
        let orb: OrbState
        switch controller.phase {
        case .idle:
            phaseText = Preferences.shared.isEnabled ? "watching" : "turned off"
            orb = Preferences.shared.isEnabled ? .listening : .breathing
        case .active:
            phaseText = "folding"
            orb = .working
        case .clearing:
            phaseText = "clearing"
            orb = .working
        }
        return .result(
            dialog: "The lid is at \(angle) degrees, \(phaseText).",
            view: FoldSnippetView(orb: orb, title: "\(angle)°", subtitle: phaseText)
        )
    }
}

struct LidUpShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: PreviewFoldIntent(),
            phrases: [
                "Preview the fold in \(.applicationName)",
                "Show me the lid fold in \(.applicationName)",
            ],
            shortTitle: "Preview the Fold",
            systemImageName: "play.fill"
        )
        AppShortcut(
            intent: EnableFoldIntent(),
            phrases: ["Turn on the lid fold in \(.applicationName)"],
            shortTitle: "Turn On the Fold",
            systemImageName: "laptopcomputer"
        )
        AppShortcut(
            intent: DisableFoldIntent(),
            phrases: ["Turn off the lid fold in \(.applicationName)"],
            shortTitle: "Turn Off the Fold",
            systemImageName: "laptopcomputer.slash"
        )
        AppShortcut(
            intent: SetFoldStyleIntent(),
            phrases: ["Set the fold style to \(\.$style) in \(.applicationName)"],
            shortTitle: "Set the Fold Style",
            systemImageName: "paintpalette"
        )
        AppShortcut(
            intent: LidStatusIntent(),
            phrases: [
                "Check the lid fold status in \(.applicationName)",
                "What's my lid angle in \(.applicationName)",
            ],
            shortTitle: "Check the Lid Angle",
            systemImageName: "gauge.with.dots.needle.50percent"
        )
    }
}

/// Every plain, user-visible piece of text above, duplicated here as flat
/// strings so a unit test can scan for Apple trademarks (Apple, iPhone,
/// iPad, Apple Watch, Mac, Siri, AirPods, …) without needing to reflect
/// into `AppShortcutPhrase`/`Summary`, which aren't plain `String`s.
/// App Store Connect's build processing rejects intent metadata containing
/// them, silently (ITMS-90626) — keep this list matching the literals above
/// whenever either changes.
enum IntentTextAudit {
    static let strings: [String] = [
        "Preview the Fold", "Plays the lid fold once, without moving the lid.",
        "The lid fold is turned off. Turn it on first.", "The fold is already playing.",
        "Previewing the fold.", "Previewing the fold",
        "Turn On the Lid Fold", "Turns the lid fold back on.", "The lid fold is on.",
        "Turn Off the Lid Fold", "Pauses the lid fold until it's turned back on.", "The lid fold is off.",
        "Set the Fold Style", "Chooses the visual style the fold plays in.", "Style",
        "Set the fold style to ",
        "Check the Lid Fold Status",
        "Reports the current lid angle and whether the fold is watching, playing or off.",
        "No lid angle sensor was found on this laptop.",
        "The lid is at ", " degrees, ", "watching", "turned off", "folding", "clearing",
        "Preview the fold in ", "Show me the lid fold in ",
        "Turn on the lid fold in ", "Turn off the lid fold in ",
        "Check the lid fold status in ", "What's my lid angle in ",
        "Preview the Fold", "Turn On the Fold", "Turn Off the Fold", "Set the Fold Style", "Check the Lid Angle",
        "Classic", "Aurora Glass", "Ink Wash", "Cool Dusk", "Fold Style",
    ] + FoldStyle.allCases.flatMap { [$0.title, $0.subtitle] }
}
