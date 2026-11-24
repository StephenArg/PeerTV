import Foundation
import Network
import os

/// Keeps the parts of an HLS stream that were already downloaded, so jumping back plays them from
/// disk instead of fetching them again.
///
/// AVPlayer drops what it has played and has no setting to keep it, so this is a small HTTP proxy
/// on 127.0.0.1. The player's asset points at the proxy; the proxy fetches playlists from the
/// server (rewriting every URI in them to go through the proxy too) and fetches media byte ranges
/// through `HLSSegmentStore`, which answers from disk when it already has the bytes.
///
/// PeerTube HLS is one fragmented MP4 per quality, read in `EXT-X-BYTERANGE` pieces, so the store
/// keeps byte ranges per file and can serve any request its saved ranges cover.
///
/// Not used for live streams or local downloads. If the proxy can't start, callers get `nil`
/// and play the stream directly, as before.
final class HLSCacheProxy: @unchecked Sendable {
    static let shared = HLSCacheProxy()

    /// Played video kept behind the playhead, on top of what the Buffer cap keeps ahead.
    static let rewindBytes: Int64 = 1 << 30

    private static let log = Logger(subsystem: "com.peernext.PeerTV", category: "HLSCacheProxy")

    private let queue = DispatchQueue(label: "PeerTV.HLSCacheProxy")
    private var listener: NWListener?
    private var port: UInt16?
    private var preferredPort: UInt16?
    /// Upstream request headers (the Bearer token) per asset, keyed by the id in proxied paths.
    private var sessions: [String: [String: String]] = [:]
    private let store: HLSSegmentStore
    private let upstream: URLSession

    /// Counters for checking the cache works (read on `queue`).
    private(set) var cacheHits = 0
    private(set) var cacheMisses = 0

    init(
        directory: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PeerTVSegmentCache", isDirectory: true),
        capacity: @escaping () -> Int64 = { HLSCacheProxy.rewindBytes + Int64(PlayerSettings.bufferCap.bytes) }
    ) {
        store = HLSSegmentStore(directory: directory, capacity: capacity)
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.httpMaximumConnectionsPerHost = 6
        upstream = URLSession(configuration: config)

        // Suspension can close the listening socket; reopen it on the same port when the app
        // comes back so players created before still reach it.
        NotificationCenter.default.addObserver(
            forName: Notification.Name("UIApplicationWillEnterForegroundNotification"),
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.queue.async { self?.restartIfNeeded() }
        }
    }

    var stats: (hits: Int, misses: Int) {
        queue.sync { (cacheHits, cacheMisses) }
    }

    /// Starts the proxy now so the first video doesn't wait for it.
    func start() {
        queue.async { self.startListenerIfNeeded() }
    }

