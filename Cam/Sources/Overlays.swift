import SwiftUI

// MARK: - Grid

struct GridOverlay: View {
    let type: GridType

    var body: some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height
            var path = Path()

            func vLine(_ f: CGFloat) { path.move(to: CGPoint(x: w * f, y: 0)); path.addLine(to: CGPoint(x: w * f, y: h)) }
            func hLine(_ f: CGFloat) { path.move(to: CGPoint(x: 0, y: h * f)); path.addLine(to: CGPoint(x: w, y: h * f)) }

            switch type {
            case .off:
                break
            case .thirds:
                vLine(1.0 / 3); vLine(2.0 / 3); hLine(1.0 / 3); hLine(2.0 / 3)
            case .grid4:
                for i in 1..<4 { vLine(CGFloat(i) / 4); hLine(CGFloat(i) / 4) }
            case .golden:
                vLine(0.382); vLine(0.618); hLine(0.382); hLine(0.618)
            case .diagonals:
                path.move(to: .zero); path.addLine(to: CGPoint(x: w, y: h))
                path.move(to: CGPoint(x: w, y: 0)); path.addLine(to: CGPoint(x: 0, y: h))
                vLine(0.5); hLine(0.5)
            case .cross:
                let c = CGPoint(x: w / 2, y: h / 2)
                let s: CGFloat = 18
                path.move(to: CGPoint(x: c.x - s, y: c.y)); path.addLine(to: CGPoint(x: c.x + s, y: c.y))
                path.move(to: CGPoint(x: c.x, y: c.y - s)); path.addLine(to: CGPoint(x: c.x, y: c.y + s))
            }
            ctx.stroke(path, with: .color(.white.opacity(0.6)), lineWidth: 0.8)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Frame guide

struct FrameGuideOverlay: View {
    let guide: FrameGuide

    var body: some View {
        GeometryReader { g in
            if let ratio = guide.ratio {
                let boxW = g.size.width, boxH = g.size.height
                let frameW = min(boxW, boxH * ratio)
                let frameH = frameW / ratio
                ZStack {
                    Path { p in
                        p.addRect(CGRect(origin: .zero, size: g.size))
                        p.addRect(CGRect(x: (boxW - frameW) / 2, y: (boxH - frameH) / 2, width: frameW, height: frameH))
                    }
                    .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
                    Rectangle()
                        .stroke(Color.white.opacity(0.85), lineWidth: 1.5)
                        .frame(width: frameW, height: frameH)
                }
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Level

struct LevelOverlay: View {
    let roll: Double

    var body: some View {
        let isLevel = abs(roll) < 0.8
        ZStack {
            Rectangle()
                .fill(isLevel ? Color.green : Color.white.opacity(0.85))
                .frame(width: 130, height: 1.5)
                .rotationEffect(.degrees(-roll))
            HStack(spacing: 112) {
                Rectangle().fill(Color.white.opacity(0.5)).frame(width: 14, height: 1.5)
                Rectangle().fill(Color.white.opacity(0.5)).frame(width: 14, height: 1.5)
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Focus indicator

struct FocusIndicator: View {
    var locked: Bool = false
    @State private var appear = false
    var body: some View {
        ZStack {
            Rectangle()
                .stroke(locked ? Theme.yellow : Color.yellow, lineWidth: locked ? 2.5 : 1.5)
                .frame(width: 72, height: 72)
            if locked {
                Image(systemName: "lock.fill").font(.system(size: 12)).foregroundColor(Theme.yellow).offset(y: -52)
            }
        }
        .scaleEffect(appear ? 1 : 1.35)
        .onAppear { withAnimation(.easeOut(duration: 0.25)) { appear = true } }
    }
}

// MARK: - Vision detections (preview only)

struct DetectionOverlay: View {
    let d: Detections
    let faces: Bool
    let hands: Bool
    let fingers: Bool

    var body: some View {
        Canvas { ctx, size in
            func box(_ r: CGRect, _ color: Color, _ lw: CGFloat) {
                let rect = CGRect(x: r.minX * size.width, y: r.minY * size.height,
                                  width: r.width * size.width, height: r.height * size.height)
                ctx.stroke(Path(roundedRect: rect, cornerRadius: 3), with: .color(color), lineWidth: lw)
            }
            if faces { for r in d.faces { box(r, Color.green, 2) } }
            if hands { for r in d.hands { box(r, Color.cyan, 2) } }
            if fingers {
                for f in d.fingers {
                    box(f.rect, Color.orange, 1.5)
                    let tip = CGPoint(x: f.tip.x * size.width, y: f.tip.y * size.height)
                    ctx.fill(Path(ellipseIn: CGRect(x: tip.x - 4.5, y: tip.y - 4.5, width: 9, height: 9)), with: .color(.red))
                    ctx.stroke(Path(ellipseIn: CGRect(x: tip.x - 4.5, y: tip.y - 4.5, width: 9, height: 9)), with: .color(.white), lineWidth: 1)
                    let label = Text(f.name).font(.system(size: 10, weight: .bold)).foregroundColor(.white)
                    let x = f.rect.midX * size.width
                    let y = max(f.rect.minY * size.height - 8, 8)
                    ctx.draw(label, at: CGPoint(x: x, y: y), anchor: .center)
                }
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Histogram

struct HistogramView: View {
    let bins: [Float]

    var body: some View {
        GeometryReader { g in
            Path { p in
                let w = g.size.width, h = g.size.height
                guard bins.count > 1 else { return }
                p.move(to: CGPoint(x: 0, y: h))
                for (i, v) in bins.enumerated() {
                    let x = w * CGFloat(i) / CGFloat(bins.count - 1)
                    p.addLine(to: CGPoint(x: x, y: h - h * CGFloat(v)))
                }
                p.addLine(to: CGPoint(x: w, y: h))
                p.closeSubpath()
            }
            .fill(LinearGradient(colors: [Color.white.opacity(0.9), Color.blue.opacity(0.7)], startPoint: .top, endPoint: .bottom))
        }
    }
}

// MARK: - Audio meter

struct AudioMeterView: View {
    let levels: [Float]
    private let ticks: [Float] = [-45, -30, -20, -10, -6, -3, 0]

    private func fraction(_ db: Float) -> CGFloat { CGFloat(max(0, min(1, (db + 60) / 60))) }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(0..<2, id: \.self) { i in
                HStack(spacing: 5) {
                    Text("\(i + 1)").font(.system(size: 9, weight: .semibold)).foregroundColor(.white.opacity(0.8)).frame(width: 8)
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 2).fill(Color.white.opacity(0.12))
                            RoundedRectangle(cornerRadius: 2)
                                .fill(LinearGradient(stops: [
                                    .init(color: .green, location: 0),
                                    .init(color: .green, location: 0.7),
                                    .init(color: .yellow, location: 0.88),
                                    .init(color: .red, location: 1)
                                ], startPoint: .leading, endPoint: .trailing))
                                .frame(width: g.size.width * fraction(levels.count > i ? levels[i] : -60))
                        }
                    }
                    .frame(height: 7)
                }
            }
            HStack(spacing: 0) {
                Spacer().frame(width: 13)
                GeometryReader { g in
                    ZStack(alignment: .topLeading) {
                        ForEach(ticks, id: \.self) { t in
                            Text("\(Int(t))")
                                .font(.system(size: 8))
                                .foregroundColor(.white.opacity(0.7))
                                .position(x: g.size.width * fraction(t), y: 5)
                        }
                    }
                }
                .frame(height: 10)
            }
        }
    }
}
