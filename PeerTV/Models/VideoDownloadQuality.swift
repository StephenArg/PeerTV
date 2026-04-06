import Foundation

enum DownloadQualityPreference: CaseIterable, Identifiable {
    case highest
    case p2160
    case p1080
    case p720
    case p480
    case p360
    case lowest

    var id: String { label }

    var label: String {
        switch self {
        case .highest: return "Highest"
        case .p2160:   return "2160p"
        case .p1080:   return "1080p"
        case .p720:    return "720p"
        case .p480:    return "480p"
        case .p360:    return "360p"
        case .lowest:  return "Lowest"
        }
    }

    /// Target resolution id cap; nil means no cap (highest/lowest use sort instead).
    var targetResolutionId: Int? {
        switch self {
        case .highest: return nil
        case .p2160:   return 2160
        case .p1080:   return 1080
        case .p720:    return 720
        case .p480:    return 480
        case .p360:    return 360
        case .lowest:  return nil
        }
    }
}

/// Picks the best downloadable file from a Video for a given quality preference.
/// Returns (file, qualityLabel) or nil if no suitable file exists.
func pickVideoFile(video: Video, preference: DownloadQualityPreference) -> (file: VideoFile, label: String)? {
    let candidates = downloadableFiles(for: video)
    guard !candidates.isEmpty else { return nil }

    switch preference {
    case .highest:
        let best = candidates.max(by: { ($0.file.resolution?.id ?? 0) < ($1.file.resolution?.id ?? 0) })
        return best.map { ($0.file, $0.label) }

    case .lowest:
        let best = candidates.min(by: { ($0.file.resolution?.id ?? 0) < ($1.file.resolution?.id ?? 0) })
        return best.map { ($0.file, $0.label) }

    default:
        guard let cap = preference.targetResolutionId else { return nil }
        let atOrBelow = candidates
            .filter { ($0.file.resolution?.id ?? 0) <= cap }
            .max(by: { ($0.file.resolution?.id ?? 0) < ($1.file.resolution?.id ?? 0) })
        if let match = atOrBelow { return (match.file, match.label) }
        // Nothing at or below target — pick the lowest available
        let fallback = candidates.min(by: { ($0.file.resolution?.id ?? 0) < ($1.file.resolution?.id ?? 0) })
        return fallback.map { ($0.file, $0.label) }
    }
}

private struct CandidateFile {
    let file: VideoFile
    let label: String
}

private func downloadableFiles(for video: Video) -> [CandidateFile] {
    var results: [CandidateFile] = []

    if let webFiles = video.files, !webFiles.isEmpty {
        for file in webFiles {
            guard let resId = file.resolution?.id, resId > 0,
                  let label = file.resolution?.label else { continue }
            guard file.fileDownloadUrl != nil || file.fileUrl != nil else { continue }
            results.append(CandidateFile(file: file, label: label))
        }
    }

    if results.isEmpty, let hlsFiles = video.streamingPlaylists?.first?.files {
        for file in hlsFiles {
            guard let resId = file.resolution?.id, resId > 0,
                  let label = file.resolution?.label else { continue }
            guard file.fileDownloadUrl != nil || file.fileUrl != nil || file.playlistUrl != nil else { continue }
            results.append(CandidateFile(file: file, label: label))
        }
    }

    return results.sorted { ($0.file.resolution?.id ?? 0) > ($1.file.resolution?.id ?? 0) }
}
