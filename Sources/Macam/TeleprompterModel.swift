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
    private var cancellables = Set<AnyCancellable>()

    static let panelWidth: CGFloat = 520
    static let visibleLines = 3
    static let controlsHeight: CGFloat = 40

    var lineHeight: CGFloat { CGFloat(fontSize) * 1.5 }

    var pillSize: CGSize {
        CGSize(width: Self.panelWidth,
               height: notch.height + 8 + lineHeight * CGFloat(Self.visibleLines) + Self.controlsHeight + 6)
    }

    var currentLine: Int {
        guard !lineOfWord.isEmpty else { return 0 }
        return lineOfWord[min(currentIndex, lineOfWord.count - 1)]
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

    private func rebuild() {
        let contentWidth = Double(Self.panelWidth) - 56
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
        fractional = 0
    }

    func jump(toLine line: Int) {
        guard line >= 0, line < lines.count, let first = lines[line].first else { return }
        currentIndex = first
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
        switch mode {
        case .scroll:
            advance(speed * dt)
        case .song:
            // Lyrics are sung, held and ornamented; recognition drops out a lot.
            // While there's sound but no recent word match, keep drifting forward.
            if level > 0.04, Date().timeIntervalSince(lastMatch) > 2.5 { advance(speed * dt) }
        case .speech:
            break
        }
    }

    private func advance(_ amount: Double) {
        fractional += amount
        let whole = Int(fractional)
        guard whole > 0 else { return }
        fractional -= Double(whole)
        let next = currentIndex + whole
        if next >= words.count { currentIndex = max(0, words.count - 1); stop() } else { currentIndex = next }
    }

    // MARK: Following the voice

    private func handleTranscript(_ transcript: [String]) {
        guard isRunning, !words.isEmpty else { return }
        let tail = transcript.suffix(5).map(Self.normalize).filter { !$0.isEmpty }
        guard !tail.isEmpty else { return }

        let song = mode == .song
        let lookAhead = song ? 90 : 30
        let lo = max(0, currentIndex - 4)
        let hi = min(words.count - 1, currentIndex + lookAhead)
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
            let dist = abs(p + 1 - currentIndex)
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
        if target > currentIndex || best.score >= 3 {
            currentIndex = target
            fractional = 0
        }
        lastMatch = Date()
        if best.pos >= words.count - 1 { stop() }
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
