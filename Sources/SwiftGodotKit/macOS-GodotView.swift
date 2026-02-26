//
//  MacOS/GodotView.swift
//
//
#if os(macOS)
import AppKit
import Foundation
import QuartzCore

import SwiftGodot
public class GodotView: NSView {
    static var keymap: [UInt16: Key] = initKeyMap()
    static var locationMap: [UInt16: KeyLocation] = initLocationMap()
    
    public var renderingLayer: CAMetalLayer? = nil
    internal var embedded: DisplayServerEmbedded?
    private var lastResizeSize: Vector2i?
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        commonInit()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }
    
    private func commonInit() {
        wantsLayer = true

        let renderingLayer = CAMetalLayer()
        renderingLayer.frame = bounds

        layer?.addSublayer(renderingLayer)
        self.renderingLayer = renderingLayer
        updateRenderingLayerGeometry()
    }
    
    deinit {
        if renderingLayer?.superlayer != nil {
            renderingLayer?.removeFromSuperlayer()
        }
    }
    
    open var windowId: Int {
        DisplayServer.mainWindowId
    }
    
    public override var bounds: CGRect {
        didSet {
            updateRenderingLayerGeometry()
            resizeWindow()
        }
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateRenderingLayerGeometry()
        resizeWindow()
    }

    func resizeWindow() {
        guard let embedded else { return }
        let scale = renderingLayer?.contentsScale ?? 1.0
        let pixelWidth = Int32(max(1, self.bounds.size.width * scale))
        let pixelHeight = Int32(max(1, self.bounds.size.height * scale))
        let size = Vector2i(x: pixelWidth, y: pixelHeight)
        if lastResizeSize != size {
            print("[SwiftGodotKit] resizeWindow id=\(windowId) size=\(pixelWidth)x\(pixelHeight)")
            if let data = ("[SwiftGodotKit] resizeWindow id=\(windowId) size=\(pixelWidth)x\(pixelHeight)\n").data(using: .utf8) {
                FileHandle.standardError.write(data)
            }
            lastResizeSize = size
        }

        embedded.resizeWindow(
            size: size,
            id: Int32(windowId)
        )
    }

    public override var acceptsFirstResponder: Bool {
        true
    }
    
    override public func keyDown(with event: NSEvent) {
        processKeyEvent(event: event, pressed: true)
    }
    
    override public func keyUp(with event: NSEvent) {
        processKeyEvent(event: event, pressed: false)
    }
    
    func processKeyEvent(event: NSEvent, pressed: Bool) {
        let keyEvent = InputEventKey()
        keyEvent.windowId = windowId
        
        guard let key = GodotView.keymap[event.keyCode] else {
            return
        }
        
        keyEvent.physicalKeycode = key

        keyEvent.ctrlPressed = event.modifierFlags.contains(.control)
        keyEvent.shiftPressed = event.modifierFlags.contains(.shift)
        keyEvent.altPressed = event.modifierFlags.contains(.option)
        keyEvent.metaPressed = event.modifierFlags.contains(.command)
        
        keyEvent.echo = event.isARepeat
        keyEvent.pressed = pressed
        keyEvent.location = GodotView.locationMap[event.keyCode] ?? .unspecified

        Input.parseInputEvent(keyEvent)
    }
    
    // MARK: - Mouse motion callback
    //
    // InputEventMouseMotion cannot go through Input.parseInputEvent() in
    // embedded mode because Viewport GUI processing calls
    // DisplayServerEmbedded::cursor_set_shape() which crashes.
    // Instead, motion events are forwarded via this static callback so the
    // host application can handle them directly.
    public static var mouseMotionHandler: ((_ event: InputEventMouseMotion) -> Void)?

    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    // MARK: - Left mouse button

    var mouseDownControl: Bool = false
    override public func mouseDown(with event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)
        print("[GodotView.mouseDown] loc=(\(Int(loc.x)),\(Int(bounds.height - loc.y))) isFirstResponder=\(self == window?.firstResponder)")
        if event.modifierFlags.contains(.control) {
            mouseDownControl = true
            processMouseButtonEvent(event: event, index: .right, pressed: true, outOfStream: false)
        } else {
            mouseDownControl = false
            processMouseButtonEvent(event: event, index: .left, pressed: true, outOfStream: false)
        }
    }

    override public func mouseUp(with event: NSEvent) {
        if mouseDownControl {
            processMouseButtonEvent(event: event, index: .right, pressed: false, outOfStream: false)
        } else {
            processMouseButtonEvent(event: event, index: .left, pressed: false, outOfStream: false)
        }
    }

    override public func mouseDragged(with event: NSEvent) {
        print("[GodotView.mouseDragged]")
        processMouseMotionEvent(event: event)
    }

    // MARK: - Right mouse button

    override public func rightMouseDown(with event: NSEvent) {
        processMouseButtonEvent(event: event, index: .right, pressed: true, outOfStream: false)
    }

    override public func rightMouseUp(with event: NSEvent) {
        processMouseButtonEvent(event: event, index: .right, pressed: false, outOfStream: false)
    }

    override public func rightMouseDragged(with event: NSEvent) {
        processMouseMotionEvent(event: event)
    }

    // MARK: - Other (middle) mouse button

    override public func otherMouseDown(with event: NSEvent) {
        processMouseButtonEvent(event: event, index: .middle, pressed: true, outOfStream: false)
    }

    override public func otherMouseUp(with event: NSEvent) {
        processMouseButtonEvent(event: event, index: .middle, pressed: false, outOfStream: false)
    }

    override public func otherMouseDragged(with event: NSEvent) {
        processMouseMotionEvent(event: event)
    }

    // MARK: - Scroll wheel

    override public func scrollWheel(with event: NSEvent) {
        let locationInView = convert(event.locationInWindow, from: nil)
        let vpos = Vector2(x: Float(locationInView.x),
                           y: Float(bounds.height - locationInView.y))
        let mask = currentButtonMask()

        // Vertical scroll
        if event.scrollingDeltaY != 0 {
            let index: MouseButton = event.scrollingDeltaY > 0 ? .wheelUp : .wheelDown
            let factor = event.hasPreciseScrollingDeltas
                ? Float(abs(event.scrollingDeltaY)) / 120.0
                : Float(abs(event.scrollingDeltaY))
            let mb = InputEventMouseButton()
            mb.windowId = windowId
            mb.buttonIndex = index
            mb.factor = Double(max(factor, 1.0))
            mb.position = vpos
            mb.globalPosition = vpos
            mb.buttonMask = mask

            mb.pressed = true
            Input.parseInputEvent(mb)

            mb.pressed = false
            Input.parseInputEvent(mb)
        }

        // Horizontal scroll
        if event.scrollingDeltaX != 0 {
            let index: MouseButton = event.scrollingDeltaX > 0 ? .wheelLeft : .wheelRight
            let factor = event.hasPreciseScrollingDeltas
                ? Float(abs(event.scrollingDeltaX)) / 120.0
                : Float(abs(event.scrollingDeltaX))
            let mb = InputEventMouseButton()
            mb.windowId = windowId
            mb.buttonIndex = index
            mb.factor = Double(max(factor, 1.0))
            mb.position = vpos
            mb.globalPosition = vpos
            mb.buttonMask = mask

            mb.pressed = true
            Input.parseInputEvent(mb)

            mb.pressed = false
            Input.parseInputEvent(mb)
        }
    }

    // MARK: - Event construction helpers

    func processMouseButtonEvent(event: NSEvent, index: MouseButton, pressed: Bool, outOfStream: Bool) {
        print("[GodotView.processMouseButtonEvent] index=\(index) pressed=\(pressed)")
        let mb = InputEventMouseButton()
        mb.windowId = windowId
        mb.buttonIndex = index == .left ? MouseButton.left : index == .right ? MouseButton.right : index == .middle ? MouseButton.middle : .none

        mb.pressed = pressed
        let locationInView = convert(event.locationInWindow, from: nil)

        let vpos = Vector2(x: Float(locationInView.x),
                           y: Float(bounds.height - locationInView.y))
        mb.globalPosition = vpos
        mb.position = vpos

        mb.buttonMask = currentButtonMask()
        if !outOfStream && index == .left && pressed {
            mb.doubleClick = event.clickCount == 2
        }
        Input.parseInputEvent(mb)
    }

    func processMouseMotionEvent(event: NSEvent) {
        let mm = InputEventMouseMotion()
        mm.windowId = windowId

        let locationInView = convert(event.locationInWindow, from: nil)
        let vpos = Vector2(x: Float(locationInView.x),
                           y: Float(bounds.height - locationInView.y))
        mm.position = vpos
        mm.globalPosition = vpos

        mm.relative = Vector2(x: Float(event.deltaX), y: Float(event.deltaY))
        mm.velocity = mm.relative
        mm.buttonMask = currentButtonMask()

        if event.type == .tabletPoint || event.subtype == .tabletPoint {
            mm.pressure = Double(event.pressure)
            mm.tilt = Vector2(x: Float(event.tilt.x), y: Float(event.tilt.y))
        }

        // Cannot use Input.parseInputEvent() for mouse motion in embedded
        // mode — Viewport GUI processing calls cursor_set_shape() which
        // crashes in DisplayServerEmbedded. Forward via callback instead.
        GodotView.mouseMotionHandler?(mm)
    }

    private func currentButtonMask() -> MouseButtonMask {
        var mask: MouseButtonMask = []
        let pressed = NSEvent.pressedMouseButtons
        if pressed & (1 << 0) != 0 { mask.insert(.left) }
        if pressed & (1 << 1) != 0 { mask.insert(.right) }
        if pressed & (1 << 2) != 0 { mask.insert(.middle) }
        return mask
    }

}

