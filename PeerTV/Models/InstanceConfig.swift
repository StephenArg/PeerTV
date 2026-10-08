import Foundation

/// Partial model for GET /api/v1/config — only the fields we care about.
struct InstanceConfig: Decodable {
    let instance: InstanceInfo?
    let serverVersion: String?
}

struct InstanceInfo: Decodable {
    let name: String?
    let shortDescription: String?
}

// MARK: - Public server directory

/// One row from the public PeerTube directory (`instances.joinpeertube.org`).
struct PeerTubeDirectoryInstance: Decodable {
    let host: String
    let name: String?
    let shortDescription: String?
    let totalLocalVideos: Int?
    let totalUsers: Int?
    /// 0–100, the directory's recent uptime score.
    let health: Int?
    let isNSFW: Bool?
    let signupAllowed: Bool?
}

/// A server offered on the server-selection screen: a curated host, with details filled in from
/// the directory when it answers.
struct PopularServer: Identifiable {
    let host: String
    /// Shown until the directory's own description arrives, and if it never does.
    let tagline: String
    var directory: PeerTubeDirectoryInstance?

    var id: String { host }
    var url: URL { URL(string: "https://\(host)")! }

    var displayName: String {
        let name = directory?.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? host : name
    }

    var blurb: String {
        let text = directory?.shortDescription?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? tagline : text
    }
}

enum PeerTubeDirectory {
    private static let instancesURL = URL(string: "https://instances.joinpeertube.org/api/v1/instances")!
    /// Directory health score below which a server is left off the list.
    static let minimumHealth = 80

    /// Well-known general-purpose servers, in display order. The directory lookup drops any that
    /// have gone unhealthy or disappeared, so the list stays usable between app updates.
    static let curatedPopularServers: [PopularServer] = [
        PopularServer(host: "tilvids.com", tagline: "Edutainment, in English"),
        PopularServer(host: "makertube.net", tagline: "Makers, musicians, artists and DIY"),
        PopularServer(host: "tube.tchncs.de", tagline: "Content made by the people who post it"),
        PopularServer(host: "peertube.wtf", tagline: "General use, hosted in northern Europe"),
        PopularServer(host: "spectra.video", tagline: "Original creators"),
        PopularServer(host: "video.hardlimit.com", tagline: "Computers, hardware and gaming, in Spanish and English"),
        PopularServer(host: "peertube.tv", tagline: "General-purpose, run by a French non-profit"),
        PopularServer(host: "framatube.org", tagline: "Framasoft, the makers of PeerTube"),
        PopularServer(host: "peertube.ch", tagline: "Generic, mostly English and French"),
        PopularServer(host: "peertube.linuxrocks.online", tagline: "Linux and open source"),
        PopularServer(host: "peertube.stream", tagline: "General-purpose, in French"),
        PopularServer(host: "skeptikon.fr", tagline: "Science and skepticism, in French"),
        PopularServer(host: "peertube.uno", tagline: "General-purpose, in Italian"),
        PopularServer(host: "tube.kockatoo.org", tagline: "The KDE community"),
    ]

    /// The directory's entry for one host, or `nil` when it doesn't list the host.
    static func lookup(host: String) async throws -> PeerTubeDirectoryInstance? {
        var components = URLComponents(url: instancesURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "start", value: "0"),
            URLQueryItem(name: "count", value: "5"),
            URLQueryItem(name: "search", value: host),
        ]
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        let page = try JSONDecoder().decode(PaginatedResponse<PeerTubeDirectoryInstance>.self, from: data)
        return page.items.first { $0.host.caseInsensitiveCompare(host) == .orderedSame }
    }
}
