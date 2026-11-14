import Foundation

/// Sound-alike comparison for matching what the recogniser heard against the script.
/// Recognisers often return a word that sounds right but is spelled differently ("night" / "knight"),
/// so equality on spelling alone throws away good evidence.
enum Phonetics {
    /// Words that carry little positional information; matching one is weak evidence.
    static let stopWords: Set<String> = [
        "the", "a", "an", "and", "or", "but", "to", "of", "in", "on", "at", "for", "with", "is", "it",
        "i", "you", "he", "she", "we", "they", "that", "this", "so", "be", "as", "my", "me", "your", "are", "was",
    ]

    private static let replacements: [(String, String)] = [
        ("ough", "o"), ("augh", "af"), ("igh", "i"), ("tch", "ch"), ("sch", "sk"), ("dge", "j"),
        ("ph", "f"), ("ck", "k"), ("wr", "r"), ("kn", "n"), ("gn", "n"), ("wh", "w"), ("qu", "kw"),
        ("x", "ks"), ("q", "k"), ("z", "s"),
    ]

    /// A rough phonetic key: spelling variants of the same sound collapse to the same string.
    static func key(_ word: String) -> String {
        var s = word
        for (a, b) in replacements { s = s.replacingOccurrences(of: a, with: b) }
        // Hard/soft c.
        var out = ""
        let chars = Array(s)
        for (i, ch) in chars.enumerated() {
            if ch == "c" {
                let next = i + 1 < chars.count ? chars[i + 1] : " "
                out.append("eiy".contains(next) ? "s" : "k")
            } else {
                out.append(ch)
            }
        }
        // Drop a silent trailing e, collapse vowel runs and doubled letters.
        if out.count > 3, out.hasSuffix("e") { out.removeLast() }
        var result = ""
        for ch in out {
            let isVowel = "aeiouy".contains(ch)
            if let last = result.last {
                if isVowel, "aeiouy".contains(last) { continue }
                if ch == last { continue }
            }
            result.append(isVowel ? "a" : ch)
        }
        return result
    }

    static func distance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        for i in 1...a.count {
            var cur = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            prev = cur
        }
        return prev[b.count]
    }

    /// How well a heard word matches a script word. About 1 is a confident match, negative is a mismatch.
    /// `last` marks the final heard word, which is often only partly spoken ("chan" on its way to "channel").
    static func similarity(heard h: String, heardKey hk: String, script s: String, scriptKey sk: String, last: Bool) -> Double {
        let weight = stopWords.contains(s) ? 0.45 : 1.0
        if h == s { return weight }
        if last, h.count >= 2, s.count > h.count, s.hasPrefix(h) { return 0.7 * weight }
        let shortest = min(h.count, s.count)
        if shortest >= 4, distance(h, s) <= (shortest >= 8 ? 2 : 1) { return 0.85 * weight }
        if shortest >= 3, hk == sk { return 0.75 * weight }
        if min(hk.count, sk.count) >= 3, distance(hk, sk) <= 1 { return 0.5 * weight }
        return -0.6
    }
}
