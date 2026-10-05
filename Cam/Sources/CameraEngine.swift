import Foundation
import AVFoundation
import Photos
import CoreImage
import CoreMotion
import ImageIO
import UIKit
import Combine

struct RecordConfig {
    let mode: CaptureMode
    let fps: Int
    let codec: VideoCodec
    let quality: BitrateQuality
    let interval: Double
    let decimate: Int
    let saveToFiles: Bool
}

private final class Recording {
    let writer: AVAssetWriter
    let vInput: AVAssetWriterInput
    let aInput: AVAssetWriterInput?
    let url: URL
    let cfg: RecordConfig
    var sessionStarted = false
    var startPTS = CMTime.zero
    var frameCount = 0
    var nextLapse: Double = 0
    var dropped = 0
    var rawIndex = 0

    init(writer: AVAssetWriter, vInput: AVAssetWriterInput, aInput: AVAssetWriterInput?, url: URL, cfg: RecordConfig) {
        self.writer = writer
        self.vInput = vInput
        self.aInput = aInput
        self.url = url
        self.cfg = cfg
    }
}

private struct RenderState {
    var look: LookFilter = .none
    var lut: CubeLUT?
    var intensity: Double = 1
    var detectFaces = false
    var detectHands = false
    var detectFingers = false
    var blurFaces = false
    var blurStrength: Double = 0.5
    var glitchQuad = false
    var glitchStrength: Double = 0.7
    var quadEffects: Set<QuadEffect> = [.invert, .glitch]
}

final class CameraEngine: NSObject, ObservableObject {

    // MARK: - Published UI state

    @Published var mode: CaptureMode = .video
    @Published var resolution: VideoResolution = .uhd4k
    @Published var fps: Int = 30
    @Published var codec: VideoCodec = .hevc
    @Published var bitrateQuality: BitrateQuality = .high
    @Published var stabilization: StabilizationOption = .standard
    @Published var lens: LensKind = .wide
    @Published var availableLenses: [LensKind] = []
    @Published var fpsMap: [VideoResolution: [Int]] = [:]
    @Published var photoResolutions: [PhotoResolutionOption] = []
    @Published var photoResolution: PhotoResolutionOption?
    @Published var rawEnabled = false
    @Published var rawAvailable = false
    @Published var flash: FlashOption = .off
    @Published var hasFlash = false
    @Published var torchOn = false
    @Published var hasTorch = false
    @Published var timelapseInterval: Double = 2

    @Published var autoExposure = true
    @Published var iso: Float = 100
    @Published var isoRange: ClosedRange<Float> = 25...3200
    @Published var shutterSeconds: Double = 1.0 / 60
    @Published var shutterRange: ClosedRange<Double> = (1.0 / 8000)...(1.0 / 30)
    @Published var evBias: Float = 0
    @Published var autoWB = true
    @Published var wbTemp: Float = 5500
    @Published var wbTint: Float = 0
    @Published var autoFocus = true
    @Published var focusPos: Float = 0.5
    @Published var zoom: CGFloat = 1
    @Published var zoomRange: ClosedRange<CGFloat> = 1...10
    @Published var focalLengthMM: Int = 24

    @Published var look: LookFilter = .none { didSet { syncRenderState() } }
    @Published var lookIntensity: Double = 1 { didSet { syncRenderState() } }
    @Published var customLUT: CubeLUT? { didSet { syncRenderState() } }

    @Published var detectFaces = false { didSet { visionSettingChanged() } }
    @Published var detectHands = false { didSet { visionSettingChanged() } }
    @Published var detectFingers = false { didSet { visionSettingChanged() } }
    @Published var blurFaces = false { didSet { visionSettingChanged() } }
    @Published var blurStrength: Double = 0.5 { didSet { syncRenderState() } }
    @Published var glitchQuad = false { didSet { visionSettingChanged() } }
    @Published var glitchStrength: Double = 0.7 { didSet { syncRenderState() } }
    @Published var quadEffects: Set<QuadEffect> = [.invert, .glitch] { didSet { syncRenderState() } }
    @Published var detections = Detections()
    @Published var aeafLocked = false
    @Published var highFPSSave: HighFPSSaveMode = .files

    @Published var grid: GridType = .thirds
    @Published var guide: FrameGuide = .off
    @Published var showHistogram = true
    @Published var showAudioMeter = true
    @Published var showLevel = true
    @Published var showInfoPanel = true

    @Published var histogram: [Float] = Array(repeating: 0, count: 64)
    @Published var audioLevels: [Float] = [-60, -60]
    @Published var rollDegrees: Double = 0
    @Published var micName: String = "Микрофон iPhone"

    @Published var isRecording = false
    @Published var recordSeconds: Double = 0
    @Published var statusMessage: String?
    @Published var videoSize = CGSize(width: 9, height: 16)
    @Published var authorized = false
    @Published var lastThumbnail: UIImage?
    @Published var freeBytes: Int64 = 0
    @Published var photoFlashTick = 0

    // MARK: - Capture plumbing

    let session = AVCaptureSession()
    weak var displayLayer: AVSampleBufferDisplayLayer?

    private let sessionQueue = DispatchQueue(label: "cam.session")
    private let captureQueue = DispatchQueue(label: "cam.capture", qos: .userInteractive)

    private var device: AVCaptureDevice?
    private var videoInput: AVCaptureDeviceInput?
    private var audioInput: AVCaptureDeviceInput?
    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private let photoOutput = AVCapturePhotoOutput()
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var rotationObservation: NSKeyValueObservation?
    private var configured = false

    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private let vision = VisionTracker()
    private var lastVisionTime = CFAbsoluteTimeGetCurrent()
    private var smallPool: CVPixelBufferPool?
    private var smallPoolSize = (0, 0)
    private let videoRenderer = LookRenderer()
    private let photoRenderer = LookRenderer()
    private let rec709 = CGColorSpace(name: CGColorSpace.itur_709) ?? CGColorSpaceCreateDeviceRGB()

    private let stateLock = NSLock()
    private var renderState = RenderState()

    // captureQueue-only state
    private var recording: Recording?
    private var pendingConfig: RecordConfig?
    private var pixelPool: CVPixelBufferPool?
    private var poolSize = (0, 0)
    private var frameCounter = 0
    private var lastHistogramTime = CFAbsoluteTimeGetCurrent()
    private var lastAudioPublish = CFAbsoluteTimeGetCurrent()
    private var lastVideoSize = CGSize.zero
    private var captureFPS = 30
    var histogramVisible = true

    private var recordingFlag = false
    private var lastVideoRes: VideoResolution = .uhd4k
    private var lastVideoFPS = 30