    /// The URL to give AVPlayer for `url` (an HLS playlist), or `nil` when the proxy isn't
    /// available and the caller should play `url` directly. `headers` go with every upstream request.
    func proxiedURL(for url: URL, headers: [String: String]) -> URL? {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else { return nil }
        let session = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12)
        let ready: UInt16? = queue.sync {
            sessions[String(session)] = headers
            startListenerIfNeeded()
            return port
        }
        let readyPort = ready ?? waitForPort(timeout: 2)
        guard let readyPort else {
            Self.log.error("proxy unavailable; playing directly")
            return nil
        }
        return Self.makeProxiedURL(for: url, session: String(session), port: readyPort)
    }

    // MARK: Listener

    private func waitForPort(timeout: TimeInterval) -> UInt16? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let p = queue.sync(execute: { port }) { return p }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return nil
    }

    private func startListenerIfNeeded() {
        guard listener == nil else { return }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let requested = preferredPort.flatMap(NWEndpoint.Port.init(rawValue:)) ?? .any
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: requested)
        let newListener: NWListener
        do {
            newListener = try NWListener(using: params)
        } catch {
            Self.log.error("listener create failed: \(error.localizedDescription, privacy: .public)")
            if preferredPort != nil {
                preferredPort = nil
                startListenerIfNeeded()
            }
            return
        }
        listener = newListener
        newListener.stateUpdateHandler = { [weak self, weak newListener] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.port = newListener?.port?.rawValue
                self.preferredPort = self.port
            case .failed(let error):
                Self.log.error("listener failed: \(error.localizedDescription, privacy: .public)")
                newListener?.cancel()
                if self.listener === newListener {
                    self.listener = nil
                    self.port = nil
                    // A taken preferred port: fall back to any port.
                    if case .posix(let code) = error, code == .EADDRINUSE { self.preferredPort = nil }
                    self.queue.asyncAfter(deadline: .now() + 0.5) { self.startListenerIfNeeded() }
                }
            case .cancelled:
                if self.listener === newListener {
                    self.listener = nil
                    self.port = nil
                }
            default:
                break
            }
        }
        newListener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        newListener.start(queue: queue)
    }

    private func restartIfNeeded() {
        if let listener, listener.state != .ready {
            listener.cancel()
            self.listener = nil
            port = nil
        }
        startListenerIfNeeded()
    }

    // MARK: Connections

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveRequest(on: connection, buffer: Data())
    }

    private func receiveRequest(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
                self.handle(head: head, on: connection)
            } else if error != nil || isComplete || buffer.count > 64 * 1024 {
                connection.cancel()
            } else {
                self.receiveRequest(on: connection, buffer: buffer)
            }
        }
    }

    private func handle(head: String, on connection: NWConnection) {
        let lines = head.components(separatedBy: "\r\n")
        let parts = (lines.first ?? "").split(separator: " ")
        guard parts.count >= 2 else { return respond(on: connection, status: 400) }
        let method = String(parts[0]).uppercased()
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()] =
                line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard method == "GET" || method == "HEAD",
              let (session, upstreamURL) = Self.decode(path: String(parts[1])),
              let sessionHeaders = sessions[session] else {
            return respond(on: connection, status: 404)
        }
        let isHead = method == "HEAD"

        if Self.isPlaylist(upstreamURL) {
            fetchPlaylist(upstreamURL, session: session, headers: sessionHeaders, isHead: isHead, on: connection)
        } else {
            serveMedia(upstreamURL, range: headers["range"].flatMap(ByteRangeRequest.init), headers: sessionHeaders, isHead: isHead, on: connection)
        }
    }

    // MARK: Playlists (never cached; URIs rewritten to the proxy)

    private func fetchPlaylist(_ url: URL, session: String, headers: [String: String], isHead: Bool, on connection: NWConnection) {
        var request = URLRequest(url: url)
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        upstream.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            self.queue.async {
                guard let http = response as? HTTPURLResponse, let data, error == nil else {
                    return self.respond(on: connection, status: 502)
                }
                guard (200...299).contains(http.statusCode), let port = self.port else {
                    return self.respond(on: connection, status: http.statusCode, body: data)
                }
                let base = http.url ?? url
                let text = String(decoding: data, as: UTF8.self)
                let rewritten = Self.rewritePlaylist(text, base: base, session: session, port: port)
                self.respond(
                    on: connection,
                    status: 200,
                    contentType: "application/vnd.apple.mpegurl",
                    body: Data(rewritten.utf8),
                    omitBody: isHead
                )
            }
        }.resume()
    }

    /// Points every URI in a playlist (variant and segment lines, and `URI="…"` attributes such as
    /// `EXT-X-MAP` and `EXT-X-MEDIA`) at the proxy, resolved against the playlist's own URL.
    static func rewritePlaylist(_ text: String, base: URL, session: String, port: UInt16) -> String {
        func proxied(_ reference: String) -> String {
            guard let absolute = URL(string: reference, relativeTo: base)?.absoluteURL else { return reference }
            return makeProxiedURL(for: absolute, session: session, port: port).absoluteString
        }
        let attribute = try! NSRegularExpression(pattern: #"URI="([^"]+)""#)
        return text
            .components(separatedBy: "\n")
            .map { rawLine -> String in
                let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty { return line }
                if trimmed.hasPrefix("#") {
                    let ns = line as NSString
                    var result = line
                    for match in attribute.matches(in: line, range: NSRange(location: 0, length: ns.length)).reversed() {
                        let value = ns.substring(with: match.range(at: 1))
                        result = (result as NSString).replacingCharacters(in: match.range(at: 1), with: proxied(value))
                    }
                    return result
                }
                return proxied(trimmed)
            }
            .joined(separator: "\n")
    }

    // MARK: Media (byte ranges, cached)

    /// Optional trace of media requests (testing only).
    var trace: ((String) -> Void)?

    private func serveMedia(_ url: URL, range: ByteRangeRequest?, headers: [String: String], isHead: Bool, on connection: NWConnection) {
        let key = Self.cacheKey(for: url)
        trace?("\(url.lastPathComponent) \(range?.headerValue ?? "no range")")

        if let range, let bounds = range.closedBounds, let cached = store.read(key: key, start: bounds.lowerBound, end: bounds.upperBound) {
            cacheHits += 1
            return respond(
                on: connection,
                status: 206,
                contentType: cached.contentType ?? Self.contentType(for: url),
                contentRange: "bytes \(bounds.lowerBound)-\(bounds.upperBound)/\(cached.totalLength.map(String.init) ?? "*")",
                body: cached.data,
                omitBody: isHead
            )
        }
        if range == nil, let cached = store.readWhole(key: key) {
            cacheHits += 1
            return respond(on: connection, status: 200, contentType: cached.contentType ?? Self.contentType(for: url), body: cached.data, omitBody: isHead)
        }
        cacheMisses += 1

        var request = URLRequest(url: url)
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        if let range { request.setValue(range.headerValue, forHTTPHeaderField: "Range") }
        upstream.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            self.queue.async {
                guard let http = response as? HTTPURLResponse, let data, error == nil else {
                    return self.respond(on: connection, status: 502)
                }
                let contentType = http.value(forHTTPHeaderField: "Content-Type")
                let contentRange = http.value(forHTTPHeaderField: "Content-Range")
                if http.statusCode == 206, let parsed = contentRange.flatMap(ContentRange.init) {
                    self.store.write(key: key, start: parsed.start, data: data, totalLength: parsed.total, contentType: contentType)
                } else if http.statusCode == 200 {
                    self.store.write(key: key, start: 0, data: data, totalLength: Int64(data.count), contentType: contentType)
                }
                self.respond(
                    on: connection,
                    status: http.statusCode,
                    contentType: contentType ?? Self.contentType(for: url),
                    contentRange: contentRange,
                    body: data,
                    omitBody: isHead
                )
            }
        }.resume()
    }

    // MARK: Responses

    private func respond(
        on connection: NWConnection,
        status: Int,
        contentType: String? = nil,
        contentRange: String? = nil,
        body: Data = Data(),
        omitBody: Bool = false
    ) {
        var head = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
        if let contentType { head += "Content-Type: \(contentType)\r\n" }
        if let contentRange { head += "Content-Range: \(contentRange)\r\n" }
        head += "Content-Length: \(body.count)\r\n"
        head += "Accept-Ranges: bytes\r\n"
        head += "Connection: close\r\n\r\n"
        var payload = Data(head.utf8)
        if !omitBody { payload.append(body) }
        connection.send(content: payload, completion: .contentProcessed { _ in connection.cancel() })
    }

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 206: return "Partial Content"
        case 400: return "Bad Request"
        case 404: return "Not Found"
        case 416: return "Range Not Satisfiable"
        case 502: return "Bad Gateway"
        default: return HTTPURLResponse.localizedString(forStatusCode: status).capitalized
        }
    }

    // MARK: URL mapping

    /// `http://127.0.0.1:<port>/<session>/<base64url of the URL>/<last path component>`. The last
    /// component keeps the file extension so the player can tell playlists from media.
    static func makeProxiedURL(for url: URL, session: String, port: UInt16) -> URL {
        let encoded = Data(url.absoluteString.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let name = url.lastPathComponent.isEmpty ? "file" : url.lastPathComponent
        let safeName = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "file"
        return URL(string: "http://127.0.0.1:\(port)/\(session)/\(encoded)/\(safeName)")!
    }

    static func decode(path: String) -> (session: String, url: URL)? {
        let pathOnly = path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? path
        let parts = pathOnly.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count >= 2 else { return nil }
        var base64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        guard let data = Data(base64Encoded: base64),
              let string = String(data: data, encoding: .utf8),
              let url = URL(string: string) else { return nil }
        return (String(parts[0]), url)
    }

    /// The file's identity for caching: the URL without the per-session video file token, so a
    /// later session for the same video reuses the bytes.
    static func cacheKey(for url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url.absoluteString }
        let kept = components.queryItems?.filter { !["videofiletoken", "reinjectvideofiletoken"].contains($0.name.lowercased()) }
        components.queryItems = (kept?.isEmpty ?? true) ? nil : kept
        return components.string ?? url.absoluteString
    }

    static func isPlaylist(_ url: URL) -> Bool {
        ["m3u8", "m3u"].contains(url.pathExtension.lowercased())
    }

    private static func contentType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "mp4", "m4s", "m4v": return "video/mp4"
        case "ts": return "video/mp2t"
        case "aac": return "audio/aac"
        case "vtt", "webvtt": return "text/vtt"
        default: return "application/octet-stream"
        }
    }
}

