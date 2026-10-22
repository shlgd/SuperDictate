import AppKit
import MetalKit
import QuartzCore
import simd

struct NotchGlowColor: Codable, Equatable {
    var red: Double
    var green: Double
    var blue: Double

    init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    init(color: NSColor) {
        let rgb = color.usingColorSpace(.sRGB) ?? .black
        red = min(1, max(0, Double(rgb.redComponent)))
        green = min(1, max(0, Double(rgb.greenComponent)))
        blue = min(1, max(0, Double(rgb.blueComponent)))
    }

    var nsColor: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: 1) }
    var vector: SIMD4<Float> { SIMD4(Float(red), Float(green), Float(blue), 0) }
    var isValid: Bool { [red, green, blue].allSatisfy { $0.isFinite && (0...1).contains($0) } }
}

struct NotchGlowPalette: Codable, Equatable {
    var colors: [NotchGlowColor]

    static let standard = NotchGlowPalette(colors: [
        NotchGlowColor(red: 0.983, green: 0.392, blue: 1),
        NotchGlowColor(red: 1, green: 0.145, blue: 0.333),
        NotchGlowColor(red: 1, green: 0.40, blue: 0.06),
        NotchGlowColor(red: 0, green: 0.588, blue: 1)
    ])

    var isValid: Bool { colors.count == 4 && colors.allSatisfy(\.isValid) }
}

struct NotchHUDGeometry: Equatable {
    let frame: NSRect
    let cameraSize: NSSize

    @MainActor
    static var current: NotchHUDGeometry? {
        guard let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }),
              let left = screen.auxiliaryTopLeftArea,
              let right = screen.auxiliaryTopRightArea else { return nil }
        guard AuroraRenderer.shared != nil else { return nil }
        return make(screenFrame: screen.frame, topInset: screen.safeAreaInsets.top,
                    leftArea: left, rightArea: right)
    }

    static func make(screenFrame: NSRect, topInset: CGFloat,
                     leftArea: NSRect?, rightArea: NSRect?) -> NotchHUDGeometry? {
        guard let left = leftArea, let right = rightArea else { return nil }
        let cameraWidth = right.minX - left.maxX
        let cameraHeight = topInset
        guard cameraWidth > 0, cameraHeight > 0 else { return nil }
        let size = NSSize(width: cameraWidth + 568, height: cameraHeight + 84)
        return NotchHUDGeometry(
            frame: NSRect(x: left.maxX - 284,
                          y: screenFrame.maxY - size.height,
                          width: size.width,
                          height: size.height),
            cameraSize: NSSize(width: cameraWidth, height: cameraHeight)
        )
    }
}

private struct RecordingLiquidMotion {
    private var origin: [SIMD2<Float>]
    private var destination: [SIMD2<Float>]
    private var elapsed: Float = 0
    private var interval: Float = 1 / 0.9
    private var peak: Float = 0
    private(set) var samplesA = simd_float4x4(columns: (SIMD4(repeating: 0.5), SIMD4(repeating: 0.5), SIMD4(repeating: 0.5), SIMD4(repeating: 0.5)))
    private(set) var samplesB = simd_float4x4(columns: (SIMD4(repeating: 0.5), SIMD4(repeating: 0.5), SIMD4(repeating: 0.5), SIMD4(repeating: 0.5)))

    init() {
        origin = Self.newOutline()
        destination = Self.newOutline()
        sampleOutline()
    }

    mutating func advance(_ delta: Float, level: Float, amplitude: Float = 1) {
        peak = max(peak, level)
        elapsed += delta
        while elapsed >= interval {
            elapsed -= interval
            origin = destination
            destination = Self.newOutline()
            interval = 1 / (0.9 + 3.1 * peak)
            peak = 0
        }
        sampleOutline(amplitude: amplitude)
    }

    private static func newOutline() -> [SIMD2<Float>] {
        let sector = 2 * Float.pi / 8
        let rotation = Float.random(in: 0..<sector)
        return (0..<8).map { index in
            let radius = Float.random(in: (1 / 1.1)...1) * 0.5
            let jitter = sector * 0.1 * Float.random(in: -0.5..<0.5)
            let angle = rotation + Float(index) * sector * (1 + jitter)
            return SIMD2(sin(angle), cos(angle)) * radius
        }
    }

