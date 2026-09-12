import AppKit
import CoreVideo
import Metal
import os
import ScreenCaptureKit

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    /// The built-in display, or `nil` in clamshell mode.
    static var builtIn: NSScreen? {
        screens.first { screen in
            guard let id = screen.displayID else { return false }
            return CGDisplayIsBuiltin(id) != 0
        }
    }
}

/// One captured frame. The Metal texture wraps the IOSurface directly, so the
/// `CVMetalTexture` has to stay alive as long as the texture is read.
final class CapturedFrame {
    let texture: MTLTexture
    private let backing: CVMetalTexture

    init?(_ backing: CVMetalTexture) {
        guard let texture = CVMetalTextureGetTexture(backing) else { return nil }
        self.backing = backing
        self.texture = texture
    }
}

/// Streams the built-in display through ScreenCaptureKit.
///
/// Frames land on the stream's queue and the newest is kept under a lock for
/// the main thread to pick up. Starting a stream takes a few hundred
/// milliseconds, so it is started as soon as the lid begins to move.
@MainActor
final class ScreenStreamer {

    /// Display P3 shares sRGB's transfer curve, so an sRGB texture format
    /// decodes it correctly and the layer only needs the matching tag.
    nonisolated static let colourSpaceName = CGColorSpace.displayP3

    private final class Receiver: NSObject, SCStreamOutput {
        private let cache: CVMetalTextureCache
        private let lock = NSLock()
        private var newest: CapturedFrame?
        private var newestID: UInt64 = 0

        init?(device: MTLDevice) {
            var made: CVMetalTextureCache?
            guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &made) == kCVReturnSuccess,
                  let made else { return nil }
            cache = made
            super.init()
        }

        func latest() -> (frame: CapturedFrame, id: UInt64)? {
            lock.lock()
            defer { lock.unlock() }
            guard let newest else { return nil }
            return (newest, newestID)
        }

        func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
            guard type == .screen,
                  CMSampleBufferIsValid(sampleBuffer),
                  let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            CVMetalTextureCacheFlush(cache, 0)
            var wrapped: CVMetalTexture?
            let result = CVMetalTextureCacheCreateTextureFromImage(
                kCFAllocatorDefault, cache, pixels, nil, .bgra8Unorm_srgb,
                CVPixelBufferGetWidth(pixels), CVPixelBufferGetHeight(pixels), 0, &wrapped
            )
            guard result == kCVReturnSuccess, let wrapped, let frame = CapturedFrame(wrapped) else { return }
            lock.lock()
            newest = frame
            newestID &+= 1
            lock.unlock()
        }
    }

    private let device: MTLDevice?
    private var stream: SCStream?
    private var receiver: Receiver?
    private var startTask: Task<Void, Never>?
    private var consumedID: UInt64 = 0

    private(set) var isStarted = false
    private(set) var hasFrames = false
    private(set) var lastError: String?

    init(device: MTLDevice? = MTLCreateSystemDefaultDevice()) {
        self.device = device
    }

    /// Begins capturing, or does nothing if already running.
    func start() {
        guard !isStarted, device != nil, ScreenRecordingPermission.isGranted else { return }
        guard let displayID = NSScreen.builtIn?.displayID else { return }
        isStarted = true
        hasFrames = false
        startTask = Task { [weak self] in
            await self?.begin(displayID: displayID)
            self?.startTask = nil
        }
    }

    func stop() {
        guard isStarted || stream != nil else { return }
        isStarted = false
        hasFrames = false
        startTask?.cancel()
        startTask = nil
        let closing = stream
        stream = nil
        receiver = nil
        consumedID = 0
        guard let closing else { return }
        Task {
            try? await closing.stopCapture()
            lidLog.notice("stream stopped")
        }
    }

    /// The newest frame, once. `nil` when nothing new has arrived.
    func newFrame() -> CapturedFrame? {
        guard let latest = receiver?.latest(), latest.id != consumedID else { return nil }
        consumedID = latest.id
        hasFrames = true
        return latest.frame
    }

    private func begin(displayID: CGDirectDisplayID) async {
        guard let device, let receiver = Receiver(device: device) else {
            isStarted = false
            return
        }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard !Task.isCancelled, isStarted else { return }
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
                isStarted = false
                lastError = "built-in display not found"
                return
            }
            // Leave our own overlay out of its own picture.
            let bundleID = Bundle.main.bundleIdentifier
            let own = content.applications.filter { $0.bundleIdentifier == bundleID }
            let filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])

            let configuration = SCStreamConfiguration()
            configuration.width = Int(filter.contentRect.width * CGFloat(filter.pointPixelScale))
            configuration.height = Int(filter.contentRect.height * CGFloat(filter.pointPixelScale))
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
            configuration.pixelFormat = kCVPixelFormatType_32BGRA
            configuration.colorSpaceName = Self.colourSpaceName
            configuration.showsCursor = false
            configuration.queueDepth = 5
            configuration.scalesToFit = false
            configuration.capturesAudio = false

            let started = CACurrentMediaTime()
            let fresh = SCStream(filter: filter, configuration: configuration, delegate: nil)
            try fresh.addStreamOutput(
                receiver, type: .screen,
                sampleHandlerQueue: DispatchQueue(label: "LidUpAnimation.frames", qos: .userInteractive)
            )
            try await fresh.startCapture()
            guard !Task.isCancelled, isStarted else {
                try? await fresh.stopCapture()
                return
            }
            self.receiver = receiver
            self.stream = fresh
            lastError = nil
            lidLog.notice("stream started \(configuration.width)x\(configuration.height) in \((CACurrentMediaTime() - started) * 1000, format: .fixed(precision: 0)) ms")
        } catch {
            guard !Task.isCancelled else { return }
            lastError = String(describing: error)
            lidLog.error("stream failed: \(String(describing: error), privacy: .public)")
            isStarted = false
        }
    }
}
