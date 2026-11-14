import AVFoundation
import Speech

/// Streams microphone audio into on-device speech recognition and reports the recognised words
/// plus a smoothed input level. Recognition tasks time out, so it restarts itself transparently.
final class SpeechTracker {
    private let engine = AVAudioEngine()
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var running = false
    private var smoothedLevel: Float = 0

    // Shared with the recognition callbacks, guarded by `lock`.
    private let lock = NSLock()
    private var contextStrings: [String] = []
    private var languageModel: SFSpeechLanguageModel.Configuration?
    private var generation = 0
    private var quickFailures = 0

    var onWords: (@Sendable ([String]) -> Void)?
    var onLevel: (@Sendable (Float) -> Void)?
    var onNotice: (@Sendable (String) -> Void)?
    var onFatal: (@Sendable (String) -> Void)?

    enum TrackerError: LocalizedError {
        case unavailable
        var errorDescription: String? { "Speech recognition isn't available right now." }
    }

    /// Words the recogniser should favour (the upcoming script).
    func setContext(_ words: [String]) {
        lock.lock(); contextStrings = words; lock.unlock()
    }

    /// A custom language model built from the script. Applies from the next recognition task.
    func setLanguageModel(_ config: SFSpeechLanguageModel.Configuration?) {
        lock.lock(); languageModel = config; lock.unlock()
    }

    /// Starts a fresh recognition task now (e.g. when a new language model becomes ready).
    func restartTask() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.running else { return }
            self.task?.cancel()
            self.beginTask()
        }
    }

    static func requestAuthorization() async -> Bool {
        let speech = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) }
        }
        guard speech else { return false }
        return await AVCaptureDevice.requestAccess(for: .audio)
    }

    func start() throws {
        guard !running else { return }
        let recognizer = SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer()
        guard let recognizer, recognizer.isAvailable else { throw TrackerError.unavailable }
        self.recognizer = recognizer
        lock.lock(); quickFailures = 0; lock.unlock()

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            self.request?.append(buffer)
            self.measure(buffer)
        }
        engine.prepare()
        try engine.start()
        running = true
        beginTask()
    }

    func stop() {
        guard running else { return }
        running = false
        lock.lock(); generation += 1; lock.unlock()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        smoothedLevel = 0
        onLevel?(0)
    }

    private func beginTask() {
        guard running, let recognizer else { return }
        lock.lock()
        generation += 1
        let gen = generation
        let context = contextStrings
        let model = languageModel
        lock.unlock()

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.taskHint = .dictation
        req.addsPunctuation = false
        req.contextualStrings = context
        if recognizer.supportsOnDeviceRecognition {
            req.requiresOnDeviceRecognition = true
            if let model { req.customizedLanguageModel = model }
        }
        request = req
        let started = Date()

        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            guard let self else { return }
            self.lock.lock(); let current = (gen == self.generation); self.lock.unlock()
            guard current else { return }   // a newer task has replaced this one

            if let result {
                self.lock.lock(); self.quickFailures = 0; self.lock.unlock()
                self.onWords?(result.bestTranscription.segments.map(\.substring))
            }
            guard error != nil || result?.isFinal == true else { return }

            // A task that dies almost immediately is a configuration problem, not a pause in speech.
            if error != nil, Date().timeIntervalSince(started) < 1.5 {
                self.lock.lock(); self.quickFailures += 1; let failures = self.quickFailures; self.lock.unlock()
                if failures >= 3 {
                    if model != nil {
                        self.setLanguageModel(nil)
                        self.lock.lock(); self.quickFailures = 0; self.lock.unlock()
                        self.onNotice?("Script vocabulary unavailable. Using standard recognition.")
                    } else {
                        DispatchQueue.main.async { [weak self] in
                            self?.stop()
                            self?.onFatal?("Speech recognition keeps failing. Check Speech Recognition access.")
                        }
                        return
                    }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                guard let self, self.running else { return }
                self.lock.lock(); let stillCurrent = (gen == self.generation); self.lock.unlock()
                guard stillCurrent else { return }
                self.task?.cancel()
                self.beginTask()
            }
        }
    }

    private func measure(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData?[0] else { return }
        let n = Int(buffer.frameLength)
        guard n > 0 else { return }
        var sum: Float = 0
        for i in 0..<n { sum += data[i] * data[i] }
        let rms = sqrt(sum / Float(n))
        let level = min(1, rms * 10)
        smoothedLevel = smoothedLevel * 0.7 + level * 0.3
        onLevel?(smoothedLevel)
    }
}