    private mutating func sampleOutline(amplitude: Float = 1) {
        let fraction = min(1, elapsed / interval)
        var lower: Float = 0
        var upper: Float = 1
        for _ in 0..<12 {
            let t = (lower + upper) * 0.5
            let x = 3 * (1-t) * (1-t) * t * 0.42 + 3 * (1-t) * t * t * 0.58 + t * t * t
            if x < fraction { lower = t } else { upper = t }
        }
        let t = (lower + upper) * 0.5
        let blend = t * t * (3 - 2 * t)
        let points = zip(origin, destination).map { $0 + ($1 - $0) * blend }
        let handle = (4 / Float(3)) * tan(Float.pi / 16) / sin(Float.pi / 8) * 0.5
        var curve = [SIMD2<Float>]()
        curve.reserveCapacity(64)
        for index in 0..<8 {
            let a = points[index]
            let b = points[(index+1)%8]
            let tangentA = simd_normalize(points[(index+1)%8] - points[(index+7)%8])
            let tangentB = simd_normalize(points[(index+2)%8] - points[index])
            let reach = simd_distance(a, b) * handle
            let c = a + tangentA * reach
            let d = b - tangentB * reach
            for step in 0..<8 {
                let u = Float(step) / 8
                let v = 1-u
                let start = a * (v*v*v) + c * (3*v*v*u)
                let end = d * (3*v*u*u) + b * (u*u*u)
                curve.append(start + end)
            }
        }
        var samples = [Float](repeating: 0.5, count: 32)
        for index in 0..<32 {
            let angle = Float(index) * 2 * Float.pi / 32
            let ray = SIMD2(sin(angle), cos(angle))
            for segment in 0..<curve.count {
                let a = curve[segment]
                let edge = curve[(segment+1)%curve.count] - a
                let cross = ray.x * edge.y - ray.y * edge.x
                if abs(cross) < 0.000001 { continue }
                let radius = (a.x * edge.y - a.y * edge.x) / cross
                let along = (a.x * ray.y - a.y * ray.x) / cross
                if radius > 0, along >= 0, along <= 1 {
                    samples[index] = radius
                    break
                }
            }
        }
        let mean = samples.reduce(0, +) / 32
        var broad = [Float](repeating: mean, count: 32)
        for harmonic in 1...2 {
            var cosine: Float = 0
            var sine: Float = 0
            for index in 0..<32 {
                let angle = Float(index * harmonic) * 2 * Float.pi / 32
                cosine += (samples[index] - mean) * cos(angle) / 16
                sine += (samples[index] - mean) * sin(angle) / 16
            }
            for index in 0..<32 {
                let angle = Float(index * harmonic) * 2 * Float.pi / 32
                broad[index] += cosine * cos(angle) + sine * sin(angle)
            }
        }
        samples = broad.map { mean + ($0 - mean) * 1.10 * amplitude }
        func column(_ offset: Int) -> SIMD4<Float> {
            SIMD4(samples[offset], samples[offset+1], samples[offset+2], samples[offset+3])
        }
        samplesA = simd_float4x4(columns: (column(0), column(4), column(8), column(12)))
        samplesB = simd_float4x4(columns: (column(16), column(20), column(24), column(28)))
    }
}

private struct AuroraParameters {
    var canvas: SIMD2<Float>
    var camera: SIMD2<Float>
    var timing: SIMD4<Float>
    var activity: SIMD4<Float>
    var output: SIMD4<Float> = .zero
    var entrance: SIMD4<Float> = SIMD4(0.5, 3, 2.2, 1.6)
    var paletteA: SIMD4<Float> = NotchGlowPalette.standard.colors[0].vector
    var paletteB: SIMD4<Float> = NotchGlowPalette.standard.colors[1].vector
    var paletteC: SIMD4<Float> = NotchGlowPalette.standard.colors[2].vector
    var paletteD: SIMD4<Float> = SIMD4(0, 0.588, 1, 1)
    var innerShapeA = simd_float4x4(columns: (SIMD4(repeating: 0.5), SIMD4(repeating: 0.5), SIMD4(repeating: 0.5), SIMD4(repeating: 0.5)))
    var innerShapeB = simd_float4x4(columns: (SIMD4(repeating: 0.5), SIMD4(repeating: 0.5), SIMD4(repeating: 0.5), SIMD4(repeating: 0.5)))
    var outerShapeA = simd_float4x4(columns: (SIMD4(repeating: 0.5), SIMD4(repeating: 0.5), SIMD4(repeating: 0.5), SIMD4(repeating: 0.5)))
    var outerShapeB = simd_float4x4(columns: (SIMD4(repeating: 0.5), SIMD4(repeating: 0.5), SIMD4(repeating: 0.5), SIMD4(repeating: 0.5)))
    var colorMotion = SIMD4<Float>.zero
    var layerVoice = SIMD4<Float>.zero
}

@MainActor
private final class AuroraRenderer {
    static let shared: AuroraRenderer? = {
        do { return try AuroraRenderer() }
        catch {
            NSLog("Aurora renderer unavailable: %@", error.localizedDescription)
            return nil
        }
    }()

    let device: MTLDevice
    let queue: MTLCommandQueue
    let pipeline: MTLRenderPipelineState

