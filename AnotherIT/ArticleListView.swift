import SwiftUI

@MainActor
final class ArticleListModel: ObservableObject {
    @Published private(set) var articles: [ArticleSummary] = []
    @Published private(set) var tags: [Tag] = []
    @Published private(set) var isLoading = false
    @Published var error: String?

    let tag: Tag?
    private var currentPage = 0
    private var lastPage = 1

    init(tag: Tag?) {
        self.tag = tag
    }

    var canLoadMore: Bool { currentPage < lastPage }

    func reload() async {
        guard !isLoading else { return }
        currentPage = 0
        lastPage = 1
        await loadNext(replacing: true)
    }

    func loadNext(replacing: Bool = false) async {
        guard !isLoading, replacing || canLoadMore else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let page = try await APIClient.shared.articles(page: currentPage + 1, tag: tag?.slug)
            let paginator = page.props.articles
            currentPage = paginator.currentPage
            lastPage = paginator.lastPage
            if replacing {
                articles = paginator.data
            } else {
                let known = Set(articles.map(\.id))
                articles += paginator.data.filter { !known.contains($0.id) }
            }
            if !page.props.allTags.isEmpty {
                tags = page.props.allTags.sorted { ($0.count ?? 0) > ($1.count ?? 0) }
            }
            error = nil
        } catch is CancellationError {
        } catch {
            if (error as? URLError)?.code == .cancelled { return }
            self.error = error.localizedDescription
        }
    }
}

/// Feed metrics, taken from vc.ru's feed.
enum FeedLayout {
    static let margin: CGFloat = 8
    static let cardSpacing: CGFloat = 8
    static let cornerRadius: CGFloat = 22
    static let padding: CGFloat = 16
    static let avatarSize: CGFloat = 40
    static let cardBackground = Color(.secondarySystemGroupedBackground)
}

struct ArticleListView: View {
    private static let topAnchor = "top"

    @StateObject private var model: ArticleListModel
    @EnvironmentObject private var router: Router

    init(tag: Tag?) {
        _model = StateObject(wrappedValue: ArticleListModel(tag: tag))
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: FeedLayout.cardSpacing) {
                    Color.clear.frame(height: 0).id(Self.topAnchor)

                    let pinned = model.articles.filter { $0.isPinned == true }
                    if !pinned.isEmpty {
                        PinnedCard(articles: pinned)
                    }

                    ForEach(model.articles.filter { $0.isPinned != true }) { article in
                        ArticleCard(article: article)
                            .onAppear {
                                if article.id == model.articles.last?.id {
                                    Task { await model.loadNext() }
                                }
                            }
                    }

                    if model.isLoading || model.canLoadMore || model.error != nil {
                        footer
                    }
                }
                .padding(.horizontal, FeedLayout.margin)
                .padding(.vertical, 8)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle(model.tag.map { "#\($0.name)" } ?? "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if model.tag == nil {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            withAnimation { proxy.scrollTo(Self.topAnchor, anchor: .top) }
                        } label: {
                            Text("Другое IT")
                                .font(.headline)
                                .padding(.horizontal, 6)
                        }
                        .accessibilityHint("Прокрутить ленту наверх")
                    }
                }
            }
        }
        .refreshable { await model.reload() }
        .task {
            if model.articles.isEmpty { await model.reload() }
        }
    }

    @ViewBuilder
    private var footer: some View {
        HStack {
            Spacer()
            if let error = model.error {
                VStack(spacing: 8) {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Повторить") {
                        Task {
                            if model.articles.isEmpty { await model.reload() } else { await model.loadNext() }
                        }
                    }
                    .buttonStyle(.glass)
                }
            } else {
                ProgressView()
                    .onAppear {
                        if !model.articles.isEmpty { Task { await model.loadNext() } }
                    }
            }
            Spacer()
        }
        .padding(.vertical, 24)
    }
}

/// Pinned articles are kept compact, like vc.ru's digest card: titles with
/// their comment counts, the rest behind "Показать ещё".
struct PinnedCard: View {
    private static let collapsedCount = 3

    let articles: [ArticleSummary]
    @EnvironmentObject private var router: Router
    @ObservedObject private var seen = SeenComments.shared
    @State private var expanded = false

