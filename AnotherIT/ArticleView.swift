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
        .overlay(alignment: .bottom) {
            if let article = model.article {
                actionBar(article)
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let article = model.article {
                ToolbarItem(placement: .navigationBarTrailing) {
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
        .task {
            if model.article == nil { await model.load() }
        }
    }

    /// Floating capsule with the article actions, like vc.ru.
    private func actionBar(_ article: Article) -> some View {
        HStack(spacing: 26) {
            Button {
                openComments(article)
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "bubble.left")
                    Text("\(article.commentCount ?? 0)").monospacedDigit()
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .accessibilityLabel("Комментарии: \(article.commentCount ?? 0)")

            ShareLink(item: SiteLinks.absolute(article.url)) {
                Image(systemName: "arrowshape.turn.up.right")
                    .frame(minWidth: 32, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Поделиться")
        }
        .buttonStyle(.plain)
        .font(.title3)
        .foregroundStyle(.primary)
        .padding(.horizontal, 24)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
        .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
        .padding(.bottom, 8)
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
        let authorName = article.author?.name ?? "Другое IT"
        let authorSlug = article.author?.slug ?? authorName
        let isBot = authorSlug == "sitebot"
        let initial = isBot ? "✨" : escape(String(authorName.prefix(1)).uppercased())
        let avatarColor = AuthorColor.hex(seed: authorSlug, isBot: isBot)

        var sub: [String] = []
        if let tag = article.tags?.first {
            sub.append("<a href=\"\(scheme)://tag/\(escape(tag.slug))\">\(escape(tag.name))</a>")
        }
        if let date = article.publishedAt {
            sub.append("<span>\(escape(DateParsing.short(date)))</span>")
        }

        var header = """
        <header class="author">
        <div class="avatar" style="background-color: \(avatarColor)">\(initial)</div>
        <div><div class="name">\(escape(authorName))</div><div class="sub">\(sub.joined())</div></div>
        </header>
        <h1>\(escape(article.title))</h1>
        """
        if let excerpt = article.excerpt, !excerpt.isEmpty {
            header += "<p class=\"lead\">\(escape(excerpt))</p>"
        }
        if let image = article.featuredImageUrl {
            header += "<img class=\"cover\" src=\"\(escape(image))\" alt=\"\">"
        }

        var footer = ""
        if let tags = article.tags, !tags.isEmpty {
            let links = tags.map {
                "<a class=\"tag\" href=\"\(scheme)://tag/\(escape($0.slug))\">#\(escape($0.name))</a>"
            }
            footer += "<div class=\"tags\">\(links.joined())</div>"
        }

        let pollNote = "<div class=\"note\">Здесь на сайте встроен интерактивный опрос — "
            + "<a href=\"\(escape(SiteLinks.absolute(article.url).absoluteString))\">открыть в браузере</a>.</div>"
        let content = (article.contentHtml ?? "")
            .replacingOccurrences(of: "<div data-poll-slot></div>", with: pollNote)

        let count = article.commentCount ?? 0
        if article.commentsEnabled != false || count > 0 {
            footer += "<a class=\"comments\" href=\"\(scheme)://comments\">Комментарии · \(count)</a>"
        }

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
        \(footer)
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
    :root { color-scheme: light dark; --bg: #fff; --text: #000; --accent: #ce2956; --muted: #8a8a8e; --border: rgba(127,127,127,.25); --fill: rgba(118,118,128,.12); }
    @media (prefers-color-scheme: dark) { :root { --bg: #000; --text: #fff; --accent: #ff5c86; --muted: #98989f; --fill: rgba(118,118,128,.24); } }
    html { -webkit-text-size-adjust: 100%; background: var(--bg); }
    body { margin: 0; padding: 8px 16px calc(110px + env(safe-area-inset-bottom)); background: var(--bg); color: var(--text); font-family: -apple-system, system-ui, sans-serif; font-size: 18px; line-height: 1.55; word-wrap: break-word; }
    a { color: var(--accent); text-decoration: none; }
    .author { display: flex; align-items: center; gap: 12px; margin: 4px 0 16px; }
    .avatar { flex: none; width: 42px; height: 42px; border-radius: 50%; color: #fff; font: 600 18px/42px ui-rounded, -apple-system, sans-serif; text-align: center; background-image: linear-gradient(rgba(255,255,255,.22), rgba(255,255,255,0)); }
    .name { font-size: 17px; font-weight: 600; line-height: 1.3; }
    .sub { font-size: 15px; line-height: 1.3; color: var(--muted); }
    .sub > * { margin-right: 10px; }
    .sub a { color: var(--text); }
    h1 { font-size: 28px; line-height: 1.22; font-weight: 700; letter-spacing: -0.01em; margin: 0 0 10px; }
    .lead { font-size: 19px; line-height: 1.45; margin: 0 0 16px; }
    .cover { display: block; width: 100%; margin: 6px 0 4px; border-radius: 14px; }
    .content { margin-top: 18px; }
    .content > :first-child { margin-top: 0; }
    p { margin: 0 0 16px; }
    h2 { font-size: 23px; line-height: 1.3; margin: 30px 0 10px; }
    h3, h4 { font-size: 20px; line-height: 1.3; margin: 26px 0 8px; }
    ul, ol { padding-left: 26px; margin: 0 0 16px; }
    li { margin-bottom: 8px; }
    li::marker { color: var(--muted); }
    img, video, iframe { max-width: 100%; height: auto; border-radius: 14px; }
    figure { margin: 20px 0; }
    figcaption { color: var(--muted); font-size: 15px; margin-top: 8px; }
    blockquote { margin: 20px 0; padding: 2px 0 2px 16px; border-left: 3px solid var(--accent); }
    pre { background: var(--fill); padding: 14px; border-radius: 12px; overflow-x: auto; font-size: 14px; line-height: 1.45; }
    code { font-family: ui-monospace, Menlo, monospace; font-size: 0.88em; background: var(--fill); padding: 2px 5px; border-radius: 5px; }
    pre code { background: none; padding: 0; }
    table { border-collapse: collapse; display: block; overflow-x: auto; font-size: 15px; }
    th, td { border: 1px solid var(--border); padding: 6px 8px; }
    hr { border: none; border-top: 1px solid var(--border); margin: 28px 0; }
    .note { margin: 16px 0; padding: 14px 16px; border-radius: 14px; background: var(--fill); font-size: 16px; }
    .tags { margin: 28px 0 0; display: flex; flex-wrap: wrap; gap: 8px; }
    .tag { padding: 6px 12px; border-radius: 999px; background: var(--fill); color: var(--text); font-size: 15px; }
    .comments { display: block; margin: 24px 0 8px; padding: 14px; text-align: center; border-radius: 14px; background: var(--fill); color: var(--accent); font-weight: 600; font-size: 17px; }
    """
}
