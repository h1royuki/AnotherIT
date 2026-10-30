import SwiftUI
import UIKit
import WebKit

@MainActor
final class ArticleModel: ObservableObject {
    @Published private(set) var article: Article?
    @Published var error: String?

    let path: String

    init(path: String) {
        self.path = path
    }

    func load() async {
        do {
            article = try await APIClient.shared.article(path: path)
            error = nil
        } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled { return }
            self.error = error.localizedDescription
        }
    }
}

/// The article followed by its comments on one page, as on vc.ru.
struct ArticleView: View {
    private static let commentsAnchor = "comments"

    let focusComments: Bool
    @StateObject private var model: ArticleModel
    @StateObject private var comments: CommentsModel
    @EnvironmentObject private var router: Router
    @ObservedObject private var seen = SeenComments.shared
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @State private var webHeight: CGFloat = 0
    @State private var highlighted: Int?
    @State private var viewerImage: ViewerImage?
    @State private var didFocus = false
    /// Whether the comments have been scrolled into view.
    @State private var inComments = false

    init(path: String, focusComments: Bool = false) {
        self.focusComments = focusComments
        _model = StateObject(wrappedValue: ArticleModel(path: path))
        _comments = StateObject(wrappedValue: CommentsModel(path: path))
    }

    var body: some View {
        Group {
            if let article = model.article {
                page(article)
            } else if let error = model.error {
                ErrorView(message: error) {
                    Task { await load() }
                }
            } else {
                ProgressView()
            }
        }
        .background(Color(.systemBackground))
        .navigationTitle("Статья")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .fullScreenCover(item: $viewerImage) { image in
            ImageViewer(url: image.url)
        }
        .task {
            if model.article == nil { await load() }
        }
        // Like the site, the visit is recorded when leaving the page.
        .onDisappear { comments.markAllSeen() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { comments.markAllSeen() }
        }
    }

    private func load() async {
        await model.load()
        guard let article = model.article else { return }
        comments.articleId = article.id
        await comments.load()
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if let article = model.article {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    ShareLink(item: SiteLinks.absolute(article.url)) {
                        Label("Поделиться", systemImage: "square.and.arrow.up")
                    }
                    Button {
                        UIPasteboard.general.url = SiteLinks.absolute(article.url)
                    } label: {
                        Label("Скопировать ссылку", systemImage: "link")
                    }
                    Button {
                        openURL(SiteLinks.absolute(article.url))
                    } label: {
                        Label("Открыть в Safari", systemImage: "safari")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
            }
        }
    }

    private func page(_ article: Article) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ArticleWebView(html: ArticleHTML.render(article), height: $webHeight) { url in
                        handleLink(url, article: article, proxy: proxy)
                    }
                    .frame(height: max(webHeight, 1))

