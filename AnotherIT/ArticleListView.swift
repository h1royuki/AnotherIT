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

struct ArticleListView: View {
    @StateObject private var model: ArticleListModel
    @EnvironmentObject private var router: Router

    init(tag: Tag?) {
        _model = StateObject(wrappedValue: ArticleListModel(tag: tag))
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
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
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(model.tag.map { "#\($0.name)" } ?? "Другое IT")
        .toolbar {
            if model.tag == nil, !model.tags.isEmpty {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        ForEach(model.tags) { tag in
                            Button {
                                router.push(.tag(tag))
                            } label: {
                                Text(tag.count.map { "\(tag.name) (\($0))" } ?? tag.name)
                            }
                        }
                    } label: {
                        Image(systemName: "number")
                    }
                    .accessibilityLabel("Теги")
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
                    .buttonStyle(.bordered)
                }
            } else {
                ProgressView()
                    .onAppear {
                        if !model.articles.isEmpty { Task { await model.loadNext() } }
                    }
            }
            Spacer()
        }
        .padding(.vertical, 16)
    }
}

enum FeedStyle {
    static let cornerRadius: CGFloat = 24
    static let cardBackground = Color(.secondarySystemGroupedBackground)
}

/// Pinned articles are kept compact: one card with just their titles.
struct PinnedCard: View {
    let articles: [ArticleSummary]
    @EnvironmentObject private var router: Router

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Label("Закреплённое", systemImage: "pin.fill")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.bottom, 4)

            ForEach(articles) { article in
                Button {
                    router.push(.article(path: article.url))
                } label: {
                    HStack(spacing: 12) {
                        Text(article.title)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 12)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if article.id != articles.last?.id {
                    Divider()
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 4)
        .background(FeedStyle.cardBackground,
                    in: RoundedRectangle(cornerRadius: FeedStyle.cornerRadius, style: .continuous))
    }
}

struct ArticleCard: View {
    let article: ArticleSummary
    @EnvironmentObject private var router: Router

    private var authorName: String { article.author?.name ?? "Другое IT" }
    private var authorSlug: String { article.author?.slug ?? authorName }
    private var isBot: Bool { authorSlug == "sitebot" }
    private var link: URL { SiteLinks.absolute(article.url) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            Text(article.title)
                .font(.title2.weight(.bold))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

            if let excerpt = article.excerpt, !excerpt.isEmpty {
                Text(excerpt)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .lineSpacing(2)
                    .lineLimit(5)
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
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .padding(.top, 2)
            }

            actions
        }
        .padding(16)
        .background(FeedStyle.cardBackground,
                    in: RoundedRectangle(cornerRadius: FeedStyle.cornerRadius, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: FeedStyle.cornerRadius, style: .continuous))
        .onTapGesture {
            router.push(.article(path: article.url))
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            AvatarView(name: authorName, color: AuthorColor.color(seed: authorSlug, isBot: isBot),
                       isAnonymous: false, isBot: isBot, size: 40)

            VStack(alignment: .leading, spacing: 1) {
                Text(authorName)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                HStack(spacing: 6) {
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
                    router.push(.comments(path: article.url, title: article.title))
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
                    .frame(width: 40, height: 40)
                    .contentShape(Rectangle())
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 28) {
            Button {
                router.push(.comments(path: article.url, title: article.title))
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "bubble.left")
                    Text("\(article.commentCount ?? 0)").monospacedDigit()
                }
                .frame(minHeight: 36)
                .contentShape(Rectangle())
            }
            .accessibilityLabel("Комментарии: \(article.commentCount ?? 0)")

            ShareLink(item: link) {
                Image(systemName: "arrowshape.turn.up.right")
                    .frame(minHeight: 36)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Поделиться")

            Spacer()
        }
        .buttonStyle(.plain)
        .font(.title3)
        .foregroundStyle(.primary)
    }
}
