import ISurfSelectCore
import SwiftUI

enum WaveFace {
    static func name(for shape: Int) -> String {
        switch shape {
        case ...2: "Mellow"
        case 3...5: "Push"
        case 6...7: "Steep"
        default: "Lip"
        }
    }
}

struct WaveProfileShape: Shape {
    var level: Double
    var lean: Double
    var closed: Bool

    var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(level, lean) }
        set {
            level = newValue.first
            lean = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let t = min(max(level, 0), 10) / 10
        let leanSign: Double = lean < 0 ? -1 : 1
        let crest = 0.58 + leanSign * 0.16
        let amp = 8 + t * 46
        let width = 0.42 - t * 0.16
        let steps = 56

        func point(_ index: Int) -> CGPoint {
            let u = Double(index) / Double(steps)
            let dist = u - crest
            let front = leanSign == 1 ? dist > 0 : dist < 0
            let sharp = front ? 1 + t * 3.4 : max(0.55, 1 - t * 0.4)
            let yNorm = 86 - amp * exp(-pow((dist * sharp) / width, 2))
            let x = rect.minX + (12 + u * 276) / 300 * rect.width
            let y = rect.minY + yNorm / 112 * rect.height
            return CGPoint(x: x, y: y)
        }

        var path = Path()
        path.move(to: point(0))
        for index in 1...steps {
            path.addLine(to: point(index))
        }
        if closed {
            path.addLine(to: CGPoint(x: rect.maxX - rect.width * 0.03, y: rect.maxY - 4))
            path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.03, y: rect.maxY - 4))
            path.closeSubpath()
        }
        return path
    }
}

struct WaveGraphic: View {
    var shape: Int
    var port: Bool

    private var level: Double { Double(shape) }
    private var lean: Double { port ? -1 : 1 }

    var body: some View {
        ZStack(alignment: .topLeading) {
            WaveProfileShape(level: level, lean: lean, closed: true)
                .fill(Color(red: 0.114, green: 0.306, blue: 0.400))
            WaveProfileShape(level: level, lean: lean, closed: false)
                .stroke(Color.white, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
            VStack(alignment: .leading, spacing: 0) {
                Text("\(shape)")
                    .font(.system(size: 28, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(.white)
                Text(WaveFace.name(for: shape))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.7))
            }
            .padding(12)
        }
        .frame(height: 132)
        .frame(maxWidth: .infinity)
        .graphicWell()
        .animation(.easeOut(duration: 0.28), value: shape)
        .animation(.easeOut(duration: 0.28), value: port)
        .accessibilityLabel("Wave shape \(shape), \(WaveFace.name(for: shape)), \(port ? "port" : "starboard")")
    }
}

struct SideGraphic: View {
    var port: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            SwingTrackShape()
                .fill(Color(red: 44.0 / 255, green: 49.0 / 255, blue: 58.0 / 255))
            SwingMarkerShape()
                .fill(Color.nautique)
                .rotationEffect(.degrees(port ? -46 : 46), anchor: UnitPoint(x: 0.5, y: 108.0 / 120.0))
            VStack {
                HStack {
                    Text("Port")
                        .foregroundStyle(port ? Color.white : SwingLabel.idle)
                    Spacer(minLength: 8)
                    Text("Starboard")
                        .foregroundStyle(port ? SwingLabel.idle : Color.white)
                }
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 14)
                .padding(.top, 8)
                Spacer(minLength: 0)
            }
        }
        .aspectRatio(280.0 / 120.0, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .graphicWell()
        .animation(reduceMotion ? .linear(duration: 0) : .easeOut(duration: 0.32), value: port)
        .accessibilityLabel(port ? "Port wave" : "Starboard wave")
    }
}

private enum SwingLabel {
    static let idle = Color(red: 183.0 / 255, green: 190.0 / 255, blue: 200.0 / 255)
}

private enum SwingSpace {
    static let width: CGFloat = 280
    static let height: CGFloat = 120
    static let center = CGPoint(x: 140, y: 108)

    static func point(_ x: CGFloat, _ y: CGFloat, in rect: CGRect) -> CGPoint {
        CGPoint(
            x: rect.minX + x / width * rect.width,
            y: rect.minY + y / height * rect.height
        )
    }

