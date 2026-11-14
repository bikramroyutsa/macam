import AVFoundation
import AppKit
import Combine
import UniformTypeIdentifiers

enum ExportSize: String, CaseIterable, Identifiable {
    case original, p1080, p720
    var id: String { rawValue }
    var label: String {
        switch self {
        case .original: "Original size"
        case .p1080: "1080p"
        case .p720: "720p"
        }
    }
    /// Short side in pixels; nil keeps the source size. Never upscales.
    var shortSide: CGFloat? {
        switch self {
        case .original: nil
        case .p1080: 1080
        case .p720: 720
        }
    }
}

/// One part of the source video. Parts always cover the whole source end to end; splitting adds a cut,
/// deleting marks a part as removed (it can be restored), and each part has its own speed.
struct EditSegment: Identifiable, Equatable {
    let id: UUID
    var start: Double
    var end: Double
    var speed: Double
    var deleted: Bool

    init(start: Double, end: Double, speed: Double = 1, deleted: Bool = false) {
        self.id = UUID()
        self.start = start; self.end = end; self.speed = speed; self.deleted = deleted
    }
}

/// A stretch of the source that makes it into the result.
struct EditPiece {
    let start: Double
    let end: Double
    let speed: Double
    let outStart: Double
    var outDuration: Double { (end - start) / speed }
    var outEnd: Double { outStart + outDuration }
}

/// Everything undo has to restore.
struct EditState: Equatable {
    var segments: [EditSegment]
    var trimStart: Double
    var trimEnd: Double
    var muted: Bool
    var rotation: Int
    var flipped: Bool
    var fadeIn: Bool
    var fadeOut: Bool
}

/// Non-destructive edits on one video: trim, split, delete and speed per part, rotate/flip, mute and fades.
/// The preview player plays exactly the composition that gets exported, so what you see is what you save.
@MainActor
final class VideoEditor: ObservableObject {
    static let speeds: [Double] = [0.25, 0.5, 1, 1.5, 2, 4]
    static let minLength = 0.3

    let url: URL
    let asset: AVURLAsset
    let player = AVPlayer()

    // Edits
    @Published var trimStart: Double = 0 { didSet { editsChanged() } }
    @Published var trimEnd: Double = 0 { didSet { editsChanged() } }
    @Published var segments: [EditSegment] = [] { didSet { editsChanged() } }
    @Published var muted = false { didSet { editsChanged() } }
    @Published var rotation = 0 { didSet { editsChanged() } }       // clockwise degrees: 0, 90, 180, 270
    @Published var flipped = false { didSet { editsChanged() } }
    @Published var fadeIn = false { didSet { editsChanged() } }
    @Published var fadeOut = false { didSet { editsChanged() } }
    @Published var exportSize: ExportSize = .original
    @Published var exportFormat: ExportFormat = .video(.movH264)

    // State
    @Published private(set) var duration: Double = 0
    @Published private(set) var hasAudio = false
    @Published private(set) var isLoading = true
    @Published private(set) var loadError: String?
    @Published private(set) var frames: [NSImage] = []
    @Published private(set) var isPlaying = false
    @Published private(set) var displayRatio: CGFloat = 16.0 / 9.0
    @Published var playhead: Double = 0                 // in source seconds
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    @Published var scrubImage: NSImage?                 // shown while a trim handle is dragged

    // Export
    @Published private(set) var isExporting = false
    @Published private(set) var exportProgress: Double = 0
    @Published private(set) var savedURL: URL?
    @Published var exportError: String?
    @Published private(set) var toast: String?

