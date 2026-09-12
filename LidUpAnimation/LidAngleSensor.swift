import Foundation
import IOKit.hid
import QuartzCore

/// Reads the MacBook lid hinge angle from Apple's built-in orientation sensor.
///
/// The sensor is an Apple HID device on usage page `0x20`, usage `0x8A`.
/// Reading it needs no permission. Two feature reports carry the angle:
///
/// - Report 7: `[0x07, b0, b1, b2, b3]`, little-endian hundredths of a degree.
/// - Report 1: `[0x01, lo, hi]`, whole degrees. Used when report 7 is missing.
///
/// The hardware refreshes the value about every 100 ms. Readings are taken on
/// a private queue and delivered on the main thread.
///
/// Device identifiers and report layout follow samhenrigold/LidAngleSensor and
/// sumimakito/Mac-Duo (Apache 2.0). See NOTICE.
final class LidAngleSensor {

    enum Resolution {
        case hundredthsOfADegree
        case wholeDegrees

        var reportID: Int {
            switch self {
            case .hundredthsOfADegree: return 7
            case .wholeDegrees: return 1
            }
        }
    }

    /// Called on the main thread with the angle in degrees (0 = closed) and
    /// the media time of the read, or `nil` when a read failed.
    var onReading: ((Double?, CFTimeInterval) -> Void)?

    private(set) var isAvailable = false
    private(set) var resolution: Resolution?

    private let queue = DispatchQueue(label: "LidUpAnimation.lidSensor", qos: .userInteractive)
    private var manager: IOHIDManager?
    private var device: IOHIDDevice?
    private var timer: DispatchSourceTimer?
    private var buffer = [UInt8](repeating: 0, count: 16)
    private var rateHz: Double = 0

    init() {
        queue.sync { open() }
    }

    deinit {
        timer?.cancel()
        if let device { IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone)) }
        if let manager { IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone)) }
    }

    /// One synchronous read. Safe to call from any thread.
    func readAngle() -> Double? {
        queue.sync { readLocked() }
    }

    /// Starts or retunes periodic reads.
    func setPollingRate(_ hz: Double) {
        queue.async { [self] in
            guard isAvailable, hz > 0 else { return }
            guard rateHz != hz else { return }
            rateHz = hz
            if timer == nil {
                let source = DispatchSource.makeTimerSource(queue: queue)
                source.setEventHandler { [weak self] in self?.tick() }
                timer = source
                source.resume()
            }
            timer?.schedule(deadline: .now(), repeating: 1.0 / hz, leeway: .milliseconds(2))
        }
    }

    func stop() {
        queue.async { [self] in
            timer?.cancel()
            timer = nil
            rateHz = 0
        }
    }

    // MARK: - Private

    private func tick() {
        let angle = readLocked()
        let time = CACurrentMediaTime()
        DispatchQueue.main.async { [weak self] in
            self?.onReading?(angle, time)
        }
    }

    private func open() {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matching: [String: Any] = [
            kIOHIDVendorIDKey: 0x05AC,
            kIOHIDDeviceUsagePageKey: 0x20,
            kIOHIDDeviceUsageKey: 0x8A,
        ]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)
        guard IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else { return }
        self.manager = manager

        guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else { return }
        for candidate in devices {
            // An external display can expose the same usage and always reads 0.
            let builtIn = (IOHIDDeviceGetProperty(candidate, kIOHIDBuiltInKey as CFString) as? NSNumber)?.boolValue ?? false
            guard builtIn else { continue }
            device = candidate
            for format in [Resolution.hundredthsOfADegree, .wholeDegrees] {
                resolution = format
                if readLocked() != nil {
                    isAvailable = true
                    return
                }
            }
        }
        device = nil
        resolution = nil
    }

    private func readLocked() -> Double? {
        guard let device, let resolution else { return nil }
        var length = CFIndex(buffer.count)
        let status = buffer.withUnsafeMutableBufferPointer { pointer -> IOReturn in
            guard let base = pointer.baseAddress else { return kIOReturnBadArgument }
            return IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, CFIndex(resolution.reportID), base, &length)
        }
        guard status == kIOReturnSuccess, length > 0, buffer[0] == UInt8(resolution.reportID) else { return nil }

        let degrees: Double
        switch resolution {
        case .hundredthsOfADegree:
            guard length >= 5 else { return nil }
            let raw = UInt32(buffer[1]) | UInt32(buffer[2]) << 8 | UInt32(buffer[3]) << 16 | UInt32(buffer[4]) << 24
            degrees = Double(raw) / 100
        case .wholeDegrees:
            guard length >= 3 else { return nil }
            degrees = Double(UInt16(buffer[1]) | UInt16(buffer[2]) << 8)
        }
        guard degrees >= 0, degrees <= 360 else { return nil }
        return degrees
    }
}
