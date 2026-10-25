import Foundation

/// Remembers which comments were already seen, the same way the site does in
/// localStorage ("newComments"): per article, the highest comment id seen and
/// the comment count at that moment.
@MainActor
final class SeenComments: ObservableObject {
    struct Record: Codable {
        var lastSeenId: Int
        var commentCount: Int
    }

    static let shared = SeenComments()

    private static let storageKey = "newComments"

    @Published private var records: [String: Record]

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode([String: Record].self, from: data) {
            records = decoded
        } else {
            records = [:]
        }
    }

    func record(for articleId: Int) -> Record? {
        records[Self.key(articleId)]
    }

    /// Comments added since the article's comments were last opened; zero
    /// for articles whose comments were never opened.
    func newCount(articleId: Int, commentCount: Int?) -> Int {
        guard let record = record(for: articleId), let commentCount else { return 0 }
        return max(0, commentCount - record.commentCount)
    }

    func markSeen(articleId: Int, lastSeenId: Int, commentCount: Int) {
        records[Self.key(articleId)] = Record(lastSeenId: lastSeenId, commentCount: commentCount)
        save()
    }

    /// Updates the count (clearing the feed badge) but keeps `lastSeenId`, so
    /// new comments stay highlighted while they are being read.
    func updateCount(articleId: Int, commentCount: Int) {
        guard var record = records[Self.key(articleId)], record.commentCount != commentCount else { return }
        record.commentCount = commentCount
        records[Self.key(articleId)] = record
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(records) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }

    private static func key(_ articleId: Int) -> String {
        "article-\(articleId)"
    }
}