    private var shown: [ArticleSummary] {
        expanded ? articles : Array(articles.prefix(Self.collapsedCount))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Закреплённое", systemImage: "pin.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            ForEach(shown) { article in
                Button {
                    router.push(.article(path: article.url))
                } label: {
                    title(article)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            if articles.count > Self.collapsedCount {
                Button {
                    withAnimation(.easeInOut(duration: 0.25)) { expanded.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Text(expanded ? "Свернуть" : "Показать ещё")
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .font(.subheadline.weight(.semibold))
                    }
                    .font(.body.weight(.medium))
                    .frame(minHeight: 32)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(FeedLayout.padding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(FeedLayout.cardBackground,
                    in: RoundedRectangle(cornerRadius: FeedLayout.cornerRadius, style: .continuous))
    }

    private func title(_ article: ArticleSummary) -> Text {
        let newComments = seen.newCount(articleId: article.id, commentCount: article.commentCount)
        let title = Text(article.title)
            .font(.body.weight(.medium))
            .foregroundColor(.primary)
        let icon = Text(Image(systemName: "bubble.left"))
            .font(.subheadline)
            .foregroundColor(.secondary)
        let count = Text(" \(article.commentCount ?? 0)")
            .font(.subheadline)
            .foregroundColor(.secondary)
        var text = title + Text("  ") + icon + count
        if newComments > 0 {
            let badge = Text(" +\(newComments)")
                .font(.subheadline.weight(.semibold))
                .foregroundColor(.accentColor)
            text = text + badge
        }
        return text
    }
}

struct ArticleCard: View {
    let article: ArticleSummary
    @EnvironmentObject private var router: Router
    @ObservedObject private var seen = SeenComments.shared

    private var authorName: String { article.author?.name ?? "Другое IT" }
    private var authorSlug: String { article.author?.slug ?? authorName }
    private var isBot: Bool { authorSlug == "sitebot" }
    private var link: URL { SiteLinks.absolute(article.url) }
    private var newComments: Int { seen.newCount(articleId: article.id, commentCount: article.commentCount) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.bottom, 14)

            Text(article.title)
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 10)

            if let excerpt = article.excerpt, !excerpt.isEmpty {
                Text(excerpt)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .lineSpacing(3)
                    .lineLimit(4)
                    .padding(.bottom, 12)
            }

            if let image = article.featuredImageUrl, let url = URL(string: image) {
                Color.clear
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .overlay(
                        AsyncImage(url: url) { phase in
                            if let image = phase.image {
                                image.resizable().scaledToFill()
                            } else {
                                Color(.tertiarySystemFill)
                            }
                        }
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .padding(.top, 2)
                    .padding(.bottom, 8)
            }

            actions
        }
        .padding(.horizontal, FeedLayout.padding)
        .padding(.top, FeedLayout.padding)
        .padding(.bottom, 6)
        .background(FeedLayout.cardBackground,
                    in: RoundedRectangle(cornerRadius: FeedLayout.cornerRadius, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: FeedLayout.cornerRadius, style: .continuous))
        .onTapGesture {
            router.push(.article(path: article.url))
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            AvatarView(name: authorName, color: AuthorColor.color(seed: authorSlug, isBot: isBot),
                       isAnonymous: false, isBot: isBot, size: FeedLayout.avatarSize)

            VStack(alignment: .leading, spacing: 2) {
                Text(authorName)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    if let tag = article.tags?.first {
                        Button {
                            router.push(.tag(tag))
                        } label: {
                            Text(tag.name).lineLimit(1)
                        }
                        .buttonStyle(.plain)
                    }
                    if let date = article.publishedAt {
                        Text(DateParsing.short(date))
                    }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Menu {
                ShareLink(item: link) {
                    Label("Поделиться", systemImage: "square.and.arrow.up")
                }
                Button {
                    router.push(.comments(path: article.url))
                } label: {
                    Label("Комментарии", systemImage: "bubble.left")
                }
                if let tags = article.tags, !tags.isEmpty {
                    Section("Теги") {
                        ForEach(tags) { tag in
                            Button("#\(tag.name)") { router.push(.tag(tag)) }
                        }
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .padding(.trailing, -10)
        }
    }

    private var actions: some View {
        HStack(spacing: 26) {
            Button {
                router.push(.comments(path: article.url))
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "bubble.left")
                        .font(.system(size: 20))
                    Text("\(article.commentCount ?? 0)").monospacedDigit()
                    if newComments > 0 {
                        Text("+\(newComments)")
                            .monospacedDigit()
                            .foregroundColor(.accentColor)
                    }
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .accessibilityLabel("Комментарии: \(article.commentCount ?? 0)")

            ShareLink(item: link) {
                Image(systemName: "arrowshape.turn.up.right")
                    .font(.system(size: 20))
                    .frame(minWidth: 32, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Поделиться")

            Spacer()
        }
        .buttonStyle(.plain)
        .font(.body)
        .foregroundStyle(.primary)
    }
}

/// All site tags, most used first, with search.
struct TagsView: View {
    @EnvironmentObject private var router: Router
    @State private var tags: [Tag] = []
    @State private var query = ""
    @State private var error: String?

    private var filtered: [Tag] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return tags }
        return tags.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        Group {
            if tags.isEmpty, let error {
                ErrorView(message: error) {
                    Task { await load() }
                }
            } else if tags.isEmpty {
                ProgressView()
            } else {
                List(filtered) { tag in
                    Button {
                        router.push(.tag(tag))
                    } label: {
                        HStack {
                            Text("#\(tag.name)")
                                .foregroundStyle(.primary)
                            Spacer()
                            if let count = tag.count {
                                Text("\(count)")
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.insetGrouped)
                .searchable(text: $query, prompt: "Поиск тегов")
            }
        }
        .navigationTitle("Теги")
        .task {
            if tags.isEmpty { await load() }
        }
        .refreshable { await load() }
    }

    private func load() async {
        do {
            let page = try await APIClient.shared.articles(page: 1, tag: nil)
            tags = page.props.allTags.sorted { ($0.count ?? 0) > ($1.count ?? 0) }
            error = nil
        } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled { return }
            self.error = error.localizedDescription
        }
    }
}
