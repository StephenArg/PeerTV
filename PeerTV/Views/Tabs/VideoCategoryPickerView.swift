import SwiftUI

/// Multiselect category filter for home video listing (`categoryOneOf` on `GET /api/v1/videos`).
struct VideoCategoryPickerView: View {
    @Environment(\.dismiss) private var dismiss

    let categories: [VideoCategoryMenuItem]
    let initialSelection: Set<Int>
    let onApply: (Set<Int>) -> Void

    @State private var selection: Set<Int>

    private let columns = [
        GridItem(.flexible(), spacing: 32),
        GridItem(.flexible(), spacing: 32)
    ]

    init(
        categories: [VideoCategoryMenuItem],
        initialSelection: Set<Int>,
        onApply: @escaping (Set<Int>) -> Void
    ) {
        self.categories = categories
        self.initialSelection = initialSelection
        self.onApply = onApply
        _selection = State(initialValue: initialSelection)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    Text("Show videos in these categories. Leave all off for every category.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 64)

                    LazyVGrid(columns: columns, spacing: 20) {
                        ForEach(categories) { category in
                            Button {
                                toggle(category.id)
                            } label: {
                                HStack(spacing: 20) {
                                    Text(category.label)
                                        .font(.callout)
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.55)
                                        .truncationMode(.tail)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    if selection.contains(category.id) {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(.primary)
                                            .layoutPriority(1)
                                    }
                                }
                                .padding(.horizontal, 40)
                                .padding(.vertical, 18)
                            }
                            .buttonStyle(.card)
                        }
                    }
                    .padding(.horizontal, 64)
                }
                .padding(.top, 36)
                .padding(.bottom, 28)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                actionBar
                    .focusSection()
            }
        }
        .wideCategorySheet()
    }

    private var actionBar: some View {
        HStack(spacing: 28) {
            if selection.isEmpty {
                Text("All categories")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Text("\(selection.count) selected")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 16)

            HStack(spacing: 28) {
                Button {
                    clearSelection()
                } label: {
                    Text("Clear")
                        .font(.callout)
                        .padding(.horizontal, 48)
                        .padding(.vertical, 16)
                }
                .buttonStyle(.card)
                .disabled(selection.isEmpty)

                Button {
                    applyAndDismiss()
                } label: {
                    Text("Done")
                        .font(.callout)
                        .padding(.horizontal, 48)
                        .padding(.vertical, 16)
                }
                .buttonStyle(.card)
            }
            .fixedSize(horizontal: true, vertical: false)
            .layoutPriority(1)
        }
        .padding(.horizontal, 64)
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial)
    }

    private func clearSelection() {
        selection = []
        onApply(Set())
    }

    private func applyAndDismiss() {
        dismiss()
    }

    private func toggle(_ id: Int) {
        if selection.contains(id) {
            selection.remove(id)
        } else {
            selection.insert(id)
        }
        onApply(selection)
    }
}

// MARK: - Wide sheet presentation

private extension View {
    /// Expands the tvOS sheet chrome to match a wider content frame (tvOS 18+).
    /// Without `presentationSizing(.fitted)`, a large `.frame(width:)` only widens
    /// content inside the default sheet and clips it.
    @ViewBuilder
    func wideCategorySheet() -> some View {
        if #available(tvOS 18.0, *) {
            self
                .frame(width: 1000, height: 920)
                .presentationSizing(.fitted)
        } else {
            self
        }
    }
}
