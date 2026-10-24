import SwiftUI

// Trending and popular movies & shows from TMDB, with "where to watch" from JustWatch (via TMDB).
// Tapping a title can open it in the matching streaming app on the TV.

struct MediaTitle: Identifiable, Hashable, Decodable {
    let id: Int
    let mediaType: String?
    let title: String?
    let name: String?
    let posterPath: String?
    let backdropPath: String?
    let overview: String?
    let voteAverage: Double?
    let releaseDate: String?
    let firstAirDate: String?

    var displayName: String { title ?? name ?? "Untitled" }
    var isShow: Bool { mediaType == "tv" || (mediaType == nil && name != nil) }
    var year: String? { (releaseDate ?? firstAirDate).flatMap { $0.count >= 4 ? String($0.prefix(4)) : nil } }
    var posterURL: URL? { posterPath.flatMap { URL(string: "https://image.tmdb.org/t/p/w342\($0)") } }
    var backdropURL: URL? { (backdropPath ?? posterPath).flatMap { URL(string: "https://image.tmdb.org/t/p/w780\($0)") } }
}

struct Provider: Identifiable, Hashable {
    let id: Int
    let name: String
    let logoURL: URL?

    /// The streaming app button this provider maps to, if any.
    var app: StreamingApp? {
        switch id {
        case 8, 175, 1796: .netflix
        case 9, 613, 2100: .prime
        case 337: .disney
        case 15: .hulu
        case 1899, 1825: .max
        case 386, 387, 2553: .peacock
        case 350, 2243: .appleTV
        case 2303, 2616, 582, 633, 1853: .paramount
        case 192, 188, 235: .youtube
        default: nil
        }
    }
}

enum TitleList: String, CaseIterable, Identifiable {
    case trending, movies, shows
    var id: String { rawValue }
    var label: String {
        switch self {
        case .trending: "Trending"
        case .movies: "Popular movies"
        case .shows: "Popular shows"
        }
    }
    var path: String {
        switch self {
        case .trending: "trending/all/week"
        case .movies: "movie/popular"
        case .shows: "tv/popular"
        }
    }
}

/// Small TMDB client. The token comes from the build (Secrets.xcconfig → Info.plist).
enum TMDB {
    static var token: String? {
        let value = Bundle.main.object(forInfoDictionaryKey: "TMDBToken") as? String
        return (value?.isEmpty ?? true) ? nil : value
    }

    static var isConfigured: Bool { token != nil }
    static var region: String { Locale.current.region?.identifier ?? "US" }

    static func list(_ list: TitleList, page: Int = 1) async throws -> [MediaTitle] {
        struct Page: Decodable { let results: [MediaTitle] }
        let data = try await get(list.path, query: ["page": "\(page)"])
        let titles = try decoder.decode(Page.self, from: data).results
        // Trending also includes people; keep movies and shows with artwork.
        return titles.filter { $0.mediaType != "person" && $0.posterPath != nil }
            .map { title in
                guard title.mediaType == nil else { return title }
                return MediaTitle(id: title.id, mediaType: list == .shows ? "tv" : "movie", title: title.title, name: title.name,
                             posterPath: title.posterPath, backdropPath: title.backdropPath, overview: title.overview,
                             voteAverage: title.voteAverage, releaseDate: title.releaseDate, firstAirDate: title.firstAirDate)
            }
    }

    /// Subscription, free and ad-supported places to watch in the user's region.
    static func providers(for title: MediaTitle) async throws -> [Provider] {
        let data = try await get("\(title.isShow ? "tv" : "movie")/\(title.id)/watch/providers")
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let region = (json["results"] as? [String: Any])?[region] as? [String: Any] else { return [] }
        var seen = Set<Int>()
        var providers: [Provider] = []
        for kind in ["flatrate", "free", "ads"] {
            for entry in (region[kind] as? [[String: Any]]) ?? [] {
                guard let id = entry["provider_id"] as? Int, let name = entry["provider_name"] as? String,
                      seen.insert(id).inserted else { continue }
                let logo = (entry["logo_path"] as? String).flatMap { URL(string: "https://image.tmdb.org/t/p/w92\($0)") }
                let provider = Provider(id: id, name: name, logoURL: logo)
                // Plans of the same service (e.g. Netflix and Netflix with Ads) show once.
                if let app = provider.app, providers.contains(where: { $0.app == app }) { continue }
                providers.append(provider)
            }
        }
        return providers
    }

    private static func get(_ path: String, query: [String: String] = [:]) async throws -> Data {
        guard let token else { throw RemoteError("Trending titles aren't set up in this build.") }
        var comps = URLComponents(string: "https://api.themoviedb.org/3/\(path)")!
        comps.queryItems = [URLQueryItem(name: "language", value: Locale.current.identifier.replacingOccurrences(of: "_", with: "-"))]
            + query.map { URLQueryItem(name: $0.key, value: $0.value) }
        var request = URLRequest(url: comps.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw RemoteError("Couldn't load titles.") }
        return data
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()
}

// MARK: - Carousel on the remote

/// Auto-sliding strip of trending titles, with a link to the full browse page.
struct TrendingCarousel: View {
    @State private var titles: [MediaTitle] = []
    @State private var index = 0
    @State private var selected: MediaTitle?
    @State private var browsing = false
    private let timer = Timer.publish(every: 4, on: .main, in: .common).autoconnect()

