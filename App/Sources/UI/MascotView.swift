import SwiftUI
import AppKit
import AgentBarCore

// The owner's personal mascot: shown by the bar while no agent session exists (collapsed in the notch circle, expanded in a
// small panel) and as live preview in Settings > Mascot. It lives like an idle blob (breathing, blinking, glances, small
// gestures, sleep after BarTheme.idleSleepAfter) but belongs to no session, so it brings its own clock and seed.

extension BlobKind {
    /// Where the body's top edge sits (fraction of height); accessories attach there.
    fileprivate var topInset: CGFloat {
        switch self {
        case .circle: return 0.0
        case .roundedSquare: return 0.04
        case .cloud: return 0.13
        case .drop: return 0.02
        case .triangle: return 0.18
        }
    }
}

/// Eye shapes that are not plain capsules.
private struct HalfEye: Shape {   // flat top, round bottom: a drowsy half-closed eye
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        p.addCurve(to: CGPoint(x: r.minX, y: r.minY), control1: CGPoint(x: r.maxX, y: r.maxY + r.height * 0.35),
                   control2: CGPoint(x: r.minX, y: r.maxY + r.height * 0.35))
        p.closeSubpath()
        return p
    }
}

private struct ArcEye: Shape {   // "^": a happy closed eye
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.maxY), control: CGPoint(x: r.midX, y: 2 * r.minY - r.maxY))
        return p
    }
}

private struct Triangle: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.midX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

private struct BowTie: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.midX, y: r.midY))
        p.addLine(to: CGPoint(x: r.minX, y: r.minY)); p.addLine(to: CGPoint(x: r.minX, y: r.maxY)); p.closeSubpath()
        p.move(to: CGPoint(x: r.midX, y: r.midY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX, y: r.maxY)); p.closeSubpath()
        return p
    }
}

