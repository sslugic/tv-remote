import Foundation

/// Opens YouTube on the TV straight onto search results, using DIAL (the protocol phones use to cast to TVs).
/// YouTube's own on-screen keyboard can't receive typed text from remotes, but its DIAL launch accepts a query:
/// "q=<text>&launch=search" (confirmed on a 2019 Samsung).
enum YouTubeSearch {
    /// Where TV makers expose YouTube's DIAL app resource.
    private static let candidates = [
        (8080, "/ws/apps/YouTube"), // Samsung
        (8060, "/dial/YouTube"),    // Roku
        (8008, "/apps/YouTube"),    // Google TV / Android TV / Chromecast
        (36866, "/apps/YouTube"),   // LG webOS
        (8009, "/apps/YouTube"),    // Fire TV
    ]

    /// Returns false if the TV doesn't offer YouTube over DIAL.
    static func search(_ query: String, host: String) async -> Bool {
        guard let url = await findApp(host: host) else { return false }
        var comps = URLComponents()
        comps.queryItems = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "launch", value: "search")]
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 8
        request.setValue("text/plain; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data((comps.percentEncodedQuery ?? "").utf8)
        guard let (_, response) = try? await LocalTLS.session.data(for: request),
              let status = (response as? HTTPURLResponse)?.statusCode else { return false }
        return (200..<300).contains(status)
    }

    private static func findApp(host: String) async -> URL? {
        for (port, path) in candidates {
            guard let url = URL(string: "http://\(host):\(port)\(path)") else { continue }
            var request = URLRequest(url: url)
            request.timeoutInterval = 2
            if let (data, response) = try? await LocalTLS.session.data(for: request),
               (response as? HTTPURLResponse)?.statusCode == 200,
               String(decoding: data, as: UTF8.self).contains("<service") {
                return url
            }
        }
        return nil
    }
}