// MARK: - Range parsing

/// `Range: bytes=a-b` (or `bytes=a-`) from the player.
struct ByteRangeRequest: Equatable {
    let start: Int64
    let end: Int64?

    init?(_ header: String) {
        let value = header.trimmingCharacters(in: .whitespaces).lowercased()
        guard value.hasPrefix("bytes="), !value.contains(",") else { return nil }
        let pieces = value.dropFirst("bytes=".count).split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard pieces.count == 2, let start = Int64(pieces[0]) else { return nil }
        self.start = start
        if pieces[1].isEmpty {
            end = nil
        } else {
            guard let end = Int64(pieces[1]), end >= start else { return nil }
            self.end = end
        }
    }

    var closedBounds: ClosedRange<Int64>? { end.map { start...$0 } }
    var headerValue: String { "bytes=\(start)-\(end.map(String.init) ?? "")" }
}

/// `Content-Range: bytes a-b/total` from the server.
struct ContentRange {
    let start: Int64
    let end: Int64
    let total: Int64?

    init?(_ header: String) {
        let value = header.trimmingCharacters(in: .whitespaces).lowercased()
        guard value.hasPrefix("bytes ") else { return nil }
        let rest = value.dropFirst("bytes ".count)
        let halves = rest.split(separator: "/", maxSplits: 1)
        guard halves.count == 2 else { return nil }
        let bounds = halves[0].split(separator: "-", maxSplits: 1)
        guard bounds.count == 2, let start = Int64(bounds[0]), let end = Int64(bounds[1]), end >= start else { return nil }
        self.start = start
        self.end = end
        total = Int64(halves[1])
    }
}