                    if webHeight == 0 {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 40)
                    }

                    actionRow(article, proxy: proxy)

                    commentsHeader(article)
                        .id(Self.commentsAnchor)

                    commentsSection(proxy: proxy)
                }
                .padding(.bottom, 96)
            }
            .refreshable { await load() }
            .onScrollGeometryChange(for: Bool.self) { geometry in
                webHeight > 0 && geometry.contentOffset.y + geometry.containerSize.height > webHeight + 80
            } action: { _, reached in
                withAnimation(.easeInOut(duration: 0.2)) { inComments = reached }
            }
            .overlay(alignment: .bottom) {
                Group {
                    if !inComments {
                        commentsButton(article, proxy: proxy)
                    } else if comments.loaded, !comments.newIds.isEmpty {
                        newCommentsPill(proxy: proxy)
                    }
                }
                .padding(.bottom, 12)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            .environment(\.openURL, OpenURLAction { url in
                if url.scheme == CommentMarkdown.commentScheme, let id = Int(url.host ?? "") {
                    jump(to: id, proxy: proxy)
                    return .handled
                }
                return router.handle(url) ? .handled : .systemAction
            })
            .onChange(of: comments.loaded) { focusIfNeeded(proxy: proxy) }
            .onChange(of: webHeight) { focusIfNeeded(proxy: proxy) }
        }
    }

    /// Opening from a comments button lands on the comments, once the page
    /// has its height and the comments are in.
    private func focusIfNeeded(proxy: ScrollViewProxy) {
        guard focusComments, !didFocus, comments.loaded, webHeight > 0 else { return }
        didFocus = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            proxy.scrollTo(Self.commentsAnchor, anchor: .top)
        }
    }

    /// Counters under the article text: a comments pill and sharing.
    private func actionRow(_ article: Article, proxy: ScrollViewProxy) -> some View {
        let newComments = comments.loaded
            ? comments.newIds.count
            : seen.newCount(articleId: article.id, commentCount: article.commentCount)
        return HStack(spacing: 12) {
            Button {
                withAnimation { proxy.scrollTo(Self.commentsAnchor, anchor: .top) }
            } label: {
                CounterPill(systemImage: "bubble.left", count: article.commentCount ?? 0, extra: newComments)
            }
            .accessibilityLabel("Комментарии: \(article.commentCount ?? 0)")

            Spacer()

            ShareLink(item: SiteLinks.absolute(article.url)) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 20))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Поделиться")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    /// "Комментарии N" with the sort menu, as a section title.
    private func commentsHeader(_ article: Article) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("Комментарии")
                .font(.title2.weight(.bold))
            Text("\(comments.loaded ? comments.totalCount : article.commentCount ?? 0)")
                .font(.title2.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Spacer()
            Menu {
                Picker("Сортировка", selection: $comments.sort) {
                    ForEach(CommentSort.allCases) { sort in
                        Label(sort.rawValue, systemImage: sort.icon).tag(sort)
                    }
                }
                Divider()
                Button {
                    withAnimation { comments.collapseAll() }
                } label: {
                    Label("Свернуть все ветки", systemImage: "rectangle.compress.vertical")
                }
                Button {
                    withAnimation { comments.collapsed = [] }
                } label: {
                    Label("Развернуть все ветки", systemImage: "rectangle.expand.vertical")
                }
            } label: {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.accentColor)
                    .frame(width: 34, height: 34)
                    .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: 1.5))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Сортировка комментариев: \(comments.sort.rawValue)")
        }
        .padding(.horizontal, 16)
        .padding(.top, 24)
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private func commentsSection(proxy: ScrollViewProxy) -> some View {
        if !comments.loaded {
            if let error = comments.error {
                ErrorView(message: error) {
                    Task { await comments.load() }
                }
                .frame(maxWidth: .infinity)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 32)
            }
        } else if comments.threads.isEmpty {
            Text("Комментариев пока нет")
                .foregroundStyle(.secondary)
                .padding(16)
        } else {
            let firstId = comments.sortedThreads.first?.id
            ForEach(comments.sortedThreads) { thread in
                ForEach(comments.lines(for: thread)) { line in
                    CommentRow(line: line,
                               showsSeparator: line.id != firstId,
                               isCollapsed: comments.collapsed.contains(line.id),
                               isHighlighted: highlighted == line.id,
                               isNew: comments.newIds.contains(line.id),
                               newReplies: comments.newReplies[line.id] ?? 0,
                               commentURL: commentURL(line.id),
                               onToggle: { withAnimation(.easeInOut(duration: 0.25)) { comments.toggle(line.id) } },
                               onParent: { parent in jump(to: parent, proxy: proxy) },
                               onImage: { viewerImage = ViewerImage(url: $0) })
                        .id(line.id)
                }
            }
        }
    }

    /// Floating button that takes the reader straight to the comments.
    private func commentsButton(_ article: Article, proxy: ScrollViewProxy) -> some View {
        let newComments = comments.loaded
            ? comments.newIds.count
            : seen.newCount(articleId: article.id, commentCount: article.commentCount)
        return Button {
            withAnimation { proxy.scrollTo(Self.commentsAnchor, anchor: .top) }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "bubble.left")
                    .font(.system(size: 19, weight: .medium))
                Text("\(article.commentCount ?? 0)")
                    .monospacedDigit()
                if newComments > 0 {
                    Text("+\(newComments)")
                        .monospacedDigit()
                        .foregroundColor(.accentColor)
                }
            }
            .font(.body.weight(.semibold))
            .padding(.horizontal, 22)
            .frame(minHeight: 48)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .glassEffect(.regular.interactive(), in: .capsule)
        .accessibilityLabel("Перейти к комментариям: \(article.commentCount ?? 0)")
    }

    /// Floating Liquid Glass capsule: tap to step through new comments,
    /// the cross marks them all as read.
    private func newCommentsPill(proxy: ScrollViewProxy) -> some View {
        HStack(spacing: 0) {
            Button {
                if let id = comments.stepNew(by: 1) { jump(to: id, proxy: proxy) }
            } label: {
                Text(comments.remainingNew > 0
                     ? Plural.newComments(comments.remainingNew)
                     : "Все новые просмотрены")
                    .font(.body.weight(.semibold))
                    .monospacedDigit()
                    .padding(.leading, 20)
                    .padding(.trailing, 8)
                    .frame(minHeight: 48)
                    .contentShape(Rectangle())
            }
            .accessibilityHint("Перейти к следующему новому комментарию")

            Button {
                withAnimation { comments.markAllSeen(clearHighlights: true) }
            } label: {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 48)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Отметить все прочитанными")
            .padding(.trailing, 6)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .glassEffect(.regular.interactive(), in: .capsule)
    }

    private func commentURL(_ id: Int) -> URL {
        let base = SiteLinks.absolute(comments.path)
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
        components?.fragment = "comment-\(id)"
        return components?.url ?? base
    }

    private func jump(to id: Int, proxy: ScrollViewProxy) {
        guard comments.reveal(id) else { return }
        DispatchQueue.main.async {
            withAnimation { proxy.scrollTo(id, anchor: .center) }
            highlighted = id
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                if highlighted == id {
                    withAnimation { highlighted = nil }
                }
            }
        }
    }

    private func handleLink(_ url: URL, article: Article, proxy: ScrollViewProxy) {
        if url.scheme == ArticleHTML.scheme {
            switch url.host {
            case "comments":
                withAnimation { proxy.scrollTo(Self.commentsAnchor, anchor: .top) }
            case "tag":
                let slug = url.lastPathComponent
                let name = article.tags?.first(where: { $0.slug == slug })?.name ?? slug
                router.push(.tag(Tag(name: name, slug: slug, count: nil)))
            default:
                break
            }
            return
        }
        if !router.handle(url) {
            openURL(url)
        }
    }
}

