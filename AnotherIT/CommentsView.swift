import SwiftUI

struct FlatComment: Identifiable {
    let comment: Comment
    let depth: Int
    let parentName: String?
    let descendants: Int
    let blocks: [MessageBlock]

    var id: Int { comment.id }
    var authorName: String { CommentsModel.displayName(comment) }
}

@MainActor
final class CommentsModel: ObservableObject {
    @Published private(set) var all: [FlatComment] = []
    @Published private(set) var loaded = false
    @Published var collapsed: Set<Int> = []
    @Published var error: String?

    let path: String

    init(path: String) {
        self.path = path
    }

    /// Comments in thread order, without the replies of collapsed comments.
    var visible: [FlatComment] {
        guard !collapsed.isEmpty else { return all }
        var result: [FlatComment] = []
        var skipDeeperThan: Int?
        for item in all {
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
            all = await Task.detached(priority: .userInitiated) { CommentsModel.flatten(tree) }.value
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

    /// Expands every collapsed ancestor so the comment becomes visible.
    func reveal(_ id: Int) -> Bool {
        guard let index = all.firstIndex(where: { $0.id == id }) else { return false }
        var depth = all[index].depth
        var i = index
        while depth > 0, i > 0 {
            i -= 1
            if all[i].depth < depth {
                collapsed.remove(all[i].id)
                depth = all[i].depth
            }
        }
        return true
    }

    nonisolated static func displayName(_ comment: Comment) -> String {
        if let name = comment.name?.trimmingCharacters(in: .whitespaces), !name.isEmpty { return name }
        return "Аноним"
    }

    nonisolated private static func flatten(_ tree: [Comment]) -> [FlatComment] {
        var result: [FlatComment] = []
        func walk(_ comments: [Comment], depth: Int, parentName: String?) -> Int {
            var count = 0
            for comment in comments {
                let index = result.count
                result.append(FlatComment(comment: comment, depth: depth, parentName: parentName,
                                          descendants: 0, blocks: []))
                let children = walk(comment.children ?? [], depth: depth + 1,
                                    parentName: displayName(comment))
                result[index] = FlatComment(comment: comment, depth: depth, parentName: parentName,
                                            descendants: children,
                                            blocks: CommentMarkdown.blocks(from: comment.message ?? ""))
                count += 1 + children
            }
            return count
        }
        _ = walk(tree, depth: 0, parentName: nil)
        return result
    }
}

struct CommentsView: View {
    let title: String
    @StateObject private var model: CommentsModel
    @EnvironmentObject private var router: Router
    @State private var highlighted: Int?
    @State private var viewerImage: ViewerImage?

    init(path: String, title: String) {
        self.title = title
        _model = StateObject(wrappedValue: CommentsModel(path: path))
    }

    var body: some View {
        ScrollViewReader { proxy in
            Group {
                if model.loaded {
                    list(proxy: proxy)
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
            if model.loaded, !model.all.isEmpty {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button("Свернуть все ветки") {
                            model.collapsed = Set(model.all.filter { $0.depth == 0 && $0.descendants > 0 }.map(\.id))
                        }
                        Button("Развернуть все") {
                            model.collapsed = []
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

    @ViewBuilder
    private func list(proxy: ScrollViewProxy) -> some View {
        List {
            Section {
                Text(title)
                    .font(.headline)
                    .listRowSeparator(.hidden)
                Text(countText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if model.all.isEmpty {
                Text("Комментариев пока нет")
                    .foregroundStyle(.secondary)
            }

            ForEach(model.visible) { item in
                CommentRow(item: item,
                           isCollapsed: model.collapsed.contains(item.id),
                           isHighlighted: highlighted == item.id,
                           onToggle: { withAnimation(.easeInOut(duration: 0.2)) { model.toggle(item.id) } },
                           onImage: { viewerImage = ViewerImage(url: $0) })
                    .id(item.id)
                    .listRowInsets(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 16))
            }
        }
        .listStyle(.plain)
        .refreshable { await model.load() }
    }

    private var countText: String {
        let n = model.all.count
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
    let isHighlighted: Bool
    let onToggle: () -> Void
    let onImage: (URL) -> Void

    private static let maxIndent = 6
    private var comment: Comment { item.comment }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(0..<min(item.depth, Self.maxIndent), id: \.self) { _ in
                Rectangle()
                    .fill(Color.secondary.opacity(0.25))
                    .frame(width: 1)
                    .padding(.trailing, 9)
            }

            VStack(alignment: .leading, spacing: 6) {
                header

                if item.depth > Self.maxIndent, let parent = item.parentName {
                    Label(parent, systemImage: "arrowshape.turn.up.left")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if isCollapsed {
                    Text("Ветка свёрнута · ответов: \(item.descendants)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    if comment.hidden == true {
                        Text(comment.message ?? "Комментарий скрыт")
                            .font(.callout.italic())
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
        }
        .padding(.vertical, 2)
        .listRowBackground(isHighlighted ? Color.accentColor.opacity(0.12) : Color.clear)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text(item.authorName)
                .font(.subheadline.weight(.semibold))
                .foregroundColor(comment.isBot == true ? .accentColor : .primary)
                .lineLimit(1)
            if comment.isBot == true {
                Text("Бот")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.accentColor.opacity(0.15))
                    .clipShape(Capsule())
            }
            if let hash = comment.ipHash, !hash.isEmpty {
                Text("#\(hash)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 4)
            if let date = comment.createdAt {
                Text(DateParsing.displayWithTime.string(from: date))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if item.descendants > 0 { onToggle() }
        }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Label("\(comment.likesCount ?? 0)", systemImage: "hand.thumbsup")
            Label("\(comment.dislikesCount ?? 0)", systemImage: "hand.thumbsdown")
            Spacer()
            if item.descendants > 0 {
                Button(action: onToggle) {
                    Label("Свернуть (\(item.descendants))", systemImage: "chevron.up")
                }
                .buttonStyle(.borderless)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.top, 2)
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
                                    Color.secondary.opacity(0.12)
                                }
                            }
                            .frame(width: 120, height: 120)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
        }
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
