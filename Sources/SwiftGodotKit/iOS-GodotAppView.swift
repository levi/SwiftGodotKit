//
//  GodotAppView.swift
//
//

#if os(iOS)

import OSLog
import SwiftUI
import SwiftGodot
import UIKit

public struct GodotAppView: UIViewRepresentable {
    @SwiftUI.Environment(\.godotApp) var app: GodotApp?
    var view = UIGodotAppView(frame: CGRect.zero)
    let source: String?
    let scene: String?
    let renderBudget: RenderBudget
    let frameRate: FrameRateRequest
    let onReady: ((GodotAppViewHandle) -> Void)?
    let onMessage: ((VariantDictionary) -> Void)?

    public init(
        source: String? = nil,
        scene: String? = nil,
        renderBudget: RenderBudget = .native,
        frameRate: FrameRateRequest = .free,
        onReady: ((GodotAppViewHandle) -> Void)? = nil,
        onMessage: ((VariantDictionary) -> Void)? = nil
    ) {
        self.source = source
        self.scene = scene
        self.renderBudget = renderBudget
        self.frameRate = frameRate
        self.onReady = onReady
        self.onMessage = onMessage
    }

    public func makeUIView(context: Context) -> UIGodotAppView {
        guard let app else {
            Logger.App.error("No GodotApp instance, you must pass it on the environment using \\.godotApp")
            return view
        }

        app.configureLaunch(source: source, scene: scene)
        app.start()
        view.contentScaleFactor = UIScreen.main.scale
        view.isMultipleTouchEnabled = true
        view.app = app
        view.source = source
        view.scene = scene
        view.renderBudget = renderBudget
        view.frameRate = frameRate
        view.onReady = onReady
        view.onMessage = onMessage
        view.syncCallbackRegistration()
        return view
    }

    public func updateUIView(_ uiView: UIGodotAppView, context: Context) {
        app?.configureLaunch(source: source, scene: scene)
        uiView.source = source
        uiView.scene = scene
        uiView.renderBudget = renderBudget
        uiView.frameRate = frameRate
        uiView.onReady = onReady
        uiView.onMessage = onMessage
        uiView.syncCallbackRegistration()
        uiView.startGodotInstance()
    }

}

/// WHAT THE HOST SIDE OF A FRAME COSTS, AND WHAT SHAPE IT IS DRAWING INTO.
///
/// Off unless `BASIS_FRAME_PROFILE=1` is in the environment, and it changes
/// nothing when it is on: every line here is a read. It exists because the phone
/// reported 16.2 fps mean across a ride and nothing in the log said whether the
/// time was the engine's, the layer's shape, or SwiftUI re-entering the view.
///
/// It writes to stdout with an explicit flush, which is what
/// `devicectl device process launch --console` reads. Godot's own `print` on iOS
/// does not reach that stream.
enum HostProbe {
    static let isOn: Bool = ProcessInfo.processInfo.environment["BASIS_FRAME_PROFILE"] == "1"

    static func say(_ message: String) {
        guard isOn else { return }
        print("[HostProbe] \(message)")
        fflush(stdout)
    }
}

typealias TTGodotAppView = UIGodotAppView
typealias TTGodotWindow = UIGodotWindow

public class UIGodotAppView: UIView {
    public var renderingLayer: CAMetalLayer? = nil
    private var displayLink : CADisplayLink? = nil

    // ── MEASUREMENT ONLY. See `HostProbe`; all of it is inert without the flag.
    private var probeGeometry = ""
    private var probeStartCalls: UInt64 = 0
    private var probeIterations: UInt64 = 0
    private var probeIterationSeconds: CFTimeInterval = 0
    private var probeWorstIteration: CFTimeInterval = 0
    private var probeGapSeconds: CFTimeInterval = 0
    private var probeWorstGap: CFTimeInterval = 0
    private var probeLastIterateAt: CFTimeInterval = 0
    private var probeReportedAt: CFTimeInterval = 0
    private var probeResizes: UInt64 = 0
    private var probeSurfaceBinds: UInt64 = 0

    private var embedded: DisplayServerEmbedded?
    private weak var nativeIOSViewController: UIViewController?
    private var callbackToken: UUID?
    private weak var callbackApp: GodotApp?
    private var didEmitDisplayServerNotEmbeddedWarning = false
    private var didEmitNativeIOSHostWarning = false
    private var nativeIOSRenderingStarted = false
    private var didRegisterNativeIOSViewController = false
    
