import SwiftUI

// MARK: - Shared sheet layout

/// Layout for the filter sheets: Done and Clear sit in a fixed column on the left, so they are
/// one press to the left from any row of the options, however long the list. The options scroll
/// on the right. Closing the sheet any other way (the Menu button) applies the draft too.
struct FilterSheetLayout<Content: View>: View {
    let title: String
    let summary: String
    let clearDisabled: Bool
    let onClear: () -> Void
    @ViewBuilder let content: () -> Content

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        HStack(alignment: .top, spacing: 40) {
            VStack(alignment: .leading, spacing: 14) {
                Text(title)
                    .font(.title3)
                    .bold()
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 24)

                actionButton("Done", systemImage: "checkmark.circle") {
                    dismiss()
                }
                actionButton("Clear", systemImage: "xmark.circle", action: onClear)
                    .disabled(clearDisabled)
                    .opacity(clearDisabled ? 0.5 : 1)

                Spacer(minLength: 24)

                Text("Back also applies and closes.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .frame(width: 280, alignment: .leading)
            .focusSection()

            ScrollView {
                content()
                    .padding(.trailing, 60)
                    .padding(.bottom, 40)
            }
            .focusSection()
        }
        .padding(.leading, 60)
        .padding(.top, 40)
        .padding(.bottom, 24)
        .wideFilterSheet()
    }

    private func actionButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: systemImage)
                Text(title)
            }
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .buttonStyle(.card)
    }
}

/// One selectable option tile, the same in every filter sheet.
struct FilterChoiceButton: View {
    let label: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 20) {
                Text(label)
                    .font(.callout)
                    .lineLimit(1)
                    .minimumScaleFactor(0.55)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.primary)
                        .layoutPriority(1)
                }
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 18)
        }
        .buttonStyle(.card)
    }
}

/// Section title inside a filter sheet, with an optional one-line note under it.
struct FilterSectionHeader: View {
    let title: String
    var note: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.secondary)
            if let note {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

extension View {
    /// Expands the tvOS sheet chrome to match a wider content frame (tvOS 18+).
    /// Without `presentationSizing(.fitted)`, a large `.frame(width:)` only widens
    /// content inside the default sheet and clips it.
    @ViewBuilder
    func wideFilterSheet() -> some View {
        if #available(tvOS 18.0, *) {
            self
                .frame(width: 1240, height: 920)
                .presentationSizing(.fitted)
        } else {
            self
        }
    }
}

// MARK: - Home filters

/// Live, category and language filters for the home grid (`isLive`, `categoryOneOf` and
/// `languageOneOf` on `GET /api/v1/videos`). Edits a draft; the caller applies it when the sheet
/// closes, whether through Done or the Menu button.
struct HomeFiltersPickerView: View {
    let categories: [VideoCategoryMenuItem]
    let commonLanguages: [VideoLanguageMenuItem]
    let otherLanguages: [VideoLanguageMenuItem]
    @Binding var filters: HomeVideoFilters

    private let columns = [
        GridItem(.flexible(), spacing: 24),
        GridItem(.flexible(), spacing: 24)
    ]

    var body: some View {
        FilterSheetLayout(
            title: "Filters",
            summary: filters.isEmpty
                ? "Showing every video. Leave a group empty to include everything in it."
                : "\(filters.activeCount) selected.",
            clearDisabled: filters.isEmpty,
            onClear: { filters = HomeVideoFilters() }
        ) {
            VStack(alignment: .leading, spacing: 28) {
                FilterSectionHeader(title: "Live")
                HStack(spacing: 24) {
                    ForEach(HomeLiveFilter.allCases) { option in
                        FilterChoiceButton(label: option.displayName, selected: filters.live == option) {
                            filters.live = option
                        }
                    }
                }

                if !categories.isEmpty {
                    FilterSectionHeader(title: "Categories")
                    LazyVGrid(columns: columns, spacing: 20) {
                        ForEach(categories) { category in
                            FilterChoiceButton(label: category.label, selected: filters.categoryIds.contains(category.id)) {
                                toggle(category.id, in: &filters.categoryIds)
                            }
                        }
                    }
                }

                if !commonLanguages.isEmpty || !otherLanguages.isEmpty {
                    FilterSectionHeader(
                        title: "Languages",
                        note: "Many videos have no language set. Select “Not specified” to keep those in the list."
                    )
                    HStack(spacing: 24) {
                        FilterChoiceButton(label: "Spoken in", selected: !filters.includeSubtitled) {
                            filters.includeSubtitled = false
                        }
                        FilterChoiceButton(label: "Spoken or subtitled in", selected: filters.includeSubtitled) {
                            filters.includeSubtitled = true
                        }
                    }
                    Text(filters.includeSubtitled
                        ? "Also shows videos in other languages that have subtitles in a selected one."
                        : "Only videos whose audio is in a selected language.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    LazyVGrid(columns: columns, spacing: 20) {
                        ForEach(commonLanguages) { language in
                            FilterChoiceButton(label: language.label, selected: filters.languageIds.contains(language.id)) {
                                toggle(language.id, in: &filters.languageIds)
                            }
                        }
                    }

                    if !otherLanguages.isEmpty {
                        FilterSectionHeader(title: "More languages")
                        LazyVGrid(columns: columns, spacing: 20) {
                            ForEach(otherLanguages) { language in
                                FilterChoiceButton(label: language.label, selected: filters.languageIds.contains(language.id)) {
                                    toggle(language.id, in: &filters.languageIds)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func toggle<ID: Hashable>(_ id: ID, in selection: inout Set<ID>) {
        if selection.contains(id) {
            selection.remove(id)
        } else {
            selection.insert(id)
        }
    }
}
