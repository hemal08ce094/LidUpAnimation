import AppKit
import Metal

/// Offscreen check: renders the fold over generated artwork at a series of
/// lid angles and writes PNGs, so the look can be inspected without a lid.
///
///     LidUpAnimation --render-check /path/to/output
enum RenderCheck {

    static func run(outputDirectory: String) -> Int32 {
        let size = CGSize(width: 1512, height: 982)
        let scale: CGFloat = 2
        guard let renderer = FoldRenderer() else {
            FileHandle.standardError.write("no Metal renderer\n".data(using: .utf8)!)
            return 1
        }
        guard renderer.begin(screenSize: size, pixelScale: scale) else { return 1 }
        guard let artwork = makeArtwork(width: Int(size.width * scale), height: Int(size.height * scale)) else { return 1 }
        renderer.absorb(image: artwork)

        let directory = URL(fileURLWithPath: outputDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm_srgb,
            width: Int(size.width * scale), height: Int(size.height * scale), mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        guard let target = renderer.device.makeTexture(descriptor: descriptor) else { return 1 }

        let reference = 112.0
        let darkAngle = 25.0
        let angles: [Double] = [112, 108, 100, 90, 80, 70, 60, 50, 40, 30, 22]
        for angle in angles {
            let progress = min(max((reference - angle) / (reference - darkAngle), 0), 1)
            let parameters = FoldParameters(
                referenceAngle: reference, currentAngle: angle, progress: progress,
                viewingDistance: 2.5, maxBlurRadius: 90, maxDim: 1
            )
            renderer.render(parameters, into: target)
            let name = String(format: "fold_%03d.png", Int(angle))
            save(texture: target, to: directory.appendingPathComponent(name))
        }
        save(image: artwork, to: directory.appendingPathComponent("source.png"))
        print("wrote \(angles.count) frames to \(directory.path)")
        return 0
    }

    private static func makeArtwork(width: Int, height: Int) -> CGImage? {
        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()
        let rect = NSRect(x: 0, y: 0, width: width, height: height)
        NSGradient(colors: [NSColor(red: 0.10, green: 0.16, blue: 0.30, alpha: 1),
                            NSColor(red: 0.55, green: 0.25, blue: 0.45, alpha: 1)])!
            .draw(in: rect, angle: 60)
        NSColor.white.withAlphaComponent(0.35).setStroke()
        let step = width / 16
        for x in stride(from: 0, through: width, by: step) {
            NSBezierPath.strokeLine(from: NSPoint(x: x, y: 0), to: NSPoint(x: x, y: height))
        }
        for y in stride(from: 0, through: height, by: step) {
            NSBezierPath.strokeLine(from: NSPoint(x: 0, y: y), to: NSPoint(x: width, y: y))
        }
        // Menu bar and dock stand-ins.
        NSColor.black.withAlphaComponent(0.5).setFill()
        NSRect(x: 0, y: height - 48, width: width, height: 48).fill()
        NSColor.white.withAlphaComponent(0.25).setFill()
        NSBezierPath(roundedRect: NSRect(x: width / 3, y: 24, width: width / 3, height: 130), xRadius: 30, yRadius: 30).fill()
        for i in 0..<8 {
            NSColor(hue: CGFloat(i) / 8, saturation: 0.8, brightness: 1, alpha: 1).setFill()
            NSBezierPath(roundedRect: NSRect(x: width / 3 + 30 + i * 110, y: 44, width: 90, height: 90), xRadius: 20, yRadius: 20).fill()
        }
        let text = NSAttributedString(string: "Lid Up", attributes: [
            .font: NSFont.systemFont(ofSize: 220, weight: .bold),
            .foregroundColor: NSColor.white,
        ])
        text.draw(at: NSPoint(x: width / 2 - 380, y: height / 2 - 120))
        image.unlockFocus()
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    private static func save(texture: MTLTexture, to url: URL) {
        let width = texture.width, height = texture.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        texture.getBytes(&bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.displayP3)!,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
              ) else { return }
        save(image: image, to: url)
    }

    private static func save(image: CGImage, to url: URL) {
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: url)
    }
}
