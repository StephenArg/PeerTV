import Foundation

/// A single comment on a video (PeerTube `/videos/{id}/comment-threads` list items).
struct VideoComment: Decodable, Hashable, Identifiable {
    let commentId: Int?
    let text: String?
    let threadId: Int?
    let inReplyToCommentId: Int?
    let createdAt: String?
    let account: AccountSummary?
    let isDeleted: Bool?
    let heldForReview: Bool?

    var id: String {
        if let commentId { return "c-\(commentId)" }
        return "c-\(threadId ?? 0)-\(createdAt ?? "")-\(text ?? "")"
    }

    /// Root thread comment (not a reply). Some instances omit `inReplyToCommentId` only for roots.
    var isRoot: Bool {
        guard let reply = inReplyToCommentId else { return true }
        if let cid = commentId, reply == cid { return true }
        return false
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(commentId)
        hasher.combine(createdAt)
    }

    static func == (lhs: VideoComment, rhs: VideoComment) -> Bool {
        lhs.commentId == rhs.commentId && lhs.createdAt == rhs.createdAt
    }

    var relativeDateLabel: String? {
        guard let dateStr = createdAt else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = iso.date(from: dateStr) ?? {
            let basic = ISO8601DateFormatter()
            basic.formatOptions = [.withInternetDateTime]
            return basic.date(from: dateStr)
        }()
        guard let date else { return nil }
        let rel = RelativeDateTimeFormatter()
        rel.unitsStyle = .abbreviated
        return rel.localizedString(for: date, relativeTo: Date())
    }

    private enum CodingKeys: String, CodingKey {
        case commentId = "id"
        case text
        case threadId
        case inReplyToCommentId
        case createdAt
        case account
        case isDeleted
        case heldForReview
    }
}

struct VideoCommentsListResponse: Decodable {
    let total: Int?
    let totalNotDeletedComments: Int?
    let data: [VideoComment]?
}

struct PostCommentResponse: Decodable {
    let comment: VideoComment?
}

/// Nested branch from `GET /videos/{id}/comment-threads/{threadId}` (replies under a thread).
struct CommentThreadBranch: Decodable {
    let comment: VideoComment?
    let children: [CommentThreadBranch]?
}

struct VideoCommentThreadDetailResponse: Decodable {
    let comment: VideoComment?
    let children: [CommentThreadBranch]?
}

/// Flatten nested reply branches (excludes the thread root; roots come from the list endpoint).
func flattenCommentBranches(_ branches: [CommentThreadBranch]?) -> [VideoComment] {
    var out: [VideoComment] = []
    for branch in branches ?? [] {
        if let c = branch.comment { out.append(c) }
        out.append(contentsOf: flattenCommentBranches(branch.children))
    }
    return out
}

/// Ordered rows for UI: roots (newest first), then each subtree in chronological order with depth.
struct CommentDisplayRow: Identifiable {
    let comment: VideoComment
    let depth: Int
    var id: String { comment.id }

    static func rows(from comments: [VideoComment]) -> [CommentDisplayRow] {
        let visible = comments.filter { $0.isDeleted != true }
        let roots = visible.filter(\.isRoot).sorted {
            ($0.createdAt ?? "") > ($1.createdAt ?? "")
        }
        var out: [CommentDisplayRow] = []
        for root in roots {
            walkThread(root, depth: 0, visible: visible, rows: &out)
        }
        return out
    }

    private static func walkThread(_ node: VideoComment, depth: Int, visible: [VideoComment], rows: inout [CommentDisplayRow]) {
        rows.append(CommentDisplayRow(comment: node, depth: depth))
        let children = visible
            .filter { $0.inReplyToCommentId == node.commentId }
            .sorted { ($0.createdAt ?? "") < ($1.createdAt ?? "") }
        for child in children {
            walkThread(child, depth: depth + 1, visible: visible, rows: &rows)
        }
    }
}

extension AccountSummary {
    /// PeerTube-style handle when local name and federation host are known.
    var handleAtHost: String? {
        guard let name, let host, !name.isEmpty, !host.isEmpty else { return nil }
        return "@\(name)@\(host)"
    }
}