    public var app: GodotApp?
    public var source: String?
    public var scene: String?
    /// See `RenderBudget`. Re-applied whenever the view lays out, so a rotation
    /// re-derives it from the new bounds rather than keeping the old drawable.
    public var renderBudget: RenderBudget = .native {
        didSet {
            guard renderBudget != oldValue, usesEmbeddedDisplayDriver else { return }
            updateRenderingLayerGeometry()
            if embedded != nil { resizeWindow() }
        }
    }
    /// See `FrameRateRequest`. Applied to the display link as soon as there is
    /// one, and again whenever it changes.
    public var frameRate: FrameRateRequest = .free {
        didSet {
            guard frameRate != oldValue else { return }
            applyFrameRate()
        }
    }
    public var onReady: ((GodotAppViewHandle) -> Void)?
    public var onMessage: ((VariantDictionary) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    private func commonInit() {
        guard usesEmbeddedDisplayDriver else {
            return
        }
        HostProbe.say(String(format: "commonInit bounds=%.1fx%.1fpt screen=%.0fx%.0fpt scale=%.2f",
                             bounds.width, bounds.height,
                             UIScreen.main.bounds.width, UIScreen.main.bounds.height,
                             UIScreen.main.scale))
        let renderingLayer = CAMetalLayer()
        let size = max(UIScreen.main.bounds.size.width, UIScreen.main.bounds.size.height)
        renderingLayer.frame.size = CGSize(width: size, height: size)
        renderingLayer.backgroundColor = UIColor.black.cgColor
        
        layer.addSublayer(renderingLayer)
        backgroundColor = .black
        self.renderingLayer = renderingLayer
        updateRenderingLayerGeometry()
    }
    
    deinit {
        stopNativeIOSRendering()
        nativeIOSViewController?.view.removeFromSuperview()
        renderingLayer?.removeFromSuperlayer()
        unregisterCallbacks()
    }
    
    public override var bounds: CGRect {
        didSet {
            if usesEmbeddedDisplayDriver {
                updateRenderingLayerGeometry()
                resizeWindow()
            } else {
                layoutNativeIOSContainer()
            }
        }
    }
    
    func resizeWindow() {
        guard usesEmbeddedDisplayDriver else { return }
        let size = pixelSize()

        if let embedded {
            probeResizes &+= 1
            HostProbe.say("resizeWindow -> \(size.x)x\(size.y) (call #\(probeResizes))")
            embedded.resizeWindow(
                size: size,
                id: Int32(DisplayServer.mainWindowId)
            )
            return
        }

        logger.error("UIGodotAppView.resizeWindow invoked with no embedded window")
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        probeGeometryChange("layoutSubviews")
        if usesEmbeddedDisplayDriver {
            updateRenderingLayerGeometry()
            if let instance = app?.instance, instance.isStarted() {
                if embedded == nil {
                    if let displayServer = DisplayServer.shared as? DisplayServerEmbedded {
                        embedded = displayServer
                    } else {
                        emitDisplayServerNotEmbeddedWarning(context: "layoutSubviews")
                    }
                }
                if embedded != nil {
                    resizeWindow()
                }
            }
            return
        }

        layoutNativeIOSContainer()
    }
    
    func startGodotInstance() {
        probeStartCalls &+= 1
        syncCallbackRegistration()
        guard let app else {
            return
        }

        if renderingLayer == nil && usesEmbeddedDisplayDriver {
            commonInit()
        }

        if !usesEmbeddedDisplayDriver {
            attachNativeIOSContainerIfNeeded()
        }

        if let instance = app.instance {
            if usesEmbeddedDisplayDriver {
                guard let renderingLayer else {
                    Logger.App.error("startGodotInstance: renderingLayer was nil")
                    return
                }
                let rendererNativeSurface = RenderingNativeSurfaceApple.create(
                    layer: UInt(bitPattern: Unmanaged.passUnretained(renderingLayer).toOpaque())
                )
                DisplayServerEmbedded.setNativeSurface(rendererNativeSurface)
                probeSurfaceBinds &+= 1
            }

            if usesEmbeddedDisplayDriver && !instance.isStarted() {
                HostProbe.say(String(
                    format: "instance.start() with bounds=%.1fx%.1fpt drawable=%.0fx%.0f",
                    bounds.width, bounds.height,
                    renderingLayer?.drawableSize.width ?? 0,
                    renderingLayer?.drawableSize.height ?? 0))
                _ = instance.start()
                app.startPending()
            }
            if displayLink == nil {
                let displayLink = CADisplayLink(target: self, selector: #selector(iterate))
                displayLink.add(to: .current, forMode: RunLoop.Mode.default)
                self.displayLink = displayLink
                applyFrameRate()
            }

            if usesEmbeddedDisplayDriver, embedded == nil {
                if let displayServer = DisplayServer.shared as? DisplayServerEmbedded {
                    embedded = displayServer
                } else {
                    emitDisplayServerNotEmbeddedWarning(context: "startGodotInstance")
                }
            }

            if usesEmbeddedDisplayDriver {
                resizeWindow()
            } else {
                syncNativeIOSRenderingState()
            }
            app.pollBridgeAndReadiness()
        } else {
            app.queueStart(self)
        }
    }

    public override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let app, app.instance != nil, let renderingLayer else { return }
        let contentsScale = renderingLayer.contentsScale
        
        var touchData: [[String : Any]] = []
        for touch in touches {
            let touchId = app.getTouchId(touch: touch)
            if touchId == -1 {
                continue
            }
            var location = touch.location(in: self)
            if !self.layer.frame.contains(location) {
                continue
            }
            location.x -= renderingLayer.frame.origin.x
            location.y -= renderingLayer.frame.origin.y
            let tapCount = touch.tapCount
            touchData.append([ "touchId": touchId, "location": location, "tapCount": tapCount ])
        }
        let windowId = Int32(DisplayServer.mainWindowId)
        for touch in touchData {
            guard let touchId = touch["touchId"] as? Int,
                  let location = touch["location"] as? CGPoint,
                  let tapCount = touch["tapCount"] as? Int,
                  let displayServer = DisplayServer.shared as? DisplayServerEmbedded
            else { continue }
            
            displayServer.touchPress (
                idx: Int32(touchId),
                x: Int32(location.x * contentsScale),
                y: Int32(location.y * contentsScale),
                pressed: true,
                doubleClick: tapCount > 1,
                window: windowId
            )
        }
    }
    
    public override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let app, app.instance != nil, let renderingLayer else { return }
        let contentsScale = renderingLayer.contentsScale
        
        var touchData: [[String : Any]] = []
        for touch in touches {
            let touchId = app.getTouchId(touch: touch)
            if touchId == -1 {
                continue
            }
            var location = touch.location(in: self)
            if !self.layer.frame.contains(location) {
                continue
            }
            location.x -= renderingLayer.frame.origin.x
            location.y -= renderingLayer.frame.origin.y
            var prevLocation = touch.previousLocation(in: self)
            if !self.layer.frame.contains(prevLocation) {
                continue
            }
            prevLocation.x -= renderingLayer.frame.origin.x
            prevLocation.y -= renderingLayer.frame.origin.y
            let alt = touch.altitudeAngle
            let azim = touch.azimuthUnitVector(in: self)
            let force = touch.force
            let maximumPossibleForce = touch.maximumPossibleForce
            touchData.append([ "touchId": touchId, "location": location, "prevLocation": prevLocation, "alt": alt, "azim": azim, "force": force, "maximumPossibleForce": maximumPossibleForce ])
        }
        
        let windowId = Int32(DisplayServer.mainWindowId)
        for touch in touchData {
            guard let touchId = touch["touchId"] as? Int,
                  let location = touch["location"] as? CGPoint,
                  let prevLocation = touch["prevLocation"] as? CGPoint,
                  let alt = touch["alt"] as? CGFloat,
                  let azim = touch["azim"] as? CGVector,
                  let force = touch["force"] as? CGFloat,
                  let maximumPossibleForce = touch["maximumPossibleForce"] as? CGFloat,
                  let displayServer = DisplayServer.shared as? DisplayServerEmbedded else { continue }
            displayServer.touchDrag(idx: Int32(touchId), prevX: Int32(prevLocation.x  * contentsScale), prevY: Int32(prevLocation.y  * contentsScale), x: Int32(location.x * contentsScale), y: Int32(location.y * contentsScale), pressure: Double(force) / Double(maximumPossibleForce), tilt: Vector2(x: Float(azim.dx) * Float(cos(alt)), y: Float(azim.dy) * cos(Float(alt))), window: windowId)
        }
    }

