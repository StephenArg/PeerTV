import SwiftUI

/// Multiselect language filter for Trending on Fediverse (`language_id` on peertube.watch hot API).
/// Edits a draft; the caller applies it when the sheet closes, whether through Done or the Menu button.
struct FediverseLanguagePickerView: View {
    @Binding var selection: Set<String>

    private let columns = [
        GridItem(.flexible(), spacing: 24),
        GridItem(.flexible(), spacing: 24)
    ]

    var body: some View {
        FilterSheetLayout(
            title: "Languages",
            summary: selection.isEmpty
                ? "Showing trending videos in every language."
                : "\(selection.count) selected.",
            clearDisabled: selection.isEmpty,
            onClear: { selection = [] }
        ) {
            VStack(alignment: .leading, spacing: 28) {
                FilterSectionHeader(title: "Show trending videos in")
                LazyVGrid(columns: columns, spacing: 20) {
                    ForEach(FediverseHotLanguage.allInOrder) { language in
                        FilterChoiceButton(label: language.displayName, selected: selection.contains(language.rawValue)) {
                            if selection.contains(language.rawValue) {
                                selection.remove(language.rawValue)
                            } else {
                                selection.insert(language.rawValue)
                            }
                        }
                    }
                }
            }
        }
    }
}
