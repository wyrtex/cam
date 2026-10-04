import SwiftUI
import AVFoundation

enum ActiveSheet: String, Identifiable {
    case format, looks, settings
    var id: String { rawValue }
}

enum Theme {
    static let bg = Color(red: 0.04, green: 0.06, blue: 0.10)
    static let accent = Color(red: 0.20, green: 0.52, blue: 1.0)
    static let panel = Color.black.opacity(0.55)
    static let rec = Color(red: 0.95, green: 0.18, blue: 0.20)
    static let yellow = Color(red: 1.0, green: 0.80, blue: 0.2)
}

struct ContentView: View {
    @StateObject private var engine = CameraEngine()
    @State private var param: ManualParam?
    @State private var sheet: ActiveSheet?
    @State private var focusPoint: CGPoint?
    @State private var focusToken = 0
    @State private var pinchBase: CGFloat?
    @State private var flashOpacity: Double = 0

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            VStack(spacing: 0) {
                TopBar(engine: engine, sheet: $sheet)
                ParamStrip(engine: engine, param: $param, sheet: $sheet)
                middle
                ModePicker(engine: engine)
                BottomBar(engine: engine)
            }
            if let msg = engine.statusMessage {
                VStack {
                    Text(msg)
                        .font(.footnote.weight(.semibold))
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(Capsule().fill(Color.black.opacity(0.8)))
                        .foregroundColor(.white)
                        .padding(.top, 70)
                    Spacer()
                }
                .transition(.opacity)
                .allowsHitTesting(false)
            }
            Color.white.opacity(flashOpacity).ignoresSafeArea().allowsHitTesting(false)
        }
        .onAppear { engine.start() }
        .onChange(of: engine.photoFlashTick) { _, _ in
            flashOpacity = 0.85
            withAnimation(.easeOut(duration: 0.25)) { flashOpacity = 0 }
        }
        .sheet(item: $sheet) { s in
            switch s {
            case .format:
                FormatSheet(engine: engine)
                    .presentationDetents([.medium, .large])
                    .presentationBackground(Theme.bg)
            case .looks:
                LooksSheet(engine: engine)
                    .presentationDetents([.medium, .large])
                    .presentationBackground(Theme.bg)
            case .settings:
                SettingsSheet(engine: engine)
                    .presentationDetents([.medium, .large])
                    .presentationBackground(Theme.bg)
            }
        }
    }

    // MARK: Middle region (preview + overlays)

    private var middle: some View {
        ZStack {
            Color.black
            previewStack
            VStack(spacing: 8) {
                Spacer()
                if let p = param {
                    ParamPanel(engine: engine, param: p)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                infoRow
            }
            .padding(8)
        }
        .clipped()
    }

    private var previewStack: some View {
        let size = engine.videoSize
        let ratio = size.height > 0 ? size.width / size.height : 9.0 / 16.0
        return ZStack {
            CameraPreview(engine: engine)
            FrameGuideOverlay(guide: engine.guide)
            GridOverlay(type: engine.grid)
            if engine.showLevel { LevelOverlay(roll: engine.rollDegrees) }
            GeometryReader { g in
                ZStack {
                    Color.clear.contentShape(Rectangle())
                        .gesture(
                            SpatialTapGesture().onEnded { v in
                                let n = CGPoint(x: v.location.x / max(g.size.width, 1), y: v.location.y / max(g.size.height, 1))
                                engine.focus(at: n)
                                focusPoint = v.location
                                focusToken += 1
                                let token = focusToken
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                                    if token == focusToken { focusPoint = nil }
                                }
                            }
                        )
                        .simultaneousGesture(
                            MagnifyGesture()
                                .onChanged { v in
                                    if pinchBase == nil { pinchBase = engine.zoom }
                                    engine.setZoom((pinchBase ?? 1) * v.magnification)
                                }
                                .onEnded { _ in pinchBase = nil }
                        )
                    if let fp = focusPoint {
                        FocusIndicator().id(focusToken).position(fp)
                    }
                }
            }
        }
        .aspectRatio(ratio, contentMode: .fit)
    }

    private var infoRow: some View {
        HStack(alignment: .bottom, spacing: 8) {
            VStack(alignment: .leading, spacing: 6) {
                if engine.showInfoPanel { StoragePanel(engine: engine) }
                if engine.showHistogram {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Rec.709").font(.system(size: 9, weight: .medium)).foregroundColor(.white.opacity(0.8))
                        HistogramView(bins: engine.histogram).frame(height: 38)
                    }
                    .padding(6)
                    .frame(width: 130)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Theme.panel))
                }
            }
            Spacer(minLength: 0)
            if engine.showAudioMeter && engine.mode == .video {
                VStack(alignment: .leading, spacing: 4) {
                    Text(engine.micName).font(.system(size: 9, weight: .medium)).foregroundColor(.white.opacity(0.8)).lineLimit(1)
                    AudioMeterView(levels: engine.audioLevels)
                }
                .padding(6)
                .frame(width: 150)
                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.panel))
            }
        }
    }
}

