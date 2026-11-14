import Combine
import Speech
import SwiftUI

enum PromptMode: String, CaseIterable, Identifiable {
    case speech = "Speech"   // strict: follows what you say
    case song = "Song"       // loose: tolerant matching + keeps drifting forward while you sing
    case scroll = "Scroll"   // no microphone, constant pace

    var id: String { rawValue }

    var blurb: String {
        switch self {
        case .speech: "Follows your voice word by word."
        case .song: "Follows the words you sing, loosely. Holds still when you stop."
        case .scroll: "Scrolls at a steady pace. No microphone."
        }
    }
}

struct PromptWord {
    let text: String
    let norm: String
    let key: String      // phonetic key of `norm`
}

@MainActor
final class TeleprompterModel: ObservableObject {
    static let sample = """
    Welcome back to the channel.
    Today I want to show you something small,
    but something I use every single day.

    Just look at the camera,
    breathe,
    and let the words come to you.
    """

    // Script & layout
    @Published var script: String {
        didSet { UserDefaults.standard.set(script, forKey: "script"); rebuild(); prepareVocabulary() }
    }
    @Published var fontSize: Double {
        didSet { UserDefaults.standard.set(fontSize, forKey: "fontSize"); rebuild() }
    }
    @Published var mode: PromptMode {
        didSet {
            UserDefaults.standard.set(mode.rawValue, forKey: "promptMode")
            if mode != .scroll, oldValue == .scroll { prepareVocabulary() }
            if isRunning { restart() }
        }
    }
    @Published var speed: Double {
        didSet { UserDefaults.standard.set(speed, forKey: "speed") }
    }

    // Playback
    @Published private(set) var words: [PromptWord] = []
    @Published private(set) var lines: [[Int]] = []     // word indices per display line
    @Published private(set) var lineOfWord: [Int] = []
    @Published var currentIndex = 0
    @Published var isRunning = false
    @Published var level: Float = 0
    @Published var voiceAmount: Double = 0   // 0 silent … 1 loud, smoothed (fast attack, slow release)
    @Published var isSpeaking = false  // voice present right now (with a short hold so it doesn't flicker)
    @Published var status = ""
    @Published var heard = ""          // what the recogniser last heard (diagnostics)
    @Published var vocabStatus = ""    // state of the script-specific language model

    // Presentation
    @Published var showScript = false      // script editor panel in the main window
    @Published var isPresented = false     // user intent
    @Published var expanded = false        // visual state, animated
    var notch = NotchGeometry.current()

    private let tracker = SpeechTracker()
    private var notchController: NotchController?
    private var tickTask: Task<Void, Never>?
    private var lastMatch = Date.distantPast
    private var fractional = 0.0

    // Pace tracking: the recogniser reports words ~0.5s late, so we learn how fast the
    // speaker moves and run slightly ahead of it, then snap back to what it confirms.
    private var confirmedIndex = 0
    private var learnedPace = 2.5                        // words per second
    private var paceSamples: [(t: Date, idx: Int)] = []
    private var lastVoice = Date.distantPast
    private var vocabTask: Task<Void, Never>?
    private var lastLoud = Date.distantPast
    private var cancellables = Set<AnyCancellable>()

    static let controlsHeight: CGFloat = 40
    static let minWidth: CGFloat = 360
    static let maxLines = 8

    /// Width of the notch teleprompter, and how many lines it shows. Both are user-resizable.
    @Published var panelWidth: CGFloat {
        didSet { UserDefaults.standard.set(Double(panelWidth), forKey: "panelWidth"); rebuild() }
    }
    @Published var visibleLines: Int {
        didSet { UserDefaults.standard.set(visibleLines, forKey: "visibleLines") }
    }

    var lineHeight: CGFloat { CGFloat(fontSize) * 1.5 }

    var pillSize: CGSize {
        CGSize(width: panelWidth,
               height: notch.height + 2 + lineHeight * CGFloat(visibleLines) + Self.controlsHeight + 6)
    }

    /// The line the view scrolls to. It leads the highlighted word by about half a second of
    /// speech, so the next line is already in place before you reach the end of this one.
    var currentLine: Int {
        guard !lineOfWord.isEmpty else { return 0 }
        let lead = visibleLines >= 3 && mode != .scroll ? min(4, Int((learnedPace * 0.6).rounded()) + 1) : 0
        return lineOfWord[min(currentIndex + lead, lineOfWord.count - 1)]
    }

