import AppKit
import SwiftUI

/// Uses the private SkyLight window server API to put a window in a space that sits above the lock screen
/// (the same trick lock-screen widget apps use). Falls back to a normal high-level window if unavailable.
enum SkyLight {
    private typealias MainConnection = @convention(c) () -> Int32
    private typealias SpaceCreate = @convention(c) (Int32, Int32, Int32) -> Int32
    private typealias SpaceSetAbsoluteLevel = @convention(c) (Int32, Int32, Int32) -> Int32
    private typealias ShowSpaces = @convention(c) (Int32, CFArray) -> Int32
    private typealias AddWindows = @convention(c) (Int32, Int32, CFArray, Int32) -> Int32

    /// Absolute space levels: 100 setup assistant, 200 security agent, 300 screen lock,
    /// 400 notification center at screen lock (the first level drawn *above* the lock screen).
    private static let aboveLockScreenLevel: Int32 = 400

    private static let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight", RTLD_NOW)
    private static var space: Int32 = 0

    private static func sym<T>(_ name: String, as: T.Type) -> T? {
        guard let handle, let p = dlsym(handle, name) else { return nil }
        return unsafeBitCast(p, to: T.self)
    }

    @discardableResult
    static func moveAboveLockScreen(_ window: NSWindow) -> Bool {
        guard let mainConnection = sym("SLSMainConnectionID", as: MainConnection.self),
              let create = sym("SLSSpaceCreate", as: SpaceCreate.self),
              let setLevel = sym("SLSSpaceSetAbsoluteLevel", as: SpaceSetAbsoluteLevel.self),
              let show = sym("SLSShowSpaces", as: ShowSpaces.self),
              let add = sym("SLSSpaceAddWindowsAndRemoveFromSpaces", as: AddWindows.self) else { return false }
        let cid = mainConnection()
        if space == 0 {
            space = create(cid, 1, 0)
            let r1 = setLevel(cid, space, aboveLockScreenLevel)
            let r2 = show(cid, [NSNumber(value: space)] as CFArray)
            Log.write("SkyLight space \(space) created (setLevel=\(r1) show=\(r2))")
        }
        let r = add(cid, space, [NSNumber(value: window.windowNumber)] as CFArray, 7)
        if r != 0 { Log.write("SkyLight add window failed: \(r)") }
        return true
    }
}

final class OverlayModel: ObservableObject {
    enum Phase { case scanning, blink, success, failed }
    @Published var phase: Phase = .scanning
    @Published var name: String = ""
    @Published var blinkCaption = BlinkStrength.regular.caption
    @Published var expanded = false
    /// Size of the camera notch on the screen we're shown on; `.zero` when there is no notch.
    @Published var notchSize: CGSize = .zero
}

// MARK: - Face ID glyph

/// The four rounded corner brackets of the Face ID symbol.
struct FaceBrackets: Shape {
    func path(in r: CGRect) -> Path {
        let w = r.width, L = w * 0.30, rad = w * 0.13
        var p = Path()
        func corner(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) {
            p.move(to: a)
            p.addArc(tangent1End: b, tangent2End: c, radius: rad)
            p.addLine(to: c)
        }
        let x0 = r.minX, y0 = r.minY, x1 = r.maxX, y1 = r.maxY
        corner(CGPoint(x: x0, y: y0 + L), CGPoint(x: x0, y: y0), CGPoint(x: x0 + L, y: y0))
        corner(CGPoint(x: x1 - L, y: y0), CGPoint(x: x1, y: y0), CGPoint(x: x1, y: y0 + L))
        corner(CGPoint(x: x1, y: y1 - L), CGPoint(x: x1, y: y1), CGPoint(x: x1 - L, y: y1))
        corner(CGPoint(x: x0 + L, y: y1), CGPoint(x: x0, y: y1), CGPoint(x: x0, y: y1 - L))
        return p
    }
}

/// Eyes, nose and smile. `look` shifts them sideways (-1…1) so the face appears to glance around.
struct FaceFeatures: Shape {
    var look: CGFloat
    var eyeOpen: CGFloat = 1

