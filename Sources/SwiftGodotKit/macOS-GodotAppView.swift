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

    /// AN UPDATE PASS IS NOT AN EVENT. SwiftUI runs this whenever the graph
    /// around the view is re-evaluated — a resize, a minimise, an unrelated
    /// state change upstream — and none of those are a reason to touch a running
    /// engine. This used to call `startGodotInstance()` unconditionally, which
    /// re-armed the frame loop, which wrote to an observable property of the
    /// very `GodotApp` this pass had just read: 45,271 passes a second,
    /// forever, with the ride frozen behind it. See `EngineBindingGuard` and
    /// `GodotApp.backgroundActivity` for the measurements.
    ///
    /// What is left here is only the cheap, repeatable part: the closures the
    /// caller re-creates on every body evaluation, and a callback registration
    /// that is a no-op once it has happened. The engine work runs when the
    /// binding is not armed, and not otherwise.
    public func updateNSView(_ nsView: NSGodotAppView, context: Context) {
        app?.configureLaunch(source: source, scene: scene)
        nsView.source = source
        nsView.scene = scene
        nsView.onReady = onReady
        nsView.onMessage = onMessage
        nsView.syncCallbackRegistration()
        if nsView.needsEngineBinding {
            nsView.startGodotInstance()
        }
    }
}

typealias TTGodotAppView = NSGodotAppView
typealias TTGodotWindow = NSGodotWindow

public class NSGodotAppView: GodotView {
    /// THE FRAME LOOP, AND THE THREE WAYS IT HAS STOPPED.
    ///
    /// `instance.iteration()` is the entire game clock — physics, the workout
    /// timer, the bridge. On macOS this view is its only caller, so whatever
    /// stops calling it stops the ride. Three separate mechanisms have done
    /// exactly that, and each is fixed in a different place:
    ///
    ///   * THE LINK STOPPED. It was `NSView.displayLink(target:selector:)`,
    ///     whose own header says the callback will not be invoked if the view is
    ///     hidden or not on any display. MEASURED at exactly 0.00 ticks/s with
    ///     the window minimised and with the app hidden (Cmd-H).
    ///     `NSWindow.displayLink` is no better — also 0.00 in both.
    ///     `NSScreen.displayLink` holds the full display rate in every window
    ///     state there is, so that is what drives the loop now, re-bound when
    ///     the window changes screen.
    ///
    ///   * THE ENGINE WAS PAUSED ON PURPOSE.
    ///     `GodotApp.applicationDidResignActive` called `pause()`, and
    ///     `iterateFrame` returned early on it. That is an iOS policy — the app
    ///     really is suspended when it leaves the foreground — applied to a Mac,
    ///     where losing key focus means somebody clicked another window. It is
    ///     gone from the macOS path (see `GodotApp.pausesOnResignActive`).
    ///
    ///   * THE MAIN THREAD NEVER CAME BACK. `GodotAppView.updateNSView` did the
    ///     engine's whole binding — surface, instance, callbacks, loop — on
    ///     every SwiftUI update pass, and arming the loop wrote to an observable
    ///     property of the `GodotApp` that pass had just read. One ordinary
    ///     window resize therefore put the process into an update loop at 45,271
    ///     passes a second with the ride frozen behind it, permanently. Cut in
    ///     two places: `EngineBindingGuard` here, `@ObservationIgnored` there.
    ///
    /// And because a training app must not quietly lose time, the link is not
    /// trusted on its own. TWO watchers sit beside it, and they are not
    /// redundant: `watchdog` is a run-loop timer that can DRIVE the frame when
    /// the link goes quiet, and `stallReporter` runs off the main thread so that
    /// the third failure above — the one that starves any run-loop timer — is
    /// still REPORTED. Between them a stall is recovered or reported; the case
    /// that can only be reported is named as such where it is emitted.
    private var link: CADisplayLink? = nil
    private var linkScreen: NSScreen? = nil
    private var screenObserver: NSObjectProtocol? = nil

    /// The backstop. A plain run-loop timer keeps its cadence in every window
    /// state, including the two where display links stop, so it can always take
    /// over. It costs a wakeup per tick and nothing else: it iterates only when
    /// the link has not.
    ///
    /// IT CAN RECOVER A QUIET LINK AND IT CANNOT RECOVER A BUSY MAIN THREAD, and
    /// that distinction cost a whole review cycle. A run-loop timer is serviced
    /// by the run loop; a main thread that never returns to the run loop
    /// therefore starves the very thing meant to notice. Measured: across a
    /// three-minute total freeze this emitted nothing at all. `stallReporter`
    /// below is the half that watches from somewhere it can see.
    private var watchdog: Foundation.Timer? = nil
    private var lastIterationAt: CFTimeInterval = 0
    private var stalled = false

    /// The frame's timestamp, written where a thread that is not the main thread
    /// can read it, and the reporter that reads it. See `FrameLoopSupport.swift`.
    private let heartbeat = FrameLoopHeartbeat()
    private var stallReporter: FrameLoopStallReporter? = nil

    /// Whether the surface, the instance and the loop are already bound for this
    /// (layer, app) pairing. The whole answer to the update loop.
    private var bindingGuard = EngineBindingGuard()