    private var toastTask: Task<Void, Never>?
    func showToast(_ text: String) {
        toast = text
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.2))
            if !Task.isCancelled { self?.toast = nil }
        }
    }

    var onSaved: ((URL) -> Void)?

    /// The format that matches the source file, so saving without changing anything is a plain copy.
    var sourceFormat: ExportFormat { url.pathExtension.lowercased() == "mp4" ? .video(.mp4H264) : .video(.movH264) }

    /// Something to save: edits, or a different format or size (that is conversion).
    var canSave: Bool { hasEdits || exportFormat != sourceFormat || exportSize != .original }

    var saveTitle: String {
        switch exportFormat {
        case .audio: return "Export Audio"
        case .gif: return "Make GIF"
        case .video: return hasEdits ? "Save Copy" : "Convert"
        }
    }

    enum ExportError: LocalizedError {
        case noAudio
        var errorDescription: String? { "This video has no audio to export." }
    }

    private var naturalSize = CGSize(width: 1920, height: 1080)
    private var preferredTransform = CGAffineTransform.identity
    private var fps: Float = 30
    private var timeObserver: Any?
    private var rebuildTask: Task<Void, Never>?
    private var scrubTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()
    private var ready = false

    private var initialState: EditState?
    private var undoStack: [EditState] = []
    private var redoStack: [EditState] = []
    private var editInProgress = false

    var name: String { url.deletingPathExtension().lastPathComponent }
    var hasEdits: Bool {
        guard let initialState else { return false }
        return state != initialState
    }

    init(url: URL) {
        self.url = url
        self.asset = AVURLAsset(url: url)
        self.exportFormat = url.pathExtension.lowercased() == "mp4" ? .video(.mp4H264) : .video(.movH264)
        player.actionAtItemEnd = .pause
        NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)
            .sink { [weak self] _ in Task { @MainActor in self?.isPlaying = false } }
            .store(in: &cancellables)
        Task { await load() }
    }

    func close() {
        player.pause()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        rebuildTask?.cancel()
        scrubTask?.cancel()
        player.replaceCurrentItem(with: nil)
    }

    // MARK: Loading

    private func load() async {
        do {
            let d = try await asset.load(.duration).seconds
            guard let video = try await asset.loadTracks(withMediaType: .video).first else {
                loadError = "This file has no video."
                isLoading = false
                return
            }
            let (size, transform, rate) = try await video.load(.naturalSize, .preferredTransform, .nominalFrameRate)
            naturalSize = size
            preferredTransform = transform
            fps = rate > 0 ? rate : 30
            hasAudio = !(try await asset.loadTracks(withMediaType: .audio)).isEmpty

            duration = d
            ready = false                      // don't rebuild for the initial trim values
            trimStart = 0
            trimEnd = d
            segments = [EditSegment(start: 0, end: d)]
            initialState = state
            ready = true
            updateDisplayRatio()

            await rebuildNow()
            isLoading = false
            installTimeObserver()
            await loadFilmstrip()
        } catch {
            loadError = "Couldn't open this video."
            isLoading = false
        }
    }

    private func loadFilmstrip() async {
        guard duration > 0 else { return }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 320, height: 320)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
        let count = 16
        let times = (0..<count).map { CMTime(seconds: duration * (Double($0) + 0.5) / Double(count), preferredTimescale: 600) }
        var collected: [(Double, NSImage)] = []
        for await result in generator.images(for: times) {
            if case let .success(requested, image, _) = result {
                collected.append((requested.seconds, NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))))
            }
        }
        frames = collected.sorted { $0.0 < $1.0 }.map(\.1)
    }

    private func installTimeObserver() {
        guard timeObserver == nil else { return }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1.0 / 30, preferredTimescale: 600), queue: .main) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self, self.isPlaying else { return }
                self.playhead = self.sourceTime(forOutput: max(0, t.seconds))
            }
        }
    }

    // MARK: Edits

    private func editsChanged() {
        guard ready else { return }
        updateDisplayRatio()
        if isPlaying { player.pause(); isPlaying = false }
        playhead = min(max(playhead, 0), duration)
        scheduleRebuild()
    }

    private func updateDisplayRatio() {
        let oriented = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
        var w = abs(oriented.width), h = abs(oriented.height)
        if rotation % 180 != 0 { swap(&w, &h) }
        if w > 0, h > 0 { displayRatio = w / h }
    }

    // MARK: Undo

    var state: EditState {
        EditState(segments: segments, trimStart: trimStart, trimEnd: trimEnd, muted: muted,
                  rotation: rotation, flipped: flipped, fadeIn: fadeIn, fadeOut: fadeOut)
    }

    private func apply(_ s: EditState) {
        let wasReady = ready
        ready = false
        segments = s.segments; trimStart = s.trimStart; trimEnd = s.trimEnd; muted = s.muted
        rotation = s.rotation; flipped = s.flipped; fadeIn = s.fadeIn; fadeOut = s.fadeOut
        ready = wasReady
        editsChanged()
    }

    private func syncUndo() {
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
    }

    /// Remembers the current state so the next change can be undone.
    func checkpoint() {
        undoStack.append(state)
        if undoStack.count > 100 { undoStack.removeFirst() }
        redoStack.removeAll()
        syncUndo()
    }

    /// For drags: one undo step for the whole gesture.
    func beginEdit() {
        guard !editInProgress else { return }
        editInProgress = true
        checkpoint()
    }

    func endEdit() { editInProgress = false }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(state)
        apply(previous)
        syncUndo()
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(state)
        apply(next)
        syncUndo()
    }

    // MARK: Simple edits

    func rotate(by degrees: Int) { checkpoint(); rotation = ((rotation + degrees) % 360 + 360) % 360 }
    func toggleFlip() { checkpoint(); flipped.toggle() }
    func toggleMute() { checkpoint(); muted.toggle() }
    func toggleFadeIn() { checkpoint(); fadeIn.toggle() }
    func toggleFadeOut() { checkpoint(); fadeOut.toggle() }

    func reset() {
        checkpoint()
        trimStart = 0; trimEnd = duration
        segments = [EditSegment(start: 0, end: duration)]
        muted = false; rotation = 0; flipped = false; fadeIn = false; fadeOut = false
    }

    // MARK: Parts: split, delete, speed

    static let minPart = 0.15

    /// The part under the playhead. At a cut it is the part that starts there.
    var currentIndex: Int {
        segments.lastIndex(where: { $0.start <= playhead + 0.0001 }) ?? 0
    }
    var currentSpeed: Double { segments.indices.contains(currentIndex) ? segments[currentIndex].speed : 1 }
    var currentIsDeleted: Bool { segments.indices.contains(currentIndex) ? segments[currentIndex].deleted : false }

    var canSplit: Bool {
        guard segments.indices.contains(currentIndex) else { return false }
        let s = segments[currentIndex]
        return playhead - s.start > Self.minPart && s.end - playhead > Self.minPart
    }

    /// Restoring is always possible; deleting needs some other part to remain.
    var canDeleteCurrent: Bool {
        guard segments.indices.contains(currentIndex) else { return false }
        if segments[currentIndex].deleted { return true }
        let i = currentIndex
        return segments.enumerated().contains { j, s in
            j != i && !s.deleted && min(s.end, trimEnd) - max(s.start, trimStart) > 0.02
        }
    }

    /// Cuts the part under the playhead in two.
    func split() {
        guard canSplit else { return }
        checkpoint()
        let i = currentIndex
        let s = segments[i]
        let t = playhead
        segments[i].end = t
        segments.insert(EditSegment(start: t, end: s.end, speed: s.speed, deleted: s.deleted), at: i + 1)
    }

    /// Removes the part under the playhead from the result, or brings it back if it was removed.
    func toggleDeleteCurrent() {
        guard canDeleteCurrent else { return }
        checkpoint()
        segments[currentIndex].deleted.toggle()
    }

    /// Sets the speed of the part under the playhead, or of every part.
    func setSpeed(_ speed: Double, applyToAll: Bool = false) {
        checkpoint()
        if applyToAll {
            for i in segments.indices { segments[i].speed = speed }
        } else if segments.indices.contains(currentIndex) {
            segments[currentIndex].speed = speed
        }
    }

    /// Moves the cut between part `index - 1` and part `index`. Wrap drags in beginEdit/endEdit.
    func moveBoundary(_ index: Int, to time: Double) {
        guard index >= 1, index < segments.count else { return }
        let lo = segments[index - 1].start + Self.minPart
        let hi = segments[index].end - Self.minPart
        guard lo < hi else { return }
        let t = min(max(time, lo), hi)
        segments[index - 1].end = t
        segments[index].start = t
    }

    /// Removes a cut, joining the two parts around it.
    func joinBoundary(_ index: Int) {
        guard index >= 1, index < segments.count else { return }
        checkpoint()
        var merged = segments[index - 1]
        merged.end = segments[index].end
        merged.deleted = segments[index - 1].deleted && segments[index].deleted
        segments.replaceSubrange((index - 1)...index, with: [merged])
    }

    // MARK: Source / result time

    /// The stretches of the source that make it into the result, in order.
    var pieces: [EditPiece] {
        var out: [EditPiece] = []
        var t = 0.0
        for s in segments where !s.deleted {
            let a = max(s.start, trimStart), b = min(s.end, trimEnd)
            guard b - a > 0.02 else { continue }
            out.append(EditPiece(start: a, end: b, speed: s.speed, outStart: t))
            t += (b - a) / s.speed
        }
        return out
    }

    /// Length of the result.
    var outputDuration: Double { pieces.last?.outEnd ?? 0 }

    /// Where a source time lands in the result. Removed stretches map to the next kept moment.
    func outputTime(forSource t: Double) -> Double {
        for p in pieces {
            if t < p.start { return p.outStart }
            if t <= p.end { return p.outStart + (t - p.start) / p.speed }
        }
        return outputDuration
    }

    func sourceTime(forOutput u: Double) -> Double {
        let list = pieces
        for p in list where u < p.outEnd { return p.start + max(0, u - p.outStart) * p.speed }
        return list.last?.end ?? duration
    }

    func isKept(_ t: Double) -> Bool { pieces.contains { t >= $0.start && t <= $0.end } }

    private func scheduleRebuild() {
        rebuildTask?.cancel()
        rebuildTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(220))
            guard !Task.isCancelled, let self else { return }
            await self.rebuildNow()
        }
    }

    private func rebuildNow() async {
        guard let built = try? await build(targetShortSide: nil) else { return }
        let item = AVPlayerItem(asset: built.composition)
        item.videoComposition = built.videoComposition
        item.audioMix = built.audioMix
        item.audioTimePitchAlgorithm = .spectral          // keep voices natural in slow-mo / fast-forward
        player.replaceCurrentItem(with: item)
        installTimeObserver()
        let compTime = max(0, min(outputTime(forSource: playhead), built.composition.duration.seconds))
        await player.seek(to: CMTime(seconds: compTime, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        if isKept(playhead) { scrubImage = nil } else { previewFrame(atSource: playhead) }
    }

    // MARK: Playback

    func togglePlay() {
        if isPlaying {
            player.pause()
            isPlaying = false
            return
        }
        if let item = player.currentItem, item.duration.isNumeric,
           player.currentTime() >= item.duration - CMTime(seconds: 0.05, preferredTimescale: 600) {
            player.seek(to: .zero)
        }
        player.play()
        isPlaying = true
    }

    /// Moves the playhead to a time on the source timeline. In a removed stretch the player shows that
    /// frame as a still, so you can see what you are about to restore.
    func seek(toSource time: Double) {
        let t = min(max(time, 0), duration)
        playhead = t
        player.seek(to: CMTime(seconds: outputTime(forSource: t), preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        if isKept(t) { scrubTask?.cancel(); scrubImage = nil } else { previewFrame(atSource: t) }
    }

    /// While a trim handle is dragged, show the frame under it (the player is rebuilt on release).
    func previewFrame(atSource time: Double) {
        scrubTask?.cancel()
        scrubTask = Task { [weak self] in
            guard let self else { return }
            let generator = AVAssetImageGenerator(asset: self.asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 1280, height: 1280)
            generator.requestedTimeToleranceBefore = CMTime(seconds: 0.15, preferredTimescale: 600)
            generator.requestedTimeToleranceAfter = CMTime(seconds: 0.15, preferredTimescale: 600)
            if let result = try? await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)), !Task.isCancelled {
                self.scrubImage = NSImage(cgImage: result.image, size: NSSize(width: result.image.width, height: result.image.height))
            }
        }
    }

    // MARK: Composition

    struct Built {
        let composition: AVMutableComposition
        let videoComposition: AVMutableVideoComposition
        let audioMix: AVAudioMix?
    }

    /// Builds what the edits describe. `targetShortSide` scales the output for export (never upscales).
    private func build(targetShortSide: CGFloat?) async throws -> Built {
        guard let sourceVideo = try await asset.loadTracks(withMediaType: .video).first else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let sourceAudio = try await asset.loadTracks(withMediaType: .audio).first

        let kept = pieces
        guard !kept.isEmpty else { throw CocoaError(.fileReadCorruptFile) }

        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw CocoaError(.fileWriteUnknown)
        }
        var audioTrack: AVMutableCompositionTrack?
        if !muted, sourceAudio != nil {
            audioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        }

        // Lay the kept pieces end to end; each is slowed or sped up on its own.
        var cursor = CMTime.zero
        for piece in kept {
            let range = CMTimeRange(start: CMTime(seconds: piece.start, preferredTimescale: 600),
                                    end: CMTime(seconds: piece.end, preferredTimescale: 600))
            try videoTrack.insertTimeRange(range, of: sourceVideo, at: cursor)
            if let audioTrack, let sourceAudio { try? audioTrack.insertTimeRange(range, of: sourceAudio, at: cursor) }
            var length = range.duration
            if piece.speed != 1 {
                let scaled = CMTimeMultiplyByFloat64(range.duration, multiplier: 1 / piece.speed)
                composition.scaleTimeRange(CMTimeRange(start: cursor, duration: range.duration), toDuration: scaled)
                length = scaled
            }
            cursor = cursor + length
        }
        let total = composition.duration

        // Geometry: source orientation, then flip, then rotation, then optional downscale.
        let oriented = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
        let w = abs(oriented.width), h = abs(oriented.height)
        var transform = preferredTransform.concatenating(CGAffineTransform(translationX: -oriented.minX, y: -oriented.minY))
        if flipped { transform = transform.concatenating(CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: w, ty: 0)) }
        var outW = w, outH = h
        switch rotation {
        case 90:
            transform = transform.concatenating(CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: h, ty: 0)); outW = h; outH = w
        case 180:
            transform = transform.concatenating(CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: w, ty: h))
        case 270:
            transform = transform.concatenating(CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: w)); outW = h; outH = w
        default: break
        }
        if let target = targetShortSide {
            let scale = min(1, target / min(outW, outH))
            if scale < 1 {
                transform = transform.concatenating(CGAffineTransform(scaleX: scale, y: scale))
                outW *= scale; outH *= scale
            }
        }
        let evenW = max(2, (outW / 2).rounded() * 2), evenH = max(2, (outH / 2).rounded() * 2)

        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)
        layer.setTransform(transform, at: .zero)

        let fade = min(0.6, total.seconds / 3)
        let fadeTime = CMTime(seconds: fade, preferredTimescale: 600)
        if fadeIn {
            layer.setOpacityRamp(fromStartOpacity: 0, toEndOpacity: 1, timeRange: CMTimeRange(start: .zero, duration: fadeTime))
        }
        if fadeOut {
            layer.setOpacityRamp(fromStartOpacity: 1, toEndOpacity: 0,
                                 timeRange: CMTimeRange(start: total - fadeTime, duration: fadeTime))
        }

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: total)
        instruction.layerInstructions = [layer]

        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = CGSize(width: evenW, height: evenH)
        videoComposition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(24, min(60, Int(fps.rounded())))))
        videoComposition.instructions = [instruction]

        var audioMix: AVAudioMix?
        if let audioTrack, fadeIn || fadeOut {
            let params = AVMutableAudioMixInputParameters(track: audioTrack)
            if fadeIn {
                params.setVolumeRamp(fromStartVolume: 0, toEndVolume: 1, timeRange: CMTimeRange(start: .zero, duration: fadeTime))
            }
            if fadeOut {
                params.setVolumeRamp(fromStartVolume: 1, toEndVolume: 0, timeRange: CMTimeRange(start: total - fadeTime, duration: fadeTime))
            }
            let mix = AVMutableAudioMix()
            mix.inputParameters = [params]
            audioMix = mix
        }
        return Built(composition: composition, videoComposition: videoComposition, audioMix: audioMix)
    }

    // MARK: Export

    private func uniqueOutputURL(ext: String) -> URL {
        let dir = url.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent
        var candidate = dir.appendingPathComponent("\(base) edited.\(ext)")
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent("\(base) edited \(n).\(ext)")
            n += 1
        }
        return candidate
    }

    /// Saves the result as a new file next to the original, in the chosen format; the original is never touched.
    func exportCopy() async {
        guard !isExporting, ready else { return }
        player.pause(); isPlaying = false
        isExporting = true
        exportProgress = 0
        exportError = nil
        savedURL = nil
        defer { isExporting = false }

        do {
            let format = exportFormat
            let built = try await build(targetShortSide: format.isVideo ? exportSize.shortSide : nil)
            let output = uniqueOutputURL(ext: format.fileExtension)
            switch format {
            case .video(let f):
                try await runExport(built, preset: f.exportPreset, type: f.fileType, to: output, withVideo: true)
            case .audio:
                guard hasAudio, !muted else { throw ExportError.noAudio }
                try await runExport(built, preset: AVAssetExportPresetAppleM4A, type: .m4a, to: output, withVideo: false)
            case .gif:
                try await writeGIF(built, to: output)
            }
            exportProgress = 1
            savedURL = output
            if format.isVideo { onSaved?(output) }
        } catch {
            let message = "Couldn't save: \(error.localizedDescription)"
            exportError = message
            showToast(message)
        }
    }

    private func runExport(_ built: Built, preset: String, type: AVFileType, to output: URL, withVideo: Bool) async throws {
        guard let session = AVAssetExportSession(asset: built.composition, presetName: preset) else {
            throw CocoaError(.fileWriteUnknown)
        }
        session.outputURL = output
        session.outputFileType = type
        if withVideo { session.videoComposition = built.videoComposition }
        session.audioMix = built.audioMix
        session.audioTimePitchAlgorithm = .spectral

        let progress = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.exportProgress = Double(session.progress)
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            session.exportAsynchronously { c.resume() }
        }
        progress.cancel()

        guard session.status == .completed else {
            try? FileManager.default.removeItem(at: output)
            throw session.error ?? CocoaError(.fileWriteUnknown)
        }
    }

    /// An endlessly looping GIF, at most 480px on the long side and about 12 frames a second.
    private func writeGIF(_ built: Built, to output: URL) async throws {
        let total = built.composition.duration.seconds
        let fps = min(12.0, max(4.0, 300 / max(total, 0.1)))      // keeps long clips to ~300 frames
        let count = max(1, Int((total * fps).rounded(.down)))

        let generator = AVAssetImageGenerator(asset: built.composition)
        generator.videoComposition = built.videoComposition
        generator.maximumSize = CGSize(width: 480, height: 480)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.03, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.03, preferredTimescale: 600)

        guard let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.gif.identifier as CFString, count, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationSetProperties(destination, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0],
        ] as CFDictionary)
        let frameProperties = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1 / fps]] as CFDictionary

        for i in 0..<count {
            let time = CMTime(seconds: Double(i) / fps, preferredTimescale: 600)
            let result = try await generator.image(at: time)
            CGImageDestinationAddImage(destination, result.image, frameProperties)
            exportProgress = Double(i + 1) / Double(count) * 0.95
        }
        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: output)
            throw CocoaError(.fileWriteUnknown)
        }
    }

    /// Saves the frame under the playhead (with all edits applied) as a JPEG photo.
    func saveFrame() async -> URL? {
        guard let built = try? await build(targetShortSide: nil) else { return nil }
        let generator = AVAssetImageGenerator(asset: built.composition)
        generator.videoComposition = built.videoComposition
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let compTime = min(max(0, player.currentTime().seconds), max(0, built.composition.duration.seconds - 0.01))
        guard let result = try? await generator.image(at: CMTime(seconds: compTime, preferredTimescale: 600)) else { return nil }
        let rep = NSBitmapImageRep(cgImage: result.image)
        guard let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.95]) else { return nil }
        let dir = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0].appendingPathComponent("Macam")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let out = dir.appendingPathComponent("Macam frame \(fmt.string(from: Date())).jpg")
        do { try jpeg.write(to: out) } catch { return nil }
        showToast("Frame saved to Pictures")
        return out
    }
}
