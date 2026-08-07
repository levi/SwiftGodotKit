//
//  MacOS/GodotAppView.swift
//
//

import OSLog
import SwiftUI
import SwiftGodot
#if os(macOS)
public struct GodotAppView: NSViewRepresentable {
    @SwiftUI.Environment(\.godotApp) var app: GodotApp?
    var view = NSGodotAppView(frame: CGRect.zero)
    let source: String?
    let scene: String?
    let onReady: ((GodotAppViewHandle) -> Void)?
    let onMessage: ((VariantDictionary) -> Void)?

    public init(
        source: String? = nil,
        scene: String? = nil,
        onReady: ((GodotAppViewHandle) -> Void)? = nil,
        onMessage: ((VariantDictionary) -> Void)? = nil
    ) {
        self.source = source
        self.scene = scene
        self.onReady = onReady
        self.onMessage = onMessage
    }

    public func makeNSView(context: Context) -> NSGodotAppView {
        guard let app else {
            Logger.App.error("No GodotApp instance, you must pass it on the environment using \\.godotApp")
            return view
        }
        app.configureLaunch(source: source, scene: scene)
        view.app = app
        view.source = source
        view.scene = scene
        view.onReady = onReady
        view.onMessage = onMessage
        view.syncCallbackRegistration()
        return view
    }

    public func updateNSView(_ nsView: NSGodotAppView, context: Context) {
        app?.configureLaunch(source: source, scene: scene)
        nsView.source = source
        nsView.scene = scene
        nsView.onReady = onReady
        nsView.onMessage = onMessage
        nsView.syncCallbackRegistration()
        nsView.startGodotInstance()
    }
}

typealias TTGodotAppView = NSGodotAppView
typealias TTGodotWindow = NSGodotWindow

public class NSGodotAppView: GodotView {
    /// THE FRAME LOOP, AND WHY IT IS TWO THINGS.
    ///
    /// `instance.iteration()` is the entire game clock — physics, the workout
    /// timer, the bridge. On macOS this view is its only caller, so whatever
    /// stops calling it stops the ride. Two separate mechanisms used to do
    /// exactly that:
    ///
    ///   * the link was `NSView.displayLink(target:selector:)`, whose own header
    ///     says the callback will not be invoked if the view is hidden or not on
    ///     any display. MEASURED at exactly 0.00 ticks/s with the window
    ///     minimised and with the app hidden (Cmd-H). `NSWindow.displayLink` is
    ///     no better — also 0.00 in both. `NSScreen.displayLink` holds the full
    ///     display rate in every window state there is, so that is what drives
    ///     the loop now, re-bound when the window changes screen.
    ///
    ///   * `GodotApp.applicationDidResignActive` called `pause()`, and
    ///     `iterateFrame` returned early on it. That is an iOS policy — the app
    ///     really is suspended when it leaves the foreground — applied to a Mac,
    ///     where losing key focus means somebody clicked another window. It is
    ///     gone from the macOS path (see `GodotApp.pausesOnResignActive`).
    ///
    /// And because a training app must not quietly lose time, the link is not
    /// trusted on its own: `watchdog` runs alongside it and drives the frame
    /// itself if the link goes quiet, reporting the stall rather than absorbing
    /// it.
    private var link: CADisplayLink? = nil
    private var linkScreen: NSScreen? = nil
    private var screenObserver: NSObjectProtocol? = nil

    /// The backstop. A plain run-loop timer keeps its cadence in every window
    /// state, including the two where display links stop, so it can always take
    /// over. It costs a wakeup per tick and nothing else: it iterates only when
    /// the link has not.
    private var watchdog: Foundation.Timer? = nil
    private var lastIterationAt: CFTimeInterval = 0
    private var stalled = false

    /// How long the loop may go quiet before the watchdog drives it. Three
    /// frames at 60 Hz — long enough not to fight a display link that is merely
    /// running at a lower refresh rate, short enough that no ride sample is lost.
    public static let stallGrace: CFTimeInterval = 0.05
    /// How long a gap has to be before it is reported as a stall rather than a
    /// hitch.
    public static let stallReport: CFTimeInterval = 0.5

    private var frameCount: UInt64 = 0
    private var loggedSurfaceBinding = false
    private var didEmitDisplayServerNotEmbeddedWarning = false
    private var callbackToken: UUID?
    private weak var callbackApp: GodotApp?

    private func stderrLog(_ message: String) {
        if let data = ("[SwiftGodotKit] " + message + "\n").data(using: .utf8) {
            FileHandle.standardError.write(data)
        }
    }

