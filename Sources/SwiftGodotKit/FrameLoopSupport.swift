//
//  FrameLoopSupport.swift
//
//  The frame loop's two decisions — "does this update have to touch the engine?"
//  and "has the loop stopped?" — kept as plain values and plain objects, with no
//  engine, window, screen or display link anywhere in them, so both can be
//  tested on a machine with no screen at all.
//

import Foundation
import QuartzCore
#if canImport(Dispatch)
import Dispatch
#endif

// MARK: - What an update pass is allowed to do to a live engine

/// WHAT AN UPDATE PASS IS ALLOWED TO DO TO A LIVE ENGINE: nothing, unless one of
/// its inputs actually changed.
///
/// SwiftUI calls `updateNSView` whenever the graph the view belongs to is
/// re-evaluated. That is not the same question as "has this view's binding to
/// the engine changed", and `updateNSView` used to answer it by rebinding the
/// Metal surface, restarting the instance, re-registering the callbacks and
/// re-arming the frame loop — every single time. Re-arming the loop wrote to an
/// observable property of the `GodotApp` the pass had just read out of the
/// environment (`GodotApp.frameLoopTeardowns`), so the pass invalidated itself
/// and ran again. One ordinary window resize started it and nothing stopped it.
///
/// MEASURED, at 1800x900, mid-ride: `startGodotInstance` entered 8,287,905
/// times, 45,271 a second, the engine at 0.0 fps and 0.00 Hz of ride samples for
/// 222 seconds, never recovering. `sample(1)` of the hung process gives the same
/// stack every time:
///
///     NSHostingView.beginTransaction
///       → GraphHost.flushTransactions
///         → PlatformViewChild.updateValue
///           → GodotAppView.updateNSView
///             → startGodotInstance
///               → RenderingNativeSurfaceApple.create(layer:)
///
/// THIS GUARD IS THE SECOND OF TWO CUTS, and it was measured on its own: with
/// the observable write still there and only this guard in place, the same run
/// held 24.2 fps and 1.00 Hz across the resize on 3 total calls. It is kept
/// because it is the one that does not depend on knowing which property is
/// observable — it stops the update pass reaching the engine at all, so no write
/// of any kind can close a cycle through it. See `GodotApp.backgroundActivity`
/// for the full 2x2.
public struct EngineBindingGuard: Equatable, Sendable {
    /// The layer the native surface was last bound to.
    public private(set) var boundLayer: ObjectIdentifier?
    /// The `GodotApp` that binding was made against. A different app object is a
    /// different engine and has to be bound again.
    public private(set) var boundApp: ObjectIdentifier?
    /// True once an engine was started against that pairing and the loop armed.
    public private(set) var isArmed = false

    public init() {}

    /// Does a call with these inputs have any work to do?
    ///
    /// Deliberately conservative in exactly one direction: it says yes whenever
    /// it is not certain the answer is no. A redundant bind costs one swapchain;
    /// a missed one costs the ride.
    public func needsBinding(layer: ObjectIdentifier?, app: ObjectIdentifier?) -> Bool {
        guard isArmed else { return true }
        guard let layer, let app else { return true }
        return boundLayer != layer || boundApp != app
    }

    /// Record that the surface is bound, the instance started and the loop armed
    /// against this pairing.
    public mutating func arm(layer: ObjectIdentifier?, app: ObjectIdentifier?) {
        boundLayer = layer
        boundApp = app
        isArmed = true
    }

    /// Forget all of it — the view left its window, or the engine went away, and
    /// the next call has to do the work again.
    public mutating func disarm() {
        boundLayer = nil
        boundApp = nil
        isArmed = false
    }
}

// MARK: - The heartbeat

