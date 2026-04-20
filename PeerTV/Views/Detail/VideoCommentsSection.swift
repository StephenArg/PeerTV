import SwiftUI

struct VideoCommentsSection: View {
    @ObservedObject var vm: VideoDetailViewModel
    @EnvironmentObject private var session: SessionStore

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Comments")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)

            if vm.commentsLoading && vm.comments.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
            } else if let err = vm.commentsError, vm.comments.isEmpty {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
            } else if vm.comments.isEmpty {
                Text("No comments yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(vm.commentDisplayRows) { row in
                        selectableCommentRow(row.comment, depth: row.depth)
                    }
                }
            }

            if session.tokenStore.accessToken != nil {
                VStack(alignment: .leading, spacing: 12) {
                    TextField("Add a comment…", text: $vm.commentDraft, axis: .vertical)
                        .lineLimit(1...2)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        // Without a cap, a vertical-axis TextField expands to fill spare space when the list above is empty.
                        .frame(maxWidth: .infinity, maxHeight: 100, alignment: .topLeading)
                        .background(.ultraThinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 10))

                    HStack(alignment: .center, spacing: 20) {
                        Button {
                            Task { await vm.postComment() }
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "paperplane.fill")
                                Text(vm.isPostingComment ? "Posting…" : "Post")
                            }
                            .font(.callout)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 16)
                        }
                        .buttonStyle(.card)
                        .disabled(vm.isPostingComment || vm.commentDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                        if let err = vm.commentPostError {
                            Text(err)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.top, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func selectableCommentRow(_ comment: VideoComment, depth: Int) -> some View {
        Button {
            vm.toggleCommentSelection(comment.id)
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 12) {
                    if depth > 0 {
                        Image(systemName: "arrow.turn.down.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .padding(.top, 4)
                    }

                    ChannelAvatarView(
                        url: session.thumbnailURL(path: comment.account?.avatars?.first?.path)
                    )
                    .frame(width: 36, height: 36)

                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Text(comment.account?.displayName ?? comment.account?.name ?? "Unknown")
                                .font(.subheadline)
                                .fontWeight(.medium)
                            if let when = comment.relativeDateLabel {
                                Text(when)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        if let name = comment.account?.name,
                           let display = comment.account?.displayName,
                           name != display {
                            Text(name)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        if comment.heldForReview == true {
                            Text("Pending moderation")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                        if let text = comment.text, !text.isEmpty {
                            Text(text)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        if vm.selectedCommentId == comment.id {
                            accountDetailsBlock(comment.account)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 12)
            .padding(.horizontal, 14)
        }
        .buttonStyle(.card)
        .padding(.leading, CGFloat(depth) * 22)
        .accessibilityLabel(commentAccessibilityLabel(comment))
    }

    private func commentAccessibilityLabel(_ comment: VideoComment) -> String {
        let author = comment.account?.displayName ?? comment.account?.name ?? "Unknown"
        let snippet = (comment.text ?? "").prefix(80)
        return "Comment by \(author). \(snippet)"
    }

    @ViewBuilder
    private func accountDetailsBlock(_ account: AccountSummary?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Author")
                .font(.caption2)
                .fontWeight(.semibold)
                .foregroundStyle(.tertiary)
                .textCase(.uppercase)

            if let host = account?.host {
                Label("\(account?.displayName ?? account?.name ?? "Unknown")@\(host)", systemImage: "globe")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 4)
    }
}
