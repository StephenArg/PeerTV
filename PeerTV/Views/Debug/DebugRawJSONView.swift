import SwiftUI

/// Raw JSON in a sheet-friendly scroll surface (plain `List` gets a bounded scroll area on tvOS).
struct DebugRawJSONView: View {
    let title: String
    let json: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Text(json)
                    .font(.system(.caption, design: .monospaced))
                    .multilineTextAlignment(.leading)
                    .listRowInsets(EdgeInsets(top: 16, leading: 24, bottom: 16, trailing: 24))
                    .listRowBackground(Color.clear)
            }
            .listStyle(.plain)
            .scrollIndicators(.visible)
            .navigationTitle("JSON: \(title)")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }
}