    private func emitDisplayServerNotEmbeddedWarning(context: String) {
        guard !didEmitDisplayServerNotEmbeddedWarning else { return }
        didEmitDisplayServerNotEmbeddedWarning = true
        let detail = "DisplayServer.shared is not DisplayServerEmbedded (\(context))"
        logger.error("\(detail, privacy: .public)")
        print("[SwiftGodotKit] \(detail)")
        stderrLog(detail)
        app?.emitRuntimeEvent(
            .warning(
                GodotWarningEvent(
                    code: .displayServerNotEmbedded,
                    detail: detail
                )
            )
        )
    }
    
    public var app: GodotApp?
    public var source: String?
    public var scene: String?
    public var onReady: ((GodotAppViewHandle) -> Void)?
    public var onMessage: ((VariantDictionary) -> Void)?
    
    public override func layout() {
        if let renderingLayer {
            renderingLayer.frame = self.bounds
        }
        
        if let app, let instance = app.instance {
            if instance.isStarted() {
                if app.displayDriver == "embedded" {
                    if embedded == nil {
                        if let displayServer = DisplayServer.shared as? DisplayServerEmbedded {
                            embedded = displayServer
                            logger.info("NSGodotAppView.layout created embedded display server")
                            print("[SwiftGodotKit] NSGodotAppView.layout created embedded display server")
                        } else {
                            emitDisplayServerNotEmbeddedWarning(context: "layout")
                        }
                    }

                    resizeWindow()
                }
            }
        } else if let app {
            app.queueLayout(self)
        }
        super.layout()
    }

    func startGodotInstance() {
        syncCallbackRegistration()
        if let app, let instance = app.instance {
            if app.displayDriver == "embedded" {
                guard let renderingLayer else {
                    Logger.App.error("startGodotInstance: renderingLayer was nil")
                    return
                }
                let rendererNativeSurface = RenderingNativeSurfaceApple.create(layer: UInt(bitPattern: Unmanaged.passUnretained(renderingLayer).toOpaque()))
                DisplayServerEmbedded.setNativeSurface(rendererNativeSurface)
                if !loggedSurfaceBinding {
                    logger.info("Bound native surface layer=\(String(describing: renderingLayer), privacy: .public) size=\(String(describing: renderingLayer.drawableSize), privacy: .public)")
                    print("[SwiftGodotKit] Bound native surface size=\(renderingLayer.drawableSize)")
                    loggedSurfaceBinding = true
                }
            }
            print("[SwiftGodotKit] startGodotInstance before instance.isStarted()")
            let alreadyStarted = instance.isStarted()
            print("[SwiftGodotKit] startGodotInstance after instance.isStarted() -> \(alreadyStarted)")
            if !alreadyStarted {
                let started = instance.start()
                Logger.App.info("startGodotInstance: instance.start() -> \(started)")
                print("[SwiftGodotKit] startGodotInstance instance.start() -> \(started)")
                stderrLog("startGodotInstance instance.start() -> \(started)")
            }
            if app.displayDriver == "embedded", embedded == nil {
                if let displayServer = DisplayServer.shared as? DisplayServerEmbedded {
                    embedded = displayServer
                    print("[SwiftGodotKit] startGodotInstance created embedded display server")
                    stderrLog("startGodotInstance created embedded display server")
                } else {
                    emitDisplayServerNotEmbeddedWarning(context: "startGodotInstance")
                }
            }
            resizeWindow()
            app.pollBridgeAndReadiness()
            installFrameLoop()
            app.registerFrameLoopTeardown(self) { [weak self] in
                self?.tearDownFrameLoop()
            }
        } else if let app {
            app.queueStart(self)
        }
    }

    // MARK: - the frame loop