struct ErrorView: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "wifi.exclamationmark")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Повторить", action: retry)
                .buttonStyle(.glassProminent)
        }
        .padding()
    }
}

/// Non-scrolling web view that reports its content height, so the article
/// text can sit inside the native scroll view above the comments.
struct ArticleWebView: UIViewRepresentable {
    let html: String
    @Binding var height: CGFloat
    let onLink: (URL) -> Void

    private static let heightScript = """
    (function () {
      function post() {
        window.webkit.messageHandlers.height.postMessage(
          Math.ceil(document.documentElement.getBoundingClientRect().height));
      }
      new ResizeObserver(post).observe(document.documentElement);
      document.querySelectorAll('img').forEach(function (img) { img.addEventListener('load', post); });
      window.addEventListener('load', post);
      post();
    })();
    """

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.dataDetectorTypes = [.link]
        let controller = config.userContentController
        controller.addUserScript(WKUserScript(source: Self.heightScript,
                                              injectionTime: .atDocumentEnd,
                                              forMainFrameOnly: true))
        controller.add(WeakScriptHandler(context.coordinator), name: "height")

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.allowsLinkPreview = false
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.onLink = onLink
        context.coordinator.onHeight = { value in
            if abs(value - height) > 0.5 { height = value }
        }
        if context.coordinator.loadedHTML != html {
            context.coordinator.loadedHTML = html
            webView.loadHTMLString(html, baseURL: APIClient.baseURL)
        }
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "height")
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var onLink: ((URL) -> Void)?
        var onHeight: ((CGFloat) -> Void)?
        var loadedHTML: String?

        func userContentController(_ userContentController: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard let value = message.body as? NSNumber else { return }
            onHeight?(CGFloat(truncating: value))
        }

        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.cancel)
                return
            }
            if navigationAction.navigationType == .linkActivated || url.scheme == ArticleHTML.scheme {
                // In-page anchors stay in the web view.
                if url.fragment != nil, ["", "/"].contains(url.path), url.host == APIClient.baseURL.host {
                    decisionHandler(.allow)
                    return
                }
                decisionHandler(.cancel)
                onLink?(url)
                return
            }
            decisionHandler(.allow)
        }
    }
}

/// Breaks the retain cycle between WKUserContentController and the coordinator.
private final class WeakScriptHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?

    init(_ target: WKScriptMessageHandler) {
        self.target = target
    }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        target?.userContentController(userContentController, didReceive: message)
    }
}

enum ArticleHTML {
    static let scheme = "anotherit-app"

