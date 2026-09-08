import SwiftUI

/// A single Unsplash photo, reduced to what the cover picker and the attribution
/// need.
nonisolated struct UnsplashPhoto: Identifiable, Sendable, Equatable {
    let id: String
    let regularURL: URL
    let thumbURL: URL
    let downloadLocation: URL
    let photographerName: String
    let photographerProfileURL: URL
    let photoPageURL: URL
    /// The photo's dominant colour as a bare hex string — a calm placeholder
    /// while the thumbnail loads. Turned into a `Color` at the view layer.
    let accentHex: String?
}

/// Read-only access to the Unsplash API.
///
/// The access key ships in the binary: the app has no backend to proxy through,
/// and the key only grants public read access (the secret key, used only for the
/// OAuth user flow, is deliberately not included). Usage stays inside the demo
/// tier — search and editorial listing, plus the download-tracking ping the API
/// terms require whenever a photo is applied.
nonisolated enum UnsplashService {
    static let accessKey = "uD5H_2QFL2joAP_KDjbcQgNDJNIR1I6CjqDTY0A8tqg"
    /// Used for the `utm_source` on every attribution link, and must match the
    /// registered application name.
    static let appName = "Financium"

    static let unsplashHomeURL = attributed(URL(string: "https://unsplash.com")!)

    /// The category chips the picker shows above the grid — a plain search term
    /// each. `nil` term is the editorial feed.
    static let categories: [(key: String, term: String?)] = [
        ("cover.unsplash.editorial", nil),
        ("cover.unsplash.cat.wallpapers", "wallpapers"),
        ("cover.unsplash.cat.nature", "nature"),
        ("cover.unsplash.cat.textures", "textures patterns"),
        ("cover.unsplash.cat.abstract", "abstract"),
        ("cover.unsplash.cat.minimal", "minimal"),
        ("cover.unsplash.cat.city", "architecture city"),
        ("cover.unsplash.cat.space", "space")
    ]

    private static let base = URL(string: "https://api.unsplash.com")!

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.urlCache = URLCache(memoryCapacity: 16 << 20, diskCapacity: 128 << 20)
        config.requestCachePolicy = .returnCacheDataElseLoad
        config.waitsForConnectivity = true
        return URLSession(configuration: config)
    }()

    // MARK: - Queries

    /// The editorial feed — what the picker shows before the user searches.
    static func editorial(page: Int = 1) async throws -> [UnsplashPhoto] {
        let dtos: [PhotoDTO] = try await request(path: "/photos", query: [
            URLQueryItem(name: "per_page", value: "30"),
            URLQueryItem(name: "page", value: "\(page)"),
            URLQueryItem(name: "order_by", value: "popular")
        ])
        return dtos.compactMap(\.model)
    }

    static func search(_ term: String, page: Int = 1) async throws -> [UnsplashPhoto] {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return try await editorial(page: page) }
        let response: SearchResponse = try await request(path: "/search/photos", query: [
            URLQueryItem(name: "query", value: trimmed),
            URLQueryItem(name: "per_page", value: "30"),
            URLQueryItem(name: "page", value: "\(page)"),
            URLQueryItem(name: "content_filter", value: "high")
        ])
        return response.results.compactMap(\.model)
    }

    // MARK: - Terms compliance

    /// Unsplash requires a hit on the photo's `download_location` whenever a
    /// photo is used. Fire-and-forget — a failure here must not block the pick.
    static func trackUsage(_ photo: UnsplashPhoto) {
        Task {
            guard var components = URLComponents(url: photo.downloadLocation, resolvingAgainstBaseURL: false) else { return }
            var items = components.queryItems ?? []
            items.append(URLQueryItem(name: "client_id", value: accessKey))
            components.queryItems = items
            guard let url = components.url else { return }
            _ = try? await session.data(from: url)
        }
    }

    /// Appends the `utm_source` / `utm_medium` pair every outbound Unsplash link
    /// must carry.
    static func attributed(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        var items = components.queryItems ?? []
        items.append(URLQueryItem(name: "utm_source", value: appName))
        items.append(URLQueryItem(name: "utm_medium", value: "referral"))
        components.queryItems = items
        return components.url ?? url
    }

    // MARK: - Image loading

    static func image(at url: URL) async -> UIImage? {
        guard let (data, _) = try? await session.data(from: url) else { return nil }
        return UIImage(data: data)
    }

    // MARK: - Plumbing

    private static func request<T: Decodable>(path: String, query: [URLQueryItem]) async throws -> T {
        guard var components = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false) else {
            throw UnsplashError.badRequest
        }
        components.queryItems = query
        guard let url = components.url else { throw UnsplashError.badRequest }
        var request = URLRequest(url: url)
        request.setValue("Client-ID \(accessKey)", forHTTPHeaderField: "Authorization")
        request.setValue("v1", forHTTPHeaderField: "Accept-Version")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw UnsplashError.badResponse }
        guard 200..<300 ~= http.statusCode else { throw UnsplashError.status(http.statusCode) }
        return try JSONDecoder().decode(T.self, from: data)
    }

    enum UnsplashError: Error { case badRequest, badResponse, status(Int) }
}

// MARK: - Wire format

private nonisolated struct SearchResponse: Decodable { let results: [PhotoDTO] }

private nonisolated struct PhotoDTO: Decodable {
    struct URLs: Decodable { let regular: String; let small: String }
    struct Links: Decodable { let html: String; let download_location: String }
    struct User: Decodable {
        struct UserLinks: Decodable { let html: String }
        let name: String
        let links: UserLinks
    }
    let id: String
    let color: String?
    let urls: URLs
    let links: Links
    let user: User

    var model: UnsplashPhoto? {
        guard let regular = URL(string: urls.regular),
              let thumb = URL(string: urls.small),
              let download = URL(string: links.download_location),
              let profile = URL(string: user.links.html),
              let page = URL(string: links.html) else { return nil }
        return UnsplashPhoto(
            id: id,
            regularURL: regular,
            thumbURL: thumb,
            downloadLocation: download,
            photographerName: user.name,
            photographerProfileURL: profile,
            photoPageURL: page,
            accentHex: color?.replacingOccurrences(of: "#", with: "")
        )
    }
}

// MARK: - Cover bridging

nonisolated extension FinancePlanCover.UnsplashCredit {
    init(_ photo: UnsplashPhoto) {
        self.init(
            photoID: photo.id,
            imageURL: photo.regularURL.absoluteString,
            thumbURL: photo.thumbURL.absoluteString,
            photographerName: photo.photographerName,
            photographerURL: photo.photographerProfileURL.absoluteString,
            photoURL: photo.photoPageURL.absoluteString
        )
    }

    var photographerLink: URL? {
        URL(string: photographerURL).map(UnsplashService.attributed)
    }
    var unsplashLink: URL? {
        URL(string: photoURL).map(UnsplashService.attributed)
    }
}

/// "Photo by <name> on Unsplash" — both the photographer and Unsplash linked
/// with the UTM tags the API terms require.
struct UnsplashCreditLabel: View {
    let credit: FinancePlanCover.UnsplashCredit
    var tint: Color = .secondary

    var body: some View {
        HStack(spacing: 3) {
            Text("cover.credit.by")
            link(credit.photographerName, credit.photographerLink)
            Text("cover.credit.on")
            link("Unsplash", credit.unsplashLink)
        }
        .font(.caption2)
        .foregroundStyle(tint)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }

    @ViewBuilder
    private func link(_ text: String, _ url: URL?) -> some View {
        if let url {
            Link(text, destination: url).underline()
        } else {
            Text(verbatim: text)
        }
    }
}