    public override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let app, app.instance != nil, let renderingLayer else { return }
        let contentsScale = renderingLayer.contentsScale
        
        var touchData: [[String : Any]] = []
        for touch in touches {
            let touchId = app.getTouchId(touch: touch)
            if touchId == -1 {
                continue
            }
            app.removeTouchId(id: touchId)
            var location = touch.location(in: self)
            if !self.layer.frame.contains(location) {
                continue
            }
            location.x -= renderingLayer.frame.origin.x
            location.y -= renderingLayer.frame.origin.y
            touchData.append([ "touchId": touchId, "location": location ])
        }
        
        let windowId = Int32(DisplayServer.mainWindowId)
        for touch in touchData {
            guard let touchId = touch["touchId"] as? Int,
                  let location = touch["location"] as? CGPoint,
                  let displayServer = DisplayServer.shared as? DisplayServerEmbedded else { continue }
            displayServer.touchPress (
                idx: Int32(touchId),
                x: Int32(location.x * contentsScale),
                y: Int32(location.y * contentsScale),
                pressed: false,
                doubleClick: false,
                window: windowId
            )
        }
    }
    
    public override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let app, app.instance != nil else { return }
        var touchData: [[String : Any]] = []
        for touch in touches {
            let touchId = app.getTouchId(touch: touch)
            if touchId == -1 {
                continue
            }
            app.removeTouchId(id: touchId)
            touchData.append([ "touchId": touchId ])
        }
        
        let windowId = Int32(DisplayServer.mainWindowId)
        for touch in touchData {
            guard let touchId = touch["touchId"] as? Int,
                  let displayServer = DisplayServer.shared as? DisplayServerEmbedded else { continue }
            
            displayServer.touchesCanceled(idx: Int32(touchId), window: windowId)
        }
    }
    
    public override func removeFromSuperview() {
        displayLink?.invalidate()
        displayLink = nil
        stopNativeIOSRendering()
        nativeIOSViewController?.view.removeFromSuperview()
        unregisterCallbacks()
        super.removeFromSuperview()
    }
    
    public override func didMoveToSuperview() {
        if superview == nil {
            return
        }
        HostProbe.say(String(format: "didMoveToSuperview bounds=%.1fx%.1fpt superview=%.1fx%.1fpt",
                             bounds.width, bounds.height,
                             superview?.bounds.width ?? 0, superview?.bounds.height ?? 0))
        if renderingLayer == nil && usesEmbeddedDisplayDriver {
            commonInit()
        }
        if usesEmbeddedDisplayDriver {
            updateRenderingLayerGeometry()
        } else {
            attachNativeIOSContainerIfNeeded()
            layoutNativeIOSContainer()
        }
        startGodotInstance()
    }

    @objc
    func iterate() {
        guard let app else { return }

        if usesEmbeddedDisplayDriver {
            if app.isPaused || !app.isDrawing {
                return
            }
            if let instance = app.instance, instance.isStarted() {
                guard HostProbe.isOn else {
                    _ = instance.iteration()
                    app.pollBridgeAndReadiness()
                    return
                }
                let entered = CACurrentMediaTime()
                if probeLastIterateAt > 0 {
                    let gap = entered - probeLastIterateAt
                    probeGapSeconds += gap
                    probeWorstGap = max(probeWorstGap, gap)
                }
                probeLastIterateAt = entered
                _ = instance.iteration()
                let iterated = CACurrentMediaTime()
                app.pollBridgeAndReadiness()
                let polled = CACurrentMediaTime()
                probeIterations &+= 1
                probeIterationSeconds += iterated - entered
                probeWorstIteration = max(probeWorstIteration, iterated - entered)
                probeReport(now: polled, bridge: polled - iterated)
            }
            return
        }

        syncNativeIOSRenderingState()
        app.pollBridgeAndReadiness()
    }
}