// MARK: - Top bar

struct TopBar: View {
    @ObservedObject var engine: CameraEngine
    @Binding var sheet: ActiveSheet?

    var body: some View {
        HStack(spacing: 10) {
            Button { sheet = .looks } label: {
                HStack(spacing: 4) {
                    Image(systemName: "camera.filters")
                    Text(engine.look == .none ? "LUT" : engine.look.rawValue)
                        .font(.system(size: 12, weight: .bold))
                        .lineLimit(1)
                }
                .padding(.horizontal, 9).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 7).fill(engine.look == .none ? Color.white.opacity(0.12) : Theme.accent))
                .foregroundColor(.white)
            }

            Button { sheet = .format } label: {
                VStack(spacing: 0) {
                    Text(formatTitle).font(.system(size: 13, weight: .heavy))
                    Text(formatSubtitle).font(.system(size: 9, weight: .semibold))
                }
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.white))
                .foregroundColor(.black)
            }

            Spacer(minLength: 0)

            Text(engine.mode == .photo ? "PHOTO" : formatTimecode(engine.recordSeconds, fps: 30))
                .font(.system(size: 22, weight: .semibold, design: .monospaced))
                .foregroundColor(engine.isRecording ? Theme.rec : .white)

            Spacer(minLength: 0)

            Button { sheet = .settings } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 18))
                    .padding(8)
                    .background(Circle().fill(Color.white.opacity(0.12)))
                    .foregroundColor(.white)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var formatTitle: String {
        engine.mode == .photo ? (engine.photoResolution?.label ?? "—") : engine.resolution.rawValue
    }
    private var formatSubtitle: String {
        if engine.mode == .photo { return engine.rawEnabled ? "RAW" : "HEIF" }
        return "\(engine.fps) fps · \(engine.codec.rawValue)"
    }
}

// MARK: - Param strip

struct ParamStrip: View {
    @ObservedObject var engine: CameraEngine
    @Binding var param: ManualParam?
    @Binding var sheet: ActiveSheet?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                chip("LENS", "\(engine.focalLengthMM)mm", .zoom, auto: false)
                if engine.mode != .photo {
                    Button { sheet = .format } label: { chipBody("FPS", "\(engine.fps)", false, false) }
                }
                chip("SHUTTER", formatShutterSeconds(engine.shutterSeconds), .shutter, auto: engine.autoExposure)
                chip("ISO", "\(Int(engine.iso))", .iso, auto: engine.autoExposure)
                chip("EV", String(format: "%+.1f", engine.evBias), .ev, auto: false)
                chip("WB", "\(Int(engine.wbTemp))K", .wb, auto: engine.autoWB)
                chip("TINT", "\(Int(engine.wbTint))", .tint, auto: false)
                chip("FOCUS", engine.autoFocus ? "AF" : String(format: "%.2f", engine.focusPos), .focus, auto: engine.autoFocus)
            }
            .padding(.horizontal, 10)
        }
        .frame(height: 46)
    }

    private func chip(_ title: String, _ value: String, _ p: ManualParam, auto: Bool) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.15)) { param = (param == p) ? nil : p }
        } label: {
            chipBody(title, value, auto, param == p)
        }
    }

    private func chipBody(_ title: String, _ value: String, _ auto: Bool, _ selected: Bool) -> some View {
        VStack(spacing: 1) {
            HStack(spacing: 3) {
                Text(title).font(.system(size: 10, weight: .semibold)).foregroundColor(.white.opacity(0.75))
                if auto {
                    Text("A").font(.system(size: 8, weight: .heavy))
                        .padding(.horizontal, 3)
                        .background(RoundedRectangle(cornerRadius: 2).fill(Theme.accent))
                        .foregroundColor(.white)
                }
            }
            Text(value).font(.system(size: 17, weight: .medium)).foregroundColor(selected ? Theme.yellow : .white)
        }
        .frame(minWidth: 58)
        .padding(.horizontal, 6)
    }
}

