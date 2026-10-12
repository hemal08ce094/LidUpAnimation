#if DEBUG
import AppKit
import Combine
import Metal
import SwiftUI
import ThinkingOrbs

/// DEBUG-only harness for App Store media. Never compiled into Release.
///
///     LidUpAnimation --store-stage <scene> <wallpaper> <WxH> [seconds] [light]
///     LidUpAnimation --store-stage sweep <outdir> <source> <WxH> <style> <angles|video>
///
/// A stage is one borderless window, sized in points, showing the real app
/// views (menu panel, style gallery, welcome window, intent snippets) over a
/// wallpaper, so a window-rect capture gets the actual UI. With `seconds`,
/// the scene plays a short script driving the real preferences (restored
/// on exit) and then quits. `sweep` renders the real Metal fold offscreen
/// either at listed angles (`112,70,40`) or as a 30 fps close-and-open run.
@MainActor
enum StoreStage {
    private static var window: NSWindow?
    private static var timer: Timer?

    static func run(arguments: [String], delegate: AppDelegate) {
        func arg(_ i: Int) -> String? { arguments.indices.contains(i) ? arguments[i] : nil }
        let scene = arg(0) ?? "menu"
        if scene == "sweep" {
            exit(sweep(out: arg(1) ?? "sweep", source: arg(2) ?? "", size: parseSize(arg(3)) ?? CGSize(width: 1440, height: 900),
                       style: FoldStyle(rawValue: arg(4) ?? "") ?? .classic, mode: arg(5) ?? "video"))
        }
        let wallpaper = arg(1).flatMap { NSImage(contentsOfFile: $0) } ?? NSImage()
        let size = parseSize(arg(2)) ?? CGSize(width: 1440, height: 900)
        let seconds = arg(3).flatMap(Double.init) ?? 0
        let light = arg(4) == "light"

        let preferences = delegate.preferences
        let controller = delegate.controller
        controller.start()
        LidBridge.shared.controller = controller
        let snapshot = Snapshot(preferences)

        let model = StageModel()
        let root = StageView(scene: scene, wallpaper: wallpaper, model: model,
                             controller: controller, preferences: preferences)
            .frame(width: size.width, height: size.height)
            .environment(\.colorScheme, light ? .light : .dark)

        let screen = NSScreen.main?.frame ?? .zero
        let rect = NSRect(x: 36, y: screen.height - 60 - size.height, width: size.width, height: size.height)
        let window = StageWindow(contentRect: rect, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: light ? .aqua : .darkAqua)
        window.level = .statusBar
        window.isOpaque = true
        window.hasShadow = false
        window.contentView = NSHostingView(rootView: root)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        self.window = window
        // The capture script reads this line: window number and top-left rect in points.
        print("STAGE \(window.windowNumber) \(Int(rect.minX)),\(Int(screen.height - rect.maxY)),\(Int(size.width)),\(Int(size.height))")
        fflush(stdout)

        let start = Date()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { _ in
            MainActor.assumeIsolated {
                let t = Date().timeIntervalSince(start)
                script(scene: scene, t: t, preferences: preferences, model: model)
                let limit = seconds > 0 ? seconds + 1.5 : 25
                if t > limit {
                    snapshot.restore(preferences)
                    exit(0)
                }
            }
        }
    }

    /// Scene scripts. Times are seconds from the window appearing; the
    /// recorder starts about half a second in.
    private static func script(scene: String, t: Double, preferences: Preferences, model: StageModel) {
        switch scene {
        case "gallery":
            let order: [FoldStyle] = [.classic, .auroraGlass, .inkWash, .coolDusk]
            let index = t < 1.2 ? 0 : (Int((t - 1.2) / 1.6) + 1) % order.count
            if preferences.foldStyle != order[index] {
                withAnimation(.easeInOut(duration: 0.2)) { preferences.foldStyle = order[index] }
            }
        case "tuning":
            // Keeps the expanded panel inside a laptop-height stage.
            if preferences.clearsWhenStill { preferences.clearsWhenStill = false }
            // Glide a few sliders so the panel reads as live.
            let phase = max(t - 1.0, 0)
            preferences.maxBlurRadius = ((90 + 50 * sin(phase * 1.1)) / 5).rounded() * 5
            preferences.darkAngle = (25 + 12 * sin(phase * 0.8)).rounded()
            preferences.viewingDistance = ((2.5 + 1.2 * sin(phase * 0.6)) * 10).rounded() / 10
        case "menu":
            preferences.showsAngleInMenuBar = true
            let off = t > 4.0 && t < 6.5
            if preferences.isEnabled == off { preferences.isEnabled = !off }
        case "voice":
            // The window recorder needs ~2.5 s to attach; start the reveal after it.
            let shown = min(Int(max(t - 2.8, 0) / 1.8) + 1, 3)
            if model.cards != shown { withAnimation(.spring(duration: 0.45)) { model.cards = shown } }
        default:
            break
        }
    }

