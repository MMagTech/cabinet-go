import SwiftUI
import UIKit
import QuartzCore


/// The native touch controls, drawn as vectors over the webview.
///
/// The touch model follows DeltaCore's approach (the approach, not the code;
/// Delta is AGPL and this project is MIT):
///
/// - Hit testing runs against each control's extended frame, which is larger
///   than what is drawn. Fingers are imprecise and games are frantic; the
///   forgiving target is what makes touch controls stop feeling like touch
///   controls.
/// - The d-pad is four overlapping rectangles, not a polar hit test. Up spans
///   the whole top band, left the whole left band, and so on, so the corners
///   belong to two directions at once and diagonals fall out of the overlap.
/// - A d-pad touch reports continuously while it moves. Sliding from up to
///   up-left is a stream of input changes, never a release and a new press.
/// - Haptics fire on every input change.
struct TouchControlPad: UIViewRepresentable {
    let items: [ControlLayout.Item]
    /// Called with a RetroArch input id and whether it is now down.
    let send: (Int, Bool) -> Void
    /// A stick's live position. Called with its four `inputs` ids, in
    /// x-positive/x-negative/y-positive/y-negative order, and the current
    /// x/y each from -1 to 1. Defaults to a no-op for layouts with no stick.
    var sendStick: (_ ids: [Int], _ x: Double, _ y: Double) -> Void = { _, _, _ in }
    /// The layout's system, for theme colours. The webview player sets
    /// this on its pad directly; this wrapper carries it for hosts that
    /// use the SwiftUI view, so both players draw the same controls.
    var system: String = ""
    /// Draw controls as moulded objects rather than flat shapes: a
    /// shadow beneath, light falling from above, a specular edge.
    /// Off by default, so every existing caller, and the local player
    /// in particular, draws byte-identically to before. Only the
    /// phone-as-controller panel turns it on, where the controls ARE
    /// the screen and there is no game for them to sit politely
    /// beside.
    var material: Bool = false
    /// The visibility slider's value, applied as UIKit alpha on the view
    /// itself, exactly as the webview player's overlay does (`pad.alpha`).
    /// Never apply SwiftUI `.opacity()` to this view instead: on iOS 26 a
    /// partially transparent representable overlaying a Metal view gets
    /// flattened into the composited layer and stops receiving touches,
    /// which killed every landscape control in the native player while
    /// portrait, whose pad overlays nothing, kept working. UIKit alpha
    /// only stops touch delivery below 0.01, and the slider floors at 25%.
    var opacity: Double = 1

    func makeUIView(context: Context) -> ControlPadView {
        let view = ControlPadView(items: items, send: send, sendStick: sendStick)
        view.backgroundColor = .clear
        view.isMultipleTouchEnabled = true
        return view
    }

    func updateUIView(_ view: ControlPadView, context: Context) {
        view.items = items
        view.material = material
        view.system = system
        view.theme = ControlTheme.current
        view.alpha = opacity
    }
}

final class ControlPadView: UIView {
    var items: [ControlLayout.Item] {
        didSet { setNeedsDisplay() }
    }
    /// The layout's system, which decides what colours the controls take:
    /// a Neo Geo panel and a Game Boy do not look alike.
    var material: Bool = false { didSet { setNeedsDisplay() } }
    var system: String = "" {
        didSet { if system != oldValue { setNeedsDisplay() } }
    }
    var theme: ControlTheme = .system {
        didSet { if theme != oldValue { setNeedsDisplay() } }
    }

    private let send: (Int, Bool) -> Void
    private let sendStick: (_ ids: [Int], _ x: Double, _ y: Double) -> Void
    private let haptic = UIImpactFeedbackGenerator(style: .light)

    /// Inputs currently held down, across all touches.
    private var pressed: Set<Int> = []
    /// What each live touch is contributing. A d-pad touch owns several.
    private var touchInputs: [UITouch: Set<Int>] = [:]
    /// The one touch currently dragging the stick, if any: only one stick
    /// ever appears in a layout, so only one touch can own it.
    private var stickTouch: UITouch?
    /// The stick's current position, -1 to 1 on each axis, for drawing the
    /// knob and for zeroing on release.
    private var stickPosition: CGPoint = .zero