    func path(in r: CGRect) -> Path {
        let w = r.width, h = r.height
        let dx = look * w * 0.06
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: r.minX + x * w + dx, y: r.minY + y * h) }
        var p = Path()
        let eyeTop = 0.40 - 0.045 * eyeOpen, eyeBottom = 0.40 + 0.045 * eyeOpen
        for x in [0.34, 0.66] {
            p.move(to: pt(x, eyeTop)); p.addLine(to: pt(x, eyeBottom))
        }
        p.move(to: pt(0.51, 0.38)); p.addLine(to: pt(0.51, 0.57)); p.addLine(to: pt(0.46, 0.57))
        p.move(to: pt(0.34, 0.69))
        p.addQuadCurve(to: pt(0.66, 0.69), control: pt(0.50, 0.80))
        return p
    }
}

struct CheckShape: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX + r.width * 0.24, y: r.minY + r.height * 0.53))
        p.addLine(to: CGPoint(x: r.minX + r.width * 0.42, y: r.minY + r.height * 0.71))
        p.addLine(to: CGPoint(x: r.minX + r.width * 0.78, y: r.minY + r.height * 0.31))
        return p
    }
}

/// Face ID glyph that looks around while scanning, becomes a spinning ring, then draws a checkmark.
struct FaceIDGlyph: View {
    let phase: OverlayModel.Phase
    var lineWidth: CGFloat = 5

    enum Stage { case face, spinner, check }
    @State private var stage: Stage = .face
    @State private var checkTrim: CGFloat = 0
    @State private var sequence = 0

    var body: some View {
        let style = StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
        TimelineView(.animation) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            let scanning = stage == .face && (phase == .scanning || phase == .blink)
            // Blink phase: the glyph blinks too, as a hint.
            let blinkCycle = t.truncatingRemainder(dividingBy: 1.6)
            let eye: CGFloat = phase == .blink && blinkCycle < 0.18 ? 0.1 : 1
            ZStack {
                FaceBrackets()
                    .stroke(Color.white, style: style)
                    .scaleEffect(stage == .face ? 1 + (scanning ? 0.04 * CGFloat(sin(t * 4.5)) : 0) : 0.55)
                    .opacity(stage == .face ? 1 : 0)
                FaceFeatures(look: scanning && phase == .scanning ? CGFloat(sin(t * 2.4)) : 0, eyeOpen: eye)
                    .stroke(Color.white, style: style)
                    .opacity(stage == .face ? 1 : 0)
                    .scaleEffect(stage == .face ? 1 : 0.4)
                Circle()
                    .stroke(Color.white, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, dash: [0.1, lineWidth * 2.2]))
                    .rotationEffect(.radians(t * 6))
                    .scaleEffect(stage == .spinner ? 0.86 : (stage == .face ? 1.3 : 0.6))
                    .opacity(stage == .spinner ? 1 : 0)
                CheckShape()
                    .trim(from: 0, to: checkTrim)
                    .stroke(Color.white, style: StrokeStyle(lineWidth: lineWidth * 1.2, lineCap: .round, lineJoin: .round))
            }
        }
        .onAppear { run(phase) }
        .onChange(of: phase) { _, p in run(p) }
    }

    private func run(_ p: OverlayModel.Phase) {
        sequence += 1
        let seq = sequence
        guard p == .success else {
            withAnimation(.easeOut(duration: 0.2)) { stage = .face; checkTrim = 0 }
            return
        }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { stage = .spinner }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            guard seq == sequence else { return }
            withAnimation(.easeOut(duration: 0.15)) { stage = .check }
            withAnimation(.easeOut(duration: 0.3).delay(0.05)) { checkTrim = 1 }
        }
    }
}

// MARK: - Island

/// Dynamic-Island style panel: grows out of the notch (or drops in as a pill on Macs without one).
struct IslandView: View {
    @ObservedObject var model: OverlayModel
    @State private var shake: CGFloat = 0

    static let canvas = CGSize(width: 360, height: 300)

    private var hasNotch: Bool { model.notchSize != .zero }
    private var topInset: CGFloat { hasNotch ? model.notchSize.height : 0 }
    private var collapsedSize: CGSize { hasNotch ? model.notchSize : CGSize(width: 120, height: 34) }
    private var expandedSize: CGSize { CGSize(width: 200, height: 186 + topInset) }

    private var caption: String {
        switch model.phase {
        case .scanning: return "Face ID"
        case .blink: return model.blinkCaption
        case .success: return model.name.isEmpty ? "Unlocked" : "Hi, \(model.name)"
        case .failed: return "Face Not Recognized"
        }
    }

