import SwiftUI
import UIKit

struct FlatComment: Identifiable {
    let comment: Comment
    let depth: Int
    let parentName: String?
    let descendants: Int
    let blocks: [MessageBlock]

    var id: Int { comment.id }
    var authorName: String { CommentsModel.displayName(comment) }
    var score: Int { (comment.likesCount ?? 0) - (comment.dislikesCount ?? 0) }
}

/// A top-level comment with all of its replies in thread order.
struct CommentThread: Identifiable {
    let root: FlatComment
    let replies: [FlatComment]

    var id: Int { root.id }
}

enum CommentSort: String, CaseIterable, Identifiable {
    case oldest = "Сначала старые"
    case newest = "Сначала новые"
    case popular = "Популярные"

    var id: Self { self }

    var icon: String {
        switch self {
        case .oldest: return "clock.arrow.circlepath"
        case .newest: return "clock"
        case .popular: return "hand.thumbsup"
        }
    }
}

/// One visible comment with what is needed to draw the thread lines next to it.
struct CommentLine: Identifiable {
    let item: FlatComment
    /// Nesting level used for layout, capped so deep threads keep their width.
    let level: Int
    /// `continues[k]` is true when the line of level `k` goes on below this row.
    let continues: [Bool]
    let hasVisibleChildren: Bool

    var id: Int { item.id }
}

@MainActor
final class CommentsModel: ObservableObject {
    @Published private(set) var threads: [CommentThread] = []
    @Published private(set) var loaded = false
    @Published var collapsed: Set<Int> = []
    @Published var error: String?
    @Published var sort: CommentSort = .oldest {
        didSet {
            guard sort != oldValue else { return }
            // In "popular" mode the point is to skim top-level comments,
            // so threads start collapsed.
            if sort == .popular {
                collapseAll()
            } else if oldValue == .popular {
                collapsed = []
            }
        }
    }

    /// Comments posted since the previous visit. Fixed for the lifetime of
    /// the screen so highlights don't vanish once the visit is recorded.
    @Published private(set) var newIds: Set<Int> = []
    /// New comments already reached with the "next new" navigation.
    @Published private(set) var visitedNew: Set<Int> = []
    @Published private(set) var currentNew: Int?
    /// Number of new comments among each comment's replies.
    private(set) var newReplies: [Int: Int] = [:]

    let path: String
    /// Set once the article is loaded; needed to remember what was seen.
    var articleId: Int?
    private let seen = SeenComments.shared

    init(path: String) {
        self.path = path
    }

    var remainingNew: Int { newIds.subtracting(visitedNew).count }

    /// New comments in the order they appear on screen.
    private var newInDisplayOrder: [Int] {
        sortedThreads.flatMap { [$0.root] + $0.replies }.map(\.id).filter { newIds.contains($0) }
    }

    /// Moves to the next (or previous) new comment and returns its id.
    func stepNew(by offset: Int) -> Int? {
        let order = newInDisplayOrder
        guard !order.isEmpty else { return nil }
        let index = currentNew.flatMap { order.firstIndex(of: $0) }
        let next: Int
        if let index {
            next = order[(index + offset + order.count) % order.count]
        } else {
            next = offset > 0 ? order[0] : order[order.count - 1]
        }
        currentNew = next
        visitedNew.insert(next)
        return next
    }

    /// Records every loaded comment as seen. With `clearHighlights` the new
    /// comment marks disappear right away (the "mark as read" button).
    func markAllSeen(clearHighlights: Bool = false) {
        guard loaded, let articleId else { return }
        let ids = threads.flatMap { [$0.root.id] + $0.replies.map(\.id) }
        seen.markSeen(articleId: articleId, lastSeenId: ids.max() ?? 0, commentCount: ids.count)
        if clearHighlights {
            newIds = []
            newReplies = [:]
            visitedNew = []
            currentNew = nil
        }
    }