    private init() throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else {
            throw NSError(domain: "SuperDictate.Aurora", code: 1)
        }
        self.device = device
        self.queue = queue
        let library = try device.makeLibrary(source: AuroraShader.source, options: nil)
        let description = MTLRenderPipelineDescriptor()
        description.vertexFunction = library.makeFunction(name: "notchVertex")
        description.fragmentFunction = library.makeFunction(name: "notchAurora")
        let color = description.colorAttachments[0]!
        color.pixelFormat = .bgra8Unorm
        color.isBlendingEnabled = true
        color.sourceRGBBlendFactor = .one
        color.destinationRGBBlendFactor = .oneMinusSourceAlpha
        color.sourceAlphaBlendFactor = .one
        color.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        pipeline = try device.makeRenderPipelineState(descriptor: description)
    }

    func encode(_ parameters: AuroraParameters, pass: MTLRenderPassDescriptor,
                command: MTLCommandBuffer) -> Bool {
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return false }
        var parameters = parameters
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&parameters, length: MemoryLayout<AuroraParameters>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        return true
    }

    func snapshot(_ parameters: AuroraParameters, scale: CGFloat) -> NSBitmapImageRep? {
        let width = Int(CGFloat(parameters.canvas.x) * scale)
        let height = Int(CGFloat(parameters.canvas.y) * scale)
        guard width > 0, height > 0 else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                                  width: width, height: height,
                                                                  mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = [.renderTarget]
        guard let texture = device.makeTexture(descriptor: descriptor),
              let command = queue.makeCommandBuffer() else { return nil }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0.18, 0.18, 0.18, 1)
        var parameters = parameters
        parameters.output.x = 1
        guard encode(parameters, pass: pass, command: command) else { return nil }
        command.commit()
        command.waitUntilCompleted()
        guard command.status == .completed else { return nil }
        var pixels = Data(count: width * height * 4)
        pixels.withUnsafeMutableBytes { pointer in
            texture.getBytes(pointer.baseAddress!, bytesPerRow: width * 4,
                             from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        guard let provider = CGDataProvider(data: pixels as CFData),
              let image = CGImage(width: width, height: height,
                                  bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
                                    .union(.byteOrder32Little),
                                  provider: provider, decode: nil, shouldInterpolate: true,
                                  intent: .defaultIntent) else { return nil }
        return NSBitmapImageRep(cgImage: image)
    }
}

@MainActor
final class NotchGlowHostView: MTKView, MTKViewDelegate {
    static let arrivalRevealDuration: TimeInterval = 0.17
    static let arrivalDuration: TimeInterval = 0.56
    static let departureDuration: TimeInterval = 0.36
    var palette: NotchGlowPalette = .standard
    private(set) var isActive = false
    private var cameraSize = NSSize.zero
    private var currentMode: RecordingHUDMode = .recording
    private var targetLevel: Float = 0
    private var voice: Float = 0
    private var innerMotion = RecordingLiquidMotion()
    private var outerMotion = RecordingLiquidMotion()
    private var voiceBody: Float = 0
    private var innerVoiceResponse: Float = 0
    private var outerVoiceResponse: Float = 0
    private var voiceAccent: Float = 0
    private var processing: Float = 0
    private var processingAge: Float = -1
    private var reveal: CGFloat = 0
    private var phase: Float = 0
    private var motionPhase: Float = 0
    private var innerColorPhase: Float = 0.37
    private var entrance = SIMD4<Float>(Float(NotchGlowHostView.arrivalDuration), 3, 2.2, 1.6)
    private var burstAge: Float = -1
    private var introAge: Float = -1
    private(set) var entranceStartedAt: TimeInterval = 0
    private var entrancePresentedAt: TimeInterval?
    private(set) var entranceFirstPresented: TimeInterval?
    private(set) var entranceFirstFrameAge: TimeInterval?
    private(set) var entranceOpenedPresented: TimeInterval?
    private(set) var entranceCompletePresented: TimeInterval?
    private var outroAge: Float = -1
    private var reducedMotion = false
    private var startFrameCallback: (() -> Void)?
    private var immediateStartFrameCallback: (@Sendable (TimeInterval) -> Void)?
    private var startFrameToken: UInt64 = 0
    private var startFramePending = false

    func whenStartFrameIsPresented(_ callback: @escaping () -> Void) {
        startFrameToken &+= 1
        startFramePending = false
        startFrameCallback = callback
        immediateStartFrameCallback = nil
    }

    func whenStartFrameIsPresented(immediate: @escaping @Sendable (TimeInterval) -> Void,
                                   _ callback: @escaping () -> Void) {
        whenStartFrameIsPresented(callback)
        immediateStartFrameCallback = immediate
    }

    func cancelStartFrameCallback() {
        startFrameToken &+= 1
        startFramePending = false
        startFrameCallback = nil
        immediateStartFrameCallback = nil
    }
    private let renderer: AuroraRenderer?
    private let backdropView = NSVisualEffectView()
    private let backdropMaskLayer = CALayer()
    private var backdropMaskSize = NSSize.zero
    private var backdropTexture: MTLTexture?
    private var pendingDrawable: CAMetalDrawable?
    private var backdropPending = false
    private var backdropGeneration = 0
    var backdropGeometryDescription: String {
        "host=\(frame) backdrop=\(backdropView.frame) mask=\(backdropMaskSize) maskFrame=\(backdropMaskLayer.frame) bounds=\(bounds.size)"
    }
    var backdropIsAligned: Bool {
        guard let parent = superview else { return false }
        return backdropView.frame.equalTo(convert(backdropRegion, to: parent))
            && backdropMaskSize == backdropRegion.size
            && backdropMaskLayer.frame.equalTo(backdropView.bounds)
            && backdropView.maskImage == nil
    }
    private(set) var backdropUpdates = 0
    var backdropFramesSynchronized: Bool { backdropUpdates == renderedFrames }
    private(set) var renderedFrames = 0

    override var isFlipped: Bool { true }