    private let motion = CMMotionManager()
    private var pollTimer: Timer?
    private var recordTimer: Timer?
    private var recordStart = Date()

    private let standardFPS = [24, 25, 30, 48, 50, 60, 100, 120, 240]

    // MARK: - Lifecycle

    func start() {
        UIApplication.shared.isIdleTimerDisabled = true
        vision.onResult = { [weak self] d in
            DispatchQueue.main.async { self?.detections = d }
        }
        Task {
            let cam = await AVCaptureDevice.requestAccess(for: .video)
            _ = await AVCaptureDevice.requestAccess(for: .audio)
            _ = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            await MainActor.run {
                self.authorized = cam
                if !cam { self.statusMessage = "Нет доступа к камере. Разрешите в Настройках iOS." }
            }
            guard cam else { return }
            self.sessionQueue.async {
                self.configureSession()
                self.session.startRunning()
            }
            await MainActor.run {
                self.startMotion()
                self.startPolling()
                self.refreshThumbnail()
                self.observeSessionEvents()
            }
        }
    }

    private func observeSessionEvents() {
        NotificationCenter.default.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: .main) { [weak self] _ in
            if self?.isRecording == true { self?.stopRecording() }
        }
        NotificationCenter.default.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: .main) { [weak self] _ in
            self?.sessionQueue.async { if let s = self?.session, !s.isRunning { s.startRunning() } }
        }
        NotificationCenter.default.addObserver(forName: AVCaptureDevice.subjectAreaDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, !self.aeafLocked else { return }
            self.resetFocusToContinuous()
        }
        NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.updateMicName()
        }
    }

    private func updateMicName() {
        let name = AVAudioSession.sharedInstance().currentRoute.inputs.first?.portName ?? "Микрофон iPhone"
        micName = name
    }

    private func onMain(_ block: @escaping () -> Void) {
        if Thread.isMainThread { block() } else { DispatchQueue.main.async(execute: block) }
    }

    func flashMessage(_ text: String) {
        onMain {
            self.statusMessage = text
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                if self.statusMessage == text { self.statusMessage = nil }
            }
        }
    }

    // MARK: - Render state

    private func syncRenderState() {
        stateLock.lock()
        renderState = RenderState(look: look, lut: customLUT, intensity: lookIntensity,
                                  detectFaces: detectFaces, detectHands: detectHands,
                                  detectFingers: detectFingers, blurFaces: blurFaces, blurStrength: blurStrength,
                                  glitchQuad: glitchQuad, glitchStrength: glitchStrength,
                                  quadEffects: quadEffects)
        stateLock.unlock()
    }

    private func visionSettingChanged() {
        syncRenderState()
        if !detectFaces && !detectHands && !detectFingers && !blurFaces && !glitchQuad {
            vision.reset()
            detections = Detections()
        }
    }

    private func currentRenderState() -> RenderState {
        stateLock.lock(); defer { stateLock.unlock() }
        return renderState
    }

    func importLUT(from url: URL) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let lut = try CubeLUT.parse(url: url)
            customLUT = lut
            look = .custom
            flashMessage("LUT загружен: \(lut.name)")
        } catch {
            flashMessage(error.localizedDescription)
        }
    }

    // MARK: - Session configuration

    private func configureSession() {
        guard !configured else { return }
        configured = true

        session.beginConfiguration()
        session.sessionPreset = .inputPriority

        if let mic = AVCaptureDevice.default(for: .audio),
           let input = try? AVCaptureDeviceInput(device: mic), session.canAddInput(input) {
            session.addInput(input)
            audioInput = input
        }

        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: captureQueue)
        if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }

        audioOutput.setSampleBufferDelegate(self, queue: captureQueue)
        if session.canAddOutput(audioOutput) { session.addOutput(audioOutput) }

        if session.canAddOutput(photoOutput) { session.addOutput(photoOutput) }
        session.commitConfiguration()

        var lenses: [LensKind] = []
        for l in LensKind.allCases where AVCaptureDevice.default(l.deviceType, for: .video, position: l.position) != nil {
            lenses.append(l)
        }
        let startLens: LensKind = lenses.contains(.wide) ? .wide : (lenses.first ?? .wide)
        onMain {
            self.availableLenses = lenses
            self.lens = startLens
            self.updateMicName()
        }
        switchDevice(to: startLens)
    }

    private func switchDevice(to newLens: LensKind) {
        guard let dev = AVCaptureDevice.default(newLens.deviceType, for: .video, position: newLens.position) else {
            flashMessage("Эта камера недоступна")
            return
        }
        session.beginConfiguration()
        let old = videoInput
        if let old { session.removeInput(old) }
        do {
            let input = try AVCaptureDeviceInput(device: dev)
            if session.canAddInput(input) {
                session.addInput(input)
                videoInput = input
                device = dev
            } else if let old, session.canAddInput(old) {
                session.addInput(old)
            }
        } catch {
            if let old, session.canAddInput(old) { session.addInput(old) }
            flashMessage("Не удалось переключить камеру")
        }
        session.commitConfiguration()

        guard let d = device else { return }
        // Never carry flash/torch over to another camera (front screen would go full-white).
        do {
            try d.lockForConfiguration()
            if d.hasTorch, d.torchMode != .off { d.torchMode = .off }
            d.unlockForConfiguration()
        } catch {}
        onMain { self.torchOn = false; self.flash = .off }
        setupRotation(for: d)
        applyMirroring(front: newLens == .front)
        refreshCapabilities()

        let m = DispatchQueue.main.sync { self.mode }
        switch m {
        case .photo: configurePhotoFormat()
        default:
            let (r, f) = DispatchQueue.main.sync { (self.resolution, self.fps) }
            applyVideoFormat(res: r, fps: f)
        }
        afterFormatChange()
    }

    private func setupRotation(for dev: AVCaptureDevice) {
        rotationObservation = nil
        let coordinator = AVCaptureDevice.RotationCoordinator(device: dev, previewLayer: nil)
        rotationCoordinator = coordinator
        rotationObservation = coordinator.observe(\.videoRotationAngleForHorizonLevelCapture, options: [.initial, .new]) { [weak self] _, _ in
            self?.sessionQueue.async { self?.applyRotation() }
        }
    }

    private func applyRotation() {
        guard !recordingFlag, let coordinator = rotationCoordinator else { return }
        let angle = coordinator.videoRotationAngleForHorizonLevelCapture
        for conn in [videoOutput.connection(with: .video), photoOutput.connection(with: .video)] {
            if let conn, conn.isVideoRotationAngleSupported(angle) { conn.videoRotationAngle = angle }
        }
    }

    private func applyMirroring(front: Bool) {
        if let conn = videoOutput.connection(with: .video) {
            conn.automaticallyAdjustsVideoMirroring = false
            if conn.isVideoMirroringSupported { conn.isVideoMirrored = front }
        }
        if let conn = photoOutput.connection(with: .video) {
            conn.automaticallyAdjustsVideoMirroring = false
            if conn.isVideoMirroringSupported { conn.isVideoMirrored = front }
        }
        applyRotation()
    }

    // MARK: - Capabilities

    private func is8BitBiPlanar(_ f: AVCaptureDevice.Format) -> Bool {
        let st = CMFormatDescriptionGetMediaSubType(f.formatDescription)
        return st == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange || st == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
    }

    private func supports(_ f: AVCaptureDevice.Format, fps: Int) -> Bool {
        f.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= Double(fps) + 0.01 && Double(fps) <= $0.maxFrameRate + 0.01 }
    }

    private func refreshCapabilities() {
        guard let d = device else { return }
        var map: [VideoResolution: Set<Int>] = [:]
        for f in d.formats where is8BitBiPlanar(f) {
            let dim = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            for r in VideoResolution.allCases where dim.width == r.width && dim.height == r.height {
                for s in standardFPS where supports(f, fps: s) { map[r, default: []].insert(s) }
            }
        }
        let sorted = map.mapValues { $0.sorted() }
        let flash = d.hasFlash
        let torch = d.hasTorch
        let raw = !photoOutput.availableRawPhotoPixelFormatTypes.isEmpty
        onMain {
            self.fpsMap = sorted
            self.hasFlash = flash
            self.hasTorch = torch
            self.rawAvailable = raw
            if !raw { self.rawEnabled = false }
        }
    }

    private func bestFormat(_ d: AVCaptureDevice, res: VideoResolution, fps: Int) -> AVCaptureDevice.Format? {
        let candidates = d.formats.filter { f in
            guard is8BitBiPlanar(f) else { return false }
            let dim = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            return dim.width == res.width && dim.height == res.height && supports(f, fps: fps)
        }
        func score(_ f: AVCaptureDevice.Format) -> Int {
            var s = 0
            if f.isVideoStabilizationModeSupported(.cinematic) { s += 2 }
            if !f.isVideoBinned { s += 1 }
            return s
        }
        return candidates.max { score($0) < score($1) }
    }

    // MARK: - Format control

    private func applyVideoFormat(res: VideoResolution, fps: Int) {
        guard let d = device else { return }
        session.beginConfiguration()
        if let fmt = bestFormat(d, res: res, fps: fps) {
            do {
                try d.lockForConfiguration()
                d.activeFormat = fmt
                let dur = CMTime(value: 1, timescale: CMTimeScale(fps))
                d.activeVideoMinFrameDuration = dur
                d.activeVideoMaxFrameDuration = dur
                d.unlockForConfiguration()
                captureFPS = fps
            } catch {
                flashMessage("Не удалось применить формат")
            }
        } else {
            flashMessage("\(res.rawValue) \(fps) fps не поддерживается этой камерой")
        }
        session.commitConfiguration()
        applyMirroring(front: lens == .front)
    }

    private func configurePhotoFormat() {
        guard let d = device else { return }
        session.beginConfiguration()
        session.sessionPreset = .photo
        session.commitConfiguration()
        captureFPS = 30

        var dims = d.activeFormat.supportedMaxPhotoDimensions
        dims.sort { Int($0.width) * Int($0.height) < Int($1.width) * Int($1.height) }
        if let maxD = dims.last {
            session.beginConfiguration()
            photoOutput.maxPhotoDimensions = maxD
            session.commitConfiguration()
        }
        var options: [PhotoResolutionOption] = []
        for dim in dims {
            let o = PhotoResolutionOption(dims: dim)
            if !options.contains(o) { options.append(o) }
        }
        onMain {
            self.photoResolutions = options
            if let cur = self.photoResolution, options.contains(cur) { return }
            // default: closest to 12 MP
            self.photoResolution = options.min {
                abs(Int($0.dims.width) * Int($0.dims.height) - 12_000_000) < abs(Int($1.dims.width) * Int($1.dims.height) - 12_000_000)
            }
        }
        applyMirroring(front: lens == .front)
    }

    private func afterFormatChange() {
        guard let d = device else { return }
        let isPhoto = DispatchQueue.main.sync { self.mode == .photo }
        let fmt = d.activeFormat

        // Zoom
        let minZ = max(1, d.minAvailableVideoZoomFactor)
        let maxZ = min(fmt.videoMaxZoomFactor, 20)
        // ISO / shutter
        let isoR = fmt.minISO...max(fmt.maxISO, fmt.minISO + 1)
        let minS = max(CMTimeGetSeconds(fmt.minExposureDuration), 1.0 / 20000)
        var maxS = CMTimeGetSeconds(fmt.maxExposureDuration)
        if !isPhoto { maxS = min(maxS, 1.0 / Double(max(captureFPS, 1))) } else { maxS = min(maxS, 1.0) }
        let shutR = minS...max(maxS, minS * 2)
        // focal length
        let fov = Double(fmt.videoFieldOfView)
        let focal = fov > 1 ? 18.0 / tan(fov * .pi / 180 / 2) : 24
        // stabilization
        applyStabilization()

        do {
            try d.lockForConfiguration()
            d.videoZoomFactor = minZ
            if d.isSmoothAutoFocusSupported { d.isSmoothAutoFocusEnabled = !isPhoto }
            d.autoFocusRangeRestriction = .none
            d.unlockForConfiguration()
        } catch {}

        onMain {
            self.zoomRange = minZ...max(maxZ, minZ + 0.01)
            self.zoom = minZ
            self.isoRange = isoR
            self.iso = min(max(self.iso, isoR.lowerBound), isoR.upperBound)
            self.shutterRange = shutR
            self.shutterSeconds = min(max(self.shutterSeconds, shutR.lowerBound), shutR.upperBound)
            self.focalLengthMM = Int(focal.rounded())
            self.applyAllManualSettings()
        }
    }

    private func applyStabilization() {
        guard let d = device, let conn = videoOutput.connection(with: .video) else { return }
        let wanted = DispatchQueue.main.sync { (self.stabilization, self.mode == .photo) }
        let mode: AVCaptureVideoStabilizationMode = wanted.1 ? .off : wanted.0.mode
        if mode == .off || d.activeFormat.isVideoStabilizationModeSupported(mode) {
            if conn.isVideoStabilizationSupported { conn.preferredVideoStabilizationMode = mode }
        } else if conn.isVideoStabilizationSupported {
            conn.preferredVideoStabilizationMode = .auto
        }
    }

    // MARK: - Public setters (UI)

    func setMode(_ m: CaptureMode) {
        guard !isRecording, m != mode else { return }
        mode = m
        torchOn = false
        let res = lastVideoRes, f = lastVideoFPS
        sessionQueue.async {
            switch m {
            case .photo:
                self.configurePhotoFormat()
            case .video:
                self.onMain { self.resolution = res; self.fps = f }
                self.applyVideoFormat(res: res, fps: f)
            case .slomo:
                let (r, s) = self.pickSlomo()
                self.onMain { self.resolution = r; self.fps = s }
                self.applyVideoFormat(res: r, fps: s)
            case .timelapse:
                let map = DispatchQueue.main.sync { self.fpsMap }
                let r = (map[res]?.contains(30) == true) ? res : .hd1080
                self.onMain { self.resolution = r; self.fps = 30 }
                self.applyVideoFormat(res: r, fps: 30)
            }
            self.afterFormatChange()
        }
    }

    private func pickSlomo() -> (VideoResolution, Int) {
        let map = DispatchQueue.main.sync { self.fpsMap }
        for r in [VideoResolution.hd1080, .hd720, .uhd4k] {
            if let list = map[r] {
                if list.contains(240) { return (r, 240) }
            }
        }
        for r in [VideoResolution.hd1080, .uhd4k, .hd720] {
            if let list = map[r], list.contains(120) { return (r, 120) }
        }
        flashMessage("Эта камера не снимает 120/240 fps")
        return (resolution, fps)
    }

    func fpsOptions(for res: VideoResolution) -> [Int] {
        fpsMap[res] ?? []
    }

    func setResolution(_ r: VideoResolution) {
        guard !isRecording else { return }
        let options = fpsOptions(for: r)
        var newFPS = fps
        if !options.contains(newFPS) {
            newFPS = options.last(where: { $0 <= fps }) ?? options.first ?? 30
        }
        resolution = r
        fps = newFPS
        if mode == .video { lastVideoRes = r; lastVideoFPS = newFPS }
        let rr = r, ff = newFPS
        sessionQueue.async {
            self.applyVideoFormat(res: rr, fps: ff)
            self.afterFormatChange()
        }
    }

    func setFPS(_ f: Int) {
        guard !isRecording else { return }
        fps = f
        if mode == .video { lastVideoFPS = f }
        let r = resolution
        sessionQueue.async {
            self.applyVideoFormat(res: r, fps: f)
            self.afterFormatChange()
        }
    }

    func setStabilization(_ s: StabilizationOption) {
        stabilization = s
        sessionQueue.async { self.applyStabilization() }
    }

    func setLens(_ l: LensKind) {
        guard !isRecording, l != lens else { return }
        lens = l
        sessionQueue.async { self.switchDevice(to: l) }
    }

    func flipCamera() {
        if lens == .front {
            setLens(availableLenses.contains(.wide) ? .wide : (availableLenses.first ?? .wide))
        } else if availableLenses.contains(.front) {
            setLens(.front)
        }
    }

    func setTorch(_ on: Bool) {
        torchOn = on
        sessionQueue.async {
            guard let d = self.device, d.hasTorch else { return }
            do {
                try d.lockForConfiguration()
                d.torchMode = on ? .on : .off
                d.unlockForConfiguration()
            } catch {}
        }
    }

    // MARK: - Manual controls

    func applyAllManualSettings() {
        updateExposure()
        updateWhiteBalance()
        updateFocus()
    }

    func updateExposure() {
        let auto = autoExposure, iso = self.iso, shutter = shutterSeconds, ev = evBias
        sessionQueue.async {
            guard let d = self.device else { return }
            do {
                try d.lockForConfiguration()
                if auto {
                    if d.isExposureModeSupported(.continuousAutoExposure) { d.exposureMode = .continuousAutoExposure }
                    let bias = min(max(ev, d.minExposureTargetBias), d.maxExposureTargetBias)
                    d.setExposureTargetBias(bias, completionHandler: nil)
                } else {
                    let f = d.activeFormat
                    let minD = CMTimeGetSeconds(f.minExposureDuration)
                    let maxD = CMTimeGetSeconds(f.maxExposureDuration)
                    let s = min(max(shutter, minD), maxD)
                    let isoC = min(max(iso, f.minISO), f.maxISO)
                    d.setExposureModeCustom(duration: CMTimeMakeWithSeconds(s, preferredTimescale: 1_000_000_000), iso: isoC, completionHandler: nil)
                }
                d.unlockForConfiguration()
            } catch {}
        }
    }

    func updateWhiteBalance() {
        let auto = autoWB, t = wbTemp, tint = wbTint
        sessionQueue.async {
            guard let d = self.device else { return }
            do {
                try d.lockForConfiguration()
                if auto {
                    if d.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { d.whiteBalanceMode = .continuousAutoWhiteBalance }
                } else if d.isLockingWhiteBalanceWithCustomDeviceGainsSupported {
                    let tt = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(temperature: t, tint: tint)
                    var g = d.deviceWhiteBalanceGains(for: tt)
                    let maxG = d.maxWhiteBalanceGain
                    g.redGain = min(max(g.redGain, 1), maxG)
                    g.greenGain = min(max(g.greenGain, 1), maxG)
                    g.blueGain = min(max(g.blueGain, 1), maxG)
                    d.setWhiteBalanceModeLocked(with: g, completionHandler: nil)
                }
                d.unlockForConfiguration()
            } catch {}
        }
    }

    func updateFocus() {
        let auto = autoFocus, pos = focusPos
        sessionQueue.async {
            guard let d = self.device else { return }
            do {
                try d.lockForConfiguration()
                if auto {
                    if d.isFocusModeSupported(.continuousAutoFocus) { d.focusMode = .continuousAutoFocus }
                } else if d.isLockingFocusWithCustomLensPositionSupported {
                    d.setFocusModeLocked(lensPosition: min(max(pos, 0), 1), completionHandler: nil)
                }
                d.unlockForConfiguration()
            } catch {}
        }
    }

    func setZoom(_ z: CGFloat) {
        let clamped = min(max(z, zoomRange.lowerBound), zoomRange.upperBound)
        zoom = clamped
        sessionQueue.async {
            guard let d = self.device else { return }
            do {
                try d.lockForConfiguration()
                d.videoZoomFactor = clamped
                d.unlockForConfiguration()
            } catch {}
            let fov = Double(d.activeFormat.videoFieldOfView)
            if fov > 1 {
                let f = 18.0 / tan(fov * .pi / 180 / 2) * Double(clamped)
                self.onMain { self.focalLengthMM = Int(f.rounded()) }
            }
        }
    }

    private func devicePoint(_ point: CGPoint, isFront: Bool) -> CGPoint {
        let angle = rotationCoordinator?.videoRotationAngleForHorizonLevelCapture ?? 90
        let x = isFront ? 1 - point.x : point.x
        let y = point.y
        var p: CGPoint
        switch Int(angle.rounded()) % 360 {
        case 0: p = CGPoint(x: x, y: y)
        case 180: p = CGPoint(x: 1 - x, y: 1 - y)
        case 270: p = CGPoint(x: 1 - y, y: x)
        default: p = CGPoint(x: y, y: 1 - x)
        }
        p.x = min(max(p.x, 0), 1)
        p.y = min(max(p.y, 0), 1)
        return p
    }

    /// Tap: focus + metering at the point, then keep tracking (continuous AF/AE around that point).
    /// `point` is normalized (0...1) inside the visible preview.
    func focus(at point: CGPoint) {
        autoFocus = true
        aeafLocked = false
        let isFront = lens == .front
        let autoExp = autoExposure
        sessionQueue.async {
            guard let d = self.device else { return }
            let p = self.devicePoint(point, isFront: isFront)
            do {
                try d.lockForConfiguration()
                if d.isFocusPointOfInterestSupported {
                    d.focusPointOfInterest = p
                    if d.isFocusModeSupported(.continuousAutoFocus) { d.focusMode = .continuousAutoFocus }
                    else if d.isFocusModeSupported(.autoFocus) { d.focusMode = .autoFocus }
                }
                if autoExp, d.isExposurePointOfInterestSupported {
                    d.exposurePointOfInterest = p
                    if d.isExposureModeSupported(.continuousAutoExposure) { d.exposureMode = .continuousAutoExposure }
                }
                d.isSubjectAreaChangeMonitoringEnabled = true
                d.unlockForConfiguration()
            } catch {}
        }
    }

    /// Long press: focus + exposure at the point and lock both (AE/AF LOCK).
    func lockFocusAndExposure(at point: CGPoint) {
        autoFocus = true
        aeafLocked = true
        let isFront = lens == .front
        sessionQueue.async {
            guard let d = self.device else { return }
            let p = self.devicePoint(point, isFront: isFront)
            do {
                try d.lockForConfiguration()
                if d.isFocusPointOfInterestSupported && d.isFocusModeSupported(.autoFocus) {
                    d.focusPointOfInterest = p
                    d.focusMode = .autoFocus
                }
                if d.isExposurePointOfInterestSupported && d.isExposureModeSupported(.autoExpose) {
                    d.exposurePointOfInterest = p
                    d.exposureMode = .autoExpose
                }
                d.isSubjectAreaChangeMonitoringEnabled = false
                d.unlockForConfiguration()
            } catch {}
            // Let AF/AE converge, then freeze them.
            self.sessionQueue.asyncAfter(deadline: .now() + 0.9) {
                guard DispatchQueue.main.sync(execute: { self.aeafLocked }) else { return }
                do {
                    try d.lockForConfiguration()
                    if d.isFocusModeSupported(.locked) { d.focusMode = .locked }
                    if d.isExposureModeSupported(.locked) { d.exposureMode = .locked }
                    d.unlockForConfiguration()
                } catch {}
            }
        }
        flashMessage("AE/AF заблокированы")
    }

    func unlockFocusAndExposure() {
        aeafLocked = false
        resetFocusToContinuous()
    }

    private func resetFocusToContinuous() {
        let autoFocusOn = autoFocus
        let autoExp = autoExposure
        sessionQueue.async {
            guard let d = self.device else { return }
            do {
                try d.lockForConfiguration()
                let center = CGPoint(x: 0.5, y: 0.5)
                if autoFocusOn {
                    if d.isFocusPointOfInterestSupported { d.focusPointOfInterest = center }
                    if d.isFocusModeSupported(.continuousAutoFocus) { d.focusMode = .continuousAutoFocus }
                }
                if autoExp {
                    if d.isExposurePointOfInterestSupported { d.exposurePointOfInterest = center }
                    if d.isExposureModeSupported(.continuousAutoExposure) { d.exposureMode = .continuousAutoExposure }
                }
                d.isSubjectAreaChangeMonitoringEnabled = true
                d.unlockForConfiguration()
            } catch {}
        }
    }

    // MARK: - Polling (auto values, storage)

    private func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.pollDevice()
        }
        updateFreeSpace()
    }

    private func pollDevice() {
        guard let d = device else { return }
        if autoExposure {
            iso = d.iso
            let s = CMTimeGetSeconds(d.exposureDuration)
            if s > 0 { shutterSeconds = s }
        }
        if autoWB {
            let g = d.deviceWhiteBalanceGains
            let maxG = d.maxWhiteBalanceGain
            if g.redGain >= 1, g.greenGain >= 1, g.blueGain >= 1, g.redGain <= maxG, g.greenGain <= maxG, g.blueGain <= maxG {
                let tt = d.temperatureAndTintValues(for: g)
                wbTemp = tt.temperature
                wbTint = tt.tint
            }
        }
        if autoFocus { focusPos = d.lensPosition }
        if Int(Date().timeIntervalSince1970 * 4) % 8 == 0 { updateFreeSpace() }
    }

    private func updateFreeSpace() {
        if let v = try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let cap = v.volumeAvailableCapacityForImportantUsage {
            freeBytes = cap
        }
    }

    var estimatedBytesPerSecond: Double {
        let dims = (Double(resolution.width), Double(resolution.height))
        let outFPS = mode == .video ? Double(fps) : 30
        let factor = codec == .h264 ? 1.6 : 1.0
        let bits = min(max(dims.0 * dims.1 * outFPS * bitrateQuality.bpp * factor, 4_000_000), 400_000_000)
        return bits / 8
    }

    private func startMotion() {
        guard motion.isDeviceMotionAvailable else { return }
        motion.deviceMotionUpdateInterval = 1.0 / 20.0
        motion.startDeviceMotionUpdates(to: .main) { [weak self] m, _ in
            guard let g = m?.gravity else { return }
            let angle = atan2(g.x, -g.y)           // 0 when upright in portrait
            let quarter = Double.pi / 2
            let rel = angle - (angle / quarter).rounded() * quarter
            self?.rollDegrees = rel * 180 / .pi
        }
    }

    // MARK: - Photo

    /// Shutter via hardware buttons: photo in photo mode, start/stop in video modes.
    func primaryAction() {
        guard authorized else { return }
        if mode == .photo { capturePhoto() }
        else if isRecording { stopRecording() }
        else { startRecording() }
    }

    func capturePhoto() {
        guard mode == .photo, !isRecording else { return }
        let flashMode = flash.mode
        let dims = photoResolution?.dims
        let wantRaw = rawEnabled
        photoFlashTick += 1
        sessionQueue.async {
            guard self.session.isRunning, let d = self.device else { return }
            var settings: AVCapturePhotoSettings
            if wantRaw, let fmt = self.photoOutput.availableRawPhotoPixelFormatTypes.first(where: { AVCapturePhotoOutput.isAppleProRAWPixelFormat($0) })
                ?? self.photoOutput.availableRawPhotoPixelFormatTypes.first {
                settings = AVCapturePhotoSettings(rawPixelFormatType: fmt)
            } else {
                if self.photoOutput.availablePhotoCodecTypes.contains(.hevc) {
                    settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
                } else {
                    settings = AVCapturePhotoSettings()
                }
                if let dims { settings.maxPhotoDimensions = dims }
                // Flash (incl. the front-screen "Retina Flash") only when explicitly chosen.
                if d.hasFlash, flashMode != .off, self.photoOutput.supportedFlashModes.contains(flashMode) { settings.flashMode = flashMode }
                else { settings.flashMode = .off }
            }
            self.applyRotation()
            self.photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }

    private func saveToLibrary(photo data: Data, dng: Bool) {
        PHPhotoLibrary.shared().performChanges({
            let req = PHAssetCreationRequest.forAsset()
            let opts = PHAssetResourceCreationOptions()
            if dng { opts.uniformTypeIdentifier = "com.adobe.raw-image" }
            req.addResource(with: .photo, data: data, options: opts)
        }) { ok, err in
            if ok { self.onMain { self.refreshThumbnail() } }
            else { self.flashMessage("Не удалось сохранить фото: \(err?.localizedDescription ?? "")") }
        }
    }

    private func saveVideoToFiles(at url: URL) {
        let fm = FileManager.default
        guard let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first else { saveVideo(at: url); return }
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        let dest = docs.appendingPathComponent("Cam-\(f.string(from: Date())).mov")
        do {
            try fm.moveItem(at: url, to: dest)
            flashMessage("Сохранено: Файлы → На iPhone → Cam Pro")
        } catch {
            saveVideo(at: url)
        }
    }

    /// Compares the file duration with wall-clock time to catch timing bugs.
    private func checkDuration(of rec: Recording) {
        guard rec.cfg.mode == .video else { return }
        let asset = AVURLAsset(url: rec.url)
        let fileSec = CMTimeGetSeconds(asset.duration)
        let wall = DispatchQueue.main.sync { self.recordSeconds }
        if wall > 2, fileSec.isFinite, abs(fileSec - wall) / wall > 0.2 {
            flashMessage(String(format: "Длительность файла %.1f с, запись %.1f с", fileSec, wall))
        }
    }

    private func saveVideo(at url: URL) {
        PHPhotoLibrary.shared().performChanges({
            PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
        }) { ok, err in
            try? FileManager.default.removeItem(at: url)
            if ok {
                self.flashMessage("Видео сохранено в Фото")
                self.onMain { self.refreshThumbnail() }
            } else {
                self.flashMessage("Не удалось сохранить видео: \(err?.localizedDescription ?? "")")
            }
        }
    }

    func refreshThumbnail() {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else { return }
        let opts = PHFetchOptions()
        opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        opts.fetchLimit = 1
        guard let asset = PHAsset.fetchAssets(with: opts).firstObject else { return }
        let ro = PHImageRequestOptions()
        ro.deliveryMode = .opportunistic
        ro.resizeMode = .fast
        PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: 160, height: 160), contentMode: .aspectFill, options: ro) { img, _ in
            if let img { self.onMain { self.lastThumbnail = img } }
        }
    }

    // MARK: - Recording

    func startRecording() {
        guard mode.isVideoLike, !isRecording, session.isRunning else { return }
        var decimate = 1
        var toFiles = false
        if mode == .video && fps >= 100 {
            switch highFPSSave {
            case .files: toFiles = true
            case .photosSlowmo: break
            case .photosReal60: decimate = max(1, fps / 60)
            }
        }
        let cfg = RecordConfig(mode: mode, fps: fps, codec: codec, quality: bitrateQuality, interval: timelapseInterval,
                               decimate: decimate, saveToFiles: toFiles)
        isRecording = true
        recordingFlag = true
        recordSeconds = 0
        recordStart = Date()
        recordTimer?.invalidate()
        recordTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.recordSeconds = Date().timeIntervalSince(self.recordStart)
        }
        captureQueue.async { self.pendingConfig = cfg }
        sessionQueue.async { self.videoOutput.alwaysDiscardsLateVideoFrames = false }
    }

    func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        recordTimer?.invalidate()
        recordTimer = nil
        captureQueue.async {
            self.pendingConfig = nil
            guard let rec = self.recording else {
                self.recordingFlag = false
                return
            }
            self.recording = nil
            if rec.sessionStarted {
                rec.vInput.markAsFinished()
                rec.aInput?.markAsFinished()
                rec.writer.finishWriting {
                    if rec.writer.status == .completed {
                        self.checkDuration(of: rec)
                        if rec.cfg.saveToFiles { self.saveVideoToFiles(at: rec.url) }
                        else { self.saveVideo(at: rec.url) }
                    } else {
                        self.flashMessage("Ошибка записи: \(rec.writer.error?.localizedDescription ?? "")")
                        try? FileManager.default.removeItem(at: rec.url)
                    }
                }
            } else {
                rec.writer.cancelWriting()
                try? FileManager.default.removeItem(at: rec.url)
            }
            self.recordingFlag = false
        }
        sessionQueue.async {
            self.videoOutput.alwaysDiscardsLateVideoFrames = true
            self.applyRotation()
        }
    }

    private func makeRecording(_ cfg: RecordConfig, pixelBuffer pb: CVPixelBuffer) -> Recording? {
        let w = CVPixelBufferGetWidth(pb)
        let h = CVPixelBufferGetHeight(pb)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cam-\(Int(Date().timeIntervalSince1970 * 1000)).mov")
        try? FileManager.default.removeItem(at: url)
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mov) else {
            flashMessage("Не удалось создать файл записи")
            return nil
        }
        let outFPS = cfg.mode == .video ? max(cfg.fps / max(cfg.decimate, 1), 1) : 30
        var bitrate = Double(w * h) * Double(outFPS) * cfg.quality.bpp * (cfg.codec == .h264 ? 1.6 : 1.0)
        bitrate = min(max(bitrate, 4_000_000), 400_000_000)

        var comp: [String: Any] = [
            AVVideoAverageBitRateKey: Int(bitrate),
            AVVideoExpectedSourceFrameRateKey: outFPS,
            AVVideoMaxKeyFrameIntervalKey: max(outFPS, 1)
        ]
        if cfg.codec == .h264 { comp[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel }

        let settings: [String: Any] = [
            AVVideoCodecKey: cfg.codec.avCodec,
            AVVideoWidthKey: w,
            AVVideoHeightKey: h,
            AVVideoCompressionPropertiesKey: comp,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
            ]
        ]
        let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        vIn.expectsMediaDataInRealTime = true
        guard writer.canAdd(vIn) else {
            flashMessage("Этот формат записи не поддерживается")
            return nil
        }
        writer.add(vIn)

        var aIn: AVAssetWriterInput?
        if cfg.mode == .video,
           let aSettings = audioOutput.recommendedAudioSettingsForAssetWriter(writingTo: .mov) as? [String: Any] {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: aSettings)
            input.expectsMediaDataInRealTime = true
            if writer.canAdd(input) { writer.add(input); aIn = input }
        }
        guard writer.startWriting() else {
            flashMessage("Ошибка запуска записи: \(writer.error?.localizedDescription ?? "")")
            return nil
        }
        return Recording(writer: writer, vInput: vIn, aInput: aIn, url: url, cfg: cfg)
    }

    // MARK: - Frame processing (captureQueue)

    private func handleVideo(_ sb: CMSampleBuffer) {
        guard let pb = CMSampleBufferGetImageBuffer(sb) else { return }

        if let cfg = pendingConfig, recording == nil {
            pendingConfig = nil
            recording = makeRecording(cfg, pixelBuffer: pb)
            if recording == nil {
                recordingFlag = false
                onMain { self.isRecording = false; self.recordTimer?.invalidate() }
            }
        }

        let state = currentRenderState()

        if state.detectFaces || state.detectHands || state.detectFingers || state.blurFaces || state.glitchQuad {
            let now = CFAbsoluteTimeGetCurrent()
            if now - lastVisionTime > 0.04, vision.isIdle(), let small = makeSmallBuffer(from: pb) {
                lastVisionTime = now
                vision.process(small,
                               faces: state.detectFaces || state.blurFaces,
                               hands: state.detectHands || state.detectFingers,
                               fingers: state.detectFingers,
                               quad: state.glitchQuad)
            }
        }
        let blurRects = state.blurFaces ? vision.faceRects() : []
        let glitch = state.glitchQuad ? vision.quad() : nil

        var outSB = sb
        var outPB = pb
        if state.look != .none || !blurRects.isEmpty || glitch != nil,
           let filtered = renderFiltered(pb, state, blurRects: blurRects, glitch: glitch) {
            var timing = CMSampleTimingInfo()
            CMSampleBufferGetSampleTimingInfo(sb, at: 0, timingInfoOut: &timing)
            if let made = makeSampleBuffer(pixelBuffer: filtered, timing: timing) {
                outSB = made
                outPB = filtered
            }
        }

        let size = CGSize(width: CVPixelBufferGetWidth(outPB), height: CVPixelBufferGetHeight(outPB))
        if size != lastVideoSize {
            lastVideoSize = size
            onMain { self.videoSize = size }
        }

        frameCounter &+= 1
        let stride = max(1, captureFPS / 60)
        if frameCounter % stride == 0 { enqueuePreview(outSB) }

        let now = CFAbsoluteTimeGetCurrent()
        if histogramVisible, now - lastHistogramTime > 0.25 {
            lastHistogramTime = now
            computeHistogram(outPB)
        }

        if let rec = recording { appendVideo(outSB, to: rec) }
    }

    private func enqueuePreview(_ sb: CMSampleBuffer) {
        guard let layer = displayLayer else { return }
        if let arr = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: true),
           CFArrayGetCount(arr) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(arr, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        if layer.status == .failed { layer.flush() }
        if layer.isReadyForMoreMediaData { layer.enqueue(sb) }
    }

    private func makeSmallBuffer(from pb: CVPixelBuffer) -> CVPixelBuffer? {
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        let scale = 640.0 / Double(max(w, h))
        let sw = max(Int(Double(w) * scale), 16), sh = max(Int(Double(h) * scale), 16)
        if smallPool == nil || smallPoolSize != (sw, sh) {
            let attrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: sw,
                kCVPixelBufferHeightKey as String: sh,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()
            ]
            var pool: CVPixelBufferPool?
            CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool)
            smallPool = pool
            smallPoolSize = (sw, sh)
        }
        guard let pool = smallPool else { return nil }
        var out: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out) == kCVReturnSuccess, let dst = out else { return nil }
        let img = CIImage(cvPixelBuffer: pb).transformed(by: CGAffineTransform(scaleX: CGFloat(scale), y: CGFloat(scale)))
        ciContext.render(img, to: dst)
        return dst
    }

    private func renderFiltered(_ pb: CVPixelBuffer, _ state: RenderState, blurRects: [CGRect], glitch: [CGPoint]?) -> CVPixelBuffer? {
        let w = CVPixelBufferGetWidth(pb)
        let h = CVPixelBufferGetHeight(pb)
        if pixelPool == nil || poolSize != (w, h) {
            let attrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                kCVPixelBufferWidthKey as String: w,
                kCVPixelBufferHeightKey as String: h,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
                kCVPixelBufferMetalCompatibilityKey as String: true
            ]
            var pool: CVPixelBufferPool?
            CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey as String: 4] as CFDictionary, attrs as CFDictionary, &pool)
            pixelPool = pool
            poolSize = (w, h)
        }
        guard let pool = pixelPool else { return nil }
        var out: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out) == kCVReturnSuccess, let dst = out else { return nil }

        let src = CIImage(cvPixelBuffer: pb)
        let base = blurRects.isEmpty ? src : FaceBlur.apply(src, faces: blurRects, strength: state.blurStrength)
        var result = videoRenderer.apply(look: state.look, lut: state.lut, intensity: state.intensity, to: base)
        if let q = glitch { result = GlitchQuad.apply(result, quad: q, seed: UInt64(frameCounter), strength: state.glitchStrength, effects: state.quadEffects) }
        ciContext.render(result, to: dst, bounds: src.extent, colorSpace: rec709)

        CVBufferSetAttachment(dst, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(dst, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(dst, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        return dst
    }

    private func makeSampleBuffer(pixelBuffer: CVPixelBuffer, timing: CMSampleTimingInfo) -> CMSampleBuffer? {
        var fd: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pixelBuffer, formatDescriptionOut: &fd)
        guard let fd else { return nil }
        var t = timing
        var sb: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, formatDescription: fd, sampleTiming: &t, sampleBufferOut: &sb)
        return sb
    }

    private func retime(_ sb: CMSampleBuffer, pts: CMTime, duration: CMTime) -> CMSampleBuffer? {
        var timing = CMSampleTimingInfo(duration: duration, presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var out: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: sb, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleBufferOut: &out)
        return out
    }

    private func appendVideo(_ sb: CMSampleBuffer, to rec: Recording) {
        guard rec.writer.status == .writing else { return }
        if rec.cfg.decimate > 1 {
            rec.rawIndex += 1
            if (rec.rawIndex - 1) % rec.cfg.decimate != 0 { return }
        }
        let pts = CMSampleBufferGetPresentationTimeStamp(sb)
        let retimed = rec.cfg.mode != .video

        if !rec.sessionStarted {
            rec.writer.startSession(atSourceTime: retimed ? .zero : pts)
            rec.startPTS = pts
            rec.sessionStarted = true
        }

        var toAppend: CMSampleBuffer? = sb
        switch rec.cfg.mode {
        case .video, .photo:
            break
        case .slomo:
            let rel = CMTimeSubtract(pts, rec.startPTS)
            let k = Double(max(rec.cfg.fps, 30)) / 30.0
            let dur = CMSampleBufferGetDuration(sb)
            toAppend = retime(sb, pts: CMTimeMultiplyByFloat64(rel, multiplier: k),
                              duration: dur.isValid ? CMTimeMultiplyByFloat64(dur, multiplier: k) : CMTime(value: 1, timescale: 30))
        case .timelapse:
            let rel = CMTimeGetSeconds(CMTimeSubtract(pts, rec.startPTS))
            if rec.frameCount > 0 && rel < rec.nextLapse { return }
            rec.nextLapse = rel + rec.cfg.interval
            toAppend = retime(sb, pts: CMTime(value: Int64(rec.frameCount), timescale: 30), duration: CMTime(value: 1, timescale: 30))
        }
        guard let buf = toAppend else { return }
        guard rec.vInput.isReadyForMoreMediaData else { rec.dropped += 1; return }
        if rec.vInput.append(buf) { rec.frameCount += 1 }
    }

    private func handleAudio(_ sb: CMSampleBuffer) {
        updateAudioLevels(sb)
        guard let rec = recording, rec.sessionStarted, rec.writer.status == .writing,
              let aIn = rec.aInput, aIn.isReadyForMoreMediaData else { return }
        if CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(sb), rec.startPTS) >= 0 {
            aIn.append(sb)
        }
    }

    private func updateAudioLevels(_ sb: CMSampleBuffer) {
        guard let fd = CMSampleBufferGetFormatDescription(sb),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd)?.pointee,
              let block = CMSampleBufferGetDataBuffer(sb) else { return }
        var length = 0
        var ptr: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &ptr) == kCMBlockBufferNoErr,
              let base = ptr else { return }
        let ch = max(Int(asbd.mChannelsPerFrame), 1)
        let bits = Int(asbd.mBitsPerChannel)
        let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        var peaks = [Float](repeating: 0, count: ch)

        if isFloat && bits == 32 {
            let n = length / 4
            base.withMemoryRebound(to: Float.self, capacity: n) { p in
                for i in 0..<n { let v = abs(p[i]); let c = i % ch; if v > peaks[c] { peaks[c] = v } }
            }
        } else if bits == 16 {
            let n = length / 2
            base.withMemoryRebound(to: Int16.self, capacity: n) { p in
                for i in 0..<n { let v = abs(Float(p[i])) / 32768; let c = i % ch; if v > peaks[c] { peaks[c] = v } }
            }
        } else { return }

        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastAudioPublish > 0.06 else { return }
        lastAudioPublish = now
        func db(_ v: Float) -> Float { v <= 0.0001 ? -60 : max(-60, 20 * log10(v)) }
        let l = db(peaks[0])
        let r = db(peaks.count > 1 ? peaks[1] : peaks[0])
        onMain {
            let prev = self.audioLevels
            self.audioLevels = [max(l, prev[0] - 4), max(r, prev[1] - 4)]
        }
    }

    private func computeHistogram(_ pb: CVPixelBuffer) {
        guard CVPixelBufferGetPlaneCount(pb) > 0 else { return }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(pb, 0) else { return }
        let w = CVPixelBufferGetWidthOfPlane(pb, 0)
        let h = CVPixelBufferGetHeightOfPlane(pb, 0)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
        var bins = [Float](repeating: 0, count: 64)
        let stepX = max(1, w / 120), stepY = max(1, h / 120)
        var y = 0
        while y < h {
            let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self)
            var x = 0
            while x < w {
                bins[Int(row[x]) >> 2] += 1
                x += stepX
            }
            y += stepY
        }
        let peak = max(bins.max() ?? 1, 1)
        let norm = bins.map { sqrt($0 / peak) }
        onMain { self.histogram = norm }
    }
}

