import AVFoundation
import AppKit
import SwiftUI

enum CaptureMode: String { case photo, video }

/// Video quality, defined by the short side of the frame so every aspect ratio gets the familiar
/// pixel height: 1080p is 1920×1080 at 16:9, 1440×1080 at 4:3, 1080×1080 at 1:1, 1080×1920 at 9:16.
/// Never upscales: if the camera can't deliver it, you get the camera's own size.
enum VideoResolution: String, CaseIterable, Identifiable {
    case p720, p1080, p2160, native

    var id: String { rawValue }
    var label: String {
        switch self {
        case .p720: "720p"
        case .p1080: "1080p"
        case .p2160: "4K"
        case .native: "Max"
        }
    }
    var detail: String {
        switch self {
        case .p720: "Small files"
        case .p1080: "Balanced"
        case .p2160: "Sharpest, large files"
        case .native: "Full camera resolution"
        }
    }
    var shortSide: CGFloat? {
        switch self {
        case .p720: 720
        case .p1080: 1080
        case .p2160: 2160
        case .native: nil
        }
    }
}

final class CameraModel: NSObject, ObservableObject, AVCapturePhotoCaptureDelegate,
                         AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private let sessionQueue = DispatchQueue(label: "macam.camera.session")
    private var configured = false

    @Published var authorization: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
    @Published var devices: [AVCaptureDevice] = []
    @Published var currentDeviceID: String?
    @Published var mirrored: Bool = UserDefaults.standard.object(forKey: "mirrored") as? Bool ?? true {
        didSet { UserDefaults.standard.set(mirrored, forKey: "mirrored") }
    }
    @Published var lastPhoto: NSImage?
    @Published var lastPhotoURL: URL?
    @Published var flash = false
    @Published var countdown: Int?
    @Published var timerSeconds: Int = 0
    @Published var mode: CaptureMode = CaptureMode(rawValue: UserDefaults.standard.string(forKey: "captureMode") ?? "") ?? .photo {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: "captureMode") }
    }
    @Published var resolution: VideoResolution = VideoResolution(rawValue: UserDefaults.standard.string(forKey: "videoResolution") ?? "") ?? .p1080 {
        didSet { UserDefaults.standard.set(resolution.rawValue, forKey: "videoResolution") }
    }
    @Published var isRecording = false
    @Published var elapsed: TimeInterval = 0

    // Recording pipeline (writer state is only touched on `writerQueue`).
    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private let writerQueue = DispatchQueue(label: "macam.camera.writer")
    private let ciContext = CIContext()
    private var audioInput: AVCaptureDeviceInput?
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioWriterInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var wantsRecording = false
    private var recordURL: URL?
    private var recordRatio: CGFloat = 16.0 / 9.0
    private var recordMirror = true
    private var recordResolution: VideoResolution = .p1080
    private var recordWithAudio = false
    private var outSize = CGSize(width: 1920, height: 1080)
    private var elapsedTimer: Timer?

    /// Set by the UI so the saved photo matches the framing on screen.
    var captureRatio: CGFloat = 16.0 / 9.0

    private var countdownTask: Task<Void, Never>?

    // MARK: Lifecycle

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            authorization = .authorized
            configureAndRun()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    self?.authorization = granted ? .authorized : .denied
                    if granted { self?.configureAndRun() }
                }
            }
        default:
            authorization = AVCaptureDevice.authorizationStatus(for: .video)
        }
    }

    private func configureAndRun() {
        refreshDevices()
        let preferred = UserDefaults.standard.string(forKey: "cameraID")
        let device = devices.first { $0.uniqueID == preferred } ?? AVCaptureDevice.default(for: .video) ?? devices.first
        guard let device else { return }
        select(device)
    }

    private func refreshDevices() {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video, position: .unspecified)
        devices = discovery.devices
    }

    func select(_ device: AVCaptureDevice) {
        currentDeviceID = device.uniqueID
        UserDefaults.standard.set(device.uniqueID, forKey: "cameraID")
        sessionQueue.async { [self] in
            session.beginConfiguration()
            session.sessionPreset = .photo
            session.inputs.forEach { session.removeInput($0) }
            if let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) {
                session.addInput(input)
            }
            if !configured, session.canAddOutput(photoOutput) {
                session.addOutput(photoOutput)
                configured = true
            }
            session.commitConfiguration()
            if !session.isRunning { session.startRunning() }
        }
    }

    // MARK: Capture

    func shutter() {
        if let countdown, countdown > 0 { // tap again cancels
            countdownTask?.cancel()
            self.countdown = nil
            return
        }
        if isRecording { stopRecording(); return }
        guard timerSeconds > 0 else { trigger(); return }
        countdownTask = Task { @MainActor in
            for n in stride(from: timerSeconds, through: 1, by: -1) {
                withAnimation(.snappy) { countdown = n }
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
            }
            withAnimation(.snappy) { countdown = nil }
            trigger()
        }
    }

    private func trigger() {
        if mode == .video { startRecording() } else { capture() }
    }

    private func capture() {
        guard session.isRunning else { return }
        let settings = AVCapturePhotoSettings()
        photoOutput.capturePhoto(with: settings, delegate: self)
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.05)) { self.flash = true }
            withAnimation(.easeOut(duration: 0.4).delay(0.06)) { self.flash = false }
            NSSound(named: "Tink")?.play()
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard error == nil, let data = photo.fileDataRepresentation() else { return }
        let ratio = captureRatio
        let mirror = mirrored
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let cg = Self.crop(data: data, ratio: ratio, mirror: mirror) else { return }
            let rep = NSBitmapImageRep(cgImage: cg)
            guard let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.95]) else { return }
            let dir = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0].appendingPathComponent("Macam")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let stamp = Self.stamp.string(from: Date())
            let url = dir.appendingPathComponent("Macam \(stamp).jpg")
            try? jpeg.write(to: url)
            let thumb = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            DispatchQueue.main.async {
                withAnimation(.spring(response: 0.45, dampingFraction: 0.7)) {
                    self?.lastPhoto = thumb
                    self?.lastPhotoURL = url
                }
            }
        }
    }

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return f
    }()

    /// Centre-crops to `ratio` (width / height) and optionally mirrors, at full sensor resolution.
    private static func crop(data: Data, ratio: CGFloat, mirror: Bool) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        var cw = w, ch = w / ratio
        if ch > h { ch = h; cw = h * ratio }
        let rect = CGRect(x: ((w - cw) / 2).rounded(), y: ((h - ch) / 2).rounded(),
                          width: cw.rounded(), height: ch.rounded())
        guard let cropped = cg.cropping(to: rect) else { return nil }
        guard mirror else { return cropped }
        guard let ctx = CGContext(data: nil, width: cropped.width, height: cropped.height,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return cropped }
        ctx.translateBy(x: CGFloat(cropped.width), y: 0)
        ctx.scaleBy(x: -1, y: 1)
        ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: cropped.width, height: cropped.height))
        return ctx.makeImage() ?? cropped
    }

    // MARK: Video

    private func startRecording() {
        guard session.isRunning, !isRecording else { return }
        recordRatio = captureRatio
        recordMirror = mirrored
        recordResolution = resolution
        Task { @MainActor in
            let micOK = await AVCaptureDevice.requestAccess(for: .audio)
            let url = Self.movieURL()
            self.sessionQueue.async { [self] in
                session.beginConfiguration()
                videoOutput.alwaysDiscardsLateVideoFrames = true
                videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
                videoOutput.setSampleBufferDelegate(self, queue: writerQueue)
                if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }
                var audio = false
                if micOK, let mic = AVCaptureDevice.default(for: .audio),
                   let input = try? AVCaptureDeviceInput(device: mic), session.canAddInput(input) {
                    session.addInput(input)
                    audioInput = input
                    audioOutput.setSampleBufferDelegate(self, queue: writerQueue)
                    if session.canAddOutput(audioOutput) { session.addOutput(audioOutput); audio = true }
                }
                session.commitConfiguration()
                writerQueue.async { [self] in
                    recordURL = url
                    recordWithAudio = audio
                    writer = nil
                    wantsRecording = true
                }
            }
            withAnimation(.snappy) { self.isRecording = true }
            self.elapsed = 0
            let started = Date()
            self.elapsedTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                self?.elapsed = Date().timeIntervalSince(started)
            }
        }
    }

    func stopRecording() {
        guard isRecording else { return }
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        withAnimation(.snappy) { isRecording = false }
        writerQueue.async { [self] in
            wantsRecording = false
            guard let writer, let url = recordURL else { cleanupOutputs(); return }
            self.writer = nil
            videoInput?.markAsFinished()
            audioWriterInput?.markAsFinished()
            writer.finishWriting { [weak self] in
                self?.cleanupOutputs()
                Task { @MainActor in await self?.showMovieThumbnail(url) }
            }
        }
    }

    private func cleanupOutputs() {
        sessionQueue.async { [self] in
            session.beginConfiguration()
            videoOutput.setSampleBufferDelegate(nil, queue: nil)
            audioOutput.setSampleBufferDelegate(nil, queue: nil)
            session.removeOutput(videoOutput)
            session.removeOutput(audioOutput)
            if let audioInput { session.removeInput(audioInput); self.audioInput = nil }
            session.commitConfiguration()
        }
    }

    @MainActor
    private func showMovieThumbnail(_ url: URL) async {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 400, height: 400)
        if let result = try? await generator.image(at: .zero) {
            let image = NSImage(cgImage: result.image, size: NSSize(width: result.image.width, height: result.image.height))
            withAnimation(.spring(response: 0.45, dampingFraction: 0.7)) {
                lastPhoto = image
                lastPhotoURL = url
            }
        } else {
            lastPhotoURL = url
        }
    }

    private static func movieURL() -> URL {
        let dir = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0].appendingPathComponent("Macam")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("Macam \(stamp.string(from: Date())).mov")
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard wantsRecording else { return }
        if output === videoOutput {
            appendVideo(sampleBuffer)
        } else if output === audioOutput {
            if let input = audioWriterInput, writer?.status == .writing, input.isReadyForMoreMediaData {
                input.append(sampleBuffer)
            }
        }
    }

    private func appendVideo(_ sample: CMSampleBuffer) {
        guard let pixels = CMSampleBufferGetImageBuffer(sample) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)

        if writer == nil {
            guard let url = recordURL else { return }
            let srcW = CGFloat(CVPixelBufferGetWidth(pixels)), srcH = CGFloat(CVPixelBufferGetHeight(pixels))
            // Fit the crop, then scale so the short side matches the chosen resolution (even dimensions for the encoder).
            var cw = srcW, ch = srcW / recordRatio
            if ch > srcH { ch = srcH; cw = srcH * recordRatio }
            let scale = recordResolution.shortSide.map { min(1, $0 / min(cw, ch)) } ?? 1
            let ow = max(2, Int((cw * scale) / 2) * 2), oh = max(2, Int((ch * scale) / 2) * 2)
            outSize = CGSize(width: ow, height: oh)

            guard let w = try? AVAssetWriter(outputURL: url, fileType: .mov) else { return }
            let v = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: min(ow, oh) > 1080 ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
                AVVideoWidthKey: ow, AVVideoHeightKey: oh,
                AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: max(6_000_000, ow * oh * 5)],
            ])
            v.expectsMediaDataInRealTime = true
            let a = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: v, sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: ow, kCVPixelBufferHeightKey as String: oh,
            ])
            if w.canAdd(v) { w.add(v) }
            if recordWithAudio {
                let ain = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC, AVNumberOfChannelsKey: 1,
                    AVSampleRateKey: 44100, AVEncoderBitRateKey: 128_000,
                ])
                ain.expectsMediaDataInRealTime = true
                if w.canAdd(ain) { w.add(ain); audioWriterInput = ain }
            }
            guard w.startWriting() else { return }
            w.startSession(atSourceTime: pts)
            writer = w; videoInput = v; adaptor = a
        }

        guard let input = videoInput, let adaptor, input.isReadyForMoreMediaData,
              let pool = adaptor.pixelBufferPool else { return }
        var out: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out)
        guard let out else { return }

        var image = CIImage(cvPixelBuffer: pixels)
        let ext = image.extent
        var cw = ext.width, ch = ext.width / recordRatio
        if ch > ext.height { ch = ext.height; cw = ext.height * recordRatio }
        let crop = CGRect(x: ext.midX - cw / 2, y: ext.midY - ch / 2, width: cw, height: ch).integral
        image = image.cropped(to: crop)
            .transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
            .transformed(by: CGAffineTransform(scaleX: outSize.width / crop.width, y: outSize.height / crop.height))
        if recordMirror {
            image = image.transformed(by: CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: outSize.width, ty: 0))
        }
        ciContext.render(image, to: out)
        adaptor.append(out, withPresentationTime: pts)
    }

    func revealLastPhoto() {
        guard let url = lastPhotoURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

// MARK: - Preview

struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession
    let mirrored: Bool
    let deviceID: String?

    func makeNSView(context: Context) -> PreviewNSView {
        let view = PreviewNSView()
        view.previewLayer.session = session
        return view
    }

    func updateNSView(_ view: PreviewNSView, context: Context) {
        view.applyMirroring(mirrored)
        // The connection appears slightly after the input is added; apply again shortly.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { view.applyMirroring(mirrored) }
    }
}

final class PreviewNSView: NSView {
    let previewLayer = AVCaptureVideoPreviewLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = CALayer()
        previewLayer.videoGravity = .resizeAspectFill
        layer?.addSublayer(previewLayer)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        previewLayer.frame = bounds
        CATransaction.commit()
    }

    func applyMirroring(_ mirrored: Bool) {
        guard let connection = previewLayer.connection, connection.isVideoMirroringSupported else { return }
        connection.automaticallyAdjustsVideoMirroring = false
        connection.isVideoMirrored = mirrored
    }
}