    init() {
        renderer = AuroraRenderer.shared
        super.init(frame: .zero, device: renderer?.device)
        colorPixelFormat = .bgra8Unorm
        clearColor = MTLClearColorMake(0, 0, 0, 0)
        framebufferOnly = true
        isPaused = true
        enableSetNeedsDisplay = false
        autoResizeDrawable = true
        preferredFramesPerSecond = 120
        layer?.isOpaque = false
        layer?.backgroundColor = NSColor.clear.cgColor
        (layer as? CAMetalLayer)?.presentsWithTransaction = true
        delegate = self
        setAccessibilityElement(true)
        backdropView.material = .underWindowBackground
        backdropView.blendingMode = .behindWindow
        backdropView.state = .active
        backdropView.wantsLayer = true
        backdropView.alphaValue = 0
        backdropView.autoresizingMask = []
        backdropView.layer?.masksToBounds = true
        backdropView.maskImage = nil
        backdropMaskLayer.anchorPoint = .zero
        backdropMaskLayer.position = .zero
        backdropMaskLayer.contentsGravity = .resize
        backdropMaskLayer.contentsScale = 1
        backdropMaskLayer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        backdropView.layer?.mask = backdropMaskLayer
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        backdropView.removeFromSuperview()
        guard let parent = superview else { return }
        parent.addSubview(backdropView, positioned: .below, relativeTo: self)
        positionBackdrop()
    }

    override func layout() {
        super.layout()
        positionBackdrop()
    }

    private var backdropRegion: NSRect {
        NSRect(x: floor((bounds.width-cameraSize.width)*0.5-48), y: 0,
               width: ceil(cameraSize.width+96), height: ceil(cameraSize.height+58)).intersection(bounds)
    }

    private func positionBackdrop() {
        guard let parent = superview else { return }
        backdropView.frame = convert(backdropRegion, to: parent)
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError() }

    func update(geometry: NotchHUDGeometry, mode: RecordingHUDMode,
                level: Float, reveal: CGFloat) {
        let active = reveal > 0 && window?.isVisible == true && renderer != nil
        if active, !isActive {
            backdropGeneration += 1
            backdropView.alphaValue = 0
            prepareVoiceForAppearance()
            voiceAccent = 0
            processing = 0
            processingAge = -1
            varyEntrance()
            burstAge = 0
            introAge = 0
            entranceStartedAt = ProcessInfo.processInfo.systemUptime
            entrancePresentedAt = nil
            entranceFirstPresented = nil
            entranceFirstFrameAge = nil
            entranceOpenedPresented = nil
            entranceCompletePresented = nil
            outroAge = -1
        } else if active, reveal > self.reveal, outroAge >= 0 {
            backdropGeneration += 1
            backdropView.alphaValue = 0
            prepareVoiceForAppearance()
            introAge = 0
            entranceStartedAt = ProcessInfo.processInfo.systemUptime
            entrancePresentedAt = nil
            entranceFirstPresented = nil
            entranceFirstFrameAge = nil
            entranceOpenedPresented = nil
            entranceCompletePresented = nil
            outroAge = -1
        }
        if reveal < self.reveal, active, outroAge < 0 { outroAge = 0 }
        if mode == .transcribing, currentMode != .transcribing {
            processingAge = 0
        }
        if mode != .transcribing { processingAge = -1 }
        cameraSize = geometry.cameraSize
        currentMode = mode
        targetLevel = level.isFinite ? max(0, min(1, level)) : 0
        self.reveal = max(0, min(1, reveal))
        reducedMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        isActive = active
        if !active {
            cancelStartFrameCallback()
            backdropGeneration += 1
            backdropView.alphaValue = 0
        }
        switch mode {
        case .recording: setAccessibilityLabel("Recording")
        case .transcribing: setAccessibilityLabel("Transcribing")
        case .error: setAccessibilityLabel("Error")
        }
    }

    private func prepareVoiceForAppearance() {
        voice = 0
        voiceBody = 0
        innerVoiceResponse = 0
        outerVoiceResponse = 0
    }

    private func varyEntrance() {
        phase = Float.random(in: 0..<120)
        innerColorPhase = (phase * 0.085 + Float.random(in: 0.18...0.82)).truncatingRemainder(dividingBy: 1)
        motionPhase = Float.random(in: 0..<80)
        entrance = SIMD4(Float(Self.arrivalDuration),
                         Float.random(in: 2.6...3.5),
                         Float.random(in: 1.9...2.5),
                         Float.random(in: 1.45...1.8))
    }

    func advance(deltaTime: TimeInterval) {
        guard isActive else { return }
        step(deltaTime: deltaTime)
        if introAge >= 0, outroAge < 0 {
            introAge = Float(max(1.0/120, ProcessInfo.processInfo.systemUptime - entranceStartedAt))
        }
        draw()
    }