    private func installFrameLoop() {
        bindDisplayLink()
        if screenObserver == nil {
            screenObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeScreenNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.bindDisplayLink()
            }
        }
        if watchdog == nil {
            lastIterationAt = CACurrentMediaTime()
            // Scheduled on `.common` so it keeps firing through window drags and
            // menu tracking, which is where a run-loop timer would otherwise
            // starve exactly when the display link is also being throttled.
            let timer = Foundation.Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
                self?.watchdogFired()
            }
            timer.tolerance = 0
            RunLoop.main.add(timer, forMode: .common)
            watchdog = timer
            stderrLog("frame loop installed (screen display link + watchdog)")
        }
    }

    /// Bind the tick to the SCREEN the window is on, not to this view. Called
    /// again whenever the window moves to another display.
    private func bindDisplayLink() {
        let screen = window?.screen ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }
        if link != nil, linkScreen === screen { return }
        link?.invalidate()
        let fresh = screen.displayLink(target: self, selector: #selector(iterate(_:)))
        fresh.add(to: .main, forMode: RunLoop.Mode.common)
        link = fresh
        linkScreen = screen
        print("[SwiftGodotKit] display link bound to screen \(screen.localizedName)")
        stderrLog("display link bound to screen \(screen.localizedName)")
    }

    private func watchdogFired() {
        let gap = CACurrentMediaTime() - lastIterationAt
        guard gap >= NSGodotAppView.stallGrace else {
            if stalled {
                stalled = false
                app?.emitRuntimeEvent(.warning(GodotWarningEvent(
                    code: .frameLoopRecovered,
                    detail: "display link is ticking again")))
                stderrLog("frame loop recovered")
            }
            return
        }
        if gap >= NSGodotAppView.stallReport, !stalled {
            stalled = true
            let detail = String(format: "no frame for %.2f s — watchdog is driving the loop", gap)
            app?.emitRuntimeEvent(.warning(GodotWarningEvent(code: .frameLoopStalled, detail: detail)))
            logger.error("\(detail, privacy: .public)")
            stderrLog("frame loop stalled: \(detail)")
        }
        // Whether it is a hitch or a stall, the frame still has to happen.
        iterateFrame()
        // A link that has gone quiet may also have gone stale — a screen change
        // while the window was off-screen leaves it bound to a display that no
        // longer drives us.
        if gap >= NSGodotAppView.stallReport {
            linkScreen = nil
            bindDisplayLink()
        }
    }

    func tearDownFrameLoop() {
        link?.invalidate()
        link = nil
        linkScreen = nil
        watchdog?.invalidate()
        watchdog = nil
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
            self.screenObserver = nil
        }
    }

    public override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        if superview == nil {
            tearDownFrameLoop()
            frameCount = 0
            unregisterCallbacks()
        }
    }
    public override func viewDidMoveToWindow() {
        // It seems doing this in viewDidMoveToSuperview is too early to start the Godot app.
        if window != nil {
            app?.start()
            startGodotInstance()
            needsLayout = true
        }
    }
    
    @objc
    func iterate(_ link: CADisplayLink) {
        iterateFrame()
    }

    /// Put the engine's window back to the size of this view if something moved
    /// it. Reading the size first means the common case — nothing moved it — is
    /// one cheap query and no resize at all, so this cannot thrash a swapchain.
    private func enforceSurfaceSize() {
        guard app?.displayDriver == "embedded", embedded != nil else { return }
        let want = desiredSurfaceSize
        guard want.x > 1, want.y > 1 else { return }
        let have = DisplayServer.windowGetSize(windowId: Int32(windowId))
        guard have != want else { return }
        if renderingLayer?.frame.size != bounds.size {
            renderingLayer?.frame = bounds
        }
        resizeWindow()
    }

    private func iterateFrame() {
        if let app, (app.isPaused || !app.isDrawing) {
            // Still a heartbeat: a deliberately paused engine is not a stall, and
            // the watchdog must not spend the whole pause shouting about one.
            lastIterationAt = CACurrentMediaTime()
            return
        }
        if let instance = app?.instance, instance.isStarted() {
            lastIterationAt = CACurrentMediaTime()
            // THE SURFACE IS RE-ASSERTED EVERY FRAME, and it has to be. The
            // embedded display server owns the Metal layer's geometry, and the
            // game sets `get_window().size` in `_ready` for the standalone build
            // — which, embedded, shrinks the layer to that size in the top-left
            // corner of the view and leaves the rest of it showing the window
            // background. `layout()` is the only other place that corrects this
            // and SwiftUI called it exactly once for a whole session, so
            // whichever of the two ran last used to win permanently.
            enforceSurfaceSize()
            _ = instance.iteration()
            app?.pollBridgeAndReadiness()
            frameCount += 1
            if frameCount == 1 || frameCount % 300 == 0 {
                logger.info("NSGodotAppView.iterate frame=\(self.frameCount)")
                print("[SwiftGodotKit] iterate frame=\(frameCount)")
                stderrLog("iterate frame=\(frameCount)")
            }
        }
    }

    deinit {
        unregisterCallbacks()
    }
}

private extension NSGodotAppView {
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
