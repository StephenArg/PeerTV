import Foundation

/// One subtitle cue from a WebVTT file.
struct VTTCue: Hashable {
    let start: TimeInterval
    let end: TimeInterval
    let text: String
}

/// Minimal WebVTT → cue list for in-app rendering (PeerTube serves `.vtt`).
enum WebVTTParser {

    private static let inlineTagRegex = try! NSRegularExpression(
        pattern: #"<[^>]+>"#,
        options: []
    )

    static func parse(_ source: String) -> [VTTCue] {
        var text = source
        if text.hasPrefix("\u{FEFF}") {
            text.removeFirst()
        }
        let rawLines = text.components(separatedBy: .newlines)
        var i = 0

        // Skip leading empties
        while i < rawLines.count, rawLines[i].trimmingCharacters(in: .whitespaces).isEmpty { i += 1 }
        guard i < rawLines.count else { return [] }

        // WEBVTT header
        if rawLines[i].trimmingCharacters(in: .whitespaces).hasPrefix("WEBVTT") {
            i += 1
            // Optional header block until blank line
            while i < rawLines.count {
                let t = rawLines[i].trimmingCharacters(in: .whitespaces)
                if t.isEmpty { i += 1; break }
                i += 1
            }
        }

        var cues: [VTTCue] = []

        while i < rawLines.count {
            while i < rawLines.count, rawLines[i].trimmingCharacters(in: .whitespaces).isEmpty { i += 1 }
            guard i < rawLines.count else { break }

            let line = rawLines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.uppercased().hasPrefix("NOTE") {
                i += 1
                while i < rawLines.count, !rawLines[i].trimmingCharacters(in: .whitespaces).isEmpty { i += 1 }
                continue
            }
            if trimmed == "STYLE" {
                i += 1
                while i < rawLines.count, !rawLines[i].trimmingCharacters(in: .whitespaces).isEmpty { i += 1 }
                continue
            }
            if trimmed.uppercased().hasPrefix("REGION") {
                i += 1
                while i < rawLines.count, !rawLines[i].trimmingCharacters(in: .whitespaces).isEmpty { i += 1 }
                continue
            }

            var timingLine = trimmed
            if !timingLine.contains("-->") {
                // Optional cue identifier line
                i += 1
                guard i < rawLines.count else { break }
                timingLine = rawLines[i].trimmingCharacters(in: .whitespaces)
            }

            guard let range = timingLine.range(of: "-->") else {
                i += 1
                continue
            }

            let startStr = String(timingLine[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
            let afterArrow = timingLine[range.upperBound...]
            let endPart = String(afterArrow).trimmingCharacters(in: .whitespaces)
            let endStr: String
            if let spaceIdx = endPart.firstIndex(where: { $0.isWhitespace }) {
                endStr = String(endPart[..<spaceIdx])
            } else {
                endStr = endPart
            }

            guard let start = parseTimestamp(startStr),
                  let end = parseTimestamp(endStr),
                  end > start
            else {
                i += 1
                continue
            }

            i += 1
            var bodyLines: [String] = []
            while i < rawLines.count {
                let bl = rawLines[i]
                if bl.trimmingCharacters(in: .whitespaces).isEmpty { i += 1; break }
                bodyLines.append(bl)
                i += 1
            }

            let rawBody = bodyLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !rawBody.isEmpty else { continue }
            let cleaned = stripInlineTags(from: rawBody)
            cues.append(VTTCue(start: start, end: end, text: cleaned))
        }

        cues.sort { $0.start < $1.start }
        return cues
    }

    private static func stripInlineTags(from text: String) -> String {
        let full = NSRange(text.startIndex..<text.endIndex, in: text)
        return inlineTagRegex.stringByReplacingMatches(in: text, options: [], range: full, withTemplate: "")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Parses `HH:MM:SS.mmm`, `MM:SS.mmm`, or `SSS` (seconds only with optional fraction).
    private static func parseTimestamp(_ s: String) -> TimeInterval? {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }

        let parts = t.split(separator: ":").map(String.init)
        switch parts.count {
        case 1:
            return Double(t.replacingOccurrences(of: ",", with: "."))
        case 2:
            guard let m = Double(parts[0]),
                  let sec = parseSecondsFragment(parts[1]) else { return nil }
            return m * 60 + sec
        case 3:
            guard let h = Double(parts[0]),
                  let m = Double(parts[1]),
                  let sec = parseSecondsFragment(parts[2]) else { return nil }
            return h * 3600 + m * 60 + sec
        default:
            return nil
        }
    }

    private static func parseSecondsFragment(_ s: String) -> TimeInterval? {
        let normalized = s.replacingOccurrences(of: ",", with: ".")
        return Double(normalized)
    }
}