    /// True when `startGodotInstance()` would actually do something.
    var needsEngineBinding: Bool {
        bindingGuard.needsBinding(layer: layerIdentity, app: appIdentity)
    }

    private var layerIdentity: ObjectIdentifier? {
        renderingLayer.map(ObjectIdentifier.init)
    }

    private var appIdentity: ObjectIdentifier? {
        app.map(ObjectIdentifier.init)
    }

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

    /// Bind the surface, start the engine, arm the loop — ONCE PER (layer, app)
    /// PAIRING, however many times this is called.
    ///
    /// Every caller of this is a "make sure it is up" caller: SwiftUI's update
    /// pass, `viewDidMoveToWindow`, and `GodotApp.startPending()` draining views
    /// that asked before there was an instance. None of them knows whether the
    /// work has already happened, so the knowledge lives here.
    func startGodotInstance() {
        // Counted before the guard, deliberately: the number that matters is how
        // often this is ENTERED, because entering it 45,271 times a second is
        // what the frozen ride looked like. A guard that made the count go down
        // by hiding the calls would be measuring itself.
        heartbeat.noteStartCall()
        syncCallbackRegistration()
        guard bindingGuard.needsBinding(layer: layerIdentity, app: appIdentity) else { return }
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
            // Only now, and only if all of that actually happened: an instance
            // that exists but has not started leaves the guard open so the next
            // caller tries again.
            if instance.isStarted() {
                bindingGuard.arm(layer: layerIdentity, app: appIdentity)
                stderrLog("engine bound (surface + instance + frame loop); "
                    + "further update passes are no-ops")
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
        installStallReporter()
    }

    /// The watcher that is NOT on the main thread, because the stall this loop
    /// actually suffered was a main thread that never came back — and the
    /// main-thread watchdog above saw nothing at all for three minutes.
    ///
    /// It reports and it does not repair: `instance.iteration()` is main-thread
    /// only, so nothing off the main thread can make a spinning app iterate.
    /// The contract this keeps is that the stall is never absorbed.
    private func installStallReporter() {
        guard stallReporter == nil else { return }
        let logStall: @Sendable (String) -> Void = { message in
            if let data = ("[SwiftGodotKit] " + message + "\n").data(using: .utf8) {
                FileHandle.standardError.write(data)
            }
        }
        // The APP, not `self`: this view is main-actor isolated and the closure
        // below runs on a queue that is deliberately not the main one. `GodotApp`
        // is a plain class and `emitRuntimeEvent` already does its own hop.
        let reporter = FrameLoopStallReporter(
            heartbeat: heartbeat,
            detector: FrameLoopStallDetector(reportAfter: NSGodotAppView.stallReport),
            traceEvery: FrameLoopStallReporter.tracingIsEnabled ? 1.0 : nil,
            report: { [weak app] event, _ in
                switch event {
                case let .stalled(age, calls, window), let .stillStalled(age, calls, window):
                    let rate = window > 0 ? Double(calls) / window : 0
                    let cause = calls > 100
                        ? "the main thread is spinning in the view's update path"
                        : "the main thread is not returning to the run loop"
                    let detail = String(
                        format: "no frame for %.2f s — %@ (startGodotInstance %llu calls in %.2f s, %.0f/s)",
                        age, cause, calls, window, rate
                    )
                    logStall("frame loop stalled (off-main watch): \(detail)")
                    // Best effort, and second: this hop needs the main thread,
                    // which is exactly what may be gone. The stderr line above
                    // is the one that is guaranteed to land.
                    app?.emitRuntimeEvent(.warning(GodotWarningEvent(
                        code: .frameLoopStalled, detail: detail)))
                case let .recovered(stallLength):
                    let detail = String(format: "frames again after %.2f s", stallLength)
                    logStall("frame loop recovered (off-main watch): \(detail)")
                    app?.emitRuntimeEvent(.warning(GodotWarningEvent(
                        code: .frameLoopRecovered, detail: detail)))
                }
            },
            trace: { snapshot in
                logStall(String(
                    format: "frameloop mono=%.3f epoch=%.3f frames=%llu starts=%llu gap=%.3f",
                    CACurrentMediaTime(), Date().timeIntervalSince1970,
                    snapshot.frames, snapshot.startCalls, snapshot.age
                ))
            }
        )
        stallReporter = reporter
        reporter.start()
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
        stallReporter?.stop()
        stallReporter = nil
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
            // The next time this view is put back in a hierarchy it has to bind
            // again — the loop it was arming has just been torn down.
            bindingGuard.disarm()
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
            heartbeat.markAlive(at: lastIterationAt)
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
            // Beaten AFTER the frame, so a frame that hangs inside `iteration()`
            // is measured from the end of the last one that did not.
            heartbeat.beat()
            if frameCount == 1 || frameCount % 300 == 0 {
                logger.info("NSGodotAppView.iterate frame=\(self.frameCount)")
                print("[SwiftGodotKit] iterate frame=\(frameCount)")
                stderrLog("iterate frame=\(frameCount)"
                    + " starts=\(heartbeat.snapshot().startCalls)")
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
