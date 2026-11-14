import SwiftUI
import Combine

enum PromptMode: String, CaseIterable, Identifiable {
    case speech = "Speech"   // strict: follows what you say
    case song = "Song"       // loose: tolerant matching + keeps drifting forward while you sing
    case scroll = "Scroll"   // no microphone, constant pace

    var id: String { rawValue }

    var blurb: String {
        switch self {
        case .speech: "Follows your voice word by word."
        case .song: "Follows lyrics loosely and keeps moving while you play."
        case .scroll: "Scrolls at a steady pace. No microphone."
        }
    }
}

struct PromptWord {
    let text: String
    let norm: String
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
        didSet { UserDefaults.standard.set(script, forKey: "script"); rebuild() }
    }
    @Published var fontSize: Double {
        didSet { UserDefaults.standard.set(fontSize, forKey: "fontSize"); rebuild() }
    }
    @Published var mode: PromptMode {
        didSet {
            UserDefaults.standard.set(mode.rawValue, forKey: "promptMode")
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
    @Published var status = ""

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
            Task { @MainActor in self?.level = level }
        }
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
                newWords.append(PromptWord(text: token, norm: Self.normalize(token)))
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

    static func normalize(_ s: String) -> String {
        String(s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
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
        switch mode {
        case .scroll:
            advance(speed * dt)
        case .speech, .song:
            if level > 0.02 { lastVoice = now }
            // Dead-reckon between recogniser updates: while the voice is active, keep moving at the
            // learned pace, but never more than a few words past what has been confirmed.
            let voiceActive = now.timeIntervalSince(lastVoice) < 0.4
            let recent = now.timeIntervalSince(lastMatch) < 3
            let song = mode == .song
            let maxLead = max(3, Int((learnedPace * (song ? 2.5 : 1.2)).rounded()))
            if voiceActive, recent, currentIndex < confirmedIndex + maxLead {
                advance(learnedPace * dt)
            } else if song, voiceActive, !recent {
                // Recognition has dropped out entirely (sustained notes, ornamentation): keep drifting.
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
        let tail = transcript.suffix(5).map(Self.normalize).filter { !$0.isEmpty }
        guard !tail.isEmpty else { return }

        let song = mode == .song
        let lookAhead = song ? 90 : 30
        let base = confirmedIndex
        let lo = max(0, base - 4)
        let hi = min(words.count - 1, base + lookAhead)
        guard lo <= hi else { return }

        var best: (pos: Int, score: Int, dist: Int)?
        for p in lo...hi {
            var score = 0
            var t = tail.count - 1
            var w = p
            while t >= 0, w >= 0 {
                let target = words[w].norm
                if target.isEmpty { w -= 1; continue }
                if Self.fuzzyEqual(tail[t], target) { score += 1; t -= 1; w -= 1 } else { break }
            }
            guard score > 0 else { continue }
            let dist = abs(p + 1 - base)
            let near = song ? 10 : 4
            let needed = dist <= near ? 1 : 2
            guard score >= needed else { continue }
            if let b = best {
                if score > b.score || (score == b.score && dist < b.dist) { best = (p, score, dist) }
            } else {
                best = (p, score, dist)
            }
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
        } else if best.score >= 3, target < confirmedIndex - 2 {
            // Clear evidence the speaker went back (re-reading a line): follow them.
            confirmedIndex = target
            currentIndex = target
            fractional = 0
            paceSamples = []
        }
        if best.pos >= words.count - 1 { stop() }
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

    private static func fuzzyEqual(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        let (la, lb) = (a.count, b.count)
        if min(la, lb) >= 4, a.hasPrefix(b) || b.hasPrefix(a) { return true }
        if min(la, lb) >= 5, abs(la - lb) <= 1 { return editDistance(a, b) <= 1 }
        return false
    }

    private static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        var prev = Array(0...b.count)
        for i in 1...max(1, a.count) where a.count > 0 {
            var cur = [i] + Array(repeating: 0, count: b.count)
            for j in 1...max(1, b.count) where b.count > 0 {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            prev = cur
        }
        return prev[b.count]
    }
}
