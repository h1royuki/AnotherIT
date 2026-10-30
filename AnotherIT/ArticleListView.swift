import SwiftUI
import UIKit

@MainActor
final class ArticleListModel: ObservableObject {
    @Published private(set) var articles: [ArticleSummary] = []
    @Published private(set) var tags: [Tag] = []
    @Published private(set) var isLoading = false
    @Published var error: String?

    @Published private(set) var tag: Tag?
    private var currentPage = 0
    private var lastPage = 1
    /// Bumped on every feed switch so late responses for the old feed are dropped.
    private var generation = 0

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

    /// Switches the feed in place to a tag (or back to all articles).
    func select(_ newTag: Tag?) async {
        guard newTag?.slug != tag?.slug else { return }
        generation += 1
        tag = newTag
        articles = []
        currentPage = 0
        lastPage = 1
        error = nil
        isLoading = false
        await loadNext(replacing: true)
    }

    func loadNext(replacing: Bool = false) async {
        guard !isLoading, replacing || canLoadMore else { return }
        isLoading = true
        let requested = generation
        defer { if requested == generation { isLoading = false } }
        do {
            let page = try await APIClient.shared.articles(page: currentPage + 1, tag: tag?.slug)
            guard requested == generation else { return }
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
            if (error as? URLError)?.code == .cancelled || requested != generation { return }
            self.error = error.localizedDescription
        }
    }
}

/// Feed metrics: full-bleed posts on a plain background.
enum FeedLayout {
    static let padding: CGFloat = 16
    static let avatarSize: CGFloat = 36
    static let chipBackground = Color(.secondarySystemBackground)
}

struct ArticleListView: View {
    /// The root feed switches tags in place; pushed tag pages are fixed.
    private let isHome: Bool
    @StateObject private var model: ArticleListModel
    @EnvironmentObject private var router: Router

    init(tag: Tag?) {
        isHome = tag == nil
        _model = StateObject(wrappedValue: ArticleListModel(tag: tag))
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if isHome {
                    homeHeader
                }

                let pinned = model.articles.filter { $0.isPinned == true }
                if !pinned.isEmpty {
                    PinnedCard(articles: pinned)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                }

                ForEach(model.articles.filter { $0.isPinned != true }) { article in
                    FeedPost(article: article)
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
            .padding(.bottom, 8)
        }
        .background(Color(.systemBackground))
        .navigationTitle(isHome ? "" : model.tag.map { "#\($0.name)" } ?? "")
        .navigationBarTitleDisplayMode(.inline)
        // The home header scrolls with the feed instead of occupying a bar.
        .toolbar(isHome ? .hidden : .automatic, for: .navigationBar)
        // Without a bar the feed would run straight into the status bar.
        .overlay(alignment: .top) {
            if isHome { StatusBarBlur() }
        }
        .refreshable { await model.reload() }
        .task {
            if model.articles.isEmpty { await model.reload() }
        }
    }