    static func render(_ article: Article) -> String {
        let authorName = article.author?.name ?? "Другое IT"
        let authorSlug = article.author?.slug ?? authorName
        let isBot = authorSlug == "sitebot"
        let initial = isBot ? "✨" : escape(String(authorName.prefix(1)).uppercased())
        let avatarColor = AuthorColor.hex(seed: authorSlug, isBot: isBot)

        let date = article.publishedAt.map { escape(DateParsing.relative($0)) } ?? ""

        var header = """
        <header class="author">
        <div class="avatar" style="background-color: \(avatarColor)">\(initial)</div>
        <div><div class="name">\(escape(authorName))</div><div class="sub">\(date)</div></div>
        </header>
        <h1>\(escape(article.title))</h1>
        """
        if let tags = article.tags, !tags.isEmpty {
            let links = tags.map {
                "<a class=\"tag\" href=\"\(scheme)://tag/\(escape($0.slug))\">\(escape($0.name))</a>"
            }
            header += "<div class=\"tags\">\(links.joined())</div>"
        }
        if let excerpt = article.excerpt, !excerpt.isEmpty {
            header += "<p class=\"lead\">\(escape(excerpt))</p>"
        }
        if let image = article.featuredImageUrl {
            header += "<img class=\"cover\" src=\"\(escape(image))\" alt=\"\">"
        }

        let pollNote = "<div class=\"note\">Здесь на сайте встроен интерактивный опрос — "
            + "<a href=\"\(escape(SiteLinks.absolute(article.url).absoluteString))\">открыть в браузере</a>.</div>"
        let content = (article.contentHtml ?? "")
            .replacingOccurrences(of: "<div data-poll-slot></div>", with: pollNote)

        return """
        <!DOCTYPE html>
        <html lang="ru">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no">
        <style>\(css)</style>
        </head>
        <body>
        <article>
        \(header)
        <div class="content">\(content)</div>
        </article>
        </body>
        </html>
        """
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// Dark-first reading layout: full-bleed media, chip tags, system colors.
    private static let css = """
    :root { color-scheme: light dark; --text: #000; --accent: #ce2956; --muted: #8a8a8e; --border: rgba(127,127,127,.25); --fill: rgba(118,118,128,.12); }
    @media (prefers-color-scheme: dark) { :root { --text: #fff; --accent: #ff4f7b; --muted: #98989f; --fill: rgba(118,118,128,.24); } }
    html { -webkit-text-size-adjust: 100%; background: transparent; }
    body { margin: 0; padding: 12px 16px 4px; background: transparent; color: var(--text); font-family: -apple-system, system-ui, sans-serif; font-size: 17px; line-height: 1.5; word-wrap: break-word; -webkit-tap-highlight-color: transparent; overflow-x: hidden; }
    a { color: var(--accent); text-decoration: none; }
    .author { display: flex; align-items: center; gap: 12px; margin: 0 0 14px; }
    .avatar { flex: none; width: 44px; height: 44px; border-radius: 50%; color: #fff; font: 600 18px/44px ui-rounded, -apple-system, sans-serif; text-align: center; background-image: linear-gradient(rgba(255,255,255,.22), rgba(255,255,255,0)); }
    .name { font-size: 17px; font-weight: 600; line-height: 1.3; }
    .sub { font-size: 15px; line-height: 1.35; color: var(--muted); }
    h1 { font-size: 24px; line-height: 1.25; font-weight: 700; letter-spacing: -0.01em; margin: 0 0 12px; }
    .tags { display: flex; gap: 8px; overflow-x: auto; margin: 0 -16px 14px; padding: 0 16px; scrollbar-width: none; }
    .tags::-webkit-scrollbar { display: none; }
    .tag { flex: none; padding: 6px 14px; border-radius: 999px; background: var(--fill); color: var(--text); font-size: 15px; font-weight: 500; white-space: nowrap; }
    .lead { font-size: 17px; line-height: 1.45; margin: 0 0 14px; }
    .cover, .content img, .content video, .content iframe { display: block; width: calc(100% + 32px); max-width: none; height: auto; margin: 12px -16px; border-radius: 0; }
    .content { margin-top: 16px; }
    .content > :first-child { margin-top: 0; }
    p { margin: 0 0 14px; }
    h2 { font-size: 21px; line-height: 1.3; margin: 28px 0 10px; }
    h3, h4 { font-size: 19px; line-height: 1.3; margin: 24px 0 8px; }
    strong, b { font-weight: 600; }
    ul, ol { padding-left: 24px; margin: 0 0 14px; }
    li { margin-bottom: 8px; }
    li::marker { color: var(--muted); }
    figure { margin: 20px 0; }
    figcaption { color: var(--muted); font-size: 15px; margin-top: 8px; }
    blockquote { margin: 18px 0; padding: 2px 0 2px 14px; border-left: 3px solid var(--accent); }
    pre { background: var(--fill); padding: 14px; border-radius: 12px; overflow-x: auto; font-size: 14px; line-height: 1.45; }
    code { font-family: ui-monospace, Menlo, monospace; font-size: 0.88em; background: var(--fill); padding: 2px 5px; border-radius: 5px; }
    pre code { background: none; padding: 0; }
    table { border-collapse: collapse; display: block; overflow-x: auto; font-size: 15px; }
    th, td { border: 1px solid var(--border); padding: 6px 8px; }
    hr { border: none; border-top: 1px solid var(--border); margin: 28px 0; }
    .note { margin: 16px 0; padding: 14px 16px; border-radius: 14px; background: var(--fill); font-size: 16px; }
    """
}
