import CoreGraphics

/// HOW MANY PIXELS THE ENGINE IS ASKED TO DRAW, WHICH ON A PHONE IS NOT
/// "ALL OF THEM".
///
/// A `CAMetalLayer` composites its drawable into the layer's own bounds, so a
/// drawable smaller than the screen's backing store is scaled up by the display
/// pipeline for free. That is the one knob that moves the 3D render and the
/// engine's 2D canvas together — `Viewport.scaling_3d_scale` moves only the
/// first, and on a HUD-heavy frame that leaves a third of the cost behind.
///
/// The budget is stated in MEGAPIXELS rather than as a scale factor because it
/// is a statement about the GPU, and a fraction of the backing store means
/// something different on every device: two thirds of an iPhone 17 Pro Max is
/// 1.7 Mpx and two thirds of an iPhone SE is 0.3. A budget generalises; a
/// fraction only describes the phone it was measured on.
public enum RenderBudget: Equatable, Sendable {
    /// One render pixel per screen pixel. Every Mac, and any surface already
    /// inside its budget.
    case native
    /// At most this many megapixels, never below one render pixel per point and
    /// never above the screen's own scale.
    case megapixels(Double)

    /// Render pixels per point, for a surface this many points across.
    func scale(forPointSize size: CGSize, screenScale: CGFloat) -> CGFloat {
        let native = max(screenScale, 1)
        guard case let .megapixels(budget) = self, budget > 0 else { return native }
        let area = max(size.width * size.height, 1)
        // Area, not width: the cost is pixels, and rotating a phone does not
        // change how many of them there are. One budget therefore answers both
        // orientations with the same number, which is what makes it a budget
        // rather than two hand-tuned constants.
        let wanted = (CGFloat(budget) * 1_000_000 / area).squareRoot()
        return min(native, max(1, wanted))
    }
}

/// HOW OFTEN THE ENGINE IS ASKED TO DRAW.
///
/// `.free` is what every desktop gets: the display link runs at whatever the
/// system offers and the engine draws every time it is called. `.range` asks
/// CoreAnimation for a cadence — a *range* rather than a number, because on a
/// 120 Hz display a hard target is a cliff: a frame that overruns its slot by a
/// millisecond waits for the next one, which is the next whole refresh, which is
/// the next rate DOWN. A range lets the compositor settle wherever the work
/// really fits.
public enum FrameRateRequest: Equatable, Sendable {
    case free
    /// Frames per second: the floor the system may fall back to, and the rate
    /// to aim for.
    case range(minimum: Int, preferred: Int)
}
