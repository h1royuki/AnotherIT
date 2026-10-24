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
        List {
            ForEach(model.articles) { article in
                Button {
                    router.push(.article(path: article.url))
                } label: {
                    ArticleRow(article: article)
                }
                .buttonStyle(.plain)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                .onAppear {
                    if article.id == model.articles.last?.id {
                        Task { await model.loadNext() }
                    }
                }
            }

            if model.isLoading || model.canLoadMore || model.error != nil {
                footer
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
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
                        Image(systemName: "tag")
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

struct ArticleRow: View {
    let article: ArticleSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let image = article.featuredImageUrl, let url = URL(string: image) {
                Color.clear
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .overlay(
                        AsyncImage(url: url) { phase in
                            if let image = phase.image {
                                image.resizable().scaledToFill()
                            } else {
                                Color.secondary.opacity(0.12)
                            }
                        }
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if article.isPinned == true {
                    Image(systemName: "pin.fill")
                        .font(.footnote)
                        .foregroundColor(.accentColor)
                }
                Text(article.title)
                    .font(.title3.weight(.semibold))
                    .foregroundColor(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let excerpt = article.excerpt, !excerpt.isEmpty {
                Text(excerpt)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
            }

            HStack(spacing: 12) {
                if let date = article.publishedAt {
                    Text(DateParsing.display.string(from: date))
                }
                if let author = article.author?.name {
                    Text(author).lineLimit(1)
                }
                Spacer()
                Label("\(article.commentCount ?? 0)", systemImage: "bubble.left")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if let tags = article.tags, !tags.isEmpty {
                Text(tags.map { "#\($0.name)" }.joined(separator: "  "))
                    .font(.caption)
                    .foregroundColor(.accentColor)
                    .lineLimit(1)
            }

            Divider().padding(.top, 6)
        }
        .contentShape(Rectangle())
    }
}