// MARK: - Segment store

/// Saved byte ranges on disk, per media file, evicted least recently used first once the total
/// passes `capacity()`. Starts empty each launch. Not thread-safe: `HLSCacheProxy` calls it on
/// its queue only.
final class HLSSegmentStore {
    struct Hit {
        let data: Data
        let totalLength: Int64?
        let contentType: String?
    }

    private struct Chunk {
        let id: UUID
        let start: Int64
        let length: Int64
        let path: URL
        var lastUsed: UInt64
        var end: Int64 { start + length - 1 }
    }

    private struct FileEntry {
        var chunks: [Chunk] = []   // sorted by start
        var totalLength: Int64?
        var contentType: String?
    }

    private let directory: URL
    private let capacity: () -> Int64
    private var files: [String: FileEntry] = [:]
    private(set) var totalBytes: Int64 = 0
    private var clock: UInt64 = 0

    init(directory: URL, capacity: @escaping () -> Int64) {
        self.directory = directory
        self.capacity = capacity
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Bytes `start...end` of `key`, when saved ranges cover all of them.
    func read(key: String, start: Int64, end: Int64) -> Hit? {
        guard var entry = files[key], end >= start else { return nil }
        var cursor = start
        var pieces: [(index: Int, from: Int64, to: Int64)] = []
        for (index, chunk) in entry.chunks.enumerated() where chunk.end >= cursor && chunk.start <= cursor {
            let to = min(chunk.end, end)
            if to >= cursor {
                pieces.append((index, cursor, to))
                cursor = to + 1
            }
            if cursor > end { break }
        }
        guard cursor > end else { return nil }

        var data = Data(capacity: Int(end - start + 1))
        for piece in pieces {
            let chunk = entry.chunks[piece.index]
            guard let handle = try? FileHandle(forReadingFrom: chunk.path) else { return nil }
            defer { try? handle.close() }
            do {
                try handle.seek(toOffset: UInt64(piece.from - chunk.start))
                guard let bytes = try handle.read(upToCount: Int(piece.to - piece.from + 1)),
                      bytes.count == Int(piece.to - piece.from + 1) else { return nil }
                data.append(bytes)
            } catch {
                return nil
            }
            clock += 1
            entry.chunks[piece.index].lastUsed = clock
        }
        files[key] = entry
        return Hit(data: data, totalLength: entry.totalLength, contentType: entry.contentType)
    }

    /// The whole file, when it was saved from a request with no range.
    func readWhole(key: String) -> Hit? {
        guard let total = files[key]?.totalLength, total > 0 else { return nil }
        return read(key: key, start: 0, end: total - 1)
    }

    func write(key: String, start: Int64, data: Data, totalLength: Int64?, contentType: String?) {
        guard !data.isEmpty else { return }
        let length = Int64(data.count)
        var entry = files[key] ?? FileEntry()
        if let totalLength { entry.totalLength = totalLength }
        if let contentType { entry.contentType = contentType }
        // Already covered by what's saved: nothing to add.
        if entry.chunks.contains(where: { $0.start <= start && $0.end >= start + length - 1 }) {
            files[key] = entry
            return
        }
        let id = UUID()
        let path = directory.appendingPathComponent(id.uuidString)
        guard (try? data.write(to: path)) != nil else { return }
        clock += 1
        entry.chunks.append(Chunk(id: id, start: start, length: length, path: path, lastUsed: clock))
        entry.chunks.sort { $0.start < $1.start }
        files[key] = entry
        totalBytes += length
        evict(keeping: id)
    }

    private func evict(keeping keptId: UUID) {
        let limit = capacity()
        while totalBytes > limit {
            var oldest: (key: String, index: Int, used: UInt64)?
            for (key, entry) in files {
                for (index, chunk) in entry.chunks.enumerated() where chunk.id != keptId {
                    if oldest == nil || chunk.lastUsed < oldest!.used { oldest = (key, index, chunk.lastUsed) }
                }
            }
            guard let oldest, var entry = files[oldest.key] else { return }
            let chunk = entry.chunks.remove(at: oldest.index)
            try? FileManager.default.removeItem(at: chunk.path)
            totalBytes -= chunk.length
            files[oldest.key] = entry.chunks.isEmpty ? nil : entry
        }
    }
}
