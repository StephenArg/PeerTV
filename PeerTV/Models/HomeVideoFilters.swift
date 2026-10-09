import Foundation

/// Row for the home Filters sheet (`GET /api/v1/videos/categories` → `{"1":"Music",…}`).
struct VideoCategoryMenuItem: Identifiable, Hashable {
    let id: Int
    let label: String
}

/// Row for the home Filters sheet (`GET /api/v1/videos/languages` → `{"en":"English",…}`).
struct VideoLanguageMenuItem: Identifiable, Hashable {
    let id: String
    let label: String

    /// Videos with no language set. `languageOneOf=_unknown` matches them; the server's language
    /// list doesn't include it, so it is added by hand. Most uploads never set a language.
    static let unspecified = VideoLanguageMenuItem(id: "_unknown", label: "Not specified")
}

/// Live-stream filter on the home grid (`isLive` on `GET /api/v1/videos`).
enum HomeLiveFilter: String, CaseIterable, Identifiable {
    case any
    case liveOnly
    case recordedOnly

    static let defaultsKey = "PeerTV.homeLiveFilter"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .any: "Any"
        case .liveOnly: "Live only"
        case .recordedOnly: "Recorded only"
        }
    }

    /// Maps to the API's `isLive` query value. `nil` means "don't send the parameter".
    var isLive: Bool? {
        switch self {
        case .any: nil
        case .liveOnly: true
        case .recordedOnly: false
        }
    }

    static func loadSaved(defaults: UserDefaults = .standard) -> HomeLiveFilter {
        defaults.string(forKey: defaultsKey).flatMap(HomeLiveFilter.init(rawValue:)) ?? .any
    }

    static func save(_ filter: HomeLiveFilter, defaults: UserDefaults = .standard) {
        if filter == .any {
            defaults.removeObject(forKey: defaultsKey)
        } else {
            defaults.set(filter.rawValue, forKey: defaultsKey)
        }
    }
}

/// Everything the home Filters sheet edits at once.
struct HomeVideoFilters: Equatable {
    var categoryIds: Set<Int> = []
    var languageIds: Set<String> = []
    /// Also keep videos that only have subtitles in a selected language (what the server's
    /// `languageOneOf` matches anyway). Off: the spoken language has to be selected.
    var includeSubtitled: Bool = false
    var live: HomeLiveFilter = .any

    var isEmpty: Bool {
        categoryIds.isEmpty && languageIds.isEmpty && live == .any
    }

    /// Shown on the Filters button: each selected category and language, plus one for a live choice.
    /// The subtitles choice widens a language filter rather than adding one, so it isn't counted.
    var activeCount: Int {
        categoryIds.count + languageIds.count + (live == .any ? 0 : 1)
    }

    /// True when both would show the same videos: the subtitles choice only matters once a
    /// language is selected.
    func selectsSameVideos(as other: HomeVideoFilters) -> Bool {
        categoryIds == other.categoryIds
            && languageIds == other.languageIds
            && live == other.live
            && (languageIds.isEmpty || includeSubtitled == other.includeSubtitled)
    }
}

enum HomeVideoCategoryFilter {
    static let defaultsKey = "PeerTV.homeVideoCategories"

    static func loadSavedIds(defaults: UserDefaults = .standard) -> [Int] {
        guard let saved = defaults.array(forKey: defaultsKey) as? [Int] else {
            return []
        }
        return saved
    }

    static func saveIds(_ ids: [Int], defaults: UserDefaults = .standard) {
        if ids.isEmpty {
            defaults.removeObject(forKey: defaultsKey)
        } else {
            defaults.set(ids, forKey: defaultsKey)
        }
    }

    static func orderedIds(from selection: Set<Int>, availableIds: [Int]) -> [Int] {
        let set = Set(selection)
        return availableIds.filter { set.contains($0) }
    }
}

enum HomeVideoLanguageFilter {
    static let defaultsKey = "PeerTV.homeVideoLanguages"
    static let includeSubtitledDefaultsKey = "PeerTV.homeVideoLanguagesIncludeSubtitled"

    static func loadSavedIds(defaults: UserDefaults = .standard) -> [String] {
        guard let saved = defaults.array(forKey: defaultsKey) as? [String] else {
            return []
        }
        return saved
    }

    static func saveIds(_ ids: [String], defaults: UserDefaults = .standard) {
        if ids.isEmpty {
            defaults.removeObject(forKey: defaultsKey)
        } else {
            defaults.set(ids, forKey: defaultsKey)
        }
    }

    static func loadIncludeSubtitled(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: includeSubtitledDefaultsKey)
    }

    static func saveIncludeSubtitled(_ include: Bool, defaults: UserDefaults = .standard) {
        if include {
            defaults.set(true, forKey: includeSubtitledDefaultsKey)
        } else {
            defaults.removeObject(forKey: includeSubtitledDefaultsKey)
        }
    }

    static func orderedIds(from selection: Set<String>, availableIds: [String]) -> [String] {
        let set = Set(selection)
        return availableIds.filter { set.contains($0) }
    }
}
