import Foundation

#if canImport(UIKit)
import UIKit
#endif

/// Converts PeerTube / ActivityPub HTML comment bodies to plain text for SwiftUI `Text`.
enum HTMLPlainText {
    static func string(from html: String) -> String {
        let trimmed = html.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        guard trimmed.contains("<") else { return decodeHTMLEntities(trimmed) }

        #if canImport(UIKit)
        if let data = trimmed.data(using: .utf8),
           let attributed = try? NSAttributedString(
               data: data,
               options: [
                   .documentType: NSAttributedString.DocumentType.html,
                   .characterEncoding: String.Encoding.utf8.rawValue
               ],
               documentAttributes: nil
           ) {
            let plain = attributed.string
                .replacingOccurrences(of: "\u{FFFC}", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !plain.isEmpty { return plain }
        }
        #endif

        return stripTagsFallback(trimmed)
    }

    private static func stripTagsFallback(_ html: String) -> String {
        var text = html
        text = text.replacingOccurrences(
            of: "<br\\s*/?>",
            with: "\n",
            options: [.regularExpression, .caseInsensitive]
        )
        text = text.replacingOccurrences(
            of: "<[^>]+>",
            with: "",
            options: .regularExpression
        )
        return decodeHTMLEntities(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func decodeHTMLEntities(_ text: String) -> String {
        let wrapped = "<span>\(text)</span>"
        guard let data = wrapped.data(using: .utf8),
              let attributed = try? NSAttributedString(
                  data: data,
                  options: [
                      .documentType: NSAttributedString.DocumentType.html,
                      .characterEncoding: String.Encoding.utf8.rawValue
                  ],
                  documentAttributes: nil
              ) else {
            return text
        }
        return attributed.string.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