struct MascotView: View {
    let appearance: MascotAppearance
    var size: CGFloat = 24
    /// When the mascot last had company (appeared or was touched); it falls asleep `BarTheme.idleSleepAfter` later. nil = never sleeps.
    var since: Date? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.barActive) private var barActive
    @State private var wakeAt: Date?

    private static let seedText = "mascot"
    private var kind: BlobKind { BlobKind(storageName: appearance.bodyKindName) ?? .circle }
    private var bodyColor: Color { Color(hex: appearance.colorHex) ?? Color(hex: MascotAppearance.defaultColorHex)! }

    /// Eyes and mouth contrast with the body: dark on light colors.
    private var faceColor: Color {
        let c = HexColor.components(appearance.colorHex) ?? (0.6, 0.6, 1)
        return 0.299 * c.red + 0.587 * c.green + 0.114 * c.blue > 0.72 ? Color.black.opacity(0.78) : Color.white
    }

    var body: some View {
        let schedule = BlobSchedule(state: .idle, since: since, seed: BlobKind.seed(Self.seedText), active: barActive,
                                    animated: !reduceMotion, waking: wakeAt)
        TimelineView(schedule) { ctx in
            GeometryReader { geo in
                scene(now: ctx.date, frame: geo.frame(in: .global))
            }
        }
        .frame(width: size, height: size)
        .onChange(of: since) { old, _ in
            if let old, Date().timeIntervalSince(old) > BarTheme.idleSleepAfter { wakeAt = Date() }
        }
        .accessibilityElement()
        .accessibilityLabel(appearance.name)
    }

    private func sleepProgress(now: Date) -> Double {
        guard let since else { return 0 }
        return max(0, min(1, (now.timeIntervalSince(since) - BarTheme.idleSleepAfter) / 2))
    }

    private func scene(now: Date, frame: CGRect) -> some View {
        let s = size, b = s * 0.84
        let animated = !reduceMotion
        let t = animated ? now.timeIntervalSinceReferenceDate : 0
        let sleep = sleepProgress(now: now)
        var sx: CGFloat = 1, sy: CGFloat = 1, rot: Double = 0, hop: CGFloat = 0
        var open: CGFloat = 1                // 1 eyes open ... 0.15 blink/asleep
        var look = CGSize.zero
        var mouth: CGFloat = 0
        if animated {
            let b0 = sin(t * 2 * .pi / (4.5 + 2.0 * sleep))
            sx = 1 + (0.04 - 0.008 * sleep) * b0; sy = sx
            if sleep == 0 {
                if t.truncatingRemainder(dividingBy: 5.3) < 0.14 { open = 0.15 }
                let g = t.truncatingRemainder(dividingBy: 7.7)
                if g < 1.4 {
                    let dir: CGFloat = Int(t / 7.7) % 2 == 0 ? 1 : -1
                    look = CGSize(width: dir * 0.09 * b * sin(.pi * g / 1.4), height: 0)
                }
                if let (action, u) = MicroAction.current(t: t, seed: BlobKind.seed(Self.seedText)) {
                    let e = CGFloat(sin(.pi * u / action.duration))
                    switch action {
                    case .yawn: mouth = e; open = 1 - 0.8 * e; sy = 1 + 0.05 * e
                    case .stretch: sy = 1 + 0.16 * e; sx = 1 - 0.09 * e; open = 1 - 0.7 * e
                    case .follow:
                        let m = mouseLook(frame: frame)
                        look = CGSize(width: m.width * e, height: m.height * e)
                    case .wiggle: rot = 11 * exp(-1.6 * u) * sin(u * 15)
                    }
                }
            }
            if let wakeAt {
                let w = now.timeIntervalSince(wakeAt)
                if w >= 0, w < 1 {
                    hop = -0.20 * s * CGFloat(exp(-3.5 * w) * abs(sin(w * 9)))
                    if w < 0.5 { open = 1 }
                }
            }
        }
        open += (0.15 - open) * CGFloat(sleep)
        let limit = b * 0.10
        let dx = max(-limit, min(limit, look.width)), dy = max(-limit, min(limit, look.height))
        let eyeBaseY = (kind.eyeY - 0.5) * b
        let eyeDist = b * 0.34
        let face = faceColor
        let opacity = 1 - 0.18 * sleep
        let swayDeg = animated ? 7 * sin(t * 1.3) : 0

        return ZStack {
            ZStack {
                ZStack {
                    BlobShape(kind: kind).fill(bodyColor.opacity(opacity))
                    if appearance.accessory == .glasses { glasses(b: b, dist: eyeDist, y: eyeBaseY, face: face) }
                    HStack(spacing: eyeDist - eyeWidth(b)) {
                        eye(open: open, b: b, face: face)
                        eye(open: open, b: b, face: face)
                    }
                    .offset(x: dx, y: eyeBaseY + dy)
                    if mouth > 0.02 {
                        Ellipse().fill(Color.black.opacity(0.55))
                            .frame(width: b * 0.20 * mouth, height: b * 0.26 * mouth)
                            .offset(x: dx * 0.5, y: eyeBaseY + dy + b * 0.22)
                    }
                }
                .frame(width: b, height: b)
                .offset(y: s * 0.06)
                accessory(b: b, s: s, sway: swayDeg)
            }
            .frame(width: s, height: s)
            .scaleEffect(x: sx, y: sy, anchor: .bottom)
            .rotationEffect(.degrees(rot), anchor: .bottom)
            .offset(y: hop)
            if sleep > 0.99, animated { sleepZ(t: t) }
        }
        .frame(width: s, height: s)
    }

    // MARK: eyes

    private func eyeWidth(_ b: CGFloat) -> CGFloat {
        switch appearance.eyeStyle {
        case .round: return b * 0.19
        case .pill: return b * 0.15
        case .sleepy: return b * 0.21
        case .happy: return b * 0.21
        }
    }

    @ViewBuilder
    private func eye(open: CGFloat, b: CGFloat, face: Color) -> some View {
        let w = eyeWidth(b)
        switch appearance.eyeStyle {
        case .round:
            Ellipse().fill(face).frame(width: w, height: max(b * 0.035, w * open))
        case .pill:
            Capsule().fill(face).frame(width: w, height: max(b * 0.035, b * 0.24 * open))
        case .sleepy:
            HalfEye().fill(face).frame(width: w, height: max(b * 0.03, b * 0.10 * open))
        case .happy:
            ArcEye().stroke(face, style: StrokeStyle(lineWidth: b * 0.06, lineCap: .round))
                .frame(width: w, height: b * 0.10 * (0.35 + 0.65 * open))
        }
    }

    private func glasses(b: CGFloat, dist: CGFloat, y: CGFloat, face: Color) -> some View {
        let d = b * 0.31, lw = max(0.8, b * 0.045)
        return ZStack {
            Circle().stroke(face.opacity(0.9), lineWidth: lw).frame(width: d, height: d).offset(x: -dist / 2)
            Circle().stroke(face.opacity(0.9), lineWidth: lw).frame(width: d, height: d).offset(x: dist / 2)
            Capsule().fill(face.opacity(0.9)).frame(width: max(0, dist - d) + lw, height: lw)
        }
        .offset(y: y)
    }

    // MARK: accessories (positioned in the s x s frame, attached to the top of the body)

    private static let gold = Color(red: 1.0, green: 0.82, blue: 0.30)
    private static let pink = Color(red: 1.0, green: 0.46, blue: 0.66)

    @ViewBuilder
    private func accessory(b: CGFloat, s: CGFloat, sway: Double) -> some View {
        let ox = (s - b) / 2, oy = (s - b) / 2 + s * 0.06
        let top = oy + kind.topInset * b
        switch appearance.accessory {
        case .none, .glasses:
            EmptyView()
        case .hat:
            let w = b * 0.36, h = b * 0.36
            ZStack {
                Triangle().fill(Self.gold).frame(width: w, height: h)
                Triangle().stroke(Color.black.opacity(0.3), lineWidth: max(0.5, b * 0.02)).frame(width: w, height: h)
                Circle().fill(Color.white).frame(width: b * 0.10, height: b * 0.10).offset(y: -h / 2)
            }
            .rotationEffect(.degrees(11))
            .position(x: ox + b * 0.56, y: top + b * 0.08 - h / 2)
        case .bow:
            ZStack {
                BowTie().fill(Self.pink).frame(width: b * 0.34, height: b * 0.20)
                Circle().fill(Self.pink.opacity(0.85)).frame(width: b * 0.09, height: b * 0.09)
            }
            .rotationEffect(.degrees(18))
            .position(x: ox + b * 0.72, y: top + b * 0.12)
        case .antenna:
            let h = b * 0.26
            ZStack {
                Capsule().fill(Color.white.opacity(0.85)).frame(width: max(1, b * 0.045), height: h)
                Circle().fill(Self.gold).frame(width: b * 0.12, height: b * 0.12).offset(y: -h / 2)
            }
            .frame(width: b * 0.2, height: h, alignment: .bottom)
            .rotationEffect(.degrees(sway), anchor: .bottom)
            .position(x: ox + b * 0.5, y: top + b * 0.07 - h / 2)
        }
    }

    /// Two small "z" that rise and fade beside the sleeping mascot.
    private func sleepZ(t: Double) -> some View {
        let s = size
        return ZStack {
            ForEach(0..<2, id: \.self) { i in
                let p = (t / 3.4 + Double(i) * 0.5).truncatingRemainder(dividingBy: 1)
                Text("z").font(.system(size: s * (0.26 + 0.10 * p), weight: .bold, design: .rounded))
                    .foregroundStyle(Color.white)
                    .opacity(sin(.pi * p) * 0.7)
                    .offset(x: s * (0.34 + 0.12 * p), y: -s * (0.22 + 0.42 * p))
            }
        }
        .allowsHitTesting(false)
    }

    /// Eye offset towards the pointer (screen coordinates) for the "follow" gesture.
    private func mouseLook(frame: CGRect) -> CGSize {
        guard let win = NSApp.windows.first(where: { $0 is BarPanel }) else { return .zero }
        let cx = win.frame.minX + frame.midX, cy = win.frame.maxY - frame.midY
        let m = NSEvent.mouseLocation
        let vx = m.x - cx, vy = -(m.y - cy)
        let len = max(1, hypot(vx, vy))
        let k = min(1, len / 60)
        return CGSize(width: vx / len * k * size * 0.10, height: vy / len * k * size * 0.10)
    }
}

