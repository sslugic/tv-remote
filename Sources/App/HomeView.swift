import SwiftUI

/// Shown for a moment on launch: the remote logo pops in over a purple glow.
struct SplashView: View {
    @State private var appeared = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            Circle()
                .fill(Color(red: 0.55, green: 0.35, blue: 1.0).opacity(0.45))
                .frame(width: 320, height: 320)
                .blur(radius: 90)
                .scaleEffect(appeared ? 1.2 : 0.6)
            VStack(spacing: 18) {
                Image("splash-logo")
                    .resizable()
                    .frame(width: 120, height: 120)
                    .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                    .shadow(color: .purple.opacity(0.6), radius: 24)
                    .scaleEffect(appeared ? 1 : 0.7)
                Text(AppInfo.name)
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 10)
            }
        }
        .onAppear {
            withAnimation(.spring(response: 0.6, dampingFraction: 0.7)) { appeared = true }
        }
    }
}

/// Landing page: a way into the remote plus banners for our other apps.
struct HomeView: View {
    @EnvironmentObject private var remote: RemoteController
    @EnvironmentObject private var prefs: Preferences
    @State private var showingSettings = false
    var onProceed: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(AppInfo.name)
                            .font(.system(size: 34, weight: .bold, design: .rounded))
                        Text(tvLine)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { showingSettings = true } label: {
                        Image(systemName: "gearshape.fill")
                            .font(.title3)
                            .padding(10)
                            .background(Circle().fill(.white.opacity(0.1)))
                    }
                    .accessibilityLabel("Settings")
                }
                .padding(.top, 12)

                proceedCard

                Text("More from us")
                    .font(.title3.bold())
                    .padding(.top, 8)

                ForEach(Promo.all) { PromoBanner(promo: $0) }
            }
            .padding(20)
        }
        .scrollIndicators(.hidden)
        .background(LinearGradient(colors: prefs.theme.background, startPoint: .top, endPoint: .bottom).ignoresSafeArea())
        .sheet(isPresented: $showingSettings) { SettingsView() }
        .foregroundStyle(.white)
    }

    private var tvLine: String {
        guard let tv = remote.current else { return "Find a TV on your Wi-Fi to get started." }
        return remote.status == .connected ? "Connected to \(tv.name)" : "Your TV: \(tv.name)"
    }

    private var proceedCard: some View {
        Button(action: onProceed) {
            HStack(spacing: 16) {
                Image("splash-logo")
                    .resizable()
                    .frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                VStack(alignment: .leading, spacing: 4) {
                    Text("Proceed to remote")
                        .font(.title3.bold())
                    Text("D-pad, volume and your streaming apps")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.75))
                }
                Spacer()
                Image(systemName: "arrow.right.circle.fill")
                    .font(.system(size: 34))
            }
            .padding(18)
            .background(
                LinearGradient(
                    colors: [Color(red: 0.45, green: 0.25, blue: 0.95), Color(red: 0.22, green: 0.10, blue: 0.55)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: 24, style: .continuous)
            )
            .shadow(color: .purple.opacity(0.4), radius: 18, y: 8)
        }
        .buttonStyle(.plain)
    }
}

/// One of our other apps, advertised on the home page.
struct Promo: Identifiable {
    let id: String
    let name: String
    let tagline: String
    let detail: String
    let image: String
    let url: URL
    let colors: [Color]
    let accent: Color

    static let all = [
        Promo(
            id: "pulse",
            name: "Pulse",
            tagline: "Retro fitness tracker",
            detail: "Count calories, log workouts and level up with your crew, 80s arcade style.",
            image: "promo-pulse",
            url: URL(string: "https://pulseretro.fit")!,
            colors: [Color(red: 0.10, green: 0.30, blue: 0.12), Color(red: 0.05, green: 0.08, blue: 0.06)],
            accent: Color(red: 0.45, green: 1.0, blue: 0.25)
        ),
        Promo(
            id: "docklio",
            name: "Docklio",
            tagline: "Every document, gathered and read",
            detail: "Pulls what belongs to each matter from Gmail, Drive, Dropbox and more. Nothing is copied or moved.",
            image: "promo-docklio",
            url: URL(string: "https://docklio.co")!,
            colors: [Color(red: 0.45, green: 0.20, blue: 0.02), Color(red: 0.10, green: 0.06, blue: 0.04)],
            accent: Color(red: 1.0, green: 0.55, blue: 0.10)
        ),
        Promo(
            id: "undertone",
            name: "Undertone",
            tagline: "Your quiet meeting copilot",
            detail: "Explains jargon from your own workspace, suggests answers and remembers every call. For Mac.",
            image: "promo-undertone",
            url: URL(string: "https://getundertone.app")!,
            colors: [Color(red: 0.20, green: 0.20, blue: 0.45), Color(red: 0.04, green: 0.04, blue: 0.07)],
            accent: Color(red: 0.51, green: 0.55, blue: 0.97)
        ),
    ]
}

struct PromoBanner: View {
    let promo: Promo
    @Environment(\.openURL) private var openURL

    var body: some View {
        Button { openURL(promo.url) } label: {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 14) {
                    Image(promo.image)
                        .resizable()
                        .frame(width: 60, height: 60)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(promo.name).font(.title3.bold())
                        Text(promo.tagline).font(.subheadline.weight(.semibold)).foregroundStyle(promo.accent)
                    }
                }
                Text(promo.detail)
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.8))
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Text("Visit \(promo.url.host() ?? "website")")
                    Image(systemName: "arrow.up.right")
                }
                .font(.footnote.bold())
                .foregroundStyle(.black)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(promo.accent, in: Capsule())
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .background(
                LinearGradient(colors: promo.colors, startPoint: .topLeading, endPoint: .bottomTrailing),
                in: RoundedRectangle(cornerRadius: 22, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(promo.accent.opacity(0.35), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}
