import SwiftUI
import AppKit
import AgentBarCore

enum BlobKind: Int, CaseIterable {
    case circle, roundedSquare, cloud, drop, triangle

    /// Stable per-session shape (djb2 over the id, so it does not change between launches).
    static func forSession(_ id: String) -> BlobKind {
        BlobKind.allCases[Int(djb2(id) % UInt64(allCases.count))]
    }

    /// Muted tint used for calm working states of a session.
    static func tint(forSession id: String) -> Color {
        let palette: [Color] = [
            Color(red: 0.45, green: 0.85, blue: 0.70), Color(red: 0.62, green: 0.60, blue: 1.0),
            Color(red: 1.0, green: 0.68, blue: 0.55), Color(red: 0.45, green: 0.75, blue: 1.0),
            Color(red: 0.80, green: 0.90, blue: 0.45),
        ]
        return palette[Int((djb2(id) / 7) % UInt64(palette.count))]
    }

    private static func djb2(_ s: String) -> UInt64 {
        s.unicodeScalars.reduce(5381 as UInt64) { ($0 &* 33) &+ UInt64($1.value) }
    }

    /// Vertical eye position (fraction of height) that looks right for this body.
    var eyeY: CGFloat {
        switch self {
        case .circle, .roundedSquare: return 0.5
        case .cloud: return 0.56
        case .drop: return 0.62
        case .triangle: return 0.66
        }
    }
}

struct BlobShape: Shape {
    let kind: BlobKind

    func path(in r: CGRect) -> Path {
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: r.minX + x * r.width, y: r.minY + y * r.height) }
        switch kind {
        case .circle:
            return Path(ellipseIn: r)
        case .roundedSquare:
            return Path(roundedRect: r.insetBy(dx: r.width * 0.04, dy: r.height * 0.04), cornerRadius: r.width * 0.30,
                        style: .continuous)
        case .cloud:
            var path = Path()
            for (cx, cy, rad) in [(0.30, 0.60, 0.25), (0.50, 0.42, 0.29), (0.72, 0.60, 0.25)] as [(CGFloat, CGFloat, CGFloat)] {
                path.addEllipse(in: CGRect(x: r.minX + (cx - rad) * r.width, y: r.minY + (cy - rad) * r.height,
                                           width: 2 * rad * r.width, height: 2 * rad * r.height))
            }
            path.addRoundedRect(in: CGRect(x: r.minX + 0.07 * r.width, y: r.minY + 0.52 * r.height,
                                           width: 0.86 * r.width, height: 0.36 * r.height),
                                cornerSize: CGSize(width: 0.17 * r.width, height: 0.17 * r.height))
            return path
        case .drop:
            var path = Path()
            path.move(to: p(0.5, 0.02))
            path.addCurve(to: p(0.97, 0.64), control1: p(0.62, 0.22), control2: p(0.97, 0.38))
            path.addCurve(to: p(0.5, 0.99), control1: p(0.97, 0.84), control2: p(0.76, 0.99))
            path.addCurve(to: p(0.03, 0.64), control1: p(0.24, 0.99), control2: p(0.03, 0.84))
            path.addCurve(to: p(0.5, 0.02), control1: p(0.03, 0.38), control2: p(0.38, 0.22))
            path.closeSubpath()
            return path
        case .triangle:
            let pts = [p(0.5, 0.10), p(0.93, 0.88), p(0.07, 0.88)]
            var path = Path()
            let k: CGFloat = 0.28
            for i in 0..<3 {
                let prev = pts[(i + 2) % 3], cur = pts[i], next = pts[(i + 1) % 3]
                func toward(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
                    CGPoint(x: a.x + (b.x - a.x) * k, y: a.y + (b.y - a.y) * k)
                }
                let start = toward(cur, prev), end = toward(cur, next)
                if i == 0 { path.move(to: start) } else { path.addLine(to: start) }
                path.addQuadCurve(to: end, control: cur)
            }
            path.closeSubpath()
            return path
        }
    }
}

/// A tiny blob character with two pill eyes. The expression follows the session state.
struct BlobView: View {
    let state: SessionState
    var kind: BlobKind = .circle
    var size: CGFloat = 18
    var tint: Color? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion)) { ctx in
            GeometryReader { geo in
                blob(t: reduceMotion ? 0 : ctx.date.timeIntervalSinceReferenceDate, frame: geo.frame(in: .global))
            }
        }
        .frame(width: size, height: size)
        .animation(BarTheme.spring, value: state)
    }

    private var color: Color {
        if let tint, state == .working || state == .idle || state == .done { return state == .working ? tint : BarTheme.idle }
        return BarTheme.color(for: state)
    }

    private func blob(t: Double, frame: CGRect) -> some View {
        let s = size
        let animated = !reduceMotion
        var sx: CGFloat = 1, sy: CGFloat = 1, rot: Double = 0, hop: CGFloat = 0
        var eyeW = s * 0.15, eyeH = s * 0.26, tilt: Double = 0
        var look = CGSize.zero
        switch state {
        case .idle, .done:
            eyeH = s * 0.11
            if animated, t.truncatingRemainder(dividingBy: 5.3) < 0.14 { eyeH = s * 0.035 }
        case .working:
            eyeH = s * 0.24
            if animated {
                let b = sin(t * 2 * .pi / 1.6)
                sx = 1 + 0.07 * b; sy = 1 - 0.07 * b
                look = CGSize(width: 0.10 * s * sin(t * 0.7), height: 0.04 * s * sin(t * 0.45))
            }
        case .needsInput:
            eyeW = s * 0.17; eyeH = s * 0.34
            if animated {
                let p = t.truncatingRemainder(dividingBy: 4.0)
                if p < 0.9 { rot = 9 * exp(-4 * p) * sin(p * 16); hop = -0.07 * s * exp(-5 * p) * abs(sin(p * 9)) }
                look = mouseLook(frame: frame)
            }
        case .error:
            eyeH = s * 0.22; tilt = 18
        }
        let limit = s * 0.10
        let dx = max(-limit, min(limit, look.width)), dy = max(-limit, min(limit, look.height))
        return ZStack {
            BlobShape(kind: kind).fill(color)
            HStack(spacing: s * 0.13) {
                Capsule().fill(Color.white).frame(width: eyeW, height: eyeH).rotationEffect(.degrees(tilt))
                Capsule().fill(Color.white).frame(width: eyeW, height: eyeH).rotationEffect(.degrees(-tilt))
            }
            .offset(x: dx, y: (kind.eyeY - 0.5) * s + dy)
        }
        .frame(width: s, height: s)
        .scaleEffect(x: sx, y: sy)
        .rotationEffect(.degrees(rot))
        .offset(y: hop)
    }

    /// Eye offset towards the pointer (screen coordinates), used by the attentive needs-input blob.
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

/// The aggregate indicator shown collapsed (always a circle blob).
struct StatusCircle: View {
    let state: SessionState
    var size: CGFloat = 18
    var body: some View { BlobView(state: state, kind: .circle, size: size) }
}