    private static func parseSize(_ s: String?) -> CGSize? {
        guard let parts = s?.split(separator: "x").compactMap({ Double($0) }), parts.count == 2 else { return nil }
        return CGSize(width: parts[0], height: parts[1])
    }

    // MARK: - Offscreen fold sweep

    private static func sweep(out: String, source: String, size: CGSize, style: FoldStyle, mode: String) -> Int32 {
        let scale: CGFloat = 2
        guard let renderer = FoldRenderer(), renderer.begin(screenSize: size, pixelScale: scale),
              let image = NSImage(contentsOfFile: source) else { return 1 }
        let width = Int(size.width * scale), height = Int(size.height * scale)
        let canvas = NSImage(size: NSSize(width: width, height: height))
        canvas.lockFocus()
        let fill = max(CGFloat(width) / image.size.width, CGFloat(height) / image.size.height)
        let drawn = NSSize(width: image.size.width * fill, height: image.size.height * fill)
        image.draw(in: NSRect(x: (CGFloat(width) - drawn.width) / 2, y: (CGFloat(height) - drawn.height) / 2,
                              width: drawn.width, height: drawn.height))
        canvas.unlockFocus()
        guard let artwork = canvas.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return 1 }
        renderer.absorb(image: artwork)

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        guard let target = renderer.device.makeTexture(descriptor: descriptor) else { return 1 }
        let directory = URL(fileURLWithPath: out)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let reference = 112.0, dark = 25.0
        var frames: [(String, Double)] = []
        if mode == "video" {
            // Lingers in the readable upper range, dips to dark, then reopens.
            let fps = 30.0
            let segments: [(Double, Double, Double)] = [(reference, reference, 0.5), (reference, 50, 3.2), (50, 18, 0.9), (18, 18, 0.4), (18, reference, 2.6), (reference, reference, 0.5)]
            var n = 0
            for (from, to, duration) in segments {
                let count = Int(duration * fps)
                for i in 0..<count {
                    let x = Double(i) / Double(count)
                    let eased = x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2
                    frames.append((String(format: "f%04d.png", n), from + (to - from) * eased))
                    n += 1
                }
            }
        } else {
            frames = mode.split(separator: ",").compactMap(Double.init).map { (String(format: "a%03d.png", Int($0)), $0) }
        }
        let tone = style.tone
        for (name, angle) in frames {
            let progress = min(max((reference - angle) / (reference - dark), 0), 1)
            renderer.render(FoldParameters(referenceAngle: reference, currentAngle: angle, progress: progress,
                                           viewingDistance: 2.5, maxBlurRadius: 90, maxDim: 1,
                                           toneShadow: tone.shadow, toneHighlight: tone.highlight, toneStrength: tone.strength),
                            into: target)
            var bytes = [UInt8](repeating: 0, count: width * height * 4)
            target.getBytes(&bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
            guard let provider = CGDataProvider(data: Data(bytes) as CFData),
                  let cg = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                   space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                                   provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
                  let data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else { return 1 }
            try? data.write(to: directory.appendingPathComponent(name))
        }
        print("wrote \(frames.count) frame(s) to \(out)")
        return 0
    }