// MARK: - Param panel (sliders)

struct ParamPanel: View {
    @ObservedObject var engine: CameraEngine
    let param: ManualParam

    var body: some View {
        VStack(spacing: 8) {
            switch param {
            case .zoom: zoomPanel
            case .shutter: shutterPanel
            case .iso: isoPanel
            case .ev: evPanel
            case .wb: wbPanel
            case .tint: tintPanel
            case .focus: focusPanel
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.black.opacity(0.72)))
    }

    private func header(_ title: String, _ value: String, auto: Binding<Bool>? = nil) -> some View {
        HStack {
            Text(title).font(.system(size: 12, weight: .bold)).foregroundColor(.white.opacity(0.8))
            Text(value).font(.system(size: 14, weight: .semibold, design: .monospaced)).foregroundColor(Theme.yellow)
            Spacer()
            if let auto {
                Toggle("Авто", isOn: auto).toggleStyle(.button).font(.system(size: 12, weight: .bold)).tint(Theme.accent)
            }
        }
    }

    // log-scale helpers
    private func logT(_ v: Double, _ lo: Double, _ hi: Double) -> Double {
        guard lo > 0, hi > lo else { return 0 }
        return min(max(log(max(v, lo) / lo) / log(hi / lo), 0), 1)
    }
    private func fromLogT(_ t: Double, _ lo: Double, _ hi: Double) -> Double { lo * pow(hi / lo, t) }

    private var autoExpBinding: Binding<Bool> {
        Binding(get: { engine.autoExposure }, set: { engine.autoExposure = $0; engine.updateExposure() })
    }

