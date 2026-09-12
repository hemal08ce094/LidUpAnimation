import AppKit
import QuartzCore

/// A borderless window above everything, including the menu bar and full
/// screen spaces. Never takes focus, never takes clicks.
final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class MetalHostView: NSView {
    init(layer metalLayer: CALayer, scale: CGFloat) {
        super.init(frame: .zero)
        metalLayer.contentsScale = scale
        self.layer = metalLayer
        wantsLayer = true
        layerContentsRedrawPolicy = .never
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        layer?.frame = bounds
    }
}

/// Owns the full-screen overlay window for one run of the effect.
@MainActor
final class FoldOverlay {

    let renderer: FoldRenderer?

    private var window: OverlayWindow?
    private var fadingWindow: OverlayWindow?
    private var presenceWindow: OverlayWindow?
    private var hasRevealed = false
    private(set) var screenSize: CGSize = .zero

    var isVisible: Bool { window != nil }
    var hostWindow: NSWindow? { window }

    init() {
        renderer = FoldRenderer()
        keepPresence()
    }

    /// ScreenCaptureKit only lists an application that owns a window, and the
    /// stream has to name this app to leave the overlay out of its own
    /// picture. This one-point window makes sure we are always listed.
    private func keepPresence() {
        guard presenceWindow == nil else { return }
        let window = OverlayWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
            styleMask: .borderless, backing: .buffered, defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.level = .normal
        window.alphaValue = 0.004
        window.sharingType = .none
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.orderFrontRegardless()
        presenceWindow = window
    }

    /// Puts up a transparent window on the built-in screen. It stays
    /// invisible until the first frame has been absorbed and drawn.
    @discardableResult
    func show(on screen: NSScreen) -> Bool {
        dismiss(animated: false)
        guard let renderer else { return false }
        screenSize = screen.frame.size
        let scale = screen.backingScaleFactor
        guard renderer.begin(screenSize: screenSize, pixelScale: scale) else { return false }

        let view = MetalHostView(layer: renderer.makeLayer(), scale: scale)
        view.frame = NSRect(origin: .zero, size: screenSize)
        view.autoresizingMask = [.width, .height]

        let window = OverlayWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = view
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        // Hidden from screen sharing and screenshots, unless a debug run
        // needs to capture the effect itself.
        window.sharingType = CommandLine.arguments.contains("--capturable") ? .readOnly : .none
        window.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        window.setFrame(screen.frame, display: false)
        window.alphaValue = 0
        window.orderFrontRegardless()
        hasRevealed = false
        self.window = window
        return true
    }

    /// Draws one frame and fades the window in the first time there is a
    /// picture to show.
    func draw(_ parameters: FoldParameters, fadeIn: TimeInterval = 0.06) {
        guard let renderer, window != nil else { return }
        renderer.draw(parameters)
        guard renderer.hasPicture, !hasRevealed, let window else { return }
        hasRevealed = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = fadeIn
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = 1
        }
    }

    func dismiss(animated: Bool, duration: TimeInterval = 0.2) {
        if let fadingWindow {
            self.fadingWindow = nil
            fadingWindow.orderOut(nil)
            fadingWindow.close()
        }
        guard let window else { return }
        self.window = nil
        renderer?.release()

        guard animated, hasRevealed else {
            window.orderOut(nil)
            window.close()
            return
        }
        fadingWindow = window
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                if let self, self.fadingWindow === window { self.fadingWindow = nil }
                window.orderOut(nil)
                window.close()
            }
        }
    }
}
