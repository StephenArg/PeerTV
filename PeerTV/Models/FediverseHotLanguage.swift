import Foundation

/// Languages supported by `GET https://api.peertube.watch/hot` (`language_id` query).
enum FediverseHotLanguage: String, CaseIterable, Identifiable {
    case english = "en"
    case italian = "it"
    case german = "de"
    case spanish = "es"
    case french = "fr"
    case arabic = "ar"
    case bulgarian = "bg"
    case modernGreek = "el"
    case hindi = "hi"
    case japanese = "ja"
    case dutch = "nl"
    case polish = "pl"
    case portuguese = "pt"
    case russian = "ru"
    case swahili = "sw"
    case thai = "th"
    case turkish = "tr"
    case urdu = "ur"
    case vietnamese = "vi"
    case chinese = "zh"

    var id: String { rawValue }

    /// Fixed picker order (also used when building `language_id` for the hot API).
    static let allInOrder: [FediverseHotLanguage] = [
        .english, .italian, .german, .spanish, .french, .arabic, .bulgarian, .modernGreek,
        .hindi, .japanese, .dutch, .polish, .portuguese, .russian, .swahili, .thai,
        .turkish, .urdu, .vietnamese, .chinese
    ]

    var displayName: String {
        switch self {
        case .english: "English"
        case .italian: "Italian"
        case .german: "German"
        case .spanish: "Spanish"
        case .french: "French"
        case .arabic: "Arabic"
        case .bulgarian: "Bulgarian"
        case .modernGreek: "Modern Greek"
        case .hindi: "Hindi"
        case .japanese: "Japanese"
        case .dutch: "Dutch"
        case .polish: "Polish"
        case .portuguese: "Portuguese"
        case .russian: "Russian"
        case .swahili: "Swahili"
        case .thai: "Thai"
        case .turkish: "Turkish"
        case .urdu: "Urdu"
        case .vietnamese: "Vietnamese"
        case .chinese: "Chinese"
        }
    }

    /// Comma-separated `language_id` value in API order, or `nil` when nothing is selected.
    static func queryValue(from selectedCodes: [String]) -> String? {
        let set = Set(selectedCodes.map { $0.lowercased() })
        let ordered = allInOrder.map(\.rawValue).filter { set.contains($0) }
        return ordered.isEmpty ? nil : ordered.joined(separator: ",")
    }

    static func orderedCodes(from selection: Set<String>) -> [String] {
        let set = Set(selection.map { $0.lowercased() })
        return allInOrder.map(\.rawValue).filter { set.contains($0) }
    }

    static func loadSavedCodes(defaults: UserDefaults = .standard) -> [String] {
        guard let saved = defaults.array(forKey: languageDefaultsKey) as? [String] else {
            return []
        }
        return orderedCodes(from: Set(saved))
    }

    static func saveCodes(_ codes: [String], defaults: UserDefaults = .standard) {
        defaults.set(codes, forKey: languageDefaultsKey)
    }

    static let languageDefaultsKey = "PeerTV.fediverseHotLanguages"
}