    var progress: Double {
        words.isEmpty ? 0 : Double(currentIndex) / Double(words.count)
    }

    init() {
        let d = UserDefaults.standard
        script = d.string(forKey: "script") ?? Self.sample
        let fs = d.double(forKey: "fontSize")
        fontSize = fs == 0 ? 28 : fs
        mode = PromptMode(rawValue: d.string(forKey: "promptMode") ?? "") ?? .speech
        let sp = d.double(forKey: "speed")
        speed = sp == 0 ? 2.5 : sp
        let pw = d.double(forKey: "panelWidth")
        panelWidth = pw == 0 ? 520 : CGFloat(pw)
        let vl = d.integer(forKey: "visibleLines")
        visibleLines = vl == 0 ? 3 : min(max(vl, 1), Self.maxLines)
        rebuild()

        tracker.onWords = { [weak self] words in
            Task { @MainActor in self?.handleTranscript(words) }
        }
        tracker.onLevel = { [weak self] level in
            Task { @MainActor in self?.handleLevel(level) }
        }
        tracker.onNotice = { [weak self] text in
            Task { @MainActor in self?.vocabStatus = text }
        }
        tracker.onFatal = { [weak self] text in
            Task { @MainActor in self?.stop(); self?.status = text }
        }
        prepareVocabulary()
    }

    func installNotch() {
        guard notchController == nil else { return }
        notchController = NotchController(model: self)
    }

    // MARK: Layout

    var maxPanelWidth: CGFloat { min(1100, (notch.screen?.frame.width ?? 1400) - 40) }

    func resetSize() {
        panelWidth = 520
        visibleLines = 3
    }

    enum ResizeAxis { case width, height }

    /// Resizes from the live mouse position: the pill is centred under the notch and hangs from the top edge.
    func resize(_ axis: ResizeAxis) {
        guard let frame = notch.screen?.frame else { return }
        let m = NSEvent.mouseLocation
        switch axis {
        case .width:
            panelWidth = min(max(2 * abs(m.x - frame.midX), Self.minWidth), maxPanelWidth)
        case .height:
            let room = frame.maxY - m.y - notch.height - 8 - Self.controlsHeight - 6
            visibleLines = min(max(Int((room / lineHeight).rounded()), 1), Self.maxLines)
        }
    }

    private func rebuild() {
        let contentWidth = Double(panelWidth) - 56
        let maxChars = max(12, Int(contentWidth / (fontSize * 0.5)))

        var newWords: [PromptWord] = []
        var newLines: [[Int]] = []
        var lineMap: [Int] = []

        for paragraph in script.components(separatedBy: "\n") {
            let tokens = paragraph.split(whereSeparator: \.isWhitespace).map(String.init)
            if tokens.isEmpty {
                if !newLines.isEmpty { newLines.append([]) }
                continue
            }
            var current: [Int] = []
            var count = 0
            for token in tokens {
                if count > 0, count + 1 + token.count > maxChars {
                    newLines.append(current); current = []; count = 0
                }
                let norm = Self.normalize(token)
                newWords.append(PromptWord(text: token, norm: norm, key: Phonetics.key(norm)))
                lineMap.append(newLines.count)
                current.append(newWords.count - 1)
                count += token.count + (count > 0 ? 1 : 0)
            }
            if !current.isEmpty { newLines.append(current) }
        }
        words = newWords
        lines = newLines
        lineOfWord = lineMap
        currentIndex = min(currentIndex, max(0, newWords.count - 1))
    }

