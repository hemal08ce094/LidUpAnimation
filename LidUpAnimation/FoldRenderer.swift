import AppKit
import Metal
import MetalPerformanceShaders
import QuartzCore
import simd

/// The optical model of the fold.
///
/// The picture is a sheet that stays where the screen was when the lid began
/// to move (the reference angle). The glass rotates under it. A fixed eye in
/// front of the Mac looks through each glass pixel and sees whatever point of
/// the anchored picture lies on that line of sight. As the lid tilts, the
/// picture also frosts over and dims towards the top, so it slips into black
/// before the hinge closes.
struct FoldParameters {
    /// Lid angle the picture is anchored at, degrees.
    var referenceAngle: Double = 110
    /// Where the glass is now, degrees.
    var currentAngle: Double = 110
    /// 0 at the reference angle, 1 fully dark.
    var progress: Double = 0
    /// Eye distance from the screen centre in screen heights.
    var viewingDistance: Double = 2.5
    /// Blur radius at full progress, points.
    var maxBlurRadius: Double = 90
    /// Darkening at full progress, 0...1.
    var maxDim: Double = 1
}

/// Draws the fold with Metal.
///
/// The picture lives on a black margin in one mipmapped texture, with a
/// Gaussian pyramid over it. Every frame is one full-screen fragment pass that
/// maps each glass pixel back into the picture and samples the pyramid at the
/// level the blur there calls for.
final class FoldRenderer {

    /// Black margin around the picture, in points. Keeps the blur reaching
    /// real black at the edges.
    static let padding: CGFloat = 128

    private struct Uniforms {
        var screen: SIMD4<Float>   // width, height (points), pixel scale, flat flag
        var eye: SIMD4<Float>      // eye position, world points
        var angles: SIMD4<Float>   // sin/cos current, sin/cos reference
        var tex: SIMD4<Float>      // padded origin xy, padded size xy (points)
        var blur: SIMD4<Float>     // max radius px, strength, hinge floor, max mip level
        var dim: SIMD4<Float>      // strength, hinge floor, reach, max dim
    }

    static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct Uniforms {
        float4 screen;
        float4 eye;
        float4 angles;
        float4 tex;
        float4 blur;
        float4 dim;
    };

    vertex float4 foldVertex(uint vid [[vertex_id]]) {
        const float2 corners[3] = { float2(-1.0, -3.0), float2(-1.0, 1.0), float2(3.0, 1.0) };
        return float4(corners[vid], 0.0, 1.0);
    }

