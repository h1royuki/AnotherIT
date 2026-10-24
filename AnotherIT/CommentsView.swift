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
    case oldest = "Старые"
    case newest = "Новые"
    case popular = "Популярные"

    var id: Self { self }
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

    let path: String

    init(path: String) {
        self.path = path
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
            loaded = true
            error = nil
        } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled { return }
            self.error = error.localizedDescription
        }
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

    init(path: String, title: String) {
        self.title = title
        self.path = path
        _model = StateObject(wrappedValue: CommentsModel(path: path))
    }

    var body: some View {
        ScrollViewReader { proxy in
            Group {
                if model.loaded {
                    list
                } else if let error = model.error {
                    ErrorView(message: error) {
                        Task { await model.load() }
                    }
                } else {
                    ProgressView()
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
        .navigationTitle("Комментарии")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if model.loaded, model.threads.contains(where: { !$0.replies.isEmpty }) {
                ToolbarItem(placement: .navigationBarTrailing) {
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
                        Image(systemName: "ellipsis.circle")
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
    }

    private var list: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.title3.weight(.bold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(countText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 4, leading: 4, bottom: 8, trailing: 4))

                Picker("Сортировка", selection: $model.sort.animation()) {
                    ForEach(CommentSort.allCases) { sort in
                        Text(sort.rawValue).tag(sort)
                    }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
            }

            if model.threads.isEmpty {
                Section {
                    Text("Комментариев пока нет")
                        .foregroundStyle(.secondary)
                }
            }

            ForEach(model.sortedThreads) { thread in
                Section {
                    row(thread.root)
                    ForEach(model.visibleReplies(of: thread)) { reply in
                        row(reply)
                    }
                    if !thread.replies.isEmpty {
                        threadToggle(thread)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .environment(\.defaultMinListRowHeight, 44)
        .refreshable { await model.load() }
    }

    private func row(_ item: FlatComment) -> some View {
        CommentRow(item: item,
                   isCollapsed: model.collapsed.contains(item.id),
                   commentURL: commentURL(item.id),
                   onToggle: { withAnimation(.easeInOut(duration: 0.25)) { model.toggle(item.id) } },
                   onImage: { viewerImage = ViewerImage(url: $0) })
            .id(item.id)
            .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
            .listRowBackground(highlighted == item.id ? Color.accentColor.opacity(0.15) : nil)
    }

    /// Full-width row at the bottom of a thread card: the main way to fold
    /// or unfold a whole thread.
    private func threadToggle(_ thread: CommentThread) -> some View {
        let isCollapsed = model.collapsed.contains(thread.id)
        return Button {
            withAnimation(.easeInOut(duration: 0.25)) { model.toggle(thread.id) }
        } label: {
            HStack {
                Text(isCollapsed ? "Показать ответы (\(thread.replies.count))" : "Скрыть ответы")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Image(systemName: isCollapsed ? "chevron.down" : "chevron.up")
                    .font(.subheadline.weight(.semibold))
            }
            .foregroundColor(.accentColor)
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func commentURL(_ id: Int) -> URL {
        var components = URLComponents(url: SiteLinks.absolute(path), resolvingAgainstBaseURL: false)
        components?.fragment = "comment-\(id)"
        return components?.url ?? SiteLinks.absolute(path)
    }

    private var countText: String {
        let n = model.totalCount
        let mod10 = n % 10, mod100 = n % 100
        let word: String
        if mod10 == 1 && mod100 != 11 {
            word = "комментарий"
        } else if (2...4).contains(mod10) && !(12...14).contains(mod100) {
            word = "комментария"
        } else {
            word = "комментариев"
        }
        return "\(n) \(word)"
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

struct CommentRow: View {
    let item: FlatComment
    let isCollapsed: Bool
    let commentURL: URL
    let onToggle: () -> Void
    let onImage: (URL) -> Void

    private static let maxIndent = 4
    private static let indentStep: CGFloat = 14
    private static let threadColors: [Color] = [.blue, .green, .orange, .purple, .pink, .teal]

    private var comment: Comment { item.comment }
    private var isReply: Bool { item.depth > 0 }
    private var visualDepth: Int { min(item.depth, Self.maxIndent) }
    private var isAnonymous: Bool { comment.name?.trimmingCharacters(in: .whitespaces).isEmpty ?? true }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if isReply {
                Color.clear
                    .frame(width: CGFloat(visualDepth - 1) * Self.indentStep)
                Capsule()
                    .fill(Self.threadColors[(item.depth - 1) % Self.threadColors.count].opacity(0.6))
                    .frame(width: 2)
                    .padding(.trailing, 10)
            }

            VStack(alignment: .leading, spacing: 8) {
                header

                if item.depth > Self.maxIndent, let parent = item.parentName {
                    Label("ответ \(parent)", systemImage: "arrowshape.turn.up.left.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

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
        }
        .alignmentGuide(.listRowSeparatorLeading) { _ in
            isReply ? CGFloat(visualDepth - 1) * Self.indentStep + 12 : 0
        }
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
            if isReply, item.descendants > 0 {
                Button(action: onToggle) {
                    Label(isCollapsed ? "Развернуть ветку" : "Свернуть ветку",
                          systemImage: isCollapsed ? "chevron.down" : "chevron.up")
                }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(item.authorName)
                .font(.subheadline.weight(.semibold))
                .foregroundColor(AuthorColor.color(for: comment))
                .lineLimit(1)
            // Anonymous authors are told apart by their IP hash.
            if isAnonymous, let hash = comment.ipHash, !hash.isEmpty {
                Text(hash)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            if comment.isBot == true {
                Text("БОТ")
                    .font(.caption2.weight(.bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.accentColor, in: Capsule())
            }
            Spacer(minLength: 8)
            if let date = comment.createdAt {
                Text(DateParsing.relative(date))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            VotePill(likes: comment.likesCount ?? 0, dislikes: comment.dislikesCount ?? 0)
            Spacer(minLength: 8)
            // Nested branches fold here; whole threads fold from the card's bottom row.
            if isReply, item.descendants > 0 {
                Button(action: onToggle) {
                    HStack(spacing: 4) {
                        Text(isCollapsed ? "Ответы (\(item.descendants))" : "Свернуть")
                        Image(systemName: isCollapsed ? "chevron.down" : "chevron.up")
                    }
                    .font(.footnote.weight(.semibold))
                    .foregroundColor(.accentColor)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.accentColor.opacity(0.12), in: Capsule())
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .padding(.vertical, -6)
            }
        }
    }

    private func imageStrip(_ images: [CommentImage]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(images, id: \.url) { image in
                    if let url = URL(string: image.url) {
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
                            .frame(width: 140, height: 140)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
        }
    }
}

struct VotePill: View {
    let likes: Int
    let dislikes: Int

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 4) {
                Image(systemName: likes > 0 ? "hand.thumbsup.fill" : "hand.thumbsup")
                Text("\(likes)")
            }
            .foregroundColor(likes > 0 ? Color(.systemGreen) : Color(.secondaryLabel))

            Rectangle()
                .fill(Color(.separator))
                .frame(width: 1, height: 12)

            HStack(spacing: 4) {
                Image(systemName: dislikes > 0 ? "hand.thumbsdown.fill" : "hand.thumbsdown")
                Text("\(dislikes)")
            }
            .foregroundColor(dislikes > 0 ? Color(.systemRed) : Color(.secondaryLabel))
        }
        .font(.footnote.weight(.semibold))
        .monospacedDigit()
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color(.tertiarySystemFill), in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Нравится: \(likes), не нравится: \(dislikes)")
    }
}

/// A stable per-author color for nicknames, derived from the IP hash so the
/// same person keeps the same color across threads.
enum AuthorColor {
    private static let palette: [Color] = [
        .blue, .green, .orange, .purple, .pink, .teal, .indigo, .red, .brown,
    ]

    static func color(for comment: Comment) -> Color {
        if comment.isBot == true { return .accentColor }
        let seed = comment.ipHash ?? comment.name ?? ""
        guard !seed.isEmpty else { return .primary }
        // djb2: stable across launches, unlike Hasher.
        var hash: UInt64 = 5381
        for byte in seed.utf8 { hash = (hash &* 33) &+ UInt64(byte) }
        return palette[Int(hash % UInt64(palette.count))]
    }
}

extension DateParsing {
    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.unitsStyle = .full
        return f
    }()

    private static let shortDate: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "d MMM yyyy"
        return f
    }()

    /// "5 минут назад" for the last week, a short date after that.
    static func relative(_ date: Date) -> String {
        let age = Date().timeIntervalSince(date)
        if age < 60 { return "только что" }
        if age < 7 * 24 * 3600 { return relativeFormatter.localizedString(for: date, relativeTo: Date()) }
        return shortDate.string(from: date)
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
