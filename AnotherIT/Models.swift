import Foundation

struct Tag: Codable, Hashable, Identifiable {
    let name: String
    let slug: String
    let count: Int?

    var id: String { slug }
}

struct Author: Codable, Hashable {
    let name: String
    let slug: String?
}

struct ArticleSummary: Codable, Hashable, Identifiable {
    let id: Int
    let title: String
    let slug: String
    let url: String
    let excerpt: String?
    let featuredImageUrl: String?
    let isPinned: Bool?
    let publishedAt: Date?
    let commentCount: Int?
    let author: Author?
    let tags: [Tag]?
}

struct Paginator<Item: Codable>: Codable {
    let currentPage: Int
    let lastPage: Int
    let total: Int?
    let data: [Item]
}

struct Article: Codable, Hashable {
    let id: Int
    let title: String
    let slug: String
    let url: String
    let excerpt: String?
    let contentHtml: String?
    let featuredImageUrl: String?
    let publishedAt: Date?
    let commentCount: Int?
    let commentsEnabled: Bool?
    let author: Author?
    let tags: [Tag]?
}

struct CommentImage: Codable, Hashable {
    let url: String
}

struct Comment: Codable, Identifiable {
    let id: Int
    let name: String?
    let message: String?
    let createdAt: Date?
    let parentId: Int?
    let likesCount: Int?
    let dislikesCount: Int?
    let ipHash: String?
    let isBot: Bool?
    let hidden: Bool?
    let images: [CommentImage]?
    let children: [Comment]?
}

// MARK: - Inertia payloads

struct InertiaPage<Props: Decodable>: Decodable {
    let component: String
    let version: String?
    let props: Props
}

struct ArticleListProps: Decodable {
    let articles: Paginator<ArticleSummary>
    let allTags: [Tag]

    private enum CodingKeys: String, CodingKey {
        case articles, allTags
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        articles = try c.decode(Paginator<ArticleSummary>.self, forKey: .articles)
        allTags = (try? c.decodeIfPresent([Tag].self, forKey: .allTags)) ?? []
    }
}

struct ArticleProps: Decodable {
    let article: Article
}

struct CommentsProps: Decodable {
    let comments: [Comment]?
}
