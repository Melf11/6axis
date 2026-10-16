import AppKit
import Metal
import MetalKit
import MetalPerformanceShaders
import simd

// MARK: - GPU data layouts (must match Shaders.swift)

struct MeshVertex {
    var px, py, pz: Float
    var nx, ny, nz: Float
    var id: UInt32
}

struct LineInstance {
    var x0, y0, z0: Float
    var x1, y1, z1: Float
    var id: UInt32
    var color: UInt32
    var flags: UInt32

    static let dashed: UInt32 = 1
    static let emphasized: UInt32 = 2

    init(_ a: SIMD3<Float>, _ b: SIMD3<Float>, id: UInt32 = 0, color: UInt32 = 0, flags: UInt32 = 0) {
        x0 = a.x; y0 = a.y; z0 = a.z
        x1 = b.x; y1 = b.y; z1 = b.z
        self.id = id
        self.color = color
        self.flags = flags
    }
}

struct PointInstance {
    var x, y, z: Float
    var id: UInt32
    var color: UInt32
    var size: Float
}

struct FillVertex {
    var x, y, z: Float
    var id: UInt32
    var color: UInt32
}

struct Globals {
    var viewProj = matrix_identity_float4x4
    var eye = SIMD4<Float>.zero
    var viewport = SIMD2<Float>.zero
    var hoverId: UInt32 = 0
    var selCount: UInt32 = 0
    var lightDir = SIMD4<Float>.zero
    var pickMode: UInt32 = 0
    var orthographic: UInt32 = 0
    var shading: UInt32 = 0
    var clip: UInt32 = 0
    var hoverColor = SIMD4<Float>.zero
    var selectColor = SIMD4<Float>.zero
    var forward = SIMD4<Float>.zero
    var clipPlane = SIMD4<Float>.zero
    var sectionColor = SIMD4<Float>.zero
}

struct DrawUniforms {
    var color = SIMD4<Float>(1, 1, 1, 1)
    var width: Float = 1
    var depthBias: Float = 0
    var flags: UInt32 = 0
    var pad: UInt32 = 0
}

/// Packs a color into RGBA8 (matches unpack_unorm4x8_to_float: r in the low byte).
func packColor(_ c: SIMD4<Float>) -> UInt32 {
    let r = UInt32(max(0, min(255, c.x * 255))), g = UInt32(max(0, min(255, c.y * 255)))
    let b = UInt32(max(0, min(255, c.z * 255))), a = UInt32(max(0, min(255, c.w * 255)))
    return r | (g << 8) | (b << 16) | (a << 24)
}

enum DepthMode { case normal, readOnly, always }

// MARK: - Render scene (CPU side)

struct MeshBatch {
    var vertices: [MeshVertex]
    var indices: [UInt32]
    var color: SIMD4<Float>
    /// Translucent meshes (command previews) draw last, without depth writes, and are not pickable.
    var translucent = false
}

struct LineBatch {
    var instances: [LineInstance]
    var width: Float
    var color: SIMD4<Float> = SIMD4(0, 0, 0, 1)
    var depthBias: Float = 0.0015
    var depth: DepthMode = .readOnly
    var pickable = true
    /// Cut by the section plane (body edges; not grid, axes or sketches).
    var clipped = false
}

struct PointBatch {
    var instances: [PointInstance]
    var depthBias: Float = 0.004
    var depth: DepthMode = .readOnly
}

struct FillBatch {
    var vertices: [FillVertex]
    var depthBias: Float = 0.001
    var depth: DepthMode = .readOnly
    var pickable = true
}

struct ShadowQuad {
    var rect: SIMD4<Float>   // minX, minY, maxX, maxY
    var z: Float
    var opacity: Float
    var pad = SIMD2<Float>.zero
}

struct RenderScene {
    /// Bounding box of opaque bodies for the soft ground shadow; nil = no shadow.
    var shadowBounds: (min: SIMD3<Float>, max: SIMD3<Float>)?
    var meshes: [MeshBatch] = []
    var fills: [FillBatch] = []
    var lines: [LineBatch] = []
    var points: [PointBatch] = []
}

struct Palette {
    var backgroundTop: SIMD4<Float>
    var backgroundBottom: SIMD4<Float>
    var hover: SIMD4<Float>
    var select: SIMD4<Float>

