import SwiftUI

/// Debug view that lets you fetch raw JSON for any endpoint to aid model iteration.
struct APIExplorerView: View {
    @EnvironmentObject var session: SessionStore
    @State private var selectedEndpoint = EndpointOption.config
    @State private var idField = ""
    @State private var jsonResult = ""
    @State private var isLoading = false

    enum EndpointOption: String, CaseIterable {
        case config = "/api/v1/config"
        case videos = "/api/v1/videos?start=0&count=2"
        case videoDetail = "/api/v1/videos/{id}"
        case channels = "/api/v1/video-channels?start=0&count=2"
        case channelDetail = "/api/v1/video-channels/{handle}"
        case playlists = "/api/v1/video-playlists?start=0&count=2"
        case me = "/api/v1/users/me"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Picker("Endpoint", selection: $selectedEndpoint) {
                ForEach(EndpointOption.allCases, id: \.self) { option in
                    Text(option.rawValue).tag(option)
                }
            }

            if selectedEndpoint == .videoDetail || selectedEndpoint == .channelDetail {
                TextField("ID or handle", text: $idField)
                    .textFieldStyle(.plain)
                    .padding()
                    .background(Color.white.opacity(0.1))
                    .cornerRadius(8)
            }

            Button(isLoading ? "Loading..." : "Fetch") {
                Task { await fetch() }
            }
            .disabled(isLoading)

            ScrollView {
                Text(jsonResult)
                    .font(.system(.caption2, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .background(Color.black.opacity(0.3))
            .cornerRadius(8)
        }
        .padding(60)
        .navigationTitle("API Explorer")
    }

    private func fetch() async {
        guard let base = session.baseURL else {
            jsonResult = "No instance URL configured"
            return
        }
        isLoading = true
        defer { isLoading = false }

        var path = selectedEndpoint.rawValue
        if selectedEndpoint == .videoDetail {
            path = "/api/v1/videos/\(idField)"
        } else if selectedEndpoint == .channelDetail {
            path = "/api/v1/video-channels/\(idField)"
        }

        guard let url = URL(string: base.absoluteString + path) else {
            jsonResult = "Invalid URL"
            return
        }

        do {
            let data = try await session.apiClient.getData(from: url)
            let json = try JSONSerialization.jsonObject(with: data)
            let pretty = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
            jsonResult = String(data: pretty, encoding: .utf8) ?? "Could not format JSON"
        } catch {
            jsonResult = "Error: \(error.localizedDescription)"
        }
    }
}