    private func updateNewComments() {
        guard let articleId else { return }
        let ids = threads.flatMap { [$0.root.id] + $0.replies.map(\.id) }
        guard let record = seen.record(for: articleId) else {
            // First visit: nothing is new, remember everything as seen.
            newIds = []
            newReplies = [:]
            seen.markSeen(articleId: articleId, lastSeenId: ids.max() ?? 0, commentCount: ids.count)
            return
        }
        newIds = Set(ids.filter { $0 > record.lastSeenId })
        visitedNew = visitedNew.intersection(newIds)
        seen.updateCount(articleId: articleId, commentCount: ids.count)

        var counts: [Int: Int] = [:]
        if !newIds.isEmpty {
            for thread in threads {
                let items = [thread.root] + thread.replies
                for (i, item) in items.enumerated() where item.descendants > 0 {
                    var n = 0
                    var j = i + 1
                    while j < items.count, items[j].depth > item.depth {
                        if newIds.contains(items[j].id) { n += 1 }
                        j += 1
                    }
                    if n > 0 { counts[item.id] = n }
                }
            }
        }
        newReplies = counts
    }

    var totalCount: Int {
        threads.reduce(0) { $0 + 1 + $1.replies.count }
    }

    var sortedThreads: [CommentThread] {
        switch sort {
        case .oldest:
            return threads
        case .newest:
            return threads.reversed()
        case .popular:
            return threads.enumerated().sorted { a, b in
                let l = a.element.root, r = b.element.root
                if l.score != r.score { return l.score > r.score }
                let ll = l.comment.likesCount ?? 0, rl = r.comment.likesCount ?? 0
                if ll != rl { return ll > rl }
                return a.offset < b.offset
            }.map(\.element)
        }
    }

    /// Replies of a thread, without the replies of collapsed comments.
    func visibleReplies(of thread: CommentThread) -> [FlatComment] {
        if collapsed.contains(thread.id) { return [] }
        guard !collapsed.isEmpty else { return thread.replies }
        var result: [FlatComment] = []
        var skipDeeperThan: Int?
        for item in thread.replies {
            if let limit = skipDeeperThan {
                if item.depth > limit { continue }
                skipDeeperThan = nil
            }
            result.append(item)
            if collapsed.contains(item.id) { skipDeeperThan = item.depth }
        }
        return result
    }

    func load() async {
        do {
            let tree = try await APIClient.shared.comments(path: path)
            threads = await Task.detached(priority: .userInitiated) { CommentsModel.makeThreads(tree) }.value
            if sort == .popular { collapseAll() }
            updateNewComments()
            loaded = true
            error = nil
        } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled { return }
            self.error = error.localizedDescription
        }
    }

    /// Visible comments of a thread prepared for drawing.
    func lines(for thread: CommentThread) -> [CommentLine] {
        let items = [thread.root] + visibleReplies(of: thread)
        let levels = items.map { min($0.depth, CommentLayout.maxLevel) }
        var result: [CommentLine] = []
        result.reserveCapacity(items.count)
        // Walk backwards: a level's line continues past a row when a later
        // sibling at that level comes before the thread climbs above it.
        var pending = [Bool](repeating: false, count: CommentLayout.maxLevel + 2)
        for i in items.indices.reversed() {
            let level = levels[i]
            let continues = Array(pending[0...level])
            pending[level] = true
            for k in (level + 1)..<pending.count { pending[k] = false }
            let hasChildren = i + 1 < items.count && items[i + 1].depth > items[i].depth
            result.append(CommentLine(item: items[i], level: level, continues: continues,
                                      hasVisibleChildren: hasChildren))
        }
        return result.reversed()
    }

    func toggle(_ id: Int) {
        if collapsed.contains(id) { collapsed.remove(id) } else { collapsed.insert(id) }
    }

    func collapseAll() {
        collapsed = Set(threads.filter { !$0.replies.isEmpty }.map(\.id))
    }

    /// Expands every collapsed ancestor so the comment becomes visible.
    func reveal(_ id: Int) -> Bool {
        for thread in threads {
            if thread.id == id { return true }
            guard let index = thread.replies.firstIndex(where: { $0.id == id }) else { continue }
            collapsed.remove(thread.id)
            var depth = thread.replies[index].depth
            var i = index
            while depth > 1, i > 0 {
                i -= 1
                if thread.replies[i].depth < depth {
                    collapsed.remove(thread.replies[i].id)
                    depth = thread.replies[i].depth
                }
            }
            return true
        }
        return false
    }

    nonisolated static func displayName(_ comment: Comment) -> String {
        if let name = comment.name?.trimmingCharacters(in: .whitespaces), !name.isEmpty { return name }
        return "Аноним"
    }

    nonisolated private static func makeThreads(_ tree: [Comment]) -> [CommentThread] {
        func flatten(_ comments: [Comment], depth: Int, parentName: String?, into result: inout [FlatComment]) -> Int {
            var count = 0
            for comment in comments {
                let index = result.count
                result.append(FlatComment(comment: comment, depth: depth, parentName: parentName,
                                          descendants: 0, blocks: []))
                let children = flatten(comment.children ?? [], depth: depth + 1,
                                       parentName: displayName(comment), into: &result)
                result[index] = FlatComment(comment: comment, depth: depth, parentName: parentName,
                                            descendants: children,
                                            blocks: CommentMarkdown.blocks(from: comment.message ?? ""))
                count += 1 + children
            }
            return count
        }

        return tree.map { root in
            var replies: [FlatComment] = []
            let count = flatten(root.children ?? [], depth: 1, parentName: displayName(root), into: &replies)
            let rootItem = FlatComment(comment: root, depth: 0, parentName: nil, descendants: count,
                                       blocks: CommentMarkdown.blocks(from: root.message ?? ""))
            return CommentThread(root: rootItem, replies: replies)
        }
    }
}

