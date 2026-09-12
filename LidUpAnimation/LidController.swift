import AppKit
import Combine
import os
import QuartzCore

let lidLog = Logger(subsystem: "com.hemalmodi.LidUpAnimation", category: "lid")

/// Watches the lid and drives the fold.
///
/// The sensor is polled on its own queue and reports about ten times a second.
/// A critically damped spring, stepped by a display link, turns those steps
/// into a smooth angle for the renderer.
///
/// Life of one run:
/// 1. The lid rests. The resting angle is remembered.
/// 2. It starts to close. The screen stream is warmed up at the first sign of
///    movement, and once the lid is `startDelta` degrees below rest the
///    overlay goes up with the picture anchored at the resting angle.
/// 3. While the lid keeps moving, the picture tilts, blurs and dims. If it
///    reaches the sleep angle, macOS sleeps and the overlay goes with it.
/// 4. If the lid opens back up, the picture follows it back to flat and the
///    overlay fades away. If the lid holds still, the picture eases back to
///    flat after `stillDelay` and the new angle becomes the resting angle.
@MainActor
final class LidController: ObservableObject {

    enum Phase: String { case idle, active, clearing }

    @Published private(set) var currentAngle: Double = 0
    @Published private(set) var isSensorAvailable = false
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var isPreviewing = false
    @Published private(set) var statusMessage = ""

    /// How many views currently show the live angle. Publishing it re-lays
    /// out the menu bar, so it only happens while something is looking.
    var angleObservers = 0

    private let preferences: Preferences
    private let sensor = LidAngleSensor()
    private let overlay = FoldOverlay()
    private let streamer = ScreenStreamer()

    private var subscriptions = Set<AnyCancellable>()
    private var displayLink: CADisplayLink?
    private var lastFrameTime: CFTimeInterval = 0
    private var lastPublishTime: CFTimeInterval = 0

    // Sensor tracking.
    private var rawAngle: Double = 0
    private var rawTime: CFTimeInterval = 0
    private var lastChangedAngle: Double?
    private var lastChangeTime: CFTimeInterval = 0
    /// Degrees per second, negative while closing.
    private var velocity: Double = 0
    private var failedReads = 0

    // Stillness.
    private var stillAnchor: Double?
    private var stillAnchorTime: CFTimeInterval = 0
    private var isStill = false
    private var restingAngle: Double?

    // Effect.
    private var referenceAngle: Double = 110
    private var visual = CriticallyDampedSpring()
    private var startedAt: CFTimeInterval = 0
    private var clearingStartedAt: CFTimeInterval = 0
    private var isSuspended = false
    private var preview: PreviewRun?
    /// A still picture for a preview that runs without Screen Recording.
    private var previewSeed: CGImage?

    private static let idleRate: Double = 10
    private static let activeRate: Double = 60
    private static let stillTolerance: Double = 1.0
    private static let stillTime: TimeInterval = 0.7
    private static let streamIdleStop: TimeInterval = 4
    private static let minimumRun: TimeInterval = 0.3
    private static let clearingMaxDuration: TimeInterval = 1.2
    private static let maxReferenceAngle: Double = 140
    /// Sensor noise at rest is about 0.1 degrees; smaller changes are ignored.
    private static let jitterBand: Double = 0.2

    /// A scripted sweep that feeds the same path the sensor feeds.
    private struct PreviewRun {
        let startedAt: CFTimeInterval
        let open: Double
        let shut: Double
        let closing: CFTimeInterval = 1.8
        let hold: CFTimeInterval = 0.5
        let opening: CFTimeInterval = 1.0

        func angle(at now: CFTimeInterval) -> Double? {
            let t = now - startedAt
            if t < 0.6 { return open }
            let e = t - 0.6
            if e < closing {
                let u = e / closing
                return open + (shut - open) * (u * u * (3 - 2 * u))
            }
            if e < closing + hold { return shut }
            if e < closing + hold + opening {
                let u = (e - closing - hold) / opening
                return shut + (open - shut) * (u * u * (3 - 2 * u))
            }
            return nil
        }
    }

    init(preferences: Preferences) {
        self.preferences = preferences
        preferences.$isEnabled
            .removeDuplicates()
            .sink { [weak self] enabled in
                if !enabled { self?.endImmediately() }
            }
            .store(in: &subscriptions)
    }

