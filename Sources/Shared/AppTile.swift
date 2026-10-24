import SwiftUI
import UIKit

/// A streaming app's button face. Uses the app's official icon when it's in the asset catalog
/// (local builds, via scripts/fetch_app_icons.py); otherwise a brand-colored tile with the name,
/// which is what the public repo and the App Store build ship.
struct AppTile: View {
    let app: StreamingApp
    var size: CGFloat = 58

    var body: some View {
        Group {
            if UIImage(named: app.imageName) != nil {
                Image(app.imageName).resizable()
            } else {
                ZStack {
                    app.color
                    Text(app.shortLabel)
                        .font(.system(size: size * 0.2, weight: .heavy, design: .rounded))
                        .foregroundStyle(app.textColor)
                        .multilineTextAlignment(.center)
                        .minimumScaleFactor(0.6)
                        .padding(4)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
    }
}

extension StreamingApp {
    var shortLabel: String {
        switch self {
        case .prime: "Prime\nVideo"
        case .max: "HBO\nMax"
        case .appleTV: "Apple\nTV"
        case .paramount: "Para-\nmount+"
        default: label
        }
    }

    var color: Color {
        switch self {
        case .netflix: Color(red: 0.08, green: 0.08, blue: 0.08)
        case .youtube: Color(red: 0.95, green: 0.0, blue: 0.0)
        case .prime: Color(red: 0.0, green: 0.47, blue: 0.95)
        case .disney: Color(red: 0.05, green: 0.15, blue: 0.40)
        case .hulu: Color(red: 0.11, green: 0.91, blue: 0.51)
        case .max: Color(red: 0.0, green: 0.15, blue: 0.75)
        case .peacock: Color(red: 0.12, green: 0.12, blue: 0.12)
        case .appleTV: Color(white: 0.9)
        case .paramount: Color(red: 0.0, green: 0.39, blue: 1.0)
        }
    }

    var textColor: Color {
        switch self {
        case .netflix: Color(red: 0.9, green: 0.04, blue: 0.08)
        case .hulu, .appleTV: .black
        default: .white
        }
    }
}
