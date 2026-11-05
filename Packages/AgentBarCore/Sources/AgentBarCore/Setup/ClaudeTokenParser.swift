import Foundation

/// Pure helpers for pulling the OAuth token out of the terminal output of `claude setup-token`.
/// Nothing here logs or stores anything; callers keep the result in memory only.
public enum ClaudeTokenParser {
    public static let prefix = "sk-ant-oat01-"
    public static let maxTokenLength = 512
    static let minBody = 20

    static func isTokenChar(_ b: UInt8) -> Bool {
        (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A) || b == 0x2D || b == 0x5F
    }

    /// Removes CSI / OSC / other escape sequences and control characters. `\r\n`, lone `\r` and `\n` all become `\n`.
    public static func stripANSI(_ input: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []; out.reserveCapacity(input.count)
        var i = 0; let n = input.count
        while i < n {
            let b = input[i]
            if b == 0x1B {
                i += 1
                guard i < n else { break }
                let k = input[i]
                if k == 0x5B {            // CSI: params 0x30-0x3F, intermediates 0x20-0x2F, final 0x40-0x7E
                    i += 1
                    while i < n, !(input[i] >= 0x40 && input[i] <= 0x7E) { i += 1 }
                    i += 1
                } else if k == 0x5D || k == 0x50 || k == 0x5E || k == 0x5F {   // OSC / DCS / PM / APC: until BEL or ESC \
                    i += 1
                    while i < n {
                        if input[i] == 0x07 { i += 1; break }
                        if input[i] == 0x1B, i + 1 < n, input[i + 1] == 0x5C { i += 2; break }
                        i += 1
                    }
                } else {                  // two-byte escape (optionally with intermediates)
                    while i < n, input[i] >= 0x20 && input[i] <= 0x2F { i += 1 }
                    i += 1
                }
                continue
            }
            if b == 0x0D { if i + 1 < n, input[i + 1] == 0x0A { i += 1 }; out.append(0x0A); i += 1; continue }
            if b == 0x0A || b == 0x09 || b >= 0x20 { out.append(b) }   // drops other C0 controls and DEL below
            i += 1
        }
        return out.filter { $0 != 0x7F }
    }

    /// Finds the token in raw terminal output (ANSI allowed). Matches line by line. With `wrapWidth` (the terminal width we
    /// set) a token hard-wrapped at exactly that width is re-joined; without it lines are never joined (the PTY is set to
    /// >= 1000 columns, so wrapping should not happen; joining without a known width would swallow following words).
    /// - Parameter isFinal: false while output is still streaming: a token that touches the end of the data (no newline
    ///   after it, or a possibly continued wrapped line) is not accepted yet. true at EOF/exit.
    public static func extract(from raw: [UInt8], isFinal: Bool = false, wrapWidth: Int? = nil) -> String? {
        let clean = stripANSI(raw)
        var lines = clean.split(separator: 0x0A, omittingEmptySubsequences: false).map { Array($0) }
        let terminated = clean.last == 0x0A
        if terminated { lines.removeLast() }                      // empty element after the final newline
        else if !isFinal, !lines.isEmpty { lines.removeLast() }   // incomplete last line
        let pre = Array(prefix.utf8)
        for (idx, line) in lines.enumerated() {
            guard let start = find(pre, in: line) else { continue }
            var tokenBytes: [UInt8] = []
            var j = start
            while j < line.count, isTokenChar(line[j]) { tokenBytes.append(line[j]); j += 1 }
            if let width = wrapWidth, j == line.count, line.count == width {
                // The token fills the whole terminal line: it may continue on the next line (hard wrap at `width`).
                var cur = idx
                var needMore = false
                while lines[cur].count == width, tokenBytes.count < maxTokenLength {
                    guard cur + 1 < lines.count else { needMore = true; break }
                    let next = lines[cur + 1]
                    guard !next.isEmpty, next.allSatisfy(isTokenChar) else { break }
                    tokenBytes += next; cur += 1
                }
                if needMore, !isFinal { continue }   // cannot tell yet whether more follows
            }
            guard tokenBytes.count >= pre.count + minBody, tokenBytes.count <= maxTokenLength else { continue }
            return String(decoding: tokenBytes, as: UTF8.self)
        }
        return nil
    }

    public static func extract(from text: String, isFinal: Bool = false, wrapWidth: Int? = nil) -> String? {
        extract(from: Array(text.utf8), isFinal: isFinal, wrapWidth: wrapWidth)
    }

    /// Strict check for a pasted token (whole string, surrounding whitespace allowed).
    public static func normalizedManualToken(_ input: String) -> String? {
        let t = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let b = Array(t.utf8)
        guard b.count >= prefix.utf8.count + minBody, b.count <= maxTokenLength, b.starts(with: Array(prefix.utf8)),
              b.allSatisfy(isTokenChar) else { return nil }
        return t
    }

    private static func find(_ needle: [UInt8], in hay: [UInt8]) -> Int? {
        guard hay.count >= needle.count else { return nil }
        for i in 0...(hay.count - needle.count) where hay[i] == needle[0] && Array(hay[i..<(i + needle.count)]) == needle { return i }
        return nil
    }
}