    @MainActor private struct Snapshot {
        let values: [String: Any]
        init(_ p: Preferences) {
            values = ["isEnabled": p.isEnabled, "foldStyleID": p.foldStyleID, "showsAngleInMenuBar": p.showsAngleInMenuBar,
                      "maxBlurRadius": p.maxBlurRadius, "darkAngle": p.darkAngle, "viewingDistance": p.viewingDistance,
                      "clearsWhenStill": p.clearsWhenStill]
        }
        func restore(_ p: Preferences) {
            p.isEnabled = values["isEnabled"] as! Bool
            p.foldStyleID = values["foldStyleID"] as! String
            p.showsAngleInMenuBar = values["showsAngleInMenuBar"] as! Bool
            p.maxBlurRadius = values["maxBlurRadius"] as! Double
            p.darkAngle = values["darkAngle"] as! Double
            p.viewingDistance = values["viewingDistance"] as! Double
            p.clearsWhenStill = values["clearsWhenStill"] as! Bool
        }
    }
}

/// Borderless, but key, so prominent buttons and focus render as they do in use.
private final class StageWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class StageModel: ObservableObject {
    @Published var cards = 1
}

private struct PanelChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .withinWindow
        view.state = .active
        return view
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

private extension View {
    func panel(_ radius: CGFloat = 14) -> some View {
        background(PanelChrome().clipShape(RoundedRectangle(cornerRadius: radius)))
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(.white.opacity(0.14), lineWidth: 1))
            .shadow(color: .black.opacity(0.45), radius: 30, y: 14)
    }
}

private struct StageView: View {
    let scene: String
    let wallpaper: NSImage
    @ObservedObject var model: StageModel
    @ObservedObject var controller: LidController
    @ObservedObject var preferences: Preferences

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.clear
            // Menu bar strip with the app's real status item label.
            HStack {
                Spacer()
                MenuBarLabel(controller: controller, preferences: preferences)
                    .font(.system(size: 14, weight: .medium))
                    .padding(.horizontal, 10).padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 6).fill(.white.opacity(scene == "menu" || scene == "tuning" ? 0.22 : 0)))
                    .padding(.trailing, 180)
            }
            .frame(height: 30)
            .foregroundStyle(.white)
            .background(.black.opacity(0.28))
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .background {
            Image(nsImage: wallpaper).resizable().aspectRatio(contentMode: .fill)
        }
        .clipped()
    }

    @ViewBuilder private var content: some View {
        switch scene {
        case "menu", "tuning":
            MenuPanelView(controller: controller, preferences: preferences, showsTuningInitially: scene == "tuning")
                .panel(12)
                .padding(.top, 38).padding(.trailing, 110)
        case "gallery":
            StyleGalleryView(preferences: preferences, controller: controller) {}
                .panel(16)
                .padding(.top, 90).padding(.trailing, 110)
        case "onboarding":
            OnboardingView(preferences: preferences, controller: controller) {}
                .fixedSize(horizontal: false, vertical: true)
                .panel(16)
                .padding(.top, 90).padding(.trailing, 110)
        case "voice":
            VStack(alignment: .trailing, spacing: 18) {
                if model.cards >= 1 {
                    voiceCard("Preview the fold in Lid Up", "Previewing the fold.",
                              FoldSnippetView(orb: .working, title: "Previewing the fold", subtitle: preferences.foldStyle.title))
                }
                if model.cards >= 2 {
                    voiceCard("Set the fold style to Ink Wash in Lid Up", "The fold style is now Ink Wash.",
                              FoldSnippetView(orb: .composing, title: FoldStyle.inkWash.title, subtitle: FoldStyle.inkWash.subtitle))
                }
                if model.cards >= 3 {
                    let angle = Int(controller.currentAngle.rounded())
                    voiceCard("What's my lid angle in Lid Up", "The lid is at \(angle) degrees, watching.",
                              FoldSnippetView(orb: .listening, title: "\(angle)°", subtitle: "watching"))
                }
            }
            .frame(width: 440)
            .padding(.top, 90).padding(.trailing, 110)
        default:
            EmptyView()
        }
    }

    private func voiceCard(_ phrase: String, _ reply: String, _ snippet: FoldSnippetView) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("\u{201C}\(phrase)\u{201D}", systemImage: "waveform")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(reply).font(.title3.weight(.semibold))
            snippet
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12).fill(.primary.opacity(0.06)))
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel(18)
        .transition(.move(edge: .trailing).combined(with: .opacity))
    }
}
#endif