    var body: some View {
        let open = model.expanded
        let size = open ? expandedSize : collapsedSize
        let bottom: CGFloat = open ? 46 : (hasNotch ? 9 : 17)
        let top: CGFloat = hasNotch ? 0 : bottom

        ZStack(alignment: .top) {
            UnevenRoundedRectangle(topLeadingRadius: top, bottomLeadingRadius: bottom,
                                   bottomTrailingRadius: bottom, topTrailingRadius: top, style: .continuous)
                .fill(Color.black)
                .frame(width: size.width, height: size.height)
                .shadow(color: .black.opacity(hasNotch ? 0 : 0.35), radius: 12, y: 4)

            if open {
                VStack(spacing: 14) {
                    FaceIDGlyph(phase: model.phase)
                        .frame(width: 82, height: 82)
                    Text(caption)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(1)
                        .contentTransition(.opacity)
                }
                .padding(.top, topInset + 30)
                .transition(.asymmetric(insertion: .opacity.animation(.easeIn(duration: 0.2).delay(0.12)),
                                        removal: .opacity.animation(.easeOut(duration: 0.1))))
            }
        }
        .offset(x: shake)
        .opacity(hasNotch || open ? 1 : 0)
        .padding(.top, hasNotch ? 0 : 10)
        .frame(width: Self.canvas.width, height: Self.canvas.height, alignment: .top)
        .animation(.spring(response: 0.42, dampingFraction: 0.74), value: open)
        .animation(.easeInOut(duration: 0.2), value: model.phase)
        .onChange(of: model.phase) { _, phase in
            guard phase == .failed else { return }
            let steps: [CGFloat] = [14, -12, 9, -6, 3, 0]
            for (i, x) in steps.enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.07) {
                    withAnimation(.easeInOut(duration: 0.07)) { shake = x }
                }
            }
        }
    }
}

// MARK: - Window

private final class IslandPanel: NSPanel {
    // Let the panel sit over the menu bar / notch area instead of being pushed below it.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class OverlayController {
    let model = OverlayModel()
    private var panel: NSPanel?
    private var generation = 0

    func show() {
        generation += 1
        let panel = self.panel ?? makePanel()
        self.panel = panel

        // Prefer the built-in display with a notch.
        let screen = NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens[0]
        model.notchSize = Self.notchSize(of: screen)
        let c = IslandView.canvas
        panel.setFrame(NSRect(x: screen.frame.midX - c.width / 2, y: screen.frame.maxY - c.height,
                              width: c.width, height: c.height), display: false)

        if panel.isVisible && panel.alphaValue > 0 && model.expanded {
            return
        }
        model.expanded = false
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        SkyLight.moveAboveLockScreen(panel)
        Log.write("Island shown (notch: \(model.notchSize))")
        let g = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self, g == self.generation else { return }
            self.model.expanded = true
        }
    }

    func hide(after delay: TimeInterval = 0) {
        let g = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, g == self.generation else { return }
            self.model.expanded = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { [weak self] in
                guard let self, g == self.generation else { return }
                self.panel?.alphaValue = 0
            }
        }
    }

    static func notchSize(of screen: NSScreen) -> CGSize {
        guard screen.safeAreaInsets.top > 0,
              let l = screen.auxiliaryTopLeftArea, let r = screen.auxiliaryTopRightArea else { return .zero }
        return CGSize(width: screen.frame.width - l.width - r.width, height: screen.safeAreaInsets.top)
    }

    /// Create the window and its above-lock-screen space up front, while the Mac is unlocked.
    func prepare() {
        guard panel == nil else { return }
        let p = makePanel()
        panel = p
        p.alphaValue = 0
        p.orderFrontRegardless()
        SkyLight.moveAboveLockScreen(p)
    }

    private func makePanel() -> NSPanel {
        let c = IslandView.canvas
        let panel = IslandPanel(contentRect: NSRect(origin: .zero, size: c),
                                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = NSWindow.Level(rawValue: Int(Int32.max - 2))
        panel.canBecomeVisibleWithoutLogin = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: IslandView(model: model))
        host.frame = NSRect(origin: .zero, size: c)
        panel.contentView = host
        return panel
    }
}
