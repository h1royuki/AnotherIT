import SwiftUI
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

struct ArticleView: View {
    @StateObject private var model: ArticleModel
    @EnvironmentObject private var router: Router
    @Environment(\.openURL) private var openURL

    init(path: String) {
        _model = StateObject(wrappedValue: ArticleModel(path: path))
    }

    var body: some View {
        Group {
            if let article = model.article {
                ArticleWebView(html: ArticleHTML.render(article)) { url in
                    handleLink(url, article: article)
                }
                .ignoresSafeArea(edges: .bottom)
            } else if let error = model.error {
                ErrorView(message: error) {
                    Task { await model.load() }
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle(model.article?.title ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let article = model.article {
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    ShareLink(item: SiteLinks.absolute(article.url))
                    Button {
                        openComments(article)
                    } label: {
                        Label("\(article.commentCount ?? 0)", systemImage: "bubble.left.and.bubble.right")
                            .labelStyle(.titleAndIcon)
                    }
                    .accessibilityLabel("Комментарии")
                }
            }
        }
        .task {
            if model.article == nil { await model.load() }
        }
    }

    private func openComments(_ article: Article) {
        router.push(.comments(path: article.url, title: article.title))
    }

    private func handleLink(_ url: URL, article: Article) {
        if url.scheme == ArticleHTML.scheme {
            switch url.host {
            case "comments":
                openComments(article)
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
                .buttonStyle(.borderedProminent)
        }
        .padding()
    }
}

struct ArticleWebView: UIViewRepresentable {
    let html: String
    let onLink: (URL) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.dataDetectorTypes = [.link]
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.isOpaque = false
        webView.backgroundColor = .systemBackground
        webView.scrollView.backgroundColor = .systemBackground
        webView.allowsLinkPreview = false
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.onLink = onLink
        if context.coordinator.loadedHTML != html {
            context.coordinator.loadedHTML = html
            webView.loadHTMLString(html, baseURL: APIClient.baseURL)
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var onLink: ((URL) -> Void)?
        var loadedHTML: String?

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

enum ArticleHTML {
    static let scheme = "anotherit-app"

    static func render(_ article: Article) -> String {
        var header = ""
        if let image = article.featuredImageUrl {
            header += "<img class=\"cover\" src=\"\(escape(image))\" alt=\"\">"
        }
        header += "<h1>\(escape(article.title))</h1>"

        var meta: [String] = []
        if let author = article.author?.name { meta.append(escape(author)) }
        if let date = article.publishedAt { meta.append(escape(DateParsing.display.string(from: date))) }
        if !meta.isEmpty {
            header += "<div class=\"meta\">\(meta.joined(separator: " · "))</div>"
        }
        if let tags = article.tags, !tags.isEmpty {
            let links = tags.map {
                "<a class=\"tag\" href=\"\(scheme)://tag/\(escape($0.slug))\">#\(escape($0.name))</a>"
            }
            header += "<div class=\"tags\">\(links.joined(separator: " "))</div>"
        }

        let pollNote = "<div class=\"note\">Здесь на сайте встроен интерактивный опрос — "
            + "<a href=\"\(escape(SiteLinks.absolute(article.url).absoluteString))\">открыть в браузере</a>.</div>"
        let content = (article.contentHtml ?? "")
            .replacingOccurrences(of: "<div data-poll-slot></div>", with: pollNote)

        let count = article.commentCount ?? 0
        let commentsButton = article.commentsEnabled == false && count == 0
            ? ""
            : "<a class=\"comments\" href=\"\(scheme)://comments\">Комментарии (\(count))</a>"

        return """
        <!DOCTYPE html>
        <html lang="ru">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
        <style>\(css)</style>
        </head>
        <body>
        <article>
        \(header)
        <div class="content">\(content)</div>
        \(commentsButton)
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

    private static let css = """
    :root { color-scheme: light dark; --accent: #ce2956; --muted: #6b6b70; --border: rgba(127,127,127,.25); --code-bg: rgba(127,127,127,.12); }
    @media (prefers-color-scheme: dark) { :root { --accent: #ff5c86; --muted: #9a9aa0; } }
    html { -webkit-text-size-adjust: 100%; }
    body { margin: 0; padding: 16px 18px calc(32px + env(safe-area-inset-bottom)); font: -apple-system-body; font-size: 18px; line-height: 1.6; word-wrap: break-word; }
    h1 { font-size: 26px; line-height: 1.25; margin: 12px 0 8px; }
    h2 { font-size: 22px; line-height: 1.3; margin: 28px 0 8px; }
    h3, h4 { font-size: 19px; margin: 24px 0 6px; }
    a { color: var(--accent); text-decoration: none; }
    img, video, iframe { max-width: 100%; height: auto; border-radius: 10px; }
    .cover { display: block; width: 100%; margin-bottom: 8px; }
    .meta { color: var(--muted); font-size: 14px; }
    .tags { margin-top: 6px; font-size: 14px; }
    .tag { margin-right: 8px; }
    .content { margin-top: 16px; }
    blockquote { margin: 16px 0; padding: 4px 14px; border-left: 3px solid var(--accent); color: var(--muted); }
    pre { background: var(--code-bg); padding: 12px; border-radius: 8px; overflow-x: auto; font-size: 14px; line-height: 1.45; }
    code { font-family: ui-monospace, Menlo, monospace; font-size: 0.9em; background: var(--code-bg); padding: 1px 4px; border-radius: 4px; }
    pre code { background: none; padding: 0; }
    table { border-collapse: collapse; display: block; overflow-x: auto; font-size: 15px; }
    th, td { border: 1px solid var(--border); padding: 6px 8px; }
    hr { border: none; border-top: 1px solid var(--border); margin: 24px 0; }
    figure { margin: 16px 0; }
    figcaption { color: var(--muted); font-size: 14px; text-align: center; }
    .note { margin: 16px 0; padding: 12px 14px; border-radius: 10px; background: var(--code-bg); font-size: 16px; }
    .comments { display: block; margin: 32px 0 8px; padding: 14px; text-align: center; border-radius: 12px; background: var(--accent); color: #fff; font-weight: 600; font-size: 17px; }
    """
}
