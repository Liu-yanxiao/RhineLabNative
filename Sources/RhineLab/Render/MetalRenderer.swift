import Metal
import MetalKit
import simd
import CoreGraphics

/// Mirrors `Frame` in the shader.
struct FrameUniforms {
    var viewProj = matrix_identity_float4x4
    var view = matrix_identity_float4x4
    var proj = matrix_identity_float4x4
    var lightViewProj = matrix_identity_float4x4
    var camPos = SIMD4<Float>(0, 0, 0, 1)
    var params = SIMD4<Float>(1.05, 20, 50, 0.48)
    var screen = SIMD4<Float>(1, 1, 0, 0)
    var fogColor = SIMD4<Float>(0, 0, 0, 1)
    var keyDir = SIMD4<Float>(0, 1, 0, 0)
    var keyColor = SIMD4<Float>(1, 1, 1, 1)
    var fillDir = SIMD4<Float>(0, 1, 0, 0)
    var fillColor = SIMD4<Float>(1, 1, 1, 1)
    var hemiSky = SIMD4<Float>(1, 1, 1, 1)
    var hemiGround = SIMD4<Float>(1, 1, 1, 1)
    var post = SIMD4<Float>(0, 0, 0, 0)
    var clip = SIMD4<Float>(10, 300, 0, 0.011)   // near, far, aperture, max blur
    var ao = SIMD4<Float>(0.5, 1.2, 0.05, 0)     // radius, strength, bias
}

struct InstanceData {
    var posTilt: SIMD4<Float>
    var yawQR: SIMD4<Float>
}

/// Deferred-transmission renderer: shadow map → opaque pass (MSAA) → blurred capture
/// → transmissive pass (frosted glass samples the capture) → tone-mapped composite.
final class MetalRenderer {
    static let sampleCount = 4

    let device: MTLDevice
    private let queue: MTLCommandQueue
    // Scene pipelines per sample count (4× MSAA, or 1 when anti-aliasing is off).
    private var pipeOpaqueBy: [Int: MTLRenderPipelineState] = [:]
    private var pipeTransBy: [Int: MTLRenderPipelineState] = [:]
    private var pipeLabelBy: [Int: MTLRenderPipelineState] = [:]
    private var pipeOpaque: MTLRenderPipelineState { pipeOpaqueBy[samples]! }
    private var pipeTrans: MTLRenderPipelineState { pipeTransBy[samples]! }
    private var pipeLabel: MTLRenderPipelineState { pipeLabelBy[samples]! }
    private var labelSampler: MTLSamplerState!
    private var pipeShadow: MTLRenderPipelineState!
    private var pipeComposite: MTLRenderPipelineState!
    private var pipeAO: MTLRenderPipelineState!
    private var aoTexture: MTLTexture!
    private var library: MTLLibrary!
    private var envSpec: MTLTexture!
    private var envIrr: MTLTexture!
    private var depthWrite: MTLDepthStencilState!
    private var depthNoWrite: MTLDepthStencilState!
    private var compositeFormat: MTLPixelFormat

    // Quality: set from the main thread, adopted at the start of the next frame.
    private let qualityLock = NSLock()
    private var requestedQuality = RenderQuality.original
    private(set) var quality = RenderQuality.original
    private var samples = 4
    var renderQuality: RenderQuality {
        get { qualityLock.lock(); defer { qualityLock.unlock() }; return requestedQuality }
        set { qualityLock.lock(); requestedQuality = newValue; qualityLock.unlock() }
    }

    // Geometry
    private var arrayMeshes: [GPUMesh] = []
    private var cardMeshes: [GPUMesh] = []
    private var assemblyMeshes: [(part: String, mesh: GPUMesh)] = []
    private var floorMesh: GPUMesh!
    private var labelMesh: GPUMesh!
    private var labelTextures: [Int: MTLTexture] = [:]

    // Per-frame buffers
    private var arrayBuffers: [MTLBuffer] = []
    private var bufferIndex = 0
    private let inFlight = DispatchSemaphore(value: 3)

    // Targets (re-created when the size changes)
    private var size = (w: 0, h: 0)
    private var msaaColor: MTLTexture!
    private var msaaDepth: MTLTexture!
    private var captureColor: MTLTexture!
    private var captureDepth: MTLTexture!
    private var captureMSAA: MTLTexture!
    private var resolved: MTLTexture!
    private var depthResolved: MTLTexture!
    private var shadowMap: MTLTexture!