    static func arc(radius: CGFloat, from start: CGFloat, to end: CGFloat, steps: Int, in rect: CGRect) -> [CGPoint] {
        (0...steps).map { step in
            let t = CGFloat(step) / CGFloat(steps)
            let degrees = start + (end - start) * t
            let radians = degrees * .pi / 180
            let x = center.x + radius * cos(radians)
            let y = center.y - radius * sin(radians)
            return point(x, y, in: rect)
        }
    }
}

private struct SwingTrackShape: Shape {
    func path(in rect: CGRect) -> Path {
        let outer = SwingSpace.arc(radius: 92, from: 158, to: 22, steps: 36, in: rect)
        let inner = SwingSpace.arc(radius: 66, from: 22, to: 158, steps: 28, in: rect)
        guard let first = outer.first else { return Path() }
        var path = Path()
        path.move(to: first)
        for point in outer.dropFirst() {
            path.addLine(to: point)
        }
        for point in inner {
            path.addLine(to: point)
        }
        path.closeSubpath()
        return path
    }
}

private struct SwingMarkerShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: SwingSpace.point(127, 102, in: rect))
        path.addLine(to: SwingSpace.point(132, 44, in: rect))
        path.addQuadCurve(
            to: SwingSpace.point(148, 44, in: rect),
            control: SwingSpace.point(140, 26, in: rect)
        )
        path.addLine(to: SwingSpace.point(153, 102, in: rect))
        path.closeSubpath()
        return path
    }
}

struct LevelPips: View {
    var filled: Int
    var total: Int
    var value: String
    var unit: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(value)
                    .font(.system(size: 28, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(.white)
                if !unit.isEmpty {
                    Text(unit)
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.65))
                }
            }
            HStack(spacing: 6) {
                ForEach(0..<total, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(index < filled ? Color.nautique : Color.white.opacity(0.14))
                        .frame(height: 12)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .graphicWell()
        .animation(.easeOut(duration: 0.22), value: filled)
    }
}

struct ZoneColumns: View {
    var zones: [StereoZone]

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            ForEach(zones) { zone in
                VStack(spacing: 6) {
                    ZStack(alignment: .bottom) {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.white.opacity(0.1))
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.nautique)
                            .frame(height: 8 + CGFloat(zone.volume) / 50 * 64)
                    }
                    .frame(height: 72)
                    Text(zone.name)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Text("\(zone.volume)")
                        .font(.caption.weight(.bold).monospacedDigit())
                        .foregroundStyle(.white)
                }
                .frame(maxWidth: .infinity)
                .animation(.easeOut(duration: 0.28), value: zone.volume)
            }
        }
        .padding(14)
        .graphicWell()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(zones.map { "\($0.name) \($0.volume)" }.joined(separator: ", "))
    }
}

struct BallastGraphic: View {
    var pounds: Int
    var port: Bool
    var running: Bool

    var body: some View {
        VStack(spacing: 8) {
            GeometryReader { geo in
                let travel = (port ? -1 : 1) * (18 + CGFloat(pounds) / 400 * geo.size.width * 0.28)
                ZStack {
                    Capsule()
                        .fill(Color.white.opacity(0.16))
                        .frame(height: 4)
                    Circle()
                        .fill(running ? Color.white : Color.nautique)
                        .frame(width: 16 + CGFloat(pounds) / 28, height: 16 + CGFloat(pounds) / 28)
                        .offset(x: travel)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(height: 56)
            HStack {
                Text("Port")
                Spacer()
                Text("\(pounds)")
                    .font(.system(size: 22, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(.white)
                Spacer()
                Text("Starboard")
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white.opacity(0.65))
        }
        .padding(14)
        .graphicWell()
        .animation(.easeOut(duration: 0.35), value: port)
        .animation(.easeOut(duration: 0.35), value: pounds)
        .animation(.easeOut(duration: 0.2), value: running)
        .accessibilityLabel("\(pounds) pounds toward \(port ? "port" : "starboard"), pumps \(running ? "running" : "idle")")
    }
}

private extension View {
    func graphicWell() -> some View {
        background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(red: 0.078, green: 0.094, blue: 0.122))
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
