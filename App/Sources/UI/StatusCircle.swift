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

    /// Numeric per-session seed for timing variation (0 for the empty string's hash is fine).
    static func seed(_ id: String) -> UInt64 { djb2(id) }

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

// MARK: - Idle life (breathing, sleep, micro actions, afterglow)

private struct BarActiveKey: EnvironmentKey { static let defaultValue = true }
extension EnvironmentValues {
    /// False while a blob is not on screen (e.g. the collapsed circle while the panel is expanded): it then ticks very slowly.
    var barActive: Bool {
        get { self[BarActiveKey.self] }
        set { self[BarActiveKey.self] = newValue }
    }
}

/// Small idle gestures, spread over time per session (interval 20-40 s, order derived from the session id).
enum MicroAction: CaseIterable {
    case yawn, stretch, follow, wiggle

    var duration: Double {
        switch self {
        case .yawn: return 2.4
        case .stretch: return 1.9
        case .follow: return 3.2
        case .wiggle: return 1.5
        }
    }

    /// The action running at time `t` (reference-date seconds) for a session seed, with its local time.
    static func current(t: Double, seed: UInt64) -> (action: MicroAction, u: Double)? {
        let period = 20 + Double(seed % 21)
        let offset = Double((seed / 21) % 20)
        let x = t - offset
        guard x >= 0 else { return nil }
        let k = (x / period).rounded(.down)
        let local = x - k * period
        let pick = Int(((seed &+ UInt64(k) &* 2654435761) >> 4) % UInt64(allCases.count))
        let action = allCases[pick]
        return local < action.duration ? (action, local) : nil
    }
}

/// Redraw cadence of a blob: fast only while something visibly moves, slow while asleep, hidden or static.
struct BlobSchedule: TimelineSchedule {
    var state: SessionState
    var since: Date?
    var seed: UInt64
    var active: Bool
    var animated: Bool
    var waking: Date?

    func entries(from start: Date, mode: TimelineScheduleMode) -> UnfoldSequence<Date, Date> {
        sequence(state: start) { last in
            let next = last.addingTimeInterval(interval(at: last) * (mode == .lowFrequency ? 4 : 1))
            last = next
            return next
        }
    }

    private func interval(at date: Date) -> TimeInterval {
        guard animated, active else { return 5 }
        if let win = NSApp.windows.first(where: { $0 is BarPanel }),
           !(win.isVisible && win.occlusionState.contains(.visible)) { return 2 }
        switch state {
        case .working, .needsInput: return 1.0 / 30
        case .error: return 1
        case .idle, .done:
            if let waking, date.timeIntervalSince(waking) < 1 { return 1.0 / 30 }
            let age = since.map { date.timeIntervalSince($0) } ?? 0
            if since != nil, age > BarTheme.idleSleepAfter + 2 { return 1.0 / 8 }
            if state == .done, age < BarTheme.doneGlowDuration { return 1.0 / 24 }
            if MicroAction.current(t: date.timeIntervalSinceReferenceDate, seed: seed) != nil { return 1.0 / 30 }
            return 1.0 / 15
        }
    }
}

