import Foundation

enum APIError: LocalizedError {
    case badStatus(Int)
    case versionConflict

    var errorDescription: String? {
        switch self {
        case .badStatus(let code): return "Сервер ответил кодом \(code)"
        case .versionConflict: return "Не удалось согласовать версию сайта"
        }
    }
}

/// The site is a Laravel + Inertia app: every page returns its data as JSON
/// when requested with the `X-Inertia` header. Comments are a deferred prop
/// and are fetched with a partial reload.
actor APIClient {
    static let shared = APIClient()
    static let baseURL = URL(string: "https://another-it.ru")!

    private static let versionKey = "inertiaVersion"

    private let session: URLSession
    private let decoder: JSONDecoder
    private var version: String

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: config)
        decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom { decoder in
            let raw = try decoder.singleValueContainer().decode(String.self)
            if let date = DateParsing.parse(raw) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "Bad date \(raw)"))
        }
        version = UserDefaults.standard.string(forKey: Self.versionKey) ?? ""
    }

    func articles(page: Int, tag: String?) async throws -> InertiaPage<ArticleListProps> {
        let path = tag.map { "/tag/\($0)" } ?? "/"
        let query = page > 1 ? [URLQueryItem(name: "page", value: String(page))] : []
        return try await fetch(path: path, query: query)
    }

    func article(path: String) async throws -> Article {
        let page: InertiaPage<ArticleProps> = try await fetch(path: path)
        return page.props.article
    }

    func comments(path: String) async throws -> [Comment] {
        let page: InertiaPage<CommentsProps> = try await fetch(
            path: path, partialComponent: "Articles/Show", partialData: ["comments"])
        return page.props.comments ?? []
    }

    private func fetch<P: Decodable>(path: String,
                                     query: [URLQueryItem] = [],
                                     partialComponent: String? = nil,
                                     partialData: [String] = []) async throws -> InertiaPage<P> {
        var components = URLComponents(url: Self.baseURL, resolvingAgainstBaseURL: false)!
        components.path = path
        components.queryItems = query.isEmpty ? nil : query
        let url = components.url!

        for attempt in 0..<3 {
            var request = URLRequest(url: url)
            request.setValue("true", forHTTPHeaderField: "X-Inertia")
            request.setValue(version, forHTTPHeaderField: "X-Inertia-Version")
            request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
            request.setValue("text/html, application/xhtml+xml", forHTTPHeaderField: "Accept")
            if let partialComponent {
                request.setValue(partialComponent, forHTTPHeaderField: "X-Inertia-Partial-Component")
                request.setValue(partialData.joined(separator: ","), forHTTPHeaderField: "X-Inertia-Partial-Data")
            }

            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await session.data(for: request)
            } catch {
                if attempt < 2, (error as? URLError)?.code != .cancelled { continue }
                throw error
            }
            guard let http = response as? HTTPURLResponse else { throw APIError.badStatus(-1) }

            // Asset version changed on the server: take the new one and retry.
            if http.statusCode == 409 {
                if let newVersion = http.value(forHTTPHeaderField: "X-Inertia-Version"), newVersion != version {
                    version = newVersion
                    UserDefaults.standard.set(newVersion, forKey: Self.versionKey)
                    continue
                }
                throw APIError.versionConflict
            }
            guard (200..<300).contains(http.statusCode) else { throw APIError.badStatus(http.statusCode) }

            let page = try decoder.decode(InertiaPage<P>.self, from: data)
            if let v = page.version, v != version {
                version = v
                UserDefaults.standard.set(v, forKey: Self.versionKey)
            }
            return page
        }
        throw APIError.versionConflict
    }
}

enum DateParsing {
    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// Laravel emits microseconds ("2026-09-25T22:43:58.000000Z"), which
    /// ISO8601DateFormatter does not accept, so the fraction is dropped.
    static func parse(_ raw: String) -> Date? {
        var s = raw
        if let dot = s.firstIndex(of: ".") {
            let rest = s[dot...].drop(while: { $0 == "." || $0.isNumber })
            s = String(s[..<dot]) + rest
        }
        return formatter.date(from: s)
    }

    static let display: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "d MMMM yyyy"
        return f
    }()

    private static let dayMonth: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "d MMM"
        return f
    }()

    private static let dayMonthYear: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "d MMM yyyy"
        return f
    }()

    /// "23 окт." for this year, "23 окт. 2024" for older dates.
    static func short(_ date: Date) -> String {
        let sameYear = Calendar.current.isDate(date, equalTo: Date(), toGranularity: .year)
        return (sameYear ? dayMonth : dayMonthYear).string(from: date)
    }

    static let displayWithTime: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "d MMM yyyy, HH:mm"
        return f
    }()
}

enum SiteLinks {
    /// Returns the site-relative path when the URL points to an article
    /// (`/yyyy/mm/dd/slug/`), otherwise nil.
    static func articlePath(from url: URL) -> String? {
        if let host = url.host, host != APIClient.baseURL.host, host != "www.another-it.ru" { return nil }
        if let scheme = url.scheme, scheme != "https", scheme != "http" { return nil }
        let parts = url.path.split(separator: "/")
        guard parts.count == 4,
              parts[0].count == 4, parts[0].allSatisfy(\.isNumber),
              parts[1].allSatisfy(\.isNumber), parts[2].allSatisfy(\.isNumber) else { return nil }
        return "/" + parts.joined(separator: "/") + "/"
    }

    static func absolute(_ path: String) -> URL {
        URL(string: path, relativeTo: APIClient.baseURL)?.absoluteURL ?? APIClient.baseURL
    }
}
