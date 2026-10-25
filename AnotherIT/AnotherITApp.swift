import SwiftUI

@main
struct AnotherITApp: App {
    init() {
        URLCache.shared = URLCache(memoryCapacity: 64 * 1024 * 1024,
                                   diskCapacity: 512 * 1024 * 1024)
    }

    var body: some Scene {
        WindowGroup {
            RoutedStack {
                ArticleListView(tag: nil)
            }
        }
    }
}

enum Route: Hashable {
    case article(path: String)
    case comments(path: String)
    case tag(Tag)
}

/// The navigation stack with its router.
struct RoutedStack<Root: View>: View {
    @StateObject private var router = Router()
    @ViewBuilder let root: () -> Root

    var body: some View {
        NavigationStack(path: $router.path) {
            root()
                .navigationDestination(for: Route.self) { route in
                    switch route {
                    case .article(let path):
                        ArticleView(path: path)
                    case .comments(let path):
                        ArticleView(path: path, focusComments: true)
                    case .tag(let tag):
                        ArticleListView(tag: tag)
                    }
                }
        }
        .environmentObject(router)
    }
}

final class Router: ObservableObject {
    @Published var path = NavigationPath()

    func push(_ route: Route) {
        path.append(route)
    }

    /// Opens site links inside the app; returns false for links it cannot handle.
    func handle(_ url: URL) -> Bool {
        if let articlePath = SiteLinks.articlePath(from: url) {
            push(.article(path: articlePath))
            return true
        }
        if url.host == APIClient.baseURL.host, url.path.hasPrefix("/tag/") {
            let slug = url.path.dropFirst("/tag/".count).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if !slug.isEmpty {
                push(.tag(Tag(name: slug, slug: slug, count: nil)))
                return true
            }
        }
        return false
    }
}