    init(
        items: [ControlLayout.Item], send: @escaping (Int, Bool) -> Void,
        sendStick: @escaping (_ ids: [Int], _ x: Double, _ y: Double) -> Void = { _, _, _ in }
    ) {
        self.items = items
        self.send = send
        self.sendStick = sendStick
        super.init(frame: .zero)
        contentMode = .redraw
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Redraw whenever the view is resized. Without this the controls keep
    /// the geometry they were first laid out with, so a rotation moves the
    /// view but not the controls inside it.
    override func layoutSubviews() {
        super.layoutSubviews()
        setNeedsDisplay()
    }

    /// Touches land here only inside a control's extended frame. Everything
    /// else passes through to the webview underneath, which matters in
    /// landscape where this view overlays the whole screen: taps on the game
    /// canvas still wake the overlay and reach EmulatorJS's menu button.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        items.contains { $0.extended.resolved(in: bounds.size).contains(point) }
    }

    // MARK: Touch handling

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            let point = touch.location(in: self)
            if stickTouch == nil, let stick = stickItem(at: point) {
                stickTouch = touch
                updateStick(stick, at: point)
                continue
            }
            touchInputs[touch] = inputs(at: point)
        }
        reconcile()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            if touch == stickTouch, let stick = items.first(where: { $0.kind == .stick }) {
                updateStick(stick, at: touch.location(in: self))
                continue
            }
            if touchInputs[touch] != nil {
                touchInputs[touch] = inputs(at: touch.location(in: self))
            }
        }
        reconcile()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            if touch == stickTouch {
                stickTouch = nil
                stickPosition = .zero
                if let stick = items.first(where: { $0.kind == .stick }), let ids = stick.inputs, ids.count == 4 {
                    sendStick(ids, 0, 0)
                }
                setNeedsDisplay()
                continue
            }
            touchInputs[touch] = nil
        }
        reconcile()
    }

    /// The stick item whose extended frame contains this point, if any.
    private func stickItem(at point: CGPoint) -> ControlLayout.Item? {
        items.first { $0.kind == .stick && $0.extended.resolved(in: bounds.size).contains(point) }
    }

    /// A stick's position is its offset from its own frame's center, capped
    /// to the frame's half-extent so it cannot report beyond fully deflected,
    /// then sent through as a magnitude the way EmulatorJS's own stick does.
    private func updateStick(_ stick: ControlLayout.Item, at point: CGPoint) {
        guard let ids = stick.inputs, ids.count == 4 else { return }
        let frame = stick.frame.resolved(in: bounds.size)
        let dx = (point.x - frame.midX) / (frame.width / 2)
        let dy = (point.y - frame.midY) / (frame.height / 2)
        let magnitude = min(1, (dx * dx + dy * dy).squareRoot())
        let angle = atan2(dy, dx)
        let x = magnitude == 0 ? 0 : cos(angle) * magnitude
        let y = magnitude == 0 ? 0 : sin(angle) * magnitude
        // touchesMoved arrives per display refresh, up to 120Hz, and a
        // thumb held "still" jitters by fractions of a point. Below 1.5%
        // of full deflection the game cannot tell the difference, so skip
        // the JS call and the redraw both, or a held stick streams
        // identical messages into the webview for as long as it is held.
        let previous = stickPosition
        guard abs(x - previous.x) > 0.015 || abs(y - previous.y) > 0.015 else { return }
        stickPosition = CGPoint(x: x, y: y)
        // No sign flip: EmulatorJS's own y-positive slot is confirmed to
        // mean "down", not "up", by N64's C-buttons, whose analog indices
        // follow the same four slot pattern and are independently confirmed
        // against source (C-Down sits in the y-positive slot). That matches
        // screen y, which already grows downward, so the raw touch delta is
        // exactly the value to send, no conversion needed.
        sendStick(ids, Double(x), Double(y))
        // Only the stick's own frame needs repainting, not every control
        // on the pad: in landscape this view spans the whole screen, and
        // a full-view redraw per touch sample repainted all of it.
        setNeedsDisplay(stick.frame.resolved(in: bounds.size).insetBy(dx: -20, dy: -20))
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        touchesEnded(touches, with: event)
    }

    /// The inputs a touch at this point should be holding.
    ///
    /// A d-pad's four bands are meant to overlap: a corner touch reporting
    /// both an up and a right is the diagonal, not a mistake. Two separate
    /// buttons overlapping is a different situation, an accident of two
    /// generous extended frames sitting close together, and reporting both
    /// is exactly the double press this was built to prevent. So buttons
    /// and pills resolve to whichever one's center is nearest, one winner
    /// only, while the d-pad keeps its own overlap untouched.
    private func inputs(at point: CGPoint) -> Set<Int> {
        var held: Set<Int> = []
        var nearestButton: (id: Int, distance: CGFloat)?

        for item in items {
            let extended = item.extended.resolved(in: bounds.size)
            guard extended.contains(point) else { continue }

            switch item.kind {
            case .dpad:
                guard let ids = item.inputs, ids.count == 4 else { break }
                let unit = CGPoint(
                    x: (point.x - extended.minX) / extended.width,
                    y: (point.y - extended.minY) / extended.height
                )

                if item.fourWay == true {
                    // Four way sticks report one direction only, whichever
                    // axis the thumb is furthest along. Pac-Man corners
                    // depend on never seeing a diagonal.
                    let dx = unit.x - 0.5
                    let dy = unit.y - 0.5
                    guard abs(dx) > 0.10 || abs(dy) > 0.10 else { break }
                    if abs(dx) > abs(dy) {
                        held.insert(dx < 0 ? ids[2] : ids[3])
                    } else {
                        held.insert(dy < 0 ? ids[0] : ids[1])
                    }
                } else {
                    // Four overlapping bands inside the extended frame. A
                    // point in a corner sits in two bands, which is exactly
                    // the diagonal.
                    if unit.y < 0.40 { held.insert(ids[0]) }   // up
                    if unit.y > 0.60 { held.insert(ids[1]) }   // down
                    if unit.x < 0.40 { held.insert(ids[2]) }   // left
                    if unit.x > 0.60 { held.insert(ids[3]) }   // right
                }
            case .button, .pill:
                guard let id = item.input else { break }
                let frame = item.frame.resolved(in: bounds.size)
                let dx = point.x - frame.midX
                let dy = point.y - frame.midY
                let distance = dx * dx + dy * dy
                if nearestButton == nil || distance < nearestButton!.distance {
                    nearestButton = (id, distance)
                }
            case .stick:
                // Handled separately: claimed by a touch in touchesBegan
                // and tracked through its own update path, not through
                // this digital held-id path.
                break
            }
        }
        if let nearestButton {
            held.insert(nearestButton.id)
        }
        return held
    }

    /// Diffs the union of all touches against what the emulator believes,
    /// sends only the changes, and pulses haptics when anything changed.
    private func reconcile() {
        let now = touchInputs.values.reduce(into: Set<Int>()) { $0.formUnion($1) }
        let downs = now.subtracting(pressed)
        let ups = pressed.subtracting(now)
        guard !downs.isEmpty || !ups.isEmpty else { return }

        for id in downs { send(id, true) }
        for id in ups { send(id, false) }
        pressed = now

        haptic.impactOccurred(intensity: downs.isEmpty ? 0.6 : 1.0)
        setNeedsDisplay()
    }

    // MARK: Drawing

    override func draw(_ rect: CGRect) {
        for item in items {
            let frame = item.frame.resolved(in: bounds.size)
            let tint = theme.tint(system: system, input: item.input)
            switch item.kind {
            case .dpad:
                let dpadTint = theme.tint(system: system, input: item.inputs?.first)
                drawDpad(in: frame, inputs: item.inputs ?? [], label: item.label, tint: dpadTint)
            case .button:
                drawRoundButton(
                    in: frame, label: item.label, tint: tint,
                    active: item.input.map(pressed.contains) ?? false
                )
            case .pill:
                drawPill(
                    in: frame, label: item.label, tint: tint,
                    active: item.input.map(pressed.contains) ?? false
                )
            case .stick:
                drawStick(in: frame)
            }
        }
    }

    private func drawStick(in frame: CGRect) {
        let radius = min(frame.width, frame.height) / 2
        let center = CGPoint(x: frame.midX, y: frame.midY)
        let active = stickTouch != nil
        let colors = style(active: active)

        let base = UIBezierPath(arcCenter: center, radius: radius, startAngle: 0, endAngle: .pi * 2, clockwise: true)
        if material {
            // A stick sits IN its housing, so the base is the one part
            // of a panel that goes the other way: sunk rather than
            // raised, lit from below because the far wall of a dish is
            // what catches the light. The knob on top is moulded like
            // everything else, which is what makes the pair read as an
            // object standing in a well.
            fillSunken(base, fill: colors.fill)
        } else {
            colors.fill.setFill()
            base.fill()
            colors.stroke.setStroke()
            base.lineWidth = 1.5
            base.stroke()
        }

        let knobRadius = radius * 0.42
        let knobCenter = CGPoint(
            x: center.x + stickPosition.x * (radius - knobRadius),
            y: center.y + stickPosition.y * (radius - knobRadius)
        )
        let knob = UIBezierPath(arcCenter: knobCenter, radius: knobRadius, startAngle: 0, endAngle: .pi * 2, clockwise: true)
        let knobFill = UIColor.white.withAlphaComponent(active ? 0.85 : 0.55)
        if material {
            fillMoulded(knob, fill: knobFill, active: active)
        } else {
            knobFill.setFill()
            knob.fill()
        }
    }

    /// Labels sit on colour rather than on the game, so they need to be
    /// solid: the translucent white that reads well over dark art disappears
    /// against a yellow button.
    private func labelColor(tint: UIColor?) -> UIColor {
        tint == nil ? UIColor.white.withAlphaComponent(0.75) : UIColor.white
    }

    /// Every control gets a contrasting outline regardless of theme, or it
    /// vanishes over bright or dark game content. A tinted control keeps the
    /// white outline for exactly that reason and carries its colour in the
    /// fill, which is what a glance reads anyway.
    private func style(active: Bool, tint: UIColor? = nil) -> (fill: UIColor, stroke: UIColor) {
        guard let tint else {
            return (
                fill: UIColor.white.withAlphaComponent(active ? 0.45 : 0.14),
                stroke: UIColor.white.withAlphaComponent(0.55)
            )
        }
        // Colour needs far more presence than white to survive: the whole
        // pad carries the visibility slider's alpha on top of this, so a
        // third of a colour under a further 70 percent reads as mud rather
        // than as red. Nearly solid when held, so a press is unmistakable in
        // peripheral vision.
        return (
            fill: tint.withAlphaComponent(active ? 0.95 : 0.62),
            stroke: UIColor.white.withAlphaComponent(0.55)
        )
    }

    private func drawDpad(in frame: CGRect, inputs: [Int], label: String? = nil, tint: UIColor? = nil) {
        // A d-pad is square. Every real one ever made is, and a thumb
        // rolling between up and left expects the same travel either
        // way. The cross used to fill whatever rect it was given, so
        // it inherited the frame's aspect AND the screen's: snes is
        // authored 0.19 by 0.42, which is square on a screen with no
        // safe-area insets and 16% taller once the drawing area is
        // inset to 773x407, which is what Marcus saw and measured.
        // Fitting a square inside the frame makes a d-pad the same
        // shape on every phone, whatever the layout says and whatever
        // the insets do.
        // Area-preserving rather than fitted inside: the frame was
        // never a deliberate box, it was a d-pad drawn to a size that
        // happened to render oblong, so keeping the weight the author
        // chose is closer to the intent than keeping a rectangle
        // nobody picked. Comes out 159pt where fitting inside gave
        // 147. Checked against every layout: no d-pad at this size
        // touches a neighbouring control.
        let side = (frame.width * frame.height).squareRoot()
        let frame = CGRect(
            x: frame.midX - side / 2, y: frame.midY - side / 2,
            width: side, height: side)
        let armThickness = frame.width * 0.34
        let cross = UIBezierPath()

        // One cross path: horizontal bar plus vertical bar.
        let horizontal = CGRect(
            x: frame.minX,
            y: frame.midY - armThickness / 2,
            width: frame.width,
            height: armThickness
        )
        let vertical = CGRect(
            x: frame.midX - armThickness / 2,
            y: frame.minY,
            width: armThickness,
            height: frame.height
        )
        cross.append(UIBezierPath(roundedRect: horizontal, cornerRadius: 6))
        cross.append(UIBezierPath(roundedRect: vertical, cornerRadius: 6))

        let anyActive = inputs.contains(where: pressed.contains)
        let colors = style(active: anyActive, tint: tint)
        if material {
            // usesEvenOddFillRule matters here: the cross is two
            // overlapping rounded rects, and the moulded fill draws
            // the path once rather than twice.
            cross.usesEvenOddFillRule = false
            fillMoulded(cross, fill: colors.fill, active: anyActive)
        } else {
            colors.fill.setFill()
            cross.fill()
        }
        if !material {
            colors.stroke.setStroke()
            cross.lineWidth = 1.5
            cross.stroke()
        }

        // A cluster distinct enough from the real d-pad to name (N64's C
        // buttons, tinted yellow) gets its label centred over the cross,
        // rather than one arm, since no single direction owns it.
        if let label {
            drawLabel(
                label, in: frame, fontSize: armThickness * 0.55,
                color: labelColor(tint: tint)
            )
        }

        // A subtle nub on the pressed direction, so the pad reads as alive.
        guard inputs.count == 4 else { return }
        let nubs: [(Int, CGPoint)] = [
            (inputs[0], CGPoint(x: frame.midX, y: frame.minY + armThickness / 2)),
            (inputs[1], CGPoint(x: frame.midX, y: frame.maxY - armThickness / 2)),
            (inputs[2], CGPoint(x: frame.minX + armThickness / 2, y: frame.midY)),
            (inputs[3], CGPoint(x: frame.maxX - armThickness / 2, y: frame.midY)),
        ]
        for (id, center) in nubs where pressed.contains(id) {
            let nub = UIBezierPath(
                arcCenter: center, radius: armThickness * 0.22,
                startAngle: 0, endAngle: .pi * 2, clockwise: true
            )
            UIColor.white.withAlphaComponent(0.8).setFill()
            nub.fill()
        }
    }

    /// Fills a control so it stands off the panel: a side wall you can
    /// actually see, a tight contact shadow at its base, a lit face,
    /// and a soft edge along the top.
    ///
    /// The first attempt lit the face and cast a soft shadow and
    /// Marcus's verdict was that the controls still had no height. He
    /// was right, and the reason is that a dark canvas cannot receive
    /// a dark shadow: black on near-black is invisible, so the whole
    /// depth cue was doing nothing. Height on a dark ground has to be
    /// DRAWN rather than shaded, which is what the side wall below is,
    /// a darker copy of the shape offset downward, so the control
    /// reads as an object with a thickness rather than a disc lying
    /// flat. Pressing collapses that wall, which is a real key going
    /// down rather than a colour changing.
    private func fillMoulded(_ path: UIBezierPath, fill: UIColor, active: Bool) {
        guard let ctx = UIGraphicsGetCurrentContext() else {
            fill.setFill(); path.fill(); return
        }
        // Depth in points. Overshot to 8 while proving the effect was
        // working at all, which it now visibly is, so pulled back to
        // where a control reads as raised rather than as stacked. The
        // press depth stays near zero: the collapse is what sells it.
        let depth: CGFloat = active ? 1 : 4

        // The side wall: the shape again, below, in the fill's own
        // colour taken well down. Its own colour rather than black, so
        // a green button has a green edge and still reads as one piece.
        //
        // SOLID, and that is the whole trick. The fills these controls
        // use are translucent by design (14% white for an untinted
        // one, so a game shows through underneath), and the first
        // version inherited that alpha for the wall: 14% of a dark
        // colour on a dark panel is nothing at all, which is exactly
        // why Marcus saw no height. A panel has no game behind it, so
        // its walls can be opaque, and an opaque edge is the only part
        // of this that a dark ground can actually show.
        var hue: CGFloat = 0, sat: CGFloat = 0, bri: CGFloat = 0, alpha: CGFloat = 0
        let wall: UIColor = fill.getHue(&hue, saturation: &sat, brightness: &bri, alpha: &alpha)
            ? UIColor(hue: hue, saturation: min(sat * 1.2, 1),
                      brightness: max(bri * 0.42, 0.10), alpha: 1)
            : UIColor(white: 0.14, alpha: 1)
        ctx.saveGState()
        let side = path.copy() as! UIBezierPath
        side.apply(CGAffineTransform(translationX: 0, y: depth))
        // A tight contact shadow under the wall. Tight on purpose: a
        // wide soft one dissolves into a dark panel and says nothing.
        ctx.setShadow(
            offset: CGSize(width: 0, height: active ? 1 : 2),
            blur: active ? 2 : 4,
            color: UIColor.black.withAlphaComponent(0.7).cgColor)
        wall.setFill()
        side.fill()
        ctx.restoreGState()

        // A hairline of the wall's colour just inside the face, so the
        // join between the two is a turned edge rather than a step.
        // The face, sitting on top of its own wall, and opaque for the
        // same reason: a translucent face lets its own wall show
        // through and the object flattens back out. The alpha these
        // fills carry is for sitting over a game, which a panel does
        // not have.
        var fr: CGFloat = 0, fg: CGFloat = 0, fb: CGFloat = 0, fa: CGFloat = 0
        let solidFace: UIColor = fill.getRed(&fr, green: &fg, blue: &fb, alpha: &fa)
            ? UIColor(red: fr, green: fg, blue: fb, alpha: 1)
            : fill
        // Untinted controls fill at 14% white, which is nearly the
        // panel itself once opaque; lift those so a grey control has
        // any presence at all.
        let face = fa < 0.5
            ? UIColor(white: 0.30 + Double(fa) * 0.4, alpha: 1)
            : solidFace
        face.setFill()
        path.fill()
        ctx.saveGState()
        ctx.addPath(path.cgPath)
        ctx.clip()
        wall.withAlphaComponent(0.55).setStroke()
        path.lineWidth = 2.2
        path.stroke()
        ctx.restoreGState()

        // Light from above, fixed. A light that moved with the phone
        // was tried and looked wrong to Marcus; a real handheld thing
        // is lit by the room, and the room does not swing.
        ctx.saveGState()
        ctx.addPath(path.cgPath)
        ctx.clip()
        let top = UIColor.white.withAlphaComponent(active ? 0.02 : 0.16).cgColor
        let mid = UIColor.white.withAlphaComponent(active ? 0.0 : 0.04).cgColor
        let bottom = UIColor.black.withAlphaComponent(active ? 0.34 : 0.24).cgColor
        let stops: [CGColor] = active
            ? [bottom, UIColor.clear.cgColor, mid, top]
            : [top, mid, UIColor.clear.cgColor, bottom]
        if let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: stops as CFArray, locations: [0, 0.35, 0.62, 1]) {
            let b = path.bounds
            ctx.drawLinearGradient(
                gradient,
                start: CGPoint(x: b.midX, y: b.minY),
                end: CGPoint(x: b.midX, y: b.maxY),
                options: [])
        }
        ctx.restoreGState()

        // A soft rim along the top edge, feathered over three passes:
        // one crisp stroke read as a hard band painted across the face.
        if !active {
            ctx.saveGState()
            ctx.addPath(path.cgPath)
            ctx.clip()
            let edge = path.copy() as! UIBezierPath
            edge.apply(CGAffineTransform(translationX: 0, y: 1.2))
            for (width, a) in [(3.4, 0.04), (2.2, 0.07), (1.2, 0.11)] {
                UIColor.white.withAlphaComponent(a).setStroke()
                edge.lineWidth = width
                edge.stroke()
            }
            ctx.restoreGState()
        }
    }

    /// The inverse of `fillMoulded`, for the parts of a panel that are
    /// holes rather than objects: a stick's housing, a trackball's
    /// well. Darker than the panel, its shadow cast inward from the
    /// near rim, lit along the far one.
    private func fillSunken(_ path: UIBezierPath, fill: UIColor) {
        guard let ctx = UIGraphicsGetCurrentContext() else {
            fill.setFill(); path.fill(); return
        }
        UIColor(white: 0.055, alpha: 1).setFill()
        path.fill()
        ctx.saveGState()
        ctx.addPath(path.cgPath)
        ctx.clip()
        let b = path.bounds
        if let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [UIColor.black.withAlphaComponent(0.75).cgColor,
                     UIColor.clear.cgColor,
                     UIColor.white.withAlphaComponent(0.10).cgColor] as CFArray,
            locations: [0, 0.45, 1]) {
            ctx.drawLinearGradient(
                gradient,
                start: CGPoint(x: b.midX, y: b.minY),
                end: CGPoint(x: b.midX, y: b.maxY), options: [])
        }
        ctx.restoreGState()
    }


    private func drawRoundButton(in frame: CGRect, label: String?, tint: UIColor?, active: Bool) {
        let diameter = min(frame.width, frame.height)
        let circleRect = CGRect(
            x: frame.midX - diameter / 2,
            y: frame.midY - diameter / 2,
            width: diameter,
            height: diameter
        )
        let circle = UIBezierPath(ovalIn: circleRect)
        let colors = style(active: active, tint: tint)
        if material {
            fillMoulded(circle, fill: colors.fill, active: active)
        } else {
            colors.fill.setFill()
            circle.fill()
        }
        // No outline on a moulded control. A hard bright line around
        // an opaque object is what makes it read as cut out and stuck
        // on rather than formed, which is what Marcus saw once the
        // height started working. The wall, the shading and the rim
        // already say where the edge is. The stroke stays for the
        // translucent controls, where it is the only thing separating
        // them from the game behind.
        if !material {
            colors.stroke.setStroke()
            circle.lineWidth = 1.5
            circle.stroke()
        }

        drawLabel(label, in: circleRect, fontSize: diameter * 0.34, color: labelColor(tint: tint))
    }

    private func drawPill(in frame: CGRect, label: String?, tint: UIColor?, active: Bool) {
        let pill = UIBezierPath(roundedRect: frame, cornerRadius: frame.height / 2)
        let colors = style(active: active, tint: tint)
        if material {
            fillMoulded(pill, fill: colors.fill, active: active)
        } else {
            colors.fill.setFill()
            pill.fill()
        }
        if !material {
            colors.stroke.setStroke()
            pill.lineWidth = 1.5
            pill.stroke()
        }

        drawLabel(label, in: frame, fontSize: frame.height * 0.42, color: labelColor(tint: tint))
    }

    private func drawLabel(
        _ label: String?, in rect: CGRect, fontSize: CGFloat, color: UIColor
    ) {
        guard let label else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: fontSize, weight: .semibold),
            .foregroundColor: color,
        ]
        let size = label.size(withAttributes: attributes)
        label.draw(
            at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2),
            withAttributes: attributes
        )
    }
}