    private func step(deltaTime: TimeInterval) {
        let dt = Float(max(0, min(0.05, deltaTime)))
        if outroAge < 0 {
            let target: Float = currentMode == .recording ? min(1, max(0, targetLevel)) : 0
            if currentMode != .transcribing {
                voice += (target - voice) * (1 - pow(0.9, dt * 60))
                voiceBody = voice
                let innerResponseTime: Float = target > innerVoiceResponse ? 0.075 : 0.14
                let outerResponseTime: Float = target > outerVoiceResponse ? 0.14 : 0.23
                innerVoiceResponse += (target-innerVoiceResponse) * (1-exp(-dt/innerResponseTime))
                outerVoiceResponse += (target-outerVoiceResponse) * (1-exp(-dt/outerResponseTime))
            }
            voiceAccent = 0
            let innerDrive = (1-exp(-2.2*innerVoiceResponse))/(1-exp(Float(-2.2)))
            let outerDrive = (1-exp(-2.2*outerVoiceResponse))/(1-exp(Float(-2.2)))
            let continuesVoiceMotion = currentMode == .recording || currentMode == .transcribing
            let innerMorphLevel: Float = continuesVoiceMotion ? innerDrive : 0.3
            let outerMorphLevel: Float = continuesVoiceMotion ? outerDrive : 0.3
            if !reducedMotion {
                let innerTempo: Float = 0.86 + 0.07 * sin(motionPhase * 0.17 + 1.2)
                let outerTempo: Float = 1.08 + 0.05 * sin(motionPhase * 0.13)
                innerMotion.advance(dt * innerTempo, level: innerMorphLevel,
                                    amplitude: continuesVoiceMotion ? 1+0.45*innerDrive : 1)
                outerMotion.advance(dt * outerTempo, level: outerMorphLevel,
                                    amplitude: continuesVoiceMotion ? 1+0.25*outerDrive : 1)
            }
            let busy: Float = currentMode == .transcribing ? 1 : 0
            processing += (busy - processing) * (1 - exp(-dt / 0.035))
            if processingAge >= 0 { processingAge += dt }
        }
        phase += dt * (1 + voiceBody * 1.6)
        let innerColorRate: Float = 0.077 + 0.011 * sin(motionPhase * 0.21 + 1.3)
        innerColorPhase = (innerColorPhase + dt * innerColorRate * (1 + voiceBody * 1.45)).truncatingRemainder(dividingBy: 1)
        motionPhase += dt * (0.72 + voiceBody * 1.0 + voiceAccent * 0.25)
        if outroAge >= 0 { outroAge += dt }
        if burstAge >= 0 { burstAge += dt }
        if introAge >= 0, outroAge < 0 { introAge += dt }
    }

    private var parameters: AuroraParameters {
        let colors = (palette.isValid ? palette : .standard).colors
        return AuroraParameters(canvas: SIMD2(Float(bounds.width), Float(bounds.height)),
                         camera: SIMD2(Float(cameraSize.width), Float(cameraSize.height)),
                         timing: SIMD4(phase, burstAge, introAge, outroAge),
                         activity: SIMD4(voiceBody, processing, reducedMotion ? 1 : 0,
                                         currentMode == .error ? 1 : 0),
                         output: SIMD4(0, motionPhase, voiceAccent, processingAge),
                         entrance: entrance,
                         paletteA: colors[0].vector, paletteB: colors[1].vector,
                         paletteC: colors[2].vector,
                         paletteD: SIMD4(Float(colors[3].red), Float(colors[3].green),
                                         Float(colors[3].blue), palette == .standard ? 1 : 0),
                         innerShapeA: innerMotion.samplesA, innerShapeB: innerMotion.samplesB,
                         outerShapeA: outerMotion.samplesA, outerShapeB: outerMotion.samplesB,
                         colorMotion: SIMD4(innerColorPhase, 0, 0, 0),
                         layerVoice: SIMD4(innerVoiceResponse, outerVoiceResponse, 0, 1))
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard isActive, !backdropPending, let renderer,
              let drawable = currentDrawable,
              let pass = currentRenderPassDescriptor,
              let command = renderer.queue.makeCommandBuffer() else { return }
        let frame = parameters
        guard renderer.encode(frame, pass: pass, command: command),
              encodeBackdrop(frame, command: command) else { return }
        backdropPending = true
        pendingDrawable = drawable
        let generation = backdropGeneration
        command.addCompletedHandler { [weak self] command in
            let completed = command.status == .completed
            DispatchQueue.main.async {
                guard let self else { return }
                defer {
                    self.backdropPending = false
                    self.pendingDrawable = nil
                }
                guard completed, self.isActive, self.backdropGeneration == generation,
                      let texture = self.backdropTexture,
                      let drawable = self.pendingDrawable else { return }
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                if self.updateBackdropMask(texture) {
                    if self.currentMode == .recording, frame.timing.z >= 0,
                       frame.timing.w < 0, self.startFrameCallback != nil, !self.startFramePending {
                        self.startFramePending = true
                        let token = self.startFrameToken
                        let immediate = self.immediateStartFrameCallback
                        drawable.addPresentedHandler { [weak self] drawable in
                            let didPresent = drawable.presentedTime > 0
                            if didPresent { immediate?(drawable.presentedTime) }
                            DispatchQueue.main.async {
                                guard let self, self.isActive,
                                      self.startFrameToken == token else { return }
                                self.startFramePending = false
                                guard didPresent else { return }
                                let callback = self.startFrameCallback
                                self.startFrameCallback = nil
                                callback?()
                            }
                        }
                    }
                    if self.entranceCompletePresented == nil, frame.timing.w < 0 {
                        let origin = self.entranceStartedAt
                        drawable.addPresentedHandler { [weak self] drawable in
                            let presentedAt = drawable.presentedTime
                            DispatchQueue.main.async {
                                guard let self, self.entranceStartedAt == origin,
                                      self.isActive, presentedAt >= origin else { return }
                                let elapsed = presentedAt - origin
                                if self.entranceFirstPresented == nil {
                                    if self.outroAge < 0 { self.entrancePresentedAt = presentedAt }
                                    self.entranceFirstPresented = elapsed
                                    self.entranceFirstFrameAge = TimeInterval(frame.timing.z)
                                    log(String(format: "notch entrance: first presented=%.1f ms shader_age=%.1f ms",
                                               elapsed * 1000, frame.timing.z * 1000))
                                }
                                if frame.timing.z >= Float(Self.arrivalRevealDuration), self.entranceOpenedPresented == nil {
                                    self.entranceOpenedPresented = elapsed
                                    log(String(format: "notch entrance: opened presented=%.1f ms shader_age=%.1f ms",
                                               elapsed * 1000, frame.timing.z * 1000))
                                }
                                if frame.timing.z >= Float(Self.arrivalDuration), self.entranceCompletePresented == nil {
                                    self.entranceCompletePresented = elapsed
                                    log(String(format: "notch entrance: complete presented=%.1f ms shader_age=%.1f ms",
                                               elapsed * 1000, frame.timing.z * 1000))
                                }
                            }
                        }
                    }
                    drawable.present()
                    self.renderedFrames += 1
                }
                CATransaction.commit()
            }
        }
        command.commit()
    }