extension UIGodotAppView {
    /// One line a second while `BASIS_FRAME_PROFILE=1`, from inside the display
    /// link: how long `GodotInstance.iteration()` took, how long the bridge poll
    /// after it took, and how far apart the link's own calls landed. The gap
    /// minus the iteration is everything else on the main thread — SwiftUI,
    /// UIKit, the app's own timers.
    fileprivate func probeReport(now: CFTimeInterval, bridge: CFTimeInterval) {
        if probeReportedAt == 0 { probeReportedAt = now }
        guard now - probeReportedAt >= 1 else { return }
        let window = now - probeReportedAt
        let n = max(1, Double(probeIterations))
        HostProbe.say(String(
            format: "frame iters=%llu (%.1f/s) iter_mean=%.1fms iter_worst=%.1fms"
                + " gap_mean=%.1fms gap_worst=%.1fms bridge_last=%.2fms"
                + " starts=%llu binds=%llu resizes=%llu"
                + " layer=%.0fx%.0fpx bounds=%.0fx%.0fpt gravity=%@",
            probeIterations, Double(probeIterations) / window,
            probeIterationSeconds / n * 1000, probeWorstIteration * 1000,
            probeGapSeconds / n * 1000, probeWorstGap * 1000, bridge * 1000,
            probeStartCalls, probeSurfaceBinds, probeResizes,
            renderingLayer?.drawableSize.width ?? 0,
            renderingLayer?.drawableSize.height ?? 0,
            bounds.width, bounds.height,
            renderingLayer?.contentsGravity.rawValue ?? "-"
        ))
        probeReportedAt = now
        probeIterations = 0
        probeIterationSeconds = 0
        probeWorstIteration = 0
        probeGapSeconds = 0
        probeWorstGap = 0
    }