    private var zoomPanel: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                ForEach(engine.availableLenses) { l in
                    Button { engine.setLens(l) } label: {
                        Text(l.rawValue)
                            .font(.system(size: 13, weight: .bold))
                            .frame(maxWidth: .infinity).padding(.vertical, 7)
                            .background(RoundedRectangle(cornerRadius: 8).fill(engine.lens == l ? Theme.accent : Color.white.opacity(0.12)))
                            .foregroundColor(.white)
                    }
                }
            }
            header("ZOOM", String(format: "%.1f×", Double(engine.zoom)))
            Slider(value: Binding(get: { Double(engine.zoom) }, set: { engine.setZoom(CGFloat($0)) }),
                   in: Double(engine.zoomRange.lowerBound)...Double(engine.zoomRange.upperBound))
        }
    }

    private var shutterPanel: some View {
        let r = engine.shutterRange
        return VStack(spacing: 4) {
            header("SHUTTER", formatShutterSeconds(engine.shutterSeconds), auto: autoExpBinding)
            Slider(value: Binding(
                get: { logT(engine.shutterSeconds, r.lowerBound, r.upperBound) },
                set: { t in
                    engine.autoExposure = false
                    engine.shutterSeconds = fromLogT(t, r.lowerBound, r.upperBound)
                    engine.updateExposure()
                }), in: 0...1)
        }
    }

    private var isoPanel: some View {
        let r = engine.isoRange
        return VStack(spacing: 4) {
            header("ISO", "\(Int(engine.iso))", auto: autoExpBinding)
            Slider(value: Binding(
                get: { logT(Double(engine.iso), Double(r.lowerBound), Double(r.upperBound)) },
                set: { t in
                    engine.autoExposure = false
                    engine.iso = Float(fromLogT(t, Double(r.lowerBound), Double(r.upperBound)))
                    engine.updateExposure()
                }), in: 0...1)
        }
    }

    private var evPanel: some View {
        VStack(spacing: 4) {
            header("EV", String(format: "%+.1f", engine.evBias))
            Slider(value: Binding(
                get: { Double(engine.evBias) },
                set: { v in
                    engine.evBias = Float(v)
                    if !engine.autoExposure { engine.autoExposure = true }
                    engine.updateExposure()
                }), in: -3...3, step: 0.1)
            Button("Сбросить") { engine.evBias = 0; engine.updateExposure() }
                .font(.system(size: 12, weight: .semibold)).foregroundColor(.white.opacity(0.8))
        }
    }

    private var wbPanel: some View {
        VStack(spacing: 6) {
            header("WB", "\(Int(engine.wbTemp))K", auto: Binding(get: { engine.autoWB }, set: { engine.autoWB = $0; engine.updateWhiteBalance() }))
            Slider(value: Binding(
                get: { Double(engine.wbTemp) },
                set: { v in
                    engine.autoWB = false
                    engine.wbTemp = Float(v)
                    engine.updateWhiteBalance()
                }), in: 2000...10000, step: 50)
            HStack(spacing: 6) {
                ForEach([(3200, "💡"), (4300, "🌥"), (5600, "☀️"), (6500, "☁️"), (7500, "🌇")], id: \.0) { item in
                    Button {
                        engine.autoWB = false
                        engine.wbTemp = Float(item.0)
                        engine.updateWhiteBalance()
                    } label: {
                        Text("\(item.1) \(item.0)")
                            .font(.system(size: 11, weight: .semibold))
                            .frame(maxWidth: .infinity).padding(.vertical, 5)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.12)))
                            .foregroundColor(.white)
                    }
                }
            }
        }
    }

    private var tintPanel: some View {
        VStack(spacing: 4) {
            header("TINT", "\(Int(engine.wbTint))")
            Slider(value: Binding(
                get: { Double(engine.wbTint) },
                set: { v in
                    engine.autoWB = false
                    engine.wbTint = Float(v)
                    engine.updateWhiteBalance()
                }), in: -150...150, step: 1)
        }
    }

    private var focusPanel: some View {
        VStack(spacing: 4) {
            header("FOCUS", engine.autoFocus ? "AF" : String(format: "%.2f", engine.focusPos),
                   auto: Binding(get: { engine.autoFocus }, set: { engine.autoFocus = $0; engine.updateFocus() }))
            Slider(value: Binding(
                get: { Double(engine.focusPos) },
                set: { v in
                    engine.autoFocus = false
                    engine.focusPos = Float(v)
                    engine.updateFocus()
                }), in: 0...1)
            HStack {
                Text("Макро").font(.system(size: 10)).foregroundColor(.white.opacity(0.6))
                Spacer()
                Text("∞").font(.system(size: 12)).foregroundColor(.white.opacity(0.6))
            }
        }
    }
}

// MARK: - Storage panel

struct StoragePanel: View {
    @ObservedObject var engine: CameraEngine

    var body: some View {
        let bps = max(engine.estimatedBytesPerSecond, 1)
        let remaining = Double(engine.freeBytes) / bps
        let freeGB = Double(engine.freeBytes) / 1_000_000_000
        HStack(spacing: 8) {
            Image(systemName: "iphone").font(.system(size: 22)).foregroundColor(.white)
            VStack(alignment: .leading, spacing: 2) {
                Text(engine.mode == .photo ? String(format: "%.0f GB", freeGB) : formatRemaining(remaining))
                    .font(.system(size: 15, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white)
                Text(engine.mode == .photo ? "свободно" : String(format: "%.0f GB · %.0f Мбит/с", freeGB, bps * 8 / 1_000_000))
                    .font(.system(size: 9)).foregroundColor(.white.opacity(0.7))
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.panel))
    }
}

// MARK: - Mode picker

struct ModePicker: View {
    @ObservedObject var engine: CameraEngine