enum Plural {
    static func form(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
        let mod10 = n % 10, mod100 = n % 100
        if mod10 == 1 && mod100 != 11 { return one }
        if (2...4).contains(mod10) && !(12...14).contains(mod100) { return few }
        return many
    }

    static func comments(_ n: Int) -> String {
        "\(n) \(form(n, "комментарий", "комментария", "комментариев"))"
    }

    static func newComments(_ n: Int) -> String {
        "\(n) \(form(n, "новый", "новых", "новых"))"
    }

    static func replies(_ n: Int) -> String {
        "\(n) \(form(n, "ответ", "ответа", "ответов"))"
    }
}

/// Comment metrics: compact one-line headers and colored thread bars.
enum CommentLayout {
    static let maxLevel = 4
    static let indent: CGFloat = 12
    static let barWidth: CGFloat = 2
    static let avatarSize: CGFloat = 24
    static let horizontalPadding: CGFloat = 16
    static let verticalPadding: CGFloat = 10
    static let barColors: [Color] = [.orange, .blue, .green, .purple, .pink]
}

struct CommentRow: View {
    let line: CommentLine
    let showsSeparator: Bool
    let isCollapsed: Bool
    let isHighlighted: Bool
    let isNew: Bool
    let newReplies: Int
    let commentURL: URL
    let onToggle: () -> Void
    let onParent: (Int) -> Void
    let onImage: (URL) -> Void

