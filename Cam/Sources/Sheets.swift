import SwiftUI
import UniformTypeIdentifiers

// MARK: - Shared bits

struct SectionTitle: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .bold))
            .foregroundColor(.white.opacity(0.55))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 14)
    }
}

struct ChipRow<T: Hashable>: View {
    let items: [T]
    let selected: T?
    let title: (T) -> String
    let action: (T) -> Void
    var enabled: Bool = true

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(items, id: \.self) { item in
                    Button { action(item) } label: {
                        Text(title(item))
                            .font(.system(size: 14, weight: .semibold))
                            .padding(.horizontal, 14).padding(.vertical, 9)
                            .background(RoundedRectangle(cornerRadius: 9).fill(selected == item ? Theme.accent : Color.white.opacity(0.12)))
                            .foregroundColor(.white)
                    }
                    .disabled(!enabled)
                }
            }
        }
        .opacity(enabled ? 1 : 0.45)
    }
}

struct SheetHeader: View {
    let title: String
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        HStack {
            Text(title).font(.title3.weight(.bold)).foregroundColor(.white)
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill").font(.title2).foregroundColor(.white.opacity(0.5))
            }
        }
    }
}

// MARK: - Format

struct FormatSheet: View {
    @ObservedObject var engine: CameraEngine

    private var resolutions: [VideoResolution] {
        VideoResolution.allCases.filter { engine.fpsMap[$0] != nil }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 6) {
                SheetHeader(title: engine.mode == .photo ? "Фото" : "Формат записи")
                if engine.isRecording {
                    Text("Во время записи настройки недоступны")
                        .font(.footnote).foregroundColor(Theme.yellow).frame(maxWidth: .infinity, alignment: .leading)
                }
                if engine.mode == .photo { photoSection } else { videoSection }
            }
            .padding(16)
        }
    }

    @ViewBuilder private var videoSection: some View {
        SectionTitle(text: "Разрешение")
        ChipRow(items: resolutions, selected: engine.resolution, title: { $0.rawValue },
                action: { engine.setResolution($0) }, enabled: !engine.isRecording && engine.mode != .slomo && engine.mode != .timelapse)

        SectionTitle(text: engine.mode == .timelapse ? "Частота кадров (фиксирована)" : "Кадров в секунду")
        ChipRow(items: fpsItems, selected: engine.fps, title: { "\($0)" },
                action: { engine.setFPS($0) }, enabled: !engine.isRecording && engine.mode != .timelapse)

        if engine.mode == .timelapse {
            SectionTitle(text: "Интервал между кадрами")
            ChipRow(items: [0.5, 1, 2, 5, 10, 30], selected: engine.timelapseInterval,
                    title: { $0 < 1 ? "0.5 с" : "\(Int($0)) с" },
                    action: { engine.timelapseInterval = $0 }, enabled: !engine.isRecording)
        }
        if engine.mode == .slomo {
            Text("Slo-mo пишется с высокой частотой и воспроизводится в \(max(engine.fps / 30, 1))× замедлении (30 fps), без звука.")
                .font(.footnote).foregroundColor(.white.opacity(0.6)).frame(maxWidth: .infinity, alignment: .leading)
        }

        SectionTitle(text: "Кодек")
        ChipRow(items: VideoCodec.allCases, selected: engine.codec, title: { $0.rawValue },
                action: { engine.codec = $0 }, enabled: !engine.isRecording)

        SectionTitle(text: "Качество (битрейт)")
        ChipRow(items: BitrateQuality.allCases, selected: engine.bitrateQuality, title: { $0.rawValue },
                action: { engine.bitrateQuality = $0 }, enabled: !engine.isRecording)
        Text(String(format: "≈ %.0f Мбит/с · ≈ %.0f МБ в минуту", engine.estimatedBytesPerSecond * 8 / 1_000_000, engine.estimatedBytesPerSecond * 60 / 1_000_000))
            .font(.footnote).foregroundColor(.white.opacity(0.6)).frame(maxWidth: .infinity, alignment: .leading)

        SectionTitle(text: "Стабилизация")
        ChipRow(items: StabilizationOption.allCases, selected: engine.stabilization, title: { $0.rawValue },
                action: { engine.setStabilization($0) })
    }

    private var fpsItems: [Int] {
        var list = engine.fpsOptions(for: engine.resolution)
        if engine.mode == .slomo { list = list.filter { $0 >= 60 } }
        return list
    }

    @ViewBuilder private var photoSection: some View {
        SectionTitle(text: "Разрешение фото")
        ChipRow(items: engine.photoResolutions, selected: engine.photoResolution, title: { $0.label },
                action: { engine.photoResolution = $0 }, enabled: !engine.rawEnabled)
        if engine.rawAvailable {
            Toggle(isOn: $engine.rawEnabled) {
                VStack(alignment: .leading) {
                    Text("RAW (DNG / ProRAW)").foregroundColor(.white)
                    Text("Без фильтров, 12 MP").font(.footnote).foregroundColor(.white.opacity(0.6))
                }
            }
            .tint(Theme.accent)
            .padding(.top, 10)
        }
        if engine.hasFlash {
            SectionTitle(text: "Вспышка")
            ChipRow(items: FlashOption.allCases, selected: engine.flash, title: { $0.rawValue }, action: { engine.flash = $0 })
        }
    }
}