/// THE HEARTBEAT A SPINNING MAIN THREAD CANNOT HOLD DOWN.
///
/// The frame loop's own watchdog is a `RunLoop.main` timer, and a run-loop timer
/// is serviced by the run loop — so the one failure it structurally cannot see
/// is the main thread never returning to the run loop. That is precisely what
/// happened above, and it is why a three-minute total stall produced no
/// `frameLoopStalled` line at all.
///
/// So the frame's timestamp is written HERE, behind a lock, where a thread that
/// is not the main thread can read it.
public final class FrameLoopHeartbeat: @unchecked Sendable {
    /// What the loop looks like from outside the main thread.
    public struct Snapshot: Equatable, Sendable {
        /// Seconds since the last frame (or since the loop last said it was
        /// deliberately idle).
        public var age: CFTimeInterval
        /// Frames iterated since this heartbeat was created.
        public var frames: UInt64
        /// Times `startGodotInstance` has been ENTERED — not times it did work.
        /// The number that made the update loop visible.
        public var startCalls: UInt64

        public init(age: CFTimeInterval, frames: UInt64, startCalls: UInt64) {
            self.age = age
            self.frames = frames
            self.startCalls = startCalls
        }
    }

    private let lock = NSLock()
    private var lastBeatAt: CFTimeInterval
    private var frameCount: UInt64 = 0
    private var startCallCount: UInt64 = 0

    public init(now: CFTimeInterval = CACurrentMediaTime()) {
        lastBeatAt = now
    }

    /// A frame happened.
    public func beat(at now: CFTimeInterval = CACurrentMediaTime()) {
        lock.lock()
        lastBeatAt = now
        frameCount &+= 1
        lock.unlock()
    }

    /// The loop ran but deliberately did not iterate — a paused engine, or one
    /// that has been told to stop drawing. Alive, so not a stall, but not a
    /// frame either.
    public func markAlive(at now: CFTimeInterval = CACurrentMediaTime()) {
        lock.lock()
        lastBeatAt = now
        lock.unlock()
    }

    /// `startGodotInstance` was entered.
    public func noteStartCall() {
        lock.lock()
        startCallCount &+= 1
        lock.unlock()
    }

    public func snapshot(at now: CFTimeInterval = CACurrentMediaTime()) -> Snapshot {
        lock.lock()
        let snapshot = Snapshot(
            age: now - lastBeatAt,
            frames: frameCount,
            startCalls: startCallCount
        )
        lock.unlock()
        return snapshot
    }
}

// MARK: - The stall decision

/// What the off-main reporter decided on one tick.
public enum FrameLoopStallEvent: Equatable, Sendable {
    /// The loop has just gone quiet for longer than the report threshold.
    /// `startCallsInWindow` is how many times `startGodotInstance` was entered
    /// over `window` seconds — a large number here names the fault as a spin in
    /// the view's update path rather than a block somewhere else.
    case stalled(age: CFTimeInterval, startCallsInWindow: UInt64, window: CFTimeInterval)
    /// Still quiet, said again so a long stall leaves a trail rather than one
    /// line at the top of it.
    case stillStalled(age: CFTimeInterval, startCallsInWindow: UInt64, window: CFTimeInterval)
    /// Frames again.
    case recovered(afterStallOf: CFTimeInterval)
}

/// The decision, with no clock and no thread in it.
public struct FrameLoopStallDetector: Sendable {
    /// How long the loop may be quiet before it is a stall rather than a hitch.
    public var reportAfter: CFTimeInterval
    /// How often a continuing stall says so again.
    public var repeatEvery: CFTimeInterval

    private var isStalled = false
    private var startCallsWhenHealthy: UInt64 = 0
    private var startCallsAtLastReport: UInt64 = 0
    private var ageAtLastReport: CFTimeInterval = 0

    public init(reportAfter: CFTimeInterval = 0.5, repeatEvery: CFTimeInterval = 5.0) {
        self.reportAfter = reportAfter
        self.repeatEvery = repeatEvery
    }

    public var isReportingAStall: Bool { isStalled }

