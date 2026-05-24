import Foundation

/// Limits concurrent / bursty anonymous requests to public PeerTube instances (e.g. peertube.watch).
actor FederatedOriginThrottle {
    static let shared = FederatedOriginThrottle()

    private var inFlight: [String: Int] = [:]
    private var lastStartedAt: [String: Date] = [:]

    private let minSpacingSeconds: TimeInterval = 0.25
    private let maxConcurrentPerHost = 2

    func acquire(host: String) async {
        let key = host.lowercased()
        while (inFlight[key] ?? 0) >= maxConcurrentPerHost {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        if let last = lastStartedAt[key] {
            let wait = minSpacingSeconds - Date().timeIntervalSince(last)
            if wait > 0 {
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            }
        }
        inFlight[key, default: 0] += 1
        lastStartedAt[key] = Date()
    }

    func release(host: String) {
        let key = host.lowercased()
        inFlight[key] = max(0, (inFlight[key] ?? 1) - 1)
    }
}