    /// Wordmark and the feed picker (all articles or a tag).
    private var homeHeader: some View {
        HStack(spacing: 12) {
            Wordmark()
            Spacer(minLength: 8)
            Menu {
                Button {
                    Task { await model.select(nil) }
                } label: {
                    if model.tag == nil {
                        Label("Все статьи", systemImage: "checkmark")
                    } else {
                        Text("Все статьи")
                    }
                }
                Section("Теги") {
                    ForEach(model.tags) { tag in
                        Button {
                            Task { await model.select(tag) }
                        } label: {
                            let title = tag.count.map { "\(tag.name) (\($0))" } ?? tag.name
                            if model.tag?.slug == tag.slug {
                                Label(title, systemImage: "checkmark")
                            } else {
                                Text(title)
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(model.tag?.name ?? "Все статьи")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                }
                .foregroundStyle(.primary)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
        }
        .padding(.horizontal, FeedLayout.padding)
        .padding(.vertical, 2)
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

/// Pinned articles are kept compact: titles with their comment counts, the
/// rest behind "Показать ещё".
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
        VStack(alignment: .leading, spacing: 10) {
            Label("Закреплённое", systemImage: "pin.fill")
                .font(.footnote.weight(.semibold))
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
                    .font(.subheadline.weight(.medium))
                    .frame(minHeight: 28)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(FeedLayout.chipBackground,
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func title(_ article: ArticleSummary) -> Text {
        let newComments = seen.newCount(articleId: article.id, commentCount: article.commentCount)
        let title = Text(article.title)
            .font(.subheadline.weight(.medium))
            .foregroundColor(.primary)
        let icon = Text(Image(systemName: "bubble.left"))
            .font(.footnote)
            .foregroundColor(.secondary)
        let count = Text(" \(article.commentCount ?? 0)")
            .font(.footnote)
            .foregroundColor(.secondary)
        var text = title + Text("  ") + icon + count
        if newComments > 0 {
            let badge = Text(" +\(newComments)")
                .font(.footnote.weight(.semibold))
                .foregroundColor(.accentColor)
            text = text + badge
        }
        return text
    }
}

/// One post in the feed: author header, title, tag chips, full-bleed cover
/// and a counters row.
struct FeedPost: View {
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
                .padding(.horizontal, FeedLayout.padding)
                .padding(.bottom, 10)

            Text(article.title)
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, FeedLayout.padding)
                .padding(.bottom, 10)

            if let excerpt = article.excerpt, !excerpt.isEmpty {
                Text(excerpt)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .lineSpacing(1)
                    .lineLimit(4)
                    .padding(.horizontal, FeedLayout.padding)
                    .padding(.bottom, 8)
            }

            if let tags = article.tags, !tags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(tags) { tag in
                            Button {
                                router.push(.tag(tag))
                            } label: {
                                Text(tag.name)
                                    .font(.footnote.weight(.medium))
                                    .foregroundStyle(.primary)
                                    .padding(.horizontal, 11)
                                    .frame(height: 26)
                                    .background(FeedLayout.chipBackground, in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, FeedLayout.padding)
                }
                .padding(.bottom, 10)
            }

            if let image = article.featuredImageUrl, let url = URL(string: image) {
                Color.clear
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .overlay(
                        AsyncImage(url: url) { phase in
                            if let image = phase.image {
                                image.resizable().scaledToFill()
                            } else {
                                Color(.secondarySystemBackground)
                            }
                        }
                    )
                    .clipped()
                    .padding(.bottom, 8)
            }

            actions
                .padding(.horizontal, FeedLayout.padding)
        }
        .padding(.top, 12)
        .padding(.bottom, 14)
        .contentShape(Rectangle())
        .onTapGesture {
            router.push(.article(path: article.url))
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            AvatarView(name: authorName, color: AuthorColor.color(seed: authorSlug, isBot: isBot),
                       isAnonymous: false, isBot: isBot, size: FeedLayout.avatarSize)

            VStack(alignment: .leading, spacing: 1) {
                Text(authorName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if let date = article.publishedAt {
                    Text(DateParsing.relative(date))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 8)

            Menu {
                ShareLink(item: link) {
                    Label("Поделиться", systemImage: "square.and.arrow.up")
                }
                Button {
                    UIPasteboard.general.url = link
                } label: {
                    Label("Скопировать ссылку", systemImage: "link")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 40, height: 40)
                    .contentShape(Rectangle())
            }
            .padding(.trailing, -10)
        }
    }

    private var actions: some View {
        HStack(spacing: 12) {
            Button {
                router.push(.comments(path: article.url))
            } label: {
                CounterPill(systemImage: "bubble.left", count: article.commentCount ?? 0, extra: newComments)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Комментарии: \(article.commentCount ?? 0)")

            Spacer()

            ShareLink(item: link) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 17))
                    .foregroundStyle(.primary)
                    .frame(width: 40, height: 40)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Поделиться")
        }
    }
}

/// The app's wordmark, matching the icon: a light "another" and a heavy
/// red "IT".
struct Wordmark: View {
    var body: some View {
        (Text("another").font(.system(size: 20, weight: .semibold))
            + Text("IT").font(.system(size: 20, weight: .black)).foregroundColor(.accentColor))
            .kerning(-0.3)
            .accessibilityLabel("AnotherIT")
    }
}

/// A soft blur under the status bar that fades out below it, like the
/// system's scroll edge effect under a navigation bar.
struct StatusBarBlur: View {
    var body: some View {
        Rectangle()
            .fill(.ultraThinMaterial)
            .frame(height: 24)
            // Grows up through the status bar, so the height is inset + 24.
            .ignoresSafeArea(edges: .top)
            .mask {
                LinearGradient(stops: [.init(color: .black, location: 0),
                                       .init(color: .black, location: 0.55),
                                       .init(color: .clear, location: 1)],
                               startPoint: .top, endPoint: .bottom)
            }
            .allowsHitTesting(false)
    }
}