    // MARK: - Lifecycle

    func start() {
        isSensorAvailable = sensor.isAvailable
        guard isSensorAvailable else {
            statusMessage = "No lid angle sensor on this Mac."
            return
        }
        if let angle = sensor.readAngle() {
            rawAngle = angle
            rawTime = CACurrentMediaTime()
            currentAngle = angle
            visual.reset(to: angle)
        }
        sensor.onReading = { [weak self] angle, time in
            self?.receive(angle: angle, at: time)
        }
        sensor.setPollingRate(Self.idleRate)
        observeSystemEvents()
    }

    func stop() {
        sensor.stop()
        endImmediately()
    }

    /// Plays the effect once without moving the lid.
    /// Without Screen Recording it plays over the desktop wallpaper instead
    /// of the live screen.
    func runPreview() {
        guard preferences.isEnabled, !isSuspended, preview == nil, phase == .idle else { return }
        if ScreenRecordingPermission.isGranted {
            previewSeed = nil
        } else {
            guard let screen = NSScreen.builtIn, let image = Self.wallpaper(for: screen) else {
                statusMessage = "Screen Recording permission is needed for the preview."
                return
            }
            previewSeed = image
        }
        let open = min(max(rawAngle, preferences.darkAngle + 30), preferences.anchorAngle + 8)
        preview = PreviewRun(startedAt: CACurrentMediaTime(), open: open, shut: max(preferences.darkAngle - 8, 5))
        isPreviewing = true
        streamer.start()
        sensor.setPollingRate(Self.activeRate)
    }