    private func encodeBackdrop(_ frame: AuroraParameters, command: MTLCommandBuffer) -> Bool {
        guard let renderer, isActive else { return false }
        let width = Int(ceil(bounds.width))
        let height = Int(ceil(bounds.height))
        guard width > 0, height > 0 else { return false }
        if backdropTexture?.width != width || backdropTexture?.height != height {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                                      width: width, height: height,
                                                                      mipmapped: false)
            descriptor.storageMode = .shared
            descriptor.usage = [.renderTarget]
            backdropTexture = renderer.device.makeTexture(descriptor: descriptor)
        }
        guard let texture = backdropTexture else { return false }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        var mask = frame
        mask.output.x = 2
        return renderer.encode(mask, pass: pass, command: command)
    }

    private func updateBackdropMask(_ texture: MTLTexture) -> Bool {
        let width = texture.width
        let height = texture.height
        var pixels = Data(count: width * height * 4)
        pixels.withUnsafeMutableBytes { pointer in
            texture.getBytes(pointer.baseAddress!, bytesPerRow: width * 4,
                             from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        guard let provider = CGDataProvider(data: pixels as CFData),
              let image = CGImage(width: width, height: height,
                                  bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
                                    .union(.byteOrder32Little),
                                  provider: provider, decode: nil, shouldInterpolate: true,
                                  intent: .defaultIntent) else { return false }
        let region = backdropRegion
        guard !region.isEmpty, let croppedImage = image.cropping(to: region) else { return false }
        positionBackdrop()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backdropMaskLayer.frame = backdropView.bounds
        backdropMaskLayer.contents = croppedImage
        backdropMaskSize = region.size
        CATransaction.commit()
        backdropView.alphaValue = 1
        backdropUpdates += 1
        return true
    }

    func preview(geometry: NotchHUDGeometry, mode: RecordingHUDMode,
                 level: Float, reveal: CGFloat = 1, time: TimeInterval = 1,
                 colorPhase: Float = 0, appearance: SIMD4<Float> = SIMD4(Float(NotchGlowHostView.arrivalDuration), 3, 2.2, 1.6)) {
        update(geometry: geometry, mode: mode, level: level, reveal: reveal)
        prepareVoiceForAppearance()
        phase = colorPhase
        innerColorPhase = (colorPhase * 0.085 + 0.37).truncatingRemainder(dividingBy: 1)
        motionPhase = colorPhase * 0.73
        entrance = appearance
        processingAge = mode == .transcribing ? 0 : -1
        burstAge = 0
        introAge = 0
        outroAge = -1
        for _ in 0..<Int(time * 120) { step(deltaTime: 1.0 / 120) }
        if reveal < 1 { outroAge = Float(1 - reveal) * Float(Self.departureDuration) }
    }

    func advancePreview(deltaTime: TimeInterval, level: Float) {
        targetLevel = level
        step(deltaTime: deltaTime)
    }

    func snapshot(scale: CGFloat = 3) -> NSBitmapImageRep? {
        renderer?.snapshot(parameters, scale: scale)
    }
}

@MainActor
func exportNotchGlowPreview(to directory: URL) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let geometry = NotchHUDGeometry.current ?? NotchHUDGeometry(
        frame: NSRect(x: 0, y: 0, width: 748, height: 116),
        cameraSize: NSSize(width: 180, height: 32))
    let examples: [(String, RecordingHUDMode, Float, TimeInterval, CGFloat)] = [
        ("01-recording-quiet", .recording, 0, 1, 1),
        ("02-recording-voice", .recording, 0.9, 1, 1),
        ("03-transcribing", .transcribing, 0, 1, 1),
        ("04-error", .error, 0, 1, 1),
        ("05-appearing", .recording, 0, 0.12, 1),
        ("06-recording-idle-4s", .recording, 0, 4, 1),
        ("07-recording-idle-5s", .recording, 0, 5, 1),
        ("08-recording-voice-4s", .recording, 0.9, 4, 1),
        ("09-burst-before", .recording, 0, 3.49, 1),
        ("10-burst-after", .recording, 0, 3.51, 1),
        ("11-exit-middle", .recording, 0, 4, 0.5),
        ("12-exit-tail", .recording, 0, 4, 0.1),
        ("13-exit-finished", .recording, 0, 4, 0),
        ("14-entrance-start", .recording, 0, 0.04, 1),
        ("15-entrance-middle", .recording, 0, 0.24, 1),
        ("16-entrance-complete", .recording, 0, 0.5, 1),
        ("26-entrance-voice-early", .recording, 0.9, 0.08, 1),
        ("27-entrance-voice-growing", .recording, 0.9, 0.18, 1),
        ("28-entrance-voice-settling", .recording, 0.9, 0.36, 1),
        ("29-entrance-voice-ready", .recording, 0.9, 0.60, 1),
        ("20-exit-release", .recording, 0.9, 4, 0.8),
        ("21-exit-retreat", .recording, 0.9, 4, 0.5),
        ("22-exit-last-glow", .recording, 0.9, 4, 0.25),
        ("23-processing-200ms", .transcribing, 0, 0.2, 1),
        ("24-processing-5s", .transcribing, 0, 5, 1),
        ("25-processing-5-3s", .transcribing, 0, 5.3, 1)
    ]
    for (name, mode, level, age, reveal) in examples {
        let view = NotchGlowHostView()
        view.frame = NSRect(origin: .zero, size: geometry.frame.size)
        view.preview(geometry: geometry, mode: mode, level: level, reveal: reveal, time: age)
        guard let png = view.snapshot()?.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "SuperDictate.NotchPreview", code: 1)
        }
        try png.write(to: directory.appendingPathComponent(name + ".png"), options: .atomic)
    }
    let departureRoot = directory.appendingPathComponent("departure-sequence", isDirectory: true)
    try FileManager.default.createDirectory(at: departureRoot, withIntermediateDirectories: true)
    for frame in 0...22 {
        let view = NotchGlowHostView()
        view.frame = NSRect(origin: .zero, size: geometry.frame.size)
        view.preview(geometry: geometry, mode: .transcribing, level: 0, reveal: max(0, 1-CGFloat(frame)/21.6), time: 2, colorPhase: 7)
        guard let png = view.snapshot(scale: 2)?.representation(using: .png, properties: [:]) else {
            throw localSpeechError("Departure preview could not render")
        }
        try png.write(to: departureRoot.appendingPathComponent(String(format: "%03d.png", frame)), options: .atomic)
    }
    let sequenceRoot = directory.appendingPathComponent("entrance-sequences", isDirectory: true)
    try FileManager.default.createDirectory(at: sequenceRoot, withIntermediateDirectories: true)
    let sequences: [(String, TimeInterval, Float)] = [
        ("quiet", .infinity, 0),
        ("immediate-voice", 0, 0.75),
        ("delayed-voice", 0.35, 0.75),
        ("delayed-normal-voice", 0.35, 0.35)
    ]
    for (name, onset, level) in sequences {
        let folder = sequenceRoot.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let view = NotchGlowHostView()
        view.frame = NSRect(origin: .zero, size: geometry.frame.size)
        view.preview(geometry: geometry, mode: .recording, level: 0, time: 0, colorPhase: 7)
        for frame in 0...60 {
            let age = Double(frame) / 60
            if frame > 0 {
                for half in 0..<2 {
                    let sampleAge = age-Double(1-half)/120
                    view.advancePreview(deltaTime: 1.0/120, level: sampleAge >= onset ? level : 0)
                }
            }
            guard let png = view.snapshot(scale: 2)?.representation(using: .png, properties: [:]) else {
                throw NSError(domain: "SuperDictate.NotchSequence", code: 1)
            }
            try png.write(to: folder.appendingPathComponent(String(format: "%03d.png", frame)), options: .atomic)
        }
    }
    let entrances: [(String, Float, SIMD4<Float>)] = [
        ("17-entrance-flow", 7, SIMD4(0.54, 2.6, 1.9, 1.8)),
        ("18-entrance-spark", 41, SIMD4(0.44, 3.5, 2.5, 1.45)),
        ("19-entrance-glide", 93, SIMD4(0.5, 3.1, 2.15, 1.65))
    ]
    for (name, phase, appearance) in entrances {
        let view = NotchGlowHostView()
        view.frame = NSRect(origin: .zero, size: geometry.frame.size)
        view.preview(geometry: geometry, mode: .recording, level: 0, time: 0.12,
                     colorPhase: phase, appearance: appearance)
        guard let png = view.snapshot()?.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "SuperDictate.NotchPreview", code: 1)
        }
        try png.write(to: directory.appendingPathComponent(name + ".png"), options: .atomic)
    }
    for (name, mode) in [("recording", RecordingHUDMode.recording), ("processing", RecordingHUDMode.transcribing)] {
        let folder = directory.appendingPathComponent("haze-"+name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let view = NotchGlowHostView()
        view.frame = NSRect(origin: .zero, size: geometry.frame.size)
        view.preview(geometry: geometry, mode: mode, level: 0.65, time: 1, colorPhase: 7)
        for frame in 0...120 {
            if frame > 0 { view.advancePreview(deltaTime: 1.0/30, level: mode == .recording ? 0.65 : 0) }
            guard let png = view.snapshot(scale: 2)?.representation(using: .png, properties: [:]) else {
                throw localSpeechError("Haze sequence could not render")
            }
            try png.write(to: folder.appendingPathComponent(String(format: "%03d.png", frame)), options: .atomic)
        }
    }
    for sample in 0..<12 {
        let view = NotchGlowHostView()
        view.frame = NSRect(origin: .zero, size: geometry.frame.size)
        view.preview(geometry: geometry, mode: .recording, level: sample % 2 == 0 ? 0.12 : 0.65, time: 1, colorPhase: Float(sample / 2 * 8))
        guard let png = view.snapshot(scale: 2)?.representation(using: .png, properties: [:]) else {
            throw localSpeechError("Crossing sample could not render")
        }
        try png.write(to: directory.appendingPathComponent(String(format: "crossing-%02d.png", sample)), options: .atomic)
    }
    print("AURORA_PREVIEW camera=\(geometry.cameraSize.width)x\(geometry.cameraSize.height) points")
}