    static let exposure: Float = Float(ProcessInfo.processInfo.environment["RL_EXPOSURE"] ?? "") ?? 1.2
    static let aoRadius: Float = Float(ProcessInfo.processInfo.environment["RL_AO_RADIUS"] ?? "") ?? 2.0
    static let aoStrength: Float = Float(ProcessInfo.processInfo.environment["RL_AO"] ?? "") ?? 3.0
    static let keyScale: Float = Float(ProcessInfo.processInfo.environment["RL_KEY"] ?? "") ?? 1.4
    static let fillScale: Float = Float(ProcessInfo.processInfo.environment["RL_FILL"] ?? "") ?? 0.6
    static let hemiScale: Float = Float(ProcessInfo.processInfo.environment["RL_HEMI"] ?? "") ?? 0.65
    static let envScale: Float = Float(ProcessInfo.processInfo.environment["RL_ENV"] ?? "") ?? 0.48
    /// Linear colours that come out as the requested sRGB colour after tone mapping at `exposure`.
    private var backgroundCache: [UInt64: SIMD3<Float>] = [:]
    private func linearBackground(_ srgb: SIMD3<Float>, exposure: Float) -> SIMD3<Float> {
        func byte(_ v: Float) -> UInt64 { UInt64(max(0, min(255, (v * 255).rounded()))) }
        let key = byte(srgb.x) << 16 | byte(srgb.y) << 8 | byte(srgb.z) | UInt64(max(0, exposure) * 10000) << 24
        if let hit = backgroundCache[key] { return hit }
        if backgroundCache.count > 256 { backgroundCache.removeAll() }
        let solved = Self.solveBackground(target: srgb, exposure: exposure)
        backgroundCache[key] = solved
        return solved
    }

    // Per-pass GPU timing (benchmark only): shadow, capture, main, ao, composite.
    var passTimingEnabled = false
    private var timingBuffer: MTLCounterSampleBuffer?
    private(set) var passNames = ["shadow", "capture", "main", "composite"]
    private var passTotals = [Double](repeating: 0, count: 4)
    private var passFrames = 0

    private func timingSupported() -> Bool {
        device.supportsCounterSampling(.atStageBoundary) && device.counterSets?.contains { $0.name == MTLCommonCounterSet.timestamp.rawValue } == true
    }

    /// Attach start/end timestamp samples for pass `index` to a render pass descriptor.
    private func timed(_ d: MTLRenderPassDescriptor, _ index: Int) {
        guard passTimingEnabled, let buf = timingBuffer else { return }
        d.sampleBufferAttachments[0].sampleBuffer = buf
        d.sampleBufferAttachments[0].startOfVertexSampleIndex = index * 2
        d.sampleBufferAttachments[0].endOfVertexSampleIndex = MTLCounterDontSample
        d.sampleBufferAttachments[0].startOfFragmentSampleIndex = MTLCounterDontSample
        d.sampleBufferAttachments[0].endOfFragmentSampleIndex = index * 2 + 1
    }

    func passTimingReport() -> String {
        guard passFrames > 0 else { return "" }
        return zip(passNames, passTotals).map { String(format: "%@ %.2f", $0, $1 / Double(passFrames)) }.joined(separator: "  ") + " ms"
    }

    var statsEnabled = ProcessInfo.processInfo.environment["RL_STATS"] != nil
    private let gpuLock = NSLock()
    private var gpuEMA = 4.0
    /// Smoothed GPU milliseconds per frame (drives adaptive quality).
    var smoothedGPUms: Double { gpuLock.lock(); defer { gpuLock.unlock() }; return gpuEMA }
    private var gpuSamples: [Double] = []
    /// GPU milliseconds of recent frames (diagnostics).
    func drainGPUTimes() -> [Double] { gpuLock.lock(); defer { gpuLock.unlock() }; let s = gpuSamples; gpuSamples = []; return s }

    private static func aces(_ input: SIMD3<Float>, exposure: Float) -> SIMD3<Float> {
        let c: SIMD3<Float> = input * (exposure / 0.6)
        let inM = float3x3(columns: (SIMD3<Float>(0.59719, 0.07600, 0.02840), SIMD3<Float>(0.35458, 0.90834, 0.13383), SIMD3<Float>(0.04823, 0.01566, 0.83777)))
        let outM = float3x3(columns: (SIMD3<Float>(1.60475, -0.10208, -0.00327), SIMD3<Float>(-0.53108, 1.10813, -0.07276), SIMD3<Float>(-0.07367, -0.00605, 1.07602)))
        let v: SIMD3<Float> = inM * c
        var out = SIMD3<Float>(repeating: 0)
        var fitted = SIMD3<Float>(repeating: 0)
        for i in 0..<3 {
            let x = v[i]
            let a = x * (x + 0.0245786) - 0.000090537
            let b = x * (0.983729 * x + 0.4329510) + 0.238081
            fitted[i] = a / b
        }
        let r: SIMD3<Float> = outM * fitted
        for i in 0..<3 { out[i] = min(1, max(0, r[i])) }
        return out
    }

