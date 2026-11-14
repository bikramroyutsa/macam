import AVFoundation
import AppKit
import SwiftUI

final class CameraModel: NSObject, ObservableObject, AVCapturePhotoCaptureDelegate {
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
        guard timerSeconds > 0 else { capture(); return }
        countdownTask = Task { @MainActor in
            for n in stride(from: timerSeconds, through: 1, by: -1) {
                withAnimation(.snappy) { countdown = n }
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
            }
            withAnimation(.snappy) { countdown = nil }
            capture()
        }
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
