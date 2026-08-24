import Foundation

/// Row for the home category picker (`GET /api/v1/videos/categories` → `{"1":"Music",…}`).
struct VideoCategoryMenuItem: Identifiable, Hashable {
    let id: Int
    let label: String
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