    /// The shape everything downstream is drawing into, said whenever it changes.
    fileprivate func probeGeometryChange(_ context: String) {
        guard HostProbe.isOn else { return }
        let layer = renderingLayer
        let line = String(
            format: "bounds=%.1fx%.1fpt scale=%.2f drawable=%.0fx%.0f layerFrame=%.0fx%.0f",
            bounds.width, bounds.height,
            layer?.contentsScale ?? 0,
            layer?.drawableSize.width ?? 0, layer?.drawableSize.height ?? 0,
            layer?.frame.width ?? 0, layer?.frame.height ?? 0
        )
        guard line != probeGeometry else { return }
        probeGeometry = line
        HostProbe.say("geometry [\(context)] \(line)")
    }
}

private extension UIGodotAppView {
    var usesEmbeddedDisplayDriver: Bool {
        app?.displayDriver == "embedded"
    }

    func updateRenderingLayerGeometry() {
        guard let renderingLayer else { return }
        renderingLayer.frame = bounds
        let screen = max(window?.screen.scale ?? contentScaleFactor, CGFloat(1))
        // The layer's `contentsScale` IS the render scale, not the screen's:
        // touches are converted to engine pixels by multiplying by it (see
        // `touchesBegan`), so the two have to be the same number or a tap lands
        // somewhere else. The drawable is then composited up to `frame` by the
        // display pipeline, which is where the saving comes from.
        let scale = renderBudget.scale(forPointSize: bounds.size, screenScale: screen)
        renderingLayer.contentsScale = scale
        renderingLayer.drawableSize = CGSize(
            width: max(CGFloat(1), bounds.size.width * scale),
            height: max(CGFloat(1), bounds.size.height * scale)
        )
        probeGeometryChange("layer")
    }

    /// Ask CoreAnimation for the cadence, rather than sleeping inside the
    /// frame. Godot's own `Engine.max_fps` throttles by delaying INSIDE
    /// `iteration()`, which here is the display link's own callback — so it
    /// would hold the main thread through the very vsync it was trying to skip.
    /// A frame-rate range hands the decision to the compositor, which is the
    /// only thing that knows when the next refresh is.
    func applyFrameRate() {
        guard let displayLink else { return }
        switch frameRate {
        case .free:
            displayLink.preferredFrameRateRange = .default
        case let .range(minimum, preferred):
            displayLink.preferredFrameRateRange = CAFrameRateRange(
                minimum: Float(minimum), maximum: Float(preferred), preferred: Float(preferred)
            )
        }
        HostProbe.say("frame rate -> \(displayLink.preferredFrameRateRange)")
    }

    func pixelSize() -> Vector2i {
        if let renderingLayer {
            return Vector2i(
                x: Int32(max(CGFloat(1), renderingLayer.drawableSize.width).rounded()),
                y: Int32(max(CGFloat(1), renderingLayer.drawableSize.height).rounded())
            )
        }
        return Vector2i(
            x: Int32(self.bounds.size.width * self.contentScaleFactor),
            y: Int32(self.bounds.size.height * self.contentScaleFactor)
        )
    }

    func attachNativeIOSContainerIfNeeded() {
        guard !usesEmbeddedDisplayDriver else { return }
        guard let controller = nativeIOSViewController ?? makeNativeIOSViewController() else { return }

        if !didRegisterNativeIOSViewController {
            registerNativeIOSViewController(controller)
            didRegisterNativeIOSViewController = true
        }

        let controllerView = controller.view!
        if controllerView.superview !== self {
            insertSubview(controllerView, at: 0)
        }

        layoutNativeIOSContainer()
    }