    static func current(dark: Bool) -> Palette {
        dark
            ? Palette(backgroundTop: SIMD4(0.20, 0.215, 0.24, 1), backgroundBottom: SIMD4(0.105, 0.11, 0.125, 1),
                      hover: SIMD4(0.45, 0.70, 1.0, 1), select: SIMD4(0.20, 0.55, 1.0, 1))
            : Palette(backgroundTop: SIMD4(0.975, 0.98, 0.99, 1), backgroundBottom: SIMD4(0.82, 0.845, 0.88, 1),
                      hover: SIMD4(0.40, 0.66, 1.0, 1), select: SIMD4(0.04, 0.47, 1.0, 1))
    }
}

// MARK: - Renderer

final class Renderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    let queue: MTLCommandQueue
    static let sampleCount = 4

    private var meshPipeline: MTLRenderPipelineState!
    private var meshPickPipeline: MTLRenderPipelineState!
    private var meshCountPipeline: MTLRenderPipelineState!
    private var sectionCapPipeline: MTLRenderPipelineState!
    private var countState: MTLDepthStencilState!
    private var capState: MTLDepthStencilState!
    /// Depth and stencil share one attachment in the main pass (stencil = section capping).
    static let depthFormat = MTLPixelFormat.depth32Float_stencil8
    private var linePipeline: MTLRenderPipelineState!
    private var linePickPipeline: MTLRenderPipelineState!
    private var pointPipeline: MTLRenderPipelineState!
    private var pointPickPipeline: MTLRenderPipelineState!
    private var fillPipeline: MTLRenderPipelineState!
    private var fillPickPipeline: MTLRenderPipelineState!
    private var bgPipeline: MTLRenderPipelineState!
    private var shadowMaskPipeline: MTLRenderPipelineState!
    private var shadowPipeline: MTLRenderPipelineState!
    private var shadowTight: MTLTexture?
    private var shadowWide: MTLTexture?
    private var shadowQuad: ShadowQuad?
    private var depthStates: [DepthMode: MTLDepthStencilState] = [:]

    private struct GPUMesh { let vb: MTLBuffer; let ib: MTLBuffer; let count: Int; let color: SIMD4<Float>; let translucent: Bool }
    private struct GPUInstances { let buffer: MTLBuffer; let count: Int; var u: DrawUniforms; let depth: DepthMode; let pickable: Bool }

    private var gpuMeshes: [GPUMesh] = []
    private var gpuFills: [GPUInstances] = []
    private var gpuLines: [GPUInstances] = []
    private var gpuGridLines: [GPUInstances] = []
    private var gpuPoints: [GPUInstances] = []

    private var pickTexture: MTLTexture?
    private var pickDepth: MTLTexture?
    /// Tests: receives a copy of the next frame exactly as presented (needs framebufferOnly = false).
    var captureNextFrame: ((MTLTexture) -> Void)?
    private var frameColor: MTLTexture?
    private var frameDepth: MTLTexture?

    /// Render targets that only live inside a render pass: tile memory on Apple GPUs, no RAM at all.
    private var transientStorage: MTLStorageMode { device.supportsFamily(.apple1) ? .memoryless : .private }

    private func target(_ fmt: MTLPixelFormat, _ w: Int, _ h: Int, samples: Int, storage: MTLStorageMode) -> MTLTexture? {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: fmt, width: w, height: h, mipmapped: false)
        d.textureType = samples > 1 ? .type2DMultisample : .type2D
        d.sampleCount = samples
        d.usage = [.renderTarget]
        d.storageMode = storage
        return device.makeTexture(descriptor: d)
    }

    /// Pass that renders multisampled into transient targets and resolves into `resolve`.
    private func resolvingPass(into resolve: MTLTexture, color: MTLTexture, depth: MTLTexture) -> MTLRenderPassDescriptor {
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = color
        rpd.colorAttachments[0].resolveTexture = resolve
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].storeAction = .multisampleResolve
        rpd.depthAttachment.texture = depth
        rpd.depthAttachment.clearDepth = 1
        rpd.depthAttachment.loadAction = .clear
        rpd.depthAttachment.storeAction = .dontCare
        rpd.stencilAttachment.texture = depth
        rpd.stencilAttachment.clearStencil = 0
        rpd.stencilAttachment.loadAction = .clear
        rpd.stencilAttachment.storeAction = .dontCare
        return rpd
    }

    /// Section caps (stencil method): count the cut model's surfaces behind each pixel, then fill the cutting
    /// plane where the count is odd. The cap has real depth, so edges inside the material stay hidden.
    private func drawSectionCap(_ enc: MTLRenderCommandEncoder, _ g: inout Globals) {
        var u = DrawUniforms()
        enc.setVertexBytes(&u, length: MemoryLayout<DrawUniforms>.stride, index: 2)
        enc.setRenderPipelineState(meshCountPipeline)
        enc.setDepthStencilState(countState)
        enc.setStencilReferenceValue(0)
        for m in gpuMeshes where !m.translucent {
            enc.setVertexBuffer(m.vb, offset: 0, index: 0)
            enc.drawIndexedPrimitives(type: .triangle, indexCount: m.count, indexType: .uint32, indexBuffer: m.ib, indexBufferOffset: 0)
        }
        // A large square in the cutting plane around the point the camera looks at.
        let n: SIMD3<Float> = simd_normalize(SIMD3<Float>(g.clipPlane.x, g.clipPlane.y, g.clipPlane.z))
        let eye = SIMD3<Float>(g.eye.x, g.eye.y, g.eye.z), fwd = SIMD3<Float>(g.forward.x, g.forward.y, g.forward.z)
        let t: SIMD3<Float> = eye + fwd * 100
        let c: SIMD3<Float> = t - n * (simd_dot(t, n) - g.clipPlane.w)
        let helper = abs(n.x) < 0.9 ? SIMD3<Float>(1, 0, 0) : SIMD3<Float>(0, 1, 0)
        let a: SIMD3<Float> = simd_normalize(simd_cross(n, helper)) * 100_000
        let b: SIMD3<Float> = simd_cross(n, a)
        let corners: [SIMD3<Float>] = [c - a - b, c + a - b, c + a + b, c - a + b]
        var verts = [0, 1, 2, 0, 2, 3].map { i in
            MeshVertex(px: corners[i].x, py: corners[i].y, pz: corners[i].z, nx: -n.x, ny: -n.y, nz: -n.z, id: 0)
        }
        enc.setRenderPipelineState(sectionCapPipeline)
        enc.setDepthStencilState(capState)
        enc.setStencilReferenceValue(1)
        enc.setVertexBytes(&verts, length: MemoryLayout<MeshVertex>.stride * verts.count, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
    }

    /// Called each frame before drawing to fetch camera/highlight state and advance animations.
    var frameProvider: (() -> FrameState)?
    /// Called once per display refresh: true if something changed since the last frame.
    var needsFrame: (() -> Bool)?
    /// Camera animations keep rendering until they finish.
    private var animating = false
    /// Frames submitted but not yet on screen. Asking for a drawable while all are in use blocks the main
    /// thread (up to a second when the display sleeps), so at this limit frames are skipped instead.
    private var inFlight = 0
    private var lastSubmit: CFTimeInterval = 0
    private let maxInFlight = 2

    struct FrameState {
        var camera: Camera
        var hoverId: UInt32
        var selection: [UInt32]
        var dark: Bool
        var animating: Bool
        /// Section view: plane normal and offset (points beyond are cut away).
        var clip: SIMD4<Float>? = nil
    }

    init?(device: MTLDevice) {
        self.device = device
        guard let q = device.makeCommandQueue() else { return nil }
        queue = q
        super.init()
        do { try buildPipelines() } catch {
            NSLog("6axis: shader build failed: \(error)")
            return nil
        }
    }

    private func buildPipelines() throws {
        let lib = try device.makeLibrary(source: shaderSource, options: nil)
        func make(_ vs: String, _ fs: String, pick: Bool, blend: Bool = true, writeColor: Bool = true) throws -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = lib.makeFunction(name: vs)
            d.fragmentFunction = lib.makeFunction(name: fs)
            d.depthAttachmentPixelFormat = pick ? .depth32Float : Renderer.depthFormat
            if !pick { d.stencilAttachmentPixelFormat = Renderer.depthFormat }
            if !writeColor { d.colorAttachments[0].writeMask = [] }
            if pick {
                d.colorAttachments[0].pixelFormat = .r32Uint
                d.rasterSampleCount = 1
            } else {
                d.colorAttachments[0].pixelFormat = .bgra8Unorm
                d.rasterSampleCount = Renderer.sampleCount
                if blend {
                    let a = d.colorAttachments[0]!
                    a.isBlendingEnabled = true
                    a.sourceRGBBlendFactor = .sourceAlpha
                    a.destinationRGBBlendFactor = .oneMinusSourceAlpha
                    a.sourceAlphaBlendFactor = .one
                    a.destinationAlphaBlendFactor = .oneMinusSourceAlpha
                }
            }
            return try device.makeRenderPipelineState(descriptor: d)
        }
        meshPipeline = try make("mesh_vs", "mesh_fs", pick: false)
        meshPickPipeline = try make("mesh_vs", "mesh_pick_fs", pick: true)
        meshCountPipeline = try make("mesh_vs", "mesh_count_fs", pick: false, blend: false, writeColor: false)
        sectionCapPipeline = try make("mesh_vs", "section_cap_fs", pick: false, blend: false)
        // Counting: every surface fragment of the cut model flips the stencil bit, regardless of depth.
        let count = MTLDepthStencilDescriptor()
        count.depthCompareFunction = .always
        count.isDepthWriteEnabled = false
        let flip = MTLStencilDescriptor()
        flip.stencilCompareFunction = .always
        flip.depthStencilPassOperation = .invert
        flip.writeMask = 1
        count.frontFaceStencil = flip
        count.backFaceStencil = flip
        countState = device.makeDepthStencilState(descriptor: count)
        // Cap: where the bit is set (inside the material) and nothing is in front of the plane.
        let cap = MTLDepthStencilDescriptor()
        cap.depthCompareFunction = .less
        cap.isDepthWriteEnabled = true
        let odd = MTLStencilDescriptor()
        odd.stencilCompareFunction = .equal
        odd.readMask = 1
        odd.writeMask = 0
        cap.frontFaceStencil = odd
        cap.backFaceStencil = odd
        capState = device.makeDepthStencilState(descriptor: cap)
        linePipeline = try make("line_vs", "line_fs", pick: false)
        linePickPipeline = try make("line_vs", "line_pick_fs", pick: true)
        pointPipeline = try make("point_vs", "point_fs", pick: false)
        pointPickPipeline = try make("point_vs", "point_pick_fs", pick: true)
        fillPipeline = try make("fill_vs", "fill_fs", pick: false)
        fillPickPipeline = try make("fill_vs", "fill_pick_fs", pick: true)
        bgPipeline = try make("bg_vs", "bg_fs", pick: false, blend: false)
        shadowPipeline = try make("shadow_vs", "shadow_fs", pick: false)
        let md = MTLRenderPipelineDescriptor()
        md.vertexFunction = lib.makeFunction(name: "mesh_vs")
        md.fragmentFunction = lib.makeFunction(name: "shadow_mask_fs")
        md.colorAttachments[0].pixelFormat = .r8Unorm
        shadowMaskPipeline = try device.makeRenderPipelineState(descriptor: md)

        for mode in [DepthMode.normal, .readOnly, .always] {
            let d = MTLDepthStencilDescriptor()
            switch mode {
            case .normal: d.depthCompareFunction = .less; d.isDepthWriteEnabled = true
            case .readOnly: d.depthCompareFunction = .lessEqual; d.isDepthWriteEnabled = false
            case .always: d.depthCompareFunction = .always; d.isDepthWriteEnabled = false
            }
            depthStates[mode] = device.makeDepthStencilState(descriptor: d)
        }
    }

    // MARK: Scene upload

    /// Replaces only the grid/axes layer (camera-following, rebuilt while panning and zooming).
    func uploadGrid(_ lines: [LineBatch]) {
        gpuGridLines = lines.compactMap { l in
            guard !l.instances.isEmpty else { return nil }
            let b = l.instances.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }
            guard let b else { return nil }
            return GPUInstances(buffer: b, count: l.instances.count, u: DrawUniforms(color: l.color, width: l.width, depthBias: l.depthBias), depth: l.depth, pickable: l.pickable)
        }
    }

    func upload(_ scene: RenderScene) {
        func buffer<T>(_ a: [T]) -> MTLBuffer? {
            guard !a.isEmpty else { return nil }
            return a.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }
        }
        gpuMeshes = scene.meshes.compactMap { m in
            guard let vb = buffer(m.vertices), let ib = buffer(m.indices) else { return nil }
            return GPUMesh(vb: vb, ib: ib, count: m.indices.count, color: m.color, translucent: m.translucent)
        }
        gpuFills = scene.fills.compactMap { f in
            guard let b = buffer(f.vertices) else { return nil }
            return GPUInstances(buffer: b, count: f.vertices.count, u: DrawUniforms(depthBias: f.depthBias), depth: f.depth, pickable: f.pickable)
        }
        gpuLines = scene.lines.compactMap { l in
            guard let b = buffer(l.instances) else { return nil }
            return GPUInstances(buffer: b, count: l.instances.count,
                                u: DrawUniforms(color: l.color, width: l.width, depthBias: l.depthBias, flags: l.clipped ? 1 : 0),
                                depth: l.depth, pickable: l.pickable)
        }
        if let b = scene.shadowBounds { renderShadow(b.min, b.max) } else { shadowQuad = nil }
        gpuPoints = scene.points.compactMap { p in
            guard let b = buffer(p.instances) else { return nil }
            return GPUInstances(buffer: b, count: p.instances.count, u: DrawUniforms(depthBias: p.depthBias), depth: p.depth, pickable: true)
        }
    }

    // MARK: Ground shadow

    /// Renders the bodies' silhouette from above, blurs it twice (contact + ambient) and
    /// places it as a quad on the ground (z = 0, or below the lowest body).
    private func renderShadow(_ lo: SIMD3<Float>, _ hi: SIMD3<Float>) {
        let size = max(hi.x - lo.x, hi.y - lo.y, 1)
        let half = size / 2 + size * 0.6 + 4
        let cx = (lo.x + hi.x) / 2, cy = (lo.y + hi.y) / 2
        let res = 256
        func tex(_ usage: MTLTextureUsage) -> MTLTexture? {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: res, height: res, mipmapped: false)
            d.usage = usage
            d.storageMode = .private
            return device.makeTexture(descriptor: d)
        }
        guard let mask = tex([.renderTarget, .shaderRead]),
              let tight = shadowTight ?? tex([.shaderRead, .shaderWrite]),
              let wide = shadowWide ?? tex([.shaderRead, .shaderWrite]),
              let cmd = queue.makeCommandBuffer() else { return }
        shadowTight = tight
        shadowWide = wide

        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = mask
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        rpd.colorAttachments[0].storeAction = .store
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) else { return }
        // Orthographic top-down projection of the shadow square.
        var g = Globals()
        g.viewProj = simd_float4x4(rows: [
            SIMD4(1 / half, 0, 0, -cx / half),
            SIMD4(0, 1 / half, 0, -cy / half),
            SIMD4(0, 0, 0, 0.5),
            SIMD4(0, 0, 0, 1),
        ])
        g.eye = SIMD4(cx, cy, hi.z + 1000, 1)
        g.orthographic = 1
        g.forward = SIMD4(0, 0, -1, 0)
        var u = DrawUniforms()
        enc.setRenderPipelineState(shadowMaskPipeline)
        enc.setCullMode(.none)
        enc.setVertexBytes(&g, length: MemoryLayout<Globals>.stride, index: 1)
        enc.setVertexBytes(&u, length: MemoryLayout<DrawUniforms>.stride, index: 2)
        for m in gpuMeshes where !m.translucent {
            enc.setVertexBuffer(m.vb, offset: 0, index: 0)
            enc.drawIndexedPrimitives(type: .triangle, indexCount: m.count, indexType: .uint32, indexBuffer: m.ib, indexBufferOffset: 0)
        }
        enc.endEncoding()
        MPSImageGaussianBlur(device: device, sigma: 3).encode(commandBuffer: cmd, sourceTexture: mask, destinationTexture: tight)
        MPSImageGaussianBlur(device: device, sigma: 30).encode(commandBuffer: cmd, sourceTexture: mask, destinationTexture: wide)
        cmd.commit()

        let z = min(0, lo.z) - size * 0.0005
        shadowQuad = ShadowQuad(rect: SIMD4(cx - half, cy - half, cx + half, cy + half), z: z, opacity: 1)
    }

    // MARK: Drawing

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    private func globals(_ f: FrameState, viewportPixels: SIMD2<Float>, pick: Bool) -> Globals {
        let cam = f.camera
        let pal = Palette.current(dark: f.dark)
        var g = Globals()
        g.viewProj = cam.viewProjection
        g.eye = SIMD4(cam.eye, 1)
        g.viewport = viewportPixels
        g.hoverId = pick ? 0 : f.hoverId
        g.selCount = pick ? 0 : UInt32(min(f.selection.count, 4096))
        // Key light from upper left of the viewer.
        let l = simd_normalize(-cam.forward + cam.up * 0.8 - cam.right * 0.5)
        g.lightDir = SIMD4(l, 0)
        g.pickMode = pick ? 1 : 0
        g.orthographic = cam.orthographic ? 1 : 0
        g.shading = AppSettings.shared.shading == .simple ? 1 : 0
        g.hoverColor = pal.hover
        g.selectColor = pal.select
        g.forward = SIMD4(cam.forward, 0)
        if let c = f.clip {
            g.clip = 1
            g.clipPlane = c
            g.sectionColor = f.dark ? SIMD4(0.85, 0.42, 0.30, 1) : SIMD4(0.90, 0.48, 0.36, 1)
        }
        return g
    }

    /// Frame timing for performance checks (SIXAXIS_DRAG_TEST).
    final class Stats: @unchecked Sendable {
        let lock = NSLock()
        var frames = 0
        var cpu: [Double] = []
        var gpu: [Double] = []
        func reset() { lock.lock(); frames = 0; cpu = []; gpu = []; lock.unlock() }
    }
    let stats = Stats()

    func draw(in view: MTKView) {
        let cpuStart = CACurrentMediaTime()
        // Hidden or minimized windows get no drawables back from the compositor; asking for one would
        // block the main thread for up to a second per frame. Keep the change pending until visible.
        guard view.window?.occlusionState.contains(.visible) == true else { return }
        if inFlight >= maxInFlight {
            // Watchdog: if no presentation was reported for a second, assume the frames were dropped.
            guard cpuStart - lastSubmit > 1 else { return }
            inFlight = 0
        }
        let changed = needsFrame?() ?? true
        guard changed || animating else { return }   // idle frames cost nothing
        guard let frame = frameProvider?() else { return }
        animating = frame.animating
        let size = view.drawableSize
        let w = Int(size.width), h = Int(size.height)
        guard w > 0, h > 0 else { return }
        if frameColor?.width != w || frameColor?.height != h {
            frameColor = target(.bgra8Unorm, w, h, samples: Renderer.sampleCount, storage: transientStorage)
            frameDepth = target(Renderer.depthFormat, w, h, samples: Renderer.sampleCount, storage: transientStorage)
        }
        guard let color = frameColor, let depth = frameDepth, let drawable = view.currentDrawable,
              let cmd = queue.makeCommandBuffer(),
              let enc = cmd.makeRenderCommandEncoder(descriptor: resolvingPass(into: drawable.texture, color: color, depth: depth)) else { return }
        var g = globals(frame, viewportPixels: SIMD2(Float(size.width), Float(size.height)), pick: false)
        let pal = Palette.current(dark: frame.dark)
        var bg = [pal.backgroundTop, pal.backgroundBottom]
        var sel = frame.selection.isEmpty ? [UInt32(0)] : Array(frame.selection.prefix(4096))

        enc.setRenderPipelineState(bgPipeline)
        enc.setDepthStencilState(depthStates[.always])
        enc.setFragmentBytes(&bg, length: MemoryLayout<SIMD4<Float>>.stride * 2, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)

        encodeScene(enc, globals: &g, selection: &sel, pick: false)
        enc.endEncoding()
        inFlight += 1
        lastSubmit = cpuStart
        drawable.addPresentedHandler { [weak self] _ in
            DispatchQueue.main.async { if let self, self.inFlight > 0 { self.inFlight -= 1 } }
        }
        if let capture = captureNextFrame, !view.framebufferOnly {
            captureNextFrame = nil
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: drawable.texture.pixelFormat, width: w, height: h, mipmapped: false)
            d.storageMode = .shared
            if let copy = device.makeTexture(descriptor: d), let blit = cmd.makeBlitCommandEncoder() {
                blit.copy(from: drawable.texture, to: copy)
                blit.endEncoding()
                cmd.addCompletedHandler { _ in DispatchQueue.main.async { capture(copy) } }
            }
        }
        cmd.present(drawable)
        let stats = self.stats
        cmd.addCompletedHandler { cb in
            stats.lock.lock(); stats.gpu.append((cb.gpuEndTime - cb.gpuStartTime) * 1000); stats.lock.unlock()
        }
        cmd.commit()
        stats.lock.lock(); stats.frames += 1; stats.cpu.append((CACurrentMediaTime() - cpuStart) * 1000); stats.lock.unlock()
    }

    /// Renders the current frame offscreen (debug snapshots, thumbnails).
    func snapshot(width w: Int, height h: Int) -> CGImage? {
        guard let frame = frameProvider?(), w > 0, h > 0 else { return nil }
        guard let msaa = target(.bgra8Unorm, w, h, samples: Renderer.sampleCount, storage: transientStorage),
              let resolve = target(.bgra8Unorm, w, h, samples: 1, storage: .shared),
              let depth = target(Renderer.depthFormat, w, h, samples: Renderer.sampleCount, storage: transientStorage),
              let cmd = queue.makeCommandBuffer() else { return nil }
        let rpd = resolvingPass(into: resolve, color: msaa, depth: depth)
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) else { return nil }
        var g = globals(frame, viewportPixels: SIMD2(Float(w), Float(h)), pick: false)
        let pal = Palette.current(dark: frame.dark)
        var bg = [pal.backgroundTop, pal.backgroundBottom]
        var sel = frame.selection.isEmpty ? [UInt32(0)] : Array(frame.selection.prefix(4096))
        enc.setRenderPipelineState(bgPipeline)
        enc.setDepthStencilState(depthStates[.always])
        enc.setFragmentBytes(&bg, length: MemoryLayout<SIMD4<Float>>.stride * 2, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encodeScene(enc, globals: &g, selection: &sel, pick: false)
        enc.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        resolve.getBytes(&bytes, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info, provider: provider,
                       decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    private func encodeScene(_ enc: MTLRenderCommandEncoder, globals g: inout Globals, selection sel: inout [UInt32], pick: Bool) {
        enc.setVertexBytes(&g, length: MemoryLayout<Globals>.stride, index: 1)
        enc.setFragmentBytes(&g, length: MemoryLayout<Globals>.stride, index: 1)
        enc.setFragmentBytes(&sel, length: MemoryLayout<UInt32>.stride * sel.count, index: 3)

        enc.setCullMode(.none)
        func meshes(translucent: Bool) {
            enc.setRenderPipelineState(pick ? meshPickPipeline : meshPipeline)
            enc.setDepthStencilState(depthStates[translucent ? .readOnly : .normal])
            for m in gpuMeshes where m.translucent == translucent {
                var u = DrawUniforms(color: m.color, depthBias: 0)
                enc.setVertexBuffer(m.vb, offset: 0, index: 0)
                enc.setVertexBytes(&u, length: MemoryLayout<DrawUniforms>.stride, index: 2)
                enc.setFragmentBytes(&u, length: MemoryLayout<DrawUniforms>.stride, index: 2)
                enc.drawIndexedPrimitives(type: .triangle, indexCount: m.count, indexType: .uint32, indexBuffer: m.ib, indexBufferOffset: 0)
            }
        }
        meshes(translucent: false)
        if !pick && g.clip != 0 { drawSectionCap(enc, &g) }
        if !pick, var q = shadowQuad, let tight = shadowTight, let wide = shadowWide {
            q.opacity = 0.62
            enc.setRenderPipelineState(shadowPipeline)
            enc.setDepthStencilState(depthStates[.readOnly])
            enc.setVertexBytes(&q, length: MemoryLayout<ShadowQuad>.stride, index: 0)
            enc.setFragmentBytes(&q, length: MemoryLayout<ShadowQuad>.stride, index: 0)
            enc.setFragmentTexture(tight, index: 0)
            enc.setFragmentTexture(wide, index: 1)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        }

        func instances(_ list: [GPUInstances], pipeline: MTLRenderPipelineState, vertexCount: Int, instanced: Bool) {
            enc.setRenderPipelineState(pipeline)
            for var item in list where !pick || item.pickable {
                enc.setDepthStencilState(depthStates[item.depth])
                enc.setVertexBuffer(item.buffer, offset: 0, index: 0)
                enc.setVertexBytes(&item.u, length: MemoryLayout<DrawUniforms>.stride, index: 2)
                enc.setFragmentBytes(&item.u, length: MemoryLayout<DrawUniforms>.stride, index: 2)
                if instanced {
                    enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertexCount, instanceCount: item.count)
                } else {
                    enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: item.count)
                }
            }
        }
        instances(gpuFills, pipeline: pick ? fillPickPipeline : fillPipeline, vertexCount: 0, instanced: false)
        instances(gpuGridLines, pipeline: pick ? linePickPipeline : linePipeline, vertexCount: 6, instanced: true)
        instances(gpuLines, pipeline: pick ? linePickPipeline : linePipeline, vertexCount: 6, instanced: true)
        instances(gpuPoints, pipeline: pick ? pointPickPipeline : pointPipeline, vertexCount: 6, instanced: true)
        if !pick { meshes(translucent: true) }
    }

    // MARK: Picking

    /// Renders object ids and returns all ids within `radius` pixels of the point, nearest first.
    func pick(at pixel: CGPoint, drawableSize: CGSize, radius: Int) -> [UInt32] {
        guard let frame = frameProvider?() else { return [] }
        let w = Int(drawableSize.width), h = Int(drawableSize.height)
        guard w > 0, h > 0 else { return [] }
        if pickTexture?.width != w || pickTexture?.height != h {
            let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r32Uint, width: w, height: h, mipmapped: false)
            td.usage = [.renderTarget]
            td.storageMode = .private
            pickTexture = device.makeTexture(descriptor: td)
            pickDepth = target(.depth32Float, w, h, samples: 1, storage: transientStorage)
        }
        guard let tex = pickTexture, let depth = pickDepth else { return [] }
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = tex
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].storeAction = .store
        rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        rpd.depthAttachment.texture = depth
        rpd.depthAttachment.loadAction = .clear
        rpd.depthAttachment.clearDepth = 1
        rpd.depthAttachment.storeAction = .dontCare

        let x0 = max(0, Int(pixel.x) - radius), y0 = max(0, Int(pixel.y) - radius)
        let x1 = min(w, Int(pixel.x) + radius + 1), y1 = min(h, Int(pixel.y) + radius + 1)
        guard x1 > x0, y1 > y0, let cmd = queue.makeCommandBuffer(),
              let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) else { return [] }
        var g = globals(frame, viewportPixels: SIMD2(Float(w), Float(h)), pick: true)
        var sel: [UInt32] = [0]
        encodeScene(enc, globals: &g, selection: &sel, pick: true)
        enc.endEncoding()

        let rw = x1 - x0, rh = y1 - y0
        guard let out = device.makeBuffer(length: rw * rh * 4, options: .storageModeShared),
              let blit = cmd.makeBlitCommandEncoder() else { return [] }
        blit.copy(from: tex, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: x0, y: y0, z: 0),
                  sourceSize: MTLSize(width: rw, height: rh, depth: 1), to: out, destinationOffset: 0,
                  destinationBytesPerRow: rw * 4, destinationBytesPerImage: rw * rh * 4)
        blit.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()

        let ptr = out.contents().bindMemory(to: UInt32.self, capacity: rw * rh)
        var best: [UInt32: Int] = [:]
        for yy in 0..<rh {
            for xx in 0..<rw {
                let id = ptr[yy * rw + xx]
                guard id != 0 else { continue }
                let dx = x0 + xx - Int(pixel.x), dy = y0 + yy - Int(pixel.y)
                let d = dx * dx + dy * dy
                guard d <= radius * radius else { continue }
                if let b = best[id], b <= d { continue }
                best[id] = d
            }
        }
        return best.sorted { $0.value < $1.value }.map(\.key)
    }
}
