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
    let articleId: Int
    private let seen = SeenComments.shared

    init(path: String, articleId: Int) {
        self.path = path
        self.articleId = articleId
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
        guard loaded else { return }
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

    static let maxLevel = 3

    /// Visible comments of a thread prepared for drawing.
    func lines(for thread: CommentThread) -> [CommentLine] {
        let items = [thread.root] + visibleReplies(of: thread)
        let levels = items.map { min($0.depth, Self.maxLevel) }
        var result: [CommentLine] = []
        result.reserveCapacity(items.count)
        // Walk backwards: a level's line continues past a row when a later
        // sibling at that level comes before the thread climbs above it.
        var pending = [Bool](repeating: false, count: Self.maxLevel + 2)
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

struct CommentsView: View {
    let title: String
    let path: String
    @StateObject private var model: CommentsModel
    @EnvironmentObject private var router: Router
    @State private var highlighted: Int?
    @State private var viewerImage: ViewerImage?
    @Environment(\.scenePhase) private var scenePhase

    init(path: String, title: String, articleId: Int) {
        self.title = title
        self.path = path
        _model = StateObject(wrappedValue: CommentsModel(path: path, articleId: articleId))
    }

    var body: some View {
        ScrollViewReader { proxy in
            Group {
                if model.loaded {
                    feed(proxy: proxy)
                } else if let error = model.error {
                    ErrorView(message: error) {
                        Task { await model.load() }
                    }
                } else {
                    ProgressView()
                }
            }
            .overlay(alignment: .bottom) {
                if model.loaded, !model.newIds.isEmpty {
                    newCommentsPanel(proxy: proxy)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .environment(\.openURL, OpenURLAction { url in
                if url.scheme == CommentMarkdown.commentScheme, let id = Int(url.host ?? "") {
                    jump(to: id, proxy: proxy)
                    return .handled
                }
                return router.handle(url) ? .handled : .systemAction
            })
        }
        .background(Color(.systemBackground))
        .navigationTitle("Комментарии")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if model.loaded, !model.threads.isEmpty {
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Menu {
                        Picker("Сортировка", selection: $model.sort) {
                            ForEach(CommentSort.allCases) { sort in
                                Label(sort.rawValue, systemImage: sort.icon).tag(sort)
                            }
                        }
                    } label: {
                        Image(systemName: "line.3.horizontal.decrease")
                    }
                    .accessibilityLabel("Сортировка")

                    Menu {
                        Button {
                            withAnimation { model.collapseAll() }
                        } label: {
                            Label("Свернуть все ветки", systemImage: "rectangle.compress.vertical")
                        }
                        Button {
                            withAnimation { model.collapsed = [] }
                        } label: {
                            Label("Развернуть все", systemImage: "rectangle.expand.vertical")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                }
            }
        }
        .fullScreenCover(item: $viewerImage) { image in
            ImageViewer(url: image.url)
        }
        .task {
            if !model.loaded { await model.load() }
        }
        // Like the site, the visit is recorded when leaving the comments.
        .onDisappear { model.markAllSeen() }
        .onChange(of: scenePhase) { phase in
            if phase == .background { model.markAllSeen() }
        }
    }

    private var subtitle: Text {
        let base = Text("\(Plural.comments(model.totalCount)) · \(model.sort.rawValue.lowercased())")
        guard !model.newIds.isEmpty else { return base }
        return base + Text(" · \(Plural.newComments(model.newIds.count))")
            .foregroundColor(.accentColor)
            .fontWeight(.semibold)
    }

    /// Floating navigator through comments added since the last visit.
    private func newCommentsPanel(proxy: ScrollViewProxy) -> some View {
        HStack(spacing: 0) {
            Text(model.remainingNew > 0 ? Plural.newComments(model.remainingNew) : "Все новые просмотрены")
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .padding(.leading, 18)
                .padding(.trailing, 8)

            Button {
                if let id = model.stepNew(by: -1) { jump(to: id, proxy: proxy) }
            } label: {
                Image(systemName: "chevron.up")
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Предыдущий новый")

            Button {
                if let id = model.stepNew(by: 1) { jump(to: id, proxy: proxy) }
            } label: {
                Image(systemName: "chevron.down")
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Следующий новый")

            Divider().frame(height: 22)

            Button {
                withAnimation { model.markAllSeen(clearHighlights: true) }
            } label: {
                Image(systemName: "checkmark")
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Отметить все прочитанными")
            .padding(.trailing, 4)
        }
        .font(.body.weight(.semibold))
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
        .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
        .padding(.bottom, 8)
    }

    private func feed(proxy: ScrollViewProxy) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(title)
                        .font(.title2.weight(.bold))
                        .fixedSize(horizontal: false, vertical: true)
                    subtitle
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 4)

                if model.threads.isEmpty {
                    Text("Комментариев пока нет")
                        .foregroundStyle(.secondary)
                        .padding(16)
                }

                ForEach(model.sortedThreads) { thread in
                    ForEach(model.lines(for: thread)) { line in
                        CommentRow(line: line,
                                   isCollapsed: model.collapsed.contains(line.id),
                                   isHighlighted: highlighted == line.id,
                                   isNew: model.newIds.contains(line.id),
                                   newReplies: model.newReplies[line.id] ?? 0,
                                   commentURL: commentURL(line.id),
                                   onToggle: { withAnimation(.easeInOut(duration: 0.25)) { model.toggle(line.id) } },
                                   onParent: { parent in jump(to: parent, proxy: proxy) },
                                   onImage: { viewerImage = ViewerImage(url: $0) })
                            .id(line.id)
                    }
                }
            }
            .padding(.bottom, model.newIds.isEmpty ? 24 : 90)
        }
        .refreshable { await model.load() }
    }

    private func commentURL(_ id: Int) -> URL {
        var components = URLComponents(url: SiteLinks.absolute(path), resolvingAgainstBaseURL: false)
        components?.fragment = "comment-\(id)"
        return components?.url ?? SiteLinks.absolute(path)
    }

    private func jump(to id: Int, proxy: ScrollViewProxy) {
        guard model.reveal(id) else { return }
        DispatchQueue.main.async {
            withAnimation { proxy.scrollTo(id, anchor: .top) }
            highlighted = id
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                if highlighted == id {
                    withAnimation { highlighted = nil }
                }
            }
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

enum CommentLayout {
    static let indent: CGFloat = 22
    static let lineX: CGFloat = 3
    static let topPadding: CGFloat = 14
    static let rootTopPadding: CGFloat = 22
    static let bottomPadding: CGFloat = 10
    static let horizontalPadding: CGFloat = 16
    static let avatarSize: CGFloat = 38
    /// Vertical center of the avatar, where the elbow meets the row.
    static let elbowY: CGFloat = avatarSize / 2
}

struct CommentRow: View {
    let line: CommentLine
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
    private var isReply: Bool { item.depth > 0 }
    private var isAnonymous: Bool { comment.name?.trimmingCharacters(in: .whitespaces).isEmpty ?? true }
    private var topPadding: CGFloat { isReply ? CommentLayout.topPadding : CommentLayout.rootTopPadding }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if comment.hidden == true {
                Text(comment.message ?? "Комментарий скрыт")
                    .font(.body.italic())
                    .foregroundStyle(.secondary)
            } else {
                MessageView(blocks: item.blocks)
            }

            if let images = comment.images, !images.isEmpty {
                imageStrip(images)
            }

            actions
        }
        .padding(.leading, CGFloat(line.level) * CommentLayout.indent)
        .padding(.top, topPadding)
        .padding(.bottom, CommentLayout.bottomPadding)
        .padding(.horizontal, CommentLayout.horizontalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(alignment: .topLeading) {
            ThreadLines(line: line, topPadding: topPadding)
                .stroke(Color(.systemGray3), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                .padding(.leading, CommentLayout.horizontalPadding)
        }
        .background(isHighlighted ? Color.accentColor.opacity(0.14)
                        : isNew ? Color.accentColor.opacity(0.06) : Color.clear)
    }

    private var header: some View {
        HStack(spacing: 10) {
            AvatarView(name: item.authorName, color: AuthorColor.color(for: comment),
                       isAnonymous: isAnonymous, isBot: comment.isBot == true,
                       size: CommentLayout.avatarSize)
            nameAndMeta
        }
    }

    private var nameAndMeta: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(item.authorName)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if comment.isBot == true {
                    Text("БОТ")
                        .font(.caption2.weight(.bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.accentColor, in: Capsule())
                }
                if let parent = comment.parentId {
                    Button {
                        onParent(parent)
                    } label: {
                        Image(systemName: "arrow.up")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 32, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, -6)
                    .accessibilityLabel("К родительскому комментарию")
                }
            }

            HStack(spacing: 6) {
                if isNew {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 7, height: 7)
                        .accessibilityLabel("Новый")
                }
                if let date = comment.createdAt {
                    Text(DateParsing.relative(date))
                }
                // Anonymous authors are told apart by their IP hash.
                if isAnonymous, let hash = comment.ipHash, !hash.isEmpty {
                    Text("·")
                    Text(hash).font(.subheadline.monospaced())
                }
                if item.depth > CommentsModel.maxLevel, let parent = item.parentName {
                    Text("·")
                    Text("ответ \(parent)").lineLimit(1)
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
    }

    private var actions: some View {
        HStack(spacing: 20) {
            RatingPill(likes: comment.likesCount ?? 0, dislikes: comment.dislikesCount ?? 0)

            if item.descendants > 0 {
                Button(action: onToggle) {
                    Text(isCollapsed ? Plural.replies(item.descendants) + (newReplies > 0 ? " · +\(newReplies)" : "")
                                     : "Свернуть")
                        .font(.body)
                        .foregroundColor(.accentColor)
                        .frame(minHeight: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            Menu {
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
            } label: {
                Image(systemName: "ellipsis")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
        }
        .padding(.vertical, -4)
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
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
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
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

/// Draws the thread guides to the left of a reply: straight lines for the
/// ancestor levels that continue, and a rounded elbow into this comment.
struct ThreadLines: Shape {
    let line: CommentLine
    let topPadding: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let indent = CommentLayout.indent
        func x(_ level: Int) -> CGFloat { CGFloat(level - 1) * indent + CommentLayout.lineX }

        let level = line.level
        if level >= 1 {
            for k in 1..<level where line.continues[k] {
                path.move(to: CGPoint(x: x(k), y: 0))
                path.addLine(to: CGPoint(x: x(k), y: rect.height))
            }
            let lx = x(level)
            let elbowY = topPadding + CommentLayout.elbowY
            let radius: CGFloat = 10
            path.move(to: CGPoint(x: lx, y: 0))
            path.addLine(to: CGPoint(x: lx, y: elbowY - radius))
            path.addQuadCurve(to: CGPoint(x: lx + radius, y: elbowY), control: CGPoint(x: lx, y: elbowY))
            path.addLine(to: CGPoint(x: CGFloat(level) * indent - 5, y: elbowY))
            if line.continues[level] {
                path.move(to: CGPoint(x: lx, y: elbowY - radius))
                path.addLine(to: CGPoint(x: lx, y: rect.height))
            }
        }

        // Line from this comment down to its first visible reply.
        if line.hasVisibleChildren, level < CommentsModel.maxLevel {
            let cx = x(level + 1)
            path.move(to: CGPoint(x: cx, y: rect.height - CommentLayout.bottomPadding + 2))
            path.addLine(to: CGPoint(x: cx, y: rect.height))
        }
        return path
    }
}

/// Net rating (likes minus dislikes): green when positive, red when negative.
/// Tapping it shows the breakdown.
struct RatingPill: View {
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
        return Color(.secondaryLabel)
    }

    var body: some View {
        Menu {
            Button {} label: {
                Label("Нравится: \(likes)", systemImage: "hand.thumbsup")
            }
            Button {} label: {
                Label("Не нравится: \(dislikes)", systemImage: "hand.thumbsdown")
            }
        } label: {
            Text(text)
                .font(.body.weight(.semibold))
                .monospacedDigit()
                .foregroundColor(color)
                .padding(.horizontal, 12)
                .frame(minWidth: 44, minHeight: 32)
                .background(color.opacity(score == 0 ? 0.12 : 0.15), in: Capsule())
                .contentShape(Capsule())
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