    func layoutNativeIOSContainer() {
        guard !usesEmbeddedDisplayDriver else { return }
        guard let controllerView = nativeIOSViewController?.view else { return }
        controllerView.frame = bounds
        controllerView.setNeedsLayout()
        controllerView.layoutIfNeeded()
    }

    func makeNativeIOSViewController() -> UIViewController? {
        guard let viewControllerType = NSClassFromString("GDTViewController") as? NSObject.Type else {
            emitNativeIOSHostWarning("GDTViewController runtime class is unavailable")
            return nil
        }

        let object = viewControllerType.init()
        guard let controller = object as? UIViewController else {
            emitNativeIOSHostWarning("GDTViewController resolved, but did not bridge to UIViewController")
            return nil
        }
        controller.loadViewIfNeeded()
        nativeIOSViewController = controller
        return controller
    }

    func registerNativeIOSViewController(_ controller: UIViewController) {
        guard let serviceClass = NSClassFromString("GDTAppDelegateService") else {
            emitNativeIOSHostWarning("GDTAppDelegateService runtime class is unavailable")
            return
        }

        let selector = NSSelectorFromString("setViewController:")
        let serviceObject: AnyObject = serviceClass
        guard serviceObject.responds(to: selector) else {
            emitNativeIOSHostWarning("GDTAppDelegateService.setViewController: is unavailable")
            return
        }

        _ = serviceObject.perform(selector, with: controller)
    }

    func syncNativeIOSRenderingState() {
        guard !usesEmbeddedDisplayDriver else { return }
        attachNativeIOSContainerIfNeeded()

        let hasDrawableBounds = bounds.width > 1 && bounds.height > 1
        if !hasDrawableBounds {
            stopNativeIOSRendering()
            return
        }

        if let app, app.isPaused || !app.isDrawing {
            stopNativeIOSRendering()
        } else {
            startNativeIOSRendering()
        }
    }

    func startNativeIOSRendering() {
        guard !nativeIOSRenderingStarted else { return }
        guard let hostView = nativeIOSViewController?.view else { return }

        let startSelector = NSSelectorFromString("startRendering")
        let hostObject: AnyObject = hostView
        guard hostObject.responds(to: startSelector) else {
            emitNativeIOSHostWarning("GDTView.startRendering is unavailable")
            return
        }

        _ = hostObject.perform(startSelector)
        nativeIOSRenderingStarted = true
    }

    func stopNativeIOSRendering() {
        guard nativeIOSRenderingStarted else { return }
        guard let hostView = nativeIOSViewController?.view else {
            nativeIOSRenderingStarted = false
            return
        }

        let stopSelector = NSSelectorFromString("stopRendering")
        let hostObject: AnyObject = hostView
        if hostObject.responds(to: stopSelector) {
            _ = hostObject.perform(stopSelector)
        }
        nativeIOSRenderingStarted = false
    }

    func emitDisplayServerNotEmbeddedWarning(context: String) {
        guard !didEmitDisplayServerNotEmbeddedWarning else { return }
        didEmitDisplayServerNotEmbeddedWarning = true
        let detail = "DisplayServer.shared is not DisplayServerEmbedded (\(context))"
        Logger.App.error("\(detail, privacy: .public)")
        app?.emitRuntimeEvent(
            .warning(
                GodotWarningEvent(
                    code: .displayServerNotEmbedded,
                    detail: detail
                )
            )
        )
    }

    func emitNativeIOSHostWarning(_ detail: String) {
        guard !didEmitNativeIOSHostWarning else { return }
        didEmitNativeIOSHostWarning = true
        Logger.App.error("\(detail, privacy: .public)")
    }

    func syncCallbackRegistration() {
        guard let app else { return }

        if callbackApp !== app {
            unregisterCallbacks()
            callbackApp = app
        }

        if callbackToken == nil {
            let token = app.registerViewCallbacks(
                handle: GodotAppViewHandle(app: app),
                onReady: { [weak self] handle in
                    self?.onReady?(handle)
                },
                onMessage: { [weak self] message in
                    self?.onMessage?(message)
                }
            )
            callbackToken = token
        }
    }

    func unregisterCallbacks() {
        callbackApp?.unregisterViewCallbacks(id: callbackToken)
        callbackToken = nil
        callbackApp = nil
    }
}

#endif