    private static func solveBackground(target: SIMD3<Float>, exposure: Float) -> SIMD3<Float> {
        var want = SIMD3<Float>(repeating: 0)
        for i in 0..<3 {
            let s = target[i]
            want[i] = s <= 0.04045 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4)
        }
        var x = want
        for _ in 0..<200 {
            let got = aces(x, exposure: exposure)
            x += (want - got) * 0.6
        }
        return x
    }

    init?(device: MTLDevice? = MTLCreateSystemDefaultDevice(), compositeFormat: MTLPixelFormat = .bgra8Unorm) {
        guard let device, let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.queue = queue
        self.compositeFormat = compositeFormat
        do {
            try buildPipelines()
            try loadGeometry()
            try buildEnvironment()
        } catch {
            FileHandle.standardError.write(Data("Renderer setup failed: \(error)\n".utf8))
            return nil
        }
        preloadLabels(count: Archive.records.count)
        arrayBuffers = (0..<3).map { _ in device.makeBuffer(length: 512 * MemoryLayout<InstanceData>.stride, options: .storageModeShared)! }
    }

    // MARK: Setup

    private func buildPipelines() throws {
        library = try device.makeLibrary(source: shaderSource, options: nil)
        let vd = MTLVertexDescriptor()
        vd.attributes[0].format = .float3; vd.attributes[0].offset = 0; vd.attributes[0].bufferIndex = 0
        vd.attributes[1].format = .float3; vd.attributes[1].offset = 12; vd.attributes[1].bufferIndex = 0
        vd.attributes[2].format = .float2; vd.attributes[2].offset = 24; vd.attributes[2].bufferIndex = 0
        vd.layouts[0].stride = 32

        func scene(_ vertex: String, _ fragment: String, blend: Bool = false, samples: Int = MetalRenderer.sampleCount) throws -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = library.makeFunction(name: vertex)
            d.fragmentFunction = library.makeFunction(name: fragment)
            d.vertexDescriptor = vd
            d.rasterSampleCount = samples
            d.colorAttachments[0].pixelFormat = .rgba16Float
            d.depthAttachmentPixelFormat = .depth32Float
            if blend {
                let a = d.colorAttachments[0]!
                a.isBlendingEnabled = true
                a.sourceRGBBlendFactor = .sourceAlpha; a.destinationRGBBlendFactor = .oneMinusSourceAlpha
                a.sourceAlphaBlendFactor = .one; a.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            }
            return try device.makeRenderPipelineState(descriptor: d)
        }
        for count in [1, 4] {
            pipeOpaqueBy[count] = try scene("vs_main", "fs_surface", samples: count)
            pipeTransBy[count] = try scene("vs_main", "fs_trans", samples: count)
            pipeLabelBy[count] = try scene("vs_main", "fs_label", blend: true, samples: count)
        }
        labelSampler = makeLabelSampler(anisotropy: quality.anisotropy)

        let s = MTLRenderPipelineDescriptor()
        s.vertexFunction = library.makeFunction(name: "vs_shadow")
        s.vertexDescriptor = vd
        s.depthAttachmentPixelFormat = .depth32Float
        pipeShadow = try device.makeRenderPipelineState(descriptor: s)

        let c = MTLRenderPipelineDescriptor()
        c.vertexFunction = library.makeFunction(name: "vs_full")
        c.fragmentFunction = library.makeFunction(name: "fs_composite")
        c.colorAttachments[0].pixelFormat = compositeFormat
        pipeComposite = try device.makeRenderPipelineState(descriptor: c)

        let ao = MTLRenderPipelineDescriptor()
        ao.vertexFunction = library.makeFunction(name: "vs_full")
        ao.fragmentFunction = library.makeFunction(name: "fs_ao")
        ao.colorAttachments[0].pixelFormat = .r8Unorm
        pipeAO = try device.makeRenderPipelineState(descriptor: ao)

        let on = MTLDepthStencilDescriptor(); on.depthCompareFunction = .lessEqual; on.isDepthWriteEnabled = true
        depthWrite = device.makeDepthStencilState(descriptor: on)
        let off = MTLDepthStencilDescriptor(); off.depthCompareFunction = .lessEqual; off.isDepthWriteEnabled = false
        depthNoWrite = device.makeDepthStencilState(descriptor: off)
    }

    private func makeLabelSampler(anisotropy: Int) -> MTLSamplerState {
        let d = MTLSamplerDescriptor()
        d.minFilter = .linear; d.magFilter = .linear; d.mipFilter = .linear
        d.sAddressMode = .clampToEdge; d.tAddressMode = .clampToEdge
        d.maxAnisotropy = max(1, min(16, anisotropy))
        return device.makeSamplerState(descriptor: d)!
    }

    /// Adopt a changed quality: pipelines, targets and the shadow map follow on this frame.
    private func adoptQuality() {
        qualityLock.lock(); let next = requestedQuality; qualityLock.unlock()
        guard next != quality else { return }
        if next.anisotropy != quality.anisotropy { labelSampler = makeLabelSampler(anisotropy: next.anisotropy) }
        if next.shadows != quality.shadows { shadowMap = nil }
        quality = next
        samples = next.antialias ? Self.sampleCount : 1
        targetCache.removeAll()
        size = (0, 0)
    }

    /// Bakes the studio environment once: a sharp radiance cube, GGX-prefiltered mips for glossy
    /// reflections (level k = roughness k/5) and a small irradiance cube for diffuse light.
    private func buildEnvironment() throws {
        struct Params { var face: UInt32; var roughness: Float; var mode: UInt32; var res: Float }
        func cube(_ size: Int, mips: Bool) -> MTLTexture {
            let d = MTLTextureDescriptor.textureCubeDescriptor(pixelFormat: .rgba16Float, size: size, mipmapped: mips)
            d.usage = [.renderTarget, .shaderRead]; d.storageMode = .private
            return device.makeTexture(descriptor: d)!
        }
        func pipeline(_ fragment: String) throws -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = library.makeFunction(name: "vs_full")
            d.fragmentFunction = library.makeFunction(name: fragment)
            d.colorAttachments[0].pixelFormat = .rgba16Float
            return try device.makeRenderPipelineState(descriptor: d)
        }
        let generate = try pipeline("fs_env_generate"), filter = try pipeline("fs_env_filter")
        let base = cube(256, mips: true)
        envSpec = cube(256, mips: true)
        envIrr = cube(16, mips: false)
        guard let cb = queue.makeCommandBuffer() else { return }

        func pass(_ texture: MTLTexture, level: Int, face: Int, _ state: MTLRenderPipelineState, _ params: Params, source: MTLTexture? = nil) {
            let d = MTLRenderPassDescriptor()
            d.colorAttachments[0].texture = texture
            d.colorAttachments[0].level = level
            d.colorAttachments[0].slice = face
            d.colorAttachments[0].loadAction = .dontCare
            d.colorAttachments[0].storeAction = .store
            guard let e = cb.makeRenderCommandEncoder(descriptor: d) else { return }
            var p = params
            e.setRenderPipelineState(state)
            e.setFragmentBytes(&p, length: MemoryLayout<Params>.stride, index: 0)
            if let source { e.setFragmentTexture(source, index: 0) }
            e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            e.endEncoding()
        }
        for face in 0..<6 {
            pass(base, level: 0, face: face, generate, Params(face: UInt32(face), roughness: 0, mode: 0, res: 256))
            pass(envSpec, level: 0, face: face, generate, Params(face: UInt32(face), roughness: 0, mode: 0, res: 256))
        }
        if let blit = cb.makeBlitCommandEncoder() { blit.generateMipmaps(for: base); blit.endEncoding() }
        for level in 1...5 {
            for face in 0..<6 {
                pass(envSpec, level: level, face: face, filter,
                     Params(face: UInt32(face), roughness: Float(level) / 5, mode: 0, res: Float(256 >> level)), source: base)
            }
        }
        for face in 0..<6 {
            pass(envIrr, level: 0, face: face, filter, Params(face: UInt32(face), roughness: 1, mode: 1, res: 16), source: base)
        }
        cb.commit()
        cb.waitUntilCompleted()
    }

    private func loadGeometry() throws {
        let meshes = try GLB.load(resource: "archive-cassette")
        arrayMeshes = meshes.filter { Surfaces.arraySurfaces.contains($0.materialName) }.map { GPUMesh(device: device, glb: $0) }
        cardMeshes = meshes.filter { !Surfaces.hidden.contains($0.materialName) }.map { GPUMesh(device: device, glb: $0) }
        // The same card split into assembly parts for the 360° viewer.
        assemblyMeshes = try GLB.load(resource: "archive-assembly")
            .filter { !Surfaces.hidden.contains($0.materialName) }
            .map { ($0.part ?? "cover", GPUMesh(device: device, glb: $0)) }

        let half: Float = 100, y: Float = -4.63
        floorMesh = GPUMesh(device: device,
            positions: [[-half, y, -half], [half, y, -half], [half, y, half], [-half, y, half]],
            normals: Array(repeating: [0, 1, 0], count: 4), uvs: Array(repeating: [0, 0], count: 4),
            indices: [0, 2, 1, 0, 3, 2], material: Surfaces.floor, kind: .floor, name: "Floor")

        // Printed label plane (0.99 × 0.46) in front of the cover.
        let (cx, cy, cz): (Float, Float, Float) = (-1.36, 3.04, 0.255)
        labelMesh = GPUMesh(device: device,
            positions: [[cx - 0.495, cy - 0.23, cz], [cx + 0.495, cy - 0.23, cz], [cx + 0.495, cy + 0.23, cz], [cx - 0.495, cy + 0.23, cz]],
            normals: Array(repeating: [0, 0, 1], count: 4), uvs: [[0, 1], [1, 1], [1, 0], [0, 0]],
            indices: [0, 1, 2, 0, 2, 3], material: SurfaceMat(), kind: .opaque, name: "Label")
    }

    /// Label textures are built off the render thread; a label that is not ready yet is skipped.
    private let labelLock = NSLock()
    private var labelsBuilding: Set<Int> = []

    private func labelTexture(_ index: Int) -> MTLTexture? {
        labelLock.lock(); defer { labelLock.unlock() }
        if let t = labelTextures[index] { return t }
        if !labelsBuilding.contains(index) {
            labelsBuilding.insert(index)
            DispatchQueue.global(qos: .userInitiated).async { [self] in buildLabel(index) }
        }
        return nil
    }

    func preloadLabels(count: Int) {
        DispatchQueue.global(qos: .utility).async { [self] in
            for i in 0..<count {
                labelLock.lock()
                let skip = labelTextures[i] != nil || labelsBuilding.contains(i)
                if !skip { labelsBuilding.insert(i) }
                labelLock.unlock()
                if !skip { buildLabel(i) }
            }
        }
    }

    private func buildLabel(_ index: Int) {
        let image = LabelImage.image(for: index)
        let w = image.width, h = image.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm_srgb, width: w, height: h, mipmapped: true)
        let t = device.makeTexture(descriptor: d)!
        t.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: bytes, bytesPerRow: w * 4)
        if let cb = queue.makeCommandBuffer(), let blit = cb.makeBlitCommandEncoder() {
            blit.generateMipmaps(for: t); blit.endEncoding()
            cb.addCompletedHandler { [self] _ in
                labelLock.lock(); labelTextures[index] = t; labelLock.unlock()
            }
            cb.commit()
        }
    }

    private struct Targets {
        var captureColor: MTLTexture, captureMSAA: MTLTexture?, captureDepth: MTLTexture
        var msaaColor: MTLTexture?, msaaDepth: MTLTexture?
        var resolved: MTLTexture, depthResolved: MTLTexture, ao: MTLTexture
    }
    private var targetCache: [Int: Targets] = [:]

    /// Render targets are cached per size, so switching between a motion and a still resolution is free.
    private func resize(_ w: Int, _ h: Int) {
        guard (w, h) != size else { return }
        size = (w, h)
        let key = w << 16 | h
        if targetCache[key] == nil {
            if targetCache.count >= 3 { targetCache.removeAll() }
            targetCache[key] = makeTargets(w, h)
        }
        let t = targetCache[key]!
        captureColor = t.captureColor; captureMSAA = t.captureMSAA; captureDepth = t.captureDepth
        msaaColor = t.msaaColor; msaaDepth = t.msaaDepth
        resolved = t.resolved; depthResolved = t.depthResolved; aoTexture = t.ao
        if shadowMap == nil {
            let side = quality.shadows > 0 ? quality.shadows : 16
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: side, height: side, mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]; d.storageMode = .private
            shadowMap = device.makeTexture(descriptor: d)
        }
    }

    private func makeTargets(_ w: Int, _ h: Int) -> Targets {
        func target(_ format: MTLPixelFormat, _ w: Int, _ h: Int, ms: Bool = false, mips: Bool = false,
                    read: Bool = false, memoryless: Bool = false) -> MTLTexture {
            let d = MTLTextureDescriptor()
            d.textureType = ms ? .type2DMultisample : .type2D
            d.pixelFormat = format; d.width = w; d.height = h
            d.sampleCount = ms ? samples : 1
            d.mipmapLevelCount = mips ? Int(floor(log2(Double(max(w, h))))) + 1 : 1
            d.usage = read ? [.renderTarget, .shaderRead] : [.renderTarget]
            d.storageMode = memoryless ? .memoryless : .private
            return device.makeTexture(descriptor: d)!
        }
        // MSAA targets live in tile memory only; just the resolves are stored. Without MSAA the
        // passes draw straight into the stored textures.
        let msaa = samples > 1
        let cw = max(1, Int(Float(w) * quality.transmission)), ch = max(1, Int(Float(h) * quality.transmission))
        let aw = max(1, Int(Float(w) * 0.5 * quality.aoResolution)), ah = max(1, Int(Float(h) * 0.5 * quality.aoResolution))
        return Targets(
            captureColor: target(.rgba16Float, cw, ch, mips: true, read: true),
            captureMSAA: msaa ? target(.rgba16Float, cw, ch, ms: true, memoryless: true) : nil,
            captureDepth: target(.depth32Float, cw, ch, ms: msaa, memoryless: true),
            msaaColor: msaa ? target(.rgba16Float, w, h, ms: true, memoryless: true) : nil,
            msaaDepth: msaa ? target(.depth32Float, w, h, ms: true, memoryless: true) : nil,
            resolved: target(.rgba16Float, w, h, read: true),
            depthResolved: target(.depth32Float, w, h, read: true),
            ao: target(.r8Unorm, aw, ah, read: true))
    }

    // MARK: Frame

    private func uniforms(_ frame: RenderFrame, width: Int, height: Int) -> FrameUniforms {
        var u = FrameUniforms()
        u.view = frame.view; u.proj = frame.proj
        u.viewProj = frame.proj * frame.view
        let lightEye = SIMD3<Float>(-6, 14, -5)
        let lightView = Matrix.lookAt(eye: lightEye, target: .zero, up: SIMD3(0, 1, 0))
        u.lightViewProj = Matrix.orthographic(left: -16, right: 16, bottom: -15, top: 15, near: 0.1, far: 45) * lightView
        u.camPos = SIMD4(frame.cameraPosition, 1)
        // Dark theme (web `themeEnvironment`): exposure 1.0 → 0.98, environment 0.52 → 0.32, lights × 0.65.
        let th = max(0, min(1, frame.themeAmount))
        let exposure = Self.exposure * (1 - 0.02 * th)
        let lights = 1 - 0.35 * th
        u.params = SIMD4(exposure, frame.fogNear, frame.fogFar, Self.envScale * (1 - 0.385 * th))
        u.screen = SIMD4(Float(width), Float(height), quality.shadows > 0 ? 1 : 0, frame.time)
        u.fogColor = SIMD4(linearBackground(frame.fogColor ?? frame.background, exposure: exposure), 1)
        u.keyDir = SIMD4(simd_normalize(lightEye), 0)
        u.keyColor = SIMD4(srgbLinear(0xfff7ed) * Self.keyScale * lights, 1)
        u.fillDir = SIMD4(simd_normalize(SIMD3<Float>(7, 8, -10)), 0)
        u.fillColor = SIMD4(SIMD3<Float>(repeating: 1) * Self.fillScale * lights, 1)
        u.hemiSky = SIMD4(srgbLinear(0xfffaf5) * Self.hemiScale * lights, 1)
        u.hemiGround = SIMD4(srgbLinear(0xb4a18c) * Self.hemiScale * lights, 1)
        let dof = frame.depthOfField * Float(quality.depthOfField) / 100
        var effectsOff = frame.effectsOff
        if quality.aoSamples == 0 { effectsOff |= 2 }
        u.post = SIMD4(frame.focusDistance, dof, Float(effectsOff), 0)
        let aperture = (0.0003 + (0.0008 - 0.0003) * frame.detail) * dof
        u.clip = SIMD4(frame.near, frame.far, aperture, 0.011)
        u.ao = SIMD4(Self.aoRadius, Self.aoStrength, 0.25, Float(max(16, quality.aoSamples)))
        return u
    }

    /// Draws one frame into `target` (a drawable texture or an offscreen texture).
    func render(_ frame: RenderFrame, to target: MTLTexture, present drawable: MTLDrawable? = nil,
                completion: (() -> Void)? = nil) {
        adoptQuality()
        resize(target.width, target.height)
        inFlight.wait()
        guard let cb = queue.makeCommandBuffer() else { inFlight.signal(); return }
        var u = uniforms(frame, width: target.width, height: target.height)
        if passTimingEnabled && timingBuffer == nil && timingSupported(),
           let set = device.counterSets?.first(where: { $0.name == MTLCommonCounterSet.timestamp.rawValue }) {
            let d = MTLCounterSampleBufferDescriptor()
            d.counterSet = set; d.storageMode = .shared; d.sampleCount = 8
            timingBuffer = try? device.makeCounterSampleBuffer(descriptor: d)
        }

        // Instances
        bufferIndex = (bufferIndex + 1) % arrayBuffers.count
        let arrayBuffer = arrayBuffers[bufferIndex]
        let count = min(frame.arrayCards.count, 512)
        let ptr = arrayBuffer.contents().bindMemory(to: InstanceData.self, capacity: 512)
        let themed = frame.arrayTheme.count >= count
        for i in 0..<count {
            ptr[i] = InstanceData(posTilt: frame.arrayCards[i], yawQR: SIMD4(0, 0, 0, themed ? frame.arrayTheme[i] : 0))
        }
        let cardInstances = frame.cards.map {
            InstanceData(posTilt: SIMD4($0.position, $0.tilt), yawQR: SIMD4($0.yaw, $0.quality, $0.reveal, $0.theme))
        }

        // 1. Shadow map: only the diffuser plates cast shadows.
        let sp = MTLRenderPassDescriptor()
        sp.depthAttachment.texture = shadowMap
        sp.depthAttachment.loadAction = .clear; sp.depthAttachment.storeAction = .store; sp.depthAttachment.clearDepth = 1
        timed(sp, 0)
        if quality.shadows > 0, let e = cb.makeRenderCommandEncoder(descriptor: sp) {
            e.setRenderPipelineState(pipeShadow)
            e.setDepthStencilState(depthWrite)
            e.setDepthBias(0.0, slopeScale: 1.5, clamp: 0.01)
            e.setCullMode(.none)
            e.setFrontFacing(.counterClockwise)
            e.setVertexBytes(&u, length: MemoryLayout<FrameUniforms>.stride, index: 1)
            if frame.assembly == nil {
                if let m = arrayMeshes.first(where: { $0.name == "Optical_Diffuser" }) {
                    e.setVertexBuffer(m.vertices, offset: 0, index: 0)
                    e.setVertexBuffer(arrayBuffer, offset: 0, index: 2)
                    e.drawIndexedPrimitives(type: .triangle, indexCount: m.indexCount, indexType: .uint32,
                                            indexBuffer: m.indices, indexBufferOffset: 0, instanceCount: count)
                }
                if let m = cardMeshes.first(where: { $0.name == "Optical_Diffuser" }) {
                    e.setVertexBuffer(m.vertices, offset: 0, index: 0)
                    for var inst in cardInstances {
                        e.setVertexBytes(&inst, length: MemoryLayout<InstanceData>.stride, index: 2)
                        e.drawIndexedPrimitives(type: .triangle, indexCount: m.indexCount, indexType: .uint32,
                                                indexBuffer: m.indices, indexBufferOffset: 0)
                    }
                }
            }
            e.endEncoding()
        }

        func bindScene(_ e: MTLRenderCommandEncoder) {
            e.setDepthStencilState(depthWrite)
            e.setCullMode(.none)
            e.setFrontFacing(.counterClockwise)
            e.setVertexBytes(&u, length: MemoryLayout<FrameUniforms>.stride, index: 1)
            e.setFragmentBytes(&u, length: MemoryLayout<FrameUniforms>.stride, index: 1)
            e.setFragmentTexture(shadowMap, index: 1)
            e.setFragmentTexture(envSpec, index: 4)
            e.setFragmentTexture(envIrr, index: 5)
        }
        func drawOpaque(_ e: MTLRenderCommandEncoder, capture: Bool = false) {
            if let a = frame.assembly { drawAssembly(e, a, transmissive: false, capture: capture); return }
            var identity = InstanceData(posTilt: .zero, yawQR: SIMD4(0, 0, 0, frame.themeAmount))
            e.setVertexBytes(&identity, length: MemoryLayout<InstanceData>.stride, index: 2)
            draw(floorMesh, on: e)
            for m in arrayMeshes where m.kind != .frost && (!capture || m.name != "Titanium_Fasteners") {
                e.setVertexBuffer(arrayBuffer, offset: 0, index: 2)
                draw(m, on: e, instances: count)
            }
            for var inst in cardInstances {
                e.setVertexBytes(&inst, length: MemoryLayout<InstanceData>.stride, index: 2)
                for m in cardMeshes where m.kind != .frost && m.kind != .ivory { draw(m, on: e) }
            }
        }
        let background = linearBackground(frame.background, exposure: u.params.x)
        let clear = MTLClearColor(red: Double(background.x), green: Double(background.y),
                                  blue: Double(background.z), alpha: 1)

        // 2. Opaque capture (MSAA, resolved into a mip chain): the glass blurs and refracts this.
        let cp0 = MTLRenderPassDescriptor()
        if let captureMSAA {
            cp0.colorAttachments[0].texture = captureMSAA
            cp0.colorAttachments[0].resolveTexture = captureColor
            cp0.colorAttachments[0].storeAction = .multisampleResolve
        } else {
            cp0.colorAttachments[0].texture = captureColor
            cp0.colorAttachments[0].storeAction = .store
        }
        cp0.colorAttachments[0].loadAction = .clear
        cp0.colorAttachments[0].clearColor = clear
        cp0.depthAttachment.texture = captureDepth
        cp0.depthAttachment.loadAction = .clear; cp0.depthAttachment.storeAction = .dontCare; cp0.depthAttachment.clearDepth = 1
        timed(cp0, 1)
        if let e = cb.makeRenderCommandEncoder(descriptor: cp0) {
            e.setRenderPipelineState(pipeOpaque)
            bindScene(e)
            drawOpaque(e, capture: true)
            e.endEncoding()
        }
        if let blit = cb.makeBlitCommandEncoder() {
            blit.generateMipmaps(for: captureColor)
            blit.endEncoding()
        }

        // 3. Main pass: everything at full resolution with MSAA, resolved straight to textures.
        let mp = MTLRenderPassDescriptor()
        if let msaaColor, let msaaDepth {
            mp.colorAttachments[0].texture = msaaColor
            mp.colorAttachments[0].resolveTexture = resolved
            mp.colorAttachments[0].storeAction = .multisampleResolve
            mp.depthAttachment.texture = msaaDepth
            mp.depthAttachment.resolveTexture = depthResolved
            mp.depthAttachment.depthResolveFilter = .min
            mp.depthAttachment.storeAction = .multisampleResolve
        } else {
            mp.colorAttachments[0].texture = resolved
            mp.colorAttachments[0].storeAction = .store
            mp.depthAttachment.texture = depthResolved
            mp.depthAttachment.storeAction = .store
        }
        mp.colorAttachments[0].loadAction = .clear
        mp.colorAttachments[0].clearColor = clear
        mp.depthAttachment.loadAction = .clear; mp.depthAttachment.clearDepth = 1
        timed(mp, 2)
        if let e = cb.makeRenderCommandEncoder(descriptor: mp) {
            e.setRenderPipelineState(pipeOpaque)
            bindScene(e)
            drawOpaque(e)

            e.setRenderPipelineState(pipeTrans)
            e.setFragmentTexture(captureColor, index: 0)
            if let a = frame.assembly {
                drawAssembly(e, a, transmissive: true)
            } else {
                for m in arrayMeshes where m.kind == .frost {
                    e.setVertexBuffer(arrayBuffer, offset: 0, index: 2)
                    draw(m, on: e, instances: count)
                }
                for var inst in cardInstances {
                    e.setVertexBytes(&inst, length: MemoryLayout<InstanceData>.stride, index: 2)
                    for m in cardMeshes where m.kind == .frost || m.kind == .ivory { draw(m, on: e) }
                }
            }
            // Printed labels
            e.setRenderPipelineState(pipeLabel)
            e.setDepthStencilState(depthNoWrite)
            e.setFragmentSamplerState(labelSampler, index: 0)
            if let a = frame.assembly {
                if let label = labelTexture(a.labelIndex) {
                    var inst = assemblyInstance("cover", a)
                    e.setVertexBytes(&inst, length: MemoryLayout<InstanceData>.stride, index: 2)
                    e.setFragmentTexture(label, index: 2)
                    draw(labelMesh, on: e, material: false)
                }
            } else {
                for (card, var inst) in zip(frame.cards, cardInstances) where card.quality > 0.001 {
                    guard let label = labelTexture(card.labelIndex) else { continue }
                    e.setVertexBytes(&inst, length: MemoryLayout<InstanceData>.stride, index: 2)
                    e.setFragmentTexture(label, index: 2)
                    draw(labelMesh, on: e, material: false)
                }
            }
            e.endEncoding()
        }

        // 4. Ambient occlusion from the resolved depth
        let ap = MTLRenderPassDescriptor()
        ap.colorAttachments[0].texture = aoTexture
        ap.colorAttachments[0].loadAction = .dontCare
        ap.colorAttachments[0].storeAction = .store
        if let e = cb.makeRenderCommandEncoder(descriptor: ap) {
            e.setRenderPipelineState(pipeAO)
            e.setFragmentBytes(&u, length: MemoryLayout<FrameUniforms>.stride, index: 1)
            e.setFragmentTexture(depthResolved, index: 1)
            e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            e.endEncoding()
        }

        // 5. Composite to the target
        let cp = MTLRenderPassDescriptor()
        cp.colorAttachments[0].texture = target
        cp.colorAttachments[0].loadAction = .dontCare
        cp.colorAttachments[0].storeAction = .store
        timed(cp, 3)
        if let e = cb.makeRenderCommandEncoder(descriptor: cp) {
            e.setRenderPipelineState(pipeComposite)
            e.setFragmentBytes(&u, length: MemoryLayout<FrameUniforms>.stride, index: 1)
            e.setFragmentTexture(resolved, index: 0)
            e.setFragmentTexture(depthResolved, index: 1)
            e.setFragmentTexture(aoTexture, index: 2)
            e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            e.endEncoding()
        }

        if let drawable { cb.present(drawable) }
        let stats = statsEnabled
        cb.addCompletedHandler { [inFlight, self] buffer in
            let ms = (buffer.gpuEndTime - buffer.gpuStartTime) * 1000
            if ms > 0 && ms < 100 { gpuLock.lock(); gpuEMA = gpuEMA * 0.9 + ms * 0.1; if stats { gpuSamples.append(ms) }; gpuLock.unlock() }
            if passTimingEnabled, let buf = timingBuffer, let data = try? buf.resolveCounterRange(0..<8) {
                data.withUnsafeBytes { raw in
                    let t = raw.bindMemory(to: UInt64.self)
                    for i in 0..<4 where t[i * 2 + 1] > t[i * 2] { passTotals[i] += Double(t[i * 2 + 1] - t[i * 2]) / 1e6 }
                    passFrames += 1
                }
            }
            inFlight.signal()
            completion?()
        }
        cb.commit()
    }

    /// One assembly part, centred on the origin and spread along the card's thickness axis.
    private func assemblyInstance(_ part: String, _ a: AssemblyDraw) -> InstanceData {
        let offset = ViewerEngine.modelOffset + SIMD3<Float>(0, 0, ViewerEngine.depth(of: part) * a.spread)
        return InstanceData(posTilt: SIMD4(offset, 0), yawQR: SIMD4(0, 1, a.clarity, a.theme))
    }

    private func drawAssembly(_ e: MTLRenderCommandEncoder, _ a: AssemblyDraw, transmissive: Bool, capture: Bool = false) {
        for (part, m) in assemblyMeshes where (m.kind == .frost || m.kind == .ivory) == transmissive {
            if capture && m.name == "Titanium_Fasteners" { continue }
            var inst = assemblyInstance(part, a)
            e.setVertexBytes(&inst, length: MemoryLayout<InstanceData>.stride, index: 2)
            draw(m, on: e)
        }
    }

    private func draw(_ mesh: GPUMesh, on e: MTLRenderCommandEncoder, instances: Int = 1, material: Bool = true) {
        e.setVertexBuffer(mesh.vertices, offset: 0, index: 0)
        if material {
            var m = mesh.material
            e.setFragmentBytes(&m, length: MemoryLayout<SurfaceMat>.stride, index: 3)
        }
        e.drawIndexedPrimitives(type: .triangle, indexCount: mesh.indexCount, indexType: .uint32,
                                indexBuffer: mesh.indices, indexBufferOffset: 0, instanceCount: instances)
    }
}