    public mutating func evaluate(_ snapshot: FrameLoopHeartbeat.Snapshot) -> FrameLoopStallEvent? {
        guard snapshot.age >= reportAfter else {
            startCallsWhenHealthy = snapshot.startCalls
            guard isStalled else { return nil }
            isStalled = false
            let stallLength = ageAtLastReport
            ageAtLastReport = 0
            return .recovered(afterStallOf: stallLength)
        }

        if !isStalled {
            isStalled = true
            let calls = snapshot.startCalls &- startCallsWhenHealthy
            startCallsAtLastReport = snapshot.startCalls
            ageAtLastReport = snapshot.age
            return .stalled(age: snapshot.age, startCallsInWindow: calls, window: snapshot.age)
        }

        let sinceLastReport = snapshot.age - ageAtLastReport
        guard sinceLastReport >= repeatEvery else { return nil }
        let calls = snapshot.startCalls &- startCallsAtLastReport
        startCallsAtLastReport = snapshot.startCalls
        ageAtLastReport = snapshot.age
        return .stillStalled(
            age: snapshot.age,
            startCallsInWindow: calls,
            window: sinceLastReport
        )
    }
}

// MARK: - The off-main reporter

/// The stall reporter, AND WHY IT ONLY REPORTS.
///
/// It runs a dispatch timer on its own queue, reads the heartbeat, and writes
/// what it finds straight to stderr — never through the main thread, because the
/// case it exists for is a main thread that is never coming back.
///
/// It cannot RECOVER that case and no watchdog can: `GodotInstance.iteration()`
/// must run on the main thread, so a main thread that is spinning cannot be made
/// to iterate by anybody. Recovery of a quiet display link belongs to the
/// main-thread watchdog, which can do it; recovery of a main-thread spin belongs
/// to not spinning. What this guarantees is the other half of the contract: the
/// stall is never absorbed silently.
public final class FrameLoopStallReporter: @unchecked Sendable {
    private let heartbeat: FrameLoopHeartbeat
    private let queue: DispatchQueue
    private let interval: CFTimeInterval
    private let traceEvery: CFTimeInterval?
    private let report: @Sendable (FrameLoopStallEvent, FrameLoopHeartbeat.Snapshot) -> Void
    private let trace: @Sendable (FrameLoopHeartbeat.Snapshot) -> Void

    private var timer: DispatchSourceTimer?
    private var detector: FrameLoopStallDetector
    private var lastTraceAt: CFTimeInterval = 0

    /// `SWIFTGODOT_FRAMELOOP_TRACE=1` turns on a once-a-second line carrying the
    /// frame and start-call counters. Off by default: a training app should not
    /// write a line a second forever, and the stall report — which is what
    /// actually matters — is always on.
    public static var tracingIsEnabled: Bool {
        let value = ProcessInfo.processInfo.environment["SWIFTGODOT_FRAMELOOP_TRACE"] ?? ""
        return value == "1" || value.lowercased() == "true" || value.lowercased() == "yes"
    }

    public init(
        heartbeat: FrameLoopHeartbeat,
        detector: FrameLoopStallDetector = FrameLoopStallDetector(),
        interval: CFTimeInterval = 0.25,
        traceEvery: CFTimeInterval? = nil,
        report: @escaping @Sendable (FrameLoopStallEvent, FrameLoopHeartbeat.Snapshot) -> Void,
        trace: @escaping @Sendable (FrameLoopHeartbeat.Snapshot) -> Void = { _ in }
    ) {
        self.heartbeat = heartbeat
        self.detector = detector
        self.interval = interval
        self.traceEvery = traceEvery
        self.report = report
        self.trace = trace
        queue = DispatchQueue(label: "app.basis.swiftgodotkit.frameloop-watch", qos: .utility)
    }

    public func start() {
        guard timer == nil else { return }
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(20))
        source.setEventHandler { [weak self] in self?.tick() }
        timer = source
        source.resume()
    }

    public func stop() {
        timer?.cancel()
        timer = nil
    }

    private func tick() {
        let now = CACurrentMediaTime()
        let snapshot = heartbeat.snapshot(at: now)
        if let event = detector.evaluate(snapshot) {
            report(event, snapshot)
        }
        if let traceEvery, now - lastTraceAt >= traceEvery {
            lastTraceAt = now
            trace(snapshot)
        }
    }

    deinit {
        timer?.cancel()
    }
}