    fragment float4 foldFragment(float4 position [[position]],
                                 constant Uniforms &u [[buffer(0)]],
                                 texture2d<float> picture [[texture(0)]]) {
        constexpr sampler linearSampler(filter::linear, mip_filter::linear, address::clamp_to_edge);
        const float4 black = float4(0.0, 0.0, 0.0, 1.0);

        float2 size = u.screen.xy;
        float scale = u.screen.z;
        // Glass point in points, y up from the hinge.
        float2 g = float2(position.x / scale, size.y - position.y / scale);

        float2 pic;
        if (u.screen.w > 0.5) {
            pic = g;
        } else {
            float sinT = u.angles.x, cosT = u.angles.y, sinR = u.angles.z, cosR = u.angles.w;
            // Hinge along the x axis at the origin, y up, z towards the viewer.
            float3 G = float3(g.x, g.y * sinT, g.y * cosT);
            float3 E = u.eye.xyz;
            float3 D = G - E;
            float3 n0 = float3(0.0, cosR, -sinR);       // picture plane normal
            float denom = dot(D, n0);
            if (fabs(denom) < 1e-5) { return black; }
            float t = -dot(E, n0) / denom;
            if (t <= 0.0) { return black; }
            float3 P = E + t * D;
            pic = float2(P.x, dot(P, float3(0.0, sinR, cosR)));
        }

        float2 unit = (pic - u.tex.xy) / u.tex.zw;
        if (any(unit < 0.0) || any(unit > 1.0)) { return black; }
        float2 uv = float2(unit.x, 1.0 - unit.y);

        float height = clamp(pic.y / size.y, 0.0, 1.0);
        float blurAmount = u.blur.y * (u.blur.z + (1.0 - u.blur.z) * height);
        float radius = blurAmount * u.blur.x;
        float3 colour;
        if (radius < 0.5) {
            colour = picture.sample(linearSampler, uv, level(0.0)).rgb;
        } else {
            float mip = clamp(log2(radius), 0.0, u.blur.w);
            float2 texel = exp2(mip) / float2(picture.get_width(), picture.get_height());
            const float w[3] = { 0.25, 0.5, 0.25 };
            colour = float3(0.0);
            for (int j = -1; j <= 1; j++) {
                for (int i = -1; i <= 1; i++) {
                    float2 offset = float2(float(i), float(j)) * texel;
                    colour += w[i + 1] * w[j + 1] * picture.sample(linearSampler, uv + offset, level(mip)).rgb;
                }
            }
        }

        float spread = smoothstep(0.0, max(u.dim.z, 0.02), height);
        float fade = u.dim.x * (u.dim.y + (1.0 - u.dim.y) * spread);
        // Samples are linear light; the power keeps the setting perceptual.
        colour *= pow(max(1.0 - u.dim.w * fade, 0.0), 2.2);
        return float4(colour, 1.0);
    }
    """

    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private lazy var pyramid = MPSImageGaussianPyramid(device: device, centerWeight: 0.375)

    private(set) var layer = CAMetalLayer()
    private var picture: MTLTexture?
    private var pendingFrame: CapturedFrame?
    private var pendingImage: CGImage?
    private var screenSize: CGSize = .zero
    private var pixelScale: CGFloat = 2
    private var maxLevel: Float = 0

    /// True once a frame has been absorbed, so there is something to show.
    private(set) var hasPicture = false

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.queue = queue
        do {
            let library = try device.makeLibrary(source: Self.shaderSource, options: nil)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "foldVertex")
            descriptor.fragmentFunction = library.makeFunction(name: "foldFragment")
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb
            pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            NSLog("LidUpAnimation: Metal pipeline failed: \(error)")
            return nil
        }
        configure(layer)
    }

    /// A fresh layer for a new overlay window.
    func makeLayer() -> CAMetalLayer {
        let fresh = CAMetalLayer()
        configure(fresh)
        layer = fresh
        return fresh
    }

    private func configure(_ target: CAMetalLayer) {
        target.device = device
        target.pixelFormat = .bgra8Unorm_srgb
        target.framebufferOnly = true
        // An opaque full-screen layer makes the window server treat every
        // window behind it as hidden, and apps stop drawing. The shader writes
        // alpha 1 everywhere, so blending gives the same picture.
        target.isOpaque = false
        // The display link paces drawing; waiting here would stall the main
        // thread whenever the window server is late with a drawable.
        target.displaySyncEnabled = false
        target.colorspace = CGColorSpace(name: ScreenStreamer.colourSpaceName)
    }

    // MARK: - Picture

    /// Prepares the padded picture texture for a screen. Frames are absorbed
    /// into it afterwards.
    @discardableResult
    func begin(screenSize: CGSize, pixelScale: CGFloat) -> Bool {
        let padded = CGSize(width: screenSize.width + 2 * Self.padding, height: screenSize.height + 2 * Self.padding)
        let width = Int((padded.width * pixelScale).rounded())
        let height = Int((padded.height * pixelScale).rounded())
        guard width > 0, height > 0 else { return false }

        if picture == nil || picture?.width != width || picture?.height != height {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm_srgb, width: width, height: height, mipmapped: true
            )
            descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
            descriptor.storageMode = .private
            guard let fresh = device.makeTexture(descriptor: descriptor) else { return false }
            clearToBlack(fresh)
            picture = fresh
        }
        self.screenSize = screenSize
        self.pixelScale = pixelScale
        maxLevel = Float(Int(floor(log2(Double(max(width, height))))))
        hasPicture = false
        pendingFrame = nil
        pendingImage = nil
        layer.drawableSize = CGSize(width: screenSize.width * pixelScale, height: screenSize.height * pixelScale)
        return true
    }

    /// Takes one live frame. The copy and the pyramid are encoded on the next
    /// drawn frame's command buffer.
    func absorb(_ frame: CapturedFrame) {
        pendingFrame = frame
        pendingImage = nil
        hasPicture = true
    }

    /// Takes one still image (used by the render check).
    func absorb(image: CGImage) {
        pendingImage = image
        pendingFrame = nil
        hasPicture = true
    }

    func release() {
        picture = nil
        pendingFrame = nil
        pendingImage = nil
        hasPicture = false
    }

    private func clearToBlack(_ target: MTLTexture) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        guard let commands = queue.makeCommandBuffer(),
              let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
    }

    private func absorbPending(into commands: MTLCommandBuffer) {
        guard var target = picture, pendingFrame != nil || pendingImage != nil else { return }
        let inset = Int((Self.padding * pixelScale).rounded())
        guard let blit = commands.makeBlitCommandEncoder() else { return }
        if let frame = pendingFrame {
            let width = min(frame.texture.width, target.width - 2 * inset)
            let height = min(frame.texture.height, target.height - 2 * inset)
            if width > 0, height > 0 {
                blit.copy(
                    from: frame.texture, sourceSlice: 0, sourceLevel: 0,
                    sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                    sourceSize: MTLSize(width: width, height: height, depth: 1),
                    to: target, destinationSlice: 0, destinationLevel: 0,
                    destinationOrigin: MTLOrigin(x: inset, y: inset, z: 0)
                )
            }
            commands.addCompletedHandler { _ in withExtendedLifetime(frame) {} }
        } else if let image = pendingImage, let staging = stage(image) {
            let width = min(staging.width, target.width - 2 * inset)
            let height = min(staging.height, target.height - 2 * inset)
            blit.copy(
                from: staging.buffer, sourceOffset: 0,
                sourceBytesPerRow: staging.width * 4,
                sourceBytesPerImage: staging.width * 4 * staging.height,
                sourceSize: MTLSize(width: width, height: height, depth: 1),
                to: target, destinationSlice: 0, destinationLevel: 0,
                destinationOrigin: MTLOrigin(x: inset, y: inset, z: 0)
            )
        }
        pendingFrame = nil
        pendingImage = nil
        blit.endEncoding()
        pyramid.encode(commandBuffer: commands, inPlaceTexture: &target, fallbackCopyAllocator: nil)
        picture = target
    }

    private func stage(_ image: CGImage) -> (buffer: MTLBuffer, width: Int, height: Int)? {
        let width = Int((screenSize.width * pixelScale).rounded())
        let height = Int((screenSize.height * pixelScale).rounded())
        guard width > 0, height > 0,
              let buffer = device.makeBuffer(length: width * height * 4, options: .storageModeShared),
              let space = CGColorSpace(name: ScreenStreamer.colourSpaceName),
              let context = CGContext(
                data: buffer.contents(), width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
              ) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return (buffer, width, height)
    }

    // MARK: - Drawing

    private func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
        let t = min(max((x - edge0) / (edge1 - edge0), 0), 1)
        return t * t * (3 - 2 * t)
    }

    private func uniforms(for p: FoldParameters) -> Uniforms {
        let width = Double(screenSize.width)
        let height = Double(screenSize.height)
        let reference = p.referenceAngle * .pi / 180
        let current = min(p.currentAngle, p.referenceAngle) * .pi / 180
        let flat: Float = abs(p.currentAngle - p.referenceAngle) < 0.01 && p.progress <= 0 ? 1 : 0

        // The eye sits level with the screen centre at the reference angle,
        // `viewingDistance` screen heights in front of it.
        let centre = SIMD3(width / 2, height / 2 * sin(reference), height / 2 * cos(reference))
        let eye = centre + SIMD3(0, 0, p.viewingDistance * height)

        let progress = min(max(p.progress, 0), 1)
        let blurStrength = pow(progress, 1.5)
        let dimStrength = pow(progress, 0.8)
        // Both start as gradients from the hinge and flatten out as the fold
        // completes, so the last frame is black everywhere, not just at the top.
        let blurFloor = 0.15 + 0.65 * progress * progress
        let late = smoothstep(0.55, 1, progress)
        let dimFloor = 0.25 + 0.75 * late

        return Uniforms(
            screen: SIMD4(Float(width), Float(height), Float(pixelScale), flat),
            eye: SIMD4(Float(eye.x), Float(eye.y), Float(eye.z), 0),
            angles: SIMD4(Float(sin(current)), Float(cos(current)), Float(sin(reference)), Float(cos(reference))),
            tex: SIMD4(Float(-Self.padding), Float(-Self.padding),
                       Float(width + 2 * Double(Self.padding)), Float(height + 2 * Double(Self.padding))),
            blur: SIMD4(Float(p.maxBlurRadius * Double(pixelScale)), Float(blurStrength), Float(blurFloor), maxLevel),
            dim: SIMD4(Float(dimStrength), Float(dimFloor), 0.6, Float(p.maxDim))
        )
    }

    /// Draws the next frame to the layer.
    func draw(_ parameters: FoldParameters) {
        guard let commands = queue.makeCommandBuffer() else { return }
        absorbPending(into: commands)
        guard let picture, hasPicture, let drawable = layer.nextDrawable() else {
            commands.commit()
            return
        }
        encode(parameters, picture: picture, target: drawable.texture, commands: commands)
        commands.present(drawable)
        commands.commit()
    }

    /// Draws one frame into an arbitrary texture and waits for it.
    func render(_ parameters: FoldParameters, into target: MTLTexture) {
        guard let commands = queue.makeCommandBuffer() else { return }
        absorbPending(into: commands)
        guard let picture, hasPicture else {
            commands.commit()
            return
        }
        encode(parameters, picture: picture, target: target, commands: commands)
        commands.commit()
        commands.waitUntilCompleted()
    }

    private func encode(_ parameters: FoldParameters, picture: MTLTexture, target: MTLTexture, commands: MTLCommandBuffer) {
        var uniforms = uniforms(for: parameters)
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.setFragmentTexture(picture, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }
}