/// A tiny blob character with two pill eyes. The expression follows the session state.
/// Idle/done blobs breathe, look around, do small gestures and fall asleep after `BarTheme.idleSleepAfter`
/// (measured from `stateSince`); done sessions get a fading afterglow ring.
struct BlobView: View {
    let state: SessionState
    var kind: BlobKind = .circle
    var size: CGFloat = 18
    var tint: Color? = nil
    /// When the current state began (e.g. the session's `updatedAt`); nil = never falls asleep, no afterglow.
    var stateSince: Date? = nil
    /// Per-session seed text (session id) for the timing of the micro actions.
    var seed: String = ""
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.barActive) private var barActive
    @State private var wakeAt: Date?

    private struct Stamp: Equatable { var state: SessionState; var since: Date? }

    var body: some View {
        let schedule = BlobSchedule(state: state, since: stateSince, seed: BlobKind.seed(seed), active: barActive,
                                    animated: !reduceMotion, waking: wakeAt)
        TimelineView(schedule) { ctx in
            GeometryReader { geo in
                blob(now: ctx.date, frame: geo.frame(in: .global))
            }
        }
        .frame(width: size, height: size)
        .animation(BarTheme.spring, value: state)
        .onChange(of: Stamp(state: state, since: stateSince)) { old, _ in
            if isAsleep(now: Date(), state: old.state, since: old.since) { wakeAt = Date() }
        }
    }

    private func resting(_ st: SessionState) -> Bool { st == .idle || st == .done }

    private func isAsleep(now: Date, state st: SessionState, since: Date?) -> Bool {
        guard resting(st), let since else { return false }
        return now.timeIntervalSince(since) > BarTheme.idleSleepAfter
    }

    /// 0 awake ... 1 asleep, eased over two seconds so eyes close and colour dims smoothly.
    private func sleepProgress(now: Date) -> Double {
        guard resting(state), let stateSince else { return 0 }
        return max(0, min(1, (now.timeIntervalSince(stateSince) - BarTheme.idleSleepAfter) / 2))
    }

    private func color(sleep: Double) -> Color {
        guard state == .working || state == .idle || state == .done else { return BarTheme.color(for: state) }
        if state == .working { return tint ?? BarTheme.color(for: state) }
        if let tint { return tint.opacity(BarTheme.idleDim - 0.10 * sleep) }
        return BarTheme.idle
    }

    private func blob(now: Date, frame: CGRect) -> some View {
        let s = size
        let animated = !reduceMotion
        let t = animated ? now.timeIntervalSinceReferenceDate : 0
        let sleep = sleepProgress(now: now)
        var sx: CGFloat = 1, sy: CGFloat = 1, rot: Double = 0, hop: CGFloat = 0
        var eyeW = s * 0.15, eyeH = s * 0.26, tilt: Double = 0
        var look = CGSize.zero
        var mouth: CGFloat = 0
        var glow = 0.0
        switch state {
        case .idle, .done:
            eyeH = s * 0.20
            eyeW = s * 0.15 + s * 0.02 * sleep
            if animated {
                // Breathing, slower while asleep.
                let period = 4.5 + 2.0 * sleep
                let b = sin(t * 2 * .pi / period)
                let amp = 0.04 - 0.008 * sleep
                sx = 1 + amp * b; sy = sx
                // Blink, glance around every few seconds, small gesture every 20-40 s.
                if sleep == 0 {
                    if t.truncatingRemainder(dividingBy: 5.3) < 0.14 { eyeH = s * 0.035 }
                    let g = t.truncatingRemainder(dividingBy: 7.7)
                    if g < 1.4 {
                        let dir: CGFloat = Int(t / 7.7) % 2 == 0 ? 1 : -1
                        look = CGSize(width: dir * 0.09 * s * sin(.pi * g / 1.4), height: 0)
                    }
                    if let (action, u) = MicroAction.current(t: t, seed: BlobKind.seed(seed)) {
                        let e = CGFloat(sin(.pi * u / action.duration))
                        switch action {
                        case .yawn:
                            mouth = e; eyeH = s * (0.20 - 0.15 * e); sy = 1 + 0.05 * e
                        case .stretch:
                            sy = 1 + 0.16 * e; sx = 1 - 0.09 * e; eyeH = s * (0.20 - 0.13 * e)
                        case .follow:
                            let m = mouseLook(frame: frame)
                            look = CGSize(width: m.width * e, height: m.height * e)
                        case .wiggle:
                            rot = 11 * exp(-1.6 * u) * sin(u * 15)
                        }
                    }
                }
                // Wake-up hop after sleeping.
                if let wakeAt {
                    let w = now.timeIntervalSince(wakeAt)
                    if w >= 0, w < 1 {
                        hop = -0.20 * s * CGFloat(exp(-3.5 * w) * abs(sin(w * 9)))
                        if w < 0.5 { eyeH = max(eyeH, s * 0.30) }
                    }
                }
                eyeH = eyeH + (s * 0.035 - eyeH) * CGFloat(sleep)
            } else {
                eyeH = s * 0.20 + (s * 0.035 - s * 0.20) * CGFloat(sleep)
            }
            if state == .done, animated, let stateSince {
                let age = now.timeIntervalSince(stateSince)
                if age >= 0, age < BarTheme.doneGlowDuration { glow = pow(1 - age / BarTheme.doneGlowDuration, 1.6) }
            }
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
        let eyeOffsetY = (kind.eyeY - 0.5) * s + dy
        let c = color(sleep: sleep)
        let ringColor = tint ?? Color.white
        return ZStack {
            if glow > 0 {
                BlobShape(kind: kind).stroke(ringColor, lineWidth: s * 0.12)
                    .blur(radius: s * 0.08)
                    .scaleEffect(1.10 + 0.22 * (1 - glow))
                    .opacity(0.75 * glow)
            }
            ZStack {
                BlobShape(kind: kind).fill(c)
                HStack(spacing: s * 0.13) {
                    Capsule().fill(Color.white).frame(width: eyeW, height: eyeH).rotationEffect(.degrees(tilt))
                    Capsule().fill(Color.white).frame(width: eyeW, height: eyeH).rotationEffect(.degrees(-tilt))
                }
                .offset(x: dx, y: eyeOffsetY)
                if mouth > 0.02 {
                    Ellipse().fill(Color.black.opacity(0.55))
                        .frame(width: s * 0.20 * mouth, height: s * 0.26 * mouth)
                        .offset(x: dx * 0.5, y: eyeOffsetY + s * 0.22)
                }
            }
            .frame(width: s, height: s)
            .scaleEffect(x: sx, y: sy)
            .rotationEffect(.degrees(rot))
            .offset(y: hop)
            if sleep > 0.99, animated { sleepZ(t: t) }
        }
        .frame(width: s, height: s)
    }

    /// Two small "z" that rise and fade beside the sleeping blob.
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
    /// Color of the most important agent (see `SessionLook.aggregateTint`); nil keeps the soft white/grey. Needs-input and
    /// error always show their warning color regardless of the tint. Never falls asleep (no `stateSince`).
    var tint: Color? = nil
    var body: some View { BlobView(state: state, kind: .circle, size: size, tint: tint, seed: "aggregate") }
}
