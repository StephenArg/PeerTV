import SwiftUI

/// Multiselect language filter for Trending on Fediverse (`language_id` on peertube.watch hot API).
struct FediverseLanguagePickerView: View {
    @Environment(\.dismiss) private var dismiss

    let initialSelection: Set<String>
    let onApply: (Set<String>) -> Void

    @State private var selection: Set<String>

    init(initialSelection: Set<String>, onApply: @escaping (Set<String>) -> Void) {
        self.initialSelection = initialSelection
        self.onApply = onApply
        _selection = State(initialValue: initialSelection)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Show trending videos in these languages. Leave all off for every language.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 50)

                    LazyVStack(spacing: 16) {
                        ForEach(FediverseHotLanguage.allInOrder) { language in
                            Button {
                                toggle(language.rawValue)
                            } label: {
                                HStack(spacing: 20) {
                                    Text(language.displayName)
                                        .font(.callout)
                                    Spacer()
                                    if selection.contains(language.rawValue) {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(.primary)
                                    }
                                }
                                .padding(.horizontal, 40)
                                .padding(.vertical, 16)
                            }
                            .buttonStyle(.card)
                        }
                    }
                    .padding(.horizontal, 50)
                }
                .padding(.top, 30)
                .padding(.bottom, 60)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Clear") {
                        selection = []
                    }
                    .disabled(selection.isEmpty)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        onApply(selection)
                        dismiss()
                    }
                }
            }
        }
    }

    private func toggle(_ code: String) {
        if selection.contains(code) {
            selection.remove(code)
        } else {
            selection.insert(code)
        }
    }
}