// MARK: - Looks

struct LooksSheet: View {
    @ObservedObject var engine: CameraEngine
    @State private var importing = false

    private var items: [LookFilter] {
        LookFilter.allCases.filter { $0 != .custom || engine.customLUT != nil }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                SheetHeader(title: "Фильтры и LUT")
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 10)], spacing: 10) {
                    ForEach(items) { l in
                        Button { engine.look = l } label: {
                            VStack(spacing: 6) {
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(LinearGradient(colors: l.swatch, startPoint: .topLeading, endPoint: .bottomTrailing))
                                    .frame(height: 58)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 10)
                                            .stroke(engine.look == l ? Theme.yellow : Color.clear, lineWidth: 3)
                                    )
                                Text(l == .custom ? (engine.customLUT?.name ?? l.rawValue) : l.rawValue)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundColor(engine.look == l ? Theme.yellow : .white)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
                if engine.look != .none {
                    SectionTitle(text: "Интенсивность")
                    HStack {
                        Slider(value: $engine.lookIntensity, in: 0...1)
                        Text("\(Int(engine.lookIntensity * 100))%")
                            .font(.system(size: 13, weight: .semibold, design: .monospaced)).foregroundColor(.white)
                            .frame(width: 48)
                    }
                }
                Button { importing = true } label: {
                    Label("Загрузить .cube LUT", systemImage: "square.and.arrow.down")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(maxWidth: .infinity).padding(.vertical, 12)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.12)))
                        .foregroundColor(.white)
                }
                .padding(.top, 8)
                Text("Фильтр применяется к превью, видео и фото (кроме RAW). На 4K 120 fps тяжёлые фильтры могут снижать плавность — для максимального качества выбери «Оригинал».")
                    .font(.footnote).foregroundColor(.white.opacity(0.55)).frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(16)
        }
        .fileImporter(isPresented: $importing,
                      allowedContentTypes: [UTType(filenameExtension: "cube") ?? .data, .plainText, .data],
                      allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first { engine.importLUT(from: url) }
        }
    }
}

extension LookFilter {
    var swatch: [Color] {
        switch self {
        case .none: return [Color(white: 0.55), Color(white: 0.25)]
        case .vivid: return [.pink, .orange, .yellow]
        case .cinema: return [Color(red: 0.1, green: 0.5, blue: 0.6), Color(red: 0.95, green: 0.55, blue: 0.2)]
        case .warm: return [.orange, .yellow]
        case .cold: return [.cyan, .blue]
        case .vintage: return [Color(red: 0.7, green: 0.55, blue: 0.4), Color(red: 0.35, green: 0.3, blue: 0.3)]
        case .bleach: return [Color(white: 0.8), Color(white: 0.3)]
        case .matte: return [Color(red: 0.5, green: 0.55, blue: 0.6), Color(red: 0.3, green: 0.3, blue: 0.35)]
        case .noir: return [.black, Color(white: 0.5)]
        case .mono: return [Color(white: 0.9), Color(white: 0.2)]
        case .silver: return [Color(white: 0.85), Color(white: 0.45)]
        case .chrome: return [.teal, .indigo]
        case .instant: return [.yellow, .brown]
        case .process: return [.mint, .purple]
        case .transfer: return [.orange, .red]
        case .fade: return [Color(white: 0.8), Color(red: 0.6, green: 0.6, blue: 0.7)]
        case .sepia: return [Color(red: 0.8, green: 0.6, blue: 0.35), Color(red: 0.4, green: 0.25, blue: 0.1)]
        case .custom: return [.purple, .blue, .green]
        }
    }
}

// MARK: - Settings

struct SettingsSheet: View {
    @ObservedObject var engine: CameraEngine

    var body: some View {
        ScrollView {
            VStack(spacing: 6) {
                SheetHeader(title: "Сетка и инструменты")

                SectionTitle(text: "Сетка")
                ChipRow(items: GridType.allCases, selected: engine.grid, title: { $0.rawValue }, action: { engine.grid = $0 })

                SectionTitle(text: "Рамка кадра")
                ChipRow(items: FrameGuide.allCases, selected: engine.guide, title: { $0.rawValue }, action: { engine.guide = $0 })

                SectionTitle(text: "Индикаторы")
                VStack(spacing: 0) {
                    toggle("Гистограмма", $engine.showHistogram)
                    toggle("Аудио-метр", $engine.showAudioMeter)
                    toggle("Уровень (горизонт)", $engine.showLevel)
                    toggle("Память и битрейт", $engine.showInfoPanel)
                }
                .padding(.horizontal, 12)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.08)))

                Text("Жесты: тап по превью — фокус, щипок — зум.")
                    .font(.footnote).foregroundColor(.white.opacity(0.55))
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 12)
            }
            .padding(16)
        }
    }

    private func toggle(_ title: String, _ binding: Binding<Bool>) -> some View {
        Toggle(title, isOn: binding).tint(Theme.accent).foregroundColor(.white).padding(.vertical, 8)
    }
}