    var body: some View {
        if TMDB.isConfigured {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("TRENDING NOW").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                    Spacer()
                    Button { browsing = true } label: {
                        HStack(spacing: 2) { Text("See all"); Image(systemName: "chevron.right") }
                            .font(.caption.weight(.semibold))
                    }
                }
                TabView(selection: $index) {
                    ForEach(Array(titles.prefix(10).enumerated()), id: \.element.id) { i, title in
                        Button { selected = title } label: { BackdropTile(title: title) }
                            .buttonStyle(.plain)
                            .tag(i)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .frame(height: 120)
                .overlay {
                    if titles.isEmpty {
                        RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.white.opacity(0.06))
                            .overlay(ProgressView())
                    }
                }
            }
            .task { if titles.isEmpty { titles = (try? await TMDB.list(.trending)) ?? [] } }
            .onReceive(timer) { _ in
                guard titles.count > 1 else { return }
                withAnimation(.easeInOut(duration: 0.6)) { index = (index + 1) % min(titles.count, 10) }
            }
            .sheet(item: $selected) { TitleDetail(title: $0) }
            .fullScreenCover(isPresented: $browsing) { BrowseView() }
        }
    }
}

struct BackdropTile: View {
    let title: MediaTitle
    var height: CGFloat = 120

    var body: some View {
        // A fixed-size base so the filled image can't push the caption out of view.
        Color.white.opacity(0.06)
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .overlay {
                AsyncImage(url: title.backdropURL) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    Color.clear
                }
            }
            .overlay { LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .center, endPoint: .bottom) }
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title.displayName).font(.headline).lineLimit(1)
                    Text([title.isShow ? "Show" : "Movie", title.year].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.white.opacity(0.75))
                }
                .foregroundStyle(.white)
                .padding(12)
            }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .contentShape(Rectangle())
    }
}

// MARK: - Browse page

struct BrowseView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var list = TitleList.trending
    @State private var titles: [TitleList: [MediaTitle]] = [:]
    @State private var selected: MediaTitle?
    @State private var failed = false

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 3)

    var body: some View {
        NavigationStack {
            ScrollView {
                Picker("List", selection: $list) {
                    ForEach(TitleList.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.bottom, 8)

                if let items = titles[list] {
                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(items) { title in
                            Button { selected = title } label: { PosterTile(title: title) }
                                .buttonStyle(.plain)
                        }
                    }
                } else if failed {
                    ContentUnavailableView("Couldn't load titles", systemImage: "wifi.exclamationmark",
                                           description: Text("Check your internet connection and try again."))
                } else {
                    ProgressView().padding(.top, 60)
                }

                Text("Movie data from TMDB. This product uses the TMDB API but is not endorsed or certified by TMDB. Streaming availability by JustWatch.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 24)
            }
            .padding(.horizontal, 16)
            .navigationTitle("What to watch")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task(id: list) { await load(list) }
            .refreshable {
                titles[list] = nil
                await load(list)
            }
            .sheet(item: $selected) { TitleDetail(title: $0) }
        }
        .preferredColorScheme(.dark)
    }

    private func load(_ list: TitleList) async {
        guard titles[list] == nil else { return }
        do {
            failed = false
            titles[list] = try await TMDB.list(list)
        } catch {
            failed = true
        }
    }
}

struct PosterTile: View {
    let title: MediaTitle

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            AsyncImage(url: title.posterURL) { image in
                image.resizable().aspectRatio(2 / 3, contentMode: .fill)
            } placeholder: {
                Color.white.opacity(0.06).aspectRatio(2 / 3, contentMode: .fit)
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            Text(title.displayName).font(.caption.weight(.semibold)).lineLimit(1)
            if let rating = title.voteAverage, rating > 0 {
                Label(String(format: "%.1f", rating), systemImage: "star.fill")
                    .font(.caption2).foregroundStyle(.yellow)
            }
        }
    }
}

// MARK: - Detail

struct TitleDetail: View {
    let title: MediaTitle
    @EnvironmentObject private var remote: RemoteController
    @Environment(\.dismiss) private var dismiss
    @State private var providers: [Provider]?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                BackdropTile(title: title, height: 180)
                HStack(spacing: 10) {
                    if let year = title.year { Text(year) }
                    Text(title.isShow ? "TV show" : "Movie")
                    if let rating = title.voteAverage, rating > 0 {
                        Label(String(format: "%.1f", rating), systemImage: "star.fill").foregroundStyle(.yellow)
                    }
                }
                .font(.subheadline).foregroundStyle(.secondary)

                if let overview = title.overview, !overview.isEmpty {
                    Text(overview).font(.body)
                }

                Text("Where to watch").font(.headline).padding(.top, 4)
                if let providers {
                    if providers.isEmpty {
                        Text("Not streaming on a subscription service in your region right now.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    ForEach(providers) { provider in providerRow(provider) }
                } else {
                    ProgressView()
                }

                Text("Streaming availability by JustWatch. Data from TMDB.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(20)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .task { providers = (try? await TMDB.providers(for: title)) ?? [] }
    }

    @ViewBuilder
    private func providerRow(_ provider: Provider) -> some View {
        HStack(spacing: 12) {
            AsyncImage(url: provider.logoURL) { $0.resizable() } placeholder: { Color.white.opacity(0.1) }
                .frame(width: 36, height: 36)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            Text(provider.name)
            Spacer()
            if let app = provider.app, remote.current != nil {
                Button("Open on TV") {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    remote.launch(app)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
    }
}