// MARK: - Delegates

extension CameraEngine: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output === videoOutput { handleVideo(sampleBuffer) }
        else if output === audioOutput { handleAudio(sampleBuffer) }
    }
}

extension CameraEngine: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let error {
            flashMessage("Ошибка съёмки: \(error.localizedDescription)")
            return
        }
        guard let data = photo.fileDataRepresentation() else { return }
        if photo.isRawPhoto {
            saveToLibrary(photo: data, dng: true)
            return
        }
        let state = currentRenderState()
        if state.look != .none || state.blurFaces || state.glitchQuad,
           var ci = CIImage(data: data, options: [.applyOrientationProperty: true]) {
            if state.blurFaces { ci = FaceBlur.apply(ci, faces: VisionTracker.detectFaces(in: ci), strength: state.blurStrength) }
            var out = photoRenderer.apply(look: state.look, lut: state.lut, intensity: state.intensity, to: ci)
            if state.glitchQuad, let q = vision.quad() { out = GlitchQuad.apply(out, quad: q, seed: UInt64(Date().timeIntervalSince1970 * 1000), strength: state.glitchStrength, effects: state.quadEffects) }
            let cs = CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpaceCreateDeviceRGB()
            let key = CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)
            if let jpeg = ciContext.jpegRepresentation(of: out, colorSpace: cs, options: [key: 0.95]) {
                saveToLibrary(photo: jpeg, dng: false)
                return
            }
        }
        saveToLibrary(photo: data, dng: false)
    }
}
