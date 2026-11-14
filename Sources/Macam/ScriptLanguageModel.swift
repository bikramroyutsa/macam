import CryptoKit
import Foundation
import Speech

/// Builds an on-device custom language model from the script, so the recogniser is strongly biased
/// towards the exact words and phrases you are about to read instead of guessing from everyday speech.
enum ScriptLanguageModel {
    enum BuildError: Error { case emptyScript }

    static func prepare(script: String, locale: Locale) async throws -> SFSpeechLanguageModel.Configuration {
        let phrases = phrases(from: script)
        guard !phrases.isEmpty else { throw BuildError.emptyScript }

        let hash = digest(script + "|" + locale.identifier)
        let fm = FileManager.default
        let dir = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("Macam", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("lm-\(hash).bin")

        let data = SFCustomLanguageModelData(locale: locale, identifier: "com.macam.script", version: hash)
        for phrase in phrases {
            data.insert(phraseCount: SFCustomLanguageModelData.PhraseCount(phrase: phrase, count: 100))
        }
        try await data.export(to: url)

        let config = SFSpeechLanguageModel.Configuration(languageModel: url)
        try await SFSpeechLanguageModel.prepareCustomLanguageModel(for: url, configuration: config)

        // Drop models built for earlier versions of the script.
        if let old = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            for f in old where f.lastPathComponent.hasPrefix("lm-") && f != url { try? fm.removeItem(at: f) }
        }
        return config
    }

    /// Whole sentences/lines, plus overlapping windows of long ones so partial reads are covered too.
    static func phrases(from script: String) -> [String] {
        let separators = CharacterSet(charactersIn: "\n.!?;:")
        var seen = Set<String>()
        var out: [String] = []
        func add(_ words: [String]) {
            guard !words.isEmpty else { return }
            let phrase = words.joined(separator: " ")
            if seen.insert(phrase).inserted { out.append(phrase) }
        }
        for chunk in script.components(separatedBy: separators) {
            let words = chunk.split(whereSeparator: \.isWhitespace).compactMap { clean(String($0)) }.flatMap { $0 }
            guard !words.isEmpty else { continue }
            if words.count <= 10 {
                add(words)
            } else {
                var i = 0
                while i < words.count {
                    add(Array(words[i..<min(words.count, i + 8)]))
                    if i + 8 >= words.count { break }
                    i += 4
                }
            }
        }
        return out
    }

    /// Lower-case letters and apostrophes only; digits are spelled out ("2" -> "two").
    private static func clean(_ token: String) -> [String]? {
        let lower = token.lowercased()
        if let n = Int(lower.filter(\.isNumber)), lower.allSatisfy(\.isNumber) {
            let spelled = NumberFormatter.localizedString(from: NSNumber(value: n), number: .spellOut)
            let parts = spelled.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
            return parts.isEmpty ? nil : parts
        }
        let word = String(lower.filter { $0.isLetter || $0 == "'" || $0 == "\u{2019}" }).replacingOccurrences(of: "\u{2019}", with: "'")
        return word.isEmpty ? nil : [word]
    }

    private static func digest(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}