private extension GodotView {
    func updateRenderingLayerGeometry() {
        guard let renderingLayer else { return }
        renderingLayer.frame = bounds
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1.0
        renderingLayer.contentsScale = scale
        renderingLayer.drawableSize = CGSize(
            width: max(1, bounds.size.width * scale),
            height: max(1, bounds.size.height * scale)
        )
    }
}

private extension GodotView {
    static func initKeyMap() -> [UInt16: Key] {
        var keymap: [UInt16: Key] = [:]
        keymap[0x00] = Key.a
        keymap[0x01] = Key.s
        keymap[0x02] = Key.d
        keymap[0x03] = Key.f
        keymap[0x04] = Key.h
        keymap[0x05] = Key.g
        keymap[0x06] = Key.z
        keymap[0x07] = Key.x
        keymap[0x08] = Key.c
        keymap[0x09] = Key.v
        keymap[0x0a] = Key.section
        keymap[0x0b] = Key.b
        keymap[0x0c] = Key.q
        keymap[0x0d] = Key.w
        keymap[0x0e] = Key.e
        keymap[0x0f] = Key.r
        keymap[0x10] = Key.y
        keymap[0x11] = Key.t
        keymap[0x12] = Key.key1
        keymap[0x13] = Key.key2
        keymap[0x14] = Key.key3
        keymap[0x15] = Key.key4
        keymap[0x16] = Key.key6
        keymap[0x17] = Key.key5
        keymap[0x18] = Key.equal
        keymap[0x19] = Key.key9
        keymap[0x1a] = Key.key7
        keymap[0x1b] = Key.minus
        keymap[0x1c] = Key.key8
        keymap[0x1d] = Key.key0
        keymap[0x1e] = Key.bracketright
        keymap[0x1f] = Key.o
        keymap[0x20] = Key.u
        keymap[0x21] = Key.bracketleft
        keymap[0x22] = Key.i
        keymap[0x23] = Key.p
        keymap[0x24] = Key.enter
        keymap[0x25] = Key.l
        keymap[0x26] = Key.j
        keymap[0x27] = Key.apostrophe
        keymap[0x28] = Key.k
        keymap[0x29] = Key.semicolon
        keymap[0x2a] = Key.backslash
        keymap[0x2b] = Key.comma
        keymap[0x2c] = Key.slash
        keymap[0x2d] = Key.n
        keymap[0x2e] = Key.m
        keymap[0x2f] = Key.period
        keymap[0x30] = Key.tab
        keymap[0x31] = Key.space
        keymap[0x32] = Key.quoteleft
        keymap[0x33] = .backspace
        keymap[0x35] = .escape
        keymap[0x36] = .meta
        keymap[0x37] = .meta
        keymap[0x38] = .shift
        keymap[0x39] = .capslock
        keymap[0x3a] = .alt
        keymap[0x3b] = .ctrl
        keymap[0x3c] = .shift
        keymap[0x3d] = .alt
        keymap[0x3e] = .ctrl
        keymap[0x40] = .f17
        keymap[0x41] = .kpPeriod
        keymap[0x43] = .kpMultiply
        keymap[0x45] = .kpAdd
        keymap[0x47] = .numlock
        keymap[0x48] = .volumeup
        keymap[0x49] = .volumedown
        keymap[0x4a] = .volumemute
        keymap[0x4b] = .kpDivide
        keymap[0x4c] = .kpEnter
        keymap[0x4e] = .kpSubtract
        keymap[0x4f] = .f18
        keymap[0x50] = .f19
        keymap[0x51] = .equal
        keymap[0x52] = .kp0
        keymap[0x53] = .kp1
        keymap[0x54] = .kp2
        keymap[0x55] = .kp3
        keymap[0x56] = .kp4
        keymap[0x57] = .kp5
        keymap[0x58] = .kp6
        keymap[0x59] = .kp7
        keymap[0x5a] = .f20
        keymap[0x5b] = .kp8
        keymap[0x5c] = .kp9
        keymap[0x5d] = .yen
        keymap[0x5e] = .underscore
        keymap[0x5f] = .comma
        keymap[0x60] = .f5
        keymap[0x61] = .f6
        keymap[0x62] = .f7
        keymap[0x63] = .f3
        keymap[0x64] = .f8
        keymap[0x65] = .f9
        keymap[0x66] = .jisEisu
        keymap[0x67] = .f11
        keymap[0x68] = .jisKana
        keymap[0x69] = .f13
        keymap[0x6a] = .f16
        keymap[0x6b] = .f14
        keymap[0x6d] = .f10
        keymap[0x6e] = .menu
        keymap[0x6f] = .f12
        keymap[0x71] = .f15
        keymap[0x72] = .insert
        keymap[0x73] = .home
        keymap[0x74] = .pageup
        keymap[0x75] = .delete
        keymap[0x76] = .f4
        keymap[0x77] = .end
        keymap[0x78] = .f2
        keymap[0x79] = .pagedown
        keymap[0x7a] = .f1
        keymap[0x7b] = .left
        keymap[0x7c] = .right
        keymap[0x7d] = .down
        keymap[0x7e] = .up
        
        return keymap
    }
    
    static func initLocationMap() -> [UInt16: KeyLocation] {
        var map = [UInt16: KeyLocation]()
        
        // ctrl
        map[0x3b] = .left
        map[0x3e] = .right
        
        // shift
        map[0x38] = .left
        map[0x3c] = .right
        
        // Alt/Option
        map[0x3a] = .left
        map[0x3d] = .right
        
        // Command
        map[0x36] = .right
        map[0x37] = .left
        
        return map
    }

}
#endif