    /// Lower-case letters and digits only. A bare number is spelled out so "2" and "two" compare equal.
    static func normalize(_ s: String) -> String {
        let lower = s.lowercased()
        if !lower.isEmpty, lower.allSatisfy(\.isNumber), let n = Int(lower) {
            let spelled = NumberFormatter.localizedString(from: NSNumber(value: n), number: .spellOut)
            return String(spelled.lowercased().filter(\.isLetter))
        }
        return String(lower.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    // MARK: Playback

    func toggleRunning() {
        if isRunning { stop() } else { Task { await start() } }
    }

    func start() async {
        guard !isRunning, !words.isEmpty else { return }
        status = ""
        if !isPresented { isPresented = true }
        if currentIndex >= words.count - 1 { currentIndex = 0 }
        confirmedIndex = currentIndex
        tracker.setContext(contextWords())   // before the recogniser starts, so the first task has it
        if mode != .scroll {
            guard await SpeechTracker.requestAuthorization() else {
                status = "Allow Microphone and Speech Recognition in System Settings."
                return
            }
            do { try tracker.start() } catch {
                status = error.localizedDescription
                return
            }
        }
        lastMatch = Date()
        fractional = 0
        confirmedIndex = currentIndex
        learnedPace = speed
        paceSamples = []
        lastVoice = .distantPast
        tracker.setContext(contextWords())
        isRunning = true
        startTicker()
    }

    func stop() {
        tracker.stop()
        tickTask?.cancel()
        tickTask = nil
        isRunning = false
        level = 0
        isSpeaking = false
        voiceAmount = 0
    }

    /// Speaking switches on at a clear level and off only after ~0.4s below it, so brief gaps
    /// between words don't make the indicator flicker.
    private func handleLevel(_ newLevel: Float) {
        level = newLevel
        if newLevel > 0.04 {
            lastLoud = Date()
            if !isSpeaking { isSpeaking = true }
        }
    }

    private func restart() {
        stop()
        Task { await start() }
    }

    func reset() {
        currentIndex = 0
        confirmedIndex = 0
        fractional = 0
        paceSamples = []
    }

    func jump(toLine line: Int) {
        guard line >= 0, line < lines.count, let first = lines[line].first else { return }
        currentIndex = first
        confirmedIndex = first
        paceSamples = []
    }

    private func startTicker() {
        tickTask?.cancel()
        tickTask = Task { @MainActor [weak self] in
            let dt = 0.05
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                self?.tick(dt)
            }
        }
    }

    private func tick(_ dt: Double) {
        guard isRunning else { return }
        let now = Date()
        if isSpeaking, now.timeIntervalSince(lastLoud) > 0.4 { isSpeaking = false }
        // Ease the indicator: quick to rise with your voice, slow to settle when you stop.
        let target = isSpeaking ? min(1, 0.3 + Double(level) * 2.0) : 0
        voiceAmount += (target - voiceAmount) * (target > voiceAmount ? 0.45 : 0.14)
        if abs(voiceAmount - target) < 0.003 { voiceAmount = target }
        switch mode {
        case .scroll:
            advance(speed * dt)
        case .speech, .song:
            if level > 0.02 { lastVoice = now }
            // Dead-reckon between recogniser updates, but only just past the last word it actually
            // heard. Nothing moves on its own: no recognised words, no progress. (A guitar alone
            // makes sound too, so loudness is never treated as "you are singing".)
            let song = mode == .song
            let voiceActive = now.timeIntervalSince(lastVoice) < 0.4
            let recent = now.timeIntervalSince(lastMatch) < (song ? 1.2 : 3)
            let maxLead = song ? max(2, Int(learnedPace.rounded())) : max(2, Int((learnedPace * 0.7).rounded()))
            if voiceActive, recent, currentIndex < confirmedIndex + maxLead {
                advance(learnedPace * dt)
            }
        }
    }

    private func advance(_ amount: Double) {
        fractional += amount
        let whole = Int(fractional)
        guard whole > 0 else { return }
        fractional -= Double(whole)
        let next = currentIndex + whole
        if next >= words.count { currentIndex = max(0, words.count - 1); stop() } else { currentIndex = next }
        if mode == .scroll { confirmedIndex = currentIndex }
    }

    // MARK: Following the voice

    private func handleTranscript(_ transcript: [String]) {
        guard isRunning, !words.isEmpty else { return }
        heard = transcript.suffix(8).joined(separator: " ")

        let heardWords = transcript.suffix(6).map(Self.normalize).filter { !$0.isEmpty }
        guard !heardWords.isEmpty else { return }
        let tail = heardWords.map { (w: $0, k: Phonetics.key($0)) }

        let song = mode == .song
        let lookAhead = song ? 90 : 30
        let near = song ? 14 : 4
        let base = confirmedIndex
        let lo = max(0, base - 4)
        let hi = min(words.count - 1, base + lookAhead)
        guard lo <= hi else { return }

        // Score every plausible "last word heard" position; nearer positions need less evidence.
        var best: (pos: Int, score: Double, rank: Double)?
        for p in lo...hi {
            let dist = abs(p + 1 - base)
            let score = alignmentScore(tail: tail, endingAt: p)
            let needed = dist <= 2 ? 0.4 : (dist <= near ? 0.75 : 1.7)
            guard score >= needed else { continue }
            let rank = score - 0.03 * Double(dist)
            if best == nil || rank > best!.rank { best = (p, score, rank) }
        }

        guard let best else { return }
        let target = min(best.pos + 1, words.count - 1)
        let now = Date()
        lastMatch = now

        if target > confirmedIndex {
            confirmedIndex = target
            recordPace(index: target, at: now)
            // Never pull the display backwards for a forward match: we may be running ahead on purpose.
            if target > currentIndex { currentIndex = target; fractional = 0 }
            if confirmedIndex % 12 == 0 { tracker.setContext(contextWords()) }
        } else if best.score >= 2.5, target < confirmedIndex - 2 {
            // Clear evidence the speaker went back (re-reading a line): follow them.
            confirmedIndex = target
            currentIndex = target
            fractional = 0
            paceSamples = []
        }
        if best.pos >= words.count - 1 { stop() }
    }

    /// Aligns the recently heard words against the script words ending at `p`, tolerating words the
    /// recogniser got wrong (substitutions), dropped or invented. The start of both sides is free,
    /// so only the quality of the overlap counts, and the last heard word anchors the end.
    private func alignmentScore(tail: [(w: String, k: String)], endingAt p: Int) -> Double {
        let n = tail.count
        let m = min(p + 1, n + 2)
        let first = p - m + 1
        let gap = 0.45

        var prev = [Double](repeating: 0, count: m + 1)
        for i in 1...n {
            var cur = [Double](repeating: 0, count: m + 1)
            for j in 1...m {
                let sw = words[first + j - 1]
                if sw.norm.isEmpty {                  // punctuation-only token: skip it for free
                    cur[j] = max(cur[j - 1], prev[j - 1])
                    continue
                }
                let sim = Phonetics.similarity(heard: tail[i - 1].w, heardKey: tail[i - 1].k,
                                               script: sw.norm, scriptKey: sw.key, last: i == n)
                cur[j] = max(prev[j - 1] + sim, prev[j] - gap, cur[j - 1] - gap)
            }
            prev = cur
        }
        return prev[m]
    }

    // MARK: Vocabulary

    /// Builds a language model from the script so recognition favours the words you are about to read.
    /// Debounced, and applied to the recogniser as soon as it is ready.
    private func prepareVocabulary() {
        vocabTask?.cancel()
        guard mode != .scroll else { return }
        let text = script
        vocabTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(1200))
            guard let self, !Task.isCancelled else { return }
            self.vocabStatus = "Learning your script…"
            let locale = SFSpeechRecognizer(locale: Locale.current)?.locale ?? SFSpeechRecognizer()?.locale ?? Locale(identifier: "en_US")
            do {
                let config = try await ScriptLanguageModel.prepare(script: text, locale: locale)
                guard !Task.isCancelled else { return }
                self.tracker.setLanguageModel(config)
                self.vocabStatus = "Script vocabulary ready"
                if self.isRunning { self.tracker.restartTask() }
            } catch {
                guard !Task.isCancelled else { return }
                self.tracker.setLanguageModel(nil)
                self.vocabStatus = ""
            }
        }
    }

    /// Words per second over the last few seconds of confirmed progress.
    private func recordPace(index: Int, at time: Date) {
        paceSamples.append((time, index))
        paceSamples.removeAll { time.timeIntervalSince($0.t) > 6 }
        guard let first = paceSamples.first, let last = paceSamples.last else { return }
        let span = last.t.timeIntervalSince(first.t)
        guard span >= 1.0, last.idx > first.idx else { return }
        let measured = Double(last.idx - first.idx) / span
        let clamped = min(7, max(0.8, measured))
        learnedPace = learnedPace * 0.5 + clamped * 0.5
    }

    /// Distinct upcoming words, handed to the recogniser so it prefers them over similar-sounding ones.
    private func contextWords() -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for w in words[min(confirmedIndex, words.count)...] where !w.norm.isEmpty {
            if seen.insert(w.norm).inserted { out.append(w.norm) }
            if out.count >= 100 { break }
        }
        return out
    }
}