// MARK: - Panel shown on hover/click while no agent exists

private struct EmptyHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// Small panel with the mascot, its name and a "New session" button (the existing New chat flow).
struct MascotEmptyPanel: View {
    let appearance: MascotAppearance
    var since: Date?
    var topPadding: CGFloat
    var width: CGFloat
    var onHeight: (CGFloat) -> Void
    @ObservedObject private var hub = ChatHub.shared

    var body: some View {
        HStack(spacing: 14) {
            MascotView(appearance: appearance, size: 56, since: since)
                .frame(width: 60, height: 60)
            VStack(alignment: .leading, spacing: 3) {
                Text(appearance.name).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                Text("No agents running").font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                if hub.backend != nil {
                    Button { NewChatFlow.run() } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "plus").font(.system(size: 10, weight: .bold))
                            Text("New session").font(.system(size: 12, weight: .semibold)).lineLimit(1).fixedSize()
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 13).padding(.vertical, 6)
                        .background(Capsule().fill(Color.white.opacity(0.16)))
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 6)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.top, topPadding)
        .padding(.horizontal, 18)
        .padding(.bottom, 16)
        .frame(width: width, alignment: .leading)
        .background(GeometryReader { Color.clear.preference(key: EmptyHeightKey.self, value: $0.size.height) })
        .onPreferenceChange(EmptyHeightKey.self) { onHeight($0) }
    }
}
