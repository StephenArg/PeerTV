import Foundation

/// Resolved caption track for playback (list menu + VTT fetch URL).
struct PeerTubeCaption: Hashable {
    let languageId: String
    let displayLabel: String
    let automaticallyGenerated: Bool
    let sourceURL: URL
}

/// API response for `GET /api/v1/videos/{id}/captions` (PeerTube v6–v8).
struct VideoCaptionsResponse: Decodable {
    let total: Int?
    let data: [VideoCaptionAPI]?
}

/// Raw caption row from PeerTube. v8 prefers `fileUrl`; older versions use `captionPath`.
struct VideoCaptionAPI: Decodable, Hashable {
    let language: VideoCaptionLanguage?
    let automaticallyGenerated: Bool?
    let captionPath: String?
    let fileUrl: String?

    struct VideoCaptionLanguage: Decodable, Hashable {
        let id: String?
        let label: String?
    }

    /// Builds a playable caption entry when a URL can be resolved.
    func resolvedPeerTubeCaption(instanceBase: URL?) -> PeerTubeCaption? {
        guard let langId = language?.id, !langId.isEmpty else { return nil }
        let label = language?.label?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? Self.displayLanguageName(for: langId)
        let url: URL?
        if let s = fileUrl?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty,
           let absolute = URL(string: s) {
            url = absolute
        } else {
            url = PeerTubeAssetURL.resolve(path: captionPath, instanceBase: instanceBase, federatedHost: nil)
        }
        guard let url else { return nil }
        return PeerTubeCaption(
            languageId: langId,
            displayLabel: label,
            automaticallyGenerated: automaticallyGenerated ?? false,
            sourceURL: url
        )
    }

    private static func displayLanguageName(for code: String) -> String {
        if let s = Locale.current.localizedString(forLanguageCode: code) { return s }
        let primary = code.split(separator: "-").first.map(String.init) ?? code
        return Locale.current.localizedString(forLanguageCode: primary) ?? code
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

extension Array where Element == VideoCaptionAPI {
    func peerTubeCaptions(instanceBase: URL?) -> [PeerTubeCaption] {
        compactMap { $0.resolvedPeerTubeCaption(instanceBase: instanceBase) }
    }
}