#if DEBUG
extension NotchGlowHostView {
    static func testStartupVoice(geometry: NotchHUDGeometry) throws {
        let view = NotchGlowHostView()
        view.frame = NSRect(origin: .zero, size: geometry.frame.size)
        view.preview(geometry: geometry, mode: .recording, level: 0, time: 0)
        func levels() -> [Float] {
            [view.parameters.activity.x, view.parameters.layerVoice.x, view.parameters.layerVoice.y]
        }
        guard levels().allSatisfy({ $0 == 0 }) else {
            throw localSpeechError("Notch entrance began with a synthetic microphone signal")
        }
        for _ in 0..<360 {
            view.advancePreview(deltaTime: 1.0/120, level: 0)
            guard levels().allSatisfy({ $0 == 0 }) else {
                throw localSpeechError("Notch entrance generated voice while the microphone was silent")
            }
        }
        view.preview(geometry: geometry, mode: .recording, level: 0, time: 0)
        view.advancePreview(deltaTime: 1.0/120, level: 0.35)
        guard levels().allSatisfy({ $0 > 0 && $0 < 0.10 }) else {
            throw localSpeechError("Notch entrance delayed the first microphone sample")
        }
        for _ in 0..<36 { view.advancePreview(deltaTime: 1.0/120, level: 0.35) }
        guard levels().allSatisfy({ $0 > 0.26 && $0 <= 0.35 }), view.voiceBody > 0.26 else {
            throw localSpeechError("Notch did not follow the microphone throughout its entrance")
        }
        for _ in 0..<120 {
            view.advancePreview(deltaTime: 1.0/120, level: 0.35)
        }
        for _ in 0..<180 { view.advancePreview(deltaTime: 1.0/120, level: 0) }
        guard levels().allSatisfy({ $0 < 0.01 }) else {
            throw localSpeechError("Notch startup strength overrode silence after speech")
        }
        for _ in 0..<60 { view.advancePreview(deltaTime: 1.0/120, level: 0.9) }
        guard levels().allSatisfy({ $0 > 0.8 }) else {
            throw localSpeechError("Notch startup handoff limited real voice response")
        }
        view.preview(geometry: geometry, mode: .recording, level: 0, time: 0.35)
        let ageBeforeAudio = view.introAge
        for _ in 0..<36 { view.advancePreview(deltaTime: 1.0/120, level: 0.35) }
        guard view.introAge > ageBeforeAudio + 0.29,
              levels().allSatisfy({ $0 > 0.26 }) else {
            throw localSpeechError("Late microphone input restarted or stalled the entrance")
        }
        print("NOTCH_STARTUP_VOICE syntheticAudio=false silentStart=quiet immediateAudio=responsive lateAudio=continuous")
    }
}

