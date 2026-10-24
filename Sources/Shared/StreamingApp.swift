import Foundation

/// Streaming apps the remote can jump straight to, with each platform's app ID.
enum StreamingApp: String, CaseIterable, Identifiable {
    case netflix, youtube, prime, disney, hulu, max, peacock, appleTV, paramount

    var id: String { rawValue }

    var label: String {
        switch self {
        case .netflix: "Netflix"
        case .youtube: "YouTube"
        case .prime: "Prime Video"
        case .disney: "Disney+"
        case .hulu: "Hulu"
        case .max: "HBO Max"
        case .peacock: "Peacock"
        case .appleTV: "Apple TV"
        case .paramount: "Paramount+"
        }
    }

    /// The app's icon in the asset catalog (fetched by scripts/fetch_app_icons.py).
    var imageName: String { "app-\(rawValue)" }

    /// Samsung Tizen app IDs, newest first (older TVs use older IDs).
    var samsungIDs: [String] {
        switch self {
        case .netflix: ["3201907018807", "11101200001"]
        case .youtube: ["111299001912"]
        case .prime: ["3201910019365", "3201512006785"]
        case .disney: ["3201901017640"]
        case .hulu: ["3201601007625"]
        case .max: ["3201601007230"]
        case .peacock: ["3202006020991"]
        case .appleTV: ["3201807016597"]
        case .paramount: ["3201710014981"]
        }
    }

    /// Roku channel IDs.
    var rokuID: String {
        switch self {
        case .netflix: "12"
        case .youtube: "837"
        case .prime: "13"
        case .disney: "291097"
        case .hulu: "2285"
        case .max: "61322"
        case .peacock: "593099"
        case .appleTV: "551012"
        case .paramount: "31440"
        }
    }

    /// LG webOS app IDs.
    var lgID: String {
        switch self {
        case .netflix: "netflix"
        case .youtube: "youtube.leanback.v4"
        case .prime: "amazon"
        case .disney: "com.disney.disneyplus-prod"
        case .hulu: "hulu"
        case .max: "com.hbo.hbomax"
        case .peacock: "com.peacock.peacockwebos"
        case .appleTV: "com.apple.appletv"
        case .paramount: "com.cbs-all-access.webapp.prod"
        }
    }

    /// App links that Google TV / Android TV opens in the matching app.
    var androidLink: String {
        switch self {
        case .netflix: "https://www.netflix.com/title"
        case .youtube: "https://www.youtube.com"
        case .prime: "https://app.primevideo.com"
        case .disney: "https://www.disneyplus.com"
        case .hulu: "https://www.hulu.com/welcome"
        case .max: "https://play.max.com"
        case .peacock: "https://www.peacocktv.com"
        case .appleTV: "https://tv.apple.com"
        case .paramount: "https://www.paramountplus.com"
        }
    }

    /// Words to match against a TV's own app list (used for Sony).
    var titleMatch: [String] {
        switch self {
        case .prime: ["prime video", "amazon"]
        case .max: ["max"]
        case .appleTV: ["apple tv"]
        default: [label.lowercased()]
        }
    }
}