    private var item: FlatComment { line.item }
    private var comment: Comment { item.comment }
    private var isAnonymous: Bool { comment.name?.trimmingCharacters(in: .whitespaces).isEmpty ?? true }
    private var contentInset: CGFloat { CGFloat(line.level) * CommentLayout.indent }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsSeparator {
                Divider()
            }
            VStack(alignment: .leading, spacing: 6) {
                header

                if comment.hidden == true {
                    Text(comment.message ?? "Комментарий скрыт")
                        .font(.subheadline.italic())
                        .foregroundStyle(.secondary)
                } else {
                    MessageView(blocks: item.blocks)
                }

                if let images = comment.images, !images.isEmpty {
                    imageStrip(images)
                }

                footer
            }
            .padding(.vertical, CommentLayout.verticalPadding)
        }
        .padding(.leading, contentInset)
        .background(alignment: .leading) {
            // One colored bar per nesting level; consecutive rows join up
            // into continuous thread lines.
            HStack(spacing: CommentLayout.indent - CommentLayout.barWidth) {
                ForEach(0..<line.level, id: \.self) { k in
                    Rectangle()
                        .fill(CommentLayout.barColors[k % CommentLayout.barColors.count].opacity(0.85))
                        .frame(width: CommentLayout.barWidth)
                }
            }
        }
        .padding(.horizontal, CommentLayout.horizontalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isHighlighted ? Color.accentColor.opacity(0.16)
                        : isNew ? Color.accentColor.opacity(0.08) : Color.clear)
        .contentShape(Rectangle())
        .contextMenu {
            if let message = comment.message, !message.isEmpty {
                Button {
                    UIPasteboard.general.string = message
                } label: {
                    Label("Скопировать текст", systemImage: "doc.on.doc")
                }
            }
            ShareLink(item: commentURL) {
                Label("Поделиться ссылкой", systemImage: "square.and.arrow.up")
            }
            if let parent = comment.parentId {
                Button {
                    onParent(parent)
                } label: {
                    Label("К родительскому комментарию", systemImage: "arrow.turn.left.up")
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 7) {
            AvatarView(name: item.authorName, color: AuthorColor.color(for: comment),
                       isAnonymous: isAnonymous, isBot: comment.isBot == true,
                       size: CommentLayout.avatarSize)

            Text(item.authorName)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .layoutPriority(1)

            if comment.isBot == true {
                Text("БОТ")
                    .font(.caption2.weight(.bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.accentColor, in: Capsule())
            }

            HStack(spacing: 5) {
                // Anonymous authors are told apart by their IP hash.
                if isAnonymous, let hash = comment.ipHash, !hash.isEmpty {
                    Text(hash).font(.footnote.monospaced())
                }
                if let date = comment.createdAt {
                    Text("· \(DateParsing.relative(date))")
                }
                if isNew {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 6, height: 6)
                        .accessibilityLabel("Новый")
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .lineLimit(1)

            Spacer(minLength: 4)

            RatingControl(likes: comment.likesCount ?? 0, dislikes: comment.dislikesCount ?? 0)
        }
    }

    @ViewBuilder
    private var footer: some View {
        let deepParent = item.depth > CommentLayout.maxLevel ? comment.parentId : nil
        if item.descendants > 0 || deepParent != nil {
            HStack(spacing: 20) {
                if let parent = deepParent {
                    Button {
                        onParent(parent)
                    } label: {
                        Label(item.parentName ?? "Ответ", systemImage: "arrow.turn.left.up")
                            .lineLimit(1)
                    }
                }
                if item.descendants > 0 {
                    Button(action: onToggle) {
                        HStack(spacing: 5) {
                            Image(systemName: isCollapsed ? "chevron.down" : "chevron.up")
                                .font(.caption2.weight(.bold))
                            Text(isCollapsed ? Plural.replies(item.descendants) : "Свернуть")
                            if isCollapsed, newReplies > 0 {
                                Text("+\(newReplies)")
                                    .fontWeight(.semibold)
                                    .foregroundColor(.accentColor)
                            }
                        }
                        .frame(minHeight: 30)
                        .contentShape(Rectangle())
                    }
                }
            }
            .buttonStyle(.plain)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(.vertical, -4)
        }
    }

    @ViewBuilder
    private func imageStrip(_ images: [CommentImage]) -> some View {
        let urls = images.compactMap { URL(string: $0.url) }
        if urls.count == 1, let url = urls.first {
            Button {
                onImage(url)
            } label: {
                AsyncImage(url: url) { phase in
                    if let img = phase.image {
                        img.resizable().scaledToFit()
                    } else {
                        Color(.tertiarySystemFill).frame(height: 200)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: 360, alignment: .leading)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(urls, id: \.self) { url in
                        Button {
                            onImage(url)
                        } label: {
                            AsyncImage(url: url) { phase in
                                if let img = phase.image {
                                    img.resizable().scaledToFill()
                                } else {
                                    Color(.tertiarySystemFill)
                                }
                            }
                            .frame(width: 180, height: 180)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

/// Net rating (likes minus dislikes) between up and down arrows: green when
/// positive, red when negative. Tapping it shows the breakdown.
struct RatingControl: View {
    let likes: Int
    let dislikes: Int

    private var score: Int { likes - dislikes }

    private var text: String {
        if score > 0 { return "+\(score)" }
        if score < 0 { return "\u{2212}\(-score)" }
        return "0"
    }

    private var color: Color {
        if score > 0 { return Color(.systemGreen) }
        if score < 0 { return Color(.systemRed) }
        return .primary
    }

    var body: some View {
        Menu {
            Button {} label: {
                Label("Нравится: \(likes)", systemImage: "arrowshape.up")
            }
            Button {} label: {
                Label("Не нравится: \(dislikes)", systemImage: "arrowshape.down")
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "arrowshape.up")
                    .foregroundStyle(.secondary)
                Text(text)
                    .font(.footnote.weight(.semibold))
                    .monospacedDigit()
                    .foregroundColor(color)
                    .frame(minWidth: 20)
                Image(systemName: "arrowshape.down")
                    .foregroundStyle(.secondary)
            }
            .font(.footnote)
            .frame(minHeight: 30)
            .contentShape(Rectangle())
        }
        .accessibilityLabel("Рейтинг \(text): нравится \(likes), не нравится \(dislikes)")
    }
}

/// A stable per-author color, derived from the IP hash so the same person
/// keeps the same color across threads.
enum AuthorColor {
    /// System colors with their dark-mode hex values for the article HTML.
    private static let palette: [(color: Color, hex: String)] = [
        (.blue, "#0A84FF"), (.green, "#30D158"), (.orange, "#FF9F0A"),
        (.purple, "#BF5AF2"), (.pink, "#FF375F"), (.teal, "#40C8E0"),
        (.indigo, "#5E5CE6"), (.red, "#FF453A"), (.brown, "#AC8E68"),
    ]

    static func color(for comment: Comment) -> Color {
        color(seed: comment.ipHash ?? comment.name ?? "", isBot: comment.isBot == true)
    }

    static func color(seed: String, isBot: Bool) -> Color {
        if isBot { return .accentColor }
        return index(seed).map { palette[$0].color } ?? .gray
    }

    static func hex(seed: String, isBot: Bool) -> String {
        if isBot { return "#CE2956" }
        return index(seed).map { palette[$0].hex } ?? "#8E8E93"
    }

    private static func index(_ seed: String) -> Int? {
        guard !seed.isEmpty else { return nil }
        // djb2: stable across launches, unlike Hasher.
        var hash: UInt64 = 5381
        for byte in seed.utf8 { hash = (hash &* 33) &+ UInt64(byte) }
        return Int(hash % UInt64(palette.count))
    }
}

struct AvatarView: View {
    let name: String
    let color: Color
    let isAnonymous: Bool
    let isBot: Bool
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle().fill(color.gradient)
            Group {
                if isBot {
                    Image(systemName: "sparkles")
                } else if isAnonymous {
                    Image(systemName: "person.fill")
                } else {
                    Text(String(name.prefix(1)).uppercased())
                }
            }
            .font(.system(size: size * 0.42, weight: .semibold, design: .rounded))
            .foregroundColor(.white)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

extension DateParsing {
    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.unitsStyle = .full
        return f
    }()

    /// "5 минут назад" for the last week, a short date after that.
    static func relative(_ date: Date) -> String {
        let age = Date().timeIntervalSince(date)
        if age < 60 { return "только что" }
        if age < 7 * 24 * 3600 { return relativeFormatter.localizedString(for: date, relativeTo: Date()) }
        return short(date)
    }
}

struct ViewerImage: Identifiable {
    let url: URL
    var id: URL { url }
}

struct ImageViewer: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            AsyncImage(url: url) { phase in
                if let image = phase.image {
                    image
                        .resizable()
                        .scaledToFit()
                        .scaleEffect(scale)
                        .gesture(
                            MagnificationGesture()
                                .onChanged { scale = max(1, lastScale * $0) }
                                .onEnded { _ in lastScale = scale }
                        )
                        .onTapGesture(count: 2) {
                            withAnimation {
                                scale = scale > 1 ? 1 : 2.5
                                lastScale = scale
                            }
                        }
                } else if phase.error != nil {
                    Image(systemName: "photo")
                        .font(.largeTitle)
                        .foregroundColor(.gray)
                } else {
                    ProgressView().tint(.white)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(Color.white, Color.white.opacity(0.3))
            }
            .padding()
            .accessibilityLabel("Закрыть")
        }
    }
}