    var body: some View {
        HStack(spacing: 18) {
            ForEach(CaptureMode.allCases) { m in
                Button { engine.setMode(m) } label: {
                    Text(m.rawValue)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(engine.mode == m ? Theme.yellow : .white.opacity(0.7))
                }
                .disabled(engine.isRecording)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(Theme.bg)
    }
}

// MARK: - Bottom bar

struct BottomBar: View {
    @ObservedObject var engine: CameraEngine

    var body: some View {
        HStack {
            Button {
                if let url = URL(string: "photos-redirect://") { UIApplication.shared.open(url) }
            } label: {
                Group {
                    if let img = engine.lastThumbnail {
                        Image(uiImage: img).resizable().scaledToFill()
                    } else {
                        Image(systemName: "photo.on.rectangle").foregroundColor(.white)
                    }
                }
                .frame(width: 46, height: 46)
                .background(Color.white.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 9))
            }

            Spacer()
            sideButton(icon: auxIcon, active: auxActive) { auxAction() }
            Spacer()

            shutterButton

            Spacer()
            sideButton(icon: "squareshape.split.3x3", active: engine.grid != .off) { cycleGrid() }
            Spacer()
            sideButton(icon: "arrow.triangle.2.circlepath.camera", active: engine.lens == .front) { engine.flipCamera() }
        }
        .padding(.horizontal, 18)
        .padding(.top, 6)
        .padding(.bottom, 10)
        .background(Theme.bg)
    }

    private var auxIcon: String {
        if engine.mode == .photo {
            switch engine.flash {
            case .off: return "bolt.slash.fill"
            case .auto: return "bolt.badge.automatic.fill"
            case .on: return "bolt.fill"
            }
        }
        return engine.torchOn ? "flashlight.on.fill" : "flashlight.off.fill"
    }

    private var auxActive: Bool {
        engine.mode == .photo ? engine.flash != .off : engine.torchOn
    }

    private func auxAction() {
        if engine.mode == .photo {
            guard engine.hasFlash else { engine.flashMessage("На этой камере нет вспышки"); return }
            let all = FlashOption.allCases
            if let i = all.firstIndex(of: engine.flash) { engine.flash = all[(i + 1) % all.count] }
        } else {
            guard engine.hasTorch else { engine.flashMessage("На этой камере нет фонарика"); return }
            engine.setTorch(!engine.torchOn)
        }
    }

    private func cycleGrid() {
        let all = GridType.allCases
        if let i = all.firstIndex(of: engine.grid) { engine.grid = all[(i + 1) % all.count] }
        engine.flashMessage("Сетка: \(engine.grid.rawValue)")
    }

    private func sideButton(icon: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .frame(width: 46, height: 46)
                .background(Circle().fill(active ? Theme.accent : Color.white.opacity(0.12)))
                .foregroundColor(.white)
        }
    }

    private var shutterButton: some View {
        Button {
            if engine.mode == .photo {
                engine.capturePhoto()
            } else if engine.isRecording {
                engine.stopRecording()
            } else {
                engine.startRecording()
            }
        } label: {
            ZStack {
                Circle().stroke(Color.white, lineWidth: 4).frame(width: 74, height: 74)
                if engine.mode == .photo {
                    Circle().fill(Color.white).frame(width: 60, height: 60)
                } else if engine.isRecording {
                    RoundedRectangle(cornerRadius: 6).fill(Theme.rec).frame(width: 30, height: 30)
                } else {
                    Circle().fill(Theme.rec).frame(width: 60, height: 60)
                }
            }
            .animation(.easeOut(duration: 0.15), value: engine.isRecording)
        }
    }
}