@MainActor
private final class NotchBackdropPatternView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill()
        bounds.fill()
        for index in stride(from: 0, to: Int(bounds.width), by: 6) {
            (index % 12 == 0 ? NSColor.systemPink : NSColor.systemBlue).setFill()
            NSRect(x: CGFloat(index), y: 0, width: 2, height: bounds.height).fill()
        }
        let text = "BACKGROUND 0123456789 BACKGROUND"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 22, weight: .bold),
            .foregroundColor: NSColor.black
        ]
        for y in stride(from: 8, to: Int(bounds.height), by: 32) {
            text.draw(at: NSPoint(x: bounds.midX - 230, y: CGFloat(y)), withAttributes: attributes)
        }
    }
}

@MainActor
func makeNotchBackdropTestWindow() -> NSWindow? {
    guard ProcessInfo.processInfo.environment["SUPERDICTATE_GLASS_PREVIEW"] == "1",
          let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) else { return nil }
    let window = NSWindow(contentRect: NSRect(x: screen.frame.midX - 380,
                                              y: screen.frame.maxY - 210,
                                              width: 760, height: 210),
                          styleMask: .borderless, backing: .buffered, defer: false)
    window.title = "SuperDictate blur diagnostic"
    window.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue - 1)
    window.isReleasedWhenClosed = false
    window.contentView = NotchBackdropPatternView(frame: NSRect(x: 0, y: 0, width: 760, height: 210))
    window.orderFrontRegardless()
    return window
}
#endif