    private static func wallpaper(for screen: NSScreen) -> CGImage? {
        guard let url = NSWorkspace.shared.desktopImageURL(for: screen),
              let image = NSImage(contentsOf: url) else { return nil }
        // Scale to fill the screen the way the desktop does.
        let size = screen.frame.size
        let scale = screen.backingScaleFactor
        let pixels = CGSize(width: size.width * scale, height: size.height * scale)
        let canvas = NSImage(size: pixels)
        canvas.lockFocus()
        let source = image.size
        let fill = max(pixels.width / source.width, pixels.height / source.height)
        let drawn = CGSize(width: source.width * fill, height: source.height * fill)
        image.draw(in: NSRect(x: (pixels.width - drawn.width) / 2, y: (pixels.height - drawn.height) / 2,
                              width: drawn.width, height: drawn.height))
        canvas.unlockFocus()
        return canvas.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    // MARK: - Sensor

    private func receive(angle: Double?, at time: CFTimeInterval) {
        guard !isSuspended else { return }
        var angle = angle
        if let run = preview {
            if let scripted = run.angle(at: time) {
                angle = scripted
            } else {
                preview = nil
                previewSeed = nil
                isPreviewing = false
                angle = sensor.readAngle()
                restingAngle = nil
                stillAnchor = nil
            }
        }
        guard let angle else {
            failedReads += 1
            if failedReads > 30, phase != .idle { endImmediately() }
            return
        }
        failedReads = 0

        // Velocity from changed readings only; the sensor repeats the same
        // value between refreshes.
        if let last = lastChangedAngle {
            if abs(angle - last) >= Self.jitterBand {
                let dt = time - lastChangeTime
                if dt > 0.001 {
                    velocity = 0.6 * ((angle - last) / dt) + 0.4 * velocity
                }
                lastChangedAngle = angle
                lastChangeTime = time
            } else if time - lastChangeTime > 0.35 {
                velocity = 0
            }
        } else {
            lastChangedAngle = angle
            lastChangeTime = time
        }
        rawAngle = angle
        rawTime = time
        publish(angle: angle)
        updateStillness(angle: angle, at: time)
        reconcile(at: time)
    }

    private func updateStillness(angle: Double, at time: CFTimeInterval) {
        if let anchor = stillAnchor, abs(angle - anchor) < Self.stillTolerance {
            if !isStill, time - stillAnchorTime >= Self.stillTime {
                isStill = true
            }
        } else {
            stillAnchor = angle
            stillAnchorTime = time
            isStill = false
        }
        if isStill, phase == .idle, preview == nil || restingAngle == nil {
            restingAngle = stillAnchor
        }
    }

    private func publish(angle: Double) {
        guard angleObservers > 0 || preferences.showsAngleInMenuBar else { return }
        let now = CACurrentMediaTime()
        guard now - lastPublishTime > 0.2 else { return }
        lastPublishTime = now
        // Whole degrees for the menu bar, tenths for the open panel.
        let rounded = angleObservers > 0 ? (angle * 10).rounded() / 10 : angle.rounded()
        if currentAngle != rounded { currentAngle = rounded }
    }

    // MARK: - Decisions

    private func reconcile(at now: CFTimeInterval) {
        guard preferences.isEnabled, isSensorAvailable else {
            sensor.setPollingRate(Self.idleRate)
            return
        }
        switch phase {
        case .idle:
            reconcileIdle(at: now)
        case .active:
            reconcileActive(at: now)
        case .clearing:
            break
        }
    }

    private func reconcileIdle(at now: CFTimeInterval) {
        let resting: Double
        if let restingAngle {
            resting = restingAngle
        } else if let run = preview {
            resting = run.open
        } else {
            sensor.setPollingRate(Self.idleRate)
            return
        }

        let closingFromRest = rawAngle < resting - 0.4 && velocity < -0.5
        let movingFast = velocity < -4
        let moving = closingFromRest || movingFast || preview != nil

        // Warm the stream at the first sign of closing, so frames are ready
        // by the time the effect starts.
        if moving, NSScreen.builtIn != nil {
            if !streamer.isStarted, ScreenRecordingPermission.isGranted {
                lidLog.notice("warm: angle \(self.rawAngle, format: .fixed(precision: 2)) resting \(resting, format: .fixed(precision: 2)) velocity \(self.velocity, format: .fixed(precision: 1))")
            }
            streamer.start()
            sensor.setPollingRate(Self.activeRate)
        } else if isStill, now - stillAnchorTime > Self.streamIdleStop, preview == nil {
            if streamer.isStarted { lidLog.notice("cool: lid still at \(self.rawAngle, format: .fixed(precision: 2))") }
            streamer.stop()
            sensor.setPollingRate(Self.idleRate)
        }

        // Anchored where the lid rests, unless it rests above the anchor
        // angle; then the effect waits for the lid to close past that angle.
        let anchor = min(max(preferences.anchorAngle, preferences.darkAngle + 15), Self.maxReferenceAngle)
        let reference = min(resting, anchor)
        guard reference > preferences.darkAngle + 10 else { return }
        let threshold = resting > anchor ? anchor : reference - preferences.startDelta
        let predicted = predictedAngle(at: now)
        guard predicted <= threshold, velocity < 0 || preview != nil else { return }
        guard let screen = NSScreen.builtIn, ScreenRecordingPermission.isGranted || previewSeed != nil else { return }
        begin(reference: reference, on: screen, at: now)
    }

    private func reconcileActive(at now: CFTimeInterval) {
        guard now - startedAt > Self.minimumRun else { return }
        // Opened back past the anchor: the picture is flat again.
        if rawAngle >= referenceAngle - 0.3 {
            beginClearing(at: now)
            return
        }
        if preferences.clearsWhenStill, preview == nil, isStill,
           now - stillAnchorTime >= preferences.stillDelay {
            restingAngle = stillAnchor
            beginClearing(at: now)
        }
    }

    /// The last reading can be a full sensor refresh old. A fast close is
    /// followed from where the lid is heading.
    private func predictedAngle(at now: CFTimeInterval) -> Double {
        guard velocity < -20 else { return rawAngle }
        let age = min(now - lastChangeTime, 0.1)
        return max(rawAngle + velocity * (age + 0.03), 0)
    }

    // MARK: - Effect

    private func begin(reference: Double, on screen: NSScreen, at now: CFTimeInterval) {
        referenceAngle = reference
        startedAt = now
        visual.reset(to: reference)
        guard overlay.show(on: screen) else { return }
        lidLog.notice("begin: reference \(reference, format: .fixed(precision: 2)) angle \(self.rawAngle, format: .fixed(precision: 2)) velocity \(self.velocity, format: .fixed(precision: 1)) stream \(self.streamer.isStarted) frames \(self.streamer.hasFrames)")
        phase = .active
        if let previewSeed {
            overlay.renderer?.absorb(image: previewSeed)
        } else {
            streamer.start()
        }
        sensor.setPollingRate(Self.activeRate)
        startDisplayLink()
    }

    private func beginClearing(at now: CFTimeInterval) {
        guard phase == .active else { return }
        guard overlay.isVisible, displayLink != nil else {
            finish()
            return
        }
        lidLog.notice("clearing: angle \(self.rawAngle, format: .fixed(precision: 2)) after \(now - self.startedAt, format: .fixed(precision: 2)) s")
        phase = .clearing
        clearingStartedAt = now
    }

    private func finish() {
        lidLog.notice("finish: angle \(self.rawAngle, format: .fixed(precision: 2))")
        stopDisplayLink()
        overlay.dismiss(animated: true)
        phase = .idle
        if preview == nil {
            stillAnchor = rawAngle
            stillAnchorTime = CACurrentMediaTime()
            isStill = false
            restingAngle = rawAngle
        }
    }

    private func endImmediately() {
        stopDisplayLink()
        overlay.dismiss(animated: false)
        streamer.stop()
        preview = nil
        previewSeed = nil
        isPreviewing = false
        phase = .idle
        restingAngle = nil
        stillAnchor = nil
        isStill = false
        velocity = 0
        lastChangedAngle = nil
        if isSensorAvailable { sensor.setPollingRate(Self.idleRate) }
    }

    // MARK: - Animation

    private func startDisplayLink() {
        stopDisplayLink()
        guard let window = overlay.hostWindow else { return }
        let link = window.displayLink(target: self, selector: #selector(step(_:)))
        link.add(to: .main, forMode: .common)
        lastFrameTime = CACurrentMediaTime()
        displayLink = link
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func step(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        let dt = min(max(now - lastFrameTime, 1.0 / 240), 1.0 / 20)
        lastFrameTime = now

        if previewSeed == nil, let frame = streamer.newFrame() {
            overlay.renderer?.absorb(frame)
        }

        let target = phase == .clearing ? referenceAngle : min(predictedAngle(at: now), referenceAngle)
        visual.advance(to: target, dt: dt)

        if phase == .clearing {
            let settled = visual.value >= referenceAngle - 0.05
            let timedOut = now - clearingStartedAt > Self.clearingMaxDuration
            if settled || timedOut {
                // The last frame must match the screen behind it exactly.
                visual.reset(to: referenceAngle)
                overlay.draw(parameters(for: referenceAngle))
                finish()
                return
            }
        }
        overlay.draw(parameters(for: visual.value))
    }

    private func parameters(for angle: Double) -> FoldParameters {
        let span = max(referenceAngle - preferences.darkAngle, 10)
        let progress = min(max((referenceAngle - angle) / span, 0), 1)
        return FoldParameters(
            referenceAngle: referenceAngle,
            currentAngle: angle,
            progress: progress,
            viewingDistance: preferences.viewingDistance,
            maxBlurRadius: preferences.maxBlurRadius,
            maxDim: preferences.maxDim
        )
    }

    // MARK: - System events

    private func observeSystemEvents() {
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification,
                     NSWorkspace.sessionDidResignActiveNotification] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.isSuspended = true
                    self?.endImmediately()
                }
            }
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification,
                     NSWorkspace.sessionDidBecomeActiveNotification] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.isSuspended = false }
            }
        }
        let distributed = DistributedNotificationCenter.default()
        distributed.addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isSuspended = true
                self?.endImmediately()
            }
        }
        distributed.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.isSuspended = false }
        }
        distributed.addObserver(forName: Notification.Name("com.hemalmodi.LidUpAnimation.preview"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.runPreview() }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.phase != .idle else { return }
                self.endImmediately()
            }
        }
    }
}

/// Turns the sensor's ten-per-second steps into a value that changes smoothly
/// at the display refresh rate. Semi-implicit Euler; the caller clamps `dt`.
struct CriticallyDampedSpring {
    var value: Double = 0
    var velocity: Double = 0
    /// Radians per second. Higher follows the target faster and smooths less.
    var frequency: Double = 18

    mutating func advance(to target: Double, dt: Double) {
        let acceleration = frequency * frequency * (target - value) - 2 * frequency * velocity
        velocity += acceleration * dt
        value += velocity * dt
    }

    mutating func reset(to newValue: Double) {
        value = newValue
        velocity = 0
    }
}
