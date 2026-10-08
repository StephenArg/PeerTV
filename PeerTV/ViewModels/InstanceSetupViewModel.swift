import Foundation

@MainActor
final class InstanceSetupViewModel: ObservableObject {
    @Published var urlText: String = "https://"
    @Published var isValidating = false
    @Published var errorMessage: String?
    @Published var instanceName: String?
    /// Starts as the curated list so the picker is never empty; `loadPopularServers` refines it.
    @Published private(set) var popularServers: [PopularServer] = PeerTubeDirectory.curatedPopularServers
    @Published private(set) var isLoadingPopularServers = false

    private var didLoadPopularServers = false

    func validate(using host: any AccountLoginHost, onSuccess: (() -> Void)? = nil) async {
        errorMessage = nil
        guard let url = URL(string: urlText),
              url.scheme == "https" || url.scheme == "http" else {
            errorMessage = "Enter a valid URL starting with https://"
            return
        }
        isValidating = true
        defer { isValidating = false }

        let configURL = url.appendingPathComponent("/api/v1/config")
        do {
            let data = try await host.apiClient.getData(from: configURL)
            let config = try JSONDecoder().decode(InstanceConfig.self, from: data)
            instanceName = config.instance?.name
            host.setInstance(url)
            onSuccess?()
        } catch {
            errorMessage = "Could not reach PeerTube instance. Check the URL and try again."
        }
    }

    /// Fills in names, descriptions and sizes from the public directory and drops servers it no
    /// longer lists or reports unhealthy. Runs once per screen; the curated list shows meanwhile.
    func loadPopularServers() async {
        guard !didLoadPopularServers else { return }
        didLoadPopularServers = true
        isLoadingPopularServers = true
        defer { isLoadingPopularServers = false }

        let curated = PeerTubeDirectory.curatedPopularServers
        typealias Lookup = Result<PeerTubeDirectoryInstance?, Error>
        let lookups = await withTaskGroup(of: (host: String, result: Lookup).self) { group -> [String: Lookup] in
            for server in curated {
                group.addTask {
                    do {
                        return (server.host, .success(try await PeerTubeDirectory.lookup(host: server.host)))
                    } catch {
                        return (server.host, .failure(error))
                    }
                }
            }
            var byHost: [String: Lookup] = [:]
            for await lookup in group {
                byHost[lookup.host] = lookup.result
            }
            return byHost
        }

        // Every lookup failing means the directory (or the network) is down; keep the list as is.
        let anySucceeded = lookups.values.contains { if case .success = $0 { return true } else { return false } }
        guard anySucceeded else { return }

        popularServers = curated.compactMap { server in
            switch lookups[server.host] {
            case .success(let entry?):
                guard entry.isNSFW != true,
                      (entry.health ?? 100) >= PeerTubeDirectory.minimumHealth else { return nil }
                var enriched = server
                enriched.directory = entry
                return enriched
            case .success(nil):
                // No longer in the directory: most likely gone.
                return nil
            case .failure, .none:
                return server
            }
        }
    }
}
